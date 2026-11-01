#!/usr/bin/env bats

setup() {
  load helpers.sh
  setup-testenv
  export SOPS_AGE_KEY_FILE=$TESTROOT/keys/root-1
  o11n identity create root-1 --from <(echo "$test_identity_root_1")
}

@test "a root identity is its file, and its public key beside it" {
  [ "$(age-keygen -y keys/root-1)" = "$(cat "$(o11n path public-key root-1 age-key)")" ]

  [ "$(o11n identity show root-1 2>/dev/null)" = "$test_identity_root_1" ]
}

@test "an identity has its own file, apart from the sops file that names it" {
  run o11n identity create host-testhost
  succeeds
  [ -f enc/host-testhost.age ]

  run sops decrypt --extract '["identity"]' enc/host-testhost.yaml
  succeeds
  [ "$output" = host-testhost ]
  [[ $(sops decrypt enc/host-testhost.yaml) != *AGE-SECRET-KEY* ]]

  o11n identity show host-testhost 2>/dev/null >"$BATS_TEST_TMPDIR/host"
  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/host run sops decrypt --extract '["identity"]' enc/host-testhost.yaml
  succeeds

  age-keygen -o "$BATS_TEST_TMPDIR/stranger" 2>/dev/null
  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/stranger run o11n secret generate host-testhost luks-key
  fails "but none were"
}

@test "a grant gives the grantee an entity's secrets, not its identity" {
  o11n identity create host-testhost
  o11n identity create user-testadmin
  o11n secret generate user-testadmin ssh-key
  o11n identity show host-testhost 2>/dev/null >"$BATS_TEST_TMPDIR/host"

  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/host run o11n secret show user-testadmin ssh-key
  succeeds

  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/host run o11n identity show user-testadmin
  fails "enc/user-testadmin.age"
}

@test "an actor acts as the entity, and as no other" {
  o11n identity create user-testadmin
  o11n identity create service-testservice
  o11n identity create service-locksmith
  o11n identity show user-testadmin 2>/dev/null >"$BATS_TEST_TMPDIR/admin"

  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/admin run o11n identity show service-testservice
  succeeds
  [[ $output == *"acting as user-testadmin"* ]]

  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/admin run o11n identity show service-locksmith
  fails "enc/service-locksmith.age"
}

@test "a luks-key has slots" {
  o11n identity create host-testhost

  run o11n secret generate host-testhost luks-key
  succeeds
  run o11n secret generate host-testhost luks-key --slot 1
  succeeds
  [[ $output == *"stored host-testhost's luks-key in slot 1"* ]]

  run o11n secret remove host-testhost luks-key --slot 1
  succeeds
  run o11n secret show host-testhost luks-key --slot 1
  fails "there's no host-testhost's luks-key in slot 1"

  run o11n secret generate host-testhost ssh-key --slot 1
  fails "a ssh-key has no slots"
}

@test "a new root identity is a recipient of everything" {
  o11n identity create host-testhost

  run o11n identity create root-2
  succeeds
  [[ $output == *"encrypted enc/host-testhost.yaml to host-testhost's recipients"* ]]

  SOPS_AGE_KEY_FILE=$TESTROOT/keys/root-2 run o11n identity show host-testhost
  succeeds
  SOPS_AGE_KEY_FILE=$TESTROOT/keys/root-2 run o11n secret generate host-testhost luks-key
  succeeds

  run o11n identity create root-3
  fails "no entity root-3"
}

@test "a root identity is rotated by another" {
  o11n identity create user-testuser
  o11n identity create root-2
  cp keys/root-1 "$BATS_TEST_TMPDIR/old-root"

  run o11n identity rotate root-1
  fails "root-1 can't rotate its own identity"

  SOPS_AGE_KEY_FILE=$TESTROOT/keys/root-2 run o11n identity rotate root-1
  succeeds

  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/old-root run o11n identity show user-testuser
  fails "enc/user-testuser.age"
  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/old-root run o11n secret generate user-testuser ssh-key
  fails "but none were"

  run o11n identity show user-testuser
  succeeds
  run o11n secret generate user-testuser ssh-key
  succeeds
}

@test "an identity rotated is what its sops file is encrypted to" {
  o11n identity create user-testuser

  run o11n identity rotate user-testuser
  succeeds
  run o11n public-key verify user-testuser age-key
  succeeds

  o11n identity show user-testuser 2>/dev/null >"$BATS_TEST_TMPDIR/user"
  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/user run sops decrypt --extract '["identity"]' enc/user-testuser.yaml
  succeeds

  run o11n identity rotate host-testhost
  fails "o11n host push host-testhost age-key"
}

@test "a host takes a new identity through its locksmith" {
  mock-host testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")

  run o11n host check host-testhost age-key
  succeeds

  run o11n host push host-testhost age-key --from <(echo "$test_age_key_2")
  succeeds
  run o11n identity show host-testhost
  [[ $output == *"$test_age_key_2"* ]]
  run o11n public-key verify host-testhost age-key
  succeeds
  run o11n host check host-testhost age-key
  succeeds

  o11n identity show host-testhost 2>/dev/null >"$BATS_TEST_TMPDIR/host"
  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/host run sops decrypt --extract '["identity"]' enc/host-testhost.yaml
  succeeds
}

@test "a host's identity isn't pushed while its public key doesn't match" {
  mock-host testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")
  age-keygen -y <(echo "$test_age_key_2") >public-keys/host-testhost-age-key.pub

  run o11n host push host-testhost age-key
  fails "isn't the age-key's public key"
}

@test "a host's luks-keys are added and revoked through its locksmith" {
  mock-host testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")

  run o11n secret generate host-testhost luks-key --from <(echo "$test_luks_key_1")
  fails "the luks-key has a trailing newline"

  run o11n secret generate host-testhost luks-key --from <(echo -n "$test_luks_key_2")
  succeeds
  run o11n host check host-testhost luks-key
  fails "No key available with this passphrase."

  run o11n secret generate host-testhost luks-key --from <(echo -n "$test_luks_key_1")
  succeeds
  run o11n host check host-testhost luks-key
  succeeds

  run o11n host push host-testhost luks-key --from <(echo -n "$test_luks_key_2")
  succeeds
  [[ $output == *"took a luks-key for slot 1, on the strength of slot 0"* ]]
  run o11n host check host-testhost luks-key --slot 1
  succeeds

  run o11n host revoke host-testhost luks-key --slot 0
  succeeds
  run o11n host check host-testhost luks-key --slot 1
  succeeds
  run o11n host check host-testhost luks-key
  fails "there's no host-testhost's luks-key"

  run o11n host revoke host-testhost luks-key --slot 1
  fails "is the last luks-key the org holds for host-testhost"
}

@test "a host's ssh-key is pulled from the host" {
  mock-host testhost
  o11n identity create host-testhost

  run o11n secret generate host-testhost ssh-key
  succeeds
  run o11n public-key verify host-testhost ssh-key
  succeeds
  run o11n host check host-testhost ssh-key
  fails "> ssh-ed25519 AAA"

  run o11n host pull-ssh-key host-testhost
  succeeds
  run o11n host check host-testhost ssh-key
  succeeds
  run o11n public-key verify host-testhost ssh-key
  fails "> ssh-ed25519 AAAA"
}

@test "a public key that's missing or another's fails verification, and is written again" {
  o11n identity create host-testhost
  o11n identity create service-testservice
  o11n identity create user-testuser

  for key in wg0-key wg1-key wg2-key; do
    run o11n secret generate host-testhost "$key"
    succeeds
    run o11n public-key verify host-testhost "$key"
    succeeds
    [ -f "public-keys/host-testhost-$key.pub" ]
  done

  cp public-keys/host-testhost-wg1-key.pub public-keys/host-testhost-wg0-key.pub
  run o11n public-key verify host-testhost wg0-key
  fails "> "

  for key in nix-sign ssh-key; do
    run o11n secret generate service-testservice "$key"
    succeeds
    rm "$(o11n path public-key service-testservice "$key")"
    run o11n public-key verify service-testservice "$key"
    fails "there's no $(o11n path public-key service-testservice "$key")"
    run o11n public-key write service-testservice "$key"
    succeeds
    run o11n public-key verify service-testservice "$key"
    succeeds
  done

  cp public-keys/root-1-age-key.pub public-keys/user-testuser-age-key.pub
  run o11n public-key verify user-testuser age-key
  fails "< $(cat public-keys/root-1-age-key.pub)"
  run o11n public-key write user-testuser age-key
  succeeds
  run o11n public-key verify user-testuser age-key
  succeeds
}

@test "a password's public key is its hash beside it" {
  o11n identity create user-testuser

  run o11n secret generate user-testuser passwd
  succeeds
  run o11n public-key verify user-testuser passwd
  succeeds
  run o11n secret hash user-testuser passwd
  succeeds
  [[ ${lines[-1]} == \$6\$* ]]

  sops set enc/user-testuser.yaml '["testuser"]["passwd"]' '"another-password"'
  run o11n public-key verify user-testuser passwd
  fails "user-testuser's passwd-sha512 isn't the passwd's public key"
  run o11n public-key write user-testuser passwd
  succeeds
  run o11n public-key verify user-testuser passwd
  succeeds
}

@test "a domain's tls-cert is its own, for it and its subdomains" {
  o11n identity create service-domain-local
  o11n identity create service-testservice

  run o11n secret generate service-domain-local tls-cert
  succeeds
  run o11n public-key verify service-domain-local tls-cert
  succeeds
  [ -f public-keys/service-domain-local-tls-cert.pem ]

  cp public-keys/service-domain-local-tls-cert.pem "$BATS_TEST_TMPDIR/cert"
  o11n secret generate service-domain-local tls-cert
  cp "$BATS_TEST_TMPDIR/cert" public-keys/service-domain-local-tls-cert.pem
  run o11n public-key verify service-domain-local tls-cert
  fails "isn't the tls-cert's public key"

  run o11n secret generate service-testservice tls-cert
  fails "a tls-cert is a domain's"
}

@test "entities with hyphens in their name" {
  o11n identity create service-sysctl-user-portal

  run o11n secret generate service-sysctl-user-portal ssh-key
  succeeds
  [ -f public-keys/service-sysctl-user-portal-ssh-key.pub ]

  run o11n secret generate service-sysctl-user-portal secret-key
  succeeds
  run o11n reencrypt
  succeeds
  run o11n public-key verify service-sysctl-user-portal secret-key
  succeeds
}

@test "what isn't there, or isn't so, is said" {
  o11n identity create service-domain-local
  o11n identity create user-testuser

  run o11n identity create service-domain-local
  fails "service-domain-local's identity already exists"
  run o11n secret generate service-domain-loca ssh-key
  fails "no entity service-domain-loca"
  run o11n secret generate root-1 ssh-key
  fails "ssh-key isn't one of root's keys: age-key"
  run o11n secret show user-testuser passwd
  fails "there's no user-testuser's passwd"
  run o11n secret show user-testuser age-key
  fails "an age-key is an identity"
  run o11n secret generate user-testuser foo-key
  fails "foo-key isn't one of user's keys"
}

@test "migrate moves each age-key from its sops file to its identity file" {
  o11n identity create user-testuser
  o11n identity show user-testuser 2>/dev/null >"$BATS_TEST_TMPDIR/user"
  sops set enc/user-testuser.yaml '["testuser"]["age-key"]' "$(jq -Rs . <"$BATS_TEST_TMPDIR/user")"
  rm enc/user-testuser.age

  run o11n identity migrate
  succeeds
  [ "$(o11n identity show user-testuser 2>/dev/null)" = "$(cat "$BATS_TEST_TMPDIR/user")" ]
  run sops decrypt --extract '["testuser"]["age-key"]' enc/user-testuser.yaml
  fails "not found"
}

@test "as runs the command with the entity's identity as sops', and its ssh-key in an agent" {
  o11n identity create user-testadmin
  o11n secret generate user-testadmin ssh-key

  run o11n as user-testadmin bash -c 'ssh-add -L; sops decrypt --extract "[\"identity\"]" enc/user-testadmin.yaml'
  succeeds
  [[ $output == *"$(cut -d' ' -f1,2 public-keys/user-testadmin-ssh-key.pub)"* ]]
  [[ $output == *$'\n'user-testadmin ]]
}

@test "as exits as the command did, and leaves no agent or keys behind" {
  o11n identity create user-testadmin
  o11n secret generate user-testadmin ssh-key

  # shellcheck disable=SC2016 # Accommodating for the command, whose variables expand as the entity's
  run o11n as user-testadmin bash -c 'echo "$SSH_AUTH_SOCK $SOPS_AGE_KEY_FILE $SSH_AGENT_PID"; exit 3'
  [ "$status" -eq 3 ]
  read -r socket identity agent <<<"${lines[-1]}"
  [ ! -e "$socket" ]
  [ ! -e "$identity" ]
  run kill -0 "$agent"
  [ "$status" -ne 0 ]
}

@test "as leaves an agent it didn't start alone" {
  o11n identity create user-testadmin
  o11n secret generate user-testadmin ssh-key
  eval "$(ssh-agent -s)" >/dev/null

  run o11n as user-testadmin true
  succeeds
  kill -0 "$SSH_AGENT_PID"
  run ssh-add -l
  [ "$status" -eq 1 ]
  ssh-agent -k >/dev/null
}

@test "as runs nothing as an entity it can't act as" {
  o11n identity create user-testadmin

  run o11n as user-testadmin touch "$BATS_TEST_TMPDIR/ran"
  fails "there's no user-testadmin's ssh-key"
  [ ! -e "$BATS_TEST_TMPDIR/ran" ]
}

@test "ssh logs in to the host as the entity, with its ssh-key, or runs the command there" {
  o11n identity create user-testadmin
  o11n secret generate user-testadmin ssh-key

  run o11n ssh user-testadmin testhost
  succeeds
  [ "${lines[-1]}" = "testadmin@testhost.local " ]

  run o11n ssh user-testadmin testhost journalctl -ef
  succeeds
  [ "${lines[-1]}" = "testadmin@testhost.local journalctl -ef" ]

  run o11n ssh user-testadmin testhost --user root
  fails "invalid user 'root'"
}

@test "edit opens the entity's secrets in sops' editor, and keeps what was written" {
  o11n identity create user-testuser
  # shellcheck disable=SC2016 # Accommodating for the editor, whose $1 expands as sops runs it
  printf '#!/bin/sh\necho "edited: yes" >>"$1"\n' >"$BATS_TEST_TMPDIR/editor"
  chmod +x "$BATS_TEST_TMPDIR/editor"

  EDITOR=$BATS_TEST_TMPDIR/editor run o11n secret edit user-testuser
  succeeds
  run sops decrypt --extract '["edited"]' enc/user-testuser.yaml
  [ "$output" = yes ]
}

@test "ops run each op of the name, and say which failed" {
  o11n identity create host-testhost
  o11n identity create user-testuser
  o11n secret generate user-testuser ssh-key

  run o11n ops verify --run
  fails "ops of verify failed"
  [[ $output == *"user-testuser verify:passwd: there's no user-testuser's passwd"* ]]
  [[ $output != *"user-testuser verify:ssh-key"* ]]

  run o11n ops rebuild --run
  succeeds
}

@test "tunnel opens, closes and tells of a server's reverse tunnel as admin, the code as one word, on the endpoint" {
  o11n identity create user-admin
  o11n secret generate user-admin ssh-key

  run o11n tunnel testhost open "it's 1234"
  succeeds
  [ "${lines[-1]}" = "admin@testhost.local sudo reverse-tunnel open 'it'\\''s 1234'" ]

  run o11n tunnel testhost close
  [ "${lines[-1]}" = "admin@testhost.local sudo reverse-tunnel close" ]

  O11N_ROUTES='' run o11n tunnel testhost status
  [ "${lines[-1]}" = "admin@testhost.example.com sudo reverse-tunnel status" ]
}

@test "unit prints a unit of the host's configuration or another's, and injects it as service-rescue" {
  o11n identity create service-rescue
  o11n secret generate service-rescue ssh-key
  mkdir "$BATS_TEST_TMPDIR/bin"
  # shellcheck disable=SC2016 # Accommodating for the stubs, whose variables expand as o11n runs them
  printf '#!/bin/sh\necho "nix $*" >>"%s/calls"\necho "[Unit]"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/nix"
  # shellcheck disable=SC2016
  printf '#!/bin/sh\nssh-add -l >/dev/null && echo "scp $(cat "$1") $2" >>"%s/calls"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/scp"
  chmod +x "$BATS_TEST_TMPDIR"/bin/*
  PATH=$BATS_TEST_TMPDIR/bin:$PATH

  run o11n unit hello.service testhost
  succeeds
  [ "${lines[-1]}" = "[Unit]" ]
  [[ $(cat "$BATS_TEST_TMPDIR/calls") == *'#nixosConfigurations.testhost.config.systemd.units."hello.service".text' ]]

  run o11n unit hello.service testhost --from lorem --inject
  succeeds
  [[ $(sed -n 2p "$BATS_TEST_TMPDIR/calls") == *'#nixosConfigurations.lorem.config'* ]]
  [ "$(sed -n 3p "$BATS_TEST_TMPDIR/calls")" = "scp [Unit] root@testhost.local:/run/systemd/system/hello.service" ]
}

@test "a route is pinned, an address or tried in the namespaces" {
  run o11n route testhost
  succeeds
  [ "${lines[-1]}" = testhost.local ]

  run o11n route localhost
  [ "$output" = localhost ]
  run o11n route 192.0.2.1
  [ "$output" = 192.0.2.1 ]

  run o11n route lorem --port 1
  fails "no contact with lorem:1"
}

test_identity_root_1=AGE-SECRET-KEY-1DJDMVRRC7UNF8HSKVSGQCWFNMJ5HTRT6HT2MDML9JZ54GCW8TYNSSWWL8D

test_age_key_1=AGE-SECRET-KEY-1L0EJY3FLSYHDE46Y80F0KLUKUWP6V3J340UR7G2GWNFGXJQ0P6ZQ6X37TN
test_age_key_2=AGE-SECRET-KEY-1V782VQAQT6QJPARYTCD8CLES04Q83V068FRFDWG02HGLE96U93FSVACDKF

test_luks_key_1="luks1-Atzc2gtZWQyNTUxO"
test_luks_key_2="luks2-roGxnLozh/+wBGot"
