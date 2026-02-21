// Tests for the leak-guard rules. Run: node --test 'scripts/guard/*.test.mjs'
//
// Fake secrets are assembled at runtime (join/repeat) so this file itself
// passes the guard.

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { checkBashCommand, checkPath, parseDenylist, redact, scanText, stripQuoted } from './rules.mjs';

const j = (...parts) => parts.join('');
const rules = (text, opts) => scanText(text, opts).map((f) => f.rule);

test('detects generic secret formats', () => {
  assert.deepEqual(rules(j('AK', 'IA', 'Q'.repeat(16))), ['aws-access-key']);
  assert.deepEqual(rules(j('gh', 'p_', 'a1'.repeat(18))), ['github-token']);
  assert.deepEqual(rules(j('-----BEGIN ', 'RSA PRIVATE KEY-----')), ['private-key']);
  assert.deepEqual(rules(j('123456789', ':AA', 'b'.repeat(33))), ['telegram-bot-token']);
  assert.deepEqual(rules(j('sk-', 'ant-', 'x9'.repeat(12))), ['anthropic-key']);
  assert.deepEqual(rules(j('AI', 'za', 'S'.repeat(35))), ['google-api-key']);
});

test('detects database URL passwords but not placeholders', () => {
  assert.deepEqual(rules(j('postgres://app:', 'hunter2x', '@db.internal:5432/app')), ['url-password']);
  assert.deepEqual(rules('postgres://app:${DB_PASSWORD}@localhost/app'), []);
  assert.deepEqual(rules('https://example.com/path'), []);
});

test('detects key=value credentials with realistic values only', () => {
  assert.deepEqual(rules(j('api_key = "', 'q7Rt9', 'Lm2Xp4', '"')), ['key-value-secret']);
  assert.deepEqual(rules('api_key = "YOUR_API_KEY"'), []);
  assert.deepEqual(rules('password: String'), []);
});

test('detects Telegram API credentials in Config.swift form', () => {
  assert.deepEqual(rules(j('static let telegramApiId: Int = ', '7654321')), ['telegram-api-id']);
  assert.deepEqual(rules(j('static let telegramApiHash = "', '0123456789abcdef'.repeat(2), '"')), ['telegram-api-hash']);
  assert.deepEqual(rules('static let telegramApiId: Int = 0'), []);
  assert.deepEqual(rules('static let telegramApiId: Int = 1234567'), []);
  assert.deepEqual(rules('static let telegramApiHash = ""'), []);
});

test('flags Apple Team IDs except placeholders', () => {
  assert.deepEqual(rules(j('DEVELOPMENT_TEAM = ', 'Q1W2E3R4T5', ';')), ['apple-team-id']);
  assert.deepEqual(rules('DEVELOPMENT_TEAM = ABCDE12345;'), []);
  assert.deepEqual(rules('DEVELOPMENT_TEAM = YOUR_TEAM_ID'), []);
});

test('flags emails except allowlisted placeholders', () => {
  assert.deepEqual(rules(j('mail me at jane.doe', '@', 'corp-mail.io')), ['email']);
  assert.deepEqual(rules('Co-Authored-By: Claude <noreply@anthropic.com>'), []);
  assert.deepEqual(rules('contact: someone@example.com'), []);
  assert.deepEqual(rules('1+vs@users.noreply.github.com'), []);
  assert.deepEqual(rules('icon@2x.png'), []);
});

test('flags personal home paths but not placeholders', () => {
  assert.deepEqual(rules(j('cd /Us', 'ers/alice/workspace')), ['home-path']);
  assert.deepEqual(rules(j('C:', '\\Users\\bob\\repo')), ['home-path']);
  assert.deepEqual(rules('absolute paths such as /Users/<you>/…'), []);
  assert.deepEqual(rules('cd /path/to/telegrowl'), []);
});

test('flags phone numbers except reserved fictional ranges', () => {
  assert.deepEqual(rules(j('+7 916 ', '555 1234')), ['phone-number']);
  assert.deepEqual(rules('e.g., +44 7700 900123'), []);
});

test('skips lines with the allow marker', () => {
  assert.deepEqual(rules(j('+7 916 ', '555 1234 // guard:allow')), []);
});

test('denylist kinds', () => {
  const list = parseDenylist([
    j('ticker\t', 'ZQXW'),
    j('ticker-ci\t', 'qwzx'),
    j('word-ci\t', 'acmecorp'),
    j('literal\t', 'secret/path'),
    j('regex\t', 'ID-[0-9]{4}'),
    '# comment',
  ].join('\n'));
  assert.equal(list.length, 5);
  const hit = (t) => rules(t, { denylist: list });
  assert.deepEqual(hit('holding ZQXW today'), ['denylist:ticker']);
  assert.deepEqual(hit('holding zqxw today'), []);
  assert.deepEqual(hit('ZQXWY is different'), []);
  assert.deepEqual(hit('QWZX here'), ['denylist:ticker-ci']);
  assert.deepEqual(hit('Working at AcmeCorp'), ['denylist:word-ci']);
  assert.deepEqual(hit('under /secret/path/x'), ['denylist:literal']);
  assert.deepEqual(hit('ref ID-1234'), ['denylist:regex']);
});

test('redacts values in previews', () => {
  const [finding] = scanText(j('AK', 'IA', 'Z'.repeat(16)));
  assert.ok(!finding.preview.includes('Z'.repeat(8)));
  assert.equal(redact('abc'), '****');
});

test('forbidden paths', () => {
  const p = (path, size) => checkPath(path, size).map((f) => f.rule);
  assert.deepEqual(p('.env'), ['env-file']);
  assert.deepEqual(p('config/.env.production'), ['env-file']);
  assert.deepEqual(p('.env.example'), []);
  assert.deepEqual(p('Telegrowl/App/Config.swift'), ['local-config']);
  assert.deepEqual(p('Telegrowl/App/Config.swift.template'), []);
  assert.deepEqual(p('Configs/Signing.local.xcconfig'), ['local-config']);
  assert.deepEqual(p('certs/dev.p12'), ['private-key-file']);
  assert.deepEqual(p('.claude/settings.local.json'), ['tool-settings', 'data-export']);
  assert.deepEqual(p('Documents/tdlib/db.sqlite'), ['session-data']);
  assert.deepEqual(p('exports/chats.csv'), ['data-export']);
  assert.deepEqual(p('scripts/screenshots/fixtures/demo.json'), []);
  assert.deepEqual(p('screenshot.png'), ['media-outside-docs']);
  assert.deepEqual(p('docs/screenshots/chats.png'), []);
  assert.deepEqual(p('Telegrowl/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'), []);
  assert.deepEqual(p('big.bin', 3 * 1024 * 1024), ['large-file']);
});

test('Bash command rules', () => {
  const b = checkBashCommand;
  assert.deepEqual(b('git commit --no-verify -m x'), ['no-verify']);
  assert.deepEqual(b('git commit -nm "msg"'), ['commit-no-verify']);
  assert.deepEqual(b('git commit -am "msg"'), []);
  assert.deepEqual(b('git commit --amend --no-edit'), []);
  assert.deepEqual(b('git push --force origin main'), ['force-push']);
  assert.deepEqual(b('git push -f'), ['force-push']);
  assert.deepEqual(b('git push --force-with-lease=main:abc origin main'), ['force-push']);
  assert.deepEqual(b('git push origin +main'), ['force-push']);
  assert.deepEqual(b('git push -u origin main'), []);
  assert.deepEqual(b('git config core.hooksPath /dev/null'), ['hooks-path']);
  assert.deepEqual(b('git -c core.hooksPath=x commit -m y'), ['hooks-path']);
  assert.deepEqual(b('git filter-repo --path x'), ['filter-repo']);
  assert.deepEqual(b('LEAK_GUARD_OVERRIDE=1 git commit -m x'), ['guard-override']);
  assert.deepEqual(b('git log -n 5'), []);
});

test('Bash rules ignore quoted strings and heredocs', () => {
  assert.deepEqual(checkBashCommand('git commit -m "docs: explain --no-verify and --force"'), []);
  assert.deepEqual(checkBashCommand("echo 'git push --force'"), []);
  const heredoc = 'git commit -F - <<\'EOF\'\nnever use --no-verify or core.hooksPath\nEOF';
  assert.deepEqual(checkBashCommand(heredoc), []);
  assert.equal(stripQuoted('a "b" \'c\''), 'a "" \'\'');
});
