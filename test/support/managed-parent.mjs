#!/usr/bin/env node
// Real Workers + detached faux Pi. An optional endpoint uses the actual Emacs
// companion; without it, only the disposable native UI is a test seam.
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import fs from 'node:fs';
import net from 'node:net';
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

const [directory, outcome, endpoint] = process.argv.slice(2);
const execute = promisify(execFile);
const source = process.env.PHIMACS_ORCHESTRATION_ROOT;
assert.ok(source && path.isAbsolute(source), 'Explicit compiled orchestration root required');
assert.ok(directory?.startsWith(`${process.env.PHIMACS_TEST_ROOT}/`), 'Synthetic test directory required');
assert.ok(['complete', 'failed'].includes(outcome), 'Expected cleanup outcome required');
if (endpoint) {
  assert.ok(endpoint.startsWith(`${process.env.PHIMACS_TEST_ROOT}/`), 'Test-owned Emacs endpoint required');
  assert.equal(outcome, 'complete', 'Real companion regression uses successful cleanup');
}
for (const name of ['tmp', 'home', 'agent', 'mux']) fs.mkdirSync(path.join(directory, name), { mode: 0o700 });
Object.assign(process.env, {
  TMPDIR: path.join(directory, 'tmp'), HOME: path.join(directory, 'home'),
  PI_CODING_AGENT_DIR: path.join(directory, 'agent'),
  // The actual companion discovers in the test frontend's initial namespace.
  PIMUX_DIR: endpoint ? process.env.PIMUX_DIR : path.join(directory, 'mux'),
  PHIMACS_PI: process.env.PHIMACS_PI_EXECUTABLE, PHIMACS_PI_VERSION: '1.4.0', PHIMACS_PI_SHA256: '',
  PI_ORCHESTRATION_HOST: 'emacs', PI_ORCHESTRATION_ENDPOINT: endpoint || path.join(directory, 'ui.sock'),
  PI_ORCHESTRATION_TARGET: 'native-parent',
});
// Import after setting TMPDIR: Workers' registry and artifacts are process-local.
const owning = relative => import(pathToFileURL(path.join(source, relative)).href);
const { runEphemeralWorker, readTarget, removeTarget, tryClaimName } = await owning('packages/orchestration/dist/workers.js');
const { createWorkerArtifacts, writeWorkerRequest } = await owning('packages/orchestration/dist/worker-frame.js');
const { readWorkerTask } = await owning('packages/orchestration/dist/worker-task.js');
const { processIdentityStatus } = await owning('packages/pimux/dist/process-identity.js');
const { listRuntimes, stopRuntime } = await owning('packages/pimux/dist/runtime.js');
const { lookupClaim } = await owning('packages/pimux/dist/ownership.js');
const name = `pilish-native-${process.pid}`;
const artifacts = createWorkerArtifacts();
const sessionFile = path.join(process.env.PHIMACS_TEST_ROOT, 'sessions', `managed-${process.pid}.jsonl`);
const trace = path.join(directory, 'lifecycle-trace.jsonl');
const emit = (event, details = {}) => process.stdout.write(`${JSON.stringify({ event, ...details })}\n`);
const abort = new AbortController();
let target;
let openCleanup;
const cleanupGate = new Promise(resolve => { openCleanup = resolve; });
let publishReady;
const advertised = new Promise(resolve => { publishReady = resolve; });
const input = readline.createInterface({ input: process.stdin, terminal: false });
input.on('line', line => {
  if (line === 'release-cleanup') openCleanup();
  else if (line === 'cancel') abort.abort();
  else if (line === 'stop') { abort.abort(); openCleanup(); }
});
input.on('close', () => { abort.abort(); openCleanup(); });
const frontend = endpoint ? null : net.createServer(client => client.destroy());
if (frontend) await new Promise((resolve, reject) => {
  frontend.once('error', reject);
  frontend.listen(process.env.PI_ORCHESTRATION_ENDPOINT, resolve);
});

function snapshot() {
  const task = target ? readWorkerTask(target.runtime.muxId) : null;
  const release = tryClaimName(name);
  if (release) release();
  return {
    task, workerState: target ? processIdentityStatus(target.process) : null,
    leaseState: fs.existsSync(path.join(artifacts.artifactDir, 'parent-task.json'))
      ? JSON.parse(fs.readFileSync(path.join(artifacts.artifactDir, 'parent-task.json'), 'utf8')).state : null,
    registered: !!readTarget(name), nameClaimHeld: !release,
    sessionClaimHeld: !!lookupClaim(sessionFile),
  };
}

const pi = { exec: async (command, args, options = {}) => {
  const encoded = /pi-orchestration-dispatch "([A-Za-z0-9+/=]+)"/.exec(args.at(-1))?.[1];
  assert.ok(encoded, 'Only the owning Emacs native boundary is intercepted');
  const request = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8'));
  if (endpoint) {
    // Execute every operation through the real compiled host, emacsclient and
    // companion. The gate holds the *returned* cleanup acknowledgement, after
    // the actual Lisp close ran, before registry/name release and publication.
    if (request.operation === 'start') target = {
      host: 'emacs', endpoint, id: request.id, name, kind: 'pi', sessionFile,
      runtime: request.spec.runtime, process: request.spec.process,
    };
    const result = await execute(command, args, { signal: options.signal, timeout: options.timeout });
    if (request.operation === 'close') {
      assert.equal(request.taskOwned, true);
      const state = snapshot();
      assert.equal(state.workerState, 'dead');
      assert.equal(state.leaseState, 'ended');
      assert.equal(state.task?.state, 'pending');
      assert.equal(state.registered, true);
      assert.equal(state.nameClaimHeld, true);
      emit('cleanup-blocked', state);
      await cleanupGate;
    } else if (request.operation === 'task-finished') {
      const state = snapshot();
      assert.equal(state.task?.state, 'complete');
      assert.equal(state.registered, false);
      assert.equal(state.nameClaimHeld, false);
      emit('task-finished', state);
    }
    return { ...result, code: 0, killed: false };
  }
  let reply;
  if (request.operation === 'capabilities') reply = { protocol: 2, runtimeAttach: true };
  else if (request.operation === 'start') {
    target = { host: 'emacs', endpoint: process.env.PI_ORCHESTRATION_ENDPOINT,
      id: request.id, name, kind: 'pi', sessionFile,
      runtime: request.spec.runtime, process: request.spec.process };
    reply = { target: { id: request.id }, muxId: target.runtime.muxId };
  } else if (request.operation === 'state') reply = { ready: true, state: 'running', muxId: target.runtime.muxId };
  else if (request.operation === 'close') {
    const state = snapshot();
    assert.equal(request.taskOwned, true);
    assert.equal(state.workerState, 'dead');
    assert.equal(state.leaseState, 'ended');
    assert.equal(state.registered, true);
    assert.equal(state.nameClaimHeld, true);
    assert.ok(!state.task || state.task.state === 'pending');
    emit('cleanup-blocked', state);
    await cleanupGate;
    reply = outcome === 'failed' ? { error: 'native fixture host cleanup failed' } : { success: true };
  } else if (request.operation === 'task-finished') {
    const state = snapshot();
    assert.equal(state.workerState, 'dead');
    assert.equal(state.nameClaimHeld, false);
    assert.equal(state.leaseState, 'ended');
    // Missing evidence is intentionally exercised by the frontend test too.
    if (state.task) {
      assert.equal(state.task.state, outcome);
      assert.equal(state.registered, outcome === 'failed');
      if (outcome === 'failed') assert.match(state.task.error, /native fixture host cleanup failed/);
    }
    emit('task-finished', { ...state, error: request.error });
    reply = { success: true };
  } else throw new Error(`Unexpected native operation ${request.operation}`);
  return { code: 0, stdout: JSON.stringify(Buffer.from(JSON.stringify(reply)).toString('base64')), stderr: '', killed: false };
} };

// This watches real provider I/O, not a guessed startup delay.
async function waitForRequest() {
  await new Promise((resolve, reject) => {
    const watcher = fs.watch(directory, check);
    const timer = setTimeout(() => finish(new Error('Faux request did not arrive')), 20_000);
    function finish(error) { watcher.close(); clearTimeout(timer); error ? reject(error) : resolve(); }
    function check() {
      if (fs.existsSync(trace) && fs.readFileSync(trace, 'utf8').includes('"event":"request"')) finish();
    }
    check();
  });
}

let observed;
try {
  writeWorkerRequest(artifacts, { id: name, task: '[hold] Pilish worker Close', tools: [],
    model: { provider: 'orchestration-fixture', id: 'one' }, thinkingLevel: 'off',
    resultPath: artifacts.resultPath, statusPath: artifacts.statusPath });
  observed = runEphemeralWorker(pi, { id: name, name, cwd: directory, sessionFile, paths: artifacts,
    task: '[hold] Pilish worker Close', signal: abort.signal,
    args: ['--no-extensions', '--no-skills', '--no-context-files', '--no-prompt-templates',
      '--extension', path.join(source, 'packages/orchestration/test/lifecycle-fixture.ts'),
      '--extension', path.join(source, 'packages/orchestration/dist/worker-frame.js'),
      '--provider', 'orchestration-fixture', '--model', 'one', '--thinking', 'off'],
    onUpdate: () => publishReady(),
  }).then(result => ({ result }), error => ({ error: String(error) }));
  const early = await Promise.race([advertised.then(() => false), observed]);
  assert.equal(early, false, `Worker ended before advertisement: ${JSON.stringify(early)}`);
  await waitForRequest();
  assert.equal(snapshot().task?.state, 'pending');
  emit('ready', { runtime: target.runtime, ...snapshot(), directory, trace, artifacts });
  const settled = await observed;
  emit('settled', { ...snapshot(), error: settled.error });
} catch (error) {
  emit('fatal', { error: String(error), stack: error.stack });
  process.exitCode = 1;
} finally {
  abort.abort();
  openCleanup();
  if (observed) await observed;
  for (const runtime of listRuntimes(process.env)) await stopRuntime(runtime.muxId, { env: process.env });
  removeTarget(name);
  if (frontend) await new Promise(resolve => frontend.close(resolve));
  input.close();
}
