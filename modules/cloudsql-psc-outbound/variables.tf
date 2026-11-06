variable "enabled" {
  description = "Whether to attach the Network Attachment to the instance (plan-time boolean)."
  type        = bool
  default     = true
}

variable "project_id" {
  description = "Project of the Cloud SQL instance."
  type        = string
}

variable "instance_name" {
  description = "Name of the Cloud SQL instance (PSC enabled)."
  type        = string
}

variable "network_attachment_uri" {
  description = "Self-link or ID of the Compute Engine Network Attachment (PSC interface) to attach to the instance."
  type        = string
  default     = null
}

variable "operation_timeout_seconds" {
  description = "Maximum time in seconds to wait for each Cloud SQL patch operation (attach and detach)."
  type        = number
  default     = 1800
}

variable "impersonate_service_account" {
  description = "Optional service account that the gcloud steps impersonate (exported as CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT). Set it to the provider's impersonate_service_account so that Terraform and gcloud use the same identity."
  type        = string
  default     = null
}
