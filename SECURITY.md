# Security Policy

## System and Scope

Orrinix is a local-only macOS menu-bar utility that inventories storage and,
after explicit confirmation, removes selected cleanup targets. It has no
service, account system, network API, telemetry, or remote command channel.

This policy covers the SwiftPM sources, tests, packaging scripts, filesystem
probes, Safari storage cleaner, reclaim logic, shell-command wrappers, and
published release artifacts in this repository.

Orrinix is maintained and published by Abbas Muhammad. The latest published
release and the current `main` branch are supported; older releases are
unsupported.

## Threat Model and Trust Boundaries

- The intended trusted actor is the local user who intentionally launches
  Orrinix.
- Sensitive assets include user files, Safari WebsiteData and caches, app and
  system caches, administrator authorization, and cleanup metadata.
- Untrusted inputs include filesystem names and contents, symlink targets,
  disappearing files, permission errors, and output from optional system tools.
- Important trust boundaries are the SwiftUI confirmation flow to cleanup
  services, user-owned files to privileged fallbacks, Safari process state to
  Safari cleanup, and the app bundle to local shell tools.
- Orrinix should fail closed when path validation, permissions, Safari process
  state, command output, or target ownership is uncertain.

## Security Invariants

- No cleanup occurs without explicit user confirmation.
- Cleanup actions operate only on their declared paths. Safari cleanup uses an
  allow-list and canonicalized paths and never targets the Safari container
  root or its parent.
- Symlinks must not expand outside an approved root; unsafe targets are
  rejected.
- Orrinix never intentionally deletes Safari.app, bookmarks, history, profiles,
  passwords, iCloud Keychain data, or unrelated WebKit data.
- Safari cleanup must quit Safari and abort if Safari remains running or
  reopens before mutation. It must not terminate unrelated WebKit processes.
- User-facing cleanup uses native FileManager/Trash operations where possible.
  Privileged commands are fixed in source control and filesystem paths are
  shell-quoted.
- Review cleanup is recoverable through Trash when supported. Reclaimed bytes
  represent measured filesystem free-space change, not an estimate.
- Logs and cleanup history must not contain cookies, passwords, website
  content, local-storage content, or browsing history.
- Scanning and cleanup work must remain off the main UI thread and safely
  handle missing or permission-denied files.

## Reportable Findings and Severity Context

Please report privately before making a public disclosure. Reportable examples
include:

- path traversal, symlink escape, arbitrary path or command execution, deletion
  outside an approved target, or whole-container deletion;
- cleanup that runs without confirmation, while Safari is writing, or against
  unrelated WebKit processes;
- leakage of passwords, cookies, site content, or administrator credentials;
- a privilege-boundary bypass, shell injection, or crafted filesystem/tool
  output that causes unsafe mutation; and
- a release or packaging change that disables these controls.

Severity guidance:

- **Critical:** remote or untrusted input enables arbitrary command execution or
  broad data loss. Because Orrinix is local-only, remote reachability must be
  demonstrated.
- **High:** local untrusted filesystem or tool input bypasses the allow-list or
  confirmation and deletes protected or unrelated data or exposes secrets.
- **Medium:** a privilege-boundary, process-state, or logging flaw with
  constrained but real impact.
- **Low:** a defense-in-depth issue without reachable data loss or exposure.

Crashes, ordinary scan inaccuracies, and UI defects without security impact are
normal bug reports unless they bypass a security invariant.

## Out of Scope, Exclusions, and Accepted Risk

- Ordinary storage-size inaccuracies, stale macOS Storage categorization,
  visual polish, and unsupported third-party tools are not security findings
  unless they enable unsafe mutation.
- User-requested cleanup of explicitly selected data is intended behavior;
  report only when scope or consent controls can be bypassed.
- The local administrator prompt, macOS TCC/Full Disk Access behavior, APFS
  sparse-file accounting, and Apple/system-tool behavior are platform
  dependencies. Report Orrinix-specific unsafe handling of those dependencies.
- Orrinix has no remote server or network protocol. Report supply-chain or
  release issues when they are tied to this repository or its artifacts.

## Known Limitations and Compensating Controls

- Full Disk Access is required for complete visibility. Missing access must be
  visible and must not be treated as proof that a path is empty.
- Ad-hoc builds may not retain macOS privacy grants across rebuilds. Use a
  stable Apple Development or Developer ID identity for distribution.
- Some privileged or system cleanup actions depend on OS tools and administrator
  authorization; failures must stop and surface an error.
- macOS can reclassify System Data asynchronously, so the inventory is not an
  exact replica of Storage Settings.
- Review items may go to Trash, so disk space is not reclaimed until Trash is
  emptied. Estimated bytes must not be reported as freed.
- Reports should include the Orrinix version or commit, macOS version, impact,
  minimal reproduction steps that contain no personal data, and redacted logs.
  Do not attach Safari databases, credentials, cookies, or personal files.

## Reporting a Vulnerability

Please do not open a public issue for suspected vulnerabilities. Use GitHub's
private Security Advisories ("Report a vulnerability") for
`Abbasm234/orrinix` when available. If that channel is unavailable, contact
Abbas Muhammad privately through the GitHub profile.

Include the affected version or commit, macOS version, security impact,
minimal reproduction steps, and redacted logs. Do not include passwords,
cookies, Safari databases, or personal files. Please allow reasonable time for
investigation and coordinated disclosure.
