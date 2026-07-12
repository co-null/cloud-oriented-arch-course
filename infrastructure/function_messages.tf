# Події з топіку
# Завантаження останніх подій з топіку
resource "google_storage_bucket_object" "messages_function_zip" {
  name   = "messages.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/messages/messages.zip"
}

resource "google_cloudfunctions_function" "messages_api" {
  name        = "messages"
  description = "Endpoint for messages"
  runtime     = "python310"
  entry_point = "main"
  trigger_http = true
  available_memory_mb = 256

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.messages_function_zip.name

  service_account_email = google_service_account.pubsub_function_sa.email

  environment_variables = {
    GCP_PROJECT = var.project_id
    PUBSUB_TOPIC = google_pubsub_topic.main_topic.name
    PUBSUB_SUBSCRIPTION = google_pubsub_subscription.main_subscription.name
  }

  depends_on = [
    google_service_account.pubsub_function_sa,
    google_pubsub_topic.main_topic,
    google_pubsub_subscription.main_subscription
  ]

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "messages_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.messages_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}
