# ------------------------------------------------------------------------------
# Separate module so that the Network Attachment can depend on the Cloud SQL
# instances (ACCEPT_MANUAL needs their tenant project) while this step depends
# on the Network Attachment, also when one attachment serves several instances
# (for_each), without a dependency cycle.
# ------------------------------------------------------------------------------

locals {
  psc_network_attachment_uri = var.network_attachment_uri == null ? "" : replace(var.network_attachment_uri, "https://www.googleapis.com/compute/v1/", "")
}

# ------------------------------------------------------------------------------
# PSC outbound (PSC interface): attach the Network Attachment to the instance so
# that Cloud SQL (and DMS replication) can reach the source in the consumer VPC.
# The instance module keeps psc_config in ignore_changes, so this step is the
# single owner of networkAttachmentUri. It fails the apply if the patch does not take effect.
#
# On destroy (enabled = false, migration_enabled = false, or
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
  count = var.enabled ? 1 : 0

  # Keep this list unchanged across versions: changing it replaces the resource
  # (detach + re-attach, i.e. two restarts) on existing stacks.
  triggers_replace = [
    var.instance_name,
    local.psc_network_attachment_uri,
  ]

  lifecycle {
    precondition {
      condition     = local.psc_network_attachment_uri != ""
      error_message = "network_attachment_uri must be set when enabled = true."
    }
  }

  input = {
    project_id                 = var.project_id
    instance_name              = var.instance_name
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

  # Destroy-time provisioners evaluate the OLD state: use try() for input keys
  # that states written by earlier versions of this module don't have.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      if [ -n "${try(self.input.impersonate_sa, "")}" ]; then
        export CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT="${try(self.input.impersonate_sa, "")}"
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
      gcloud sql operations wait "$${OP}" --project="$${PROJECT}" --timeout="${try(self.input.timeout_seconds, 1800)}"

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
