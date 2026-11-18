#!/bin/zsh
# Universal build → Developer ID signature (hardened runtime) → notarized, stapled ZIP in dist/.
#
#   scripts/release.sh            sign + notarize + staple + validate
#   scripts/release.sh --no-notarize
#
# Identity: $APPLE_APPLICATION_SIGNING_IDENTITY, else the single "Developer ID Application" in the Keychain.
# Notarization: $APPLE_NOTARY_PROFILE (a `notarytool store-credentials` profile), else
#               "notaryProfile" in ~/.config/terminal/release.json (shared with Helge Terminal).
# Keychain:     $APPLE_SIGNING_KEYCHAIN (CI uses a temporary one).
set -euo pipefail
cd "${0:A:h}/.."

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

VERSION=$(<VERSION)
APP="build/Helge Launcher.app"
DIST=dist
ZIP="$DIST/HelgeLauncher-$VERSION-universal.zip"
KEYCHAIN_ARGS=()
[[ -n "${APPLE_SIGNING_KEYCHAIN:-}" ]] && KEYCHAIN_ARGS=(--keychain "$APPLE_SIGNING_KEYCHAIN")

IDENTITY=${APPLE_APPLICATION_SIGNING_IDENTITY:-}
if [[ -z "$IDENTITY" ]]; then
  ids=("${(@f)$(security find-identity -v -p codesigning ${APPLE_SIGNING_KEYCHAIN:-} | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | sort -u)}")
  [[ ${#ids} -eq 1 && -n "${ids[1]}" ]] || { echo "error: set APPLE_APPLICATION_SIGNING_IDENTITY (found ${#ids} Developer ID identities)" >&2; exit 1; }
  IDENTITY=${ids[1]}
fi

scripts/bundle.sh --universal

echo "==> Signing with: $IDENTITY"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" \
  --identifier no.helgesverre.launcher "$APP/Contents/MacOS/HelgeLauncher"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" \
  --identifier no.helgesverre.launcher "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"

mkdir -p "$DIST"
rm -f "$ZIP"

if (( NOTARIZE )); then
  PROFILE=${APPLE_NOTARY_PROFILE:-}
  if [[ -z "$PROFILE" && -f ~/.config/terminal/release.json ]]; then
    PROFILE=$(/usr/bin/plutil -extract notaryProfile raw -o - ~/.config/terminal/release.json 2>/dev/null || true)
  fi
  [[ -n "$PROFILE" ]] || { echo "error: no notary profile (set APPLE_NOTARY_PROFILE)" >&2; exit 1; }
  NOTARY_KEYCHAIN=()
  [[ -n "${APPLE_SIGNING_KEYCHAIN:-}" ]] && NOTARY_KEYCHAIN=(--keychain "$APPLE_SIGNING_KEYCHAIN")

  echo "==> Notarizing (profile $PROFILE)"
  SUBMIT=$(mktemp -d)/submit.zip
  ditto -c -k --keepParent "$APP" "$SUBMIT"
  xcrun notarytool submit "$SUBMIT" --keychain-profile "$PROFILE" "${NOTARY_KEYCHAIN[@]}" --wait --timeout 30m --output-format json \
    | tee "$DIST/notarization.json"
  [[ "$(/usr/bin/plutil -extract status raw -o - "$DIST/notarization.json")" == "Accepted" ]] || {
    id=$(/usr/bin/plutil -extract id raw -o - "$DIST/notarization.json")
    xcrun notarytool log "$id" --keychain-profile "$PROFILE" "${NOTARY_KEYCHAIN[@]}" >&2 || true
    echo "error: notarization was not accepted" >&2; exit 1
  }
  rm -f "$SUBMIT"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > SHA256SUMS)
echo "==> $ZIP"
cat "$DIST/SHA256SUMS"
