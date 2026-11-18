# shellcheck shell=bash
# Dependency: nixos/apps/mail.nix sets DMARC_SERVER, the mail server, which it logs in to over imaps and
# whose addresses send the org's mail, DMARC_LOGIN and DMARC_PASSWORD, the file of the login's password, and
# DMARC_RETENTION, the days Archive keeps a report, and DMARC_MAILBOXES, the domains the server receives mail for.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
printf 'user = "%s:%s"\n' "$DMARC_LOGIN" "$(<"$DMARC_PASSWORD")" >"$work/curlrc"

imap() {
	curl -sS --max-time 60 -K "$work/curlrc" "imaps://$DMARC_SERVER/$1" "${@:2}"
}

uids() {
	imap "$1" -X "UID SEARCH $2" | tr -d '\r' | sed -n 's/^\* SEARCH//p'
}

# Fact: a report may write an IPv6 address in any of its forms, so each is compared expanded.
expanded() {
	local address=${1,,} head tail fill=() group
	[[ $address == *:* ]] || {
		echo "$address"
		return
	}
	head=${address%%::*}
	tail=''
	[[ $address == *::* ]] && tail=${address#*::}
	local -a heads tails
	IFS=: read -ra heads <<<"$head"
	IFS=: read -ra tails <<<"$tail"
	for ((group = ${#heads[@]} + ${#tails[@]}; group < 8; group++)); do fill+=(0); done
	local -a groups=("${heads[@]}" "${fill[@]}" "${tails[@]}")
	printf '%04x:' "${groups[@]/#/0x}" | sed 's/:$//'
	echo
}

declare -A ours
while read -r address _; do
	ours[$(expanded "$address")]=1
done < <(getent ahosts "$DMARC_SERVER")
((${#ours[@]})) || {
	echo "dmarc-reports: $DMARC_SERVER resolves to no address, so no report tells of the org's own mail" >&2
	exit 1
}

declare -A mailboxes
for domain in $DMARC_MAILBOXES; do
	mailboxes[${domain,,}]=1
done

mailbox() {
	local domain=${1,,}
	while [[ -n $domain ]]; do
		[[ -v mailboxes[$domain] ]] && return
		[[ $domain == *.* ]] || return 1
		domain=${domain#*.}
	done
	return 1
}

# Fact: a report is XML, as is or zipped or gzipped, and DMARCbis's has a namespace, which the paths below leave out.
report() {
	case $(od -An -N2 -tx1 "$1") in
	" 50 4b") unzip -p "$1" ;;
	" 1f 8b") gzip -dc "$1" ;;
	*) cat "$1" ;;
	esac | head -c 64M | sed -E 's/<feedback[^>]*>/<feedback>/' >"$work/report.xml"
	xmlstarlet sel -T -t -v feedback/report_metadata/org_name -o $'\t' -v feedback/report_metadata/report_id \
		-o $'\t' -v feedback/policy_published/domain -n \
		-m feedback/record -v row/source_ip -o $'\t' -v row/count -o $'\t' -v row/policy_evaluated/dkim \
		-o $'\t' -v row/policy_evaluated/spf -o $'\t' -v identifiers/header_from -n "$work/report.xml" 2>/dev/null
}

# Policy: a report is flagged, and stays in INBOX, when the mail server's own mail fails DKIM or SPF as its From's
# domain, when mail from elsewhere passes SPF as a domain the server receives mail for, which only the server is to,
# or passes SPF but not DKIM as another, or when it holds no report; the rest go to Archive. A flagged report is the
# admin's to move or delete: unflagged, it's read again.
# Fact: a domain whose mail is hosted elsewhere names its provider's shared hosts in its SPF, which pass for anyone they
# send for, while the provider signs the domain's own mail with its DKIM key.
flagged=0
for uid in $(uids INBOX UNFLAGGED); do
	rm -rf "$work/parts"
	mkdir "$work/parts"
	imap "INBOX/;UID=$uid" >"$work/message"
	ripmime -i "$work/message" -d "$work/parts" >/dev/null 2>&1 || true
	reasons=() found=0
	for part in "$work/parts"/*; do
		[[ -f $part ]] || continue
		report "$part" >"$work/lines" || continue
		found=1
		IFS=$'\t' read -r org id domain <"$work/lines"
		while IFS=$'\t' read -r ip count dkim spf from; do
			if [[ -v ours[$(expanded "$ip")] ]]; then
				failing=()
				[[ $dkim == pass ]] || failing+=(DKIM)
				[[ $spf == pass ]] || failing+=(SPF)
				((${#failing[@]} == 0)) ||
					reasons+=("$org's report $id on $domain: $count from $ip, $DMARC_SERVER's, fail ${failing[*]} as $from")
			elif [[ $spf == pass ]] && mailbox "$from"; then
				reasons+=("$org's report $id on $domain: $count from $ip pass SPF as $from, which only $DMARC_SERVER is to")
			elif [[ $spf == pass && $dkim != pass ]]; then
				reasons+=("$org's report $id on $domain: $count from $ip pass SPF but not DKIM as $from, whose SPF lets $ip send as it")
			fi
		done < <(tail -n +2 "$work/lines")
	done
	((found)) || reasons+=("message $uid holds no DMARC report: $(sed -n 's/^Subject: //Ip' "$work/message" | head -1)")
	if ((${#reasons[@]})); then
		imap INBOX -X "UID STORE $uid +FLAGS.SILENT (\\Flagged)" >/dev/null
		printf '%s\n' "${reasons[@]}" >&2
		flagged=$((flagged + 1))
	else
		imap INBOX -X "UID MOVE $uid Archive" >/dev/null
	fi
done

old=$(uids Archive "SENTBEFORE $(LC_ALL=C date -d "-$DMARC_RETENTION days" +%d-%b-%Y)")
if [[ -n ${old// /} ]]; then
	read -ra old <<<"$old"
	set=$(
		IFS=,
		echo "${old[*]}"
	)
	imap Archive -X "UID STORE $set +FLAGS.SILENT (\\Deleted)" >/dev/null
	imap Archive -X "UID EXPUNGE $set" >/dev/null
fi

((flagged == 0)) || {
	echo "dmarc-reports: flagged $flagged in $DMARC_LOGIN's INBOX" >&2
	exit 1
}
