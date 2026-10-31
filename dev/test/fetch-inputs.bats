#!/usr/bin/env bats

# shellcheck disable=SC2016 # Accommodating for the stub, whose variables expand when it runs
setup() {
  fetch=$BATS_TEST_DIRNAME/../fetch-inputs.sh
  cd "$BATS_TEST_TMPDIR" || exit
  mkdir bin
  printf '#!%s\n%s\n' "$BASH" '
    ref=${*: -1}
    echo "$ref" >>"$BATS_TEST_TMPDIR/fetched"
    if [[ $ref == *private* ]]; then
      echo "error: no access" >&2
      exit 1
    fi
    printf "{\"storePath\":\"/nix/store/%s-source\"}\n" "$(basename "${ref%%\?*}")"
  ' >bin/nix
  chmod +x bin/nix
  export PATH=$BATS_TEST_TMPDIR/bin:$PATH
}

github() {
  printf '"%s":{"locked":{"type":"github","owner":"%s","repo":"%s","rev":"%s"}}' "$1" "$2" "$3" "$4"
}

gitlab() {
  printf '"%s":{"locked":{"type":"gitlab","owner":"%s","repo":"%s","rev":"%s"}}' "$1" "$2" "$3" "$4"
}

@test "fetches each github: input once over git, at its revision, and prints where it lands" {
  printf '{"nodes":{%s,%s,%s,"other":{"locked":{"type":"path"}},"root":{}}}' \
    "$(github a owner one 1)" "$(github b owner two 2)" "$(github c owner one 1)" >flake.lock

  run "$fetch"
  [ "$status" -eq 0 ]
  [ "$output" = "/nix/store/one-source
/nix/store/two-source" ]
  [ "$(cat fetched)" = "git+https://github.com/owner/one?rev=1&shallow=1
git+https://github.com/owner/two?rev=2&shallow=1" ]
}

@test "fetches gitlab: inputs over git from gitlab.com, or the host the lock names" {
  printf '{"nodes":{%s,"b":{"locked":{"type":"gitlab","host":"git.example.org","owner":"owner","repo":"two","rev":"2"}}}}' \
    "$(gitlab a owner one 1)" >flake.lock

  run "$fetch"
  [ "$status" -eq 0 ]
  [ "$output" = "/nix/store/two-source
/nix/store/one-source" ]
  [ "$(cat fetched)" = "git+https://git.example.org/owner/two?rev=2&shallow=1
git+https://gitlab.com/owner/one?rev=1&shallow=1" ]
}

@test "reports what it can't fetch, fetches the rest and fails" {
  mkdir org
  printf '{"nodes":{%s,%s}}' "$(github a owner private 1)" "$(github b owner public 2)" >org/flake.lock

  run "$fetch" org/flake.lock
  [ "$status" -eq 1 ]
  [[ $output == *"could not fetch git+https://github.com/owner/private?rev=1&shallow=1:"*"error: no access"* ]]
  [[ $output == *"/nix/store/public-source"* ]]
}
