// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 DwDestiny
// Input: Authorization requests and planned notifications (title, body, topic) from MonitorEngine.
// Output: System notifications through UNUserNotificationCenter with the action "复制给 Agent"; authorization state as a string.
//         Callbacks: the action (copy the prompt of one topic, the card stays closed) and a tap on the notification (open the card).
// Pos: Mac-only notification layer (docs/PROJECT.md 5, docs/DESIGN.md 6.9); without an app bundle it does nothing and reports "unavailable".
//      The global budget (3 per hour, 10 per day) moved to the engine, which consumes it in problem order.
//      R-14 (docs/DESIGN_V2.md 14.3): a tap passes the item to `onOpenCard`. The engine hands it to AppDelegate.openPanel(pinning:),
//      which opens the PanelWindow and pins the sidebar of NotificationPlanner.sidebarItem(for:). Owner WP-B; the callback type is unchanged.

import Foundation
import UserNotifications

/// Authorization strings: "authorized" | "denied" | "not_determined" | "unavailable".
/// Completion handlers run on an arbitrary queue; the caller hops to its own queue.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let categoryID = "molemonitor.alert"
    static let copyActionID = "molemonitor.copy-prompt"

    private let center: UNUserNotificationCenter?

    /// Called on an arbitrary queue when the user taps "复制给 Agent". The card stays closed.
    var onCopyPrompt: ((PromptTopic) -> Void)?
    /// Called on an arbitrary queue when the user taps the notification itself. The card opens and shows the item.
    var onOpenCard: ((HealthItem?) -> Void)?

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
        // UNVERIFIED-ON-MAC: UNNotificationAction/UNNotificationCategory initializers and setNotificationCategories.
        // Fallback: remove the category; notifications then come without the action and a tap still opens the card.
        let copy = UNNotificationAction(identifier: Notifier.copyActionID, title: "复制给 Agent", options: [])
        let category = UNNotificationCategory(identifier: Notifier.categoryID, actions: [copy], intentIdentifiers: [], options: [])
        center?.setNotificationCategories([category])
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

    /// Posts one planned notification when authorized. The engine has already applied the budget and the order.
    /// The identifier is the dedupe key, so a newer notification of the same event replaces the older one.
    func post(_ planned: PlannedNotification) {
        guard let center else { return }
        center.getNotificationSettings { settings in
            guard Notifier.authorizationString(settings.authorizationStatus) == "authorized" else { return }
            let content = UNMutableNotificationContent()
            content.title = planned.title
            content.body = planned.body
            content.sound = .default
            content.threadIdentifier = planned.item.rawValue
            content.categoryIdentifier = Notifier.categoryID
            content.userInfo = ["topic": planned.topic.rawValue, "item": planned.item.rawValue]
            let request = UNNotificationRequest(identifier: planned.key, content: content, trigger: nil)
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

    /// A tap on the action or on the notification body.
    // UNVERIFIED-ON-MAC: didReceive response delegate signature and UNNotificationDefaultActionIdentifier.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let topic: PromptTopic? = (info["topic"] as? String).flatMap { PromptTopic(rawValue: $0) }
        let item: HealthItem? = (info["item"] as? String).flatMap { HealthItem(rawValue: $0) }
        if response.actionIdentifier == Notifier.copyActionID {
            if let topic { onCopyPrompt?(topic) }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            onOpenCard?(item)
        }
        completionHandler()
    }
}
