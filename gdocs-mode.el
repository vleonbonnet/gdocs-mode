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
;; Staleness: GDOC_REVISION scraped from the /edit page is the remote
;; anchor. GDOC_CONTENT_HASH persists the last successful local baseline.
;;
;; Push strategy: the default OT encoder rebuilds text styling and supported
;; structural entities for the cookie-authenticated /save endpoint. The
;; legacy plain backend remains lossy. Unsupported remote capabilities are
;; accounted for centrally and a push is refused unless their preservation is
;; provable.
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
the diff includes list, table, or changed inline-object paragraphs. An
unchanged inline object can remain outside the diff when preflight proves it
is preserved."
  :type '(choice (const :tag "Plain text diff" plain)
                 (const :tag "OT encode (full replace + styles)" ot-encode)
                 (const :tag "OT incremental (paragraph diff)" ot-incremental))
  :group 'gdocs-mode)

(defcustom gdocs-verify-after-save t
  "Refetch the document after a committed OT save and verify its body.

When non-nil, every successful `ot-encode' / `ot-incremental' push is
followed by one /edit refetch whose decoded body must equal the expected
round-trip render of the pushed model; a mismatch is reported as an error
instead of a clean sync.  Set to nil to restore the older behavior of
trusting the /save response revision alone."
  :type 'boolean
  :group 'gdocs-mode)

(defcustom gdocs-docs-tab "t.0"
  "Google Docs tab identifier used in /save and comment requests.

The browser protocol addresses one tab of a multi-tab document.  Most
documents only have the initial tab \"t.0\"."
  :type 'string
  :group 'gdocs-mode)

(defconst gdocs-save-build-header
  "editors.documents-frontend_20260909.00_p1"
  "Fallback X-Build header value for /save requests.

The live value is taken from the document page's own `buildLabel'; this
fallback covers synthetic states without one.  Update it (or rely on the
page value) when Google rotates the editors frontend.")

(defcustom gdocs-save-send-sid nil
  "Include the persisted session sid in /save requests.

The 2026-05 frontend required it; Google's current editors frontend
rejects an unknown session id with HTTP 400 (err 3), while omitting the
parameter saves fine.  The bundle-internal sid is unaffected."
  :type 'boolean
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

(defun gdocs--validate-curl-timeout (value)
  "Return VALUE when it is a positive number, otherwise signal an error."
  (unless (and (numberp value) (> value 0))
    (user-error "gdocs: curl timeouts must be positive numbers"))
  value)

(defun gdocs--set-curl-timeout (symbol value)
  "Set SYMBOL to validated curl timeout VALUE."
  (set-default symbol (gdocs--validate-curl-timeout value)))

(defcustom gdocs-curl-connect-timeout 10
  "Maximum seconds curl may spend establishing a connection."
  :type 'number
  :set #'gdocs--set-curl-timeout
  :group 'gdocs-mode)

(defcustom gdocs-curl-total-timeout 60
  "Maximum seconds allowed for an entire curl operation."
  :type 'number
  :set #'gdocs--set-curl-timeout
  :group 'gdocs-mode)

(defun gdocs--curl-timeout-args ()
  "Return validated command-line timeout arguments for curl."
  (list "--connect-timeout"
        (number-to-string
         (gdocs--validate-curl-timeout gdocs-curl-connect-timeout))
        "--max-time"
        (number-to-string
         (gdocs--validate-curl-timeout gdocs-curl-total-timeout))))

(defun gdocs--curl-exit-error (exit-code)
  "Return a diagnostic for curl EXIT-CODE."
  (if (equal exit-code 28)
      "curl timeout (exit 28)"
    (format "curl exit %s" exit-code)))

(defconst gdocs--export-base "https://docs.google.com/document/d/")

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

(defvar-local gdocs--sync-timer nil
  "Idle timer for auto-sync in this buffer.")

(defvar-local gdocs--auto-sync-in-flight nil
  "Identity token for the edit-state probe currently in flight.")

(defvar-local gdocs--auto-sync-generation 0
  "Generation of the current auto-sync lifecycle.")

(defvar gdocs--sync-mutex nil
  "Ownership token for the global sync operation, or nil when unlocked.")

(defun gdocs--sync-acquire ()
  "Acquire the global sync lock and return its unique ownership token."
  (unless gdocs--sync-mutex
    (let ((owner (list 'gdocs-sync-owner)))
      (setq gdocs--sync-mutex owner)
      owner)))

(defun gdocs--sync-release (owner)
  "Release the global sync lock when OWNER still owns it."
  (when (and owner (eq owner gdocs--sync-mutex))
    (setq gdocs--sync-mutex nil)
    t))

(defvar-local gdocs--last-synced-hash nil
  "SHA-256 of the pushable buffer body (sans synchronization metadata)
at the moment of the last successful pull or push. Used by
`gdocs--auto-sync-tick' to detect unsynced local edits without relying
on `buffer-modified-p' (which is unreliable in temp/indirect buffers
and not set when content is inserted programmatically).")

(defvar-local gdocs--auto-sync-conflict-revision nil
  "Remote revision for which auto-sync last warned about a conflict.
A warning is emitted again when the remote revision changes or the
conflict has disappeared and later recurs.")

(defvar-local gdocs--pull-generation 0
  "Identity of the most recently dispatched pull for this buffer.")

(defvar-local gdocs--auto-sync-failures 0
  "Consecutive failed auto-sync ticks in this buffer.

Each failure doubles the next tick's delay (capped at ten minutes);
a successful pull or push resets it.  Stops the every-5-seconds
warning spam when Google rate-limits the session or the network is
down.")

(defun gdocs--auto-sync-delay ()
  "Seconds until the next auto-sync tick, with exponential backoff."
  (min (* gdocs-auto-sync-interval
          (expt 2 (max 0 gdocs--auto-sync-failures)))
       600))

(define-error 'gdocs-pull-conflict "GDocs pull conflict")


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
       (save-excursion
         (goto-char (point-min))
         (org-entry-get (point) "GDOC_ID" nil))))

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

(defun gdocs--update-top-metadata (title revision &optional unsupported-summary)
  "Write Drive TITLE, revision/timestamp, and capability metadata.

The Drive document name is synchronization metadata, not an Org keyword.
Title-styled paragraphs are rendered separately by `gdocs-dm-to-org'.
UNSUPPORTED-SUMMARY is a sanitized count string, never raw remote data."
  (save-excursion
    (when title
      (gdocs--put-top-property "GDOC_TITLE" title))
    (when revision
      (gdocs--put-top-property "GDOC_REVISION" revision))
    (when (stringp unsupported-summary)
      (if (string-empty-p unsupported-summary)
          (when (org-entry-get (point-min) "GDOC_UNSUPPORTED" t)
            (org-entry-delete (point-min) "GDOC_UNSUPPORTED"))
        (gdocs--put-top-property "GDOC_UNSUPPORTED" unsupported-summary)))
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


(defun gdocs--horizontal-whitespace-p (char)
  "Return non-nil when CHAR is horizontal whitespace.
The OT stream can contain regular spaces, tabs, or Unicode space
characters such as NBSP.  Newlines are deliberately not included: a
selected paragraph boundary is a real anchor boundary, not padding to
discard."
  (and char
       (or (eq char ?\s)
           (eq char ?\t)
           (eq (get-char-code-property char 'general-category) 'Zs))))

(defconst gdocs--org-link-description-sentinel (string #x200b)
  "Invisible separator used to keep Org subscript/LaTeX syntax literal.")

(defun gdocs--debug-context-suffix (text)
  "Return a short suffix of TEXT suitable for debug diagnostics.
Never log an entire document context merely because an anchor could not
be placed."
  (let* ((text (or text ""))
         (limit 32)
         (start (max 0 (- (length text) limit))))
    (if (zerop start)
        text
      (concat "..." (substring text start)))))

(defun gdocs--inline-ref-containing-link-end ()
  "Return the closing boundary of the Org link containing point, or nil.

The point must be inside a link description.  Bare links are handled as a
special case because their target is also their visible text.  Walk the
element parents so styled runs inside a link are recognized without scanning
for literal closing brackets.  Org includes trailing horizontal whitespace in
a link's `:end'; subtract its `:post-blank' to find the closing delimiter."
  (condition-case nil
      (let ((position (point))
            (element (org-element-context))
            link-end)
        (while (and element (not link-end))
          (when (eq (org-element-type element) 'link)
            (let* ((begin (org-element-property :begin element))
                   (end (org-element-property :end element))
                   (post-blank (org-element-property :post-blank element))
                   (closing-end
                    (and (integerp end)
                         (- end (if (and (integerp post-blank)
                                         (> post-blank 0))
                                    post-blank
                                  0))))
                   (contents-begin (org-element-property
                                    :contents-begin element))
                   (contents-end (org-element-property :contents-end element)))
              (when (and (integerp begin)
                         (integerp closing-end)
                         (<= begin position)
                         (< position closing-end)
                         (if (and (integerp contents-begin)
                                  (integerp contents-end))
                             (and (<= contents-begin position)
                                  (<= position contents-end))
                           ;; A bare link has no description; its target is
                           ;; the visible text and must be kept whole.
                           t))
                (setq link-end closing-end))))
          (setq element (org-element-property :parent element)))
        link-end)
    (error nil)))

(defun gdocs--org-visible-and-map (org-body)
  "Return visible Org text and a map back to positions in ORG-BODY.

The result is (TEXT . MAP), where MAP[i] is the zero-based ORG-BODY index
that supplied TEXT[i].  Link descriptions and bare link text are visible;
link targets hidden behind descriptions, Org delimiters, heading and list
prefixes, drawers, and title keyword prefixes are not."
  (with-temp-buffer
    (org-mode)
    (insert org-body)
    (let* ((size (buffer-size))
           (visible (make-vector size t))
           (tree (org-element-parse-buffer)))
      (cl-labels
          ((hide (begin end)
             (when (and (integerp begin) (integerp end))
               (let ((from (max 0 (1- begin)))
                     (to (min size (1- end))))
                 (while (< from to)
                   (aset visible from nil)
                   (cl-incf from)))))
           (closing-end (element)
             (- (org-element-property :end element)
                (or (org-element-property :post-blank element) 0)))
           (hide-inline-delimiters (element)
             (let ((begin (org-element-property :begin element))
                   (end (closing-end element)))
               (hide begin (1+ begin))
               (hide (1- end) end)))
           (hide-renderer-link-description-escapes (element)
             (let ((from (org-element-property :contents-begin element))
                   (end (org-element-property :contents-end element))
                   (sentinel (string-to-char
                              gdocs--org-link-description-sentinel)))
               (when (and (integerp from) (integerp end))
                 (setq from (1- from)
                       end (1- end))
                 (while (< from end)
                   (cond
                    ((and (< (+ from 2) end)
                          (= (aref org-body from) sentinel)
                          (memq (aref org-body (1+ from)) '(?_ ?\\ ?\[ ?\]))
                          (= (aref org-body (+ from 2)) sentinel))
                     (aset visible from nil)
                     (aset visible (+ from 2) nil)
                     (cl-incf from 3))
                    ((and (< (1+ from) end)
                          (= (aref org-body from) ?\\)
                          (memq (aref org-body (1+ from))
                                '(?* ?/ ?+ ?= ?~)))
                     (aset visible from nil)
                     (cl-incf from 2))
                    (t
                     (cl-incf from)))))))
           (hide-line-around-value (element value)
             (let* ((begin (org-element-property :begin element))
                    (line-end (save-excursion
                                (goto-char begin)
                                (line-end-position)))
                    (value-start
                     (and (stringp value)
                          (save-excursion
                            (goto-char begin)
                            (search-forward value line-end t)
                            (match-beginning 0)))))
               (when value-start
                 (hide begin value-start)
                 (hide (+ value-start (length value)) line-end)))))
        (org-element-map tree '(property-drawer node-property planning)
          (lambda (element)
            (hide (org-element-property :begin element)
                  (org-element-property :end element))))
        (org-element-map tree 'headline
          (lambda (element)
            (hide-line-around-value element
                                    (org-element-property :raw-value element))))
        (org-element-map tree 'item
          (lambda (element)
            (hide (org-element-property :begin element)
                  (org-element-property :contents-begin element))))
        (org-element-map tree 'keyword
          (lambda (element)
            (when (member (downcase (org-element-property :key element))
                          '("title" "subtitle"))
              (hide-line-around-value element
                                      (org-element-property :value element)))))
        (org-element-map tree '(bold italic underline strike-through code verbatim)
          #'hide-inline-delimiters)
        (org-element-map tree 'link
          (lambda (element)
            (let* ((begin (org-element-property :begin element))
                   (end (closing-end element))
                   (contents-begin (org-element-property :contents-begin element))
                   (contents-end (org-element-property :contents-end element)))
              (cond
               ((and (integerp contents-begin) (integerp contents-end))
                (hide begin contents-begin)
                (hide contents-end end))
               ((and (<= (+ begin 4) end)
                     (string= (buffer-substring-no-properties begin (1+ begin))
                              "[[")
                     (string= (buffer-substring-no-properties (- end 2) end)
                              "]]"))
                (hide begin (+ begin 2))
                (hide (- end 2) end)))
              (hide-renderer-link-description-escapes element))))
        (let ((text (make-string size 0))
              (map (make-vector size 0))
              (out 0))
          (dotimes (index size)
            (when (aref visible index)
              (aset text out (aref org-body index))
              (aset map out index)
              (cl-incf out)))
          (cons (substring text 0 out) (seq-subseq map 0 out)))))))

(defconst gdocs--comment-footnote-label-prefix "gdocs-comment-"
  "Reserved Org footnote label prefix for generated Google comments.")

(defun gdocs--comment-footnote-label (number)
  "Return the generated Org footnote label for comment NUMBER."
  (format "%s%d" gdocs--comment-footnote-label-prefix number))

(defun gdocs--assert-comment-footnote-namespace-available (org-body)
  "Signal an error when ORG-BODY already uses the reserved comment namespace."
  (when (string-match-p
         (concat "\\[fn:" (regexp-quote gdocs--comment-footnote-label-prefix))
         org-body)
    (error "GDocs comment footnote namespace `%s' is already used in the document"
           gdocs--comment-footnote-label-prefix)))

(defun gdocs--inline-comment-refs (org-body ot-body anchor-map comments)
  "Insert generated comment refs into ORG-BODY at each anchor position.
ANCHOR-MAP is the alist (KIX-ID . (SI . EI)) returned by
`gdocs--decode-doco-anchors'. COMMENTS is the list returned by
`gdocs--parse-docos-sync-response'. Anchor positions are one-based OT
positions and `EI' is the inclusive final position of the anchored range.
Only the first comment per anchor gets an inline ref — replies share the
thread anchor and listing them all inline would clutter the prose. The ref
lands at the end of the anchored span; a unique-match check skips placement
when the context is ambiguous (an extra reply showing up inline is harmless
but wrong)."
  (gdocs--assert-comment-footnote-namespace-available org-body)
  (let* ((ot-body (or ot-body ""))
         (plain+map (gdocs--ot-plain-and-map ot-body))
         (plain (car plain+map))
         (map (cdr plain+map))
         (ot->plain (let ((tbl (make-hash-table :test 'eql)))
                      (dotimes (j (length map))
                        (puthash (aref map j) j tbl))
                      tbl))
         (ot-length (length ot-body))
         (seen (make-hash-table :test 'equal))
         (placements nil))
    (dolist (c comments)
      (let* ((n (car c))
             (anchor (plist-get (cdr c) :anchor))
             (rng (and anchor (cdr (assoc anchor anchor-map))))
             (si (car-safe rng))
             (ei (cdr-safe rng)))
        (cond
         ((not rng)
          (gdocs-log 'debug
                     "inline-ref fn:%d anchor=%S: no decoded range — skipped"
                     n anchor))
         ((gethash anchor seen) nil)
         (t
          (puthash anchor t seen)
          ;; Doco anchors use EI as the inclusive final OT position.  Map
          ;; EI itself, rather than EI-1, into the inverse plain-text map;
          ;; the latter is what split a final letter off the anchor.  A
          ;; structural codepoint has no plain counterpart, so only in that
          ;; specific case walk back over adjacent structural positions.
          (let* ((plain-index (and (integerp ei) (gethash ei ot->plain)))
                 (mapped-ei ei))
            (unless (integerp plain-index)
              (when (and (integerp ei)
                         (>= ei 1) (<= ei ot-length)
                         (memq (aref ot-body (1- ei))
                               gdocs--ot-structural-codepoints))
                (setq mapped-ei (1- ei))
                (while (and (>= mapped-ei 1)
                            (memq (aref ot-body (1- mapped-ei))
                                  gdocs--ot-structural-codepoints))
                  (cl-decf mapped-ei))
                (setq plain-index (and (>= mapped-ei 1)
                                       (gethash mapped-ei ot->plain)))
                (when (integerp plain-index)
                  (gdocs-log
                   'debug
                   "inline-ref fn:%d anchor=%S range=%S..%S: EI %d is structural; using preceding OT position %d"
                   n anchor si ei ei mapped-ei))))
            (if (integerp plain-index)
                (let ((plain-end (1+ plain-index)))
                  ;; A user may select the spaces after a word.  They are
                  ;; not part of the visible anchor location, but punctuation
                  ;; is: only horizontal whitespace is trimmed here.
                  (let ((untrimmed-end plain-end))
                    (while (and (> plain-end 0)
                                (gdocs--horizontal-whitespace-p
                                 (aref plain (1- plain-end))))
                      (cl-decf plain-end))
                    (when (< plain-end untrimmed-end)
                      (gdocs-log
                       'debug
                       "inline-ref fn:%d anchor=%S range=%S..%S: trimmed %d trailing horizontal whitespace codepoint%s"
                       n anchor si ei (- untrimmed-end plain-end)
                       (if (= (- untrimmed-end plain-end) 1) "" "s"))))
                  (push (list :n n :anchor anchor :si si :ei ei
                              :plain-end plain-end)
                        placements))
              (gdocs-log
               'debug
               "inline-ref fn:%d anchor=%S range=%S..%S: EI has no plain-text mapping (OT length %d) — skipped"
               n anchor si ei ot-length)))))))
    (setq placements
          (sort placements (lambda (a b)
                             (> (plist-get a :plain-end)
                                (plist-get b :plain-end)))))
    (with-temp-buffer
      (org-mode)
      (insert org-body)
      (let* ((visible+map (gdocs--org-visible-and-map org-body))
             (visible-text (car visible+map))
             (visible-map (cdr visible+map)))
        (dolist (pl placements)
          (let* ((pe (plist-get pl :plain-end))
                 (n (plist-get pl :n))
                 (anchor (plist-get pl :anchor))
                 (si (plist-get pl :si))
                 (ei (plist-get pl :ei))
                 (full-context (substring plain 0 pe))
                 ;; Walk back through candidate context windows, shortest
                 ;; first, expanding until we get a unique match. Min 4 chars
                 ;; (otherwise a single word fragment matches everywhere);
                 ;; max 64 chars (longer doesn't help and risks spanning
                 ;; structural boundaries the org body re-renders differently).
                 (found nil)
                 (last-window 0)
                 (last-count 0)
                 (last-context nil))
            (catch 'placed
              (dolist (window-len '(8 12 16 24 32 48 64))
                (when (and (not found)
                           (>= (length full-context) (min 4 window-len)))
                  (let* ((wl (min window-len (length full-context)))
                         (context (substring full-context (- (length full-context) wl)))
                         (re (gdocs--relaxed-newlines-regexp context))
                         (last nil) (count 0))
                    (setq last-window wl last-context context)
                    (let ((search-start 0))
                      (while (string-match re visible-text search-start)
                        (cl-incf count)
                        (setq last (match-end 0)
                              search-start (max (1+ (match-beginning 0))
                                                (match-end 0)))))
                    (setq last-count count)
                    (when (= count 1)
                      (setq found t)
                      (goto-char (+ 2 (aref visible-map (1- last))))
                      ;; A plain-text endpoint can fall inside a labeled link
                      ;; (including a styled description). Keep the reference
                      ;; outside the complete link, before any following blank.
                      (let ((link-end (gdocs--inline-ref-containing-link-end)))
                        (when link-end
                          (goto-char link-end)))
                      ;; Walk past trailing emphasis markers so the ref lands
                      ;; outside `~text~' or `*text*' rather
                      ;; than inside (which would alter the styled span).
                      (while (and (< (point) (point-max))
                                  (memq (char-after) '(?* ?~ ?/ ?_ ?+ ?=)))
                        (forward-char 1))
                      (insert (format "[fn:%s]"
                                      (gdocs--comment-footnote-label n)))
                      (throw 'placed t)))))
              (gdocs-log
               'debug
               "inline-ref fn:%d anchor=%S range=%S..%S plain-end=%d window=%d matches=%d context-suffix=%S — no unique match; skipped"
               n anchor si ei pe last-window last-count
               (gdocs--debug-context-suffix last-context)))))
        (buffer-string)))))

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
push (Google holds the canonical comments; the section is an editable,
ephemeral local projection that the next pull regenerates)."
  (concat
   "\n* Comments\n"
   ":PROPERTIES:\n:GDOC_LOCAL: t\n:END:\n\n"
   (mapconcat
    (lambda (c)
      ;; Org footnote definition. `C-c C-c' on the inline reference
      ;; ref jumps here; `C-c C-c' here jumps back. Idiomatic org —
      ;; no `<<target>>' clutter.
      (format "[fn:%s] %s\n"
              (gdocs--comment-footnote-label (car c))
              (gdocs--normalize-comment-text
               (plist-get (cdr c) :text))))
    (sort comments :key #'car)
    "")))

(defun gdocs--append-comments-section (body comments)
  "Return BODY with the rendered COMMENTS section appended.
Exactly one blank line separates the body from the `* Comments'
heading; without comments BODY passes through unchanged."
  (if comments
      (concat (string-trim-right body) "\n"
              (gdocs--render-comments-section comments))
    body))

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
        ;; Chunks were found, so the snapshot is valid even when no `is' op
        ;; carried text: that is a genuinely empty body.  Returning nil here
        ;; is reserved for "no model chunks at all" (a failed parse), which
        ;; callers must never treat as an empty document.
        (list :ot-body body :revision rev)))))

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

(defun gdocs--tab-op-body (ops)
  "Return the text inserted by OPS, in their OT order."
  (mapconcat (lambda (op) (alist-get 's op))
             (seq-filter (lambda (op) (equal (alist-get 'ty op) "is")) ops)
             ""))

(defun gdocs--tabs-from-ops (ops)
  "Split OPS into ordered tab plists, or signal on unknown tab structure.
Each tab has :id, :title, :icon, :path, :ops and :ot-body.  Nil means the
document uses the original, single-body format.  Indices within a tab's
operations are local to that tab, not to the combined document."
  (let (root declarations tabs)
    (dolist (op ops)
      (pcase (alist-get 'ty op)
        ("mkch"
         (unless (and (null root)
                      (consp (alist-get 'd op))
                      (consp (car (alist-get 'd op)))
                      (equal (alist-get 'd op)
                             (list (list 1 (cadar (alist-get 'd op)))))
                      (stringp (cadar (alist-get 'd op))))
           (error "gdocs: unrecognized first tab declaration"))
         (setq root (cadar (alist-get 'd op))))
        ("ac"
         (let* ((data (alist-get 'd op))
                (id (nth 0 data)) (properties (nth 1 data))
                (path (nth 2 data))
                (title (and (listp properties)
                            (cadr (member 1 properties))))
                (icon (and (listp properties)
                           (cadr (member 2 properties)))))
           (unless (and (= (length data) 3) (stringp id)
                        (string-match-p "\\`t\\.[A-Za-z0-9]+\\'" id)
                        (stringp title) (not (string-empty-p title))
                        (or (null icon) (stringp icon))
                        (listp properties) (cl-evenp (length properties))
                        (= (cl-count 1 properties) 1)
                        (<= (cl-count 2 properties) 1)
                        (cl-loop for (key value) on properties by #'cddr
                                 always (and (memq key '(1 2)) (stringp value)))
                        (consp path) (cl-every #'natnump path))
             (error "gdocs: unrecognized tab declaration"))
           (push (list :id id :title title :icon icon :path path
                       :ops nil :ot-body "")
                 declarations)))))
    (when (and declarations (not root))
      (error "gdocs: missing first tab declaration"))
    (when (and (not declarations)
               (seq-some (lambda (op) (equal (alist-get 'ty op) "nm")) ops))
      (error "gdocs: tab operations without tab declarations"))
    (when declarations
      (setq tabs (list (list :id "t.0" :title root :path '(0)
                             :ops nil :ot-body "")))
      (dolist (tab (sort declarations
                         (lambda (a b)
                           (let ((pa (plist-get a :path)) (pb (plist-get b :path)))
                             (catch 'order
                               (cl-loop for x in pa for y in pb
                                        when (/= x y) do (throw 'order (< x y)))
                               (< (length pa) (length pb)))))))
        (let* ((path (plist-get tab :path))
               (siblings (seq-filter
                          (lambda (entry)
                            (equal (butlast (plist-get entry :path))
                                   (butlast path))) tabs))
               (parent (and (> (length path) 1)
                            (seq-find (lambda (entry)
                                        (equal (plist-get entry :path)
                                               (butlast path))) tabs))))
          (unless (and (or (and (= (length path) 1)
                                (= (car path) 1))
                           (and parent
                                (= (length (plist-get parent :path))
                                   (1- (length path)))))
                       (= (car (last path)) (length siblings))
                       (not (seq-find (lambda (entry)
                                        (equal (plist-get entry :id)
                                               (plist-get tab :id))) tabs)))
            (error "gdocs: inconsistent tab tree"))
          (setq tabs (append tabs (list tab)))))
      (dolist (op ops)
        (let* ((ty (alist-get 'ty op))
               (nmr (alist-get 'nmr op))
               (tab (if (equal ty "nm")
                        (and (listp nmr) (= (length nmr) 2)
                             (equal (car nmr) "ksm")
                             (seq-find (lambda (entry)
                                         (equal (plist-get entry :id) (cadr nmr)))
                                       (cdr tabs)))
                      (car tabs))))
          (when (and (equal ty "nm")
                     (not (and tab (listp (alist-get 'nmc op))
                               (stringp (alist-get 'ty (alist-get 'nmc op)))
                               (not (member (alist-get 'ty (alist-get 'nmc op))
                                            '("mkch" "ac" "nm" "utlp" "umv"))))))
            (error "gdocs: unrecognized tab operation"))
          (unless (member ty '("mkch" "ac" "utlp" "umv"))
            (push (if (equal ty "nm") (alist-get 'nmc op) op)
                  (plist-get tab :ops)))))
      (when (seq-some (lambda (tab)
                        (not (seq-some (lambda (op)
                                         (equal (alist-get 'ty op) "is"))
                                       (plist-get tab :ops)))) tabs)
        (error "gdocs: tab has no decodable body"))
      (dolist (tab tabs)
        (setf (plist-get tab :ops) (nreverse (plist-get tab :ops)))
        (setf (plist-get tab :ot-body)
              (gdocs--tab-op-body (plist-get tab :ops))))
      tabs)))

(defun gdocs--state-for-tab (state tab-id)
  "Return a write-planning STATE scoped to TAB-ID from a fresh edit state."
  (let* ((tabs (plist-get state :tabs))
         (tab (seq-find (lambda (item)
                          (equal (plist-get item :id) tab-id)) tabs)))
    (unless tab (user-error "gdocs: tab %s not found in remote state" tab-id))
    (let* ((scoped (copy-sequence state))
           (ops (plist-get tab :ops))
           (body (plist-get tab :ot-body))
           (analysis (gdocs--decode-capability-analysis ops body)))
      (setq scoped (plist-put scoped :tabs nil))
      (setq scoped (plist-put scoped :tab-id tab-id))
      (setq scoped (plist-put scoped :ot-ops ops))
      (setq scoped (plist-put scoped :ot-body body))
      (setq scoped (plist-put scoped :inline-objects
                              (plist-get analysis :objects)))
      (plist-put scoped :unsupported (plist-get analysis :unsupported)))))

(defun gdocs--local-tabs (body remote-tabs)
  "Extract tab-local Org bodies from BODY, validating REMOTE-TABS structure.
Tab and content headings may have the same Org level, so boundaries are
identified by GDOC_TAB properties, never by heading depth alone."
  (with-temp-buffer
    (org-mode)
    (insert body)
    (let (headings result)
      (org-element-map (org-element-parse-buffer) 'headline
        (lambda (heading)
          (let ((start (org-element-property :begin heading)))
            (goto-char start)
            (when-let* ((id (org-entry-get start "GDOC_TAB" nil)))
              (push (list :id id :start start
                          :level (org-element-property :level heading)
                          :title (org-get-heading t t t t)
                          :icon (org-entry-get start "GDOC_TAB_ICON" nil)
                          :body-start (save-excursion
                                        (forward-line)
                                        (when (looking-at org-property-drawer-re)
                                          (goto-char (match-end 0))
                                          (forward-line))
                                        (point)))
                    headings)))))
      (setq headings (nreverse headings))
      (unless (= (length headings) (length remote-tabs))
        (user-error "gdocs: tab count changed; tab creation/deletion is unsupported"))
      (unless (string-empty-p
               (string-trim (buffer-substring-no-properties
                             (point-min) (plist-get (car headings) :start))))
        (user-error "gdocs: content outside the tab headings is unsupported"))
      (cl-loop for entry in headings
               for remote in remote-tabs
               for next in (append (cdr headings) (list nil))
               do (let* ((depth (length (plist-get remote :path)))
                         (icon (plist-get remote :icon))
                         (title (concat (if icon (concat icon " ") "")
                                        (plist-get remote :title))))
                    (unless (and (equal (plist-get entry :id)
                                        (plist-get remote :id))
                                 (= (plist-get entry :level) depth)
                                 (equal (plist-get entry :title) title)
                                 (equal (plist-get entry :icon) icon))
                      (user-error "gdocs: tab order, level, title or icon changed"))
                    (let ((text (buffer-substring-no-properties
                                 (plist-get entry :body-start)
                                 (if next (plist-get next :start) (point-max)))))
                      (with-temp-buffer
                        (org-mode)
                        (insert (string-trim-right text) "\n")
                        (goto-char (point-min))
                        (while (re-search-forward "^\\(\\*+\\) " nil t)
                          (let ((stars (match-string 1)))
                            (when (<= (length stars) depth)
                              (user-error "gdocs: content heading crosses tab boundary"))
                            (replace-match (concat
                                            (substring stars depth) " ") t t)))
                        (push (cons (plist-get entry :id) (buffer-string))
                              result)))))
      (nreverse result))))

(defun gdocs--plain-org-text-p (text)
  "Non-nil when Org TEXT is only unstyled paragraphs that round-trip exactly.
Such text maps one-to-one onto OT characters, so it can be sent as a
literal insertion without changing its meaning."
  (condition-case nil
      (let* ((doc (gdocs-dm-from-org text))
             (paras (plist-get doc :paragraphs)))
        (and (cl-every
              (lambda (para)
                (and (memq (plist-get para :kind) '(:para :blank))
                     (cl-every (lambda (run)
                                 (and (null (plist-get run :styles))
                                      (null (plist-get run :link))
                                      (null (plist-get run :inline-object))))
                               (plist-get para :runs))))
              paras)
             (null (plist-get doc :lossy))
             (equal (string-trim-right (gdocs-dm-to-org doc))
                    (string-trim-right text))))
    (error nil)))

(defun gdocs--tab-push-plan (doc-id state local-body)
  "Plan one changed tab from LOCAL-BODY against freshly fetched STATE.
Return nil for an exact no-op.  The current write path deliberately limits
a multi-tab push to one tab and one incremental model change per save."
  (let* ((tabs (plist-get state :tabs))
         (parts (gdocs--local-tabs local-body tabs))
         (remote-parts
          (gdocs--local-tabs
           (car (gdocs--render-tab-tree
                 tabs (plist-get state :revision) doc-id)) tabs))
         (changes nil))
    (dolist (part parts)
      (let* ((scoped (gdocs--state-for-tab state (car part)))
             (remote (cdr (assoc (car part) remote-parts)))
             (local (cdr part)))
        (unless (string= (gdocs--push-comparison-body local)
                         (gdocs--push-comparison-body remote))
          (push (list :tab-id (car part) :state scoped
                      :local local :remote remote) changes))))
    (when (> (length changes) 1)
      (user-error "gdocs: edit one tab at a time; multiple tab changes need separate saves"))
    (when-let* ((change (car changes)))
      (let* ((scoped (plist-get change :state))
             (local (plist-get change :local))
             (remote (plist-get change :remote))
             (diff (gdocs--diff-single-region remote local))
             (deleted (and diff (substring-no-properties
                                 (plist-get diff :deleted))))
             (inserted (and diff (substring-no-properties
                                  (plist-get diff :inserted))))
             (start (and diff (plist-get diff :start)))
             (ot-body (plist-get scoped :ot-body))
             (text (gdocs--ot-plain-text ot-body))
             ;; Only plain-text tabs are planned here: the OT body equals the
             ;; rendered text with no structural codepoints, so a text offset
             ;; I is exactly OT position I+1 (checked below before use).
             (plain-p (and (equal ot-body text)
                           (equal (string-trim-right text)
                                  (string-trim-right remote))
                           (not (string-match-p "[\x00-\x08\x0b-\x1f]" text))))
             (rem-end (and diff (plist-get diff :rem-end)))
             (range (and plain-p diff (<= rem-end (length text))
                         (cons (1+ start) (1+ rem-end))))
             (position (car-safe range))
             (plan (cond
                    ((and position (string-empty-p deleted)
                          (length> inserted 0))
                     (list :kind :incremental
                           :commands (list `((ty . "is") (ibi . ,position)
                                             (s . ,inserted)))
                           :ranges (list (list :ot-start position
                                               :ot-end position
                                               :insert-at position
                                               :delete-count 0))
                           :post-body (gdocs--push-comparison-body local)))
                    ((and range (string-empty-p inserted)
                          (length> deleted 0))
                     (list :kind :incremental
                           :commands (list `((ty . "ds") (si . ,(car range))
                                             (ei . ,(1- (cdr range)))))
                           :ranges (list (list :ot-start (car range)
                                               :ot-end (1- (cdr range))
                                               :insert-at (car range)
                                               :delete-count (length deleted)))
                           :post-body (gdocs--push-comparison-body local))))))
        (unless (and plan plain-p (gdocs--plain-org-text-p local))
          (user-error "gdocs: tab edit is not a safe single text operation"))
        (gdocs--push-preflight scoped local plan)
        (append change (list :plan plan))))))

(defun gdocs--tab-remote-unchanged-p (before after tab-id)
  "Check that every tab except TAB-ID is unchanged from BEFORE to AFTER."
  (let ((old-tabs (plist-get before :tabs))
        (new-tabs (plist-get after :tabs)))
    (and (= (length old-tabs) (length new-tabs))
         (cl-every
          (lambda (old new)
            (and (equal (plist-get old :id) (plist-get new :id))
                 (equal (plist-get old :title) (plist-get new :title))
                 (equal (plist-get old :icon) (plist-get new :icon))
                 (equal (plist-get old :path) (plist-get new :path))
                 (or (equal (plist-get old :id) tab-id)
                     (equal (plist-get old :ops) (plist-get new :ops)))))
          old-tabs new-tabs))))

(defun gdocs--tab-save-ack-p (response pre-revision)
  "Check RESPONSE's revisions for a tab save from PRE-REVISION."
  (let* ((previous (gdocs--save-revision-value pre-revision))
         (metadata (alist-get 'metadata response))
         (server (gdocs--save-revision-value
                  (alist-get 'serverRevision metadata)))
         (ranges (alist-get 'revisionRanges response))
         (last-range (car (last ranges)))
         (committed (gdocs--save-revision-value (car (last last-range)))))
    (and previous server committed
         (= server previous)
         (= committed (1+ previous)))))

(defun gdocs--tab-save-outcome (doc-id before after tab-id expected)
  "Classify AFTER relative to BEFORE for a one-tab save of TAB-ID.
Return `:committed' when exactly one revision was added, only TAB-ID
changed and its body is EXPECTED; `:untouched' when the document is
identical to BEFORE; otherwise `:conflict'."
  (let ((pre-rev (plist-get before :revision))
        (post-rev (and after (plist-get after :revision))))
    (cond
     ((null after) :conflict)
     ((and (gdocs--push-revisions-equal-p post-rev pre-rev)
           (gdocs--tab-remote-unchanged-p before after nil))
      :untouched)
     ((and (gdocs--push-revisions-equal-p
            post-rev (gdocs--push-next-revision pre-rev))
           (gdocs--tab-remote-unchanged-p before after tab-id)
           (string= expected
                    (or (gdocs--push-state-body
                         doc-id (gdocs--state-for-tab after tab-id))
                        "")))
      :committed)
     (t :conflict))))

(defvar gdocs--rate-limit-retry-delay)

(defconst gdocs--tab-save-max-attempts 5
  "Maximum /save attempts for one tab edit, counting throttled retries.")

(defun gdocs--tab-push-async (doc-id buf local-rev local-body state owner)
  "Save one changed tab of DOC-ID from LOCAL-BODY against fresh STATE.
Each attempt is planned from the current remote state.  After every
response, success or failure, the document is refetched and classified:
a verified commit finalizes BUF, an untouched document after a transient
rejection is replanned and retried, and anything else fails closed.
OWNER is the sync mutex token and is released exactly once."
  (let ((done nil))
    (cl-labels
        ((finish (err)
           (unless done
             (setq done t)
             (gdocs--sync-release owner)
             (if err
                 (gdocs-log 'warn "Push %s: %s" doc-id err)
               (gdocs-log 'info "Pushed %s (tab edit, verified)" doc-id))))
         (buffer-unchanged-p ()
           (and (buffer-live-p buf)
                (with-current-buffer buf
                  (equal local-body (gdocs--buffer-body-as-plain)))))
         (attempt (current n)
           (condition-case sig
               (let ((change (gdocs--tab-push-plan doc-id current local-body)))
                 (cond
                  ((null change)
                   (if (buffer-unchanged-p)
                       (progn
                         (with-current-buffer buf
                           (gdocs--finalize-push-props
                            (plist-get current :revision) local-body))
                         (finish nil))
                     (finish "local buffer changed during push")))
                  ((not (equal local-rev (format "%s" (plist-get current :revision))))
                   (finish "remote revision changed; pull before pushing"))
                  ((not (buffer-unchanged-p))
                   (finish "local buffer changed before save"))
                  (t (send current change n))))
             (error (finish (error-message-string sig)))))
         (send (current change n)
           (let* ((plan (plist-get change :plan))
                  (tab-id (plist-get change :tab-id))
                  (expected (plist-get plan :post-body)))
             (gdocs--save-request-async
              doc-id (plist-get change :state) (plist-get plan :commands)
              (lambda (response err)
                (let ((transient
                       (or (and (listp err)
                                (memq (plist-get err :http-code) '(400 550)))
                           (and (null err)
                                (gdocs--save-response-xsrf-token response)))))
                  (gdocs--fetch-edit-state-async
                   doc-id
                   (lambda (fresh fetch-err)
                     (condition-case sig
                         (let ((outcome
                                (if fetch-err :conflict
                                  (gdocs--tab-save-outcome
                                   doc-id current fresh tab-id expected))))
                           (cond
                            ((and (eq outcome :committed)
                                  (or err (null response)
                                      (gdocs--tab-save-ack-p
                                       response (plist-get current :revision))))
                             (if (not (buffer-unchanged-p))
                                 (finish "local buffer changed during save; pull to reconcile")
                               (with-current-buffer buf
                                 (gdocs--finalize-push-props
                                  (plist-get fresh :revision) local-body))
                               (finish nil)))
                            ((and (eq outcome :untouched) transient
                                  (< n gdocs--tab-save-max-attempts))
                             (gdocs-log 'info "/save throttled for tab %s (attempt %d); retrying"
                                        tab-id n)
                             (run-with-timer
                              gdocs--rate-limit-retry-delay nil
                              (lambda () (unless done (attempt fresh (1+ n))))))
                            ((eq outcome :untouched)
                             (finish (format "tab save not committed: %s"
                                             (or err "unacknowledged response"))))
                            (t
                             (finish (format "tab save outcome unknown (%s); pull before retrying"
                                             (or fetch-err err "unexpected remote state"))))))
                       (error (finish (error-message-string sig))))))))))))
      (attempt state 1))))

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

(defun gdocs--write-sensitive-diagnostic (path writer)
  "Write a sensitive diagnostic to PATH using WRITER and mode 0600.
WRITER is called with a temporary buffer current.  The destination is
replaced atomically, and the staging file is removed unless writing completes."
  (let* ((path (expand-file-name path))
         (directory (file-name-directory path))
         staging)
    (unless (file-directory-p directory)
      (error "Diagnostic output directory does not exist: %s" directory))
    (unwind-protect
        (progn
          (setq staging
                (make-temp-file
                 (expand-file-name ".gdocs-diagnostic-" directory)))
          (with-temp-buffer
            (funcall writer)
            (let ((coding-system-for-write 'utf-8-unix))
              (write-region nil nil staging nil 'silent)))
          (set-file-modes staging #o600)
          (rename-file staging path t)
          (setq staging nil)
          path)
      (when (and staging (file-exists-p staging))
        (ignore-errors (delete-file staging))))))

(defun gdocs-recon-dump (doc-id &optional out-file summary-file)
  "Fetch DOC-ID's /edit page, parse the full modelChunk, and dump it.

The full op stream is written as a pretty-printed Elisp form.  OUT-FILE
and SUMMARY-FILE are honored exactly when supplied; otherwise each file
gets an unpredictable name from `make-temp-file'.  Files have mode 0600.

These dumps contain sensitive document and raw OT content and persist
until deleted.  The exact paths are reported without logging their raw
content.  Read-only — does not modify the doc or any buffer.  The
caller's `gdocs-auth-function' is used."
  (interactive "sDoc ID: ")
  (let* ((html (gdocs--fetch-edit-page-sync doc-id))
         (full (gdocs--parse-model-chunk-full html))
         (revision (plist-get full :revision))
         (ops (plist-get full :ops))
         (type-counts (gdocs--recon-op-types ops))
         (attr-keys (gdocs--recon-attribute-keys ops))
         (generated-out (null out-file))
         (generated-summary (null summary-file))
         out summary-out completed)
    (unwind-protect
        (prog1
            (progn
              (setq out (or out-file
                            (make-temp-file "gdocs-recon-" nil ".eld")))
              (setq summary-out
                    (or summary-file
                        (make-temp-file "gdocs-recon-summary-" nil ".eld")))
              (gdocs--write-sensitive-diagnostic
               out
               (lambda ()
                 (let ((print-length nil)
                       (print-level nil))
                   (pp `(:revision ,revision :n-ops ,(length ops) :ops ,ops)
                       (current-buffer)))))
              (gdocs--write-sensitive-diagnostic
               summary-out
               (lambda ()
                 (let ((print-length nil) (print-level nil))
                   (pp `(:revision ,revision
                                   :n-ops ,(length ops)
                                   :type-counts ,type-counts
                                   :attr-keys ,attr-keys)
                       (current-buffer)))))
              (message
               "gdocs-recon: sensitive dumps persist until deleted; dump=%s summary=%s"
               out summary-out)
              (list :revision revision :n-ops (length ops)
                    :type-counts type-counts :dump out :summary summary-out))
          (setq completed t))
      (unless completed
        (when (and generated-out out (file-exists-p out))
          (ignore-errors (delete-file out)))
        (when (and generated-summary summary-out (file-exists-p summary-out))
          (ignore-errors (delete-file summary-out)))))))

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
;; DOC   = (:revision N :doc-id S :title S :paragraphs (PARA ...)
;;          :lists ALIST :inline-objects (OBJECT ...) :unsupported (CAP ...)
;;          :ot-length N)   ; decoded docs only: length of the OT body text
;;
;; A document's last paragraph is terminated by a newline Google keeps
;; outside the OT body text, one position past its end.  When the body text
;; itself ends with a newline, that last paragraph is empty and the decoder
;; omits it; otherwise the decoded last paragraph has no newline in the
;; body, and `:ot-length' is one less than the paragraphs' emitted length.
;; PARA  = (:kind :para|:heading|:title|:subtitle|:blank|:list|:code|:table
;;          :level N         ; heading level 1..5 (only for :heading)
;;          :list-id S       ; list entity id (only for :list)
;;          :nest N          ; list nesting 0..8 (only for :list)
;;          :glyph :bullet|:number  ; resolved from list def (only for :list)
;;          :anchor S        ; ps_hdid (only for headings)
;;          :runs (RUN ...))
;;          :inline-object OBJECT ; only for a standalone inline object)
;; RUN   = (:text S :styles (:bold :italic :underline :strike :verbatim :code)
;;          :link S :inline-object OBJECT)
;; OBJECT = (:kind :inline-object :entity-id S :object-kind :image
;;           :content-id S :width NUMBER :height NUMBER :ot-position N)
;;          ; `:ot-position' is decoder metadata, not object identity.
;;
;; Tables are represented as a single :kind=:table paragraph whose :rows is a
;; list of rows; each row is a list of cells; each cell is a list of runs.

(defun gdocs-dm-make-doc (&rest props)
  "Construct a doc-model. PROPS is a plist of :revision :doc-id :title
:paragraphs :lists :inline-objects :unsupported."
  (let ((doc (list :paragraphs nil :lists nil
                   :inline-objects nil :unsupported nil)))
    (cl-loop for (k v) on props by #'cddr
             do (setq doc (plist-put doc k v)))
    doc))

(defsubst gdocs-dm-paragraphs (doc) (plist-get doc :paragraphs))
(defsubst gdocs-dm-lists (doc) (plist-get doc :lists))
(defsubst gdocs-dm-revision (doc) (plist-get doc :revision))
(defsubst gdocs-dm-title (doc) (plist-get doc :title))
(defsubst gdocs-dm-inline-objects (doc) (plist-get doc :inline-objects))
(defsubst gdocs-dm-unsupported (doc) (plist-get doc :unsupported))
(defsubst gdocs-dm-lossy (doc) (plist-get doc :lossy))

;; The registry describes wire-level recognition only.  A recognized key is
;; not necessarily a supported capability: the value-policy tables below
;; distinguish fields that are faithfully round-tripped from fields that are
;; merely normalized to the defaults emitted by this package.
(defconst gdocs--capability-registry
  '((:operation
     ("is" . :recognized)
     ("ds" . :recognized)
     ("as" . :attribute)
     ("ae" . :entity-definition)
     ("te" . :entity-attachment)
     ("umv" . :model-version))
    (:entity
     ("list" . :recognized)
     ("inline" . :recognized-not-editable)
     ("date" . :recognized-not-editable)
     ("person" . :recognized-not-editable))
    (:attribute
     ("text" . :recognized)
     ("link" . :recognized)
     ("paragraph" . :recognized)
     ("list" . :recognized)
     ("tbl" . :recognized)
     ("doco_anchor" . :recognized-not-editable)
     ("document" . :document-settings)
     ("headings" . :document-settings)
     ("language" . :document-settings)))
  "Central registry for raw Google Docs OT constructs.

The values describe wire-level recognition, not push safety.  Semantic value
support is defined by the capability policy tables, because recognizing a
field name alone does not prove that its value survives a decode/encode
round-trip.

`:document-settings' marks attribute types that describe the document as a
whole (initial heading styles, document flags, spell-check language).  Google
sends them as zero-width `as' operations outside the OT body text, so a body
replacement does not remove them; see
`gdocs--capability-document-attribute-types'.")

(defun gdocs--capability-classify (category value)
  "Return the registry classification for CATEGORY and VALUE.
Unknown values are classified as `:unknown'."
  (or (cdr (assoc value (cdr (assq category gdocs--capability-registry))))
      :unknown))

;; Policy values:
;;   :supported    The semantic value is decoded and emitted faithfully.
;;   :normalized   Only the canonical/default value is emitted; other values
;;                 must be reported as potentially destructive.
;;   :explicitness The key records inheritance/explicitness, not formatting.
;; This is intentionally a table rather than a list of recognized names.
(defconst gdocs--capability-text-style-key-policy
  '((ts_bd . :supported) (ts_bd_i . :explicitness)
    (ts_it . :supported) (ts_it_i . :explicitness)
    (ts_un . :supported) (ts_un_i . :explicitness)
    (ts_st . :supported) (ts_st_i . :explicitness)
    (ts_ff . :normalized) (ts_ff_i . :explicitness)
    (ts_fs . :normalized) (ts_fs_i . :explicitness)
    (ts_fgc2 . :normalized) (ts_fgc2_i . :explicitness)
    (ts_bgc2 . :normalized) (ts_bgc2_i . :explicitness)
    (ts_va . :normalized) (ts_va_i . :explicitness)
    (ts_sc . :normalized) (ts_sc_i . :explicitness)
    (ts_tw . :normalized) (ts_tw_i . :explicitness)
    (ts_lsp . :normalized) (ts_lsp_i . :explicitness))
  "Classification table for observed text-style keys.

The normalized entries are supported only for their canonical values.  Their
non-default semantic values are not represented by the Org model and are
therefore reported by the capability scanner.")

(defconst gdocs--capability-known-text-style-keys
  (mapcar #'car gdocs--capability-text-style-key-policy)
  "Text-style keys understood by the scanner.

This is a *known* key list, not a list of keys whose values are all
supported.  See `gdocs--capability-text-style-key-policy'.")

(defconst gdocs--capability-list-level-key-policy
  '((b_gf . :normalized) (b_ts . :nested-style)
    (b_ifl . :normalized) (b_gs . :normalized)
    (b_a . :normalized) (b_sn . :normalized)
    (b_gt . :normalized) (b_il . :normalized))
  "Classification table for list-level entity fields.

The encoder emits, for levels 0 through 8, `b_gt' 9 for bullets or 13 for
numbers, `b_gs' cycling through ●/○/■ for bullets or the empty string for
numbers, `b_gf' as %N or %N., `b_ifl' as 18+36N, `b_il' as 36+36N,
`b_a' as 0, `b_sn' as 1, and the block returned by
`gdocs--ts-block-canonical' as `b_ts'.  Observed semantic values outside
those exact canonical forms cannot be reproduced by full replacement.")

(defconst gdocs--capability-list-level-required-semantic-fields
  '(b_gf b_ts b_ifl b_gs b_a b_sn b_gt b_il)
  "Semantic fields required to prove a bound list level canonical.")

(defconst gdocs--capability-list-text-style-required-semantic-fields
  '(ts_un ts_sc ts_fgc2 ts_bgc2 ts_it ts_va ts_fs ts_ff ts_st ts_bd ts_tw)
  "Semantic text-style fields required in a canonical bound list level.")

(defconst gdocs--capability-list-text-style-explicitness-fields
  (cl-loop for (key . policy) in gdocs--capability-text-style-key-policy
           when (eq policy :explicitness)
           collect key)
  "Recognized list text-style explicitness metadata fields.")

(defconst gdocs--capability-paragraph-style-key-policy
  '((ps_hd . :supported) (ps_hd_i . :explicitness)
    (ps_hdid . :supported) (ps_hdid_i . :explicitness)
    (ps_il . :normalized) (ps_il_i . :explicitness)
    (ps_ifl . :normalized) (ps_ifl_i . :explicitness)
    (ps_al . :normalized) (ps_al_i . :explicitness))
  "Classification table for observed paragraph-style keys.

Heading levels and heading anchors have Org representations.  Indentation and
alignment are decoded for pull diagnostics, but the current Org model does not
emit them; only their ordinary defaults are therefore safe to normalize.")

(defconst gdocs--capability-table-attribute-key-policy
  '((tbls_tblid . :normalized) (tbls_cols . :normalized)
    (cv . :normalized) (op . :normalized) (opValue . :normalized)
    (col_wv . :normalized) (col_wt . :normalized)
    (col_tdt . :normalized) (tdt_v . :normalized)
    (col_tf . :normalized) (ttf_vn . :normalized)
    (ttf_n . :normalized))
  "Classification table for table attributes.

The table shape and canonical column defaults are emitted, but the Org model
has no table-width or table-specific formatting representation.  Any
non-canonical column value is consequently destructive on replacement.")

(defconst gdocs--capability-supported-font-family-mappings
  '(("Arial" . :default)
    ("Courier New" . :verbatim)
    ("Roboto Mono" . :code))
  "Font families with an exact representation in the Org model.

The two monospace names are deliberate encoder/decoder markers.  Do not use
substring matching here: an arbitrary family containing `Courier' or `Mono'
would otherwise be silently replaced by one of these mappings.")

(defconst gdocs--capability-default-text-size 11.0)
(defconst gdocs--capability-default-foreground-color "#000000")
(defconst gdocs--capability-default-vertical-alignment "nor")
(defconst gdocs--capability-default-text-weight 400)

(defconst gdocs--capability-document-attribute-types
  '("document" "headings" "language")
  "Attribute types Google scopes to the whole document.

They are emitted as zero-width `as' operations (`si' equals `ei') whose
range lies outside the replaced body text.  Body deletion and insertion
therefore cannot discard them, so the capability scanner reports them as
informational instead of destructive.  A non-zero-width operation carrying
one of these types is NOT understood and stays fail-closed.")

(defun gdocs--capability-document-settings-p (style op)
  "Return non-nil when STYLE is a document-scoped type on a zero-width OP."
  (and (member style gdocs--capability-document-attribute-types)
       (listp op)
       (equal (alist-get 'si op) (alist-get 'ei op))))

(defun gdocs--model-version-op-p (op)
  "Return non-nil when OP is a well-formed model-version marker.
Google ends the model chunk of documents saved by a recent editor with
`((ty . \"umv\") (mv . N))'."
  (and (listp op)
       (equal (alist-get 'ty op) "umv")
       (natnump (alist-get 'mv op))))

(defconst gdocs--capability-annotation-attribute-types
  '("bookmark_range" "comment" "ignore_spellcheck" "import_warnings"
    "markup" "named_range" "suppress_feature")
  "Annotation-state attribute types.

The editors frontend emits one `as' operation per annotation system per
saved range, SETting the annotation ids on that range.  An op whose sets
are all EMPTY carries no annotation content (it is the editor's
bookkeeping for a range with no bookmarks/comments/named ranges), so it
is preserved trivially by any push and is reported informationally.  An
op carrying non-empty annotation ids is real content and stays
fail-closed.")

(defun gdocs--capability-annotation-op-empty-p (sm)
  "Return non-nil when SM only clears or declares empty annotation sets.
Every entry must be an explicitness flag (`*_i'), a boolean, or a
`cv'-wrapped set operation whose `opValue' is empty.  A link envelope
(`lnks_link' without a string `ulnk_url') is also an empty marker."
  (and (listp sm)
       (cl-every
        (lambda (entry)
          (let ((key (car-safe entry))
                (value (cdr-safe entry)))
            (or (memq value '(t :json-false))
                (null value)
                (and (symbolp key)
                     (string-suffix-p "_i" (symbol-name key)))
                (and (listp value)
                     (assq 'cv value)
                     (let ((cv (cdr (assq 'cv value))))
                       (and (listp cv)
                            (equal (cdr (assq 'op cv)) "set")
                            (let ((op-value (cdr (assq 'opValue cv))))
                              (or (null op-value)
                                  (and (vectorp op-value)
                                       (= (length op-value) 0))
                                  (and (listp op-value)
                                       (null op-value)))))))
                ;; A link clear-envelope: lnks_link without a usable URL.
                (and (listp value)
                     (assq 'lnks_link value)
                     (not (stringp
                           (cdr (assq 'ulnk_url
                                      (cdr (assq 'lnks_link value))))))))))
        sm)))

(defun gdocs--capability-font-family-style (family)
  "Return the exact Org style represented by FONT or nil.

`:default' means that the family is the ordinary emitted family and carries
no Org inline marker."
  (cdr (assoc family gdocs--capability-supported-font-family-mappings)))

(defun gdocs--capability-table-key-policy (key)
  "Return the classification for table attribute KEY, or nil."
  (cdr (assq key gdocs--capability-table-attribute-key-policy)))

(defun gdocs--capability-kind-label (kind)
  "Return a concise, user-facing label for capability KIND."
  (or (cdr (assq kind
                 '((:inline-image . "inline image")
                   (:remote-chip . "remote chip")
                   (:unknown-entity . "unknown entity")
                   (:unknown-feature . "unknown feature")
                   (:unsupported-style . "unsupported style")
                   (:unsupported-paragraph . "unsupported paragraph construct")
                   (:structural-codepoint . "unhandled structural codepoint")
                   (:comment-anchor . "comment anchor")
                   (:local-unsupported . "local unsupported-content marker")
                   (:unsupported-entity . "unsupported entity")
                   (:document-settings . "document setting")
                   (:annotation-state . "empty annotation marker")
                   (:lossy-fallback . "disclosed fallback"))))
      (replace-regexp-in-string "-" " " (symbol-name kind))))

(defun gdocs--capability-plural-label (kind)
  "Return the plural label for capability KIND."
  (pcase kind
    (:inline-image "inline images")
    (:remote-chip "remote chips")
    (:unknown-entity "unknown entities")
    (:unknown-feature "unknown features")
    (:unsupported-style "unsupported styles")
    (:unsupported-paragraph "unsupported paragraph constructs")
    (:structural-codepoint "unhandled structural codepoints")
    (:comment-anchor "comment anchors")
    (:local-unsupported "local unsupported-content markers")
    (:unsupported-entity "unsupported entities")
    (:document-settings "document settings")
    (:annotation-state "empty annotation markers")
    (:lossy-fallback "disclosed fallbacks")
    (_ (concat (gdocs--capability-kind-label kind) "s"))))

(defun gdocs--capability-report (kind explanation &rest props)
  "Build a sanitized unsupported-capability report.

PROPS may contain `:ot-start', `:ot-end', `:entity-id', `:entity-type',
`:codepoint', `:severity', `:preserve-untouched', `:refuse-push',
`:push-policy', `:source', and `:render-directive'. Raw OT operations and
payloads must never be placed in PROPS. `:preserve-untouched' is the proof
required for an
incremental push; `:refuse-push' marks capabilities for which no such proof
can be made."
  (let* ((preserve (if (plist-member props :preserve-untouched)
                       (plist-get props :preserve-untouched)
                     nil))
         (refuse (if (plist-member props :refuse-push)
                     (plist-get props :refuse-push)
                   t))
         (report (list :kind kind
                       :severity (or (plist-get props :severity)
                                     :destructive)
                       :preserve-untouched preserve
                       :safe-untouched preserve
                       :refuse-push refuse
                       :push-policy (or (plist-get props :push-policy)
                                        (if refuse :refuse :allow-if-untouched))
                       :explanation explanation)))
    (cl-loop for (key value) on props by #'cddr
             unless (memq key '(:severity :preserve-untouched :refuse-push
                                          :push-policy))
             do (setq report (plist-put report key value)))
    report))

(defun gdocs--capability-normalize (value)
  "Convert legacy string VALUE into a structured local report."
  (if (and (listp value) (plist-member value :kind))
      (let* ((report (copy-sequence value))
             (kind (plist-get report :kind))
             (preserve (cond
                        ((plist-member report :preserve-untouched)
                         (plist-get report :preserve-untouched))
                        ((plist-member report :safe-untouched)
                         (plist-get report :safe-untouched))
                        (t nil)))
             (refuse (if (plist-member report :refuse-push)
                         (plist-get report :refuse-push)
                       t)))
        (setq report (plist-put report :severity
                                (or (plist-get report :severity)
                                    :destructive)))
        (setq report (plist-put report :preserve-untouched preserve))
        (setq report (plist-put report :safe-untouched preserve))
        (setq report (plist-put report :refuse-push refuse))
        (setq report (plist-put report :push-policy
                                (or (plist-get report :push-policy)
                                    (if refuse :refuse :allow-if-untouched))))
        (unless (plist-get report :explanation)
          (setq report
                (plist-put report :explanation
                           (format "Unsupported %s."
                                   (gdocs--capability-kind-label kind)))))
        report)
    (gdocs--capability-report
     :local-unsupported
     "The local document contains an unsupported-content marker."
     :source :local)))

(defun gdocs--capability-merge (&rest report-lists)
  "Return REPORT-LISTS concatenated without duplicate reports."
  (let (out keys)
    (dolist (reports report-lists)
      (dolist (report reports)
        (setq report (gdocs--capability-normalize report))
        (let ((key (mapcar (lambda (field) (plist-get report field))
                           '(:kind :entity-id :entity-type :feature-type
                                   :ot-start :ot-end :source))))
          (unless (member key keys)
            (setq keys (append keys (list key)))
            (setq out (append out (list report)))))))
    out))

(defun gdocs--capability-summary (reports)
  "Return a sanitized count summary for REPORTS.
The summary contains kinds and counts only; it never serializes raw OT or
entity payloads."
  (let ((counts (make-hash-table :test #'eq)))
    (dolist (value reports)
      (let ((report (gdocs--capability-normalize value)))
        (let ((kind (plist-get report :kind)))
          (puthash kind (1+ (gethash kind counts 0)) counts))))
    (let (kinds)
      (maphash (lambda (kind _count) (push kind kinds)) counts)
      (setq kinds (sort kinds
                        (lambda (a b)
                          (string< (symbol-name a) (symbol-name b)))))
      (mapconcat
       (lambda (kind)
         (let ((count (gethash kind counts)))
           (format "%d %s" count
                   (if (= count 1)
                       (gdocs--capability-kind-label kind)
                     (gdocs--capability-plural-label kind)))))
       kinds ", "))))

(defun gdocs--capability-sanitized-details (reports)
  "Return debug-safe summaries for REPORTS.
Identifiers, payloads, and raw operation shapes are intentionally omitted."
  (mapcar
   (lambda (value)
     (let ((report (gdocs--capability-normalize value)))
       (let ((out (list :kind (plist-get report :kind)
                        :severity (plist-get report :severity)
                        :preserve-untouched
                        (plist-get report :preserve-untouched)
                        :refuse-push (plist-get report :refuse-push))))
         (dolist (key '(:entity-type :ot-start :ot-end :codepoint))
           (when (plist-member report key)
             (setq out (plist-put out key (plist-get report key)))))
         out)))
   reports))

(defun gdocs--doc-has-inline-object-p (doc)
  "Return non-nil if DOC contains an inline object in any model shape."
  (or (gdocs-dm-inline-objects doc)
      (cl-some
       (lambda (paragraph)
         (or (eq (plist-get paragraph :kind) :inline-object)
             (and (eq (plist-get paragraph :kind) :table)
                  (gdocs--doc-table-inline-objects paragraph))
             (cl-some (lambda (run) (plist-get run :inline-object))
                      (plist-get paragraph :runs))))
       (gdocs-dm-paragraphs doc))))

(defun gdocs-dm-make-run (text &optional styles link)
  "Build a run with TEXT and optional STYLES (list of keywords) and LINK."
  (let ((r (list :text text)))
    (when styles (setq r (plist-put r :styles styles)))
    (when link (setq r (plist-put r :link link)))
    r))

(defun gdocs-dm-runs-text (runs)
  "Return the concatenated text of RUNS (ignoring styles)."
  (mapconcat (lambda (r) (or (plist-get r :text) "")) runs ""))

(defun gdocs--table-cell-runs (cell)
  "Return the flat run list represented by table CELL.

The canonical model stores a cell as a one-element list containing its runs,
but accepting a direct run list here keeps all table boundaries tolerant of
the older intermediate shape as well."
  (cond
   ((null cell) nil)
   ((and (consp cell)
         (consp (car cell))
         (or (plist-member (car cell) :text)
             (plist-member (car cell) :inline-object)))
    cell)
   ((listp cell) (apply #'append cell))
   (t nil)))

(defun gdocs--doc-table-inline-objects (paragraph)
  "Return inline objects nested in table CELLS of PARAGRAPH."
  (cl-loop for row in (plist-get paragraph :rows)
           append (cl-loop for cell in row
                           append (cl-loop for run in
                                           (gdocs--table-cell-runs cell)
                                           when (plist-get run :inline-object)
                                           collect (plist-get run :inline-object)))))

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
  "Convert the supported semantic parts of text-style SM to Org flags.

Font families are mapped only when an exact Org representation exists.  Other
semantic dimensions are intentionally left to the capability scanner rather
than being silently discarded here."
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
      ;; these two exact names are preserved across round-trips.  All other
      ;; families are reported by `gdocs--scan-unsupported-capabilities'.
      (unless (eq ff 'unset)
        (pcase (and (stringp ff) (gdocs--capability-font-family-style ff))
          (:verbatim
           (setq out (plist-put out :verbatim t))
           (setq out (plist-put out :code nil)))
          (:code
           (setq out (plist-put out :code t))
           (setq out (plist-put out :verbatim nil)))
          ;; Arial, an explicit unset, or an unsupported family all mean that
          ;; this range is not one of the two Org monospace mappings.  The
          ;; unsupported case is blocked by the scanner before a push.
          (_
           (setq out (plist-put out :code nil))
           (setq out (plist-put out :verbatim nil)))))
      out)))

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

(defun gdocs--link-sm-action (sm)
  "Decode the link modifier in SM.

Return a plist whose :action is either :set, :clear, or :invalid.  Normal
Google Docs links have the shape

  ((lnks_link . ((lnk_type . 0) (ulnk_url . URL))))

The editor uses a few equivalent representations when it removes a link:
the `lnks_link' value may be JSON false or nil, or the nested `ulnk_url'
may be explicitly unset.  Treat only those representations as a clear;
anything else is invalid so a malformed operation cannot accidentally apply
an unrelated URL."
  (condition-case _err
      (if (not (listp sm))
          (list :action :invalid :reason "sm is not an object")
        (let ((lnks (alist-get 'lnks_link sm 'unset)))
          (cond
           ;; Some model revisions mark the whole link field as explicitly
           ;; unset.
           ((or (eq lnks :json-false) (eq lnks :null) (null lnks))
            (list :action :clear))
           ((eq lnks 'unset)
            ;; `lnks_link_i' is an explicitness marker seen in style
            ;; modifiers; honor it only as a clear, never as a URL-bearing
            ;; operation.
            (let ((marker (alist-get 'lnks_link_i sm 'unset)))
              (if (or (eq marker :json-false) (null marker))
                  (list :action :clear)
                (list :action :invalid
                      :reason "missing sm.lnks_link"))))
           ((listp lnks)
            (let ((url (alist-get 'ulnk_url lnks 'unset)))
              (cond
               ((stringp url)
                (if (string-empty-p url)
                    (list :action :clear)
                  (list :action :set :url url)))
               ((or (eq url 'unset) (eq url :json-false)
                    (eq url :null) (null url))
                ;; A present link object without a URL is the nested form of
                ;; an explicit unset.  It is not a request to retain the
                ;; previous URL.
                (list :action :clear))
               (t
                (list :action :invalid
                      :reason "sm.lnks_link.ulnk_url is not a string")))))
           (t
            (list :action :invalid
                  :reason "sm.lnks_link is not an object")))))
    (error
     (list :action :invalid :reason "malformed link modifier"))))

(defun gdocs--decode-links (ops body-len)
  "Build a vector of length BODY-LEN containing link destinations.

`as st=\"link\"' ranges use the same one-based, inclusive positions as
text-style ranges.  Operations are applied in stream order, so a later
explicit unset removes a previously decoded link.  Invalid ranges or link
modifiers are ignored with a warning; in particular, a bad operation never
gets to reuse the URL from a neighboring range."
  (let ((vec (make-vector body-len nil)))
    (dolist (op ops)
      (condition-case _err
          (when (and (listp op)
                     (equal (alist-get 'ty op) "as")
                     (equal (alist-get 'st op) "link"))
            (let* ((si (alist-get 'si op))
                   (ei (alist-get 'ei op))
                   (action (gdocs--link-sm-action (alist-get 'sm op nil)))
                   (kind (plist-get action :action)))
              (cond
               ;; The annotation envelopes Google emits around saved ranges
               ;; (e.g. a link-clear op whose ei is one past the body) are
               ;; bookkeeping, not malformed data: skip them silently.
               ((and (gdocs--capability-annotation-op-empty-p
                      (alist-get 'sm op nil))
                     (>= ei (1- body-len)))
                nil)
               ((not (and (integerp si) (integerp ei)
                          (<= 1 si) (<= si ei) (<= ei body-len)))
                (gdocs-log 'warn
                           "Ignoring malformed Google Docs link range %S..%S"
                           si ei))
               ((eq kind :invalid)
                (gdocs-log
                 'warn
                 "Ignoring malformed Google Docs link op at %d..%d: %s"
                 si ei (or (plist-get action :reason) "unknown modifier")))
               (t
                (let ((url (and (eq kind :set) (plist-get action :url))))
                  (cl-loop for i from si to ei
                           do (aset vec (1- i) url)))))))
        (error
         (gdocs-log 'warn "Ignoring malformed Google Docs link operation"))))
    vec))

(defun gdocs--decode-para-attrs (ops)
  "Walk paragraph-style ops; return an alist OT-POS → decoded attributes.

Heading levels and anchors are represented in the Org model.  Indentation and
alignment are retained here so the capability scanner can report non-default
values with their OT ranges; they are not silently treated as supported by
the decoder merely because they are decoded."
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

(defun gdocs--effective-list-nesting-level (sm)
  "Return the effective list nesting level from style modifier SM.

Google omits `ls_nest' for level zero.  Preserve an explicitly supplied
value so malformed values remain available to capability validation."
  (when (listp sm)
    (if (assq 'ls_nest sm)
        (alist-get 'ls_nest sm)
      0)))

(defun gdocs--decode-list-bindings (ops)
  "Walk list-style ops; return alist OT-POS → decoded list attributes."
  (let (out)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "list"))
        (let* ((si (alist-get 'si op))
               (sm (alist-get 'sm op))
               (id (alist-get 'ls_id sm))
               (nest (gdocs--effective-list-nesting-level sm))
               (text-style (alist-get 'ls_ts sm 'unset)))
          (when (stringp id)
            (push (cons si (list :list-id id :nest nest
                                 :text-style text-style)) out)))))
    out))

(defun gdocs--decode-table-attrs (ops)
  "Walk table-style ops; return alist OT-POS → (:table-id S :cols N).

Only table identity and column count have a model representation.  Column
widths and nested table attributes are validated separately by
`gdocs--scan-unsupported-capabilities' before a push is allowed."
  (let (out)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "tbl"))
        (let* ((si (alist-get 'si op))
               (sm (alist-get 'sm op))
               (id (and (listp sm) (alist-get 'tbls_tblid sm)))
               (cols (and (listp sm) (alist-get 'tbls_cols sm)))
               (col-cv (and (listp cols) (alist-get 'cv cols)))
               (col-vec (and (listp col-cv)
                             (alist-get 'opValue col-cv)))
               (ncols (if (or (listp col-vec) (vectorp col-vec))
                          (length col-vec)
                        0)))
          (push (cons si (list :table-id id :cols ncols)) out))))
    out))

(defun gdocs--decode-list-defs (ops)
  "Collect ae list entity defs. Return alist (LIST-ID . NESTS) where
NESTS is alist N → decoded semantic list-level fields."
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
                                       :gf (alist-get 'b_gf body)
                                       :text-style (alist-get 'b_ts body 'unset)
                                       :indent-first (alist-get 'b_ifl body)
                                       :indent-left (alist-get 'b_il body)
                                       :alignment (alist-get 'b_a body)
                                       :start-number (alist-get 'b_sn body))))))
          (push (cons id nests) defs))))
    (nreverse defs)))

(defun gdocs--inline-image-object-from-ae (op)
  "Decode an image object definition from inline entity OP.

Google's `ae et=\"inline\"' operation stores image metadata below
`epm.ee_eo'.  The entity is not associated with a body position here;
that association is made by its separate `te' operation."
  (let* ((id (alist-get 'id op))
         (epm (alist-get 'epm op))
         (eo (and (listp epm) (alist-get 'ee_eo epm)))
         (content-id (and (listp eo) (alist-get 'i_cid eo)))
         (width (and (listp eo) (alist-get 'i_wth eo)))
         (height (and (listp eo) (alist-get 'i_ht eo))))
    (when (and (stringp id) (stringp content-id))
      (list :kind :inline-object
            :entity-id id
            :object-kind :image
            :content-id content-id
            :width (and (numberp width) width)
            :height (and (numberp height) height)))))

(defconst gdocs--ot-chip-codepoint #xe909
  "OT codepoint Google uses as the placeholder for a smart chip.

Date and person chips occupy exactly one OT position, just like the
image `*' placeholder, and carry no visible text of their own.")

(defconst gdocs--chip-link-prefix "gdocs-chip"
  "Org link protocol used to render date/person chips locally.

The full syntax is `[[gdocs-chip:date ENTITY][DATE]]' and
`[[gdocs-chip:person ENTITY][NAME]]'.  Org displays only the
description (with `org-date' face for date chips), keeping the remote
identity in the hidden link path.")

(defun gdocs--valid-chip-label-p (label)
  "Return non-nil when LABEL can be embedded in a chip placeholder."
  (and (stringp label)
       (not (string-empty-p label))
       (not (string-match-p "[[:cntrl:]]" label))))

(defun gdocs--chip-date-parse (text)
  "Parse date-chip display TEXT into (YEAR MONTH DAY), or nil.
Accepts Org date syntax (`2026-08-31', with or without a weekday) and
the Google label format (`Aug 31, 2026')."
  (let ((parsed (parse-time-string (string-trim (or text "")))))
    (and (nth 3 parsed) (nth 4 parsed) (nth 5 parsed)
         (list (nth 5 parsed) (nth 4 parsed) (nth 3 parsed)))))

(defun gdocs--chip-date-ymd (seconds label)
  "Return a date chip's (YEAR MONTH DAY) from its epoch or label.
SECONDS is the chip's `dfie_ts' epoch; Google encodes the chip date as
noon UTC so the calendar date is timezone-safe.  LABEL is parsed as a
fallback for older payloads."
  (or (and (numberp seconds)
           (let ((decoded (decode-time seconds "UTC")))
             (list (nth 5 decoded) (nth 4 decoded) (nth 3 decoded))))
      (gdocs--chip-date-parse label)))

(defun gdocs--chip-date-display (object)
  "Return the Org display text for date chip OBJECT."
  (or (and (plist-get object :ymd)
           (format-time-string
            "%Y-%m-%d %a"
            (encode-time 0 0 0
                         (nth 2 (plist-get object :ymd))
                         (nth 1 (plist-get object :ymd))
                         (nth 0 (plist-get object :ymd)))))
      (plist-get object :label)))

(defun gdocs--chip-entity-object (op)
  "Decode a date/person chip `ae' entity definition OP into an object plist.

The chip's semantic payload becomes its stable `:chip-value' (the
calendar date for date chips, the contact name for person chips), which
is what push matching compares; `:label' retains Google's display text
for the Org rendering.  A changed semantic value is reported as a
changed object rather than silently rewritten."
  (let* ((type (alist-get 'et op))
         (epm (alist-get 'epm op))
         (label (if (equal type "date")
                    (alist-get 'dfie_dt (alist-get 'dat_df epm))
                  (alist-get 'per_n epm)))
         (seconds (and (equal type "date")
                       (alist-get 'tv_s
                                  (alist-get 'tv
                                             (alist-get 'dfie_ts epm)))))
         (ymd (and (equal type "date")
                   (gdocs--chip-date-ymd seconds label))))
    (when (and (gdocs--valid-chip-label-p label)
               (stringp (alist-get 'id op))
               (or (not (equal type "date")) ymd))
      (list :kind :inline-object
            :object-kind (if (equal type "date") :chip-date :chip-person)
            :entity-id (alist-get 'id op)
            :label label
            :ymd ymd
            :chip-value (if (equal type "date")
                            (format "%04d-%02d-%02d"
                                    (nth 0 ymd) (nth 1 ymd) (nth 2 ymd))
                          label)))))

(defun gdocs--chip-object-from-link (el props)
  "Build a chip object from an Org chip link EL with link PROPS, or nil.
Accepts both the registered-protocol parse (path already stripped) and
the fuzzy fallback (full path kept).  A date description that does not
parse returns nil so the marker fails closed."
  (when (and (consp el) (eq (car el) 'link) (listp props))
    (let* ((type (plist-get props :type))
           (path (plist-get props :path))
           (full (cond
                  ((and (stringp type)
                        (equal type gdocs--chip-link-prefix))
                   path)
                  ((and (stringp path)
                        (string-prefix-p
                         (concat gdocs--chip-link-prefix ":") path))
                   (substring path
                              (1+ (length gdocs--chip-link-prefix)))))))
      (when (and (stringp full)
                 (string-match
                  "\\`\\(date\\|person\\):\\([^[:space:]]+\\)\\'" full))
        (let* ((kind (match-string 1 full))
               (entity-id (match-string 2 full))
               (begin (org-element-property :contents-begin el))
               (end (org-element-property :contents-end el))
               (desc (and begin end
                          (buffer-substring-no-properties begin end))))
          (when (gdocs--valid-chip-label-p desc)
            (if (equal kind "date")
                (let ((ymd (gdocs--chip-date-parse desc)))
                  (and ymd
                       (list :kind :inline-object
                             :object-kind :chip-date
                             :entity-id entity-id
                             :label desc
                             :ymd ymd
                             :chip-value (format "%04d-%02d-%02d"
                                                 (nth 0 ymd)
                                                 (nth 1 ymd)
                                                 (nth 2 ymd)))))
              (and (gdocs--valid-inline-object-id-p entity-id)
                   (list :kind :inline-object
                         :object-kind :chip-person
                         :entity-id entity-id
                         :label desc
                         :ymd nil
                         :chip-value desc)))))))))

(defun gdocs--chip-org-link (object)
  "Render chip OBJECT as an Org link; the description is what Org shows."
  (pcase (plist-get object :object-kind)
    (:chip-date
     (format "[[%s:date:%s][%s]]"
             gdocs--chip-link-prefix
             (plist-get object :entity-id)
             (gdocs--chip-date-display object)))
    (:chip-person
     (format "[[%s:person:%s][%s]]"
             gdocs--chip-link-prefix
             (plist-get object :entity-id)
             (or (plist-get object :label) "")))
    (_ (user-error "gdocs: invalid inline-object marker metadata"))))

(defun gdocs--chip-link-face (path)
  "Return the Org face for a chip link with PATH.
Date chips render with the `org-date' face so they look like ordinary
Org timestamps; person chips use the ordinary link face."
  (if (string-prefix-p "person:" path) 'org-link 'org-date))

(org-link-set-parameters
 gdocs--chip-link-prefix
 :follow #'gdocs--chip-link-follow
 :face #'gdocs--chip-link-face)

(defun gdocs--chip-link-follow (path _arg)
  "Follow handler for chip links: chips are pull-only remote objects."
  (user-error
   "gdocs: remote chip %s is pull-only; edit it in Google Docs and pull" path))

(defun gdocs--inline-object-is-image-p (object)
  "Return non-nil when inline OBJECT is an image placeholder."
  (eq (plist-get object :object-kind) :image))

(defconst gdocs--inline-object-identity-keys
  '(:entity-id :kind :object-kind :content-id :width :height :chip-value)
  "Stable fields that identify an inline object for comparison.

OT positions, decoder-only vectors, and source metadata are deliberately not
part of this identity.  Width and height remain part of the identity because
changing either changes the rendered object and cannot be preserved by a text
only incremental edit.  A chip's `:chip-value' (calendar date or contact
name) participates for the same reason; its display label does not.")

(defun gdocs--inline-object-canonical-value (key value)
  "Normalize VALUE for stable inline-object identity KEY.

JSON decoding and Org parsing may represent the same dimension as an integer
or a float.  Normalize numeric dimensions so that representation details do
not make an unchanged object look changed."
  (if (and (memq key '(:width :height)) (numberp value))
      (float value)
    value))

(defun gdocs--inline-object-dimension-equal-p (a b)
  "Return non-nil when dimensions A and B are exactly numerically equal.

The preservation policy accepts integer/float representation differences, but
does not use a tolerance and does not treat missing/non-numeric dimensions as
preserved metadata."
  (and (gdocs--valid-inline-object-dimension-p a)
       (gdocs--valid-inline-object-dimension-p b)
       (= (float a) (float b))))

(defun gdocs--inline-object-identity (object)
  "Return the stable comparison identity of inline OBJECT.

Only `gdocs--inline-object-identity-keys' are copied.  In particular,
`:ot-position' remains available to the capability preflight but is not part
of equality, because it changes when unrelated text is inserted before an
otherwise untouched object."
  (when (and object (listp object))
    (cl-loop for key in gdocs--inline-object-identity-keys
             append (list key
                          (gdocs--inline-object-canonical-value
                           key (plist-get object key))))))

(defun gdocs--decode-inline-objects (ops body)
  "Decode inline image and smart-chip entities in OPS against OT BODY.

An `ae' operation whose entity type is \"inline\" (image), \"date\", or
\"person\" defines an entity.  Its `te' operation contains the
authoritative one-based `spi' position and matching entity ID;
`body[spi - 1]' must be the entity's placeholder codepoint.  Entity or
operation order is deliberately ignored.  The result is a plist with
`:objects', a position-indexed `:object-vector', and structured
`:unsupported' capability reports."
  (let ((definitions (make-hash-table :test #'equal))
        (attachments nil)
        (reports nil)
        (body-len (length (or body ""))))
    (dolist (op ops)
      (when (listp op)
        (cond
         ((and (equal (alist-get 'ty op) "ae")
               (member (alist-get 'et op) '("inline" "date" "person")))
          (let* ((id (alist-get 'id op))
                 (kind (if (equal (alist-get 'et op) "inline")
                           :inline-image :remote-chip))
                 (object (if (equal (alist-get 'et op) "inline")
                             (gdocs--inline-image-object-from-ae op)
                           (gdocs--chip-entity-object op))))
            (cond
             ((not (stringp id))
              (push (gdocs--capability-report
                     kind
                     "A remote entity definition has no usable identifier."
                     :refuse-push t :render-directive t)
                    reports))
             ((gethash id definitions)
              (push (gdocs--capability-report
                     kind
                     "A remote entity definition is supplied more than once."
                     :entity-id id
                     :refuse-push t :render-directive t)
                    reports))
             (object (puthash id (cons (alist-get 'et op) object) definitions))
             (t
              (puthash id (cons (alist-get 'et op) :unsupported) definitions)
              (push (gdocs--capability-report
                     kind
                     "A remote entity has metadata the decoder cannot preserve."
                     :entity-id id
                     :refuse-push t :render-directive t)
                    reports)))))
         ((equal (alist-get 'ty op) "te")
          (push (list (alist-get 'id op) (alist-get 'spi op)) attachments)))))
    (setq attachments (nreverse attachments))
    (let ((objects nil)
          (object-vector (make-vector body-len nil))
          (seen-ids (make-hash-table :test #'equal))
          (seen-positions (make-hash-table :test #'eql)))
      (dolist (attachment attachments)
        (let* ((id (nth 0 attachment))
               (spi (nth 1 attachment))
               (definition (and (stringp id) (gethash id definitions)))
               (type (car-safe definition))
               (object (and (consp definition) (cdr definition)))
               (kind (if (equal type "inline") :inline-image :remote-chip))
               (placeholder (if (equal type "inline")
                                ?* gdocs--ot-chip-codepoint)))
          (cond
           ((not (stringp id))
            (push (gdocs--capability-report
                   :inline-image
                   "A remote entity attachment has no usable identifier."
                   :refuse-push t :render-directive t)
                  reports))
           ((null definition)
            (push (gdocs--capability-report
                   :unknown-entity
                   "A remote entity attachment has no matching definition."
                   :entity-id id
                   :refuse-push t :render-directive t)
                  reports))
           ((eq object :unsupported)
            ;; The malformed definition already contributed the detailed
            ;; reason above; retain this attachment as unsupported too.
            (push (gdocs--capability-report
                   kind
                   "A remote entity attachment cannot be decoded."
                   :entity-id id
                   :refuse-push t :render-directive t)
                  reports))
           ((not (integerp spi))
            (push (gdocs--capability-report
                   kind
                   "A remote entity attachment has no usable OT position."
                   :entity-id id
                   :refuse-push t :render-directive t)
                  reports))
           ((or (< spi 1) (> spi body-len))
            (push (gdocs--capability-report
                   kind
                   "A remote entity attachment has an out-of-range OT position."
                   :entity-id id
                   :refuse-push t :render-directive t)
                  reports))
           ((/= (aref body (1- spi)) placeholder)
            (push (gdocs--capability-report
                   kind
                   "A remote entity attachment is not attached to its placeholder."
                   :entity-id id
                   :ot-start spi :ot-end spi
                   :preserve-untouched t :refuse-push nil
                   :push-policy :allow-if-untouched :render-directive t)
                  reports))
           ((gethash id seen-ids)
            (push (gdocs--capability-report
                   kind
                   "A remote entity is attached more than once."
                   :entity-id id
                   :refuse-push t :render-directive t)
                  reports))
           ((gethash spi seen-positions)
            (push (gdocs--capability-report
                   kind
                   "A remote entity placeholder has multiple attached entities."
                   :ot-start spi :ot-end spi
                   :preserve-untouched t :refuse-push nil
                   :push-policy :allow-if-untouched :render-directive t)
                  reports))
           (t
            (setq object (plist-put (copy-sequence object) :ot-position spi))
            (puthash id t seen-ids)
            (puthash spi t seen-positions)
            (aset object-vector (1- spi) object)
            (push (gdocs--capability-report
                   kind
                   (if (equal type "inline")
                       "Inline images are pull-only; the current OT encoder can preserve one only when it is left untouched."
                     (format "Remote %s chips are pull-only; the current OT encoder can preserve one only when it is left untouched."
                             (if (equal type "date") "date" "person")))
                   :entity-id id
                   :ot-start spi :ot-end spi
                   :preserve-untouched t :refuse-push nil
                   :push-policy :allow-if-untouched)
                  reports)
            (push object objects)))))
      ;; Every inline definition must have exactly one attachment.  This is
      ;; what prevents a missing or reordered `te' from being guessed from
      ;; the number or order of literal asterisks in the body.
      (maphash
       (lambda (id definition)
         (unless (gethash id seen-ids)
           (unless (eq (cdr definition) :unsupported)
             (push (gdocs--capability-report
                    (if (equal (car definition) "inline")
                        :inline-image :remote-chip)
                    "A remote entity has no unambiguous OT attachment."
                    :entity-id id
                    :refuse-push t :render-directive t)
                   reports))))
       definitions)
      (list :objects (sort objects
                           (lambda (a b)
                             (< (plist-get a :ot-position)
                                (plist-get b :ot-position))))
            :object-vector object-vector
            :unsupported (nreverse reports)))))

(defun gdocs--capability-op-range (op)
  "Return OP's sanitized inclusive OT range, or nil when unavailable."
  (let ((start (alist-get 'si op))
        (end (alist-get 'ei op)))
    (when (and (integerp start) (>= start 1)
               (or (null end)
                   (and (integerp end) (>= end start))))
      (list :ot-start start
            :ot-end (if (and (integerp end) (>= end start)) end start)))))

(defun gdocs--capability-report-for-op
    (kind explanation op &rest props)
  "Build a capability report for OP, adding its OT range when known."
  (apply #'gdocs--capability-report kind explanation
         (append (gdocs--capability-op-range op) props)))

(defun gdocs--capability-unknown-style-keys (sm known)
  "Return unknown semantic keys in style modifier SM.

Explicitness/inheritance keys ending in `_i' are deliberately excluded:
their presence does not carry a formatting value, and they are classified
separately by the policy tables."
  (if (not (listp sm))
      '(:malformed-style)
    (cl-loop for entry in sm
             for key = (and (consp entry) (car entry))
             unless (and key
                         (or (memq key known)
                             (and (symbolp key)
                                  (string-suffix-p "_i" (symbol-name key)))))
             collect (or key :malformed-style))))

(defun gdocs--capability-default-value-p (value)
  "Return non-nil when VALUE means an ordinary unset/default value."
  (memq value '(nil :json-false :null)))

(defun gdocs--capability-number-equal-p (value expected)
  "Return non-nil when numeric VALUE equals numeric EXPECTED."
  (and (numberp value) (numberp expected) (= value expected)))

(defun gdocs--capability-color-default-p (value default-color)
  "Return non-nil when color VALUE has the emitted DEFAULT-COLOR semantics.

Google represents colors as an object containing `hclr_color' and
`clr_type'.  Missing/default components are accepted because they carry the
same visible result as the canonical emitted object."
  (cond
   ((gdocs--capability-default-value-p value) t)
   ((stringp value)
    (if default-color
        (string-equal (downcase value) (downcase default-color))
      (string-empty-p value)))
   ((listp value)
    (and (cl-every
          (lambda (entry)
            (memq (car-safe entry) '(hclr_color clr_type)))
          value)
         (let* ((color-entry (assq 'hclr_color value))
                (color (and color-entry (cdr color-entry)))
                (type-entry (assq 'clr_type value))
                (type (and type-entry (cdr type-entry))))
           (and (or (null color-entry)
                    (gdocs--capability-default-value-p color)
                    (and (stringp color)
                         (if default-color
                             (string-equal (downcase color)
                                           (downcase default-color))
                           (string-empty-p color))))
                (or (null type-entry)
                    (gdocs--capability-default-value-p type)
                    (gdocs--capability-number-equal-p type 0))))))
   (t nil)))

(defun gdocs--capability-letter-spacing-default-p (value)
  "Return non-nil when letter-spacing VALUE means no extra spacing.
Google writes `ts_lsp' as `((lspp_points . 0.0) (lsp_type . 0))' on text
and list levels it saves, which is the spacing text has without it."
  (or (gdocs--capability-default-value-p value)
      (and (listp value)
           (cl-every (lambda (entry)
                       (memq (car-safe entry) '(lspp_points lsp_type)))
                     value)
           (let ((points (assq 'lspp_points value))
                 (type (assq 'lsp_type value)))
             (and (or (null points)
                      (gdocs--capability-number-equal-p (cdr points) 0))
                  (or (null type)
                      (gdocs--capability-number-equal-p (cdr type) 0)))))))

(defun gdocs--capability-text-style-value-supported-p (key value)
  "Return non-nil when semantic text-style KEY/VALUE is round-trip safe."
  (pcase key
    ((or 'ts_bd 'ts_it 'ts_un 'ts_st)
     (or (gdocs--capability-default-value-p value) (eq value t)))
    ('ts_ff
     (or (gdocs--capability-default-value-p value)
         (and (stringp value)
              (gdocs--capability-font-family-style value))))
    ('ts_fs
     (or (gdocs--capability-default-value-p value)
         (gdocs--capability-number-equal-p
          value gdocs--capability-default-text-size)))
    ('ts_fgc2
     (gdocs--capability-color-default-p
      value gdocs--capability-default-foreground-color))
    ('ts_bgc2
     (gdocs--capability-color-default-p value nil))
    ('ts_va
     (or (gdocs--capability-default-value-p value)
         (equal value gdocs--capability-default-vertical-alignment)))
    ('ts_sc
     (or (gdocs--capability-default-value-p value) (eq value nil)))
    ('ts_tw
     (or (gdocs--capability-default-value-p value)
         (gdocs--capability-number-equal-p
          value gdocs--capability-default-text-weight)))
    ('ts_lsp
     (gdocs--capability-letter-spacing-default-p value))
    (_ t)))

(defun gdocs--capability-unsupported-value-report
    (kind explanation op feature-type)
  "Build a range-bearing report for unsupported semantic FEATURE-TYPE."
  (gdocs--capability-report-for-op
   kind explanation op
   :feature-type feature-type
   :preserve-untouched t :refuse-push nil
   :push-policy :allow-if-untouched))

(defun gdocs--scan-text-style-modifier (op sm)
  "Return reports for unknown or non-round-trippable text modifier SM."
  (append
   (mapcar
    (lambda (key)
      (gdocs--capability-report-for-op
       :unsupported-style
       "A remote text-style dimension is not represented by the Org/OT model."
       op :feature-type (format "%s" key)
       :preserve-untouched t :refuse-push nil
       :push-policy :allow-if-untouched))
    (gdocs--capability-unknown-style-keys
     sm gdocs--capability-known-text-style-keys))
   (gdocs--scan-text-style-values op sm)))

(defun gdocs--scan-text-style-values (op sm)
  "Return reports for non-round-trippable semantic values in text SM."
  (when (listp sm)
    (cl-loop for (key . policy) in gdocs--capability-text-style-key-policy
             for entry = (assq key sm)
             when (and entry
                       (not (eq policy :explicitness))
                       (not (gdocs--capability-text-style-value-supported-p
                             key (cdr entry))))
             collect
             (gdocs--capability-unsupported-value-report
              :unsupported-style
              "A remote text-style value is not represented by the Org model and would be replaced on push."
              op (symbol-name key)))))

(defun gdocs--capability-list-text-style-value-canonical-p (key value)
  "Return non-nil when list text-style KEY/VALUE has emitted semantics."
  (pcase key
    ((or 'ts_bd 'ts_it 'ts_un 'ts_st 'ts_sc)
     (gdocs--capability-default-value-p value))
    ('ts_ff
     (or (gdocs--capability-default-value-p value)
         (equal value "Arial")))
    ('ts_fs
     (or (gdocs--capability-default-value-p value)
         (gdocs--capability-number-equal-p value 11.0)))
    ('ts_fgc2
     (gdocs--capability-color-default-p value "#000000"))
    ('ts_bgc2
     (gdocs--capability-color-default-p value nil))
    ('ts_va
     (or (gdocs--capability-default-value-p value)
         (equal value "nor")))
    ('ts_tw
     (or (gdocs--capability-default-value-p value)
         (gdocs--capability-number-equal-p value 400)))
    ('ts_lsp
     (gdocs--capability-letter-spacing-default-p value))
    (_ nil)))

(defun gdocs--capability-list-text-style-features
    (style prefix &optional require-semantic-fields)
  "Return noncanonical semantic feature names in list STYLE under PREFIX.
When REQUIRE-SEMANTIC-FIELDS is non-nil, also report absent canonical
semantic fields.  Explicitness metadata is recognized independently and is
not required to establish the semantic value."
  (cond
   ((and (not require-semantic-fields)
         (or (eq style 'unset) (gdocs--capability-default-value-p style))) nil)
   ((not (listp style)) (list prefix))
   (t
    (let ((features
           (cl-loop for entry in style
                    for key = (car-safe entry)
                    for policy = (cdr (assq
                                       key
                                       gdocs--capability-text-style-key-policy))
                    unless (or (memq key
                                     gdocs--capability-list-text-style-explicitness-fields)
                               (and policy
                                    (gdocs--capability-list-text-style-value-canonical-p
                                     key (cdr entry))))
                    collect (if (symbolp key)
                                (format "%s.%s" prefix (symbol-name key))
                              prefix))))
      (when require-semantic-fields
        (dolist (key gdocs--capability-list-text-style-required-semantic-fields)
          (unless (assq key style)
            (push (format "%s.%s" prefix (symbol-name key)) features))))
      (delete-dups (nreverse features))))))

(defun gdocs--list-binding-paragraph-range (op body)
  "Return the paragraph range proven by list binding OP in BODY."
  (let ((si (alist-get 'si op))
        (ei (alist-get 'ei op)))
    (when (and (integerp si) (>= si 1) (equal si ei)
               (<= si (length (or body "")))
               (= (aref body (1- si)) ?\n))
      (let ((previous (cl-position ?\n body :from-end t :end (1- si))))
        (list :ot-start (if previous (+ previous 2) 1)
              :ot-end si)))))

(defun gdocs--capability-list-report
    (kind explanation feature &optional range entity-id)
  "Build a list capability report for FEATURE and its proven RANGE."
  (apply #'gdocs--capability-report kind explanation
         (append (when range range)
                 (when entity-id
                   (list :entity-type "list" :entity-id entity-id))
                 (list :feature-type feature
                       :preserve-untouched (and range t)
                       :refuse-push (not range)
                       :push-policy (if range :allow-if-untouched :refuse)))))

(defun gdocs--scan-list-text-style (op sm body)
  "Return reports for noncanonical nested `ls_ts' values in list binding SM."
  (when (listp sm)
    (let ((range (gdocs--list-binding-paragraph-range op body)))
      (mapcar
       (lambda (feature)
         (gdocs--capability-list-report
          :unsupported-paragraph
          "A remote list text-style value is not reproduced by the OT encoder."
          feature range))
       (gdocs--capability-list-text-style-features
        (alist-get 'ls_ts sm 'unset) "ls_ts")))))

(defun gdocs--capability-list-level-features (level level-body)
  "Return every noncanonical semantic feature in LEVEL-BODY at LEVEL."
  (if (not (and (integerp level) (<= 0 level) (<= level 8)
                (listp level-body)))
      (list "le_nb")
    (let* ((gt (alist-get 'b_gt level-body 'unset))
           (numbered (memq gt '(10 13 15)))
           (bullet-glyphs ["●" "○" "■" "●" "○" "■" "●" "○" "■"])
           features)
      (dolist (key gdocs--capability-list-level-required-semantic-fields)
        (unless (assq key level-body)
          (push (symbol-name key) features)))
      (dolist (entry level-body)
        (let* ((key (car-safe entry))
               (value (cdr entry))
               (known (assq key gdocs--capability-list-level-key-policy))
               (canonical
                (pcase key
                  ('b_gt (memq value '(9 13)))
                  ('b_gs (equal value (if numbered ""
                                        (aref bullet-glyphs level))))
                  ('b_gf (equal value (format "%%%d%s" level
                                              (if numbered "." ""))))
                  ('b_ifl (gdocs--capability-number-equal-p
                           value (+ 18 (* 36 level))))
                  ('b_il (gdocs--capability-number-equal-p
                          value (* 36 (1+ level))))
                  ('b_a (gdocs--capability-number-equal-p value 0))
                  ('b_sn (gdocs--capability-number-equal-p value 1))
                  ('b_ts t)
                  (_ nil))))
          (cond
           ((and (symbolp key) (string-suffix-p "_i" (symbol-name key))))
           ((not known)
            (push (if (symbolp key) (symbol-name key) "list-level") features))
           ((eq key 'b_ts)
            (setq features
                  (nconc (gdocs--capability-list-text-style-features
                          value "b_ts" t) features)))
           ((not canonical)
            (push (symbol-name key) features)))))
      (nreverse features))))

(defun gdocs--list-entity-binding-ranges (ops body)
  "Return list entity binding ranges, levels, and proof completeness."
  (let (bindings)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "list"))
        (let* ((sm (alist-get 'sm op))
               (id (and (listp sm) (alist-get 'ls_id sm)))
               (range (gdocs--list-binding-paragraph-range op body)))
          (when (stringp id)
            (let* ((cell (assoc id bindings))
                   (info (or (cdr cell)
                             (list :ranges nil :references nil :complete t))))
              (setq info
                    (plist-put info :references
                               (cons (cons (gdocs--effective-list-nesting-level sm)
                                           range)
                                     (plist-get info :references))))
              (if range
                  (setq info (plist-put
                              info :ranges
                              (cons range (plist-get info :ranges))))
                (setq info (plist-put info :complete nil)))
              (if cell
                  (setcdr cell info)
                (push (cons id info) bindings)))))))
    bindings))

(defun gdocs--list-binding-level-ranges (binding-info level)
  "Return every proven or unknown range referencing LEVEL in BINDING-INFO."
  (cl-loop for (nest . range) in (plist-get binding-info :references)
           when (equal nest level)
           collect range))

(defun gdocs--list-nesting-sequence-reports (ops body)
  "Report list nesting transitions that plain Org lists cannot represent."
  (let (bindings reports previous)
    (dolist (op ops)
      (when (and (equal (alist-get 'ty op) "as")
                 (equal (alist-get 'st op) "list"))
        (let* ((sm (alist-get 'sm op))
               (nest (gdocs--effective-list-nesting-level sm))
               (range (gdocs--list-binding-paragraph-range op body)))
          (when (and range (integerp nest) (<= 0 nest) (<= nest 8))
            (push (list :nest nest :range range) bindings)))))
    (dolist (binding
             (sort bindings
                   (lambda (a b)
                     (< (plist-get (plist-get a :range) :ot-start)
                        (plist-get (plist-get b :range) :ot-start)))))
      (let* ((range (plist-get binding :range))
             (nest (plist-get binding :nest))
             (contiguous
              (and previous
                   (= (plist-get range :ot-start)
                      (1+ (plist-get (plist-get previous :range) :ot-end)))))
             (maximum (if contiguous
                          (1+ (plist-get previous :nest))
                        0)))
        (when (> nest maximum)
          (let ((report
                 (gdocs--capability-list-report
                  :unsupported-paragraph
                  "A remote list nesting transition cannot be represented by an Org plain list."
                  "list-nesting-sequence" range)))
            (push (plist-put report :render-directive t) reports)))
        (setq previous binding)))
    (nreverse reports)))

(defun gdocs--list-entity-level (levels level)
  "Return the unique LEVEL entry from LEVELS, or nil when not provable."
  (let* ((name (intern (format "nl_%d" level)))
         (matches (cl-remove-if-not
                   (lambda (entry) (eq (car-safe entry) name)) levels)))
    (and (= (length matches) 1) (car matches))))

(defun gdocs--paragraph-heading-value-supported-p (value)
  "Return non-nil for paragraph heading values the Org model can emit."
  (or (gdocs--capability-default-value-p value)
      (and (integerp value)
           (memq value '(0 1 2 3 4 5 100 101)))))

(defun gdocs--paragraph-style-value-supported-p (key value attrs)
  "Return non-nil when paragraph semantic KEY/VALUE survives emission.
ATTRS is the effective decoded paragraph attribute plist at the operation's
position, used to validate heading anchors that arrive in a separate op."
  (pcase key
    ('ps_hd (gdocs--paragraph-heading-value-supported-p value))
    ('ps_hdid
     (or (gdocs--capability-default-value-p value)
         (and (stringp value)
              (not (string-empty-p value))
              (integerp (plist-get attrs :heading))
              (memq (plist-get attrs :heading)
                    '(1 2 3 4 5 100 101)))))
    ((or 'ps_il 'ps_ifl 'ps_al)
     (or (gdocs--capability-default-value-p value)
         (gdocs--capability-number-equal-p value 0)))
    (_ t)))

(defun gdocs--scan-paragraph-style-values (op sm para-attrs)
  "Return reports for non-round-trippable semantic values in paragraph SM."
  (when (listp sm)
    (let* ((si (alist-get 'si op))
           (attrs (cdr (assq si para-attrs))))
      (cl-loop for (key . policy) in gdocs--capability-paragraph-style-key-policy
               for entry = (assq key sm)
               when (and entry
                         (not (eq policy :explicitness))
                         (not (gdocs--paragraph-style-value-supported-p
                               key (cdr entry) attrs)))
               collect
               (gdocs--capability-unsupported-value-report
                :unsupported-paragraph
                "A remote paragraph value is not represented by the Org model and would be replaced on push."
                op (symbol-name key))))))

(defun gdocs--capability-table-column-values (sm)
  "Return table column values from table SM, or a validation sentinel.

`:absent' and `:default' mean that no non-default column values are present;
`:invalid' means the table attribute cannot be safely decoded."
  (let ((entry (and (listp sm) (assq 'tbls_cols sm))))
    (cond
     ((null entry) :absent)
     ((gdocs--capability-default-value-p (cdr entry)) :default)
     ((not (listp (cdr entry))) :invalid)
     (t
      (let* ((cols (cdr entry))
             (cv-entry (assq 'cv cols)))
        (cond
         ((null cv-entry) :default)
         ((gdocs--capability-default-value-p (cdr cv-entry)) :default)
         ((not (listp (cdr cv-entry))) :invalid)
         (t
          (let* ((cv (cdr cv-entry))
                 (op-entry (assq 'op cv))
                 (op (and op-entry (cdr op-entry)))
                 (values-entry (assq 'opValue cv))
                 (values (and values-entry (cdr values-entry))))
            (cond
             ((or (null op-entry) (equal op "unset")) :default)
             ((not (equal op "set")) :invalid)
             ((not (or (listp values) (vectorp values))) :invalid)
             (t (if (vectorp values) (append values nil) values)))))))))))

(defun gdocs--capability-table-column-unsupported-keys (column)
  "Return semantic keys in COLUMN that differ from emitted defaults."
  (cond
   ((null column) nil)
   ((not (listp column)) '(table-column))
   (t
    (cl-loop for entry in column
             for key = (and (consp entry) (car entry))
             for value = (and (consp entry) (cdr entry))
             unless
             (or (and (symbolp key)
                      (string-suffix-p "_i" (symbol-name key)))
                 (pcase key
                   ('col_wv (gdocs--capability-number-equal-p value 0))
                   ('col_wt (gdocs--capability-number-equal-p value 1))
                   ('col_tdt
                    (or (gdocs--capability-default-value-p value)
                        (and (listp value)
                             (cl-every
                              (lambda (nested)
                                (eq (car-safe nested) 'tdt_v))
                              value)
                             (let ((nested (assq 'tdt_v value)))
                               (or (null nested)
                                   (gdocs--capability-number-equal-p
                                    (cdr nested) 0))))))
                   ('col_tf
                    (or (gdocs--capability-default-value-p value)
                        (and (listp value)
                             (cl-every
                              (lambda (nested)
                                (memq (car-safe nested) '(ttf_vn ttf_n)))
                              value)
                             (let ((version (assq 'ttf_vn value))
                                   (name (assq 'ttf_n value)))
                               (and (or (null version)
                                        (gdocs--capability-number-equal-p
                                         (cdr version) 0))
                                    (or (null name)
                                        (equal (cdr name) "")))))))
                   (_ nil)))
             collect (or key 'table-column)))))

(defun gdocs--capability-table-unsupported-keys (sm)
  "Return unsupported semantic table keys in table attribute SM."
  (if (not (listp sm))
      '(tbl)
    (let (keys)
      ;; `tbls_tblid' is an identity value and `tbls_cols' is validated below;
      ;; explicitness fields are not semantic formatting values.
      (dolist (entry sm)
        (let ((key (and (consp entry) (car entry))))
          (unless (or (and (memq key '(tbls_tblid tbls_cols))
                           (gdocs--capability-table-key-policy key))
                      (and (symbolp key)
                           (string-suffix-p "_i" (symbol-name key))))
            (push key keys))))
      (let ((cols-entry (assq 'tbls_cols sm)))
        (when cols-entry
          (let ((cols (cdr cols-entry)))
            (unless (gdocs--capability-default-value-p cols)
              (if (not (listp cols))
                  (push 'tbls_cols keys)
                (dolist (entry cols)
                  (let ((key (and (consp entry) (car entry))))
                    (unless (or (eq key 'cv)
                                (and (symbolp key)
                                     (string-suffix-p "_i" (symbol-name key))))
                      (push (or key 'tbls_cols) keys)))
                  (let ((cv-entry (assq 'cv cols)))
                    (when cv-entry
                      (let ((cv (cdr cv-entry)))
                        (unless (gdocs--capability-default-value-p cv)
                          (if (not (listp cv))
                              (push 'tbls_cols keys)
                            (dolist (entry cv)
                              (let ((key (and (consp entry) (car entry))))
                                (unless (or (memq key '(op opValue))
                                            (and (symbolp key)
                                                 (string-suffix-p
                                                  "_i" (symbol-name key))))
                                  (push (or key 'tbls_cols) keys)))
                              (let ((columns
                                     (gdocs--capability-table-column-values sm)))
                                (cond
                                 ((eq columns :invalid)
                                  (push 'tbls_cols keys))
                                 ((listp columns)
                                  (dolist (column columns)
                                    (dolist (key
                                             (gdocs--capability-table-column-unsupported-keys
                                              column))
                                      (push key keys))))))))))))))))
          (delete-dups (nreverse keys)))))))

(defun gdocs--scan-unsupported-capabilities (ops body)
  "Classify raw OPS and structural codepoints in BODY.

This scanner records only capability metadata and short explanations. It
never copies an operation, style payload, URL, or entity contents into a
report. Inline image reports are produced by
`gdocs--decode-inline-objects'."
  (let ((reports nil)
        (attachments (make-hash-table :test #'equal))
        (list-entity-counts (make-hash-table :test #'equal))
        (para-attrs (gdocs--decode-para-attrs ops))
        (list-binding-ranges (gdocs--list-entity-binding-ranges ops body)))
    (setq reports (gdocs--list-nesting-sequence-reports ops body))
    ;; Collect attachment positions first so an unknown entity can carry a
    ;; useful range when Google supplied a `te' operation for it.
    (dolist (op ops)
      (when (and (listp op) (equal (alist-get 'ty op) "te"))
        (let ((id (alist-get 'id op))
              (spi (alist-get 'spi op)))
          (when (and (stringp id) (integerp spi) (>= spi 1))
            (puthash id spi attachments)))))
    (dolist (op ops)
      (when (and (listp op)
                 (equal (alist-get 'ty op) "ae")
                 (equal (alist-get 'et op) "list")
                 (stringp (alist-get 'id op)))
        (let ((id (alist-get 'id op)))
          (puthash id (1+ (gethash id list-entity-counts 0))
                   list-entity-counts))))
    (dolist (op ops)
      (when (listp op)
        (let* ((type (alist-get 'ty op))
               (classification (gdocs--capability-classify :operation type)))
          (cond
           ((eq classification :unknown)
            (push (gdocs--capability-report-for-op
                   :unknown-feature
                   "The remote operation type is not understood and would be removed by a full replacement."
                   op
                   :feature-type (if (stringp type) type "unknown")
                   :refuse-push t)
                  reports))
           ;; The model-version marker closes a document's model chunk and
           ;; names the model version the editor saved it under.  It holds
           ;; no content and sits outside the body, so a body replacement
           ;; cannot remove it.  A marker without an integer version is not
           ;; understood and stays fail-closed.
           ((eq classification :model-version)
            (unless (gdocs--model-version-op-p op)
              (push (gdocs--capability-report-for-op
                     :unknown-feature
                     "A model-version marker has no usable version."
                     op :feature-type "umv" :refuse-push t)
                    reports)))
           ((equal type "is")
            (unless (stringp (alist-get 's op))
              (push (gdocs--capability-report-for-op
                     :unknown-feature
                     "A remote text insertion has no usable text payload."
                     op :feature-type "is" :refuse-push t)
                    reports)))
           ((equal type "ae")
            (let* ((entity-type (alist-get 'et op))
                   (entity-id (alist-get 'id op))
                   (entity-class
                    (gdocs--capability-classify :entity entity-type)))
              (cond
               ((eq entity-class :unknown)
                (let ((report
                       (gdocs--capability-report
                        :unknown-entity
                        "The remote entity type is not understood and would be removed by a full replacement."
                        :entity-type (if (stringp entity-type)
                                         entity-type "unknown")
                        :refuse-push t)))
                  (when (stringp entity-id)
                    (setq report (plist-put report :entity-id entity-id)))
                  (when (and (stringp entity-id)
                             (gethash entity-id attachments))
                    (setq report
                          (plist-put report :ot-start
                                     (gethash entity-id attachments)))
                    (setq report
                          (plist-put report :ot-end
                                     (gethash entity-id attachments)))
                    (setq report
                          (plist-put report :preserve-untouched t))
                    (setq report
                          (plist-put report :safe-untouched t))
                    (setq report
                          (plist-put report :refuse-push nil))
                    (setq report
                          (plist-put report :push-policy
                                     :allow-if-untouched)))
                  (push report reports)))
               ((equal entity-type "list")
                (if (stringp entity-id)
                    (let ((binding-info
                           (cdr (assoc entity-id list-binding-ranges))))
                      (when binding-info
                        (let* ((epm (alist-get 'epm op))
                               (levels (and (listp epm)
                                            (alist-get 'le_nb epm)))
                               (references (plist-get binding-info :references))
                               entity-features)
                          (when (listp epm)
                            (dolist (entry epm)
                              (let ((key (car-safe entry)))
                                (unless (or (eq key 'le_nb)
                                            (and (symbolp key)
                                                 (string-suffix-p
                                                  "_i" (symbol-name key))))
                                  (push (if (symbolp key)
                                            (symbol-name key) "list-entity")
                                        entity-features)))))
                          (unless (listp levels)
                            (push "le_nb" entity-features))
                          (dolist (feature (delete-dups entity-features))
                            (dolist (reference references)
                              (push (gdocs--capability-list-report
                                     :unsupported-entity
                                     "A bound remote list definition cannot be proven canonical."
                                     feature (cdr reference) entity-id)
                                    reports)))
                          (dolist (level
                                   (delete-dups
                                    (cl-loop for (nest . _range) in references
                                             when (and (integerp nest)
                                                       (<= 0 nest) (<= nest 8))
                                             collect nest)))
                            (let* ((level-entry
                                    (and (listp levels)
                                         (gdocs--list-entity-level levels level)))
                                   (features
                                    (if level-entry
                                        (gdocs--capability-list-level-features
                                         level (cdr level-entry))
                                      (list (format "nl_%d" level))))
                                   (ranges (gdocs--list-binding-level-ranges
                                            binding-info level)))
                              (dolist (feature features)
                                (dolist (range ranges)
                                  (push (gdocs--capability-list-report
                                         :unsupported-entity
                                         "A bound remote list definition cannot be proven canonical."
                                         feature range entity-id)
                                        reports))))))))
                  nil))
               ;; Inline definitions are validated by the image decoder.
               ((equal entity-type "inline") nil)
               ;; Date/person chip definitions are validated by the same
               ;; decoder; its pull-only report covers them.
               ((member entity-type '("date" "person")) nil)
               ((eq entity-class :recognized-not-editable)
                (push (gdocs--capability-report
                       :unsupported-entity
                       "A recognized remote entity is not represented by the Org/OT model."
                       :entity-type (if (stringp entity-type)
                                        entity-type "recognized")
                       :entity-id entity-id
                       :refuse-push t)
                      reports)))))
           ((equal type "as")
            (let* ((style (alist-get 'st op))
                   (style-class (gdocs--capability-classify
                                 :attribute style))
                   (sm (alist-get 'sm op)))
              (cond
               ;; Document-scoped settings are zero-width `as' operations
               ;; outside the replaced body.  Recognized types are reported
               ;; informationally; they never block push because body
               ;; commands cannot remove them.  A non-zero-width operation
               ;; carrying one of these types is not understood and is
               ;; refused like any other unknown feature.
               ((eq style-class :document-settings)
                (if (gdocs--capability-document-settings-p style op)
                    (push (gdocs--capability-report-for-op
                           :document-settings
                           "Document-level settings live outside the replaced body and are not affected by push."
                           op :feature-type (if (stringp style)
                                                style "document-settings")
                           :severity :informational
                           :preserve-untouched t
                           :refuse-push nil
                           :push-policy :allow-push)
                          reports)
                  (push (gdocs--capability-report-for-op
                         :unknown-feature
                         "A document-level attribute has an unexpected range and would be removed by a full replacement."
                         op :feature-type (if (stringp style) style "unknown")
                         :refuse-push t)
                        reports)))
               ;; Annotation-state envelopes whose sets are all empty
               ;; carry no content (the editor's range bookkeeping) and
               ;; are preserved trivially.  Real annotation ids stay
               ;; fail-closed via the unknown branch below.
               ((and (member style
                             gdocs--capability-annotation-attribute-types)
                     (gdocs--capability-annotation-op-empty-p sm))
                (push (gdocs--capability-report-for-op
                       :annotation-state
                       "An empty annotation-state marker (no bookmarks, comments, or named ranges on this range); it carries no content."
                       op :feature-type (if (stringp style) style "annotation")
                       :severity :informational
                       :preserve-untouched t
                       :refuse-push nil
                       :push-policy :allow-push)
                      reports))
               ((eq style-class :unknown)
                (push (gdocs--capability-report-for-op
                       :unknown-feature
                       "The remote attribute type is not understood and would be removed by a full replacement."
                       op :feature-type (if (stringp style) style "unknown")
                       :refuse-push t)
                      reports))
               ((equal style "text")
                (dolist (report (gdocs--scan-text-style-modifier op sm))
                  (push report reports)))
               ((equal style "paragraph")
                (dolist (key (gdocs--capability-unknown-style-keys
                              sm (mapcar #'car
                                         gdocs--capability-paragraph-style-key-policy)))
                  (push (gdocs--capability-report-for-op
                         :unsupported-paragraph
                         "A remote paragraph attribute is not represented by the Org/OT model."
                         op :feature-type (format "%s" key)
                         :preserve-untouched t :refuse-push nil
                         :push-policy :allow-if-untouched)
                        reports))
                (dolist (report (gdocs--scan-paragraph-style-values
                                 op sm para-attrs))
                  (push report reports)))
               ((equal style "list")
                (dolist (key (gdocs--capability-unknown-style-keys
                              sm '(ls_id ls_nest ls_ts)))
                  (push (gdocs--capability-list-report
                         :unsupported-paragraph
                         "A remote list attribute is not represented by the Org/OT model."
                         (format "%s" key)
                         (gdocs--list-binding-paragraph-range op body))
                        reports))
                (dolist (report (gdocs--scan-list-text-style op sm body))
                  (push report reports))
                (let ((id (and (listp sm) (alist-get 'ls_id sm)))
                      (nest (gdocs--effective-list-nesting-level sm))
                      (range (gdocs--list-binding-paragraph-range op body)))
                  (unless (stringp id)
                    (push (gdocs--capability-list-report
                           :unsupported-paragraph
                           "A remote list binding has no usable definition identifier."
                           "ls_id" range)
                          reports))
                  (unless (and (integerp nest)
                               (<= 0 nest) (<= nest 8))
                    (push (gdocs--capability-list-report
                           :unsupported-paragraph
                           "A remote list nesting level is outside the supported range."
                           "ls_nest"
                           range)
                          reports))
                  (when (and (stringp id)
                             (integerp nest) (<= 0 nest) (<= nest 8)
                             (/= (gethash id list-entity-counts 0) 1))
                    (push (gdocs--capability-list-report
                           :unsupported-paragraph
                           (if (zerop (gethash id list-entity-counts 0))
                               "A remote list binding references a missing definition."
                             "A remote list binding references an ambiguous definition.")
                           "list-definition" range id)
                          reports))))
               ((equal style "tbl")
                (dolist (key (gdocs--capability-table-unsupported-keys sm))
                  (push (gdocs--capability-report-for-op
                         :unsupported-paragraph
                         "A remote table attribute is not represented by the Org/OT model and would be replaced on push."
                         op :feature-type
                         (if (symbolp key)
                             (format "tbl.%s" (symbol-name key))
                           "tbl")
                         :preserve-untouched t :refuse-push nil
                         :push-policy :allow-if-untouched)
                        reports)))
               ((equal style "link")
                (let ((action (gdocs--link-sm-action sm)))
                  (unless (or (memq (plist-get action :action) '(:set :clear))
                              ;; A link clear-envelope carries no URL.
                              (gdocs--capability-annotation-op-empty-p sm))
                    (push (gdocs--capability-report-for-op
                           :unsupported-style
                           "A remote link modifier is malformed and cannot be safely round-tripped."
                           op :feature-type "link"
                           :preserve-untouched t :refuse-push nil
                           :push-policy :allow-if-untouched)
                          reports))))
               ((equal style "doco_anchor")
                (unless (gdocs--capability-annotation-op-empty-p sm)
                  (push (gdocs--capability-report-for-op
                         :comment-anchor
                         "A remote comment anchor is not emitted by the OT encoder; it can be preserved only when left untouched."
                         op :preserve-untouched t :refuse-push nil
                         :push-policy :allow-if-untouched)
                        reports)))
               ((eq style-class :recognized-not-editable)
                (push (gdocs--capability-report-for-op
                       :unknown-feature
                       "A recognized remote attribute is not represented by the Org/OT model."
                       op :feature-type (if (stringp style) style "recognized")
                       :preserve-untouched t :refuse-push nil
                       :push-policy :allow-if-untouched)
                      reports)))))))))
    ;; Structural controls outside the four table markers understood by the
    ;; decoder are features, not ordinary text. Report each occurrence with
    ;; its precise OT position so incremental edits can avoid it.
    (let ((structural (and (boundp 'gdocs--ot-structural-codepoints)
                           gdocs--ot-structural-codepoints)))
      (dotimes (i (length (or body "")))
        (let ((codepoint (aref body i)))
          (when (and (>= codepoint #x10)
                     (<= codepoint #x1f)
                     (not (memq codepoint structural)))
            (push (gdocs--capability-report
                   :structural-codepoint
                   "A remote structural codepoint is not handled by the OT decoder."
                   :codepoint codepoint
                   :ot-start (1+ i) :ot-end (1+ i)
                   :preserve-untouched t :refuse-push nil
                   :push-policy :allow-if-untouched)
                  reports)))))
    ;; Known table markers still need a valid nesting shape. An unmatched
    ;; marker is not safe to normalize into an ordinary paragraph.
    (let ((depth 0)
          (open-position nil))
      (dotimes (i (length (or body "")))
        (let ((codepoint (aref body i)))
          (cond
           ((= codepoint gdocs--ot-table-open)
            (when (zerop depth)
              (setq open-position (1+ i)))
            (cl-incf depth))
           ((= codepoint gdocs--ot-table-close)
            (if (> depth 0)
                (progn
                  (cl-decf depth)
                  (when (zerop depth)
                    (setq open-position nil)))
              (push (gdocs--capability-report
                     :unsupported-paragraph
                     "A remote table structure has an unmatched close marker."
                     :feature-type "table-structure"
                     :ot-start (1+ i) :ot-end (1+ i)
                     :preserve-untouched t :refuse-push nil
                     :push-policy :allow-if-untouched)
                    reports))))))
      (when (and (> depth 0) open-position)
        (push (gdocs--capability-report
               :unsupported-paragraph
               "A remote table structure has an unmatched open marker."
               :feature-type "table-structure"
               :ot-start open-position
               :ot-end (length (or body ""))
               :preserve-untouched t :refuse-push nil
               :push-policy :allow-if-untouched)
              reports)))
    (nreverse reports)))

(defun gdocs--decode-capability-analysis (ops body)
  "Decode inline objects and return the complete capability analysis."
  (let* ((inline (gdocs--decode-inline-objects ops body))
         (reports (gdocs--capability-merge
                   (gdocs--scan-unsupported-capabilities ops body)
                   (plist-get inline :unsupported))))
    (list :objects (plist-get inline :objects)
          :object-vector (plist-get inline :object-vector)
          :unsupported reports)))

(defun gdocs--decode-doco-anchors (ops)
  "Extract comment anchors from OPS. Returns an alist (KIX-ID . (SI . EI)).
SI and EI are one-based OT positions; EI is the inclusive final position
of the range, not a one-past-the-end position.
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

(defun gdocs--build-runs
    (body ts-vec start end &optional link-vec inline-object-vec)
  "Slice runs from BODY[START..END-1] using TS-VEC and LINK-VEC.

Returns runs with :text, :styles, and optional :link properties.  A run
ends whenever either the active text styles or the link destination changes.
Structural codepoints are skipped and never become visible run text.
INLINE-OBJECT-VEC maps zero-based OT body indexes to decoded inline-object
plists. An object occupies its one OT placeholder position and is emitted as
a first-class run rather than as text."
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
        (let ((object (and inline-object-vec
                           (aref inline-object-vec i))))
          (if object
              (progn
                (push (list :inline-object object) runs)
                (cl-incf i))
            (let* ((cur-keys (gdocs--styles-active-keys (aref ts-vec i)))
                   (cur-link (and link-vec (aref link-vec i)))
                   (run-start i))
              (cl-loop while (and (< i end)
                                  (not (memq (aref body i)
                                             (list gdocs--ot-table-open
                                                   gdocs--ot-table-close
                                                   gdocs--ot-row-end
                                                   gdocs--ot-cell-end)))
                                  (not (and inline-object-vec
                                            (aref inline-object-vec i)))
                                  (equal cur-keys
                                         (gdocs--styles-active-keys
                                          (aref ts-vec i)))
                                  (equal cur-link
                                         (and link-vec (aref link-vec i))))
                       do (cl-incf i))
              (let ((text (substring body run-start i)))
                (push (gdocs-dm-make-run text cur-keys cur-link) runs)))))))
    (nreverse runs)))

(defun gdocs--build-table-para
    (body ts-vec start end table-attr &optional link-vec inline-object-vec)
  "Construct a :table paragraph from BODY[START..END-1] — the slice
between (but excluding) the 0x10/0x11 markers.

Layout (one row of a 2-cell table):
  0x12 0x1c <cell-text> \\n 0x1c <cell-text> \\n …

0x12 starts a new row; 0x1c starts a new cell within the current row.
Each cell ends with a literal \\n right before the next 0x1c, 0x12, or
0x11 — strip that trailing newline.  LINK-VEC is passed through to cell
run construction."
  (let ((rows nil) (cells nil) (cell-start nil)
        (i start))
    (cl-flet ((flush-cell
                (upto)
                (let* ((from cell-start)
                       (to (if (and (> upto from)
                                    (= (aref body (1- upto)) ?\n))
                               (1- upto)
                             upto))
                       (runs (gdocs--build-runs body ts-vec from to link-vec
                                                inline-object-vec)))
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
  "Return non-nil if RUNS is an unlinked, all-`:code' paragraph.

A linked code-styled paragraph is kept as inline content so its destination
is not lost by the source-block renderer, which intentionally emits raw code
text without inline markup."
  (and runs
       (not (cl-some (lambda (r) (plist-get r :link)) runs))
       (not (cl-some (lambda (r) (plist-get r :inline-object)) runs))
       (cl-every (lambda (r)
                   (or (string-empty-p (or (plist-get r :text) ""))
                       (memq :code (plist-get r :styles))))
                 runs)))

(defun gdocs--build-para (pa lb ta runs list-defs)
  "Assemble one paragraph plist from attrs."
  (let* ((inline-object (and (= (length runs) 1)
                             (plist-get (car runs) :inline-object)))
         (kind (if inline-object :inline-object
                 (gdocs--paragraph-kind pa lb)))
         (heading (and pa (plist-get pa :heading)))
         (anchor (and pa (plist-get pa :anchor)))
         (list-id (and lb (plist-get lb :list-id)))
         (nest (or (and lb (plist-get lb :nest)) 0))
         (glyph (and lb (gdocs--list-glyph-kind list-defs list-id nest)))
         (out (list :kind kind :runs runs)))
    (when inline-object
      (dolist (key '(:entity-id :object-kind :content-id :width :height
                                :label :ymd :chip-value :ot-position))
        (when (plist-member inline-object key)
          (setq out (plist-put out key (plist-get inline-object key))))))
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

(defun gdocs--heading-kind-p (kind)
  "Return non-nil when KIND receives canonical Org heading padding."
  (memq kind '(:heading :title :subtitle)))

(defun gdocs--normalize-paragraphs (paragraphs)
  "Return the canonical paragraph sequence for PARAGRAPHS.

Google Docs can represent visual whitespace as several consecutive empty
paragraphs.  Org has no useful representation for the distinction, so this
normalization intentionally keeps at most one `:blank' paragraph, removes
leading and trailing empty paragraphs, and is lossy for repeated empties.

An empty paragraph between two `:code' paragraphs has a defined meaning: it
is an empty source line.  Such a paragraph is converted to an empty `:code'
paragraph rather than allowing the renderer to close and reopen the source
block.  This keeps source-block boundaries intact and makes the operation
idempotent.  Other single empty paragraphs remain available to represent a
meaningful paragraph break, for example between a paragraph and a list.  A
single blank adjacent to a heading-like paragraph is retained here so the
renderer can observe and reuse it instead of adding another one."
  (let ((collapsed nil)
        (previous-blank nil))
    ;; First collapse adjacent blanks.  Do not mutate the model supplied by a
    ;; caller: the same decoded model may also be used by the OT diff path.
    (dolist (para paragraphs)
      (if (eq (plist-get para :kind) :blank)
          (unless previous-blank
            (push para collapsed)
            (setq previous-blank t))
        (push para collapsed)
        (setq previous-blank nil)))
    (setq collapsed (nreverse collapsed))
    ;; Blank paragraphs at either document edge are only visual padding.  In
    ;; particular, don't let an OT body ending in several newlines turn into
    ;; a visibly padded Org file.
    (while (and collapsed
                (eq (plist-get (car collapsed) :kind) :blank))
      (setq collapsed (cdr collapsed)))
    (setq collapsed (nreverse collapsed))
    (while (and collapsed
                (eq (plist-get (car collapsed) :kind) :blank))
      (setq collapsed (cdr collapsed)))
    (setq collapsed (nreverse collapsed))
    ;; A generic blank between code paragraphs is part of the source block,
    ;; not a paragraph separator outside it.  The first pass guarantees that
    ;; there is at most one such entry to convert.
    (let ((out nil)
          (rest collapsed))
      (while rest
        (let* ((para (car rest))
               (next (cadr rest))
               (previous (car out)))
          (if (and (eq (plist-get para :kind) :blank)
                   (eq (plist-get previous :kind) :code)
                   (eq (plist-get next :kind) :code))
              (push (list :kind :code
                          :runs (list (gdocs-dm-make-run ""))) out)
            (push para out)))
        (setq rest (cdr rest)))
      (nreverse out))))

(defun gdocs--normalize-paragraphs-for-ot (paragraphs)
  "Return PARAGRAPHS canonicalized for remote OT emission/diffing.

`gdocs--normalize-paragraphs' retains one blank adjacent to a heading so the
Org renderer can reuse it.  That blank is presentation-only, however: the OT
model represents the heading paragraph itself and must not receive a new
remote empty paragraph just because Org needs visual padding.  Remove those
heading-adjacent blanks after the common normalization pass."
  (let ((normalized (gdocs--normalize-paragraphs paragraphs))
        (out nil)
        (rest nil))
    (setq rest normalized)
    (while rest
      (let ((para (car rest))
            (next (cadr rest))
            (previous (car out)))
        (unless (and (eq (plist-get para :kind) :blank)
                     (or (gdocs--heading-kind-p (plist-get previous :kind))
                         (gdocs--heading-kind-p (plist-get next :kind))))
          (push para out)))
      (setq rest (cdr rest)))
    (nreverse out)))

(defun gdocs-dm-from-ops (revision doc-id title body ops)
  "Decode BODY (the OT body string) + OPS into a doc-model.
REVISION, DOC-ID and TITLE are stored as metadata."
  (let* ((body-len (length body))
         (ts-vec (gdocs--decode-text-styles ops body-len))
         (link-vec (gdocs--decode-links ops body-len))
         (para-attrs (gdocs--decode-para-attrs ops))
         (list-bindings (gdocs--decode-list-bindings ops))
         (table-attrs (gdocs--decode-table-attrs ops))
         (list-defs (gdocs--decode-list-defs ops))
         (inline-analysis (gdocs--decode-capability-analysis ops body))
         (inline-object-vec (plist-get inline-analysis :object-vector))
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
            (push (gdocs--build-table-para body ts-vec (1+ i) (1- j) ta
                                           link-vec inline-object-vec)
                  paragraphs)
            (setq i j)))
         (t
          ;; Find next \n (which terminates this paragraph) or end of body.
          (let* ((nl (or (cl-position ?\n body :start i :end body-len)
                         body-len))
                 (ot-nl-pos (1+ nl))     ; 1-based
                 (pa (cdr (assq ot-nl-pos para-attrs)))
                 (lb (cdr (assq ot-nl-pos list-bindings)))
                 (runs (gdocs--build-runs body ts-vec i nl link-vec
                                          inline-object-vec)))
            (push (gdocs--build-para pa lb nil runs list-defs) paragraphs)
            (setq i (1+ nl)))))))
    (gdocs-dm-make-doc :revision revision :doc-id doc-id :title title
                       :paragraphs (nreverse paragraphs)
                       :ot-length body-len
                       :lists list-defs
                       :inline-objects (plist-get inline-analysis :objects)
                       :unsupported (plist-get inline-analysis :unsupported))))

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

(defconst gdocs--org-inline-escape-chars
  '(?\\ ?* ?/ ?_ ?+ ?= ?~ ?\[ ?\])
  "Org characters that need a backslash when emitted as literal text.")

(defconst gdocs--org-table-escape-sentinel (string #x2063)
  "Renderer-only sentinel for reversible Org table cell escapes.

The table encoding is `\\vert{} Sp' for a pipe, `\\linebreak{} Sn Sb ' for
a newline, and `SS' for a literal sentinel, where S is this character.")

(defconst gdocs--org-table-pipe-qualifier
  (concat gdocs--org-table-escape-sentinel "p"))

(defconst gdocs--org-table-newline-qualifier
  (concat gdocs--org-table-escape-sentinel "n"))

(defconst gdocs--org-table-boundary-qualifier
  (concat gdocs--org-table-escape-sentinel "b"))

(defun gdocs--escape-org-inline (text &optional escape-special)
  "Normalize TEXT for safe inline Org emission.

OT structural codepoints are stripped.  Org emphasis, link, and escape
characters are escaped or protected when ESCAPE-SPECIAL is non-nil, because
TEXT is then a link description rather than already-encoded Org markup.  The
renderer adds the actual style markers and link delimiters after this
function returns."
  (let ((text (replace-regexp-in-string
               (rx (any 16 17 18 28)) "" text)))
    (if escape-special
        (mapconcat
         (lambda (char)
           (cond
            ;; Org's backslash escape does not reliably suppress `_'
            ;; subscript parsing, and a `\['/`\]` pair can become a LaTeX
            ;; fragment.  Invisible separators preserve the exact visible
            ;; description and are removed on the way back.
            ((memq char '(?_ ?\\ ?\[ ?\]))
             (concat gdocs--org-link-description-sentinel
                     (string char)
                     gdocs--org-link-description-sentinel))
            ((memq char gdocs--org-inline-escape-chars)
             (concat "\\" (string char)))
            (t (string char))))
         (string-to-list text) "")
      text)))

(defconst gdocs--org-style-order
  '(:bold :italic :underline :strike :verbatim :code)
  "Outer→inner emit order for style markers.
Non-atomic styles (bold/italic/underline/strike) wrap atomic
verbatim/code so that `*=foo=*' parses as bold-around-verbatim rather
than the reverse (which org would treat as opaque).")

(defun gdocs--split-inline-space (text)
  "Split TEXT into (LEADING CORE TRAILING) whitespace components.
CORE is TEXT without its leading/trailing whitespace; either component
may be the empty string but CORE and TEXT only differ by whitespace."
  (let ((leading "") (core (or text "")) (trailing ""))
    (when (string-match "\\`[ \t\n\r]+" core)
      (setq leading (match-string 0 core)
            core (substring core (match-end 0))))
    (when (string-match "[ \t\n\r]+\\'" core)
      (setq trailing (match-string 0 core)
            core (substring core 0 (match-beginning 0))))
    (list leading core trailing)))

(defun gdocs--emphasis-pre-char-ok-p (char)
  "Non-nil when CHAR may precede an Org emphasis opener.
CHAR nil means the marker would start the line, which is allowed.
Uses `org-emphasis-regexp-components' so user customization applies."
  (or (null char)
      (string-match-p
       (concat "\\`[" (nth 0 org-emphasis-regexp-components) "]")
       (char-to-string char))))

(defun gdocs--emphasis-post-char-ok-p (char)
  "Non-nil when CHAR may follow an Org emphasis closer.
CHAR nil means the marker would end the line, which is allowed.
Uses `org-emphasis-regexp-components' so user customization applies."
  (or (null char)
      (string-match-p
       (concat "\\`[" (nth 1 org-emphasis-regexp-components) "]")
       (char-to-string char))))

(defun gdocs--wrap-emphasis-inner (inner key)
  "Wrap the styled text INNER in KEY's Org marker when that parses.

Whitespace at the group boundary is moved outside the markers so that a
span covering trailing text whitespace renders as `*text* ' rather than
the unparsable `*text *'.  Markers are dropped (keeping every character)
when Org could not parse the emphasis: an empty core, a core spanning a
line break, or a boundary character outside Org's emphasis pre/post
classes — typically a style that starts or ends mid-word."
  (pcase-let* ((`(,leading ,core ,trailing)
                (gdocs--split-inline-space inner))
               (mk (cdr (assq key gdocs--org-style-markers))))
    (cond
     ((or (string-empty-p core) (string-match-p "[\n\r]" core))
      inner)
     (t (concat leading mk core mk trailing)))))

(defun gdocs--emphasis-boundaries-ok-p (previous-char next-char)
  "Non-nil when Org emphasis parses between PREVIOUS-CHAR and NEXT-CHAR.
Either char may be nil for the line edge.  The border rule (no whitespace
directly inside the markers) is already guaranteed by trimming."
  (and (gdocs--emphasis-pre-char-ok-p previous-char)
       (gdocs--emphasis-post-char-ok-p next-char)))

(defvar gdocs--render-link-description nil
  "Non-nil while rendering the description of one logical Org link.")

(defun gdocs--valid-inline-object-dimension-p (value)
  "Return non-nil when VALUE is representable as a positive finite dimension."
  (and (numberp value)
       (> value 0)
       (condition-case nil
           (let ((as-float (float value)))
             (and (= as-float as-float)
                  (< as-float 1.0e+INF)))
         (error nil))))

(defun gdocs--valid-inline-object-id-p (value)
  "Return non-nil when VALUE is a nonempty, control-free marker field."
  (and (stringp value)
       (not (string-empty-p value))
       (not (string-match-p "[[:space:]]" value))
       (not (seq-some
             (lambda (char)
               (eq (get-char-code-property char 'general-category) 'Cc))
             value))))

(defun gdocs--inline-object-number (value)
  "Format inline-object dimension VALUE for an Org placeholder."
  (unless (gdocs--valid-inline-object-dimension-p value)
    (user-error "gdocs: inline-object dimensions must be positive and finite"))
  (if (integerp value)
      (number-to-string value)
    (let* ((float-output-format nil)
           (printed (prin1-to-string value)))
      (if (string-match "\\`\\([0-9]+\\)\\.0\\'" printed)
          (match-string 1 printed)
        printed))))

(defun gdocs--inline-object-spec (object)
  "Return the unambiguous, remote-marked Org payload for OBJECT.

Images use the stable syntax `image ENTITY WIDTHxHEIGHT
content-id=CONTENT'.  Chips render as Org chip links instead; see
`gdocs--chip-org-link'."
  (unless (and (listp object)
               (eq (plist-get object :kind) :inline-object)
               (gdocs--valid-inline-object-id-p
                (plist-get object :entity-id)))
    (user-error "gdocs: invalid inline-object marker metadata"))
  (unless (eq (plist-get object :object-kind) :image)
    (user-error "gdocs: invalid inline-object marker metadata"))
  (unless (gdocs--valid-inline-object-id-p
           (plist-get object :content-id))
    (user-error "gdocs: invalid inline-object marker metadata"))
  (format "image %s %sx%s content-id=%s"
          (plist-get object :entity-id)
          (gdocs--inline-object-number (plist-get object :width))
          (gdocs--inline-object-number (plist-get object :height))
          (plist-get object :content-id)))

(defun gdocs--render-inline-object (object &optional embedded)
  "Render OBJECT as an explicit remote-object placeholder.

Images use a custom Org keyword when standalone and an Org export
snippet when EMBEDDED in prose, so the marker remains unambiguous even
when sharing a paragraph with ordinary text.  Chips render as Org chip
links in both shapes; Org hides the link path and shows the description."
  (if (gdocs--inline-object-is-image-p object)
      (let ((spec (gdocs--inline-object-spec object)))
        (if embedded
            (format "@@gdocs-inline-object:%s@@" spec)
          (format "#+gdocs_inline_object: %s" spec)))
    (gdocs--chip-org-link object)))

(defun gdocs--render-run-text (run &optional no-link escape-special)
  "Render the textual payload of RUN — escape + optional link wrapping.

When NO-LINK is non-nil, only the text is emitted.  This is used while a
contiguous link group is rendered as one Org link; the default remains useful
for callers rendering one run directly."
  (if (plist-get run :inline-object)
      (gdocs--render-inline-object (plist-get run :inline-object) t)
    (let* ((text (or (plist-get run :text) ""))
           (link (plist-get run :link))
           (clean (gdocs--escape-org-inline
                   text (or escape-special (and link (not no-link))))))
      (if (and link (not no-link))
          (if (and (null (plist-get run :styles))
                   (string= text link))
              (org-link-make-string link)
            (org-link-make-string link
                                  (if (string-empty-p clean) link clean)))
        clean))))

(defun gdocs--render-link-group (runs link)
  "Render contiguous RUNS sharing LINK as one logical Org link.

Rendering the description as a run group preserves style changes inside a
link without repeating the link target for every style run."
  (let* ((description (let ((gdocs--render-link-description t))
                        (gdocs--render-runs-styled runs nil)))
         (plain (gdocs-dm-runs-text runs))
         (bare (and (not (cl-some (lambda (run)
                                    (plist-get run :styles))
                                  runs))
                    (string= plain link))))
    (if bare
        (org-link-make-string link)
      (org-link-make-string link
                            (if (string-empty-p description) link description)))))

(defun gdocs--common-run-style (runs)
  "Return a style key spanning both linked and unlinked RUNS, if any.

Only a style that crosses a link boundary is lifted outside link wrappers.
When every run is linked, styles remain inside the link description, which is
the more idiomatic Org representation for bold/italic link labels."
  (when (and (seq-some (lambda (run) (plist-get run :link)) runs)
             (seq-some (lambda (run) (null (plist-get run :link))) runs))
    ;; Atomic verbatim/code markers cannot safely contain an Org link, so
    ;; keep those styles inside their respective link groups.
    (seq-find (lambda (key)
                (and (not (null runs))
                     (cl-every (lambda (run)
                                 (memq key (plist-get run :styles)))
                               runs)))
              '(:bold :italic :underline :strike))))

(defun gdocs--run-without-style (run key)
  "Return a copy of RUN with style KEY removed."
  (let ((copy (copy-sequence run)))
    (plist-put copy :styles
               (delq key (copy-sequence (plist-get run :styles))))
    copy))

(defun gdocs--render-runs-by-link (runs)
  "Render RUNS after grouping adjacent runs by link destination.

The link grouping keeps bold/italic/code sub-runs inside one logical link;
styles that span both linked and unlinked text are lifted outside the link
boundary first."
  (let ((common-style (gdocs--common-run-style runs)))
    (if common-style
        ;; Keep a style that spans a link boundary outside the link.  This
        ;; both preserves the original formatting and avoids Org treating a
        ;; style marker immediately following a closing bracket as literal.
        (let ((inner (gdocs--render-runs-by-link
                      (mapcar (lambda (run)
                                (gdocs--run-without-style run common-style))
                              runs))))
          (gdocs--wrap-emphasis-inner inner common-style))
      (let ((groups nil)
            (current nil)
            (current-link :gdocs-no-link))
        (dolist (run runs)
          (let ((link (plist-get run :link)))
            (if (or (eq current-link :gdocs-no-link)
                    (equal link current-link))
                (progn
                  (setq current-link link)
                  (push run current))
              (push (cons current-link (nreverse current)) groups)
              (setq current-link link
                    current (list run)))))
        (when current
          (push (cons current-link (nreverse current)) groups))
        (mapconcat
         (lambda (group)
           (let ((link (car group))
                 (group-runs (cdr group)))
             (if link
                 (gdocs--render-link-group group-runs link)
               (gdocs--render-runs-styled group-runs nil))))
         (nreverse groups) "")))))

(defun gdocs--render-runs (runs)
  "Render a list of RUNS to org text.
Adjacent runs that share a link are rendered inside one bracket link, while
adjacent runs that share a style are wrapped by a single emphasis pair rather
than per-run pairs."
  (gdocs--render-runs-by-link runs))

(defun gdocs--normalize-table-cell-runs (runs)
  "Normalize newlines in table RUNS without flattening run metadata.

Every CR becomes LF.  For a CR and LF split across adjacent textual runs, the
pair becomes a separate LF run carrying only styles and a link shared by both
source characters.  Inline objects interrupt adjacency."
  (let (reversed
        previous-cell
        previous-run
        previous-ended-in-cr)
    (dolist (run runs)
      (let ((copy (copy-sequence run)))
        (let ((text (plist-get run :text)))
          (if (stringp text)
              (progn
                (let ((normalized-text
                       (replace-regexp-in-string "\r\n?" "\n" text t t)))
                  (when (and previous-cell
                             previous-ended-in-cr
                             (string-prefix-p "\n" text))
                    (let* ((previous (car previous-cell))
                           (previous-text (plist-get previous :text))
                           (styles
                            (seq-filter
                             (lambda (style)
                               (memq style (plist-get run :styles)))
                             (plist-get previous-run :styles)))
                           (link
                            (and (equal (plist-get previous-run :link)
                                        (plist-get run :link))
                                 (plist-get run :link))))
                      (setcar previous-cell
                              (plist-put previous :text
                                         (substring previous-text 0 -1)))
                      (push (gdocs-dm-make-run "\n" styles link) reversed))
                    (setq normalized-text (substring normalized-text 1)))
                  (setq copy (plist-put copy :text normalized-text)))
                (push copy reversed)
                (unless (string-empty-p text)
                  (setq previous-cell reversed
                        previous-run run
                        previous-ended-in-cr (string-suffix-p "\r" text))))
            (push copy reversed)
            (setq previous-cell nil
                  previous-run nil
                  previous-ended-in-cr nil)))))
    (nreverse reversed)))

(defun gdocs--escape-org-table-cell-markup (text)
  "Escape table delimiters in rendered cell TEXT.

Org table rows are line-oriented, so a literal pipe or newline cannot be
emitted verbatim inside a cell.  Sentinel-qualified `\\vert{}' and
`\\linebreak{}' constructs survive Org parsing and distinguish renderer
escapes from identical literal text.  This is deliberately applied after
inline rendering so pipes in link descriptions and style runs are protected
without changing run boundaries."
  (mapconcat
   (lambda (char)
     (cond
      ((= char (string-to-char gdocs--org-table-escape-sentinel))
       (concat gdocs--org-table-escape-sentinel
               gdocs--org-table-escape-sentinel))
      ((= char 124) (concat "\\vert{}" gdocs--org-table-pipe-qualifier))
      ((= char 10)
       (concat "\\linebreak{}" gdocs--org-table-newline-qualifier
               gdocs--org-table-boundary-qualifier " "))
      (t (string char))))
   (string-to-list (or text "")) ""))

(defun gdocs--render-table-cell (cell)
  "Render one table CELL while keeping its content in one Org row."
  (gdocs--escape-org-table-cell-markup
   (gdocs--render-runs
    (gdocs--normalize-table-cell-runs (gdocs--table-cell-runs cell)))))

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
    (mapconcat (lambda (run)
                 (gdocs--render-run-text run t
                                         gdocs--render-link-description))
               runs "")))

(defun gdocs--render-runs-split-on (key runs already-wrapped)
  "Group RUNS by whether each carries KEY; wrap KEY-bearing groups.

Group text is rendered first so the wrap decision can use the rendered
neighboring characters.  See `gdocs--wrap-emphasis-inner' for the
whitespace and boundary policy."
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
    (setq groups (nreverse groups))
    (let* ((rendered
            (mapcar
             (lambda (g)
               (let* ((has-key (car g))
                      (group-runs (cdr g))
                      (inner
                       (gdocs--render-runs-styled
                        group-runs
                        (if has-key (cons key already-wrapped) already-wrapped))))
                 (cons has-key inner)))
             groups))
           (out nil))
      (cl-loop for tail on rendered
               for index from 0
               do (let* ((has-key (car (car tail)))
                         (inner (cdr (car tail)))
                         (previous (and (> index 0)
                                        (cdr (nth (1- index) rendered))))
                         (next (cadr tail))
                         (previous-char
                          (and previous (length> previous 0)
                               (aref previous (1- (length previous)))))
                         (next-char
                          (and next
                               (let ((text (cdr next)))
                                 (and (length> text 0) (aref text 0))))))
                    (if (and has-key
                             (not (string-empty-p (string-trim inner))))
                        (pcase-let* ((`(,leading ,core ,trailing)
                                      (gdocs--split-inline-space inner))
                                     ;; Whitespace moved outside the markers
                                     ;; is the effective boundary character
                                     ;; the parser will see.
                                     (effective-previous
                                      (if (length> leading 0) ?\s previous-char))
                                     (effective-next
                                      (if (length> trailing 0) ?\s next-char)))
                          (if (or (string-empty-p core)
                                  (string-match-p "[\n\r]" core)
                                  (not (gdocs--emphasis-boundaries-ok-p
                                        effective-previous effective-next)))
                              (push (concat leading core trailing) out)
                            (let ((mk (cdr (assq key gdocs--org-style-markers))))
                              (push (concat leading mk core mk trailing)
                                    out))))
                      (push inner out))))
      (apply #'concat (nreverse out)))))

(defun gdocs--render-heading-stars (level)
  "Return N stars for heading LEVEL (1..5). Levels >5 are clamped to 5."
  (make-string (min 5 (max 1 level)) ?*))

(defun gdocs--render-list-bullet (glyph nest &optional ordinal indent)
  "Return the leading bullet text for a list item.
GLYPH is :bullet or :number; NEST is 0-based. ORDINAL is the 1-based
sequence number within the current numbered list at this nest level
\(only used when GLYPH is :number; defaults to 1). INDENT, when non-nil,
is the syntax-aware leading column computed from the parent item marker."
  (concat (make-string (or indent (* 2 (max 0 nest))) ?\s)
          (if (eq glyph :number)
              (format "%d. " (or ordinal 1))
            "- ")))

(defun gdocs--org-display-width (text)
  "Display width of TEXT as Org renders it, hiding link targets.
Chip links render as only their description, so column alignment uses
the visible width rather than the raw marker length."
  (string-width
   (replace-regexp-in-string
    "\\[\\[\\([^][]*\\)\\]\\[\\([^][]*\\)\\]\\]" "\\2"
    (or text ""))))

(defun gdocs--render-table-para (para)
  "Render a :kind=:table paragraph to an org-mode table.

Rows are padded to a common column count and cells are padded with
spaces so every row shares the same display widths — the shape
`org-table-align' would produce.  Alignment is deterministic, so an
unchanged table keeps its byte-exact rendering across pulls."
  (let* ((rows (plist-get para :rows))
         (rendered
          (mapcar (lambda (row) (mapcar #'gdocs--render-table-cell row))
                  rows))
         (ncols (apply #'max 0 (mapcar #'length rendered)))
         (padded
          (mapcar (lambda (row)
                    (append row (make-list (- ncols (length row)) "")))
                  rendered))
         (widths
          (cl-loop for col below ncols
                   collect (apply #'max 0
                                  (mapcar (lambda (row)
                                            (gdocs--org-display-width
                                             (nth col row)))
                                          padded)))))
    (string-join
     (mapcar (lambda (row)
               (concat "| "
                       (mapconcat
                        #'identity
                        (cl-mapcar
                         (lambda (cell width)
                           (concat cell
                                   (make-string (- width
                                                   (gdocs--org-display-width
                                                    cell))
                                                ?\s)))
                         row widths)
                        " | ")
                       " |"))
             padded)
     "\n")))

(defun gdocs--render-paragraph-line (para &optional ordinal list-indent)
  "Render PARA to its org line (no trailing newline).
ORDINAL applies to numbered list items only — see `gdocs--render-list-bullet'."
  (let* ((kind (plist-get para :kind))
         (runs (plist-get para :runs))
         (text (gdocs--render-runs runs)))
    (pcase kind
      (:blank "")
      (:inline-object (gdocs--render-inline-object para))
      (:unsupported
       (gdocs--render-unsupported-directive
        (list (or (plist-get para :unsupported-reason)
                  "unsupported content"))))
      ;; Google Docs distinguishes the doc *name* (metadata, fetched
      ;; from the HTML <title>) from Title-styled body paragraphs. The
      ;; document name is stored in GDOC_TITLE by the pull wrapper; this
      ;; branch renders only the body paragraph.
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
         (concat (gdocs--render-list-bullet glyph nest ordinal list-indent)
                 text)))
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

(defun gdocs--render-unsupported-directive (reasons &optional keyword)
  "Render structured or legacy REASONS as one visible Org directive.

Only the report explanations are rendered; raw operation payloads are never
copied into the local document.  Identical explanations are grouped with a
repeat count instead of being repeated once per occurrence."
  (format "#+%s: %s" (or keyword "gdocs_unsupported")
          (replace-regexp-in-string
           "[ \t\n\r]+" " "
           (string-trim
            (string-join
             (let ((counts (make-hash-table :test #'equal))
                   (order nil))
               (dolist (reason reasons)
                 (let ((explanation
                        (if (stringp reason)
                            reason
                          (or (plist-get reason :explanation)
                              "unsupported content"))))
                   (unless (gethash explanation counts)
                     (push explanation order))
                   (puthash explanation
                            (1+ (gethash explanation counts 0))
                            counts)))
               (mapcar
                (lambda (explanation)
                  (let ((count (gethash explanation counts)))
                    (if (= count 1)
                        explanation
                      (format "%s (x%d)" explanation count))))
                (nreverse order)))
             "; ")))))

(defun gdocs-dm-to-org (doc)
  "Render a doc-model DOC to a canonical org-mode string.

Code blocks: contiguous :kind=:code paragraphs are wrapped in a single
\\#+begin_src/\\#+end_src block. Lists, headings, tables and plain
paragraphs each emit one line (terminated by \\n). Empty paragraphs are
normalized before rendering. A heading, Title, or Subtitle receives exactly
one blank line on each side where adjacent content exists; an existing blank
paragraph satisfies that rule. Padding is applied to paragraph entries rather
than to the final text, so it never appears inside a source block."
  (let ((paras (gdocs--normalize-paragraphs (gdocs-dm-paragraphs doc)))
        (entries nil)
        (code-lines nil)
        (list-counters (make-hash-table :test #'equal))
        (list-content-indents (make-hash-table :test #'eql)))
    ;; First turn paragraphs into logical render entries. A source block is
    ;; one entry, which makes the later heading-padding pass unable to insert
    ;; a line between two of its source lines.
    (dolist (p paras)
      (let ((kind (plist-get p :kind)))
        ;; Reset numbered-list counters whenever we leave a list. A new
        ;; contiguous list starts fresh when ordinary content intervenes.
        (unless (eq kind :list)
          (clrhash list-counters)
          (clrhash list-content-indents))
        (cond
         ((eq kind :code)
          (push (mapconcat (lambda (r) (or (plist-get r :text) ""))
                           (plist-get p :runs) "")
                code-lines))
         (t
          (when code-lines
            (push (list :kind :code-block
                        :lines (append (list "#+begin_src text")
                                       (nreverse code-lines)
                                       (list "#+end_src")))
                  entries)
            (setq code-lines nil))
          (let ((ordinal nil)
                (list-indent nil))
            (when (eq kind :list)
              (let* ((nest (max 0 (or (plist-get p :nest) 0)))
                     (list-id (plist-get p :list-id))
                     (glyph (plist-get p :glyph))
                     (counter-key (cons list-id nest)))
                (let (deeper-keys)
                  (maphash (lambda (key _value)
                             (when (> (cdr key) nest)
                               (push key deeper-keys)))
                           list-counters)
                  (dolist (key deeper-keys)
                    (remhash key list-counters)))
                (setq list-indent
                      (if (zerop nest)
                          0
                        (or (gethash (1- nest) list-content-indents)
                            (* 2 nest))))
                (when (eq glyph :number)
                  (setq ordinal (1+ (gethash counter-key list-counters 0)))
                  (puthash counter-key ordinal list-counters))
                (let* ((marker (if (eq glyph :number)
                                   (format "%d. " (or ordinal 1))
                                 "- "))
                       (content-indent (+ list-indent (length marker))))
                  (puthash nest content-indent list-content-indents)
                  (let (deeper-indents)
                    (maphash (lambda (level _indent)
                               (when (> level nest)
                                 (push level deeper-indents)))
                             list-content-indents)
                    (dolist (level deeper-indents)
                      (remhash level list-content-indents))))))
            (let ((line (gdocs--render-paragraph-line
                         p ordinal list-indent)))
              (push (list :kind kind
                          :heading (gdocs--org-heading-line-p line)
                          :blank (string-empty-p line)
                          :lines (list line))
                    entries)))))))
    (when code-lines
      (push (list :kind :code-block
                  :lines (append (list "#+begin_src text")
                                 (nreverse code-lines)
                                 (list "#+end_src")))
            entries))
    (setq entries (nreverse entries))
    ;; Add padding from the logical neighboring entries. The look-ahead is
    ;; important: an explicit blank paragraph after a heading must not be
    ;; accompanied by another synthetic blank. Since normalized entries
    ;; contain at most one blank, applying this pass again cannot add anything.
    (let ((out nil))
      (cl-loop for tail on entries
               for entry = (car tail)
               for next = (cadr tail)
               do (let ((heading (plist-get entry :heading))
                        (lines (plist-get entry :lines)))
                    (when (and heading out
                               (not (string-empty-p (car out))))
                      (push "" out))
                    (dolist (line lines)
                      (push line out))
                    (when (and heading next
                               (not (plist-get next :blank)))
                      (push "" out))))
      (let* ((final (nreverse out))
             (explicit-unsupported
              (seq-some (lambda (para)
                          (eq (plist-get para :kind) :unsupported))
                        paras))
             (render-reports
              (seq-filter
               (lambda (report)
                 (plist-get (gdocs--capability-normalize report)
                            :render-directive))
               (gdocs-dm-unsupported doc)))
             (list-nesting-reports
              (seq-filter
               (lambda (report)
                 (equal (plist-get report :feature-type)
                        "list-nesting-sequence"))
               render-reports))
             (other-reports
              (seq-difference render-reports list-nesting-reports #'eq))
             (rendered (concat (string-join final "\n")
                               (if final "\n" ""))))
        (if explicit-unsupported
            rendered
          (concat
           (when other-reports
             (concat (gdocs--render-unsupported-directive other-reports)
                     "\n"))
           (when list-nesting-reports
             (concat
              (gdocs--render-unsupported-directive
               list-nesting-reports "gdocs_unsupported_list_nesting")
              "\n"))
           rendered))))))

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

(defun gdocs--inline-object-dimension (token)
  "Parse an inline-object dimension TOKEN, or return nil."
  (when (and (stringp token)
             (string-match-p
              "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\(?:[eE][+-]?[0-9]+\\)?\\'"
              token))
    (let ((dimension (string-to-number token)))
      (and (gdocs--valid-inline-object-dimension-p dimension) dimension))))

(defun gdocs--parse-inline-object-spec (value)
  "Parse the payload of a `gdocs_inline_object' Org placeholder.

The stable image syntax is `image ENTITY WIDTHxHEIGHT
content-id=CONTENT'.  The date/person payload forms (`date ENTITY
LABEL', `person ENTITY LABEL') are still accepted for buffers pulled by
older builds; current pulls render chips as Org chip links instead."
  (let* ((valid-payload (and (stringp value)
                             (not (seq-some
                                   (lambda (char)
                                     (eq (get-char-code-property
                                          char 'general-category)
                                         'Cc))
                                   value))))
         (fields (and valid-payload
                      (split-string (string-trim value)
                                    "[ \t]+" t))))
    (pcase (car fields)
      ("image"
       (let* ((dimensions (nth 2 fields))
              (content-field (nth 3 fields))
              (content-id (and (stringp content-field)
                               (string-prefix-p "content-id=" content-field)
                               (substring content-field
                                          (length "content-id="))))
              (width-token nil)
              (height-token nil))
         (when (and (= (length fields) 4)
                    (stringp (nth 1 fields))
                    (not (string-empty-p (nth 1 fields)))
                    (stringp dimensions)
                    (string-match
                     "\\`\\([^x]+\\)x\\([^x]+\\)\\'" dimensions))
           (setq width-token (match-string 1 dimensions)
                 height-token (match-string 2 dimensions))
           (when (and (gdocs--inline-object-dimension width-token)
                      (gdocs--inline-object-dimension height-token)
                      (gdocs--valid-inline-object-id-p (nth 1 fields))
                      (gdocs--valid-inline-object-id-p content-id))
             (list :kind :inline-object
                   :entity-id (nth 1 fields)
                   :object-kind :image
                   :content-id content-id
                   :width (gdocs--inline-object-dimension width-token)
                   :height (gdocs--inline-object-dimension height-token))))))
      ((or "date" "person")
       (when (and (>= (length fields) 3)
                  (gdocs--valid-inline-object-id-p (nth 1 fields)))
         (let* ((label (string-join (nthcdr 2 fields) " "))
                (ymd (and (equal (car fields) "date")
                          (gdocs--chip-date-parse label))))
           (when (and (gdocs--valid-chip-label-p label)
                      (or (not (equal (car fields) "date")) ymd))
             (list :kind :inline-object
                   :entity-id (nth 1 fields)
                   :object-kind (if (equal (car fields) "date")
                                    :chip-date :chip-person)
                   :label label
                   :ymd ymd
                   :chip-value (if ymd
                                   (format "%04d-%02d-%02d"
                                           (nth 0 ymd) (nth 1 ymd)
                                           (nth 2 ymd))
                                 label)))))))))

(defun gdocs--unescape-org-inline
    (text &optional link-description table-cell)
  "Remove the literal-text escapes emitted by `gdocs--escape-org-inline'.

Only the characters that the renderer escapes are unescaped.  For link
descriptions, the invisible separator used around subscript/LaTeX-sensitive
characters is removed too.  Table-cell encoding is decoded separately.
Other backslashes remain ordinary user content,
which avoids turning unrelated Org syntax (for example a LaTeX command) into
a different document-model value."
  (let* ((text (if table-cell
                   (gdocs--unescape-org-table-markup text)
                 text))
         (i 0)
         (n (length text))
         (out nil))
    (while (< i n)
      (let ((char (aref text i)))
        (cond
         ((and link-description
               (= char #x200b))
          (cl-incf i))
         ((and (or (not table-cell) link-description)
               (= char ?\\)
               (< (1+ i) n)
               (memq (aref text (1+ i)) gdocs--org-inline-escape-chars))
          (push (aref text (1+ i)) out)
          (setq i (+ i 2)))
         (t
          (push char out)
          (cl-incf i)))))
    (apply #'string (nreverse out))))

(defun gdocs--unescape-org-table-markup (text)
  "Decode renderer-qualified table escapes in TEXT."
  (let ((i 0)
        (n (length (or text "")))
        (out nil)
        (text (or text ""))
        (pipe (concat "\\vert{}" gdocs--org-table-pipe-qualifier))
        (newline (concat "\\linebreak{}"
                         gdocs--org-table-newline-qualifier)))
    (while (< i n)
      (cond
       ((and (<= (+ i (length pipe)) n)
             (string= pipe (substring text i (+ i (length pipe)))))
        (push "|" out)
        (setq i (+ i (length pipe))))
       ((and (<= (+ i (length newline)) n)
             (string= newline (substring text i (+ i (length newline)))))
        (push "\n" out)
        (setq i (+ i (length newline))))
       ((and (< (1+ i) n)
             (= (aref text i)
                (string-to-char gdocs--org-table-escape-sentinel))
             (= (aref text (1+ i))
                (string-to-char gdocs--org-table-escape-sentinel)))
        (push gdocs--org-table-escape-sentinel out)
        (setq i (+ i 2)))
       ((and (<= (+ i (length gdocs--org-table-boundary-qualifier) 1) n)
             (string= gdocs--org-table-boundary-qualifier
                      (substring text i
                                 (+ i (length
                                       gdocs--org-table-boundary-qualifier))))
             (= (aref text (+ i (length
                                 gdocs--org-table-boundary-qualifier)))
                ?\s))
        (setq i (+ i (length gdocs--org-table-boundary-qualifier) 1)))
       ((or (and (<= (+ i (length gdocs--org-table-pipe-qualifier)) n)
                 (string= gdocs--org-table-pipe-qualifier
                          (substring text i
                                     (+ i (length
                                           gdocs--org-table-pipe-qualifier)))))
            (and (<= (+ i (length gdocs--org-table-newline-qualifier)) n)
                 (string= gdocs--org-table-newline-qualifier
                          (substring text i
                                     (+ i (length
                                           gdocs--org-table-newline-qualifier))))))
        (setq i (+ i 2)))
       (t
        (push (string (aref text i)) out)
        (cl-incf i))))
    (apply #'concat (nreverse out))))

(defun gdocs--org-element-visible-text (el inherited-link table-cell)
  "Return the source-visible text of inline element EL, or nil."
  (let* ((begin (org-element-property :begin el))
         (end (org-element-property :end el))
         (source (and (integerp begin)
                      (integerp end)
                      (<= (point-min) begin end (point-max))
                      (buffer-substring-no-properties begin end)))
         (source (or source
                     (condition-case nil
                         (org-element-interpret-data el)
                       (error nil)))))
    (when (and (stringp source) (not (string-empty-p source)))
      (gdocs--unescape-org-inline source inherited-link table-cell))))

(defun gdocs--org-element-escaped-p (el)
  "Return non-nil when EL is preceded by an odd number of backslashes."
  (let ((position (org-element-property :begin el))
        (count 0))
    (when (integerp position)
      (setq position (1- position))
      (while (and (>= position (point-min))
                  (= (char-after position) ?\\))
        (cl-incf count)
        (cl-decf position)))
    (cl-oddp count)))

(defun gdocs--org-table-escape-value (el)
  "Return the literal value of a renderer-generated table escape EL."
  (let ((end (org-element-property :end el)))
    (pcase (car el)
      ('entity
       (and (string= (plist-get (cadr el) :name) "vert")
            (integerp end)
            (<= (+ end (length gdocs--org-table-pipe-qualifier))
                (point-max))
            (string= (buffer-substring-no-properties
                      end (+ end (length gdocs--org-table-pipe-qualifier)))
                     gdocs--org-table-pipe-qualifier)
            "|"))
      ('latex-fragment
       (and (string= (plist-get (cadr el) :value) "\\linebreak{}")
            (integerp end)
            (<= (+ end (length gdocs--org-table-newline-qualifier))
                (point-max))
            (string= (buffer-substring-no-properties
                      end (+ end (length gdocs--org-table-newline-qualifier)))
                     gdocs--org-table-newline-qualifier)
            "\n")))))

(defun gdocs--element-runs
    (el &optional inherited-styles inherited-link table-cell visible-fallback)
  "Walk inline ORG-ELEMENT EL and return a flat list of runs.
INHERITED-STYLES and INHERITED-LINK are inherited from outer wrappers.
TABLE-CELL enables the table-only escapes for embedded newlines.
VISIBLE-FALLBACK preserves unsupported source as plain text."
  (cond
   ((stringp el)
    (if (string-empty-p el)
        nil
      (list (gdocs-dm-make-run
             (gdocs--unescape-org-inline
              el (and inherited-link t) table-cell)
             inherited-styles inherited-link))))
   ((null el) nil)
   ((consp el)
    (let* ((type (and (symbolp (car el)) (car el)))
           (props (and (consp (cdr el)) (cadr el)))
           (contents (cddr el))
           (style (cdr (assq type gdocs--org-element-styles))))
      (cond
       ((and (eq type 'export-snippet)
             (string= (downcase (format "%s"
                                        (or (plist-get props :backend)
                                            (plist-get props :back-end))))
                      "gdocs-inline-object"))
        (let ((object (and (not (gdocs--org-element-escaped-p el))
                           (gdocs--parse-inline-object-spec
                            (plist-get props :value)))))
          (cond
           (object
            ;; Org attaches the whitespace after the closing `@@' to the
            ;; snippet as `:post-blank'.  Like the link branch below, it
            ;; belongs to the surrounding text, so re-emit it as a run.
            (let ((runs (list (list :inline-object object)))
                  (post-blank (org-element-property :post-blank el)))
              (if (and (integerp post-blank) (> post-blank 0))
                  (append runs
                          (list (gdocs-dm-make-run
                                 (make-string post-blank ?\s)
                                 inherited-styles inherited-link)))
                runs)))
           ((gdocs--org-element-escaped-p el)
            (let ((text (gdocs--org-element-visible-text
                         el inherited-link table-cell)))
              (when text
                (list (gdocs-dm-make-run
                       text inherited-styles inherited-link)))))
           (t
            (let* ((text (and visible-fallback
                              (gdocs--org-element-visible-text
                               el inherited-link table-cell)))
                   (run (gdocs-dm-make-run
                         (or text "") inherited-styles inherited-link)))
              (list (plist-put run :inline-object-malformed t)))))))
       ((eq type 'link)
        (let ((chip (gdocs--chip-object-from-link el props)))
          (if chip
              ;; A remote chip rendered as an Org chip link becomes a
              ;; first-class object run again; Org attaches any trailing
              ;; whitespace to the link as `:post-blank', so re-emit it.
              (let ((runs (list (list :inline-object chip)))
                    (post-blank (org-element-property :post-blank el)))
                (if (and (integerp post-blank) (> post-blank 0))
                    (append runs
                            (list (gdocs-dm-make-run
                                   (make-string post-blank ?\s)
                                   inherited-styles inherited-link)))
                  runs))
            (let* ((path (plist-get props :path))
                   (kind (plist-get props :type))
                   (path (if table-cell
                             (gdocs--unescape-org-table-markup path)
                           path))
                   (url (if (member kind '("https" "http" "mailto" "ftp"))
                            (format "%s:%s" kind path)
                          path))
                   (runs (if contents
                             (cl-mapcan
                              (lambda (c)
                                (gdocs--element-runs c inherited-styles url
                                                     table-cell visible-fallback))
                              contents)
                           ;; Bare link with no description.
                           (list (gdocs-dm-make-run (or url path)
                                                    inherited-styles url))))
                   ;; Org attaches whitespace after a link to the link's
                   ;; `:post-blank' property.  It belongs to the surrounding
                   ;; style/link context, not to the link destination.
                   (post-blank (org-element-property :post-blank el)))
              (if (and (integerp post-blank) (> post-blank 0))
                  (append runs
                          (list (gdocs-dm-make-run
                                 (make-string post-blank ?\s)
                                 inherited-styles inherited-link)))
                runs)))))
       ((eq type 'plain-text)
        (when (stringp props)
          (list (gdocs-dm-make-run
                 (gdocs--unescape-org-inline
                  props (and inherited-link t) table-cell)
                 inherited-styles inherited-link))))
       ((eq type 'entity)
        (let* ((text (or (and table-cell
                              (gdocs--org-table-escape-value el))
                         (and visible-fallback
                              (gdocs--org-element-visible-text
                               el inherited-link table-cell))
                         ;; Ordinary prose keeps the entity's UTF-8
                         ;; replacement (or its ASCII form) instead of
                         ;; dropping it.
                         (plist-get props :utf-8)
                         (plist-get props :ascii)
                         (gdocs--org-element-visible-text
                          el inherited-link table-cell)))
               (runs (when (stringp text)
                       (list (gdocs-dm-make-run
                              text inherited-styles inherited-link))))
               (post-blank (org-element-property :post-blank el)))
          (if (and table-cell runs (not visible-fallback)
                   (integerp post-blank) (> post-blank 0))
              (append runs
                      (list (gdocs-dm-make-run
                             (make-string post-blank ?\s)
                             inherited-styles inherited-link)))
            runs)))
       ((eq type 'latex-fragment)
        (let* ((text (or (and table-cell
                              (gdocs--org-table-escape-value el))
                         (and visible-fallback
                              (gdocs--org-element-visible-text
                               el inherited-link table-cell))
                         (and table-cell (plist-get props :value))
                         ;; Ordinary prose keeps the raw LaTeX source as
                         ;; literal text instead of dropping it.
                         (gdocs--org-element-visible-text
                          el inherited-link table-cell)))
               (runs (when (stringp text)
                       (list (gdocs-dm-make-run
                              text
                              inherited-styles inherited-link))))
               (post-blank (org-element-property :post-blank el)))
          (if (and table-cell runs (not visible-fallback)
                   (integerp post-blank) (> post-blank 0))
              (append runs
                      (list (gdocs-dm-make-run
                             (make-string post-blank ?\s)
                             inherited-styles inherited-link)))
            runs)))
       (style
        (let* ((styles (cons style inherited-styles))
               (runs
                (if (and (memq type '(code verbatim))
                         (stringp (plist-get props :value)))
                    ;; Inline code/verbatim contents come as a single
                    ;; string in :value.
                    (list (gdocs-dm-make-run
                           (if table-cell
                               (gdocs--unescape-org-table-markup
                                (plist-get props :value))
                             (plist-get props :value))
                           styles inherited-link))
                  (cl-mapcan
                   (lambda (c)
                     (gdocs--element-runs c styles inherited-link table-cell
                                          visible-fallback))
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
       ;; Org anchors never appear in exported text, but a title or table
       ;; cell visible-fallback keeps the literal source.
       ((and (memq type '(target radio-target)) (not visible-fallback)) nil)
       (t
        (if (and contents (not (and table-cell visible-fallback)))
            (cl-mapcan
             (lambda (c)
               (gdocs--element-runs c inherited-styles inherited-link
                                    table-cell visible-fallback))
             contents)
          ;; Leaf objects (timestamps, footnote references, statistics
          ;; cookies, macros, …) keep their source-visible text rather
          ;; than disappearing from ordinary prose.
          (let ((text (gdocs--org-element-visible-text
                       el inherited-link table-cell)))
            (when text
              (list (gdocs-dm-make-run
                     text inherited-styles inherited-link)))))))))))

(defun gdocs--paragraph-content-runs (par &optional visible-fallback)
  "Return the runs of an org `paragraph' element PAR, trimming the
trailing newline that org-element keeps at the end of each paragraph.
VISIBLE-FALLBACK is passed to `gdocs--element-runs'."
  (let ((runs (cl-mapcan
               (lambda (c)
                 (gdocs--element-runs c nil nil nil visible-fallback))
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
    (seq-remove (lambda (r)
                  (and (not (plist-get r :inline-object))
                       (not (plist-get r :inline-object-malformed))
                       (string-empty-p (or (plist-get r :text) ""))))
                runs)))

(defun gdocs--org-inline-content-runs (text &optional visible-fallback)
  "Parse TEXT as inline Org content and return its doc-model runs.

TEXT is placed in a temporary paragraph before being parsed, so keyword
prefixes are never included in the returned runs.  A zero-width prefix keeps
TEXT that happens to start with Org block syntax (for example `* heading') in
that paragraph.  If VISIBLE-FALLBACK is non-nil, unsupported leaf elements
retain their source-visible text.  If Org cannot produce a paragraph, or
parsing fails, return TEXT as one unstyled run instead of silently dropping
visible content."
  (when (and (stringp text) (not (string-empty-p text)))
    (let ((fallback
           (list (gdocs-dm-make-run (substring-no-properties text))))
          ;; An ordinary character before an emphasis marker would prevent
          ;; Org from recognizing it.  U+200B is accepted as a boundary by
          ;; the emphasis parser and is removed from the first parsed run.
          (sentinel (string #x200b)))
      (condition-case nil
          (with-temp-buffer
            (let ((org-inhibit-startup t))
              (insert sentinel text "\n"))
            (org-mode)
            (let* ((tree (org-element-parse-buffer))
                   (section
                    (seq-find
                     (lambda (element)
                       (and (consp element) (eq (car element) 'section)))
                     (cddr tree)))
                   (paragraph
                    (and section
                         (seq-find
                          (lambda (element)
                            (and (consp element)
                                 (eq (car element) 'paragraph)))
                          (cddr section))))
                   (runs (and paragraph
                              (gdocs--paragraph-content-runs
                               paragraph visible-fallback)))
                   (first (car runs))
                   (first-text (and first (plist-get first :text))))
              (if (and (stringp first-text)
                       (string-prefix-p sentinel first-text))
                  (let ((trimmed (copy-sequence first)))
                    (plist-put trimmed :text
                               (substring-no-properties
                                first-text (length sentinel)))
                    (setq runs (cons trimmed (cdr runs)))
                    (or (seq-remove
                         (lambda (run)
                           (and (not (plist-get run :inline-object))
                                (not (plist-get run :inline-object-malformed))
                                (string-empty-p
                                 (or (plist-get run :text) ""))))
                         runs)
                        fallback))
                fallback)))
        (error fallback)))))

(defun gdocs--org-headline-runs (hl)
  "Return runs for a headline element HL by parsing its :raw-value."
  (gdocs--org-inline-content-runs (plist-get (cadr hl) :raw-value)))

(defun gdocs--org-item-paragraph (item)
  "Return ITEM's direct paragraph child, or nil."
  (seq-find (lambda (element)
              (and (consp element) (eq (car element) 'paragraph)))
            (cddr item)))

(defun gdocs--org-item-runs (item)
  "Return runs for a plain-list item ITEM."
  (let ((paragraph (gdocs--org-item-paragraph item)))
    (when paragraph (gdocs--paragraph-content-runs paragraph))))

(defun gdocs--item-glyph (item)
  "Return :bullet or :number based on the item's leading bullet text."
  (let ((bullet (plist-get (cadr item) :bullet)))
    (cond
     ((null bullet) :bullet)
     ((string-match-p "^[0-9]+[.)]" bullet) :number)
     (t :bullet))))

(defun gdocs--org-list-id (plain-list glyph ids)
  "Return PLAIN-LIST's stable parse-local ID for GLYPH from IDS."
  (or (gethash glyph ids)
      (let ((id (format "kix.l%s"
                        (substring
                         (md5 (format "%S-%S-%d" plain-list glyph (random)))
                         0 12))))
        (puthash glyph id ids)
        id)))

(defun gdocs--org-item-prefix-runs (item)
  "Return runs carrying ITEM's checkbox state and description tag.

Checkbox markers keep their literal `[X]' / `[ ]' / `[-]' text so the state
survives publication.  Description-list terms are rendered as `term :: '
prefix runs.  Both are disclosed fallbacks, not structural support."
  (let* ((props (cadr item))
         (checkbox (plist-get props :checkbox))
         (tag (plist-get props :tag))
         (runs nil))
    (when checkbox
      (let ((marker (pcase checkbox
                      ('on "[X] ") ('off "[ ] ") ('trans "[-] ")
                      ('intermediate "[-] ")
                      (_ nil))))
        (when marker
          (push (gdocs-dm-make-run marker) runs))))
    (when tag
      (let ((tag-runs (cl-mapcan
                       (lambda (obj) (gdocs--element-runs obj nil nil))
                       (if (consp (car tag)) tag (list tag)))))
        (setq runs (append runs tag-runs (list (gdocs-dm-make-run " :: "))))))
    (nreverse runs)))

(defun gdocs--walk-org-list (plain-list nest ids &optional source-spans)
  "Convert PLAIN-LIST recursively at logical NEST using glyph ID table IDS.

An item's first paragraph becomes the list paragraph; checkbox state and
description tags are prefixed literally.  Remaining children keep their
text as ordinary paragraphs marked with a disclosed fallback, and nested
plain lists recurse normally."
  (let (paragraphs)
    (dolist (item (cddr plain-list))
      (when (and (consp item) (eq (car item) 'item))
        (let* ((glyph (gdocs--item-glyph item))
               (paragraph (gdocs--org-item-paragraph item))
               (runs (append (gdocs--org-item-prefix-runs item)
                             (gdocs--org-item-runs item)))
               (model (list :kind :list
                            :glyph glyph
                            :nest nest
                            :list-id (gdocs--org-list-id plain-list glyph ids)
                            :runs runs)))
          (push (if source-spans
                    (gdocs--org-annotate-paragraph
                     model
                     (gdocs--org-element-line-number (or paragraph item))
                     (gdocs--org-element-last-line-number (or paragraph item)))
                  model)
                paragraphs)
          (let ((first-paragraph t))
            (dolist (child (cddr item))
              (when (consp child)
                (cond
                 ((eq (car child) 'plain-list)
                  (setq paragraphs
                        (nconc
                         (nreverse
                          (gdocs--walk-org-list child (1+ nest) ids
                                                source-spans))
                         paragraphs)))
                 ((and (eq (car child) 'paragraph) first-paragraph)
                  (setq first-paragraph nil))
                 (t
                  (setq first-paragraph nil)
                  ;; Any other block inside the item keeps its text as
                  ;; ordinary content with a disclosed fallback.
                  (let ((extras
                         (cl-mapcan
                          (lambda (grandchild)
                            (gdocs--walk-org-element grandchild
                                                     source-spans))
                          (list child))))
                    (when extras
                      (let ((first (car extras)))
                        (unless (plist-get first :lossy-fallback)
                          (setcar extras
                                  (plist-put (copy-sequence first)
                                             :lossy-fallback
                                             "list item continuation is rendered as ordinary content"))))
                      (setq paragraphs
                            (nconc (nreverse extras) paragraphs))))))))))))
    (nreverse paragraphs)))

(defun gdocs--coalesce-table-cell-runs (runs)
  "Coalesce adjacent table RUNS with identical style and link metadata.

Runs with different destinations or styles, and inline-object runs, are never
coalesced.  This only removes AST boundaries introduced by table-safe Org
entities and post-blank whitespace."
  (let (out)
    (dolist (run runs (nreverse out))
      (let ((previous (car out)))
        (if (and previous
                 (not (plist-get previous :inline-object))
                 (not (plist-get run :inline-object))
                 (not (plist-get previous :inline-object-malformed))
                 (not (plist-get run :inline-object-malformed))
                 (equal (plist-get previous :styles)
                        (plist-get run :styles))
                 (equal (plist-get previous :link)
                        (plist-get run :link)))
            (setcar out
                    (plist-put (copy-sequence previous) :text
                               (concat (or (plist-get previous :text) "")
                                       (or (plist-get run :text) ""))))
          (push run out))))))

(defun gdocs--trim-table-cell-runs (runs)
  "Trim table padding from the edge text runs in RUNS.

Only the first and last textual runs are changed.  Inline objects and all
style/link boundaries remain separate, and an all-whitespace cell becomes an
empty run list rather than disappearing from its row."
  (let* ((runs (mapcar (lambda (run)
                         (let ((copy (copy-sequence run))
                               (text (plist-get run :text)))
                           (when (stringp text)
                             (setq copy (plist-put
                                         copy :text
                                         (substring-no-properties text))))
                           copy))
                       runs))
         (first-index nil)
         (last-index nil)
         (index 0))
    (dolist (run runs)
      (when (stringp (plist-get run :text))
        (unless first-index (setq first-index index))
        (setq last-index index))
      (cl-incf index))
    (when first-index
      (let* ((first-run (nth first-index runs))
             (last-run (nth last-index runs))
             (first-text (string-trim-left (or (plist-get first-run :text)
                                               "")))
             (last-text (string-trim-right (or (plist-get last-run :text)
                                               ""))))
        (setcar (nthcdr first-index runs)
                (plist-put (copy-sequence first-run) :text first-text))
        (if (= first-index last-index)
            (setcar (nthcdr first-index runs)
                    (plist-put (copy-sequence first-run)
                               :text (string-trim (or (plist-get first-run
                                                                 :text)
                                                      ""))))
          (setcar (nthcdr last-index runs)
                  (plist-put (copy-sequence last-run) :text last-text)))))
    (gdocs--coalesce-table-cell-runs
     (seq-remove (lambda (run)
                   (and (not (plist-get run :inline-object))
                        (not (plist-get run :inline-object-malformed))
                        (string-empty-p (or (plist-get run :text) ""))))
                 runs))))

(defun gdocs--src-block-paragraphs (sb)
  "Split a src-block's :value into a list of :code paragraphs.

Each run carries the `:code' style so the OT emitter sends the matching
monospace font (Roboto Mono) and a pull decodes the paragraph back into a
`:code' paragraph.  The source language is not represented by the remote
model; a pull always renders `text' as the language."
  (let* ((val (or (plist-get (cadr sb) :value) ""))
         (lines (split-string val "\n"))
         ;; org-element appends a trailing \n; drop the trailing empty line.
         (lines (if (and lines (string-empty-p (car (last lines))))
                    (butlast lines)
                  lines)))
    ;; Keep an empty source block representable.  More importantly, an empty
    ;; line *inside* a non-empty block remains a :code paragraph and must not
    ;; be mistaken for a generic paragraph separator.
    (unless lines (setq lines (list "")))
    (mapcar (lambda (line)
              (list :kind :code
                    :runs (list (gdocs-dm-make-run line '(:code)))
                    :lossy-fallback
                    "source block is published as code text; its language is not preserved remotely"))
            lines)))

(defun gdocs--org-element-line-number (el)
  "Return the source line containing ORG-ELEMENT EL, or nil."
  (let ((begin (and el (org-element-property :begin el))))
    (and (integerp begin) (line-number-at-pos begin))))

(defun gdocs--org-element-last-line-number (el)
  "Return the last source line occupied by ORG-ELEMENT EL, or nil."
  (let ((begin (and el (org-element-property :begin el)))
        ;; Paragraph/list elements include their following blank lines in
        ;; :end.  :contents-end stops before that post-blank region.
        (end (and el (or (org-element-property :contents-end el)
                         (org-element-property :end el)))))
    (when (and (integerp begin) (integerp end))
      ;; Element :end is conventionally one past its final character.  Step
      ;; back so a trailing newline is attributed to the element rather than
      ;; to an empty line following it.
      (line-number-at-pos (max begin (1- end))))))

(defun gdocs--org-annotate-paragraph (paragraph start-line
                                                &optional end-line group)
  "Attach transient source-span metadata to PARAGRAPH.

The metadata is used only to recover meaningful blank paragraphs from Org
source text.  It is removed before `gdocs-dm-from-org' returns its model."
  (let ((copy (copy-sequence paragraph)))
    (setq copy (plist-put copy :gdocs-source-start-line start-line))
    (setq copy (plist-put copy :gdocs-source-end-line (or end-line start-line)))
    (when group
      (setq copy (plist-put copy :gdocs-source-group group)))
    copy))

(defun gdocs--org-heading-kind-p (paragraph)
  "Return non-nil when PARAGRAPH is a heading-like keyword entry."
  (gdocs--heading-kind-p (plist-get paragraph :kind)))

(defun gdocs--org-with-meaningful-blanks (paragraphs)
  "Insert meaningful source blank paragraphs into PARAGRAPHS.

Org-element treats ordinary blank lines as formatting (`:post-blank') rather
than elements.  The doc-model needs one explicit blank paragraph when that
line separates ordinary content, otherwise rendering a pulled document with
such a paragraph would not be idempotent.  Blank lines adjacent to headings,
Title, or Subtitle entries are synthetic Org padding and are deliberately
discarded.  Source-block spans are treated as one protected region so empty
source lines remain :code paragraphs instead."
  (let ((out nil)
        (previous nil))
    (dolist (paragraph paragraphs)
      (let* ((current-start (plist-get paragraph :gdocs-source-start-line))
             (previous-end (and previous
                                (plist-get previous :gdocs-source-end-line)))
             (current-group (plist-get paragraph :gdocs-source-group))
             (previous-group (and previous
                                  (plist-get previous :gdocs-source-group)))
             (blank-gap (and current-start previous-end
                             (> (- current-start previous-end) 1))))
        (when (and previous blank-gap
                   (not (and current-group previous-group
                             (eq current-group previous-group)))
                   (not (gdocs--org-heading-kind-p previous))
                   (not (gdocs--org-heading-kind-p paragraph)))
          (push (list :kind :blank :runs nil) out))
        (push paragraph out)
        (setq previous paragraph)))
    ;; Remove the transient span keys without changing any user-visible model
    ;; fields.  `plist-put' with nil would leave the keys present, so rebuild
    ;; each plist explicitly.
    (mapcar
     (lambda (paragraph)
       (let (clean)
         (cl-loop for (key value) on paragraph by #'cddr
                  unless (memq key '(:gdocs-source-start-line
                                     :gdocs-source-end-line
                                     :gdocs-source-group))
                  do (setq clean (append clean (list key value))))
         clean))
     (nreverse out))))

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
                (let ((runs
                       (gdocs--trim-table-cell-runs
                        (cl-mapcan
                         (lambda (content)
                           (gdocs--element-runs content nil nil t t))
                         (cddr sub)))))
                  (push (list runs) cells))))
            (let ((row (nreverse cells)))
              (setq max-cols (max max-cols (length row)))
              (push row rows))))))
    (list :kind :table
          :rows (nreverse rows)
          :cols max-cols)))

(defun gdocs--walk-children-with-lossy (el source-spans reason)
  "Walk EL's children as ordinary content, marking the first paragraph.

REASON explains the disclosed structural loss and is attached as
`:lossy-fallback' to the first produced paragraph so publication previews
can enumerate it.  Children that produce no paragraphs yield no entry."
  (let ((children (cl-mapcan
                   (lambda (child)
                     (gdocs--walk-org-element child source-spans))
                   (cddr el))))
    (when children
      (let ((first (car children)))
        (unless (plist-get first :lossy-fallback)
          (setcar children (plist-put (copy-sequence first)
                                      :lossy-fallback reason)))))
    children))

(defun gdocs--walk-org-element (el &optional source-spans)
  "Convert a top-level org-element EL into zero or more paragraphs.

When SOURCE-SPANS is non-nil, attach transient source line metadata so the
caller can distinguish meaningful blank lines from heading padding.

Every element type receives an explicit treatment.  Blocks the remote model
cannot represent structurally (quotes, verse, centers, special, example,
drawers, footnote definitions, horizontal rules) keep their text and are
marked with a `:lossy-fallback' explanation; purely organizational
metadata (planning lines, clocks, diary sexps, unknown keywords, targets)
is intentionally excluded.  Nothing silently disappears."
  (pcase (and (consp el) (car el))
    ('headline
     (let* ((props (cadr el))
            (level (plist-get props :level))
            (runs (gdocs--org-headline-runs el))
            (kind :heading)
            (para (list :kind kind :level level :runs runs))
            (para (if source-spans
                      (gdocs--org-annotate-paragraph
                       para (gdocs--org-element-line-number el))
                    para)))
       (cons para
             (cl-mapcan
              (lambda (child)
                (gdocs--walk-org-element child source-spans))
              (cddr el)))))
    ('section
     (cl-mapcan
      (lambda (child)
        (gdocs--walk-org-element child source-spans))
      (cddr el)))
    ('paragraph
     (let ((runs (gdocs--paragraph-content-runs el)))
       (let ((para (if runs
                       (list :kind :para :runs runs)
                     (list :kind :blank :runs nil))))
         (list (if source-spans
                   (gdocs--org-annotate-paragraph
                    para (gdocs--org-element-line-number el)
                    (gdocs--org-element-last-line-number el))
                 para)))))
    ('plain-list
     (let ((ids (make-hash-table :test #'eq)))
       (gdocs--walk-org-list el 0 ids source-spans)))
    ('src-block
     (let* ((start (gdocs--org-element-line-number el))
            (paragraphs (gdocs--src-block-paragraphs el))
            ;; The source block's closing line is occupied even though it is
            ;; not emitted as a doc-model paragraph.  Use it when deciding
            ;; whether the following entry has a real blank gap.
            (end (+ (or start 0) 1 (length paragraphs))))
       (if source-spans
           (mapcar (lambda (paragraph)
                     (gdocs--org-annotate-paragraph paragraph start end el))
                   paragraphs)
         paragraphs)))
    ('table
     (let ((para (gdocs--org-table-paragraph el)))
       (list (if source-spans
                 (gdocs--org-annotate-paragraph
                  para (gdocs--org-element-line-number el)
                  (gdocs--org-element-last-line-number el))
               para))))
    ('keyword
     (let* ((props (cadr el))
            (key (and (stringp (plist-get props :key))
                      (downcase (plist-get props :key))))
            (val (plist-get props :value)))
       (cond
        ((member key '("title" "subtitle"))
         (let ((para (list :kind (if (equal key "title") :title :subtitle)
                           :runs (gdocs--org-inline-content-runs val t))))
           (list (if source-spans
                     (gdocs--org-annotate-paragraph
                      para (gdocs--org-element-line-number el)
                      (gdocs--org-element-last-line-number el))
                   para))))
        ((equal key "gdocs_inline_object")
         (let* ((object (gdocs--parse-inline-object-spec val))
                (para (or object
                          (list :kind :unsupported
                                :runs nil
                                :inline-object-malformed t
                                :unsupported-reason
                                "malformed gdocs_inline_object placeholder"))))
           (list (if source-spans
                     (gdocs--org-annotate-paragraph
                      para (gdocs--org-element-line-number el)
                      (gdocs--org-element-last-line-number el))
                   para))))
        ((equal key "gdocs_unsupported")
         (list (list :kind :unsupported
                     :runs nil
                     :unsupported-reason
                     "The local document contains an unsupported-content marker.")))
        (t nil))))
    ;; Greater blocks and drawers the remote model cannot represent keep all
    ;; of their text as ordinary content, marked with a disclosed fallback.
    ((or 'quote-block 'verse-block 'center-block 'example-block
         'special-block 'dynamic-block)
     (gdocs--walk-children-with-lossy
      el source-spans
      (format "%s block is rendered as ordinary paragraphs"
              (replace-regexp-in-string "-block$" "" (symbol-name (car el))))))
    ('drawer
     (gdocs--walk-children-with-lossy
      el source-spans "drawer contents are rendered as ordinary paragraphs"))
    ('footnote-definition
     (let* ((label (or (plist-get (cadr el) :label) "fn"))
            (children (cl-mapcan
                       (lambda (child)
                         (gdocs--walk-org-element child source-spans))
                       (cddr el))))
       (when children
         (let ((first (car children)))
           ;; Keep the marker visible so the note survives publication.
           (setcar children
                   (plist-put (copy-sequence first)
                              :runs (append
                                     (list (gdocs-dm-make-run
                                            (format "[fn:%s] " label)))
                                     (plist-get first :runs))))
           (unless (plist-get (car children) :lossy-fallback)
             (setcar children
                     (plist-put (car children)
                                :lossy-fallback
                                (format "footnote [%s] is rendered as inline text because the remote model has no footnotes"
                                        label))))))
       children))
    ('horizontal-rule
     (let ((para (list :kind :para
                       :runs (list (gdocs-dm-make-run
                                    (make-string 40 ?-)))
                       :lossy-fallback
                       "horizontal rule is rendered as a dashed line")))
       (list (if source-spans
                 (gdocs--org-annotate-paragraph
                  para (gdocs--org-element-line-number el))
               para))))
    ;; Organizational metadata that ordinary Org export also excludes.
    ((or 'planning 'clock 'diary-sexp) nil)
    ;; Drawers and comments carry metadata or editor notes, not content.
    ((or 'property-drawer 'node-property 'comment 'comment-block
         'export-block) nil)
    ('fixed-width
     (let* ((value (string-join
                    (split-string (or (plist-get (cadr el) :value) "")
                                  "\n") "\n"))
            (para (list :kind :para
                        :runs (list (gdocs-dm-make-run value))
                        :lossy-fallback
                        "fixed-width line is rendered as an ordinary paragraph")))
       (list (if source-spans
                 (gdocs--org-annotate-paragraph
                  para (gdocs--org-element-line-number el))
               para))))
    ;; Fallback for any remaining block element with children: keep the
    ;; content, disclose the structural loss.  Childless elements are
    ;; literalized from their source text.
    (_
     (if (cddr el)
         (gdocs--walk-children-with-lossy
          el source-spans
          (format "%s is not represented structurally and keeps its text"
                  (car el)))
       (let ((text (gdocs--org-element-visible-text el nil nil)))
         (when (and text (not (string-empty-p text)))
           (list (list :kind :para
                       :runs (list (gdocs-dm-make-run text))
                       :lossy-fallback
                       (format "%s is rendered as literal text"
                               (car el))))))))))

(defun gdocs-dm-from-org (org-text)
  "Parse ORG-TEXT (a string) into a canonical doc-model.

Drops the property drawer if present.  One source blank between ordinary
entries is retained so a canonical rendered model is byte-stable when parsed
and rendered again.  Blank lines used solely as padding around headings,
Title, or Subtitle keywords are discarded; repeated empty paragraphs remain
intentionally lossy.  Inverse of `gdocs-dm-to-org' (lossy for unsupported
syntax)."
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
           (with-spans
            (cl-mapcan
             (lambda (el) (gdocs--walk-org-element el t))
             (cddr tree)))
           (paras (gdocs--org-with-meaningful-blanks with-spans))
           (lossy (delq nil
                        (cl-loop for paragraph in paras
                                 collect (plist-get paragraph
                                                    :lossy-fallback)))))
      (gdocs-dm-make-doc
       :revision nil :doc-id nil :title nil
       :paragraphs paras
       :lossy (delete-dups lossy)
       :inline-objects
       (cl-loop for paragraph in paras
                append (cond
                        ((eq (plist-get paragraph :kind) :inline-object)
                         (list paragraph))
                        ((eq (plist-get paragraph :kind) :table)
                         (gdocs--doc-table-inline-objects paragraph))
                        (t
                         (cl-loop for run in (plist-get paragraph :runs)
                                  when (plist-get run :inline-object)
                                  collect (plist-get run :inline-object)))))
       :unsupported
       (cl-loop for paragraph in paras
                when (eq (plist-get paragraph :kind) :unsupported)
                collect (gdocs--capability-report
                         :local-unsupported
                         (or (plist-get paragraph :unsupported-reason)
                             "The local document contains unsupported Org content.")
                         :source :local :render-directive t))))))

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

(defun gdocs--emit-list-style-op (list-id nest pos)
  "Emit one `as st=list' binding op at OT position POS (1-based, the
paragraph-terminator newline) for LIST-ID at zero-based NEST.  Sanitized OT
fixtures confirm `ls_nest' on the binding; the list definition supplies the
matching per-level indentation and glyph data."
  (unless (and (integerp nest) (<= 0 nest) (<= nest 8))
    (user-error "gdocs: list nesting level %S is outside the supported range 0..8"
                nest))
  `((ty . "as") (st . "list") (si . ,pos) (ei . ,pos)
    (sm . ((ls_ts . ,(gdocs--ts-block-canonical))
           (ls_id . ,list-id)
           (ls_nest . ,nest)))))

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
          (let* ((runs (gdocs--table-cell-runs cell))
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
36pt per level (18pt first-line offset), `b_a'=0, and `b_sn'=1. For
level N, bullets emit `b_gt'=9, `b_gs' cycling ●/○/■, and `b_gf'=%N;
numbers emit `b_gt'=13, an empty `b_gs', and `b_gf'=%N.  `b_ifl' is
18+36N and `b_il' is 36+36N. For LISTS, each entry is \(LIST-ID . GLYPH),
where GLYPH is :bullet or :number.

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
  (when (gdocs--doc-has-inline-object-p doc)
    (user-error
     "gdocs: remote object placeholders (inline images and chips) are remote-only; their OT creation operations are not supported"))
  (when (gdocs-dm-unsupported doc)
    (user-error "gdocs: document contains unsupported content: %s"
                (or (plist-get (gdocs--capability-normalize
                                (car (gdocs-dm-unsupported doc)))
                               :explanation)
                    "unsupported content")))
  (gdocs--emit-paragraphs-ot
   (gdocs--normalize-paragraphs-for-ot (gdocs-dm-paragraphs doc))))

(defun gdocs--emit-paragraphs-ot (paragraphs)
  "Render PARAGRAPHS (already canonicalized) to (BODY . OPS).

No paragraph normalization happens here: callers such as the incremental
planner depend on the emitted positions matching the exact paragraph
sequence supplied, including blank paragraphs the generic normalization
would drop."
  (let* ((paragraphs paragraphs)
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
  "Return non-nil when runs R1 and R2 have equal visible content.

Text, styles, links, and stable inline-object identity participate in the
comparison; decoder-only inline-object metadata does not."
  (let ((o1 (plist-get r1 :inline-object))
        (o2 (plist-get r2 :inline-object)))
    (if (or o1 o2)
        (let ((identity1 (and o1 (gdocs--inline-object-identity o1)))
              (identity2 (and o2 (gdocs--inline-object-identity o2))))
          (and identity1 identity2 (equal identity1 identity2)))
      (and (equal (plist-get r1 :text) (plist-get r2 :text))
           (equal (sort (copy-sequence (plist-get r1 :styles))
                        :lessp #'string<)
                  (sort (copy-sequence (plist-get r2 :styles))
                        :lessp #'string<))
           (equal (plist-get r1 :link) (plist-get r2 :link))))))

(defun gdocs--table-run-valid-for-equality-p (run)
  "Return non-nil when RUN has a well-formed equality representation."
  (and (proper-list-p run)
       (let ((object (plist-get run :inline-object))
             (text-present (plist-member run :text))
             (styles (plist-get run :styles))
             (link (plist-get run :link)))
         (if object
             (and (proper-list-p object)
                  (not text-present)
                  (null styles)
                  (null link)
                  (eq (plist-get object :kind) :inline-object)
                  (stringp (plist-get object :entity-id))
                  (symbolp (plist-get object :object-kind))
                  (cond
                   ((eq (plist-get object :object-kind) :image)
                    (and (stringp (plist-get object :content-id))
                         (numberp (plist-get object :width))
                         (numberp (plist-get object :height))))
                   ((memq (plist-get object :object-kind)
                          '(:chip-date :chip-person))
                    (gdocs--valid-chip-label-p
                     (plist-get object :chip-value)))
                   (t nil)))
           (and text-present
                (stringp (plist-get run :text))
                (or (null styles)
                    (and (proper-list-p styles)
                         (cl-every #'symbolp styles)))
                (or (null link) (stringp link)))))))

(defun gdocs--table-cell-runs-for-equality (cell)
  "Return CELL's canonical run list, or `:invalid-table-cell'.

Both the current one-element wrapper and the legacy direct run-list shape are
accepted.  Other shapes are rejected rather than flattened ambiguously."
  (cond
   ((null cell) nil)
   ((not (proper-list-p cell)) :invalid-table-cell)
   ((and (= (length cell) 1)
         (proper-list-p (car cell))
         (cl-every #'gdocs--table-run-valid-for-equality-p (car cell)))
    (car cell))
   ((cl-every #'gdocs--table-run-valid-for-equality-p cell) cell)
   (t :invalid-table-cell)))

(defun gdocs--table-for-equality (table)
  "Return TABLE's canonical visible shape, or nil if it is inconsistent.

The result contains rows, cells, and ordered runs only.  Transient table IDs
and decoder metadata are excluded.  Rows must agree on their cell count, and
an explicit `:cols' value must agree with that shape."
  (let ((rows (plist-get table :rows))
        (declared-cols (plist-get table :cols))
        canonical expected-cols valid)
    (setq valid (and (proper-list-p rows) rows))
    (dolist (row rows)
      (if (not (and valid (proper-list-p row) row))
          (setq valid nil)
        (let ((cols (length row))
              canonical-row)
          (if (and expected-cols (/= expected-cols cols))
              (setq valid nil)
            (setq expected-cols cols)
            (dolist (cell row)
              (let ((runs (gdocs--table-cell-runs-for-equality cell)))
                (if (eq runs :invalid-table-cell)
                    (setq valid nil)
                  (push runs canonical-row))))
            (push (nreverse canonical-row) canonical)))))
    (when (and valid
               (or (null declared-cols)
                   (and (integerp declared-cols)
                        (> declared-cols 0)
                        (= declared-cols expected-cols))))
      (nreverse canonical))))

(defun gdocs--table-equal-p (table1 table2)
  "Return non-nil when TABLE1 and TABLE2 have equal canonical table content."
  (let ((canonical1 (gdocs--table-for-equality table1))
        (canonical2 (gdocs--table-for-equality table2)))
    (and canonical1 canonical2
         (= (length canonical1) (length canonical2))
         (cl-every
          (lambda (row1 row2)
            (and (= (length row1) (length row2))
                 (cl-every
                  (lambda (cell1 cell2)
                    (and (= (length cell1) (length cell2))
                         (cl-every #'gdocs--run-text-equal-p cell1 cell2)))
                  row1 row2)))
          canonical1 canonical2))))

(defun gdocs--paragraph-inline-object-for-equality (paragraph)
  "Return the standalone inline object represented by PARAGRAPH.

Remote decoding stores a standalone object both in paragraph fields and as a
single `:inline-object' run.  Org parsing stores it only in paragraph fields.
Normalize those shapes to the run object, rejecting an inconsistent duplicate
instead of allowing one representation to hide changed metadata."
  (when (eq (plist-get paragraph :kind) :inline-object)
    (let* ((runs (plist-get paragraph :runs))
           (run-object (and (= (length runs) 1)
                            (plist-get (car runs) :inline-object)))
           (paragraph-object (and (plist-member paragraph :entity-id)
                                  paragraph)))
      (cond
       ((and run-object paragraph-object)
        (if (equal (gdocs--inline-object-identity run-object)
                   (gdocs--inline-object-identity paragraph-object))
            run-object
          :invalid-inline-object))
       (run-object run-object)
       (paragraph-object paragraph-object)
       (t :invalid-inline-object)))))

(defun gdocs--paragraph-runs-for-equality (paragraph)
  "Return non-table PARAGRAPH runs in the canonical shape used for equality."
  (if (eq (plist-get paragraph :kind) :inline-object)
      (list (list :inline-object
                  (gdocs--paragraph-inline-object-for-equality paragraph)))
    (plist-get paragraph :runs)))

(defun gdocs--paragraph-equal-p (p1 p2)
  "Return non-nil if P1 and P2 are equivalent at the user-visible level.
Compares kind, runs, heading level, list nest/glyph, canonical inline-object
identity, and canonical table structure and cell runs.  Transient table and
list IDs are ignored because they differ between live-decoded and freshly
rendered docs.  Malformed tables are never equal."
  (let* ((kind (plist-get p1 :kind))
         (object1 (and (eq kind :inline-object)
                       (gdocs--paragraph-inline-object-for-equality p1)))
         (object2 (and (eq kind :inline-object)
                       (gdocs--paragraph-inline-object-for-equality p2))))
    (and (not (eq object1 :invalid-inline-object))
         (not (eq object2 :invalid-inline-object))
         (eq kind (plist-get p2 :kind))
         ;; A missing heading level renders exactly like level 1, so it should
         ;; not turn a spacing-only/render-normalization pass into an OT edit.
         (equal (if (eq kind :heading)
                    (or (plist-get p1 :level) 1)
                  (plist-get p1 :level))
                (if (eq kind :heading)
                    (or (plist-get p2 :level) 1)
                  (plist-get p2 :level)))
         (equal (plist-get p1 :nest) (plist-get p2 :nest))
         (equal (plist-get p1 :glyph) (plist-get p2 :glyph))
         (if (eq kind :table)
             (gdocs--table-equal-p p1 p2)
           (let ((r1 (gdocs--paragraph-runs-for-equality p1))
                 (r2 (gdocs--paragraph-runs-for-equality p2)))
             (and (= (length r1) (length r2))
                  (cl-every #'gdocs--run-text-equal-p r1 r2)))))))

(defun gdocs--paragraphs-common-prefix (a b)
  (let ((n 0))
    (while (and a b (gdocs--paragraph-equal-p (car a) (car b)))
      (cl-incf n) (setq a (cdr a) b (cdr b)))
    n))

(defun gdocs--paragraphs-common-suffix (a b)
  (gdocs--paragraphs-common-prefix (reverse a) (reverse b)))

(defun gdocs--paragraphs-ot-length (paras)
  (if (null paras) 0
    (let ((sanitized
           (mapcar
            (lambda (paragraph)
              (let ((copy (copy-tree paragraph)))
                (if (eq (plist-get copy :kind) :inline-object)
                    (list :kind :para :runs (list (gdocs-dm-make-run "*")))
                  (cl-labels
                      ((sanitize-runs
                         (runs)
                         (mapcar
                          (lambda (run)
                            (if (plist-get run :inline-object)
                                (gdocs-dm-make-run "*")
                              run))
                          runs)))
                    (if (eq (plist-get copy :kind) :table)
                        (setq copy
                              (plist-put
                               copy :rows
                               (mapcar
                                (lambda (row)
                                  (mapcar
                                   (lambda (cell)
                                     (mapcar #'sanitize-runs cell))
                                   row))
                                (plist-get copy :rows))))
                      (setq copy
                            (plist-put copy :runs
                                       (sanitize-runs
                                        (plist-get copy :runs))))))
                  copy)))
            paras)))
      (length (car (gdocs--emit-paragraphs-ot sanitized))))))

(defun gdocs--shift-op-positions (op shift)
  (mapcar (lambda (kv)
            (pcase (car kv)
              ((or 'si 'ei 'ibi) (cons (car kv) (+ (cdr kv) shift)))
              (_ kv)))
          op))

(defun gdocs--raw-indices-for-norm (raw norm)
  "Return, for each paragraph in NORM, its index in RAW.

`gdocs--normalize-paragraphs-for-ot' drops or merges raw paragraphs but
never reorders them, so every normalized paragraph either is one of the
raw paragraph objects (matched with `eq') or — for a blank converted to
an empty source line — has the same OT length as the raw paragraph it
replaced.  Unmatched entries reuse the previous matched index."
  (let ((indices nil)
        (previous 0))
    (dolist (para norm)
      (let ((index (cl-position para raw :test #'eq)))
        (if index
            (setq previous index)
          (setq index previous))
        (push index indices)))
    (nreverse indices)))

(defun gdocs-dm-to-incremental-save-plan (old-doc new-doc &optional classify-only)
  "Compute a paragraph-level save plan from OLD-DOC to NEW-DOC.

The paragraph diff runs on the canonicalized
(`gdocs--normalize-paragraphs-for-ot') sequences of both documents so
spacing-only differences around headings do not create diff noise.  All
OT offsets, however, are computed from the RAW old-document paragraphs
— exactly as decoded from the remote operations — because `ds'/`is'
positions address the raw body.  Normalizing the position source would
silently shorten heading-adjacent blank paragraphs and corrupt the
edited range.

Falls back to a full-replace bundle if the diff region includes any
list, table, or inline-object paragraphs — those carry structure or
entity data whose live values we cannot safely rewrite in place.

The returned plist contains `:commands', an explicit `:kind', and the OT
`:ranges' touched by an incremental plan.  When CLASSIFY-ONLY is non-nil, a
fallback plan omits commands that would re-encode unsupported local entities."
  (let* ((old-raw (gdocs-dm-paragraphs old-doc))
         (new-raw (gdocs-dm-paragraphs new-doc))
         (old-norm (gdocs--normalize-paragraphs-for-ot old-raw))
         (new-norm (gdocs--normalize-paragraphs-for-ot new-raw))
         (old-raw-len (gdocs--paragraphs-ot-length old-raw))
         ;; The OT length the remote body actually has.  It is one short of
         ;; OLD-RAW-LEN when the last paragraph's newline is the one Google
         ;; keeps outside the body; see the doc-model schema.
         (old-ot-len (or (plist-get old-doc :ot-length) old-raw-len))
         (unterminated (and old-raw (= old-ot-len (1- old-raw-len))))
         (old-map (gdocs--raw-indices-for-norm old-raw old-norm))
         (pre (gdocs--paragraphs-common-prefix old-norm new-norm))
         (suf (gdocs--paragraphs-common-suffix
               (nthcdr pre old-norm) (nthcdr pre new-norm)))
         (pre (if (and unterminated
                       (> pre 0)
                       (= suf 0)
                       (= pre (length old-norm))
                       (< pre (length new-norm))
                       (= (nth (1- pre) old-map) (1- (length old-raw))))
                  ;; Appending after an unterminated last paragraph: no
                  ;; insertion point lies past its text, so rewrite that
                  ;; paragraph together with what follows it.
                  (1- pre)
                pre))
         (old-mid (cl-subseq old-norm pre
                             (- (length old-norm) suf)))
         (new-mid (cl-subseq new-norm pre
                             (- (length new-norm) suf))))
    (cond
     ((and (null old-mid) (null new-mid))
      '(:commands nil :kind :noop :ranges nil))
     ((cl-some (lambda (p)
                 (or (memq (plist-get p :kind)
                           '(:list :table :inline-object))
                     (cl-some (lambda (run)
                                (plist-get run :inline-object))
                              (plist-get p :runs))))
               (append old-mid new-mid))
      (list :commands
            (and (not classify-only)
                 (gdocs-dm-to-save-commands old-ot-len new-doc))
            :kind :full-replace
            :ranges nil))
     (t
      (let* (;; Raw span covering the common prefix: through the raw
             ;; paragraph that produced the last normalized prefix entry.
             (prefix-last-raw (and (> pre 0)
                                   (nth (1- pre) old-map)))
             (raw-prefix-len (if prefix-last-raw
                                 (gdocs--paragraphs-ot-length
                                  (cl-subseq old-raw 0 (1+ prefix-last-raw)))
                               0))
             ;; Raw span of the replaced middle: from the prefix end to the
             ;; raw paragraph that produced the first normalized suffix
             ;; entry.  Raw paragraphs dropped by normalization inside that
             ;; span are deleted, which is the intended canonicalization.
             (suffix-first-raw (and (> suf 0)
                                    (nth (- (length old-norm) suf) old-map)))
             (raw-mid-len (cond
                           (suffix-first-raw
                            (- (gdocs--paragraphs-ot-length
                                (cl-subseq old-raw 0 suffix-first-raw))
                               raw-prefix-len))
                           ;; No common suffix: the middle extends to the
                           ;; end of the raw body, including trailing
                           ;; normalized-away paragraphs, but not past the
                           ;; body text: the newline Google keeps after an
                           ;; unterminated last paragraph cannot be deleted.
                           (t
                            (- old-ot-len raw-prefix-len))))
             ;; NEW-MID is a slice of the already canonical NEW-NORM.
             ;; Emit it as is: normalizing the slice on its own would drop
             ;; a blank paragraph at its edges, which is only an edge of
             ;; the slice, not of the document.
             (built (gdocs--emit-paragraphs-ot new-mid))
             (mid-body (car built))
             (mid-style-ops (cdr built))
             (shifted-ops
              (mapcar (lambda (op)
                        (gdocs--shift-op-positions op raw-prefix-len))
                      mid-style-ops))
             (cmds nil))
        (when (> raw-mid-len 0)
          (push `((ty . "ds") (si . ,(1+ raw-prefix-len))
                  (ei . ,(+ raw-prefix-len raw-mid-len)))
                cmds))
        (when (length> mid-body 0)
          (push `((ty . "is") (ibi . ,(1+ raw-prefix-len))
                  (s . ,mid-body))
                cmds))
        (list :commands (append (nreverse cmds) shifted-ops)
              :kind :incremental
              :ranges
              (list (list :ot-start (1+ raw-prefix-len)
                          :ot-end (if (> raw-mid-len 0)
                                      (+ raw-prefix-len raw-mid-len)
                                    (1+ raw-prefix-len))
                          :insert-at (1+ raw-prefix-len)
                          :delete-count raw-mid-len))))))))

(defun gdocs-dm-to-incremental-save-commands (old-doc new-doc)
  "Return OT commands for the paragraph-level diff from OLD-DOC to NEW-DOC.

Use `gdocs-dm-to-incremental-save-plan' when the fallback classification and
touched OT ranges are needed for capability preflight."
  (plist-get (gdocs-dm-to-incremental-save-plan old-doc new-doc) :commands))

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

(defun gdocs--render-tab-tree (tabs revision doc-id &optional comments)
  "Render TABS as Org content and return (CONTENT . CAPABILITY-REPORTS)."
  (let (parts reports)
    (dolist (tab tabs)
      (let* ((depth (length (plist-get tab :path)))
             (model (gdocs-dm-from-ops
                     revision doc-id (plist-get tab :title)
                     (plist-get tab :ot-body) (plist-get tab :ops)))
             (model
              (plist-put
               model :paragraphs
               (mapcar
                (lambda (para)
                  (let ((para (copy-sequence para)))
                    (pcase (plist-get para :kind)
                      (:heading
                       (plist-put para :level
                                  (+ depth (plist-get para :level))))
                      ((or :title :subtitle) (plist-put para :kind :para))
                      (_ para))))
                (gdocs-dm-paragraphs model))))
             (content (gdocs-dm-to-org model))
             (anchors (gdocs--decode-doco-anchors (plist-get tab :ops)))
             (tab-comments (seq-filter
                            (lambda (comment)
                              (assoc (plist-get (cdr comment) :anchor) anchors))
                            comments))
             (content (if tab-comments
                          (gdocs--inline-comment-refs
                           content (plist-get tab :ot-body) anchors tab-comments)
                        content))
             (icon (plist-get tab :icon)))
        (setq reports (nconc reports (gdocs-dm-unsupported model)))
        (push (concat (make-string depth ?*) " "
                      (if icon (concat icon " ") "")
                      (plist-get tab :title) "\n"
                      ":PROPERTIES:\n:GDOC_TAB: " (plist-get tab :id) "\n"
                      (if icon (concat ":GDOC_TAB_ICON: " icon "\n") "")
                      ":END:\n"
                      content) parts)))
    (cons (string-join (nreverse parts) "\n") reports)))

(defun gdocs--tabbed-comment-refs (body tabs comments)
  "Insert COMMENTS in their tab-local content inside BODY."
  (if (null comments) body
    (let* ((plain (car (gdocs--render-tab-tree tabs nil nil)))
           (annotated (car (gdocs--render-tab-tree tabs nil nil comments)))
           (start (string-match (regexp-quote plain) body)))
      (unless start (error "gdocs: tab content changed before comment placement"))
      (concat (substring body 0 start) annotated
              (substring body (+ start (length plain)))))))

(defun gdocs--ot-decode-pipeline (doc-id html state &optional creation-time-ms)
  "Pure transform: decode an OT-backed HTML + STATE into (TITLE . BODY).
Returns (TITLE . BODY) — BODY includes the properties drawer,
and (when CREATION-TIME-MS is non-nil) a `#+date:' line, ready for
`gdocs--apply-pull-into-buffer'. Multi-tab bodies have one document-level
`#+title:' from the Drive name; tabs are headings and body Title/Subtitle
paragraphs inside them are plain text. Single-tab documents retain their
existing Title/Subtitle behavior."
  (let* ((parsed (gdocs--parse-model-chunk-full html))
         (ops (or (plist-get state :ot-ops)
                  (plist-get parsed :ops)))
         (revision (or (plist-get state :revision)
                       (plist-get parsed :revision)))
         (ot-body (plist-get state :ot-body))
         (edit-title (plist-get state :title))
         (tabs (plist-get state :tabs))
         (doc (unless tabs (gdocs-dm-from-ops revision doc-id edit-title
                                              (or ot-body "") ops)))
         (rendered-tabs (and tabs (gdocs--render-tab-tree tabs revision doc-id)))
         (org-content (if tabs (car rendered-tabs) (gdocs-dm-to-org doc)))
         (date-str (gdocs--format-creation-date creation-time-ms))
         (header
          ;; Metadata keywords precede the tab outline, not a tab body.
          (concat
           (when date-str "\n")
           (when tabs (format "#+title: %s\n" (or edit-title doc-id)))
           (when date-str (format "#+date: %s\n" date-str))
           "\n"))
         (titled (concat header org-content))
         (effective-title (or edit-title doc-id))
         ;; Hash the Org projection; title, date and top drawer are metadata.
         (hash (secure-hash 'sha256 org-content))
         (capability-summary (gdocs--capability-summary
                              (if tabs (cdr rendered-tabs)
                                (gdocs-dm-unsupported doc))))
         (props (concat
                 (format
                  ":PROPERTIES:\n:GDOC_ID: %s\n:GDOC_TITLE: %s\n:GDOC_REVISION: %s\n:GDOC_CONTENT_HASH: %s\n:GDOC_SYNCED_AT: %s\n"
                  doc-id
                  effective-title
                  (if revision (number-to-string revision) "")
                  hash
                  (gdocs--now-iso))
                 (when tabs (format ":GDOC_TABS: %d\n" (length tabs)))
                 (when (length> capability-summary 0)
                   (format ":GDOC_UNSUPPORTED: %s\n"
                           capability-summary))
                 ":END:\n")))
    (cons effective-title (concat props titled))))

(defun gdocs--ot-body-length (ot-body)
  "Return the OT codepoint count of OT-BODY (the model chunk's `is.s')."
  (length (or ot-body "")))

(defun gdocs--ot-plain-and-map (ot-body)
  "Walk OT-BODY and split it into plain text + a position map.

Returns a cons (PLAIN . MAP) where:
- PLAIN is OT-BODY with structural codepoints (see
  `gdocs--ot-structural-codepoints') removed.
- MAP is a vector of length (length PLAIN). MAP[i] is the OT position
  of PLAIN[i] (1-based: OT pos 1 = first codepoint of the body).

Lookup: a plain-text position P corresponds to OT position MAP[P].
For an edit that replaces PLAIN[A..B), the OT range is MAP[A]..MAP[B-1]+1.
Comment anchors use a different convention: their `ei' is the inclusive
final OT position and must be mapped directly (without subtracting one)
through the OT-to-plain inverse of MAP."
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
 - Body Title/Subtitle keyword prefixes: `#+title: ' / `#+subtitle: '
   removed while their paragraph text is retained.
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
       ;; Body Title/Subtitle keywords are Org syntax for paragraph styles;
       ;; OT plain text contains only the paragraph text.
       ((and at-line-start
             (let* ((line-end (or (string-match "\n" text i) n))
                    (line (substring text i line-end)))
               (string-match-p
                "\\`#\\+\\(?:title\\|subtitle\\):[ \t]*" line)))
        (let* ((line-end (or (string-match "\n" text i) n))
               (line (substring text i line-end)))
          (string-match "\\`#\\+\\(?:title\\|subtitle\\):[ \t]*" line)
          (setq i (+ i (match-end 0))
                at-line-start nil)))
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
Returns a plist (:title :token :ouid :revision :smv :smb-seg :ot-body
:ot-ops :tabs :build-label :unsupported). The capability fields are derived
from this HTML, not from buffer-local metadata.
Any field may be nil if not present. Returns nil if HTML is nil.
Unrecognized tab structures signal rather than returning a partial body."
  (when html
    (let ((title nil) (token nil) (ouid nil) (revision nil)
          (smv nil) (smb-seg nil) (ot-body nil) (build-label nil))
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
        ;; The regex captures the raw JSON literal including \uXXXX escapes
        ;; (the segment is base64 whose `=' signs arrive as \u003d).  Decode
        ;; them by reading the value as a JSON string; leaving them in makes
        ;; /save double-escape the segment and reject with 400/err 3.
        (setq smb-seg
              (condition-case _
                  (let ((json-array-type 'list)
                        (json-object-type 'alist))
                    (json-read-from-string
                     (concat "\"" (match-string 1 html) "\"")))
                (error (match-string 1 html)))))
      (when (string-match "\"buildLabel\"[ \t]*:[ \t]*\"\\([^\"]+\\)\"" html)
        (setq build-label (match-string 1 html)))
      (let* ((mc (gdocs--parse-model-chunk html))
             (full (gdocs--parse-model-chunk-full html))
             (all-ops (plist-get full :ops))
             (tabs (gdocs--tabs-from-ops all-ops))
             (single-ops (if (and (null tabs)
                                  (seq-some (lambda (op)
                                              (equal (alist-get 'ty op) "mkch"))
                                            all-ops))
                             (seq-remove (lambda (op)
                                           (member (alist-get 'ty op)
                                                   '("mkch" "utlp" "umv")))
                                         all-ops)
                           all-ops)))
        (setq ot-body (if tabs (plist-get (car tabs) :ot-body)
                        (if (eq single-ops all-ops)
                            (plist-get mc :ot-body)
                          (gdocs--tab-op-body single-ops))))
        (when (plist-get mc :revision)
          (setq revision (plist-get mc :revision)))
        (let* ((ops (if tabs (plist-get (car tabs) :ops) single-ops))
               (analysis (gdocs--decode-capability-analysis
                          ops (or ot-body ""))))
          (list :title title :token token :ouid ouid :revision revision
                :smv smv :smb-seg smb-seg :ot-body ot-body
                :ot-ops ops :tabs tabs
                :build-label build-label
                :inline-objects (plist-get analysis :objects)
                :unsupported (plist-get analysis :unsupported)))))))

(defun gdocs--fetch-edit-state (doc-id)
  "Fetch the doc's /edit page once and extract everything we need.
Returns a plist (:title T :token TK :ouid U :revision N :smv V
:smb-seg S :ot-body STR :ot-ops OPS :unsupported REPORTS). Any field may be
nil if not found.
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
CALLBACK is called exactly once as `(funcall CALLBACK BODY ERR)'. If a
sync operation is already active, BODY is nil and ERR is \"sync busy\"."
  (interactive)
  (if gdocs--sync-mutex
      (progn
        (gdocs-log 'warn "Mutex locked - skipping pull")
        (when callback
          (condition-case callback-sig
              (funcall callback nil "sync busy")
            (error
             (gdocs-log 'error "busy pull callback failed: %s"
                        (error-message-string callback-sig))))))
    (let ((owner (gdocs--sync-acquire))
          (dispatched nil))
      (unwind-protect
          (let ((buf (current-buffer))
                (doc-id (gdocs--get-doc-id doc-id))
                (cb (or callback (lambda (_b _e) nil))))
            (gdocs--pull-locally-async-1 doc-id buf cb owner)
            (setq dispatched t))
        (unless dispatched
          (gdocs--sync-release owner))))))

(defun gdocs--capture-pull-snapshot (buf)
  "Capture the local state that a pull into BUF must not overwrite."
  (unless (buffer-live-p buf)
    (signal 'gdocs-pull-conflict '("destination buffer was killed")))
  (with-current-buffer buf
    (setq gdocs--pull-generation (1+ gdocs--pull-generation))
    (list :buffer buf
          :generation gdocs--pull-generation
          :body-hash (gdocs--current-body-hash)
          :revision (gdocs--top-property-value "GDOC_REVISION"))))

(defun gdocs--pull-conflict-revision (revision)
  "Return REVISION as a conflict-state number, or nil if unavailable."
  (cond
   ((integerp revision) revision)
   ((and (stringp revision)
         (string-match-p "\\`[0-9]+\\'" revision))
    (string-to-number revision))))

(defun gdocs--assert-pull-snapshot-current (buf snapshot remote-revision)
  "Refuse to apply a pull when BUF no longer matches SNAPSHOT."
  (let ((reason
         (cond
          ((not (buffer-live-p buf)) "destination buffer was killed")
          ((not (eq buf (plist-get snapshot :buffer)))
           "destination buffer identity changed")
          (t
           (with-current-buffer buf
             (cond
              ((not (equal gdocs--pull-generation
                           (plist-get snapshot :generation)))
               "a newer pull was dispatched")
              ((not (equal (gdocs--top-property-value "GDOC_REVISION")
                           (plist-get snapshot :revision)))
               "local revision changed while the pull was in flight")
              ((not (equal (gdocs--current-body-hash)
                           (plist-get snapshot :body-hash)))
               "local body changed while the pull was in flight")))))))
    (when reason
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (setq gdocs--auto-sync-conflict-revision
                (gdocs--pull-conflict-revision remote-revision))))
      (signal 'gdocs-pull-conflict (list reason)))))

(defun gdocs--pull-locally-async-1 (doc-id buf cb owner)
  "Background driver for `gdocs-pull-locally'.
Single GET on /edit gives us both the state and the raw HTML whose
modelChunk we need for the op stream. Comments live in the cookie-auth
`/docos/p/sync' endpoint — chain a POST there and append the
`* Comments' subtree if any."
  (let ((snapshot (gdocs--capture-pull-snapshot buf))
        (done nil))
    (cl-labels ((finish
                  (body err)
                  (unless done
                    (setq done t)
                    (gdocs--sync-release owner)
                    (when err (gdocs-log 'warn "Pull %s: %s" doc-id err))
                    (funcall cb body err))))
      (gdocs--fetch-edit-page-async
       doc-id
       (lambda (state edit-html err)
         (cond
          (err (finish nil err))
          (t
           (condition-case setup-sig
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
                             (tabs (plist-get state :tabs))
                             (anchor-map (gdocs--decode-doco-anchors
                                          (plist-get state :ot-ops)))
                             (ot-body (plist-get state :ot-body)))
                        (gdocs--docos-sync-raw-async
                         doc-id state
                         (lambda (raw _docos-err)
                           (condition-case sig2
                               (let* ((comments
                                       (and raw
                                            (gdocs--parse-docos-sync-response raw)))
                                      (_namespace-available
                                       (and comments
                                            (gdocs--assert-comment-footnote-namespace-available
                                             body)))
                                      (body-with-refs
                                       (if tabs
                                           (gdocs--tabbed-comment-refs
                                            body tabs comments)
                                         (if (and comments ot-body)
                                             (gdocs--inline-comment-refs
                                              body ot-body anchor-map comments)
                                           body)))
                                      (final
                                       (gdocs--append-comments-section
                                        body-with-refs comments)))
                                 (gdocs--apply-pull-into-buffer
                                  doc-id buf title final snapshot
                                  (plist-get state :revision))
                                 (finish final nil))
                             (error
                              (finish nil (error-message-string sig2)))))))
                    (error (finish nil (error-message-string sig))))))
             (error (finish nil (error-message-string setup-sig)))))))))))

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
  "Split a pull BODY into (DRAWER-ALIST LEGACY-TITLE CONTENT).

DRAWER-ALIST is a list of (KEY . VALUE) strings from a leading
`:PROPERTIES:'…`:END:' block. LEGACY-TITLE is the value of a leading
`#+title:' line only when the drawer lacks `GDOC_TITLE', which identifies
the old representation where the first title was synthetic metadata.
CONTENT is everything after synchronization metadata, with blank lines
between the header and the body skipped. A leading `#+title:' in a new
`GDOC_TITLE'-bearing single-tab body is content and is never stripped.
For multi-tab bodies the document-level `#+title:' is metadata."
  (with-temp-buffer
    (insert body)
    (goto-char (point-min))
    (let ((drawer nil) (legacy-title nil))
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
      ;; Before GDOC_TITLE existed, the pull wrapper put the Drive name in
      ;; this position. Preserve that parser behavior for old serialized pull
      ;; bodies, while treating a title keyword in the new representation as
      ;; an actual body paragraph.
      (when (and drawer
                 (not (assoc "GDOC_TITLE" drawer))
                 (looking-at "^#\\+title:[ \t]*\\(.*\\)$"))
        (let ((m (match-string-no-properties 1)))
          (when (and m (not (string-empty-p (string-trim m))))
            (setq legacy-title (string-trim m))))
        (forward-line 1))
      (when (assoc "GDOC_TABS" drawer)
        (while (looking-at "^[ \t]*\n") (forward-line 1))
        (unless (looking-at "^#\\+title:[ \t]*.*$")
          (error "gdocs: missing document title in tabbed pull"))
        (forward-line 1)
        (while (looking-at "^[ \t]*\n") (forward-line 1)))
      (when (looking-at "^#\\+date:[ \t]*.*$")
        (forward-line 1))
      (while (and (not (eobp)) (looking-at "^[ \t]*\n"))
        (forward-line 1))
      (list (nreverse drawer) legacy-title
            (buffer-substring-no-properties (point) (point-max))))))

(defun gdocs--top-property-value (key)
  "Return top-level property KEY in the current Org buffer, or nil."
  (and (derived-mode-p 'org-mode)
       (save-excursion
         (goto-char (point-min))
         (org-entry-get (point-min) key nil))))

(defun gdocs--legacy-leading-title-region ()
  "Return the old synthetic title region, or nil.

Legacy synchronized buffers have a `GDOC_ID' but no `GDOC_TITLE'; their
first `#+title:' after the top property drawer is the Drive document name.
The returned region includes the blank padding immediately following that
line, but never a second title paragraph."
  (save-excursion
    (goto-char (point-min))
    (when (and (gdocs--top-property-value "GDOC_ID")
               (not (gdocs--top-property-value "GDOC_TITLE")))
      (when (looking-at org-property-drawer-re)
        (goto-char (match-end 0))
        (forward-line))
      (when (looking-at "^#\\+title:[^\n]*\n?")
        (let ((start (point)))
          (goto-char (match-end 0))
          (while (and (not (eobp)) (looking-at "^[ \t]*\n"))
            (forward-line 1))
          (cons start (point)))))))

(defun gdocs--migrate-legacy-title ()
  "Remove the synthetic title from an old synchronized buffer.

Only the first leading title is removed. A second, identical or different,
`#+title:' remains available as the body Title paragraph."
  (when-let* ((region (gdocs--legacy-leading-title-region)))
    (delete-region (car region) (cdr region))
    t))

(defun gdocs--skip-buffer-synchronization-metadata ()
  "Move to the start of pushable body content in the current buffer.

Skip the top property drawer, an old synthetic title when this is a legacy
buffer, the generated date keyword, and leading presentation blanks. A
`#+title:' is retained for a single-tab `GDOC_TITLE' buffer because it is
then a pushable body Title paragraph; in a multi-tab buffer it names the
whole document and is skipped."
  (goto-char (point-min))
  (when (looking-at org-property-drawer-re)
    (goto-char (match-end 0))
    (forward-line))
  (when (and (gdocs--top-property-value "GDOC_ID")
             (not (gdocs--top-property-value "GDOC_TITLE"))
             (looking-at "^#\\+title:.*\n?"))
    (goto-char (match-end 0)))
  (when (gdocs--top-property-value "GDOC_TABS")
    (while (looking-at "^[ \t]*\n") (forward-line 1))
    ;; An existing flat buffer has a date but no document-level title until
    ;; its first tabbed pull has replaced the body. Accept either order.
    (when (looking-at "^#\\+date:.*\n")
      (goto-char (match-end 0)))
    (while (looking-at "^[ \t]*\n") (forward-line 1))
    (when (looking-at "^#\\+title:.*\n?")
      (goto-char (match-end 0)))
    (while (looking-at "^[ \t]*\n") (forward-line 1)))
  (when (looking-at "^#\\+date:.*\n")
    (goto-char (match-end 0)))
  (while (and (not (eobp)) (looking-at "^[ \t]*\n"))
    (forward-line 1))
  (point))

(defun gdocs--body-start-pos ()
  "Return the position where pushable document content starts."
  (save-excursion
    (gdocs--skip-buffer-synchronization-metadata)))

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

(defun gdocs--apply-pull-into-buffer (doc-id buf title body
                                             &optional snapshot remote-revision)
  "Update BUF so its body matches BODY, preserving point and metadata.

The Drive name is stored in `GDOC_TITLE'. Multi-tab buffers also show it
as a document-level `#+title:' keyword. Old buffers whose first title is the
synthetic metadata title are migrated before the body diff, so a second
title remains intact even when its text equals the Drive name.

Replaced/inserted text is briefly highlighted via `gdocs--flash-regions'.
Falls back to a full body replace if the diff would touch the whole document
anyway."
  (unless (and body (not (string-empty-p body)))
    (error "GDocs pull returned empty content"))
  (when snapshot
    (gdocs--assert-pull-snapshot-current buf snapshot remote-revision))
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((inhibit-read-only t)
             (saved-mod (buffer-modified-p))
             (point-marker (copy-marker (point) t))
             (parsed (gdocs--parse-pull-body body))
             (drawer (nth 0 parsed))
             (legacy-title (nth 1 parsed))
             (content (nth 2 parsed))
             (effective-title (or title
                                  (cdr (assoc "GDOC_TITLE" drawer))
                                  legacy-title
                                  doc-id)))
        (unless (derived-mode-p 'org-mode) (org-mode))
        ;; The old representation had a synthetic leading #+title but no
        ;; GDOC_TITLE property. Remove exactly that line before installing
        ;; the new metadata; a second title is body content.
        (gdocs--migrate-legacy-title)
        ;; Write top-level properties. GDOC_ID is forced to the doc-id
        ;; we were called with (canonical); other keys come from the
        ;; pull's drawer if present.
        (gdocs--put-top-property "GDOC_ID" doc-id)
        (unless (assoc "GDOC_TABS" drawer)
          (when (gdocs--top-property-value "GDOC_TABS")
            (org-entry-delete (point-min) "GDOC_TABS")))
        (dolist (pair drawer)
          (unless (string= (car pair) "GDOC_ID")
            (gdocs--put-top-property (car pair) (cdr pair))))
        ;; Refresh the Drive name and sync time. Multi-tab documents also
        ;; show the name as a file-level title above their tab headings.
        (gdocs--update-top-metadata
         effective-title nil
         (or (cdr (assoc "GDOC_UNSUPPORTED" drawer)) ""))
        (when (assoc "GDOC_TABS" drawer)
          (save-excursion
            (goto-char (point-min))
            (when (looking-at org-property-drawer-re)
              (goto-char (match-end 0))
              (forward-line))
            (if (looking-at "^#\\+title:.*$")
                (replace-match (format "#+title: %s" effective-title) t t)
              (insert (format "#+title: %s\n" effective-title)))))
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
        ;; Recompute after migration/body edits so legacy pull payloads
        ;; cannot leave a hash for the old synthetic-title representation.
        (gdocs--put-top-property "GDOC_CONTENT_HASH"
                                 (gdocs--current-body-hash))
        (gdocs--mark-synced)
        (when (and (buffer-file-name) (not saved-mod))
          (save-buffer))))))


;;; Public commands — push

(defun gdocs--current-body-hash ()
  "SHA-256 of the buffer's pushable body.

Synchronization metadata, including `GDOC_TITLE', is excluded. A body
`#+title:' remains part of the hashed text for single-tab documents;
the multi-tab document title is metadata."
  (secure-hash 'sha256 (gdocs--buffer-body-as-plain)))

(defun gdocs--valid-content-hash-p (hash)
  "Return non-nil when HASH is a serialized SHA-256 digest."
  (and (stringp hash)
       (string-match-p "\\`[[:xdigit:]]\\{64\\}\\'" hash)))

(defun gdocs--restore-sync-baseline ()
  "Restore the last successful baseline from GDOC_CONTENT_HASH.

A missing or malformed property leaves the synchronization state unknown."
  (let ((persisted-hash (gdocs--top-property-value "GDOC_CONTENT_HASH")))
    (setq gdocs--last-synced-hash
          (and (gdocs--valid-content-hash-p persisted-hash)
               (downcase persisted-hash))
          gdocs--auto-sync-conflict-revision nil)))

(defun gdocs--sync-state ()
  "Return the local synchronization state: `clean', `dirty', or `unknown'."
  (cond
   ((null gdocs--last-synced-hash) 'unknown)
   ((string= (gdocs--current-body-hash) gdocs--last-synced-hash) 'clean)
   (t 'dirty)))

(defun gdocs--mark-synced (&optional committed-hash)
  "Record COMMITTED-HASH or the current body hash as the sync baseline.
Call inside `with-current-buffer' after every successful pull or push."
  (setq gdocs--last-synced-hash (or committed-hash
                                    (gdocs--current-body-hash))
        gdocs--auto-sync-conflict-revision nil))

(defun gdocs--buffer-body-as-plain ()
  "Dump the pushable body, excluding synchronization metadata.

The top property drawer, document-level title for multi-tab buffers,
legacy synthetic title, and generated date are excluded. A `#+title:' is
retained when it belongs to the body of a single-tab document. Generated
`[fn:gdocs-comment-N]' references and the marked `* Comments' subtree are
excluded. Numeric and user-named Org footnotes remain pushable content."
  (save-excursion
    (let* ((body-start (gdocs--body-start-pos))
           (end (gdocs--find-local-subtree-start body-start))
           (text (buffer-substring-no-properties body-start end))
           (text (replace-regexp-in-string "\r\n" "\n" text))
           ;; The reserved namespace belongs only to Google's generated
           ;; comment projection; ordinary Org footnotes are user content.
           (text (replace-regexp-in-string
                  (concat "\\[fn:"
                          (regexp-quote gdocs--comment-footnote-label-prefix)
                          "[0-9]+\\]")
                  "" text)))
      text)))

(defun gdocs--inline-object-capability-report (object &optional source)
  "Build a capability report for decoded inline OBJECT."
  (gdocs--capability-report
   (if (gdocs--inline-object-is-image-p object) :inline-image :remote-chip)
   (if (gdocs--inline-object-is-image-p object)
       "Inline images are pull-only; the current OT encoder can preserve one only when it is left untouched."
     "Remote chips are pull-only; the current OT encoder can preserve one only when it is left untouched.")
   :entity-id (plist-get object :entity-id)
   :ot-start (plist-get object :ot-position)
   :ot-end (plist-get object :ot-position)
   :source source
   :preserve-untouched t :refuse-push nil
   :push-policy :allow-if-untouched))

(defun gdocs--remote-capability-analysis (state)
  "Return a fresh capability analysis for push STATE.

When raw `:ot-ops' are present they are authoritative and are decoded on
every call. The cached `:unsupported' value is only a fallback for synthetic
or legacy states without raw operations; push safety never trusts a stale
buffer-local report over raw remote state."
  (if (plist-get state :ot-ops)
      (gdocs--decode-capability-analysis
       (plist-get state :ot-ops)
       (or (plist-get state :ot-body) ""))
    (let ((objects (plist-get state :inline-objects)))
      (list :objects objects
            :unsupported
            (gdocs--capability-merge
             (mapcar (lambda (report)
                       (if (stringp report)
                           (gdocs--capability-report
                            :unknown-feature
                            "The remote document contains capability data from an older decoder."
                            :source :remote :refuse-push t)
                         report))
                     (plist-get state :unsupported))
             (mapcar (lambda (object)
                       (gdocs--inline-object-capability-report
                        object :remote))
                     objects))))))

(defalias 'gdocs--remote-inline-object-analysis
  #'gdocs--remote-capability-analysis)

(defun gdocs--local-inline-object-capability-report (object)
  "Build the local capability report for inline OBJECT."
  (gdocs--capability-report
   (if (gdocs--inline-object-is-image-p object) :inline-image :remote-chip)
   (if (gdocs--inline-object-is-image-p object)
       "The local document contains an inline image marker that the OT encoder cannot create or change."
     "The local document contains a remote chip marker that the OT encoder cannot create or change.")
   :entity-id (plist-get object :entity-id)
   :source :local-object
   :preserve-untouched t :refuse-push nil
   :push-policy :allow-if-untouched))

(defun gdocs--capability-object-entity-id (object)
  "Return OBJECT's usable stable entity ID, or nil."
  (let ((id (plist-get object :entity-id)))
    (and (stringp id)
         (not (string-empty-p id))
         id)))

(defun gdocs--inline-object-matching-report (object source explanation)
  "Build a sanitized inline-object mismatch report for OBJECT.

SOURCE identifies which representation supplied OBJECT.  The entity ID is
retained internally for matching and range bookkeeping, but capability error
summaries never serialize it."
  (gdocs--capability-report
   (if (gdocs--inline-object-is-image-p object) :inline-image :remote-chip)
   explanation
   :entity-id (gdocs--capability-object-entity-id object)
   :ot-start (plist-get object :ot-position)
   :ot-end (plist-get object :ot-position)
   :source source
   :preserve-untouched t :refuse-push nil
   :push-policy :allow-if-untouched))

(defun gdocs--capability-object-error-ranges (reports)
  "Return conservative deletion ranges for inline-object REPORTS.

These ranges are diagnostic/preflight metadata only.  They retain the remote
OT position without normalizing the corresponding marker text first."
  (cl-loop for report in reports
           for start = (plist-get report :ot-start)
           for end = (plist-get report :ot-end)
           when (and (integerp start) (integerp end) (>= end start))
           collect (list :ot-start start :ot-end end
                         :insert-at start
                         :delete-count (max 1 (1+ (- end start))))))

(defun gdocs--capability-object-matching-errors
    (local-objects remote-objects &optional partial)
  "Return reports when LOCAL-OBJECTS cannot be preserved against REMOTE-OBJECTS.

Matching is keyed by the stable entity ID first, then compares immutable
metadata.  Each valid ID is consumed at most once.  FULL comparisons require
the two representations to contain the same ordered set of objects; PARTIAL
comparisons are used for an insertion payload and only reject markers in that
payload, because the payload is not the complete local document."
  (let ((local-seen (make-hash-table :test #'equal))
        (remote-seen (make-hash-table :test #'equal))
        (remote-by-id (make-hash-table :test #'equal))
        (local-duplicates (make-hash-table :test #'equal))
        (remote-duplicates (make-hash-table :test #'equal))
        (local-paired (make-hash-table :test #'equal))
        (consumed (make-hash-table :test #'equal))
        (errors nil))
    ;; Validate local IDs before attempting any match.  A duplicate ID must
    ;; never be allowed to consume the same remote object twice.
    (dolist (object local-objects)
      (let ((id (gdocs--capability-object-entity-id object)))
        (cond
         ((null id)
          (push (gdocs--inline-object-matching-report
                 object :local-object
                 "A local inline object marker has no usable entity ID.")
                errors))
         ((gethash id local-seen)
          (puthash id t local-duplicates)
          (push (gdocs--inline-object-matching-report
                 object :local-object
                 "A local inline object marker uses an entity ID more than once.")
                errors))
         (t (puthash id object local-seen)))))
    ;; Validate remote IDs separately.  Legacy/synthetic states may carry an
    ;; object list without having passed through the raw OT decoder.  This
    ;; check also applies to partial insertion preflight.
    (dolist (object remote-objects)
      (let ((id (gdocs--capability-object-entity-id object)))
        (cond
         ((null id)
          (push (gdocs--inline-object-matching-report
                 object :remote-object
                 "A remote inline object has no usable entity ID.")
                errors))
         ((gethash id remote-seen)
          (puthash id t remote-duplicates)
          (push (gdocs--inline-object-matching-report
                 object :remote-object
                 "A remote inline object uses an entity ID more than once.")
                errors))
         (t
          (puthash id object remote-seen)
          (puthash id object remote-by-id)))))
    (if partial
        ;; An insertion payload cannot safely create, duplicate, or substitute
        ;; an image.  It is not the complete local representation, so do not
        ;; interpret its absence of markers as deletion of remote objects.
        (dolist (object local-objects)
          (unless (gethash (gdocs--capability-object-entity-id object)
                           local-duplicates)
            (push (gdocs--inline-object-matching-report
                   object :local-object
                   "An inline object marker cannot be inserted or changed.")
                  errors)))
      (progn
        ;; Pair by entity ID, consuming a remote object exactly once.  A
        ;; metadata mismatch consumes the corresponding remote ID for error
        ;; reporting, rather than being mistaken for a second missing object.
        (dolist (object local-objects)
          (let ((id (gdocs--capability-object-entity-id object)))
            (when (and id
                       ;; Pair the first occurrence even when the ID is
                       ;; duplicated; the later occurrences are the local
                       ;; one-to-many violation already reported above.
                       (not (gethash id local-paired))
                       (not (gethash id remote-duplicates)))
              (puthash id t local-paired)
              (let ((remote (gethash id remote-by-id)))
                (cond
                 ((null remote)
                  (push (gdocs--inline-object-matching-report
                         object :local-object
                         "A local inline object marker has no matching remote object.")
                        errors))
                 (t
                  (puthash id t consumed)
                  (unless (gdocs--capability-object-equal-p object remote)
                    (push (gdocs--inline-object-matching-report
                           remote :remote-object
                           "Inline object metadata differs between local and remote documents.")
                          errors))))))))
        ;; A remote ID without a local marker is a deletion, not an ordinary
        ;; text edit.  Do not let placeholder normalization hide it.
        (dolist (object remote-objects)
          (let ((id (gdocs--capability-object-entity-id object)))
            (when (and id
                       (not (gethash id remote-duplicates))
                       (not (gethash id consumed)))
              (push (gdocs--inline-object-matching-report
                     object :remote-object
                     "A remote inline object has no local marker.")
                    errors))))
        ;; OT positions are transient, but moving an image is not supported.
        ;; Compare document order separately from object identity.
        (when (null errors)
          (let ((local-order
                 (mapcar #'gdocs--capability-object-entity-id local-objects))
                (remote-order
                 (mapcar #'gdocs--capability-object-entity-id remote-objects)))
            (unless (equal local-order remote-order)
              (push (gdocs--inline-object-matching-report
                     (car remote-objects) :remote-object
                     "Inline object markers were reordered, but moving remote objects is unsupported.")
                    errors))))))
    (nreverse errors)))

(defun gdocs--doc-malformed-inline-object-count (doc)
  "Return the number of malformed inline-object marker nodes in DOC."
  (cl-loop
   for paragraph in (gdocs-dm-paragraphs doc)
   sum (+ (if (plist-get paragraph :inline-object-malformed) 1 0)
          (cl-count-if
           (lambda (run) (plist-get run :inline-object-malformed))
           (if (eq (plist-get paragraph :kind) :table)
               (cl-loop for row in (plist-get paragraph :rows)
                        append (cl-loop for cell in row
                                        append (gdocs--table-cell-runs cell)))
             (plist-get paragraph :runs))))))

(defun gdocs--remote-inline-object-validation-errors (reports)
  "Return hard inline-object reports from remote capability REPORTS.

Valid remote image/chip reports deliberately have `:refuse-push' nil and
are preserved by range checks.  A hard report represents malformed or
ambiguous remote object data that must also block a no-op."
  (cl-remove-if-not
   (lambda (report)
     (and (memq (plist-get report :kind) '(:inline-image :remote-chip))
          (plist-get report :refuse-push)))
   reports))

(defun gdocs--local-capability-analysis (local-body)
  "Decode local unsupported markers and inline objects for preflight.
Local object payloads are used only for equality checking against the fresh
remote analysis; they are never put into a capability report.  Malformed
parsed marker nodes are reported as invalid."
  (let* ((body (or local-body ""))
         (doc (gdocs-dm-from-org body))
         (objects (gdocs-dm-inline-objects doc))
         (reports (mapcar #'gdocs--local-inline-object-capability-report
                          objects))
         (malformed-count (gdocs--doc-malformed-inline-object-count doc))
         (marker-errors
          (if (zerop malformed-count)
              nil
            (list
             (gdocs--capability-report
              :inline-image
              "The local document contains an invalid inline object marker."
              :source :local-marker :refuse-push t :render-directive nil)))))
    (list :objects objects
          :inline-marker-errors marker-errors
          :unsupported (gdocs--capability-merge
                        (gdocs-dm-unsupported doc)
                        marker-errors reports))))

(defun gdocs--capability-object-equal-p (a b)
  "Return non-nil when local and remote inline objects are unchanged.

The stable entity ID is the primary identity.  Once it matches, the object
kind and the immutable payload must also match: images compare content ID
and dimensions, chips compare their Google-supplied label.  Dimensions use
the exact numeric policy of `gdocs--inline-object-canonical-value': numeric
values are compared after conversion to double precision with no tolerance,
and missing dimensions are not preserved.  OT position and decoder/source
metadata are ignored."
  (let ((id-a (gdocs--capability-object-entity-id a))
        (id-b (gdocs--capability-object-entity-id b))
        (object-kind-a (plist-get a :object-kind))
        (object-kind-b (plist-get b :object-kind)))
    (and id-a id-b
         (equal id-a id-b)
         (plist-get a :kind)
         (equal (plist-get a :kind) (plist-get b :kind))
         object-kind-a object-kind-b
         (equal object-kind-a object-kind-b)
         (if (eq object-kind-a :image)
             (let ((content-a (plist-get a :content-id))
                   (content-b (plist-get b :content-id)))
               (and (stringp content-a) (stringp content-b)
                    (not (string-empty-p content-a))
                    (not (string-empty-p content-b))
                    (equal content-a content-b)
                    (gdocs--inline-object-dimension-equal-p
                     (plist-get a :width) (plist-get b :width))
                    (gdocs--inline-object-dimension-equal-p
                     (plist-get a :height) (plist-get b :height))))
           ;; Chips carry a semantic value (calendar date or contact
           ;; name) instead of image metadata; display formatting is
           ;; deliberately not compared.
           (let ((value-a (plist-get a :chip-value))
                 (value-b (plist-get b :chip-value)))
             (and (gdocs--valid-chip-label-p value-a)
                  (gdocs--valid-chip-label-p value-b)
                  (equal value-a value-b)))))))

(defun gdocs--capability-object-matches-p (object remote-objects)
  "Return non-nil when OBJECT has exactly one matching remote object.

This helper does not mutate REMOTE-OBJECTS, so callers needing a complete
one-to-one proof must use `gdocs--capability-object-matching-errors'."
  (let ((candidates
         (cl-remove-if-not
          (lambda (remote)
            (equal (gdocs--capability-object-entity-id object)
                   (gdocs--capability-object-entity-id remote)))
          remote-objects)))
    (and (= (length candidates) 1)
         (gdocs--capability-object-equal-p object (car candidates)))))

(defun gdocs--capability-report-range (report)
  "Return REPORT's inclusive OT range, or nil when no range is known."
  (let ((start (plist-get report :ot-start))
        (end (plist-get report :ot-end)))
    (and (integerp start) (integerp end) (>= start 1) (>= end start)
         (cons start end))))

(defun gdocs--capability-range-touched-p (report ranges)
  "Return non-nil when an edit in RANGES touches REPORT.

Each range is a plist with `:ot-start' and `:ot-end' inclusive for deleted
content, `:delete-count', and optional `:insert-at'. An insertion at N occurs
before OT position N, so it touches inclusive range [START, END] exactly when
START < N <= END. Thus neither adjacent insertion touches a one-position
range. Any deletion that overlaps the range touches it."
  (let ((cap-range (gdocs--capability-report-range report)))
    (and cap-range
         (cl-some
          (lambda (range)
            (let* ((start (plist-get range :ot-start))
                   (end (plist-get range :ot-end))
                   (insert-at (or (plist-get range :insert-at) start))
                   (delete-count (or (plist-get range :delete-count) 0)))
              (and (integerp start) (integerp end)
                   (or (and (> delete-count 0)
                            (<= (car cap-range) end)
                            (<= start (cdr cap-range)))
                       (and (integerp insert-at)
                            (> insert-at (car cap-range))
                            (<= insert-at (cdr cap-range)))))))
          ranges))))

(defun gdocs--inline-marker-ot-char (object)
  "Return the single OT placeholder char Google indexes for OBJECT.
Images use `*'; date/person chips use `gdocs--ot-chip-codepoint'."
  (if (gdocs--inline-object-is-image-p object)
      ?* gdocs--ot-chip-codepoint))

(defun gdocs--inline-markers-as-ot-placeholders (text)
  "Replace local/Org inline-object markers with their OT placeholder.

The rendered Org view carries a descriptive line or embedded export token,
while Google indexes one placeholder codepoint (an asterisk for images, a
private-use chip codepoint for date/person chips). This normalization is
used only for diff anchoring after capability validation; the original local
body is never rewritten."
  (with-temp-buffer
    (let ((org-inhibit-startup t))
      (insert (or text "")))
    (org-mode)
    (let ((tree (org-element-parse-buffer))
          replacements)
      (org-element-map tree '(keyword export-snippet link)
        (lambda (element)
          (let* ((type (car element))
                 (key (org-element-property :key element))
                 (backend (or (org-element-property :backend element)
                              (org-element-property :back-end element)))
                 (value (org-element-property :value element))
                 (standalone (and (eq type 'keyword)
                                  (stringp key)
                                  (string= (downcase key)
                                           "gdocs_inline_object")))
                 (embedded (and (eq type 'export-snippet)
                                (string= (downcase (format "%s" backend))
                                         "gdocs-inline-object")
                                (not (gdocs--org-element-escaped-p element))))
                 (parsed (or (and (or standalone embedded)
                                  (gdocs--parse-inline-object-spec value))
                             (and (eq type 'link)
                                  (gdocs--chip-object-from-link
                                   element (and (consp (cdr element))
                                                (cadr element)))))))
            (when parsed
              (let ((begin (org-element-property :begin element))
                    (end (org-element-property :end element)))
                (when (or embedded (eq type 'link))
                  (setq end (- end (or (org-element-property :post-blank element)
                                       0))))
                (when (and standalone (> end begin)
                           (= (char-before end) ?\n))
                  (cl-decf end))
                (push (list begin end
                            (gdocs--inline-marker-ot-char parsed))
                      replacements))))))
      (dolist (range (sort replacements
                           (lambda (a b) (> (car a) (car b)))))
        (delete-region (car range) (cadr range))
        (goto-char (car range))
        (insert (char-to-string (nth 2 range))))
      (buffer-string))))

(defun gdocs--push-capability-summary-error (reports reason)
  "Signal a sanitized user-error for REPORTS and REASON."
  (let* ((summary (gdocs--capability-summary reports))
         (format-string
          (pcase reason
            (:local
             "gdocs: Push refused: refusing push because the local body contains %s; image creation/replacement is not supported; pull remains available")
            (:full-replace
             "gdocs: Push refused: refusing push because full-document replacement would discard %s; pull remains available and unsupported content cannot be edited safely")
            (:intersects
             "gdocs: Push refused: refusing push because the edit intersects %s; the current OT encoder cannot preserve it")
            (_
             "gdocs: Push refused: refusing push because preservation cannot be proven for %s; pull remains available"))))
    (user-error (format format-string summary))))

(defun gdocs--push-preflight (state local-body plan)
  "Validate PLAN against a fresh remote capability report.

PLAN is a plist with `:kind' of `:full-replace', `:incremental', or `:noop'
and, for incremental edits, a `:ranges' list.  The optional
`:inline-object-scope' value `:partial' marks an insertion payload rather than
the complete local document.  A full replacement is never allowed in the
presence of destructive unsupported content. An incremental edit is allowed
 only when every report has a known range, explicitly allows untouched
 preservation, and no edit range touches it. The caller must pass STATE
obtained from the current /edit fetch; raw `:ot-ops' are decoded again here so
stale buffer-local capability metadata cannot bypass policy."
  (when (plist-get state :tabs)
    (user-error "gdocs: multi-tab saves require a selected tab state"))
  (let* ((remote (gdocs--remote-capability-analysis state))
         (local (gdocs--local-capability-analysis local-body))
         (remote-objects (plist-get remote :objects))
         (local-objects (plist-get local :objects))
         (kind (plist-get plan :kind))
         (object-errors
          (append
           (plist-get local :inline-marker-errors)
           (gdocs--remote-inline-object-validation-errors
            (plist-get remote :unsupported))
           (gdocs--capability-object-matching-errors
            local-objects remote-objects
            (eq (plist-get plan :inline-object-scope) :partial))))
         (local-reports (plist-get local :unsupported))
         (reports (gdocs--capability-merge
                   (plist-get remote :unsupported)
                   (cl-remove-if
                    (lambda (report)
                      (eq (plist-get report :source) :local-object))
                    local-reports)))
         ;; Reports whose policy allows push regardless of context (document
         ;; settings outside the replaced body) never block any plan kind,
         ;; including the conservative no-op path.
         (blocking (cl-remove-if
                    (lambda (report)
                      (eq (plist-get report :push-policy) :allow-push))
                    reports)))
    (when object-errors
      (gdocs--push-capability-summary-error
       object-errors
       (if (and (eq kind :incremental)
                (cl-some
                 (lambda (report)
                   (gdocs--capability-range-touched-p
                    report (plist-get plan :ranges)))
                 object-errors))
           :intersects
         :local)))
    (unless (eq kind :noop)
      (cond
       ((eq kind :full-replace)
        (let* ((final-newline (1+ (length (or (plist-get state :ot-body) ""))))
               (destructive
                (cl-remove-if-not
                 (lambda (report)
                   (and (eq (plist-get report :severity) :destructive)
                        ;; A full replacement rewrites the body text only.
                        ;; The newline Google keeps after it, and the
                        ;; paragraph attributes on that newline, stay.
                        (not (and (plist-get report :preserve-untouched)
                                  (not (plist-get report :refuse-push))
                                  (eql (plist-get report :ot-start)
                                       final-newline)
                                  (eql (plist-get report :ot-end)
                                       final-newline)))))
                 blocking)))
          (when destructive
            (gdocs--push-capability-summary-error
             destructive :full-replace))))
       ((eq kind :incremental)
        (let* ((ranges (plist-get plan :ranges))
               (hard (cl-remove-if-not
                      (lambda (report)
                        (or (plist-get report :refuse-push)
                            (not (plist-get report :preserve-untouched))))
                      blocking))
               (unranged (cl-remove-if
                          #'gdocs--capability-report-range blocking))
               (intersecting
                (cl-remove-if-not
                 (lambda (report)
                   (gdocs--capability-range-touched-p report ranges))
                 blocking)))
          (cond
           (hard (gdocs--push-capability-summary-error hard :proof))
           ((or (null ranges) unranged)
            (gdocs--push-capability-summary-error
             (or unranged blocking) :proof))
           (intersecting
            (gdocs--push-capability-summary-error intersecting :intersects)))))
       (t
        (when blocking
          (gdocs--push-capability-summary-error blocking :proof)))))
    t))

(defun gdocs--push-preflight-insertion (state ot-position text)
  "Preflight an insertion against a freshly refetched STATE."
  (when (length> text 0)
    (let ((plan (list :kind :incremental)))
      (setq plan
            (plist-put
             plan :ranges
             (list (list :ot-start ot-position
                         :ot-end ot-position
                         :insert-at ot-position
                         :delete-count 0))))
      ;; TEXT is only the inserted payload, not the complete local document.
      ;; Its absence of image markers therefore cannot prove that existing
      ;; remote images were deleted, while any marker in the payload is an
      ;; unsupported image creation/duplication attempt.
      (setq plan (plist-put plan :inline-object-scope :partial))
      (gdocs--push-preflight state text plan))))

(defun gdocs--push-plan-ranges (state remote-body local-body)
  "Return OT touch ranges for a conservative incremental push plan."
  (let* ((ot-body (plist-get state :ot-body))
         (local-stripped
          (gdocs--inline-markers-as-ot-placeholders
           (car (gdocs--strip-heading-drawers local-body))))
         (remote-mappable
          (gdocs--inline-markers-as-ot-placeholders remote-body))
         (prepended (gdocs--diff-prepend remote-mappable local-stripped))
         (appended (gdocs--diff-append remote-mappable local-stripped)))
    (cond
     (prepended
      (list (list :ot-start 1 :ot-end 1 :insert-at 1 :delete-count 0)))
     ((and appended ot-body)
      (let ((at (1+ (gdocs--ot-body-length ot-body))))
        (list (list :ot-start at :ot-end at :insert-at at :delete-count 0))))
     (ot-body
      (let* ((paragraph-regions (gdocs--diff-paragraphs
                                 remote-mappable local-stripped))
             (regions (cond
                       ((zerop (length paragraph-regions))
                        (let ((single (gdocs--diff-single-region
                                       remote-mappable local-stripped)))
                          (and single (list single))))
                       ((= (length paragraph-regions) 1)
                        (let ((single (gdocs--diff-single-region
                                       remote-mappable local-stripped)))
                          (and single (list single))))
                       (t paragraph-regions))))
        (and regions
             (mapcar
              (lambda (region)
                (let ((ot-range
                       (gdocs--locate-edit-in-ot
                        ot-body remote-mappable
                        (plist-get region :start)
                        (plist-get region :rem-end))))
                  (when ot-range
                    (list :ot-start (car ot-range)
                          :ot-end (if (> (length (plist-get region :deleted)) 0)
                                      (1- (cdr ot-range))
                                    (car ot-range))
                          :insert-at (car ot-range)
                          :delete-count (length (plist-get region :deleted))))))
              regions))))
     (t nil))))

(defun gdocs--preserve-clean-list-nesting (old-doc new-doc)
  "Keep OLD-DOC list levels when NEW-DOC's visible list content is unchanged."
  (if (not (and old-doc
                (cl-some
                 (lambda (report)
                   (equal (plist-get report :feature-type)
                          "list-nesting-sequence"))
                 (gdocs-dm-unsupported old-doc))))
      new-doc
    (let ((old (gdocs-dm-paragraphs old-doc))
          (new (gdocs-dm-paragraphs new-doc))
          paragraphs
          clean)
      (setq clean (= (length old) (length new)))
      (while (and clean old new)
        (let* ((old-paragraph (car old))
               (new-paragraph (copy-tree (car new)))
               (old-list (eq (plist-get old-paragraph :kind) :list))
               (new-list (eq (plist-get new-paragraph :kind) :list)))
          (when (or old-list new-list)
            (if (and old-list new-list)
                (progn
                  (setq new-paragraph
                        (plist-put new-paragraph :nest
                                   (plist-get old-paragraph :nest)))
                  (unless (gdocs--paragraph-equal-p
                           old-paragraph new-paragraph)
                    (setq clean nil)))
              (setq clean nil)))
          (push new-paragraph paragraphs))
        (setq old (cdr old)
              new (cdr new)))
      (if clean
          (plist-put (copy-sequence new-doc) :paragraphs
                     (nreverse paragraphs))
        new-doc))))

(defun gdocs--incremental-needs-full-replace-p (state local-body)
  "Return non-nil when the incremental backend must replace the document."
  (let* ((ot-ops (plist-get state :ot-ops))
         (old-doc (and ot-ops
                       (gdocs-dm-from-ops
                        (plist-get state :revision)
                        nil (plist-get state :title)
                        (or (plist-get state :ot-body) "") ot-ops)))
         (new-doc (gdocs--preserve-clean-list-nesting
                   old-doc (gdocs-dm-from-org local-body))))
    (or (null old-doc)
        (eq (plist-get (gdocs-dm-to-incremental-save-plan old-doc new-doc t)
                       :kind)
            :full-replace))))

(defun gdocs--incremental-plan-for-state (state local-body)
  "Build an explicit incremental-backend plan against STATE."
  (let* ((ot-ops (plist-get state :ot-ops))
         (old-doc (and ot-ops
                       (gdocs-dm-from-ops
                        (plist-get state :revision)
                        nil (plist-get state :title)
                        (or (plist-get state :ot-body) "") ot-ops)))
         (new-doc (gdocs--preserve-clean-list-nesting
                   old-doc (gdocs-dm-from-org local-body))))
    (if old-doc
        (gdocs-dm-to-incremental-save-plan old-doc new-doc t)
      (list :commands
            (gdocs-dm-to-save-commands
             (length (or (plist-get state :ot-body) "")) new-doc)
            :kind :full-replace
            :ranges nil))))

(defun gdocs--push-plan-for-diff (state local-body remote-body)
  "Return the preflight plan for the configured push backend."
  ;; Validate the complete marker representation before replacing any marker
  ;; with a literal OT placeholder.  Invalid representations still return a
  ;; conservative plan so callers can run the normal preflight and receive a
  ;; sanitized error, but no marker text is normalized on this path.
  (let* ((remote-analysis (gdocs--remote-capability-analysis state))
         (local-analysis (gdocs--local-capability-analysis local-body))
         (object-errors
          (append
           (plist-get local-analysis :inline-marker-errors)
           (gdocs--remote-inline-object-validation-errors
            (plist-get remote-analysis :unsupported))
           (gdocs--capability-object-matching-errors
            (plist-get local-analysis :objects)
            (plist-get remote-analysis :objects)))))
    (if object-errors
        ;; Preserve the backend's conservative plan shape for diagnostics and
        ;; range-aware callers, while still skipping normalization and relying
        ;; on preflight to reject the invalid representation.
        (let ((kind (if (memq gdocs-push-backend '(ot-encode ot-incremental))
                        :full-replace
                      :incremental)))
          (list :kind kind
                :ranges (and (eq kind :incremental)
                             (gdocs--capability-object-error-ranges
                              object-errors))))
      (let* ((local-stripped
              (gdocs--inline-markers-as-ot-placeholders
               (car (gdocs--strip-heading-drawers local-body))))
             (remote-mappable
              (gdocs--inline-markers-as-ot-placeholders remote-body))
             (incremental-plan
              (and (eq gdocs-push-backend 'ot-incremental)
                   (gdocs--incremental-plan-for-state state local-body)))
             (kind
              (cond
               ((eq gdocs-push-backend 'ot-incremental)
                (plist-get incremental-plan :kind))
               ((or (string= remote-mappable local-stripped)
                    ;; Content that differs only in Org spelling (keyword
                    ;; case, padding) is a no-op too: the canonical
                    ;; round-trip render of the local body matches remote.
                    (string= remote-mappable
                             (gdocs--push-comparison-body
                              (gdocs--push-expected-remote-body
                               (gdocs-dm-from-org local-body)))))
                :noop)
               ((eq gdocs-push-backend 'ot-encode) :full-replace)
               (t :incremental))))
        (list :kind kind
              :ranges (cond
                       ((and incremental-plan (eq kind :incremental))
                        (plist-get incremental-plan :ranges))
                       ((eq kind :incremental)
                        (gdocs--push-plan-ranges
                         state remote-body local-body)))
              :post-body (gdocs--push-comparison-body local-body))))))

(defun gdocs--assert-push-safe (state &optional local-body)
  "Compatibility guard for callers that require full-replacement safety.
All policy is delegated to `gdocs--push-preflight'."
  (gdocs--push-preflight
   state (or local-body "") '(:kind :full-replace)))

(defun gdocs--find-local-subtree-start (start)
  "Return the generated Comments subtree start, or `point-max'.
Search begins at START.  Both the exact heading and its `:GDOC_LOCAL: t'
marker are required so unrelated local-marked subtrees remain pushable."
  (save-excursion
    (goto-char start)
    (let ((found nil))
      (while (and (not found)
                  (re-search-forward "^\\* Comments[ \t]*$" nil t))
        (let ((head-bol (line-beginning-position)))
          (forward-line 1)
          (when (looking-at org-property-drawer-re)
            (let ((drawer (buffer-substring-no-properties
                           (match-beginning 0) (match-end 0))))
              (when (string-match-p "^:GDOC_LOCAL:[ \t]+t[ \t]*$" drawer)
                (setq found
                      (save-excursion
                        (goto-char head-bol)
                        (skip-chars-backward " \t\n" start)
                        (if (= (point) start)
                            start
                          (min head-bol (1+ (line-end-position)))))))))))
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
(define-error 'gdocs-save-post-dispatch-failed
              "gdocs /save failed after dispatch")

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
  (let ((timeout-args (gdocs--curl-timeout-args))
        body-file resp-file args)
    (unwind-protect
        (progn
          (setq body-file (make-temp-file "gdocs-req-" nil ".bin")
                resp-file (make-temp-file "gdocs-resp-" nil ".bin")
                args (append (list "--silent" "--compressed")
                             timeout-args
                             (list
                              "-X" "POST"
                              "-o" resp-file
                              "-w" "%{http_code}"
                              "--data-binary" (concat "@" body-file))
                             (mapcan
                              (lambda (h)
                                (list "-H" (format "%s: %s" (car h) (cdr h))))
                              headers)
                             (list url)))
          (let* ((_ (let ((coding-system-for-write 'utf-8))
                      (with-temp-file body-file (insert body))))
                 (status-string
                  (with-temp-buffer
                    (let ((exit (apply #'call-process "curl" nil t nil args)))
                      (unless (zerop exit)
                        (signal 'gdocs-save-post-dispatch-failed
                                (list (gdocs--curl-exit-error exit)))))
                    (buffer-string)))
                 (http-code (string-to-number status-string))
                 (response
                  (condition-case sig
                      (with-temp-buffer
                        (set-buffer-multibyte nil)
                        (insert-file-contents-literally resp-file)
                        (decode-coding-region (point-min) (point-max) 'utf-8)
                        (buffer-string))
                    (error
                     (signal 'gdocs-save-post-dispatch-failed
                             (list (error-message-string sig)))))))
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
            response))
      (when body-file (ignore-errors (delete-file body-file)))
      (when resp-file (ignore-errors (delete-file resp-file))))))

(defconst gdocs--inter-region-delay 3
  "Seconds to sleep between regions of a multi-region in-place push.
Multi-region pushes hit the /save endpoint 2× per region (ds + is). Doing
4+ saves back-to-back triggers HTTP 550 rate limiting whose cooldown is
longer than `gdocs--rate-limit-retry-delay'. Spacing regions avoids the
burst budget entirely and keeps the push reliable.")

(defconst gdocs--rate-limit-retry-delay 3
  "Seconds to wait before retrying a /save POST that returned HTTP 550.
Short enough to recover from transient load-balancer blips, long enough
not to hammer Google's throttle further.  A 550 / err 13 on every save
of a session is not a throttle: it is a SID the endpoint refuses (see
`gdocs--session-sid-valid-p').")

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
A browser keeps one SID for its editing session and numbers its saves
with `reqId'; persisting the pair lets saves from this workstation do
the same.  The endpoint reads the SID as a signed 64-bit integer: one
with its top bit set fails its first save with HTTP 550 / err 13 and
then every later one, which earlier versions took for a throttle.  See
`gdocs--session-sid-valid-p'."
  :type 'file
  :group 'gdocs-mode)

(defun gdocs--save-request (doc-id state commands)
  "POST commands to the cookie-auth /save endpoint.
STATE is the plist from `gdocs--fetch-edit-state'.  COMMANDS is a list
of OT ops (alists). Returns parsed JSON response (XSSI-stripped)."
  (when (plist-get state :tabs)
    (user-error "gdocs: multi-tab saves require a selected tab state"))
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
                       (format "[%d, \"%s\"]" smv smb-seg)
                     (format "[%d]" smv)))
         (qs (concat "id=" doc-id
                     ;; The current editors frontend rejects unknown
                     ;; session ids with HTTP 400; send it only when asked.
                     (if gdocs-save-send-sid (concat "&sid=" sid) "")
                     "&vc=1&c=1&w=1&flr=0"
                     (format "&smv=%d" smv)
                     "&smb=" (url-hexify-string smb-pair)
                     "&token=" (url-hexify-string token)
                     "&ouid=" ouid
                     "&includes_info_params=true"
                     "&cros_files=false&nded=false"
                     "&tab=" (url-hexify-string
                              (or (plist-get state :tab-id) gdocs-docs-tab))))
         (url (format "https://docs.google.com/document/u/0/d/%s/save?%s"
                      doc-id qs))
         (commands (if (plist-get state :tab-id)
                       (mapcar (lambda (op)
                                 `((ty . "nm")
                                   (nmr . ["ksm" ,(plist-get state :tab-id)])
                                   (nmc . ,op))) commands)
                     commands))
         (bundles (json-encode
                   (vector
                    `((commands . ,(vconcat commands))
                      (sid . ,sid)
                      (reqId . ,req-id)))))
         (form (format "rev=%s&bundles=%s"
                       (number-to-string rev)
                       (url-hexify-string bundles)))
         ;; The X-Rel-Id / X-Build / X-Client-Deadline-Ms triple was the
         ;; browser-fingerprint set of the 2026-05 frontend; the current
         ;; frontend VALIDATES it and rejects mismatches with 400/err 3,
         ;; so the plain header set is sent instead.
         (headers (append
                   `(("Content-Type" . "application/x-www-form-urlencoded;charset=utf-8")
                     ("X-Same-Domain" . "1")
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
       (signal 'gdocs-save-post-dispatch-failed
               (list (format "unparseable response: %s"
                             (substring stripped 0
                                        (min 300 (length stripped))))))))))

(defun gdocs--ot-remote-org-body (doc-id html state)
  "Render the remote doc as the org view we diff pushes against.
Pure transform: decodes the modelChunk in HTML through the same
pipeline as the pull. The doc-model renderer emits only body content, so
Title/Subtitle keywords must remain in the result: they are pushable body
paragraphs, not synchronization metadata."
  (let* ((parsed (gdocs--parse-model-chunk-full html))
         (ops (plist-get parsed :ops))
         (revision (or (plist-get state :revision)
                       (plist-get parsed :revision)))
         (ot-body (plist-get state :ot-body))
         (edit-title (plist-get state :title))
         (doc (gdocs-dm-from-ops revision doc-id edit-title
                                 (or ot-body "") ops))
         (org (gdocs-dm-to-org doc)))
    org))

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
  (let ((timeout-args (gdocs--curl-timeout-args))
        body-file resp-file stdout-buf process args finished)
    (cl-labels
        ((cleanup ()
           (when (and (processp process) (process-live-p process))
             (ignore-errors (delete-process process)))
           (when body-file (ignore-errors (delete-file body-file)))
           (when resp-file (ignore-errors (delete-file resp-file)))
           (when (buffer-live-p stdout-buf)
             (ignore-errors (kill-buffer stdout-buf))))
         (deliver (response http-code err)
           (unless finished
             (setq finished t)
             (cleanup)
             (condition-case callback-sig
                 (funcall callback response http-code err)
               (error
                (gdocs-log 'error "async callback failed: %s"
                           (error-message-string callback-sig)))))))
      (condition-case setup-sig
          (let ((setup-complete nil))
            (unwind-protect
                (progn
                  (when body
                    (setq body-file
                          (make-temp-file "gdocs-req-" nil ".bin")))
                  (setq resp-file (make-temp-file "gdocs-resp-" nil ".bin")
                        stdout-buf
                        (generate-new-buffer " *gdocs-curl-out*")
                        args
                        (append
                         (list "--silent" "--compressed")
                         timeout-args
                         (list "-X" method
                               "-o" resp-file
                               "-w" "%{http_code}")
                         (when body
                           (list "--data-binary" (concat "@" body-file)))
                         (mapcan
                          (lambda (h)
                            (list "-H" (format "%s: %s" (car h) (cdr h))))
                          headers)
                         (list url)))
                  (when body
                    (let ((coding-system-for-write 'utf-8))
                      (with-temp-file body-file (insert body))))
                  (setq process
                        (make-process
                         :name "gdocs-curl"
                         :noquery t
                         :command (cons "curl" args)
                         :buffer stdout-buf
                         :sentinel
                         (lambda (proc _event)
                           (when (memq (process-status proc) '(exit signal))
                             (condition-case response-sig
                                 (let ((exit-code (process-exit-status proc))
                                       http-code response err)
                                   (if (not (zerop exit-code))
                                       (setq err
                                             (gdocs--curl-exit-error exit-code))
                                     (when (buffer-live-p stdout-buf)
                                       (with-current-buffer stdout-buf
                                         (let ((status
                                                (string-trim (buffer-string))))
                                           (setq http-code
                                                 (and
                                                  (string-match-p
                                                   "^[0-9]+$" status)
                                                  (string-to-number status))))))
                                     (when (file-exists-p resp-file)
                                       (with-temp-buffer
                                         (let ((coding-system-for-read 'utf-8))
                                           (insert-file-contents resp-file))
                                         (setq response (buffer-string)))))
                                   (deliver response http-code err))
                               (error
                                (deliver nil nil
                                         (error-message-string
                                          response-sig))))))))
                  (setq setup-complete t)
                  process)
              (unless setup-complete (cleanup))))
        (error
         (deliver nil nil (error-message-string setup-sig))
         (signal (car setup-sig) (cdr setup-sig)))))))

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
         (let ((parsed (condition-case sig
                           (gdocs--parse-edit-state-html html)
                         (error (error-message-string sig)))))
           (if (stringp parsed)
               (funcall callback nil parsed)
             (funcall callback parsed nil))))))))

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
         (let ((parsed (condition-case sig
                           (gdocs--parse-edit-state-html html)
                         (error (error-message-string sig)))))
           (if (stringp parsed)
               (funcall callback nil nil parsed)
             (funcall callback parsed html nil))))))))

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
                       (format "[%d, \"%s\"]" smv smb-seg)
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
            "&tab=" (url-hexify-string gdocs-docs-tab))))

(defun gdocs--docos-headers (doc-id)
  "Return the cookie-auth headers the browser sends to /docos/p/*."
  (append
   `(("X-Same-Domain" . "1")
     ("Origin" . "https://docs.google.com")
     ("Referer" . ,(format "https://docs.google.com/document/d/%s/edit?tab=%s"
                           doc-id gdocs-docs-tab))
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
Output lands in *gdocs-comments-debug*.  The buffer contains sensitive
document and comment content and persists until killed."
  (interactive)
  (let* ((doc-id (gdocs--get-doc-id doc-id))
         (buf (get-buffer-create "*gdocs-comments-debug*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format ";; WARNING: sensitive document/comment content; kill this buffer when done\n;; gdocs-debug-comments-fetch %s at %s\n;; …fetching…\n"
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
  (when (plist-get state :tabs)
    (user-error "gdocs: multi-tab saves require a selected tab state"))
  (let* ((token (plist-get state :token))
         (ouid (plist-get state :ouid))
         (rev (plist-get state :revision))
         (smv (or (plist-get state :smv) 2147483647))
         (smb-seg (plist-get state :smb-seg))
         (req-id (gdocs--session-next-reqid))
         (sid gdocs--session-sid)
         (smb-pair (if smb-seg
                       (format "[%d, \"%s\"]" smv smb-seg)
                     (format "[%d]" smv)))
         (qs (concat "id=" doc-id
                     ;; The current editors frontend rejects unknown
                     ;; session ids with HTTP 400; send it only when asked.
                     (if gdocs-save-send-sid (concat "&sid=" sid) "")
                     "&vc=1&c=1&w=1&flr=0"
                     (format "&smv=%d" smv)
                     "&smb=" (url-hexify-string smb-pair)
                     "&token=" (url-hexify-string token)
                     "&ouid=" ouid
                     "&includes_info_params=true"
                     "&cros_files=false&nded=false"
                     "&tab=" (url-hexify-string
                              (or (plist-get state :tab-id) gdocs-docs-tab))))
         (url (format "https://docs.google.com/document/u/0/d/%s/save?%s"
                      doc-id qs))
         (commands (if (plist-get state :tab-id)
                       (mapcar (lambda (op)
                                 `((ty . "nm")
                                   (nmr . ["ksm" ,(plist-get state :tab-id)])
                                   (nmc . ,op))) commands)
                     commands))
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

(defun gdocs--push-comparison-body (body)
  "Return the canonical body representation used for push verification.

Heading drawers and inline-object display markers are not part of Google's
OT text.  They must be removed in the same way when comparing a freshly
fetched state with the high-level push intent; otherwise a successful retry
could be mistaken for an unrelated change merely because the renderer uses a
different Org representation."
  (gdocs--inline-markers-as-ot-placeholders
   (replace-regexp-in-string
    "^#\\+gdocs_unsupported_list_nesting:.*\n" ""
    (car (gdocs--strip-heading-drawers (or body ""))))))

(defun gdocs--remote-org-body-from-state (doc-id state)
  "Render STATE's current OT stream as an Org body.

This is deliberately derived from the raw operations on every refetch.  A
retry must not use the body or capability information captured before the
refetch.  Synthetic tests may provide `:remote-body' directly, but real edit
states always contain `:ot-body' and `:ot-ops'."
  (when state
    (or (plist-get state :remote-body)
        (let ((doc (gdocs-dm-from-ops
                    (plist-get state :revision)
                    doc-id
                    (plist-get state :title)
                    (or (plist-get state :ot-body) "")
                    (or (plist-get state :ot-ops) nil))))
          (gdocs-dm-to-org doc)))))

(defun gdocs--push-state-body (doc-id state)
  "Return STATE's canonical remote body, or nil when it cannot be decoded."
  (and state
       (condition-case _
           (gdocs--push-comparison-body
            (gdocs--remote-org-body-from-state doc-id state))
         (error nil))))

(defun gdocs--push-revisions-equal-p (a b)
  "Return non-nil when revision values A and B represent the same revision."
  (and a b (string= (format "%s" a) (format "%s" b))))

(defun gdocs--push-next-revision (revision)
  "Return the expected next revision for numeric REVISION, or nil."
  (cond
   ((integerp revision) (1+ revision))
   ((and (stringp revision)
         (string-match-p "\\`[0-9]+\\'" revision))
    (number-to-string (1+ (string-to-number revision))))
   (t nil)))

(defun gdocs--push-apply-region-body (body region)
  "Apply REGION's high-level text replacement to canonical BODY."
  (let ((start (plist-get region :start))
        (rem-end (plist-get region :rem-end))
        (inserted (or (plist-get region :inserted) "")))
    (concat (substring body 0 start)
            inserted
            (substring body rem-end))))

(defun gdocs--push-target-body-from-regions (remote-body regions)
  "Reconstruct a target body from high-level REGIONS for legacy callers.

REGIONS are applied latest-first, so an edit to a later position cannot shift
the original coordinates of an earlier region.  Normal push callers pass the
complete local body directly; this fallback keeps the low-level multi-region
helper safe when only its historical REGION argument is available."
  (let ((target (gdocs--push-comparison-body remote-body)))
    (dolist (region regions target)
      (setq target (gdocs--push-apply-region-body target region)))))

(defun gdocs--push-region-list
    (remote-body target-body &optional selector)
  "Return high-level regions needed to turn REMOTE-BODY into TARGET-BODY.

When SELECTOR is supplied, prefer the contracted single-region diff if it
identifies that selector.  Paragraph-level diffs intentionally expand a
single paragraph replacement, but a retry of that operation must preserve
the original high-level edit rather than switch to the whole paragraph."
  (let* ((remote (gdocs--push-comparison-body remote-body))
         (target (gdocs--push-comparison-body target-body))
         (paragraphs (gdocs--diff-paragraphs remote target))
         (single (gdocs--diff-single-region remote target)))
    (if (and selector single
             (listp selector)
             (= (plist-get single :start) (plist-get selector :start))
             (equal (or (plist-get single :deleted) "")
                    (or (plist-get selector :deleted) ""))
             (equal (or (plist-get single :inserted) "")
                    (or (plist-get selector :inserted) "")))
        (list single)
      (or paragraphs (and single (list single))))))

(defun gdocs--push-region-selector (region)
  "Return a content selector for REGION, not a reusable OT position."
  (list :start (plist-get region :start)
        :deleted (or (plist-get region :deleted) "")
        :inserted (or (plist-get region :inserted) "")))

(defun gdocs--push-select-region (regions selector)
  "Select a freshly computed region from REGIONS using high-level SELECTOR.

SELECTOR may be an integer index in latest-first order or a content selector.
The returned region is always an object from the current diff; no positional
fields from a previous plan are reused as an OT operation."
  (cond
   ((integerp selector)
    (or (nth selector (nreverse (copy-sequence regions)))
        (user-error "gdocs: could not replan the requested edit region")))
   ((listp selector)
    (let* ((matches
            (cl-remove-if-not
             (lambda (candidate)
               (and (= (plist-get candidate :start)
                       (plist-get selector :start))
                    (equal (or (plist-get candidate :deleted) "")
                           (or (plist-get selector :deleted) ""))
                    (equal (or (plist-get candidate :inserted) "")
                           (or (plist-get selector :inserted) ""))))
             regions))
           (same-start
            (cl-find-if
             (lambda (candidate)
               (= (plist-get candidate :start)
                  (plist-get selector :start)))
             matches)))
      (or same-start
          (and (= (length matches) 1) (car matches))
          (user-error "gdocs: could not uniquely replan the requested edit region"))))
   (t
    (user-error "gdocs: invalid edit-region selector %S" selector))))

(defun gdocs--push-region-plan
    (state remote-body target-body selector stage)
  "Build a fresh positional plan for one high-level region.

STATE and REMOTE-BODY are the same current snapshot.  TARGET-BODY is the
complete desired canonical body.  STAGE is `:delete' or `:insert'."
  (let* ((remote (gdocs--push-comparison-body remote-body))
         (target (gdocs--push-comparison-body target-body))
         (regions (gdocs--push-region-list remote target selector))
         (region (and regions (gdocs--push-select-region regions selector)))
         (start (and region (plist-get region :start)))
         (rem-end (and region (plist-get region :rem-end)))
         (deleted (and region (or (plist-get region :deleted) "")))
         (inserted (and region (or (plist-get region :inserted) "")))
         (ot-body (plist-get state :ot-body))
         (ot-range
          (and region
               (or (gdocs--locate-edit-in-ot
                    ot-body remote start rem-end)
                   ;; A pure insertion at the end has no surviving plain
                   ;; character to anchor through the segment map.  The end
                   ;; of the OT body is nevertheless an unambiguous position.
                   (and (= start rem-end)
                        (= start (length remote))
                        (cons (1+ (length (or ot-body "")))
                              (1+ (length (or ot-body ""))))))))
         (ot-start (and ot-range (car ot-range)))
         (ot-end (and ot-range (cdr ot-range)))
         (kind (if (eq stage :delete) :delete :insert)))
    (unless (and region ot-range)
      (user-error "gdocs: could not locate edit context uniquely in OT body"))
    (when (and (eq kind :delete) (zerop (length deleted)))
      (user-error "gdocs: deletion plan contains no deleted content"))
    (when (and (eq kind :insert) (zerop (length inserted)))
      (user-error "gdocs: insertion plan contains no inserted content"))
    (list :kind kind
          :op (if (eq kind :delete)
                  `((ty . "ds") (si . ,ot-start) (ei . ,(1- ot-end)))
                `((ty . "is") (ibi . ,ot-start) (s . ,inserted)))
          :ot-start ot-start
          :ot-end ot-end
          :deleted deleted
          :inserted inserted
          :region region
          :post-body (if (eq kind :delete)
                         (gdocs--push-apply-region-body remote
                                                        (list :start start
                                                              :rem-end rem-end
                                                              :inserted ""))
                       (gdocs--push-apply-region-body remote
                                                      (list :start start
                                                            :rem-end start
                                                            :inserted inserted)))
          :preflight-plan
          (list :kind :incremental
                :ranges
                (list (list :ot-start ot-start
                            :ot-end (if (eq kind :delete)
                                        (1- ot-end)
                                      ot-start)
                            :insert-at ot-start
                            :delete-count (if (eq kind :delete)
                                              (length deleted)
                                            0)))))))

(defun gdocs--push-insert-plan (state remote-body text mode)
  "Build a fresh prepend/append insertion plan against STATE."
  (let* ((remote (gdocs--push-comparison-body remote-body))
         (ot-body (or (plist-get state :ot-body) ""))
         (ot-start (if (eq mode :prepend) 1 (1+ (length ot-body)))))
    (list :kind :insert
          :op `((ty . "is") (ibi . ,ot-start) (s . ,text))
          :ot-start ot-start
          :inserted text
          :post-body (if (eq mode :prepend)
                         (concat text remote)
                       (concat remote text))
          :preflight-plan
          (list :kind :incremental
                :ranges (list (list :ot-start ot-start
                                    :ot-end ot-start
                                    :insert-at ot-start
                                    :delete-count 0))))))

(defun gdocs--push-expected-remote-body (doc)
  "Return the canonical Org body expected after DOC is committed.

The expectation is derived from the actual publication model by rendering
DOC to Org — the same transformation a post-save refetch decodes — rather
than from the user's original Org spelling.  Keyword case, blank padding,
and other source-only normalization must not make a committed save look
unconfirmed."
  (gdocs-dm-to-org doc))

(defun gdocs--push-full-plan (doc-id state local-body backend)
  "Build a fresh full-bundle plan for BACKEND against STATE."
  (let* ((ot-body (or (plist-get state :ot-body) ""))
         (new-doc (gdocs-dm-from-org local-body))
         (generated
          (if (eq backend 'ot-incremental)
              (let* ((ot-ops (plist-get state :ot-ops))
                     (revision (plist-get state :revision))
                     (title (plist-get state :title))
                     (old-doc (and ot-ops
                                   (gdocs-dm-from-ops
                                    revision doc-id title ot-body ot-ops))))
                (if old-doc
                    (gdocs-dm-to-incremental-save-plan old-doc new-doc)
                  (list :commands
                        (gdocs-dm-to-save-commands (length ot-body) new-doc)
                        :kind :full-replace
                        :ranges nil)))
            (list :commands
                  (gdocs-dm-to-save-commands (length ot-body) new-doc)
                  :kind :full-replace
                  :ranges nil))))
    (list :kind (plist-get generated :kind)
          :commands (plist-get generated :commands)
          :ranges (plist-get generated :ranges)
          ;; The expected post-save body is the round-trip render of the
          ;; pushed model, not the original local spelling.
          :post-body (gdocs--push-comparison-body
                      (gdocs--push-expected-remote-body new-doc)))))

(defun gdocs--make-push-intent
    (state local-body expected-body replan &optional label)
  "Create an intent that can be replanned after a remote refetch."
  (list :gdocs-push-intent t
        :local-body local-body
        :expected-body (gdocs--push-comparison-body expected-body)
        :expected-revision (plist-get state :revision)
        :replan replan
        :label label))

(defun gdocs--push-intent-p (value)
  "Return non-nil when VALUE is a high-level push intent."
  (and (listp value) (plist-get value :gdocs-push-intent)))

(defun gdocs--push-plan-for-intent (intent state remote-body)
  "Call INTENT's planner and annotate its current pre-operation snapshot."
  (let* ((body (gdocs--push-comparison-body remote-body))
         (expected (plist-get intent :expected-body))
         (plan (funcall (plist-get intent :replan) state body)))
    (unless (and plan
                 (or (plist-get plan :post-body)
                     (eq (plist-get plan :kind) :raw)))
      (user-error "gdocs: high-level push intent produced no operation"))
    (unless (or (null expected) (string= body expected))
      (user-error "gdocs: remote body changed before replanning"))
    (setq plan (plist-put plan :pre-body body))
    (setq plan (plist-put plan :pre-revision (plist-get state :revision)))
    ;; A /save batch advances the document revision once.  Keeping this
    ;; expected value lets throttle verification reject a body that happens
    ;; to look like our target but also contains an unrelated intervening
    ;; revision.
    (setq plan
          (plist-put
           plan :post-revision
           (gdocs--push-next-revision (plist-get state :revision))))
    plan))

(defun gdocs--push-preflight-plan (intent state plan)
  "Run the capability preflight required for PLAN on current STATE."
  (let ((kind (plist-get plan :kind))
        (local-body (or (plist-get intent :local-body)
                        (plist-get plan :post-body))))
    (pcase kind
      (:insert
       (gdocs--push-preflight-insertion
        state (plist-get plan :ot-start) (plist-get plan :inserted)))
      (:delete
       ;; Deletion is the destructive step.  Re-run the complete range-aware
       ;; analysis immediately before every ds, including after a retry.
       (gdocs--push-preflight
        state local-body (plist-get plan :preflight-plan)))
      ((or :incremental :full-replace :noop)
       (gdocs--push-preflight state local-body plan))
      (_
       (user-error "gdocs: operation plan has no capability preflight")))))

(defun gdocs--make-raw-push-intent (state op)
  "Wrap a legacy raw OP without pretending it is safely replayable.

Callers should use a real high-level intent.  This compatibility wrapper is
kept for low-level users, but an ambiguous save cannot be retried because no
expected post-operation body is available."
  (list :gdocs-push-intent :raw
        :local-body nil
        :expected-body nil
        :expected-revision (plist-get state :revision)
        :replan (lambda (_state _body)
                  (list :kind :raw :op op))))

(defun gdocs--push-plan-commands (plan)
  "Return the save command list represented by PLAN."
  (or (plist-get plan :commands)
      (let ((op (plist-get plan :op)))
        (and op (list op)))))

(defun gdocs--push-classify-refetched-state (doc-id state plan &optional body-only)
  "Classify a refetched STATE relative to failed PLAN.

Return `:committed' when the post-operation body is visible, `:retry' when
the pre-operation state is still present, `:conflict' for an unrelated
change, and `:unknown' when the state cannot be decoded.  When BODY-ONLY is
non-nil, classify an unexpected successful response solely from the fresh
body: the post-body confirms the save and the pre-body proves it uncommitted."
  (if (eq (plist-get plan :kind) :raw)
      :unknown
    (let ((body (gdocs--push-state-body doc-id state))
          (pre-body (plist-get plan :pre-body))
          (post-body (plist-get plan :post-body))
          (pre-rev (plist-get plan :pre-revision))
          (post-rev (plist-get plan :post-revision))
          (fresh-rev (and state (plist-get state :revision))))
      (cond
       ((or (null body) (and body-only (string= pre-body post-body))) :unknown)
       ((and body-only (string= body post-body)) :committed)
       ((and body-only (string= body pre-body)) :retry)
       ((and (string= body post-body)
             fresh-rev
             (if post-rev
                 (gdocs--push-revisions-equal-p fresh-rev post-rev)
               (not (gdocs--push-revisions-equal-p fresh-rev pre-rev))))
        :committed)
       ((and (string= body pre-body)
             (gdocs--push-revisions-equal-p fresh-rev pre-rev))
        :retry)
       ((and (string= body post-body)
             (gdocs--push-revisions-equal-p fresh-rev pre-rev))
        :unknown)
       (t :conflict)))))

(defun gdocs--push-save-outcome-error (outcome failure retryable attempt)
  "Signal a safe error for a reconciled failed save.

OUTCOME is from `gdocs--push-classify-refetched-state'.  FAILURE describes
the original transport or response failure.  RETRYABLE is non-nil only for
an explicit retry policy such as the bounded throttle retry."
  (pcase outcome
    (:conflict
     (user-error
      "gdocs: ambiguous save outcome after %s; conflict with remote content or revision"
      failure))
    (:unknown
     (user-error "gdocs: ambiguous save outcome after %s; refusing to replay"
                 failure))
    (:retry
     (if retryable
         (user-error
          "gdocs: /save remained throttled after %d attempts; no operation was committed"
          attempt)
       (user-error "gdocs: save was not committed: %s" failure)))
    (_
     (user-error "gdocs: unable to establish save outcome after %s" failure))))

(defun gdocs--push-throttle-outcome-error (outcome attempt)
  "Compatibility wrapper for a failed throttle outcome."
  (gdocs--push-save-outcome-error outcome "throttle rejection" t attempt))

(defun gdocs--push-verify-state (doc-id state expected-body expected-revision)
  "Verify that STATE is exactly the expected post-operation snapshot."
  (unless state
    (user-error "gdocs: state refetch failed while verifying committed operation"))
  (let ((actual-body (gdocs--push-state-body doc-id state))
        (actual-revision (plist-get state :revision)))
    (unless (and actual-body
                 (string= actual-body
                          (gdocs--push-comparison-body expected-body)))
      (user-error "gdocs: state refetch found unexpected remote content"))
    (unless (gdocs--push-revisions-equal-p actual-revision expected-revision)
      (user-error "gdocs: state refetch saw rev %S, expected %S"
                  actual-revision expected-revision))
    t))

(defun gdocs--save-revision-value (value)
  "Return VALUE as a non-negative integer revision, or nil."
  (cond
   ((and (integerp value) (>= value 0)) value)
   ((and (stringp value) (string-match-p "\\`[0-9]+\\'" value))
    (string-to-number value))
   (t nil)))

(defun gdocs--save-response-revision (response plan)
  "Return PLAN's post-revision when RESPONSE acknowledges exactly that save.

The terminal endpoint of `revisionRanges' is the revision the save
created and must equal PLAN's post-revision.  `serverRevision' is the
revision the server applied the save on top of, one below it; earlier
responses of the editors frontend reported the post-revision there
instead, which is still accepted.  Without `revisionRanges' only that
older shape identifies the save, so `serverRevision' must equal the
post-revision.  Missing, malformed, disagreeing, lower, or higher values
signal an error so the caller reconciles against fresh content."
  (let* ((expected (gdocs--save-revision-value
                    (plist-get plan :post-revision)))
         (metadata-cell (and (listp response) (assq 'metadata response)))
         (metadata (and metadata-cell (cdr metadata-cell)))
         (server-cell (and (listp metadata)
                           (assq 'serverRevision metadata)))
         (ranges-cell (and (listp response)
                           (assq 'revisionRanges response)))
         (ranges (and ranges-cell (cdr ranges-cell)))
         (last-range (and (listp ranges) (car (last ranges))))
         (range-rev-cell (and (listp last-range) (car (last last-range))))
         (server-rev (and server-cell
                          (gdocs--save-revision-value (cdr server-cell))))
         (range-rev (and ranges-cell
                         (gdocs--save-revision-value range-rev-cell))))
    (unless (and expected
                 (or server-cell ranges-cell)
                 (or (null server-cell) server-rev)
                 (or (null ranges-cell) range-rev)
                 (if ranges-cell
                     (and (= range-rev expected)
                          (or (null server-cell)
                              (= server-rev expected)
                              (= server-rev (1- expected))))
                   (= server-rev expected)))
      (user-error "gdocs: /save revision metadata did not exactly match expected rev %S"
                  (plist-get plan :post-revision)))
    expected))

(defun gdocs--save-response-xsrf-token (response)
  "Return the rotated XSRF token carried by an HTTP 200 RESPONSE.

When another client (for example an open browser tab auto-saving the
same document) consumed the session's save token, the server answers 200
with an `er' entry of the shape [\"er\" \"XSRF\" nil nil NEW-TOKEN 200 …]
and no revision metadata.  The save is NOT committed; the new token is
the current one and the request may be retried with it."
  (when (listp response)
    (let* ((er-cell (seq-find
                     (lambda (entry)
                       (and (listp entry) (equal (car entry) "er")
                            (equal (nth 1 entry) "XSRF")
                            (stringp (nth 4 entry))))
                     response)))
      (and er-cell (nth 4 er-cell)))))

(defun gdocs--async-throttle-error-p (err)
  "Return non-nil when async ERR has the structured throttle shape."
  (and (listp err)
       (= (or (plist-get err :http-code) 0) 550)
       (= (or (plist-get err :err-code) 0) 13)
       (plist-get err :di)))

(defun gdocs--run-op-result-async-verify-save
    (doc-id plan delay callback &optional body-only)
  "Refetch after a failed save and callback with `(OUTCOME STATE ERR)'."
  (let (done verify)
    (cl-labels
        ((finish (outcome state err)
           (unless done
             (setq done t)
             (funcall callback outcome state err))))
      (setq verify
            (lambda ()
              (unless done
                (condition-case setup-sig
                    (gdocs--fetch-edit-state-async
                     doc-id
                     (lambda (fresh-state state-err)
                       (if state-err
                           (finish nil nil
                                   (format "state refetch failed: %s"
                                           state-err))
                         (condition-case sig
                             (finish
                              (gdocs--push-classify-refetched-state
                               doc-id fresh-state plan body-only)
                              fresh-state nil)
                           (error
                            (finish nil nil
                                    (error-message-string sig)))))))
                  (error
                   (finish nil nil (error-message-string setup-sig)))))))
      (condition-case timer-sig
          (if (> delay 0)
              (run-with-timer
               delay nil
               (lambda ()
                 (condition-case sig
                     (funcall verify)
                   (error
                    (finish nil nil (error-message-string sig))))))
            (funcall verify))
        (error
         (finish nil nil (error-message-string timer-sig)))))))

(defun gdocs--run-op-result-async-handle-failure
    (doc-id intent plan callback attempt failure retryable
            outcome fresh-state verify-err)
  "Handle a classified post-dispatch async save failure."
  (cond
   (verify-err
    (funcall callback nil
             (format "gdocs: ambiguous save outcome after %s; %s"
                     failure verify-err)))
   ((eq outcome :committed)
    (funcall callback
             (list :revision (plist-get fresh-state :revision)
                   :state fresh-state
                   :plan plan)
             nil))
   ((and retryable (eq outcome :retry) (< attempt 5))
    ;; The replanner sees FRESH-STATE; PLAN and its positional operation are
    ;; never replayed.  Throttles and rotated smb/token races (400/err 3)
    ;; recover by replanning against the refetched state.
    (gdocs--run-op-result-async-step
     doc-id fresh-state intent callback (1+ attempt)))
   (t
    (condition-case sig
        (gdocs--push-save-outcome-error
         outcome failure retryable attempt)
      (error
       (funcall callback nil (error-message-string sig)))))))

(defun gdocs--run-op-result-async-reconcile
    (doc-id intent plan callback attempt failure retryable &optional body-only)
  "Reconcile a post-dispatch FAILURE against a fresh remote snapshot."
  (gdocs--run-op-result-async-verify-save
   doc-id plan (if retryable gdocs--rate-limit-retry-delay 0)
   (lambda (outcome fresh-state verify-err)
     (gdocs--run-op-result-async-handle-failure
      doc-id intent plan callback attempt failure retryable
      outcome fresh-state verify-err))
   body-only))

(defun gdocs--run-op-result-async-save-callback
    (doc-id state intent plan callback attempt response err)
  "Process one async save response for PLAN."
  (condition-case sig
      (cond
       ((null err)
        (let ((xsrf-token (gdocs--save-response-xsrf-token response)))
          (cond
           ;; Another client consumed the save token; the server rotated it.
           ;; Retry the whole intent with the rotated token — the save never
           ;; committed, so the plan replans against the unchanged body.
           ((and xsrf-token (< attempt 5))
            (gdocs-log
             'info
             "/save token rotated by a concurrent client (attempt %d); retrying"
             attempt)
            (gdocs--run-op-result-async-step
             doc-id (plist-put (copy-sequence state) :token xsrf-token)
             intent callback (1+ attempt)))
           ((and xsrf-token (>= attempt 5))
            (funcall callback nil "gdocs: /save token kept rotating; giving up"))
           (t
            (condition-case revision-sig
                (funcall
                 callback
                 (list :revision (gdocs--save-response-revision response plan)
                       :state state
                       :plan plan)
                 nil)
              (error
               (gdocs--run-op-result-async-reconcile
                doc-id intent plan callback attempt
                (error-message-string revision-sig) nil t)))))))
       (t
        (let* ((retryable (or (gdocs--async-throttle-error-p err)
                              ;; The current frontend rejects a save whose
                              ;; smb segment or token was rotated by a
                              ;; concurrent page load (every /edit fetch
                              ;; rotates them) with 400/err 3. Refetching
                              ;; the full state and retrying is the same
                              ;; recovery the browser performs.
                              (and (listp err)
                                   (= (or (plist-get err :http-code) 0) 400)
                                   (= (or (plist-get err :err-code) 0) 3))))
               (failure
                (if (listp err)
                    (format "/save rejected (http %s err %s)"
                            (plist-get err :http-code)
                            (plist-get err :err-code))
                  (format "%s" err))))
          (when retryable
            (gdocs-log
             'warn
             "/save rejected (attempt %d), refetching state and retrying"
             attempt))
          (gdocs--run-op-result-async-reconcile
           doc-id intent plan callback attempt failure retryable))))
    (error
     (funcall callback nil (error-message-string sig)))))

(defun gdocs--run-op-result-async-step
    (doc-id state intent callback attempt)
  "Execute one async intent attempt; CALLBACK is already once-wrapped."
  (let ((prepared
         (condition-case sig
             (let* ((current-body
                     (or (gdocs--push-state-body doc-id state)
                         (plist-get intent :expected-body)))
                    (plan (gdocs--push-plan-for-intent
                           intent state current-body))
                    (commands (gdocs--push-plan-commands plan)))
               (unless (and state commands)
                 (user-error "gdocs: cannot send operation without a current state"))
               (unless (eq (plist-get plan :kind) :raw)
                 (gdocs--push-preflight-plan intent state plan))
               (list plan commands))
           (error (list :error (error-message-string sig))))))
    (if (plist-get prepared :error)
        (funcall callback nil (plist-get prepared :error))
      (let ((plan (car prepared))
            (commands (cadr prepared)))
        (condition-case sig
            (gdocs--save-request-async
             doc-id state commands
             (lambda (response err)
               (gdocs--run-op-result-async-save-callback
                doc-id state intent plan callback attempt response err)))
          (error
           (funcall callback nil (error-message-string sig))))))))

(defun gdocs--run-op-result-async
    (doc-id state intent callback &optional attempt)
  "Run high-level INTENT asynchronously and return a result plist.

CALLBACK receives `(RESULT ERR)'.  Every operation plan is rebuilt from the
state used for its save request.  A throttled request is first classified by
refetching the remote body: a visible post-body means the original request
committed, the exact pre-state permits one freshly planned retry, and every
other outcome fails closed."
  (let ((done nil))
    (gdocs--run-op-result-async-step
     doc-id state intent
     (lambda (result err)
       (unless done
         (setq done t)
         (funcall callback result err)))
     (or attempt 1))))

(defun gdocs--run-op-async (doc-id state op callback &optional attempt)
  "Compatibility wrapper for `gdocs--run-op-result-async'.

Raw OP values are accepted for low-level callers, but they are deliberately
not retryable after an ambiguous save.  Push code passes a high-level intent
instead and receives the same `(NEW-REV ERR)' callback shape."
  (let ((intent (if (gdocs--push-intent-p op)
                    op
                  (gdocs--make-raw-push-intent state op))))
    (gdocs--run-op-result-async
     doc-id state intent
     (lambda (result err)
       (funcall callback (and result (plist-get result :revision)) err))
     attempt)))

(defun gdocs--finalize-push-props (new-rev local-body)
  "Write GDOC_REVISION / hash / synced-at on the current buffer.
Caller must already be inside `with-current-buffer'."
  (let ((committed-hash (secure-hash 'sha256 local-body)))
    (gdocs--put-top-property "GDOC_REVISION" (format "%s" new-rev))
    (gdocs--put-top-property "GDOC_CONTENT_HASH" committed-hash)
    (gdocs--put-top-property "GDOC_SYNCED_AT" (gdocs--now-iso))
    (gdocs--mark-synced committed-hash)))

(defun gdocs--apply-in-place-region-result-async
    (doc-id state remote-body region buffer local-body callback)
  "Apply REGION asynchronously and callback with `(RESULT ERR)'.

The delete and insert stages each build an intent from the current body.  A
successful stage is refetched and verified before the next stage is planned,
so the insertion position is never copied from the delete plan."
  (let ((done nil)
        (committed-rev nil)
        (initial-body (gdocs--push-comparison-body remote-body))
        (target-body (gdocs--push-comparison-body
                      (or local-body
                          (gdocs--push-apply-region-body
                           (gdocs--push-comparison-body remote-body)
                           region)))))
    (cl-labels
        ((finish (result err)
           (unless done
             (setq done t)
             (funcall callback result err)))
         (run-stage (stage stage-state stage-body selector)
           (let ((intent
                  (gdocs--make-push-intent
                   stage-state local-body stage-body
                   (lambda (fresh-state fresh-body)
                     (gdocs--push-region-plan
                      fresh-state fresh-body target-body selector stage))
                   (format "region-%s" stage))))
             (gdocs--run-op-result-async
              doc-id stage-state intent
              (lambda (op-result op-err)
                (condition-case callback-sig
                    (if op-err
                        (finish (or op-result
                                    (and committed-rev
                                         (list :revision committed-rev)))
                                op-err)
                      (let* ((plan (plist-get op-result :plan))
                             (rev (plist-get op-result :revision))
                             (post-body (plist-get plan :post-body))
                             (deleted (plist-get plan :deleted))
                             (inserted (plist-get plan :inserted))
                             (ot-start (plist-get plan :ot-start)))
                        (setq committed-rev rev)
                        (when (and rev (buffer-live-p buffer))
                          (with-current-buffer buffer
                            (gdocs--shift-buffer-anchors
                             (if (eq stage :delete) 'ds 'is)
                             ot-start
                             (length (if (eq stage :delete)
                                         deleted
                                       inserted)))
                            ;; This is a committed stage revision, not
                            ;; the final push baseline.  Do not write the
                            ;; content hash until every stage succeeds.
                            (gdocs--put-top-property
                             "GDOC_REVISION" (number-to-string rev))))
                        (condition-case setup-sig
                            (gdocs--fetch-edit-state-async
                             doc-id
                             (lambda (fresh-state state-err)
                               (condition-case verify-sig
                                   (if state-err
                                       (finish op-result state-err)
                                     (gdocs--push-verify-state
                                      doc-id fresh-state post-body rev)
                                     (let ((fresh-body
                                            (gdocs--push-state-body
                                             doc-id fresh-state)))
                                       (if (and (eq stage :delete)
                                                (length> inserted 0))
                                           (run-stage
                                            :insert
                                            fresh-state
                                            fresh-body
                                            (list :start
                                                  (plist-get
                                                   (plist-get plan :region)
                                                   :start)
                                                  :deleted ""
                                                  :inserted inserted))
                                         (finish
                                          (list :revision rev
                                                :state fresh-state
                                                :body fresh-body
                                                :plan plan)
                                          nil))))
                                 (error
                                  (finish
                                   op-result
                                   (error-message-string verify-sig))))))
                          (error
                           (finish op-result
                                   (error-message-string setup-sig))))))
                  (error
                   (finish nil (error-message-string callback-sig)))))))))
      ;; The selector is content-based.  It is only used to choose the same
      ;; high-level region after a retry; the current diff supplies positions.
      (run-stage (if (length> (or (plist-get region :deleted) "") 0)
                     :delete
                   :insert)
                 state initial-body
                 (gdocs--push-region-selector region)))))

(defun gdocs--apply-in-place-region-async
    (doc-id state remote-body region buffer callback &optional local-body)
  "Async sibling of `gdocs--apply-in-place-region'."
  (gdocs--apply-in-place-region-result-async
   doc-id state remote-body region buffer local-body
   (lambda (result err)
     (funcall callback (and result (plist-get result :revision)) err))))

(defun gdocs--multi-regions-refetch-async
    (doc-id current-state expected-body callback)
  "Refetch and verify the boundary before another multi-region operation."
  (gdocs--fetch-edit-state-async
   doc-id
   (lambda (fresh-state state-err)
     (if state-err
         (funcall callback nil state-err)
       (condition-case sig
           (progn
             (gdocs--push-verify-state
              doc-id fresh-state expected-body
              (plist-get current-state :revision))
             (funcall callback fresh-state nil))
         (error
          (funcall callback nil (error-message-string sig))))))))

(defun gdocs--apply-multi-regions-async
    (doc-id state remote-body regions buffer callback &optional local-body)
  "Apply latest-first regions, rebuilding and verifying after every stage."
  (let ((done nil)
        (target-body (gdocs--push-comparison-body
                      (or local-body
                          (gdocs--push-target-body-from-regions
                           remote-body regions))))
        (remaining (length regions))
        (current-state state)
        (current-body (gdocs--push-comparison-body remote-body))
        (last-rev nil))
    (cl-labels
        ((finish (rev err)
           (unless done
             (setq done t)
             (funcall callback rev err)))
         (step ()
           (if (zerop remaining)
               (finish last-rev nil)
             (let ((prepared
                    (condition-case sig
                        (let* ((fresh-regions
                                (gdocs--push-region-list
                                 current-body target-body))
                               ;; Always take the latest position from the
                               ;; freshly computed diff.  `regions' is only
                               ;; the count captured before the first op.
                               (region (car (last fresh-regions))))
                          (unless region
                            (user-error
                             "gdocs: remaining multi-region plan disappeared"))
                          (list region))
                      (error (list :error (error-message-string sig))))))
               (if (plist-get prepared :error)
                   (finish last-rev (plist-get prepared :error))
                 (gdocs--apply-in-place-region-result-async
                  doc-id current-state current-body (car prepared)
                  buffer local-body
                  (lambda (result err)
                    (if err
                        (finish (or (and result
                                         (plist-get result :revision))
                                    last-rev)
                                err)
                      (setq last-rev (plist-get result :revision)
                            current-state (plist-get result :state)
                            current-body (plist-get result :body))
                      (cl-decf remaining)
                      (if (zerop remaining)
                          (finish last-rev nil)
                        (condition-case timer-sig
                            (run-with-timer
                             gdocs--inter-region-delay nil
                             (lambda ()
                               (unless done
                                 (condition-case setup-sig
                                     (gdocs--multi-regions-refetch-async
                                      doc-id current-state current-body
                                      (lambda (fresh-state refetch-err)
                                        (condition-case callback-sig
                                            (if refetch-err
                                                (finish last-rev refetch-err)
                                              (setq current-state fresh-state
                                                    current-body
                                                    (gdocs--push-state-body
                                                     doc-id fresh-state))
                                              (step))
                                          (error
                                           (finish
                                            last-rev
                                            (error-message-string
                                             callback-sig))))))
                                   (error
                                    (finish last-rev
                                            (error-message-string
                                             setup-sig)))))))
                          (error
                           (finish last-rev
                                   (error-message-string timer-sig)))))))))))))
      (if (zerop remaining)
          (finish nil nil)
        (step)))))

(defun gdocs--push-verify-and-finalize-async
    (doc-id initial result backend command-count finalize)
  "Verify a committed save by refetching DOC-ID, then call FINALIZE.

INITIAL is the full push plan (its `:post-body' is the expected round-trip
render); RESULT is the save result plist with `:revision'.  BACKEND and
COMMAND-COUNT describe the completed operation for the log line.  FINALIZE
is `gdocs--apply-push-async''s one-shot finisher, called as
`(funcall FINALIZE REV ERR EXTRA)'."
  (gdocs--fetch-edit-state-async
   doc-id
   (lambda (fresh-state v-err)
     (let ((v-failure
            (or v-err
                (condition-case sig
                    (progn
                      (gdocs--push-verify-state
                       doc-id fresh-state
                       (plist-get initial :post-body)
                       (plist-get result :revision))
                      nil)
                  (error (error-message-string sig))))))
       (funcall finalize
                (plist-get result :revision)
                v-failure
                (if v-failure
                    (format ", %s (%d ops, verification failed)"
                            backend command-count)
                  (format ", %s (%d ops, verified)"
                          backend command-count)))))))

(defun gdocs--apply-push-async
    (doc-id state local-body remote-body buffer callback)
  "Async sibling of `gdocs--apply-push'.
CALLBACK is called exactly once as `(funcall CALLBACK NEW-REV ERR)'.
Planning and preflight refusals call it before any transport with NEW-REV nil
and a sanitized error string.  Transport success and failure retain their
reported revision semantics.  BUFFER is where property writes go."
  (let ((done nil))
    (cl-labels
        ((finish (rev err)
           (unless done
             (setq done t)
             (funcall callback rev err)))
         (finalize (rev err extra)
           ;; A committed intermediate stage may report REV with ERR.  It is
           ;; already recorded by the region helper, but it is not a
           ;; successful push baseline and must not receive a content hash.
           (when (and rev (null err) (buffer-live-p buffer))
             (with-current-buffer buffer
               (gdocs--finalize-push-props rev local-body)))
           (when (and rev (null err))
             (gdocs-log 'info "Pushed %s (rev %s)%s"
                        doc-id rev (or extra "")))
           (finish rev err)))
      (let ((initial
             (condition-case sig
                 (let* ((raw-plan
                         (gdocs--push-plan-for-diff
                          state local-body remote-body))
                        ;; Direct callers historically required an image guard
                        ;; even for a synthetic no-op.
                        (preflight-plan
                         (if (eq (plist-get raw-plan :kind) :noop)
                             (list :kind :full-replace)
                           raw-plan))
                        (local-stripped
                         (gdocs--push-comparison-body local-body))
                        (remote-mappable
                         (gdocs--push-comparison-body remote-body)))
                   (gdocs--push-preflight state local-body preflight-plan)
                   (list local-stripped remote-mappable
                         (plist-get state :ot-body)))
               ((user-error error)
                (finish nil (error-message-string sig))
                nil))))
        (when initial
          (let* ((local-stripped (nth 0 initial))
                 (remote-mappable (nth 1 initial))
                 (ot-body (nth 2 initial))
                 (prepended
                  (gdocs--diff-prepend remote-mappable local-stripped))
                 (appended
                  (gdocs--diff-append remote-mappable local-stripped)))
            (cond
             ;; Content that already matches remote — directly or after the
             ;; canonical round-trip render (Org keyword case and padding) —
             ;; needs no save at all.
             ((or (string= local-stripped remote-mappable)
                  (string= remote-mappable
                           (gdocs--push-comparison-body
                            (gdocs--push-expected-remote-body
                             (gdocs-dm-from-org local-body)))))
              (finalize (plist-get state :revision) nil
                        ", no changes (content matches remote)"))
             ;; Full OT bundles use the same intent engine.  A throttle is only
             ;; retryable when the exact target body can be observed or the
             ;; exact pre-state is still present for a fresh command rebuild.
             ((memq gdocs-push-backend '(ot-encode ot-incremental))
              (let* ((backend gdocs-push-backend)
                     (initial (gdocs--push-full-plan
                               doc-id state local-body backend))
                     (commands (gdocs--push-plan-commands initial)))
                (if (null commands)
                    (finalize (plist-get state :revision) nil
                              (format ", %s (0 ops)" backend))
                  (let ((intent
                         (gdocs--make-push-intent
                          state local-body remote-mappable
                          (lambda (fresh-state _fresh-body)
                            (gdocs--push-full-plan
                             doc-id fresh-state local-body backend))
                          (format "%s" backend))))
                    (gdocs--run-op-result-async
                     doc-id state intent
                     (lambda (result err)
                       (cond
                        ((or err (null result) (not gdocs-verify-after-save))
                         (finalize (and result (plist-get result :revision))
                                   err
                                   (format ", %s (%d ops)"
                                           backend (length commands))))
                        ;; Read-after-write verification: a committed save
                        ;; is only reported as success when a fresh refetch
                        ;; decodes to the expected round-trip body.
                        (t
                         (gdocs--push-verify-and-finalize-async
                          doc-id initial result backend
                          (length commands) #'finalize)))))))))
             (prepended
              (let ((intent
                     (gdocs--make-push-intent
                      state local-body remote-mappable
                      (lambda (fresh-state fresh-body)
                        (gdocs--push-insert-plan
                         fresh-state fresh-body prepended :prepend))
                      "prepend")))
                (gdocs--run-op-result-async
                 doc-id state intent
                 (lambda (result err)
                   (when (and result (null err) (buffer-live-p buffer))
                     (with-current-buffer buffer
                       (gdocs--shift-buffer-anchors
                        'is (plist-get (plist-get result :plan) :ot-start)
                        (length prepended))))
                   (finalize (and result (plist-get result :revision))
                             err
                             (format ", +%d prepended chars"
                                     (length prepended)))))))
             ((and appended ot-body)
              (let ((intent
                     (gdocs--make-push-intent
                      state local-body remote-mappable
                      (lambda (fresh-state fresh-body)
                        (gdocs--push-insert-plan
                         fresh-state fresh-body appended :append))
                      "append")))
                (gdocs--run-op-result-async
                 doc-id state intent
                 (lambda (result err)
                   (finalize (and result (plist-get result :revision))
                             err
                             (format ", +%d appended chars"
                                     (length appended)))))))
             (ot-body
              (let* ((para-regions
                      (gdocs--diff-paragraphs remote-mappable local-stripped))
                     (n-regions (length para-regions)))
                (cond
                 ((or (zerop n-regions) (= n-regions 1))
                  (let ((single (gdocs--diff-single-region
                                 remote-mappable local-stripped)))
                    (if single
                        (gdocs--apply-in-place-region-result-async
                         doc-id state remote-mappable single buffer local-body
                         (lambda (result err)
                           (finalize (and result (plist-get result :revision))
                                     err nil)))
                      (finish nil nil))))
                 (t
                  (gdocs--apply-multi-regions-async
                   doc-id state remote-mappable
                   (nreverse (copy-sequence para-regions)) buffer
                   (lambda (rev err) (finalize rev err nil))
                   local-body)))))
             (t
              (finish nil
                      "edit shape not yet supported (non-contiguous diff, or change crosses table/list structure)")))))))))



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
Returns t if a session was loaded, nil if the file was absent, unreadable
or held a SID that `gdocs--session-sid-valid-p' rejects."
  (when (file-readable-p gdocs-session-file)
    (condition-case _
        (with-temp-buffer
          (insert-file-contents gdocs-session-file)
          (let ((data (read (current-buffer))))
            ;; A SID persisted by an earlier version may have its top bit
            ;; set; the endpoint refuses such a SID, so a new one is made.
            (when (and (gdocs--session-sid-valid-p (plist-get data :sid))
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

(defun gdocs--session-sid-valid-p (sid)
  "Return non-nil when SID is a session id the /save endpoint accepts.
A SID is 16 lowercase hex digits read as a signed 64-bit integer, so it
must be below 2^63: the endpoint answers a SID whose top bit is set with
HTTP 550/err 13 on its first save, and keeps refusing that SID on every
later save."
  (and (stringp sid)
       (let ((case-fold-search nil))
         (string-match-p "\\`[0-7][0-9a-f]\\{15\\}\\'" sid))))

(defun gdocs--session-new-sid ()
  "Return a random session id that `gdocs--session-sid-valid-p' accepts."
  (format "%016x"
          (logior (ash (random (expt 2 31)) 32)
                  (random (expt 2 32)))))

(defun gdocs--session-ensure ()
  "Make sure `gdocs--session-sid' / `gdocs--session-req-id' are populated.
Loads from disk on first call; generates a fresh SID if no file exists."
  (unless (and gdocs--session-sid gdocs--session-req-id)
    (or (gdocs--session-load-from-disk)
        (progn
          (setq gdocs--session-sid (gdocs--session-new-sid))
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
  (and (consp err)
       (eq (car err) 'gdocs-save-rejected)
       (let ((data (cdr err)))
         (and (= (or (plist-get data :http-code) 0) 550)
              (= (or (plist-get data :err-code) 0) 13)
              (plist-get data :di)))))

(defun gdocs--run-op-result (doc-id state intent-or-op)
  "Run a high-level push intent synchronously and return a result plist.

The result contains `:revision', `:state', and the exact freshly planned
`:plan' used for the successful save.  On a throttle, the refetched state is
classified before any retry.  Only an exact unchanged pre-state is retryable;
the retry calls the intent's replanner and therefore cannot reuse a stale OT
operation."
  (let* ((intent (if (gdocs--push-intent-p intent-or-op)
                     intent-or-op
                   (gdocs--make-raw-push-intent state intent-or-op)))
         (current-state state)
         (attempt 0)
         (result nil))
    (while (and (null result) (< attempt 2))
      (cl-incf attempt)
      (let* ((current-body
              (or (gdocs--push-state-body doc-id current-state)
                  (plist-get intent :expected-body)))
             (plan (gdocs--push-plan-for-intent
                    intent current-state current-body))
             (commands (gdocs--push-plan-commands plan)))
        (unless (and current-state commands)
          (user-error "gdocs: cannot send operation without a current state"))
        (unless (eq (plist-get plan :kind) :raw)
          ;; This runs for every planned attempt, including a retry.
          (gdocs--push-preflight-plan intent current-state plan))
        (cl-labels
            ((reconcile (failure retryable &optional body-only)
               (when retryable
                 (gdocs-log
                  'warn
                  "/save rejected (err 13, di %s) attempt %d, verifying in %ds"
                  (plist-get (cdr failure) :di) attempt
                  gdocs--rate-limit-retry-delay)
                 (sleep-for gdocs--rate-limit-retry-delay))
               (let ((fresh-state
                      (condition-case fetch-sig
                          (gdocs--fetch-edit-state doc-id)
                        (error
                         (user-error
                          "gdocs: ambiguous save outcome after %s; state refetch failed: %s"
                          (error-message-string failure)
                          (error-message-string fetch-sig))))))
                 (pcase (gdocs--push-classify-refetched-state
                         doc-id fresh-state plan body-only)
                   (:committed
                    (setq result
                          (list :revision (plist-get fresh-state :revision)
                                :state fresh-state
                                :plan plan)))
                   (:retry
                    (if (and retryable (< attempt 2))
                        (setq current-state fresh-state)
                      (gdocs--push-save-outcome-error
                       :retry (error-message-string failure)
                       retryable attempt)))
                   (outcome
                    (gdocs--push-save-outcome-error
                     outcome (error-message-string failure)
                     retryable attempt))))))
          (condition-case err
              (let ((response
                     (gdocs--save-request doc-id current-state commands)))
                (condition-case revision-sig
                    (setq result
                          (list :revision
                                (gdocs--save-response-revision response plan)
                                :state current-state
                                :plan plan))
                  (error (reconcile revision-sig nil t))))
            ((gdocs-save-rejected gdocs-save-post-dispatch-failed)
             (reconcile err (gdocs--throttle-error-p err)))))))
    result))

(defun gdocs--run-op (doc-id state op-or-intent)
  "Send OP-OR-INTENT synchronously and return its committed revision.

High-level intents are replanned after every refetch.  A legacy raw operation
is accepted for compatibility but cannot be replayed after an ambiguous save."
  (plist-get (gdocs--run-op-result doc-id state op-or-intent) :revision))

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

(defun gdocs--apply-in-place-region-result
    (doc-id state remote-body region &optional local-body)
  "Synchronously apply REGION and return a detailed result plist.

Each stage is planned from the state it sends against, then refetched and
verified before the next stage.  LOCAL-BODY is the complete desired Org body
used for capability preflight; when omitted, REGION itself supplies the
desired body for compatibility with low-level callers."
  (let* ((initial-body (gdocs--push-comparison-body remote-body))
         (target-body
          (gdocs--push-comparison-body
           (or local-body
               (gdocs--push-apply-region-body initial-body region))))
         (initial-selector (gdocs--push-region-selector region)))
    (cl-labels
        ((run-stage (stage stage-state stage-body selector)
           (let* ((intent
                   (gdocs--make-push-intent
                    stage-state local-body stage-body
                    (lambda (fresh-state fresh-body)
                      (gdocs--push-region-plan
                       fresh-state fresh-body target-body selector stage))))
                  (operation (gdocs--run-op-result
                              doc-id stage-state intent))
                  (plan (plist-get operation :plan))
                  (rev (plist-get operation :revision))
                  (post-body (plist-get plan :post-body)))
             (when rev
               (gdocs--shift-buffer-anchors
                (if (eq stage :delete) 'ds 'is)
                (plist-get plan :ot-start)
                (length (if (eq stage :delete)
                            (plist-get plan :deleted)
                          (plist-get plan :inserted))))
               ;; This revision belongs to a committed stage.  The final
               ;; content hash is written only by the outer successful push.
               (gdocs--put-top-property "GDOC_REVISION"
                                        (number-to-string rev)))
             (let ((fresh-state (gdocs--fetch-edit-state doc-id)))
               (gdocs--push-verify-state
                doc-id fresh-state post-body rev)
               (list :operation operation
                     :state fresh-state
                     :body (gdocs--push-state-body doc-id fresh-state)
                     :plan plan)))))
      (let* ((deleted (or (plist-get region :deleted) ""))
             (inserted (or (plist-get region :inserted) ""))
             (first
              (if (length> deleted 0)
                  (run-stage :delete state initial-body initial-selector)
                (run-stage :insert state initial-body initial-selector)))
             (first-operation (plist-get first :operation))
             (first-plan (plist-get first :plan))
             (final
              (if (and (length> deleted 0) (length> inserted 0))
                  (run-stage
                   :insert
                   (plist-get first :state)
                   (plist-get first :body)
                   (list :start (plist-get (plist-get first-plan :region)
                                           :start)
                         :deleted ""
                         :inserted inserted))
                first))
             (operation (plist-get final :operation))
             (plan (plist-get final :plan))
             (rev (plist-get operation :revision)))
        (gdocs-log 'info
                   "Pushed %s (rev %s, edited %d→%d chars at OT %d)"
                   doc-id rev (length deleted) (length inserted)
                   (plist-get plan :ot-start))
        (list :revision rev
              :state (plist-get final :state)
              :body (plist-get final :body)
              :plan plan
              :previous (and (not (eq first final)) first-operation))))))

(defun gdocs--apply-in-place-region
    (doc-id state remote-body region &optional local-body)
  "Apply ONE in-place change REGION and return `(NEW-REV . NEW-STATE)'."
  (let ((result (gdocs--apply-in-place-region-result
                 doc-id state remote-body region local-body)))
    (cons (plist-get result :revision)
          (plist-get result :state))))

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
  (let* ((raw-plan (gdocs--push-plan-for-diff state local-body remote-body))
         (plan (if (eq (plist-get raw-plan :kind) :noop)
                   (list :kind :full-replace)
                 raw-plan))
         (local-stripped (gdocs--push-comparison-body local-body))
         (remote-mappable (gdocs--push-comparison-body remote-body))
         (ot-body (plist-get state :ot-body))
         (prepended (gdocs--diff-prepend remote-mappable local-stripped))
         (appended (gdocs--diff-append remote-mappable local-stripped))
         (new-rev nil))
    (gdocs--push-preflight state local-body plan)
    (cond
     ((memq gdocs-push-backend '(ot-encode ot-incremental))
      (let* ((initial (gdocs--push-full-plan
                       doc-id state local-body gdocs-push-backend))
             (commands (gdocs--push-plan-commands initial)))
        (when commands
          (let* ((intent
                  (gdocs--make-push-intent
                   state local-body remote-mappable
                   (lambda (fresh-state _fresh-body)
                     (gdocs--push-full-plan
                      doc-id fresh-state local-body gdocs-push-backend))))
                 (result (gdocs--run-op-result doc-id state intent)))
            (setq new-rev (plist-get result :revision))))))
     (prepended
      (let* ((intent
              (gdocs--make-push-intent
               state local-body remote-mappable
               (lambda (fresh-state fresh-body)
                 (gdocs--push-insert-plan
                  fresh-state fresh-body prepended :prepend))))
             (result (gdocs--run-op-result doc-id state intent))
             (op-plan (plist-get result :plan)))
        (setq new-rev (plist-get result :revision))
        (gdocs--shift-buffer-anchors
         'is (plist-get op-plan :ot-start) (length prepended))
        (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))))
     ((and appended ot-body)
      (let* ((intent
              (gdocs--make-push-intent
               state local-body remote-mappable
               (lambda (fresh-state fresh-body)
                 (gdocs--push-insert-plan
                  fresh-state fresh-body appended :append))))
             (result (gdocs--run-op-result doc-id state intent)))
        (setq new-rev (plist-get result :revision))
        (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))))
     (ot-body
      (let* ((para-regions (gdocs--diff-paragraphs
                            remote-mappable local-stripped))
             (n-regions (length para-regions)))
        (if (<= n-regions 1)
            (let ((single (gdocs--diff-single-region
                           remote-mappable local-stripped)))
              (when single
                (let ((result
                       (gdocs--apply-in-place-region-result
                        doc-id state remote-mappable single local-body)))
                  (setq new-rev (plist-get result :revision)))))
          ;; Recompute the remaining regions from the verified body after
          ;; every successful operation.  The original region list is never
          ;; sent to a newer remote snapshot.
          (let ((current-state state)
                (current-body remote-mappable))
            (dotimes (index n-regions)
              (when (> index 0)
                (sleep-for gdocs--inter-region-delay)
                ;; A concurrent edit can arrive after the previous
                ;; operation's verification and before the next one.  Do a
                ;; fresh revision/body check at that boundary as well.
                (let ((fresh-state (gdocs--fetch-edit-state doc-id)))
                  (gdocs--push-verify-state
                   doc-id fresh-state current-body
                   (plist-get current-state :revision))
                  (setq current-state fresh-state
                        current-body (gdocs--push-state-body
                                      doc-id fresh-state))))
              (let* ((fresh-regions
                      (gdocs--push-region-list current-body local-stripped))
                     (region (car (last fresh-regions))))
                (unless region
                  (user-error "gdocs: remaining multi-region plan disappeared"))
                (let ((result
                       (gdocs--apply-in-place-region-result
                        doc-id current-state current-body region local-body)))
                  (setq new-rev (plist-get result :revision)
                        current-state (plist-get result :state)
                        current-body (plist-get result :body)))))))))
     (t
      (user-error
       "gdocs: edit shape not yet supported (non-contiguous diff, or change crosses table/list structure)")))
    ;; Never write a final baseline for a failed or ambiguous operation.
    (when new-rev
      (gdocs--put-top-property "GDOC_REVISION" (number-to-string new-rev))
      (gdocs--put-top-property "GDOC_CONTENT_HASH"
                               (secure-hash 'sha256 local-body))
      (gdocs--put-top-property "GDOC_SYNCED_AT" (gdocs--now-iso))
      (gdocs--mark-synced))
    new-rev))

(defun gdocs-push-remotely (&optional doc-id)
  "Push the current buffer asynchronously through the /save endpoint.

`gdocs-push-backend' selects the operation model.  `ot-encode' replaces the
remote OT body with a full Org-to-model encoding.  `ot-incremental' emits a
paragraph-model diff when safe and falls back to that full encoding for
structural changes.  Legacy `plain' emits lossy text-only `is'/`ds' operations
for prepend, append, and mappable single- or multi-region changes.

Before any write, decode the freshly fetched OT state and refuse plans that
cannot preserve unsupported content.  A changed buffer is also refused when
the fetched revision differs from GDOC_REVISION.  If the canonical local and
remote bodies already match, no /save is sent; after capability validation the
fresh remote revision establishes a verified baseline even if the stored
revision was stale.

The command returns after dispatch.  A package-wide synchronization lock skips
overlapping work and remains held until the asynchronous chain finishes.
Failures are logged as warnings.  A successful save or verified no-op updates
GDOC_REVISION, GDOC_CONTENT_HASH, and GDOC_SYNCED_AT and marks the buffer
synced.  After an ambiguous post-dispatch failure, refetch and compare the
expected pre- and post-operation body and revision: accept an observed commit,
allow one freshly planned throttle retry only from a verified unchanged
pre-operation state, and refuse conflicting or indeterminate outcomes without
writing a final hash baseline."
  (interactive)
  (if gdocs--sync-mutex
      (progn (gdocs-log 'warn "Mutex locked - skipping push") nil)
    (let ((owner (gdocs--sync-acquire))
          (dispatched nil))
      (unwind-protect
          (let* ((buf (current-buffer))
                 (doc-id (gdocs--get-doc-id doc-id))
                 (local-rev (org-entry-get (point-min) "GDOC_REVISION" t))
                 (local-body (gdocs--buffer-body-as-plain)))
            (unless (and local-rev (not (string-empty-p local-rev)))
              (user-error "gdocs: no GDOC_REVISION on this buffer — pull first"))
            (gdocs--push-remotely-async-1
             doc-id buf local-rev local-body owner)
            (setq dispatched t))
        (unless dispatched
          (gdocs--sync-release owner))))))

(defun gdocs--push-remotely-async-1
    (doc-id buf local-rev local-body owner)
  "Background driver for `gdocs-push-remotely'.
Single GET on /edit gives both the edit state and the modelChunk we
decode into the org view we diff against. Releases the sync mutex on
completion or error."
  ;; Editor save sessions expire server-side within minutes of inactivity;
  ;; a sporadic push must start from a fresh session id or the /save is
  ;; rejected (400/err 3).
  (gdocs-session-reset)
  (let* ((done nil)
         (release
          (lambda (err)
            (unless done
              (setq done t)
              (gdocs--sync-release owner)
              (when err (gdocs-log 'warn "Push %s: %s" doc-id err))
              t))))
    (gdocs--fetch-edit-page-async
     doc-id
     (lambda (state html err)
       (unless done
         (let* ((remote-rev (and state (plist-get state :revision)))
                (token (and state (plist-get state :token)))
                (ouid (and state (plist-get state :ouid))))
           (cond
            (err (funcall release err))
            ((null state) (funcall release "empty edit state"))
            ;; A state with neither ops nor body means the /edit page carried
            ;; no model chunks at all.  Decoding failure must never be
            ;; interpreted as an empty document that is safe to replace.
            ((and (null (plist-get state :ot-ops))
                  (null (plist-get state :ot-body)))
             (funcall release "edit state could not be decoded: no model chunks"))
            ((not (and token ouid remote-rev))
             (funcall release "missing token/ouid/rev"))
            ((plist-get state :tabs)
             (setq done t)
             (condition-case sig
                 (if (with-current-buffer buf
                       (save-excursion
                         (goto-char (point-min))
                         (and (re-search-forward
                               "^#\\+title:[ \t]*\\(.*\\)$" nil t)
                              (equal (match-string-no-properties 1)
                                     (plist-get state :title)))))
                     (gdocs--tab-push-async
                      doc-id buf local-rev local-body state owner)
                   (progn
                     (gdocs--sync-release owner)
                     (gdocs-log 'warn
                                "Push %s: document title changed locally; rename separately"
                                doc-id)))
               (error
                (gdocs--sync-release owner)
                (gdocs-log 'warn "Push %s: %s" doc-id
                           (error-message-string sig)))))
            (t
             (condition-case sig
                 (let* ((remote-body
                         (gdocs--ot-remote-org-body doc-id html state))
                        (plan (gdocs--push-plan-for-diff
                               state local-body remote-body)))
                   ;; STATE and HTML came from the current /edit fetch above;
                   ;; preflight decodes their raw ops again rather than trusting
                   ;; any capability summary serialized in the buffer.
                   (gdocs--push-preflight state local-body plan)
                   (cond
                    ((eq (plist-get plan :kind) :noop)
                     (when (buffer-live-p buf)
                       (with-current-buffer buf
                         (gdocs--finalize-push-props remote-rev local-body)))
                     (when (funcall release nil)
                       (gdocs-log 'info "Push: no local changes for %s" doc-id)))
                    ((not (string= local-rev (format "%s" remote-rev)))
                     (funcall release
                              (format
                               "refusing push: remote rev %s != local %s"
                               remote-rev local-rev)))
                    (t
                     (gdocs--apply-push-async
                      doc-id state local-body remote-body buf
                      (lambda (_rev e2)
                        (funcall release e2))))))
               (error
                (funcall release (error-message-string sig))))))))))))

(defun gdocs-debug-push-state (&optional doc-id out-file)
  "Dump everything `gdocs-push-remotely' sees into OUT-FILE for inspection.
Does NOT push — just captures: local body, remote body, OT state, the
single-region diff, and the locate result (if any).  An explicit OUT-FILE
is honored exactly.  Otherwise an unpredictable mode-0600 file is made
with `make-temp-file'.  The dump contains sensitive document and raw OT
content and persists until deleted.  Returns and logs its exact path
without logging raw content."
  (interactive)
  (let* ((doc-id (gdocs--get-doc-id doc-id))
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
         (capability-analysis (gdocs--remote-capability-analysis state))
         (capability-reports (plist-get capability-analysis :unsupported))
         (capability-summary (gdocs--capability-summary capability-reports))
         (capability-details
          (gdocs--capability-sanitized-details capability-reports))
         (single (gdocs--diff-single-region remote-body local-stripped))
         (paras (gdocs--diff-paragraphs remote-body local-stripped))
         (locate (and single
                      (gdocs--locate-edit-in-ot
                       ot-body remote-body
                       (plist-get single :start)
                       (plist-get single :rem-end))))
         (generated-out (null out-file))
         out completed)
    (unwind-protect
        (prog1
            (progn
              (setq out (or out-file
                            (make-temp-file "gdocs-push-debug-" nil ".txt")))
              (gdocs--write-sensitive-diagnostic
               out
               (lambda ()
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
                 (insert (format "unsupported capability summary: %s\n"
                                 (if (length> capability-summary 0)
                                     capability-summary
                                   "none")))
                 (insert (format "unsupported capability details (sanitized): %S\n"
                                 capability-details))
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
                                                (min (length plain) (+ i 30)))))))))
              (message
               "gdocs-debug-push-state: sensitive dump persists until deleted: %s"
               out)
              out)
          (setq completed t))
      (unless completed
        (when (and generated-out out (file-exists-p out))
          (ignore-errors (delete-file out)))))))


;;; Source-file publication (one-way Org → Google Docs)
;;
;; The source Org file remains authoritative; the Google Doc is a published
;; projection.  Publication metadata lives in `gdocs-publish-registry-file',
;; never in the user's source text.  Publishing converts the source, runs
;; the normal capability preflight, refuses to clobber foreign content or a
;; concurrently changed revision, and verifies the committed result by
;; refetching it.

(defconst gdocs-drive-rename-base
  "https://drivefrontend-pa.clients6.google.com/drive/v3/files"
  "Cookie-authenticated Drive file endpoint used by the editors frontend.

The documented googleapis.com Drive API requires OAuth; the editors'
own frontend proxy accepts the browser's SAPISIDHASH authorization
derived from the same cookie jar the /save protocol uses.")

(defcustom gdocs-drive-oauth-token nil
  "Optional OAuth access token with the Drive `drive.file' scope.

When non-nil, document renames use `Authorization: Bearer' on the
Google Drive API, which is the reliable path (Google's current
frontends reject cookie-only Drive API calls with 401/403).  When nil,
the rename falls back to the browser's SAPISIDHASH authorization and
silently gives up after the first rejection."
  :type '(choice (const :tag "None" nil) string)
  :group 'gdocs-mode)

(defvar gdocs--drive-rename-gave-up nil
  "Non-nil after a cookie-authenticated rename was rejected once.
Avoids log-spamming the failure on every publish for the session.")

(defun gdocs--cookie-value (name)
  "Return cookie NAME's value from the auth function's Cookie header, or nil."
  (let ((cookie (cdr (assoc "Cookie" (gdocs--auth-headers)))))
    (and (stringp cookie)
         (string-match (concat "\\(?:^\\|;\\s-*\\)"
                               (regexp-quote name) "=\\([^;]+\\)")
                       cookie)
         (match-string 1 cookie))))

(defun gdocs--sapisidhash-header ()
  "Build the SAPISIDHASH Authorization header, or nil without a SAPISID.
The hash is bound to the docs.google.com origin because that is the
origin the browser session (and therefore the SAPISID cookie) is
associated with."
  (let ((sapisid (gdocs--cookie-value "SAPISID")))
    (when (and sapisid (not (string-empty-p sapisid)))
      (let* ((ts (format-time-string "%s"))
             (origin "https://docs.google.com")
             (hash (secure-hash 'sha1 (concat ts " " origin " " sapisid))))
        (format "SAPISIDHASH %s_%s" ts hash)))))

(defun gdocs-rename-remotely (doc-id title callback)
  "Rename the Drive document DOC-ID to TITLE asynchronously.
CALLBACK is called exactly once as `(funcall CALLBACK TITLE ERR)'.

With `gdocs-drive-oauth-token' the rename uses the documented Drive API
and reliably succeeds.  Without a token the browser's SAPISIDHASH
authorization is attempted; Google currently rejects it (the cookie
session lacks the Drive scope), so the first rejection sets
`gdocs--drive-rename-gave-up' and later renames skip the request with a
nil CALLBACK result and a \"not available\" error."
  (cond
   (gdocs-drive-oauth-token
    (let* ((url (format "https://www.googleapis.com/drive/v3/files/%s"
                        doc-id))
           (headers (append
                     `(("Content-Type" . "application/json; charset=utf-8")
                       ("Authorization" . ,(concat "Bearer "
                                                   gdocs-drive-oauth-token)))
                     (gdocs--auth-headers)))
           (data (encode-coding-string (json-encode `((name . ,title)))
                                       'utf-8)))
      (gdocs--curl-async url "PATCH" headers data
                         (lambda (_raw code err)
                           (cond
                            (err (funcall callback nil err))
                            ((and (integerp code) (>= code 200) (< code 300))
                             (funcall callback title nil))
                            (t
                             (funcall callback nil (format "HTTP %s" code))))))))
   (gdocs--drive-rename-gave-up
    (funcall callback nil "Drive rename unavailable without gdocs-drive-oauth-token"))
   (t
    (let* ((url (format "%s/%s?fields=name" gdocs-drive-rename-base doc-id))
           (headers (append
                     `(("Content-Type" . "application/json; charset=utf-8")
                       ("Origin" . "https://docs.google.com")
                       ("X-Goog-AuthUser" . "0")
                       ("Referer" . "https://docs.google.com/")
                       ("User-Agent" . ,gdocs-default-user-agent))
                     (gdocs--auth-headers)
                     (let ((auth (gdocs--sapisidhash-header)))
                       (and auth (list (cons "Authorization" auth))))))
           (data (encode-coding-string (json-encode `((name . ,title))) 'utf-8)))
      (gdocs--curl-async url "PATCH" headers data
                         (lambda (_raw code err)
                           (cond
                            (err (funcall callback nil err))
                            ((and (integerp code) (>= code 200) (< code 300))
                             (funcall callback title nil))
                            ;; Cookie-authenticated Drive calls are
                            ;; forbidden on Google's current frontends;
                            ;; don't retry on every publish.
                            ((memq code '(401 403))
                             (setq gdocs--drive-rename-gave-up t)
                             (funcall
                              callback
                              nil
                              "Drive rename requires gdocs-drive-oauth-token (cookie authorization rejected)"))
                            (t
                             (funcall callback nil (format "HTTP %s" code))))))))))

(defun gdocs--doc-body-title (doc)
  "Return DOC's body title (the first Title-kind paragraph's text), or nil."
  (cl-some
   (lambda (paragraph)
     (when (eq (plist-get paragraph :kind) :title)
       (let ((text (string-trim (gdocs-dm-runs-text (plist-get paragraph :runs)))))
         (and (not (string-empty-p text)) text))))
   (gdocs-dm-paragraphs doc)))


(defcustom gdocs-publish-registry-file
  (expand-file-name "gdocs-publish-registry.el" user-emacs-directory)
  "File recording source-file → Google Doc associations.

Each entry stores the last published revision so a later publish refuses
to overwrite concurrent remote changes instead of clobbering them."
  :type 'file
  :group 'gdocs-mode)

(defcustom gdocs-publish-rename-from-title t
  "Rename the Drive document to the source's `#+TITLE:' after publishing.

The rename happens best-effort after the content is committed and
verified; a failure is logged but does not fail the publish.  Without a
`#+TITLE:' the document name is left alone."
  :type 'boolean
  :group 'gdocs-mode)

(defvar gdocs--publish-registry nil
  "Alist ((SOURCE . (DOC-ID . LAST-PUBLISHED-REVISION))).")

(defun gdocs--publish-registry-load ()
  "Populate `gdocs--publish-registry' from `gdocs-publish-registry-file'."
  (setq gdocs--publish-registry
        (when (and gdocs-publish-registry-file
                   (file-exists-p gdocs-publish-registry-file))
          (with-temp-buffer
            (insert-file-contents gdocs-publish-registry-file)
            (ignore-errors (read (current-buffer)))))))

(defun gdocs--publish-registry-record (source doc-id revision)
  "Persist that SOURCE published to DOC-ID at REVISION."
  (gdocs--publish-registry-load)
  (setq gdocs--publish-registry
        (cons (cons (expand-file-name source) (cons doc-id revision))
              (cl-remove-if
               (lambda (entry)
                 (equal (car entry) (expand-file-name source)))
               gdocs--publish-registry)))
  (when gdocs-publish-registry-file
    (let ((directory (file-name-directory gdocs-publish-registry-file)))
      (when (and directory (not (file-exists-p directory)))
        (ignore-errors (make-directory directory t))))
    (with-temp-file gdocs-publish-registry-file
      (prin1 gdocs--publish-registry (current-buffer)))))

(defun gdocs--publish-registry-lookup (source)
  "Return (DOC-ID . LAST-REVISION) recorded for SOURCE, or nil."
  (gdocs--publish-registry-load)
  (cdr (assoc (expand-file-name source) gdocs--publish-registry)))

(defun gdocs--publish-analysis (source)
  "Convert SOURCE's Org text and return a publication analysis plist.

The plist carries `:org-text', `:doc' (the parsed model), `:lossy' (the
disclosed fallback explanations), `:unsupported-summary' (non-nil text
blocks publication), and `:expected-org' (the round-trip render that a
committed document must decode back to)."
  (let* ((org-text (with-temp-buffer
                     ;; Decoded read (NOT literally): the source is UTF-8 and
                     ;; the OT model indexes CHARACTERS.  A literal read makes
                     ;; every multi-byte character three raw bytes, shifting
                     ;; all style-op positions after it.
                     (insert-file-contents source)
                     (buffer-string)))
         (doc (gdocs-dm-from-org org-text))
         (unsupported (gdocs-dm-unsupported doc)))
    (list :org-text org-text
          :doc doc
          :lossy (gdocs-dm-lossy doc)
          :unsupported-summary (and unsupported
                                    (gdocs--capability-summary unsupported))
          :expected-org (gdocs--push-expected-remote-body doc))))

(defun gdocs--publish-target-buffer (doc-id)
  "Return the live org buffer synchronized with DOC-ID, or nil."
  (seq-find
   (lambda (buffer)
     (with-current-buffer buffer
       (and (derived-mode-p 'org-mode)
            (equal (gdocs--top-property-value "GDOC_ID") doc-id))))
   (buffer-list)))

(defun gdocs-publish-preview (source &optional doc-id)
  "Return a preview plist for publishing Org file SOURCE to DOC-ID.

DOC-ID defaults to the recorded association for SOURCE.  The plist
carries `:doc-id', `:lossy', `:unsupported-summary', `:expected-org',
and `:paragraph-count'.  This function performs no network I/O and
never modifies files.  Interactively, a readable report is shown in a
help buffer."
  (interactive "fOrg file to publish: ")
  (let* ((analysis (gdocs--publish-analysis source))
         (doc-id (or doc-id
                     (car (gdocs--publish-registry-lookup source))))
         (result (list :doc-id doc-id
                       :lossy (plist-get analysis :lossy)
                       :unsupported-summary
                       (plist-get analysis :unsupported-summary)
                       :expected-org (plist-get analysis :expected-org)
                       :paragraph-count
                       (length (gdocs-dm-paragraphs
                                (plist-get analysis :doc))))))
    (when (called-interactively-p 'any)
      (with-help-window "*gdocs publish preview*"
        (princ (format "Publish %s → %s\n\n"
                       (file-name-nondirectory source)
                       (or doc-id "(no associated doc)")))
        (princ (format "Paragraphs: %d\n\n"
                       (plist-get result :paragraph-count)))
        (if (plist-get result :unsupported-summary)
            (progn
              (princ "BLOCKED — unsupported content:\n  ")
              (princ (plist-get result :unsupported-summary))
              (princ "\n"))
          (princ "No blocking unsupported content.\n"))
        (if (plist-get result :lossy)
            (progn
              (princ "\nDisclosed fallbacks:\n")
              (dolist (reason (plist-get result :lossy))
                (princ (format "  - %s\n" reason))))
          (princ "\nNo disclosed fallbacks.\n"))))
    result))

(defun gdocs-publish-check (source &optional doc-id)
  "Compare Org file SOURCE with its published Google Doc DOC-ID.

Returns a plist with `:status' (`:in-sync', `:drift', `:stale-revision',
`:unpublished', or `:error'), and `:detail'.  Network I/O is synchronous;
the document is never modified."
  (interactive "fOrg file to check: ")
  (let* ((registered (gdocs--publish-registry-lookup source))
         (doc-id (gdocs--extract-doc-id
                  (or doc-id (car registered))))
         (analysis (gdocs--publish-analysis source)))
    (unless doc-id
      (user-error "gdocs: no doc-id for %s; publish first or pass DOC-ID"
                  source))
    (let* ((state (gdocs--fetch-edit-state doc-id))
           (remote-rev (and state (plist-get state :revision))))
      (cond
       ((or (null state)
            (and (null (plist-get state :ot-ops))
                 (null (plist-get state :ot-body))))
        (list :status :error :detail "remote state could not be decoded"))
       ((and (cdr registered) remote-rev
             (not (string= (format "%s" (cdr registered))
                           (format "%s" remote-rev))))
        (list :status :stale-revision
              :detail (format "registry rev %s, remote rev %s"
                              (cdr registered) remote-rev)))
       ((null remote-rev)
        (list :status :unpublished :detail "no remote revision"))
       (t
        (let* ((remote-doc
                (gdocs-dm-from-ops remote-rev doc-id
                                   (plist-get state :title)
                                   (or (plist-get state :ot-body) "")
                                   (plist-get state :ot-ops)))
               (remote-body
                (gdocs--push-comparison-body (gdocs-dm-to-org remote-doc)))
               (expected
                (gdocs--push-comparison-body
                 (plist-get analysis :expected-org))))
          (if (string= remote-body expected)
              (list :status :in-sync
                    :detail (format "remote rev %s matches source" remote-rev))
            (list :status :drift
                  :detail "remote body differs from the source projection"))))))))

(defun gdocs-publish-file (source doc-id &optional force no-prompt callback)
  "Publish Org file SOURCE as the body of Google Doc DOC-ID.

The document body is fully replaced from the source file; the source
file is never modified.  Guards, in order:

- The conversion must be free of blocking unsupported content.
- A foreign document (non-empty body never published from this source)
  requires FORCE.
- A remote revision newer than the last recorded publish requires FORCE.

Disclosed fallbacks are confirmed interactively unless NO-PROMPT is
non-nil; non-interactive calls log them instead.

After a successful commit the association and revision are recorded in
`gdocs-publish-registry-file', and a synchronized org buffer for DOC-ID
is refreshed by a pull.  When `gdocs-verify-after-save' is non-nil the
committed body is refetched and verified before success is reported.

The push is asynchronous; CALLBACK receives `(RESULT ERR)' exactly once,
where RESULT is a plist with `:revision', `:verified', `:lossy', and
`:doc-id'.  For interactive use the outcome is also logged."
  (let* ((source (expand-file-name source))
         (doc-id (gdocs--extract-doc-id doc-id))
         (analysis (gdocs--publish-analysis source))
         (lossy (plist-get analysis :lossy))
         (registered (gdocs--publish-registry-lookup source))
         (buffer (gdocs--publish-target-buffer doc-id)))
    (when (plist-get analysis :unsupported-summary)
      (user-error
       "gdocs: publish refused: source contains %s"
       (plist-get analysis :unsupported-summary)))
    (when (and lossy (not no-prompt))
      (if noninteractive
          (gdocs-log 'info "Publish fallbacks for %s: %s" doc-id
                     (string-join lossy "; "))
        (unless (yes-or-no-p
                 (format "Publish with disclosed fallbacks (%s)? "
                         (string-join lossy "; ")))
          (user-error "gdocs: publish cancelled"))))
    ;; Save sessions expire within minutes; publish always saves from a
    ;; fresh one.
    (gdocs-session-reset)
    (let* ((state (gdocs--fetch-edit-state doc-id))
           (remote-rev (and state (plist-get state :revision)))
           (remote-body
            (and state
                 (gdocs--remote-org-body-from-state doc-id state))))
      (cond
       ((or (null state)
            (and (null (plist-get state :ot-ops))
                 (null (plist-get state :ot-body))))
        (user-error
         "gdocs: publish refused: remote state could not be decoded"))
       ((plist-get state :tabs)
        (user-error
         "gdocs: publish refused: multi-tab documents cannot be replaced safely"))
       ((and (cdr registered) remote-rev
             (not (string= (format "%s" (cdr registered))
                           (format "%s" remote-rev)))
             (not force))
        (user-error
         "gdocs: publish refused: remote rev %s is newer than the last publish (%s); re-check and pass FORCE"
         remote-rev (cdr registered)))
       ((and (length> (gdocs--push-comparison-body remote-body) 0)
             (null registered)
             (not force)
             (not (and buffer
                       (with-current-buffer buffer
                         (gdocs--top-property-value "GDOC_CONTENT_HASH")))))
        (user-error
         "gdocs: publish refused: %s has content and was never published from %s; pass FORCE to overwrite"
         doc-id source)))
      ;; Capability preflight against the freshly fetched state.
      (gdocs--push-preflight state (plist-get analysis :org-text)
                             '(:kind :full-replace))
      (let ((owner (or (gdocs--sync-acquire)
                       (user-error "gdocs: another sync operation is active"))))
        (gdocs--apply-push-async
         doc-id state (plist-get analysis :org-text) remote-body buffer
         (lambda (new-rev err)
           (gdocs--sync-release owner)
           (if err
               (progn
                 (gdocs-log 'warn "Publish of %s failed: %s" source err)
                 (when callback (funcall callback nil err)))
             (gdocs--publish-registry-record source doc-id new-rev)
             (let ((result (list :revision new-rev
                                 :verified (and gdocs-verify-after-save t)
                                 :lossy lossy
                                 :doc-id doc-id)))
               (gdocs-log 'info "Published %s → %s (rev %s%s)"
                          source doc-id new-rev
                          (if lossy
                              (format ", %d disclosed fallbacks"
                                      (length lossy))
                            ""))
               ;; The Drive document name follows the source's `#+TITLE:'
               ;; automatically.  A body `#+title:' is a pushable Title
               ;; paragraph; the Drive name is separate metadata and is
               ;; renamed best-effort after the content is committed.
               (let ((body-title (gdocs--doc-body-title
                                  (plist-get analysis :doc))))
                 (cond
                  ((and gdocs-publish-rename-from-title body-title
                        (plist-get state :title)
                        (not (string= body-title
                                      (plist-get state :title))))
                   (gdocs-rename-remotely
                    doc-id body-title
                    (lambda (renamed r-err)
                      (if r-err
                          (gdocs-log
                           (if (string-match-p "unavailable\\|requires" r-err)
                               'info 'warn)
                           "Rename of %s to %S skipped: %s"
                           doc-id body-title r-err)
                        (gdocs-log
                         'info
                         "Renamed %s to %S" doc-id renamed))
                      (when (buffer-live-p buffer)
                        (with-current-buffer buffer
                          (when renamed
                            (gdocs--put-top-property
                             "GDOC_TITLE" renamed)))))))
                  (body-title
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (gdocs--put-top-property "GDOC_TITLE" body-title))))))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (gdocs-pull-locally doc-id)))
               (when callback (funcall callback result nil)))))))
      nil)))


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
         (tab-id (and (stringp input)
                      (string-match "[?&]tab=\\(t\\.[A-Za-z0-9]+\\)" input)
                      (match-string 1 input)))
         (existing (seq-find
                    (lambda (b)
                      (with-current-buffer b
                        (and (derived-mode-p 'org-mode)
                             (string= (or (gdocs--doc-id-from-buffer) "")
                                      doc-id))))
                    (buffer-list))))
    (if existing
        (progn (switch-to-buffer existing)
               (when tab-id (gdocs--goto-tab tab-id)))
      ;; Use a placeholder buffer name; pull will set the real title.
      (let ((buffer (generate-new-buffer (format "*gdocs:%s*" doc-id))))
        (with-current-buffer buffer
          (org-mode)
          (erase-buffer)
          (insert (format ":PROPERTIES:\n:GDOC_ID: %s\n:END:\n" doc-id))
          (goto-char (point-min))
          (gdocs-pull-locally
           doc-id
           (lambda (_body err)
             (when (and (not err) (buffer-live-p buffer))
               (with-current-buffer buffer
                 (let ((new-title (gdocs--top-property-value "GDOC_TITLE")))
                   (when (and new-title (not (string-empty-p new-title)))
                     (rename-buffer (format "%s.org" new-title) t)))
                 (when tab-id (gdocs--goto-tab tab-id))))))
          ;; The pull is asynchronous. Use an already stored GDOC_TITLE when
          ;; reopening a prepared buffer, otherwise keep the ID placeholder
          ;; until the fetched Drive metadata arrives in the callback.
          (let ((new-title (gdocs--top-property-value "GDOC_TITLE")))
            (rename-buffer
             (format "%s.org"
                     (if (and new-title (not (string-empty-p new-title)))
                         new-title doc-id))
             t))
          (gdocs-mode 1)
          (switch-to-buffer buffer))))))

(defun gdocs--goto-tab (tab-id)
  "Move to the heading for TAB-ID in the current Org buffer."
  (goto-char (point-min))
  (unless (and (re-search-forward
                (format "^:GDOC_TAB: %s$" (regexp-quote tab-id)) nil t)
               (progn (org-back-to-heading t)
                      (equal (org-entry-get (point) "GDOC_TAB") tab-id)))
    (user-error "gdocs: tab %s not present in this document" tab-id)))


;;; Minor mode

(defun gdocs--has-id-p ()
  "Buffer has a GDOC_ID property."
  (gdocs--doc-id-from-buffer))

(defun gdocs--auto-sync-tick ()
  "Sync this buffer with its remote Google Doc.

Decision (resolved per tick after a single edit-state probe):
  - Remote and local revisions differ, and the buffer is clean → pull.
  - Remote and local revisions match, and the buffer is dirty → push.
  - Both revisions differ and the buffer is dirty → warn and do nothing.
  - The local synchronization baseline is unknown → do nothing.
  - Either revision is unavailable → report the diagnostic and do nothing.

Local-edit detection uses a buffer-local hash baseline refreshed by
`gdocs--mark-synced' at every successful pull/push (not
`buffer-modified-p', which doesn't fire for programmatic inserts and
isn't reliable in temp/indirect buffers).

Fully async; the timer re-arms with an adaptive backoff so a transient
network blip or Google rate limit doesn't spam warnings every interval."
  (when (and (bound-and-true-p gdocs-mode)
             (gdocs--has-id-p)
             (not gdocs--sync-mutex))
    (let ((doc-id (gdocs--doc-id-from-buffer)))
      (if (eq (gdocs--sync-state) 'unknown)
          (progn
            (cl-incf gdocs--auto-sync-failures)
            (gdocs-log 'warn
                       "Auto-sync skipped for %s: synchronization baseline unavailable; run `gdocs-pull-locally' or `gdocs-push-remotely' manually"
                       doc-id))
        (let ((buf (current-buffer))
              (generation gdocs--auto-sync-generation)
              (token (list nil)))
          (unless gdocs--auto-sync-in-flight
            (setq gdocs--auto-sync-in-flight token)
            (condition-case fetch-error
                (gdocs--fetch-edit-state-async
                 doc-id
                 (lambda (state err)
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (when (and (bound-and-true-p gdocs-mode)
                                  (= generation gdocs--auto-sync-generation)
                                  (eq token gdocs--auto-sync-in-flight))
                         (setq gdocs--auto-sync-in-flight nil)
                         (cond
                          (err
                           (cl-incf gdocs--auto-sync-failures)
                           (gdocs-log 'warn
                                      "Auto-sync state fetch failed for %s (next tick in %ss): %s"
                                      doc-id (gdocs--auto-sync-delay) err))
                          ((null state)
                           (cl-incf gdocs--auto-sync-failures)
                           (gdocs-log 'warn
                                      "Auto-sync skipped for %s: remote revision unavailable (next tick in %ss)"
                                      doc-id (gdocs--auto-sync-delay)))
                          (t
                           (let* ((remote-rev (plist-get state :revision))
                                  (local-rev
                                   (org-entry-get (point-min) "GDOC_REVISION" t))
                                  (remote-rev-number
                                   (cond
                                    ((integerp remote-rev) remote-rev)
                                    ((and (stringp remote-rev)
                                          (string-match-p "\\`[0-9]+\\'" remote-rev))
                                     (string-to-number remote-rev))))
                                  (local-rev-number
                                   (and (stringp local-rev)
                                        (string-match-p "\\`[0-9]+\\'" local-rev)
                                        (string-to-number local-rev)))
                                  (have-revs (and (numberp remote-rev-number)
                                                  (numberp local-rev-number)))
                                  (stale (and have-revs
                                              (/= remote-rev-number local-rev-number)))
                                  (sync-state (gdocs--sync-state))
                                  (dirty (eq sync-state 'dirty)))
                             (cond
                              ((eq sync-state 'unknown)
                               (gdocs-log 'warn
                                          "Auto-sync skipped for %s: synchronization baseline unavailable; run `gdocs-pull-locally' or `gdocs-push-remotely' manually"
                                          doc-id))
                              ((not have-revs)
                               (cl-incf gdocs--auto-sync-failures)
                               (gdocs-log 'warn
                                          "Auto-sync skipped for %s: revision unavailable (remote=%S local=%S; next tick in %ss)"
                                          doc-id remote-rev local-rev
                                          (gdocs--auto-sync-delay)))
                              ((and stale dirty)
                               (unless (equal gdocs--auto-sync-conflict-revision
                                              remote-rev-number)
                                 (setq gdocs--auto-sync-conflict-revision
                                       remote-rev-number)
                                 (gdocs-log
                                  'warn
                                  "Auto-sync conflict for %s at remote revision %s: local and remote changed; neither pull nor push was performed. Resolve the changes, then run `gdocs-pull-locally' or `gdocs-push-remotely'."
                                  doc-id remote-rev-number)))
                              (t
                               ;; A valid non-conflicting state means an earlier conflict
                               ;; no longer applies, even if the subsequent sync fails.
                               (setq gdocs--auto-sync-conflict-revision nil)
                               (setq gdocs--auto-sync-failures 0)
                               (cond
                                (stale
                                 (gdocs-pull-locally
                                  doc-id
                                  (lambda (_body p-err)
                                    (when (and (not p-err) (buffer-live-p buf))
                                      (with-current-buffer buf
                                        (gdocs-log 'info "Auto-pulled %s to rev %S"
                                                   doc-id remote-rev-number))))))
                                (dirty
                                 (gdocs-log 'info "Auto-pushing %s (local edits)"
                                            doc-id)
                                 (gdocs-push-remotely doc-id)))))))))))))
              (error
               (when (and (= generation gdocs--auto-sync-generation)
                          (eq token gdocs--auto-sync-in-flight))
                 (setq gdocs--auto-sync-in-flight nil))
               (cl-incf gdocs--auto-sync-failures)
               (gdocs-log 'warn "Auto-sync state fetch failed for %s (next tick in %ss): %s"
                          doc-id (gdocs--auto-sync-delay)
                          (error-message-string fetch-error))))))))))

(defun gdocs--enable ()
  (gdocs--restore-sync-baseline)
  (when gdocs--sync-timer
    (cancel-timer gdocs--sync-timer)
    (setq gdocs--sync-timer nil))
  (cl-incf gdocs--auto-sync-generation)
  (setq gdocs--auto-sync-in-flight nil)
  (let* ((buf (current-buffer))
         (generation gdocs--auto-sync-generation)
         (timer nil))
    (cl-labels
        ((arm ()
           ;; Self-re-arming (non-repeating) timer: the delay is
           ;; recomputed every cycle so consecutive failures back off
           ;; exponentially (see `gdocs--auto-sync-delay').
           (setq timer
                 (run-with-timer
                  (gdocs--auto-sync-delay)
                  nil
                  (lambda ()
                    (if (and (buffer-live-p buf)
                             (with-current-buffer buf
                               (and (bound-and-true-p gdocs-mode)
                                    (= generation gdocs--auto-sync-generation)
                                    (eq timer gdocs--sync-timer))))
                        (progn
                          (gdocs--auto-sync-tick)
                          (arm))
                      (when timer (cancel-timer timer))))))))
      (arm))
    (setq gdocs--sync-timer timer)
    (add-hook 'kill-buffer-hook #'gdocs--disable nil t))
  (gdocs-log 'info "gdocs-mode enabled"))

(defun gdocs--disable ()
  (cl-incf gdocs--auto-sync-generation)
  (setq gdocs--auto-sync-in-flight nil
        gdocs--auto-sync-failures 0)
  (when gdocs--sync-timer
    (cancel-timer gdocs--sync-timer)
    (setq gdocs--sync-timer nil))
  (remove-hook 'kill-buffer-hook #'gdocs--disable t)
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
