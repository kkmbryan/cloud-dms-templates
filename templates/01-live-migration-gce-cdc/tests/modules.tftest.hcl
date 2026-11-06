# ==============================================================================
# Plan-only tests for the shared modules' preconditions and validations.
#
# expect_failures can only reference checkable objects of the module under
# test, so preconditions inside child modules (firewall target, PSC subnet,
# source TLS, migration job dump settings) are tested here by pointing each run
# at the module directly (run { module { source = ... } }). The template-level
# wiring is covered by plan.tftest.hcl.
# ==============================================================================

mock_provider "google" {
  override_during = plan

  mock_resource "google_compute_network_attachment" {
    defaults = {
      id        = "projects/my-gcp-project-01/regions/europe-west2/networkAttachments/dms-mysql-psc-na"
      self_link = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/networkAttachments/dms-mysql-psc-na"
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

# ------------------------------------------------------------------------------
# modules/networking-psc
# ------------------------------------------------------------------------------
run "networking_accept_manual_derives_tenant_project" {
  command = plan

  module {
    source = "../../modules/networking-psc"
  }

  variables {
    project_id                           = "my-gcp-project-01"
    region                               = "europe-west2"
    network                              = "projects/my-gcp-project-01/global/networks/my-vpc"
    subnet                               = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
    cloudsql_psc_service_attachment_link = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
    source_target_tags                   = ["mysql-source"]
  }

  assert {
    condition     = google_compute_network_attachment.dms_psc[0].producer_accept_lists == tolist(["example-tp"])
    error_message = "ACCEPT_MANUAL must accept only the tenant project parsed from the service attachment link."
  }

  assert {
    condition     = google_compute_network_attachment.dms_psc[0].connection_preference == "ACCEPT_MANUAL"
    error_message = "ACCEPT_MANUAL must be the default connection preference."
  }

  assert {
    condition     = google_compute_firewall.na_to_source[0].source_ranges == toset(["10.20.0.0/28"])
    error_message = "The firewall rule must trust only the Network Attachment subnet CIDR."
  }

  assert {
    condition     = google_compute_firewall.na_to_source[0].direction == "INGRESS" && one(google_compute_firewall.na_to_source[0].allow).ports == tolist(["3306"])
    error_message = "The firewall rule must allow INGRESS tcp:3306 only."
  }

  assert {
    condition     = one(google_compute_firewall.na_to_source[0].log_config).metadata == "INCLUDE_ALL_METADATA"
    error_message = "Firewall logging must be on."
  }
}

run "networking_accept_manual_without_tenant_rejected" {
  command = plan

  module {
    source = "../../modules/networking-psc"
  }

  variables {
    project_id                  = "my-gcp-project-01"
    region                      = "europe-west2"
    network                     = "projects/my-gcp-project-01/global/networks/my-vpc"
    subnet                      = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
    create_source_firewall_rule = false
  }

  expect_failures = [google_compute_network_attachment.dms_psc]
}

run "networking_missing_subnet_rejected" {
  command = plan

  module {
    source = "../../modules/networking-psc"
  }

  variables {
    project_id                           = "my-gcp-project-01"
    region                               = "europe-west2"
    network                              = "projects/my-gcp-project-01/global/networks/my-vpc"
    cloudsql_psc_service_attachment_link = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
    create_source_firewall_rule          = false
  }

  expect_failures = [google_compute_network_attachment.dms_psc]
}

run "networking_firewall_tags_and_service_accounts_rejected" {
  command = plan

  module {
    source = "../../modules/networking-psc"
  }

  variables {
    project_id                           = "my-gcp-project-01"
    region                               = "europe-west2"
    network                              = "projects/my-gcp-project-01/global/networks/my-vpc"
    subnet                               = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
    cloudsql_psc_service_attachment_link = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
    source_target_tags                   = ["mysql-source"]
    source_target_service_accounts       = ["mysql-source@my-gcp-project-01.iam.gserviceaccount.com"]
  }

  expect_failures = [google_compute_firewall.na_to_source]
}

run "networking_firewall_without_target_rejected" {
  command = plan

  module {
    source = "../../modules/networking-psc"
  }

  variables {
    project_id                           = "my-gcp-project-01"
    region                               = "europe-west2"
    network                              = "projects/my-gcp-project-01/global/networks/my-vpc"
    subnet                               = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
    cloudsql_psc_service_attachment_link = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
  }

  expect_failures = [google_compute_firewall.na_to_source]
}

run "networking_firewall_service_account_target" {
  command = plan

  module {
    source = "../../modules/networking-psc"
  }

  variables {
    project_id                           = "my-gcp-project-01"
    region                               = "europe-west2"
    network                              = "projects/my-gcp-project-01/global/networks/my-vpc"
    subnet                               = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
    cloudsql_psc_service_attachment_link = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
    source_target_service_accounts       = ["mysql-source@my-gcp-project-01.iam.gserviceaccount.com"]
  }

  assert {
    condition     = google_compute_firewall.na_to_source[0].target_service_accounts == toset(["mysql-source@my-gcp-project-01.iam.gserviceaccount.com"]) && google_compute_firewall.na_to_source[0].target_tags == null
    error_message = "A service-account target alone must be accepted and used without tags."
  }
}

# ------------------------------------------------------------------------------
# modules/dms-connection-profiles
# ------------------------------------------------------------------------------
run "profiles_server_only_without_ca_rejected" {
  command = plan

  module {
    source = "../../modules/dms-connection-profiles"
  }

  variables {
    project_id               = "my-gcp-project-01"
    region                   = "europe-west2"
    source_host              = "10.10.0.2"
    source_username          = "dms_migration"
    source_password          = "example-source-password"
    destination_cloud_sql_id = "cloudsql-mysql-dest-live-01"
    source_ssl_type          = "SERVER_ONLY"
  }

  expect_failures = [google_database_migration_service_connection_profile.source]
}

run "profiles_server_client_without_client_cert_rejected" {
  command = plan

  module {
    source = "../../modules/dms-connection-profiles"
  }

  variables {
    project_id                = "my-gcp-project-01"
    region                    = "europe-west2"
    source_host               = "10.10.0.2"
    source_username           = "dms_migration"
    source_password           = "example-source-password"
    destination_cloud_sql_id  = "cloudsql-mysql-dest-live-01"
    source_ssl_type           = "SERVER_CLIENT"
    source_ssl_ca_certificate = "-----BEGIN CERTIFICATE-----\nPLACEHOLDER\n-----END CERTIFICATE-----\n"
  }

  expect_failures = [google_database_migration_service_connection_profile.source]
}

run "profiles_server_only_with_ca" {
  command = plan

  module {
    source = "../../modules/dms-connection-profiles"
  }

  variables {
    project_id                = "my-gcp-project-01"
    region                    = "europe-west2"
    source_host               = "10.10.0.2"
    source_username           = "dms_migration"
    source_password           = "example-source-password"
    destination_cloud_sql_id  = "cloudsql-mysql-dest-live-01"
    source_ssl_type           = "SERVER_ONLY"
    source_ssl_ca_certificate = "-----BEGIN CERTIFICATE-----\nPLACEHOLDER\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition     = one(one(google_database_migration_service_connection_profile.source.mysql).ssl).type == "SERVER_ONLY"
    error_message = "SERVER_ONLY with a CA certificate must be accepted."
  }

  assert {
    condition     = length(google_database_migration_service_connection_profile.destination_existing) == 1 && length(google_database_migration_service_connection_profile.destination) == 0
    error_message = "EXISTING_CLOUDSQL must create only the cloud_sql_id destination profile."
  }
}

run "profiles_password_longer_than_32_rejected" {
  command = plan

  module {
    source = "../../modules/dms-connection-profiles"
  }

  variables {
    project_id               = "my-gcp-project-01"
    region                   = "europe-west2"
    source_host              = "10.10.0.2"
    source_username          = "dms_migration"
    source_password          = "this-placeholder-password-is-longer-than-32-chars"
    destination_cloud_sql_id = "cloudsql-mysql-dest-live-01"
  }

  expect_failures = [var.source_password]
}

run "profiles_display_name_with_underscore_rejected" {
  command = plan

  module {
    source = "../../modules/dms-connection-profiles"
  }

  variables {
    project_id               = "my-gcp-project-01"
    region                   = "europe-west2"
    source_host              = "10.10.0.2"
    source_username          = "dms_migration"
    source_password          = "example-source-password"
    destination_cloud_sql_id = "cloudsql-mysql-dest-live-01"
    source_display_name      = "MySQL_8.0 (source)"
  }

  expect_failures = [var.source_display_name]
}

# ------------------------------------------------------------------------------
# modules/dms-migration-job
# ------------------------------------------------------------------------------
run "job_selective_databases_and_dump_flags" {
  command = plan

  module {
    source = "../../modules/dms-migration-job"
  }

  variables {
    project_id                     = "my-gcp-project-01"
    region                         = "europe-west2"
    source_connection_profile      = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/src"
    destination_connection_profile = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/dest"
    databases                      = ["app_db", "billing"]
    dump_flags = [
      { name = "single-transaction", value = "true" },
    ]
  }

  assert {
    condition     = one(one(google_database_migration_service_migration_job.migration.objects_config).source_objects_config).objects_selection_type == "SPECIFIED_OBJECTS"
    error_message = "databases must set objects_selection_type = SPECIFIED_OBJECTS."
  }

  assert {
    condition = [
      for c in one(one(google_database_migration_service_migration_job.migration.objects_config).source_objects_config).object_configs :
      one(c.object_identifier).database
      ] == ["app_db", "billing"] && alltrue([
        for c in one(one(google_database_migration_service_migration_job.migration.objects_config).source_objects_config).object_configs :
        one(c.object_identifier).type == "DATABASE"
    ])
    error_message = "databases must become DATABASE object identifiers, in order."
  }

  assert {
    condition     = one(one(google_database_migration_service_migration_job.migration.dump_flags).dump_flags).name == "single-transaction"
    error_message = "dump_flags must be passed to the migration job."
  }

  assert {
    condition     = one(google_database_migration_service_migration_job.migration.performance_config).dump_parallel_level == "OPTIMAL"
    error_message = "The DMS-managed dump must keep performance_config."
  }
}

run "job_all_databases_by_default" {
  command = plan

  module {
    source = "../../modules/dms-migration-job"
  }

  variables {
    project_id                     = "my-gcp-project-01"
    region                         = "europe-west2"
    source_connection_profile      = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/src"
    destination_connection_profile = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/dest"
  }

  assert {
    condition     = length(google_database_migration_service_migration_job.migration.objects_config) == 0
    error_message = "Without databases the job must not restrict the migrated objects."
  }
}

run "job_invalid_database_name_rejected" {
  command = plan

  module {
    source = "../../modules/dms-migration-job"
  }

  variables {
    project_id                     = "my-gcp-project-01"
    region                         = "europe-west2"
    source_connection_profile      = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/src"
    destination_connection_profile = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/dest"
    databases                      = ["app db; drop"]
  }

  expect_failures = [var.databases]
}

run "job_physical_without_dump_path_rejected" {
  command = plan

  module {
    source = "../../modules/dms-migration-job"
  }

  variables {
    project_id                     = "my-gcp-project-01"
    region                         = "europe-west2"
    source_connection_profile      = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/src"
    destination_connection_profile = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/dest"
    dump_type                      = "PHYSICAL"
  }

  expect_failures = [google_database_migration_service_migration_job.migration]
}

run "job_databases_with_dump_path_rejected" {
  command = plan

  module {
    source = "../../modules/dms-migration-job"
  }

  variables {
    project_id                     = "my-gcp-project-01"
    region                         = "europe-west2"
    source_connection_profile      = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/src"
    destination_connection_profile = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/dest"
    dump_path                      = "gs://my-dms-staging-bucket/mysqldump/mysql80-dump.sql.gz"
    databases                      = ["app_db"]
  }

  expect_failures = [google_database_migration_service_migration_job.migration]
}

run "job_display_name_with_dot_rejected" {
  command = plan

  module {
    source = "../../modules/dms-migration-job"
  }

  variables {
    project_id                     = "my-gcp-project-01"
    region                         = "europe-west2"
    source_connection_profile      = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/src"
    destination_connection_profile = "projects/my-gcp-project-01/locations/europe-west2/connectionProfiles/dest"
    display_name                   = "MySQL 8.0 to Cloud SQL"
  }

  expect_failures = [var.display_name]
}
