import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync, mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const file = '.github/workflows/build-ios.yml';
const workflow = () => Bun.YAML.parse(readFileSync(file, 'utf8')) as any;

describe('iOS distribution workflow boundary', () => {
  test('exported builds identify each dispatch and retry without changing the release version', () => {
    const steps = workflow().jobs.build.steps;
    const stamp = steps.findIndex((s: any) => s.name === 'Stamp identifiable build');
    expect(stamp).toBeGreaterThan(steps.findIndex((s: any) => s.name === 'Generate project'));
    expect(stamp).toBeLessThan(steps.findIndex((s: any) => s.run?.includes('scripts/sign-ios.py')));
    const root = mkdtempSync(join(tmpdir(), 'iris-build-identity-'));
    try {
      const plists = ['App', 'Widgets', 'Share'].map(name => join(root, 'apps/ios', name, 'Info.plist'));
      for (const path of plists) {
        mkdirSync(join(path, '..'), { recursive: true });
        const seed = Bun.spawnSync(['python3', '-c', 'import plistlib,sys; plistlib.dump({"CFBundleVersion":"1","CFBundleShortVersionString":"1.0","CFBundleIdentifier":"com.example.fixture"},open(sys.argv[1],"wb"))', path]);
        expect(seed.exitCode).toBe(0);
      }
      const info = plists[0];
      for (const [run, attempt] of [['71', '1'], ['71', '2'], ['72', '1']]) {
        const result = Bun.spawnSync(['python3', '-c', steps[stamp].run], { cwd: root, env: { ...process.env, GITHUB_RUN_NUMBER: run, GITHUB_RUN_ATTEMPT: attempt, GITHUB_SHA: 'a'.repeat(40) } });
        expect(result.exitCode).toBe(0);
        // Every embedded extension carries the app's exact build number.
        for (const path of plists) {
          const read = Bun.spawnSync(['python3', '-c', 'import json,plistlib,sys; print(json.dumps(plistlib.load(open(sys.argv[1],"rb"))))', path]);
          const value = JSON.parse(read.stdout.toString());
          expect(value.CFBundleVersion).toBe(`${run}.${attempt}`);
          expect(value.CFBundleShortVersionString).toBe('1.0');
          expect(value.CFBundleIdentifier).toBe('com.example.fixture');
        }
      }
      const before = readFileSync(info);
      const invalid = Bun.spawnSync(['python3', '-c', steps[stamp].run], { cwd: root, env: { ...process.env, GITHUB_RUN_NUMBER: 'bad', GITHUB_RUN_ATTEMPT: '1' } });
      expect(invalid.exitCode).not.toBe(0);
      expect(readFileSync(info)).toEqual(before);
      const verify = steps.findIndex((s: any) => s.name === 'Verify exported build identity');
      expect(verify).toBeGreaterThan(steps.findIndex((s: any) => s.run?.includes('scripts/sign-ios.py')));
      expect(verify).toBeLessThan(steps.findIndex((s: any) => s.run?.includes('age --encrypt')));
      mkdirSync(join(root, 'ios-output'));
      const pack = Bun.spawnSync(['python3', '-c', 'import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],"w"); z.write(sys.argv[2],"Payload/Fixture.app/Info.plist"); z.close()', join(root, 'ios-output/App.ipa'), info]);
      expect(pack.exitCode).toBe(0);
      const verifyRun = (run: string) => Bun.spawnSync(['python3', '-c', steps[verify].run], { env: { ...process.env, RUNNER_TEMP: root, GITHUB_RUN_NUMBER: run, GITHUB_RUN_ATTEMPT: '1' } });
      expect(verifyRun('72').exitCode).toBe(0);
      expect(verifyRun('73').exitCode).not.toBe(0);
    } finally { rmSync(root, { recursive: true }); }
  });
  test('requires an explicit manual dispatch and recipient', () => {
    expect(existsSync(file)).toBe(true);
    const w = workflow();
    expect(Object.keys(w.on)).toEqual(['workflow_dispatch']);
    expect(w.on.workflow_dispatch.inputs.artifact_recipient.required).toBe(true);
    expect(w.permissions).toEqual({ contents: 'read' });
  });
  test('uploads encrypted IPA only with one day retention', () => {
    const steps = workflow().jobs.build.steps;
    const uploads = steps.filter((s: any) => s.uses?.startsWith('actions/upload-artifact@'));
    expect(uploads.length).toBe(1);
    expect(uploads[0].with.path).toBe('${{ runner.temp }}/ios-artifact/Iris.ipa.age');
    expect(uploads[0].with['retention-days']).toBe(1);
    expect(uploads[0].with['if-no-files-found']).toBe('error');
  });
  test('encrypts after signed artifact verification and fails closed', () => {
    const steps = workflow().jobs.build.steps;
    const sign = steps.findIndex((s: any) => s.run?.includes('scripts/sign-ios.py'));
    const encrypt = steps.findIndex((s: any) => s.run?.includes('age --encrypt'));
    const upload = steps.findIndex((s: any) => s.uses?.startsWith('actions/upload-artifact@'));
    expect(sign).toBeGreaterThan(-1);
    expect(encrypt).toBeGreaterThan(sign);
    expect(upload).toBeGreaterThan(encrypt);
    expect(steps[encrypt].run).toContain('set -euo pipefail');
    expect(steps[encrypt].env.ARTIFACT_RECIPIENT).toBe('${{ inputs.artifact_recipient }}');
    expect(steps[encrypt].run).not.toContain('${{ inputs.');
  });
  test('removes plaintext output even when encryption fails', () => {
    const cleanup = workflow().jobs.build.steps.find((s: any) => s.name === 'Remove plaintext output');
    expect(cleanup.if).toBe('always()');
    expect(cleanup.run).toContain('ios-output');
  });
  test('requires the intended phone from the secret seam', () => {
    const sign = workflow().jobs.build.steps.find((s: any) => s.name === 'Sign and verify Ad Hoc IPA');
    const load = workflow().jobs.build.steps.find((s: any) => s.uses?.startsWith('1password/load-secrets-action@'));
    expect(load.env.IOS_DEVICE_ID).toBe('op://Iris/Iris ENV/IOS_DEVICE_ID');
    expect(sign.run).toContain('test -n "$IOS_DEVICE_ID"');
  });
  test('uses existing project service account and iOS distribution fields', () => {
    const step = workflow().jobs.build.steps.find((s: any) => s.uses?.startsWith('1password/load-secrets-action@'));
    expect(step.env.OP_SERVICE_ACCOUNT_TOKEN).toBe('${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}');
    expect(step.env.IOS_CERTIFICATE_P12_BASE64).toBe('op://Apple Signing/Apple Distribution Cert/p12_base64');
    expect(step.env.IOS_CERTIFICATE_PASSWORD).toBe('op://Apple Signing/Apple Distribution Cert/password');
    expect(step.env.IOS_PROFILE_BASE64).toBeUndefined();
    expect(step.env.ASC_KEY_P8_BASE64).toBe('op://Apple Signing/App Store Connect API Key/p8_base64');
    const download = workflow().jobs.build.steps.find((s: any) => s.name === 'Download app and extension Ad Hoc profiles');
    expect(download.env.PROFILE_IDS.match(/\$\{\{[^}]+\}\}/g)).toEqual([
      '${{ vars.IOS_PROVISIONING_PROFILE_ID }}',
      '${{ vars.IOS_WIDGETS_PROVISIONING_PROFILE_ID }}',
      '${{ vars.IOS_SHARE_PROVISIONING_PROFILE_ID }}',
    ]);
    expect(download.run).toContain('IOS_EXTENSION_PROFILES_BASE64=');
    expect(download.run).toContain("profile.profileType!=='IOS_APP_ADHOC'");
    expect(download.run).toContain('::add-mask::');
  });
});
