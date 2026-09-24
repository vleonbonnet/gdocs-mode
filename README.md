# gdocs-mode

Bidirectional sync between local Org mode buffers and remote Google Docs
documents.

A Google Doc opens as a local `.org` buffer; edits made locally can be pushed
back, and remote changes are detected and pulled automatically. The goal is to
give Org users the same editing experience for Google Docs that they already
have for local files.

**Note:** this is still work in progress and some rich content does not
properly sync.

## Features

- **Pull** — fetches the current remote content and rewrites the local buffer.  
Headings, paragraphs, bold/italic/code spans, bullet and numbered lists,  
tables, code blocks, and inline image metadata convert to Org equivalents.  
Remote images are represented by explicit remote-object placeholders: standalone  
images use `#+gdocs_inline_object:` and images embedded in prose use  
`@@gdocs-inline-object:image ENTITY WIDTHxHEIGHT content-id=CONTENT@@`; the  
image bytes are not downloaded.  
Date and person smart chips are decoded the same way and rendered as Org chip  
links whose hidden target carries the remote identity, for example  
`[[gdocs-chip:date ENTITY][2026-09-24 Thu]]`; the description shows the  
payload (an Org-style date or the contact name) with the `org-date` face on  
date chips. The semantic value behind the link is what push matching compares, so  
a reformatted description that parses to the same calendar date still matches. Rendered  
tables pad their cells so every row shares the same display widths, and emphasis markers  
are placed so Org actually parses the result (boundary whitespace moves  
outside the markers; emphasis that Org could not parse is dropped rather than  
emitted as literal markup).  
Comments are pulled into an editable local-only, ephemeral projection. Comments  
with unambiguous anchors get reserved `[fn:gdocs-comment-N]` references, and all  
fetched comments are listed in a local `* Comments` subtree. You may edit that  
projection locally, but only its reserved references and generated subtree are  
stripped before push; ordinary numeric and named Org footnotes remain content.  
Pull fails visibly if the remote body already uses the reserved namespace.
- **Push** — converts the local Org buffer back to Google Docs format and
writes it remotely. The configured `gdocs-push-backend` determines whether the
push is a full replacement/re-encoding, a model-level incremental update, or a
legacy plain-text diff. A push does not always update existing sections in
place.
- **Auto-sync** — a periodic timer (`run-with-timer`) polls the remote revision
every `gdocs-auto-sync-interval` seconds. Its decision table is:

| Remote/local revision state | Local body | Action |
|-----------------------------|------------|--------|
| Different                   | Clean      | Pull     |
| Same                        | Dirty      | Push     |
| Different                   | Dirty      | Warn once for that remote revision; take no action |
| Same                        | Clean      | Take no action |
| Either revision unavailable, or state fetch fails | Either | Report a diagnostic; take no action |

Local dirty state is determined from a hash baseline refreshed after successful
syncs, not from `buffer-modified-p`. The baseline is persisted in
`GDOC_CONTENT_HASH` and restored when the mode is enabled; a missing or malformed
baseline is `unknown`, so auto-sync reports it and does not even start a remote
probe. At most one edit-state probe is in flight per buffer, and disabling or
re-enabling the mode invalidates callbacks from an earlier lifecycle. A pull also
captures the body hash and `GDOC_REVISION` at dispatch and refuses to overwrite the
buffer if either changes before the asynchronous response is applied. A manual
`gdocs-push-remotely` applies the conflict and verified-no-op rules described
below.

- **Org link interception** — opening a `docs.google.com/document/d/...` link
in Org opens it through `gdocs-mode` instead of the browser.

### Push backends

`gdocs-push-backend` defaults to `ot-encode`:

| Backend | Behavior |
|---------|----------|
| `ot-encode` | Default. Rebuilds the document model from the local Org buffer, deletes the existing OT body, and inserts a complete re-encoding with supported styles and structure. |
| `ot-incremental` | Decodes the live OT body into a document model and computes a paragraph-level model diff. Safe changed regions use incremental operations. If the changed region contains a list, table, standalone inline object, or inline object embedded in prose, it falls back to the same full replacement/re-encoding as `ot-encode`; unchanged image paragraphs outside the changed region can remain incremental. |
| `plain` | Legacy/experimental incremental plain-text diff. Emits only `is`/`ds` text operations and no style information; it is lossy and not recommended. |

`ot-encode` sends the full delete/insert/style command list in one save.
`ot-incremental` uses a paragraph-model diff when the changed region is safe;
list, table, standalone inline-object, and inline-object-in-prose changes fall
back to the `ot-encode` full replacement. Legacy `plain` can apply pure prepend
and append operations, mappable single-region replacements, and disjoint
paragraph changes. Replacements use sequential single-operation saves, and
multi-region edits are rebuilt latest-first against freshly verified state.
Plain pushes carry no style operations and can therefore lose formatting.

### Push safety and completion

Every plan is preflighted against capability data decoded again from the
freshly fetched remote OT state; persisted or buffer-local summaries are not
trusted. A full replacement is refused when it would discard a destructive
unsupported capability. An incremental edit is allowed only when every
unsupported capability permits untouched preservation, has a known range, and
no deletion or insertion boundary touches that range. Invalid or changed inline
object markers, ambiguous remote objects, and any plan for which preservation
cannot be proved are refused before `/save`. A no-op still validates local and
remote inline-object representations, but untouched unsupported ranges need no
write-preservation proof.

For a changed body, the fetched remote revision must equal the buffer's
`GDOC_REVISION`; a mismatch is a revision conflict and no write is attempted.
There is one intentional exception: when the canonical local body already
matches the freshly fetched remote body, capability preflight still runs but
the command sends no `/save`. That verified no-op records the fresh remote
revision as the new baseline, even when the old `GDOC_REVISION` was stale.

Push is asynchronous. A package-wide synchronization lock covers the initial
fetch and the complete save/verification chain; overlapping synchronization is
skipped, and the lock is released on success or error. Asynchronous failures are
reported through the warning log. A successful save or verified no-op updates
`GDOC_REVISION`, `GDOC_CONTENT_HASH`, and `GDOC_SYNCED_AT`, then marks the
buffer synchronized. If a multi-stage plain push commits an intermediate
operation and a later stage fails, only its revision may be recorded; no final
content-hash baseline is written.

A transport error, server rejection, or malformed success response after
dispatch has an ambiguous outcome. The mode refetches the document and compares
both body and revision with the expected pre- and post-operation snapshots. An
observed committed result is accepted. A throttle rejection may be retried once
only when the exact pre-operation state is still present, and the operation is
rebuilt against that fresh state rather than replayed. Conflicting, undecodable,
or otherwise indeterminate outcomes fail closed without a final hash baseline.

### Spacing canonicalization

Pull/render uses a structural spacing policy rather than rewriting the final
text with a regular expression:

- heading, `#+title:`, and `#+subtitle:` entries have exactly one blank line
before and after them when neighboring content exists;
- consecutive Google Docs empty paragraphs are reduced to one meaningful Org
blank line, while leading/trailing empty paragraphs are discarded;
- empty paragraphs between source-code paragraphs remain empty source lines,
and heading padding is never inserted inside a source block;
- lists stay contiguous unless the source contains a meaningful blank
paragraph.

Repeated empty paragraphs are intentionally handled lossily: Google Docs'
arbitrary visual vertical spacing has no stable Org equivalent. The normalized
paragraph model is also used by the OT emitter and paragraph diff, so a
synthetic heading blank cannot become a new remote paragraph on every cycle.

### Supported content

The supported round-trip surface is headings, paragraphs, inline emphasis,
links, lists, tables, and source blocks. Google Docs inline images are
pullable but intentionally not editable. A standalone pulled image is rendered
as an explicit remote placeholder such as:

```org
#+gdocs_inline_object: image kix.example 468x102 content-id=s-blob-v1-IMAGE-example
```

The placeholder is metadata, not prose and not an Org image link. Its entity
ID, object kind, content ID, and dimensions form its stable identity. Do not
edit, remove, move, or recreate it and then push: a full-replacement push is
refused rather than silently deleting the remote image. A safe incremental edit
may proceed only when the remote image is matched to its unchanged local
placeholder and the edit range is proven not to touch it. Image creation,
deletion, movement, duplication, metadata changes, and ambiguous
entity-to-placeholder associations remain refused.

Date and person smart chips follow the same policy with `date`/`person` object  
kinds. They render as Org chip links such as  
`[[gdocs-chip:date:kix.example][2026-09-24 Thu]]` and  
`[[gdocs-chip:person:kix.example][Jane Doe]]`; Org hides the target and shows  
only the description. The chip's semantic value (calendar date or contact name)  
is the editable-identity field: an unchanged chip is preserved by incremental  
edits that do not touch it, while creating, deleting, moving, or editing a chip  
is refused before any `/save`.

## Requirements

- Emacs **29.1+**.
- [`request`](https://github.com/tkf/emacs-request) **0.3.2+**.
- `curl` available on `PATH` at runtime. Pull, push, auto-sync, and comments
networking invoke external `curl` subprocesses.

The core package does not use SQLite. Emacs built with SQLite support is required
only for the optional Firefox-cookie example below, which calls `sqlite-open` and
`sqlite-select`. Other `gdocs-auth-function` implementations do not inherit that
requirement.

## Installation

Clone the repository and point `use-package` at it:

```elisp
(use-package gdocs-mode
  :load-path "~/path/to/gdocs-mode/"
  :config
  (setq gdocs-auth-function #'my/gdocs/firefox-cookies)) ; see Authentication
```

If you use [`elpaca`](https://github.com/progfolio/elpaca) or
[`straight.el`](https://github.com/radian-software/straight.el), install
directly from Git:

```elisp
;; elpaca
(use-package gdocs-mode
:ensure (:host github :repo "vleonbonnet/gdocs-mode"))

;; straight
(use-package gdocs-mode
  :straight (gdocs-mode :host github :repo "vleonbonnet/gdocs-mode"))
  ```

## Authentication

The mode never talks to Google directly about credentials. Instead,
`gdocs-auth-function` holds a function of no arguments that returns an alist of
HTTP headers to attach to every request. It is called fresh on every request,
so backends may compute timestamp-sensitive headers inside it. Two header
shapes are recognised:

| Backend                  | Returned alist                              |
|--------------------------|---------------------------------------------|
| Cookie (browser session) | `(("Cookie" . "SID=…; HSID=…; SSID=…; …"))` |
| OAuth2                   | `(("Authorization" . "Bearer ya29…"))`      |

The cookie backend works for both read and write. OAuth bearer tokens currently
work only against the read-side REST API — the `/save` (push) endpoint still
requires cookie auth that matches a real browser request. Wiring the documented
OAuth `documents.batchUpdate` endpoint to remove the cookie dependency on push
is the main piece of remaining work.

### Bootstrap backend: Firefox cookies

The quickest way to exercise the mode end-to-end is to derive a session from a
logged-in Firefox profile. This reads `cookies.sqlite` directly via Emacs's
built-in `sqlite-open`. It is a **development-tier mechanism** — no secrets
manager, no rotation, no logout detection — and should not be used in shared or
multi-user setups.

```elisp
(defun my/gdocs/firefox-cookies ()
  "Return google.com cookies from Firefox as a Cookie header alist."
  (let ((src (expand-file-name
              ;; Adjust the profile path to your platform / profile id:
              ;;   macOS:   ~/Library/Application Support/Firefox/Profiles/<id>.default-release/
              ;;   Linux:   ~/.mozilla/firefox/<id>.default-release/
              ;;   Windows: %APPDATA%/Mozilla/Firefox/Profiles/<id>.default-release/
              "~/Library/Application Support/Firefox/Profiles/XXXXXXXX.default-release/cookies.sqlite"))
        ;; Firefox holds an exclusive lock on the live DB, so work off a copy.
        (tmp (make-temp-file "gdocs-cookies" nil ".sqlite"))
        db rows cookies)
    (unwind-protect
        (progn
          (copy-file src tmp t)
          (setq db (sqlite-open tmp))
          ;; Order DESC so the preferred host's row is visited last and wins.
          (setq rows (sqlite-select
                      db
                      (concat "SELECT name, value, host FROM moz_cookies "
                              "WHERE host LIKE '%google.com' "
                              "ORDER BY CASE "
                              "  WHEN host = 'docs.google.com' OR host = '.docs.google.com' THEN 1 "
                              "  WHEN host = '.google.com' THEN 2 ELSE 3 END DESC")))
          (sqlite-close db)
          (setq db nil)
          (dolist (row rows)
            (setf (alist-get (car row) cookies nil nil #'equal) (cadr row)))
          (list (cons "Cookie"
                      (mapconcat (lambda (c) (format "%s=%s" (car c) (cdr c)))
                                 cookies "; "))))
      (when db (ignore-errors (sqlite-close db)))
      (ignore-errors (delete-file tmp)))))
```

When the same cookie name appears for multiple hosts, `docs.google.com` wins
over `.google.com`, mirroring the host priority the browser uses so that
`SAPISID`/`SID` resolution matches what Firefox sends.

For anything beyond local experimentation, write your own
`gdocs-auth-function` that obtains browser-session cookies from an appropriate
credential store such as a password manager or the macOS Keychain. An OAuth
refresh-token flow is suitable only for pull/read requests until push is moved to
a documented OAuth-capable API.

## Usage

| Command               | What it does                                                   |
|-----------------------|----------------------------------------------------------------|
| `gdocs-open`          | Open a Google Docs URL or document ID (or the link at point).  |
| `gdocs-pull-locally`  | Fetch remote content and rewrite the local buffer.             |
| `gdocs-push-remotely` | Push local Org changes back to the remote document.            |
| `gdocs-out-of-date`   | Check whether the remote document has advanced.                |
| `gdocs-mode`          | The Org minor mode that ties pull/push/auto-sync together.     |
| `gdocs-publish-file`  | Publish a source Org file as the body of a Google Doc (one-way projection). |
| `gdocs-publish-preview` | Show the conversion preview, disclosed fallbacks, and blocking content for a source file. |
| `gdocs-publish-check` | Compare a source file with its published document (read-only drift check). |
| `gdocs-session-reset` | Delete the persisted `/save` SID/request-id session and create a new one on the next push. |
| `gdocs-recon-dump` | Write read-only OT reconstruction and summary dumps to unpredictable mode-0600 temporary files. |
| `gdocs-debug-comments-fetch` | Fetch comments into `*gdocs-comments-debug*` for diagnostics; does not push. |
| `gdocs-debug-push-state` | Write a read-only push-planning dump to an unpredictable mode-0600 temporary file. |

When called from Lisp with a callback, `gdocs-pull-locally` completes it
exactly once as `(CALLBACK BODY ERR)`. If another sync operation owns the
global lock, it returns a nil body and `"sync busy"` without disturbing that
operation. Interactive busy pulls continue to log a warning.

Diagnostic dumps and the comments debug buffer contain sensitive document,
comment, and raw OT content. They persist until explicitly deleted or killed.
The commands report exact generated paths without logging raw content; supplied
output paths are honored. Delete file dumps after use, for example with
`M-: (delete-file "/exact/path/reported/by/the/command")`, and kill
`*gdocs-comments-debug*` when finished.

Open a document with `M-x gdocs-open` and paste the URL or document ID. The
mode opens (or reuses) a local `.org` buffer named after the document title and
performs an initial pull. `gdocs-mode` auto-enables in any Org buffer that
carries a `GDOC_ID` property, and the mode line shows an indicator while it is
active.

For a document with multiple tabs, pull puts every tab in the same Org buffer. Each tab is a heading with a `GDOC_TAB` property; nested tabs become nested headings, and headings within a tab are shifted below its heading. The document name appears once as the file's `#+title:`. A tab emoji appears both in its heading and in `GDOC_TAB_ICON`. Opening a URL with `?tab=…` moves to that tab after pull. Single-tab documents keep their existing unwrapped layout.

Pushing a multi-tab document is supported for a deliberately narrow case: the buffer differs from the remote in **one tab**, that tab contains only plain, unstyled paragraphs, and the change is a single insertion or deletion. The save is scoped to that tab (each command is wrapped in the editor's tab namespace and `tab=` names it). After every response the document is refetched and accepted only when exactly one revision was added, the edited tab has the expected text, and every other tab's operations are unchanged. A throttled save that left the document untouched is replanned from the fresh state and retried (up to five attempts); any other outcome fails closed and asks you to pull. Edits touching several tabs, tabs with lists, tables, headings, chips or formatting, tab renames/moves, and content outside the tab headings are refused before any `/save`. `gdocs-publish-file` still refuses multi-tab documents.

### Source-file publication (one-way Org → Google Docs)

For documents whose source of truth is a plain Org file (not a synced buffer), `gdocs-publish-file` publishes it as the full body of a Google Doc. The source file is never modified; the Google Doc is a projection.

The command: converts the source and refuses blocking unsupported content; discloses lossy conversions before writing (quotes, source-block languages, footnotes-as-text, …) and confirms them interactively; refuses to overwrite a document whose non-empty body was never published from that source (pass FORCE deliberately); refuses a remote revision newer than the last recorded publish; runs the standard capability preflight against the freshly fetched remote state; refetches after the commit and verifies the body when `gdocs-verify-after-save` (default t); records the association and last revision in `gdocs-publish-registry-file`, and refreshes a synchronized buffer for the document, if one is open.

`gdocs-publish-preview` shows the conversion result without any network I/O. `gdocs-publish-check` compares the source against the published document and reports `:in-sync`, `:drift`, `:stale-revision`, or `:unpublished`.

### Buffer metadata

These properties are maintained on the top-level node of every synced buffer:

| Property         | Purpose                                       |
|------------------|-----------------------------------------------|
| `GDOC_ID`        | Identifies the remote document.               |
| `GDOC_TITLE`     | Stores the Google Drive document name. Body `#+title:` keywords remain Title-styled paragraphs and are pushable content. |
| `GDOC_REVISION`  | Staleness anchor — last known remote revision.|
| `GDOC_CONTENT_HASH` | Hash baseline used to detect local changes. |
| `GDOC_SYNCED_AT` | Timestamp of the last successful pull, push, or verified no-op.|
| `GDOC_TABS` | Number of tabs in the pulled multi-tab document. |

## Configuration

| Variable                  | Default     | Purpose                                                  |
|---------------------------|-------------|----------------------------------------------------------|
| `gdocs-auth-function`     | `nil`       | Returns the HTTP auth headers (see above). **Required.** |
| `gdocs-push-backend`      | `ot-encode` | Push strategy; see [Push backends](#push-backends).      |
| `gdocs-verify-after-save` | `t`         | Refetch after a committed OT save and verify the body.   |
| `gdocs-docs-tab`          | `"t.0"`     | Google Docs tab identifier for `/save` and comment requests. |
| `gdocs-publish-registry-file` | `~/.emacs.d/gdocs-publish-registry.el` | Source-file → document publication registry. |
| `gdocs-auto-sync-interval`| `5`         | Seconds between periodic background sync checks.         |
| `gdocs-log-level`         | `warn`      | One of `debug`, `info`, `warn`, `error`.                |
| `gdocs-session-file`      | `$XDG_CACHE_HOME/gdocs-mode/session.eld`, or `~/.cache/gdocs-mode/session.eld` | Where the persistent `/save` SID + request id are kept. |
| `gdocs-default-user-agent` | Firefox 138 on macOS | User-Agent sent with requests. |
| `gdocs-pull-flash-duration` | `0.8` | Seconds for the pull-change highlight fade. |
| `gdocs-pull-flash-steps` | `12` | Number of pull-change highlight fade steps. |

## Offline development tests

The conversion and synchronization helpers have an offline ERT suite backed
by sanitized synthetic OT, inline-image, and comments fixtures. It never
contacts Google, reads browser cookies, or mutates user buffers/files. The
default test target excludes the `integration` ERT tag:

```sh
make test
```

Offline tests load `test/gdocs-mode-test-request.el`, a test-only shim that
rejects network requests. It is not a bundled copy of request and cannot be
used for production byte-compilation or opt-in integration tests.

Production byte-compilation requires a real, compatible
[`request`](https://github.com/tkf/emacs-request) package (version 0.3.2 or
newer). Install it yourself and set `REQUEST_DIR` to the directory containing
its `request.el` or `request.elc`:

```sh
make byte-compile REQUEST_DIR="$HOME/.emacs.d/elpa/request-0.3.3"
make check REQUEST_DIR="$HOME/.emacs.d/elpa/request-0.3.3"
make space-path-check REQUEST_DIR="$HOME/.emacs.d/elpa/request-0.3.3"
```

No dependency is downloaded by these targets. A missing `REQUEST_DIR`, a
directory that does not contain request, or request older than 0.3.2 fails the
production compile with a diagnostic. `make check` also verifies those failure
cases and a successful real-request compile. The test suite and test-file
compilation load the offline shim separately after the production file has
compiled against real request.

Run `make space-path-check` to repeat all three commands through a temporary
symlink whose path contains a space.

Live integration testing is opt-in only. Neither `make test` nor `make check`
runs the `integration` ERT tag. To opt in explicitly, invoke the integration
target with the same real request package directory:

```sh
make integration REQUEST_DIR="$HOME/.emacs.d/elpa/request-0.3.3"
```

That target requires `REQUEST_DIR`, sets `GDOCS_MODE_RUN_INTEGRATION=1`, and
runs only tests tagged `integration`. The repository currently bundles no live
credential tests; it contains only a gated integration-category check so future
local live tests cannot run by default. Any such local test is responsible for
providing its own credentials.

Byte-compilation writes `gdocs-mode.elc` and `gdocs-mode-test.elc` to a fresh
directory under `$TMPDIR` (or `/tmp`), puts that directory first on the load
path, and removes it on success, failure, or interruption. It never writes
compiled files beside the source files, and `make check` serializes its test
and compilation prerequisites even when invoked with `make -j check`.

## Caveats

- **Cookie-only push.** The `/save` write path matches a real browser request
and requires browser-session cookie authentication. OAuth bearer tokens can be
used for reads but do not support `/save`; there is no hardened credential story
yet.
- **Format fidelity is best-effort.** Headings, paragraphs, inline emphasis, lists, tables, and code blocks round-trip.
- **Disclosed fallbacks, not silent loss.** Blocks the remote model cannot represent (quote/verse/center/example/special blocks, footnote definitions, horizontal rules, fixed-width lines) keep their text as ordinary content with a disclosed fallback instead of disappearing. Inline leaves (timestamps, entities, LaTeX fragments, footnote references, macros) are literalized in prose. Source-block language, checkbox structure inside lists, and rich Google-only formatting have no faithful round trip.
- **Inline images are pull-only placeholders.** Downloading, uploading, moving, replacing, and deleting them through push are unsupported except for safe incremental text edits that prove the image was left untouched.
- **Comments** are pulled as an editable local-only footnote and `* Comments` projection, stripped before push, and regenerated from remote comments on the next pull; local edits are never sent to Google. Suggestions and column layouts remain out of scope.
- **Rate limiting.** Google's `/save` endpoint rejects malformed or
excessively bursty requests; the mode persists a session SID to look like a
single stable client.
