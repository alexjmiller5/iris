# Sidebar navigation

Recent destinations are a device preference, separate for the sample database and
account workspace. The version 1 preference contains at most eight exact
`{ table, view, row }` identifier tuples in newest-first order. It contains no
labels, credentials, endpoints, record bodies or query configuration.

Only completed navigation adds or moves an entry. Saves, sync, label refresh,
failed navigation and cancelled discard leave the order unchanged. Reopening a
recent destination resolves its current catalog, saved-view definition and full
record through the existing core requests before applying the normal draft and
pending-write guards. Saved views are identified by their stable ID.

Labels are resolved from current local data. A missing table, view or record stays
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
LIFE_UI_TEST_URL=http://life-ui-recents.localhost:5236/workspace?review \
  bun scripts/test-sidebar-recents.ts <life-data-checkout>
bun scripts/test-sidebar-mutations.ts <life-data-checkout> --unit
bun scripts/test-sidebar-mutations.ts <life-data-checkout> --browser
```

Open the reserved fixture tab on the matching development server first. The hub
checkout must contain the browser CORS and device-session endpoints. The runner
refuses storage resets outside reserved fixture origins. Browser mutations run
sequentially, assert behavioral failures and restore each file in `finally`.
Only one Playwright CDP client may be attached during native confirm flows.
Close the workspace through its supported UI before leaving/resetting the page.
