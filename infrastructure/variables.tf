variable "bucket_name" {
  description = "Ім'я bucket для статичного контенту"
  type        = string
}

variable "project_id" {
  description = "Ім'я проєкту"
  type        = string
}

variable "region" {
  description = "Регіон, де створювати ресурси"
  type        = string
}

variable "mailgun_domain" {
  description = "Домен для відправки email"
  type        = string
}

variable "topic_name" {
  description = "Топік для подій додавання квартир і бронювань"
  type        = string
}

variable "admin_email" {
  description = "Email адміністратора для системних сповіщень"
  type        = string
}

variable "alert_email" {
  description = "Email для отримання алертів команди"
  type        = string
}
