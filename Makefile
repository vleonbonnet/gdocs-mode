EMACS ?= emacs
EMACS_BATCH = $(EMACS) -Q --batch -L . -L test
TEST_FILE = test/gdocs-mode-test.el

.PHONY: test byte-compile check integration

test: ; $(EMACS_BATCH) -l $(TEST_FILE) --eval '(ert-run-tests-batch-and-exit (quote (not (tag integration))))'

byte-compile: ; $(EMACS_BATCH) -l $(TEST_FILE) --eval '(byte-compile-file "gdocs-mode.el")' --eval '(byte-compile-file "$(TEST_FILE)")'

check: test byte-compile

# This target only exercises the explicit ERT integration selector.  The
# repository ships no live credential tests; future local tests must opt in
# with the same variable and remain responsible for their own credentials.
integration: ; GDOCS_MODE_RUN_INTEGRATION=1 $(EMACS_BATCH) -l $(TEST_FILE) --eval '(ert-run-tests-batch-and-exit (quote (tag integration)))'
