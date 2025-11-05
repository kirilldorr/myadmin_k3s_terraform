output "app_endpoint" {
  value = "http://${aws_instance.k3s_server.public_dns}"
}

output "kubectl_config_command" {
  value = "scp -i .keys/k3s-keys.pem ubuntu@${aws_instance.k3s_server.public_dns}:/home/ubuntu/k3s.yaml ~/.kube/config-k3s && export KUBECONFIG=~/.kube/config-k3s"
}

output "ssh_connect_command" {
  value = "ssh -i .keys/k3s-keys.pem ubuntu@${aws_instance.k3s_server.public_dns}"
}
