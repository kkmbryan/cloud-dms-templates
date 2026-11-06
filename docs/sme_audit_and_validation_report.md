# Cloud DMS Migration — Multi-SME Architecture, Security & Terraform Validation Report

**English** | [简体中文](sme_audit_and_validation_report.zh-CN.md)

- **Scope**: Enterprise Customer-Agnostic Reference Architecture
- **Source Environment**: Self-Managed MySQL 8.0 on Google Compute Engine (GCE)
- **Destination Environment**: Cloud SQL for MySQL (`MYSQL_8_4` LTS Default or `MYSQL_8_0`, Enterprise Plus Regional HA)
- **Migration Service**: Google Cloud Database Migration Service (Cloud DMS) — Continuous Change Data Capture (CDC)
- **Repository Path**: `cloud-dms-templates/`
- **Review Panel**:
  - `infra-sme` — Principal Cloud Networking & Storage Infrastructure SME
  - `db-sme` — Principal Database Migration & Cloud SQL SME
  - `iac-auditor` — Principal Security & Infrastructure-as-Code (IaC) Auditor
- **Audit Status**: **APPROVED (100% PASS — 0 Errors, 0 Warnings)**

---

## 1. Executive Summary

The Cloud DMS Terraform template repository (`cloud-dms-templates`) has undergone a comprehensive multi-SME architectural review, security hardening audit, and automated Terraform schema validation against `hashicorp/google` provider `v8.9.0` (compatible with `>= 5.30.0` and Terraform `>= 1.5.0`).

All five reusable Terraform modules and both production root templates passed `terraform fmt -check -recursive`, `terraform init -backend=false`, and `terraform validate` with **zero errors and zero warnings**.

---

## 2. Architecture Decision Records (ADRs)

> [!IMPORTANT]
> **Why Cloud DMS Migrates GCE MySQL 8.0 to `MYSQL_8_0` or `MYSQL_8_4` LTS (Rather Than Skipping Directly to 9.7)**
> Native MySQL binary log replication and Google Cloud Database Migration Service (Cloud DMS) support homogeneous migrations (`8.0 -> 8.0`) and adjacent major LTS upgrades (`8.0 -> 8.4`). Skipping major versions directly (`8.0 -> 9.7`) during live continuous GTID replication is unsupported by MySQL InnoDB data dictionary and binary log replication internals. Furthermore, MySQL `8.4` is Oracle's current Long-Term Support (LTS) release track supported by Cloud SQL for MySQL. If an organization requires MySQL `9.x` in the future, the validated enterprise path is to migrate via Cloud DMS to `MYSQL_8_4` (or `MYSQL_8_0` followed by an in-place upgrade to `MYSQL_8_4`), promote the Cloud SQL instance, and execute a controlled post-promotion major version upgrade (`8.0 -> 8.4 -> 9.x`).

| Architecture Decision Area | Validated Engineering Decision & Rationale |
| :--- | :--- |
| **ADR-01: Target Database Version (`MYSQL_8_4` & `MYSQL_8_0`)** | Both templates and `modules/cloudsql-mysql-destination` enforce `contains(["MYSQL_8_0", "MYSQL_8_4"], var.database_version)` with `MYSQL_8_4` as the recommended LTS default and `MYSQL_8_0` supported for strict source parity. |
| **ADR-02: Private Service Connect (`PSC`) Default Connectivity** | `modules/networking-psc` and `modules/cloudsql-mysql-destination` default to `connectivity_type = "PSC"` and `destination_mode = "EXISTING_CLOUDSQL"`, using `google_compute_network_attachment` together with Cloud SQL's `psc_config.network_attachment_uri` (PSC Outbound) and `demote-destination` to avoid transitive VPC peering bottlenecks while retaining optional `PSA` support. |
| **ADR-03: Scenario 1 — Live Migration + Continuous CDC** | `templates/01-live-migration-gce-cdc` provisions a `CONTINUOUS` DMS migration job using a multi-threaded live logical initial dump (`dump_type = "LOGICAL"`, `dump_parallel_level = "MAX"`) followed by ongoing GTID row-based binary log CDC. |
| **ADR-04: Scenario 2 — GCS Backup-Seeded + Continuous CDC** | `templates/02-backup-migration-gcs-cdc` provisions a regional hardened GCS staging bucket (`modules/gcs-migration-staging`) and a `CONTINUOUS` DMS migration job seeded via `dump_path` supporting both `PHYSICAL` (Percona XtraBackup 8.0 default for multi-TB databases) and `LOGICAL` (`mysqldump`) backups, followed by continuous GTID Binlog CDC. |
| **ADR-05: Mutual Exclusivity Guardrail (`dump_path` vs. `dump_flags`)** | `modules/dms-migration-job` enforces strict mutual exclusivity in `google_database_migration_service_migration_job`: when `dump_path` is populated (Scenario 2), `dump_flags` and `performance_config` are dynamically suppressed (`!local.use_gcs_backup_dump`), preventing provider schema conflicts. |
| **ADR-06: Cloud SQL Enterprise Plus High Availability & Resilience** | `modules/cloudsql-mysql-destination` defaults to `edition = "ENTERPRISE_PLUS"`, `availability_type = "REGIONAL"`, `data_cache_enabled = true`, `deletion_protection = true`, `binary_log_enabled = true`, and `point_in_time_recovery_enabled = true` with 7-day transaction log retention and 30 retained automated backups. |

---

## 3. Automated Terraform & Git Validation Evidence

All validation checks were executed in `cloud-dms-templates/` against Terraform and `hashicorp/google` provider `v8.9.0`:

| Validation Check | Execution Result & Output Summary |
| :--- | :--- |
| **Git Repository Initialization (`git status`)** | **PASSED** — Local Git repository initialized on branch `main` with `.gitignore` excluding `.terraform/`, `*.tfstate*`, `*.tfvars` (while preserving `*.tfvars.example`), and `.terraform.lock.hcl`. |
| **Recursive Formatting (`terraform fmt -check -recursive`)** | **PASSED** — Exit code `0` across all `.tf` and `.tfvars.example` files in `modules/` and `templates/`. |
| **Scenario 1 Validation (`templates/01-live-migration-gce-cdc`)** | **PASSED** — `terraform init -backend=false && terraform validate` initialized modules `networking`, `cloudsql_destination`, `dms_connection_profiles`, and `dms_migration_job` and returned `Success! The configuration is valid.` (0 errors, 0 warnings). |
| **Scenario 2 Validation (`templates/02-backup-migration-gcs-cdc`)** | **PASSED** — `terraform init -backend=false && terraform validate` initialized modules `networking`, `gcs_migration_staging`, `cloudsql_destination`, `dms_connection_profiles`, and `dms_migration_job` and returned `Success! The configuration is valid.` (0 errors, 0 warnings). |
| **CI/CD & Operations Tooling (`Makefile` & `.github/workflows/terraform-ci.yml`)** | **PASSED** — `Makefile` provides `fmt`, `fmt-check`, `validate`, `lint`, `verify-job`, `status-job`, `promote-job`, and `clean`. GitHub Actions workflow automates format and schema validation on push and pull request events. |

---

## 4. Security & Compliance Audit Checklist

| Security Control Domain | Audit Verification Detail |
| :--- | :--- |
| **Secret & Credential Protection (`sensitive = true`)** | **VERIFIED** — All password and private key inputs (`root_password`, `cloudsql_root_password`, `source_password`, `source_gce_mysql_password`, `destination_password`, `dest_root_password`, `source_ssl_client_key`) are marked `sensitive = true` across all modules and root templates. |
| **Network Isolation & Zero Public IP Exposure** | **VERIFIED** — Cloud SQL destination sets `ipv4_enabled = false` by default (`var.enable_ipv4 = false`) and routes traffic over Private Service Connect (`psc_enabled = true` with explicit `allowed_consumer_projects`) or Private Services Access (`PSA`). |
| **PSC Network Attachment Authorization** | **VERIFIED** — `google_compute_network_attachment.dms_psc` supports `ACCEPT_AUTOMATIC` or explicit `ACCEPT_MANUAL` authorization via `producer_accept_lists` (`[var.project_id]` and optional `var.dms_tenant_project_id`), paired with Cloud SQL `psc_config.network_attachment_uri`. |
| **GCS Staging Bucket Hardening (Scenario 2)** | **VERIFIED** — `google_storage_bucket.migration_staging` enforces `uniform_bucket_level_access = true`, `public_access_prevention = "enforced"`, object `versioning { enabled = true }`, optional CMEK encryption (`kms_key_name`), and automated `Delete` lifecycle cleanup after `var.retention_days` (default `14` days). |
| **Least-Privilege GCS IAM Bindings** | **VERIFIED** — `modules/gcs-migration-staging` grants `roles/storage.objectViewer` and `roles/storage.legacyBucketReader` exclusively to the DMS service account (`dms_service_account_email`) and `roles/storage.objectAdmin` to explicit `backup_writer_members`. |
| **Database Deletion Protection & Point-in-Time Recovery** | **VERIFIED** — `google_sql_database_instance.destination` enforces both Terraform-level `deletion_protection = true` and GCP API-level `deletion_protection_enabled = true`, enables `cloudsql_iam_authentication = "on"`, and enables `binary_log_enabled = true` and `point_in_time_recovery_enabled = true` by default. |

---

## 5. Module & Deliverable Inventory Sign-Off

| Deliverable Path | Audited Scope & Sign-Off Status |
| :--- | :--- |
| `modules/networking-psc/` | **APPROVED** (`infra-sme` / `iac-auditor`) — Provisions `google_compute_network_attachment` and `google_database_migration_service_private_connection` (`psc_interface_config`) for `PSC` default, plus optional `PSA` peering. |
| `modules/gcs-migration-staging/` | **APPROVED** (`infra-sme` / `iac-auditor`) — Provisions hardened regional GCS staging bucket with UBLA, public access prevention, lifecycle cleanup, optional CMEK, and least-privilege IAM. |
| `modules/cloudsql-mysql-destination/` | **APPROVED** (`db-sme` / `iac-auditor`) — Provisions Cloud SQL for MySQL (`MYSQL_8_4` or `MYSQL_8_0`, `ENTERPRISE_PLUS` Regional HA, Data Cache, PSC/PSA, PITR, deletion protection). |
| `modules/dms-connection-profiles/` | **APPROVED** (`db-sme` / `iac-auditor`) — Provisions source GCE MySQL 8.0 connection profile (with optional mTLS/SSL) and destination Cloud SQL connection profile (`EXISTING_CLOUDSQL` or `DMS_MANAGED_CLOUDSQL`). |
| `modules/dms-migration-job/` | **APPROVED** (`db-sme` / `iac-auditor`) — Provisions `CONTINUOUS` DMS migration job supporting Scenario 1 (`LOGICAL` parallel dump) and Scenario 2 (`PHYSICAL` XtraBackup or `LOGICAL` dump from GCS `dump_path` with mutual exclusivity against `dump_flags`). |
| `templates/01-live-migration-gce-cdc/` | **APPROVED** (`db-sme` / `iac-auditor`) — End-to-end root template for Scenario 1 (Live GCE MySQL 8.0 Dump + Continuous Binlog CDC). |
| `templates/02-backup-migration-gcs-cdc/` | **APPROVED** (`db-sme` / `iac-auditor`) — End-to-end root template for Scenario 2 (GCS Backup Seed + Continuous Binlog CDC) including executable `scripts/stream_xtrabackup_to_gcs.sh`. |
| `docs/gce_mysql80_to_cloudsql_dms_migration_runbook.md` | **APPROVED** (`db-sme` / `iac-auditor`) — Step-by-step DBA runbook covering MySQL 8.0 GTID/binlog prerequisites, Pure PSC + PSC Outbound (`network_attachment_uri`) architecture, Scenario 1 & 2 execution, CDC monitoring, near-zero downtime promotion, and `8.0 -> 8.4 -> 9.x` upgrade path. |

---

**Signed**:
- `infra-sme` (Infrastructure & Networking SME)
- `db-sme` (Database Migration & Cloud SQL SME)
- `iac-auditor` (Principal Security & IaC Auditor)
