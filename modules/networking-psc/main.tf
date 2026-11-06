locals {
  is_psc = var.connectivity_type == "PSC"
  is_psa = var.connectivity_type == "PSA"

  create_na = local.is_psc && var.create_network_attachment

  # Subnet that hosts the PSC interfaces (Network Attachment). A dedicated small
  # subnet is recommended; it defaults to var.subnet.
  na_subnet = var.network_attachment_subnet != "" ? var.network_attachment_subnet : var.subnet

  # ACCEPT_MANUAL: accept only the listed producer projects. By default this is
  # the Cloud SQL tenant project, i.e. the project segment of the instance's
  # psc_service_attachment_link (projects/<tenant>/regions/<r>/serviceAttachments/<n>).
  derived_producer_project = var.cloudsql_psc_service_attachment_link == null ? "" : try(regex("projects/([^/]+)/", var.cloudsql_psc_service_attachment_link)[0], "")
  producer_accept_list     = length(var.producer_accept_list) > 0 ? var.producer_accept_list : compact([local.derived_producer_project])

  create_firewall = local.create_na && var.create_source_firewall_rule
  firewall_name   = var.source_firewall_rule_name != "" ? var.source_firewall_rule_name : "${var.network_attachment_name}-to-source"
}

# ------------------------------------------------------------------------------
# Private Service Connect (PSC) - Recommended Default
# The Network Attachment lets the destination Cloud SQL instance open a PSC
# interface into this subnet so that DMS replication reaches the source.
#
# The attachment depends on the Cloud SQL instance (it needs the tenant project
# for ACCEPT_MANUAL), and the instance does not depend on the attachment: a
# separate step attaches it to the instance afterwards. So one apply works:
# instance -> Network Attachment -> attach to instance.
# ------------------------------------------------------------------------------

data "google_compute_subnetwork" "na" {
  count     = local.create_firewall ? 1 : 0
  self_link = startswith(local.na_subnet, "https://") ? local.na_subnet : "https://www.googleapis.com/compute/v1/${local.na_subnet}"
}

resource "google_compute_network_attachment" "dms_psc" {
  count = local.create_na ? 1 : 0

  project               = var.project_id
  name                  = var.network_attachment_name
  region                = var.region
  description           = "PSC Network Attachment used by the Cloud SQL destination (PSC interface) to reach the source MySQL during DMS replication"
  connection_preference = var.psc_connection_preference
  subnetworks           = [local.na_subnet]
  producer_accept_lists = var.psc_connection_preference == "ACCEPT_MANUAL" ? local.producer_accept_list : null

  lifecycle {
    precondition {
      condition     = local.na_subnet != ""
      error_message = "Set subnet (or network_attachment_subnet) to the subnet that hosts the PSC Network Attachment."
    }
    precondition {
      condition     = var.psc_connection_preference != "ACCEPT_MANUAL" || length(local.producer_accept_list) > 0
      error_message = "ACCEPT_MANUAL needs a producer accept list: either the Cloud SQL instance's psc_service_attachment_link (derived automatically) or psc_producer_accept_list."
    }
  }
}

# ------------------------------------------------------------------------------
# Firewall: allow the PSC interfaces (Network Attachment subnet) to reach the
# source MySQL port. Without it, a default-deny VPC fails `verify`.
# ------------------------------------------------------------------------------

resource "google_compute_firewall" "na_to_source" {
  count = local.create_firewall ? 1 : 0

  project     = var.project_id
  name        = local.firewall_name
  network     = var.network
  description = "Allow DMS replication from the PSC Network Attachment subnet to the source MySQL"
  direction   = "INGRESS"
  priority    = var.source_firewall_priority

  source_ranges           = [data.google_compute_subnetwork.na[0].ip_cidr_range]
  target_tags             = length(var.source_target_tags) > 0 ? var.source_target_tags : null
  target_service_accounts = length(var.source_target_service_accounts) > 0 ? var.source_target_service_accounts : null

  allow {
    protocol = "tcp"
    ports    = [tostring(var.source_port)]
  }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }

  lifecycle {
    precondition {
      condition     = (length(var.source_target_tags) > 0) != (length(var.source_target_service_accounts) > 0)
      error_message = "create_source_firewall_rule = true needs exactly one of source_target_tags or source_target_service_accounts (a VPC firewall rule can't use both)."
    }
  }
}

# ------------------------------------------------------------------------------
# Private Services Access (PSA) - Optional Alternative
# ------------------------------------------------------------------------------

resource "google_compute_global_address" "psa_range" {
  count = local.is_psa && var.create_psa_peering ? 1 : 0

  project       = var.project_id
  name          = var.psa_allocated_ip_range_name
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = var.psa_prefix_length
  network       = var.network
  labels        = var.labels
}

resource "google_service_networking_connection" "psa_connection" {
  count = local.is_psa && var.create_psa_peering ? 1 : 0

  network                 = var.network
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa_range[0].name]
}
