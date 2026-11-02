variable "project_id" {
  description = "The GCP project ID where the Cloud SQL destination, GCS staging bucket, and Cloud DMS resources will be deployed."
  type        = string
}

variable "region" {
  description = "The GCP region for the migration (must match across GCS staging bucket, Cloud SQL, and Cloud DMS)."
  type        = string
  default     = "asia-southeast1"
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
  description = "Globally unique name for the GCS staging bucket holding the Percona XtraBackup or mysqldump backup file."
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

variable "dms_service_account_email" {
  description = "Cloud DMS / Cloud SQL service agent email granted read access to the staging bucket."
  type        = string
  default     = ""
}

variable "backup_writer_members" {
  description = "List of IAM principals (e.g., GCE VM service account) granted roles/storage.objectAdmin on the staging bucket."
  type        = list(string)
  default     = []
}

variable "backup_object_path" {
  description = "Object path inside the GCS staging bucket (e.g., 'backups/mysql80-full.xbstream.zst' for PHYSICAL XtraBackup or 'backups/mysql80-dump.sql.gz' for LOGICAL mysqldump)."
  type        = string
  default     = "backups/mysql80-full.xbstream"
}

# Cloud SQL Destination Configuration
variable "destination_mode" {
  description = "Destination provisioning mode: 'EXISTING_CLOUDSQL' (recommended default: provisions a standalone Cloud SQL instance with Private Service Connect, No Public IP, and PSC Outbound Network Attachment network_attachment_uri, and demotes it for DMS replication) or 'DMS_MANAGED_CLOUDSQL'."
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
  description = "Target Cloud SQL for MySQL version ('MYSQL_8_4' default LTS or 'MYSQL_8_0'). Note: For PHYSICAL XtraBackup imports, ensure source and destination minor/major compatibility per Cloud DMS guidelines."
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
  description = "Root password for the destination Cloud SQL instance."
  type        = string
  sensitive   = true
}

variable "cloudsql_deletion_protection" {
  description = "Whether deletion protection is enabled on the destination Cloud SQL instance."
  type        = bool
  default     = true
}

# Source GCE MySQL 8.0 Connection Profile Configuration
variable "source_gce_mysql_host" {
  description = "Private IPv4 address or internal DNS hostname of the source GCE MySQL 8.0 VM (used for ongoing Binlog CDC after GCS backup restore)."
  type        = string
}

variable "source_gce_mysql_port" {
  description = "TCP port of the source GCE MySQL 8.0 instance."
  type        = number
  default     = 3306
}

variable "source_gce_mysql_username" {
  description = "Dedicated replication username on the source GCE MySQL 8.0 instance."
  type        = string
  default     = "dms_repl_user"
}

variable "source_gce_mysql_password" {
  description = "Password for the source GCE MySQL 8.0 replication user."
  type        = string
  sensitive   = true
}

variable "destination_connection_host" {
  description = "Optional override for destination Cloud SQL host IP/DNS in the DMS connection profile."
  type        = string
  default     = ""
}

# DMS Backup-Seeded Migration + CDC Job Configuration
variable "migration_job_id" {
  description = "Identifier for the backup-seeded continuous DMS migration job."
  type        = string
  default     = "gcs-bkp-mysql80-cdc"
}

variable "dump_type" {
  description = "Backup format staged in GCS: 'PHYSICAL' (default for Percona XtraBackup non-blocking multi-TB backups) or 'LOGICAL' (mysqldump)."
  type        = string
  default     = "PHYSICAL"

  validation {
    condition     = contains(["PHYSICAL", "LOGICAL"], var.dump_type)
    error_message = "dump_type must be either \"PHYSICAL\" (Percona XtraBackup) or \"LOGICAL\" (mysqldump)."
  }
}

variable "connectivity_method" {
  description = "Connectivity method used by the DMS migration job to reach the source GCE MySQL 8.0 VM for CDC ('VPC_PEERING', 'REVERSE_SSH', or 'STATIC_IP')."
  type        = string
  default     = "VPC_PEERING"
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
