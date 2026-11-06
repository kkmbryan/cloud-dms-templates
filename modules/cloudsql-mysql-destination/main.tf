locals {
  default_flags = [
    {
      name  = "cloudsql_iam_authentication"
      value = "on"
    }
  ]

  user_flag_names = [for f in var.database_flags : f.name]

  psc_network_attachment_uri = var.psc_network_attachment_uri == null ? "" : replace(var.psc_network_attachment_uri, "https://www.googleapis.com/compute/v1/", "")

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
  deletion_protection = var.deletion_protection

  # Write-only argument (Terraform >= 1.11): the root password is sent to the
  # API but never stored in the Terraform plan or state.
  root_password_wo         = var.root_password
  root_password_wo_version = nonsensitive(var.root_password != null) ? tostring(var.root_password_wo_version) : null

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

# ------------------------------------------------------------------------------
# PSC outbound (PSC interface): attach the Network Attachment to the instance so
# that Cloud SQL (and DMS replication) can reach the source in the consumer VPC.
# psc_config is in ignore_changes above, so this step is the single owner of
# networkAttachmentUri. It fails the apply if the patch does not take effect.
# ------------------------------------------------------------------------------
resource "terraform_data" "psc_outbound_network_attachment" {
  # Use a plan-time boolean: the attachment URI itself is unknown until the
  # Network Attachment exists.
  count = var.enabled && var.connectivity_type == "PSC" && var.psc_outbound_enabled ? 1 : 0

  triggers_replace = [
    google_sql_database_instance.destination[0].name,
    local.psc_network_attachment_uri,
  ]

  lifecycle {
    precondition {
      condition     = local.psc_network_attachment_uri != ""
      error_message = "psc_network_attachment_uri must be set when psc_outbound_enabled = true."
    }
  }

  input = {
    project_id                 = var.project_id
    instance_name              = google_sql_database_instance.destination[0].name
    psc_network_attachment_uri = local.psc_network_attachment_uri
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      PROJECT="${self.input.project_id}"
      INSTANCE="${self.input.instance_name}"
      WANT="${self.input.psc_network_attachment_uri}"

      current_na() {
        gcloud sql instances describe "$${INSTANCE}" --project="$${PROJECT}" \
          --format="value(settings.ipConfiguration.pscConfig.networkAttachmentUri)" \
          | sed -e 's#^https://www.googleapis.com/compute/v1/##'
      }

      if [ "$(current_na)" != "$${WANT}" ]; then
        echo "Attaching network attachment $${WANT} to Cloud SQL instance $${INSTANCE}..."
        gcloud sql instances patch "$${INSTANCE}" --project="$${PROJECT}" \
          --psc-network-attachment-uri="$${WANT}" --quiet
      fi

      ACTUAL="$(current_na)"
      if [ "$${ACTUAL}" != "$${WANT}" ]; then
        echo "ERROR: networkAttachmentUri is '$${ACTUAL}', expected '$${WANT}'." >&2
        exit 1
      fi
      echo "Network attachment verified on $${INSTANCE}."
    EOT
  }
}
