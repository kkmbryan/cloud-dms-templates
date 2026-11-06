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

  # Delete seed objects retention_days after upload.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = var.retention_days
    }
  }

  # Versioning keeps a noncurrent copy of every overwritten or deleted object
  # (including the seed after `gcloud storage rm`). Delete those copies too.
  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      days_since_noncurrent_time = var.noncurrent_version_retention_days
      with_state                 = "ARCHIVED"
    }
  }
}

locals {
  # DMS and the destination Cloud SQL instance service account both need to
  # list the bucket and read the seed objects.
  # Reference: https://cloud.google.com/database-migration/docs/mysql/migrate-with-physical-xtrabackup
  reader_roles = ["roles/storage.objectViewer", "roles/storage.legacyBucketReader"]

  # Keys are static labels so that for_each works even when a member email is
  # only known after apply (for example the Cloud SQL instance service account).
  reader_bindings = {
    for pair in setproduct(keys(var.reader_members), local.reader_roles) :
    "${pair[0]}/${pair[1]}" => {
      # A bare email is treated as a service account; anything with a type
      # prefix (serviceAccount:, group:, user:, ...) is used as is.
      member = strcontains(var.reader_members[pair[0]], ":") ? var.reader_members[pair[0]] : "serviceAccount:${var.reader_members[pair[0]]}"
      role   = pair[1]
    }
  }
}

resource "google_storage_bucket_iam_member" "readers" {
  for_each = local.reader_bindings

  bucket = google_storage_bucket.migration_staging.name
  role   = each.value.role
  member = each.value.member
}

# Writers upload the seed. `gcloud storage cp` also reads object metadata
# (storage.objects.get) and the helper script lists the folder, so writers get
# objectCreator + objectViewer. Neither role can delete or overwrite objects.
resource "google_storage_bucket_iam_member" "backup_writers" {
  for_each = {
    for pair in setproduct(var.backup_writer_members, ["roles/storage.objectCreator", "roles/storage.objectViewer"]) :
    "${pair[0]}/${pair[1]}" => { member = pair[0], role = pair[1] }
  }

  bucket = google_storage_bucket.migration_staging.name
  role   = each.value.role
  member = each.value.member
}
