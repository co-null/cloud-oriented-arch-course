# Додати/отримати квартири
# Завантаження (копіювання/оновлення) функції (як архіву) для apartments з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "apartments_function_zip" {
  name   = "apartments.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/apartments/apartments.zip"
}

resource "google_cloudfunctions_function" "apartments_api" {
  name        = "apartments"
  description = "Endpoint for apartments"
  runtime     = "python310"
  entry_point = "main"
  trigger_http = true
  available_memory_mb = 256

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.apartments_function_zip.name

  service_account_email = google_service_account.pubsub_function_sa.email

  environment_variables = {
    GCP_PROJECT = var.project_id
    PUBSUB_TOPIC = google_pubsub_topic.main_topic.name
  }

  depends_on = [
    google_service_account.pubsub_function_sa,
    google_pubsub_topic.main_topic
  ]

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "apartments_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.apartments_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}
