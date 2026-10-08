# gno-nix

Nix overlays and packages for the [gno.land](https://github.com/gnolang/gno)
toolchain, so any project can install the gno CLI tools with one input and pin
whatever version it needs.

Prebuilt release binaries by default, nothing compiled. Any tag, branch or
revision from source when you want one, without working out a single hash
yourself.

> **Status:** this is a staging home. The overlays are proposed for adoption by
> [gnoverse](https://github.com/gnoverse); until that is approved, use
> `github:albttx/nix-overlays`. If it moves, only the flake URL changes: the
> overlay names, package names and manifest layout stay as they are.

## Quick start

```shell
mkdir my-gno-project && cd my-gno-project
nix flake init -t github:albttx/nix-overlays
nix develop
```

That gives you a devShell with `gno`, `gnokey`, `gnoland`, `gnodev` and
`gnoweb`.

To wire it into a project by hand:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    gno-nix.url = "github:albttx/nix-overlays";
  };

  outputs =
    { nixpkgs, gno-nix, ... }:
    let
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        overlays = [ gno-nix.overlays.default ];
      };
    in
    {
      devShells.x86_64-linux.default = pkgs.mkShell {
        packages = [ pkgs.gno-tools ];
      };
    };
}
```

## Choosing a version

### The default

`pkgs.gno-tools` tracks the newest tagged upstream release, which a scheduled
workflow proposes by pull request. `pkgs.gno-nix.defaultVersion` tells you what
that is right now.

### A version this repo has recorded

```nix
pkgs.gno-nix.releases."1.4.0"          # the whole suite
pkgs.gno-nix.releases."1.4.0".gnokey   # one tool from it
```

`versions/gno.json` lists what is recorded. Each entry holds the SRI hash of
every release binary plus a pin of the source tree at that same tag.

### A version this repo has *not* recorded, or a branch

Point the `gno-src` input wherever you like and use `pkgs.gno-tools-source`.
You supply no hash: your own `flake.lock` records it.

```nix
inputs.gno-nix.url = "github:albttx/nix-overlays";

# a tag nobody here has recorded
inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/v1.8.0";

# or a branch
inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/my-feature";

# or an exact revision
inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/3f8a1c2";
```

```nix
packages = [ pkgs.gno-tools-source ];
```

This compiles the gno tree, so it is slower than the release binaries. Every
tool under `contribs/` follows the same input.

#### When a ref needs a new vendorHash

Nix needs a `vendorHash` for every Go module it builds, and that hash is
determined by the module's dependency set. `versions/vendor-hashes.json` maps
the sha256 of a module's `go.mod` + `go.sum` to its `vendorHash`, so **any ref
whose dependencies match one already recorded just works**, which covers most
branches cut from a recent release.

This works because the modules are built with `proxyVendor = true`. Almost every
module under `contribs/` carries `replace github.com/gnolang/gno => ../..`, and
the default `go mod vendor` would copy that locally replaced parent into
`vendor/`, making the hash depend on the whole gno tree. Two revisions with an
identical `go.mod` and `go.sum` would then still need different hashes.
`proxyVendor` populates the module cache from the Go proxy, which never
contains a local replacement, so the hash depends only on the declared
dependencies.

When a ref does change dependencies, evaluation stops and tells you so. Record
the new hashes with:

```shell
nix run github:albttx/nix-overlays#vendor-hash -- v1.8.0
```

That probes each module without compiling anything and writes the result into
`versions/vendor-hashes.json`. Or pass one yourself:

```nix
pkgs.gno-nix.fromSource {
  src = inputs.my-gno;
  version = "1.8.0";
  vendorHash = "sha256-...";
  gnodevVendorHash = "sha256-...";
}
```

### Prebuilt binaries for an unrecorded tag

To get release binaries rather than a source build for a tag this repo has not
recorded, add it to the manifest:

```shell
nix run github:albttx/nix-overlays#update-versions -- --gno 1.8.0
```

It reads that release's published `CHECKSUMS.txt` and converts the hashes to
SRI, so no binary is downloaded to produce them. Open a pull request with the
result and everyone gets it.

## What is packaged

| Attribute | Source | What it is |
|---|---|---|
| `gno-tools` | release binaries | `gno`, `gnokey`, `gnoland`, `gnodev`, `gnoweb` |
| `gno`, `gnokey`, `gnoland`, `gnodev`, `gnoweb` | release binaries | each on its own |
| `gno-tools-source` | `gno-src` | the same five, compiled |
| `gno-indexer` | release binaries | `tx-indexer`, the Tendermint2 chain indexer |
| `gno-faucet` | `gno-faucet-src` | the standalone [gnolang/faucet](https://github.com/gnolang/faucet) |
| `gno-contribs` | `gno-src` | everything below, as one package |
| `gnobr` | `gno-src` | roll a node back to a height and replay locally |
| `gnobro` | `gno-src` | terminal UI for exploring realms |
| `gnofaucet` | `gno-src` | the faucet in `contribs/`, distinct from `gno-faucet` |
| `gnogenesis` | `gno-src` | create and manipulate `genesis.json` |
| `gnohealth` | `gno-src` | chain health checks |
| `gnokeykc` | `gno-src` | system keychain integration for `gnokey` |
| `gnokms` | `gno-src` | key management for remote validator signing |
| `gnomd` | `gno-src` | render Markdown in the terminal |
| `gnomigrate` | `gno-src` | migrate legacy data formats |
| `gpao` | `gno-src` | off-chain package-approver oracle |
| `tx-archive` | `gno-src` | back up and restore chain transactions |

Each overlay is also available on its own, when a project wants only part of
this: `overlays.gno`, `overlays.gno-contribs`, `overlays.gno-indexer`,
`overlays.gno-faucet`.

## Three things this fixes

Worth knowing, because all three bite anyone packaging gno by hand.

**The Linux release binaries do not run on NixOS as shipped.** They are
dynamically linked against glibc and carry the interpreter
`/lib64/ld-linux-x86-64.so.2`, which does not exist on NixOS, so they fail with
`Could not start dynamically linked executable`. `autoPatchelfHook` rewrites the
interpreter and rpath into the store. The tx-indexer binaries are static and
need none of this.

**The release binaries cannot find the Gno standard libraries.** They are linked
with `GNOROOT` set to the path of upstream's own CI checkout,
`/home/runner/work/gno/gno`, so `gno test` fails with
`unknown import path "testing"`. Every release entry therefore pins the source
tree at its own tag; the overlay assembles a real GNOROOT from it (the stdlibs,
the examples tree and the genesis files, matching what upstream's Dockerfile
puts at `/gnoroot`) and wraps each binary with `--set-default GNOROOT`. An
explicit `GNOROOT` in your environment still wins, and
`pkgs.gno-nix.gnoRoot` is the path if you want to export it yourself.

The source builds instead embed it at link time, the way upstream's own
Dockerfile does, along with `version.Version`, without which the binaries
report their version as `develop`.

**`-trimpath` breaks amino in two of the modules.** `contribs/gnofaucet` and the
standalone faucet repo take `github.com/gnolang/gno` from the Go proxy rather
than through `replace ... => ../..`, and the 2025 pseudo-version they pin has an
`amino.GetCallersDirname` that does not yet turn a relative source path into an
empty string. `buildGoModule` passes `-trimpath`, which makes every path
relative, so those binaries panicked at startup with
`dirName if present should be absolute`. They are built with
`allowGoReference = true`, which drops `-trimpath`. That puts the Go toolchain
in their closure, so it is applied only to the modules that need it, detected
from their `go.mod` rather than hard-coded.

## Licensing

gno is commonly labelled GPL-3.0. It is not. `LICENSE.md` in the gno tree is the
**GNO Network General Public License, version 6**, published by NewTendermint,
LLC, which its own text describes as a fork of the AGPL-3.0 and as free
software. There is no SPDX identifier for it, so `lib/licenses.nix` declares it
explicitly. The `tm2/` subtree is Apache-2.0, as are tx-indexer and the
standalone faucet.

## Keeping it current

`.github/workflows/update-versions.yml` runs daily. It resolves the newest
`vX.Y.Z` release of gno and tx-indexer, rewrites `versions/*.json` from each
release's published checksum manifest, re-pins `gno-src`, records any new
vendorHashes, checks that the result builds, and opens a pull request.

Non-semver tags are ignored, so the `chain/mainnet` and `chain/onyx` genesis
tags, which carry no binaries, never become the default.

Pull requests authored by `GITHUB_TOKEN` do not trigger workflow runs. Set a PAT
as the `GNO_NIX_PAT` secret if you want CI to run on these pull requests.

To do the same by hand:

```shell
make update        # refresh the version manifests
make vendor-hash   # record vendorHashes for the pinned ref
make check         # flake checks
make build         # build the release-binary packages
```

## Development

```shell
nix develop
make help
```

`make lint` checks Nix formatting and runs `shellcheck`; `nix flake check` runs
both plus the release-binary builds. The source builds are kept out of
`nix flake check` because compiling the gno tree is slow; CI builds them in a
separate job, which is what catches a stale vendorHash.
