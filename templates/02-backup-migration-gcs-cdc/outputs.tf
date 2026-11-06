output "connectivity_type" {
  description = "Active connectivity mode for the migration ('PSC' or 'PSA')."
  value       = module.networking.connectivity_type
}

output "network_attachment_self_link" {
  description = "Self-link of the PSC Network Attachment (when connectivity_type = 'PSC')."
  value       = module.networking.network_attachment_self_link
}

output "staging_bucket_name" {
  description = "Name of the GCS migration staging bucket."
  value       = module.gcs_migration_staging.bucket_name
}

output "staging_bucket_url" {
  description = "GCS URI of the migration staging bucket."
  value       = module.gcs_migration_staging.bucket_url
}

output "configured_dump_path" {
  description = "dump_path configured on the DMS migration job: the mysqldump file (LOGICAL) or the dedicated folder with the prepared XtraBackup files (PHYSICAL). Upload the seed exactly here."
  value       = local.dump_path
}

output "dms_service_agent" {
  description = "DMS service agent that was granted read access to the staging bucket."
  value       = local.dms_service_agent
}

output "cloudsql_instance_name" {
  description = "Name of the destination Cloud SQL for MySQL instance."
  value       = coalesce(module.cloudsql_destination.instance_name, module.dms_connection_profiles.dms_cloud_sql_id, var.cloudsql_instance_name)
}

output "cloudsql_private_ip" {
  description = "Private (PSA) IPv4 address of the destination Cloud SQL instance. Null for the default PSC-only instance; use psc_endpoint_ip_address instead."
  value       = try(coalesce(module.cloudsql_destination.private_ip_address, module.dms_connection_profiles.dms_cloud_sql_private_ip), null)
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
  description = "PSC DNS name of the destination Cloud SQL instance. It resolves inside var.network through the private DNS record created with the PSC endpoint."
  value       = module.cloudsql_destination.dns_name
}

output "psc_endpoint_ip_address" {
  description = "Internal IP address of the PSC consumer endpoint that applications use to reach Cloud SQL (null when create_psc_endpoint = false)."
  value       = module.cloudsql_psc_endpoint.endpoint_ip_address
}

output "psc_endpoint_dns_name" {
  description = "DNS name that resolves to the PSC endpoint inside var.network. Point applications at this name after promotion."
  value       = module.cloudsql_psc_endpoint.dns_name
}

output "psc_endpoint_connection_status" {
  description = "PSC connection status of the endpoint, captured at apply; run terraform refresh (or apply) to update. Expect ACCEPTED."
  value       = module.cloudsql_psc_endpoint.psc_connection_status
}

output "cloudsql_service_account_email" {
  description = "Service account of the destination Cloud SQL instance."
  value       = module.cloudsql_destination.service_account_email_address
}

output "source_connection_profile_name" {
  description = "Full resource name of the source MySQL 8.0 DMS connection profile."
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
  description = "State of the DMS migration job as of the last Terraform refresh."
  value       = module.dms_migration_job.migration_job_state
}

output "migration_job_phase" {
  description = "Phase of the DMS migration job as of the last Terraform refresh."
  value       = module.dms_migration_job.migration_job_phase
}
