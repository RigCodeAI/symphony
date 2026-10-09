resource "google_storage_bucket" "archive" {
  project                     = var.project_id
  name                        = local.archive_bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = {
    managed_by = "terraform"
    purpose    = "permanent-factory-evidence"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket" "backups" {
  project                     = var.project_id
  name                        = local.backup_bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  dynamic "lifecycle_rule" {
    for_each = var.backup_retention_days == null ? [] : [var.backup_retention_days]

    content {
      action {
        type = "Delete"
      }

      condition {
        age = lifecycle_rule.value
      }
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.backup_retention_days == null ? [] : [var.backup_retention_days]

    content {
      action {
        type = "Delete"
      }

      condition {
        age                = lifecycle_rule.value
        num_newer_versions = 1
      }
    }
  }

  labels = {
    managed_by = "terraform"
    purpose    = "rotating-factory-backups"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_storage_bucket" "releases" {
  project                     = var.project_id
  name                        = local.release_bucket
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  versioning {
    enabled = true
  }

  labels = {
    managed_by = "terraform"
    purpose    = "pinned-service-releases"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_disk" "coordinator_boot" {
  project = var.project_id
  name    = "${var.name_prefix}-coordinator-boot"
  zone    = var.zone
  image   = var.debian12_image
  type    = "pd-balanced"
  size    = var.coordinator_boot_disk_size_gb

  labels = {
    managed_by = "terraform"
    role       = "coordinator-boot"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_disk" "coordinator_data" {
  project = var.project_id
  name    = "${var.name_prefix}-coordinator-data"
  zone    = var.zone
  type    = "pd-balanced"
  size    = var.coordinator_data_disk_size_gb
  # Snapshot scheduling is attached in a separate resource below.

  labels = {
    managed_by = "terraform"
    role       = "coordinator-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_disk" "worker_boot" {
  project = var.project_id
  name    = "${var.name_prefix}-worker-01-boot"
  zone    = var.zone
  image   = var.debian12_image
  type    = "pd-balanced"
  size    = var.worker_boot_disk_size_gb

  labels = {
    managed_by = "terraform"
    role       = "worker-boot"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_disk" "worker_data" {
  project = var.project_id
  name    = "${var.name_prefix}-worker-01-data"
  zone    = var.zone
  type    = "pd-balanced"
  size    = var.worker_data_disk_size_gb
  # Snapshot scheduling is attached in a separate resource below.

  labels = {
    managed_by = "terraform"
    role       = "worker-data"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_compute_disk_resource_policy_attachment" "coordinator_daily_snapshots" {
  project = var.project_id
  name    = google_compute_resource_policy.daily_data_snapshots.name
  disk    = google_compute_disk.coordinator_data.name
  zone    = var.zone
}

resource "google_compute_disk_resource_policy_attachment" "worker_daily_snapshots" {
  project = var.project_id
  name    = google_compute_resource_policy.daily_data_snapshots.name
  disk    = google_compute_disk.worker_data.name
  zone    = var.zone
}

resource "google_secret_manager_secret" "managed" {
  for_each = local.secret_definitions

  project   = var.project_id
  secret_id = each.value.secret_id

  replication {
    auto {}
  }

  labels = {
    managed_by = "terraform"
    purpose    = "factory-secret-container"
  }

  lifecycle {
    prevent_destroy = true
  }
}
