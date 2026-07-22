# Блок для роботи з сервісними акаунтами
# Права для роботи з Firestore
resource "google_project_iam_member" "function_sa_firestore_user" {
  project = var.project_id
  role    = "roles/datastore.user"
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

# Створення токену для авторизації для функції диспетчера
resource "google_project_iam_member" "function_sa_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}