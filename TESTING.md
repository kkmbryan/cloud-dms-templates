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
| Shell lint | ShellCheck 0.10.0 | `templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh`, `scripts/source-prep/preflight_check.sh` | Pass |
| `ignore_changes` on `psc_config` | `terraform plan` (PR-3) | Template 01 with `network_attachment_uri` managed natively | A reference from the instance to the Network Attachment creates a dependency cycle (the `ACCEPT_MANUAL` attachment needs the instance first). With a literal URI after creation, the plan reported no changes. The templates keep `ignore_changes`. |
| Upgrade from the PR-2 state | Terraform 1.11.4, the attach and demote `terraform_data` blocks with a stubbed `gcloud` | PR-2 state, then the PR-3 code | Plan: 2 in-place `input` updates, no replacement. `count` to 0 and a replacement on the old state run the destroy-time detach without errors. |

## 2. Live End-to-End Tests

| Date | Code revision | Source | Target | Scenario | Seed | Result |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| 2026-11 | Initial release (`91b9c77`) | MySQL 8.0.46 on Compute Engine | Cloud SQL for MySQL 8.4, Enterprise Plus | 1 (template 01) | DMS-managed logical dump | Pass: verify, start, CDC, promote. |
| 2026-11 | Initial release (`91b9c77`) | MySQL 8.0.46 on Compute Engine | Cloud SQL for MySQL 8.4, Enterprise Plus | 2 (template 02) | mysqldump file (`LOGICAL`) | Pass after the Cloud SQL instance service account was granted bucket read access by hand. Terraform now grants it automatically. |
| 2026-11-06 | PR-2 | MySQL 8.0.46 (Ubuntu 22.04) on Compute Engine | Cloud SQL for MySQL 8.4 (8.4.11), Enterprise, zonal | 1 (template 01) | DMS-managed logical dump | Pass: `make preflight` (FAIL on the fresh VM, PASS after `scripts/source-prep`), apply, verify, start, CDC, promote. Clients reached the instance through the PSC endpoint and private DNS record. No Terraform drift after the post-promotion apply. |
| 2026-11-06 | PR-2 | MySQL 8.0.46 (Ubuntu 22.04) on Compute Engine | Cloud SQL for MySQL 8.4 (8.4.11), Enterprise, zonal | 2 (template 02) | mysqldump file (`LOGICAL`) | Pass: two-phase apply, verify, start, CDC, promote. Bucket IAM fully automatic. `GTID_SUBSET` = 1 and row counts match. |
| 2026-11-06 | PR-2 | MySQL 8.0.46 (Ubuntu 22.04) on Compute Engine | Cloud SQL for MySQL 8.0, Enterprise, zonal | 2 (template 02) | Prepared Percona XtraBackup 8.0.35 folder (`PHYSICAL`) | Pass: `xtrabackup_to_gcs.sh` (backup, prepare, upload to a dedicated folder), two-phase apply, verify, start, CDC, promote. `GTID_SUBSET` = 1 and row counts match. |
| 2026-11-06 | PR-3 (T4) | MySQL 8.0.46 (Ubuntu 22.04), `require_secure_transport = ON` | Cloud SQL for MySQL 8.4 (8.4.11), Enterprise, zonal, `cloudsql_ssl_mode = "ENCRYPTED_ONLY"` | 1 (template 01) | DMS-managed logical dump | Pass: `ACCEPT_MANUAL` Network Attachment (tenant project derived from the instance), firewall rule with a network tag target, `source_ssl_type = "REQUIRED"`, then verify, start, CDC, promote. Through the PSC endpoint and DNS record: TLS 1.2 session, `GTID_SUBSET` = 1, row counts match, write after promotion; `--ssl-mode=DISABLED` rejected. Post-promotion apply (including `cloudsql_password_validation_policy`), then no drift. `make preflight` reports `tls` PASS. |
| 2026-11-06 | PR-3 (T5) | Same stack as T4, after promotion | Same | 1 (template 01) | — | Pass: `migration_enabled = false` destroyed 7 resources (job, profiles, demote and attach steps, Network Attachment, firewall rule) in about 6 minutes (detach about 5 minutes). Cloud SQL, PSC endpoint and DNS kept; a client probe through the endpoint failed for about 20 seconds during the restart. Clients connected and wrote afterwards; the next plan reported no changes. Then `terraform destroy`. |
| 2026-11-06 | PR-3 (T6) | MySQL 8.0.46 | Cloud SQL for MySQL 8.0, Enterprise, zonal | 1 (template 01) | DMS-managed logical dump | Pass: single apply with all defaults (`ACCEPT_MANUAL`, firewall rule with a service account target, `REQUIRED` TLS), verify, start, CDC. Deleting the `RUNNING` job (no `--force`) was accepted; the instance stayed a read replica. `terraform destroy` then detached the Network Attachment and deleted everything. |
| 2026-11-06 | PR-3 (T7) | MySQL 8.0.46 | Cloud SQL for MySQL 8.4, Enterprise, zonal, CMEK | 2 (template 02) | mysqldump file (`LOGICAL`) in a CMEK bucket | Pass: two-phase apply with `cloudsql_kms_key_name` and `staging_bucket_kms_key_name`, noncurrent-version lifecycle rule, verify, start, CDC. `terraform destroy` while the job was `RUNNING` in CDC deleted the job (about 1 minute), detached the Network Attachment and destroyed all 16 resources in about 7 minutes. |
| 2026-11-06 | PR-3 (negative tests) | MySQL 8.0.46 | Cloud SQL for MySQL 8.4 | 1 (template 01) | — | (a) `create_source_firewall_rule = false`: `verify` failed with "Failure connecting to the source database. Make sure the connectivity information on the connection profile is correct and the source database is reachable." (b) `ACCEPT_MANUAL` with a wrong `psc_producer_accept_list`: the attach step failed with `[ERROR_NETWORK_ATTACHMENT_POLICY_FORBIDDEN]` and no connection endpoint was created; fixing the list updated the attachment in place and the next apply attached it. |

## 3. Known Limitations

- **Physical seeds:** DMS supports `PHYSICAL` (XtraBackup) seeds only for a `MYSQL_8_0` target. The backup must be prepared, stored in a dedicated folder, and no single file can exceed 5 TB.
- **Secrets in state:** The source migration password is stored (marked sensitive) in Terraform state, because the DMS connection profile resource has no write-only password argument. The Cloud SQL root password is set on `root@'%'` with the write-only `password_wo` argument of `google_sql_user` and is not stored. Use a protected remote state backend.
- **`local-exec` steps:** Attaching and detaching the Network Attachment and demoting the destination run `gcloud` from the machine that runs Terraform, with that machine's active `gcloud` account, or with `impersonate_service_account` when it is set.
- **No full Terraform apply during migration:** After demotion, DMS changes the destination's backup settings, and a full `terraform apply` fails with `Backups cannot be enabled for read replica instance` until promotion. Target only the firewall rule if you must change it in that window (runbook section 6).
- **`psc_config` drift:** `psc_config` is in `ignore_changes`, so later changes to `allowed_consumer_projects` need `gcloud sql instances patch --allowed-psc-projects`.
- **Password validation policy:** Set `cloudsql_password_validation_policy` after promotion; at creation the API rejects the instance because the root password is applied afterwards.
- **`migration_enabled = false`:** Only after promotion and only in `EXISTING_CLOUDSQL` mode. Detaching the Network Attachment restarts the instance.
- **Abandoned migrations:** Deleting a job before promotion (T6, T7) left the source representation instance `<instance>-master` (`ON_PREMISES_INSTANCE`), which Terraform doesn't manage; delete it with `gcloud sql instances delete`.
- **Network Attachment authorization:** `ACCEPT_MANUAL` with the tenant project ID was accepted; the attachment shows the connection under the tenant project number.
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
