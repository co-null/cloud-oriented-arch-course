# IAM права  для Dispatcher
# Dispatcher: запис логів
resource "google_project_iam_member" "dispatcher_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# Dispatcher: запис метрик
resource "google_project_iam_member" "dispatcher_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# Dispatcher: Firestore для idempotency store
resource "google_project_iam_member" "dispatcher_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# Dispatcher SA може генерувати OIDC-токени для push-підписки
# Потрібно щоб Pub/Sub міг підписувати запити від імені цього SA
resource "google_service_account_iam_member" "pubsub_agent_token_creator" {
  service_account_id = google_service_account.dispatcher_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.pubsub_agent.member
}

# Диспетчер
# Завантаження (копіювання/оновлення) функції (як архіву) для dispatcher з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "dispatcher_function_zip" {
  name   = "dispatcher.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/dispatcher/dispatcher.zip"
}

resource "google_cloudfunctions_function" "pubsub_dispatcher" {
  name        = "pubsub_dispatcher"
  description = "Підписується на booking-events (dispatcher_push_sub) та викликає send_email по REST"
  runtime     = "python310"
  entry_point = "main"
  available_memory_mb = 256
  timeout = 60

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.dispatcher_function_zip.name
  service_account_email = google_service_account.dispatcher_sa.email

  trigger_http = true
  https_trigger_security_level = "SECURE_ALWAYS"
  ingress_settings             = "ALLOW_ALL"

  environment_variables = {
    GCP_PROJECT      = var.project_id
    EMAIL_SENDER_URL = google_cloudfunctions_function.send_email.https_trigger_url
    ADMIN_EMAIL      = var.admin_email
    PUBSUB_TOPIC     = google_pubsub_topic.main_topic.name
  }

  depends_on = [
    google_project_service.apis,
    google_cloudfunctions_function.send_email,
    google_project_iam_member.dispatcher_firestore,
    google_pubsub_topic.main_topic
  ]
}

resource "google_cloudfunctions_function_iam_member" "dispatcher_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.pubsub_dispatcher.name
  role           = "roles/cloudfunctions.invoker"
  member         = google_project_service_identity.pubsub_agent.member
}

resource "google_cloudfunctions_function_iam_member" "dispatcher_sa_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.pubsub_dispatcher.name
  role           = "roles/cloudfunctions.invoker"
  member         = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}