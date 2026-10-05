import { describe, expect, test } from 'bun:test';
import { existsSync, readFileSync } from 'node:fs';

const file = '.github/workflows/build-ios.yml';
const workflow = () => Bun.YAML.parse(readFileSync(file, 'utf8')) as any;

describe('iOS distribution workflow boundary', () => {
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
    expect(uploads[0].with.path).toBe('${{ runner.temp }}/ios-artifact/LifeUI.ipa.age');
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
    expect(load.env.IOS_DEVICE_ID).toBe('op://Life UI/Life UI ENV/IOS_DEVICE_ID');
    expect(sign.run).toContain('test -n "$IOS_DEVICE_ID"');
  });
  test('uses existing project service account and iOS distribution fields', () => {
    const step = workflow().jobs.build.steps.find((s: any) => s.uses?.startsWith('1password/load-secrets-action@'));
    expect(step.env.OP_SERVICE_ACCOUNT_TOKEN).toBe('${{ secrets.OP_SERVICE_ACCOUNT_TOKEN }}');
    expect(step.env.IOS_CERTIFICATE_P12_BASE64).toBe('op://Apple Signing/Apple Distribution Cert/p12_base64');
    expect(step.env.IOS_CERTIFICATE_PASSWORD).toBe('op://Apple Signing/Apple Distribution Cert/password');
    expect(step.env.IOS_PROFILE_BASE64).toBe('op://Apple Signing/Wildcard Ad Hoc Profile/mobileprovision_base64');
  });
});
