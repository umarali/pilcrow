# Building Pilcrow

Use macOS 26 or later and Xcode 26 or later, with full Xcode selected by
`xcode-select`. Run these commands from the repository root.

```sh
xcrun swift build
./tools/test.sh
./tools/build-app.sh          # release configuration
./tools/build-app.sh --debug  # debug configuration
```

The script replaces `build/Pilcrow.app` and signs both executables. Launch
with `open build/Pilcrow.app` so macOS attributes permissions to Pilcrow.
Running the executable directly from Terminal can attribute permissions to
Terminal. Build and test commands leave the app closed.

## Local signing

Use a stable identity so macOS can associate permissions with Pilcrow across
rebuilds. List available identities and pass the SHA-1 for an existing Apple
Development identity.

```sh
security find-identity -v -p codesigning
PILCROW_SIGN_IDENTITY='SHA-1 from the list' ./tools/build-app.sh
```

If you leave `PILCROW_SIGN_IDENTITY` unset, the script selects a unique
`Pilcrow Local Signing` identity if present. Otherwise it uses ad-hoc signing,
which can require regranting permissions after a rebuild.

If you have no Apple Development identity, `./tools/create-local-signing-identity.sh`
creates a local certificate and imports its private key into your login
keychain. In Keychain Access, open the certificate's **Get Info → Trust** and
set **Code Signing** to **Always Trust**. Run `security find-identity -v -p codesigning`
again to check that the identity is available.

## Reset permissions for a manual test

Quit Pilcrow first. Its bundle ID is `org.pilcrow.app`. These commands reset
consent and clear saved settings for your account.

```sh
tccutil reset All org.pilcrow.app
defaults delete org.pilcrow.app
```

To reset consent for just one service, use `ScreenCapture` or `Microphone`
in place of `All`. Reopen the bundle
and follow [Manual testing](manual-testing.md).

## Release

There is no release build yet. Developer ID signing, notarization and stapling
are tracked in [#1](https://github.com/umarali/pilcrow/issues/1).
