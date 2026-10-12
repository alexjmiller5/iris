# Sidebar navigation

Recent destinations are a device preference, separate for the sample database and
account workspace. The version 2 preference contains at most eight exact
`{ table, view, row }` identifier tuples in newest-first order, each with its
display snapshot `{ label, context, trash, unavailable }` once it has been shown
resolved. It contains no credentials, endpoints, record bodies or query
configuration. A version 1 preference (tuples only) still reads; its entries show
their raw IDs until their first refresh, which stores their snapshots.

Only completed navigation adds or moves an entry. Saves, sync, label refresh,
failed navigation and cancelled discard leave the order unchanged. Reopening a
recent destination resolves its current catalog, saved-view definition and full
record through the existing core requests before applying the normal draft and
pending-write guards. Saved views are identified by their stable ID.

A plain table link (a sidebar table, a pinned table, Find's table entry, a table
recent) is a table visit: `view` is null and it is named by the table, although the
table opens on its default saved view. Only a chosen view (the view switcher, a view
link, Find's view entry, Save as new view) is a view visit, named by the view, and
only a chosen view joins a record visit's identity and context. Restoring this
page's own URL, which names the default view a plain table opened on, keeps it a
table visit.

A visit stores the title, view name or table the page shows when it is recorded,
and stored snapshots paint with the sidebar when a workspace opens, so a recent
never flashes its ID or a Loading line. Labels then refresh from current local
data in the background; an entry updates, and its snapshot is stored again, only
when something changed (a rename, trash, or availability). The snapshot is display
only: opening a recent always resolves its tuple. A missing table, view or record stays
in the list with its availability reason and a Remove action, because local
absence can reflect a partial replica. Removal only changes this preference.
Trashed records are marked and use the existing read-only editor and Restore
path. Storage errors are visible and leave in-memory navigation available. If
reading the preference fails, its stored contents remain untouched for that
workspace session.

The collapsible System tables section uses the catalog's `readOnly` boolean.
This is the service-owned table contract, independent of the writeability
advisory for unsupported storage such as SQLite views. System tables remain
navigable and eligible for Recent; their edit guards remain in force.

No pins, streams, cross-workspace routing or transient filter/sort history are
included. URLs and recent destinations share the same table/view/row contract.

Verification uses a disposable browser origin, real OPFS and the synthetic hub:

```sh
IRIS_TEST_URL=http://iris-recents.localhost:5236/workspace?review \
  bun scripts/test-sidebar-recents.ts <soma-checkout>
bun scripts/test-sidebar-mutations.ts <soma-checkout> --unit
bun scripts/test-sidebar-mutations.ts <soma-checkout> --browser
```

Open the reserved fixture tab on the matching development server first. The hub
checkout must contain the browser CORS and device-session endpoints. The runner
refuses storage resets outside reserved fixture origins. Browser mutations run
sequentially, assert behavioral failures and restore each file in `finally`.
Only one Playwright CDP client may be attached during native confirm flows.
Close the workspace through its supported UI before leaving/resetting the page.
