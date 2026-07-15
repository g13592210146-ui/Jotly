import Combine
import Foundation

@MainActor
final class JotlyDebugTurnStore: ObservableObject {
    static let shared = JotlyDebugTurnStore()

    @Published private(set) var turns: [AgentDebugTurn] = []
    private let store: LocalStore

    private init() {
        let store = LocalStore()
        self.store = store
        turns = store.loadDebugTurns()
    }

    func startTurn(cardId: String, userText: String) {
        var turn = AgentDebugTurn(cardId: cardId, userText: userText)
        turn.updateNode(id: "input", state: .completed, detail: userText)
        turns.insert(turn, at: 0)
        store.upsertDebugTurn(turn)
    }

    func updateTurn(
        cardId: String,
        systemPrompt: String? = nil,
        userPrompt: String? = nil,
        fullPrompt: String? = nil,
        modelName: String? = nil,
        modelOutput: String? = nil,
        decodedSummary: String? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        promptCacheHitTokens: Int? = nil,
        promptCacheMissTokens: Int? = nil,
        promptCacheCreationTokens: Int? = nil,
        nodeId: String? = nil,
        nodeState: AgentDebugTurn.Node.State? = nil,
        nodeDetail: String? = nil
    ) {
        guard let index = turns.firstIndex(where: { $0.cardId == cardId }) else { return }
        if let systemPrompt {
            turns[index].systemPrompt = systemPrompt
        }
        if let userPrompt {
            turns[index].userPrompt = userPrompt
        }
        if let fullPrompt {
            turns[index].fullPrompt = fullPrompt
        }
        if let modelName {
            turns[index].modelName = modelName
        }
        if let modelOutput {
            turns[index].modelOutput = modelOutput
        }
        if let decodedSummary {
            turns[index].decodedSummary = decodedSummary
        }
        if let promptTokens {
            turns[index].promptTokens = promptTokens
        }
        if let completionTokens {
            turns[index].completionTokens = completionTokens
        }
        if let totalTokens {
            turns[index].totalTokens = totalTokens
        }
        if let promptCacheHitTokens {
            turns[index].promptCacheHitTokens = promptCacheHitTokens
        }
        if let promptCacheMissTokens {
            turns[index].promptCacheMissTokens = promptCacheMissTokens
        }
        if let promptCacheCreationTokens {
            turns[index].promptCacheCreationTokens = promptCacheCreationTokens
        }
        if let nodeId, let nodeState, let nodeDetail {
            turns[index].updateNode(id: nodeId, state: nodeState, detail: nodeDetail)
        } else {
            turns[index].updatedAt = Date()
        }
        store.upsertDebugTurn(turns[index])
    }

    func updateNode(cardId: String, nodeId: String, state: AgentDebugTurn.Node.State, detail: String) {
        updateTurn(cardId: cardId, nodeId: nodeId, nodeState: state, nodeDetail: detail)
    }

    func removeTurn(cardId: String) {
        turns.removeAll { $0.cardId == cardId }
    }
}
