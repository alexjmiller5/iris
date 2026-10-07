# Page capture viewer

Open a saved capture metadata row, then choose **View page capture** on the web or
**Open as page capture** in the native record menu. The action explicitly validates
that row as one immutable attempt. It does not infer a capture table from its name,
change schemas, submit record drafts or discover the archiver's local queue.

Screenshot is the default. Choose **Archived HTML** to read the saved page. Both
previews are bounded to 8 MiB; PNG decoding also rejects dimensions over 100 million
pixels. Preview refusal does not change whether the retained attempt is valid.
Save PNG/HTML retrieves and verifies the original bytes independently, up to
128 MiB. The native system picker supports cancel and retry; the browser uses an
explicit download. HTML files are never opened automatically. **Open original
website** is a separate action, omitted for unsupported or unsafe URL text.

Succeeded and partial attempts require both complete HTML and PNG metadata plus a
capture timestamp. Partial warnings show the publisher's positive missing-resource
and/or unfinished-section counts. Terminal failures retain the original source text
and no artifact fields. Whitespace-only invalid source history remains visible;
an empty source string is invalid metadata. The fixture envelope's version is not
a row discriminator.

Each file operation uses the enrolled host's independently authorized file reader.
Capture-table access does not authorize files. The viewer verifies MIME, exact byte
length and SHA-256 before preview or save. A table grant spanning several source
tables is deliberately broad; client filters cannot supply missing server source
authorization.

Archived HTML is hostile. Native uses a fresh nonpersistent WKWebView with no
message handlers, content JavaScript disabled, an opaque sandboxed child, an early
restrictive CSP, content rules blocking external requests and delegates denying
navigation/popups. Context gestures cannot reach WebKit's external-link menu.
Web uses an empty-sandbox iframe, restrictive CSP and no credential forwarding;
its preview derivative also removes scripts, refresh/navigation attributes and
embedded browsing contexts through an inert template. Original downloads are
unchanged. Retained assets are inline/data resources, not a mounted resource tree.
External missing assets remain missing, and the partial warning remains visible.

Changing preview, closing the viewer or changing the workspace cancels outstanding
work and disposes local file/blob resources. A late response from an old request
cannot change a reopened viewer. The archiver CLI's coverage report is separate:
this viewer makes no claim about queued captures or current-source completeness.

## Verification

Metadata and artifact tests cover malformed outcomes, retained partials, unsupported
source text, independent file reads, digest mismatches and preview budgets. Native
WebKit probes exercise scripts, resources, forms, links, popups, nested content,
custom schemes and cancellation with permissive positive controls. The opt-in
application-hosted gesture test checks actual contextual gestures and native clicks;
`scripts/test-capture-native-gestures.py` addresses only its printed synthetic PID.

`scripts/test-page-capture.ts` exercises the mounted web component in a dedicated
disposable origin with a local request sink, hostile HTML and canceled/reopened
requests. It connects to an explicitly owned existing tab, never another workspace.
All fixtures are synthetic. No personal capture is required for these checks.
