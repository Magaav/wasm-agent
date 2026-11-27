#!/usr/bin/env node
// The path policy: WHICH FILES A LANDING MAY NOT TAKE BY ITSELF, read from data in the repo.
//
// `policies/landing-policy.json` lists globs. A request whose diff touches one of them stops at
// `needs_review` and does not run until an approval names EXACTLY (branch, sha, policy-hash). A new sha
// voids an approval because the key includes the sha, not because somebody remembers to delete it - and a
// changed policy file voids every approval too, because the hash is of the file's bytes.
//
// Glob semantics are deliberately small and total: `**` crosses directories, `*` does not, `?` is one
// character. A policy that needed a real glob engine would be a policy whose behaviour depends on a
// library version, and this file has to answer the same way in five years.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

function globToRegExp(glob) {
  let out = '^';
  for (let i = 0; i < glob.length; i += 1) {
    const ch = glob[i];
    if (ch === '*' && glob[i + 1] === '*') { out += '.*'; i += 1; if (glob[i + 1] === '/') i += 1; continue; }
    if (ch === '*') { out += '[^/]*'; continue; }
    if (ch === '?') { out += '[^/]'; continue; }
    out += ch.replace(/[.+^${}()|[\]\\]/g, '\\$&');
  }
  return new RegExp(`${out}$`);
}

export function loadPolicy(file) {
  const text = fs.readFileSync(file, 'utf8');
  const parsed = JSON.parse(text);
  if (!Array.isArray(parsed.review)) throw new Error(`${file} has no review list`);
  return parsed;
}

/// The hash is of the FILE'S BYTES, normalised only by JSON re-serialisation with sorted keys, so two
/// checkouts with the same policy agree and a one-character edit does not.
export function policyHash(file) {
  const parsed = loadPolicy(file);
  const canonical = (value) => {
    if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
    if (value && typeof value === 'object') {
      return `{${Object.keys(value).sort().map((k) => `${JSON.stringify(k)}:${canonical(value[k])}`).join(',')}}`;
    }
    return JSON.stringify(value);
  };
  return crypto.createHash('sha256').update(canonical(parsed)).digest('hex');
}

/// What in this diff the policy names, and why. Empty means the queue may run it without a person.
export function evaluate(policy, files) {
  const rules = (policy.review || []).map((rule) => ({...rule, re: globToRegExp(rule.glob)}));
  const never = (policy.never || []).map((rule) => ({...rule, re: globToRegExp(rule.glob)}));
  const review = [];
  const refused = [];
  for (const file of files) {
    for (const rule of never) if (rule.re.test(file)) refused.push({file, glob: rule.glob, why: rule.why || 'never' });
    for (const rule of rules) if (rule.re.test(file)) review.push({file, glob: rule.glob, why: rule.why || '' });
  }
  return {review, refused, needsReview: review.length > 0, refuses: refused.length > 0};
}

/// Where a repo keeps it. One name, so a reader and the runner cannot disagree about which file decides.
export function policyPath(repo) {
  return path.join(repo, 'policies', 'landing-policy.json');
}

export {globToRegExp};
