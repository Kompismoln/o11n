#!/usr/bin/env bats

setup() {
  opening="<<<<<<< signed"
  divider="======="
  closing=">>>>>>> @""stamp"
  cd "$BATS_TEST_TMPDIR" || exit
  git init -q -b main repo
  cd repo || exit
  git config user.name operator
  git config user.email operator@example.org
  git config commit.gpgsign false
  mkdir dev
  cp "$BATS_TEST_DIRNAME/../../.prettierrc.yaml" .
  cp "$BATS_TEST_DIRNAME"/../{check.sh,write.sh,files.bash,stamps.sh,refcheck.sh,parts.sh} dev/
  printf '#!%s\n' "$BASH" >dev/index.sh
  chmod +x dev/index.sh
  echo '# Doc' >doc.md
  echo '{ }' >default.nix
  git add -A
  git commit -q -m one
}

@test "check.sh runs the stages named side by side, says what each said in order, and which failed" {
  printf '%s\n%s\nnew\n%s\n' "$opening" "$divider" "$closing" >>doc.md

  run dev/check.sh stamps pending docs
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "• stamps" ]
  [ "${lines[1]}" = "• pending" ]
  [ "${lines[2]}" = "flag: doc.md: 1 stamps pending: the operator stamps them before work proceeds" ]
  [ "${lines[3]}" = "• docs" ]
  [ "${lines[4]}" = "• failed: pending" ]

  run dev/check.sh stamps
  [ "$status" -eq 0 ]
  [ "$output" = "• stamps" ]

  run dev/check.sh nowhere
  [ "$status" -eq 1 ]
  [ "$output" = "no stage nowhere: stamps pending format lint docs parts index eval leaks bats vm" ]
}

@test "format checks the Nix, the Rust and the docs but those with stamps pending, which write.sh formats" {
  echo '{a=1;}' >default.nix
  echo 'fn main(){}' >main.rs
  printf '* one\n' >doc.md
  printf '%s\n%s\n* held\n%s\n' "$opening" "$divider" "$closing" >held.md
  run dev/check.sh format
  [ "$status" -ne 0 ]
  [[ $output == *"default.nix"* ]]
  nixfmt default.nix
  run dev/check.sh format
  [ "$status" -ne 0 ]
  [[ $output == *"main.rs"* ]]
  rustfmt main.rs
  run dev/check.sh format
  [ "$status" -ne 0 ]
  [[ $output == *"doc.md"* ]]
  [[ $output != *"held.md"* ]]
  [[ $output == *"dev/write.sh writes the format; run it, not nixfmt, rustfmt or prettier."* ]]

  run dev/write.sh
  [ "$status" -eq 0 ]
  [ "$(cat default.nix)" = "{ a = 1; }" ]
  [ "$(cat main.rs)" = "fn main() {}" ]
  [ "$(cat doc.md)" = "- one" ]
  [ "$(sed -n 3p held.md)" = "* held" ]
  run dev/check.sh format
  [ "$status" -eq 0 ]
}

@test "write.sh, given a commit, stamps each change to a doc since it" {
  echo 'More.' >>doc.md
  run dev/write.sh HEAD
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "against $(git log -1 --format='%h %s')" ]
  [ "${lines[1]}" = "doc.md: 1 stamps" ]
  grep -qxF "$opening" doc.md
}

@test "write.sh writes the index, and, given a commit, stamps it" {
  printf '#!%s\nprintf "# Index\\n\\nWritten.\\n" >index.md\n' "$BASH" >dev/index.sh
  run dev/write.sh HEAD
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "index.md: 1 stamps" ]
  grep -qxF 'Written.' index.md
}

@test "docs flags paths that aren't there and commits off main, but not what's elsewhere or ignored" {
  mkdir tools
  touch tools/there.sh
  echo /tools/written.sh >.gitignore
  git add -A
  git commit -q -m tools
  main=$(git rev-parse --short HEAD)
  git checkout -q -b work
  git commit -q --allow-empty -m branch
  branch=$(git rev-parse --short HEAD)
  cat >doc.md <<DOC
See \`tools/there.sh\`, \`tools/*.sh\` and \`tools/gone.sh\`, then \`elsewhere/x.sh\`.
The former \`tools/old.sh\`, Owner/repo's \`tools/theirs.sh\` and \`tools/mine.sh\` in Owner/repo.
Since $main, not $branch, and Owner/repo's
\`tools/wrapped.sh\`, and \`tools/written.sh\`, which a tool writes.

\`\`\`
tools/fenced.sh $branch
\`\`\`
DOC

  run dev/check.sh docs
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "flag: doc.md:1: \`tools/gone.sh\` isn't there" ]
  [ "${lines[2]}" = "flag: doc.md:3: $branch isn't a commit on main" ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "each stage logs what it said to dev/state/logs/<stage>.log, under what ran it, and still fails as it did" {
  printf '%s\n' "$opening" >>doc.md

  run dev/check.sh stamps docs
  [ "$status" -eq 1 ]
  [[ $(head -n 1 dev/state/logs/stamps.log) == *" $(git rev-parse --short HEAD) dev/check.sh stamps" ]]
  [ "$(sed -n 2p dev/state/logs/stamps.log)" = "• stamps" ]
  grep -q "a stamp isn't closed" dev/state/logs/stamps.log
  [ "$(tail -n +2 dev/state/logs/docs.log)" = "• docs" ]
}

@test "parts flags a stage or layer not declared, code or a doc that isn't there, a file two parts hold, and an index of no part" {
  mkdir -p docs/index
  echo '# Index' >docs/index/gone.md
  cat >dev/parts.toml <<'TOML'
stages = ["drafted"]
layers = ["domain"]
[parts.one]
stage = "drafted"
layer = "domain"
code = ["dev", "gone.nix"]
[parts.two]
stage = "felt"
layer = "domin"
doc = "doc.md"
code = ["dev/check.sh"]
TOML
  run dev/check.sh parts
  [ "$status" -eq 1 ]
  [[ $output == *"[parts.one]: \`gone.nix\` isn't there"* ]]
  [[ $output == *"[parts.two]: stage 'felt' isn't one of stages"* ]]
  [[ $output == *"[parts.two]: layer 'domin' isn't one of layers"* ]]
  [[ $output == *"\`dev/check.sh\` is held by 2 parts, one, two, not one"* ]]
  [[ $output == *"\`docs/index/gone.md\` indexes no part"* ]]
  [[ $output != *"default.nix"* ]]
}
