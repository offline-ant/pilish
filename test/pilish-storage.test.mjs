// SPDX-License-Identifier: GPL-3.0-or-later
import assert from 'node:assert/strict';
import { test } from 'node:test';
import * as fs from 'node:fs';
import * as path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import { storageRuntime, mutateSession } from '../scripts/pilish-storage.mjs';

const PIMUX = process.env.PILISH_TEST_PIMUX;
assert.ok(PIMUX && path.isAbsolute(PIMUX), 'Set PILISH_TEST_PIMUX to the explicit compiled pimux executable');
const PI = process.env.PILISH_TEST_PI;
assert.ok(PI && path.isAbsolute(PI), 'Set PILISH_TEST_PI to the absolute Pi executable');
const runtime = storageRuntime(PIMUX);
const require = createRequire(fs.realpathSync(PIMUX));
const { createClaimTestEnvironment, acquireClaim, releaseClaim, lookupClaim } = runtime.ownership;
const helper = fileURLToPath(new URL('../scripts/pilish-storage.mjs', import.meta.url));
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const identity = runtime.identity.readProcessIdentity(process.pid);

function fixture(t) {
  const isolation = createClaimTestEnvironment();
  t.after(() => fs.rmSync(isolation.root, { recursive: true, force: true }));
  const home = path.join(isolation.root, 'home');
  const agent = path.join(isolation.root, 'agent');
  fs.mkdirSync(home, { mode: 0o700 });
  fs.mkdirSync(agent, { mode: 0o700 });
  const file = path.join(isolation.sessions, 'conversation.jsonl');
  const header = { type: 'session', version: 3, id: randomUUID(), timestamp: new Date().toISOString(), cwd: isolation.sessions };
  fs.writeFileSync(file, `${JSON.stringify(header)}\n${JSON.stringify({ type: 'message', id: 'first', parentId: null, timestamp: new Date().toISOString(), message: { role: 'user', content: 'Hello from a synthetic saved conversation', timestamp: Date.now() } })}\n`);
  const env = { PATH: process.env.PATH, HOME: home, XDG_DATA_HOME: path.join(home, 'data'),
    PI_CODING_AGENT_DIR: agent, PI_CODING_AGENT_SESSION_DIR: isolation.sessions, ...isolation.env };
  return { ...isolation, file, env };
}

function child(request, env) {
  return new Promise((resolve, reject) => {
    const process = spawn(globalThis.process.execPath, [helper, PIMUX], { env, stdio: ['pipe', 'pipe', 'pipe'] });
    let output = '';
    let stderr = '';
    process.stdout.setEncoding('utf8').on('data', text => { output += text; });
    process.stderr.setEncoding('utf8').on('data', text => { stderr += text; });
    process.on('error', reject);
    process.on('close', code => {
      try { resolve({ code, response: JSON.parse(output), stderr }); }
      catch { reject(new Error(`Invalid helper output: ${output}; ${stderr}`)); }
    });
    process.stdin.end(JSON.stringify(request));
  });
}

function hold(input, file = input.file, kind = 'rpc') {
  return acquireClaim(file, { id: randomUUID(), kind, wrapper: identity, pi: null, protocol: 2 }, input.options);
}

test('helper resolves only the explicit compiled public package and refuses relative paths', () => {
  assert.throws(() => storageRuntime('pimux'), /absolute/);
  assert.equal(require('@phimacs/pimux/protocol').PROTOCOL_VERSION, 2);
});

test('append holds a stopped-file lease, preserves missing newline and parents the fresh physical tail', async t => {
  const input = fixture(t);
  fs.appendFileSync(input.file, '{"type":"custom","id":"trailing","parentId":"first"}\nmalformed');
  const result = await child({ action: 'append', file: input.file, type: 'session_info', payload: { name: '  Test\nname  ' } }, input.env);
  assert.equal(result.code, 0, result.response.error);
  const bytes = fs.readFileSync(input.file, 'utf8');
  assert.match(bytes, /malformed\n\{"type":"session_info"/);
  const entry = JSON.parse(bytes.trim().split('\n').at(-1));
  assert.equal(entry.parentId, 'trailing');
  assert.equal(entry.name, 'Test name');
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('label clear omits label and rejects vanished targets without creating a file', async t => {
  const input = fixture(t);
  const result = await child({ action: 'append', file: input.file, type: 'label', payload: { targetId: 'first' } }, input.env);
  assert.equal(result.code, 0, result.response.error);
  const entry = JSON.parse(fs.readFileSync(input.file, 'utf8').trim().split('\n').at(-1));
  assert.equal(entry.type, 'label');
  assert.equal(Object.hasOwn(entry, 'label'), false);
  const before = fs.readFileSync(input.file);
  const missing = await child({ action: 'append', file: input.file, type: 'label', payload: { targetId: 'gone', label: 'No' } }, input.env);
  assert.equal(missing.code, 1);
  assert.match(missing.response.error, /no longer exists/);
  assert.deepEqual(fs.readFileSync(input.file), before);
  const absent = path.join(input.sessions, 'absent.jsonl');
  const create = await child({ action: 'append', file: absent, type: 'session_info', payload: { name: 'No create' } }, input.env);
  assert.equal(create.code, 1);
  assert.equal(fs.existsSync(absent), false);
});

test('active and uncertain launcher claims refuse append, rewrite and delete across process/aliases', async t => {
  const input = fixture(t);
  const symlink = path.join(input.sessions, 'symbolic.jsonl');
  const hardlink = path.join(input.sessions, 'hard.jsonl');
  fs.symlinkSync(input.file, symlink);
  fs.linkSync(input.file, hardlink);
  const before = fs.readFileSync(input.file);
  for (const kind of ['rpc', 'tui', 'lease']) {
    const claim = hold(input, input.file, kind);
    try {
      for (const file of [input.file, symlink, hardlink]) {
        for (const request of [
          { action: 'append', type: 'session_info', payload: { name: 'Must refuse' } },
          { action: 'rewrite', expectedSha256: digest(before), contents: before.toString('base64') },
          { action: 'delete', trash: false },
        ]) {
          const result = await child({ ...request, file }, input.env);
          assert.equal(result.code, 1);
          assert.match(result.response.error, /Session is owned/);
          assert.deepEqual(fs.readFileSync(input.file), before);
          assert.ok(fs.existsSync(file));
        }
      }
    } finally { releaseClaim(claim); }
  }
});

test('a real managed launcher cannot open a file while a stopped mutation holds its lease', async t => {
  const input = fixture(t);
  let blocked;
  const interleaved = { ...runtime, ownership: { ...runtime.ownership,
    acquireClaim(...args) {
      const claim = runtime.ownership.acquireClaim(...args);
      blocked = spawnSync(PIMUX, ['start', '--json', '--', PI, '--mode', 'rpc', '--session', input.file,
        '--no-extensions', '--no-skills', '--no-prompt-templates'],
      { env: input.env, encoding: 'utf8', timeout: 30_000 });
      return claim;
    },
  } };
  const result = await mutateSession(interleaved, { action: 'append', file: input.file,
    type: 'session_info', payload: { name: 'Lease excludes launch' } }, input.env);
  assert.equal(result.committed, true);
  assert.notEqual(blocked.status, 0);
  assert.match(`${blocked.stdout}${blocked.stderr}`, /nonattachable lease/);
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('same canonical path with a live Pi identity remains unavailable after wrapper death', async t => {
  const input = fixture(t);
  const dead = { ...identity, startTime: `${BigInt(identity.startTime) + 1n}` };
  const claim = acquireClaim(input.file, { id: randomUUID(), kind: 'rpc', wrapper: dead, pi: identity, protocol: 2 }, input.options);
  try {
    const result = await child({ action: 'delete', file: input.file, trash: false }, input.env);
    assert.equal(result.code, 1);
    assert.match(result.response.error, /Session is owned/);
    assert.ok(fs.existsSync(input.file));
  } finally { releaseClaim(claim); }
});

test('digest-bound rewrites cannot lose a concurrently committed stopped-file change', async t => {
  const input = fixture(t);
  const original = fs.readFileSync(input.file);
  const one = Buffer.concat([original, Buffer.from('{"type":"session_info","id":"one","parentId":"first","name":"One"}\n')]);
  const two = Buffer.concat([original, Buffer.from('{"type":"session_info","id":"two","parentId":"first","name":"Two"}\n')]);
  const outcomes = await Promise.all([one, two].map(contents => child({ action: 'rewrite', file: input.file,
    expectedSha256: digest(original), contents: contents.toString('base64') }, input.env)));
  assert.equal(outcomes.filter(item => item.code === 0).length, 1);
  assert.equal(outcomes.filter(item => item.code === 1).length, 1);
  assert.match(outcomes.find(item => item.code === 1).response.error, /owned|changed/);
  const written = fs.readFileSync(input.file);
  assert.ok(written.equals(one) || written.equals(two));
  assert.equal(lookupClaim(input.file, input.options), undefined);
  assert.deepEqual(fs.readdirSync(input.sessions), ['conversation.jsonl']);
});

test('selected symlink deletion removes the alias but not the conversation target', async t => {
  const input = fixture(t);
  const alias = path.join(input.sessions, 'alias.jsonl');
  fs.symlinkSync(input.file, alias);
  const result = await child({ action: 'delete', file: alias, expectedCanonical: input.file, trash: false }, input.env);
  assert.equal(result.code, 0, result.response.error);
  assert.equal(fs.existsSync(alias), false);
  assert.equal(fs.existsSync(input.file), true);
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('retargeted confirmation refuses before deletion and releases only its own lease', async t => {
  const input = fixture(t);
  const other = path.join(input.sessions, 'other.jsonl');
  fs.copyFileSync(input.file, other);
  for (const request of [
    { action: 'delete', trash: false },
    { action: 'append', type: 'session_info', payload: { name: 'Wrong file' } },
  ]) {
    const result = await child({ ...request, file: other, expectedCanonical: input.file }, input.env);
    assert.equal(result.code, 1);
    assert.match(result.response.error, /pathname changed/);
    assert.deepEqual(fs.readFileSync(other), fs.readFileSync(input.file));
  }
  assert.ok(fs.existsSync(other));
  assert.equal(lookupClaim(other, input.options), undefined);
});

test('unsupported actions/entry fields refuse without touching storage or executing commands', async t => {
  const input = fixture(t);
  const before = fs.readFileSync(input.file);
  for (const request of [
    { action: 'exec', file: input.file, command: 'false' },
    { action: 'append', file: input.file, type: 'message', payload: {} },
    { action: 'append', file: input.file, type: 'label', payload: { targetId: 'first', id: 'first' } },
    { action: 'rewrite', file: input.file, contents: 'eA==', expectedSha256: 'bad' },
  ]) await assert.rejects(mutateSession(runtime, request, input.env), /Unsupported|Only|Rewrite/);
  assert.deepEqual(fs.readFileSync(input.file), before);
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('test claims cannot authorize an ordinary temporary or production-path conversation', async t => {
  const input = fixture(t);
  const external = path.join(input.root, 'outside-sessions.jsonl');
  fs.copyFileSync(input.file, external);
  await assert.rejects(mutateSession(runtime, { action: 'delete', file: external, trash: false }, input.env), /Synthetic|synthetic/);
  assert.ok(fs.existsSync(external));
});

test('managed export never opens a live claimed input and never overwrites existing outputs', async t => {
  const input = fixture(t);
  const output = path.join(input.root, 'export.html');
  const claim = hold(input);
  try {
    const result = await child({ action: 'export', file: input.file, output, piExecutable: PI }, input.env);
    assert.equal(result.code, 1);
    assert.match(result.response.error, /owned/);
    assert.equal(fs.existsSync(output), false);
  } finally { releaseClaim(claim); }
  fs.writeFileSync(output, 'Existing artifact');
  const existing = await child({ action: 'export', file: input.file, output, piExecutable: PI }, input.env);
  assert.equal(existing.code, 1);
  assert.equal(fs.readFileSync(output, 'utf8'), 'Existing artifact');
});

test('stopped export runs the managed launcher with a synthetic home and no provider calls', async t => {
  const input = fixture(t);
  const output = path.join(input.root, 'export.html');
  const result = await child({ action: 'export', file: input.file, output, piExecutable: PI }, input.env);
  assert.equal(result.code, 0, result.response.error);
  const encoded = fs.readFileSync(output, 'utf8').match(/<script id="session-data" type="application\/json">([^<]+)<\/script>/)?.[1];
  assert.ok(encoded, 'export contains the encoded authoritative session');
  assert.match(Buffer.from(encoded, 'base64').toString('utf8'), /Hello from a synthetic saved conversation/);
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('real Emacs storage wrapper exchanges one JSON receipt with the leased helper', t => {
  const input = fixture(t);
  const source = path.dirname(fileURLToPath(new URL('../pilish-storage.el', import.meta.url)));
  const expression = `(progn (setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil) (require 'pilish-storage) (defalias 'pilish-runtime-configured-p (lambda () t)) (setq pilish-runtime-pimux-executable ${JSON.stringify(PIMUX)}) (let ((receipt (pilish-storage-append-entry ${JSON.stringify(input.file)} "session_info" '(:name "From Emacs")))) (unless (plist-get receipt :committed) (error "Missing committed receipt")) (princ (plist-get receipt :operationId))))`;
  const result = spawnSync('emacs', ['-Q', '--batch', '-L', source, '--eval', expression], { env: input.env, encoding: 'utf8', timeout: 30_000 });
  assert.equal(result.status, 0, result.stderr);
  assert.match(result.stdout, /^[a-f0-9-]{36}$/);
  assert.match(fs.readFileSync(input.file, 'utf8'), /From Emacs/);
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('a trash writer surviving helper death retains its claim until actual writer exit', async t => {
  const input = fixture(t);
  const bin = path.join(input.root, 'bin');
  const ready = path.join(input.root, 'trash-ready');
  fs.mkdirSync(bin, { mode: 0o700 });
  fs.writeFileSync(path.join(bin, 'gio'), `#!${process.execPath}\nconst fs = require('node:fs');\nprocess.on('SIGUSR1', () => { fs.unlinkSync(process.argv.at(-1)); process.exit(0); });\nfs.writeFileSync(${JSON.stringify(ready)}, 'ready');\nsetInterval(() => {}, 1000);\n`, { mode: 0o700 });
  const owner = spawn(process.execPath, [helper, PIMUX], { env: { ...input.env, PATH: `${bin}:${input.env.PATH}` }, stdio: ['pipe', 'pipe', 'pipe'] });
  let writer;
  const exited = new Promise(resolve => owner.once('close', resolve));
  t.after(async () => {
    if (owner.exitCode === null && owner.signalCode === null) owner.kill('SIGKILL');
    if (writer && runtime.identity.processIdentityStatus(writer) === 'alive') process.kill(writer.pid, 'SIGKILL');
    await exited;
  });
  owner.stdin.end(JSON.stringify({ action: 'delete', file: input.file, trash: true }));
  const deadline = performance.now() + 10_000;
  while (performance.now() < deadline) {
    writer = lookupClaim(input.file, input.options)?.owner.pi;
    if (writer && fs.existsSync(ready)) break;
    await delay(20);
  }
  assert.ok(writer && fs.existsSync(ready), 'auxiliary writer reached the leased operation');
  owner.kill('SIGKILL');
  await exited;
  const refused = await child({ action: 'append', file: input.file, type: 'session_info', payload: { name: 'Must not race trash' } }, input.env);
  assert.equal(refused.code, 1);
  assert.match(refused.response.error, /owned/);
  assert.equal(runtime.identity.processIdentityStatus(writer), 'alive');
  process.kill(writer.pid, 'SIGUSR1');
  while (performance.now() < deadline && runtime.identity.processIdentityStatus(writer) === 'alive') await delay(20);
  assert.notEqual(runtime.identity.processIdentityStatus(writer), 'alive');
  assert.equal(lookupClaim(input.file, input.options), undefined);
});

test('trash honors the confirmed policy in a synthetic XDG home, without permanent fallback', async t => {
  const input = fixture(t);
  if (spawnSync('gio', ['version'], { env: input.env }).error) { t.skip('optional gio trash utility is unavailable'); return; }
  const result = await child({ action: 'delete', file: input.file, trash: true }, input.env);
  assert.equal(result.code, 0, result.response.error);
  assert.equal(fs.existsSync(input.file), false);
  const trash = path.join(input.env.XDG_DATA_HOME, 'Trash');
  assert.equal(fs.readdirSync(path.join(trash, 'files')).length, 1);
  assert.equal(fs.readdirSync(path.join(trash, 'info')).length, 1);
  assert.equal(lookupClaim(input.file, input.options), undefined);
});
