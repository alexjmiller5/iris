# Selected row actions

Use each row's checkbox, or **Select loaded rows**, to select records on the current
web page. Selection is explicit and clears when that page reloads. **Export** saves
the selected committed rows as JSON or CSV, with a separate CSV metadata download.
The export retains the loaded-page coverage and freshness caveats.

Open **Selection**, choose a property and value, then **Apply to selected**. Empty
text stays empty text; **Clear value (null)** explicitly clears a value. The same
property editors and catalog options used by individual records are available.
**Move selected to trash** soft-deletes the selected records.

Each record uses a fresh full row and its revision through the ordinary validated
writer. A rejected row does not stop the remaining selection. The result lists
every selected ID as succeeded, failed or unattempted. Successful changes are local
commits; synchronization can independently reject them and uses the existing inbox.
**Cancel remaining** stops admission of further rows. A write already in flight
retains its actual success/failure receipt. The existing Undo action applies to the
last saved row, not the whole selection.

Finish or discard an active draft before applying bulk changes. The operation does
not flush drafts. Changing workspace, table, view or catalog stops further writes;
ordinary row refreshes from the operation's own commits preserve its frozen IDs.
