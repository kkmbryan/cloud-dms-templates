# Scenario 1: Live Migration from Self-Managed MySQL 8.0 on Compute Engine + Continuous CDC

**English** | [简体中文](README.zh-CN.md)

## Overview

This root Terraform template deploys an end-to-end **Live Initial Dump + Continuous Change Data Capture (CDC)** pipeline using **Database Migration Service (DMS)** to migrate self-managed **MySQL 8.0 on Compute Engine** to **Cloud SQL for MySQL (`MYSQL_8_4` default or `MYSQL_8_0`)** with a short cutover window. Default region: `europe-west2`.

### Key Architectural Highlights

- **Target Version Flexibility (`MYSQL_8_4` or `MYSQL_8_0`)**: Defaults to `MYSQL_8_4` (Enterprise Plus with Data Cache) while supporting `MYSQL_8_0`.
- **Private Service Connect (PSC) Default**: Creates a Compute Engine **Network Attachment** and attaches it to the PSC-only Cloud SQL instance (PSC interface, `psc_config.network_attachment_uri`) so that DMS reaches the source in your VPC. Private Services Access (`PSA`) is optional.
- **Application Access After Promotion**: Creates a **PSC consumer endpoint** (internal IP + forwarding rule) and a **private Cloud DNS record** for the instance DNS name (`create_psc_endpoint = true`).
- **No Passwords on the Command Line**: The DMS connection profiles and the migration job are native Terraform resources. The Cloud SQL root password is set on `root@'%'` with the write-only `password_wo` argument of `google_sql_user` and is not stored in state.
- **Locked-Down Replication Path**: The Network Attachment uses `ACCEPT_MANUAL` and accepts only the Cloud SQL tenant project, derived from the instance in the same apply. A firewall rule (logging on) allows `tcp:source_gce_mysql_port` only from the Network Attachment subnet (`network_attachment_subnet`) to the source VM (`source_target_tags` or `source_target_service_accounts`). DMS connects over TLS (`source_ssl_type = "REQUIRED"`), and Cloud SQL accepts only encrypted connections (`cloudsql_ssl_mode = "ENCRYPTED_ONLY"`). See [docs/security_hardening.md](../../docs/security_hardening.md).
- **DMS-Managed Initial Load (`dump_parallel_level = "OPTIMAL"`)**: DMS runs a parallel logical dump from the live source and then switches to continuous GTID binlog replication (`type = "CONTINUOUS"`). `OPTIMAL` is the DMS recommendation; `MAX` adds load on the source.

---

## Architecture Flow

```mermaid
flowchart LR
    subgraph GCE_VPC["Customer VPC"]
        GCE["Compute Engine VM: self-managed MySQL 8.0<br/>(GTID=ON, ROW binlog)"]
        NA["PSC Network Attachment<br/>(ACCEPT_MANUAL, dedicated subnet)"]
        FW["Firewall rule<br/>(NA subnet to tcp:3306, logged)"]
        EP["PSC endpoint + private DNS"]
    end

    subgraph DMS_Control["Database Migration Service"]
        JOB["DMS migration job<br/>(CONTINUOUS: OPTIMAL parallel dump + CDC<br/>+ demote-destination)"]
    end

    subgraph CloudSQL_Producer["Cloud SQL Producer VPC"]
        CSQL["Cloud SQL for MySQL 8.4 / 8.0<br/>(PSC only + network_attachment_uri)"]
    end

    CSQL -->|"PSC interface: network_attachment_uri"| NA
    NA --> FW
    FW -->|"TLS (source_ssl_type), port 3306"| GCE
    GCE -->|"Step 1: parallel logical dump<br/>Step 2: continuous binlog CDC"| CSQL
    JOB -->|"Orchestrates dump, demote and CDC"| CSQL
    EP -->|"Applications after promotion"| CSQL
```

---

## Usage Instructions

Complete the [Prerequisites](../../README.md#3-prerequisites) and the source preparation in [runbook section 2](../../docs/gce_mysql80_to_cloudsql_dms_migration_runbook.md) first (`make preflight` must report no FAIL). The order is: **apply → users, grants, DEFINERs and flags (runbook section 5) → verify → start**.

### 1. Configure Variables

Copy `terraform.tfvars.example` to `terraform.tfvars` and populate your environment values, including `network_attachment_subnet` and `source_target_tags` (or `source_target_service_accounts`) for the firewall rule. Pass passwords as environment variables (for example from Secret Manager) instead of writing them to disk, and keep state in a remote backend ([`backend.tf.example`](backend.tf.example)):

```bash
cp terraform.tfvars.example terraform.tfvars
cp backend.tf.example backend.tf   # edit the bucket and KMS key
export TF_VAR_cloudsql_root_password="$(gcloud secrets versions access latest --secret=cloudsql-root-password)"
export TF_VAR_source_gce_mysql_password="$(gcloud secrets versions access latest --secret=dms-source-password)"
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

After Terraform creates the connection profiles and the migration job and demotes the destination, and after runbook section 5. Don't run `terraform apply` between `start` and `promote`: DMS changes the destination's backup and recovery settings (runbook section 6).

```bash
# Verify pre-flight connectivity and MySQL 8.0 replication configuration
gcloud database-migration migration-jobs verify gce-live-mysql80-cdc \
  --region=europe-west2

# Start the live initial dump + continuous CDC replication
gcloud database-migration migration-jobs start gce-live-mysql80-cdc \
  --region=europe-west2
```

### 5. Cutover / Promotion

Monitor replication lag with `make lag` (`max_replica_sec_lag`, with a fallback to the destination's `replica_lag` when `CLOUDSQL_INSTANCE` is set) or in Cloud Monitoring. When the lag is near `0` during the cutover window, stop writes on the source MySQL 8.0 instance, complete the Go / No-Go checklist and rollback decision (runbook section 8), and promote the Cloud SQL destination:

```bash
gcloud database-migration migration-jobs promote gce-live-mysql80-cdc \
  --region=europe-west2
```

Then point applications to the `psc_endpoint_dns_name` Terraform output, and run `terraform plan`/`apply` (runbook section 9.1). For teardown and decommission, see runbook section 10.

### 6. Retire the Migration Objects

After promotion, set `migration_enabled = false` and apply. Terraform deletes the DMS job, the connection profiles, the demote step, the Network Attachment and the source firewall rule; Cloud SQL, the PSC endpoint and DNS stay. Detaching the Network Attachment **restarts the instance**, so run it in a maintenance window (runbook section 10.2).

```bash
terraform plan -var migration_enabled=false -out=tfplan   # Review: Cloud SQL, endpoint and DNS are not destroyed
terraform apply tfplan
```
