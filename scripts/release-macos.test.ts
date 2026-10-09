import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const workflow = Bun.YAML.parse(
  await Bun.file(
    new URL("../.github/workflows/release-macos.yml", import.meta.url),
  ).text(),
) as any;

// Run the workflow's real shell/JSON validation, replacing only remote/native
// operations. No Apple credentials, app build, GitHub calls or native signing.
const submissionId = "11111111-2222-4333-8444-555555555555";
const sourceSha = "c".repeat(40);
const archiveBytes = "synthetic signed archive";
const archiveHash = createHash("sha256").update(archiveBytes).digest("hex");
const stepScript = (job: string, name: string) => {
  const step = workflow.jobs[job]?.steps.find((s: any) => s.name === name);
  expect(step, `missing workflow step ${job}/${name}`).toBeDefined();
  return step.run as string;
};

async function recoveryFixture() {
  const root = await mkdtemp(join(tmpdir(), "iris-recovery-test-"));
  await mkdir(join(root, "saved"));
  await mkdir(join(root, "build/Fixture.app/Contents"), { recursive: true });
  await mkdir(join(root, "runner"));
  await writeFile(join(root, "archive"), archiveBytes);
  await writeFile(join(root, "saved/Fixture-notarize.zip"), archiveBytes);
  await writeFile(
    join(root, "build/Fixture.app/Contents/Info.plist"),
    '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>0.4.0</string><key>CFBundleVersion</key><string>7</string></dict></plist>',
  );
  const receipt = {
    schemaVersion: 1,
    repository: "fixture/app",
    runId: "123",
    runNumber: "7",
    sourceSha,
    tag: "v0.4.0",
    version: "0.4.0",
    archiveSha256: archiveHash,
    submissionId,
    teamId: "ABC1234567",
    certificateSha1: "D".repeat(40),
  };
  const env = {
    ...process.env,
    APP: "Fixture",
    GITHUB_REPOSITORY: "fixture/app",
    GITHUB_RUN_ID: "123",
    GITHUB_RUN_NUMBER: "7",
    GITHUB_RUN_ATTEMPT: "1",
    GITHUB_SHA: sourceSha,
    GITHUB_REF_NAME: "v0.4.0",
    RELEASE_VERSION: "0.4.0",
    GITHUB_ENV: join(root, "env"),
    GITHUB_OUTPUT: join(root, "output"),
    RUNNER_TEMP: join(root, "runner"),
    FIXTURE_ROOT: root,
    SUBMISSION_ID: submissionId,
    SUBMITTED_SHA256: archiveHash,
    EXPECTED_SUBMISSION_ID: submissionId,
    EXPECTED_ARCHIVE_SHA256: archiveHash,
    EXPECTED_RECEIPT_SHA256: "",
    SIGNING_TEAM: "ABC1234567",
    SIGNING_CERTIFICATE: "D".repeat(40),
    TEAM_ID: "ABC1234567",
    IDENTITY_SHA: "D".repeat(40),
    ASC_KEY_P8_BASE64: Buffer.from("synthetic-private-key").toString("base64"),
    ASC_KEY_ID: "synthetic-key",
    ASC_ISSUER_ID: "synthetic-issuer",
    WAIT_STATUS: "Accepted",
    WAIT_ID: submissionId,
    WAIT_EXIT: "0",
    LOG_ID: submissionId,
    LOG_SHA: archiveHash,
    LOG_STATUS: "Accepted",
    GH_EXIT: "0",
    GH_TOKEN: "synthetic-github-token",
    PREFLIGHT_STATUS: "404",
    FIXTURE_API_EXIT: "1",
    PREFLIGHT_BODY: '{"message":"Not Found","status":"404"}',
    DRAFT_STATUS: "200",
    DRAFT_EXIT: "0",
    DRAFT_BODY: '{"data":{"repository":{"release":null}}}',
    KEYCHAIN_EXIT: "0",
  };
  const save = async (value = receipt) => {
    const bytes = JSON.stringify(value);
    await writeFile(join(root, "saved/notarization-receipt.json"), bytes);
    env.EXPECTED_RECEIPT_SHA256 = createHash("sha256")
      .update(bytes)
      .digest("hex");
  };
  await save();
  const doubles = `
    xcrun() {
      printf '%s\\n' "$*" >> "$FIXTURE_ROOT/calls"
      case "$1 $2" in
        'notarytool submit')
          [[ " $* " != *' --wait '* ]] || return 97
          printf '{"id":"%s","message":"Successfully uploaded file"}\\n' "$SUBMISSION_ID";;
        'notarytool wait') printf '{"id":"%s","status":"%s"}\\n' "$WAIT_ID" "$WAIT_STATUS"; return "$WAIT_EXIT";;
        'notarytool log') printf '{"jobId":"%s","status":"%s","statusCode":0,"sha256":"%s","issues":null}\\n' "$LOG_ID" "$LOG_STATUS" "$LOG_SHA" > "\${@: -1}";;
        'stapler staple'|'stapler validate') :;;
        *) return 99;;
      esac
    }
    ditto() { if [[ "$1" == -c ]]; then cp "$FIXTURE_ROOT/archive" "\${@: -1}"; fi; }
    lipo() { printf 'lipo %s\\n' "$*" >> "$FIXTURE_ROOT/calls"; }
    codesign() { printf 'codesign %s\\n' "$*" >> "$FIXTURE_ROOT/calls"; }
    spctl() { printf 'spctl %s\\n' "$*" >> "$FIXTURE_ROOT/calls"; }
    gh() {
      printf 'gh %s\\n' "$*" >> "$FIXTURE_ROOT/calls"
      if [[ "$1" == api ]]; then
        if [[ "$2" == graphql ]]; then
          if [[ "$DRAFT_STATUS" != network ]]; then
            printf 'HTTP/2.0 %s Test\\r\\nContent-Type: application/json\\r\\n\\r\\n%s\\n' "$DRAFT_STATUS" "$DRAFT_BODY"
          fi
          return "$DRAFT_EXIT"
        fi
        if [[ "$PREFLIGHT_STATUS" != network ]]; then
          printf 'HTTP/2.0 %s Test\\r\\nContent-Type: application/json\\r\\n\\r\\n%s\\n' "$PREFLIGHT_STATUS" "$PREFLIGHT_BODY"
        fi
        return "$FIXTURE_API_EXIT"
      fi
      return "$GH_EXIT"
    }
    xcodebuild() { printf 'unexpected native build\\n' >> "$FIXTURE_ROOT/calls"; return 98; }
    security() { printf 'unexpected Keychain operation\\n' >> "$FIXTURE_ROOT/calls"; return 98; }
    bash() {
      if [[ "$1" == scripts/test-macos-keychain.sh ]]; then
        printf 'Keychain CRUD gate\\n' >> "$FIXTURE_ROOT/calls"; return "$KEYCHAIN_EXIT"
      else command bash "$@"; fi
    }
    python3() {
      if [[ "$1" == scripts/verify-macos-signing.py ]]; then
        printf 'verify-signing %s\\n' "$*" >> "$FIXTURE_ROOT/calls"
      else command python3 "$@"; fi
    }
  `;
  const run = async (script: string) => {
    const child = Bun.spawn(
      ["bash", "-euo", "pipefail", "-c", doubles + script],
      { cwd: root, env, stdout: "pipe", stderr: "pipe" },
    );
    const [code, stdout, stderr] = await Promise.all([
      child.exited,
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
    ]);
    return { code, diagnostic: stdout + stderr };
  };
  const calls = async () =>
    Bun.file(join(root, "calls"))
      .exists()
      .then((exists) => (exists ? Bun.file(join(root, "calls")).text() : ""));
  return {
    root,
    env,
    receipt,
    save,
    run,
    calls,
    close: () => rm(root, { recursive: true, force: true }),
  };
}

test("release recovery keeps successful submission artifact across a release-only retry", async () => {
  expect(workflow.jobs.release.needs).toBe("submit");
  const upload = workflow.jobs.submit.steps.find(
    (s: any) => s.id === "artifact",
  );
  const download = workflow.jobs.release.steps.find((s: any) =>
    s.uses?.startsWith("actions/download-artifact@"),
  );
  expect(workflow.jobs.submit.outputs.artifact_id).toBe(
    "${{ steps.artifact.outputs.artifact-id }}",
  );
  expect(download.with["artifact-ids"]).toBe(
    "${{ needs.submit.outputs.artifact_id }}",
  );
  expect(download.with.name).toBeUndefined();
  expect(download["continue-on-error"]).toBeUndefined();
  expect(download.if).toBeUndefined();
  expect(upload.with["retention-days"]).toBe(3);
  expect(upload.with["if-no-files-found"]).toBe("error");
  expect(upload.continueOnError ?? upload["continue-on-error"]).toBeUndefined();
  expect(upload.with.overwrite).not.toBe(true);
  const submitSteps = workflow.jobs.submit.steps;
  expect(
    submitSteps.findIndex((s: any) => s.name === "Sign and verify app"),
  ).toBeLessThan(
    submitSteps.findIndex((s: any) => s.name === "Submit signed archive"),
  );
  expect(
    submitSteps.findIndex((s: any) => s.name === "Submit signed archive"),
  ).toBeLessThan(submitSteps.indexOf(upload));
  expect(
    submitSteps.find((s: any) => s.name === "Delete temporary signing material")
      .if,
  ).toBe("always()");
  expect(
    workflow.jobs.release.steps.find(
      (s: any) => s.name === "Delete temporary notary material",
    ).if,
  ).toBe("always()");
  expect(upload.with.path.trim().split("\n")).toEqual([
    "build/Iris-notarize.zip",
    "build/notarization-receipt.json",
  ]);
  const f = await recoveryFixture();
  try {
    let r = await f.run(stepScript("submit", "Submit signed archive"));
    expect(r.code, r.diagnostic).toBe(0);
    const written = JSON.parse(
      await readFile(join(f.root, "build/notarization-receipt.json"), "utf8"),
    );
    expect(written).toEqual(f.receipt);
    expect(
      await Bun.file(join(f.root, "runner/iris-notary.p8")).exists(),
    ).toBe(false);
    await f.save(written);
    r = await f.run(stepScript("release", "Validate saved submission"));
    expect(r.code, r.diagnostic).toBe(0);
    f.env.WAIT_STATUS = "In Progress";
    f.env.WAIT_EXIT = "124";
    r = await f.run(stepScript("release", "Wait for existing notarization"));
    expect(r.code).toBe(124);
    expect(
      await Bun.file(join(f.root, "runner/iris-notary.p8")).exists(),
    ).toBe(false);
    f.env.GITHUB_RUN_ATTEMPT = "2";
    f.env.WAIT_STATUS = "Accepted";
    f.env.WAIT_EXIT = "0";
    r = await f.run(
      stepScript("release", "Validate saved submission") +
        "\n" +
        stepScript("release", "Wait for existing notarization") +
        "\n" +
        stepScript("release", "Package accepted app") +
        "\n" +
        stepScript("release", "Publish GitHub release"),
    );
    expect(r.code, r.diagnostic).toBe(0);
    const calls = await f.calls();
    expect(calls.match(/notarytool submit/g)).toHaveLength(1);
    expect(
      calls.match(new RegExp(`notarytool wait ${submissionId}`, "g")),
    ).toHaveLength(2);
    expect(calls).not.toContain("submit --wait");
    expect(calls).toContain("stapler validate");
    expect(calls).toContain("gh release create v0.4.0 --verify-tag");
  } finally {
    await f.close();
  }
});

for (const field of [
  "repository",
  "runId",
  "runNumber",
  "sourceSha",
  "tag",
  "version",
  "archiveSha256",
  "submissionId",
]) {
  test(`release recovery rejects changed receipt ${field} before waiting`, async () => {
    const f = await recoveryFixture();
    try {
      await f.save({ ...f.receipt, [field]: "wrong" });
      const r = await f.run(stepScript("release", "Validate saved submission"));
      expect(r.code, r.diagnostic).not.toBe(0);
      expect(await f.calls()).toBe("");
    } finally {
      await f.close();
    }
  });
}

for (const failure of [
  "missing/expired artifact",
  "archive digest",
  "receipt digest",
  "invalid UUID",
]) {
  test(`release recovery fails closed for ${failure}`, async () => {
    const f = await recoveryFixture();
    try {
      if (failure === "missing/expired artifact")
        await rm(join(f.root, "saved"), { recursive: true });
      if (failure === "archive digest")
        await writeFile(join(f.root, "saved/Fixture-notarize.zip"), "tampered");
      if (failure === "receipt digest")
        f.env.EXPECTED_RECEIPT_SHA256 = "0".repeat(64);
      if (failure === "invalid UUID") {
        f.env.EXPECTED_SUBMISSION_ID = "not-a-uuid";
        await f.save({ ...f.receipt, submissionId: "not-a-uuid" });
      }
      const r = await f.run(stepScript("release", "Validate saved submission"));
      expect(r.code, r.diagnostic).not.toBe(0);
      expect(await f.calls()).toBe("");
    } finally {
      await f.close();
    }
  });
}

for (const failure of [
  "pending",
  "rejected",
  "auth",
  "status ID",
  "log jobId",
  "log SHA",
  "log status",
]) {
  test(`release recovery never publishes after ${failure}`, async () => {
    const f = await recoveryFixture();
    try {
      if (failure === "pending") f.env.WAIT_STATUS = "In Progress";
      if (failure === "rejected") f.env.WAIT_STATUS = "Invalid";
      if (failure === "auth") f.env.WAIT_EXIT = "1";
      if (failure === "status ID")
        f.env.WAIT_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
      if (failure === "log jobId")
        f.env.LOG_ID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
      if (failure === "log SHA") f.env.LOG_SHA = "0".repeat(64);
      if (failure === "log status") f.env.LOG_STATUS = "Invalid";
      const r = await f.run(
        stepScript("release", "Wait for existing notarization") +
          "\n" +
          stepScript("release", "Package accepted app") +
          "\n" +
          stepScript("release", "Publish GitHub release"),
      );
      expect(r.code, r.diagnostic).not.toBe(0);
      expect(await f.calls()).not.toMatch(/stapler|gh release/);
      expect(
        await Bun.file(join(f.root, "runner/iris-notary.p8")).exists(),
      ).toBe(false);
    } finally {
      await f.close();
    }
  });
}

test("release recovery stops on ambiguous publication and loads no signing secrets", async () => {
  const f = await recoveryFixture();
  try {
    f.env.GH_EXIT = "1";
    const r = await f.run(stepScript("release", "Publish GitHub release"));
    expect(r.code).not.toBe(0);
    expect(await f.calls()).not.toMatch(/delete|upload|--clobber|edit/);
    const secrets = workflow.jobs.release.steps.find((s: any) =>
      s.uses?.startsWith("1password/load-secrets-action@"),
    );
    expect(Object.keys(secrets.env).sort()).toEqual([
      "ASC_ISSUER_ID",
      "ASC_KEY_ID",
      "ASC_KEY_P8_BASE64",
      "OP_SERVICE_ACCOUNT_TOKEN",
    ]);
    expect(workflow.jobs.cask.needs).toBe("release");
  } finally {
    await f.close();
  }
});

for (const fixture of [
  {
    name: "existing published release",
    status: "200",
    exit: "0",
    body: '{"id":7,"draft":false}',
  },
  {
    name: "existing draft release",
    status: "200",
    exit: "0",
    body: '{"id":7,"draft":true}',
  },
  {
    name: "authenticated absence",
    status: "404",
    exit: "1",
    body: '{"message":"Not Found","status":"404"}',
    create: true,
  },
  {
    name: "unauthorized",
    status: "401",
    exit: "1",
    body: '{"message":"Bad credentials"}',
  },
  {
    name: "forbidden",
    status: "403",
    exit: "1",
    body: '{"message":"Forbidden"}',
  },
  {
    name: "rate limited",
    status: "429",
    exit: "1",
    body: '{"message":"Rate limit exceeded"}',
  },
  {
    name: "server failure",
    status: "503",
    exit: "1",
    body: '{"message":"Unavailable"}',
  },
  { name: "network failure", status: "network", exit: "1", body: "" },
  { name: "invalid response", status: "404", exit: "1", body: "not JSON" },
  {
    name: "unexpected not-found response",
    status: "404",
    exit: "1",
    body: '{"message":"Unexpected"}',
  },
  {
    name: "inconsistent exit status",
    status: "404",
    exit: "0",
    body: '{"message":"Not Found","status":"404"}',
  },
]) {
  test(`release recovery publication preflight handles ${fixture.name}`, async () => {
    const f = await recoveryFixture();
    try {
      Object.assign(f.env, {
        PREFLIGHT_STATUS: fixture.status,
        FIXTURE_API_EXIT: fixture.exit,
        PREFLIGHT_BODY: fixture.body,
      });
      const r = await f.run(stepScript("release", "Publish GitHub release"));
      const calls = await f.calls();
      expect(calls).toContain("repos/fixture/app/releases/tags/v0.4.0");
      if (fixture.create) {
        expect(r.code, r.diagnostic).toBe(0);
        expect(calls).toContain("gh release create v0.4.0");
      } else {
        expect(r.code).not.toBe(0);
        expect(calls).not.toMatch(/gh release|--clobber/);
      }
    } finally {
      await f.close();
    }
  });
}

test("release recovery publication preflight requires explicit authentication", async () => {
  const f = await recoveryFixture();
  try {
    f.env.GH_TOKEN = "";
    const r = await f.run(stepScript("release", "Publish GitHub release"));
    expect(r.code).not.toBe(0);
    expect(await f.calls()).toBe("");
  } finally {
    await f.close();
  }
});

for (const fixture of [
  {
    name: "draft hidden by REST404",
    status: "200",
    exit: "0",
    body: '{"data":{"repository":{"release":{"id":"fixture","isDraft":true}}}}',
  },
  {
    name: "published race after REST404",
    status: "200",
    exit: "0",
    body: '{"data":{"repository":{"release":{"id":"fixture","isDraft":false}}}}',
  },
  {
    name: "GraphQL error",
    status: "200",
    exit: "0",
    body: '{"errors":[{"message":"denied"}],"data":{"repository":{"release":null}}}',
  },
  {
    name: "missing repository",
    status: "200",
    exit: "0",
    body: '{"data":{"repository":null}}',
  },
  {
    name: "missing release field",
    status: "200",
    exit: "0",
    body: '{"data":{"repository":{}}}',
  },
  {
    name: "draft lookup auth failure",
    status: "401",
    exit: "1",
    body: '{"message":"Bad credentials"}',
  },
  {
    name: "draft lookup server failure",
    status: "503",
    exit: "1",
    body: '{"message":"Unavailable"}',
  },
  {
    name: "draft lookup network failure",
    status: "network",
    exit: "1",
    body: "",
  },
  {
    name: "malformed draft response",
    status: "200",
    exit: "0",
    body: "invalid JSON",
  },
]) {
  test(`release recovery publication preflight stops for ${fixture.name}`, async () => {
    const f = await recoveryFixture();
    try {
      Object.assign(f.env, {
        DRAFT_STATUS: fixture.status,
        DRAFT_EXIT: fixture.exit,
        DRAFT_BODY: fixture.body,
      });
      const r = await f.run(stepScript("release", "Publish GitHub release"));
      expect(r.code).not.toBe(0);
      expect(await f.calls()).toContain("gh api graphql --include");
      expect(await f.calls()).toContain("-f tag=v0.4.0");
      expect(await f.calls()).not.toContain("gh release create");
    } finally {
      await f.close();
    }
  });
}

test("release recovery requires actual Keychain gate success before submission", async () => {
  const f = await recoveryFixture();
  try {
    const sign = stepScript("submit", "Sign and verify app");
    const start = sign.indexOf('lipo "build/');
    expect(start).toBeGreaterThan(0);
    f.env.KEYCHAIN_EXIT = "1";
    const r = await f.run(
      sign.slice(start) + "\n" + stepScript("submit", "Submit signed archive"),
    );
    expect(r.code).not.toBe(0);
    expect(await f.calls()).toContain("Keychain CRUD gate");
    expect(await f.calls()).not.toContain("notarytool submit");
  } finally {
    await f.close();
  }
});

test("release recovery rejects an invalid new submission ID and cleans its key", async () => {
  const f = await recoveryFixture();
  try {
    f.env.SUBMISSION_ID = "not-a-uuid";
    const r = await f.run(stepScript("submit", "Submit signed archive"));
    expect(r.code).not.toBe(0);
    expect(
      await Bun.file(join(f.root, "build/notarization-receipt.json")).exists(),
    ).toBe(false);
    expect(
      await Bun.file(join(f.root, "runner/iris-notary.p8")).exists(),
    ).toBe(false);
  } finally {
    await f.close();
  }
});

test("release recovery rejects missing artifact identity before the download action", async () => {
  const f = await recoveryFixture();
  try {
    for (const id of ["", "0", "1,2", "attempt-2"]) {
      const script = stepScript("release", "Require saved artifact identity");
      const r = await f.run(`export EXPECTED_ARTIFACT_ID='${id}'\n${script}`);
      expect(r.code).not.toBe(0);
    }
    const r = await f.run(
      "export EXPECTED_ARTIFACT_ID=12345\n" +
        stepScript("release", "Require saved artifact identity"),
    );
    expect(r.code, r.diagnostic).toBe(0);
    const steps = workflow.jobs.release.steps;
    expect(
      steps.findIndex((s: any) => s.name === "Require saved artifact identity"),
    ).toBeLessThan(
      steps.findIndex((s: any) =>
        s.uses?.startsWith("actions/download-artifact@"),
      ),
    );
  } finally {
    await f.close();
  }
});

for (const field of ["CFBundleShortVersionString", "CFBundleVersion"]) {
  test(`release recovery refuses saved app ${field} mismatch`, async () => {
    const f = await recoveryFixture();
    try {
      const file = join(f.root, "build/Fixture.app/Contents/Info.plist");
      const data = await readFile(file, "utf8");
      await writeFile(
        file,
        data.replace(
          `<key>${field}</key><string>`,
          `<key>${field}</key><string>wrong-`,
        ),
      );
      const r = await f.run(stepScript("release", "Package accepted app"));
      expect(r.code).not.toBe(0);
      expect(await f.calls()).not.toContain("stapler");
    } finally {
      await f.close();
    }
  });
}
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
    const root = await mkdtemp(join(tmpdir(), "iris-cask-test-"));
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
        // Ruby accepts the old comparison string, but Homebrew requires a symbol.
        expect(contents).toMatch(/^\s*depends_on macos: :sonoma\s*$/m);
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
    const root = await mkdtemp(join(tmpdir(), "iris-universal-test-"));
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
  30_000, // Real compiler/signing subprocesses can exceed Bun's 5-second unit-test default.
);

// Exercise the release verifier against real universal Mach-O signatures.
// Removing either architecture inspection must accept a broken fixture and fail.
test.skipIf(process.platform !== "darwin")(
  "private identity and production push are required in each signed architecture",
  async () => {
    const root = await mkdtemp(join(tmpdir(), "iris-signing-test-"));
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
        `<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.application-identifier</key><string>TESTTEAM01.org.example.fixture</string><key>com.apple.developer.team-identifier</key><string>TESTTEAM01</string><key>com.apple.developer.aps-environment</key><string>production</string></dict></plist>`,
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
profile={"ApplicationIdentifierPrefix":["TESTTEAM01"],"TeamIdentifier":["TESTTEAM01"],"Platform":["OSX"],"ProvisionsAllDevices":True,"ExpirationDate":datetime.datetime(2099,1,1),"DeveloperCertificates":[b"fixture"],"Entitlements":{"com.apple.application-identifier":"TESTTEAM01.org.example.fixture","com.apple.developer.team-identifier":"TESTTEAM01","com.apple.developer.aps-environment":"production"}}
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
  30_000, // Real compiler/signing subprocesses can exceed Bun's 5-second unit-test default.
);
