# Використання провайдера Google Cloud
# Email функція
# Завантаження (копіювання/оновлення) функції (як архіву) для email з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "email_function_zip" {
  name   = "send-email.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/send-email/send-email.zip"
}

# Передаємо секрет в Cloud Function
resource "google_cloudfunctions_function" "send_email" {
  name = "send_email"
  runtime = "python310"
  entry_point = "send_email"
  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.email_function_zip.name
  trigger_http = true
  available_memory_mb = 128

  secret_environment_variables {
    key    = "MAILGUN_API_KEY"
    project_id = var.project_id
    secret = "MAILGUN_API_KEY"
    version = "latest"
  }
  environment_variables = {
    MAILGUN_DOMAIN = var.mailgun_domain
  }
}

# IAM-політики для Cloud Function
resource "google_secret_manager_secret_iam_member" "send_email_function_access" {
  secret_id = "projects/${var.project_id}/secrets/MAILGUN_API_KEY"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_cloudfunctions_function.send_email.service_account_email}"
}

resource "google_cloudfunctions_function_iam_member" "send_email_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.send_email.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}
