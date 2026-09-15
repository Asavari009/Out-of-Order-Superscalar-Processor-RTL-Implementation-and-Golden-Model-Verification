# Makefile -- top-level entry points for the OoO pipeline project.
#
# Every target that produces output logs it to logs/, timestamped, so
# results are never lost to /tmp (which grendel/most systems clear on
# reboot or after a while). Run `make help` for a summary.

SHELL := /bin/bash
TIMESTAMP := $(shell date +%Y%m%d_%H%M%S)
LOGDIR := logs

# Default RTL run config -- override on the command line, e.g.:
#   make run TRACE=golden/vectors/val_trace_gcc1 WIDTH=1 ROB_SIZE=16 IQ_SIZE=8
WIDTH    ?= 4
ROB_SIZE ?= 32
IQ_SIZE  ?= 16
TRACE    ?= /dev/null

RTL_FILES := rtl/ooo_pkg.sv rtl/pipe_reg.sv rtl/sched_reg.sv rtl/rmt.sv \
             rtl/rob.sv rtl/issue_queue.sv rtl/exec_units.sv rtl/ooo_pipeline.sv

VERILATOR_FLAGS := --binary -j 0 --timing -Wno-fatal -Irtl

.PHONY: help smoke golden lint run val-regression clean

help:
	@echo "Targets:"
	@echo "  make smoke                          - run all RTL unit + pipeline smoke tests (Verilator)"
	@echo "  make golden                         - confirm golden C++ model matches all 8 official val configs"
	@echo "  make lint                           - lint-only check of every RTL file (no simulation)"
	@echo "  make run TRACE=... WIDTH=.. ROB_SIZE=.. IQ_SIZE=.. - run a real trace through the assembled RTL pipeline"
	@echo "  make val-regression                 - run golden/sim against all 8 official val configs (sanity: golden vs itself)"
	@echo "  make val-rtl [CONFIGS=\"val1 val2\"]   - run the ASSEMBLED RTL PIPELINE against official val configs vs golden (the real check)"
	@echo "  make report TRACE=... WIDTH=.. ROB_SIZE=.. IQ_SIZE=.. [GOLDEN=expected.txt] - full per-instruction report, diffed vs golden if given"
	@echo "  make clean                          - remove build artifacts (keeps logs/)"
	@echo ""
	@echo "All output is logged to $(LOGDIR)/<target>_<timestamp>.log"

$(LOGDIR):
	@mkdir -p $(LOGDIR)

smoke: $(LOGDIR)
	@echo "Running full smoke suite, logging to $(LOGDIR)/smoke_$(TIMESTAMP).log"
	@./run_smoke.sh 2>&1 | tee $(LOGDIR)/smoke_$(TIMESTAMP).log; \
	 ln -sf smoke_$(TIMESTAMP).log $(LOGDIR)/smoke_latest.log; \
	 exit_code=$${PIPESTATUS[0]}; \
	 exit $$exit_code

golden: $(LOGDIR)
	@echo "Running golden model regression, logging to $(LOGDIR)/golden_$(TIMESTAMP).log"
	@bash golden/run_golden_regression.sh 2>&1 | tee $(LOGDIR)/golden_$(TIMESTAMP).log; \
	 ln -sf golden_$(TIMESTAMP).log $(LOGDIR)/golden_latest.log; \
	 exit_code=$${PIPESTATUS[0]}; \
	 exit $$exit_code

lint: $(LOGDIR)
	@echo "Lint-checking all RTL, logging to $(LOGDIR)/lint_$(TIMESTAMP).log"
	@verilator --lint-only -Irtl $(RTL_FILES) -Wno-fatal 2>&1 | tee $(LOGDIR)/lint_$(TIMESTAMP).log; \
	 ln -sf lint_$(TIMESTAMP).log $(LOGDIR)/lint_latest.log

# Runs a real trace file through the fully-assembled RTL pipeline
# (verif/sim_trace/run_trace.sv) and reports the same summary format as
# the golden model (Dynamic Instruction Count / Cycles / IPC). Does NOT
# yet produce the full per-instruction FE{}...RT{} report -- see
# docs/README.md for why that's still ahead of us.
run: $(LOGDIR)
	@echo "Building RTL trace runner: WIDTH=$(WIDTH) ROB_SIZE=$(ROB_SIZE) IQ_SIZE=$(IQ_SIZE) TRACE=$(TRACE)"
	@rm -rf /tmp/ooo_rtl_run_obj
	@verilator $(VERILATOR_FLAGS) -GWIDTH=$(WIDTH) -GROB_SIZE=$(ROB_SIZE) -GIQ_SIZE=$(IQ_SIZE) \
		--Mdir /tmp/ooo_rtl_run_obj \
		$(RTL_FILES) verif/sim_trace/run_trace.sv \
		--top-module run_trace -o vrun_trace \
		> $(LOGDIR)/run_compile_$(TIMESTAMP).log 2>&1 || \
		(echo "COMPILE FAILED, see $(LOGDIR)/run_compile_$(TIMESTAMP).log"; \
		 tail -40 $(LOGDIR)/run_compile_$(TIMESTAMP).log; exit 1)
	@echo "Running against $(TRACE), logging to $(LOGDIR)/run_$(TIMESTAMP).log"
	@/tmp/ooo_rtl_run_obj/vrun_trace +trace=$(TRACE) 2>&1 | tee $(LOGDIR)/run_$(TIMESTAMP).log; \
	 ln -sf run_$(TIMESTAMP).log $(LOGDIR)/run_latest.log; \
	 exit_code=$${PIPESTATUS[0]}; \
	 exit $$exit_code

# Runs the FULL per-instruction report generator (not just summary stats)
# against a trace, and diffs it field-by-field against golden's own
# per-instruction report -- the real bug-finding tool, vs. `run` which
# only gives you the final IPC/cycle count. Usage:
#   make report TRACE=... WIDTH=.. ROB_SIZE=.. IQ_SIZE=.. GOLDEN=path/to/expected.txt
report: $(LOGDIR)
	@echo "Building full report generator: WIDTH=$(WIDTH) ROB_SIZE=$(ROB_SIZE) IQ_SIZE=$(IQ_SIZE) TRACE=$(TRACE)"
	@rm -rf /tmp/ooo_rtl_report_obj
	@verilator $(VERILATOR_FLAGS) -GWIDTH=$(WIDTH) -GROB_SIZE=$(ROB_SIZE) -GIQ_SIZE=$(IQ_SIZE) \
		--Mdir /tmp/ooo_rtl_report_obj \
		$(RTL_FILES) verif/sim_trace/run_trace_report.sv \
		--top-module run_trace_report -o vrun_trace_report \
		> $(LOGDIR)/report_compile_$(TIMESTAMP).log 2>&1 || \
		(echo "COMPILE FAILED, see $(LOGDIR)/report_compile_$(TIMESTAMP).log"; exit 1)
	@/tmp/ooo_rtl_report_obj/vrun_trace_report +trace=$(TRACE) 2>&1 | tee $(LOGDIR)/report_$(TIMESTAMP).log
	@grep -E "^[0-9]|^#" $(LOGDIR)/report_$(TIMESTAMP).log > $(LOGDIR)/report_$(TIMESTAMP)_clean.txt
	@ln -sf report_$(TIMESTAMP)_clean.txt $(LOGDIR)/report_latest_clean.txt
	@echo "Clean val*.txt-style report (no simulator noise): $(LOGDIR)/report_$(TIMESTAMP)_clean.txt"
	@if [ -n "$(GOLDEN)" ]; then \
		grep -E "^[0-9]" $(LOGDIR)/report_$(TIMESTAMP).log > /tmp/rtl_report_lines.txt; \
		grep -E "^[0-9]" $(GOLDEN) > /tmp/golden_report_lines.txt; \
		python3 verif/regression/compare_rtl_vs_golden_report.py /tmp/rtl_report_lines.txt /tmp/golden_report_lines.txt; \
	fi

val-regression: $(LOGDIR)
	@echo "Running golden model against all 8 official val configs, logging to $(LOGDIR)/val_regression_$(TIMESTAMP).log"
	@bash verif/regression/run_val_regression.sh 2>&1 | tee $(LOGDIR)/val_regression_$(TIMESTAMP).log; \
	 ln -sf val_regression_$(TIMESTAMP).log $(LOGDIR)/val_regression_latest.log; \
	 exit_code=$${PIPESTATUS[0]}; \
	 exit $$exit_code

# Runs the ASSEMBLED RTL PIPELINE (not just the golden model) against all
# 8 official configs, both real traces, and compares final summary stats
# (instruction count / cycles / IPC) against golden. This is the real
# "does the whole design work on real programs" check. Pass config names
# to run a subset, e.g.: make val-rtl CONFIGS="val1 val2"
val-rtl: $(LOGDIR)
	@echo "Running RTL pipeline against official val configs ($(if $(CONFIGS),$(CONFIGS),all 8)), logging to $(LOGDIR)/val_rtl_$(TIMESTAMP).log"
	@bash verif/regression/run_rtl_val_regression.sh $(CONFIGS) 2>&1 | tee $(LOGDIR)/val_rtl_$(TIMESTAMP).log; \
	 ln -sf val_rtl_$(TIMESTAMP).log $(LOGDIR)/val_rtl_latest.log; \
	 exit_code=$${PIPESTATUS[0]}; \
	 exit $$exit_code

clean:
	@rm -rf /tmp/ooo_rtl_smoke /tmp/ooo_rtl_run_obj
	@rm -f golden/sim golden/*.o
	@echo "Cleaned build artifacts. Logs in $(LOGDIR)/ were kept."
