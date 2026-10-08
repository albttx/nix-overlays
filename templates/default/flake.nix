{
  description = "A gno.land project";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    gno-nix.url = "github:albttx/nix-overlays";

    # To pin a different gno, uncomment one of these. No hash to work out:
    # your flake.lock records it.
    #
    # gno-nix.inputs.gno-src.url = "github:gnolang/gno/v1.8.0";
    # gno-nix.inputs.gno-src.url = "github:gnolang/gno/my-branch";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      gno-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ gno-nix.overlays.default ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            # gno, gnokey, gnoland, gnodev and gnoweb at the version gno-nix
            # defaults to, as prebuilt release binaries.
            pkgs.gno-tools

            # A specific recorded release instead:
            #   pkgs.gno-nix.releases."1.4.0"
            #
            # Or built from whatever gno-src points at, which is how you get a
            # tag gno-nix has not recorded, or a branch:
            #   pkgs.gno-tools-source

            pkgs.go
          ];

          shellHook = ''
            gno version
          '';
        };
      }
    );
}
