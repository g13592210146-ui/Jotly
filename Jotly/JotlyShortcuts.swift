import AppIntents
import Combine
import Foundation
import os
import SwiftUI
import UniformTypeIdentifiers
import _AppIntents_SwiftUI

extension Notification.Name {
    static let jotlyStoreDidChange = Notification.Name("jotlyStoreDidChange")
}

@MainActor
final class ShortcutAnalysisSnippetStore: ObservableObject {
    static let shared = ShortcutAnalysisSnippetStore()

    @Published private(set) var operation: ShortcutAnalysisOperation?

    private var activeTask: Task<Void, Never>?

    private let store = LocalStore()
    private let analysisService = ShortcutAnalysisService.shared

    init() {
        refreshOperation()
    }

    func refreshOperation() {
        operation = try? store.latestShortcutOperation()
    }

    func startScreenshotAnalysis(loadImageData: @escaping () async throws -> Data) -> ShortcutAnalysisOperation {
        return start(mode: .screenshot) { [analysisService] operationId in
            let imageData = try await loadImageData()
            return try await analysisService.processScreenshot(imageData, operationId: operationId)
        }
    }

    func startVoiceAnalysis(text: String) -> ShortcutAnalysisOperation {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return start(mode: .voice) { [analysisService] operationId in
            try await analysisService.processVoice(trimmed, operationId: operationId)
        }
    }

    func requestCancellation(operationId: String) {
        activeTask?.cancel()
        do {
            _ = try store.updateShortcutOperation(id: operationId) { operation in
                operation.phase = .cancelled
                operation.cancelRequested = true
                operation.openAppRequested = false
                operation.resultTitle = "已取消"
                operation.resultSummary = "本次分析已取消"
                operation.resultMessage = "你已取消这次快捷分析。"
            }
        } catch {
            JotlyLog.storage.warning("cancel shortcut operation failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshOperation()
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
        reloadStatusSnippetIfAvailable()
    }

    func requestOpenResult(operationId: String) {
        do {
            _ = try store.updateShortcutOperation(id: operationId) { operation in
                operation.openAppRequested = true
            }
        } catch {
            JotlyLog.storage.warning("open shortcut result failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshOperation()
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
        reloadStatusSnippetIfAvailable()
    }

    private func start(
        mode: ShortcutAnalysisMode,
        work: @escaping (String) async throws -> ShortcutAnalysisOutcome
    ) -> ShortcutAnalysisOperation {
        if let latest = try? store.latestShortcutOperation(),
           latest.mode == mode,
           Date().timeIntervalSince(latest.createdAt) < 20 {
            operation = latest
            return latest
        }

        activeTask?.cancel()

        let operationId = "shortcut_\(UUID().uuidString)"
        let now = Date()
        let createdOperation = ShortcutAnalysisOperation(
            id: operationId,
            mode: mode,
            createdAt: now,
            updatedAt: now,
            phase: .processing,
            resultCardId: nil,
            resultTitle: nil,
            resultSummary: nil,
            resultMessage: nil,
            cancelRequested: false,
            openAppRequested: false
        )

        do {
            try store.upsertShortcutOperation(createdOperation)
        } catch {
            JotlyLog.storage.warning("create shortcut operation failed: \(error.localizedDescription, privacy: .public)")
        }
        operation = createdOperation
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)

        activeTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
                let outcome = try await work(operationId)
                try Task.checkCancellation()
                await MainActor.run {
                    self.applySuccess(operationId: operationId, outcome: outcome)
                }
            } catch is CancellationError {
                await MainActor.run {
                    if self.isExplicitlyCancelled(operationId: operationId) {
                        self.applyCancellation(operationId: operationId)
                    } else {
                        self.applyInterruptionIfLatest(operationId: operationId)
                    }
                }
            } catch {
                await MainActor.run {
                    self.applyFailure(operationId: operationId, error: error)
                }
            }
            await MainActor.run {
                self.activeTask = nil
            }
        }

        return createdOperation
    }

    private func applySuccess(operationId: String, outcome: ShortcutAnalysisOutcome) {
        do {
            _ = try store.updateShortcutOperation(id: operationId) { operation in
                operation.phase = .completed
                operation.resultCardId = outcome.card.id
                operation.resultTitle = outcome.card.title
                operation.resultSummary = outcome.card.summary.isEmpty ? outcome.card.message : outcome.card.summary
                operation.resultMessage = outcome.card.completionMessage ?? outcome.card.message
            }
        } catch {
            JotlyLog.storage.warning("update shortcut success state failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshOperation()
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
        reloadStatusSnippetIfAvailable()
    }

    private func applyCancellation(operationId: String) {
        do {
            _ = try store.updateShortcutOperation(id: operationId) { operation in
                operation.phase = .cancelled
                operation.cancelRequested = true
                operation.resultTitle = "已取消"
                operation.resultSummary = "本次分析已取消"
                operation.resultMessage = "你已取消这次快捷分析。"
            }
        } catch {
            JotlyLog.storage.warning("update shortcut cancel state failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshOperation()
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
        reloadStatusSnippetIfAvailable()
    }

    private func isExplicitlyCancelled(operationId: String) -> Bool {
        guard let operation = try? store.shortcutOperation(id: operationId) else { return false }
        return operation.cancelRequested || operation.phase == .cancelled
    }

    private func applyInterruptionIfLatest(operationId: String) {
        guard (try? store.latestShortcutOperation()?.id) == operationId else { return }
        do {
            _ = try store.updateShortcutOperation(id: operationId) { operation in
                operation.phase = .failed
                operation.resultTitle = "处理被中断"
                operation.resultSummary = "请重新运行快捷指令"
                operation.resultMessage = "系统中断了这次快捷分析，不是你手动取消。"
            }
        } catch {
            JotlyLog.storage.warning("update shortcut interruption state failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshOperation()
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
        reloadStatusSnippetIfAvailable()
    }

    private func applyFailure(operationId: String, error: Error) {
        do {
            _ = try store.updateShortcutOperation(id: operationId) { operation in
                operation.phase = .failed
                operation.resultTitle = "识别失败"
                operation.resultSummary = "请稍后重试"
                operation.resultMessage = error.localizedDescription
            }
        } catch {
            JotlyLog.storage.warning("update shortcut failure state failed: \(error.localizedDescription, privacy: .public)")
        }
        refreshOperation()
        NotificationCenter.default.post(name: .jotlyStoreDidChange, object: nil)
        reloadStatusSnippetIfAvailable()
    }

    private func reloadStatusSnippetIfAvailable() {
        if #available(iOS 26.0, *) {
            ShortcutAnalysisStatusIntent.reload()
        }
    }
}

struct ShortcutAnalysisSnippetView: View {
    private let operation: ShortcutAnalysisOperation

    init(operation: ShortcutAnalysisOperation) {
        self.operation = operation
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header(for: operation)
            bodyContent(for: operation)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
    }

    private func header(for operation: ShortcutAnalysisOperation) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.blue.opacity(0.18))
                .frame(width: 20, height: 20)
                .overlay(
                    Text("J")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                )
            Text("Jotly | \(operation.mode.title)")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func bodyContent(for operation: ShortcutAnalysisOperation) -> some View {
        switch operation.phase {
        case .pending, .processing:
            Text(operation.mode == .screenshot ? "正在分析图片" : "正在分析")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text("点完成可后台处理，回到 Jotly 查看结果。")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        case .completed:
            Text("已完成")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            Text(displaySummary(for: operation))
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled, .failed:
            if let title = operation.resultTitle, !title.isEmpty {
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            if let summary = operation.resultSummary, !summary.isEmpty {
                Text(summary)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            if let message = operation.resultMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func displaySummary(for operation: ShortcutAnalysisOperation) -> String {
        let candidates = [
            operation.resultMessage,
            operation.resultSummary,
            operation.resultTitle
        ]
        for candidate in candidates {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                return String(trimmed.prefix(96))
            }
        }
        return "结果已生成，回到 Jotly 查看详情。"
    }
}

@available(iOS 26.0, *)
public struct ShortcutAnalysisStatusIntent: SnippetIntent {
    public static var title: LocalizedStringResource = "快捷分析状态"
    public static var description = IntentDescription("显示当前快捷分析的处理状态和结果。")
    public static var openAppWhenRun = false
    public static var isDiscoverable = false

    @Parameter(title: "操作 ID")
    public var operationId: String

    public init() {
        self.operationId = ""
    }

    public init(operationId: String) {
        self.operationId = operationId
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("显示快捷分析状态")
    }

    public func perform() async throws -> some ShowsSnippetView {
        let store = await MainActor.run { LocalStore() }
        let operation = try await MainActor.run {
            try store.shortcutOperation(id: operationId)
                ?? ShortcutAnalysisOperation(
                    id: operationId,
                    mode: .screenshot,
                    createdAt: Date(),
                    updatedAt: Date(),
                    phase: .failed,
                    resultCardId: nil,
                    resultTitle: "处理失败",
                    resultSummary: "没有找到这次快捷分析",
                    resultMessage: "请回到 Jotly 查看结果。",
                    cancelRequested: false,
                    openAppRequested: false
                )
        }
        let view = await MainActor.run { ShortcutAnalysisSnippetView(operation: operation) }
        return .result(view: view)
    }
}

@available(iOS 26.0, *)
public struct AnalyzeScreenshotIntent: AppIntent {
    public static var title: LocalizedStringResource = "截图"
    public static var description = IntentDescription("把一张截图送进当前选中的模型图片链路里分析。")
    public static var openAppWhenRun = false
    public static var isDiscoverable = true

    @Parameter(title: "截图", default: IntentFile(data: Data(), filename: "screenshot.png", type: .image), supportedContentTypes: [UTType.image, UTType.png, UTType.jpeg, UTType.heic])
    public var screenshot: IntentFile

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("分析 \(\.$screenshot)")
    }

    public func perform() async throws -> some ShowsSnippetIntent {
        let file = screenshot
        let operation = await ShortcutAnalysisSnippetStore.shared.startScreenshotAnalysis {
            try await Self.loadImageData(from: file)
        }
        return .result(snippetIntent: ShortcutAnalysisStatusIntent(operationId: operation.id))
    }

    private static func loadImageData(from file: IntentFile) async throws -> Data {
        if !file.data.isEmpty {
            return file.data
        }

        var contentTypes = file.availableContentTypes
        contentTypes.append(contentsOf: [.image, .png, .jpeg, .heic])
        var seen = Set<UTType>()
        var lastError: Error?
        for contentType in contentTypes where seen.insert(contentType).inserted {
            do {
                return try await file.data(contentType: contentType)
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }
        throw JotlyError.invalidToolParameters("图片读取失败。")
    }
}

@available(iOS 26.0, *)
public struct StartVoiceCaptureIntent: AppIntent {
    public static var title: LocalizedStringResource = "语音"
    public static var description = IntentDescription("把听写出来的文本送进当前记账流程。")
    public static var openAppWhenRun = false
    public static var isDiscoverable = true

    @Parameter(title: "听写文本", default: "")
    public var dictatedText: String

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("处理语音 \(\.$dictatedText)")
    }

    public func perform() async throws -> some ShowsSnippetIntent {
        let operation = await ShortcutAnalysisSnippetStore.shared.startVoiceAnalysis(text: dictatedText)
        return .result(snippetIntent: ShortcutAnalysisStatusIntent(operationId: operation.id))
    }
}

public struct CancelShortcutAnalysisIntent: AppIntent {
    public static var title: LocalizedStringResource = "取消快捷分析"
    public static var description = IntentDescription("取消当前截图或语音分析。")
    public static var openAppWhenRun = false
    public static var isDiscoverable = false

    @Parameter(title: "操作 ID")
    public var operationId: String

    public init() {
        self.operationId = ""
    }

    public init(operationId: String) {
        self.operationId = operationId
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("取消 \(\.$operationId)")
    }

    public func perform() async throws -> some IntentResult {
        await ShortcutAnalysisSnippetStore.shared.requestCancellation(operationId: operationId)
        return .result()
    }
}

public struct OpenShortcutResultIntent: AppIntent {
    public static var title: LocalizedStringResource = "打开结果"
    public static var description = IntentDescription("打开 Jotly 查看这次快捷分析结果。")
    public static var openAppWhenRun = true
    public static var isDiscoverable = false

    @Parameter(title: "操作 ID")
    public var operationId: String

    public init() {
        self.operationId = ""
    }

    public init(operationId: String) {
        self.operationId = operationId
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("打开结果 \(\.$operationId)")
    }

    public func perform() async throws -> some IntentResult {
        await ShortcutAnalysisSnippetStore.shared.requestOpenResult(operationId: operationId)
        return .result()
    }
}

@available(iOS 26.0, *)
public struct JotlyAppShortcutsProvider: AppShortcutsProvider {
    @AppIntents.AppShortcutsBuilder
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AnalyzeScreenshotIntent(),
            phrases: [
                "在 \(.applicationName) 中截图",
                "用 \(.applicationName) 分析截图",
                "让 \(.applicationName) 识别图片"
            ],
            shortTitle: "截图",
            systemImageName: "camera.viewfinder"
        )
        AppShortcut(
            intent: StartVoiceCaptureIntent(),
            phrases: [
                "在 \(.applicationName) 中语音",
                "用 \(.applicationName) 记语音",
                "让 \(.applicationName) 开始录音"
            ],
            shortTitle: "语音",
            systemImageName: "mic.fill"
        )
    }
}
