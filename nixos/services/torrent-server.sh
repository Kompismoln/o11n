# shellcheck shell=bash
# Dependency: crates/o11n/src/torrent.rs sends one of these as the command; sshd hands it over as SSH_ORIGINAL_COMMAND,
# unparsed by any shell. TORRENT_TO and TORRENT_AS hold <name>=<directory> pairs, and TORRENT_DEFAULT a directory or
# nothing (nixos/services/torrent-server.nix).
read -ra args <<<"${SSH_ORIGINAL_COMMAND-}"
remote=(transmission-remote "$TRANSMISSION_RPC")

declare -A to as
for pair in ${TORRENT_TO-}; do to[${pair%%=*}]=${pair#*=}; done
for pair in ${TORRENT_AS-}; do as[${pair%%=*}]=${pair#*=}; done

names() {
	local -n of=$1
	local IFS=,
	keys=("${!of[@]}")
	echo "${keys[*]:-none}"
}

case ${args[0]-} in
add)
	links=() dir=${TORRENT_DEFAULT-} target='' kind=''
	set -- "${args[@]:1}"
	while (($#)); do
		case $1 in
		--to)
			target=${2-}
			[[ -n $target && -v to[$target] ]] || {
				echo "add: --to names an allotment the server downloads into: $(names to)" >&2
				exit 2
			}
			dir=${to[$target]}
			shift 2
			;;
		--as)
			kind=${2-}
			[[ -n $kind && -v as[$kind] ]] || {
				echo "add: --as names a kind the server files a download by: $(names as)" >&2
				exit 2
			}
			dir=${as[$kind]}
			shift 2
			;;
		*)
			links+=("$1")
			shift
			;;
		esac
	done
	[[ -z $target || -z $kind ]] || {
		echo "add: --as files a download where its kind goes, which --to would too: give one of them" >&2
		exit 2
	}
	((${#links[@]} > 0)) || {
		echo "add: a magnet link, a URL or - for a .torrent on stdin" >&2
		exit 2
	}
	[[ -n $dir ]] || {
		echo "add: the server has no allotment it downloads into by default: give --to $(names to)" >&2
		exit 2
	}
	# Fact: transmission-remote sets the download-dir of what it adds after --add, and of the session before it.
	for link in "${links[@]}"; do
		if [[ $link == - ]]; then
			file=$(mktemp --suffix=.torrent)
			trap 'rm -f "$file"' EXIT
			cat >"$file"
			"${remote[@]}" --add "$file" --download-dir "$dir"
		else
			"${remote[@]}" --add "$link" --download-dir "$dir"
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
	echo "torrent-server: add [--to <allotment>|--as <kind>] <link|->..., list or remove [--delete] <id>..." >&2
	exit 2
	;;
esac
