import Combine
import Foundation
import ImageIO
import UIKit
@preconcurrency import Vision
import os

@MainActor
final class JotlyHomeViewModel: ObservableObject {
    enum InputMode: String {
        case voice
        case handwriting
    }

    enum HomeDisplayMode: String, CaseIterable, Identifiable {
        case cards
        case conversation
        case flow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .cards:
                "卡片"
            case .conversation:
                "对话"
            case .flow:
                "流程"
            }
        }
    }

    enum ASRProvider: String, CaseIterable, Identifiable {
        case apple
        case mimo
        case doubao
        case aliyun

        var id: String { rawValue }

        var title: String {
            switch self {
            case .apple:
                "Apple"
            case .mimo:
                "MIMO"
            case .doubao:
                "豆包"
            case .aliyun:
                "阿里"
            }
        }
    }

    enum FilterCategory: String, CaseIterable, Identifiable {
        case all = "全部"
        case habit = "习惯打卡"
        case countdown = "正/倒数日"
        case subscription = "订阅"
        case asset = "资产"

        var id: String { rawValue }
    }

    enum VoiceReleaseAction: Equatable {
        case send
        case cancel
        case hold
        case edit
    }

    private enum VoiceCaptureDestination: Equatable {
        case composer
        case card(String)
    }

    private enum AgentProcessingStage: Equatable {
        case persistence
        case modelRequest
        case decode
        case cardUpdate

        var summary: String {
            switch self {
            case .persistence:
                "输入或结果保存失败"
            case .modelRequest:
                "模型请求失败"
            case .decode:
                "模型 JSON 解码失败"
            case .cardUpdate:
                "结果已解析，但卡片更新失败"
            }
        }

        func userMessage(for error: Error) -> String {
            switch self {
            case .decode:
                "模型返回格式异常，请查看调试输出。"
            case .persistence:
                "数据保存失败：\(error.localizedDescription)"
            case .modelRequest:
                error.localizedDescription
            case .cardUpdate:
                "结果已解析，但卡片更新失败：\(error.localizedDescription)"
            }
        }
    }

    enum VoiceCompletionResult: Equatable {
        case insertIntoTextField(String)
        case openFullEditor(String)
    }

    enum VoiceEditDestination: Equatable {
        case textField
        case fullEditor
    }

    @Published var inputMode: InputMode = .voice
    @Published var isRecording = false
    @Published var isVoiceCaptureActive = false
    @Published var liveTranscript = ""
    @Published var voiceReleaseAction: VoiceReleaseAction = .send
    @Published var draftText: String = ""
    @Published var editorText: String = ""
    @Published var textInputFocusToken = 0
    @Published var voiceDragTranslation: CGSize = .zero
    @Published var isVoiceHoldLocked = false
    @Published var voiceAmplitude: Float = 0.0
    @Published var statusText = "长按说话，松手后生成卡片"
    @Published var displayMode: HomeDisplayMode = .cards
    @Published var selectedCategory: FilterCategory = .all {
        didSet { rebuildDisplayedCards() }
    }
    @Published var cards: [MemoryCard] = [MemoryCard.idle()] {
        didSet { rebuildDisplayedCards() }
    }
    @Published private(set) var displayedCards: [MemoryCard] = [MemoryCard.idle()]

    private func rebuildDisplayedCards() {
        switch selectedCategory {
        case .all:
            let roots = cards.filter { $0.parentId == nil }
            if roots.isEmpty {
                displayedCards = cards
                return
            }
            displayedCards = roots
        case .habit:
            displayedCards = cards.filter { $0.type == "habit" }
        case .countdown:
            displayedCards = cards.filter { $0.type == "countdown" }
        case .subscription:
            displayedCards = cards.filter { $0.type == "subscription" }
        case .asset:
            displayedCards = cards.filter { $0.type == "asset" }
        }
    }

    @Published var debugTurns: [AgentDebugTurn] = []
    private let debugStore = JotlyDebugTurnStore.shared
    private var debugTurnsCancellable: AnyCancellable?
    @Published var asrProvider: ASRProvider = {
        if let saved = UserDefaults.standard.string(forKey: "selected_asr_provider"),
           let provider = ASRProvider(rawValue: saved) {
            return provider
        }
        return .mimo
    }() {
        didSet {
            UserDefaults.standard.set(asrProvider.rawValue, forKey: "selected_asr_provider")
        }
    }
    @Published var selectedAgentModel: LifeAgentLLMModel = {
        if let saved = UserDefaults.standard.string(forKey: "selected_agent_model"),
           let model = LifeAgentLLMModel(rawValue: saved) {
            return model
        }
        return .deepseekV4Pro
    }() {
        didSet {
            UserDefaults.standard.set(selectedAgentModel.rawValue, forKey: "selected_agent_model")
            enforceImageInputModeAvailability()
        }
    }
    @Published var imageInputMode: ImageInputMode = {
        if let saved = UserDefaults.standard.string(forKey: "selected_image_input_mode"),
           let mode = ImageInputMode(rawValue: saved) {
            return mode
        }
        return .ocr
    }() {
        didSet {
            UserDefaults.standard.set(imageInputMode.rawValue, forKey: "selected_image_input_mode")
        }
    }
    @Published private(set) var modelCostCNY: Double = UserDefaults.standard.double(forKey: "agent_model_total_cost_cny")
    @Published private(set) var lastModelUsageSummary: String = ""
    @Published var clarificationDraftText: String = ""
    @Published var activeClarificationCardID: String?

    @Published var isCameraAvailable = false

    private let appleSpeechService = SpeechService()
    private let mimoASRService = MimoASRService()
    private let doubaoASRService = DoubaoASRService()
    private let aliyunASRService = AliyunASRService()
    private let deepSeekClient = DeepSeekClient()
    private let store = LocalStore()
    private let birthdayExecutor = BirthdayToolExecutor()
    private let toolDispatcher = ToolDispatcher()
    private var pressArmed = false
    private var activeVoiceCaptureDestination: VoiceCaptureDestination?
    private var activeVoiceSessionID: UUID?
    private var terminatingVoiceSessionID: UUID?
    private var cancelledASRSessionID: UUID?
    private var voiceStartTask: Task<Void, Never>?
    private var voiceStopTask: Task<Void, Never>?
    private var storeReloadTask: Task<Void, Never>?
    private var cardPageLoadTask: Task<Void, Never>?
    private let cardPageSize = 30
    private var hasMorePersistedCards = true
    private var isCancellingASRService = false
    private var voiceStartedWithEmptyDraft = true
    private var pendingComposerVoiceImages: [UIImage]?
    private var confirmedLiveTranscript = ""
    private var currentLiveTranscript = ""
    private var editorLinkedDraftCard = false
    private var cancelledCardIDs = Set<String>()

    private let beginHapticGenerator = UIImpactFeedbackGenerator(style: .medium)
    private let selectionHapticGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private let releaseHapticGenerator = UIImpactFeedbackGenerator(style: .light)
    private let familyHolidayIntroKey = "jotly_family_holiday_intro_seen"
    private let holdHapticGenerator = UIImpactFeedbackGenerator(style: .rigid)

    init() {
        // 预热震动发生器
        beginHapticGenerator.prepare()
        selectionHapticGenerator.prepare()
        releaseHapticGenerator.prepare()
        holdHapticGenerator.prepare()
        debugTurns = debugStore.turns
        debugTurnsCancellable = debugStore.$turns.sink { [weak self] turns in
            self?.debugTurns = turns
        }

        // 后台检测相机可用性，避免点击时主线程检测卡顿
        Task { @MainActor [weak self] in
            let available = UIImagePickerController.isSourceTypeAvailable(.camera)
            self?.isCameraAvailable = available
        }

        // 监听系统中断与退后台通知，自动重置录制状态，防止误触或后台挂起死锁
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelVoiceCaptureOnInterrupt()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .jotlyStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleReloadState()
            }
        }

        Task { [weak self] in
            guard let self else { return }
            let startedAt = ContinuousClock.now
            let pageSize = self.cardPageSize
            let snapshot = await Task.detached(priority: .userInitiated) { [pageSize] in
                LocalStore.loadSnapshotFromDisk(cardLimit: pageSize)
            }.value
            if let snapshot, !snapshot.cards.isEmpty {
                let loadedCards = snapshot.cards.sorted { $0.updatedAt > $1.updatedAt }
                self.cards = loadedCards
                self.hasMorePersistedCards = loadedCards.count == self.cardPageSize
                JotlyLog.storage.info("Loaded \(loadedCards.count, privacy: .public) cards from local store")
                let elapsed = startedAt.duration(to: .now)
                JotlyLog.storage.info("Initial card page ready in \(String(describing: elapsed), privacy: .public)")
                self.scheduleLunarMaintenance()
            }
            ensureFamilyHolidayIntroCardIfNeeded()
        }

        Task {
            await MemoryOSCoordinator.shared.resumePendingIndexing()
        }
    }

    func loadMoreCardsIfNeeded(visibleCardID: String) {
        guard hasMorePersistedCards,
              cardPageLoadTask == nil,
              visibleCardID == displayedCards.last?.id
        else { return }
        let offset = cards.filter { $0.id != "card_idle" }.count
        let pageSize = cardPageSize
        cardPageLoadTask = Task { [weak self] in
            let page = await Task.detached(priority: .utility) {
                LocalStore.loadCardsFromDisk(limit: pageSize, offset: offset)
            }.value
            guard let self else { return }
            let existingIDs = Set(self.cards.map(\.id))
            let additions = page.filter { !existingIDs.contains($0.id) }
            if !additions.isEmpty {
                self.cards.append(contentsOf: additions)
            }
            self.hasMorePersistedCards = page.count == pageSize
            self.cardPageLoadTask = nil
        }
    }

    private func scheduleLunarMaintenance() {
        Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            let fullSnapshot = await Task.detached(priority: .background) {
                LocalStore.loadSnapshotFromDisk()
            }.value
            guard let fullSnapshot else { return }
            do {
                if let refreshedSnapshot = try await self.birthdayExecutor.refreshLunarDateSeries(in: fullSnapshot) {
                    try self.store.saveSnapshot(refreshedSnapshot)
                    self.scheduleReloadState()
                    JotlyLog.storage.info("Refreshed lunar date series in background")
                }
            } catch {
                JotlyLog.tool.warning("refresh lunar date series skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    var hasSavedDraftCard: Bool {
        cards.contains { $0.id == "card_draft" }
    }

    var activeCardVoiceCaptureCardID: String? {
        if case .card(let cardId)? = activeVoiceCaptureDestination {
            return cardId
        }
        return nil
    }

    var isComposerVoiceCaptureActive: Bool {
        isVoiceCaptureActive && activeVoiceCaptureDestination == .composer
    }

    var isImageVoiceCaptureActive: Bool {
        isComposerVoiceCaptureActive && pendingComposerVoiceImages != nil
    }

    var selectedModelPriceSummary: String {
        selectedAgentModel.priceSummary
    }

    var modelCostText: String {
        "已用 ¥\(String(format: "%.4f", modelCostCNY))"
    }

    var resolvedImageInputMode: ImageInputMode {
        selectedAgentModel.supportsDirectImageInput ? imageInputMode : .ocr
    }

    var imageInputModeSummary: String {
        if selectedAgentModel.supportsDirectImageInput {
            return imageInputMode.title
        }
        return "仅本地 OCR"
    }

    // MARK: - 输入模式切换

    private func startDebugTurn(cardId: String, userText: String) {
        debugStore.startTurn(cardId: cardId, userText: userText)
    }

    private func updateDebugTurn(
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
        debugStore.updateTurn(
            cardId: cardId,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            fullPrompt: fullPrompt,
            modelName: modelName,
            modelOutput: modelOutput,
            decodedSummary: decodedSummary,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            promptCacheHitTokens: promptCacheHitTokens,
            promptCacheMissTokens: promptCacheMissTokens,
            promptCacheCreationTokens: promptCacheCreationTokens,
            nodeId: nodeId,
            nodeState: nodeState,
            nodeDetail: nodeDetail
        )
    }

    private func updateDebugNode(cardId: String, nodeId: String, state: AgentDebugTurn.Node.State, detail: String) {
        debugStore.updateNode(cardId: cardId, nodeId: nodeId, state: state, detail: detail)
    }

    private func recordModelUsage(_ response: DeepSeekDebugResponse) {
        guard response.estimatedCostCNY > 0 else {
            lastModelUsageSummary = response.usage?.summaryText ?? ""
            return
        }
        modelCostCNY += response.estimatedCostCNY
        UserDefaults.standard.set(modelCostCNY, forKey: "agent_model_total_cost_cny")
        lastModelUsageSummary = response.usage?.summaryText ?? ""
    }

    private func decodedSummary(for response: DeepSeekDebugResponse, analysis: AgentAnalysis) -> String {
        let costText = response.estimatedCostCNY > 0
            ? ", cost≈¥\(String(format: "%.5f", response.estimatedCostCNY))"
            : ""
        return "model=\(response.modelName), intent=\(analysis.intent), type=\(analysis.cardType), confirmation=\(analysis.requiresConfirmation), action=\(analysis.recommendedActionValue ?? "nil")\(costText)"
    }

    private func rawModelOutput(from error: Error) -> String? {
        if case JotlyError.invalidDeepSeekResponseWithRaw(let raw) = error {
            return raw
        }
        return nil
    }

    private func modelFailureMessage(for error: Error) -> String {
        switch error {
        case JotlyError.invalidDeepSeekResponse, JotlyError.invalidDeepSeekResponseWithRaw:
            return "模型返回格式异常，请查看调试输出。"
        case JotlyError.missingDeepSeekContent:
            return "模型没有返回可解析内容，请稍后重试。"
        default:
            return error.localizedDescription
        }
    }

    private func isLoopCancelled(cardId: String) -> Bool {
        cancelledCardIDs.contains(cardId) || !cards.contains { $0.id == cardId }
    }

    private func ensureFamilyHolidayIntroCardIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: familyHolidayIntroKey) else { return }
        guard !cards.contains(where: { $0.id == "card_family_holiday_intro" }) else { return }
        guard !store.cardExists(id: "card_family_holiday_intro") else {
            UserDefaults.standard.set(true, forKey: familyHolidayIntroKey)
            return
        }

        var visibleCards = cards.filter { $0.id != "card_idle" }
        let card = MemoryCard.familyHolidayIntro()
        visibleCards.insert(card, at: 0)
        cards = visibleCards.isEmpty ? [card] : visibleCards
        try? store.upsertCard(card)
        UserDefaults.standard.set(true, forKey: familyHolidayIntroKey)
    }

    func toggleInputMode() {
        guard !isRecording else { return }
        if inputMode == .voice {
            activateTextInput()
        } else {
            activateVoiceInput()
        }
    }

    func activateTextInput(overwriting text: String? = nil) {
        guard !isRecording else { return }
        inputMode = .handwriting
        if let text = text {
            draftText = text
        }
        textInputFocusToken += 1
    }

    func activateVoiceInput() {
        inputMode = .voice
    }

    func setImageInputMode(_ mode: ImageInputMode) {
        guard selectedAgentModel.supportsDirectImageInput || mode == .ocr else {
            imageInputMode = .ocr
            statusText = "\(selectedAgentModel.title) 仅支持本地 OCR"
            return
        }
        imageInputMode = mode
    }

    func prepareEditor(with text: String, linkedDraftCard: Bool = false) {
        editorText = text
        editorLinkedDraftCard = linkedDraftCard
    }

    private func enforceImageInputModeAvailability() {
        guard !selectedAgentModel.supportsDirectImageInput, imageInputMode == .directModel else { return }
        imageInputMode = .ocr
        statusText = "\(selectedAgentModel.title) 仅支持本地 OCR"
    }

    func voiceEditDestination(for text: String) -> VoiceEditDestination {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !voiceStartedWithEmptyDraft {
            return .fullEditor
        }
        return trimmed.count > 10 ? .fullEditor : .textField
    }

    private func canBeginCardVoiceCapture(for cardId: String) -> Bool {
        guard let card = cards.first(where: { $0.id == cardId }) else { return false }
        guard card.id != "card_idle", card.type != "draft" else { return false }
        return card.status == .completed || card.status == .waitingConfirmation
    }

    private func beginVoiceCapture(destination: VoiceCaptureDestination) {
        guard !isRecording else { return }
        guard !pressArmed else { return }
        guard activeVoiceCaptureDestination == nil else { return }
        guard activeVoiceSessionID == nil else { return }

        pressArmed = true
        let sessionID = UUID()
        activeVoiceSessionID = sessionID
        terminatingVoiceSessionID = nil
        cancelledASRSessionID = nil
        voiceStartTask?.cancel()
        activeVoiceCaptureDestination = destination
        isVoiceCaptureActive = true
        voiceReleaseAction = .send
        voiceDragTranslation = .zero
        isVoiceHoldLocked = false
        if destination == .composer {
            voiceStartedWithEmptyDraft = draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        resetLiveTranscriptState()
        liveTranscript = ""
        voiceAmplitude = 0.0
        statusText = voiceCapturePreparingText(for: destination)

        // 只预热，不立刻震动。震动必须表示 ASR 已经可以收音。
        beginHapticGenerator.prepare()
        selectionHapticGenerator.prepare()
        releaseHapticGenerator.prepare()

        voiceStartTask = Task { [weak self, sessionID] in
            guard let self else { return }
            do {
                guard isCurrentVoiceSession(sessionID), pressArmed else { return }

                try await startSelectedASRService()

                guard isCurrentVoiceSession(sessionID), pressArmed else {
                    return
                }
                voiceStartTask = nil
                isRecording = true
                statusText = voiceCaptureListeningText(for: destination)
                JotlyLog.app.info("Voice session ready: \(sessionID.uuidString, privacy: .public)")
                beginHapticGenerator.impactOccurred()
                beginHapticGenerator.prepare()
            } catch {
                guard isCurrentVoiceSession(sessionID) else { return }
                abortVoiceCapture(status: error.localizedDescription)
            }
        }
    }

    private func voiceCapturePreparingText(for destination: VoiceCaptureDestination) -> String {
        switch destination {
        case .composer:
            return "正在准备转写..."
        case .card:
            return "正在准备补充卡片..."
        }
    }

    private func voiceCaptureListeningText(for destination: VoiceCaptureDestination) -> String {
        switch destination {
        case .composer:
            return "\(asrProvider.title) 正在聆听..."
        case .card(let cardId):
            if let card = cards.first(where: { $0.id == cardId }) {
                return "正在聆听「\(card.title)」..."
            }
            return "正在聆听当前卡片..."
        }
    }

    func beginVoiceCapture() {
        beginVoiceCapture(destination: .composer)
    }

    func beginCardVoiceCapture(cardId: String) {
        guard canBeginCardVoiceCapture(for: cardId) else {
            statusText = "当前卡片暂不支持语音补充"
            return
        }
        beginVoiceCapture(destination: .card(cardId))
    }

    func updateVoiceDrag(translation: CGSize) {
        guard isVoiceCaptureActive,
              activeVoiceCaptureDestination == .composer,
              !isVoiceHoldLocked else { return }
        voiceDragTranslation = translation

        let newAction = resolvedVoiceReleaseAction(for: translation)

        if newAction != voiceReleaseAction {
            let oldAction = voiceReleaseAction
            voiceReleaseAction = newAction

            // 触发清晰物理振动反馈，告诉用户已经选中对应操作
            if newAction == .hold {
                triggerHoldHaptic()
            } else if newAction == .cancel || newAction == .edit {
                // 进入选中状态：重度触觉反馈（模拟磁吸落槽）
                selectionHapticGenerator.impactOccurred()
                selectionHapticGenerator.prepare()
            } else if oldAction == .cancel || oldAction == .edit || oldAction == .hold {
                // 离开选中状态：轻度触觉反馈（模拟弹出）
                releaseHapticGenerator.impactOccurred()
                releaseHapticGenerator.prepare()
            }
        }
    }

    func updateImageVoiceDrag(translation: CGSize) {
        guard isImageVoiceCaptureActive, !isVoiceHoldLocked else { return }
        voiceDragTranslation = translation

        let newAction = resolvedImageVoiceReleaseAction(for: translation)
        if newAction != voiceReleaseAction {
            let oldAction = voiceReleaseAction
            voiceReleaseAction = newAction

            if newAction == .hold {
                triggerHoldHaptic()
            } else if newAction == .cancel {
                selectionHapticGenerator.impactOccurred()
                selectionHapticGenerator.prepare()
            } else if oldAction == .cancel || oldAction == .hold {
                releaseHapticGenerator.impactOccurred()
                releaseHapticGenerator.prepare()
            }
        }
    }

    func cancelVoiceCaptureOnInterrupt() {
        if isRecording || isVoiceCaptureActive || pressArmed {
            JotlyLog.app.warning("Recording interrupted, resetting state")
            abortVoiceCapture(status: "长按说话，松手后生成卡片")
        }
    }

    func finishVoiceCaptureForCurrentAction() -> VoiceCompletionResult? {
        switch activeVoiceCaptureDestination {
        case .composer:
            switch voiceReleaseAction {
            case .send:
                finishVoiceCapture(commit: true)
                return nil
            case .cancel:
                finishVoiceCapture(commit: false)
                statusText = "已取消"
                return nil
            case .hold:
                holdVoiceCapture()
                return nil
            case .edit:
                return finishVoiceCaptureForEditing()
            }
        case .card:
            finishVoiceCapture(commit: true)
            return nil
        case nil:
            return nil
        }
    }

    func finishImageVoiceCaptureForCurrentAction() -> Bool {
        switch voiceReleaseAction {
        case .send:
            finishVoiceCapture(commit: true)
            return true
        case .cancel:
            finishVoiceCapture(commit: false)
            statusText = "已取消语音"
            return false
        case .hold:
            holdVoiceCapture()
            return false
        case .edit:
            finishVoiceCapture(commit: true)
            return true
        }
    }

    func finishVoiceCaptureForEditing() -> VoiceCompletionResult? {
        let textForEditing = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        finishVoiceCapture(commit: false)

        guard !textForEditing.isEmpty else {
            statusText = "可以手动输入"
            return .insertIntoTextField("")
        }

        let destination = voiceEditDestination(for: textForEditing)
        switch destination {
        case .textField:
            statusText = "已填入文本框"
            return .insertIntoTextField(textForEditing)
        case .fullEditor:
            statusText = "已转入长文本编辑"
            return .openFullEditor(textForEditing)
        }
    }

    func toggleHeldVoiceCapture() {
        if isVoiceHoldLocked {
            stopHeldVoiceCapture()
        } else {
            holdVoiceCapture()
        }
    }

    func stopHeldVoiceCapture() {
        guard isVoiceHoldLocked else { return }
        isVoiceHoldLocked = false
        finishVoiceCapture(commit: true)
    }

    func finishVoiceCapture(commit: Bool) {
        let destination = activeVoiceCaptureDestination
        guard let sessionID = activeVoiceSessionID,
              terminatingVoiceSessionID != sessionID else { return }
        terminatingVoiceSessionID = sessionID
        JotlyLog.app.info("Voice session terminating: \(sessionID.uuidString, privacy: .public), commit=\(commit)")

        pressArmed = false
        isVoiceCaptureActive = false
        isVoiceHoldLocked = false
        voiceReleaseAction = .send
        voiceDragTranslation = .zero
        voiceAmplitude = 0.0
        activeVoiceCaptureDestination = nil

        guard isRecording else {
            voiceStartTask?.cancel()
            voiceStartTask = nil
            cancelSelectedASRService(for: sessionID)
            clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
            statusText = "长按说话，松手后生成卡片"
            return
        }

        isRecording = false

        guard commit else {
            voiceStartTask?.cancel()
            voiceStartTask = nil
            cancelSelectedASRService(for: sessionID)
            clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
            statusText = "长按说话，松手后生成卡片"
            return
        }

        // 提交场景：停止录音并拿最终识别结果
        // liveTranscript 已经在流式识别过程中实时更新了
        statusText = "正在识别..."
        voiceStopTask?.cancel()
        voiceStopTask = Task { [weak self, sessionID, destination] in
            guard let self else { return }
            do {
                let text = try await self.stopSelectedASRService()
                guard self.isCurrentVoiceSession(sessionID),
                      self.terminatingVoiceSessionID == sessionID else { return }
                let trimmed = self.finalizedLiveTranscript(with: text)
                if trimmed.isEmpty {
                    // 如果最终结果为空，从实时转写里捞一份（可能有网络问题时兜底）
                    let live = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
                    guard !live.isEmpty else {
                        await MainActor.run {
                            self.statusText = "未识别到语音内容"
                        }
                        return
                    }
                    await MainActor.run {
                        self.routeVoiceCaptureResult(text: live, destination: destination)
                    }
                    return
                }
                self.clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
                await MainActor.run {
                    self.routeVoiceCaptureResult(text: trimmed, destination: destination)
                }
            } catch {
                guard self.isCurrentVoiceSession(sessionID),
                      self.terminatingVoiceSessionID == sessionID else { return }
                // 如果 API 失败了，尝试用实时转写的结果兜底
                let live = self.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                self.clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
                if !live.isEmpty {
                    await MainActor.run {
                        self.routeVoiceCaptureResult(text: live, destination: destination)
                    }
                } else {
                    await MainActor.run {
                        self.statusText = "识别失败：\(error.localizedDescription)"
                    }
                }
            }
        }
    }

    @MainActor
    private func routeVoiceCaptureResult(text: String, destination: VoiceCaptureDestination?) {
        switch destination {
        case .composer:
            if let images = pendingComposerVoiceImages, !images.isEmpty {
                pendingComposerVoiceImages = nil
                submitImages(images, userText: text)
            } else {
                submitRecognizedText(text)
            }
        case .card(let cardId):
            submitCardSupplementText(text, for: cardId)
        case nil:
            submitRecognizedText(text)
        }
    }

    private func clearVoiceCaptureState(resetTranscript: Bool, preserveDestination: Bool = false) {
        pressArmed = false
        activeVoiceSessionID = nil
        terminatingVoiceSessionID = nil
        voiceStartTask = nil
        voiceStopTask = nil
        isVoiceCaptureActive = false
        isRecording = false
        isVoiceHoldLocked = false
        voiceReleaseAction = .send
        voiceDragTranslation = .zero
        voiceAmplitude = 0.0
        if !preserveDestination {
            activeVoiceCaptureDestination = nil
        }
        if resetTranscript {
            liveTranscript = ""
            resetLiveTranscriptState()
        }
    }

    private func abortVoiceCapture(status: String) {
        guard let sessionID = activeVoiceSessionID else {
            clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
            statusText = status
            return
        }
        guard terminatingVoiceSessionID != sessionID else { return }
        terminatingVoiceSessionID = sessionID
        JotlyLog.app.info("Voice session cancelled: \(sessionID.uuidString, privacy: .public)")
        voiceStartTask?.cancel()
        voiceStartTask = nil
        voiceStopTask?.cancel()
        voiceStopTask = nil
        cancelSelectedASRService(for: sessionID)
        pendingComposerVoiceImages = nil
        clearVoiceCaptureState(resetTranscript: true, preserveDestination: false)
        statusText = status
    }

    private func isCurrentVoiceSession(_ sessionID: UUID?) -> Bool {
        guard let sessionID else { return false }
        return activeVoiceSessionID == sessionID
    }

    @MainActor
    private func startSelectedASRService() async throws {
        let transcriptHandler: @MainActor (String, Bool) -> Void = { [weak self] text, isFinal in
            self?.updateLiveTranscript(with: text, isFinal: isFinal)
        }
        let volumeHandler: @MainActor (Float) -> Void = { [weak self] level in
            self?.voiceAmplitude = level
        }

        switch asrProvider {
        case .apple:
            try await appleSpeechService.start(
                onTranscript: transcriptHandler,
                onVolumeChanged: volumeHandler
            )
        case .mimo:
            try await mimoASRService.start(
                onTranscript: transcriptHandler,
                onVolumeChanged: volumeHandler
            )
        case .doubao:
            try await doubaoASRService.start(
                onTranscript: transcriptHandler,
                onVolumeChanged: volumeHandler
            )
        case .aliyun:
            try await aliyunASRService.start(
                onTranscript: transcriptHandler,
                onVolumeChanged: volumeHandler
            )
        }
    }

    @MainActor
    private func stopSelectedASRService() async throws -> String {
        switch asrProvider {
        case .apple:
            let text = liveTranscript
            appleSpeechService.stop()
            return text
        case .mimo:
            return try await mimoASRService.stop()
        case .doubao:
            return try await doubaoASRService.stop()
        case .aliyun:
            return try await aliyunASRService.stop()
        }
    }

    @MainActor
    private func cancelSelectedASRService(for sessionID: UUID) {
        guard cancelledASRSessionID != sessionID else { return }
        guard !isCancellingASRService else { return }
        cancelledASRSessionID = sessionID
        isCancellingASRService = true
        defer { isCancellingASRService = false }

        switch asrProvider {
        case .apple:
            appleSpeechService.stop()
        case .mimo:
            mimoASRService.cancel()
        case .doubao:
            doubaoASRService.cancel()
        case .aliyun:
            aliyunASRService.cancel()
        }
    }

    private func updateLiveTranscript(with rawText: String, isFinal: Bool = false) {
        let text = normalizedASRText(rawText, isFinal: isFinal)
        guard !text.isEmpty else {
            if isFinal {
                currentLiveTranscript = ""
                liveTranscript = confirmedLiveTranscript
            }
            return
        }

        if isFinal {
            confirmedLiveTranscript = committedTranscript(confirmedLiveTranscript, text)
            currentLiveTranscript = ""
            liveTranscript = confirmedLiveTranscript
            return
        }

        currentLiveTranscript = partialTranscript(text, after: confirmedLiveTranscript)
        liveTranscript = mergedTranscript(confirmedLiveTranscript, currentLiveTranscript)
    }

    private func finalizedLiveTranscript(with serviceText: String) -> String {
        updateLiveTranscript(with: serviceText, isFinal: true)
        return liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resetLiveTranscriptState() {
        confirmedLiveTranscript = ""
        currentLiveTranscript = ""
    }

    private func appendConversationMessage(
        role: CardConversationMessage.Role,
        text: String,
        to card: inout MemoryCard,
        limit: Int = 16
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        card.conversationMessages.append(CardConversationMessage(role: role, text: trimmed))
        if card.conversationMessages.count > limit {
            card.conversationMessages = Array(card.conversationMessages.suffix(limit))
        }
    }

    private func mergedTranscript(_ left: String, _ right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        if lhs.isEmpty { return rhs }
        if rhs.isEmpty { return lhs }
        if lhs == rhs || lhs.hasSuffix(rhs) || lhs.contains(rhs) { return lhs }
        if rhs.hasPrefix(lhs) { return rhs }
        let overlap = suffixPrefixOverlap(lhs, rhs)
        if overlap > 0 {
            return lhs + String(rhs.dropFirst(overlap))
        }
        if shouldInsertSpace(between: lhs, and: rhs) {
            return "\(lhs) \(rhs)"
        }
        return lhs + rhs
    }

    private func partialTranscript(_ text: String, after confirmed: String) -> String {
        let confirmedText = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let incoming = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !confirmedText.isEmpty, incoming.hasPrefix(confirmedText) else {
            return incoming
        }
        return String(incoming.dropFirst(confirmedText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func committedTranscript(_ confirmed: String, _ incomingFinal: String) -> String {
        let confirmedText = confirmed.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalText = incomingFinal.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !confirmedText.isEmpty else {
            return finalText
        }

        if finalText.hasPrefix(confirmedText) {
            return finalText
        }

        return mergedTranscript(confirmedText, finalText)
    }

    private func normalizedASRText(_ text: String, isFinal: Bool) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        let duplicatePunctuation = ["。。": "。", "，，": "，", "！！": "！", "？？": "？", "..": ".", ",,": ",", "!!": "!", "??": "?"]
        for (pattern, replacement) in duplicatePunctuation {
            while result.contains(pattern) {
                result = result.replacingOccurrences(of: pattern, with: replacement)
            }
        }
        if !isFinal {
            result = result.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.!！?？；;：:"))
        }
        return result
    }

    private func shouldInsertSpace(between left: String, and right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return false }
        return last.isASCII && first.isASCII && (last.isLetter || last.isNumber) && (first.isLetter || first.isNumber)
    }

    private func suffixPrefixOverlap(_ left: String, _ right: String) -> Int {
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

    // MARK: - 文本提交

    func submitDraftText(_ submittedText: String? = nil) {
        let trimmed = (submittedText ?? draftText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draftText = ""
        inputMode = .voice
        submitRecognizedText(trimmed)
    }

    func submitEditorText() {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if editorLinkedDraftCard {
            removeDraftCard()
        }

        editorText = ""
        editorLinkedDraftCard = false
        inputMode = .voice
        submitRecognizedText(trimmed)
    }

    func deleteEditorText() {
        if editorLinkedDraftCard {
            removeDraftCard()
        }

        editorText = ""
        editorLinkedDraftCard = false
    }

    // MARK: - 卡片选项选择

    func selectOption(_ option: CardOption, for cardId: String) {
        JotlyLog.tool.info("selectOption called: key=\(option.key, privacy: .public), value=\(option.value, privacy: .public), cardId=\(cardId, privacy: .public)")

        guard let index = cards.firstIndex(where: { $0.id == cardId }) else {
            JotlyLog.tool.warning("selectOption blocked: card not found \(cardId, privacy: .public)")
            return
        }

        guard cards[index].status == .waitingConfirmation else {
            JotlyLog.tool.warning("selectOption blocked: card status is \(self.cards[index].status.rawValue, privacy: .public)")
            return
        }

        var selectionCard = cards[index]
        appendConversationMessage(role: .user, text: "用户选择：\(option.label)", to: &selectionCard)
        selectionCard.markUpdated()
        cards[index] = selectionCard
        try? store.upsertCard(selectionCard)

        let directPlans = resolvedPlans(for: option, card: cards[index])
        let isRecordOnlySelection = option.value == "record_only"
            || option.value.localizedStandardContains("仅记录")
            || option.label.localizedStandardContains("仅记录")
        let nextStep = isRecordOnlySelection
            ? "finish"
            : (option.nextStep ?? (option.value == "request_more_info" ? "wait_for_more_info" : (directPlans.isEmpty ? "continue_loop" : "finish")))
        if nextStep == "wait_for_more_info" || option.value == "request_more_info" {
            JotlyLog.tool.info("selectOption entering clarification mode")
            var clarifying = cards[index]
            clarifying.selectedOptionValue = option.value
            clarifying.message = option.description ?? option.resultCard?.message ?? "请补充更多信息，我会继续判断。"
            appendConversationMessage(role: .assistant, text: clarifying.message, to: &clarifying)
            clarifying.markUpdated()
            cards[index] = clarifying
            activeClarificationCardID = cardId
            clarificationDraftText = clarifying.supplementalText ?? ""
            statusText = "请补充信息"
            try? store.upsertCard(clarifying)
            return
        }

        JotlyLog.tool.info("selectOption proceeding: switching to executing state")

        var executing = cards[index]
        executing.status = .executing
        executing.selectedOptionValue = option.value
        executing.message = executingMessage(for: option)
        executing.markUpdated()
        cards[index] = executing
        statusText = "正在处理..."

        Task { [weak self] in
            guard let self else { return }
            do {
                JotlyLog.storage.info("selectOption: storing card and executing tool")
                try store.upsertCard(executing)
                updateDebugNode(cardId: cardId, nodeId: "confirm", state: .completed, detail: "用户选择：\(option.label)")
                let plans = directPlans
                updateDebugNode(
                    cardId: cardId,
                    nodeId: "tool",
                    state: plans.isEmpty ? .completed : .running,
                    detail: plans.isEmpty ? "选项没有挂载直接动作，继续交给模型判断" : "执行工具：\(plans.map(\.tool).joined(separator: ", "))"
                )
                let results = try await executeToolPlans(plans, card: executing)
                guard !isLoopCancelled(cardId: cardId) else { return }

                var completed = executing
                completed.status = status(from: option.resultCard?.status) ?? .completed
                let completionMessage = option.resultCard?.message ?? results.last?.completionMessage ?? "已处理完成。"
                completed.completionMessage = completionMessage
                completed.message = completionMessage
                if let title = option.resultCard?.title {
                    completed.title = title
                }
                if let summary = option.resultCard?.summary {
                    completed.summary = summary
                }
                if let type = option.resultCard?.type {
                    completed.type = type
                }
                completed.options = []
                completed.reminderInfo = preferredReminderInfo(from: results)
                if let meta = mergedMetadata(from: results) {
                    completed.metadata = meta
                }
                appendConversationMessage(role: .assistant, text: completionMessage, to: &completed)
                completed.markUpdated()
                if !plans.isEmpty {
                    updateDebugNode(cardId: cardId, nodeId: "tool", state: .completed, detail: completionMessage)
                }
                updateDebugNode(cardId: cardId, nodeId: "finish", state: .completed, detail: nextStep == "finish" ? "卡片已更新为完成状态" : "等待下一轮模型判断")

                if let idx = cards.firstIndex(where: { $0.id == cardId }) {
                    cards[idx] = completed
                }
                try store.upsertCard(completed)
                if completed.status == .completed {
                    updateChildrenStatus(for: completed.id, status: .completed)
                }
                clearClarificationState(for: completed.id)
                if nextStep == "continue_loop" {
                    statusText = "AI 正在继续判断..."
                    await continueAgentLoop(after: option, results: results, card: completed)
                } else {
                    statusText = "已完成"
                }
                JotlyLog.tool.info("selectOption completed successfully")
            } catch {
                guard !isLoopCancelled(cardId: cardId) else { return }
                JotlyLog.tool.error("selectOption failed: \(error.localizedDescription, privacy: .public)")
                updateDebugNode(cardId: cardId, nodeId: "tool", state: .failed, detail: error.localizedDescription)
                updateDebugNode(cardId: cardId, nodeId: "finish", state: .failed, detail: "工具执行失败")
                var failed = executing
                failed.status = .failed
                failed.message = error.localizedDescription
                failed.options = []
                failed.markUpdated()

                if let idx = cards.firstIndex(where: { $0.id == cardId }) {
                    cards[idx] = failed
                }
                statusText = "处理失败"
                try? store.upsertCard(failed)
            }
        }
    }

    func toggleReceiptChildIgnored(cardId: String, childId: String) {
        guard let cardIndex = cards.firstIndex(where: { $0.id == cardId }),
              let childIndex = cards[cardIndex].children.firstIndex(where: { $0.id == childId })
        else { return }

        cards[cardIndex].children[childIndex].isIgnored.toggle()
        cards[cardIndex].children[childIndex].status = cards[cardIndex].children[childIndex].isIgnored
            ? "ignored"
            : "pending"
        cards[cardIndex].markUpdated()
        try? store.upsertCard(cards[cardIndex])
    }

    // MARK: - 图片/文件

    func insertImage(_ image: UIImage) {
        insertImages([image])
    }

    func insertImages(_ images: [UIImage]) {
        submitImages(images, userText: nil)
    }

    func beginImageVoiceCapture(images: [UIImage]) {
        guard !images.isEmpty else { return }
        pendingComposerVoiceImages = images
        beginVoiceCapture(destination: .composer)
    }

    func submitImages(_ images: [UIImage], userText: String? = nil) {
        guard !isRecording else {
            statusText = "正在录音，先结束后再处理图片"
            return
        }
        guard !images.isEmpty else { return }

        let mode = resolvedImageInputMode
        statusText = imageProcessingStatusText(mode: mode, total: images.count)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await processPickedImages(images, mode: mode, userText: userText)
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    private func processPickedImages(_ images: [UIImage], mode: ImageInputMode, userText: String?) async throws {
        let trimmedUserText = userText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch mode {
        case .ocr:
            var parts: [String] = []
            for (offset, image) in images.enumerated() {
                statusText = "正在本地识别图片（\(offset + 1)/\(images.count)）..."
                let recognizedText = try await recognizeText(from: image)
                let trimmed = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(images.count > 1 ? "第 \(offset + 1) 张图片文字：\n\(trimmed)" : trimmed)
                }
            }
            guard !parts.isEmpty else {
                statusText = "图片里没有识别到可用文字"
                return
            }
            var promptText = parts.joined(separator: "\n\n")
            if !trimmedUserText.isEmpty {
                promptText = "用户补充：\(trimmedUserText)\n\n图片 OCR 结果：\n\(promptText)"
            }
            submitRecognizedText(promptText, imageInputMode: .ocr)
        case .directModel:
            let attachments = images.enumerated().compactMap { offset, image -> ImageAttachment? in
                statusText = "正在压缩图片（\(offset + 1)/\(images.count)）..."
                return makeImageAttachment(from: image)
            }
            guard attachments.count == images.count else {
                throw JotlyError.invalidToolParameters("图片压缩失败")
            }
            let promptText = imageDirectPromptText(imageCount: images.count, userText: trimmedUserText)
            submitRecognizedText(promptText, imageAttachments: attachments, imageInputMode: .directModel)
        }
    }

    private func imageDirectPromptText(imageCount: Int, userText: String) -> String {
        let base = imageCount > 1
            ? "用户上传了 \(imageCount) 张图片，请把这些图片作为同一次输入整体理解，综合判断后按系统要求输出 JSON。"
            : "用户上传了一张图片，请结合图片内容判断，并按系统要求输出 JSON。"
        guard !userText.isEmpty else { return base }
        return "\(base)\n用户补充：\(userText)"
    }

    private func imageProcessingStatusText(mode: ImageInputMode, total: Int) -> String {
        let suffix = total > 1 ? "（共 \(total) 张）" : ""
        switch mode {
        case .ocr:
            return "正在本地识别图片\(suffix)..."
        case .directModel:
            return "正在把图片送给模型\(suffix)..."
        }
    }

    func insertFile(_ url: URL) {
        statusText = "已添加文件（第一期不进入 AI 流程）"
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
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    // MARK: - 删除卡片

    func deleteCard(id: String) {
        cancelledCardIDs.insert(id)

        if id == "card_draft" {
            editorText = ""
            editorLinkedDraftCard = false
        }

        // Remove from the visible list first so the swipe animation is never blocked by disk or EventKit work.
        let children = cards.filter { $0.parentId == id }
        var idsToDelete = Set(children.map(\.id))
        idsToDelete.insert(id)
        cards.removeAll { idsToDelete.contains($0.id) }
        if let activeClarificationCardID, idsToDelete.contains(activeClarificationCardID) {
            clearClarificationState()
        }

        if cards.isEmpty {
            cards = [MemoryCard.idle()]
        }

        Task { [weak self, idsToDelete] in
            let snapshot = await Task.detached(priority: .utility) {
                LocalStore.loadSnapshotFromDisk()
            }.value
            guard let self, let snapshot else { return }
            for cardID in idsToDelete {
                birthdayExecutor.cancelArtifacts(for: snapshot, cardId: cardID)
            }
            try? store.deleteCards(ids: idsToDelete)
        }
    }

    // MARK: - 草稿箱管理

    func saveEditorAsCard() {
        let trimmed = editorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        // 移除 idle 提示卡片
        cards.removeAll { $0.id == "card_idle" }

        if let idx = cards.firstIndex(where: { $0.id == "card_draft" }) {
            cards[idx].originalText = trimmed
            cards[idx].updatedAt = Date()
            try? store.upsertCard(cards[idx])
        } else {
            let draftCard = MemoryCard(
                id: "card_draft",
                type: "draft",
                title: "未完成的草稿",
                status: .idle,
                originalText: trimmed,
                summary: "",
                message: "点击继续编辑或发送",
                completionMessage: nil,
                options: [],
                entities: nil,
                supplementalText: nil,
                toolCandidates: [],
                selectedOptionValue: nil,
                reminderInfo: nil,
                toolPlan: nil,
                metadata: nil,
                imageInputMode: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
            cards.insert(draftCard, at: 0)
            try? store.upsertCard(draftCard)
        }

        editorLinkedDraftCard = true
    }

    func openDraftCard() {
        guard let draftIndex = cards.firstIndex(where: { $0.id == "card_draft" }) else { return }
        let text = cards[draftIndex].originalText
        prepareEditor(with: text, linkedDraftCard: true)
    }

    func removeDraftCard() {
        cards.removeAll { $0.id == "card_draft" }
        try? store.deleteCard(id: "card_draft")
        editorLinkedDraftCard = false
        if cards.isEmpty {
            cards = [MemoryCard.idle()]
        }
    }

    // MARK: - Private

    private func submitRecognizedText(
        _ text: String,
        imageAttachment: ImageAttachment? = nil,
        imageAttachments: [ImageAttachment] = [],
        imageInputMode: ImageInputMode? = nil,
        inputFingerprint: String? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        JotlyLog.app.info("submitRecognizedText received text length=\(trimmed.count, privacy: .public)")
        let attachments = imageAttachments.isEmpty ? (imageAttachment.map { [$0] } ?? []) : imageAttachments
        let resolvedImageMode = imageInputMode ?? (attachments.isEmpty ? nil : .ocr)
        let resolvedFingerprint = resolvedImageMode.map { _ in
            inputFingerprint ?? ImageInputFingerprint.make(text: trimmed, attachments: attachments)
        }
        if let resolvedFingerprint,
           cards.contains(where: { $0.metadata?["input_fingerprint"] == resolvedFingerprint }) {
            statusText = "这组图片已经处理过了"
            return
        }

        // 移除 idle 卡片
        cards.removeAll { $0.id == "card_idle" }

        var card = MemoryCard.processing(text: trimmed)
        card.imageInputMode = resolvedImageMode
        if !attachments.isEmpty {
            card.backgroundImagePath = CardBackgroundImageStore.relativePath(for: card.id)
        }
        card.userVisibleInput = attachments.isEmpty
            ? trimmed
            : (attachments.count > 1 ? "正在分析 \(attachments.count) 张图片" : "正在分析图片")
        card.metadata = ["processing_status": attachments.isEmpty ? "正在理解你的输入" : "正在识别图片内容"]
        if let resolvedFingerprint {
            card.metadata?["input_fingerprint"] = resolvedFingerprint
        }
        appendConversationMessage(role: .user, text: trimmed, to: &card)
        // 新卡片插入到最前面
        cards.insert(card, at: 0)
        startDebugTurn(cardId: card.id, userText: trimmed)
        statusText = "AI 正在整理..."

        let inputType: String
        switch resolvedImageMode {
        case .none:
            inputType = "text"
        case .some(.ocr):
            inputType = "image_ocr"
        case .some(.directModel):
            inputType = "image_direct"
        }
        let input = RawInput(text: trimmed, linkedCardId: card.id, type: inputType)

        Task { [weak self] in
            guard let self else { return }
            var processingStage = AgentProcessingStage.persistence
            var decodedAnalysis: AgentAnalysis?
            do {
                let requestContext = AgentRequestContext.newCard()
                if let firstImage = attachments.first {
                    let imageData = firstImage.data
                    let cardID = card.id
                    _ = try? await Task.detached(priority: .utility) {
                        try CardBackgroundImageStore.save(imageData, for: cardID)
                    }.value
                }
                try store.saveRawInput(input, card: card)
                updateProcessingStatus(
                    cardId: card.id,
                    text: attachments.isEmpty ? "正在理解你的输入" : "正在识别图片内容"
                )
                let prompt = deepSeekClient.debugPrompt(
                    text: trimmed,
                    latestCardStatus: .processing,
                    currentDate: DateFormatting.todayString(),
                    model: selectedAgentModel,
                    imageInputMode: resolvedImageMode,
                    requestContext: requestContext
                )
                updateDebugTurn(
                    cardId: card.id,
                    systemPrompt: prompt.systemPrompt,
                    userPrompt: prompt.userPrompt,
                    fullPrompt: prompt.fullPrompt,
                    nodeId: "prompt",
                    nodeState: .completed,
                    nodeDetail: "已组装 system + user prompt"
                )
                updateDebugNode(cardId: card.id, nodeId: "model", state: .running, detail: "正在请求模型")
                JotlyLog.deepSeek.info("calling DeepSeek analyze")
                processingStage = .modelRequest
                let initialResponse = try await deepSeekClient.analyzeWithDebug(
                    text: trimmed,
                    latestCardStatus: .processing,
                    currentDate: DateFormatting.todayString(),
                    model: selectedAgentModel,
                    imageAttachments: attachments,
                    imageInputMode: resolvedImageMode,
                    requestContext: requestContext,
                    existingCards: cards
                )
                guard !isLoopCancelled(cardId: card.id) else { return }
                recordModelUsage(initialResponse)
                let resolved = try await resolveMemoryResponseIfNeeded(
                    initialResponse,
                    text: trimmed,
                    latestCardStatus: .processing,
                    currentDate: DateFormatting.todayString(),
                    imageAttachments: attachments,
                    imageInputMode: resolvedImageMode,
                    requestContext: requestContext,
                    existingCards: cards,
                    cardID: card.id
                )
                updateProcessingStatus(cardId: card.id, text: "正在整理卡片")
                let debugResponse = resolved.response
                if resolved.retrieval != nil {
                    recordModelUsage(debugResponse)
                }
                let analysis = normalizedAnalysis(debugResponse.analysis)
                decodedAnalysis = analysis
                processingStage = .cardUpdate
                updateDebugTurn(
                    cardId: card.id,
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
                updateDebugNode(cardId: card.id, nodeId: "decode", state: .completed, detail: "JSON 已解析：\(analysis.intent)")
                JotlyLog.deepSeek.info(
                    "DeepSeek response: intent=\(analysis.intent, privacy: .public), cardType=\(analysis.cardType, privacy: .public), requiresConfirmation=\(analysis.requiresConfirmation, privacy: .public), recommendedAction=\(analysis.recommendedActionValue ?? "nil", privacy: .public), options=\(analysis.options.count, privacy: .public)"
                )

                try await handleAgentAnalysis(analysis, on: card, requestContext: requestContext)
                scheduleMemoryIngestion(from: analysis, linkedCardID: card.id)
                if let retrieval = resolved.retrieval {
                    try? store.linkMemories(retrieval.memoryIDs, toCardID: card.id)
                }
            } catch {
                guard !isLoopCancelled(cardId: card.id) else { return }
                JotlyLog.deepSeek.error("DeepSeek error: \(error.localizedDescription, privacy: .public)")
                if let analysis = decodedAnalysis {
                    let detail = "结果已解析，但卡片更新失败：\(error.localizedDescription)"
                    var failed = makeAgentResultCard(
                        from: analysis,
                        reusing: card,
                        requestContext: .newCard(),
                        originalStatus: card.status
                    )
                    failed.status = .failed
                    failed.message = detail
                    failed.completionMessage = detail
                    appendConversationMessage(role: .assistant, text: detail, to: &failed)
                    failed.markUpdated()
                    if let index = cards.firstIndex(where: { $0.id == failed.id }) {
                        cards[index] = failed
                    }
                    statusText = "结果暂未保存"
                    updateDebugNode(cardId: card.id, nodeId: "decode", state: .completed, detail: "JSON 已解析：\(analysis.intent)")
                    updateDebugNode(cardId: card.id, nodeId: "finish", state: .failed, detail: detail)
                    return
                }
                let rawOutput = rawModelOutput(from: error)
                let failureStage = agentFailureStage(for: error, current: processingStage)
                let failureNode = failureStage == .decode
                    ? "decode"
                    : (failureStage == .persistence ? "finish" : "model")
                updateDebugTurn(
                    cardId: card.id,
                    modelOutput: rawOutput ?? error.localizedDescription,
                    decodedSummary: failureStage.summary,
                    nodeId: failureNode,
                    nodeState: .failed,
                    nodeDetail: error.localizedDescription
                )
                var failed = card
                failed.status = .failed
                failed.title = "处理失败"
                failed.message = modelFailureMessage(for: error)
                failed.completionMessage = failed.message
                failed.options = []
                appendConversationMessage(role: .assistant, text: failed.message, to: &failed)
                failed.markUpdated()
                if let index = cards.firstIndex(where: { $0.id == failed.id }) {
                    cards[index] = failed
                }
                statusText = "处理失败"
                if failureStage == .decode {
                    updateDebugNode(cardId: card.id, nodeId: "decode", state: .failed, detail: error.localizedDescription)
                }
                updateDebugNode(cardId: card.id, nodeId: "finish", state: .failed, detail: failed.message)
                try? store.upsertCard(failed)
            }
        }
    }

    private func resolveMemoryResponseIfNeeded(
        _ initialResponse: DeepSeekDebugResponse,
        text: String,
        latestCardStatus: CardStatus,
        currentDate: String,
        imageAttachments: [ImageAttachment] = [],
        imageInputMode: ImageInputMode?,
        requestContext: AgentRequestContext,
        existingCards: [MemoryCard],
        cardID: String
    ) async throws -> (response: DeepSeekDebugResponse, retrieval: MemoryRetrievalResult?) {
        guard initialResponse.analysis.needMemory == true else {
            updateDebugNode(cardId: cardID, nodeId: "memory", state: .completed, detail: "本轮不需要读取记忆")
            return (initialResponse, nil)
        }

        let query = initialResponse.analysis.memoryQuery?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuery = (query?.isEmpty == false ? query : nil) ?? text
        try? store.updateAgentRunMemoryRequest(
            cardID: cardID,
            needMemory: true,
            query: resolvedQuery
        )
        updateDebugNode(cardId: cardID, nodeId: "memory", state: .running, detail: "正在检索：\(resolvedQuery)")

        let retrieval = await MemoryOSCoordinator.shared.retrieve(query: resolvedQuery)
        let detail = retrieval.memories.isEmpty
            ? "未找到相关记忆"
            : "命中 \(retrieval.memories.count) 条记忆 · 向量=\(retrieval.usedVectorSearch ? "是" : "否") · 重排=\(retrieval.usedRerank ? "是" : "否")"
        updateDebugNode(cardId: cardID, nodeId: "memory", state: .completed, detail: detail)
        updateDebugNode(cardId: cardID, nodeId: "model", state: .running, detail: "已装载记忆，正在生成回复")

        let secondResponse = try await deepSeekClient.analyzeWithDebug(
            text: text,
            latestCardStatus: latestCardStatus,
            currentDate: currentDate,
            model: selectedAgentModel,
            supplementalText: retrieval.promptContext,
            imageAttachments: imageAttachments,
            imageInputMode: imageInputMode,
            requestContext: requestContext,
            existingCards: existingCards
        )
        let replyAnalysis = secondResponse.analysis.asMemoryReply()
        return (
            DeepSeekDebugResponse(
                analysis: replyAnalysis,
                systemPrompt: secondResponse.systemPrompt,
                userPrompt: secondResponse.userPrompt,
                fullPrompt: secondResponse.fullPrompt,
                modelName: secondResponse.modelName,
                rawModelOutput: secondResponse.rawModelOutput,
                usage: secondResponse.usage,
                estimatedCostCNY: secondResponse.estimatedCostCNY
            ),
            retrieval
        )
    }

    private func scheduleMemoryIngestion(from analysis: AgentAnalysis, linkedCardID: String) {
        guard let memories = analysis.memoryToSave, !memories.isEmpty else { return }
        Task {
            await MemoryOSCoordinator.shared.ingest(memories, linkedCardID: linkedCardID)
        }
    }

    @MainActor
    private func updateProcessingStatus(cardId: String, text: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }),
              cards[index].status == .processing || cards[index].status == .executing else { return }
        var card = cards[index]
        var metadata = card.metadata ?? [:]
        metadata["processing_status"] = text
        card.metadata = metadata
        card.updatedAt = Date()
        cards[index] = card
        try? store.upsertCard(card)
    }

    @MainActor
    private func handleAgentAnalysis(
        _ analysis: AgentAnalysis,
        on card: MemoryCard,
        requestContext: AgentRequestContext
    ) async throws {
        let originalStatus = requestContext.cardSnapshot?.status ?? card.status

        if analysis.withinCardScope == false {
            let rejection = analysis.scopeReason?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "当前卡片无法识别该指令"
            updateDebugNode(cardId: card.id, nodeId: "confirm", state: .completed, detail: "当前卡片无法承载该指令")
            var rejected = card
            rejected.status = originalStatus == .processing ? .completed : originalStatus
            rejected.message = rejection
            rejected.completionMessage = rejection
            appendConversationMessage(role: .assistant, text: rejection, to: &rejected)
            rejected.markUpdated()
            if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                cards[idx] = rejected
            }
            statusText = rejection
            try store.upsertCard(rejected)
            if originalStatus == .waitingConfirmation {
                clearClarificationState(for: card.id)
            }
            return
        }

        if analysis.requiresConfirmation || shouldRequireInitialConfirmation(analysis, requestContext: requestContext) {
            updateDebugNode(cardId: card.id, nodeId: "confirm", state: .running, detail: "需要用户确认：\(analysis.options.count) 个选项")
            var updated = makeConfirmationCard(from: analysis, reusing: card)
            applyHabitDefaultsIfNeeded(to: &updated, appendTodayIfMissing: false)
            if let polished = analysis.optimizedUserText, !polished.isEmpty {
                updated.originalText = polished
            }
            appendConversationMessage(role: .assistant, text: updated.message, to: &updated)
            if let idx = cards.firstIndex(where: { $0.id == card.id }) {
                cards[idx] = updated
            }
            statusText = "请选择下一步"
            try store.upsertCard(updated)
            insertDerivedCards(from: analysis, parent: card, status: .waitingConfirmation)

            if originalStatus == .waitingConfirmation {
                clearClarificationState(for: card.id)
            }
            return
        }

        if analysis.shouldExecuteNow {
            updateDebugNode(cardId: card.id, nodeId: "confirm", state: .completed, detail: "无需确认，准备执行")
            insertDerivedCards(from: analysis, parent: card, status: .completed)

            await executeResolvedBirthdayAnalysis(analysis, on: card, requestContext: requestContext)
            return
        }

        updateDebugNode(cardId: card.id, nodeId: "confirm", state: .completed, detail: "信息已写回当前卡片")
        var updated = makeAgentResultCard(
            from: analysis,
            reusing: card,
            requestContext: requestContext,
            originalStatus: originalStatus
        )
        updated.status = requestContext.mode == .cardRevision && originalStatus == .waitingConfirmation ? .waitingConfirmation : .completed
        applyHabitDefaultsIfNeeded(
            to: &updated,
            appendTodayIfMissing: requestContext.mode == .cardRevision
        )
        if let polished = analysis.optimizedUserText, !polished.isEmpty {
            updated.originalText = polished
        }
        if let changeNote = analysis.changeNote, !changeNote.isEmpty {
            updated.changeNote = changeNote
            updated.isUpdated = true
        }
        appendConversationMessage(role: .assistant, text: updated.message, to: &updated)
        updated.markUpdated()
        if let idx = cards.firstIndex(where: { $0.id == card.id }) {
            cards[idx] = updated
        }
        statusText = updated.status == .waitingConfirmation ? "请选择下一步" : "已完成"
        try store.upsertCard(updated)

        if updated.status == .completed {
            insertDerivedCards(from: analysis, parent: card, status: .completed)
            updateChildrenStatus(for: updated.id, status: .completed)
        }

        if originalStatus == .waitingConfirmation, updated.status != .waitingConfirmation {
            clearClarificationState(for: card.id)
        }
    }

    @MainActor
    func submitClarificationText(_ text: String, for cardId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        submitCardSupplementText(trimmed, for: cardId)
    }

    @MainActor
    func submitCardSupplementText(_ text: String, for cardId: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }

        let originalStatus = cards[index].status
        guard originalStatus == .waitingConfirmation || originalStatus == .completed else { return }

        var contextCard = cards[index]
        appendConversationMessage(role: .user, text: trimmed, to: &contextCard)
        contextCard.supplementalText = trimmed

        var supplementing = contextCard
        supplementing.status = .processing
        supplementing.message = cardSupplementProcessingMessage(for: originalStatus)
        supplementing.userVisibleInput = trimmed
        var processingMetadata = supplementing.metadata ?? [:]
        processingMetadata["processing_status"] = "正在修改卡片"
        supplementing.metadata = processingMetadata
        supplementing.markUpdated()
        cards[index] = supplementing

        if originalStatus == .waitingConfirmation {
            activeClarificationCardID = cardId
            clarificationDraftText = ""
        }
        statusText = supplementing.message
        startDebugTurn(cardId: cardId, userText: trimmed)

        let input = RawInput(
            text: trimmed,
            linkedCardId: cardId,
            type: originalStatus == .waitingConfirmation ? "clarification" : "card_voice"
        )

        Task { [weak self] in
            guard let self else { return }
            var processingStage = AgentProcessingStage.persistence
            var decodedAnalysis: AgentAnalysis?
            do {
                let requestContext = AgentRequestContext.cardRevision(card: contextCard)
                try store.saveRawInput(input, card: supplementing)
                updateDebugNode(cardId: cardId, nodeId: "prompt", state: .running, detail: "当前卡片上下文已加入 prompt")
                let prompt = deepSeekClient.debugPrompt(
                    text: trimmed,
                    latestCardStatus: supplementing.status,
                    currentDate: DateFormatting.todayString(),
                    model: selectedAgentModel,
                    imageInputMode: supplementing.imageInputMode,
                    requestContext: requestContext
                )
                updateDebugTurn(
                    cardId: cardId,
                    systemPrompt: prompt.systemPrompt,
                    userPrompt: prompt.userPrompt,
                    fullPrompt: prompt.fullPrompt,
                    nodeId: "prompt",
                    nodeState: .completed,
                    nodeDetail: "已用卡片循环上下文组装 prompt"
                )
                updateDebugNode(cardId: cardId, nodeId: "model", state: .running, detail: "正在请求模型")
                processingStage = .modelRequest
                let initialResponse = try await deepSeekClient.analyzeWithDebug(
                    text: trimmed,
                    latestCardStatus: supplementing.status,
                    currentDate: DateFormatting.todayString(),
                    model: selectedAgentModel,
                    imageInputMode: supplementing.imageInputMode,
                    requestContext: requestContext,
                    existingCards: cards
                )
                guard !isLoopCancelled(cardId: cardId) else { return }
                recordModelUsage(initialResponse)
                let resolved = try await resolveMemoryResponseIfNeeded(
                    initialResponse,
                    text: trimmed,
                    latestCardStatus: supplementing.status,
                    currentDate: DateFormatting.todayString(),
                    imageInputMode: supplementing.imageInputMode,
                    requestContext: requestContext,
                    existingCards: cards,
                    cardID: cardId
                )
                let debugResponse = resolved.response
                if resolved.retrieval != nil {
                    recordModelUsage(debugResponse)
                }
                let analysis = normalizedAnalysis(debugResponse.analysis)
                decodedAnalysis = analysis
                processingStage = .cardUpdate
                updateDebugTurn(
                    cardId: cardId,
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
                    nodeDetail: "模型已返回补充后的输出"
                )
                updateDebugNode(cardId: cardId, nodeId: "decode", state: .completed, detail: "JSON 已重新解析：\(analysis.intent)")
                try await handleAgentAnalysis(analysis, on: supplementing, requestContext: requestContext)
                scheduleMemoryIngestion(from: analysis, linkedCardID: cardId)
                if let retrieval = resolved.retrieval {
                    try? store.linkMemories(retrieval.memoryIDs, toCardID: cardId)
                }
            } catch {
                guard !isLoopCancelled(cardId: cardId) else { return }
                JotlyLog.deepSeek.error("Card supplement failed: \(error.localizedDescription, privacy: .public)")
                if let analysis = decodedAnalysis {
                    let detail = "结果已解析，但卡片更新失败：\(error.localizedDescription)"
                    var failed = makeAgentResultCard(
                        from: analysis,
                        reusing: contextCard,
                        requestContext: .cardRevision(card: contextCard),
                        originalStatus: originalStatus
                    )
                    failed.status = originalStatus
                    failed.message = "\(analysis.message)\n\n\(detail)"
                    failed.completionMessage = originalStatus == .waitingConfirmation ? nil : failed.message
                    appendConversationMessage(role: .assistant, text: failed.message, to: &failed)
                    failed.markUpdated()
                    if let idx = cards.firstIndex(where: { $0.id == cardId }) {
                        cards[idx] = failed
                    }
                    statusText = "结果暂未保存"
                    updateDebugNode(cardId: cardId, nodeId: "decode", state: .completed, detail: "JSON 已解析：\(analysis.intent)")
                    updateDebugNode(cardId: cardId, nodeId: "finish", state: .failed, detail: detail)
                    return
                }
                let rawOutput = rawModelOutput(from: error)
                let failureStage = agentFailureStage(for: error, current: processingStage)
                let failureNode = failureStage == .decode
                    ? "decode"
                    : (failureStage == .persistence ? "finish" : "model")
                updateDebugTurn(
                    cardId: cardId,
                    modelOutput: rawOutput ?? error.localizedDescription,
                    decodedSummary: failureStage.summary,
                    nodeId: failureNode,
                    nodeState: .failed,
                    nodeDetail: error.localizedDescription
                )
                let rejection = failureStage.userMessage(for: error)
                var failed = supplementing
                failed.status = originalStatus
                failed.message = rejection
                failed.completionMessage = rejection
                appendConversationMessage(role: .assistant, text: rejection, to: &failed)
                failed.markUpdated()
                if let idx = cards.firstIndex(where: { $0.id == cardId }) {
                    cards[idx] = failed
                }
                statusText = rejection
                try? store.upsertCard(failed)
                if originalStatus == .waitingConfirmation {
                    clearClarificationState(for: cardId)
                }
            }
        }
    }

    private func cardSupplementProcessingMessage(for status: CardStatus) -> String {
        switch status {
        case .waitingConfirmation:
            return "AI 正在重新判断..."
        case .completed:
            return "AI 正在补充当前卡片..."
        default:
            return "AI 正在处理..."
        }
    }

    func cancelClarification(for cardId: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        guard cards[index].status == .waitingConfirmation else {
            clearClarificationState(for: cardId)
            return
        }

        var card = cards[index]
        if card.selectedOptionValue == "request_more_info" {
            card.selectedOptionValue = nil
            card.markUpdated()
            cards[index] = card
            try? store.upsertCard(card)
        }

        clearClarificationState(for: cardId)
        statusText = "请选择下一步"
    }

    func reloadState() {
        storeReloadTask?.cancel()
        let pageSize = cardPageSize
        storeReloadTask = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                LocalStore.loadSnapshotFromDisk(cardLimit: pageSize)
            }.value
            guard let self, let snapshot, !Task.isCancelled else { return }
            self.store.invalidateCache()
            self.cards = snapshot.cards.sorted { $0.updatedAt > $1.updatedAt }
            self.hasMorePersistedCards = snapshot.cards.count == pageSize
            if let openedOperation = snapshot.shortcutOperations.sorted(by: { $0.updatedAt > $1.updatedAt }).first(where: { $0.phase == .completed && $0.openAppRequested }) {
                self.displayMode = .cards
                self.selectedCategory = .all
                Task { @MainActor [store] in
                    _ = try? store.updateShortcutOperation(id: openedOperation.id) { operation in
                        operation.openAppRequested = false
                    }
                }
            }
        }
    }

    private func scheduleReloadState() {
        storeReloadTask?.cancel()
        storeReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.reloadState()
            }
        }
    }

    @MainActor
    private func executeResolvedBirthdayAnalysis(
        _ analysis: AgentAnalysis,
        on card: MemoryCard,
        requestContext: AgentRequestContext
    ) async {
        guard !isLoopCancelled(cardId: card.id) else { return }
        guard let actionValue = analysis.recommendedActionValue ?? fallbackActionValue(for: analysis, card: card) else {
            JotlyLog.tool.error("Resolved analysis missing action value")
            var failed = analysis.makeCard(reusing: card)
            failed.status = .failed
            failed.message = "无法确定下一步，请再补充一次。"
            failed.completionMessage = failed.message
            failed.options = []
            failed.markUpdated()
            if let idx = cards.firstIndex(where: { $0.id == failed.id }) {
                cards[idx] = failed
            }
            statusText = "处理失败"
            try? store.upsertCard(failed)
            clearClarificationState(for: failed.id)
            return
        }

        var executing = analysis.makeCard(reusing: card)
        executing.status = .executing
        executing.selectedOptionValue = actionValue
        executing.message = "正在处理..."
        executing.completionMessage = nil
        executing.markUpdated()

        if let idx = cards.firstIndex(where: { $0.id == executing.id }) {
            cards[idx] = executing
        }
        statusText = "正在处理..."
        try? store.upsertCard(executing)

        do {
            var completed = executing
            completed.status = .completed
            completed.options = []

            let executablePlans = analysis.toolPlan?.filter { $0.when == "now" } ?? []

            var toolResults: [ToolDispatcher.ToolExecutionResult] = []
            for plan in executablePlans {
                updateDebugNode(cardId: executing.id, nodeId: "tool", state: .running, detail: "执行工具：\(plan.tool)")
                let result = try await toolDispatcher.execute(plan: plan, card: executing)
                toolResults.append(result)
                guard !isLoopCancelled(cardId: executing.id) else { return }
                if result.shouldDeleteCallingCard {
                    deleteCard(id: executing.id)
                    reloadState()
                    return
                }
                let modelMessage = analysis.card?.message ?? analysis.userVisibleText
                if requestContext.mode == .cardRevision, let modelMessage, !modelMessage.isEmpty {
                    completed.message = modelMessage
                    completed.completionMessage = modelMessage
                } else {
                    completed.completionMessage = result.completionMessage
                    completed.message = result.completionMessage
                }
                if let meta = result.metadata {
                    completed.metadata = meta
                    if completed.type == "habit",
                       let json = meta["initial_check_in_dates"],
                       let data = json.data(using: .utf8),
                       let dates = try? JSONDecoder().decode([String].self, from: data),
                       !dates.isEmpty {
                        completed.habitCheckInDates = dates
                    }
                }
                updateDebugNode(cardId: executing.id, nodeId: "tool", state: .completed, detail: result.completionMessage)
            }

            completed.reminderInfo = preferredReminderInfo(from: toolResults)

            if completed.message == "正在处理..." {
                completed.message = analysis.card?.message ?? analysis.userVisibleText ?? "已处理完成。"
            }
            if completed.type == "habit" && (completed.habitCheckInDates == nil || completed.habitCheckInDates!.isEmpty) {
                completed.habitCheckInDates = [DateFormatting.todayString()]
            }
            if let polished = analysis.optimizedUserText, !polished.isEmpty {
                completed.originalText = polished
            }
            if let changeNote = analysis.changeNote, !changeNote.isEmpty {
                completed.changeNote = changeNote
                completed.isUpdated = true
            }
            appendConversationMessage(role: .assistant, text: completed.message, to: &completed)
            completed.markUpdated()
            updateDebugNode(cardId: executing.id, nodeId: "finish", state: .completed, detail: completed.message)

            if let idx = cards.firstIndex(where: { $0.id == completed.id }) {
                cards[idx] = completed
            }
            statusText = "已完成"
            try store.upsertCard(completed)
            if completed.status == .completed {
                updateChildrenStatus(for: completed.id, status: .completed)
            }
            clearClarificationState(for: completed.id)
            reloadState()
        } catch {
            guard !isLoopCancelled(cardId: executing.id) else { return }
            JotlyLog.tool.error("Auto execution failed: \(error.localizedDescription, privacy: .public)")
            updateDebugNode(cardId: executing.id, nodeId: "tool", state: .failed, detail: error.localizedDescription)
            updateDebugNode(cardId: executing.id, nodeId: "finish", state: .failed, detail: "执行失败")
            var failed: MemoryCard
            if requestContext.mode == .cardRevision, let originalCard = requestContext.cardSnapshot {
                failed = originalCard
                let failureMessage = "修改没有成功，原日程已保留。\(error.localizedDescription)"
                failed.message = failureMessage
                failed.completionMessage = failureMessage
                appendConversationMessage(role: .assistant, text: failureMessage, to: &failed)
            } else {
                failed = executing
                failed.status = .failed
                failed.message = error.localizedDescription
                failed.completionMessage = error.localizedDescription
                failed.options = []
            }
            failed.markUpdated()

            if let idx = cards.firstIndex(where: { $0.id == failed.id }) {
                cards[idx] = failed
            }
            statusText = "处理失败"
            try? store.upsertCard(failed)
            clearClarificationState(for: failed.id)
        }
    }

    private func resolvedPlans(for option: CardOption, card: MemoryCard) -> [AgentToolPlan] {
        let isReceiptConfirmation = card.type == "receipt"
            && (option.value.localizedStandardContains("confirm")
                || option.label.localizedStandardContains("确认创建"))
        if isReceiptConfirmation {
            let enabledPlans = card.children
                .filter { !$0.isIgnored }
                .flatMap(\.actions)
            if !enabledPlans.isEmpty {
                return enabledPlans
            }
        }

        if let actions = option.actions, !actions.isEmpty {
            return actions
        }

        if card.type == "receipt", option.label.localizedStandardContains("保存小票") {
            return [
                AgentToolPlan(tool: "memory.save", when: "now", params: [
                    "type": .string("receipt"),
                    "title": .string(card.title),
                    "content": .string(card.originalText)
                ])
            ]
        }

        if option.value == "record_only" || option.value.localizedStandardContains("仅记录") || option.label.localizedStandardContains("仅记录") {
            return [
                AgentToolPlan(tool: "memory.save", when: "now", params: [
                    "type": .string(card.type),
                    "title": .string(card.title),
                    "content": .string(card.originalText)
                ])
            ]
        }

        if
            let toolPlan = card.toolPlan,
            let matched = toolPlan.first(where: { $0.tool == option.value || $0.params["option_value"]?.stringValue == option.value })
        {
            return [AgentToolPlan(tool: matched.tool, when: "now", params: matched.params)]
        }

        return []
    }

    private func executeToolPlans(_ plans: [AgentToolPlan], card: MemoryCard) async throws -> [ToolDispatcher.ToolExecutionResult] {
        var results: [ToolDispatcher.ToolExecutionResult] = []
        for plan in plans {
            let executable = AgentToolPlan(tool: plan.tool, when: "now", params: plan.params)
            let result = try await toolDispatcher.execute(plan: executable, card: card)
            results.append(result)
        }
        return results
    }

    private func mergedMetadata(from results: [ToolDispatcher.ToolExecutionResult]) -> [String: String]? {
        var merged: [String: String] = [:]
        for metadata in results.compactMap(\.metadata) {
            merged.merge(metadata) { _, new in new }
        }
        return merged.isEmpty ? nil : merged
    }

    // A single model response can both create a system event and save a local record.
    // Keep the event metadata visible instead of letting the later record-only result hide it.
    private func preferredReminderInfo(from results: [ToolDispatcher.ToolExecutionResult]) -> CardReminderInfo? {
        let reminderInfos = results.compactMap(\.reminderInfo)
        return reminderInfos.last(where: { $0.type != "record" }) ?? reminderInfos.last
    }

    private func status(from value: String?) -> CardStatus? {
        guard let value else { return nil }
        return CardStatus(rawValue: value)
    }

    @MainActor
    private func continueAgentLoop(after option: CardOption, results: [ToolDispatcher.ToolExecutionResult], card: MemoryCard) async {
        let toolSummary = results.map(\.completionMessage).joined(separator: "\n")
        let requestContext = AgentRequestContext.optionContinue(card: card, lastExecutionResult: toolSummary)
        let loopText = """
        \(card.originalText)
        用户选择：\(option.label)
        已执行结果：\(toolSummary)
        请根据这个选择和执行结果判断下一步。
        """

        var decodedAnalysis: AgentAnalysis?
        do {
            updateDebugNode(cardId: card.id, nodeId: "model", state: .running, detail: "根据用户选择继续请求模型")
            let debugResponse = try await deepSeekClient.analyzeWithDebug(
                text: loopText,
                latestCardStatus: card.status,
                currentDate: DateFormatting.todayString(),
                model: selectedAgentModel,
                imageInputMode: card.imageInputMode,
                requestContext: requestContext,
                existingCards: cards
            )
            guard !isLoopCancelled(cardId: card.id) else { return }
            recordModelUsage(debugResponse)
            let analysis = normalizedAnalysis(debugResponse.analysis)
            decodedAnalysis = analysis
            updateDebugTurn(
                cardId: card.id,
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
                nodeDetail: "模型已返回下一轮判断"
            )
            updateDebugNode(cardId: card.id, nodeId: "decode", state: .completed, detail: "下一轮 JSON 已解析：\(analysis.intent)")

            try await handleAgentAnalysis(analysis, on: card, requestContext: requestContext)
        } catch {
            guard !isLoopCancelled(cardId: card.id) else { return }
            if let analysis = decodedAnalysis {
                let detail = "结果已解析，但卡片更新失败：\(error.localizedDescription)"
                var failed = makeAgentResultCard(
                    from: analysis,
                    reusing: card,
                    requestContext: requestContext,
                    originalStatus: card.status
                )
                failed.status = card.status
                failed.message = "\(analysis.message)\n\n\(detail)"
                failed.completionMessage = failed.message
                appendConversationMessage(role: .assistant, text: failed.message, to: &failed)
                failed.markUpdated()
                if let idx = cards.firstIndex(where: { $0.id == failed.id }) {
                    cards[idx] = failed
                }
                statusText = "结果暂未保存"
                updateDebugNode(cardId: card.id, nodeId: "decode", state: .completed, detail: "下一轮 JSON 已解析：\(analysis.intent)")
                updateDebugNode(cardId: card.id, nodeId: "finish", state: .failed, detail: detail)
                return
            }
            let rawOutput = rawModelOutput(from: error)
            if let rawOutput {
                updateDebugTurn(
                    cardId: card.id,
                    modelOutput: rawOutput,
                    decodedSummary: "下一轮模型输出不是有效 JSON"
                )
            }
            let failureStage = agentFailureStage(for: error, current: .modelRequest)
            updateDebugNode(
                cardId: card.id,
                nodeId: failureStage == .decode ? "decode" : "model",
                state: .failed,
                detail: error.localizedDescription
            )
            var failed = card
            failed.status = .failed
            failed.message = error.localizedDescription
            failed.completionMessage = error.localizedDescription
            failed.markUpdated()
            if let idx = cards.firstIndex(where: { $0.id == failed.id }) {
                cards[idx] = failed
            }
            statusText = "处理失败"
            try? store.upsertCard(failed)
        }
    }

    private func fallbackActionValue(for analysis: AgentAnalysis, card: MemoryCard) -> String? {
        if analysis.cardType == "record" {
            return "record_only"
        }
        if analysis.cardType == "countdown" || analysis.intent.contains("countdown") {
            return "create_countdown"
        }
        if analysis.cardType == "habit" || analysis.intent.contains("habit") {
            return "create_habit"
        }
        return "default_execute"
    }

    private func shouldRequireInitialConfirmation(
        _ analysis: AgentAnalysis,
        requestContext: AgentRequestContext
    ) -> Bool {
        guard requestContext.mode == .newCard else { return false }
        if analysis.cardType == "birthday" { return true }
        let externalTools: Set<String> = [
            "create_solar_birthday_reminder",
            "reminder.create_solar_birthday",
            "create_lunar_birthday_reminder",
            "reminder.create_lunar_birthday",
            "lunar_series.create",
            "create_date_reminder",
            "create_reminder",
            "reminder.create",
            "calendar.create_event",
            "notification.schedule",
            "family_holiday_reminders.create"
        ]
        if analysis.toolPlan?.contains(where: { externalTools.contains($0.tool) }) == true {
            return true
        }
        return analysis.options.contains { option in
            if option.actions?.contains(where: { externalTools.contains($0.tool) }) == true {
                return true
            }
            return option.actionButtons?.contains { button in
                button.actions.contains { externalTools.contains($0.tool) }
            } == true
        }
    }

    private func normalizedAnalysis(_ analysis: AgentAnalysis) -> AgentAnalysis {
        return analysis
    }

    private func makeAgentResultCard(
        from analysis: AgentAnalysis,
        reusing card: MemoryCard,
        requestContext: AgentRequestContext,
        originalStatus: CardStatus
    ) -> MemoryCard {
        guard requestContext.mode != .newCard, analysis.cardType == "reply" else {
            return analysis.makeCard(reusing: card)
        }

        var updated = requestContext.cardSnapshot ?? card
        updated.status = originalStatus == .processing ? .completed : originalStatus
        updated.message = analysis.message
        updated.completionMessage = updated.status == .waitingConfirmation ? nil : analysis.message
        if let polished = analysis.optimizedUserText, !polished.isEmpty {
            updated.originalText = polished
        }
        if let changeNote = analysis.changeNote, !changeNote.isEmpty {
            updated.changeNote = changeNote
            updated.isUpdated = true
        }
        updated.markUpdated()
        return updated
    }

    private func agentFailureStage(
        for error: Error,
        current: AgentProcessingStage
    ) -> AgentProcessingStage {
        switch error {
        case JotlyError.invalidDeepSeekResponse, JotlyError.invalidDeepSeekResponseWithRaw:
            return .decode
        default:
            return current
        }
    }

    private func makeConfirmationCard(from analysis: AgentAnalysis, reusing card: MemoryCard) -> MemoryCard {
        var updated = analysis.makeCard(reusing: card)
        updated.status = .waitingConfirmation
        updated.completionMessage = nil
        updated.selectedOptionValue = nil
        if updated.type == "birthday", updated.options.isEmpty {
            updated.options = AgentAnalysis.birthdayOptions()
        } else {
            updated.options = uniqueOptions(updated.options)
        }
        updated.markUpdated()
        return updated
    }

    private func insertDerivedCards(from analysis: AgentAnalysis, parent: MemoryCard, status: CardStatus) {
        guard let derivedCards = analysis.derivedCards else { return }
        for (index, derivedCard) in derivedCards.enumerated() {
            let child = makeDerivedCard(from: derivedCard, parent: parent, index: index, status: status)
            if let parentIndex = cards.firstIndex(where: { $0.id == parent.id }) {
                cards.insert(child, at: parentIndex + 1 + index)
            } else {
                cards.append(child)
            }
            try? store.upsertCard(child)
        }
    }

    private func makeDerivedCard(from derivedCard: AgentCard, parent: MemoryCard, index: Int, status: CardStatus) -> MemoryCard {
        let targetDateStr = derivedCard.type == "countdown" ? derivedCard.metadata?["target_date"] : nil
        var child = MemoryCard(
            id: "\(parent.id)_child_\(index)",
            type: derivedCard.type,
            title: derivedCard.title,
            status: status,
            originalText: parent.originalText,
            summary: derivedCard.summary,
            message: derivedCard.message,
            completionMessage: nil,
            options: [],
            entities: nil,
            supplementalText: nil,
            toolCandidates: [],
            selectedOptionValue: nil,
            reminderInfo: nil,
            toolPlan: nil,
            metadata: derivedCard.metadata,
            imageInputMode: parent.imageInputMode,
            conversationMessages: [],
            createdAt: Date(),
            updatedAt: Date(),
            cardBody: derivedCard.message,
            attributes: derivedCard.attributes,
            metrics: derivedCard.metrics,
            backgroundStyle: derivedCard.backgroundStyle ?? .plain,
            backgroundSemantic: derivedCard.backgroundSemantic,
            children: derivedCard.children,
            userVisibleInput: parent.userVisibleInput
        )
        child.parentId = parent.id
        child.targetDateString = targetDateStr
        applyHabitDefaultsIfNeeded(to: &child, appendTodayIfMissing: false)
        return child
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

    private func uniqueOptions(_ options: [CardOption]) -> [CardOption] {
        var seenKeys = Set<String>()
        var seenValues = Set<String>()
        return options.filter { option in
            let isNew = !seenKeys.contains(option.key) && !seenValues.contains(option.value)
            seenKeys.insert(option.key)
            seenValues.insert(option.value)
            return isNew
        }
    }

    private func clearClarificationState(for cardId: String? = nil) {
        if let cardId, activeClarificationCardID != cardId {
            return
        }
        activeClarificationCardID = nil
        clarificationDraftText = ""
    }

    private func executingMessage(for option: CardOption) -> String {
        let toolName = option.actions?.first?.tool ?? option.value
        let isLunar = option.actions?.first?.params["calendar_type"]?.stringValue == "lunar" || option.actions?.first?.params["lunar_month"] != nil
        let isBirthday = option.actions?.first?.params["is_birthday"]?.boolValue == true
            || option.actions?.first?.params["is_birthday"]?.stringValue == "true"
            || option.actions?.first?.params["person_name"] != nil
            || (option.actions?.first?.params["title"]?.stringValue?.localizedStandardContains("生日") ?? false)
            || toolName.contains("birthday")

        switch toolName {
        case "record_only":
            return "正在保存普通记录"
        case "create_date_reminder", "create_reminder", "reminder.create":
            return "正在创建日期提醒"
        case "calendar.create_event":
            if isBirthday {
                return isLunar ? "正在保存农历生日提醒" : "正在为你创建生日提醒"
            }
            return isLunar ? "正在保存农历日程事件" : "正在创建日程事件"
        case "create_solar_birthday_reminder":
            return "正在为你创建生日提醒"
        case "create_lunar_birthday_reminder":
            return "正在保存农历生日提醒"
        default:
            return "正在处理你的选择"
        }
    }

    private func holdVoiceCapture() {
        guard isRecording || isVoiceCaptureActive else { return }
        pressArmed = false
        isVoiceHoldLocked = true
        isVoiceCaptureActive = true
        isRecording = true
        voiceReleaseAction = .hold
        voiceDragTranslation = .zero
        statusText = "已挂住，继续说话"
    }

    private func resolvedVoiceReleaseAction(for translation: CGSize) -> VoiceReleaseAction {
        let finger = CGPoint(x: translation.width, y: translation.height)
        let distanceToCenter = sqrt(finger.x * finger.x + finger.y * finger.y)

        // 1. 中心死区：位移不足 60pt 时一律判定为“松手发送”
        if distanceToCenter < 60 {
            return .send
        }

        // 2. 精确计算到目标按钮物理中心的距离 (相对于拖拽起点，向上滑动 Y 为负值)
        let cancelTarget = CGPoint(x: -118, y: -60)
        let holdTarget = CGPoint(x: 0, y: -112)
        let editTarget = CGPoint(x: 118, y: -60)

        let dCancel = sqrt(pow(finger.x - cancelTarget.x, 2) + pow(finger.y - cancelTarget.y, 2))
        let dHold = sqrt(pow(finger.x - holdTarget.x, 2) + pow(finger.y - holdTarget.y, 2))
        let dEdit = sqrt(pow(finger.x - editTarget.x, 2) + pow(finger.y - editTarget.y, 2))

        // 3. 极其宽松的判定触碰半径 (65pt)，只要手指稍微摸到或掠过按钮边缘即可触发，无需强行指到中心点
        if dCancel < 65 {
            return .cancel
        } else if dHold < 65 {
            return .hold
        } else if dEdit < 65 {
            return .edit
        }

        return .send
    }

    private func resolvedImageVoiceReleaseAction(for translation: CGSize) -> VoiceReleaseAction {
        let finger = CGPoint(x: translation.width, y: translation.height)
        let distanceToCenter = sqrt(finger.x * finger.x + finger.y * finger.y)

        if distanceToCenter < 58 {
            return .send
        }

        let cancelTarget = CGPoint(x: -96, y: -70)
        let holdTarget = CGPoint(x: 96, y: -70)
        let dCancel = sqrt(pow(finger.x - cancelTarget.x, 2) + pow(finger.y - cancelTarget.y, 2))
        let dHold = sqrt(pow(finger.x - holdTarget.x, 2) + pow(finger.y - holdTarget.y, 2))

        if dCancel < 70 {
            return .cancel
        } else if dHold < 70 {
            return .hold
        }

        return .send
    }

    private func triggerHoldHaptic() {
        // 先触发一个轻震
        let lightGenerator = UIImpactFeedbackGenerator(style: .light)
        lightGenerator.prepare()
        lightGenerator.impactOccurred()

        // 延迟 80ms 后，触发一个重震，形成“先轻后重”的段落式双重机械按键触感
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000)
            let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
            heavyGenerator.prepare()
            heavyGenerator.impactOccurred()
        }
    }

    func toggleHabitCheckIn(cardId: String, dateStr: String) {
        guard let index = cards.firstIndex(where: { $0.id == cardId }) else { return }
        var card = cards[index]
        guard card.type == "habit" else { return }

        var dates = card.habitCheckInDates ?? []
        let currentCount = dates.filter { $0 == dateStr }.count

        // Remove all instances of dateStr
        dates.removeAll(where: { $0 == dateStr })

        // Cycle: 0 -> 1 -> 2 -> 3 -> 0
        let newCount = (currentCount + 1) % 4
        for _ in 0..<newCount {
            dates.append(dateStr)
        }

        card.habitCheckInDates = dates
        card.markUpdated()
        cards[index] = card
        try? store.upsertCard(card)

        JotlyLog.storage.info("Toggled habit check-in for \(cardId, privacy: .public) on \(dateStr, privacy: .public), newCount=\(newCount, privacy: .public)")
    }

    private func updateChildrenStatus(for parentId: String, status: CardStatus) {
        for idx in cards.indices {
            if cards[idx].parentId == parentId {
                cards[idx].status = status
                try? store.upsertCard(cards[idx])
            }
        }
    }
}
