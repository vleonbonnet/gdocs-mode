;;; gdocs-mode-request-check-load-path.el --- Isolate request checks -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valentin Leon

;;; Code:

(let ((candidate-directory (getenv "GDOCS_MODE_REQUEST_CHECK_DIRECTORY"))
      (built-in-directory (file-name-as-directory
                           (file-truename lisp-directory)))
      built-in-load-path)
  (dolist (directory load-path)
    (when directory
      (let ((true-directory (file-name-as-directory
                             (file-truename directory))))
        (when (or (equal true-directory built-in-directory)
                  (file-in-directory-p true-directory built-in-directory))
          (push directory built-in-load-path)))))
  (setq load-path
        (append (when (and candidate-directory
                           (not (string-empty-p candidate-directory)))
                  (list candidate-directory))
                (nreverse built-in-load-path))))

;;; gdocs-mode-request-check-load-path.el ends here
