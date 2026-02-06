# Voice Chat Mode Design

## Overview

A hands-free voice chat mode for 1-on-1 conversations with Telegram bots. The user enters voice chat, speaks naturally, and messages are recorded and sent automatically. Bot replies play back automatically. No buttons needed during conversation — voice commands control mute/unmute.

## State Machine

Two layers: a **mute toggle** and a **conversation loop**.

### Mute Layer

```
UNMUTED ──("mute" command or button)──→ MUTED
MUTED   ──("unmute" command or button)─→ UNMUTED
```

- **UNMUTED:** Conversation loop is active (see below). Speech recognition runs in parallel to detect "mute" keyword.
- **MUTED:** VAD and recording are off. Bot messages play automatically as they arrive. Speech recognition still runs, listening only for "unmute."

### Conversation Loop (UNMUTED only)

```
LISTENING ──(voice detected)──→ RECORDING
    ↑                               │
    │                        (silence detected)
    │                               ↓
PLAYING  ←──(bot msg queued)── PROCESSING
    │                               │
    └──(playback ends, queue empty)─┘
```

- **LISTENING** — Mic is hot (VAD monitoring). No recording, no playback. If a bot message is queued, transition to PLAYING. If voice is detected, transition to RECORDING.
- **RECORDING** — AVAudioRecorder writing to disk. Bot messages arriving go into playback queue (don't play). Silence detection auto-stops and transitions to PROCESSING.
- **PROCESSING** — Converting M4A to OGG/Opus and sending via TDLib. VAD stays active — if user starts talking again, new recording begins immediately (back to RECORDING). Bot messages queue.
- **PLAYING** — Playing back bot voice messages from the queue. If user starts speaking (VAD triggers), stop playback, keep remaining messages in queue, transition to RECORDING.

## Audio Pipeline

### AVAudioEngine (replaces AVAudioRecorder for voice chat mode)

```
AVAudioEngine (always running in voice chat mode)
    │
    ├── Input Tap (raw audio buffer)
    │       │
    │       ├── VAD: RMS amplitude monitoring
    │       │     → Exceeds threshold? Start writing to AVAudioFile
    │       │     → Below threshold for N seconds? Stop, send file
    │       │
    │       └── Speech Recognition: SFSpeechAudioBufferRecognitionRequest
    │             → Feeds same audio buffers
    │             → Listens for "mute" / "unmute" keywords
    │             → On match: toggle mute state, discard current audio
    │
    └── AVAudioFile (recording to disk)
          → Only writes when VAD says "voice detected"
          → Produces M4A file on silence → existing convert+send pipeline
```

The existing `AudioService` recording (AVAudioRecorder) stays intact for normal conversation view. Voice chat mode uses AVAudioEngine through `AudioService` — it owns the audio session and engine. `VoiceChatService` coordinates when to install/remove the input tap.

### Speech Recognition

- Uses `SFSpeechRecognizer` with on-device recognition (iOS 17+).
- `SFSpeechAudioBufferRecognitionRequest` fed from the same AVAudioEngine input tap.
- Listens for keywords: "mute", "unmute" (configurable in settings).
- Rolling restart every ~50 seconds to avoid Apple's ~1 minute session limit.
- When command detected: toggle mute state, discard in-progress recording (so command word isn't sent as a message).

## Message Queue

### Incoming (bot voice messages)

```
Message arrives while RECORDING/PROCESSING → Append to queue
Message arrives while LISTENING (unmuted)   → Transition to PLAYING
Message arrives while MUTED                 → Play immediately
Playback finishes                           → Next in queue? Play. Empty? → LISTENING
```

- Queue stores `VoiceNote` metadata (file ID, duration). Files downloaded on-demand when it's their turn to play.
- Prefetch: download next item in queue while current one plays.
- Non-voice messages (text, photo) are skipped — visible in normal conversation view.

### Interruption handling

When user speaks during bot playback:
1. Stop playback immediately
2. Remaining unplayed messages stay in queue
3. Start recording user's voice
4. After send + silence, queue resumes

### Outgoing

No queue needed. Each recording goes straight through the existing convert→send pipeline independently. TDLib handles message ordering.

## UI: VoiceChatView

Full-screen, minimal — designed for glancing, not staring.

```
┌──────────────────────────────┐
│                        [X]   │  ← Leave button
│                              │
│         ╭──────────╮         │
│         │          │         │
│         │  STATE   │         │  ← Large central indicator
│         │  VISUAL  │         │
│         │          │         │
│         ╰──────────╯         │
│                              │
│      "Listening..."          │  ← State label
│                              │
│    ┌────────────────────┐    │
│    │  Mute / Unmute     │    │  ← Toggle button
│    └────────────────────┘    │
│                              │
└──────────────────────────────┘
```

### Central visual by state

| State | Visual | Color |
|-------|--------|-------|
| LISTENING | Subtle pulsing circle | Neutral |
| RECORDING | Expanding waveform rings (audio level) | Red |
| PROCESSING | Spinning/sending animation | Neutral |
| PLAYING | Waveform animation from bot audio | Blue |
| MUTED | Dimmed circle with mute icon | Gray |

### State label

"Listening...", "Recording", "Sending...", "Bot is speaking", "Muted"

### Entry point

Toolbar button in conversation view (headphones or waveform icon). Opens VoiceChatView for the currently selected chat.

## Edge Cases & Error Handling

### Audio interruptions (phone call, Siri)
- `AVAudioSession.interruptionNotification` → transition to MUTED.
- When interruption ends, stay muted. Show "Tap to resume" prompt.

### VAD false triggers
- Minimum recording duration: if silence detected within ~0.5s of VAD trigger, discard (too short to be speech).
- VAD threshold configurable in settings for different environments.

### Command word in mid-sentence
- If "mute" detected inside longer phrase, honor it. Discard in-progress recording.

### Network loss
- Send failures go to retry queue. Voice chat stays active.
- Subtle "offline" indicator in UI.

### Permissions
- Check mic + speech recognition permissions on voice chat entry.
- If denied, show explanation and deep-link to Settings. Don't enter voice chat.

### Speech recognition session limits
- Apple limits ~1 minute continuous. Rolling restart every ~50s with brief overlap.

## File Changes

### New files
- `Telegrowl/Services/VoiceChatService.swift` — State machine, VAD, speech recognition, message queue
- `Telegrowl/Views/VoiceChatView.swift` — Full-screen voice chat UI

### Modified files
- `AudioService.swift` — Add `setupAudioEngine()` / `installInputTap()` for AVAudioEngine support
- `ContentView.swift` — Remove driving mode, add VoiceChatView navigation
- `ChatListView.swift` — Remove car icon from toolbar
- `SettingsView.swift` — Remove driving mode tips, rename "Hands-Free" to "Voice Chat", add VAD sensitivity and command keyword settings

### Removed
- Driving mode view code from ContentView
- "Hands-free" text references (replaced with "Voice Chat")
- `DrivingModeInfo` and `SiriShortcutsInfo` views from SettingsView

### Unchanged
- `TelegramService.swift` — VoiceChatService calls existing methods
- `AudioConverter.swift` — Same convert+send pipeline
- `ConversationView.swift` — Normal message view stays as-is
- `RecordButton.swift` / `InputBarView.swift` — Manual recording still works

## Settings Additions

| Setting | Default | Description |
|---------|---------|-------------|
| VAD sensitivity | Medium | Low/Medium/High threshold for voice detection |
| Mute command | "mute" | Keyword to mute |
| Unmute command | "unmute" | Keyword to unmute |
| Min recording duration | 0.5s | Discard recordings shorter than this |
