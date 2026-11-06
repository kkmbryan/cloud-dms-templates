# Operational Runbook: Self-Managed MySQL 8.0 on Compute Engine to Cloud SQL (8.0 / 8.4) Migration via Database Migration Service

**English** | [简体中文](gce_mysql80_to_cloudsql_dms_migration_runbook.zh-CN.md)

> [!IMPORTANT]
> **Target MySQL Version Policy (`MYSQL_8_0` & `MYSQL_8_4` LTS)**
> Google Cloud Database Migration Service (DMS) supports migrating from **MySQL 8.0** to **Cloud SQL for MySQL 8.0 (`MYSQL_8_0`)** or **Cloud SQL for MySQL 8.4 LTS (`MYSQL_8_4`)**.
> MySQL and Cloud DMS **do not support skipping major LTS versions** (for example, migrating directly from `8.0` to `9.7` in a single DMS step). To adopt MySQL `9.x` in the future, migrate to `MYSQL_8_4` (or `MYSQL_8_0` first, then upgrade in-place to `8.4`), promote the instance, and execute a controlled post-promotion major version upgrade (`8.0 -> 8.4 -> 9.x`).

---

## 1. Migration Decision Matrix: Scenario 1 vs. Scenario 2

| Criteria | Scenario 1: Live Migration + Continuous CDC (`01-live-migration-gce-cdc`) | Scenario 2: Backup in GCS + Continuous CDC (`02-backup-migration-gcs-cdc`) |
| :--- | :--- | :--- |
| **Database Size** | Small to Medium (`< 500 GB`) | Large to Multi-Terabyte (`500 GB – 15+ TB`) |
| **Initial Seed Mechanism** | DMS-managed parallel logical dump (`dump_type = "LOGICAL"`, `dump_parallel_level = "OPTIMAL"`) directly from the source MySQL 8.0 | mysqldump file (`dump_type = "LOGICAL"`, default) or prepared Percona XtraBackup folder (`dump_type = "PHYSICAL"`, `MYSQL_8_0` target only) in GCS via `dump_path` |
| **Impact on Source Primary** | Moderate read I/O & CPU during initial parallel dump | No DMS dump load; you run mysqldump or XtraBackup on your own schedule |
| **Ongoing Replication** | Continuous GTID Binlog CDC (`type = "CONTINUOUS"`) | Continuous GTID Binlog CDC (`type = "CONTINUOUS"`) automatically resumed from backup GTID coordinates |
| **Cutover Downtime** | Near-zero (minutes during final promotion) | Near-zero (minutes during final promotion) |

### 1.1 Seed Support Matrix

| Initial seed (`dump_type`) | Template | Target `MYSQL_8_0` | Target `MYSQL_8_4` | `dump_path` |
| :--- | :--- | :--- | :--- | :--- |
| DMS-managed logical dump (`LOGICAL`) | 01 | Supported | Supported | Not used |
| mysqldump file (`LOGICAL`, default) | 02 | Supported | Supported | One file: `gs://<bucket>/<path>.sql.gz` |
| Prepared Percona XtraBackup (`PHYSICAL`) | 02 | Supported | **Not supported by DMS** (rejected by Terraform validation) | Dedicated folder: `gs://<bucket>/<folder>` |

> [!WARNING]
> DMS doesn't support physical (XtraBackup) migrations to MySQL 8.4. Template 02 rejects `dump_type = "PHYSICAL"` unless `target_database_version = "MYSQL_8_0"`. The physical backup must be **prepared** and uploaded to a **dedicated folder** that contains no other files, and no single backup file can exceed 5 TB. See [Migrate by using a Percona XtraBackup physical file](https://cloud.google.com/database-migration/docs/mysql/migrate-with-physical-xtrabackup).

---

## 2. Phase 1: Source MySQL 8.0 Pre-Flight Verification

Before starting either Scenario 1 or Scenario 2, verify the following mandatory parameters on the self-managed source MySQL 8.0 instance (`/etc/mysql/mysql.conf.d/mysqld.cnf` or `/etc/my.cnf`):

### 2.1 Mandatory `my.cnf` Parameters for GTID & Binlog CDC

```ini
[mysqld]
server_id                  = 1001
log_bin                    = mysql-bin
binlog_format              = ROW
binlog_row_image           = FULL
gtid_mode                  = ON
enforce_gtid_consistency   = ON
binlog_expire_logs_seconds = 604800   # Retain binlogs for at least 7 days (604,800s) during initial seeding
```

Verify active runtime values on the source MySQL 8.0 instance:

```sql
SHOW GLOBAL VARIABLES WHERE Variable_name IN (
  'server_id',
  'log_bin',
  'binlog_format',
  'binlog_row_image',
  'gtid_mode',
  'enforce_gtid_consistency',
  'binlog_expire_logs_seconds'
);
```

### 2.2 Create the Migration Accounts

Use two separate accounts:

| Account | Used by | Host | Privileges |
| :--- | :--- | :--- | :--- |
| `dms_migration` | DMS source connection profile (Terraform `source_gce_mysql_username`) | `'%'` (required by DMS) | Scenario 1: `REPLICATION SLAVE`, `REPLICATION CLIENT`, `EXECUTE`, `SELECT`, `SHOW VIEW`, `TRIGGER`, `EVENT`, `RELOAD`, `LOCK TABLES`. Scenario 2 (CDC only): `REPLICATION SLAVE`, `REPLICATION CLIENT`, `EXECUTE`. **Never** `BACKUP_ADMIN`. |
| `xtrabackup` | `xtrabackup_to_gcs.sh` on the source VM (Scenario 2 `PHYSICAL` only) | `'localhost'` | `BACKUP_ADMIN`, `PROCESS`, `RELOAD`, `LOCK TABLES`, `REPLICATION CLIENT`, plus `SELECT` on `performance_schema.log_status` and `performance_schema.keyring_component_status` |

Connect to the source MySQL 8.0 instance as an administrative user and run:

```sql
-- 1) DMS migration user. DMS requires host '%' and a password of 32 characters or fewer.
CREATE USER IF NOT EXISTS 'dms_migration'@'%' IDENTIFIED BY 'REPLACE_ME_MAX_32_CHARS';

-- Scenario 1 (DMS-managed dump):
GRANT REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE, SELECT, SHOW VIEW, TRIGGER, EVENT, RELOAD, LOCK TABLES
  ON *.* TO 'dms_migration'@'%';

-- Scenario 2 (you provide the seed): CDC privileges only.
-- GRANT REPLICATION SLAVE, REPLICATION CLIENT, EXECUTE ON *.* TO 'dms_migration'@'%';

-- Do NOT grant BACKUP_ADMIN to dms_migration: DMS rejects a migration account
-- with BACKUP_ADMIN on MySQL 8.0 and later.

-- 2) XtraBackup user (Scenario 2 PHYSICAL only), local connections only.
CREATE USER IF NOT EXISTS 'xtrabackup'@'localhost' IDENTIFIED BY 'REPLACE_WITH_SECURE_PASSWORD';
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO 'xtrabackup'@'localhost';
GRANT SELECT ON performance_schema.log_status TO 'xtrabackup'@'localhost';
GRANT SELECT ON performance_schema.keyring_component_status TO 'xtrabackup'@'localhost';
```

> [!NOTE]
> For the Scenario 2 `LOGICAL` seed, run `mysqldump` with an existing administrative account that can read every migrated database (it needs `SELECT`, `SHOW VIEW`, `TRIGGER`, `EVENT`, `LOCK TABLES` and `RELOAD`). Pass credentials through a `0600` option file (`--defaults-extra-file`), never with `--password=` on the command line. References: [Configure your source database](https://cloud.google.com/database-migration/docs/mysql/configure-source-database-continuous), [Percona XtraBackup privileges](https://docs.percona.com/percona-xtrabackup/8.0/privileges.html).

---

## 3. Phase 2: Private Service Connect (PSC) & Outbound Network Attachment Architecture

Both templates default to **Private Service Connect (`connectivity_type = "PSC"`, `destination_mode = "EXISTING_CLOUDSQL"`)** to avoid transitive VPC peering limitations:

1. **Cloud SQL Pure PSC + Outbound Network Attachment (`network_attachment_uri`)**:
   - The `cloudsql-mysql-destination` module configures `psc_enabled = true` (with `ipv4_enabled = false`) and `allowed_consumer_projects`. After the instance exists, it runs `gcloud sql instances patch --psc-network-attachment-uri=...` and re-reads the instance; the apply fails if the attachment is not set. The destination Cloud SQL instance then opens private outbound replication connections into your VPC subnet.
2. **Compute Engine Network Attachment**:
   - The `networking-psc` module provisions `google_compute_network_attachment` in your subnet. When `dms_tenant_project_id` is omitted, it defaults to `ACCEPT_AUTOMATIC`; when `dms_tenant_project_id` is specified, it enforces `ACCEPT_MANUAL` and restricts `producer_accept_lists` to your project and the specified tenant project.
3. **Native DMS Connection Profiles & Migration Job**:
   - The source and destination connection profiles and the migration job are native Terraform resources. The source password is sent to the DMS API by the provider and never appears on a command line. It is still stored (marked sensitive) in Terraform state, so protect your state backend.
4. **Automated Destination Demotion (`demote-destination`)**:
   - When `destination_mode = "EXISTING_CLOUDSQL"`, the `dms-migration-job` module runs `gcloud database-migration migration-jobs demote-destination` once after the job is created, waits for the operation (default timeout 3600 s) and fails the apply if the operation reports an error.
5. **PSC Consumer Endpoint & Private DNS (Application Access)**:
   - The `cloudsql-psc-endpoint` module (`create_psc_endpoint = true` by default) reserves an internal IP in `psc_endpoint_subnet`, creates a forwarding rule to the instance's service attachment, and adds an A record for the instance DNS name in a private Cloud DNS zone for `<region>.sql.goog.` bound to `network`. If your VPC already has that zone, set `psc_existing_dns_zone_name`.

---

## 4. Phase 3: Executing the Migration

Complete the [Prerequisites](../README.md#3-prerequisites) first. The order is always: **apply → produce the seed (Scenario 2) → verify → start**.

### Option A: Scenario 1 — Live Migration + Continuous CDC (`templates/01-live-migration-gce-cdc`)

1. **Deploy Terraform Infrastructure**:
   ```bash
   cd templates/01-live-migration-gce-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your project_id, network, subnets and source IP
   export TF_VAR_cloudsql_root_password='REPLACE_ME'
   export TF_VAR_source_gce_mysql_password='REPLACE_ME_MAX_32_CHARS'
   terraform init
   terraform validate
   terraform apply
   ```
2. **Run Pre-Flight Verification**:
   ```bash
   gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
     --region=europe-west2
   ```
3. **Start Live Dump + Continuous CDC**:
   ```bash
   gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
     --region=europe-west2
   ```

---

### Option B: Scenario 2 — Backup in GCS + Continuous CDC (`templates/02-backup-migration-gcs-cdc`)

1. **Deploy Terraform Infrastructure (GCS Staging Bucket + IAM + Cloud SQL + DMS Job)**:
   ```bash
   cd templates/02-backup-migration-gcs-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars: dump_type ("LOGICAL" default, or "PHYSICAL" with MYSQL_8_0) and backup_gcs_path
   export TF_VAR_cloudsql_root_password='REPLACE_ME'
   export TF_VAR_source_gce_mysql_password='REPLACE_ME_MAX_32_CHARS'
   terraform init
   terraform validate
   terraform apply

   # The single seed location used by the migration job
   terraform output -raw configured_dump_path
   ```
2. **Produce the Seed on the Source VM at `configured_dump_path`**:
   - **Logical seed (`dump_type = "LOGICAL"`, default)**:
     ```bash
     export DUMP_PATH="gs://my-dms-staging-bucket/mysqldump/mysql80-dump.sql.gz"   # = configured_dump_path
     # ~/.mysqldump.cnf (chmod 600) contains: [client] user=... password=...
     mysqldump --defaults-extra-file="${HOME}/.mysqldump.cnf" \
       --host=127.0.0.1 \
       --databases app_db1 app_db2 \
       --hex-blob \
       --no-autocommit \
       --default-character-set=utf8mb4 \
       --single-transaction \
       --routines \
       --triggers \
       --events \
       --set-gtid-purged=ON \
       | gzip -c \
       | gcloud storage cp - "${DUMP_PATH}"
     ```
     List only application databases in `--databases` (not `mysql`, `sys`, `performance_schema` or `information_schema`), don't use `--master-data`/`--source-data` when GTID is on, and don't run DDL while the dump runs. See [Exporting a MySQL database using mysqldump](https://cloud.google.com/database-migration/docs/mysql/mysql-dump).
   - **Physical seed (`dump_type = "PHYSICAL"`, `MYSQL_8_0` target only — Percona XtraBackup 8.0)**:
     Copy [`scripts/xtrabackup_to_gcs.sh`](../templates/02-backup-migration-gcs-cdc/scripts/xtrabackup_to_gcs.sh) to the source VM and run it. It checks `innodb_page_size`, the XtraBackup and server versions, free disk and that the folder is empty, then runs `--backup`, `--prepare` and `gcloud storage cp -r` into the folder:
     ```bash
     export GCS_BACKUP_FOLDER="gs://my-dms-staging-bucket/xtrabackup/mysql80-full"   # = configured_dump_path
     export XTRABACKUP_USER="xtrabackup"   # the script prompts for the password
     sudo -E ./xtrabackup_to_gcs.sh
     ```
3. **Verify & Start Backup-Seeded CDC Migration Job**:
   ```bash
   gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
     --region=europe-west2

   gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
     --region=europe-west2
   ```

---

## 5. Phase 4: Monitoring CDC Replication Lag & Data Verification

1. **Check Migration Job Phase & State**:
   ```bash
   gcloud database-migration migration-jobs describe gce-live-mysql80-cdc \
     --region=europe-west2 \
     --format="table(name, state, phase, duration)"
   ```
   - Wait for `phase` to transition from `FULL_DUMP` to `CDC`.
2. **Monitor Cloud Monitoring Metrics**:
   - Track `datamigration.googleapis.com/migration_job/max_replica_sec_lag` and `datamigration.googleapis.com/migration_job/max_replica_bytes_lag` in Cloud Monitoring until replication lag stabilizes near `0`. See [Migration job metrics](https://cloud.google.com/database-migration/docs/mysql/migration-job-metrics).
3. **Verify GTID Convergence**:
   - On the source MySQL 8.0:
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```
   - On the destination Cloud SQL replica (read-only during CDC), connect through the PSC endpoint DNS name (`psc_endpoint_dns_name` Terraform output):
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```

---

## 6. Phase 5: Near-Zero Downtime Cutover (Promotion)

Perform the following sequence during the scheduled cutover window:

1. **Drain Application Traffic & Set the Source MySQL 8.0 to Read-Only**:
   ```sql
   SET GLOBAL super_read_only = ON;
   SET GLOBAL read_only = ON;
   ```
2. **Confirm Zero Replication Lag**:
   Verify that `SELECT @@GLOBAL.gtid_executed;` on the destination Cloud SQL instance matches the source MySQL 8.0 instance.
3. **Promote the Cloud DMS Migration Job**:
   ```bash
   gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
     --region=europe-west2
   ```
   - Cloud DMS disconnects replication from the source MySQL 8.0 and promotes the Cloud SQL for MySQL (`MYSQL_8_4` or `MYSQL_8_0`) instance to a standalone writable primary (`state = COMPLETED`).
4. **Repoint Application Endpoints**:
   - Point your connection strings to the PSC endpoint DNS name (`psc_endpoint_dns_name` Terraform output). The private zone created by Terraform resolves it to the PSC endpoint IP (`psc_endpoint_ip_address`) inside `network`. Test from an application host:
     ```bash
     mysql --host="<psc_endpoint_dns_name>" --user="<app_user>" -p -e "SELECT @@hostname, @@version;"
     ```

---

## 7. Phase 6: Post-Promotion Major Version Upgrade Path (`8.0 -> 8.4 -> 9.x`)

- If you migrated to **`MYSQL_8_0`** first for strict parity with the source MySQL 8.0, you can perform an in-place major version upgrade to **`MYSQL_8_4` LTS** via Terraform by updating `target_database_version = "MYSQL_8_4"` and running `terraform apply`.
- When Google Cloud SQL releases general availability support for MySQL **`9.x`** (`MYSQL_9_7` / innovation or LTS track), instances running on **`MYSQL_8_4`** can then follow the supported sequential major version upgrade path (`8.0 -> 8.4 -> 9.x`) with near-zero downtime using Cloud SQL Enterprise Plus rolling maintenance.
