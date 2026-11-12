import json, re, sys
pbx_path, resolved_path = sys.argv[1], sys.argv[2]

def brace_balance(text):
    depth, i, n = 0, 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                i += 2 if text[i] == '\\' else 1
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 1
        elif c in "{(": depth += 1
        elif c in "})": depth -= 1
        if depth < 0: return -1
        i += 1
    return depth

pbx = open(pbx_path).read()
assert brace_balance(pbx) == 0, "project file unbalanced before patching"
ids = set(re.findall(r'([0-9A-F]{24}) /\* (?:XCRemoteSwiftPackageReference "native-apps-ducksans"|DuckSansFont(?: in Frameworks)?) \*/', pbx))
if not ids:
    print("No DuckSans package in project, nothing to do"); sys.exit(0)
out, end_marker, removed = [], None, 0
for line in pbx.split("\n"):
    if end_marker is not None:
        removed += 1
        if line == end_marker: end_marker = None
        continue
    s = line.strip()
    if any(s.startswith(i) for i in ids):
        removed += 1
        if s.endswith("= {"):
            indent = line[:len(line) - len(line.lstrip())]
            end_marker = indent + "};"
        continue
    out.append(line)
new = "\n".join(out)
assert end_marker is None, "unterminated object"
assert not any(i in new for i in ids), "leftover DuckSans refs"
assert brace_balance(new) == 0, "project file unbalanced after patching"
open(pbx_path, "w").write(new)
r = json.load(open(resolved_path))
r["pins"] = [p for p in r["pins"] if p["identity"] != "native-apps-ducksans"]
json.dump(r, open(resolved_path, "w"), indent=2)
print(f"Removed {len(ids)} DuckSans ids ({removed} lines) and its Package.resolved pin; braces balanced")
