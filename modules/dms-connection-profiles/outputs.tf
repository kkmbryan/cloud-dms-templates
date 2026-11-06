output "source_connection_profile_name" {
  description = "Full resource name of the source MySQL DMS connection profile."
  value       = google_database_migration_service_connection_profile.source.name
}

output "source_connection_profile_id" {
  description = "Short ID of the source MySQL DMS connection profile."
  value       = google_database_migration_service_connection_profile.source.connection_profile_id
}

output "destination_connection_profile_name" {
  description = "Full resource name of the destination Cloud SQL for MySQL DMS connection profile."
  value       = local.use_existing_cloudsql ? google_database_migration_service_connection_profile.destination_existing[0].name : google_database_migration_service_connection_profile.destination[0].name
}

output "destination_connection_profile_id" {
  description = "Short ID of the destination Cloud SQL for MySQL DMS connection profile."
  value       = local.use_existing_cloudsql ? google_database_migration_service_connection_profile.destination_existing[0].connection_profile_id : google_database_migration_service_connection_profile.destination[0].connection_profile_id
}

output "dms_cloud_sql_id" {
  description = "The destination Cloud SQL instance ID (the existing instance, or the one DMS creates when destination_mode = 'DMS_MANAGED_CLOUDSQL')."
  value       = local.use_existing_cloudsql ? var.destination_cloud_sql_id : try(google_database_migration_service_connection_profile.destination[0].cloudsql[0].cloud_sql_id, null)
}

output "dms_cloud_sql_private_ip" {
  description = "The private IPv4 address of the Cloud SQL instance provisioned by DMS (when destination_mode = 'DMS_MANAGED_CLOUDSQL')."
  value       = local.use_existing_cloudsql ? null : try(google_database_migration_service_connection_profile.destination[0].cloudsql[0].private_ip, null)
}

output "dms_cloud_sql_public_ip" {
  description = "The public IPv4 address of the Cloud SQL instance provisioned by DMS (when destination_mode = 'DMS_MANAGED_CLOUDSQL')."
  value       = local.use_existing_cloudsql ? null : try(google_database_migration_service_connection_profile.destination[0].cloudsql[0].public_ip, null)
}
