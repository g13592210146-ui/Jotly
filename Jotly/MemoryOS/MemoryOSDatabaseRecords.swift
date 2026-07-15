import Foundation
import GRDB

nonisolated struct RawEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "raw_events"

    let id: String
    let type: String
    let content: String
    let attachmentPathsJSON: Data?
    let conversationID: String?
    let legacyCardID: String?
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, type, content
        case attachmentPathsJSON = "attachment_paths_json"
        case conversationID = "conversation_id"
        case legacyCardID = "legacy_card_id"
        case createdAt = "created_at"
    }
}

nonisolated struct ConversationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "conversations"

    let id: String
    var title: String?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct MessageRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "messages"

    let id: String
    let conversationID: String
    let role: String
    let content: String
    let rawEventID: String?
    let agentRunID: String?
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case conversationID = "conversation_id"
        case rawEventID = "raw_event_id"
        case agentRunID = "agent_run_id"
        case createdAt = "created_at"
    }
}

nonisolated struct AgentRunRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_runs"

    let id: String
    let triggerMessageID: String?
    var status: String
    var needMemory: Bool
    var memoryQuery: String?
    var toolPlanJSON: Data?
    var errorMessage: String?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, status
        case triggerMessageID = "trigger_message_id"
        case needMemory = "need_memory"
        case memoryQuery = "memory_query"
        case toolPlanJSON = "tool_plan_json"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct CardRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "cards"

    let id: String
    var type: String
    var title: String
    var status: String
    var contentJSON: Data
    var sourceRunID: String?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, type, title, status
        case contentJSON = "content_json"
        case sourceRunID = "source_run_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct CardMessageLinkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "card_message_links"

    let cardID: String
    let messageID: String
    let relationType: String

    enum CodingKeys: String, CodingKey {
        case cardID = "card_id"
        case messageID = "message_id"
        case relationType = "relation_type"
    }
}

nonisolated struct AgentDebugTurnRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "agent_debug_turns"

    let id: String
    let cardID: String
    var payloadJSON: Data
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case cardID = "card_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct ActionLogRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "action_logs"

    let id: String
    let agentRunID: String?
    let cardID: String?
    let toolName: String
    var status: String
    let parametersJSON: Data?
    var resultJSON: Data?
    var errorMessage: String?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, status
        case agentRunID = "agent_run_id"
        case cardID = "card_id"
        case toolName = "tool_name"
        case parametersJSON = "parameters_json"
        case resultJSON = "result_json"
        case errorMessage = "error_message"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct MemoryItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_items"

    let id: String
    let type: String
    var content: String
    var structuredDataJSON: Data?
    var importance: Double
    var confidence: Double
    var status: String
    var sourceEventID: String?
    var sourceMessageID: String?
    var embeddingStatus: String = "legacy"
    var embeddingError: String? = nil
    var embeddedAt: Double? = nil
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, type, content, importance, confidence, status
        case structuredDataJSON = "structured_data_json"
        case sourceEventID = "source_event_id"
        case sourceMessageID = "source_message_id"
        case embeddingStatus = "embedding_status"
        case embeddingError = "embedding_error"
        case embeddedAt = "embedded_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct MemoryEmbeddingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_embeddings"

    let memoryItemID: String
    let model: String
    let dimensions: Int
    let vectorBlob: Data
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case memoryItemID = "memory_item_id"
        case model, dimensions
        case vectorBlob = "vector_blob"
        case createdAt = "created_at"
    }
}

nonisolated struct MemorySearchCandidate: Sendable, Equatable {
    let id: String
    let type: String
    let content: String
    let importance: Double
    let confidence: Double
    let createdAt: Double
    var lexicalScore: Double
    var vectorScore: Double
}

nonisolated struct VectorMemoryRecord: Sendable {
    let memory: MemorySearchCandidate
    let dimensions: Int
    let vectorBlob: Data
}

nonisolated struct EntityRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entities"

    let id: String
    let type: String
    var name: String
    var normalizedName: String
    var attributesJSON: Data?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, type, name
        case normalizedName = "normalized_name"
        case attributesJSON = "attributes_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct EntityRelationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "entity_relations"

    let id: String
    let fromEntityID: String
    let relation: String
    let toEntityID: String?
    let valueJSON: Data?
    let confidence: Double
    let sourceMemoryID: String?
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, relation, confidence
        case fromEntityID = "from_entity_id"
        case toEntityID = "to_entity_id"
        case valueJSON = "value_json"
        case sourceMemoryID = "source_memory_id"
        case createdAt = "created_at"
    }
}

nonisolated struct MemoryEntityLinkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "memory_entity_links"

    let memoryItemID: String
    let entityID: String
    let role: String?

    enum CodingKeys: String, CodingKey {
        case memoryItemID = "memory_item_id"
        case entityID = "entity_id"
        case role
    }
}

nonisolated struct CardMemoryLinkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "card_memory_links"

    let cardID: String
    let memoryItemID: String
    let relationType: String

    enum CodingKeys: String, CodingKey {
        case cardID = "card_id"
        case memoryItemID = "memory_item_id"
        case relationType = "relation_type"
    }
}

nonisolated struct ShortcutOperationRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "shortcut_operations"

    let id: String
    let mode: String
    var phase: String
    var payloadJSON: Data
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, mode, phase
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct BirthdayEventRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "birthday_events"

    let id: String
    let cardID: String
    let payloadJSON: Data
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case cardID = "card_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

nonisolated struct ReminderTaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "reminder_tasks"

    let id: String
    let cardID: String
    let birthdayEventID: String?
    let payloadJSON: Data
    let createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id
        case cardID = "card_id"
        case birthdayEventID = "birthday_event_id"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
    }
}

nonisolated struct AssetRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "assets"

    var id: String
    let sourceCardID: String
    let normalizedName: String
    let name: String
    let category: String
    let quantity: Double
    let amount: Double?
    let currency: String?
    let purchasedAt: Double?
    let estimatedExpiryAt: Double?
    let estimateNote: String?
    let payloadJSON: Data?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, name, category, quantity, amount, currency
        case sourceCardID = "source_card_id"
        case normalizedName = "normalized_name"
        case purchasedAt = "purchased_at"
        case estimatedExpiryAt = "estimated_expiry_at"
        case estimateNote = "estimate_note"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

nonisolated struct SubscriptionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "subscriptions"

    var id: String
    let sourceCardID: String
    let normalizedService: String
    let serviceName: String
    let planName: String?
    let amount: Double?
    let currency: String?
    let billingCycle: String?
    let nextBillingAt: Double?
    let payloadJSON: Data?
    let createdAt: Double
    var updatedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, amount, currency
        case sourceCardID = "source_card_id"
        case normalizedService = "normalized_service"
        case serviceName = "service_name"
        case planName = "plan_name"
        case billingCycle = "billing_cycle"
        case nextBillingAt = "next_billing_at"
        case payloadJSON = "payload_json"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
