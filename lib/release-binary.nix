# A prebuilt executable taken from a GitHub release.
#
# Upstream ships two shapes: a bare executable (gnolang/gno) and a tarball with
# the executables at its root (gnolang/tx-indexer). `archive` picks between them.
{ pkgs }:

{
  pname,
  version,
  url,
  hash,
  binaries,
  archive ? false,
  description,
  homepage,
  license,
  platforms,
  mainProgram ? builtins.head binaries,
  extraNativeBuildInputs ? [ ],
  postInstall ? "",
}:

let
  inherit (pkgs) lib stdenv;

  # gno's Linux release binaries are dynamically linked against glibc and carry
  # the interpreter /lib64/ld-linux-x86-64.so.2, which does not exist on NixOS,
  # so they fail with "Could not start dynamically linked executable" unless the
  # interpreter and rpath are rewritten into the store.
  #
  # autoPatchelfHook does that. It leaves statically linked artifacts alone, so
  # tx-indexer passes through untouched.
  patchElf = stdenv.hostPlatform.isLinux;
in

stdenv.mkDerivation (
  {
    inherit pname version;

    src = pkgs.fetchurl { inherit url hash; };

    nativeBuildInputs = lib.optionals patchElf [ pkgs.autoPatchelfHook ] ++ extraNativeBuildInputs;
    buildInputs = lib.optionals patchElf [ pkgs.glibc ];

    installPhase = ''
      runHook preInstall
    ''
    + (
      if archive then
        lib.concatMapStrings (bin: ''
          install -Dm755 ${bin} "$out/bin/${bin}"
        '') binaries
      else
        ''
          install -Dm755 "$src" "$out/bin/${mainProgram}"
        ''
    )
    + postInstall
    + ''
      runHook postInstall
    '';

    meta = {
      inherit
        description
        homepage
        license
        mainProgram
        platforms
        ;
      sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    };
  }
  // (if archive then { sourceRoot = "."; } else { dontUnpack = true; })
)
