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
  cp "$BATS_TEST_DIRNAME/../../check.sh" "$BATS_TEST_DIRNAME/../../write.sh" "$BATS_TEST_DIRNAME/../../.prettierrc.yaml" .
  cp "$BATS_TEST_DIRNAME/../files.bash" "$BATS_TEST_DIRNAME/../stamps.sh" "$BATS_TEST_DIRNAME/../refcheck.py" dev/
  echo '# Doc' >doc.md
  echo '{ }' >default.nix
  git add -A
  git commit -q -m one
}

@test "check.sh runs the stages named side by side, says what each said in order, and which failed" {
  printf '%s\n%s\nnew\n%s\n' "$opening" "$divider" "$closing" >>doc.md

  run ./check.sh stamps pending docs
  [ "$status" -eq 1 ]
  [ "${lines[0]}" = "• stamps" ]
  [ "${lines[1]}" = "• pending" ]
  [ "${lines[2]}" = "flag: doc.md: 1 stamps pending: the operator stamps them before work proceeds" ]
  [ "${lines[3]}" = "• docs" ]
  [ "${lines[4]}" = "• failed: pending" ]

  run ./check.sh stamps
  [ "$status" -eq 0 ]
  [ "$output" = "• stamps" ]

  run ./check.sh nowhere
  [ "$status" -eq 1 ]
  [ "$output" = "no stage nowhere: stamps pending format lint docs eval leaks bats vm" ]
}

@test "format checks the Nix and the docs but those with stamps pending, which write.sh formats" {
  echo '{a=1;}' >default.nix
  printf '* one\n' >doc.md
  printf '%s\n%s\n* held\n%s\n' "$opening" "$divider" "$closing" >held.md
  run ./check.sh format
  [ "$status" -ne 0 ]
  [[ $output == *"default.nix"* ]]
  nixfmt default.nix
  run ./check.sh format
  [ "$status" -ne 0 ]
  [[ $output == *"doc.md"* ]]
  [[ $output != *"held.md"* ]]

  run ./write.sh
  [ "$status" -eq 0 ]
  [ "$(cat default.nix)" = "{ a = 1; }" ]
  [ "$(cat doc.md)" = "- one" ]
  [ "$(sed -n 3p held.md)" = "* held" ]
  run ./check.sh format
  [ "$status" -eq 0 ]
}

@test "write.sh, given a commit, stamps each change to a doc since it" {
  echo 'More.' >>doc.md
  run ./write.sh HEAD
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "against $(git log -1 --format='%h %s')" ]
  [ "${lines[1]}" = "doc.md: 1 stamps" ]
  grep -qxF "$opening" doc.md
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

  run ./check.sh docs
  [ "$status" -eq 1 ]
  [ "${lines[1]}" = "flag: doc.md:1: \`tools/gone.sh\` isn't there" ]
  [ "${lines[2]}" = "flag: doc.md:3: $branch isn't a commit on main" ]
  [ "${#lines[@]}" -eq 3 ]
}
