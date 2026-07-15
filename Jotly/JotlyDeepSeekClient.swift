import Foundation
import os

private struct AgentAnalysisDecodeFailure: LocalizedError {
    let detail: String

    var errorDescription: String? { detail }
}

struct DeepSeekClient {
    private let deepSeekEndpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private let dashScopeEndpoint = URL(string: "https://llm-kxzzc9bbhvuvw4e9.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions")!
    private let mimoEndpoint = URL(string: "https://api.xiaomimimo.com/v1/chat/completions")!

    func debugPrompt(
        text: String,
        latestCardStatus: CardStatus,
        currentDate: String,
        model: LifeAgentLLMModel = .deepseekV4Pro,
        supplementalText: String? = nil,
        imageInputMode: ImageInputMode? = nil,
        requestContext: AgentRequestContext = .newCard()
    ) -> (systemPrompt: String, userPrompt: String, fullPrompt: String) {
        let prompt = Self.makePromptBundle(
            text: text,
            currentDate: currentDate,
            latestCardStatus: latestCardStatus,
            supplementalText: supplementalText,
            imageInputMode: imageInputMode,
            requestContext: requestContext
        )
        return (
            prompt.systemPrompt,
            prompt.userPrompt,
            prompt.fullPrompt
        )
    }

    func debugCardSupplementPrompt(
        text: String,
        card: MemoryCard,
        currentDate: String,
        model: LifeAgentLLMModel = .deepseekV4Pro
    ) -> (systemPrompt: String, userPrompt: String, fullPrompt: String) {
        _ = model
        let prompt = Self.makePromptBundle(
            text: text,
            currentDate: currentDate,
            latestCardStatus: card.status,
            supplementalText: nil,
            imageInputMode: card.imageInputMode,
            requestContext: .cardRevision(card: card)
        )
        return (
            prompt.systemPrompt,
            prompt.userPrompt,
            prompt.fullPrompt
        )
    }

    func analyze(
        text: String,
        latestCardStatus: CardStatus,
        currentDate: String,
        model: LifeAgentLLMModel = .deepseekV4Pro,
        supplementalText: String? = nil,
        imageAttachment: ImageAttachment? = nil,
        imageAttachments: [ImageAttachment] = [],
        imageInputMode: ImageInputMode? = nil,
        requestContext: AgentRequestContext = .newCard(),
        existingCards: [MemoryCard] = []
    ) async throws -> AgentAnalysis {
        let attachments = Self.imageAttachmentsWithLegacy(imageAttachment, imageAttachments)
        return try await analyzeWithDebug(
            text: text,
            latestCardStatus: latestCardStatus,
            currentDate: currentDate,
            model: model,
            supplementalText: supplementalText,
            imageAttachments: attachments,
            imageInputMode: imageInputMode,
            requestContext: requestContext,
            existingCards: existingCards
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
        imageInputMode: ImageInputMode? = nil,
        requestContext: AgentRequestContext = .newCard(),
        existingCards: [MemoryCard] = []
    ) async throws -> DeepSeekDebugResponse {
        let attachments = Self.imageAttachmentsWithLegacy(imageAttachment, imageAttachments)
        let prompt = Self.makePromptBundle(
            text: text,
            currentDate: currentDate,
            latestCardStatus: latestCardStatus,
            supplementalText: supplementalText,
            imageInputMode: imageInputMode,
            requestContext: requestContext,
            existingCards: existingCards
        )
        let messages = Self.buildMessages(
            systemPrompt: prompt.systemPrompt,
            skillLayers: prompt.skillLayers,
            userPrompt: prompt.userPrompt,
            imageAttachments: attachments,
            supportsImageInput: selectedModel.supportsDirectImageInput && !attachments.isEmpty,
            for: selectedModel
        )

        var request = URLRequest(url: endpoint(for: selectedModel))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey(for: selectedModel))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeepSeekRequest(
                model: apiModelName(for: selectedModel),
                messages: messages,
                responseFormat: responseFormat(for: selectedModel),
                temperature: 0.2,
                stream: false,
                enableThinking: enableThinking(for: selectedModel),
                thinking: thinkingConfig(for: selectedModel),
                maxTokens: nil,
                reasoningEffort: reasoningEffort(for: selectedModel)
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
        let initialDecodeError: String
        do {
            let analysis = try Self.decodeAnalysis(from: content)
            return DeepSeekDebugResponse(
                analysis: analysis,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                fullPrompt: prompt.fullPrompt,
                modelName: selectedModel.rawValue,
                rawModelOutput: content,
                usage: envelope.usage,
                estimatedCostCNY: selectedModel.estimatedCost(using: envelope.usage)
            )
        } catch {
            initialDecodeError = error.localizedDescription
        }

        JotlyLog.deepSeek.error(
            "Initial model output is not a valid AgentAnalysis: \(initialDecodeError, privacy: .public); attempting one repair"
        )
        var repairedOutput: String?
        do {
            let repaired = try await repairAnalysisOutput(content, model: selectedModel)
            repairedOutput = repaired.content
            let analysis = try Self.decodeAnalysis(from: repaired.content)
            let combinedUsage = Self.combinedUsage(envelope.usage, repaired.usage)
            return DeepSeekDebugResponse(
                analysis: analysis,
                systemPrompt: prompt.systemPrompt,
                userPrompt: prompt.userPrompt,
                fullPrompt: prompt.fullPrompt,
                modelName: selectedModel.rawValue,
                rawModelOutput: "[首次输出]\n\(content)\n\n[格式修复输出]\n\(repaired.content)",
                usage: combinedUsage,
                estimatedCostCNY: selectedModel.estimatedCost(using: envelope.usage)
                    + selectedModel.estimatedCost(using: repaired.usage)
            )
        } catch {
            JotlyLog.deepSeek.error("AgentAnalysis repair failed: \(error.localizedDescription, privacy: .public)")
            throw JotlyError.invalidDeepSeekResponseWithRaw(
                """
                [首次输出]
                \(content)

                [首次解码错误]
                \(initialDecodeError)

                [格式修复输出]
                \(repairedOutput ?? "修复请求未返回内容")

                [格式修复错误]
                \(error.localizedDescription)
                """
            )
        }
    }

    private func repairAnalysisOutput(
        _ rawOutput: String,
        model selectedModel: LifeAgentLLMModel
    ) async throws -> (content: String, usage: AgentModelUsage?) {
        let messages = [
            DeepSeekMessage(
                role: "system",
                content: """
                你只负责修复 JSON。不得改变原始语义，不得增加新行动。
                输出必须是单个 JSON 对象，字段使用：intent、risk_level、requires_confirmation、should_execute_now、reasoning、context_mode、target_card_id、within_card_scope、scope_reason、card、tool_plan、memory_to_save、user_visible_text、optimized_user_text、change_note、need_memory、memory_query。
                card 使用 cardType、title、summary、body、options、metadata；兼容旧字段 type、message。title 和 body 必须是非空的用户可见文本。tool_plan 每项使用 tool、when、params。
                缺失的非关键数组使用 []，缺失布尔值使用 false。不要输出 Markdown 或解释。
                """
            ),
            DeepSeekMessage(role: "user", content: rawOutput)
        ]

        var request = URLRequest(url: endpoint(for: selectedModel))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey(for: selectedModel))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeepSeekRequest(
                model: apiModelName(for: selectedModel),
                messages: messages,
                responseFormat: responseFormat(for: selectedModel),
                temperature: 0,
                stream: false,
                enableThinking: false,
                thinking: nil,
                maxTokens: nil,
                reasoningEffort: nil
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw JotlyError.deepSeekHTTPError(httpResponse.statusCode, Self.responseSummary(from: data))
        }
        let envelope = try JSONDecoder().decode(DeepSeekResponse.self, from: data)
        guard let content = envelope.choices.first?.message.bestContent else {
            throw JotlyError.missingDeepSeekContent
        }
        return (content, envelope.usage)
    }

    func prewarm(
        model selectedModel: LifeAgentLLMModel = .deepseekV4Pro
    ) async throws -> DeepSeekDebugResponse {
        let prompt = Self.makePromptBundle(
            text: "ping",
            currentDate: DateFormatting.todayString(),
            latestCardStatus: .idle,
            supplementalText: nil,
            imageInputMode: nil,
            requestContext: .newCard()
        )
        let messages = Self.buildMessages(
            systemPrompt: prompt.systemPrompt,
            skillLayers: prompt.skillLayers,
            userPrompt: prompt.userPrompt,
            for: selectedModel
        )

        var request = URLRequest(url: endpoint(for: selectedModel))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey(for: selectedModel))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            DeepSeekRequest(
                model: apiModelName(for: selectedModel),
                messages: messages,
                responseFormat: nil,
                temperature: 0.1,
                stream: false,
                enableThinking: false,
                thinking: thinkingConfig(for: selectedModel),
                maxTokens: 5,
                reasoningEffort: reasoningEffort(for: selectedModel)
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
        let content = envelope.choices.first?.message.bestContent ?? ""
        
        let dummyAnalysis = AgentAnalysis(
            intent: "prewarm",
            riskLevel: "low",
            requiresConfirmation: false,
            shouldExecuteNow: false,
            card: nil,
            toolPlan: nil,
            memoryToSave: nil,
            userVisibleText: "预热就绪"
        )

        return DeepSeekDebugResponse(
            analysis: dummyAnalysis,
            systemPrompt: prompt.systemPrompt,
            userPrompt: prompt.userPrompt,
            fullPrompt: prompt.fullPrompt,
            modelName: selectedModel.rawValue,
            rawModelOutput: content,
            usage: envelope.usage,
            estimatedCostCNY: selectedModel.estimatedCost(using: envelope.usage)
        )
    }

    func analyzeCardSupplement(
        text: String,
        card: MemoryCard,
        currentDate: String,
        model selectedModel: LifeAgentLLMModel = .deepseekV4Pro
    ) async throws -> DeepSeekDebugResponse {
        try await analyzeWithDebug(
            text: text,
            latestCardStatus: card.status,
            currentDate: currentDate,
            model: selectedModel,
            supplementalText: nil,
            imageAttachment: nil,
            imageInputMode: card.imageInputMode,
            requestContext: .cardRevision(card: card)
        )
    }

    private func apiModelName(for model: LifeAgentLLMModel) -> String {
        switch model {
        case .deepseekV4FlashThinking:
            return "deepseek-v4-flash"
        default:
            return model.rawValue
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

    private func thinkingConfig(for model: LifeAgentLLMModel) -> DeepSeekThinkingConfig? {
        switch model {
        case .deepseekV4Pro, .deepseekV4FlashThinking:
            return DeepSeekThinkingConfig(type: "enabled")
        case .deepseekV4Flash:
            return DeepSeekThinkingConfig(type: "disabled")
        default:
            return nil
        }
    }

    private func reasoningEffort(for model: LifeAgentLLMModel) -> String? {
        switch model {
        case .deepseekV4Pro:
            return "high"
        default:
            return nil
        }
    }

    private func responseFormat(for model: LifeAgentLLMModel) -> DeepSeekResponseFormat? {
        switch model {
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            nil
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking, .qwen37Plus, .qwen36Flash, .qwen35Flash:
            .init(type: "json_object")
        }
    }

    private static func usesExplicitContextCache(for model: LifeAgentLLMModel) -> Bool {
        switch model {
        case .qwen37Plus, .qwen36Flash, .qwen35Flash:
            return true
        default:
            return false
        }
    }

    private static func makePromptBundle(
        text: String,
        currentDate: String,
        latestCardStatus: CardStatus,
        supplementalText: String?,
        imageInputMode: ImageInputMode?,
        requestContext: AgentRequestContext,
        existingCards: [MemoryCard] = []
    ) -> PromptBundle {
        let systemPrompt = resolvedSystemPrompt(
            text: text,
            requestContext: requestContext,
            existingCards: existingCards
        )
        let skillLayers = skillPromptLayers(imageInputMode: imageInputMode)
        let userPrompt = userContent(
            text: text,
            supplementalText: supplementalText,
            currentDate: currentDate,
            latestCardStatus: latestCardStatus,
            imageInputMode: imageInputMode,
            requestContext: requestContext
        )
        return PromptBundle(
            systemPrompt: systemPrompt,
            skillLayers: skillLayers,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt(
                cachedSystemPrompt: systemPrompt,
                skillLayers: skillLayers,
                userPrompt: userPrompt
            )
        )
    }

    private static func makeCardSupplementPromptBundle(
        text: String,
        card: MemoryCard,
        currentDate: String
    ) -> PromptBundle {
        let threadText = cardConversationThreadPrompt(from: card.conversationMessages)
        let combinedText = [
            card.originalText,
            card.summary,
            card.message,
            card.completionMessage ?? "",
            card.supplementalText ?? "",
            threadText,
            text
        ]
        .joined(separator: "\n")
        let systemPrompt = resolvedSystemPrompt(
            text: combinedText,
            requestContext: .cardRevision(card: card),
            existingCards: [card]
        )
        let skillLayers = skillPromptLayers(imageInputMode: nil)
        let userPrompt = cardSupplementUserContent(
            text: text,
            card: card,
            threadText: threadText,
            currentDate: currentDate
        )
        return PromptBundle(
            systemPrompt: systemPrompt,
            skillLayers: skillLayers,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt(
                cachedSystemPrompt: systemPrompt,
                skillLayers: skillLayers,
                userPrompt: userPrompt
            )
        )
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
        skillLayers: [PromptLayer],
        userPrompt: String,
        imageAttachments: [ImageAttachment] = [],
        supportsImageInput: Bool = false,
        for model: LifeAgentLLMModel
    ) -> [DeepSeekMessage] {
        if Self.usesExplicitContextCache(for: model) {
            let blocks = [
                DeepSeekContentBlock.text(systemPrompt, cacheControl: .init(type: "ephemeral"))
            ] + skillLayers.map {
                DeepSeekContentBlock.text($0.content)
            }
            if supportsImageInput, !imageAttachments.isEmpty {
                return [
                    DeepSeekMessage(role: "system", contentBlocks: blocks),
                    DeepSeekMessage(
                        role: "user",
                        contentBlocks: [.text(userPrompt)] + imageAttachments.map { .image(url: $0.dataURL) }
                    )
                ]
            }
            return [
                DeepSeekMessage(role: "system", contentBlocks: blocks),
                DeepSeekMessage(role: "user", content: userPrompt)
            ]
        }

        var messages: [DeepSeekMessage] = [DeepSeekMessage(role: "system", content: systemPrompt)]
        messages.append(contentsOf: skillLayers.map {
            DeepSeekMessage(role: "system", content: $0.content)
        })
        if supportsImageInput, !imageAttachments.isEmpty {
            messages.append(
                DeepSeekMessage(
                    role: "user",
                    contentBlocks: [.text(userPrompt)] + imageAttachments.map { .image(url: $0.dataURL) }
                )
            )
        } else {
            messages.append(DeepSeekMessage(role: "user", content: userPrompt))
        }
        return messages
    }

    private static func removeThinkingTags(from text: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractLastCodeBlock(from text: String) -> Data? {
        let pattern = "```(?:json|JSON)?\\s*([\\s\\S]*?)\\s*```"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let matches = regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text))
        
        for match in matches.reversed() {
            if let range = Range(match.range(at: 1), in: text) {
                let codeContent = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if let data = codeContent.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    return data
                }
            }
        }
        return nil
    }

    private static func decodeAnalysis(from content: String) throws -> AgentAnalysis {
        guard let jsonData = jsonObjectData(from: content) else {
            throw AgentAnalysisDecodeFailure(detail: "未找到完整 JSON 对象")
        }
        let analysis: AgentAnalysis
        do {
            analysis = try JSONDecoder().decode(AgentAnalysis.self, from: jsonData)
        } catch {
            let detail = decodingErrorDetail(error)
            JotlyLog.deepSeek.error("JSONDecoder decoding AgentAnalysis failed: \(detail, privacy: .public)")
            throw AgentAnalysisDecodeFailure(detail: detail)
        }

        if analysis.needMemory != true {
            guard let card = analysis.card else {
                throw AgentAnalysisDecodeFailure(detail: "缺少用户可见卡片")
            }
            guard !card.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentAnalysisDecodeFailure(detail: "卡片标题为空")
            }
            guard !card.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentAnalysisDecodeFailure(detail: "卡片正文为空")
            }
        }
        return analysis
    }

    private static func decodingErrorDetail(_ error: Error) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            let value = codingPath.map(\.stringValue).joined(separator: ".")
            return value.isEmpty ? "根节点" : value
        }

        switch error {
        case DecodingError.keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath + [key]))：\(context.debugDescription)"
        case DecodingError.typeMismatch(_, let context):
            return "字段类型错误 \(path(context.codingPath))：\(context.debugDescription)"
        case DecodingError.valueNotFound(_, let context):
            return "字段值为空 \(path(context.codingPath))：\(context.debugDescription)"
        case DecodingError.dataCorrupted(let context):
            return "数据损坏 \(path(context.codingPath))：\(context.debugDescription)"
        default:
            return error.localizedDescription
        }
    }

    private static func combinedUsage(
        _ first: AgentModelUsage?,
        _ second: AgentModelUsage?
    ) -> AgentModelUsage? {
        guard first != nil || second != nil else { return nil }
        func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }
        return AgentModelUsage(
            inputTokens: sum(first?.inputTokens, second?.inputTokens),
            outputTokens: sum(first?.outputTokens, second?.outputTokens),
            promptTokens: sum(first?.promptTokens, second?.promptTokens),
            completionTokens: sum(first?.completionTokens, second?.completionTokens),
            totalTokens: sum(first?.totalTokens, second?.totalTokens),
            promptCacheHitTokens: sum(first?.promptCacheHitTokens, second?.promptCacheHitTokens),
            promptCacheMissTokens: sum(first?.promptCacheMissTokens, second?.promptCacheMissTokens),
            promptCacheCreationTokens: sum(first?.promptCacheCreationTokens, second?.promptCacheCreationTokens)
        )
    }

    private static func jsonObjectData(from content: String) -> Data? {
        let cleaned = removeThinkingTags(from: content)
        if let data = cleaned.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }

        if let fencedData = extractLastCodeBlock(from: cleaned) {
            return fencedData
        }

        let withoutFence = cleaned
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

    private static func fullPrompt(
        cachedSystemPrompt: String,
        skillLayers: [PromptLayer],
        userPrompt: String
    ) -> String {
        var parts: [String] = [
            "[cached_system]",
            cachedSystemPrompt
        ]
        for layer in skillLayers {
            parts.append("[\(layer.marker)]")
            parts.append(layer.content)
        }
        parts.append("[user]")
        parts.append(userPrompt)
        return parts.joined(separator: "\n")
    }

    private static func userContent(
        text: String,
        supplementalText: String?,
        currentDate: String,
        latestCardStatus: CardStatus,
        imageInputMode: ImageInputMode?,
        requestContext: AgentRequestContext
    ) -> String {
        let referenceDate = DateFormatting.date(fromDayString: currentDate)
        var parts = [
            "用户输入：\(text)",
            "用户输入时间：\(DateFormatting.userRequestDateTimeString(currentDateString: currentDate))",
            "当前农历日期：\(DateFormatting.lunarDateString(from: referenceDate))",
            "context_mode：\(requestContext.mode.rawValue)",
            "当前卡片状态：\(latestCardStatus.rawValue)"
        ]
        if let imageInputMode {
            parts.append("图片输入方式：\(imageInputMode.title)")
            parts.append("本次输入包含一张或多张图片，请把全部图片作为同一次请求整体理解。")
        }
        if let supplementalText, !supplementalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("补充信息：\(supplementalText)")
        }
        parts.append(contentsOf: requestContextUserContent(requestContext))
        return parts.joined(separator: "\n")
    }

    private static func requestContextUserContent(_ requestContext: AgentRequestContext) -> [String] {
        guard let card = requestContext.cardSnapshot else {
            return []
        }

        var parts: [String] = [
            "target_card_id：\(requestContext.targetCardId ?? card.id)",
            "卡片快照：",
            "- id：\(card.id)",
            "- type：\(card.type)",
            "- status：\(card.status.rawValue)",
            "- title：\(card.title)",
            "- summary：\(card.summary)",
            "- message：\(card.message)",
            "- original_text：\(card.originalText)"
        ]

        if let completionMessage = card.completionMessage, !completionMessage.isEmpty {
            parts.append("- completion_message：\(completionMessage)")
        }
        if let supplementalText = card.supplementalText, !supplementalText.isEmpty {
            parts.append("- supplemental_text：\(supplementalText)")
        }
        if let selectedOptionValue = card.selectedOptionValue {
            parts.append("- selected_option_value：\(selectedOptionValue)")
        }
        if !card.options.isEmpty {
            let optionsText = card.options.map { option in
                "\(option.key). \(option.label) value=\(option.value)"
            }.joined(separator: "；")
            parts.append("- options：\(optionsText)")
        }
        if let reminderInfo = card.reminderInfo {
            let reminderParts = [
                "type=\(reminderInfo.type)",
                "person=\(reminderInfo.personName)",
                "date=\(reminderInfo.date)",
                "status=\(reminderInfo.status)",
                "calendar_event_id=\(reminderInfo.calendarEventId ?? "")",
                "reminder_item_id=\(reminderInfo.reminderItemId ?? "")",
                "notification_request_id=\(reminderInfo.notificationRequestId ?? "")"
            ]
            parts.append("- reminder_info：\(reminderParts.joined(separator: "，"))")
        }
        if let metadata = card.metadata, !metadata.isEmpty {
            let metadataText = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "，")
            parts.append("- metadata：\(metadataText)")
        }
        let threadText = cardConversationThreadPrompt(from: card.conversationMessages)
        if !threadText.isEmpty {
            parts.append("卡片对话线程：\n\(threadText)")
        }
        if let lastExecutionResult = requestContext.lastExecutionResult, !lastExecutionResult.isEmpty {
            parts.append("上一轮工具执行结果：\(lastExecutionResult)")
        }

        parts.append("要求：本轮只能更新 target_card_id 对应卡片。若无法承载本次输入，返回 within_card_scope=false 和 scope_reason。")
        return parts
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
    * 一个打卡统计或习惯卡片；
    * 一个正数日/倒数日纪念卡片；
    * 一个订阅记录；
    * 一条可回看的生活记忆。
    你的回复不应该像聊天机器人一样长篇解释。
    卡片文案要短、准、自然。

    ---

    ## 三、直接执行与确认执行规范
    - **直接静默执行 (tool_plan)**：仅在动作低风险且关键参数完整时使用。此时 `should_execute_now` 为 `true`，`requires_confirmation` 为 `false`。
    - **确认后执行 (options[].actions 或 action_buttons[].actions)**：对于中高风险动作（如创建生日、缴费等日程/提醒事项），你必须在卡片选项（options）或辅助按钮（action_buttons）中挂载相应的 actions，并设置 `requires_confirmation = true`。用户点击后，由 App 提取对应动作 of parameters 并执行。
    - **支持无选项的纯内容/反馈卡片（滞空卡片）**：
      - 卡片不仅用于审批确认，也可作为纯文本反馈（例如直接回答用户、记录无待办的事件）。
      - 如果交互不需要用户二次确认，你应当将 `requires_confirmation` 设为 `false` 并**将 `options` 设为空数组 `[]`（或省略该字段）**。客户端会将其直接作为“已完成”（绿点状态）展示，不出现任何按钮，只渲染题干与正文，实现纯粹的内容信息反馈。
    - **记忆查询与回复卡片**：
      - 当用户询问“我之前……”“去年……”“上次……”“你记得……吗”或其他必须依赖用户历史信息才能回答的问题时，第一轮必须返回 `need_memory: true`，并在 `memory_query` 中给出简短、明确、适合检索的查询语句。此时不要凭空回答。
      - 当补充信息中出现 `[MEMORY_RETRIEVAL_RESULTS]` 与 `memory_retrieval_completed: true` 时，说明记忆检索已经完成。你必须返回 `need_memory: false`，卡片类型必须是 `reply`，只用 `message` 回答用户；`options`、`tool_plan`、`memory_to_save` 必须为空。
      - `reply` 卡片只用于回答问题，不表示新增记录，不得把用户的一次记忆查询再次存成新记忆。
      - 回复只能依据检索结果。没有找到时直接说“目前没有找到相关记忆”，不得猜测或补造。
    - **结果卡片规范 (result_card)**：每个卡片选项 (options) 或辅助按钮 (action_buttons) **必须** 挂载一个 `"result_card"` 结构，并在其中指定 `message` 参数。当用户做出相应选择后，客户端将直接显示此 `message`，**大模型必须通过此字段来对每一条可能的分支生成拟人化、贴心、精准的完成话术，客户端本身绝不生成任何温情问候或提示文案**。

    ---

    ## 四、禁止静默默认原则（消除人机代差）
    - **禁止替用户做过度默认假设**：当处理需要定时提醒或重要重复任务时，若用户表达模糊，可通过卡片选项让用户确认，而不要直接静默地替用户做出可能错误的决策。
    - **必须在卡片选项中列出清晰的决策路径**：
      - **日常/习惯提醒**：如果用户想记个提醒但没说明频率，必须在选项中列出“每天重复提醒”（挂载 `reminder.create`，`repeat_rule: "daily"`）、“仅提醒这一次”（挂载 `reminder.create`，`repeat_rule: "once"`）、“仅作备忘记录”（挂载 `memory.save`）。
      - 如果所有关键参数齐全，可以直接提供“同意创建”与“仅记录”。

    ---

    ## 五、文案风格与备注 (Note) 特别规范
    ## 五、新增卡片类型及派生从属规则 (New Card Types & Derivation Rules)
    1. **习惯打卡卡片 (type: "habit")**：
       - 用于记录用户想长期坚持的习惯或活动打卡统计（例如“开始每天喝咖啡打卡”、“每天喝奶茶记录”、“点外卖统计”等）。
       - 只要检测到用户有长期、高频、可累积统计的活动倾向，应将对应卡片类型设为 `"habit"`。
    2. **正数日/倒数日卡片 (type: "countdown")**：
       - 用于展示某个时间节点距离当前时刻的天数（例如“距离高考还有多少天”、“戒烟坚持了多少天”）。
       - 在 `metadata` 字典中，**必须**输出 `"target_date"`，格式为 `"yyyy-MM-dd"`。
    3. **卡片派生与从属关系 (derived_cards)**：
       - **黄金法则**：一个用户请求（主卡片）可能会包含多个具体的需求或衍生任务（例如，用户说“帮我开启吃药打卡，下周一去北京出差，并记录下个月8号是妈妈生日”）。
       - 在这种包含多项需求的情况下：
         - 顶层 `card` 应该是一个复合主卡片（type 设为 `"note"` 或 `"record"`），汇总展示用户的整段输入与整体状态。
         - 在 JSON 根级增加 `"derived_cards"` 字段，将派生的各子事务作为子卡片输出在数组中。
         - 每个子卡片声明它的 `type`（如 `"habit"`，`"countdown"`，`"reminder"`，`"birthday"`）、`title`、`summary`、`message`，并在 `metadata` 中提供必要字段。
         - App 客户端会自动将它们作为子卡片在 UI 上与主卡片进行连接和延续展示。

    ---

    ## 六、文案风格与备注 (Note) 特别规范
    - **绝对的备注控制权**：App 底层在写入 iOS 日历 (EKEvent) 和提醒事项 (EKReminder) 时，**完全没有任何自动拼接的文案模板**（不会自动添加“来自随心记”等小尾巴）。备注 (note / advance_note / birthday_note) **全部由你完全决定并直接写入**。
    - **备注要求**：必须输出简短、拟人、贴心、有温度的完整中文字符串。绝对不能包含任何 JSON 格式、技术字段名、引号、冒号标签（如“生日日期：”或“备忘：”）。
      - 错误示例：`note: "起飞时间：19:00"` 或 `note: "带身份证，来自随心记"`
      - 正确示例：`note: "晚上七点准时起飞，出发前别忘了仔细检查一下身份证 and 随身登机牌哦。"`
      - 生日提前提醒备注 (`advance_note`) 示例：`"过几天就是小A的生日了，可以提前准备一个暖心的小惊喜或是一句简单的问候。"`
      - 生日当天日程备注 (`birthday_note`) 示例：`"今天是小A的生日，记得送上最真挚的生日祝福，让这一天充满仪式感。"`
    - **文案要短、准、有一点温度**，拒绝任何套话、空泛的抒情或心理咨询式的长句。不使用“作为 AI”。

    ---

    ## 七、可用工具、边界条件与参数要求
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

    10. **`habit.create`**
        - **使用场景**：注册并创建一个全新的习惯打卡卡片。用户提出一个新的想长期做并计数的活动（如“我打算每天开始吃药打卡”），且数据库注册表里没有该卡片时调用。
        - **参数要求**：
          - `title` (String, 必须): 习惯的标题名称（如 `"吃药打卡"`、`"奶茶打卡"`）。
          - `initial_check_ins` (Array, 可选): 初始打卡日期数组，每个元素包含 `date` (格式 `yyyy-MM-dd`) 和 `count` (Integer，打卡次数)。

    11. **`habit.check_in`**
        - **使用场景**：在已有的习惯打卡卡片上记入新的打卡。当用户有打卡、计数事件（如“我今天又喝了咖啡”或“我这周一喝了1杯、周三喝了2杯咖啡”），且对应习惯卡片已在注册表存在时调用（必须提供卡片 ID）。
        - **参数要求**：
          - `card_id` (String, 必须): 已有习惯卡片的 ID。
          - `check_ins` (Array, 必须): 意图记入的打卡清单。每个元素包含 `date` (格式 `yyyy-MM-dd`) 和 `count` (Integer，打卡次数)。
          - `optimized_message` (String, 可选): 拟人化贴心的打卡完成文案。

    12. **`countdown.create`**
        - **使用场景**：创建一个全新的正/倒数日纪念日卡片。用户要求记住距离某天还有多久（倒计时）或者某天已经过去多久（正计时）时调用。
        - **参数要求**：
          - `title` (String, 必须): 正/倒计时的标题（如 `"黑客松比赛结束"`、`"入职周年"`）。
          - `target_date` (String, 必须): 目标基准日期，格式为 `yyyy-MM-dd`（如 `"2026-07-15"`）。

    13. **`countdown.update`**
        - **使用场景**：修改、调整或更新已有的正数日/倒数日纪念卡片信息（如“把比赛倒计时改到18号”）。
        - **参数要求**：
          - `card_id` (String, 必须): 已有正/倒数日卡片的 ID。
          - `title` (String, 可选): 新标题。
          - `target_date` (String, 可选): 新目标基准日期，格式为 `yyyy-MM-dd`。

    14. **`subscription.save`**
        - **使用场景**：保存从订阅页或扣费页识别出的本地订阅记录。
        - **边界条件**：只写入 Jotly 本地数据库，可直接执行；不得同时静默创建日历或提醒。
        - **参数要求**：
          - `service_name` (String, 必须): 软件或服务名称。
          - `plan_name` (String, 可选): 套餐名称。
          - `amount` (Number, 可选): 单次扣费金额。
          - `currency` (String, 可选): 币种，默认 `CNY`。
          - `billing_cycle` (String, 可选): `weekly | monthly | quarterly | yearly | unknown`。
          - `next_billing_date` (String, 可选): 下次扣费日期，格式 `yyyy-MM-dd`。

    15. **`asset.ingest`**
        - **使用场景**：把一张或多张小票、订单图片中的全部商品作为一次资产入库。
        - **边界条件**：一批图片只能调用一次。普通单件资产可直接记录；购物小票的批量入库必须放在用户确认选项中，确认前不得执行。
        - **参数要求**：
          - `items` (Array, 必须): 商品数组，每项包含 `name`、`category`、`quantity`，可选 `amount` / `unit_price` / `total_price`、`currency`、`purchase_date`、`estimated_expiry_date`、`estimate_note`。
          - 估算保质期或更换周期时，`estimate_note` 必须明确包含“估算”依据；耐用品不得填写估算淘汰日期。

    ---

    ## 八、输出 JSON 协议格式
    你必须且只能输出包含一个符合以下模式的严格 JSON 块，严禁输出多个 JSON 块，严禁重复或拼接相同的 JSON 块，严禁在 JSON 之外输出任何 Markdown 标记或解释文字。
    除仅用于触发记忆检索的第一轮外，`card.title` 和 `card.body` 都是必填非空字段。标题负责概括，正文负责向用户解释结果或提出确认问题，不能只返回标题。
    {
      "intent": "string",
      "risk_level": "low | medium | high",
      "requires_confirmation": true,
      "should_execute_now": false,
      "reasoning": "私有推理空间，思考是否信息齐备、是否有历法/周期代差等",
      "card": {
        "cardType": "birthday | date_task | counter | receipt | subscription | asset | reminder | note | record | habit | countdown | reply | unknown",
        "title": "卡片标题",
        "summary": "简短的一句摘要",
        "body": "卡片唯一正文。只写用户需要看到的结果，不复述输入，不展示内部提示词",
        "status": "processing | waiting_confirmation | completed | failed",
        "backgroundStyle": "plain | animatedGradient | illustration | atmosphereImage | brandTint | assetImage",
        "backgroundSemantic": "仅描述背景语义，不输出布局坐标或代码",
        "attributes": [
          {"label": "购入价格", "value": "¥199"}
        ],
        "metrics": [
          {"label": "本月累计", "value": "6", "unit": "杯"}
        ],
        "children": [
          {
            "id": "稳定且唯一的子项 ID",
            "cardType": "habit | asset | reminder | record",
            "title": "子项标题",
            "body": "一行关键摘要",
            "attributes": [],
            "actions": [
              {"tool": "asset.ingest", "when": "now", "params": {}}
            ],
            "status": "pending",
            "isIgnored": false
          }
        ],
        "options": [
          {
            "key": "A",
            "label": "仅作记录",
            "value": "record_only",
            "description": "仅记录在本地备忘，不创建提醒",
            "next_step": "finish",
            "actions": [
              {
                "tool": "memory.save",
                "when": "now",
                "params": {
                  "type": "record",
                  "content": "西藏出游准备清单：带上防晒霜、保温杯、相机、冲锋衣"
                }
              }
            ],
            "result_card": {
              "message": "已将你的出行清单记录到备忘中啦，随时可以在主页查看。"
            }
          },
          {
            "key": "B",
            "label": "创建提醒",
            "value": "create_reminder",
            "description": "在提醒事项中创建单次待办提醒",
            "next_step": "finish",
            "actions": [
              {
                "tool": "reminder.create",
                "when": "now",
                "params": {
                  "title": "整理西藏出游清单",
                  "date": "2026-06-28 10:00",
                  "repeat_rule": "once",
                  "note": "记得整理西藏行囊：带上防晒霜、保温杯、相机和防寒衣物。"
                }
              }
            ],
            "result_card": {
              "message": "已为你创建明天上午10点的提醒：“整理西藏出游清单”。"
            }
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
      "need_memory": false,
      "memory_query": null,
      "user_visible_text": "在气泡中展现的一句话，需贴心精简",
      "optimized_user_text": "由模型将用户语音识别（ASR）文本里的语气词、卡顿、口语病优化后，更为干净通顺的文本备用（不改变原意）",
      "derived_cards": [
        {
          "type": "habit | countdown | birthday | date_task | subscription | asset | reminder | note | record | reply",
          "title": "习惯吃药打卡",
          "summary": "每天早晚吃药记录",
          "message": "已为你开启每天吃药的习惯记录，记得坚持哦！",
          "metadata": {
            "target_date": "2026-07-15"
          }
        }
      ]
    }

    卡片结构规则：
    - `body` 是普通用户唯一可见正文，禁止同时在 `summary`、`body` 中重复同一句话。
    - 不得输出“用户上传了一张图片，请……”等内部任务描述。
    - 不得生成“补充信息”或 `request_more_info` 选项；用户补充内容统一通过长按当前卡片完成。
    - 只返回结构化内容；不要返回坐标、字号、固定高度、HTML 或 SwiftUI。
    - `attributes` 最多提供 4 个最关键属性，其余信息放详情或调试输出。
    - 普通卡 `children=[]`；只有小票等一对多确认任务才使用 `children`。

    `memory_to_save` 只写入未来值得再次检索的稳定事实、事件、偏好、关系或任务摘要：
    - 内容必须脱离当前对话也能独立理解，避免“这个”“那里”等无指代文本。
    - 不保存模型回复、推理过程、寒暄、一次性查询问题或已经由检索结果回答的内容。
    - 没有长期价值时返回空数组 `[]`。
    """

    private static let cardLifecyclePrompt = """
    ## 八、卡片级生命周期循环
    每一张卡片都是一个独立的生命周期循环。用户后续对同一张卡长按语音、补充文字或点击选项，都不是新任务，而是这张卡自己的下一轮输入。

    当动态上下文里的 `context_mode` 为 `card_revision` 或 `option_continue` 时：
    - 只能围绕 `target_card_id` 对应的当前卡片做修正、补充、确认或继续执行。
    - 必须读取卡片快照、卡片对话线程、已执行工具结果和本次用户输入。
    - 待确认卡：本次输入等同于用户继续补充信息，需要重新输出这张卡的完整待确认状态。
    - 已完成卡：本次输入等同于用户修改已有结果，需要尽量基于已有工具产物更新旧结果，不要重复创建无关新卡。
    - 如果用户输入明显超出当前卡片范围，返回 `within_card_scope = false`，并用 `scope_reason` 给出简短文案。

    可用于修改已完成卡的工具：
    - `reminder.update`：修改当前卡已有提醒事项。参数沿用 `reminder.create`，必须尽量携带新的 `title`、`date` 或 `due_at`、`repeat_rule`、`note`。
    - `calendar.update` / `calendar.update_event`：修改当前卡已有日历事件。参数沿用 `calendar.create_event`，必须尽量携带新的 `title`、`date` 或 `start_date`、`repeat_rule`、`note`。
    - `memory.update`：修改当前卡已有本地记录。参数沿用 `memory.save`，必须携带新的 `content`。
    - 当 `reminder_info.calendar_event_id` 非空且用户修改日期或时间时，必须使用 `calendar.update`；当只有 `reminder_item_id` 时使用 `reminder.update`。不得声称无法修改，也不得重新创建无关卡片。
    - 用户只说“改成下午 4 点”等局部时间时，必须继承卡片快照中的原日期、标题和重复规则，向更新工具返回完整的 `yyyy-MM-dd HH:mm`。本轮修改指令本身就是明确授权，设置 `should_execute_now=true`。

    输出 JSON 除原有字段外，可以包含：
    {
      "context_mode": "new_card | card_revision | option_continue",
      "target_card_id": "string | null",
      "within_card_scope": true,
      "scope_reason": "string | null"
    }
    """

    private static func resolvedSystemPrompt(
        text: String,
        requestContext: AgentRequestContext,
        existingCards: [MemoryCard]
    ) -> String {
        var layers = [systemPrompt, cardLifecyclePrompt]
        if shouldLoadBirthdaySkill(text: text, requestContext: requestContext) {
            layers.append(birthdaySkillPrompt)
        }
        layers.append(activeCardsRegistryPrompt(for: existingCards))
        return layers.joined(separator: "\n\n")
    }

    private static func shouldLoadBirthdaySkill(
        text: String,
        requestContext: AgentRequestContext
    ) -> Bool {
        if text.localizedStandardContains("生日") {
            return true
        }

        guard requestContext.mode != .newCard,
              let card = requestContext.cardSnapshot
        else {
            return false
        }

        return card.type == "birthday"
            || card.originalText.localizedStandardContains("生日")
    }

    private static func activeCardsRegistryPrompt(for cards: [MemoryCard]) -> String {
        let habits = cards.filter { $0.type == "habit" }
        let habitList = habits.map { "- ID: \"\($0.id)\", Title: \"\($0.title)\"" }.joined(separator: "\n")
        
        let countdowns = cards.filter { $0.type == "countdown" }
        let countdownList = countdowns.map { "- ID: \"\($0.id)\", Title: \"\($0.title)\", TargetDate: \"\($0.targetDateString ?? $0.metadata?["target_date"] ?? "")\"" }.joined(separator: "\n")
        
        return """
        ## 九、系统当前已有卡片注册表 (Active Cards Registry)
        以下是用户当前已创建并保存在系统中的习惯打卡和正倒数日卡片。
        当处理新输入或修改长按卡片时，如果用户表达的打卡或计数指令、或者是对某个特定倒数日（如黑客松）的修改意图，能匹配到列表中的某张卡片，你必须优先更新（使用 `habit.check_in` 或 `countdown.update`）这些已有卡片（复用其 ID 传参），绝对禁止为其新建重复的卡片！
        
        对于卡片修改修改（包含日常日程修改，或习惯/倒计时修改），你必须在输出 JSON 的顶层中返回 `"change_note"`，描述具体修改了什么（例如 `"将日期改至2026-07-18"`、`"打卡次数累计+1"`），以便客户端展示简易胶囊变更徽章。

        ### 1. 已有习惯打卡卡片 (Habit Cards):
        \(habitList.isEmpty ? "（暂无）" : habitList)
        
        ### 2. 已有正倒数日卡片 (Countdown Cards):
        \(countdownList.isEmpty ? "（暂无）" : countdownList)
        """
    }

    private static func skillPromptLayers(imageInputMode: ImageInputMode?) -> [PromptLayer] {
        guard imageInputMode != nil else { return [] }
        return [
            PromptLayer(
                marker: "mvp_image_demo_skill",
                title: "MVPImageDemoSkillPack",
                content: mvpImageDemoSkillPrompt
            )
        ]
    }

    private static let mvpImageDemoSkillPrompt = """
    ## MVP 图片演示技能包
    本技能包只处理图片输入。多张图片属于同一次请求，必须整体理解并只生成一张主卡片；不得按图片数量拆成多张重复卡片。

    ### 1. 微信生日候选
    这是本次 MVP 的重点演示场景，优先级高于普通截图记录。

    #### 识别依据
    - 先判断图片是否是微信聊天页、联系人页或资料页。可参考微信界面结构、聊天标题、联系人头像、消息气泡和资料字段，不要只看某一个孤立词。
    - 如果页面顶部聊天标题、联系人名称或备注名附近同时出现一个合理日期，应优先理解为该联系人的“生日候选”。常见形式包括：`妈妈 7月16日`、`妈妈 07-16`、`妈妈(7.16)`、`小王 1998/07/16`、`张三 0716`。
    - `person_name` 必须取日期旁边的联系人名称并移除日期本身。例如 `妈妈 7月16日` 的人物是“妈妈”，绝不能改成用户本人，也不能擅自改成其他亲属。
    - 只出现月日也足以生成生日候选，不要求备注里明确出现“生日”两个字。年份存在时保留为证据信息；每年重复提醒仍以月日为核心。
    - 本地 OCR 模式下，如果文本能体现“微信页面 + 联系人标题/备注 + 日期”的组合，也按同一规则处理，不得因为没有直接看到图片而忽略生日候选。

    #### 必须排除的误判
    - 消息气泡里的聊天内容日期、消息时间、聊天日期分隔线、转账时间、订单时间和系统通知时间，不能仅凭日期就判定为生日。
    - 日期没有与联系人名称或备注字段形成明确关联时，不要硬猜生日；回落为普通图片理解或要求补充信息。
    - 无效日期、无法确认人物名称时不得编造人物或日期。

    #### 固定输出行为
    - 证据满足时，输出 `intent="wechat_birthday_candidate"`，主卡必须是 `birthday`，标题使用“人物称呼 + 生日提醒”，例如“妈妈生日提醒”。只生成这一张主卡，不得同时生成普通截图记录卡。
    - `summary` 明确写出从微信备注识别到的人物和日期；`message` 说明“这个日期大概率是生日”，并询问用户选择阳历、农历或仅记录。
    - `metadata` 至少包含：`person_name`、`birthday_date_text`、`date`、`evidence_source="wechat_contact_remark"`。`birthday_date_text` 忠实保留图片文字；`date` 必须归一化为 `yyyy-MM-dd`。图片没有年份时使用当前年份补全，只用于传递月日，不得自行改月日。
    - 未明确阳历或农历时，必须设置 `requires_confirmation=true`、`should_execute_now=false`、`tool_plan=[]`，确认前不得创建日历、提醒事项或通知。
    - 必须提供三个选项：
      - A `仅记录`：`value="record_only"`，只挂载 `memory.save`。
      - B `阳历`：`value="create_solar_birthday_reminder"`，提供“3天”和“6天”两个 `action_buttons`，分别挂载 `create_solar_birthday_reminder`。
      - C `农历`：`value="create_lunar_birthday_reminder"`，提供“3天”和“6天”两个 `action_buttons`，分别挂载 `create_lunar_birthday_reminder`。
    - 四个提醒动作都必须携带识别出的人物、标准化后的 `date`、图片中的月日、对应提前天数以及完整的祝福备注。用户选择历法和提前天数后才执行。

    ### 2. 奶茶、咖啡打卡
    - 图片是美团、饿了么等订单，且商品明确是奶茶、咖啡或其他饮品；或图片本身明确拍摄了奶茶、咖啡，应生成或更新 `habit` 打卡卡片。
    - 已有匹配习惯卡时使用 `habit.check_in`；没有时使用 `habit.create`。标题使用“奶茶打卡”或“咖啡打卡”等长期行为，不使用单次商户名代替。
    - 同一批图片只记一次本次事件，禁止重复打卡。
    - 这是本地记录，设置 `requires_confirmation=false`、`should_execute_now=true`、`options=[]`。

    ### 3. 软件订阅
    - 图片是 App Store、系统订阅页、软件会员页或扣费页面时，优先提取软件名称、套餐、金额、币种、扣费周期和下次扣费日期，生成 `subscription` 卡片。
    - 使用 `subscription.save` 保存本地订阅记录。保存本地记录可直接执行；创建任何外部提醒必须作为用户确认后的选项动作。
    - 本轮只保存订阅，设置 `requires_confirmation=false`、`should_execute_now=true`、`options=[]`；如需提醒，在卡片文案中提示用户可回到 Jotly 补充，不在同一轮静默创建。

    ### 4. 小票与资产
    - 图片是购物小票、订单明细或购买凭证时，生成一张 `receipt` 父卡，禁止每个商品各生成一张首页卡片。
    - 父卡的 `children` 按语义整理为打卡、资产、提醒建议或普通记录。每个子项必须提供稳定 ID、一行摘要和对应 actions。
    - 商品可包含食品、调味品、日用品、牙刷和电子产品。购买日期、数量、价格以图片证据为准。
    - 食品、调味品和牙刷允许给出明确标注为“估算”的保质期或更换周期；耐用品只记录购买日期和价格，不猜测淘汰时间。
    - 必须设置 `requires_confirmation=true`、`should_execute_now=false`，确认前不得调用 `asset.ingest`、打卡或提醒工具。
    - `options` 至少包含“确认创建”和“仅保存小票”。“确认创建”的 actions 汇总所有未忽略子项动作；“仅保存小票”只能保存小票原始记录。
    - 创建提醒仍属于外部行动，必须在用户明确确认后执行。

    ### 5. 输出优先级和安全
    - 优先选择以上最明确的单一主场景；没有可靠证据时才生成普通 `record`，不得硬猜。
    - 本地打卡和订阅保存属于低风险本地记录，可以直接执行；购物小票的批量资产入库必须先确认。
    - 日历、提醒事项和通知属于外部行动，必须放入用户可见的确认选项，确认前不得执行。
    """

    private static func cardSupplementSystemPrompt(for card: MemoryCard) -> String {
        let baseScope = """
        你是「随心记」里的卡片补充模式。

        你的任务是基于当前卡片的上下文，对同一张卡做局部修正、补充、微调或继续确认。
        你只能修改当前卡片内部的信息，不能跳出这张卡去创建新的无关任务，也不能把用户指令泛化成其他卡片。

        允许修改的范围包括：
        - 日期、时间、历法、提醒提前天数
        - 人名、称呼、备注、摘要、正文
        - 当前卡片的选项、执行路径、补充说明

        如果用户的指令明显超出了这张卡能承载的范围，请直接标记 `within_card_scope = false`，并在卡片里给出简短拒绝文案，例如“当前卡片无法识别该指令”或“无法完成该指令”。
        """

        switch card.type {
        case "birthday":
            return baseScope + """

            这张卡属于生日/纪念日上下文。优先保持人物、历法、提醒节奏和备注一致，只在当前卡内部继续修正。
            """
        case "date_task":
            return baseScope + """

            这张卡属于日期/提醒上下文。优先围绕日程时间、重复规则、提醒备注和执行状态做修改。
            """
        case "habit":
            return baseScope + """

            这张卡属于习惯打卡上下文。用户后续补充通常表示一次新的打卡、次数增加或范围修正，不要把它当成越界指令直接拒绝。
            优先围绕累计次数、打卡日期、备注和展示文案做增量更新。
            """
        case "countdown":
            return baseScope + """

            这张卡属于正倒数日上下文。用户后续补充通常表示标题修正、目标日期修正或说明补充，不要把它当成越界指令直接拒绝。
            优先围绕标题、目标日期和展示文案做增量更新。
            """
        case "reply":
            return baseScope + """

            这张卡是记忆查询的回复卡。用户后续输入属于对同一查询的追问，可以再次声明 `need_memory: true` 并生成更精确的 `memory_query`。
            最终仍返回 `reply` 卡片，只展示回复内容，不创建工具计划，不把查询本身写入记忆。
            """
        default:
            return baseScope + """

            这张卡属于普通记录或已完成卡片。优先围绕原始语义、补充说明和展示文案做增量调整。
            """
        }
    }

    private static func cardSupplementUserContent(
        text: String,
        card: MemoryCard,
        threadText: String,
        currentDate: String
    ) -> String {
        let referenceDate = DateFormatting.date(fromDayString: currentDate)
        var parts: [String] = [
            "当前时间：\(DateFormatting.userRequestDateTimeString(currentDateString: currentDate))",
            "当前农历日期：\(DateFormatting.lunarDateString(from: referenceDate))",
            "卡片ID：\(card.id)",
            "卡片状态：\(card.status.rawValue)",
            "卡片类型：\(card.type)",
            "卡片标题：\(card.title)",
            "卡片摘要：\(card.summary)",
            "卡片正文：\(card.message)"
        ]

        if let completionMessage = card.completionMessage, !completionMessage.isEmpty {
            parts.append("卡片完成信息：\(completionMessage)")
        }
        if let reminderInfo = card.reminderInfo {
            var reminderParts: [String] = [
                "类型=\(reminderInfo.type)",
                "主角=\(reminderInfo.personName)",
                "日期=\(reminderInfo.date)",
                "提前=\(reminderInfo.remindBeforeDays)天",
                "状态=\(reminderInfo.status)"
            ]
            if let nextTriggerDate = reminderInfo.nextTriggerDate {
                reminderParts.append("下次触发=\(nextTriggerDate)")
            }
            parts.append("提醒信息：\(reminderParts.joined(separator: "，"))")
        }
        if let supplementalText = card.supplementalText, !supplementalText.isEmpty {
            parts.append("已有补充信息：\(supplementalText)")
        }
        if let metadata = card.metadata, !metadata.isEmpty {
            let metadataText = metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: "，")
            parts.append("卡片元数据：\(metadataText)")
        }
        if !threadText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("卡片对话线程：\n\(threadText)")
        }
        parts.append("本次语音补充：\(text)")
        parts.append("要求：只在当前卡片范围内改写，若超出范围请返回拒绝文案并将 within_card_scope 标记为 false。")
        parts.append("最终输出必须是合法的 json，不能夹杂任何解释文字。")
        return parts.joined(separator: "\n")
    }

    private static func cardConversationThreadPrompt(from messages: [CardConversationMessage], limit: Int = 12) -> String {
        let recentMessages = Array(messages.suffix(limit))
        guard !recentMessages.isEmpty else {
            return ""
        }

        return recentMessages.enumerated().map { index, message in
            let prefix = message.role == .user ? "用户" : "模型"
            let stamp = DateFormatting.debugTimeString(from: message.createdAt)
            return "\(index + 1). \(prefix) [\(stamp)]：\(message.text)"
        }.joined(separator: "\n")
    }

    private static let birthdaySkillPrompt = """
    ## 生日提醒专项技能 (Birthday Reminder Skill)

    这段技能会在文本里出现“生日”时自动加载。最终要要不要当成生日提醒、要不要创建系统日程，仍然由你根据用户整句话自主判断。

    ### 核心交互、工具映射与硬规范要求：
    1. **主角称呼**：
       - 当用户说“我生日”“我的生日”“自己生日”时，主角就是用户本人，不要擅自改写成妈妈、爸爸、亲属或朋友。
       - 当用户明确说“我妈妈生日”“我朋友生日”“小孩生日”时，直接把对应称呼当作主角称呼即可，不要追问具体姓名。
       - 如果用户只说“生日”但没有明确是谁的生日，才再去结合上下文判断。
    2. **防静默默认与选项硬规范（核心澄清与引导规则）**：
       - **强制澄清规则**：当用户只说生日日期（例如“明天我妈妈生日”或“下周三我朋友生日”）而**没有明确声明是公历（阳历）还是农历（阴历）时，你绝对不能擅自假设是阳历或农历**！
       - 在这种模糊情况下，你必须生成一个处于“待确认”状态的卡片，并且：
         1) 在 `message` 中明确询问用户其历法属性（例如：“明天就是这位亲友的生日啦，对方过的是阳历（公历）还是农历（阴历）生日呢？要不要设置一个每年重复的提醒？”）。
         2) **必须严格返回以下三个选项（不得省略农历入口）**：
            - A 选项：仅作记录（挂载 `memory.save`，`value: "record_only"`，不创建每年重复提醒）。
            - B 选项：标签只写“阳历”（挂载 `create_solar_birthday_reminder`，必须有 action_buttons 提前天数选择）。
            - C 选项：标签只写“农历”（挂载 `create_lunar_birthday_reminder`，必须有 action_buttons 提前天数选择）。
         这可以强行引导用户做出清晰的区分和决策。
       - **必须包含 action_buttons**：主选项 B 和 C 的属性中，**必须**挂载 `action_buttons` 以提供天数决策按钮：
         - 第一个 action_button：标签只写“3天”，`value` 为“solar_3_days”/“lunar_3_days”，挂载参数含 `"remind_before_days": 3` 的 `create_solar_birthday_reminder` / `create_lunar_birthday_reminder`。
         - 第二个 action_button：标签只写“6天”，`value` 为“solar_6_days”/“lunar_6_days”，挂载参数含 `"remind_before_days": 6` 的 `create_solar_birthday_reminder` / `create_lunar_birthday_reminder`。
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
        "label": "阳历",
        "value": "create_solar_birthday_reminder",
        "description": "每年按阳历重复提醒我",
        "next_step": "finish",
        "action_buttons": [
          {
            "label": "3天",
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
            "label": "6天",
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
        "label": "农历",
        "value": "create_lunar_birthday_reminder",
        "description": "每年按农历重复提醒我",
        "next_step": "finish",
        "action_buttons": [
          {
            "label": "3天",
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
            "label": "6天",
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

struct DeepSeekThinkingConfig: Encodable {
    let type: String
}

private struct DeepSeekRequest: Encodable {
    let model: String
    let messages: [DeepSeekMessage]
    let responseFormat: DeepSeekResponseFormat?
    let temperature: Double
    let stream: Bool
    let enableThinking: Bool?
    let thinking: DeepSeekThinkingConfig?
    let maxTokens: Int?
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case responseFormat = "response_format"
        case temperature
        case stream
        case enableThinking = "enable_thinking"
        case thinking
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

private struct PromptLayer {
    let marker: String
    let title: String
    let content: String
}

private struct PromptBundle {
    let systemPrompt: String
    let skillLayers: [PromptLayer]
    let userPrompt: String
    let fullPrompt: String
}

private struct DeepSeekMessage: Codable {
    let role: String
    let content: String?
    let contentBlocks: [DeepSeekContentBlock]?
    let reasoningContent: String?

    init(role: String, content: String) {
        self.role = role
        self.content = content
        self.contentBlocks = nil
        self.reasoningContent = nil
    }

    init(role: String, contentBlocks: [DeepSeekContentBlock]) {
        self.role = role
        self.content = nil
        self.contentBlocks = contentBlocks
        self.reasoningContent = nil
    }

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case reasoningContent = "reasoning_content"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            content = stringContent
            contentBlocks = nil
        } else if let blocks = try? container.decode([DeepSeekContentBlock].self, forKey: .content) {
            content = nil
            contentBlocks = blocks
        } else {
            content = nil
            contentBlocks = nil
        }
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if let contentBlocks {
            try container.encode(contentBlocks, forKey: .content)
        } else {
            try container.encodeIfPresent(content, forKey: .content)
        }
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
    }

    var bestContent: String? {
        if let content = content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            return content
        }
        if let contentBlocks, !contentBlocks.isEmpty {
            let joined = contentBlocks.compactMap(\.text).joined()
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        if let reasoningContent = reasoningContent?.trimmingCharacters(in: .whitespacesAndNewlines), !reasoningContent.isEmpty {
            return reasoningContent
        }
        return nil
    }
}

private struct DeepSeekContentBlock: Codable {
    let type: String
    let text: String?
    let imageURL: DeepSeekImageURL?
    let cacheControl: DeepSeekCacheControl?

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
        case cacheControl = "cache_control"
    }

    static func text(_ text: String, cacheControl: DeepSeekCacheControl? = nil) -> DeepSeekContentBlock {
        DeepSeekContentBlock(type: "text", text: text, imageURL: nil, cacheControl: cacheControl)
    }

    static func image(url: String) -> DeepSeekContentBlock {
        DeepSeekContentBlock(type: "image_url", text: nil, imageURL: DeepSeekImageURL(url: url), cacheControl: nil)
    }
}

private struct DeepSeekCacheControl: Codable {
    let type: String
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
