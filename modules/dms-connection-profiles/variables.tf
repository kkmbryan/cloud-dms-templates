variable "project_id" {
  description = "The GCP project ID where the DMS connection profiles will be created."
  type        = string
}

variable "region" {
  description = "The GCP region where the DMS connection profiles will reside."
  type        = string
}

variable "source_profile_id" {
  description = "The connection profile ID for the source GCE self-managed MySQL 8.0 database."
  type        = string
  default     = "gce-mysql80-src"
}

variable "source_display_name" {
  description = "Display name for the source GCE MySQL 8.0 connection profile."
  type        = string
  default     = "GCE MySQL 80 Source"
}

variable "source_host" {
  description = "Private IP address or hostname of the source GCE MySQL 8.0 instance."
  type        = string
}

variable "source_port" {
  description = "Network port of the source GCE MySQL 8.0 instance."
  type        = number
  default     = 3306
}

variable "source_username" {
  description = "Database replication/migration username on the source GCE MySQL 8.0 instance."
  type        = string
}

variable "source_password" {
  description = "Password of the migration user on the source MySQL instance (DMS limit: 32 characters or fewer)."
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.source_password) > 0 && length(var.source_password) <= 32
    error_message = "source_password must be 1-32 characters long (Database Migration Service limit)."
  }
}

variable "source_ssl_type" {
  description = "TLS mode from DMS to the source: REQUIRED (default: encrypted, server certificate not verified), SERVER_ONLY (verify the server certificate against source_ssl_ca_certificate), SERVER_CLIENT (also present a client certificate) or NONE (no TLS, not recommended)."
  type        = string
  default     = "REQUIRED"

  validation {
    condition     = contains(["NONE", "REQUIRED", "SERVER_ONLY", "SERVER_CLIENT"], var.source_ssl_type)
    error_message = "source_ssl_type must be NONE, REQUIRED, SERVER_ONLY or SERVER_CLIENT."
  }
}

variable "source_ssl_ca_certificate" {
  description = "x509 PEM-encoded CA certificate that signed the source MySQL server certificate (SERVER_ONLY and SERVER_CLIENT)."
  type        = string
  default     = null
}

variable "source_ssl_client_certificate" {
  description = "Optional x509 PEM-encoded client certificate used to authenticate to the source MySQL server."
  type        = string
  default     = null
}

variable "source_ssl_client_key" {
  description = "Optional unencrypted PKCS#1 or PKCS#8 PEM-encoded private key associated with the client certificate."
  type        = string
  default     = null
  sensitive   = true
}

variable "destination_profile_id" {
  description = "The connection profile ID for the destination Cloud SQL for MySQL database."
  type        = string
  default     = "cloudsql-mysql-dest"
}

variable "destination_display_name" {
  description = "Display name for the destination Cloud SQL for MySQL connection profile."
  type        = string
  default     = "Cloud SQL MySQL Destination"
}

variable "destination_mode" {
  description = "Destination provisioning mode: EXISTING_CLOUDSQL (recommended for pre-provisioned Cloud SQL with PSC and MYSQL_8_4/MYSQL_8_0) or DMS_MANAGED_CLOUDSQL."
  type        = string
  default     = "EXISTING_CLOUDSQL"

  validation {
    condition     = contains(["EXISTING_CLOUDSQL", "DMS_MANAGED_CLOUDSQL"], var.destination_mode)
    error_message = "destination_mode must be either \"EXISTING_CLOUDSQL\" or \"DMS_MANAGED_CLOUDSQL\"."
  }
}

variable "destination_cloud_sql_id" {
  description = "The Cloud SQL instance ID (name) of the existing destination when destination_mode is EXISTING_CLOUDSQL."
  type        = string
  default     = ""
}

variable "dest_database_version" {
  description = "Database version when destination_mode is DMS_MANAGED_CLOUDSQL (e.g., MYSQL_8_0 or MYSQL_8_4)."
  type        = string
  default     = "MYSQL_8_4"

  validation {
    condition     = contains(["MYSQL_8_0", "MYSQL_8_4"], var.dest_database_version)
    error_message = "dest_database_version must be either \"MYSQL_8_0\" or \"MYSQL_8_4\"."
  }
}

variable "dest_edition" {
  description = "Cloud SQL edition when destination_mode is DMS_MANAGED_CLOUDSQL (ENTERPRISE_PLUS or ENTERPRISE)."
  type        = string
  default     = "ENTERPRISE_PLUS"
}

variable "dest_tier" {
  description = "Cloud SQL machine tier when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = string
  default     = "db-perf-optimized-N-8"
}

variable "dest_disk_size_gb" {
  description = "Storage size in GB when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = number
  default     = 250
}

variable "dest_disk_type" {
  description = "Disk type when destination_mode is DMS_MANAGED_CLOUDSQL (PD_SSD or PD_HDD)."
  type        = string
  default     = "PD_SSD"
}

variable "dest_auto_storage_increase" {
  description = "Whether storage auto-increase is enabled when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = bool
  default     = true
}

variable "dest_zone" {
  description = "Primary GCP compute zone when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = string
  default     = ""
}

variable "dest_root_password" {
  description = "Root password when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = string
  default     = ""
  sensitive   = true
}

variable "dest_enable_ipv4" {
  description = "Whether public IPv4 is enabled when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = bool
  default     = false
}

variable "dest_private_network" {
  description = "VPC self_link for PSA connectivity when destination_mode is DMS_MANAGED_CLOUDSQL."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels to apply to the DMS connection profiles."
  type        = map(string)
  default     = {}
}
