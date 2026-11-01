#!/usr/bin/env node
// SPDX-License-Identifier: GPL-3.0-or-later
// Narrow stopped-session mutations. No arbitrary command or raw Pi-open endpoint.
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createHash, randomBytes, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const MAX_REQUEST_BYTES = 128 * 1024 * 1024;
const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);

function absolute(value, name) {
  if (typeof value !== 'string' || !path.isAbsolute(value) || value.includes('\0')) throw new Error(`${name} must be an absolute local path`);
  return value;
}

/** Resolve the configured, compiled package, never a sibling source or NODE_PATH. */
export function storageRuntime(pimuxExecutable) {
  if (Number(process.versions.node.split('.')[0]) < 24) throw new Error('Managed storage requires Node 24');
  absolute(pimuxExecutable, 'pimux executable');
  const executable = fs.realpathSync.native(pimuxExecutable);
  fs.accessSync(executable, fs.constants.R_OK | fs.constants.X_OK);
  const require = createRequire(executable);
  if (require('@phimacs/pimux/package.json').name !== '@phimacs/pimux'
      || require('@phimacs/pimux/protocol').PROTOCOL_VERSION !== 2) throw new Error('Storage requires the configured protocol-2 pimux package');
  return { executable, ownership: require('@phimacs/pimux/ownership'), identity: require('@phimacs/pimux/process-identity') };
}

function validate(request) {
  if (!record(request)) throw new Error('Storage request must be an object');
  if (!['append', 'delete', 'rewrite', 'export'].includes(request.action)) throw new Error('Unsupported storage action');
  absolute(request.file, 'session file');
  if (request.action === 'append') {
    if (!['session_info', 'label'].includes(request.type) || !record(request.payload)) throw new Error('Only session_info and label entries can be appended');
    const allowed = request.type === 'session_info' ? ['name'] : ['targetId', 'label'];
    if (Object.keys(request.payload).some(key => !allowed.includes(key))) throw new Error('Unsupported entry field');
    if (request.type === 'session_info' && (typeof request.payload.name !== 'string' || !request.payload.name.trim())) throw new Error('Session name cannot be empty');
    if (request.type === 'label' && (typeof request.payload.targetId !== 'string' || !request.payload.targetId)) throw new Error('A label needs a target entry');
    if (request.payload.label !== undefined && typeof request.payload.label !== 'string') throw new Error('A label must be text or absent');
  } else if (request.action === 'rewrite') {
    if (!/^[a-f0-9]{64}$/.test(request.expectedSha256 ?? '') || typeof request.contents !== 'string'
        || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(request.contents)) throw new Error('Rewrite needs the original SHA-256 and base64 bytes');
  } else if (request.action === 'delete') {
    if (request.trash !== undefined && typeof request.trash !== 'boolean') throw new Error('Invalid trash policy');
  } else {
    absolute(request.piExecutable, 'Pi executable');
    absolute(request.output, 'export output');
    if (!request.output.endsWith('.html')) throw new Error('Managed exports require a new .html output file');
  }
  if (request.expectedCanonical !== undefined) absolute(request.expectedCanonical, 'expected session identity');
}

function matchingPath(runtime, claim, requested) {
  runtime.ownership.reconcileClaim(claim);
  if (runtime.ownership.canonicalSessionPath(requested) !== claim.file) throw new Error('Selected session pathname changed during the operation');
}

function append(runtime, claim, request) {
  // O_APPEND without O_CREAT: an unpersisted session must never be created here.
  const fd = fs.openSync(claim.file, fs.constants.O_RDWR | fs.constants.O_APPEND | fs.constants.O_NOFOLLOW);
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile()) throw new Error('Session must be a regular file');
    const original = fs.readFileSync(fd);
    const text = original.toString('utf8');
    const ids = new Set([...text.matchAll(/"id"\s*:\s*"([^"\r\n]+)"/g)].map(match => match[1]));
    let parentId = null;
    let header = false;
    const entries = [];
    for (const line of text.split('\n')) {
      let entry;
      try { entry = JSON.parse(line); } catch { continue; }
      if (!record(entry)) continue;
      if (!header) {
        if (entry.type !== 'session') throw new Error('Not a Pi session file');
        header = true;
      } else entries.push(entry);
    }
    if (!header) throw new Error('Not a Pi session file');
    if (entries.length) parentId = typeof entries.at(-1).id === 'string' ? entries.at(-1).id : null;
    if (request.type === 'label' && !ids.has(request.payload.targetId)) throw new Error('Label target no longer exists; refresh the tree');
    let id;
    for (let attempt = 0; attempt < 100; attempt++) {
      id = randomBytes(4).toString('hex');
      if (!ids.has(id)) break;
      id = undefined;
    }
    if (!id) {
      do { id = randomUUID().replaceAll('-', ''); } while (ids.has(id));
    }
    const payload = request.type === 'session_info'
      ? { name: request.payload.name.replace(/[\r\n]+/g, ' ').trim() } : request.payload;
    const line = JSON.stringify({ type: request.type, id, parentId, timestamp: new Date().toISOString(), ...payload });
    matchingPath(runtime, claim, request.file);
    const current = fs.statSync(claim.file);
    if (current.dev !== stat.dev || current.ino !== stat.ino) throw new Error('Session was replaced before append');
    fs.writeFileSync(fd, `${original.length && original.at(-1) !== 10 ? '\n' : ''}${line}\n`, 'utf8');
    return { entryId: id };
  } finally { fs.closeSync(fd); }
}

function rewrite(runtime, claim, request) {
  const original = fs.readFileSync(claim.file);
  if (sha256(original) !== request.expectedSha256) throw new Error('Session changed before rewrite; refresh and try the action explicitly');
  const contents = Buffer.from(request.contents, 'base64');
  const temporary = path.join(path.dirname(claim.file), `.pi-nav-${randomUUID()}`);
  let swapped = false;
  try {
    const fd = fs.openSync(temporary, 'wx', fs.statSync(claim.file).mode & 0o777);
    try { fs.writeFileSync(fd, contents); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
    matchingPath(runtime, claim, request.file);
    // The digest is checked again at the commit boundary, not only at acquisition.
    if (sha256(fs.readFileSync(claim.file)) !== request.expectedSha256) throw new Error('Session changed before rewrite commit');
    fs.renameSync(temporary, claim.file);
    swapped = true;
    runtime.ownership.reconcileClaim(claim);
    return {};
  } finally { if (!swapped) fs.rmSync(temporary, { force: true }); }
}

async function remove(runtime, claim, request, env) {
  matchingPath(runtime, claim, request.file);
  if (!request.trash) { fs.unlinkSync(request.file); return {}; }
  // Keep the selected symlink itself as the target, as Emacs delete-file does.
  // Record the auxiliary writer, so helper death cannot release a live trash move.
  // No permanent-delete fallback when this optional utility is unavailable.
  await new Promise((resolve, reject) => {
    const child = spawn('gio', ['trash', '--', request.file],
      { env: { ...env, GIO_USE_VFS: 'local' }, stdio: ['ignore', 'ignore', 'pipe'] });
    let stderr = '';
    let failure;
    let writer;
    let escalation;
    const terminate = signal => {
      if (writer && runtime.identity.processIdentityStatus(writer) === 'alive') child.kill(signal);
    };
    const timeout = setTimeout(() => {
      failure = new Error('Trash timed out; no permanent-delete fallback was attempted');
      terminate('SIGTERM');
      escalation = setTimeout(() => terminate('SIGKILL'), 1000);
    }, 30_000);
    child.stderr.setEncoding('utf8').on('data', text => { stderr = (stderr + text).slice(-16 * 1024); });
    child.once('spawn', () => {
      try {
        writer = runtime.identity.readProcessIdentity(child.pid);
        if (writer) runtime.ownership.updateClaim(claim, { ...claim.owner, pi: writer });
      } catch (error) { failure = error; child.kill('SIGTERM'); }
    });
    child.once('error', error => { failure = error; });
    child.once('close', code => {
      clearTimeout(timeout);
      if (escalation) clearTimeout(escalation);
      if (failure || code !== 0) reject(new Error(`Could not move session to trash: ${failure?.message ?? stderr.trim()}`));
      else resolve();
    });
  });
  return {};
}

function exportSession(runtime, request, env) {
  const canonical = runtime.ownership.canonicalSessionPath(request.file);
  if (request.expectedCanonical && canonical !== request.expectedCanonical) throw new Error('Selected session pathname changed before export');
  if (runtime.ownership.canonicalSessionPath(request.output) === canonical) throw new Error('Export output must not replace its session');
  // Never overwrite another artifact or a session via an existing output alias.
  const fd = fs.openSync(request.output, 'wx', 0o600);
  const reservation = fs.fstatSync(fd);
  fs.closeSync(fd);
  const result = spawnSync(runtime.executable, ['tui', '--', request.piExecutable,
    '--no-extensions', '--no-skills', '--no-prompt-templates', '--export', canonical, request.output],
  { env, encoding: 'utf8', timeout: 60_000, maxBuffer: 1024 * 1024 });
  if (result.error || result.status !== 0) {
    // Retain nonempty/changed partial output; never erase uncertain newer data.
    const stat = fs.statSync(request.output, { throwIfNoEntry: false });
    if (stat?.ino === reservation.ino && stat.dev === reservation.dev && stat.size === 0) fs.unlinkSync(request.output);
    throw new Error(`Managed export failed: ${result.error?.message ?? result.stderr.trim() ?? 'launcher exited unsuccessfully'}`);
  }
  return { output: request.output };
}

/** All mutation IO runs inside the common claim; no raw helper Pi open. */
export async function mutateSession(runtime, request, env = process.env) {
  validate(request);
  const operationId = randomUUID();
  if (request.action === 'export') return { operationId, committed: true, ...exportSession(runtime, request, env) };
  const wrapper = runtime.identity.readProcessIdentity(process.pid);
  if (!wrapper) throw new Error('Cannot establish storage helper identity');
  const options = env.PHIMACS_TEST_ROOT ? { testRoot: env.PHIMACS_TEST_ROOT } : {};
  const claim = runtime.ownership.acquireClaim(request.file, { id: operationId, kind: 'lease', wrapper, pi: null }, options);
  let committed = false;
  try {
    if (request.expectedCanonical && request.expectedCanonical !== claim.file) throw new Error('Selected session pathname changed before mutation');
    const result = request.action === 'append' ? append(runtime, claim, request)
      : request.action === 'rewrite' ? rewrite(runtime, claim, request) : await remove(runtime, claim, request, env);
    committed = true;
    return { operationId, committed, ...result };
  } finally {
    try { runtime.ownership.releaseClaim(claim); }
    catch (error) {
      throw new Error(`Storage operation ${operationId} ${committed ? 'committed but release is uncertain; do not repeat it' : 'failed and its lease is uncertain'}: ${error.message}`);
    }
  }
}

function readRequest() {
  const chunks = [];
  const buffer = Buffer.alloc(64 * 1024);
  let size = 0;
  for (;;) {
    const count = fs.readSync(0, buffer, 0, buffer.length, null);
    if (!count) break;
    size += count;
    if (size > MAX_REQUEST_BYTES) throw new Error('Storage request exceeds its size limit');
    chunks.push(Buffer.from(buffer.subarray(0, count)));
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function main() {
  if (process.argv.length !== 3) throw new Error('Usage: node pilish-storage.mjs /absolute/pimux');
  const request = readRequest();
  validate(request);
  const result = await mutateSession(storageRuntime(process.argv[2]), request);
  process.stdout.write(`${JSON.stringify({ ok: true, ...result })}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch(error => {
    process.stdout.write(`${JSON.stringify({ ok: false, error: error.message })}\n`);
    process.exitCode = 1;
  });
}
