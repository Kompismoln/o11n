#!/usr/bin/env bats

setup() {
  stamps=$BATS_TEST_DIRNAME/../stamps.sh
  opening="<<<<<<< signed"
  divider="======="
  closing=">>>>>>> @""stamp"
  cd "$BATS_TEST_TMPDIR" || exit
  git init -q repo
  cd repo || exit
  git config user.name agent
  git config user.email agent@example.org
  git config commit.gpgsign false
}

signed() {
  git add -A
  git -c user.name=human -c user.email=human@example.org commit -q -m "${1:-signed}"
}

worked() {
  git add -A
  git commit -q -m "${1:-work}"
}

@test "write needs a commit by someone else" {
  echo one >doc.md
  worked

  run "$stamps" write
  [ "$status" -eq 1 ]
  [[ $output == *"no commit on HEAD's first parents is by anyone but agent@example.org"* ]]
}

@test "write stamps each change since what a human signed, committed or not" {
  printf 'one\ntwo\nthree\nfour\n' >doc.md
  signed
  printf 'one\nTWO\nthree\nfour\n' >doc.md
  worked
  printf 'one\nTWO\nthree\nfour\nfive\n' >doc.md

  run "$stamps" write
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "against $(git log -1 --format='%h %s' HEAD~1)" ]
  [ "${lines[1]}" = "doc.md: 2 stamps" ]
  [ "$(cat doc.md)" = "one
$opening
two
$divider
TWO
$closing
three
four
$opening
$divider
five
$closing" ]
}

@test "write leaves its stamps as they are, and restamps a further change against what was signed" {
  printf 'one\ntwo\n' >doc.md
  signed
  printf 'one\nTWO\n' >doc.md
  "$stamps" write

  run "$stamps" write
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "nothing to write" ]

  printf 'ONE\nTWO\n' >doc.md
  run "$stamps" write
  [ "${lines[1]}" = "doc.md: 1 stamps" ]
  [ "$(cat doc.md)" = "$opening
one
two
$divider
ONE
TWO
$closing" ]
}

@test "write stamps a new doc whole, and a renamed one against its old name" {
  seq 1 10 >old.md
  signed
  git mv old.md new.md
  seq 1 10 | sed 's/^5$/five/' >new.md
  echo fresh >fresh.md

  run "$stamps" write
  [ "$status" -eq 0 ]
  [[ $output == *"new.md: 1 stamps"* ]]
  [[ $output == *"fresh.md: 1 stamps"* ]]
  [ "$(sed -n 5,9p new.md)" = "$opening
5
$divider
five
$closing" ]
  [ "$(cat fresh.md)" = "$opening
$divider
fresh
$closing" ]
}

@test "write leaves what isn't a doc, and a doc deleted, alone" {
  echo one >doc.md
  echo one >notes.txt
  signed
  git rm -q doc.md
  echo two >notes.txt

  run "$stamps" write
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "nothing to write" ]
  [ "$(cat notes.txt)" = two ]
}

@test "check flags stamps pending until a human stamps them" {
  printf 'one\ntwo\n' >doc.md
  signed
  printf 'one\nTWO\n' >doc.md
  "$stamps" write

  run "$stamps" check
  [ "$status" -eq 1 ]
  [ "$output" = "flag: doc.md: 1 stamps pending: a human stamps them before work proceeds" ]

  printf 'one\nTWO\n' >doc.md
  run "$stamps" check
  [ "$status" -eq 0 ]
  [ "$output" = ok ]
}

@test "check flags a conflict marker that isn't a stamp's, and a stamp that isn't closed" {
  printf 'one\n<<<<<<< HEAD\n' >merge.md
  printf 'one\n%s\ntwo\n%s\n' "$opening" "$divider" >open.md

  run "$stamps" check
  [ "$status" -eq 1 ]
  [[ $output == *"flag: merge.md: line 2: a conflict marker that isn't a stamp's"* ]]
  [[ $output == *"flag: open.md: line 2: a stamp isn't closed"* ]]
}

@test "check reads a directory without git" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/docs"
  echo one >"$BATS_TEST_TMPDIR/plain/docs/doc.md"

  run "$stamps" check "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]

  printf '%s\n%s\none\n%s\n' "$opening" "$divider" "$closing" >"$BATS_TEST_TMPDIR/plain/docs/doc.md"
  run "$stamps" check "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 1 ]
  [ "$output" = "flag: docs/doc.md: 1 stamps pending: a human stamps them before work proceeds" ]
}
