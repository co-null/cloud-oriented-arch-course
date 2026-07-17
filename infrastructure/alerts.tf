# МОНІТОРИНГ ТА АЛЕРТИ


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
    # Автоматично закриває інцидент якщо метрика зникла (наприклад, DLQ спорожнів)
    # і нових повідомлень не надходить протягом 24 годин
    auto_close = "86400s"

    # Повторне сповіщення кожні 4 години поки інцидент залишається відкритим
    notification_channel_strategy {
      notification_channel_names = [google_monitoring_notification_channel.team_email.name]
      renotify_interval          = "14400s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Повідомлення не вдалося обробити після 5 спроб. Перевірте логи pubsub-dispatcher та стан email-sender функції."
    mime_type = "text/markdown"
  }
}

resource "google_monitoring_alert_policy" "dispatcher_errors" {
  display_name = "⚠️ pubsub_dispatcher: помилки виконання"
  combiner     = "OR"

  conditions {
    display_name = "Function execution errors"
    condition_threshold {
      filter          = "resource.type=\"cloud_function\" AND resource.labels.function_name=\"pubsub_dispatcher\" AND metric.type=\"cloudfunctions.googleapis.com/function/execution_count\" AND metric.labels.status=\"error\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "300s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_RATE"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"

    notification_channel_strategy {
      notification_channel_names = [google_monitoring_notification_channel.team_email.name]
      renotify_interval          = "3600s"  # Нагадування щогодини
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]
}


# ──────────────────────────────────────────────────────────────────────────────
# РОЗШИРЕНИЙ МОНІТОРИНГ
# Використовує team_email notification channel з main.tf
# ──────────────────────────────────────────────────────────────────────────────

# Алерт: зростаючий backlog у dispatcher підписці
resource "google_monitoring_alert_policy" "dispatcher_backlog_high" {
  display_name = "⚠️ Dispatcher: backlog повідомлень > 50"
  combiner     = "OR"

  conditions {
    display_name = "High undelivered message count in dispatcher subscription"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"pubsub_subscription\"",
        "resource.labels.subscription_id=\"dispatcher-push-sub\"",
        "metric.type=\"pubsub.googleapis.com/subscription/num_undelivered_messages\""
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 50
      duration        = "300s"  # 5 хвилин

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  alert_strategy {
    auto_close = "86400s"
    notification_channel_strategy {
      notification_channel_names = [google_monitoring_notification_channel.team_email.name]
      renotify_interval          = "3600s"
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Dispatcher не встигає обробляти повідомлення. Перевірте логи pubsub_dispatcher та send_email. Можливі причини: rate limit Mailgun, помилки Firestore, велике навантаження."
    mime_type = "text/markdown"
  }
}

# Алерт: старе повідомлення у dispatcher черзі
resource "google_monitoring_alert_policy" "dispatcher_message_too_old" {
  display_name = "🕐 Dispatcher: повідомлення очікує > 10 хвилин"
  combiner     = "OR"

  conditions {
    display_name = "Oldest unacked message age > 10 minutes"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"pubsub_subscription\"",
        "resource.labels.subscription_id=\"dispatcher-push-sub\"",
        "metric.type=\"pubsub.googleapis.com/subscription/oldest_unacked_message_age\""
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 600   # 10 хвилин у секундах
      duration        = "120s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Є повідомлення у черзі dispatcher'а що чекає обробки більше 10 хвилин. Це може означати 'зависле' бронювання. Перевірте Firestore колекцію bookings на записи зі статусом 'processing'."
    mime_type = "text/markdown"
  }
}

# Алерт: помилки у watchdog функції
resource "google_monitoring_alert_policy" "watchdog_execution_errors" {
  display_name = "🔧 Watchdog: помилки виконання"
  combiner     = "OR"

  conditions {
    display_name = "Any watchdog execution error"
    condition_threshold {
      filter = join(" AND ", [
        "resource.type=\"cloud_function\"",
        "resource.labels.function_name=\"watchdog\"",
        "metric.type=\"cloudfunctions.googleapis.com/function/execution_count\"",
        "metric.labels.status=\"error\""
      ])
      comparison      = "COMPARISON_GT"
      threshold_value = 0   # будь-яка помилка watchdog — вже інцидент
      duration        = "60s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]

  documentation {
    content   = "Watchdog функція впала. Перевірте логи: gcloud functions logs read watchdog --limit=50"
    mime_type = "text/markdown"
  }
}

# Алерт: висока latency dispatcher або send_email
resource "google_monitoring_alert_policy" "critical_functions_high_latency" {
  display_name = "⏱ Критичні функції: p99 latency > 10 секунд"
  combiner     = "OR"

  dynamic "conditions" {
    for_each = toset(["pubsub_dispatcher", "send_email"])
    content {
      display_name = "p99 latency > 10s for ${conditions.key}"
      condition_threshold {
        filter = join(" AND ", [
          "resource.type=\"cloud_function\"",
          "resource.labels.function_name=\"${conditions.key}\"",
          "metric.type=\"cloudfunctions.googleapis.com/function/execution_times\""
        ])
        comparison      = "COMPARISON_GT"
        threshold_value = 10000000000  # 10 секунд у наносекундах
        duration        = "300s"

        aggregations {
          alignment_period     = "60s"
          per_series_aligner   = "ALIGN_PERCENTILE_99"
          cross_series_reducer = "REDUCE_MEAN"
          group_by_fields      = ["resource.labels.function_name"]
        }
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.team_email.name]
}

