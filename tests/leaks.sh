# Usage: bash leaks.sh STORE_DIR DRV PATTERN...
#
# Walks the derivations a system is built from, starting at DRV, without building anything, and prints every
# derivation and input source that matches a PATTERN, an extended regular expression, as a whole word. Sources named
# "source" are whole input trees, like nixpkgs, and are skipped: what o11n and an org add are copies of their own
# files, named after them.
set -euo pipefail

store_dir=$1 drv=$2
shift 2
pattern="\\b($(
    IFS='|'
    echo "$*"
))\\b"
store_path="$store_dir/[0-9a-z]{32}-[A-Za-z0-9+._?=-]+"

declare -A drvs=() sources=()
level=("$drv")
while ((${#level[@]})); do
    for path in "${level[@]}"; do drvs[$path]=1; done
    # Accommodating for ATerm, Derive([outputs],[inputDrvs],[inputSrcs],"system",...): no output holds a "]", and the
    # first `],"` closes the input sources, so what lies between is the input derivations and sources alone.
    mapfile -t found < <(
        printf '%s\0' "${level[@]}" |
            xargs -0 sed -E 's/^Derive\(\[[^]]*\],\[//; s/\],".*//' |
            grep -oE "$store_path" | sort -u
    )
    level=()
    for path in "${found[@]}"; do
        if [[ $path == *.drv ]]; then
            [[ -n ${drvs[$path]:-} ]] || level+=("$path")
        elif [[ $path != *-source ]]; then
            sources[$path]=1
        fi
    done
done

echo "${#drvs[@]} derivations and ${#sources[@]} sources from $drv"
mapfile -t searched < <(printf '%s\n' "${!drvs[@]}" "${!sources[@]}" | sort)
! printf '%s\0' "${searched[@]}" | xargs -0 grep -rnoaE "$pattern" -- >&2
