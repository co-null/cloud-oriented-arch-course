# Використання провайдера Google Cloud
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# 
# АКТИВАЦІЯ GCP API
#
# GCP за замовчуванням вимикає більшість API у новому проєкті.
# Terraform активує їх автоматично перед деплоєм ресурсів.
#
# disable_on_destroy = false означає, що при знищенні інфраструктури
# через `terraform destroy` API залишаться увімкненими. Це безпечніше,
# ніж їх вимикати — інші ресурси в проєкті можуть від них залежати.
# 
resource "google_project_service" "apis" {
  for_each = toset([
# Cloud Functions Gen 1 — основний сервіс деплою функцій
    "cloudfunctions.googleapis.com",

    # Pub/Sub — черга подій; топік apartment-events вже існує з попередньої теми
    "pubsub.googleapis.com",

    # IAM - сервіс ролей доступу
    "iam.googleapis.com",

    # Secret Manager — захищене зберігання MAILGUN_API_KEY та MAILGUN_DOMAIN
    "secretmanager.googleapis.com",

    # Cloud Build — збірка та деплой коду функцій з GCS
    "cloudbuild.googleapis.com",

    # Firestore — idempotency store для захисту від дублювання листів
    "firestore.googleapis.com",

    # Cloud Monitoring — метрики та алерти
    "monitoring.googleapis.com",

    # Cloud Logging — структуроване логування функцій
    "logging.googleapis.com",

    "storage.googleapis.com",
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com"
  ])

  service            = each.key
  disable_on_destroy = false
}

resource "google_project_service_identity" "pubsub_agent" {
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"

  # Pub/Sub API має бути активований до провізіонування агента
  depends_on = [google_project_service.apis]
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

# Bucket для CSV-завантажень від адміністраторів
resource "google_storage_bucket" "apartments_imports" {
  name                        = "${var.project_id}-apartments-imports"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  # Soft Delete: вимкнено — CSV-файли є тимчасовими
  soft_delete_policy {
    retention_duration_seconds = 0
  }

  # Версіонування: увімкнено для аудиту завантажень
  versioning {
    enabled = true
  }

  # Lifecycle: зберігаємо тільки 3 версії, видаляємо все через 90 днів
  lifecycle_rule {
    action { type = "Delete" }
    condition {
      num_newer_versions = 3
      is_live            = false
    }
  }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 90 }
  }

  # CORS для завантаження з браузерного admin UI
  cors {
    origin          = [*] # не рекомендовано для production!
    method          = ["PUT", "OPTIONS"]
    response_header = ["Content-Type", "ETag", "X-Goog-Upload-Status"]
    max_age_seconds = 3600
  }

  depends_on = [google_project_service.apis]
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

# Вивід URL для bucket
output "static_site_url" {
  description = "URL для доступу до статичного сайту"
  value       = "http://${google_storage_bucket.static_site.name}.storage.googleapis.com/index.html"
}
