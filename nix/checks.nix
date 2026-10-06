{ pkgs, package, homeModule }:
let
  inherit (pkgs) lib;
  sample = pkgs.runCommand "life-ui-package-fixture" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir -p LifeUI.app/Contents/{MacOS,Resources,_CodeSignature}
    printf '#!/bin/sh\nprintf signed-payload' > LifeUI.app/Contents/MacOS/LifeUI
    chmod +x LifeUI.app/Contents/MacOS/LifeUI
    printf profile > LifeUI.app/Contents/embedded.provisionprofile
    printf ticket > LifeUI.app/Contents/CodeResources
    printf signature > LifeUI.app/Contents/_CodeSignature/CodeResources
    ln -s ../MacOS/LifeUI LifeUI.app/Contents/Resources/executable
    zip -qry fixture.zip LifeUI.app
    mv fixture.zip "$out"
  '';
  fixturePackage = package.overrideAttrs { src = sample; };
  evaluate = settings: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      homeModule
      {
        options.home.packages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
        options.assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      }
      settings
    ];
  };
  enabled = (evaluate { programs.life-ui = { enable = true; package = fixturePackage; }; }).config;
  disabled = (evaluate {}).config;
  defaultEnabled = (evaluate { programs.life-ui.enable = true; }).config;
  customRelease = package.override {
    version = "1.2.3";
    url = "https://example.invalid/releases/app.zip";
    hash = lib.fakeHash;
  };
in {
  home-module = assert disabled.home.packages == [];
    assert enabled.home.packages == [ fixturePackage ];
    assert (builtins.head defaultEnabled.home.packages).drvPath == package.drvPath;
    assert lib.all (entry: entry.assertion) enabled.assertions;
    assert customRelease.version == "1.2.3";
    assert customRelease.src.url == "https://example.invalid/releases/app.zip";
    assert customRelease.src.outputHash == lib.fakeHash;
    pkgs.runCommand "life-ui-home-module-check" {} "touch $out";
  bundle-preservation = pkgs.runCommand "life-ui-bundle-preservation-check" {
    nativeBuildInputs = [ pkgs.unzip pkgs.diffutils ];
  } ''
    unzip -q ${sample}
    diff -r --no-dereference LifeUI.app ${fixturePackage}/Applications/LifeUI.app
    test -x ${fixturePackage}/Applications/LifeUI.app/Contents/MacOS/LifeUI
    test -L ${fixturePackage}/Applications/LifeUI.app/Contents/Resources/executable
    test "$(readlink ${fixturePackage}/Applications/LifeUI.app/Contents/Resources/executable)" = ../MacOS/LifeUI
    touch "$out"
  '';
}
