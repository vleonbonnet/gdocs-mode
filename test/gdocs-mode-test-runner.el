;;; gdocs-mode-test-runner.el --- Isolated offline test runner -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valentin Leon

;;; Code:

(require 'cl-lib)
(require 'ert)

(defvar gdocs-session-file)

(let* ((suite-directory (make-temp-file "gdocs-mode-test-" t))
       (temporary-file-directory
        (file-name-as-directory (expand-file-name "tmp" suite-directory)))
       (user-emacs-directory
        (file-name-as-directory (expand-file-name "emacs" suite-directory)))
       (gdocs-session-file
        (expand-file-name "state/session.eld" suite-directory))
       (process-environment (copy-sequence process-environment))
       stats)
  (make-directory temporary-file-directory t)
  (make-directory user-emacs-directory t)
  (setenv "XDG_CACHE_HOME" (expand-file-name "cache" suite-directory))
  (setenv "GDOCS_MODE_RUN_INTEGRATION" nil)
  (unwind-protect
      (progn
        (load (expand-file-name "gdocs-mode-test.el"
                                (file-name-directory
                                 (or load-file-name buffer-file-name)))
              nil nil t)
        (let ((gdocs-test--suite-temp-directory suite-directory)
              (gdocs-auth-function
               (lambda ()
                 (error "Offline test blocked unstubbed auth/cookie access"))))
          (cl-letf (((symbol-function 'gdocs--curl-post)
                     (lambda (&rest _args)
                       (error "Offline test blocked unstubbed synchronous curl access")))
                    ((symbol-function 'gdocs--curl-async)
                     (lambda (&rest _args)
                       (error "Offline test blocked unstubbed asynchronous curl access"))))
            (setq stats (ert-run-tests-batch '(not (tag integration)))))))
    (when (file-exists-p suite-directory)
      (delete-directory suite-directory t)))
  (when (file-exists-p suite-directory)
    (error "Offline test suite did not clean temporary state: %s"
           suite-directory))
  (kill-emacs (if (zerop (ert-stats-completed-unexpected stats)) 0 1)))

;;; gdocs-mode-test-runner.el ends here
