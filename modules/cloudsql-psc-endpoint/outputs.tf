output "endpoint_ip_address" {
  description = "Internal IP address of the PSC endpoint."
  value       = var.enabled ? google_compute_address.psc_endpoint[0].address : null
}

output "forwarding_rule_self_link" {
  description = "Self-link of the PSC endpoint forwarding rule."
  value       = var.enabled ? google_compute_forwarding_rule.psc_endpoint[0].self_link : null
}

output "psc_connection_status" {
  description = "PSC connection status of the endpoint, captured at apply; run terraform refresh (or apply) to update. Expect ACCEPTED."
  value       = var.enabled ? google_compute_forwarding_rule.psc_endpoint[0].psc_connection_status : null
}

output "dns_name" {
  description = "DNS name that resolves to the endpoint IP inside the consumer VPC (null when no record is created)."
  value       = var.enabled && var.create_dns_record ? google_dns_record_set.instance[0].name : null
}

output "dns_zone_name" {
  description = "Name of the private Cloud DNS zone that holds the record (null when no record is created)."
  value       = var.enabled && var.create_dns_record ? google_dns_record_set.instance[0].managed_zone : null
}
