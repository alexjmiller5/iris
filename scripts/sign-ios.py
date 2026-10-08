#!/usr/bin/env python3
"""Archive one iOS app and its extensions with existing Ad Hoc identities; never install or publish."""
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import tempfile
import zipfile
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from pathlib import Path


def run(*args, env=None):
    result = subprocess.run([str(a) for a in args], env=env, capture_output=True)
    if result.returncode:
        # Tool diagnostics can contain decoded signing material or device identifiers.
        raise RuntimeError(f'{args[0]} failed (exit {result.returncode}); no signing diagnostics emitted')
    return result.stdout


def validate_profile(profile, bundle, device):
    entitlements = profile.get('Entitlements', {})
    expiration = profile.get('ExpirationDate')
    teams = profile.get('TeamIdentifier', [])
    identifier = entitlements.get('application-identifier', '')
    prefix, separator, pattern = identifier.partition('.')
    bundle_matches = '*' not in bundle and (pattern == '*' or pattern == bundle or (
        pattern.endswith('.*') and '*' not in pattern[:-1] and bundle.startswith(pattern[:-1])))
    if (not separator or prefix not in profile.get('ApplicationIdentifierPrefix', [])
            or not bundle_matches):
        raise ValueError('Profile does not authorize the app bundle')
    if (len(teams) != 1 or entitlements.get('com.apple.developer.team-identifier') != teams[0]
            or not re.fullmatch(r'[A-Za-z0-9-]+', profile.get('UUID', ''))):
        raise ValueError('Invalid profile team or UUID')
    if (not isinstance(expiration, datetime)
            or expiration.replace(tzinfo=timezone.utc) <= datetime.now(timezone.utc)):
        raise ValueError('Profile is expired or lacks an expiration')
    if (not profile.get('ProvisionedDevices') or profile.get('ProvisionsAllDevices')
            or entitlements.get('get-task-allow') is not False
            or not profile.get('DeveloperCertificates')):
        raise ValueError('An Ad Hoc distribution profile with certificates and devices is required')
    if device and device not in profile['ProvisionedDevices']:
        raise ValueError('Profile does not include the selected device')
    return teams[0], profile['UUID']


def identity_for_profile(keychain, profile):
    allowed = {hashlib.sha1(cert).hexdigest().upper() for cert in profile['DeveloperCertificates']}
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning', keychain).decode()
    for fingerprint in re.findall(r'([A-Fa-f0-9]{40}) "(?:Apple|iPhone) Distribution:[^"]+"', identities):
        if fingerprint.upper() in allowed:
            return fingerprint.upper()
    raise ValueError('No valid distribution private-key identity matches the profile')


def target_entitlements(settings):
    """A target's declared entitlements with $(SETTING) references resolved; unknown fails."""
    path = settings.get('CODE_SIGN_ENTITLEMENTS')
    if not path:
        return {}
    declared = plistlib.loads((Path(settings['PROJECT_DIR']) / path).read_bytes())

    def expand(value):
        if isinstance(value, list):
            return [expand(entry) for entry in value]
        if isinstance(value, str):
            return re.sub(r'\$[({](\w+)[)}]', lambda match: settings[match.group(1)], value)
        return value
    return {key: expand(value) for key, value in declared.items()}


def profile_setting(app_bundle, bundle):
    """Build setting naming a target's profile: IOS_PROFILE, or IOS_<SUFFIX>_PROFILE for
    an extension `<app>.<suffix>`; project.yml references the same names."""
    if bundle == app_bundle:
        return 'IOS_PROFILE'
    suffix = bundle.removeprefix(app_bundle + '.')
    if suffix == bundle or not re.fullmatch(r'[A-Za-z0-9-]+', suffix):
        raise ValueError('Extension bundle must be a direct child of the app bundle')
    return f"IOS_{suffix.upper().replace('-', '_')}_PROFILE"


def profiles_for_targets(bundles, profiles):
    """Exactly one explicit (non-wildcard) profile per target and none left over."""
    selected = {}
    for profile in profiles:
        identifier = profile.get('Entitlements', {}).get('application-identifier', '')
        bundle = identifier.partition('.')[2]
        if bundle not in bundles or bundle in selected:
            raise ValueError('Each signing profile must authorize exactly one distinct target')
        selected[bundle] = profile
    if set(selected) != set(bundles):
        raise ValueError('Every app and extension target needs its own signing profile')
    return selected


def validate_profile_set(profiles, device, required_groups):
    """Every embedded executable needs its own validated capability grant."""
    if not profiles or (len(profiles) > 1 and not required_groups):
        raise ValueError('Embedded targets require an explicit shared App Group')
    if any(not isinstance(group, str) or not group.startswith('group.') or '*' in group
           for group in required_groups):
        raise ValueError('Invalid required App Group')
    team = None
    certificates = None
    for bundle, profile in profiles.items():
        candidate, _ = validate_profile(profile, bundle, device)
        if team is not None and candidate != team:
            raise ValueError('Embedded targets must use the same team')
        team = candidate
        entitlements = profile['Entitlements']
        if required_groups:
            identifier = entitlements['application-identifier']
            if '*' in identifier or any(
                    group not in entitlements.get('com.apple.security.application-groups', [])
                    for group in required_groups):
                raise ValueError('Explicit bundle profiles must authorize the shared App Group')
        allowed = profile['DeveloperCertificates']
        certificates = (list(allowed) if certificates is None else
                        [certificate for certificate in certificates if certificate in allowed])
    if not certificates:
        raise ValueError('No distribution certificate is shared by every target profile')
    return team, certificates


@contextmanager
def signing_material(p12, password, profile_files, profiles):
    original = shlex.split(run('security', 'list-keychains', '-d', 'user').decode())
    with tempfile.TemporaryDirectory(prefix='ios-signing-') as temporary, ExitStack() as cleanup:
        root = Path(temporary)
        keychain = root / 'signing.keychain-db'
        certificate = root / 'certificate.p12'
        certificate.write_bytes(p12)
        certificate.chmod(0o600)
        key_password = secrets.token_urlsafe(32)
        run('security', 'create-keychain', '-p', key_password, keychain)
        cleanup.callback(run, 'security', 'delete-keychain', keychain)
        cleanup.callback(run, 'security', 'list-keychains', '-d', 'user', '-s', *original)
        run('security', 'set-keychain-settings', '-lut', '21600', keychain)
        run('security', 'unlock-keychain', '-p', key_password, keychain)
        run('security', 'import', certificate, '-P', password, '-A', '-t', 'cert', '-f', 'pkcs12', '-k', keychain)
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-k', key_password, keychain)
        run('security', 'list-keychains', '-d', 'user', '-s', keychain, *original)
        profiles.mkdir(parents=True, exist_ok=True)
        for uuid, profile_bytes in profile_files.items():
            installed = profiles / f'{uuid}.mobileprovision'
            with installed.open('xb') as stream:
                cleanup.callback(installed.unlink)
                installed.chmod(0o600)
                stream.write(profile_bytes)
        yield keychain


def validate_entitlements(signed, authorized):
    """Accept scalar claims and arrays authorized by the profile; reject other shapes."""
    def permits(value, grant):
        if type(value) is not type(grant):
            return False
        if isinstance(value, str):
            if '*' in value:
                return False
            return value == grant or (grant.endswith('*') and '*' not in grant[:-1]
                                      and value.startswith(grant[:-1]))
        if isinstance(value, bool):
            return value == grant
        if isinstance(value, list):
            return all(any(permits(entry, allowed) for allowed in grant) for entry in value)
        return False

    for key, value in signed.items():
        if key not in authorized or not permits(value, authorized[key]):
            raise ValueError('Exported entitlement is unauthorized or unsupported')


def extract_certificate(app, prefix):
    run('codesign', '-d', f'--extract-certificates={prefix}', app)
    certificate = Path(str(prefix) + '0')
    run('openssl', 'x509', '-inform', 'DER', '-in', certificate, '-checkend', '0', '-noout')
    return certificate.read_bytes()


def verify_app(app, bundle, team, fingerprint, device, expected_uuid=None):
    if plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier'] != bundle:
        raise ValueError('Exported bundle identifier changed')
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', app / 'embedded.mobileprovision'))
    actual_team, actual_uuid = validate_profile(profile, bundle, device)
    if actual_team != team or (expected_uuid and actual_uuid != expected_uuid):
        raise ValueError('Exported team or provisioning profile changed')
    run('codesign', '--verify', '--deep', '--strict', app)
    entitlements = plistlib.loads(run('codesign', '-d', '--entitlements', ':-', app))
    prefix = profile['Entitlements']['application-identifier'].partition('.')[0]
    if (entitlements.get('application-identifier') != f'{prefix}.{bundle}'
            or entitlements.get('com.apple.developer.team-identifier') != team
            or entitlements.get('get-task-allow', False) is not False):
        raise ValueError('Exported signing entitlements do not match distribution identity')
    validate_entitlements(entitlements, profile['Entitlements'])
    with tempfile.TemporaryDirectory(prefix='ios-cert-') as temporary:
        certificate = extract_certificate(app, Path(temporary) / 'certificate')
        if (hashlib.sha1(certificate).hexdigest().upper() != fingerprint
                or certificate not in profile['DeveloperCertificates']):
            raise ValueError('Exported leaf certificate is not the selected profile identity')
    return entitlements


def verify_app_tree(app, bundle, team, fingerprint, device, expected_profiles, required_groups,
                    declared=None):
    """Verify every extension individually; --deep alone does not prove its claims."""
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    versions = (info.get('CFBundleShortVersionString'), info.get('CFBundleVersion'))
    if not all(isinstance(version, str) and version for version in versions):
        raise ValueError('App version metadata is missing')
    targets = {bundle: app}
    for extension in app.rglob('*.appex'):
        if extension.is_symlink() or extension.parent != app / 'PlugIns':
            raise ValueError('Unsupported embedded extension placement')
        metadata = plistlib.loads((extension / 'Info.plist').read_bytes())
        identifier = metadata.get('CFBundleIdentifier')
        if (not isinstance(identifier, str) or not identifier.startswith(bundle + '.')
                or identifier in targets):
            raise ValueError('Unexpected embedded bundle identity')
        if (metadata.get('CFBundleShortVersionString'), metadata.get('CFBundleVersion')) != versions:
            raise ValueError('App and extension versions differ')
        targets[identifier] = extension
    if set(targets) != set(expected_profiles):
        raise ValueError('Exported embedded targets do not match the signing profiles')
    if len(targets) > 1 and not required_groups:
        raise ValueError('Embedded targets require an explicit shared App Group')
    for identifier, target in targets.items():
        entitlements = verify_app(target, identifier, team, fingerprint, device,
                                  expected_profiles[identifier])
        groups = entitlements.get('com.apple.security.application-groups', [])
        if set(groups) != set(required_groups):
            raise ValueError('App and extension App Groups do not match the required grant')
        for key, value in (declared or {}).get(identifier, {}).items():
            if entitlements.get(key) != value:
                raise ValueError('Exported target lost a declared entitlement')


def build(project, scheme, output):
    p12 = base64.b64decode(os.environ['IOS_CERTIFICATE_P12_BASE64'], validate=True)
    password = os.environ['IOS_CERTIFICATE_PASSWORD']
    # The app profile first, then one explicit profile per embedded extension.
    encoded = [os.environ['IOS_PROFILE_BASE64'], *os.environ.get('IOS_EXTENSION_PROFILES_BASE64', '').split()]
    device = os.environ.get('IOS_DEVICE_ID') or None
    base = ['xcodebuild', '-project', project, '-scheme', scheme, '-configuration', 'Release']
    settings = json.loads(run(*base, '-sdk', 'iphoneos', '-showBuildSettings', '-json'))
    targets = [entry['buildSettings'] for entry in settings
               if entry['buildSettings'].get('WRAPPER_EXTENSION') in ('app', 'appex')]
    apps = [target for target in targets if target['WRAPPER_EXTENSION'] == 'app']
    if len(apps) != 1:
        raise ValueError('Exactly one application target is supported')
    bundle = apps[0]['PRODUCT_BUNDLE_IDENTIFIER']
    declared = {target['PRODUCT_BUNDLE_IDENTIFIER']: target_entitlements(target) for target in targets}
    groups = {tuple(sorted(entitlements.get('com.apple.security.application-groups', [])))
              for entitlements in declared.values()}
    if len(declared) != len(targets) or len(groups) != 1:
        raise ValueError('App and extensions need distinct bundles and one shared App Group set')
    required_groups = list(groups.pop())
    with tempfile.TemporaryDirectory(prefix='ios-archive-') as temporary:
        root = Path(temporary)
        decoded = []
        for index, value in enumerate(encoded):
            data = base64.b64decode(value, validate=True)
            source = root / f'source-{index}.mobileprovision'
            source.write_bytes(data)
            decoded.append((plistlib.loads(run('security', 'cms', '-D', '-i', source)), data))
        selected = profiles_for_targets(list(declared), [profile for profile, _ in decoded])
        team, certificates = validate_profile_set(selected, device, required_groups)
        for target, profile in selected.items():
            # Declared capabilities (push, App Groups) must be granted, not silently dropped.
            validate_entitlements(declared[target], profile['Entitlements'])
        uuids = {target: profile['UUID'] for target, profile in selected.items()}
        profiles = Path.home() / 'Library/Developer/Xcode/UserData/Provisioning Profiles'
        files = {profile['UUID']: data for profile, data in decoded}
        with signing_material(p12, password, files, profiles) as keychain:
            fingerprint = identity_for_profile(keychain, {'DeveloperCertificates': certificates})
            # project.yml references IOS_PROFILE on the app and IOS_<SUFFIX>_PROFILE on extensions.
            names = {profile_setting(bundle, target): uuid for target, uuid in uuids.items()}
            env = dict(os.environ, **names)
            archive = root / 'App.xcarchive'
            run(*base, '-destination', 'generic/platform=iOS', '-archivePath', archive,
                '-derivedDataPath', root / 'DerivedData', 'CODE_SIGN_STYLE=Manual',
                f'DEVELOPMENT_TEAM={team}', f'CODE_SIGN_IDENTITY={fingerprint}',
                *(f'{name}={uuid}' for name, uuid in names.items()),
                f'OTHER_CODE_SIGN_FLAGS=--keychain {shlex.quote(str(keychain))}', 'archive', env=env)
            export_options = root / 'ExportOptions.plist'
            export_options.write_bytes(plistlib.dumps({
                'method': 'release-testing', 'signingStyle': 'manual', 'teamID': team,
                'signingCertificate': fingerprint, 'provisioningProfiles': uuids,
                'manageAppVersionAndBuildNumber': False,
            }))
            exported = root / 'export'
            run('xcodebuild', '-exportArchive', '-archivePath', archive,
                '-exportOptionsPlist', export_options, '-exportPath', exported)
            ipas = list(exported.glob('*.ipa'))
            if len(ipas) != 1:
                raise ValueError('Expected exactly one exported IPA')
            extracted = root / 'extracted'
            with zipfile.ZipFile(ipas[0]) as ipa:
                if any(Path(n).is_absolute() or '..' in Path(n).parts for n in ipa.namelist()):
                    raise ValueError('Unsafe exported IPA path')
            run('ditto', '-x', '-k', ipas[0], extracted)
            apps = list((extracted / 'Payload').glob('*.app'))
            if len(apps) != 1:
                raise ValueError('Expected exactly one exported app')
            verify_app_tree(apps[0], bundle, team, fingerprint, device, uuids, required_groups, declared)
            output = Path(output)
            output.mkdir(parents=True, exist_ok=True)
            destination = output / 'App.ipa'
            if destination.exists():
                raise FileExistsError('Refusing to overwrite an existing IPA')
            shutil.copyfile(ipas[0], destination)
            destination.chmod(0o600)
    print('Verified Ad Hoc IPA written; signing material cleaned up.')
    print('IPA SHA256: ' + hashlib.sha256(destination.read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', required=True)
    parser.add_argument('--scheme', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit(143)))
    try:
        build(args.project, args.scheme, args.output)
    except (KeyError, ValueError, RuntimeError, OSError) as error:
        # Do not stringify arbitrary subprocess exceptions or their secret-bearing argv.
        print(f'Signing failed: {type(error).__name__}. No signing material published.', file=__import__('sys').stderr)
        raise SystemExit(1) from None


if __name__ == '__main__':
    main()
