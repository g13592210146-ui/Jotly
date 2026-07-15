import Foundation
import CryptoKit

nonisolated enum AppExperienceMode: String, CaseIterable, Identifiable {
    case regular
    case developer

    var id: String { rawValue }
    var title: String { self == .regular ? "常规模式" : "开发者模式" }
    var detail: String {
        self == .regular
            ? "只显示业务卡片和输入入口"
            : "显示模型、图片模式和完整调试信息"
    }
}

nonisolated enum CardStatus: String, Codable, CaseIterable {
    case idle
    case processing
    case waitingConfirmation = "waiting_confirmation"
    case executing
    case completed
    case failed
}

nonisolated enum BirthdayCalendarType: String, Codable {
    case recordOnly = "record_only"
    case solar
    case lunar
}

nonisolated enum ImageInputMode: String, CaseIterable, Identifiable, Codable {
    case ocr
    case directModel = "direct_model"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ocr:
            "本地 OCR"
        case .directModel:
            "模型直传"
        }
    }
}

nonisolated enum ShortcutAnalysisMode: String, CaseIterable, Identifiable, Codable {
    case screenshot
    case voice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenshot:
            "截图"
        case .voice:
            "语音"
        }
    }
}

nonisolated enum ShortcutAnalysisPhase: String, CaseIterable, Codable {
    case pending
    case processing
    case completed
    case cancelled
    case failed
}

nonisolated struct ShortcutAnalysisOperation: Identifiable, Codable, Equatable {
    let id: String
    let mode: ShortcutAnalysisMode
    let createdAt: Date
    var updatedAt: Date
    var phase: ShortcutAnalysisPhase
    var resultCardId: String?
    var resultTitle: String?
    var resultSummary: String?
    var resultMessage: String?
    var cancelRequested: Bool
    var openAppRequested: Bool

    var displayTitle: String {
        "Jotly | \(mode.title)"
    }

    var statusLabel: String {
        switch phase {
        case .pending, .processing:
            "正在处理"
        case .completed:
            "已完成"
        case .cancelled:
            "已取消"
        case .failed:
            "处理失败"
        }
    }

    var isActive: Bool {
        phase == .pending || phase == .processing
    }
}

nonisolated struct RawInput: Identifiable, Codable, Equatable {
    let id: String
    let type: String
    let text: String
    let createdAt: Date
    let linkedCardId: String

    init(text: String, linkedCardId: String, type: String = "voice", createdAt: Date = Date()) {
        self.id = "input_\(UUID().uuidString)"
        self.type = type
        self.text = text
        self.createdAt = createdAt
        self.linkedCardId = linkedCardId
    }

    init(id: String, type: String, text: String, createdAt: Date, linkedCardId: String) {
        self.id = id
        self.type = type
        self.text = text
        self.createdAt = createdAt
        self.linkedCardId = linkedCardId
    }
}

nonisolated struct CardConversationMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let text: String
    let createdAt: Date

    init(role: Role, text: String, createdAt: Date = Date()) {
        self.id = "thread_\(UUID().uuidString)"
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

nonisolated struct ImageAttachment: Codable, Equatable {
    let data: Data
    let mimeType: String

    var dataURL: String {
        "data:\(mimeType);base64,\(data.base64EncodedString())"
    }
}

nonisolated enum ImageInputFingerprint {
    static func make(text: String, attachments: [ImageAttachment]) -> String {
        var data = Data(text.utf8)
        for attachment in attachments {
            data.append(contentsOf: attachment.dataURL.utf8)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }


    static func make(data: Data, text: String = "") -> String {
        var input = Data(text.utf8)
        input.append(data)
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CardBackgroundImageStore {
    static func relativePath(for cardID: String) -> String {
        "CardBackgrounds/\(cardID).jpg"
    }

    static func save(_ data: Data, for cardID: String) throws -> String {
        let relativePath = relativePath(for: cardID)
        let fileURL = try absoluteURL(for: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        return relativePath
    }

    static func absoluteURL(for relativePath: String) throws -> URL {
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return root.appendingPathComponent(relativePath, isDirectory: false)
    }
}

nonisolated struct CardOption: Identifiable, Codable, Equatable {
    var id: String { key }

    let key: String
    let label: String
    let value: String
    var description: String?
    var actions: [AgentToolPlan]?
    var actionButtons: [CardActionButton]?
    var nextStep: String?
    var resultCard: AgentOptionResultCard?

    enum CodingKeys: String, CodingKey {
        case key
        case label
        case value
        case description
        case actions
        case actionButtons = "action_buttons"
        case nextStep = "next_step"
        case resultCard = "result_card"
    }

    init(
        key: String,
        label: String,
        value: String,
        description: String? = nil,
        actions: [AgentToolPlan]? = nil,
        actionButtons: [CardActionButton]? = nil,
        nextStep: String? = nil,
        resultCard: AgentOptionResultCard? = nil
    ) {
        self.key = key
        self.label = label
        self.value = value
        self.description = description
        self.actions = actions
        self.actionButtons = actionButtons
        self.nextStep = nextStep
        self.resultCard = resultCard
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decodeIfPresent(String.self, forKey: .label) ?? "继续"
        let value = try container.decodeIfPresent(String.self, forKey: .value) ?? label
        self.init(
            key: try container.decodeIfPresent(String.self, forKey: .key) ?? value,
            label: label,
            value: value,
            description: try container.decodeIfPresent(String.self, forKey: .description),
            actions: try container.decodeIfPresent([AgentToolPlan].self, forKey: .actions),
            actionButtons: try container.decodeIfPresent([CardActionButton].self, forKey: .actionButtons),
            nextStep: try container.decodeIfPresent(String.self, forKey: .nextStep),
            resultCard: try container.decodeIfPresent(AgentOptionResultCard.self, forKey: .resultCard)
        )
    }

}

nonisolated struct CardActionButton: Identifiable, Codable, Equatable {
    var id: String { value }

    let label: String
    let value: String
    var actions: [AgentToolPlan]
    var nextStep: String?
    var resultCard: AgentOptionResultCard?

    enum CodingKeys: String, CodingKey {
        case label
        case value
        case actions
        case nextStep = "next_step"
        case resultCard = "result_card"
    }
}

nonisolated struct BirthdayEntities: Codable, Equatable {
    var personName: String?
    var eventType: String?
    var dateText: String?
    var date: String?
    var remindBeforeDays: Int?
    var lunarMonth: Int?
    var lunarDay: Int?
    var isLeapMonth: Bool?

    enum CodingKeys: String, CodingKey {
        case personName = "person_name"
        case eventType = "event_type"
        case dateText = "date_text"
        case date
        case remindBeforeDays = "remind_before_days"
        case lunarMonth = "lunar_month"
        case lunarDay = "lunar_day"
        case isLeapMonth = "is_leap_month"
    }
}

nonisolated struct DateTaskArtifact: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let year: Int?
    let occurrenceDate: String?
    let reminderDate: String?
    let calendarEventId: String?
    let reminderItemId: String?
    let notificationRequestId: String?
}

/// 卡片关联的提醒信息（用于卡片上展示）
nonisolated struct CardReminderInfo: Codable, Equatable {
    let type: String          // "solar" / "lunar" / "record"
    let personName: String
    let date: String
    let remindBeforeDays: Int
    let nextTriggerDate: String?  // 格式: yyyy-MM-dd 或 yyyy-MM-dd HH:mm
    let status: String        // "active" / "saved_lunar" / "none"
    let calendarEventId: String?
    let reminderItemId: String?
    let notificationRequestId: String?
    var artifacts: [DateTaskArtifact]? = nil
}

nonisolated enum CardBackgroundStyle: String, Codable, Equatable, Sendable {
    case plain
    case animatedGradient
    case illustration
    case atmosphereImage
    case brandTint
    case assetImage

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = CardBackgroundStyle(rawValue: (try? container.decode(String.self)) ?? "") ?? .plain
    }
}

nonisolated struct CardAttribute: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String { "\(label):\(value)" }
    let label: String
    let value: String
}

nonisolated struct CardMetric: Codable, Equatable, Hashable, Sendable, Identifiable {
    var id: String { "\(label):\(value):\(unit ?? "")" }
    let label: String
    let value: String
    let unit: String?
}

nonisolated struct CardChild: Codable, Equatable, Identifiable {
    let id: String
    let cardType: String
    let title: String
    let body: String
    let attributes: [CardAttribute]
    let actions: [AgentToolPlan]
    var status: String
    var isIgnored: Bool

    enum CodingKeys: String, CodingKey {
        case id, cardType, type, title, body, message, attributes, actions, status, isIgnored
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decodeIfPresent(String.self, forKey: .title) ?? "待处理事项"
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? "child_\(UUID().uuidString)"
        self.cardType = try container.decodeIfPresent(String.self, forKey: .cardType)
            ?? container.decodeIfPresent(String.self, forKey: .type)
            ?? "record"
        self.title = title
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
            ?? container.decodeIfPresent(String.self, forKey: .message)
            ?? title
        self.attributes = try container.decodeIfPresent([CardAttribute].self, forKey: .attributes) ?? []
        self.actions = try container.decodeIfPresent([AgentToolPlan].self, forKey: .actions) ?? []
        self.status = try container.decodeIfPresent(String.self, forKey: .status) ?? "pending"
        self.isIgnored = try container.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(cardType, forKey: .cardType)
        try container.encode(title, forKey: .title)
        try container.encode(body, forKey: .body)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(actions, forKey: .actions)
        try container.encode(status, forKey: .status)
        try container.encode(isIgnored, forKey: .isIgnored)
    }

    init(
        id: String,
        cardType: String,
        title: String,
        body: String,
        attributes: [CardAttribute] = [],
        actions: [AgentToolPlan] = [],
        status: String = "pending",
        isIgnored: Bool = false
    ) {
        self.id = id
        self.cardType = cardType
        self.title = title
        self.body = body
        self.attributes = attributes
        self.actions = actions
        self.status = status
        self.isIgnored = isIgnored
    }
}

nonisolated struct MemoryCard: Identifiable, Codable, Equatable {
    let id: String
    var type: String
    var title: String
    var status: CardStatus
    var originalText: String
    var summary: String
    var message: String
    var completionMessage: String?
    var options: [CardOption]
    var entities: BirthdayEntities?
    var supplementalText: String?
    var toolCandidates: [String]
    var selectedOptionValue: String?
    var reminderInfo: CardReminderInfo?   // 新增：提醒信息
    var toolPlan: [AgentToolPlan]?
    var metadata: [String: String]?
    var imageInputMode: ImageInputMode?
    var conversationMessages: [CardConversationMessage] = []
    var cardBody: String?
    var attributes: [CardAttribute]
    var metrics: [CardMetric]
    var backgroundStyle: CardBackgroundStyle
    var backgroundSemantic: String?
    var backgroundImagePath: String?
    var children: [CardChild]
    var userVisibleInput: String?
    let createdAt: Date
    var updatedAt: Date
    
    var parentId: String? = nil
    var habitCheckInDates: [String]? = nil
    var targetDateString: String? = nil
    var isUpdated: Bool? = nil
    var changeNote: String? = nil

    init(
        id: String,
        type: String,
        title: String,
        status: CardStatus,
        originalText: String,
        summary: String,
        message: String,
        completionMessage: String?,
        options: [CardOption],
        entities: BirthdayEntities?,
        supplementalText: String?,
        toolCandidates: [String],
        selectedOptionValue: String?,
        reminderInfo: CardReminderInfo?,
        toolPlan: [AgentToolPlan]?,
        metadata: [String: String]?,
        imageInputMode: ImageInputMode?,
        conversationMessages: [CardConversationMessage] = [],
        createdAt: Date,
        updatedAt: Date,
        cardBody: String? = nil,
        attributes: [CardAttribute] = [],
        metrics: [CardMetric] = [],
        backgroundStyle: CardBackgroundStyle = .plain,
        backgroundSemantic: String? = nil,
        backgroundImagePath: String? = nil,
        children: [CardChild] = [],
        userVisibleInput: String? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.status = status
        self.originalText = originalText
        self.summary = summary
        self.message = message
        self.completionMessage = completionMessage
        self.options = options
        self.entities = entities
        self.supplementalText = supplementalText
        self.toolCandidates = toolCandidates
        self.selectedOptionValue = selectedOptionValue
        self.reminderInfo = reminderInfo
        self.toolPlan = toolPlan
        self.metadata = metadata
        self.imageInputMode = imageInputMode
        self.conversationMessages = conversationMessages
        self.cardBody = cardBody
        self.attributes = attributes
        self.metrics = metrics
        self.backgroundStyle = backgroundStyle
        self.backgroundSemantic = backgroundSemantic
        self.backgroundImagePath = backgroundImagePath
        self.children = children
        self.userVisibleInput = userVisibleInput
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case status
        case originalText = "originalText"
        case summary
        case message
        case completionMessage
        case options
        case entities
        case supplementalText
        case toolCandidates
        case selectedOptionValue
        case reminderInfo
        case toolPlan
        case metadata
        case imageInputMode
        case conversationMessages
        case cardBody
        case attributes
        case metrics
        case backgroundStyle
        case backgroundSemantic
        case backgroundImagePath
        case children
        case userVisibleInput
        case createdAt
        case updatedAt
        case parentId
        case habitCheckInDates
        case targetDateString
        case isUpdated
        case changeNote
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            type: try container.decode(String.self, forKey: .type),
            title: try container.decode(String.self, forKey: .title),
            status: try container.decode(CardStatus.self, forKey: .status),
            originalText: try container.decode(String.self, forKey: .originalText),
            summary: try container.decode(String.self, forKey: .summary),
            message: try container.decode(String.self, forKey: .message),
            completionMessage: try container.decodeIfPresent(String.self, forKey: .completionMessage),
            options: try container.decode([CardOption].self, forKey: .options),
            entities: try container.decodeIfPresent(BirthdayEntities.self, forKey: .entities),
            supplementalText: try container.decodeIfPresent(String.self, forKey: .supplementalText),
            toolCandidates: try container.decodeIfPresent([String].self, forKey: .toolCandidates) ?? [],
            selectedOptionValue: try container.decodeIfPresent(String.self, forKey: .selectedOptionValue),
            reminderInfo: try container.decodeIfPresent(CardReminderInfo.self, forKey: .reminderInfo),
            toolPlan: try container.decodeIfPresent([AgentToolPlan].self, forKey: .toolPlan),
            metadata: try container.decodeIfPresent([String: String].self, forKey: .metadata),
            imageInputMode: try container.decodeIfPresent(ImageInputMode.self, forKey: .imageInputMode),
            conversationMessages: try container.decodeIfPresent([CardConversationMessage].self, forKey: .conversationMessages) ?? [],
            createdAt: try container.decode(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            cardBody: try container.decodeIfPresent(String.self, forKey: .cardBody),
            attributes: try container.decodeIfPresent([CardAttribute].self, forKey: .attributes) ?? [],
            metrics: try container.decodeIfPresent([CardMetric].self, forKey: .metrics) ?? [],
            backgroundStyle: try container.decodeIfPresent(CardBackgroundStyle.self, forKey: .backgroundStyle) ?? .plain,
            backgroundSemantic: try container.decodeIfPresent(String.self, forKey: .backgroundSemantic),
            backgroundImagePath: try container.decodeIfPresent(String.self, forKey: .backgroundImagePath),
            children: try container.decodeIfPresent([CardChild].self, forKey: .children) ?? [],
            userVisibleInput: try container.decodeIfPresent(String.self, forKey: .userVisibleInput)
        )
        self.parentId = try container.decodeIfPresent(String.self, forKey: .parentId)
        self.habitCheckInDates = try container.decodeIfPresent([String].self, forKey: .habitCheckInDates)
        self.targetDateString = try container.decodeIfPresent(String.self, forKey: .targetDateString)
        self.isUpdated = try container.decodeIfPresent(Bool.self, forKey: .isUpdated)
        self.changeNote = try container.decodeIfPresent(String.self, forKey: .changeNote)
    }

    static func idle() -> MemoryCard {
        MemoryCard(
            id: "card_idle",
            type: "system",
            title: "准备记录",
            status: .idle,
            originalText: "",
            summary: "",
            message: "长按说话后，我会在这里整理你的任务",
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
            conversationMessages: [],
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    static func processing(text: String) -> MemoryCard {
        let now = Date()
        return MemoryCard(
            id: "card_\(UUID().uuidString)",
            type: "processing",
            title: "刚刚记录",
            status: .processing,
            originalText: text,
            summary: "",
            message: "AI 正在整理……",
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
            conversationMessages: [],
            createdAt: now,
            updatedAt: now,
            backgroundStyle: .animatedGradient,
            userVisibleInput: text
        )
    }

    static func familyHolidayIntro() -> MemoryCard {
        let now = Date()
        return MemoryCard(
            id: "card_family_holiday_intro",
            type: "date_task",
            title: "家人节日提醒",
            status: .waitingConfirmation,
            originalText: "系统预设：母亲节和父亲节提醒",
            summary: "可创建母亲节和父亲节提醒",
            message: "我可以帮你记住母亲节和父亲节。当天提醒你，也可以提前几天先提醒一次，方便准备祝福或礼物。以后其他重要日期，也可以直接告诉我。",
            completionMessage: nil,
            options: [
                CardOption(
                    key: "A",
                    label: "暂不创建",
                    value: "record_only",
                    actions: [
                        AgentToolPlan(tool: "memory.save", when: "now", params: [
                            "title": .string("暂不创建家人节日提醒"),
                            "content": .string("用户暂时不创建母亲节和父亲节提醒。")
                        ])
                    ],
                    nextStep: "finish",
                    resultCard: AgentOptionResultCard(
                        type: "record",
                        title: "已记下",
                        summary: "暂不创建节日提醒",
                        message: "已先不创建。后续有任何重要日期，你都可以直接告诉我，我来帮你设置提醒。",
                        status: "completed"
                    )
                ),
                CardOption(
                    key: "B",
                    label: "创建节日提醒",
                    value: "create_family_holiday_reminders",
                    actionButtons: [1, 3, 5, 7].map { day in
                        CardActionButton(
                            label: "提前\(day)天",
                            value: "family_holiday_\(day)_days",
                            actions: [
                                AgentToolPlan(tool: "family_holiday_reminders.create", when: "now", params: [
                                    "remind_before_days": .number(Double(day))
                                ])
                            ],
                            nextStep: "finish",
                            resultCard: AgentOptionResultCard(
                                type: "date_task",
                                title: "节日提醒已创建",
                                summary: "母亲节和父亲节提醒",
                                message: "已创建母亲节和父亲节提醒。我会在当天提醒你，也会提前\(day)天提醒你准备祝福或礼物。",
                                status: "completed"
                            )
                        )
                    }
                )
            ],
            entities: nil,
            supplementalText: nil,
            toolCandidates: ["family_holiday_reminders.create", "memory.save"],
            selectedOptionValue: nil,
            reminderInfo: nil,
            toolPlan: nil,
            metadata: [
                "preset": "family_holiday_intro",
                "source": "app_initialization"
            ],
            imageInputMode: nil,
            conversationMessages: [],
            createdAt: now,
            updatedAt: now
        )
    }

    mutating func markUpdated() {
        updatedAt = Date()
    }
}

nonisolated struct BirthdayEvent: Identifiable, Codable, Equatable {
    let id: String
    let cardId: String
    let personName: String
    let date: String
    let calendarType: BirthdayCalendarType
    let lunarMonth: Int?
    let lunarDay: Int?
    let isLeapMonth: Bool
    let repeatRule: String
    let remindBeforeDays: Int
    let createdAt: Date
}

nonisolated struct ReminderTask: Identifiable, Codable, Equatable {
    let id: String
    let cardId: String
    let birthdayEventId: String
    let title: String
    let calendarType: BirthdayCalendarType
    let repeatRule: String
    let remindBeforeDays: Int
    let remindTime: String
    let nextTriggerAt: Date?
    let notificationMessage: String
    let status: String
    let calendarEventId: String?
    let reminderItemId: String?
    let notificationRequestId: String?
    var artifacts: [DateTaskArtifact]? = nil
}

nonisolated struct JotlyStoreSnapshot: Codable, Equatable {
    var rawInputs: [RawInput] = []
    var cards: [MemoryCard] = []
    var birthdayEvents: [BirthdayEvent] = []
    var reminderTasks: [ReminderTask] = []
    var shortcutOperations: [ShortcutAnalysisOperation] = []

    enum CodingKeys: String, CodingKey {
        case rawInputs
        case cards
        case birthdayEvents
        case reminderTasks
        case shortcutOperations
    }

    init(
        rawInputs: [RawInput] = [],
        cards: [MemoryCard] = [],
        birthdayEvents: [BirthdayEvent] = [],
        reminderTasks: [ReminderTask] = [],
        shortcutOperations: [ShortcutAnalysisOperation] = []
    ) {
        self.rawInputs = rawInputs
        self.cards = cards
        self.birthdayEvents = birthdayEvents
        self.reminderTasks = reminderTasks
        self.shortcutOperations = shortcutOperations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rawInputs = try container.decodeIfPresent([RawInput].self, forKey: .rawInputs) ?? []
        cards = try container.decodeIfPresent([MemoryCard].self, forKey: .cards) ?? []
        birthdayEvents = try container.decodeIfPresent([BirthdayEvent].self, forKey: .birthdayEvents) ?? []
        reminderTasks = try container.decodeIfPresent([ReminderTask].self, forKey: .reminderTasks) ?? []
        shortcutOperations = try container.decodeIfPresent([ShortcutAnalysisOperation].self, forKey: .shortcutOperations) ?? []
    }
}

nonisolated enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension JSONValue {
    nonisolated var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return String(value)
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            return value.lowercased() == "true" || value == "1"
        case .number(let value):
            return value != 0
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            if let number = Int(value) {
                return number
            }
            return Self.chineseInteger(from: value)
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value):
            return value
        case .string(let value):
            return Double(value)
        default:
            return nil
        }
    }

    private static func chineseInteger(from value: String) -> Int? {
        let normalized = value
            .replacingOccurrences(of: "初", with: "")
            .replacingOccurrences(of: "廿", with: "二十")
            .replacingOccurrences(of: "卅", with: "三十")
            .replacingOccurrences(of: "冬", with: "十一")
            .replacingOccurrences(of: "腊", with: "十二")
            .replacingOccurrences(of: "正", with: "一")
        let direct: [String: Int] = [
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
            "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12,
            "十三": 13, "十四": 14, "十五": 15, "十六": 16, "十七": 17, "十八": 18, "十九": 19,
            "二十": 20, "二十一": 21, "二十二": 22, "二十三": 23, "二十四": 24, "二十五": 25,
            "二十六": 26, "二十七": 27, "二十八": 28, "二十九": 29, "三十": 30
        ]
        return direct[normalized]
    }
}

nonisolated struct AgentCard: Codable, Equatable {
    let type: String
    let title: String
    let summary: String
    let message: String
    let options: [CardOption]
    var metadata: [String: String]? = nil
    var attributes: [CardAttribute] = []
    var metrics: [CardMetric] = []
    var status: String? = nil
    var backgroundStyle: CardBackgroundStyle? = nil
    var backgroundSemantic: String? = nil
    var children: [CardChild] = []
    
    enum CodingKeys: String, CodingKey {
        case type, title, summary, message, options, metadata
        case cardType
        case body
        case attributes, metrics, status, backgroundStyle, backgroundSemantic, children
    }

    init(
        type: String,
        title: String,
        summary: String,
        message: String,
        options: [CardOption],
        metadata: [String: String]? = nil,
        attributes: [CardAttribute] = [],
        metrics: [CardMetric] = [],
        status: String? = nil,
        backgroundStyle: CardBackgroundStyle? = nil,
        backgroundSemantic: String? = nil,
        children: [CardChild] = []
    ) {
        self.type = type
        self.title = title
        self.summary = summary
        self.message = message
        self.options = options
        self.metadata = metadata
        self.attributes = attributes
        self.metrics = metrics
        self.status = status
        self.backgroundStyle = backgroundStyle
        self.backgroundSemantic = backgroundSemantic
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let metadata = (try? container.decode([String: String].self, forKey: .metadata))
            ?? (try? container.decode([String: JSONValue].self, forKey: .metadata))?
                .compactMapValues(\.stringValue)
        self.init(
            type: try container.decodeIfPresent(String.self, forKey: .cardType)
                ?? container.decodeIfPresent(String.self, forKey: .type)
                ?? "record",
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            message: try container.decodeIfPresent(String.self, forKey: .body)
                ?? container.decodeIfPresent(String.self, forKey: .message)
                ?? "",
            options: try container.decodeIfPresent([CardOption].self, forKey: .options) ?? [],
            metadata: metadata,
            attributes: try container.decodeIfPresent([CardAttribute].self, forKey: .attributes) ?? [],
            metrics: try container.decodeIfPresent([CardMetric].self, forKey: .metrics) ?? [],
            status: try container.decodeIfPresent(String.self, forKey: .status),
            backgroundStyle: try container.decodeIfPresent(CardBackgroundStyle.self, forKey: .backgroundStyle),
            backgroundSemantic: try container.decodeIfPresent(String.self, forKey: .backgroundSemantic),
            children: try container.decodeIfPresent([CardChild].self, forKey: .children) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .cardType)
        try container.encode(title, forKey: .title)
        try container.encode(summary, forKey: .summary)
        try container.encode(message, forKey: .body)
        try container.encode(options, forKey: .options)
        try container.encodeIfPresent(metadata, forKey: .metadata)
        try container.encode(attributes, forKey: .attributes)
        try container.encode(metrics, forKey: .metrics)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(backgroundStyle, forKey: .backgroundStyle)
        try container.encodeIfPresent(backgroundSemantic, forKey: .backgroundSemantic)
        try container.encode(children, forKey: .children)
    }
}

nonisolated struct AgentOptionResultCard: Codable, Equatable {
    var type: String?
    var title: String?
    var summary: String?
    var message: String?
    var status: String?
}

nonisolated struct AgentToolPlan: Codable, Equatable {
    let tool: String
    let when: String
    let params: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case tool, when, params
    }

    init(tool: String, when: String, params: [String: JSONValue]) {
        self.tool = tool
        self.when = when
        self.params = params
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tool = try container.decode(String.self, forKey: .tool)
        when = try container.decodeIfPresent(String.self, forKey: .when) ?? "now"
        params = try container.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

nonisolated struct AgentMemoryToSave: Codable, Equatable, Sendable {
    let type: String
    let content: String
}

struct AgentRequestContext: Equatable {
    enum Mode: String, Equatable {
        case newCard = "new_card"
        case cardRevision = "card_revision"
        case optionContinue = "option_continue"
    }

    let mode: Mode
    let targetCardId: String?
    let cardSnapshot: MemoryCard?
    let lastExecutionResult: String?

    nonisolated static func newCard() -> AgentRequestContext {
        AgentRequestContext(
            mode: .newCard,
            targetCardId: nil,
            cardSnapshot: nil,
            lastExecutionResult: nil
        )
    }

    nonisolated static func cardRevision(card: MemoryCard) -> AgentRequestContext {
        AgentRequestContext(
            mode: .cardRevision,
            targetCardId: card.id,
            cardSnapshot: card,
            lastExecutionResult: nil
        )
    }

    nonisolated static func optionContinue(card: MemoryCard, lastExecutionResult: String) -> AgentRequestContext {
        AgentRequestContext(
            mode: .optionContinue,
            targetCardId: card.id,
            cardSnapshot: card,
            lastExecutionResult: lastExecutionResult
        )
    }
}

nonisolated struct AgentDebugTurn: Identifiable, Codable, Equatable, Hashable {
    nonisolated struct Node: Identifiable, Codable, Equatable, Hashable {
        nonisolated enum State: String, Codable, Equatable, Hashable {
            case pending = "等待"
            case running = "处理中"
            case completed = "完成"
            case failed = "失败"
        }

        let id: String
        var title: String
        var state: State
        var detail: String
        var startedAt: Date?
        var completedAt: Date?

        var durationText: String? {
            guard let startedAt else { return nil }
            let end = completedAt ?? Date()
            let duration = max(0, end.timeIntervalSince(startedAt))
            if duration < 1 {
                return "\(Int(duration * 1000))ms"
            }
            return String(format: "%.1fs", duration)
        }
    }

    let id: String
    let cardId: String
    var userText: String
    var systemPrompt: String
    var userPrompt: String
    var fullPrompt: String
    var modelName: String
    var modelOutput: String
    var decodedSummary: String
    var nodes: [Node]
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var promptCacheHitTokens: Int?
    var promptCacheMissTokens: Int?
    var promptCacheCreationTokens: Int?
    let createdAt: Date
    var updatedAt: Date

    init(
        cardId: String,
        userText: String,
        systemPrompt: String = "",
        userPrompt: String = "",
        fullPrompt: String = "",
        modelName: String = "",
        modelOutput: String = "",
        decodedSummary: String = "",
        nodes: [Node] = AgentDebugTurn.defaultNodes(),
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        promptCacheHitTokens: Int? = nil,
        promptCacheMissTokens: Int? = nil,
        promptCacheCreationTokens: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = "debug_\(UUID().uuidString)"
        self.cardId = cardId
        self.userText = userText
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.fullPrompt = fullPrompt
        self.modelName = modelName
        self.modelOutput = modelOutput
        self.decodedSummary = decodedSummary
        self.nodes = nodes
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.promptCacheCreationTokens = promptCacheCreationTokens
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    static func defaultNodes() -> [Node] {
        [
            Node(id: "input", title: "用户输入", state: .completed, detail: "已收到原始输入", startedAt: Date(), completedAt: Date()),
            Node(id: "prompt", title: "组装提示词", state: .pending, detail: "等待发送给模型"),
            Node(id: "model", title: "模型分析", state: .pending, detail: "等待模型返回"),
            Node(id: "decode", title: "解析 JSON", state: .pending, detail: "等待解析结构化结果"),
            Node(id: "memory", title: "记忆检索", state: .pending, detail: "等待判断是否需要记忆"),
            Node(id: "confirm", title: "确认判断", state: .pending, detail: "等待判断是否需要用户确认"),
            Node(id: "tool", title: "工具执行", state: .pending, detail: "等待执行计划"),
            Node(id: "finish", title: "最终反馈", state: .pending, detail: "等待生成卡片状态")
        ]
    }

    mutating func updateNode(id: String, state: Node.State, detail: String) {
        if let index = nodes.firstIndex(where: { $0.id == id }) {
            let now = Date()
            nodes[index].state = state
            nodes[index].detail = detail
            switch state {
            case .running:
                if nodes[index].startedAt == nil {
                    nodes[index].startedAt = now
                }
                nodes[index].completedAt = nil
            case .completed, .failed:
                if nodes[index].startedAt == nil {
                    nodes[index].startedAt = now
                }
                nodes[index].completedAt = now
            case .pending:
                nodes[index].startedAt = nil
                nodes[index].completedAt = nil
            }
        }
        updatedAt = Date()
    }

    var tokenUsageText: String? {
        guard promptTokens != nil || completionTokens != nil || totalTokens != nil || promptCacheHitTokens != nil || promptCacheMissTokens != nil || promptCacheCreationTokens != nil else {
            return nil
        }
        var parts: [String] = []
        if let promptTokens {
            parts.append("输入 \(promptTokens)")
        }
        if let completionTokens {
            parts.append("输出 \(completionTokens)")
        }
        if let totalTokens {
            parts.append("总计 \(totalTokens)")
        } else if let promptTokens, let completionTokens {
            parts.append("总计 \(promptTokens + completionTokens)")
        }
        if let promptCacheHitTokens {
            parts.append("缓存命中 \(promptCacheHitTokens)")
        }
        if let promptCacheCreationTokens {
            parts.append("缓存创建 \(promptCacheCreationTokens)")
        }
        if let promptCacheMissTokens {
            parts.append("缓存未命中 \(promptCacheMissTokens)")
        }
        return parts.joined(separator: " · ")
    }
}

struct DeepSeekDebugResponse {
    let analysis: AgentAnalysis
    let systemPrompt: String
    let userPrompt: String
    let fullPrompt: String
    let modelName: String
    let rawModelOutput: String
    let usage: AgentModelUsage?
    let estimatedCostCNY: Double
}

struct AgentModelUsage: Decodable, Equatable {
    let inputTokens: Int?
    let outputTokens: Int?
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptCacheHitTokens: Int?
    let promptCacheMissTokens: Int?
    let promptCacheCreationTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptCacheHitTokens = "prompt_cache_hit_tokens"
        case promptCacheMissTokens = "prompt_cache_miss_tokens"
        case promptCacheCreationTokens = "prompt_cache_creation_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    enum PromptTokensDetailsKeys: String, CodingKey {
        case cachedTokens = "cached_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }

    init(
        inputTokens: Int?,
        outputTokens: Int?,
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        promptCacheHitTokens: Int?,
        promptCacheMissTokens: Int?,
        promptCacheCreationTokens: Int?
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.promptCacheHitTokens = promptCacheHitTokens
        self.promptCacheMissTokens = promptCacheMissTokens
        self.promptCacheCreationTokens = promptCacheCreationTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
        let outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
        let promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens) ?? inputTokens
        let topLevelCacheHit = try container.decodeIfPresent(Int.self, forKey: .promptCacheHitTokens)
        let topLevelCacheMiss = try container.decodeIfPresent(Int.self, forKey: .promptCacheMissTokens)
        let topLevelCacheCreation = try container.decodeIfPresent(Int.self, forKey: .promptCacheCreationTokens)
        let details = try? container.nestedContainer(keyedBy: PromptTokensDetailsKeys.self, forKey: .promptTokensDetails)
        let detailCacheHit = try details?.decodeIfPresent(Int.self, forKey: .cachedTokens)
        let detailCacheCreation = try details?.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
        let cacheHit = topLevelCacheHit ?? detailCacheHit

        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.promptTokens = promptTokens
        self.completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens) ?? outputTokens
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens) ?? ((promptTokens ?? 0) + (outputTokens ?? 0))
        self.promptCacheHitTokens = cacheHit
        self.promptCacheCreationTokens = topLevelCacheCreation ?? detailCacheCreation
        if let topLevelCacheMiss {
            self.promptCacheMissTokens = topLevelCacheMiss
        } else if let promptTokens, let cacheHit {
            self.promptCacheMissTokens = max(promptTokens - cacheHit, 0)
        } else {
            self.promptCacheMissTokens = nil
        }
    }

    var summaryText: String {
        let input = promptTokens ?? 0
        let output = completionTokens ?? 0
        let total = totalTokens ?? input + output
        var parts = ["输入 \(input)", "输出 \(output)", "总计 \(total) tokens"]
        if let promptCacheHitTokens {
            parts.append("缓存命中 \(promptCacheHitTokens)")
        }
        if let promptCacheCreationTokens {
            parts.append("缓存创建 \(promptCacheCreationTokens)")
        }
        if let promptCacheMissTokens {
            parts.append("缓存未命中 \(promptCacheMissTokens)")
        }
        return parts.joined(separator: " · ")
    }
}

enum LifeAgentLLMModel: String, CaseIterable, Identifiable, Codable {
    case deepseekV4Pro = "deepseek-v4-pro"
    case deepseekV4Flash = "deepseek-v4-flash"
    case deepseekV4FlashThinking = "deepseek-v4-flash-thinking"
    case qwen37Plus = "qwen3.7-plus"
    case qwen36Flash = "qwen3.6-flash"
    case qwen35Flash = "qwen3.5-flash"
    case mimoV25ProUltraSpeed = "mimo-v2.5-pro-ultraspeed"
    case mimoV25Pro = "mimo-v2.5-pro"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepseekV4Pro:
            "DeepSeek V4 Pro"
        case .deepseekV4Flash:
            "DeepSeek V4 Flash"
        case .deepseekV4FlashThinking:
            "DeepSeek V4 Flash Thinking"
        case .qwen37Plus:
            "Qwen3.7 Plus"
        case .qwen36Flash:
            "Qwen3.6 Flash"
        case .qwen35Flash:
            "Qwen3.5 Flash"
        case .mimoV25ProUltraSpeed:
            "MiMo V2.5 Pro UltraSpeed"
        case .mimoV25Pro:
            "MiMo V2.5 Pro"
        }
    }

    var providerTitle: String {
        switch self {
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking:
            "DeepSeek"
        case .qwen37Plus, .qwen36Flash, .qwen35Flash:
            "百炼"
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            "小米 MiMo"
        }
    }

    var supportsDirectImageInput: Bool {
        switch self {
        case .qwen37Plus, .qwen36Flash, .qwen35Flash:
            true
        case .deepseekV4Pro, .deepseekV4Flash, .deepseekV4FlashThinking, .mimoV25ProUltraSpeed, .mimoV25Pro:
            false
        }
    }

    var imageInputSupportSummary: String {
        supportsDirectImageInput ? "OCR / 模型直传" : "仅本地 OCR"
    }

    var inputPricePerMillion: Double {
        switch self {
        case .deepseekV4Pro:
            3
        case .deepseekV4Flash:
            1
        case .deepseekV4FlashThinking:
            1
        case .qwen37Plus:
            2
        case .qwen36Flash:
            1.2
        case .qwen35Flash:
            0.2
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            0
        }
    }

    var cacheHitInputPricePerMillion: Double {
        switch self {
        case .deepseekV4Pro:
            0.025
        case .deepseekV4Flash:
            0.02
        case .deepseekV4FlashThinking:
            0.02
        case .qwen37Plus:
            0.4
        case .qwen36Flash:
            0.12
        case .qwen35Flash:
            0.02
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            0
        }
    }

    var outputPricePerMillion: Double {
        switch self {
        case .deepseekV4Pro:
            6
        case .deepseekV4Flash:
            2
        case .deepseekV4FlashThinking:
            2
        case .qwen37Plus:
            8
        case .qwen36Flash:
            7.2
        case .qwen35Flash:
            2
        case .mimoV25ProUltraSpeed, .mimoV25Pro:
            0
        }
    }

    var priceSummary: String {
        if inputPricePerMillion == 0, cacheHitInputPricePerMillion == 0, outputPricePerMillion == 0 {
            return "价格未配置"
        }
        return "输入 ¥\(Self.priceText(inputPricePerMillion))/M · 缓存 ¥\(Self.priceText(cacheHitInputPricePerMillion))/M · 输出 ¥\(Self.priceText(outputPricePerMillion))/M"
    }

    func estimatedCost(using usage: AgentModelUsage?) -> Double {
        guard let usage else { return 0 }
        let outputTokens = Double(usage.completionTokens ?? 0)

        if let cacheHit = usage.promptCacheHitTokens,
           let cacheMiss = usage.promptCacheMissTokens,
           cacheHit + cacheMiss > 0 {
            return Double(cacheMiss) / 1_000_000 * inputPricePerMillion
                + Double(cacheHit) / 1_000_000 * cacheHitInputPricePerMillion
                + outputTokens / 1_000_000 * outputPricePerMillion
        }

        return Double(usage.promptTokens ?? 0) / 1_000_000 * inputPricePerMillion
            + outputTokens / 1_000_000 * outputPricePerMillion
    }

    private static func priceText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
    }
}

struct AgentAnalysis: Codable, Equatable {
    let intent: String
    let riskLevel: String?
    let requiresConfirmation: Bool
    let shouldExecuteNow: Bool
    let card: AgentCard?
    let toolPlan: [AgentToolPlan]?
    let memoryToSave: [AgentMemoryToSave]?
    let userVisibleText: String?
    var reasoning: String? = nil
    var contextMode: String? = nil
    var targetCardId: String? = nil
    var withinCardScope: Bool? = nil
    var scopeReason: String? = nil
    var derivedCards: [AgentCard]? = nil
    var optimizedUserText: String? = nil
    var changeNote: String? = nil
    var needMemory: Bool? = nil
    var memoryQuery: String? = nil

    enum CodingKeys: String, CodingKey {
        case intent
        case riskLevel = "risk_level"
        case requiresConfirmation = "requires_confirmation"
        case shouldExecuteNow = "should_execute_now"
        case card
        case toolPlan = "tool_plan"
        case memoryToSave = "memory_to_save"
        case userVisibleText = "user_visible_text"
        case reasoning
        case contextMode = "context_mode"
        case targetCardId = "target_card_id"
        case withinCardScope = "within_card_scope"
        case scopeReason = "scope_reason"
        case derivedCards = "derived_cards"
        case optimizedUserText = "optimized_user_text"
        case changeNote = "change_note"
        case needMemory = "need_memory"
        case memoryQuery = "memory_query"
    }

    init(
        intent: String,
        riskLevel: String?,
        requiresConfirmation: Bool,
        shouldExecuteNow: Bool,
        card: AgentCard?,
        toolPlan: [AgentToolPlan]?,
        memoryToSave: [AgentMemoryToSave]?,
        userVisibleText: String?,
        reasoning: String? = nil,
        contextMode: String? = nil,
        targetCardId: String? = nil,
        withinCardScope: Bool? = nil,
        scopeReason: String? = nil,
        derivedCards: [AgentCard]? = nil,
        optimizedUserText: String? = nil,
        changeNote: String? = nil,
        needMemory: Bool? = nil,
        memoryQuery: String? = nil
    ) {
        self.intent = intent
        self.riskLevel = riskLevel
        self.requiresConfirmation = requiresConfirmation
        self.shouldExecuteNow = shouldExecuteNow
        self.card = card
        self.toolPlan = toolPlan
        self.memoryToSave = memoryToSave
        self.userVisibleText = userVisibleText
        self.reasoning = reasoning
        self.contextMode = contextMode
        self.targetCardId = targetCardId
        self.withinCardScope = withinCardScope
        self.scopeReason = scopeReason
        self.derivedCards = derivedCards
        self.optimizedUserText = optimizedUserText
        self.changeNote = changeNote
        self.needMemory = needMemory
        self.memoryQuery = memoryQuery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        intent = try container.decodeIfPresent(String.self, forKey: .intent) ?? "unknown"
        riskLevel = try container.decodeIfPresent(String.self, forKey: .riskLevel)
        requiresConfirmation = try container.decodeFlexibleBoolIfPresent(forKey: .requiresConfirmation) ?? false
        shouldExecuteNow = try container.decodeFlexibleBoolIfPresent(forKey: .shouldExecuteNow) ?? false
        card = try container.decodeIfPresent(AgentCard.self, forKey: .card)
        toolPlan = try container.decodeIfPresent([AgentToolPlan].self, forKey: .toolPlan)
        memoryToSave = try container.decodeIfPresent([AgentMemoryToSave].self, forKey: .memoryToSave)
        userVisibleText = try container.decodeIfPresent(String.self, forKey: .userVisibleText)
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning)
        contextMode = try container.decodeIfPresent(String.self, forKey: .contextMode)
        targetCardId = try container.decodeIfPresent(String.self, forKey: .targetCardId)
        withinCardScope = try container.decodeFlexibleBoolIfPresent(forKey: .withinCardScope)
        scopeReason = try container.decodeIfPresent(String.self, forKey: .scopeReason)
        derivedCards = try container.decodeIfPresent([AgentCard].self, forKey: .derivedCards)
        optimizedUserText = try container.decodeIfPresent(String.self, forKey: .optimizedUserText)
        changeNote = try container.decodeIfPresent(String.self, forKey: .changeNote)
        needMemory = try container.decodeFlexibleBoolIfPresent(forKey: .needMemory)
        memoryQuery = try container.decodeIfPresent(String.self, forKey: .memoryQuery)
    }

    // Compatibility properties
    var cardType: String { card?.type ?? "unknown" }
    var title: String { card?.title ?? "普通记录" }
    var summary: String { card?.summary ?? "普通记录" }
    var message: String { card?.message ?? userVisibleText ?? "我先帮你记下了。" }
    var options: [CardOption] { card?.options ?? [] }
    var toolCandidates: [String] { toolPlan?.map { $0.tool } ?? [] }

    var recommendedActionValue: String? {
        if shouldExecuteNow, let firstTool = toolPlan?.first?.tool {
            return firstTool
        }
        return nil
    }

    var entities: BirthdayEntities {
        var personName = card?.metadata?["person_name"]
        var date = card?.metadata?["date"]
            ?? card?.metadata?["solar_date"]
            ?? card?.metadata?["birthday_date_text"]
            ?? card?.metadata?["date_text"]
        var remindBeforeDays: Int? = nil
        var lunarMonth: Int? = nil
        var lunarDay: Int? = nil
        var isLeapMonth: Bool? = nil

        if let toolPlan = toolPlan {
            for plan in toolPlan {
                if let pName = plan.params["person_name"] {
                    if case .string(let s) = pName { personName = s }
                }
                if let pDate = plan.params["date"] {
                    if case .string(let s) = pDate { date = s }
                }
                if let pDays = plan.params["remind_before_days"] {
                    if case .number(let n) = pDays { remindBeforeDays = Int(n) }
                    else if case .string(let s) = pDays { remindBeforeDays = Int(s) }
                }
                if let pLunarMonth = plan.params["lunar_month"] {
                    if case .number(let n) = pLunarMonth { lunarMonth = Int(n) }
                    else if case .string(let s) = pLunarMonth { lunarMonth = Int(s) }
                }
                if let pLunarDay = plan.params["lunar_day"] {
                    if case .number(let n) = pLunarDay { lunarDay = Int(n) }
                    else if case .string(let s) = pLunarDay { lunarDay = Int(s) }
                }
                if let pLeap = plan.params["is_leap_month"] {
                    if case .bool(let b) = pLeap { isLeapMonth = b }
                    else if case .string(let s) = pLeap { isLeapMonth = (s == "true") }
                }
            }
        }

        return BirthdayEntities(
            personName: personName,
            eventType: cardType,
            dateText: date,
            date: date,
            remindBeforeDays: remindBeforeDays ?? 3,
            lunarMonth: lunarMonth,
            lunarDay: lunarDay,
            isLeapMonth: isLeapMonth ?? false
        )
    }

    func extractMetadata() -> [String: String] {
        var dict: [String: String] = [:]
        if let toolPlan = toolPlan {
            for plan in toolPlan {
                for (key, val) in plan.params {
                    switch val {
                    case .string(let s): dict[key] = s
                    case .number(let n): dict[key] = String(n)
                    case .bool(let b): dict[key] = String(b)
                    default: break
                    }
                }
            }
        }
        return dict
    }

    func makeCard(reusing card: MemoryCard) -> MemoryCard {
        var updated = card
        updated.type = cardType
        updated.title = title
        updated.status = requiresConfirmation ? .waitingConfirmation : .completed
        updated.originalText = card.originalText
        updated.summary = summary
        updated.message = message
        updated.cardBody = self.card?.message
        updated.options = options
        updated.attributes = self.card?.attributes ?? []
        updated.metrics = self.card?.metrics ?? []
        updated.backgroundStyle = self.card?.backgroundStyle ?? .plain
        updated.backgroundSemantic = self.card?.backgroundSemantic
        updated.children = self.card?.children ?? []
        updated.userVisibleInput = optimizedUserText ?? updated.userVisibleInput
        updated.entities = entities
        updated.supplementalText = card.supplementalText
        updated.toolCandidates = toolCandidates
        updated.selectedOptionValue = requiresConfirmation ? card.selectedOptionValue : recommendedActionValue
        updated.completionMessage = requiresConfirmation ? nil : message
        updated.toolPlan = toolPlan
        var mergedMetadata = card.metadata ?? [:]
        for (key, value) in self.card?.metadata ?? [:] {
            mergedMetadata[key] = value
        }
        for (key, value) in extractMetadata() {
            mergedMetadata[key] = value
        }
        updated.metadata = mergedMetadata.isEmpty ? nil : mergedMetadata
        updated.imageInputMode = card.imageInputMode
        updated.conversationMessages = card.conversationMessages
        updated.changeNote = changeNote ?? card.changeNote
        if card.status == .completed {
            updated.isUpdated = true
        }
        updated.markUpdated()
        return updated
    }

    func asMemoryReply() -> AgentAnalysis {
        let cardMessage = card?.message.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleMessage = userVisibleText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyText = cardMessage?.isEmpty == false
            ? cardMessage!
            : (visibleMessage?.isEmpty == false ? visibleMessage! : "没有找到相关记忆。")
        return AgentAnalysis(
            intent: "memory_answer",
            riskLevel: "low",
            requiresConfirmation: false,
            shouldExecuteNow: false,
            card: AgentCard(
                type: "reply",
                title: "",
                summary: "",
                message: replyText,
                options: [],
                metadata: ["content_format": card?.metadata?["content_format"] ?? "markdown"]
            ),
            toolPlan: nil,
            memoryToSave: [],
            userVisibleText: replyText,
            reasoning: reasoning,
            contextMode: contextMode,
            targetCardId: targetCardId,
            withinCardScope: withinCardScope,
            scopeReason: scopeReason,
            derivedCards: nil,
            optimizedUserText: optimizedUserText,
            changeNote: nil,
            needMemory: false,
            memoryQuery: memoryQuery
        )
    }

    static func birthdayOptions() -> [CardOption] {
        [
            CardOption(
                key: "A",
                label: "仅记录",
                value: "record_only",
                actions: [
                    AgentToolPlan(tool: "memory.save", when: "now", params: [:])
                ]
            ),
            CardOption(
                key: "B",
                label: "阳历",
                value: "create_solar_birthday_reminder",
                actionButtons: [
                    CardActionButton(
                        label: "3天",
                        value: "solar_3_days",
                        actions: [
                            AgentToolPlan(tool: "create_solar_birthday_reminder", when: "now", params: ["remind_before_days": .number(3)])
                        ],
                        nextStep: "finish"
                    ),
                    CardActionButton(
                        label: "6天",
                        value: "solar_6_days",
                        actions: [
                            AgentToolPlan(tool: "create_solar_birthday_reminder", when: "now", params: ["remind_before_days": .number(6)])
                        ],
                        nextStep: "finish"
                    )
                ]
            ),
            CardOption(
                key: "C",
                label: "农历",
                value: "create_lunar_birthday_reminder",
                actionButtons: [
                    CardActionButton(
                        label: "3天",
                        value: "lunar_3_days",
                        actions: [
                            AgentToolPlan(tool: "create_lunar_birthday_reminder", when: "now", params: ["remind_before_days": .number(3)])
                        ],
                        nextStep: "finish"
                    ),
                    CardActionButton(
                        label: "6天",
                        value: "lunar_6_days",
                        actions: [
                            AgentToolPlan(tool: "create_lunar_birthday_reminder", when: "now", params: ["remind_before_days": .number(6)])
                        ],
                        nextStep: "finish"
                    )
                ]
            )
        ]
    }

    static func dateOptions() -> [CardOption] {
        [
            CardOption(key: "A", label: "仅记录，不创建提醒", value: "record_only"),
            CardOption(key: "B", label: "创建日期提醒", value: "create_date_reminder")
        ]
    }

    static func birthdayFallback(
        originalText: String,
        currentDate: String,
        personName: String,
        remindBeforeDays: Int
    ) -> AgentAnalysis {
        AgentAnalysis(
            intent: "birthday_detected",
            riskLevel: "medium",
            requiresConfirmation: true,
            shouldExecuteNow: false,
            card: AgentCard(
                type: "birthday",
                title: "生日提醒",
                summary: "我理解这是 \(personName) 的生日。",
                message: "我可以帮每年提醒，但还需要确认这是阳历生日还是农历生日。",
                options: birthdayOptions()
            ),
            toolPlan: [
                AgentToolPlan(
                    tool: "memory.save",
                    when: "after_user_choice",
                    params: [
                        "type": .string("birthday"),
                        "person_name": .string(personName),
                        "date_text": .string("今天"),
                        "date": .string(currentDate),
                        "remind_before_days": .number(Double(remindBeforeDays))
                    ]
                )
            ],
            memoryToSave: [
                AgentMemoryToSave(type: "input_summary", content: "用户提到 \(personName) 今天生日。")
            ],
            userVisibleText: "我可以帮每年提醒，但还需要确认这是阳历生日还是农历生日。"
        )
    }

    static func dateFallback(
        originalText: String,
        currentDate: String,
        resolvedDate: String?,
        title: String,
        message: String
    ) -> AgentAnalysis {
        AgentAnalysis(
            intent: "date_task_detected",
            riskLevel: "medium",
            requiresConfirmation: true,
            shouldExecuteNow: false,
            card: AgentCard(
                type: "date_task",
                title: title,
                summary: "我理解这是一个需要提醒的事项。",
                message: message,
                options: dateOptions()
            ),
            toolPlan: [
                AgentToolPlan(
                    tool: "reminder.create",
                    when: "after_user_confirmation",
                    params: [
                        "type": .string("date_task"),
                        "title": .string(title),
                        "date": .string(resolvedDate ?? currentDate)
                    ]
                )
            ],
            memoryToSave: [
                AgentMemoryToSave(type: "date_task", content: originalText)
            ],
            userVisibleText: message
        )
    }

    static func recordFallback(originalText: String) -> AgentAnalysis {
        AgentAnalysis(
            intent: "record_only",
            riskLevel: "low",
            requiresConfirmation: false,
            shouldExecuteNow: true,
            card: AgentCard(
                type: "record",
                title: "普通记录",
                summary: "普通记录",
                message: "我先帮你记下了。",
                options: []
            ),
            toolPlan: [
                AgentToolPlan(
                    tool: "memory.save",
                    when: "now",
                    params: [
                        "type": .string("record"),
                        "content": .string(originalText)
                    ]
                )
            ],
            memoryToSave: [
                AgentMemoryToSave(type: "record", content: originalText)
            ],
            userVisibleText: "我先帮你记下了。"
        )
    }
}

private extension KeyedDecodingContainer {
    func decodeFlexibleBoolIfPresent(forKey key: Key) throws -> Bool? {
        if let value = try? decode(Bool.self, forKey: key) {
            return value
        }
        guard let value = try? decode(String.self, forKey: key) else {
            return nil
        }
        switch value.lowercased() {
        case "true", "1", "yes": return true
        case "false", "0", "no": return false
        default: return nil
        }
    }
}

enum DateFormatting {
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func todayString() -> String {
        dayFormatter.string(from: Date())
    }

    static func currentDateTimeString() -> String {
        dateTimeFormatter.string(from: Date())
    }

    static func currentMonthString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy年M月"
        return formatter.string(from: Date())
    }

    static func currentTimeZoneString() -> String {
        TimeZone.current.identifier
    }

    static func date(fromDayString value: String?) -> Date {
        guard let value else { return Date() }
        if let date = dayFormatter.date(from: value) {
            return date
        }
        if let date = dateTime(from: value) {
            return date
        }
        return Date()
    }

    static func userRequestDateTimeString(currentDateString: String) -> String {
        let calendar = Calendar.current
        let now = Date()
        let refDate = date(fromDayString: currentDateString)
        var components = calendar.dateComponents([.year, .month, .day], from: refDate)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: now)
        components.hour = timeComponents.hour
        components.minute = timeComponents.minute
        components.second = timeComponents.second
        if let merged = calendar.date(from: components) {
            return dateTimeFormatter.string(from: merged)
        }
        return dateTimeFormatter.string(from: now)
    }

    static func lunarDateString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .chinese)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "U年MMMd"
        return "农历" + formatter.string(from: date)
    }

    static func string(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func dateTimeString(from date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    static func dateTime(from value: String?) -> Date? {
        guard let value else { return nil }
        if let date = dateTimeFormatter.date(from: value) {
            return date
        }
        return dayFormatter.date(from: value)
    }

    static func badgeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current

        let year = Calendar.current.component(.year, from: date)
        let currentYear = Calendar.current.component(.year, from: Date())
        formatter.dateFormat = year == currentYear ? "M月d日 HH:mm" : "yyyy年M月d日 HH:mm"
        return formatter.string(from: date)
    }

    static func debugTimeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
