# Використання провайдера Google Cloud
provider "google" {
  project = var.project_id
  region  = var.region
}

# Тут буде блок для використовуваних сервісів
resource "google_project_service" "firestore_api" {
  project = var.project_id
  service = "firestore.googleapis.com"
  
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "pubsub_api" {
  project = var.project_id
  service = "pubsub.googleapis.com"
  
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "cloudfunctions_api" {
  project = var.project_id
  service = "cloudfunctions.googleapis.com"
  
  disable_dependent_services = false
  disable_on_destroy         = false
}

resource "google_project_service" "iam_api" {
  project = var.project_id
  service = "iam.googleapis.com"
  
  disable_dependent_services = false
  disable_on_destroy         = false
}

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
    google_service_account.pubsub_function_sa,
    google_pubsub_topic.main_topic,
    google_project_service.firestore_api,
    google_project_service.cloudfunctions_api
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

# Додання брокера Pub-Sub
# Основний топік для повідомлень
resource "google_pubsub_topic" "main_topic" {
  name    = var.topic_name
  project = var.project_id
  
  # Налаштування retention
  message_retention_duration = "604800s" # 7 днів
  
  depends_on = [google_project_service.pubsub_api]
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

# Вивід URL для bucket
output "static_site_url" {
  description = "URL для доступу до статичного сайту"
  value       = "http://${google_storage_bucket.static_site.name}.storage.googleapis.com/index.html"
}
