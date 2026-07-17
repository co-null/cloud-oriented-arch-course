# Вивід URL для bucket
output "static_site_url" {
  description = "URL для доступу до статичного сайту"
  value       = "http://${google_storage_bucket.static_site.name}.storage.googleapis.com/index.html"
}

output "apartments_api_url" {
  description = "URL apartments Cloud Function"
  value       = google_cloudfunctions_function.apartments_api.https_trigger_url
}

output "bookings_api_url" {
  description = "URL bookings Cloud Function"
  value       = google_cloudfunctions_function.bookings_api.https_trigger_url
}

output "dispatcher_url" {
  description = "URL dispatcher Cloud Function"
  value       = google_cloudfunctions_function.pubsub_dispatcher.https_trigger_url
}

output "generate_import_url_endpoint" {
  description = "URL для отримання Signed URL для CSV завантаження"
  value       = google_cloudfunctions_function.generate_import_url.https_trigger_url
}

output "import_bucket_name" {
  description = "Назва GCS bucket для CSV-завантажень"
  value       = google_storage_bucket.apartments_imports.name
}

output "watchdog_url" {
  description = "URL watchdog функції (для ручного тестування)"
  value       = google_cloudfunctions_function.watchdog.https_trigger_url
}

output "watchdog_scheduler_job" {
  description = "Назва Cloud Scheduler job"
  value       = google_cloud_scheduler_job.watchdog_job.name
}

output "main_pubsub_topic" {
  description = "Назва основного Pub/Sub топіку"
  value       = google_pubsub_topic.main_topic.name
}

output "dlq_topic" {
  description = "Назва DLQ топіку"
  value       = google_pubsub_topic.notification_dlq.name
}