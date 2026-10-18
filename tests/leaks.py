# usage: leaks.py STORE_DIR DRV PATTERN...
#
# Walks the derivations a system is built from, starting at DRV, without building
# anything, and prints every derivation and input source that matches a PATTERN as
# a whole word. Sources named "source" are whole input trees, like nixpkgs, and are
# skipped: what o11n and an org add are copies of their own files, named after them.

import os
import re
import sys

store_dir, drv, *patterns = sys.argv[1:]
store_path = re.compile(
    re.escape(store_dir).encode() + rb"/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+"
)
pattern = re.compile(rb"\b(?:" + "|".join(patterns).encode() + rb")\b")


def inputs(text):
    """The input derivations and input sources of a derivation in ATerm form:
    the second and third fields of Derive(outputs, inputDrvs, inputSrcs, ...)."""
    fields, depth, start, quoted, escaped = [], 0, len(b"Derive("), False, False
    for i in range(start, len(text)):
        c = text[i : i + 1]
        if quoted:
            escaped, quoted = (False, True) if escaped else (c == b"\\", c != b'"')
        elif c == b'"':
            quoted = True
        elif c in b"([":
            depth += 1
        elif c in b")]":
            depth -= 1
        elif c == b"," and depth == 0:
            fields.append(text[start:i])
            start = i + 1
            if len(fields) == 3:
                break
    return [
        {path.decode() for path in store_path.findall(field)} for field in fields[1:3]
    ]


def files(path):
    if os.path.isdir(path):
        for root, _, names in os.walk(path):
            for name in names:
                yield os.path.join(root, name)
    else:
        yield path


def leaks(path):
    for file in files(path):
        if os.path.islink(file) or not os.path.isfile(file):
            continue
        with open(file, "rb") as f:
            for number, line in enumerate(f, 1):
                if match := pattern.search(line):
                    yield f"{file}:{number}: {match.group().decode(errors='replace')}"


drvs, sources, todo = set(), set(), [drv]
while todo:
    path = todo.pop()
    if path in drvs:
        continue
    drvs.add(path)
    with open(path, "rb") as f:
        input_drvs, input_srcs = inputs(f.read())
    todo.extend(input_drvs - drvs)
    sources |= {src for src in input_srcs if not src.endswith("-source")}

found = [leak for path in sorted(drvs | sources) for leak in leaks(path)]
print(f"{len(drvs)} derivations and {len(sources)} sources from {drv}")
for leak in found:
    print(leak, file=sys.stderr)
sys.exit(1 if found else 0)
