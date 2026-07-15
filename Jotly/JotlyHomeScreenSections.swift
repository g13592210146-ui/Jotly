import SwiftUI
import UIKit

// MARK: - 背景

struct HomeBackground: View {
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

            ArcWaveShape()
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

struct ArcWaveShape: Shape {
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

struct HomeHeader: View {
    @Binding var asrProvider: JotlyHomeViewModel.ASRProvider
    @Binding var displayMode: JotlyHomeViewModel.HomeDisplayMode
    @Binding var selectedAgentModel: LifeAgentLLMModel
    let modelPriceSummary: String
    let modelCostText: String
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
                        .glassCircleSurface(size: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("个人页")
            }

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

            Picker("显示模式", selection: $displayMode) {
                ForEach(JotlyHomeViewModel.HomeDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("显示模式")
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
}

// MARK: - 调试视图

struct DebugEmptyStateView: View {
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
        .cardStyle(isDraft: false, cornerRadius: 24)
    }
}

struct CardDebugHistoryView: View {
    let card: MemoryCard
    let turns: [AgentDebugTurn]
    @State private var selectedPrompt: AgentDebugTurn?
    @State private var selectedOutput: AgentDebugTurn?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(card.title)
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text("共保存 \(turns.count) 轮调试记录")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.48))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if turns.isEmpty {
                    DebugEmptyStateView(title: "暂无调试记录", message: "这张卡片还没有可查看的模型调用记录。")
                } else {
                    ForEach(turns.sorted { $0.createdAt > $1.createdAt }) { turn in
                        DebugConversationRow(
                            turn: turn,
                            onPromptTap: { selectedPrompt = turn },
                            onModelOutputTap: { selectedOutput = turn }
                        )
                        DebugFlowRow(turn: turn)
                    }
                }
            }
            .padding(16)
        }
        .background(HomeBackground())
        .navigationTitle("卡片调试")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selectedPrompt) { PromptDetailView(turn: $0) }
        .navigationDestination(item: $selectedOutput) { ModelOutputDetailView(turn: $0) }
    }
}

struct DebugConversationRow: View {
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

            DebugMessageBlock(title: "用户输入", text: turn.userText, tint: .blue)

            if !turn.modelName.isEmpty {
                DebugMessageBlock(title: "请求模型", text: turn.modelName, tint: .purple)
            }

            if turn.promptTokens != nil || turn.completionTokens != nil || turn.promptCacheHitTokens != nil || turn.promptCacheCreationTokens != nil || turn.promptCacheMissTokens != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.cyan.opacity(0.75))
                            .frame(width: 8, height: 8)
                        Text("Token 统计与缓存命中")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(white: 0.24))
                    }
                    
                    HStack(spacing: 8) {
                        if let input = turn.promptTokens {
                            tokenMetricCard(title: "输入 Token", value: input, color: .blue)
                        }
                        if let output = turn.completionTokens {
                            tokenMetricCard(title: "输出 Token", value: output, color: .purple)
                        }
                        if let hit = turn.promptCacheHitTokens {
                            let hitRateText: String? = {
                                guard let input = turn.promptTokens, input > 0 else { return nil }
                                return String(format: " (%.0f%%)", Double(hit) / Double(input) * 100)
                            }()
                            tokenMetricCard(title: "缓存命中", value: hit, subtext: hitRateText, color: .green)
                        }
                        if let created = turn.promptCacheCreationTokens {
                            tokenMetricCard(title: "缓存创建", value: created, color: .teal)
                        }
                        if let miss = turn.promptCacheMissTokens {
                            tokenMetricCard(title: "缓存未命中", value: miss, color: .orange)
                        }
                    }
                }
            } else if let tokenUsage = turn.tokenUsageText, !tokenUsage.isEmpty {
                DebugMessageBlock(title: "Token 使用与缓存命中", text: tokenUsage, tint: .cyan)
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

            DebugMessageBlock(
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
                DebugMessageBlock(title: "解析摘要", text: turn.decodedSummary, tint: .orange)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(isDraft: false, cornerRadius: 24)
    }

    private func tokenMetricCard(title: String, value: Int, subtext: String? = nil, color: Color) -> some View {
        VStack(alignment: .center, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.5))
            HStack(alignment: .lastTextBaseline, spacing: 1) {
                Text("\(value)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                if let subtext {
                    Text(subtext)
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(color.opacity(0.85))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 0.8)
        )
    }
}

struct DebugMessageBlock: View {
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

struct DebugFlowRow: View {
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
                    DebugFlowNodeView(node: node)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(isDraft: false, cornerRadius: 24)
    }
}

struct DebugFlowNodeView: View {
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

struct PromptSection: Identifiable, Equatable {
    let id: String
    let title: String
    let content: String
    let isUserContent: Bool
}

struct PromptSectionView: View {
    let section: PromptSection
    
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

struct SideIndexBar: View {
    let sections: [PromptSection]
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

struct PromptDetailView: View {
    let turn: AgentDebugTurn
    
    @State private var activeSectionId: String? = nil
    
    private func parseSections(from fullPrompt: String) -> [PromptSection] {
        if fullPrompt.contains("[cached_system]") {
            return parseLayeredSections(from: fullPrompt)
        }

        return parseLegacySections(from: fullPrompt)
    }

    private func parseLayeredSections(from fullPrompt: String) -> [PromptSection] {
        var sections: [PromptSection] = []
        var currentKey: String?
        var currentLines: [String] = []

        func flushCurrentSection() {
            guard let currentKey else { return }
            let content = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                currentLines.removeAll()
                return
            }
            sections.append(PromptSection(
                id: currentKey,
                title: layeredSectionTitle(for: currentKey),
                content: content,
                isUserContent: currentKey == "user"
            ))
            currentLines.removeAll()
        }

        for rawLine in fullPrompt.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") && !line.contains(" ") {
                flushCurrentSection()
                currentKey = String(line.dropFirst().dropLast())
            } else {
                currentLines.append(rawLine)
            }
        }
        flushCurrentSection()
        return sections
    }

    private func layeredSectionTitle(for key: String) -> String {
        switch key {
        case "cached_system":
            return "缓存底座"
        case "user":
            return "用户输入与上下文"
        default:
            if key.hasPrefix("skill:") {
                let skill = String(key.dropFirst("skill:".count))
                switch skill {
                case "birthday":
                    return "生日技能"
                default:
                    return skill
                }
            }
            return key
        }
    }

    private func parseLegacySections(from fullPrompt: String) -> [PromptSection] {
        var sections: [PromptSection] = []
        let parts = fullPrompt.components(separatedBy: "[user]\n")
        let systemPart = parts.first ?? ""
        let userPart = parts.count > 1 ? parts[1] : ""
        
        let cleanSystemPart = systemPart.replacingOccurrences(of: "[system]\n", with: "")
        let systemBlocks = cleanSystemPart.components(separatedBy: "## ")
        
        if let intro = systemBlocks.first, !intro.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(PromptSection(
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
            
            sections.append(PromptSection(
                id: "system_\(title)",
                title: title,
                content: content,
                isUserContent: false
            ))
        }
        
        if !userPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(PromptSection(
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
                            PromptSectionView(section: section)
                                .id(section.id)
                        }
                    }
                    .padding(22)
                    .padding(.trailing, 28)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                            proxy.scrollTo("user_content", anchor: .top)
                            activeSectionId = "user_content"
                        }
                    }
                }
                .overlay(alignment: .trailing) {
                    if !sections.isEmpty {
                        SideIndexBar(
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
        .background(HomeBackground())
        .navigationTitle("完整提示词")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ModelOutputDetailView: View {
    let turn: AgentDebugTurn

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("模型原始输出")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))

                DebugMessageBlock(
                    title: "模型原始输出 (完整 JSON)",
                    text: turn.modelOutput.isEmpty ? "等待模型返回..." : turn.modelOutput,
                    tint: .green
                )
            }
            .padding(22)
        }
        .background(HomeBackground())
        .navigationTitle("模型输出详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 任务卡片

private struct CardVoiceLongPressGesture: UIGestureRecognizerRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var lifecycle = CardVoicePressLifecycle()
        var canBegin: () -> Bool = { false }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            canBegin()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    let minimumDuration: TimeInterval
    let allowableMovement: CGFloat
    let canBegin: () -> Bool
    let onBegan: () -> Void
    let onChanged: (Bool) -> Void
    let onEnded: (Bool) -> Void
    let onCancelled: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = allowableMovement
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = context.coordinator
        context.coordinator.canBegin = canBegin
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        recognizer.minimumPressDuration = minimumDuration
        recognizer.allowableMovement = allowableMovement
        context.coordinator.canBegin = canBegin
    }

    func handleUIGestureRecognizerAction(_ recognizer: UILongPressGestureRecognizer, context: Context) {
        let isInside = recognizer.view.map {
            $0.bounds.contains(recognizer.location(in: $0))
        } ?? false

        let event: CardVoicePressLifecycle.Event
        switch recognizer.state {
        case .began:
            event = .began(isInside: isInside)
        case .changed:
            event = .moved(isInside: isInside)
        case .ended:
            event = .ended(isInside: isInside)
        case .cancelled, .failed:
            event = .cancelled
        default:
            return
        }

        for action in context.coordinator.lifecycle.handle(event) {
            switch action {
            case .start:
                onBegan()
            case .setCancelState(let shouldCancel):
                onChanged(!shouldCancel)
            case .finish(let shouldCancel):
                onEnded(!shouldCancel)
            case .cancel:
                onCancelled()
            }
        }
    }
}

struct TaskCardView: View {
    let card: MemoryCard
    let onSelectOption: (CardOption) -> Void
    let onDelete: () -> Void
    let activeVoiceCaptureCardID: String?
    let voiceAmplitude: Float
    let liveTranscript: String
    let isVoiceCaptureActive: Bool
    let isListScrolling: Bool
    let onBeginCardVoiceCapture: () -> Void
    let onEndCardVoiceCapture: () -> Void
    let onCancelCardVoiceCapture: () -> Void
    let onToggleHabitDate: ((String) -> Void)?
    let onToggleReceiptChildIgnored: ((String) -> Void)?

    @State private var pulseVisible = false
    @State private var isVoicePressCancelled = false
    @State private var isVoicePressStarted = false
    private let voicePressDelay: TimeInterval = 0.35
    private let voicePressMovementTolerance: CGFloat = 12

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    if card.status == .processing || card.status == .executing {
                        processingContent
                    } else if card.type == "reply" {
                    Text(replyAttributedContent)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(Color(white: 0.16))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityLabel(card.message)
                    } else if card.type == "habit" && card.status == .completed {
                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 6) {
                                Text(displayTitle)
                                    .font(.system(size: 20, weight: .bold, design: .rounded))
                                    .foregroundStyle(Color(white: 0.12))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text("打卡")
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.brown)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.brown.opacity(0.10), in: Capsule())
                            }

                            Text("本月第 \(card.habitCheckInDates?.count ?? 0) 次")
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(white: 0.22))

                            if !displayMessage.isEmpty {
                                Text(displayMessage)
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundStyle(Color(white: 0.4))
                                    .lineLimit(2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HabitMonthlyGrid(card: card, isInteractive: false, onToggleDate: { dateStr in
                            onToggleHabitDate?(dateStr)
                        })
                        .frame(maxWidth: 112, alignment: .trailing)
                    }
                    } else if card.status == .waitingConfirmation {
                        confirmationContent
                    } else {
                        completedOrFailedContent
                    }
                }
                .contentShape(Rectangle())
                .gesture(cardVoicePressGesture)

                if card.type == "habit", card.status != .completed {
                    HabitMonthlyGrid(card: card, isInteractive: card.status == .waitingConfirmation, onToggleDate: { dateStr in
                        onToggleHabitDate?(dateStr)
                    })
                    .padding(.top, 4)
                }

                if card.status == .waitingConfirmation, !card.options.isEmpty {
                    ApprovalOptionsView(options: card.options, onSelect: onSelectOption)
                        .padding(.top, 6)
                }

            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CardSurfaceBackground(card: card))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.055), radius: 12, x: 0, y: 5)

            if isCardVoiceCaptureActive {
                cardVoiceCaptureOverlay
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale))
            }
        }
        .onDisappear {
            cancelPendingVoicePress()
        }
        .onChange(of: isCardVoiceCaptureActive) { _, newValue in
            if !newValue {
                resetVoicePressState()
            }
        }
        .onChange(of: isListScrolling) { _, scrolling in
            guard scrolling, !isCardVoiceCaptureActive else { return }
            cancelPendingVoicePress()
        }
    }

    private var canStartCardVoiceCapture: Bool {
        card.id != "card_idle"
            && card.type != "draft"
            && !isListScrolling
            && (card.status == .completed || card.status == .waitingConfirmation)
    }

    private var replyAttributedContent: AttributedString {
        (try? AttributedString(markdown: card.message)) ?? AttributedString(card.message)
    }

    private var isCardVoiceCaptureActive: Bool {
        activeVoiceCaptureCardID == card.id && isVoiceCaptureActive
    }

    private var cardVoicePressGesture: CardVoiceLongPressGesture {
        CardVoiceLongPressGesture(
            minimumDuration: voicePressDelay,
            allowableMovement: voicePressMovementTolerance,
            canBegin: { canStartCardVoiceCapture },
            onBegan: beginVoicePressIfNeeded,
            onChanged: { isInsideCard in
                updateVoicePressCancelState(isInsideCard: isInsideCard)
            },
            onEnded: { isInsideCard in
                isVoicePressCancelled = !isInsideCard
                finishVoicePress()
            },
            onCancelled: cancelPendingVoicePress
        )
    }

    private func beginVoicePressIfNeeded() {
        guard !isVoicePressStarted else { return }
        guard canStartCardVoiceCapture, !isCardVoiceCaptureActive else { return }
        isVoicePressStarted = true
        isVoicePressCancelled = false
        onBeginCardVoiceCapture()
    }

    private func finishVoicePress() {
        let pressStarted = isVoicePressStarted
        isVoicePressStarted = false
        guard pressStarted, isCardVoiceCaptureActive else {
            resetVoicePressState()
            return
        }

        let shouldCancel = isVoicePressCancelled
        resetVoicePressState()
        if shouldCancel {
            onCancelCardVoiceCapture()
        } else {
            onEndCardVoiceCapture()
        }
    }

    private func cancelPendingVoicePress() {
        let shouldCancelCapture = isVoicePressStarted && isCardVoiceCaptureActive
        isVoicePressStarted = false
        if shouldCancelCapture {
            onCancelCardVoiceCapture()
        }
        resetVoicePressState()
    }

    private func resetVoicePressState() {
        isVoicePressStarted = false
        isVoicePressCancelled = false
    }

    private func updateVoicePressCancelState(isInsideCard: Bool) {
        guard isVoicePressStarted, isCardVoiceCaptureActive else { return }
        let shouldCancel = !isInsideCard
        if shouldCancel != isVoicePressCancelled {
            isVoicePressCancelled = shouldCancel
            if shouldCancel {
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }
        }
    }

    private var cardVoiceCaptureOverlay: some View {
        GeometryReader { _ in
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: isVoicePressCancelled
                                        ? [Color.red.opacity(0.20), Color.red.opacity(0.08), Color.white.opacity(0.18)]
                                        : [Color.white.opacity(0.42), Color.white.opacity(0.14), Color(red: 0.76, green: 0.88, blue: 0.98).opacity(0.24)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
                    )

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(isVoicePressCancelled ? Color.red : Color.green)
                            .frame(width: 8, height: 8)
                            .shadow(color: (isVoicePressCancelled ? Color.red : Color.green).opacity(0.4), radius: 8)

                        Text(isVoicePressCancelled ? "松手取消" : "正在识别")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(isVoicePressCancelled ? Color.red : Color.green)
                    }
                    
                    if !isVoicePressCancelled && !liveTranscript.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "quote.opening")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Color.green.opacity(0.6))
                                .padding(.top, 2)
                            Text(liveTranscript)
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(white: 0.15))
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                        }
                        .padding(.horizontal, 12)
                    }

                    MicAmplitudeWaveform(amplitude: voiceAmplitude, isRecording: true)
                        .frame(height: 36)

                    Text(isVoicePressCancelled ? "松手即可取消本次输入" : "手指移出卡片区域即可取消")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.42))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .overlay(alignment: .center) {
                Circle()
                    .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    .frame(width: 88, height: 88)
                    .scaleEffect(pulseVisible ? 1.22 : 0.88)
                    .opacity(pulseVisible ? 0.06 : 0.18)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                            pulseVisible = true
                        }
                    }
            }
            .contentShape(Rectangle())
        }
    }

    private func reminderBadge(_ reminder: CardReminderInfo, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: reminder.type == "lunar" ? "moon.stars" : "bell")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
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

    private func reminderBadgeText(_ reminder: CardReminderInfo) -> String? {
        if let nextTriggerDate = reminder.nextTriggerDate {
            if let date = DateFormatting.dateTime(from: nextTriggerDate) {
                return "下次 \(DateFormatting.badgeString(from: date))"
            }
            return "下次 \(nextTriggerDate)"
        }
        if reminder.type == "lunar" || reminder.type == "solar" {
            return "\(reminder.type == "lunar" ? "农历" : "阳历") 提前 \(reminder.remindBeforeDays) 天"
        }
        return nil
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

    @ViewBuilder
    private var processingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(processingInputText)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.16))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 9) {
                Circle()
                    .fill(Color.blue.opacity(0.85))
                    .frame(width: 8, height: 8)
                    .symbolEffect(.pulse, options: .repeating)
                ProcessingStatusText(text: processingStatusText)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var processingInputText: String {
        if let visible = card.userVisibleInput?.trimmingCharacters(in: .whitespacesAndNewlines), !visible.isEmpty {
            return visible
        }
        if card.imageInputMode != nil
            || card.originalText.hasPrefix("用户上传")
            || card.originalText.hasPrefix("用户通过快捷指令") {
            return "正在分析图片"
        }
        return card.originalText.isEmpty ? "正在整理这条内容" : card.originalText
    }

    private var processingStatusText: String {
        if let value = card.metadata?["processing_status"], !value.isEmpty {
            return value
        }
        return card.imageInputMode == nil ? "正在整理卡片" : "正在识别图片内容"
    }

    @ViewBuilder
    private var confirmationContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(displayTitle)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.12))
                .fixedSize(horizontal: false, vertical: true)

            if !displayMessage.isEmpty {
                Text(displayMessage)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(Color(white: 0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isBirthdayCard {
                birthdayDetails
            }
        }
    }

    @ViewBuilder
    private var completedOrFailedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(displayTitle)
                    .font(.system(size: card.id == "card_idle" ? 26 : 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.12))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if !isBirthdayCard,
                   let reminder = card.reminderInfo,
                   reminder.type != "record",
                   let badgeText = reminderBadgeText(reminder),
                   !badgeText.isEmpty {
                    reminderBadge(reminder, text: badgeText)
                } else if let cardTypeBadgeText {
                    Text(cardTypeBadgeText)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.38))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.72), in: Capsule())
                }
            }

            if card.isUpdated == true, !isBirthdayCard {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("已更新")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.green.opacity(0.92))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.green.opacity(0.11), in: Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !displayMessage.isEmpty {
                Text(displayMessage)
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(card.status == .failed ? Color.red.opacity(0.82) : Color(white: 0.38))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isBirthdayCard {
                birthdayDetails
            }

            if !card.attributes.isEmpty,
               card.type != "asset",
               card.type != "subscription",
               !isBirthdayCard {
                attributeList(Array(card.attributes.prefix(4)))
            }

            if card.type == "subscription", card.status == .completed {
                subscriptionDetails
            } else if card.type == "asset", card.status == .completed {
                assetDetails
            }

            if card.type == "receipt", !card.children.isEmpty {
                ReceiptChildrenView(
                    children: card.children,
                    onToggleIgnored: { childID in
                        onToggleReceiptChildIgnored?(childID)
                    }
                )
            }

            if card.type == "countdown" {
                CountdownDisplayView(card: card)
                    .padding(.top, 4)
            }
        }
    }

    private var isBirthdayCard: Bool {
        card.type == "birthday" || card.type == "birthday_reminder"
    }

    @ViewBuilder
    private var birthdayDetails: some View {
        VStack(spacing: 9) {
            HStack(spacing: 9) {
                birthdayInfoBlock(
                    label: "人物",
                    value: birthdayPersonText,
                    tint: Color(red: 0.95, green: 0.47, blue: 0.60)
                )
                birthdayInfoBlock(
                    label: "日期",
                    value: birthdayDateText,
                    tint: Color(red: 0.96, green: 0.58, blue: 0.30)
                )
            }

            if let nextReminderText = birthdayNextReminderText {
                birthdayInfoBlock(
                    label: "下次提醒",
                    value: nextReminderText,
                    tint: Color(red: 0.32, green: 0.55, blue: 0.96)
                )
            }

            if card.status == .completed,
               let reminder = card.reminderInfo,
               reminder.type != "record" {
                Text("已创建日历提醒")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.green.opacity(0.95))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }

    private func birthdayInfoBlock(label: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint.opacity(0.78))
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.20))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var birthdayPersonText: String {
        firstNonEmpty([
            card.reminderInfo?.personName,
            card.metadata?["person_name"],
            card.entities?.personName
        ]) ?? "待确认"
    }

    private var birthdayDateText: String {
        if card.reminderInfo?.type == "lunar",
           let month = card.entities?.lunarMonth,
           let day = card.entities?.lunarDay {
            return "农历 \(month)月\(day)日"
        }

        let rawDate = firstNonEmpty([
            card.metadata?["birthday_date_text"],
            card.metadata?["date_text"],
            card.reminderInfo?.date,
            card.entities?.dateText,
            card.entities?.date
        ]) ?? "待确认"
        let conciseDate = birthdayConciseDate(rawDate)
        guard !conciseDate.contains("阳历"), !conciseDate.contains("农历") else {
            return conciseDate
        }
        switch card.reminderInfo?.type {
        case "solar": return "阳历 \(conciseDate)"
        case "lunar": return "农历 \(conciseDate)"
        default: return conciseDate
        }
    }

    private func birthdayConciseDate(_ value: String) -> String {
        guard let date = DateFormatting.dateTime(from: value) else { return value }
        let components = Calendar(identifier: .gregorian).dateComponents([.month, .day], from: date)
        guard let month = components.month, let day = components.day else { return value }
        return "\(month)月\(day)日"
    }

    private var birthdayNextReminderText: String? {
        guard let value = firstNonEmpty([card.reminderInfo?.nextTriggerDate]) else { return nil }
        if let date = DateFormatting.dateTime(from: value) {
            return DateFormatting.badgeString(from: date)
        }
        return value
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
                continue
            }
            return trimmed
        }
        return nil
    }

    @ViewBuilder
    private func attributeList(_ attributes: [CardAttribute]) -> some View {
        VStack(spacing: 8) {
            ForEach(attributes) { attribute in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(attribute.label)
                        .foregroundStyle(Color(white: 0.48))
                    Spacer(minLength: 12)
                    Text(attribute.value)
                        .foregroundStyle(Color(white: 0.18))
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .padding(.top, 2)
    }

    @ViewBuilder
    private var subscriptionDetails: some View {
        let metadata = card.metadata ?? [:]
        let amount = metadata["amount"] ?? ""
        let currency = metadata["currency"] ?? ""
        let cycle = metadata["billing_cycle"] ?? ""
        let nextDate = metadata["next_billing_date"] ?? ""
        VStack(alignment: .leading, spacing: 7) {
            if !card.attributes.isEmpty {
                attributeList(Array(card.attributes.prefix(4)))
            }
            if !amount.isEmpty {
                Label("\(currency) \(amount)", systemImage: "creditcard.fill")
            }
            if !cycle.isEmpty {
                Label("扣费周期：\(subscriptionCycleText(cycle))", systemImage: "repeat")
            }
            if !nextDate.isEmpty {
                Label("下次扣费：\(nextDate)", systemImage: "calendar")
            }
            if let progress = subscriptionProgress {
                ProgressView(value: progress)
                    .tint(Color.blue.opacity(0.75))
                    .accessibilityLabel("订阅周期进度")
            }
        }
        .font(.system(size: 13, weight: .medium, design: .rounded))
        .foregroundStyle(Color(white: 0.38))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var assetDetails: some View {
        if !card.attributes.isEmpty {
            attributeList(Array(card.attributes.prefix(4)))
        } else {
            let items = assetDisplayItems
            if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(items.prefix(8).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline) {
                        Text(item["name"] ?? "商品")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Spacer(minLength: 8)
                        if let amount = item["amount"], !amount.isEmpty {
                            Text("¥\(amount)")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Color(white: 0.45))
                        }
                    }
                    if let note = item["estimate_note"], !note.isEmpty {
                        Text(note)
                            .font(.system(size: 11, weight: .regular, design: .rounded))
                            .foregroundStyle(Color.orange.opacity(0.85))
                    }
                }
                if items.count > 8 {
                    Text("另有 \(items.count - 8) 件商品")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.5))
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private var subscriptionProgress: Double? {
        guard let startText = card.metadata?["billing_start_date"] ?? card.metadata?["last_billing_date"],
              let endText = card.metadata?["next_billing_date"],
              let start = cardDate(startText),
              let end = cardDate(endText),
              end > start else { return nil }
        return min(max(Date().timeIntervalSince(start) / end.timeIntervalSince(start), 0), 1)
    }

    private func cardDate(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }

    private var assetDisplayItems: [[String: String]] {
        guard let json = card.metadata?["asset_items_json"],
              let data = json.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return [] }
        return items
    }

    private func subscriptionCycleText(_ value: String) -> String {
        switch value.lowercased() {
        case "weekly": return "每周"
        case "monthly": return "每月"
        case "quarterly": return "每季度"
        case "yearly", "annual": return "每年"
        default: return value
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
            return [card.completionMessage, card.cardBody, card.message, card.summary]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? ""
        case .failed:
            return card.message.isEmpty ? "你可以重新说一次。" : card.message
        case .waitingConfirmation:
            return card.message
        }
    }

    private var cardTypeBadgeText: String? {
        switch card.type {
        case "birthday", "birthday_reminder": return "生日"
        case "countdown": return "倒计时"
        case "countup": return "正计时"
        case "asset": return "资产"
        case "subscription": return "订阅"
        case "receipt": return "小票"
        default: return nil
        }
    }

}

private struct ProcessingStatusText: View {
    let text: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 2.4) / 2.4

            Text(text)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(white: 0.25),
                            Color.blue.opacity(0.95),
                            Color(white: 0.25)
                        ],
                        startPoint: UnitPoint(x: phase - 0.45, y: 0.5),
                        endPoint: UnitPoint(x: phase + 0.45, y: 0.5)
                    )
                )
        }
        .accessibilityLabel(text)
    }
}

private struct ReceiptChildrenView: View {
    let children: [CardChild]
    let onToggleIgnored: (String) -> Void

    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 9) {
            ForEach(children) { child in
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: symbolName(for: child.cardType))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(child.isIgnored ? Color.gray : Color.blue)
                            .frame(width: 30, height: 30)
                            .background(Color.white.opacity(0.72), in: Circle())

                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.title)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(child.isIgnored ? Color.gray : Color(white: 0.18))
                            Text(child.body)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(Color(white: 0.46))
                                .lineLimit(expandedIDs.contains(child.id) ? nil : 1)
                        }

                        Spacer(minLength: 4)

                        Button(child.isIgnored ? "恢复" : "忽略") {
                            onToggleIgnored(child.id)
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .buttonStyle(.borderless)

                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                if expandedIDs.contains(child.id) {
                                    expandedIDs.remove(child.id)
                                } else {
                                    expandedIDs.insert(child.id)
                                }
                            }
                        } label: {
                            Image(systemName: expandedIDs.contains(child.id) ? "chevron.up" : "chevron.down")
                                .font(.system(size: 12, weight: .bold))
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                    }

                    if expandedIDs.contains(child.id), !child.attributes.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(child.attributes.prefix(4)) { attribute in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(attribute.label)
                                    Spacer(minLength: 10)
                                    Text(attribute.value)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(white: 0.38))
                        .padding(.leading, 40)
                    }
                }
                .padding(12)
                .background(
                    child.isIgnored ? Color.gray.opacity(0.07) : Color.white.opacity(0.62),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .opacity(child.isIgnored ? 0.7 : 1)
            }
        }
    }

    private func symbolName(for type: String) -> String {
        switch type {
        case "habit": return "checkmark.circle.fill"
        case "asset": return "shippingbox.fill"
        case "reminder": return "bell.fill"
        default: return "doc.text.fill"
        }
    }
}

private struct CardSurfaceBackground: View {
    let card: MemoryCard

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(uiColor: .secondarySystemBackground)
            background

            if card.type == "asset", let path = card.backgroundImagePath {
                CardAssetBackgroundImage(relativePath: path)
            }

            if card.status != .processing,
               card.status != .executing,
               let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(symbolColor)
                    .padding(18)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        if card.status == .processing || card.status == .executing {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 3.2) / 3.2

                LinearGradient(
                    colors: [
                        Color.white,
                        Color.blue.opacity(0.10),
                        Color.cyan.opacity(0.09),
                        Color.white
                    ],
                    startPoint: UnitPoint(x: phase - 0.75, y: 0.05),
                    endPoint: UnitPoint(x: phase + 0.95, y: 0.95)
                )
            }
        } else {
            LinearGradient(colors: palette, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var palette: [Color] {
        switch card.backgroundStyle {
        case .brandTint:
            return [Color.blue.opacity(0.10), Color.white]
        case .illustration:
            return [Color.orange.opacity(0.09), Color.pink.opacity(0.08), Color.white]
        case .atmosphereImage:
            return [Color.teal.opacity(0.09), Color.blue.opacity(0.08), Color.white]
        case .assetImage:
            return [Color.indigo.opacity(0.09), Color.white]
        case .animatedGradient:
            return [Color.blue.opacity(0.08), Color.cyan.opacity(0.07), Color.white]
        case .plain:
            break
        }

        switch card.type {
        case "birthday", "birthday_reminder":
            return [Color.orange.opacity(0.10), Color.pink.opacity(0.09), Color.white]
        case "habit", "check_in":
            return [Color.brown.opacity(0.10), Color.orange.opacity(0.07), Color.white]
        case "countdown", "countup":
            return [Color.blue.opacity(0.10), Color.teal.opacity(0.08), Color.white]
        case "asset", "receipt":
            return [Color.indigo.opacity(0.09), Color.blue.opacity(0.05), Color.white]
        case "subscription":
            return [Color.blue.opacity(0.10), Color.cyan.opacity(0.06), Color.white]
        default:
            return [Color.white, Color(white: 0.985)]
        }
    }

    private var symbolName: String? {
        switch card.type {
        case "birthday", "birthday_reminder": return "birthday.cake"
        case "habit", "check_in": return "cup.and.saucer.fill"
        case "countdown", "countup": return "mountain.2.fill"
        case "asset": return "shippingbox.fill"
        case "subscription": return "repeat.circle.fill"
        case "receipt": return "receipt.fill"
        default: return nil
        }
    }

    private var symbolColor: Color {
        switch card.type {
        case "birthday", "birthday_reminder": return .pink.opacity(0.08)
        case "habit", "check_in": return .brown.opacity(0.08)
        case "countdown", "countup": return .blue.opacity(0.08)
        default: return .indigo.opacity(0.07)
        }
    }
}

private struct CardAssetBackgroundImage: View {
    let relativePath: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(0.88), Color.white.opacity(0.66)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }
        }
        .clipped()
        .task(id: relativePath) {
            guard let url = try? CardBackgroundImageStore.absoluteURL(for: relativePath),
                  let data = try? await Task.detached(priority: .utility, operation: {
                      try Data(contentsOf: url)
                  }).value else { return }
            image = UIImage(data: data)
        }
        .accessibilityHidden(true)
    }
}

struct CardListRow: View {
    let card: MemoryCard
    @Binding var revealedDeleteCardID: String?
    let onSelectOption: (CardOption) -> Void
    let onDelete: () -> Void
    let onDraftTap: () -> Void
    let onSwipeDelete: () -> Void
    let onDebugTap: () -> Void
    let activeVoiceCaptureCardID: String?
    let voiceAmplitude: Float
    let liveTranscript: String
    let isVoiceCaptureActive: Bool
    let isListScrolling: Bool
    let onBeginCardVoiceCapture: () -> Void
    let onEndCardVoiceCapture: () -> Void
    let onCancelCardVoiceCapture: () -> Void
    let onToggleHabitDate: ((String) -> Void)?
    let onToggleReceiptChildIgnored: ((String) -> Void)?

    @State private var dragOffset: CGFloat = 0
    @State private var isDeleteDragActive = false

    private let deleteRevealWidth: CGFloat = 82

    var body: some View {
        ZStack(alignment: .trailing) {
            if revealedDeleteCardID == card.id || dragOffset < -0.5 {
                deleteButton
            }

            TaskCardView(
                card: card,
                onSelectOption: onSelectOption,
                onDelete: onDelete,
                activeVoiceCaptureCardID: activeVoiceCaptureCardID,
                voiceAmplitude: voiceAmplitude,
                liveTranscript: liveTranscript,
                isVoiceCaptureActive: isVoiceCaptureActive,
                isListScrolling: isListScrolling,
                onBeginCardVoiceCapture: onBeginCardVoiceCapture,
                onEndCardVoiceCapture: onEndCardVoiceCapture,
                onCancelCardVoiceCapture: onCancelCardVoiceCapture,
                onToggleHabitDate: onToggleHabitDate,
                onToggleReceiptChildIgnored: onToggleReceiptChildIgnored
            )
            .contentShape(Rectangle())
            .offset(x: dragOffset)
            .simultaneousGesture(deleteRevealGesture)
            .modifier(CardRowTapModifier(
                isEnabled: true,
                action: {
                    if card.type == "draft" {
                        onDraftTap()
                    } else if revealedDeleteCardID == card.id {
                        closeDeleteReveal()
                    } else {
                        onDebugTap()
                    }
                }
            ))
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
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
                guard !isVoiceCaptureActive else { return }
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
                guard !isVoiceCaptureActive else { return }
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

private struct CardRowTapModifier: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.onTapGesture(perform: action)
        } else {
            content
        }
    }
}

struct SafeAreaBottomReader: View {
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

struct ApprovalOptionsView: View {
    let options: [CardOption]
    let onSelect: (CardOption) -> Void

    @State private var tappedOption: String? = nil
    @State private var tappedActionButton: String? = nil

    private var visibleOptions: [CardOption] {
        options.filter { option in
            option.value != "request_more_info"
                && !option.label.localizedStandardContains("补充信息")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let simpleOptions = visibleOptions.filter { $0.actionButtons?.isEmpty != false }
            let groupedOptions = visibleOptions.filter { $0.actionButtons?.isEmpty == false }

            if !simpleOptions.isEmpty {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(simpleOptions) { option in
                        simpleOptionButton(option, ordinal: ordinal(for: option))
                    }
                }
            }

            if !groupedOptions.isEmpty {
                VStack(spacing: 8) {
                    ForEach(groupedOptions) { option in
                        optionRow(option, ordinal: ordinal(for: option))
                    }
                }
            }
        }
    }

    private func simpleOptionButton(_ option: CardOption, ordinal: Int) -> some View {
        Button {
            tappedOption = option.id
            onSelect(option)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                tappedOption = nil
            }
        } label: {
            HStack(spacing: 8) {
                optionOrdinal(ordinal)
                Text(displayLabel(for: option))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.18))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 12)
            .background(
                tappedOption == option.id
                    ? Color.blue.opacity(0.18)
                    : Color.blue.opacity(0.09),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ option: CardOption, ordinal: Int) -> some View {
        let hasActionButtons = option.actionButtons?.isEmpty == false

        return HStack(spacing: 10) {
            if hasActionButtons {
                optionLabel(option, ordinal: ordinal)
            } else {
                Button {
                    tappedOption = option.id
                    onSelect(option)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        tappedOption = nil
                    }
                } label: {
                    optionLabel(option, ordinal: ordinal)
                }
                .buttonStyle(.plain)
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
                            Text(displayLabel(for: actionButton, in: option))
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

    private func optionLabel(_ option: CardOption, ordinal: Int) -> some View {
        HStack(spacing: 10) {
            optionOrdinal(ordinal)

            Text(displayLabel(for: option))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Color(white: 0.2))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
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
    }

    private func ordinal(for option: CardOption) -> Int {
        (visibleOptions.firstIndex(where: { $0.id == option.id }) ?? 0) + 1
    }

    private func displayLabel(for option: CardOption) -> String {
        switch option.value {
        case "create_solar_birthday_reminder":
            return "阳历"
        case "create_lunar_birthday_reminder":
            return "农历"
        case "record_only":
            return "仅记录"
        default:
            return option.label
        }
    }

    private func displayLabel(for actionButton: CardActionButton, in option: CardOption) -> String {
        guard option.value == "create_solar_birthday_reminder"
                || option.value == "create_lunar_birthday_reminder" else {
            return actionButton.label
        }

        return actionButton.label
            .replacingOccurrences(of: "提前", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private func optionOrdinal(_ ordinal: Int) -> some View {
        Text("\(ordinal)")
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .foregroundStyle(Color(white: 0.32))
            .frame(width: 24, height: 24)
            .background(Color.white.opacity(0.62), in: Circle())
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

struct HabitMonthlyGrid: View {
    let card: MemoryCard
    let isInteractive: Bool
    let onToggleDate: (String) -> Void
    
    var body: some View {
        let calendar = Calendar.current
        let now = Date()
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let range = calendar.range(of: .day, in: .month, for: now)!
        let daysCount = range.count
        
        let checkedDates = card.habitCheckInDates ?? []
        let todayDay = calendar.component(.day, from: now)
        
        if isInteractive {
            // Interactive Mode (waitingConfirmation)
            VStack(alignment: .leading, spacing: 8) {
                Text("本月打卡进程（已打卡 \(checkedDates.count) 次）")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.45))
                    
                let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(1...daysCount, id: \.self) { day in
                        let dateStr = String(format: "%04d-%02d-%02d", year, month, day)
                        let count = checkedDates.filter { $0 == dateStr }.count
                        let isChecked = count > 0
                        let isFuture = day > todayDay
                        
                        Button(action: {
                            if !isFuture {
                                onToggleDate(dateStr)
                            }
                        }) {
                            Circle()
                                .fill(isChecked ? Color.green : (isFuture ? Color(white: 0.94) : Color(white: 0.85)))
                                .overlay(
                                    VStack(spacing: 1) {
                                        Text("\(day)")
                                            .font(.system(size: 8, weight: .bold, design: .rounded))
                                            .foregroundStyle(isChecked ? .white : (isFuture ? Color(white: 0.6) : Color(white: 0.3)))
                                        
                                        if count > 0 {
                                            HStack(spacing: 1) {
                                                ForEach(0..<min(count, 3), id: \.self) { _ in
                                                    Circle()
                                                        .fill(Color.white)
                                                        .frame(width: 2.2, height: 2.2)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.top, count > 0 ? 2 : 0)
                                )
                                .aspectRatio(1, contentMode: .fit)
                        }
                        .buttonStyle(.plain)
                        .disabled(isFuture)
                    }
                }
            }
            .padding(12)
            .background(Color(white: 0.96))
            .cornerRadius(16)
        } else {
            // Thumbnail Mode (completed)
            VStack(alignment: .leading, spacing: 6) {
                let columns = Array(repeating: GridItem(.fixed(10), spacing: 5), count: 10)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                    ForEach(1...daysCount, id: \.self) { day in
                        let dateStr = String(format: "%04d-%02d-%02d", year, month, day)
                        let count = checkedDates.filter { $0 == dateStr }.count
                        let isFuture = day > todayDay
                        
                        Circle()
                            .fill(
                                count == 0 ? (isFuture ? Color(white: 0.94) : Color(white: 0.88)) :
                                count == 1 ? Color.green.opacity(0.45) :
                                count == 2 ? Color.green.opacity(0.75) :
                                Color.green
                            )
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .padding(8)
            .background(Color(white: 0.96))
            .cornerRadius(10)
        }
    }
}

struct CountdownDisplayView: View {
    let card: MemoryCard
    
    var body: some View {
        if let targetDate = targetDate {
            let calendar = Calendar.current
            let startOfToday = calendar.startOfDay(for: Date())
            let startOfTarget = calendar.startOfDay(for: targetDate)
            let components = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget)
            let days = components.day ?? 0
            
            VStack(alignment: .center, spacing: 6) {
                if days > 0 {
                    Text("距离 \(card.title) 还有")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                    Text("\(days)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.blue)
                    Text("天")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                } else if days < 0 {
                    Text("\(card.title) 已经过去")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                    Text("\(abs(days))")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.orange)
                    Text("天")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                } else {
                    Text("就是今天！")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.green)
                    Text(card.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.45))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(white: 0.96))
            .cornerRadius(16)
        }
    }
    
    private var targetDate: Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        let dateStr = card.targetDateString ?? card.metadata?["target_date"] ?? card.metadata?["date"]
        if let first10 = dateStr?.prefix(10) {
            return formatter.date(from: String(first10))
        }
        return nil
    }
}

// MARK: - 自适应卡片图标提供者
struct CardIconProvider {
    static func iconName(forType type: String, title: String) -> String {
        let t = title.lowercased()
        if type == "habit" {
            if t.contains("咖啡") || t.contains("coffee") { return "cup.and.saucer.fill" }
            if t.contains("睡") || t.contains("晚安") || t.contains("sleep") { return "moon.stars.fill" }
            if t.contains("水") || t.contains("water") { return "drop.fill" }
            if t.contains("健身") || t.contains("运动") || t.contains("跑") || t.contains("workout") { return "dumbbell.fill" }
            if t.contains("学习") || t.contains("读") || t.contains("study") { return "book.closed.fill" }
            return "checkmark.shield.fill"
        } else {
            if t.contains("比赛") || t.contains("黑客") || t.contains("hackathon") || t.contains("comp") { return "trophy.fill" }
            if t.contains("考") || t.contains("学") || t.contains("exam") { return "book.fill" }
            if t.contains("生日") || t.contains("birthday") { return "gift.fill" }
            if t.contains("旅行") || t.contains("游") || t.contains("出差") || t.contains("trip") { return "airplane" }
            if t.contains("休") || t.contains("假") || t.contains("vacation") { return "sun.max.fill" }
            return "alarm.fill"
        }
    }
    
    static func iconColor(forType type: String, title: String) -> Color {
        let t = title.lowercased()
        if type == "habit" {
            if t.contains("咖啡") { return .brown }
            if t.contains("睡") { return .indigo }
            if t.contains("水") { return .blue }
            if t.contains("健身") { return .orange }
            return .green
        } else {
            if t.contains("比赛") || t.contains("黑客") { return .yellow }
            if t.contains("生日") { return .pink }
            if t.contains("旅行") { return .cyan }
            return .blue
        }
    }
}

// MARK: - 精精致致的双列正方形 Widget 卡片
struct SquareCardView: View {
    let card: MemoryCard
    @Binding var revealedDeleteCardID: String?
    let isVoiceCaptureActive: Bool
    let onToggleHabitDate: (String) -> Void
    let onDelete: () -> Void
    let onDebugTap: () -> Void
    
    @State private var dragOffset: CGFloat = 0
    @State private var isDeleteDragActive = false
    private let deleteRevealWidth: CGFloat = 64
    
    var body: some View {
        let iconName = CardIconProvider.iconName(forType: card.type, title: card.title)
        let iconColor = CardIconProvider.iconColor(forType: card.type, title: card.title)
        
        ZStack(alignment: .trailing) {
            deleteButton
            
            VStack(alignment: .leading, spacing: 8) {
            // Top Row: Icon on left, status indicator on right
            HStack {
                Image(systemName: iconName)
                    .font(.system(size: 14))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(iconColor.opacity(0.12))
                    .clipShape(Circle())
                
                Spacer()
                
                Circle()
                    .fill(card.status == .completed ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
            }
            
            // Title
            Text(card.title)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.12))
                .lineLimit(1)
            
            Spacer(minLength: 0)
            
            // Content values
            if card.type == "habit" {
                let checkedDates = card.habitCheckInDates ?? []
                let totalCount = checkedDates.count
                
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(totalCount)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.green)
                        Text("累计次")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    
                    Spacer()
                    
                    // Compact mini dot grid
                    let calendar = Calendar.current
                    let now = Date()
                    let year = calendar.component(.year, from: now)
                    let month = calendar.component(.month, from: now)
                    let columns = Array(repeating: GridItem(.fixed(5), spacing: 2), count: 7)
                    
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(1...28, id: \.self) { day in
                            let dateStr = String(format: "%04d-%02d-%02d", year, month, day)
                            let count = checkedDates.filter { $0 == dateStr }.count
                            Circle()
                                .fill(count > 0 ? Color.green : Color(white: 0.9))
                                .frame(width: 5, height: 5)
                        }
                    }
                    .frame(width: 47)
                }
            } else {
                // Countdown/Count-up
                let days = daysRemaining()
                
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(abs(days))")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(days >= 0 ? Color.blue : Color.orange)
                        Text(days >= 0 ? "剩余天" : "已过去")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(white: 0.5))
                    }
                    
                    Spacer()
                    
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(targetDateLabel())
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(white: 0.4))
                        Text("目标日")
                            .font(.system(size: 8, weight: .regular, design: .rounded))
                            .foregroundStyle(Color(white: 0.6))
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.white)
            .cornerRadius(18)
            .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(white: 0.94), lineWidth: 1)
            )
            .offset(x: dragOffset)
            .gesture(deleteRevealGesture)
            .onTapGesture {
                if revealedDeleteCardID == card.id {
                    closeDeleteReveal()
                } else {
                    onDebugTap()
                }
            }
            .onChange(of: revealedDeleteCardID) { _, newValue in
                if newValue != card.id && dragOffset < 0 {
                    closeDeleteReveal()
                }
            }
        }
    }
    
    private var deleteButton: some View {
        Button(role: .destructive, action: {
            onDelete()
            closeDeleteReveal()
        }) {
            Image(systemName: "trash.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
                .frame(width: deleteRevealWidth - 16, height: 48)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.red)
                )
        }
        .padding(.trailing, 8)
        .buttonStyle(.plain)
    }

    private var deleteRevealGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onChanged { value in
                guard !isVoiceCaptureActive else { return }
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
                guard !isVoiceCaptureActive else { return }
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

    private func daysRemaining() -> Int {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        guard let target = targetDate() else { return 0 }
        let startOfTarget = calendar.startOfDay(for: target)
        let components = calendar.dateComponents([.day], from: startOfToday, to: startOfTarget)
        return components.day ?? 0
    }
    
    private func targetDate() -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let dateStr = card.targetDateString ?? card.metadata?["target_date"] ?? card.metadata?["date"]
        if let first10 = dateStr?.prefix(10) {
            return formatter.date(from: String(first10))
        }
        return nil
    }
    
    private func targetDateLabel() -> String {
        let dateStr = card.targetDateString ?? card.metadata?["target_date"] ?? card.metadata?["date"] ?? ""
        if dateStr.count >= 10 {
            return String(dateStr.prefix(10).suffix(5)) // Show MM-dd
        }
        return dateStr
    }
}
