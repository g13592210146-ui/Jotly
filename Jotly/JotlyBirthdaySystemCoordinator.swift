import EventKit
import Foundation
import os
import UserNotifications

@MainActor
final class BirthdaySystemCoordinator {
    private let eventStore = EKEventStore()
    private let notificationCenter = UNUserNotificationCenter.current()

    func ensureAccess() async throws {
        if #available(iOS 17.0, *) {
            let calendarGranted = try await eventStore.requestFullAccessToEvents()
            guard calendarGranted else {
                throw JotlyError.calendarPermissionDenied
            }

            let reminderGranted = try await eventStore.requestFullAccessToReminders()
            guard reminderGranted else {
                throw JotlyError.reminderPermissionDenied
            }
        } else {
            throw JotlyError.eventStoreUnavailable
        }

        let notificationGranted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
        guard notificationGranted else {
            throw JotlyError.notificationPermissionDenied
        }
    }

    struct BirthdayNotes {
        var advanceNote: String?
        var birthdayNote: String?

        static let empty = BirthdayNotes(advanceNote: nil, birthdayNote: nil)
    }

    func persistSolar(event: BirthdayEvent, task: ReminderTask, remindBeforeDays: Int, customNotes: BirthdayNotes) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        var occurrenceDate: Date? = nil
        let baseDate = DateFormatting.date(fromDayString: event.date)
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: baseDate)
        comps.hour = 0
        comps.minute = 0
        occurrenceDate = Calendar.current.date(from: comps)
        
        if occurrenceDate == nil {
            occurrenceDate = birthdayOccurrenceDate(from: task.nextTriggerAt, remindBeforeDays: remindBeforeDays)
        }
        let calendarEventId = try createCalendarEvent(
            title: task.title,
            startDate: occurrenceDate,
            remindBeforeDays: remindBeforeDays,
            notes: notes(for: event, task: task, customNote: customNotes.birthdayNote, isAdvanceReminder: false),
            isRecurring: true,
            isAllDay: true
        )
        let reminderItemId = try createReminderItem(
            title: task.title,
            dueDate: task.nextTriggerAt,
            notes: notes(for: event, task: task, customNote: customNotes.advanceNote, isAdvanceReminder: true),
            isRecurring: true
        )
        let notificationRequestId = try await scheduleNotification(
            identifier: task.id,
            title: task.title,
            body: task.notificationMessage,
            fireDate: task.nextTriggerAt,
            repeats: true
        )

        let artifact = DateTaskArtifact(
            id: "artifact_\(UUID().uuidString)",
            kind: "solar_yearly",
            year: occurrenceDate.map { Calendar.current.component(.year, from: $0) },
            occurrenceDate: occurrenceDate.map { DateFormatting.string(from: $0) },
            reminderDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId
        )

        return BirthdayExecutionArtifacts(
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: [artifact]
        )
    }

    func persistLunar(event: BirthdayEvent, task: ReminderTask, remindBeforeDays: Int, customNotes: BirthdayNotes) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        let occurrences = lunarOccurrences(
            lunarMonth: event.lunarMonth,
            lunarDay: event.lunarDay,
            isLeapMonth: event.isLeapMonth,
            remindBeforeDays: remindBeforeDays,
            minimumFutureCount: 5
        )
        guard !occurrences.isEmpty else {
            throw JotlyError.invalidDeepSeekResponse
        }

        var artifacts: [DateTaskArtifact] = []
        for occurrence in occurrences {
            let calendarEventId = try createCalendarEvent(
                title: task.title,
                startDate: occurrence.occurrenceDate,
                remindBeforeDays: remindBeforeDays,
                notes: notes(for: event, task: task, occurrenceDate: occurrence.occurrenceDate, customNote: customNotes.birthdayNote, isAdvanceReminder: false),
                isRecurring: false,
                isAllDay: true
            )
            let reminderItemId = try createReminderItem(
                title: task.title,
                dueDate: occurrence.reminderDate,
                notes: notes(for: event, task: task, occurrenceDate: occurrence.occurrenceDate, customNote: customNotes.advanceNote, isAdvanceReminder: true),
                isRecurring: false
            )
            let notificationRequestId = try await scheduleNotification(
                identifier: "\(task.id)_\(occurrence.year)",
                title: task.title,
                body: task.notificationMessage,
                fireDate: occurrence.reminderDate,
                repeats: false
            )
            artifacts.append(
                DateTaskArtifact(
                    id: "artifact_\(UUID().uuidString)",
                    kind: "lunar_series_occurrence",
                    year: occurrence.year,
                    occurrenceDate: DateFormatting.string(from: occurrence.occurrenceDate),
                    reminderDate: DateFormatting.string(from: occurrence.reminderDate),
                    calendarEventId: calendarEventId,
                    reminderItemId: reminderItemId,
                    notificationRequestId: notificationRequestId
                )
            )
        }

        return BirthdayExecutionArtifacts(
            calendarEventId: artifacts.first?.calendarEventId,
            reminderItemId: artifacts.first?.reminderItemId,
            notificationRequestId: artifacts.first?.notificationRequestId,
            artifacts: artifacts
        )
    }

    func persistDate(event: BirthdayEvent, task: ReminderTask, customNote: String?) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        let usesCalendar = shouldUseCalendarEvent(for: task)
        let alarmLeadDays = shouldUseLeadAlarm(for: event, task: task) ? task.remindBeforeDays : 0
        let calendarEventId: String?
        let reminderItemId: String?
        if usesCalendar {
            calendarEventId = try createCalendarEvent(
                title: task.title,
                startDate: task.nextTriggerAt,
                remindBeforeDays: alarmLeadDays,
                notes: notesForDateTask(task, customNote: customNote),
                repeatRule: task.repeatRule
            )
            reminderItemId = nil
        } else {
            calendarEventId = nil
            reminderItemId = try createReminderItem(
                title: task.title,
                dueDate: task.nextTriggerAt,
                notes: notesForDateTask(task, customNote: customNote),
                remindBeforeDays: alarmLeadDays,
                repeatRule: task.repeatRule
            )
        }

        let isBirthday = task.title.localizedStandardContains("生日") || event.calendarType == .solar || event.calendarType == .lunar
        let notificationRequestId: String?
        if isBirthday && task.remindBeforeDays > 0, let triggerAt = task.nextTriggerAt {
            let fireDate = Calendar.current.date(byAdding: .day, value: -task.remindBeforeDays, to: triggerAt) ?? triggerAt
            notificationRequestId = try? await scheduleNotification(
                identifier: task.id,
                title: task.title,
                body: task.notificationMessage,
                fireDate: fireDate,
                repeats: task.repeatRule == "yearly"
            )
        } else {
            notificationRequestId = nil
        }

        let artifact = DateTaskArtifact(
            id: "artifact_\(UUID().uuidString)",
            kind: usesCalendar ? "calendar_event" : "reminder_item",
            year: task.nextTriggerAt.map { Calendar.current.component(.year, from: $0) },
            occurrenceDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
            reminderDate: task.nextTriggerAt.map { DateFormatting.string(from: $0) },
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId
        )

        return BirthdayExecutionArtifacts(
            calendarEventId: calendarEventId,
            reminderItemId: reminderItemId,
            notificationRequestId: notificationRequestId,
            artifacts: [artifact]
        )
    }

    func persistFamilyHolidaySeries(event: BirthdayEvent, task: ReminderTask, remindBeforeDays: Int) async throws -> BirthdayExecutionArtifacts {
        try await ensureAccess()

        let occurrences = familyHolidayOccurrences(remindBeforeDays: remindBeforeDays, minimumFutureYears: 5)
        guard !occurrences.isEmpty else {
            throw JotlyError.invalidDeepSeekResponse
        }

        var artifacts: [DateTaskArtifact] = []
        for occurrence in occurrences {
            let title = occurrence.name
            let calendarEventId = try createCalendarEvent(
                title: title,
                startDate: occurrence.occurrenceDate,
                remindBeforeDays: 0,
                notes: familyHolidayNotes(name: occurrence.name, remindBeforeDays: remindBeforeDays, isAdvanceReminder: false),
                isRecurring: false,
                isAllDay: true
            )
            let reminderItemId = try createReminderItem(
                title: title,
                dueDate: occurrence.reminderDate,
                notes: familyHolidayNotes(name: occurrence.name, remindBeforeDays: remindBeforeDays, isAdvanceReminder: true),
                isRecurring: false
            )
            let notificationRequestId = try await scheduleNotification(
                identifier: "\(task.id)_\(occurrence.kind)_\(occurrence.year)",
                title: title,
                body: "\(occurrence.name)快到了，可以提前准备一句祝福或一个小心意。",
                fireDate: occurrence.reminderDate,
                repeats: false
            )
            artifacts.append(
                DateTaskArtifact(
                    id: "artifact_\(UUID().uuidString)",
                    kind: "family_holiday_\(occurrence.kind)",
                    year: occurrence.year,
                    occurrenceDate: DateFormatting.string(from: occurrence.occurrenceDate),
                    reminderDate: DateFormatting.dateTimeString(from: occurrence.reminderDate),
                    calendarEventId: calendarEventId,
                    reminderItemId: reminderItemId,
                    notificationRequestId: notificationRequestId
                )
            )
        }

        return BirthdayExecutionArtifacts(
            calendarEventId: artifacts.first?.calendarEventId,
            reminderItemId: artifacts.first?.reminderItemId,
            notificationRequestId: artifacts.first?.notificationRequestId,
            artifacts: artifacts
        )
    }

    func cancelArtifacts(for snapshot: JotlyStoreSnapshot, cardId: String) {
        let tasks = snapshot.reminderTasks.filter { $0.cardId == cardId }
        let notificationIds = tasks.flatMap { task -> [String] in
            var ids = task.artifacts?.compactMap(\.notificationRequestId) ?? []
            if let notificationRequestId = task.notificationRequestId {
                ids.append(notificationRequestId)
            } else {
                ids.append(task.id)
            }
            return ids
        }
        if !notificationIds.isEmpty {
            notificationCenter.removePendingNotificationRequests(withIdentifiers: notificationIds)
        }

        for task in tasks {
            let calendarEventIds = Set((task.artifacts?.compactMap(\.calendarEventId) ?? []) + [task.calendarEventId].compactMap { $0 })
            for calendarEventId in calendarEventIds {
                if let event = eventStore.event(withIdentifier: calendarEventId) {
                    try? eventStore.remove(event, span: .futureEvents, commit: true)
                }
            }

            let reminderItemIds = Set((task.artifacts?.compactMap(\.reminderItemId) ?? []) + [task.reminderItemId].compactMap { $0 })
            for reminderItemId in reminderItemIds {
                if let reminder = eventStore.calendarItem(withIdentifier: reminderItemId) as? EKReminder {
                    try? eventStore.remove(reminder, commit: true)
                }
            }
        }
    }

    private func createCalendarEvent(
        title: String,
        startDate: Date?,
        remindBeforeDays: Int,
        notes: String,
        isRecurring: Bool,
        isAllDay: Bool = false
    ) throws -> String {
        guard let startDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = startDate
        event.isAllDay = isAllDay
        event.endDate = isAllDay
            ? (Calendar.current.date(bySettingHour: 23, minute: 59, second: 59, of: startDate) ?? startDate.addingTimeInterval(86399))
            : (Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate.addingTimeInterval(3600))
        if !isAllDay && remindBeforeDays > 0 {
            event.alarms = [EKAlarm(relativeOffset: TimeInterval(-remindBeforeDays * 24 * 60 * 60))]
        }

        if isRecurring {
            let recurrence = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
            event.recurrenceRules = [recurrence]
        }

        do {
            try eventStore.save(event, span: .futureEvents, commit: true)
        } catch {
            throw JotlyError.calendarEventCreationFailed(error.localizedDescription)
        }

        return event.eventIdentifier ?? "calendar_\(UUID().uuidString)"
    }

    private func createReminderItem(
        title: String,
        dueDate: Date?,
        notes: String,
        isRecurring: Bool
    ) throws -> String {
        guard let dueDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        let dueComponents = reminderDueDateComponents(from: dueDate)
        reminder.dueDateComponents = dueComponents
        reminder.alarms = [EKAlarm(absoluteDate: dueDate)]
        if isRecurring {
            reminder.recurrenceRules = [EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)]
        }

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw JotlyError.reminderCreationFailed(error.localizedDescription)
        }

        JotlyLog.tool.info(
            "Reminder saved title=\(title, privacy: .public), due=\(DateFormatting.dateTimeString(from: dueDate), privacy: .public), components=\(String(describing: dueComponents), privacy: .public), id=\(reminder.calendarItemIdentifier, privacy: .public)"
        )
        return reminder.calendarItemIdentifier
    }

    private func createCalendarEvent(
        title: String,
        startDate: Date?,
        remindBeforeDays: Int,
        notes: String,
        repeatRule: String
    ) throws -> String {
        guard let startDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewEvents ?? eventStore.calendars(for: .event).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let event = EKEvent(eventStore: eventStore)
        event.calendar = calendar
        event.title = title
        event.notes = notes
        event.startDate = startDate
        event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate) ?? startDate.addingTimeInterval(3600)
        if remindBeforeDays > 0 {
            event.alarms = [EKAlarm(relativeOffset: TimeInterval(-remindBeforeDays * 24 * 60 * 60))]
        }
        if let rule = recurrenceRule(from: repeatRule) {
            event.recurrenceRules = [rule]
        }

        do {
            try eventStore.save(event, span: .futureEvents, commit: true)
        } catch {
            throw JotlyError.calendarEventCreationFailed(error.localizedDescription)
        }

        return event.eventIdentifier ?? "calendar_\(UUID().uuidString)"
    }

    private func createReminderItem(
        title: String,
        dueDate: Date?,
        notes: String,
        remindBeforeDays: Int,
        repeatRule: String
    ) throws -> String {
        guard let dueDate else {
            throw JotlyError.invalidDeepSeekResponse
        }
        guard let calendar = eventStore.defaultCalendarForNewReminders() ?? eventStore.calendars(for: .reminder).first else {
            throw JotlyError.eventStoreUnavailable
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.calendar = calendar
        reminder.title = title
        reminder.notes = notes
        let dueComponents = reminderDueDateComponents(from: dueDate)
        reminder.dueDateComponents = dueComponents
        reminder.alarms = [EKAlarm(absoluteDate: dueDate)]
        if let rule = recurrenceRule(from: repeatRule) {
            reminder.recurrenceRules = [rule]
        }

        do {
            try eventStore.save(reminder, commit: true)
        } catch {
            throw JotlyError.reminderCreationFailed(error.localizedDescription)
        }

        JotlyLog.tool.info(
            "Reminder saved title=\(title, privacy: .public), due=\(DateFormatting.dateTimeString(from: dueDate), privacy: .public), components=\(String(describing: dueComponents), privacy: .public), repeat=\(repeatRule, privacy: .public), id=\(reminder.calendarItemIdentifier, privacy: .public)"
        )
        return reminder.calendarItemIdentifier
    }

    private func reminderDueDateComponents(from date: Date) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.calendar = calendar
        components.timeZone = .current
        return components
    }

    private func recurrenceRule(from value: String) -> EKRecurrenceRule? {
        switch value {
        case "daily":
            return EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil)
        case "weekly":
            return EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: nil)
        case "monthly":
            return EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        case "yearly", "yearly_lunar":
            return EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        default:
            return nil
        }
    }

    private func shouldUseCalendarEvent(for task: ReminderTask) -> Bool {
        if task.status == "calendar_event" {
            return true
        }
        let calendarKeywords = ["会议", "约会", "日程", "行程", "面试", "上课", "课程", "开会"]
        return calendarKeywords.contains { task.title.localizedStandardContains($0) }
    }

    private func shouldUseLeadAlarm(for event: BirthdayEvent, task: ReminderTask) -> Bool {
        guard task.remindBeforeDays > 0 else { return false }
        if event.calendarType == .solar || event.calendarType == .lunar {
            return true
        }
        if task.title.localizedStandardContains("生日") {
            return true
        }
        if task.title.localizedStandardContains("纪念日") {
            return true
        }
        return false
    }

    private func scheduleNotification(
        identifier: String,
        title: String,
        body: String,
        fireDate: Date?,
        repeats: Bool
    ) async throws -> String {
        guard let fireDate else {
            throw JotlyError.invalidDeepSeekResponse
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let components: DateComponents
        if repeats {
            components = Calendar.current.dateComponents([.month, .day, .hour, .minute], from: fireDate)
        } else {
            components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        }

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await notificationCenter.add(request)
        return identifier
    }

    private func notes(
        for event: BirthdayEvent,
        task: ReminderTask,
        occurrenceDate: Date? = nil,
        customNote: String? = nil,
        isAdvanceReminder: Bool
    ) -> String {
        return customNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

    private func notesForDateTask(_ task: ReminderTask, customNote: String? = nil) -> String {
        return customNote?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func dateTaskNoteOpening(for task: ReminderTask) -> String {
        let title = task.title
        if title.localizedStandardContains("喝水") {
            return "💧 咕嘟咕嘟，记得照顾好自己的身体，喝水也是件正经事。"
        }
        if title.localizedStandardContains("吃药") || title.localizedStandardContains("服药") {
            return "💊 药不能停，健康第一。按时服药，身体才会好起来哦。"
        }
        if title.localizedStandardContains("续费") || title.localizedStandardContains("充值") || title.localizedStandardContains("缴费") {
            return "💳 提醒小帮手上线：提前处理一下，避免服务被打断哦。"
        }
        if title.localizedStandardContains("会议") || title.localizedStandardContains("约会") || title.localizedStandardContains("行程") {
            return "🗓️ 精彩生活，准时出发。到时间我会准时叫你的。"
        }
        if title.localizedStandardContains("羽毛球") || title.localizedStandardContains("打球") {
            return "🏸 出门前记得带上球拍、球鞋和水，轻装上阵就好。"
        }
        
        let standardOpenings = [
            "✨ 别担心，每一件小事，我都帮你妥帖记着呢。",
            "🌟 滴答滴答，生活的小步调，我们一起稳稳走过。",
            "🍀 愿你今天的心情 and 天气一样明朗，待会儿见！",
            "🎈 重要的事，交给我来守护，你只管享受当下就好。"
        ]
        let index = abs(title.hashValue) % standardOpenings.count
        return standardOpenings[index].replacingOccurrences(of: " and ", with: "和")
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

    private func birthdayOccurrenceDate(from reminderDate: Date?, remindBeforeDays: Int) -> Date? {
        guard let reminderDate else { return nil }
        return Calendar.current.date(byAdding: .day, value: remindBeforeDays, to: reminderDate)
    }

    fileprivate func lunarOccurrences(
        lunarMonth: Int?,
        lunarDay: Int?,
        isLeapMonth: Bool,
        remindBeforeDays: Int,
        minimumFutureCount: Int
    ) -> [(year: Int, occurrenceDate: Date, reminderDate: Date)] {
        guard let lunarMonth, let lunarDay else { return [] }

        let lunarCalendar = Calendar(identifier: .chinese)
        let gregorianCalendar = Calendar.current
        let now = Date()
        let currentYear = lunarCalendar.component(.year, from: now)
        var results: [(year: Int, occurrenceDate: Date, reminderDate: Date)] = []

        for offset in 0...20 {
            var components = DateComponents()
            components.calendar = lunarCalendar
            components.year = currentYear + offset
            components.month = lunarMonth
            components.day = lunarDay
            components.hour = 0
            components.minute = 0
            components.isLeapMonth = isLeapMonth

            guard
                let occurrenceDate = lunarCalendar.date(from: components),
                let rawReminderDate = gregorianCalendar.date(byAdding: .day, value: -remindBeforeDays, to: occurrenceDate)
            else {
                continue
            }
            var reminderComponents = gregorianCalendar.dateComponents([.year, .month, .day], from: rawReminderDate)
            reminderComponents.hour = 12
            reminderComponents.minute = 30
            guard let reminderDate = gregorianCalendar.date(from: reminderComponents) else {
                continue
            }

            if reminderDate > now {
                results.append((currentYear + offset, occurrenceDate, reminderDate))
            }

            if results.count >= minimumFutureCount {
                break
            }
        }

        return results
    }

    private func familyHolidayOccurrences(remindBeforeDays: Int, minimumFutureYears: Int) -> [(kind: String, name: String, year: Int, occurrenceDate: Date, reminderDate: Date)] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        let now = Date()
        var results: [(kind: String, name: String, year: Int, occurrenceDate: Date, reminderDate: Date)] = []

        for offset in 0...10 {
            let year = currentYear + offset
            let holidays: [(String, String, Date?)] = [
                ("mother", "母亲节", nthWeekday(year: year, month: 5, weekday: 1, ordinal: 2)),
                ("father", "父亲节", nthWeekday(year: year, month: 6, weekday: 1, ordinal: 3))
            ]

            for (kind, name, maybeDate) in holidays {
                guard let occurrenceDate = maybeDate,
                      let rawReminderDate = calendar.date(byAdding: .day, value: -remindBeforeDays, to: occurrenceDate)
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
                    results.append((kind, name, year, occurrenceDate, reminderDate))
                }
            }

            if results.filter({ $0.kind == "mother" }).count >= minimumFutureYears,
               results.filter({ $0.kind == "father" }).count >= minimumFutureYears {
                break
            }
        }

        return results.sorted { $0.reminderDate < $1.reminderDate }
    }

    private func nthWeekday(year: Int, month: Int, weekday: Int, ordinal: Int) -> Date? {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.weekday = weekday
        components.weekdayOrdinal = ordinal
        components.hour = 0
        components.minute = 0
        return Calendar.current.date(from: components)
    }

    private func familyHolidayNotes(name: String, remindBeforeDays: Int, isAdvanceReminder: Bool) -> String {
        var lines: [String] = []
        if isAdvanceReminder {
            lines.append("\(name)快到了。")
            lines.append("留点时间准备一句祝福，或者一个小小的心意。")
        } else {
            lines.append("今天是\(name)，记得送上一句祝福。")
        }
        lines.append("来自随心记")
        return lines.joined(separator: "\n")
    }
}
