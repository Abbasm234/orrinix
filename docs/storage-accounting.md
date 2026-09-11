# Orrinix storage accounting

Orrinix keeps filesystem capacity separate from its category scan. The scan
explains likely System Data locations; it does not try to reconstruct Apple's
private storage categories or calculate global Used by adding folders.

## Primary metrics

- **Total** is the capacity reported by `statfs` for the startup Data volume.
- **Free now** is `f_bavail * f_bsize`: blocks currently available on that
  APFS filesystem. This is the value used by both the menu bar and dashboard.
- **Used** is `Total - Free now`.
- **Available for Important Usage** and **Available for Opportunistic Usage**
  are optional `URLResourceValues` hints from macOS. They may include space
  macOS can reclaim, so neither is labelled Free.
- **Potentially reclaimable** is the positive difference between Important
  Usage capacity and current physical free space. If macOS does not provide
  that hint, Orrinix leaves it unavailable rather than inventing a number.

All values are stored as `Int64` bytes and formatted with one file-style
`ByteCountFormatStyle` at presentation time.

## APFS and the Data volume

The query uses `/System/Volumes/Data` when present, falling back to `/` only
on older systems. The signed System volume, Preboot, Recovery, VM, external
volumes and mounted disk images are not used for the primary metric. APFS
snapshots, clones, sparse files and shared extents are therefore accounted for
by the filesystem instead of being double-counted by directory recursion.

## Category estimates and System Data

Recursive probes report allocated-on-disk bytes for their own claimed roots.
They are explanatory estimates and can overlap with APFS-managed accounting;
they never control Total, Used or Free. Orrinix labels the result **Estimated
System Data** because Apple's System Data category is private and can include
snapshots, swap, caches, Safari/WebKit data and other system-managed storage.

Time Machine local snapshots are listed separately with their count and date
range when available. APFS does not reliably expose their individual byte
cost, so the UI says that their size is managed by APFS instead of guessing.

Safari and developer probes use allocated bytes and avoid parent/child totals.
After any cleanup, Orrinix samples physical free space before and after the
operation and reports only the increase actually released by the filesystem;
logical files moved to the Trash are not claimed as recovered physical space.

The fast metrics refresh on launch, menu open, scan, cleanup and every 30
seconds. Deep category scans remain asynchronous so the menu bar never waits
for a recursive walk.
