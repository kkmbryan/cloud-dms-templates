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
  default     = "gce-mysql80-to-cloudsql-cdc"
}

variable "display_name" {
  description = "Human-readable display name for the DMS migration job."
  type        = string
  default     = "GCE MySQL 80 to Cloud SQL Continuous CDC Migration"
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
  description = "Destination provisioning mode: EXISTING_CLOUDSQL (default, provisions a standalone Cloud SQL instance with Private Service Connect and PSC Outbound Network Attachment network_attachment_uri and demotes it for DMS replication) or DMS_MANAGED_CLOUDSQL."
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
  description = "GCS URI path (gs://<bucket>/<object>) to a pre-staged backup file in Cloud Storage for Scenario 2 (Backup in GCS + CDC). Leave null or empty for Scenario 1 (Live Migration + CDC). Mutually exclusive with dump_flags."
  type        = string
  default     = null
}

variable "dump_parallel_level" {
  description = "Parallelism level during DMS-managed initial dump (MIN, OPTIMAL, or MAX). Used when dump_path is null/empty."
  type        = string
  default     = "MAX"

  validation {
    condition     = contains(["MIN", "OPTIMAL", "MAX"], var.dump_parallel_level)
    error_message = "dump_parallel_level must be one of \"MIN\", \"OPTIMAL\", or \"MAX\"."
  }
}

variable "dump_flags" {
  description = "Optional list of custom dump flags (name/value pairs) for DMS-managed logical dumps. Ignored when dump_path is set (mutually exclusive in Google Provider schema)."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "connectivity_method" {
  description = "Network connectivity method used by the DMS migration job to reach the source GCE MySQL 8.0 VM: VPC_PEERING, REVERSE_SSH, or STATIC_IP."
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

variable "labels" {
  description = "Labels to apply to the DMS migration job."
  type        = map(string)
  default     = {}
}
