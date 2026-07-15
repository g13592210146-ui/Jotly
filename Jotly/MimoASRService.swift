import AVFoundation
import Foundation
import os

/// 小米 MIMO ASR 语音识别服务
///
/// 核心思路：
/// 1. 录音期间缓存音频并按增量片段上传
/// 2. 松手后只补发尚未上传的音频
/// 3. 避免周期性重发整段音频导致同一句话被多次识别和追加
final class MimoASRService {

    // MARK: - 配置

    private var apiKey: String { JotlySecrets.mimoASRAPIKey }
    private let baseURL = "https://api.xiaomimimo.com/v1/chat/completions"
    private let model = "mimo-v2.5-asr"

    // MARK: - 录音状态

    private lazy var audioEngine = AVAudioEngine()
    private var recordedBuffers: [AVAudioPCMBuffer] = []
    private var recordingFormat: AVAudioFormat?
    private var submittedBufferCount = 0
    private var liveTranscriptionTask: Task<Void, Never>?
    private let stateQueue = DispatchQueue(label: "jotly.mimo.state")

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        try stateQueue.sync(execute: body)
    }

    // MARK: - 权限

    @MainActor
    func requestPermissions() async throws {
        let micGranted = await Self.requestMicrophonePermission()
        guard micGranted else {
            throw JotlyError.microphonePermissionDenied
        }
    }

    // MARK: - 录音控制

    /// 开始录音。
    /// - Parameters:
    ///   - onTranscript: 实时转写回调（每收到一个 SSE chunk 就调用）
    ///   - onVolumeChanged: 音量振幅回调（用于 UI 动画）
        @MainActor
    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onVolumeChanged: @escaping @MainActor (Float) -> Void
    ) async throws {
        try await requestPermissions()
        resetRecorderForStart()
        try configureAudioSession()

        let inputNode = audioEngine.inputNode
        try validateInputFormat(inputNode.outputFormat(forBus: 0))
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            if let copy = buffer.copyBuffer() {
                self.withState {
                    if self.recordingFormat == nil {
                        self.recordingFormat = copy.format
                    }
                    self.recordedBuffers.append(copy)
                }
            }
            let level = Self.calculateLevel(from: buffer)
            Task { @MainActor in
                onVolumeChanged(level)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            resetRecorderForStart()
            throw error
        }
        liveTranscriptionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.sendPendingAudioChunk(
                    minimumBufferCount: 3,
                    onTranscript: onTranscript
                )
            }
        }
        JotlyLog.speech.info("MimoASR 录音已开始")
    }

    /// 停止录音，做最后一次流式发送拿到最终结果
    @MainActor
    func stop() async throws -> String {
        JotlyLog.speech.info("MimoASR 停止录音")

        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        stopRecorderKeepingBuffers()

        // 最后只发送还没被实时任务处理过的尾段。
        JotlyLog.speech.info("MimoASR 发送剩余音频...")
        let finalText = await sendPendingAudioChunk(
            minimumBufferCount: 1,
            onTranscript: { _, _ in }
        )
        JotlyLog.speech.info("MimoASR 尾段识别结果: \(finalText, privacy: .public)")
        clearRecordedBuffers()
        return finalText
    }

    /// 取消录音，不发送最终请求
    @MainActor
    func cancel() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        resetRecorderForStart()
        JotlyLog.speech.info("MimoASR 录音已取消")
    }

    // MARK: - 发送

    /// 只发送从上次上传之后新增的音频，避免重复识别已显示文本。
    @discardableResult
    private func sendPendingAudioChunk(
        minimumBufferCount: Int,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) async -> String {
        let snapshot = withState { () -> (startIndex: Int, endIndex: Int, format: AVAudioFormat?, buffers: [AVAudioPCMBuffer]?) in
            let startIndex = submittedBufferCount
            let endIndex = recordedBuffers.count
            let format = recordingFormat ?? recordedBuffers.first?.format
            guard endIndex > startIndex, endIndex - startIndex >= minimumBufferCount else {
                return (startIndex, endIndex, format, nil)
            }
            return (startIndex, endIndex, format, Array(recordedBuffers[startIndex..<endIndex]))
        }

        guard let buffers = snapshot.buffers else {
            return ""
        }

        guard !buffers.isEmpty, let format = snapshot.format else { return "" }

        let totalFrames = buffers.reduce(0) { $0 + $1.frameLength }
        guard totalFrames > 0 else { return "" }

        do {
            let wavData = try Self.encodeAllBuffersToWAV(buffers: buffers, format: format)
            var finalText = ""
            try await streamRecognize(wavData: wavData) { text, _ in
                finalText = text
                onTranscript(text, false)
            }
            if !finalText.isEmpty {
                await MainActor.run {
                    onTranscript(finalText, true)
                }
            }
            withState {
                submittedBufferCount = max(submittedBufferCount, snapshot.endIndex)
            }
            return finalText
        } catch {
            JotlyLog.speech.error("MimoASR 增量识别失败: \(error.localizedDescription, privacy: .public)")
            return ""
        }
    }

    // MARK: - SSE 请求

    /// 向 MIMO API 发送 POST 请求（stream: true），逐 chunk 解析 SSE 并回调。
    private func streamRecognize(
        wavData: Data,
        onTranscript: @escaping @MainActor (String, Bool) -> Void
    ) async throws {
        let audioBase64 = wavData.base64EncodedString()

        let requestBody = MimoASRStreamRequest(
            model: model,
            messages: [
                MimoASRMessage(
                    role: "user",
                    content: [
                        MimoASRContent(
                            type: "input_audio",
                            inputAudio: MimoASRInputAudio(
                                data: "data:audio/wav;base64,\(audioBase64)"
                            )
                        )
                    ]
                )
            ],
            stream: true,
            extraBody: MimoASRExtraBody(
                asrOptions: MimoASROptions(language: "zh")
            )
        )

        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = try JSONEncoder().encode(requestBody)

        // 使用 URLSession 的 bytes (async sequence) 来流式读取 SSE
        let session = URLSession.shared
        let (bytes, response) = try await session.bytes(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                var errorBody = ""
                for try await line in bytes.lines {
                    errorBody += line
                    if errorBody.count > 2000 { break }
                }
                JotlyLog.speech.error("MimoASR API 错误: \(errorBody, privacy: .public)")
                throw JotlyError.speechStartFailed("MIMO API (\(httpResponse.statusCode))")
            }
        }

        var currentStreamingText = ""
        for try await line in bytes.lines {
            if Task.isCancelled { return }

            // SSE 格式: "data: {...}"
            guard line.hasPrefix("data: ") else { continue }
            let jsonStr = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)

            // 结束标记
            if jsonStr == "[DONE]" { break }

            guard let jsonData = jsonStr.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(MimoASRStreamChunk.self, from: jsonData)
                if let delta = chunk.choices?.first?.delta?.content, !delta.isEmpty {
                    currentStreamingText += delta
                    await MainActor.run {
                        onTranscript(currentStreamingText, false)
                    }
                }
            } catch {
                // 跳过无法解析的 chunk
                JotlyLog.speech.debug("MimoASR SSE parse skip: \(jsonStr.prefix(100), privacy: .public)")
            }
        }

    }

    // MARK: - WAV 编码

    /// 将多个 PCM buffer 合并后编码为 WAV
    private static func encodeAllBuffersToWAV(buffers: [AVAudioPCMBuffer], format: AVAudioFormat) throws -> Data {
        let totalFrames = buffers.reduce(0) { $0 + $1.frameLength }
        guard totalFrames > 0 else { throw JotlyError.speechUnavailable }

        guard let mergedBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else {
            throw JotlyError.speechUnavailable
        }
        mergedBuffer.frameLength = totalFrames

        var offset: AVAudioFrameCount = 0
        for buffer in buffers {
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { continue }
            if let src = buffer.floatChannelData, let dst = mergedBuffer.floatChannelData {
                for ch in 0..<Int(format.channelCount) {
                    memcpy(dst[ch] + Int(offset), src[ch], frameCount * MemoryLayout<Float>.size)
                }
            }
            offset += AVAudioFrameCount(frameCount)
        }

        return try encodeToWAV(buffer: mergedBuffer, format: format)
    }

    /// 将 PCM buffer 编码为 WAV 格式的数据（16-bit PCM）
    private static func encodeToWAV(buffer: AVAudioPCMBuffer, format: AVAudioFormat) throws -> Data {
        let channelCount = Int(format.channelCount)
        let sampleRate = format.sampleRate
        let frameLength = Int(buffer.frameLength)

        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let blockAlign = channelCount * bytesPerSample
        let byteRate = Int(sampleRate) * blockAlign
        let dataSize = frameLength * blockAlign
        let fileSize = 36 + dataSize

        var wavData = Data()

        // RIFF header
        wavData.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        wavData.append(littleEndian32: UInt32(fileSize))
        wavData.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt chunk
        wavData.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        wavData.append(littleEndian32: 16)
        wavData.append(littleEndian16: 1) // PCM
        wavData.append(littleEndian16: UInt16(channelCount))
        wavData.append(littleEndian32: UInt32(sampleRate))
        wavData.append(littleEndian32: UInt32(byteRate))
        wavData.append(littleEndian16: UInt16(blockAlign))
        wavData.append(littleEndian16: UInt16(bitsPerSample))

        // data chunk
        wavData.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        wavData.append(littleEndian32: UInt32(dataSize))

        // PCM 数据（float -> 16-bit int）
        if let floatData = buffer.floatChannelData {
            for frame in 0..<frameLength {
                for ch in 0..<channelCount {
                    let sample = floatData[ch][frame]
                    let clamped = max(-1.0, min(1.0, sample))
                    let int16Sample = Int16(clamped * 32767.0)
                    withUnsafeBytes(of: int16Sample.littleEndian) { wavData.append(contentsOf: $0) }
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            for frame in 0..<frameLength {
                for ch in 0..<channelCount {
                    let sample = int16Data[ch][frame]
                    withUnsafeBytes(of: sample.littleEndian) { wavData.append(contentsOf: $0) }
                }
            }
        } else {
            throw JotlyError.speechUnavailable
        }

        return wavData
    }

    // MARK: - 工具方法

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
    private func resetRecorderForStart() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        clearRecordedBuffers()
    }

    @MainActor
    private func stopRecorderKeepingBuffers() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func clearRecordedBuffers() {
        withState {
            recordedBuffers.removeAll()
            recordingFormat = nil
            submittedBufferCount = 0
        }
    }

    private func validateInputFormat(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            JotlyLog.speech.error(
                "MimoASR invalid input format: channels=\(format.channelCount, privacy: .public), sampleRate=\(format.sampleRate, privacy: .public)"
            )
            throw JotlyError.speechStartFailed("麦克风输入暂时不可用，请稍后再试。")
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
        let scaled = sqrt(rms) * 4.5
        return min(max(scaled, 0.0), 1.0)
    }
}

// MARK: - Data 追加小端字节

private extension Data {
    mutating func append(littleEndian16 value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func append(littleEndian32 value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }
}

// MARK: - MIMO ASR API 模型（请求）

struct MimoASRMessage: Encodable {
    let role: String
    let content: [MimoASRContent]
}

struct MimoASRContent: Encodable {
    let type: String
    let inputAudio: MimoASRInputAudio

    enum CodingKeys: String, CodingKey {
        case type
        case inputAudio = "input_audio"
    }
}

struct MimoASRInputAudio: Encodable {
    let data: String
}

struct MimoASRExtraBody: Encodable {
    let asrOptions: MimoASROptions

    enum CodingKeys: String, CodingKey {
        case asrOptions = "asr_options"
    }
}

struct MimoASROptions: Encodable {
    let language: String
}

/// 流式请求体（带 stream 字段）
struct MimoASRStreamRequest: Encodable {
    let model: String
    let messages: [MimoASRMessage]
    let stream: Bool
    let extraBody: MimoASRExtraBody

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case extraBody = "extra_body"
    }
}

// MARK: - MIMO ASR API 模型（流式响应，OpenAI SSE 格式）

/// SSE 中的单个 chunk
struct MimoASRStreamChunk: Decodable {
    let choices: [MimoASRStreamChoice]?
}

struct MimoASRStreamChoice: Decodable {
    let delta: MimoASRStreamDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case delta
        case finishReason = "finish_reason"
    }
}

struct MimoASRStreamDelta: Decodable {
    let content: String?
}
