# Scenario 1: Live Migration from Self-Managed GCE MySQL 8.0 + Continuous CDC

**English** | [简体中文](README.zh-CN.md)

## Overview

This root Terraform template deploys an end-to-end **Live Initial Dump + Continuous Change Data Capture (CDC)** pipeline using **Google Cloud Database Migration Service (DMS)** to migrate self-managed **MySQL 8.0 on Compute Engine (GCE)** to **Cloud SQL for MySQL (`MYSQL_8_4` LTS default or `MYSQL_8_0`)** with near-zero downtime.

### Key Architectural Highlights

- **Target Version Flexibility (`MYSQL_8_4` or `MYSQL_8_0`)**: Defaults to `MYSQL_8_4` (Enterprise Plus with local SSD Data Cache enabled) while supporting `MYSQL_8_0`. Cloud DMS does not support skipping major versions directly from MySQL 8.0 to 9.7; if 9.x is required in the future, perform a post-promotion upgrade (`8.0 -> 8.4 -> 9.x`).
- **Private Service Connect (PSC) Default**: Avoids transitive VPC peering constraints by provisioning a Compute Engine **Network Attachment** (`google_compute_network_attachment`) and binding Cloud SQL's **PSC Outbound** (`psc_config.network_attachment_uri`) with automated `demote-destination`, while also supporting traditional Private Services Access (`PSA`).
- **High-Throughput Initial Load (`dump_parallel_level = "MAX"`)**: Uses DMS-managed multi-threaded logical dump directly from the live GCE MySQL 8.0 instance, automatically transitioning into continuous GTID Binlog replication (`type = "CONTINUOUS"`).

---

## Architecture Flow

```mermaid
flowchart LR
    subgraph GCE_VPC["Production VPC"]
        GCE["GCE VM: Self-Managed MySQL 8.0\n(GTID=ON, ROW Binlog)"]
        NA["PSC Network Attachment\n(dms-mysql-psc-na)"]
    end

    subgraph DMS_Control["Google Cloud DMS"]
        JOB["DMS Migration Job\n(CONTINUOUS: MAX Parallel Dump + CDC\n+ demote-destination)"]
    end

    subgraph CloudSQL_Producer["Cloud SQL Producer VPC"]
        CSQL["Cloud SQL for MySQL 8.4 / 8.0\n(Pure PSC + network_attachment_uri)"]
    end

    CSQL -->|PSC Outbound: network_attachment_uri| NA
    NA -->|Internal Routing (Port 3306)| GCE
    GCE -->|1. Parallel Logical Dump\n2. Continuous Binlog CDC| CSQL
    JOB -->|Orchestrates Dump, Demote & CDC| CSQL
```

---

## Usage Instructions

### 1. Configure Variables

Copy `terraform.tfvars.example` to `terraform.tfvars` and populate your environment values:

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 2. Initialize and Validate

```bash
terraform init
terraform validate
```

### 3. Plan and Apply

```bash
terraform plan -out=tfplan
terraform apply tfplan
```

### 4. Verify & Start the DMS Migration Job

After Terraform provisions the connection profiles and migration job:

```bash
# Verify pre-flight connectivity and MySQL 8.0 replication configuration
gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
  --region=asia-southeast1

# Start the live initial dump + continuous CDC replication
gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
  --region=asia-southeast1
```

### 5. Cutover / Promotion

Once `replication_lag` reaches `0 seconds` during the cutover window, stop writes on the GCE MySQL 8.0 instance and promote the Cloud SQL destination:

```bash
gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
  --region=asia-southeast1
```
