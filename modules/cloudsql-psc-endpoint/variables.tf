variable "enabled" {
  description = "Whether to create the PSC consumer endpoint (reserved internal IP + forwarding rule) and the DNS record."
  type        = bool
  default     = true
}

variable "project_id" {
  description = "The Google Cloud project ID where the PSC endpoint and DNS resources are created. It must be listed in the instance's allowed_consumer_projects."
  type        = string
}

variable "region" {
  description = "The region of the Cloud SQL instance. The PSC endpoint must be in the same region as the service attachment."
  type        = string
}

variable "name" {
  description = "Name prefix for the endpoint resources (normally the Cloud SQL instance name)."
  type        = string
}

variable "network" {
  description = "Self-link or ID of the consumer VPC network where applications connect from (projects/PROJECT/global/networks/NETWORK)."
  type        = string
}

variable "subnetwork" {
  description = "Self-link or ID of the consumer subnet in which the endpoint's internal IP address is reserved."
  type        = string
  default     = ""

  validation {
    condition     = !var.enabled || (var.subnetwork != null && var.subnetwork != "")
    error_message = "subnetwork must be set to the subnet that hosts the PSC endpoint IP address."
  }
}

variable "ip_address" {
  description = "Optional internal IP address to reserve for the endpoint. Leave empty to let Google Cloud pick a free address in the subnet."
  type        = string
  default     = ""
}

variable "service_attachment_link" {
  description = "The Cloud SQL instance's psc_service_attachment_link."
  type        = string
}

variable "instance_dns_name" {
  description = "The Cloud SQL instance's dns_name (for example <uid>.<label>.<region>.sql.goog.)."
  type        = string
}

variable "allow_psc_global_access" {
  description = "Whether clients in other regions can use the endpoint."
  type        = bool
  default     = false
}

variable "create_dns_record" {
  description = "Whether to create an A record for the instance DNS name that points to the endpoint IP."
  type        = bool
  default     = true
}

variable "existing_dns_zone_name" {
  description = "Name of an existing private Cloud DNS zone for <region>.sql.goog. bound to the network. When set, the module adds the record to it instead of creating a new zone."
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Name of the private Cloud DNS zone to create when existing_dns_zone_name is empty. Defaults to '<name>-sql-goog'."
  type        = string
  default     = ""
}

variable "dns_record_ttl" {
  description = "TTL in seconds of the instance A record."
  type        = number
  default     = 300
}

variable "labels" {
  description = "Labels applied to the address, forwarding rule and DNS zone."
  type        = map(string)
  default     = {}
}
