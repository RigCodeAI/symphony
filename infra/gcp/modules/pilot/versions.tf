terraform {
  required_version = "= 1.13.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "= 8.5.0"
    }
  }
}
