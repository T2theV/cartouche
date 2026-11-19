# package.nix — builds the cartouche Linux port. Source (app/, the Godot
# project) is fetched from GitHub at the pinned commit below.
#
# Usage (from the repo root, any x86_64 Linux with nixpkgs):
#
#   nix-build ./package.nix
#
#   result/bin/cartouche-linux.x86_64 --games-dir=/path/to/roms
#
# The exported binary is NOT self-contained: Godot loads the data pack
# <executable-without-extension>.pck sitting next to it, so the package ships
# both bin/cartouche-linux.x86_64 and bin/cartouche-linux.pck. Keep both in the
# same directory if you copy them out of the store.
#
# Build recipe (mirrors nixpkgs pkgs/development/tools/godot/common.nix):
#   1. fetch the official Godot 4.7.2-stable editor binary (byte-identical to
#      the one used for the verified exports),
#   2. fetch the export templates tpz and keep only linux_release.x86_64 —
#      the editor must find it under
#      $HOME/.local/share/godot/export_templates/4.7.2.stable/ (its CLI
#      auto-download fails silently in headless builds),
#   3. godot --headless --import        (regenerate the .godot import cache),
#   4. godot --headless --export-release Linux <out>   (preset "Linux").
{ pkgs ? import <nixpkgs> { } }:

let
  inherit (pkgs) lib;

  # Editor and export templates must be the same release; 4.7.2-stable is
  # what app/ was built and tested against.
  godotVersion = "4.7.2-stable";
  godotVersionDir = lib.replaceStrings [ "-" ] [ "." ] godotVersion; # 4.7.2.stable

  godotEditor = pkgs.fetchurl {
    url = "https://github.com/godotengine/godot/releases/download/${godotVersion}/Godot_v${godotVersion}_linux.x86_64.zip";
    hash = "sha256-yt0yBOcoo10/E623/Q15AmNrefa5XEDCZetztsNTKeQ";
  };

  godotTemplates = pkgs.fetchurl {
    # All-platform template archive (1.2 GB) — we only extract the one Linux
    # release template the export needs.
    url = "https://github.com/godotengine/godot/releases/download/${godotVersion}/Godot_v${godotVersion}_export_templates.tpz";
    hash = "sha256-8phJC41E2TS+QlpaZaUb8V9CJCiyKaBqbhHZ/+okgBE";
  };
in
pkgs.stdenv.mkDerivation rec {
  pname = "cartouche";
  version = "0.4.1";

  # Project source: fetch from GitHub at a pinned commit. build/ and .godot
  # are not committed, so the tarball is exactly what the editor needs
  # (.godot is regenerated below). The app/ dir holds the Godot project.
  src = (pkgs.fetchFromGitHub {
    owner = "T2theV";
    repo = "cartouche";
    rev = "f4a60115b885917a63066cb5780555f1acda2a1f";
    hash = "sha256-DZdDMsE/5dVcvLFfsEHNqtb2NkPhfVeaU2pl9OTParY";
  }) + "/app";

  nativeBuildInputs = [ pkgs.unzip pkgs.glibc ];

  inherit godotEditor godotTemplates;

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR/godot-home
    mkdir -p "$HOME/.local/share/godot/export_templates"

    # Editor binary.
    mkdir -p $TMPDIR/godot
    unzip -q $godotEditor -d $TMPDIR/godot
    chmod +x $TMPDIR/godot/Godot_v${godotVersion}_linux.x86_64

    # Templates, where the editor looks for them.
    mkdir -p $TMPDIR/godot-templates
    unzip -q $godotTemplates -d $TMPDIR/godot-templates \
      templates/linux_release.x86_64
    ln -s $TMPDIR/godot-templates/templates \
      "$HOME/.local/share/godot/export_templates/${godotVersionDir}"

    # The editor is dynamically linked to glibc (interpreter
    # /lib64/ld-linux-x86-64.so.2). Sandboxed Nix builds provide that via
    # the stdenv glibc, but e.g. nix-build inside Docker often runs
    # unsandboxed where no /lib64 exists — exec through the loader
    # explicitly so both cases work.
    godot() {
      "${pkgs.glibc}/lib64/ld-linux-x86-64.so.2" \
        "$TMPDIR/godot/Godot_v${godotVersion}_linux.x86_64" "$@"
    }

    # The editor writes the import cache (.godot) into the project, and
    # stdenv already made the unpacked source writable — build in place.
    godot --headless --path . --import

    mkdir -p $TMPDIR/export
    godot --headless --path . \
      --export-release Linux $TMPDIR/export/cartouche-linux.x86_64
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    # Both files are required at runtime: the PCK is named after the
    # executable with its last extension stripped.
    install -m 755 $TMPDIR/export/cartouche-linux.x86_64 $out/bin/
    install -m 644 $TMPDIR/export/cartouche-linux.pck $out/bin/
    runHook postInstall
  '';

  meta = with pkgs.lib; {
    description = "Cartouche — ROM cartridge game launcher (Godot 4.7 Linux port)";
    homepage = "https://github.com/T2theV/cartouche";
    license = licenses.gpl3Only;
    platforms = platforms.linux;
    sourceProvenance = [ sourceTypes.binaryNativeCode ];
    maintainers = [ ];
  };
}
