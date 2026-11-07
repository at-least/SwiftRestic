#!/bin/bash
# Xcode build phase: puts the pinned helpers (restic, rclone) in the app.
# Each is signed here, with the app's identity, because Xcode seals the app
# after the last build phase and a seal over an unsigned or differently
# signed helper fails `codesign --verify --deep --strict`.
set -euo pipefail
helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
mkdir -p "$helpers"

restic="$("$SRCROOT/Tools/fetch-restic.sh")"
cp -f "$restic" "$helpers/restic"
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --identifier com.newlix.SwiftRestic.restic "$helpers/restic"

rclone="$("$SRCROOT/Tools/fetch-rclone.sh")"
cp -f "$rclone" "$helpers/rclone"
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --identifier com.newlix.SwiftRestic.rclone "$helpers/rclone"
