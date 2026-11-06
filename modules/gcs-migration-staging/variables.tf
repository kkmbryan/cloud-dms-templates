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

variable "reader_members" {
  description = "Map of static label => principal that gets read access (roles/storage.objectViewer + roles/storage.legacyBucketReader) on the bucket. Values can be a bare service account email or a full IAM member string (for example serviceAccount:..., group:...). Use static keys such as \"cloudsql_instance_sa\" and \"dms_service_agent\"."
  type        = map(string)
  default     = {}
}

variable "backup_writer_members" {
  description = "List of IAM principals (for example ['serviceAccount:mysql-backup@my-project.iam.gserviceaccount.com']) granted roles/storage.objectCreator to upload the Percona XtraBackup folder or mysqldump file."
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
