output "bucket_name" {
  description = "Name of the GCS migration staging bucket."
  value       = google_storage_bucket.migration_staging.name
}

output "bucket_url" {
  description = "GCS URI (gs://<bucket_name>) of the migration staging bucket."
  value       = "gs://${google_storage_bucket.migration_staging.name}"
}

output "bucket_self_link" {
  description = "The URI of the created GCS bucket resource."
  value       = google_storage_bucket.migration_staging.self_link
}
