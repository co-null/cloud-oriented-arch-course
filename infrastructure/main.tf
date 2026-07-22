# ═══════════════════════════════════════════════════════════
# ПРОВАЙДЕРИ
# ═══════════════════════════════════════════════════════════

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ═══════════════════════════════════════════════════════════
# АКТИВАЦІЯ GCP API
#
# disable_on_destroy = false: при terraform destroy API залишаються
# увімкненими — інші ресурси проєкту можуть від них залежати.
# ═══════════════════════════════════════════════════════════

resource "google_project_service" "apis" {
  for_each = toset([
    # Cloud Functions Gen 1 — основний сервіс деплою функцій
    "cloudfunctions.googleapis.com",

    # Pub/Sub — черга подій; топік booking-events вже існує з попередньої теми
    "pubsub.googleapis.com",

    # IAM - сервіс ролей доступу
    "iam.googleapis.com",

    # Secret Manager — захищене зберігання MAILGUN_API_KEY
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
    "iamcredentials.googleapis.com",
    "cloudscheduler.googleapis.com"
  ])

  service            = each.key
  disable_on_destroy = false
}

# Pub/Sub Service Identity — потрібен для DLQ та push-підписок
resource "google_project_service_identity" "pubsub_agent" {
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"

  # Pub/Sub API має бути активований до провізіонування агента
  depends_on = [google_project_service.apis]
}

# ═══════════════════════════════════════════════════════════
# STORAGE BUCKETS — загальні
# ═══════════════════════════════════════════════════════════
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