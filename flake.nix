{
  description = "Nix overlays and packages for the gno.land toolchain";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Source tree for every from-source build: gno-tools-source and all of
    # contribs/. Pinned to the release that versions/gno.json defaults to.
    #
    # Override it to build any other tag, branch or revision. You supply no
    # hash; your own flake.lock records it:
    #
    #   inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/v1.5.0";
    #   inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/my-branch";
    gno-src = {
      url = "github:gnolang/gno/v1.5.0";
      flake = false;
    };

    # The standalone faucet, a separate repo from contribs/gnofaucet.
    gno-faucet-src = {
      url = "github:gnolang/faucet/v0.5.3";
      flake = false;
    };
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      ...
    }@inputs:
    let
      overlays = import ./overlays {
        inherit (nixpkgs) lib;
        inherit inputs;
      };
    in
    {
      inherit overlays;

      templates.default = {
        path = ./templates/default;
        description = "A project devShell with the gno.land tools";
      };
    }
    // flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ overlays.default ];
        };

        # The scripts keep their shebang and run from the store; the wrapper only
        # puts their dependencies on PATH.
        mkScript =
          name: script:
          pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = with pkgs; [
              bash
              coreutils
              curl
              findutils
              gawk
              git
              gnugrep
              gnused
              jq
            ];
            text = ''
              exec ${pkgs.bash}/bin/bash ${script} "$@"
            '';
          };

        update-versions = mkScript "update-versions" ./scripts/update-versions.sh;
        vendor-hash = mkScript "vendor-hash" ./scripts/vendor-hash.sh;
      in
      {
        packages = {
          inherit (pkgs)
            # gno.land release binaries
            gno
            gnokey
            gnoland
            gnodev
            gnoweb
            gno-tools

            # the same suite, compiled from the gno-src input
            gno-tools-source

            # side tools
            gno-indexer
            gno-faucet

            # contribs/, compiled from the gno-src input
            gno-contribs
            gnobr
            gnobro
            gnofaucet
            gnogenesis
            gnohealth
            gnokeykc
            gnokms
            gnomd
            gnomigrate
            gpao
            tx-archive
            ;

          inherit update-versions vendor-hash;

          default = pkgs.gno-tools;
        };

        apps = {
          update-versions = {
            type = "app";
            program = "${update-versions}/bin/update-versions";
            meta.description = "Refresh versions/*.json from the newest upstream release";
          };

          vendor-hash = {
            type = "app";
            program = "${vendor-hash}/bin/vendor-hash";
            meta.description = "Discover and record vendorHashes for a gno ref";
          };
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            gno-tools
            gno-indexer

            # for working on this repo
            curl
            jq
            nixfmt-rfc-style
            shellcheck
          ];
        };

        # Release binaries and the repo's own hygiene. Source builds are left to
        # CI's dedicated job: compiling the gno tree is far too slow to sit in
        # the default `nix flake check`.
        checks = {
          inherit (pkgs) gno-tools gno-indexer;

          formatting =
            pkgs.runCommand "check-nixfmt"
              {
                nativeBuildInputs = [
                  pkgs.findutils
                  pkgs.nixfmt-rfc-style
                ];
              }
              ''
                cd ${./.}
                # Passing a directory to nixfmt is deprecated, so the files are listed.
                find . -name '*.nix' -exec nixfmt --check {} +
                touch "$out"
              '';

          scripts = pkgs.runCommand "check-shellcheck" { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
            shellcheck ${./scripts}/*.sh && touch "$out"
          '';
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
