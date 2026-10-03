# Native link identity contract

The codec carries an existing `NativeDestination` in a versioned `life://open/v1`
URL. The query has exactly one workspace selector, `replica` or `local`, a required
`table`, and optional `view` and `row` identifiers. Identifiers remain byte-exact
UTF-8 values, including literal plus and percent characters. Unknown parameters,
duplicate parameters, unsupported versions and empty identifiers are errors.

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

This model slice does not register the scheme, handle incoming system URLs,
operate the clipboard or install a navigation destination. Those host changes
require separate native interaction tests.
