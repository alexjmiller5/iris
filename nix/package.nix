{ lib, stdenvNoCC, fetchurl, unzip
, version ? "0.8.0"
, url ? "https://github.com/alexjmiller5/life-ui/releases/download/v${version}/LifeUI-v${version}.zip"
, hash ? "sha256-gCghdip3zVuW2+ZZ+1CjyC1+pI9meDNo9mxbQnBEvDM="
}:
stdenvNoCC.mkDerivation {
  pname = "life-ui";
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
    cp -R LifeUI.app "$out/Applications/"
  '';
  meta = {
    description = "Local-first client for catalogued Life Data databases";
    homepage = "https://github.com/alexjmiller5/life-ui";
    platforms = lib.platforms.darwin;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
