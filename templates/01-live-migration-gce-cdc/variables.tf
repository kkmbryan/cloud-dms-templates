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
  description = "Full path (projects/PROJECT/regions/REGION/subnetworks/SUBNET) or self-link of the regional subnetwork used by the PSC Network Attachment (required when connectivity_type = 'PSC')."
  type        = string
  default     = ""

  validation {
    condition     = var.subnet == "" || can(regex("^(https://www\\.googleapis\\.com/compute/v1/)?projects/[^/]+/regions/[^/]+/subnetworks/[^/]+$", var.subnet))
    error_message = "subnet must be empty or a full subnetwork path: projects/PROJECT/regions/REGION/subnetworks/SUBNET (optionally prefixed with https://www.googleapis.com/compute/v1/)."
  }
}

variable "network_attachment_name" {
  description = "Name of the PSC Network Attachment. Use a different name per stack when several migrations share a project and region."
  type        = string
  default     = "dms-mysql-psc-na"
}

variable "network_attachment_subnet" {
  description = "Optional dedicated subnet for the PSC Network Attachment, as a full path (projects/PROJECT/regions/REGION/subnetworks/SUBNET) or self-link, for example a /28 used only by the attachment. The firewall rule trusts this subnet's CIDR. Defaults to var.subnet when empty."
  type        = string
  default     = ""

  validation {
    condition     = var.network_attachment_subnet == "" || can(regex("^(https://www\\.googleapis\\.com/compute/v1/)?projects/[^/]+/regions/[^/]+/subnetworks/[^/]+$", var.network_attachment_subnet))
    error_message = "network_attachment_subnet must be empty or a full subnetwork path: projects/PROJECT/regions/REGION/subnetworks/SUBNET (optionally prefixed with https://www.googleapis.com/compute/v1/)."
  }
}

variable "psc_connection_preference" {
  description = "Network Attachment connection preference. ACCEPT_MANUAL (default) accepts only the Cloud SQL tenant project, derived from the instance's psc_service_attachment_link (or psc_producer_accept_list). ACCEPT_AUTOMATIC (opt-in) accepts any producer project that knows the attachment URI."
  type        = string
  default     = "ACCEPT_MANUAL"

  validation {
    condition     = contains(["ACCEPT_MANUAL", "ACCEPT_AUTOMATIC"], var.psc_connection_preference)
    error_message = "psc_connection_preference must be either \"ACCEPT_MANUAL\" or \"ACCEPT_AUTOMATIC\"."
  }
}

variable "psc_producer_accept_list" {
  description = "Optional override of the ACCEPT_MANUAL producer accept list (project IDs). Leave empty (recommended) to derive the Cloud SQL tenant project from the instance."
  type        = list(string)
  default     = []
}

variable "allowed_psc_consumer_projects" {
  description = "Additional application projects allowed to create PSC endpoints to the Cloud SQL instance. project_id (which hosts the endpoint created here) is always allowed. Applied when the instance is created."
  type        = list(string)
  default     = []
}

variable "create_source_firewall_rule" {
  description = "Create an INGRESS firewall rule (logging on) that allows tcp:source_gce_mysql_port from the Network Attachment subnet to the source VM. Set source_target_tags or source_target_service_accounts."
  type        = bool
  default     = true
}

variable "source_target_tags" {
  description = "Network tags of the source MySQL VM (firewall rule target). Set this or source_target_service_accounts."
  type        = list(string)
  default     = []
}

variable "source_target_service_accounts" {
  description = "Service account emails of the source MySQL VM (firewall rule target). Set this or source_target_tags."
  type        = list(string)
  default     = []
}

variable "source_firewall_rule_name" {
  description = "Name of the source firewall rule. Defaults to '<network_attachment_name>-to-source'."
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

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", var.cloudsql_instance_name))
    error_message = "cloudsql_instance_name must be 2-50 characters: lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen (the PSC endpoint resource names append up to 13 characters)."
  }
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

  validation {
    condition     = contains(["ENTERPRISE_PLUS", "ENTERPRISE"], var.cloudsql_edition)
    error_message = "cloudsql_edition must be \"ENTERPRISE_PLUS\" or \"ENTERPRISE\"."
  }
}

variable "cloudsql_tier" {
  description = "Machine tier for the destination Cloud SQL instance."
  type        = string
  default     = "db-perf-optimized-N-8"

  validation {
    condition     = !startswith(var.cloudsql_tier, "db-perf-optimized-N-") || var.cloudsql_edition == "ENTERPRISE_PLUS"
    error_message = "db-perf-optimized-N-* tiers are Enterprise Plus tiers: set cloudsql_edition = \"ENTERPRISE_PLUS\", or use an Enterprise tier such as db-custom-4-16384."
  }
}

variable "cloudsql_availability_type" {
  description = "Availability type for the destination Cloud SQL instance ('REGIONAL' for HA or 'ZONAL')."
  type        = string
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "ZONAL"], var.cloudsql_availability_type)
    error_message = "cloudsql_availability_type must be \"REGIONAL\" or \"ZONAL\"."
  }
}

variable "cloudsql_disk_size_gb" {
  description = "Initial storage size in GB for the destination Cloud SQL instance."
  type        = number
  default     = 500
}

variable "cloudsql_root_password" {
  description = "Initial root password for the destination Cloud SQL instance. Applied to root@'%' through the write-only password_wo argument of google_sql_user (EXISTING_CLOUDSQL), so it is not stored in Terraform state."
  type        = string
  sensitive   = true
}

variable "cloudsql_root_password_version" {
  description = "Version of the write-only Cloud SQL root password. Increment it to push a new cloudsql_root_password to the instance (the password is never stored in Terraform state)."
  type        = number
  default     = 1
}

variable "cloudsql_lower_case_table_names" {
  description = "Optional lower_case_table_names for the destination (0 or 1). IMMUTABLE after the instance is created. Set it to the source value (SELECT @@lower_case_table_names). Null keeps the Cloud SQL default (0)."
  type        = number
  default     = null
}

variable "cloudsql_deletion_protection" {
  description = "Whether deletion protection is enabled on the destination Cloud SQL instance."
  type        = bool
  default     = true
}

variable "cloudsql_transaction_log_retention_days" {
  description = "Days of binary logs kept for point-in-time recovery: 1-7 for ENTERPRISE, 1-35 for ENTERPRISE_PLUS."
  type        = number
  default     = 7

  validation {
    condition     = var.cloudsql_transaction_log_retention_days >= 1 && var.cloudsql_transaction_log_retention_days <= (var.cloudsql_edition == "ENTERPRISE_PLUS" ? 35 : 7)
    error_message = "cloudsql_transaction_log_retention_days must be 1-7 for ENTERPRISE and 1-35 for ENTERPRISE_PLUS."
  }
}

variable "cloudsql_retained_backups" {
  description = "Number of automated backups to keep (1-365)."
  type        = number
  default     = 30

  validation {
    condition     = var.cloudsql_retained_backups >= 1 && var.cloudsql_retained_backups <= 365
    error_message = "cloudsql_retained_backups must be between 1 and 365."
  }
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

  validation {
    condition     = length(var.source_gce_mysql_password) > 0 && length(var.source_gce_mysql_password) <= 32
    error_message = "source_gce_mysql_password must be 1-32 characters long (Database Migration Service limit)."
  }
}

# DMS Live Migration + CDC Job Configuration
variable "migration_job_id" {
  description = "Identifier for the live continuous DMS migration job."
  type        = string
  default     = "gce-live-mysql80-cdc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,54}[a-z0-9]$", var.migration_job_id))
    error_message = "migration_job_id must be 2-56 characters: lowercase letters, digits and hyphens, starting with a letter and not ending with a hyphen (the connection profile IDs append -src and -dest)."
  }
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

variable "migration_databases" {
  description = "Optional list of source databases to migrate (selective migration, like gcloud --databases-filter). Empty (default) = all user databases."
  type        = list(string)
  default     = []
}

variable "dump_flags" {
  description = "Optional mysqldump flags for the DMS-managed dump, as name/value pairs (for example [{ name = \"max-allowed-packet\", value = \"1G\" }])."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
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

# Source TLS (DMS -> source MySQL)
variable "source_ssl_type" {
  description = "TLS mode from DMS to the source: REQUIRED (default: encrypted, server certificate not verified), SERVER_ONLY (verify against source_ssl_ca_certificate), SERVER_CLIENT (also send a client certificate) or NONE (not recommended)."
  type        = string
  default     = "REQUIRED"

  validation {
    condition     = contains(["NONE", "REQUIRED", "SERVER_ONLY", "SERVER_CLIENT"], var.source_ssl_type)
    error_message = "source_ssl_type must be NONE, REQUIRED, SERVER_ONLY or SERVER_CLIENT."
  }
}

variable "source_ssl_ca_certificate" {
  description = "PEM CA certificate of the source MySQL server certificate (SERVER_ONLY, SERVER_CLIENT). For example TF_VAR_source_ssl_ca_certificate=\"$(cat ca.pem)\"."
  type        = string
  default     = null
}

variable "source_ssl_client_certificate" {
  description = "PEM client certificate for the migration user (SERVER_CLIENT)."
  type        = string
  default     = null
}

variable "source_ssl_client_key" {
  description = "PEM private key of the client certificate (SERVER_CLIENT). Stored in Terraform state; protect the backend."
  type        = string
  default     = null
  sensitive   = true
}

# Cloud SQL security options
variable "cloudsql_ssl_mode" {
  description = "Cloud SQL ssl_mode for client connections: ENCRYPTED_ONLY (default), ALLOW_UNENCRYPTED_AND_ENCRYPTED or TRUSTED_CLIENT_CERTIFICATE_REQUIRED."
  type        = string
  default     = "ENCRYPTED_ONLY"

  validation {
    condition     = contains(["ALLOW_UNENCRYPTED_AND_ENCRYPTED", "ENCRYPTED_ONLY", "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"], var.cloudsql_ssl_mode)
    error_message = "cloudsql_ssl_mode must be ALLOW_UNENCRYPTED_AND_ENCRYPTED, ENCRYPTED_ONLY or TRUSTED_CLIENT_CERTIFICATE_REQUIRED."
  }
}

variable "cloudsql_kms_key_name" {
  description = "Optional Cloud KMS key for CMEK on the Cloud SQL instance (projects/P/locations/REGION/keyRings/R/cryptoKeys/K, same region). Set at creation only. Grant the Cloud SQL service agent roles/cloudkms.cryptoKeyEncrypterDecrypter first. Also used for the DMS-created instance in DMS_MANAGED_CLOUDSQL mode (cloudsql.settings.cmek_key_name)."
  type        = string
  default     = null
}

variable "cloudsql_password_validation_policy" {
  description = "Optional Cloud SQL password validation policy for database users (null = off). Enable it after promotion (post-promotion apply): when it is set at creation, the API rejects the instance because the root password is applied afterwards (write-only google_sql_user). Example: { min_length = 14, complexity = \"COMPLEXITY_DEFAULT\", reuse_interval = 5, disallow_username_substring = true }. password_change_interval is not offered (PostgreSQL only)."
  type = object({
    min_length                  = optional(number, 12)
    complexity                  = optional(string, "COMPLEXITY_DEFAULT")
    reuse_interval              = optional(number, 5)
    disallow_username_substring = optional(bool, true)
  })
  default = null
}

# Lifecycle and identity
variable "migration_enabled" {
  description = "Set to false after cutover (promotion) to retire the migration objects: the DMS job, connection profiles, demote step, Network Attachment (cleared from the instance first, which RESTARTS it) and the source firewall rule. Cloud SQL, the PSC endpoint and DNS are kept. EXISTING_CLOUDSQL only."
  type        = bool
  default     = true

  validation {
    condition     = var.migration_enabled || var.destination_mode == "EXISTING_CLOUDSQL"
    error_message = "migration_enabled = false is supported only with destination_mode = \"EXISTING_CLOUDSQL\" (in DMS_MANAGED_CLOUDSQL mode the instance belongs to the DMS destination profile)."
  }
}

variable "impersonate_service_account" {
  description = "Optional deployer service account. The google provider impersonates it, and the gcloud local-exec steps get it as CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT, so both use the same identity. The destroy-time detach step keeps the value from its own state."
  type        = string
  default     = null
}
