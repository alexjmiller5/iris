"""Verify final distribution signing and private Data Protection identity."""
import datetime
import fnmatch
import hashlib
import plistlib
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def verify_claims(claims, profile, team, bundle, certificate):
    def require(condition, message):
        if not condition:
            raise ValueError(message)

    prefix = profile.get("ApplicationIdentifierPrefix", [])
    require(len(prefix) == 1, "Profile must have one App ID prefix")
    app_id = prefix[0] + "." + bundle
    require(claims == {
        "com.apple.application-identifier": app_id,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.aps-environment": "production",
    }, "App must claim only its profile-backed private identity and production push entitlement")
    require(profile.get("TeamIdentifier") == [team], "Profile team mismatch")
    require(profile.get("Platform") == ["OSX"], "Profile is not for macOS")
    require(profile.get("ProvisionsAllDevices") is True, "Profile is not direct distribution")
    require(profile.get("ExpirationDate", datetime.datetime.min) > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), "Profile expired")
    require(certificate in profile.get("DeveloperCertificates", []), "Profile does not authorize signing certificate")
    allowed = profile.get("Entitlements", {})
    require(allowed.get("com.apple.developer.aps-environment") == "production", "Profile must authorize production Apple push")
    require(allowed.get("com.apple.developer.team-identifier") == team, "Profile entitlement team mismatch")
    require(fnmatch.fnmatchcase(app_id, allowed.get("com.apple.application-identifier", "")), "Profile does not authorize app ID")
    require(not allowed.get("get-task-allow") and not allowed.get("com.apple.security.get-task-allow"), "Development profile is not distributable")



def read_claims(app):
    for arch in ("arm64", "x86_64"):
        claims = plistlib.loads(subprocess.check_output([
            "codesign", "-d", "--arch", arch, "--entitlements", "-", "--xml", str(app)
        ], stderr=subprocess.DEVNULL))
        yield arch, claims



def extract_certificate(app, arch):
    with tempfile.TemporaryDirectory(prefix="iris-certificate-") as scratch:
        prefix = str(Path(scratch) / "certificate")
        subprocess.run(["codesign", "-d", "--arch", arch, "--extract-certificates=" + prefix, str(app)], check=True, capture_output=True)
        return Path(prefix + "0").read_bytes()


def main(app, expected_team, expected_certificate_sha1):
    app = Path(app)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    profile = plistlib.loads(subprocess.check_output([
        "security", "cms", "-D", "-i", str(app / "Contents/embedded.provisionprofile")
    ], stderr=subprocess.DEVNULL))
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    for arch, claims in read_claims(app):
        details = subprocess.run(["codesign", "-d", "--verbose=4", "--arch", arch, str(app)], check=True, capture_output=True, text=True).stderr
        if not re.search(r"^TeamIdentifier=" + re.escape(expected_team) + r"$", details, re.M):
            raise ValueError("Signed team does not match selected distribution identity")
        certificate = extract_certificate(app, arch)
        if hashlib.sha1(certificate).hexdigest().upper() != expected_certificate_sha1.upper():
            raise ValueError("Export did not use the selected existing certificate")
        verify_claims(claims, profile, expected_team, info["CFBundleIdentifier"], certificate)
    print("Both app architectures have profile-authorized private Keychain identity")


if __name__ == "__main__":
    main(*sys.argv[1:])
