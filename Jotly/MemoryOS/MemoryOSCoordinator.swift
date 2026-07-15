import Foundation
import os

nonisolated struct RetrievedMemory: Sendable, Equatable {
    let id: String
    let type: String
    let content: String
    let createdAt: Date
    let relevanceScore: Double
}

nonisolated struct MemoryRetrievalResult: Sendable, Equatable {
    let query: String
    let memories: [RetrievedMemory]
    let usedVectorSearch: Bool
    let usedRerank: Bool

    var memoryIDs: [String] { memories.map(\.id) }

    var promptContext: String {
        guard !memories.isEmpty else {
            return """
            [MEMORY_RETRIEVAL_RESULTS]
            memory_retrieval_completed: true
            没有检索到足以回答问题的已保存记忆。请明确告诉用户目前没有找到相关记忆，不要编造。
            """
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = memories.enumerated().map { index, memory in
            "\(index + 1). [memory_id=\(memory.id)] [\(memory.type)] [\(formatter.string(from: memory.createdAt))] \(memory.content)"
        }
        return """
        [MEMORY_RETRIEVAL_RESULTS]
        memory_retrieval_completed: true
        以下内容来自用户自己的本地记忆库。只能依据这些记忆回答；如果证据不足，要直接说明没有找到，不得补造事实。
        \(rows.joined(separator: "\n"))
        """
    }
}

nonisolated struct MemoryModelClient: Sendable {
    static let embeddingModel = "text-embedding-v4"
    static let embeddingDimensions = 256
    static let rerankModel = "qwen3-vl-rerank"

    private let embeddingEndpoint = URL(
        string: "https://llm-kxzzc9bbhvuvw4e9.cn-beijing.maas.aliyuncs.com/api/v1/services/embeddings/text-embedding/text-embedding"
    )!
    private let rerankEndpoint = URL(
        string: "https://llm-kxzzc9bbhvuvw4e9.cn-beijing.maas.aliyuncs.com/api/v1/services/rerank/text-rerank/text-rerank"
    )!

    func embedding(for text: String, textType: String) async throws -> [Float] {
        var request = URLRequest(url: embeddingEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            EmbeddingRequest(
                model: Self.embeddingModel,
                input: .init(texts: [String(text.prefix(12_000))]),
                parameters: .init(
                    textType: textType,
                    dimension: Self.embeddingDimensions,
                    outputType: "dense"
                )
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        guard let vector = envelope.output.embeddings.first?.embedding,
              vector.count == Self.embeddingDimensions
        else {
            throw MemoryOSError.invalidEmbeddingResponse
        }
        return vector
    }

    func rerank(query: String, documents: [String], topN: Int) async throws -> [(index: Int, score: Double)] {
        guard !documents.isEmpty else { return [] }
        var request = URLRequest(url: rerankEndpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(
            RerankRequest(
                model: Self.rerankModel,
                input: .init(query: String(query.prefix(8_000)), documents: documents.map { String($0.prefix(8_000)) }),
                parameters: .init(returnDocuments: false, topN: min(topN, documents.count))
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.validate(response: response, data: data)
        let envelope = try JSONDecoder().decode(RerankResponse.self, from: data)
        return envelope.output.results.map { ($0.index, $0.relevanceScore) }
    }

    private var apiKey: String {
        UserDefaults.standard.string(forKey: "memory_dashscope_api_key")
            ?? JotlySecrets.dashScopeAPIKey
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode)
        else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(decoding: data.prefix(600), as: UTF8.self)
            throw MemoryOSError.httpError(status, detail)
        }
    }
}

actor MemoryOSCoordinator {
    static let shared = MemoryOSCoordinator()

    private let database: JotlyDatabase?
    private let modelClient = MemoryModelClient()
    private var indexingMemoryIDs: Set<String> = []

    init() {
        database = JotlyDatabaseProvider.shared()
    }

    func resumePendingIndexing() async {
        if let counts = try? database?.memoryEmbeddingStatusCounts() {
            await MainActor.run {
                JotlyLog.storage.info("Memory embedding states: \(String(describing: counts), privacy: .public)")
            }
        }
        guard let ids = try? database?.pendingMemoryIDs(limit: 30) else { return }
        for id in ids {
            Task { await self.indexMemory(id: id) }
        }
    }

    func ingest(_ memories: [AgentMemoryToSave], linkedCardID: String) async {
        guard let database, !memories.isEmpty else { return }
        var seen: Set<String> = []
        for memory in memories {
            let content = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let dedupKey = "\(memory.type)|\(content)".lowercased()
            guard seen.insert(dedupKey).inserted else { continue }
            let now = Date().timeIntervalSince1970
            let id = "memory_\(UUID().uuidString)"
            do {
                let persistedID = try database.saveMemoryItem(
                    MemoryItemRecord(
                        id: id,
                        type: memory.type,
                        content: content,
                        structuredDataJSON: nil,
                        importance: 0.5,
                        confidence: 1.0,
                        status: "active",
                        sourceEventID: nil,
                        sourceMessageID: nil,
                        embeddingStatus: "pending",
                        createdAt: now,
                        updatedAt: now
                    ),
                    linkedCardID: linkedCardID
                )
                Task { await self.indexMemory(id: persistedID) }
            } catch {
                await MainActor.run {
                    JotlyLog.storage.error("Memory background save failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    func indexMemory(id: String) async {
        guard let database, !indexingMemoryIDs.contains(id) else { return }
        guard let memory = try? database.memoryItem(id: id),
              memory.status == "active",
              memory.embeddingStatus == "pending" || memory.embeddingStatus == "failed" || memory.embeddingStatus == "running"
        else { return }

        indexingMemoryIDs.insert(id)
        defer { indexingMemoryIDs.remove(id) }
        do {
            try database.markMemoryEmbeddingRunning(id: id)
            let vector = try await modelClient.embedding(for: memory.content, textType: "document")
            try database.saveMemoryEmbedding(
                memoryID: id,
                model: MemoryModelClient.embeddingModel,
                dimensions: MemoryModelClient.embeddingDimensions,
                vectorBlob: Self.encodeVector(vector)
            )
        } catch {
            try? database.markMemoryEmbeddingFailed(id: id, error: error.localizedDescription)
            await MainActor.run {
                JotlyLog.storage.warning("Memory embedding failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func retrieve(query rawQuery: String, limit: Int = 6) async -> MemoryRetrievalResult {
        let startedAt = Date()
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let database, !query.isEmpty else {
            return MemoryRetrievalResult(query: query, memories: [], usedVectorSearch: false, usedRerank: false)
        }

        var merged: [String: MemorySearchCandidate] = [:]
        let lexical = (try? database.lexicalMemoryCandidates(query: query, limit: 30)) ?? []
        for candidate in lexical { merged[candidate.id] = candidate }

        var usedVectorSearch = false
        if let queryVector = try? await modelClient.embedding(for: query, textType: "query"),
           let vectorRows = try? database.vectorMemories(
               model: MemoryModelClient.embeddingModel,
               dimensions: MemoryModelClient.embeddingDimensions
           ) {
            usedVectorSearch = true
            let vectorCandidates = vectorRows.compactMap { row -> MemorySearchCandidate? in
                guard let vector = Self.decodeVector(row.vectorBlob, dimensions: row.dimensions) else { return nil }
                var candidate = row.memory
                candidate.vectorScore = Self.cosineSimilarity(queryVector, vector)
                return candidate
            }
            .filter { $0.vectorScore > 0.15 }
            .sorted { $0.vectorScore > $1.vectorScore }
            .prefix(30)

            for candidate in vectorCandidates {
                if var existing = merged[candidate.id] {
                    existing.vectorScore = candidate.vectorScore
                    merged[candidate.id] = existing
                } else {
                    merged[candidate.id] = candidate
                }
            }
        }

        let candidates = merged.values
            .sorted { lhs, rhs in
                let left = max(lhs.lexicalScore, lhs.vectorScore) + lhs.importance * 0.05
                let right = max(rhs.lexicalScore, rhs.vectorScore) + rhs.importance * 0.05
                return left > right
            }
            .prefix(40)
            .map { $0 }

        guard !candidates.isEmpty else {
            return MemoryRetrievalResult(query: query, memories: [], usedVectorSearch: usedVectorSearch, usedRerank: false)
        }

        var ranked: [(candidate: MemorySearchCandidate, score: Double)] = []
        var usedRerank = false
        if let reranked = try? await modelClient.rerank(
            query: query,
            documents: candidates.map(\.content),
            topN: min(limit, candidates.count)
        ) {
            usedRerank = true
            ranked = reranked.compactMap { result in
                guard candidates.indices.contains(result.index), result.score >= 0.08 else { return nil }
                return (candidates[result.index], result.score)
            }
        }

        if ranked.isEmpty {
            ranked = candidates.prefix(limit).map { candidate in
                (candidate, max(candidate.lexicalScore, candidate.vectorScore))
            }
        }

        let memories = ranked.prefix(limit).map { item in
            RetrievedMemory(
                id: item.candidate.id,
                type: item.candidate.type,
                content: item.candidate.content,
                createdAt: Date(timeIntervalSince1970: item.candidate.createdAt),
                relevanceScore: item.score
            )
        }
        let result = MemoryRetrievalResult(
            query: query,
            memories: memories,
            usedVectorSearch: usedVectorSearch,
            usedRerank: usedRerank
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        await MainActor.run {
            JotlyLog.storage.info(
                "Memory retrieval: results=\(result.memories.count, privacy: .public), vector=\(result.usedVectorSearch, privacy: .public), rerank=\(result.usedRerank, privacy: .public), elapsed=\(elapsed, privacy: .public)s"
            )
        }
        return result
    }

    private static func encodeVector(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decodeVector(_ data: Data, dimensions: Int) -> [Float]? {
        guard data.count == dimensions * MemoryLayout<Float>.size else { return nil }
        return data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Float.self))
        }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Double = 0
        var leftNorm: Double = 0
        var rightNorm: Double = 0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            dot += left * right
            leftNorm += left * left
            rightNorm += right * right
        }
        guard leftNorm > 0, rightNorm > 0 else { return 0 }
        return dot / (sqrt(leftNorm) * sqrt(rightNorm))
    }
}

nonisolated enum MemoryOSError: LocalizedError {
    case invalidEmbeddingResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEmbeddingResponse:
            "向量模型返回格式异常"
        case .httpError(let status, let detail):
            "记忆模型请求失败（HTTP \(status)）：\(detail)"
        }
    }
}

nonisolated private struct EmbeddingRequest: Encodable {
    let model: String
    let input: Input
    let parameters: Parameters

    struct Input: Encodable { let texts: [String] }
    struct Parameters: Encodable {
        let textType: String
        let dimension: Int
        let outputType: String

        enum CodingKeys: String, CodingKey {
            case textType = "text_type"
            case dimension
            case outputType = "output_type"
        }
    }
}

nonisolated private struct EmbeddingResponse: Decodable {
    let output: Output
    struct Output: Decodable { let embeddings: [Item] }
    struct Item: Decodable { let embedding: [Float] }
}

nonisolated private struct RerankRequest: Encodable {
    let model: String
    let input: Input
    let parameters: Parameters

    struct Input: Encodable {
        let query: String
        let documents: [String]
    }

    struct Parameters: Encodable {
        let returnDocuments: Bool
        let topN: Int

        enum CodingKeys: String, CodingKey {
            case returnDocuments = "return_documents"
            case topN = "top_n"
        }
    }
}

nonisolated private struct RerankResponse: Decodable {
    let output: Output
    struct Output: Decodable { let results: [Item] }
    struct Item: Decodable {
        let index: Int
        let relevanceScore: Double

        enum CodingKeys: String, CodingKey {
            case index
            case relevanceScore = "relevance_score"
        }
    }
}
