#!/usr/bin/env node
import fs from 'node:fs';
import {nativeTrace,piTrace,preparedRequests} from './agent-benchmark-telemetry.mjs';
const mode=process.argv[2],file=process.argv[3];
if(!['native','pi','prepared'].includes(mode))throw Error('usage: agent-benchmark-observe.mjs <native|pi|prepared> <private-file|->');
const raw=fs.readFileSync(file==='-'?0:file,'utf8');
const result=mode==='pi'?piTrace(raw):mode==='native'?nativeTrace(JSON.parse(raw)):preparedRequests(JSON.parse(raw));
console.log(JSON.stringify(result,null,2));
