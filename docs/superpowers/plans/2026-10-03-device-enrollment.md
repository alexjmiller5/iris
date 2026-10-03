# Device enrollment implementation plan

> **For agentic workers:** Use the executing-plans or subagent-driven-development skill. Implement each task with failing behavioral tests first, then the host and actual service checks.

**Goal:** Connect browser, macOS and iOS clients using the hub's existing device approval flow.

**Architecture:** The generated core operations own approval paths, response interpretation and replica eligibility. Platform hosts own random generation, hashing, HTTP, cancellation, deadlines and credential storage. The hub owns approval and revocation; no new service endpoints are required.

**Tech stack:** Shared TypeScript core, Svelte, SwiftUI/JavaScriptCore, Web Crypto/CryptoKit and native Keychain.

**Spec:** This document specifies the host integration of the core enrollment contract and its canonical enrollment-policy fixture.

## Required behavior

- The app shall generate a fresh `lt_` token from 24 cryptographically random bytes and send only its SHA-256 fingerprint in the approval URL.
- The app shall display the approval code and open an explicit approval link. It shall use the generated core path and fixed `/v1/session` transport, never a credential in a URL.
- When a session is approved, the app shall require exact candidate identity and `session.replica.allowed` before installing the connection. New manually entered tokens shall use the same session validation, including admin rejection.
- While waiting, the host shall apply the core polling delay and a monotonic deadline. Cancel, timeout, workspace changes and a replacement attempt shall invalidate late responses.
- The browser shall hold the token in memory only. Native installation shall use Keychain, and a failed installation shall attempt revocation without claiming success unless the core confirms it.
- Reopening an established native replica shall remain usable offline. A transient session check failure shall not erase the saved connection or local rows. Reconnecting with a new credential requires successful validation.
- Cancellation shall attempt cleanup for the generated candidate only. A 401 means unauthorized, not revoked; the UI shall explain that an approval link may still need cancellation/revocation through the hub if approved later.
- The transport shall return typed HTTP status and bounded JSON, omit cookies, refuse redirects, use sanitized failures, and never forward a bearer token to a different endpoint.
- A capped deployment shall still permit enrollment and show its usage/notifications. No client fallback shall evade the cap.

## Review focus

- Late approval after cancel or after switching workspace must never install a token.
- Manual root/admin or table-restricted credentials must not become replica credentials.
- Keychain/storage failure must preserve the old connection and explain candidate cleanup accurately.
- Offline reopen must retain local access; failed validation of a new credential must preserve the established connection.
- Browser popup restrictions, narrow layouts and keyboard navigation must leave an explicit usable approval link and Cancel control.

## Task 1: Browser approval and typed transport

- [ ] Write tests for secure token generation, fixed session transport and bounded typed replies, using the existing core policy rather than a second validator.
- [ ] Write model/component tests for polling, retry delay, deadline, cancellation, replacement, failed validation and session-only installation.
- [ ] Implement the host and connection UI. Keep manual token entry as an explicit alternative and preserve current download controls.
- [ ] Run an end-to-end synthetic actual Worker approval flow with disposable auth state, including revoked/admin/restricted tokens and stale approval responses. Synthetic manual fixture tokens must be dedicated full-scope tokens, not the operator root.
- [ ] Verify current connection preservation, no credentials in URLs/storage/logs, keyboard/narrow layout and mutation sensitivity. Run the full web suite, checks, lint and build; commit and push the isolated branch for integration.

## Task 2: Native enrollment

- [ ] Write native host tests for token generation, typed bounded session transport, core fixture parity, deadlines and late callbacks.
- [ ] Add approval UI to the shared connection screen and use supported system URL opening. Keep platform-specific code limited to transport, secure storage and presentation.
- [ ] Validate new credentials before replacing Keychain/current workspace. Keep established replica reopening offline and isolate state by deployment.
- [ ] Exercise failed Keychain installation and cleanup outcomes, cancellation, reopen and real JavaScriptCore policy calls.
- [ ] Run macOS/iOS host tests, actual simulator approval flow, mutation checks and Release artifact verification. Preserve evidence and commit all integrated changes.

## Task 3: Integration and documentation

- [ ] Regenerate the shared contract and bundles once from the reviewed core source when native builds are idle. Both hosts must consume that exact contract.
- [ ] Re-run existing sync/cap/notification flows with dedicated synthetic device credentials.
- [ ] Document enrollment, offline reopen, forgetting versus revoking a device, and replacement-machine enrollment in README and current contracts in AGENTS.md.
- [ ] Verify CI and update the existing enrollment task. Live approval, signing and deployment remain separate owner actions.
