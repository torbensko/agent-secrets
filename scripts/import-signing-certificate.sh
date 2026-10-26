#!/bin/bash
# Run only on an ephemeral GitHub runner; never print certificate or password values.
set -euo pipefail
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${CERTIFICATE_P12:?Missing CERTIFICATE_P12 secret}"
: "${CERTIFICATE_PASSWORD:?Missing CERTIFICATE_PASSWORD secret}"
KEYCHAIN_PATH="$RUNNER_TEMP/secrets-signing.keychain-db"
P12_PATH="$RUNNER_TEMP/secrets-certificate.p12"
KEYCHAIN_PASSWORD="$(openssl rand -base64 32)"
echo "::add-mask::$KEYCHAIN_PASSWORD"
printf 'KEYCHAIN_PATH=%s\n' "$KEYCHAIN_PATH" >> "$GITHUB_ENV"
trap 'rm -f "$P12_PATH"' EXIT
umask 077
printf '%s' "$CERTIFICATE_P12" | base64 --decode > "$P12_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$P12_PATH" -k "$KEYCHAIN_PATH" -P "$CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null
security list-keychains -d user -s "$KEYCHAIN_PATH" login.keychain-db
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p')"
[[ -n "$IDENTITY" && "$IDENTITY" != *$'\n'* ]] || { echo 'Supply exactly one Developer ID Application identity.' >&2; exit 1; }
printf 'SIGNING_IDENTITY=%s\n' "$IDENTITY" >> "$GITHUB_ENV"

# The Keychain entitlement is restricted, so the app must embed a Developer ID provisioning profile.
# Profiles aren't secret (every shipped app carries one), so it's committed alongside the project.
: "${APPLE_TEAM_ID:?Missing APPLE_TEAM_ID}"
PROFILE_SOURCE="$RUNNER_TEMP/secrets.provisionprofile"
cp Config/Secrets_Developer_ID.provisionprofile "$PROFILE_SOURCE"
PROFILE_PLIST="$RUNNER_TEMP/secrets-profile.plist"
security cms -D -i "$PROFILE_SOURCE" > "$PROFILE_PLIST"
PROFILE_UUID="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")"
APP_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST")"
ALL_DEVICES="$(/usr/libexec/PlistBuddy -c 'Print :ProvisionsAllDevices' "$PROFILE_PLIST" 2>/dev/null || echo false)"
rm -f "$PROFILE_PLIST"
[[ "$APP_IDENTIFIER" == "$APPLE_TEAM_ID.com.torbensko.secrets" ]] || { echo 'The provisioning profile is not for com.torbensko.secrets.' >&2; exit 1; }
[[ "$ALL_DEVICES" == true ]] || { echo 'Supply a Developer ID provisioning profile, not a development one.' >&2; exit 1; }
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
mkdir -p "$PROFILE_DIR"
PROFILE_PATH="$PROFILE_DIR/$PROFILE_UUID.provisionprofile"
mv "$PROFILE_SOURCE" "$PROFILE_PATH"
printf 'PROFILE_UUID=%s\nPROFILE_PATH=%s\n' "$PROFILE_UUID" "$PROFILE_PATH" >> "$GITHUB_ENV"
