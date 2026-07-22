import Foundation
import UserNotifications

extension UNMutableNotificationContent {
    func modify(message: Message, baseUrl: String) {
        // Body and title
        if let body = message.message {
            self.body = body
        }
        
        // Set notification title to short URL if there is no title. The title is always set
        // by the server, but it may be empty.
        if let title = message.title, title != "" {
            self.title = title
        } else {
            self.title = topicShortUrl(baseUrl: baseUrl, topic: message.topic)
        }
        
        // Emojify title or message
        let emojiTags = parseEmojiTags(message.tags)
        if !emojiTags.isEmpty {
            if let title = message.title, title != "" {
                self.title = emojiTags.joined(separator: "") + " " + self.title
            } else {
                self.body = emojiTags.joined(separator: "") + " " + self.body
            }
        }
        
        // Add custom actions
        //
        // We re-define the categories every time here, which is weird, but it works. When tapped, the action sets the
        // actionIdentifier in the application(didReceive) callback. This logic is handled in the AppDelegate. This approach
        // is described in a comment in https://stackoverflow.com/questions/30103867/changing-action-titles-in-interactive-notifications-at-run-time#comment122812568_30107065
        //
        // We also must set the .foreground flag, which brings the notification to the foreground and avoids an error about
        // permissions. This is described in https://stackoverflow.com/a/44580916/1440785
        configureNotificationActions(message: message)
        
        // Group by topic, and only elevate priority 5 alerts to critical when the user opted in
        // and iOS has granted critical alert permission.
        self.threadIdentifier = topicUrl(baseUrl: baseUrl, topic: message.topic)
        
        // Map priorities to interruption level (light up screen, ...) and relevance (order)
        switch message.priority {
        case 1:
            self.sound = .default
            self.interruptionLevel = .passive
            self.relevanceScore = 0
        case 2:
            self.sound = .default
            self.interruptionLevel = .passive
            self.relevanceScore = 0.25
        case 4:
            self.sound = .default
            self.interruptionLevel = .timeSensitive
            self.relevanceScore = 0.75
        case 5:
            if Store.shared.getCriticalAlertsEnabled() && Store.getCriticalAlertsAuthorized() {
                self.sound = .defaultCritical
                self.interruptionLevel = .critical
            } else {
                self.sound = .default
                self.interruptionLevel = .timeSensitive
            }
            self.relevanceScore = 1
        default:
            self.sound = .default
            self.interruptionLevel = .active
            self.relevanceScore = 0.5
        }
        
        // Make sure the userInfo matches, so that when the notification is tapped, the AppDelegate
        // can properly navigate to the right topic and re-assemble the message.
        self.userInfo = message.toUserInfo()
        self.userInfo["base_url"] = baseUrl
    }

    func attachImageIfNeeded(message: Message, user: BasicUser?, completionHandler: @escaping () -> Void) {
        guard let attachment = message.attachment else {
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }
        guard attachment.isImageAttachment(), let url = URL(string: attachment.url) else {
            completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            return
        }

        if let localFileUrl = AttachmentFileStore.existingLocalFileUrl(
            notificationID: message.id,
            remoteUrl: url,
            attachment: attachment,
            mimeType: attachment.type
        ) {
            DispatchQueue.main.async {
                let didAttachImage = self.attachLocalImage(from: localFileUrl)
                self.completeAttachmentHandling(message: message, didAttachImage: didAttachImage, completionHandler: completionHandler)
            }
            return
        }

        var request = URLRequest(url: url)
        request.setValue(ApiService.userAgent, forHTTPHeaderField: "User-Agent")
        if let user = user {
            request.setValue(user.toHeader(), forHTTPHeaderField: "Authorization")
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 20

        URLSession(configuration: config).downloadTask(with: request) { tempUrl, response, _ in
            guard
                let tempUrl,
                let httpResponse = response as? HTTPURLResponse,
                (200..<300).contains(httpResponse.statusCode)
            else {
                self.completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
                return
            }

            let mimeType = attachment.type ?? httpResponse.mimeType
            guard mimeType?.lowercased().hasPrefix("image/") == true || attachment.isImageAttachment() else {
                self.completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
                return
            }

            do {
                let downloaded = try AttachmentFileStore.storeDownloadedTemporaryFile(
                    notificationID: message.id,
                    remoteUrl: url,
                    attachment: attachment,
                    temporaryFileUrl: tempUrl,
                    mimeType: mimeType
                )
                Store.shared.completeAttachmentDownload(
                    notificationID: message.id,
                    localPath: downloaded.localFileUrl.path,
                    resolvedType: downloaded.mimeType,
                    resolvedSize: downloaded.size
                )
                DispatchQueue.main.async {
                    let didAttachImage = self.attachLocalImage(from: downloaded.localFileUrl)
                    self.completeAttachmentHandling(message: message, didAttachImage: didAttachImage, completionHandler: completionHandler)
                }
            } catch {
                Log.w("NotificationContent", "Failed to create notification attachment", error)
                self.completeAttachmentHandling(message: message, didAttachImage: false, completionHandler: completionHandler)
            }
        }.resume()
    }

    private func attachLocalImage(from localFileUrl: URL) -> Bool {
        do {
            let notificationAttachment = try UNNotificationAttachment(identifier: "attachment", url: localFileUrl)
            attachments = attachments + [notificationAttachment]
            return true
        } catch {
            Log.w("NotificationContent", "Failed to attach local image", error)
            return false
        }
    }

    /// Registers interactive action buttons on the lock screen / expanded notification.
    ///
    /// Important details:
    /// - Category must be registered **before** the notification is delivered (async-only registration races).
    /// - Category id is **unique per message** so concurrent notifications keep the correct button set.
    /// - iOS / ntfy support up to 3 user actions.
    private func configureNotificationActions(message: Message) {
        let userActions = message.actions ?? []
        guard !userActions.isEmpty else {
            categoryIdentifier = ""
            return
        }

        // Unique category so each notification keeps its own button labels/ids
        let categoryId = "ntfy.actions.\(message.id)"
        categoryIdentifier = categoryId

        let unActions: [UNNotificationAction] = userActions.prefix(3).enumerated().map { index, action in
            // Server may omit id; identifiers must be non-empty for didReceive matching.
            let identifier = action.id.isEmpty ? "action_\(index)_\(action.action)" : action.id
            // view: bring app/URL to foreground. http: run without forcing UI.
            let options: UNNotificationActionOptions = (action.action == "view") ? [.foreground] : []
            return UNNotificationAction(identifier: identifier, title: action.label, options: options)
        }

        let category = UNNotificationCategory(
            identifier: categoryId,
            actions: unActions,
            intentIdentifiers: [],
            options: []
        )

        // Merge with existing ntfy action categories, then register before delivery.
        // Previously this used async getNotificationCategories without waiting, so the
        // notification often appeared with a category id but no registered buttons.
        let center = UNUserNotificationCenter.current()
        let lock = DispatchSemaphore(value: 0)
        var toRegister = Set<UNNotificationCategory>([category])
        center.getNotificationCategories { existing in
            let others = existing.filter {
                $0.identifier != categoryId && $0.identifier.hasPrefix("ntfy.actions.")
            }
            var merged = Set(others).union([category])
            if merged.count > 40 {
                // Prefer keeping the newest category; drop arbitrary older ones
                merged = Set(Array(merged.suffix(40)))
            }
            toRegister = merged
            lock.signal()
        }
        if lock.wait(timeout: .now() + 0.8) == .timedOut {
            // Time budget (esp. NSE): still register at least this notification's buttons
            toRegister = [category]
        }
        center.setNotificationCategories(toRegister)
    }

    private func completeAttachmentHandling(message: Message, didAttachImage: Bool, completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.appendAttachmentSummaryIfNeeded(message: message, didAttachImage: didAttachImage)
            completionHandler()
        }
    }

    private func appendAttachmentSummaryIfNeeded(message: Message, didAttachImage: Bool) {
        guard let attachment = message.attachment else {
            return
        }
        if attachment.isImageAttachment(), didAttachImage {
            return
        }

        let summary = fallbackAttachmentSummary(attachment: attachment)
        guard !summary.isEmpty else {
            return
        }

        if body.isEmpty {
            body = summary
        } else {
            body = body + "\n\n" + summary
        }
    }
}

private func fallbackAttachmentSummary(attachment: MessageAttachment) -> String {
    var parts = [attachment.displayName()]
    if let size = attachment.size, size > 0 {
        parts.append(formatBytes(size))
    }
    if attachment.isExpired() {
        parts.append("expired")
    }
    return "Attachment: " + parts.joined(separator: ", ")
}
