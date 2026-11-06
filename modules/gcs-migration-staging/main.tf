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

# Writers only need to create objects (upload the dump). They can't delete or
# overwrite existing backup objects.
resource "google_storage_bucket_iam_member" "backup_writers" {
  for_each = toset(var.backup_writer_members)

  bucket = google_storage_bucket.migration_staging.name
  role   = "roles/storage.objectCreator"
  member = each.value
}
