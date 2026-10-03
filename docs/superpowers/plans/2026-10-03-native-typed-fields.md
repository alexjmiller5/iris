# Native typed field controls

Finish the approved MVP's ordinary form controls while retaining the shared core
as the validator and writer. New components own presentation and draft bindings;
the existing record editor, recovery journal and save path remain authoritative.

1. Select and multi-select use native choices and removable selected values, with
   descriptions from the catalog. Load SQL-backed choices through NativeWorkspace
   options. Preserve unknown selections and exact UTF-8 values; opening a field
   never rewrites its source. Invalid stored arrays remain available as source
   with a visible error. Loading failure retains the draft and supports retry.
2. Date and datetime use native pickers with explicit clearing. Keep untouched
   strings intact, date-only values timezone-free, and datetime display explicit
   about UTC. Invalid source stays visible instead of becoming today's date.
3. Boolean controls preserve the difference between unset and false. URL, email
   and phone fields retain text editing and offer explicit system open actions;
   never open a link automatically or accept arbitrary executable URL schemes.
4. Only new component/helper files, relevant CatalogField presentation helpers,
   and WorkspaceView's private FieldInput region belong to this slice. The
   incoming-reference work owns the surrounding RecordEditor body.

Start with choice projection and asynchronous option loading tests. Observe RED
before each implementation, then cover source preservation, opaque identities,
load/retry/cancellation and actual JavaScriptCore options. Add the native views
only after the tested draft behavior is green. Continue with date/link conversion
tests, semantic mutations and the full SwiftPM suite on restored source.

The shared Apple execution owner verifies the resulting controls on an isolated
iOS simulator. Mac interaction needs an unlocked console; compile and model
checks do not substitute for that test. Do not alter generated resources, core
rules, live data or deployment configuration.
