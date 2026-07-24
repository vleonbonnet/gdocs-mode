EMACS ?= emacs
ROOT_DIR ?= $(CURDIR)
EMACS_BATCH = $(EMACS) -Q --batch -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test"
SOURCE_FILE = $(ROOT_DIR)/gdocs-mode.el
TEST_FILE = $(ROOT_DIR)/test/gdocs-mode-test.el
TEST_REQUEST_SHIM = $(ROOT_DIR)/test/gdocs-mode-test-request.el

.PHONY: test byte-compile check integration space-path-check
.NOTPARALLEL: check

test: ; $(EMACS_BATCH) -l "$(TEST_FILE)" --eval '(ert-run-tests-batch-and-exit (quote (not (tag integration))))'

byte-compile:
	@set -e; \
build_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/gdocs-mode-build.XXXXXX"); \
trap 'status=$$?; rm -rf "$$build_dir"; exit $$status' EXIT HUP INT TERM; \
	GDOCS_MODE_BYTE_COMPILE_DIR="$$build_dir" \
	GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	$(EMACS) -Q --batch -L "$$build_dir" -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test" \
	-l "$(TEST_REQUEST_SHIM)" \
	--eval '(progn (require (quote bytecomp)) (setq byte-compile-dest-file-function (lambda (filename) (expand-file-name (concat (file-name-sans-extension (file-name-nondirectory filename)) ".elc") (getenv "GDOCS_MODE_BYTE_COMPILE_DIR")))))' \
	--eval '(unless (byte-compile-file (getenv "GDOCS_MODE_SOURCE_FILE")) (error "Byte compilation failed for gdocs-mode.el"))'; \
	GDOCS_MODE_BYTE_COMPILE_DIR="$$build_dir" \
	GDOCS_MODE_TEST_FILE="$(TEST_FILE)" \
	$(EMACS) -Q --batch -L "$$build_dir" -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test" \
	-l "$(TEST_REQUEST_SHIM)" \
	-l "$$build_dir/gdocs-mode.elc" \
	--eval '(progn (require (quote bytecomp)) (setq byte-compile-dest-file-function (lambda (filename) (expand-file-name (concat (file-name-sans-extension (file-name-nondirectory filename)) ".elc") (getenv "GDOCS_MODE_BYTE_COMPILE_DIR")))))' \
	--eval '(unless (byte-compile-file (getenv "GDOCS_MODE_TEST_FILE")) (error "Byte compilation failed for gdocs-mode-test.el"))'; \
test -s "$$build_dir/gdocs-mode.elc"; \
test -s "$$build_dir/gdocs-mode-test.elc"

check: test byte-compile

space-path-check:
	@set -e; \
	smoke_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/gdocs-mode-space-check.XXXXXX"); \
	trap 'status=$$?; rm -rf "$$smoke_dir"; exit $$status' EXIT HUP INT TERM; \
	repo_link="$$smoke_dir/gdocs mode"; \
	ln -s "$(ROOT_DIR)" "$$repo_link"; \
	$(MAKE) -C "$$repo_link" ROOT_DIR="$$repo_link" test; \
	$(MAKE) -C "$$repo_link" ROOT_DIR="$$repo_link" byte-compile; \
	$(MAKE) -C "$$repo_link" ROOT_DIR="$$repo_link" check

# This target only exercises the explicit ERT integration selector.  The
# repository ships no live credential tests; future local tests must opt in
# with the same variable and remain responsible for their own credentials.
integration: ; GDOCS_MODE_RUN_INTEGRATION=1 $(EMACS_BATCH) -l "$(TEST_FILE)" --eval '(ert-run-tests-batch-and-exit (quote (tag integration)))'
