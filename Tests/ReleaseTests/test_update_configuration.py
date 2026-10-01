import sys
sys.dont_write_bytecode = True

import base64
import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("configure_updates", ROOT / "Scripts/configure-updates.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class UpdateConfigurationTests(unittest.TestCase):
    def info(self):
        return {"CFBundleIdentifier": "com.muses.app",
                "CFBundleURLTypes": [{"CFBundleURLSchemes": ["muses"]}],
                "MusesGoogleOAuthClientID": "public-client-id"}

    def env(self):
        return {"MUSES_UPDATE_PUBLIC_KEY": base64.b64encode(bytes(range(32))).decode()}

    def test_preview_has_no_feed_or_key(self):
        info = module.configure(self.info(), {})
        self.assertEqual(info["SUFeedURL"], "")
        self.assertEqual(info["SUPublicEDKey"], "")
        self.assertTrue(info["SURequireSignedFeed"])
        self.assertTrue(info["SUVerifyUpdateBeforeExtraction"])

    def test_production_uses_fixed_https_feed(self):
        info = module.configure(self.info(), self.env())
        self.assertEqual(info["SUFeedURL"], module.DEFAULT_FEED)
        self.assertFalse(info["SUEnableAutomaticChecks"])

    def test_malformed_keys_are_rejected(self):
        for key in ["not-base64", base64.b64encode(b"too short").decode()]:
            with self.assertRaises(ValueError):
                module.configure(self.info(), {"MUSES_UPDATE_PUBLIC_KEY": key})

    def test_unsafe_feeds_are_rejected(self):
        for feed in ["http://example.com/feed.xml", "https://user:secret@example.com/feed.xml",
                     "file:///tmp/feed.xml", "https:///feed.xml", "https://example.com/feed.xml#fragment"]:
            with self.assertRaises(ValueError):
                module.configure(self.info(), dict(self.env(), MUSES_UPDATE_FEED_URL=feed))

    def test_releases_require_public_key_and_developer_id(self):
        with self.assertRaises(ValueError):
            module.configure(self.info(), {"MUSES_AUTOMATIC_UPDATES_REQUIRED": "YES"})
        with self.assertRaises(ValueError):
            module.configure(self.info(), dict(self.env(), MUSES_AUTOMATIC_UPDATES_REQUIRED="YES"))
        module.configure(self.info(), dict(self.env(), MUSES_AUTOMATIC_UPDATES_REQUIRED="YES",
                                          MUSES_SIGN_IDENTITY="Developer ID Application: Test"))

    def test_acceptance_cannot_use_production_feed(self):
        with self.assertRaises(ValueError):
            module.configure(self.info(), dict(self.env(), MUSES_BUNDLE_ID="com.muses.acceptance.updates"))

    def test_acceptance_clears_oauth_and_deep_links(self):
        info = module.configure(self.info(), {"MUSES_BUNDLE_ID": "com.muses.acceptance.updates"})
        self.assertNotIn("CFBundleURLTypes", info)
        self.assertEqual(info["MusesGoogleOAuthClientID"], "")
        self.assertEqual(info["MusesGoogleOAuthClientSecret"], "")
        self.assertFalse(info["MusesWebHomeEnabled"])

    def test_signed_loopback_requires_explicit_acceptance_build(self):
        env = dict(self.env(), MUSES_UPDATE_FEED_URL="http://127.0.0.1:18765/appcast.xml",
                   MUSES_UPDATE_ACCEPTANCE_LOOPBACK="YES")
        with self.assertRaises(ValueError):
            module.configure(self.info(), env)
        info = module.configure(self.info(), dict(env, MUSES_BUNDLE_ID="com.muses.acceptance.updates"))
        self.assertTrue(info["MusesUpdateAcceptanceLoopback"])
        self.assertTrue(info["NSAppTransportSecurity"]["NSAllowsLocalNetworking"])
        with self.assertRaises(ValueError):
            module.configure(self.info(), dict(env, MUSES_BUNDLE_ID="com.muses.acceptance.updates",
                                               MUSES_UPDATE_FEED_URL="http://example.com:18765/appcast.xml"))


if __name__ == "__main__":
    unittest.main()
