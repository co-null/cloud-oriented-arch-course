resource "google_monitoring_notification_channel" "team_email" {
  display_name = "Team Email Alerts"
  type         = "email"
  labels       = { email_address = var.alert_email }
}