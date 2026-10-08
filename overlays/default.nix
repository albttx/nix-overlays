# Every overlay in this repo, individually and composed.
#
# Take `default` for the lot, or a single one when a project only wants, say,
# the indexer:
#
#   overlays = [ gno-nix.overlays.gno-indexer ];
{ lib, inputs }:

let
  gno = import ./gno.nix { inherit inputs; };
  gno-contribs = import ./gno-contribs.nix { inherit inputs; };
  gno-indexer = import ./gno-indexer.nix;
  gno-faucet = import ./gno-faucet.nix { inherit inputs; };
in
{
  inherit
    gno
    gno-contribs
    gno-indexer
    gno-faucet
    ;

  default = lib.composeManyExtensions [
    gno
    gno-contribs
    gno-indexer
    gno-faucet
  ];
}
