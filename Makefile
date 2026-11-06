SHELL := /bin/bash
TEMPLATES := templates/01-live-migration-gce-cdc templates/02-backup-migration-gcs-cdc examples/multi-database
# Required for the DMS targets: your project ID (no default on purpose).
PROJECT_ID ?=
REGION ?= europe-west2
# Template (or example) directory whose Terraform outputs supply JOB_ID and
# CLOUDSQL_INSTANCE when they aren't set: for example TF_DIR=templates/02-backup-migration-gcs-cdc.
TF_DIR ?= templates/01-live-migration-gce-cdc
# DMS job ID. Default: `terraform -chdir=$(TF_DIR) output -raw migration_job_id`.
JOB_ID ?=
# Guarded promote: maximum replication lag in seconds, and CONFIRM=yes to skip
# the interactive confirmation (for automation). SKIP_LAG_CHECK=yes skips the lag gate.
MAX_LAG_SECONDS ?= 10
# How long the DMS targets wait for their operation (verify, start, stop, ...).
OP_TIMEOUT_SECONDS ?= 1800
CONFIRM ?=
SKIP_LAG_CHECK ?=

# Source pre-flight (run on the source VM; see scripts/source-prep/README.md).
# MYSQL_DEFAULTS_FILE: MySQL option file ([client] user/password), mode 0600 or 0400.
MYSQL_DEFAULTS_FILE ?= $(HOME)/.my-dms.cnf
SCENARIO ?= 1
DMS_USER ?= dms_migration
SEED_HOURS ?= 24
BACKUP_GTID ?=
MYSQL_HOST ?=
MYSQL_PORT ?=
MYSQL_SOCKET ?=

# Replication lag window (minutes) for `make lag`, and the command that prints
# an OAuth access token for the Cloud Monitoring API.
LAG_MINUTES ?= 30
ACCESS_TOKEN_CMD ?= gcloud auth print-access-token
# Optional: destination Cloud SQL instance name, for the replica_lag fallback.
# Default: `terraform -chdir=$(TF_DIR) output -raw cloudsql_instance_name`.
CLOUDSQL_INSTANCE ?=

# Optional Data Validation Tool (pip install google-pso-data-validator).
DVT_SOURCE_CONN ?= dms_src
DVT_TARGET_CONN ?= dms_tgt
DVT_TABLES ?=

.PHONY: help fmt fmt-check validate lint test preflight demote-destination verify-job start-job status-job stop-job resume-job restart-job lag lag-max validate-data promote-job clean

# Shell prologue for the DMS targets: checks PROJECT_ID and resolves JOB_ID and
# CLOUDSQL_INSTANCE from the Terraform outputs of TF_DIR when they aren't set.
define DMS_CTX
set -euo pipefail; \
case "$(PROJECT_ID)" in ""|my-gcp-project-id|my-gcp-project-01) \
  echo "ERROR: set PROJECT_ID=<your project ID> (for example make $@ PROJECT_ID=...)." >&2; exit 2;; esac; \
JOB="$(JOB_ID)"; \
if [ -z "$$JOB" ]; then \
  if ! JOB="$$(terraform -chdir=$(TF_DIR) output -raw migration_job_id 2>/dev/null)" || [ -z "$$JOB" ]; then \
    echo "ERROR: set JOB_ID, or TF_DIR to an applied template that outputs migration_job_id." >&2; exit 2; \
  fi; \
fi; \
INSTANCE="$(CLOUDSQL_INSTANCE)"; \
if [ -z "$$INSTANCE" ]; then \
  INSTANCE="$$(terraform -chdir=$(TF_DIR) output -raw cloudsql_instance_name 2>/dev/null)" || INSTANCE=""; \
fi; \
GC=(--region="$(REGION)" --project="$(PROJECT_ID)"); \
run_op() { \
  local verb="$$1" op done err deadline; \
  op="$$(gcloud database-migration migration-jobs "$$verb" "$$JOB" "$${GC[@]}" --format="value(name)")"; \
  if [ -z "$$op" ]; then echo "ERROR: $$verb returned no operation." >&2; return 1; fi; \
  echo "Waiting for $$verb on $$JOB ($$op)..."; \
  deadline=$$(( $$(date +%s) + $(OP_TIMEOUT_SECONDS) )); \
  while :; do \
    done="$$(gcloud database-migration operations describe "$$op" "$${GC[@]}" --format="value(done)")"; \
    if [ "$$done" = "True" ] || [ "$$done" = "true" ]; then break; fi; \
    if [ "$$(date +%s)" -ge "$$deadline" ]; then echo "ERROR: $$verb did not finish within $(OP_TIMEOUT_SECONDS)s." >&2; return 1; fi; \
    sleep 10; \
  done; \
  err="$$(gcloud database-migration operations describe "$$op" "$${GC[@]}" --format="value(error.message)")"; \
  if [ -n "$$err" ]; then echo "ERROR: $$verb failed: $$err" >&2; return 1; fi; \
  gcloud database-migration migration-jobs describe "$$JOB" "$${GC[@]}" --format="table(name.basename(), state, phase, error.message)"; \
}
endef

help:
	@echo "Cloud DMS Migration - Terraform & Operations Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  fmt                Format all Terraform configuration files recursively"
	@echo "  fmt-check          Check formatting of all Terraform configuration files"
	@echo "  validate           Initialize (backend=false) and validate all root templates"
	@echo "  lint               Run tflint across modules and templates"
	@echo "  preflight          On the source VM: read-only MySQL source checks (MYSQL_DEFAULTS_FILE, SCENARIO,"
	@echo "                     DMS_USER, SEED_HOURS, optional BACKUP_GTID, MYSQL_HOST/MYSQL_PORT/MYSQL_SOCKET)"
	@echo "  test               Run terraform test (mock provider) in each template"
	@echo "  demote-destination MANUAL RECOVERY ONLY: demote the destination (terraform apply already does this)"
	@echo "  verify-job         Run Cloud DMS pre-flight verification on migration job (JOB_ID, REGION, PROJECT_ID)"
	@echo "  start-job          Start the Cloud DMS migration job (JOB_ID, REGION, PROJECT_ID)"
	@echo "  status-job         Describe the migration job state and phase (lag: Cloud Monitoring metric"
	@echo "                     datamigration.googleapis.com/migration_job/max_replica_sec_lag)"
	@echo "  lag                Show max_replica_sec_lag for the last LAG_MINUTES (JOB_ID, REGION, PROJECT_ID);"
	@echo "                     falls back to Cloud SQL replica_lag (CLOUDSQL_INSTANCE, default from TF_DIR)"
	@echo "  lag-max            Print only the latest replication lag in seconds (used by promote-job)"
	@echo "  validate-data      Optional: Data Validation Tool count validation (DVT_SOURCE_CONN,"
	@echo "                     DVT_TARGET_CONN, DVT_TABLES=db.table[,db.table])"
	@echo "  stop-job           Stop a running migration job (JOB_ID or TF_DIR, PROJECT_ID)"
	@echo "  resume-job         Resume a stopped migration job"
	@echo "  restart-job        Restart a failed or stopped job from the beginning (re-dumps the data)"
	@echo "  promote-job        Guarded promote: job must be RUNNING in CDC, lag <= MAX_LAG_SECONDS, then"
	@echo "                     confirm by typing the job ID (CONFIRM=yes skips the prompt)"
	@echo "  clean              Remove local .terraform directories (keeps the committed template lock files)"
	@echo ""
	@echo "  DMS targets need PROJECT_ID. JOB_ID and CLOUDSQL_INSTANCE default to the Terraform outputs of TF_DIR."

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

validate:
	@for dir in $(TEMPLATES); do \
		echo "==> Validating $$dir..."; \
		(cd $$dir && terraform init -backend=false -input=false -reconfigure && terraform validate) || exit 1; \
	done

test:
	@for dir in $(TEMPLATES); do \
		echo "==> terraform test in $$dir..."; \
		(cd $$dir && terraform init -backend=false -input=false && terraform test) || exit 1; \
	done

lint:
	@if command -v tflint >/dev/null 2>&1; then \
		tflint --init && tflint --recursive; \
	else \
		echo "tflint not installed; skipping tflint check."; \
	fi

preflight:
	MYSQL_DEFAULTS_FILE="$(MYSQL_DEFAULTS_FILE)" MYSQL_HOST="$(MYSQL_HOST)" MYSQL_PORT="$(MYSQL_PORT)" \
	MYSQL_SOCKET="$(MYSQL_SOCKET)" ./scripts/source-prep/preflight_check.sh \
		--scenario "$(SCENARIO)" \
		--dms-user "$(DMS_USER)" \
		--seed-hours "$(SEED_HOURS)" \
		$(if $(BACKUP_GTID),--backup-gtid "$(BACKUP_GTID)")

# Manual recovery only: `terraform apply` already demotes the destination once.
demote-destination:
	@$(DMS_CTX); \
	echo "MANUAL RECOVERY: demoting the destination of $$JOB (terraform apply normally does this)."; \
	run_op demote-destination

verify-job:
	@$(DMS_CTX); run_op verify

start-job:
	@$(DMS_CTX); run_op start

status-job:
	@$(DMS_CTX); gcloud database-migration migration-jobs describe "$$JOB" "$${GC[@]}" \
		--format="table(name, state, phase, duration, error.message)"

stop-job:
	@$(DMS_CTX); run_op stop

resume-job:
	@$(DMS_CTX); run_op resume

restart-job:
	@$(DMS_CTX); \
	echo "Restarting $$JOB from the beginning: DMS clears the destination data and dumps again."; \
	run_op restart

# Cloud Monitoring API v3 projects.timeSeries.list (gcloud has no time-series
# read command). The access token goes to curl on stdin (-H @-), not on argv.
# Reads the DMS metric first; if it returns no series and CLOUDSQL_INSTANCE is
# set, falls back to the Cloud SQL replica lag metric of the destination.
DMS_LAG_METRIC := datamigration.googleapis.com/migration_job/max_replica_sec_lag
CLOUDSQL_LAG_METRIC := cloudsql.googleapis.com/database/replication/replica_lag

# Formatter for `make lag`: argv[1] = metric type, argv[2] = "table" or "max".
# "max" prints only the highest of the newest values per series (used by the
# guarded promote). Exits 3 when there are no series.
define LAG_PY
import json, sys
ts = json.load(sys.stdin).get("timeSeries", [])
if not ts:
    sys.exit(3)
mode = sys.argv[2] if len(sys.argv) > 2 else "table"
def val(p):
    v = p["value"]
    return float(v.get("int64Value", v.get("doubleValue", 0)))
if mode == "max":
    print(max(val(max(t["points"], key=lambda p: p["interval"]["endTime"])) for t in ts if t.get("points")))
    sys.exit(0)
print("Metric: " + sys.argv[1])
print("%-22s %-40s %s" % ("END_TIME", "SERIES", "LAG_SECONDS"))
for t in ts:
    labels = dict(t.get("resource", {}).get("labels", {}))
    labels.update(t.get("metric", {}).get("labels", {}))
    series = labels.get("database") or labels.get("database_id") or labels.get("migration_job_id", "-")
    for p in t.get("points", []):
        v = p["value"]
        print("%-22s %-40s %s" % (p["interval"]["endTime"], series, v.get("int64Value", v.get("doubleValue"))))
endef
export LAG_PY

# `make lag` prints a table; `make lag-max` prints one number (seconds) and
# sends messages to stderr. Both read the DMS metric first and fall back to the
# destination's Cloud SQL replica_lag (CLOUDSQL_INSTANCE, default from TF_DIR).
LAG_MODE ?= table
lag-max:
	@$(MAKE) --no-print-directory -s lag LAG_MODE=max

lag:
	@$(DMS_CTX); \
	say() { if [ "$(LAG_MODE)" = "max" ]; then echo "$$*" >&2; else echo "$$*"; fi; }; \
	start="$$(python3 -c 'import datetime as d, sys; print((d.datetime.now(d.timezone.utc) - d.timedelta(minutes=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$(LAG_MINUTES)")"; \
	end="$$(python3 -c 'import datetime as d; print(d.datetime.now(d.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))')"; \
	query() { \
		$(ACCESS_TOKEN_CMD) | sed 's/^/Authorization: Bearer /' | \
		curl -sS --fail -G -H @- \
			"https://monitoring.googleapis.com/v3/projects/$(PROJECT_ID)/timeSeries" \
			--data-urlencode "filter=$$1" \
			--data-urlencode "interval.startTime=$$start" \
			--data-urlencode "interval.endTime=$$end"; \
	}; \
	show() { rc=0; printf '%s' "$$2" | python3 -c "$$LAG_PY" "$$1" "$(LAG_MODE)" || rc=$$?; return $$rc; }; \
	resp="$$(query 'metric.type="$(DMS_LAG_METRIC)" AND resource.labels.migration_job_id="'"$$JOB"'" AND resource.labels.location="$(REGION)"')"; \
	rc=0; show "$(DMS_LAG_METRIC)" "$$resp" || rc=$$?; \
	if [ "$$rc" -eq 0 ]; then exit 0; elif [ "$$rc" -ne 3 ]; then exit "$$rc"; fi; \
	say "No $(DMS_LAG_METRIC) data for job $$JOB in the last $(LAG_MINUTES) minutes."; \
	if [ -z "$$INSTANCE" ]; then \
		say "Set CLOUDSQL_INSTANCE=<destination instance> (or TF_DIR) to fall back to $(CLOUDSQL_LAG_METRIC)."; \
		say "Metrics can take several minutes to appear after the job enters CDC; also check JOB_ID/REGION/PROJECT_ID."; \
		exit 0; \
	fi; \
	say "Falling back to $(CLOUDSQL_LAG_METRIC) for $(PROJECT_ID):$$INSTANCE."; \
	resp="$$(query 'metric.type="$(CLOUDSQL_LAG_METRIC)" AND resource.labels.database_id="$(PROJECT_ID):'"$$INSTANCE"'"')"; \
	rc=0; show "$(CLOUDSQL_LAG_METRIC)" "$$resp" || rc=$$?; \
	if [ "$$rc" -eq 3 ]; then \
		say "No $(CLOUDSQL_LAG_METRIC) data either. Metrics can take several minutes to appear; check CLOUDSQL_INSTANCE and LAG_MINUTES."; \
		exit 0; \
	fi; \
	exit "$$rc"

validate-data:
	@command -v data-validation >/dev/null 2>&1 || { \
		echo "data-validation not found. Optional tool: pip install google-pso-data-validator"; \
		echo "and create the connections first (see scripts/source-prep/README.md)."; exit 1; }
	@test -n "$(DVT_TABLES)" || { echo "Set DVT_TABLES=db.table[,db.table...]"; exit 1; }
	data-validation validate column \
		--source-conn "$(DVT_SOURCE_CONN)" \
		--target-conn "$(DVT_TARGET_CONN)" \
		--tables-list "$(DVT_TABLES)"

promote-job:
	@$(DMS_CTX); \
	read -r STATE PHASE < <(gcloud database-migration migration-jobs describe "$$JOB" "$${GC[@]}" --format="value(state,phase)"); \
	echo "Job $$JOB: state=$$STATE phase=$$PHASE"; \
	if [ "$$STATE" != "RUNNING" ] || { [ "$$PHASE" != "CDC" ] && [ "$$PHASE" != "READY_FOR_PROMOTE" ]; }; then \
		echo "ERROR: promote only a RUNNING job in the CDC phase." >&2; exit 1; \
	fi; \
	if [ "$(SKIP_LAG_CHECK)" != "yes" ]; then \
		LAG="$$($(MAKE) --no-print-directory -s lag LAG_MODE=max JOB_ID="$$JOB" CLOUDSQL_INSTANCE="$$INSTANCE" LAG_MINUTES=10)"; \
		if [ -z "$$LAG" ]; then echo "ERROR: no replication lag data in the last 10 minutes (SKIP_LAG_CHECK=yes to override)." >&2; exit 1; fi; \
		echo "Latest replication lag: $${LAG}s (limit $(MAX_LAG_SECONDS)s)"; \
		if ! python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) <= float(sys.argv[2]) else 1)' "$$LAG" "$(MAX_LAG_SECONDS)"; then \
			echo "ERROR: lag above MAX_LAG_SECONDS; stop writes on the source and retry." >&2; exit 1; \
		fi; \
	fi; \
	if [ "$(CONFIRM)" != "yes" ]; then \
		echo "Complete the Go / No-Go checklist (runbook section 8.1) and stop writes on the source first."; \
		read -r -p "Type the job ID to promote $$JOB: " ANSWER; \
		if [ "$$ANSWER" != "$$JOB" ]; then echo "Aborted." >&2; exit 1; fi; \
	fi; \
	run_op promote

clean:
	find . -type d -name ".terraform" -prune -exec rm -rf {} +
	find modules -type f -name ".terraform.lock.hcl" -delete
