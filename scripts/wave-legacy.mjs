#!/usr/bin/env node
// No bulk reaper. Each supplied independent signed bundle is checked by the
// native bridge; missing identity/provenance remains explicit and preserved.
import fs from 'node:fs';import path from 'node:path';import {fileURLToPath} from 'node:url';import {native} from './wave-adapter.mjs';
if(process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  try {
    const [configFile,bundleFile]=process.argv.slice(2),config=JSON.parse(fs.readFileSync(configFile,'utf8')),bundle=JSON.parse(fs.readFileSync(bundleFile,'utf8'));
    const result=native(config,{kind:'legacy',bundle});
    console.log(JSON.stringify(result));if(result.allocation_safe!==true)process.exitCode=1;
  }catch(e){console.log(JSON.stringify({allocation_safe:false,original_execution_outcome:'unknown',reason:e.message}));process.exitCode=1;}
}
