# Contributing to Telegrowl

Thanks for your interest! Bug reports, device test results (especially with
car or Bluetooth audio), and pull requests are all welcome.

## Getting started

1. Fork and clone the repository.
2. Follow [docs/setup.md](docs/setup.md) to create `Config.swift` (and
   `Configs/Signing.local.xcconfig` for devices).
3. Run `xcodegen generate` and build the **Telegrowl** scheme.

Use [Demo Mode](README.md#demo-mode) for UI work that doesn't need a Telegram
account.

## Making changes

- **Keep pull requests focused.** One fix or feature per PR is easier to review.
- **Regenerate the project** with `xcodegen generate` when you add, remove, or
  rename source files, and commit the updated `Telegrowl.xcodeproj`.
- **Match the existing style**: SwiftUI views, `@MainActor` services, and
  `print()` logging with the emoji prefixes described in the README.
- **Concurrency:** `AVAudioPCMBuffer` is not `Sendable`. Do buffer work
  synchronously on the audio thread and hop only computed values to the main
  actor (see `DictationService.processAudioBuffer`).
- **Verify** that the app builds without new warnings, and describe how you
  tested: simulator, device model, iOS version, and whether you used Bluetooth
  or CarPlay audio. There is no automated test suite yet; tests for pure logic
  such as trigger detection or waveform packing are especially welcome.
- **Update the docs** (README, `docs/setup.md`, `CLAUDE.md`) when behavior or
  setup changes.

## Commit messages

The history uses [Conventional Commits](https://www.conventionalcommits.org/):

```
feat: add voice message playback speed control
fix(dictation): restart recognition after Siri interruption
docs: clarify signing setup for personal teams
```

Common types are `feat`, `fix`, `refactor`, `docs`, and `chore`.

## Keep private data out

This app signs in to real Telegram accounts, so it is easy to leak personal
data by accident. Never commit:

- `Config.swift`, API IDs or hashes, bot tokens, or any other credential
- your Apple Team ID (it belongs in the gitignored `Signing.local.xcconfig`)
- phone numbers, usernames, chat names, or message contents from a real account
- screenshots or logs from a real account; use Demo Mode and fictional
  fixtures instead
- absolute paths from your machine, such as `/Users/<you>/…`

If you notice a leak in an open pull request, force-push a fixed branch and
rotate the credential. Once something is merged, removing it from history is
much harder.

## Reporting bugs

Open an issue with the device, iOS version, steps to reproduce, and relevant
console output (redact phone numbers, usernames, and chat names). For security
issues, follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE).
