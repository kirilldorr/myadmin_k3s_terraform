output "app_endpoint" {
  value = "http://${aws_instance.ec2_instance.public_dns}"
}

output "ssh_connect_command" {
  value = "ssh -i .keys/id_rsa ubuntu@${aws_instance.ec2_instance.public_dns}"
}

output "hash" {
  value = local.image_tag
}
