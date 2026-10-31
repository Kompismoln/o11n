#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for Markdown, whose backticks are literal here
setup() {
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir -p bin dev docs/index
  cp "$BATS_TEST_DIRNAME/../index.py" dev/
  cp "$BATS_TEST_DIRNAME/../../.prettierrc.yaml" .
  printf '#!%s\ncat "%s/index.json"\n' "$BASH" "$BATS_TEST_TMPDIR" >bin/nix
  chmod +x bin/nix
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH
  cat >index.json <<'JSON'
{"org": [{"name": "host.<name>.roles", "type": "list of string", "default": "[ ]", "prose": false,
          "description": "the roles it has", "files": ["org/host.nix"]},
         {"name": "host.<name>.uid", "type": "int", "default": "the block of its class", "prose": true,
          "description": null, "files": ["org/principal.nix"]},
         {"name": "vpn", "type": null, "default": "{\n  wg0 = { };\n}", "prose": false,
          "description": null, "files": ["org/default.nix"]}],
 "tools": []}
JSON
}

@test "writes a doc for each part with entries, checks it, its stamps pending read as written now, and removes the rest" {
  echo stale >docs/index/gone.md

  run python3 dev/index.py
  [ "$status" -eq 0 ]
  [ "$output" = "docs/index/org.md: written
docs/index/gone.md: removed" ]
  [ ! -e docs/index/tools.md ]
  grep -qxF '### `host.<name>.roles`' docs/index/org.md
  grep -qxF '`org/host.nix` · list of string' docs/index/org.md
  grep -qxF 'Default: `[ ]`' docs/index/org.md
  grep -qxF 'Default: the block of its class' docs/index/org.md
  grep -qxF '```nix' docs/index/org.md
  grep -qxF '  wg0 = { };' docs/index/org.md

  run python3 dev/index.py --check
  [ "$status" -eq 0 ]

  sed -i 's/^the roles it has$/<<<<<<< signed\nWhether it was.\n=======\nthe roles it has\n>>>>>>> @''stamp/' docs/index/org.md
  run python3 dev/index.py --check
  [ "$status" -eq 0 ]

  sed -i 's/"list of string"/"string"/' index.json
  echo stale >docs/index/gone.md
  run python3 dev/index.py --check
  [ "$status" -eq 1 ]
  [ "$output" = "flag: docs/index/org.md: isn't what dev/index.py writes
flag: docs/index/gone.md: indexes a part with nothing to index" ]
}
