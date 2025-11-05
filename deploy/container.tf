resource "aws_ecr_repository" "app_repo" {
  name = "myadmin"

  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = true
}

data "aws_caller_identity" "current" {}

resource "null_resource" "docker_build_and_push" {

  depends_on = [aws_ecr_repository.app_repo]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      unset DOCKER_HOST
      
      REPO_URL="${aws_ecr_repository.app_repo.repository_url}"
      ACCOUNT_ID="${data.aws_caller_identity.current.account_id}"
      REGION="${local.aws_region}"
      
      echo "LOG: Logging in to ECR..."
      aws ecr get-login-password --region $${REGION} | docker login --username AWS --password-stdin $${ACCOUNT_ID}.dkr.ecr.$${REGION}.amazonaws.com
      
      echo "LOG: Building Docker image..."
      docker -H unix:///var/run/docker.sock build --pull -t $${REPO_URL}:latest ${local.app_source_code_path}

      echo "LOG: Pushing image to ECR..."
      docker -H unix:///var/run/docker.sock push $${REPO_URL}:latest

      echo "LOG: Build and push complete."
    EOT

    interpreter = ["/bin/bash", "-c"]
  }
}


