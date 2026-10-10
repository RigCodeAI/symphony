resource "google_service_account" "coordinator" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-coordinator"
  display_name = "Rig factory coordinator"
  description  = "Runtime identity for the Symphony coordinator VM."
}

resource "google_service_account" "worker" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-worker"
  display_name = "Rig factory worker"
  description  = "Runtime identity for the initial private worker VM."
}

resource "google_project_iam_member" "coordinator_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_project_iam_member" "coordinator_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_project_iam_member" "worker_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "worker_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_agent_secrets" {
  for_each = toset(["model_auth", "git_read"])

  project   = var.project_id
  secret_id = google_secret_manager_secret.managed[each.value].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_secret_manager_secret_iam_member" "coordinator_worker_ssh" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.managed["worker_ssh"].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_secret_manager_secret_iam_member" "coordinator_integration_secrets" {
  for_each = var.optional_integration_secrets

  project   = var.project_id
  secret_id = google_secret_manager_secret.managed[each.key].id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_storage_bucket_iam_member" "coordinator_archive_creator" {
  bucket = google_storage_bucket.archive.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_storage_bucket_iam_member" "coordinator_archive_reader" {
  bucket = google_storage_bucket.archive.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_storage_bucket_iam_member" "coordinator_backup_creator" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_storage_bucket_iam_member" "coordinator_backup_reader" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.coordinator.email}"
}

resource "google_storage_bucket_iam_member" "coordinator_release_reader" {
  bucket = google_storage_bucket.releases.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.coordinator.email}"

  condition {
    title       = "pinned-release-and-worker-key-only"
    description = "The coordinator may read only the configured release archive and pilot worker public host key."
    expression  = "resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/${var.release_object}\" || resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/host-keys/${var.name_prefix}-worker-01.pub\""
  }
}

resource "google_storage_bucket_iam_member" "worker_release_reader" {
  bucket = google_storage_bucket.releases.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.worker.email}"

  condition {
    title       = "pinned-release-only"
    description = "The pilot worker may read only the configured release archive."
    expression  = "resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/${var.release_object}\""
  }
}

resource "google_storage_bucket_iam_member" "worker_host_key_creator" {
  bucket = google_storage_bucket.releases.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.worker.email}"

  condition {
    title       = "worker-host-key-object-only"
    description = "The pilot worker may create only its own immutable SSH host-key object."
    expression  = "resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/host-keys/${var.name_prefix}-worker-01.pub\""
  }
}

resource "google_storage_bucket_iam_member" "worker_host_key_reader" {
  bucket = google_storage_bucket.releases.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.worker.email}"

  condition {
    title       = "worker-host-key-object-only"
    description = "The pilot worker may read only its own immutable SSH host-key object to verify an idempotent publication retry."
    expression  = "resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/host-keys/${var.name_prefix}-worker-01.pub\""
  }
}

resource "google_iap_tunnel_instance_iam_member" "iap_tunnel_operator" {
  for_each = var.compute_enabled ? var.iap_operator_emails : toset([])

  project  = var.project_id
  zone     = var.zone
  instance = "${var.name_prefix}-coordinator"
  role     = "roles/iap.tunnelResourceAccessor"
  member   = "user:${each.value}"

  depends_on = [google_compute_instance.coordinator]
}

resource "google_compute_instance_iam_member" "os_login_operator" {
  for_each = var.compute_enabled ? var.iap_operator_emails : toset([])

  project       = var.project_id
  zone          = var.zone
  instance_name = "${var.name_prefix}-coordinator"
  role          = "roles/compute.osAdminLogin"
  member        = "user:${each.value}"

  depends_on = [google_compute_instance.coordinator]
}

resource "google_service_account_iam_member" "os_login_operator_act_as" {
  for_each = var.compute_enabled ? var.iap_operator_emails : toset([])

  service_account_id = google_service_account.coordinator.name
  role               = "roles/iam.serviceAccountUser"
  member             = "user:${each.value}"
}

resource "google_iap_web_backend_service_iam_member" "https_viewer" {
  for_each = local.ingress_enabled ? var.iap_viewer_emails : toset([])

  project             = var.project_id
  web_backend_service = "${var.name_prefix}-coordinator-https"
  role                = "roles/iap.httpsResourceAccessor"
  member              = "user:${each.value}"

  depends_on = [google_compute_backend_service.coordinator_https]
}
