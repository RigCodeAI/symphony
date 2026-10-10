locals {
  archive_bucket = coalesce(var.archive_bucket_name, "${var.project_id}-${var.name_prefix}-archive")
  backup_bucket  = coalesce(var.backup_bucket_name, "${var.project_id}-${var.name_prefix}-backups")
  release_bucket = coalesce(var.release_bucket_name, "${var.project_id}-${var.name_prefix}-releases")

  worker_indexes = var.worker_count == 0 ? toset([]) : toset([0])

  secret_definitions = merge(
    {
      model_auth = {
        secret_id = var.secret_ids.model_auth
        version   = var.secret_versions.model_auth
      }
      git_read = {
        secret_id = var.secret_ids.git_read
        version   = var.secret_versions.git_read
      }
      worker_ssh = {
        secret_id = var.secret_ids.worker_ssh
        version   = var.secret_versions.worker_ssh
      }
    },
    var.optional_integration_secrets,
  )

  worker_hosts = [
    for index in local.worker_indexes : {
      name = "${var.name_prefix}-worker-${format("%02d", index + 1)}"
      ip   = google_compute_address.worker.address
    } if var.compute_enabled
  ]

  tracked_instance_ids = var.compute_enabled ? concat(
    [google_compute_instance.coordinator["main"].instance_id],
    [for instance in values(google_compute_instance.worker) : instance.instance_id],
  ) : []

  low_disk_instance_filter = join(" OR ", [
    for instance_id in local.tracked_instance_ids : "resource.labels.instance_id = \"${instance_id}\""
  ])

  event_log_name  = "projects/${var.project_id}/logs/factory-events"
  ingress_enabled = var.enable_https_iap && var.compute_enabled
}

resource "google_compute_network" "factory" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-private"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "factory" {
  project                  = var.project_id
  name                     = "${var.name_prefix}-${var.region}"
  ip_cidr_range            = var.subnet_cidr
  region                   = var.region
  network                  = google_compute_network.factory.id
  private_ip_google_access = true
}

resource "google_compute_address" "coordinator" {
  project      = var.project_id
  name         = "${var.name_prefix}-coordinator-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.factory.id
  description  = "Reserved private address for the Symphony coordinator."
}

resource "google_compute_address" "worker" {
  project      = var.project_id
  name         = "${var.name_prefix}-worker-01-ip"
  region       = var.region
  address_type = "INTERNAL"
  subnetwork   = google_compute_subnetwork.factory.id
  description  = "Reserved private address for the initial Symphony worker."
}

resource "google_compute_router" "factory" {
  project = var.project_id
  name    = "${var.name_prefix}-router"
  region  = var.region
  network = google_compute_network.factory.id
}

resource "google_compute_router_nat" "factory" {
  project                            = var.project_id
  name                               = "${var.name_prefix}-nat"
  region                             = var.region
  router                             = google_compute_router.factory.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

resource "google_compute_firewall" "iap_ssh_to_coordinator" {
  project       = var.project_id
  name          = "${var.name_prefix}-iap-ssh"
  network       = google_compute_network.factory.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["${var.name_prefix}-coordinator"]
  priority      = 1000
  description   = "SSH to the coordinator through Identity-Aware Proxy TCP forwarding only."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "coordinator_ssh_to_worker" {
  project                 = var.project_id
  name                    = "${var.name_prefix}-coordinator-to-worker-ssh"
  network                 = google_compute_network.factory.name
  direction               = "INGRESS"
  source_service_accounts = [google_service_account.coordinator.email]
  target_service_accounts = [google_service_account.worker.email]
  priority                = 1000
  description             = "Only the coordinator service identity may open SSH to the worker."

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "https_healthcheck" {
  count = local.ingress_enabled ? 1 : 0

  project       = var.project_id
  name          = "${var.name_prefix}-https-healthcheck"
  network       = google_compute_network.factory.name
  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${var.name_prefix}-coordinator"]
  priority      = 1000
  description   = "Google load-balancer health checks and proxies to the coordinator listeners."

  allow {
    protocol = "tcp"
    ports    = var.enable_linear_webhook ? ["8080", "8081"] : ["8080"]
  }
}

resource "google_compute_resource_policy" "daily_data_snapshots" {
  project     = var.project_id
  name        = "${var.name_prefix}-daily-data-snapshots"
  region      = var.region
  description = "Daily snapshots for retained coordinator and worker data disks."

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "04:00"
      }
    }

    retention_policy {
      max_retention_days    = var.snapshot_retention_days
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }

    snapshot_properties {
      storage_locations = [var.region]
      guest_flush       = true
      labels = {
        managed_by = "terraform"
        purpose    = "factory-data-backup"
      }
    }
  }
}
