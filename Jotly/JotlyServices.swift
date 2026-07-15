import EventKit
import AVFoundation
import Foundation
import Speech
import UserNotifications
import os

enum JotlyError: LocalizedError {
    case speechPermissionDenied
    case microphonePermissionDenied
    case speechUnavailable
    case speechStartFailed(String)
    case deepSeekHTTPError(Int, String)
    case missingDeepSeekContent
    case invalidDeepSeekResponse
    case invalidDeepSeekResponseWithRaw(String)
    case notificationPermissionDenied
    case calendarPermissionDenied
    case reminderPermissionDenied
    case eventStoreUnavailable
    case calendarEventCreationFailed(String)
    case reminderCreationFailed(String)
    case unsupportedTool(String)
    case missingASRConfiguration(String)
    case invalidToolParameters(String)

    var errorDescription: String? {
        switch self {
        case .speechPermissionDenied:
            "需要语音识别权限，将你的语音转成文字。"
        case .microphonePermissionDenied:
            "需要使用麦克风来识别你的语音记录。"
        case .speechUnavailable:
            "当前设备暂时不可用语音识别。"
        case .speechStartFailed(let message):
            "启动语音识别失败：\(message)"
        case .deepSeekHTTPError(let statusCode, let message):
            "模型请求失败（\(statusCode)）：\(message)"
        case .missingDeepSeekContent:
            "模型没有返回可解析内容。"
        case .invalidDeepSeekResponse:
            "模型返回格式不是有效 JSON。"
        case .invalidDeepSeekResponseWithRaw:
            "模型返回格式不是有效 JSON。"
        case .notificationPermissionDenied:
            "需要通知权限，在重要日期前提醒你。"
        case .calendarPermissionDenied:
            "需要日历权限，把生日写进系统日历。"
        case .reminderPermissionDenied:
            "需要提醒事项权限，把生日提醒写进系统提醒事项。"
        case .eventStoreUnavailable:
            "系统日历服务暂时不可用。"
        case .calendarEventCreationFailed(let message):
            "创建系统日历事件失败：\(message)"
        case .reminderCreationFailed(let message):
            "创建系统提醒事项失败：\(message)"
        case .unsupportedTool(let value):
            "暂不支持这个操作：\(value)"
        case .missingASRConfiguration(let message):
            message
        case .invalidToolParameters(let message):
            message
        }
    }
}

final class SpeechService {
    private final class ConverterInputState: @unchecked Sendable {
        nonisolated(unsafe) var hasData = true
    }

    deinit {
        print("[SpeechService] deinit 被调用！")
    }
    nonisolated(unsafe) private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    // 现代 iOS 26+ 语音识别属性 (使用 Any? 进行类型擦除，以确保在最低部署目标 iOS 18 下能正常编译)
    private var activeAnalyzer: Any?
    private var activeTranscriber: Any?
    private var activeTask: Task<Void, Never>?
    private var activeAnalysisTask: Task<Void, Never>?
    private var activeInputBuilder: Any?

    // 降级与缓存控制属性
    private let lock = NSLock()
    private var isUsingLegacy = false
    private var hasReceivedTranscript = false
    private var rawAudioBuffers: [AVAudioPCMBuffer] = []
    private var fallbackCheckTask: Task<Void, Never>?
    private var onTranscriptHandler: (@MainActor (String, Bool) -> Void)?
    private var onVolumeChangedHandler: (@MainActor (Float) -> Void)?

    private func withLockedState<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func resetFallbackState() {
        withLockedState {
            isUsingLegacy = false
            hasReceivedTranscript = false
            rawAudioBuffers.removeAll()
        }
    }

    private func setUsingLegacy(_ value: Bool) {
        withLockedState {
            isUsingLegacy = value
        }
    }

    private func needsModernFallback() -> Bool {
        withLockedState {
            !hasReceivedTranscript && !isUsingLegacy
        }
    }

    @available(iOS 26.0, *)
    private func setActiveInputBuilder(_ builder: AsyncStream<AnalyzerInput>.Continuation) {
        withLockedState {
            activeInputBuilder = builder
        }
    }

    private func appendRawAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        withLockedState {
            rawAudioBuffers.append(buffer)
            if rawAudioBuffers.count > 30 {
                rawAudioBuffers.removeFirst()
            }
        }
    }

    @available(iOS 26.0, *)
    private func currentRecognitionState() -> (
        useLegacy: Bool,
        legacyRequest: SFSpeechAudioBufferRecognitionRequest?,
        builder: AsyncStream<AnalyzerInput>.Continuation?
    ) {
        withLockedState {
            (
                isUsingLegacy,
                recognitionRequest,
                activeInputBuilder as? AsyncStream<AnalyzerInput>.Continuation
            )
        }
    }

    private func markTranscriptReceived() {
        withLockedState {
            hasReceivedTranscript = true
        }
    }

    private func beginLegacyFallback() -> [AVAudioPCMBuffer]? {
        withLockedState {
            guard !isUsingLegacy else { return nil }
            isUsingLegacy = true
            return rawAudioBuffers
        }
    }

    @available(iOS 26.0, *)
    private func clearModernRecognitionState() {
        withLockedState {
            if let builder = activeInputBuilder as? AsyncStream<AnalyzerInput>.Continuation {
                builder.finish()
            }
            activeInputBuilder = nil
            activeAnalyzer = nil
            activeTranscriber = nil
        }
    }

    private func setRecognitionRequest(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        withLockedState {
            recognitionRequest = request
        }
    }

    @MainActor
    func warmup() {
        _ = self.recognizer
        _ = self.audioEngine.inputNode
        if #available(iOS 26.0, *) {
            Task {
                _ = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "zh-CN"))
            }
        }
    }

    @MainActor
    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onVolumeChanged: @escaping @MainActor (Float) -> Void
    ) async throws {
        guard await Self.requestSpeechAuthorization() else {
            throw JotlyError.speechPermissionDenied
        }
        guard await Self.requestMicrophonePermission() else {
            throw JotlyError.microphonePermissionDenied
        }

        self.onTranscriptHandler = onTranscript
        self.onVolumeChangedHandler = onVolumeChanged
        
        resetFallbackState()

        do {
            try configureAudioSession()
            
            var startedModern = false
            if #available(iOS 26.0, *) {
                let locale = Locale(identifier: "zh-CN")
                if await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil {
                    do {
                        JotlyLog.speech.info("采用 SpeechAnalyzer 实时流式识别")
                        try await startModernRecognition(onTranscript: onTranscript)
                        startedModern = true
                        
                        // 启动 1.5 秒超时降级检测任务
                        self.fallbackCheckTask = Task { [weak self] in
                            try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5 秒
                            guard let self else { return }
                            await MainActor.run {
                                let needsFallback = self.needsModernFallback()
                                
                                if needsFallback && self.audioEngine.isRunning {
                                    print("[SpeechService] 1.5秒内未收到现代识别结果，触发安全降级机制...")
                                    self.fallbackToLegacy()
                                }
                            }
                        }
                    } catch {
                        JotlyLog.speech.error("SpeechAnalyzer 启动失败: \(error.localizedDescription, privacy: .public)，将降级使用 SFSpeechRecognizer")
                    }
                } else {
                    JotlyLog.speech.info("当前系统 SpeechTranscriber 不支持 zh-CN 语言包，降级到 SFSpeechRecognizer")
                }
            }

            if !startedModern {
                setUsingLegacy(true)
                
                JotlyLog.speech.info("启动 SFSpeechRecognizer 识别方案")
                guard let recognizer, recognizer.isAvailable else {
                    throw JotlyError.speechUnavailable
                }
                try await startLegacyRecognition(using: recognizer, onTranscript: onTranscript)
            }
        } catch {
            throw JotlyError.speechStartFailed(error.localizedDescription)
        }
    }

    @MainActor
    func stop() {
        print("[SpeechService] stop() 被调用")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        fallbackCheckTask?.cancel()
        fallbackCheckTask = nil
        
        resetFallbackState()
        
        // 清理 legacy 资源
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        
        // 清理 modern 资源
        if #available(iOS 26.0, *) {
            stopModernRecognition()
        }
        
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @available(iOS 26.0, *)
    @MainActor
    private func startModernRecognition(onTranscript: @escaping @MainActor (String, Bool) -> Void) async throws {
        stopModernRecognition()

        let locale = Locale(identifier: "zh-CN")
        guard let finalLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw JotlyError.speechUnavailable
        }
        
        // 使用标准的 progressiveTranscription 预设，获取最佳流式效果
        let transcriber = SpeechTranscriber(
            locale: finalLocale,
            preset: .progressiveTranscription
        )
        
        let status = await AssetInventory.status(forModules: [transcriber])
        print("[SpeechService] 语音识别资产状态: \(status)")
        if status != .installed {
            print("[SpeechService] 中文语音识别资产未完整安装 (status: \(status))，安全降级至 SFSpeechRecognizer")
            throw JotlyError.speechUnavailable
        }
        
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            print("[SpeechService] 无法获取 SpeechAnalyzer 支持的音频格式，降级至 SFSpeechRecognizer")
            throw JotlyError.speechUnavailable
        }
        print("[SpeechService] SpeechAnalyzer 目标音频格式: \(targetFormat)")

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.activeTranscriber = transcriber
        self.activeAnalyzer = analyzer

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        print("[SpeechService] 麦克风录音格式: \(recordingFormat)")
        inputNode.removeTap(onBus: 0)
        
        guard let converter = AVAudioConverter(from: recordingFormat, to: targetFormat) else {
            print("[SpeechService] 无法从 \(recordingFormat) 转换到 \(targetFormat)，将安全降级至 SFSpeechRecognizer")
            throw JotlyError.speechUnavailable
        }
        
        // 构造流式输入队列
        let (inputSequence, inputBuilder) = AsyncStream.makeStream(of: AnalyzerInput.self)
        setActiveInputBuilder(inputBuilder)
        
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            guard let self else { return }
            
            // 计算音量振幅并通知主线程
            let level = SpeechService.calculateLevel(from: buffer)
            Task { @MainActor in
                self.onVolumeChangedHandler?(level)
            }

            // 1. 复制音频帧并加入缓存队列 (用于可能发生的降级)
            if let copy = buffer.copyBuffer() {
                self.appendRawAudioBuffer(copy)
            }
            
            // 2. 检查当前是否已经降级到 legacy
            let state = self.currentRecognitionState()
            let useLegacy = state.useLegacy
            let legacyRequest = state.legacyRequest
            let builder = state.builder
            
            if useLegacy {
                legacyRequest?.append(buffer)
            } else {
                let ratio = Float(targetFormat.sampleRate) / Float(recordingFormat.sampleRate)
                let capacity = AVAudioFrameCount(Float(buffer.frameCapacity) * ratio)
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                    print("[SpeechService] 无法创建目标大小的 AVAudioPCMBuffer")
                    return
                }
                
                let inputState = ConverterInputState()
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    if inputState.hasData {
                        outStatus.pointee = .haveData
                        inputState.hasData = false
                        return buffer
                    } else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                }
                
                var error: NSError?
                let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)
                if status == .error {
                    print("[SpeechService] 音频格式转换失败: \(String(describing: error))")
                } else {
                    builder?.yield(AnalyzerInput(buffer: convertedBuffer))
                }
            }
        }
        
        audioEngine.prepare()
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try self?.audioEngine.start()
        }.value
        print("[SpeechService] AudioEngine 成功启动，开始输入流...")
        
        // 开启 Swift Concurrency 异步迭代，实时获取 partial results / final results
        let transcriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                print("[SpeechService] 监听 transcriber.results 异步迭代...")
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.isFinal
                    print("[SpeechService] 收到转写文字: '\(text)', isFinal: \(isFinal)")
                    
                    if !text.isEmpty {
                        self.markTranscriptReceived()
                        onTranscript(text, isFinal)
                    }
                }
                print("[SpeechService] transcriber.results 迭代结束")
            } catch {
                print("[SpeechService] SpeechTranscriber 流式获取失败: \(error.localizedDescription)")
            }
        }
        
        self.activeTask = transcriptionTask
        
        // 开启分析引擎处理流式输入
        let analysisTask = Task {
            do {
                print("[SpeechService] 启动 SpeechAnalyzer.analyzeSequence...")
                let _ = try await analyzer.analyzeSequence(inputSequence)
                print("[SpeechService] SpeechAnalyzer.analyzeSequence 正常结束")
            } catch {
                print("[SpeechService] SpeechAnalyzer 结束运行，出现错误: \(error.localizedDescription)")
            }
        }
        self.activeAnalysisTask = analysisTask
    }

    @available(iOS 26.0, *)
    @MainActor
    private func fallbackToLegacy() {
        guard let buffersToFeed = beginLegacyFallback() else { return }
        
        print("[SpeechService] 正在降级到 SFSpeechRecognizer...")
        
        // 1. 停止现代识别任务 (不停止 audioEngine 录音，防止噪音或中断)
        activeTask?.cancel()
        activeTask = nil
        activeAnalysisTask?.cancel()
        activeAnalysisTask = nil
        
        clearModernRecognitionState()
        
        // 2. 初始化 SFSpeechRecognizer
        guard let recognizer, recognizer.isAvailable else {
            print("[SpeechService] 降级失败：SFSpeechRecognizer 不可用")
            self.onTranscriptHandler?("", true)
            return
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = false
        
        setRecognitionRequest(request)
        
        // 3. 喂入缓存的音频帧 (保持用户说话内容的完整性)
        print("[SpeechService] 喂入缓存的音频帧数量: \(buffersToFeed.count)")
        for buffer in buffersToFeed {
            request.append(buffer)
        }
        
        // 4. 开启 legacy 任务
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    let text = result.bestTranscription.formattedString
                    print("[SpeechService] [Legacy] 收到转写文字: '\(text)', isFinal: \(result.isFinal)")
                    self.onTranscriptHandler?(text, result.isFinal)
                }
            }
            if error != nil {
                Task { @MainActor in
                    self.onTranscriptHandler?("", true)
                }
            }
        }
    }

    @available(iOS 26.0, *)
    @MainActor
    private func stopModernRecognition() {
        print("[SpeechService] stopModernRecognition() 被调用")
        activeTask?.cancel()
        activeTask = nil
        
        activeAnalysisTask?.cancel()
        activeAnalysisTask = nil
        
        if let builder = activeInputBuilder as? AsyncStream<AnalyzerInput>.Continuation {
            builder.finish()
        }
        activeInputBuilder = nil
        
        activeAnalyzer = nil
        activeTranscriber = nil
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        #if os(iOS)
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        #endif
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    @MainActor
    private func startLegacyRecognition(
        using recognizer: SFSpeechRecognizer,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) async throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
            request?.append(buffer)
            
            // 计算音量振幅并通知主线程
            if let self {
                let level = SpeechService.calculateLevel(from: buffer)
                Task { @MainActor in
                    self.onVolumeChangedHandler?(level)
                }
            }
        }

        audioEngine.prepare()
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try self?.audioEngine.start()
        }.value

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                Task { @MainActor in
                    onTranscript(result.bestTranscription.formattedString, result.isFinal)
                }
            }

            if error != nil {
                Task { @MainActor in
                    onTranscript("", true)
                }
            }
        }
    }

    private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private static func requestMicrophonePermission() async -> Bool {
        if #available(iOS 17.0, *) {
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelVal = channelData[0]
        let frameLength = Int(buffer.frameLength)
        if frameLength == 0 { return 0 }
        
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelVal[i]
            sum += sample * sample
        }
        
        let rms = sqrt(sum / Float(frameLength))
        // 使用非线性映射 (例如平方根) 放大微小音量，让音量振幅变化更加敏感和活跃
        let scaled = sqrt(rms) * 4.5
        return min(max(scaled, 0.0), 1.0)
    }
}

struct LegacyDeepSeekClient {
    private let deepSeekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private let dashScopeEndpoint = URL(string: "https://llm-kxzzc9bbhvuvw4e9.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!
    private let mimoEndpoint = URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!

    func debugPrompt(
        text: String,
        latestCardStatus: CardStatus,
        currentDate: String,
        model: LifeAgentLLMModel = .deepseekV4Pro,
        supplementalText: String? = nil,
        imageInputMode: ImageInputMode? = nil
    ) -> (systemPrompt: String, userPrompt: String, fullPrompt: String) {
        let userPrompt = Self.userContent(
            text: text,
            supplementalText: supplementalText,
            currentDate: currentDate,
            latestCardStatus: latestCardStatus,
            imageInputMode: imageInputMode
        )
        let sysPrompt = Self.resolvedSystemPrompt(for: text)
        return (
            sysPrompt,
            userPrompt,
            Self.fullPrompt(systemPrompt: sysPrompt, userPrompt: userPrompt)
        )
    }

    func analyze(
        text: String,
        latestCardStatus: CardStatus,
        currentDate: String,
        model: LifeAgentLLMModel = .deepseekV4Pro,
        supplementalText: String? = nil,
        imageInputMode: ImageInputMode? = nil
    ) async throws -> AgentAnalysis {
        try await analyzeWithDebug(
            text: text,
            latestCardStatus: latestCardStatus,
            currentDate: currentDate,
            model: model,
            supplementalText: supplementalText,
            imageInputMode: imageInputMode
        ).analysis
    }

    func analyzeWithDebug(
        text: String,
        latestCardStatus: CardStatus,
        currentDate: String,
        model selectedModel: LifeAgentLLMModel = .deepseekV4Pro,
        supplementalText: String? = nil,
        imageAttachment: ImageAttachment? = nil,
        imageAttachments: [ImageAttachment] = [],
        imageInputMode: ImageInputMode? = nil
    ) async throws -> DeepSeekDebugResponse {
        let attachments = Self.imageAttachmentsWithLegacy(imageAttachment, imageAttachments)
        let userPrompt = Self.userContent(
            text: text,
            supplementalText: supplementalText,
            currentDate: currentDate,
            latestCardStatus: latestCardStatus,
            imageInputMode: imageInputMode
        )
        let sysPrompt = Self.resolvedSystemPrompt(for: text)
        let messages = Self.buildMessages(
            systemPrompt: sysPrompt,
            userPrompt: userPrompt,
            imageAttachments: attachments,
            supportsImageInput: selectedModel.supportsDirectImageInput && !attachments.isEmpty
        )

        var request = URLRequest(url: endpoint(for: selectedModel))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey(for: selectedModel))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeepSeekRequest(
                model: selectedModel.rawValue,
                messages: messages,
                responseFormat: responseFormat(for: selectedModel),
                temperature: 0.2,
                stream: false,
                enableThinking: enableThinking(for: selectedModel)
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw JotlyError.deepSeekHTTPError(
                httpResponse.statusCode,
                Self.responseSummary(from: data)
            )
        }

        let envelope = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
        guard let content = envelope.choices.first?.message.bestContent else {
            throw JotlyError.missingDeepSeekContent
        }
        guard let jsonData = Self.jsonObjectData(from: content) else {
            throw JotlyError.invalidDeepSeekResponseWithRaw(content)
        }
        do {
            let analysis = try JSONDecoder().decode(AgentAnalysis.self, from: jsonData)
            return DeepSeekDebugResponse(
                analysis: analysis,
                systemPrompt: sysPrompt,
                userPrompt: userPrompt,
                fullPrompt: Self.fullPrompt(systemPrompt: sysPrompt, userPrompt: userPrompt),
                modelName: selectedModel.rawValue,
                rawModelOutput: content,
                usage: envelope.usage,
                estimatedCostCNY: selectedModel.estimatedCost(using: envelope.usage)
            )
        } catch {
            JotlyLog.deepSeek.error("JSONDecoder decoding AgentAnalysis failed: \(error, privacy: .public)")
            throw JotlyError.invalidDeepSeekResponseWithRaw(content)
        }
    }

    private func endpoint(for model: LifeAgentLLMModel) -> URL {
        switch model {
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking:
            deepSeekEndpoint
        case .qwen37Plus, .qwen36Flash, .qwen35Flash:
            dashScopeEndpoint
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            mimoEndpoint
        }
    }

    private func apiKey(for model: LifeAgentLLMModel) -> String {
        switch model {
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking:
            JotlySecrets.deepSeekAPIKey
        case .qwen37Plus, .qwen36Flash, .qwen35Flash:
            JotlySecrets.dashScopeAPIKey
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            JotlySecrets.mimoLLMAPIKey
        }
    }

    private func enableThinking(for model: LifeAgentLLMModel) -> Bool? {
        switch model {
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking:
            nil
        case .qwen37Plus, .qwen36Flash, .qwen35Flash:
            true
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            nil
        }
    }

    private func responseFormat(for model: LifeAgentLLMModel) -> DeepSeekResponseFormat? {
        switch model {
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            return nil
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking, .qwen37Plus, .qwen36Flash, .qwen35Flash:
            return .init(type: "json_object")
        }
    }

    private static func jsonObjectData(from content: String) -> Data? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        let withoutFence = trimmed
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```JSON", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = withoutFence.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        return firstValidJSONObjectData(in: withoutFence)
    }

    private static func firstValidJSONObjectData(in text: String) -> Data? {
        let characters = Array(text)
        var startIndex: Int?
        var depth = 0
        var inString = false
        var isEscaped = false

        for index in characters.indices {
            let character = characters[index]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            if character == "\"" {
                inString = true
                continue
            }

            if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                guard depth > 0 else { continue }
                depth -= 1
                if depth == 0, let start = startIndex {
                    let candidate = String(characters[start...index])
                    if let data = candidate.data(using: .utf8),
                       (try? JSONSerialization.jsonObject(with: data)) != nil {
                        return data
                    }
                    startIndex = nil
                }
            }
        }
        return nil
    }

    private static func fullPrompt(systemPrompt: String, userPrompt: String) -> String {
        """
        [system]
        \(systemPrompt)

        [user]
        \(userPrompt)
        """
    }

    private static func userContent(
        text: String,
        supplementalText: String?,
        currentDate: String,
        latestCardStatus: CardStatus,
        imageInputMode: ImageInputMode?
    ) -> String {
        let referenceDate = DateFormatting.date(fromDayString: currentDate)
        var parts = [
            "用户输入：\(text)",
            "用户输入时间：\(DateFormatting.userRequestDateTimeString(currentDateString: currentDate))",
            "当前农历日期：\(DateFormatting.lunarDateString(from: referenceDate))",
            "当前卡片状态：\(latestCardStatus.rawValue)"
        ]
        if let imageInputMode {
            parts.append("图片输入方式：\(imageInputMode.title)")
        }
        if let supplementalText, !supplementalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("补充信息：\(supplementalText)")
        }
        return parts.joined(separator: "\n")
    }

    private static func imageAttachmentsWithLegacy(
        _ imageAttachment: ImageAttachment?,
        _ imageAttachments: [ImageAttachment]
    ) -> [ImageAttachment] {
        if !imageAttachments.isEmpty { return imageAttachments }
        return imageAttachment.map { [$0] } ?? []
    }

    private static func buildMessages(
        systemPrompt: String,
        userPrompt: String,
        imageAttachments: [ImageAttachment],
        supportsImageInput: Bool
    ) -> [DeepSeekMessage] {
        var messages = [DeepSeekMessage(role: "system", content: .text(systemPrompt))]
        if supportsImageInput, !imageAttachments.isEmpty {
            messages.append(
                DeepSeekMessage(
                    role: "user",
                    content: .parts([.text(userPrompt)] + imageAttachments.map { .image(url: $0.dataURL) })
                )
            )
        } else {
            messages.append(DeepSeekMessage(role: "user", content: .text(userPrompt)))
        }
        return messages
    }

    private static func responseSummary(from data: Data) -> String {
        guard !data.isEmpty else { return "响应为空" }
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any]
        {
            let message = error["message"] as? String
            let type = error["type"] as? String
            return [type, message]
                .compactMap { $0 }
                .joined(separator: " / ")
        }
        return String(decoding: data.prefix(240), as: UTF8.self)
    }

    private static let systemPrompt = """
    你是「随心记」里的生活 Agent。

    你的任务不是被动记录用户说过的话，而是认真理解用户随口丢进来的生活碎片，判断其中是否存在可记录、可提醒、可统计、可回看、可执行、可沉淀为记忆的价值。

    你要像一个克制、可靠、有生活感的整理者：想得比用户多一步，但不要多打扰用户一步。

    你的最高原则是：
    想得深，说得短；主动发现，谨慎执行；默认记录，打扰前确认；有温度，但不油腻。

    ---

    ## 一、你的核心职责与调用主体
    所有的系统写入操作都通过 App 后台与 iOS 系统的数据库交互。你的职责是解析语义，构造交互卡片（Card）呈现在交互窗口给用户，并在用户确认（Actions）后指示 App 调用底层工具写入系统。
    
    你主要控制的是两个层面：
    1. 页面卡片窗口（Card）：在这个窗口中决策给用户展示什么、提供什么选择。
    2. 工具调用指令（Tool Plans）：当用户确认某项动作时，App 将执行的底层数据库写入指令。

    ---

    ## 二、你不是聊天机器人
    你不是陪用户长聊的聊天机器人。
    你更像一个手机端生活整理 Agent。
    用户说一句话、拍一张图、丢进一个碎片，你要尽量把它整理成：
    * 一张卡片；
    * 一条记录；
    * 一个提醒建议；
    * 一个打卡统计；
    * 一个订阅记录；
    * 一条可回看的生活记忆。
    你的回复不应该像聊天机器人一样长篇解释。
    卡片文案要短、准、自然。

    ---

    ## 三、直接执行与确认执行规范
    - **直接静默执行 (tool_plan)**：仅在动作低风险且关键参数完整时使用。此时 `should_execute_now` 为 `true`，`requires_confirmation` 为 `false`。
    - **确认后执行 (options[].actions 或 action_buttons[].actions)**：对于中高风险动作（如创建生日、缴费等日程/提醒事项），你必须在卡片选项（options）或辅助按钮（action_buttons）中挂载相应的 actions，并设置 `requires_confirmation = true`。用户点击后，由 App 提取对应动作的 parameters 并执行。
    - **结果卡片规范 (result_card)**：每个卡片选项 (options) 或辅助按钮 (action_buttons) **必须** 挂载一个 `"result_card"` 结构，并在其中指定 `message` 参数。当用户做出相应选择后，客户端将直接显示此 `message`，**大模型必须通过此字段来对每一条可能的分支生成拟人化、贴心、精准的完成话术，客户端本身绝不生成任何温情问候或提示文案**。

    ---

    ## 四、禁止静默默认原则（消除人机代差）
    - **禁止替用户做默认假设**：当用户未明确指出历法（阳历/农历）或周期（单次/每天重复）时，**绝不能静默默认**。例如，用户说“记个张三生日”，不能默认成“只记一次”或“阳历生日”。
    - **必须在卡片选项中列出清晰的决策路径**：
      - **生日提醒**：必须在选项中明确列出“每年农历提醒”（挂载 `create_lunar_birthday_reminder`）、“每年阳历提醒”（挂载 `create_solar_birthday_reminder`）以及“仅作备忘记录，不设提醒”（挂载 `memory.save`）。并且，为了提供多维度提前时间选择，阳历与农历选项的 `action_buttons` 中必须包含「提前3天」与「提前6天」两个辅助按钮，具体参考下文协议。
      - **日常/习惯提醒**：如果用户想记个提醒但没说明频率，必须在选项中列出“每天重复提醒”（挂载 `reminder.create`，`repeat_rule: "daily"`）、“仅提醒这一次”（挂载 `reminder.create`，`repeat_rule: "once"`）、“仅作备忘记录”（挂载 `memory.save`）。
      - 如果所有关键参数齐全（用户明确指出了日期、周期、历法），则可以直接提供“同意创建”与“仅记录”。

    ---

    ## 五、文案风格与备注 (Note) 特别规范
    - **绝对的备注控制权**：App 底层在写入 iOS 日历 (EKEvent) 和提醒事项 (EKReminder) 时，**完全没有任何自动拼接的文案模板**（不会自动添加“来自随心记”等小尾巴）。备注 (note / advance_note / birthday_note) **全部由你完全决定并直接写入**。
    - **备注要求**：必须输出简短、拟人、贴心、有温度的完整中文字符串。绝对不能包含任何 JSON 格式、技术字段名、引号、冒号标签（如“生日日期：”或“备忘：”）。
      - 错误示例：`note: "起飞时间：19:00"` 或 `note: "带身份证，来自随心记"`
      - 正确示例：`note: "晚上七点准时起飞，出发前别忘了仔细检查一下身份证和随身登机牌哦。"`
      - 生日提前提醒备注 (`advance_note`) 示例：`"过几天就是小A的生日了，可以提前准备一个暖心的小惊喜或是一句简单的问候。"`
      - 生日当天日程备注 (`birthday_note`) 示例：`"今天是小A的生日，记得送上最真挚的生日祝福，让这一天充满仪式感。"`
    - **文案要短、准、有一点温度**，拒绝任何套话、空泛的抒情或心理咨询式的长句。不使用“作为 AI”。

    ---

    ## 六、可用工具、边界条件与参数要求
    你只能在 JSON 的 `tool_plan`、`options[].actions` 或 `action_buttons[].actions` 中指定以下工具。切勿臆造工具名。

    1. **`card.ask_user`**
       - **使用场景**：当输入信息不全或需要用户抉择时，用于在界面展示交互卡。
       - **边界条件**：不属于系统写入操作。此时 `requires_confirmation` 必须为 `true`。
       - **参数要求**：无参数。

    2. **`memory.save`** (别名 `record_only`)
       - **使用场景**：保存低风险的普通记录或生活备忘（不创建系统日程 and 提醒）。
       - **参数要求**：
         - `type` (String, 必须): `"record"` 或 `"birthday"`
         - `content` (String, 必须): 记录的具体内容摘要。

    3. **`create_solar_birthday_reminder`** (别名 `reminder.create_solar_birthday`)
       - **使用场景**：创建**每年重复的阳历生日**提醒。
       - **边界条件**：必须在用户明确或通过选项确认是阳历生日时才能调用。
       - **参数要求**：
         - `person_name` (String, 必须): 生日主角称呼（如 `"小A"`、`"妈妈"`）。如果不知道具体名字，使用亲缘或称呼（如 `"朋友"`）。不要包含“的生日”等后缀。
         - `date` (String, 必须): 格式为 `yyyy-MM-dd`（如 `"1995-09-20"`）。如果不知道出生年份，使用当前年份或默认年份。
         - `remind_before_days` (Integer, 必须): 提前几天提醒，默认为 `3`。
         - `advance_note` (String, 必须): 提前提醒时的拟人化备注，需包含“还有几天就生日了” and “准备祝福/小惊喜”语义。
         - `birthday_note` (String, 必须): 生日当天日程的拟人化备注，需包含“今天是生日” and “记得送上祝福”语义。

    4. **`create_lunar_birthday_reminder`** (别名 `reminder.create_lunar_birthday` 或 `lunar_series.create`)
       - **使用场景**：创建**每年重复的阴历/农历生日**提醒。
       - **边界条件**：必须在用户明确或通过选项确认是农历生日时调用。由于 iOS 系统不原生支持农历循环重复日程，App 后台会自动推算未来 5 年的农历日期并批量写入系统日历，你只需要传参，不要自行计算。
       - **参数要求**：
         - `person_name` (String, 必须): 生日主角称呼，不要有“的生日”等后缀。
         - `date` (String, 可选): 用户提到的参考阳历日期 `yyyy-MM-dd`（若无则不传，由后台自动转换）。
         - `lunar_month` (Integer, 必须): 农历月份，必须是 **1 到 12 的阿拉伯数字**（例如 农历五月 传 `5`，不要传 "五" 或 "五月"）。
         - `lunar_day` (Integer, 必须): 农历日期，必须是 **1 到 30 的阿拉伯数字**（例如 农历廿六 传 `26`，不要传 "廿六"）。
         - `is_leap_month` (Boolean, 可选): 是否是农历闰月，默认 `false`。
         - `remind_before_days` (Integer, 必须): 提前几天提醒，默认为 `3`。
         - `advance_note` (String, 必须): 提前提醒的拟人化贴心备注。
         - `birthday_note` (String, 必须): 生日当天日程的拟人化贴心备注。

    5. **`calendar.create_event`**
       - **使用场景**：在 iOS 系统日历中创建单次或重复的**非生日日程事件**（如会议、面试、约会、行程、非生日类纪念日等）。
       - **参数要求**：
         - `title` (String, 必须): 日程的标题（如 `"项目周会"`、`"去体育馆打羽毛球"`）。
         - `date` / `start_date` / `start_at` (String, 必须): 格式必须为 `yyyy-MM-dd`（全天事件）或 `yyyy-MM-dd HH:mm`（指定具体时间）。
         - `time` (String, 可选): 如果用户没明确时间，默认不填（或填 `"12:30"` 以示告知）。
         - `repeat_rule` (String, 必须): 重复规则，可选值为 `"once"`（不重复）| `"daily"`（每天）| `"weekly"`（每周）| `"monthly"`（每月）| `"yearly"`（每年）。
         - `remind_before_days` (Integer, 必须): 提前几天提醒，默认为 `0`。
         - `note` (String, 必须): 拟人化、有温度且和日程相关的完整备注（例如提醒用户打球需要准备哪些装备等）。

    6. **`reminder.create`** (别名 `create_reminder` 或 `create_date_reminder`)
       - **使用场景**：在 iOS 提醒事项中创建**非生日的待办事项提醒**（如“每天吃药”、“今晚交房租”等具有强烈待办属性的事务）。
       - **参数要求**：
         - `title` (String, 必须): 待办事项标题。
         - `date` / `due_at` (String, 必须): 提醒触发的日期时间，格式为 `yyyy-MM-dd` 或 `yyyy-MM-dd HH:mm`。
         - `repeat_rule` (String, 必须): 可选为 `"once"` | `"daily"` | `"weekly"` | `"monthly"` | `"yearly"`。
         - `note` (String, 必须): 拟人化、贴心的提醒备注。

    7. **`family_holiday_reminders.create`**
       - **使用场景**：一键为父母创建“母亲节”和“父亲节”组合的每年循环提醒。
       - **参数要求**：
         - `remind_before_days` (Integer, 必须): 提前几天提醒，默认为 `5`。

    8. **`artifacts.cancel`**
       - **使用场景**：当用户在会话中明确要求“删除”或“取消”之前本会话创建的日历/提醒事项时调用。
       - **参数要求**：无参数。

    9. **`counter.add`**
       - **使用场景**：当用户明确要求计数打卡（如“又喝了一杯咖啡”）时调用。
       - **参数要求**：
         - `category` (String, 必须): 计数类别（如 `"coffee"`）。
         - `name` (String, 必须): 计数的展示名称（如 `"咖啡"`）。
         - `count` (Integer, 必须): 本次累加值，通常为 `1`。

    ---

    ## 七、输出 JSON 协议格式
    你必须且只能输出包含一个符合以下模式的严格 JSON 块，严禁输出多个 JSON 块，严禁重复或拼接相同的 JSON 块，严禁在 JSON 之外输出任何 Markdown 标记或解释文字。
    {
      "intent": "string",
      "risk_level": "low | medium | high",
      "requires_confirmation": true,
      "should_execute_now": false,
      "reasoning": "私有推理空间，思考是否信息齐备、是否有历法/周期代差等",
      "card": {
        "type": "birthday | date_task | counter | receipt | subscription | reminder | note | record | unknown",
        "title": "卡片标题",
        "summary": "简短的一句摘要",
        "message": "在卡片上向用户显示的话，要精简且有温度，不要有客服腔或空套话",
        "options": [
          {
            "key": "A",
            "label": "暂不创建",
            "value": "record_only",
            "description": "仅记录在本地备忘，不写入系统提醒",
            "next_step": "finish",
            "actions": [
              {
                "tool": "memory.save",
                "when": "now",
                "params": {
                  "type": "birthday",
                  "content": "记录生日备忘"
                }
              }
            ]
          },
          {
            "key": "B",
            "label": "创建阳历生日提醒",
            "value": "create_solar_birthday_reminder",
            "description": "每年按阳历重复提醒我",
            "next_step": "finish",
            "action_buttons": [
              {
                "label": "提前3天",
                "value": "solar_3_days",
                "next_step": "finish",
                "actions": [
                  {
                    "tool": "create_solar_birthday_reminder",
                    "when": "now",
                    "params": {
                      "person_name": "朋友小孩",
                      "date": "2026-06-23",
                      "remind_before_days": 3,
                      "advance_note": "过几天就是朋友小孩的阳历生日了，可以提前准备一个暖心的小礼物哦。",
                      "birthday_note": "今天是朋友小孩的阳历生日，记得送上最真挚的祝福。"
                    }
                  }
                ]
              },
              {
                "label": "提前6天",
                "value": "solar_6_days",
                "next_step": "finish",
                "actions": [
                  {
                    "tool": "create_solar_birthday_reminder",
                    "when": "now",
                    "params": {
                      "person_name": "朋友小孩",
                      "date": "2026-06-23",
                      "remind_before_days": 6,
                      "advance_note": "还有不到一周就是朋友小孩的阳历生日了，别忘了提前准备礼物和祝福哦。",
                      "birthday_note": "今天是朋友小孩的阳历生日，记得送上暖心的祝福。"
                    }
                  }
                ]
              }
            ]
          }
        ]
      },
      "tool_plan": [
        {
          "tool": "memory.save",
          "when": "now",
          "params": {
            "type": "record",
            "content": "用户提到今天又喝了一杯拿铁"
          }
        }
      ],
      "memory_to_save": [
        {
          "type": "string",
          "content": "string"
        }
      ],
      "user_visible_text": "在气泡中展现的一句话，需贴心精简"
    }
    """

    private static func resolvedSystemPrompt(for text: String) -> String {
        if text.contains("生日") {
            return systemPrompt + "\n\n" + birthdaySkillPrompt
        }
        return systemPrompt
    }

    private static let birthdaySkillPrompt = """
    ## 生日提醒专项技能 (Birthday Reminder Skill)

    这段技能会在文本里出现“生日”时自动加载。最终要要不要当成生日提醒、要不要创建系统日程，仍然由你根据用户整句话自主判断。

    ### 核心交互、工具映射与硬规范要求：
    1. **主角称呼**：如果用户说“我朋友小孩生日”，这已足够作为主角称呼（如 `person_name: "朋友小孩"` 或 `person_name: "朋友的小孩"`），不要追问具体姓名。
    2. **防静默默认与选项硬规范**：
       - 当用户没有明确说“阳历/阳历生日”或“农历/阴历生日”时，卡片必须返回三个明确的主选项：
         - A 选项：暂不创建（挂载 `memory.save`，`value: "record_only"`）。
         - B 选项：创建阳历生日提醒（挂载 `create_solar_birthday_reminder`）。
         - C 选项：创建农历生日提醒（挂载 `create_lunar_birthday_reminder`）。
       - **必须包含 action_buttons**：主选项 B 和 C 的属性中，**必须**挂载 `action_buttons` 以提供天数决策按钮：
         - 第一个 action_button：标签为“提前3天”，`value` 为“solar_3_days”/“lunar_3_days”，挂载参数含 `"remind_before_days": 3` 的 `create_solar_birthday_reminder` / `create_lunar_birthday_reminder`。
         - 第二个 action_button：标签为“提前6天”，`value` 为“solar_6_days”/“lunar_6_days”，挂载参数含 `"remind_before_days": 6` 的 `create_solar_birthday_reminder` / `create_lunar_birthday_reminder`。
       - 如果用户在话中明确指出了提前天数，则可以不提供 `action_buttons`，直接在选项的 `actions` 中传入对应的参数即可。
    3. **备注的拟人化备注控制**：
       - 系统创建日程与提醒的备注文字完全由你输入的 `advance_note` 和 `birthday_note` 参数控制，App 底层不会做任何字面上的自动拼接（无“来自随心记”等小尾巴）。
       - 必须生成完整的拟人化温情备注，包含提前准备和当天祝福的真实文案。

    ### 生日选项 JSON 示例（核心硬规范模板）：
    ```json
    "options": [
      {
        "key": "A",
        "label": "仅记录",
        "value": "record_only",
        "description": "仅保存为本地普通记录",
        "next_step": "finish",
        "actions": [
          {
            "tool": "memory.save",
            "when": "now",
            "params": {
              "type": "birthday",
              "content": "我朋友小孩今天生日"
            }
          }
        ],
        "result_card": {
          "message": "已为你记在本地备忘中。"
        }
      },
      {
        "key": "B",
        "label": "创建阳历生日提醒",
        "value": "create_solar_birthday_reminder",
        "description": "每年按阳历重复提醒我",
        "next_step": "finish",
        "action_buttons": [
          {
            "label": "提前3天",
            "value": "solar_3_days",
            "next_step": "finish",
            "actions": [
              {
                "tool": "create_solar_birthday_reminder",
                "when": "now",
                "params": {
                  "person_name": "朋友小孩",
                  "date": "2026-06-23",
                  "remind_before_days": 3,
                  "advance_note": "再过几天就是朋友小孩的阳历生日了，可以提前准备一个暖心的小礼物哦。",
                  "birthday_note": "今天是朋友小孩的阳历生日，记得送上最真挚的祝福。"
                }
              }
            ],
            "result_card": {
              "message": "阳历生日提醒已创建。我会在每年阳历6月23日提前3天提醒你哦。"
            }
          },
          {
            "label": "提前6天",
            "value": "solar_6_days",
            "next_step": "finish",
            "actions": [
              {
                "tool": "create_solar_birthday_reminder",
                "when": "now",
                "params": {
                  "person_name": "朋友小孩",
                  "date": "2026-06-23",
                  "remind_before_days": 6,
                  "advance_note": "还有不到一周就是朋友小孩的阳历生日了，别忘了提前准备礼物和祝福哦。",
                  "birthday_note": "今天是朋友小孩的阳历生日，记得送上暖心的祝福。"
                }
              }
            ],
            "result_card": {
              "message": "阳历生日提醒已创建。我会在每年阳历6月23日提前6天提醒你哦。"
            }
          }
        ]
      },
      {
        "key": "C",
        "label": "创建农历生日提醒",
        "value": "create_lunar_birthday_reminder",
        "description": "每年按农历重复提醒我",
        "next_step": "finish",
        "action_buttons": [
          {
            "label": "提前3天",
            "value": "lunar_3_days",
            "next_step": "finish",
            "actions": [
              {
                "tool": "create_lunar_birthday_reminder",
                "when": "now",
                "params": {
                  "person_name": "朋友小孩",
                  "lunar_month": 5,
                  "lunar_day": 8,
                  "remind_before_days": 3,
                  "advance_note": "再过几天就是朋友小孩的农历生日了，可以提前准备一个暖心的小礼物哦。",
                  "birthday_note": "今天是朋友小孩的农历生日，记得送上最真挚的祝福。"
                }
              }
            ],
            "result_card": {
              "message": "农历生日提醒已创建。我会在每年农历五月八日提前3天提醒你哦。"
            }
          },
          {
            "label": "提前6天",
            "value": "lunar_6_days",
            "next_step": "finish",
            "actions": [
              {
                "tool": "create_lunar_birthday_reminder",
                "when": "now",
                "params": {
                  "person_name": "朋友小孩",
                  "lunar_month": 5,
                  "lunar_day": 8,
                  "remind_before_days": 6,
                  "advance_note": "还有不到一周就是朋友小孩的农历生日了，别忘了提前准备礼物和祝福哦。",
                  "birthday_note": "今天是朋友小孩的农历生日，记得送上暖心的祝福。"
                }
              }
            ],
            "result_card": {
              "message": "农历生日提醒已创建。我会在每年农历五月八日提前6天提醒你哦。"
            }
          }
        ]
      }
    ]
    ```
    """
}

enum LegacyLocalBirthdayParser {
    static func analysis(from text: String, currentDate: String) -> AgentAnalysis {
        guard looksDateRelated(text) else {
            return AgentAnalysis.recordFallback(originalText: text)
        }

        guard looksLikeBirthday(text) else {
            return dateFallback(from: text, currentDate: currentDate)
        }

        let remindBeforeDays = extractRemindBeforeDays(from: text) ?? 3
        if let calendarType = extractCalendarType(from: text) {
            return birthdayResolved(
                originalText: text,
                currentDate: currentDate,
                personName: extractPersonName(from: text),
                calendarType: calendarType,
                remindBeforeDays: remindBeforeDays
            )
        }

        return AgentAnalysis.birthdayFallback(
            originalText: text,
            currentDate: currentDate,
            personName: extractPersonName(from: text),
            remindBeforeDays: remindBeforeDays
        )
    }

    static func looksDateRelated(_ text: String) -> Bool {
        if looksLikeBirthday(text) {
            return true
        }
        if containsExplicitDate(text) {
            return true
        }

        let dateIntentKeywords = [
            "提醒", "记得", "别忘", "别忘了", "忘记", "老是忘", "总忘", "日程", "日历", "安排", "约会", "会议", "纪念日", "截止", "到期",
            "今天", "明天", "后天", "大后天", "下周", "下个月", "周一", "周二", "周三", "周四", "周五", "周六", "周日",
            "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期天", "星期日",
            "农历", "阴历", "阳历", "公历", "每天", "每日", "每年", "每月", "每周", "提前"
        ]
        return dateIntentKeywords.contains { text.localizedStandardContains($0) }
    }

    private static func dateFallback(from text: String, currentDate: String) -> AgentAnalysis {
        let resolvedDate = resolvedDateString(from: text, currentDate: currentDate)
        let potentialNeed = !text.localizedStandardContains("提醒") && !text.localizedStandardContains("记得")
        let message: String
        if potentialNeed {
            message = "听起来这件事容易被忘掉。我可以每天在一个合适的时间提醒你，要不要让我来安排？"
        } else if resolvedDate == nil {
            message = "我知道你想让我提醒这件事，但还缺具体时间。默认我可以先按今天 12:30 来提醒，你也可以补充更准确的时间。"
        } else {
            message = "我可以按你说的时间提醒你。请确认后，我再写入系统提醒。"
        }
        return AgentAnalysis.dateFallback(
            originalText: text,
            currentDate: currentDate,
            resolvedDate: resolvedDate,
            title: "日期提醒",
            message: message
        )
    }

    private static func looksLikeBirthday(_ text: String) -> Bool {
        let birthdayKeywords = ["生日", "生辰", "寿辰", "过生日"]
        return birthdayKeywords.contains { text.localizedStandardContains($0) }
    }

    private static func containsExplicitDate(_ text: String) -> Bool {
        let patterns = [
            #"(?:(?:\d{1,2})|[一二三四五六七八九十]{1,3})\s*[月]\s*(?:(?:\d{1,2})|[一二三四五六七八九十]{1,3})\s*[日号]?"#,
            #"(?:(?:\d{1,2})|[一二三四五六七八九十]{1,3})\s*[日号]"#,
            #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}"#
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static func resolvedDateString(from text: String, currentDate: String) -> String? {
        if let monthDay = resolveMonthDay(from: text, currentDate: currentDate) {
            return DateFormatting.string(from: monthDay)
        }
        if text.localizedStandardContains("明天") {
            let date = Calendar.current.date(byAdding: .day, value: 1, to: DateFormatting.date(fromDayString: currentDate))
            return date.map { DateFormatting.string(from: $0) }
        }
        if text.localizedStandardContains("后天") {
            let date = Calendar.current.date(byAdding: .day, value: 2, to: DateFormatting.date(fromDayString: currentDate))
            return date.map { DateFormatting.string(from: $0) }
        }
        if text.localizedStandardContains("今天") {
            return currentDate
        }
        return nil
    }

    private static func resolveMonthDay(from text: String, currentDate: String) -> Date? {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})[日号]?"#) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              match.numberOfRanges > 2,
              let monthRange = Range(match.range(at: 1), in: normalized),
              let dayRange = Range(match.range(at: 2), in: normalized),
              let month = Int(normalized[monthRange]),
              let day = Int(normalized[dayRange])
        else {
            return nil
        }

        let base = DateFormatting.date(fromDayString: currentDate)
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: base)
        for year in [currentYear, currentYear + 1] {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = 12
            components.minute = 30
            if let date = calendar.date(from: components), date >= base {
                return date
            }
        }
        return nil
    }

    private static func extractCalendarType(from text: String) -> BirthdayCalendarType? {
        if text.localizedStandardContains("阴历") || text.localizedStandardContains("农历") {
            return .lunar
        }
        if text.localizedStandardContains("阳历") || text.localizedStandardContains("公历") {
            return .solar
        }
        return nil
    }

    private static func extractRemindBeforeDays(from text: String) -> Int? {
        let normalized = text.replacingOccurrences(of: " ", with: "")

        let digitPatterns = [
            "提前(\\d+)天": 1,
            "提前(\\d+)周": 7
        ]
        for (pattern, multiplier) in digitPatterns {
            if let value = matchInt(in: normalized, pattern: pattern) {
                return value * multiplier
            }
        }

        let chineseDayMap: [String: Int] = [
            "一天": 1, "两天": 2, "三天": 3, "四天": 4, "五天": 5,
            "六天": 6, "七天": 7, "八天": 8, "九天": 9, "十天": 10
        ]
        for (token, value) in chineseDayMap {
            if normalized.localizedStandardContains("提前\(token)") {
                return value
            }
        }

        if normalized.localizedStandardContains("一周") {
            return 7
        }
        if normalized.localizedStandardContains("两周") {
            return 14
        }

        return nil
    }

    private static func matchInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    private static func birthdayResolved(
        originalText: String,
        currentDate: String,
        personName: String,
        calendarType: BirthdayCalendarType,
        remindBeforeDays: Int
    ) -> AgentAnalysis {
        let actionValue = calendarType == .solar
            ? "create_solar_birthday_reminder"
            : "create_lunar_birthday_reminder"

        return AgentAnalysis(
            intent: "birthday_detected",
            riskLevel: "medium",
            requiresConfirmation: false,
            shouldExecuteNow: true,
            card: AgentCard(
                type: "birthday",
                title: "生日提醒",
                summary: "我理解这是 \(personName) 的\(calendarType == .solar ? "阳历" : "农历")生日。",
                message: "信息已经够了，我会按每年提前 \(remindBeforeDays) 天安排提醒。",
                options: []
            ),
            toolPlan: [
                AgentToolPlan(
                    tool: actionValue,
                    when: "now",
                    params: [
                        "type": .string("birthday"),
                        "person_name": .string(personName),
                        "date_text": .string("今天"),
                        "date": .string(currentDate),
                        "remind_before_days": .number(Double(remindBeforeDays)),
                        "calendar_type": .string(calendarType == .solar ? "solar" : "lunar")
                    ]
                )
            ],
            memoryToSave: [
                AgentMemoryToSave(type: "input_summary", content: "用户提到 \(personName) 今天生日，生日类型为\(calendarType == .solar ? "阳历" : "农历")。")
            ],
            userVisibleText: "信息已经够了，我会按每年提前 \(remindBeforeDays) 天安排提醒。"
        )
    }

    private static func extractPersonName(from text: String) -> String {
        let separators = ["今天生日", "生日"]
        var candidate = text
        for separator in separators {
            if let range = candidate.range(of: separator) {
                candidate = String(candidate[..<range.lowerBound])
                break
            }
        }

        let prefixes = ["我朋友", "我的朋友", "朋友", "我家人", "我的家人", "家人", "我", "的"]
        for prefix in prefixes {
            if candidate.hasPrefix(prefix) {
                candidate.removeFirst(prefix.count)
            }
        }

        candidate = candidate
            .replacingOccurrences(of: "是", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return candidate.isEmpty ? "生日主角" : candidate
    }
}

private struct DeepSeekRequest: Encodable {
    let model: String
    let messages: [DeepSeekMessage]
    let responseFormat: DeepSeekResponseFormat?
    let temperature: Double
    let stream: Bool
    let enableThinking: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
        case stream
        case enableThinking = "enable_thinking"
    }
}

private struct DeepSeekMessage: Codable {
    let role: String
    let content: DeepSeekMessageContent?
    let reasoningContent: String?

    init(role: String, content: DeepSeekMessageContent) {
        self.role = role
        self.content = content
        self.reasoningContent = nil
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
    }

    var bestContent: String? {
        if let content = content?.bestText, !content.isEmpty {
            return content
        }
        if let reasoningContent = reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoningContent.isEmpty {
            return reasoningContent
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        if let string = try? container.decode(String.self, forKey: .content) {
            content = .text(string)
        } else if let parts = try? container.decode([DeepSeekMessagePart].self, forKey: .content) {
            content = .parts(parts)
        } else {
            content = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let content {
            switch content {
            case .text(let string):
                try container.encode(string, forKey: .content)
            case .parts(let parts):
                try container.encode(parts, forKey: .content)
            }
        }
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }
}

    private enum DeepSeekMessageContent: Codable {
        case text(String)
        case parts([DeepSeekMessagePart])

    var bestText: String? {
        switch self {
        case .text(let string):
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        case .parts(let parts):
            return parts.compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
        }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let string = try? container.decode(String.self) {
                self = .text(string)
                return
            }
            let parts = try container.decode([DeepSeekMessagePart].self)
            self = .parts(parts)
        }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let string):
            try string.encode(to: encoder)
        case .parts(let parts):
            try parts.encode(to: encoder)
        }
    }
}

private struct DeepSeekMessagePart: Codable {
    let type: String
    let text: String?
    let imageURL: DeepSeekImageURL?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    static func text(_ text: String) -> DeepSeekMessagePart {
        DeepSeekMessagePart(type: "text", text: text, imageURL: nil)
    }

    static func image(url: String) -> DeepSeekMessagePart {
        DeepSeekMessagePart(type: "image_url", text: nil, imageURL: DeepSeekImageURL(url: url))
    }
}

private struct DeepSeekImageURL: Codable {
    let url: String
}

private struct DeepSeekResponseFormat: Encodable {
    let type: String
}

private struct DeepSeekResponse: Decodable {
    struct Choice: Decodable {
        let message: DeepSeekMessage
    }

    let choices: [Choice]
    let usage: AgentModelUsage?
}

@MainActor
final class LegacyLocalStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil) {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.fileURL = fileURL ?? baseURL.appendingPathComponent("jotly_store.json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    func load() throws -> JotlyStoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return JotlyStoreSnapshot()
        }
        let data = try Data(contentsOf: fileURL)
        return try decoder.decode(JotlyStoreSnapshot.self, from: data)
    }

    func saveRawInput(_ input: RawInput, card: MemoryCard) throws {
        var snapshot = try load()
        snapshot.rawInputs.append(input)
        upsert(card: card, in: &snapshot)
        try save(snapshot)
    }

    func upsertCard(_ card: MemoryCard) throws {
        var snapshot = try load()
        upsert(card: card, in: &snapshot)
        try save(snapshot)
    }

    func saveSnapshot(_ snapshot: JotlyStoreSnapshot) throws {
        try save(snapshot)
    }

    func appendBirthdayEvent(_ event: BirthdayEvent, reminderTask: ReminderTask?) throws {
        var snapshot = try load()
        snapshot.birthdayEvents.append(event)
        if let reminderTask {
            snapshot.reminderTasks.append(reminderTask)
        }
        let reminderState = reminderTask == nil ? "none" : "present"
        JotlyLog.storage.info("appendBirthdayEvent eventId=\(event.id, privacy: .public), reminderTask=\(reminderState, privacy: .public)")
        try save(snapshot)
    }

    private func upsert(card: MemoryCard, in snapshot: inout JotlyStoreSnapshot) {
        if let index = snapshot.cards.firstIndex(where: { $0.id == card.id }) {
            snapshot.cards[index] = card
        } else {
            snapshot.cards.append(card)
        }
    }

    private func save(_ snapshot: JotlyStoreSnapshot) throws {
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: [.atomic])
    }

    func deleteCard(id: String) throws {
        var snapshot = try load()
        let eventsToDelete = snapshot.birthdayEvents.filter { $0.cardId == id }
        let eventIds = Set(eventsToDelete.map { $0.id })
        snapshot.reminderTasks.removeAll { eventIds.contains($0.birthdayEventId) || $0.cardId == id }
        snapshot.birthdayEvents.removeAll { $0.cardId == id }
        snapshot.rawInputs.removeAll { $0.linkedCardId == id }
        snapshot.cards.removeAll { $0.id == id }
        try save(snapshot)
    }
}

@MainActor
final class LegacyBirthdaySystemCoordinator {
    private let eventStore = EKEventStore()
    private let notificationCenter = UNUserNotificationCenter.current()

    func ensureAccess() async throws {
        if #available(iOS 17.0, *) {
            let calendarGranted = try await eventStore.requestFullAccessToEvents()
            guard calendarGranted else {
                throw JotlyError.calendarPermissionDenied
            }

            let reminderGranted = try await eventStore.requestFullAccessToReminders()
            guard reminderGranted else {
                throw JotlyError.reminderPermissionDenied
            }
        } else {
            throw JotlyError.eventStoreUnavailable
        }

        let notificationGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        guard notificationGranted else {
            throw JotlyError.notificationPermissionDenied
        }
    }

    struct BirthdayNotes {
        var advanceNote: String?
        var birthdayNote: String?

        static let empty = BirthdayNotes(advanceNote: nil, birthdayNote: nil)
    }

    func persistSolar(event: BirthdayEvent, task: ReminderTask, remindBeforeDays: Int, customNotes: BirthdayNotes) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        var occurrenceDate: Date? = nil
        let baseDate = DateFormatting.date(fromDayString: event.date)
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: baseDate)
        comps.hour = 0
        comps.minute = 0
        occurrenceDate = Calendar.current.date(from: comps)
        
        if occurrenceDate == nil {
            occurrenceDate = birthdayOccurrenceDate(from: task.nextTriggerAt, remindBeforeDays: remindBeforeDays)
        }
        let calendarEventId = try createCalendarEvent(
            title: task.title,
            startDate: occurrenceDate,
            remindBeforeDays: remindBeforeDays,
            notes: notes(for: event, task: task, customNote: customNotes.birthdayNote, isAdvanceReminder: false),
            isRecurring: true,
            isAllDay: true
        )
        let reminderItemId = try createReminderItem(
            title: task.title,
            dueDate: task.nextTriggerAt,
            notes: notes(for: event, task: task, customNote: customNotes.advanceNote, isAdvanceReminder: true),
            isRecurring: true
        )
        let notificationRequestId = try await scheduleNotification(
            identifier: task.id,
            title: task.title,
            body: task.notificationMessage,
            fireDate: task.nextTriggerAt,
            repeats: true
        )

        let artifact = DateTaskArtifact(
            id: "artifact_\(UUID().uuidString)",
            kind: "solar_yearly",
            year: occurrenceDate.map { Calendar.current.component(.year, from: $0) },
            occurrenceDate: occurrenceDate.map { DateFormatting.string(from: $0) },
            reminderDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId
        )

        return BirthdayExecutionArtifacts(
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: [artifact]
        )
    }

    func persistLunar(event: BirthdayEvent, task: ReminderTask, remindBeforeDays: Int, customNotes: BirthdayNotes) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        let occurrences = lunarOccurrences(
            lunarMonth: event.lunarMonth,
            lunarDay: event.lunarDay,
            isLeapMonth: event.isLeapMonth,
            remindBeforeDays: remindBeforeDays,
            minimumFutureCount: 5
        )
        guard !occurrences.isEmpty else {
            throw JotlyError.invalidDeepSeekResponse
        }

        var artifacts: [DateTaskArtifact] = []
        for occurrence in occurrences {
            let calendarEventId = try createCalendarEvent(
                title: task.title,
                startDate: occurrence.occurrenceDate,
                remindBeforeDays: remindBeforeDays,
                notes: notes(for: event, task: task, occurrenceDate: occurrence.occurrenceDate, customNote: customNotes.birthdayNote, isAdvanceReminder: false),
                isRecurring: false,
                isAllDay: true
            )
            let reminderItemId = try createReminderItem(
                title: task.title,
                dueDate: occurrence.reminderDate,
                notes: notes(for: event, task: task, occurrenceDate: occurrence.occurrenceDate, customNote: customNotes.advanceNote, isAdvanceReminder: true),
                isRecurring: false
            )
            let notificationRequestId = try await scheduleNotification(
                identifier: "\(task.id)_\(occurrence.year)",
                title: task.title,
                body: task.notificationMessage,
                fireDate: occurrence.reminderDate,
                repeats: false
            )
            artifacts.append(
                DateTaskArtifact(
                    id: "artifact_\(UUID().uuidString)",
                    kind: "lunar_series_occurrence",
                    year: occurrence.year,
                    occurrenceDate: DateFormatting.string(from: occurrence.occurrenceDate),
                    reminderDate: DateFormatting.string(from: occurrence.reminderDate),
                    calendarEventId: calendarEventId,
                    reminderItemId: reminderItemId,
                    notificationRequestId: notificationRequestId
                )
            )
        }

        return BirthdayExecutionArtifacts(
            calendarEventId: artifacts.first?.calendarEventId,
            reminderItemId: artifacts.first?.reminderItemId,
            notificationRequestId: artifacts.first?.notificationRequestId,
            artifacts: artifacts
        )
    }

    func persistDate(event: BirthdayEvent, task: ReminderTask, customNote: String?) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        let usesCalendar = shouldUseCalendarEvent(for: task)
        let alarmLeadDays = shouldUseLeadAlarm(for: event, task: task) ? task.remindBeforeDays : 0
        let calendarEventId: String?
        let reminderItemId: String?
        if usesCalendar {
            calendarEventId = try createCalendarEvent(
                title: task.title,
                startDate: task.nextTriggerAt,
                remindBeforeDays: alarmLeadDays,
                notes: notesForDateTask(task, customNote: customNote),
                repeatRule: task.repeatRule
            )
            reminderItemId = nil
        } else {
            calendarEventId = nil
            reminderItemId = try createReminderItem(
                title: task.title,
                dueDate: task.nextTriggerAt,
                notes: notesForDateTask(task, customNote: customNote),
                remindBeforeDays: alarmLeadDays,
                repeatRule: task.repeatRule
            )
        }

        let isBirthday = task.title.localizedStandardContains("生日") || event.calendarType == .solar || event.calendarType == .lunar
        let notificationRequestId: String?
        if isBirthday && task.remindBeforeDays > 0, let triggerAt = task.nextTriggerAt {
            let fireDate = Calendar.current.date(byAdding: .day, value: -task.remindBeforeDays, to: triggerAt) ?? triggerAt
            notificationRequestId = try? await scheduleNotification(
                identifier: task.id,
                title: task.title,
                body: task.notificationMessage,
                fireDate: fireDate,
                repeats: task.repeatRule == "yearly"
            )
        } else {
            notificationRequestId = nil
        }

        let artifact = DateTaskArtifact(
            id: "artifact_\(UUID().uuidString)",
            kind: usesCalendar ? "calendar_event" : "reminder_item",
            year: task.nextTriggerAt.map { Calendar.current.component(.year, from: $0) },
            occurrenceDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
            reminderDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId
        )

        return BirthdayExecutionArtifacts(
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: [artifact]
        )
    }

    func persistFamilyHolidaySeries(event: BirthdayEvent, task: ReminderTask, remindBeforeDays: Int) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        let occurrences = familyHolidayOccurrences(remindBeforeDays: remindBeforeDays, minimumFutureYears: 5)
        guard !occurrences.isEmpty else {
            throw JotlyError.invalidDeepSeekResponse
        }

        var artifacts: [DateTaskArtifact] = []
        for occurrence in occurrences {
            let title = occurrence.name
            let calendarEventId = try createCalendarEvent(
                title: title,
                startDate: occurrence.occurrenceDate,
                remindBeforeDays: 0,
                notes: familyHolidayNotes(name: occurrence.name, remindBeforeDays: remindBeforeDays, isAdvanceReminder: false),
                isRecurring: false,
                isAllDay: true
            )
            let reminderItemId = try createReminderItem(
                title: title,
                dueDate: occurrence.reminderDate,
                notes: familyHolidayNotes(name: occurrence.name, remindBeforeDays: remindBeforeDays, isAdvanceReminder: true),
                isRecurring: false
            )
            let notificationRequestId = try await scheduleNotification(
                identifier: "\(task.id)_\(occurrence.kind)_\(occurrence.year)",
                title: title,
                body: "\(occurrence.name)快到了，可以提前准备一句祝福或一个小心意。",
                fireDate: occurrence.reminderDate,
                repeats: false
            )
            artifacts.append(
                DateTaskArtifact(
                    id: "artifact_\(UUID().uuidString)",
                    kind: "family_holiday_\(occurrence.kind)",
                    year: occurrence.year,
                    occurrenceDate: DateFormatting.string(from: occurrence.occurrenceDate),
                    reminderDate: DateFormatting.dateTimeString(from: occurrence.reminderDate),
                    calendarEventId: calendarEventId,
                    reminderItemId: reminderItemId,
                    notificationRequestId: notificationRequestId
                )
            )
        }

        return BirthdayExecutionArtifacts(
            calendarEventId: artifacts.first?.calendarEventId,
            reminderItemId: artifacts.first?.reminderItemId,
            notificationRequestId: artifacts.first?.notificationRequestId,
            artifacts: artifacts
        )
    }

    func cancelArtifacts(for snapshot: JotlyStoreSnapshot, cardId: String) {
        let tasks = snapshot.reminderTasks.filter { $0.cardId == cardId }
        let notificationIds = tasks.flatMap { task -> [String] in
            var ids = task.artifacts?.compactMap(\.notificationRequestId) ?? []
            if let notificationRequestId = task.notificationRequestId {
                ids.append(notificationRequestId)
            } else {
                ids.append(task.id)
            }
            return ids
        }
        if !notificationIds.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIds)
        }

        for task in tasks {
            let calendarEventIds = Set((task.artifacts?.compactMap(\.calendarEventId) ?? []) + [task.calendarEventId].compactMap { $0 })
            for calendarEventId in calendarEventIds {
                if let event = eventStore.event(withIdentifier: calendarEventId) {
                    try? eventStore.remove(event, span: .futureEvents, commit: true)
                }
            }

            let reminderItemIds = Set((task.artifacts?.compactMap(\.reminderItemId) ?? []) + [task.reminderItemId].compactMap { $0 })
            for reminderItemId in reminderItemIds {
                if let reminder = eventStore.calendarItem(withIdentifier: reminderItemId) as? EKReminder {
                    try? eventStore.remove(reminder, commit: true)
                }
            }
        }
    }

    private func createCalendarEvent(
        title: String,
        startDate: Date?,
        remindBeforeDays: Int,
        notes: String,
        isRecurring: Bool,
        isAllDay: Bool = false
    ) throws -> String {
        guard let startDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = startDate
        event.isAllDay = isAllDay
        event.endDate = isAllDay
            ? (Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: startDate) ?? startDate.addingTimeInterval(86399))
            : (Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate.addingTimeInterval(3600))
        if !isAllDay && remindBeforeDays > 0 {
            event.alarms = [EKAlarm(relativeOffset: TimeInterval(-remindBeforeDays * 24 * 60 * 60))]
        }

        if isRecurring {
            let recurrence = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
            event.recurrenceRules = [recurrence]
        }

        do {
            try eventStore.save(event, span: .futureEvents, commit: true)
        } catch {
            throw JotlyError.calendarEventCreationFailed(error.localizedDescription)
        }

        return event.eventIdentifier ?? "calendar_\(UUID().uuidString)"
    }

    private func createReminderItem(
        title: String,
        dueDate: Date?,
        notes: String,
        isRecurring: Bool
    ) throws -> String {
        guard let dueDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        let dueComponents = reminderDueDateComponents(from: dueDate)
        reminder.dueDateComponents = dueComponents
        reminder.alarms = [EKAlarm(absoluteDate: dueDate)]
        if isRecurring {
            reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)]
        }

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw JotlyError.reminderCreationFailed(error.localizedDescription)
        }

        JotlyLog.tool.info(
            "Reminder saved title=\(title, privacy: .public), due=\(DateFormatting.dateTimeString(from: dueDate), privacy: .public), components=\(String(describing: dueComponents), privacy: .public), id=\(reminder.calendarItemIdentifier, privacy: .public)"
        )
        return reminder.calendarItemIdentifier
    }

    private func createCalendarEvent(
        title: String,
        startDate: Date?,
        remindBeforeDays: Int,
        notes: String,
        repeatRule: String
    ) throws -> String {
        guard let startDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = startDate
        event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate.addingTimeInterval(3600)
        if remindBeforeDays > 0 {
            event.alarms = [EKAlarm(relativeOffset: TimeInterval(-remindBeforeDays * 24 * 60 * 60))]
        }
        if let rule = recurrenceRule(from: repeatRule) {
            event.recurrenceRules = [rule]
        }

        do {
            try eventStore.save(event, span: .futureEvents, commit: true)
        } catch {
            throw JotlyError.calendarEventCreationFailed(error.localizedDescription)
        }

        return event.eventIdentifier ?? "calendar_\(UUID().uuidString)"
    }

    private func createReminderItem(
        title: String,
        dueDate: Date?,
        notes: String,
        remindBeforeDays: Int,
        repeatRule: String
    ) throws -> String {
        guard let dueDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        let dueComponents = reminderDueDateComponents(from: dueDate)
        reminder.dueDateComponents = dueComponents
        reminder.alarms = [EKAlarm(absoluteDate: dueDate)]
        if let rule = recurrenceRule(from: repeatRule) {
            reminder.recurrenceRules = [rule]
        }

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw JotlyError.reminderCreationFailed(error.localizedDescription)
        }

        JotlyLog.tool.info(
            "Reminder saved title=\(title, privacy: .public), due=\(DateFormatting.dateTimeString(from: dueDate), privacy: .public), components=\(String(describing: dueComponents), privacy: .public), repeat=\(repeatRule, privacy: .public), id=\(reminder.calendarItemIdentifier, privacy: .public)"
        )
        return reminder.calendarItemIdentifier
    }

    private func reminderDueDateComponents(from date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.calendar = calendar
        components.timeZone = .current
        return components
    }

    private func recurrenceRule(from value: String) -> EKRecurrenceRule? {
        switch value {
        case "daily":
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case "weekly":
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "monthly":
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case "yearly", "yearly_lunar":
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        default:
            return nil
        }
    }

    private func shouldUseCalendarEvent(for task: ReminderTask) -> Bool {
        if task.status == "calendar_event" {
            return true
        }
        let calendarKeywords = ["会议", "约会", "日程", "行程", "面试", "上课", "课程", "开会"]
        return calendarKeywords.contains { task.title.localizedStandardContains($0) }
    }

    private func shouldUseLeadAlarm(for event: BirthdayEvent, task: ReminderTask) -> Bool {
        guard task.remindBeforeDays > 0 else { return false }
        if event.calendarType == .solar || event.calendarType == .lunar {
            return true
        }
        if task.title.localizedStandardContains("生日") {
            return true
        }
        if task.title.localizedStandardContains("纪念日") {
            return true
        }
        return false
    }

    private func scheduleNotification(
        identifier: String,
        title: String,
        body: String,
        fireDate: Date?,
        repeats: Bool
    ) async throws -> String {
        guard let fireDate else {
            throw JotlyError.invalidDeepSeekResponse
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components: DateComponents
        if repeats {
            components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: fireDate)
        } else {
            components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await notificationCenter.add(request)
        return identifier
    }

    private func notes(
        for event: BirthdayEvent,
        task: ReminderTask,
        occurrenceDate: Date? = nil,
        customNote: String? = nil,
        isAdvanceReminder: Bool
    ) -> String {
        return customNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func birthdayDisplayName(from rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "这位重要的人"
        }
        for suffix in ["的生日", "生日"] {
            while name.hasSuffix(suffix), name.count > suffix.count {
                name.removeLast(suffix.count)
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return name.isEmpty ? "这位重要的人" : name
    }

    private func notesForDateTask(_ task: ReminderTask, customNote: String? = nil) -> String {
        return customNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func dateTaskNoteOpening(for task: ReminderTask) -> String {
        let title = task.title
        if title.localizedStandardContains("喝水") {
            return "💧 咕嘟咕嘟，记得照顾好自己的身体，喝水也是件正经事。"
        }
        if title.localizedStandardContains("吃药") || title.localizedStandardContains("服药") {
            return "💊 药不能停，健康第一。按时服药，身体才会好起来哦。"
        }
        if title.localizedStandardContains("续费") || title.localizedStandardContains("充值") || title.localizedStandardContains("缴费") {
            return "💳 提醒小帮手上线：提前处理一下，避免服务被打断哦。"
        }
        if title.localizedStandardContains("会议") || title.localizedStandardContains("约会") || title.localizedStandardContains("行程") {
            return "🗓️ 精彩生活，准时出发。到时间我会准时叫你的。"
        }
        if title.localizedStandardContains("羽毛球") || title.localizedStandardContains("打球") {
            return "🏸 出门前记得带上球拍、球鞋和水，轻装上阵就好。"
        }
        
        let standardOpenings = [
            "✨ 别担心，每一件小事，我都帮你妥帖记着呢。",
            "🌟 滴答滴答，生活的小步调，我们一起稳稳走过。",
            "🍀 愿你今天的心情 and 天气一样明朗，待会儿见！",
            "🎈 重要的事，交给我来守护，你只管享受当下就好。"
        ]
        let index = abs(title.hashValue) % standardOpenings.count
        return standardOpenings[index].replacingOccurrences(of: " and ", with: "和")
    }

    private func humanReadableRepeatRule(_ value: String) -> String {
        switch value {
        case "daily": return "每天"
        case "weekly": return "每周"
        case "monthly": return "每月"
        case "yearly", "yearly_lunar": return "每年"
        default: return "不重复"
        }
    }

    private func dateReminderCompletionMessage(title: String, repeatRule: String, reminderDate: Date) -> String {
        let repeatText = humanReadableRepeatRule(repeatRule)
        if repeatText == "不重复" {
            return "提醒已创建。我会在 \(DateFormatting.badgeString(from: reminderDate)) 提醒你。"
        }
        return "提醒已创建。我会\(repeatText)在 \(timeString(from: reminderDate)) 提醒你\(title.isEmpty ? "" : "：\(title)")。"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func birthdayOccurrenceDate(from reminderDate: Date?, remindBeforeDays: Int) -> Date? {
        guard let reminderDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: remindBeforeDays, to: reminderDate)
    }

    fileprivate func lunarOccurrences(
        lunarMonth: Int?,
        lunarDay: Int?,
        isLeapMonth: Bool,
        remindBeforeDays: Int,
        minimumFutureCount: Int
    ) -> [(year: Int, occurrenceDate: Date, reminderDate: Date)] {
        guard let lunarMonth, let lunarDay else { return [] }

        let lunarCalendar = Calendar(identifier: .chinese)
        let gregorianCalendar = Calendar.current
        let now = Date()
        let currentYear = lunarCalendar.component(.year, from: now)
        var results: [(year: Int, occurrenceDate: Date, reminderDate: Date)] = []

        for offset in 0...20 {
            var components = DateComponents()
            components.calendar = lunarCalendar
            components.year = currentYear + offset
            components.month = lunarMonth
            components.day = lunarDay
            components.hour = 0
            components.minute = 0
            components.isLeapMonth = isLeapMonth

            guard
                let occurrenceDate = lunarCalendar.date(from: components),
                let rawReminderDate = gregorianCalendar.date(byAdding: .day, value: -remindBeforeDays, to: occurrenceDate)
            else {
                continue
            }
            var reminderComponents = gregorianCalendar.dateComponents([.year, .month, .day], from: rawReminderDate)
            reminderComponents.hour = 12
            reminderComponents.minute = 30
            guard let reminderDate = gregorianCalendar.date(from: reminderComponents) else {
                continue
            }

            if reminderDate > now {
                results.append((currentYear + offset, occurrenceDate, reminderDate))
            }

            if results.count >= minimumFutureCount {
                break
            }
        }

        return results
    }

    private func familyHolidayOccurrences(remindBeforeDays: Int, minimumFutureYears: Int) -> [(kind: String, name: String, year: Int, occurrenceDate: Date, reminderDate: Date)] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let now = Date()
        var results: [(kind: String, name: String, year: Int, occurrenceDate: Date, reminderDate: Date)] = []

        for offset in 0...10 {
            let year = currentYear + offset
            let holidays: [(String, String, Date?)] = [
                ("mother", "母亲节", nthWeekday(year: year, month: 5, weekday: 1, ordinal: 2)),
                ("father", "父亲节", nthWeekday(year: year, month: 6, weekday: 1, ordinal: 3))
            ]

            for (kind, name, maybeDate) in holidays {
                guard let occurrenceDate = maybeDate,
                      let rawReminderDate = calendar.date(byAdding: .day, value: -remindBeforeDays, to: occurrenceDate)
                else {
                    continue
                }
                var reminderComponents = calendar.dateComponents([.year, .month, .day], from: rawReminderDate)
                reminderComponents.hour = 12
                reminderComponents.minute = 30
                guard let reminderDate = calendar.date(from: reminderComponents) else {
                    continue
                }

                if reminderDate > now {
                    results.append((kind, name, year, occurrenceDate, reminderDate))
                }
            }

            if results.filter({ $0.kind == "mother" }).count >= minimumFutureYears,
               results.filter({ $0.kind == "father" }).count >= minimumFutureYears {
                break
            }
        }

        return results.sorted { $0.reminderDate < $1.reminderDate }
    }

    private func nthWeekday(year: Int, month: Int, weekday: Int, ordinal: Int) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = ordinal
        components.hour = 0
        components.minute = 0
        return Calendar.current.date(from: components)
    }

    private func familyHolidayNotes(name: String, remindBeforeDays: Int, isAdvanceReminder: Bool) -> String {
        var lines: [String] = []
        if isAdvanceReminder {
            lines.append("\(name)快到了。")
            lines.append("留点时间准备一句祝福，或者一个小小的心意。")
        } else {
            lines.append("今天是\(name)，记得送上一句祝福。")
        }
        lines.append("来自随心记")
        return lines.joined(separator: "\n")
    }
}

struct LegacyBirthdayExecutionArtifacts {
    let calendarEventId: String?
    let reminderItemId: String?
    let notificationRequestId: String?
    var artifacts: [DateTaskArtifact] = []
}

@MainActor
final class LegacyBirthdayToolExecutor {
    private let scheduler = BirthdaySystemCoordinator()

    func execute(option: CardOption, card: MemoryCard) async throws -> BirthdayToolResult {
        // Check if date parameters are present. If not, fall back to record only to avoid errors/invalid reminders.
        let modelDateStr = card.metadata?["date"] ?? card.metadata?["start_date"] ?? card.metadata?["due_date"] 
            ?? card.metadata?["datetime"] ?? card.metadata?["date_time"] ?? card.metadata?["start_at"] ?? card.metadata?["due_at"]
            ?? card.metadata?["solar_date"] ?? card.entities?.date
            
        let hasDate: Bool
        if option.value == "create_lunar_birthday_reminder" {
            let hasLunarMonth = card.entities?.lunarMonth != nil || card.metadata?["lunar_month"] != nil
            let hasLunarDay = card.entities?.lunarDay != nil || card.metadata?["lunar_day"] != nil
            let hasSolarDate = modelDateStr != nil && !modelDateStr!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            hasDate = (hasLunarMonth && hasLunarDay) || hasSolarDate
        } else {
            hasDate = modelDateStr != nil && !modelDateStr!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !hasDate && option.value != "record_only" {
            JotlyLog.tool.info("execute: model date parameters missing, falling back to record_only.")
            return recordOnly(card: card)
        }

        switch option.value {
        case "record_only":
            return recordOnly(card: card)
        case "create_date_reminder":
            return try await createDateReminder(card: card)
        case "create_solar_birthday_reminder":
            return try await createSolarReminder(card: card)
        case "create_lunar_birthday_reminder":
            return try await createLunarReminder(card: card)
        default:
            throw JotlyError.unsupportedTool(option.value)
        }
    }

    func cancelArtifacts(for snapshot: JotlyStoreSnapshot, cardId: String) {
        scheduler.cancelArtifacts(for: snapshot, cardId: cardId)
    }

    func createFamilyHolidayReminders(card: MemoryCard, remindBeforeDays: Int) async throws -> BirthdayToolResult {
        let event = BirthdayEvent(
            id: "date_\(UUID().uuidString)",
            cardId: card.id,
            personName: "母亲节和父亲节",
            date: DateFormatting.todayString(),
            calendarType: .solar,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: false,
            repeatRule: "family_holiday_series",
            remindBeforeDays: remindBeforeDays,
            createdAt: Date()
        )
        let task = ReminderTask(
            id: "reminder_\(UUID().uuidString)",
            cardId: card.id,
            birthdayEventId: event.id,
            title: "母亲节和父亲节提醒",
            calendarType: .solar,
            repeatRule: "family_holiday_series",
            remindBeforeDays: remindBeforeDays,
            remindTime: "12:30",
            nextTriggerAt: nil,
            notificationMessage: "家人节日快到了，可以提前准备祝福或礼物。",
            status: "family_holiday_series",
            calendarEventId: nil,
            reminderItemId: nil,
            notificationRequestId: nil,
            artifacts: []
        )
        let artifacts = try await scheduler.persistFamilyHolidaySeries(event: event, task: task, remindBeforeDays: remindBeforeDays)
        let updatedTask = ReminderTask(
            id: task.id,
            cardId: task.cardId,
            birthdayEventId: task.birthdayEventId,
            title: task.title,
            calendarType: task.calendarType,
            repeatRule: task.repeatRule,
            remindBeforeDays: task.remindBeforeDays,
            remindTime: task.remindTime,
            nextTriggerAt: artifacts.artifacts
                .compactMap { DateFormatting.dateTime(from: $0.reminderDate) }
                .filter { $0 > Date() }
                .sorted()
                .first,
            notificationMessage: task.notificationMessage,
            status: task.status,
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: updatedTask,
            completionMessage: "已创建节日提醒任务。",
            reminderInfo: CardReminderInfo(
                type: "family_holiday",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: remindBeforeDays,
                nextTriggerDate: updatedTask.nextTriggerAt.map { DateFormatting.dateTimeString(from: $0) },
                status: "active",
                calendarEventId: updatedTask.calendarEventId,
                reminderItemId: updatedTask.reminderItemId,
                notificationRequestId: updatedTask.notificationRequestId,
                artifacts: updatedTask.artifacts
            )
        )
    }

    func refreshLunarDateSeries(in snapshot: JotlyStoreSnapshot) async throws -> JotlyStoreSnapshot? {
        var updatedSnapshot = snapshot
        var changed = false

        for event in snapshot.birthdayEvents where event.calendarType == .lunar {
            guard let taskIndex = updatedSnapshot.reminderTasks.firstIndex(where: { $0.birthdayEventId == event.id }) else {
                continue
            }

            let task = updatedSnapshot.reminderTasks[taskIndex]
            if futureArtifactCount(task.artifacts) >= 5 {
                continue
            }

            scheduler.cancelArtifacts(for: updatedSnapshot, cardId: event.cardId)
            let artifacts = try await scheduler.persistLunar(event: event, task: task, remindBeforeDays: event.remindBeforeDays, customNotes: .empty)
            let refreshedTask = reminderTask(
                updating: task,
                artifacts: artifacts.artifacts,
                calendarEventId: artifacts.calendarEventId,
                reminderItemId: artifacts.reminderItemId,
                notificationRequestId: artifacts.notificationRequestId
            )
            updatedSnapshot.reminderTasks[taskIndex] = refreshedTask

            if let cardIndex = updatedSnapshot.cards.firstIndex(where: { $0.id == event.cardId }) {
                var card = updatedSnapshot.cards[cardIndex]
                card.reminderInfo = CardReminderInfo(
                    type: "lunar",
                    personName: event.personName,
                    date: event.date,
                    remindBeforeDays: event.remindBeforeDays,
                    nextTriggerDate: refreshedTask.nextTriggerAt.map { DateFormatting.string(from: $0) },
                    status: "saved_lunar",
                    calendarEventId: refreshedTask.calendarEventId,
                    reminderItemId: refreshedTask.reminderItemId,
                    notificationRequestId: refreshedTask.notificationRequestId,
                    artifacts: refreshedTask.artifacts
                )
                card.markUpdated()
                updatedSnapshot.cards[cardIndex] = card
            }

            changed = true
        }

        return changed ? updatedSnapshot : nil
    }

    private func recordOnly(card: MemoryCard) -> BirthdayToolResult {
        let remindDays = resolvedRemindBeforeDays(from: card)
        let event = makeBirthdayEvent(card: card, calendarType: .recordOnly, remindBeforeDays: remindDays)
        return BirthdayToolResult(
            event: event,
            reminderTask: nil,
            completionMessage: "已保存。",
            reminderInfo: CardReminderInfo(
                type: "record",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: 0,
                nextTriggerDate: nil,
                status: "none",
                calendarEventId: nil,
                reminderItemId: nil,
                notificationRequestId: nil
            )
        )
    }

    private func validateBirthdayDatePresence(card: MemoryCard, calendarType: BirthdayCalendarType) throws {
        let combinedText = "\(card.originalText)\n\(card.supplementalText ?? "")"
        let explicitDateText = card.entities?.date ?? card.metadata?["date"] ?? card.metadata?["solar_date"] ?? card.metadata?["start_date"] ?? card.metadata?["due_date"]
        let hasExplicitDate = isUsableDateText(explicitDateText)
            || containsCompleteMonthDay(in: combinedText)
            || combinedText.localizedStandardContains("今天")
            || combinedText.localizedStandardContains("明天")
            || combinedText.localizedStandardContains("后天")

        if calendarType == .lunar {
            let parsed = lunarComponents(from: combinedText)
            let hasLunarMonth = card.entities?.lunarMonth != nil || card.metadata?["lunar_month"] != nil || parsed.month != nil
            let hasLunarDay = card.entities?.lunarDay != nil || card.metadata?["lunar_day"] != nil || parsed.day != nil
            if hasLunarMonth && hasLunarDay {
                return
            }
            guard hasExplicitDate else {
                throw JotlyError.invalidToolParameters("无法识别出农历或可转换的阳历日期信息。")
            }
            return
        }

        guard hasExplicitDate else {
            throw JotlyError.invalidToolParameters("无法识别出可用的阳历日期信息。")
        }
    }

    private func containsCompleteMonthDay(in text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        return normalized.range(of: #"(\d{1,2}|[一二三四五六七八九十冬腊正]+)月(\d{1,2}|[一二三四五六七八九十二三四五六七八九]+)[日号]?"#, options: .regularExpression) != nil
    }

    private func isUsableDateText(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return false
        }
        if DateFormatting.dateTime(from: value) != nil {
            return true
        }
        return value == "今天" || value == "明天" || value == "后天"
    }

    private func containsDayOnlyLunarCue(in text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        return normalized.range(of: #"(\d{1,2}|[一二三四五六七八九十二三四五六七八九]+)[日号]"#, options: .regularExpression) != nil
    }

    private func lunarComponents(from text: String) -> (month: Int?, day: Int?) {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard
            let regex = try? NSRegularExpression(pattern: #"农历(闰)?([正一二三四五六七八九十冬腊\d]{1,3})月([初十廿卅一二三四五六七八九\d]{1,4})[日号]?"#),
            let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
            match.numberOfRanges >= 4,
            let monthRange = Range(match.range(at: 2), in: normalized),
            let dayRange = Range(match.range(at: 3), in: normalized)
        else {
            return (nil, nil)
        }
        return (
            parseChineseNumber(String(normalized[monthRange]), isLunarMonth: true),
            parseChineseNumber(String(normalized[dayRange]), isLunarMonth: false)
        )
    }

    private func parseChineseNumber(_ value: String, isLunarMonth: Bool) -> Int? {
        if let number = Int(value) {
            return number
        }
        let normalized = value
            .replacingOccurrences(of: "初", with: "")
            .replacingOccurrences(of: "廿", with: "二十")
            .replacingOccurrences(of: "卅", with: "三十")
            .replacingOccurrences(of: "冬", with: "十一")
            .replacingOccurrences(of: "腊", with: "十二")
            .replacingOccurrences(of: "正", with: "一")
        let direct: [String: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
            "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12,
            "十三": 13, "十四": 14, "十五": 15, "十六": 16, "十七": 17, "十八": 18, "十九": 19,
            "二十": 20, "二十一": 21, "二十二": 22, "二十三": 23, "二十四": 24, "二十五": 25,
            "二十六": 26, "二十七": 27, "二十八": 28, "二十九": 29, "三十": 30
        ]
        guard let parsed = direct[normalized] else { return nil }
        if isLunarMonth {
            return (1...12).contains(parsed) ? parsed : nil
        }
        return (1...30).contains(parsed) ? parsed : nil
    }

    private func parseChineseNumberString(_ value: String) -> Int? {
        if let number = Int(value) {
            return number
        }
        return parseChineseNumber(value, isLunarMonth: false)
    }

    private func createSolarReminder(card: MemoryCard) async throws -> BirthdayToolResult {
        try validateBirthdayDatePresence(card: card, calendarType: .solar)
        let remindDays = resolvedRemindBeforeDays(from: card)
        let event = makeBirthdayEvent(card: card, calendarType: .solar, remindBeforeDays: remindDays)
        guard let reminderDate = nextSolarReminderDate(for: event.date, remindBeforeDays: remindDays) else {
            throw JotlyError.invalidDeepSeekResponse
        }

        let birthdayName = birthdayDisplayName(from: event.personName)
        let notes = birthdayNotes(from: card, birthdayName: birthdayName, remindBeforeDays: remindDays)
        let notificationMessage = notes.advanceNote ?? "还有 \(remindDays) 天就是\(birthdayName)的生日了，可以提前准备一句祝福。"
        let baseTask = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "active"
        )
        let artifacts = try await scheduler.persistSolar(event: event, task: baseTask, remindBeforeDays: remindDays, customNotes: notes)
        let task = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "active",
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: task,
            completionMessage: "生日提醒已创建。我会在每年提前 \(remindDays) 天提醒你。",
            reminderInfo: CardReminderInfo(
                type: "solar",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: remindDays,
                nextTriggerDate: task.nextTriggerAt.map { DateFormatting.dateTimeString(from: $0) },
                status: "active",
                calendarEventId: task.calendarEventId,
                reminderItemId: task.reminderItemId,
                notificationRequestId: task.notificationRequestId,
                artifacts: task.artifacts
            )
        )
    }

    private func createDateReminder(card: MemoryCard) async throws -> BirthdayToolResult {
        let repeatRule = resolvedRepeatRule(from: card)
        let reminderDate = resolvedDateTime(from: card)
        let isBirthday = dateTaskTitle(from: card).localizedStandardContains("生日") || card.type == "birthday" || card.metadata?["event_type"] == "birthday"
        let remindBeforeDays = card.entities?.remindBeforeDays ?? (isBirthday ? 3 : 0)
        let resolvedEventDate = DateFormatting.string(from: reminderDate)
        
        let event = BirthdayEvent(
            id: "date_\(UUID().uuidString)",
            cardId: card.id,
            personName: dateTaskTitle(from: card),
            date: resolvedEventDate,
            calendarType: .solar,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: false,
            repeatRule: repeatRule,
            remindBeforeDays: remindBeforeDays,
            createdAt: Date()
        )
        let notificationMessage: String
        if isBirthday {
            notificationMessage = card.metadata?["notification_body"] ?? card.metadata?["note"] ?? "\(event.personName)还有 \(remindBeforeDays) 天就过生日啦，记得准备小惊喜哦！"
        } else {
            notificationMessage = card.metadata?["notification_body"] ?? card.metadata?["note"] ?? "你有一个日期提醒：\(event.personName)"
        }
        let executionStatus = card.metadata?["tool"] == "calendar.create_event" ? "calendar_event" : "active"
        let baseTask = makeReminderTask(
            card: card,
            event: event,
            repeatRule: repeatRule,
            remindBeforeDays: event.remindBeforeDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: executionStatus
        )
        let customNote = card.metadata?["note"] ?? card.metadata?["notes"] ?? card.metadata?["notification_body"]
        let artifacts = try await scheduler.persistDate(event: event, task: baseTask, customNote: customNote)
        let task = makeReminderTask(
            card: card,
            event: event,
            repeatRule: repeatRule,
            remindBeforeDays: event.remindBeforeDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: executionStatus,
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: task,
            completionMessage: dateReminderCompletionMessage(title: event.personName, repeatRule: repeatRule, reminderDate: reminderDate),
            reminderInfo: CardReminderInfo(
                type: "date",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: event.remindBeforeDays,
                nextTriggerDate: task.nextTriggerAt.map { DateFormatting.dateTimeString(from: $0) },
                status: "active",
                calendarEventId: task.calendarEventId,
                reminderItemId: task.reminderItemId,
                notificationRequestId: task.notificationRequestId,
                artifacts: task.artifacts
            )
        )
    }

    private func createLunarReminder(card: MemoryCard) async throws -> BirthdayToolResult {
        try validateBirthdayDatePresence(card: card, calendarType: .lunar)
        let remindDays = resolvedRemindBeforeDays(from: card)
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.timeZone = .current
        let lunar: DateComponents
        let parsedLunar = lunarComponents(from: "\(card.originalText)\n\(card.supplementalText ?? "")")
        if let lunarMonth = card.entities?.lunarMonth ?? card.metadata?["lunar_month"].flatMap(parseChineseNumberString) ?? parsedLunar.month,
           let lunarDay = card.entities?.lunarDay ?? card.metadata?["lunar_day"].flatMap(parseChineseNumberString) ?? parsedLunar.day {
            var components = DateComponents()
            components.month = lunarMonth
            components.day = lunarDay
            components.isLeapMonth = card.entities?.isLeapMonth ?? false
            lunar = components
        } else {
            let sourceDate = DateFormatting.date(fromDayString: card.entities?.date ?? card.metadata?["date"] ?? card.metadata?["solar_date"])
            lunar = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: sourceDate)
        }

        let event = BirthdayEvent(
            id: "birthday_\(UUID().uuidString)",
            cardId: card.id,
            personName: normalizedPersonName(from: card),
            date: card.entities?.date ?? DateFormatting.todayString(),
            calendarType: .lunar,
            lunarMonth: lunar.month,
            lunarDay: lunar.day,
            isLeapMonth: lunar.isLeapMonth ?? false,
            repeatRule: "yearly_lunar",
            remindBeforeDays: remindDays,
            createdAt: Date()
        )

        guard let reminderDate = nextLunarReminderDate(
            lunarMonth: lunar.month,
            lunarDay: lunar.day,
            isLeapMonth: lunar.isLeapMonth ?? false,
            remindBeforeDays: remindDays
        ) else {
            throw JotlyError.invalidDeepSeekResponse
        }

        let birthdayName = birthdayDisplayName(from: event.personName)
        let notes = birthdayNotes(from: card, birthdayName: birthdayName, remindBeforeDays: remindDays)
        let notificationMessage = notes.advanceNote ?? "还有 \(remindDays) 天就是\(birthdayName)的生日了，可以提前准备一句祝福。"
        let baseTask = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly_lunar",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "saved_lunar"
        )
        let artifacts = try await scheduler.persistLunar(event: event, task: baseTask, remindBeforeDays: remindDays, customNotes: notes)
        let task = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly_lunar",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "saved_lunar",
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: task,
            completionMessage: "农历生日提醒已创建。已按未来 10 年写入日历和提醒事项。",
            reminderInfo: CardReminderInfo(
                type: "lunar",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: remindDays,
                nextTriggerDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
                status: "saved_lunar",
                calendarEventId: task.calendarEventId,
                reminderItemId: task.reminderItemId,
                notificationRequestId: task.notificationRequestId,
                artifacts: task.artifacts
            )
        )
    }

    private func makeBirthdayEvent(card: MemoryCard, calendarType: BirthdayCalendarType, remindBeforeDays: Int) -> BirthdayEvent {
        BirthdayEvent(
            id: "birthday_\(UUID().uuidString)",
            cardId: card.id,
            personName: normalizedPersonName(from: card),
            date: card.entities?.date ?? DateFormatting.todayString(),
            calendarType: calendarType,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: false,
            repeatRule: calendarType == .lunar ? "yearly_lunar" : "yearly",
            remindBeforeDays: remindBeforeDays,
            createdAt: Date()
        )
    }

    private func makeReminderTask(
        card: MemoryCard,
        event: BirthdayEvent,
        repeatRule: String,
        remindBeforeDays: Int,
        nextTriggerAt: Date,
        notificationMessage: String,
        status: String,
        calendarEventId: String? = nil,
        reminderItemId: String? = nil,
        notificationRequestId: String? = nil,
        artifacts: [DateTaskArtifact] = []
    ) -> ReminderTask {
        let taskTitle: String
        if event.id.hasPrefix("date_") || card.metadata?["tool"] == "reminder.create" || card.metadata?["tool"] == "calendar.create_event" {
            taskTitle = event.personName
        } else if event.personName.localizedStandardContains("生日") {
            taskTitle = event.personName
        } else {
            taskTitle = "\(event.personName)的生日"
        }

        return ReminderTask(
            id: "reminder_\(UUID().uuidString)",
            cardId: card.id,
            birthdayEventId: event.id,
            title: taskTitle,
            calendarType: event.calendarType,
            repeatRule: repeatRule,
            remindBeforeDays: remindBeforeDays,
            remindTime: "12:30",
            nextTriggerAt: nextTriggerAt,
            notificationMessage: notificationMessage,
            status: status,
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: artifacts
        )
    }

    private func reminderTask(
        updating task: ReminderTask,
        artifacts: [DateTaskArtifact],
        calendarEventId: String?,
        reminderItemId: String?,
        notificationRequestId: String?
    ) -> ReminderTask {
        let nextTriggerAt = artifacts
            .compactMap { DateFormatting.date(fromDayString: $0.reminderDate) }
            .filter { $0 > Date() }
            .sorted()
            .first ?? task.nextTriggerAt

        return ReminderTask(
            id: task.id,
            cardId: task.cardId,
            birthdayEventId: task.birthdayEventId,
            title: task.title,
            calendarType: task.calendarType,
            repeatRule: task.repeatRule,
            remindBeforeDays: task.remindBeforeDays,
            remindTime: task.remindTime,
            nextTriggerAt: nextTriggerAt,
            notificationMessage: task.notificationMessage,
            status: task.status,
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: artifacts
        )
    }

    private func futureArtifactCount(_ artifacts: [DateTaskArtifact]?) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        return artifacts?
            .compactMap { DateFormatting.date(fromDayString: $0.reminderDate) }
            .filter { $0 >= today }
            .count ?? 0
    }

    private func resolvedRemindBeforeDays(from card: MemoryCard) -> Int {
        card.entities?.remindBeforeDays ?? 3
    }

    private func birthdayNotes(from card: MemoryCard, birthdayName: String, remindBeforeDays: Int) -> BirthdaySystemCoordinator.BirthdayNotes {
        let metadata = card.metadata ?? [:]
        let advanceNote = firstNonEmpty([
            metadata["advance_note"],
            metadata["pre_reminder_note"],
            metadata["reminder_note"]
        ]) ?? "还有 \(remindBeforeDays) 天就是\(birthdayName)的生日了，可以提前准备一句祝福，或者一个小小的惊喜。"

        let birthdayNote = firstNonEmpty([
            metadata["birthday_note"],
            metadata["day_note"],
            metadata["event_note"],
            metadata["note"],
            metadata["notes"]
        ]) ?? "今天是\(birthdayName)的生日，记得送上祝福，让这一天被好好记住。"

        return BirthdaySystemCoordinator.BirthdayNotes(
            advanceNote: advanceNote,
            birthdayNote: birthdayNote
        )
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func birthdayDisplayName(from rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "这位重要的人"
        }
        for suffix in ["的生日", "生日"] {
            while name.hasSuffix(suffix), name.count > suffix.count {
                name.removeLast(suffix.count)
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return name.isEmpty ? "这位重要的人" : name
    }

    private func normalizedPersonName(from card: MemoryCard) -> String {
        let value = card.entities?.personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "生日主角"
    }

    private func dateTaskTitle(from card: MemoryCard) -> String {
        let candidates = [
            card.metadata?["title"],
            card.metadata?["subject"],
            card.metadata?["content"],
            card.metadata?["summary"],
            card.entities?.eventType,
            card.summary,
            cleanedReminderTitle(from: card.originalText)
        ]
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return String(value.prefix(24))
            }
        }
        return "日期提醒"
    }

    private func cleanedReminderTitle(from text: String) -> String {
        var value = text
        let replacements: [String] = [
            "你记得提醒我",
            "记得提醒我",
            "提醒我",
            "的时候",
            "到时候",
            "每天",
            "每日",
            "老是忘记",
            "总忘记",
            "忘记"
        ]
        for replacement in replacements {
            value = value.replacingOccurrences(of: replacement, with: "")
        }
        if !text.localizedStandardContains("生日") {
            value = value.replacingOccurrences(of: "生日", with: "")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("。") || value.hasPrefix("，") || value.hasPrefix(",") || value.hasPrefix(".") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? text : value
    }

    private func resolvedRepeatRule(from card: MemoryCard) -> String {
        if let explicit = card.metadata?["repeat_rule"] ?? card.metadata?["repeatRule"] ?? card.metadata?["recurrence"] {
            switch explicit {
            case "daily", "weekly", "monthly", "yearly", "yearly_lunar", "once":
                return explicit
            default:
                break
            }
        }
        let text = "\(card.originalText)\n\(card.supplementalText ?? "")"
        if text.localizedStandardContains("每天") || text.localizedStandardContains("每日") || text.localizedStandardContains("天天") {
            return "daily"
        }
        if text.localizedStandardContains("每周") || text.localizedStandardContains("每星期") || text.localizedStandardContains("每个星期") {
            return "weekly"
        }
        if text.localizedStandardContains("每月") || text.localizedStandardContains("每个月") {
            return "monthly"
        }
        if text.localizedStandardContains("每年") || text.localizedStandardContains("每一年") {
            return "yearly"
        }
        
        let isBirthday = card.originalText.localizedStandardContains("生日") || card.supplementalText?.localizedStandardContains("生日") == true || card.type == "birthday" || card.metadata?["event_type"] == "birthday" || card.metadata?["title"]?.localizedStandardContains("生日") == true
        if isBirthday {
            return "yearly"
        }
        return "once"
    }

    private func humanReadableRepeatRule(_ value: String) -> String {
        switch value {
        case "daily": return "每天"
        case "weekly": return "每周"
        case "monthly": return "每月"
        case "yearly", "yearly_lunar": return "每年"
        default: return "不重复"
        }
    }

    private func dateReminderCompletionMessage(title: String, repeatRule: String, reminderDate: Date) -> String {
        let repeatText = humanReadableRepeatRule(repeatRule)
        if repeatText == "不重复" {
            return "提醒已创建。我会在 \(DateFormatting.badgeString(from: reminderDate)) 提醒你。"
        }
        return "提醒已创建。我会\(repeatText)在 \(timeString(from: reminderDate)) 提醒你\(title.isEmpty ? "" : "：\(title)")。"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func resolvedDateTime(from card: MemoryCard) -> Date {
        // Strictly parse date and time parameters outputted by the model
        let modelDateStr = card.metadata?["date"] ?? card.metadata?["start_date"] ?? card.metadata?["due_date"] 
            ?? card.metadata?["datetime"] ?? card.metadata?["date_time"] ?? card.metadata?["start_at"] ?? card.metadata?["due_at"]
        let modelTimeStr = card.metadata?["time"]
        
        guard let trimmedDateStr = modelDateStr?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedDateStr.isEmpty else {
            JotlyLog.tool.error("resolvedDateTime: Model parameters missing date/time info.")
            return Date()
        }
        
        guard let date = DateFormatting.dateTime(from: trimmedDateStr) else {
            JotlyLog.tool.error("resolvedDateTime: Invalid date format from model: \(trimmedDateStr)")
            return Date()
        }
        
        // If the date parameter already contains specific time (":"), use it directly
        if trimmedDateStr.contains(":") {
            return date
        }
        
        // Combine model date with model's time parameter or default
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let time = resolveTime(from: modelTimeStr ?? "") ?? (hour: 12, minute: 30)
        comps.hour = time.hour
        comps.minute = time.minute
        return Calendar.current.date(from: comps) ?? date
    }

    private func resolveTime(from text: String) -> (hour: Int, minute: Int)? {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        if let regex = try? NSRegularExpression(pattern: #"([零〇一二两三四五六七八九十\d]{1,3})[:：点时]([零〇一二两三四五六七八九十\d]{1,3}|半)?分?"#) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            if let match = regex.firstMatch(in: normalized, options: [], range: range),
               let hourRange = Range(match.range(at: 1), in: normalized),
               let rawHour = parseClockNumber(String(normalized[hourRange]))
            {
                var minute = 0
                if match.numberOfRanges > 2,
                   match.range(at: 2).location != NSNotFound,
                   let minuteRange = Range(match.range(at: 2), in: normalized)
                {
                    let minuteText = String(normalized[minuteRange])
                    minute = minuteText == "半" ? 30 : (parseClockNumber(minuteText) ?? 0)
                }
                let hour = normalized.localizedStandardContains("下午") || normalized.localizedStandardContains("晚上")
                    ? (rawHour < 12 ? rawHour + 12 : rawHour)
                    : rawHour
                return (min(max(hour, 0), 23), min(max(minute, 0), 59))
            }
        }
        if normalized.localizedStandardContains("中午") {
            return (12, 30)
        }
        if normalized.localizedStandardContains("早上") {
            return (9, 0)
        }
        if normalized.localizedStandardContains("晚上") {
            return (20, 0)
        }
        return nil
    }

    private func parseClockNumber(_ value: String) -> Int? {
        let normalized = value
            .replacingOccurrences(of: "〇", with: "零")
            .replacingOccurrences(of: "两", with: "二")
        if let number = Int(normalized) {
            return number
        }
        if normalized == "零" {
            return 0
        }
        return parseChineseNumberString(normalized)
    }

    private func nextSolarReminderDate(for dayString: String, remindBeforeDays: Int) -> Date? {
        let birthday = DateFormatting.date(fromDayString: dayString)
        let calendar = Calendar.current
        let birthdayComponents = calendar.dateComponents([.month, .day], from: birthday)
        guard let month = birthdayComponents.month, let day = birthdayComponents.day else {
            return nil
        }

        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        for offset in 0...1 {
            var birthdayThisYear = DateComponents()
            birthdayThisYear.year = currentYear + offset
            birthdayThisYear.month = month
            birthdayThisYear.day = day
            birthdayThisYear.hour = 0
            birthdayThisYear.minute = 0
            guard
                let birthdayDate = calendar.date(from: birthdayThisYear),
                let rawReminderDate = calendar.date(byAdding: .day, value: -remindBeforeDays, to: birthdayDate)
            else {
                continue
            }
            var reminderComponents = calendar.dateComponents([.year, .month, .day], from: rawReminderDate)
            reminderComponents.hour = 12
            reminderComponents.minute = 30
            guard let reminderDate = calendar.date(from: reminderComponents) else {
                continue
            }
            if reminderDate > now {
                return reminderDate
            }
        }
        return nil
    }

    private func nextLunarReminderDate(
        lunarMonth: Int?,
        lunarDay: Int?,
        isLeapMonth: Bool,
        remindBeforeDays: Int
    ) -> Date? {
        guard let lunarMonth, let lunarDay else { return nil }

        let lunarCalendar = Calendar(identifier: .chinese)
        let gregorianCalendar = Calendar.current
        let now = Date()
        let currentYear = lunarCalendar.component(.year, from: now)

        for offset in 0...2 {
            var birthdayComponents = DateComponents()
            birthdayComponents.calendar = lunarCalendar
            birthdayComponents.year = currentYear + offset
            birthdayComponents.month = lunarMonth
            birthdayComponents.day = lunarDay
            birthdayComponents.isLeapMonth = isLeapMonth

            guard
                let birthdayDate = lunarCalendar.date(from: birthdayComponents),
                let reminderDate = gregorianCalendar.date(byAdding: .day, value: -remindBeforeDays, to: birthdayDate)
            else {
                continue
            }

            if reminderDate > now {
                return reminderDate
            }
        }

        return nil
    }
}

struct LegacyBirthdayToolResult {
    let event: BirthdayEvent
    let reminderTask: ReminderTask?
    let completionMessage: String
    var reminderInfo: CardReminderInfo? = nil
}

extension AVAudioPCMBuffer {
    func legacyCopyBuffer() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return nil
        }
        copy.frameLength = frameLength
        if let src = floatChannelData, let dst = copy.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(frameLength))
            }
        } else if let src = int16ChannelData, let dst = copy.int16ChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(frameLength))
            }
        } else if let src = int32ChannelData, let dst = copy.int32ChannelData {
            for channel in 0..<Int(format.channelCount) {
                dst[channel].initialize(from: src[channel], count: Int(frameLength))
            }
        }
        return copy
    }
}

@MainActor
final class LegacyToolDispatcher {
    private let birthdayExecutor = BirthdayToolExecutor()
    private let store = LocalStore()

    struct ToolExecutionResult {
        let completionMessage: String
        let reminderInfo: CardReminderInfo?
        let metadata: [String: String]?
    }

    func execute(plan: AgentToolPlan, card: MemoryCard) async throws -> ToolExecutionResult {
        let executionCard = enrichedCard(card, with: plan)
        switch plan.tool {
        case "counter.add":
            var category = "coffee"
            var name = "记录"
            var count = 1
            if let cat = plan.params["category"], case .string(let s) = cat { category = s }
            if let n = plan.params["name"], case .string(let s) = n { name = s }
            if let c = plan.params["count"] {
                if case .number(let d) = c { count = Int(d) }
                else if case .string(let s) = c { count = Int(s) ?? 1 }
            }

            let totalCount = try getCounterTotal(category: category) + count

            let message = "已记下，这是你本月第 \(totalCount) 杯\(category == "coffee" ? "咖啡" : name)。"

            return ToolExecutionResult(
                completionMessage: message,
                reminderInfo: CardReminderInfo(
                    type: "counter",
                    personName: category,
                    date: DateFormatting.todayString(),
                    remindBeforeDays: 0,
                    nextTriggerDate: nil,
                    status: "completed",
                    calendarEventId: nil,
                    reminderItemId: nil,
                    notificationRequestId: nil
                ),
                metadata: [
                    "category": category,
                    "name": name,
                    "count": String(count),
                    "total_count": String(totalCount)
                ]
            )

        case "card.ask_user":
            return ToolExecutionResult(
                completionMessage: executionCard.message.isEmpty ? "请确认下一步。" : executionCard.message,
                reminderInfo: nil,
                metadata: executionCard.metadata
            )

        case "memory.save", "record_only":
            let recordTitle = executionCard.metadata?["title"] ?? executionCard.title
            return ToolExecutionResult(
                completionMessage: plan.tool == "record_only" ? "已保存。" : "已记录。",
                reminderInfo: CardReminderInfo(
                    type: "record",
                    personName: recordTitle.isEmpty ? "普通记录" : recordTitle,
                    date: DateFormatting.todayString(),
                    remindBeforeDays: 0,
                    nextTriggerDate: nil,
                    status: "none",
                    calendarEventId: nil,
                    reminderItemId: nil,
                    notificationRequestId: nil
                ),
                metadata: executionCard.metadata
            )

        case "create_solar_birthday_reminder", "reminder.create_solar_birthday":
            let opt = CardOption(key: "C", label: "阳历生日", value: "create_solar_birthday_reminder")
            let result = try await birthdayExecutor.execute(option: opt, card: executionCard)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: executionCard.metadata
            )

        case "create_lunar_birthday_reminder", "reminder.create_lunar_birthday", "lunar_series.create":
            let opt = CardOption(key: "B", label: "阴历生日", value: "create_lunar_birthday_reminder")
            let result = try await birthdayExecutor.execute(option: opt, card: executionCard)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: executionCard.metadata
            )

        case "create_date_reminder", "create_reminder", "reminder.create", "calendar.create_event", "notification.schedule":
            let opt = CardOption(key: "B", label: "创建日期提醒", value: "create_date_reminder")
            let result = try await birthdayExecutor.execute(option: opt, card: executionCard)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: executionCard.metadata
            )

        case "family_holiday_reminders.create":
            let remindBeforeDays = plan.params["remind_before_days"]?.intValue ?? 5
            let result = try await birthdayExecutor.createFamilyHolidayReminders(card: executionCard, remindBeforeDays: remindBeforeDays)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: executionCard.metadata
            )

        default:
            throw JotlyError.unsupportedTool(plan.tool)
        }
    }

    private func enrichedCard(_ card: MemoryCard, with plan: AgentToolPlan) -> MemoryCard {
        var updated = card
        var metadata = updated.metadata ?? [:]
        for (key, value) in plan.params {
            if let string = value.stringValue {
                metadata[key] = string
            }
        }
        metadata["tool"] = plan.tool
        updated.metadata = metadata

        var entities = updated.entities ?? BirthdayEntities(
            personName: nil,
            eventType: nil,
            dateText: nil,
            date: nil,
            remindBeforeDays: nil,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: nil
        )
        entities.personName = metadata["person_name"] ?? metadata["personName"] ?? metadata["subject"] ?? metadata["title"] ?? entities.personName
        entities.eventType = metadata["event_type"] ?? metadata["eventType"] ?? metadata["title"] ?? entities.eventType
        entities.dateText = metadata["date_text"] ?? metadata["dateText"] ?? metadata["date"] ?? metadata["solar_date"] ?? metadata["start_date"] ?? entities.dateText
        entities.date = metadata["date"] ?? metadata["solar_date"] ?? metadata["start_date"] ?? metadata["due_date"] ?? entities.date
        entities.remindBeforeDays = plan.params["remind_before_days"]?.intValue
            ?? plan.params["remindBeforeDays"]?.intValue
            ?? entities.remindBeforeDays
        entities.lunarMonth = plan.params["lunar_month"]?.intValue ?? entities.lunarMonth
        entities.lunarDay = plan.params["lunar_day"]?.intValue ?? entities.lunarDay
        if let leap = metadata["is_leap_month"] ?? metadata["isLeapMonth"] {
            entities.isLeapMonth = leap == "true"
        }
        updated.entities = entities
        return updated
    }

    private func getCounterTotal(category: String) throws -> Int {
        let snapshot = try store.load()
        let matchingCards = snapshot.cards.filter {
            $0.type == "counter" && $0.metadata?["category"] == category
        }
        let total = matchingCards.reduce(0) { sum, card in
            let c = card.metadata?["count"].flatMap { Int($0) } ?? 0
            return sum + c
        }
        return total
    }
}
