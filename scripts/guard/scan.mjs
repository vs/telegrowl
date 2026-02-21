#!/usr/bin/env node
// Leak guard: scans content headed for this repository for secrets and
// personal data. Rules live in rules.mjs; private values in a local denylist
// outside the repository (see refresh-denylist.mjs).
//
// Modes:
//   --staged              staged changes (pre-commit hook)
//   --commit-msg <file>   a commit message (commit-msg hook)
//   --pre-push            commits being pushed, read from stdin (pre-push hook);
//                         refuses non-fast-forward pushes and deletion of main
//   --range <a..b>        commits in a range (CI); `--range all` scans everything
//   --tree                every tracked file at HEAD
//   --claude-hook         Claude Code PreToolUse hook for file-writing tools
//   --claude-bash         Claude Code PreToolUse hook for Bash commands
//
// Exit codes: 0 clean, 1 findings (git/CI), 2 blocked (Claude Code hooks).
// LEAK_GUARD_OVERRIDE=1 lets a human bypass git-hook findings after review.

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { checkBashCommand, checkPath, parseDenylist, scanText } from './rules.mjs';

const ZERO = /^0+$/;
const PROTECTED_BRANCH = 'refs/heads/main';

function git(args, opts = {}) {
  return execFileSync('git', args, { encoding: 'utf8', maxBuffer: 256 * 1024 * 1024, ...opts });
}
function gitBuffer(args, opts = {}) {
  return execFileSync('git', args, { maxBuffer: 256 * 1024 * 1024, ...opts });
}

function repoRoot(cwd = process.cwd()) {
  return git(['rev-parse', '--show-toplevel'], { cwd }).trim();
}

function loadDenylist(root) {
  const name = `${root.split(sep).pop().replace(/-public$/, '')}-guard`;
  const file = process.env.LEAK_GUARD_DENYLIST || join(homedir(), '.config', name, 'denylist.txt');
  if (!existsSync(file)) return { entries: [], file: null };
  return { entries: parseDenylist(readFileSync(file, 'utf8')), file };
}

const isBinary = (buf) => buf.subarray(0, 8000).includes(0);

// --- Reporting --------------------------------------------------------------

const findings = [];
function record(where, list) {
  for (const f of list) findings.push({ where, ...f });
}

function report(label) {
  if (!findings.length) return 0;
  console.error(`\n✋ leak-guard (${label}): ${findings.length} finding(s)\n`);
  for (const f of findings) {
    const loc = f.line ? `${f.where}:${f.line}` : f.where;
    const detail = f.preview ? ` ${f.preview}` : f.size ? ` (${(f.size / 1048576).toFixed(1)} MB)` : '';
    console.error(`  ${f.rule.padEnd(24)} ${loc}${detail}`);
  }
  console.error(`
Remove the data, or if a line is a deliberate public placeholder, add a
"guard:allow" comment on that line. See CONTRIBUTING.md → Leak guard.
`);
  return 1;
}

function finish(label) {
  const code = report(label);
  if (code && process.env.LEAK_GUARD_OVERRIDE === '1') {
    console.error('⚠️  LEAK_GUARD_OVERRIDE=1 set — allowing anyway.\n');
    process.exit(0);
  }
  process.exit(code);
}

// --- Scanners ---------------------------------------------------------------

function scanBlob(where, content, denylist) {
  if (isBinary(content)) return;
  record(where, scanText(content.toString('utf8'), { denylist }));
}

function scanCommit(sha, denylist, root) {
  const short = sha.slice(0, 10);
  const message = git(['log', '-1', '--format=%B', sha], { cwd: root });
  record(`${short} (message)`, scanText(message, { denylist }));
  const ids = git(['log', '-1', '--format=%ae%n%ce', sha], { cwd: root }).trim().split('\n');
  record(`${short} (author)`, scanText(ids.join('\n'), { denylist }));

  // Files added or modified by this commit (root commits: everything)
  const diff = git(['diff-tree', '-r', '--root', '--no-commit-id', '-z', '--diff-filter=ACMRT', sha], { cwd: root });
  const parts = diff.split('\0').filter(Boolean);
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const meta = parts[i].split(' ');
    const blob = meta[3];
    let path = parts[i + 1];
    if (/^[RC]/.test(meta[4])) path = parts[(i += 1) + 1];
    const size = Number(git(['cat-file', '-s', blob], { cwd: root }).trim());
    record(`${short} ${path}`, checkPath(path, size));
    scanBlob(`${short} ${path}`, gitBuffer(['cat-file', 'blob', blob], { cwd: root }), denylist);
  }
}

function scanStaged(root, denylist) {
  const names = git(['diff', '--cached', '--name-only', '-z', '--diff-filter=ACMRT'], { cwd: root }).split('\0').filter(Boolean);
  for (const path of names) {
    const content = gitBuffer(['show', `:${path}`], { cwd: root });
    record(path, checkPath(path, content.length));
    scanBlob(path, content, denylist);
  }
}

function scanTree(root, denylist) {
  const names = git(['ls-files', '-z'], { cwd: root }).split('\0').filter(Boolean);
  for (const path of names) {
    const full = join(root, path);
    if (!existsSync(full)) continue;
    const content = readFileSync(full);
    record(path, checkPath(path, content.length));
    scanBlob(path, content, denylist);
  }
}

function revList(args, root) {
  return git(['rev-list', '--reverse', ...args], { cwd: root }).split('\n').filter(Boolean);
}

function readStdin() {
  try { return readFileSync(0, 'utf8'); } catch { return ''; }
}

// --- Claude Code hooks ------------------------------------------------------

function block(message) {
  console.error(message);
  process.exit(2);
}

// Returns the repo root if `file` is inside a repository and not gitignored.
function trackedTarget(file) {
  const abs = resolve(file);
  let dir = dirname(abs);
  while (!existsSync(dir)) dir = dirname(dir);
  let root;
  try { root = realpathSync(repoRoot(dir)); } catch { return null; }
  const rel = relative(root, join(realpathSync(dir), relative(dir, abs)));
  if (!rel || rel.startsWith('..') || rel.split(sep)[0] === '.git') return null;
  try {
    // Tracked files are never reported as ignored, so they are always scanned
    git(['check-ignore', '-q', rel], { cwd: root, stdio: 'ignore' });
    return null; // ignored
  } catch {
    return { root, rel };
  }
}

function claudeWriteHook() {
  let input;
  try { input = JSON.parse(readStdin()); } catch { block('leak-guard: could not parse hook input'); }
  const t = input.tool_input || {};
  const file = t.file_path || t.notebook_path;
  if (!file) process.exit(0);
  const target = trackedTarget(file);
  if (!target) process.exit(0);

  const texts = [t.content, t.new_string, t.new_source, ...(t.edits || []).map((e) => e.new_string)].filter((x) => typeof x === 'string');
  const { entries } = loadDenylist(target.root);
  record(target.rel, checkPath(target.rel));
  for (const text of texts) record(target.rel, scanText(text, { denylist: entries }));
  if (findings.length) {
    report('Claude Code edit');
    block(`Blocked: this ${input.tool_name || 'edit'} would put secrets or personal data into ${target.rel}.`);
  }
  process.exit(0);
}

function claudeBashHook() {
  let input;
  try { input = JSON.parse(readStdin()); } catch { block('leak-guard: could not parse hook input'); }
  const command = input.tool_input?.command || '';
  const violations = checkBashCommand(command);
  if (violations.length) {
    block(`Blocked by leak-guard (${violations.join(', ')}): hooks bypasses, force pushes, hooksPath changes, history rewrites, and guard overrides must be run by a human.`);
  }
  process.exit(0);
}

// --- Main -------------------------------------------------------------------

const [mode, arg] = process.argv.slice(2);
if (mode === '--claude-hook') claudeWriteHook();
if (mode === '--claude-bash') claudeBashHook();

const root = repoRoot();
const { entries: denylist } = loadDenylist(root);

switch (mode) {
  case '--staged':
    scanStaged(root, denylist);
    finish('staged changes');
    break;

  case '--commit-msg':
    record('commit message', scanText(readFileSync(arg, 'utf8'), { denylist }));
    finish('commit message');
    break;

  case '--pre-push': {
    const refusals = [];
    for (const line of readStdin().split('\n').filter(Boolean)) {
      const [, localSha, remoteRef, remoteSha] = line.split(' ');
      if (ZERO.test(localSha)) {
        if (remoteRef === PROTECTED_BRANCH) refusals.push(`deleting ${remoteRef}`);
        continue;
      }
      if (remoteRef === PROTECTED_BRANCH && !ZERO.test(remoteSha)) {
        let ancestor = false;
        try { git(['merge-base', '--is-ancestor', remoteSha, localSha], { cwd: root, stdio: 'ignore' }); ancestor = true; } catch {}
        if (!ancestor) refusals.push(`non-fast-forward push to ${remoteRef}`);
      }
      const range = ZERO.test(remoteSha) ? [localSha, '--not', '--remotes'] : [`${remoteSha}..${localSha}`];
      for (const sha of revList(range, root)) scanCommit(sha, denylist, root);
    }
    if (refusals.length) {
      console.error(`\n✋ leak-guard: refusing ${refusals.join(', ')}. Rewriting published history needs a human.\n`);
      process.exit(1);
    }
    finish('outgoing commits');
    break;
  }

  case '--range': {
    const shas = arg === 'all' ? revList(['--all'], root) : revList([arg], root);
    for (const sha of shas) scanCommit(sha, denylist, root);
    console.error(`leak-guard: scanned ${shas.length} commit(s)`);
    finish(`range ${arg}`);
    break;
  }

  case '--tree':
    scanTree(root, denylist);
    finish('tree');
    break;

  default:
    console.error('usage: scan.mjs --staged | --commit-msg <file> | --pre-push | --range <a..b|all> | --tree | --claude-hook | --claude-bash');
    process.exit(64);
}
