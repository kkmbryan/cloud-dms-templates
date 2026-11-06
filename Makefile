SHELL := /bin/bash
TEMPLATES := templates/01-live-migration-gce-cdc templates/02-backup-migration-gcs-cdc
PROJECT_ID ?= my-gcp-project-id
REGION ?= europe-west2
# Default job ID of templates/01-live-migration-gce-cdc. For Scenario 2 use
# JOB_ID=gcs-bkp-mysql80-cdc, or JOB_ID=$$(terraform -chdir=<template> output -raw migration_job_id).
JOB_ID ?= gce-live-mysql80-cdc

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
CLOUDSQL_INSTANCE ?=

# Optional Data Validation Tool (pip install google-pso-data-validator).
DVT_SOURCE_CONN ?= dms_src
DVT_TARGET_CONN ?= dms_tgt
DVT_TABLES ?=

.PHONY: help fmt fmt-check validate lint preflight demote-destination verify-job start-job status-job lag validate-data promote-job clean

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
	@echo "  demote-destination Manual recovery only: demote the destination (terraform apply already does this)"
	@echo "  verify-job         Run Cloud DMS pre-flight verification on migration job (JOB_ID, REGION, PROJECT_ID)"
	@echo "  start-job          Start the Cloud DMS migration job (JOB_ID, REGION, PROJECT_ID)"
	@echo "  status-job         Describe the migration job state and phase (lag: Cloud Monitoring metric"
	@echo "                     datamigration.googleapis.com/migration_job/max_replica_sec_lag)"
	@echo "  lag                Show max_replica_sec_lag for the last LAG_MINUTES (JOB_ID, REGION, PROJECT_ID);"
	@echo "                     falls back to Cloud SQL replica_lag when CLOUDSQL_INSTANCE is set"
	@echo "  validate-data      Optional: Data Validation Tool count validation (DVT_SOURCE_CONN,"
	@echo "                     DVT_TARGET_CONN, DVT_TABLES=db.table[,db.table])"
	@echo "  promote-job        Promote the Cloud DMS migration job for final cutover"
	@echo "  clean              Remove local .terraform directories (keeps the committed template lock files)"

fmt:
	terraform fmt -recursive

fmt-check:
	terraform fmt -check -recursive

validate:
	@for dir in $(TEMPLATES); do \
		echo "==> Validating $$dir..."; \
		(cd $$dir && terraform init -backend=false -input=false -reconfigure && terraform validate) || exit 1; \
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

demote-destination:
	gcloud database-migration migration-jobs demote-destination $(JOB_ID) \
		--region=$(REGION) \
		--project=$(PROJECT_ID)

verify-job:
	gcloud database-migration migration-jobs verify $(JOB_ID) \
		--region=$(REGION) \
		--project=$(PROJECT_ID)

start-job:
	gcloud database-migration migration-jobs start $(JOB_ID) \
		--region=$(REGION) \
		--project=$(PROJECT_ID)

status-job:
	gcloud database-migration migration-jobs describe $(JOB_ID) \
		--region=$(REGION) \
		--project=$(PROJECT_ID) \
		--format="table(name, state, phase, duration, error.message)"

# Cloud Monitoring API v3 projects.timeSeries.list (gcloud has no time-series
# read command). The access token goes to curl on stdin (-H @-), not on argv.
# Reads the DMS metric first; if it returns no series and CLOUDSQL_INSTANCE is
# set, falls back to the Cloud SQL replica lag metric of the destination.
DMS_LAG_METRIC := datamigration.googleapis.com/migration_job/max_replica_sec_lag
CLOUDSQL_LAG_METRIC := cloudsql.googleapis.com/database/replication/replica_lag

# Formatter for `make lag`: argv[1] = metric type. Exits 3 when there are no series.
define LAG_PY
import json, sys
ts = json.load(sys.stdin).get("timeSeries", [])
if not ts:
    sys.exit(3)
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

lag:
	@set -euo pipefail; \
	start="$$(date -u -d "-$(LAG_MINUTES) minutes" +%Y-%m-%dT%H:%M:%SZ)"; \
	end="$$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
	query() { \
		$(ACCESS_TOKEN_CMD) | sed 's/^/Authorization: Bearer /' | \
		curl -sS --fail -G -H @- \
			"https://monitoring.googleapis.com/v3/projects/$(PROJECT_ID)/timeSeries" \
			--data-urlencode "filter=$$1" \
			--data-urlencode "interval.startTime=$$start" \
			--data-urlencode "interval.endTime=$$end"; \
	}; \
	show() { rc=0; printf '%s' "$$2" | python3 -c "$$LAG_PY" "$$1" || rc=$$?; return $$rc; }; \
	resp="$$(query 'metric.type="$(DMS_LAG_METRIC)" AND resource.labels.migration_job_id="$(JOB_ID)" AND resource.labels.location="$(REGION)"')"; \
	rc=0; show "$(DMS_LAG_METRIC)" "$$resp" || rc=$$?; \
	if [ "$$rc" -eq 0 ]; then exit 0; elif [ "$$rc" -ne 3 ]; then exit "$$rc"; fi; \
	echo "No $(DMS_LAG_METRIC) data for job $(JOB_ID) in the last $(LAG_MINUTES) minutes."; \
	if [ -z "$(CLOUDSQL_INSTANCE)" ]; then \
		echo "Set CLOUDSQL_INSTANCE=<destination instance> to fall back to $(CLOUDSQL_LAG_METRIC)."; \
		echo "Metrics can take several minutes to appear after the job enters CDC; also check JOB_ID/REGION/PROJECT_ID."; \
		exit 0; \
	fi; \
	echo "Falling back to $(CLOUDSQL_LAG_METRIC) for $(PROJECT_ID):$(CLOUDSQL_INSTANCE)."; \
	resp="$$(query 'metric.type="$(CLOUDSQL_LAG_METRIC)" AND resource.labels.database_id="$(PROJECT_ID):$(CLOUDSQL_INSTANCE)"')"; \
	rc=0; show "$(CLOUDSQL_LAG_METRIC)" "$$resp" || rc=$$?; \
	if [ "$$rc" -eq 3 ]; then \
		echo "No $(CLOUDSQL_LAG_METRIC) data either. Metrics can take several minutes to appear; check CLOUDSQL_INSTANCE and LAG_MINUTES."; \
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
	gcloud database-migration migration-jobs promote $(JOB_ID) \
		--region=$(REGION) \
		--project=$(PROJECT_ID)

clean:
	find . -type d -name ".terraform" -prune -exec rm -rf {} +
	find modules -type f -name ".terraform.lock.hcl" -delete
