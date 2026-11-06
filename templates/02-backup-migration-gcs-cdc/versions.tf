terraform {
  required_version = ">= 1.11.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 8.0, < 9.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Optional: deploy as a service account. The gcloud local-exec steps get the
  # same identity through CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT.
  impersonate_service_account = var.impersonate_service_account
}
