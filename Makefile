EMACS ?= emacs
ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
EMACS_BATCH = $(EMACS) -Q --batch -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test"
TEST_FILE = $(ROOT_DIR)/test/gdocs-mode-test.el
TEST_SETUP = --eval '(setq load-prefer-newer t)'

.PHONY: test byte-compile check integration
.NOTPARALLEL: check

test: ; $(EMACS_BATCH) $(TEST_SETUP) -l $(TEST_FILE) --eval '(ert-run-tests-batch-and-exit (quote (not (tag integration))))'

byte-compile:
@set -e; \
build_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/gdocs-mode-build.XXXXXX"); \
trap 'status=$$?; rm -rf "$$build_dir"; exit $$status' EXIT HUP INT TERM; \
GDOCS_MODE_BYTE_COMPILE_DIR="$$build_dir" \
$(EMACS) -Q --batch -L "$$build_dir" -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test" $(TEST_SETUP) \
-l "$(TEST_FILE)" \
--eval '(progn (require (quote bytecomp)) (setq byte-compile-dest-file-function (lambda (filename) (expand-file-name (concat (file-name-sans-extension (file-name-nondirectory filename)) ".elc") (getenv "GDOCS_MODE_BYTE_COMPILE_DIR")))))' \
--eval '(unless (byte-compile-file "$(ROOT_DIR)/gdocs-mode.el") (error "Byte compilation failed for gdocs-mode.el"))' \
--eval '(unless (byte-compile-file "$(TEST_FILE)") (error "Byte compilation failed for $(TEST_FILE)"))'

check: test byte-compile

# This target only exercises the explicit ERT integration selector.  The
# repository ships no live credential tests; future local tests must opt in
# with the same variable and remain responsible for their own credentials.
integration: ; GDOCS_MODE_RUN_INTEGRATION=1 $(EMACS_BATCH) $(TEST_SETUP) -l $(TEST_FILE) --eval '(ert-run-tests-batch-and-exit (quote (tag integration)))'
