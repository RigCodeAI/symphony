resource "google_project_service" "storage_api" {
  project            = var.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "terraform_state" {
  project                     = var.project_id
  name                        = var.state_bucket_name
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = {
    managed_by = "terraform"
    purpose    = "terraform-state"
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.storage_api]
}
