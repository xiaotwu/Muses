#!/usr/bin/env python3
"""Inject public update configuration; never read or write signing private keys."""
import base64
import os
import plistlib
from pathlib import Path
from urllib.parse import urlsplit

DEFAULT_FEED = "https://github.com/xiaotwu/Muses-Polyhymnia/releases/download/updates/appcast.xml"


def configure(info, env):
    key = env.get("MUSES_UPDATE_PUBLIC_KEY", "").strip()
    required = env.get("MUSES_AUTOMATIC_UPDATES_REQUIRED") == "YES"
    feed = env.get("MUSES_UPDATE_FEED_URL", DEFAULT_FEED if key else "")
    bundle_id = env.get("MUSES_BUNDLE_ID", info["CFBundleIdentifier"])
    acceptance = bundle_id.startswith("com.muses.acceptance.")
    if bundle_id != "com.muses.app" and not acceptance:
        raise ValueError("Unsupported application bundle identifier")
    loopback = acceptance and env.get("MUSES_UPDATE_ACCEPTANCE_LOOPBACK") == "YES"
    if key:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError("MUSES_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key")
        url = urlsplit(feed)
        local = loopback and url.scheme == "http" and url.hostname == "127.0.0.1" and url.port is not None
        if (url.scheme != "https" and not local) or not url.hostname or url.username or url.password or url.fragment:
            raise ValueError("Update feeds require an HTTPS URL without credentials or fragments")
        if acceptance and feed == DEFAULT_FEED:
            raise ValueError("Acceptance bundles cannot use the production feed")
    elif required:
        raise ValueError("A release requires MUSES_UPDATE_PUBLIC_KEY")
    if required and not env.get("MUSES_SIGN_IDENTITY", "").startswith("Developer ID Application:"):
        raise ValueError("A release requires a Developer ID Application identity")
    info.update(SUFeedURL=feed if key else "", SUPublicEDKey=key,
                SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                SUEnableAutomaticChecks=False, SUAutomaticallyUpdate=False,
                SUScheduledCheckInterval=86400)
    info["CFBundleIdentifier"] = bundle_id
    info["MusesUpdateAcceptanceLoopback"] = loopback
    if loopback:
        info["NSAppTransportSecurity"] = {"NSAllowsLocalNetworking": True}
    if acceptance:
        info.pop("CFBundleURLTypes", None)
        info["MusesGoogleOAuthClientID"] = ""
        info["MusesGoogleOAuthClientSecret"] = ""
        info["MusesWebHomeEnabled"] = False
    return info


if __name__ == "__main__":
    path = Path(os.environ["MUSES_BUNDLE_PATH"]) / "Contents/Info.plist"
    with path.open("rb") as source:
        info = plistlib.load(source)
    info = configure(info, os.environ)
    with path.open("wb") as destination:
        plistlib.dump(info, destination)
