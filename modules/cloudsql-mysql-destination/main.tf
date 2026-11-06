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
  #   the cloudsql-psc-outbound module owns it.
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
