variable "project_id" {
  description = "The Google Cloud project ID for all resources."
  type        = string
}

variable "region" {
  description = "Region for the Cloud SQL instances, DMS resources, the shared Network Attachment and the PSC endpoints."
  type        = string
  default     = "europe-west2"
}

variable "network" {
  description = "Full path of the VPC that hosts the source MySQL VMs and the applications (projects/PROJECT/global/networks/NETWORK)."
  type        = string
}

variable "psc_endpoint_subnet" {
  description = "Full path of the subnet for the PSC endpoint IP addresses (projects/PROJECT/regions/REGION/subnetworks/SUBNET), normally the application subnet."
  type        = string

  validation {
    condition     = can(regex("^(https://www\\.googleapis\\.com/compute/v1/)?projects/[^/]+/regions/[^/]+/subnetworks/[^/]+$", var.psc_endpoint_subnet))
    error_message = "psc_endpoint_subnet must be a full subnetwork path: projects/PROJECT/regions/REGION/subnetworks/SUBNET."
  }
}

variable "network_attachment_subnet" {
  description = "Full path of the dedicated subnet for the shared Network Attachment. Each Cloud SQL instance takes one IP address in it; a /28 serves up to 11 instances."
  type        = string

  validation {
    condition     = can(regex("^(https://www\\.googleapis\\.com/compute/v1/)?projects/[^/]+/regions/[^/]+/subnetworks/[^/]+$", var.network_attachment_subnet))
    error_message = "network_attachment_subnet must be a full subnetwork path: projects/PROJECT/regions/REGION/subnetworks/SUBNET."
  }
}

variable "network_attachment_name" {
  description = "Name of the Network Attachment shared by all Cloud SQL instances of this stack."
  type        = string
  default     = "dms-multi-psc-na"
}

variable "psc_connection_preference" {
  description = "ACCEPT_MANUAL (default) accepts only the Cloud SQL tenant projects of the instances in this stack; ACCEPT_AUTOMATIC is opt-in."
  type        = string
  default     = "ACCEPT_MANUAL"

  validation {
    condition     = contains(["ACCEPT_MANUAL", "ACCEPT_AUTOMATIC"], var.psc_connection_preference)
    error_message = "psc_connection_preference must be either \"ACCEPT_MANUAL\" or \"ACCEPT_AUTOMATIC\"."
  }
}

variable "create_source_firewall_rule" {
  description = "Create one INGRESS rule (logging on) that allows source_port from the Network Attachment subnet to the source VMs."
  type        = bool
  default     = true
}

variable "source_port" {
  description = "TCP port of the source MySQL servers (used by the shared firewall rule)."
  type        = number
  default     = 3306
}

variable "source_target_tags" {
  description = "Network tags of the source MySQL VMs (firewall rule target). Set this or source_target_service_accounts."
  type        = list(string)
  default     = []
}

variable "source_target_service_accounts" {
  description = "Service accounts of the source MySQL VMs (firewall rule target). Set this or source_target_tags."
  type        = list(string)
  default     = []
}

variable "existing_dns_zone_name" {
  description = "Name of an existing private zone for <region>.sql.goog. bound to the network. Empty: the stack creates one zone and adds one record per instance."
  type        = string
  default     = ""
}

variable "migrations" {
  description = <<-EOT
    One entry per migration job, keyed by the DMS migration job ID. Each entry creates one Cloud SQL
    destination instance, one PSC endpoint + DNS record, two DMS connection profiles and one job.
    DMS supports one migration job per destination instance; to split one source server across
    instances, give each entry a different `databases` list (selective migration).
  EOT
  type = map(object({
    instance_name          = string
    source_host            = string
    source_port            = optional(number, 3306)
    source_username        = optional(string, "dms_migration")
    source_ssl_type        = optional(string, "REQUIRED")
    databases              = optional(list(string), [])
    database_version       = optional(string, "MYSQL_8_4")
    edition                = optional(string, "ENTERPRISE_PLUS")
    tier                   = optional(string, "db-perf-optimized-N-8")
    availability_type      = optional(string, "REGIONAL")
    disk_size_gb           = optional(number, 250)
    deletion_protection    = optional(bool, true)
    ssl_mode               = optional(string, "ENCRYPTED_ONLY")
    lower_case_table_names = optional(number)
    kms_key_name           = optional(string)
  }))

  validation {
    condition     = alltrue([for k, m in var.migrations : can(regex("^[a-z][a-z0-9-]{0,54}[a-z0-9]$", k))])
    error_message = "Each migrations key (the DMS job ID) must be 2-56 characters: lowercase letters, digits and hyphens, starting with a letter."
  }

  validation {
    condition     = alltrue([for k, m in var.migrations : can(regex("^[a-z][a-z0-9-]{0,48}[a-z0-9]$", m.instance_name))])
    error_message = "Each instance_name must be 2-50 characters: lowercase letters, digits and hyphens, starting with a letter."
  }

  validation {
    condition     = length(distinct([for k, m in var.migrations : m.instance_name])) == length(var.migrations)
    error_message = "Each migration needs its own instance_name: DMS supports one migration job per destination instance."
  }

  validation {
    condition     = alltrue([for k, m in var.migrations : !startswith(m.tier, "db-perf-optimized-N-") || m.edition == "ENTERPRISE_PLUS"])
    error_message = "db-perf-optimized-N-* tiers need edition = \"ENTERPRISE_PLUS\"."
  }
}

variable "source_passwords" {
  description = "Password of the source migration user per migrations key (32 characters or fewer). Pass it with TF_VAR_source_passwords='{\"job-a\":\"...\"}', for example from Secret Manager."
  type        = map(string)
  sensitive   = true
}

variable "cloudsql_root_passwords" {
  description = "Root password per migrations key, applied with the write-only password_wo argument (not stored in state)."
  type        = map(string)
  sensitive   = true
}

variable "migration_enabled" {
  description = "Set to false after all jobs are promoted to retire the DMS jobs, profiles, the shared Network Attachment (detached from every instance first; each instance restarts) and the firewall rule. Cloud SQL, PSC endpoints and DNS are kept."
  type        = bool
  default     = true
}

variable "impersonate_service_account" {
  description = "Optional deployer service account, used by the provider and by the gcloud local-exec steps."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels for the Cloud SQL instances, DMS resources and PSC endpoints."
  type        = map(string)
  default = {
    workload   = "mysql-dms-migration"
    scenario   = "multi-database"
    managed_by = "terraform"
  }
}
