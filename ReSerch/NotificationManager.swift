import UserNotifications

enum NotificationManager {
    static func requestPermission() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func sendBatchComplete(count: Int, failed: Int) {
        let content = UNMutableNotificationContent()
        content.title = "ReSerch"
        if failed == 0 {
            content.body = count == 1
                ? "1 transcript saved."
                : "\(count) transcripts saved."
        } else {
            content.body = "\(count) saved, \(failed) failed."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request)
    }
}
