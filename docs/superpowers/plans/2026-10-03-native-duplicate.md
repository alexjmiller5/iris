# Native duplicate draft model

This slice prepares an unsaved copy with the existing RecordDraft and
RecordEditorModel. Host actions and controls remain separate.

- Construct a new editor with fresh catalog properties and `original: nil`.
  `installDuplicateDraft(from:isCurrent:)` copies only present fields in that
  draft's existing field list. This retains set-once fields and excludes managed,
  derived and deprecated fields. Core still owns conversion, defaults and validation.
- Each explicit creation value removes its column from the existing `initial`
  dictionary. A missing baseline makes even a blank clear explicit in the patch.
  Missing source columns remain untouched and receive core defaults. An optional
  Codable set distinguishes copied SQL empty strings from null; older journals
  decode without it and retain their previous meaning. Receipt and Undo handling
  preserve a newer clear even when its displayed text is also blank.
- `setValue(_:for:explicit:)` defaults to ignoring byte-identical values because
  Markdown snapshot collection can replay unchanged source. Changed values are
  explicit edits; an intentional same-value clear passes `explicit: true`.
- Duplicate installation keeps its own nil-recordID journal before presentation,
  including an empty copy. Existing recovery variants remain on disk. Unreadable
  recovery, stale ownership, in-flight saves and persistence failure prevent
  publication; failed persistence restores the original draft and recoveries.
  The existing new-record gate prevents autosave without an extra pause state.

Verification covers real JSC defaults/nulls/empty text and row creation, false and zero,
exact UTF-8 source, field exclusions, set-once values, no SQL until Save, legacy
decoding, independent journal ownership, persistence rollback, and a clear made
while a creation receipt is pending. Semantic mutations and the restored full
SwiftPM suite are required before handoff.

The model checkpoint adds 19 behavioral tests. Real JSC probes first reproduced
default-vs-null loss and copied-empty-text loss; the restored focused run passed
51 tests. All 31 semantic mutants were caught by behavioral assertions. The
restored full SwiftPM run passed 316 tests in 54 suites, with five existing HTTP
integration tests skipped. Swift formatting and whitespace checks passed.

## Host handoff

The host must resolve the source's exact ID against fresh full rows and catalog,
check core writeability, and retain workspace/query/request guards. Web parity
allows active source rows only. Prepare and persist before installing the new
editor through the existing prepared-editor seam. Keep its list context; an
unsaved copy has no record destination to add to recents.

A generic new-record **Set empty** action can call
`editor.setValue("", for: field.id, explicit: true)` outside FieldInput's typed
bindings. A picker already on its unset value cannot signal this intent through
an unchanged selection. These controls, duplicate actions, fresh-source host
tests and actual native UI verification are not part of this model slice.
