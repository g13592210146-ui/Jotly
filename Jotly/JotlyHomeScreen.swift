import Combine
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

// MARK: - 主屏幕

struct JotlyHomeScreen: View {
    @StateObject private var model = JotlyHomeViewModel()
    @AppStorage("app_experience_mode") private var experienceModeRaw = AppExperienceMode.regular.rawValue
    @FocusState private var isTextFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    @State private var showProfilePage = false
    @State private var showAddContentSheet = false
    @State private var isAddContentPanelExpanded = false
    @State private var addContentPanelDragOffset: CGFloat = 0
    @State private var addContentSelectedImages: [UIImage] = []
    @State private var showCameraUnavailableAlert = false
    @State private var showCameraSheet = false
    @State private var safeAreaBottom: CGFloat = 0

    @State private var showDeleteConfirmation = false
    @State private var cardToDelete: MemoryCard? = nil
    @State private var revealedDeleteCardID: String? = nil
    @State private var showFullScreenEditor = false
    @State private var selectedDebugPrompt: AgentDebugTurn? = nil
    @State private var selectedModelOutput: AgentDebugTurn? = nil
    @State private var isCardListScrolling = false
    @State private var selectedDebugCardID: String? = nil

    var body: some View {
        NavigationStack {
            rootContent
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        if isTextFocused {
                            isTextFocused = false
                        }
                    }
            )
            .background(
                LegacySafeAreaBottomReader { newValue in
                    safeAreaBottom = newValue
                }
            )
            .navigationDestination(isPresented: $showProfilePage) {
                LegacyProfilePlaceholderView()
            }
            .navigationDestination(item: $selectedDebugPrompt) { turn in
                LegacyPromptDetailView(turn: turn)
            }
            .navigationDestination(item: $selectedModelOutput) { turn in
                LegacyModelOutputDetailView(turn: turn)
            }
            .navigationDestination(item: $selectedDebugCardID) { cardID in
                if let card = model.cards.first(where: { $0.id == cardID }) {
                    CardDebugHistoryView(card: card, turns: model.debugTurns.filter { $0.cardId == cardID })
                } else {
                    ContentUnavailableView("卡片不存在", systemImage: "rectangle.slash")
                }
            }
            .alert(
                "删除这张卡片？",
                isPresented: $showDeleteConfirmation,
            ) {
                Button("删除", role: .destructive) {
                    confirmDeleteCard()
                }

                Button("取消", role: .cancel) {
                    cardToDelete = nil
                    revealedDeleteCardID = nil
                }
            } message: {
                Text(deleteConfirmationMessage)
            }
            .onChange(of: showDeleteConfirmation) { _, newValue in
                if !newValue {
                    cardToDelete = nil
                    revealedDeleteCardID = nil
                }
            }
            .sheet(isPresented: $showCameraSheet) {
                LegacyCameraPicker(onImagePick: model.insertImage)
                    .ignoresSafeArea()
            }
            .alert("相机不可用", isPresented: $showCameraUnavailableAlert) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("当前设备没有可用的相机。模拟器里会出现这个提示。")
            }

            .sheet(isPresented: $showFullScreenEditor) {
                LegacyFullScreenEditorView(
                    text: $model.editorText,
                    onDelete: {
                        showFullScreenEditor = false
                        model.deleteEditorText()
                    },
                    onSend: {
                        showFullScreenEditor = false
                        model.submitEditorText()
                    },
                    onStash: {
                        showFullScreenEditor = false
                        model.saveEditorAsCard()
                    }
                )
            }
            .onChange(of: model.textInputFocusToken) { _, _ in
                isTextFocused = true
            }
            .onChange(of: model.inputMode) { _, newValue in
                handleInputModeChange(newValue)
            }
            .onChange(of: scenePhase) { _, newPhase in
                handleScenePhaseChange(newPhase)
            }
            .onChange(of: experienceModeRaw) { _, newValue in
                if newValue == AppExperienceMode.regular.rawValue {
                    model.displayMode = .cards
                }
            }
        }
        .preferredColorScheme(.light)
    }

    private var rootContent: some View {
        ZStack(alignment: .bottom) {
            LegacyHomeBackground()
            switch isDeveloperMode ? model.displayMode : .cards {
            case .cards:
                cardList
            case .conversation:
                debugConversationList
            case .flow:
                debugFlowList
            }
            bottomAttachmentLayer
            voiceOverlay
        }
    }

    private var bottomAttachmentLayer: some View {
        ZStack(alignment: .bottom) {
            addContentPanel
            bottomDock
        }
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .zIndex(6)
    }

    @ViewBuilder
    private var addContentPanel: some View {
        if showAddContentSheet {
            LegacyPhotoComposerSheet(
                isRecording: model.isRecording,
                voiceAmplitude: model.voiceAmplitude,
                liveTranscript: model.liveTranscript,
                voiceReleaseAction: model.voiceReleaseAction,
                onSelectionImagesChanged: { images in
                    addContentSelectedImages = images
                }
            )
            .frame(height: addContentPanelHeight + bottomSafeAreaInset)
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: 30,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: 30,
                    style: .continuous
                )
            )
            .shadow(color: Color.black.opacity(0.14), radius: 24, y: -8)
            .padding(.bottom, -bottomSafeAreaInset)
            .offset(y: addContentPanelDragOffset)
            .overlay(alignment: .top) {
                Color.clear
                    .frame(height: 58)
                    .contentShape(Rectangle())
                    .gesture(addContentPanelDragGesture)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var bottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .safeAreaInsets.bottom ?? 0
    }

    private var addContentPanelHeight: CGFloat {
        let screenHeight = UIScreen.main.bounds.height
        return isAddContentPanelExpanded
            ? min(screenHeight * 0.78, 700)
            : min(screenHeight * 0.46, 420)
    }

    private var addContentPanelDragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if value.translation.height > 0 {
                    addContentPanelDragOffset = min(value.translation.height, 120)
                }
            }
            .onEnded { value in
                if value.translation.height > 220 {
                    closeAddContentPanel()
                } else if isAddContentPanelExpanded, value.translation.height > 130 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.84)) {
                        isAddContentPanelExpanded = false
                        addContentPanelDragOffset = 0
                    }
                } else if value.translation.height < -50 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.84)) {
                        isAddContentPanelExpanded = true
                        addContentPanelDragOffset = 0
                    }
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        addContentPanelDragOffset = 0
                    }
                }
            }
    }

    private var cardList: some View {
        List {
            headerRow
            filterSelectorRow
            cardRows
            bottomSpacerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .interacting, .decelerating, .animating:
                isCardListScrolling = true
            case .idle, .tracking:
                isCardListScrolling = false
            }
        }
        // 卡片长按录音期间由卡片手势独占纵向移动，避免列表跟手滚动。
        .scrollDisabled(model.isVoiceCaptureActive && model.activeCardVoiceCaptureCardID != nil)
    }

    private var headerRow: some View {
        LegacyHomeHeader(
            asrProvider: $model.asrProvider,
            displayMode: $model.displayMode,
            selectedAgentModel: $model.selectedAgentModel,
            imageInputMode: $model.imageInputMode,
            modelPriceSummary: model.selectedModelPriceSummary,
            modelCostText: model.modelCostText,
            supportsDirectImageInput: model.selectedAgentModel.supportsDirectImageInput,
            isDeveloperMode: isDeveloperMode
        ) {
            showProfilePage = true
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16))
    }

    private var isDeveloperMode: Bool {
        experienceModeRaw == AppExperienceMode.developer.rawValue
    }

    private var filterSelectorRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(JotlyHomeViewModel.FilterCategory.allCases) { category in
                    let isSelected = model.selectedCategory == category
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.76)) {
                            model.selectedCategory = category
                        }
                    }) {
                        Text(category.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium, design: .rounded))
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            .foregroundStyle(isSelected ? Color.white : Color(white: 0.35))
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.blue.opacity(0.85) : Color(white: 0.94))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(isSelected ? Color.blue.opacity(0.1) : Color.black.opacity(0.04), lineWidth: 0.8)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 22)
        .padding(.vertical, 8)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets())
    }

    private var cardRows: some View {
        Group {
            if model.selectedCategory == .all
                || model.selectedCategory == .subscription
                || model.selectedCategory == .asset {
                ForEach(model.displayedCards) { card in
                    cardRow(for: card)
                        .onAppear {
                            model.loadMoreCardsIfNeeded(visibleCardID: card.id)
                        }
                }
            } else {
                let pairs = model.displayedCards.chunked(into: 2)
                ForEach(0..<pairs.count, id: \.self) { pairIndex in
                    let pair = pairs[pairIndex]
                    HStack(spacing: 14) {
                        ForEach(pair) { card in
                            SquareCardView(
                                card: card,
                                revealedDeleteCardID: $revealedDeleteCardID,
                                isVoiceCaptureActive: model.isVoiceCaptureActive,
                                onToggleHabitDate: { dateStr in
                                    model.toggleHabitCheckIn(cardId: card.id, dateStr: dateStr)
                                },
                                onDelete: {
                                    cardToDelete = card
                                    showDeleteConfirmation = true
                                },
                                onDebugTap: {
                                    selectedDebugCardID = card.id
                                }
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: 142)
                        }
                        if pair.count < 2 {
                            Spacer()
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 22, bottom: 7, trailing: 22))
                }
            }
        }
    }

    @ViewBuilder
    private func cardRow(for card: MemoryCard) -> some View {
        if card.id != "card_idle" {
            VStack(spacing: 12) {
                // Render parent card
                CardListRow(
                    card: card,
                    revealedDeleteCardID: $revealedDeleteCardID,
                    onSelectOption: { option in
                        model.selectOption(option, for: card.id)
                    },
                    onDelete: {
                        model.deleteCard(id: card.id)
                    },
                    onDraftTap: {
                        model.openDraftCard()
                        showFullScreenEditor = true
                    },
                    onSwipeDelete: {
                        cardToDelete = card
                        showDeleteConfirmation = true
                    },
                    onDebugTap: {
                        selectedDebugCardID = card.id
                    },
                    activeVoiceCaptureCardID: model.activeCardVoiceCaptureCardID,
                    voiceAmplitude: model.voiceAmplitude,
                    liveTranscript: model.liveTranscript,
                    isVoiceCaptureActive: model.isVoiceCaptureActive,
                    isListScrolling: isCardListScrolling,
                    onBeginCardVoiceCapture: {
                        model.beginCardVoiceCapture(cardId: card.id)
                    },
                    onEndCardVoiceCapture: {
                        if let outcome = model.finishVoiceCaptureForCurrentAction() {
                            handleVoiceCompletion(outcome)
                        }
                    },
                    onCancelCardVoiceCapture: {
                        model.cancelVoiceCaptureOnInterrupt()
                    },
                    onToggleHabitDate: { dateStr in
                        model.toggleHabitCheckIn(cardId: card.id, dateStr: dateStr)
                    },
                    onToggleReceiptChildIgnored: { childID in
                        model.toggleReceiptChildIgnored(cardId: card.id, childId: childID)
                    }
                )
                
                // Render child cards if in .all mode and they exist
                if model.selectedCategory == .all {
                    let children = model.cards.filter { $0.parentId == card.id }
                    if !children.isEmpty {
                        HStack(alignment: .center, spacing: 0) {
                            // Visual connecting line
                            VStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.blue.opacity(0.35))
                                    .frame(width: 2.2)
                                    .padding(.vertical, 4)
                            }
                            .frame(width: 44) // Perfect alignment
                            
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(children) { child in
                                        SquareCardView(
                                            card: child,
                                            revealedDeleteCardID: $revealedDeleteCardID,
                                            isVoiceCaptureActive: model.isVoiceCaptureActive,
                                            onToggleHabitDate: { dateStr in
                                                model.toggleHabitCheckIn(cardId: child.id, dateStr: dateStr)
                                            },
                                            onDelete: {
                                                cardToDelete = child
                                                showDeleteConfirmation = true
                                            },
                                            onDebugTap: {
                                                selectedDebugCardID = child.id
                                            }
                                        )
                                        .frame(width: 142, height: 142)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 7, leading: 22, bottom: 7, trailing: 22))
        } else {
            TaskCardView(
                card: card,
                onSelectOption: { option in
                    model.selectOption(option, for: card.id)
                },
                onDelete: {},
                activeVoiceCaptureCardID: model.activeCardVoiceCaptureCardID,
                voiceAmplitude: model.voiceAmplitude,
                liveTranscript: model.liveTranscript,
                isVoiceCaptureActive: model.isVoiceCaptureActive,
                isListScrolling: false,
                onBeginCardVoiceCapture: {
                    model.beginCardVoiceCapture(cardId: card.id)
                },
                onEndCardVoiceCapture: {
                    if let outcome = model.finishVoiceCaptureForCurrentAction() {
                        handleVoiceCompletion(outcome)
                    }
                },
                onCancelCardVoiceCapture: {
                    model.cancelVoiceCaptureOnInterrupt()
                },
                onToggleHabitDate: nil,
                onToggleReceiptChildIgnored: { childID in
                    model.toggleReceiptChildIgnored(cardId: card.id, childId: childID)
                }
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 7, leading: 22, bottom: 7, trailing: 22))
        }
    }

    private var bottomSpacerRow: some View {
        Color.clear
            .frame(height: 240)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
    }

    private var debugConversationList: some View {
        List {
            headerRow
            if model.debugTurns.isEmpty {
                LegacyDebugEmptyStateView(
                    title: "还没有对话调试信息",
                    message: "说一句话后，这里会显示用户输入、完整 prompt 和模型原始输出。"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 18, leading: 22, bottom: 8, trailing: 22))
            } else {
                ForEach(model.debugTurns) { turn in
                    DebugConversationRow(turn: turn, onPromptTap: {
                        selectedDebugPrompt = turn
                    }, onModelOutputTap: {
                        selectedModelOutput = turn
                    })
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 7, leading: 22, bottom: 7, trailing: 22))
                }
            }
            bottomSpacerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }

    private var debugFlowList: some View {
        List {
            headerRow
            if model.debugTurns.isEmpty {
                LegacyDebugEmptyStateView(
                    title: "还没有流程节点",
                    message: "每次对话后，这里会实时回显输入、模型判断、确认、工具执行和最终反馈。"
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 18, leading: 22, bottom: 8, trailing: 22))
            } else {
                ForEach(model.debugTurns) { turn in
                    LegacyDebugFlowRow(turn: turn)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 7, leading: 22, bottom: 7, trailing: 22))
                }
            }
            bottomSpacerRow
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var voiceOverlay: some View {
        if model.isComposerVoiceCaptureActive && !model.isImageVoiceCaptureActive {
            VoiceCaptureOverlay(
                model: model,
                dragTranslation: model.voiceDragTranslation,
                onVoiceCompletion: handleVoiceCompletion
            )
            .ignoresSafeArea()
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .animation(.spring(response: 0.35, dampingFraction: 0.82), value: model.isComposerVoiceCaptureActive)
            .zIndex(3)
        }
    }

    private var deleteConfirmationMessage: String {
        let title = cardToDelete?.title ?? "这张卡片"
        return "删除后会从列表和本地记录中移除「\(title)」。"
    }

    private func confirmDeleteCard() {
        guard let card = cardToDelete else { return }

        model.deleteCard(id: card.id)
        cardToDelete = nil
        revealedDeleteCardID = nil
    }

    private func handleCameraTap() {
        closeAddContentPanel()
        if model.isCameraAvailable {
            showCameraSheet = true
        } else {
            showCameraUnavailableAlert = true
        }
    }

    private func toggleMode() {
        guard !model.isRecording else { return }
        if model.inputMode == .voice {
            closeAddContentPanel()
        }
        isTextFocused = false
        model.toggleInputMode()
    }

    private func handleInputModeChange(_ newValue: JotlyHomeViewModel.InputMode) {
        if newValue == .voice {
            isTextFocused = false
        } else {
            closeAddContentPanel()
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        if newPhase == .background || newPhase == .inactive {
            model.cancelVoiceCaptureOnInterrupt()
        } else if newPhase == .active {
            model.reloadState()
        }
    }

    private var bottomDock: some View {
        ComposerDock(
            mode: model.inputMode,
            isRecording: model.isRecording,
            draftTextSeed: model.draftText,
            isTextFocused: $isTextFocused,
            addIcon: addDockIcon,
            onCameraTap: handleCameraTap,
            onVoicePressBegin: beginVoicePress,
            onVoiceDragChanged: handleVoiceDragChanged,
            onVoiceRelease: endVoicePress,
            onModeToggle: toggleMode,
            onTextSubmit: { text in
                model.submitDraftText(text)
            },
            onAddTap: handleAddTap
        )
        .padding(.horizontal, 22)
        .padding(.bottom, bottomDockBottomPadding)
        .opacity((model.isComposerVoiceCaptureActive && !model.isImageVoiceCaptureActive) ? 0.0 : 1.0)
        .animation(.easeOut(duration: 0.2), value: model.isComposerVoiceCaptureActive)
        .animation(.spring(response: 0.35, dampingFraction: 0.84), value: showAddContentSheet)
    }

    private var bottomDockBottomPadding: CGFloat {
        isTextFocused ? 8 : 6
    }

    private func beginVoicePress() {
        if showAddContentSheet, !addContentSelectedImages.isEmpty {
            model.beginImageVoiceCapture(images: addContentSelectedImages)
            return
        }
        model.beginVoiceCapture()
    }

    private func handleVoiceDragChanged(_ translation: CGSize) {
        if showAddContentSheet, model.isImageVoiceCaptureActive {
            model.updateImageVoiceDrag(translation: translation)
        } else {
            model.updateVoiceDrag(translation: translation)
        }
    }

    private func endVoicePress() {
        if showAddContentSheet, model.isImageVoiceCaptureActive {
            let shouldClose = model.finishImageVoiceCaptureForCurrentAction()
            if shouldClose {
                closeAddContentPanel()
            }
            return
        }
        if let outcome = model.finishVoiceCaptureForCurrentAction() {
            handleVoiceCompletion(outcome)
        }
    }

    private var addDockIcon: String {
        showAddContentSheet && !addContentSelectedImages.isEmpty ? "paperplane.fill" : "plus"
    }

    private func handleAddTap() {
        if showAddContentSheet, !addContentSelectedImages.isEmpty {
            model.submitImages(addContentSelectedImages)
            closeAddContentPanel()
            return
        }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
            isTextFocused = false
            showAddContentSheet.toggle()
            if !showAddContentSheet {
                isAddContentPanelExpanded = false
                addContentPanelDragOffset = 0
                addContentSelectedImages = []
            }
        }
    }

    private func closeAddContentPanel() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            showAddContentSheet = false
            isAddContentPanelExpanded = false
            addContentPanelDragOffset = 0
            addContentSelectedImages = []
        }
    }

    private func handleVoiceCompletion(_ outcome: JotlyHomeViewModel.VoiceCompletionResult) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)

            switch outcome {
            case .insertIntoTextField(let text):
                closeAddContentPanel()
                model.activateTextInput(overwriting: text)
            case .openFullEditor(let text):
                closeAddContentPanel()
                model.prepareEditor(with: text, linkedDraftCard: false)
                showFullScreenEditor = true
            }
        }
    }
}

// MARK: - 背景

struct LegacyHomeBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.98, green: 0.97, blue: 0.94),
                    Color(red: 0.95, green: 0.98, blue: 1.00),
                    Color(red: 0.97, green: 0.95, blue: 0.92)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color(red: 0.97, green: 0.89, blue: 0.74).opacity(0.22))
                .frame(width: 320, height: 320)
                .blur(radius: 42)
                .offset(x: -120, y: -220)

            Circle()
                .fill(Color(red: 0.80, green: 0.88, blue: 0.98).opacity(0.28))
                .frame(width: 380, height: 380)
                .blur(radius: 60)
                .offset(x: 170, y: 340)

            LegacyArcWaveShape()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.73, green: 0.86, blue: 0.96).opacity(0.45),
                            Color.white.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(height: 300)
                .offset(y: 320)
                .blur(radius: 4)
        }
    }
}

struct LegacyArcWaveShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.height * 0.18))
        path.addCurve(
            to: CGPoint(x: rect.width, y: rect.height * 0.48),
            control1: CGPoint(x: rect.width * 0.18, y: 0),
            control2: CGPoint(x: rect.width * 0.56, y: rect.height * 0.26)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - 顶部 Header

struct LegacyHomeHeader: View {
    @Binding var asrProvider: JotlyHomeViewModel.ASRProvider
    @Binding var displayMode: JotlyHomeViewModel.HomeDisplayMode
    @Binding var selectedAgentModel: LifeAgentLLMModel
    @Binding var imageInputMode: ImageInputMode
    let modelPriceSummary: String
    let modelCostText: String
    let supportsDirectImageInput: Bool
    let isDeveloperMode: Bool
    let onAvatarTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("今天想记点什么？")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.12))
                        .minimumScaleFactor(0.78)

                    Text("说一句话，我帮你整理成卡片")
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(Color(white: 0.35))
                }

                Spacer(minLength: 12)

                Button(action: onAvatarTap) {
                    Image(systemName: "person")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(white: 0.25))
                        .frame(width: 44, height: 44)
                        .legacyGlassCircleSurface(size: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("个人页")
            }

            if isDeveloperMode {
            HStack(spacing: 10) {
                Menu {
                    ForEach(JotlyHomeViewModel.ASRProvider.allCases) { provider in
                        Button {
                            asrProvider = provider
                        } label: {
                            Label(provider.title, systemImage: provider == asrProvider ? "checkmark" : "waveform")
                        }
                    }
                } label: {
                    dropdownPill(title: "语音", value: asrProvider.title)
                }
                .accessibilityLabel("语音识别服务")

                Menu {
                    ForEach(LifeAgentLLMModel.allCases) { model in
                        Button {
                            selectedAgentModel = model
                        } label: {
                            Label(model.title, systemImage: model == selectedAgentModel ? "checkmark" : "brain")
                        }
                    }
                } label: {
                    dropdownPill(title: "模型", value: selectedAgentModel.title)
                }
                .accessibilityLabel("模型服务")
            }

            Text("\(selectedAgentModel.providerTitle) · \(modelPriceSummary) · \(modelCostText)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.42))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("图片输入")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.44))

                HStack(spacing: 8) {
                    imageModeButton(
                        title: ImageInputMode.ocr.title,
                        isSelected: imageInputMode == .ocr,
                        isEnabled: true
                    ) {
                        imageInputMode = .ocr
                    }

                    imageModeButton(
                        title: ImageInputMode.directModel.title,
                        isSelected: imageInputMode == .directModel,
                        isEnabled: supportsDirectImageInput
                    ) {
                        imageInputMode = .directModel
                    }
                }

                Text(supportsDirectImageInput ? "Qwen 可直传图片，其他模型自动回落到 OCR" : "当前模型不支持图片直传，只能先做本地 OCR")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.52))
                    .lineLimit(2)
            }

            Picker("显示模式", selection: $displayMode) {
                ForEach(JotlyHomeViewModel.HomeDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("显示模式")
            }
        }
    }

    private func dropdownPill(title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.45))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.16))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color(white: 0.42))
        }
        .padding(.horizontal, 13)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .background(
            Capsule()
                .fill(.white.opacity(0.58))
                .overlay(
                    Capsule()
                        .stroke(.white.opacity(0.7), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 12, x: 0, y: 6)
        )
    }

    private func imageModeButton(
        title: String,
        isSelected: Bool,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isEnabled ? (isSelected ? Color.white : Color(white: 0.18)) : Color(white: 0.65))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    Capsule()
                        .fill(isSelected && isEnabled ? Color.black.opacity(0.88) : Color.white.opacity(0.62))
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected && isEnabled ? Color.black.opacity(0.08) : Color.white.opacity(0.72),
                                    lineWidth: 1
                                )
                        )
                )
                .opacity(isEnabled ? 1.0 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

// MARK: - 调试视图

struct LegacyDebugEmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.12))
            Text(message)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.42))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .legacyCardStyle(isDraft: false, cornerRadius: 24)
    }
}

struct LegacyDebugConversationRow: View {
    let turn: AgentDebugTurn
    let onPromptTap: () -> Void
    let onModelOutputTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("对话调试")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.45))
                Spacer()
                Text(DateFormatting.debugTimeString(from: turn.createdAt))
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.55))
            }

            LegacyDebugMessageBlock(title: "用户输入", text: turn.userText, tint: .blue)

            if !turn.modelName.isEmpty {
                LegacyDebugMessageBlock(title: "请求模型", text: turn.modelName, tint: .purple)
            }

            HStack(spacing: 12) {
                Button(action: onPromptTap) {
                    HStack {
                        Image(systemName: "doc.text.magnifyingglass")
                        Text("查看提示词")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.16))
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.62))
                    )
                }
                .buttonStyle(.plain)

                Button(action: onModelOutputTap) {
                    HStack {
                        Image(systemName: "curlybraces")
                        Text("查看原始输出")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.16))
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white.opacity(0.62))
                    )
                }
                .buttonStyle(.plain)
            }

            LegacyDebugMessageBlock(
                title: "模型输出 (点击查看完整)",
                text: turn.modelOutput.isEmpty ? "等待模型返回..." : turn.modelOutput,
                tint: .green,
                lineLimit: 10
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onModelOutputTap()
            }

            if !turn.decodedSummary.isEmpty {
                LegacyDebugMessageBlock(title: "解析摘要", text: turn.decodedSummary, tint: .orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .legacyCardStyle(isDraft: false, cornerRadius: 24)
    }
}

struct LegacyDebugMessageBlock: View {
    let title: String
    let text: String
    let tint: Color
    var lineLimit: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(tint.opacity(0.75))
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.24))
            }

            Text(text)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.24))
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.58))
                )
        }
    }
}

struct LegacyDebugFlowRow: View {
    let turn: AgentDebugTurn

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(turn.userText)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))
                    .lineLimit(2)
                if !turn.decodedSummary.isEmpty {
                    Text(turn.decodedSummary)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.42))
                        .lineLimit(2)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(turn.nodes) { node in
                    LegacyDebugFlowNodeView(node: node)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .legacyCardStyle(isDraft: false, cornerRadius: 24)
    }
}

struct LegacyDebugFlowNodeView: View {
    let node: AgentDebugTurn.Node

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: 30, height: 30)
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(color)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(node.title)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.16))
                    Text(node.state.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(color.opacity(0.14)))
                    if let durationText = node.durationText {
                        Text(durationText)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(white: 0.48))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color(white: 0.92)))
                    }
                }
                Text(node.detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.42))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var color: Color {
        switch node.state {
        case .pending:
            Color(white: 0.55)
        case .running:
            .blue
        case .completed:
            .green
        case .failed:
            .red
        }
    }

    private var iconName: String {
        switch node.state {
        case .pending:
            "circle"
        case .running:
            "arrow.triangle.2.circlepath"
        case .completed:
            "checkmark"
        case .failed:
            "xmark"
        }
    }
}

struct LegacyPromptSection: Identifiable, Equatable {
    let id: String
    let title: String
    let content: String
    let isUserContent: Bool
}

struct LegacyPromptSectionView: View {
    let section: LegacyPromptSection
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(section.isUserContent ? Color.blue : Color.purple)
                    .frame(width: 8, height: 8)
                Text(section.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.16))
            }
            
            Text(section.content)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(white: 0.24))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(section.isUserContent 
                              ? Color.blue.opacity(0.08) 
                              : Color.white.opacity(0.58))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(section.isUserContent ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
                )
        }
    }
}

struct LegacySideIndexBar: View {
    let sections: [LegacyPromptSection]
    let onJump: (String) -> Void
    @Binding var activeSectionId: String?
    
    @State private var hoveredIndex: Int? = nil
    
    var body: some View {
        let itemHeight: CGFloat = 20
        
        VStack(spacing: 0) {
            ForEach(0..<sections.count, id: \.self) { idx in
                let section = sections[idx]
                let isHovered = hoveredIndex == idx
                let isActive = activeSectionId == section.id
                
                Circle()
                    .fill(section.isUserContent ? Color.blue : (isActive ? Color.purple : Color.black.opacity(isHovered ? 0.6 : 0.25)))
                    .frame(width: isActive ? 8 : 6, height: isActive ? 8 : 6)
                    .scaleEffect(isActive ? 1.3 : (isHovered ? 1.15 : 1.0))
                    .frame(width: 24, height: itemHeight)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onJump(section.id)
                    }
            }
        }
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.85))
                .overlay(
                    Capsule()
                        .strokeBorder(Color(white: 0.88), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
        )
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let y = value.location.y
                    let idx = Int(y / itemHeight)
                    if idx >= 0 && idx < sections.count {
                        hoveredIndex = idx
                        let targetId = sections[idx].id
                        onJump(targetId)
                    } else {
                        hoveredIndex = nil
                    }
                }
                .onEnded { _ in
                    hoveredIndex = nil
                }
            )
            .overlay(alignment: .leading) {
                if let idx = hoveredIndex, idx >= 0 && idx < sections.count {
                    Text(sections[idx].title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.black.opacity(0.85))
                        )
                        .offset(x: -140)
                }
            }
    }
}

struct LegacyPromptDetailView: View {
    let turn: AgentDebugTurn
    
    @State private var activeSectionId: String? = nil
    
    private func parseSections(from fullPrompt: String) -> [LegacyPromptSection] {
        var sections: [LegacyPromptSection] = []
        let parts = fullPrompt.components(separatedBy: "[user]\n")
        let systemPart = parts.first ?? ""
        let userPart = parts.count > 1 ? parts[1] : ""
        
        let cleanSystemPart = systemPart.replacingOccurrences(of: "[system]\n", with: "")
        let systemBlocks = cleanSystemPart.components(separatedBy: "## ")
        
        if let intro = systemBlocks.first, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(LegacyPromptSection(
                id: "system_intro",
                title: "介绍",
                content: intro.trimmingCharacters(in: .whitespacesAndNewlines),
                isUserContent: false
            ))
        }
        
        for block in systemBlocks.dropFirst() {
            let lines = block.components(separatedBy: .newlines)
            guard let firstLine = lines.first else { continue }
            let title = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            
            sections.append(LegacyPromptSection(
                id: "system_\(title)",
                title: title,
                content: content,
                isUserContent: false
            ))
        }
        
        if !userPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(LegacyPromptSection(
                id: "user_content",
                title: "用户输入与上下文",
                content: userPart.trimmingCharacters(in: .whitespacesAndNewlines),
                isUserContent: true
            ))
        }
        
        return sections
    }

    var body: some View {
        let sections = parseSections(from: turn.fullPrompt)
        
        ZStack(alignment: .trailing) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("调试详情 - 完整提示词")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(white: 0.12))
                            .padding(.bottom, 6)
                        
                        ForEach(sections) { section in
                            LegacyPromptSectionView(section: section)
                                .id(section.id)
                        }
                    }
                    .padding(22)
                    .padding(.trailing, 28) // Leave room for sidebar index
                }
                .onAppear {
                    // Auto scroll to user content section after brief delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            proxy.scrollTo("user_content", anchor: .top)
                            activeSectionId = "user_content"
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if !sections.isEmpty {
                        LegacySideIndexBar(
                            sections: sections,
                            onJump: { targetId in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(targetId, anchor: .top)
                                    activeSectionId = targetId
                                }
                            },
                            activeSectionId: $activeSectionId
                        )
                        .padding(.trailing, 8)
                    }
                }
            }
        }
        .background(LegacyHomeBackground())
        .navigationTitle("完整提示词")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct LegacyModelOutputDetailView: View {
    let turn: AgentDebugTurn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("模型原始输出")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))

                LegacyDebugMessageBlock(
                    title: "模型原始输出 (完整 JSON)",
                    text: turn.modelOutput.isEmpty ? "等待模型返回..." : turn.modelOutput,
                    tint: .green
                )
            }
            .padding(22)
        }
        .background(LegacyHomeBackground())
        .navigationTitle("模型输出详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 任务卡片

struct LegacyTaskCardView: View {
    let card: MemoryCard
    let clarificationCardID: String?
    @Binding var clarificationDraftText: String
    let onSelectOption: (CardOption) -> Void
    let onClarificationSubmit: (String) -> Void
    let onClarificationCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if card.type == "reply" {
                Text((try? AttributedString(markdown: card.message)) ?? AttributedString(card.message))
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(white: 0.16))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
            // 顶部状态栏
            HStack(spacing: 8) {
                statusDot

                Text(statusLabel)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.45))

                Spacer(minLength: 0)

                // 提醒信息徽章（仅记录不显示）
                if let reminder = card.reminderInfo, reminder.type != "record" {
                    reminderBadge(reminder)
                }
            }

            // 标题
            Text(displayTitle)
                .font(.system(size: card.id == "card_idle" ? 26 : 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.12))
                .fixedSize(horizontal: false, vertical: true)

            // 原始输入
            if !card.originalText.isEmpty {
                Text(card.originalText)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
            }

            // 摘要
            if !displaySummary.isEmpty {
                Text(displaySummary)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.45))
            }

            // 主消息
            if !displayMessage.isEmpty {
                Text(displayMessage)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(white: 0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 失败详情
            if card.status == .failed, let detail = card.completionMessage, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.red.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            // 审批选项
            if card.status == .waitingConfirmation, !card.options.isEmpty {
                LegacyApprovalOptionsView(options: card.options, onSelect: onSelectOption)
                    .padding(.top, 6)
            }

            if shouldShowClarificationInput {
                LegacyClarificationInputView(
                    text: $clarificationDraftText,
                    onSubmit: {
                        onClarificationSubmit(clarificationDraftText)
                    },
                    onCancel: onClarificationCancel
                )
                .padding(.top, 4)
            }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .legacyCardStyle(isDraft: card.type == "draft", cornerRadius: 24)
    }

    private var shouldShowClarificationInput: Bool {
        card.status == .waitingConfirmation
            && (card.type == "birthday" || card.type == "date_task" || card.id == clarificationCardID || card.selectedOptionValue == "request_more_info")
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .strokeBorder(Color(white: 0.7), lineWidth: 1)
            )
    }

    private func reminderBadge(_ reminder: CardReminderInfo) -> some View {
        HStack(spacing: 4) {
            Image(systemName: reminder.type == "lunar" ? "moon.stars" : "bell")
                .font(.system(size: 10, weight: .semibold))
            Text(reminderBadgeText(reminder))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(Color(white: 0.35))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(Color(white: 0.88))
        )
        .overlay(
            Capsule()
                .strokeBorder(Color(white: 0.82), lineWidth: 0.5)
        )
    }

    private func reminderBadgeText(_ reminder: CardReminderInfo) -> String {
        if let nextTriggerDate = reminder.nextTriggerDate {
            if let date = DateFormatting.dateTime(from: nextTriggerDate) {
                return "下次 \(DateFormatting.badgeString(from: date))"
            }
            return "下次 \(nextTriggerDate)"
        }
        return "\(reminder.type == "lunar" ? "农历" : "阳历") 提前 \(reminder.remindBeforeDays) 天"
    }

    private var displayTitle: String {
        if card.type == "draft" {
            return "未完成的草稿"
        }
        switch card.status {
        case .executing:
            return "正在处理……"
        case .failed:
            return "处理失败"
        default:
            return card.title
        }
    }

    private var displayMessage: String {
        if card.type == "draft" {
            return card.message.isEmpty ? "点击卡片继续编辑或发送" : card.message
        }
        if card.type == "record" {
            return card.status == .failed ? (card.message.isEmpty ? "你可以重新说一次。" : card.message) : ""
        }
        switch card.status {
        case .idle:
            return card.message
        case .processing:
            return "AI 正在整理……"
        case .executing:
            return card.message.isEmpty ? "正在为你创建生日提醒" : card.message
        case .completed:
            return card.completionMessage ?? card.message
        case .failed:
            return card.message.isEmpty ? "你可以重新说一次。" : card.message
        case .waitingConfirmation:
            return card.message
        }
    }

    private var displaySummary: String {
        if card.status == .waitingConfirmation || card.status == .processing || card.status == .executing {
            return ""
        }

        if card.type == "record", card.summary.localizedStandardContains("生日") {
            return "普通记录"
        }
        
        let clean = { (s: String) -> String in
            var res = s.lowercased()
            let charsToRemove: Set<Character> = ["。", "，", "？", "！", "、", "；", "：", "“", "”", "‘", "’", "（", "）", "【", "】", ".", ",", "?", "!", ";", ":", "\"", "'", "(", ")", "[", "]", " ", "\t", "\n", "\r"]
            res.removeAll(where: { charsToRemove.contains($0) })
            return res
        }
        
        let normalizedSummary = clean(card.summary)
        let normalizedOriginal = clean(card.originalText)
        let normalizedTitle = clean(card.title)
        
        if normalizedSummary == normalizedOriginal || normalizedSummary == normalizedTitle {
            return ""
        }
        
        return card.summary
    }

    private var statusLabel: String {
        if card.type == "draft" {
            return "草稿"
        }
        switch card.status {
        case .idle:
            return "准备记录"
        case .processing:
            return "整理中"
        case .waitingConfirmation:
            return "待确认"
        case .executing:
            return "执行中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    private var statusColor: Color {
        if card.type == "draft" {
            return .orange
        }
        switch card.status {
        case .failed:
            return .red
        case .completed:
            return .green
        case .waitingConfirmation:
            return .orange
        case .processing, .executing:
            return .blue
        case .idle:
            return Color(white: 0.7)
        }
    }
}

struct LegacyCardListRow: View {
    let card: MemoryCard
    @Binding var revealedDeleteCardID: String?
    let clarificationCardID: String?
    @Binding var clarificationDraftText: String
    let onSelectOption: (CardOption) -> Void
    let onClarificationSubmit: (String) -> Void
    let onClarificationCancel: () -> Void
    let onDelete: () -> Void
    let onDraftTap: () -> Void
    let onSwipeDelete: () -> Void

    @State private var dragOffset: CGFloat = 0
    @State private var isDeleteDragActive = false

    private let deleteRevealWidth: CGFloat = 82

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteButton

            LegacyTaskCardView(
                card: card,
                clarificationCardID: clarificationCardID,
                clarificationDraftText: $clarificationDraftText,
                onSelectOption: onSelectOption,
                onClarificationSubmit: onClarificationSubmit,
                onClarificationCancel: onClarificationCancel,
                onDelete: onDelete
            )
            .contentShape(Rectangle())
            .offset(x: dragOffset)
            .simultaneousGesture(deleteRevealGesture)
            .onTapGesture {
                if card.type == "draft" {
                    onDraftTap()
                } else if revealedDeleteCardID == card.id {
                    closeDeleteReveal()
                }
            }
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 22, bottom: 7, trailing: 22))
        .onChange(of: revealedDeleteCardID) { _, newValue in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                dragOffset = newValue == card.id ? -deleteRevealWidth : 0
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            revealedDeleteCardID = card.id
            dragOffset = -deleteRevealWidth
            onSwipeDelete()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 17, weight: .semibold))
                Text("删除")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(width: deleteRevealWidth)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.red)
            )
        }
        .buttonStyle(.plain)
    }

    private var deleteRevealGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                let horizontal = abs(value.translation.width)
                let vertical = abs(value.translation.height)
                if !isDeleteDragActive {
                    guard horizontal > 28, horizontal > vertical * 2.2 else {
                        return
                    }
                    isDeleteDragActive = true
                }

                let baseOffset = revealedDeleteCardID == card.id ? -deleteRevealWidth : 0
                let nextOffset = baseOffset + value.translation.width
                dragOffset = min(0, max(-deleteRevealWidth, nextOffset))
            }
            .onEnded { _ in
                defer { isDeleteDragActive = false }
                guard isDeleteDragActive else { return }
                if dragOffset < -deleteRevealWidth * 0.45 {
                    revealedDeleteCardID = card.id
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        dragOffset = -deleteRevealWidth
                    }
                } else {
                    closeDeleteReveal()
                }
            }
    }

    private func closeDeleteReveal() {
        if revealedDeleteCardID == card.id {
            revealedDeleteCardID = nil
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            dragOffset = 0
        }
    }
}

struct LegacySafeAreaBottomReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    onChange(geo.safeAreaInsets.bottom)
                }
                .onChange(of: geo.safeAreaInsets.bottom) { _, newValue in
                    onChange(newValue)
                }
        }
    }
}

// MARK: - 审批选项

struct LegacyApprovalOptionsView: View {
    let options: [CardOption]
    let onSelect: (CardOption) -> Void

    @State private var tappedOption: String? = nil
    @State private var tappedActionButton: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("请选择下一步")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.45))

            VStack(spacing: 6) {
                ForEach(options) { option in
                    optionRow(option)
                }
            }
        }
    }

    private func optionRow(_ option: CardOption) -> some View {
        let hasActionButtons = option.actionButtons?.isEmpty == false

        return HStack(spacing: 10) {
            HStack(spacing: 10) {
                Text(option.key)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.25))
                    .frame(width: 26, height: 26)
                    .background(Color(white: 0.85), in: Circle())

                Text(option.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.2))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(
                tappedOption == option.id
                    ? Color(white: 0.92)
                    : Color(white: 0.90)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color(white: 0.82), lineWidth: 0.8)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                guard !hasActionButtons else { return }
                tappedOption = option.id
                onSelect(option)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    tappedOption = nil
                }
            }

            if let buttons = option.actionButtons, !buttons.isEmpty {
                HStack(spacing: 6) {
                    ForEach(buttons) { actionButton in
                        Button {
                            let tapId = "\(option.id)_\(actionButton.id)"
                            tappedActionButton = tapId
                            onSelect(option.derivedOption(from: actionButton))
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                tappedActionButton = nil
                            }
                        } label: {
                            Text(actionButton.label)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(white: 0.18))
                                .padding(.horizontal, 10)
                                .frame(height: 34)
                                .background(
                                    tappedActionButton == "\(option.id)_\(actionButton.id)"
                                        ? Color(white: 0.86)
                                        : Color.white.opacity(0.72)
                                )
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color(white: 0.80), lineWidth: 0.8)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private extension CardOption {
    func derivedOption(from actionButton: CardActionButton) -> CardOption {
        CardOption(
            key: key,
            label: "\(label) · \(actionButton.label)",
            value: actionButton.value,
            description: description,
            actions: actionButton.actions,
            nextStep: actionButton.nextStep ?? nextStep,
            resultCard: actionButton.resultCard ?? resultCard
        )
    }
}

struct LegacyClarificationInputView: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("补充信息")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.45))

            TextField("补充更多信息", text: $text, axis: .vertical)
                .lineLimit(2...4)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(white: 0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(white: 0.84), lineWidth: 0.8)
                )
                .focused($isFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            HStack(spacing: 10) {
                Button("取消", role: .cancel) {
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.42))

                Spacer(minLength: 0)

                Button("提交") {
                    onSubmit()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.blue)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(white: 0.84), lineWidth: 0.8)
        )
    }
}

struct LegacyVoiceCaptureOverlay: View {
    @ObservedObject var model: JotlyHomeViewModel
    let dragTranslation: CGSize
    let onVoiceCompletion: (JotlyHomeViewModel.VoiceCompletionResult) -> Void
    
    @State private var animatePulse = false
    @State private var showCancelConfirmation = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // 1. 全屏半透明黑色遮罩，使背景变暗 (支持点击以关闭/取消，彻底解除挂起死锁)
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    requestCancelConfirmation()
                }

            // 2. 底部悬浮毛玻璃组件 (唯一的毛玻璃底座 - 顶部是个坎，不需要顶部大圆弧)
            VStack(spacing: 0) {
                // A) 文字转写区域 (直接显示在玻璃背景上，没有多余的卡片边框)
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Spacer()
                        HStack(spacing: 6) {
                            if model.liveTranscript.isEmpty {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                                    )
                                    .scaleEffect(animatePulse ? 1.25 : 1.0)
                            } else {
                                LegacyMicAmplitudeWaveform(amplitude: model.voiceAmplitude, isRecording: model.isRecording)
                            }
                            
                            Text(overlayStatusText)
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(white: 0.35))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                                )
                        )
                        Spacer()
                    }
                    .onAppear {
                        // 使用无限循环且不反向的线性渐变，实现如同雷达般持续向外扩散的呼吸波纹
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            animatePulse = true
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        if model.liveTranscript.isEmpty {
                            LegacyBouncingVoiceVisualizer()
                                .frame(height: 180)
                                .padding(.vertical, 20)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView(.vertical, showsIndicators: false) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(model.liveTranscript)
                                            .font(.system(size: 20, weight: .bold, design: .rounded))
                                            .foregroundStyle(
                                                LinearGradient(
                                                    colors: [Color(white: 0.1), Color(white: 0.22)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .lineSpacing(6)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)

                                        Spacer(minLength: 0)
                                            .id("bottomID")
                                    }
                                }
                                .onChange(of: model.liveTranscript) { _, _ in
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        proxy.scrollTo("bottomID", anchor: .bottom)
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)

                Spacer(minLength: 10)

                // B) 液体交互区域 (三球弧形：取消 / 挂住 / 编辑)
                VStack(spacing: 10) {
                    ZStack {
                        LegacyLiquidConnectorCanvas(dragTranslation: dragTranslation, releaseAction: model.voiceReleaseAction)
                            .frame(height: 192)

                        actionOrb(
                            icon: "xmark",
                            caption: actionCaption(for: .cancel),
                            tint: .red,
                            progress: cancelProgress,
                            size: 48,
                            associatedAction: .cancel
                        ) {
                            requestCancelConfirmation()
                        }
                        .scaleEffect(cancelScale)
                        .offset(x: -118, y: 12)
                        .zIndex(cancelProgress)

                        actionOrb(
                            icon: model.isVoiceHoldLocked ? "paperplane.fill" : "waveform",
                            caption: actionCaption(for: .hold),
                            tint: .green,
                            progress: holdProgress,
                            size: 58,
                            associatedAction: .hold
                        ) {
                            if model.isVoiceHoldLocked {
                                model.stopHeldVoiceCapture()
                            } else {
                                model.toggleHeldVoiceCapture()
                            }
                        }
                        .scaleEffect(holdScale)
                        .offset(x: 0, y: -40)
                        .zIndex(holdProgress)

                        actionOrb(
                            icon: "pencil",
                            caption: actionCaption(for: .edit),
                            tint: .blue,
                            progress: editProgress,
                            size: 48,
                            associatedAction: .edit
                        ) {
                            if let outcome = model.finishVoiceCaptureForEditing() {
                                onVoiceCompletion(outcome)
                            }
                        }
                        .scaleEffect(editScale)
                        .offset(x: 118, y: 12)
                        .zIndex(editProgress)
                    }
                    .padding(.top, 2)
                }
                .padding(.top, 2)
                .padding(.bottom, 8)
                .frame(height: 224)
                
                Spacer(minLength: 16)
            }
            .frame(height: 500)
            .background(
                LegacyRoundedCorner(radius: 32, corners: [.topLeft, .topRight])
                    .fill(.ultraThinMaterial)
                    .overlay(
                        LegacyRoundedCorner(radius: 32, corners: [.topLeft, .topRight])
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.65),
                                        .white.opacity(0.15),
                                        .clear
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.0
                            )
                    )
                    .background(
                        LegacyRoundedCorner(radius: 32, corners: [.topLeft, .topRight])
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.12),
                                        Color.black.opacity(0.02)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .shadow(color: Color.black.opacity(0.12), radius: 20, x: 0, y: -10)
                    )
            )
            .ignoresSafeArea(edges: .bottom)

            if showCancelConfirmation {
                VStack(spacing: 16) {
                    Text("要取消并丢弃本次语音内容吗？")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.12))
                    
                    Text("取消后本次已识别的内容会被清空。")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                        .multilineTextAlignment(.center)
                    
                    HStack(spacing: 12) {
                        Button("继续保留") {
                            showCancelConfirmation = false
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color(white: 0.25))
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.white.opacity(0.24), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 0.5))

                        Button("丢弃并取消") {
                            showCancelConfirmation = false
                            model.cancelVoiceCaptureOnInterrupt()
                        }
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.85), in: Capsule())
                    }
                }
                .padding(20)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 50)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showCancelConfirmation)
        .allowsHitTesting(true)
    }

    private var cancelProgress: CGFloat {
        voiceActionFocus(for: .cancel)
    }

    private var editProgress: CGFloat {
        voiceActionFocus(for: .edit)
    }

    private var holdProgress: CGFloat {
        if model.isVoiceHoldLocked {
            return 1
        }
        return voiceActionFocus(for: .hold)
    }

    private var cancelScale: CGFloat {
        CGFloat(1.0) + CGFloat(pow(Double(cancelProgress), 0.82)) * CGFloat(0.58)
    }

    private var editScale: CGFloat {
        CGFloat(1.0) + CGFloat(pow(Double(editProgress), 0.82)) * CGFloat(0.58)
    }

    private var holdScale: CGFloat {
        CGFloat(1.0) + CGFloat(pow(Double(holdProgress), 0.82)) * CGFloat(0.60)
    }

    private var hoverPromptText: String {
        if model.isVoiceHoldLocked {
            return "挂住中，点发送完成"
        }
        switch model.voiceReleaseAction {
        case .cancel:
            return "松手取消"
        case .hold:
            return "松手挂住"
        case .edit:
            return "松手编辑"
        case .send:
            return "左滑取消 / 上滑挂住 / 右滑编辑"
        }
    }

    private var overlayStatusText: String {
        if model.isVoiceHoldLocked {
            return "持续说话中"
        }
        return model.isRecording ? "正在听" : "准备听写"
    }

    private func actionCaption(for action: JotlyHomeViewModel.VoiceReleaseAction) -> String {
        // 当选中某个特定按钮后，隐藏其他按钮上的文本，仅展示选中按钮的“松手XX”字样
        if model.voiceReleaseAction != .send && model.voiceReleaseAction != action {
            return ""
        }

        if model.isVoiceHoldLocked {
            switch action {
            case .cancel:
                return "取消"
            case .hold:
                return "发送"
            case .edit:
                return "编辑"
            case .send:
                return "发送"
            }
        }

        switch action {
        case .cancel:
            return model.voiceReleaseAction == .cancel ? "松手取消" : "取消"
        case .hold:
            return model.voiceReleaseAction == .hold ? "松手挂住" : "挂住"
        case .edit:
            return model.voiceReleaseAction == .edit ? "松手编辑" : "编辑"
        case .send:
            return "发送"
        }
    }

    private func requestCancelConfirmation() {
        let hasText = !model.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasText {
            showCancelConfirmation = true
        } else {
            model.cancelVoiceCaptureOnInterrupt()
        }
    }

    private func voiceActionFocus(for action: JotlyHomeViewModel.VoiceReleaseAction) -> CGFloat {
        let finger = CGPoint(x: dragTranslation.width, y: dragTranslation.height)
        let center: CGPoint

        switch action {
        case .cancel:
            center = CGPoint(x: -118, y: -60)
        case .hold:
            center = CGPoint(x: 0, y: -112)
        case .edit:
            center = CGPoint(x: 118, y: -60)
        case .send:
            return 0
        }

        let distance = sqrt(pow(finger.x - center.x, 2) + pow(finger.y - center.y, 2))
        let radius: CGFloat = 65
        
        if distance < radius {
            return 1.0
        } else if distance < 120 {
            // 从 120pt 距离就开始顺滑放大，让视觉过渡更自然、更容易感知
            let t = (120 - distance) / (120 - radius)
            return t
        } else {
            return 0.0
        }
    }

    @ViewBuilder
    private func actionOrb(
        icon: String,
        caption: String,
        tint: Color,
        progress: CGFloat,
        size: CGFloat,
        associatedAction: JotlyHomeViewModel.VoiceReleaseAction,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.voiceReleaseAction == associatedAction ? tint : Color(white: 0.42))
                    .lineLimit(1)
                    .frame(height: 14)
                    .frame(width: size + 30)
                    .minimumScaleFactor(0.8)

                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.24))
                        .shadow(color: Color.black.opacity(0.08), radius: 4, x: 0, y: 2)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5)
                        )
                        .background(
                            Circle()
                                .fill(tint.opacity(0.76 * progress))
                        )

                    Image(systemName: icon)
                        .font(.system(size: size * 0.28, weight: .bold))
                        .foregroundStyle(progress > 0.45 ? Color.white : Color(white: 0.25))
                }
                .frame(width: size, height: size)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - 语音波纹

struct LegacyVoiceWaveBadge: View {
    let isAnimating: Bool
    @State private var animate = false

    var body: some View {
        HStack(spacing: 4) {
            waveBar(height: 10)
            waveBar(height: 18)
            waveBar(height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        )
        .scaleEffect(animate ? 1.03 : 0.98)
        .onAppear {
            animate = isAnimating
        }
        .onChange(of: isAnimating) { _, newValue in
            animate = newValue
        }
        .animation(
            isAnimating
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.2),
            value: animate
        )
    }

    @ViewBuilder
    private func waveBar(height: CGFloat) -> some View {
        Capsule()
            .fill(.white.opacity(0.9))
            .frame(width: 4, height: height)
    }
}

// MARK: - 底部输入栏

private enum DockMetrics {
    static let sideButtonSize: CGFloat = 54
    static let sideIconSize: CGFloat = 20
    static let itemSpacing: CGFloat = 12
    static let pillHeight: CGFloat = 54
    static let pillCornerRadius: CGFloat = 27
    static let modeButtonWidth: CGFloat = 44
    static let dividerHeight: CGFloat = 18
    
    static let themeColor = Color(white: 0.25)
}

struct LegacyComposerDock: View {
    let mode: JotlyHomeViewModel.InputMode
    let isRecording: Bool
    @Binding var draftText: String
    var isTextFocused: FocusState<Bool>.Binding
    let onCameraTap: () -> Void
    let onVoicePressBegin: () -> Void
    let onVoiceDragChanged: (CGSize) -> Void
    let onVoiceRelease: () -> Void
    let onModeToggle: () -> Void
    let onTextSubmit: () -> Void
    let onAddTap: () -> Void

    @State private var isCameraPressed = false
    @State private var isAddPressed = false

    var body: some View {
        dockContent
    }

    private var dockContent: some View {
        HStack(spacing: isRecording ? 0 : DockMetrics.itemSpacing) {
            if !isRecording {
                LegacyDockIconButton(
                    icon: "camera",
                    isLeft: true,
                    accessibilityLabel: "打开相机",
                    action: onCameraTap,
                    isPressed: $isCameraPressed
                )
                .transition(.scale(scale: 0.01, anchor: .trailing).combined(with: .opacity))
            }

                LegacyComposerPill(
                mode: mode,
                isRecording: isRecording,
                draftText: $draftText,
                isTextFocused: isTextFocused,
                onVoicePressBegin: onVoicePressBegin,
                onVoiceDragChanged: onVoiceDragChanged,
                onVoiceRelease: onVoiceRelease,
                onModeToggle: onModeToggle,
                onTextSubmit: onTextSubmit
            )
            .frame(maxWidth: .infinity)

            if !isRecording {
                LegacyDockIconButton(
                    icon: "plus",
                    isLeft: false,
                    accessibilityLabel: "添加内容",
                    action: onAddTap,
                    isPressed: $isAddPressed
                )
                .transition(.scale(scale: 0.01, anchor: .leading).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 380)
        .background(
            LegacyComposerDockBackground(
                isCameraPressed: isCameraPressed,
                isAddPressed: isAddPressed,
                isRecording: isRecording
            )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isRecording)
    }
}

struct LegacyDockIconButtonStyle: ButtonStyle {
    let isLeft: Bool
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.15 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

struct LegacyDockIconButton: View {
    let icon: String
    let isLeft: Bool
    let accessibilityLabel: String
    let action: () -> Void
    @Binding var isPressed: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: DockMetrics.sideIconSize, weight: .semibold))
                .foregroundStyle(DockMetrics.themeColor)
                .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
        }
        .buttonStyle(LegacyDockIconButtonStyle(isLeft: isLeft, isPressed: $isPressed))
        .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .zIndex(isPressed ? 10 : 0)
    }
}

struct LegacyComposerDockBackground: View {
    let isCameraPressed: Bool
    let isAddPressed: Bool
    let isRecording: Bool

    var body: some View {
        ZStack {
            // 原生 3 个独立毛玻璃形状 (在融合过程中保持 85% 不透明度，完美保留高光白边与投影)
            if !isRecording {
                HStack(spacing: DockMetrics.itemSpacing) {
                    // 左侧圆圈
                    Color.clear
                        .legacyGlassCircleSurface(size: DockMetrics.sideButtonSize)
                        .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
                        .scaleEffect(isCameraPressed ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isCameraPressed)
                    
                    Spacer()
                    
                    // 右侧圆圈
                    Color.clear
                        .legacyGlassCircleSurface(size: DockMetrics.sideButtonSize)
                        .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
                        .scaleEffect(isAddPressed ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isAddPressed)
                }
            }
            
            // 中间输入胶囊背景
            Color.clear
                .legacyGlassCapsuleSurface(cornerRadius: DockMetrics.pillCornerRadius)
                .frame(height: DockMetrics.pillHeight)
                .padding(.horizontal, isRecording ? 0 : (DockMetrics.sideButtonSize + DockMetrics.itemSpacing))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isRecording)
    }
}

// MARK: - 输入胶囊

struct LegacyComposerPill: View {
    let mode: JotlyHomeViewModel.InputMode
    let isRecording: Bool
    @Binding var draftText: String
    var isTextFocused: FocusState<Bool>.Binding
    let onVoicePressBegin: () -> Void
    let onVoiceDragChanged: (CGSize) -> Void
    let onVoiceRelease: () -> Void
    let onModeToggle: () -> Void
    let onTextSubmit: () -> Void

    @State private var pressArmed = false
    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 0) {
            content

            Divider()
                .frame(height: DockMetrics.dividerHeight)
                .overlay(Color.black.opacity(0.12))

            modeToggleView
        }
        .frame(height: DockMetrics.pillHeight)
        .padding(.leading, mode == .voice ? 12 : 14)
        .padding(.trailing, mode == .voice ? 12 : 6)
        .onChange(of: isRecording) { _, newValue in
            if !newValue {
                pressArmed = false
            }
        }
    }

    private var modeToggleView: some View {
        Image(systemName: mode == .voice ? "keyboard" : "mic")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(DockMetrics.themeColor)
            .frame(width: DockMetrics.modeButtonWidth, height: DockMetrics.pillHeight)
            .contentShape(Rectangle())
            .onTapGesture {
                onModeToggle()
            }
            .accessibilityLabel("切换输入模式")
    }

    @ViewBuilder
    private var content: some View {
        if mode == .voice {
            voiceModeContent
        } else {
            textModeContent
        }
    }

    private var voiceModeContent: some View {
        GeometryReader { geometry in
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(isRecording ? Color.blue : DockMetrics.themeColor)

                Text(isRecording ? "正在听" : "按住说话")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(isRecording ? Color(white: 0.2) : DockMetrics.themeColor)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(voiceGesture(with: geometry.size.width))
        }
        .frame(height: DockMetrics.pillHeight)
    }

    private var textModeContent: some View {
        HStack(spacing: 0) {
            TextField("输入文字", text: $draftText)
                .focused(isTextFocused)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.15))
                .submitLabel(.send)
                .textInputAutocapitalization(.never)
                .onSubmit(onTextSubmit)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: DockMetrics.pillHeight - 10, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity)
        .frame(height: DockMetrics.pillHeight)
    }

    private func voiceGesture(with width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard mode == .voice else { return }
                
                // 计算手指相对于按钮中心的偏移量，这样无论是按左边还是右边，拉出的液体圆球和触控位置都是 1:1 对齐的
                let xOffset = value.location.x - (width / 2)
                let yOffset = value.location.y - (DockMetrics.pillHeight / 2)
                
                onVoiceDragChanged(CGSize(width: xOffset, height: yOffset))
                
                guard !pressArmed else { return }
                pressArmed = true
                onVoicePressBegin()
            }
            .onEnded { _ in
                guard mode == .voice else { return }
                pressArmed = false
                onVoiceRelease()
            }
    }
}

// MARK: - 录音标记

struct LegacyRecordingFlag: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 3) {
            waveBar(height: 8)
            waveBar(height: 14)
            waveBar(height: 10)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Capsule().fill(.white.opacity(0.68)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.82), lineWidth: 1))
        .scaleEffect(animate ? 1.03 : 0.97)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }

    @ViewBuilder
    private func waveBar(height: CGFloat) -> some View {
        Capsule()
            .fill(.black.opacity(0.72))
            .frame(width: 3, height: height)
    }
}

// MARK: - 添加内容 Sheet

struct LegacyPhotoComposerSheet: View {
    @StateObject private var photoStore = LegacyPhotoGridStore.shared
    @State private var selectedAssetIds: [String] = []
    @State private var selectionLoadTask: Task<Void, Never>?

    let isRecording: Bool
    let voiceAmplitude: Float
    let liveTranscript: String
    let voiceReleaseAction: JotlyHomeViewModel.VoiceReleaseAction
    let onSelectionImagesChanged: ([UIImage]) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                content
            }
            .background(.ultraThinMaterial)

            if isRecording {
                LegacyImageVoiceCaptureOverlay(
                    transcript: photoVoiceTranscript,
                    amplitude: voiceAmplitude,
                    releaseAction: photoVoiceReleaseAction
                )
                .transition(.opacity)
            }
        }
        .task {
            await photoStore.requestAccessAndLoad()
        }
        .onDisappear {
            selectionLoadTask?.cancel()
            onSelectionImagesChanged([])
        }
    }

    private var header: some View {
        VStack(spacing: 9) {
            Capsule()
                .fill(Color.black.opacity(0.16))
                .frame(width: 38, height: 5)
                .padding(.top, 10)

            Text("相册")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.12))
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        switch photoStore.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 28, weight: .semibold))
                Text("需要允许访问相册，才能选择图片。")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color(white: 0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            GeometryReader { proxy in
                let spacing: CGFloat = 1
                let columnCount = 4
                let availableWidth = max(proxy.size.width - spacing * CGFloat(columnCount - 1), 0)
                let cellSide = floor(availableWidth / CGFloat(columnCount))
                let columns = Array(
                    repeating: GridItem(.fixed(cellSide), spacing: spacing),
                    count: columnCount
                )

                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                        ForEach(photoStore.assets, id: \.localIdentifier) { asset in
                            LegacyPhotoGridCell(
                                assetID: asset.localIdentifier,
                                selectionIndex: selectionIndex(for: asset.localIdentifier),
                                side: cellSide,
                                loadThumbnail: {
                                    await photoStore.thumbnail(for: asset)
                                }
                            ) {
                                toggleSelection(asset.localIdentifier)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 110)
                }
            }
        }
    }

    private var photoVoiceTranscript: String {
        liveTranscript
    }

    private var photoVoiceReleaseAction: JotlyHomeViewModel.VoiceReleaseAction {
        voiceReleaseAction
    }

    private func selectionIndex(for assetId: String) -> Int? {
        guard let index = selectedAssetIds.firstIndex(of: assetId) else { return nil }
        return index + 1
    }

    private func toggleSelection(_ assetId: String) {
        if let index = selectedAssetIds.firstIndex(of: assetId) {
            selectedAssetIds.remove(at: index)
        } else {
            selectedAssetIds.append(assetId)
        }
        publishSelectionImages()
    }

    private func selectedAssets() -> [PHAsset] {
        selectedAssetIds.compactMap { id in
            photoStore.assets.first { $0.localIdentifier == id }
        }
    }

    private func publishSelectionImages() {
        selectionLoadTask?.cancel()
        let assets = selectedAssets()
        let requestedAssetIds = selectedAssetIds
        guard !assets.isEmpty else {
            onSelectionImagesChanged([])
            return
        }
        selectionLoadTask = Task {
            let images = await photoStore.loadImages(for: assets)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard selectedAssetIds == requestedAssetIds else { return }
                onSelectionImagesChanged(images)
            }
        }
    }
}

struct LegacyPhotoGridCell: View {
    let assetID: String
    let selectionIndex: Int?
    let side: CGFloat
    let loadThumbnail: () async -> UIImage?
    let onTap: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(Color.black.opacity(0.06))
                    }
                }
                .frame(width: side, height: side)
                .clipped()

                if let selectionIndex {
                    Text("\(selectionIndex)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.blue))
                        .padding(6)
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                        .background(Circle().fill(Color.black.opacity(0.18)))
                        .frame(width: 22, height: 22)
                        .padding(6)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .accessibilityIdentifier("photo-grid-cell-\(assetID)")
        }
        .buttonStyle(.plain)
        .frame(width: side, height: side)
        .task(id: assetID) {
            thumbnail = await loadThumbnail()
        }
    }
}

struct LegacyImageVoiceBar: View {
    let isEnabled: Bool
    let isRecording: Bool
    let isHeld: Bool
    let amplitude: Float
    let onPressBegin: () -> Void
    let onDragChanged: (CGSize) -> Void
    let onRelease: () -> Void
    let onHeldSend: () -> Void

    @State private var pressArmed = false

    var body: some View {
        Button {
            if isHeld {
                onHeldSend()
            }
        } label: {
            ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isRecording
                            ? [Color.blue.opacity(0.95), Color.cyan.opacity(0.85)]
                            : [Color.white.opacity(0.92), Color.white.opacity(0.76)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6)

            HStack(spacing: 10) {
                Image(systemName: isHeld ? "paperplane.fill" : "mic.fill")
                    .font(.system(size: 16, weight: .bold))
                Text(isHeld ? "发送" : (isRecording ? "松手发送" : "按住说话"))
                    .font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(isRecording ? .white : Color(white: 0.12))

            if isRecording {
                HStack(spacing: 3) {
                    ForEach(0..<28, id: \.self) { index in
                        Capsule()
                            .fill(.white.opacity(0.8))
                            .frame(width: 2, height: barHeight(index))
                    }
                }
                .padding(.top, 46)
            }
        }
        }
        .buttonStyle(.plain)
        .frame(height: isRecording ? 96 : 52)
        .opacity(isEnabled ? 1 : 0.42)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard isEnabled, !isHeld else { return }
                    if !pressArmed {
                        pressArmed = true
                        onPressBegin()
                    }
                    if pressArmed {
                        onDragChanged(value.translation)
                    }
                }
                .onEnded { _ in
                    guard pressArmed else { return }
                    pressArmed = false
                    onRelease()
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.82), value: isRecording)
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let phase = CGFloat(index % 7) / 6.0
        let base = 8 + abs(sin(phase * .pi)) * 18
        return base + CGFloat(amplitude) * 18
    }
}

struct LegacyImageVoiceCaptureOverlay: View {
    let transcript: String
    let amplitude: Float
    let releaseAction: JotlyHomeViewModel.VoiceReleaseAction

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            HStack(spacing: 46) {
                actionBubble(
                    title: releaseAction == .cancel ? "松手取消" : "取消",
                    icon: "xmark",
                    isActive: releaseAction == .cancel
                )

                actionBubble(
                    title: releaseAction == .hold ? "松手挂住" : "挂住",
                    icon: "pin.fill",
                    isActive: releaseAction == .hold
                )
            }
            .padding(.bottom, 18)

            Text(releaseAction == .cancel ? "松手取消" : "松手发送")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            LegacyScrollingTranscriptLine(text: transcript)
                .frame(height: 30)
                .padding(.horizontal, 28)

            LegacyImageVoiceWave(amplitude: amplitude)
                .frame(height: 26)
                .padding(.horizontal, 44)

            Spacer(minLength: 82)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.12),
                    Color.cyan.opacity(0.34),
                    Color.blue.opacity(0.58)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .background(.ultraThinMaterial)
        )
        .allowsHitTesting(false)
    }

    private func actionBubble(title: String, icon: String, isActive: Bool) -> some View {
        VStack(spacing: 7) {
            Circle()
                .fill(isActive ? Color.white.opacity(0.96) : Color.white.opacity(0.68))
                .frame(width: isActive ? 62 : 52, height: isActive ? 62 : 52)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: isActive ? 22 : 18, weight: .bold))
                        .foregroundStyle(isActive ? Color.blue : Color(white: 0.2))
                )
                .shadow(color: Color.black.opacity(0.12), radius: 14, y: 8)

            Text(title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(isActive ? 1 : 0.82))
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isActive)
    }
}

struct LegacyScrollingTranscriptLine: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Text(text.isEmpty ? "正在听..." : text)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Color.clear
                        .frame(width: 1, height: 1)
                        .id("transcriptEnd")
                }
                .frame(minWidth: 1, alignment: .leading)
            }
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("transcriptEnd", anchor: .trailing)
                }
            }
        }
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.08),
                    .init(color: .black, location: 0.92),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
    }
}

struct LegacyImageVoiceWave: View {
    let amplitude: Float

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<34, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.72))
                    .frame(width: 3, height: height(for: index))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func height(for index: Int) -> CGFloat {
        let phase = CGFloat(index % 8) / 7
        return 8 + abs(sin(phase * .pi)) * 12 + CGFloat(amplitude) * 16
    }
}

struct LegacyPhotoComposerButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold, design: .rounded))
            .foregroundStyle(isPrimary ? .white : Color(white: 0.18))
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isPrimary ? Color.blue : Color.white.opacity(0.86))
            )
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

@MainActor
final class LegacyPhotoGridStore: ObservableObject {
    static let shared = LegacyPhotoGridStore()

    enum State: Equatable {
        case loading
        case denied
        case ready
    }

    @Published var state: State = .loading
    @Published var assets: [PHAsset] = []
    private let manager = PHCachingImageManager()
    private let thumbnailCache = NSCache<NSString, UIImage>()
    private var loadStartedAt: Date?
    private var didLogFirstThumbnail = false

    func requestAccessAndLoad() async {
        if state == .ready, !assets.isEmpty { return }
        loadStartedAt = Date()
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let status: PHAuthorizationStatus
        if current == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        } else {
            status = current
        }

        guard status == .authorized || status == .limited else {
            state = .denied
            return
        }

        loadAssets()
        state = .ready
        let elapsed = Date().timeIntervalSince(loadStartedAt ?? Date())
        JotlyLog.app.info("Photo assets ready: count=\(self.assets.count, privacy: .public), elapsed=\(elapsed, privacy: .public)s")
    }

    func thumbnail(for asset: PHAsset) async -> UIImage? {
        let key = asset.localIdentifier as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        guard let image = await requestImage(
            for: asset,
            targetSize: CGSize(width: 220, height: 220),
            fast: true
        ) else { return nil }
        thumbnailCache.setObject(image, forKey: key)
        if !didLogFirstThumbnail {
            didLogFirstThumbnail = true
            let elapsed = Date().timeIntervalSince(loadStartedAt ?? Date())
            JotlyLog.app.info("First photo thumbnail ready in \(elapsed, privacy: .public)s")
        }
        return image
    }

    func loadImages(for assets: [PHAsset]) async -> [UIImage] {
        var images: [UIImage] = []
        for asset in assets {
            if let image = await requestImage(for: asset, targetSize: CGSize(width: 1600, height: 1600), fast: false) {
                images.append(image)
            }
        }
        return images
    }

    private func loadAssets() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 160
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var loaded: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            loaded.append(asset)
        }
        // PHFetchResult already follows the requested creation-date order.
        // Keeping that order avoids reordering photos created in the same second.
        assets = loaded
    }

    private func requestImage(for asset: PHAsset, targetSize: CGSize, fast: Bool) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = fast ? .opportunistic : .highQualityFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            var didResume = false
            manager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if fast || !degraded {
                    guard !didResume else { return }
                    didResume = true
                    continuation.resume(returning: image)
                }
            }
        }
    }
}

// MARK: - 相机选择器

struct LegacyCameraPicker: UIViewControllerRepresentable {
    let onImagePick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagePick: onImagePick)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImagePick: (UIImage) -> Void

        init(onImagePick: @escaping (UIImage) -> Void) {
            self.onImagePick = onImagePick
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImagePick(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 个人页占位

struct LegacyProfilePlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @AppStorage("app_experience_mode") private var experienceModeRaw = AppExperienceMode.regular.rawValue

    private let shortcutsURL = URL(string: "shortcuts://")!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("显示模式")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))
                    .padding(.top, 10)

                VStack(spacing: 10) {
                    ForEach(AppExperienceMode.allCases) { mode in
                        Button {
                            experienceModeRaw = mode.rawValue
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: mode == .regular ? "sparkles.rectangle.stack" : "hammer")
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(mode.title)
                                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                                    Text(mode.detail)
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color(white: 0.46))
                                }
                                Spacer()
                                Image(systemName: experienceModeRaw == mode.rawValue ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(experienceModeRaw == mode.rawValue ? Color.blue : Color(white: 0.72))
                            }
                            .foregroundStyle(Color(white: 0.18))
                            .padding(16)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text("快捷入口")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))

                Text("两个入口：截图和语音。点下面的按钮先打开 Shortcuts，然后搜索 Jotly，把动作加进去。")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color(white: 0.38))
                    .fixedSize(horizontal: false, vertical: true)

                shortcutInstallCard(
                    title: "截图",
                    description: "用于轻拍背面后截图分析。打开 Shortcuts 后搜索 Jotly，添加“截图”动作，再接系统截图步骤。"
                )

                shortcutInstallCard(
                    title: "语音",
                    description: "用于系统快捷操作里的语音记账。打开 Shortcuts 后搜索 Jotly，添加“语音”动作，再绑定到你常用的按钮。"
                )

                VStack(alignment: .leading, spacing: 8) {
                    Text("说明")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.18))
                    Text("我们只提供应用里的动作入口，不替你预填快捷指令。具体绑定到背面轻拍、操作按钮，还是其他系统入口，由你在快捷指令和 iPhone 设置里选择。")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.44))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.78))
                )

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle("快捷入口")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") {
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private func shortcutInstallCard(title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))
                Spacer()
                Image(systemName: title == "截图" ? "camera.viewfinder" : "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(white: 0.24))
            }

            Text(description)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color(white: 0.42))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                openURL(shortcutsURL)
            } label: {
                HStack {
                    Image(systemName: "plus")
                    Text("去添加")
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.46, blue: 0.98),
                            Color(red: 0.13, green: 0.34, blue: 0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.white.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.06), radius: 18, x: 0, y: 10)
        )
    }
}

// MARK: - View Extensions

private extension View {
    @ViewBuilder
    func legacyGlassCircleSurface(size: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear, in: .circle)
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .background(
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.30),
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                )
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.07), radius: 12, x: 0, y: 6)
        }
    }

    @ViewBuilder
    func legacyGlassCapsuleSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear, in: .capsule)
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule())
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.07), radius: 14, x: 0, y: 7)
        }
    }

    @ViewBuilder
    func legacyGlassRectSurface(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.clear, in: .rect(cornerRadius: cornerRadius))
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.32),
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.38), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.07), radius: 14, x: 0, y: 7)
        }
    }

    @ViewBuilder
    func legacyCardStyle(isDraft: Bool, cornerRadius: CGFloat) -> some View {
        if isDraft {
            self
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white,
                                    Color(red: 0.99, green: 0.98, blue: 0.95)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            Color.orange.opacity(0.45),
                            style: StrokeStyle(lineWidth: 1.2, dash: [6, 4])
                        )
                )
                .shadow(color: .orange.opacity(0.04), radius: 12, x: 0, y: 4)
        } else {
            self.legacyWhiteCard(cornerRadius: cornerRadius)
        }
    }

    /// 白色卡片 — 与背景区分，深色文字
    func legacyWhiteCard(cornerRadius: CGFloat) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white,
                                Color(red: 0.97, green: 0.97, blue: 0.98)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color(white: 0.88), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
    }

    /// 深色磨砂玻璃卡片 — 用于悬浮语音转写面板，浅色文字
    func legacyDarkGlassCard(cornerRadius: CGFloat) -> some View {
        self
            .background(.ultraThinMaterial)
            .background(Color.black.opacity(0.32))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
    }
}

// MARK: - Preview

#if DEBUG
struct JotlyHomeScreen_Previews: PreviewProvider {
    static var previews: some View {
        JotlyHomeScreen()
    }
}
#endif

// MARK: - Liquid Connector Canvas

struct LegacyLiquidConnectorCanvas: View {
    let dragTranslation: CGSize
    let releaseAction: JotlyHomeViewModel.VoiceReleaseAction

    var body: some View {
        Canvas { context, size in
            // 使用更大模糊半径（22） and alpha 阈值组合，让拉伸的桥梁丰满圆润而不显尖锐，表现如同高品质液体玻璃
            context.addFilter(.alphaThreshold(min: 0.45, color: Color.white.opacity(0.25)))
            context.addFilter(.blur(radius: 22))

            context.drawLayer { ctx in
                let center = CGPoint(x: size.width / 2, y: size.height - 24)
                
                // 1. 底部基础胶状层 (拱形层)
                let baseRect = CGRect(
                    x: -80,
                    y: size.height - 48,
                    width: size.width + 160,
                    height: 142
                )
                ctx.fill(Path(ellipseIn: baseRect), with: .color(.black))

                // 2. 中心源圆圈 (位于底部中央)
                let sourceRect = CGRect(
                    x: center.x - 25,
                    y: center.y - 25,
                    width: 50,
                    height: 50
                )
                ctx.fill(Path(ellipseIn: sourceRect), with: .color(.black))

                // 计算拖动进度，基于总位移 (死区 10pt，拉伸满 65pt)
                let dragX = dragTranslation.width
                let dragY = dragTranslation.height
                let dragDistance = sqrt(dragX * dragX + dragY * dragY)
                let deadzone: CGFloat = 10
                let activeThreshold: CGFloat = 65
                let progress = dragDistance > deadzone ? min((dragDistance - deadzone) / (activeThreshold - deadzone), CGFloat(1.0)) : CGFloat(0.0)

                // 3. 液体拉伸滴落球及桥梁连结
                if dragDistance > deadzone {
                    // 1:1 跟手，没有任何超前系数或 Y 轴阻尼/限制，使得流动液体完全落在用户手指正下方
                    let dropX = center.x + dragX
                    let dropY = center.y + dragY
                    
                    // 用较大半径包裹住手，并且随拉伸收缩
                    let dropRadius: CGFloat = 26 - 4 * sin(progress * .pi)
                    let dropRect = CGRect(
                        x: dropX - dropRadius,
                        y: dropY - dropRadius,
                        width: dropRadius * 2,
                        height: dropRadius * 2
                    )
                    ctx.fill(Path(ellipseIn: dropRect), with: .color(.black))
                    
                    // 桥接过渡球：直接在 center 和 (dropX, dropY) 之间进行插值，使连结线完美对准手指
                    let steps = 10
                    for i in 1..<steps {
                        let stepProgress = CGFloat(i) / CGFloat(steps)
                        let stepX = center.x + (dropX - center.x) * stepProgress
                        let stepY = center.y + (dropY - center.y) * stepProgress
                        
                        // 桥身随拉伸过渡变细，产生真实拉长水滴效果
                        let stepRadius = 20 * (1.0 - stepProgress * 0.45)
                        
                        let stepRect = CGRect(
                            x: stepX - stepRadius,
                            y: stepY - stepRadius,
                            width: stepRadius * 2,
                            height: stepRadius * 2
                        )
                        ctx.fill(Path(ellipseIn: stepRect), with: .color(.black))
                    }
                }
            }
        }
    }
}

struct LegacyArchedSheetShape: Shape {
    var archHeight: CGFloat = 40
    var cornerRadius: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        
        // Start at bottom-left
        path.move(to: CGPoint(x: 0, y: height))
        
        // Go up left edge to start of top-left corner radius
        path.addLine(to: CGPoint(x: 0, y: cornerRadius + archHeight))
        
        // Top-left corner arc
        path.addQuadCurve(
            to: CGPoint(x: cornerRadius, y: archHeight),
            control: CGPoint(x: 0, y: archHeight)
        )
        
        // Arched curve across the top edge peaking in the center
        path.addQuadCurve(
            to: CGPoint(x: width - cornerRadius, y: archHeight),
            control: CGPoint(x: width / 2, y: archHeight - archHeight * 2)
        )
        
        // Top-right corner arc
        path.addQuadCurve(
            to: CGPoint(x: width, y: cornerRadius + archHeight),
            control: CGPoint(x: width, y: archHeight)
        )
        
        // Go down right edge to bottom-right
        path.addLine(to: CGPoint(x: width, y: height))
        
        // Close the path
        path.closeSubpath()
        
        return path
    }
}

// MARK: - Rounded Corner

struct LegacyRoundedCorner: InsettableShape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let path = UIBezierPath(roundedRect: insetRect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius - insetAmount, height: radius - insetAmount))
        return Path(path.cgPath)
    }

    func inset(by amount: CGFloat) -> LegacyRoundedCorner {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

// MARK: - 全屏编辑视图

struct LegacyFullScreenEditorView: View {
    @Binding var text: String
    let onDelete: () -> Void
    let onSend: () -> Void
    let onStash: () -> Void
    
    @FocusState private var isEditorFocused: Bool
    
    var body: some View {
        NavigationStack {
            ZStack {
                LegacyHomeBackground()
                
                VStack(spacing: 20) {
                    // Editor Panel with Glass Surface
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $text)
                            .focused($isEditorFocused)
                            .font(.system(size: 18, weight: .medium, design: .rounded))
                            .lineSpacing(6)
                            .scrollContentBackground(.hidden)
                            .background(Color.clear)
                            .foregroundStyle(Color(white: 0.15))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        
                        HStack {
                            Spacer()
                            Text("\(text.count) 字")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(white: 0.45))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.3))
                                )
                        }
                    }
                    .padding(22)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white.opacity(0.35))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.65), .white.opacity(0.2)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.0
                            )
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 15, x: 0, y: 8)
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 22)
                }
            }
            .navigationTitle("编辑内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("删除", role: .destructive) {
                        onDelete()
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("暂存") {
                        onStash()
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    
                    Button("发送") {
                        onSend()
                    }
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.blue)
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            // Delay slightly to allow keyboard transition to animate smoothly
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isEditorFocused = true
            }
        }
    }
}

// MARK: - 语音波纹动画组件

struct LegacyBouncingVoiceVisualizer: View {
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(0..<9, id: \.self) { index in
                LegacyBouncingBar(index: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LegacyBouncingBar: View {
    let index: Int
    @State private var isAnimating = false
    
    private let animDuration: Double
    private let targetHeight: CGFloat
    
    init(index: Int) {
        self.index = index
        self.animDuration = Double.random(in: 0.45...0.75)
        
        switch index {
        case 0, 8: self.targetHeight = CGFloat.random(in: 12...18)
        case 1, 7: self.targetHeight = CGFloat.random(in: 22...34)
        case 2, 6: self.targetHeight = CGFloat.random(in: 36...52)
        case 3, 5: self.targetHeight = CGFloat.random(in: 52...72)
        case 4: self.targetHeight = CGFloat.random(in: 68...88)
        default: self.targetHeight = 15
        }
    }
    
    var body: some View {
        RoundedRectangle(cornerRadius: 3.5)
            .fill(
                LinearGradient(
                    colors: [
                        Color.green.opacity(0.85),
                        Color.green.opacity(0.4)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3.5)
                    .stroke(Color.white.opacity(0.4), lineWidth: 0.8)
            )
            .shadow(color: Color.green.opacity(0.12), radius: 6, x: 0, y: 3)
            .frame(width: 6, height: isAnimating ? targetHeight : 10)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: animDuration)
                    .repeatForever(autoreverses: true)
                ) {
                    isAnimating = true
                }
            }
    }
}

// MARK: - 实时麦克风振幅微型波波图
struct LegacyMicAmplitudeWaveform: View {
    let amplitude: Float
    let isRecording: Bool
    
    var body: some View {
        HStack(spacing: 2.5) {
            bar(heightFactor: 0.4)
            bar(heightFactor: 0.8)
            bar(heightFactor: 1.0)
            bar(heightFactor: 0.7)
            bar(heightFactor: 0.5)
        }
        .frame(width: 26, height: 20)
    }
    
    @ViewBuilder
    private func bar(heightFactor: CGFloat) -> some View {
        let amp = isRecording ? CGFloat(amplitude) : 0.0
        let height = 3.0 + (17.0 * amp * heightFactor)
        
        Capsule()
            .fill(isRecording ? Color.green : Color.gray)
            .frame(width: 2.5, height: height)
            .animation(.interactiveSpring(response: 0.12, dampingFraction: 0.55), value: height)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
