# Usage: python3 dev/refcheck.py, in a clone. Flags each reference a doc makes, outside its code
# blocks and what a stamp pending holds as signed, that doesn't resolve: a path in backticks whose
# first part is at the clone's root, and that git doesn't ignore as what a tool writes, or a commit
# that isn't on main. A reference the text says is elsewhere is left alone: after "former" or
# "<owner>/<repo>'s", or before "in <owner>/<repo>".
import glob
import os
import re
import subprocess
import sys

PATH = re.compile(r"`([\w.-]+/[^`\s<>${}]*)`")
COMMIT = re.compile(r"(?<![\w/.:-])(?=[0-9a-f]*[a-f])(?=[0-9a-f]*\d)[0-9a-f]{7,40}(?![\w-])")
BEFORE = re.compile(r"(?:\bformer|[\w-]+/[\w.-]+'s)\s*`?$")
AFTER = re.compile(r"^`?\s+in [\w-]+/[\w.-]+")


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, text=True)


# Yields each paragraph of prose, with the number of its first line, so that what says a reference
# is elsewhere still says so once prettier wraps it onto another line.
def prose(doc):
    signed = fenced = False
    first, lines = 0, []
    with open(doc) as text:
        for n, line in enumerate(text, 1):
            line = line.rstrip("\n")
            kept = False
            if line == "<<<<<<< signed":
                signed = True
            elif line == "=======" and signed:
                signed = False
            elif line.startswith(">>>>>>> ") or signed:
                pass
            elif line.lstrip().startswith("```"):
                fenced = not fenced
            elif not fenced and line.strip():
                first = first if lines else n
                lines.append(line)
                kept = True
            if not kept and lines:
                yield first, "\n".join(lines)
                lines = []
    if lines:
        yield first, "\n".join(lines)


def elsewhere(text, match):
    return BEFORE.search(text[: match.start()]) or AFTER.match(text[match.end() :])


def resolves(ref):
    path = ref.split(":")[0]
    if git("check-ignore", "-q", path).returncode == 0:
        return True
    return bool(glob.glob(path)) if "*" in path else os.path.exists(path)


def on_main(commit, main):
    return main and git("merge-base", "--is-ancestor", commit, main).returncode == 0


def main():
    root = os.listdir(".")
    main = next((ref for ref in ("origin/main", "main") if git("rev-parse", "--verify", "-q", ref).returncode == 0), None)
    docs = git("ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md").stdout.split("\0")
    flagged = False
    for doc in filter(os.path.isfile, docs):
        for first, text in prose(doc):
            for match in PATH.finditer(text):
                ref = match.group(1)
                if ref.split("/")[0] in root and not elsewhere(text, match) and not resolves(ref):
                    n = first + text.count("\n", 0, match.start())
                    print(f"flag: {doc}:{n}: `{ref}` isn't there", file=sys.stderr)
                    flagged = True
            for match in COMMIT.finditer(text):
                commit = match.group(0)
                if not elsewhere(text, match) and not on_main(commit, main):
                    n = first + text.count("\n", 0, match.start())
                    print(f"flag: {doc}:{n}: {commit} isn't a commit on main", file=sys.stderr)
                    flagged = True
    sys.exit(1 if flagged else 0)


main()
