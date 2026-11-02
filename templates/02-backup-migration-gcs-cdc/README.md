# Scenario 2: Migration from Backup in GCS (Percona XtraBackup / mysqldump) + Continuous CDC

## Overview

This root Terraform template deploys a **Backup-Seeded Continuous Change Data Capture (CDC)** migration pipeline using **Google Cloud Database Migration Service (DMS)** for multi-terabyte or load-sensitive **self-managed MySQL 8.0 on Compute Engine (GCE)** workloads migrating to **Cloud SQL for MySQL (`MYSQL_8_4` LTS default or `MYSQL_8_0`)**.

### Why Use Scenario 2 (Backup in GCS + CDC)?

- **Zero Initial Dump Load on Production Primary**: Instead of running a live dump against the active production GCE MySQL 8.0 primary, you stream a non-blocking **Percona XtraBackup (`PHYSICAL`)** or **`mysqldump` (`LOGICAL`)** from the GCE VM (or a dedicated read replica) into a regional **Cloud Storage (GCS)** staging bucket.
- **Fast Multi-TB Ingestion + Automatic GTID CDC Resumption**: Cloud DMS seeds the destination Cloud SQL instance directly from `dump_path` (`gs://<bucket>/<object>`), automatically reads the embedded GTID/binlog coordinates from the backup, and connects to the live GCE MySQL 8.0 source to stream ongoing **Binlog CDC** changes until cutover.
- **Strict Terraform Schema Compliance (`dump_path` vs. `dump_flags`)**: Enforces the Google Terraform Provider requirement that `dump_path` and `dump_flags` are mutually exclusive on `google_database_migration_service_migration_job`.

---

## Architecture Flow

```mermaid
flowchart LR
    subgraph GCE_VPC["Production VPC"]
        GCE["GCE VM: Self-Managed MySQL 8.0\n(GTID=ON, ROW Binlog)"]
        NA["PSC Network Attachment\n(dms-mysql-psc-na)"]
    end

    subgraph GCS_Stage["Regional Cloud Storage"]
        GCS["GCS Staging Bucket\n(Percona XtraBackup PHYSICAL\nor mysqldump LOGICAL)"]
    end

    subgraph DMS_Control["Google Cloud DMS"]
        JOB["DMS Migration Job\n(CONTINUOUS: GCS dump_path + CDC\n+ demote-destination)"]
    end

    subgraph CloudSQL_Producer["Cloud SQL Producer VPC"]
        CSQL["Cloud SQL for MySQL 8.4 / 8.0\n(Pure PSC + network_attachment_uri)"]
    end

    GCE -->|1. Stream Non-Blocking Backup\nstream_xtrabackup_to_gcs.sh| GCS
    GCS -->|2. Restore Initial Seed\n(dump_path)| CSQL
    CSQL -->|PSC Outbound: network_attachment_uri| NA
    NA -->|Internal Routing (Port 3306)| GCE
    GCE -->|3. Continuous GTID Binlog CDC| CSQL
    JOB -->|Orchestrates Seed, Demote & CDC| CSQL
```

---

## Usage Instructions

### 1. Configure Variables

Copy `terraform.tfvars.example` to `terraform.tfvars` and customize your project, network, and backup path settings:

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 2. Initialize, Validate, and Apply Infrastructure

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

### 3. Stream Percona XtraBackup from GCE MySQL 8.0 to GCS

On the source GCE MySQL 8.0 VM (or read replica), run the included helper script `scripts/stream_xtrabackup_to_gcs.sh` to stream a hot physical backup directly to the provisioned GCS staging bucket:

```bash
export MYSQL_USER="dms_backup_user"
export MYSQL_PASSWORD="YOUR_SECURE_PASSWORD"
export BUCKET_NAME="prod-dms-mysql80-staging-sg"
export BACKUP_OBJECT_PATH="backups/mysql80-full.xbstream"

./scripts/stream_xtrabackup_to_gcs.sh
```

### 4. Verify & Start the DMS Backup + CDC Migration Job

Once the backup file exists at `gs://${BUCKET_NAME}/${BACKUP_OBJECT_PATH}`:

```bash
# Verify connection profiles, GCS permissions, and GTID replication topology
gcloud database-migration migration-jobs verify gcs-bkp-mysql80-cdc \
  --region=asia-southeast1

# Start the migration job (restores from GCS dump_path, then enters continuous CDC)
gcloud database-migration migration-jobs start gcs-bkp-mysql80-cdc \
  --region=asia-southeast1
```

### 5. Cutover / Promotion

When CDC lag reaches `0 seconds` during the scheduled maintenance window, stop application writes to GCE MySQL 8.0 and promote Cloud SQL:

```bash
gcloud database-migration migration-jobs promote gcs-bkp-mysql80-cdc \
  --region=asia-southeast1
```
