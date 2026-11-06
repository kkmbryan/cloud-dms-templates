# ==============================================================================
# Plan-only tests for Scenario 1 (terraform test, no Google Cloud credentials).
#
# The google provider is mocked. override_during = plan makes the mocked
# computed values (service attachment link, self links, subnet CIDR) known at
# plan time, so the derived values (ACCEPT_MANUAL accept list, firewall source
# range) can be asserted. terraform_data local-exec steps only run on apply,
# so every run uses command = plan.
#
# Run: terraform init -backend=false && terraform test
# ==============================================================================

mock_provider "google" {
  override_during = plan

  mock_resource "google_sql_database_instance" {
    defaults = {
      psc_service_attachment_link   = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
      dns_name                      = "abc123.def456.europe-west2.sql.goog."
      connection_name               = "my-gcp-project-01:europe-west2:cloudsql-mysql-dest-live-01"
      self_link                     = "https://sqladmin.googleapis.com/sql/v1beta4/projects/my-gcp-project-01/instances/cloudsql-mysql-dest-live-01"
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
      self_link = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/addresses/cloudsql-mysql-dest-live-01-psc-ip"
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

  mock_data "google_project" {
    defaults = {
      number = "123456789012"
    }
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
}

# ------------------------------------------------------------------------------
# Defaults: PSC + EXISTING_CLOUDSQL + ACCEPT_MANUAL
# ------------------------------------------------------------------------------
run "psc_existing_cloudsql_defaults" {
  command = plan

  assert {
    condition     = output.connectivity_type == "PSC"
    error_message = "Default connectivity_type must be PSC."
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == "cloudsql-mysql-dest-live-01"
    error_message = "EXISTING_CLOUDSQL must create the Cloud SQL instance."
  }

  assert {
    condition     = output.cloudsql_psc_service_attachment == "projects/example-tp/regions/europe-west2/serviceAttachments/a"
    error_message = "The instance service attachment link must be exported."
  }

  assert {
    condition     = output.network_attachment_producer_accept_list == tolist(["example-tp"])
    error_message = "ACCEPT_MANUAL accept list must be exactly the tenant project parsed from the service attachment link."
  }

  assert {
    condition     = output.network_attachment_self_link != null
    error_message = "The Network Attachment must be created while migration_enabled = true."
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
    error_message = "Connection profiles and migration job must be planned while migration_enabled = true."
  }

  assert {
    condition     = output.migration_job_id == "gce-live-mysql80-cdc"
    error_message = "Default migration job ID changed."
  }
}

# ------------------------------------------------------------------------------
# Explicit accept list override
# ------------------------------------------------------------------------------
run "psc_accept_list_override" {
  command = plan

  variables {
    psc_producer_accept_list = ["override-tenant-project"]
  }

  assert {
    condition     = output.network_attachment_producer_accept_list == tolist(["override-tenant-project"])
    error_message = "psc_producer_accept_list must replace the derived tenant project."
  }
}

run "psc_accept_automatic_has_no_accept_list" {
  command = plan

  variables {
    psc_connection_preference = "ACCEPT_AUTOMATIC"
  }

  assert {
    condition     = output.network_attachment_producer_accept_list == null
    error_message = "ACCEPT_AUTOMATIC must not set a producer accept list."
  }
}

# ------------------------------------------------------------------------------
# PSA: no Network Attachment, no firewall rule, no PSC endpoint
# ------------------------------------------------------------------------------
run "psa_existing_cloudsql" {
  command = plan

  variables {
    connectivity_type = "PSA"
  }

  assert {
    condition     = output.connectivity_type == "PSA"
    error_message = "connectivity_type must be PSA."
  }

  assert {
    condition     = output.network_attachment_self_link == null && output.source_firewall_rule_name == null
    error_message = "PSA must not create a Network Attachment or the PSC source firewall rule."
  }

  assert {
    condition     = output.psc_endpoint_ip_address == null
    error_message = "PSA must not create a PSC consumer endpoint."
  }

  assert {
    condition     = module.networking.psa_private_network_link == var.network
    error_message = "PSA without create_psa_peering must use var.network as the private network."
  }
}

# ------------------------------------------------------------------------------
# DMS_MANAGED_CLOUDSQL: no Terraform instance, no NA, DMS-managed profile
# ------------------------------------------------------------------------------
run "dms_managed_cloudsql" {
  command = plan

  variables {
    destination_mode = "DMS_MANAGED_CLOUDSQL"
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == null
    error_message = "DMS_MANAGED_CLOUDSQL must not create the Cloud SQL instance in Terraform."
  }

  assert {
    condition     = output.network_attachment_self_link == null && output.source_firewall_rule_name == null
    error_message = "DMS_MANAGED_CLOUDSQL must not create the Network Attachment or the firewall rule."
  }

  assert {
    condition     = output.psc_endpoint_ip_address == null
    error_message = "DMS_MANAGED_CLOUDSQL must not create a PSC consumer endpoint."
  }

  assert {
    condition     = length(module.dms_connection_profiles) == 1 && length(module.dms_migration_job) == 1
    error_message = "DMS_MANAGED_CLOUDSQL must still plan the profiles and the migration job."
  }
}

# ------------------------------------------------------------------------------
# migration_enabled = false (post-cutover): migration objects removed, Cloud SQL
# instance and PSC endpoint kept
# ------------------------------------------------------------------------------
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
    condition     = output.migration_job_name == null && output.source_connection_profile_name == null
    error_message = "migration_enabled = false must not export job or profile names."
  }

  assert {
    condition     = output.network_attachment_self_link == null && output.source_firewall_rule_name == null
    error_message = "migration_enabled = false must remove the Network Attachment and the source firewall rule."
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == "cloudsql-mysql-dest-live-01"
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
# Input validation
# ------------------------------------------------------------------------------
run "bare_subnet_name_rejected" {
  command = plan

  variables {
    subnet = "my-subnet"
  }

  expect_failures = [var.subnet]
}

run "self_link_subnet_accepted" {
  command = plan

  variables {
    subnet = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/subnetworks/my-subnet"
  }

  assert {
    condition     = output.network_attachment_self_link != null
    error_message = "A subnetwork self-link must be accepted."
  }
}

run "invalid_target_version_rejected" {
  command = plan

  variables {
    target_database_version = "MYSQL_5_7"
  }

  expect_failures = [var.target_database_version]
}

run "invalid_migration_job_id_rejected" {
  command = plan

  variables {
    migration_job_id = "Live_Job"
  }

  expect_failures = [var.migration_job_id]
}

run "migration_job_id_trailing_hyphen_rejected" {
  command = plan

  variables {
    migration_job_id = "live-job-"
  }

  expect_failures = [var.migration_job_id]
}

run "invalid_instance_name_rejected" {
  command = plan

  variables {
    cloudsql_instance_name = "1-starts-with-a-digit"
  }

  expect_failures = [var.cloudsql_instance_name]
}

run "instance_name_too_long_rejected" {
  command = plan

  variables {
    cloudsql_instance_name = "a-cloud-sql-instance-name-that-is-longer-than-fifty-chars"
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
    cloudsql_edition                        = "ENTERPRISE"
    cloudsql_tier                           = "db-perf-optimized-N-8"
    cloudsql_transaction_log_retention_days = 7
  }

  expect_failures = [var.cloudsql_tier]
}

run "enterprise_custom_tier_accepted" {
  command = plan

  variables {
    cloudsql_edition = "ENTERPRISE"
    cloudsql_tier    = "db-custom-4-16384"
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == "cloudsql-mysql-dest-live-01"
    error_message = "ENTERPRISE with a db-custom tier must be accepted."
  }
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

run "enterprise_plus_retention_35_accepted" {
  command = plan

  variables {
    cloudsql_transaction_log_retention_days = 35
  }

  assert {
    condition     = module.cloudsql_destination.instance_name == "cloudsql-mysql-dest-live-01"
    error_message = "ENTERPRISE_PLUS must accept 35 days of transaction log retention."
  }
}

run "enterprise_plus_retention_over_35_rejected" {
  command = plan

  variables {
    cloudsql_transaction_log_retention_days = 36
  }

  expect_failures = [var.cloudsql_transaction_log_retention_days]
}

run "retained_backups_zero_rejected" {
  command = plan

  variables {
    cloudsql_retained_backups = 0
  }

  expect_failures = [var.cloudsql_retained_backups]
}

run "retained_backups_over_365_rejected" {
  command = plan

  variables {
    cloudsql_retained_backups = 366
  }

  expect_failures = [var.cloudsql_retained_backups]
}

# ------------------------------------------------------------------------------
# Selective migration and dump flags (wired into the migration job)
# ------------------------------------------------------------------------------
run "migration_databases_and_dump_flags_accepted" {
  command = plan

  variables {
    migration_databases = ["app_db", "billing"]
    dump_flags = [
      { name = "single-transaction", value = "true" },
    ]
  }

  assert {
    condition     = length(module.dms_migration_job) == 1 && output.migration_job_id == "gce-live-mysql80-cdc"
    error_message = "migration_databases and dump_flags must be accepted by the template."
  }
}
