# ==============================================================================
# Example: several MySQL 8.0 migrations (one DMS job per Cloud SQL instance)
# sharing one Network Attachment, one firewall rule and one private DNS zone.
# ==============================================================================

locals {
  # ACCEPT_MANUAL: the Cloud SQL tenant projects of all instances (in testing,
  # instances in the same project and region shared one tenant project).
  tenant_projects = distinct([
    for k, d in module.destination : regex("projects/([^/]+)/", d.psc_service_attachment_link)[0]
  ])

  create_dns_zone = var.existing_dns_zone_name == ""
  dns_zone_name   = local.create_dns_zone ? google_dns_managed_zone.sql_goog[0].name : var.existing_dns_zone_name
}

# 1. Shared Network Attachment (ACCEPT_MANUAL) + firewall rule to the sources.
module "networking" {
  source = "../../modules/networking-psc"

  project_id              = var.project_id
  region                  = var.region
  connectivity_type       = "PSC"
  network                 = var.network
  network_attachment_name = var.network_attachment_name
  labels                  = var.labels

  create_network_attachment = var.migration_enabled
  subnet                    = var.network_attachment_subnet
  psc_connection_preference = var.psc_connection_preference
  producer_accept_list      = local.tenant_projects

  create_source_firewall_rule    = var.create_source_firewall_rule
  source_port                    = var.source_port
  source_target_tags             = var.source_target_tags
  source_target_service_accounts = var.source_target_service_accounts
}

# 2. One Cloud SQL destination per migration.
module "destination" {
  source   = "../../modules/cloudsql-mysql-destination"
  for_each = var.migrations

  project_id             = var.project_id
  region                 = var.region
  instance_name          = each.value.instance_name
  database_version       = each.value.database_version
  edition                = each.value.edition
  tier                   = each.value.tier
  availability_type      = each.value.availability_type
  connectivity_type      = "PSC"
  enable_ipv4            = false
  allowed_psc_projects   = [var.project_id]
  disk_size_gb           = each.value.disk_size_gb
  root_password          = var.cloudsql_root_passwords[each.key]
  lower_case_table_names = each.value.lower_case_table_names
  deletion_protection    = each.value.deletion_protection
  ssl_mode               = each.value.ssl_mode
  kms_key_name           = each.value.kms_key_name
  labels                 = var.labels
}

# 2b. Attach the shared Network Attachment to every instance while the
#     migration runs (detached again, with a restart, by migration_enabled = false).
module "psc_outbound" {
  source   = "../../modules/cloudsql-psc-outbound"
  for_each = var.migrations

  enabled                     = var.migration_enabled
  project_id                  = var.project_id
  instance_name               = module.destination[each.key].instance_name
  network_attachment_uri      = module.networking.network_attachment_self_link
  impersonate_service_account = var.impersonate_service_account
}

# 3. One private zone for <region>.sql.goog. (a VPC can bind only one zone for
#    that name), with one A record per instance.
resource "google_dns_managed_zone" "sql_goog" {
  count = local.create_dns_zone ? 1 : 0

  project     = var.project_id
  name        = "${var.network_attachment_name}-sql-goog"
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

module "psc_endpoint" {
  source   = "../../modules/cloudsql-psc-endpoint"
  for_each = var.migrations

  project_id              = var.project_id
  region                  = var.region
  name                    = each.value.instance_name
  network                 = var.network
  subnetwork              = var.psc_endpoint_subnet
  service_attachment_link = module.destination[each.key].psc_service_attachment_link
  instance_dns_name       = module.destination[each.key].dns_name
  existing_dns_zone_name  = local.dns_zone_name
  labels                  = var.labels
}

# 4. DMS connection profiles and jobs (removed with migration_enabled = false).
module "profiles" {
  source   = "../../modules/dms-connection-profiles"
  for_each = var.migration_enabled ? var.migrations : {}

  project_id          = var.project_id
  region              = var.region
  source_profile_id   = "${each.key}-src"
  source_display_name = "MySQL source ${each.key}"
  source_host         = each.value.source_host
  source_port         = each.value.source_port
  source_username     = each.value.source_username
  source_password     = var.source_passwords[each.key]
  source_ssl_type     = each.value.source_ssl_type

  destination_profile_id   = "${each.key}-dest"
  destination_display_name = "Cloud SQL destination ${each.key}"
  destination_mode         = "EXISTING_CLOUDSQL"
  destination_cloud_sql_id = module.psc_outbound[each.key].instance_name
  labels                   = var.labels
}

module "job" {
  source   = "../../modules/dms-migration-job"
  for_each = var.migration_enabled ? var.migrations : {}

  project_id                     = var.project_id
  region                         = var.region
  migration_job_id               = each.key
  display_name                   = "MySQL 80 to Cloud SQL ${each.key}"
  migration_type                 = "CONTINUOUS"
  destination_mode               = "EXISTING_CLOUDSQL"
  source_connection_profile      = module.profiles[each.key].source_connection_profile_name
  destination_connection_profile = module.profiles[each.key].destination_connection_profile_name
  dump_type                      = "LOGICAL"
  databases                      = each.value.databases
  impersonate_service_account    = var.impersonate_service_account
  labels                         = var.labels
}
