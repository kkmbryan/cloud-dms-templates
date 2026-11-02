variable "project_id" {
  description = "The Google Cloud project ID where the staging GCS bucket will be created."
  type        = string
}

variable "region" {
  description = "The GCP region for the staging GCS bucket (must match the Cloud SQL destination and DMS job region)."
  type        = string
}

variable "bucket_name" {
  description = "Globally unique name for the GCS migration staging bucket."
  type        = string
}

variable "force_destroy" {
  description = "Whether to allow deleting the staging bucket even when it contains backup objects."
  type        = bool
  default     = false
}

variable "retention_days" {
  description = "Number of days to retain migration backup objects before automatic lifecycle deletion."
  type        = number
  default     = 14
}

variable "dms_service_account_email" {
  description = "Cloud DMS / Cloud SQL service agent email (e.g., 'service-PROJECT_NUMBER@gcp-sa-datamigration.iam.gserviceaccount.com') granted read access to the staging bucket."
  type        = string
  default     = ""
}

variable "backup_writer_members" {
  description = "List of IAM principals (e.g., ['serviceAccount:gce-mysql-backup@project.iam.gserviceaccount.com']) granted roles/storage.objectAdmin to upload Percona XtraBackup or mysqldump files."
  type        = list(string)
  default     = []
}

variable "kms_key_name" {
  description = "Optional Cloud KMS crypto key resource ID for Customer-Managed Encryption Keys (CMEK) on the staging bucket."
  type        = string
  default     = null
}

variable "labels" {
  description = "Key-value map of labels to attach to the GCS staging bucket."
  type        = map(string)
  default     = {}
}
