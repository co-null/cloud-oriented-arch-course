# Блок для роботи з сервісними акаунтами
# Права для роботи з Firestore
resource "google_project_iam_member" "function_sa_firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# Додаткові права для Firestore (якщо потрібно створювати колекції)
resource "google_project_iam_member" "function_sa_firestore_owner" {
  project = var.project_id
  role    = "roles/datastore.owner"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# Права для Firebase Admin SDK
resource "google_project_iam_member" "function_sa_firebase_admin" {
  project = var.project_id
  role    = "roles/firebase.admin"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# Project-level IAM для Service Accounts
resource "google_project_iam_member" "function_sa_pubsub_admin" {
  project = var.project_id
  role    = "roles/pubsub.admin"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

resource "google_project_iam_member" "function_sa_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

resource "google_project_iam_member" "function_sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# IAM для створення топіків (якщо потрібно динамічне створення)
resource "google_project_iam_member" "function_sa_topic_admin" {
  project = var.project_id
  role    = "roles/pubsub.editor"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# Права для всіх Cloud Functions на використання Service Account
resource "google_service_account_iam_member" "functions_sa_user" {
  service_account_id = google_service_account.pubsub_function_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.project_id}@appspot.gserviceaccount.com"
}

# Додаткові права для функцій
# Права на створення підписок
resource "google_project_iam_member" "function_sa_subscription_admin" {
  project = var.project_id
  role    = "roles/pubsub.admin"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# Створення токену для авторизації для функції диспетчера
resource "google_project_iam_member" "function_sa_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# ─── Права для url_generator_sa ──────────────────────────────────────────────

# Може писати об'єкти в import bucket (для підпису URL)
resource "google_storage_bucket_iam_member" "url_gen_bucket_creator" {
  bucket = google_storage_bucket.apartments_imports.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.url_generator_sa.email}"
}

# Keyless signing: може підписувати від свого імені
resource "google_service_account_iam_member" "url_gen_token_creator" {
  service_account_id = google_service_account.url_generator_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.url_generator_sa.email}"
}

# Може писати в Firestore (для запису pending-статусу)
resource "google_project_iam_member" "url_gen_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.url_generator_sa.email}"
}

# ─── Права для csv_importer_sa ───────────────────────────────────────────────

# Може читати файли з import bucket
resource "google_storage_bucket_iam_member" "importer_bucket_reader" {
  bucket = google_storage_bucket.apartments_imports.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# Може також писати (для переміщення файлів у quarantine/)
resource "google_storage_bucket_iam_member" "importer_bucket_creator" {
  bucket = google_storage_bucket.apartments_imports.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# Може видаляти (для переміщення в quarantine)
resource "google_storage_bucket_iam_member" "importer_bucket_admin" {
  bucket = google_storage_bucket.apartments_imports.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# Firestore: читання і запис
resource "google_project_iam_member" "importer_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# Може публікувати в існуючий топік подій квартир
resource "google_pubsub_topic_iam_member" "importer_apartment_events_publisher" {
  topic  = var.apartment_events_topic
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# Може читати з Pub/Sub subscription (потрібно для Cloud Function)
resource "google_pubsub_subscription_iam_member" "importer_subscriber" {
  subscription = google_pubsub_subscription.csv_import_processor.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}