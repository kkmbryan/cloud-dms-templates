# Testing

**English** | [简体中文](TESTING.zh-CN.md)

This page records what has been tested, with which versions, and what is known not to work. It is not a certification or a support statement. Test the templates in your own non-production project before you use them in production.

## 1. Static Checks (Every Change)

| Check | Tool and version | Scope | Result |
| :--- | :--- | :--- | :--- |
| Formatting | `terraform fmt -check -recursive` (Terraform 1.11.4) | All modules and templates | Pass |
| Validation | `terraform init -backend=false` + `terraform validate` (Terraform 1.11.4, `hashicorp/google` 8.10.0) | Both root templates | Pass |
| Plan | `terraform plan` against an empty test project in `europe-west2` (no apply) | Both templates, default `EXISTING_CLOUDSQL` + `PSC` mode, plus `DMS_MANAGED_CLOUDSQL`, `PHYSICAL` + `MYSQL_8_0`, PSC endpoint off, and existing DNS zone variants | Pass |
| Negative validation | `terraform plan` | `PHYSICAL` + `MYSQL_8_4`, `PHYSICAL` with a file path, `backup_gcs_path` with a trailing slash, source password longer than 32 characters | Rejected, as intended |
| Shell lint | ShellCheck 0.10.0 | `templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh` | Pass |

## 2. Live End-to-End Tests

| Date | Code revision | Source | Target | Scenario | Seed | Result |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 2026-11 | Initial release (`91b9c77`) | MySQL 8.0.46 on Compute Engine | Cloud SQL for MySQL 8.4, Enterprise Plus | 1 (template 01) | DMS-managed logical dump | Pass: verify, start, CDC, promote. |
| 2026-11 | Initial release (`91b9c77`) | MySQL 8.0.46 on Compute Engine | Cloud SQL for MySQL 8.4, Enterprise Plus | 2 (template 02) | mysqldump file (`LOGICAL`) | Pass after the Cloud SQL instance service account was granted bucket read access by hand. Terraform now grants it automatically. |
| 2026-11-06 | PR-2 | MySQL 8.0.46 (Ubuntu 22.04) on Compute Engine | Cloud SQL for MySQL 8.4 (8.4.11), Enterprise, zonal | 1 (template 01) | DMS-managed logical dump | Pass: `make preflight` (FAIL on the fresh VM, PASS after `scripts/source-prep`), apply, verify, start, CDC, promote. Clients reached the instance through the PSC endpoint and private DNS record. No Terraform drift after the post-promotion apply. |
| 2026-11-06 | PR-2 | MySQL 8.0.46 (Ubuntu 22.04) on Compute Engine | Cloud SQL for MySQL 8.4 (8.4.11), Enterprise, zonal | 2 (template 02) | mysqldump file (`LOGICAL`) | Pass: two-phase apply, verify, start, CDC, promote. Bucket IAM fully automatic. `GTID_SUBSET` = 1 and row counts match. |
| 2026-11-06 | PR-2 | MySQL 8.0.46 (Ubuntu 22.04) on Compute Engine | Cloud SQL for MySQL 8.0, Enterprise, zonal | 2 (template 02) | Prepared Percona XtraBackup 8.0.35 folder (`PHYSICAL`) | Pass: `xtrabackup_to_gcs.sh` (backup, prepare, upload to a dedicated folder), two-phase apply, verify, start, CDC, promote. `GTID_SUBSET` = 1 and row counts match. |

## 3. Known Limitations

- **Physical seeds:** DMS supports `PHYSICAL` (XtraBackup) seeds only for a `MYSQL_8_0` target. The backup must be prepared, stored in a dedicated folder, and no single file can exceed 5 TB.
- **Secrets in state:** The source migration password is stored (marked sensitive) in Terraform state, because the DMS connection profile resource has no write-only password argument. The Cloud SQL root password is set on `root@'%'` with the write-only `password_wo` argument of `google_sql_user` and is not stored. Use a protected remote state backend.
- **`local-exec` steps:** Attaching the Network Attachment to the Cloud SQL instance and demoting the destination run `gcloud` from the machine that runs Terraform, with that machine's active `gcloud` account.
- **No Terraform apply during migration:** DMS changes some settings on the destination while the job runs. Don't run `terraform apply` on the destination between `start` and `promote`.
- **Network Attachment authorization:** The Network Attachment defaults to `ACCEPT_AUTOMATIC`.
- **PSC DNS zone:** The default private zone covers `<region>.sql.goog.` in `network`. If the VPC already has such a zone (for example for other Cloud SQL PSC instances), set `psc_existing_dns_zone_name`.
- **Issues found and fixed by the PR-2 live tests:**
  - DMS checks that the seed exists when the migration job is created, so Scenario 2 needs two applies (`create_migration_job = false`, upload the seed, then apply again).
  - `gcloud storage cp` needs `storage.objects.get`, so backup writers get `roles/storage.objectViewer` in addition to `roles/storage.objectCreator`.
  - With only a write-only root password, the provider deletes the default `root@'%'` user; the module now recreates it.
  - The empty `#innodb_redo` directory after `--prepare` broke the upload; the script now uses `gcloud storage rsync`.
  - A source view whose DEFINER user didn't exist on Cloud SQL made `verify` fail with "Definer is not supported" until the user was created (runbook section 5).
- **Detaching the Network Attachment** (`gcloud sql instances patch --clear-psc-network-attachment-uri`) restarted the instance in testing (about 5 minutes).
- **Percona XtraBackup version:** the newest XtraBackup 8.0 release (8.0.35) is older than current MySQL 8.0 servers. The helper script then requires XtraBackup 8.0.34 or later and adds `--lock-ddl=ON`.
- **Data Validation Tool:** `make validate-data` is documented but was not run in the live tests.
- **`DMS_MANAGED_CLOUDSQL` mode:** Not covered by the live tests above. In Scenario 2 you must grant the DMS-created instance's service account read access to the bucket yourself.
