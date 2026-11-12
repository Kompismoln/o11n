#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for Markdown, whose backticks are literal here

setup() {
  opening="<<<<<<< signed"
  divider="======="
  closing=">>>>>>> @""stamp"
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir bin
  printf '#!%s\ncat "%s/index.json"\n' "$BASH" "$BATS_TEST_TMPDIR" >bin/nix
  chmod +x bin/nix
  echo '{}' >index.json
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH
  git init -q -b main repo
  cd repo || exit
  git config user.name operator
  git config user.email operator@example.org
  git config commit.gpgsign false
  mkdir dev
  cp "$BATS_TEST_DIRNAME/../../.prettierrc.yaml" .
  cp "$BATS_TEST_DIRNAME"/../{check.sh,write.sh} dev/
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
  [ "$output" = "no stage nowhere: stamps pending stamped format lint docs parts index eval leaks bats vm" ]
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

@test "write.sh, given STAMPED, stamps each change to a doc since it" {
  echo 'More.' >>doc.md
  STAMPED=HEAD run dev/write.sh
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "against $(git log -1 --format='%h %s')" ]
  [ "${lines[1]}" = "doc.md: 1 stamps" ]
  grep -qxF "$opening" doc.md
}

indexed() {
  echo '{"x": [{"name": "o", "type": "int", "default": "1", "prose": false, "description": "Written.", "files": ["x.nix"]}]}' \
    >"$BATS_TEST_TMPDIR/index.json"
}

@test "write.sh writes the index, and, given STAMPED, stamps it" {
  indexed
  STAMPED=HEAD run dev/write.sh
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "docs/index/x.md: written" ]
  [ "${lines[2]}" = "docs/index/x.md: 1 stamps" ]
  grep -qxF 'Written.' docs/index/x.md
}

@test "each stage write.sh writes has its stage of check.sh, which passes once it has written" {
  indexed
  echo '{a=1;}' >default.nix
  echo 'More.' >>doc.md
  export STAMPED=HEAD
  for pair in format:format index:index stamps:stamped; do
    run dev/check.sh "${pair#*:}"
    [ "$status" -ne 0 ]
    run dev/write.sh "${pair%%:*}"
    [ "$status" -eq 0 ]
    run dev/check.sh "${pair#*:}"
    [ "$status" -eq 0 ]
  done

  unset STAMPED
  run dev/write.sh stamps
  [ "$status" -eq 1 ]
  [ "$output" = "write.sh: stamps writes against STAMPED, which is unset" ]
  run dev/write.sh nowhere
  [ "$status" -eq 1 ]
  [ "$output" = "no stage nowhere: costs format index stamps" ]
}

@test "docs flags paths that aren't there and commits off main, but not what's elsewhere or ignored" {
  mkdir tools
  touch tools/there.sh
  echo /tools/written.sh >.gitignore
  git add -A
  git commit -q -m tools
  main=$(git rev-parse HEAD)
  git checkout -q -b work
  git commit -q --allow-empty -m branch
  branch=$(git rev-parse HEAD)
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

@test "parts flags a stage or layer not declared, code or a doc that isn't there, a file two parts hold alike, and an index of no part" {
  mkdir -p docs/index
  echo '# Index' >docs/index/gone.md
  cat >dev/parts.toml <<'TOML'
stages = ["drafted"]
layers = ["domain"]
[parts.one]
stage = "drafted"
layer = "domain"
code = ["dev", "gone.nix", "dev/write.sh"]
[parts.two]
stage = "felt"
layer = "domin"
doc = "doc.md"
code = ["dev/check.sh", "dev/write.sh"]
TOML
  run dev/check.sh parts
  [ "$status" -eq 1 ]
  [[ $output == *"[parts.one]: \`gone.nix\` isn't there"* ]]
  [[ $output == *"[parts.two]: stage 'felt' isn't one of stages"* ]]
  [[ $output == *"[parts.two]: layer 'domin' isn't one of layers"* ]]
  [[ $output == *"\`dev/write.sh\` is held by 2 parts, one, two, not one"* ]]
  [[ $output != *"\`dev/check.sh\` is held"* ]]
  [[ $output == *"\`docs/index/gone.md\` indexes no part"* ]]
  [[ $output != *"default.nix"* ]]
}

@test "o11n-dev fails for an O11N_ROOT that holds no o11n-dev to build" {
  O11N_ROOT=$PWD run o11n-dev main
  [ "$status" -eq 1 ]
  [ "$output" = "o11n-dev: O11N_ROOT, $PWD, holds no crates/o11n-dev to build" ]
}

@test "with MACHINE_CLASS set and dev/costs.tsv there, each stage spools what it took, which write.sh folds into it" {
  MACHINE_CLASS=container run dev/check.sh stamps
  [ "$status" -eq 0 ]
  [ ! -e dev/state/costs-spool.tsv ]

  printf '2026-11-12T00:00:00Z\tcontainer\t12.0\t0\t0\tabc\tdev/check.sh lint\n' >dev/costs.tsv
  printf '[costs]\nquoted = "container"\nquoted_in = ["doc.md"]\n' >settings.toml
  printf -- '- `dev/check.sh lint` ~900s\n- `dev/check.sh docs` ~900s\n' >doc.md
  MACHINE_CLASS=container run dev/check.sh stamps
  [ "$status" -eq 0 ]
  MACHINE_CLASS=container run dev/check.sh stamps docs
  [ "$status" -eq 0 ]
  commit=$(git rev-parse --short HEAD)
  [ "$(cut -f2,4- dev/state/costs-spool.tsv | sort)" = "container	0	0	$commit	dev/check.sh stamps
container	0	0	$commit	dev/check.sh stamps docs
container	0	1	$commit	dev/check.sh docs
container	0	1	$commit	dev/check.sh stamps" ]

  run dev/write.sh costs
  [ "$status" -eq 0 ]
  [ "$output" = "dev/costs.tsv: 4 folded
doc.md: figures rewritten" ]
  [ ! -e dev/state/costs-spool.tsv ]
  [ "$(wc -l <dev/costs.tsv)" -eq 5 ]
  [ "$(cat doc.md)" = '- `dev/check.sh lint` ~12s
- `dev/check.sh docs` ~900s' ]
  run dev/write.sh costs
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "vm spools its evaluation, its build and each VM test the builder ran, with the time its driver says it took" {
  touch dev/costs.tsv
  {
    printf '#!%s\n' "$BASH"
    cat <<'NIX'
case $1 in
eval) echo '{"vm": 1, "eval": 3}' ;;
run)
  echo 'vm-test-run-o11n-mail> (finished: run the VM test script, in 30.48 seconds)' >&2
  echo 'vm-test-run-o11n-mail> (finished: cleanup, in 0.12 seconds)' >&2
  ;;
esac
NIX
  } >"$BATS_TEST_TMPDIR/bin/nix"
  {
    printf '#!%s\n' "$BASH"
    cat <<'NIX'
echo "${*//$'\n'/ }" >>"$BATS_TEST_TMPDIR/nix-eval-jobs.log"
echo '{"attrPath": ["0/vm/mail"], "drvPath": "/nix/store/x-vm-test-run-o11n-mail.drv"}'
NIX
  } >"$BATS_TEST_TMPDIR/bin/nix-eval-jobs"
  printf '#!%s\n' "$BASH" >"$BATS_TEST_TMPDIR/bin/nix-store"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  MACHINE_CLASS=container run dev/check.sh vm
  [ "$status" -eq 0 ]
  [[ $output == *"run the VM test script, in 30.48 seconds"* ]]
  [ "$(cut -f7 dev/state/costs-spool.tsv)" = "nix-eval-jobs vm
o11n remote build .#stages.vm
vmTests.mail
dev/check.sh vm" ]
  [ "$(sed -n 3p dev/state/costs-spool.tsv | cut -f3,4)" = "30.5	0" ]
  [[ $(cat "$BATS_TEST_TMPDIR/nix-eval-jobs.log") == *"--select"* ]]
}

@test "a stage's jobs, at a tree whose derivations are still there, are as they were last evaluated there" {
  {
    printf '#!%s\n' "$BASH"
    cat <<'NIX'
echo "$*" >>"$BATS_TEST_TMPDIR/nix.log"
[[ $1 != eval ]] || echo '{"eval": 2}'
NIX
  } >"$BATS_TEST_TMPDIR/bin/nix"
  {
    printf '#!%s\n' "$BASH"
    cat <<'NIX'
echo "${*//$'\n'/ }" >>"$BATS_TEST_TMPDIR/nix-eval-jobs.log"
echo '{"attrPath": ["0/eval/one"], "drvPath": "/nix/store/x-one.drv"}'
echo '{"attrPath": ["0/eval/two"], "drvPath": "/nix/store/x-two.drv"}'
NIX
  } >"$BATS_TEST_TMPDIR/bin/nix-eval-jobs"
  printf '#!%s\nexit "${INVALID:-0}"\n' "$BASH" >"$BATS_TEST_TMPDIR/bin/nix-store"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  run dev/check.sh eval
  [ "$status" -eq 0 ]
  grep -qxF -- "build --no-link --quiet --no-warn-dirty /nix/store/x-one.drv^* /nix/store/x-two.drv^*" "$BATS_TEST_TMPDIR/nix.log"
  run dev/check.sh eval
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$BATS_TEST_TMPDIR/nix-eval-jobs.log")" -eq 1 ]
  INVALID=1 run dev/check.sh eval
  [ "$(wc -l <"$BATS_TEST_TMPDIR/nix-eval-jobs.log")" -eq 2 ]
  echo changed >>doc.md
  run dev/check.sh eval
  [ "$(wc -l <"$BATS_TEST_TMPDIR/nix-eval-jobs.log")" -eq 3 ]
}

@test "a job that fails to evaluate fails its stage, saying why, and the stage evaluated beside it builds" {
  {
    printf '#!%s\n' "$BASH"
    cat <<'NIX'
[[ $1 != eval ]] || echo '{"eval": 1, "leaks": 1}'
NIX
  } >"$BATS_TEST_TMPDIR/bin/nix"
  {
    printf '#!%s\n' "$BASH"
    cat <<'NIX'
echo '{"attrPath": ["0/eval/one"], "error": "error: broken"}'
echo '{"attrPath": ["1/leaks/two"], "drvPath": "/nix/store/x-two.drv"}'
NIX
  } >"$BATS_TEST_TMPDIR/bin/nix-eval-jobs"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  run dev/check.sh eval leaks
  [ "$status" -eq 1 ]
  [[ $output == *"eval/one: error: broken"* ]]
  [ "${lines[-1]}" = "• failed: eval" ]
}

@test "an evaluation that fails before nix-eval-jobs answers fails each stage that waits for it, rather than hang" {
  printf '#!%s\necho "warning: noise" >&2\n[[ $1 != eval ]] || { echo "error: no jobs" >&2; exit 1; }\n' "$BASH" \
    >"$BATS_TEST_TMPDIR/bin/nix"
  chmod +x "$BATS_TEST_TMPDIR/bin/nix"
  run timeout 60 dev/check.sh eval leaks
  [ "$status" -eq 1 ]
  [[ $output == *"error: no jobs"* ]]
  [[ $output == *"evaluate: eval wasn't evaluated, as said above"* ]]
  [ "${lines[-1]}" = "• failed: eval leaks" ]
}
