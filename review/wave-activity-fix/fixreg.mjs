import fs from 'node:fs';
const p = process.argv[2], repo = process.argv[3];
const r = JSON.parse(fs.readFileSync(p, 'utf8'));
r.repo = repo;
fs.writeFileSync(p, JSON.stringify(r, null, 1) + '\n');
console.log('copy registration.repo ->', r.repo);
