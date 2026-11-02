SHELL := /bin/bash
TEMPLATES := templates/01-live-migration-gce-cdc templates/02-backup-migration-gcs-cdc
PROJECT_ID ?= my-gcp-project-id
REGION ?= asia-southeast1
JOB_ID ?= gce-mysql80-to-cloudsql-cdc

.PHONY: help fmt fmt-check validate lint demote-destination verify-job start-job status-job promote-job clean

help:
	@echo "Cloud DMS Migration - Terraform & Operations Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  fmt                Format all Terraform configuration files recursively"
	@echo "  fmt-check          Check formatting of all Terraform configuration files"
	@echo "  validate           Initialize (backend=false) and validate all root templates"
	@echo "  lint               Run tflint across modules and templates"
	@echo "  demote-destination Demote pre-existing Cloud SQL PSC destination instance for migration job"
	@echo "  verify-job         Run Cloud DMS pre-flight verification on migration job (JOB_ID, REGION, PROJECT_ID)"
	@echo "  start-job          Start the Cloud DMS migration job (JOB_ID, REGION, PROJECT_ID)"
	@echo "  status-job         Describe current Cloud DMS migration job phase and replication lag"
	@echo "  promote-job        Promote the Cloud DMS migration job for final cutover"
	@echo "  clean              Remove local .terraform directories and lock files"

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

promote-job:
	gcloud database-migration migration-jobs promote $(JOB_ID) \
		--region=$(REGION) \
		--project=$(PROJECT_ID)

clean:
	find . -type d -name ".terraform" -exec rm -rf {} +
	find . -type f -name ".terraform.lock.hcl" -delete
