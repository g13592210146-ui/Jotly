import Foundation
import os

@MainActor
final class LocalStore {
    private let legacyFileURL: URL
    private let customFileURL: URL?
    private lazy var database: JotlyDatabase? = JotlyDatabaseProvider.shared(fileURL: customFileURL)
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cachedSnapshot: JotlyStoreSnapshot?

    init(fileURL: URL? = nil) {
        let baseURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let resolvedFileURL = fileURL ?? baseURL.appendingPathComponent("jotly_store.json")
        self.legacyFileURL = resolvedFileURL
        self.customFileURL = fileURL

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    nonisolated static func loadSnapshotFromDisk(cardLimit: Int? = nil) -> JotlyStoreSnapshot? {
        let urls = JotlyDatabase.defaultURLs()
        if let database = JotlyDatabaseProvider.shared(),
           let snapshot = try? database.loadSnapshot(cardLimit: cardLimit) {
            return snapshot
        }
        guard FileManager.default.fileExists(atPath: urls.legacyJSON.path),
              let data = try? Data(contentsOf: urls.legacyJSON)
        else {
            return JotlyStoreSnapshot()
        }
        return try? JSONDecoder().decode(JotlyStoreSnapshot.self, from: data)
    }

    nonisolated static func loadCardsFromDisk(limit: Int, offset: Int) -> [MemoryCard] {
        (try? JotlyDatabaseProvider.shared()?.loadCards(limit: limit, offset: offset)) ?? []
    }

    func load() throws -> JotlyStoreSnapshot {
        if let cachedSnapshot {
            return cachedSnapshot
        }
        if let database {
            let snapshot = try database.loadSnapshot()
            cachedSnapshot = snapshot
            return snapshot
        }
        guard FileManager.default.fileExists(atPath: legacyFileURL.path) else {
            let snapshot = JotlyStoreSnapshot()
            cachedSnapshot = snapshot
            return snapshot
        }
        let data = try Data(contentsOf: legacyFileURL)
        let snapshot = try decoder.decode(JotlyStoreSnapshot.self, from: data)
        cachedSnapshot = snapshot
        return snapshot
    }

    func invalidateCache() {
        cachedSnapshot = nil
    }

    func cardExists(id: String) -> Bool {
        (try? database?.cardExists(id: id)) ?? false
    }

    func replaceCachedSnapshot(_ snapshot: JotlyStoreSnapshot) {
        cachedSnapshot = snapshot
    }

    func saveRawInput(_ input: RawInput, card: MemoryCard) throws {
        if let database {
            try database.saveRawInput(input, card: card)
            cachedSnapshot = nil
            return
        }
        var snapshot = try load()
        snapshot.rawInputs.append(input)
        upsert(card: card, in: &snapshot)
        try saveLegacy(snapshot)
    }

    func upsertCard(_ card: MemoryCard) throws {
        if let database {
            try database.upsertCard(card)
            cachedSnapshot = nil
            return
        }
        var snapshot = try load()
        upsert(card: card, in: &snapshot)
        try saveLegacy(snapshot)
    }

    func loadDebugTurns() -> [AgentDebugTurn] {
        (try? database?.loadDebugTurns()) ?? []
    }

    func upsertDebugTurn(_ turn: AgentDebugTurn) {
        try? database?.upsertDebugTurn(turn)
    }

    func upsertAssets(_ records: [AssetRecord]) throws {
        guard let database else { return }
        try database.upsertAssets(records)
    }

    func upsertSubscription(_ record: SubscriptionRecord) throws {
        guard let database else { return }
        try database.upsertSubscription(record)
    }

    func shortcutOperation(id: String) throws -> ShortcutAnalysisOperation? {
        if let database {
            return try database.shortcutOperation(id: id)
        }
        let snapshot = try load()
        return snapshot.shortcutOperations.first { $0.id == id }
    }

    func latestShortcutOperation() throws -> ShortcutAnalysisOperation? {
        if let database {
            return try database.latestShortcutOperation()
        }
        let snapshot = try load()
        return snapshot.shortcutOperations.sorted { $0.updatedAt > $1.updatedAt }.first
    }

    func upsertShortcutOperation(_ operation: ShortcutAnalysisOperation) throws {
        if let database {
            try database.upsertShortcutOperation(operation)
            cachedSnapshot = nil
            return
        }
        var snapshot = try load()
        if let index = snapshot.shortcutOperations.firstIndex(where: { $0.id == operation.id }) {
            snapshot.shortcutOperations[index] = operation
        } else {
            snapshot.shortcutOperations.append(operation)
        }
        trimShortcutOperations(in: &snapshot)
        try saveLegacy(snapshot)
    }

    @discardableResult
    func updateShortcutOperation(id: String, _ update: (inout ShortcutAnalysisOperation) -> Void) throws -> ShortcutAnalysisOperation? {
        if let database {
            let operation = try database.updateShortcutOperation(id: id, update: update)
            cachedSnapshot = nil
            return operation
        }
        var snapshot = try load()
        guard let index = snapshot.shortcutOperations.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        var operation = snapshot.shortcutOperations[index]
        update(&operation)
        operation.updatedAt = Date()
        snapshot.shortcutOperations[index] = operation
        trimShortcutOperations(in: &snapshot)
        try saveLegacy(snapshot)
        return operation
    }

    func saveSnapshot(_ snapshot: JotlyStoreSnapshot) throws {
        if let database {
            try database.replaceSnapshot(snapshot)
            cachedSnapshot = nil
            return
        }
        try saveLegacy(snapshot)
    }

    func appendBirthdayEvent(_ event: BirthdayEvent, reminderTask: ReminderTask?) throws {
        if let database {
            try database.appendBirthdayEvent(event, reminderTask: reminderTask)
            cachedSnapshot = nil
            return
        }
        var snapshot = try load()
        snapshot.birthdayEvents.append(event)
        if let reminderTask {
            snapshot.reminderTasks.append(reminderTask)
        }
        let reminderState = reminderTask == nil ? "none" : "present"
        JotlyLog.storage.info("appendBirthdayEvent eventId=\(event.id, privacy: .public), reminderTask=\(reminderState, privacy: .public)")
        try saveLegacy(snapshot)
    }

    private func upsert(card: MemoryCard, in snapshot: inout JotlyStoreSnapshot) {
        if let index = snapshot.cards.firstIndex(where: { $0.id == card.id }) {
            snapshot.cards[index] = card
        } else {
            snapshot.cards.append(card)
        }
    }

    private func trimShortcutOperations(in snapshot: inout JotlyStoreSnapshot) {
        let limit = 40
        guard snapshot.shortcutOperations.count > limit else { return }
        snapshot.shortcutOperations = Array(
            snapshot.shortcutOperations
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(limit)
        )
    }

    private func saveLegacy(_ snapshot: JotlyStoreSnapshot) throws {
        cachedSnapshot = snapshot
        let data = try encoder.encode(snapshot)
        try data.write(to: legacyFileURL, options: [.atomic])
    }

    func deleteCard(id: String) throws {
        try deleteCards(ids: [id])
    }

    func deleteCards(ids: some Sequence<String>) throws {
        let idsToDelete = Set(ids)
        guard !idsToDelete.isEmpty else { return }

        if let database {
            try database.deleteCards(ids: idsToDelete)
            cachedSnapshot = nil
            return
        }

        var snapshot = try load()
        let eventsToDelete = snapshot.birthdayEvents.filter { idsToDelete.contains($0.cardId) }
        let eventIds = Set(eventsToDelete.map { $0.id })
        snapshot.reminderTasks.removeAll { eventIds.contains($0.birthdayEventId) || idsToDelete.contains($0.cardId) }
        snapshot.birthdayEvents.removeAll { idsToDelete.contains($0.cardId) }
        snapshot.rawInputs.removeAll { idsToDelete.contains($0.linkedCardId) }
        snapshot.cards.removeAll { idsToDelete.contains($0.id) }
        try saveLegacy(snapshot)
    }

    @discardableResult
    func saveMemoryItem(_ memory: MemoryItemRecord, linkedCardID: String?) throws -> String? {
        guard let database else { return nil }
        return try database.saveMemoryItem(memory, linkedCardID: linkedCardID)
    }

    func updateAgentRunMemoryRequest(cardID: String, needMemory: Bool, query: String?) throws {
        try database?.updateAgentRunMemoryRequest(
            cardID: cardID,
            needMemory: needMemory,
            query: query
        )
    }

    func linkMemories(_ memoryIDs: [String], toCardID cardID: String) throws {
        try database?.linkMemories(memoryIDs, toCardID: cardID)
    }

    func createActionLog(cardID: String?, toolName: String, parametersJSON: Data?) throws -> String? {
        try database?.createActionLog(
            cardID: cardID,
            toolName: toolName,
            parametersJSON: parametersJSON
        )
    }

    func finishActionLog(id: String?, resultJSON: Data?, errorMessage: String?) throws {
        guard let database, let id else { return }
        try database.finishActionLog(id: id, resultJSON: resultJSON, errorMessage: errorMessage)
    }
}
