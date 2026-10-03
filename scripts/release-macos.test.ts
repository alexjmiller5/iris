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
