# Debug build
build:
    swift build

# Development .app in build/ (Developer ID signed when available, so Accessibility survives rebuilds)
bundle:
    scripts/bundle.sh

# Universal, signed, notarized ZIP in dist/
release:
    scripts/release.sh

# Signed ZIP without notarization
package:
    scripts/release.sh --no-notarize

# Install the development build to /Applications and restart it
install: bundle
    pkill -x HelgeLauncher || true
    ditto "build/Helge Launcher.app" "/Applications/Helge Launcher.app"
    open "/Applications/Helge Launcher.app"

# Signing identity and notary profile check
release-status:
    security find-identity -v -p codesigning | grep "Developer ID Application" || echo "no Developer ID Application identity"
    xcrun notarytool history --keychain-profile "${APPLE_NOTARY_PROFILE:-$(plutil -extract notaryProfile raw -o - ~/.config/terminal/release.json)}" --output-format json | head -c 200; echo

# Regenerate the app and menu-bar icons
icons:
    swift tools/icon.swift magnifier assets/AppIcon.png 1024
    swift tools/icon.swift template Resources/MenuBarIcon@2x.png 44
    swift tools/icon.swift template Resources/MenuBarIcon.png 22

# Headless search, e.g. `just search tp`
search q mode="root":
    swift build -q && .build/debug/HelgeLauncher --mode {{mode}} --search "{{q}}"

# Headless AI question
ask q:
    swift build -q && .build/debug/HelgeLauncher --ai "{{q}}"
