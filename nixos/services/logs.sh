#!/usr/bin/env bash
# Summary: what reached the host from outside since the span given, as counts and the most frequent sources.
set -uo pipefail

since=${1:-7d}
[[ $since =~ ^([1-9][0-9]*)([mhdw])$ ]] || {
	echo "logs: a span is a number and m, h, d or w, as 7d, not '$since'" >&2
	exit 2
}
declare -A units=([m]=minutes [h]=hours [d]=days [w]=weeks)
cutoff=$(date -d "-${BASH_REMATCH[1]} ${units[${BASH_REMATCH[2]}]}" +%Y-%m-%dT%H:%M:%S)
journal() { journalctl -q --since="${cutoff/T/ }" -o cat "$@" 2>/dev/null; }

norm() {
	sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/IP/g; s/\[?[0-9a-f]{1,4}(:[0-9a-f]{0,4}){2,7}\]?/IP/g;
		s/port [0-9]+/port N/g; s/\]:[0-9]+/]:N/g; s/(user|for|user=<|rip=)[ =]?[^ ,>]+/\1 U/g; s/#[0-9]+/#N/g;
		s/[0-9]+(\.[0-9]+)?(s|ms)\b/T/g; s/[0-9A-F]{10,}/Q/g; s/session=<[^>]*>/session=<S>/g'
}
sources() {
	grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|[0-9a-f]{1,4}(:[0-9a-f]{0,4}){3,7}' | sort | uniq -c | sort -rn | head -"${1:-10}"
}
top() { sort | uniq -c | sort -rn | head -"${1:-15}"; }

echo "===== $(hostname) since $cutoff"
echo "--- listening, but not on loopback"
ss -Hltnu | awk '$5 !~ /^(127\.|\[::1\]|\[::ffff:127\.)/ {print $1, $5}' | sort -u

echo "--- refused by the firewall, by interface, protocol and port"
journal -k -g 'refused (connection|packet)' | grep -oE 'IN=[^ ]* .*PROTO=[A-Z0-9]+ .*DPT=[0-9]+' |
	sed -E 's/^(IN=[^ ]*) .*(PROTO=[A-Z0-9]+) .*(DPT=[0-9]+)$/\1 \2 \3/' | top 20

for unit in sshd reverse-tunnel postfix dovecot keycloak; do
	log=$(journal -u "$unit")
	[[ -n $log ]] || continue
	echo "--- $unit: $(wc -l <<<"$log") lines, by kind"
	norm <<<"$log" | top 20
	echo "--- $unit: sources of failures"
	grep -iE 'invalid|fail|denied|reject|penalty|lost|NOQUEUE|LOGIN_ERROR' <<<"$log" | sources 10
done

echo "--- sshd: users tried"
journal -u sshd | grep -oE '(Invalid|invalid|authenticating) user [^ ]+' | awk '{print $NF}' | top
echo "--- sshd: accepted, by user and source"
journal -u sshd | awk '/^Accepted/ {print $4, $6}' | top

if [[ -r /var/log/nginx ]]; then
	# Dependency: nixos/nginx.nix logs each request as JSON, its time first.
	log=$(find /var/log/nginx -name 'access.log*' -newermt "${cutoff/T/ }" -exec zcat -f {} + 2>/dev/null |
		awk -v cutoff="\"time_iso8601\": \"$cutoff" 'substr($0, 2, length(cutoff)) >= cutoff')
	field() { sed -nE "s/.*\"$1\": \"?([^\",]*)\"?.*/\1/p"; }
	echo "--- nginx: $(grep -c . <<<"$log") requests, by status"
	field status <<<"$log" | top 10
	echo "--- nginx: by host"
	field host <<<"$log" | top 20
	echo "--- nginx: 4xx by host, method and path"
	grep -aE '"status": "4' <<<"$log" |
		sed -nE 's/.*"request_method": "([^"]*)", "request_uri": "([^"?]*)[^"]*".*"host": "([^"]*)".*/\3 \1 \2/p' | top 25
	echo "--- nginx: POSTs to logins, by host, path and status"
	grep -a '"request_method": "POST"' <<<"$log" |
		sed -nE 's/.*"status": "([0-9]+)".*"request_uri": "([^"?]*)[^"]*".*"host": "([^"]*)".*/\3 \2 \1/p' |
		grep -iE 'login|auth|token|xmlrpc|wp-|signin|session|admin|/api ' | top 20
	echo "--- nginx: sources of 4xx"
	grep -aE '"status": "4' <<<"$log" | field remote_addr | top 10
fi

echo "--- fail2ban, by jail"
journal -u fail2ban | grep -oE '\[[a-z0-9-]+\] (Ban|Unban|Found|Restore Ban)' | top 20

exit 0
