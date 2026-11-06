output "migration_job_name" {
  description = "Full resource name of the DMS migration job."
  value       = google_database_migration_service_migration_job.migration.name
  depends_on  = [terraform_data.demote_destination]
}

output "migration_job_id" {
  description = "Short ID of the DMS migration job."
  value       = google_database_migration_service_migration_job.migration.migration_job_id
  depends_on  = [terraform_data.demote_destination]
}

output "migration_job_state" {
  description = "State of the DMS migration job as of the last Terraform refresh. Use `gcloud database-migration migration-jobs describe` for the live value."
  value       = google_database_migration_service_migration_job.migration.state
}

output "migration_job_phase" {
  description = "Phase of the DMS migration job as of the last Terraform refresh (for example FULL_DUMP, CDC, READY_FOR_PROMOTE)."
  value       = google_database_migration_service_migration_job.migration.phase
}
