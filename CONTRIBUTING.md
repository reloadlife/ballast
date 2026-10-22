# Contributing to Ballast

Issues and pull requests are welcome. A good first contribution is teaching [`ArtifactKind`](Sources/Ballast/Engine/ArtifactKind.swift) another kind of build folder: a name plus the marker file that proves it. The marker can sit beside the folder (`Cargo.toml`, any `*.csproj`), inside it (`pyvenv.cfg`, `CACHEDIR.TAG`, `lcov.info`), or, for a folder inside another one like `Carthage/Build`, in the project two levels up. Add a case to the table in `AutoCleanTests.swift`, which checks every kind with and without its marker. Please add a test for anything that touches the safety rules.

```sh
swift build && swift test
```

## Building

Or build it yourself (needs Xcode 27 on macOS 26 or later for the Shortcuts actions; with an older Xcode, `bundle.sh` warns and builds without them):

```sh
git clone https://github.com/reloadlife/ballast.git
cd ballast
./scripts/bundle.sh        # builds Ballast.app
open Ballast.app
```

## Releasing

Push a tag like `v0.2.0` and the [release workflow](.github/workflows/release.yml) tests, builds and publishes `Ballast.zip`. It signs with a Developer ID and notarizes automatically when these repository secrets are set: `MACOS_CERTIFICATE_P12` (base64 `.p12`), `MACOS_CERTIFICATE_PASSWORD`, `NOTARY_KEY_P8` (base64 App Store Connect API key), `NOTARY_KEY_ID` and `NOTARY_ISSUER_ID`. Without them, releases are signed ad-hoc.

In-app updates need one more secret, `SPARKLE_ED_PRIVATE_KEY`, and the matching public key in the repository. Set both up once, on your Mac:

```sh
./scripts/sparkle-setup.sh          # creates the key in your login keychain,
                                    # writes Resources/sparkle-public-key.txt
.build/artifacts/sparkle/Sparkle/bin/generate_keys -x private.key
gh secret set SPARKLE_ED_PRIVATE_KEY < private.key
rm private.key
git add Resources/sparkle-public-key.txt && git commit -m "Add Sparkle public key"
```

From then on, `bundle.sh` builds the public key into the app, and each release also publishes `appcast.xml`, signed with the private key, next to `Ballast.zip`. The app reads it from `releases/latest/download/appcast.xml`, so it always sees the newest release. Keep the key in your keychain and a backup: updates signed with any other key won't install over existing copies. Sparkle compares build numbers (`CFBundleVersion`, the workflow's run number), so every release is newer than the last. Without the secret, releases skip the appcast and nothing else changes.

Opt-in usage data needs a PostHog project. Create one (US or EU cloud), copy its **Project API key** (`phc_…`, meant to be public), and either commit it or give it to the workflow:

```sh
# Either: commit it (read by bundle.sh for release builds)
cp Resources/telemetry.example.json Resources/telemetry.json   # fill in apiKey and host
git add Resources/telemetry.json && git commit -m "Add PostHog project key"

# Or: repository variables (secrets work too)
gh variable set POSTHOG_API_KEY --body "phc_…"
gh variable set POSTHOG_HOST --body "https://eu.i.posthog.com"   # default: https://us.i.posthog.com
```

In the PostHog project's settings, also turn on discarding client IP data, so the address requests come from isn't stored with events. Local builds (`./scripts/bundle.sh` without `BUILD_NUMBER`) skip the committed file, so development never reports into the real project; `TELEMETRY_DEV=1` opts back in, and `POSTHOG_API_KEY`/`POSTHOG_HOST` in the environment always apply (plain `http://` is accepted only for `127.0.0.1` or `localhost`, for a local test server). Without a key, releases build as before and Settings › Privacy says usage sharing isn't set up.
