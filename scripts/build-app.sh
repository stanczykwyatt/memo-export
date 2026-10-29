#!/bin/bash
# Builds a universal "Memo Export.app" (Apple silicon and Intel) into ./build and signs it
# with the sandbox entitlements, plus the memo-export command line tool next to it.
#
#   scripts/build-app.sh            ad-hoc signature, for running on this Mac
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

identity="${SIGN_IDENTITY:--}"
app="build/Memo Export.app"

# Each architecture is built on its own and then combined, which works with just the
# Command Line Tools. Building both in one step needs Xcode.
binaries=()
tools=()
for arch in arm64 x86_64; do
	triple="$arch-apple-macosx14.0"
	swift build -c release --product MemoExport --triple "$triple"
	swift build -c release --product memo-export --triple "$triple"
	bin="$(swift build -c release --triple "$triple" --show-bin-path)"
	binaries+=("$bin/MemoExport")
	tools+=("$bin/memo-export")
done

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create "${binaries[@]}" -output "$app/Contents/MacOS/MemoExport"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
	cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
fi

# Signed with the default requirement, which names this exact build. macOS ties Full Disk Access
# to it, so no other program can claim the permission by reusing the bundle ID. The cost is that
# each update has to be allowed again. A Developer ID signature would keep it across updates.
codesign --force --options runtime --timestamp=none \
	--entitlements Resources/MemoExport.entitlements \
	--sign "$identity" "$app"
codesign --verify --strict "$app"

# The command line tool runs as you, in your terminal, so it isn't sandboxed. It only ever reads
# the Voice Memos library, and writes only into the folder you give it.
lipo -create "${tools[@]}" -output build/memo-export
codesign --force --options runtime --timestamp=none --identifier com.stanczykwyatt.memo-export \
	--sign "$identity" build/memo-export
codesign --verify --strict build/memo-export

echo "Built $app and build/memo-export"
