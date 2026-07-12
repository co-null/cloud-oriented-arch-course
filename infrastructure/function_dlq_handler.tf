# dlq-handler
# Завантаження (копіювання/оновлення) функції (як архіву) для dlq-handler з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "dlq_handler_function_zip" {
  name   = "dlq_handler.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/dlq_handler/dlq_handler.zip"
}

resource "google_cloudfunctions_function" "dlq_handler" {
  name        = "dlq_handler"
  description = "Логує повідомлення з Dead Letter Queue та відправляє алерти"
  runtime     = "python310"
  entry_point = "main"
  available_memory_mb = 128
  timeout = 60

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.dlq_handler_function_zip.name
  service_account_email = google_service_account.dispatcher_sa.email

  # Gen 1 нативний Pub/Sub тригер
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.notification_dlq.id

    failure_policy {
      retry = false  # DLQ не ретраїмо — лише логуємо
    }
  }

  environment_variables = {
    GCP_PROJECT      = var.project_id
  }

  depends_on = [
    google_project_service.apis,
    google_pubsub_topic.notification_dlq
  ]
}
