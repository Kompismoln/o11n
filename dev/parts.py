"""Usage: python3 dev/parts.py, from the clone's root. Flags, and fails for, what dev/parts.toml holds amiss: a stage
or a layer that isn't one of its stages or layers, a part's code or doc that isn't there, a tracked file two parts hold,
and an index of no part."""

import subprocess
import sys
import tomllib
from pathlib import Path


def tracked():
    try:
        listed = subprocess.run(
            ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
            capture_output=True,
            check=True,
            text=True,
        ).stdout
        return sorted(path for path in listed.split("\0") if path and Path(path).is_file())
    except (OSError, subprocess.CalledProcessError):
        return sorted(str(path) for path in Path(".").rglob("*") if path.is_file())


def holds(entry, path):
    return path == entry or path.startswith(entry.rstrip("/") + "/")


def flags(declared, files):
    stages, layers, parts = declared["stages"], declared["layers"], declared["parts"]
    for name, part in parts.items():
        if part.get("stage") not in stages:
            yield f"[parts.{name}]: stage {part.get('stage')!r} isn't one of stages"
        if part.get("layer") not in layers:
            yield f"[parts.{name}]: layer {part.get('layer')!r} isn't one of layers"
        for entry in part.get("code", []):
            if not any(holds(entry, path) for path in files):
                yield f"[parts.{name}]: `{entry}` isn't there"
        if "doc" in part and part["doc"] not in files:
            yield f"[parts.{name}]: `{part['doc']}` isn't there"
    for path in files:
        held = [name for name, part in parts.items() if path in (part.get("doc"), f"docs/index/{name}.md")]
        held += [name for name, part in parts.items() if any(holds(entry, path) for entry in part.get("code", []))]
        if len(held) > 1:
            yield f"`{path}` is held by {len(held)} parts, {', '.join(held)}, not one"
        if path.startswith("docs/index/") and not held:
            yield f"`{path}` indexes no part"


def main():
    with open("dev/parts.toml", "rb") as file:
        declared = tomllib.load(file)
    flagged = list(flags(declared, tracked()))
    for flag in flagged:
        print(f"flag: dev/parts.toml: {flag}")
    sys.exit(1 if flagged else 0)


if __name__ == "__main__":
    main()
