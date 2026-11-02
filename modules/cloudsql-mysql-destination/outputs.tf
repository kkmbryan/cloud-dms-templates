output "instance_name" {
  description = "The name of the provisioned Cloud SQL for MySQL destination instance."
  value       = var.enabled ? google_sql_database_instance.destination[0].name : null
  depends_on  = [terraform_data.psc_outbound_network_attachment]
}

output "instance_connection_name" {
  description = "The connection name of the Cloud SQL instance (project:region:instance)."
  value       = var.enabled ? google_sql_database_instance.destination[0].connection_name : null
}

output "psc_service_attachment_link" {
  description = "The Private Service Connect (PSC) service attachment link for the Cloud SQL instance."
  value       = var.enabled ? google_sql_database_instance.destination[0].psc_service_attachment_link : null
}

output "dns_name" {
  description = "The DNS name of the Cloud SQL instance for PSC or private connectivity."
  value       = var.enabled ? google_sql_database_instance.destination[0].dns_name : null
}

output "private_ip_address" {
  description = "The private IPv4 address assigned to the Cloud SQL instance (when using PSA)."
  value       = var.enabled ? google_sql_database_instance.destination[0].private_ip_address : null
}

output "self_link" {
  description = "The URI of the provisioned Cloud SQL instance."
  value       = var.enabled ? google_sql_database_instance.destination[0].self_link : null
}

output "service_account_email_address" {
  description = "The service account email address assigned to the Cloud SQL instance."
  value       = var.enabled ? google_sql_database_instance.destination[0].service_account_email_address : null
}
