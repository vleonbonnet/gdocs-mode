;;; gdocs-mode.el --- Sync org-mode with Google Docs  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valentin Leon

;; Author: Valentin Leon <valentin@leon.click>
;; Created: 21 May 2026
;; Version: 0.1
;; Keywords: productivity, docs, convenience
;; URL: https://github.com/vleonbonnet/gdocs-mode
;; Package-Requires: ((emacs "29.1") (request "0.3.2"))

;; This file is not part of GNU Emacs.

;; This file is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This file is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this file.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Bidirectional sync between Org mode buffers and Google Docs documents.
;;
;; Pull strategy: decode the /edit page's modelChunk OT stream into a
;; doc-model, then render to org. Cookie-authenticated.
;;
;; Staleness: GDOC_REVISION scraped from the /edit page is the
;; anchor. GDOC_CONTENT_HASH is recorded for human/debug diffing only.
;;
;; Push strategy (v1, lossy): whole-document replace via the cookie-
;; authenticated /save endpoint that the browser uses. Delete the full
;; OT span, insert the buffer body as plain text. Inline formatting,
;; heading levels, lists, tables won't round-trip through push — those
;; need per-run style commands and are deferred to v2. Pull preserves
;; everything; only push is plain-text.
;;
;; Auth is decoupled. Configure `gdocs-auth-function' to return an
;; alist of HTTP headers. Cookie sessions today, OAuth tomorrow.

;;; Code:

(require 'org)
(require 'org-element)
(require 'json)
(require 'request)
(require 'subr-x)
(require 'cl-lib)
(require 'seq)
(require 'url-util)

(defgroup gdocs-mode nil
  "Google Docs integration for Emacs."
  :group 'external)

(defcustom gdocs-auth-function nil
  "Function of no arguments returning an alist of HTTP headers
to attach to every request. Typical return value:
  ((\"Cookie\" . \"SID=...; HSID=...; SSID=...; ...\"))
Future OAuth backends will return:
  ((\"Authorization\" . \"Bearer ya29...\"))
The function is called fresh per request — backends may compute
timestamp-sensitive headers like SAPISIDHASH inside it."
  :type 'function
  :group 'gdocs-mode)

(defcustom gdocs-push-backend 'ot-encode
  "Which strategy to use when pushing local changes.
`plain' diffs the buffer text against the remote OT plain view and
emits `is'/`ds' ops only — no style information is sent. NOT
recommended: Google Docs re-parses literal `*…*' / `~…~' markers in
plain-text inserts and re-anchors styling at sub-token boundaries,
causing visible drift on round-trip.
`ot-encode' (default) rebuilds the entire doc-model from the buffer
via `gdocs-dm-from-org', emits a full `ds'+`is'+styles command list
via `gdocs-dm-to-save-commands', and ships them in one /save call.
`ot-incremental' decodes the live OT body to a doc-model, computes a
paragraph-level diff against the new doc-model, and emits only the
changed range's ds+is+style ops via
`gdocs-dm-to-incremental-save-commands'. Falls back to ot-encode if
the diff includes list or table paragraphs (entity-id rewrite limit)."
  :type '(choice (const :tag "Plain text diff" plain)
                 (const :tag "OT encode (full replace + styles)" ot-encode)
                 (const :tag "OT incremental (paragraph diff)" ot-incremental))
  :group 'gdocs-mode)

(defcustom gdocs-auto-sync-interval 5
  "Idle interval in seconds for background pull checks."
  :type 'integer
  :group 'gdocs-mode)

(defcustom gdocs-log-level 'warn
  "Logging level for gdocs operations.
Default `warn' keeps *Messages* quiet during normal pull/push; set to
`info' or `debug' to trace requests."
  :type '(choice (const :tag "Debug" debug)
                 (const :tag "Info" info)
                 (const :tag "Warning" warn)
                 (const :tag "Error" error))
  :group 'gdocs-mode)

(defcustom gdocs-default-user-agent
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:138.0) Gecko/20100101 Firefox/138.0"
  "User-Agent header sent with every request."
  :type 'string
  :group 'gdocs-mode)

(defconst gdocs--export-base "https://docs.google.com/document/d/")

(defvar-local gdocs--sync-timer nil
  "Idle timer for auto-sync in this buffer.")

(defvar gdocs--sync-mutex nil
  "Global mutex for sync operations.")

(defvar-local gdocs--last-synced-hash nil
  "SHA-256 of the buffer body (sans top property drawer and #+title
line) at the moment of the last successful pull or push. Used by
`gdocs--auto-sync-tick' to detect unsynced local edits without relying
on `buffer-modified-p' (which is unreliable in temp/indirect buffers
and not set when content is inserted programmatically).")


;;; Logging

(defun gdocs-log (level format-string &rest args)
  "Log message at LEVEL."
  (let ((priorities '((debug . 1) (info . 2) (warn . 3) (error . 4))))
    (when (>= (cdr (assq level priorities))
              (cdr (assq gdocs-log-level priorities)))
      (message "GDocs [%s] %s"
               (upcase (symbol-name level))
               (apply #'format format-string args)))))


;;; HTTP layer

(defun gdocs--auth-headers ()
  "Resolve auth headers via `gdocs-auth-function'."
  (unless (functionp gdocs-auth-function)
    (user-error "gdocs-auth-function is not configured"))
  (or (funcall gdocs-auth-function)
      (user-error "gdocs-auth-function returned no headers")))

(defun gdocs--make-request (url method &optional data parser)
  "Make HTTP request. PARSER defaults to `json-read'.
Suppresses url.el's `Contacting host:' progress messages and
request.el's chatty backend logs so *Messages* stays clean."
  (let ((response-data nil)
        (error-info nil)
        (parser (or parser 'json-read))
        (url-show-status nil)
        (request-message-level -1)
        (request-log-level -1))
    (request url
      :type method
      :headers (append `(("Content-Type" . "application/json; charset=utf-8")
                         ("User-Agent" . ,gdocs-default-user-agent)
                         ("Referer" . "https://docs.google.com/"))
                       (gdocs--auth-headers))
      :data (when data (encode-coding-string (json-encode data) 'utf-8))
      :parser parser
      :encoding 'utf-8
      :sync t
      :success (cl-function
                (lambda (&key data &allow-other-keys)
                  (setq response-data data)))
      :error (cl-function
              (lambda (&key error-thrown symbol-status response &allow-other-keys)
                (setq error-info
                      (list :error error-thrown
                            :status symbol-status
                            :code (and response (request-response-status-code response))
                            :body (and response (request-response-data response)))))))
    (when error-info
      (error "GDocs request failed: %s (status %s, code %s) body=%s"
             (plist-get error-info :error)
             (plist-get error-info :status)
             (plist-get error-info :code)
             (let ((b (plist-get error-info :body)))
               (if (stringp b) (substring b 0 (min 200 (length b))) b))))
    response-data))


;;; ID / URL parsing

(defun gdocs--extract-doc-id (input)
  "Pull a doc id out of INPUT, which may be an id, URL, or org link."
  (cond
   ((null input) nil)
   ((string-match "/document/d/\\([A-Za-z0-9_-]+\\)" input)
    (match-string 1 input))
   ((string-match "^[A-Za-z0-9_-]\\{20,\\}$" input)
    input)
   (t input)))

(defun gdocs--doc-id-from-buffer ()
  "Return GDOC_ID from current buffer's top-level node, or nil."
  (and (derived-mode-p 'org-mode)
       (org-entry-get (point-min) "GDOC_ID" t)))

(defun gdocs--get-doc-id (&optional doc-id)
  "Resolve DOC-ID, or fall back to buffer property, link at point, or prompt."
  (or (and doc-id (gdocs--extract-doc-id doc-id))
      (gdocs--doc-id-from-buffer)
      (let* ((ctx (and (derived-mode-p 'org-mode) (org-element-context)))
             (link (and ctx (eq (org-element-type ctx) 'link)
                        (org-element-property :raw-link ctx))))
        (and link (gdocs--extract-doc-id link)))
      (gdocs--extract-doc-id (read-string "Google Docs URL or ID: "))))


;;; Metadata

(defun gdocs--now-iso ()
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun gdocs--put-top-property (key value)
  "Set KEY=VALUE on the top-level org node."
  (save-excursion
    (goto-char (point-min))
    (org-entry-put (point-min) key value)))

(defun gdocs--update-top-metadata (title revision)
  "Write title (as #+title) and revision/timestamp properties."
  (save-excursion
    (when title
      (goto-char (point-min))
      (if (re-search-forward "^#\\+title:.*$" nil t)
          (replace-match (format "#+title: %s" title) t t)
        (goto-char (point-min))
        (when (looking-at org-property-drawer-re)
          (goto-char (match-end 0))
          (forward-line))
        (insert (format "#+title: %s\n" title))))
    (when revision
      (gdocs--put-top-property "GDOC_REVISION" revision))
    (gdocs--put-top-property "GDOC_SYNCED_AT" (gdocs--now-iso))))

;;; Out-of-date check

(defun gdocs-out-of-date (&optional doc-id)
  "Return non-nil if remote differs from local anchor.
Compares GDOC_REVISION against the revision scraped from the /edit
page. Returns nil when either side has no revision (caller should
pull rather than guess)."
  (interactive)
  (let* ((doc-id (gdocs--get-doc-id doc-id))
         (state (gdocs--fetch-edit-state doc-id))
         (remote-rev (plist-get state :revision))
         (local-rev (org-entry-get (point-min) "GDOC_REVISION" t))
         (different
          (and remote-rev local-rev (not (string-empty-p local-rev))
               (not (string= local-rev (number-to-string remote-rev))))))
    (when (called-interactively-p 'any)
      (message "GDocs %s: %s" doc-id (if different "out-of-date" "current")))
    different))


(defun gdocs--inline-comment-refs (org-body ot-body anchor-map comments)
  "Insert `[fn:N]' refs into ORG-BODY at each comment's anchor position.
ANCHOR-MAP is the alist (KIX-ID . (SI . EI)) returned by
`gdocs--decode-doco-anchors'. COMMENTS is the list returned by
`gdocs--parse-docos-sync-response'. Only the first comment per anchor
gets an inline ref — replies share the thread anchor and listing them
all inline would clutter the prose. The ref lands at the end of the
anchored span; a unique-match check skips placement when the context is
ambiguous (an extra reply [fn:N+1] showing up inline is harmless but
wrong)."
  (let* ((plain+map (gdocs--ot-plain-and-map ot-body))
         (plain (car plain+map))
         (map (cdr plain+map))
         (ot->plain (let ((tbl (make-hash-table :test 'eql)))
                      (dotimes (j (length map))
                        (puthash (aref map j) j tbl))
                      tbl))
         (seen (make-hash-table :test 'equal))
         (placements nil))
    (dolist (c comments)
      (let* ((n (car c))
             (anchor (plist-get (cdr c) :anchor))
             (rng (and anchor (cdr (assoc anchor anchor-map))))
             (ei (cdr-safe rng)))
        (when (and rng (not (gethash anchor seen)))
          (puthash anchor t seen)
          ;; EI is the OT position one past the last anchored codepoint.
          ;; Walk back until a mapped plain index is found (structural
          ;; codepoints in OT have no plain counterpart, so a few EI
          ;; values land on nothing — skip past them).
          (let ((probe (1- ei)) (plain-end nil))
            (while (and (>= probe 1) (not plain-end))
              (let ((j (gethash probe ot->plain)))
                (when j (setq plain-end (1+ j))))
              (cl-decf probe))
            (when plain-end
              (push (list :n n :plain-end plain-end) placements))))))
    (setq placements
          (sort placements (lambda (a b)
                             (> (plist-get a :plain-end)
                                (plist-get b :plain-end)))))
    (with-temp-buffer
      (insert org-body)
      (dolist (pl placements)
        (let* ((pe (plist-get pl :plain-end))
               (n (plist-get pl :n))
               (full-context (substring plain 0 pe))
               ;; Walk back through candidate context windows, shortest
               ;; first, expanding until we get a unique match. Min 4 chars
               ;; (otherwise a single word fragment matches everywhere);
               ;; max 64 chars (longer doesn't help and risks spanning
               ;; structural boundaries the org body re-renders differently).
               (found nil))
          (catch 'placed
            (dolist (window-len '(8 12 16 24 32 48 64))
              (when (and (not found) (>= (length full-context) (min 4 window-len)))
                (let* ((wl (min window-len (length full-context)))
                       (context (substring full-context (- (length full-context) wl)))
                       (re (gdocs--inline-ref-context-re context))
                       (last nil) (count 0))
                  (goto-char (point-min))
                  (while (re-search-forward re nil t)
                    (cl-incf count)
                    (setq last (match-end 0)))
                  (when (= count 1)
                    (setq found t)
                    (goto-char last)
                    ;; Walk past any trailing emphasis markers so the
                    ;; `[fn:N]' lands outside `~text~' or `*text*' rather
                    ;; than inside (which would alter the styled span).
                    (while (and (< (point) (point-max))
                                (memq (char-after) '(?* ?~ ?/ ?_ ?+ ?=)))
                      (forward-char 1))
                    (insert (format "[fn:%d]" n))
                    (throw 'placed t)))))
            (gdocs-log 'debug "inline-ref fn:%d: no unique match (plain-end %d) — skipped"
                       n pe))))
      (buffer-string))))

(defun gdocs--inline-ref-context-re (context)
  "Build a relaxed regex from CONTEXT (OT-plain substring) for matching
inside the rendered org body. Allows:
- Inline emphasis markers (`*~=/_+`) between any two plain chars (the
  body wraps styled runs with these; OT plain does not).
- Optional heading/list line prefixes after each `\\n' (paragraph
  break).
- Whitespace between consecutive whitespace chars."
  (let* ((emph "[*~=/_+]*")
         (line-prefix
          (concat emph
                  "\n"
                  emph
                  "\\(?:\\*+ \\|[ \t]*[-+*] \\|[ \t]*[0-9]+[.)] \\)?"
                  emph))
         (piece->re
          (lambda (s)
            (mapconcat (lambda (c) (regexp-quote (string c)))
                       (string-to-list s)
                       emph))))
    (mapconcat piece->re (split-string context "\n") line-prefix)))

(defun gdocs--normalize-comment-text (s)
  "Normalize a comment body for rendering: NBSPs become regular spaces,
runs of horizontal whitespace collapse to one space. Newlines are
preserved so multi-paragraph comments stay readable. Google Docs'
WYSIWYG editor often injects NBSPs (e.g. via paste from elsewhere or
autocorrect after sentence-ending punctuation); they're indistinguishable
from regular spaces visually but render as `?\\xa0 ' (NBSP + space)
that looks like a stray double space in Emacs."
  (let ((out (or s "")))
    (setq out (replace-regexp-in-string "[ \t ]+" " " out))
    (string-trim out)))

(defun gdocs--render-comments-section (comments)
  "Format COMMENTS as a trailing `* Comments' subtree.

COMMENTS is the list returned by `gdocs--parse-docos-sync-response':
each entry is (N :text TEXT :anchor KIX-ID). The heading carries
`:GDOC_LOCAL: t' so `gdocs--buffer-body-as-plain' can strip it before
push (Google holds the canonical comments; the section is a read-only
projection)."
  (concat
   "\n* Comments\n"
   ":PROPERTIES:\n:GDOC_LOCAL: t\n:END:\n\n"
   (mapconcat
    (lambda (c)
      ;; Org footnote definition. `C-c C-c' on the inline `[fn:N]'
      ;; ref jumps here; `C-c C-c' here jumps back. Idiomatic org —
      ;; no `<<target>>' clutter.
      (format "[fn:%d] %s\n"
              (car c)
              (gdocs--normalize-comment-text
               (plist-get (cdr c) :text))))
    (sort comments :key #'car)
    "")))

;;; Public commands — pull

(defun gdocs--parse-model-chunks-raw (html)
  "Iterate every `DOCS_modelChunk = …' assignment in HTML and return a
list of (CHUNK-OPS . REVISION) pairs in document order. Large docs are
split across multiple chunks; reading only the first under-reports both
the body and the ops stream."
  (when html
    (let (out)
      (with-temp-buffer
        (insert html)
        (goto-char (point-min))
        (while (re-search-forward "DOCS_modelChunk[ \t]*=[ \t]*" nil t)
          (condition-case _
              (let* ((json-array-type 'list)
                     (json-object-type 'alist)
                     (obj (json-read))
                     (chunk (cdr (assq 'chunk obj)))
                     (revision (cdr (assq 'revision obj))))
                (when chunk
                  (push (cons chunk revision) out)))
            (error nil))))
      (nreverse out))))

(defun gdocs--parse-model-chunk (html)
  "Extract the OT model from a /edit page HTML response.
Returns a plist (:ot-body STR :revision N) or nil if not found.

Google's editor boots by parsing JS object literals assigned to
`DOCS_modelChunk' inside inline <script>s. Large docs split the model
across multiple chunks; we concatenate every `is' op's `s' field across
all chunks to recover the full OT body.

Every character of an `is' op's `s' string occupies exactly one position
in Google's OT index space. That includes control bytes \\u0010..\\u001F
which Google emits as structural markers (table open, row, cell, list
start, list close, …). The export text strips them, so text-position ≠
OT-position for any doc with structure."
  (let ((chunks (gdocs--parse-model-chunks-raw html)))
    (when chunks
      (let ((body "") (rev nil))
        (dolist (entry chunks)
          (let ((chunk (car entry)) (chunk-rev (cdr entry)))
            (when (and chunk-rev (or (null rev) (> chunk-rev rev)))
              (setq rev chunk-rev))
            (dolist (op chunk)
              (when (and (listp op) (equal (cdr (assq 'ty op)) "is")
                         (stringp (cdr (assq 's op))))
                (setq body (concat body (cdr (assq 's op))))))))
        (when (length> body 0)
          (list :ot-body body :revision rev))))))

(defun gdocs--parse-model-chunk-full (html)
  "Like `gdocs--parse-model-chunk' but returns the entire op stream
across every chunk in HTML.

Returns a plist `(:revision N :ops (OP1 OP2 …))' or nil. Each op is the
raw alist from `json-read', so all attributes are preserved — this is
the recon entry point for learning what op shapes Google uses for
styling, headings, lists, tables, and code blocks."
  (let ((chunks (gdocs--parse-model-chunks-raw html)))
    (when chunks
      (let (ops (rev nil))
        (dolist (entry chunks)
          (let ((chunk (car entry)) (chunk-rev (cdr entry)))
            (when (and chunk-rev (or (null rev) (> chunk-rev rev)))
              (setq rev chunk-rev))
            (setq ops (nconc ops (copy-sequence chunk)))))
        (when ops (list :revision rev :ops ops))))))

(defun gdocs--recon-op-types (ops)
  "Return alist (TY . COUNT) summarising op type frequencies in OPS."
  (let ((counts (make-hash-table :test 'equal)))
    (dolist (op ops)
      (let ((ty (cdr (assq 'ty op))))
        (puthash ty (1+ (gethash ty counts 0)) counts)))
    (let (result)
      (maphash (lambda (k v) (push (cons k v) result)) counts)
      (sort result (lambda (a b) (> (cdr a) (cdr b)))))))

(defun gdocs--recon-attribute-keys (ops)
  "Return alist (TY . (ATTR1 ATTR2 …)) of all attribute keys observed
per op type, so we can see at a glance what fields each op carries."
  (let ((per-ty (make-hash-table :test 'equal)))
    (dolist (op ops)
      (let* ((ty (cdr (assq 'ty op)))
             (keys (mapcar #'car op))
             (seen (gethash ty per-ty)))
        (dolist (k keys)
          (unless (memq k seen) (push k seen)))
        (puthash ty seen per-ty)))
    (let (result)
      (maphash (lambda (k v) (push (cons k (sort v :lessp #'string<)) result))
               per-ty)
      (sort result (lambda (a b) (string< (car a) (car b)))))))

(defun gdocs-recon-dump (doc-id)
  "Fetch DOC-ID's /edit page, parse the full modelChunk, and dump it.

Writes the full op stream to `/tmp/gdocs-recon-DOC-ID.eld' as a
pretty-printed elisp form and prints a short summary (op type counts
+ attribute keys per type) to *Messages*. Read-only — does not modify
the doc or any buffer. The caller's `gdocs-auth-function' is used."
  (interactive "sDoc ID: ")
  (let* ((html (gdocs--fetch-edit-page-sync doc-id))
         (full (gdocs--parse-model-chunk-full html))
         (revision (plist-get full :revision))
         (ops (plist-get full :ops))
         (out (format "/tmp/gdocs-recon-%s.eld" doc-id))
         (summary-out (format "/tmp/gdocs-recon-%s-summary.eld" doc-id))
         (type-counts (gdocs--recon-op-types ops))
         (attr-keys (gdocs--recon-attribute-keys ops)))
    (with-temp-file out
      (let ((print-length nil)
            (print-level nil))
        (pp `(:revision ,revision :n-ops ,(length ops) :ops ,ops)
            (current-buffer))))
    (with-temp-file summary-out
      (let ((print-length nil) (print-level nil))
        (pp `(:revision ,revision
              :n-ops ,(length ops)
              :type-counts ,type-counts
              :attr-keys ,attr-keys)
            (current-buffer))))
    (message "gdocs-recon: rev=%S ops=%d types=%S → %s"
             revision (length ops) type-counts out)
    (list :revision revision :n-ops (length ops)
          :type-counts type-counts :dump out :summary summary-out)))

(defun gdocs--fetch-edit-page-sync (doc-id)
  "Synchronous fetch of /edit page for recon. Bypasses the async paths."
  (let ((url (format "%s%s/edit" gdocs--export-base doc-id)))
    (gdocs--make-request url "GET" nil 'buffer-string)))

;;; Phase A.1 — Doc-model schema
;;
;; A "doc-model" is the lossy-but-faithful intermediate representation we
;; decode from Google Docs' OT op stream and from which we render org. It's a
;; plist with a list of paragraph plists. Each paragraph has a :kind, optional
;; structural attributes (heading level, list binding, anchor) and a list of
;; runs. Each run is a (:text :styles :link) plist.
;;
;; DOC   = (:revision N :doc-id S :title S :paragraphs (PARA ...) :lists ALIST)
;; PARA  = (:kind :para|:heading|:title|:subtitle|:blank|:list|:code|:table
;;          :level N         ; heading level 1..5 (only for :heading)
;;          :list-id S       ; list entity id (only for :list)
;;          :nest N          ; list nesting 0..8 (only for :list)
;;          :glyph :bullet|:number  ; resolved from list def (only for :list)
;;          :anchor S        ; ps_hdid (only for headings)
;;          :runs (RUN ...))
;; RUN   = (:text S :styles (:bold :italic :underline :strike :code) :link S)
;;
;; Tables are represented as a single :kind=:table paragraph whose :rows is a
;; list of rows; each row is a list of cells; each cell is a list of runs.

(defun gdocs-dm-make-doc (&rest props)
  "Construct a doc-model. PROPS is a plist of :revision :doc-id :title
:paragraphs :lists."
  (let ((doc (list :paragraphs nil :lists nil)))
    (cl-loop for (k v) on props by #'cddr
             do (setq doc (plist-put doc k v)))
    doc))

(defsubst gdocs-dm-paragraphs (doc) (plist-get doc :paragraphs))
(defsubst gdocs-dm-lists (doc) (plist-get doc :lists))
(defsubst gdocs-dm-revision (doc) (plist-get doc :revision))
(defsubst gdocs-dm-title (doc) (plist-get doc :title))

(defun gdocs-dm-make-run (text &optional styles link)
  "Build a run with TEXT and optional STYLES (list of keywords) and LINK."
  (let ((r (list :text text)))
    (when styles (setq r (plist-put r :styles styles)))
    (when link (setq r (plist-put r :link link)))
    r))

(defun gdocs-dm-runs-text (runs)
  "Return the concatenated text of RUNS (ignoring styles)."
  (mapconcat (lambda (r) (or (plist-get r :text) "")) runs ""))

(defun gdocs-dm-pp (doc &optional buffer-name)
  "Pretty-print DOC into BUFFER-NAME (default *gdocs-doc-model*) and return it."
  (let ((buf (get-buffer-create (or buffer-name "*gdocs-doc-model*"))))
    (with-current-buffer buf
      (erase-buffer)
      (emacs-lisp-mode)
      (let ((print-length nil) (print-level nil))
        (pp doc (current-buffer))))
    buf))

;;; Phase A.2 — modelChunk → doc-model decoder

(defconst gdocs--ot-table-open  #x10)
(defconst gdocs--ot-table-close #x11)
(defconst gdocs--ot-row-end     #x12)
(defconst gdocs--ot-cell-end    #x1c)

(defun gdocs--sm-bool (sm key)
  "Return t if KEY is set to t in SM, nil if explicitly cleared
\(:json-false), or `unset' if absent."
  (let ((v (alist-get key sm 'unset)))
    (cond ((eq v t) t)
          ((eq v :json-false) nil)
          (t 'unset))))

(defun gdocs--styles-from-text-sm (sm)
  "Convert a text-style SM to a plist of (:bold/:italic/.../ :code) flags
plus optional :clears flag plist."
  (let (out)
    (pcase (gdocs--sm-bool sm 'ts_bd)
      ('t (setq out (plist-put out :bold t)))
      ('nil (setq out (plist-put out :bold nil))))
    (pcase (gdocs--sm-bool sm 'ts_it)
      ('t (setq out (plist-put out :italic t)))
      ('nil (setq out (plist-put out :italic nil))))
    (pcase (gdocs--sm-bool sm 'ts_un)
      ('t (setq out (plist-put out :underline t)))
      ('nil (setq out (plist-put out :underline nil))))
    (pcase (gdocs--sm-bool sm 'ts_st)
      ('t (setq out (plist-put out :strike t)))
      ('nil (setq out (plist-put out :strike nil))))
    (let ((ff (alist-get 'ts_ff sm 'unset)))
      ;; Font family is our channel for distinguishing inline `=verbatim='
      ;; from `~code~' — Google Docs has only one inline-code style, but
      ;; the font dimension is preserved across round-trips. We pick a
      ;; specific monospace name per org marker on push (see
      ;; `gdocs--sm-text-explicit') and decode it back here.
      (cond
       ((and (stringp ff) (string-match-p "Courier" ff))
        (setq out (plist-put out :verbatim t))
        (setq out (plist-put out :code nil)))
       ((and (stringp ff) (string-match-p "Mono" ff))
        (setq out (plist-put out :code t))
        (setq out (plist-put out :verbatim nil)))
       ((eq ff :json-false)
        (setq out (plist-put out :code nil))
        (setq out (plist-put out :verbatim nil)))))
    out))

(defun gdocs--styles-apply (cur new)
  "Layer NEW onto CUR. Both are style plists; NEW's keys override."
  (let ((merged (copy-sequence cur)))
    (cl-loop for (k v) on new by #'cddr
             do (setq merged (plist-put merged k v)))
    merged))

(defun gdocs--styles-active-keys (s)
  "Return the sorted list of style keys with truthy values in plist S."
  (let (keys)
    (cl-loop for (k v) on s by #'cddr
             when v do (push k keys))
    (sort keys (lambda (a b) (string< (symbol-name a) (symbol-name b))))))

(defun gdocs--decode-text-styles (ops body-len)
  "Build a vector of length BODY-LEN of per-char style plists. Op ranges
are 1-based inclusive (OT positions), so OT pos i → vec[i-1]."
  (let ((vec (make-vector body-len nil)))
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "text"))
        (let* ((si (alist-get 'si op))
               (ei (alist-get 'ei op))
               (sm (alist-get 'sm op))
               (styles (gdocs--styles-from-text-sm sm)))
          (when (and (integerp si) (integerp ei) (<= si ei))
            (cl-loop for i from (max 1 si) to (min ei body-len)
                     do (aset vec (1- i)
                              (gdocs--styles-apply (aref vec (1- i)) styles)))))))
    vec))

(defun gdocs--decode-para-attrs (ops)
  "Walk paragraph-style ops; return an alist OT-POS → (:heading N
:anchor S :indent-left X :indent-first X :align V)."
  (let (out)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "paragraph"))
        (let* ((si (alist-get 'si op))
               (sm (alist-get 'sm op))
               (cell (assq si out))
               (cur (cdr cell))
               (hd  (alist-get 'ps_hd sm))
               (hdid (alist-get 'ps_hdid sm))
               (il  (alist-get 'ps_il sm))
               (ifl (alist-get 'ps_ifl sm))
               (al  (alist-get 'ps_al sm)))
          (when (integerp hd) (setq cur (plist-put cur :heading hd)))
          (when (stringp hdid) (setq cur (plist-put cur :anchor hdid)))
          (when (numberp il)  (setq cur (plist-put cur :indent-left il)))
          (when (numberp ifl) (setq cur (plist-put cur :indent-first ifl)))
          (when (integerp al) (setq cur (plist-put cur :align al)))
          (if cell (setcdr cell cur) (push (cons si cur) out)))))
    out))

(defun gdocs--decode-list-bindings (ops)
  "Walk list-style ops; return alist OT-POS → (:list-id S :nest N)."
  (let (out)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "list"))
        (let* ((si (alist-get 'si op))
               (sm (alist-get 'sm op))
               (id (alist-get 'ls_id sm))
               (nest (or (alist-get 'ls_nest sm) 0)))
          (when (stringp id)
            (push (cons si (list :list-id id :nest nest)) out)))))
    out))

(defun gdocs--decode-table-attrs (ops)
  "Walk table-style ops; return alist OT-POS → (:table-id S :cols N)."
  (let (out)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "tbl"))
        (let* ((si (alist-get 'si op))
               (sm (alist-get 'sm op))
               (id (alist-get 'tbls_tblid sm))
               (cols (alist-get 'tbls_cols sm))
               (col-cv (alist-get 'cv cols))
               (col-vec (alist-get 'opValue col-cv))
               (ncols (length col-vec)))
          (push (cons si (list :table-id id :cols ncols)) out))))
    out))

(defun gdocs--decode-list-defs (ops)
  "Collect ae list entity defs. Return alist (LIST-ID . NESTS) where
NESTS is alist N → (:gt N :gs S :gf S)."
  (let (defs)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "ae")
                 (equal (alist-get 'et op) "list"))
        (let* ((id (alist-get 'id op))
               (epm (alist-get 'epm op))
               (le-nb (alist-get 'le_nb epm))
               (nests
                (cl-loop for (sym . body) in le-nb
                         for name = (and (symbolp sym) (symbol-name sym))
                         for n = (and name
                                      (string-match "^nl_\\([0-9]+\\)$" name)
                                      (string-to-number (match-string 1 name)))
                         when n collect
                         (cons n (list :gt (alist-get 'b_gt body)
                                       :gs (alist-get 'b_gs body)
                                       :gf (alist-get 'b_gf body))))))
          (push (cons id nests) defs))))
    (nreverse defs)))

(defun gdocs--decode-doco-anchors (ops)
  "Extract comment anchors from OPS. Returns an alist (KIX-ID . (SI . EI)).
Comments are anchored via `as st=\"doco_anchor\"' ops whose
`sm.das_a.cv' carries `op=set' and `opValue=[\"kix.<id>\"]'. The JSON
serialises `opValue' as a single-element array, so the decoded value is
a one-element list (or, defensively, a bare string). `op=unset' /
absent opValue clears an anchor and is skipped."
  (let (out)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "doco_anchor"))
        (let* ((si (alist-get 'si op))
               (ei (alist-get 'ei op))
               (sm (alist-get 'sm op))
               (das-a (alist-get 'das_a sm))
               (cv (alist-get 'cv das-a))
               (op-kind (alist-get 'op cv))
               (val (alist-get 'opValue cv))
               (id (cond
                    ((stringp val) val)
                    ((and (listp val) (stringp (car val))) (car val)))))
          (when (and (equal op-kind "set") id
                     (integerp si) (integerp ei))
            (push (cons id (cons si ei)) out)))))
    (nreverse out)))

(defun gdocs--list-glyph-kind (defs list-id nest)
  "Look up list LIST-ID's NEST level in DEFS. Return :bullet or :number."
  (let* ((nests (cdr (assoc list-id defs)))
         (entry (cdr (assq nest nests)))
         (gt (plist-get entry :gt)))
    ;; Per recon: gt=9 → bullet; gt=10/13/15 → numbered.
    (if (eq gt 9) :bullet :number)))

(defun gdocs--build-runs (body ts-vec start end)
  "Slice runs from BODY[START..END-1] using TS-VEC styles. Returns a
list of runs (:text :styles). Skips structural codepoints."
  (let ((runs nil)
        (i start))
    (while (< i end)
      ;; Skip structural codepoints — table markers should not appear in
      ;; ordinary paragraphs but if they do, drop them.
      (while (and (< i end)
                  (memq (aref body i)
                        (list gdocs--ot-table-open gdocs--ot-table-close
                              gdocs--ot-row-end gdocs--ot-cell-end)))
        (setq i (1+ i)))
      (when (< i end)
        (let* ((cur-keys (gdocs--styles-active-keys (aref ts-vec i)))
               (run-start i))
          (cl-loop while (and (< i end)
                              (not (memq (aref body i)
                                         (list gdocs--ot-table-open
                                               gdocs--ot-table-close
                                               gdocs--ot-row-end
                                               gdocs--ot-cell-end)))
                              (equal cur-keys
                                     (gdocs--styles-active-keys (aref ts-vec i))))
                   do (cl-incf i))
          (let ((text (substring body run-start i)))
            (push (gdocs-dm-make-run text cur-keys) runs)))))
    (nreverse runs)))

(defun gdocs--build-table-para (body ts-vec start end table-attr)
  "Construct a :table paragraph from BODY[START..END-1] — the slice
between (but excluding) the 0x10/0x11 markers.

Layout (one row of a 2-cell table):
  0x12 0x1c <cell-text> \\n 0x1c <cell-text> \\n …

0x12 starts a new row; 0x1c starts a new cell within the current row.
Each cell ends with a literal \\n right before the next 0x1c, 0x12, or
0x11 — strip that trailing newline."
  (let ((rows nil) (cells nil) (cell-start nil)
        (i start))
    (cl-flet ((flush-cell
                (upto)
                (let* ((from cell-start)
                       (to (if (and (> upto from)
                                    (= (aref body (1- upto)) ?\n))
                               (1- upto)
                             upto))
                       (runs (gdocs--build-runs body ts-vec from to)))
                  (push (list runs) cells)
                  (setq cell-start nil)))
              (flush-row ()
                (when cells
                  (push (nreverse cells) rows)
                  (setq cells nil))))
      (while (< i end)
        (let ((c (aref body i)))
          (cond
           ((= c gdocs--ot-row-end)
            (when cell-start (flush-cell i))
            (flush-row))
           ((= c gdocs--ot-cell-end)
            (when cell-start (flush-cell i))
            (setq cell-start (1+ i)))))
        (cl-incf i))
      (when cell-start (flush-cell i))
      (flush-row))
    (append (list :kind :table :rows (nreverse rows))
            (when table-attr table-attr))))

(defun gdocs--paragraph-kind (pa lb)
  "Map paragraph attrs PA and list-binding LB to a :kind keyword."
  (cond
   (lb :list)
   ((and pa (eq (plist-get pa :heading) 100)) :title)
   ((and pa (eq (plist-get pa :heading) 101)) :subtitle)
   ((and pa (integerp (plist-get pa :heading))
         (<= 1 (plist-get pa :heading) 5))
    :heading)
   (t :para)))

(defun gdocs--paragraph-is-code-block (runs)
  "Return non-nil if every non-empty run in RUNS is :code-styled."
  (and runs
       (cl-every (lambda (r)
                   (or (string-empty-p (or (plist-get r :text) ""))
                       (memq :code (plist-get r :styles))))
                 runs)))

(defun gdocs--build-para (pa lb ta runs list-defs)
  "Assemble one paragraph plist from attrs."
  (let* ((kind (gdocs--paragraph-kind pa lb))
         (heading (and pa (plist-get pa :heading)))
         (anchor (and pa (plist-get pa :anchor)))
         (list-id (and lb (plist-get lb :list-id)))
         (nest (or (and lb (plist-get lb :nest)) 0))
         (glyph (and lb (gdocs--list-glyph-kind list-defs list-id nest)))
         (out (list :kind kind :runs runs)))
    (when (and (eq kind :heading) heading)
      (setq out (plist-put out :level heading)))
    (when (and anchor (memq kind '(:heading :title :subtitle)))
      (setq out (plist-put out :anchor anchor)))
    (when (eq kind :list)
      (setq out (plist-put out :list-id list-id))
      (setq out (plist-put out :nest nest))
      (setq out (plist-put out :glyph glyph)))
    (when (and (eq kind :para) (gdocs--paragraph-is-code-block runs))
      (setq out (plist-put out :kind :code)))
    (when ta
      (setq out (plist-put out :table-id (plist-get ta :table-id)))
      (setq out (plist-put out :cols (plist-get ta :cols))))
    (when (null runs)
      (setq out (plist-put out :kind :blank)))
    out))

(defun gdocs-dm-from-ops (revision doc-id title body ops)
  "Decode BODY (the OT body string) + OPS into a doc-model.
REVISION, DOC-ID and TITLE are stored as metadata."
  (let* ((body-len (length body))
         (ts-vec (gdocs--decode-text-styles ops body-len))
         (para-attrs (gdocs--decode-para-attrs ops))
         (list-bindings (gdocs--decode-list-bindings ops))
         (table-attrs (gdocs--decode-table-attrs ops))
         (list-defs (gdocs--decode-list-defs ops))
         (paragraphs nil)
         (i 0))
    (while (< i body-len)
      (let ((c (aref body i)))
        (cond
         ;; Table open: capture body to matching close codepoint.
         ((= c gdocs--ot-table-open)
          (let* ((tpos (1+ i))           ; 1-based OT pos of the 0x10
                 (ta (cdr (assq tpos table-attrs)))
                 (j (1+ i))
                 (depth 1))
            (while (and (< j body-len) (> depth 0))
              (let ((cc (aref body j)))
                (cond
                 ((= cc gdocs--ot-table-open)  (cl-incf depth))
                 ((= cc gdocs--ot-table-close) (cl-decf depth))))
              (cl-incf j))
            ;; j now points 1 past the matching close.
            (push (gdocs--build-table-para body ts-vec (1+ i) (1- j) ta)
                  paragraphs)
            (setq i j)))
         (t
          ;; Find next \n (which terminates this paragraph) or end of body.
          (let* ((nl (or (cl-position ?\n body :start i :end body-len)
                         body-len))
                 (ot-nl-pos (1+ nl))     ; 1-based
                 (pa (cdr (assq ot-nl-pos para-attrs)))
                 (lb (cdr (assq ot-nl-pos list-bindings)))
                 (runs (gdocs--build-runs body ts-vec i nl)))
            (push (gdocs--build-para pa lb nil runs list-defs) paragraphs)
            (setq i (1+ nl)))))))
    (gdocs-dm-make-doc :revision revision :doc-id doc-id :title title
                       :paragraphs (nreverse paragraphs)
                       :lists list-defs)))

;;; Phase A.3 — Doc-model → org renderer

(defconst gdocs--org-style-markers
  '((:bold      . "*")
    (:italic    . "/")
    (:underline . "_")
    (:strike    . "+")
    (:verbatim  . "=")
    (:code      . "~"))
  "Mapping from style keyword to its org inline marker.
Order here matters only for emit-stability of nested wrappers.")

(defun gdocs--escape-org-inline (text)
  "Lightly normalize TEXT for safe inline org emission. Strips OT
structural codepoints just in case."
  (replace-regexp-in-string
   (rx (any 16 17 18 28)) "" text))

(defconst gdocs--org-style-order
  '(:bold :italic :underline :strike :verbatim :code)
  "Outer→inner emit order for style markers.
Non-atomic styles (bold/italic/underline/strike) wrap atomic
verbatim/code so that `*=foo=*' parses as bold-around-verbatim rather
than the reverse (which org would treat as opaque).")

(defun gdocs--render-run-text (run)
  "Render the textual payload of RUN — escape + link wrapping, no styles."
  (let* ((text (or (plist-get run :text) ""))
         (link (plist-get run :link))
         (clean (gdocs--escape-org-inline text)))
    (if link
        (format "[[%s][%s]]" link
                (if (string-empty-p clean) link clean))
      clean)))

(defun gdocs--render-runs (runs)
  "Render a list of RUNS to org text.
Adjacent runs that share a style are wrapped by a single emphasis pair
rather than per-run pairs, so `(bold)(bold code)(bold)' renders as
`*A~B~C*' instead of `*A**~B~**C*'."
  (gdocs--render-runs-styled runs nil))

(defun gdocs--render-runs-styled (runs already-wrapped)
  "Inner driver for `gdocs--render-runs'.
ALREADY-WRAPPED is the set of style keys an outer wrapper has already
emitted; we won't re-emit them inside."
  (cl-block done
    (dolist (key gdocs--org-style-order)
      (unless (memq key already-wrapped)
        (when (cl-some (lambda (r) (memq key (plist-get r :styles))) runs)
          (cl-return-from done
            (gdocs--render-runs-split-on key runs already-wrapped)))))
    (mapconcat #'gdocs--render-run-text runs "")))

(defun gdocs--render-runs-split-on (key runs already-wrapped)
  "Group RUNS by whether each carries KEY; wrap KEY-bearing groups."
  (let ((groups nil) (cur nil) (cur-has 'unset))
    (dolist (r runs)
      (let ((has (and (memq key (plist-get r :styles)) t)))
        (cond
         ((eq cur-has 'unset)
          (setq cur (list r) cur-has has))
         ((eq has cur-has)
          (push r cur))
         (t
          (push (cons cur-has (nreverse cur)) groups)
          (setq cur (list r) cur-has has)))))
    (when cur (push (cons cur-has (nreverse cur)) groups))
    (mapconcat
     (lambda (g)
       (let* ((has-key (car g))
              (group-runs (cdr g))
              (inner (gdocs--render-runs-styled
                      group-runs
                      (if has-key (cons key already-wrapped) already-wrapped))))
         (if (and has-key
                  (not (string-empty-p (string-trim inner))))
             (let ((mk (cdr (assq key gdocs--org-style-markers))))
               (format "%s%s%s" mk inner mk))
           inner)))
     (nreverse groups) "")))

(defun gdocs--render-heading-stars (level)
  "Return N stars for heading LEVEL (1..5). Levels >5 are clamped to 5."
  (make-string (min 5 (max 1 level)) ?*))

(defun gdocs--render-list-bullet (glyph nest &optional ordinal)
  "Return the leading bullet text for a list item.
GLYPH is :bullet or :number; NEST is 0-based. ORDINAL is the 1-based
sequence number within the current numbered list at this nest level
\(only used when GLYPH is :number; defaults to 1)."
  (let ((indent (make-string (* 2 (max 0 nest)) ?\s)))
    (concat indent (if (eq glyph :number)
                       (format "%d. " (or ordinal 1))
                     "- "))))

(defun gdocs--render-table-para (para)
  "Render a :kind=:table paragraph to an org-mode table."
  (let* ((rows (plist-get para :rows))
         (lines
          (mapcar
           (lambda (row)
             (concat "| "
                     (mapconcat
                      (lambda (cell)
                        (let* ((para-runs
                                (if (and cell (consp (car cell))
                                         (plist-member (car cell) :text))
                                    cell      ; runs directly
                                  (apply #'append cell))) ; list of run-lists
                               (text (gdocs--render-runs para-runs)))
                          (replace-regexp-in-string "[|\n]" " " text)))
                      row " | ")
                     " |"))
           rows)))
    (string-join lines "\n")))

(defun gdocs--render-paragraph-line (para &optional ordinal)
  "Render PARA to its org line (no trailing newline).
ORDINAL applies to numbered list items only — see `gdocs--render-list-bullet'."
  (let* ((kind (plist-get para :kind))
         (runs (plist-get para :runs))
         (text (gdocs--render-runs runs)))
    (pcase kind
      (:blank "")
      ;; Google Docs distinguishes the doc *name* (metadata, fetched
      ;; from the HTML <title>) from Title-styled body paragraphs. We
      ;; surface the doc name as the first `#+title:' line in the buffer
      ;; wrapper, and each body Title paragraph as an additional
      ;; `#+title:' keyword inline so round-trips preserve both.
      (:title (if (string-empty-p text) ""
                (format "#+title: %s" text)))
      (:subtitle (if (string-empty-p text) ""
                   (format "#+subtitle: %s" text)))
      (:heading
       (let* ((level (or (plist-get para :level) 1))
              (stars (gdocs--render-heading-stars level)))
         (concat stars " " text)))
      (:list
       (let* ((glyph (plist-get para :glyph))
              (nest (or (plist-get para :nest) 0)))
         (concat (gdocs--render-list-bullet glyph nest ordinal) text)))
      (:code text)
      (:table (gdocs--render-table-para para))
      (_ text))))

(defun gdocs--org-heading-line-p (line)
  "Non-nil if LINE needs blank-line padding before and after.
Matches both `* heading' lines and body-level `#+title:'/`#+subtitle:'
keyword lines emitted from Title/Subtitle paragraphs."
  (and (stringp line)
       (or (string-match-p "\\`\\*+ " line)
           (string-match-p "\\`#\\+title:" line)
           (string-match-p "\\`#\\+subtitle:" line))))

(defun gdocs-dm-to-org (doc)
  "Render a doc-model DOC to an org-mode string.

Code blocks: contiguous :kind=:code paragraphs are wrapped in a single
\#+begin_src/#+end_src block. Lists, headings, tables and plain
paragraphs each emit one line (terminated by \\n). A blank line is
inserted before and after each heading so the result reads as
idiomatic org."
  (let ((paras (gdocs-dm-paragraphs doc))
        (out nil)
        (in-code nil)
        (list-counters (make-vector 10 0))
        (last-list-id nil))
    (dolist (p paras)
      (let ((kind (plist-get p :kind)))
        ;; Reset numbered-list counters whenever we leave a list. A new
        ;; list (different :list-id) also resets them on entry below.
        (unless (eq kind :list)
          (fillarray list-counters 0)
          (setq last-list-id nil))
        (cond
         ((eq kind :code)
          (unless in-code
            (push "#+begin_src text" out)
            (setq in-code t))
          (push (mapconcat (lambda (r) (or (plist-get r :text) ""))
                           (plist-get p :runs) "")
                out))
         (t
          (when in-code
            (push "#+end_src" out)
            (setq in-code nil))
          (let ((ordinal nil))
            (when (and (eq kind :list)
                       (eq (plist-get p :glyph) :number))
              (let* ((nest (min 9 (max 0 (or (plist-get p :nest) 0))))
                     (list-id (plist-get p :list-id)))
                (unless (equal list-id last-list-id)
                  (fillarray list-counters 0)
                  (setq last-list-id list-id))
                ;; Counters at deeper nest levels reset whenever we step
                ;; back up — re-entering a sublist starts at 1 again.
                (let ((i (1+ nest)))
                  (while (< i (length list-counters))
                    (aset list-counters i 0)
                    (cl-incf i)))
                (aset list-counters nest (1+ (aref list-counters nest)))
                (setq ordinal (aref list-counters nest))))
            (push (gdocs--render-paragraph-line p ordinal) out))))))
    (when in-code (push "#+end_src" out))
    (let* ((lines (nreverse out))
           (padded nil))
      (dolist (line lines)
        (when (and (gdocs--org-heading-line-p line)
                   padded
                   (not (equal (car padded) "")))
          (push "" padded))
        (push line padded)
        (when (gdocs--org-heading-line-p line)
          (push "" padded)))
      (let ((final (nreverse padded)))
        (concat (string-join final "\n")
                (if final "\n" ""))))))

;;; Phase B.1 — org → doc-model parser
;;
;; Walks the parse tree produced by `org-element-parse-buffer' and emits a
;; doc-model with the same shape consumed by Phase B.2's OT emitter. Only
;; surface elements we round-trip: headings, paragraphs, plain lists, src
;; blocks, links and the inline emphasis markers. Tables are deferred to
;; Phase C.

(defconst gdocs--org-element-styles
  '((bold          . :bold)
    (italic        . :italic)
    (underline     . :underline)
    (strike-through . :strike)
    (code          . :code)
    (verbatim      . :verbatim))
  "Mapping of `org-element' inline emphasis tags to doc-model style keys.")

(defun gdocs--element-runs (el &optional inherited-styles inherited-link)
  "Walk inline ORG-ELEMENT EL and return a flat list of runs.
INHERITED-STYLES and INHERITED-LINK are inherited from outer wrappers."
  (cond
   ((stringp el)
    (if (string-empty-p el)
        nil
      (list (gdocs-dm-make-run el inherited-styles inherited-link))))
   ((null el) nil)
   ((consp el)
    (let* ((type (and (symbolp (car el)) (car el)))
           (props (and (consp (cdr el)) (cadr el)))
           (contents (cddr el))
           (style (cdr (assq type gdocs--org-element-styles))))
      (cond
       ((eq type 'link)
        (let* ((path (plist-get props :path))
               (kind (plist-get props :type))
               (url (if (member kind '("https" "http" "mailto" "ftp"))
                        (format "%s:%s" kind path)
                      path)))
          (if contents
              (cl-mapcan
               (lambda (c) (gdocs--element-runs c inherited-styles url))
               contents)
            ;; Bare link with no description.
            (list (gdocs-dm-make-run path inherited-styles url)))))
       ((eq type 'plain-text)
        (when (stringp props)
          (list (gdocs-dm-make-run props inherited-styles inherited-link))))
       (style
        (let* ((styles (cons style inherited-styles))
               (runs
                (if (and (memq type '(code verbatim))
                         (stringp (plist-get props :value)))
                    ;; Inline code/verbatim contents come as a single
                    ;; string in :value.
                    (list (gdocs-dm-make-run (plist-get props :value)
                                             styles inherited-link))
                  (cl-mapcan
                   (lambda (c) (gdocs--element-runs c styles inherited-link))
                   contents)))
               ;; Org-element consumes the post-character whitespace
               ;; after the closing marker into the emphasis element
               ;; (so `=foo= bar' parses with the space attached to the
               ;; verbatim, not to "bar"). Re-emit it as a trailing
               ;; unstyled run so the OT body preserves it.
               (post-blank (org-element-property :post-blank el)))
          (if (and (integerp post-blank) (> post-blank 0))
              (append runs
                      (list (gdocs-dm-make-run
                             (make-string post-blank ?\s)
                             inherited-styles inherited-link)))
            runs)))
       (t
        (cl-mapcan
         (lambda (c) (gdocs--element-runs c inherited-styles inherited-link))
         contents)))))))

(defun gdocs--paragraph-content-runs (par)
  "Return the runs of an org `paragraph' element PAR, trimming the
trailing newline that org-element keeps at the end of each paragraph."
  (let ((runs (cl-mapcan
               (lambda (c) (gdocs--element-runs c nil nil))
               (cddr par))))
    ;; Strip a single trailing newline from the last run if present.
    (when runs
      (let* ((tail (last runs))
             (last (car tail))
             (text (or (plist-get last :text) "")))
        (when (and (length> text 0)
                   (= (aref text (1- (length text))) ?\n))
          (setcar tail
                  (plist-put (copy-sequence last) :text
                             (substring-no-properties text 0 -1))))))
    ;; Strip display properties on all run texts for cleaner equality checks.
    (setq runs
          (mapcar (lambda (r)
                    (let ((t1 (plist-get r :text)))
                      (if (stringp t1)
                          (plist-put (copy-sequence r) :text
                                     (substring-no-properties t1))
                        r)))
                  runs))
    ;; Drop empty runs.
    (seq-remove (lambda (r) (string-empty-p (or (plist-get r :text) "")))
                  runs)))

(defun gdocs--org-headline-runs (hl)
  "Return runs for a headline element HL by parsing its :raw-value
\(simpler than walking the title's parsed structure since org-element
sometimes lifts inline children up into the headline)."
  (let ((raw (plist-get (cadr hl) :raw-value)))
    (when (and raw (not (string-empty-p raw)))
      (with-temp-buffer
        (let ((org-inhibit-startup t)) (insert raw "\n"))
        (org-mode)
        (let* ((tree (org-element-parse-buffer))
               (par (seq-find (lambda (e)
                                  (and (consp e) (eq (car e) 'paragraph)))
                                (cddr tree))))
          (if par (gdocs--paragraph-content-runs par)
            (list (gdocs-dm-make-run raw nil nil))))))))

(defun gdocs--org-item-runs (item)
  "Return runs for a plain-list item ITEM."
  (let ((par (seq-find (lambda (e)
                           (and (consp e) (eq (car e) 'paragraph)))
                         (cddr item))))
    (when par (gdocs--paragraph-content-runs par))))

(defun gdocs--item-glyph (item)
  "Return :bullet or :number based on the item's leading bullet text."
  (let ((bullet (plist-get (cadr item) :bullet)))
    (cond
     ((null bullet) :bullet)
     ((string-match-p "^[0-9]+[.)]" bullet) :number)
     (t :bullet))))

(defun gdocs--item-nest (item)
  "Approximate nest depth from the item's :pre-blank+structure indent."
  ;; org-element doesn't directly expose nest level; infer from
  ;; :structure if available, otherwise from leading indentation.
  (let* ((begin (plist-get (cadr item) :begin))
         (struct (plist-get (cadr item) :structure))
         (indent
          (or (cl-some (lambda (row) (and (eq (car row) begin) (nth 1 row)))
                       struct)
              0)))
    (/ indent 2)))

(defun gdocs--src-block-paragraphs (sb)
  "Split a src-block's :value into a list of :code paragraphs."
  (let* ((val (or (plist-get (cadr sb) :value) ""))
         (lines (split-string val "\n"))
         ;; org-element appends a trailing \n; drop the trailing empty line.
         (lines (if (and lines (string-empty-p (car (last lines))))
                    (butlast lines)
                  lines)))
    (mapcar (lambda (line)
              (list :kind :code
                    :runs (list (gdocs-dm-make-run line))))
            lines)))

(defun gdocs--org-table-paragraph (table-el)
  "Convert an org-element \='table TABLE-EL into a :kind=:table paragraph.
Each cell becomes (RUNS) — one element holding a list of runs."
  (let* ((rows nil)
         (max-cols 0))
    (dolist (child (cddr table-el))
      (when (and (consp child) (eq (car child) 'table-row))
        (let* ((rtype (plist-get (cadr child) :type))
               (cells nil))
          ;; Skip rule rows (|---+---|) — they carry no content.
          (unless (eq rtype 'rule)
            (dolist (sub (cddr child))
              (when (and (consp sub) (eq (car sub) 'table-cell))
                (let* ((text (string-trim
                              (substring-no-properties
                               (org-element-interpret-data (cddr sub)))))
                       (runs (when (length> text 0)
                               (list (gdocs-dm-make-run text)))))
                  (push (list runs) cells))))
            (let ((row (nreverse cells)))
              (setq max-cols (max max-cols (length row)))
              (push row rows))))))
    (list :kind :table
          :rows (nreverse rows)
          :cols max-cols)))

(defun gdocs--walk-org-element (el)
  "Convert a top-level org-element EL into zero or more paragraphs."
  (pcase (and (consp el) (car el))
    ('headline
     (let* ((props (cadr el))
            (level (plist-get props :level))
            (runs (gdocs--org-headline-runs el))
            (kind :heading)
            (para (list :kind kind :level level :runs runs)))
       (cons para
             (cl-mapcan #'gdocs--walk-org-element (cddr el)))))
    ('section
     (cl-mapcan #'gdocs--walk-org-element (cddr el)))
    ('paragraph
     (let ((runs (gdocs--paragraph-content-runs el)))
       (if runs
           (list (list :kind :para :runs runs))
         (list (list :kind :blank :runs nil)))))
    ('plain-list
     (let ((nest-base nil)
           (cur-glyph nil)
           (cur-id nil)
           (items (seq-filter (lambda (c) (and (consp c) (eq (car c) 'item)))
                                    (cddr el))))
       (mapcar
        (lambda (item)
          (let* ((raw-nest (gdocs--item-nest item))
                 (nest (progn
                         (unless nest-base (setq nest-base raw-nest))
                         (max 0 (- raw-nest (or nest-base 0)))))
                 (glyph (gdocs--item-glyph item)))
            ;; Allocate a fresh list-id whenever the glyph kind changes so
            ;; bullet and numbered runs don't share one `ae list' def
            ;; (which would force both to render with the same marker).
            (unless (and cur-id (eq cur-glyph glyph))
              (setq cur-glyph glyph
                    cur-id (format "kix.l%s"
                                   (substring
                                    (md5 (format "%S-%S-%d" el glyph (random)))
                                    0 12))))
            (list :kind :list
                  :glyph glyph
                  :nest nest
                  :list-id cur-id
                  :runs (gdocs--org-item-runs item))))
        items)))
    ('src-block (gdocs--src-block-paragraphs el))
    ('table (list (gdocs--org-table-paragraph el)))
    ('keyword
     (let* ((props (cadr el))
            (key (and (stringp (plist-get props :key))
                      (downcase (plist-get props :key))))
            (val (plist-get props :value)))
       (cond
        ((equal key "title")
         (list (list :kind :title
                     :runs (when (and val (not (string-empty-p val)))
                             (list (gdocs-dm-make-run val))))))
        ((equal key "subtitle")
         (list (list :kind :subtitle
                     :runs (when (and val (not (string-empty-p val)))
                             (list (gdocs-dm-make-run val))))))
        (t nil))))
    (_ nil)))

(defun gdocs-dm-from-org (org-text)
  "Parse ORG-TEXT (a string) into a doc-model. Drops the property drawer
if present. Inverse of `gdocs-dm-to-org' (lossy for unsupported syntax)."
  (with-temp-buffer
    (let ((org-inhibit-startup t)) (insert org-text))
    (org-mode)
    (goto-char (point-min))
    ;; Skip a leading property drawer (won't round-trip through the model).
    (when (looking-at org-property-drawer-re)
      (let ((inhibit-read-only t))
        (delete-region (match-beginning 0) (match-end 0))
        (when (looking-at "\n") (delete-char 1))))
    (let* ((tree (org-element-parse-buffer))
           (paras (cl-mapcan #'gdocs--walk-org-element (cddr tree))))
      (gdocs-dm-make-doc :revision nil :doc-id nil :title nil
                         :paragraphs paras))))

;;; Phase B.2 — Doc-model → OT op-stream emitter
;;
;; Renders a doc-model into an OT body string + a flat list of as/ae ops
;; that recreate the doc's styling. The simplest push strategy uses this
;; as a full-document replacement: delete the existing body with a `ds'
;; op, insert the new body with an `is' op, then apply the style/entity
;; ops on top.
;;
;; Style-modifier shape: every explicit style key X needs a paired X_i
;; set to :json-false ("explicit, not inherited"); clearing sets X to
;; :json-false too. We model this here so the ops match what Google's
;; editor emits.

(defconst gdocs--ts-style-keymap
  '((:bold      . ts_bd)
    (:italic    . ts_it)
    (:underline . ts_un)
    (:strike    . ts_st)))

(defun gdocs--sm-text-explicit (styles)
  "Build an OT text style-modifier alist that explicitly sets every key
in STYLES (a list of doc-model style keywords) and clears every other
ts_* key."
  (let (sm)
    (dolist (entry gdocs--ts-style-keymap)
      (let* ((dm-key (car entry))
             (ot-key (cdr entry))
             (set? (memq dm-key styles))
             (i-key (intern (concat (symbol-name ot-key) "_i"))))
        (push (cons ot-key (if set? t :json-false)) sm)
        (push (cons i-key :json-false) sm)))
    (cond
     ;; Verbatim and code both render monospace in Google Docs; we use
     ;; the font family as the disambiguator so org markers round-trip.
     ;; "Courier New" pairs with `=verbatim='; "Roboto Mono" pairs with
     ;; `~code~'. See `gdocs--styles-from-text-sm' for the decoder.
     ((memq :verbatim styles)
      (push '(ts_ff_i . :json-false) sm)
      (push '(ts_ff . "Courier New") sm))
     ((memq :code styles)
      (push '(ts_ff_i . :json-false) sm)
      (push '(ts_ff . "Roboto Mono") sm))
     (t
      (push '(ts_ff_i . :json-false) sm)
      (push '(ts_ff . "Arial") sm)))
    (nreverse sm)))

(defun gdocs--style-key-set (run)
  (let ((s (plist-get run :styles)))
    (gdocs--styles-active-keys
     (cl-loop for k in s with out = nil
              do (setq out (plist-put out k t))
              finally return out))))

(defun gdocs--emit-text-style-ops (runs base-pos)
  "Emit `as' text-style ops for each styled RUN starting at BASE-POS
\(1-based)."
  (let ((ops nil) (pos base-pos))
    (dolist (run runs)
      (let* ((text (plist-get run :text))
             (len (length text))
             (styles (gdocs--style-key-set run)))
        (when (and (> len 0) styles)
          (push `((ty . "as") (st . "text")
                  (si . ,pos) (ei . ,(+ pos len -1))
                  (sm . ,(gdocs--sm-text-explicit styles)))
                ops))
        (setq pos (+ pos len))))
    (nreverse ops)))

(defun gdocs--emit-link-style-ops (runs base-pos)
  "Emit `as st=link' ops with inline lnks_link sm for any link-bearing
runs. The URL is carried in `sm.lnks_link.ulnk_url'; no entity-define
op is needed (Google's editor models links as pure style, not as an ae
entity)."
  (let ((ops nil) (pos base-pos))
    (dolist (run runs)
      (let* ((text (plist-get run :text))
             (len (length text))
             (link (plist-get run :link)))
        (when (and link (> len 0))
          (push `((ty . "as") (st . "link")
                  (si . ,pos) (ei . ,(+ pos len -1))
                  (sm . ((lnks_link . ((lnk_type . 0)
                                       (ulnk_url . ,link))))))
                ops))
        (setq pos (+ pos len))))
    (nreverse ops)))

(defun gdocs--emit-paragraph-style-op (kind level anchor pos)
  "Emit an `as' paragraph op at POS for headings/title/subtitle, or nil."
  (let* ((hd (pcase kind
               (:title 100) (:subtitle 101)
               (:heading (and (integerp level) level))
               (_ nil))))
    (when hd
      (let ((sm `((ps_hd . ,hd) (ps_hd_i . :json-false))))
        (when (and anchor (not (string-empty-p anchor)))
          (setq sm (append sm `((ps_hdid . ,anchor)
                                (ps_hdid_i . :json-false)))))
        `((ty . "as") (st . "paragraph") (si . ,pos) (ei . ,pos)
          (sm . ,sm))))))

(defun gdocs--ts-block-canonical ()
  "Return the canonical 24-field text-style block observed live in
both `ae list' per-level `b_ts' and `as st=list' `ls_ts'. The cookie
=/save= endpoint rejects list ops that lack this complete block."
  '((ts_un . :json-false) (ts_un_i . :json-false)
    (ts_sc . :json-false) (ts_it_i . t)
    (ts_fgc2 (hclr_color . "#000000") (clr_type . 0))
    (ts_st_i . t) (ts_bgc2 (hclr_color) (clr_type . 0))
    (ts_fs_i . t) (ts_ff_i . t) (ts_bgc2_i . t)
    (ts_it . :json-false) (ts_va . "nor") (ts_bd_i . t)
    (ts_va_i . t) (ts_fs . 11.0) (ts_ff . "Arial")
    (ts_st . :json-false) (ts_bd . :json-false)
    (ts_fgc2_i . t) (ts_sc_i . t) (ts_tw . 400)))

(defun gdocs--emit-list-style-op (list-id _nest pos)
  "Emit one `as st=list' binding op at OT position POS (1-based, the
paragraph-terminator newline) for LIST-ID. Mirrors the live shape:
`sm' must carry both the canonical `ls_ts' text-style block and the
`ls_id'. Nest level is encoded indirectly via paragraph indent (not
on this op); we always emit at level 0."
  `((ty . "as") (st . "list") (si . ,pos) (ei . ,pos)
    (sm . ((ls_ts . ,(gdocs--ts-block-canonical))
           (ls_id . ,list-id)))))

(defun gdocs--gen-table-id ()
  "Generate a fresh Google-style table id (e.g. `table.abc123def456`)."
  (let* ((chars "abcdefghijklmnopqrstuvwxyz0123456789")
         (n (length chars))
         (out (make-string 12 ?a)))
    (dotimes (i 12)
      (aset out i (aref chars (random n))))
    (concat "table." out)))

(defun gdocs--emit-table-col-attrs (cols)
  "Build the `tbls_cols' opValue alist-list for COLS columns."
  (let ((col '((col_wv . 0.0)
               (col_wt . 1)
               (col_tdt . ((tdt_v . 0)))
               (col_tf  . ((ttf_vn . 0) (ttf_n . ""))))))
    (make-list cols col)))

(defun gdocs--emit-table-body-and-ops (para base-pos)
  "Render a :kind=:table PARA into (BODY-STRING . OPS) starting at
1-based OT position BASE-POS. BODY-STRING does NOT include the
terminating \\n after the 0x11 close — the caller appends that.

OPS contains the tbl `as' op for the table plus any text-style / link
ops for cell content."
  (let* ((rows (plist-get para :rows))
         (cols-spec (plist-get para :cols))
         (cols (or cols-spec
                   (and rows (apply #'max
                                    (mapcar #'length rows)))
                   1))
         (table-id (or (plist-get para :table-id) (gdocs--gen-table-id)))
         (parts nil)
         (pos base-pos)
         (text-ops nil)
         (link-ops nil)
         (table-pos base-pos))
    ;; Open table.
    (push (string gdocs--ot-table-open) parts)
    (setq pos (1+ pos))
    (dolist (row rows)
      ;; Row marker, then cols cells (pad short rows with empty cells).
      (push (string gdocs--ot-row-end) parts)
      (setq pos (1+ pos))
      (let* ((row-cells (or row '()))
             (n (length row-cells))
             (padded (if (< n cols)
                         (append row-cells (make-list (- cols n) nil))
                       (cl-subseq row-cells 0 cols))))
        (dolist (cell padded)
          (push (string gdocs--ot-cell-end) parts)
          (setq pos (1+ pos))
          (let* ((runs (and (consp cell) (car cell)))
                 (cell-text (gdocs-dm-runs-text (or runs nil)))
                 (cell-start pos))
            (when (length> cell-text 0)
              (push cell-text parts)
              (setq text-ops
                    (nconc (nreverse (gdocs--emit-text-style-ops
                                      runs cell-start))
                           text-ops))
              (setq link-ops
                    (nconc (nreverse (gdocs--emit-link-style-ops
                                      runs cell-start))
                           link-ops))
              (setq pos (+ pos (length cell-text))))
            (push "\n" parts)
            (setq pos (1+ pos))))))
    ;; Close table.
    (push (string gdocs--ot-table-close) parts)
    (let* ((body (apply #'concat (nreverse parts)))
           (tbl-op
            `((ty . "as") (st . "tbl") (si . ,table-pos) (ei . ,table-pos)
              (sm . ((tbls_cols . ((cv . ((op . "set")
                                          (opValue . ,(gdocs--emit-table-col-attrs cols))))))
                     (tbls_tblid . ,table-id))))))
      (cons body
            (append (list tbl-op)
                    (nreverse text-ops)
                    (nreverse link-ops))))))

(defun gdocs--collect-list-ids (paragraphs)
  "Return alist (LIST-ID . FIRST-GLYPH) for every list-bound paragraph;
synthesizes an id for paragraphs that don't carry one yet."
  (let (seen)
    (dolist (p paragraphs)
      (when (eq (plist-get p :kind) :list)
        (let ((id (or (plist-get p :list-id)
                      (format "kix.l%s"
                              (substring (md5 (format "%S" p)) 0 12))))
              (glyph (plist-get p :glyph)))
          (unless (assoc id seen)
            (push (cons id glyph) seen)))))
    (nreverse seen)))

(defun gdocs--emit-list-defs (lists)
  "Emit `ae list' definitions covering all 9 nest levels (nl_0..nl_8).

Each per-level alist mirrors the live shape: `b_gf' glyph format,
canonical `b_ts' text-style block, `b_ifl'/`b_il' indents stepped by
36pt per level (18pt first-line offset). For LISTS, each entry is
\(LIST-ID . GLYPH), where GLYPH is :bullet or :number.

Bullet glyphs cycle ●/○/■ across levels; numbered uses no glyph string
\(b_gt=13 already tells the renderer to compute the number)."
  (let ((bullet-glyphs ["●" "○" "■" "●" "○" "■" "●" "○" "■"]))
    (mapcar
     (lambda (entry)
       (let* ((id (car entry))
              (glyph (cdr entry))
              (numbered (eq glyph :number))
              (gt (if numbered 13 9))
              (ts (gdocs--ts-block-canonical))
              (levels
               (cl-loop
                for n from 0 to 8
                collect
                (let* ((b-il (float (* 36 (1+ n))))
                       (b-ifl (float (+ 18 (* 36 n))))
                       (gs (if numbered "" (aref bullet-glyphs n)))
                       (b-gf (format "%%%d%s" n (if numbered "." ""))))
                  (cons (intern (format "nl_%d" n))
                        `((b_gf . ,b-gf)
                          (b_ts . ,ts)
                          (b_ifl . ,b-ifl)
                          (b_gs . ,gs)
                          (b_a . 0)
                          (b_sn . 1)
                          (b_gt . ,gt)
                          (b_il . ,b-il)))))))
         `((ty . "ae") (et . "list") (id . ,id)
           (epm . ((le_nb . ,levels))))))
     lists)))

(defun gdocs-dm-to-ot (doc)
  "Render DOC (a doc-model) to (BODY . OPS) where BODY is the OT body
string and OPS is the list of `ae'/`as' ops needed to recreate styling.
The caller is responsible for `ds' (clear old body) and `is' (insert
BODY at position 1)."
  (let* ((paragraphs (gdocs-dm-paragraphs doc))
         (list-defs (gdocs--collect-list-ids paragraphs))
         (parts nil)
         (pos 1)
         (text-ops nil)
         (para-ops nil)
         (link-ops nil))
    (dolist (p paragraphs)
      (let ((kind (plist-get p :kind)))
        (cond
         ((eq kind :table)
          (let* ((built (gdocs--emit-table-body-and-ops p pos))
                 (tbody (car built))
                 (tops  (cdr built)))
            (push tbody parts)
            (setq pos (+ pos (length tbody)))
            ;; Terminating \n for the table paragraph.
            (push "\n" parts)
            (setq pos (1+ pos))
            (setq para-ops (nconc (nreverse tops) para-ops))))
         (t
          (let* ((runs (plist-get p :runs))
                 (text (gdocs-dm-runs-text runs))
                 (run-base-pos pos))
            (push text parts)
            (setq text-ops
                  (nconc (nreverse (gdocs--emit-text-style-ops
                                    runs run-base-pos))
                         text-ops))
            (setq link-ops
                  (nconc (nreverse (gdocs--emit-link-style-ops runs run-base-pos))
                         link-ops))
            (setq pos (+ pos (length text)))
            (push "\n" parts)
            (let ((nl-pos pos))
              (pcase kind
                ((or :heading :title :subtitle)
                 (let ((op (gdocs--emit-paragraph-style-op
                            kind (plist-get p :level)
                            (plist-get p :anchor) nl-pos)))
                   (when op (push op para-ops))))
                (:list
                 (let ((op (gdocs--emit-list-style-op
                            (plist-get p :list-id)
                            (or (plist-get p :nest) 0)
                            nl-pos)))
                   (when op (push op para-ops))))
                (_ nil))
              (setq pos (1+ pos))))))))
    (let ((body (apply #'concat (nreverse parts)))
          (ae-list-ops (gdocs--emit-list-defs list-defs)))
      (cons body
            (append ae-list-ops
                    (nreverse text-ops)
                    (nreverse link-ops)
                    (nreverse para-ops))))))

(defun gdocs--run-text-equal-p (r1 r2)
  (and (equal (plist-get r1 :text) (plist-get r2 :text))
       (equal (sort (plist-get r1 :styles) :lessp #'string<)
              (sort (plist-get r2 :styles) :lessp #'string<))
       (equal (plist-get r1 :link) (plist-get r2 :link))))

(defun gdocs--paragraph-equal-p (p1 p2)
  "Return non-nil if P1 and P2 are equivalent at the user-visible level.
Compares kind, runs, heading level, list nest/glyph, but NOT list-id —
list ids differ between live-decoded and freshly-rendered docs."
  (and (eq (plist-get p1 :kind) (plist-get p2 :kind))
       (equal (plist-get p1 :level) (plist-get p2 :level))
       (equal (plist-get p1 :nest) (plist-get p2 :nest))
       (equal (plist-get p1 :glyph) (plist-get p2 :glyph))
       (let ((r1 (plist-get p1 :runs))
             (r2 (plist-get p2 :runs)))
         (and (= (length r1) (length r2))
              (cl-every #'gdocs--run-text-equal-p r1 r2)))))

(defun gdocs--paragraphs-common-prefix (a b)
  (let ((n 0))
    (while (and a b (gdocs--paragraph-equal-p (car a) (car b)))
      (cl-incf n) (setq a (cdr a) b (cdr b)))
    n))

(defun gdocs--paragraphs-common-suffix (a b)
  (gdocs--paragraphs-common-prefix (reverse a) (reverse b)))

(defun gdocs--paragraphs-ot-length (paras)
  (if (null paras) 0
    (length (car (gdocs-dm-to-ot
                  (gdocs-dm-make-doc :paragraphs paras))))))

(defun gdocs--shift-op-positions (op shift)
  (mapcar (lambda (kv)
            (pcase (car kv)
              ((or 'si 'ei 'ibi) (cons (car kv) (+ (cdr kv) shift)))
              (_ kv)))
          op))

(defun gdocs-dm-to-incremental-save-commands (old-doc new-doc)
  "Compute paragraph-level diff between OLD-DOC and NEW-DOC and emit
minimal save commands.

Falls back to a full-replace bundle if the diff region includes any
list or table paragraphs — those carry entity ids whose live values we
don't track yet, so re-emitting them in-place can desync references.

Returns a list of OT save commands (possibly empty if docs are equal)."
  (let* ((old-paras (gdocs-dm-paragraphs old-doc))
         (new-paras (gdocs-dm-paragraphs new-doc))
         (pre (gdocs--paragraphs-common-prefix old-paras new-paras))
         (suf (gdocs--paragraphs-common-suffix
               (nthcdr pre old-paras) (nthcdr pre new-paras)))
         (old-mid (cl-subseq old-paras pre
                             (- (length old-paras) suf)))
         (new-mid (cl-subseq new-paras pre
                             (- (length new-paras) suf))))
    (cond
     ((and (null old-mid) (null new-mid))
      nil)
     ((cl-some (lambda (p) (memq (plist-get p :kind) '(:list :table)))
               (append old-mid new-mid))
      (gdocs-dm-to-save-commands
       (gdocs--paragraphs-ot-length old-paras) new-doc))
     (t
      (let* ((old-pre-len (gdocs--paragraphs-ot-length
                           (cl-subseq old-paras 0 pre)))
             (old-mid-len (gdocs--paragraphs-ot-length old-mid))
             (sub-doc (gdocs-dm-make-doc :paragraphs new-mid))
             (built (gdocs-dm-to-ot sub-doc))
             (mid-body (car built))
             (mid-style-ops (cdr built))
             (shifted-ops
              (mapcar (lambda (op)
                        (gdocs--shift-op-positions op old-pre-len))
                      mid-style-ops))
             (cmds nil))
        (when (> old-mid-len 0)
          (push `((ty . "ds") (si . ,(1+ old-pre-len))
                  (ei . ,(+ old-pre-len old-mid-len)))
                cmds))
        (when (length> mid-body 0)
          (push `((ty . "is") (ibi . ,(1+ old-pre-len))
                  (s . ,mid-body))
                cmds))
        (append (nreverse cmds) shifted-ops))))))

(defun gdocs-dm-to-save-commands (current-ot-len doc)
  "Produce the OT save-command list to fully replace a doc of length
CURRENT-OT-LEN with the contents of DOC."
  (let* ((built (gdocs-dm-to-ot doc))
         (body (car built))
         (style-ops (cdr built))
         (cmds nil))
    (when (and (integerp current-ot-len) (> current-ot-len 0))
      (push `((ty . "ds") (si . 1) (ei . ,current-ot-len)) cmds))
    (when (length> body 0)
      (push `((ty . "is") (ibi . 1) (s . ,body)) cmds))
    (setq cmds (nreverse cmds))
    (append cmds style-ops)))

(defun gdocs--format-creation-date (creation-time-ms)
  "Format CREATION-TIME-MS (epoch ms, integer or nil) as an org
inactive-style timestamp [YYYY-MM-DD Day]. Returns nil for
nil/zero/garbage input."
  (when (and (integerp creation-time-ms) (> creation-time-ms 0))
    (format-time-string "[%Y-%m-%d %a]" (/ creation-time-ms 1000))))

(defun gdocs--ot-decode-pipeline (doc-id html state &optional creation-time-ms)
  "Pure transform: decode an OT-backed HTML + STATE into (TITLE . BODY).
Returns (TITLE . BODY) — BODY includes the properties drawer, the
`#+title:' line, and (when CREATION-TIME-MS is non-nil) a `#+date:'
line, ready for `gdocs--apply-pull-into-buffer'."
  (let* ((parsed (gdocs--parse-model-chunk-full html))
         (ops (plist-get parsed :ops))
         (revision (or (plist-get state :revision)
                       (plist-get parsed :revision)))
         (ot-body (plist-get state :ot-body))
         (edit-title (plist-get state :title))
         (doc (gdocs-dm-from-ops revision doc-id edit-title
                                 (or ot-body "") ops))
         (org-content (gdocs-dm-to-org doc))
         (date-str (gdocs--format-creation-date creation-time-ms))
         (header
          (concat
           (when edit-title (format "#+title: %s\n" edit-title))
           (when date-str (format "#+date: %s\n" date-str))
           (when (or edit-title date-str) "\n")))
         (titled (concat header org-content))
         (hash (secure-hash 'sha256 titled))
         (effective-title (or edit-title doc-id))
         (props (format
                 ":PROPERTIES:\n:GDOC_ID: %s\n:GDOC_REVISION: %s\n:GDOC_CONTENT_HASH: %s\n:GDOC_SYNCED_AT: %s\n:END:\n"
                 doc-id
                 (if revision (number-to-string revision) "")
                 hash
                 (gdocs--now-iso))))
    (cons effective-title (concat props titled))))

(defun gdocs--ot-body-length (ot-body)
  "Return the OT codepoint count of OT-BODY (the model chunk's `is.s')."
  (length (or ot-body "")))

;; Codepoints in the OT body that represent doc structure (table open/close,
;; row, cell …). These don't appear in the plain-text view a user edits
;; locally; the txt-export expands them into newlines/tabs in a way that
;; isn't a 1:1 char substitution (entire structural runs collapse), so we
;; can't translate by substitution alone. Instead we drop them when
;; building the plain view and record their OT positions so that in-place
;; edits stay clear of table interiors.
(defconst gdocs--ot-structural-codepoints
  '(#x10 #x11 #x12 #x1c)
  "OT codepoints that mark structure (not visible plain content).
0x10/0x11 = table open/close. 0x12 = row separator. 0x1c = cell separator.")

(defun gdocs--ot-plain-and-map (ot-body)
  "Walk OT-BODY and split it into plain text + a position map.

Returns a cons (PLAIN . MAP) where:
- PLAIN is OT-BODY with structural codepoints (see
  `gdocs--ot-structural-codepoints') removed.
- MAP is a vector of length (length PLAIN). MAP[i] is the OT position
  of PLAIN[i] (1-based: OT pos 1 = first codepoint of the body).

Lookup: a plain-text position P corresponds to OT position MAP[P].
For an edit that replaces PLAIN[A..B), the OT range is MAP[A]..MAP[B-1]+1."
  (let* ((n (length (or ot-body "")))
         (plain (make-string n 0))
         (map (make-vector n 0))
         (j 0)
         (structural gdocs--ot-structural-codepoints))
    (dotimes (i n)
      (let ((c (aref ot-body i)))
        (unless (memq c structural)
          (aset plain j c)
          (aset map j (1+ i))
          (cl-incf j))))
    (cons (substring plain 0 j)
          (seq-subseq map 0 j))))

(defun gdocs--ot-plain-text (ot-body)
  "Convenience: just the plain view, no map. See `gdocs--ot-plain-and-map'."
  (car (gdocs--ot-plain-and-map ot-body)))

;;; Org → OT plain view (markup-stripping for context matching)

(defun gdocs--strip-org-markup (text)
  "Strip org-only markup from TEXT for matching against OT plain view.
Returns (STRIPPED . OFFSETS) where OFFSETS is a vector of length
`(length STRIPPED)'; OFFSETS[i] is the index in TEXT of STRIPPED[i].

Strips:
- Heading prefix at line start: `^\\*+ ' (e.g. `* H' → `H').
- PROPERTIES drawer: `:PROPERTIES:\\n...:END:\\n' removed entirely.
- Unordered list marker at line start: `^\\s-*[-+] '.
- Ordered list marker at line start: `^\\s-*[0-9]+[.)] '.

Leaves tables, code blocks, and inline markup alone — those need their
own structural handling. The OFFSETS vector lets callers map a position
in STRIPPED back to the original TEXT, which is how
`gdocs--locate-edit-in-ot' converts an OT-plain match index back into a
position in the org buffer."
  (let* ((n (length text))
         (stripped (make-string n 0))
         (offsets (make-vector n 0))
         (j 0)
         (i 0)
         (at-line-start t))
    (while (< i n)
      (cond
       ;; PROPERTIES drawer — skip from `:PROPERTIES:' through `:END:\n'.
       ((and at-line-start
             (<= (+ i (length ":PROPERTIES:")) n)
             (string= (substring text i (+ i (length ":PROPERTIES:")))
                      ":PROPERTIES:"))
        (let ((end (string-match "^:END:[ \t]*\n?" text i)))
          (setq i (if end (match-end 0) n)
                at-line-start t)))
       ;; Heading marker at line start: ^\*+
       ((and at-line-start (= (aref text i) ?*))
        (let ((k i))
          (while (and (< k n) (= (aref text k) ?*)) (cl-incf k))
          (cond
           ;; Stars followed by space → heading marker, skip stars+space.
           ((and (< k n) (= (aref text k) ?\s))
            (setq i (1+ k) at-line-start nil))
           ;; Not a heading (lone `*` or `**word`) → emit verbatim.
           (t
            (aset stripped j ?*)
            (aset offsets j i)
            (cl-incf j) (cl-incf i)
            (setq at-line-start nil)))))
       ;; Unordered list marker: ^\s*[-+]
       ((and at-line-start
             (let ((k i))
               (while (and (< k n)
                           (or (= (aref text k) ?\s)
                               (= (aref text k) ?\t)))
                 (cl-incf k))
               (and (< (1+ k) n)
                    (memq (aref text k) '(?- ?+))
                    (= (aref text (1+ k)) ?\s))))
        ;; Skip leading whitespace + marker + space.
        (while (and (< i n)
                    (or (= (aref text i) ?\s) (= (aref text i) ?\t)))
          (cl-incf i))
        (setq i (+ i 2)
              at-line-start nil))
       ;; Ordered list marker: ^\s*[0-9]+[.)]
       ((and at-line-start
             (let ((k i))
               (while (and (< k n)
                           (or (= (aref text k) ?\s)
                               (= (aref text k) ?\t)))
                 (cl-incf k))
               (and (< k n) (>= (aref text k) ?0) (<= (aref text k) ?9)
                    (let ((m k))
                      (while (and (< m n)
                                  (>= (aref text m) ?0)
                                  (<= (aref text m) ?9))
                        (cl-incf m))
                      (and (< (1+ m) n)
                           (memq (aref text m) '(?. ?\)))
                           (= (aref text (1+ m)) ?\s))))))
        (while (and (< i n)
                    (or (= (aref text i) ?\s) (= (aref text i) ?\t)))
          (cl-incf i))
        (while (and (< i n)
                    (>= (aref text i) ?0) (<= (aref text i) ?9))
          (cl-incf i))
        (setq i (+ i 2) ; the `.`/`)` and the space
              at-line-start nil))
       ;; Org table row: `^|...|$`. Strip leading/trailing pipes, replace
       ;; ` | ' cell separators with `\\n', drop `|---+---|' alignment rows.
       ;; OT plain stores table cells as `cell\n', so a 2x2 org table
       ;; `| a | b |\n| c | d |\n' becomes `a\nb\nc\nd\n', which matches.
       ((and at-line-start (= (aref text i) ?|))
        (let* ((nl (string-match "\n" text i))
               (line-end (or nl n)))
          (cond
           ;; Alignment row — drop the whole line including its \n.
           ((and (< (1+ i) line-end) (= (aref text (1+ i)) ?-))
            (setq i (min (1+ line-end) n)
                  at-line-start t))
           (t
            ;; Skip leading `|' and any following whitespace.
            (cl-incf i)
            (while (and (< i line-end)
                        (or (= (aref text i) ?\s) (= (aref text i) ?\t)))
              (cl-incf i))
            (while (< i line-end)
              (cond
               ;; Trailing ` |' right before EOL — drop both.
               ((and (= (aref text i) ?\s)
                     (< (1+ i) line-end)
                     (= (aref text (1+ i)) ?|)
                     (= (+ i 2) line-end))
                (setq i line-end))
               ;; Trailing `|' right before EOL.
               ((and (= (aref text i) ?|)
                     (= (1+ i) line-end))
                (setq i line-end))
               ;; Cell separator ` | ' → emit \n.
               ((and (<= (+ i 3) line-end)
                     (= (aref text i) ?\s)
                     (= (aref text (1+ i)) ?|)
                     (= (aref text (+ i 2)) ?\s))
                (aset stripped j ?\n)
                (aset offsets j (1+ i))
                (cl-incf j)
                (setq i (+ i 3))
                (while (and (< i line-end)
                            (or (= (aref text i) ?\s) (= (aref text i) ?\t)))
                  (cl-incf i)))
               (t
                (aset stripped j (aref text i))
                (aset offsets j i)
                (cl-incf j) (cl-incf i))))
            ;; Emit row-terminating \n.
            (when (and (< i n) (= (aref text i) ?\n))
              (aset stripped j ?\n)
              (aset offsets j i)
              (cl-incf j) (cl-incf i))
            (setq at-line-start t)))))
       ;; Default: copy char.
       (t
        (let ((c (aref text i)))
          (aset stripped j c)
          (aset offsets j i)
          (cl-incf j) (cl-incf i)
          (setq at-line-start (= c ?\n))))))
    (cons (substring stripped 0 j)
          (seq-subseq offsets 0 j))))

;;; Org → OT reconstruction (step 1: plain paragraphs only)

(defun gdocs--org-to-ot (org-text)
  "Convert ORG-TEXT (plain paragraphs only) to the OT codepoint string.

For step 1 this only handles plain paragraphs. Non-empty lines join
with a single `\\n' between them; blank lines in org have no OT
representation (paragraph separator). The trailing `\\n' is preserved
iff ORG-TEXT itself ends with `\\n' — so this composes cleanly when
measuring a prefix `[heading-start, edit-pos)' that may end mid-paragraph.

Refuses input containing headings, tables, code blocks, lists, links,
or other rich content — those need their own converters and a clear
error is better than a silent miscount, since the resulting length is
fed straight into OT-position arithmetic."
  (let ((lines (split-string org-text "\n"))
        (kept nil))
    (dolist (line lines)
      (cond
       ((string-empty-p line) nil)
       ((string-match-p "^\\*+ " line)
        (user-error "gdocs--org-to-ot: heading not supported yet: %S" line))
       ((string-match-p "^\\s-*[-+*] " line)
        (user-error "gdocs--org-to-ot: list item not supported yet: %S" line))
       ((string-match-p "^\\s-*[0-9]+[.)] " line)
        (user-error "gdocs--org-to-ot: ordered list not supported yet: %S" line))
       ((string-match-p "^|" line)
        (user-error "gdocs--org-to-ot: table not supported yet: %S" line))
       ((string-match-p "^#\\+begin_" line)
        (user-error "gdocs--org-to-ot: code/quote block not supported yet"))
       ((string-match-p "\\[\\[" line)
        (user-error "gdocs--org-to-ot: link not supported yet: %S" line))
       (t (push line kept))))
    (let* ((joined (string-join (nreverse kept) "\n"))
           (ends-nl (and (length> org-text 0)
                         (= (aref org-text (1- (length org-text))) ?\n))))
      (if (and ends-nl (not (string-empty-p joined)))
          (concat joined "\n")
        joined))))

(defun gdocs--parse-edit-state-html (html)
  "Extract the edit-state plist from an /edit page HTML string.
Returns a plist (:title :token :ouid :revision :smv :smb-seg :ot-body).
Any field may be nil if not present. Returns nil if HTML is nil."
  (when html
    (let ((title nil) (token nil) (ouid nil) (revision nil)
          (smv nil) (smb-seg nil) (ot-body nil))
      (when (string-match "<title[^>]*>\\([^<]*\\)</title>" html)
        (let ((raw (string-trim (match-string 1 html))))
          (setq title
                (cond
                 ((string-empty-p raw) nil)
                 ((string-suffix-p " - Google Docs" raw)
                  (substring raw 0 (- (length raw) (length " - Google Docs"))))
                 (t raw)))))
      (when (string-match
             "\"info_params\"[ \t]*:[ \t]*{[^}]*\"token\"[ \t]*:[ \t]*\"\\([^\"]+\\)\""
             html)
        (setq token (match-string 1 html)))
      (when (string-match
             "\"info_params\"[ \t]*:[ \t]*{[^}]*\"ouid\"[ \t]*:[ \t]*\"\\([^\"]+\\)\""
             html)
        (setq ouid (match-string 1 html)))
      (when (string-match "\"revision\"[ \t]*:[ \t]*\\([0-9]+\\)" html)
        (setq revision (string-to-number (match-string 1 html))))
      (when (string-match "\"docs-smv\"[ \t]*:[ \t]*\\([0-9]+\\)" html)
        (setq smv (string-to-number (match-string 1 html))))
      (when (string-match
             "\"docs-smfb\"[ \t]*:[ \t]*\\[[ \t]*[0-9]+[ \t]*,[ \t]*\"\\([^\"]+\\)\"\\]"
             html)
        (setq smb-seg (match-string 1 html)))
      (let ((mc (gdocs--parse-model-chunk html))
            (full (gdocs--parse-model-chunk-full html)))
        (setq ot-body (plist-get mc :ot-body))
        (when (plist-get mc :revision)
          (setq revision (plist-get mc :revision)))
        (list :title title :token token :ouid ouid :revision revision
              :smv smv :smb-seg smb-seg :ot-body ot-body
              :ot-ops (plist-get full :ops))))))

(defun gdocs--fetch-edit-state (doc-id)
  "Fetch the doc's /edit page once and extract everything we need.
Returns a plist (:title T :token TK :ouid U :revision N :smv V
:smb-seg S :ot-body STR). Any field may be nil if not found.
Single GET — reused by pull, push, and staleness.

:smv is the model-version-max from `docs-smv'.
:smb-seg is the body-segment id from `docs-smfb' (the literal that goes
into the URL `smb' param). It is doc-specific and tab-specific.
:ot-body is the doc body in OT index space — every codepoint occupies
one OT position. Length of this string = the end-of-doc OT index."
  (condition-case _
      (let* ((url (format "%s%s/edit" gdocs--export-base doc-id))
             (html (gdocs--make-request url "GET" nil 'buffer-string)))
        (gdocs--parse-edit-state-html html))
    (error nil)))

(defun gdocs--annotate-headings-with-ot-anchors (org-content ot-body)
  "Return ORG-CONTENT with `:GDOC_OT_START:' inserted on every heading.

Walks the OT body's plain view in parallel with the headings and emits
each heading's OT position into a fresh property drawer attached to its
own line. The OT body always carries heading titles as bare plain text
(styling is conveyed by separate ops), so the title's position in the
plain view maps directly to its OT position.

If OT-BODY is nil or empty, returns ORG-CONTENT unchanged. If a heading
title cannot be located in the OT plain view, that heading is skipped
with a `gdocs-log' warning — anchor-shift on subsequent pushes will
just leave it un-anchored until the next pull."
  (if (or (null ot-body) (string-empty-p ot-body))
      org-content
    (let* ((plain+map (gdocs--ot-plain-and-map ot-body))
           (plain (car plain+map))
           (map (cdr plain+map)))
      (with-temp-buffer
        (insert org-content)
        (goto-char (point-min))
        (let ((cursor 0))
          (while (re-search-forward "^\\*+ \\(.+\\)$" nil t)
            (let* ((raw-title (string-trim (match-string 1)))
                   ;; Strip the org inline markers our html-format-node may
                   ;; have emitted: *bold*, /italic/, _under_, +strike+, =code=.
                   ;; Bare-character regex is good enough for step 2; deeper
                   ;; round-tripping is part of the inverse-converter work.
                   (title (replace-regexp-in-string
                           "[*/_+=]" "" raw-title))
                   (heading-end (line-end-position))
                   (idx (and (not (string-empty-p title))
                             (string-search title plain cursor))))
              (if (not idx)
                  (gdocs-log 'warn
                             "anchor: heading %S not found in OT plain view past %d"
                             title cursor)
                (let ((ot-pos (aref map idx)))
                  (setq cursor (+ idx (length title)))
                  (goto-char heading-end)
                  (insert (format
                           "\n:PROPERTIES:\n:GDOC_OT_START: %d\n:END:"
                           ot-pos)))))))
        (buffer-string)))))

(defun gdocs-get-title (url-or-id)
  "Return the title of the Google Doc identified by URL-OR-ID.
Accepts a doc id, full /document/d/<id>/edit URL, or org link.
Returns the doc's title string, or nil if not reachable."
  (let* ((doc-id (gdocs--extract-doc-id url-or-id))
         (state (and doc-id (gdocs--fetch-edit-state doc-id))))
    (and state (plist-get state :title))))

(defun gdocs-pull-locally (&optional doc-id callback)
  "Pull remote into current buffer asynchronously.
DOC-ID falls back to the buffer's GDOC_ID property. The network I/O runs
in a background curl subprocess so Emacs stays responsive. Optional
CALLBACK is `(funcall CB BODY ERR)' on completion."
  (interactive)
  (if gdocs--sync-mutex
      (gdocs-log 'warn "Mutex locked - skipping pull")
    (setq gdocs--sync-mutex t)
    (let ((buf (current-buffer))
          (doc-id (gdocs--get-doc-id doc-id))
          (cb (or callback (lambda (_b _e) nil))))
      (gdocs--pull-locally-async-1 doc-id buf cb))))

(defun gdocs--pull-locally-async-1 (doc-id buf cb)
  "Background driver for `gdocs-pull-locally'.
Single GET on /edit gives us both the state and the raw HTML whose
modelChunk we need for the op stream. Comments live in the cookie-auth
`/docos/p/sync' endpoint — chain a POST there and append the
`* Comments' subtree if any."
  (let ((release (lambda (err)
                   (setq gdocs--sync-mutex nil)
                   (when err (gdocs-log 'warn "Pull %s: %s" doc-id err))
                   (funcall cb nil err))))
    (gdocs--fetch-edit-page-async
     doc-id
     (lambda (state edit-html err)
       (cond
        (err (funcall release err))
        (t
         (gdocs--fetch-docdetails-async
          doc-id state
          (lambda (details details-err)
            (when details-err
              (gdocs-log 'debug "docdetails fetch failed for %s: %s"
                         doc-id details-err))
            (condition-case sig
                (let* ((creation-time-ms
                        (and (listp details)
                             (alist-get 'CREATION_TIME details)))
                       (built (gdocs--ot-decode-pipeline
                               doc-id edit-html state creation-time-ms))
                       (title (car built))
                       (body (cdr built))
                       (parsed (gdocs--parse-model-chunk-full edit-html))
                       (anchor-map (gdocs--decode-doco-anchors
                                    (plist-get parsed :ops)))
                       (ot-body (plist-get state :ot-body)))
                  (gdocs--docos-sync-raw-async
                   doc-id state
                   (lambda (raw _docos-err)
                     (condition-case sig2
                         (let* ((comments (and raw
                                               (gdocs--parse-docos-sync-response
                                                raw)))
                                (body-with-refs
                                 (if (and comments ot-body)
                                     (gdocs--inline-comment-refs
                                      body ot-body anchor-map comments)
                                   body))
                                (final (if comments
                                           (concat (string-trim-right
                                                    body-with-refs)
                                                   "\n\n"
                                                   (gdocs--render-comments-section
                                                    comments))
                                         body-with-refs)))
                           (gdocs--apply-pull-into-buffer doc-id buf title final)
                           (setq gdocs--sync-mutex nil)
                           (funcall cb final nil))
                       (error (funcall release (error-message-string sig2)))))))
              (error (funcall release (error-message-string sig))))))))))))

(defface gdocs-pull-flash
  '((((background dark))  :background "#264f3a" :extend t)
    (((background light)) :background "#d4f4dd" :extend t)
    (t :inherit highlight))
  "Face used to briefly highlight regions just updated by a pull.")

(defcustom gdocs-pull-flash-duration 0.8
  "Total seconds for the pull-flash fade-out animation."
  :type 'number :group 'gdocs)

(defcustom gdocs-pull-flash-steps 12
  "Number of fade steps between the highlight color and the buffer
background during the pull-flash animation. Higher = smoother fade."
  :type 'integer :group 'gdocs)

(defun gdocs--flash-blend (c1 c2 ratio)
  "Blend hex/named colors C1 and C2 at RATIO (0 → C1, 1 → C2).
Returns a #RRRRGGGGBBBB hex string, or nil if either color is unknown."
  (let ((v1 (and c1 (color-values c1)))
        (v2 (and c2 (color-values c2))))
    (when (and v1 v2)
      (apply #'format "#%04x%04x%04x"
             (cl-mapcar (lambda (a b)
                          (round (+ (* (- 1 ratio) a) (* ratio b))))
                        v1 v2)))))

(defun gdocs--flash-fade-step (ov start-color end-color step total interval)
  "One tick of the fade: blend START-COLOR toward END-COLOR by STEP/TOTAL,
update OV's face background, and schedule the next tick. When STEP reaches
TOTAL, deletes the overlay instead."
  (cond
   ((not (overlayp ov)) nil)
   ((>= step total) (delete-overlay ov))
   (t
    (let* ((ratio (/ (float step) total))
           (blended (gdocs--flash-blend start-color end-color ratio)))
      (when blended
        (overlay-put ov 'face `(:background ,blended :extend t))))
    (run-with-timer interval nil
                    #'gdocs--flash-fade-step
                    ov start-color end-color (1+ step) total interval))))

(defun gdocs--flash-regions (ranges)
  "Highlight RANGES (list of (start-marker . end-marker)) with
`gdocs-pull-flash' and gradually fade them out over
`gdocs-pull-flash-duration' seconds. Falls back to a single-shot
overlay removal if the frame can't report colors (e.g. batch/tty)."
  (let* ((start-color (face-attribute 'gdocs-pull-flash :background nil 'default))
         (end-color (face-attribute 'default :background nil 'default))
         (interval (/ gdocs-pull-flash-duration
                      (float (max 1 gdocs-pull-flash-steps)))))
    (when (or (null start-color) (eq start-color 'unspecified))
      (setq start-color nil))
    (when (or (null end-color) (eq end-color 'unspecified))
      (setq end-color nil))
    (dolist (range ranges)
      (let* ((s (car range)) (e (cdr range))
             (buf (and (markerp s) (marker-buffer s))))
        (when (and buf (buffer-live-p buf)
                   (markerp e) (eq (marker-buffer e) buf)
                   (< (marker-position s) (marker-position e)))
          (let ((ov (make-overlay (marker-position s) (marker-position e) buf)))
            (overlay-put ov 'face 'gdocs-pull-flash)
            (overlay-put ov 'gdocs-flash t)
            (if (and start-color end-color)
                (gdocs--flash-fade-step ov start-color end-color
                                        1 gdocs-pull-flash-steps interval)
              (run-with-timer gdocs-pull-flash-duration nil
                              (lambda ()
                                (when (overlayp ov) (delete-overlay ov))))))))
      (when (markerp (car range)) (set-marker (car range) nil))
      (when (markerp (cdr range)) (set-marker (cdr range) nil)))))

(defun gdocs--parse-pull-body (body)
  "Split a pull BODY into (DRAWER-ALIST TITLE CONTENT).

DRAWER-ALIST is a list of (KEY . VALUE) strings from a leading
`:PROPERTIES:'…`:END:' block; TITLE is the value of a leading
`#+title:' line; CONTENT is everything after, with any blank lines
between the header and the body skipped. All three parts are optional."
  (with-temp-buffer
    (insert body)
    (goto-char (point-min))
    (let ((drawer nil) (title nil))
      (when (looking-at "^:PROPERTIES:[ \t]*\n")
        (forward-line 1)
        (while (and (not (eobp))
                    (not (looking-at "^:END:[ \t]*$")))
          (when (looking-at
                 "^:\\([A-Za-z][A-Za-z0-9_-]*\\):[ \t]*\\(.*\\)$")
            (push (cons (match-string-no-properties 1)
                        (string-trim (match-string-no-properties 2)))
                  drawer))
          (forward-line 1))
        (when (looking-at "^:END:[ \t]*$")
          (forward-line 1)))
      (when (looking-at "^#\\+title:[ \t]*\\(.*\\)$")
        (let ((m (match-string-no-properties 1)))
          (when (and m (not (string-empty-p (string-trim m))))
            (setq title (string-trim m))))
        (forward-line 1))
      (when (looking-at "^#\\+date:[ \t]*.*$")
        (forward-line 1))
      (while (and (not (eobp)) (looking-at "^[ \t]*\n"))
        (forward-line 1))
      (list (nreverse drawer) title
            (buffer-substring-no-properties (point) (point-max))))))

(defun gdocs--body-start-pos ()
  "Return the position where the doc body starts in the current buffer
\(after the top-level property drawer and #+title line, mirroring
`gdocs--buffer-body-as-plain'). The pattern matches a blank line only
when it ends in a newline, so we never spin at end-of-buffer."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at org-property-drawer-re)
      (goto-char (match-end 0))
      (forward-line))
    (when (looking-at "^#\\+title:.*\n")
      (goto-char (match-end 0)))
    (when (looking-at "^#\\+date:.*\n")
      (goto-char (match-end 0)))
    (while (and (not (eobp)) (looking-at "^[ \t]*\n"))
      (forward-line 1))
    (point)))

(defun gdocs--apply-diff-regions (body-start regions)
  "Apply diff REGIONS to the current buffer's body.
BODY-START is the buffer position of the start of the diffed body
substring. REGIONS is the list returned by `gdocs--diff-paragraphs',
where each plist's `:start' and `:rem-end' are offsets into the body
*before* any edits (REMOTE side). Returns a list of (start-marker .
end-marker) pairs covering each inserted span, suitable for
`gdocs--flash-regions'.

Edits are applied in reverse order so earlier offsets stay valid."
  (let ((flash nil))
    (dolist (region (reverse regions))
      (let* ((rs  (plist-get region :start))
             (re  (plist-get region :rem-end))
             (ins (plist-get region :inserted))
             (buf-rs (+ body-start rs))
             (buf-re (+ body-start re)))
        (delete-region buf-rs buf-re)
        (goto-char buf-rs)
        (let ((ins-start (point)))
          (insert ins)
          (when (length> ins 0)
            (push (cons (copy-marker ins-start nil)
                        (copy-marker (point) t))
                  flash)))))
    flash))

(defun gdocs--apply-pull-into-buffer (doc-id buf title body)
  "Update BUF so its body matches BODY, preserving point and metadata.

Diffs the current body (everything after the top property drawer and
#+title line) against BODY at paragraph granularity and edits only the
changed regions. Replaced/inserted text is briefly highlighted via
`gdocs--flash-regions'. Falls back to a full body replace if the diff
would touch the whole document anyway."
  (unless (and body (not (string-empty-p body)))
    (error "GDocs pull returned empty content"))
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (saved-mod (buffer-modified-p))
             (point-marker (copy-marker (point) t))
             (parsed (gdocs--parse-pull-body body))
             (drawer (nth 0 parsed))
             (parsed-title (nth 1 parsed))
             (content (nth 2 parsed))
             (effective-title (or parsed-title title)))
        (unless (derived-mode-p 'org-mode) (org-mode))
        ;; Write top-level properties. GDOC_ID is forced to the doc-id
        ;; we were called with (canonical); other keys come from the
        ;; pull's drawer if present.
        (gdocs--put-top-property "GDOC_ID" doc-id)
        (dolist (pair drawer)
          (unless (string= (car pair) "GDOC_ID")
            (gdocs--put-top-property (car pair) (cdr pair))))
        (when effective-title
          (save-excursion
            (goto-char (point-min))
            (if (re-search-forward "^#\\+title:.*$" nil t)
                (replace-match (format "#+title: %s" effective-title) t t)
              (gdocs--update-top-metadata effective-title nil))
            ;; Ensure exactly one blank line between the title and the
            ;; body. `body-start-pos' already skips them, but if there's
            ;; no blank the body sits flush against the title.
            (goto-char (point-min))
            (when (re-search-forward "^#\\+title:.*\n" nil t)
              (unless (looking-at "^[ \t]*\n")
                (insert "\n")))))
        (let* ((body-start (gdocs--body-start-pos))
               (current-content (buffer-substring-no-properties
                                 body-start (point-max))))
          (cond
           ((string= current-content content)
            (gdocs-log 'info "Pulled %s: no change" doc-id))
           (t
            (let* ((regions (gdocs--diff-paragraphs current-content content))
                   (total-ins (apply #'+ (mapcar
                                          (lambda (r)
                                            (length (plist-get r :inserted)))
                                          regions)))
                   (flash nil))
              (if (or (null regions)
                      (>= total-ins (length content)))
                  (save-excursion
                    (delete-region body-start (point-max))
                    (goto-char body-start)
                    (let ((ins-start (point)))
                      (insert content)
                      (push (cons (copy-marker ins-start nil)
                                  (copy-marker (point) t))
                            flash)))
                (save-excursion
                  (setq flash (gdocs--apply-diff-regions
                               body-start regions))))
              (gdocs--flash-regions flash)
              (gdocs-log 'info "Pulled %s (%d region%s, %d chars)"
                         doc-id (length regions)
                         (if (length= regions 1) "" "s")
                         (length content))))))
        (goto-char (marker-position point-marker))
        (set-marker point-marker nil)
        (org-cycle-hide-drawers 'all)
        (gdocs--mark-synced)
        (when (and (buffer-file-name) (not saved-mod))
          (save-buffer))))))


;;; Public commands — push

(defun gdocs--current-body-hash ()
  "SHA-256 of the buffer's pushable body (drawer + #+title stripped)."
  (secure-hash 'sha256 (gdocs--buffer-body-as-plain)))

(defun gdocs--mark-synced ()
  "Record the current buffer body hash as the post-sync baseline.
Call inside `with-current-buffer' after every successful pull or push."
  (setq gdocs--last-synced-hash (gdocs--current-body-hash)))

(defun gdocs--buffer-body-as-plain ()
  "Dump buffer minus top property drawer and #+title to plain text.

Also strips any trailing heading whose drawer carries `:GDOC_LOCAL: t'
\(currently the auto-generated `* Comments' subtree, which is a
read-only projection of Google's comments and must not be pushed)."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at org-property-drawer-re)
      (goto-char (match-end 0))
      (forward-line))
    ;; Also skip a leading #+title: line and any blank lines after it.
    ;; The `\n' in the blank-line pattern is required so we don't loop at
    ;; end-of-buffer where `looking-at' would match empty content forever.
    (when (looking-at "^#\\+title:.*\n")
      (goto-char (match-end 0)))
    (when (looking-at "^#\\+date:.*\n")
      (goto-char (match-end 0)))
    (while (and (not (eobp)) (looking-at "^[ \t]*\n"))
      (forward-line 1))
    (let* ((body-start (point))
           (end (gdocs--find-local-subtree-start body-start))
           (text (buffer-substring-no-properties body-start end))
           (text (replace-regexp-in-string "\r\n" "\n" text))
           ;; Strip inline footnote refs (`[fn:N]'). These are rendered
           ;; from Google's comment anchors on pull and have no place in
           ;; the pushed body — the canonical comments live on Google.
           (text (replace-regexp-in-string "\\[fn:[0-9]+\\]" "" text)))
      text)))

(defun gdocs--find-local-subtree-start (start)
  "Return the buffer position where a `:GDOC_LOCAL: t'-marked top-level
heading begins, or `point-max' if none. Search begins at START."
  (save-excursion
    (goto-char start)
    (let ((found nil))
      (while (and (not found)
                  (re-search-forward "^\\* " nil t))
        (let ((head-bol (line-beginning-position)))
          (forward-line 1)
          (when (looking-at org-property-drawer-re)
            (let ((drawer (buffer-substring-no-properties
                           (match-beginning 0) (match-end 0))))
              (when (string-match-p "^:GDOC_LOCAL:[ \t]+t[ \t]*$" drawer)
                (setq found head-bol))))))
      (or found (point-max)))))

(defun gdocs--export-txt-length (doc-id)
  "Return the OT length to use for ds (delete-span).
Fetches /export?format=txt and returns the character count. The
endpoint emits a trailing newline; Google's OT counts characters so we
return raw length and let the caller decide whether to subtract."
  (let* ((url (format "%s%s/export?format=txt" gdocs--export-base doc-id))
         (txt (gdocs--make-request url "GET" nil 'buffer-string)))
    (length (or txt ""))))

(defun gdocs--strip-xssi (s)
  "Strip Google's )]}' anti-XSSI prefix from response S."
  (if (and s (string-prefix-p ")]}'" s))
      (substring s (length ")]}'"))
    s))

;; Custom error so callers can distinguish a structured /save rejection
;; from a generic error. Data shape: (HTTP-CODE ERR-CODE DI BODY).
;; ERR-CODE 13 with a `di' counter is the throttle/abuse signal we
;; observed across all 550 responses; other values would indicate a
;; different rejection class.
(define-error 'gdocs-save-rejected "gdocs /save returned an error")

(defun gdocs--parse-save-error-body (body)
  "Extract (ERR-CODE . DI) from a /save error response BODY, or (nil . nil).
Google emits 550s as XSSI-prefixed JSON arrays:
  )]}'
  [[\"er\", null, null, null, null, 550, null, null, null, 13], [\"di\", N]]
ERR-CODE is the last element of the `er' array; DI is the number in
the `di' tuple."
  (condition-case _
      (let* ((stripped (gdocs--strip-xssi (string-trim-left body)))
             (json-array-type 'list)
             (json-object-type 'alist)
             (parsed (json-read-from-string stripped))
             (er-arr (and (listp parsed)
                          (seq-find (lambda (x)
                                        (and (listp x) (equal (car x) "er")))
                                      parsed)))
             (di-arr (and (listp parsed)
                          (seq-find (lambda (x)
                                        (and (listp x) (equal (car x) "di")))
                                      parsed))))
        (cons (and er-arr (car (last er-arr)))
              (and di-arr (cadr di-arr))))
    (error (cons nil nil))))

(defun gdocs--curl-post (url headers body)
  "POST BODY to URL with HEADERS using curl directly (no cookie jar).
Returns the response body string. Signals an error on non-2xx.
We bypass `request.el' here because its persistent cookie jar layers
stale Google session cookies on top of our explicit Cookie header and
that causes intermittent code-13 rejections from /save."
  (let* ((body-file (make-temp-file "gdocs-req-" nil ".bin"))
         (resp-file (make-temp-file "gdocs-resp-" nil ".bin"))
         (args (append (list "--silent" "--compressed"
                             "-X" "POST"
                             "-o" resp-file
                             "-w" "%{http_code}"
                             "--data-binary" (concat "@" body-file))
                       (mapcan (lambda (h)
                                 (list "-H" (format "%s: %s" (car h) (cdr h))))
                               headers)
                       (list url))))
    (unwind-protect
        (let* ((_ (let ((coding-system-for-write 'utf-8))
                    (with-temp-file body-file (insert body))))
               (status-string
                (with-temp-buffer
                  (let ((exit (apply #'call-process "curl" nil t nil args)))
                    (unless (zerop exit)
                      (error "gdocs: curl exit %d for %s" exit url)))
                  (buffer-string)))
               (http-code (string-to-number status-string))
               (response (with-temp-buffer
                           (set-buffer-multibyte nil)
                           (insert-file-contents-literally resp-file)
                           (decode-coding-region (point-min) (point-max) 'utf-8)
                           (buffer-string))))
          (unless (and (>= http-code 200) (< http-code 300))
            (let* ((parsed (gdocs--parse-save-error-body response))
                   (err-code (car parsed))
                   (di (cdr parsed)))
              (signal 'gdocs-save-rejected
                      (list :http-code http-code
                            :err-code err-code
                            :di di
                            :body (substring response 0
                                             (min 300 (length response)))))))
          response)
      (ignore-errors (delete-file body-file))
      (ignore-errors (delete-file resp-file)))))

(defconst gdocs--inter-region-delay 3
  "Seconds to sleep between regions of a multi-region in-place push.
Multi-region pushes hit the /save endpoint 2× per region (ds + is). Doing
4+ saves back-to-back triggers HTTP 550 rate limiting whose cooldown is
longer than `gdocs--rate-limit-retry-delay'. Spacing regions avoids the
burst budget entirely and keeps the push reliable.")

(defconst gdocs--rate-limit-retry-delay 3
  "Seconds to wait before retrying a /save POST that returned HTTP 550.
Short enough to recover from transient load-balancer blips, long enough
not to hammer Google's throttle further. /save throttle is probabilistic
per-request, not a hard session cooldown — see Push protocol.")

(defvar gdocs--session-sid nil
  "Persistent session SID, shared across all /save calls from this client.
A real browser keeps one SID for an entire edit-session and bumps `reqId'
monotonically across every save. We mimic that by persisting the pair to
disk (see `gdocs--session-file'). Tests can `let'-bind this for isolation.")

(defvar gdocs--session-req-id nil
  "Persistent monotonic /save request counter, paired with `gdocs--session-sid'.
Each save bumps it and writes the new value back to disk.")

(defcustom gdocs-session-file
  (expand-file-name "gdocs-mode/session.eld"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name "~/.cache")))
  "Where to persist the SID + reqId pair between Emacs sessions.
Cold-SID + reqId=1 on every save makes us look like dozens of new
clients hammering one doc — Google's abuse heuristic returns
HTTP 550 / err 13 deterministically (mis-diagnosed earlier as
transient throttle). One persistent SID per workstation looks
like one browser session and clears the rejection."
  :type 'file
  :group 'gdocs-mode)

(defun gdocs--save-request (doc-id state commands)
  "POST commands to the cookie-auth /save endpoint.
STATE is the plist from `gdocs--fetch-edit-state'.  COMMANDS is a list
of OT ops (alists). Returns parsed JSON response (XSSI-stripped)."
  (let* ((token (plist-get state :token))
         (ouid (plist-get state :ouid))
         (rev (plist-get state :revision))
         (smv (or (plist-get state :smv) 2147483647))
         (smb-seg (plist-get state :smb-seg))
         (req-id (gdocs--session-next-reqid))
         (sid gdocs--session-sid)
         ;; URL params match the browser /save request exactly. `smv'
         ;; (model version max) and `smb' (model snapshot bounds) come
         ;; from `docs-smv' / `docs-smfb' on the /edit page. Without them
         ;; Google's OT engine rejects multi-char ops with 550/code 13.
         (smb-pair (if smb-seg
                       (format "[%d, %s]" smv smb-seg)
                     (format "[%d]" smv)))
         (qs (concat "id=" doc-id
                     "&sid=" sid
                     "&vc=1&c=1&w=1&flr=0"
                     (format "&smv=%d" smv)
                     "&smb=" (url-hexify-string smb-pair)
                     "&token=" (url-hexify-string token)
                     "&ouid=" ouid
                     "&includes_info_params=true"
                     "&cros_files=false&nded=false"
                     "&tab=t.0"))
         (url (format "https://docs.google.com/document/u/0/d/%s/save?%s"
                      doc-id qs))
         (bundles (json-encode
                   (vector
                    `((commands . ,(vconcat commands))
                      (sid . ,sid)
                      (reqId . ,req-id)))))
         (form (format "rev=%s&bundles=%s"
                       (number-to-string rev)
                       (url-hexify-string bundles)))
         ;; The X-Rel-Id / X-Build / X-Client-Deadline-Ms triple is the
         ;; browser-fingerprint set the editors frontend sends; Google
         ;; uses it as a "real client" heuristic and 550s without it.
         ;; Values are stable placeholders — they don't need to match a
         ;; specific release.
         (headers (append
                   `(("Content-Type" . "application/x-www-form-urlencoded;charset=utf-8")
                     ("X-Same-Domain" . "1")
                     ("X-Rel-Id" . "30a.558e52c.s")
                     ("X-Build" . "editors.documents-frontend_20260513.00_p2")
                     ("X-Client-Deadline-Ms" . "20000")
                     ("Origin" . "https://docs.google.com")
                     ("Referer" . ,(format "https://docs.google.com/document/d/%s/edit" doc-id))
                     ("User-Agent" . ,gdocs-default-user-agent))
                   (gdocs--auth-headers)))
         (raw (gdocs--curl-post url headers form))
         (stripped (gdocs--strip-xssi raw)))
    (condition-case _
        (let ((json-array-type 'list)
              (json-object-type 'alist))
          (json-read-from-string stripped))
      (error
       (error "gdocs /save: unparseable response: %s"
              (substring stripped 0 (min 300 (length stripped))))))))

(defun gdocs--ot-remote-org-body (doc-id html state)
  "Render the remote doc as the org view we diff pushes against.
Pure transform: decodes the modelChunk in HTML through the same
pipeline as the pull, then strips the leading `#+'-prefixed and blank
lines so the result is the body text the push diff expects (heading
markers and list markers preserved; org metadata stripped)."
  (let* ((parsed (gdocs--parse-model-chunk-full html))
         (ops (plist-get parsed :ops))
         (revision (or (plist-get state :revision)
                       (plist-get parsed :revision)))
         (ot-body (plist-get state :ot-body))
         (edit-title (plist-get state :title))
         (doc (gdocs-dm-from-ops revision doc-id edit-title
                                 (or ot-body "") ops))
         (org (gdocs-dm-to-org doc))
         (lines (split-string org "\n")))
    (while (and lines
                (or (string-prefix-p "#+" (car lines))
                    (string-empty-p (string-trim (car lines)))))
      (setq lines (cdr lines)))
    (string-join lines "\n")))

;;; -------------------------------------------------------------------------
;;; Async HTTP layer
;;;
;;; All public commands (`gdocs-pull-locally', `gdocs-push-remotely',
;;; `gdocs--auto-sync-tick') run their network I/O through `make-process'
;;; so Emacs never blocks on curl. The sync primitives above are retained
;;; for offline tests; the async siblings reuse the same parsers.
;;; -------------------------------------------------------------------------

(defun gdocs--curl-async (url method headers body callback)
  "Run a curl request asynchronously.
CALLBACK is called as (funcall CALLBACK RESP HTTP-CODE ERR).
RESP is the response body (utf-8 string) or nil. HTTP-CODE is the integer
status code parsed from `-w %{http_code}', or nil. ERR is a short
human-readable string on curl-side failure, otherwise nil. Caller decides
how to interpret HTTP-CODE (e.g. 550 is a /save throttle, not a hard error)."
  (let* ((body-file (and body (make-temp-file "gdocs-req-" nil ".bin")))
         (resp-file (make-temp-file "gdocs-resp-" nil ".bin"))
         (stdout-buf (generate-new-buffer " *gdocs-curl-out*"))
         (args (append (list "--silent" "--compressed"
                             "-X" method
                             "-o" resp-file
                             "-w" "%{http_code}")
                       (when body (list "--data-binary" (concat "@" body-file)))
                       (mapcan (lambda (h)
                                 (list "-H" (format "%s: %s" (car h) (cdr h))))
                               headers)
                       (list url))))
    (when body
      (let ((coding-system-for-write 'utf-8))
        (with-temp-file body-file (insert body))))
    (make-process
     :name "gdocs-curl"
     :noquery t
     :command (cons "curl" args)
     :buffer stdout-buf
     :sentinel
     (lambda (proc _event)
       (when (memq (process-status proc) '(exit signal))
         (let ((exit-code (process-exit-status proc))
               (http-code nil) (response nil) (err nil))
           (unwind-protect
               (cond
                ((not (zerop exit-code))
                 (setq err (format "curl exit %d" exit-code)))
                (t
                 (when (buffer-live-p stdout-buf)
                   (with-current-buffer stdout-buf
                     (let ((s (string-trim (buffer-string))))
                       (setq http-code (and (string-match-p "^[0-9]+$" s)
                                            (string-to-number s))))))
                 (when (file-exists-p resp-file)
                   (with-temp-buffer
                     ;; `insert-file-contents' + `coding-system-for-read'
                     ;; produces a proper multibyte string. The earlier
                     ;; `set-buffer-multibyte nil' + `decode-coding-region'
                     ;; left the buffer unibyte, so `(buffer-string)' returned
                     ;; raw-byte chars (codepoints #x3FFF80+byte) for any
                     ;; multibyte sequence — em-dashes etc. would survive as
                     ;; three pseudo-chars instead of one U+2014.
                     (let ((coding-system-for-read 'utf-8))
                       (insert-file-contents resp-file))
                     (setq response (buffer-string))))))
             (when body-file (ignore-errors (delete-file body-file)))
             (ignore-errors (delete-file resp-file))
             (when (buffer-live-p stdout-buf) (kill-buffer stdout-buf)))
           (condition-case sig
               (funcall callback response http-code err)
             (error
              (gdocs-log 'error "async callback failed: %s"
                         (error-message-string sig))))))))))

(defun gdocs--make-request-async (url method data parser callback)
  "Async sibling of `gdocs--make-request'. CALLBACK = `(funcall CB RESULT ERR)'.
RESULT is the parsed body (json-read alist, or raw string if PARSER is
`buffer-string'). ERR is a short string on failure, nil on success.
DATA is encoded as JSON when non-nil. PARSER ∈ (json-read buffer-string)."
  (let* ((parser (or parser 'json-read))
         (headers (append `(("Content-Type" . "application/json; charset=utf-8")
                            ("User-Agent" . ,gdocs-default-user-agent)
                            ("Referer" . "https://docs.google.com/"))
                          (gdocs--auth-headers)))
         (body (when data (encode-coding-string (json-encode data) 'utf-8))))
    (gdocs--curl-async
     url method headers body
     (lambda (resp code err)
       (cond
        (err (funcall callback nil err))
        ((or (null code) (< code 200) (>= code 300))
         (funcall callback nil
                  (format "HTTP %s body=%s" code
                          (and resp (substring resp 0 (min 200 (length resp)))))))
        ((eq parser 'buffer-string)
         (funcall callback resp nil))
        ((eq parser 'json-read)
         (condition-case sig
             (let ((json-array-type 'list)
                   (json-object-type 'alist))
               (funcall callback (json-read-from-string resp) nil))
           (error (funcall callback nil
                           (format "json-read: %s" (error-message-string sig))))))
        (t (funcall callback resp nil)))))))

(defun gdocs--fetch-edit-state-async (doc-id callback)
  "Async sibling of `gdocs--fetch-edit-state'.
CALLBACK = `(funcall CB STATE ERR)'. STATE may be nil if parsing fails."
  (let ((url (format "%s%s/edit" gdocs--export-base doc-id)))
    (gdocs--make-request-async
     url "GET" nil 'buffer-string
     (lambda (html err)
       (if err
           (funcall callback nil err)
         (funcall callback (gdocs--parse-edit-state-html html) nil))))))

(defun gdocs--fetch-edit-page-async (doc-id callback)
  "Fetch the /edit page once. CALLBACK = `(funcall CB STATE HTML ERR)'.
On success, STATE is the parsed edit-state plist and HTML is the raw
page body (needed by the ot-decode backend, which walks the modelChunk
op stream)."
  (let ((url (format "%s%s/edit" gdocs--export-base doc-id)))
    (gdocs--make-request-async
     url "GET" nil 'buffer-string
     (lambda (html err)
       (if err
           (funcall callback nil nil err)
         (funcall callback (gdocs--parse-edit-state-html html) html nil))))))

(defun gdocs--fetch-docdetails-async (doc-id state callback)
  "GET /docdetails/read for DOC-ID; return parsed JSON alist.
STATE is the edit-state plist (for token + ouid). CALLBACK is called as
`(funcall CB ALIST ERR)'. Soft-fail: on any HTTP/parse problem we hand
back nil + a short err string — the caller treats docdetails as
best-effort and proceeds without it."
  (let* ((token (or (plist-get state :token) ""))
         (ouid (or (plist-get state :ouid) ""))
         (url (format
               "%s%s/docdetails/read?id=%s&token=%s&ouid=%s&includes_info_params=true"
               gdocs--export-base doc-id doc-id
               (url-hexify-string token) ouid))
         (headers (cons '("X-Same-Domain" . "1") (gdocs--auth-headers))))
    (gdocs--curl-async
     url "GET" headers nil
     (lambda (resp code err)
       (cond
        (err (funcall callback nil err))
        ((or (null code) (< code 200) (>= code 300))
         (funcall callback nil (format "HTTP %s" code)))
        (t
         (condition-case sig
             (let* ((stripped (gdocs--strip-xssi (string-trim-left (or resp ""))))
                    (json-array-type 'list)
                    (json-object-type 'alist)
                    (parsed (json-read-from-string stripped)))
               (funcall callback parsed nil))
           (error (funcall callback nil (error-message-string sig))))))))))

;;; -------------------------------------------------------------------------
;;; Discussions (comments) endpoints
;;;
;;; The browser editor talks to two endpoints under `/docos/p/' to load
;;; and sync comments. Both are cookie-authenticated (same session as
;;; /save) and share the standard /save-style query params:
;;;
;;; - POST /docos/p/sync   — session sync. On page load, body is `p=[[]]'
;;;   (with no `id'/`reqid' on the query string). On follow-ups, body is
;;;   `p=[null, <epoch-ms>]' to poll for changes since timestamp, or
;;;   `p=[[<thread-bundle>], <ms>]' to push a new comment / reply.
;;; - GET  /docos/p/uc     — bulk fetch of every open discussion on the
;;;   doc. Returns XSSI-prefixed JSON. This is what we replace the
;;;   html-export comment scrape with.

(defun gdocs--docos-base-qs (doc-id state &optional reqid)
  "Build the shared query string for /docos/p/* calls.
STATE is the plist from `gdocs--fetch-edit-state'. When REQID is nil
the `reqid' param is omitted (matches the session-init POST)."
  (gdocs--session-ensure)
  (let* ((token (plist-get state :token))
         (ouid (plist-get state :ouid))
         (smv (or (plist-get state :smv) 2147483647))
         (smb-seg (plist-get state :smb-seg))
         (smb-pair (if smb-seg
                       (format "[%d, %s]" smv smb-seg)
                     (format "[%d]" smv))))
    (concat (when doc-id (format "id=%s&" doc-id))
            (when reqid (format "reqid=%d&" reqid))
            "sid=" gdocs--session-sid
            "&vc=1&c=1&w=1&flr=0"
            (format "&smv=%d" smv)
            "&smb=" (url-hexify-string smb-pair)
            "&token=" (url-hexify-string (or token ""))
            "&ouid=" (or ouid "")
            "&includes_info_params=true"
            "&cros_files=false&nded=false"
            "&tab=t.0")))

(defun gdocs--docos-headers (doc-id)
  "Return the cookie-auth headers the browser sends to /docos/p/*."
  (append
   `(("X-Same-Domain" . "1")
     ("Origin" . "https://docs.google.com")
     ("Referer" . ,(format "https://docs.google.com/document/d/%s/edit?tab=t.0"
                           doc-id))
     ("User-Agent" . ,gdocs-default-user-agent))
   (gdocs--auth-headers)))

(defun gdocs--docos-sync-raw-async (doc-id state callback)
  "POST p=[[]] to /docos/p/sync and hand back the raw response body.
This is the call the browser editor makes on page load. The body
returned by the server carries every open discussion under an
`sr' (server-response) tag — we parse it in
`gdocs--parse-docos-sync-response'. CALLBACK = (funcall CB RAW ERR)."
  (let* ((qs (gdocs--docos-base-qs nil state nil))
         (url (format "%s%s/docos/p/sync?%s" gdocs--export-base doc-id qs))
         (form "p=%5B%5B%5D%5D")
         (headers (cons '("Content-Type" . "application/x-www-form-urlencoded;charset=utf-8")
                        (gdocs--docos-headers doc-id))))
    (gdocs--curl-async
     url "POST" headers form
     (lambda (raw code err)
       (cond
        (err (funcall callback nil err))
        ((and (integerp code) (>= code 200) (< code 300))
         (funcall callback raw nil))
        (t (funcall callback nil (format "HTTP %s" code))))))))

(defun gdocs--docos-plain-body (rec)
  "Return the `text/plain' body of comment record REC (or nil).
REC is a thread root or reply record. Index 3 holds the plain body
as `(\"text/plain\" \"<text>\")'."
  (when (listp rec)
    (let ((cell (nth 3 rec)))
      (when (and (listp cell) (equal (car cell) "text/plain"))
        (cadr cell)))))

(defun gdocs--parse-docos-sync-response (raw)
  "Parse the XSSI-prefixed JSON body returned by /docos/p/sync.
Returns a list of (N :text TEXT :anchor KIX-ID) plists — root comment
first, then each reply, numbered sequentially in the order the server
returned the threads. KIX-ID (the bundle's kix.* anchor) is shared
across the thread root and all its replies; nil if absent.

Response layout (reverse-engineered from a live capture):
  [\"sr\", [<thread-bundle>, ...], <epoch-ms>]
Each thread bundle is [<thread-id>, <record>, _, _, _, _, _, <anchor>].
<record>[3] is the plain body; <record>[7] is the replies array, each
reply having the same shape as a record."
  (when (and raw (not (string-empty-p raw)))
    (let* ((stripped (gdocs--strip-xssi (string-trim-left raw)))
           (json-array-type 'list)
           (json-object-type 'alist)
           (data (ignore-errors (json-read-from-string stripped)))
           (sr (seq-find (lambda (entry)
                           (and (listp entry) (equal (car entry) "sr")))
                         data))
           (threads (and sr (nth 1 sr)))
           (n 0)
           (out nil))
      (dolist (bundle threads)
        (let* ((rec (and (listp bundle) (nth 1 bundle)))
               (anchor (and (listp bundle) (nth 7 bundle)))
               (anchor (and (stringp anchor) anchor))
               (root-plain (gdocs--docos-plain-body rec))
               (replies (and (listp rec) (nth 7 rec))))
          (when (and root-plain (not (string-empty-p root-plain)))
            (cl-incf n)
            (push (list n :text root-plain :anchor anchor) out))
          (dolist (reply replies)
            (let ((reply-plain (gdocs--docos-plain-body reply)))
              (when (and reply-plain (not (string-empty-p reply-plain)))
                (cl-incf n)
                (push (list n :text reply-plain :anchor anchor) out))))))
      (nreverse out))))

(defun gdocs--fetch-comments-async (doc-id callback)
  "Fetch the parsed comments list for DOC-ID.
CALLBACK = (funcall CB COMMENTS ERR). COMMENTS is a list of (N . TEXT)
pairs the way `gdocs--render-comments-section' wants them; nil if the
doc has none or the fetch fails."
  (gdocs--fetch-edit-state-async
   doc-id
   (lambda (state state-err)
     (cond
      (state-err (funcall callback nil state-err))
      ((null state) (funcall callback nil "no edit state"))
      (t
       (gdocs--docos-sync-raw-async
        doc-id state
        (lambda (raw fetch-err)
          (cond
           (fetch-err (funcall callback nil
                               (format "docos sync: %s" fetch-err)))
           (t (condition-case sig
                  (funcall callback
                           (gdocs--parse-docos-sync-response raw)
                           nil)
                (error (funcall callback nil
                                (format "docos parse: %s"
                                        (error-message-string sig))))))))))))))

(defun gdocs-debug-comments-fetch (&optional doc-id)
  "Interactive: dump the /docos/p/sync response + parsed comments.
Output lands in *gdocs-comments-debug*."
  (interactive)
  (let* ((doc-id (gdocs--get-doc-id doc-id))
         (buf (get-buffer-create "*gdocs-comments-debug*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format ";; gdocs-debug-comments-fetch %s at %s\n;; …fetching…\n"
                        doc-id (gdocs--now-iso)))))
    (display-buffer buf)
    (gdocs--fetch-edit-state-async
     doc-id
     (lambda (state state-err)
       (cond
        (state-err (with-current-buffer buf
                     (let ((inhibit-read-only t))
                       (goto-char (point-max))
                       (insert (format ";; state error: %s\n" state-err)))))
        (t (gdocs--docos-sync-raw-async
            doc-id state
            (lambda (raw fetch-err)
              (with-current-buffer buf
                (let ((inhibit-read-only t))
                  (goto-char (point-max))
                  (cond
                   (fetch-err (insert (format ";; ERROR: %s\n" fetch-err)))
                   (t (let ((parsed (ignore-errors
                                      (gdocs--parse-docos-sync-response raw))))
                        (insert (format ";; raw: %d bytes\n" (length raw)))
                        (insert (format ";; parsed: %d comments\n\n"
                                        (length parsed)))
                        (dolist (c parsed)
                          (insert (format "[fn:%d] %s\n" (car c) (cdr c))))
                        (insert "\n---RAW---\n")
                        (insert raw))))))))))))))

(defun gdocs--save-request-async (doc-id state commands callback)
  "Async sibling of `gdocs--save-request'.
CALLBACK = `(funcall CB PARSED-JSON ERR)'.
On 2xx, PARSED-JSON is the XSSI-stripped JSON alist and ERR is nil.
On non-2xx, PARSED-JSON is nil and ERR is a plist
\(:http-code :err-code :di :body) suitable for `gdocs--throttle-error-p'
on a synthetic (gdocs-save-rejected . ERR) signal data shape.
On curl error, ERR is a string."
  (let* ((token (plist-get state :token))
         (ouid (plist-get state :ouid))
         (rev (plist-get state :revision))
         (smv (or (plist-get state :smv) 2147483647))
         (smb-seg (plist-get state :smb-seg))
         (req-id (gdocs--session-next-reqid))
         (sid gdocs--session-sid)
         (smb-pair (if smb-seg
                       (format "[%d, %s]" smv smb-seg)
                     (format "[%d]" smv)))
         (qs (concat "id=" doc-id
                     "&sid=" sid
                     "&vc=1&c=1&w=1&flr=0"
                     (format "&smv=%d" smv)
                     "&smb=" (url-hexify-string smb-pair)
                     "&token=" (url-hexify-string token)
                     "&ouid=" ouid
                     "&includes_info_params=true"
                     "&cros_files=false&nded=false"
                     "&tab=t.0"))
         (url (format "https://docs.google.com/document/u/0/d/%s/save?%s"
                      doc-id qs))
         (bundles (json-encode
                   (vector
                    `((commands . ,(vconcat commands))
                      (sid . ,sid)
                      (reqId . ,req-id)))))
         (form (format "rev=%s&bundles=%s"
                       (number-to-string rev)
                       (url-hexify-string bundles)))
         (headers (append
                   `(("Content-Type" . "application/x-www-form-urlencoded;charset=utf-8")
                     ("X-Same-Domain" . "1")
                     ("X-Rel-Id" . "30a.558e52c.s")
                     ("X-Build" . "editors.documents-frontend_20260513.00_p2")
                     ("X-Client-Deadline-Ms" . "20000")
                     ("Origin" . "https://docs.google.com")
                     ("Referer" . ,(format "https://docs.google.com/document/d/%s/edit" doc-id))
                     ("User-Agent" . ,gdocs-default-user-agent))
                   (gdocs--auth-headers))))
    (gdocs--curl-async
     url "POST" headers form
     (lambda (raw code err)
       (gdocs--save-response-dispatch raw code err callback)))))

(defun gdocs--save-response-dispatch (raw code err callback)
  "Decode a /save response and forward (PARSED-JSON ERR) to CALLBACK."
  (cond
   (err (funcall callback nil err))
   ((and (integerp code) (>= code 200) (< code 300))
    (let ((stripped (gdocs--strip-xssi (or raw ""))))
      (condition-case sig
          (let ((json-array-type 'list)
                (json-object-type 'alist))
            (funcall callback (json-read-from-string stripped) nil))
        (error
         (funcall callback nil
                  (format "json-read: %s on %s"
                          (error-message-string sig)
                          (substring stripped 0
                                     (min 200 (length stripped)))))))))
   (t
    (let* ((body (or raw ""))
           (parsed (gdocs--parse-save-error-body body))
           (err-code (car parsed))
           (di (cdr parsed)))
      (funcall callback nil
               (list :http-code code :err-code err-code :di di
                     :body (substring body 0
                                      (min 300 (length body)))))))))

(defun gdocs--run-op-async (doc-id state op callback &optional attempt)
  "Async sibling of `gdocs--run-op'.
CALLBACK = `(funcall CB NEW-REV ERR)'. ERR is nil on success, otherwise
a string (user-recoverable). Retries once on a 550/err-13 throttle, with
state refetched in between, as the sync path does."
  (let ((attempt (or attempt 1)))
    (gdocs--save-request-async
     doc-id state (list op)
     (lambda (resp err)
       (cond
        ((null err)
         (let* ((meta (cdr (assq 'metadata resp)))
                (server-rev (cdr (assq 'serverRevision meta)))
                (ranges (cdr (assq 'revisionRanges resp)))
                (range-rev (and ranges
                                (let ((last (car (last ranges))))
                                  (and last (car (last last))))))
                (new-rev (cond
                          ((and server-rev range-rev) (max server-rev range-rev))
                          (t (or range-rev server-rev)))))
           (if new-rev
               (funcall callback new-rev nil)
             (funcall callback nil "/save returned no new revision"))))
        ((and (listp err)
              (= (or (plist-get err :http-code) 0) 550)
              (= (or (plist-get err :err-code) 0) 13)
              (plist-get err :di)
              (< attempt 2))
         (gdocs-log 'warn "/save rejected (err 13, di %s) attempt %d, retrying in %ds"
                    (plist-get err :di) attempt gdocs--rate-limit-retry-delay)
         (run-with-timer
          gdocs--rate-limit-retry-delay nil
          (lambda ()
            (gdocs--fetch-edit-state-async
             doc-id
             (lambda (new-state state-err)
               (if state-err
                   (funcall callback nil
                            (format "state refetch failed: %s" state-err))
                 (gdocs--run-op-async doc-id (or new-state state)
                                      op callback (1+ attempt))))))))
        ((listp err)
         (funcall callback nil
                  (format "/save rejected (http %s err %s)"
                          (plist-get err :http-code) (plist-get err :err-code))))
        (t (funcall callback nil (format "%s" err))))))))

(defun gdocs--finalize-push-props (new-rev local-body)
  "Write GDOC_REVISION / hash / synced-at on the current buffer.
Caller must already be inside `with-current-buffer'."
  (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))
  (gdocs--put-top-property "GDOC_CONTENT_HASH"
                           (secure-hash 'sha256 local-body))
  (gdocs--put-top-property "GDOC_SYNCED_AT" (gdocs--now-iso))
  (gdocs--mark-synced))

(defun gdocs--apply-in-place-region-async
    (doc-id state remote-body region buffer callback)
  "Async sibling of `gdocs--apply-in-place-region'.
Runs ds (if any) → refetch state for verify → is (if any). CALLBACK is
`(funcall CB NEW-REV ERR)'."
  (let* ((start (plist-get region :start))
         (rem-end (plist-get region :rem-end))
         (deleted (plist-get region :deleted))
         (inserted (plist-get region :inserted))
         (ot-body (plist-get state :ot-body))
         (ot-range (gdocs--locate-edit-in-ot
                    ot-body remote-body start rem-end)))
    (cond
     ((null ot-range)
      (funcall callback nil
               "could not locate edit context uniquely in OT body"))
     (t
      (let* ((ot-start (car ot-range))
             (ot-end (cdr ot-range))
             (do-is (lambda (state-for-is callback2)
                      (if (zerop (length inserted))
                          (funcall callback2 nil nil)
                        (gdocs--run-op-async
                         doc-id state-for-is
                         `((ty . "is") (ibi . ,ot-start) (s . ,inserted))
                         (lambda (rev err)
                           (when (and rev (buffer-live-p buffer))
                             (with-current-buffer buffer
                               (gdocs--shift-buffer-anchors
                                'is ot-start (length inserted))
                               (gdocs--put-top-property
                                "GDOC_REVISION" (number-to-string rev))))
                           (funcall callback2 rev err)))))))
        (cond
         ((length> deleted 0)
          (gdocs--run-op-async
           doc-id state
           `((ty . "ds") (si . ,ot-start) (ei . ,(1- ot-end)))
           (lambda (ds-rev ds-err)
             (cond
              (ds-err (funcall callback nil ds-err))
              (t
               (when (and ds-rev (buffer-live-p buffer))
                 (with-current-buffer buffer
                   (gdocs--shift-buffer-anchors
                    'ds ot-start (length deleted))
                   (gdocs--put-top-property
                    "GDOC_REVISION" (number-to-string ds-rev))))
               (gdocs--fetch-edit-state-async
                doc-id
                (lambda (refreshed s-err)
                  (cond
                   (s-err (funcall callback nil s-err))
                   ((not (equal (plist-get refreshed :revision) ds-rev))
                    (funcall callback nil
                             (format "state refetch saw rev %S, expected %S"
                                     (plist-get refreshed :revision)
                                     ds-rev)))
                   (t (funcall do-is refreshed
                               (lambda (is-rev is-err)
                                 (funcall callback
                                          (or is-rev ds-rev)
                                          is-err))))))))))))
         (t
          (funcall do-is state callback))))))))

(defun gdocs--apply-multi-regions-async
    (doc-id state remote-body regions buffer callback)
  "Apply REGIONS (latest-first) sequentially, refetching state between.
CALLBACK = `(funcall CB FINAL-REV ERR)'."
  (if (null regions)
      (funcall callback nil nil)
    (let ((region (car regions))
          (rest (cdr regions)))
      (gdocs--apply-in-place-region-async
       doc-id state remote-body region buffer
       (lambda (rev err)
         (cond
          (err (funcall callback rev err))
          ((null rest) (funcall callback rev nil))
          (t
           (run-with-timer
            gdocs--inter-region-delay nil
            (lambda ()
              (gdocs--fetch-edit-state-async
               doc-id
               (lambda (next-state s-err)
                 (if s-err
                     (funcall callback rev s-err)
                   (gdocs--apply-multi-regions-async
                    doc-id next-state remote-body rest buffer
                    (lambda (final-rev fr-err)
                      (funcall callback (or final-rev rev) fr-err)))))))))))))))

(defun gdocs--apply-push-async
    (doc-id state local-body remote-body buffer callback)
  "Async sibling of `gdocs--apply-push'.
CALLBACK = `(funcall CB NEW-REV ERR)'. BUFFER is where property writes go."
  (let* ((ot-body (plist-get state :ot-body))
         (ot-len (gdocs--ot-body-length ot-body))
         (local-stripped (car (gdocs--strip-heading-drawers local-body)))
         (prepended (gdocs--diff-prepend remote-body local-stripped))
         (appended (gdocs--diff-append remote-body local-stripped))
         (finalize
          (lambda (rev err extra)
            (when (and rev (buffer-live-p buffer))
              (with-current-buffer buffer
                (gdocs--finalize-push-props rev local-body)))
            (when (and rev (not err))
              (gdocs-log 'info "Pushed %s (rev %s)%s" doc-id rev (or extra "")))
            (funcall callback rev err))))
    (cond
     ;; OT-encode backend: rebuild the doc-model from the buffer and ship
     ;; a single multi-op /save bundle (ds + is + styles + entities). The
     ;; plain-text diff branches below are bypassed since this is a full
     ;; replacement, not a diff.
     ((memq gdocs-push-backend '(ot-encode ot-incremental))
      (let* ((new-doc (gdocs-dm-from-org local-body))
             (backend gdocs-push-backend)
             (cmds
              (cond
               ((eq backend 'ot-incremental)
                (let* ((ot-ops (plist-get state :ot-ops))
                       (rev (plist-get state :revision))
                       (title (plist-get state :title))
                       (old-doc (and ot-ops
                                     (gdocs-dm-from-ops
                                      rev doc-id title (or ot-body "") ot-ops))))
                  (if old-doc
                      (gdocs-dm-to-incremental-save-commands old-doc new-doc)
                    ;; No live ops parsed — fall back to full-replace.
                    (gdocs-dm-to-save-commands ot-len new-doc))))
               (t (gdocs-dm-to-save-commands ot-len new-doc))))
             (label (cond ((null cmds) nil)
                          ((eq backend 'ot-incremental) "ot-incremental")
                          (t "ot-encode"))))
        (cond
         ((null cmds)
          (gdocs-log 'info "Pushed %s: no-op (docs equal)" doc-id)
          (funcall callback nil nil))
         (t
          (gdocs--save-request-async
           doc-id state cmds
           (lambda (parsed err)
             (cond
              (err (funcall callback nil (format "%s push failed: %S" label err)))
              (t
               (let* ((meta (cdr (assq 'metadata parsed)))
                      (server-rev (cdr (assq 'serverRevision meta)))
                      (ranges (cdr (assq 'revisionRanges parsed)))
                      (range-rev (and ranges
                                      (let ((last (car (last ranges))))
                                        (and last (car (last last))))))
                      (new-rev (cond
                                ((and server-rev range-rev)
                                 (max server-rev range-rev))
                                (t (or range-rev server-rev)))))
                 (if new-rev
                     (funcall finalize new-rev nil
                              (format ", %s (%d ops)" label (length cmds)))
                   (funcall callback nil
                            (format "%s push: no rev in response" label))))))))))))
     (prepended
      (gdocs--run-op-async
       doc-id state
       `((ty . "is") (ibi . 1) (s . ,prepended))
       (lambda (rev err)
         (when (and rev (buffer-live-p buffer))
           (with-current-buffer buffer
             (gdocs--shift-buffer-anchors 'is 1 (length prepended))))
         (funcall finalize rev err
                  (format ", +%d prepended chars" (length prepended))))))
     ((and appended ot-body)
      (gdocs--run-op-async
       doc-id state
       `((ty . "is") (ibi . ,(1+ ot-len)) (s . ,appended))
       (lambda (rev err)
         (funcall finalize rev err
                  (format ", +%d appended chars" (length appended))))))
     (ot-body
      (let* ((para-regions (gdocs--diff-paragraphs remote-body local-stripped))
             (n-regions (length para-regions)))
        (cond
         ((or (zerop n-regions) (= n-regions 1))
          (let ((single (gdocs--diff-single-region
                         remote-body local-stripped)))
            (if single
                (gdocs--apply-in-place-region-async
                 doc-id state remote-body single buffer
                 (lambda (rev err) (funcall finalize rev err nil)))
              (funcall callback nil nil))))
         (t
          (gdocs--apply-multi-regions-async
           doc-id state remote-body
           (nreverse (copy-sequence para-regions)) buffer
           (lambda (rev err) (funcall finalize rev err nil)))))))
     (t
      (funcall callback nil
               "edit shape not yet supported (non-contiguous diff, or change crosses table/list structure)")))))

(defun gdocs--diff-prepend (remote local)
  "If LOCAL = NEW + REMOTE for some NEW, return NEW; else nil.
Detects a pure-prepend edit — the only edit shape we can push without
mapping Google's OT index space (insert at ibi=1 always works)."
  (and (> (length local) (length remote))
       (string-suffix-p remote local)
       (substring local 0 (- (length local) (length remote)))))

(defun gdocs--diff-append (remote local)
  "If LOCAL = REMOTE + NEW for some NEW, return NEW; else nil.
Detects a pure-append edit. Push uses the OT-body length from the
/edit page model chunk to compute the insertion index."
  (and (> (length local) (length remote))
       (string-prefix-p remote local)
       (substring local (length remote))))

(defun gdocs--split-paragraphs (text)
  "Return list of (PARAGRAPH-WITH-TRAILING-DELIM . START-OFFSET-IN-TEXT).
Splits TEXT on `\\n\\n'; each chunk *includes* its trailing `\\n\\n' so
char ranges line up trivially when we delete or replace whole paragraphs.
The final chunk has no trailing delimiter if TEXT didn't end in one."
  (let ((result nil) (i 0) (start 0) (n (length text)))
    (while (< i n)
      (if (and (< (1+ i) n)
               (= (aref text i) ?\n)
               (= (aref text (1+ i)) ?\n))
          (progn
            (push (cons (substring text start (+ i 2)) start) result)
            (setq i (+ i 2) start i))
        (cl-incf i)))
    (when (< start n)
      (push (cons (substring text start n) start) result))
    (nreverse result)))

(defun gdocs--lcs-pairs (a b)
  "Return ascending list of (I . J) pairs forming a longest common subsequence.
A and B are vectors; matching is by `equal'. Classic O(N·M) DP."
  (let* ((na (length a))
         (nb (length b))
         (w (1+ nb))
         (dp (make-vector (* (1+ na) w) 0)))
    (dotimes (i na)
      (dotimes (j nb)
        (aset dp (+ (* (1+ i) w) (1+ j))
              (if (equal (aref a i) (aref b j))
                  (1+ (aref dp (+ (* i w) j)))
                (max (aref dp (+ (* i w) (1+ j)))
                     (aref dp (+ (* (1+ i) w) j)))))))
    (let ((pairs nil) (i na) (j nb))
      (while (and (> i 0) (> j 0))
        (cond
         ((equal (aref a (1- i)) (aref b (1- j)))
          (push (cons (1- i) (1- j)) pairs)
          (cl-decf i) (cl-decf j))
         ((> (aref dp (+ (* (1- i) w) j))
             (aref dp (+ (* i w) (1- j))))
          (cl-decf i))
         (t (cl-decf j))))
      pairs)))

(defun gdocs--diff-paragraphs (remote local)
  "Return a list of disjoint change-region plists between REMOTE and LOCAL.
Splits both strings into paragraphs (`gdocs--split-paragraphs'), aligns
them via LCS, and emits one region per maximal misaligned span.
Each plist has the same shape as `gdocs--diff-single-region'
\(`:start :rem-end :loc-end :deleted :inserted'). Regions are ordered
by remote position; runs of length zero are skipped.

Returns nil if REMOTE and LOCAL are paragraph-identical (the prefix/
suffix path is preferred for sub-paragraph edits)."
  (let* ((rpar (gdocs--split-paragraphs remote))
         (lpar (gdocs--split-paragraphs local))
         (r-texts (vconcat (mapcar #'car rpar)))
         (l-texts (vconcat (mapcar #'car lpar)))
         (r-starts (mapcar #'cdr rpar))
         (l-starts (mapcar #'cdr lpar))
         (na (length r-texts))
         (nb (length l-texts))
         (pairs (gdocs--lcs-pairs r-texts l-texts))
         (regions nil)
         (ri 0) (li 0))
    (cl-labels
        ((r-start-at (k) (if (< k na) (nth k r-starts) (length remote)))
         (l-start-at (k) (if (< k nb) (nth k l-starts) (length local)))
         (emit (rs re ls le)
           (unless (and (= rs re) (= ls le))
             (push (list :start rs
                         :rem-end re
                         :loc-end le
                         :deleted (substring remote rs re)
                         :inserted (substring local ls le))
                   regions))))
      (dolist (p pairs)
        (let ((rj (car p)) (lj (cdr p)))
          (emit (r-start-at ri) (r-start-at rj)
                (l-start-at li) (l-start-at lj))
          (setq ri (1+ rj) li (1+ lj))))
      ;; Trailing tail after the last matched pair (or whole doc if no matches).
      (emit (r-start-at ri) (length remote)
            (l-start-at li) (length local)))
    (nreverse regions)))

(defun gdocs--diff-single-region (remote local)
  "Return a plist describing a contiguous one-region diff, or nil.
Computes the longest common prefix and suffix between REMOTE and LOCAL
and treats the rest as a single replacement.

Plist keys:
  :start    — common prefix length (= position of the change in REMOTE
              and LOCAL, since the prefix matches in both).
  :rem-end  — end of the replaced range in REMOTE (exclusive).
  :loc-end  — end of the replaced range in LOCAL (exclusive).
  :deleted  — substring of REMOTE that goes away.
  :inserted — substring of LOCAL that takes its place.

Returns nil for the no-op case (REMOTE = LOCAL). Always returns a plist
for any other input — callers decide whether the region is too large or
crosses structural boundaries to be safe to push."
  (let* ((rn (length remote))
         (ln (length local)))
    (unless (string= remote local)
      (let* ((min-len (min rn ln))
             (pre 0))
        (while (and (< pre min-len)
                    (= (aref remote pre) (aref local pre)))
          (cl-incf pre))
        (let* ((suf 0)
               (max-suf (- min-len pre)))
          (while (and (< suf max-suf)
                      (= (aref remote (- rn suf 1))
                         (aref local (- ln suf 1))))
            (cl-incf suf))
          (list :start pre
                :rem-end (- rn suf)
                :loc-end (- ln suf)
                :deleted (substring remote pre (- rn suf))
                :inserted (substring local pre (- ln suf))))))))

(defun gdocs--session-load-from-disk ()
  "Populate `gdocs--session-sid' / `gdocs--session-req-id' from disk.
Returns t if a session was loaded, nil if the file was absent or unreadable."
  (when (file-readable-p gdocs-session-file)
    (condition-case _
        (with-temp-buffer
          (insert-file-contents gdocs-session-file)
          (let ((data (read (current-buffer))))
            (when (and (plist-get data :sid)
                       (integerp (plist-get data :req-id)))
              (setq gdocs--session-sid (plist-get data :sid))
              (setq gdocs--session-req-id (plist-get data :req-id))
              t)))
      (error nil))))

(defun gdocs--session-write-to-disk ()
  "Persist `gdocs--session-sid' / `gdocs--session-req-id' to disk."
  (when (and gdocs--session-sid gdocs--session-req-id)
    (let ((dir (file-name-directory gdocs-session-file)))
      (unless (file-directory-p dir)
        (make-directory dir 'parents)))
    (with-temp-file gdocs-session-file
      (prin1 (list :sid gdocs--session-sid
                   :req-id gdocs--session-req-id
                   :saved-at (float-time))
             (current-buffer)))))

(defun gdocs--session-ensure ()
  "Make sure `gdocs--session-sid' / `gdocs--session-req-id' are populated.
Loads from disk on first call; generates a fresh SID if no file exists."
  (unless (and gdocs--session-sid gdocs--session-req-id)
    (or (gdocs--session-load-from-disk)
        (progn
          (setq gdocs--session-sid
                (format "%016x"
                        (logior (ash (random (expt 2 32)) 32)
                                (random (expt 2 32)))))
          (setq gdocs--session-req-id 0)
          (gdocs--session-write-to-disk)))))

(defun gdocs--session-next-reqid ()
  "Return the next reqId for /save, bump the counter, and persist."
  (gdocs--session-ensure)
  (cl-incf gdocs--session-req-id)
  (gdocs--session-write-to-disk)
  gdocs--session-req-id)

(defun gdocs-session-reset ()
  "Drop the on-disk session and force a fresh SID on next /save.
Use this if Google has marked the current SID bad (rare)."
  (interactive)
  (setq gdocs--session-sid nil
        gdocs--session-req-id nil)
  (when (file-exists-p gdocs-session-file)
    (delete-file gdocs-session-file))
  (when (called-interactively-p 'any)
    (message "gdocs session reset")))

(defun gdocs--throttle-error-p (err)
  "Return non-nil if ERR is a `gdocs-save-rejected' with the throttle shape.
Throttle signature observed empirically: HTTP 550, err-code 13, plus a
`di' counter. ERR's data must be a plist (the format emitted by
`gdocs--curl-post' on non-2xx)."
  (and (eq (car err) 'gdocs-save-rejected)
       (let ((data (cdr err)))
         (and (= (or (plist-get data :http-code) 0) 550)
              (= (or (plist-get data :err-code) 0) 13)
              (plist-get data :di)))))

(defun gdocs--run-op (doc-id state op)
  "Send a single OT op against STATE; return the new revision (int).

Post-op rev comes from `revisionRanges' (last entry). `serverRevision'
can lag (reports pre-op rev when the server advanced); we take the max
defensively.

On a `gdocs-save-rejected' with throttle shape (HTTP 550 + err-code 13),
sleeps `gdocs--rate-limit-retry-delay' seconds, refetches STATE, retries
once. A second rejection surfaces a recoverable `user-error' — callers
should not assume the doc is unchanged, since a prior op in the same
push may have committed. /save throttling is probabilistic per-request,
so a subsequent manual push will often succeed."
  (let ((attempt 0)
        (result nil))
    (while (and (null result) (< attempt 2))
      (cl-incf attempt)
      (condition-case err
          (let* ((resp (gdocs--save-request doc-id state (list op)))
                 (meta (cdr (assq 'metadata resp)))
                 (server-rev (cdr (assq 'serverRevision meta)))
                 (ranges (cdr (assq 'revisionRanges resp)))
                 (range-rev (and ranges
                                 (let ((last (car (last ranges))))
                                   (and last (car (last last))))))
                 (new-rev (cond
                           ((and server-rev range-rev) (max server-rev range-rev))
                           (t (or range-rev server-rev)))))
            (unless new-rev
              (user-error "gdocs: /save returned no new revision (resp=%S)" resp))
            (setq result new-rev))
        (gdocs-save-rejected
         (cond
          ((and (gdocs--throttle-error-p err) (< attempt 2))
           (gdocs-log 'warn "/save rejected (err 13, di %s) attempt %d, retrying in %ds"
                      (plist-get (cdr err) :di) attempt
                      gdocs--rate-limit-retry-delay)
           (sleep-for gdocs--rate-limit-retry-delay)
           (let ((refreshed (gdocs--fetch-edit-state doc-id)))
             (when refreshed (setq state refreshed))))
          ((gdocs--throttle-error-p err)
           (user-error
            "gdocs: /save rejected (err 13) after %d attempts. Retry the push; rev will resync."
            attempt))
          (t (signal (car err) (cdr err)))))))
    result))

(defun gdocs--strip-heading-drawers (body)
  "Strip per-heading `:PROPERTIES:' drawers from BODY.
Returns (STRIPPED . ANCHORS) where ANCHORS is a list of
(CONTENT-START . OT-ANCHOR) sorted by position. CONTENT-START is the
0-based position in STRIPPED of the first character after the
heading's drawer (i.e. the start of the heading's content). OT-ANCHOR
is the integer value of `:GDOC_OT_START:' inside the drawer.

Headings whose drawer has no `:GDOC_OT_START:' are kept (drawer left in
place) but get no anchor entry."
  (let ((anchors nil))
    (with-temp-buffer
      (insert body)
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ .+$" nil t)
        (forward-line 1)
        (when (looking-at "^:PROPERTIES:\n")
          (let* ((drawer-start (point))
                 (drawer-end (and (re-search-forward "^:END:[ \t]*\n" nil t)
                                  (point)))
                 (drawer-text (and drawer-end
                                   (buffer-substring-no-properties
                                    drawer-start drawer-end)))
                 (anchor (and drawer-text
                              (string-match "^:GDOC_OT_START: \\([0-9]+\\)$"
                                            drawer-text)
                              (string-to-number (match-string 1 drawer-text)))))
            (when (and drawer-end anchor)
              (delete-region drawer-start drawer-end)
              (push (cons (1- drawer-start) anchor) anchors)))))
      (cons (buffer-string) (nreverse anchors)))))

(defun gdocs--shift-buffer-anchors (op-kind ot-pos count)
  "Shift `:GDOC_OT_START:' anchors in the current buffer after a push.

OP-KIND is `is' (insert) or `ds' (delete). OT-POS is the OT position
where the op started; COUNT is the number of codepoints inserted or
deleted.

`is' at OT-POS with COUNT codepoints: anchors with OT-start >= OT-POS
shift by +COUNT.
`ds' at [OT-POS, OT-POS+COUNT): anchors with OT-start >= OT-POS+COUNT
shift by -COUNT."
  (let ((threshold (pcase op-kind
                     ('is ot-pos)
                     ('ds (+ ot-pos count))
                     (_ (error "gdocs--shift-buffer-anchors: bad op %S" op-kind))))
        (delta (pcase op-kind ('is count) ('ds (- count)))))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^:GDOC_OT_START: \\([0-9]+\\)$" nil t)
        (let ((current (string-to-number (match-string 1))))
          (when (>= current threshold)
            (replace-match (format ":GDOC_OT_START: %d" (+ current delta))
                           t t)))))))

(defun gdocs--whitespace-char-p (c)
  "Non-nil if C is space, tab, NBSP, or newline.
Treated as one equivalence class by `gdocs--relaxed-newlines-regexp'
because html-to-org and OT disagree on whitespace: html-to-org maps
runs of spaces to `(sp)(NBSP)(sp)' and strips trailing whitespace
before newlines, while OT keeps everything verbatim."
  (or (= c ?\s) (= c ?\t) (= c #x00a0) (= c ?\n)))

(defun gdocs--relaxed-newlines-regexp (s)
  "Return a regexp matching S with whitespace runs relaxed to `[ \\t\\240\\n]+'.
Each maximal run of whitespace characters (space, tab, NBSP, newline) in
S is replaced with that character-class; the rest is `regexp-quote'd.
This handles three sources of OT-vs-html-export divergence:
- paragraph separators (`\\n\\n' in html-to-org vs `\\n' in OT);
- multi-space runs converted to `(sp)(NBSP)(sp)' by html-to-org;
- trailing whitespace before newlines kept in OT, stripped in html-to-org.
The empty-run requirement (`+') still enforces that *some* whitespace
exists between adjacent words on both sides — a word-boundary mismatch
won't false-match."
  (let ((parts nil)
        (i 0)
        (n (length s)))
    (while (< i n)
      (if (gdocs--whitespace-char-p (aref s i))
          (progn
            (while (and (< i n) (gdocs--whitespace-char-p (aref s i)))
              (cl-incf i))
            (push "[ \t \n]+" parts))
        (let ((j i))
          (while (and (< j n)
                      (not (gdocs--whitespace-char-p (aref s j))))
            (cl-incf j))
          (push (regexp-quote (substring s i j)) parts)
          (setq i j))))
    (apply #'concat (nreverse parts))))

(defun gdocs--find-stripped-idx (offsets target)
  "Return smallest i such that OFFSETS[i] >= TARGET, or (length OFFSETS).
OFFSETS is the surviving-char→original-index map produced by
`gdocs--strip-org-markup'; this is how we project an original-text
position onto its stripped-text counterpart."
  (let ((i 0) (n (length offsets)))
    (while (and (< i n) (< (aref offsets i) target))
      (cl-incf i))
    i))

(defun gdocs--locate--result-from-match (map del-start del-end)
  "Helper: build (OT-START . OT-END) from match positions in plain.
Returns nil if positions are out of MAP's range — callers should treat
that as `locate failed' and route through the append/prepend branches."
  (let ((n (length map)))
    (cond
     ;; Pure insert at end of plain: no OT position to anchor on via map.
     ;; Caller's append branch handles this; locate returns nil so we don't
     ;; pretend to know an OT position past the body.
     ((>= del-start n) nil)
     ((> del-end del-start)
      (when (<= del-end n)
        (cons (aref map del-start)
              (1+ (aref map (1- del-end))))))
     (t
      (cons (aref map del-start)
            (aref map del-start))))))

(defun gdocs--locate-edit-in-ot (ot-body remote-body start rem-end)
  "Locate the OT range corresponding to a diff at [START, REM-END) in REMOTE-BODY.

Two-pass strategy:
  1. Anchored full-document match. Strip markup from the entire
     REMOTE-BODY, build a regex `^pre del post$' with newline runs
     relaxed to `\\n+', and apply it to the OT plain view. A single
     match across the whole doc is unique by construction and pins the
     edit position exactly, regardless of repeated context elsewhere.
  2. Fallback: windowed context-match. If the full-doc anchor fails
     (stripped REMOTE-BODY doesn't equal the OT plain view — e.g. an
     html-to-org artifact introduced a character that isn't in OT),
     widen a slice around the edit until the regex matches unambiguously.

Markup-stripping lets us match edits whose context includes `* ' heading
prefixes, `- ' / `1. ' list markers, or `:PROPERTIES:' drawers — OT plain
has none of those, so a verbatim needle would fail. The offset vector
returned by `gdocs--strip-org-markup' maps stripped indices back to the
original text so the position math stays anchored to remote-body's
coordinates.

Returns (OT-START . OT-END) where OT-END is the OT position one past the
last deleted codepoint (or = OT-START for a pure insert). Returns nil if
no unique match — logs a debug summary so callers can see why."
  (let* ((plain+map (gdocs--ot-plain-and-map ot-body))
         (plain (car plain+map))
         (map (cdr plain+map)))
    (or
     ;; --- Pass 1: anchored full-document match. ---
     (let* ((sm (gdocs--strip-org-markup remote-body))
            (stripped (car sm))
            (offsets (cdr sm))
            (s-start (gdocs--find-stripped-idx offsets start))
            (s-end (gdocs--find-stripped-idx offsets rem-end)))
       (when (and (<= s-start (length stripped))
                  (<= s-end (length stripped))
                  (<= s-start s-end))
         (let* ((pre (substring stripped 0 s-start))
                (del (substring stripped s-start s-end))
                (post (substring stripped s-end))
                (anchored-re
                 (concat "\\`\\(" (gdocs--relaxed-newlines-regexp pre) "\\)"
                         "\\(" (gdocs--relaxed-newlines-regexp del) "\\)"
                         "\\(" (gdocs--relaxed-newlines-regexp post) "\\)\\'")))
           (when (string-match anchored-re plain)
             (gdocs--locate--result-from-match
              map (match-beginning 2) (match-end 2))))))
     ;; --- Pass 2: windowed context-match fallback. ---
     (let* ((max-window (max (length remote-body) (length plain)))
            (window 4)
            (found nil)
            (give-up nil))
       (while (and (not found) (not give-up))
         (let* ((b-start (max 0 (- start window)))
                (b-end (min (length remote-body) (+ rem-end window)))
                (slice (substring remote-body b-start b-end))
                (sm (gdocs--strip-org-markup slice))
                (needle (car sm))
                (offsets (cdr sm))
                (s-start (gdocs--find-stripped-idx offsets (- start b-start)))
                (s-end (gdocs--find-stripped-idx offsets (- rem-end b-start)))
                (pre (substring needle 0 s-start))
                (del (substring needle s-start s-end))
                (post (substring needle s-end))
                (full-re (concat "\\(" (gdocs--relaxed-newlines-regexp pre) "\\)"
                                 "\\(" (gdocs--relaxed-newlines-regexp del) "\\)"
                                 "\\(" (gdocs--relaxed-newlines-regexp post) "\\)"))
                ;; Bias the search to start at the *expected* plain position,
                ;; not from position 0 — that way, when the doc has the same
                ;; pre/del/post pattern earlier (e.g. repeated markers), the
                ;; bias picks the correct one.
                (search-from (max 0 (- start (length pre) 16)))
                (first (and (length> needle 0)
                            (string-match full-re plain search-from))))
           (cond
            ((zerop (length needle))
             (setq give-up t))
            ((null first)
             ;; No match from the biased start — try from 0 once before widening,
             ;; in case the doc has so much structural prefix that the bias
             ;; overshot the real position.
             (let ((unbiased (string-match full-re plain 0)))
               (cond
                ((null unbiased)
                 (if (>= window max-window)
                     (setq give-up t)
                   (setq window (min max-window (* window 2)))))
                ((string-match full-re plain
                                (max (1+ unbiased) (match-end 0)))
                 (if (>= window max-window)
                     (setq give-up t)
                   (setq window (min max-window (* window 2)))))
                (t
                 (let ((r (gdocs--locate--result-from-match
                           map (match-beginning 2) (match-end 2))))
                   (if r
                       (setq found r)
                     (setq give-up t)))))))
            (t
             (let ((del-start (match-beginning 2))
                   (del-end (match-end 2))
                   (next-search-from (max (1+ first) (match-end 0))))
               (cond
                ((string-match full-re plain next-search-from)
                 (if (>= window max-window)
                     (setq give-up t)
                   (setq window (min max-window (* window 2)))))
                (t
                 (let ((r (gdocs--locate--result-from-match
                           map del-start del-end)))
                   (if r
                       (setq found r)
                     ;; Match's position is out of map range (edit at
                     ;; end-of-plain). No OT pos to anchor here — caller
                     ;; should route through the append branch. Stop.
                     (setq give-up t)))))))))
         (when (and (not found) (not give-up)
                    (>= window max-window))
           (setq give-up t)))
       (or found
           (progn
             (gdocs-log 'debug
                        "locate: failed start=%d rem-end=%d plain-len=%d remote-len=%d stripped-eq-plain=%S"
                        start rem-end (length plain) (length remote-body)
                        (string= (car (gdocs--strip-org-markup remote-body))
                                 plain))
             nil))))))

(defun gdocs--anchor-for-position (anchors pos)
  "Return (CONTENT-START . OT-ANCHOR) covering POS.
ANCHORS is the alist from `gdocs--strip-heading-drawers'; assumed
ascending by CONTENT-START. Picks the latest entry with
CONTENT-START <= POS. Falls back to the virtual doc-root anchor
(0 . 1) when no heading anchor precedes POS — every OT body starts at
position 1, so the document root is always a valid anchor for the very
first content."
  (let ((chosen '(0 . 1)))
    (dolist (a anchors)
      (when (<= (car a) pos)
        (setq chosen a)))
    chosen))

(defun gdocs--map-text-range-to-ot (map start end)
  "Return (OT-START . OT-END) for a [START, END) slice of plain text.
MAP is the vector returned by `gdocs--ot-plain-and-map'. OT range is
inclusive of OT-START and exclusive of OT-END+1 in the conventional OT
sense — `ds si=OT-START ei=OT-END' deletes the slice.

Special case: START == END (pure insert) returns the OT position to
pass as `ibi'; OT-END is meaningless and set equal to OT-START."
  (let ((n (length map)))
    (cond
     ;; Pure insert at end of plain text — caller already handles append.
     ((and (= start end) (= start n))
      (error "gdocs: cannot map insert past end of plain text via segment map"))
     ;; Pure insert in the middle — anchor on the next plain char.
     ((= start end)
      (let ((ot (aref map start)))
        (cons ot ot)))
     (t
      (let ((ot-start (aref map start))
            (ot-end (1+ (aref map (1- end)))))
        (cons ot-start ot-end))))))

(defun gdocs--apply-in-place-region (doc-id state remote-body region)
  "Apply ONE in-place change REGION to the doc.
Returns (NEW-REV . NEW-STATE) after the (ds, is) pair completes.
REGION is a plist from `gdocs--diff-single-region' or
`gdocs--diff-paragraphs'. STATE must reflect the doc's *current* rev
and OT body — the caller is responsible for refetching between regions."
  (let* ((start (plist-get region :start))
         (rem-end (plist-get region :rem-end))
         (deleted (plist-get region :deleted))
         (inserted (plist-get region :inserted))
         (ot-body (plist-get state :ot-body))
         (ot-range (or (gdocs--locate-edit-in-ot
                        ot-body remote-body start rem-end)
                       (user-error "gdocs: could not locate edit context uniquely in OT body")))
         (ot-start (car ot-range))
         (ot-end (cdr ot-range))
         (rev nil))
    (when (length> deleted 0)
      (setq rev (gdocs--run-op
                 doc-id state
                 `((ty . "ds") (si . ,ot-start) (ei . ,(1- ot-end)))))
      (gdocs--shift-buffer-anchors 'ds ot-start (length deleted))
      ;; Persist the new rev immediately. If the following `is' fails,
      ;; the buffer still tracks the server's actual rev so the next
      ;; push can diff from current state instead of being refused.
      (gdocs--put-top-property "GDOC_REVISION" (number-to-string rev))
      (setq state (gdocs--fetch-edit-state doc-id))
      (unless (and state (equal (plist-get state :revision) rev))
        (user-error "gdocs: state refetch after delete saw rev %S, expected %S"
                    (and state (plist-get state :revision)) rev)))
    (when (length> inserted 0)
      (setq rev (gdocs--run-op
                 doc-id state
                 `((ty . "is") (ibi . ,ot-start) (s . ,inserted))))
      (gdocs--shift-buffer-anchors 'is ot-start (length inserted))
      (gdocs--put-top-property "GDOC_REVISION" (number-to-string rev)))
    (gdocs-log 'info
               "Pushed %s (rev %s, edited %d→%d chars at OT %d)"
               doc-id rev (length deleted) (length inserted) ot-start)
    (cons rev state)))

(defun gdocs--apply-push (doc-id state local-body remote-body)
  "Dispatch on diff shape and apply the push.
Strategies, in order:
  1. Pure prepend  → one `is ibi=1' op.
  2. Pure append   → one `is ibi=ot-len+1' op.
  3. Single-region in-place edit (paragraph-level diff returns one
     region) — apply via `gdocs--apply-in-place-region' using the
     prefix/suffix-contracted diff for minimal payload.
  4. Disjoint multi-region edits (paragraph-level diff returns 2+ regions)
     — apply each region in reverse order so positions for earlier
     regions don't get shifted by later ops; state is refetched between
     regions to pick up the advanced revision.
Each in-place op is a single-op POST (multi-op bundles trigger Google's
abuse heuristic — see Push protocol). The final new revision and content
hash are written back to buffer metadata."
  (let* ((ot-body (plist-get state :ot-body))
         (ot-len (gdocs--ot-body-length ot-body))
         (local-stripped (car (gdocs--strip-heading-drawers local-body)))
         (prepended (gdocs--diff-prepend remote-body local-stripped))
         (appended (gdocs--diff-append remote-body local-stripped))
         (new-rev nil))
    (cond
     (prepended
      (setq new-rev (gdocs--run-op
                     doc-id state
                     `((ty . "is") (ibi . 1) (s . ,prepended))))
      (gdocs--shift-buffer-anchors 'is 1 (length prepended))
      (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))
      (gdocs-log 'info "Pushed %s (rev %s, +%d prepended chars)"
                 doc-id new-rev (length prepended)))
     ((and appended ot-body)
      (setq new-rev (gdocs--run-op
                     doc-id state
                     `((ty . "is") (ibi . ,(1+ ot-len)) (s . ,appended))))
      (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))
      (gdocs-log 'info "Pushed %s (rev %s, +%d appended chars)"
                 doc-id new-rev (length appended)))
     (ot-body
      (let* ((para-regions (gdocs--diff-paragraphs remote-body local-stripped))
             (n-regions (length para-regions)))
        (cond
         ((zerop n-regions)
          ;; Paragraph-level diff finds nothing but prepend/append didn't
          ;; match — extremely rare; fall through to single-region.
          (let ((single (gdocs--diff-single-region remote-body local-stripped)))
            (when single
              (setq new-rev (car (gdocs--apply-in-place-region
                                  doc-id state remote-body single))))))
         ((= n-regions 1)
          ;; Single paragraph touched — prefer the contracted single-region
          ;; diff so we ship only the changed substring, not the whole para.
          (let ((single (gdocs--diff-single-region remote-body local-stripped)))
            (setq new-rev (car (gdocs--apply-in-place-region
                                doc-id state remote-body single)))))
         (t
          ;; Disjoint regions — apply latest-first, refetching state.
          ;; Sleep between regions so we don't burst the /save rate budget.
          (let ((regions (nreverse (copy-sequence para-regions)))
                (first t))
            (dolist (region regions)
              (unless first (sleep-for gdocs--inter-region-delay))
              (setq first nil)
              (setq state (gdocs--fetch-edit-state doc-id))
              (let ((res (gdocs--apply-in-place-region
                          doc-id state remote-body region)))
                (setq new-rev (car res)))))))))
     (t
      (user-error
       "gdocs: edit shape not yet supported (non-contiguous diff, or change crosses table/list structure)")))
    ;; new-rev may be nil if no branch produced an op (e.g. the diff
    ;; collapses to a no-op after stripping). Don't write garbage to the
    ;; rev property in that case.
    (when new-rev
      (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))
      (gdocs--put-top-property "GDOC_CONTENT_HASH"
                               (secure-hash 'sha256 local-body))
      (gdocs--put-top-property "GDOC_SYNCED_AT" (gdocs--now-iso))
      (gdocs--mark-synced))
    new-rev))

(defun gdocs-push-remotely (&optional doc-id)
  "Push buffer to remote via the cookie-authenticated /save endpoint.

Supported diff shapes:
  - Pure prepend (`is ibi=1').
  - Pure append (`is ibi=ot-len+1').
  - Single-region replace within plain-paragraph content. The text
    position of the change is mapped to an OT position via the
    `gdocs--ot-plain-and-map' table, then `ds' and `is' are pushed as
    two sequential single-op POSTs.

Refused: edits whose plain-text local view doesn't match the OT
body's plain view (i.e. the diff crosses or sits inside a table or
list), non-contiguous diffs, and stale-rev pushes.

Conflict safety: refuses if remote revision differs from stored
GDOC_REVISION. On success, updates GDOC_REVISION and
GDOC_CONTENT_HASH from the response."
  (interactive)
  (if gdocs--sync-mutex
      (progn (gdocs-log 'warn "Mutex locked - skipping push") nil)
    (setq gdocs--sync-mutex t)
    (let* ((buf (current-buffer))
           (doc-id (gdocs--get-doc-id doc-id))
           (local-rev (org-entry-get (point-min) "GDOC_REVISION" t))
           (local-body (gdocs--buffer-body-as-plain)))
      (unless (and local-rev (not (string-empty-p local-rev)))
        (setq gdocs--sync-mutex nil)
        (user-error "gdocs: no GDOC_REVISION on this buffer — pull first"))
      (gdocs--push-remotely-async-1 doc-id buf local-rev local-body))))

(defun gdocs--push-remotely-async-1 (doc-id buf local-rev local-body)
  "Background driver for `gdocs-push-remotely'.
Single GET on /edit gives both the edit state and the modelChunk we
decode into the org view we diff against. Releases the sync mutex on
completion or error."
  (let ((release (lambda (err)
                   (setq gdocs--sync-mutex nil)
                   (when err (gdocs-log 'warn "Push %s: %s" doc-id err)))))
    (gdocs--fetch-edit-page-async
     doc-id
     (lambda (state html err)
       (let* ((remote-rev (and state (plist-get state :revision)))
              (token (and state (plist-get state :token)))
              (ouid (and state (plist-get state :ouid))))
         (cond
          (err (funcall release err))
          ((null state) (funcall release "empty edit state"))
          ((not (and token ouid remote-rev))
           (funcall release "missing token/ouid/rev"))
          ((not (string= local-rev (number-to-string remote-rev)))
           (funcall release
                    (format "refusing push: remote rev %s != local %s"
                            remote-rev local-rev)))
          (t
           (condition-case sig
               (let ((remote-body (gdocs--ot-remote-org-body doc-id html state)))
                 (cond
                  ((string= (car (gdocs--strip-heading-drawers local-body))
                            remote-body)
                   (setq gdocs--sync-mutex nil)
                   (gdocs-log 'info "Push: no local changes for %s" doc-id))
                  (t
                   (gdocs--apply-push-async
                    doc-id state local-body remote-body buf
                    (lambda (_rev e2)
                      (setq gdocs--sync-mutex nil)
                      (when e2 (gdocs-log 'warn "Push %s: %s" doc-id e2)))))))
             (error (funcall release (error-message-string sig)))))))))))

(defun gdocs-debug-push-state (&optional doc-id out-file)
  "Dump everything `gdocs-push-remotely' sees into OUT-FILE for inspection.
Does NOT push — just captures: local body, remote body, OT state, the
single-region diff, and the locate result (if any). Default OUT-FILE is
\"/tmp/gdocs-push-debug.txt\". Returns the file path."
  (interactive)
  (let* ((doc-id (gdocs--get-doc-id doc-id))
         (out (or out-file "/tmp/gdocs-push-debug.txt"))
         (local-rev (org-entry-get (point-min) "GDOC_REVISION" t))
         (local-body (gdocs--buffer-body-as-plain))
         (html (gdocs--fetch-edit-page-sync doc-id))
         (state (gdocs--parse-edit-state-html html))
         (remote-body (gdocs--ot-remote-org-body doc-id html state))
         (ot-body (and state (plist-get state :ot-body)))
         (remote-rev (and state (plist-get state :revision)))
         (local-stripped (car (gdocs--strip-heading-drawers local-body)))
         (plain (and ot-body (gdocs--ot-plain-text ot-body)))
         (stripped-remote (car (gdocs--strip-org-markup remote-body)))
         (single (gdocs--diff-single-region remote-body local-stripped))
         (paras (gdocs--diff-paragraphs remote-body local-stripped))
         (locate (and single
                      (gdocs--locate-edit-in-ot
                       ot-body remote-body
                       (plist-get single :start)
                       (plist-get single :rem-end)))))
    (with-temp-file out
      (insert (format "doc-id: %s\n" doc-id))
      (insert (format "local-rev: %s\n" local-rev))
      (insert (format "remote-rev: %s\n" remote-rev))
      (insert (format "local-body length: %d\n" (length local-body)))
      (insert (format "remote-body length: %d\n" (length remote-body)))
      (insert (format "ot-body length: %d\n" (length (or ot-body ""))))
      (insert (format "plain (ot minus structural) length: %d\n" (length (or plain ""))))
      (insert (format "stripped-remote length: %d\n" (length stripped-remote)))
      (insert (format "stripped-remote == plain? %S\n"
                      (and plain (string= stripped-remote plain))))
      (insert (format "diff-single-region: %S\n" single))
      (insert (format "diff-paragraphs count: %d\n" (length paras)))
      (insert (format "locate result: %S\n" locate))
      (insert "\n=== local-body ===\n")
      (insert local-body)
      (insert "\n=== remote-body ===\n")
      (insert remote-body)
      (insert "\n=== local-stripped (after strip-heading-drawers) ===\n")
      (insert local-stripped)
      (insert "\n=== ot-body (raw, structural codepoints visible) ===\n")
      (prin1 (or ot-body "") (current-buffer))
      (insert "\n=== plain (ot minus structural) ===\n")
      (insert (or plain ""))
      (insert "\n=== stripped-remote ===\n")
      (insert stripped-remote)
      (when (and plain (not (string= stripped-remote plain)))
        (insert "\n=== first divergence between stripped-remote and plain ===\n")
        (let* ((n (min (length stripped-remote) (length plain)))
               (i 0))
          (while (and (< i n)
                      (= (aref stripped-remote i) (aref plain i)))
            (cl-incf i))
          (insert (format "diverge at index %d of %d/%d\n"
                          i (length stripped-remote) (length plain)))
          (insert (format "stripped-remote[%d-30..%d+30]: %S\n"
                          i i
                          (substring stripped-remote
                                     (max 0 (- i 30))
                                     (min (length stripped-remote) (+ i 30)))))
          (insert (format "plain          [%d-30..%d+30]: %S\n"
                          i i
                          (substring plain
                                     (max 0 (- i 30))
                                     (min (length plain) (+ i 30))))))))
    (message "gdocs-debug-push-state: wrote %s" out)
    out))


;;; Public command — open

(defun gdocs-open (&optional url-or-id)
  "Open a Google Doc. URL-OR-ID may be a URL, doc id, or read from link at point."
  (interactive)
  (let* ((ctx (and (derived-mode-p 'org-mode) (org-element-context)))
         (link (and ctx (eq (org-element-type ctx) 'link)
                    (org-element-property :raw-link ctx)))
         (input (or url-or-id
                    link
                    (read-string "Google Docs URL or ID: ")))
         (doc-id (gdocs--extract-doc-id input))
         (existing (seq-find
                    (lambda (b)
                      (with-current-buffer b
                        (and (derived-mode-p 'org-mode)
                             (string= (or (org-entry-get (point-min) "GDOC_ID" t) "")
                                      doc-id))))
                    (buffer-list))))
    (if existing
        (switch-to-buffer existing)
      ;; Use a placeholder buffer name; pull will set the real title.
      (let ((buffer (generate-new-buffer (format "*gdocs:%s*" doc-id))))
        (with-current-buffer buffer
          (org-mode)
          (erase-buffer)
          (insert (format ":PROPERTIES:\n:GDOC_ID: %s\n:END:\n" doc-id))
          (goto-char (point-min))
          (gdocs-pull-locally doc-id)
          (let* ((new-title (save-excursion
                              (goto-char (point-min))
                              (when (re-search-forward "^#\\+title: \\(.*\\)$" nil t)
                                (string-trim (match-string 1)))))
                 (target-name (format "%s.org"
                                      (if (and new-title (not (string-empty-p new-title)))
                                          new-title doc-id))))
            (rename-buffer target-name t))
          (gdocs-mode 1)
          (switch-to-buffer buffer))))))


;;; Minor mode

(defun gdocs--has-id-p ()
  "Buffer has a GDOC_ID property."
  (and (derived-mode-p 'org-mode)
       (org-entry-get (point-min) "GDOC_ID" t)))

(defun gdocs--auto-sync-tick ()
  "Sync this buffer with its remote Google Doc.

Decision (resolved per tick after a single edit-state probe):
  - Remote rev > local rev   → pull (remote always wins on conflict).
  - Remote rev == local rev and buffer hash differs from
    `gdocs--last-synced-hash' → push the local edits.
  - Otherwise → noop.

Local-edit detection uses a buffer-local hash baseline refreshed by
`gdocs--mark-synced' at every successful pull/push (not
`buffer-modified-p', which doesn't fire for programmatic inserts and
isn't reliable in temp/indirect buffers).

Fully async; the outer timer is re-armed regardless of outcome so a
transient network blip doesn't disable auto-sync."
  (when (and (bound-and-true-p gdocs-mode)
             (gdocs--has-id-p)
             (not gdocs--sync-mutex))
    (let* ((buf (current-buffer))
           (doc-id (gdocs--doc-id-from-buffer)))
      (gdocs--fetch-edit-state-async
       doc-id
       (lambda (state err)
         (when (and (not err) state (buffer-live-p buf))
           (with-current-buffer buf
             (let* ((remote-rev (plist-get state :revision))
                    (local-rev (org-entry-get (point-min) "GDOC_REVISION" t))
                    (have-revs (and remote-rev local-rev
                                    (not (string-empty-p local-rev))))
                    (stale (and have-revs
                                (not (string= local-rev
                                              (number-to-string remote-rev)))))
                    (cur-hash (gdocs--current-body-hash))
                    (dirty (and gdocs--last-synced-hash
                                (not (string= cur-hash
                                              gdocs--last-synced-hash)))))
               (cond
                (stale
                 (gdocs-pull-locally
                  doc-id
                  (lambda (_body p-err)
                    (when (and (not p-err) (buffer-live-p buf))
                      (with-current-buffer buf
                        (gdocs-log 'info "Auto-pulled %s to rev %S"
                                   doc-id remote-rev))))))
                (dirty
                 (gdocs-log 'info "Auto-pushing %s (local edits)" doc-id)
                 (gdocs-push-remotely doc-id)))))))))))

(defun gdocs--enable ()
  (gdocs--mark-synced)
  (let* ((buf (current-buffer))
         (timer nil))
    (setq timer
          (run-with-timer
           gdocs-auto-sync-interval
           gdocs-auto-sync-interval
           (lambda ()
             (if (buffer-live-p buf)
                 (with-current-buffer buf
                   (gdocs--auto-sync-tick))
               (when timer (cancel-timer timer))))))
    (setq gdocs--sync-timer timer)
    (add-hook 'kill-buffer-hook #'gdocs--disable nil t))
  (gdocs-log 'info "gdocs-mode enabled"))

(defun gdocs--disable ()
  (when gdocs--sync-timer
    (cancel-timer gdocs--sync-timer)
    (setq gdocs--sync-timer nil))
  (gdocs-log 'info "gdocs-mode disabled"))

(defun gdocs--mode-line-indicator ()
  "Return a state-aware mode-line string for gdocs-mode.

Suffixes:
  (no suffix) — synced; local matches the last-pulled remote rev.
  *           — buffer-modified-p: there are unsaved local edits."
  (if (buffer-modified-p) " GDocs*" " GDocs"))

(define-minor-mode gdocs-mode
  "Bidirectional sync with Google Docs."
  :lighter (:eval (gdocs--mode-line-indicator))
  :group 'gdocs-mode
  (if gdocs-mode
      (if (gdocs--has-id-p)
          (gdocs--enable)
        (setq gdocs-mode nil)
        (user-error "No GDOC_ID property — use gdocs-open or set the property manually"))
    (gdocs--disable)))

(defun gdocs--maybe-enable ()
  "Auto-enable in org buffers carrying a GDOC_ID."
  (when (and (derived-mode-p 'org-mode)
             (gdocs--has-id-p)
             (not gdocs-mode))
    (gdocs-mode 1)))

(add-hook 'org-mode-hook #'gdocs--maybe-enable)
(add-hook 'find-file-hook #'gdocs--maybe-enable)

(defconst gdocs--url-re
  "\\`https?://docs\\.google\\.com/document/d/[A-Za-z0-9_-]+"
  "Regexp matching a Google Docs document URL we want to intercept.")

(defun gdocs--org-open-link (url)
  "Open a Google Docs URL via `gdocs-open' from `org-open-link-functions'.
This handler only fires for *plain* (unbracketed) URLs at point.
Bracketed `[[url][desc]]' links are intercepted by
`gdocs--org-link-open-advice' on `org-link-open' instead."
  (when (and (stringp url) (string-match-p gdocs--url-re url))
    (gdocs-open url)
    t))

(add-hook 'org-open-link-functions #'gdocs--org-open-link)

(defun gdocs--org-link-open-advice (link &rest _)
  "`:before-until' advice on `org-link-open' that claims Google Docs links.
LINK is the parsed org link element. Returning non-nil suppresses the
default `https' handler (browser)."
  (let ((url (and (eq (org-element-type link) 'link)
                  (or (org-element-property :raw-link link)
                      (let ((type (org-element-property :type link))
                            (path (org-element-property :path link)))
                        (and type path (concat type ":" path)))))))
    (when (and (stringp url) (string-match-p gdocs--url-re url))
      (gdocs-open url)
      t)))

(advice-add 'org-link-open :before-until #'gdocs--org-link-open-advice)

(provide 'gdocs-mode)

;;; gdocs-mode.el ends here
