mock_provider "google" {
  override_during = plan
  mock_data "google_project" {
    defaults = { number = "123456789012" }
  }
}

variables {
  project_id                    = "factory-pilot-test"
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

run "managed_domain_satisfies_root_viewer_gate" {
  command = plan
  variables {
    enable_https_iap                   = true
    viewer_hostname                    = "factory.example.test"
    iap_viewer_emails                  = []
    iap_viewer_domains                 = ["rig.ai"]
    iap_google_managed_oauth_confirmed = true
  }
  assert {
    condition     = output.coordinator_https_url == "https://factory.example.test"
    error_message = "Domain-only access must satisfy the root ingress viewer requirement."
  }
}

run "empty_viewers_block_ingress" {
  command = plan
  variables {
    enable_https_iap                   = true
    viewer_hostname                    = "factory.example.test"
    iap_google_managed_oauth_confirmed = true
  }
  expect_failures = [var.enable_https_iap]
}

run "unconfirmed_organization_blocks_domain_ingress" {
  command = plan
  variables {
    enable_https_iap   = true
    viewer_hostname    = "factory.example.test"
    iap_viewer_domains = ["rig.ai"]
  }
  expect_failures = [var.enable_https_iap]
}

run "malformed_root_domain_rejected" {
  command = plan
  variables {
    iap_viewer_domains = ["domain:rig.ai"]
  }
  expect_failures = [var.iap_viewer_domains]
}
