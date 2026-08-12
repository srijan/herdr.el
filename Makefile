EMACS ?= emacs
EXTRA_LOAD_PATH ?=
BATCH := $(EMACS) -Q --batch -L . -L test $(addprefix -L ,$(EXTRA_LOAD_PATH))

TESTS := $(wildcard test/*-test.el)
SRC   := $(filter-out %-autoloads.el,$(wildcard *.el))

## Sources that require a package Emacs does not ship.  Their tests skip
## themselves when the package is absent, but byte-compiling them cannot:
## it would just fail to load the require.  So they are compiled only
## when EXTRA_LOAD_PATH says where the package is, which keeps a bare
## `make compile' on a checkout with nothing installed meaningful.
EXTERNAL    := herdr-dispatch.el
COMPILE_SRC := $(if $(EXTRA_LOAD_PATH),$(SRC),$(filter-out $(EXTERNAL),$(SRC)))

.PHONY: test test-live compile clean all

all: compile test

## Run the hermetic suite (no herdr server required).
test:
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (not (tag :live))))'

## Run only the tests that need a live herdr server.
test-live:
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) \
	  --eval '(ert-run-tests-batch-and-exit (quote (tag :live)))'

## Byte-compile everything, treating warnings as failures.
compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(COMPILE_SRC)

clean:
	rm -f *.elc test/*.elc
