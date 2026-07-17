# ═══════════════════════════════════════════════════════════
# PUB/SUB ТОПІКИ ТА ПІДПИСКИ
#
# IAM права — в iam.tf
# ═══════════════════════════════════════════════════════════

# ─── Основний event bus ────────────────────────────────────

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

# Підписка для читання подій (pull, для messages функції)
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

# Push-підписка для dispatcher (HTTP push з OIDC)
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

# ─── CSV Import pipeline ───────────────────────────────────

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

  depends_on = [
    google_pubsub_topic.csv_imports,
    google_pubsub_topic.csv_imports_dlq,
  ]
}
  