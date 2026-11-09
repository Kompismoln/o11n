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
	sed -E 's/\b[0-9]{4}-[0-9]{2}-[0-9]{2}\b/D/g; s/\b(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) +[0-9]{1,2}\b/D/g;
		s/\b[0-9]{2}:[0-9]{2}:[0-9]{2}([.,][0-9]+)?\b/T/g;
		s/port [0-9]+/port N/g; s/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/IP/g; s/::ffff:IP\b/IP/g;
		s/(^|[^[:alnum:]._:])([0-9a-f]{1,4}(:[0-9a-f]{0,4}){2,7}|::[0-9a-f]{1,4}(:[0-9a-f]{1,4}){0,6})/\1IP/g; s/\]:[0-9]+/]:N/g;
		s/(^|[^[:alpha:]])(username|user|for)( |=<?)[^ ,<>]+/\1\2\3U/g; s/rip=[^ ,>]+/rip=IP/g; s/#[0-9]+/#N/g; s/thread-[0-9]+/thread-N/g;
		s/\b[0-9]+(\.[0-9]+)?(s|ms)\b/T/g; s/[0-9A-F]{10,}/Q/g; s/session=<[^>]*>/session=<S>/g; s/^<[0-9a-z]{6}>; //'
}
own=" $(ip -o addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); printf "%s ", $4}')"
# Dependency: nixos/services/logs.nix sets ORG_PREFIX6 and ORG_PREFIX4 to the org's prefix and prefix4.
label() {
	awk -v f="$1" -v own="$own" -v p6="${ORG_PREFIX6:-}:" -v p4="${ORG_PREFIX4:-}." '
		NF < f { print; next }
		{
			rest = $0; out = ""
			for (i = 1; i <= f; i++) {
				match(rest, /^ *[^ ]+/)
				out = out substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
			}
			a = $f; gsub(/^\[|\]$/, "", a); sub(/^::ffff:/, "", a)
			tag = index(own, " " a " ") ? " (this host)" : \
				(length(p6) > 1 && index(a, p6) == 1) || (length(p4) > 1 && index(a, p4) == 1) ? " (org)" : ""
			print out tag rest
		}'
}
# Fact: keycloak writes an IPv6 address in full, as fd00:0:0:0:0:0:0:1, where ip, sshd and nginx write fd00::1.
compress() {
	awk '!/:/ { print; next }
		{
			a = tolower($0); n = 0
			if (i = index(a, "::")) {
				h = split(substr(a, 1, i - 1), head, ":"); t = split(substr(a, i + 2), tail, ":")
				for (j = 1; j <= h; j++) g[++n] = head[j]
				for (j = 1; j <= 8 - h - t; j++) g[++n] = "0"
				for (j = 1; j <= t; j++) g[++n] = tail[j]
			} else n = split(a, g, ":")
			if (n != 8) { print; next }
			start = 0; longest = 1; run = 0
			for (j = 1; j <= 8; j++) {
				sub(/^0+/, "", g[j]); if (g[j] == "") g[j] = "0"
				if (g[j] == "0") { if (++run > longest) { longest = run; start = j - run + 1 } } else run = 0
			}
			out = ""
			for (j = 1; j <= 8; j++)
				if (j == start) { out = out "::"; j += longest - 1 }
				else out = out (out == "" || out ~ /::$/ ? "" : ":") g[j]
			print out
		}'
}
# Fact: dovecot names the host's own address in each line, as lip=.
sources() {
	sed -E 's/lip=[^,]*//g' | grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b|[0-9a-f]{1,4}(:[0-9a-f]{0,4}){3,7}' |
		compress | sort | uniq -c | sort -rn | head -"${1:-10}" | label 2
}
top() { sort | uniq -c | sort -rn | head -"${1:-15}"; }
field() { sed -nE "s/.*\"$1\": \"?([^\",]*)\"?.*/\1/p"; }
reach() {
	if [[ -z $2 ]]; then
		echo "$1: nothing"
	elif [[ ${2:0:19} > $cutoff ]]; then
		echo "$1 from $2, after the cutoff: the span isn't all there"
	else
		echo "$1 from $2"
	fi
}

echo "===== $(hostname) since $cutoff$(date +%:z)"
echo "--- how far back each log reaches"
reach journal "$(journalctl -q -o short-iso --no-pager 2>/dev/null | head -1 | cut -d' ' -f1)"
if [[ -r /var/log/nginx ]]; then
	oldest=$(find /var/log/nginx -name 'access.log*' -readable -printf '%T@ %p\n' | sort -n | head -1 | cut -d' ' -f2-)
	reach nginx "$([[ -n $oldest ]] && zcat -f "$oldest" 2>/dev/null | head -1 | field time_iso8601)"
	unreadable=$(find /var/log/nginx -name 'access.log*' ! -readable | wc -l)
	((unreadable == 0)) || echo "nginx: $unreadable of its logs unreadable"
fi

echo "--- listening, but not on loopback, by unit"
listening=$(ss -Hltnu --cgroup 2>/dev/null)
status=$?
if ((status != 0)) || [[ -z $listening ]]; then
	echo "ss --cgroup gave nothing, status $status: the units are unknown"
	listening=$(ss -Hltnu)
fi
awk '$5 !~ /^(127\.|\[::1\]|\[::ffff:127\.)/ {
	unit = "-"
	for (i = 7; i <= NF; i++) if ($i ~ /^cgroup:/) { unit = $i; sub(/^cgroup:(.*\/)?/, "", unit) }
	print $1, $5, (unit == "" ? "-" : unit)
}' <<<"$listening" | sort -u

echo "--- units failed now"
systemctl --failed --plain --no-legend --no-pager 2>/dev/null | awk '{print $1}'
echo "--- units restarted, by unit"
journal _PID=1 -g 'Scheduled restart job' | grep -oE '^[^ ]+: Scheduled' | sed 's/: Scheduled$//' | top 10
echo "--- out of memory, processes killed"
journal -k -g 'Killed process' | grep -oE 'Killed process [0-9]+ \([^)]*\)' | sed -E 's/.*\((.*)\)$/\1/' | top 10

# Policy: a line that says something went as it should is counted, not listed by kind: what restarted and who logged
# in have sections of their own.
lifecycle='^(Starting|Started|Stopping|Stopped|Finished|Reloading|Reloaded) |\.service: (Deactivated successfully|Consumed )'
declare -A routine=(
	[sshd]='^(Connection from .* rdomain|Accepted |Postponed publickey|pam_unix\(sshd:session\): session (opened|closed)|User child is on pid|Server listening on|Received signal 15)'
	[postfix]='^(connect from |(Anonymous|Trusted|Verified) TLS connection established|[0-9A-Za-z]+: (client=|message-id=|removed$|from=<))'
	[dovecot]='^lmtp\([0-9]+\): (Connect|Disconnect) from local'
	[rspamd]='(^|; )(proxy; proxy_(accept_socket|milter_finish_handler)|map; http_map_finish: data is not modified|cfg; rspamd_worker_monitored_)'
	[keycloak]='^[0-9-]+ [0-9:,.]+ (INFO|DEBUG) '
)
for unit in sshd reverse-tunnel postfix dovecot rspamd keycloak; do
	log=$(journal -u "$unit" | grep -v '^statistics: ')
	[[ -n $log ]] || continue
	kinds=$(grep -vE "$lifecycle${routine[$unit]:+|${routine[$unit]}}" <<<"$log")
	lines=$(grep -c . <<<"$log")
	echo "--- $unit: $lines lines, $((lines - $(grep -c . <<<"$kinds"))) of them routine; the rest by kind"
	grep . <<<"$kinds" | norm | top 20
	failures=$(grep -iE 'invalid|fail|denied|reject|penalty|lost|NOQUEUE|LOGIN_ERROR|error|blocked' <<<"$log")
	echo "--- $unit: failures, by kind"
	grep . <<<"$failures" | norm | top 10
	# Fact: the addresses in rspamd's lines are what it looked up, not who connected.
	[[ $unit == rspamd ]] && continue
	echo "--- $unit: sources of failures"
	sources 10 <<<"$failures"
done

# Dependency: nixos/apps/mobilizon.nix has its container's console carry mobilizon's warnings and errors, as journald
# forwards them, after its uptime and the process, and Elixir writes them, after the time and metadata.
# Fact: a container's getty can leave its prompt before a line.
for unit in $(journalctl -q -F _SYSTEMD_UNIT 2>/dev/null | grep '^container@' | sort); do
	log=$(journal -u "$unit" | sed -nE 's/^.*\[ *[0-9]+\.[0-9]+\] [^ ]+\[[0-9]+\]: [0-9:.]+ ([^ []+=[^ ]* )*\[(warning|error)\] /[\2] /p')
	[[ -n $log ]] || continue
	echo "--- $unit: warnings and errors, by kind"
	sed -E 's/#PID<[0-9.]+>/#PID/g' <<<"$log" | norm | top 20
done

echo "--- sshd: users tried"
journal -u sshd | grep -oE '(Invalid|invalid|authenticating) user [^ ]+' | awk '{print $NF}' | top
echo "--- sshd: accepted, by user and source"
journal -u sshd | awk '/^Accepted (publickey|password|keyboard-interactive)/ {print $4, $6}' | top | label 3

if [[ -r /var/log/nginx ]]; then
	# Dependency: nixos/nginx.nix logs each request as JSON, its time first.
	log=$(find /var/log/nginx -name 'access.log*' -newermt "${cutoff/T/ }" -exec zcat -f {} + 2>/dev/null |
		awk -v cutoff="\"time_iso8601\": \"$cutoff" 'substr($0, 2, length(cutoff)) >= cutoff')
	echo "--- nginx: $(grep -c . <<<"$log") requests, by status"
	field status <<<"$log" | top 10
	echo "--- nginx: by host"
	field host <<<"$log" | top 20
	echo "--- nginx: 4xx by host, method and path"
	grep -aE '"status": "4' <<<"$log" |
		sed -nE 's/.*"request_method": "([^"]*)", "request_uri": "([^"?]*)[^"]*".*"host": "([^"]*)".*/\3 \1 \2/p' | top 25
	echo "--- nginx: 5xx by host, method, path and upstream status"
	grep -aE '"status": "5' <<<"$log" | awk '
		function value(name, got) {
			return match($0, "\"" name "\": \"((\\\\.|[^\"\\\\])*)\"", got) && got[1] != "" ? got[1] : "-"
		}
		{ uri = value("request_uri"); sub(/\?.*/, "", uri)
		  print value("host"), value("request_method"), uri, "upstream " value("upstream_status") }' | top 20
	echo "--- nginx: POSTs to logins, by host, path and status"
	grep -a '"request_method": "POST"' <<<"$log" |
		sed -nE 's/.*"status": "([0-9]+)".*"request_uri": "([^"?]*)[^"]*".*"host": "([^"]*)".*/\3 \2 \1/p' |
		grep -iE 'login|auth|token|xmlrpc|wp-|signin|session|admin|/api ' | top 20
	echo "--- nginx: sources of 4xx, with the user agent they sent most"
	grep -aE '"status": "4' <<<"$log" | awk '
		match($0, /"remote_addr": "([^"]*)"/, addr) {
			agent = match($0, /"http_user_agent": "((\\.|[^"\\])*)"/, sent) && sent[1] != "" ? sent[1] : "-"
			requests[addr[1]]++
			if (++by[addr[1], agent] == 1) agents[addr[1]]++
			if (by[addr[1], agent] > most[addr[1]]) { most[addr[1]] = by[addr[1], agent]; agentOf[addr[1]] = agent }
		}
		END {
			for (a in requests)
				printf "%7d %s %s%s\n", requests[a], a, substr(agentOf[a], 1, 120),
					(agents[a] > 1 ? sprintf(" (+%d other agents)", agents[a] - 1) : "")
		}' | sort -rn | head -10 | label 2
fi

echo "--- fail2ban, by jail"
journal -u fail2ban | grep -oE '\[[a-z0-9-]+\] (Ban|Unban|Found|Restore Ban)' | top 20

exit 0
