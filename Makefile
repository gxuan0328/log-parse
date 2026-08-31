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

REPORT_DIR  ?= ./reports
SAMPLE_OUT  := ./examples/sample-outputs
SAMPLE_LOGS := ./examples/sample-logs/LUNG-CANCER-REPORT-LOG
SAMPLE_TS   := 20260521_000000
SAMPLE_DATE := 2026-05-21
SAMPLE_FROM := 2026-05-18
SAMPLE_TO   := 2026-05-25

.PHONY: help all test lint check report access iis errors samples-regen clean install-deps

help:        ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make \033[36m<target>\033[0m\n\nTargets:\n"} \
	     /^[a-zA-Z_-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

all: check test ## Run lint + tests

test:        ## Run functional test suite
	@bash $(TESTS)/run_tests.sh

lint:        ## Run shellcheck on all scripts
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck $(BIN)/*.sh $(LIB)/*.sh; \
	else \
		echo "shellcheck not installed; skipping"; \
	fi

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

samples-regen: ## Regenerate examples/sample-outputs/ (pins TS+NO_COLOR for determinism)
	@echo "Regenerating sample outputs (TS=$(SAMPLE_TS), NO_COLOR=1)..."
	@export NO_COLOR=1 LOG_PARSE_RUN_TS=$(SAMPLE_TS) LOG_PARSE_TEST_HOSTS_CONF=$(CURDIR)/tests/fixtures/test_hosts.conf; \
	SOUT=$(SAMPLE_OUT); SLOG=$(SAMPLE_LOGS); \
	D=$(SAMPLE_DATE); F=$(SAMPLE_FROM); T=$(SAMPLE_TO); \
	\
	# IIS \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --view detail                --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.txt   $$SOUT/iis_all_2026-05-21.txt;               cp -f $$_t/$(SAMPLE_TS)/iis_summary.txt $$SOUT/iis_summary_all_2026-05-21.txt;               rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --region taipei --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.txt   $$SOUT/iis_taipei_2026-05-21.txt;             rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --region taichung --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.txt $$SOUT/iis_taichung_2026-05-21.txt;           rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --merge         --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.txt   $$SOUT/iis_all_merged_2026-05-21.txt;         rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --format tsv    --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.tsv   $$SOUT/iis_detail_all_2026-05-21.tsv;         rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --format csv    --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.csv   $$SOUT/iis_detail_all_2026-05-21.csv;         rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --test-hosts only --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.txt   $$SOUT/iis_only_2026-05-21.txt;              rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_iis.sh --log-dir $$SLOG --date $$D --test-hosts all  --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/iis_detail.txt   $$SOUT/iis_allmode_2026-05-21.txt;           rm -rf $$_t; \
	\
	# Access \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --date $$D              --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.txt  $$SOUT/access_detail_all_2026-05-21.txt;   cp -f $$_t/$(SAMPLE_TS)/access_summary.txt $$SOUT/access_summary_all_2026-05-21.txt; cp -f $$_t/$(SAMPLE_TS)/access_ip_counts.tsv $$SOUT/access_ip_counts_all_2026-05-21.tsv; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --date $$D --region taipei   --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.txt $$SOUT/access_taipei_2026-05-21.txt;   rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --date $$D --region taichung --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.txt $$SOUT/access_taichung_2026-05-21.txt; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --date $$D --merge          --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.txt $$SOUT/access_all_merged_2026-05-21.txt; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --from $$F --to $$T --region taipei --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.txt $$SOUT/access_taipei_week.txt; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --from $$F --to $$T --format tsv --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.tsv $$SOUT/access_all_week.tsv; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_access.sh --log-dir $$SLOG --from $$F --to $$T --format csv --view detail --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/access_detail.csv $$SOUT/access_all_week.csv; rm -rf $$_t; \
	\
	# Errors \
	_t=$$(mktemp -d); bash $(BIN)/analyze_errors.sh --log-dir $$SLOG --date $$D --region taipei   --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/errors_detail.txt $$SOUT/errors_taipei_2026-05-21.txt; cp -f $$_t/$(SAMPLE_TS)/errors_detail.txt $$SOUT/errors_detail_taipei_2026-05-21.txt; cp -f $$_t/$(SAMPLE_TS)/errors_summary.txt $$SOUT/errors_summary_taipei_2026-05-21.txt; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_errors.sh --log-dir $$SLOG --date $$D --region taichung --top 20 --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/errors_detail.txt $$SOUT/errors_taichung_top20_2026-05-21.txt; rm -rf $$_t; \
	\
	# Overview \
	_t=$$(mktemp -d); bash $(BIN)/analyze_overview.sh --log-dir $$SLOG --from $$F --to $$T           --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/overview_summary.txt $$SOUT/overview_all_week.txt;    rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_overview.sh --log-dir $$SLOG --from $$F --to $$T --region taipei --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/overview_summary.txt $$SOUT/overview_taipei_week.txt; rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/analyze_overview.sh --log-dir $$SLOG --date $$D           --output-dir $$_t 2>/dev/null; cp -f $$_t/$(SAMPLE_TS)/overview_summary.txt $$SOUT/overview_all_2026-05-21.txt; rm -rf $$_t; \
	\
	# log_report (capture stdout = combined console mirror) \
	_t=$$(mktemp -d); bash $(BIN)/log_report.sh --log-dir $$SLOG --date $$D                         --output-dir $$_t 2>/dev/null > $$SOUT/log_report_full_2026-05-21.txt;               rm -rf $$_t; \
	_t=$$(mktemp -d); bash $(BIN)/log_report.sh --log-dir $$SLOG --date $$D --region taipei --modules iis,access --output-dir $$_t 2>/dev/null > $$SOUT/log_report_taipei_partial_2026-05-21.txt; rm -rf $$_t; \
	echo "Sample outputs regenerated -> $(SAMPLE_OUT)/"

clean:       ## Remove generated reports
	@rm -rf $(REPORT_DIR)
	@echo "Cleaned $(REPORT_DIR)/"

install-deps:## Verify required runtime dependencies are present
	@for cmd in bash gawk sort date mktemp; do \
		command -v $$cmd >/dev/null 2>&1 && echo "  [OK]   $$cmd" || echo "  [MISS] $$cmd"; \
	done
