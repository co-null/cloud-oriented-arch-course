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

