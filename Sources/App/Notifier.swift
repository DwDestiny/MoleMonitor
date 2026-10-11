// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Authorization requests and alerts (type, title, body) from MonitorEngine.
// Output: System notifications through UNUserNotificationCenter; authorization state as a string.
// Pos: Mac-only notification layer (docs/PROJECT.md 5); without an app bundle it does nothing and reports "unavailable".

import Foundation
import UserNotifications

/// Authorization strings: "authorized" | "denied" | "not_determined" | "unavailable".
/// Completion handlers run on an arbitrary queue; the caller hops to its own queue.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    private let lock = NSLock()
    private var budget = NotificationBudget()

    var isAvailable: Bool { center != nil }

    override init() {
        // UNUserNotificationCenter.current() raises an exception when the process has no app bundle
        // (for example a bare binary run by --diagnose). Do not touch the UN API in that case.
        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }
        super.init()
        center?.delegate = self
    }

    // MARK: Authorization

    func currentAuthorization(completion: @escaping (String) -> Void) {
        guard let center else { completion("unavailable"); return }
        center.getNotificationSettings { settings in
            completion(Notifier.authorizationString(settings.authorizationStatus))
        }
    }

    // UNVERIFIED-ON-MAC: UNUserNotificationCenter API spelling (requestAuthorization(options:completionHandler:),
    // getNotificationSettings, add(_:withCompletionHandler:)) and whether an ad-hoc signed app gets a prompt (V19).
    // Fallback: on any error the state is "unavailable" and the status card shows the denied text.
    func requestAuthorization(completion: @escaping (String) -> Void) {
        guard let center else { completion("unavailable"); return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            // An error (for example an ad-hoc signature that the system refuses) is reported as unavailable.
            if error != nil { completion("unavailable"); return }
            guard let self else { completion("unavailable"); return }
            self.currentAuthorization(completion: completion)
        }
    }

    private static func authorizationString(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "not_determined"
        @unknown default: return "unavailable"
        }
    }

    // MARK: Posting

    /// Posts one notification when authorized and under the global cap (3 per hour, 10 per day).
    /// An over-cap alert is dropped here; it stays in the engine's alert list.
    /// The identifier is "type:subject", so a newer notification of the same alert replaces the older one.
    func post(type: String, subject: String, title: String, body: String, now: Date) {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            guard Notifier.authorizationString(settings.authorizationStatus) == "authorized" else { return }
            self.lock.lock()
            let allowed = self.budget.tryConsume(now: now)
            self.lock.unlock()
            guard allowed else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            content.threadIdentifier = type
            let request = UNNotificationRequest(identifier: "\(type):\(subject)", content: content, trigger: nil)
            center.add(request) { _ in }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    /// Show banners even while this app is frontmost (the status card may be open).
    // UNVERIFIED-ON-MAC: presentation options .banner/.list (macOS 11+) and the delegate method signature.
    // Fallback: remove this delegate method; notifications then appear only when the app is not frontmost.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
