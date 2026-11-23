p = "rust/wa-sentinel/src/main.rs"
s = open(p, encoding="utf-8").read()
old = '''            if let Some(line) = held.announcement(key, verb, &why, asked) {'''
new = '''            if let Some(line) = held.announcement(key, verb, &why, asked) {'''
assert old in s
open(p, "w", encoding="utf-8").write(s)
print('no-op check ok')
