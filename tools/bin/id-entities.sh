#!/usr/bin/env bash
# tools/bin/id-entities.sh

# === section 0: setup

# shellcheck disable=SC2030,SC2031
# - variables are modified in subshells intentionally

set -euo pipefail
declare -x act_as entity prefix class key
declare -g slot

tools_root="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# import run, with, log/try/die etc.
# shellcheck source=../libexec/run-with.bash
. "$tools_root/libexec/run-with.bash"

main() {
    # setup prefix, class, key etc.
    setup "$@" || die 1 "setup failed"

    # 'with id' runs id() and brings the result into scope as $id,
    # like a lazy variable.
    with id
    log info "$id wants to $prefix $key"

    # map command to a callchain and invoke its functions, e.g.
    # $ id-entities.sh -u alex verify ssh-key ->
    #     verify:user:ssh-key
    #     verify:user
    #     verify:ssh-key
    #     verify:
    run "$prefix"

    # sync to seize control over final output
    sync && log success "$prefix $key for $id completed."
}

# generate a sequence of functions for `run` to try
callchain() {
    # strip everything from the first colon
    local _prefix=${prefix%%:*}
    grep "^${prefix%:}" <<EOF
$_prefix:$class:$key
$_prefix:$class
$_prefix:$key
$_prefix:
EOF
}

setup() {
    [[ -n ${1:-} ]] || die 1 "hello! try --help" usage

    case "$1" in
    -r | --root) class="root" ;;
    -h | --host) class="host" ;;
    -u | --user) class="user" ;;
    -s | --service) class="service" ;;
    -S | --store) class="store" ;;
    -a | --app) class="app" ;;
    -H | --help)
        less "$tools_root/share/doc/id-entities-usage.txt"
        exit 0
        ;;
    *)
        if IFS='-' read -r class entity < <(org-toml.sh autocomplete-identity "$1"); then
            shift
            set -- "$entity" "$@"
            set -- "$class" "$@"
        else
            die 1 "could not infer a valid context" usage
        fi
        ;;
    esac

    entity=${2:?"entity name required"}
    prefix=${3:?"prefix is required"}
    key=${4-"age-key"}
    slot=${5:-0}

    preflight-input
    preflight-org-toml
    preflight-backend
    preflight-act-as
}

preflight-input() {
    links-by-prefix "$prefix" >/dev/null ||
        die 1 "no link matches prefix '$prefix'"

    allowed_keys | grep -q "$key" ||
        die 1 "$key not allowed for $class, allowed keys: $(allowed_keys)"
}

preflight-org-toml() {
    log info "org name: $(org-toml.sh "name")"
}

preflight-backend() {
    with backend_path
    [[ $prefix == "init" && -f "$backend_path" ]] &&
        die 1 "can't init '$entity', '$backend_path' already exists."

    [[ $prefix == "init" || -f "$backend_path" ]] ||
        die 1 "'$backend_path' doesn't exist, did you spell '$entity' correctly?"

    if [[ $prefix =~ ^(verify|align|check)$ ]]; then
        (with secret_file) || die 0 "no secret to $prefix"
    fi

    log info "$backend_path"
}

preflight-act-as() {
    with id
    local _class _entity age_key
    # bootstrap root-1 need not be checked, as it has nothing to be checked against
    [[ "$prefix-$id" != "init-root-1" ]] || return 0
    IFS='-' read -r _class _entity <<<"${SOPS_AGE_KEY_FILE##*/}"

    age_key=$(
        class=$_class
        entity=$_entity
        key="age-key"
        slot=0
        run derive-artifact
    ) || die 1 "no identity found in '$SOPS_AGE_KEY_FILE'"

    act_as="$_class-$_entity $age_key"

    log important "$act_as"
}

# === section 1: links
#
# there are ~70 links and they are listed below grouped by prefix and sorted
# roughly by typical workflow order

# --- init:*:*

# a trailing colon terminates the callchain
init:root:() {
    run new
}

# non-root entities require a little dance to encrypt themselves before backend
# is created (the age-key has to encrypt itself)
init:() {
    with id backend_path secret_path secret_seed
    IFS=' ' read -r act_as_id _ <<<"$act_as"

    if [[ -s "$secret_seed" ]]; then
        cat "$secret_seed" >"$secret_path"
    else
        run create-secret >"$secret_path"
    fi

    run align
    mkdir -p "$(dirname "$backend_path")"

    with sops_yaml
    # shellcheck disable=SC2094
    # SC believes we're reading from $(backend_file) here, but --filename-override
    # simply tells sops what creation rule to use, so this is ok.
    echo "identity: $class-$entity" | (cd "$(dirname "$sops_yaml")" && sops encrypt \
        --filename-override "$backend_path" \
        /dev/stdin >"$backend_path")
    run new
}

# --- new:*:*

new:() {
    run new-secret align
}

# prevent identities from rotating themselves out of access
new:age-key() {
    with id
    [[ -n ${act_as:-} ]] || return 0
    IFS=' ' read -r act_as_id _ <<<"$act_as"
    [[ "$id" != "${act_as_id:-}" ]] ||
        die 1 "entities are not allowed to rotate their own identity"
}

# --- new-secret:*:*

new-secret:() {
    # If SECRET_SEED is set to the path of a file, the path will be available
    # in $secret_seed
    with secret_seed
    if [[ -s "$secret_seed" ]]; then
        run encrypt <"$secret_seed"
    else
        run create-secret | run encrypt
    fi
}

# --- [verify|check]:*:*
# verify: ensure that private and public keys are aligned
# check: ensure live environment are actually using expected keys
verify:() {
    with get-artifact:
    run derive-artifact | try diff - "$get_artifact_"
}

# force artifact-only verification
verify:host:ssh-key:() {
    with get-artifact:
    derive-artifact:ssh-key: | try diff - "$get_artifact_"
}

verify:service:tls-cert:() {
    with get-artifact: secret_file domain

    try openssl x509 -in "$get_artifact_" -checkend 2592000 | log info

    openssl x509 -in "$get_artifact_" -noout -ext subjectAltName |
        try grep -qE "DNS:(\*\.)?$domain"

    openssl pkey -in "$secret_file" -pubout |
        try diff - <(openssl x509 -in "$get_artifact_" -pubkey -noout)
}

# remap check -> verify for host's ssh-keys
# verify already scans host, so check can piggyback on verify for host's ssh keys
check:host:ssh-key:() {
    verify:
}

check:host:age-key() {
    base64-secret: | locksmith
}

check:host:luks-key() {
    base64-secret: | locksmith
}

# --- [align|pull|push]:*:*

align:() {
    run derive-artifact | run set-artifact
}

# prevent derive-artifact from doing host scan for host:ssh-key
align:host:ssh-key:() {
    derive-artifact:ssh-key: | run set-artifact

    with get-artifact:
    log warning "next 'pull' will replace public ssh key at '$get_artifact_'"
}

# host scan under pull:* instead
pull:host:ssh-key:() {
    align:
}

push:host:luks-key() {
    with secret_file secret_seed

    # if the currently held secret and the user-provided-secret are identical,
    # pass them to looksmith as two (also identical) base64-strings.
    # this will instruct locksmith to drop the luks-key on the host.
    if cmp -s "$secret_file" "$secret_seed"; then
        run base64-secret new base64-secret | locksmith
        return
    fi

    # otherwise create a new secret under first available slot and pass them
    # as two base64-strings, this will instruct locksmith to add the second
    # passphrase.
    with next-slot:
    {
        run base64-secret
        slot=$next_slot_ run new base64-secret
    } | locksmith
}

push:host:age-key() {
    run verify
    # age-keys are stacked in the hosts' key file and will remain until
    # garbage-collected.
    run base64-secret new base64-secret | locksmith
}

# --- create-secret:*:*

create-secret:age-key() {
    try age-keygen | tail -1
}

create-secret:ssh-key() {
    with id tmp_path
    local out
    out=$(try ssh-keygen -t "ed25519" -f "$tmp_path" -N "" -C "$id") || exit
    log info "$out"
    cat "$tmp_path"
}

create-secret:nix-sign() {
    with id
    nix key generate-secret --key-name "$id"
}

create-secret:wg0-key() {
    try wg genkey
}

create-secret:wg1-key() {
    try wg genkey
}

create-secret:wg2-key() {
    try wg genkey
}

create-secret:luks-key() {
    try passphrase 12
}

create-secret:tls-cert() {
    try openssl genpkey -algorithm ED25519
}

create-secret:passwd() {
    try passphrase 8
}

create-secret:secret-key() {
    try passphrase 40
}

create-secret:restic-key() {
    try passphrase 40
}

# nixos-mailserver has unix-like user management, so mail will piggyback
# on passwd for all ops
create-secret:mail() {
    create-secret:passwd
}

# --- validate:*:*

validate:() {
    # secrets without artifacts may supply null operations here
    run derive-artifact >/dev/null
}

validate:luks-key() {
    validate-passphrase
}

validate:passwd() {
    validate-passphrase
}

validate:secret-key() {
    validate-passphrase
}

validate:mail() {
    validate:passwd
}

# this key 'passwd-sha512' is actually artifact for 'passwd', so it should not be
# deriving artifacts and we terminate the callchain with a trailing colon
validate:passwd-sha512:() {
    validate-sha512
}

validate:mail-sha512:() {
    validate:passwd-sha512:
}

validate-sha512() {
    with secret_file
    # shellcheck disable=SC2016
    # - single quotes intentional
    grep -q '^\$6\$[^$]\+\$[./0-9A-Za-z]\+$' "$secret_file"
}

validate-passphrase() {
    with secret_file
    local min_length=6

    ! trailing-newline "$secret_file" ||
        die 1 "'$secret_file' has trailing newline"

    [[ $(wc -m <"$secret_file") -ge "$min_length" ]] ||
        die 1 "'$(cat "$secret_file")' is shorter than $min_length chars"
}
# --- derive-artifact:*:*

derive-artifact:age-key:() {
    cat-secret: | try age-keygen -y
}

derive-artifact:passwd:() {
    sha512-secret:
}

derive-artifact:mail:() {
    derive-artifact:passwd:
}

# luks-keys and secret-keys have no public artifact
derive-artifact:luks-key:() {
    :
}

derive-artifact:secret-key:() {
    :
}

derive-artifact:restic-key:() {
    :
}

derive-artifact:wg0-key:() {
    cat-secret: | try wg pubkey
}

derive-artifact:wg1-key:() {
    cat-secret: | try wg pubkey
}

derive-artifact:wg2-key:() {
    cat-secret: | try wg pubkey
}

derive-artifact:nix-sign:() {
    cat-secret: | try nix key convert-secret-to-public
}

derive-artifact:tls-cert:() {
    with domain
    run cat-secret | try openssl req -new -x509 -key /dev/stdin \
        -subj "/CN=$domain" \
        -addext "subjectAltName=DNS:*.$domain,DNS:$domain" \
        -nodes -out - -days 3650
}

derive-artifact:ssh-key:() {
    with secret_file
    try ssh-keygen -y -C "" -f "$secret_file"
}

derive-artifact:host:ssh-key:() {
    with fqdn
    try ssh-keyscan -q "$fqdn" | awk '{print $2, $3}'
}

# --- get-artifact:*

get-artifact:() {
    with artifact_path
    # shellcheck disable=SC2015
    # - this is not if/then/else
    test -s "$artifact_path" &&
        echo "$artifact_path" ||
        die 1 "no artifact at $artifact_path"
}

get-artifact:passwd() {
    with artifact_path
    # create subshell to retreive secret from passwd-sha512 and use as artifact
    key=$key-sha512 cat-secret: >"$artifact_path"
}

get-artifact:mail() {
    get-artifact:passwd
}

get-artifact:luks-key:() {
    echo /dev/null
}

get-artifact:secret-key:() {
    echo /dev/null
}

# --- set-artifact:*

set-artifact:() {
    with artifact_path
    cat >"$artifact_path"
}

set-artifact:age-key:() {
    local diff=false
    with tmp_path
    cat >"$tmp_path"

    (run verify) || diff=true

    with artifact_path
    cat "$tmp_path" >"$artifact_path"

    if [[ $diff == true ]]; then
        rebuild:
    fi
}

set-artifact:luks-key:() {
    cat >/dev/null
}

set-artifact:secret-key:() {
    cat >/dev/null
}
set-artifact:passwd:() {
    key=$key-sha512 run encrypt
}

set-artifact:mail:() {
    set-artifact:passwd:
}

# --- [encrypt|decrypt|unset]:*:*

encrypt:() {
    with secret_path
    cat >"$secret_path"
    run validate

    with backend_path backend_component json-secret:
    try sops set "$backend_path" "$backend_component" "$json_secret_"
}

encrypt:root:() {
    with secret_path backend_path
    cat >"$secret_path"
    run validate
    try cp -a "$secret_path" "$backend_path"
}

decrypt:() {
    with backend_file backend_component
    try sops decrypt --extract "$backend_component" "$backend_file"
}

decrypt:root:() {
    with backend_path
    try cat "$backend_path"
}

unset:() {
    with backend_path backend_component
    try sops unset "$backend_path" "$backend_component"
}

# --- rebuild:*:*

rebuild:() {
    [[ $class != "root" ]] || return 0

    local rc=0 out=$tmpdir/updatekeys.out err=$tmpdir/updatekeys.err
    with backend_path sops_yaml

    (cd "$(dirname "$sops_yaml")" && sops updatekeys -y "$backend_path" >"$out" 2>"$err") ||
        rc=$?
    log important <"$out"
    sed -n '/synced with/p' "$err" | log info

    case $rc in
    0 | 1) return ;;
    *) die $rc "sops updatekeys error" ;;
    esac
}

# --- next-slot:*:*

next-slot:() {
    local slot=0
    while (LOG_LEVEL=off run decrypt >/dev/null); do
        ((slot++)) || true
    done
    echo "$slot"
}

# --- [cat|base64|json|sha512]-secret:*:*

cat-secret:() {
    with secret_file && cat "$secret_file"
}

base64-secret:() {
    cat-secret: | try base64 -w0
    echo
}

json-secret:() {
    cat-secret: | try jq -Rs
}

sha512-secret:() {
    local salt
    salt=$(
        LOG_LEVEL=off
        key=$key-sha512
        run cat-secret | awk -F'$' '{print $3}'
    ) || salt=""
    run cat-secret | mkpasswd -sm sha-512 -S "$salt"
}

# === section 2: lazy variables (idempotent functions)

# declarations to keep shellcheck happy

declare -g \
    artifact_path \
    backend_component \
    backend_enabled \
    backend_file \
    backend_path \
    domain \
    exact_key \
    get_artifact_ \
    fqdn \
    id \
    json_secret_ \
    next_slot_ \
    secret_file \
    secret_path \
    secret_seed \
    sops_yaml \
    tmp_path

allowed_keys() {
    org-toml.sh "class" "$class" "keys"
}

artifact_path() {
    # secrets that have public keys and other artifacts can store them at a
    # permanent location specified in org.toml
    with repo_root
    echo -n "$repo_root/"
    CONTEXT="$class:$entity:$key" org-toml.sh "public-artifacts" ||
        echo "$tmpdir/$class.$entity.$exact_key.artifact"
}

backend_component() {
    with exact_key
    local c="['$exact_key']"
    [[ $class == "host" ]] || c="['$entity']$c"
    echo "$c"
}

backend_enabled() {
    with backend_path
    local identity rc

    identity=$(try sops decrypt --extract "['identity']" "$backend_path")
    rc=$?

    [[ $identity == "$class-$entity" ]] ||
        die 1 "identity $identity doesn't match $class-$entity"

    case $rc in
    0) echo true ;;
    100) die 1 "backend file missing for '$entity'" ;;
    *) die $rc "sops could not decrypt '$backend_path'" ;;
    esac
}

backend_file() {
    with backend_path backend_enabled
    [[ "$backend_enabled" == "true" ]] || die 1 "backend for '$entity' disabled"
    echo "$backend_path"
}

backend_path() {
    with repo_root
    echo -n "$repo_root/"
    CONTEXT="$class:$entity:$key" org-toml.sh "secrets"
}

domain() {
    case "$entity" in
    domain-*)
        echo "${entity#domain-}"
        ;;
    *) die 1 "tls-cert can only be given to domains" ;;
    esac
}

exact_key() {
    local exact_key=$key
    [[ "$slot" == "0" ]] || exact_key+="--$slot"
    echo "$exact_key"
}

fqdn() {
    find-route.sh "$entity"
}

id() {
    echo "$class-$entity"
}

passphrase() {
    local length=${1:-12}
    openssl rand -base64 "$length" | tr -d '\n'
}

secret_file() {
    with secret_path
    [[ -s $secret_path ]] ||
        run decrypt >"$secret_path" &&
        echo "$secret_path"
}

secret_path() {
    with exact_key
    local s=$tmpdir/$class.$entity.$exact_key.secret
    [[ -f "$s" ]] || {
        (umask 077 && touch "$s")
    }
    echo "$s"
}

secret_seed() {
    local f=$tmpdir/secret_seed

    [[ -f "$f" ]] || {
        touch "$f"
        [[ -r ${SECRET_SEED:-} ]] &&
            cat "$SECRET_SEED" >"$f"
    }
    echo "$f"
}

sops_yaml() {
    with id
    local f="$tmpdir/$id/.sops.yaml"
    mkdir -p "$(dirname "$f")"
    org-toml.sh "sops-yaml" "$id" >"$f"
    echo "$f"
}

tmp_path() {
    local s
    s=$(mktemp "$tmpdir/XXXXXX") && rm "$s"
    echo "$s"
}

# === misc helpers

usage() {
    sed -n '/^USAGE$/,/^$/p' "$tools_root/share/doc/id-entities-usage.txt"
}

# A subshell of its own, so that its trap can't replace run-with.bash's in the caller.
locksmith() (
    with id fqdn

    if [ -t 0 ]; then
        die 1 "no payload"
    fi

    local lines payload

    payload=$(cat)
    [[ -n $payload ]] || die 1 "empty payload"

    lines=$(echo "$payload" | wc -l)
    [[ "$lines" -eq 1 || "$lines" -eq 2 ]] ||
        die 1 "payload must be 1-2 lines (got $lines)"

    eval "$(ssh-agent -s)" >/dev/null
    trap 'ssh-agent -k >/dev/null 2>&1' EXIT

    # create a subshell to retreive locksmith's ssh-key
    (
        class=service
        entity=locksmith
        key=ssh-key
        slot=0
        run cat-secret
    ) | try ssh-add -

    local out
    # shellcheck disable=SC2029
    # - "$key" expands client side intentionally
    out=$(echo "$payload" | try ssh "locksmith@$fqdn" "$key") || exit
    log info "$out"

    case $lines in
    1) log success "$key on $id confirmed" ;;
    2) log success "$key on $id deployed" ;;
    esac
)

# === main
main "$@"
