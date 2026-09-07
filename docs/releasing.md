# Releasing Orrinix for direct macOS distribution

Orrinix is distributed outside the Mac App Store as a Developer ID-signed,
notarized ZIP. The production workflow is implemented by
`scripts/notarize-release.sh` and is separate from local ad-hoc debug builds.

## Prerequisites

Before a production release, install or confirm:

1. Apple Developer Program membership with Developer ID distribution access.
2. A **Developer ID Application** certificate in the login Keychain. In Xcode,
   open **Settings → Accounts → Manage Certificates → + → Developer ID
   Application**. Do not substitute an Apple Development certificate.
3. The correct bundle identifier (`com.orrinix.mac`) registered to the same
   Apple Developer Team.
4. Xcode command-line tools, including `swift`, `codesign`, `xcrun`, `ditto`,
   `spctl`, and `shasum`.
5. A `notarytool` Keychain profile. Create it once; the command securely asks
   for the app-specific password and does not place it in source control:

   ```bash
   xcrun notarytool store-credentials OrrinixNotary \
     --apple-id "APPLE_ID_EMAIL" \
     --team-id "TEAM_ID"
   ```

   The profile name can be overridden with `NOTARY_PROFILE`, but credentials
   must remain in the macOS Keychain.

## Build a production artifact

From the repository root:

```bash
scripts/notarize-release.sh 0.3.5
```

If the `VERSION` file already contains the intended version, omit the argument:

```bash
scripts/notarize-release.sh
```

The script selects the installed Developer ID Application identity. To select
one explicitly when more than one is installed:

```bash
CODESIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  NOTARY_PROFILE=OrrinixNotary \
  scripts/notarize-release.sh 0.3.5
```

The script fails before building if the certificate, Team ID, or Keychain
profile is missing. It never falls back to ad-hoc signing for a production
artifact and never writes credentials to disk.

## Verification performed

The workflow records its checks under `dist/` and performs all of the following:

- Release SwiftPM build and app-bundle assembly.
- Deepest-first signing of any nested Mach-O code, then the main app, with
  Hardened Runtime and a secure timestamp.
- Strict code-signature verification and Team ID/bundle ID checks.
- Entitlement inspection, including rejection of `get-task-allow`.
- Pre-notarization Gatekeeper assessment.
- `xcrun notarytool submit --wait` and log retrieval on failure.
- Ticket stapling and `xcrun stapler validate`.
- Post-stapling `codesign --verify --deep --strict` and Gatekeeper assessment.
- A new post-stapling ZIP and SHA-256 checksum.

Only the final post-stapling archive should be uploaded to GitHub Releases:

```text
dist/Orrinix-vVERSION-macOS.zip
dist/Orrinix-vVERSION-macOS.zip.sha256
```

Do not distribute the pre-stapling notarization upload archive.

## Full Disk Access

Notarization does not grant Full Disk Access. Users may still need to enable
Orrinix under **System Settings → Privacy & Security → Full Disk Access** and
reopen the app after changing the grant. A stable Developer ID identity helps
macOS remember that grant across rebuilds.

## Troubleshooting

### No Developer ID Application identity

Run:

```bash
security find-identity -p codesigning -v
```

If no Developer ID Application identity is listed, create or install the
certificate in Xcode before running the release script. Do not use an ad-hoc or
Apple Development signature for public distribution.

### Notary profile unavailable

Check the Keychain profile without exposing its secret:

```bash
xcrun notarytool history --keychain-profile OrrinixNotary
```

If it is missing, run the `store-credentials` command in the prerequisites
section and let `notarytool` prompt for the app-specific password.

### Notarization is rejected

The script saves the submission response as
`dist/notarization-submission.json` and retrieves
`dist/notarization-log.json` when Apple returns a submission ID. Fix the root
cause, rebuild, re-sign, and submit the new artifact; do not resubmit an
unchanged rejected ZIP.

### Gatekeeper does not accept the stapled app

Inspect `dist/gatekeeper-final.txt`, `dist/signing.txt`, and
`dist/stapler-validate.txt`. Confirm the app was signed with the intended
Developer ID Application identity, has a secure timestamp and Hardened Runtime,
and that the final ZIP was created after stapling.
