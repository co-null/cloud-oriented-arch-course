# Check-token функція
# Завантаження (копіювання/оновлення) функції (як архіву) для Check-token з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "check_token_function_zip" {
  name   = "check-token.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/check-token/check-token.zip"
}

resource "google_cloudfunctions_function" "protected_api" {
  name        = "protected-api"
  description = "Protected endpoint with Firebase token check"
  runtime     = "python310"
  entry_point = "protected"
  trigger_http = true
  available_memory_mb = 128

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.check_token_function_zip.name

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "protected_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.protected_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}
