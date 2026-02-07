# User Avatars Design

## Goal

Replace colored initials circles with real Telegram profile photos in the chat list and settings views.

## Scope

- **ChatListView** — show chat photo next to each chat row
- **SettingsView** — show current user's profile photo in the account section
- **Not in scope** — conversation view message bubbles (future enhancement)

## Component: AvatarView

A reusable SwiftUI view (~60 lines) that handles three states:

1. **No photo** — colored initials circle (current behavior, extracted from existing code)
2. **Photo exists, not downloaded** — show minithumbnail (blurred ~40px JPEG from `Minithumbnail.data`) while downloading `photo.small` (160x160)
3. **Photo downloaded** — show full image from `file.local.path`

Parameters: photo info (ChatPhotoInfo? or ProfilePhoto?), fallback title, size.

## Data Flow

1. `AvatarView` appears with photo info and title
2. Checks `photo.small.local.isDownloadingCompleted` — if true, shows image immediately
3. If not, displays minithumbnail and triggers `TelegramService.downloadPhoto(file:)`
4. On download completion, crossfades to full image via `.transition(.opacity)`

## TelegramService Addition

```swift
func downloadPhoto(file: File) async throws -> File {
    try await api.downloadFile(
        fileId: file.id,
        limit: 0,
        offset: 0,
        priority: 1,
        synchronous: true
    )
}
```

Reuses the same pattern as `downloadVoice()`.

## Caching

Rely on TDLib's built-in file caching. No custom cache layer.

## Fallback Chain

Real photo → minithumbnail → colored initials. Graceful degradation at every step.

## Files Changed

| File | Change |
|------|--------|
| `Telegrowl/Views/AvatarView.swift` | New — reusable avatar component |
| `Telegrowl/Views/ChatListView.swift` | Replace initials circle with AvatarView |
| `Telegrowl/Views/SettingsView.swift` | Replace initials circle with AvatarView |
| `Telegrowl/Services/TelegramService.swift` | Add `downloadPhoto(file:)` method |
