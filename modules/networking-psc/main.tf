locals {
  is_psc = var.connectivity_type == "PSC"
  is_psa = var.connectivity_type == "PSA"

  producer_accept_list = compact(concat(
    [var.project_id],
    var.dms_tenant_project_id != "" ? [var.dms_tenant_project_id] : []
  ))
}

# ------------------------------------------------------------------------------
# Private Service Connect (PSC) - Recommended Default
# ------------------------------------------------------------------------------

resource "google_compute_network_attachment" "dms_psc" {
  count = local.is_psc ? 1 : 0

  project               = var.project_id
  name                  = var.network_attachment_name
  region                = var.region
  description           = "Private Service Connect Network Attachment for Cloud DMS and Cloud SQL MySQL connectivity"
  connection_preference = var.dms_tenant_project_id != "" ? "ACCEPT_MANUAL" : var.psc_connection_preference
  subnetworks           = [var.subnet]
  producer_accept_lists = (var.dms_tenant_project_id != "" || var.psc_connection_preference == "ACCEPT_MANUAL") ? local.producer_accept_list : null
}

resource "google_database_migration_service_private_connection" "dms_psc" {
  count = local.is_psc && var.create_dms_private_connection ? 1 : 0

  project               = var.project_id
  location              = var.region
  private_connection_id = var.private_connection_id
  display_name          = var.private_connection_id
  labels                = var.labels

  psc_interface_config {
    network_attachment = google_compute_network_attachment.dms_psc[0].id
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
