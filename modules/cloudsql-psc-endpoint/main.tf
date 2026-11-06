# ------------------------------------------------------------------------------
# Private Service Connect (PSC) consumer endpoint + private DNS for a
# PSC-enabled Cloud SQL instance.
#
# Applications in the consumer VPC reach the instance through:
#   - an internal IP address reserved in a consumer subnet,
#   - a forwarding rule that targets the instance's service attachment, and
#   - an A record for the instance DNS name in a private Cloud DNS zone.
#
# Reference: https://cloud.google.com/sql/docs/mysql/configure-private-service-connect
#            https://cloud.google.com/sql/docs/mysql/configure-dns
# ------------------------------------------------------------------------------

locals {
  create_zone = var.enabled && var.create_dns_record && var.existing_dns_zone_name == ""
  zone_name   = var.existing_dns_zone_name != "" ? var.existing_dns_zone_name : (var.dns_zone_name != "" ? var.dns_zone_name : "${var.name}-sql-goog")

  # Cloud SQL PSC DNS names have the form <uid>.<project-label>.<region>.sql.goog.
  record_name = var.instance_dns_name == null ? "" : (endswith(var.instance_dns_name, ".") ? var.instance_dns_name : "${var.instance_dns_name}.")
}

resource "google_compute_address" "psc_endpoint" {
  count = var.enabled ? 1 : 0

  project      = var.project_id
  region       = var.region
  name         = "${var.name}-psc-ip"
  description  = "Internal IP address for the PSC endpoint of Cloud SQL instance ${var.name}"
  address_type = "INTERNAL"
  subnetwork   = var.subnetwork
  address      = var.ip_address != "" ? var.ip_address : null
  labels       = var.labels
}

resource "google_compute_forwarding_rule" "psc_endpoint" {
  count = var.enabled ? 1 : 0

  project                 = var.project_id
  region                  = var.region
  name                    = "${var.name}-psc-endpoint"
  description             = "PSC endpoint for Cloud SQL instance ${var.name}"
  network                 = var.network
  ip_address              = google_compute_address.psc_endpoint[0].self_link
  load_balancing_scheme   = ""
  target                  = var.service_attachment_link
  allow_psc_global_access = var.allow_psc_global_access
  # The private zone below (or an existing zone) holds the record, so do not
  # let PSC auto-generate a DNS zone for this endpoint.
  no_automate_dns_zone = true
  labels               = var.labels

  lifecycle {
    precondition {
      condition     = var.service_attachment_link != null && var.service_attachment_link != ""
      error_message = "service_attachment_link must be set. Enable PSC on the Cloud SQL instance (connectivity_type = \"PSC\")."
    }
  }
}

resource "google_dns_managed_zone" "sql_goog" {
  count = local.create_zone ? 1 : 0

  project     = var.project_id
  name        = local.zone_name
  dns_name    = "${var.region}.sql.goog."
  description = "Private zone for Cloud SQL PSC DNS names in ${var.region}"
  visibility  = "private"
  labels      = var.labels

  private_visibility_config {
    networks {
      network_url = var.network
    }
  }
}

resource "google_dns_record_set" "instance" {
  count = var.enabled && var.create_dns_record ? 1 : 0

  project      = var.project_id
  managed_zone = local.create_zone ? google_dns_managed_zone.sql_goog[0].name : local.zone_name
  name         = local.record_name
  type         = "A"
  ttl          = var.dns_record_ttl
  rrdatas      = [google_compute_address.psc_endpoint[0].address]
}
