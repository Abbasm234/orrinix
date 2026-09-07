#!/bin/bash
# Build, sign, notarize, staple, verify, and package Orrinix for direct
# distribution outside the Mac App Store.
#
# Usage:
#   scripts/notarize-release.sh
#   scripts/notarize-release.sh 0.3.5
#
# Required before running:
#   * Developer ID Application certificate in the login keychain
#   * notarytool Keychain profile (default: OrrinixNotary)
#
# This script never stores or reads Apple passwords. Create the Keychain
# profile once with xcrun notarytool store-credentials.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
app_name="Orrinix"
bundle_id="com.orrinix.mac"
minimum_macos="14.0"
version=${1:-$(tr -d '[:space:]' < "$root/VERSION")}
notary_profile=${NOTARY_PROFILE:-OrrinixNotary}
requested_identity=${CODESIGN_IDENTITY:-}
requested_team=${DEVELOPMENT_TEAM:-}

dist_dir="$root/dist"
app_bundle="$dist_dir/$app_name.app"
app_binary="$app_bundle/Contents/MacOS/$app_name"
info_plist="$app_bundle/Contents/Info.plist"
notary_zip="$dist_dir/$app_name-notarization.zip"
final_zip="$dist_dir/$app_name-v$version-macOS.zip"
checksum_file="$final_zip.sha256"

die() {
  echo "error: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for command_name in xcodebuild swift codesign security ditto xcrun spctl shasum plutil file; do
  require_command "$command_name"
done

[ -f "$root/Package.swift" ] || die "Package.swift not found at $root"
[ -f "$root/VERSION" ] || die "VERSION not found at $root"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] \
  || die "invalid version '$version' (expected a semantic version)"

identities=$(security find-identity -p codesigning -v 2>/dev/null || true)
developer_identities=$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p')
[ -n "$developer_identities" ] \
  || die "no Developer ID Application certificate is installed; create one in Xcode > Settings > Accounts > Manage Certificates"
developer_identity_count=$(printf '%s\n' "$developer_identities" | awk 'NF { count += 1 } END { print count + 0 }')

identity="$requested_identity"
if [ -n "$identity" ]; then
  printf '%s\n' "$developer_identities" | grep -F -x "$identity" >/dev/null \
    || die "CODESIGN_IDENTITY is not a valid installed Developer ID Application identity"
else
  if [ -n "$requested_team" ]; then
    identity=$(printf '%s\n' "$developer_identities" | grep -F "($requested_team)" | head -1 || true)
    [ -n "$identity" ] || die "no Developer ID Application identity matches DEVELOPMENT_TEAM=$requested_team"
  elif [ "$developer_identity_count" -ne 1 ]; then
    die "multiple Developer ID Application identities are installed; set CODESIGN_IDENTITY or DEVELOPMENT_TEAM"
  else
    identity=$(printf '%s\n' "$developer_identities" | head -1)
  fi
fi

team_id=$(printf '%s\n' "$identity" | sed -n 's/.*(\([[:alnum:]-][[:alnum:]-]*\))$/\1/p')
[ -n "$team_id" ] || die "could not determine Team ID from the selected signing identity"
[ -z "$requested_team" ] || [ "$team_id" = "$requested_team" ] \
  || die "selected signing identity Team ID ($team_id) does not match DEVELOPMENT_TEAM=$requested_team"

xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
  || die "notarytool Keychain profile '$notary_profile' is unavailable; create it with xcrun notarytool store-credentials"

echo "==> Building Orrinix $version"
"$root/scripts/compile-strings.sh"
swift build -c release --package-path "$root"
bin_path=$(swift build -c release --package-path "$root" --show-bin-path)
binary="$bin_path/$app_name"
resource_bundle="$bin_path/${app_name}_${app_name}.bundle"
[ -x "$binary" ] || die "release executable was not produced: $binary"
[ -d "$resource_bundle" ] || die "resource bundle was not produced: $resource_bundle"

# dist/ contains only ignored release artifacts. Remove it before packaging so
# a stale app or archive cannot be mistaken for the current build.
rm -rf "$dist_dir"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary" "$app_binary"
cp -R "$resource_bundle" "$app_bundle/Contents/Resources/"

[ -f "$root/assets/AppIcon.icns" ] || "$root/scripts/make-icon.sh"
cp "$root/assets/AppIcon.icns" "$app_bundle/Contents/Resources/AppIcon.icns"

cat > "$info_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$app_name</string>
  <key>CFBundleExecutable</key>
  <string>$app_name</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$bundle_id</string>
  <key>CFBundleName</key>
  <string>$app_name</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$version</string>
  <key>CFBundleVersion</key>
  <string>$version</string>
  <key>LSMinimumSystemVersion</key>
  <string>$minimum_macos</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
EOF
plutil -lint "$info_plist" >/dev/null

# Sign any nested Mach-O code first, then the application bundle. The current
# SwiftPM target has no embedded frameworks or helpers, but this loop keeps the
# release safe if that changes later.
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  [ "$candidate" = "$app_binary" ] && continue
  if file "$candidate" | grep -q 'Mach-O'; then
    codesign --force --options runtime --timestamp --sign "$identity" "$candidate"
  fi
done <<EOF
$(find "$app_bundle/Contents" -type f -perm -111 -print)
EOF

codesign --force --options runtime --timestamp --sign "$identity" \
  --identifier "$bundle_id" "$app_bundle"

codesign --verify --strict --verbose=2 "$app_bundle"
codesign -dvvv "$app_bundle" > "$dist_dir/signing.txt" 2>&1
grep -F 'Authority=Developer ID Application:' "$dist_dir/signing.txt" >/dev/null \
  || die "the app is not signed with a Developer ID Application identity"
grep -F "TeamIdentifier=$team_id" "$dist_dir/signing.txt" >/dev/null \
  || die "signed app TeamIdentifier does not match $team_id"
grep -E 'flags=.*runtime' "$dist_dir/signing.txt" >/dev/null \
  || die "Hardened Runtime is not enabled in the signed app"

codesign -d --entitlements :- "$app_bundle" > "$dist_dir/entitlements.plist" 2>&1
if grep -F 'com.apple.security.get-task-allow' "$dist_dir/entitlements.plist" >/dev/null; then
  die "production app contains com.apple.security.get-task-allow"
fi

while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  if file "$candidate" | grep -q 'Mach-O'; then
    codesign --verify --strict --verbose=2 "$candidate"
  fi
done <<EOF
$(find "$app_bundle/Contents" -type f -perm -111 -print)
EOF

spctl --assess --type execute --verbose=4 "$app_bundle" > "$dist_dir/gatekeeper-prenotarization.txt" 2>&1 || true

echo "==> Creating notarization archive"
ditto -c -k --keepParent "$app_bundle" "$notary_zip"

echo "==> Submitting to Apple Notary Service (profile: $notary_profile)"
submission_json="$dist_dir/notarization-submission.json"
set +e
xcrun notarytool submit "$notary_zip" \
  --keychain-profile "$notary_profile" \
  --output-format json \
  --wait > "$submission_json" 2>&1
submit_exit=$?
set -e

submission_id=$(sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$submission_json" | head -1)
notary_status=$(sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$submission_json" | head -1)
if [ "$submit_exit" -ne 0 ] || [ "$notary_status" != "Accepted" ]; then
  if [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" --keychain-profile "$notary_profile" \
      --output-format json > "$dist_dir/notarization-log.json" 2>&1 || true
  fi
  die "Apple notarization did not return Accepted (status: ${notary_status:-unknown}); see $submission_json"
fi

echo "==> Stapling notarization ticket"
xcrun stapler staple "$app_bundle" > "$dist_dir/stapler-staple.txt" 2>&1
xcrun stapler validate "$app_bundle" > "$dist_dir/stapler-validate.txt" 2>&1
codesign --verify --deep --strict --verbose=2 "$app_bundle" > "$dist_dir/codesign-final.txt" 2>&1
spctl --assess --type execute --verbose=4 "$app_bundle" > "$dist_dir/gatekeeper-final.txt" 2>&1

echo "==> Creating final post-stapling archive"
ditto -c -k --keepParent "$app_bundle" "$final_zip"
shasum -a 256 "$final_zip" > "$checksum_file"
rm -f "$notary_zip"

cat > "$dist_dir/release-summary.txt" <<EOF
ORRINIX RELEASE STATUS
Version: $version
Bundle Identifier: $bundle_id
Team ID: $team_id
Signing Identity: $identity
Hardened Runtime: enabled
Notarization: Accepted
Stapling: passed
Gatekeeper: accepted
SHA-256: $(cut -d' ' -f1 "$checksum_file")

ARTIFACTS
App: $app_bundle
Release ZIP: $final_zip
Checksum: $checksum_file
Submission ID: ${submission_id:-unknown}
EOF

cat "$dist_dir/release-summary.txt"
