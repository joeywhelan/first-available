# Terraform 1.11+ is needed for write-only arguments (password_wo), which keep
# passwords out of the state file.
terraform {
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.10"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 8.10"
    }
  }
}

# Both providers authenticate with Application Default Credentials
# (gcloud auth application-default login).
provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
}

provider "google-beta" {
  project = var.gcp_project_id
  region  = var.gcp_region
}
