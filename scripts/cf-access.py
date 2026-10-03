#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = ["httpx"]
# ///
"""Idempotent Cloudflare Access provisioner (declarative-via-script).

Puts Access in front of a private site. The desired state reads straight off
the invocation - re-running converges, it never duplicates:

  scripts/cf-access.py --name <site> --domain dash.example.com --email you@example.com

Common extras:

  --domain '*-<site>.<subdomain>.workers.dev'   also protect Workers preview URLs
  --email  ross@example.com                     repeat for each person allowed
  --pwa                                         second BYPASS app for the icon/
                                                manifest paths iOS fetches without
                                                cookies (else the homescreen icon
                                                degrades to a letter monogram)
  --public-path /api/foo                        more cookie-less paths for that
                                                bypass app (repeatable) - e.g. a
                                                machine-polled status flag
  --service-token <name>                        let a machine caller through with
                                                an Access service token: created
                                                once (client secret printed ONCE -
                                                store it), then attached to the
                                                app as a non_identity policy
  --dry-run                                     print the plan, change nothing

Login is the Cloudflare identity provider (sign in with the Cloudflare account);
with a single allowed IdP the login-method chooser is skipped, so an already
signed-in browser lands on the site directly. Sessions last a month by default.

Auth: CLOUDFLARE_API_TOKEN env var if set (needs Account > Access: Apps and
Policies > Edit), else the AI Agent Cloudflare API key from 1Password (by ID).
Account: CLOUDFLARE_ACCOUNT_ID env var, else the token's sole visible account.
"""

import argparse
import json
import os
import subprocess
import sys

import httpx

API = "https://api.cloudflare.com/client/v4"
OP_TOKEN_REF = "op://4eeyrkqibibn7k4j6rz2fbzvxm/mxxpo6neiz3grdyrjj7rv7nume/credential"

# Fetched without cookies by iOS/browsers, so they can't sit behind a login.
# Non-sensitive by nature - everything else on the host stays protected.
PWA_PUBLIC_PATHS = [
    "/apple-touch-icon.png",
    "/icon-192.png",
    "/icon-512.png",
    "/favicon.svg",
    "/manifest.webmanifest",
]


def api_token() -> str:
    if tok := os.environ.get("CLOUDFLARE_API_TOKEN"):
        return tok
    return subprocess.run(
        ["op", "read", OP_TOKEN_REF], capture_output=True, text=True, check=True
    ).stdout.strip()


def unwrap(r: httpx.Response) -> dict | list:
    r.raise_for_status()
    body = r.json()
    if not body.get("success"):
        sys.exit(f"Cloudflare API error: {body.get('errors')}")
    return body["result"]


def desired_app(name: str, uris: list[str], session: str, idp: str, *policies: dict) -> dict:
    """The full app body we want Cloudflare to hold. Pure - safe to diff/print."""
    return {
        "name": name,
        "type": "self_hosted",
        "destinations": [{"type": "public", "uri": u} for u in uris],
        "session_duration": session,
        "allowed_idps": [idp],
        # One allowed IdP means there is nothing to choose - skip the chooser.
        "auto_redirect_to_identity": True,
        "app_launcher_visible": True,
        "policies": list(policies),
    }


def drifted(want: dict, have: dict) -> bool:
    """True if Cloudflare's copy differs from what we want, on the fields we own."""
    for k in ("name", "session_duration", "allowed_idps", "auto_redirect_to_identity"):
        if want[k] != have.get(k):
            return True
    if [d["uri"] for d in want["destinations"]] != [
        d["uri"] for d in have.get("destinations") or []
    ]:
        return True
    return [(p["decision"], p["include"]) for p in want["policies"]] != [
        (p.get("decision"), p.get("include")) for p in have.get("policies") or []
    ]


def service_token_policy(c: httpx.Client, account: str, name: str, dry_run: bool) -> dict:
    """Find or create the named Access service token; return its non_identity
    policy. The client secret is only readable at creation - it is printed once,
    on stderr, for the caller to store (1Password)."""
    tokens = unwrap(c.get(f"{API}/accounts/{account}/access/service_tokens", params={"per_page": 100}))
    tok = next((t for t in tokens if t["name"] == name), None)
    if tok is None:
        if dry_run:
            print(f"WOULD CREATE service token '{name}'")
            tok = {"id": "<pending>"}
        else:
            tok = unwrap(
                c.post(
                    f"{API}/accounts/{account}/access/service_tokens",
                    json={"name": name, "duration": "87600h"},
                )
            )
            print(f"created service token '{name}' - store these now, the secret is shown ONCE:", file=sys.stderr)
            print(json.dumps({"clientId": tok["client_id"], "clientSecret": tok["client_secret"]}))
    else:
        print(f"service token '{name}' exists (client id {tok['client_id']})", file=sys.stderr)
    return {
        "name": f"{name} - service token",
        "decision": "non_identity",
        "include": [{"service_token": {"token_id": tok["id"]}}],
    }


def upsert(c: httpx.Client, account: str, apps: list, want: dict, dry_run: bool) -> None:
    existing = next((a for a in apps if a["name"] == want["name"]), None)
    uris = [d["uri"] for d in want["destinations"]]

    if existing is None:
        if dry_run:
            print(f"WOULD CREATE '{want['name']}' -> {uris}")
            return
        unwrap(c.post(f"{API}/accounts/{account}/access/apps", json=want))
        print(f"created '{want['name']}' -> {uris}")
    elif drifted(want, existing):
        if dry_run:
            print(f"WOULD UPDATE '{want['name']}' -> {uris}")
            return
        unwrap(c.put(f"{API}/accounts/{account}/access/apps/{existing['id']}", json=want))
        print(f"updated '{want['name']}' -> {uris}")
    else:
        print(f"'{want['name']}' already converged")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--name", required=True, help="app name (use the project slug)")
    ap.add_argument("--domain", action="append", required=True, dest="domains")
    ap.add_argument("--email", action="append", required=True, dest="emails")
    ap.add_argument("--session", default="730h", help="session duration (default 1 month)")
    ap.add_argument("--pwa", action="store_true", help="also bypass the cookie-less PWA assets")
    ap.add_argument("--public-path", action="append", default=[], dest="public_paths")
    ap.add_argument("--service-token", help="name of an Access service token to admit")
    ap.add_argument("--idp", default="cloudflare", help="IdP type: cloudflare or onetimepin")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, change nothing")
    args = ap.parse_args()

    c = httpx.Client(headers={"Authorization": f"Bearer {api_token()}"}, timeout=30)

    account = os.environ.get("CLOUDFLARE_ACCOUNT_ID")
    if not account:
        accounts = unwrap(c.get(f"{API}/accounts"))
        if len(accounts) != 1:
            sys.exit("Multiple accounts visible - set CLOUDFLARE_ACCOUNT_ID")
        account = accounts[0]["id"]

    # IdP ids are per-account, so look ours up by type rather than hardcoding it.
    idps = unwrap(c.get(f"{API}/accounts/{account}/access/identity_providers"))
    idp = next((i["id"] for i in idps if i["type"] == args.idp), None)
    if idp is None:
        sys.exit(f"No '{args.idp}' identity provider on this account: {[i['type'] for i in idps]}")

    apps = unwrap(c.get(f"{API}/accounts/{account}/access/apps", params={"per_page": 100}))

    policies = [
        {
            "name": f"{args.name} - allowed people",
            "decision": "allow",
            "include": [{"email": {"email": e}} for e in args.emails],
        }
    ]
    if args.service_token:
        policies.append(service_token_policy(c, account, args.service_token, args.dry_run))

    upsert(
        c,
        account,
        apps,
        desired_app(args.name, args.domains, args.session, idp, *policies),
        args.dry_run,
    )

    public_paths = (PWA_PUBLIC_PATHS if args.pwa else []) + args.public_paths
    if public_paths:
        upsert(
            c,
            account,
            apps,
            desired_app(
                f"{args.name} - public assets",
                [d + p for d in args.domains for p in public_paths],
                args.session,
                idp,
                {
                    "name": f"{args.name} - public assets bypass",
                    "decision": "bypass",
                    "include": [{"everyone": {}}],
                },
            ),
            args.dry_run,
        )
    if args.pwa:
        print('PWA: set crossorigin="use-credentials" on the manifest <link>, then')
        print("     delete + re-add the homescreen app (iOS caches the icon at add-time)")


if __name__ == "__main__":
    main()
