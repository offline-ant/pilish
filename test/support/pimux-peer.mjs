#!/usr/bin/env node
/** Synthetic independent socket frontend for the native integration lane. */
import net from 'node:net';
const [socketPath,commandJson,waitForRun]=process.argv.slice(2);
const command=JSON.parse(commandJson);
const socket=net.connect(socketPath);
let remainder='',hello,snapshot,response,settled=false,sent=false;
const timer=setTimeout(()=>finish(new Error('peer deadline')),30000);
function finish(error){clearTimeout(timer);socket.destroy();if(error){process.stderr.write(error.message+'\n');process.exitCode=1;}else process.stdout.write(JSON.stringify({hello,snapshot,response})+'\n');}
socket.on('error',finish);
socket.on('data',chunk=>{remainder+=chunk.toString('utf8');let end;while((end=remainder.indexOf('\n'))>=0){const line=remainder.slice(0,end);remainder=remainder.slice(end+1);if(!line)continue;const record=JSON.parse(line);if(record.type==='pimux_hello'){if(record.protocol!==2)return finish(new Error('protocol'));hello=record;}
if(record.type==='pimux_snapshot')snapshot=record;
if(record.type==='pimux_live'&&!sent){sent=true;socket.write(JSON.stringify({...command,id:'independent-peer'})+'\n');}
if(record.type==='agent_settled')settled=true;
if(record.type==='response'&&record.id==='independent-peer')response=record;
if(response&&(!waitForRun||settled))return finish();}});
