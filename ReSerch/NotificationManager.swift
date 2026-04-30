import UserNotifications

enum NotificationManager {
    static func requestPermission() {
        #if !targetEnvironment(simulator)
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        #endif
    }

    /// Brief per-item progress ping during a batch — silent (no sound) to avoid
    /// spamming the user. Useful when the user moves to another app and wants to
    /// know the batch is still alive.
    static func sendBatchProgress(current: Int, total: Int, lastTitle: String?) {
        let content = UNMutableNotificationContent()
        content.title = "ReSerch"
        if let title = lastTitle, !title.isEmpty {
            let trimmed = title.count > 50 ? String(title.prefix(50)) + "…" : title
            content.body = "\(current) of \(total): \(trimmed)"
        } else {
            content.body = "\(current) of \(total) transcripts done"
        }
        // Silent — don't spam sounds. Final completion uses sendBatchComplete with sound.
        let request = UNNotificationRequest(
            identifier: "reserch.batch.progress",   // re-use identifier so each new ping replaces the previous
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
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
