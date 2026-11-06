locals {
  use_existing_cloudsql = var.destination_mode == "EXISTING_CLOUDSQL"
}

# ------------------------------------------------------------------------------
# Source connection profile (both destination modes)
#
# Native resource: the source password is sent to the DMS API by the provider
# and never appears on a command line or in the process list.
# Note: the password is still stored (marked sensitive) in Terraform state, so
# protect the state backend.
# ------------------------------------------------------------------------------

resource "google_database_migration_service_connection_profile" "source" {
  project               = var.project_id
  location              = var.region
  connection_profile_id = var.source_profile_id
  display_name          = var.source_display_name
  role                  = "SOURCE"
  labels                = var.labels

  mysql {
    host     = var.source_host
    port     = var.source_port
    username = var.source_username
    password = var.source_password

    dynamic "ssl" {
      for_each = var.source_ssl_ca_certificate != null ? [1] : []
      content {
        ca_certificate     = var.source_ssl_ca_certificate
        client_certificate = var.source_ssl_client_certificate
        client_key         = var.source_ssl_client_key
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Destination connection profile, mode A (default): EXISTING_CLOUDSQL
# Points DMS at the Cloud SQL instance that Terraform created
# (equivalent to `gcloud database-migration connection-profiles create mysql
# --cloudsql-instance=INSTANCE --role=DESTINATION`).
# ------------------------------------------------------------------------------

resource "google_database_migration_service_connection_profile" "destination_existing" {
  count = local.use_existing_cloudsql ? 1 : 0

  project               = var.project_id
  location              = var.region
  connection_profile_id = var.destination_profile_id
  display_name          = var.destination_display_name
  role                  = "DESTINATION"
  labels                = var.labels

  mysql {
    cloud_sql_id = var.destination_cloud_sql_id
  }

  lifecycle {
    precondition {
      condition     = var.destination_cloud_sql_id != null && var.destination_cloud_sql_id != ""
      error_message = "destination_cloud_sql_id must be set when destination_mode = \"EXISTING_CLOUDSQL\"."
    }
  }
}

# ------------------------------------------------------------------------------
# Destination connection profile, mode B (optional): DMS_MANAGED_CLOUDSQL
# DMS creates the Cloud SQL instance from these settings.
# ------------------------------------------------------------------------------

resource "google_database_migration_service_connection_profile" "destination" {
  count = local.use_existing_cloudsql ? 0 : 1

  project               = var.project_id
  location              = var.region
  connection_profile_id = var.destination_profile_id
  display_name          = var.destination_display_name
  labels                = var.labels

  cloudsql {
    settings {
      source_id             = google_database_migration_service_connection_profile.source.name
      database_version      = var.dest_database_version
      edition               = var.dest_edition
      tier                  = var.dest_tier
      data_disk_size_gb     = tostring(var.dest_disk_size_gb)
      data_disk_type        = var.dest_disk_type
      auto_storage_increase = var.dest_auto_storage_increase
      zone                  = var.dest_zone
      root_password         = var.dest_root_password
      user_labels           = var.labels

      ip_config {
        enable_ipv4     = var.dest_enable_ipv4
        private_network = var.dest_private_network
      }
    }
  }
}
