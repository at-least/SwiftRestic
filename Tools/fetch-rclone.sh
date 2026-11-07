#!/bin/bash
# The one rclone the app ships and the tests run: downloads the pinned
# release once into .build/, checks both architectures against the release's
# SHA256SUMS, and joins them. Prints the universal binary's path.
#
# To move to a new rclone: change version and both sums here, then run the
# gate. The sums are rclone-v$version-*.zip's lines in
# https://downloads.rclone.org/v$version/SHA256SUMS.
set -euo pipefail
cd "$(dirname "$0")/.."

version=1.76.0
sha256_arm64=e72dc90b70f4947a7b72b61bde4a4fbba5777b2874fb448951ffdde67ebd0ab7
sha256_amd64=4f5835733d52b818340f97b1fc0348a70461534d123363a183ca2b660219595a

work="$PWD/.build/rclone/$version"
mkdir -p "$work"

fetch() {
    local arch="$1" sha256="$2"
    local archive="$work/rclone-v${version}-osx-$arch.zip"
    if [ ! -f "$archive" ]; then
        curl -fsSL -o "$archive.partial" \
            "https://downloads.rclone.org/v$version/rclone-v$version-osx-$arch.zip"
        mv "$archive.partial" "$archive"
    fi
    echo "$sha256  $archive" | shasum -a 256 -c --status - || {
        echo "error: $archive does not match the pinned checksum; delete it and rerun, and if it fails again do not ship it" >&2
        exit 1
    }
    # The zip unpacks one folder holding the binary; -j flattens it.
    unzip -oj "$archive" "rclone-v$version-osx-$arch/rclone" -d "$work" >/dev/null
    mv "$work/rclone" "$work/rclone-$arch"
    chmod +x "$work/rclone-$arch"
}

if [ ! -x "$work/rclone" ]; then
    fetch arm64 "$sha256_arm64"
    fetch amd64 "$sha256_amd64"
    lipo -create "$work/rclone-arm64" "$work/rclone-amd64" -output "$work/rclone.partial"
    rm "$work/rclone-arm64" "$work/rclone-amd64"
    mv "$work/rclone.partial" "$work/rclone"
fi
echo "$work/rclone"
