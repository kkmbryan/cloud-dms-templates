resource "google_storage_bucket" "migration_staging" {
  project                     = var.project_id
  name                        = var.bucket_name
  location                    = var.region
  storage_class               = "STANDARD"
  force_destroy               = var.force_destroy
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  labels                      = var.labels

  versioning {
    enabled = true
  }

  dynamic "encryption" {
    for_each = var.kms_key_name != null && var.kms_key_name != "" ? [1] : []
    content {
      default_kms_key_name = var.kms_key_name
    }
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.retention_days
    }
  }
}

resource "google_storage_bucket_iam_member" "dms_object_viewer" {
  count = var.dms_service_account_email != "" ? 1 : 0

  bucket = google_storage_bucket.migration_staging.name
  role   = "roles/storage.objectViewer"
  member = startswith(var.dms_service_account_email, "serviceAccount:") ? var.dms_service_account_email : "serviceAccount:${var.dms_service_account_email}"
}

resource "google_storage_bucket_iam_member" "dms_legacy_bucket_reader" {
  count = var.dms_service_account_email != "" ? 1 : 0

  bucket = google_storage_bucket.migration_staging.name
  role   = "roles/storage.legacyBucketReader"
  member = startswith(var.dms_service_account_email, "serviceAccount:") ? var.dms_service_account_email : "serviceAccount:${var.dms_service_account_email}"
}

resource "google_storage_bucket_iam_member" "backup_writers" {
  for_each = toset(var.backup_writer_members)

  bucket = google_storage_bucket.migration_staging.name
  role   = "roles/storage.objectAdmin"
  member = each.value
}
