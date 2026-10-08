# buildGoModule wrappers for the Go modules in the gno tree and in the
# standalone faucet repo.
#
# Nix needs a vendorHash for every Go module it builds, and that hash changes
# with the module's dependency set. versions/vendor-hashes.json maps the sha256
# of go.mod + go.sum to the matching vendorHash, so any tag or branch whose
# dependencies match one already recorded builds with nothing to supply.
#
# That mapping only holds because of proxyVendor; see mkModule below.
{ pkgs, vendorHashes }:

let
  inherit (pkgs) lib;

  gnoLicenses = import ./licenses.nix { inherit lib; };

  moduleDir = src: modRoot: if modRoot == "." then "${src}" else "${src}/${modRoot}";

  # Does this module take github.com/gnolang/gno from the Go proxy rather than
  # through `replace github.com/gnolang/gno => ../..`?
  #
  # Those that do pin a 2025 pseudo-version of gno whose
  # amino.GetCallersDirname still lacks the guard that turns a relative source
  # path into "". buildGoModule passes -trimpath by default, which makes every
  # path relative, so such a binary panics the moment amino registers a
  # package:
  #
  #   dirName if present should be absolute, but got github.com/gnolang/gno@v0...
  #
  # allowGoReference drops -trimpath and restores absolute paths. It costs the
  # Go toolchain in the closure, so it is only set where it is needed: today
  # contribs/gnofaucet and the standalone faucet repo. Modules that do not
  # depend on gno at all, like contribs/gnomd, are unaffected either way.
  takesGnoFromProxy =
    { src, modRoot }:
    let
      gomod = builtins.readFile "${moduleDir src modRoot}/go.mod";
    in
    lib.hasInfix "github.com/gnolang/gno v" gomod
    && !(lib.hasInfix "replace github.com/gnolang/gno => ../" gomod);

  # go.mod is part of the key, not just go.sum: contribs/gnogenesis and
  # contribs/gpao ship a byte-identical go.sum and are told apart only by their
  # go.mod, so go.sum alone would collide. go.mod is also what carries the
  # `require` and `replace` directives that shape the dependency set.
  moduleKey =
    { src, modRoot }:
    let
      dir = moduleDir src modRoot;
    in
    builtins.hashString "sha256" (
      builtins.readFile "${dir}/go.mod" + builtins.readFile "${dir}/go.sum"
    );

  resolveVendorHash =
    {
      src,
      modRoot,
      vendorHash ? null,
    }:
    if vendorHash != null then
      vendorHash
    else
      let
        key = moduleKey { inherit src modRoot; };
      in
      vendorHashes.${key} or (throw ''
        gno-nix: no vendorHash recorded for the Go module '${modRoot}' of this source
        tree (go.mod+go.sum sha256 ${key}).

        Discover it with:

            nix run github:albttx/nix-overlays#vendor-hash -- <git-ref>

        then add the result to versions/vendor-hashes.json, or pass vendorHash
        explicitly to the builder.
      '');

  # GNOROOT: the data the gno tools read at runtime -- the Gno standard
  # libraries, the examples tree and the genesis files. Upstream's Dockerfile
  # assembles the same set at /gnoroot.
  #
  # Without it `gno` and `gnoland` abort with "gno was unable to determine
  # GNOROOT": buildGoModule passes -trimpath, which defeats the call-stack
  # fallback gnoenv would otherwise use.
  mkGnoRoot =
    { src, version }:
    pkgs.runCommand "gnoroot-${version}" { } ''
      mkdir -p "$out/gnovm/tests" "$out/gno.land/genesis"

      cp -r ${src}/examples "$out/examples"
      cp -r ${src}/gnovm/stdlibs "$out/gnovm/stdlibs"
      cp -r ${src}/gnovm/tests/stdlibs "$out/gnovm/tests/stdlibs"
      cp ${src}/gno.land/genesis/genesis_txs.jsonl "$out/gno.land/genesis/"
      cp ${src}/gno.land/genesis/genesis_balances.txt "$out/gno.land/genesis/"

      chmod -R u+w "$out"
    '';

  mkModule =
    {
      pname,
      version,
      src,
      subPackages,
      modRoot ? ".",
      vendorHash ? null,
      description,
      homepage ? "https://github.com/gnolang/gno",
      license ? gnoLicenses.gnoNgpl6,
      mainProgram ? pname,
      postInstall ? "",
      gnoRoot ? null,
      allowGoReference ? takesGnoFromProxy { inherit src modRoot; },
    }:
    let
      # The standalone faucet repo has no stdlibs tree, so it gets no GNOROOT.
      resolvedGnoRoot =
        if gnoRoot != null then
          gnoRoot
        else if builtins.pathExists "${src}/gnovm/stdlibs" then
          mkGnoRoot { inherit src version; }
        else
          null;
    in
    pkgs.buildGoModule {
      inherit
        pname
        version
        src
        modRoot
        subPackages
        postInstall
        ;

      vendorHash = resolveVendorHash { inherit src modRoot vendorHash; };

      # Almost every module under contribs/ carries
      # `replace github.com/gnolang/gno => ../..`. The default `go mod vendor`
      # copies that locally replaced parent into vendor/, so the vendorHash
      # would depend on the whole gno tree: two revisions with a byte-identical
      # go.mod and go.sum would still need different hashes, and keying the
      # manifest on go.mod + go.sum would be wrong.
      #
      # proxyVendor populates the module cache from the Go proxy instead, which
      # never includes a local replacement. The hash then depends only on the
      # declared dependencies, which is what makes one recorded entry serve
      # every ref that shares those dependencies.
      proxyVendor = true;

      # See takesGnoFromProxy above: this is what keeps -trimpath from breaking
      # amino's package registration in the modules that need it.
      inherit allowGoReference;

      # Upstream sets both of these at link time; see its Dockerfile. Without
      # the first, `gnokey version` reports "develop" instead of the version.
      # Go ignores an -X for a package that is not in the build, so passing
      # both to every module is harmless.
      ldflags = [
        "-X"
        "github.com/gnolang/gno/tm2/pkg/version.Version=${version}"
      ]
      ++ lib.optionals (resolvedGnoRoot != null) [
        "-X"
        "github.com/gnolang/gno/gnovm/pkg/gnoenv._GNOROOT=${resolvedGnoRoot}"
      ];

      passthru = lib.optionalAttrs (resolvedGnoRoot != null) { gnoRoot = resolvedGnoRoot; };

      # Running the gno test suite is upstream CI's job, not a packaging step.
      doCheck = false;

      env.CGO_ENABLED = 0;

      meta = {
        inherit
          description
          homepage
          license
          mainProgram
          ;
        platforms = lib.platforms.unix;
        sourceProvenance = [ lib.sourceTypes.fromSource ];
      };
    };
in
{
  inherit
    moduleKey
    resolveVendorHash
    mkGnoRoot
    mkModule
    ;
}
