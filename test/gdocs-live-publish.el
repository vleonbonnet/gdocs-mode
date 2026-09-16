;;; gdocs-live-publish.el --- Live publish harness (disposable doc first) -*- lexical-binding: t; -*-
;; Run: emacs -Q --batch -L . -L REQUEST_DIR -l request -l gdocs-mode.el \
;;           -l gdocs-live-publish.el --eval '(gdocs-live/run)'
;; Creates a disposable Google Doc with the browser-cookie auth, publishes
;; the brief to it, and verifies document settings survive.

(require 'cl-lib)
(require 'url-parse)

;; Configure the package's auth to use the Firefox-cookie backend.
(setq gdocs-auth-function #'gdocs-live/cookies)

(defvar gdocs-live/source
  "/Users/val/Documents/projects/pr-bot/secateur/capability-brief.org")

(defun gdocs-live/cookies ()
  "Return google.com cookies from Firefox as a Cookie header alist."
  (let ((src (expand-file-name
              "~/Library/Application Support/Firefox/Profiles/6txhwtfy.default-release/cookies.sqlite"))
        (tmp (make-temp-file "gdocs-live-cookies" nil ".sqlite"))
        db rows cookies)
    (unwind-protect
        (progn
          (copy-file src tmp t)
          (setq db (sqlite-open tmp))
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

(defun gdocs-live/create-doc (&optional title)
  "Create a fresh Google Doc and return its document id, or nil."
  (let* ((url (concat "https://docs.google.com/document/create"
                      (and title (format "?title=%s" (url-hexify-string title)))))
         (headers (append '(("User-Agent" . "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:138.0) Gecko/20100101 Firefox/138.0"))
                          (gdocs-live/cookies)))
         (tmp-out (make-temp-file "gdocs-live-create"))
         (tmp-hdr (concat tmp-out ".headers"))
         (args (list "curl" "-sS" "-o" tmp-out "-D" tmp-hdr
                     "-w" "%{http_code} %{redirect_url}"
                     "-L" "--post303" "-X" "POST" url)))
    (dolist (h headers) (nconc args (list "-H" (concat (car h) ": " (cdr h)))))
    (with-temp-buffer
      (let* ((status (apply #'call-process (car args) nil t nil (cdr args)))
             (out (string-trim (buffer-string))))
        (delete-file tmp-out)
        (delete-file tmp-hdr)
        (if (and (= status 0) (string-match "\\`3[0-9][0-9] \\(.*\\)\\'" out))
            (progn
              (message "create redirect: %s" (match-string 1 out))
              (gdocs--extract-doc-id (match-string 1 out)))
          (message "create failed: status=%s out=%s" status out)
          nil)))))

(defun gdocs-live/publish-to (doc-id label)
  "Publish the brief to DOC-ID; return the result plist."
  (let ((result :pending))
    (setq gdocs-log-level 'info)
    (gdocs-publish-file gdocs-live/source doc-id t t
                        (lambda (res err)
                          (setq result (if err (list :error err) res))))
    (with-timeout (60 (setq result (list :error "timeout")))
      (while (eq result :pending) (sit-for 0.3)))
    (message "%s result: %S" label result)
    result))

(defun gdocs-live/run ()
  "Validate the full publish pipeline on a disposable document."
  (interactive)
  (let* ((disposable (gdocs-live/create-doc "gdocs-mode disposable publish test"))
         results)
    (if (null disposable)
        (message "STEP1 FAILED: could not create disposable doc")
      (message "STEP1 ok: disposable doc %s" disposable)
      (push (gdocs-live/publish-to disposable "disposable") results)
      ;; settings-survival check: refetch and decode
      (let* ((state (gdocs--fetch-edit-state disposable))
             (ops (plist-get state :ot-ops))
             (body (plist-get state :ot-body)))
        (message "STEP2 disposable rev=%s body-len=%d ops=%d"
                 (plist-get state :revision) (length (or body "")) (length ops))
        ;; document settings must still be present after publish
        (let ((settings (cl-count-if
                         (lambda (op)
                           (and (equal (alist-get 'ty op) "as")
                                (member (alist-get 'st op)
                                        '("document" "headings" "language"))))
                         ops)))
          (message "STEP3 document-setting ops after publish: %d (expect >=3)" settings)))
      ;; a second publish must be idempotent (no spurious diff)
      (push (gdocs-live/publish-to disposable "republish") results)
      ;; drift check must agree
      (let ((check (gdocs-publish-check gdocs-live/source disposable)))
        (message "STEP4 check: %S" check)))
    (message "SUMMARY: %S" (nreverse results))))
