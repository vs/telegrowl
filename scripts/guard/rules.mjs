// Leak-guard rules: pure functions, no I/O.
//
// scanText() finds secrets and personal data in text; checkPath() flags files
// that must never be committed. scan.mjs wires these into git hooks, Claude
// Code hooks, and CI. Rules must stay generic: private values live only in the
// local denylist (see refresh-denylist.mjs), never in this repository.

export const ALLOW_MARKER = 'guard:allow';
export const MAX_FILE_BYTES = 2 * 1024 * 1024;

// Public placeholders that look like the things we detect.
export const ALLOWED_EMAILS = new Set([
  'semyon.vadishev@gmail.com', // public author address
  'noreply@anthropic.com',
  'noreply@github.com',
]);
const ALLOWED_EMAIL_DOMAINS = /(^|\.)(example\.(com|org|net)|users\.noreply\.github\.com)$/i;
const ALLOWED_TEAM_IDS = new Set(['ABCDE12345', 'YOUR_TEAM_ID']);
const ALLOWED_API_IDS = new Set(['1234567']); // docs/setup.md example
const ALLOWED_PHONES = /^\+44 ?7700 ?900\d{3}$|^\+1 ?\(?555\)? ?01\d\d/;
const ALLOWED_HOME_USERS = new Set(['<you>', 'you', 'USER', '$USER', 'Shared', 'runner', 'username', 'name']);

// --- Generic secret formats -------------------------------------------------

const SECRET_PATTERNS = [
  ['private-key', /-----BEGIN (?:[A-Z]+ )?PRIVATE KEY-----/],
  ['aws-access-key', /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/],
  ['github-token', /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{50,})\b/],
  ['slack-token', /\bxox[abposr]-[A-Za-z0-9-]{10,}\b/],
  ['stripe-key', /\b[rs]k_live_[A-Za-z0-9]{16,}\b/],
  ['google-api-key', /\bAIza[0-9A-Za-z_-]{35}\b/],
  ['openai-key', /\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b/],
  ['anthropic-key', /\bsk-ant-[A-Za-z0-9_-]{20,}\b/],
  ['telegram-bot-token', /\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b/],
  ['jwt', /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/],
  ['url-password', /\b[a-z][a-z0-9+.-]*:\/\/[^\s:/@'"`]+:([^\s@/'"`]{3,})@[^\s'"`]+/i],
];

// key = value credentials; the value must look real (not a placeholder).
const KV_SECRET = /\b(api[_-]?hash|api[_-]?key|secret|token|passw(?:or)?d|client[_-]?secret)\b["']?\s*[:=]\s*["']([^"'\s]{8,})["']/gi;
const PLACEHOLDER_VALUE = /^(?:your[_-]|x{4,}|<|\$\{|\$\(|example|changeme|placeholder|dummy|test|fake|redacted)/i;

// Telegram API credentials in Swift/xcconfig style assignments.
const TELEGRAM_API_ID = /\btelegramApiId\s*:\s*Int\s*=\s*([1-9]\d{4,})/;
const TELEGRAM_API_HASH = /\btelegramApiHash\s*=\s*"([0-9a-f]{32})"/i;

// Apple Team ID in project settings.
const TEAM_ID = /\b(?:DEVELOPMENT_TEAM|DevelopmentTeam)\s*[:=]\s*"?([A-Z0-9]{10})\b/g;

const EMAIL = /[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g;
const HOME_PATH = /(?:\/Users\/|\/home\/|[A-Za-z]:\\Users\\)([^\s/\\'"`)]+)/g;
const PHONE = /\+\d{1,3}[ -]\(?\d{2,4}\)?[ -]\d{3}[ -]?\d{2,4}(?:[ -]\d{2,4})?/g;

// --- Denylist ---------------------------------------------------------------

/**
 * Parses denylist text: one `kind<TAB>value` per line, `#` comments allowed.
 * Kinds:
 *   ticker     case-sensitive, whole word (e.g. an all-caps identifier)
 *   ticker-ci  case-insensitive, whole word
 *   word-ci    case-insensitive, whole word, also matches camelCase/snake parts
 *   literal    exact substring
 *   regex      JavaScript regular expression (case-sensitive)
 */
export function parseDenylist(text) {
  const entries = [];
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+#.*$/, '').trimEnd();
    if (!line || line.startsWith('#')) continue;
    const tab = line.indexOf('\t');
    if (tab < 0) continue;
    const kind = line.slice(0, tab).trim();
    const value = line.slice(tab + 1);
    const re = denyRegex(kind, value);
    if (re) entries.push({ kind, value, re });
  }
  return entries;
}

const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

export function denyRegex(kind, value) {
  if (!value) return null;
  switch (kind) {
    case 'ticker': return new RegExp(`(?<![A-Za-z0-9])${escape(value)}(?![A-Za-z0-9])`);
    case 'ticker-ci': return new RegExp(`(?<![A-Za-z0-9])${escape(value)}(?![A-Za-z0-9])`, 'i');
    case 'word-ci': return new RegExp(`(?<![a-z0-9])${escape(value)}(?![a-z0-9])`, 'i');
    case 'literal': return new RegExp(escape(value));
    case 'regex': return new RegExp(value);
    default: return null;
  }
}

// --- Scanning ---------------------------------------------------------------

/** Redacts a matched value for display: keeps a short prefix only. */
export function redact(value) {
  const s = String(value);
  if (s.length <= 4) return '****';
  return `${s.slice(0, 2)}…(${s.length} chars)`;
}

/**
 * Scans text and returns findings `{ rule, line, preview }`. Values are
 * redacted in `preview`. Lines containing `guard:allow` are skipped.
 * Options: `denylist` (parsed entries), `path` (for context-specific rules).
 */
export function scanText(text, { denylist = [] } = {}) {
  const findings = [];
  const lines = String(text).split('\n');
  lines.forEach((line, i) => {
    if (line.includes(ALLOW_MARKER)) return;
    const add = (rule, value) => findings.push({ rule, line: i + 1, preview: redact(value) });

    for (const [rule, re] of SECRET_PATTERNS) {
      const m = line.match(re);
      if (m && !(rule === 'url-password' && PLACEHOLDER_VALUE.test(m[1]))) add(rule, m[0]);
    }
    for (const m of line.matchAll(KV_SECRET)) {
      if (!PLACEHOLDER_VALUE.test(m[2]) && /[0-9]/.test(m[2]) && /[A-Za-z]/.test(m[2])) add('key-value-secret', m[2]);
    }
    let m;
    if ((m = line.match(TELEGRAM_API_ID)) && !ALLOWED_API_IDS.has(m[1])) add('telegram-api-id', m[1]);
    if ((m = line.match(TELEGRAM_API_HASH))) add('telegram-api-hash', m[1]);
    for (const t of line.matchAll(TEAM_ID)) {
      if (!ALLOWED_TEAM_IDS.has(t[1])) add('apple-team-id', t[1]);
    }
    for (const e of line.matchAll(EMAIL)) {
      const email = e[0];
      if (line[e.index - 1] === ':') continue; // user:password@host, reported as url-password
      const domain = email.split('@')[1];
      if (!ALLOWED_EMAILS.has(email.toLowerCase()) && !ALLOWED_EMAIL_DOMAINS.test(domain) && !/\.(png|jpe?g|svg|pdf)$/i.test(domain)) {
        add('email', email);
      }
    }
    for (const h of line.matchAll(HOME_PATH)) {
      if (!ALLOWED_HOME_USERS.has(h[1])) add('home-path', h[0]);
    }
    for (const p of line.matchAll(PHONE)) {
      if (!ALLOWED_PHONES.test(p[0])) add('phone-number', p[0]);
    }
    for (const entry of denylist) {
      const d = line.match(entry.re);
      if (d) add(`denylist:${entry.kind}`, d[0]);
    }
  });
  return findings;
}

// --- Paths ------------------------------------------------------------------

const FORBIDDEN_PATHS = [
  ['env-file', /(^|\/)\.env(\.[^/]+)?$/],
  ['private-key-file', /\.(pem|p12|p8|key|keystore|jks|mobileprovision|cer)$|(^|\/)id_(rsa|ed25519|ecdsa)(\.pub)?$/i],
  ['local-config', /(^|\/)Config\.swift$|\.local\.xcconfig$/],
  ['tool-settings', /(^|\/)\.claude\/settings\.local\.json$|(^|\/)\.(idea|vscode)\//],
  ['session-data', /(^|\/)(tdlib|tdlib_files|send_queue)\/|td\.binlog$|\.(sqlite|sqlite3|db)$/i],
  ['secret-file', /\.secret$|(^|\/)(secrets?|credentials?)\.(json|ya?ml|txt|plist)$/i],
];
const DATA_EXPORT = /\.(csv|tsv|xlsx?|json|ndjson|sql|har)$/i;
const DATA_ALLOWED = /^(scripts\/screenshots\/fixtures\/|Telegrowl\/Resources\/Assets\.xcassets\/|\.github\/|scripts\/guard\/)|(^|\/)(Package\.resolved|package(-lock)?\.json)$/;
const MEDIA = /\.(png|jpe?g|gif|heic|webp|bmp|tiff?|mov|mp4|m4a|ogg|oga|wav|mp3|caf)$/i;
const MEDIA_ALLOWED = /^(docs\/|Telegrowl\/Resources\/Assets\.xcassets\/)/;

/** Returns findings for a repository-relative path (and optional size in bytes). */
const TEMPLATE_FILE = /\.(example|sample|template)$/;

export function checkPath(path, size = 0) {
  const findings = [];
  for (const [rule, re] of FORBIDDEN_PATHS) {
    if (re.test(path) && !TEMPLATE_FILE.test(path)) findings.push({ rule, path });
  }
  if (DATA_EXPORT.test(path) && !DATA_ALLOWED.test(path)) findings.push({ rule: 'data-export', path });
  if (MEDIA.test(path) && !MEDIA_ALLOWED.test(path)) findings.push({ rule: 'media-outside-docs', path });
  if (size > MAX_FILE_BYTES) findings.push({ rule: 'large-file', path, size });
  return findings;
}

// --- Claude Code Bash commands ----------------------------------------------

/** Removes heredoc bodies and quoted strings so only the command skeleton remains. */
export function stripQuoted(command) {
  let s = String(command);
  // Heredocs: <<EOF ... EOF, <<'EOF', <<"EOF", <<-EOF
  s = s.replace(/<<-?\s*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[^\n]*\n[\s\S]*?\n\s*\2(?=\s|$)/g, '<<HEREDOC');
  s = s.replace(/'[^']*'/g, "''");
  s = s.replace(/"(?:[^"\\]|\\.)*"/g, '""');
  return s;
}

const BASH_RULES = [
  ['no-verify', /(^|\s)--no-verify(\s|=|$)/],
  ['commit-no-verify', /\bgit\b[^;&|]*\bcommit\b[^;&|]*\s-[a-zA-Z]*n[a-zA-Z]*(\s|$)/],
  ['force-push', /\bgit\b[^;&|]*\bpush\b[^;&|]*(\s--force(-with-lease)?(\s|=|$)|\s-[a-zA-Z]*f[a-zA-Z]*(\s|$)|\s\+[^\s]+)/],
  ['hooks-path', /core\.hooksPath/i],
  ['filter-repo', /\bfilter-repo\b|\bfilter-branch\b|\bbfg\b/],
  ['guard-override', /\bLEAK_GUARD_OVERRIDE\b/],
];

/** Returns the names of rules that a shell command violates. */
export function checkBashCommand(command) {
  const skeleton = stripQuoted(command);
  return BASH_RULES.filter(([, re]) => re.test(skeleton)).map(([name]) => name);
}
