import Foundation
import os

struct BirthdayExecutionArtifacts {
    let calendarEventId: String?
    let reminderItemId: String?
    let notificationRequestId: String?
    var artifacts: [DateTaskArtifact] = []
}

@MainActor
final class BirthdayToolExecutor {
    private let scheduler = BirthdaySystemCoordinator()

    func execute(option: CardOption, card: MemoryCard) async throws -> BirthdayToolResult {
        // Check if date parameters are present. If not, fall back to record only to avoid errors/invalid reminders.
        let dateCandidates: [String?] = [
            card.metadata?["date"],
            card.metadata?["start_date"],
            card.metadata?["due_date"],
            card.metadata?["datetime"],
            card.metadata?["date_time"],
            card.metadata?["start_at"],
            card.metadata?["due_at"],
            card.metadata?["solar_date"],
            card.metadata?["birthday_date_text"],
            card.metadata?["date_text"],
            card.entities?.date,
            card.entities?.dateText
        ]
        let modelDateStr = dateCandidates.compactMap { $0 }.first
            
        let hasDate: Bool
        if option.value == "create_lunar_birthday_reminder" {
            let hasLunarMonth = card.entities?.lunarMonth != nil || card.metadata?["lunar_month"] != nil
            let hasLunarDay = card.entities?.lunarDay != nil || card.metadata?["lunar_day"] != nil
            let hasSolarDate = modelDateStr != nil && !modelDateStr!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            hasDate = (hasLunarMonth && hasLunarDay) || hasSolarDate
        } else {
            hasDate = modelDateStr != nil && !modelDateStr!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if !hasDate && option.value != "record_only" {
            JotlyLog.tool.info("execute: model date parameters missing, falling back to record_only.")
            return recordOnly(card: card)
        }

        switch option.value {
        case "record_only":
            return recordOnly(card: card)
        case "create_date_reminder":
            return try await createDateReminder(card: card)
        case "create_solar_birthday_reminder":
            return try await createSolarReminder(card: card)
        case "create_lunar_birthday_reminder":
            return try await createLunarReminder(card: card)
        default:
            throw JotlyError.unsupportedTool(option.value)
        }
    }

    func cancelArtifacts(for snapshot: JotlyStoreSnapshot, cardId: String) {
        scheduler.cancelArtifacts(for: snapshot, cardId: cardId)
    }

    func createFamilyHolidayReminders(card: MemoryCard, remindBeforeDays: Int) async throws -> BirthdayToolResult {
        let event = BirthdayEvent(
            id: "date_\(UUID().uuidString)",
            cardId: card.id,
            personName: "母亲节和父亲节",
            date: DateFormatting.todayString(),
            calendarType: .solar,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: false,
            repeatRule: "family_holiday_series",
            remindBeforeDays: remindBeforeDays,
            createdAt: Date()
        )
        let task = ReminderTask(
            id: "reminder_\(UUID().uuidString)",
            cardId: card.id,
            birthdayEventId: event.id,
            title: "母亲节和父亲节提醒",
            calendarType: .solar,
            repeatRule: "family_holiday_series",
            remindBeforeDays: remindBeforeDays,
            remindTime: "12:30",
            nextTriggerAt: nil,
            notificationMessage: "家人节日快到了，可以提前准备祝福或礼物。",
            status: "family_holiday_series",
            calendarEventId: nil,
            reminderItemId: nil,
            notificationRequestId: nil,
            artifacts: []
        )
        let artifacts = try await scheduler.persistFamilyHolidaySeries(event: event, task: task, remindBeforeDays: remindBeforeDays)
        let updatedTask = ReminderTask(
            id: task.id,
            cardId: task.cardId,
            birthdayEventId: task.birthdayEventId,
            title: task.title,
            calendarType: task.calendarType,
            repeatRule: task.repeatRule,
            remindBeforeDays: task.remindBeforeDays,
            remindTime: task.remindTime,
            nextTriggerAt: artifacts.artifacts
                .compactMap { DateFormatting.dateTime(from: $0.reminderDate) }
                .filter { $0 > Date() }
                .sorted()
                .first,
            notificationMessage: task.notificationMessage,
            status: task.status,
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: updatedTask,
            completionMessage: "已创建节日提醒任务。",
            reminderInfo: CardReminderInfo(
                type: "family_holiday",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: remindBeforeDays,
                nextTriggerDate: updatedTask.nextTriggerAt.map { DateFormatting.dateTimeString(from: $0) },
                status: "active",
                calendarEventId: updatedTask.calendarEventId,
                reminderItemId: updatedTask.reminderItemId,
                notificationRequestId: updatedTask.notificationRequestId,
                artifacts: updatedTask.artifacts
            )
        )
    }

    func refreshLunarDateSeries(in snapshot: JotlyStoreSnapshot) async throws -> JotlyStoreSnapshot? {
        var updatedSnapshot = snapshot
        var changed = false

        for event in snapshot.birthdayEvents where event.calendarType == .lunar {
            guard let taskIndex = updatedSnapshot.reminderTasks.firstIndex(where: { $0.birthdayEventId == event.id }) else {
                continue
            }

            let task = updatedSnapshot.reminderTasks[taskIndex]
            if futureArtifactCount(task.artifacts) >= 5 {
                continue
            }

            scheduler.cancelArtifacts(for: updatedSnapshot, cardId: event.cardId)
            let artifacts = try await scheduler.persistLunar(event: event, task: task, remindBeforeDays: event.remindBeforeDays, customNotes: .empty)
            let refreshedTask = reminderTask(
                updating: task,
                artifacts: artifacts.artifacts,
                calendarEventId: artifacts.calendarEventId,
                reminderItemId: artifacts.reminderItemId,
                notificationRequestId: artifacts.notificationRequestId
            )
            updatedSnapshot.reminderTasks[taskIndex] = refreshedTask

            if let cardIndex = updatedSnapshot.cards.firstIndex(where: { $0.id == event.cardId }) {
                var card = updatedSnapshot.cards[cardIndex]
                card.reminderInfo = CardReminderInfo(
                    type: "lunar",
                    personName: event.personName,
                    date: event.date,
                    remindBeforeDays: event.remindBeforeDays,
                    nextTriggerDate: refreshedTask.nextTriggerAt.map { DateFormatting.string(from: $0) },
                    status: "saved_lunar",
                    calendarEventId: refreshedTask.calendarEventId,
                    reminderItemId: refreshedTask.reminderItemId,
                    notificationRequestId: refreshedTask.notificationRequestId,
                    artifacts: refreshedTask.artifacts
                )
                card.markUpdated()
                updatedSnapshot.cards[cardIndex] = card
            }

            changed = true
        }

        return changed ? updatedSnapshot : nil
    }

    private func recordOnly(card: MemoryCard) -> BirthdayToolResult {
        let remindDays = resolvedRemindBeforeDays(from: card)
        let event = makeBirthdayEvent(card: card, calendarType: .recordOnly, remindBeforeDays: remindDays)
        return BirthdayToolResult(
            event: event,
            reminderTask: nil,
            completionMessage: "已保存。",
            reminderInfo: CardReminderInfo(
                type: "record",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: 0,
                nextTriggerDate: nil,
                status: "none",
                calendarEventId: nil,
                reminderItemId: nil,
                notificationRequestId: nil
            )
        )
    }

    private func validateBirthdayDatePresence(card: MemoryCard, calendarType: BirthdayCalendarType) throws {
        let combinedText = "\(card.originalText)\n\(card.supplementalText ?? "")"
        let hasExplicitDate = resolvedSolarBirthdayDateString(from: card) != nil

        if calendarType == .lunar {
            let parsed = lunarComponents(from: combinedText)
            let hasLunarMonth = card.entities?.lunarMonth != nil || card.metadata?["lunar_month"] != nil || parsed.month != nil
            let hasLunarDay = card.entities?.lunarDay != nil || card.metadata?["lunar_day"] != nil || parsed.day != nil
            if hasLunarMonth && hasLunarDay {
                return
            }
            guard hasExplicitDate else {
                throw JotlyError.invalidToolParameters("无法识别出农历或可转换的阳历日期信息。")
            }
            return
        }

        guard hasExplicitDate else {
            throw JotlyError.invalidToolParameters("无法识别出可用的阳历日期信息。")
        }
    }

    private func resolvedSolarBirthdayDateString(from card: MemoryCard) -> String? {
        let candidates = [
            card.entities?.date,
            card.entities?.dateText,
            card.metadata?["date"],
            card.metadata?["solar_date"],
            card.metadata?["birthday_date_text"],
            card.metadata?["date_text"],
            card.metadata?["start_date"],
            card.metadata?["due_date"]
        ]

        for candidate in candidates.compactMap({ $0 }) {
            if let normalized = normalizedSolarBirthdayDateString(candidate, allowBareMonthDay: true) {
                return normalized
            }
        }

        let combinedText = "\(card.originalText)\n\(card.supplementalText ?? "")"
        return normalizedSolarBirthdayDateString(combinedText, allowBareMonthDay: false)
    }

    private func normalizedSolarBirthdayDateString(_ rawValue: String, allowBareMonthDay: Bool) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let date = DateFormatting.dateTime(from: value) {
            return DateFormatting.string(from: date)
        }

        let normalized = value.replacingOccurrences(of: " ", with: "")
        if let components = numericDateComponents(in: normalized, includeBareMonthDay: allowBareMonthDay),
           let date = validatedGregorianDate(year: components.year, month: components.month, day: components.day) {
            return DateFormatting.string(from: date)
        }

        guard
            let regex = try? NSRegularExpression(
                pattern: #"([一二三四五六七八九十冬腊正\d]{1,3})月([初十廿卅一二三四五六七八九\d]{1,4})[日号]?"#
            ),
            let match = regex.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            ),
            let monthRange = Range(match.range(at: 1), in: normalized),
            let dayRange = Range(match.range(at: 2), in: normalized),
            let month = parseChineseNumber(String(normalized[monthRange]), isLunarMonth: true),
            let day = parseChineseNumber(String(normalized[dayRange]), isLunarMonth: false),
            let date = validatedGregorianDate(year: nil, month: month, day: day)
        else {
            return nil
        }
        return DateFormatting.string(from: date)
    }

    private func numericDateComponents(
        in text: String,
        includeBareMonthDay: Bool
    ) -> (year: Int?, month: Int, day: Int)? {
        let fullPattern = #"(?<!\d)(\d{4})[年./-](\d{1,2})[月./-](\d{1,2})[日号]?(?!\d)"#
        if let values = integerCaptures(pattern: fullPattern, text: text), values.count == 3 {
            return (values[0], values[1], values[2])
        }

        let monthDayPattern = includeBareMonthDay
            ? #"(?<!\d)(\d{1,2})[月./-](\d{1,2})[日号]?(?!\d)"#
            : #"(?<!\d)(\d{1,2})月(\d{1,2})[日号]?(?!\d)"#
        if let values = integerCaptures(pattern: monthDayPattern, text: text), values.count == 2 {
            return (nil, values[0], values[1])
        }
        return nil
    }

    private func integerCaptures(pattern: String, text: String) -> [Int]? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            )
        else {
            return nil
        }

        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }
    }

    private func validatedGregorianDate(year: Int?, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let resolvedYear = year ?? calendar.component(.year, from: Date())
        let components = DateComponents(year: resolvedYear, month: month, day: day)
        guard let date = calendar.date(from: components) else { return nil }
        let validated = calendar.dateComponents([.year, .month, .day], from: date)
        guard validated.year == resolvedYear, validated.month == month, validated.day == day else {
            return nil
        }
        return date
    }

    private func containsDayOnlyLunarCue(in text: String) -> Bool {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        return normalized.range(of: #"(\d{1,2}|[一二三四五六七八九十二三四五六七八九]+)[日号]"#, options: .regularExpression) != nil
    }

    private func lunarComponents(from text: String) -> (month: Int?, day: Int?) {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard
            let regex = try? NSRegularExpression(pattern: #"农历(闰)?([正一二三四五六七八九十冬腊\d]{1,3})月([初十廿卅一二三四五六七八九\d]{1,4})[日号]?"#),
            let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)),
            match.numberOfRanges >= 4,
            let monthRange = Range(match.range(at: 2), in: normalized),
            let dayRange = Range(match.range(at: 3), in: normalized)
        else {
            return (nil, nil)
        }
        return (
            parseChineseNumber(String(normalized[monthRange]), isLunarMonth: true),
            parseChineseNumber(String(normalized[dayRange]), isLunarMonth: false)
        )
    }

    private func parseChineseNumber(_ value: String, isLunarMonth: Bool) -> Int? {
        if let number = Int(value) {
            return number
        }
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
        guard let parsed = direct[normalized] else { return nil }
        if isLunarMonth {
            return (1...12).contains(parsed) ? parsed : nil
        }
        return (1...30).contains(parsed) ? parsed : nil
    }

    private func parseChineseNumberString(_ value: String) -> Int? {
        if let number = Int(value) {
            return number
        }
        return parseChineseNumber(value, isLunarMonth: false)
    }

    private func createSolarReminder(card: MemoryCard) async throws -> BirthdayToolResult {
        try validateBirthdayDatePresence(card: card, calendarType: .solar)
        let remindDays = resolvedRemindBeforeDays(from: card)
        let event = makeBirthdayEvent(card: card, calendarType: .solar, remindBeforeDays: remindDays)
        guard let reminderDate = nextSolarReminderDate(for: event.date, remindBeforeDays: remindDays) else {
            throw JotlyError.invalidDeepSeekResponse
        }

        let birthdayName = birthdayDisplayName(from: event.personName)
        let notes = birthdayNotes(from: card, birthdayName: birthdayName, remindBeforeDays: remindDays)
        let notificationMessage = notes.advanceNote ?? "还有 \(remindDays) 天就是\(birthdayName)的生日了，可以提前准备一句祝福。"
        let baseTask = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "active"
        )
        let artifacts = try await scheduler.persistSolar(event: event, task: baseTask, remindBeforeDays: remindDays, customNotes: notes)
        let task = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "active",
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: task,
            completionMessage: "生日提醒已创建。我会在每年提前 \(remindDays) 天提醒你。",
            reminderInfo: CardReminderInfo(
                type: "solar",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: remindDays,
                nextTriggerDate: task.nextTriggerAt.map { DateFormatting.dateTimeString(from: $0) },
                status: "active",
                calendarEventId: task.calendarEventId,
                reminderItemId: task.reminderItemId,
                notificationRequestId: task.notificationRequestId,
                artifacts: task.artifacts
            )
        )
    }

    private func createDateReminder(card: MemoryCard) async throws -> BirthdayToolResult {
        let repeatRule = resolvedRepeatRule(from: card)
        let reminderDate = resolvedDateTime(from: card)
        let isBirthday = dateTaskTitle(from: card).localizedStandardContains("生日") || card.type == "birthday" || card.metadata?["event_type"] == "birthday"
        let remindBeforeDays = card.entities?.remindBeforeDays ?? (isBirthday ? 3 : 0)
        let resolvedEventDate = DateFormatting.string(from: reminderDate)
        
        let event = BirthdayEvent(
            id: "date_\(UUID().uuidString)",
            cardId: card.id,
            personName: dateTaskTitle(from: card),
            date: resolvedEventDate,
            calendarType: .solar,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: false,
            repeatRule: repeatRule,
            remindBeforeDays: remindBeforeDays,
            createdAt: Date()
        )
        let notificationMessage: String
        if isBirthday {
            notificationMessage = card.metadata?["notification_body"] ?? card.metadata?["note"] ?? "\(event.personName)还有 \(remindBeforeDays) 天就过生日啦，记得准备小惊喜哦！"
        } else {
            notificationMessage = card.metadata?["notification_body"] ?? card.metadata?["note"] ?? "你有一个日期提醒：\(event.personName)"
        }
        let executionStatus = card.metadata?["tool"] == "calendar.create_event" ? "calendar_event" : "active"
        let baseTask = makeReminderTask(
            card: card,
            event: event,
            repeatRule: repeatRule,
            remindBeforeDays: event.remindBeforeDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: executionStatus
        )
        let customNote = card.metadata?["note"] ?? card.metadata?["notes"] ?? card.metadata?["notification_body"]
        let artifacts = try await scheduler.persistDate(event: event, task: baseTask, customNote: customNote)
        let task = makeReminderTask(
            card: card,
            event: event,
            repeatRule: repeatRule,
            remindBeforeDays: event.remindBeforeDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: executionStatus,
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: task,
            completionMessage: dateReminderCompletionMessage(title: event.personName, repeatRule: repeatRule, reminderDate: reminderDate),
            reminderInfo: CardReminderInfo(
                type: "date",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: event.remindBeforeDays,
                nextTriggerDate: task.nextTriggerAt.map { DateFormatting.dateTimeString(from: $0) },
                status: "active",
                calendarEventId: task.calendarEventId,
                reminderItemId: task.reminderItemId,
                notificationRequestId: task.notificationRequestId,
                artifacts: task.artifacts
            )
        )
    }

    private func createLunarReminder(card: MemoryCard) async throws -> BirthdayToolResult {
        try validateBirthdayDatePresence(card: card, calendarType: .lunar)
        let remindDays = resolvedRemindBeforeDays(from: card)
        var lunarCalendar = Calendar(identifier: .chinese)
        lunarCalendar.timeZone = .current
        let lunar: DateComponents
        let parsedLunar = lunarComponents(from: "\(card.originalText)\n\(card.supplementalText ?? "")")
        if let lunarMonth = card.entities?.lunarMonth ?? card.metadata?["lunar_month"].flatMap(parseChineseNumberString) ?? parsedLunar.month,
           let lunarDay = card.entities?.lunarDay ?? card.metadata?["lunar_day"].flatMap(parseChineseNumberString) ?? parsedLunar.day {
            var components = DateComponents()
            components.month = lunarMonth
            components.day = lunarDay
            components.isLeapMonth = card.entities?.isLeapMonth ?? false
            lunar = components
        } else {
            guard
                let sourceDateString = resolvedSolarBirthdayDateString(from: card),
                let sourceDate = DateFormatting.dateTime(from: sourceDateString)
            else {
                throw JotlyError.invalidToolParameters("无法识别出农历或可转换的阳历日期信息。")
            }
            lunar = lunarCalendar.dateComponents([.month, .day, .isLeapMonth], from: sourceDate)
        }

        let event = BirthdayEvent(
            id: "birthday_\(UUID().uuidString)",
            cardId: card.id,
            personName: normalizedPersonName(from: card),
            date: resolvedSolarBirthdayDateString(from: card) ?? DateFormatting.todayString(),
            calendarType: .lunar,
            lunarMonth: lunar.month,
            lunarDay: lunar.day,
            isLeapMonth: lunar.isLeapMonth ?? false,
            repeatRule: "yearly_lunar",
            remindBeforeDays: remindDays,
            createdAt: Date()
        )

        guard let reminderDate = nextLunarReminderDate(
            lunarMonth: lunar.month,
            lunarDay: lunar.day,
            isLeapMonth: lunar.isLeapMonth ?? false,
            remindBeforeDays: remindDays
        ) else {
            throw JotlyError.invalidDeepSeekResponse
        }

        let birthdayName = birthdayDisplayName(from: event.personName)
        let notes = birthdayNotes(from: card, birthdayName: birthdayName, remindBeforeDays: remindDays)
        let notificationMessage = notes.advanceNote ?? "还有 \(remindDays) 天就是\(birthdayName)的生日了，可以提前准备一句祝福。"
        let baseTask = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly_lunar",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "saved_lunar"
        )
        let artifacts = try await scheduler.persistLunar(event: event, task: baseTask, remindBeforeDays: remindDays, customNotes: notes)
        let task = makeReminderTask(
            card: card,
            event: event,
            repeatRule: "yearly_lunar",
            remindBeforeDays: remindDays,
            nextTriggerAt: reminderDate,
            notificationMessage: notificationMessage,
            status: "saved_lunar",
            calendarEventId: artifacts.calendarEventId,
            reminderItemId: artifacts.reminderItemId,
            notificationRequestId: artifacts.notificationRequestId,
            artifacts: artifacts.artifacts
        )

        return BirthdayToolResult(
            event: event,
            reminderTask: task,
            completionMessage: "农历生日提醒已创建。已按未来 10 年写入日历和提醒事项。",
            reminderInfo: CardReminderInfo(
                type: "lunar",
                personName: event.personName,
                date: event.date,
                remindBeforeDays: remindDays,
                nextTriggerDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
                status: "saved_lunar",
                calendarEventId: task.calendarEventId,
                reminderItemId: task.reminderItemId,
                notificationRequestId: task.notificationRequestId,
                artifacts: task.artifacts
            )
        )
    }

    private func makeBirthdayEvent(card: MemoryCard, calendarType: BirthdayCalendarType, remindBeforeDays: Int) -> BirthdayEvent {
        BirthdayEvent(
            id: "birthday_\(UUID().uuidString)",
            cardId: card.id,
            personName: normalizedPersonName(from: card),
            date: resolvedSolarBirthdayDateString(from: card) ?? DateFormatting.todayString(),
            calendarType: calendarType,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: false,
            repeatRule: calendarType == .lunar ? "yearly_lunar" : "yearly",
            remindBeforeDays: remindBeforeDays,
            createdAt: Date()
        )
    }

    private func makeReminderTask(
        card: MemoryCard,
        event: BirthdayEvent,
        repeatRule: String,
        remindBeforeDays: Int,
        nextTriggerAt: Date,
        notificationMessage: String,
        status: String,
        calendarEventId: String? = nil,
        reminderItemId: String? = nil,
        notificationRequestId: String? = nil,
        artifacts: [DateTaskArtifact] = []
    ) -> ReminderTask {
        let taskTitle: String
        if event.id.hasPrefix("date_") || card.metadata?["tool"] == "reminder.create" || card.metadata?["tool"] == "calendar.create_event" {
            taskTitle = event.personName
        } else if event.personName.localizedStandardContains("生日") {
            taskTitle = event.personName
        } else {
            taskTitle = "\(event.personName)的生日"
        }

        return ReminderTask(
            id: "reminder_\(UUID().uuidString)",
            cardId: card.id,
            birthdayEventId: event.id,
            title: taskTitle,
            calendarType: event.calendarType,
            repeatRule: repeatRule,
            remindBeforeDays: remindBeforeDays,
            remindTime: "12:30",
            nextTriggerAt: nextTriggerAt,
            notificationMessage: notificationMessage,
            status: status,
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: artifacts
        )
    }

    private func reminderTask(
        updating task: ReminderTask,
        artifacts: [DateTaskArtifact],
        calendarEventId: String?,
        reminderItemId: String?,
        notificationRequestId: String?
    ) -> ReminderTask {
        let nextTriggerAt = artifacts
            .compactMap { DateFormatting.date(fromDayString: $0.reminderDate) }
            .filter { $0 > Date() }
            .sorted()
            .first ?? task.nextTriggerAt

        return ReminderTask(
            id: task.id,
            cardId: task.cardId,
            birthdayEventId: task.birthdayEventId,
            title: task.title,
            calendarType: task.calendarType,
            repeatRule: task.repeatRule,
            remindBeforeDays: task.remindBeforeDays,
            remindTime: task.remindTime,
            nextTriggerAt: nextTriggerAt,
            notificationMessage: task.notificationMessage,
            status: task.status,
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: artifacts
        )
    }

    private func futureArtifactCount(_ artifacts: [DateTaskArtifact]?) -> Int {
        let today = Calendar.current.startOfDay(for: Date())
        return artifacts?
            .compactMap { DateFormatting.date(fromDayString: $0.reminderDate) }
            .filter { $0 >= today }
            .count ?? 0
    }

    private func resolvedRemindBeforeDays(from card: MemoryCard) -> Int {
        card.entities?.remindBeforeDays ?? 3
    }

    private func birthdayNotes(from card: MemoryCard, birthdayName: String, remindBeforeDays: Int) -> BirthdaySystemCoordinator.BirthdayNotes {
        let metadata = card.metadata ?? [:]
        let advanceNote = firstNonEmpty([
            metadata["advance_note"],
            metadata["pre_reminder_note"],
            metadata["reminder_note"]
        ]) ?? "还有 \(remindBeforeDays) 天就是\(birthdayName)的生日了，可以提前准备一句祝福，或者一个小小的惊喜。"

        let birthdayNote = firstNonEmpty([
            metadata["birthday_note"],
            metadata["day_note"],
            metadata["event_note"],
            metadata["note"],
            metadata["notes"]
        ]) ?? "今天是\(birthdayName)的生日，记得送上祝福，让这一天被好好记住。"

        return BirthdaySystemCoordinator.BirthdayNotes(
            advanceNote: advanceNote,
            birthdayNote: birthdayNote
        )
    }

    private func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private func birthdayDisplayName(from rawName: String) -> String {
        var name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return "这位重要的人"
        }
        for suffix in ["的生日", "生日"] {
            while name.hasSuffix(suffix), name.count > suffix.count {
                name.removeLast(suffix.count)
                name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return name.isEmpty ? "这位重要的人" : name
    }

    private func normalizedPersonName(from card: MemoryCard) -> String {
        let value = card.entities?.personName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "生日主角"
    }

    private func dateTaskTitle(from card: MemoryCard) -> String {
        let candidates = [
            card.metadata?["title"],
            card.metadata?["subject"],
            card.metadata?["content"],
            card.metadata?["summary"],
            card.entities?.eventType,
            card.summary,
            cleanedReminderTitle(from: card.originalText)
        ]
        for candidate in candidates {
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return String(value.prefix(24))
            }
        }
        return "日期提醒"
    }

    private func cleanedReminderTitle(from text: String) -> String {
        var value = text
        let replacements: [String] = [
            "你记得提醒我",
            "记得提醒我",
            "提醒我",
            "的时候",
            "到时候",
            "每天",
            "每日",
            "老是忘记",
            "总忘记",
            "忘记"
        ]
        for replacement in replacements {
            value = value.replacingOccurrences(of: replacement, with: "")
        }
        if !text.localizedStandardContains("生日") {
            value = value.replacingOccurrences(of: "生日", with: "")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("。") || value.hasPrefix("，") || value.hasPrefix(",") || value.hasPrefix(".") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? text : value
    }

    private func resolvedRepeatRule(from card: MemoryCard) -> String {
        if let explicit = card.metadata?["repeat_rule"] ?? card.metadata?["repeatRule"] ?? card.metadata?["recurrence"] {
            switch explicit {
            case "daily", "weekly", "monthly", "yearly", "yearly_lunar", "once":
                return explicit
            default:
                break
            }
        }
        let text = "\(card.originalText)\n\(card.supplementalText ?? "")"
        if text.localizedStandardContains("每天") || text.localizedStandardContains("每日") || text.localizedStandardContains("天天") {
            return "daily"
        }
        if text.localizedStandardContains("每周") || text.localizedStandardContains("每星期") || text.localizedStandardContains("每个星期") {
            return "weekly"
        }
        if text.localizedStandardContains("每月") || text.localizedStandardContains("每个月") {
            return "monthly"
        }
        if text.localizedStandardContains("每年") || text.localizedStandardContains("每一年") {
            return "yearly"
        }
        
        let isBirthday = card.originalText.localizedStandardContains("生日") || card.supplementalText?.localizedStandardContains("生日") == true || card.type == "birthday" || card.metadata?["event_type"] == "birthday" || card.metadata?["title"]?.localizedStandardContains("生日") == true
        if isBirthday {
            return "yearly"
        }
        return "once"
    }

    private func humanReadableRepeatRule(_ value: String) -> String {
        switch value {
        case "daily": return "每天"
        case "weekly": return "每周"
        case "monthly": return "每月"
        case "yearly", "yearly_lunar": return "每年"
        default: return "不重复"
        }
    }

    private func dateReminderCompletionMessage(title: String, repeatRule: String, reminderDate: Date) -> String {
        let repeatText = humanReadableRepeatRule(repeatRule)
        if repeatText == "不重复" {
            return "提醒已创建。我会在 \(DateFormatting.badgeString(from: reminderDate)) 提醒你。"
        }
        return "提醒已创建。我会\(repeatText)在 \(timeString(from: reminderDate)) 提醒你\(title.isEmpty ? "" : "：\(title)")。"
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func resolvedDateTime(from card: MemoryCard) -> Date {
        // Strictly parse date and time parameters outputted by the model
        let modelDateStr = card.metadata?["date"] ?? card.metadata?["start_date"] ?? card.metadata?["due_date"] 
            ?? card.metadata?["datetime"] ?? card.metadata?["date_time"] ?? card.metadata?["start_at"] ?? card.metadata?["due_at"]
        let modelTimeStr = card.metadata?["time"]
        
        guard let trimmedDateStr = modelDateStr?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedDateStr.isEmpty else {
            JotlyLog.tool.error("resolvedDateTime: Model parameters missing date/time info.")
            return Date()
        }
        
        guard let date = DateFormatting.dateTime(from: trimmedDateStr) else {
            JotlyLog.tool.error("resolvedDateTime: Invalid date format from model: \(trimmedDateStr)")
            return Date()
        }
        
        // If the date parameter already contains specific time (":"), use it directly
        if trimmedDateStr.contains(":") {
            return date
        }
        
        // Combine model date with model's time parameter or default
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let time = resolveTime(from: modelTimeStr ?? "") ?? (hour: 12, minute: 30)
        comps.hour = time.hour
        comps.minute = time.minute
        return Calendar.current.date(from: comps) ?? date
    }

    private func resolveTime(from text: String) -> (hour: Int, minute: Int)? {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        if let regex = try? NSRegularExpression(pattern: #"([零〇一二两三四五六七八九十\d]{1,3})[:：点时]([零〇一二两三四五六七八九十\d]{1,3}|半)?分?"#) {
            let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            if let match = regex.firstMatch(in: normalized, options: [], range: range),
               let hourRange = Range(match.range(at: 1), in: normalized),
               let rawHour = parseClockNumber(String(normalized[hourRange]))
            {
                var minute = 0
                if match.numberOfRanges > 2,
                   match.range(at: 2).location != NSNotFound,
                   let minuteRange = Range(match.range(at: 2), in: normalized)
                {
                    let minuteText = String(normalized[minuteRange])
                    minute = minuteText == "半" ? 30 : (parseClockNumber(minuteText) ?? 0)
                }
                let hour = normalized.localizedStandardContains("下午") || normalized.localizedStandardContains("晚上")
                    ? (rawHour < 12 ? rawHour + 12 : rawHour)
                    : rawHour
                return (min(max(hour, 0), 23), min(max(minute, 0), 59))
            }
        }
        if normalized.localizedStandardContains("中午") {
            return (12, 30)
        }
        if normalized.localizedStandardContains("早上") {
            return (9, 0)
        }
        if normalized.localizedStandardContains("晚上") {
            return (20, 0)
        }
        return nil
    }

    private func parseClockNumber(_ value: String) -> Int? {
        let normalized = value
            .replacingOccurrences(of: "〇", with: "零")
            .replacingOccurrences(of: "两", with: "二")
        if let number = Int(normalized) {
            return number
        }
        if normalized == "零" {
            return 0
        }
        return parseChineseNumberString(normalized)
    }

    private func nextSolarReminderDate(for dayString: String, remindBeforeDays: Int) -> Date? {
        let birthday = DateFormatting.date(fromDayString: dayString)
        let calendar = Calendar.current
        let birthdayComponents = calendar.dateComponents([.month, .day], from: birthday)
        guard let month = birthdayComponents.month, let day = birthdayComponents.day else {
            return nil
        }

        let now = Date()
        let currentYear = calendar.component(.year, from: now)
        for offset in 0...1 {
            var birthdayThisYear = DateComponents()
            birthdayThisYear.year = currentYear + offset
            birthdayThisYear.month = month
            birthdayThisYear.day = day
            birthdayThisYear.hour = 0
            birthdayThisYear.minute = 0
            guard
                let birthdayDate = calendar.date(from: birthdayThisYear),
                let rawReminderDate = calendar.date(byAdding: .day, value: -remindBeforeDays, to: birthdayDate)
            else {
                continue
            }
            var reminderComponents = calendar.dateComponents([.year, .month, .day], from: rawReminderDate)
            reminderComponents.hour = 12
            reminderComponents.minute = 30
            guard let reminderDate = calendar.date(from: reminderComponents) else {
                continue
            }
            if reminderDate > now {
                return reminderDate
            }
        }
        return nil
    }

    private func nextLunarReminderDate(
        lunarMonth: Int?,
        lunarDay: Int?,
        isLeapMonth: Bool,
        remindBeforeDays: Int
    ) -> Date? {
        guard let lunarMonth, let lunarDay else { return nil }

        let lunarCalendar = Calendar(identifier: .chinese)
        let gregorianCalendar = Calendar.current
        let now = Date()
        let currentYear = lunarCalendar.component(.year, from: now)

        for offset in 0...2 {
            var birthdayComponents = DateComponents()
            birthdayComponents.calendar = lunarCalendar
            birthdayComponents.year = currentYear + offset
            birthdayComponents.month = lunarMonth
            birthdayComponents.day = lunarDay
            birthdayComponents.isLeapMonth = isLeapMonth

            guard
                let birthdayDate = lunarCalendar.date(from: birthdayComponents),
                let reminderDate = gregorianCalendar.date(byAdding: .day, value: -remindBeforeDays, to: birthdayDate)
            else {
                continue
            }

            if reminderDate > now {
                return reminderDate
            }
        }

        return nil
    }
}

struct BirthdayToolResult {
    let event: BirthdayEvent
    let reminderTask: ReminderTask?
    let completionMessage: String
    var reminderInfo: CardReminderInfo? = nil
}
