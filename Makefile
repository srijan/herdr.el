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

## herdr-deps.el gates every target, so it meets the same warning bar as
## the sources it loads them with.  It was the one file the item-2 gate
## did not cover: `SRC' is the package's own root *.el, and a file that
## decides whether the build runs at all was never byte-compiled.
COMPILE_SRC := $(SRC) test/herdr-deps.el

## A hang is not a pass, and without a deadline it is not a failure
## either — it is a CI job killed with no output, which reads as
## infrastructure trouble rather than as a broken commit.  Measured: two
## plausible off-by-ones in loop bounds, one in herdr-dispatch.el and one
## in herdr-state.el, make this suite run forever rather than fail.
##
## Detected rather than required.  `timeout' is GNU coreutils, which
## macOS does not ship and Homebrew installs as `gtimeout' unless the
## user asked otherwise; a Makefile that hard-codes it fails to run at
## all on a stock macOS, which is a worse outcome than an undeadlined
## suite.  Set TEST_TIMEOUT to change the limit, or to nothing to opt out.
TIMEOUT      := $(shell command -v timeout 2>/dev/null || \
                        command -v gtimeout 2>/dev/null)
TEST_TIMEOUT ?= 300
DEADLINE     := $(if $(and $(TIMEOUT),$(TEST_TIMEOUT)),$(TIMEOUT) $(TEST_TIMEOUT))

.PHONY: test test-live compile clean all

all: compile test

## Run the hermetic suite (no herdr server required).
test:
	$(DEADLINE) $(BATCH) $(foreach f,$(TESTS),-l $(f)) \
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
