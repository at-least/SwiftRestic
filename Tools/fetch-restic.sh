#!/bin/bash
# The one restic the app ships and the tests run: downloads the pinned
# release once into .build/, checks both architectures against the release's
# SHA256SUMS, and joins them. Prints the universal binary's path.
#
# To move to a new restic: change version and both sums here, then run the
# gate. PinnedRestic (tests) reads the version from this file.
set -euo pipefail
cd "$(dirname "$0")/.."

version=0.19.1
sha256_arm64=7be0a144ccc377880f294204aa271d76e4b79554b42a751151d425ce6ebac143
sha256_amd64=c38d579622cf602f665234c5a8c315030b6cf70656028fe6dc29a786b60e5f35

work="$PWD/.build/restic/$version"
mkdir -p "$work"

fetch() {
    local arch="$1" sha256="$2"
    local archive="$work/restic_${version}_darwin_$arch.bz2"
    if [ ! -f "$archive" ]; then
        curl -fsSL -o "$archive.partial" \
            "https://github.com/restic/restic/releases/download/v$version/restic_${version}_darwin_$arch.bz2"
        mv "$archive.partial" "$archive"
    fi
    echo "$sha256  $archive" | shasum -a 256 -c --status - || {
        echo "error: $archive does not match the pinned checksum; delete it and rerun, and if it fails again do not ship it" >&2
        exit 1
    }
    bunzip2 -c "$archive" > "$work/restic-$arch"
    chmod +x "$work/restic-$arch"
}

if [ ! -x "$work/restic" ]; then
    fetch arm64 "$sha256_arm64"
    fetch amd64 "$sha256_amd64"
    lipo -create "$work/restic-arm64" "$work/restic-amd64" -output "$work/restic.partial"
    rm "$work/restic-arm64" "$work/restic-amd64"
    mv "$work/restic.partial" "$work/restic"
fi
echo "$work/restic"
