import SwiftUI
import UIKit

// MARK: - Home Screen Surface Helpers

extension View {
    @ViewBuilder
    func glassCircleSurface(size: CGFloat) -> some View {
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
    func glassCapsuleSurface(cornerRadius: CGFloat) -> some View {
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
    func glassRectSurface(cornerRadius: CGFloat) -> some View {
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
    func cardStyle(isDraft: Bool, cornerRadius: CGFloat) -> some View {
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
            self.whiteCard(cornerRadius: cornerRadius)
        }
    }

    /// 白色卡片 — 与背景区分，深色文字
    func whiteCard(cornerRadius: CGFloat) -> some View {
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
    func darkGlassCard(cornerRadius: CGFloat) -> some View {
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
