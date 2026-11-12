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

  run o11n secret generate user-testuser ssh-key --slot 1
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
  o11n host pull-ssh-key host-testhost
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

@test "a host drops its old identities once the secrets of its systems open without them" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")
  cp enc/host-testhost.yaml "$BATS_TEST_TMPDIR/before.yaml"
  o11n host push host-testhost age-key --from <(echo "$test_age_key_2")
  local keyfile=$BATS_TEST_TMPDIR/host-testhost.local/keys/host-testhost
  [ "$(wc -l <"$keyfile")" -eq 2 ]

  run o11n host revoke host-testhost age-key --slot 1
  fails "a host's age-key has no slots"

  run o11n host revoke host-testhost age-key
  fails "doesn't list the sops files it decrypts: deploy before revoking"

  mock-systems "$BATS_TEST_TMPDIR/before.yaml"
  run o11n host revoke host-testhost age-key
  fails "doesn't open with the current identity alone: deploy before revoking"
  [[ $output == *"before.yaml, which "* ]]
  [ "$(wc -l <"$keyfile")" -eq 2 ]

  mock-systems "$TESTROOT/enc/host-testhost.yaml"
  run o11n host revoke host-testhost age-key
  succeeds
  [[ $output == *"host-testhost dropped every identity but its current one"* ]]
  [ "$(cat "$keyfile")" = "$test_age_key_2" ]
  run o11n host check host-testhost age-key
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
  o11n host pull-ssh-key host-testhost
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
  [[ $output == *"took a luks-key for slot 0, and the one it held moved to slot 1"* ]]
  [ "$(o11n secret show host-testhost luks-key)" = "$test_luks_key_2" ]
  run o11n host check host-testhost luks-key --slot 1
  succeeds
  run o11n host check host-testhost luks-key
  succeeds

  run o11n host revoke host-testhost luks-key --slot 0
  fails "slot 0 is the luks-key a deployment writes"

  mock-boot grub "$test_luks_key_1"
  run o11n host revoke host-testhost luks-key --slot 1
  fails "holds this luks-key: deploy the one that replaces it first"
  run o11n host check host-testhost luks-key --slot 1
  succeeds

  mock-boot grub "$test_luks_key_2"
  run o11n host revoke host-testhost luks-key --slot 1
  succeeds
  run o11n host check host-testhost luks-key --slot 1
  fails "there's no host-testhost's luks-key in slot 1"
  run o11n host check host-testhost luks-key
  succeeds
}

@test "status reads the luks-key of the initrd the host boots next, which opens its disk and is the one deployed" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")
  o11n secret generate host-testhost luks-key --from <(echo -n "$test_luks_key_1")

  mock-boot grub "$test_luks_key_1"
  run o11n status host-testhost
  [[ $output == *"host-testhost initrd-key ok"* ]]

  o11n host push host-testhost luks-key --from <(echo -n "$test_luks_key_2")
  run o11n status host-testhost
  [[ $output == *"host-testhost initrd-key fail: "*"opens /dev/null, but isn't the one a deployment writes"* ]]

  mock-boot systemd-boot "$test_luks_key_2"
  run o11n status host-testhost
  [[ $output == *"host-testhost initrd-key ok"* ]]

  mock-boot systemd-boot "luks3-Atzc2gtZWQyNTUxO"
  run o11n status host-testhost
  [[ $output == *"host-testhost initrd-key fail: ssh: the luks-key in the initrd that boots "*" doesn't open /dev/null"* ]]
}

@test "a host's ssh-key is its own, which the org has the public key of, pulled from the host" {
  mock-host testhost
  o11n identity create host-testhost

  run o11n secret generate host-testhost ssh-key
  fails "ssh-key isn't one of host-testhost's keys"
  run o11n host check host-testhost ssh-key
  fails "o11n host pull-ssh-key host-testhost"

  run o11n host pull-ssh-key host-testhost
  succeeds
  run o11n host check host-testhost ssh-key
  succeeds

  echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHbJn6Vuli56nRUNM600//YqhKLqmDIlbWwKN/VZAyNg" >public-keys/host-testhost-ssh-key.pub
  run o11n host check host-testhost ssh-key
  fails "host-testhost has another ssh-key: o11n host pull-ssh-key host-testhost, if it's the host"
}

@test "a public key that's missing or another's fails verification, and is written again" {
  o11n identity create host-testhost
  o11n identity create service-nix-serve
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

  for entity_key in "service-nix-serve nix-sign" "user-testuser ssh-key"; do
    read -r entity key <<<"$entity_key"
    run o11n secret generate "$entity" "$key"
    succeeds
    rm "$(o11n path public-key "$entity" "$key")"
    run o11n public-key verify "$entity" "$key"
    fails "there's no $(o11n path public-key "$entity" "$key")"
    run o11n public-key write "$entity" "$key"
    succeeds
    run o11n public-key verify "$entity" "$key"
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

@test "a host has a wireguard key for each of its vpns, and none for another" {
  o11n identity create host-lorem

  [ "$(o11n keys host-lorem)" = "$(printf '%s\n' age-key syncthing-user-testuser.testhost wg0-key)" ]
  [ "$(o11n keys host)" = "$(printf '%s\n' age-key)" ]
  run o11n secret generate host-lorem wg0-key
  succeeds
  run o11n secret generate host-lorem wg1-key
  fails "wg1-key isn't one of host-lorem's keys: age-key, syncthing-user-testuser.testhost, wg0-key"
}

@test "a host has a luks-key only with an encrypted disk" {
  [ "$(o11n keys host-testhost)" = "$(printf '%s\n' age-key luks-key syncthing-user-testuser.testhost wg0-key wg1-key wg2-key)" ]
  run o11n secret generate host-lorem luks-key
  fails "luks-key isn't one of host-lorem's keys"
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
  fails "tls-cert isn't one of service-testservice's keys"
}

@test "entities with hyphens in their name" {
  o11n identity create service-sysctl-user-portal
  [ -f public-keys/service-sysctl-user-portal-age-key.pub ]

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
  fails "ssh-key isn't one of root-1's keys: age-key"
  run o11n secret show user-testuser passwd
  fails "there's no user-testuser's passwd"
  run o11n secret show user-testuser age-key
  fails "an age-key is an identity"
  run o11n secret generate user-testuser foo-key
  fails "foo-key isn't one of user-testuser's keys"
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

  run o11n ssh user-testadmin testhost --user nobody
  fails "invalid user 'nobody'"
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

@test "status checks each entity by what it has: its keys, its host's services, its url and its mail" {
  run o11n status --list host-testhost host-lorem user-testuser user-admin
  succeeds
  [[ $output == *"host-testhost on-host luks-key"* ]]
  [[ $output == *"host-testhost initrd-key"* ]]
  [[ $output == *"org o11n"* ]]
  [[ $output == *"host-testhost version"* ]]
  [[ $output == *"host-testhost reboot"* ]]
  [[ $output == *"host-testhost nix-daemon"* ]]
  [[ $output == *"host-testhost submission mail.example.com"* ]]
  [[ $output == *"user-testuser mail-login mail.example.com"* ]]
  [[ $output == *"user-testuser secret passwd"* ]]
  [[ $output != *"host-lorem nix-daemon"* ]]
  [[ $output != *"user-admin mail-login"* ]]
  [[ $output != *"public-key passwd"* ]]
}

@test "status checks a host's ssh-key on the connections it logs in with" {
  mock-host testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")
  ssh-keygen -q -t ed25519 -N '' -f "$BATS_TEST_TMPDIR/other"
  cut -d' ' -f1,2 "$BATS_TEST_TMPDIR/other.pub" >public-keys/host-testhost-ssh-key.pub

  run o11n status host-testhost
  [[ $output == *"host-testhost ssh-key fail: ssh: Host key verification failed."* ]]
  [[ $output == *"o11n host pull-ssh-key host-testhost, if it's the host's own"* ]]
  [[ $output == *"host-testhost on-host age-key fail: ssh: Host key verification failed."* ]]

  o11n host pull-ssh-key host-testhost
  run o11n status host-testhost
  [[ $output == *"host-testhost ssh-key ok"* ]]
  [[ $output == *"host-testhost on-host age-key ok"* ]]
}

@test "status tells whether this o11n is the package the o11n the org pins builds" {
  local bin o11n
  bin=$(readlink -f "$(command -v o11n)")
  if [[ $bin != /nix/store/* ]]; then
    run o11n status host-testhost
    [[ $output == *"org o11n skip: this o11n isn't in the nix store, as one cargo built"* ]]
    bin=$(nix-store --add "$bin" 2>/dev/null) || skip "nix can't add to the store here"
  fi
  o11n=$(cut -d / -f 1-4 <<<"$bin")

  mkdir o11n-stub
  echo "{ outputs = _: { packages.x86_64-linux.o11n.outPath = \"$o11n\"; }; }" >o11n-stub/flake.nix
  echo "{ inputs.o11n.url = \"path:$TESTROOT/o11n-stub\"; outputs = _: { }; }" >flake.nix
  nix flake lock 2>/dev/null || skip "nix can't lock a flake here"
  run "$bin" status host-testhost
  [[ $output == *"org o11n ok"* ]]

  echo "{ outputs = _: { packages.x86_64-linux.o11n.outPath = \"/nix/store/other\"; }; }" >o11n-stub/flake.nix
  nix flake update 2>/dev/null
  run "$bin" status host-testhost
  [[ $output == *"org o11n fail: this o11n is $o11n, and the org's builds /nix/store/other"* ]]
}

@test "status tells whether a host runs the org's tree and the o11n it pins" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-nix-switch
  mkdir o11n-stub
  echo '{ outputs = _: { }; }' >o11n-stub/flake.nix
  echo "{ inputs.o11n.url = \"path:$TESTROOT/o11n-stub\"; outputs = _: { }; }" >flake.nix
  nix flake lock 2>/dev/null || skip "nix can't lock a flake here"
  local tree pinned
  tree=$(nix flake metadata --json . 2>/dev/null | jq -r .locked.narHash)
  pinned=$(jq -r .nodes.o11n.locked.narHash flake.lock)

  echo "current system /nix/store/a" >"$BATS_TEST_TMPDIR/deployed-testhost.local"
  run o11n status host-testhost
  [[ $output == *"host-testhost version skip: host-testhost runs a system that doesn't say its versions"* ]]

  printf 'current org %s\ncurrent o11n %s\n' "$tree" "$pinned" >"$BATS_TEST_TMPDIR/deployed-testhost.local"
  run o11n status host-testhost
  [[ $output == *"host-testhost version ok"* ]]

  printf 'current org sha256-old\ncurrent o11n sha256-old\n' >"$BATS_TEST_TMPDIR/deployed-testhost.local"
  run o11n status host-testhost
  [[ $output == *"host-testhost version fail: host-testhost runs the org's tree sha256-old, not this one's $tree, and o11n sha256-old, not the one the org pins, $pinned: o11n apply host-testhost"* ]]
}

@test "status tells whether a host boots another kernel than it runs" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-nix-switch
  printf '%s\n' "booted kernel /nix/store/k1" "booted kernel-modules /nix/store/m1" \
    "next kernel /nix/store/k1" "next kernel-modules /nix/store/m1" >"$BATS_TEST_TMPDIR/deployed-testhost.local"
  run o11n status host-testhost
  [[ $output == *"host-testhost reboot ok"* ]]

  printf '%s\n' "booted kernel /nix/store/k1" "booted kernel-modules /nix/store/m1" \
    "next kernel /nix/store/k2" "next kernel-modules /nix/store/m1" >"$BATS_TEST_TMPDIR/deployed-testhost.local"
  run o11n status host-testhost
  [[ $output == *"host-testhost reboot fail: host-testhost runs kernel /nix/store/k1 boots as /nix/store/k2: reboot it"* ]]
}

@test "status says ok, fail or skip of each check, a skip for a secret it can't decrypt, and fails for a fail" {
  mock-host testhost
  o11n identity create service-locksmith
  o11n secret generate service-locksmith ssh-key
  o11n identity create host-testhost --from <(echo "$test_age_key_1")
  o11n host pull-ssh-key host-testhost
  o11n identity create user-testuser
  o11n secret generate user-testuser mail

  run o11n status host-testhost user-testuser
  fails "checks failed"
  [[ $output == *"host-testhost identity ok"* ]]
  [[ $output == *"host-testhost recipients ok"* ]]
  [[ $output == *"host-testhost ssh-key ok"* ]]
  [[ $output == *"host-testhost on-host age-key ok"* ]]
  [[ $output == *"host-testhost nix-daemon ok"* ]]
  [[ $output == *"host-testhost nix-store skip: "* ]]
  [[ $output == *"host-testhost submission mail.example.com ok"* ]]
  [[ $output == *"host-testhost public-key wg0-key fail: there's no public-keys/host-testhost-wg0-key.pub"* ]]
  [[ $output == *"user-testuser secret mail ok"* ]]
  [[ $output == *"user-testuser secret passwd fail: there's no user-testuser's passwd"* ]]
  [[ $output == *"user-testuser mail-login mail.example.com ok"* ]]
  grep -q "^curl -sS --max-time 20 --ssl-reqd -X NOOP smtp://mail.example.com:587 -K " "$BATS_TEST_TMPDIR/curl"
  grep -q "^user = \"testuser@example.com:$(o11n secret show user-testuser mail 2>/dev/null)\"$" "$BATS_TEST_TMPDIR/curl"

  CURL_SMTP="(67) Login denied" run o11n status user-testuser
  [[ $output == *"user-testuser mail-login mail.example.com fail: curl: (67) Login denied"* ]]

  SOPS_AGE_KEY_FILE=$BATS_TEST_TMPDIR/nobody run o11n status user-testuser
  [[ $output == *"user-testuser secret mail skip: "* ]]
  [[ $output == *"user-testuser mail-login mail.example.com skip: "* ]]
}

# Usage: dns <name> <type> <type's code> <data>...: what the DNS stub of bin/curl answers name type with.
dns() {
  local name=$1 type=$2 code=$3 answers='' data
  shift 3
  for data; do
    answers+="${answers:+,}{\"type\":$code,\"data\":$(jq -Rn --arg data "$data" '$data')}"
  done
  mkdir -p "$BATS_TEST_TMPDIR/dns"
  echo "{\"Status\":0,\"Answer\":[$answers]}" >"$BATS_TEST_TMPDIR/dns/$name.$type"
}

@test "status checks the DNS of the mail server's domains as a receiver reads it" {
  run o11n status --list host-testhost user-testuser user-admin
  [[ $output == *"host-testhost mx example.com"* ]]
  [[ $output == *"host-testhost spf example.com"* ]]
  [[ $output == *"host-testhost dkim example.com"* ]]
  [[ $output == *"host-testhost dmarc example.com"* ]]
  [[ $output != *"host-testhost mx example.org"* ]]
  [[ $output != *"host-testhost spf example.org"* ]]
  [[ $output == *"user-testuser spf example.org"* ]]
  [[ $output == *"user-testuser dkim example.org"* ]]
  [[ $output == *"user-testuser dmarc example.org"* ]]
  [[ $output != *"user-testuser spf example.com"* ]]
  [[ $output != *"user-admin spf"* ]]

  mock-host testhost
  dns mail.example.com A 1 192.0.2.1
  dns mail.example.com AAAA 28 2001:db8::1
  dns example.com MX 15 "10 mail.example.com."
  dns example.com TXT 16 '"v=spf1 include:_spf.example.com -all"' '"other"'
  dns _spf.example.com TXT 16 '"v=spf1 ip4:192.0.2.0/24 ip6:2001:db8::/32 -all"'
  dns mail._domainkey.example.com TXT 16 '"v=DKIM1; k=rsa; " "p=MIIB"'
  dns _dmarc.example.com TXT 16 '"v=DMARC1; p=reject"'
  run o11n status host-testhost
  [[ $output == *"host-testhost mx example.com ok"* ]]
  [[ $output == *"host-testhost spf example.com ok"* ]]
  [[ $output == *"host-testhost dkim example.com ok"* ]]
  [[ $output == *"host-testhost dmarc example.com ok"* ]]
  grep -q "^curl -sS --max-time 20 --get -H accept: application/dns-json --data-urlencode name=example.com --data-urlencode type=TXT https://cloudflare-dns.com/dns-query$" "$BATS_TEST_TMPDIR/curl"

  dns example.com MX 15 "10 other.example.net."
  dns example.com TXT 16 '"v=spf1 ip4:192.0.2.1 ~all"'
  rm "$BATS_TEST_TMPDIR/dns/mail._domainkey.example.com.TXT"
  dns _dmarc.example.com TXT 16 '"v=DMARC1; p=reject"' '"v=DMARC1; p=none"'
  run o11n status host-testhost
  fails "checks failed"
  [[ $output == *"host-testhost mx example.com fail: example.com's MX is other.example.net, not mail.example.com, so its mailboxes get no mail: publish example.com MX 10 mail.example.com"* ]]
  [[ $output == *"host-testhost spf example.com fail: SPF of example.com gives softfail for 2001:db8::1, which mail.example.com sends from: add a:mail.example.com to it"* ]]
  [[ $output == *"host-testhost dkim example.com fail: mail._domainkey.example.com has no DKIM key"* ]]
  [[ $output == *"host-testhost dmarc example.com fail: _dmarc.example.com has 2 v=DMARC1 records, which receivers take as none: keep one"* ]]

  dns example.org TXT 16 '"v=spf1 a:mail.example.com -all"'
  dns mail._domainkey.example.org TXT 16 '"p=MIIB"'
  run o11n status user-testuser
  [[ $output == *"user-testuser spf example.org ok"* ]]
  [[ $output == *"user-testuser dkim example.org ok"* ]]
  [[ $output == *"user-testuser dmarc example.org fail: _dmarc.example.org has no v=DMARC1 record"* ]]
}

@test "status tells a sops file encrypted to another than it should be" {
  o11n identity create user-testuser
  o11n identity create user-testadmin
  cp enc/user-testadmin.yaml enc/user-testuser.yaml

  run o11n status user-testuser
  fails "checks failed"
  [[ $output == *"user-testuser recipients fail: enc/user-testuser.yaml is encrypted to user-testadmin it shouldn't be, and not to user-testuser it should: o11n reencrypt"* ]]
}

@test "status skips a host without an endpoint that doesn't answer, and fails one with" {
  O11N_ROUTES='' run o11n status host-testhost host-lorem
  [[ $output == *"host-lorem ssh-key skip: no contact with lorem:22"* ]]
  [[ $output == *"host-testhost ssh-key fail: no contact with testhost:22"* ]]
}

@test "a key comes with what reads it: a principal's passwd, ssh-key, mail and state, o11n's services', or the org's declaring it" {
  [ "$(o11n keys user-testuser)" = "$(printf '%s\n' age-key archive-passwd mail passwd restic-key ssh-key)" ]
  [ "$(o11n keys user-admin)" = "$(printf '%s\n' age-key ssh-key)" ]
  [ "$(o11n keys service-nix-serve)" = "$(printf '%s\n' age-key nix-sign)" ]
  [ "$(o11n keys service-sysctl-user-portal)" = "$(printf '%s\n' age-key secret-key)" ]
  [ "$(o11n keys service-testservice)" = "$(printf '%s\n' age-key)" ]
  [ "$(o11n keys service-rescue)" = "$(printf '%s\n' age-key passwd ssh-key)" ]
  [ "$(o11n keys service-locksmith)" = "$(printf '%s\n' age-key ssh-key)" ]
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

@test "state fetch downloads a principal's home from each host it's on, as service-rescue, once it has said how much" {
  o11n identity create service-rescue
  o11n secret generate service-rescue ssh-key
  export O11N_ROUTES="testhost=testhost.local lorem=lorem.local"
  mkdir "$BATS_TEST_TMPDIR/state"

  run o11n state fetch user-testuser --dir "$BATS_TEST_TMPDIR/state"
  succeeds
  [[ $output == *"3.0 KiB to download, before compression, from lorem (1.5 KiB), testhost (1.5 KiB)"* ]]

  local files=("$BATS_TEST_TMPDIR"/state/*)
  [ "${#files[@]}" = 2 ]
  [[ ${files[0]##*/} =~ ^user-testuser@lorem-[0-9]{4}(-[0-9]{2}){5}\.tar\.zst$ ]]
  [[ ${files[1]##*/} == user-testuser@testhost-*.tar.zst ]]
  [ "$(cat "${files[1]}")" = "the tar of tar --zstd -cf - -C '/home' -- 'testuser' on testhost.local" ]

  run o11n state fetch service-testservice
  fails "service-testservice has no home to fetch"
}

@test "state snapshots and prune run restic on each archive, as archive-restic, with the restic-key on stdin" {
  o11n identity create service-rescue
  o11n secret generate service-rescue ssh-key
  o11n identity create user-testuser
  o11n secret generate user-testuser restic-key
  local key
  key=$(o11n secret show user-testuser restic-key)

  O11N_ROUTES=$lorem_routes run o11n state snapshots user-testuser
  succeeds
  [[ $output == *"lorem:"*"archive-restic 'user-testuser' 'snapshots'  on lorem.local, with $key"* ]]
  [[ $output == *"testhost:"*"archive-restic 'user-testuser' 'snapshots'  on testhost.local, with $key"* ]]

  O11N_ROUTES=$lorem_routes run o11n state snapshots user-testuser --from nowhere
  fails "user-testuser archives to lorem, testhost, not nowhere"

  O11N_ROUTES=$lorem_routes run o11n state prune user-testuser
  succeeds
  [[ $output == *"archive-restic 'user-testuser' 'forget' '--prune' '--keep-last=2'  on lorem.local"* ]]
  [[ $output == *"testhost: user-testuser's archive there has no prune, so it keeps everything"* ]]

  O11N_ROUTES=$lorem_routes run o11n state snapshots service-testservice
  fails "service-testservice has no state"
}

@test "state restore downloads a snapshot, or extracts it into an empty home on a host, of the host named or restored to" {
  o11n identity create service-rescue
  o11n secret generate service-rescue ssh-key
  o11n identity create user-testuser
  o11n secret generate user-testuser restic-key
  local dump="archive-restic 'user-testuser' 'dump' '--archive' 'tar' '--host'"

  O11N_ROUTES=$lorem_routes run o11n state restore user-testuser --dir "$BATS_TEST_TMPDIR"
  fails "user-testuser archives to lorem, testhost: name one with --from"
  O11N_ROUTES=$lorem_routes run o11n state restore user-testuser --from lorem --dir "$BATS_TEST_TMPDIR"
  fails "user-testuser is on lorem, testhost: name the host whose snapshot with --of"

  O11N_ROUTES=$lorem_routes run o11n state restore user-testuser --from lorem --of testhost --snapshot 1a2b3c --dir "$BATS_TEST_TMPDIR"
  succeeds
  [[ $(cat "$BATS_TEST_TMPDIR/user-testuser@testhost-1a2b3c.tar.zst") == "$dump 'testhost' '1a2b3c' '/home/testuser' | zstd -q on lorem.local, with "* ]]

  O11N_ROUTES=$lorem_routes run o11n state restore user-testuser --from lorem --to testhost
  succeeds
  [[ $(cat "$BATS_TEST_TMPDIR/extracted-testhost.local") == "$dump 'testhost' 'latest' '/home/testuser' | zstd -q on lorem.local, with "* ]]

  echo /home/testuser/kept >"$BATS_TEST_TMPDIR/home-testhost.local"
  O11N_ROUTES=$lorem_routes run o11n state restore user-testuser --from lorem --to testhost
  fails "user-testuser's home on testhost, /home/testuser, isn't empty: move what's in it aside first"
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

lorem_routes="testhost=testhost.local lorem=lorem.local"

test_identity_root_1=AGE-SECRET-KEY-1DJDMVRRC7UNF8HSKVSGQCWFNMJ5HTRT6HT2MDML9JZ54GCW8TYNSSWWL8D

test_age_key_1=AGE-SECRET-KEY-1L0EJY3FLSYHDE46Y80F0KLUKUWP6V3J340UR7G2GWNFGXJQ0P6ZQ6X37TN
test_age_key_2=AGE-SECRET-KEY-1V782VQAQT6QJPARYTCD8CLES04Q83V068FRFDWG02HGLE96U93FSVACDKF

test_luks_key_1="luks1-Atzc2gtZWQyNTUxO"
test_luks_key_2="luks2-roGxnLozh/+wBGot"

@test "status checks each slot of a luks-key the org holds, without slot 0" {
  o11n identity create host-testhost
  o11n secret generate host-testhost luks-key --slot 1

  run o11n status host-testhost
  [[ $output == *"host-testhost secret luks-key ok"* ]]

  sops set enc/host-testhost.yaml '["luks-key--1"]' '"luks1-Atzc2gtZWQyNTUxO\n"'
  run o11n status host-testhost
  [[ $output == *"host-testhost secret luks-key fail: host-testhost's luks-key in slot 1: the luks-key has a trailing newline"* ]]
}

@test "status --failed says only what fails, and fails as status does" {
  o11n identity create user-testuser

  run o11n status --failed user-testuser
  fails "checks failed"
  [[ $output == *"user-testuser secret passwd fail: there's no user-testuser's passwd"* ]]
  [[ $output != *" ok"* ]]
  [[ $output != *" skip: "* ]]
}

@test "an entity with no secrets of its own or another's is let be without an identity, until it has one" {
  run o11n status --list service-testservice
  succeeds
  [[ $output != *"service-testservice identity"* ]]

  o11n identity create service-testservice
  run o11n status --list service-testservice
  [[ $output == *"service-testservice identity"* ]]
}

@test "a host without NixOS has no ssh-key or locksmith checked" {
  run o11n status --list host-ipsum host-testhost
  succeeds
  [[ $output == *"host-testhost ssh-key"* ]]
  [[ $output != *"host-ipsum ssh-key"* ]]
  [[ $output != *"host-ipsum on-host"* ]]
}

@test "secret extra lists what a sops file holds that isn't one of its keys, and status fails for it" {
  o11n identity create host-testhost
  o11n identity create user-testuser
  o11n secret generate user-testuser passwd
  o11n secret generate host-testhost luks-key --slot 2
  sops set enc/user-testuser.yaml '["testuser"]["wifi-keys"]' '"psk=x"'
  sops set enc/user-testuser.yaml '["stray"]' '"x"'
  sops set enc/host-testhost.yaml '["ssh-key"]' '"x"'

  [ "$(o11n secret extra user-testuser host-testhost 2>/dev/null)" = "$(printf '%s\n' 'host-testhost ssh-key' 'user-testuser stray' 'user-testuser testuser.wifi-keys')" ]

  run o11n status user-testuser
  [[ $output == *"user-testuser secrets fail: enc/user-testuser.yaml holds what o11n doesn't know: stray, testuser.wifi-keys: declare each under the entity's keys, or take it out with o11n secret edit user-testuser"* ]]
}

@test "status tells whether an allotment's replicas are in sync" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-nix-switch
  local said=$BATS_TEST_TMPDIR/allotments-testhost.local
  allotment() {
    local peer=$1 conflicts=${2:-0}
    printf '{"user-testuser.testhost": {"state": "idle", "errors": [], "conflicts": %s, "peers": {"lorem": %s}}}' \
      "$conflicts" "$peer" >"$said"
  }

  run o11n status host-testhost
  [[ $output == *"host-testhost allotment-sync user-testuser.testhost lorem skip: host-testhost runs a system that doesn't say how its allotments sync"* ]]

  allotment '{"connected": true, "lastSeen": "2026-11-05T12:00:00Z", "lastSeenAgoS": 0, "completion": 100, "needItems": 0, "needBytes": 0}'
  run o11n status host-testhost
  [[ $output == *"host-testhost allotment-sync user-testuser.testhost lorem ok"* ]]
  [[ $output == *"host-testhost allotment-conflicts user-testuser.testhost ok"* ]]

  allotment '{"connected": true, "lastSeen": "2026-11-05T12:00:00Z", "lastSeenAgoS": 0, "completion": 97.5, "needItems": 3, "needBytes": 2048}' 2
  run o11n status host-testhost
  [[ $output == *"lorem fail: lorem has 97.5% of user-testuser.testhost, 3 items, 2048 bytes, to go"* ]]
  [[ $output == *"allotment-conflicts user-testuser.testhost fail: /srv/allotments/user-testuser has 2 conflicting copies"* ]]

  allotment '{"connected": false, "lastSeen": "2026-11-04T12:00:00Z", "lastSeenAgoS": 86400, "completion": 100, "needItems": 0, "needBytes": 0}'
  run o11n status host-testhost
  [[ $output == *"lorem skip: lorem isn't connected, last seen 2026-11-04T12:00:00Z"* ]]

  allotment '{"connected": false, "lastSeen": "2026-10-01T12:00:00Z", "lastSeenAgoS": 3000000, "completion": 100, "needItems": 0, "needBytes": 0}'
  run o11n status host-testhost
  [[ $output == *"lorem fail: lorem was last seen 2026-10-01T12:00:00Z, over a week ago"* ]]

  allotment '{"connected": false, "lastSeen": "1970-01-01T00:00:00Z", "lastSeenAgoS": 1793000000, "completion": 0, "needItems": 0, "needBytes": 0}'
  run o11n status host-testhost
  [[ $output == *"lorem fail: lorem has never connected"* ]]

  echo '{"user-testuser.testhost": {"error": "curl: (7) Failed to connect"}}' >"$said"
  run o11n status host-testhost
  [[ $output == *"lorem fail: allotment-sync@user-testuser.testhost: curl: (7) Failed to connect"* ]]

  echo '{}' >"$said"
  run o11n status host-testhost
  [[ $output == *"lorem fail: host-testhost runs no allotment-sync@user-testuser.testhost: o11n apply host-testhost"* ]]
}

@test "status tells whether a principal's archive holds a snapshot of each host, since its timer last started it" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-rescue
  o11n secret generate service-rescue ssh-key
  o11n identity create user-testuser
  o11n secret generate user-testuser restic-key

  run o11n status user-testuser
  [[ $output == *"user-testuser archive testhost testhost fail: testhost holds no snapshot of user-testuser on testhost: o11n ssh service-rescue testhost --user root systemctl start state-archive@user-testuser:testhost"* ]]
  [[ $output == *"user-testuser archive testhost lorem skip: "*", and it has no endpoint"* ]]
  [[ $output == *"user-testuser archive lorem testhost skip: "*", and it has no endpoint"* ]]

  echo '[{"time": "2026-11-06T03:00:12.123456789+01:00"}]' >"$BATS_TEST_TMPDIR/snapshots-testhost.local"
  run o11n status user-testuser
  [[ $output == *"user-testuser archive testhost testhost ok"* ]]

  echo '@1793930400' >"$BATS_TEST_TMPDIR/trigger-testhost.local"
  run o11n status user-testuser
  [[ $output == *"user-testuser archive testhost testhost ok"* ]]

  echo '@1793934000' >"$BATS_TEST_TMPDIR/trigger-testhost.local"
  run o11n status user-testuser
  [[ $output == *"user-testuser archive testhost testhost fail: state-archive@user-testuser:testhost on testhost took no snapshot since its timer last started it, the latest being of 2026-11-06T03:00:12.123456789+01:00: journalctl -u state-archive@user-testuser:testhost on testhost"* ]]
}

@test "status tells whether a nextcloud's homes and external storages are reachable on each of its hosts" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-nix-switch
  local said=$BATS_TEST_TMPDIR/nextcloud-testhost.local

  run o11n status --list app-cloud
  [[ $output == *"app-cloud nextcloud-home carol testhost"* ]]
  [[ $output == *"app-cloud nextcloud-external alice/files testhost"* ]]

  run o11n status app-cloud
  [[ $output == *"app-cloud nextcloud-home carol testhost skip: host-testhost runs a system that doesn't say how its nextclouds' storages are"* ]]

  printf '%s\n' 'cloud home carol ok' 'cloud external alice/files ok' >"$said"
  run o11n status app-cloud
  [[ $output == *"app-cloud nextcloud-home carol testhost ok"* ]]
  [[ $output == *"app-cloud nextcloud-external alice/files testhost ok"* ]]

  printf '%s\n' 'cloud home carol /var/lib/cloud/nextcloud/data/carol isn'"'"'t mounted: systemctl status /var/lib/cloud/nextcloud/data/carol' \
    'cloud external alice/files error: Error while connecting' >"$said"
  run o11n status app-cloud
  [[ $output == *"app-cloud nextcloud-home carol testhost fail: cloud's home carol on host-testhost: /var/lib/cloud/nextcloud/data/carol isn't mounted: systemctl status /var/lib/cloud/nextcloud/data/carol"* ]]
  [[ $output == *"app-cloud nextcloud-external alice/files testhost fail: cloud's external alice/files on host-testhost: error: Error while connecting"* ]]

  echo 'other home carol ok' >"$said"
  run o11n status app-cloud
  [[ $output == *"app-cloud nextcloud-home carol testhost fail: host-testhost says nothing of cloud's home carol: o11n apply host-testhost"* ]]
}

@test "status tells whether a nextcloud follows what the replicas of an allotment it mounts change" {
  local routes="testhost=testhost.local lorem=lorem.local"
  mock-host lorem
  O11N_ROUTES=$routes o11n host pull-ssh-key host-lorem
  o11n identity create service-nix-switch
  local said=$BATS_TEST_TMPDIR/nextcloud-lorem.local

  O11N_ROUTES=$routes run o11n status --list app-files
  [[ $output == *"app-files nextcloud-changes testuser/testhost lorem"* ]]
  [[ $output != *"app-cloud nextcloud-changes"* ]]

  printf '%s\n' 'files external testuser/testhost ok' 'files changes testuser/testhost ok' >"$said"
  O11N_ROUTES=$routes run o11n status app-files
  [[ $output == *"app-files nextcloud-changes testuser/testhost lorem ok"* ]]

  printf '%s\n' 'files changes testuser/testhost nextcloud-changes-testuser-testhost.service is activating: journalctl -M files -u nextcloud-changes-testuser-testhost.service' >"$said"
  O11N_ROUTES=$routes run o11n status app-files
  [[ $output == *"app-files nextcloud-changes testuser/testhost lorem fail: files's changes testuser/testhost on host-lorem: nextcloud-changes-testuser-testhost.service is activating"* ]]
}

@test "status tells whether an app's database has the collation version its host's postgresql has" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-nix-switch
  local said=$BATS_TEST_TMPDIR/databases-testhost.local

  run o11n status --list app-auth
  [[ $output == *"app-auth collation testhost"* ]]

  run o11n status app-auth
  [[ $output == *"app-auth collation testhost skip: host-testhost runs a system that doesn't say its databases' collations"* ]]

  printf '%s\n' 'postgres 2.40 2.40' 'auth 2.40 2.40' >"$said"
  run o11n status app-auth
  [[ $output == *"app-auth collation testhost ok"* ]]

  printf '%s\n' 'postgres 2.40 2.42' 'auth 2.40 2.42' >"$said"
  run o11n status app-auth
  [[ $output == *"app-auth collation testhost fail: auth on host-testhost was made with collation version 2.40, and its postgresql has 2.42, so its indexes on text may be out of order: journalctl -u postgresql-collation on host-testhost"* ]]

  echo 'postgres 2.42 2.42' >"$said"
  run o11n status app-auth
  [[ $output == *"app-auth collation testhost fail: host-testhost has no database auth: o11n apply host-testhost"* ]]
}

@test "status has Keycloak test each realm's mail, logged in as its o11n client with the app's admin-client-secret" {
  run o11n status --list app-auth
  [[ $output == *"app-auth keycloak-mail example"* ]]

  run o11n status app-auth
  [[ $output == *"app-auth keycloak-mail example skip: "* ]]

  o11n identity create app-auth
  o11n secret generate app-auth admin-client-secret
  run o11n status app-auth
  [[ $output == *"app-auth keycloak-mail example ok"* ]]
  grep -qxF "stdin $(o11n secret show app-auth admin-client-secret)" "$BATS_TEST_TMPDIR/curl"
  grep -qxF "Authorization: Bearer token" "$BATS_TEST_TMPDIR/curl"
  grep -qxF 'stdin {"host":"mail.example.com","password":"**********"}' "$BATS_TEST_TMPDIR/curl"

  KEYCLOAK_SMTP='{"errorMessage": "Failed to send email"}' KEYCLOAK_SMTP_CODE=500 run o11n status app-auth
  [[ $output == *"app-auth keycloak-mail example fail: https://auth.example.com/admin/realms/example/testSMTPConnection answers 500: Failed to send email"* ]]

  KEYCLOAK_TOKEN='{"error": "unauthorized_client", "error_description": "Invalid client credentials"}' KEYCLOAK_TOKEN_CODE=401 \
    run o11n status app-auth
  [[ $output == *"app-auth keycloak-mail example fail: https://auth.example.com/realms/master/protocol/openid-connect/token answers 401: Invalid client credentials"* ]]

  KEYCLOAK_REALM='{"realm": "example"}' run o11n status app-auth
  [[ $output == *"app-auth keycloak-mail example fail: realm example has no mail server"* ]]
}

@test "logs reads each host with the logs service, as the service, since the span given" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-logs
  o11n secret generate service-logs ssh-key
  run o11n logs --since 2d
  succeeds
  [[ $output == *"the logs of testhost.local since 2d"* ]]

  touch "$BATS_TEST_TMPDIR/logs-unreachable"
  run o11n logs
  fails "couldn't read the logs of host-testhost"
  [[ $output == *"===== testhost couldn't be read"* ]]
  [[ $output == *"Connection refused"* ]]
  rm "$BATS_TEST_TMPDIR/logs-unreachable"

  run o11n logs "service-*"
  fails "no host of service-* has the logs service"
}

@test "torrent adds, lists and removes the server's torrents, as the service" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost
  o11n identity create service-torrent-server
  o11n secret generate service-torrent-server ssh-key

  run o11n torrent add 'magnet:?xt=urn:btih:0123&dn=lorem+ipsum' https://example.com/a.torrent
  succeeds
  [[ $output == *"transmission-remote 127.0.0.1:9091 --add magnet:?xt=urn:btih:0123&dn=lorem+ipsum --download-dir /srv/allotments/service-media-server/downloads"* ]]
  [[ $output == *"transmission-remote 127.0.0.1:9091 --add https://example.com/a.torrent --download-dir /srv/allotments/service-media-server/downloads"* ]]

  run o11n torrent add --to user-alice https://example.com/a.torrent
  succeeds
  [[ $output == *"--add https://example.com/a.torrent --download-dir /srv/allotments/user-alice"* ]]

  run o11n torrent add --as movies https://example.com/a.torrent
  succeeds
  [[ $output == *"--add https://example.com/a.torrent --download-dir /srv/allotments/service-media-server/downloads/movies"* ]]

  run o11n torrent add --to user-bob https://example.com/a.torrent
  fails "--to names an allotment the server downloads into: "
  [[ $output == *"service-media-server"* && $output == *"user-alice"* ]]

  run o11n torrent add --as books https://example.com/a.torrent
  fails "--as names a kind the server files a download by: movies"

  run o11n torrent add --to user-alice --as movies https://example.com/a.torrent
  fails "cannot be used with"

  TORRENT_DEFAULT='' run o11n torrent add https://example.com/a.torrent
  fails "the server has no allotment it downloads into by default: give --to "

  echo "the metainfo" >lorem.torrent
  run o11n torrent add lorem.torrent
  succeeds
  [[ $output == *"--add /"*".torrent"*"the metainfo"* ]]

  run o11n torrent list
  succeeds
  [[ $output == *"transmission-remote 127.0.0.1:9091 --list"* ]]

  run o11n torrent remove 1 3
  succeeds
  [[ $output == *"transmission-remote 127.0.0.1:9091 --torrent 1,3 --remove"* ]]

  run o11n torrent --host testhost remove --delete 2
  succeeds
  [[ $output == *"transmission-remote 127.0.0.1:9091 --torrent 2 --remove-and-delete"* ]]

  run o11n torrent add 'magnet:?xt=urn:btih:0123&dn=lorem ipsum'
  fails "a link has no whitespace in it"

  run o11n torrent --host lorem list
  fails "host-lorem has no torrent-server service"
}

@test "status checks the torrent server's list as the service, and the media server's health and its *arrs' at its name on its vpn" {
  mock-host testhost
  o11n host pull-ssh-key host-testhost

  run o11n status --list host-testhost
  [[ $output == *"host-testhost torrent-server"* ]]
  [[ $output == *"host-testhost media-server media-server-testhost.local"* ]]
  [[ $output == *"host-testhost media-server media-server-testhost.local radarr"* ]]
  [[ $output == *"host-testhost media-server media-server-testhost.local lidarr"* ]]

  run o11n status host-testhost
  [[ $output == *"host-testhost torrent-server skip: "* ]]
  [[ $output == *"host-testhost media-server media-server-testhost.local ok"* ]]
  [[ $output == *"host-testhost media-server media-server-testhost.local sonarr ok"* ]]

  o11n identity create service-torrent-server
  o11n secret generate service-torrent-server ssh-key
  run o11n status host-testhost
  [[ $output == *"host-testhost torrent-server ok"* ]]

  JELLYFIN_HEALTH=Unhealthy run o11n status host-testhost
  [[ $output == *"host-testhost media-server media-server-testhost.local fail: http://media-server-testhost.local:8096/health answers Unhealthy"* ]]

  ARR_PING='Bad Gateway' run o11n status host-testhost
  [[ $output == *"host-testhost media-server media-server-testhost.local radarr fail: http://media-server-testhost.local:7878/ping answers Bad Gateway"* ]]
}
