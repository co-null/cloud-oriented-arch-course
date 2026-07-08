# Використання провайдера Google Cloud
provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# 
# АКТИВАЦІЯ GCP API
#
# GCP за замовчуванням вимикає більшість API у новому проєкті.
# Terraform активує їх автоматично перед деплоєм ресурсів.
#
# disable_on_destroy = false означає, що при знищенні інфраструктури
# через `terraform destroy` API залишаться увімкненими. Це безпечніше,
# ніж їх вимикати — інші ресурси в проєкті можуть від них залежати.
# 
resource "google_project_service" "apis" {
  for_each = toset([
# Cloud Functions Gen 1 — основний сервіс деплою функцій
    "cloudfunctions.googleapis.com",

    # Pub/Sub — черга подій; топік apartment-events вже існує з попередньої теми
    "pubsub.googleapis.com",

    # IAM - сервіс ролей доступу
    "iam.googleapis.com",

    # Secret Manager — захищене зберігання MAILGUN_API_KEY та MAILGUN_DOMAIN
    "secretmanager.googleapis.com",

    # Cloud Build — збірка та деплой коду функцій з GCS
    "cloudbuild.googleapis.com",

    # Firestore — idempotency store для захисту від дублювання листів
    "firestore.googleapis.com",

    # Cloud Monitoring — метрики та алерти
    "monitoring.googleapis.com",

    # Cloud Logging — структуроване логування функцій
    "logging.googleapis.com"
  ])

  service            = each.key
  disable_on_destroy = false
}

resource "google_project_service_identity" "pubsub_agent" {
  provider = google-beta
  project  = var.project_id
  service  = "pubsub.googleapis.com"

  # Pub/Sub API має бути активований до провізіонування агента
  depends_on = [google_project_service.apis]
}


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
resource "google_project_iam_member" "function_sa_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# Права на створення підписок
resource "google_project_iam_member" "function_sa_subscription_admin" {
  project = var.project_id
  role    = "roles/pubsub.admin"
  member  = "serviceAccount:${google_service_account.pubsub_function_sa.email}"
}

# IAM права  для Dispatcher
# dispatcher: запис логів
resource "google_project_iam_member" "dispatcher_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# dispatcher: запис метрик
resource "google_project_iam_member" "dispatcher_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}

# dispatcher: Firestore для idempotency store
resource "google_project_iam_member" "dispatcher_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.dispatcher_sa.email}"
}


# Створення Google Cloud Storage bucket для статичного сайту
resource "google_storage_bucket" "static_site" {
  name     = var.bucket_name
  location = var.region

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  force_destroy = true # Дозволяє видаляти bucket разом із файлами
}

# Відкриємо сторінку для всіх
resource "google_storage_bucket_iam_member" "public_rule" {
  bucket = google_storage_bucket.static_site.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# Завантаження (копіювання/оновлення) статичних файлів із локальної директорії у bucket
resource "google_storage_bucket_object" "static_files" {
  # Для кожного файлу у директорії ./src/static створюється об'єкт у bucket
  for_each = fileset("${path.module}/../src/static", "**/*.*")

  name   = each.key
  bucket = google_storage_bucket.static_site.name
  source = "${path.module}/../src/static/${each.key}"

  content_type = (
    can(regex("\\.css$", each.key)) ? "text/css" :
    can(regex("\\.js$", each.key)) ? "application/javascript" :
    can(regex("\\.html?$", each.key)) ? "text/html" :
    can(regex("\\.png$", each.key)) ? "image/png" :
    can(regex("\\.jpe?g$", each.key)) ? "image/jpeg" :
    can(regex("\\.svg$", each.key)) ? "image/svg+xml" :
    null
  )
}

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
  name       = "notification-dlq"
  depends_on = [google_project_service.apis]
  message_retention_duration = "604800s"  # 7 днів
}

# Pub/Sub сервісний агент повинен мати право публікувати в DLQ
# ВАЖЛИВО: цей ресурс має існувати ДО створення підписки з DLQ-політикою
resource "google_pubsub_topic_iam_member" "pubsub_dlq_publisher" {
  topic  = google_pubsub_topic.notification_dlq.name
  role   = "roles/pubsub.publisher"
  member = google_project_service_identity.pubsub_agent.member
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

# DLQ ПІДПИСКА
# Окрема підписка з dead_letter_policy на основному топіку. 
# Gen 1 тригер dispatcher використовує власну автоматичну підписку,
# а ця підписка — виключно для DLQ-маршрутизації.

resource "google_pubsub_subscription" "dispatcher_sub_dlq" {
  name  = "dispatcher-sub-with-dlq"
  topic = google_pubsub_topic.main_topic.name

  ack_deadline_seconds = 30

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.notification_dlq.id
    max_delivery_attempts = 5
  }

  # ВАЖЛИВО: IAM на DLQ топік має існувати ДО створення підписки
  depends_on = [google_pubsub_topic_iam_member.pubsub_dlq_publisher]
}

resource "google_pubsub_subscription_iam_member" "pubsub_acks_main_sub" {
  subscription = google_pubsub_subscription.dispatcher_sub_dlq.name
  role         = "roles/pubsub.subscriber"
  member       = google_project_service_identity.pubsub_agent.member
}

# Створення Google Cloud Storage bucket для функцій (ім'я буде відповідати [ІД вашого проєкту]-function-bucket)
resource "google_storage_bucket" "function_bucket" {
  name     = "${var.project_id}-function-bucket"
  location = var.region
  force_destroy = true 
}

# Email функція
# Завантаження (копіювання/оновлення) функції (як архіву) для email з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "email_function_zip" {
  name   = "send-email.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/send-email/send-email.zip"
}

# Передаємо секрет в Cloud Function
resource "google_cloudfunctions_function" "send_email" {
  name = "send_email"
  runtime = "python310"
  entry_point = "send_email"
  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.email_function_zip.name
  trigger_http = true
  available_memory_mb = 128

  secret_environment_variables {
    key    = "MAILGUN_API_KEY"
    project_id = var.project_id
    secret = "MAILGUN_API_KEY"
    version = "latest"
  }
  environment_variables = {
    MAILGUN_DOMAIN = var.mailgun_domain
  }
}

# IAM-політики для Cloud Function
resource "google_secret_manager_secret_iam_member" "send_email_function_access" {
  secret_id = "projects/${var.project_id}/secrets/MAILGUN_API_KEY"
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_cloudfunctions_function.send_email.service_account_email}"
}

resource "google_cloudfunctions_function_iam_member" "send_email_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.send_email.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}

# Check-token функція
# Завантаження (копіювання/оновлення) функції (як архіву) для Check-token з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "check_token_function_zip" {
  name   = "check-token.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/check-token/check-token.zip"
}

resource "google_cloudfunctions_function" "protected_api" {
  name        = "protected-api"
  description = "Protected endpoint with Firebase token check"
  runtime     = "python310"
  entry_point = "protected"
  trigger_http = true
  available_memory_mb = 128

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.check_token_function_zip.name

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "protected_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.protected_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}

# Додати/отримати квартири
# Завантаження (копіювання/оновлення) функції (як архіву) для apartments з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "apartments_function_zip" {
  name   = "apartments.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/apartments/apartments.zip"
}

resource "google_cloudfunctions_function" "apartments_api" {
  name        = "apartments"
  description = "Endpoint for apartments"
  runtime     = "python310"
  entry_point = "main"
  trigger_http = true
  available_memory_mb = 256

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.apartments_function_zip.name

  service_account_email = google_service_account.pubsub_function_sa.email

  environment_variables = {
    GCP_PROJECT = var.project_id
    PUBSUB_TOPIC = google_pubsub_topic.main_topic.name
  }

  depends_on = [
    google_service_account.pubsub_function_sa,
    google_pubsub_topic.main_topic
  ]

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "apartments_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.apartments_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}

# Бронювання
# Завантаження (копіювання/оновлення) функції (як архіву) для apartments з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "bookings_function_zip" {
  name   = "bookings.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/bookings/bookings.zip"
}

resource "google_cloudfunctions_function" "bookings_api" {
  name        = "bookings"
  description = "Endpoint for bookings"
  runtime     = "python310"
  entry_point = "main"
  trigger_http = true
  available_memory_mb = 256
  timeout = 60

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.bookings_function_zip.name

  service_account_email = google_service_account.pubsub_function_sa.email

  environment_variables = {
    GCP_PROJECT = var.project_id
    PUBSUB_TOPIC = google_pubsub_topic.main_topic.name
  }

  depends_on = [
    google_project_service.apis,
    google_service_account.pubsub_function_sa,
    google_pubsub_topic.main_topic
  ]

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "bookings_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.bookings_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
}

# Події з топіку
# Завантаження останніх подій з топіку
resource "google_storage_bucket_object" "messages_function_zip" {
  name   = "messages.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/messages/messages.zip"
}

resource "google_cloudfunctions_function" "messages_api" {
  name        = "messages"
  description = "Endpoint for messages"
  runtime     = "python310"
  entry_point = "main"
  trigger_http = true
  available_memory_mb = 256

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.messages_function_zip.name

  service_account_email = google_service_account.pubsub_function_sa.email

  environment_variables = {
    GCP_PROJECT = var.project_id
    PUBSUB_TOPIC = google_pubsub_topic.main_topic.name
    PUBSUB_SUBSCRIPTION = google_pubsub_subscription.main_subscription.name
  }

  depends_on = [
    google_service_account.pubsub_function_sa,
    google_pubsub_topic.main_topic,
    google_pubsub_subscription.main_subscription
  ]

  ingress_settings = "ALLOW_ALL"
  https_trigger_security_level = "SECURE_ALWAYS"
}

resource "google_cloudfunctions_function_iam_member" "messages_api_invoker" {
  project        = var.project_id
  region         = var.region
  cloud_function = google_cloudfunctions_function.messages_api.name
  role           = "roles/cloudfunctions.invoker"
  member         = "allUsers"
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
  description = "Підписується на booking-events та викликає send_email по REST"
  runtime     = "python310"
  entry_point = "main"
  trigger_http = true
  available_memory_mb = 256
  timeout = 60

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.bookings_function_zip.name
  service_account_email = google_service_account.dispatcher_sa.email

  # Gen 1 нативний Pub/Sub тригер
  event_trigger {
    event_type = "google.pubsub.topic.publish"   # Gen 1 синтаксис
    resource   = google_pubsub_topic.main_topic.id

    failure_policy {
      retry = true  # При RuntimeError — Pub/Sub автоматично повторить доставку
    }
  }

  environment_variables = {
    GCP_PROJECT      = var.project_id
    EMAIL_SENDER_URL = google_cloudfunctions_function.send_email.https_trigger_url
    ADMIN_EMAIL      = var.admin_email
    PUBSUB_TOPIC = google_pubsub_topic.main_topic.name
  }

  depends_on = [
    google_project_service.apis,
    google_cloudfunctions_function.send_email,
    google_project_iam_member.dispatcher_firestore,
    google_pubsub_topic.main_topic
  ]
}

# dlq-handler
# Завантаження (копіювання/оновлення) функції (як архіву) для dlq-handler з локальної директорії у bucket для функції
resource "google_storage_bucket_object" "dlq_handler_function_zip" {
  name   = "dlq_handler.zip"
  bucket = google_storage_bucket.function_bucket.name
  source = "${path.module}/../src/cloud-functions/dlq_handler/dlq_handler.zip"
}

resource "google_cloudfunctions_function" "dlq_handler" {
  name        = "dlq_handler"
  description = "Логує повідомлення з Dead Letter Queue та відправляє алерти"
  runtime     = "python310"
  entry_point = "main"
  available_memory_mb = 128
  timeout = 60

  source_archive_bucket = google_storage_bucket.function_bucket.name
  source_archive_object = google_storage_bucket_object.dlq_handler_function_zip.name
  service_account_email = google_service_account.dispatcher_sa.email

  # Gen 1 нативний Pub/Sub тригер
  event_trigger {
    event_type = "google.pubsub.topic.publish"
    resource   = google_pubsub_topic.notification_dlq.id

    failure_policy {
      retry = false  # DLQ не ретраїмо — лише логуємо
    }
  }

  environment_variables = {
    GCP_PROJECT      = var.project_id
  }

  depends_on = [
    google_project_service.apis,
    google_pubsub_topic.notification_dlq
  ]
}

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

# МОНІТОРИНГ ТА АЛЕРТИ
resource "google_monitoring_notification_channel" "team_email" {
  display_name = "Team Email Alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

resource "google_monitoring_alert_policy" "dlq_non_empty" {
  display_name = "🚨 Notification DLQ: є необроблені повідомлення"
  combiner     = "OR"

  conditions {
    display_name = "DLQ received messages"
    condition_threshold {
      filter          = "resource.type=\"pubsub_topic\" AND resource.labels.topic_id=\"notification-dlq\" AND metric.type=\"pubsub.googleapis.com/topic/send_message_operation_count\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "60s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  alert_strategy {
    notification_rate_limit { period = "3600s" }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Повідомлення не вдалося обробити після 5 спроб. Перевірте логи pubsub-dispatcher та стан email-sender функції."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "dispatcher_errors" {
  display_name = "⚠️ pubsub-dispatcher: помилки виконання"
  combiner     = "OR"

  conditions {
    display_name = "Function execution errors"
    condition_threshold {
      # У Gen 1 метрика помилок — через Cloud Functions, не Cloud Run
      filter          = "resource.type=\"cloud_function\" AND resource.labels.function_name=\"pubsub-dispatcher\" AND metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" AND metric.labels.status=\"error\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]
}

# Вивід URL для bucket
output "static_site_url" {
  description = "URL для доступу до статичного сайту"
  value       = "http://${google_storage_bucket.static_site.name}.storage.googleapis.com/index.html"
}
