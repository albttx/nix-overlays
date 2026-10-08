#!/usr/bin/env bash
#
# Refresh versions/gno.json and versions/tx-indexer.json from the newest
# upstream GitHub release.
#
# Hashes are derived from each release's own checksum manifest and converted to
# SRI with `nix hash convert`, so no release binary is ever downloaded.
#
# usage: update-versions.sh [--gno VERSION] [--tx-indexer VERSION] [--check]
#
#   --gno / --tx-indexer  pin a specific version instead of resolving the latest
#   --check               report what would change and exit 1 if anything would,
#                         without writing

set -euo pipefail

# Works both from a checkout and from `nix run`, where the script itself lives
# in the store and the checkout is wherever it was invoked.
if [ -n "${GNO_NIX_ROOT:-}" ]; then
  repo_root=$GNO_NIX_ROOT
elif repo_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$repo_root" ]; then
  :
else
  repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

versions_dir="$repo_root/versions"

if [ ! -d "$versions_dir" ]; then
  echo "update-versions: '$repo_root' has no versions/ directory." >&2
  echo "Run this from a gno-nix checkout, or set GNO_NIX_ROOT to one." >&2
  exit 1
fi

gno_pin=""
tx_indexer_pin=""
check_only=0

while [ $# -gt 0 ]; do
  case "$1" in
    --gno) gno_pin="${2#v}"; shift 2 ;;
    --tx-indexer) tx_indexer_pin="${2#v}"; shift 2 ;;
    --check) check_only=1; shift ;;
    -h | --help) sed -n '3,14p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "update-versions: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

# Platform -> the os_arch fragment upstream uses in its asset names.
platforms=(
  "aarch64-darwin:darwin_arm64"
  "aarch64-linux:linux_arm64"
  "x86_64-darwin:darwin_amd64"
  "x86_64-linux:linux_amd64"
)

log() { printf '%s\n' "$*" >&2; }

# curl with the token GitHub Actions provides, when there is one. Unauthenticated
# calls work too but share a 60/hour rate limit.
gh_curl() {
  local auth=()
  [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl --fail --silent --show-error --location "${auth[@]}" "$@"
}

# Highest vX.Y.Z release of a repo, excluding drafts, prereleases and the
# non-semver tags gno uses for chain genesis (chain/mainnet, chain/onyx, ...).
latest_version() {
  local repo=$1
  gh_curl "https://api.github.com/repos/$repo/releases?per_page=100" \
    | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
    | sed 's/^v//' \
    | sort -V \
    | tail -1
}

to_sri() { nix hash convert --hash-algo sha256 --to sri "$1"; }

# Look an asset up in a `sha256sum`-format checksum manifest and return it as SRI.
sri_for_asset() {
  local checksums=$1 asset=$2 hex
  hex=$(awk -v want="$asset" '$2 == want { print $1 }' <<<"$checksums" | head -1)
  if [ -z "$hex" ]; then
    log "  ! no checksum entry for '$asset'"
    return 1
  fi
  to_sri "$hex"
}

# gnolang/gno: five bare executables per platform, checksums in CHECKSUMS.txt.
#
# The release entry also pins the source tree at the same tag. The release
# binaries carry a GNOROOT baked in at upstream's CI path
# (/home/runner/work/gno/gno), so they cannot find the Gno standard libraries
# anywhere real; the overlay assembles a GNOROOT from this source and points
# them at it. Pinning per release keeps a recorded older version's stdlibs in
# step with its own binaries.
build_gno_release() {
  local version=$1 checksums binaries tool platform system suffix sri source_json

  checksums=$(gh_curl "https://github.com/gnolang/gno/releases/download/v$version/CHECKSUMS.txt")

  binaries='{}'
  for tool in gno gnokey gnoland gnodev gnoweb; do
    local tool_obj='{}'
    for platform in "${platforms[@]}"; do
      system=${platform%%:*}
      suffix=${platform##*:}
      sri=$(sri_for_asset "$checksums" "${tool}_${suffix}")
      tool_obj=$(jq --arg s "$system" --arg h "$sri" '.[$s] = $h' <<<"$tool_obj")
    done
    binaries=$(jq --arg t "$tool" --argjson o "$tool_obj" '.[$t] = $o' <<<"$binaries")
  done

  # `nix flake prefetch` gives both fields builtins.fetchTree needs to fetch
  # this exact tree purely.
  source_json=$(nix flake prefetch --json "github:gnolang/gno/v$version" \
    | jq '{ rev: .locked.rev, narHash: .hash }')

  jq -n --argjson s "$source_json" --argjson b "$binaries" '{ source: $s, binaries: $b }'
}

# gnolang/tx-indexer: one tarball per platform, checksums in checksums.txt.
build_tx_indexer_release() {
  local version=$1 checksums entry platform system suffix sri
  checksums=$(gh_curl "https://github.com/gnolang/tx-indexer/releases/download/v$version/checksums.txt")

  entry='{}'
  for platform in "${platforms[@]}"; do
    system=${platform%%:*}
    suffix=${platform##*:}
    sri=$(sri_for_asset "$checksums" "tx-indexer_${version}_${suffix}.tar.gz")
    entry=$(jq --arg s "$system" --arg h "$sri" '.[$s] = $h' <<<"$entry")
  done
  printf '%s' "$entry"
}

changed=0

update_manifest() {
  local name=$1 repo=$2 pin=$3
  local file="$versions_dir/$name.json" version current updated release

  version=$pin
  if [ -z "$version" ]; then
    version=$(latest_version "$repo")
    [ -n "$version" ] || { log "$name: could not resolve a latest version from $repo"; return 1; }
  fi

  current=$(jq -r '.default // ""' "$file" 2>/dev/null || echo "")
  log "$name: upstream latest $version, manifest default ${current:-none}"

  # Already the default and already recorded: nothing to do.
  if [ "$version" = "$current" ] && jq -e --arg v "$version" '.releases[$v]' "$file" >/dev/null 2>&1; then
    return 0
  fi

  log "$name: recording $version"
  case "$name" in
    gno) release=$(build_gno_release "$version") ;;
    tx-indexer) release=$(build_tx_indexer_release "$version") ;;
    *) log "$name: no release builder"; return 1 ;;
  esac

  updated=$(jq -S --arg v "$version" --argjson r "$release" \
    '.default = $v | .releases[$v] = $r' "$file")

  if [ "$check_only" -eq 1 ]; then
    log "$name: would update to $version"
    changed=1
    return 0
  fi

  printf '%s\n' "$updated" > "$file"
  changed=1
  log "$name: wrote $file"
}

# Seed an empty manifest so a first run has something to merge into.
for name in gno tx-indexer; do
  [ -f "$versions_dir/$name.json" ] || printf '{\n  "default": "",\n  "releases": {}\n}\n' > "$versions_dir/$name.json"
done

update_manifest gno gnolang/gno "$gno_pin"
update_manifest tx-indexer gnolang/tx-indexer "$tx_indexer_pin"

# The source builds track gno through the `gno-src` flake input, so the input's
# tag has to move with the manifest default or `gno-tools-source` would lag the
# release binaries.
gno_default=$(jq -r '.default' "$versions_dir/gno.json")
if [ "$check_only" -eq 0 ] && [ -n "$gno_default" ]; then
  if [ -f "$repo_root/flake.nix" ] \
    && grep -qE 'github:gnolang/gno/v[0-9]+\.[0-9]+\.[0-9]+' "$repo_root/flake.nix"; then
    sed -i -E "s|github:gnolang/gno/v[0-9]+\.[0-9]+\.[0-9]+|github:gnolang/gno/v$gno_default|" \
      "$repo_root/flake.nix"
    log "gno-src: pinned to v$gno_default, relocking"
    (cd "$repo_root" && nix flake lock)
  fi
fi

if [ "$changed" -eq 0 ]; then
  log "everything already up to date"
  exit 0
fi

[ "$check_only" -eq 1 ] && exit 1
exit 0
