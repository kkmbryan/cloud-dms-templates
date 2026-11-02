variable "enabled" {
  description = "Whether to provision this standalone Cloud SQL destination instance (set to false when destination_mode = 'DMS_MANAGED_CLOUDSQL')."
  type        = bool
  default     = true
}

variable "project_id" {
  description = "The GCP project ID where the Cloud SQL for MySQL destination instance will be created."
  type        = string
}

variable "region" {
  description = "The GCP region for the Cloud SQL destination instance."
  type        = string
}

variable "instance_name" {
  description = "The name of the Cloud SQL for MySQL destination instance."
  type        = string
}

variable "database_version" {
  description = "The MySQL database version for the destination instance. Cloud DMS supports homogeneous MySQL 8.0 -> 8.0 or 8.0 -> 8.4 LTS migrations (cannot skip major versions directly from 8.0 to 9.7)."
  type        = string
  default     = "MYSQL_8_4"

  validation {
    condition     = contains(["MYSQL_8_0", "MYSQL_8_4"], var.database_version)
    error_message = "database_version must be either \"MYSQL_8_0\" or \"MYSQL_8_4\". Cloud DMS does not support skipping major versions directly from MySQL 8.0 to 9.x."
  }
}

variable "edition" {
  description = "The edition of the Cloud SQL instance (ENTERPRISE_PLUS or ENTERPRISE)."
  type        = string
  default     = "ENTERPRISE_PLUS"

  validation {
    condition     = contains(["ENTERPRISE_PLUS", "ENTERPRISE"], var.edition)
    error_message = "edition must be either \"ENTERPRISE_PLUS\" or \"ENTERPRISE\"."
  }
}

variable "tier" {
  description = "The machine type (tier) for the Cloud SQL instance."
  type        = string
  default     = "db-perf-optimized-N-8"
}

variable "availability_type" {
  description = "The availability type of the Cloud SQL instance (REGIONAL for HA or ZONAL)."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.availability_type)
    error_message = "availability_type must be either \"REGIONAL\" or \"ZONAL\"."
  }
}

variable "connectivity_type" {
  description = "Network connectivity architecture for the Cloud SQL instance (PSC or PSA)."
  type        = string
  default     = "PSC"

  validation {
    condition     = contains(["PSC", "PSA"], var.connectivity_type)
    error_message = "connectivity_type must be either \"PSC\" or \"PSA\"."
  }
}

variable "allowed_psc_projects" {
  description = "List of consumer project IDs allowed to connect to this Cloud SQL instance via Private Service Connect (PSC)."
  type        = list(string)
  default     = []
}

variable "psc_network_attachment_uri" {
  description = "The URI of the Compute Engine Network Attachment (PSCI) used by the Cloud SQL instance for Private Service Connect outbound connections to the source VPC."
  type        = string
  default     = null
}

variable "private_network" {
  description = "The VPC self_link or ID used for Private Services Access (PSA) when connectivity_type is PSA."
  type        = string
  default     = null
}

variable "enable_ipv4" {
  description = "Whether this Cloud SQL instance should be assigned a public IPv4 address."
  type        = bool
  default     = false
}

variable "disk_size_gb" {
  description = "Initial storage size in GB."
  type        = number
  default     = 250
}

variable "disk_type" {
  description = "Disk type for the Cloud SQL instance (PD_SSD or PD_HDD)."
  type        = string
  default     = "PD_SSD"
}

variable "disk_autoresize" {
  description = "Whether storage size should be automatically increased when needed."
  type        = bool
  default     = true
}

variable "disk_autoresize_limit" {
  description = "Maximum storage size in GB to which storage can be auto-increased (0 means no limit)."
  type        = number
  default     = 0
}

variable "data_cache_enabled" {
  description = "Whether local SSD data cache is enabled (applicable when edition is ENTERPRISE_PLUS)."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Whether Terraform and GCP deletion protection is enabled for the Cloud SQL instance."
  type        = bool
  default     = true
}

variable "root_password" {
  description = "Initial root password for the Cloud SQL instance."
  type        = string
  default     = null
  sensitive   = true
}

variable "database_flags" {
  description = "Additional MySQL database flags to apply to the Cloud SQL instance."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "backup_enabled" {
  description = "Whether automated backups are enabled."
  type        = bool
  default     = true
}

variable "binary_log_enabled" {
  description = "Whether binary logging is enabled (required for HA, PITR, and downstream replication)."
  type        = bool
  default     = true
}

variable "point_in_time_recovery_enabled" {
  description = "Whether Point-in-Time Recovery (PITR) is enabled."
  type        = bool
  default     = true
}

variable "transaction_log_retention_days" {
  description = "Number of days to retain binary transaction logs for PITR (1 to 7)."
  type        = number
  default     = 7
}

variable "retained_backups" {
  description = "Number of automated backups to retain."
  type        = number
  default     = 30
}

variable "labels" {
  description = "User labels to apply to the Cloud SQL instance."
  type        = map(string)
  default     = {}
}
