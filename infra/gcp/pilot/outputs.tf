output "coordinator_name" {
  description = "Coordinator VM name."
  value       = module.pilot.coordinator_name
}

output "coordinator_private_ip" {
  description = "Private address used for operator IAP SSH and the local service health probe."
  value       = module.pilot.coordinator_private_ip
}

output "worker_names" {
  description = "Worker VM names."
  value       = module.pilot.worker_names
}

output "worker_private_ips" {
  description = "Worker private addresses advertised to the coordinator."
  value       = module.pilot.worker_private_ips
}

output "archive_bucket" {
  description = "Private permanent evidence bucket."
  value       = module.pilot.archive_bucket
}

output "backup_bucket" {
  description = "Private rotating operational backup bucket."
  value       = module.pilot.backup_bucket
}

output "release_bucket" {
  description = "Private pinned service release and worker host-key bucket."
  value       = module.pilot.release_bucket
}

output "secret_resource_names" {
  description = "Secret Manager resource names. These identify containers only; no values are managed by Terraform."
  value       = module.pilot.secret_resource_names
}

output "coordinator_https_url" {
  description = "HTTPS URL when optional IAP ingress is enabled; null while disabled."
  value       = module.pilot.coordinator_https_url
}
