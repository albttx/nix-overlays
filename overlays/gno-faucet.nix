# gnolang/faucet: the standalone, configurable faucet for gno.land and other
# Tendermint2 chains.
#
# This is a separate repo from contribs/gnofaucet in the gno tree. Upstream
# attaches no binaries to its releases, so it is compiled from the
# `gno-faucet-src` flake input:
#
#   inputs.gno-nix.inputs.gno-faucet-src.url = "github:gnolang/faucet/v0.5.3";
{ inputs }:

final: prev:

let
  pkgs = prev;
  inherit (pkgs) lib;

  vendorHashes = builtins.fromJSON (builtins.readFile ../versions/vendor-hashes.json);
  gnoSource = import ../lib/gno-source.nix { inherit pkgs vendorHashes; };
in

{
  gno-faucet = gnoSource.mkModule {
    pname = "gno-faucet";
    version = inputs.gno-faucet-src.shortRev or "unstable";
    src = inputs.gno-faucet-src;

    subPackages = [ "cmd" ];
    # Go names the executable after its package directory.
    postInstall = ''
      mv "$out/bin/cmd" "$out/bin/gno-faucet"
    '';

    description = "Configurable faucet for gno.land and Tendermint2 chains";
    homepage = "https://github.com/gnolang/faucet";
    license = lib.licenses.asl20;
    mainProgram = "gno-faucet";
  };
}
