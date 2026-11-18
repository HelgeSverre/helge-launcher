# Helge Launcher: keyboard launcher for macOS.
set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

[private]
default:
    @just --list --unsorted

# ── build ─────────────────────────────────────────────────────────────

# Debug build.
[group('build')]
build:
    swift build

# Development app in build/ (Developer ID signed when available, so Accessibility survives rebuilds).
[group('build')]
bundle:
    scripts/bundle.sh

# Install the development build to /Applications and restart it.
[group('build')]
install: bundle
    pkill -x HelgeLauncher || true
    ditto "build/Helge Launcher.app" "/Applications/Helge Launcher.app"
    open "/Applications/Helge Launcher.app"

# Regenerate the app icon and the menu-bar icon.
[group('build')]
icons:
    swift tools/icon.swift magnifier assets/AppIcon.png 1024
    swift tools/icon.swift template Resources/MenuBarIcon@2x.png 44
    swift tools/icon.swift template Resources/MenuBarIcon.png 22

# ── test ──────────────────────────────────────────────────────────────

# Run the test suite.
[group('test')]
test:
    swift test

# Ranked search without the UI, e.g. `just search tp` or `just search thumbs emoji`.
[group('test')]
search query mode="root":
    swift build -q && .build/debug/HelgeLauncher --mode "$2" --search "$1"

# Run a configured plugin, e.g. `just plugin Calc "2*21"`.
[group('test')]
plugin name query="":
    swift build -q && .build/debug/HelgeLauncher --plugin "$1" --search "$2"

# Expand a snippet text, e.g. `just expand 'Today is {weekday}'`.
[group('test')]
expand text:
    swift build -q && .build/debug/HelgeLauncher --expand "$1"

# Ask the AI from the terminal.
[group('test')]
ask question:
    swift build -q && .build/debug/HelgeLauncher --ai "$1"

# Draw the launcher offscreen to a PNG, e.g. `just render /tmp/hl.png --search cap`.
[group('test')]
render out *args:
    swift build -q && .build/debug/HelgeLauncher --render "$@"

# ── release ───────────────────────────────────────────────────────────

# Check the Developer ID identity and notary profile.
[group('release')]
release-status:
    security find-identity -v -p codesigning | grep "Developer ID Application" || echo "no Developer ID Application identity"
    xcrun notarytool history --keychain-profile "${APPLE_NOTARY_PROFILE:-$(plutil -extract notaryProfile raw -o - ~/.config/terminal/release.json)}" --output-format json | head -c 200; echo

# Universal app, signed, without notarization (dist/).
[group('release')]
package:
    scripts/release.sh --no-notarize

# Universal app, signed, notarized and stapled (dist/).
[group('release')]
release:
    scripts/release.sh
