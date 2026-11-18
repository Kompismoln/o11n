# shellcheck shell=bash
# Dependency: nixos/apps/mail.nix sets GLESYS_ACCOUNT, GLESYS_KEY, the file of the account's API key, GLESYS_API, its
# base URL, GLESYS_ZONES, a JSON file of what each zone is to hold, and DKIM_DIR, where the server keeps its DKIM keys.
set -uo pipefail
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf 'user = "%s:%s"\n' "$GLESYS_ACCOUNT" "$(<"$GLESYS_KEY")" >"$work/curlrc"

api() {
	local method=$1 field args=()
	shift
	for field; do args+=(--data-urlencode "$field"); done
	curl -sS --fail-with-body --max-time 60 -K "$work/curlrc" -H 'Accept: application/json' "${args[@]}" \
		"$GLESYS_API/domain/$method"
}

# Fact: a TXT record longer than 255 characters is strings of at most that, which a receiver reads joined.
# Accommodating for the zone's apex, which is taken as "@", nothing or the zone's name, as an SPF record found under
# another would be added again, and two fail SPF.
found() {
	jq -r --arg zone "$zone" --arg host "$1" --arg type "$2" --arg prefix "$3" '
		.response.records[]
		| select(.type == $type and (.host == $host or $host == "@" and (.host == "" or .host == $zone)))
		| (.data | gsub("\"\\s*\""; "") | gsub("^\"|\"$"; "")) as $data
		| select($data | ascii_downcase | startswith($prefix | ascii_downcase))
		| "\(.recordid)\t\($data)"
	' <<<"$records"
}

name() {
	if [[ $2 == @ ]]; then echo "$1"; else echo "$2.$1"; fi
}

failed=0
fail() {
	echo "$*" >&2
	failed=1
}

add() {
	local zone=$1 host=$2 type=$3 data=$4
	if api addrecord "domainname=$zone" "host=$host" "type=$type" "data=$data" "ttl=3600" >/dev/null; then
		echo "$(name "$zone" "$host") $type: added $data"
	else
		fail "$(name "$zone" "$host") $type: adding $data failed"
	fi
}

# Policy: a record o11n owns is made what it's to be; one it doesn't is added only where there's none of its kind.
keep() {
	local zone=$1 host=$2 type=$3 prefix=$4 data=$5 owned=$6 id was
	IFS=$'\t' read -r id was < <(found "$host" "$type" "$prefix" | head -n 1)
	if [[ -z ${id:-} ]]; then
		add "$zone" "$host" "$type" "$data"
	elif [[ $owned == true && $was != "$data" ]]; then
		if api updaterecord "recordid=$id" "data=$data" >/dev/null; then
			echo "$(name "$zone" "$host") $type: $data, was $was"
		else
			fail "$(name "$zone" "$host") $type: updating to $data failed"
		fi
	fi
}

while read -r zone; do
	if ! records=$(api listrecords "domainname=$zone"); then
		fail "$zone: listing its records failed: $records"
		continue
	fi
	while IFS=$'\t' read -r kind host data; do
		case $kind in
		mx)
			found "$host" MX "" | cut -f2 | grep -qiE "(^| )${data//./\\.}\.?$" || add "$zone" "$host" MX "10 $data."
			;;
		spf) keep "$zone" "$host" TXT "v=spf1" "$data" false ;;
		dmarc) keep "$zone" "$host" TXT "v=DMARC1" "$data" true ;;
		authorize) keep "$zone" "$host" TXT "v=DMARC1" "v=DMARC1" false ;;
		dkim)
			if [[ ! -f $DKIM_DIR/$data ]]; then
				fail "$(name "$zone" "$host") TXT: the server has no DKIM key $DKIM_DIR/$data"
				continue
			fi
			keep "$zone" "$host" TXT "v=DKIM1" "$(grep -o '"[^"]*"' "$DKIM_DIR/$data" | tr -d '"\n')" true
			;;
		esac
	done < <(jq -r --arg zone "$zone" '.[$zone][] | [.kind, .host, .data] | @tsv' "$GLESYS_ZONES")
done < <(jq -r 'keys[]' "$GLESYS_ZONES")
exit "$failed"
