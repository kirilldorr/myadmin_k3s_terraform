data "local_file" "json_file" {
  filename = "../../terraform_outputs.json"
}

locals {
  duplicated_json = jsondecode(data.local_file.json_file.content)
}

output "ssh_connect_command" {
  value = local.duplicated_json["ssh_connect_command"]["value"]
}

output "kubectl_config_command" {
  value = local.duplicated_json["kubectl_config_command"]["value"]
}

output "app_endpoint" {
  value = local.duplicated_json["app_endpoint"]["value"]
}
