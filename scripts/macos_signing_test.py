"""Release claims must be authorized by the app's distribution profile."""
import copy
import datetime
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "signing", Path(__file__).with_name("verify-macos-signing.py")
)
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.team = "TEAM000001"
        self.bundle = "org.example.fixture"
        # App ID prefixes need not equal team IDs.
        self.claims = {
            "com.apple.application-identifier": "PREFIX0001.org.example.fixture",
            "com.apple.developer.team-identifier": self.team,
        }
        self.profile = {
            "ExpirationDate": datetime.datetime(2099, 1, 1),
            "Platform": ["OSX"],
            "ProvisionsAllDevices": True,
            "TeamIdentifier": [self.team],
            "ApplicationIdentifierPrefix": ["PREFIX0001"],
            "DeveloperCertificates": [b"fixture-certificate"],
            "Entitlements": {
                **self.claims,
                "keychain-access-groups": ["PREFIX0001.*"],
            },
        }

    def verify(self):
        signing.verify_claims(
            self.claims, self.profile, self.team, self.bundle, b"fixture-certificate"
        )

    def test_private_identity_accepts_distinct_profile_prefix(self):
        self.verify()

    def test_missing_or_changed_identity_rejected(self):
        for key in list(self.claims):
            with self.subTest(key=key):
                saved = self.claims.pop(key)
                with self.assertRaises(ValueError):
                    self.verify()
                self.claims[key] = "WRONG"
                with self.assertRaises(ValueError):
                    self.verify()
                self.claims[key] = saved

    def test_shared_group_and_debug_claims_rejected(self):
        for key, value in [
            ("keychain-access-groups", ["PREFIX0001.*"]),
            ("com.apple.security.application-groups", ["group.fixture"]),
            ("com.apple.security.get-task-allow", True),
        ]:
            with self.subTest(key=key):
                self.claims[key] = value
                with self.assertRaises(ValueError):
                    self.verify()
                del self.claims[key]

    def test_wrong_profile_rejected(self):
        original = copy.deepcopy(self.profile)
        for key, value in [
            ("ExpirationDate", datetime.datetime(2000, 1, 1)),
            ("DeveloperCertificates", [b"different-cert"]),
            ("ApplicationIdentifierPrefix", [self.team]),
            ("TeamIdentifier", ["OTHERTEAM1"]),
            ("ProvisionsAllDevices", False),
            ("Platform", ["iOS"]),
            ("Entitlements", {**self.claims, "com.apple.application-identifier": "PREFIX0001.other.app"}),
        ]:
            with self.subTest(key=key):
                self.profile = {**original, key: value}
                with self.assertRaises(ValueError):
                    self.verify()


if __name__ == "__main__":
    unittest.main()
