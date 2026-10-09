{ pkgs, package, homeModule }:
let
  inherit (pkgs) lib;
  sample = pkgs.runCommand "iris-package-fixture" { nativeBuildInputs = [ pkgs.zip ]; } ''
    mkdir -p Iris.app/Contents/{MacOS,Resources,_CodeSignature}
    printf '#!/bin/sh\nprintf signed-payload' > Iris.app/Contents/MacOS/Iris
    chmod +x Iris.app/Contents/MacOS/Iris
    printf profile > Iris.app/Contents/embedded.provisionprofile
    printf ticket > Iris.app/Contents/CodeResources
    printf signature > Iris.app/Contents/_CodeSignature/CodeResources
    ln -s ../MacOS/Iris Iris.app/Contents/Resources/executable
    zip -qry fixture.zip Iris.app
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
  enabled = (evaluate { programs.iris = { enable = true; package = fixturePackage; }; }).config;
  disabled = (evaluate {}).config;
  defaultEnabled = (evaluate { programs.iris.enable = true; }).config;
  customRelease = package.override {
    version = "1.2.3";
    url = "https://example.invalid/releases/app.zip";
    hash = lib.fakeHash;
  };
  darwinEvaluate = settings: lib.evalModules {
    specialArgs = { inherit pkgs; };
    modules = [
      ./darwin.nix
      {
        options = {
          environment.systemPackages = lib.mkOption { type = lib.types.listOf lib.types.package; default = []; };
          assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
          homebrew = {
            enable = lib.mkOption { type = lib.types.bool; default = true; };
            user = lib.mkOption { type = lib.types.str; default = "fixture-user"; };
            prefix = lib.mkOption { type = lib.types.str; default = "/fixture/brew"; };
            casks = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
          };
          system.checks.text = lib.mkOption { type = lib.types.lines; default = ""; };
          system.activationScripts.homebrew.text = lib.mkOption { type = lib.types.lines; default = ""; };
        };
      }
      settings
    ];
  };
  darwinEnabled = (darwinEvaluate { programs.iris = { enable = true; package = fixturePackage; }; }).config;
  darwinDisabled = (darwinEvaluate {}).config;
  duplicateOwner = (darwinEvaluate {
    programs.iris.enable = true;
    homebrew.casks = [{ name = "alexjmiller5/tap/iris"; }];
  }).config;
in {
  darwin-module = assert darwinDisabled.environment.systemPackages == [];
    assert darwinDisabled.system.checks.text == "";
    assert darwinEnabled.environment.systemPackages == [ fixturePackage ];
    assert lib.all (entry: entry.assertion) darwinEnabled.assertions;
    assert !(lib.all (entry: entry.assertion) duplicateOwner.assertions);
    pkgs.runCommand "iris-darwin-module-check" {} "touch $out";
  home-module = assert disabled.home.packages == [];
    assert enabled.home.packages == [ fixturePackage ];
    assert (builtins.head defaultEnabled.home.packages).drvPath == package.drvPath;
    assert lib.all (entry: entry.assertion) enabled.assertions;
    assert customRelease.version == "1.2.3";
    assert customRelease.src.url == "https://example.invalid/releases/app.zip";
    assert customRelease.src.outputHash == lib.fakeHash;
    pkgs.runCommand "iris-home-module-check" {} "touch $out";
  bundle-preservation = pkgs.runCommand "iris-bundle-preservation-check" {
    nativeBuildInputs = [ pkgs.unzip pkgs.diffutils ];
  } ''
    unzip -q ${sample}
    diff -r --no-dereference Iris.app ${fixturePackage}/Applications/Iris.app
    test -x ${fixturePackage}/Applications/Iris.app/Contents/MacOS/Iris
    test -L ${fixturePackage}/Applications/Iris.app/Contents/Resources/executable
    test "$(readlink ${fixturePackage}/Applications/Iris.app/Contents/Resources/executable)" = ../MacOS/Iris
    touch "$out"
  '';
}
