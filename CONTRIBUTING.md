# Contributing to Telegrowl

Thanks for your interest! Bug reports, device test results (especially with
car or Bluetooth audio), and pull requests are all welcome.

## Getting started

1. Fork and clone the repository.
2. Follow [docs/setup.md](docs/setup.md) to create `Config.swift` (and
   `Configs/Signing.local.xcconfig` for devices).
3. Run `./scripts/setup-hooks.sh` once to enable the leak guard (needs
   [Node.js](https://nodejs.org) 20 or later).
4. Run `xcodegen generate` and build the **Telegrowl** scheme.

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

## Leak guard

`scripts/guard/` scans everything headed for the repository for secrets and
personal data. It runs in three places:

| Where | What it checks |
|---|---|
| `pre-commit` hook | staged files: contents, forbidden file types, size |
| `commit-msg` hook | the commit message |
| `pre-push` hook | every outgoing commit (message, author email, added files); refuses non-fast-forward pushes to `main` and deleting `main` |
| CI (`.github/workflows/leak-guard.yml`) | the pushed or PR commit range plus the whole tree, using generic rules only |

The hooks live in `.githooks/` and are enabled by `scripts/setup-hooks.sh`.
They **fail closed**: without Node.js, commits and pushes are refused.

**What it detects** (see `scripts/guard/rules.mjs`):

- common secret formats (private keys, cloud and GitHub tokens, Telegram bot
  tokens, JWTs, `key = "value"` credentials, passwords in URLs)
- Telegram `api_id` / `api_hash` values and Apple Team IDs
- email addresses other than public placeholders, home-directory paths, and
  phone numbers outside reserved fictional ranges
- forbidden files: `.env*`, keys and certificates, `Config.swift`,
  `*.local.xcconfig`, local tool settings, TDLib or other session data, data
  exports outside `scripts/screenshots/fixtures/`, images outside `docs/` and
  the asset catalog, and files over 2 MB

**Private denylist.** Generic rules can't know your API ID or Team ID.
`node scripts/guard/refresh-denylist.mjs` builds a denylist from your local
`Config.swift`, `Signing.local.xcconfig`, and home path, and writes it to
`~/.config/telegrowl-guard/denylist.txt` (mode 0600, outside the repository).
Add your own entries to `manual.txt` in the same directory, one
`kind<TAB>value` per line; the kinds are `ticker`, `ticker-ci`, `word-ci`,
`literal`, and `regex`. Re-run the script when those files change. Values that
already appear in the working tree are skipped and listed so you can check
they aren't leaks.

**False positives.** If a line is a deliberate public placeholder, add a
`guard:allow` comment on that line. For a one-off, reviewed exception, a human
can set `LEAK_GUARD_OVERRIDE=1` for a single commit or push. Don't use
`--no-verify`.

**Tests:** `node --test 'scripts/guard/*.test.mjs'`. Fake secrets in the tests
are assembled at runtime so the test file passes its own guard.

## Reporting bugs

Open an issue with the device, iOS version, steps to reproduce, and relevant
console output (redact phone numbers, usernames, and chat names). For security
issues, follow [SECURITY.md](SECURITY.md) instead.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](LICENSE).
