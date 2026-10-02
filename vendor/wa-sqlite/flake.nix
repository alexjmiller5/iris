{
  description = "Pinned FTS5-enabled wa-sqlite browser build";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/8d5d270900d3fc75655ea2d9d248b234f6631439";
  outputs = { nixpkgs, ... }:
    let
      manifest = builtins.fromJSON (builtins.readFile ./manifest.json);
      systems = [ "aarch64-darwin" "aarch64-linux" "x86_64-linux" ];
    in {
      packages = nixpkgs.lib.genAttrs systems (system:
        let pkgs = import nixpkgs { inherit system; }; in
        assert pkgs.emscripten.version == manifest.emscripten; {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "wa-sqlite-fts5";
            version = "${manifest.sqlite.version}-${builtins.substring 0 7 manifest.waSqlite.revision}";
            src = pkgs.fetchurl {
              name = "wa-sqlite.tar.gz";
              inherit (manifest.waSqlite) url sha256;
            };
            sqlite = pkgs.fetchurl {
              inherit (manifest.sqlite) url sha256;
            };
            extension = pkgs.fetchurl {
              inherit (manifest.extension) url sha256;
            };
            nativeBuildInputs = [ pkgs.emscripten pkgs.unzip ];
            dontConfigure = true;
            dontFixup = true;
            buildPhase = ''
              runHook preBuild
              export EM_CACHE="$TMPDIR/emscripten-cache"
              export SOURCE_DATE_EPOCH=1
              export TZ=UTC
              unzip -q "$sqlite"
              mkdir -p deps/version-${manifest.sqlite.version} cache
              cp ${manifest.sqlite.amalgamation}/sqlite3.c ${manifest.sqlite.amalgamation}/*.h deps/version-${manifest.sqlite.version}/
              cp "$extension" cache/extension-functions.c
              cp "$extension" deps/extension-functions.c
              # Delete only the packaged outputs so make cannot reuse upstream WASM.
              rm dist/wa-sqlite.mjs dist/wa-sqlite.wasm
              make dist/wa-sqlite.mjs SQLITE_VERSION=version-${manifest.sqlite.version} \
                WASQLITE_EXTRA_DEFINES="${builtins.concatStringsSep " " (map (flag: "-D${flag}") manifest.defines)}"
              runHook postBuild
            '';
            installPhase = ''
              mkdir -p "$out"
              cp dist/wa-sqlite.mjs dist/wa-sqlite.wasm LICENSE "$out/"
            '';
          };
        });
    };
}
