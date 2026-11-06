locals {
  use_gcs_backup_dump   = var.dump_path != null && var.dump_path != ""
  use_existing_cloudsql = var.destination_mode == "EXISTING_CLOUDSQL"
}

# ------------------------------------------------------------------------------
# DMS continuous migration job (both destination modes)
#
# EXISTING_CLOUDSQL (default): no connectivity block is set. The destination is
# a PSC-enabled Cloud SQL instance with a Network Attachment (PSC interface), so
# DMS uses that path to reach the source.
# DMS_MANAGED_CLOUDSQL: the selected connectivity_method block is set.
# ------------------------------------------------------------------------------

resource "google_database_migration_service_migration_job" "migration" {
  project          = var.project_id
  location         = var.region
  migration_job_id = var.migration_job_id
  display_name     = var.display_name
  type             = var.migration_type
  source           = var.source_connection_profile
  destination      = var.destination_connection_profile
  dump_type        = var.dump_type
  labels           = var.labels

  # dump_path and dump_flags are mutually exclusive in the provider schema.
  dump_path = local.use_gcs_backup_dump ? var.dump_path : null

  dynamic "performance_config" {
    for_each = !local.use_gcs_backup_dump ? [1] : []
    content {
      dump_parallel_level = var.dump_parallel_level
    }
  }

  dynamic "dump_flags" {
    for_each = (!local.use_gcs_backup_dump && length(var.dump_flags) > 0) ? [1] : []
    content {
      dynamic "dump_flags" {
        for_each = var.dump_flags
        content {
          name  = dump_flags.value.name
          value = dump_flags.value.value
        }
      }
    }
  }

  dynamic "vpc_peering_connectivity" {
    for_each = !local.use_existing_cloudsql && var.connectivity_method == "VPC_PEERING" ? [1] : []
    content {
      vpc = var.vpc_peering_network
    }
  }

  dynamic "reverse_ssh_connectivity" {
    for_each = !local.use_existing_cloudsql && var.connectivity_method == "REVERSE_SSH" ? [1] : []
    content {
      vm_ip   = var.reverse_ssh_vm_ip
      vm_port = var.reverse_ssh_vm_port
      vm      = var.reverse_ssh_vm
      vpc     = var.reverse_ssh_vpc
    }
  }

  dynamic "static_ip_connectivity" {
    for_each = !local.use_existing_cloudsql && var.connectivity_method == "STATIC_IP" ? [1] : []
    content {
    }
  }

  lifecycle {
    precondition {
      condition     = !(var.dump_type == "PHYSICAL" && !local.use_gcs_backup_dump)
      error_message = "dump_type = \"PHYSICAL\" requires dump_path (a GCS folder with a prepared Percona XtraBackup backup)."
    }
  }
}

# ------------------------------------------------------------------------------
# Demote the existing destination (EXISTING_CLOUDSQL only)
#
# DMS requires the existing Cloud SQL instance to run as a read replica before
# `verify` and `start`. There is no native resource for this action, so it runs
# once through gcloud after the job is created. The step polls the operation
# with a deadline and fails the apply if the operation reports an error. If it
# fails, Terraform marks it tainted and the next apply runs it again.
# ------------------------------------------------------------------------------

resource "terraform_data" "demote_destination" {
  count = local.use_existing_cloudsql && var.demote_destination ? 1 : 0

  triggers_replace = [
    google_database_migration_service_migration_job.migration.name,
  ]

  input = {
    project_id       = var.project_id
    region           = var.region
    migration_job_id = google_database_migration_service_migration_job.migration.migration_job_id
    timeout_seconds  = var.demote_timeout_seconds
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      PROJECT="${self.input.project_id}"
      REGION="${self.input.region}"
      JOB="${self.input.migration_job_id}"
      DEADLINE=$(( $(date +%s) + ${self.input.timeout_seconds} ))

      echo "Demoting the destination of migration job $${JOB}..."
      OP=$(gcloud database-migration migration-jobs demote-destination "$${JOB}" \
        --region="$${REGION}" --project="$${PROJECT}" --format="value(name)")
      if [ -z "$${OP}" ]; then
        echo "ERROR: demote-destination returned no operation name." >&2
        exit 1
      fi

      while true; do
        DONE=$(gcloud database-migration operations describe "$${OP}" \
          --region="$${REGION}" --project="$${PROJECT}" --format="value(done)")
        if [ "$${DONE}" = "True" ] || [ "$${DONE}" = "true" ]; then
          break
        fi
        if [ "$(date +%s)" -ge "$${DEADLINE}" ]; then
          echo "ERROR: demote operation $${OP} did not finish within ${self.input.timeout_seconds}s." >&2
          exit 1
        fi
        sleep 15
      done

      ERR=$(gcloud database-migration operations describe "$${OP}" \
        --region="$${REGION}" --project="$${PROJECT}" --format="value(error.message)")
      if [ -n "$${ERR}" ]; then
        echo "ERROR: demote operation $${OP} failed: $${ERR}" >&2
        exit 1
      fi
      echo "Destination demoted for migration job $${JOB}."
    EOT
  }
}
