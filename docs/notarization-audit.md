# Orrinix notarization audit

Audit date: 2026-09-07

## Project

- Project type: Swift Package Manager executable package (`Package.swift`).
- Target: `Orrinix` executable, with `OrrinixTests` as its test target.
- There is no `.xcodeproj`, `.xcworkspace`, or Xcode scheme to archive.
- Deployment target: macOS 14.0 or later.
- Bundle identifier: `com.orrinix.mac`.
- Version source: the root `VERSION` file (currently `0.3.4`).

## Current signing state

- The existing local `dist/Orrinix.app` was inspected before production changes.
- Its signature is ad-hoc (`flags=0x2(adhoc)`), with no Team Identifier.
- `spctl --assess --type execute` cannot accept this ad-hoc artifact.
- `security find-identity -p codesigning -v` returned **0 valid identities** on
  this Mac on the audit date.
- No Developer ID Application certificate is installed, so no production
  signing or notarization submission was attempted.
- App Store Connect login is not itself a Developer ID certificate or a
  `notarytool` Keychain credential.

## Runtime, entitlements, and sandbox

- The current SwiftPM app has no entitlements file and no embedded provisioning
  profile.
- The existing ad-hoc artifact does not have a production Hardened Runtime
  signature.
- App Sandbox is not enabled. This is intentional: Orrinix needs to inspect
  user and system storage locations and relies on Full Disk Access where macOS
  requires it.
- The production script signs with `--options runtime --timestamp`, rejects
  `com.apple.security.get-task-allow`, and records the final entitlements.

## Nested executable components

The inspected app contains one Mach-O executable:

- `Contents/MacOS/Orrinix`

There are no embedded frameworks, XPC services, helper executables, dylibs,
privileged helper bundles, login items, or third-party package binaries in the
current app bundle. The resource bundle and icon are data-only resources.

## Potential notarization blockers

1. A **Developer ID Application** certificate must be installed and must match
   the Apple Developer Team that owns `com.orrinix.mac`.
2. A secure `xcrun notarytool` Keychain profile is required. The release script
   defaults to `OrrinixNotary` and never stores credentials in the repository.
3. Apple Developer Program access must permit Developer ID signing and
   notarization. App Store Connect access alone does not prove that access.
4. A stable signing identity is needed for Full Disk Access grants to persist
   across rebuilds.

## Changes made for production preparation

- Added `scripts/notarize-release.sh`, which builds the SwiftPM release,
  creates the app bundle, signs nested code deepest-first, verifies Hardened
  Runtime and entitlements, submits with `notarytool`, staples the ticket,
  runs Gatekeeper verification, creates the final post-stapling ZIP, and writes
  a SHA-256 checksum.
- Added `docs/releasing.md` with prerequisites, commands, and troubleshooting.
- The final production workflow intentionally fails instead of falling back to
  ad-hoc signing when required Apple credentials are missing.
