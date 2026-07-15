import Foundation
import UIKit
@preconcurrency import Vision

struct ShortcutAnalysisOutcome {
    let card: MemoryCard
    let analysis: AgentAnalysis
    let usage: AgentModelUsage?
    let estimatedCostCNY: Double
    let modelName: String
    let dialogText: String
}

@MainActor
final class ShortcutAnalysisService {
    static let shared = ShortcutAnalysisService()

    private let deepSeekClient = DeepSeekClient()
    private let store = LocalStore()
    private let debugStore = JotlyDebugTurnStore.shared
    private let toolDispatcher = ToolDispatcher()

    func processScreenshot(_ imageData: Data, operationId: String) async throws -> ShortcutAnalysisOutcome {
        try Task.checkCancellation()
        try ensureShortcutOperationCanContinue(operationId: operationId)
        guard let image = UIImage(data: imageData) else {
            throw JotlyError.invalidToolParameters("截图无法读取。")
        }

        let model = selectedAgentModel()
        let currentDate = DateFormatting.todayString()
        let snapshot = try? store.load()
        let resolvedImageMode = resolvedImageInputMode(for: model)
        try markShortcutOperationProcessing(operationId: operationId)
        try Task.checkCancellation()
        try ensureShortcutOperationCanContinue(operationId: operationId)

        if model.supportsDirectImageInput, resolvedImageMode == .directModel {
            guard let attachment = makeImageAttachment(from: image) else {
                throw JotlyError.invalidToolParameters("图片处理失败：图片压缩失败。")
            }
            return try await processText(
                """
                用户通过快捷指令传入了一张图片。请先理解图片中的文字、票据、页面或截图内容，再按系统要求输出结构化 JSON。
                不要只描述图片，也不要返回普通文本；如果图片内容不足以生成具体卡片，请按现有规则生成需要用户确认或补充的结果。
                """,
                sourceType: "shortcut_screenshot",
                currentDate: currentDate,
                operationId: operationId,
                imageAttachment: attachment,
                imageInputMode: .directModel,
                inputFingerprint: ImageInputFingerprint.make(data: imageData),
                existingCards: snapshot?.cards ?? []
            )
        }

        let recognizedText = try await recognizeText(from: image)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try ensureShortcutOperationCanContinue(operationId: operationId)
        guard !recognizedText.isEmpty else {
            throw JotlyError.invalidToolParameters("图片里没有识别到可用内容。")
        }
        return try await processText(
            recognizedText,
            sourceType: "shortcut_screenshot_ocr",
            currentDate: currentDate,
            operationId: operationId,
            imageInputMode: .ocr,
            inputFingerprint: ImageInputFingerprint.make(data: imageData),
            existingCards: snapshot?.cards ?? []
        )
    }

    func processVoice(_ dictatedText: String, operationId: String) async throws -> ShortcutAnalysisOutcome {
        try Task.checkCancellation()
        try ensureShortcutOperationCanContinue(operationId: operationId)
        let trimmed = dictatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JotlyError.invalidToolParameters("没有收到听写文本。请在快捷指令里先添加系统「听写文本」，再把听写结果传给 Jotly「语音」。")
        }

        let currentDate = DateFormatting.todayString()
        let snapshot = try? store.load()
        try markShortcutOperationProcessing(operationId: operationId)
        return try await processText(
            trimmed,
            sourceType: "shortcut_voice",
            currentDate: currentDate,
            operationId: operationId,
            imageInputMode: nil,
            existingCards: snapshot?.cards ?? []
        )
    }

    private func processText(
        _ text: String,
        sourceType: String,
        currentDate: String,
        operationId: String,
        imageAttachment: ImageAttachment? = nil,
        imageInputMode: ImageInputMode? = nil,
        inputFingerprint: String? = nil,
        existingCards: [MemoryCard] = []
    ) async throws -> ShortcutAnalysisOutcome {
        try Task.checkCancellation()
        try ensureShortcutOperationCanContinue(operationId: operationId)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw JotlyError.invalidToolParameters("输入内容不能为空。")
        }

        let selectedModel = selectedAgentModel()
        let requestContext = AgentRequestContext.newCard()
        let now = Date()
        let resolvedFingerprint = imageInputMode.map { _ in
            inputFingerprint ?? ImageInputFingerprint.make(
                text: trimmed,
                attachments: imageAttachment.map { [$0] } ?? []
            )
        }
        if let resolvedFingerprint,
           let existingCard = existingCards.first(where: { $0.metadata?["input_fingerprint"] == resolvedFingerprint }) {
            try? markShortcutOperationCompleted(
                operationId: operationId,
                cardId: existingCard.id,
                title: existingCard.title,
                summary: "这张图片已经处理过",
                message: shortcutDisplaySummary(for: existingCard)
            )
            return ShortcutAnalysisOutcome(
                card: existingCard,
                analysis: AgentAnalysis(
                    intent: "duplicate_image_input",
                    riskLevel: "low",
                    requiresConfirmation: false,
                    shouldExecuteNow: false,
                    card: AgentCard(
                        type: existingCard.type,
                        title: existingCard.title,
                        summary: existingCard.summary,
                        message: existingCard.message,
                        options: existingCard.options,
                        metadata: existingCard.metadata
                    ),
                    toolPlan: [],
                    memoryToSave: [],
                    userVisibleText: "这张图片已经处理过。"
                ),
                usage: nil,
                estimatedCostCNY: 0,
                modelName: selectedModel.rawValue,
                dialogText: "这张图片已经处理过。"
            )
        }
        let prompt = deepSeekClient.debugPrompt(
            text: trimmed,
            latestCardStatus: .processing,
            currentDate: currentDate,
            model: selectedModel,
            imageInputMode: imageInputMode
        )
        let backgroundImagePath = imageAttachment.map { _ in
            CardBackgroundImageStore.relativePath(for: operationId)
        }
        if let imageAttachment {
            let imageData = imageAttachment.data
            _ = try? await Task.detached(priority: .utility) {
                try CardBackgroundImageStore.save(imageData, for: operationId)
            }.value
        }
        let processingCard = MemoryCard(
            id: operationId,
            type: "shortcut",
            title: "AI 解析中",
            status: .processing,
            originalText: trimmed,
            summary: "",
            message: "AI 正在整理……",
            completionMessage: nil,
            options: [],
            entities: nil,
            supplementalText: nil,
            toolCandidates: [],
            selectedOptionValue: nil,
            reminderInfo: nil,
            toolPlan: nil,
            metadata: [
                "source": "shortcut",
                "shortcut_type": sourceType,
                "input_fingerprint": resolvedFingerprint ?? "",
                "processing_status": imageInputMode == nil ? "正在理解你的输入" : "正在识别图片内容"
            ],
            imageInputMode: imageInputMode,
            conversationMessages: [CardConversationMessage(role: .user, text: trimmed)],
            createdAt: now,
            updatedAt: now,
            backgroundStyle: .animatedGradient,
            backgroundImagePath: backgroundImagePath,
            userVisibleInput: imageInputMode == nil ? trimmed : "正在分析图片"
        )

        try store.saveRawInput(
            RawInput(text: trimmed, linkedCardId: processingCard.id, type: sourceType),
            card: processingCard
        )
        debugStore.startTurn(cardId: processingCard.id, userText: trimmed)
        debugStore.updateTurn(
            cardId: processingCard.id,
            systemPrompt: prompt.systemPrompt,
            userPrompt: prompt.userPrompt,
            fullPrompt: prompt.fullPrompt,
            nodeId: "prompt",
            nodeState: .completed,
            nodeDetail: "已组装 system + user prompt"
        )
        debugStore.updateNode(cardId: processingCard.id, nodeId: "model", state: .running, detail: "正在请求模型")
        postStoreDidChange()

        do {
            try Task.checkCancellation()
            try ensureShortcutOperationCanContinue(operationId: operationId)
            let initialResponse = try await deepSeekClient.analyzeWithDebug(
                text: trimmed,
                latestCardStatus: .processing,
                currentDate: currentDate,
                model: selectedModel,
                imageAttachment: imageAttachment,
                imageInputMode: imageInputMode,
                requestContext: requestContext,
                existingCards: existingCards
            )
            try ensureShortcutOperationCanContinue(operationId: operationId)
            let resolved = try await resolveMemoryResponseIfNeeded(
                initialResponse,
                text: trimmed,
                currentDate: currentDate,
                model: selectedModel,
                imageAttachment: imageAttachment,
                imageInputMode: imageInputMode,
                requestContext: requestContext,
                existingCards: existingCards,
                cardID: processingCard.id
            )
            updateProcessingStatus(cardId: processingCard.id, text: "正在整理卡片")
            let debugResponse = resolved.response
            let analysis = normalizedAnalysis(debugResponse.analysis)
            debugStore.updateTurn(
                cardId: processingCard.id,
                systemPrompt: debugResponse.systemPrompt,
                userPrompt: debugResponse.userPrompt,
                fullPrompt: debugResponse.fullPrompt,
                modelName: debugResponse.modelName,
                modelOutput: debugResponse.rawModelOutput,
                decodedSummary: decodedSummary(for: debugResponse, analysis: analysis),
                promptTokens: debugResponse.usage?.promptTokens,
                completionTokens: debugResponse.usage?.completionTokens,
                totalTokens: debugResponse.usage?.totalTokens,
                promptCacheHitTokens: debugResponse.usage?.promptCacheHitTokens,
                promptCacheMissTokens: debugResponse.usage?.promptCacheMissTokens,
                promptCacheCreationTokens: debugResponse.usage?.promptCacheCreationTokens,
                nodeId: "model",
                nodeState: .completed,
                nodeDetail: "模型已返回原始输出"
            )
            debugStore.updateNode(cardId: processingCard.id, nodeId: "decode", state: .completed, detail: "JSON 已解析：\(analysis.intent)")
            var finalCard = analysis.makeCard(reusing: processingCard)
            applyHabitDefaultsIfNeeded(to: &finalCard, appendTodayIfMissing: false)
            if let polished = analysis.optimizedUserText, !polished.isEmpty {
                finalCard.originalText = polished
            }
            if let changeNote = analysis.changeNote, !changeNote.isEmpty {
                finalCard.changeNote = changeNote
                finalCard.isUpdated = true
            }
            let mustConfirm = analysis.requiresConfirmation || requiresExternalActionConfirmation(analysis)
            if mustConfirm {
                finalCard.status = .waitingConfirmation
                finalCard.completionMessage = nil
                if finalCard.type == "birthday", finalCard.options.isEmpty {
                    finalCard.options = AgentAnalysis.birthdayOptions()
                }
            } else if analysis.shouldExecuteNow {
                let plans = analysis.toolPlan?.filter { $0.when == "now" } ?? []
                var results: [ToolDispatcher.ToolExecutionResult] = []
                for plan in plans {
                    try ensureShortcutOperationCanContinue(operationId: operationId)
                    debugStore.updateNode(cardId: processingCard.id, nodeId: "tool", state: .running, detail: "执行工具：\(plan.tool)")
                    let result = try await toolDispatcher.execute(plan: plan, card: finalCard)
                    results.append(result)
                    debugStore.updateNode(cardId: processingCard.id, nodeId: "tool", state: .completed, detail: result.completionMessage)
                }
                finalCard.status = .completed
                finalCard.options = []
                if let message = results.last?.completionMessage {
                    finalCard.message = message
                    finalCard.completionMessage = message
                }
                var metadata = finalCard.metadata ?? [:]
                for resultMetadata in results.compactMap(\.metadata) {
                    metadata.merge(resultMetadata) { _, new in new }
                }
                finalCard.metadata = metadata.isEmpty ? nil : metadata
                finalCard.reminderInfo = results.compactMap(\.reminderInfo).last
                applyInitialHabitDates(from: metadata, to: &finalCard)

                if let replacementCardID = results.last(where: \.shouldDeleteCallingCard)?.metadata?["card_id"],
                   let replacement = try store.load().cards.first(where: { $0.id == replacementCardID }) {
                    try? store.deleteCard(id: processingCard.id)
                    finalCard = replacement
                }
            } else {
                finalCard.status = .completed
                finalCard.options = []
            }
            appendConversationMessage(role: .assistant, text: finalCard.message, to: &finalCard)
            finalCard.markUpdated()
            try store.upsertCard(finalCard)
            if let memories = analysis.memoryToSave, !memories.isEmpty {
                Task {
                    await MemoryOSCoordinator.shared.ingest(memories, linkedCardID: finalCard.id)
                }
            }
            if let retrieval = resolved.retrieval {
                try? store.linkMemories(retrieval.memoryIDs, toCardID: finalCard.id)
            }
            try? markShortcutOperationCompleted(
                operationId: operationId,
                cardId: finalCard.id,
                title: finalCard.title,
                summary: shortcutDisplaySummary(for: finalCard),
                message: shortcutDisplaySummary(for: finalCard)
            )
            postStoreDidChange()
            debugStore.updateNode(cardId: processingCard.id, nodeId: "finish", state: .completed, detail: finalCard.message)

            return ShortcutAnalysisOutcome(
                card: finalCard,
                analysis: analysis,
                usage: debugResponse.usage,
                estimatedCostCNY: debugResponse.estimatedCostCNY,
                modelName: debugResponse.modelName,
                dialogText: "已分析完成：\(finalCard.completionMessage ?? finalCard.message)"
            )
        } catch is CancellationError {
            if isShortcutOperationExplicitlyCancelled(operationId: operationId) {
                var cancelledCard = processingCard
                cancelledCard.status = .failed
                cancelledCard.title = "已取消"
                cancelledCard.message = "本次分析已取消。"
                cancelledCard.completionMessage = "本次分析已取消。"
                appendConversationMessage(role: .assistant, text: cancelledCard.message, to: &cancelledCard)
                cancelledCard.markUpdated()
                try? store.upsertCard(cancelledCard)
                try? markShortcutOperationCancelled(operationId: operationId, cardId: cancelledCard.id, message: cancelledCard.message)
                postStoreDidChange()
                debugStore.updateNode(cardId: processingCard.id, nodeId: "model", state: .failed, detail: "已取消")
                debugStore.updateNode(cardId: processingCard.id, nodeId: "decode", state: .failed, detail: "已取消")
                debugStore.updateNode(cardId: processingCard.id, nodeId: "finish", state: .failed, detail: "已取消")
            } else if isLatestShortcutOperation(operationId: operationId) {
                var interruptedCard = processingCard
                interruptedCard.status = .failed
                interruptedCard.title = "处理被中断"
                interruptedCard.message = "系统中断了这次快捷分析，不是你手动取消。请重新运行快捷指令。"
                interruptedCard.completionMessage = interruptedCard.message
                appendConversationMessage(role: .assistant, text: interruptedCard.message, to: &interruptedCard)
                interruptedCard.markUpdated()
                try? store.upsertCard(interruptedCard)
                try? markShortcutOperationInterrupted(operationId: operationId, cardId: interruptedCard.id, message: interruptedCard.message)
                postStoreDidChange()
                debugStore.updateNode(cardId: processingCard.id, nodeId: "model", state: .failed, detail: "系统中断")
                debugStore.updateNode(cardId: processingCard.id, nodeId: "decode", state: .failed, detail: "系统中断")
                debugStore.updateNode(cardId: processingCard.id, nodeId: "finish", state: .failed, detail: "系统中断")
            }
            throw CancellationError()
        } catch {
            var failedCard = processingCard
            failedCard.status = .failed
            failedCard.title = "识别失败"
            failedCard.message = shortcutFailureMessage(for: error)
            failedCard.completionMessage = failedCard.message
            appendConversationMessage(role: .assistant, text: failedCard.message, to: &failedCard)
            failedCard.markUpdated()
            try? store.upsertCard(failedCard)
            try? markShortcutOperationFailed(operationId: operationId, cardId: failedCard.id, message: failedCard.message)
            postStoreDidChange()
            debugStore.updateTurn(
                cardId: processingCard.id,
                modelOutput: rawModelOutput(from: error) ?? error.localizedDescription,
                decodedSummary: "模型请求或解析失败"
            )
            debugStore.updateNode(cardId: processingCard.id, nodeId: "model", state: .failed, detail: error.localizedDescription)
            debugStore.updateNode(cardId: processingCard.id, nodeId: "decode", state: .failed, detail: "进入失败处理")
            debugStore.updateNode(cardId: processingCard.id, nodeId: "finish", state: .failed, detail: "执行失败")
            throw error
        }
    }

    private func selectedAgentModel() -> LifeAgentLLMModel {
        if let saved = UserDefaults.standard.string(forKey: "selected_agent_model"),
           let model = LifeAgentLLMModel(rawValue: saved) {
            return model
        }
        return .deepseekV4Pro
    }

    private func resolveMemoryResponseIfNeeded(
        _ initialResponse: DeepSeekDebugResponse,
        text: String,
        currentDate: String,
        model: LifeAgentLLMModel,
        imageAttachment: ImageAttachment?,
        imageInputMode: ImageInputMode?,
        requestContext: AgentRequestContext,
        existingCards: [MemoryCard],
        cardID: String
    ) async throws -> (response: DeepSeekDebugResponse, retrieval: MemoryRetrievalResult?) {
        guard initialResponse.analysis.needMemory == true else {
            debugStore.updateNode(cardId: cardID, nodeId: "memory", state: .completed, detail: "本轮不需要读取记忆")
            return (initialResponse, nil)
        }
        let query = initialResponse.analysis.memoryQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuery = (query?.isEmpty == false ? query : nil) ?? text
        try? store.updateAgentRunMemoryRequest(cardID: cardID, needMemory: true, query: resolvedQuery)
        debugStore.updateNode(cardId: cardID, nodeId: "memory", state: .running, detail: "正在检索：\(resolvedQuery)")
        let retrieval = await MemoryOSCoordinator.shared.retrieve(query: resolvedQuery)
        debugStore.updateNode(
            cardId: cardID,
            nodeId: "memory",
            state: .completed,
            detail: retrieval.memories.isEmpty ? "未找到相关记忆" : "命中 \(retrieval.memories.count) 条记忆"
        )
        let second = try await deepSeekClient.analyzeWithDebug(
            text: text,
            latestCardStatus: .processing,
            currentDate: currentDate,
            model: model,
            supplementalText: retrieval.promptContext,
            imageAttachment: imageAttachment,
            imageInputMode: imageInputMode,
            requestContext: requestContext,
            existingCards: existingCards
        )
        return (
            DeepSeekDebugResponse(
                analysis: second.analysis.asMemoryReply(),
                systemPrompt: second.systemPrompt,
                userPrompt: second.userPrompt,
                fullPrompt: second.fullPrompt,
                modelName: second.modelName,
                rawModelOutput: second.rawModelOutput,
                usage: second.usage,
                estimatedCostCNY: second.estimatedCostCNY
            ),
            retrieval
        )
    }

    private func selectedImageInputMode() -> ImageInputMode {
        if let saved = UserDefaults.standard.string(forKey: "selected_image_input_mode"),
           let mode = ImageInputMode(rawValue: saved) {
            return mode
        }
        return .ocr
    }

    private func resolvedImageInputMode(for model: LifeAgentLLMModel) -> ImageInputMode {
        guard model.supportsDirectImageInput else { return .ocr }
        return selectedImageInputMode()
    }

    private func normalizedAnalysis(_ analysis: AgentAnalysis) -> AgentAnalysis {
        analysis
    }

    private func requiresExternalActionConfirmation(_ analysis: AgentAnalysis) -> Bool {
        if analysis.cardType == "birthday" { return true }
        let externalTools: Set<String> = [
            "create_solar_birthday_reminder", "reminder.create_solar_birthday",
            "create_lunar_birthday_reminder", "reminder.create_lunar_birthday", "lunar_series.create",
            "create_date_reminder", "create_reminder", "reminder.create",
            "calendar.create_event", "notification.schedule", "family_holiday_reminders.create"
        ]
        if analysis.toolPlan?.contains(where: { externalTools.contains($0.tool) }) == true {
            return true
        }
        return analysis.options.contains { option in
            option.actions?.contains(where: { externalTools.contains($0.tool) }) == true
                || option.actionButtons?.contains(where: { button in
                    button.actions.contains { externalTools.contains($0.tool) }
                }) == true
        }
    }

    private func updateProcessingStatus(cardId: String, text: String) {
        guard var card = try? store.load().cards.first(where: { $0.id == cardId }),
              card.status == .processing || card.status == .executing else { return }
        var metadata = card.metadata ?? [:]
        metadata["processing_status"] = text
        card.metadata = metadata
        card.updatedAt = Date()
        try? store.upsertCard(card)
        postStoreDidChange()
    }

    private func applyInitialHabitDates(from metadata: [String: String], to card: inout MemoryCard) {
        guard card.type == "habit",
              let json = metadata["initial_check_in_dates"],
              let data = json.data(using: .utf8),
              let dates = try? JSONDecoder().decode([String].self, from: data),
              !dates.isEmpty else { return }
        card.habitCheckInDates = dates
    }

    private func decodedSummary(for response: DeepSeekDebugResponse, analysis: AgentAnalysis) -> String {
        let costText = response.estimatedCostCNY > 0
            ? ", cost≈¥\(String(format: "%.5f", response.estimatedCostCNY))"
            : ""
        return "model=\(response.modelName), intent=\(analysis.intent), type=\(analysis.cardType), confirmation=\(analysis.requiresConfirmation), action=\(analysis.recommendedActionValue ?? "nil")\(costText)"
    }

    private func shortcutDisplaySummary(for card: MemoryCard) -> String {
        let candidates = [
            card.completionMessage,
            card.summary,
            card.message
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return String(trimmed.prefix(96))
            }
        }
        return "结果已生成，回到 Jotly 查看详情。"
    }

    private func shortcutFailureMessage(for error: Error) -> String {
        switch error {
        case JotlyError.invalidDeepSeekResponse, JotlyError.invalidDeepSeekResponseWithRaw:
            return "模型返回格式异常，请回到 Jotly 查看调试输出。"
        case JotlyError.missingDeepSeekContent:
            return "模型没有返回可解析内容，请稍后重试。"
        default:
            return error.localizedDescription
        }
    }

    private func rawModelOutput(from error: Error) -> String? {
        if case JotlyError.invalidDeepSeekResponseWithRaw(let raw) = error {
            return raw
        }
        return nil
    }

    private func applyHabitDefaultsIfNeeded(to card: inout MemoryCard, appendTodayIfMissing: Bool) {
        guard card.type == "habit" else { return }
        if appendTodayIfMissing {
            var dates = card.habitCheckInDates ?? []
            dates.append(DateFormatting.todayString())
            card.habitCheckInDates = dates
            return
        }
        if card.habitCheckInDates == nil || card.habitCheckInDates!.isEmpty {
            card.habitCheckInDates = [DateFormatting.todayString()]
        }
    }

    private func appendConversationMessage(role: CardConversationMessage.Role, text: String, to card: inout MemoryCard) {
        card.conversationMessages.append(CardConversationMessage(role: role, text: text))
    }

    private func recognizeText(from image: UIImage) async throws -> String {
        guard let cgImage = normalizedCGImage(from: image) else {
            throw JotlyError.invalidToolParameters("无法读取图片内容。")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: cgImageOrientation(for: image.imageOrientation),
                options: [:]
            )
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let lines = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Task.checkCancellation()
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func postStoreDidChange() {
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
    }

    private func markShortcutOperationProcessing(operationId: String) throws {
        if let operation = try store.shortcutOperation(id: operationId),
           operation.cancelRequested || operation.phase == .cancelled {
            throw CancellationError()
        }
        try store.updateShortcutOperation(id: operationId) { operation in
            operation.phase = .processing
            operation.cancelRequested = false
            operation.openAppRequested = false
            operation.resultCardId = nil
            operation.resultTitle = nil
            operation.resultSummary = nil
            operation.resultMessage = nil
        }
    }

    private func markShortcutOperationCompleted(
        operationId: String,
        cardId: String,
        title: String,
        summary: String,
        message: String
    ) throws {
        try store.updateShortcutOperation(id: operationId) { operation in
            operation.phase = .completed
            operation.resultCardId = cardId
            operation.resultTitle = title
            operation.resultSummary = summary
            operation.resultMessage = message
        }
    }

    private func markShortcutOperationCancelled(operationId: String, cardId: String, message: String) throws {
        try store.updateShortcutOperation(id: operationId) { operation in
            operation.phase = .cancelled
            operation.resultCardId = cardId
            operation.resultTitle = "已取消"
            operation.resultSummary = "本次分析已取消"
            operation.resultMessage = message
        }
    }

    private func markShortcutOperationInterrupted(operationId: String, cardId: String, message: String) throws {
        try store.updateShortcutOperation(id: operationId) { operation in
            operation.phase = .failed
            operation.resultCardId = cardId
            operation.resultTitle = "处理被中断"
            operation.resultSummary = "请重新运行快捷指令"
            operation.resultMessage = message
        }
    }

    private func markShortcutOperationFailed(operationId: String, cardId: String, message: String) throws {
        try store.updateShortcutOperation(id: operationId) { operation in
            operation.phase = .failed
            operation.resultCardId = cardId
            operation.resultTitle = "识别失败"
            operation.resultSummary = message
            operation.resultMessage = message
        }
    }

    private func ensureShortcutOperationCanContinue(operationId: String) throws {
        try Task.checkCancellation()
        if let operation = try store.shortcutOperation(id: operationId),
           operation.cancelRequested || operation.phase == .cancelled {
            throw CancellationError()
        }
    }

    private func isShortcutOperationExplicitlyCancelled(operationId: String) -> Bool {
        guard let operation = try? store.shortcutOperation(id: operationId) else { return false }
        return operation.cancelRequested || operation.phase == .cancelled
    }

    private func isLatestShortcutOperation(operationId: String) -> Bool {
        guard let operation = try? store.latestShortcutOperation() else { return false }
        return operation.id == operationId
    }

    private func makeImageAttachment(from image: UIImage) -> ImageAttachment? {
        guard let data = normalizedJPEGData(from: image) else { return nil }
        return ImageAttachment(data: data, mimeType: "image/jpeg")
    }

    private func normalizedJPEGData(from image: UIImage) -> Data? {
        guard let normalized = normalizedImage(from: image) else { return nil }
        return normalized.jpegData(compressionQuality: 0.84)
    }

    private func normalizedCGImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage {
            return cgImage
        }

        guard let normalized = normalizedImage(from: image) else {
            return nil
        }
        return normalized.cgImage
    }

    private func normalizedImage(from image: UIImage, maxDimension: CGFloat = 1600) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }

        let scale = min(maxDimension / max(size.width, size.height), 1.0)
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func cgImageOrientation(for orientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch orientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
