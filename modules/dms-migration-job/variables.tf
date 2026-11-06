variable "project_id" {
  description = "The GCP project ID where the DMS migration job will be created."
  type        = string
}

variable "region" {
  description = "The GCP region where the DMS migration job will reside."
  type        = string
}

variable "migration_job_id" {
  description = "The unique identifier for the DMS migration job."
  type        = string
  default     = "gce-live-mysql80-cdc"
}

variable "display_name" {
  description = "Human-readable display name for the DMS migration job."
  type        = string
  default     = "GCE MySQL 80 to Cloud SQL Continuous CDC Migration"

  validation {
    condition     = !can(regex("[._()]", var.display_name))
    error_message = "display_name can't contain '.', '_', '(' or ')' (rejected by Database Migration Service)."
  }
}

variable "migration_type" {
  description = "The type of migration job: CONTINUOUS (initial dump/seed + ongoing Binlog CDC for near-zero downtime switchover) or ONE_TIME."
  type        = string
  default     = "CONTINUOUS"

  validation {
    condition     = contains(["CONTINUOUS", "ONE_TIME"], var.migration_type)
    error_message = "migration_type must be either \"CONTINUOUS\" or \"ONE_TIME\"."
  }
}

variable "source_connection_profile" {
  description = "The full resource name of the source DMS connection profile."
  type        = string
}

variable "destination_connection_profile" {
  description = "The full resource name or short ID of the destination DMS connection profile."
  type        = string
}

variable "destination_mode" {
  description = "Destination provisioning mode: EXISTING_CLOUDSQL (default: the job targets a Terraform-created, PSC-enabled Cloud SQL instance with a Network Attachment and demotes it before start) or DMS_MANAGED_CLOUDSQL (DMS creates the instance)."
  type        = string
  default     = "EXISTING_CLOUDSQL"

  validation {
    condition     = contains(["EXISTING_CLOUDSQL", "DMS_MANAGED_CLOUDSQL"], var.destination_mode)
    error_message = "destination_mode must be either \"EXISTING_CLOUDSQL\" or \"DMS_MANAGED_CLOUDSQL\"."
  }
}

variable "dump_type" {
  description = "The initial dump method: LOGICAL (mysqldump / parallel logical dump) or PHYSICAL (Percona XtraBackup)."
  type        = string
  default     = "LOGICAL"

  validation {
    condition     = contains(["LOGICAL", "PHYSICAL"], var.dump_type)
    error_message = "dump_type must be either \"LOGICAL\" or \"PHYSICAL\"."
  }
}

variable "dump_path" {
  description = "Scenario 2 only: GCS location of the pre-staged seed. LOGICAL: one mysqldump file (gs://<bucket>/<path>.sql.gz). PHYSICAL: the dedicated folder that holds a prepared Percona XtraBackup backup (gs://<bucket>/<folder>, no trailing slash). Leave null or empty for Scenario 1 (DMS-managed dump). Mutually exclusive with dump_flags."
  type        = string
  default     = null
}

variable "dump_parallel_level" {
  description = "Parallelism level during the DMS-managed initial dump (MIN, OPTIMAL, or MAX). Used only when dump_path is null or empty. OPTIMAL is the DMS recommendation; MAX adds load on the source."
  type        = string
  default     = "OPTIMAL"

  validation {
    condition     = contains(["MIN", "OPTIMAL", "MAX"], var.dump_parallel_level)
    error_message = "dump_parallel_level must be one of \"MIN\", \"OPTIMAL\", or \"MAX\"."
  }
}

variable "dump_flags" {
  description = "Optional list of custom dump flags (name/value pairs) for DMS-managed logical dumps. Rejected when dump_path is set (mutually exclusive in the provider schema)."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "databases" {
  description = "Optional list of source databases to migrate (selective migration, the API equivalent of gcloud --databases-filter). Empty = all databases. DMS-managed dump only (no dump_path)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for d in var.databases : can(regex("^[A-Za-z0-9_$-]{1,64}$", d))])
    error_message = "Each database name must be 1-64 characters of letters, digits, '_', '$' or '-'."
  }
}

variable "connectivity_method" {
  description = "DMS_MANAGED_CLOUDSQL only: connectivity method used by the migration job to reach the source (VPC_PEERING, REVERSE_SSH, or STATIC_IP). Ignored for EXISTING_CLOUDSQL, which uses the instance's PSC interface (Network Attachment)."
  type        = string
  default     = "VPC_PEERING"

  validation {
    condition     = contains(["VPC_PEERING", "REVERSE_SSH", "STATIC_IP"], var.connectivity_method)
    error_message = "connectivity_method must be one of \"VPC_PEERING\", \"REVERSE_SSH\", or \"STATIC_IP\"."
  }
}

variable "vpc_peering_network" {
  description = "The VPC network name or self_link when connectivity_method is VPC_PEERING."
  type        = string
  default     = ""
}

variable "reverse_ssh_vm_ip" {
  description = "Bastion/proxy VM IP address when connectivity_method is REVERSE_SSH."
  type        = string
  default     = ""
}

variable "reverse_ssh_vm_port" {
  description = "Bastion/proxy SSH port when connectivity_method is REVERSE_SSH."
  type        = number
  default     = 22
}

variable "reverse_ssh_vm" {
  description = "Bastion/proxy VM name when connectivity_method is REVERSE_SSH."
  type        = string
  default     = ""
}

variable "reverse_ssh_vpc" {
  description = "VPC network name for reverse SSH connectivity."
  type        = string
  default     = ""
}

variable "demote_destination" {
  description = "EXISTING_CLOUDSQL only: run `gcloud database-migration migration-jobs demote-destination` after the job is created."
  type        = bool
  default     = true
}

variable "demote_timeout_seconds" {
  description = "Maximum time in seconds to wait for the demote-destination operation before failing the apply."
  type        = number
  default     = 3600
}

variable "labels" {
  description = "Labels to apply to the DMS migration job."
  type        = map(string)
  default     = {}
}

variable "impersonate_service_account" {
  description = "Optional service account that the gcloud demote step impersonates (exported as CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT). Set it to the provider's impersonate_service_account."
  type        = string
  default     = null
}
