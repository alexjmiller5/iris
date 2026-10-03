# Native deep-link codec and workspace identity

Implement the approved model/store slice only. No URL registration, host intake,
clipboard control, navigation coordinator, core operation or database metadata.

- Encode `life://open/v1` with exactly one `replica` endpoint digest or `local`
  UUID and the existing `NativeDestination` table/view/row tuple. Preserve UTF-8
  bytes; reject unknown versions/fields, duplicate parameters and missing IDs.
- A replica digest reuses the canonical enrolled endpoint's existing storage
  hash. Never normalize an endpoint again in the codec or put credentials,
  filesystem paths, labels or content in the URL.
- A missing workspace binding represents the temporary sample and cannot issue
  a link. Matching a parsed link requires the explicitly opened workspace's
  binding, with no current-database fallback.
- Keep random local UUIDs in private atomic Application Support preferences,
  scoped by the existing draft-store key. The UUID is independent of that key.
  Re-read before every operation. Serialize synchronous operations on MainActor
  so independent windows cannot publish competing first IDs.
- Pair each UUID with the file's volume identity, inode and creation time.
  Ordinary in-place database writes preserve identity; replacement invalidates
  the old binding. A moved app container retains its relative preference scope.
  External moves/copies are not automatically rebound. Unread, malformed and
  future preferences must never be overwritten. Intake/lookup never creates IDs.

## Verification

Write meaningful failing tests before implementation. Test actual temporary
files, independently constructed stores, permission failures, replacement,
container relocation, symlink aliases and private atomic persistence. Test opaque
UTF-8/percent/plus identifiers, duplicate/unknown query fields, canonical replica
identity and mismatched workspace bindings. Catch semantic mutants and run the
restored full LifeKit suite in the coordinated isolated SwiftPM slot.

## Later host handoff

Attach the binding to the installed database, not connection flags: forgetting
credentials leaves the replica database open. After matching, call the common
fresh resolver and existing pending-write/draft guards. Only UI installation may
record recents. A local identity error leaves navigation available but prevents
copying or matching a local link. The existing app-owned root is supplied by the
host; the store never discovers or embeds a user path.

The file creation-time API requires an Apple file-timestamp privacy reason at
application integration. Coordinate that declaration with the Apple owner;
resources and application registration are outside this model slice.

Actual cold/warm launch, Copy link, dirty cancellation and platform registration
remain separate Apple UI gates. No claim of end-to-end deep-link support belongs
to this slice.
