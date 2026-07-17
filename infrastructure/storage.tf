# ═══════════════════════════════════════════════════════════
# STORAGE: CSV IMPORT PIPELINE
#
# Статичний сайт та function bucket — в main.tf
# ═══════════════════════════════════════════════════════════

# GCS Service Account потребує дозволу публікувати в наш топік
data "google_storage_project_service_account" "gcs_sa" {
  depends_on = [google_project_service.apis]
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
      with_state         = "ARCHIVED"
    }
  }

  lifecycle_rule {
    action { type = "Delete" }
    condition { age = 90 }
  }

  # CORS для завантаження з браузерного admin UI
  cors {
    origin          = ["*"] # не рекомендовано для production!
    method          = ["PUT", "OPTIONS"]
    response_header = ["Content-Type", "ETag", "X-Goog-Upload-Status"]
    max_age_seconds = 3600
  }

  depends_on = [google_project_service.apis]
}


# Налаштовуємо notification: тільки OBJECT_FINALIZE, тільки папка imports/
resource "google_storage_notification" "csv_import_notification" {
  bucket         = google_storage_bucket.apartments_imports.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.csv_imports.id
  event_types    = ["OBJECT_FINALIZE"]
  # Фільтруємо: тільки файли в imports/, не в quarantine/
  object_name_prefix = "imports/"

  depends_on = [google_pubsub_topic_iam_member.gcs_csv_imports_publisher]
}