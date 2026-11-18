# Releases

The [Release workflow](../.github/workflows/release.yml) builds a universal app, signs it with the Developer ID certificate (hardened runtime), notarizes and staples it, and uploads `HelgeLauncher-X.Y.Z-universal.zip` plus `SHA256SUMS`. A version tag also publishes a GitHub release and writes `Casks/helge-launcher.rb` in [homebrew-tap](https://github.com/HelgeSverre/homebrew-tap) from `packaging/helge-launcher.rb`.

## Publish a version

1. Set `VERSION` (`X.Y.Z`) and write `release-notes/X.Y.Z.md` (short headings and bullets, user-visible changes).
2. Commit to `main`, then tag that commit:

   ```sh
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

The tag must match `VERSION` and be on `main`. A rerun of a failed tag run resumes only when the uploaded checksums match; a changed build needs a new version. The cask update refuses to downgrade.

Test signing and notarization without publishing:

```sh
gh workflow run release.yml --ref main
```

## Local

```sh
just release-status  # Developer ID identity and notary profile
just package         # signed ZIP, no notarization
just release         # signed, notarized, stapled ZIP in dist/
just install         # Developer ID signed dev build → /Applications
```

Local signing uses the single `Developer ID Application` identity in the Keychain (or `APPLE_APPLICATION_SIGNING_IDENTITY`) and the notary profile from `APPLE_NOTARY_PROFILE` or `notaryProfile` in `~/.config/terminal/release.json`.

Dev builds are signed with the same Developer ID, so the Accessibility grant (keyed on team + bundle id) survives rebuilds and updates. Ad-hoc builds lose it on every rebuild.

## Credentials

Recovery source: Helge's **Personal** 1Password vault, item **Helge Launcher Release Signing**. The Developer ID certificate and notarization API key are shared with Helge Terminal; that item references the originals in **Sourcefour Release Signing** and **Terminal Release Signing**.

| Repository secret | Value |
| --- | --- |
| `APPLE_APPLICATION_CERTIFICATE_BASE64` | Base64 application PKCS#12 export |
| `APPLE_APPLICATION_CERTIFICATE_PASSWORD` | Export password |
| `APPLE_APPLICATION_SIGNING_IDENTITY` | Developer ID Application identity |
| `APPLE_NOTARY_KEY_BASE64` | Base64 notarization API private key |
| `APPLE_NOTARY_KEY_ID` | API key ID |
| `APPLE_NOTARY_ISSUER_ID` | API issuer ID |
| `APPLE_TEAM_ID` | Apple developer team ID |
| `HOMEBREW_TAP_TOKEN` | Fine-grained token `helge-launcher-homebrew-tap`: homebrew-tap only, Contents RW, Metadata R, no expiry |

The signing job imports the certificate into a temporary Keychain, stores the notary profile there, deletes the import files, and deletes the Keychain at the end even on failure. Only the ZIP and `SHA256SUMS` are uploaded as artifacts.
