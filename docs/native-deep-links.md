# Native link identity contract

The codec carries an existing `NativeDestination` in a versioned `iris://open/v1`
URL. The query has exactly one workspace selector, `replica` or `local`, a required
`table`, optional `view` and `row` identifiers, and optional `state` query JSON. Identifiers remain byte-exact
UTF-8 values, including literal plus and percent characters. Unknown parameters,
duplicate parameters, unsupported versions and empty identifiers are errors. Query state is limited to 16 KiB and validated by the canonical read-only view compiler after workspace matching. It carries no action values; those come from the displayed saved revision.

Replica selectors are the existing SHA-256 storage key of the canonical enrolled
hub endpoint. Callers supply the endpoint already canonicalized by `HubTransport`.
The URL contains neither that endpoint nor any credential. Matching a digest is
only routing: it never enrolls a device, grants access, performs HTTP, or chooses
credentials. An opened replica retains its binding when its credential is forgotten.

Local selectors are random UUIDs persisted beneath the app's Application Support
root. The existing draft preference scope finds the private file; its path hash
is not the public identity. Independent devices and same-named files receive
different UUIDs. The preference includes a local file stamp so replacing the
database invalidates its old binding without depending on record contents.
These links are device-local. Copies and externally moved files are not silently
rebound to old links. Temporary samples have no link binding.

This identity belongs to the physical file. Rewriting database contents in place
is treated as editing that same file; distinguishing a logical database reset
from ordinary writes would require a database-owned identity outside this slice.

## Host handoff

1. Supply the installed database's binding, independently of transient connection
   flags. Do not derive it from a display label or from a generic local filename.
2. Parse with `NativeDeepLink(url:)`, then obtain the destination through
   `destination(matching:)`. A missing or different binding is an error, never a
   fallback to the current database.
3. Resolve current catalog, saved view and full row with `NativeDestinationResolver`.
   Preserve the existing pending-write, draft-discard and stale-response guards.
4. After successful UI installation, invoke the shared navigation completion hook.
   Parsing, matching, metadata lookup and failed navigation must not bump recents.
5. For Copy link, explicitly call `NativeLinkIdentityStore.create()` for a local
   database, then `NativeDeepLink(destination:workspace:).url`. A nil workspace
   binding cannot produce a sample link. Never copy a URL after a persistence error.

`NativeLinkIdentityStore.load()` never writes. Both operations re-read the latest
preferences and synchronously run on MainActor so independent windows share an
already-created UUID. Malformed, future and inaccessible files are preserved.
Only explicit creation may rotate a binding after database replacement. The
directory is private, and preference replacement is atomic.

The file stamp uses volume identity, inode and creation time. The timestamp API
requires the application's appropriate file-timestamp privacy declaration when
the host adopts this store. Apple distinguishes the nonpersistent
[file resource identifier](https://developer.apple.com/documentation/foundation/urlresourcekey/fileresourceidentifierkey)
from a [document identifier](https://developer.apple.com/documentation/foundation/urlresourcekey/documentidentifierkey)
that can survive file replacement; neither alone satisfies this contract.

The workspace lifecycle retains its installed binding independently of credentials.
Forgetting a connection keeps the replica binding; replacing or closing the client
clears it. Local opening reads identity without creating preferences and retains
the opened physical file stamp. A replacement at the same path blocks both Copy
and matching until the workspace is reopened. An unread preference file disables
link operations with an error while ordinary workspace use remains available.

`PendingNativeLink` retains one intent. A blocked action or lookup failure does
not consume it; completion and errors apply only to the matching request UUID.
It has no automatic navigation or persistence.

The apps include file-timestamp privacy declarations because the lifecycle reads
the file stamp on opening. `C617.1` covers app-container files; macOS additionally
declares `3B52.1` for databases explicitly chosen in its file picker, following
[Apple's approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

Both apps register the `soma` URL scheme. `WorkspaceView` receives incoming URLs
with `onOpenURL` and only retains them in `PendingNativeLink`; a banner offers an
explicit Open and Dismiss, and receipt never navigates, enrolls, opens or switches
a workspace. Open is disabled while any editor, sheet, handoff or navigation is
active; an open record editor shows a waiting notice instead. Open matches the
binding through `linkedDestination`, then reuses the guarded `openDestination`
path, and clears the request only after that destination installs. A mismatched
or unavailable destination keeps the request with its error. Copy link in the
records header copies the table and applied saved view; the record editor copies
a saved record. Both copy only after encoding and identity persistence succeed.
