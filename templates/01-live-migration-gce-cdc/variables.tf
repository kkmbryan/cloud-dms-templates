variable "project_id" {
  description = "The GCP project ID where the Cloud SQL destination and Cloud DMS resources will be deployed."
  type        = string
}

variable "region" {
  description = "The GCP region for the migration (e.g., asia-southeast1 or australia-southeast1)."
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
  default     = "cloudsql-mysql-dest-live-01"
}

variable "target_database_version" {
  description = "Target Cloud SQL for MySQL version ('MYSQL_8_4' default LTS or 'MYSQL_8_0'). Cloud DMS migrates from MySQL 8.0 to 8.0 or 8.4 (cannot skip directly to 9.7)."
  type        = string
  default     = "MYSQL_8_4"

  validation {
    condition     = contains(["MYSQL_8_0", "MYSQL_8_4"], var.target_database_version)
    error_message = "target_database_version must be either \"MYSQL_8_0\" or \"MYSQL_8_4\"."
  }
}

variable "cloudsql_edition" {
  description = "Cloud SQL edition ('ENTERPRISE_PLUS' default for sub-second near-zero downtime HA & Data Cache, or 'ENTERPRISE')."
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
  default     = 500
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
  description = "Private IPv4 address or internal DNS hostname of the source GCE MySQL 8.0 VM."
  type        = string
}

variable "source_gce_mysql_port" {
  description = "TCP port of the source GCE MySQL 8.0 instance."
  type        = number
  default     = 3306
}

variable "source_gce_mysql_username" {
  description = "Dedicated migration & replication username on the source GCE MySQL 8.0 instance."
  type        = string
  default     = "dms_repl_user"
}

variable "source_gce_mysql_password" {
  description = "Password for the source GCE MySQL 8.0 migration user."
  type        = string
  sensitive   = true
}

variable "destination_connection_host" {
  description = "Optional override for destination Cloud SQL host IP/DNS in the DMS connection profile (defaults to Cloud SQL private IP or PSC DNS name)."
  type        = string
  default     = ""
}

# DMS Live Migration + CDC Job Configuration
variable "migration_job_id" {
  description = "Identifier for the live continuous DMS migration job."
  type        = string
  default     = "gce-live-mysql80-cdc"
}

variable "dump_parallel_level" {
  description = "Parallelism level during the live initial logical dump ('MIN', 'OPTIMAL', or 'MAX')."
  type        = string
  default     = "MAX"
}

variable "connectivity_method" {
  description = "Connectivity method used by the DMS migration job to reach the source GCE MySQL 8.0 VM ('VPC_PEERING', 'REVERSE_SSH', or 'STATIC_IP')."
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
  description = "Standard resource labels for Cloud DMS migration resources."
  type        = map(string)
  default = {
    environment = "production"
    workload    = "mysql-dms-migration"
    scenario    = "live-gce-cdc"
    managed_by  = "terraform"
  }
}
