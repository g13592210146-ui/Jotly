import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - 语音浮层

struct VoiceCaptureOverlay: View {
    @ObservedObject var model: JotlyHomeViewModel
    let dragTranslation: CGSize
    let onVoiceCompletion: (JotlyHomeViewModel.VoiceCompletionResult) -> Void
    
    @State private var animatePulse = false
    @State private var showCancelConfirmation = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    requestCancelConfirmation()
                }

            VStack(spacing: 0) {
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
                                MicAmplitudeWaveform(amplitude: model.voiceAmplitude, isRecording: model.isRecording)
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
                        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                            animatePulse = true
                        }
                    }

                    ZStack(alignment: .topLeading) {
                        if model.liveTranscript.isEmpty {
                            BouncingVoiceVisualizer()
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

                VStack(spacing: 10) {
                    ZStack {
                        LiquidConnectorCanvas(dragTranslation: dragTranslation, releaseAction: model.voiceReleaseAction)
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
                RoundedCorner(radius: 32, corners: [.topLeft, .topRight])
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedCorner(radius: 32, corners: [.topLeft, .topRight])
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
                        RoundedCorner(radius: 32, corners: [.topLeft, .topRight])
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

    private var overlayStatusText: String {
        if model.isVoiceHoldLocked {
            return "持续说话中"
        }
        return model.isRecording ? "正在听" : "准备听写"
    }

    private func actionCaption(for action: JotlyHomeViewModel.VoiceReleaseAction) -> String {
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

struct VoiceWaveBadge: View {
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

struct ComposerDock: View {
    let mode: JotlyHomeViewModel.InputMode
    let isRecording: Bool
    let draftTextSeed: String
    var isTextFocused: FocusState<Bool>.Binding
    let addIcon: String
    let onCameraTap: () -> Void
    let onVoicePressBegin: () -> Void
    let onVoiceDragChanged: (CGSize) -> Void
    let onVoiceRelease: () -> Void
    let onModeToggle: () -> Void
    let onTextSubmit: (String) -> Void
    let onAddTap: () -> Void

    @State private var isCameraPressed = false
    @State private var isAddPressed = false
    @State private var draftText = ""

    var body: some View {
        dockContent
    }

    private var dockContent: some View {
        HStack(spacing: isRecording ? 0 : DockMetrics.itemSpacing) {
            if !isRecording {
                DockIconButton(
                    icon: "camera",
                    isLeft: true,
                    accessibilityLabel: "打开相机",
                    action: onCameraTap,
                    isPressed: $isCameraPressed
                )
                .transition(.scale(scale: 0.01, anchor: .trailing).combined(with: .opacity))
            }

            ComposerPill(
                mode: mode,
                isRecording: isRecording,
                draftText: $draftText,
                isTextFocused: isTextFocused,
                onVoicePressBegin: onVoicePressBegin,
                onVoiceDragChanged: onVoiceDragChanged,
                onVoiceRelease: onVoiceRelease,
                onModeToggle: onModeToggle,
                onTextSubmit: {
                    let text = draftText
                    draftText = ""
                    onTextSubmit(text)
                }
            )
            .frame(maxWidth: .infinity)

            if !isRecording {
                DockIconButton(
                    icon: addIcon,
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
            ComposerDockBackground(
                isCameraPressed: isCameraPressed,
                isAddPressed: isAddPressed,
                isRecording: isRecording
            )
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isRecording)
        .onChange(of: draftTextSeed) { _, newValue in
            guard newValue != draftText else { return }
            draftText = newValue
        }
    }
}

struct DockIconButtonStyle: ButtonStyle {
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

struct DockIconButton: View {
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
        .buttonStyle(DockIconButtonStyle(isLeft: isLeft, isPressed: $isPressed))
        .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
        .contentShape(Circle())
        .accessibilityLabel(accessibilityLabel)
        .zIndex(isPressed ? 10 : 0)
    }
}

struct ComposerDockBackground: View {
    let isCameraPressed: Bool
    let isAddPressed: Bool
    let isRecording: Bool

    var body: some View {
        ZStack {
            if !isRecording {
                HStack(spacing: DockMetrics.itemSpacing) {
                    Color.clear
                        .glassCircleSurface(size: DockMetrics.sideButtonSize)
                        .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
                        .scaleEffect(isCameraPressed ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isCameraPressed)
                    
                    Spacer()
                    
                    Color.clear
                        .glassCircleSurface(size: DockMetrics.sideButtonSize)
                        .frame(width: DockMetrics.sideButtonSize, height: DockMetrics.sideButtonSize)
                        .scaleEffect(isAddPressed ? 1.15 : 1.0)
                        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isAddPressed)
                }
            }
            
            Color.clear
                .glassCapsuleSurface(cornerRadius: DockMetrics.pillCornerRadius)
                .frame(height: DockMetrics.pillHeight)
                .padding(.horizontal, isRecording ? 0 : (DockMetrics.sideButtonSize + DockMetrics.itemSpacing))
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: isRecording)
    }
}

struct ComposerPill: View {
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

struct RecordingFlag: View {
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

struct AddContentSheet: View {
    @Environment(\.dismiss) private var dismiss

    let onImagesPick: ([UIImage]) -> Void
    let onFilePick: (URL) -> Void
    @State private var showFileImporter = false
    @State private var isPickerLoaded = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isPickerLoaded {
                    PhotoLibraryPickerView { images in
                        onImagesPick(images)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                isPickerLoaded = true
                            }
                        }
                }

                Divider()

                Button {
                    showFileImporter = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.up")
                        Text("上传文件")
                    }
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .navigationTitle("添加内容")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onFilePick(url)
                dismiss()
            }
        }
    }
}

struct PhotoLibraryPickerView: UIViewControllerRepresentable {
    let onImagesPick: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onImagesPick: onImagesPick)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onImagesPick: ([UIImage]) -> Void

        init(onImagesPick: @escaping ([UIImage]) -> Void) {
            self.onImagesPick = onImagesPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                picker.dismiss(animated: true)
                return
            }

            var images = Array<UIImage?>(repeating: nil, count: results.count)
            let group = DispatchGroup()

            for (index, result) in results.enumerated() {
                let provider = result.itemProvider
                guard provider.canLoadObject(ofClass: UIImage.self) else { continue }

                group.enter()
                provider.loadObject(ofClass: UIImage.self) { object, _ in
                    if let image = object as? UIImage {
                        images[index] = image
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) { [weak picker] in
                let loadedImages = images.compactMap { $0 }
                if !loadedImages.isEmpty {
                    self.onImagesPick(loadedImages)
                }
                DispatchQueue.main.async {
                    picker?.dismiss(animated: true)
                }
            }
        }

        func pickerDidCancel(_ picker: PHPickerViewController) {
            picker.dismiss(animated: true)
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
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

struct ProfilePlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
        .navigationTitle("个人页")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") {
                    dismiss()
                }
            }
        }
    }
}
