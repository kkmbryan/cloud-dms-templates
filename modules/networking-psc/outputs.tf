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

output "psa_private_network_link" {
  description = "The VPC network link for Private Services Access (when connectivity_type = 'PSA')."
  value       = local.is_psa ? (var.create_psa_peering ? google_service_networking_connection.psa_connection[0].network : (var.peering_vpc_self_link != "" ? var.peering_vpc_self_link : var.network)) : null
}
