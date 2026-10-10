data "google_project" "current" {
  project_id = var.project_id
}

locals {
  required_apis = toset([
    "billingbudgets.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "iap.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_apis

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "pilot" {
  source = "../modules/pilot"

  project_id                         = var.project_id
  project_number                     = data.google_project.current.number
  region                             = var.region
  zone                               = var.zone
  name_prefix                        = var.name_prefix
  compute_enabled                    = var.compute_enabled
  worker_count                       = var.worker_count
  coordinator_machine_type           = var.coordinator_machine_type
  worker_machine_type                = var.worker_machine_type
  debian12_image                     = var.debian12_image
  subnet_cidr                        = var.subnet_cidr
  coordinator_boot_disk_size_gb      = var.coordinator_boot_disk_size_gb
  coordinator_data_disk_size_gb      = var.coordinator_data_disk_size_gb
  worker_boot_disk_size_gb           = var.worker_boot_disk_size_gb
  worker_data_disk_size_gb           = var.worker_data_disk_size_gb
  service_revision                   = var.service_revision
  release_object                     = var.release_object
  release_sha256                     = var.release_sha256
  worker_ssh_public_key              = var.worker_ssh_public_key
  secret_ids                         = var.secret_ids
  secret_versions                    = var.secret_versions
  optional_integration_secrets       = var.optional_integration_secrets
  archive_bucket_name                = var.archive_bucket_name
  backup_bucket_name                 = var.backup_bucket_name
  release_bucket_name                = var.release_bucket_name
  backup_retention_days              = var.backup_retention_days
  snapshot_retention_days            = var.snapshot_retention_days
  billing_account_id                 = var.billing_account_id
  budget_amount_usd                  = var.budget_amount_usd
  notification_emails                = var.notification_emails
  iap_operator_emails                = var.iap_operator_emails
  enable_https_iap                   = var.enable_https_iap
  viewer_hostname                    = var.viewer_hostname
  iap_viewer_emails                  = var.iap_viewer_emails
  iap_google_managed_oauth_confirmed = var.iap_google_managed_oauth_confirmed

  depends_on = [google_project_service.required]
}
