EMACS ?= emacs
ifneq ($(origin ROOT_DIR), command line)
override ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
endif
REQUEST_DIR ?=
EMACS_BATCH = $(EMACS) -Q --batch -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test"
SOURCE_FILE = $(ROOT_DIR)/gdocs-mode.el
TEST_FILE = $(ROOT_DIR)/test/gdocs-mode-test.el
TEST_RUNNER = $(ROOT_DIR)/test/gdocs-mode-test-runner.el
TEST_REQUEST_SHIM = $(ROOT_DIR)/test/gdocs-mode-test-request.el
COMPILE_DRIVER = $(ROOT_DIR)/test/gdocs-mode-compile.el
REQUEST_CHECK_LOAD_PATH = $(ROOT_DIR)/test/gdocs-mode-request-check-load-path.el

.PHONY: test byte-compile request-compile-check check integration space-path-check
.NOTPARALLEL: check

test: ; $(EMACS_BATCH) -l "$(TEST_RUNNER)"

byte-compile:
	@set -e; \
	build_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/gdocs-mode-build.XXXXXX"); \
	trap 'status=$$?; rm -rf "$$build_dir"; exit $$status' EXIT HUP INT TERM; \
	REQUEST_DIR="$(REQUEST_DIR)" \
	GDOCS_MODE_BYTE_COMPILE_DIR="$$build_dir" \
	GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	$(EMACS) -Q --batch -L "$$build_dir" -L "$(REQUEST_DIR)" \
	-l "$(COMPILE_DRIVER)"; \
	GDOCS_MODE_BYTE_COMPILE_DIR="$$build_dir" \
	GDOCS_MODE_TEST_FILE="$(TEST_FILE)" \
	$(EMACS) -Q --batch -L "$$build_dir" -L "$(ROOT_DIR)" -L "$(ROOT_DIR)/test" \
	-l "$(TEST_REQUEST_SHIM)" \
	-l "$$build_dir/gdocs-mode.elc" \
	--eval '(progn (require (quote bytecomp)) (setq byte-compile-dest-file-function (lambda (filename) (expand-file-name (concat (file-name-sans-extension (file-name-nondirectory filename)) ".elc") (getenv "GDOCS_MODE_BYTE_COMPILE_DIR")))))' \
	--eval '(unless (byte-compile-file (getenv "GDOCS_MODE_TEST_FILE")) (error "Byte compilation failed for gdocs-mode-test.el"))'; \
	test -s "$$build_dir/gdocs-mode.elc"; \
	test -s "$$build_dir/gdocs-mode-test.elc"

request-compile-check:
	@set -e; \
	check_dir=$$(mktemp -d "$${TMPDIR:-/tmp}/gdocs-mode-request-check.XXXXXX"); \
	trap 'status=$$?; rm -rf "$$check_dir"; exit $$status' EXIT HUP INT TERM; \
	missing_dir="$$check_dir/missing request"; \
	global_dir="$$check_dir/global request"; \
	compatible_dir="$$check_dir/compatible request"; \
	incompatible_dir="$$check_dir/incompatible request"; \
	fixture_build_dir="$$check_dir/fixture compiled output"; \
	production_build_dir="$$check_dir/production compiled output"; \
	mkdir "$$missing_dir" "$$global_dir" "$$compatible_dir" "$$incompatible_dir" "$$fixture_build_dir" "$$production_build_dir"; \
	printf '%s\n' '(defconst request-version "0.3.2")' '(provide (quote request))' > "$$global_dir/request.el"; \
	cp "$$global_dir/request.el" "$$compatible_dir/request.el"; \
	printf '%s\n' '(defconst request-version "0.3.1")' '(provide (quote request))' > "$$incompatible_dir/request.el"; \
	if REQUEST_DIR="$$missing_dir" GDOCS_MODE_REQUEST_CHECK_DIRECTORY= GDOCS_MODE_BYTE_COMPILE_DIR="$$fixture_build_dir" GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	  $(EMACS) -Q --batch -l "$(REQUEST_CHECK_LOAD_PATH)" -l "$(COMPILE_DRIVER)" > "$$check_dir/missing.log" 2>&1; then \
	  printf '%s\n' 'Expected production compilation without request to fail' >&2; exit 1; \
	fi; \
	grep -F 'Real request package 0.3.2+ is unavailable' "$$check_dir/missing.log" >/dev/null; \
	if REQUEST_DIR="$$missing_dir" GDOCS_MODE_REQUEST_CHECK_DIRECTORY="$$global_dir" GDOCS_MODE_BYTE_COMPILE_DIR="$$fixture_build_dir" GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	  $(EMACS) -Q --batch -l "$(REQUEST_CHECK_LOAD_PATH)" -l "$(COMPILE_DRIVER)" > "$$check_dir/global.log" 2>&1; then \
	  printf '%s\n' 'Expected production compilation with request outside REQUEST_DIR to fail' >&2; exit 1; \
	fi; \
	grep -F 'Resolved request outside REQUEST_DIR:' "$$check_dir/global.log" >/dev/null; \
	REQUEST_DIR="$$compatible_dir" GDOCS_MODE_REQUEST_CHECK_DIRECTORY="$$compatible_dir" GDOCS_MODE_BYTE_COMPILE_DIR="$$fixture_build_dir" GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	$(EMACS) -Q --batch -l "$(REQUEST_CHECK_LOAD_PATH)" -l "$(COMPILE_DRIVER)" > "$$check_dir/compatible.log" 2>&1; \
	test -s "$$fixture_build_dir/gdocs-mode.elc"; \
	if REQUEST_DIR="$$incompatible_dir" GDOCS_MODE_REQUEST_CHECK_DIRECTORY="$$incompatible_dir" GDOCS_MODE_BYTE_COMPILE_DIR="$$fixture_build_dir" GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	  $(EMACS) -Q --batch -l "$(REQUEST_CHECK_LOAD_PATH)" -l "$(COMPILE_DRIVER)" > "$$check_dir/incompatible.log" 2>&1; then \
	  printf '%s\n' 'Expected production compilation with incompatible request to fail' >&2; exit 1; \
	fi; \
	grep -F 'Real request package 0.3.2+ is required' "$$check_dir/incompatible.log" >/dev/null; \
	REQUEST_DIR="$(REQUEST_DIR)" GDOCS_MODE_BYTE_COMPILE_DIR="$$production_build_dir" GDOCS_MODE_SOURCE_FILE="$(SOURCE_FILE)" \
	$(EMACS) -Q --batch -L "$(REQUEST_DIR)" -l "$(COMPILE_DRIVER)"; \
	test -s "$$production_build_dir/gdocs-mode.elc"; \
	test ! -e "$(ROOT_DIR)/gdocs-mode.elc"; \
	test ! -e "$(ROOT_DIR)/test/gdocs-mode-test.elc"

check: test byte-compile request-compile-check

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
integration:
	@test -n "$(REQUEST_DIR)" || { printf '%s\n' 'REQUEST_DIR is required for the opt-in integration target' >&2; exit 1; }
	GDOCS_MODE_RUN_INTEGRATION=1 $(EMACS_BATCH) -L "$(REQUEST_DIR)" -l "$(TEST_FILE)" --eval '(ert-run-tests-batch-and-exit (quote (tag integration)))'
