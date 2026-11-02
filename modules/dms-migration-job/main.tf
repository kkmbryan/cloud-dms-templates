locals {
  use_gcs_backup_dump   = var.dump_path != null && var.dump_path != ""
  use_existing_cloudsql = var.destination_mode == "EXISTING_CLOUDSQL"
}

# ------------------------------------------------------------------------------
# Mode A (Recommended Default): EXISTING_CLOUDSQL (Pre-provisioned Cloud SQL with Pure PSC)
# Creates the migration job against the EXISTING_CLOUDSQL destination and runs
# demote-destination so the standalone PSC + PSC Outbound Cloud SQL instance is
# ready for verify-job and start-job.
# ------------------------------------------------------------------------------

resource "terraform_data" "migration_existing_cloudsql" {
  count = local.use_existing_cloudsql ? 1 : 0

  input = {
    project_id                     = var.project_id
    region                         = var.region
    migration_job_id               = var.migration_job_id
    display_name                   = var.display_name
    migration_type                 = var.migration_type
    source_connection_profile      = var.source_connection_profile
    destination_connection_profile = var.destination_connection_profile
    dump_type                      = var.dump_type
    dump_path                      = var.dump_path != null ? var.dump_path : ""
    dump_parallel_level            = var.dump_parallel_level
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      if ! gcloud database-migration migration-jobs describe "${self.input.migration_job_id}" --region="${self.input.region}" --project="${self.input.project_id}" >/dev/null 2>&1; then
        DUMP_FLAGS="--dump-type=${self.input.dump_type}"
        if [ -n "${self.input.dump_path}" ]; then
          DUMP_FLAGS="$${DUMP_FLAGS} --dump-path=${self.input.dump_path}"
        elif [ -n "${self.input.dump_parallel_level}" ]; then
          DUMP_FLAGS="$${DUMP_FLAGS} --dump-parallel-level=${self.input.dump_parallel_level}"
        fi
        gcloud database-migration migration-jobs create "${self.input.migration_job_id}" \
          --region="${self.input.region}" \
          --project="${self.input.project_id}" \
          --type="${self.input.migration_type}" \
          --source="${self.input.source_connection_profile}" \
          --destination="${self.input.destination_connection_profile}" \
          --display-name="${self.input.display_name}" \
          $${DUMP_FLAGS} \
          --no-async

        DEMOTE_OP=$(gcloud database-migration migration-jobs demote-destination "${self.input.migration_job_id}" \
          --region="${self.input.region}" \
          --project="${self.input.project_id}" \
          --format="value(name)")
        if [ -n "$${DEMOTE_OP}" ]; then
          while true; do
            DONE=$(gcloud database-migration operations describe "$${DEMOTE_OP}" \
              --region="${self.input.region}" \
              --project="${self.input.project_id}" \
              --format="value(done)")
            if [ "$${DONE}" = "True" ] || [ "$${DONE}" = "true" ]; then
              break
            fi
            sleep 10
          done
        fi
      fi
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      gcloud database-migration migration-jobs delete "${self.input.migration_job_id}" \
        --region="${self.input.region}" \
        --project="${self.input.project_id}" \
        --quiet || true
    EOT
  }
}

# ------------------------------------------------------------------------------
# Mode B (Optional): DMS_MANAGED_CLOUDSQL
# ------------------------------------------------------------------------------

resource "google_database_migration_service_migration_job" "migration" {
  count = local.use_existing_cloudsql ? 0 : 1

  project          = var.project_id
  location         = var.region
  migration_job_id = var.migration_job_id
  display_name     = var.display_name
  type             = var.migration_type
  source           = var.source_connection_profile
  destination      = var.destination_connection_profile
  dump_type        = var.dump_type
  labels           = var.labels

  # Mutual exclusivity enforcement: dump_path and dump_flags cannot both be set.
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
    for_each = var.connectivity_method == "VPC_PEERING" ? [1] : []
    content {
      vpc = var.vpc_peering_network
    }
  }

  dynamic "reverse_ssh_connectivity" {
    for_each = var.connectivity_method == "REVERSE_SSH" ? [1] : []
    content {
      vm_ip   = var.reverse_ssh_vm_ip
      vm_port = var.reverse_ssh_vm_port
      vm      = var.reverse_ssh_vm
      vpc     = var.reverse_ssh_vpc
    }
  }

  dynamic "static_ip_connectivity" {
    for_each = var.connectivity_method == "STATIC_IP" ? [1] : []
    content {
    }
  }
}
