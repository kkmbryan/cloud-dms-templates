# Scenario 2: Migration from a Backup in GCS (mysqldump / Percona XtraBackup) + Continuous CDC

**English** | [简体中文](README.zh-CN.md)

## Overview

This root Terraform template deploys a **Backup-Seeded Continuous Change Data Capture (CDC)** migration pipeline using **Database Migration Service (DMS)** for large or load-sensitive **self-managed MySQL 8.0 on Compute Engine** workloads migrating to **Cloud SQL for MySQL (`MYSQL_8_4` default or `MYSQL_8_0`)**. Default region: `europe-west2`.

### Why Use Scenario 2 (Backup in GCS + CDC)?

- **You Control the Initial Seed**: Instead of a DMS-managed dump, you create a **`mysqldump` file (`LOGICAL`, default)** or a **prepared Percona XtraBackup (`PHYSICAL`)** on your own schedule and upload it to a regional **Cloud Storage (GCS)** staging bucket.
- **Seed + Automatic GTID CDC Resumption**: DMS restores the seed from `dump_path`, reads the GTID position recorded in the backup, and then replicates ongoing **binlog CDC** changes from the live source until cutover.
- **Automatic Bucket IAM**: The DMS service agent and the Cloud SQL instance service account get `roles/storage.objectViewer` + `roles/storage.legacyBucketReader`; `backup_writer_members` get `roles/storage.objectCreator`. You don't type the service agent email. In `DMS_MANAGED_CLOUDSQL` mode, DMS creates the instance after apply, so grant its service account both reader roles yourself before `verify`: `gcloud storage buckets add-iam-policy-binding gs://BUCKET --member=serviceAccount:INSTANCE_SA --role=roles/storage.objectViewer` (repeat with `roles/storage.legacyBucketReader`).
- **Strict Terraform Schema Compliance (`dump_path` vs. `dump_flags`)**: Enforces the Google Terraform Provider requirement that `dump_path` and `dump_flags` are mutually exclusive on `google_database_migration_service_migration_job`.

### Support Matrix

| `dump_type` | Seed in GCS (`backup_gcs_path`) | Target `MYSQL_8_0` | Target `MYSQL_8_4` |
| :--- | :--- | :--- | :--- |
| `LOGICAL` (default) | One mysqldump file, for example `mysqldump/mysql80-dump.sql.gz` | Supported | Supported |
| `PHYSICAL` | Dedicated folder with a prepared XtraBackup, for example `xtrabackup/mysql80-full` | Supported | **Not supported by DMS** (Terraform validation fails) |

---

## Architecture Flow

```mermaid
flowchart LR
    subgraph GCE_VPC["Customer VPC"]
        GCE["Compute Engine VM: self-managed MySQL 8.0<br/>(GTID=ON, ROW binlog)"]
        NA["PSC Network Attachment<br/>(dms-mysql-psc-na)"]
        EP["PSC endpoint + private DNS"]
    end

    subgraph GCS_Stage["Regional Cloud Storage"]
        GCS["GCS staging bucket<br/>(mysqldump file LOGICAL<br/>or prepared XtraBackup folder PHYSICAL)"]
    end

    subgraph DMS_Control["Database Migration Service"]
        JOB["DMS migration job<br/>(CONTINUOUS: GCS dump_path + CDC<br/>+ demote-destination)"]
    end

    subgraph CloudSQL_Producer["Cloud SQL Producer VPC"]
        CSQL["Cloud SQL for MySQL 8.4 / 8.0<br/>(PSC only + network_attachment_uri)"]
    end

    GCE -->|"Step 1: upload the seed<br/>(mysqldump or xtrabackup_to_gcs.sh)"| GCS
    GCS -->|"Step 2: restore initial seed<br/>(dump_path)"| CSQL
    CSQL -->|"PSC interface: network_attachment_uri"| NA
    NA -->|"Internal routing (port 3306)"| GCE
    GCE -->|"Step 3: continuous GTID binlog CDC"| CSQL
    JOB -->|"Orchestrates seed, demote and CDC"| CSQL
    EP -->|"Applications after promotion"| CSQL
```

---

## Usage Instructions

Complete the [Prerequisites](../../README.md#3-prerequisites) (including `gcloud beta services identity create --service=datamigration.googleapis.com`) and the source preparation in [runbook section 2](../../docs/gce_mysql80_to_cloudsql_dms_migration_runbook.md) first. The order is: **apply → produce the seed → verify → start**.

### 1. Configure Variables

Copy `terraform.tfvars.example` to `terraform.tfvars` and set the project, network, `dump_type` and `backup_gcs_path`. Pass passwords as environment variables:

```bash
cp terraform.tfvars.example terraform.tfvars
export TF_VAR_cloudsql_root_password='REPLACE_ME'
export TF_VAR_source_gce_mysql_password='REPLACE_ME_MAX_32_CHARS'
```

### 2. Initialize, Validate, and Apply Infrastructure

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan

# The single seed location configured on the migration job
terraform output -raw configured_dump_path
```

### 3. Produce the Seed at `configured_dump_path`

**`LOGICAL` (default):** on the source VM, stream a mysqldump file to the exact path (full command and flags: [runbook section 4, Option B](../../docs/gce_mysql80_to_cloudsql_dms_migration_runbook.md)):

```bash
export DUMP_PATH="gs://my-dms-staging-bucket/mysqldump/mysql80-dump.sql.gz"   # = configured_dump_path
mysqldump --defaults-extra-file="${HOME}/.mysqldump.cnf" --host=127.0.0.1 \
  --databases app_db1 app_db2 --hex-blob --no-autocommit --default-character-set=utf8mb4 \
  --single-transaction --routines --triggers --events --set-gtid-purged=ON \
  | gzip -c | gcloud storage cp - "${DUMP_PATH}"
```

**`PHYSICAL` (`MYSQL_8_0` target only):** on the source VM, run [`scripts/xtrabackup_to_gcs.sh`](scripts/xtrabackup_to_gcs.sh). It backs up, prepares and uploads the files into the dedicated folder:

```bash
export GCS_BACKUP_FOLDER="gs://my-dms-staging-bucket/xtrabackup/mysql80-full"   # = configured_dump_path
export XTRABACKUP_USER="xtrabackup"   # the script prompts for the password
sudo -E ./scripts/xtrabackup_to_gcs.sh
```

### 4. Verify & Start the DMS Backup + CDC Migration Job

```bash
# Verify connection profiles, GCS permissions, and GTID replication topology
gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
  --region=europe-west2

# Start the migration job (restores from GCS dump_path, then enters continuous CDC)
gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
  --region=europe-west2
```

### 5. Cutover / Promotion

Monitor `datamigration.googleapis.com/migration_job/max_replica_sec_lag` in Cloud Monitoring. When the lag is near `0` during the scheduled maintenance window, stop application writes to the source MySQL 8.0 and promote Cloud SQL:

```bash
gcloud database-migration migration-jobs promote gcs-bkp-mysql80-cdc \
  --region=europe-west2
```

Then point applications to the `psc_endpoint_dns_name` Terraform output.
