# gnolang/tx-indexer: a Tendermint2 indexer that serves chain data over
# JSON-RPC and GraphQL.
#
# Upstream attaches a tarball per platform to each release, so this always uses
# release binaries, pinned in versions/tx-indexer.json.

final: prev:

let
  pkgs = prev;
  inherit (pkgs) lib;

  manifest = builtins.fromJSON (builtins.readFile ../versions/tx-indexer.json);
  mkReleaseBinary = import ../lib/release-binary.nix { inherit pkgs; };

  homepage = "https://github.com/gnolang/tx-indexer";

  # Platform -> the os_arch fragment upstream uses in its release asset names.
  assetSuffixes = {
    aarch64-darwin = "darwin_arm64";
    aarch64-linux = "linux_arm64";
    x86_64-darwin = "darwin_amd64";
    x86_64-linux = "linux_amd64";
  };

  releaseFor =
    version:
    manifest.releases.${version} or (throw ''
      gno-nix: tx-indexer ${version} is not recorded in versions/tx-indexer.json.

      Recorded: ${lib.concatStringsSep ", " (builtins.attrNames manifest.releases)}

      Add it with:

          nix run github:albttx/nix-overlays#update-versions -- --tx-indexer ${version}
    '');

  fromRelease =
    {
      version,
      hashes ? releaseFor version,
    }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      suffix =
        assetSuffixes.${system}
          or (throw "gno-nix: upstream ships no tx-indexer release binary for ${system}");
    in
    mkReleaseBinary {
      pname = "gno-indexer";
      inherit version;

      url = "${homepage}/releases/download/v${version}/tx-indexer_${version}_${suffix}.tar.gz";
      hash =
        hashes.${system} or (throw "gno-nix: no hash recorded for tx-indexer ${version} on ${system}");

      archive = true;
      binaries = [ "tx-indexer" ];

      inherit homepage;
      description = "Tendermint2 indexer serving gno.land chain data over JSON-RPC and GraphQL";
      license = lib.licenses.asl20;
      platforms = builtins.attrNames hashes;
    };
in

{
  gno-indexer = fromRelease { version = manifest.default; };

  gno-indexer-nix = {
    inherit fromRelease;
    defaultVersion = manifest.default;

    # e.g. pkgs.gno-indexer-nix.releases."1.1.1"
    releases = lib.mapAttrs (version: _: fromRelease { inherit version; }) manifest.releases;
  };
}
