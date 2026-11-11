# shellcheck shell=bash
# Dependency: nixos/services/media-server.nix runs this for each of Radarr, Sonarr and Lidarr, as the service, with
# APP, API, URL, CONFIG, ROOT, DOWNLOADS, RENAME and TRANSMISSION_PORT.

# Fact: an *arr writes its API key into its config.xml as it first starts, and answers /ping once it's up.
for _ in $(seq 300); do
	[[ -s $CONFIG ]] && curl -fsS "$URL/ping" >/dev/null 2>&1 && break
	sleep 1
done
key=$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$CONFIG")
[[ -n $key ]] || {
	echo "$APP has no ApiKey in $CONFIG" >&2
	exit 1
}

api() {
	local method=$1 path=$2 said
	shift 2
	said=$(curl -sS --fail-with-body -X "$method" -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
		"$URL/api/$API/$path" "$@") || {
		echo "$APP: $method $path: $said" >&2
		return 1
	}
	printf '%s\n' "$said"
}

install -d "$ROOT" "$DOWNLOADS"

if ! api GET rootfolder | jq -e --arg path "$ROOT" 'any(.[]; .path | rtrimstr("/") == $path)' >/dev/null; then
	folder=$(jq -n --arg path "$ROOT" '{path: $path}')
	if [[ $APP == lidarr ]]; then
		# Fact: Lidarr's root folders have a name and the profiles of what's added to them.
		folder=$(jq \
			--arg name "$(basename "$ROOT")" \
			--argjson quality "$(api GET qualityprofile | jq '.[0].id')" \
			--argjson metadata "$(api GET metadataprofile | jq '.[0].id')" \
			'. + {name: $name, defaultQualityProfileId: $quality, defaultMetadataProfileId: $metadata,
			defaultMonitorOption: "all", defaultNewItemMonitorOption: "all", defaultTags: []}' <<<"$folder")
	fi
	api POST rootfolder --data "$folder" >/dev/null
fi

# Fact: each *arr names the fields of its Transmission client its own way, of which one alone is a Directory, and it
# refuses a Directory with a Category, which its schema has by default.
client=$(api GET downloadclient/schema | jq \
	--arg downloads "$DOWNLOADS" \
	--argjson port "$TRANSMISSION_PORT" \
	'.[] | select(.implementation == "Transmission")
	| . + {name: "torrent-server", enable: true, priority: 1, removeCompletedDownloads: true,
	removeFailedDownloads: true, tags: []}
	| .fields |= map(
		if .name == "host" then .value = "127.0.0.1"
		elif .name == "port" then .value = $port
		elif .name | test("directory$"; "i") then .value = $downloads
		elif .name | test("category$"; "i") then .value = ""
		else . end)')
id=$(api GET downloadclient | jq -r '.[] | select(.name == "torrent-server") | .id')
if [[ -n $id ]]; then
	api PUT "downloadclient/$id?forceSave=true" --data "$(jq --argjson id "$id" '. + {id: $id}' <<<"$client")" >/dev/null
else
	api POST "downloadclient?forceSave=true" --data "$client" >/dev/null
fi

naming=$(api GET config/naming)
api PUT "config/naming/$(jq .id <<<"$naming")" --data "$(jq --arg rename "$RENAME" '.[$rename] = true' <<<"$naming")" >/dev/null

# Policy: the library holds its metadata as Kodi's .nfo files and images, which any player reads.
api GET metadata | jq -c '.[] | select(.implementation == "XbmcMetadata")' | while read -r consumer; do
	api PUT "metadata/$(jq .id <<<"$consumer")?forceSave=true" --data "$(jq '.enable = true' <<<"$consumer")" >/dev/null
done
