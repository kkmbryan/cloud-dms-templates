output "connectivity_type" {
  description = "Active connectivity architecture ('PSC' or 'PSA')."
  value       = var.connectivity_type
}

output "network_attachment_id" {
  description = "The ID of the Compute Engine Network Attachment (null when it isn't created)."
  value       = local.create_na ? google_compute_network_attachment.dms_psc[0].id : null
}

output "network_attachment_self_link" {
  description = "The self_link of the Compute Engine Network Attachment (null when it isn't created)."
  value       = local.create_na ? google_compute_network_attachment.dms_psc[0].self_link : null
}

output "network_attachment_producer_accept_list" {
  description = "Producer projects accepted by the Network Attachment (ACCEPT_MANUAL)."
  value       = local.create_na && var.psc_connection_preference == "ACCEPT_MANUAL" ? local.producer_accept_list : null
}

output "network_attachment_connection_endpoints" {
  description = "PSC interface connections on the Network Attachment as of the last refresh (status ACCEPTED, PENDING or REJECTED)."
  value       = local.create_na ? google_compute_network_attachment.dms_psc[0].connection_endpoints : null
}

output "source_firewall_rule_name" {
  description = "Name of the firewall rule that allows the Network Attachment subnet to reach the source (null when not created)."
  value       = local.create_firewall ? google_compute_firewall.na_to_source[0].name : null
}

output "psa_private_network_link" {
  description = "The VPC network link for Private Services Access (when connectivity_type = 'PSA')."
  value       = local.is_psa ? (var.create_psa_peering ? google_service_networking_connection.psa_connection[0].network : (var.peering_vpc_self_link != "" ? var.peering_vpc_self_link : var.network)) : null
}
