import AVFoundation
import Foundation
import os
import zlib

final class DoubaoASRService {
    private let appID = "4583950460"
    private var accessToken: String { JotlySecrets.doubaoASRAccessToken }
    private let resourceID = "volc.seedasr.sauc.duration"
    private let websocketURL = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async"
    private let model = "bigmodel"
    private let client = DoubaoRealtimeASRClient()

    @MainActor
    func start(
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onVolumeChanged: @escaping @MainActor (Float) -> Void
    ) async throws {
        try await client.start(
            appID: appID,
            accessToken: accessToken,
            resourceID: resourceID,
            websocketURL: websocketURL,
            model: model,
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

private final class DoubaoRealtimeASRClient {
    private enum MessageType: UInt8 {
        case fullClientRequest = 0b0001
        case audioOnlyRequest = 0b0010
        case fullServerResponse = 0b1001
        case serverAckOrAudioResponse = 0b1011
        case errorResponse = 0b1111
    }

    private enum MessageFlag: UInt8 {
        case none = 0b0000
        case withPositiveSequence = 0b0001
        case lastPacket = 0b0010
        case withNegativeSequence = 0b0011
    }

    private enum SerializationMethod: UInt8 {
        case none = 0b0000
        case json = 0b0001
    }

    private enum CompressionMethod: UInt8 {
        case none = 0b0000
        case gzip = 0b0001
    }

    private let audioSampleRate: Double = 16_000
    private let sendQueue = DispatchQueue(label: "jotly.doubao.send")
    private let lock = NSLock()
    private let audioEngine = AVAudioEngine()

    private var urlSession: URLSession?
    private var websocketTask: URLSessionWebSocketTask?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var onTranscript: (@MainActor (String, Bool) -> Void)?
    private var onVolumeChanged: (@MainActor (Float) -> Void)?
    private var pendingAudioBuffer = Data()
    private var fullTextSnapshot = ""
    private var interimSnapshot = ""
    private var emittedUtteranceKeys = Set<String>()
    private var sentAudioPacketCount = 0
    private var receivedFrameCount = 0
    private var latestAudioDurationMilliseconds = 0
    private var isRunning = false
    private var isStopping = false
    private var finalText = ""
    private var errorMessage: String?
    private var continuation: CheckedContinuation<String, Error>?

    private enum StopContinuationAction {
        case throwError(String)
        case returning(String)
        case wait
    }

    @MainActor
    func start(
        appID: String,
        accessToken: String,
        resourceID: String,
        websocketURL: String,
        model: String,
        onTranscript: @escaping @MainActor (String, Bool) -> Void,
        onVolumeChanged: @escaping @MainActor (Float) -> Void
    ) async throws {
        guard !appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JotlyError.missingASRConfiguration("豆包缺少 APP ID。")
        }
        guard !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JotlyError.missingASRConfiguration("豆包缺少 Access Token。")
        }
        guard !resourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JotlyError.missingASRConfiguration("豆包缺少 Resource ID。")
        }
        guard await RemoteASRAudioRecorder.requestMicrophonePermission() else {
            throw JotlyError.microphonePermissionDenied
        }

        resetRecorderForStart()
        self.onTranscript = onTranscript
        self.onVolumeChanged = onVolumeChanged
        resetState()

        // 1. 先启动本地音频录音，确保在按住的瞬间立即开始采音，不丢失前置音频
        do {
            try await configureRecorder()
        } catch {
            cleanupAfterStop()
            throw error
        }

        // 2. 然后建立 WebSocket 连接并启动
        guard let url = URL(string: websocketURL) else {
            throw JotlyError.missingASRConfiguration("豆包实时地址无效。")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-Api-Connect-Id")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        urlSession = session
        websocketTask = task

        task.resume()
        isRunning = true
        receiveLoop()
        logHandshakeResponse(from: task)

        // 3. 发送握手后的初始化协议（由 websocket 自动在实际连接建立后发送）
        guard sendInitialRequest(model: model) else {
            cleanupAfterStop()
            throw JotlyError.speechStartFailed("豆包首包发送失败。")
        }
        JotlyLog.speech.info("DoubaoASR websocket started and recorder is active")
    }

    private func logHandshakeResponse(from task: URLSessionWebSocketTask) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            guard let response = task.response as? HTTPURLResponse else {
                JotlyLog.speech.warning("DoubaoASR handshake response unavailable")
                return
            }
            let logID = response.value(forHTTPHeaderField: "X-Tt-Logid") ?? "-"
            let connectID = response.value(forHTTPHeaderField: "X-Api-Connect-Id") ?? "-"
            JotlyLog.speech.info(
                "DoubaoASR handshake status=\(response.statusCode, privacy: .public) X-Tt-Logid=\(logID, privacy: .public) X-Api-Connect-Id=\(connectID, privacy: .public)"
            )
        }
    }

    @MainActor
    func stop() async throws -> String {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard isRunning else {
            return currentText()
        }

        isStopping = true
        flushPendingAudio(isFinal: true)

        return try await withCheckedThrowingContinuation { continuation in
            switch lock.withLock({ () -> StopContinuationAction in
                if let errorMessage {
                    return .throwError(errorMessage)
                }
                if !finalText.isEmpty || (!fullTextSnapshot.isEmpty && websocketTask == nil) {
                    return .returning(currentTextLocked())
                }
                self.continuation = continuation
                return .wait
            }) {
            case .throwError(let message):
                cleanupAfterStop()
                continuation.resume(throwing: JotlyError.speechStartFailed(message))
            case .returning(let result):
                cleanupAfterStop()
                continuation.resume(returning: result)
            case .wait:
                scheduleStopTimeout()
            }
        }
    }

    @MainActor
    func cancel() {
        stopRecorder()
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        websocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        cleanupState()
        continuation?.resume(returning: "")
        JotlyLog.speech.info("DoubaoASR 录音已取消")
    }

    @MainActor
    private func configureRecorder() async throws {
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

        let inputNode = audioEngine.inputNode
        try validateInputFormat(inputNode.outputFormat(forBus: 0))
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: audioSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw JotlyError.speechUnavailable
        }
        self.targetFormat = outputFormat

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            let level = RemoteASRAudioRecorder.calculateLevel(from: buffer)
            Task { @MainActor in
                self.onVolumeChanged?(level)
            }
            self.appendConvertedAudio(buffer, outputFormat: outputFormat)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            stopRecorder()
            throw error
        }
    }

    private func appendConvertedAudio(
        _ buffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat
    ) {
        let inputFormat = buffer.format
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return }
        if converter == nil {
            guard let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                emitError("豆包音频转换器创建失败。")
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
        pendingAudioBuffer.append(data)
        lock.unlock()
        flushPendingAudio(isFinal: false)
    }

    private func sendInitialRequest(model: String) -> Bool {
        let modelName = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "bigmodel" : model
        let payload: [String: Any] = [
            "user": [
                "uid": "jotly-ios"
            ],
            "audio": [
                "format": "pcm",
                "rate": Int(audioSampleRate),
                "bits": 16,
                "channel": 1
            ],
            "request": [
                "reqid": UUID().uuidString,
                "model_name": modelName,
                "enable_itn": true,
                "enable_punc": true,
                "show_utterances": true,
                "result_type": "single",
                "end_window_size": 800
            ]
        ]

        guard let compressedPayload = gzipCompress(jsonData(payload)) else {
            emitError("豆包请求压缩失败，无法启动识别。")
            return false
        }

        sendFrame(
            messageType: .fullClientRequest,
            flag: .none,
            serialization: .json,
            compression: .gzip,
            payload: compressedPayload
        )
        return true
    }

    private func sendAudioChunk(_ data: Data) {
        guard !data.isEmpty else { return }
        let payload = gzipCompress(data) ?? data
        sendFrame(
            messageType: .audioOnlyRequest,
            flag: .none,
            serialization: .none,
            compression: payload == data ? .none : .gzip,
            payload: payload
        )
    }

    private func flushPendingAudio(isFinal: Bool) {
        let packetSize = max(Int(audioSampleRate * 0.2) * 2, 640)
        while true {
            var chunk: Data?
            lock.lock()
            if pendingAudioBuffer.count >= packetSize {
                chunk = pendingAudioBuffer.prefix(packetSize)
                pendingAudioBuffer.removeFirst(packetSize)
            } else if isFinal, !pendingAudioBuffer.isEmpty {
                chunk = pendingAudioBuffer
                pendingAudioBuffer.removeAll(keepingCapacity: false)
            }
            lock.unlock()

            guard let chunk else { break }
            sendAudioChunk(chunk)
        }
        if isFinal {
            sendFrame(
                messageType: .audioOnlyRequest,
                flag: .lastPacket,
                serialization: .none,
                compression: .none,
                payload: Data()
            )
        }
    }

    private func sendFrame(
        messageType: MessageType,
        flag: MessageFlag,
        serialization: SerializationMethod,
        compression: CompressionMethod,
        payload: Data,
        sequence: Int32? = nil
    ) {
        guard isRunning, let websocketTask else { return }
        let frame = makeFrame(
            messageType: messageType,
            flag: flag,
            serialization: serialization,
            compression: compression,
            payload: payload,
            sequence: sequence
        )

        sendQueue.async { [weak self, websocketTask] in
            websocketTask.send(.data(frame)) { error in
                guard let self, self.isRunning else { return }
                if let error {
                    self.emitError("Doubao websocket send failed: \(error.localizedDescription)")
                    self.cleanupAfterStop()
                    self.finishIfPossible(with: self.currentText())
                }
            }
        }
    }

    private func makeFrame(
        messageType: MessageType,
        flag: MessageFlag,
        serialization: SerializationMethod,
        compression: CompressionMethod,
        payload: Data,
        sequence: Int32? = nil
    ) -> Data {
        var frame = Data()
        let version: UInt8 = 0b0001
        let headerSizeWords: UInt8 = 0b0001
        frame.append((version << 4) | headerSizeWords)
        frame.append((messageType.rawValue << 4) | flag.rawValue)
        frame.append((serialization.rawValue << 4) | compression.rawValue)
        frame.append(0)
        if flag == .withPositiveSequence || flag == .withNegativeSequence {
            let sequenceValue = sequence ?? (flag == .withNegativeSequence ? -1 : 1)
            frame.append(sequenceValue.bigEndianData)
        }
        frame.append(Int32(payload.count).bigEndianData)
        frame.append(payload)
        return frame
    }

    private func receiveLoop() {
        guard isRunning, let websocketTask else { return }
        websocketTask.receive { [weak self] result in
            guard let self, self.isRunning else { return }
            switch result {
            case .failure(let error):
                self.emitError("Doubao websocket receive failed: \(error.localizedDescription)")
                self.finishIfPossible(with: self.currentText())
            case .success(let message):
                self.handleIncomingMessage(message)
                self.receiveLoop()
            }
        }
    }

    private func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            handleIncomingBinaryFrame(data)
        case .string(let text):
            if !text.isEmpty {
                JotlyLog.speech.info("Doubao received text frame: \(text, privacy: .public)")
            }
        @unknown default:
            break
        }
    }

    private func handleIncomingBinaryFrame(_ data: Data) {
        guard data.count >= 8 else {
            JotlyLog.speech.warning("Doubao frame too short: \(data.count, privacy: .public) bytes")
            return
        }

        let headerByte0 = data[data.startIndex]
        let headerByte1 = data[data.startIndex + 1]
        let headerByte2 = data[data.startIndex + 2]

        let headerSizeWords = Int(headerByte0 & 0x0F)
        let headerSize = max(4, headerSizeWords * 4)
        guard data.count >= headerSize + 4 else { return }

        let messageTypeValue = (headerByte1 & 0xF0) >> 4
        let flagValue = headerByte1 & 0x0F
        let serializationValue = (headerByte2 & 0xF0) >> 4
        let compressionValue = headerByte2 & 0x0F

        guard let messageType = MessageType(rawValue: messageTypeValue) else { return }

        var cursor = headerSize
        if flagValue == MessageFlag.withPositiveSequence.rawValue || flagValue == MessageFlag.withNegativeSequence.rawValue {
            guard data.count >= cursor + 4 else { return }
            cursor += 4
        }

        switch messageType {
        case .fullServerResponse, .serverAckOrAudioResponse:
            guard data.count >= cursor + 4 else { return }
            let payloadSize = Int(data.readInt32BigEndian(at: cursor))
            cursor += 4
            guard payloadSize >= 0, data.count >= cursor + payloadSize else { return }

            let payload = data.subdata(in: cursor..<(cursor + payloadSize))
            let parsedPayload = decodePayload(
                payload: payload,
                serializationValue: serializationValue,
                compressionValue: compressionValue
            )
            receivedFrameCount += 1
            if receivedFrameCount <= 5 || receivedFrameCount % 20 == 0 {
                JotlyLog.speech.info(
                    "Doubao frame recv type=\(messageTypeValue, privacy: .public) flag=\(flagValue, privacy: .public) compression=\(compressionValue, privacy: .public) serialization=\(serializationValue, privacy: .public) payload=\(payloadSize, privacy: .public)"
                )
            }
            handleServerPayload(parsedPayload, isFinalFrame: flagValue == MessageFlag.lastPacket.rawValue || flagValue == MessageFlag.withNegativeSequence.rawValue)
        case .errorResponse:
            guard data.count >= cursor + 8 else { return }
            let errorCode = data.readUInt32BigEndian(at: cursor)
            cursor += 4
            let errorSize = Int(data.readUInt32BigEndian(at: cursor))
            cursor += 4
            guard data.count >= cursor + errorSize else { return }
            let errorData = data.subdata(in: cursor..<(cursor + errorSize))
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            emitError("Doubao error \(errorCode): \(errorMessage)")
            finishIfPossible(with: currentText())
        case .fullClientRequest, .audioOnlyRequest:
            break
        }
    }

    private func decodePayload(payload: Data, serializationValue: UInt8, compressionValue: UInt8) -> [String: Any]? {
        let rawPayload: Data
        switch CompressionMethod(rawValue: compressionValue) {
        case .some(.none):
            rawPayload = payload
        case .some(.gzip):
            guard let inflated = gzipDecompress(payload) else { return nil }
            rawPayload = inflated
        case nil:
            rawPayload = payload
        }

        guard SerializationMethod(rawValue: serializationValue) == .json else {
            return nil
        }

        guard
            let object = try? JSONSerialization.jsonObject(with: rawPayload, options: []),
            let dictionary = object as? [String: Any]
        else {
            return nil
        }
        return dictionary
    }

    private func handleServerPayload(_ payload: [String: Any]?, isFinalFrame: Bool) {
        guard let payload else { return }

        if let audioInfo = payload["audio_info"] as? [String: Any] {
            let durationMs = intValue(audioInfo["duration"]) ?? 0
            if durationMs > latestAudioDurationMilliseconds {
                latestAudioDurationMilliseconds = durationMs
            }
        }

        if let message = payload["message"] as? String, !message.isEmpty {
            JotlyLog.speech.info("Doubao message: \(message, privacy: .public)")
        }

        let resultObject: [String: Any]?
        if let dict = payload["result"] as? [String: Any] {
            resultObject = dict
        } else if let list = payload["result"] as? [[String: Any]] {
            resultObject = list.first
        } else if let text = payload["result"] as? String {
            resultObject = ["text": text]
        } else if payload["utterances"] != nil || payload["text"] != nil {
            resultObject = payload
        } else {
            resultObject = nil
        }

        guard let result = resultObject else { return }

        if let utterances = result["utterances"] as? [[String: Any]], !utterances.isEmpty {
            _ = processUtterances(utterances, isFinalFrame: isFinalFrame)
            if let fullText = result["text"] as? String {
                lock.lock()
                fullTextSnapshot = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
            }
        } else if let fullText = result["text"] as? String {
            let normalizedText = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else { return }
            lock.lock()
            fullTextSnapshot = normalizedText
            if isFinalFrame {
                finalText = normalizedText
            }
            lock.unlock()
            emitTranscript(normalizedText, isFinal: isFinalFrame)
        }

        if isFinalFrame {
            lock.lock()
            if finalText.isEmpty {
                finalText = currentTextLocked()
            }
            let result = finalText.isEmpty ? currentTextLocked() : finalText
            lock.unlock()
            finishIfPossible(with: result)
        }
    }

    private func processUtterances(_ utterances: [[String: Any]], isFinalFrame: Bool) -> Bool {
        var newlyFinal = [String]()
        var latestInterim = ""

        lock.lock()
        defer { lock.unlock() }

        for utterance in utterances {
            guard let text = utterance["text"] as? String, !text.isEmpty else { continue }
            let definite = (utterance["definite"] as? Bool) ?? false
            if definite {
                let key = utteranceKey(for: utterance, fallbackText: text)
                if !emittedUtteranceKeys.contains(key) {
                    emittedUtteranceKeys.insert(key)
                    newlyFinal.append(text)
                }
            } else {
                latestInterim = text
            }
        }

        var emitted = false
        if !newlyFinal.isEmpty {
            let finalChunk = newlyFinal.joined()
            fullTextSnapshot = joinedTranscriptLocked(fullTextSnapshot, finalChunk)
            interimSnapshot = ""
            finalText = isFinalFrame ? fullTextSnapshot : finalText
            emitted = true
            DispatchQueue.main.async { [weak self] in
                self?.onTranscript?(finalChunk, true)
            }
        } else if !latestInterim.isEmpty {
            let delta = textDelta(newText: latestInterim, previousText: interimSnapshot)
            interimSnapshot = latestInterim
            if !delta.isEmpty {
                emitted = true
                DispatchQueue.main.async { [weak self] in
                    self?.onTranscript?(latestInterim, false)
                }
            }
        } else if isFinalFrame {
            interimSnapshot = ""
        }
        return emitted
    }

    private func utteranceKey(for utterance: [String: Any], fallbackText: String) -> String {
        let start = (utterance["start_time"] as? Int) ?? 0
        let end = (utterance["end_time"] as? Int) ?? 0
        return "\(start)-\(end)-\(fallbackText)"
    }

    private func textDelta(newText: String, previousText: String) -> String {
        if previousText.isEmpty { return newText }
        if newText.hasPrefix(previousText) {
            return String(newText.dropFirst(previousText.count))
        }
        let prefixLength = commonPrefixLength(newText, previousText)
        return String(newText.dropFirst(prefixLength))
    }

    private func commonPrefixLength(_ left: String, _ right: String) -> Int {
        var index = 0
        let leftChars = Array(left)
        let rightChars = Array(right)
        let upper = min(leftChars.count, rightChars.count)
        while index < upper, leftChars[index] == rightChars[index] {
            index += 1
        }
        return index
    }

    private func joinedTranscriptLocked(_ left: String, _ right: String) -> String {
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

    private func shouldInsertSpaceLocked(between left: String, and right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        return last.isASCII && first.isASCII && (last.isLetter || last.isNumber) && (first.isLetter || first.isNumber)
    }

    private func suffixPrefixOverlapLocked(_ left: String, _ right: String) -> Int {
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

    private func emitTranscript(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            self.onTranscript?(trimmed, isFinal)
        }
    }

    private func emitError(_ message: String) {
        lock.lock()
        errorMessage = message
        lock.unlock()
        JotlyLog.speech.error("DoubaoASR error: \(message, privacy: .public)")
    }

    private func finishIfPossible(with result: String) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        cleanupAfterStop()
        continuation.resume(returning: result)
    }

    private func scheduleStopTimeout() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            let outcome = self.lock.withLock { () -> (CheckedContinuation<String, Error>, String)? in
                guard let continuation = self.continuation else { return nil }
                self.continuation = nil
                return (continuation, self.currentTextLocked())
            }
            guard let outcome else { return }
            let (continuation, result) = outcome
            self.cleanupAfterStop()
            continuation.resume(returning: result)
        }
    }

    private func cleanupAfterStop() {
        stopRecorder()
        websocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
        cleanupState()
    }

    private func resetRecorderForStart() {
        stopRecorder()
        converter = nil
        targetFormat = nil
        pendingAudioBuffer.removeAll(keepingCapacity: false)
    }

    private func stopRecorder() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func validateInputFormat(_ format: AVAudioFormat) throws {
        guard format.sampleRate > 0, format.channelCount > 0 else {
            JotlyLog.speech.error(
                "DoubaoASR invalid input format: channels=\(format.channelCount, privacy: .public), sampleRate=\(format.sampleRate, privacy: .public)"
            )
            throw JotlyError.speechStartFailed("麦克风输入暂时不可用，请稍后再试。")
        }
    }

    private func cleanupState() {
        isRunning = false
        isStopping = false
        websocketTask = nil
        urlSession = nil
        converter = nil
        targetFormat = nil
        pendingAudioBuffer.removeAll(keepingCapacity: false)
        emittedUtteranceKeys.removeAll()
        sentAudioPacketCount = 0
        receivedFrameCount = 0
        latestAudioDurationMilliseconds = 0
        finalText = ""
        errorMessage = nil
        continuation = nil
    }

    private func resetState() {
        lock.lock()
        fullTextSnapshot = ""
        interimSnapshot = ""
        pendingAudioBuffer.removeAll(keepingCapacity: false)
        emittedUtteranceKeys.removeAll()
        sentAudioPacketCount = 0
        receivedFrameCount = 0
        latestAudioDurationMilliseconds = 0
        finalText = ""
        errorMessage = nil
        continuation = nil
        isRunning = false
        isStopping = false
        lock.unlock()
    }

    private func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return currentTextLocked()
    }

    private func currentTextLocked() -> String {
        if !finalText.isEmpty { return finalText }
        return joinedTranscriptLocked(fullTextSnapshot, interimSnapshot)
    }

    private func jsonData(_ payload: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int32:
            return Int(value)
        case let value as Int64:
            return Int(value)
        case let value as Double:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private func gzipCompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        var input = [UInt8](data)
        var output = Data(capacity: max(256, data.count / 2))
        let chunkSize = 16_384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        var stream = z_stream()
        let success = input.withUnsafeMutableBytes { pointer -> Bool in
            stream.next_in = pointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(pointer.count)
            let initStatus = deflateInit2_(
                &stream,
                Z_DEFAULT_COMPRESSION,
                Z_DEFLATED,
                MAX_WBITS + 16,
                MAX_MEM_LEVEL,
                Z_DEFAULT_STRATEGY,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else { return false }
            defer { deflateEnd(&stream) }

            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return deflate(&stream, Z_FINISH)
                }
                if status != Z_OK && status != Z_STREAM_END {
                    return false
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
            }
            return true
        }

        return success ? output : nil
    }

    private func gzipDecompress(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }

        var input = [UInt8](data)
        var output = Data(capacity: data.count * 2)
        let chunkSize = 16_384
        var buffer = [UInt8](repeating: 0, count: chunkSize)

        var stream = z_stream()
        let success = input.withUnsafeMutableBytes { pointer -> Bool in
            stream.next_in = pointer.bindMemory(to: Bytef.self).baseAddress
            stream.avail_in = uInt(pointer.count)
            let initStatus = inflateInit2_(
                &stream,
                MAX_WBITS + 16,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initStatus == Z_OK else { return false }
            defer { inflateEnd(&stream) }

            while true {
                let status: Int32 = buffer.withUnsafeMutableBufferPointer { outputBuffer in
                    stream.next_out = outputBuffer.baseAddress
                    stream.avail_out = uInt(chunkSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                if status != Z_OK && status != Z_STREAM_END {
                    return false
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(buffer, count: produced)
                }
                if status == Z_STREAM_END {
                    break
                }
                if stream.avail_in == 0 && produced == 0 {
                    break
                }
            }
            return true
        }

        return success ? output : nil
    }
}
