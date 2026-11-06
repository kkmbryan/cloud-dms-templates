# ==============================================================================
# Scenario 2: Migration from a Backup in GCS (mysqldump / XtraBackup) + CDC
# ==============================================================================

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  # DMS service agent. Create it once per project before the first apply:
  #   gcloud beta services identity create --service=datamigration.googleapis.com
  dms_service_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-datamigration.iam.gserviceaccount.com"

  # Single source of truth for the seed location (also exported as the
  # configured_dump_path output). LOGICAL: one file. PHYSICAL: a folder.
  dump_path = "${module.gcs_migration_staging.bucket_url}/${var.backup_gcs_path}"

  bucket_reader_members = merge(
    { dms_service_agent = local.dms_service_agent },
    var.destination_mode == "EXISTING_CLOUDSQL" ? { cloudsql_instance_sa = module.cloudsql_destination.service_account_email_address } : {},
    { for m in var.additional_bucket_reader_members : "extra:${m}" => m },
  )
}

# 1. Private Service Connect (PSC) networking (default) or PSA
module "networking" {
  source = "../../modules/networking-psc"

  project_id              = var.project_id
  region                  = var.region
  connectivity_type       = var.connectivity_type
  network                 = var.network
  subnet                  = var.subnet
  network_attachment_name = var.network_attachment_name
  create_psa_peering      = var.create_psa_peering
  labels                  = var.labels

  # The Network Attachment exists only while the migration runs, and only for
  # EXISTING_CLOUDSQL (it is attached to the Terraform-created instance).
  create_network_attachment = var.migration_enabled && var.destination_mode == "EXISTING_CLOUDSQL"
  network_attachment_subnet = var.network_attachment_subnet

  # ACCEPT_MANUAL: accept only the Cloud SQL tenant project, taken from the
  # instance's service attachment link (created first, in the same apply).
  psc_connection_preference            = var.psc_connection_preference
  cloudsql_psc_service_attachment_link = module.cloudsql_destination.psc_service_attachment_link
  producer_accept_list                 = var.psc_producer_accept_list

  # tcp:source port from the Network Attachment subnet to the source VM.
  create_source_firewall_rule    = var.create_source_firewall_rule
  source_firewall_rule_name      = var.source_firewall_rule_name
  source_port                    = var.source_gce_mysql_port
  source_target_tags             = var.source_target_tags
  source_target_service_accounts = var.source_target_service_accounts
}

# 2. Cloud SQL for MySQL destination instance (MYSQL_8_4 default or MYSQL_8_0)
module "cloudsql_destination" {
  source = "../../modules/cloudsql-mysql-destination"

  enabled                        = var.destination_mode == "EXISTING_CLOUDSQL"
  project_id                     = var.project_id
  region                         = var.region
  instance_name                  = var.cloudsql_instance_name
  database_version               = var.target_database_version
  edition                        = var.cloudsql_edition
  tier                           = var.cloudsql_tier
  availability_type              = var.cloudsql_availability_type
  connectivity_type              = var.connectivity_type
  enable_ipv4                    = false
  allowed_psc_projects           = distinct(concat([var.project_id], var.allowed_psc_consumer_projects))
  private_network                = module.networking.psa_private_network_link
  disk_size_gb                   = var.cloudsql_disk_size_gb
  root_password                  = var.cloudsql_root_password
  root_password_wo_version       = var.cloudsql_root_password_version
  lower_case_table_names         = var.cloudsql_lower_case_table_names
  transaction_log_retention_days = var.cloudsql_transaction_log_retention_days
  retained_backups               = var.cloudsql_retained_backups
  deletion_protection            = var.cloudsql_deletion_protection
  ssl_mode                       = var.cloudsql_ssl_mode
  kms_key_name                   = var.cloudsql_kms_key_name
  password_validation_policy     = var.cloudsql_password_validation_policy
  labels                         = var.labels
}

# Attach the Network Attachment to the instance (PSC interface) while the
# migration runs; detached again (instance restart) when migration_enabled = false.
module "cloudsql_psc_outbound" {
  source = "../../modules/cloudsql-psc-outbound"

  enabled                     = var.destination_mode == "EXISTING_CLOUDSQL" && var.connectivity_type == "PSC" && var.migration_enabled
  project_id                  = var.project_id
  instance_name               = module.cloudsql_destination.instance_name
  network_attachment_uri      = module.networking.network_attachment_self_link
  impersonate_service_account = var.impersonate_service_account
}

# 3. GCS staging bucket for the seed. Read access is granted automatically to
#    the DMS service agent and to the Cloud SQL instance service account.
module "gcs_migration_staging" {
  source = "../../modules/gcs-migration-staging"

  project_id                        = var.project_id
  region                            = var.region
  bucket_name                       = var.staging_bucket_name
  force_destroy                     = var.staging_bucket_force_destroy
  retention_days                    = var.staging_bucket_retention_days
  noncurrent_version_retention_days = var.staging_bucket_noncurrent_version_retention_days
  kms_key_name                      = var.staging_bucket_kms_key_name
  reader_members                    = local.bucket_reader_members
  backup_writer_members             = var.backup_writer_members
  labels                            = var.labels
}

# 4. PSC consumer endpoint + private DNS so applications can reach the
#    instance after promotion (EXISTING_CLOUDSQL + PSC only)
module "cloudsql_psc_endpoint" {
  source = "../../modules/cloudsql-psc-endpoint"

  enabled                 = var.create_psc_endpoint && var.destination_mode == "EXISTING_CLOUDSQL" && var.connectivity_type == "PSC"
  project_id              = var.project_id
  region                  = var.region
  name                    = var.cloudsql_instance_name
  network                 = var.network
  subnetwork              = var.psc_endpoint_subnet != "" ? var.psc_endpoint_subnet : var.subnet
  ip_address              = var.psc_endpoint_ip_address
  service_attachment_link = module.cloudsql_destination.psc_service_attachment_link
  instance_dns_name       = module.cloudsql_destination.dns_name
  allow_psc_global_access = var.psc_endpoint_global_access
  create_dns_record       = var.create_psc_dns_record
  existing_dns_zone_name  = var.psc_existing_dns_zone_name
  labels                  = var.labels
}

# 5. Cloud DMS source and destination connection profiles (native resources)
module "dms_connection_profiles" {
  source = "../../modules/dms-connection-profiles"
  count  = var.migration_enabled ? 1 : 0

  project_id          = var.project_id
  region              = var.region
  source_profile_id   = "${var.migration_job_id}-src"
  source_display_name = "MySQL 80 source backup CDC"
  source_host         = var.source_gce_mysql_host
  source_port         = var.source_gce_mysql_port
  source_username     = var.source_gce_mysql_username
  source_password     = var.source_gce_mysql_password

  source_ssl_type               = var.source_ssl_type
  source_ssl_ca_certificate     = var.source_ssl_ca_certificate
  source_ssl_client_certificate = var.source_ssl_client_certificate
  source_ssl_client_key         = var.source_ssl_client_key

  destination_profile_id   = var.destination_mode == "DMS_MANAGED_CLOUDSQL" ? var.cloudsql_instance_name : "${var.migration_job_id}-dest"
  destination_display_name = "Cloud SQL ${replace(var.target_database_version, "_", " ")} destination backup CDC"
  destination_mode         = var.destination_mode
  destination_cloud_sql_id = var.destination_mode == "EXISTING_CLOUDSQL" ? module.cloudsql_psc_outbound.instance_name : ""

  dest_database_version = var.target_database_version
  dest_edition          = var.cloudsql_edition
  dest_tier             = var.cloudsql_tier
  dest_disk_size_gb     = var.cloudsql_disk_size_gb
  dest_zone             = var.cloudsql_zone != "" ? var.cloudsql_zone : "${var.region}-a"
  dest_root_password    = var.cloudsql_root_password
  dest_cmek_key_name    = var.cloudsql_kms_key_name
  dest_enable_ipv4      = false
  dest_private_network  = var.network
  labels                = var.labels
}

# 6. Cloud DMS continuous migration job seeded from GCS (dump_path) + binlog CDC.
#    DMS checks that the seed exists at dump_path when the job is created, so
#    run a first apply with create_migration_job = false, upload the seed to
#    configured_dump_path, then apply again with create_migration_job = true.
module "dms_migration_job" {
  source = "../../modules/dms-migration-job"
  count  = var.migration_enabled && var.create_migration_job ? 1 : 0

  # Bucket IAM must exist before `verify`/`start`; make the job wait for it.
  depends_on = [module.gcs_migration_staging]

  project_id                     = var.project_id
  region                         = var.region
  migration_job_id               = var.migration_job_id
  display_name                   = "GCS backup ${var.dump_type} to Cloud SQL ${replace(var.target_database_version, "_", " ")} CDC"
  migration_type                 = "CONTINUOUS"
  destination_mode               = var.destination_mode
  source_connection_profile      = module.dms_connection_profiles[0].source_connection_profile_name
  destination_connection_profile = module.dms_connection_profiles[0].destination_connection_profile_name
  dump_type                      = var.dump_type
  dump_path                      = local.dump_path
  connectivity_method            = var.connectivity_method
  vpc_peering_network            = var.network
  reverse_ssh_vm_ip              = var.reverse_ssh_vm_ip
  reverse_ssh_vm                 = var.reverse_ssh_vm
  reverse_ssh_vpc                = var.network
  impersonate_service_account    = var.impersonate_service_account
  labels                         = var.labels
}

# State address before migration_enabled added count to this module.
moved {
  from = module.dms_connection_profiles
  to   = module.dms_connection_profiles[0]
}

# The attach step moved from the destination module to its own module.
moved {
  from = module.cloudsql_destination.terraform_data.psc_outbound_network_attachment
  to   = module.cloudsql_psc_outbound.terraform_data.psc_outbound_network_attachment
}
