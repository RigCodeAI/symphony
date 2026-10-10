locals {
  monitored_events = toset([
    "service_unhealthy",
    "backup_failed",
    "archive_failed",
  ])
}

resource "google_monitoring_notification_channel" "email" {
  for_each = var.notification_emails

  project      = var.project_id
  display_name = "${var.name_prefix} alert ${each.value}"
  type         = "email"
  enabled      = true

  labels = {
    email_address = each.value
  }
}

resource "google_logging_metric" "factory_event" {
  for_each = local.monitored_events

  project = var.project_id
  name    = "${var.name_prefix}_${each.value}"
  filter  = "resource.type=\"gce_instance\" AND logName=\"${local.event_log_name}\" AND jsonPayload.message:\"FACTORY_EVENT ${each.value}\""

  metric_descriptor {
    metric_kind  = "DELTA"
    value_type   = "INT64"
    unit         = "1"
    display_name = "Factory ${replace(each.value, "_", " ")} events"
  }
}

resource "google_monitoring_alert_policy" "factory_event" {
  for_each = local.monitored_events

  project      = var.project_id
  display_name = "${var.name_prefix}: ${replace(each.value, "_", " ")}"
  combiner     = "OR"
  enabled      = true

  notification_channels = [
    for channel in values(google_monitoring_notification_channel.email) : channel.name
  ]

  documentation {
    mime_type = "text/markdown"
    content   = "The coordinator emitted `FACTORY_EVENT ${each.value}`. Inspect the `factory-events` log and the coordinator service."
  }

  conditions {
    display_name = "${each.value} was emitted"

    condition_threshold {
      filter          = "resource.type=\"gce_instance\" AND metric.type=\"logging.googleapis.com/user/${google_logging_metric.factory_event[each.key].name}\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"

      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "low_disk" {
  count = var.compute_enabled ? 1 : 0

  project      = var.project_id
  display_name = "${var.name_prefix}: disk use above 80%"
  combiner     = "OR"
  enabled      = true

  notification_channels = [
    for channel in values(google_monitoring_notification_channel.email) : channel.name
  ]

  documentation {
    mime_type = "text/markdown"
    content   = "An Ops Agent disk filesystem reported at least 80% use. Check coordinator and worker disk headroom before dispatching more work."
  }

  conditions {
    display_name = "Ops Agent disk utilization exceeds 80%"

    condition_threshold {
      filter          = "resource.type=\"gce_instance\" AND metric.type=\"agent.googleapis.com/disk/percent_used\" AND metric.labels.state=\"used\" AND (${local.low_disk_instance_filter})"
      comparison      = "COMPARISON_GT"
      threshold_value = 80
      duration        = "300s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_MAX"
        cross_series_reducer = "REDUCE_MAX"
        group_by_fields      = ["resource.labels.instance_id"]
      }

      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_billing_budget" "pilot" {
  billing_account = var.billing_account_id
  display_name    = "${var.name_prefix} monthly pilot budget"

  budget_filter {
    projects = ["projects/${var.project_number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(floor(var.budget_amount_usd))
      nanos         = floor((var.budget_amount_usd - floor(var.budget_amount_usd)) * 1000000000)
    }
  }

  threshold_rules {
    threshold_percent = 0.5
  }

  threshold_rules {
    threshold_percent = 0.8
  }

  threshold_rules {
    threshold_percent = 1.0
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "FORECASTED_SPEND"
  }

  all_updates_rule {
    disable_default_iam_recipients = true
    monitoring_notification_channels = [
      for channel in values(google_monitoring_notification_channel.email) : channel.name
    ]
  }
}
