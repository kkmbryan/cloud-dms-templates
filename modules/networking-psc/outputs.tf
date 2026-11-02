output "connectivity_type" {
  description = "Active connectivity architecture ('PSC' or 'PSA')."
  value       = var.connectivity_type
}

output "network_attachment_id" {
  description = "The ID of the Compute Engine Network Attachment (when connectivity_type = 'PSC')."
  value       = local.is_psc ? google_compute_network_attachment.dms_psc[0].id : null
}

output "network_attachment_self_link" {
  description = "The self_link of the Compute Engine Network Attachment (when connectivity_type = 'PSC')."
  value       = local.is_psc ? google_compute_network_attachment.dms_psc[0].self_link : null
}

output "private_connection_id" {
  description = "The full resource ID of the Cloud DMS Private Connection (when connectivity_type = 'PSC' and create_dms_private_connection = true)."
  value       = local.is_psc && var.create_dms_private_connection ? google_database_migration_service_private_connection.dms_psc[0].id : null
}

output "private_connection_short_id" {
  description = "The short ID of the Cloud DMS Private Connection (when connectivity_type = 'PSC' and create_dms_private_connection = true)."
  value       = local.is_psc && var.create_dms_private_connection ? (google_database_migration_service_private_connection.dms_psc[0].id != "" ? google_database_migration_service_private_connection.dms_psc[0].private_connection_id : var.private_connection_id) : null
}

output "private_connection_name" {
  description = "The canonical resource name of the Cloud DMS Private Connection (when connectivity_type = 'PSC' and create_dms_private_connection = true)."
  value       = local.is_psc && var.create_dms_private_connection ? google_database_migration_service_private_connection.dms_psc[0].name : null
}

output "psa_private_network_link" {
  description = "The VPC network link for Private Services Access (when connectivity_type = 'PSA')."
  value       = local.is_psa ? (var.create_psa_peering ? google_service_networking_connection.psa_connection[0].network : (var.peering_vpc_self_link != "" ? var.peering_vpc_self_link : var.network)) : null
}
