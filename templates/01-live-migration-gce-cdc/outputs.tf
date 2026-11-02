output "connectivity_type" {
  description = "Active connectivity mode for the migration ('PSC' or 'PSA')."
  value       = module.networking.connectivity_type
}

output "network_attachment_self_link" {
  description = "Self-link of the PSC Network Attachment (when connectivity_type = 'PSC')."
  value       = module.networking.network_attachment_self_link
}

output "private_connection_name" {
  description = "Canonical resource name of the Cloud DMS Private Connection (when connectivity_type = 'PSC')."
  value       = module.networking.private_connection_name
}

output "cloudsql_instance_name" {
  description = "Name of the destination Cloud SQL for MySQL instance."
  value       = coalesce(module.cloudsql_destination.instance_name, module.dms_connection_profiles.dms_cloud_sql_id, var.cloudsql_instance_name)
}

output "cloudsql_private_ip" {
  description = "Private IPv4 address of the destination Cloud SQL for MySQL instance."
  value       = coalesce(module.cloudsql_destination.private_ip_address, module.dms_connection_profiles.dms_cloud_sql_private_ip, "pending")
}

output "cloudsql_connection_name" {
  description = "Connection name of the destination Cloud SQL instance."
  value       = module.cloudsql_destination.instance_connection_name
}

output "cloudsql_psc_service_attachment" {
  description = "PSC Service Attachment URI of the destination Cloud SQL instance."
  value       = module.cloudsql_destination.psc_service_attachment_link
}

output "cloudsql_dns_name" {
  description = "Private DNS name of the destination Cloud SQL instance."
  value       = module.cloudsql_destination.dns_name
}

output "source_connection_profile_name" {
  description = "Full resource name of the source GCE MySQL 8.0 DMS connection profile."
  value       = module.dms_connection_profiles.source_connection_profile_name
}

output "destination_connection_profile_name" {
  description = "Full resource name of the destination Cloud SQL DMS connection profile."
  value       = module.dms_connection_profiles.destination_connection_profile_name
}

output "migration_job_name" {
  description = "Full resource name of the continuous DMS migration job."
  value       = module.dms_migration_job.migration_job_name
}

output "migration_job_id" {
  description = "Short ID of the continuous DMS migration job."
  value       = module.dms_migration_job.migration_job_id
}

output "migration_job_state" {
  description = "Current state of the continuous DMS migration job."
  value       = module.dms_migration_job.migration_job_state
}

output "migration_job_phase" {
  description = "Current phase of the continuous DMS migration job."
  value       = module.dms_migration_job.migration_job_phase
}
