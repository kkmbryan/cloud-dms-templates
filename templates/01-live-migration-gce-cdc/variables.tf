variable "project_id" {
  description = "The GCP project ID where the Cloud SQL destination and Cloud DMS resources will be deployed."
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

# Cloud SQL Destination Configuration
variable "destination_mode" {
  description = "Destination provisioning mode: 'EXISTING_CLOUDSQL' (default: Terraform creates a PSC-only Cloud SQL instance with no public IP, attaches the Network Attachment, and demotes it for DMS) or 'DMS_MANAGED_CLOUDSQL' (DMS creates the instance from the cloudsql settings in the destination connection profile)."
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
  description = "Target Cloud SQL for MySQL version ('MYSQL_8_4' default or 'MYSQL_8_0'). This template supports MySQL 8.0 sources to 8.0 or 8.4 targets."
  type        = string
  default     = "MYSQL_8_4"

  validation {
    condition     = contains(["MYSQL_8_0", "MYSQL_8_4"], var.target_database_version)
    error_message = "target_database_version must be either \"MYSQL_8_0\" or \"MYSQL_8_4\"."
  }
}

variable "cloudsql_edition" {
  description = "Cloud SQL edition ('ENTERPRISE_PLUS' default, with Data Cache, or 'ENTERPRISE')."
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
  description = "Private IPv4 address or internal DNS hostname of the source GCE MySQL 8.0 VM."
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

# DMS Live Migration + CDC Job Configuration
variable "migration_job_id" {
  description = "Identifier for the live continuous DMS migration job."
  type        = string
  default     = "gce-live-mysql80-cdc"
}

variable "dump_parallel_level" {
  description = "Parallelism of the DMS-managed initial logical dump ('MIN', 'OPTIMAL' or 'MAX'). OPTIMAL is the DMS recommendation; MAX adds load on the source."
  type        = string
  default     = "OPTIMAL"

  validation {
    condition     = contains(["MIN", "OPTIMAL", "MAX"], var.dump_parallel_level)
    error_message = "dump_parallel_level must be one of \"MIN\", \"OPTIMAL\" or \"MAX\"."
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
  description = "Standard resource labels for Cloud DMS migration resources."
  type        = map(string)
  default = {
    environment = "production"
    workload    = "mysql-dms-migration"
    scenario    = "live-gce-cdc"
    managed_by  = "terraform"
  }
}
