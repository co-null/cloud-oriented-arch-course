# ═══════════════════════════════════════════════════════════
# IAM — ЄДИНИЙ ФАЙЛ ДЛЯ ВСІХ ПРАВ ДОСТУПУ
#
# Структура:
#   1. pubsub_function_sa  (apartments, bookings, messages)
#   2. dispatcher_sa
#   3. scheduler_sa
#   4. url_generator_sa
#   5. csv_importer_sa
#   6. Pub/Sub топіки — bindings
#   7. Pub/Sub підписки — bindings
#   8. Pub/Sub агент (DLQ, OIDC)
# ═══════════════════════════════════════════════════════════

# ───────────────────────────────────────────────────────────
# 1. pubsub_function_sa
#    Використовується: apartments, bookings, messages функції
#
# ───────────────────────────────────────────────────────────

resource "google_project_iam_member" "function_sa_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"   # читання і запис Firestore
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

# App Engine default SA може використовувати pubsub_function_sa
# (потрібно для деплою Gen 1 Cloud Functions)
resource "google_service_account_iam_member" "functions_sa_user" {
  service_account_id = google_service_account.pubsub_function_sa.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.project_id}@appspot.gserviceaccount.com"
}

# ───────────────────────────────────────────────────────────
# 2. dispatcher_sa
# ───────────────────────────────────────────────────────────

# Dispatcher: Firestore для idempotency store
resource "google_project_iam_member" "dispatcher_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# Dispatcher: запис логів
resource "google_project_iam_member" "dispatcher_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# Dispatcher: запис метрик
resource "google_project_iam_member" "dispatcher_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# Pub/Sub агент може генерувати OIDC-токени від імені dispatcher_sa
# (потрібно для push-підписки dispatcher_push_sub)
resource "google_service_account_iam_member" "pubsub_agent_token_creator" {
  service_account_id = google_service_account.dispatcher_sa.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = google_project_service_identity.pubsub_agent.member
}

# ───────────────────────────────────────────────────────────
# 3. scheduler_sa
# ───────────────────────────────────────────────────────────
resource "google_project_iam_member" "scheduler_functions_invoker" {
  project = var.project_id
  role    = "roles/cloudfunctions.invoker"
  member  = "serviceAccount:${google_service_account.scheduler_sa.email}"
}

# ───────────────────────────────────────────────────────────
# 4. url_generator_sa
#    Генерує Signed URL для завантаження CSV
# ───────────────────────────────────────────────────────────

# Може писати/перевіряти наявність об'єктів в import bucket
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

# ───────────────────────────────────────────────────────────
# 5. csv_importer_sa
#    Обробляє CSV, пише в Firestore, публікує в main_topic
# ───────────────────────────────────────────────────────────

# Повний доступ до import bucket (читання, запис у quarantine/, видалення)
# roles/storage.objectAdmin включає viewer + creator + delete
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

resource "google_project_iam_member" "importer_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# Читання з Pub/Sub subscription (потрібно для Gen 1 Pub/Sub trigger)
resource "google_pubsub_subscription_iam_member" "importer_csv_subscriber" {
  subscription = google_pubsub_subscription.csv_import_processor.name
  role         = "roles/pubsub.subscriber"
  member       = "serviceAccount:${google_service_account.csv_importer_sa.email}"
}

# ───────────────────────────────────────────────────────────
# 6. Pub/Sub топіки — IAM bindings
#
#    Використовуємо iam_binding (авторитативний) для main_topic.
#    Всі publishers і viewers — тут, в одному місці.
# ───────────────────────────────────────────────────────────

# Хто може публікувати в main_topic
resource "google_pubsub_topic_iam_binding" "main_topic_publishers" {
  topic   = google_pubsub_topic.main_topic.name
  role    = "roles/pubsub.publisher"
  project = var.project_id

  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",   # apartments, bookings
    "serviceAccount:${google_service_account.pubsub_publisher_sa.email}",  # зовнішній publisher
    "serviceAccount:${google_service_account.csv_importer_sa.email}",      # CSV import
    "serviceAccount:${google_service_account.dispatcher_sa.email}",
  ]
}

resource "google_pubsub_topic_iam_binding" "main_topic_viewers" {
  topic   = google_pubsub_topic.main_topic.name
  role    = "roles/pubsub.viewer"
  project = var.project_id

  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_subscriber_sa.email}",
  ]
}

# Pub/Sub агент може публікувати в DLQ (потрібно для переміщення з основної підписки)
resource "google_pubsub_topic_iam_member" "pubsub_agent_dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.notification_dlq.name
  role    = "roles/pubsub.publisher"
  member  = google_project_service_identity.pubsub_agent.member
}

# GCS SA може публікувати в csv_imports топік (для GCS notifications)
resource "google_pubsub_topic_iam_member" "gcs_csv_imports_publisher" {
  topic  = google_pubsub_topic.csv_imports.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}

# ───────────────────────────────────────────────────────────
# 7. Pub/Sub підписки — IAM bindings
# ───────────────────────────────────────────────────────────

resource "google_pubsub_subscription_iam_binding" "main_sub_subscribers" {
  subscription = google_pubsub_subscription.main_subscription.name
  role         = "roles/pubsub.subscriber"
  project      = var.project_id

  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_subscriber_sa.email}",
  ]
}

resource "google_pubsub_subscription_iam_binding" "main_sub_viewers" {
  subscription = google_pubsub_subscription.main_subscription.name
  role         = "roles/pubsub.viewer"
  project      = var.project_id

  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_subscriber_sa.email}",
  ]
}

# Pub/Sub агент може ACK повідомлення в dispatcher підписці
# (потрібно для переміщення в DLQ)
resource "google_pubsub_subscription_iam_member" "pubsub_agent_dispatcher_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.dispatcher_push_sub.name
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub_agent.member
}