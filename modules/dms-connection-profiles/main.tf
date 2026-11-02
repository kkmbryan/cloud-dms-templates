locals {
  use_existing_cloudsql = var.destination_mode == "EXISTING_CLOUDSQL"
}

# ------------------------------------------------------------------------------
# Mode A (Recommended Default): EXISTING_CLOUDSQL (Pre-provisioned Cloud SQL with Pure PSC)
# Uses gcloud database-migration connection-profiles create mysql with
# --role=SOURCE and --role=DESTINATION --cloudsql-instance
# ------------------------------------------------------------------------------

resource "terraform_data" "source_existing_cloudsql" {
  count = local.use_existing_cloudsql ? 1 : 0

  input = {
    project_id            = var.project_id
    region                = var.region
    source_profile_id     = var.source_profile_id
    source_display_name   = var.source_display_name
    source_host           = var.source_host
    source_port           = var.source_port
    source_username       = var.source_username
    source_password       = var.source_password
    private_connection_id = var.private_connection_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      if ! gcloud database-migration connection-profiles describe "${self.input.source_profile_id}" --region="${self.input.region}" --project="${self.input.project_id}" >/dev/null 2>&1; then
        CREATE_SUCCESS="false"
        if [ -n "${self.input.private_connection_id}" ]; then
          if gcloud database-migration connection-profiles create mysql "${self.input.source_profile_id}" \
            --region="${self.input.region}" \
            --project="${self.input.project_id}" \
            --role=SOURCE \
            --host="${self.input.source_host}" \
            --port="${self.input.source_port}" \
            --username="${self.input.source_username}" \
            --password="${self.input.source_password}" \
            --private-connection="${self.input.private_connection_id}" \
            --display-name="${self.input.source_display_name}" \
            --no-async 2>/dev/null; then
            CREATE_SUCCESS="true"
          fi
        fi
        if [ "$CREATE_SUCCESS" != "true" ]; then
          gcloud database-migration connection-profiles create mysql "${self.input.source_profile_id}" \
            --region="${self.input.region}" \
            --project="${self.input.project_id}" \
            --role=SOURCE \
            --host="${self.input.source_host}" \
            --port="${self.input.source_port}" \
            --username="${self.input.source_username}" \
            --password="${self.input.source_password}" \
            --display-name="${self.input.source_display_name}" \
            --no-async
        fi
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud database-migration connection-profiles delete "${self.input.source_profile_id}" \
        --region="${self.input.region}" \
        --project="${self.input.project_id}" \
        --quiet || true
    EOT
  }
}

resource "terraform_data" "destination_existing_cloudsql" {
  count = local.use_existing_cloudsql ? 1 : 0

  depends_on = [terraform_data.source_existing_cloudsql]

  input = {
    project_id               = var.project_id
    region                   = var.region
    destination_profile_id   = var.destination_profile_id
    destination_display_name = var.destination_display_name
    destination_cloud_sql_id = var.destination_cloud_sql_id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      if ! gcloud database-migration connection-profiles describe "${self.input.destination_profile_id}" --region="${self.input.region}" --project="${self.input.project_id}" >/dev/null 2>&1; then
        gcloud database-migration connection-profiles create mysql "${self.input.destination_profile_id}" \
          --region="${self.input.region}" \
          --project="${self.input.project_id}" \
          --role=DESTINATION \
          --cloudsql-instance="${self.input.destination_cloud_sql_id}" \
          --display-name="${self.input.destination_display_name}" \
          --no-async
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud database-migration connection-profiles delete "${self.input.destination_profile_id}" \
        --region="${self.input.region}" \
        --project="${self.input.project_id}" \
        --quiet || true
    EOT
  }
}

# ------------------------------------------------------------------------------
# Mode B (Optional): DMS_MANAGED_CLOUDSQL
# ------------------------------------------------------------------------------

resource "google_database_migration_service_connection_profile" "source" {
  count = local.use_existing_cloudsql ? 0 : 1

  project               = var.project_id
  location              = var.region
  connection_profile_id = var.source_profile_id
  display_name          = var.source_display_name
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

resource "google_database_migration_service_connection_profile" "destination" {
  count = local.use_existing_cloudsql ? 0 : 1

  project               = var.project_id
  location              = var.region
  connection_profile_id = var.destination_profile_id
  display_name          = var.destination_display_name
  labels                = var.labels

  cloudsql {
    settings {
      source_id             = google_database_migration_service_connection_profile.source[0].name
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
