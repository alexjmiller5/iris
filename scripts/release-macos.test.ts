import { expect, test } from "bun:test";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const workflow = Bun.YAML.parse(
  await Bun.file(
    new URL("../.github/workflows/release-macos.yml", import.meta.url),
  ).text(),
) as any;
const script = workflow.jobs.cask.steps.find(
  (step: any) => step.name === "Update Homebrew cask",
).run;
const sha = "a".repeat(64),
  otherSha = "b".repeat(64);
const cask = (version: string, checksum = sha) =>
  `cask "example-app" do\n  version "${version}"\n  sha256 "${checksum}"\nend\n`;

const cases = [
  {
    name: "first release creates a cask",
    existing: null,
    version: "1.0.0",
    update: true,
  },
  {
    name: "forward release compares numeric components",
    existing: cask("1.9.0"),
    version: "1.10.0",
    update: true,
  },
  {
    name: "identical version and hash is a no-op",
    existing: cask("1.2.0"),
    version: "1.2.0",
    update: false,
  },
  {
    name: "stale retry leaves a newer cask untouched",
    existing: cask("1.2.0", otherSha),
    version: "1.1.0",
    update: false,
  },
  {
    name: "identical version rejects a different artifact hash",
    existing: cask("1.2.0", otherSha),
    version: "1.2.0",
    error: true,
  },
  {
    name: "unknown cask format fails closed",
    existing: "not a supported cask\n",
    version: "1.2.0",
    error: true,
  },
  {
    name: "prerelease existing version fails closed",
    existing: cask("1.0.0-beta.1"),
    version: "1.2.0",
    error: true,
  },
  {
    name: "leading-zero existing version fails closed",
    existing: cask("01.0.0"),
    version: "1.2.0",
    error: true,
  },
  {
    name: "missing checksum fails closed",
    existing: cask("1.0.0").replace(/  sha256.*\n/, ""),
    version: "1.2.0",
    error: true,
  },
  {
    name: "nonhex checksum fails closed",
    existing: cask("1.0.0", "z".repeat(64)),
    version: "1.2.0",
    error: true,
  },
  {
    name: "duplicate version is ambiguous",
    existing: cask("1.0.0").replace("end", '  version "2.0.0"\nend'),
    version: "1.2.0",
    error: true,
  },
  {
    name: "duplicate checksum is ambiguous",
    existing: cask("1.0.0").replace("end", `  sha256 "${otherSha}"\nend`),
    version: "1.2.0",
    error: true,
  },
  {
    name: "existing Ruby expression is never evaluated",
    existing: cask("1.0.0").replace(
      '"1.0.0"',
      '(File.write("executed", "yes"); "1.0.0")',
    ),
    version: "1.2.0",
    error: true,
  },
  {
    name: "missing release hash fails closed",
    existing: null,
    version: "1.2.0",
    checksum: "",
    error: true,
  },
  {
    name: "invalid incoming version fails closed",
    existing: null,
    version: "v1.2.0",
    error: true,
  },
] as const;

for (const fixture of cases)
  test(fixture.name, async () => {
    const root = await mkdtemp(join(tmpdir(), "life-ui-cask-test-"));
    const file = join(root, "tap/Casks/example-app.rb");
    try {
      await mkdir(join(root, "tap/Casks"), { recursive: true });
      if (fixture.existing !== null) await writeFile(file, fixture.existing);
      // Exercise the real workflow shell; every git call is intercepted before any network/auth.
      const child = Bun.spawn(
        [
          "bash",
          "-euo",
          "pipefail",
          "-c",
          `git() { printf '%s\\n' "$*" >> git-calls; if [[ "$*" == *'diff --cached --quiet'* ]]; then return 1; fi; };\n${script}`,
        ],
        {
          cwd: root,
          env: {
            ...process.env,
            APP: "ExampleApp",
            CASK: "example-app",
            GITHUB_REPOSITORY: "example/example-app",
            RELEASE_VERSION: fixture.version,
            SHA256: "checksum" in fixture ? fixture.checksum : sha,
          },
          stdout: "pipe",
          stderr: "pipe",
        },
      );
      const [status, out, err] = await Promise.all([
        child.exited,
        new Response(child.stdout).text(),
        new Response(child.stderr).text(),
      ]);
      const contents = await readFile(file, "utf8").catch(() => null);
      const calls = await readFile(join(root, "git-calls"), "utf8").catch(
        () => "",
      );
      expect(await Bun.file(join(root, "executed")).exists()).toBe(false);
      if ("error" in fixture) expect(status, out + err).not.toBe(0);
      else expect(status, out + err).toBe(0);
      if ("update" in fixture && fixture.update) {
        expect(contents).toContain(`version "${fixture.version}"`);
        expect(contents).toContain(`sha256 "${sha}"`);
        expect(calls).toContain("-C tap push");
      } else {
        expect(contents).toBe(fixture.existing);
        expect(calls).toBe("");
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

test.skipIf(process.platform !== "darwin")(
  "universal verification accepts both architectures and rejects a thin app",
  async () => {
    const root = await mkdtemp(join(tmpdir(), "life-ui-universal-test-"));
    try {
      const executable = join(root, "build/Fixture.app/Contents/MacOS/Fixture");
      await mkdir(join(root, "build/Fixture.app/Contents/MacOS"), {
        recursive: true,
      });
      const source = join(root, "fixture.c");
      await writeFile(source, "int main(void) { return 0; }\n");
      const step = workflow.jobs.release.steps
        .map((step: any) => step.run ?? "")
        .join("\n");
      const command = step
        .split("\n")
        .filter((line: string) => line.trim().startsWith("lipo "))
        .join("\n");
      expect(command).toBeDefined();
      for (const architectures of [
        ["arm64", "x86_64"],
        ["arm64"],
        ["x86_64"],
      ]) {
        const compile = Bun.spawn(
          [
            "xcrun",
            "clang",
            ...architectures.flatMap((arch) => ["-arch", arch]),
            source,
            "-o",
            executable,
          ],
          { stdout: "pipe", stderr: "pipe" },
        );
        expect(await compile.exited).toBe(0);
        const verify = Bun.spawn(["bash", "-euc", command], {
          cwd: root,
          env: { ...process.env, APP: "Fixture" },
          stdout: "pipe",
          stderr: "pipe",
        });
        const code = await verify.exited;
        const diagnostic =
          (await new Response(verify.stdout).text()) +
          (await new Response(verify.stderr).text());
        if (architectures.length === 2) expect(code, diagnostic).toBe(0);
        else expect(code).not.toBe(0);
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
);

// Exercise the release verifier against real universal Mach-O signatures.
// Removing either architecture inspection must accept a broken fixture and fail.
test.skipIf(process.platform !== "darwin")(
  "private Keychain identity is required in each signed architecture",
  async () => {
    const root = await mkdtemp(join(tmpdir(), "life-ui-signing-test-"));
    try {
      const app = join(root, "Fixture.app");
      await mkdir(join(app, "Contents/MacOS"), { recursive: true });
      await writeFile(
        join(root, "fixture.c"),
        "int main(void) { return 0; }\n",
      );
      const valid = join(root, "valid.plist");
      const empty = join(root, "empty.plist");
      await writeFile(
        valid,
        `<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.application-identifier</key><string>TESTTEAM01.org.example.fixture</string><key>com.apple.developer.team-identifier</key><string>TESTTEAM01</string></dict></plist>`,
      );
      await writeFile(
        empty,
        `<?xml version="1.0"?><plist version="1.0"><dict/></plist>`,
      );
      async function run(args: string[]) {
        const process = Bun.spawn(args, { stdout: "pipe", stderr: "pipe" });
        const [code, out, err] = await Promise.all([
          process.exited,
          new Response(process.stdout).text(),
          new Response(process.stderr).text(),
        ]);
        return { code, diagnostic: out + err };
      }
      for (const missing of [null, "arm64", "x86_64"]) {
        for (const arch of ["arm64", "x86_64"]) {
          const binary = join(root, arch);
          const compile = await run([
            "xcrun",
            "clang",
            "-arch",
            arch,
            join(root, "fixture.c"),
            "-o",
            binary,
          ]);
          expect(compile.code, compile.diagnostic).toBe(0);
          const sign = await run([
            "codesign",
            "--force",
            "--sign",
            "-",
            "--identifier",
            "org.example.fixture",
            "--entitlements",
            arch === missing ? empty : valid,
            binary,
          ]);
          expect(sign.code, sign.diagnostic).toBe(0);
        }
        const merge = await run([
          "lipo",
          "-create",
          join(root, "arm64"),
          join(root, "x86_64"),
          "-output",
          join(app, "Contents/MacOS/Fixture"),
        ]);
        expect(merge.code, merge.diagnostic).toBe(0);
        const verify = await run([
          "python3",
          "-c",
          `
import datetime,runpy,sys
module=runpy.run_path(sys.argv[1])
profile={"ApplicationIdentifierPrefix":["TESTTEAM01"],"TeamIdentifier":["TESTTEAM01"],"Platform":["OSX"],"ProvisionsAllDevices":True,"ExpirationDate":datetime.datetime(2099,1,1),"DeveloperCertificates":[b"fixture"],"Entitlements":{"com.apple.application-identifier":"TESTTEAM01.org.example.fixture","com.apple.developer.team-identifier":"TESTTEAM01"}}
for arch, claims in module["read_claims"](sys.argv[2]):
    module["verify_claims"](claims,profile,"TESTTEAM01","org.example.fixture",b"fixture")
`,
          new URL("./verify-macos-signing.py", import.meta.url).pathname,
          app,
        ]);
        if (missing === null) expect(verify.code, verify.diagnostic).toBe(0);
        else
          expect(
            verify.code,
            "Missing " + missing + " identity was accepted",
          ).not.toBe(0);
      }
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  },
);
