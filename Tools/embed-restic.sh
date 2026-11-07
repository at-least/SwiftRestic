#!/bin/bash
# Xcode build phase: puts the pinned restic in the app. It is signed here, with
# the app's identity, because Xcode seals the app after the last build phase
# and a seal over an unsigned or differently signed helper fails
# `codesign --verify --deep --strict`.
set -euo pipefail
source_binary="$("$SRCROOT/Tools/fetch-restic.sh")"
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"
cp -f "$source_binary" "$helpers/restic"
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --identifier com.newlix.SwiftRestic.restic "$helpers/restic"
