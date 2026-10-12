{ lib, stdenvNoCC, fetchurl, unzip
, version ? "1.2.0"
, url ? "https://github.com/alexjmiller5/iris/releases/download/v${version}/Iris-v${version}.zip"
, hash ? "sha256-Lv+0I9HSLIH6zYaZ1YYU4Kjo9dU8ZRVpnuPVMkLV93A="
}:
stdenvNoCC.mkDerivation {
  pname = "iris";
  inherit version;
  src = fetchurl { inherit url hash; };
  nativeBuildInputs = [ unzip ];
  phases = [ "unpackPhase" "installPhase" ];
  unpackPhase = ''unzip -q "$src"'';
  # The release is already signed and notarized. Even shebang rewriting or
  # stripping an embedded executable would invalidate its sealed contents.
  dontFixup = true;
  dontStrip = true;
  installPhase = ''
    mkdir -p "$out/Applications"
    cp -R Iris.app "$out/Applications/"
  '';
  meta = {
    description = "Local-first client for catalogued Soma databases";
    homepage = "https://github.com/alexjmiller5/iris";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
