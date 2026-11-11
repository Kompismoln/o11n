# shellcheck shell=bash
# Dependency: crates/o11n/src/torrent.rs sends one of these as the command; sshd hands it over as SSH_ORIGINAL_COMMAND,
# unparsed by any shell.
read -ra args <<<"${SSH_ORIGINAL_COMMAND-}"
remote=(transmission-remote "$TRANSMISSION_RPC")

case ${args[0]-} in
add)
	((${#args[@]} > 1)) || {
		echo "add: a magnet link, a URL or - for a .torrent on stdin" >&2
		exit 2
	}
	for link in "${args[@]:1}"; do
		if [[ $link == - ]]; then
			file=$(mktemp --suffix=.torrent)
			trap 'rm -f "$file"' EXIT
			cat >"$file"
			"${remote[@]}" --add "$file"
		else
			"${remote[@]}" --add "$link"
		fi
	done
	;;
list)
	"${remote[@]}" --list
	;;
remove)
	action=--remove
	ids=("${args[@]:1}")
	if [[ ${ids[0]-} == --delete ]]; then
		action=--remove-and-delete
		ids=("${ids[@]:1}")
	fi
	((${#ids[@]} > 0)) || {
		echo "remove: the ids of the torrents, as list numbers them" >&2
		exit 2
	}
	for id in "${ids[@]}"; do
		[[ $id =~ ^[0-9]+$ ]] || {
			echo "remove: $id is no torrent's id" >&2
			exit 2
		}
	done
	"${remote[@]}" --torrent "$(
		IFS=,
		echo "${ids[*]}"
	)" "$action"
	;;
*)
	echo "torrent-server: add <link|->..., list or remove [--delete] <id>..." >&2
	exit 2
	;;
esac
