# Releasing Short Circuit

Releases are cut by pushing a `vX.Y.Z` tag. `.github/workflows/release.yml`
runs the unit tests, then builds, signs, notarizes, staples, packages, and
publishes a DMG and a zip to the GitHub Release for that tag. Before the first
release, complete the one-time setup below.

> The repository is assumed to be `inxilpro/short-circuit`. The workflows do
> not hard-code it (they publish to whatever repository they run in), but the
> download link in `README.md` does; update it if the repository lives
> elsewhere.

Short Circuit is distributed outside the Mac App Store with Developer ID
signing and notarization. It cannot be sandboxed: the sandbox blocks both
`lsregister -dump` and the default-handler setters, which are the whole app.
The hardened runtime is on, and the app needs no entitlements.

## Runner image and Xcode

Both workflows run on GitHub's `xcode-27` image with
`/Applications/Xcode_27.0.app`. The project file is in Xcode 27's format and
targets macOS 26.6, and the GA `macos-26` image only has Xcode 26.0.1–26.6
(macOS SDK 26.5 at most), so it can't build this project. `xcode-27` is a
**preview** image: expect GitHub to rename or retire it. When a GA `macos-27`
image ships, change `runs-on` and `XCODE_APP` in both workflows together.
Current images: <https://github.com/actions/runner-images#available-images>.

## One-time setup

### 1. Developer ID Application certificate

1. In Xcode → Settings → Accounts → your team (657AK7D2D9) → Manage
   Certificates, create a **Developer ID Application** certificate if one does
   not exist (or create it at developer.apple.com → Certificates). The one
   Chronicle uses works here too; it belongs to the team, not the app.
2. In Keychain Access, find the certificate (with its private key), select
   both, and export as a `.p12`, choosing an export password.
3. Base64-encode it for the secret:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

   The clipboard contents become `MACOS_CERTIFICATE_P12`; the export password
   becomes `MACOS_CERTIFICATE_PASSWORD`.

### 2. App Store Connect API key (for notarization)

1. In App Store Connect → Users and Access → Integrations → App Store Connect
   API → Team Keys, generate a key with the **Developer** role (or reuse
   Chronicle's key; it isn't tied to an app).
2. Download the `.p8` file (only possible once).
3. Record:
   - the **Key ID** → `ASC_KEY_ID`
   - the **Issuer ID** (top of the keys page) → `ASC_ISSUER_ID`
   - the file contents (`cat AuthKey_XXXX.p8`) → `ASC_PRIVATE_KEY`

No App Store Connect app record is needed for Developer ID notarization.

### 3. GitHub secrets

The names match Chronicle's, so the same values can be set on this
repository. Set each secret (Settings → Secrets and variables → Actions, or
with `gh`):

```sh
gh secret set MACOS_CERTIFICATE_P12       # base64 of the Developer ID .p12
gh secret set MACOS_CERTIFICATE_PASSWORD  # the .p12 export password
gh secret set KEYCHAIN_PASSWORD           # any random string, e.g. `uuidgen`
gh secret set APPLE_TEAM_ID               # 657AK7D2D9
gh secret set ASC_KEY_ID                  # App Store Connect API key ID
gh secret set ASC_ISSUER_ID               # App Store Connect API issuer ID
gh secret set ASC_PRIVATE_KEY             # contents of the .p8 file
```

`KEYCHAIN_PASSWORD` protects only the throwaway keychain created for a single
CI run; any random value is fine. `GITHUB_TOKEN` is provided automatically;
the workflow's `permissions: contents: write` lets it create the release.
No repository variables are needed.

## Cutting a release

1. Make sure `main` is green (CI runs an unsigned Release build and the unit
   tests).
2. Choose the next version. The tag is the single source of truth: the
   workflow strips the `v` and overrides both `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` with it, so the `1.0` in the project file is only
   what local builds report. Use strictly increasing `X.Y.Z` versions; an
   in-app updater added later will compare them.
3. Tag and push:

   ```sh
   git tag v1.0.0
   git push origin v1.0.0
   ```

4. Watch the Release workflow. On success the GitHub Release for the tag
   contains `Short-Circuit-X.Y.Z.dmg` and `Short-Circuit-X.Y.Z.zip` (asset
   names use a hyphen because GitHub rewrites spaces), and the log prints
   their SHA-256 sums for a future Homebrew cask.

A tag that isn't `vX.Y.Z` fails in the first step. A failed run leaves no
release behind; fix the problem, delete the tag locally and remotely
(`git push origin :refs/tags/v1.0.0`), and push it again.

## Verifying a release

Do this after the first release and any time signing changes:

1. Download the DMG from the release, drag the app to `/Applications`, and
   launch it. Gatekeeper should show no warnings (notarized and stapled).
2. Spot-check locally:

   ```sh
   codesign --verify --deep --strict --verbose=2 "/Applications/Short Circuit.app"
   codesign --display --verbose=2 "/Applications/Short Circuit.app"   # Developer ID, Timestamp, flags=…(runtime)
   spctl -a -t exec -vv "/Applications/Short Circuit.app"               # source=Notarized Developer ID
   xcrun stapler validate "/Applications/Short Circuit.app"
   ```

3. Confirm About Short Circuit reports the tagged version.
4. Change one default app from the inspector and confirm macOS shows its
   consent prompt and the change sticks. This is the one place the hardened,
   notarized build could differ from a Debug build, and it can only be tested
   by a person at the Mac.

## Updates

There is no in-app updater yet; users download new releases from GitHub.
Chronicle ships updates through Sparkle, and the release workflow here is
laid out so Sparkle can be added later without restructuring. It would need:

- the Sparkle Swift package and an `SPUStandardUpdaterController` with a
  **Check for Updates…** menu item in the app;
- an `Info.plist` with `SUFeedURL` and `SUPublicEDKey` (see Chronicle's
  `docs/RELEASING.md` for the key generation steps);
- Chronicle's "Re-sign Sparkle nested components" step, an appcast step, and
  the `SPARKLE_PRIVATE_KEY` secret in `release.yml`.

A Homebrew cask can point at the zip asset today.
