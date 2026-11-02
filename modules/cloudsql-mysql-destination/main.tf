locals {
  default_flags = [
    {
      name  = "cloudsql_iam_authentication"
      value = "on"
    }
  ]

  user_flag_names = [for f in var.database_flags : f.name]

  merged_database_flags = concat(
    [for df in local.default_flags : df if !contains(local.user_flag_names, df.name)],
    var.database_flags
  )
}

resource "google_sql_database_instance" "destination" {
  count = var.enabled ? 1 : 0

  project             = var.project_id
  name                = var.instance_name
  region              = var.region
  database_version    = var.database_version
  root_password       = var.root_password
  deletion_protection = var.deletion_protection

  settings {
    tier                        = var.tier
    edition                     = var.edition
    availability_type           = var.availability_type
    disk_size                   = var.disk_size_gb
    disk_type                   = var.disk_type
    disk_autoresize             = var.disk_autoresize
    disk_autoresize_limit       = var.disk_autoresize_limit
    deletion_protection_enabled = var.deletion_protection
    user_labels                 = var.labels

    data_cache_config {
      data_cache_enabled = var.edition == "ENTERPRISE_PLUS" ? var.data_cache_enabled : false
    }

    ip_configuration {
      ipv4_enabled    = var.enable_ipv4
      private_network = var.connectivity_type == "PSA" ? var.private_network : null

      dynamic "psc_config" {
        for_each = var.connectivity_type == "PSC" ? [1] : []
        content {
          psc_enabled               = true
          allowed_consumer_projects = length(var.allowed_psc_projects) > 0 ? var.allowed_psc_projects : [var.project_id]
        }
      }
    }

    backup_configuration {
      enabled                        = var.backup_enabled
      binary_log_enabled             = var.binary_log_enabled
      transaction_log_retention_days = var.transaction_log_retention_days

      backup_retention_settings {
        retained_backups = var.retained_backups
        retention_unit   = "COUNT"
      }
    }

    dynamic "database_flags" {
      for_each = local.merged_database_flags
      content {
        name  = database_flags.value.name
        value = database_flags.value.value
      }
    }
  }

  lifecycle {
    ignore_changes = [
      settings[0].ip_configuration[0].psc_config
    ]
  }
}

resource "terraform_data" "psc_outbound_network_attachment" {
  count = var.enabled && var.connectivity_type == "PSC" && var.psc_network_attachment_uri != null && var.psc_network_attachment_uri != "" ? 1 : 0

  depends_on = [google_sql_database_instance.destination]

  input = {
    project_id                 = var.project_id
    instance_name              = google_sql_database_instance.destination[0].name
    psc_network_attachment_uri = replace(var.psc_network_attachment_uri, "https://www.googleapis.com/compute/v1/", "")
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      CURRENT_NA=$(gcloud sql instances describe "${self.input.instance_name}" \
        --project="${self.input.project_id}" \
        --format="value(settings.ipConfiguration.pscConfig.networkAttachmentUri)" || true)
      if [ "$${CURRENT_NA}" != "${self.input.psc_network_attachment_uri}" ]; then
        ACCESS_TOKEN=$(gcloud auth application-default print-access-token)
        OP_NAME=$(curl -s -X PATCH \
          -H "Authorization: Bearer $${ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          "https://sqladmin.googleapis.com/v1/projects/${self.input.project_id}/instances/${self.input.instance_name}" \
          -d "{\"settings\":{\"ipConfiguration\":{\"pscConfig\":{\"pscEnabled\":true,\"networkAttachmentUri\":\"${self.input.psc_network_attachment_uri}\"}}}}" \
          | python3 -c "import sys, json; print(json.load(sys.stdin).get('name', ''))")
        if [ -n "$${OP_NAME}" ]; then
          gcloud sql operations wait "$${OP_NAME}" --project="${self.input.project_id}" --timeout=600
        fi
      fi
    EOT
  }
}
