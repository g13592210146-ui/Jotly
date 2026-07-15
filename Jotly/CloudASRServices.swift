import AVFoundation
import Foundation
import os
import zlib

final class LegacyDoubaoASRService {
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

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
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
        guard sendInitialRequest(model: model) else {
            cleanupAfterStop()
            throw JotlyError.speechStartFailed("豆包首包发送失败。")
        }
        do {
            try await configureRecorder()
        } catch {
            cleanupAfterStop()
            throw error
        }
        JotlyLog.speech.info("DoubaoASR websocket started")
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
            let state = withState {
                (errorMessage, finalText, fullTextSnapshot, websocketTask == nil)
            }
            if let errorMessage = state.0 {
                cleanupAfterStop()
                continuation.resume(throwing: JotlyError.speechStartFailed(errorMessage))
                return
            }
            if !state.1.isEmpty || (!state.2.isEmpty && state.3) {
                let result = currentTextLocked()
                cleanupAfterStop()
                continuation.resume(returning: result)
                return
            }
            withState {
                self.continuation = continuation
            }
            scheduleStopTimeout()
        }
    }

    @MainActor
    func cancel() {
        stopRecorder()
        let continuation = withState {
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
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
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
            frame.append(sequenceValue.legacyBigEndianData)
        }
        frame.append(Int32(payload.count).legacyBigEndianData)
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
            let payloadSize = Int(data.legacyReadInt32BigEndian(at: cursor))
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
            let errorCode = data.legacyReadUInt32BigEndian(at: cursor)
            cursor += 4
            let errorSize = Int(data.legacyReadUInt32BigEndian(at: cursor))
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
            let state = self.withState {
                (self.continuation, self.currentTextLocked())
            }
            guard let continuation = state.0 else {
                return
            }
            self.withState {
                self.continuation = nil
            }
            let result = state.1
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
        withState {
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
        }
    }

    private func currentText() -> String {
        withState {
            currentTextLocked()
        }
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

final class LegacyAliyunASRService {
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
                "language_hints": ["zh", "en"]
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
            lock.lock()
            if isCompleted {
                let result = finalText.isEmpty ? latestText : finalText
                lock.unlock()
                nui.nui_release()
                self.nui = nil
                continuation.resume(returning: result)
            } else if let errorMessage {
                lock.unlock()
                nui.nui_release()
                self.nui = nil
                continuation.resume(throwing: JotlyError.speechStartFailed(errorMessage))
            } else {
                self.continuation = continuation
                lock.unlock()
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

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)

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
        try audioEngine.start()
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

private final class LegacyRemoteASRAudioRecorder {
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
        if #available(iOS 13.0, *) {
            try session.setAllowHapticsAndSystemSoundsDuringRecording(true)
        }
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }

    fileprivate static func requestMicrophonePermission() async -> Bool {
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

    fileprivate static func calculateLevel(from buffer: AVAudioPCMBuffer) -> Float {
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

private extension UInt32 {
    var legacyBigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }
}

private extension Int32 {
    var legacyBigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: MemoryLayout<Int32>.size)
    }
}

private extension Data {
    func legacyReadUInt32BigEndian(at offset: Int) -> UInt32 {
        let range = offset..<(offset + 4)
        var value: UInt32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { targetBuffer in
            copyBytes(to: targetBuffer, from: range)
        }
        return UInt32(bigEndian: value)
    }

    func legacyReadInt32BigEndian(at offset: Int) -> Int32 {
        let range = offset..<(offset + 4)
        var value: Int32 = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { targetBuffer in
            copyBytes(to: targetBuffer, from: range)
        }
        return Int32(bigEndian: value)
    }
}
