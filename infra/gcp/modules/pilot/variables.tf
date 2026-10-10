variable "project_id" { type = string }
variable "project_number" { type = string }
variable "region" { type = string }
variable "zone" { type = string }
variable "name_prefix" { type = string }
variable "compute_enabled" { type = bool }
variable "worker_count" { type = number }
variable "coordinator_machine_type" { type = string }
variable "worker_machine_type" { type = string }
variable "debian12_image" { type = string }
variable "subnet_cidr" { type = string }
variable "coordinator_boot_disk_size_gb" { type = number }
variable "coordinator_data_disk_size_gb" { type = number }
variable "worker_boot_disk_size_gb" { type = number }
variable "worker_data_disk_size_gb" { type = number }
variable "service_revision" { type = string }
variable "release_object" {
  type = string

  validation {
    condition     = var.release_object == "releases/${var.service_revision}.tar.gz"
    error_message = "release_object must name the tar archive for service_revision."
  }
}
variable "release_sha256" { type = string }
variable "worker_ssh_public_key" { type = string }
variable "secret_ids" {
  type = object({
    model_auth = string
    git_read   = string
    worker_ssh = string
  })
}
variable "secret_versions" {
  type = object({
    model_auth = string
    git_read   = string
    worker_ssh = string
  })
}
variable "optional_integration_secrets" {
  type = map(object({
    secret_id = string
    version   = string
  }))
  default = {}

  validation {
    condition = alltrue([
      for name, integration in var.optional_integration_secrets :
      !contains(["model_auth", "git_read", "worker_ssh"], name) &&
      can(regex("^[A-Za-z0-9_-]{1,255}$", integration.secret_id)) &&
      can(regex("^[1-9][0-9]*$", integration.version))
    ])
    error_message = "Optional integration secrets must use non-reserved map keys, valid Secret Manager IDs and positive pinned version numbers."
  }

  validation {
    condition = length(distinct(concat(
      values(var.secret_ids),
      [for integration in values(var.optional_integration_secrets) : integration.secret_id],
    ))) == length(var.secret_ids) + length(var.optional_integration_secrets)
    error_message = "Each base and optional integration secret container must have a distinct Secret Manager ID."
  }
}
variable "archive_bucket_name" {
  type     = string
  nullable = true
}
variable "backup_bucket_name" {
  type     = string
  nullable = true
}
variable "release_bucket_name" {
  type     = string
  nullable = true
}
variable "backup_retention_days" {
  type     = number
  nullable = true
}
variable "snapshot_retention_days" { type = number }
variable "billing_account_id" { type = string }
variable "budget_amount_usd" { type = number }
variable "notification_emails" { type = set(string) }
variable "iap_operator_emails" { type = set(string) }
variable "enable_https_iap" { type = bool }
variable "viewer_hostname" {
  type     = string
  nullable = true
}
variable "iap_viewer_emails" { type = set(string) }
variable "iap_google_managed_oauth_confirmed" { type = bool }
