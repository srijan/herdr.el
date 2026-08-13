EMACS ?= emacs
EXTRA_LOAD_PATH ?=

## `test/herdr-deps.el' is loaded before anything else and puts
## magit-section and transient on the load path, searching the package
## directories elpaca, package.el and straight.el use.  Not finding
## them is a hard error naming EXTRA_LOAD_PATH.
##
## That is what lets every target treat magit-section as the declared
## dependency it is.  It used to be treated as optional in two places:
## the dispatcher tests skipped themselves when it was absent, and
## `compile' left herdr-dispatch.el out of the compile set unless
## EXTRA_LOAD_PATH said where the library was.  Measured, that meant a
## bare `make test' skipped 97 of 325 tests — every `herdr-dispatch-'
## test there is — and reported success, while `make compile' never
## compiled the file at all.
##
## EXTRA_LOAD_PATH still works and still wins: it is added to the load
## path ahead of the search, and herdr-deps only looks for what
## `locate-library' cannot already answer.
BATCH := $(EMACS) -Q --batch -L . -L test $(addprefix -L ,$(EXTRA_LOAD_PATH)) \
           -l test/herdr-deps.el

TESTS := $(wildcard test/*-test.el)
SRC   := $(filter-out %-autoloads.el,$(wildcard *.el))

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
	  -f batch-byte-compile $(SRC)

clean:
	rm -f *.elc test/*.elc
