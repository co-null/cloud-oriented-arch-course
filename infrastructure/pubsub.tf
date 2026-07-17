# Додання брокера Pub-Sub
# Основний топік для повідомлень
resource "google_pubsub_topic" "main_topic" {
  name    = var.topic_name
  project = var.project_id
  
  # Налаштування retention
  message_retention_duration = "604800s" # 7 днів
  
  depends_on = [google_project_service.apis]
}

# DLQ топік
resource "google_pubsub_topic" "notification_dlq" {
  name                       = "notification-dlq"
  project                    = var.project_id

  # Налаштування retention
  message_retention_duration = "604800s"

  depends_on                 = [google_project_service.apis]
}

# Pub/Sub сервісний агент повинен мати право публікувати в DLQ
resource "google_pubsub_topic_iam_member" "pubsub_dlq_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.notification_dlq.name
  role    = "roles/pubsub.publisher"
  member  = google_project_service_identity.pubsub_agent.member
}

# Pub/Sub service agent може ACK повідомлення в основній підписці
# (потрібно для переміщення в DLQ)
resource "google_pubsub_subscription_iam_member" "pubsub_agent_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.dispatcher_push_sub.name
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub_agent.member
}

# Основна підписка
resource "google_pubsub_subscription" "main_subscription" {
  name    = "${var.topic_name}-subscription"
  topic   = google_pubsub_topic.main_topic.name
  project = var.project_id
  
  # Налаштування acknowledgment
  ack_deadline_seconds = 60
  
  # Налаштування retention
  message_retention_duration = "604800s" # 7 днів
  retain_acked_messages      = false
  
  # Налаштування retry policy
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }
    
  # Налаштування expiration
  expiration_policy {
    ttl = "2678400s" # 31 день
  }
  
  depends_on = [
    google_pubsub_topic.main_topic,
  ]
}

# Підписка для диспетчера
resource "google_pubsub_subscription" "dispatcher_push_sub" {
  name    = "dispatcher-push-sub"
  topic   = google_pubsub_topic.main_topic.name
  project = var.project_id

  ack_deadline_seconds = 60

  # Push до HTTP-функції з OIDC-аутентифікацією
  push_config {
    push_endpoint = google_cloudfunctions_function.pubsub_dispatcher.https_trigger_url

    oidc_token {
      service_account_email = google_service_account.dispatcher_sa.email
      audience              = google_cloudfunctions_function.pubsub_dispatcher.https_trigger_url
    }
  }

  # DLQ після 5 невдалих спроб
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.notification_dlq.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  message_retention_duration = "604800s"
  retain_acked_messages      = false

  expiration_policy {
    ttl = "2678400s"
  }

  # IAM на DLQ та права агента мають бути готові до створення підписки
  depends_on = [
    google_pubsub_topic_iam_member.pubsub_dlq_publisher,
    google_service_account_iam_member.pubsub_agent_token_creator,
    google_cloudfunctions_function.pubsub_dispatcher,
    google_pubsub_topic.main_topic
  ]
}


# IAM bindings для топіків
resource "google_pubsub_topic_iam_binding" "publisher_binding" {
  topic   = google_pubsub_topic.main_topic.name
  role    = "roles/pubsub.publisher"
  project = var.project_id
  
  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_publisher_sa.email}"
  ]
}

resource "google_pubsub_topic_iam_binding" "viewer_binding" {
  topic   = google_pubsub_topic.main_topic.name
  role    = "roles/pubsub.viewer"
  project = var.project_id
  
  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_subscriber_sa.email}"
  ]
}

# IAM bindings для підписок
resource "google_pubsub_subscription_iam_binding" "subscriber_binding" {
  subscription = google_pubsub_subscription.main_subscription.name
  role         = "roles/pubsub.subscriber"
  project      = var.project_id
  
  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_subscriber_sa.email}"
  ]
}

resource "google_pubsub_subscription_iam_binding" "viewer_subscription_binding" {
  subscription = google_pubsub_subscription.main_subscription.name
  role         = "roles/pubsub.viewer"
  project      = var.project_id
  
  members = [
    "serviceAccount:${google_service_account.pubsub_function_sa.email}",
    "serviceAccount:${google_service_account.pubsub_subscriber_sa.email}"
  ]
}

# ═══════════════════════════════════════════════════════════
# Pub/Sub для GCS Notifications
# ═══════════════════════════════════════════════════════════

# Топік для подій завантаження CSV
resource "google_pubsub_topic" "csv_imports" {
  name = "apartments-csv-imports"

  # Зберігаємо повідомлення 7 днів
  # (для DLQ і потенційного replay)
  message_retention_duration = "604800s"

  depends_on = [google_project_service.apis]
}

# Dead Letter Topic для невдалих імпортів
resource "google_pubsub_topic" "csv_imports_dlq" {
  name                       = "apartments-csv-imports-dlq"
  message_retention_duration = "604800s"
}

# Subscription для Cloud Function
resource "google_pubsub_subscription" "csv_import_processor" {
  name  = "apartments-csv-import-processor-sub"
  topic = google_pubsub_topic.csv_imports.name

  # 5 хвилин на обробку одного CSV
  ack_deadline_seconds = 300

  # Exponential backoff: починаємо з 30s, максимум 10 хвилин
  retry_policy {
    minimum_backoff = "30s"
    maximum_backoff = "600s"
  }

  # Dead Letter Queue після 5 спроб
  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.csv_imports_dlq.id
    max_delivery_attempts = 5
  }
  
# ═══════════════════════════════════════════════════════════
# GCS Notification → Pub/Sub
# ═══════════════════════════════════════════════════════════

# GCS Service Account потребує дозволу публікувати в наш топік
data "google_storage_project_service_account" "gcs_sa" {
  depends_on = [google_project_service.required_apis]
}

resource "google_pubsub_topic_iam_member" "gcs_can_publish" {
  topic  = google_pubsub_topic.csv_imports.name
  role   = "roles/pubsub.publisher"
  member = "serviceAccount:${data.google_storage_project_service_account.gcs_sa.email_address}"
}

# Налаштовуємо notification: тільки OBJECT_FINALIZE, тільки папка imports/
resource "google_storage_notification" "csv_import_notification" {
  bucket         = google_storage_bucket.apartments_imports.name
  payload_format = "JSON_API_V1"
  topic          = google_pubsub_topic.csv_imports.id
  event_types    = ["OBJECT_FINALIZE"]
  # Фільтруємо: тільки файли в imports/, не в quarantine/
  object_name_prefix = "imports/"

  depends_on = [google_pubsub_topic_iam_member.gcs_can_publish]
}