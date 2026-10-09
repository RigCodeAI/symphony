variable "project_id" {
  description = "GCP project that will hold the Terraform state bucket."
  type        = string
  default     = "factory-511117"
}

variable "state_bucket_name" {
  description = "Globally unique name for the separate Terraform state bucket."
  type        = string
  default     = "factory-511117-symphony-tfstate"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid lower-case GCS bucket name."
  }
}

variable "location" {
  description = "Location for the Terraform state bucket."
  type        = string
  default     = "us-central1"
}
