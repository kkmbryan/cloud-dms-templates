output "instance_name" {
  description = "The Cloud SQL instance name, available once the Network Attachment is attached (use it to order resources that need replication connectivity)."
  value       = var.instance_name
  depends_on  = [terraform_data.psc_outbound_network_attachment]
}

output "network_attachment_uri" {
  description = "The Network Attachment attached to the instance (null when enabled = false)."
  value       = var.enabled ? local.psc_network_attachment_uri : null
}
