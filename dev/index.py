"""Usage: python3 dev/index.py [--check], from the clone's root. Writes docs/index/<part>.md for each part the flake's
index (dev/index.nix) has entries for, and removes those of parts it has none for; with --check, writes nothing and
flags, and fails for, each that differs from what it would write, its stamps pending read as written now."""

import json
import subprocess
import sys
from pathlib import Path

INDEX = Path("docs/index")
OPENING, DIVIDER, CLOSING = "<<<<<<< signed", "=======", ">>>>>>> @" + "stamp"


def index():
    said = subprocess.run(
        ["nix", "eval", "--json", "--no-warn-dirty", ".#index"], capture_output=True, check=True, text=True
    ).stdout
    return json.loads(said)


def rendered(part, options):
    lines = [
        f"# `{part}`",
        "",
        "Written by `dev/index.py` from the options of an org that are declared in the part's code, as "
        "`dev/index.nix` reads them, each by its place in `org.toml`.",
        "",
        "## Options",
    ]
    for option in options:
        facts = [", ".join(f"`{path}`" for path in option["files"])]
        if option["type"]:
            facts.append(option["type"])
        lines += ["", f"### `{option['name']}`", "", " · ".join(facts)]
        if option["default"] is not None:
            default = option["default"].strip()
            if option["prose"]:
                lines += ["", f"Default: {default}"]
            elif "\n" in default:
                lines += ["", "Default:", "", "```nix", default, "```"]
            else:
                lines += ["", f"Default: `{default}`"]
        if option["description"]:
            lines += ["", option["description"].strip()]
    return formatted("\n".join(lines) + "\n", INDEX / f"{part}.md")


def formatted(text, path):
    return subprocess.run(
        ["prettier", "--stdin-filepath", str(path)], input=text, capture_output=True, check=True, text=True
    ).stdout


def applied(text):
    kept, at = [], None
    for line in text.splitlines(keepends=True):
        bare = line.rstrip("\n")
        if at is None and bare == OPENING:
            at = "signed"
        elif at == "signed" and bare == DIVIDER:
            at = "applied"
        elif at == "applied" and bare == CLOSING:
            at = None
        elif at != "signed":
            kept.append(line)
    return "".join(kept)


def main():
    check = sys.argv[1:] == ["--check"]
    written = {INDEX / f"{part}.md": rendered(part, options) for part, options in sorted(index().items()) if options}
    stale = [path for path in sorted(INDEX.glob("*.md")) if path not in written]
    flagged = False
    for path, text in written.items():
        now = applied(path.read_text()) if path.exists() else None
        if now == text:
            continue
        if check:
            print(f"flag: {path}: isn't what dev/index.py writes")
            flagged = True
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
            print(f"{path}: written")
    for path in stale:
        if check:
            print(f"flag: {path}: indexes a part with nothing to index")
            flagged = True
        else:
            path.unlink()
            print(f"{path}: removed")
    sys.exit(1 if flagged else 0)


if __name__ == "__main__":
    main()
