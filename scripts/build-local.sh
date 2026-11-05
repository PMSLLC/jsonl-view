#!/bin/bash
# Local build without an Apple ID signed in to Xcode: manual signing with the
# keychain's "Apple Development" certificate and no provisioning profile.
# Team 997DW79YCR is the certificate's OU (the "(7UHLT8YAFL)" in its name is a personal
# identifier, not the team). project.yml keeps automatic signing for normal Xcode builds.
# Then registers the app and its Quick Look extension so `qlmanage -p` uses it.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Release}"
xcodegen generate
xcodebuild -project JSONLView.xcodeproj -scheme JSONLView -configuration "$CONFIG" \
  -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM=997DW79YCR PROVISIONING_PROFILE_SPECIFIER="" build
APP="$PWD/build/Build/Products/$CONFIG/JSONLView.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
pluginkit -a "$APP/Contents/PlugIns/JSONLPreview.appex"
pluginkit -e use -i com.brahy.jsonl-view.preview
qlmanage -r
pluginkit -m -v -i com.brahy.jsonl-view.preview
