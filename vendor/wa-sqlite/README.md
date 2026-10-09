# wa-sqlite with FTS5

Life UI's browser Worker uses this synchronous JS/WASM pair with the pinned
`wa-sqlite` JavaScript API and `OPFSCoopSyncVFS` from `apps/web/package.json`.
The build keeps upstream's exports, authorizer, VFS, optimization and compile
options, adding only `SQLITE_ENABLE_FTS5` through `WASQLITE_EXTRA_DEFINES`.

`manifest.json` pins and hashes wa-sqlite, the official SQLite amalgamation,
and extension-functions. `flake.lock` pins nixpkgs and the complete compiler
closure (Emscripten 6.0.9, LLVM 22.1.8 and Binaryen 132). Compilation runs in
Nix's build directory with a fresh Emscripten cache and no network fetches. Build-time
source downloads are fixed-output, hash-checked Nix derivations.

From the repository root, with Nix and Bun installed:

```sh
# Verify source/API compatibility and every committed output byte/hash.
bun scripts/build-wa-sqlite.ts --check
# Recompile in a fresh build directory and require the same Nix output and vendor bytes.
bun scripts/build-wa-sqlite.ts --check --rebuild
# Regenerate artifacts and SHA-256 records after an intentional pin update.
bun scripts/build-wa-sqlite.ts --write
```

The flake is also a standalone Nix package; after cloning the public repository:

```sh
nix build path:./vendor/wa-sqlite --no-link --print-out-paths
```

It exposes `packages.default` on Apple Silicon macOS, aarch64 Linux and x86_64
Linux. Byte reproducibility is checked on aarch64-darwin; other systems have
not been verified. Ordinary browser builds use the committed artifacts and do
not need Nix or Emscripten. The regeneration script copies only the three build
manifests to a temporary directory outside the checkout, removes it on exit,
and never installs a compiler or modifies machine configuration.

The disposable browser regression bundles the actual application Worker and
adds SQL probes only to the test bundle. Open a dedicated test tab at
`http://iris-fts.localhost:5209/fts-fixture`, then run:

```sh
LIFE_UI_TEST_CDP=http://127.0.0.1:9222 bun scripts/test-wa-sqlite.ts
```

If Chrome initially shows its connection error page because the temporary
server is not running yet, pass that tab's CDP target ID as
`LIFE_UI_TEST_TARGET`. The script starts/stops its own server and clears only
this reserved fixture origin. It retains the supplied tab for the caller to
close. `LIFE_UI_TEST_URL` can change the port but not the reserved host/path.
`LIFE_UI_TEST_WASM_DIR` selects another JS/WASM pair for regression comparison;
select `apps/web/node_modules/wa-sqlite/dist` to reproduce the missing-FTS5 RED.

The fixture covers OPFS, accent folding, prefix matching, snippets in Markdown,
trigger/queue atomicity, rollback, delete, read authorization and persistence
across close/reopen. It never opens a personal database or contacts a hub.

wa-sqlite is MIT licensed (included `LICENSE`). SQLite is public domain.
The extension-functions source is the same contribution used by upstream;
its original source header is available at the hash-pinned URL in `manifest.json`.
