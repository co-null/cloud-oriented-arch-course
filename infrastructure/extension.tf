# terraform/extension.tf
# Розширення наявної інфраструктури: Watchdog + Cloud Scheduler + розширений моніторинг
#
# Залежить від ресурсів з main.tf:
#   - google_project_service.apis
#   - google_storage_bucket.function_bucket
#   - google_service_account.dispatcher_sa
#   - google_monitoring_notification_channel.team_email
#   - var.project_id, var.region


# ──────────────────────────────────────────────────────────────────────────────
# НОВІ API
# ──────────────────────────────────────────────────────────────────────────────

resource "google_project_service" "scheduler_api" {
  service            = "cloudscheduler.googleapis.com"
  disable_on_destroy = false
  depends_on         = [google_project_service.apis]
}

# ──────────────────────────────────────────────────────────────────────────────
# WATCHDOG FUNCTION
# ──────────────────────────────────────────────────────────────────────────────

resource "google_storage_bucket_object" "watchdog_function_zip" {
  name   = "watchdog.zip"
  bucket = google_storage_bucket.function_bucket.name
  # function_bucket визначено у main.tf — просто додаємо новий об'єкт
  source = "${path.module}/../src/cloud-functions/watchdog/watchdog.zip"
}

resource "google_cloudfunctions_function" "watchdog" {
  name        = "watchdog"
  description = "Виявляє 'завислі' бронювання та фіксує timeout"
  runtime     = "python310"
  entry_point = "check_stuck_bookings"

  trigger_http        = true
  available_memory_mb = 128
  timeout             = 60

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.watchdog_function_zip.name

  # Використовуємо існуючий dispatcher_sa з main.tf
  # Він вже має roles/datastore.user для Firestore
  service_account_email = google_service_account.dispatcher_sa.email

  environment_variables = {
    GCP_PROJECT              = var.project_id
    WATCHDOG_TIMEOUT_MINUTES = tostring(var.watchdog_timeout_minutes)
  }

  ingress_settings             = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"

  depends_on = [
    google_project_service.apis,
    google_service_account.dispatcher_sa
  ]
}

# Лише scheduler_sa може викликати watchdog — не публічний endpoint
resource "google_cloudfunctions_function_iam_member" "watchdog_scheduler_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.watchdog.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

# ──────────────────────────────────────────────────────────────────────────────
# SERVICE ACCOUNT ДЛЯ CLOUD SCHEDULER
# Окремий SA за принципом least privilege
# ──────────────────────────────────────────────────────────────────────────────

resource "google_service_account" "scheduler_sa" {
  account_id   = "scheduler-sa"
  display_name = "Cloud Scheduler Service Account"
  description  = "SA для виклику Cloud Functions через Cloud Scheduler"
  project      = var.project_id
}

resource "google_project_iam_member" "scheduler_functions_invoker" {
  project = var.project_id
  role    = "roles/cloudfunctions.invoker"
  member  = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLOUD SCHEDULER JOB
# ──────────────────────────────────────────────────────────────────────────────

resource "google_cloud_scheduler_job" "watchdog_job" {
  name             = "watchdog-job"
  description      = "Запускає watchdog кожні 5 хвилин для виявлення stuck бронювань"
  schedule         = var.watchdog_schedule
  time_zone        = "Europe/Kyiv"
  project          = var.project_id
  region           = var.region
  attempt_deadline = "30s"

  retry_config {
    retry_count          = 1
    min_backoff_duration = "5s"
    max_backoff_duration = "30s"
    max_retry_duration   = "60s"
    max_doublings        = 2
  }

  http_target {
    http_method = "POST"
    uri         = google_cloudfunctions_function.watchdog.https_trigger_url

    body = base64encode(jsonencode({
      source = "cloud_scheduler"
      job    = "watchdog-job"
    }))

    headers = {
      "Content-Type" = "application/json"
    }

    # OIDC токен — Cloud Scheduler автентифікується як scheduler_sa
    oidc_token {
      service_account_email = google_service_account.scheduler_sa.email
      audience              = google_cloudfunctions_function.watchdog.https_trigger_url
    }
  }

  depends_on = [
    google_project_service.scheduler_api,
    google_cloudfunctions_function.watchdog
  ]
}

# ──────────────────────────────────────────────────────────────────────────────
# РОЗШИРЕНИЙ МОНІТОРИНГ
# Використовує team_email notification channel з main.tf
# ──────────────────────────────────────────────────────────────────────────────

# Алерт: зростаючий backlog у dispatcher підписці
resource "google_monitoring_alert_policy" "dispatcher_backlog_high" {
  display_name = "⚠️ Dispatcher: backlog повідомлень > 50"
  combiner     = "OR"

  conditions {
    display_name = "High undelivered message count in dispatcher subscription"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"pubsub_subscription\"",
        "resource.labels.subscription_id=\"dispatcher-push-sub\"",
        "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 50
      duration        = "300s"  # 5 хвилин

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
    notification_channel_strategy {
      notification_channel_names = [google_monitoring_notification_channel.team_email.name]
      renotify_interval          = "3600s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Dispatcher не встигає обробляти повідомлення. Перевірте логи pubsub_dispatcher та send_email. Можливі причини: rate limit Mailgun, помилки Firestore, велике навантаження."
    mime_type = "text/markdown"
  }
}

# Алерт: старе повідомлення у dispatcher черзі
resource "google_monitoring_alert_policy" "dispatcher_message_too_old" {
  display_name = "🕐 Dispatcher: повідомлення очікує > 10 хвилин"
  combiner     = "OR"

  conditions {
    display_name = "Oldest unacked message age > 10 minutes"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"pubsub_subscription\"",
        "resource.labels.subscription_id=\"dispatcher-push-sub\"",
        "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 600   # 10 хвилин у секундах
      duration        = "120s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Є повідомлення у черзі dispatcher'а що чекає обробки більше 10 хвилин. Це може означати 'зависле' бронювання. Перевірте Firestore колекцію bookings на записи зі статусом 'processing'."
    mime_type = "text/markdown"
  }
}

# Алерт: помилки у watchdog функції
resource "google_monitoring_alert_policy" "watchdog_execution_errors" {
  display_name = "🔧 Watchdog: помилки виконання"
  combiner     = "OR"

  conditions {
    display_name = "Any watchdog execution error"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"cloud_function\"",
        "resource.labels.function_name=\"watchdog\"",
        "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\"",
        "metric.labels.status=\"error\""
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0   # будь-яка помилка watchdog — вже інцидент
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Watchdog функція впала. Перевірте логи: gcloud functions logs read watchdog --limit=50"
    mime_type = "text/markdown"
  }
}

# Алерт: висока latency dispatcher або send_email
resource "google_monitoring_alert_policy" "critical_functions_high_latency" {
  display_name = "⏱ Критичні функції: p99 latency > 10 секунд"
  combiner     = "OR"

  dynamic "conditions" {
    for_each = toset(["pubsub_dispatcher", "send_email"])
    content {
      display_name = "p99 latency > 10s for ${conditions.key}"
      condition_threshold {
        filter = join(" AND ", [
          "resource.type=\"cloud_function\"",
          "resource.labels.function_name=\"${conditions.key}\"",
          "metric.type=\"cloudfunctions.googleapis.com/function/execution_times\""
        ])
        comparison      = "COMPARISON_GT"
        threshold_value = 10000000000  # 10 секунд у наносекундах
        duration        = "300s"

        aggregations {
          alignment_period     = "60s"
          per_series_aligner   = "ALIGN_PERCENTILE_99"
          cross_series_reducer = "REDUCE_MEAN"
          group_by_fields      = ["resource.labels.function_name"]
        }
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]
}

# ──────────────────────────────────────────────────────────────────────────────
# OUTPUTS
# ──────────────────────────────────────────────────────────────────────────────

output "watchdog_url" {
  description = "URL watchdog функції (для ручного тестування)"
  value       = google_cloudfunctions_function.watchdog.https_trigger_url
}

output "watchdog_scheduler_job_name" {
  description = "Назва Cloud Scheduler job"
  value       = google_cloud_scheduler_job.watchdog_job.name
}