import Foundation
import UserNotifications

@MainActor
enum ReadingReminderScheduler {
    private static let reminderRequestID = "daily-reading-goal-reminder"
    private static let lastChanceRequestID = "daily-reading-goal-last-chance"
    private static let lastChanceBufferMinutes = 15

    static func reschedule(for store: Store, requestAuthorizationIfNeeded: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [reminderRequestID, lastChanceRequestID])

        guard store.goal.reminderEnabled else { return }

        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined where requestAuthorizationIfNeeded:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else { return }
            } catch {
                return
            }
        default:
            return
        }

        await scheduleStandardReminder(for: store, center: center)
        await scheduleLastChanceReminder(for: store, center: center)
    }

    static func exampleBody(goalMinutes: Int = 30, readMinutes: Int = 18, streak: Int = 5, bestStreak: Int = 8) -> String {
        notificationBody(
            remainingMinutes: max(1, goalMinutes - readMinutes),
            streak: streak,
            bestStreak: bestStreak
        )
    }

    private static func scheduleStandardReminder(for store: Store, center: UNUserNotificationCenter) async {
        guard let reminderDate = nextReminderDate(hour: store.goal.reminderHour, minute: store.goal.reminderMinute) else { return }
        let goalMinutes = max(1, store.goal.minutes)
        let readMinutes = minutesRead(on: reminderDate, store: store)
        let remainingMinutes = max(0, goalMinutes - readMinutes)
        guard remainingMinutes > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your reading goal is close"
        content.body = notificationBody(
            remainingMinutes: remainingMinutes,
            streak: streakForReminder(on: reminderDate, store: store),
            bestStreak: store.bestStreak()
        )
        content.sound = .default

        await addNotification(
            identifier: reminderRequestID,
            date: reminderDate,
            content: content,
            center: center
        )
    }

    private static func scheduleLastChanceReminder(for store: Store, center: UNUserNotificationCenter) async {
        guard let reminder = nextLastChanceReminder(for: store) else { return }

        let content = UNMutableNotificationContent()
        content.title = "Last chance to hit today’s goal"
        content.body = lastChanceBody(remainingMinutes: reminder.remainingMinutes)
        content.sound = .default

        await addNotification(
            identifier: lastChanceRequestID,
            date: reminder.date,
            content: content,
            center: center
        )
    }

    private static func addNotification(
        identifier: String,
        date: Date,
        content: UNNotificationContent,
        center: UNUserNotificationCenter
    ) async {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    private static func nextReminderDate(hour: Int, minute: Int) -> Date? {
        let cal = Calendar.current
        let now = Date()
        let safeHour = min(23, max(0, hour))
        let safeMinute = min(59, max(0, minute))
        var comps = cal.dateComponents([.year, .month, .day], from: now)
        comps.hour = safeHour
        comps.minute = safeMinute
        comps.second = 0
        guard let today = cal.date(from: comps) else { return nil }
        if today > now { return today }
        return cal.date(byAdding: .day, value: 1, to: today)
    }

    private static func nextLastChanceReminder(for store: Store) -> (date: Date, remainingMinutes: Int)? {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        for dayOffset in 0...1 {
            guard let day = cal.date(byAdding: .day, value: dayOffset, to: today),
                  let reminder = lastChanceReminder(on: day, store: store),
                  reminder.date > now else {
                continue
            }
            return reminder
        }

        return nil
    }

    private static func lastChanceReminder(on day: Date, store: Store) -> (date: Date, remainingMinutes: Int)? {
        let cal = Calendar.current
        let goalMinutes = max(1, store.goal.minutes)
        let readMinutes = minutesRead(on: day, store: store)
        let remainingMinutes = max(0, goalMinutes - readMinutes)
        guard remainingMinutes > 0 else { return nil }
        guard let nextMidnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: day)) else { return nil }

        let warningLeadMinutes = remainingMinutes + lastChanceBufferMinutes
        guard let reminderDate = cal.date(byAdding: .minute, value: -warningLeadMinutes, to: nextMidnight),
              cal.isDate(reminderDate, inSameDayAs: day) else {
            return nil
        }

        return (reminderDate, remainingMinutes)
    }

    private static func minutesRead(on date: Date, store: Store) -> Int {
        Fmt.minutes(store.secondsByDay()[Fmt.dayKey(date)] ?? 0)
    }

    private static func streakForReminder(on date: Date, store: Store) -> Int {
        let cal = Calendar.current
        let map = store.secondsByDay()
        let need = max(1, store.goal.minutes) * 60
        let met: (Date) -> Bool = { (map[Fmt.dayKey($0)] ?? 0) >= need }
        var cursor = date
        if !met(cursor) {
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var count = 0
        while met(cursor) {
            count += 1
            cursor = cal.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        return count
    }

    private static func notificationBody(remainingMinutes: Int, streak: Int, bestStreak: Int) -> String {
        let minuteText = remainingMinutes == 1 ? "1 minute" : "\(remainingMinutes) minutes"
        let streakText = streak == 1 ? "1-day streak" : "\(streak)-day streak"

        if bestStreak > streak {
            let daysAway = bestStreak - streak + 1
            let recordText = daysAway == 1 ? "1 day" : "\(daysAway) days"
            return "You’re on a \(streakText). Read \(minuteText) tonight to keep it alive. You’re \(recordText) away from beating your best streak."
        }

        if streak > 0 {
            return "You’re on a \(streakText). Read \(minuteText) tonight to keep your momentum going."
        }

        return "You have \(minuteText) left to hit today’s goal. A short reading session still counts."
    }

    private static func lastChanceBody(remainingMinutes: Int) -> String {
        let minuteText = remainingMinutes == 1 ? "1 minute" : "\(remainingMinutes) minutes"
        return "You need \(minuteText) to hit today’s goal. Start now and you still have a little buffer before midnight."
    }
}
