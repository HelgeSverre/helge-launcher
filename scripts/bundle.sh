#!/bin/zsh
# Builds "Helge Launcher.app" (menu-bar app).
#   scripts/bundle.sh              native arch, ad-hoc signed (development)
#   scripts/bundle.sh --universal  arm64 + x86_64, unsigned (scripts/release.sh signs it)
set -euo pipefail
cd "${0:A:h}/.."

UNIVERSAL=0
[[ "${1:-}" == "--universal" ]] && UNIVERSAL=1

VERSION=$(<VERSION)
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)
APP="build/Helge Launcher.app"

if (( UNIVERSAL )); then
  swift build -c release --arch arm64 --arch x86_64
  BIN=.build/apple/Products/Release/HelgeLauncher
else
  swift build -c release
  BIN=.build/release/HelgeLauncher
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/HelgeLauncher"
cp Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# App icon: one source image → .icns (regenerate the PNG with `swift tools/icon.swift`).
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>Helge Launcher</string>
	<key>CFBundleExecutable</key>
	<string>HelgeLauncher</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>no.helgesverre.launcher</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>Helge Launcher</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleSupportedPlatforms</key>
	<array>
		<string>MacOSX</string>
	</array>
	<key>CFBundleVersion</key>
	<string>${BUILD}</string>
	<key>CFBundleURLTypes</key>
	<array>
		<dict>
			<key>CFBundleURLName</key>
			<string>no.helgesverre.launcher</string>
			<key>CFBundleURLSchemes</key>
			<array>
				<string>helgelauncher</string>
			</array>
		</dict>
	</array>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © 2026 Helge Sverre.</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

if (( ! UNIVERSAL )); then
  # Sign dev builds with the Developer ID when available: Accessibility (TCC) grants then key on
  # team + bundle id and survive rebuilds. Ad-hoc signatures change every build and lose the grant.
  ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
  codesign --force --options runtime --sign "${ID:--}" --identifier no.helgesverre.launcher "$APP"
fi
echo "built $APP ($VERSION, build $BUILD)"
