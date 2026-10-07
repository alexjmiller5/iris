# Nix packaging

`nix develop` supplies Bun 1.4.2, just, ripgrep and Git on Apple Silicon macOS
and aarch64/x86_64 Linux. It does not install tools globally. Use the repository's locked
dependencies with `bun install --frozen-lockfile`. Xcode is a separate native
development prerequisite; the Nix app package does not build Swift.

## Signed macOS app

`nix build .#life-ui` produces `result/Applications/LifeUI.app`. The default
package pins the published universal **0.6.0** ZIP by SHA-256. It extracts and
copies the bundle without fixup, stripping, patching or re-signing. The embedded
profile, entitlements and stapled notarization ticket stay with the app.
App packages support Apple Silicon and Intel macOS. Their Nixpkgs 26.05 pin
retains Intel support; the separately pinned development toolchain matches CI's
Bun version and has no Intel macOS shell.

The flake exports `homeModules.life-ui` (also `homeModules.default`):

```nix
{
  inputs.life-ui.url = "github:alexjmiller5/life-ui";
  # In your Home Manager configuration:
  # imports = [ inputs.life-ui.homeModules.life-ui ];
  # programs.life-ui.enable = true;
}
```

The module adds the package to `home.packages`; use Home Manager's macOS
application linking support to expose it in Applications. Runtime enrollment,
credentials and preferences remain in the app's supported interface and secure
storage. No token or personal configuration belongs in this flake.

To select another **published, signed** archive, override all release inputs:

```nix
programs.life-ui = {
  enable = true;
  package = inputs.life-ui.packages.${pkgs.stdenv.hostPlatform.system}.life-ui.override {
    version = "<published-version>";
    url = "https://<release-host>/<signed-release>.zip";
    hash = "sha256-<archive-hash>";
  };
};
```

The ZIP must contain `LifeUI.app` at its root. A different hash fails closed.
The default URL follows the version when only version/hash are overridden.
Pin this flake in the consuming flake lock; it never follows the latest release
automatically. Choose one installation owner when adopting the module. An
existing cask declaration is not changed by this repository.

## Verification

```sh
nix flake check --no-write-lock-file
nix flake check --all-systems --no-build --no-write-lock-file
nix build .#life-ui --no-link --print-out-paths
```

The checks exercise module disabled/default/custom-package behavior, generic
release overrides, and extraction of a synthetic bundle containing an executable,
profile, ticket, signature resource and symlink. They compare every file's bytes
and require the executable bit and symlink target to survive.

For the real output path printed by `nix build`, run:

```sh
codesign --verify --deep --strict '<output>/Applications/LifeUI.app'
xcrun stapler validate '<output>/Applications/LifeUI.app'
spctl --assess --type execute --verbose=2 '<output>/Applications/LifeUI.app'
```

Verification on macOS, 2026-10-07 UTC, against published 0.6.0:

| Check | Result |
| --- | --- |
| Archive SHA-256 | `b65041f0ce0f0b55f761f806960adef6dd2126a09d8b819542e9b347d37ba1c9` |
| Nix build and synthetic preservation/module checks | Pass |
| All source/output file hashes, symlink targets, executable bits | Identical |
| arm64 and x86_64 entitlements and designated requirements | Identical |
| Strict signature, stapled ticket, Gatekeeper | Pass; Notarized Developer ID |

The [0.6.0 release CI](https://github.com/alexjmiller5/life-ui/actions/runs/37640029572)
also records `Data Protection Keychain create/read/update/delete passed` from
the separately signed production-adapter probe with a unique synthetic service.
That is release evidence, not a fresh local Keychain probe of the Nix output.
No user credentials were accessed and no application was installed for these
packaging checks. Installed-app launch, enrollment and fresh Nix-output Keychain
acceptance remain separate and unverified. A future release must retain the
existing release CI Keychain gate; byte/signature preservation alone is not a
substitute for it.

## Darwin installation and Homebrew migration

The flake exports `darwinModules.default` and `homeModules.default`. Use one
installation owner. The Darwin module publishes the signed release through
`environment.systemPackages` into `/Applications/Nix Apps/LifeUI.app`:

```nix
programs.life-ui = {
  enable = true;
  # package = inputs.life-ui.packages.${pkgs.system}.default;
  migrateFromHomebrew = true; # Only for an existing app-only cask installation.
};
```

Remove this app's cask declaration from the same host change. Save work and quit
the installed app normally before activation. Other casks and Homebrew's policy
stay unchanged; Homebrew distribution remains supported.

An early activation check rejects an undeclared migration, unknown/orphan receipt,
uninstall hooks, or a running app before bundles are published. After publication,
the module rechecks the receipt and process, verifies the new bundle's signature
and contents against its package, then uninstalls only the exact cask without
`--zap`. Failure stops activation before normal Homebrew cleanup. Activation is
not atomic: a failure can leave both app bundles present for review. Never delete
application data, preferences or Keychain items to recover a packaging failure.

Keep the old signed release and receipt before migration. Roll back with an
explicit `package` override to that signed release after checking data-format
compatibility. An old Homebrew declaration can fetch the current tap version;
rolling back a Nix generation alone does not necessarily restore an old cask.
Native sign-in, enrollment and permission prompts stay app-managed user state.
A replacement machine enrolls through the app's normal interface.

Run `python3 scripts/test-nix-migration.py` for the isolated activation cases and
`nix flake check` for the package/module checks. The package's `version`, `url`
and `hash` inputs can pin another immutable signed release without rebuilding
or modifying the application.
