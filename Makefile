# ----------------------------------------------------------------------------
# log-parse — convenience targets for common workflows
# ----------------------------------------------------------------------------

SHELL      := /usr/bin/env bash
PROJECT    := log-parse
LOG_DIR    ?= ./examples/sample-logs/LUNG-CANCER-REPORT-LOG
REGION     ?= all
DAYS       ?= 7

BIN        := bin
LIB        := lib
TESTS      := tests
DOCS       := docs

REPORT_DIR ?= ./reports

.PHONY: help all test lint check report access iis errors clean install-deps

help:        ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

all: check test ## Run lint + tests

test:        ## Run functional test suite
	@bash $(TESTS)/run_tests.sh

lint:        ## Run shellcheck on all scripts
	@command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck not installed; skipping"; exit 0; }
	@shellcheck $(BIN)/*.sh $(LIB)/*.sh

check: lint  ## Static analysis (alias for lint)

report:      ## Run full report (LOG_DIR, REGION, DAYS overridable)
	@mkdir -p $(REPORT_DIR)
	@bash $(BIN)/log_report.sh --log-dir $(LOG_DIR) --region $(REGION) --days $(DAYS) \
		--output-dir $(REPORT_DIR)
	@echo "Reports written to $(REPORT_DIR)/"

access:      ## Run access correlation only
	@bash $(BIN)/analyze_access.sh --log-dir $(LOG_DIR) --region $(REGION) --days $(DAYS)

iis:         ## Run IIS analysis only
	@bash $(BIN)/analyze_iis.sh --log-dir $(LOG_DIR) --region $(REGION) --days $(DAYS)

errors:      ## Run error analysis only
	@bash $(BIN)/analyze_errors.sh --log-dir $(LOG_DIR) --region $(REGION) --days $(DAYS)

clean:       ## Remove generated reports
	@rm -rf $(REPORT_DIR)
	@echo "Cleaned $(REPORT_DIR)/"

install-deps:## Verify required runtime dependencies are present
	@for cmd in bash gawk sort date mktemp; do \
		command -v $$cmd >/dev/null 2>&1 && echo "  [OK]   $$cmd" || echo "  [MISS] $$cmd"; \
	done
