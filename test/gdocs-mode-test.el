;;; gdocs-mode-test.el --- Offline ERT tests for gdocs-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valentin Leon

;;; Commentary:

;; These tests deliberately exercise the conversion boundaries with synthetic
;; OT streams.  No test in this file calls Google, resolves browser cookies,
;; or writes a user's buffer or file.  The small request shim below is only
;; used when the optional `request' package is not installed in a clean batch
;; Emacs; synchronization tests stub the network-facing functions themselves.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'json)
(require 'seq)

;; `gdocs-mode.el' declares request as a package dependency.  Keep the
;; offline suite runnable with `emacs -Q' even when that optional dependency
;; is not present in the batch environment.
(unless (require 'request nil t)
  (defmacro request (&rest args)
    ;; Reference the dynamically scoped knobs used by the production call
    ;; site so byte compilation with this shim has the same signal/noise as
    ;; compilation with the real request.el macro.
    `(progn
       (ignore ,@args request-message-level request-log-level)
       (error "The request package is unavailable in an offline test")))
  (defun request-response-status-code (_response) nil)
  (defun request-response-data (_response) nil)
  (provide 'request))

(defconst gdocs-test--directory
  (file-name-directory (or load-file-name buffer-file-name)))

(add-to-list 'load-path (expand-file-name ".." gdocs-test--directory))
(require 'gdocs-mode)

(defconst gdocs-test--integration-variable "GDOCS_MODE_RUN_INTEGRATION"
  "Environment variable that explicitly opts into integration tests.")

;;; Fixture and synthetic OT helpers

(defun gdocs-test--fixture (name)
  "Read the single sanitized fixture named NAME from `fixtures/'."
  (let ((file (expand-file-name (format "%s.eld" name)
                                (expand-file-name "fixtures" gdocs-test--directory))))
    (with-temp-buffer
      (insert-file-contents file)
      (read (current-buffer)))))

(defun gdocs-test--inline-case (name)
  "Return the sanitized inline-image case named NAME."
  (let ((file (cdr (assoc name
                          '(("one-image-between-paragraphs" . "inline-image-one")
                            ("multiple-images-not-entity-order" . "inline-image-multiple")
                            ("literal-asterisk-paragraph" . "inline-image-literal-star")
                            ("image-and-literal-asterisk" . "inline-image-mixed")
                            ("ambiguous-image-attachment" . "inline-image-ambiguous"))))))
    (and file (gdocs-test--fixture file))))

(defun gdocs-test--fixture-html (fixture)
  "Turn the model chunks in FIXTURE into synthetic edit-page HTML."
  (mapconcat
   (lambda (chunk)
     (format "<script>DOCS_modelChunk = %s;</script>"
             (json-encode
              `((chunk . ,(plist-get chunk :ops))
                (revision . ,(plist-get chunk :revision))))))
   (plist-get fixture :chunks)
   "\n"))

(defun gdocs-test--html-for-ops (revision ops)
  "Build one synthetic modelChunk assignment for OPS and REVISION."
  (format "DOCS_modelChunk = %s;"
          (json-encode `((chunk . ,ops) (revision . ,revision)))))

(defun gdocs-test--insert-op (body)
  "Construct an OT insert operation for BODY."
  `((ty . "is") (s . ,body)))

(defun gdocs-test--style-modifier (styles)
  "Construct a compact text style modifier for STYLES.

The production decoder intentionally accepts sparse modifiers, so fixtures
only set the styles being characterized.  Code and verbatim use the two
synthetic font families understood by the decoder."
  (let ((mapping '((:bold . ts_bd)
                   (:italic . ts_it)
                   (:underline . ts_un)
                   (:strike . ts_st)))
        (sm nil))
    (dolist (entry mapping)
      (when (memq (car entry) styles)
        (push (cons (cdr entry) t) sm)))
    (cond
     ((memq :verbatim styles) (push '(ts_ff . "Courier New") sm))
     ((memq :code styles) (push '(ts_ff . "Roboto Mono") sm)))
    (nreverse sm)))

(defun gdocs-test--occurrence-start (body needle &optional occurrence)
  "Return the zero-based start of NEEDLE's OCCURRENCE in BODY."
  (let ((from 0)
        (wanted (or occurrence 1))
        (found nil))
    (dotimes (_ wanted)
      (setq found (string-match (regexp-quote needle) body from))
      (unless found
        (error "Fixture needle not found: %S" needle))
      (setq from (+ found (length needle))))
    found))

(defun gdocs-test--text-range-op (body range)
  "Construct a text style op from a fixture RANGE.

RANGE uses a human-readable `:text' needle and `:styles' list rather than
duplicating OT positions in every fixture."
  (let* ((needle (plist-get range :text))
         (start (gdocs-test--occurrence-start
                 body needle (plist-get range :occurrence)))
         (si (1+ start))
         (ei (+ si (length needle) -1)))
    `((ty . "as") (st . "text") (si . ,si) (ei . ,ei)
      (sm . ,(gdocs-test--style-modifier (plist-get range :styles))))))

(defun gdocs-test--link-range-op (body text url &optional occurrence)
  "Construct an `as st=link' op covering TEXT in BODY.
The nested modifier intentionally mirrors the shape observed in modelChunk
streams, including `lnks_link.ulnk_url'."
  (let* ((start (gdocs-test--occurrence-start body text occurrence))
         (si (1+ start))
         (ei (+ si (length text) -1)))
    `((ty . "as") (st . "link") (si . ,si) (ei . ,ei)
      (sm . ((lnks_link . ((lnk_type . 0)
                           (ulnk_url . ,url))))))))

(defun gdocs-test--link-unset-op (si ei)
  "Construct an explicit nested `ulnk_url' unset link op."
  `((ty . "as") (st . "link") (si . ,si) (ei . ,ei)
    (sm . ((lnks_link . ((lnk_type . 0)
                         (ulnk_url . :json-false)))))))

(defun gdocs-test--line-end-pos (body line)
  "Return the one-based OT position of LINE's terminating newline."
  (let ((from 0) (idx nil))
    (dotimes (_ line)
      (setq idx (string-match "\n" body from))
      (unless idx
        (error "Fixture line %d has no terminating newline" line))
      (setq from (1+ idx)))
    (1+ idx)))

(defun gdocs-test--paragraph-op (body spec)
  "Construct a paragraph style op from a fixture SPEC."
  (let* ((kind (plist-get spec :kind))
         (pos (gdocs-test--line-end-pos body (plist-get spec :line)))
         (heading (pcase kind
                    (:title 100)
                    (:subtitle 101)
                    (:heading (plist-get spec :level))
                    (_ nil)))
         (sm (when heading `((ps_hd . ,heading)))))
    (when (plist-get spec :anchor)
      (setq sm (append sm `((ps_hdid . ,(plist-get spec :anchor))))))
    `((ty . "as") (st . "paragraph") (si . ,pos) (ei . ,pos)
      (sm . ,sm))))

(defun gdocs-test--list-definition-op (definition)
  "Construct an `ae list' operation from a fixture DEFINITION."
  (let* ((id (plist-get definition :id))
         (numbered (eq (plist-get definition :glyph) :number))
         (levels
          (cl-loop for n from 0 to 8
                   collect
                   (cons (intern (format "nl_%d" n))
                         `((b_gt . ,(if numbered 13 9)))))))
    `((ty . "ae") (et . "list") (id . ,id)
      (epm . ((le_nb . ,levels))))))

(defun gdocs-test--list-binding-op (body binding)
  "Construct a list binding op from a fixture BINDING."
  (let ((pos (gdocs-test--line-end-pos body (plist-get binding :line))))
    `((ty . "as") (st . "list") (si . ,pos) (ei . ,pos)
      (sm . ((ls_id . ,(plist-get binding :id))
             (ls_nest . ,(or (plist-get binding :nest) 0)))))))

(defun gdocs-test--fixture-ops (fixture)
  "Construct OT operations described by a synthetic FIXTURE."
  (let ((body (plist-get fixture :body)))
    (append
     (list (gdocs-test--insert-op body))
     (mapcar (apply-partially #'gdocs-test--text-range-op body)
             (plist-get fixture :text-ranges))
     (mapcar (apply-partially #'gdocs-test--paragraph-op body)
             (plist-get fixture :paragraph-styles))
     (mapcar #'gdocs-test--list-definition-op
             (plist-get fixture :list-defs))
     (mapcar (apply-partially #'gdocs-test--list-binding-op body)
             (plist-get fixture :list-bindings))
     (plist-get fixture :unknown-ops))))

(defun gdocs-test--title-pipeline (drive-title body paragraph-styles)
  "Run the pull pipeline for a synthetic BODY and paragraph styles."
  (let* ((fixture (list :body body :paragraph-styles paragraph-styles))
         (ops (gdocs-test--fixture-ops fixture))
         (state (list :revision 12 :title drive-title :ot-body body)))
    (gdocs--ot-decode-pipeline
     "synthetic-title-document"
     (gdocs-test--html-for-ops 12 ops)
     state)))

(defun gdocs-test--apply-pull (initial title body)
  "Apply a synthetic pull BODY to INITIAL and return its resulting buffer text."
  (with-temp-buffer
    (insert initial)
    (org-mode)
    (cl-letf (((symbol-function 'gdocs--flash-regions) (lambda (_ranges) nil)))
      (gdocs--apply-pull-into-buffer "synthetic-title-document"
                                     (current-buffer) title body))
    (buffer-string)))

(defun gdocs-test--run-view (run)
  "Return the stable, user-visible shape of RUN."
  (list (plist-get run :text)
        (sort (copy-sequence (or (plist-get run :styles) nil))
              (lambda (a b) (string< (symbol-name a) (symbol-name b))))
        (plist-get run :link)))

(defun gdocs-test--coalesce-runs (runs)
  "Merge adjacent RUNS with the same style and link metadata.

OT decoding quite reasonably merges neighboring unstyled characters, while
Org parsing can retain a boundary created by a post-blank.  Comparison is
about user-visible run semantics, not those incidental boundaries."
  (let (out)
    (dolist (run runs (nreverse out))
      (let ((prior (car out)))
        (if (and prior
                 (equal (plist-get prior :styles) (plist-get run :styles))
                 (equal (plist-get prior :link) (plist-get run :link)))
            (setcar out
                    (plist-put (copy-sequence prior) :text
                               (concat (plist-get prior :text)
                                       (plist-get run :text))))
          (push (copy-sequence run) out))))))

(defun gdocs-test--cell-view (cell)
  "Return the stable text/run shape of a table CELL."
  (let ((runs (if (and cell (consp (car cell))
                       (plist-member (car cell) :text))
                  cell
                (apply #'append cell))))
    (mapcar #'gdocs-test--run-view runs)))

(defun gdocs-test--paragraph-view (paragraph)
  "Return a comparison shape for PARAGRAPH, omitting unstable IDs."
  (if (eq (plist-get paragraph :kind) :table)
      (list :table
            (mapcar (lambda (row) (mapcar #'gdocs-test--cell-view row))
                    (plist-get paragraph :rows)))
    (list (plist-get paragraph :kind)
          (plist-get paragraph :level)
          (plist-get paragraph :nest)
          (plist-get paragraph :glyph)
          (mapcar #'gdocs-test--run-view
                  (gdocs-test--coalesce-runs (plist-get paragraph :runs))))))

(defun gdocs-test--model-view (doc)
  "Return stable paragraph shapes for DOC."
  (mapcar #'gdocs-test--paragraph-view (gdocs-dm-paragraphs doc)))

(defun gdocs-test--normalize-org (text)
  "Normalize line endings and trailing horizontal whitespace in TEXT.

Org renderers commonly differ only in whether a terminal paragraph
separator is represented as one or two final newlines.  Drop terminal blank
lines while retaining the single final newline required by a text buffer."
  (let* ((text (substring-no-properties (or text "")))
         (ends-newline (string-suffix-p "\n" text))
         (lines (split-string text "\n" nil)))
    (setq lines
          (mapcar (lambda (line)
                    (replace-regexp-in-string "[ \t]+$" "" line))
                  lines))
    (while (and (> (length lines) 1)
                (string-empty-p (car (last lines))))
      (setq lines (butlast lines)))
    (concat (string-join lines "\n")
            (if ends-newline "\n" ""))))

(defun gdocs-test--op-shape (op)
  "Return the stable structural shape of an OT OP.

Payload values such as generated list/table IDs are intentionally omitted;
string payloads are represented by their lengths."
  (let ((sm (alist-get 'sm op)))
    (list (cons :ty (alist-get 'ty op))
          (cons :st (alist-get 'st op))
          (cons :si (alist-get 'si op))
          (cons :ei (alist-get 'ei op))
          (cons :ibi (alist-get 'ibi op))
          (cons :s-length (and (stringp (alist-get 's op))
                               (length (alist-get 's op))))
          (cons :sm-keys
                (sort (mapcar (lambda (key)
                                (if (symbolp key)
                                    (symbol-name key)
                                  (format "%s" key)))
                              (mapcar #'car sm))
                      #'string<)))))

(defun gdocs-test--op-shapes (ops)
  "Return stable shapes for OPS."
  (mapcar #'gdocs-test--op-shape ops))

(defun gdocs-test--count-substring (text needle)
  "Count non-overlapping occurrences of NEEDLE in TEXT."
  (let ((from 0) (count 0))
    (while (string-match (regexp-quote needle) text from)
      (cl-incf count)
      (setq from (match-end 0)))
    count))

(defun gdocs-test--comment-record (text replies)
  "Construct the synthetic discussion record shape expected by the parser."
  (vector nil nil nil (vector "text/plain" text) nil nil nil
          (vconcat
           (mapcar (lambda (reply)
                     (vector nil nil nil (vector "text/plain" reply)
                             nil nil nil nil))
                   replies))))

(defun gdocs-test--comments-json (fixture)
  "Build an XSSI-prefixed `/docos/p/sync' response from FIXTURE."
  (let ((bundles
         (vconcat
          (mapcar
           (lambda (thread)
             (vector (plist-get thread :id)
                     (gdocs-test--comment-record
                      (plist-get thread :text)
                      (plist-get thread :replies))
                     nil nil nil nil nil
                     (plist-get thread :anchor)))
           (plist-get fixture :threads)))))
    (concat ")]}'\n"
            (json-encode (vector (vector "sr" bundles 1700000000000))))))

(defun gdocs-test--anchor-op (start end id)
  "Construct a synthetic `doco_anchor' style op.
END is the inclusive final OT position."
  `((ty . "as") (st . "doco_anchor") (si . ,start) (ei . ,end)
    (sm . ((das_a . ((cv . ((op . "set")
                            (opValue . (,id))))))))))

(defun gdocs-test--table-body (rows &optional after)
  "Construct an OT table body for ROWS, optionally followed by AFTER."
  (concat
   (string gdocs--ot-table-open)
   (mapconcat
    (lambda (row)
      (concat (string gdocs--ot-row-end)
              (mapconcat (lambda (cell)
                           (concat (string gdocs--ot-cell-end)
                                   cell "\n"))
                         row "")))
    rows "")
   (string gdocs--ot-table-close)
   (when after (concat "\n" after "\n"))))

(defun gdocs-test--table-ops (fixture)
  "Construct insert and table-attribute ops for table FIXTURE."
  (let* ((rows (plist-get fixture :rows))
         (body (gdocs-test--table-body rows (plist-get fixture :after)))
         (cols (apply #'max (mapcar #'length rows))))
    (list (gdocs-test--insert-op body)
          `((ty . "as") (st . "tbl") (si . 1) (ei . 1)
            (sm . ((tbls_tblid . ,(plist-get fixture :table-id))
                   (tbls_cols . ((cv . ((op . "set")
                                        (opValue . ,(make-list cols nil))))))))))))

;;; Parsing and low-level OT characterization

(ert-deftest gdocs-test-parse-single-model-chunk ()
  "A single modelChunk assignment yields its body and revision."
  (let* ((fixture (gdocs-test--fixture "basic-document"))
         (chunk (car (plist-get fixture :chunks)))
         (parsed (gdocs--parse-model-chunk
                  (gdocs-test--html-for-ops
                   (plist-get chunk :revision) (plist-get chunk :ops)))))
    (should (equal (plist-get parsed :revision) 9))
    (should (equal (plist-get parsed :ot-body) "Synthetic first chunk\n"))))

(ert-deftest gdocs-test-parse-multiple-chunks-and-highest-revision ()
  "All model chunks contribute inserts and the greatest revision wins."
  (let* ((fixture (gdocs-test--fixture "basic-document"))
         (html (gdocs-test--fixture-html fixture))
         (raw (gdocs--parse-model-chunks-raw html))
         (full (gdocs--parse-model-chunk-full html))
         (parsed (gdocs--parse-model-chunk html)))
    (should (= (length raw) 2))
    (should (= (plist-get full :revision) 12))
    (should (= (plist-get parsed :revision) 12))
    (should (equal (plist-get parsed :ot-body)
                   "Synthetic first chunk\nSynthetic second chunk\n")))
  (let* ((valid (gdocs-test--html-for-ops
                 4 (list (gdocs-test--insert-op "valid\n"))))
         (html (concat "DOCS_modelChunk = {not valid JSON};\n" valid))
         (parsed (gdocs--parse-model-chunk html)))
    (should (= (plist-get parsed :revision) 4))
    (should (equal (plist-get parsed :ot-body) "valid\n"))))

(ert-deftest gdocs-test-malformed-and-empty-model-chunks-are-safe ()
  "Malformed assignments are skipped and empty chunks do not become bodies."
  (should-not (gdocs--parse-model-chunk "DOCS_modelChunk = {oops};"))
  (should-not (gdocs--parse-model-chunk
               (gdocs-test--html-for-ops 1 nil)))
  (should-not (gdocs--parse-model-chunks-raw nil)))

(ert-deftest gdocs-test-structural-codepoint-mapping ()
  "Plain text drops structure while retaining exact OT positions."
  (let* ((ot (concat "A" (string gdocs--ot-table-open) "B"
                     (string gdocs--ot-cell-end) "C"
                     (string gdocs--ot-row-end) "D"))
         (plain+map (gdocs--ot-plain-and-map ot)))
    (should (equal (car plain+map) "ABCD"))
    (should (equal (append (cdr plain+map) nil) '(1 3 5 7)))
    (should (= (gdocs--ot-body-length ot) 7))
    (should (equal (gdocs--map-text-range-to-ot (cdr plain+map) 1 3)
                   '(3 . 6)))))

(ert-deftest gdocs-test-unsupported-entity-op-does-not-corrupt-text ()
  "Unknown entities remain ignorable metadata around an image placeholder."
  (let* ((fixture (gdocs-test--fixture "unsupported-entities"))
         (body (plist-get fixture :body))
         (ops (append (list (gdocs-test--insert-op body))
                      (plist-get fixture :unknown-ops)))
         (doc (gdocs-dm-from-ops nil nil nil body ops)))
    (should (equal (gdocs-dm-to-org doc) (plist-get fixture :expected-org)))
    (should (equal (mapcar #'gdocs-test--paragraph-view
                           (gdocs-dm-paragraphs doc))
                   '((:para nil nil nil (("Before" nil nil)))
                     (:para nil nil nil (("￼" nil nil)))
                     (:para nil nil nil (("After" nil nil))))))))

(ert-deftest gdocs-test-inline-image-decodes-and-renders-explicitly ()
  "A te.spi image attachment becomes a first-class remote placeholder."
  (let* ((fixture (gdocs-test--inline-case "one-image-between-paragraphs"))
         (body (plist-get fixture :body))
         (doc (gdocs-dm-from-ops nil nil nil body (plist-get fixture :ops)))
         (object (car (gdocs-dm-inline-objects doc)))
         (paragraph (nth 1 (gdocs-dm-paragraphs doc)))
         (org (gdocs-dm-to-org doc)))
    (should (eq (plist-get object :kind) :inline-object))
    (should (eq (plist-get object :object-kind) :image))
    (should (equal (plist-get object :entity-id)
                   "kix.synthetic-image-one"))
    (should (equal (plist-get object :content-id)
                   "s-blob-v1-IMAGE-synthetic-one"))
    (should (= (plist-get object :ot-position) 8))
    (should (= (plist-get object :width) 468.0))
    (should (= (plist-get object :height) 102.0))
    (should (eq (plist-get paragraph :kind) :inline-object))
    (should (string-match-p
             "^#\\+gdocs_inline_object: image kix.synthetic-image-one 468x102 content-id=s-blob-v1-IMAGE-synthetic-one$"
             org))
    (should-not (string-match-p "^\\*$" org))
    (should (equal org
                   (gdocs-dm-to-org (gdocs-dm-from-org org))))))

(ert-deftest gdocs-test-embedded-inline-image-marker-round-trips ()
  "An inline object sharing a paragraph uses a parseable Org token."
  (let* ((object '(:kind :inline-object
                         :entity-id "kix.synthetic-embedded"
                         :object-kind :image
                         :content-id "s-blob-v1-IMAGE-synthetic-embedded"
                         :width 10.0 :height 20.0 :ot-position 8))
         (doc (gdocs-dm-make-doc
               :inline-objects (list object)
               :paragraphs
               (list (list :kind :para
                           :runs (list (gdocs-dm-make-run "Before")
                                       (list :inline-object object)
                                       (gdocs-dm-make-run "After"))))))
         (org (gdocs-dm-to-org doc))
         (round-tripped (gdocs-dm-from-org org)))
    (should (equal org
                   "Before@@gdocs-inline-object:image kix.synthetic-embedded 10x20 content-id=s-blob-v1-IMAGE-synthetic-embedded@@After\n"))
    (should (= (length (gdocs-dm-inline-objects round-tripped)) 1))
    (should (equal (gdocs-dm-runs-text
                    (plist-get (car (gdocs-dm-paragraphs round-tripped))
                               :runs))
                   "BeforeAfter"))
    (should-error (gdocs-dm-to-ot doc) :type 'user-error)))

(ert-deftest gdocs-test-inline-images-use-te-positions-not-entity-order ()
  "Multiple images are sorted by OT position, not ae or te order."
  (let* ((fixture (gdocs-test--inline-case "multiple-images-not-entity-order"))
         (doc (gdocs-dm-from-ops nil nil nil
                                 (plist-get fixture :body)
                                 (plist-get fixture :ops)))
         (objects (gdocs-dm-inline-objects doc)))
    (should (equal (mapcar (lambda (object)
                             (list (plist-get object :entity-id)
                                   (plist-get object :ot-position)))
                           objects)
                   '(("kix.synthetic-image-one" 5)
                     ("kix.synthetic-image-two" 11))))))

(ert-deftest gdocs-test-literal-asterisk-remains-text ()
  "An ordinary star paragraph is not an inline object without te."
  (let* ((fixture (gdocs-test--inline-case "literal-asterisk-paragraph"))
         (doc (gdocs-dm-from-ops nil nil nil
                                 (plist-get fixture :body)
                                 (plist-get fixture :ops))))
    (should-not (gdocs-dm-inline-objects doc))
    (should-not (gdocs-dm-unsupported doc))
    (should (equal (gdocs-dm-to-org doc) "Before\n*\nAfter\n"))))

(ert-deftest gdocs-test-image-and-literal-asterisk-stay-distinct ()
  "Only the te-attached star becomes a remote image placeholder."
  (let* ((fixture (gdocs-test--inline-case "image-and-literal-asterisk"))
         (doc (gdocs-dm-from-ops nil nil nil
                                 (plist-get fixture :body)
                                 (plist-get fixture :ops)))
         (org (gdocs-dm-to-org doc)))
    (should (= (length (gdocs-dm-inline-objects doc)) 1))
    (should (equal org
                   (concat "Image\n"
                           "#+gdocs_inline_object: image kix.synthetic-image-mixed 468x102 content-id=s-blob-v1-IMAGE-synthetic-mixed\n"
                           "Literal\n*\nAfter\n")))))

(ert-deftest gdocs-test-ambiguous-inline-image-mapping-is-unsupported ()
  "An image without an authoritative te attachment is not guessed."
  (let* ((fixture (gdocs-test--inline-case "ambiguous-image-attachment"))
         (doc (gdocs-dm-from-ops nil nil nil
                                 (plist-get fixture :body)
                                 (plist-get fixture :ops))))
    (should-not (gdocs-dm-inline-objects doc))
    (should (gdocs-dm-unsupported doc))
    (should (string-match-p "^#\\+gdocs_unsupported: "
                            (gdocs-dm-to-org doc)))))

;;; Doc-model formatting

(ert-deftest gdocs-test-decoder-headings-and-all-inline-styles ()
  "The decoder preserves paragraph kinds and all supported run styles."
  (let* ((fixture (gdocs-test--fixture "styles"))
         (body (plist-get fixture :body))
         (doc (gdocs-dm-from-ops 21 nil nil body
                                 (gdocs-test--fixture-ops fixture)))
         (paragraphs (gdocs-dm-paragraphs doc))
         (runs (append (plist-get (car paragraphs) :runs)
                       (plist-get (cadr paragraphs) :runs))))
    (should (eq (plist-get (car paragraphs) :kind) :heading))
    (should (= (plist-get (car paragraphs) :level) 2))
    (dolist (entry '(("Bold" :bold)
                     ("italic" :italic)
                     ("underline" :underline)
                     ("strike" :strike)
                     ("code" :code)
                     ("verbatim" :verbatim)))
      (let ((run (seq-find (lambda (candidate)
                             (string= (plist-get candidate :text)
                                      (car entry)))
                           runs)))
        (should run)
        (should (memq (cadr entry) (plist-get run :styles)))))
    (let ((nested (seq-find (lambda (run)
                              (string= (plist-get run :text) "style"))
                            runs)))
      (should nested)
      (should (memq :bold (plist-get nested :styles)))
      (should (memq :italic (plist-get nested :styles))))))

(ert-deftest gdocs-test-render-title-subtitle-headings-and-blank-padding ()
  "Title keywords and repeated blank paragraphs render deterministically."
  (let* ((fixture (gdocs-test--fixture "styles"))
         (model (gdocs-dm-make-doc
                 :paragraphs
                 (append
                  (list (list :kind :title
                              :runs (list (gdocs-dm-make-run "Same Name")))
                        (list :kind :subtitle
                              :runs (list (gdocs-dm-make-run "A subtitle"))))
                  (plist-get fixture :repeated-blank-model))))
         (org (gdocs-dm-to-org model)))
    (should (equal (gdocs-test--normalize-org org)
                   "#+title: Same Name\n\n#+subtitle: A subtitle\n\nBefore\n\n** Heading\n\nAfter\n"))))

(ert-deftest gdocs-test-canonical-heading-spacing-policy ()
  "Heading-like entries use one idempotent blank line of padding."
  (let ((para (lambda (kind text &optional level)
                (list :kind kind
                      :level level
                      :runs (when text (list (gdocs-dm-make-run text))))))
        (blank (lambda () (list :kind :blank :runs nil))))
    (dolist (paragraphs-and-expected
             (list
              (cons (list (funcall para :para "Before")
                          (funcall para :heading "Heading" 2)
                          (funcall para :para "After"))
                    "Before\n\n** Heading\n\nAfter\n")
              (cons (list (funcall para :para "Before")
                          (funcall blank)
                          (funcall blank)
                          (funcall para :heading "Heading" 2)
                          (funcall blank)
                          (funcall blank)
                          (funcall para :para "After"))
                    "Before\n\n** Heading\n\nAfter\n")
              (cons (list (funcall para :heading "One" 1)
                          (funcall para :heading "Two" 1))
                    "* One\n\n* Two\n")))
      (should (equal (gdocs-dm-to-org
                      (gdocs-dm-make-doc
                       :paragraphs (car paragraphs-and-expected)))
                     (cdr paragraphs-and-expected))))))

(ert-deftest gdocs-test-canonical-blank-model-and-org-round-trip ()
  "Repeated, edge, and meaningful blanks have a stable lossy policy."
  (let ((para (lambda (kind text)
                (list :kind kind
                      :runs (when text (list (gdocs-dm-make-run text)))))))
    (let* ((model
            (gdocs-dm-make-doc
             :paragraphs
             (list (funcall para :blank nil)
                   (funcall para :blank nil)
                   (funcall para :para "First")
                   (funcall para :blank nil)
                   (funcall para :blank nil)
                   (funcall para :para "Second")
                   (funcall para :blank nil)
                   (funcall para :blank nil))))
           (first (gdocs-dm-to-org model))
           (second (gdocs-dm-to-org (gdocs-dm-from-org first))))
      (should (equal first "First\n\nSecond\n"))
      (should (equal first second)))
    ;; A blank between ordinary content and a list is meaningful; without it
    ;; list entries remain contiguous with the preceding paragraph.
    (should (equal
             (gdocs-dm-to-org
              (gdocs-dm-from-org "Paragraph\n\n\n- one\n- two\n"))
             "Paragraph\n\n- one\n- two\n"))
    (should (equal
             (gdocs-dm-to-org
              (gdocs-dm-from-org "Paragraph\n- one\n- two\n"))
             "Paragraph\n- one\n- two\n"))))

(ert-deftest gdocs-test-canonical-title-subtitle-spacing ()
  "Title and Subtitle keywords follow the same one-blank policy."
  (let ((title (list :kind :title
                     :runs (list (gdocs-dm-make-run "Document"))))
        (subtitle (list :kind :subtitle
                        :runs (list (gdocs-dm-make-run "A subtitle"))))
        (para (list :kind :para
                    :runs (list (gdocs-dm-make-run "Body")))))
    (should (equal
             (gdocs-dm-to-org (gdocs-dm-make-doc
                               :paragraphs (list title para)))
             "#+title: Document\n\nBody\n"))
    (should (equal
             (gdocs-dm-to-org (gdocs-dm-make-doc
                               :paragraphs (list title subtitle para)))
             "#+title: Document\n\n#+subtitle: A subtitle\n\nBody\n"))))

(ert-deftest gdocs-test-canonical-source-block-and-boundaries ()
  "Empty source lines stay inside one source block, without padding noise."
  (let ((code (lambda (text)
                (list :kind :code
                      :runs (list (gdocs-dm-make-run text)))))
        (heading (list :kind :heading :level 1
                       :runs (list (gdocs-dm-make-run "Code")))))
    (should (equal
             (gdocs-dm-to-org
              (gdocs-dm-make-doc
               :paragraphs (list heading
                                 (funcall code "alpha")
                                 (funcall code "")
                                 (funcall code "beta"))))
             "* Code\n\n#+begin_src text\nalpha\n\nbeta\n#+end_src\n"))
    ;; A generic blank between code paragraphs is normalized to the same
    ;; empty source line rather than splitting the block.
    (should (equal
             (gdocs-dm-to-org
              (gdocs-dm-make-doc
               :paragraphs (list (funcall code "alpha")
                                 (list :kind :blank :runs nil)
                                 (list :kind :blank :runs nil)
                                 (funcall code "beta"))))
             "#+begin_src text\nalpha\n\nbeta\n#+end_src\n"))))

(ert-deftest gdocs-test-canonical-spacing-does-not-create-diff-noise ()
  "Canonical render/parse cycles compare equal at paragraph granularity."
  (let* ((source "Before\n\n\n* Heading\n\n\nAfter\n")
         (first (gdocs-dm-to-org (gdocs-dm-from-org source)))
         (second (gdocs-dm-to-org (gdocs-dm-from-org first))))
    (should (equal first "Before\n\n* Heading\n\nAfter\n"))
    (should (equal first second))
    (should-not (gdocs--diff-paragraphs first second))
    ;; Explicit Google blanks around a heading normalize to the same model as
    ;; synthetic Org padding, so an incremental push has no spacing-only ops.
    (let* ((old (gdocs-dm-make-doc
                 :paragraphs
                 (list (list :kind :para
                             :runs (list (gdocs-dm-make-run "Before")))
                       (list :kind :blank :runs nil)
                       (list :kind :heading :runs
                             (list (gdocs-dm-make-run "Heading")))
                       (list :kind :blank :runs nil)
                       (list :kind :para
                             :runs (list (gdocs-dm-make-run "After"))))))
           (new (gdocs-dm-from-org first)))
      (should-not (gdocs-dm-to-incremental-save-commands old new)))))

(ert-deftest gdocs-test-render-list-variants-and-nesting ()
  "Bullet/number glyphs and nesting become stable Org list markers."
  (let* ((fixture (gdocs-test--fixture "lists"))
         (body (plist-get fixture :body))
         (doc (gdocs-dm-from-ops nil nil nil body
                                 (gdocs-test--fixture-ops fixture))))
    (should (equal (gdocs-test--normalize-org (gdocs-dm-to-org doc))
                   "- Bullet one\n  - Nested bullet\n1. Number one\n  1. Nested number\n"))))

(ert-deftest gdocs-test-render-table-model ()
  "Table structure and cell text survive decode and Org rendering."
  (let* ((fixture (gdocs-test--fixture "tables"))
         (body (gdocs-test--table-body (plist-get fixture :rows)
                                       (plist-get fixture :after)))
         (doc (gdocs-dm-from-ops nil nil nil body
                                 (gdocs-test--table-ops fixture)))
         (table (car (gdocs-dm-paragraphs doc))))
    (should (eq (plist-get table :kind) :table))
    (should (= (plist-get table :cols) 2))
    (should (equal (gdocs-test--normalize-org (gdocs-dm-to-org doc))
                   "| A1 | B1 |\n| A2 | B2 |\n\nAfter the table\n"))
    (let* ((org-doc (gdocs-dm-from-org "| A1 | B1 |\n| A2 | B2 |\n"))
           (built (gdocs-dm-to-ot org-doc))
           (ot-body (car built))
           (ops (cdr built)))
      (should (= (aref ot-body 0) gdocs--ot-table-open))
      (should (string-match-p (regexp-quote (string gdocs--ot-cell-end)) ot-body))
      (should (seq-some (lambda (op) (equal (alist-get 'st op) "tbl"))
                        ops)))))

(ert-deftest gdocs-test-source-block-rendering ()
  "Contiguous code paragraphs render as one source block."
  (let* ((doc (gdocs-dm-make-doc
               :paragraphs
               (list (list :kind :code
                           :runs (list (gdocs-dm-make-run "(alpha)")))
                     (list :kind :code
                           :runs (list (gdocs-dm-make-run "(beta)"))))))
         (org (gdocs-dm-to-org doc)))
    (should (equal org "#+begin_src text\n(alpha)\n(beta)\n#+end_src\n"))))

;;; Org -> doc-model and round trips

(ert-deftest gdocs-test-org-to-model-titles-styles-lists-source-and-table ()
  "The Org parser exposes the supported surface as doc-model paragraphs."
  (let* ((org-text
          (concat "#+title: Local title\n"
                  "#+subtitle: Local subtitle\n\n"
                  "* Heading\n\n"
                  "A *bold* /italic/ _under_ +strike+ =verbatim= ~code~.\n\n"
                  "- bullet\n"
                  "1. numbered\n\n"
                  "#+begin_src emacs-lisp\n(message \"ok\")\n#+end_src\n\n"
                  "| A | B |\n|---+---|\n| C | D |\n"))
         (doc (gdocs-dm-from-org org-text))
         (kinds (mapcar (lambda (p) (plist-get p :kind))
                        (gdocs-dm-paragraphs doc)))
         (runs (plist-get (nth 3 (gdocs-dm-paragraphs doc)) :runs)))
    (should (equal (seq-take kinds 4) '(:title :subtitle :heading :para)))
    (should (memq :bold (plist-get (seq-find
                                    (lambda (r) (string= (plist-get r :text)
                                                         "bold"))
                                    runs)
                                   :styles)))
    (should (member :list kinds))
    (should (member :code kinds))
    (should (member :table kinds))))

(ert-deftest gdocs-test-org-link-runs-and-rendered-labels ()
  "Labeled HTTP and mail links retain their URLs and visible labels."
  (let* ((fixture (gdocs-test--fixture "links"))
         (doc (gdocs-dm-from-org (plist-get fixture :org-text)))
         (runs (plist-get (car (gdocs-dm-paragraphs doc)) :runs)))
    (should (equal (mapcar #'gdocs-test--run-view runs)
                   (mapcar #'gdocs-test--run-view (plist-get fixture :runs))))
    (should (equal (concat (gdocs-dm-runs-text runs) "\n")
                   (plist-get fixture :plain-text)))
    (should (equal (gdocs-dm-to-org doc) (plist-get fixture :org-text)))))

(ert-deftest gdocs-test-pull-link-ranges-preserve-boundaries-and-unsets ()
  "Link ranges split runs at destination changes and explicit unsets."
  (let* ((body "one two three\n")
         (ops (list (gdocs-test--insert-op body)
                    (gdocs-test--link-range-op body "one"
                                               "https://one.example")
                    (gdocs-test--link-range-op body "two"
                                               "https://two.example")
                    ;; Remove the final two characters of the second link.
                    (gdocs-test--link-unset-op 6 7)))
         (doc (gdocs-dm-from-ops nil nil nil body ops))
         (runs (plist-get (car (gdocs-dm-paragraphs doc)) :runs)))
    (should (equal (mapcar #'gdocs-test--run-view runs)
                   '(("one" nil "https://one.example")
                     (" " nil nil)
                     ("t" nil "https://two.example")
                     ("wo three" nil nil))))
    (should (equal (gdocs-dm-to-org doc)
                   "[[https://one.example][one]] [[https://two.example][t]]wo three\n"))))

(ert-deftest gdocs-test-pull-link-rendering-variants ()
  "Pull renders labeled, bare, and mailto links with their destinations."
  (let* ((body "Example https://example.com mail\n")
         (ops (list (gdocs-test--insert-op body)
                    (gdocs-test--link-range-op body "Example"
                                               "https://example.com")
                    (gdocs-test--link-range-op body "https://example.com"
                                               "https://example.com")
                    (gdocs-test--link-range-op body "mail"
                                               "mailto:reader@example.com")))
         (doc (gdocs-dm-from-ops nil nil nil body ops))
         (round-tripped (gdocs-dm-from-org (gdocs-dm-to-org doc))))
    (should (equal (gdocs-dm-to-org doc)
                   "[[https://example.com][Example]] [[https://example.com]] [[mailto:reader@example.com][mail]]\n"))
    (should (equal (gdocs-test--model-view doc)
                   (gdocs-test--model-view round-tripped)))))

(ert-deftest gdocs-test-pull-link-spanning-style-runs-renders-one-link ()
  "A link covering styled sub-runs gets one logical Org link wrapper."
  (let* ((body "Bold italic code\n")
         (ops (list (gdocs-test--insert-op body)
                    (gdocs-test--link-range-op body "Bold italic code"
                                               "https://example.com")
                    (gdocs-test--text-range-op
                     body '(:text "Bold" :styles (:bold)))
                    (gdocs-test--text-range-op
                     body '(:text "italic" :styles (:italic)))
                    (gdocs-test--text-range-op
                     body '(:text "code" :styles (:code)))))
         (doc (gdocs-dm-from-ops nil nil nil body ops))
         (org (gdocs-dm-to-org doc)))
    (should (equal org
                   "[[https://example.com][*Bold* /italic/ ~code~]]\n"))
    (should (= (gdocs-test--count-substring org "[[") 1))
    (should (= (gdocs-test--count-substring org "]]") 1))))

(ert-deftest gdocs-test-pull-code-styled-link-is-not-source-block ()
  "A code-styled link remains an inline link when it fills a paragraph."
  (let* ((body "code\n")
         (ops (list (gdocs-test--insert-op body)
                    (gdocs-test--link-range-op body "code"
                                               "https://example.com")
                    (gdocs-test--text-range-op
                     body '(:text "code" :styles (:code)))))
         (doc (gdocs-dm-from-ops nil nil nil body ops)))
    (should (eq (plist-get (car (gdocs-dm-paragraphs doc)) :kind) :para))
    (should (equal (gdocs-dm-to-org doc)
                   "[[https://example.com][~code~]]\n"))))

(ert-deftest gdocs-test-linked-and-unlinked-identical-style-stays-bounded ()
  "A link boundary does not leak into adjacent text with the same style."
  (let* ((body "linked plain\n")
         (ops (list (gdocs-test--insert-op body)
                    (gdocs-test--link-range-op body "linked"
                                               "https://example.com")
                    (gdocs-test--text-range-op
                     body '(:text "linked plain" :styles (:bold)))))
         (doc (gdocs-dm-from-ops nil nil nil body ops))
         (org (gdocs-dm-to-org doc))
         (round-tripped (gdocs-dm-from-org org)))
    (should (equal org "*[[https://example.com][linked]] plain*\n"))
    (should (equal (gdocs-test--model-view doc)
                   (gdocs-test--model-view round-tripped)))))

(ert-deftest gdocs-test-pull-link-escaping-round-trips ()
  "Link targets and descriptions with Org-significant characters are safe."
  (let* ((body "A]B*\n")
         (url "https://example.com/a]b")
         (ops (list (gdocs-test--insert-op body)
                    (gdocs-test--link-range-op body "A]B*" url)))
         (decoded (gdocs-dm-from-ops nil nil nil body ops))
         (org (gdocs-dm-to-org decoded))
         (round-tripped (gdocs-dm-from-org org)))
    (should (equal org
                   (concat "[[https://example.com/a\\]b][A"
                           gdocs--org-link-description-sentinel
                           "]"
                           gdocs--org-link-description-sentinel
                           "B\\*]]\n")))
    (should (equal (gdocs-test--model-view decoded)
                   (gdocs-test--model-view round-tripped)))
    (let* ((ot (gdocs-dm-to-ot round-tripped))
           (link-op (seq-find (lambda (op)
                                (equal (alist-get 'st op) "link"))
                              (cdr ot)))
           (lnks (alist-get 'lnks_link (alist-get 'sm link-op))))
      (should link-op)
      (should (equal (alist-get 'ulnk_url lnks) url)))))

(ert-deftest gdocs-test-link-description-specials-round-trip ()
  "All inline Org delimiters remain literal inside a pulled link label."
  (let* ((text (concat "* / _ + = ~ [ ] " (string ?\\)))
         (url "https://example.com/special?a=[b]")
         (doc (gdocs-dm-make-doc
               :paragraphs
               (list (list :kind :para
                           :runs (list (gdocs-dm-make-run text nil url))))))
         (org (gdocs-dm-to-org doc))
         (round-tripped (gdocs-dm-from-org org))
         (run (car (plist-get (car (gdocs-dm-paragraphs round-tripped))
                              :runs))))
    (should (equal text (plist-get run :text)))
    (should (equal url (plist-get run :link)))))

(ert-deftest gdocs-test-malformed-link-operation-is-ignored ()
  "Malformed link modifiers do not attach a URL to unrelated text."
  (let* ((body "abc\n")
         (valid (gdocs-test--link-range-op body "a"
                                           "https://valid.example"))
         (malformed `((ty . "as") (st . "link") (si . 2) (ei . 3)
                      (sm . ((lnks_link . ((ulnk_url . 42)))))))
         (doc (gdocs-dm-from-ops nil nil nil body
                                 (list (gdocs-test--insert-op body)
                                       valid malformed)))
         (runs (plist-get (car (gdocs-dm-paragraphs doc)) :runs)))
    (should (equal (mapcar #'gdocs-test--run-view runs)
                   '(("a" nil "https://valid.example")
                     ("bc" nil nil))))))

(ert-deftest gdocs-test-org-model-org-normalized-round-trip ()
  "Rendering a parsed Org model is stable after normalization."
  (let* ((source "#+title: Round trip\n\n* Heading\n\nA *bold* and /italic/.\n")
         (first (gdocs-dm-to-org (gdocs-dm-from-org source)))
         (second (gdocs-dm-to-org (gdocs-dm-from-org first))))
    (should (equal (gdocs-test--normalize-org first)
                   (gdocs-test--normalize-org second)))))

(ert-deftest gdocs-test-model-ot-model-round-trip-preserves-user-shape ()
  "OT emission followed by decoding preserves text and styles."
  (let* ((source "#+title: Round trip\n\n* Heading\n\nA *bold* and /italic/.\n")
         (original (gdocs-dm-from-org source))
         (built (gdocs-dm-to-ot original))
         (decoded (gdocs-dm-from-ops nil nil nil (car built) (cdr built))))
    (should (equal (gdocs-test--model-view original)
                   (gdocs-test--model-view decoded)))))

(ert-deftest gdocs-test-generated-save-command-shapes-ignore-unstable-ids ()
  "Save commands expose stable OT shapes without comparing generated IDs."
  (let* ((doc (gdocs-dm-from-org
               "#+title: Shape\n\nA *bold* [[https://example.test][link]].\n"))
         (commands (gdocs-dm-to-save-commands 23 doc))
         (shapes (gdocs-test--op-shapes commands)))
    (should (equal (mapcar (lambda (shape) (cdr (assq :ty shape)))
                           (seq-take shapes 2))
                   '("ds" "is")))
    (should (seq-some (lambda (shape)
                        (equal (cdr (assq :st shape)) "text"))
                      shapes))
    (should (seq-some (lambda (shape)
                        (equal (cdr (assq :st shape)) "link"))
                      shapes))
    (should (= (cdr (assq :s-length (cadr shapes)))
               (length (car (gdocs-dm-to-ot doc)))))))

;;; Comments

(ert-deftest gdocs-test-comment-anchor-extraction ()
  "Doco anchor ops decode their kix ID and inclusive range."
  (let* ((op (gdocs-test--anchor-op 6 7 "kix.synthetic-final-letter"))
         (anchors (gdocs--decode-doco-anchors (list op))))
    (should (equal anchors
                   '(("kix.synthetic-final-letter" 6 . 7))))))

(ert-deftest gdocs-test-comment-response-parsing-and-reply-numbering ()
  "Thread roots and replies are numbered in server order."
  (let* ((fixture (gdocs-test--fixture "comments"))
         (comments (gdocs--parse-docos-sync-response
                    (gdocs-test--comments-json fixture))))
    (should (= (length comments) 3))
    (should (= (car (nth 0 comments)) 1))
    (should (equal (plist-get (cdr (nth 0 comments)) :text)
                   "Root   comment"))
    (should (= (car (nth 1 comments)) 2))
    (should (equal (plist-get (cdr (nth 1 comments)) :anchor)
                   "kix.synthetic-final-letter"))
    (should (= (car (nth 2 comments)) 3))))

(ert-deftest gdocs-test-comment-inline-anchor-at-final-letter ()
  "A final-letter anchor lands outside the closing emphasis marker."
  (let* ((fixture (gdocs-test--fixture "comments"))
         (anchor (plist-get fixture :anchor))
         (range (plist-get fixture :anchor-range))
         (anchor-map
          (list (cons anchor
                      (cons (plist-get range :start)
                            (plist-get range :end)))))
         (comments '((1 :text "Root" :anchor "kix.synthetic-final-letter")
                     (2 :text "Reply" :anchor "kix.synthetic-final-letter")))
         (rendered (gdocs--inline-comment-refs
                    (plist-get fixture :org-body)
                    (plist-get fixture :ot-body)
                    anchor-map comments)))
    (should (equal rendered "A *word*[fn:1]\n"))))

(ert-deftest gdocs-test-comment-inclusive-ei-does-not-split-words ()
  "An inclusive EI places refs after the final letter of a word."
  (dolist (word '("coverage" "code areas"))
    (let* ((anchor "kix.inclusive-word")
           (ot-body (concat word "\n"))
           (si 1)
           (ei (length word))
           ;; [SI, EI) omits the final letter; [SI, EI] includes it.
           (exclusive (substring ot-body (1- si) (1- ei)))
           (inclusive (substring ot-body (1- si) ei)))
      (should (equal exclusive (substring word 0 -1)))
      (should (equal inclusive word))
      (should
       (equal
        (gdocs--inline-comment-refs
         ot-body ot-body
         (list (cons anchor (cons si ei)))
         (list (list 1 :text "synthetic" :anchor anchor)))
        (concat word "[fn:1]\n"))))))

(ert-deftest gdocs-test-comment-anchor-does-not-snap-to-word-boundary ()
  "An explicitly partial range remains partial rather than being expanded."
  (let* ((prefix "prefix ")
         (word "coverage")
         (partial (substring word 0 -1))
         (ot-body (concat prefix word " suffix\n"))
         (anchor "kix.partial-word")
         (si (1+ (length prefix)))
         (ei (+ si (length partial) -1)))
    (should
     (equal
      (gdocs--inline-comment-refs
       ot-body ot-body
       (list (cons anchor (cons si ei)))
       (list (list 1 :text "synthetic" :anchor anchor)))
      (concat prefix partial "[fn:1]" (substring word -1) " suffix\n")))))

(ert-deftest gdocs-test-comment-inclusive-ei-preserves-punctuation ()
  "Punctuation included by EI remains before the inline ref."
  (dolist (sentence '("sentence." "question?"))
    (let ((anchor "kix.inclusive-punctuation"))
      (should
       (equal
        (gdocs--inline-comment-refs
         (concat sentence "\n")
         (concat sentence "\n")
         (list (cons anchor (cons 1 (length sentence))))
         (list (list 1 :text "synthetic" :anchor anchor)))
        (concat sentence "[fn:1]\n"))))))

(ert-deftest gdocs-test-comment-inclusive-ei-places-ref-outside-emphasis ()
  "Inline refs after styled text stay outside Org emphasis markers."
  (let ((anchor "kix.emphasized-word"))
    (should
     (equal
      (gdocs--inline-comment-refs
       "*coverage*\n"
       "coverage\n"
       (list (cons anchor (cons 1 8)))
       (list (list 1 :text "synthetic" :anchor anchor)))
      "*coverage*[fn:1]\n"))))

(ert-deftest gdocs-test-comment-trailing-selected-space-is-not-anchor-end ()
  "Trailing selected horizontal whitespace is ignored for placement."
  (let ((anchor "kix.trailing-space"))
    (should
     (equal
      (gdocs--inline-comment-refs
       "coverage \n"
       "coverage \n"
       (list (cons anchor (cons 1 9)))
       (list (list 1 :text "synthetic" :anchor anchor)))
      "coverage[fn:1] \n"))))

(ert-deftest gdocs-test-comment-structural-codepoint-near-ei ()
  "Structural OT codepoints do not move an anchor one character early."
  (let ((marker (string gdocs--ot-cell-end))
        (anchor "kix.structural-boundary"))
    ;; First, EI is a visible character after a structural marker.
    (should
     (equal
      (gdocs--inline-comment-refs
       "coverage\n"
       (concat "coverag" marker "e\n")
       (list (cons anchor (cons 1 9)))
       (list (list 1 :text "synthetic" :anchor anchor)))
      "coverage[fn:1]\n"))
    ;; An anchor can also end on a structural position (for example, at a
    ;; table-cell boundary).  It still belongs after the preceding text.
    (should
     (equal
      (gdocs--inline-comment-refs
       "coverage\n"
       (concat "coverage" marker "\n")
       (list (cons anchor (cons 1 9)))
       (list (list 1 :text "synthetic" :anchor anchor)))
      "coverage[fn:1]\n"))))

(ert-deftest gdocs-test-comment-ambiguous-context-is-not-placed ()
  "Repeated context does not receive a misleading inline footnote."
  (let* ((fixture (gdocs-test--fixture "comments"))
         (range (plist-get fixture :ambiguous-range))
         (anchor-map (list (cons "kix.ambiguous"
                                 (cons (plist-get range :start)
                                       (plist-get range :end))))))
    (should (equal
             (gdocs--inline-comment-refs
              (plist-get fixture :ambiguous-org-body)
              (plist-get fixture :ambiguous-ot-body)
              anchor-map
              '((1 :text "ambiguous" :anchor "kix.ambiguous")))
             (plist-get fixture :ambiguous-org-body)))))

(ert-deftest gdocs-test-comment-whitespace-normalization-and-section ()
  "NBSP and horizontal whitespace normalize in the local comments subtree."
  (let* ((fixture (gdocs-test--fixture "comments"))
         (comments (gdocs--parse-docos-sync-response
                    (gdocs-test--comments-json fixture)))
         (section (gdocs--render-comments-section comments)))
    (should (string-match-p "\\[fn:1\\] Root comment" section))
    (should (string-match-p "\\[fn:2\\] A reply" section))
    (should (string-match-p "\\[fn:3\\] Second comment" section))
    (should (equal (gdocs--normalize-comment-text "  a  \t b  ") "a b"))))

;;; Pull/push helpers and preflight

(ert-deftest gdocs-test-edit-state-metadata-and-title-extraction ()
  "Edit-state parsing extracts title, tokens, revision, and OT body."
  (let* ((fixture (gdocs-test--fixture "basic-document"))
         (html (concat "<title>Synthetic Document - Google Docs</title>\n"
                       "\"info_params\": {\"token\": \"token.synthetic\", "
                       "\"ouid\": \"ouid.synthetic\"}\n"
                       "\"revision\": 88, \"docs-smv\": 42, "
                       "\"docs-smfb\": [1, \"segment.synthetic\"]\n"
                       (gdocs-test--fixture-html fixture)))
         (state (gdocs--parse-edit-state-html html)))
    ;; The modelChunk revision is the canonical revision once it is present.
    (should (equal (plist-get state :title) "Synthetic Document"))
    (should (equal (plist-get state :token) "token.synthetic"))
    (should (equal (plist-get state :ouid) "ouid.synthetic"))
    (should (= (plist-get state :revision) 12))
    (should (= (plist-get state :smv) 42))
    (should (equal (plist-get state :smb-seg) "segment.synthetic"))
    (should (string-suffix-p "Synthetic second chunk\n"
                             (plist-get state :ot-body)))))

(ert-deftest gdocs-test-ot-decode-pipeline-builds-pull-body ()
  "The pure pull pipeline extracts title, date, body, and sync metadata."
  (let* ((fixture (gdocs-test--fixture "basic-document"))
         (body (plist-get fixture :body))
         (ops (gdocs-test--fixture-ops
               (list :body body
                     :paragraph-styles (plist-get fixture :paragraph-styles))))
         (html (gdocs-test--html-for-ops 12 ops))
         (state (list :revision 12
                      :title (plist-get fixture :title)
                      :ot-body body))
         (result (gdocs--ot-decode-pipeline
                  (plist-get fixture :doc-id) html state 1760000000000))
         (pull-body (cdr result)))
    (should (equal (car result) "Synthetic Document"))
    (should (string-match-p
             "^:PROPERTIES:\n:GDOC_ID: synthetic-basic-document\n"
             pull-body))
    (should (string-match-p ":GDOC_TITLE: Synthetic Document" pull-body))
    (should (string-match-p ":GDOC_REVISION: 12" pull-body))
    (should (string-match-p "^#\\+date: \\[20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]"
                            pull-body))
    ;; The Drive name is in GDOC_TITLE; only the body Title style is visible.
    (should (= (gdocs-test--count-substring pull-body
                                            "#+title: Synthetic Document")
               1))
    (should (string-suffix-p "Body text\n" pull-body))))

(ert-deftest gdocs-test-pipeline-drive-title-without-body-title ()
  "A Drive name does not create a synthetic Org title keyword."
  (let* ((result (gdocs-test--title-pipeline "Drive name" "Body\n" nil))
         (pull-body (cdr result)))
    (should (equal (car result) "Drive name"))
    (should (string-match-p ":GDOC_TITLE: Drive name" pull-body))
    (should-not (string-match-p "^#\\+title:" pull-body))))

(ert-deftest gdocs-test-pull-image-bearing-document-succeeds ()
  "Pull decodes an image-bearing model without emitting a star paragraph."
  (let* ((fixture (gdocs-test--inline-case "one-image-between-paragraphs"))
         (body (plist-get fixture :body))
         (ops (plist-get fixture :ops))
         (state (list :revision 17 :title "Synthetic image document"
                      :ot-body body))
         (result (gdocs--ot-decode-pipeline
                  "synthetic-image-document"
                  (gdocs-test--html-for-ops 17 ops)
                  state))
         (pull-body (cdr result)))
    (should (string-match-p
             "^#\\+gdocs_inline_object: image kix.synthetic-image-one 468x102 content-id=s-blob-v1-IMAGE-synthetic-one$"
             pull-body))
    (should (string-match-p ":GDOC_UNSUPPORTED: 1 inline image"
                            pull-body))
    (should-not (string-match-p "^\\*$" pull-body))))

(ert-deftest gdocs-test-buffer-body-preserves-remote-image-marker ()
  "The pushable body keeps the explicit remote image marker intact."
  (with-temp-buffer
    (insert ":PROPERTIES:\n:GDOC_ID: synthetic-image-document\n:END:\n\n"
            "Before\n"
            "#+gdocs_inline_object: image kix.synthetic-image-one 468x102 content-id=s-blob-v1-IMAGE-synthetic-one\n"
            "After\n")
    (org-mode)
    (should (equal
             (gdocs--buffer-body-as-plain)
             (concat "Before\n"
                     "#+gdocs_inline_object: image kix.synthetic-image-one 468x102 content-id=s-blob-v1-IMAGE-synthetic-one\n"
                     "After\n")))))

(ert-deftest gdocs-test-pipeline-body-title-is-independent-of-drive-name ()
  "A body Title paragraph remains visible and may equal or differ from the Drive name."
  (dolist (case '(("Same" "Same") ("Drive name" "Body title")))
    (let* ((drive-title (car case))
           (body-title (cadr case))
           (result (gdocs-test--title-pipeline
                    drive-title
                    (concat body-title "\nBody\n")
                    '((:line 1 :kind :title))))
           (pull-body (cdr result)))
      (should (string-match-p
               (format ":GDOC_TITLE: %s" drive-title)
               pull-body))
      (should (= (gdocs-test--count-substring
                  pull-body (format "#+title: %s" body-title))
                 1)))))

(ert-deftest gdocs-test-pipeline-preserves-title-and-subtitle-body-styles ()
  "Title and Subtitle body paragraphs are both emitted without metadata duplicates."
  (let* ((result (gdocs-test--title-pipeline
                  "Drive name"
                  "Body title\nBody subtitle\nBody\n"
                  '((:line 1 :kind :title)
                    (:line 2 :kind :subtitle))))
         (pull-body (cdr result)))
    (should (equal (gdocs-test--count-substring pull-body "#+title:") 1))
    (should (equal (gdocs-test--count-substring pull-body "#+subtitle:") 1))
    (should (string-suffix-p
             "#+title: Body title\n\n#+subtitle: Body subtitle\n\nBody\n"
             pull-body))))

(ert-deftest gdocs-test-pull-body-and-body-start-detection ()
  "Pull metadata is separated from the body without touching user content."
  (let* ((body (concat ":PROPERTIES:\n"
                       ":GDOC_ID: synthetic-id\n"
                       ":GDOC_REVISION: 12\n"
                       ":END:\n"
                       "#+title: Synthetic title\n"
                       "#+date: [2026-01-02 Fri]\n\n"
                       "* Body heading\nBody\n"))
         (parsed (gdocs--parse-pull-body body)))
    (should (equal (nth 0 parsed)
                   '(("GDOC_ID" . "synthetic-id")
                     ("GDOC_REVISION" . "12"))))
    (should (equal (nth 1 parsed) "Synthetic title"))
    (should (equal (nth 2 parsed) "* Body heading\nBody\n")))
  (let* ((body (concat ":PROPERTIES:\n"
                       ":GDOC_ID: synthetic-id\n"
                       ":GDOC_TITLE: Drive name\n"
                       ":END:\n"
                       "#+title: Body title\n\nBody\n"))
         (parsed (gdocs--parse-pull-body body)))
    (should-not (nth 1 parsed))
    (should (equal (nth 2 parsed) "#+title: Body title\n\nBody\n")))
  (with-temp-buffer
    (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n:END:\n"
            "#+title: Synthetic title\n\n\nBody\n")
    (org-mode)
    (should (equal (buffer-substring (gdocs--body-start-pos) (point-max))
                   "Body\n")))
  (with-temp-buffer
    (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n"
            ":GDOC_TITLE: Drive name\n:END:\n"
            "#+title: Body title\n\nBody\n")
    (org-mode)
    (should (equal (buffer-substring (gdocs--body-start-pos) (point-max))
                   "#+title: Body title\n\nBody\n"))))

(ert-deftest gdocs-test-legacy-title-migrates-without-body-title ()
  "A legacy synthetic title is removed when the remote body has no Title style."
  (let* ((initial (concat ":PROPERTIES:\n:GDOC_ID: synthetic-title-document\n:END:\n"
                          "#+title: Drive name\n\nBody\n"))
         (remote (concat ":PROPERTIES:\n"
                         ":GDOC_ID: synthetic-title-document\n"
                         ":GDOC_TITLE: Drive name\n"
                         ":GDOC_REVISION: 12\n:END:\n"
                         "Body\n"))
         (result (gdocs-test--apply-pull initial "Drive name" remote)))
    (should-not (string-match-p "^#\\+title:" result))
    (should (string-match-p ":GDOC_TITLE: Drive name" result))
    (should (string-match-p "Body\n\\'" result))))

(ert-deftest gdocs-test-legacy-duplicate-titles-preserve-body-title ()
  "Migration removes only synthetic metadata, including when both titles match."
  (dolist (body-title '("Drive name" "Body title"))
    (let* ((initial (concat ":PROPERTIES:\n:GDOC_ID: synthetic-title-document\n:END:\n"
                            "#+title: Drive name\n\n"
                            (format "#+title: %s\n\nBody\n" body-title)))
           (remote (concat ":PROPERTIES:\n"
                           ":GDOC_ID: synthetic-title-document\n"
                           ":GDOC_TITLE: Drive name\n"
                           ":GDOC_REVISION: 12\n:END:\n"
                           (format "#+title: %s\n\nBody\n" body-title)))
           (result (gdocs-test--apply-pull initial "Drive name" remote)))
      (should (= (gdocs-test--count-substring result "#+title:") 1))
      (should (string-match-p
               (format "^#\\+title: %s$" (regexp-quote body-title))
               result))
      (should (string-match-p ":GDOC_TITLE: Drive name" result)))))

(ert-deftest gdocs-test-pull-body-title-and-subtitle-are-pushable ()
  "Pulling Title and Subtitle keeps both in the body sent to the OT encoder."
  (let* ((pipeline (gdocs-test--title-pipeline
                    "Drive name"
                    "Body title\nBody subtitle\nBody\n"
                    '((:line 1 :kind :title)
                      (:line 2 :kind :subtitle))))
         (result (gdocs-test--apply-pull
                  ":PROPERTIES:\n:GDOC_ID: synthetic-title-document\n:END:\n"
                  (car pipeline)
                  (cdr pipeline))))
    (should (string-match-p ":GDOC_TITLE: Drive name" result))
    (let* ((body (with-temp-buffer
                   (insert result)
                   (org-mode)
                   (gdocs--buffer-body-as-plain)))
           (doc (gdocs-dm-from-org body))
           (kinds (mapcar (lambda (p) (plist-get p :kind))
                          (gdocs-dm-paragraphs doc)))
           (ops (cdr (gdocs-dm-to-ot doc)))
           (paragraph-headings
            (mapcar (lambda (op) (alist-get 'ps_hd (alist-get 'sm op)))
                    (seq-filter (lambda (op)
                                  (equal (alist-get 'st op) "paragraph"))
                                ops))))
      (should (equal (seq-take kinds 3) '(:title :subtitle :para)))
      (should (equal paragraph-headings '(100 101))))))

(ert-deftest gdocs-test-title-keywords-strip-to-ot-plain-text ()
  "Markup matching removes Title syntax but retains its body text and offsets."
  (let* ((org "#+title: Body title\n\n#+subtitle: Body subtitle\n\nBody\n")
         (stripped+offsets (gdocs--strip-org-markup org)))
    (should (equal (car stripped+offsets)
                   "Body title\n\nBody subtitle\n\nBody\n"))
    (should (= (aref (cdr stripped+offsets) 0)
               (length "#+title: ")))
    (should (= (aref (cdr stripped+offsets)
                     (string-match "Body subtitle" (car stripped+offsets)))
               (string-match "Body subtitle" org)))))

(ert-deftest gdocs-test-remote-org-body-retains-body-title-keywords ()
  "The remote push view retains Title/Subtitle body syntax."
  (let* ((body "Body title\nBody subtitle\nBody\n")
         (fixture (list :body body
                        :paragraph-styles '((:line 1 :kind :title)
                                            (:line 2 :kind :subtitle))))
         (ops (gdocs-test--fixture-ops fixture))
         (html (gdocs-test--html-for-ops 12 ops))
         (state (list :revision 12 :title "Drive name" :ot-body body)))
    (should (equal (gdocs--ot-remote-org-body
                    "synthetic-title-document" html state)
                   "#+title: Body title\n\n#+subtitle: Body subtitle\n\nBody\n"))))

(ert-deftest gdocs-test-pipeline-content-hash-matches-pushable-body ()
  "The pull hash covers body Title syntax but excludes its synchronization wrapper."
  (let* ((pipeline
          (gdocs-test--title-pipeline
           "Drive name"
           "Body title\nBody\n"
           (list (list :line 1 :kind :title))))
         (body (cdr pipeline)))
    (with-temp-buffer
      (insert body)
      (org-mode)
      (should (equal (org-entry-get (point-min) "GDOC_CONTENT_HASH" t)
                     (gdocs--current-body-hash))))))

(ert-deftest gdocs-test-content-hash-ignores-sync-metadata ()
  "The body hash ignores synchronization metadata but tracks body Title edits."
  (with-temp-buffer
    (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n"
            ":GDOC_TITLE: Drive title\n:END:\n"
            "#+title: Body title\n\nBody\n")
    (org-mode)
    (let ((hash (gdocs--current-body-hash)))
      (gdocs--put-top-property "GDOC_REVISION" "9")
      (gdocs--put-top-property "GDOC_TITLE" "Renamed Drive title")
      (should (equal hash (gdocs--current-body-hash)))
      (goto-char (point-min))
      (re-search-forward "^#\\+title:.*$" nil t)
      (replace-match "#+title: Changed body title" t t)
      (should-not (equal hash (gdocs--current-body-hash)))
      (goto-char (point-max))
      (insert "changed")
      (should-not (equal hash (gdocs--current-body-hash))))))

(ert-deftest gdocs-test-local-comments-subtree-is-stripped-before-push ()
  "The generated local comments projection and footnote refs are not pushed."
  (with-temp-buffer
    (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n:END:\n"
            "#+title: Synthetic title\n\n"
            "Visible text[fn:1]\n\n"
            "* Comments\n"
            ":PROPERTIES:\n:GDOC_LOCAL: t\n:END:\n\n"
            "[fn:1] A local comment\n")
    (org-mode)
    (should (equal (gdocs--buffer-body-as-plain) "Visible text\n\n"))))

(ert-deftest gdocs-test-heading-drawers-and-anchor-shifting ()
  "Heading OT anchors are stripped for push and shifted after edits."
  (with-temp-buffer
    (insert "* One\n:PROPERTIES:\n:GDOC_OT_START: 3\n:END:\nOne body\n\n"
            "* Two\n:PROPERTIES:\n:GDOC_OT_START: 20\n:END:\nTwo body\n")
    (org-mode)
    (let* ((stripped+anchors (gdocs--strip-heading-drawers (buffer-string)))
           (stripped (car stripped+anchors))
           (anchors (cdr stripped+anchors)))
      (should-not (string-match-p ":GDOC_OT_START:" stripped))
      (should (= (length anchors) 2))
      (should (equal (mapcar #'cdr anchors) '(3 20))))
    (gdocs--shift-buffer-anchors 'is 3 4)
    (should (string-match-p "^:GDOC_OT_START: 7$" (buffer-string)))
    (should (string-match-p "^:GDOC_OT_START: 24$" (buffer-string)))
    (gdocs--shift-buffer-anchors 'ds 7 4)
    (should (string-match-p "^:GDOC_OT_START: 20$" (buffer-string)))))

(ert-deftest gdocs-test-paragraph-diff-and-edit-shapes ()
  "Paragraph and contiguous diffs identify minimal inserted/deleted ranges."
  (let ((single (gdocs--diff-single-region "one\n\ntwo\n\nthree\n"
                                           "one\n\nchanged\n\nthree\n"))
        (regions (gdocs--diff-paragraphs "one\n\ntwo\n\nthree\n\n"
                                         "one\n\nchanged\n\nthree\n\nfour\n")))
    (should (= (plist-get single :start) 5))
    (should (equal (plist-get single :deleted) "two"))
    (should (equal (plist-get single :inserted) "changed"))
    (should (= (length regions) 2))
    (should (equal (gdocs--diff-prepend "body" "newbody") "new"))
    (should (equal (gdocs--diff-append "body" "bodynew") "new"))
    (should-not (gdocs--diff-prepend "body" "bodynew"))
    (should-not (gdocs--diff-single-region "same" "same"))))

(ert-deftest gdocs-test-org-to-ot-plain-helper-and-rich-input-guards ()
  "The plain OT helper preserves paragraph separators and rejects markup."
  (should (equal (gdocs--org-to-ot "one\n\ntwo\n") "one\ntwo\n"))
  (dolist (rich '("* heading\n" "- item\n" "1. item\n"
                  "| cell |\n" "#+begin_src text\nx\n#+end_src\n"
                  "[[https://example.test][link]]\n"))
    (should-error (gdocs--org-to-ot rich) :type 'user-error)))

(ert-deftest gdocs-test-incremental-save-diff-and-entity-fallback ()
  "Paragraph diffs emit minimal commands and lists trigger full replacement."
  (let* ((para (lambda (text)
                 (list :kind :para
                       :runs (list (gdocs-dm-make-run text)))))
         (old (gdocs-dm-make-doc
               :paragraphs (mapcar para '("one" "two" "three"))))
         (new (gdocs-dm-make-doc
               :paragraphs (mapcar para '("one" "changed" "three"))))
         (commands (gdocs-dm-to-incremental-save-commands old new)))
    (should (equal (seq-take (mapcar (lambda (op) (alist-get 'ty op)) commands)
                             2)
                   '("ds" "is")))
    (should (equal (alist-get 's (cadr commands)) "changed\n"))
    (should-not (gdocs-dm-to-incremental-save-commands old old)))
  (let* ((list-para (list :kind :list :list-id "list.synthetic"
                          :glyph :bullet :nest 0
                          :runs (list (gdocs-dm-make-run "item"))))
         (old (gdocs-dm-make-doc :paragraphs (list list-para)))
         (new (gdocs-dm-make-doc
               :paragraphs
               (list (plist-put (copy-sequence list-para)
                                :runs (list (gdocs-dm-make-run "changed"))))))
         (commands (gdocs-dm-to-incremental-save-commands old new)))
    (should (equal (seq-take (mapcar (lambda (op) (alist-get 'ty op)) commands)
                             2)
                   '("ds" "is")))
    (should (= (alist-get 'si (car commands)) 1))))

(ert-deftest gdocs-test-locate-edit-through-structural-ot-map ()
  "An edit in plain text maps back to its OT positions."
  (let* ((remote "A word\n")
         (local "A WORD\n")
         (region (gdocs--diff-single-region remote local))
         (range (gdocs--locate-edit-in-ot
                 (concat "A " (string gdocs--ot-table-open)
                         "word\n")
                 remote
                 (plist-get region :start)
                 (plist-get region :rem-end))))
    ;; The structural marker sits between the space and the edited word.
    (should (equal range '(4 . 8)))))

(ert-deftest gdocs-test-image-bearing-push-is-refused-before-ot-ops ()
  "An image-bearing remote document cannot enter any push backend."
  (let* ((fixture (gdocs-test--inline-case "one-image-between-paragraphs"))
         (body (plist-get fixture :body))
         (state (list :revision 17 :ot-body body
                      :ot-ops (plist-get fixture :ops)))
         (message nil))
    (condition-case err
        (gdocs--apply-push "synthetic-image-document" state
                           "Before\nAfter\n" "Before\nAfter\n")
      (user-error (setq message (error-message-string err))))
    (should (string-match-p "refusing push" message))
    (should (string-match-p "inline image" message))
    (should (string-match-p "pull remains available" message))
    (condition-case err
        (gdocs--apply-push-async
         "synthetic-image-document" state "Before\nAfter\n"
         "Before\nAfter\n" nil (lambda (&rest _args) nil))
      (user-error (setq message (error-message-string err))))
    (should (string-match-p "refusing push" message))))

(ert-deftest gdocs-test-capability-preflight-allows-supported-text-only ()
  "A supported text-only incremental edit passes capability preflight."
  (let* ((gdocs-push-backend 'plain)
         (body "Before\n")
         (state (list :revision 7 :ot-body body
                      :ot-ops (list (gdocs-test--insert-op body))))
         (local "Changed\n")
         (plan (gdocs--push-plan-for-diff state local body)))
    (should (eq (plist-get plan :kind) :incremental))
    (should (gdocs--push-preflight state local plan))))

(ert-deftest gdocs-test-capability-report-unknown-entity-refuses-replacement ()
  "An unknown entity is reported structurally and blocks replacement."
  (let* ((body "Text\n")
         (ops (list (gdocs-test--insert-op body)
                    '((ty . "ae") (et . "equation")
                      (id . "remote-secret-equation-id"))))
         (state (list :revision 7 :ot-body body :ot-ops ops))
         (doc (gdocs-dm-from-ops 7 "synthetic" nil body ops))
         (report (seq-find (lambda (entry)
                             (eq (plist-get entry :kind) :unknown-entity))
                           (gdocs-dm-unsupported doc)))
         (plan (gdocs--push-plan-for-diff state "Changed\n" body))
         (message nil))
    (should report)
    (should (equal (plist-get report :entity-type) "equation"))
    (should-not (plist-get report :ot-start))
    (should-not (plist-get report :preserve-untouched))
    (should (plist-get report :refuse-push))
    (condition-case err
        (gdocs--push-preflight state "Changed\n" plan)
      (user-error (setq message (error-message-string err))))
    (should (string-match-p "1 unknown entity" message))
    (should-not (string-match-p "remote-secret-equation-id" message))
    (should-not (string-match-p "equation" message))))

(ert-deftest gdocs-test-capability-range-preservation-policy ()
  "An image outside an edit range is allowed, but an intersecting edit is not."
  (let* ((gdocs-push-backend 'plain)
         (fixture (gdocs-test--inline-case "one-image-between-paragraphs"))
         (body (plist-get fixture :body))
         (ops (plist-get fixture :ops))
         (state (list :revision 17 :ot-body body :ot-ops ops))
         (remote (gdocs--ot-remote-org-body
                  "synthetic-image-document"
                  (gdocs-test--html-for-ops 17 ops) state))
         (unrelated (replace-regexp-in-string "Before" "Changed" remote))
         (safe-plan (gdocs--push-plan-for-diff state unrelated remote))
         (marker (string-match "#\\+gdocs_inline_object:[^\n]*\n" remote))
         (intersecting (concat (substring remote 0 marker)
                               (substring remote
                                          (+ marker
                                             (length (match-string 0 remote))))))
         (unsafe-plan (gdocs--push-plan-for-diff
                       state intersecting remote))
         (message nil))
    (should (eq (plist-get safe-plan :kind) :incremental))
    (should (gdocs--push-preflight state unrelated safe-plan))
    (should (eq (plist-get unsafe-plan :kind) :incremental))
    (condition-case err
        (gdocs--push-preflight state intersecting unsafe-plan)
      (user-error (setq message (error-message-string err))))
    (should (string-match-p "intersects" message))
    (should (string-match-p "1 inline image" message))))

(ert-deftest gdocs-test-capability-preflight-redecodes-fresh-remote-state ()
  "Raw capabilities from a fresh remote state override stale local summaries."
  (let ((gdocs--sync-mutex t)
        (gdocs-push-backend 'ot-encode)
        (applied nil)
        (unknown-ops (list (gdocs-test--insert-op "Remote\n")
                           '((ty . "ae") (et . "equation")
                             (id . "new-remote-object")))))
    (cl-letf (((symbol-function 'gdocs--fetch-edit-page-async)
               (lambda (_doc callback)
                 (funcall callback
                          (list :revision 8 :token "token" :ouid "ouid"
                                :ot-body "Remote\n" :ot-ops unknown-ops
                                ;; Deliberately stale/empty local capability data.
                                :unsupported nil)
                          "synthetic-html" nil)))
              ((symbol-function 'gdocs--ot-remote-org-body)
               (lambda (&rest _args) "Remote\n"))
              ((symbol-function 'gdocs--apply-push-async)
               (lambda (&rest _args) (setq applied t))))
      (gdocs--push-remotely-async-1 "synthetic-id" nil "8" "Changed\n")
      (should-not applied)
      (should-not gdocs--sync-mutex))))

(ert-deftest gdocs-test-capability-error-summary-is-sanitized ()
  "Capability errors report counts and kinds, never raw entity payloads."
  (let* ((body "Text\n")
         (ops (list (gdocs-test--insert-op body)
                    '((ty . "ae") (et . "equation") (id . "secret-one") )
                    '((ty . "ae") (et . "equation") (id . "secret-two") )))
         (state (list :revision 7 :ot-body body :ot-ops ops))
         (message nil))
    (condition-case err
        (gdocs--push-preflight
         state "Changed\n"
         '(:kind :full-replace))
      (user-error (setq message (error-message-string err))))
    (should (string-match-p "2 unknown entities" message))
    (should-not (string-match-p "secret-one\|secret-two\|equation" message))))

(ert-deftest gdocs-test-capability-reports-structural-and-paragraph-constructs ()
  "Unhandled structural codepoints and paragraph attributes are reported."
  (let* ((body (concat "A" (string #x13) "\n"))
         (ops (list (gdocs-test--insert-op body)
                    '((ty . "as") (st . "paragraph")
                      (si . 3) (ei . 3)
                      (sm . ((ps_pb . t))))))
         (doc (gdocs-dm-from-ops 7 "synthetic" nil body ops))
         (reports (gdocs-dm-unsupported doc))
         (structural (seq-find (lambda (report)
                                 (eq (plist-get report :kind)
                                     :structural-codepoint))
                               reports))
         (paragraph (seq-find (lambda (report)
                                (eq (plist-get report :kind)
                                    :unsupported-paragraph))
                              reports)))
    (should structural)
    (should (= (plist-get structural :ot-start) 2))
    (should (plist-get structural :preserve-untouched))
    (should paragraph)
    (should (equal (plist-get paragraph :feature-type) "ps_pb"))))

(ert-deftest gdocs-test-auto-sync-never-selects-lossy-override ()
  "Auto-sync invokes the normal guarded push entry point only."
  (let ((gdocs-mode t)
        (gdocs--sync-mutex nil)
        (gdocs--last-synced-hash "stale")
        (called nil))
    (with-temp-buffer
      (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n:GDOC_REVISION: 1\n:END:\n\nChanged\n")
      (org-mode)
      (cl-letf (((symbol-function 'gdocs--fetch-edit-state-async)
                 (lambda (_doc callback)
                   (funcall callback '(:revision 1) nil)))
                ((symbol-function 'gdocs-push-remotely)
                 (lambda (&rest args) (setq called args))))
        (gdocs--auto-sync-tick))
      (should (equal called '("synthetic-id"))))))

(ert-deftest gdocs-test-debug-capability-output-is-sanitized ()
  "Debug output includes capability counts without raw entity identifiers."
  (let* ((body "Text\n")
         (ops (list (gdocs-test--insert-op body)
                    '((ty . "ae") (et . "equation")
                      (id . "secret-debug-entity"))))
         (html (gdocs-test--html-for-ops 7 ops))
         (out (make-temp-file "gdocs-debug-capability-")))
    (with-temp-buffer
      (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n:GDOC_REVISION: 7\n:END:\n\nChanged\n")
      (org-mode)
      (cl-letf (((symbol-function 'gdocs--fetch-edit-page-sync)
                 (lambda (_doc) html)))
        (gdocs-debug-push-state "synthetic-id" out)))
    (unwind-protect
        (with-temp-buffer
          (insert-file-contents out)
          (should (search-forward "unsupported capability summary: 1 unknown entity"
                                  nil t))
          (goto-char (point-min))
          (should-not (search-forward "secret-debug-entity" nil t)))
      (delete-file out))))

(ert-deftest gdocs-test-local-image-marker-cannot-recreate-an-image ()
  "A local remote-object marker is not silently emitted as plain text."
  (let ((message nil))
    (condition-case err
        (gdocs--assert-push-safe
         '(:ot-body "plain\n" :ot-ops nil)
         "#+gdocs_inline_object: image kix.synthetic 1x1 content-id=s-blob-v1-IMAGE-synthetic\n")
      (user-error (setq message (error-message-string err))))
    (should (string-match-p "refusing push" message))
    (should (string-match-p "creation/replacement" message))))

(ert-deftest gdocs-test-push-preflight-refuses-missing-revision ()
  "A buffer without a revision is rejected before any network probe."
  (let ((gdocs--sync-mutex nil))
    (with-temp-buffer
      (insert ":PROPERTIES:\n:GDOC_ID: synthetic-id\n:END:\n\nBody\n")
      (org-mode)
      (should-error (gdocs-push-remotely "synthetic-id") :type 'user-error)
      (should-not gdocs--sync-mutex))))

(ert-deftest gdocs-test-push-preflight-refuses-stale-remote-state ()
  "A mocked remote revision mismatch refuses push without applying changes."
  (let ((gdocs--sync-mutex t)
        (gdocs-log-level 'error)
        (applied nil))
    (cl-letf (((symbol-function 'gdocs--fetch-edit-page-async)
               (lambda (_doc callback)
                 (funcall callback
                          '(:revision 8 :token "token" :ouid "ouid")
                          "synthetic-html" nil)))
              ((symbol-function 'gdocs--apply-push-async)
               (lambda (&rest _args) (setq applied t))))
      (gdocs--push-remotely-async-1 "synthetic-id" nil "7" "local")
      (should-not applied)
      (should-not gdocs--sync-mutex))))

(ert-deftest gdocs-test-push-preflight-noop-and-dirty-dispatch ()
  "Matching revision performs a no-op or dispatches dirty content offline."
  (let ((gdocs--sync-mutex t)
        (called nil))
    (cl-letf (((symbol-function 'gdocs--fetch-edit-page-async)
               (lambda (_doc callback)
                 (funcall callback
                          '(:revision 7 :token "token" :ouid "ouid")
                          "synthetic-html" nil)))
              ((symbol-function 'gdocs--ot-remote-org-body)
               (lambda (&rest _args) "same"))
              ((symbol-function 'gdocs--apply-push-async)
               (lambda (&rest _args) (setq called t))))
      (gdocs--push-remotely-async-1 "synthetic-id" nil "7" "same")
      (should-not called)
      (should-not gdocs--sync-mutex)))
  (let ((gdocs--sync-mutex t)
        (called nil)
        (arguments nil))
    (cl-letf (((symbol-function 'gdocs--fetch-edit-page-async)
               (lambda (_doc callback)
                 (funcall callback
                          '(:revision 7 :token "token" :ouid "ouid")
                          "synthetic-html" nil)))
              ((symbol-function 'gdocs--ot-remote-org-body)
               (lambda (&rest _args) "remote"))
              ((symbol-function 'gdocs--apply-push-async)
               (lambda (_doc _state local remote _buffer callback)
                 (setq called t arguments (list local remote))
                 (funcall callback 8 nil))))
      (gdocs--push-remotely-async-1 "synthetic-id" nil "7" "local")
      (should called)
      (should (equal arguments '("local" "remote")))
      (should-not gdocs--sync-mutex))))

;;; Optional integration category

(ert-deftest gdocs-test-integration-category-gate ()
  "Integration tests require an explicit opt-in environment variable.

This suite ships no live credential test.  The tagged test documents and
checks the gate so future local integration tests cannot run accidentally."
  :tags '(integration)
  (skip-unless (equal (getenv gdocs-test--integration-variable) "1"))
  (should (equal (getenv gdocs-test--integration-variable) "1")))

(provide 'gdocs-mode-test)

;;; gdocs-mode-test.el ends here
