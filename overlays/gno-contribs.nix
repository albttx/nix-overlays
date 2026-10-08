# The tools under contribs/ in the gno tree.
#
# Upstream attaches no release binaries to these, so they are always compiled
# from the `gno-src` flake input. Each one is its own Go module, which is why
# each needs its own vendorHash in versions/vendor-hashes.json.
#
# gnodev is deliberately absent: it ships as a release binary and belongs to the
# gno-tools suite in overlays/gno.nix.
{ inputs }:

final: prev:

let
  pkgs = prev;
  inherit (pkgs) lib;

  vendorHashes = builtins.fromJSON (builtins.readFile ../versions/vendor-hashes.json);
  gnoSource = import ../lib/gno-source.nix { inherit pkgs vendorHashes; };
  gnoLicenses = import ../lib/licenses.nix { inherit lib; };

  src = inputs.gno-src;
  version = inputs.gno-src.shortRev or "unstable";

  contribs = {
    gnobr.description = "Roll a gnoland node back to a target height and replay blocks locally";
    gnobro.description = "Terminal UI to explore gno.land realms";
    gnofaucet.description = "Faucet server for a gno.land chain";
    gnogenesis.description = "Create and manipulate a gno.land genesis.json";
    gnohealth.description = "Health check suite for a gno.land chain";
    gnokeykc.description = "System keychain integration for gnokey";
    gnokms.description = "Key management service for remote validator signing";
    gnomd.description = "Render Markdown in the terminal";
    gnomigrate.description = "Migrate legacy Gno data formats to the current ones";
    gpao.description = "Off-chain package-approver oracle for chains on the inert code policy";

    tx-archive = {
      description = "Back up and restore transaction data from a Tendermint2 chain";
      subPackages = [ "cmd" ];
      # Go names the executable after its package directory, so ./cmd produces
      # a binary called `cmd`.
      renameFrom = "cmd";
    };
  };

  mkContrib =
    name: attrs:
    gnoSource.mkModule {
      pname = name;
      inherit version src;

      modRoot = "contribs/${name}";
      subPackages = attrs.subPackages or [ "." ];

      inherit (attrs) description;
      mainProgram = name;

      postInstall = lib.optionalString (attrs ? renameFrom) ''
        mv "$out/bin/${attrs.renameFrom}" "$out/bin/${name}"
      '';
    };

  built = lib.mapAttrs mkContrib contribs;
in

built
// {
  # All of them as one package, each also reachable through passthru.
  gno-contribs = pkgs.symlinkJoin {
    name = "gno-contribs-${version}";
    paths = builtins.attrValues built;
    passthru = built // {
      inherit version src;
    };
    meta = {
      description = "The experimental tools under contribs/ in the gno tree";
      homepage = "https://github.com/gnolang/gno/tree/master/contribs";
      license = gnoLicenses.gnoNgpl6;
      platforms = lib.platforms.unix;
    };
  };
}
