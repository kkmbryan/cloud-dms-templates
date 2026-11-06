variable "project_id" {
  description = "The Google Cloud project ID where networking resources will be provisioned."
  type        = string
}

variable "region" {
  description = "The GCP region for the Private Service Connect Network Attachment."
  type        = string
}

variable "connectivity_type" {
  description = "Network connectivity architecture for Cloud SQL and Cloud DMS ('PSC' recommended default or 'PSA')."
  type        = string
  default     = "PSC"

  validation {
    condition     = contains(["PSC", "PSA"], var.connectivity_type)
    error_message = "connectivity_type must be either 'PSC' (Private Service Connect) or 'PSA' (Private Services Access)."
  }
}

variable "network" {
  description = "Self-link or ID of the VPC network hosting the GCE MySQL source and/or PSA peering."
  type        = string
}

variable "subnet" {
  description = "Self-link or URI of the regional subnetwork used by the PSC Network Attachment (required when connectivity_type = 'PSC')."
  type        = string
  default     = ""
}

variable "network_attachment_name" {
  description = "Name of the Compute Engine Network Attachment for PSC interface connectivity."
  type        = string
  default     = "dms-mysql-psc-na"
}

variable "network_attachment_subnet" {
  description = "Optional dedicated subnet (self-link or ID) for the PSC Network Attachment. Recommended: a small subnet (for example a /28) used only by the attachment, so the firewall rule can trust exactly that range. Defaults to var.subnet when empty."
  type        = string
  default     = ""
}

variable "create_network_attachment" {
  description = "Whether to create the Network Attachment (and the source firewall rule) when connectivity_type = 'PSC'. The templates set it to false for DMS_MANAGED_CLOUDSQL and when migration_enabled = false."
  type        = bool
  default     = true
}

variable "psc_connection_preference" {
  description = "Connection preference for the PSC Network Attachment. ACCEPT_MANUAL (default) accepts only the producer projects in the accept list (by default the Cloud SQL tenant project derived from cloudsql_psc_service_attachment_link). ACCEPT_AUTOMATIC accepts a PSC interface from any project that knows the attachment URI."
  type        = string
  default     = "ACCEPT_MANUAL"

  validation {
    condition     = contains(["ACCEPT_MANUAL", "ACCEPT_AUTOMATIC"], var.psc_connection_preference)
    error_message = "psc_connection_preference must be either \"ACCEPT_MANUAL\" or \"ACCEPT_AUTOMATIC\"."
  }
}

variable "cloudsql_psc_service_attachment_link" {
  description = "The Cloud SQL instance's psc_service_attachment_link. Its project segment (the Cloud SQL tenant project) becomes the ACCEPT_MANUAL producer accept list."
  type        = string
  default     = null
}

variable "producer_accept_list" {
  description = "Optional override of the ACCEPT_MANUAL producer accept list (project IDs). Leave empty to derive it from cloudsql_psc_service_attachment_link."
  type        = list(string)
  default     = []
}

variable "create_source_firewall_rule" {
  description = "Create an INGRESS firewall rule that allows tcp:source_port from the Network Attachment subnet CIDR to the source VM (source_target_tags or source_target_service_accounts), with logging on."
  type        = bool
  default     = true
}

variable "source_firewall_rule_name" {
  description = "Name of the source firewall rule. Defaults to '<network_attachment_name>-to-source'."
  type        = string
  default     = ""
}

variable "source_firewall_priority" {
  description = "Priority of the source firewall rule."
  type        = number
  default     = 1000
}

variable "source_port" {
  description = "TCP port of the source MySQL server."
  type        = number
  default     = 3306
}

variable "source_target_tags" {
  description = "Network tags of the source MySQL VM, used as the firewall rule target. Set this or source_target_service_accounts."
  type        = list(string)
  default     = []
}

variable "source_target_service_accounts" {
  description = "Service account emails of the source MySQL VM, used as the firewall rule target. Set this or source_target_tags."
  type        = list(string)
  default     = []
}

variable "psa_allocated_ip_range_name" {
  description = "Name of the allocated global internal IP range for Private Services Access (PSA)."
  type        = string
  default     = "google-managed-services-sql"
}

variable "psa_prefix_length" {
  description = "Prefix length of the allocated global IP range for PSA (e.g., 16 for /16)."
  type        = number
  default     = 16
}

variable "create_psa_peering" {
  description = "Whether to create a new global IP allocation and Service Networking VPC peering when connectivity_type is 'PSA'."
  type        = bool
  default     = false
}

variable "peering_vpc_self_link" {
  description = "Existing peered VPC network self-link when connectivity_type is 'PSA' and create_psa_peering is false."
  type        = string
  default     = ""
}

variable "labels" {
  description = "Key-value map of resource labels to apply to supported networking resources."
  type        = map(string)
  default     = {}
}
