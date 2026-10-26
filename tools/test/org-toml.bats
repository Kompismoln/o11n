#!/usr/bin/env bats
# tests/org-toml.bats

set -eu

setup() {
  load helpers.sh
  test_cmd=id-entities.sh

  echo "=== BEGIN SETUP ===" >&2
  setup-testenv
  export SOPS_AGE_KEY_FILE="$TESTROOT/keys/root-1"

  # init root 1 (bootstrap)
  export test_identity_root_1=AGE-SECRET-KEY-1DJDMVRRC7UNF8HSKVSGQCWFNMJ5HTRT6HT2MDML9JZ54GCW8TYNSSWWL8D
  SECRET_SEED=<(echo "$test_identity_root_1") "$test_cmd" -r 1 init age-key

  "$test_cmd" -r 2 init age-key

  echo "=== END SETUP ===" >&2
}

@test "org-toml base" {
  run org-toml.sh "name"
  expect 0 "Testorg"

  run org-toml.sh "build-hosts"
  expect 0 "testhost"

  run org-toml.sh "class" "host" "no-key"
  expect 1 "null"

  run org-toml.sh "class" "host" "keys"
  expect 0 "luks-key" 6

  run org-toml.sh "class-list"
  expect 0 "user" 4
}

@test "org-toml context" {
  run org-toml.sh "public-artifacts"
  expect 1 "CONTEXT: unbound"

  CONTEXT="host:testhost:age-key" run org-toml.sh "public-artifacts"
  expect 0 "artifacts/host-testhost-age-key.pub"

  CONTEXT="service:testdomain:tls-cert" run org-toml.sh "public-artifacts"
  expect 0 "artifacts/service-testdomain-tls-cert.pem"

  CONTEXT="host:testhost:age-key" run org-toml.sh "secrets"
  expect 0 "enc/host-testhost.yaml"

  CONTEXT="root:1:age-key" run org-toml.sh "secrets"
  expect 0 "keys/root-1"
}

@test "org-toml ops" {
  run org-toml.sh "ops" "rebuild"
  expect 0 "user-testuser rebuild:age-key" 9

  run org-toml.sh "ops" "check"
  expect 0 "host-lenovo check:ssh-key" 2

  run org-toml.sh "ops" "verify"
  expect 0 "user-testuser verify:mail" 33
}

@test "org-toml autocomplete-identity" {
  run org-toml.sh "ids-by-id" host-testhost
  expect 0 "host-testhost"

  run org-toml.sh "ids-by-id" host-testhos
  expect 1 ""

  run org-toml.sh "autocomplete-identity" "adm"
  expect 0 "user-testadmin" 1

  run org-toml.sh "autocomplete-identity" "user-testadmin"
  expect 0 "user-testadmin" 1
}

@test "org-toml sops-yaml" {
  id-entities.sh host-testhost init
  id-entities.sh host-lorem init
  id-entities.sh service-locksmith init
  id-entities.sh service-testservice init
  id-entities.sh user-testadmin init
  run org-toml.sh "sops-yaml" "*"
  expect 0 "some recipients missing"

  id-entities.sh user-testuser init
  id-entities.sh service-domain-local init
  id-entities.sh service-sysctl-user-portal init
  run org-toml.sh "sops-yaml" "*"
  expect 0 "age" 65
}

@test "org-toml recipients" {
  id-entities.sh user-testadmin init
  id-entities.sh host-testhost init
  id-entities.sh host-lorem init
  run org-toml.sh "recipients" "user-testadmin"
  expect 0 "age" 5
}

@test "org-toml grants" {
  run org-toml.sh "grants" "user-testadmin"
  expect 0 "host-testhost" 2

  run org-toml.sh "grants" "user-testuser"
  expect 0 "host-testhost" 1

  run org-toml.sh "grants" "host-testhost"
  expect 0 "" 1

  run org-toml.sh "grants" "service-locksmith"
  expect 0 "host-testhost" 2
}

@test "org-toml entity_group expansion" {
  run org-toml.sh "expand-entity-group" "*"
  expect 0 "user-testuser" 9

  run org-toml.sh "expand-entity-group" "user-testadmin"
  expect 0 "user-testadmin" 1

  run org-toml.sh "expand-entity-group" "host-*"
  expect 0 "host-testhost" 2

  run org-toml.sh "expand-entity-group" "host:lorem"
  expect 0 "host-lorem" 1

  run org-toml.sh "expand-entity-group" "host:testrole"
  expect 0 "host-testhost" 2

  run org-toml.sh "expand-entity-group" "host:trol"
  expect 0 "" 1

  run org-toml.sh "expand-entity-group" "host:testrole+lorem"
  expect 0 "host-lorem" 1
}

@test "org-toml search" {
  run org-toml.sh "ids-by-substring" "user" "testadmin"
  expect 0 "user-testadmin"

  run org-toml.sh "ids-by-substring" "*" "testadmin"
  expect 0 "user-testadmin"

  run org-toml.sh "ids-by-substring" "user" "adm"
  expect 0 "user-testadmin"

  run org-toml.sh "ids-by-substring" "usr" "adm"
  expect 5 "jq: error"

  run org-toml.sh "ids-by-substring" "host" "o"
  expect 0 "host-testhost" 2

  run org-toml.sh "ids-by-substring" "host" "q"
  expect 0 "" 1

  run org-toml.sh "ids-by-substring" "*" "l"
  expect 0 "service-sysctl-user-portal" 4
}

@test "org-toml reads the org at O11N_ORG_ROOT, whatever another project calls its root" {
  mkdir "$BATS_TEST_TMPDIR/project"
  cd "$BATS_TEST_TMPDIR/project"

  REPO_ROOT=$PWD O11N_ORG_ROOT=$TESTROOT run org-toml.sh "name"
  expect 0 "Testorg"
}
