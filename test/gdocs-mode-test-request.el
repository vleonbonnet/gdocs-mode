;;; gdocs-mode-test-request.el --- Offline request shim -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Valentin Leon

;;; Code:

(when (featurep 'request)
  (error "Refusing to replace an already loaded request package"))

(defmacro request (&rest args)
  `(progn
     (ignore ,@args request-message-level request-log-level)
     (error "Network requests are unavailable in offline tests")))

(defun request-response-status-code (_response) nil)
(defun request-response-data (_response) nil)

(provide 'request)
(provide 'gdocs-mode-test-request)

;;; gdocs-mode-test-request.el ends here
