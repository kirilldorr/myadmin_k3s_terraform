resource "aws_ecr_repository" "app_repo" {
  name = local.app_name

  image_tag_mutability = "MUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
  force_delete = true
}

data "aws_caller_identity" "current" {}

resource "null_resource" "docker_build_and_push" {
  depends_on = [aws_ecr_repository.app_repo]

  triggers = {
    image_tag = local.image_tag
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      unset DOCKER_HOST

      REPO_URL="${aws_ecr_repository.app_repo.repository_url}"
      ACCOUNT_ID="${data.aws_caller_identity.current.account_id}"
      REGION="${local.aws_region}"
      TAG="${local.image_tag}"

      echo "LOG: Logging in to ECR..."
      aws ecr get-login-password --region $${REGION} | docker login --username AWS --password-stdin $${ACCOUNT_ID}.dkr.ecr.$${REGION}.amazonaws.com
      
      echo "LOG: Building Docker image..."
      docker build --pull -t $${REPO_URL}:$${TAG} ${local.app_source_code_path}

      echo "LOG: Pushing image to ECR..."
      docker push $${REPO_URL}:$${TAG}

      echo "LOG: Build and push complete. TAG=$${TAG}"
    EOT

    interpreter = ["/bin/bash", "-c"]
  }
}

resource "local_file" "image_tag" {
  depends_on = [null_resource.docker_build_and_push]
  content    = local.image_tag
  filename   = "${path.module}/image_tag.txt"
}

