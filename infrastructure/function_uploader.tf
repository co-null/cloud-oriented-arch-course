# Завантаження файлів
resource "google_storage_bucket_object" "url_generator_zip" {
  name   = "url_generator.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/url_generator/url_generator.zip"
}

resource "google_storage_bucket_object" "csv_importer_zip" {
  name   = "csv_importer.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/csv_importer/csv_importer.zip"
}

# HTTP функція: генерує Signed URL для завантаження
resource "google_cloudfunctions_function" "generate_import_url" {
  name        = "generate-import-url"
  description = "Generates Signed URL for CSV apartment import"
  runtime     = "python310"
  region      = var.region

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.url_generator_zip.name

  trigger_http          = true
  entry_point           = "generate_import_url"
  service_account_email = google_service_account.url_generator_sa.email

  available_memory_mb = 256
  timeout             = 60

  environment_variables = {
    IMPORT_BUCKET   = google_storage_bucket.apartments_imports.name
    SIGNING_SA      = google_service_account.url_generator_sa.email
    GCP_PROJECT     = var.project_id
  }

  depends_on = [
    google_project_service.apis,
    google_storage_bucket_object.url_generator_zip
  ]
}


# Pub/Sub-triggered функція: обробляє CSV
resource "google_cloudfunctions_function" "import_apartments" {
  name        = "import-apartments"
  description = "Processes uploaded CSV to bulk-import apartments into Firestore"
  runtime     = "python310"
  region      = var.region

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.csv_importer_zip.name

  entry_point           = "import_apartments"
  service_account_email = google_service_account.csv_importer_sa.email

  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.csv_imports.id

    failure_policy {
      retry = true  # Retry + DLQ після 5 спроб
    }
  }

  available_memory_mb = 512   # CSV-парсинг потребує пам'яті
  timeout             = 540   # 9 хвилин — максимум для Gen 1

  environment_variables = {
    IMPORT_BUCKET          = google_storage_bucket.apartments_imports.name
    GCP_PROJECT            = var.project_id
    APARTMENT_EVENTS_TOPIC = var.topic_name
  }

  depends_on = [
    google_project_service.apis,
    google_storage_bucket_object.csv_importer_zip,
    google_storage_notification.csv_import_notification
  ]
}

# Дозволяємо виклик HTTP функції (лише для authenticated users проєкту)
resource "google_cloudfunctions_function_iam_member" "url_gen_invoker" {
  project        = google_cloudfunctions_function.generate_import_url.project
  region         = google_cloudfunctions_function.generate_import_url.region
  cloud_function = google_cloudfunctions_function.generate_import_url.name
  role           = "roles/cloudfunctions.invoker"
  # В production: замінити на SA вашого auth middleware / API Gateway
  member         = "allUsers"
}
