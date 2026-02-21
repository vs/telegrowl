#if DEBUG
import Foundation
import TDLibKit

/// Fictional chats and messages for Demo Mode (DEBUG builds only).
///
/// Launch with `-demo` and point `TELEGROWL_DEMO_FIXTURES` at a JSON file
/// (see `scripts/screenshots/fixtures/demo.json`). Without the variable,
/// Demo Mode starts with an empty chat list.
///
/// Optional environment variables drive the initial screen for screenshots:
/// - `TELEGROWL_DEMO_AUTOLOGIN=1` — skip the welcome screen
/// - `TELEGROWL_DEMO_OPEN_CHAT=<chat id>` — push that conversation
/// - `TELEGROWL_DEMO_SETTINGS=1` — present Settings
/// - `TELEGROWL_DEMO_DICTATION=text|voice` — show the dictation overlay
/// - `TELEGROWL_DEMO_TRANSCRIPT=<text>` — live transcription for the overlay
/// - `TELEGROWL_DEMO_CLOCK=HH:mm` — message times are relative to this time today
struct DemoFixtures {
    let me: User
    let chats: [Chat]
    let messages: [Int64: [Message]]

    // MARK: - Launch Options

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    static var autoLogin: Bool { env["TELEGROWL_DEMO_AUTOLOGIN"] == "1" }
    static var openChatId: Int64? { env["TELEGROWL_DEMO_OPEN_CHAT"].flatMap(Int64.init) }
    static var showSettings: Bool { env["TELEGROWL_DEMO_SETTINGS"] == "1" }
    static var transcript: String { env["TELEGROWL_DEMO_TRANSCRIPT"] ?? "" }

    /// Pretend "now" is this time today (`HH:mm`), e.g. to match a status bar override.
    static var clock: Foundation.Date {
        guard let value = env["TELEGROWL_DEMO_CLOCK"] else { return Foundation.Date() }
        let parts = value.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return Foundation.Date() }
        return Calendar.current.date(
            bySettingHour: parts[0], minute: parts[1], second: 0, of: Foundation.Date()
        ) ?? Foundation.Date()
    }

    static var dictationState: DictationState? {
        switch env["TELEGROWL_DEMO_DICTATION"] {
        case "text": return .dictating
        case "voice": return .recording
        default: return nil
        }
    }

    // MARK: - Fixture File

    private struct FixtureFile: Decodable {
        struct Person: Decodable {
            let id: Int64
            let firstName: String
            let lastName: String
            let username: String?
        }

        struct Voice: Decodable {
            let duration: Int
            let caption: String?
            let waveform: [UInt8]?
        }

        struct FixtureMessage: Decodable {
            let id: Int64
            let out: Bool
            let minutesAgo: Int
            let text: String?
            let voice: Voice?
        }

        struct FixtureChat: Decodable {
            let id: Int64
            let title: String
            let unread: Int?
            let pinned: Bool?
            let messages: [FixtureMessage]
        }

        let me: Person
        let chats: [FixtureChat]
    }

    static func load() -> DemoFixtures? {
        guard let path = env["TELEGROWL_DEMO_FIXTURES"] else { return nil }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let file = try decoder.decode(FixtureFile.self, from: data)
            return build(from: file)
        } catch {
            print("❌ Demo: failed to load fixtures at \(path): \(error)")
            return nil
        }
    }

    // MARK: - Model Construction

    private static func build(from file: FixtureFile) -> DemoFixtures {
        let now = Int(clock.timeIntervalSince1970)
        let me = makeUser(file.me)

        var chats: [Chat] = []
        var messages: [Int64: [Message]] = [:]

        for (index, fixtureChat) in file.chats.enumerated() {
            let chatMessages = fixtureChat.messages.map { fixture in
                makeMessage(fixture, chatId: fixtureChat.id, myId: me.id, now: now)
            }
            messages[fixtureChat.id] = chatMessages
            chats.append(makeChat(
                fixtureChat,
                lastMessage: chatMessages.last,
                order: Int64(file.chats.count - index)
            ))
        }

        return DemoFixtures(me: me, chats: chats, messages: messages)
    }

    private static func makeUser(_ person: FixtureFile.Person) -> User {
        User(
            accentColorId: 0, activeStoryState: nil, addedToAttachmentMenu: false,
            backgroundCustomEmojiId: 0, emojiStatus: nil, firstName: person.firstName,
            haveAccess: true, id: person.id, isCloseFriend: false, isContact: false,
            isMutualContact: false, isPremium: false, isSupport: false, languageCode: "en",
            lastName: person.lastName, paidMessageStarCount: 0, phoneNumber: "",
            profileAccentColorId: 0, profileBackgroundCustomEmojiId: 0, profilePhoto: nil,
            restrictionInfo: nil, restrictsNewChats: false,
            status: .userStatusOnline(UserStatusOnline(expires: Int.max)),
            type: .userTypeRegular,
            upgradedGiftColors: nil,
            usernames: person.username.map {
                Usernames(activeUsernames: [$0], collectibleUsernames: [], disabledUsernames: [], editableUsername: $0)
            },
            verificationStatus: nil
        )
    }

    private static func makeChat(_ fixture: FixtureFile.FixtureChat, lastMessage: Message?, order: Int64) -> Chat {
        Chat(
            accentColorId: 0, actionBar: nil,
            availableReactions: .chatAvailableReactionsAll(ChatAvailableReactionsAll(maxReactionCount: 0)),
            background: nil, backgroundCustomEmojiId: 0, blockList: nil, businessBotManageBar: nil,
            canBeDeletedForAllUsers: false, canBeDeletedOnlyForSelf: true, canBeReported: false,
            chatLists: [.chatListMain], clientData: "", defaultDisableNotification: false,
            draftMessage: nil, emojiStatus: nil, hasProtectedContent: false, hasScheduledMessages: false,
            id: fixture.id, isMarkedAsUnread: false, isTranslatable: false, lastMessage: lastMessage,
            lastReadInboxMessageId: 0, lastReadOutboxMessageId: lastMessage?.id ?? 0,
            messageAutoDeleteTime: 0, messageSenderId: nil,
            notificationSettings: ChatNotificationSettings(
                disableMentionNotifications: false, disablePinnedMessageNotifications: false,
                muteFor: 0, muteStories: false, showPreview: true, showStoryPoster: false,
                soundId: 0, storySoundId: 0,
                useDefaultDisableMentionNotifications: true, useDefaultDisablePinnedMessageNotifications: true,
                useDefaultMuteFor: true, useDefaultMuteStories: true, useDefaultShowPreview: true,
                useDefaultShowStoryPoster: true, useDefaultSound: true, useDefaultStorySound: true
            ),
            pendingJoinRequests: nil,
            permissions: ChatPermissions(
                canAddLinkPreviews: true, canChangeInfo: false, canCreateTopics: false,
                canInviteUsers: false, canPinMessages: true, canSendAudios: true,
                canSendBasicMessages: true, canSendDocuments: true, canSendOtherMessages: true,
                canSendPhotos: true, canSendPolls: false, canSendVideoNotes: true,
                canSendVideos: true, canSendVoiceNotes: true
            ),
            photo: nil,
            positions: [ChatPosition(isPinned: fixture.pinned ?? false, list: .chatListMain, order: TdInt64(integerLiteral: Int(order)), source: nil)],
            profileAccentColorId: 0, profileBackgroundCustomEmojiId: 0, replyMarkupMessageId: 0,
            theme: nil, title: fixture.title,
            type: .chatTypePrivate(ChatTypePrivate(userId: fixture.id)),
            unreadCount: fixture.unread ?? 0, unreadMentionCount: 0, unreadReactionCount: 0,
            upgradedGiftColors: nil,
            videoChat: VideoChat(defaultParticipantId: nil, groupCallId: 0, hasParticipants: false),
            viewAsTopics: false
        )
    }

    private static func makeMessage(_ fixture: FixtureFile.FixtureMessage, chatId: Int64, myId: Int64, now: Int) -> Message {
        let content: MessageContent
        if let voice = fixture.voice {
            let file = File(
                expectedSize: 0, id: 0,
                local: LocalFile(
                    canBeDeleted: false, canBeDownloaded: false, downloadOffset: 0,
                    downloadedPrefixSize: 0, downloadedSize: 0, isDownloadingActive: false,
                    isDownloadingCompleted: false, path: ""
                ),
                remote: RemoteFile(id: "", isUploadingActive: false, isUploadingCompleted: true, uniqueId: "", uploadedSize: 0),
                size: 0
            )
            content = .messageVoiceNote(MessageVoiceNote(
                caption: FormattedText(entities: [], text: voice.caption ?? ""),
                isListened: true,
                voiceNote: VoiceNote(
                    duration: voice.duration,
                    mimeType: "audio/ogg",
                    speechRecognitionResult: nil,
                    voice: file,
                    waveform: Waveform.pack(voice.waveform ?? Waveform.sample(seed: Int(fixture.id)))
                )
            ))
        } else {
            content = .messageText(MessageText(
                linkPreview: nil, linkPreviewOptions: nil,
                text: FormattedText(entities: [], text: fixture.text ?? "")
            ))
        }

        return Message(
            authorSignature: "", autoDeleteIn: 0, canBeSaved: true, chatId: chatId,
            containsUnreadMention: false, content: content, date: now - fixture.minutesAgo * 60,
            editDate: 0, effectId: 0, factCheck: nil, forwardInfo: nil, hasTimestampedMedia: false,
            id: fixture.id, importInfo: nil, interactionInfo: nil, isChannelPost: false,
            isFromOffline: false, isOutgoing: fixture.out, isPaidStarSuggestedPost: false,
            isPaidTonSuggestedPost: false, isPinned: false, mediaAlbumId: 0, paidMessageStarCount: 0,
            replyMarkup: nil, replyTo: nil, restrictionInfo: nil, schedulingState: nil,
            selfDestructIn: 0, selfDestructType: nil, senderBoostCount: 0, senderBusinessBotUserId: 0,
            senderId: .messageSenderUser(MessageSenderUser(userId: fixture.out ? myId : chatId)),
            sendingState: nil, suggestedPostInfo: nil, summaryLanguageCode: "", topicId: nil,
            unreadReactions: [], viaBotUserId: 0
        )
    }
}
#endif
