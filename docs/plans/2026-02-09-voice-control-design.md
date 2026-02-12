# Voice-Controlled App Design

**Date:** 2026-02-09
**Status:** Design

## Overview

Make Telegrowl fully voice-controlled from launch. The app listens for commands immediately after authentication, enabling hands-free navigation, chat entry, message playback, and chat switching — all without touching the screen.

## Architecture

### New Components

**VoiceCommandService** (singleton, `@MainActor`)
- Runs from app launch after auth + permissions
- Owns AVAudioEngine + SFSpeechRecognizer for command detection
- Uses AVSpeechSynthesizer for all spoken announcements
- Manages an announcement queue for incoming messages
- States: `idle`, `listening`, `paused`, `announcing`, `awaitingResponse`, `transitioning`

**Voice Aliases** — `[Int64: String]` dictionary in UserDefaults via Config, mapping chatId to alias string.

### Modified Components

**VoiceChatService** — gains three new commands beyond mute/unmute:
- "close" → back to contacts view
- "chat with X" → switch to another contact's chat
- Cross-chat announcement handling during silence gaps

**ChatListView** — long-press context menu for voice alias management. Listening indicator in navigation bar.

**ContentView** — orchestrates handoffs between VoiceCommandService and VoiceChatService. Handles programmatic navigation triggered by voice commands.

**Config** — new settings for all command words, speech locale, behavior toggles.

**SettingsView** — new "Voice Control" section.

## Command Detection

### Silence-Bounded Recognition

Commands are distinguished from conversation by requiring silence gaps:
- Track audio levels via buffer RMS (same as existing VAD)
- State machine: `silent` → `speaking` → `silent`
- When `speaking` → `silent` transition occurs and silence lasts ≥ `Config.commandSilenceGap` (default 0.75s):
  - Check if preceding silence before speech was also ≥ 0.75s
  - If yes: the speech segment is a **command candidate**
  - Grab transcription text for that window
  - Run through command matching

### Speech Recognition

- SFSpeechRecognizer running continuously with rolling 50s restart (existing pattern)
- Locale configurable via `Config.speechLocale` (default `en-US`)
- On-device recognition preferred

### Command Matching

Keyword matching on transcribed text (case-insensitive).

**Contacts view commands:**

| Command | Config Key | Default | Behavior |
|---------|-----------|---------|----------|
| Exit | `exitCommand` | `"exit"` | Close the app |
| Chat with {name} | `chatWithPrefix` | `"chat with"` | Open chat with matched contact |
| Play | `playCommand` | `"play"` | Play/read latest message (5s window only) |
| Chat | `chatCommand` | `"chat"` | Enter voice chat with announced contact (5s window only) |
| Stop listening | `pauseCommand` | `"stop listening"` | Pause voice control |
| Start listening | `resumeCommand` | `"start listening"` | Resume (recognized even while paused) |

**Chat view commands (VoiceChatService):**

| Command | Config Key | Default | Behavior |
|---------|-----------|---------|----------|
| Mute | `muteCommand` | `"mute"` | Stop recording, keep playing incoming |
| Unmute | `unmuteCommand` | `"unmute"` | Resume recording |
| Close | `closeCommand` | `"close"` | Leave chat, return to contacts view |
| Chat with {name} | `chatWithPrefix` | `"chat with"` | Switch to another contact's chat |
| Play | `playCommand` | `"play"` | Play cross-chat message (announcement window only) |
| Chat | `chatCommand` | `"chat"` | Switch to announced contact (announcement window only) |

### Contact Name Matching

1. Check aliases first (exact match, case-insensitive)
2. Then check chat titles (substring match, case-insensitive)
3. First match wins
4. On match: announce full Telegram name via TTS ("Starting chat with {full name}")
5. On no match: announce "Contact not found"

All command words are configurable strings in Settings, allowing any language.

## Announcement Queue

### Incoming Message Announcements (Contacts View)

- When a new message arrives (voice or text), VoiceCommandService enqueues an announcement
- Queue is **deduplicated by chatId** — multiple messages from the same contact produce one announcement referencing the latest message
- Announcements processed sequentially: announce → 5s window → next (or expire)
- Format: "Message from {alias or full name}" via AVSpeechSynthesizer

### 5-Second Response Window

After each announcement:
1. VoiceCommandService enters `awaitingResponse` state, stores announced chatId + message reference
2. "Play" and "chat" commands become active
3. "Play" on voice message: download and play the audio
4. "Play" on text message (when `Config.readTextMessages` enabled): TTS reads the content
5. "Chat": enter voice chat with the announced contact
6. After 5s with no command: window expires, process next queued announcement or return to `listening`

### Cross-Chat Announcements (Chat View)

When `Config.announceCrossChat` is enabled (default: true):
- VoiceChatService observes incoming messages from **other** chats
- Waits for a silence gap (user not speaking) before announcing
- Pauses recording/VAD during TTS playback
- "Chat" during the announcement window: stop VoiceChatService, discard unsent recording, switch to announced contact
- "Play" during window: read/play the message without leaving current chat

## Service Handoff

### Contacts View → Chat View

1. User says "chat with bot" (or "chat" during 5s window)
2. VoiceCommandService matches contact
3. TTS announces "Starting chat with {full Telegram name}"
4. After TTS completes: VoiceCommandService stops its audio engine + speech recognizer
5. ContentView navigates programmatically to conversation + voice chat view
6. VoiceChatService starts, begins in **unmuted** state

### Chat View → Contacts View

1. User says "close"
2. VoiceChatService stops (discards any in-progress recording)
3. ContentView pops navigation back to ChatListView
4. VoiceCommandService restarts its engine

### Chat View → Different Chat

1. User says "chat with alice"
2. VoiceChatService stops (discards unsent recording)
3. VoiceCommandService resumes briefly: matches contact, announces full name
4. Handoff to new VoiceChatService instance for the new chat

Only one service owns the microphone at a time. The handoff gap (~0.5s) occurs during navigation transitions.

## TTS (AVSpeechSynthesizer)

- Shared instance on VoiceCommandService
- Uses `Config.speechLocale` for voice selection
- Before TTS or audio playback: pause speech recognizer input tap to avoid mic picking up speaker output
- Resume listening after TTS/playback completes (via AVSpeechSynthesizerDelegate)

Announcement strings:
- Incoming message: "Message from {alias or full name}"
- Chat entry: "Starting chat with {full Telegram name}"
- Error: "Contact not found"
- Text message read: speaks message content directly

## Voice Aliases

### Storage

- `Config.voiceAliases: [Int64: String]` — UserDefaults-backed dictionary
- `Config.setVoiceAlias(chatId:alias:)` / `Config.removeVoiceAlias(chatId:)`

### UI

- Long-press context menu on chat rows in ChatListView:
  - "Set Voice Alias" (no alias set) → alert with text field
  - "Edit Voice Alias" (alias exists) → alert with pre-filled text field
  - "Clear Voice Alias" (alias exists) → removes alias
- Alias displayed as a subtle label on the chat row (gray italic text under the title)

## Settings

### New Config Properties

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `speechLocale` | `String` | `"en-US"` | SFSpeechRecognizer + TTS locale |
| `exitCommand` | `String` | `"exit"` | Close the app |
| `chatWithPrefix` | `String` | `"chat with"` | Prefix for opening a chat |
| `playCommand` | `String` | `"play"` | Play/read latest message |
| `chatCommand` | `String` | `"chat"` | Enter chat with announced contact |
| `closeCommand` | `String` | `"close"` | Leave chat view |
| `pauseCommand` | `String` | `"stop listening"` | Pause voice control |
| `resumeCommand` | `String` | `"start listening"` | Resume voice control |
| `readTextMessages` | `Bool` | `true` | TTS reads text messages on "play" |
| `announceCrossChat` | `Bool` | `true` | Announce other contacts while in chat |
| `commandSilenceGap` | `Double` | `0.75` | Seconds of silence to bound a command |
| `announcementWindow` | `Double` | `5.0` | Seconds to respond after announcement |

### SettingsView

New "Voice Control" section:
- Toggle: Voice Control enabled/disabled
- Locale picker
- Command word fields (grouped)
- Toggle: Read text messages aloud
- Toggle: Announce cross-chat messages

## App Launch Flow

1. App starts → register defaults (existing)
2. Auth check → AuthView if needed (existing)
3. Once authenticated + chats loaded:
   - Request microphone permission if not granted
   - Request speech recognition permission if not granted
   - If either denied: show contacts view with banner explaining voice control is disabled + link to Settings
   - If both granted: `VoiceCommandService.shared.start()`
4. Contacts view shown with listening indicator

### Visual Indicators

- Navigation bar: small mic icon (pulses while listening, static with slash when paused, spinner during transitions)
- Chat rows: alias shown as gray italic subtitle
- During announcement: corresponding chat row briefly highlights

## Edge Cases

1. **TTS/mic conflict:** Pause speech recognizer input tap before any TTS or audio playback. Resume after completion.

2. **Rapid commands:** Ignore commands during `transitioning` state. Only accept in `listening` or `awaitingResponse`.

3. **Command words in conversation:** The 0.75s silence boundary prevents casual speech from triggering commands in chat view.

4. **Speech recognition restart gap:** ~0.5s gap during 50s rolling restart. Commands may be missed; user can repeat. Same pattern as existing VoiceChatService.

5. **Duplicate contact names:** First match wins. Users should set unique aliases to disambiguate.

6. **Background:** VoiceCommandService pauses when app backgrounds. Auto-restarts on foreground if it was listening before.

7. **Phone call / Siri interrupts:** AVAudioSession interruption → auto-pause. Resume on return to foreground. Same as existing interruption handling.

8. **Permissions denied:** App works normally with manual tap navigation. Voice control disabled gracefully. Toggle in settings to re-enable.

## Out of Scope (Future)

- Background listening (requires wake word, unreliable on iOS)
- Fuzzy/phonetic name matching
- Intent classification (NLP-based command parsing)
- Per-contact notification sounds
- Siri Shortcuts integration
