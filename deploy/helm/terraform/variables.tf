variable "admin_secret" {
  description = "Admin secret for the application"
  type        = string
}

variable "cluster_name" {
  description = "The name of the cluster"
  type        = string
}

variable "app_name" {
  type    = string
  default = "myapp"
}
