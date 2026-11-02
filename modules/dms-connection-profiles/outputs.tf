output "source_connection_profile_name" {
  description = "Full resource name of the source GCE MySQL 8.0 DMS connection profile."
  value       = local.use_existing_cloudsql ? "projects/${var.project_id}/locations/${var.region}/connectionProfiles/${terraform_data.source_existing_cloudsql[0].input.source_profile_id}" : google_database_migration_service_connection_profile.source[0].name
}

output "source_connection_profile_id" {
  description = "Short ID of the source GCE MySQL 8.0 DMS connection profile."
  value       = local.use_existing_cloudsql ? terraform_data.source_existing_cloudsql[0].input.source_profile_id : google_database_migration_service_connection_profile.source[0].connection_profile_id
}

output "destination_connection_profile_name" {
  description = "Full resource name of the destination Cloud SQL MySQL DMS connection profile."
  value       = local.use_existing_cloudsql ? "projects/${var.project_id}/locations/${var.region}/connectionProfiles/${terraform_data.destination_existing_cloudsql[0].input.destination_profile_id}" : google_database_migration_service_connection_profile.destination[0].name
}

output "destination_connection_profile_id" {
  description = "Short ID of the destination Cloud SQL MySQL DMS connection profile."
  value       = local.use_existing_cloudsql ? terraform_data.destination_existing_cloudsql[0].input.destination_profile_id : google_database_migration_service_connection_profile.destination[0].connection_profile_id
}

output "dms_cloud_sql_id" {
  description = "The Cloud SQL instance ID provisioned by DMS (when destination_mode = 'DMS_MANAGED_CLOUDSQL')."
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
