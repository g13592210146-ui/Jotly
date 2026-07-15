import Foundation

enum LocalBirthdayParser {
    static func analysis(from text: String, currentDate: String) -> AgentAnalysis {
        guard looksDateRelated(text) else {
            return AgentAnalysis.recordFallback(originalText: text)
        }

        guard looksLikeBirthday(text) else {
            return dateFallback(from: text, currentDate: currentDate)
        }

        let remindBeforeDays = extractRemindBeforeDays(from: text) ?? 3
        if let calendarType = extractCalendarType(from: text) {
            return birthdayResolved(
                originalText: text,
                currentDate: currentDate,
                personName: extractPersonName(from: text),
                calendarType: calendarType,
                remindBeforeDays: remindBeforeDays
            )
        }

        return AgentAnalysis.birthdayFallback(
            originalText: text,
            currentDate: currentDate,
            personName: extractPersonName(from: text),
            remindBeforeDays: remindBeforeDays
        )
    }

    static func looksDateRelated(_ text: String) -> Bool {
        if looksLikeBirthday(text) {
            return true
        }
        if containsExplicitDate(text) {
            return true
        }

        let dateIntentKeywords = [
            "提醒", "记得", "别忘", "别忘了", "忘记", "老是忘", "总忘", "日程", "日历", "安排", "约会", "会议", "纪念日", "截止", "到期",
            "今天", "明天", "后天", "大后天", "下周", "下个月", "周一", "周二", "周三", "周四", "周五", "周六", "周日",
            "星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期天", "星期日",
            "农历", "阴历", "阳历", "公历", "每天", "每日", "每年", "每月", "每周", "提前"
        ]
        return dateIntentKeywords.contains { text.localizedStandardContains($0) }
    }

    private static func dateFallback(from text: String, currentDate: String) -> AgentAnalysis {
        let resolvedDate = resolvedDateString(from: text, currentDate: currentDate)
        let potentialNeed = !text.localizedStandardContains("提醒") && !text.localizedStandardContains("记得")
        let message: String
        if potentialNeed {
            message = "听起来这件事容易被忘掉。我可以每天在一个合适的时间提醒你，要不要让我来安排？"
        } else if resolvedDate == nil {
            message = "我知道你想让我提醒这件事，但还缺具体时间。默认我可以先按今天 12:30 来提醒，你也可以补充更准确的时间。"
        } else {
            message = "我可以按你说的时间提醒你。请确认后，我再写入系统提醒。"
        }
        return AgentAnalysis.dateFallback(
            originalText: text,
            currentDate: currentDate,
            resolvedDate: resolvedDate,
            title: "日期提醒",
            message: message
        )
    }

    private static func looksLikeBirthday(_ text: String) -> Bool {
        let birthdayKeywords = ["生日", "生辰", "寿辰", "过生日"]
        return birthdayKeywords.contains { text.localizedStandardContains($0) }
    }

    private static func containsExplicitDate(_ text: String) -> Bool {
        let patterns = [
            #"(?:(?:\d{1,2})|[一二三四五六七八九十]{1,3})\s*[月]\s*(?:(?:\d{1,2})|[一二三四五六七八九十]{1,3})\s*[日号]?"#,
            #"(?:(?:\d{1,2})|[一二三四五六七八九十]{1,3})\s*[日号]"#,
            #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}"#
        ]
        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.firstMatch(in: text, options: [], range: range) != nil
        }
    }

    private static func resolvedDateString(from text: String, currentDate: String) -> String? {
        if let monthDay = resolveMonthDay(from: text, currentDate: currentDate) {
            return DateFormatting.string(from: monthDay)
        }
        if text.localizedStandardContains("明天") {
            let date = Calendar.current.date(byAdding: .day, value: 1, to: DateFormatting.date(fromDayString: currentDate))
            return date.map { DateFormatting.string(from: $0) }
        }
        if text.localizedStandardContains("后天") {
            let date = Calendar.current.date(byAdding: .day, value: 2, to: DateFormatting.date(fromDayString: currentDate))
            return date.map { DateFormatting.string(from: $0) }
        }
        if text.localizedStandardContains("今天") {
            return currentDate
        }
        return nil
    }

    private static func resolveMonthDay(from text: String, currentDate: String) -> Date? {
        let normalized = text.replacingOccurrences(of: " ", with: "")
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})月(\d{1,2})[日号]?"#) else {
            return nil
        }
        let range = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = regex.firstMatch(in: normalized, options: [], range: range),
              match.numberOfRanges > 2,
              let monthRange = Range(match.range(at: 1), in: normalized),
              let dayRange = Range(match.range(at: 2), in: normalized),
              let month = Int(normalized[monthRange]),
              let day = Int(normalized[dayRange])
        else {
            return nil
        }

        let base = DateFormatting.date(fromDayString: currentDate)
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: base)
        for year in [currentYear, currentYear + 1] {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            components.hour = 12
            components.minute = 30
            if let date = calendar.date(from: components), date >= base {
                return date
            }
        }
        return nil
    }

    private static func extractCalendarType(from text: String) -> BirthdayCalendarType? {
        if text.localizedStandardContains("阴历") || text.localizedStandardContains("农历") {
            return .lunar
        }
        if text.localizedStandardContains("阳历") || text.localizedStandardContains("公历") {
            return .solar
        }
        return nil
    }

    private static func extractRemindBeforeDays(from text: String) -> Int? {
        let normalized = text.replacingOccurrences(of: " ", with: "")

        let digitPatterns = [
            "提前(\\d+)天": 1,
            "提前(\\d+)周": 7
        ]
        for (pattern, multiplier) in digitPatterns {
            if let value = matchInt(in: normalized, pattern: pattern) {
                return value * multiplier
            }
        }

        let chineseDayMap: [String: Int] = [
            "一天": 1, "两天": 2, "三天": 3, "四天": 4, "五天": 5,
            "六天": 6, "七天": 7, "八天": 8, "九天": 9, "十天": 10
        ]
        for (token, value) in chineseDayMap {
            if normalized.localizedStandardContains("提前\(token)") {
                return value
            }
        }

        if normalized.localizedStandardContains("一周") {
            return 7
        }
        if normalized.localizedStandardContains("两周") {
            return 14
        }

        return nil
    }

    private static func matchInt(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
    }

    private static func birthdayResolved(
        originalText: String,
        currentDate: String,
        personName: String,
        calendarType: BirthdayCalendarType,
        remindBeforeDays: Int
    ) -> AgentAnalysis {
        let actionValue = calendarType == .solar
            ? "create_solar_birthday_reminder"
            : "create_lunar_birthday_reminder"

        return AgentAnalysis(
            intent: "birthday_detected",
            riskLevel: "medium",
            requiresConfirmation: false,
            shouldExecuteNow: true,
            card: AgentCard(
                type: "birthday",
                title: "生日提醒",
                summary: "我理解这是 \(personName) 的\(calendarType == .solar ? "阳历" : "农历")生日。",
                message: "信息已经够了，我会按每年提前 \(remindBeforeDays) 天安排提醒。",
                options: []
            ),
            toolPlan: [
                AgentToolPlan(
                    tool: actionValue,
                    when: "now",
                    params: [
                        "type": .string("birthday"),
                        "person_name": .string(personName),
                        "date_text": .string("今天"),
                        "date": .string(currentDate),
                        "remind_before_days": .number(Double(remindBeforeDays)),
                        "calendar_type": .string(calendarType == .solar ? "solar" : "lunar")
                    ]
                )
            ],
            memoryToSave: [
                AgentMemoryToSave(type: "input_summary", content: "用户提到 \(personName) 今天生日，生日类型为\(calendarType == .solar ? "阳历" : "农历")。")
            ],
            userVisibleText: "信息已经够了，我会按每年提前 \(remindBeforeDays) 天安排提醒。"
        )
    }

    private static func extractPersonName(from text: String) -> String {
        let separators = ["今天生日", "生日"]
        var candidate = text
        for separator in separators {
            if let range = candidate.range(of: separator) {
                candidate = String(candidate[..<range.lowerBound])
                break
            }
        }

        let prefixes = ["我朋友", "我的朋友", "朋友", "我家人", "我的家人", "家人", "我", "的"]
        for prefix in prefixes {
            if candidate.hasPrefix(prefix) {
                candidate.removeFirst(prefix.count)
            }
        }

        candidate = candidate
            .replacingOccurrences(of: "是", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return candidate.isEmpty ? "生日主角" : candidate
    }
}
