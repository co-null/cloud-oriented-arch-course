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