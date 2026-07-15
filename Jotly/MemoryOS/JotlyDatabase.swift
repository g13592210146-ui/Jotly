import Foundation
import GRDB

nonisolated enum JotlyDatabaseProvider {
    private static let lock = NSLock()
    private static var cachedDatabase: JotlyDatabase?
    private static var didAttemptInitialization = false

    static func shared(fileURL: URL? = nil) -> JotlyDatabase? {
        // Test/custom stores must stay isolated from the app database.
        if let fileURL {
            let urls = JotlyDatabase.defaultURLs(fileURL: fileURL)
            return try? JotlyDatabase(databaseURL: urls.database, legacyJSONURL: urls.legacyJSON)
        }

        lock.lock()
        defer { lock.unlock() }
        if didAttemptInitialization { return cachedDatabase }
        didAttemptInitialization = true
        let urls = JotlyDatabase.defaultURLs()
        cachedDatabase = try? JotlyDatabase(
            databaseURL: urls.database,
            legacyJSONURL: urls.legacyJSON
        )
        return cachedDatabase
    }
}

nonisolated final class JotlyDatabase: @unchecked Sendable {
    private let queue: DatabaseQueue
    private let legacyJSONURL: URL

    init(databaseURL: URL, legacyJSONURL: URL) throws {
        self.legacyJSONURL = legacyJSONURL

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.journalMode = .wal
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        queue = try DatabaseQueue(path: databaseURL.path, configuration: configuration)
        try JotlyDatabaseSchema.makeMigrator().migrate(queue)
        try migrateLegacyJSONIfNeeded()

        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: databaseURL.path
        )
    }

    static func defaultURLs(fileURL: URL? = nil) -> (database: URL, legacyJSON: URL) {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let legacyURL = fileURL ?? baseURL.appendingPathComponent("jotly_store.json")
        let databaseURL = legacyURL
            .deletingPathExtension()
            .appendingPathExtension("sqlite")
        return (databaseURL, legacyURL)
    }

    func loadSnapshot(cardLimit: Int? = nil) throws -> JotlyStoreSnapshot {
        try queue.read { db in
            var cardRequest = CardRecord.order(Column("updated_at").desc)
            if let cardLimit {
                cardRequest = cardRequest.limit(cardLimit)
            }
            let cards = try cardRequest.fetchAll(db)
                .compactMap { try? Self.decode(MemoryCard.self, from: $0.contentJSON) }

            let rawInputs: [RawInput]
            let birthdayEvents: [BirthdayEvent]
            let reminderTasks: [ReminderTask]
            if cardLimit == nil {
                rawInputs = try RawEventRecord
                    .order(Column("created_at").asc)
                    .fetchAll(db)
                    .map {
                        RawInput(
                            id: $0.id,
                            type: $0.type,
                            text: $0.content,
                            createdAt: Date(timeIntervalSince1970: $0.createdAt),
                            linkedCardId: $0.legacyCardID ?? ""
                        )
                    }
                birthdayEvents = try BirthdayEventRecord
                    .order(Column("created_at").asc)
                    .fetchAll(db)
                    .compactMap { try? Self.decode(BirthdayEvent.self, from: $0.payloadJSON) }
                reminderTasks = try ReminderTaskRecord
                    .order(Column("created_at").asc)
                    .fetchAll(db)
                    .compactMap { try? Self.decode(ReminderTask.self, from: $0.payloadJSON) }
            } else {
                // The home screen does not need historical raw events or
                // reminder payloads before first paint.
                rawInputs = []
                birthdayEvents = []
                reminderTasks = []
            }

            let shortcutOperations = try ShortcutOperationRecord
                .order(Column("updated_at").asc)
                .fetchAll(db)
                .compactMap { try? Self.decode(ShortcutAnalysisOperation.self, from: $0.payloadJSON) }

            return JotlyStoreSnapshot(
                rawInputs: rawInputs,
                cards: cards,
                birthdayEvents: birthdayEvents,
                reminderTasks: reminderTasks,
                shortcutOperations: shortcutOperations
            )
        }
    }

    func loadCards(limit: Int, offset: Int) throws -> [MemoryCard] {
        try queue.read { db in
            try CardRecord
                .order(Column("updated_at").desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
                .compactMap { try? Self.decode(MemoryCard.self, from: $0.contentJSON) }
        }
    }

    func cardExists(id: String) throws -> Bool {
        try queue.read { db in
            try CardRecord.fetchOne(db, key: id) != nil
        }
    }

    func saveRawInput(_ input: RawInput, card: MemoryCard) throws {
        try queue.write { db in
            try saveRawInput(input, card: card, in: db)
        }
    }

    func upsertCard(_ card: MemoryCard) throws {
        try queue.write { db in
            let sourceRunID = try String.fetchOne(
                db,
                sql: "SELECT source_run_id FROM cards WHERE id = ?",
                arguments: [card.id]
            )
            try upsertCard(card, sourceRunID: sourceRunID, in: db)
            if let sourceRunID,
               var run = try AgentRunRecord.fetchOne(db, key: sourceRunID) {
                run.status = Self.runStatus(for: card.status)
                run.updatedAt = card.updatedAt.timeIntervalSince1970
                try run.save(db)
            }
        }
    }

    func loadDebugTurns() throws -> [AgentDebugTurn] {
        try queue.read { db in
            try AgentDebugTurnRecord
                .order(Column("created_at").desc)
                .fetchAll(db)
                .compactMap { try? Self.decode(AgentDebugTurn.self, from: $0.payloadJSON) }
        }
    }

    func upsertDebugTurn(_ turn: AgentDebugTurn) throws {
        try queue.write { db in
            try AgentDebugTurnRecord(
                id: turn.id,
                cardID: turn.cardId,
                payloadJSON: try Self.encode(turn),
                createdAt: turn.createdAt.timeIntervalSince1970,
                updatedAt: turn.updatedAt.timeIntervalSince1970
            ).save(db)
        }
    }

    func upsertAssets(_ records: [AssetRecord]) throws {
        guard !records.isEmpty else { return }
        try queue.write { db in
            for var record in records {
                if let existing = try AssetRecord
                    .filter(Column("source_card_id") == record.sourceCardID)
                    .filter(Column("normalized_name") == record.normalizedName)
                    .fetchOne(db) {
                    record.id = existing.id
                    try record.update(db)
                } else {
                    try record.insert(db)
                }
            }
        }
    }

    func upsertSubscription(_ record: SubscriptionRecord) throws {
        try queue.write { db in
            var record = record
            if let existing = try SubscriptionRecord
                .filter(Column("source_card_id") == record.sourceCardID)
                .filter(Column("normalized_service") == record.normalizedService)
                .fetchOne(db) {
                record.id = existing.id
                try record.update(db)
            } else {
                try record.insert(db)
            }
        }
    }

    func shortcutOperation(id: String) throws -> ShortcutAnalysisOperation? {
        try queue.read { db in
            guard let record = try ShortcutOperationRecord.fetchOne(db, key: id) else { return nil }
            return try Self.decode(ShortcutAnalysisOperation.self, from: record.payloadJSON)
        }
    }

    func latestShortcutOperation() throws -> ShortcutAnalysisOperation? {
        try queue.read { db in
            guard let record = try ShortcutOperationRecord
                .order(Column("updated_at").desc)
                .fetchOne(db)
            else { return nil }
            return try Self.decode(ShortcutAnalysisOperation.self, from: record.payloadJSON)
        }
    }

    func upsertShortcutOperation(_ operation: ShortcutAnalysisOperation) throws {
        try queue.write { db in
            try upsertShortcutOperation(operation, in: db)
            try trimShortcutOperations(in: db)
        }
    }

    func updateShortcutOperation(
        id: String,
        update: (inout ShortcutAnalysisOperation) -> Void
    ) throws -> ShortcutAnalysisOperation? {
        try queue.write { db in
            guard let record = try ShortcutOperationRecord.fetchOne(db, key: id) else { return nil }
            var operation = try Self.decode(ShortcutAnalysisOperation.self, from: record.payloadJSON)
            update(&operation)
            operation.updatedAt = Date()
            try upsertShortcutOperation(operation, in: db)
            try trimShortcutOperations(in: db)
            return operation
        }
    }

    func replaceSnapshot(_ snapshot: JotlyStoreSnapshot) throws {
        try queue.write { db in
            try replaceCompatibilitySnapshot(snapshot, in: db)
        }
    }

    func appendBirthdayEvent(_ event: BirthdayEvent, reminderTask: ReminderTask?) throws {
        try queue.write { db in
            try birthdayEventRecord(event).save(db)
            if let reminderTask {
                try reminderTaskRecord(reminderTask).save(db)
            }
        }
    }

    func deleteCards(ids: Set<String>) throws {
        guard !ids.isEmpty else { return }
        try queue.write { db in
            for id in ids {
                try ReminderTaskRecord
                    .filter(Column("card_id") == id)
                    .deleteAll(db)
                try BirthdayEventRecord
                    .filter(Column("card_id") == id)
                    .deleteAll(db)
                try CardRecord.deleteOne(db, key: id)
            }
        }
    }

    @discardableResult
    func saveMemoryItem(_ memory: MemoryItemRecord, linkedCardID: String?) throws -> String {
        try queue.write { db in
            var resolvedMemory = memory
            if resolvedMemory.sourceMessageID == nil,
               let linkedCardID,
               let sourceMessage = try MessageRecord.fetchOne(
                   db,
                   sql: """
                   SELECT messages.*
                   FROM messages
                   JOIN card_message_links
                     ON card_message_links.message_id = messages.id
                   WHERE card_message_links.card_id = ?
                     AND card_message_links.relation_type = 'trigger'
                   ORDER BY messages.created_at ASC
                   LIMIT 1
                   """,
                   arguments: [linkedCardID]
               ) {
                resolvedMemory.sourceMessageID = sourceMessage.id
                resolvedMemory.sourceEventID = sourceMessage.rawEventID
            }

            // A model response can expose the same memory through both
            // memory_to_save and memory.save. Keep persistence idempotent at
            // the database boundary so every caller gets the same behavior.
            if let existingID = try String.fetchOne(
                db,
                sql: """
                SELECT id FROM memory_items
                WHERE status = 'active'
                  AND type = ?
                  AND content = ?
                  AND created_at >= ?
                ORDER BY created_at DESC
                LIMIT 1
                """,
                arguments: [
                    resolvedMemory.type,
                    resolvedMemory.content,
                    Date().addingTimeInterval(-300).timeIntervalSince1970
                ]
            ) {
                if let linkedCardID,
                   try CardRecord.fetchOne(db, key: linkedCardID) != nil {
                    try CardMemoryLinkRecord(
                        cardID: linkedCardID,
                        memoryItemID: existingID,
                        relationType: "projection"
                    ).save(db)
                }
                return existingID
            }

            try resolvedMemory.save(db)
            if let linkedCardID,
               try CardRecord.fetchOne(db, key: linkedCardID) != nil {
                try CardMemoryLinkRecord(
                    cardID: linkedCardID,
                    memoryItemID: resolvedMemory.id,
                    relationType: "projection"
                ).save(db)
            }
            return resolvedMemory.id
        }
    }

    func memoryItem(id: String) throws -> MemoryItemRecord? {
        try queue.read { db in
            try MemoryItemRecord.fetchOne(db, key: id)
        }
    }

    func markMemoryEmbeddingRunning(id: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_items
                SET embedding_status = 'running', embedding_error = NULL, updated_at = ?
                WHERE id = ? AND embedding_status IN ('pending', 'failed', 'running')
                """,
                arguments: [Date().timeIntervalSince1970, id]
            )
        }
    }

    func saveMemoryEmbedding(
        memoryID: String,
        model: String,
        dimensions: Int,
        vectorBlob: Data
    ) throws {
        try queue.write { db in
            let now = Date().timeIntervalSince1970
            try MemoryEmbeddingRecord(
                memoryItemID: memoryID,
                model: model,
                dimensions: dimensions,
                vectorBlob: vectorBlob,
                createdAt: now
            ).save(db)
            try db.execute(
                sql: """
                UPDATE memory_items
                SET embedding_status = 'completed', embedding_error = NULL,
                    embedded_at = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [now, now, memoryID]
            )
        }
    }

    func markMemoryEmbeddingFailed(id: String, error: String) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE memory_items
                SET embedding_status = 'failed', embedding_error = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [String(error.prefix(500)), Date().timeIntervalSince1970, id]
            )
        }
    }

    func pendingMemoryIDs(limit: Int = 20) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT id FROM memory_items
                WHERE status = 'active'
                  AND (
                    embedding_status IN ('pending', 'failed')
                    OR (embedding_status = 'running' AND updated_at < ?)
                  )
                ORDER BY updated_at ASC
                LIMIT ?
                """,
                arguments: [Date().addingTimeInterval(-120).timeIntervalSince1970, limit]
            )
        }
    }

    func memoryEmbeddingStatusCounts() throws -> [String: Int] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT embedding_status, COUNT(*) AS count
                FROM memory_items
                GROUP BY embedding_status
                """
            )
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let status: String = row["embedding_status"],
                      let count: Int = row["count"]
                else { return nil }
                return (status, count)
            })
        }
    }

    func lexicalMemoryCandidates(query: String, limit: Int = 30) throws -> [MemorySearchCandidate] {
        try queue.read { db in
            let escapedFTS = Self.ftsQuery(from: query)
            var rows: [Row] = []
            if let escapedFTS, !escapedFTS.isEmpty {
                rows = (try? Row.fetchAll(
                    db,
                    sql: """
                    SELECT m.id, m.type, m.content, m.importance, m.confidence, m.created_at,
                           (-bm25(memory_items_fts)) AS lexical_score
                    FROM memory_items_fts
                    JOIN memory_items m ON m.id = memory_items_fts.memory_item_id
                    WHERE memory_items_fts MATCH ? AND m.status = 'active'
                    ORDER BY bm25(memory_items_fts), m.importance DESC, m.created_at DESC
                    LIMIT ?
                    """,
                    arguments: [escapedFTS, limit]
                )) ?? []
            }

            if rows.count < limit {
                let likeRows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, type, content, importance, confidence, created_at,
                           CASE WHEN content = ? THEN 1.0 ELSE 0.72 END AS lexical_score
                    FROM memory_items
                    WHERE status = 'active' AND content LIKE '%' || ? || '%'
                    ORDER BY importance DESC, created_at DESC
                    LIMIT ?
                    """,
                    arguments: [query, query, limit]
                )
                let existing = Set(rows.compactMap { $0["id"] as String? })
                rows.append(contentsOf: likeRows.filter { row in
                    guard let id: String = row["id"] else { return false }
                    return !existing.contains(id)
                })
            }

            return rows.prefix(limit).compactMap(Self.memoryCandidate(from:))
        }
    }

    func vectorMemories(model: String, dimensions: Int) throws -> [VectorMemoryRecord] {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT m.id, m.type, m.content, m.importance, m.confidence, m.created_at,
                       e.dimensions, e.vector_blob
                FROM memory_embeddings e
                JOIN memory_items m ON m.id = e.memory_item_id
                WHERE m.status = 'active' AND e.model = ? AND e.dimensions = ?
                """,
                arguments: [model, dimensions]
            )
            return rows.compactMap { row in
                guard let memory = Self.memoryCandidate(from: row),
                      let vectorBlob: Data = row["vector_blob"],
                      let storedDimensions: Int = row["dimensions"]
                else { return nil }
                return VectorMemoryRecord(
                    memory: memory,
                    dimensions: storedDimensions,
                    vectorBlob: vectorBlob
                )
            }
        }
    }

    func updateAgentRunMemoryRequest(cardID: String, needMemory: Bool, query: String?) throws {
        try queue.write { db in
            try db.execute(
                sql: """
                UPDATE agent_runs
                SET need_memory = ?, memory_query = ?, updated_at = ?
                WHERE id = (SELECT source_run_id FROM cards WHERE id = ?)
                """,
                arguments: [needMemory, query, Date().timeIntervalSince1970, cardID]
            )
        }
    }

    func linkMemories(_ memoryIDs: [String], toCardID cardID: String) throws {
        guard !memoryIDs.isEmpty else { return }
        try queue.write { db in
            guard try CardRecord.fetchOne(db, key: cardID) != nil else { return }
            for memoryID in Set(memoryIDs) {
                guard try MemoryItemRecord.fetchOne(db, key: memoryID) != nil else { continue }
                try CardMemoryLinkRecord(
                    cardID: cardID,
                    memoryItemID: memoryID,
                    relationType: "retrieval_source"
                ).save(db)
            }
        }
    }

    func createActionLog(
        cardID: String?,
        toolName: String,
        parametersJSON: Data?
    ) throws -> String {
        let id = "action_\(UUID().uuidString)"
        let now = Date().timeIntervalSince1970
        try queue.write { db in
            let runID = cardID.flatMap { cardID in
                try? String.fetchOne(
                    db,
                    sql: "SELECT source_run_id FROM cards WHERE id = ?",
                    arguments: [cardID]
                )
            } ?? nil
            try ActionLogRecord(
                id: id,
                agentRunID: runID,
                cardID: cardID,
                toolName: toolName,
                status: "running",
                parametersJSON: parametersJSON,
                resultJSON: nil,
                errorMessage: nil,
                createdAt: now,
                updatedAt: now
            ).insert(db)
        }
        return id
    }

    func finishActionLog(id: String, resultJSON: Data?, errorMessage: String?) throws {
        try queue.write { db in
            guard var action = try ActionLogRecord.fetchOne(db, key: id) else { return }
            action.status = errorMessage == nil ? "completed" : "failed"
            action.resultJSON = resultJSON
            action.errorMessage = errorMessage
            action.updatedAt = Date().timeIntervalSince1970
            try action.update(db)
        }
    }

    private func migrateLegacyJSONIfNeeded() throws {
        try queue.write { db in
            let migrationKey = "legacy_json_import_v1"
            let existing = try String.fetchOne(
                db,
                sql: "SELECT value FROM schema_metadata WHERE key = ?",
                arguments: [migrationKey]
            )
            guard existing == nil else { return }

            if FileManager.default.fileExists(atPath: legacyJSONURL.path) {
                let data = try Data(contentsOf: legacyJSONURL)
                let snapshot = try JSONDecoder().decode(JotlyStoreSnapshot.self, from: data)
                try replaceCompatibilitySnapshot(snapshot, in: db)
            }

            try db.execute(
                sql: "INSERT INTO schema_metadata (key, value) VALUES (?, ?)",
                arguments: [migrationKey, "completed"]
            )
        }
    }

    private func replaceCompatibilitySnapshot(_ snapshot: JotlyStoreSnapshot, in db: Database) throws {
        try ShortcutOperationRecord.deleteAll(db)
        try ReminderTaskRecord.deleteAll(db)
        try BirthdayEventRecord.deleteAll(db)

        // Snapshot replacement updates the compatibility projection only. Raw events,
        // messages, runs, and memories remain durable even when their card disappears.
        let incomingCardIDs = Set(snapshot.cards.map(\.id))
        let existingCardIDs = try String.fetchAll(db, sql: "SELECT id FROM cards")
        for cardID in existingCardIDs where !incomingCardIDs.contains(cardID) {
            try CardRecord.deleteOne(db, key: cardID)
        }

        let cardsByID = Dictionary(uniqueKeysWithValues: snapshot.cards.map { ($0.id, $0) })
        for input in snapshot.rawInputs {
            if let card = cardsByID[input.linkedCardId] {
                try saveRawInput(input, card: card, in: db)
            } else {
                try upsertRawEvent(input, in: db)
            }
        }

        for card in snapshot.cards where !snapshot.rawInputs.contains(where: { $0.linkedCardId == card.id }) {
            let sourceRunID = try String.fetchOne(
                db,
                sql: "SELECT source_run_id FROM cards WHERE id = ?",
                arguments: [card.id]
            )
            try upsertCard(card, sourceRunID: sourceRunID, in: db)
        }
        for event in snapshot.birthdayEvents {
            try birthdayEventRecord(event).save(db)
        }
        for task in snapshot.reminderTasks {
            try reminderTaskRecord(task).save(db)
        }
        for operation in snapshot.shortcutOperations {
            try upsertShortcutOperation(operation, in: db)
        }
        try trimShortcutOperations(in: db)
    }

    private func saveRawInput(_ input: RawInput, card: MemoryCard, in db: Database) throws {
        let conversationID = "conversation_\(card.id)"
        let triggerMessageID = "message_\(input.id)"
        let runID = "run_\(card.id)"
        let timestamp = input.createdAt.timeIntervalSince1970

        try ConversationRecord(
            id: conversationID,
            title: card.title,
            createdAt: timestamp,
            updatedAt: card.updatedAt.timeIntervalSince1970
        ).save(db)
        try upsertRawEvent(input, conversationID: conversationID, in: db)
        try MessageRecord(
            id: triggerMessageID,
            conversationID: conversationID,
            role: "user",
            content: input.text,
            rawEventID: input.id,
            agentRunID: runID,
            createdAt: timestamp
        ).save(db)
        try AgentRunRecord(
            id: runID,
            triggerMessageID: triggerMessageID,
            status: Self.runStatus(for: card.status),
            needMemory: false,
            memoryQuery: nil,
            toolPlanJSON: card.toolPlan.flatMap { try? Self.encode($0) },
            errorMessage: nil,
            createdAt: timestamp,
            updatedAt: card.updatedAt.timeIntervalSince1970
        ).save(db)
        try upsertCard(card, sourceRunID: runID, in: db)
        try CardMessageLinkRecord(
            cardID: card.id,
            messageID: triggerMessageID,
            relationType: "trigger"
        ).save(db)
    }

    private func upsertRawEvent(
        _ input: RawInput,
        conversationID: String? = nil,
        in db: Database
    ) throws {
        try RawEventRecord(
            id: input.id,
            type: input.type,
            content: input.text,
            attachmentPathsJSON: nil,
            conversationID: conversationID,
            legacyCardID: input.linkedCardId,
            createdAt: input.createdAt.timeIntervalSince1970
        ).save(db)
    }

    private func upsertCard(_ card: MemoryCard, sourceRunID: String?, in db: Database) throws {
        try CardRecord(
            id: card.id,
            type: card.type,
            title: card.title,
            status: card.status.rawValue,
            contentJSON: Self.encode(card),
            sourceRunID: sourceRunID,
            createdAt: card.createdAt.timeIntervalSince1970,
            updatedAt: card.updatedAt.timeIntervalSince1970
        ).save(db)

        let conversationID = "conversation_\(card.id)"
        try ConversationRecord(
            id: conversationID,
            title: card.title,
            createdAt: card.createdAt.timeIntervalSince1970,
            updatedAt: card.updatedAt.timeIntervalSince1970
        ).save(db)

        for message in card.conversationMessages {
            try MessageRecord(
                id: message.id,
                conversationID: conversationID,
                role: message.role.rawValue,
                content: message.text,
                rawEventID: nil,
                agentRunID: sourceRunID,
                createdAt: message.createdAt.timeIntervalSince1970
            ).save(db)
            try CardMessageLinkRecord(
                cardID: card.id,
                messageID: message.id,
                relationType: message.role == .user ? "confirmation" : "response"
            ).save(db)
        }
    }

    private func upsertShortcutOperation(_ operation: ShortcutAnalysisOperation, in db: Database) throws {
        try ShortcutOperationRecord(
            id: operation.id,
            mode: operation.mode.rawValue,
            phase: operation.phase.rawValue,
            payloadJSON: Self.encode(operation),
            createdAt: operation.createdAt.timeIntervalSince1970,
            updatedAt: operation.updatedAt.timeIntervalSince1970
        ).save(db)
    }

    private func trimShortcutOperations(in db: Database) throws {
        try db.execute(
            sql: """
            DELETE FROM shortcut_operations
            WHERE id NOT IN (
                SELECT id FROM shortcut_operations
                ORDER BY updated_at DESC
                LIMIT 40
            )
            """
        )
    }

    private func birthdayEventRecord(_ event: BirthdayEvent) throws -> BirthdayEventRecord {
        BirthdayEventRecord(
            id: event.id,
            cardID: event.cardId,
            payloadJSON: try Self.encode(event),
            createdAt: event.createdAt.timeIntervalSince1970
        )
    }

    private func reminderTaskRecord(_ task: ReminderTask) throws -> ReminderTaskRecord {
        ReminderTaskRecord(
            id: task.id,
            cardID: task.cardId,
            birthdayEventID: task.birthdayEventId,
            payloadJSON: try Self.encode(task),
            createdAt: Date().timeIntervalSince1970
        )
    }

    private static func runStatus(for cardStatus: CardStatus) -> String {
        switch cardStatus {
        case .idle:
            "idle"
        case .processing, .executing:
            "running"
        case .waitingConfirmation:
            "waiting_confirmation"
        case .completed:
            "completed"
        case .failed:
            "failed"
        }
    }

    private static func ftsQuery(from query: String) -> String? {
        let rawTerms = query
            .split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
            .map(String.init)
            .filter { $0.count >= 2 }
        var terms: [String] = []
        for term in rawTerms {
            let characters = Array(term)
            if characters.count >= 3,
               characters.contains(where: { $0.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) }) {
                for index in 0...(characters.count - 3) {
                    terms.append(String(characters[index...index + 2]))
                    if terms.count == 16 { break }
                }
            } else {
                terms.append(term)
            }
            if terms.count == 16 { break }
        }
        guard !terms.isEmpty else { return nil }
        return terms
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " OR ")
    }

    private static func memoryCandidate(from row: Row) -> MemorySearchCandidate? {
        guard let id: String = row["id"],
              let type: String = row["type"],
              let content: String = row["content"],
              let importance: Double = row["importance"],
              let confidence: Double = row["confidence"],
              let createdAt: Double = row["created_at"]
        else { return nil }
        let lexicalScore: Double = row["lexical_score"] ?? 0
        return MemorySearchCandidate(
            id: id,
            type: type,
            content: content,
            importance: importance,
            confidence: confidence,
            createdAt: createdAt,
            lexicalScore: lexicalScore,
            vectorScore: 0
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
