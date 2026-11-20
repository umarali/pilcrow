# Building Pilcrow

Use macOS 26 or later and Xcode 26 or later, with the full Xcode selected by `xcode-select`. From the repository root:

```sh
xcrun swift build
./tools/test.sh
./tools/build-app.sh          # release bundle
./tools/build-app.sh --debug  # debug bundle
```

The bundle is `build/Pilcrow.app`. Launch it with `open build/Pilcrow.app`. Running the binary inside the bundle or `.build/*/Pilcrow` from Terminal makes Terminal the responsible process, so permissions attach to Terminal. If you granted Terminal Screen Recording only for Pilcrow, revoke that permission in System Settings. The script replaces the previous bundle and takes its version from `PilcrowCore.version`. Tests use a throwaway HOME and synthetic data; building and testing do not launch the app or request permissions.

## Signing and permissions

The bundle ID is `org.pilcrow.app`. In accordance with D-08 and D-17, a stable signing identity lets macOS associate permissions with Pilcrow across rebuilds. Ad-hoc signatures can change on rebuild and cause permissions to be requested again. The preferred local option is an existing Apple Development identity. List identities and select its SHA-1 when building:

```sh
security find-identity -v -p codesigning
PILCROW_SIGN_IDENTITY=<SHA-1 of an "Apple Development" identity> ./tools/build-app.sh
```

This provides a stable, Apple-anchored designated requirement without writing to the keychain. If `PILCROW_SIGN_IDENTITY` is unset, the build resolves a unique `Pilcrow Local Signing` identity by SHA-1; if none is available, it uses ad-hoc signing with a warning. A `Developer ID Application:` identity gets a secure timestamp, which requires access to Apple's timestamp service. Other local signing uses no timestamp by default, so it works offline. Set `PILCROW_TIMESTAMP=1` to request a timestamp explicitly.

For people without an Apple account, `./tools/create-local-signing-identity.sh` is the fallback. It creates a self-signed code-signing certificate and imports its private key into the login keychain. To trust it, open Keychain Access, select the certificate, choose Get Info, open Trust, and set Code Signing to Always Trust; leave the other settings unchanged. Then check `security find-identity -v -p codesigning`. Keep the private key private. This local identity is not a Developer ID and does not make a distributable notarized release. If a certificate with that name already exists, the script stops without creating another; inspect or repair it manually if necessary.

To select another existing identity explicitly, set `PILCROW_SIGN_IDENTITY` to its name or SHA-1 before building. Signing is not notarization.

The hardened runtime entitlement allows audio input. The app is not sandboxed for now; sandbox restrictions and distribution requirements need separate evaluation. Microphone and speech recognition access still require the user's consent.

For a human testing permission onboarding, reset all Pilcrow permission consent, or reset Screen Recording, Microphone, and Speech Recognition individually. Remove Pilcrow's preferences as well. Earlier bare-executable runs stored preferences under the `Pilcrow` domain:

```sh
tccutil reset All org.pilcrow.app
# Or reset categories individually:
tccutil reset ScreenCapture org.pilcrow.app
tccutil reset Microphone org.pilcrow.app
tccutil reset SpeechRecognition org.pilcrow.app
defaults delete org.pilcrow.app
defaults delete Pilcrow
```

The preferences commands may report that a domain does not exist if no preferences have been saved. These commands affect local user state; they are not part of the build or automated tests.

To remove the fallback self-signed identity, first reset its trust in Keychain Access (the certificate → Get Info → Trust → When using this certificate: Use System Defaults), then run `security delete-identity -c 'Pilcrow Local Signing'`. Once the certificate is deleted it can no longer be selected in Keychain Access, so do the trust step first.

## Release (not yet implemented)

A future release path needs Developer ID signing, notarization using `notarytool` with an App Store Connect API key, and stapling. Sparkle 2 updates and a Homebrew cask are also planned, not implemented.
