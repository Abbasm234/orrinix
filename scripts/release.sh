#!/bin/bash
# One-command release: bump VERSION, test, build a notarized .app, move the
# CHANGELOG's Unreleased section under the new version, commit, tag, push and
# publish the GitHub release with the ZIP and its SHA-256 file.
#
#   scripts/release.sh --check    # only report what is missing, change nothing
#   scripts/release.sh            # patch: 1.0.2 -> 1.0.3
#   scripts/release.sh minor      # 1.0.2 -> 1.1.0
#   scripts/release.sh major      # 1.0.2 -> 2.0.0
#
# Optional settings:
#   GITHUB_REPOSITORY        defaults to this checkout's GitHub remote
#   NOTARY_PROFILE           defaults to OrrinixNotary
#   HOMEBREW_TAP_REPOSITORY  when set, the cask in that tap is updated too
#   HOMEBREW_CASK_NAME       defaults to orrinix
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
part=${1:-patch}
cd "$root"

# GUI-launched shells and fresh terminals may not have Homebrew on PATH.
for prefix in /opt/homebrew/bin /usr/local/bin; do
  case ":$PATH:" in *":$prefix:"*) ;; *) [ -d "$prefix" ] && PATH="$prefix:$PATH" ;; esac
done
export PATH

repo=${GITHUB_REPOSITORY:-$(git remote get-url origin 2>/dev/null | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}
tap_repo=${HOMEBREW_TAP_REPOSITORY:-}
cask=${HOMEBREW_CASK_NAME:-orrinix}
export NOTARY_PROFILE=${NOTARY_PROFILE:-OrrinixNotary}

# Preflight: every check runs and reports, so one run lists everything that
# needs fixing instead of stopping at the first problem.
problems=0
ok() { printf '  \342\234\223 %s\n' "$1"; }
missing() {
  printf '  \342\234\227 %s\n' "$1"
  printf '      %s\n' "${@:2}"
  problems=$((problems + 1))
}

# The Team ID is the OU of any installed Apple signing certificate, so the
# notarytool hint can be pasted as is instead of containing placeholders.
team_id() {
  local name
  name=$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/"(Apple Development|Developer ID Application): / { print $2; exit }')
  [ -n "$name" ] || return 0
  security find-certificate -c "$name" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's#.*/OU=\([A-Z0-9]*\)/.*#\1#p'
}

echo "==> Checking release prerequisites"
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "main" ]; then ok "on main"; else missing "on $branch, not main" "git switch main"; fi
if [ -z "$(git status --porcelain)" ]; then ok "working tree clean"; else missing "uncommitted changes" "commit or stash them first (git status)"; fi
if [ -n "$repo" ]; then ok "GitHub repository: $repo"; else missing "GitHub repository unknown" "set GITHUB_REPOSITORY=owner/name"; fi
if ! command -v gh >/dev/null; then
  missing "GitHub CLI not installed" "brew install gh"
elif ! gh auth status >/dev/null 2>&1; then
  missing "GitHub CLI not logged in" "gh auth login"
else
  ok "GitHub CLI logged in"
fi
if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Developer ID Application: '; then
  ok "Developer ID Application certificate"
else
  missing "no Developer ID Application certificate in the keychain" \
    "Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application" \
    "(Account Holder only), or import the .p12 exported from the Mac that has it."
fi
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  ok "notarytool profile $NOTARY_PROFILE"
else
  team=$(team_id)
  missing "notarytool profile '$NOTARY_PROFILE' not found. Run this and answer its two questions:" \
    "xcrun notarytool store-credentials $NOTARY_PROFILE${team:+ --team-id $team}" \
    "(your Apple ID email, then an app-specific password from account.apple.com)"
fi
if grep -q '^## \[Unreleased\]' CHANGELOG.md 2>/dev/null; then
  ok "CHANGELOG.md has an Unreleased section"
else
  missing "CHANGELOG.md has no '## [Unreleased]' section" "add one describing this release"
fi
if [ -n "$tap_repo" ]; then ok "Homebrew tap: $tap_repo"; else ok "Homebrew tap: none (cask update skipped)"; fi

if [ "$problems" -gt 0 ]; then
  echo "==> $problems prerequisite(s) missing; nothing was changed." >&2
  exit 1
fi
if [ "$part" = "--check" ]; then
  echo "==> Ready to release."
  exit 0
fi

# Bump.
current=$(tr -d '[:space:]' < VERSION)
IFS=. read -r major minor patch <<< "$current"
case "$part" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
  *) echo "usage: $0 [--check|major|minor|patch]" >&2; exit 1 ;;
esac
version="$major.$minor.$patch"
tag="v$version"
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && { echo "tag $tag already exists" >&2; exit 1; }
echo "==> $current -> $version"

# Verify before anything is published.
swift build
swift test
if command -v shellcheck >/dev/null; then
  shellcheck sysdata scripts/*.sh
else
  echo "warning: shellcheck not installed; skipping shell lint (brew install shellcheck)" >&2
fi

# Builds, signs, notarizes, staples and zips dist/Orrinix-vX.Y.Z-macOS.zip
# plus its .sha256. Nothing in the repository changes until it succeeds.
scripts/notarize-release.sh "$version"
archive="dist/Orrinix-v$version-macOS.zip"
[ -f "$archive" ] && [ -f "$archive.sha256" ] || { echo "missing $archive or its .sha256" >&2; exit 1; }

# Release notes: the CHANGELOG's Unreleased section, with image paths made
# absolute so they render on the release page.
notes=$(mktemp)
awk '/^## \[Unreleased\]/ { on = 1; next } /^## \[/ { on = 0 } on' CHANGELOG.md \
  | sed -E "s#(src|href)=\"assets/#\\1=\"https://raw.githubusercontent.com/$repo/$tag/assets/#g" \
  | sed -E '/^The next release \(.*\)\. Build from source to try it today\.$/d' \
  | cat -s | sed '/./,$!d' > "$notes"
{
  echo
  echo "## Install"
  echo
  echo "Requires macOS 14 or later. Download \`Orrinix-v$version-macOS.zip\`, check it against the \`.sha256\` file, unzip it and move Orrinix.app to /Applications. Signed with Developer ID and notarized by Apple."
} >> "$notes"

# CHANGELOG: the Unreleased section becomes this version.
today=$(date +%Y-%m-%d)
sed -i '' \
  -e "s/^## \[Unreleased\]$/## [Unreleased]\\
\\
## [$version] - $today/" \
  -e "s#^\[Unreleased\]: \(.*\)/compare/v[0-9.]*\.\.\.HEAD#[Unreleased]: \1/compare/$tag...HEAD\\
[$version]: \1/compare/v$current...$tag#" \
  CHANGELOG.md
sed -i '' '/^The next release (.*)\. Build from source to try it today\.$/d' CHANGELOG.md
squeezed=$(mktemp)
cat -s CHANGELOG.md > "$squeezed" && mv "$squeezed" CHANGELOG.md
printf '%s\n' "$version" > VERSION

# Commit, tag, push, publish.
git add VERSION CHANGELOG.md
git commit -q -m "chore: release $tag"
git tag -a "$tag" -m "$tag"
git push -q origin main "$tag"
gh release create "$tag" "$archive" "$archive.sha256" --repo "$repo" --title "Orrinix $tag" --notes-file "$notes"
rm -f "$notes"

# Homebrew cask, only when a tap is configured.
if [ -n "$tap_repo" ]; then
  sha=$(cut -d' ' -f1 < "$archive.sha256")
  tap_dir=$(mktemp -d)
  gh repo clone "$tap_repo" "$tap_dir" -- -q
  sed -i '' \
    -e "s/version \"[0-9.]*\"/version \"$version\"/" \
    -e "s/sha256 \"[0-9a-f]*\"/sha256 \"$sha\"/" \
    "$tap_dir/Casks/$cask.rb"
  ruby -c "$tap_dir/Casks/$cask.rb" >/dev/null
  git -C "$tap_dir" commit -qam "$cask $version"
  git -C "$tap_dir" push -q origin main
  rm -rf "$tap_dir"
fi

echo "==> released $tag: https://github.com/$repo/releases/tag/$tag"
