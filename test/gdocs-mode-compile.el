;;; gdocs-mode-compile.el --- Production byte-compile driver -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valentin Leon

;;; Code:

(require 'bytecomp)

(let* ((minimum-version "0.3.2")
       (request-directory (getenv "REQUEST_DIR"))
       (request-library (locate-library "request")))
  (unless (and request-directory (not (string-empty-p request-directory)))
    (error "REQUEST_DIR is required; install request %s+ and set REQUEST_DIR to its library directory"
           minimum-version))
  (unless request-library
    (error "Real request package %s+ is unavailable in REQUEST_DIR=%s; install it explicitly (no download was attempted)"
           minimum-version request-directory))
  (unless (file-in-directory-p (file-truename request-library)
                               (file-name-as-directory
                                (file-truename request-directory)))
    (error "Resolved request outside REQUEST_DIR: %s" request-library))
  (require 'request)
  (unless (and (boundp 'request-version)
               (stringp request-version)
               (version<= minimum-version request-version))
    (error "Real request package %s+ is required; REQUEST_DIR supplied version %s"
           minimum-version
           (if (boundp 'request-version) request-version "unknown (possibly the test shim)")))
  (let* ((structural-symbol-name "gdocs--ot-structural-codepoints")
         (structural-symbol-warning nil)
         (original-warning-function byte-compile-log-warning-function)
         (byte-compile-log-warning-function
          (lambda (string position fill level)
            (when (string-match-p (regexp-quote structural-symbol-name) string)
              (setq structural-symbol-warning string))
            (funcall original-warning-function string position fill level))))
    (setq byte-compile-dest-file-function
          (lambda (filename)
            (expand-file-name
             (concat (file-name-sans-extension
                      (file-name-nondirectory filename))
                     ".elc")
             (getenv "GDOCS_MODE_BYTE_COMPILE_DIR"))))
    (unless (byte-compile-file (getenv "GDOCS_MODE_SOURCE_FILE"))
      (error "Byte compilation failed for gdocs-mode.el"))
    (when structural-symbol-warning
      (error "Byte compilation warned about %s: %s"
             structural-symbol-name structural-symbol-warning))))

;;; gdocs-mode-compile.el ends here
