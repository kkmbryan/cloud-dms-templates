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
| — | Current | MySQL 8.0 | Cloud SQL for MySQL 8.0 | 2 (template 02) | Prepared Percona XtraBackup folder (`PHYSICAL`) | **Pending re-test.** Not yet tested end to end. |
| — | Current | MySQL 8.0 | Cloud SQL for MySQL 8.4 | 1 and 2 | Logical | **Pending re-test** with the current code (native connection profiles and migration job, PSC endpoint and DNS, automatic bucket IAM) in `europe-west2`. |

## 3. Known Limitations

- **Physical seeds:** DMS supports `PHYSICAL` (XtraBackup) seeds only for a `MYSQL_8_0` target. The backup must be prepared, stored in a dedicated folder, and no single file can exceed 5 TB.
- **Secrets in state:** The source migration password is stored (marked sensitive) in Terraform state, because the DMS connection profile resource has no write-only password argument. The Cloud SQL root password uses the write-only `root_password_wo` argument and is not stored. Use a protected remote state backend.
- **`local-exec` steps:** Attaching the Network Attachment to the Cloud SQL instance and demoting the destination run `gcloud` from the machine that runs Terraform, with that machine's active `gcloud` account.
- **No Terraform apply during migration:** DMS changes some settings on the destination while the job runs. Don't run `terraform apply` on the destination between `start` and `promote`.
- **Network Attachment authorization:** The Network Attachment defaults to `ACCEPT_AUTOMATIC`.
- **PSC DNS zone:** The default private zone covers `<region>.sql.goog.` in `network`. If the VPC already has such a zone (for example for other Cloud SQL PSC instances), set `psc_existing_dns_zone_name`.
- **`DMS_MANAGED_CLOUDSQL` mode:** Not covered by the live tests above. In Scenario 2 you must grant the DMS-created instance's service account read access to the bucket yourself.
