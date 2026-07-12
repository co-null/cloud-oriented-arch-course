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