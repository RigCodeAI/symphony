mock_provider "google" {
  override_during = plan

  mock_resource "google_service_account" {
    defaults = {
      name  = "projects/factory-pilot-test/serviceAccounts/factory-test@factory-pilot-test.iam.gserviceaccount.com"
      email = "factory-test@factory-pilot-test.iam.gserviceaccount.com"
    }
  }
}

variables {
  project_id                    = "factory-pilot-test"
  project_number                = "123456789012"
  region                        = "us-central1"
  zone                          = "us-central1-a"
  name_prefix                   = "rig-factory"
  compute_enabled               = true
  worker_count                  = 1
  coordinator_machine_type      = "e2-standard-2"
  worker_machine_type           = "n2-standard-16"
  debian12_image                = "projects/debian-cloud/global/images/debian-12-bookworm-v20260902"
  subnet_cidr                   = "10.42.0.0/20"
  coordinator_boot_disk_size_gb = 30
  coordinator_data_disk_size_gb = 100
  worker_boot_disk_size_gb      = 50
  worker_data_disk_size_gb      = 500
  service_revision              = "0123456789abcdef0123456789abcdef01234567"
  release_object                = "releases/0123456789abcdef0123456789abcdef01234567.tar.gz"
  release_sha256                = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  worker_ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakePilotPublicKey"
  secret_ids = {
    model_auth = "model-auth"
    git_read   = "git-read"
    worker_ssh = "worker-ssh"
  }
  secret_versions = {
    model_auth = "1"
    git_read   = "2"
    worker_ssh = "3"
  }
  optional_integration_secrets = {
    linear_api = {
      secret_id = "linear-api"
      version   = "7"
    }
  }
  archive_bucket_name                = null
  backup_bucket_name                 = null
  release_bucket_name                = null
  backup_retention_days              = 30
  snapshot_retention_days            = 14
  billing_account_id                 = "000000-000000-000000"
  budget_amount_usd                  = 250
  notification_emails                = ["ops@example.test"]
  iap_operator_emails                = ["operator@example.test"]
  enable_https_iap                   = false
  viewer_hostname                    = null
  iap_viewer_emails                  = []
  iap_google_managed_oauth_confirmed = false
}

run "private_instances_and_role_scoped_secrets" {
  command = plan

  assert {
    condition     = length(google_compute_instance.coordinator["main"].network_interface[0].access_config) == 0
    error_message = "The coordinator must not have a public IP."
  }

  assert {
    condition     = length(google_compute_instance.worker["0"].network_interface[0].access_config) == 0
    error_message = "The worker must not have a public IP."
  }

  assert {
    condition     = local.worker_metadata["enable-oslogin"] == "FALSE" && !contains(keys(local.worker_metadata), "ssh-keys")
    error_message = "The worker must use the bootstrap-installed restricted key and disable inherited OS Login."
  }

  assert {
    condition     = local.coordinator_metadata["factory-cloud-io-sha256"] == sha256(local.coordinator_metadata["factory-cloud-io"])
    error_message = "The root-only cloud transport metadata must carry a matching digest."
  }

  assert {
    condition     = local.coordinator_config.worker_ssh_public_key == var.worker_ssh_public_key
    error_message = "Coordinator metadata must carry only the public key needed to verify the pinned worker SSH private key."
  }

  assert {
    condition     = toset(keys(local.coordinator_config.secret_ids)) == toset(["worker_ssh", "linear_api"])
    error_message = "Coordinator metadata must contain only its worker-SSH and configured integration secret references."
  }

  assert {
    condition     = toset(keys(local.worker_config.secret_ids)) == toset(["model_auth", "git_read"])
    error_message = "Only model-auth and git-read secret references may be present in worker metadata config."
  }

  assert {
    condition     = length(google_secret_manager_secret_iam_member.worker_agent_secrets) == 2 && google_secret_manager_secret_iam_member.coordinator_worker_ssh.role == "roles/secretmanager.secretAccessor"
    error_message = "Worker and coordinator Secret Manager access must remain role-scoped."
  }

  assert {
    condition     = google_storage_bucket_iam_member.worker_host_key_creator.condition[0].expression == google_storage_bucket_iam_member.worker_host_key_reader.condition[0].expression && google_storage_bucket_iam_member.worker_host_key_reader.role == "roles/storage.objectViewer"
    error_message = "Worker host-key create and retry-read access must cover only the same exact public-key object."
  }

  assert {
    condition     = google_storage_bucket_iam_member.worker_release_reader.condition[0].expression == "resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/${var.release_object}\"" && google_storage_bucket_iam_member.coordinator_release_reader.condition[0].expression == "resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/${var.release_object}\" || resource.name == \"projects/_/buckets/${google_storage_bucket.releases.name}/objects/host-keys/${var.name_prefix}-worker-01.pub\""
    error_message = "Release readers must be limited to the exact pinned artifact and coordinator worker key."
  }

  assert {
    condition     = google_storage_bucket_iam_member.coordinator_backup_creator.role == "roles/storage.objectCreator" && google_storage_bucket_iam_member.coordinator_backup_reader.role == "roles/storage.objectViewer"
    error_message = "The coordinator may create and read backups but must not delete them."
  }

  assert {
    condition = length(google_storage_bucket.backups.lifecycle_rule) == 2 && anytrue(flatten([
      for rule in google_storage_bucket.backups.lifecycle_rule : [
        for condition in rule.condition : condition.num_newer_versions == 1
      ]
    ]))
    error_message = "Versioned backup objects and their older generations must both age out when retention is enabled."
  }

  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_member.coordinator_integration_secrets)) == toset(["linear_api"]) && google_secret_manager_secret_iam_member.coordinator_integration_secrets["linear_api"].role == "roles/secretmanager.secretAccessor"
    error_message = "Optional integration access must remain scoped to its configured secret container."
  }

  assert {
    condition     = google_logging_metric.factory_event["service_unhealthy"].filter == "resource.type=\"gce_instance\" AND logName=\"projects/${var.project_id}/logs/factory-events\" AND jsonPayload.message:\"FACTORY_EVENT service_unhealthy\""
    error_message = "Service event alerts must match the Ops Agent log and timestamp-prefixed event message."
  }

  assert {
    condition     = length(google_iap_tunnel_instance_iam_member.iap_tunnel_operator) == 1 && google_compute_instance_iam_member.os_login_operator["operator@example.test"].role == "roles/compute.osAdminLogin"
    error_message = "Operator access must use IAP tunnel IAM and coordinator-scoped OS Admin Login."
  }
}

run "compute_disabled_plan_keeps_retained_resources" {
  command = plan

  variables {
    compute_enabled = false
  }

  assert {
    condition     = length(google_compute_instance.coordinator) == 0 && length(google_compute_instance.worker) == 0
    error_message = "compute_enabled=false must remove only VM instances."
  }

  assert {
    condition     = google_compute_disk.coordinator_data.name == "rig-factory-coordinator-data" && google_compute_disk.worker_data.name == "rig-factory-worker-01-data"
    error_message = "Retained coordinator and worker data disks must remain managed when compute is disabled."
  }

  assert {
    condition     = google_storage_bucket.archive.name == "factory-pilot-test-rig-factory-archive" && google_storage_bucket.releases.name == "factory-pilot-test-rig-factory-releases"
    error_message = "Permanent archive and release buckets must remain managed when compute is disabled."
  }
}

run "optional_https_ingress_requires_iap_allowlist" {
  command = plan

  variables {
    enable_https_iap                   = true
    viewer_hostname                    = "factory.example.test"
    iap_viewer_emails                  = ["viewer@example.test"]
    iap_google_managed_oauth_confirmed = true
  }

  assert {
    condition     = google_compute_backend_service.coordinator_https[0].iap[0].enabled
    error_message = "Optional HTTPS traffic must pass through IAP."
  }

  assert {
    condition     = google_iap_web_backend_service_iam_member.https_viewer["viewer@example.test"].role == "roles/iap.httpsResourceAccessor" && google_iap_web_backend_service_iam_member.https_viewer["viewer@example.test"].member == "user:viewer@example.test" && google_iap_web_backend_service_iam_member.https_viewer["viewer@example.test"].web_backend_service == "rig-factory-coordinator-https"
    error_message = "Only the configured viewer allowlist may use the optional HTTPS endpoint."
  }

  assert {
    condition     = toset(google_compute_firewall.https_healthcheck[0].source_ranges) == toset(["130.211.0.0/22", "35.191.0.0/16"])
    error_message = "The optional HTTP backend must accept traffic only from Google load-balancer probes and proxies."
  }
}

run "managed_domain_only_dashboard_access" {
  command = plan
  variables {
    enable_https_iap                   = true
    viewer_hostname                    = "factory.example.test"
    iap_viewer_domains                 = ["rig.ai"]
    iap_google_managed_oauth_confirmed = true
  }
  assert {
    condition     = google_iap_web_backend_service_iam_member.https_domain_viewer["rig.ai"].member == "domain:rig.ai" && google_iap_web_backend_service_iam_member.https_domain_viewer["rig.ai"].role == "roles/iap.httpsResourceAccessor" && google_iap_web_backend_service_iam_member.https_domain_viewer["rig.ai"].web_backend_service == "rig-factory-coordinator-https" && length(google_iap_web_backend_service_iam_member.https_viewer) == 0 && google_compute_backend_service.coordinator_https[0].iap[0].enabled
    error_message = "Managed-domain access must grant only the dashboard backend IAP role."
  }
  assert {
    condition     = keys(google_iap_tunnel_instance_iam_member.iap_tunnel_operator) == ["operator@example.test"] && length(google_compute_instance_iam_member.os_login_operator) == 1
    error_message = "Dashboard domains must not receive operator tunnel or OS Login access."
  }
}

run "mixed_domain_and_email_dashboard_access" {
  command = plan
  variables {
    enable_https_iap                   = true
    viewer_hostname                    = "factory.example.test"
    iap_viewer_domains                 = ["rig.ai"]
    iap_viewer_emails                  = ["viewer@example.test"]
    iap_google_managed_oauth_confirmed = true
  }
  assert {
    condition     = length(google_iap_web_backend_service_iam_member.https_domain_viewer) == 1 && google_iap_web_backend_service_iam_member.https_viewer["viewer@example.test"].member == "user:viewer@example.test"
    error_message = "Domain support must preserve existing email resource addresses and grants."
  }
}

run "disabled_ingress_has_no_domain_access_grants" {
  command = plan
  variables {
    iap_viewer_domains = ["rig.ai"]
  }
  assert {
    condition     = length(google_iap_web_backend_service_iam_member.https_domain_viewer) == 0 && length(google_iap_web_backend_service_iam_member.https_viewer) == 0
    error_message = "Disabled ingress must not create dashboard IAM grants."
  }
}

run "invalid_domain_principals_rejected" {
  command = plan
  variables {
    iap_viewer_domains = ["*.rig.ai", "user@rig.ai", "domain:rig.ai", "allUsers"]
  }
  expect_failures = [var.iap_viewer_domains]
}

run "linear_webhook_has_only_an_exact_public_route_and_coordinator_credentials" {
  command = plan
  override_resource {
    target          = google_compute_backend_service.coordinator_https[0]
    override_during = plan
    values          = { self_link = "https://compute.googleapis.com/compute/v1/projects/test/global/backendServices/dashboard" }
  }
  override_resource {
    target          = google_compute_backend_service.linear_webhook[0]
    override_during = plan
    values          = { self_link = "https://compute.googleapis.com/compute/v1/projects/test/global/backendServices/webhook" }
  }
  variables {
    enable_https_iap                   = true
    viewer_hostname                    = "factory.example.test"
    iap_viewer_emails                  = ["viewer@example.test"]
    iap_google_managed_oauth_confirmed = true
    coordinator_workflow               = "linear"
    enable_linear_webhook              = true
    optional_integration_secrets = {
      linear_api     = { secret_id = "linear-api", version = "7" }
      linear_signing = { secret_id = "linear-signing", version = "2" }
    }
    coordinator_secret_env = { LINEAR_API_KEY = "linear_api", LINEAR_API_TOKEN = "linear_signing" }
  }
  assert {
    condition     = google_compute_backend_service.coordinator_https[0].iap[0].enabled && !google_compute_backend_service.linear_webhook[0].iap[0].enabled && google_compute_backend_service.linear_webhook[0].port_name == "linear-webhook"
    error_message = "The dashboard must retain IAP while the signed webhook uses its isolated listener."
  }
  assert {
    condition     = google_compute_url_map.viewer[0].default_service == google_compute_backend_service.coordinator_https[0].self_link && google_compute_url_map.viewer[0].path_matcher[0].default_service == google_compute_backend_service.coordinator_https[0].self_link && toset(google_compute_url_map.viewer[0].path_matcher[0].path_rule[0].paths) == toset(["/hooks/linear"]) && google_compute_url_map.viewer[0].path_matcher[0].path_rule[0].service == google_compute_backend_service.linear_webhook[0].self_link
    error_message = "Only the exact signed webhook path may bypass IAP."
  }
  assert {
    condition     = local.coordinator_config.coordinator_secret_versions == { LINEAR_API_KEY = "7", LINEAR_API_TOKEN = "2" } && toset(keys(local.worker_config.secret_ids)) == toset(["model_auth", "git_read"]) && !contains(keys(local.worker_config), "coordinator_secret_env")
    error_message = "Only the coordinator receives pinned integration credential references."
  }
}

run "webhook_cannot_enable_without_dashboard_identity_gate" {
  command = plan
  variables {
    enable_linear_webhook = true
  }
  expect_failures = [var.enable_linear_webhook]
}
