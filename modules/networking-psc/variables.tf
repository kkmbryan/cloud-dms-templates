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

variable "dms_tenant_project_id" {
  description = "Optional Google-managed DMS/Cloud SQL tenant project ID (e.g., 'p123456-abcdef-tp') to add to the PSC Network Attachment producer_accept_lists."
  type        = string
  default     = ""
}

variable "psc_connection_preference" {
  description = "Connection preference for the PSC Network Attachment ('ACCEPT_MANUAL' or 'ACCEPT_AUTOMATIC'). When dms_tenant_project_id is known, 'ACCEPT_MANUAL' is enforced."
  type        = string
  default     = "ACCEPT_AUTOMATIC"
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
