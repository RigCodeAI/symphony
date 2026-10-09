output "coordinator_name" {
  value = "${var.name_prefix}-coordinator"
}

output "coordinator_private_ip" {
  value = try(google_compute_instance.coordinator["main"].network_interface[0].network_ip, null)
}

output "worker_names" {
  value = [for instance in values(google_compute_instance.worker) : instance.name]
}

output "worker_private_ips" {
  value = [for instance in values(google_compute_instance.worker) : instance.network_interface[0].network_ip]
}

output "archive_bucket" {
  value = google_storage_bucket.archive.name
}

output "backup_bucket" {
  value = google_storage_bucket.backups.name
}

output "release_bucket" {
  value = google_storage_bucket.releases.name
}

output "secret_resource_names" {
  value = { for name, secret in google_secret_manager_secret.managed : name => secret.id }
}

output "coordinator_https_url" {
  value = local.ingress_enabled ? "https://${var.viewer_hostname}" : null
}
