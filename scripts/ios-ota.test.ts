import { expect, test } from 'bun:test';
import { mkdtemp, mkdir, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

test.each(['71.1', '71.2'])('OTA identifies build %s with its own install and download URLs', async (build) => {
  const root = await mkdtemp(join(tmpdir(), 'iris-ota-metadata-'));
  try {
    const ipa = join(root, 'fixture.ipa');
    const dir = join(root, 'served');
    await mkdir(dir);
    const seed = Bun.spawnSync(['python3', '-c', 'import plistlib,sys,zipfile; z=zipfile.ZipFile(sys.argv[1],"w"); z.writestr("Payload/Fixture.app/Info.plist",plistlib.dumps({"CFBundleIdentifier":"com.example.fixture","CFBundleDisplayName":"Fixture","CFBundleShortVersionString":"1.0","CFBundleVersion":sys.argv[2]})); z.close()', ipa, build]);
    expect(seed.exitCode).toBe(0);
    // Execute the real IPA-to-install-page path without publishing a tailnet service.
    const source = await readFile(new URL('./ota-install.sh', import.meta.url), 'utf8');
    const section = source.slice(source.indexOf('cp "$ipa"'), source.indexOf('port=$(python3'));
    expect(section).toContain('<<PLIST');
    const generated = Bun.spawnSync(['bash', '-eu', '-c', section], { env: { ...process.env, ipa, dir, base: 'https://fixture.invalid' } });
    expect(generated.exitCode).toBe(0);
    const page = await readFile(join(dir, 'index.html'), 'utf8');
    expect(page).toContain('1.0');
    expect(page).toContain(build);
    expect(page).toContain(`manifest-${build}.plist`);
    expect(await readFile(join(dir, `install-${build}.html`), 'utf8')).toBe(page);
    const manifest = await readFile(join(dir, `manifest-${build}.plist`), 'utf8');
    expect(manifest).toContain(`<key>bundle-version</key><string>${build}</string>`);
    expect(manifest).toContain(`https://fixture.invalid/app-${build}.ipa`);
    expect(manifest).toContain('com.example.fixture');
    expect(await readFile(join(dir, `app-${build}.ipa`))).toEqual(await readFile(ipa));
  } finally { await rm(root, { recursive: true, force: true }); }
});
