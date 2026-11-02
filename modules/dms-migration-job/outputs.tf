output "migration_job_name" {
  description = "Full resource name of the DMS migration job."
  value       = local.use_existing_cloudsql ? "projects/${var.project_id}/locations/${var.region}/migrationJobs/${terraform_data.migration_existing_cloudsql[0].input.migration_job_id}" : google_database_migration_service_migration_job.migration[0].name
}

output "migration_job_id" {
  description = "Short ID of the DMS migration job."
  value       = local.use_existing_cloudsql ? terraform_data.migration_existing_cloudsql[0].input.migration_job_id : google_database_migration_service_migration_job.migration[0].migration_job_id
}

output "migration_job_state" {
  description = "Current lifecycle state of the DMS migration job."
  value       = local.use_existing_cloudsql ? "NOT_STARTED" : google_database_migration_service_migration_job.migration[0].state
}

output "migration_job_phase" {
  description = "Current phase of the DMS migration job (e.g., FULL_DUMP, CDC, READY_FOR_PROMOTE)."
  value       = local.use_existing_cloudsql ? "" : google_database_migration_service_migration_job.migration[0].phase
}
