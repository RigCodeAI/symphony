locals {
  coordinator_config = {
    version               = 1
    project_id            = var.project_id
    project_number        = var.project_number
    role                  = "coordinator"
    instance_name         = "${var.name_prefix}-coordinator"
    service_revision      = var.service_revision
    archive_bucket        = google_storage_bucket.archive.name
    backup_bucket         = google_storage_bucket.backups.name
    release_bucket        = google_storage_bucket.releases.name
    release_object        = var.release_object
    release_sha256        = var.release_sha256
    data_disk_device      = "factory-data"
    worker_hosts          = local.worker_hosts
    host_key_prefix       = "host-keys/"
    worker_ssh_public_key = var.worker_ssh_public_key
    secret_ids = merge(
      { worker_ssh = google_secret_manager_secret.managed["worker_ssh"].id },
      { for name, secret in var.optional_integration_secrets : name => google_secret_manager_secret.managed[name].id },
    )
    secret_versions = merge(
      { worker_ssh = var.secret_versions.worker_ssh },
      { for name, secret in var.optional_integration_secrets : name => secret.version },
    )
    enable_ingress = local.ingress_enabled
  }

  worker_config = {
    version          = 1
    project_id       = var.project_id
    project_number   = var.project_number
    role             = "worker"
    instance_name    = "${var.name_prefix}-worker-01"
    worker_hosts     = [{ name = "${var.name_prefix}-worker-01", ip = google_compute_address.worker.address }]
    service_revision = var.service_revision
    archive_bucket   = google_storage_bucket.archive.name
    backup_bucket    = google_storage_bucket.backups.name
    release_bucket   = google_storage_bucket.releases.name
    release_object   = var.release_object
    release_sha256   = var.release_sha256
    data_disk_device = "factory-data"
    worker_ssh_user  = "factory-worker"
    secret_ids = {
      model_auth = google_secret_manager_secret.managed["model_auth"].id
      git_read   = google_secret_manager_secret.managed["git_read"].id
    }
    secret_versions = {
      model_auth = var.secret_versions.model_auth
      git_read   = var.secret_versions.git_read
    }
    worker_ssh_public_key = var.worker_ssh_public_key
    host_key_object       = "host-keys/${var.name_prefix}-worker-01.pub"
  }

  coordinator_metadata = {
    "block-project-ssh-keys"  = "TRUE"
    "enable-oslogin"          = "TRUE"
    "factory-config"          = jsonencode(local.coordinator_config)
    "factory-cloud-io"        = local.cloud_io_script
    "factory-cloud-io-sha256" = sha256(local.cloud_io_script)
    "startup-script"          = local.startup_script
  }

  worker_metadata = {
    "block-project-ssh-keys"  = "TRUE"
    "enable-oslogin"          = "FALSE"
    "factory-config"          = jsonencode(local.worker_config)
    "factory-cloud-io"        = local.cloud_io_script
    "factory-cloud-io-sha256" = sha256(local.cloud_io_script)
    "startup-script"          = local.startup_script
  }

  startup_script  = file(abspath("${path.module}/../../../../factory/deploy/gcp-startup.sh"))
  cloud_io_script = file(abspath("${path.module}/../../../../factory/deploy/cloud_io.py"))
}

resource "google_compute_instance" "coordinator" {
  for_each = var.compute_enabled ? { main = true } : {}

  project                   = var.project_id
  name                      = "${var.name_prefix}-coordinator"
  zone                      = var.zone
  machine_type              = var.coordinator_machine_type
  allow_stopping_for_update = true
  tags                      = ["${var.name_prefix}-coordinator"]

  boot_disk {
    source      = google_compute_disk.coordinator_boot.id
    auto_delete = false
    device_name = "factory-coordinator-boot"
  }

  attached_disk {
    source      = google_compute_disk.coordinator_data.id
    device_name = "factory-data"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.factory.id
    network_ip = google_compute_address.coordinator.address
  }

  service_account {
    email  = google_service_account.coordinator.email
    scopes = ["cloud-platform"]
  }

  metadata = local.coordinator_metadata

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = {
    managed_by = "terraform"
    role       = "coordinator"
  }

  depends_on = [
    google_project_iam_member.coordinator_log_writer,
    google_project_iam_member.coordinator_metric_writer,
    google_secret_manager_secret_iam_member.coordinator_worker_ssh,
    google_secret_manager_secret_iam_member.coordinator_integration_secrets,
    google_storage_bucket_iam_member.coordinator_archive_creator,
    google_storage_bucket_iam_member.coordinator_archive_reader,
    google_storage_bucket_iam_member.coordinator_backup_creator,
    google_storage_bucket_iam_member.coordinator_backup_reader,
    google_storage_bucket_iam_member.coordinator_release_reader,
  ]
}

resource "google_compute_instance" "worker" {
  for_each = var.compute_enabled ? { for index in local.worker_indexes : tostring(index) => index } : {}

  project                   = var.project_id
  name                      = "${var.name_prefix}-worker-${format("%02d", each.value + 1)}"
  zone                      = var.zone
  machine_type              = var.worker_machine_type
  allow_stopping_for_update = true
  tags                      = ["${var.name_prefix}-worker"]

  boot_disk {
    source      = google_compute_disk.worker_boot.id
    auto_delete = false
    device_name = "factory-worker-boot"
  }

  attached_disk {
    source      = google_compute_disk.worker_data.id
    device_name = "factory-data"
    mode        = "READ_WRITE"
  }

  network_interface {
    subnetwork = google_compute_subnetwork.factory.id
    network_ip = google_compute_address.worker.address
  }

  service_account {
    email  = google_service_account.worker.email
    scopes = ["cloud-platform"]
  }

  metadata = local.worker_metadata

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = {
    managed_by = "terraform"
    role       = "worker"
  }

  depends_on = [
    google_project_iam_member.worker_log_writer,
    google_project_iam_member.worker_metric_writer,
    google_secret_manager_secret_iam_member.worker_agent_secrets,
    google_storage_bucket_iam_member.worker_host_key_creator,
    google_storage_bucket_iam_member.worker_host_key_reader,
    google_storage_bucket_iam_member.worker_release_reader,
  ]
}

resource "google_compute_instance_group" "coordinator" {
  count = local.ingress_enabled ? 1 : 0

  project   = var.project_id
  name      = "${var.name_prefix}-coordinator-backend"
  zone      = var.zone
  instances = [google_compute_instance.coordinator["main"].self_link]

  named_port {
    name = "http"
    port = 8080
  }
}

resource "google_compute_health_check" "coordinator_http" {
  count = local.ingress_enabled ? 1 : 0

  project             = var.project_id
  name                = "${var.name_prefix}-coordinator-8080"
  check_interval_sec  = 60
  timeout_sec         = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = 8080
  }
}

resource "google_compute_managed_ssl_certificate" "viewer" {
  count = local.ingress_enabled ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-viewer"

  managed {
    domains = [var.viewer_hostname]
  }
}

resource "google_compute_ssl_policy" "viewer" {
  count = local.ingress_enabled ? 1 : 0

  project         = var.project_id
  name            = "${var.name_prefix}-viewer-tls"
  profile         = "MODERN"
  min_tls_version = "TLS_1_2"
}

resource "google_compute_backend_service" "coordinator_https" {
  count = local.ingress_enabled ? 1 : 0

  project               = var.project_id
  name                  = "${var.name_prefix}-coordinator-https"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.coordinator_http[0].id]
  enable_cdn            = false

  backend {
    group = google_compute_instance_group.coordinator[0].self_link
  }

  iap {
    enabled = true
  }
}

resource "google_compute_url_map" "viewer" {
  count = local.ingress_enabled ? 1 : 0

  project         = var.project_id
  name            = "${var.name_prefix}-viewer"
  default_service = google_compute_backend_service.coordinator_https[0].self_link
}

resource "google_compute_target_https_proxy" "viewer" {
  count = local.ingress_enabled ? 1 : 0

  project          = var.project_id
  name             = "${var.name_prefix}-viewer"
  url_map          = google_compute_url_map.viewer[0].self_link
  ssl_certificates = [google_compute_managed_ssl_certificate.viewer[0].self_link]
  ssl_policy       = google_compute_ssl_policy.viewer[0].self_link
}

resource "google_compute_global_address" "viewer" {
  count = local.ingress_enabled ? 1 : 0

  project = var.project_id
  name    = "${var.name_prefix}-viewer"
}

resource "google_compute_global_forwarding_rule" "viewer_https" {
  count = local.ingress_enabled ? 1 : 0

  project               = var.project_id
  name                  = "${var.name_prefix}-viewer-https"
  target                = google_compute_target_https_proxy.viewer[0].self_link
  ip_address            = google_compute_global_address.viewer[0].address
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL_MANAGED"
}
