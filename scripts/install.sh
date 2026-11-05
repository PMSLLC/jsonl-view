#!/bin/bash
# Build Release and install to /Applications, register the Quick Look extension, make it
# the handler for .jsonl.
# Signing: reuses scripts/build-local.sh (manual "Apple Development" signing, no profile),
# because Xcode has no Apple ID signed in on this Mac. Once the owner signs in to Xcode,
# automatic signing with `xcodebuild -allowProvisioningUpdates` works too.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-local.sh Release

SRC="$PWD/build/Build/Products/Release/JSONLView.app"
target="/Applications/JSONLView.app"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[ -d "$SRC" ] || { echo "build output missing: $SRC" >&2; exit 1; }

# Quit any running instance so the old code is not left running.
if pgrep -x JSONLView >/dev/null; then
  osascript -e 'quit app "JSONLView"' || pkill -x JSONLView || true
  sleep 1
fi

# Guarded replace.
if [ -z "$target" ] || [ "$target" != "/Applications/JSONLView.app" ]; then
  echo "refusing to replace unexpected target: '$target'" >&2; exit 1
fi
echo "replacing $target"
tmp="/Applications/.JSONLView.app.new"
rm -rf -- "${tmp:?}"
ditto "$SRC" "$tmp"   # a failed copy leaves the old app in place
rm -rf -- "${target:?}"
mv "$tmp" "$target"

# Unregister stale copies (DerivedData, this repo's build/), then register the installed one.
{ "$LSREG" -dump | grep -o '/[^ ]*JSONLView\.app' || true; } | sort -u | while read -r p; do
  [ "$p" = "$target" ] || "$LSREG" -u "$p" || true
done
"$LSREG" -f "$target"
pluginkit -a "$target/Contents/PlugIns/JSONLPreview.appex"
pluginkit -e use -i com.brahy.jsonl-view.preview
qlmanage -r
qlmanage -r cache
pluginkit -m -v -i com.brahy.jsonl-view.preview

# Open once: first launch asks macOS to make it the default for .jsonl.
open "$target"
