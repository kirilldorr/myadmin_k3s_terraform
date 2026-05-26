output "app_endpoint" {
  value = "http://${aws_instance.ec2_instance.public_dns}"
}

output "ssh_connect_command" {
  value = "ssh -i .keys/id_rsa ubuntu@${aws_instance.ec2_instance.public_dns}"
}

output "hash" {
  value = local.image_tag
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app_repo.repository_url
}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  value = local.aws_region
}

output "public_ip" {
  value = aws_instance.ec2_instance.public_ip
}
