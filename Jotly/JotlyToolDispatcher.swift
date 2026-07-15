import Foundation
import os

@MainActor
final class ToolDispatcher {
    private let birthdayExecutor = BirthdayToolExecutor()
    private let store = LocalStore()

    struct ToolExecutionResult {
        let completionMessage: String
        let reminderInfo: CardReminderInfo?
        let metadata: [String: String]?
        var shouldDeleteCallingCard: Bool = false
    }

    func execute(plan: AgentToolPlan, card: MemoryCard) async throws -> ToolExecutionResult {
        let parametersJSON = try? JSONEncoder().encode(plan.params)
        let actionLogID = try? store.createActionLog(
            cardID: card.id,
            toolName: plan.tool,
            parametersJSON: parametersJSON
        )

        do {
            let result = try await executeTool(plan: plan, card: card)
            try? store.finishActionLog(
                id: actionLogID,
                resultJSON: actionResultJSON(result),
                errorMessage: nil
            )
            return result
        } catch {
            try? store.finishActionLog(
                id: actionLogID,
                resultJSON: nil,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    private func executeTool(plan: AgentToolPlan, card: MemoryCard) async throws -> ToolExecutionResult {
        let executionCard = enrichedCard(card, with: plan)
        switch plan.tool {
        case "counter.add":
            var category = "coffee"
            var name = "记录"
            var count = 1
            if let cat = plan.params["category"], case .string(let s) = cat { category = s }
            if let n = plan.params["name"], case .string(let s) = n { name = s }
            if let c = plan.params["count"] {
                if case .number(let d) = c { count = Int(d) }
                else if case .string(let s) = c { count = Int(s) ?? 1 }
            }

            let totalCount = try getCounterTotal(category: category) + count

            let message = "已记下，这是你本月第 \(totalCount) 杯\(category == "coffee" ? "咖啡" : name)。"

            return ToolExecutionResult(
                completionMessage: message,
                reminderInfo: CardReminderInfo(
                    type: "counter",
                    personName: category,
                    date: DateFormatting.todayString(),
                    remindBeforeDays: 0,
                    nextTriggerDate: nil,
                    status: "completed",
                    calendarEventId: nil,
                    reminderItemId: nil,
                    notificationRequestId: nil
                ),
                metadata: [
                    "category": category,
                    "name": name,
                    "count": String(count),
                    "total_count": String(totalCount)
                ]
            )

        case "card.ask_user":
            return ToolExecutionResult(
                completionMessage: executionCard.message.isEmpty ? "请确认下一步。" : executionCard.message,
                reminderInfo: nil,
                metadata: executionCard.metadata
            )

        case "memory.save", "record_only":
            let recordTitle = executionCard.metadata?["title"] ?? executionCard.title
            let content = plan.params["content"]?.stringValue
                ?? executionCard.metadata?["content"]
                ?? executionCard.message
            let memoryID = "memory_\(UUID().uuidString)"
            let now = Date().timeIntervalSince1970
            let persistedMemoryID = try store.saveMemoryItem(
                MemoryItemRecord(
                    id: memoryID,
                    type: plan.params["type"]?.stringValue ?? "event",
                    content: content.isEmpty ? recordTitle : content,
                    structuredDataJSON: try? JSONEncoder().encode(plan.params),
                    importance: plan.params["importance"]?.doubleValue ?? 0.5,
                    confidence: plan.params["confidence"]?.doubleValue ?? 1.0,
                    status: "active",
                    sourceEventID: nil,
                    sourceMessageID: nil,
                    embeddingStatus: "pending",
                    createdAt: now,
                    updatedAt: now
                ),
                linkedCardID: executionCard.id
            ) ?? memoryID
            Task(priority: .utility) {
                await MemoryOSCoordinator.shared.indexMemory(id: persistedMemoryID)
            }
            var metadata = mergedExecutionMetadata(card: executionCard, reminderInfo: nil) ?? [:]
            metadata["memory_id"] = memoryID
            return ToolExecutionResult(
                completionMessage: plan.tool == "record_only" ? "已保存。" : "已记录。",
                reminderInfo: CardReminderInfo(
                    type: "record",
                    personName: recordTitle.isEmpty ? "普通记录" : recordTitle,
                    date: DateFormatting.todayString(),
                    remindBeforeDays: 0,
                    nextTriggerDate: nil,
                    status: "none",
                    calendarEventId: nil,
                    reminderItemId: nil,
                    notificationRequestId: nil
                ),
                metadata: metadata
            )

        case "memory.update":
            var metadata = executionCard.metadata ?? [:]
            metadata["updated_at"] = DateFormatting.dateTimeString(from: Date())
            metadata["content"] = plan.params["content"]?.stringValue ?? metadata["content"] ?? executionCard.message
            return ToolExecutionResult(
                completionMessage: "已更新当前卡片记录。",
                reminderInfo: executionCard.reminderInfo,
                metadata: metadata
            )

        case "create_solar_birthday_reminder", "reminder.create_solar_birthday":
            let opt = CardOption(key: "C", label: "阳历生日", value: "create_solar_birthday_reminder")
            let result = try await birthdayExecutor.execute(option: opt, card: executionCard)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: mergedExecutionMetadata(card: executionCard, reminderInfo: result.reminderInfo)
            )

        case "create_lunar_birthday_reminder", "reminder.create_lunar_birthday", "lunar_series.create":
            let opt = CardOption(key: "B", label: "阴历生日", value: "create_lunar_birthday_reminder")
            let result = try await birthdayExecutor.execute(option: opt, card: executionCard)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: mergedExecutionMetadata(card: executionCard, reminderInfo: result.reminderInfo)
            )

        case "create_date_reminder", "create_reminder", "reminder.create", "calendar.create_event", "notification.schedule":
            let opt = CardOption(key: "B", label: "创建日期提醒", value: "create_date_reminder")
            let result = try await birthdayExecutor.execute(option: opt, card: executionCard)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: mergedExecutionMetadata(card: executionCard, reminderInfo: result.reminderInfo)
            )

        case "reminder.update", "calendar.update", "calendar.update_event":
            return try await replaceExistingDateArtifacts(plan: plan, card: card)

        case "family_holiday_reminders.create":
            let remindBeforeDays = plan.params["remind_before_days"]?.intValue ?? 5
            let result = try await birthdayExecutor.createFamilyHolidayReminders(card: executionCard, remindBeforeDays: remindBeforeDays)
            try store.appendBirthdayEvent(result.event, reminderTask: result.reminderTask)
            return ToolExecutionResult(
                completionMessage: result.completionMessage,
                reminderInfo: result.reminderInfo,
                metadata: mergedExecutionMetadata(card: executionCard, reminderInfo: result.reminderInfo)
            )

        case "habit.create":
            var title = "新打卡"
            if let t = plan.params["title"], case .string(let s) = t { title = s }
            
            var dates: [String] = []
            if let checkInsVal = plan.params["initial_check_ins"], case .array(let arr) = checkInsVal {
                for entryVal in arr {
                    if case .object(let obj) = entryVal,
                       let dateVal = obj["date"], case .string(let d) = dateVal {
                        let countVal = obj["count"]
                        var count = 1
                        if let c = countVal {
                            if case .number(let n) = c { count = Int(n) }
                            else if case .string(let s) = c { count = Int(s) ?? 1 }
                        }
                        for _ in 0..<count {
                            dates.append(d)
                        }
                    }
                }
            }
            if dates.isEmpty {
                dates = [DateFormatting.todayString()]
            }
            
            return ToolExecutionResult(
                completionMessage: "已创建习惯卡片“\(title)”，包含初始打卡纪录。",
                reminderInfo: nil,
                metadata: [
                    "card_id": executionCard.id,
                    "title": title,
                    "initial_check_in_dates": jsonString(dates)
                ]
            )
            
        case "habit.check_in":
            guard let cardIdVal = plan.params["card_id"], case .string(let cardId) = cardIdVal else {
                throw JotlyError.invalidToolParameters("card_id is missing")
            }
            let snapshot = try store.load()
            guard let idx = snapshot.cards.firstIndex(where: { $0.id == cardId }) else {
                throw JotlyError.invalidToolParameters("Card \(cardId) not found")
            }
            var existingCard = snapshot.cards[idx]
            var dates = existingCard.habitCheckInDates ?? []
            
            if let checkInsVal = plan.params["check_ins"], case .array(let arr) = checkInsVal {
                for entryVal in arr {
                    if case .object(let obj) = entryVal,
                       let dateVal = obj["date"], case .string(let d) = dateVal {
                        let countVal = obj["count"]
                        var count = 1
                        if let c = countVal {
                            if case .number(let n) = c { count = Int(n) }
                            else if case .string(let s) = c { count = Int(s) ?? 1 }
                        }
                        for _ in 0..<count {
                            dates.append(d)
                        }
                    }
                }
            } else {
                dates.append(DateFormatting.todayString())
            }
            
            existingCard.habitCheckInDates = dates
            if let msgVal = plan.params["optimized_message"], case .string(let msg) = msgVal {
                existingCard.message = msg
            } else {
                existingCard.message = "已更新，当前累计 \(dates.count) 次。"
            }
            existingCard.status = .completed
            existingCard.markUpdated()
            try store.upsertCard(existingCard)
            
            return ToolExecutionResult(
                completionMessage: existingCard.message,
                reminderInfo: nil,
                metadata: ["card_id": cardId, "total_count": String(dates.count)],
                shouldDeleteCallingCard: true
            )
            
        case "countdown.create":
            guard let titleVal = plan.params["title"], case .string(let title) = titleVal else {
                throw JotlyError.invalidToolParameters("title is missing")
            }
            guard let targetDateVal = plan.params["target_date"], case .string(let targetDate) = targetDateVal else {
                throw JotlyError.invalidToolParameters("target_date is missing")
            }
            
            var newCard = MemoryCard(
                id: "countdown_\(UUID().uuidString)",
                type: "countdown",
                title: title,
                status: .completed,
                originalText: card.originalText,
                summary: "倒数日已设定",
                message: "已创建“\(title)”的倒计时。",
                completionMessage: "已创建“\(title)”的倒数卡片，目标日为 \(targetDate)。",
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
            newCard.targetDateString = targetDate
            try store.upsertCard(newCard)
            return ToolExecutionResult(
                completionMessage: "已创建“\(title)”的倒数卡片，目标日为 \(targetDate)。",
                reminderInfo: nil,
                metadata: ["card_id": newCard.id, "title": title, "target_date": targetDate]
            )
            
        case "countdown.update":
            guard let cardIdVal = plan.params["card_id"], case .string(let cardId) = cardIdVal else {
                throw JotlyError.invalidToolParameters("card_id is missing")
            }
            let snapshot = try store.load()
            guard let idx = snapshot.cards.firstIndex(where: { $0.id == cardId }) else {
                throw JotlyError.invalidToolParameters("Card \(cardId) not found")
            }
            var existingCard = snapshot.cards[idx]
            
            if let titleVal = plan.params["title"], case .string(let t) = titleVal {
                existingCard.title = t
            }
            if let targetDateVal = plan.params["target_date"], case .string(let td) = targetDateVal {
                existingCard.targetDateString = td
            }
            existingCard.message = "倒计时已更新。"
            existingCard.status = .completed
            existingCard.markUpdated()
            try store.upsertCard(existingCard)
            
            return ToolExecutionResult(
                completionMessage: "已更新倒数日“\(existingCard.title)”的基准日期。",
                reminderInfo: nil,
                metadata: [
                    "card_id": cardId,
                    "title": existingCard.title,
                    "target_date": existingCard.targetDateString ?? ""
                ],
                shouldDeleteCallingCard: true
            )

        case "asset.ingest":
            guard let itemsValue = plan.params["items"], case .array(let itemValues) = itemsValue else {
                throw JotlyError.invalidToolParameters("items is missing")
            }
            let now = Date().timeIntervalSince1970
            var records: [AssetRecord] = []
            var displayItems: [[String: String]] = []
            for itemValue in itemValues {
                guard case .object(let item) = itemValue,
                      let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else { continue }
                let category = item["category"]?.stringValue ?? "other"
                let amount = item["total_price"]?.doubleValue
                    ?? item["amount"]?.doubleValue
                    ?? item["unit_price"]?.doubleValue
                    ?? item["price"]?.doubleValue
                let purchaseDate = parsedTimestamp(item["purchase_date"]?.stringValue)
                let expiryDate = parsedTimestamp(
                    item["estimated_expiry_date"]?.stringValue
                        ?? item["expiry_date"]?.stringValue
                )
                let estimateNote = item["estimate_note"]?.stringValue
                    ?? item["expiry_basis"]?.stringValue
                let payload = try? JSONEncoder().encode(itemValue)
                records.append(
                    AssetRecord(
                        id: "asset_\(UUID().uuidString)",
                        sourceCardID: executionCard.id,
                        normalizedName: normalizedKey(name),
                        name: name,
                        category: category,
                        quantity: item["quantity"]?.doubleValue ?? 1,
                        amount: amount,
                        currency: item["currency"]?.stringValue ?? "CNY",
                        purchasedAt: purchaseDate,
                        estimatedExpiryAt: expiryDate,
                        estimateNote: estimateNote,
                        payloadJSON: payload,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                displayItems.append([
                    "name": name,
                    "category": category,
                    "quantity": compactNumber(item["quantity"]?.doubleValue ?? 1),
                    "amount": amount.map(compactNumber) ?? "",
                    "estimate_note": estimateNote ?? ""
                ])
            }
            guard !records.isEmpty else {
                throw JotlyError.invalidToolParameters("items contains no valid asset")
            }
            try store.upsertAssets(records)
            var metadata = executionCard.metadata ?? [:]
            metadata["asset_count"] = String(records.count)
            metadata["asset_items_json"] = jsonString(displayItems)
            return ToolExecutionResult(
                completionMessage: "已将 \(records.count) 件商品加入资产记录。",
                reminderInfo: nil,
                metadata: metadata
            )

        case "subscription.save":
            guard let serviceName = (plan.params["service_name"]?.stringValue
                ?? plan.params["name"]?.stringValue)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !serviceName.isEmpty else {
                throw JotlyError.invalidToolParameters("service_name is missing")
            }
            let now = Date().timeIntervalSince1970
            let amount = plan.params["amount"]?.doubleValue
                ?? plan.params["price"]?.doubleValue
            let record = SubscriptionRecord(
                id: "subscription_\(UUID().uuidString)",
                sourceCardID: executionCard.id,
                normalizedService: normalizedKey(serviceName),
                serviceName: serviceName,
                planName: plan.params["plan_name"]?.stringValue,
                amount: amount,
                currency: plan.params["currency"]?.stringValue ?? "CNY",
                billingCycle: plan.params["billing_cycle"]?.stringValue,
                nextBillingAt: parsedTimestamp(
                    plan.params["next_billing_date"]?.stringValue
                        ?? plan.params["next_billing_at"]?.stringValue
                ),
                payloadJSON: try? JSONEncoder().encode(plan.params),
                createdAt: now,
                updatedAt: now
            )
            try store.upsertSubscription(record)
            var metadata = executionCard.metadata ?? [:]
            metadata["service_name"] = serviceName
            metadata["plan_name"] = record.planName ?? ""
            metadata["amount"] = amount.map(compactNumber) ?? ""
            metadata["currency"] = record.currency ?? ""
            metadata["billing_cycle"] = record.billingCycle ?? ""
            metadata["next_billing_date"] = plan.params["next_billing_date"]?.stringValue
                ?? plan.params["next_billing_at"]?.stringValue
                ?? ""
            return ToolExecutionResult(
                completionMessage: "已保存 \(serviceName) 的订阅记录。",
                reminderInfo: nil,
                metadata: metadata
            )

        default:
            throw JotlyError.unsupportedTool(plan.tool)
        }
    }

    private func actionResultJSON(_ result: ToolExecutionResult) -> Data? {
        var payload: [String: Any] = [
            "completion_message": result.completionMessage,
            "should_delete_calling_card": result.shouldDeleteCallingCard
        ]
        if let metadata = result.metadata {
            payload["metadata"] = metadata
        }
        if let reminderInfo = result.reminderInfo,
           let reminderData = try? JSONEncoder().encode(reminderInfo),
           let reminderObject = try? JSONSerialization.jsonObject(with: reminderData) {
            payload["reminder_info"] = reminderObject
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private func normalizedKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
            .lowercased()
    }

    private func parsedTimestamp(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        if let date = DateFormatting.dateTime(from: value) {
            return date.timeIntervalSince1970
        }
        return DateFormatting.dayFormatter.date(from: String(value.prefix(10)))?.timeIntervalSince1970
    }

    private func compactNumber(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private func jsonString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    private func replaceExistingDateArtifacts(plan: AgentToolPlan, card: MemoryCard) async throws -> ToolExecutionResult {
        let previousSnapshot = try store.load()
        let previousEvents = previousSnapshot.birthdayEvents.filter { $0.cardId == card.id }
        let previousEventIDs = Set(previousEvents.map(\.id))
        let previousTaskIDs = Set(
            previousSnapshot.reminderTasks
                .filter { $0.cardId == card.id || previousEventIDs.contains($0.birthdayEventId) }
                .map(\.id)
        )

        let replacementTool: String
        switch plan.tool {
        case "calendar.update", "calendar.update_event":
            replacementTool = "calendar.create_event"
        default:
            replacementTool = "reminder.create"
        }

        var params = try completedDateUpdateParameters(from: plan.params, card: card)
        if params["repeat_rule"] == nil, let repeatRule = card.metadata?["repeat_rule"] {
            params["repeat_rule"] = .string(repeatRule)
        }
        if params["title"] == nil {
            params["title"] = .string(card.metadata?["title"] ?? card.title)
        }
        if params["note"] == nil {
            params["note"] = .string(card.metadata?["note"] ?? card.message)
        }

        let createPlan = AgentToolPlan(tool: replacementTool, when: "now", params: params)
        let result = try await execute(plan: createPlan, card: card)

        // The replacement is created first. A malformed update must never delete the
        // user's existing calendar/reminder artifacts.
        birthdayExecutor.cancelArtifacts(for: previousSnapshot, cardId: card.id)
        var updatedSnapshot = try store.load()
        updatedSnapshot.reminderTasks.removeAll {
            previousTaskIDs.contains($0.id) || previousEventIDs.contains($0.birthdayEventId)
        }
        updatedSnapshot.birthdayEvents.removeAll { previousEventIDs.contains($0.id) }
        try store.saveSnapshot(updatedSnapshot)

        var metadata = result.metadata ?? [:]
        metadata["updated_from_tool"] = plan.tool
        metadata["previous_calendar_event_id"] = card.reminderInfo?.calendarEventId ?? card.metadata?["calendar_event_id"] ?? ""
        metadata["previous_reminder_item_id"] = card.reminderInfo?.reminderItemId ?? card.metadata?["reminder_item_id"] ?? ""

        return ToolExecutionResult(
            completionMessage: "已更新当前卡片的时间安排。",
            reminderInfo: result.reminderInfo,
            metadata: metadata
        )
    }

    private func completedDateUpdateParameters(
        from requestedParameters: [String: JSONValue],
        card: MemoryCard
    ) throws -> [String: JSONValue] {
        var params = requestedParameters
        let dateKeys = ["date", "start_date", "due_date", "datetime", "date_time", "start_at", "due_at"]
        let explicitDateKey = dateKeys.first { params[$0]?.stringValue?.isEmpty == false }
        let requestedTime = params["time"]?.stringValue
            ?? params["start_time"]?.stringValue
            ?? params["new_time"]?.stringValue

        if params["time"] == nil, let requestedTime, !requestedTime.isEmpty {
            params["time"] = .string(requestedTime)
        }

        let previousDateValue = card.reminderInfo?.nextTriggerDate
            ?? dateKeys.compactMap { card.metadata?[$0] }.first
            ?? card.reminderInfo?.date
            ?? card.entities?.date
            ?? card.entities?.dateText

        guard let previousDateValue,
              let previousDate = DateFormatting.dateTime(from: previousDateValue)
        else {
            throw JotlyError.invalidToolParameters("当前卡片缺少原日程时间，无法安全修改。")
        }

        let previousDay = DateFormatting.string(from: previousDate)
        let previousTime = clockString(from: previousDate)

        if let explicitDateKey,
           let explicitDateValue = params[explicitDateKey]?.stringValue,
           let explicitDate = DateFormatting.dateTime(from: explicitDateValue) {
            if requestedTime != nil {
                // A separately supplied new time always wins over the time embedded
                // in an inherited full date such as "2026-07-16 15:00".
                params[explicitDateKey] = .string(DateFormatting.string(from: explicitDate))
            } else if !explicitDateValue.contains(":") {
                params[explicitDateKey] = .string("\(DateFormatting.string(from: explicitDate)) \(previousTime)")
            }
        } else if explicitDateKey == nil {
            params["date"] = .string(requestedTime == nil ? "\(previousDay) \(previousTime)" : previousDay)
        }

        guard dateKeys.contains(where: { params[$0]?.stringValue?.isEmpty == false }) else {
            throw JotlyError.invalidToolParameters("修改后的日程缺少日期信息。")
        }
        return params
    }

    private func clockString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    private func mergedExecutionMetadata(card: MemoryCard, reminderInfo: CardReminderInfo?) -> [String: String]? {
        var metadata = card.metadata ?? [:]
        if let reminderInfo {
            metadata["reminder_type"] = reminderInfo.type
            metadata["reminder_status"] = reminderInfo.status
            metadata["reminder_date"] = reminderInfo.date
            metadata["calendar_event_id"] = reminderInfo.calendarEventId ?? ""
            metadata["reminder_item_id"] = reminderInfo.reminderItemId ?? ""
            metadata["notification_request_id"] = reminderInfo.notificationRequestId ?? ""
            if let nextTriggerDate = reminderInfo.nextTriggerDate {
                metadata["next_trigger_date"] = nextTriggerDate
            }
        }
        return metadata.isEmpty ? nil : metadata
    }

    private func enrichedCard(_ card: MemoryCard, with plan: AgentToolPlan) -> MemoryCard {
        var updated = card
        var metadata = updated.metadata ?? [:]
        for (key, value) in plan.params {
            if let string = value.stringValue {
                metadata[key] = string
            }
        }
        metadata["tool"] = plan.tool
        updated.metadata = metadata

        var entities = updated.entities ?? BirthdayEntities(
            personName: nil,
            eventType: nil,
            dateText: nil,
            date: nil,
            remindBeforeDays: nil,
            lunarMonth: nil,
            lunarDay: nil,
            isLeapMonth: nil
        )
        entities.personName = metadata["person_name"] ?? metadata["personName"] ?? metadata["subject"] ?? metadata["title"] ?? entities.personName
        entities.eventType = metadata["event_type"] ?? metadata["eventType"] ?? metadata["title"] ?? entities.eventType
        entities.dateText = metadata["birthday_date_text"] ?? metadata["date_text"] ?? metadata["dateText"] ?? metadata["date"] ?? metadata["solar_date"] ?? metadata["start_date"] ?? entities.dateText
        entities.date = metadata["date"] ?? metadata["solar_date"] ?? metadata["birthday_date_text"] ?? metadata["date_text"] ?? metadata["start_date"] ?? metadata["due_date"] ?? entities.date
        entities.remindBeforeDays = plan.params["remind_before_days"]?.intValue
            ?? plan.params["remindBeforeDays"]?.intValue
            ?? entities.remindBeforeDays
        entities.lunarMonth = plan.params["lunar_month"]?.intValue ?? entities.lunarMonth
        entities.lunarDay = plan.params["lunar_day"]?.intValue ?? entities.lunarDay
        if let leap = metadata["is_leap_month"] ?? metadata["isLeapMonth"] {
            entities.isLeapMonth = leap == "true"
        }
        updated.entities = entities
        return updated
    }

    private func getCounterTotal(category: String) throws -> Int {
        let snapshot = try store.load()
        let matchingCards = snapshot.cards.filter {
            $0.type == "counter" && $0.metadata?["category"] == category
        }
        let total = matchingCards.reduce(0) { sum, card in
            let c = card.metadata?["count"].flatMap { Int($0) } ?? 0
            return sum + c
        }
        return total
    }
}
