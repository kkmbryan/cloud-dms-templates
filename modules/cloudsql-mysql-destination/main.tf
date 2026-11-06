locals {
  default_flags = concat(
    [
      {
        name  = "cloudsql_iam_authentication"
        value = "on"
      }
    ],
    # DMS requires local_infile=ON on the destination for MySQL 8.0 -> 8.4.
    # https://cloud.google.com/database-migration/docs/mysql/known-limitations
    var.database_version == "MYSQL_8_4" ? [
      {
        name  = "local_infile"
        value = "on"
      }
    ] : [],
    # lower_case_table_names can only be set when the instance is created.
    var.lower_case_table_names != null ? [
      {
        name  = "lower_case_table_names"
        value = tostring(var.lower_case_table_names)
      }
    ] : [],
  )

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

  # CMEK (optional). Set at creation only; the key must be in the same region and
  # the Cloud SQL service agent needs roles/cloudkms.cryptoKeyEncrypterDecrypter.
  encryption_key_name = var.kms_key_name

  # The root password is applied by google_sql_user.root below with a
  # write-only argument (Terraform >= 1.11), so it is not stored in Terraform
  # state. A saved plan file (terraform plan -out) still contains root module
  # input variables, so protect plan files.

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
      ssl_mode        = var.ssl_mode

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

    dynamic "password_validation_policy" {
      for_each = var.password_validation_policy == null ? [] : [var.password_validation_policy]
      content {
        enable_password_policy      = true
        min_length                  = password_validation_policy.value.min_length
        complexity                  = password_validation_policy.value.complexity
        reuse_interval              = password_validation_policy.value.reuse_interval
        disallow_username_substring = password_validation_policy.value.disallow_username_substring
        password_change_interval    = password_validation_policy.value.password_change_interval
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

  # psc_config is a set, so ignore_changes can't be narrowed to
  # network_attachment_uri: the whole block is ignored after creation.
  # - network_attachment_uri: the Network Attachment is created after the
  #   instance (ACCEPT_MANUAL needs the tenant project from this instance), so
  #   terraform_data.psc_outbound_network_attachment below owns it.
  # - allowed_consumer_projects: applied at creation. To change it later, run
  #   `gcloud sql instances patch INSTANCE --allowed-psc-projects=...`
  #   (see docs/security_hardening.md).
  lifecycle {
    ignore_changes = [
      settings[0].ip_configuration[0].psc_config
    ]
  }
}

# ------------------------------------------------------------------------------
# root@'%' with a write-only password.
# When root_password is not set, the provider deletes the default root@'%' user
# after it creates the instance (it does not take root_password_wo into account).
# This resource recreates root@'%' with password_wo, so the password is still
# kept out of Terraform state. Create it before DMS demotes the instance.
# ------------------------------------------------------------------------------
resource "google_sql_user" "root" {
  count = var.enabled && nonsensitive(var.root_password != null) ? 1 : 0

  project             = var.project_id
  instance            = google_sql_database_instance.destination[0].name
  name                = "root"
  host                = "%"
  password_wo         = var.root_password
  password_wo_version = var.root_password_wo_version

  # DMS and promotion manage users on the instance during the migration; don't
  # let a later destroy of this user fail the teardown.
  deletion_policy = "ABANDON"
}

# ------------------------------------------------------------------------------
# PSC outbound (PSC interface): attach the Network Attachment to the instance so
# that Cloud SQL (and DMS replication) can reach the source in the consumer VPC.
# psc_config is in ignore_changes above, so this step is the single owner of
# networkAttachmentUri. It fails the apply if the patch does not take effect.
#
# On destroy (psc_outbound_enabled = false, migration_enabled = false, or
# terraform destroy) it clears the attachment from the instance first, so that
# the Network Attachment can be deleted. Clearing it RESTARTS the instance:
# plan it in a maintenance window on a promoted production instance.
#
# gcloud runs with the active gcloud credentials. To use the same identity as
# the provider, set impersonate_service_account (exported to gcloud as
# CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT).
# ------------------------------------------------------------------------------
resource "terraform_data" "psc_outbound_network_attachment" {
  # Use a plan-time boolean: the attachment URI itself is unknown until the
  # Network Attachment exists.
  count = var.enabled && var.connectivity_type == "PSC" && var.psc_outbound_enabled ? 1 : 0

  triggers_replace = [
    var.project_id,
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
    timeout_seconds            = var.operation_timeout_seconds
    impersonate_sa             = var.impersonate_service_account == null ? "" : var.impersonate_service_account
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ -n "${self.input.impersonate_sa}" ]; then
        export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${self.input.impersonate_sa}"
      fi
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
        OP=$(gcloud sql instances patch "$${INSTANCE}" --project="$${PROJECT}" \
          --psc-network-attachment-uri="$${WANT}" --async --quiet --format="value(name)")
        if [ -z "$${OP}" ]; then
          echo "ERROR: instances patch returned no operation name." >&2
          exit 1
        fi
        gcloud sql operations wait "$${OP}" --project="$${PROJECT}" --timeout="${self.input.timeout_seconds}"
      fi

      ACTUAL="$(current_na)"
      if [ "$${ACTUAL}" != "$${WANT}" ]; then
        echo "ERROR: networkAttachmentUri is '$${ACTUAL}', expected '$${WANT}'." >&2
        exit 1
      fi
      echo "Network attachment verified on $${INSTANCE}."
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ -n "${self.input.impersonate_sa}" ]; then
        export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${self.input.impersonate_sa}"
      fi
      PROJECT="${self.input.project_id}"
      INSTANCE="${self.input.instance_name}"

      # The instance may already be gone (deleted outside Terraform). Only that
      # case is skipped; any other describe error fails the destroy.
      if ! NAMES=$(gcloud sql instances list --project="$${PROJECT}" \
          --filter="name=$${INSTANCE}" --format="value(name)"); then
        echo "ERROR: could not list Cloud SQL instances in $${PROJECT}." >&2
        exit 1
      fi
      if [ -z "$${NAMES}" ]; then
        echo "Instance $${INSTANCE} not found; nothing to detach."
        exit 0
      fi

      CURRENT=$(gcloud sql instances describe "$${INSTANCE}" --project="$${PROJECT}" \
        --format="value(settings.ipConfiguration.pscConfig.networkAttachmentUri)")
      if [ -z "$${CURRENT}" ]; then
        echo "No network attachment on $${INSTANCE}; nothing to detach."
        exit 0
      fi

      echo "Clearing the network attachment from $${INSTANCE} (the instance restarts)..."
      OP=$(gcloud sql instances patch "$${INSTANCE}" --project="$${PROJECT}" \
        --clear-psc-network-attachment-uri --async --quiet --format="value(name)")
      if [ -z "$${OP}" ]; then
        echo "ERROR: instances patch returned no operation name." >&2
        exit 1
      fi
      gcloud sql operations wait "$${OP}" --project="$${PROJECT}" --timeout="${self.input.timeout_seconds}"

      AFTER=$(gcloud sql instances describe "$${INSTANCE}" --project="$${PROJECT}" \
        --format="value(settings.ipConfiguration.pscConfig.networkAttachmentUri)")
      if [ -n "$${AFTER}" ]; then
        echo "ERROR: networkAttachmentUri is still '$${AFTER}'." >&2
        exit 1
      fi
      echo "Network attachment cleared from $${INSTANCE}."
    EOT
  }
}
