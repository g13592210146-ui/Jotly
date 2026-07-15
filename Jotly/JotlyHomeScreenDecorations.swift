import SwiftUI
import UIKit

// MARK: - 液体连接与编辑器装饰

struct LiquidConnectorCanvas: View {
    let dragTranslation: CGSize
    let releaseAction: JotlyHomeViewModel.VoiceReleaseAction

    var body: some View {
        Canvas { context, size in
            context.addFilter(.alphaThreshold(min: 0.45, color: Color.white.opacity(0.25)))
            context.addFilter(.blur(radius: 22))

            context.drawLayer { ctx in
                let center = CGPoint(x: size.width / 2, y: size.height - 24)
                
                let baseRect = CGRect(
                    x: -80,
                    y: size.height - 48,
                    width: size.width + 160,
                    height: 142
                )
                ctx.fill(Path(ellipseIn: baseRect), with: .color(.black))

                let sourceRect = CGRect(
                    x: center.x - 25,
                    y: center.y - 25,
                    width: 50,
                    height: 50
                )
                ctx.fill(Path(ellipseIn: sourceRect), with: .color(.black))

                let dragX = dragTranslation.width
                let dragY = dragTranslation.height
                let dragDistance = sqrt(dragX * dragX + dragY * dragY)
                let deadzone: CGFloat = 10
                let activeThreshold: CGFloat = 65
                let progress = dragDistance > deadzone ? min((dragDistance - deadzone) / (activeThreshold - deadzone), CGFloat(1.0)) : CGFloat(0.0)

                if dragDistance > deadzone {
                    let dropX = center.x + dragX
                    let dropY = center.y + dragY
                    let dropRadius: CGFloat = 26 - 4 * sin(progress * .pi)
                    let dropRect = CGRect(
                        x: dropX - dropRadius,
                        y: dropY - dropRadius,
                        width: dropRadius * 2,
                        height: dropRadius * 2
                    )
                    ctx.fill(Path(ellipseIn: dropRect), with: .color(.black))
                    
                    let steps = 10
                    for i in 1..<steps {
                        let stepProgress = CGFloat(i) / CGFloat(steps)
                        let stepX = center.x + (dropX - center.x) * stepProgress
                        let stepY = center.y + (dropY - center.y) * stepProgress
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

struct ArchedSheetShape: Shape {
    var archHeight: CGFloat = 40
    var cornerRadius: CGFloat = 32

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height
        
        path.move(to: CGPoint(x: 0, y: height))
        path.addLine(to: CGPoint(x: 0, y: cornerRadius + archHeight))
        path.addQuadCurve(
            to: CGPoint(x: cornerRadius, y: archHeight),
            control: CGPoint(x: 0, y: archHeight)
        )
        path.addQuadCurve(
            to: CGPoint(x: width - cornerRadius, y: archHeight),
            control: CGPoint(x: width / 2, y: archHeight - archHeight * 2)
        )
        path.addQuadCurve(
            to: CGPoint(x: width, y: cornerRadius + archHeight),
            control: CGPoint(x: width, y: archHeight)
        )
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }
}

struct RoundedCorner: InsettableShape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let path = UIBezierPath(roundedRect: insetRect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius - insetAmount, height: radius - insetAmount))
        return Path(path.cgPath)
    }

    func inset(by amount: CGFloat) -> RoundedCorner {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct FullScreenEditorView: View {
    @Binding var text: String
    let onDelete: () -> Void
    let onSend: () -> Void
    let onStash: () -> Void
    
    @FocusState private var isEditorFocused: Bool
    
    var body: some View {
        NavigationStack {
            ZStack {
                HomeBackground()
                
                VStack(spacing: 20) {
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isEditorFocused = true
            }
        }
    }
}

struct BouncingVoiceVisualizer: View {
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(0..<9, id: \.self) { index in
                BouncingBar(index: index)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BouncingBar: View {
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

struct MicAmplitudeWaveform: View {
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
