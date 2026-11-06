# ==============================================================================
# Plan-only tests for examples/multi-database (terraform test, no credentials).
#
# The google provider is mocked with override_during = plan so the mocked
# service attachment links, subnet CIDR and endpoint addresses are known at
# plan time. terraform_data local-exec steps only run on apply.
#
# Run: terraform init -backend=false && terraform test
# ==============================================================================

mock_provider "google" {
  override_during = plan

  mock_resource "google_sql_database_instance" {
    defaults = {
      psc_service_attachment_link   = "projects/example-tp/regions/europe-west2/serviceAttachments/a"
      dns_name                      = "abc123.def456.europe-west2.sql.goog."
      service_account_email_address = "p000000000000-abcdef@gcp-sa-cloud-sql.iam.gserviceaccount.com"
    }
  }

  mock_resource "google_compute_network_attachment" {
    defaults = {
      id        = "projects/my-gcp-project-01/regions/europe-west2/networkAttachments/dms-multi-psc-na"
      self_link = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/networkAttachments/dms-multi-psc-na"
    }
  }

  mock_resource "google_compute_address" {
    defaults = {
      address   = "10.10.0.10"
      self_link = "https://www.googleapis.com/compute/v1/projects/my-gcp-project-01/regions/europe-west2/addresses/mock-psc-ip"
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

variables {
  project_id                = "my-gcp-project-01"
  region                    = "europe-west2"
  network                   = "projects/my-gcp-project-01/global/networks/my-vpc"
  psc_endpoint_subnet       = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/my-app-subnet"
  network_attachment_subnet = "projects/my-gcp-project-01/regions/europe-west2/subnetworks/dms-psc-na-subnet"
  source_target_tags        = ["mysql-source"]

  migrations = {
    "orders-cdc" = {
      instance_name = "cloudsql-orders-01"
      source_host   = "10.10.0.2"
      databases     = ["orders"]
    }
    "billing-cdc" = {
      instance_name = "cloudsql-billing-01"
      source_host   = "10.10.0.2"
      databases     = ["billing"]
    }
  }

  source_passwords = {
    "orders-cdc"  = "example-source-password"
    "billing-cdc" = "example-source-password"
  }

  cloudsql_root_passwords = {
    "orders-cdc"  = "example-root-password"
    "billing-cdc" = "example-root-password"
  }
}

run "two_migrations_share_one_attachment" {
  command = plan

  assert {
    condition     = length(module.destination) == 2
    error_message = "Two migrations must create two Cloud SQL destinations."
  }

  assert {
    condition     = output.cloudsql_instance_names == { "billing-cdc" = "cloudsql-billing-01", "orders-cdc" = "cloudsql-orders-01" }
    error_message = "Instance names must be keyed by migration job ID."
  }

  assert {
    condition     = length([for k, o in module.psc_outbound : k if o.network_attachment_uri != null]) == 2
    error_message = "Each destination must get its own outbound attach step."
  }

  assert {
    condition     = output.network_attachment_self_link != null
    error_message = "One shared Network Attachment must be created."
  }

  assert {
    condition     = output.network_attachment_producer_accept_list == tolist(["example-tp"])
    error_message = "The accept list must hold the distinct tenant projects of the instances."
  }

  assert {
    condition     = module.networking.source_firewall_rule_name == "dms-multi-psc-na-to-source"
    error_message = "One shared source firewall rule must be created."
  }

  assert {
    condition     = length(google_dns_managed_zone.sql_goog) == 1
    error_message = "One private DNS zone must be created."
  }

  assert {
    condition     = length([for k, e in module.psc_endpoint : k if e.dns_name != null]) == 2
    error_message = "Each instance must get its own DNS record."
  }

  assert {
    condition     = length(module.profiles) == 2 && length(module.job) == 2
    error_message = "Each migration must get its own profiles and job."
  }

  assert {
    condition     = toset(output.migration_job_ids) == toset(["orders-cdc", "billing-cdc"])
    error_message = "Migration job IDs must be the migrations keys."
  }
}

run "existing_dns_zone_is_reused" {
  command = plan

  variables {
    existing_dns_zone_name = "shared-sql-goog"
  }

  assert {
    condition     = length(google_dns_managed_zone.sql_goog) == 0 && output.dns_zone_name == "shared-sql-goog"
    error_message = "existing_dns_zone_name must reuse the zone instead of creating one."
  }
}

run "migration_disabled_keeps_instances_and_endpoints" {
  command = plan

  variables {
    migration_enabled = false
  }

  assert {
    condition     = length(module.profiles) == 0 && length(module.job) == 0
    error_message = "migration_enabled = false must remove all profiles and jobs."
  }

  assert {
    condition     = output.network_attachment_self_link == null && module.networking.source_firewall_rule_name == null
    error_message = "migration_enabled = false must remove the shared Network Attachment and firewall rule."
  }

  assert {
    condition     = length([for k, o in module.psc_outbound : k if o.network_attachment_uri != null]) == 0
    error_message = "migration_enabled = false must detach every instance."
  }

  assert {
    condition     = length(module.destination) == 2 && length([for k, e in module.psc_endpoint : k if e.endpoint_ip_address != null]) == 2
    error_message = "migration_enabled = false must keep the instances and PSC endpoints."
  }
}

run "duplicate_instance_name_rejected" {
  command = plan

  variables {
    migrations = {
      "orders-cdc" = {
        instance_name = "cloudsql-shared-01"
        source_host   = "10.10.0.2"
        databases     = ["orders"]
      }
      "billing-cdc" = {
        instance_name = "cloudsql-shared-01"
        source_host   = "10.10.0.2"
        databases     = ["billing"]
      }
    }
  }

  expect_failures = [var.migrations]
}

run "invalid_job_id_key_rejected" {
  command = plan

  variables {
    migrations = {
      "Orders_CDC" = {
        instance_name = "cloudsql-orders-01"
        source_host   = "10.10.0.2"
      }
    }
    source_passwords        = { "Orders_CDC" = "example-source-password" }
    cloudsql_root_passwords = { "Orders_CDC" = "example-root-password" }
  }

  expect_failures = [var.migrations]
}

run "perf_optimized_tier_needs_enterprise_plus" {
  command = plan

  variables {
    migrations = {
      "orders-cdc" = {
        instance_name = "cloudsql-orders-01"
        source_host   = "10.10.0.2"
        edition       = "ENTERPRISE"
      }
    }
    source_passwords        = { "orders-cdc" = "example-source-password" }
    cloudsql_root_passwords = { "orders-cdc" = "example-root-password" }
  }

  expect_failures = [var.migrations]
}

run "bare_endpoint_subnet_rejected" {
  command = plan

  variables {
    psc_endpoint_subnet = "my-app-subnet"
  }

  expect_failures = [var.psc_endpoint_subnet]
}
