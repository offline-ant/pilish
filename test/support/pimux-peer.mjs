#!/usr/bin/env node
/** Synthetic independent socket frontend for the native integration lane. */
import net from 'node:net';

const [socketPath, commandJson, waitForRun] = process.argv.slice(2);
const command = JSON.parse(commandJson);
const socket = net.connect(socketPath);
socket.setEncoding('utf8');
let remainder = '', hello, snapshot, response, settled = false, sent = false, finished = false;
const timer = setTimeout(() => finish(new Error('peer deadline')), 30000);

function finish(error) {
  if (finished) return;
  finished = true;
  clearTimeout(timer);
  socket.destroy();
  if (error) {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  } else process.stdout.write(JSON.stringify({ hello, snapshot, response }) + '\n');
}

socket.on('error', finish);
socket.on('end', () => finish(new Error('peer ended before command acknowledgement')));
socket.on('data', chunk => {
  remainder += chunk;
  let end;
  while (!finished && (end = remainder.indexOf('\n')) >= 0) {
    const line = remainder.slice(0, end);
    remainder = remainder.slice(end + 1);
    if (!line) continue;
    let record;
    try { record = JSON.parse(line); } catch { return finish(new Error('malformed peer record')); }
    if (record.type === 'pimux_hello') {
      if (record.protocol !== 2 || !record.capabilities?.includes('contextual-input')) {
        return finish(new Error('contextual protocol required'));
      }
      hello = record;
    }
    if (record.type === 'pimux_snapshot') snapshot = record;
    if (record.type === 'pimux_live' && !sent && hello && record.generation === snapshot?.generation) {
      // Capture this exact branch anchor once. A later snapshot cannot retarget
      // the action or turn a rejected command into an automatic retry.
      const context = snapshot.inputContext;
      if (!context || typeof context.contextId !== 'string') return finish(new Error('input context unavailable'));
      sent = true;
      socket.write(JSON.stringify({ ...command, pimuxContext: context, id: 'independent-peer' }) + '\n');
    }
    if (record.type === 'pimux_snapshot_failed') return finish(new Error('peer snapshot failed'));
    if (record.type === 'agent_settled') settled = true;
    if (record.type === 'response' && record.id === 'independent-peer') response = record;
    if (response && (response.success === false || !waitForRun || settled)) return finish();
  }
});
