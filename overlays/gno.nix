# The gno.land command line tools.
#
# Two ways in, both pinned:
#
#   * release binaries, from versions/gno.json, for the versions this repo has
#     recorded. Fast, nothing is compiled.
#   * a source build following the `gno-src` flake input, for any tag, branch or
#     revision. A consumer overrides the input and needs no hash of their own:
#
#       inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/v1.8.0";
{ inputs }:

final: prev:

let
  pkgs = prev;
  inherit (pkgs) lib;

  manifest = builtins.fromJSON (builtins.readFile ../versions/gno.json);
  vendorHashes = builtins.fromJSON (builtins.readFile ../versions/vendor-hashes.json);

  mkReleaseBinary = import ../lib/release-binary.nix { inherit pkgs; };
  gnoSource = import ../lib/gno-source.nix { inherit pkgs vendorHashes; };
  gnoLicenses = import ../lib/licenses.nix { inherit lib; };

  homepage = "https://github.com/gnolang/gno";
  license = gnoLicenses.gnoNgpl6;

  # Platform -> the os_arch fragment upstream uses in its release asset names.
  assetSuffixes = {
    aarch64-darwin = "darwin_arm64";
    aarch64-linux = "linux_arm64";
    x86_64-darwin = "darwin_amd64";
    x86_64-linux = "linux_amd64";
  };

  descriptions = {
    gno = "Gno toolchain: build, test and run Gno code";
    gnokey = "Key manager and transaction client for gno.land";
    gnoland = "gno.land blockchain node";
    gnodev = "Local gno.land development node with hot reload";
    gnoweb = "Web frontend for a gno.land chain";
  };

  defaultVersion = manifest.default;

  releaseFor =
    version:
    manifest.releases.${version} or (throw ''
      gno-nix: version ${version} is not recorded in versions/gno.json.

      Recorded: ${lib.concatStringsSep ", " (builtins.attrNames manifest.releases)}

      Add it with:

          nix run github:albttx/nix-overlays#update-versions -- --gno ${version}

      or build that tag from source instead, which needs no hash:

          inputs.gno-nix.inputs.gno-src.url = "github:gnolang/gno/v${version}";
    '');

  # The source tree at a release's own tag, fetched purely from the rev and
  # narHash the manifest records.
  sourceFor =
    version:
    builtins.fetchTree {
      type = "github";
      owner = "gnolang";
      repo = "gno";
      inherit ((releaseFor version).source) rev narHash;
    };

  gnoRootFor =
    version:
    gnoSource.mkGnoRoot {
      inherit version;
      src = sourceFor version;
    };

  mkTool =
    {
      name,
      version,
      hashes,
      gnoRoot,
    }:
    let
      system = pkgs.stdenv.hostPlatform.system;
      suffix =
        assetSuffixes.${system}
          or (throw "gno-nix: upstream ships no ${name} release binary for ${system}");
    in
    mkReleaseBinary {
      pname = name;
      inherit version;

      url = "${homepage}/releases/download/v${version}/${name}_${suffix}";
      hash = hashes.${system} or (throw "gno-nix: no hash recorded for ${name} ${version} on ${system}");

      binaries = [ name ];

      # Upstream links its release binaries with GNOROOT pointing at its own CI
      # checkout, /home/runner/work/gno/gno, so out of the box `gno test` fails
      # with `unknown import path "testing"`: the Gno standard libraries are
      # nowhere to be found. Point them at a real GNOROOT assembled from the
      # source at the same tag.
      #
      # --set-default, so an explicit GNOROOT in the environment still wins.
      extraNativeBuildInputs = [ pkgs.makeWrapper ];
      postInstall = ''
        wrapProgram "$out/bin/${name}" --set-default GNOROOT "${gnoRoot}"
      '';

      inherit homepage license;
      description = descriptions.${name} or "gno.land tool ${name}";
      platforms = builtins.attrNames hashes;
    };

  # The whole suite for one recorded release, as a single package. Each tool is
  # also reachable through passthru, so `pkgs.gno-tools.gnokey` works.
  fromRelease =
    {
      version,
      hashes ? (releaseFor version).binaries,
      gnoRoot ? gnoRootFor version,
    }:
    let
      tools = lib.mapAttrs (
        name: toolHashes:
        mkTool {
          inherit name version gnoRoot;
          hashes = toolHashes;
        }
      ) hashes;
    in
    pkgs.symlinkJoin {
      name = "gno-tools-${version}";
      paths = builtins.attrValues tools;
      passthru = tools // {
        inherit version gnoRoot;
      };
      meta = {
        description = "The gno.land command line tools (${version}, release binaries)";
        inherit homepage license;
        mainProgram = "gno";
        platforms = lib.platforms.unix;
      };
    };

  # The same suite compiled from a source tree. The four tools in the root Go
  # module plus gnodev, which upstream keeps in its own module under contribs/.
  fromSource =
    {
      src,
      version ? "unstable",
      vendorHash ? null,
      gnodevVendorHash ? null,
    }:
    let
      root = gnoSource.mkModule {
        pname = "gno-tools";
        inherit version src vendorHash;
        subPackages = [
          "gno.land/cmd/gnoland"
          "gno.land/cmd/gnokey"
          "gno.land/cmd/gnoweb"
          "gnovm/cmd/gno"
        ];
        description = "The gno.land command line tools, built from source";
        mainProgram = "gno";
      };

      gnodev = gnoSource.mkModule {
        pname = "gnodev";
        inherit version src;
        vendorHash = gnodevVendorHash;
        modRoot = "contribs/gnodev";
        subPackages = [ "." ];
        description = descriptions.gnodev;
      };
    in
    pkgs.symlinkJoin {
      name = "gno-tools-source-${version}";
      paths = [
        root
        gnodev
      ];
      passthru = {
        inherit
          root
          gnodev
          src
          version
          ;
      };
      meta = {
        description = "The gno.land command line tools (${version}, built from source)";
        inherit homepage license;
        mainProgram = "gno";
        platforms = lib.platforms.unix;
      };
    };

  # Whatever `gno-src` resolves to: a release tag by default, or the branch or
  # revision a consumer overrode the input with.
  sourceVersion = inputs.gno-src.shortRev or "unstable";
in

# Each tool at the default version, as its own top-level package.
lib.mapAttrs (
  name: hashes:
  mkTool {
    inherit name hashes;
    version = defaultVersion;
    gnoRoot = gnoRootFor defaultVersion;
  }
) (releaseFor defaultVersion).binaries

// {
  gno-tools = fromRelease { version = defaultVersion; };

  gno-tools-source = fromSource {
    src = inputs.gno-src;
    version = sourceVersion;
  };

  # Builders and the recorded release set, for projects that want a version
  # other than the default.
  gno-nix = {
    inherit fromRelease fromSource;
    inherit (gnoSource) mkModule mkGnoRoot moduleKey;

    defaultVersion = defaultVersion;

    # The GNOROOT the release binaries are pointed at, for anything that needs
    # to export it by hand.
    gnoRoot = gnoRootFor defaultVersion;

    # e.g. pkgs.gno-nix.releases."1.4.0"
    releases = lib.mapAttrs (version: _: fromRelease { inherit version; }) manifest.releases;
  };
}
