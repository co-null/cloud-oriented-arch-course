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
    google_project_service.apis,
    google_cloudfunctions_function.watchdog
  ]
}
