import AVFoundation
import Foundation
import os

final class AliyunASRService {
    private var apiKey: String { JotlySecrets.aliyunASRAPIKey }
    private let client = AliyunNuiASRClient()

    @MainActor
    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onVolumeChanged: @escaping @MainActor (Float) -> Void
    ) async throws {
        try await client.start(
            apiKey: apiKey,
            onTranscript: onTranscript,
            onVolumeChanged: onVolumeChanged
        )
    }

    @MainActor
    func stop() async throws -> String {
        try await client.stop()
    }

    @MainActor
    func cancel() {
        client.cancel()
    }
}

private final class AliyunNuiASRClient: NSObject, NeoNuiSdkDelegate {
    private let lock = NSLock()
    nonisolated(unsafe) private var audioQueue = Data()
    nonisolated(unsafe) private var confirmedText = ""
    nonisolated(unsafe) private var currentPartialText = ""
    nonisolated(unsafe) private var latestText = ""
    nonisolated(unsafe) private var finalText = ""
    nonisolated(unsafe) private var errorMessage: String?
    nonisolated(unsafe) private var isCompleted = false
    nonisolated(unsafe) private var isReady = false
    nonisolated(unsafe) private var continuation: CheckedContinuation<String, Error>?
    nonisolated(unsafe) private var readyContinuation: CheckedContinuation<Void, Error>?
    nonisolated(unsafe) private var onTranscript: (@MainActor (String, Bool) -> Void)?
    nonisolated(unsafe) private var onVolumeChanged: (@MainActor (Float) -> Void)?
    nonisolated(unsafe) private var nui: NeoNui?
    nonisolated(unsafe) private let audioEngine = AVAudioEngine()
    nonisolated(unsafe) private var converter: AVAudioConverter?
    nonisolated(unsafe) private var targetFormat: AVAudioFormat?

    private enum StopContinuationOutcome {
        case returning(String)
        case throwing(String)
        case wait
    }

    @MainActor
    func start(
        apiKey: String,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onVolumeChanged: @escaping @MainActor (Float) -> Void
    ) async throws {
        guard !apiKey.isEmpty else {
            throw JotlyError.missingASRConfiguration("阿里云缺少 DashScope API Key。")
        }
        guard await RemoteASRAudioRecorder.requestMicrophonePermission() else {
            throw JotlyError.microphonePermissionDenied
        }

        self.onTranscript = onTranscript
        self.onVolumeChanged = onVolumeChanged
        if let existing = nui {
            existing.nui_release()
            self.nui = nil
        }
        resetState()

        guard let instance = NeoNui.get_instance() else {
            throw JotlyError.speechStartFailed("阿里云 NUI SDK 实例创建失败。")
        }
        instance.delegate = self
        nui = instance

        let initCode = withJSONObjectCString([
            "url": "wss://dashscope.aliyuncs.com/api-ws/v1/inference",
            "apikey": apiKey,
            "device_id": "jotly-ios-asr-test",
            "service_mode": "1",
            "log_track_level": "\(NUI_LOG_LEVEL_WARNING.rawValue)"
        ]) { cString in
            instance.nui_initialize(
                cString,
                logLevel: NUI_LOG_LEVEL_WARNING,
                saveLog: false
            )
        }
        guard initCode == SUCCESS else {
            throw JotlyError.speechStartFailed("阿里云 NUI 初始化失败：\(initCode)")
        }

        let paramsCode = withJSONObjectCString([
            "service_type": SERVICE_TYPE_SPEECH_TRANSCRIBER.rawValue,
            "nls_config": [
                "model": "fun-asr-realtime-2026-02-28",
                "sr_format": "pcm",
                "sample_rate": 16000,
                "transcription_enabled": true,
                "enable_intermediate_result": true,
                "enable_sentence_detection": true,
                "enable_inverse_text_normalization": true,
                "enable_word_level_result": true,
                "enable_ignore_sentence_timeout": false,
                "max_sentence_silence": 800,
                "language_hints": ["zh"]
            ]
        ]) { cString in
            instance.nui_set_params(cString)
        }
        guard paramsCode == SUCCESS else {
            instance.nui_release()
            throw JotlyError.speechStartFailed("阿里云 NUI 参数设置失败：\(paramsCode)")
        }

        try await configureRecorder()
        let startCode = withJSONObjectCString(["apikey": apiKey]) { cString in
            instance.nui_dialog_start(MODE_P2T, dialogParam: cString)
        }
        guard startCode == SUCCESS else {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            instance.nui_release()
            throw JotlyError.speechStartFailed("阿里云 NUI 启动失败：\(startCode)")
        }
        try await waitUntilReady(timeoutNanoseconds: 1_500_000_000)
        JotlyLog.speech.info("AliyunASR NUI 识别已就绪")
    }

    @MainActor
    func stop() async throws -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let nui else {
            return latestText
        }
        let stopCode = nui.nui_dialog_cancel(false)
        guard stopCode == SUCCESS else {
            nui.nui_release()
            throw JotlyError.speechStartFailed("阿里云 NUI 停止失败：\(stopCode)")
        }

        return try await withCheckedThrowingContinuation { continuation in
            switch lock.withLock({ () -> StopContinuationOutcome in
                if isCompleted {
                    return .returning(finalText.isEmpty ? latestText : finalText)
                } else if let errorMessage {
                    return .throwing(errorMessage)
                } else {
                    self.continuation = continuation
                    return .wait
                }
            }) {
            case .returning(let result):
                nui.nui_release()
                self.nui = nil
                continuation.resume(returning: result)
            case .throwing(let errorMessage):
                nui.nui_release()
                self.nui = nil
                continuation.resume(throwing: JotlyError.speechStartFailed(errorMessage))
            case .wait:
                break
            }
        }
    }

    @MainActor
    func cancel() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        nui?.nui_dialog_cancel(true)
        nui?.nui_release()
        nui = nil
        failReadyIfNeeded("阿里云识别已取消。")
        resumeIfNeeded(returning: "")
        resetState()
        JotlyLog.speech.info("AliyunASR NUI 识别已取消")
    }

    nonisolated func onNuiNeedAudioData(_ audioData: UnsafeMutablePointer<CChar>!, length len: Int32) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !audioQueue.isEmpty else { return 0 }
        let count = min(Int(len), audioQueue.count)
        audioQueue.withUnsafeBytes { rawBuffer in
            if let base = rawBuffer.baseAddress {
                audioData.update(from: base.assumingMemoryBound(to: CChar.self), count: count)
            }
        }
        audioQueue.removeFirst(count)
        return Int32(count)
    }

    nonisolated func onNuiEventCallback(
        _ nuiEvent: NuiCallbackEvent,
        dialog: Int,
        kwsResult wuw: UnsafePointer<CChar>!,
        asrResult asr_result: UnsafePointer<CChar>!,
        ifFinish finish: Bool,
        retCode code: Int32
    ) {
        if nuiEvent == EVENT_TRANSCRIBER_STARTED || nuiEvent == EVENT_ASR_STARTED {
            markReadyIfNeeded()
        } else if nuiEvent == EVENT_ASR_PARTIAL_RESULT || nuiEvent == EVENT_ASR_RESULT || nuiEvent == EVENT_SENTENCE_END {
            let text = parseCurrentSentenceText(from: asr_result)
            guard !text.isEmpty else { return }
            let isFinalText = nuiEvent == EVENT_SENTENCE_END
            lock.lock()
            let displayText = applyAliyunTranscriptLocked(text, isFinal: isFinalText)
            lock.unlock()
            Task { @MainActor in
                self.onTranscript?(displayText, isFinalText)
            }
        } else if nuiEvent == EVENT_TRANSCRIBER_COMPLETE {
            completeIfNeeded()
        } else if nuiEvent == EVENT_ASR_ERROR {
            let response = currentResponseString()
            failIfNeeded("阿里云识别错误 \(code)：\(response)")
        } else if nuiEvent == EVENT_MIC_ERROR {
            failIfNeeded("阿里云 SDK 2 秒未收到音频数据。")
        }
    }

    nonisolated func onNuiAudioStateChanged(_ state: NuiAudioState) {
        if state == STATE_OPEN {
            markReadyIfNeeded()
        } else if state == STATE_CLOSE || state == STATE_PAUSE {
            Task { @MainActor in
                self.audioEngine.stop()
                self.audioEngine.inputNode.removeTap(onBus: 0)
            }
        }
    }

    private func configureRecorder() async throws {
        audioEngine.reset()

        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            #if os(iOS)
            if #available(iOS 13.0, *) {
                try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            if let inputs = session.availableInputs,
               let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtInMic)
            }
            #endif
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        }.value

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            JotlyLog.speech.error("AliyunASR: AVAudioEngine input format is invalid (0 ch/0 Hz). Hardware mic may not be ready.")
            throw JotlyError.speechUnavailable
        }

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw JotlyError.speechUnavailable
        }
        self.targetFormat = outputFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let level = RemoteASRAudioRecorder.calculateLevel(from: buffer)
            Task { @MainActor in
                self.onVolumeChanged?(level)
            }
            self.appendConvertedAudio(buffer, outputFormat: outputFormat)
        }

        audioEngine.prepare()
        try await Task.detached(priority: .userInitiated) { [weak self] in
            try self?.audioEngine.start()
        }.value
    }

    private func appendConvertedAudio(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat
    ) {
        let inputFormat = buffer.format
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        if converter == nil {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                JotlyLog.speech.error("AliyunASR 音频转换器创建失败")
                return
            }
            converter = newConverter
        }
        guard let converter else { return }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return
        }

        var hasData = true
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if hasData {
                hasData = false
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        var error: NSError?
        converter.convert(to: converted, error: &error, withInputFrom: inputBlock)
        guard error == nil, let channelData = converted.int16ChannelData else { return }
        let byteCount = Int(converted.frameLength) * MemoryLayout<Int16>.size
        let data = Data(bytes: channelData[0], count: byteCount)
        lock.lock()
        audioQueue.append(data)
        lock.unlock()
    }

    private func resetState() {
        lock.lock()
        audioQueue.removeAll()
        confirmedText = ""
        currentPartialText = ""
        latestText = ""
        finalText = ""
        errorMessage = nil
        isCompleted = false
        isReady = false
        continuation = nil
        readyContinuation = nil
        lock.unlock()
    }

    private func waitUntilReady(timeoutNanoseconds: UInt64) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isReady {
                lock.unlock()
                continuation.resume(returning: ())
                return
            }
            readyContinuation = continuation
            lock.unlock()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.failReadyIfNeeded("阿里云 NUI 连接超时，请稍后再试。")
            }
        }
    }

    private nonisolated func markReadyIfNeeded() {
        lock.lock()
        guard !isReady else {
            lock.unlock()
            return
        }
        isReady = true
        let continuation = readyContinuation
        readyContinuation = nil
        lock.unlock()
        continuation?.resume(returning: ())
    }

    private nonisolated func failReadyIfNeeded(_ message: String) {
        lock.lock()
        guard !isReady, let continuation = readyContinuation else {
            lock.unlock()
            return
        }
        readyContinuation = nil
        errorMessage = message
        lock.unlock()
        continuation.resume(throwing: JotlyError.speechStartFailed(message))
    }

    private nonisolated func applyAliyunTranscriptLocked(_ rawText: String, isFinal: Bool) -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return latestText
        }

        if isFinal {
            if !confirmedText.isEmpty, text.hasPrefix(confirmedText) {
                confirmedText = text
            } else {
                confirmedText = joinedTranscriptLocked(confirmedText, text)
            }
            currentPartialText = ""
            latestText = confirmedText
            finalText = confirmedText
            return latestText
        }

        currentPartialText = partialTranscriptLocked(text, after: confirmedText)
        latestText = joinedTranscriptLocked(confirmedText, currentPartialText)
        return latestText
    }

    private nonisolated func partialTranscriptLocked(_ text: String, after confirmed: String) -> String {
        let confirmedText = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmedText.isEmpty, incoming.hasPrefix(confirmedText) else {
            return incoming
        }
        return String(incoming.dropFirst(confirmedText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func joinedTranscriptLocked(_ left: String, _ right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        if lhs.hasSuffix(rhs) || lhs.contains(rhs) { return lhs }
        if rhs.hasPrefix(lhs) { return rhs }
        let overlap = suffixPrefixOverlapLocked(lhs, rhs)
        if overlap > 0 {
            return lhs + String(rhs.dropFirst(overlap))
        }
        if shouldInsertSpaceLocked(between: lhs, and: rhs) {
            return "\(lhs) \(rhs)"
        }
        return lhs + rhs
    }

    private nonisolated func shouldInsertSpaceLocked(between left: String, and right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        return last.isASCII && first.isASCII && (last.isLetter || last.isNumber) && (first.isLetter || first.isNumber)
    }

    private nonisolated func suffixPrefixOverlapLocked(_ left: String, _ right: String) -> Int {
        let leftChars = Array(left)
        let rightChars = Array(right)
        let maxLength = min(leftChars.count, rightChars.count)
        guard maxLength > 0 else { return 0 }
        for length in stride(from: maxLength, through: 1, by: -1) {
            let leftSuffix = leftChars[(leftChars.count - length)..<leftChars.count]
            let rightPrefix = rightChars[0..<length]
            if Array(leftSuffix) == Array(rightPrefix) {
                return length
            }
        }
        return 0
    }

    private nonisolated func parseCurrentSentenceText(from callbackResponse: UnsafePointer<CChar>!) -> String {
        let response = callbackResponse.map { String(cString: $0) }
        if let text = extractAliyunTranscriptText(from: response) {
            return text
        }
        return extractAliyunTranscriptText(from: currentResponseString()) ?? ""
    }

    private nonisolated func currentResponseString() -> String {
        guard let response = nui?.nui_get_all_response() else { return "" }
        return String(cString: response)
    }

    private nonisolated func extractAliyunTranscriptText(from rawResponse: String?) -> String? {
        guard let rawResponse = rawResponse?.trimmingCharacters(in: .whitespacesAndNewlines), !rawResponse.isEmpty else {
            return nil
        }

        if let data = rawResponse.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) {
            return extractAliyunTranscriptText(from: json)
        }

        return rawResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated func extractAliyunTranscriptText(from object: Any) -> String? {
        switch object {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let array as [Any]:
            for item in array {
                if let text = extractAliyunTranscriptText(from: item), !text.isEmpty {
                    return text
                }
            }
            return nil
        case let dict as [String: Any]:
            let prioritizedKeys = [
                "text",
                "transcript",
                "transcription",
                "sentence",
                "output",
                "result",
                "results",
                "response",
                "payload"
            ]

            for key in prioritizedKeys {
                if let value = dict[key], let text = extractAliyunTranscriptText(from: value), !text.isEmpty {
                    return text
                }
            }

            for value in dict.values {
                if let text = extractAliyunTranscriptText(from: value), !text.isEmpty {
                    return text
                }
            }
            return nil
        default:
            return nil
        }
    }

    private nonisolated func completeIfNeeded() {
        lock.lock()
        isCompleted = true
        let result = finalText.isEmpty ? latestText : finalText
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if let continuation {
            Task { @MainActor in
                self.nui?.nui_release()
                self.nui = nil
                continuation.resume(returning: result)
            }
        }
    }

    private nonisolated func failIfNeeded(_ message: String) {
        lock.lock()
        errorMessage = message
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        if let continuation {
            Task { @MainActor in
                self.nui?.nui_release()
                self.nui = nil
                continuation.resume(throwing: JotlyError.speechStartFailed(message))
            }
        }
    }

    private func resumeIfNeeded(returning value: String) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }

    private func withJSONObjectCString<T>(_ object: Any, _ body: (UnsafePointer<CChar>) -> T) -> T {
        let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        let string = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return string.withCString(body)
    }
}

final class RemoteASRAudioRecorder {
    private let serviceName: String
    private lazy var audioEngine = AVAudioEngine()

    init(serviceName: String) {
        self.serviceName = serviceName
    }

    @MainActor
    func start(onVolumeChanged: @escaping @MainActor (Float) -> Void) async throws {
        guard await Self.requestMicrophonePermission() else {
            throw JotlyError.microphonePermissionDenied
        }
        try configureAudioSession()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            let level = Self.calculateLevel(from: buffer)
            Task { @MainActor in
                onVolumeChanged(level)
            }
        }

        audioEngine.prepare()
        try audioEngine.start()
        JotlyLog.speech.info("\(self.serviceName, privacy: .public) recorder started")
    }

    @MainActor
    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    @MainActor
    func cancel() {
        stop()
    }

    @MainActor
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        #if os(iOS)
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        if let inputs = session.availableInputs,
           let builtInMic = inputs.first(where: { $0.portType == .builtInMic }) {
            try? session.setPreferredInput(builtInMic)
        }
        #endif
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    static func requestMicrophonePermission() async -> Bool {
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

    static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
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
        let scaled = sqrt(rms) * 4.5
        return min(max(scaled, 0.0), 1.0)
    }
}
