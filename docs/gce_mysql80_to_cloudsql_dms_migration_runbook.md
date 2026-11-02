# Operational Runbook: GCE Self-Managed MySQL 8.0 to Cloud SQL (8.0 / 8.4) Migration via Cloud DMS

> [!IMPORTANT]
> **Target MySQL Version Policy (`MYSQL_8_0` & `MYSQL_8_4` LTS)**
> Google Cloud Database Migration Service (DMS) supports migrating from **MySQL 8.0** to **Cloud SQL for MySQL 8.0 (`MYSQL_8_0`)** or **Cloud SQL for MySQL 8.4 LTS (`MYSQL_8_4`)**.
> MySQL and Cloud DMS **do not support skipping major LTS versions** (for example, migrating directly from `8.0` to `9.7` in a single DMS step). To adopt MySQL `9.x` in the future, migrate to `MYSQL_8_4` (or `MYSQL_8_0` first, then upgrade in-place to `8.4`), promote the instance, and execute a controlled post-promotion major version upgrade (`8.0 -> 8.4 -> 9.x`).

---

## 1. Migration Decision Matrix: Scenario 1 vs. Scenario 2

| Criteria | Scenario 1: Live Migration + Continuous CDC (`01-live-migration-gce-cdc`) | Scenario 2: Backup in GCS + Continuous CDC (`02-backup-migration-gcs-cdc`) |
| :--- | :--- | :--- |
| **Database Size** | Small to Medium (`< 500 GB`) | Large to Multi-Terabyte (`500 GB – 15+ TB`) |
| **Initial Seed Mechanism** | DMS-managed parallel logical dump (`dump_type = "LOGICAL"`, `dump_parallel_level = "MAX"`) directly from GCE MySQL 8.0 | Pre-staged physical backup (`Percona XtraBackup`, `dump_type = "PHYSICAL"`) or logical dump (`mysqldump`, `dump_type = "LOGICAL"`) in GCS via `dump_path` |
| **Impact on Source GCE Primary** | Moderate read I/O & CPU during initial parallel dump | Near-zero impact (hot physical stream via `xtrabackup` or taken from a GCE read replica) |
| **Ongoing Replication** | Continuous GTID Binlog CDC (`type = "CONTINUOUS"`) | Continuous GTID Binlog CDC (`type = "CONTINUOUS"`) automatically resumed from backup GTID coordinates |
| **Cutover Downtime** | Near-zero (minutes during final promotion) | Near-zero (minutes during final promotion) |

---

## 2. Phase 1: Source GCE MySQL 8.0 Pre-Flight Verification

Before starting either Scenario 1 or Scenario 2, verify the following mandatory parameters on the source self-managed GCE MySQL 8.0 instance (`/etc/mysql/mysql.conf.d/mysqld.cnf` or `/etc/my.cnf`):

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

Verify active runtime values on the GCE MySQL 8.0 instance:

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

### 2.2 Create Dedicated DMS Replication & Migration User

Connect to the GCE MySQL 8.0 source instance as `root` and create the migration user:

```sql
CREATE USER IF NOT EXISTS 'dms_repl_user'@'%' IDENTIFIED BY 'REPLACE_WITH_SECURE_PASSWORD';

-- Required privileges for initial logical dump and continuous GTID Binlog CDC
GRANT REPLICATION SLAVE, REPLICATION CLIENT, SELECT, SHOW VIEW, TRIGGER, EVENT
  ON *.* TO 'dms_repl_user'@'%';

-- Additional privileges if using Percona XtraBackup 8.0 on the source GCE VM
GRANT BACKUP_ADMIN, PROCESS, RELOAD, LOCK TABLES, PERFORMANCE_SCHEMA.*
  ON *.* TO 'dms_repl_user'@'%';

FLUSH PRIVILEGES;
```

---

## 3. Phase 2: Private Service Connect (PSC) & Outbound Network Attachment Architecture

Both templates default to **Private Service Connect (`connectivity_type = "PSC"`, `destination_mode = "EXISTING_CLOUDSQL"`)** to avoid transitive VPC peering limitations:

1. **Cloud SQL Pure PSC + Outbound Network Attachment (`network_attachment_uri`)**:
   - The `cloudsql-mysql-destination` module configures `psc_enabled = true` (with `ipv4_enabled = false`), populates `allowed_consumer_projects`, and binds `psc_config.network_attachment_uri` to the Compute Engine Network Attachment so the destination Cloud SQL instance can establish private outbound replication connections directly into your VPC subnet.
2. **Compute Engine Network Attachment**:
   - The `networking-psc` module provisions `google_compute_network_attachment` in your GCE subnet. When `dms_tenant_project_id` is omitted, it defaults to `ACCEPT_AUTOMATIC`; when `dms_tenant_project_id` is specified, it enforces `ACCEPT_MANUAL` and restricts `producer_accept_lists` to your project and the specified tenant project.
3. **Automated Destination Demotion (`demote-destination`)**:
   - When `destination_mode = "EXISTING_CLOUDSQL"`, the `dms-migration-job` module creates the migration job and automatically runs `gcloud database-migration migration-jobs demote-destination`, preparing the standalone Cloud SQL instance for `verify` and `start`.

---

## 4. Phase 3: Executing the Migration

### Option A: Scenario 1 — Live Migration + Continuous CDC (`templates/01-live-migration-gce-cdc`)

1. **Deploy Terraform Infrastructure**:
   ```bash
   cd templates/01-live-migration-gce-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars with your project_id, VPC, GCE IP, and credentials
   terraform init
   terraform validate
   terraform apply
   ```
2. **Run Pre-Flight Verification**:
   ```bash
   gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
     --region=asia-southeast1
   ```
3. **Start Live Dump + Continuous CDC**:
   ```bash
   gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
     --region=asia-southeast1
   ```

---

### Option B: Scenario 2 — Backup in GCS + Continuous CDC (`templates/02-backup-migration-gcs-cdc`)

1. **Deploy Terraform Infrastructure (GCS Staging Bucket + Cloud SQL + DMS Job)**:
   ```bash
   cd templates/02-backup-migration-gcs-cdc
   cp terraform.tfvars.example terraform.tfvars
   # Edit terraform.tfvars (choose dump_type = "PHYSICAL" for XtraBackup or "LOGICAL" for mysqldump)
   terraform init
   terraform validate
   terraform apply
   ```
2. **Stream Non-Blocking Backup from GCE MySQL 8.0 to GCS**:
   - **Physical Backup (Recommended for Multi-TB Databases — Percona XtraBackup 8.0)**:
     Run the included helper script on the GCE MySQL 8.0 VM:
     ```bash
     export MYSQL_USER="dms_repl_user"
     export MYSQL_PASSWORD="YOUR_SECURE_PASSWORD"
     export BUCKET_NAME="prod-dms-mysql80-staging-sg"
     export BACKUP_OBJECT_PATH="backups/mysql80-full.xbstream"

     ./scripts/stream_xtrabackup_to_gcs.sh
     ```
   - **Alternative Logical Backup (`mysqldump` with `dump_type = "LOGICAL"`)**:
     ```bash
     mysqldump \
       --host=127.0.0.1 \
       --user=dms_repl_user \
       --password="${MYSQL_PASSWORD}" \
       --all-databases \
       --single-transaction \
       --routines \
       --triggers \
       --events \
       --set-gtid-purged=ON \
       --master-data=1 \
       | gzip -c \
       | gcloud storage cp - "gs://${BUCKET_NAME}/backups/mysql80-dump.sql.gz"
     ```
3. **Verify & Start Backup-Seeded CDC Migration Job**:
   ```bash
   gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
     --region=asia-southeast1

   gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
     --region=asia-southeast1
   ```

---

## 5. Phase 4: Monitoring CDC Replication Lag & Data Verification

1. **Check Migration Job Phase & State**:
   ```bash
   gcloud database-migration migration-jobs describe gce-live-mysql80-cdc \
     --region=asia-southeast1 \
     --format="table(name, state, phase, duration)"
   ```
   - Wait for `phase` to transition from `FULL_DUMP` to `CDC`.
2. **Monitor Cloud Monitoring Metric**:
   - Track `datamigration.googleapis.com/migration_job/replication_lag` in Cloud Monitoring until replication lag stabilizes at `0 seconds`.
3. **Verify GTID Convergence**:
   - On Source GCE MySQL 8.0:
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```
   - On Destination Cloud SQL replica (read-only during CDC):
     ```sql
     SELECT @@GLOBAL.gtid_executed;
     ```

---

## 6. Phase 5: Near-Zero Downtime Cutover (Promotion)

Perform the following sequence during the scheduled cutover window:

1. **Drain Application Traffic & Set Source GCE MySQL 8.0 to Read-Only**:
   ```sql
   SET GLOBAL super_read_only = ON;
   SET GLOBAL read_only = ON;
   ```
2. **Confirm Zero Replication Lag**:
   Verify that `SELECT @@GLOBAL.gtid_executed;` on the destination Cloud SQL instance matches the source GCE MySQL 8.0 instance.
3. **Promote the Cloud DMS Migration Job**:
   ```bash
   gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
     --region=asia-southeast1
   ```
   - Cloud DMS disconnects replication from the GCE MySQL 8.0 source and promotes the Cloud SQL for MySQL (`MYSQL_8_4` or `MYSQL_8_0`) instance to a standalone writable primary (`state = COMPLETED`).
4. **Repoint Application Endpoints**:
   - Update your Private DNS record or connection strings to point to the Cloud SQL PSC DNS name (`cloudsql_dns_name` Terraform output).

---

## 7. Phase 6: Post-Promotion Major Version Upgrade Path (`8.0 -> 8.4 -> 9.x`)

- If you migrated to **`MYSQL_8_0`** first for strict parity with GCE MySQL 8.0, you can perform an in-place major version upgrade to **`MYSQL_8_4` LTS** via Terraform by updating `target_database_version = "MYSQL_8_4"` and running `terraform apply`.
- When Google Cloud SQL releases general availability support for MySQL **`9.x`** (`MYSQL_9_7` / innovation or LTS track), instances running on **`MYSQL_8_4`** can then follow the supported sequential major version upgrade path (`8.0 -> 8.4 -> 9.x`) with near-zero downtime using Cloud SQL Enterprise Plus rolling maintenance.
