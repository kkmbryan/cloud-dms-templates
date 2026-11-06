variable "project_id" {
  description = "The GCP project ID where the Cloud SQL destination, GCS staging bucket, and Cloud DMS resources will be deployed."
  type        = string
}

variable "region" {
  description = "The GCP region for the migration. The Cloud SQL instance, DMS resources and (Scenario 2) the staging bucket must all be in this region."
  type        = string
  default     = "europe-west2"
}

variable "connectivity_type" {
  description = "Network connectivity architecture for Cloud SQL and DMS ('PSC' recommended default or 'PSA')."
  type        = string
  default     = "PSC"

  validation {
    condition     = contains(["PSC", "PSA"], var.connectivity_type)
    error_message = "connectivity_type must be either \"PSC\" or \"PSA\"."
  }
}

variable "network" {
  description = "Self-link or ID of the VPC network hosting the GCE MySQL 8.0 source instance."
  type        = string
}

variable "subnet" {
  description = "Self-link or URI of the regional subnetwork used by the PSC Network Attachment (required when connectivity_type = 'PSC')."
  type        = string
  default     = ""
}

variable "dms_tenant_project_id" {
  description = "Optional Google-managed DMS/Cloud SQL tenant project ID (e.g., 'p123456-abcdef-tp') to add to the PSC Network Attachment producer_accept_lists."
  type        = string
  default     = ""
}

variable "create_psa_peering" {
  description = "Whether to create a new global IP allocation and Service Networking VPC peering when connectivity_type is 'PSA'."
  type        = bool
  default     = false
}

# GCS Staging Bucket Configuration (Scenario 2 Backup Seed)
variable "staging_bucket_name" {
  description = "Globally unique name for the GCS staging bucket that holds the mysqldump file or the prepared Percona XtraBackup folder."
  type        = string
}

variable "staging_bucket_force_destroy" {
  description = "Whether to allow deleting the staging bucket even when it contains backup objects."
  type        = bool
  default     = false
}

variable "staging_bucket_retention_days" {
  description = "Number of days to retain migration backup objects in the GCS staging bucket before lifecycle cleanup."
  type        = number
  default     = 14
}

variable "additional_bucket_reader_members" {
  description = "Optional extra principals (full IAM member strings, for example 'group:dba-team@example.com') that get read access to the staging bucket. The Cloud SQL instance service account and the DMS service agent are granted automatically."
  type        = list(string)
  default     = []
}

variable "backup_writer_members" {
  description = "IAM principals (for example the source VM's service account) granted roles/storage.objectCreator on the staging bucket to upload the seed."
  type        = list(string)
  default     = []
}

variable "backup_gcs_path" {
  description = <<-EOT
    Path of the seed inside the staging bucket, without 'gs://<bucket>/' and without a trailing slash.
    - dump_type = "LOGICAL": one mysqldump file, for example 'mysqldump/mysql80-dump.sql.gz'.
    - dump_type = "PHYSICAL": a dedicated folder that contains only the prepared Percona XtraBackup files, for example 'xtrabackup/mysql80-full'.
    The DMS dump_path is gs://<staging_bucket_name>/<backup_gcs_path> (see the configured_dump_path output).
  EOT
  type        = string
  default     = "mysqldump/mysql80-dump.sql.gz"

  validation {
    condition     = length(var.backup_gcs_path) > 0 && !startswith(var.backup_gcs_path, "gs://") && !startswith(var.backup_gcs_path, "/") && !endswith(var.backup_gcs_path, "/")
    error_message = "backup_gcs_path must be a path inside the bucket, with no 'gs://' prefix and no leading or trailing slash."
  }

  validation {
    condition     = var.dump_type != "PHYSICAL" || !can(regex("\\.(sql|gz|zst|xbstream)$", var.backup_gcs_path))
    error_message = "With dump_type = \"PHYSICAL\", backup_gcs_path must be a dedicated folder that holds the prepared XtraBackup files, not a single file."
  }
}

# Cloud SQL Destination Configuration
variable "destination_mode" {
  description = "Destination provisioning mode: 'EXISTING_CLOUDSQL' (default: Terraform creates a PSC-only Cloud SQL instance with no public IP, attaches the Network Attachment, grants it bucket read access, and demotes it for DMS) or 'DMS_MANAGED_CLOUDSQL' (DMS creates the instance; you must then grant its service account read access to the bucket yourself)."
  type        = string
  default     = "EXISTING_CLOUDSQL"

  validation {
    condition     = contains(["DMS_MANAGED_CLOUDSQL", "EXISTING_CLOUDSQL"], var.destination_mode)
    error_message = "destination_mode must be either \"DMS_MANAGED_CLOUDSQL\" or \"EXISTING_CLOUDSQL\"."
  }
}

variable "cloudsql_zone" {
  description = "Primary GCP compute zone for the destination Cloud SQL instance when destination_mode is DMS_MANAGED_CLOUDSQL (defaults to '<region>-a' if empty)."
  type        = string
  default     = ""
}

variable "cloudsql_instance_name" {
  description = "Name of the destination Cloud SQL for MySQL instance."
  type        = string
  default     = "cloudsql-mysql-dest-bkp-01"
}

variable "target_database_version" {
  description = "Target Cloud SQL for MySQL version ('MYSQL_8_4' default or 'MYSQL_8_0'). dump_type = 'PHYSICAL' (Percona XtraBackup) supports only 'MYSQL_8_0'."
  type        = string
  default     = "MYSQL_8_4"

  validation {
    condition     = contains(["MYSQL_8_0", "MYSQL_8_4"], var.target_database_version)
    error_message = "target_database_version must be either \"MYSQL_8_0\" or \"MYSQL_8_4\"."
  }
}

variable "cloudsql_edition" {
  description = "Cloud SQL edition ('ENTERPRISE_PLUS' default or 'ENTERPRISE')."
  type        = string
  default     = "ENTERPRISE_PLUS"
}

variable "cloudsql_tier" {
  description = "Machine tier for the destination Cloud SQL instance."
  type        = string
  default     = "db-perf-optimized-N-8"
}

variable "cloudsql_availability_type" {
  description = "Availability type for the destination Cloud SQL instance ('REGIONAL' for HA or 'ZONAL')."
  type        = string
  default     = "REGIONAL"
}

variable "cloudsql_disk_size_gb" {
  description = "Initial storage size in GB for the destination Cloud SQL instance."
  type        = number
  default     = 1000
}

variable "cloudsql_root_password" {
  description = "Initial root password for the destination Cloud SQL instance. Sent through the write-only root_password_wo argument (EXISTING_CLOUDSQL), so it is not stored in Terraform state."
  type        = string
  sensitive   = true
}

variable "cloudsql_root_password_version" {
  description = "Version of the write-only Cloud SQL root password. Increment it to push a new cloudsql_root_password to the instance (the password is never stored in Terraform state)."
  type        = number
  default     = 1
}

variable "cloudsql_deletion_protection" {
  description = "Whether deletion protection is enabled on the destination Cloud SQL instance."
  type        = bool
  default     = true
}

# PSC consumer endpoint + private DNS (application access after promotion)
variable "create_psc_endpoint" {
  description = "Create a PSC consumer endpoint (internal IP + forwarding rule) and a private DNS record for the Cloud SQL instance in var.network. Applies when destination_mode = EXISTING_CLOUDSQL and connectivity_type = PSC."
  type        = bool
  default     = true
}

variable "psc_endpoint_subnet" {
  description = "Subnet (self-link or ID) for the PSC endpoint IP address, normally the application subnet. Defaults to var.subnet when empty."
  type        = string
  default     = ""
}

variable "psc_endpoint_ip_address" {
  description = "Optional fixed internal IP address for the PSC endpoint. Leave empty to let Google Cloud choose one."
  type        = string
  default     = ""
}

variable "psc_endpoint_global_access" {
  description = "Allow clients in other regions to use the PSC endpoint."
  type        = bool
  default     = false
}

variable "create_psc_dns_record" {
  description = "Create an A record for the instance DNS name (cloudsql_dns_name) that points to the PSC endpoint IP."
  type        = bool
  default     = true
}

variable "psc_existing_dns_zone_name" {
  description = "Name of an existing private Cloud DNS zone for '<region>.sql.goog.' bound to var.network. When empty, a new private zone is created. Set this if the VPC already has such a zone (for example for other Cloud SQL PSC instances)."
  type        = string
  default     = ""
}

# Source GCE MySQL 8.0 Connection Profile Configuration
variable "source_gce_mysql_host" {
  description = "Private IPv4 address or internal DNS hostname of the source MySQL 8.0 VM (used for binlog CDC after the seed is restored)."
  type        = string
}

variable "source_gce_mysql_port" {
  description = "TCP port of the source GCE MySQL 8.0 instance."
  type        = number
  default     = 3306
}

variable "source_gce_mysql_username" {
  description = "Dedicated DMS migration user on the source MySQL 8.0 instance (created as 'dms_migration'@'%'; see the runbook for grants)."
  type        = string
  default     = "dms_migration"
}

variable "source_gce_mysql_password" {
  description = "Password of the source migration user (32 characters or fewer)."
  type        = string
  sensitive   = true
}

# DMS Backup-Seeded Migration + CDC Job Configuration
variable "migration_job_id" {
  description = "Identifier for the backup-seeded continuous DMS migration job."
  type        = string
  default     = "gcs-bkp-mysql80-cdc"
}

variable "dump_type" {
  description = "Seed format staged in GCS: 'LOGICAL' (default, mysqldump file; works for MYSQL_8_0 and MYSQL_8_4 targets) or 'PHYSICAL' (prepared Percona XtraBackup folder; MYSQL_8_0 target only)."
  type        = string
  default     = "LOGICAL"

  validation {
    condition     = contains(["PHYSICAL", "LOGICAL"], var.dump_type)
    error_message = "dump_type must be either \"LOGICAL\" (mysqldump) or \"PHYSICAL\" (Percona XtraBackup)."
  }

  validation {
    condition     = var.dump_type != "PHYSICAL" || var.target_database_version == "MYSQL_8_0"
    error_message = "dump_type = \"PHYSICAL\" requires target_database_version = \"MYSQL_8_0\". Database Migration Service does not support physical (XtraBackup) migrations to MySQL 8.4. Use dump_type = \"LOGICAL\" for an 8.4 target."
  }
}

variable "connectivity_method" {
  description = "DMS_MANAGED_CLOUDSQL only: connectivity method for the migration job ('VPC_PEERING', 'REVERSE_SSH' or 'STATIC_IP'). Ignored for EXISTING_CLOUDSQL, which uses the PSC interface."
  type        = string
  default     = "VPC_PEERING"

  validation {
    condition     = contains(["VPC_PEERING", "REVERSE_SSH", "STATIC_IP"], var.connectivity_method)
    error_message = "connectivity_method must be one of \"VPC_PEERING\", \"REVERSE_SSH\" or \"STATIC_IP\"."
  }
}

variable "reverse_ssh_vm_ip" {
  description = "Bastion VM IP address if connectivity_method is REVERSE_SSH."
  type        = string
  default     = ""
}

variable "reverse_ssh_vm" {
  description = "Bastion VM resource name if connectivity_method is REVERSE_SSH."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Standard resource labels for Cloud DMS Backup + CDC migration resources."
  type        = map(string)
  default = {
    environment = "production"
    workload    = "mysql-dms-migration"
    scenario    = "backup-gcs-cdc"
    managed_by  = "terraform"
  }
}
