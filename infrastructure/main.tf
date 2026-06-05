# Використання провайдера Google Cloud
provider "google" {
  project = var.project_id
  region  = var.region
}

# Створення Google Cloud Storage bucket для статичного сайту
resource "google_storage_bucket" "static_site" {
  name     = var.bucket_name
  location = var.region

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  force_destroy = true # Дозволяє видаляти bucket разом із файлами
}

# Відкриємо сторінку для всіх
resource "google_storage_bucket_iam_member" "public_rule" {
  bucket = google_storage_bucket.static_site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Завантаження (копіювання/оновлення) статичних файлів із локальної директорії у bucket
resource "google_storage_bucket_object" "static_files" {
  # Для кожного файлу у директорії ./src/static створюється об'єкт у bucket
  for_each = fileset("${path.module}/../src/static", "**/*.*")

  name   = each.key
  bucket = google_storage_bucket.static_site.name
  source = "${path.module}/../src/static/${each.key}"

  content_type = (
    can(regex("\\.css$", each.key)) ? "text/css" :
    can(regex("\\.js$", each.key)) ? "application/javascript" :
    can(regex("\\.html?$", each.key)) ? "text/html" :
    can(regex("\\.png$", each.key)) ? "image/png" :
    can(regex("\\.jpe?g$", each.key)) ? "image/jpeg" :
    can(regex("\\.svg$", each.key)) ? "image/svg+xml" :
    null
  )
}

# Створення Google Cloud Storage bucket для функцій (ім'я буде відповідати [ІД вашого проєкту]-function-bucket)
resource "google_storage_bucket" "function_bucket" {
  name     = "${var.project_id}-function-bucket"
  location = var.region
  force_destroy = true 
}

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
  available_memory_mb = 256

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


# Вивід URL для bucket
output "static_site_url" {
  description = "URL для доступу до статичного сайту"
  value       = "http://${google_storage_bucket.static_site.name}.storage.googleapis.com/index.html"
}
