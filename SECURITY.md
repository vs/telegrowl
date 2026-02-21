# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Report them privately through GitHub's
[private vulnerability reporting](https://github.com/vs/telegrowl/security/advisories/new)
(*Security* tab → *Report a vulnerability*). Include steps to reproduce, the
affected version or commit, and the impact you expect.

This is a personal project maintained in spare time. I aim to acknowledge
reports within a week and will coordinate a fix and disclosure with you.

## Supported versions

Only the latest commit on `main` is supported. There are no binary releases.

## Security model

Telegrowl is a client-only iOS app. There is no Telegrowl server: the app talks
directly to Telegram through [TDLib](https://core.telegram.org/tdlib).

- **Credentials.** Each build embeds the builder's own Telegram `api_id` and
  `api_hash` from the gitignored `Config.swift`. They identify the app, not a
  user, but they can be abused if leaked, so never commit or share them.
- **Telegram session.** After you sign in, TDLib keeps the session and caches
  (chats, messages, downloaded media) in the app's `Documents/tdlib` and
  `Documents/tdlib_files` directories. TDLib's own database encryption is
  **not used** (the `databaseEncryptionKey` is empty), so the data is protected
  only by iOS Data Protection. Anyone with access to an unlocked device or an
  unencrypted backup may be able to read it.
- **Send queue.** Messages waiting to be sent, including voice recordings, are
  stored as plain files in `Documents/send_queue/`, protected only by iOS Data
  Protection, until Telegram confirms them.
- **Speech recognition.** Recognition runs on-device when the model for the
  selected locale is available. Otherwise it falls back to Apple's server-based
  recognition, which sends audio to Apple under Apple's privacy policy.
  Recognition runs continuously while a conversation is open, but only text
  after a trigger word is sent to Telegram.
- **Logs.** The app prints diagnostic logs to the console, including chat IDs,
  recognized speech, and dictated message text. Phone numbers are masked, but
  don't share raw logs.
- **Demo Mode** is compiled into DEBUG builds only and never starts TDLib.

Things that are out of scope: the security of Telegram's servers, TDLib itself
(report those to Telegram), and attacks that need a jailbroken or already
compromised device.
