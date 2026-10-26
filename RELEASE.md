# Releasing Agent Secrets

Agent Secrets follows the same release setup as Picker: Sparkle 2 for updates, and GitHub Releases for downloads. Sparkle reads `https://github.com/torbensko/agent-secrets/releases/latest/download/appcast.xml`, so there's no separate server to update.

## GitHub setup

In [Actions secrets](https://github.com/torbensko/agent-secrets/settings/secrets/actions), set the same secrets as Picker:

| Secret | Value |
| --- | --- |
| `CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate **including its private key** |
| `CERTIFICATE_PASSWORD` | Password for the exported P12 |
| `APPLE_ID` | Apple account used for notarization |
| `APPLE_ID_PASSWORD` | App-specific password for that account |
| `APPLE_TEAM_ID` | Developer team ID (`D6WA425MQA`) |
| `SPARKLE_PRIVATE_KEY` | Agent Secrets' own update-signing key; set by `scripts/configure-updates.sh` |

### Provisioning profile

Picker doesn't need one; Agent Secrets does. iCloud Keychain sync needs the `keychain-access-groups` entitlement, and macOS only honours that entitlement when it's authorised by a provisioning profile, including in Developer ID builds. Without one, the app won't launch.

The Developer ID profile is committed at `Config/Secrets_Developer_ID.provisionprofile`. It isn't secret, since every shipped app embeds it, and it authorises all of the team's Developer ID Application certificates. Xcode created it by exporting a Release archive with automatic Developer ID signing. To regenerate it, for example after adding a new Developer ID certificate, do the same with `-allowProvisioningUpdates`, then copy the new profile from `~/Library/Developer/Xcode/UserData/Provisioning Profiles`.

The release job checks the profile is a Developer ID profile for `com.torbensko.secrets` before using it. It also refuses to publish an app that's missing the entitlement or the embedded profile.

### Update signing key

The public Sparkle key is committed in `Config/Updates.xcconfig`. The private key is kept in your login Keychain under account `com.torbensko.secrets`. Never commit it or paste it into logs, and never quietly generate a replacement after shipping. To upload the existing key to GitHub again:

```sh
xcodebuild -resolvePackageDependencies -project Secrets.xcodeproj -scheme Secrets -derivedDataPath build
./scripts/configure-updates.sh
```

The helper refuses a mismatched key. Keep a secure backup of the Keychain item: losing the key means a deliberate Sparkle key migration.

## Publish

1. Update `VERSION` and `RELEASE_NOTES.md`, then commit and push to `main`. The build number comes from the release workflow's run number.
2. Wait for **Test and package** to pass. Its unsigned DMG and ZIP are development builds with updates disabled, not public downloads.
3. Run **Build and release** manually from [Actions](https://github.com/torbensko/agent-secrets/actions/workflows/release.yml) on `main`.

The release workflow:

- tests the app, then archives a universal build
- exports it with Developer ID signing and the provisioning profile
- notarizes and staples the app and the DMG
- signs the ZIP and the appcast with Ed25519, and checks those signatures against the key embedded in the app
- creates a draft release, then publishes it

Existing tags and releases are never overwritten.

## Local checks

```sh
xcodegen generate
xcodebuild -project Secrets.xcodeproj -scheme Secrets -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build test CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGN_ENTITLEMENTS= DEVELOPMENT_TEAM=
./scripts/package.sh --unsigned
./scripts/test-appcast.sh
```

`Secrets.xcodeproj` is generated from `project.yml`, but it's committed, because CI builds it directly. Run `xcodegen generate` after editing `project.yml`, and commit both.

## Update behaviour

Sparkle asks permission before checking automatically. Automatic downloads start off. The Agent Secrets menu has **Check for Updates…** and the automatic-check setting. Development builds never start the updater. An agent using the MCP server launches the same executable with `--mcp`; that mode never starts the updater.
