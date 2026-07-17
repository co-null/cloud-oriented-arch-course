# ═══════════════════════════════════════════════════════════
# SERVICE ACCOUNTS
#
# Цей файл містить ТІЛЬКИ визначення service accounts.
# Всі IAM права — в iam.tf
# ═══════════════════════════════════════════════════════════

# Загальний SA для Cloud Functions що працюють з Pub/Sub
resource "google_service_account" "pubsub_function_sa" {
  account_id   = "pubsub-function-sa"
  display_name = "Pub/Sub Cloud Function Service Account"
  description  = "Service account for Cloud Functions that work with Pub/Sub"
  project      = var.project_id
}

# SA виключно для публікації повідомлень (не використовується функціями напряму)
resource "google_service_account" "pubsub_publisher_sa" {
  account_id   = "pubsub-publisher-sa"
  display_name = "Pub/Sub Publisher Service Account"
  description  = "Service account for publishing messages to Pub/Sub"
  project      = var.project_id
}

# SA для читання підписок
resource "google_service_account" "pubsub_subscriber_sa" {
  account_id   = "pubsub-subscriber-sa"
  display_name = "Pub/Sub Subscriber Service Account"
  description  = "Service account for subscribing to Pub/Sub messages"
  project      = var.project_id
}

# SA для dispatcher функції (окремий через OIDC push-підписку)
resource "google_service_account" "dispatcher_sa" {
  account_id   = "pubsub-dispatcher-sa"
  display_name = "Pub/Sub Dispatcher Function SA"
  project      = var.project_id  # явно вказуємо project
}

# SA для Cloud Scheduler (watchdog jobs)
resource "google_service_account" "scheduler_sa" {
  account_id   = "scheduler-sa"
  display_name = "Cloud Scheduler SA"
  description  = "SA для виклику Cloud Functions через Cloud Scheduler"
  project      = var.project_id
}

# SA для функції генерації Signed URL
resource "google_service_account" "url_generator_sa" {
  account_id   = "import-url-generator-sa"
  display_name = "SA: Import URL Generator Function"
}

# SA для функції обробки CSV
resource "google_service_account" "csv_importer_sa" {
  account_id   = "csv-importer-sa"
  display_name = "SA: CSV Importer Function"
}
