import UserNotifications

enum NotificationManager {
    static func requestPermission() {
        #if !targetEnvironment(simulator)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        #endif
    }

    static func sendBatchComplete(count: Int, failed: Int, playlistName: String? = nil) {
        let content = UNMutableNotificationContent()
        if let name = playlistName, !name.isEmpty {
            let trimmed = name.count > 40 ? String(name.prefix(40)) + "…" : name
            content.title = "Playlist '\(trimmed)'"
        } else {
            content.title = "ReSerch"
        }
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
