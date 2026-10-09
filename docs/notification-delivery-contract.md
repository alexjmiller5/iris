# Notification delivery contract

The inbox feed and shared read acknowledgements belong to Soma. Iris
owns permission handling and presentation. This document specifies the compact
transport identity and the integration requirements for Apple push delivery.
Native apps register through the canonical service capability and platform token
callbacks. Local alert identifiers and checkpoints remain separate from APNs.

## Event identity

The original opaque `event.id` and deployment identify an event. `event.seq`
orders the feed; it is not a read, deduplication or delivery identity. Compare
IDs by their exact UTF-8 bytes, without Unicode normalization. Never mark an
event read using its transport hash.

The compact transport key is:

```javascript
base64urlWithoutPadding(
  SHA256(utf8(JSON.stringify([
    "life-notification-v1", deploymentIdentity, exactEventId
  ])))
)
```

This produces exactly 43 ASCII bytes, below APNs' 64-byte collapse-ID limit.
The tuple uses ECMAScript `JSON.stringify` encoding: no spaces or slash
escaping, JSON escapes for quotes/backslashes/control characters, scalar UTF-8
for other characters, and no Unicode normalization. Inputs are Unicode scalar
strings. Tuple framing separates `("a", "bc")` from `("ab", "c")`.
The deployment identity is the service's canonical identity, not an arbitrary
caller-provided URL alias. Do not invent a new deployment identity in the client.

`NotificationDeliveryIdentity.collapseKey` is the isolated Swift implementation.
`NotificationDeliveryIdentityTests` pins independently generated JavaScript
golden vectors for slashes, quote/backslash/control characters, emoji, composed
and decomposed strings, tuple framing and line/paragraph separators. Tests also
execute ECMAScript encoding in JavaScriptCore. The implementation is not wired
into existing local notification IDs; that change requires a checkpoint and
pending-request compatibility plan.

Tokens, topics, environments, installation IDs and token generations are
excluded from the event key. Token rotation preserves an event's key. A
subscription delivery receipt additionally includes its installation-subscription
ID, so delivery to one installation never acknowledges another installation.
APNs collapse behavior is not a durable receipt or a substitute for deduplication.

## Registration and lifecycle requirements

The service API owner supplies registration and delivery retry persistence.
There is no second client registration store, schema or writer in this change.
The canonical API and client lifecycle use these requirements:

| Trigger | Required behavior |
| --- | --- |
| Installation registration | Authenticate using the existing device session. Derive principal and deployment from that session; caller-supplied values are not authority. |
| Topic/environment selection | Validate against service-owned app configuration and the signed app's environment. Do not accept arbitrary provider destinations from a client. |
| APNs token callback | Treat token bytes as opaque and replaceable. Bind the current generation to that installation subscription. Do not put tokens in event payloads, identities, logs or source control. |
| Token rotation | Invalidate the previous generation for delivery. Preserve event identity; isolate receipts by subscription. A late result from the old generation cannot reactivate it. |
| Logout/revocation | Invalidate that subscription's delivery authorization. Reject later requests and stale callbacks under the revoked session. |
| Temporary scheduling or provider failure | Retain retry eligibility. Do not mark an event presented or read because delivery was attempted. |
| Provider acceptance | Record acceptance separately from presentation and shared read state. Acceptance does not prove a banner appeared. |
| Another client marks read | Reconcile the feed's authoritative read state independently of local or remote delivery receipts. |

These rows define integration acceptance. Unit and transport tests exercise
registration guards; signed physical delivery requires separate evidence.

## Selected presentation policy

After confirmed push registration, APNs owns native banners and polling updates
only the inbox and shared read state. Before registration, existing foreground
local alerts continue. `NotificationAlerts.isPushRegistered` is an injected,
deployment-scoped readiness lookup. The app owner must supply it from the current
authenticated installation registration, not from a token callback, permission
grant, previous session or registration attempt. Its default is false.
HubServicesModel supplies readiness from the current PushRegistration object
only after a confirmed canonical receipt.

Readiness must bind the server receipt to the exact deployment, current
authenticated session, installation and token generation. Rotation, logout,
session replacement or deployment replacement invalidates readiness immediately.
An async registration receipt is accepted only when its captured generation
still equals the current generation. The canonical registration API supplies
an opaque receipt binding. HubTransport uses it under the enrolled session;
an uncertain attempt never establishes readiness. The service's
internal token hash must never become a public session or installation identity.

The delivery gate checks readiness again after awaiting OS permission settings,
so registration that finishes during that lookup suppresses local scheduling.
Suppression advances the presentation baseline but does not claim the event was
locally delivered or mark it read. Returning to local mode uses the latest inbox
baseline rather than replaying push-era history.

Permission to request alerts remains an explicit user action. Reconnect and
polling must not prompt for permission.
If the hub changes or a refresh is canceled while OS permission settings are
being read, the old event must not be scheduled or consumed. A stale scheduling
receipt must not commit the obsolete refresh. A request already submitted to the
OS cannot be guaranteed to be recalled if the refresh becomes obsolete while
awaiting its receipt. Successful current OS scheduling advances the local
delivery checkpoint, not shared read state.
Another window can disable alerts or finish delivering an event while these
operations await the OS. Recheck the current preference and exact delivered IDs
before scheduling, then merge successful receipts into fresh state. Preserve
other windows' preferences and delivery IDs, and never lower a newer baseline.
Skipping an already delivered event must still allow later eligible events in
the same batch.

## Minimal application and signing integration

- NativePushNotifications receives iOS/macOS registration success/failure
  callbacks and forwards opaque tokens under the current authenticated session.
  Register through the platform API at the agreed lifecycle point. Stop stale
  callbacks from crossing logout, session changes or token generations.
- The app owner coordinates a single `UNUserNotificationCenter` delegate for
  foreground presentation and response handling. The current local presenter
  installs its own delegate lazily; adding a second delegate would overwrite
  it. A notification response must reconcile the authoritative inbox using
  the original event identity and the selected read policy.
- iOS needs an explicit push-enabled App ID and matching provisioning profile
  and `aps-environment` entitlement. A wildcard Ad Hoc profile is insufficient.
  macOS requires its matching profile and
  `com.apple.developer.aps-environment` entitlement. Verify the exported signed
  app and profile agree on bundle/topic and environment.
- Signing configuration includes the platform APNs entitlement. A signed build
  or installation alone is not delivery evidence; verify the exported app and
  profile before physical acceptance. Visible alert delivery alone does not
  require adding a background-fetch feature.

The service owns canonical registration, subscription receipts and sender
integration. Native apps use the selected push-only banner policy. Forgetting a
connection requires confirmed revocation when alerts were enabled or registration
was attempted. The durable attempt hint supports recovery after relaunch and is
not registration authority.

## Acceptance evidence

`NotificationSchedulingTests` exercises the actual presenter through a synthetic
OS boundary: permission states, content, immediate requests and cancellation or
deployment invalidation during permission lookup. `NotificationDeliveryIntegrationTests`
extends the serialized hub suite and exercises the real core and HTTP transport:
failed scheduling, reconnect, retry, and independent shared read acknowledgements.
Existing alert tests cover byte-exact event deduplication, per-deployment state
and durable partial-success retries.

Synthetic tests do not demonstrate physical banners or closed-app delivery.
Record separate results for foreground, background and terminated iOS/macOS
apps using a signed build, matching APNs environment and synthetic event.
For each result retain event identity, installation subscription, token generation
without token bytes, provider response, observed banner, inbox row and subsequent
read reconciliation. Check rotation, revocation, denied permission, retries and
reconnect without duplicate banners. Test an explicit user force-quit separately;
do not infer its behavior from an ordinary termination. Physical iPhone testing
requires the enrolled phone and its paired installation host to be available.

Apple references: [APNs request headers and collapse ID](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns),
[registering with APNs](https://developer.apple.com/documentation/usernotifications/registering-your-app-with-apns),
[iOS entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/aps-environment),
[macOS entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.aps-environment).
