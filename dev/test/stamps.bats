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

commit() {
  git add -A
  git commit -q -m "${1:-work}"
}

@test "write needs a commit" {
  echo one >doc.md
  commit

  run "$stamps" write
  [ "$status" -eq 1 ]
  [ "$output" = "stamps: write: '' isn't a commit" ]

  run "$stamps" write nowhere
  [ "$status" -eq 1 ]
  [ "$output" = "stamps: write: 'nowhere' isn't a commit" ]
}

@test "write stamps each change since the commit, committed or not" {
  printf 'one\ntwo\nthree\nfour\n' >doc.md
  commit signed
  printf 'one\nTWO\nthree\nfour\n' >doc.md
  commit
  printf 'one\nTWO\nthree\nfour\nfive\n' >doc.md

  run "$stamps" write HEAD~1
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

@test "write stamps against what was signed at the commit, through its stamps pending" {
  printf 'one\ntwo\n' >doc.md
  commit signed
  printf 'one\nTWO\n' >doc.md
  "$stamps" write HEAD
  commit turn

  printf 'ONE\nTWO\n' >doc.md
  run "$stamps" write HEAD
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "doc.md: 1 stamps" ]
  [ "$(cat doc.md)" = "$opening
one
two
$divider
ONE
TWO
$closing" ]
}

@test "write leaves its stamps as they are" {
  printf 'one\ntwo\n' >doc.md
  commit signed
  printf 'one\nTWO\n' >doc.md
  "$stamps" write HEAD

  run "$stamps" write HEAD
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "nothing to write" ]
}

@test "write stamps a new doc whole, and a renamed one against its old name" {
  seq 1 10 >old.md
  commit signed
  git mv old.md new.md
  seq 1 10 | sed 's/^5$/five/' >new.md
  echo fresh >fresh.md

  run "$stamps" write HEAD
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
  commit signed
  git rm -q doc.md
  echo two >notes.txt

  run "$stamps" write HEAD
  [ "$status" -eq 0 ]
  [ "${lines[1]}" = "nothing to write" ]
  [ "$(cat notes.txt)" = two ]
}

@test "check flags a conflict marker that isn't a stamp's, and a stamp that isn't closed" {
  printf 'one\n<<<<<<< HEAD\n' >merge.md
  printf 'one\n%s\ntwo\n%s\n' "$opening" "$divider" >open.md

  run "$stamps" check
  [ "$status" -eq 1 ]
  [[ $output == *"flag: merge.md: line 2: a conflict marker that isn't a stamp's"* ]]
  [[ $output == *"flag: open.md: line 2: a stamp isn't closed"* ]]

  run "$stamps" pending
  [ "$status" -eq 1 ]
  [[ $output == *"flag: merge.md: line 2: a conflict marker that isn't a stamp's"* ]]
}

@test "check passes stamps pending, and pending fails on them until the operator stamps them" {
  printf 'one\ntwo\n' >doc.md
  commit signed
  printf 'one\nTWO\n' >doc.md
  "$stamps" write HEAD

  run "$stamps" check
  [ "$status" -eq 0 ]
  [ "$output" = "" ]

  run "$stamps" pending
  [ "$status" -eq 1 ]
  [ "$output" = "flag: doc.md: 1 stamps pending: the operator stamps them before work proceeds" ]

  printf 'one\nTWO\n' >doc.md
  run "$stamps" pending
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "check and pending read a directory without git" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/docs"
  printf '%s\n%s\none\n%s\n' "$opening" "$divider" "$closing" >"$BATS_TEST_TMPDIR/plain/docs/doc.md"

  run "$stamps" check "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 0 ]

  run "$stamps" pending "$BATS_TEST_TMPDIR/plain"
  [ "$status" -eq 1 ]
  [ "$output" = "flag: docs/doc.md: 1 stamps pending: the operator stamps them before work proceeds" ]
}
