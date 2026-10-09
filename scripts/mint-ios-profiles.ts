// Operator tool: mint one explicit Ad Hoc profile per iOS target (and the Mac
// Developer ID profile that shares the universal app App ID) with the existing
// certificates, after the App Group is assigned in the developer portal.
// Prints `VARIABLE=<profile id>` lines for `gh variable set`; never profile content.
//
//   op run --env-file=<operator tpl> -- bun scripts/mint-ios-profiles.ts
//
// Env: ASC_KEY_P8_BASE64, ASC_KEY_ID, ASC_ISSUER_ID (App Store Connect key) and
// IOS_DEVICE_ID (the enrolled phone's UDID, from the project ENV item).
import { createPrivateKey, sign } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const app = 'com.alexmiller.life-ui';
const group = 'group.' + app;
const targets = [
  { variable: 'IOS_PROVISIONING_PROFILE_ID', bundle: app, name: 'Life UI Ad Hoc', type: 'IOS_APP_ADHOC', cert: 'DISTRIBUTION' },
  { variable: 'IOS_WIDGETS_PROVISIONING_PROFILE_ID', bundle: app + '.widgets', name: 'Life UI Widgets Ad Hoc', type: 'IOS_APP_ADHOC', cert: 'DISTRIBUTION' },
  { variable: 'IOS_SHARE_PROVISIONING_PROFILE_ID', bundle: app + '.share', name: 'Life UI Share Ad Hoc', type: 'IOS_APP_ADHOC', cert: 'DISTRIBUTION' },
  { variable: 'MACOS_PROVISIONING_PROFILE_ID', bundle: app, name: 'Life UI Developer ID', type: 'MAC_APP_DIRECT', cert: 'DEVELOPER_ID_APPLICATION' },
];

const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const header = encode({ alg: 'ES256', kid: process.env.ASC_KEY_ID, typ: 'JWT' });
const claims = encode({ iss: process.env.ASC_ISSUER_ID, iat: now, exp: now + 1200, aud: 'appstoreconnect-v1' });
const key = createPrivateKey(Buffer.from(process.env.ASC_KEY_P8_BASE64 ?? '', 'base64'));
const jwt = `${header}.${claims}.` + sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
async function api(method: string, path: string, body?: unknown): Promise<any> {
  const response = await fetch('https://api.appstoreconnect.apple.com/v1' + path, {
    method, headers: { Authorization: 'Bearer ' + jwt, 'Content-Type': 'application/json' },
    body: body && JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${method} ${path.split('?')[0]}: HTTP ${response.status}`);
  return response.json();
}
const one = (rows: any[], what: string) => {
  if (rows.length !== 1) throw new Error(`Expected exactly one ${what}, found ${rows.length}`);
  return rows[0];
};

const udid = process.env.IOS_DEVICE_ID ?? '';
if (!/^[A-Za-z0-9-]+$/.test(udid)) throw new Error('IOS_DEVICE_ID is required');
const device = one((await api('GET', `/devices?filter[udid]=${encodeURIComponent(udid)}&filter[status]=ENABLED`)).data, 'enabled device');
const directory = mkdtempSync(join(tmpdir(), 'life-ui-profiles-'));
try {
  for (const target of targets) {
    const bundle = one((await api('GET', `/bundleIds?filter[identifier]=${target.bundle}&limit=200`)).data
      .filter((b: any) => b.attributes.identifier === target.bundle), `${target.bundle} App ID`);
    const certificate = one((await api('GET', `/certificates?filter[certificateType]=${target.cert}&limit=200`)).data
      .filter((c: any) => Date.parse(c.attributes.expirationDate) > Date.now()), `active ${target.cert} certificate`);
    const relationships: any = {
      bundleId: { data: { type: 'bundleIds', id: bundle.id } },
      certificates: { data: [{ type: 'certificates', id: certificate.id }] },
    };
    if (target.type === 'IOS_APP_ADHOC') relationships.devices = { data: [{ type: 'devices', id: device.id }] };
    const made = (await api('POST', '/profiles', {
      data: { type: 'profiles', attributes: { name: `${target.name} ${new Date().toISOString().slice(0, 10)}`, profileType: target.type }, relationships },
    })).data;
    const file = join(directory, made.id + '.mobileprovision');
    writeFileSync(file, Buffer.from(made.attributes.profileContent, 'base64'), { mode: 0o600 });
    const plist = execFileSync('security', ['cms', '-D', '-i', file]);
    const entitlements = JSON.parse(execFileSync('plutil', ['-extract', 'Entitlements', 'json', '-o', '-', '-'], { input: plist }).toString());
    const groups: string[] = entitlements['com.apple.security.application-groups'] ?? [];
    if (target.type === 'IOS_APP_ADHOC' && !groups.includes(group)) {
      throw new Error(`${target.bundle} profile lacks ${group}: assign the App Group in the developer portal first`);
    }
    console.log(`${target.variable}=${made.id}`);
  }
} finally {
  rmSync(directory, { recursive: true, force: true });
}
