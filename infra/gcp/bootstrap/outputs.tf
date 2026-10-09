output "state_bucket_name" {
  description = "Use this bucket when configuring the pilot root's GCS backend."
  value       = google_storage_bucket.terraform_state.name
}

output "state_bucket_url" {
  description = "GCS URL for the Terraform state bucket."
  value       = "gs://${google_storage_bucket.terraform_state.name}"
}
