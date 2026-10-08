#!/usr/bin/env bash
#
# Discover the buildGoModule vendorHash of every Go module in a gno source tree
# and record it in versions/vendor-hashes.json.
#
# Needed when a tag or branch changes go.mod or go.sum, because the vendorHash
# is derived from the module's dependency set. Modules whose hash is already
# recorded are skipped.
#
# usage: vendor-hash.sh [REF]
#
#   REF   a gno git ref (tag, branch or revision). Default: the tag the
#         `gno-src` flake input is pinned to.

set -euo pipefail

if [ -n "${GNO_NIX_ROOT:-}" ]; then
  repo_root=$GNO_NIX_ROOT
elif repo_root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$repo_root" ]; then
  :
else
  repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
fi

manifest="$repo_root/versions/vendor-hashes.json"

if [ ! -f "$manifest" ]; then
  echo "vendor-hash: no $manifest." >&2
  echo "Run this from a gno-nix checkout, or set GNO_NIX_ROOT to one." >&2
  exit 1
fi

case "${1:-}" in
  -h | --help)
    sed -n '3,15p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

ref=${1:-}
if [ -z "$ref" ]; then
  ref=$(grep -oE 'github:gnolang/gno/[^"]+' "$repo_root/flake.nix" | head -1 | sed 's|.*/||')
  [ -n "$ref" ] || { echo "vendor-hash: could not read the gno-src pin from flake.nix" >&2; exit 1; }
fi

log() { printf '%s\n' "$*" >&2; }

# Probe against the exact nixpkgs this repo locks, so a discovered hash matches
# what the overlays will build with.
nixpkgs_ref=$(nix flake metadata --json "$repo_root" \
  | jq -r '.locks.nodes.nixpkgs.locked | "github:\(.owner)/\(.repo)/\(.rev)"')
[ "$nixpkgs_ref" != "github:null/null/null" ] || {
  echo "vendor-hash: could not read the locked nixpkgs from $repo_root/flake.lock" >&2
  exit 1
}
log "nixpkgs: $nixpkgs_ref"

log "resolving github:gnolang/gno/$ref"
src=$(nix flake prefetch --json "github:gnolang/gno/$ref" | jq -r .storePath)
log "source: $src"

# Match lib/gno-source.nix moduleKey: sha256 over go.mod followed by go.sum.
# go.mod is part of the key because contribs/gnogenesis and contribs/gpao ship
# an identical go.sum and differ only in go.mod.
module_key() { cat "$1/go.mod" "$1/go.sum" | sha256sum | cut -d' ' -f1; }

# Build the module's vendor derivation with a deliberately wrong hash and read
# the real one out of the mismatch. Only dependencies are fetched, nothing is
# compiled.
probe_vendor_hash() {
  local dir=$1 mod_root=$2 out
  out=$(nix build --no-link --impure --expr "
    let pkgs = import (builtins.getFlake \"$nixpkgs_ref\") { system = builtins.currentSystem; };
    in (pkgs.buildGoModule {
      pname = \"vendor-probe\";
      version = \"0\";
      src = $src;
      modRoot = \"$mod_root\";
      # Must match lib/gno-source.nix, or the discovered hash is useless.
      proxyVendor = true;
      vendorHash = pkgs.lib.fakeHash;
    }).goModules
  " 2>&1) && {
    # A successful build means fakeHash was right, which cannot happen.
    log "  ! unexpected success probing $mod_root"
    return 1
  }
  printf '%s\n' "$out" | grep -oE 'got: +sha256-[A-Za-z0-9+/=]+' | head -1 | awk '{ print $2 }'
}

added=0
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cp "$manifest" "$tmp"

# The root module, then every module under contribs/. That includes modules this
# repo does not package, such as contribs/github-bot, gno's own CI bot: recording
# them costs one line each and means mkModule can build them if anyone wants to.
mod_roots=(".")
while IFS= read -r gomod; do
  rel=${gomod#"$src"/}
  mod_roots+=("${rel%/go.mod}")
done < <(find "$src/contribs" -mindepth 2 -maxdepth 2 -name go.mod | sort)

for mod_root in "${mod_roots[@]}"; do
  if [ "$mod_root" = "." ]; then dir=$src; else dir="$src/$mod_root"; fi
  [ -f "$dir/go.sum" ] || { log "$mod_root: no go.sum, skipping"; continue; }

  key=$(module_key "$dir")
  if jq -e --arg k "$key" 'has($k)' "$tmp" >/dev/null; then
    log "$mod_root: already recorded"
    continue
  fi

  log "$mod_root: probing"
  if hash=$(probe_vendor_hash "$dir" "$mod_root") && [ -n "$hash" ]; then
    log "$mod_root: $hash"
    jq -S --arg k "$key" --arg h "$hash" '.[$k] = $h' "$tmp" > "$tmp.next"
    mv "$tmp.next" "$tmp"
    added=$((added + 1))
  else
    log "$mod_root: FAILED to determine a vendorHash"
  fi
done

if [ "$added" -eq 0 ]; then
  log "nothing to add"
  exit 0
fi

mv "$tmp" "$manifest"
trap - EXIT
log "added $added entry/entries to $manifest"
