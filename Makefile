EMACS ?= emacs
EXTRA_LOAD_PATH ?=

## `emacs -Q' initialises no package system, so magit-section is put on
## the load path here: package.el's copy through `package-initialize',
## elpaca's and straight.el's build directories wholesale.
## EXTRA_LOAD_PATH goes first and wins.
DEP_DIRS := $(wildcard ../../builds/* $(HOME)/.emacs.d/var/elpaca/builds/* \
                       $(HOME)/.emacs.d/straight/build/*)

## `load-prefer-newer' before anything is loaded, because it defaults to
## nil: `require' takes the .elc whenever one exists, however old.  That
## made `make test' after `make compile' silently test the last compile
## rather than the working tree — a source edit could pass, or fail, on
## code that is no longer there.  Measured while checking that a test
## caught a deliberate break: it did not, and the break was invisible.
BATCH := $(EMACS) -Q --batch -L . -L test $(addprefix -L ,$(EXTRA_LOAD_PATH) $(DEP_DIRS)) \
           --eval '(setq load-prefer-newer t)' \
           --eval '(package-initialize)' \
           --eval '(unless (locate-library "magit-section") \
                     (error "herdr: magit-section not found; make <target> EXTRA_LOAD_PATH=/path/to/magit-section"))'

TESTS := $(wildcard test/*-test.el)
SRC   := $(filter-out %-autoloads.el,$(wildcard *.el))

COMPILE_SRC := $(SRC)

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
