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
Comments are pulled into a read-only local projection. Comments with unambiguous
anchors get footnote references at those anchors, and all fetched comments are
listed in a local `* Comments` subtree. The projection is stripped before push;
editing or pushing comments is unsupported.
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
syncs, not from `buffer-modified-p`. A manual `gdocs-push-remotely` also refuses
to push when the fetched remote revision differs from the buffer's
`GDOC_REVISION`.

- **Org link interception** — opening a `docs.google.com/document/d/...` link
in Org opens it through `gdocs-mode` instead of the browser.

### Push backends

`gdocs-push-backend` defaults to `ot-encode`:

| Backend | Behavior |
|---------|----------|
| `ot-encode` | Default. Rebuilds the document model from the local Org buffer and emits a full replacement/re-encoding, including supported styles and structure. |
| `ot-incremental` | Decodes the live OT body into a document model and computes a paragraph-level model diff. Safe changes use incremental operations; changes involving lists, tables, or changed inline-object paragraphs fall back to a full replacement/re-encoding. |
| `plain` | Legacy/experimental plain-text diff. Emits only `is`/`ds` text operations and no style information; it is lossy and not recommended. |

Full replacements and incremental operations both go through capability
preflight. Unsupported remote content is handled fail-closed: a full
replacement is refused, while an incremental edit is allowed only when every
unsupported capability has a known range, untouched preservation is explicitly
proven, and no edited range intersects it. If that proof is unavailable, the
push is refused.

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

## Requirements

- Emacs **29.1+** (uses the built-in `sqlite-*` API for the cookie backend).
- [`request`](https://github.com/tkf/emacs-request) **0.3.2+**.
- `curl` available on `PATH` at runtime. Asynchronous networking invokes
external `curl` subprocesses.

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
`gdocs-auth-function` that pulls credentials from a password manager, the macOS
Keychain, or an OAuth refresh-token flow.

## Usage

| Command               | What it does                                                   |
|-----------------------|----------------------------------------------------------------|
| `gdocs-open`          | Open a Google Docs URL or document ID (or the link at point).  |
| `gdocs-pull-locally`  | Fetch remote content and rewrite the local buffer.             |
| `gdocs-push-remotely` | Push local Org changes back to the remote document.            |
| `gdocs-out-of-date`   | Check whether the remote document has advanced.                |
| `gdocs-mode`          | The Org minor mode that ties pull/push/auto-sync together.     |

Open a document with `M-x gdocs-open` and paste the URL or document ID. The
mode opens (or reuses) a local `.org` buffer named after the document title and
performs an initial pull. `gdocs-mode` auto-enables in any Org buffer that
carries a `GDOC_ID` property, and the mode line shows an indicator while it is
active.

### Buffer metadata

These properties are maintained on the top-level node of every synced buffer:

| Property         | Purpose                                       |
|------------------|-----------------------------------------------|
| `GDOC_ID`        | Identifies the remote document.               |
| `GDOC_TITLE`     | Stores the Google Drive document name. Body `#+title:` keywords remain Title-styled paragraphs and are pushable content. |
| `GDOC_REVISION`  | Staleness anchor — last known remote revision.|
| `GDOC_SYNCED_AT` | Timestamp of the last successful pull or push.|

## Configuration

| Variable                  | Default     | Purpose                                                  |
|---------------------------|-------------|----------------------------------------------------------|
| `gdocs-auth-function`     | `nil`       | Returns the HTTP auth headers (see above). **Required.** |
| `gdocs-push-backend`      | `ot-encode` | Push strategy; see [Push backends](#push-backends).      |
| `gdocs-auto-sync-interval`| `5`         | Seconds between periodic background sync checks.         |
| `gdocs-log-level`         | `warn`      | One of `debug`, `info`, `warn`, `error`.                |
| `gdocs-session-file`      | XDG cache   | Where the persistent `/save` SID + request id are kept. |

## Offline development tests

The conversion and synchronization helpers have an offline ERT suite backed
by sanitized synthetic OT, inline-image, and comments fixtures. It never
contacts Google, reads browser cookies, or mutates user buffers/files:

```sh
make test
```

Run byte-compilation validation with `make byte-compile`, or run both checks
with `make check`. The optional `make integration` target only selects the
`integration` ERT tag after explicitly setting `GDOCS_MODE_RUN_INTEGRATION=1`;
no live credentials or live integration tests are required by this repository.
Byte-compilation writes `gdocs-mode.elc` and `gdocs-mode-test.elc` to a fresh
directory under `$TMPDIR` (or `/tmp`), puts that directory first on the load
path, and removes it on success, failure, or interruption. It never writes
compiled files beside the source files, and `make check` serializes its test
and compilation prerequisites even when invoked with `make -j check`.

## Caveats

- **Cookie-only push.** The write path matches a real browser request and
depends on a live Firefox/OAuth session; there is no hardened credential
story yet.
- **Format fidelity is best-effort.** Headings, paragraphs, inline emphasis,
lists, tables, and code blocks round-trip. Inline images are pull-only
placeholders; downloading, uploading, moving, replacing, and deleting them
through push are unsupported except for safe incremental text edits that prove
the image was left untouched. Comments are pulled as a read-only footnote and
`* Comments` projection, stripped before push, and cannot be edited or pushed.
Suggestions and column layouts remain out of scope.
- **Rate limiting.** Google's `/save` endpoint rejects malformed or
excessively bursty requests; the mode persists a session SID to look like a
single stable client.
