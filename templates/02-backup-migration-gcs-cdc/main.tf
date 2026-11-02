# ==============================================================================
# Scenario 2: Migration from Backup in GCS (XtraBackup / mysqldump) + CDC
# ==============================================================================

# 1. Private Service Connect (PSC) Default Networking (with optional PSA)
module "networking" {
  source = "../../modules/networking-psc"

  project_id            = var.project_id
  region                = var.region
  connectivity_type     = var.connectivity_type
  network               = var.network
  subnet                = var.subnet
  dms_tenant_project_id = var.dms_tenant_project_id
  create_psa_peering    = var.create_psa_peering
  labels                = var.labels
}

# 2. GCS Staging Bucket for Physical (Percona XtraBackup) or Logical Backup Seed
module "gcs_migration_staging" {
  source = "../../modules/gcs-migration-staging"

  project_id                = var.project_id
  region                    = var.region
  bucket_name               = var.staging_bucket_name
  force_destroy             = var.staging_bucket_force_destroy
  retention_days            = var.staging_bucket_retention_days
  dms_service_account_email = var.dms_service_account_email
  backup_writer_members     = var.backup_writer_members
  labels                    = var.labels
}

# 3. Cloud SQL for MySQL Destination Instance (MYSQL_8_4 default or MYSQL_8_0)
module "cloudsql_destination" {
  source = "../../modules/cloudsql-mysql-destination"

  enabled                    = var.destination_mode == "EXISTING_CLOUDSQL"
  project_id                 = var.project_id
  region                     = var.region
  instance_name              = var.cloudsql_instance_name
  database_version           = var.target_database_version
  edition                    = var.cloudsql_edition
  tier                       = var.cloudsql_tier
  availability_type          = var.cloudsql_availability_type
  connectivity_type          = var.connectivity_type
  enable_ipv4                = false
  allowed_psc_projects       = compact([var.project_id, var.dms_tenant_project_id])
  psc_network_attachment_uri = module.networking.network_attachment_self_link
  private_network            = module.networking.psa_private_network_link
  disk_size_gb               = var.cloudsql_disk_size_gb
  root_password              = var.cloudsql_root_password
  deletion_protection        = var.cloudsql_deletion_protection
  labels                     = var.labels
}

# 4. Cloud DMS Source & Destination Connection Profiles
module "dms_connection_profiles" {
  source = "../../modules/dms-connection-profiles"

  project_id            = var.project_id
  region                = var.region
  source_profile_id     = "${var.migration_job_id}-src"
  source_display_name   = "GCE MySQL 80 Source Backup CDC"
  source_host           = var.source_gce_mysql_host
  source_port           = var.source_gce_mysql_port
  source_username       = var.source_gce_mysql_username
  source_password       = var.source_gce_mysql_password
  private_connection_id = module.networking.private_connection_short_id != null ? module.networking.private_connection_short_id : ""

  destination_profile_id   = var.destination_mode == "DMS_MANAGED_CLOUDSQL" ? var.cloudsql_instance_name : "${var.migration_job_id}-dest"
  destination_display_name = "Cloud SQL ${replace(var.target_database_version, "_", " ")} Destination Backup CDC"
  destination_mode         = var.destination_mode
  destination_cloud_sql_id = var.destination_mode == "EXISTING_CLOUDSQL" ? module.cloudsql_destination.instance_name : ""
  destination_host         = var.destination_connection_host != "" ? var.destination_connection_host : (var.destination_mode == "EXISTING_CLOUDSQL" ? (var.connectivity_type == "PSC" ? module.cloudsql_destination.dns_name : module.cloudsql_destination.private_ip_address) : "")
  destination_username     = "root"
  destination_password     = var.cloudsql_root_password

  dest_database_version  = var.target_database_version
  dest_edition           = var.cloudsql_edition
  dest_tier              = var.cloudsql_tier
  dest_availability_type = var.cloudsql_availability_type
  dest_disk_size_gb      = var.cloudsql_disk_size_gb
  dest_zone              = var.cloudsql_zone != "" ? var.cloudsql_zone : "${var.region}-a"
  dest_root_password     = var.cloudsql_root_password
  dest_enable_ipv4       = false
  dest_private_network   = var.network
  labels                 = var.labels
}

# 5. Cloud DMS Backup-Seeded Continuous Migration Job (GCS dump_path + Binlog CDC)
module "dms_migration_job" {
  source = "../../modules/dms-migration-job"

  project_id                     = var.project_id
  region                         = var.region
  migration_job_id               = var.migration_job_id
  display_name                   = "GCS Backup ${var.dump_type} to Cloud SQL ${replace(var.target_database_version, "_", " ")} CDC"
  migration_type                 = "CONTINUOUS"
  destination_mode               = var.destination_mode
  source_connection_profile      = module.dms_connection_profiles.source_connection_profile_name
  destination_connection_profile = module.dms_connection_profiles.destination_connection_profile_name
  dump_type                      = var.dump_type
  dump_path                      = "${module.gcs_migration_staging.bucket_url}/${var.backup_object_path}"
  connectivity_method            = var.connectivity_method
  vpc_peering_network            = var.network
  reverse_ssh_vm_ip              = var.reverse_ssh_vm_ip
  reverse_ssh_vm                 = var.reverse_ssh_vm
  reverse_ssh_vpc                = var.network
  labels                         = var.labels
}
