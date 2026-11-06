# ==============================================================================
# Plan-only tests for Scenario 2 (terraform test, no Google Cloud credentials).
#
# The google provider is mocked. override_during = plan makes the mocked
# computed values (service attachment link, project number, subnet CIDR) known
# at plan time so derived values can be asserted. terraform_data local-exec
# steps only run on apply, so every run uses command = plan. Module
# preconditions are covered by templates/01-live-migration-gce-cdc/tests.
#
# Run: terraform init -backend=false && terraform test
# ==============================================================================

mock_provider "google" {
  override_during = plan

  mock_resource "google_sql_database_instance" {
    defaults = {
      psc_service_attachment_link   = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
      dns_name                      = "abc123.def456.europe-west2.sql.goog."
      connection_name               = "my-gcp-project-01:europe-west2:cloudsql-mysql-dest-bkp-01"
      self_link                     = "https://sqladmin.googleapis.com/sql/v1beta4/projects/my-gcp-project-01/instances/cloudsql-mysql-dest-bkp-01"
      service_account_email_address = "p000000000000-abcdef@gcp-sa-cloud-sql.iam.gserviceaccount.com"
      private_ip_address            = "10.10.0.3"
    }
  }

  mock_resource "google_compute_network_attachment" {
    defaults = {
      id        = "projects/my-gcp-project-01/regions/europe-west2/networkAttachments/dms-mysql-psc-na"
      self_link = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/networkAttachments/dms-mysql-psc-na"
    }
  }

  mock_resource "google_compute_address" {
    defaults = {
      address   = "10.10.0.10"
      self_link = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/addresses/cloudsql-mysql-dest-bkp-01-psc-ip"
    }
  }

  mock_resource "google_storage_bucket" {
    defaults = {
      self_link = "https://www.googleapis.com/storage/v1/b/my-dms-staging-bucket"
      url       = "gs://my-dms-staging-bucket"
    }
  }

  mock_resource "google_database_migration_service_connection_profile" {
    defaults = {
      name = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/mock-profile"
    }
  }

  mock_data "google_compute_subnetwork" {
    defaults = {
      ip_cidr_range = "10.20.0.0/28"
      self_link     = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
    }
  }
}

# The project number drives the DMS service agent email.
override_data {
  target = data.google_project.this
  values = {
    number     = "123456789012"
    project_id = "my-gcp-project-01"
  }
}

variables {
  project_id                = "my-gcp-project-01"
  region                    = "europe-west2"
  network                   = "projects/my-gcp-project-01/global/networks/my-vpc"
  subnet                    = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/my-subnet"
  network_attachment_subnet = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
  source_target_tags        = ["mysql-source"]
  source_gce_mysql_host     = "10.10.0.2"
  source_gce_mysql_password = "example-source-password"
  cloudsql_root_password    = "example-root-password"
  staging_bucket_name       = "my-dms-staging-bucket"
}

# ------------------------------------------------------------------------------
# Defaults: LOGICAL mysqldump seed, PSC + EXISTING_CLOUDSQL + ACCEPT_MANUAL
# ------------------------------------------------------------------------------
run "logical_psc_existing_cloudsql_defaults" {
  command = plan

  assert {
    condition     = output.configured_dump_path == "gs://my-dms-staging-bucket/mysqldump/mysql80-dump.sql.gz"
    error_message = "configured_dump_path must be gs://<bucket>/<backup_gcs_path>."
  }

  assert {
    condition     = output.dms_service_agent == "serviceAccount:service-123456789012@gcp-sa-datamigration.iam.gserviceaccount.com"
    error_message = "The DMS service agent must be derived from the project number."
  }

  assert {
    condition     = output.network_attachment_producer_accept_list == tolist(["example-tp"])
    error_message = "ACCEPT_MANUAL accept list must be exactly the tenant project parsed from the service attachment link."
  }

  assert {
    condition     = output.source_firewall_rule_name == "dms-mysql-psc-na-to-source"
    error_message = "The source firewall rule must be created with the default name."
  }

  assert {
    condition     = output.psc_endpoint_ip_address == "10.10.0.10"
    error_message = "The PSC consumer endpoint must be created for EXISTING_CLOUDSQL + PSC."
  }

  assert {
    condition     = length(module.dms_connection_profiles) == 1 && length(module.dms_migration_job) == 1
    error_message = "Connection profiles and migration job must be planned by default."
  }

  assert {
    condition     = output.migration_job_id == "gcs-bkp-mysql80-cdc"
    error_message = "Default migration job ID changed."
  }
}

run "physical_mysql80_folder_accepted" {
  command = plan

  variables {
    dump_type               = "PHYSICAL"
    target_database_version = "MYSQL_8_0"
    backup_gcs_path         = "xtrabackup/mysql80-full"
  }

  assert {
    condition     = output.configured_dump_path == "gs://my-dms-staging-bucket/xtrabackup/mysql80-full"
    error_message = "PHYSICAL must use the XtraBackup folder as dump_path."
  }

  assert {
    condition     = length(module.dms_migration_job) == 1
    error_message = "PHYSICAL + MYSQL_8_0 must plan the migration job."
  }
}

# ------------------------------------------------------------------------------
# Seed validations
# ------------------------------------------------------------------------------
run "physical_mysql84_rejected" {
  command = plan

  variables {
    dump_type               = "PHYSICAL"
    target_database_version = "MYSQL_8_4"
    backup_gcs_path         = "xtrabackup/mysql80-full"
  }

  expect_failures = [var.dump_type]
}

run "physical_file_path_rejected" {
  command = plan

  variables {
    dump_type               = "PHYSICAL"
    target_database_version = "MYSQL_8_0"
    backup_gcs_path         = "xtrabackup/mysql80-full.xbstream"
  }

  expect_failures = [var.backup_gcs_path]
}

run "backup_path_trailing_slash_rejected" {
  command = plan

  variables {
    dump_type               = "PHYSICAL"
    target_database_version = "MYSQL_8_0"
    backup_gcs_path         = "xtrabackup/mysql80-full/"
  }

  expect_failures = [var.backup_gcs_path]
}

run "backup_path_gs_prefix_rejected" {
  command = plan

  variables {
    backup_gcs_path = "gs://my-dms-staging-bucket/mysqldump/mysql80-dump.sql.gz"
  }

  expect_failures = [var.backup_gcs_path]
}

# ------------------------------------------------------------------------------
# Two-phase apply and post-cutover cleanup
# ------------------------------------------------------------------------------
run "first_phase_without_migration_job" {
  command = plan

  variables {
    create_migration_job = false
  }

  assert {
    condition     = length(module.dms_migration_job) == 0 && output.migration_job_name == null
    error_message = "create_migration_job = false must not plan the migration job."
  }

  assert {
    condition     = length(module.dms_connection_profiles) == 1
    error_message = "create_migration_job = false must still plan the connection profiles."
  }

  assert {
    condition     = output.staging_bucket_name == "my-dms-staging-bucket"
    error_message = "The staging bucket must be created in the first phase."
  }
}

run "migration_disabled_keeps_instance_and_endpoint" {
  command = plan

  variables {
    migration_enabled = false
  }

  assert {
    condition     = length(module.dms_connection_profiles) == 0 && length(module.dms_migration_job) == 0
    error_message = "migration_enabled = false must remove the connection profiles and the migration job."
  }

  assert {
    condition     = output.network_attachment_self_link == null && output.source_firewall_rule_name == null
    error_message = "migration_enabled = false must remove the Network Attachment and the source firewall rule."
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == "cloudsql-mysql-dest-bkp-01"
    error_message = "migration_enabled = false must keep the Cloud SQL instance."
  }

  assert {
    condition     = output.psc_endpoint_ip_address == "10.10.0.10"
    error_message = "migration_enabled = false must keep the PSC consumer endpoint."
  }
}

run "dms_managed_with_migration_disabled_rejected" {
  command = plan

  variables {
    destination_mode  = "DMS_MANAGED_CLOUDSQL"
    migration_enabled = false
  }

  expect_failures = [var.migration_enabled]
}

# ------------------------------------------------------------------------------
# Connectivity and destination modes
# ------------------------------------------------------------------------------
run "psa_existing_cloudsql" {
  command = plan

  variables {
    connectivity_type = "PSA"
  }

  assert {
    condition     = output.network_attachment_self_link == null && output.source_firewall_rule_name == null && output.psc_endpoint_ip_address == null
    error_message = "PSA must not create PSC resources."
  }
}

run "dms_managed_cloudsql" {
  command = plan

  variables {
    destination_mode = "DMS_MANAGED_CLOUDSQL"
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == null && output.network_attachment_self_link == null
    error_message = "DMS_MANAGED_CLOUDSQL must not create the instance or the Network Attachment in Terraform."
  }

  assert {
    condition     = length(module.dms_migration_job) == 1
    error_message = "DMS_MANAGED_CLOUDSQL must still plan the migration job."
  }
}

# ------------------------------------------------------------------------------
# Input validation
# ------------------------------------------------------------------------------
run "bare_subnet_name_rejected" {
  command = plan

  variables {
    subnet = "my-subnet"
  }

  expect_failures = [var.subnet]
}

run "invalid_migration_job_id_rejected" {
  command = plan

  variables {
    migration_job_id = "Backup_Job"
  }

  expect_failures = [var.migration_job_id]
}

run "invalid_instance_name_rejected" {
  command = plan

  variables {
    cloudsql_instance_name = "instance-name-ending-with-hyphen-"
  }

  expect_failures = [var.cloudsql_instance_name]
}

run "invalid_edition_rejected" {
  command = plan

  variables {
    cloudsql_edition = "STANDARD"
  }

  expect_failures = [var.cloudsql_edition]
}

run "perf_optimized_tier_needs_enterprise_plus" {
  command = plan

  variables {
    cloudsql_edition = "ENTERPRISE"
    cloudsql_tier    = "db-perf-optimized-N-8"
  }

  expect_failures = [var.cloudsql_tier]
}

run "invalid_availability_type_rejected" {
  command = plan

  variables {
    cloudsql_availability_type = "MULTI_REGIONAL"
  }

  expect_failures = [var.cloudsql_availability_type]
}

run "enterprise_retention_over_7_rejected" {
  command = plan

  variables {
    cloudsql_edition                        = "ENTERPRISE"
    cloudsql_tier                           = "db-custom-4-16384"
    cloudsql_transaction_log_retention_days = 8
  }

  expect_failures = [var.cloudsql_transaction_log_retention_days]
}

run "enterprise_plus_retention_over_35_rejected" {
  command = plan

  variables {
    cloudsql_transaction_log_retention_days = 36
  }

  expect_failures = [var.cloudsql_transaction_log_retention_days]
}

run "retained_backups_over_365_rejected" {
  command = plan

  variables {
    cloudsql_retained_backups = 366
  }

  expect_failures = [var.cloudsql_retained_backups]
}
