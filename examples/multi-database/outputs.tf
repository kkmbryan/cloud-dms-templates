output "network_attachment_self_link" {
  description = "Self-link of the shared Network Attachment (null after migration_enabled = false)."
  value       = module.networking.network_attachment_self_link
}

output "network_attachment_producer_accept_list" {
  description = "Cloud SQL tenant projects accepted by the shared Network Attachment (ACCEPT_MANUAL)."
  value       = module.networking.network_attachment_producer_accept_list
}

output "cloudsql_instance_names" {
  description = "Cloud SQL instance name per migration job ID."
  value       = { for k, d in module.destination : k => d.instance_name }
}

output "psc_endpoint_dns_names" {
  description = "DNS name per migration job ID that resolves to its PSC endpoint inside the network. Point applications at these names after promotion."
  value       = { for k, e in module.psc_endpoint : k => e.dns_name }
}

output "psc_endpoint_ip_addresses" {
  description = "PSC endpoint IP address per migration job ID."
  value       = { for k, e in module.psc_endpoint : k => e.endpoint_ip_address }
}

output "migration_job_ids" {
  description = "DMS migration job IDs (use with make ... JOB_ID=<id> CLOUDSQL_INSTANCE=<instance>)."
  value       = [for k, j in module.job : j.migration_job_id]
}

output "dns_zone_name" {
  description = "Private Cloud DNS zone that holds the instance records."
  value       = local.dns_zone_name
}
