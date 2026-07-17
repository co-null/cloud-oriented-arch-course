# Service Account для Cloud Functions
resource "google_service_account" "pubsub_function_sa" {
  account_id   = "pubsub-function-sa"
  display_name = "Pub/Sub Cloud Function Service Account"
  description  = "Service account for Cloud Functions that work with Pub/Sub"
  project      = var.project_id
}

# Service Account для Publisher
resource "google_service_account" "pubsub_publisher_sa" {
  account_id   = "pubsub-publisher-sa"
  display_name = "Pub/Sub Publisher Service Account"
  description  = "Service account for publishing messages to Pub/Sub"
  project      = var.project_id
}

# Service Account для Subscriber
resource "google_service_account" "pubsub_subscriber_sa" {
  account_id   = "pubsub-subscriber-sa"
  display_name = "Pub/Sub Subscriber Service Account"
  description  = "Service account for subscribing to Pub/Sub messages"
  project      = var.project_id
}

# Service Account для Dispatcher
resource "google_service_account" "dispatcher_sa" {
  account_id   = "pubsub-dispatcher-sa"
  display_name = "Pub/Sub Dispatcher Function SA"
  project      = var.project_id  # явно вказуємо project
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
