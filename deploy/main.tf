terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  aws_region           = "us-west-2"
  vpc_cidr             = "10.0.0.0/16"
  subnet_a_cidr        = "10.0.10.0/24"
  subnet_b_cidr        = "10.0.11.0/24"
  az_a                 = "us-west-2a"
  az_b                 = "us-west-2b"
  cluster_name         = "myapp-k3s"
  app_name             = "myapp"
  app_source_code_path = "../"

  app_container_port = 3500
  service_port       = 80
  admin_secret       = "your_secret"

  ingress_ports = [
    { from = 22, to = 22, protocol = "tcp", desc = "SSH" },
    { from = 80, to = 80, protocol = "tcp", desc = "App HTTP (Traefik)" },
    { from = 443, to = 443, protocol = "tcp", desc = "App HTTPS (Traefik)" },
    { from = 6443, to = 6443, protocol = "tcp", desc = "Kubernetes API" }
  ]
}

provider "aws" {
  region = local.aws_region
}

data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical ubuntu account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "k3s_server" {
  instance_type = "t3a.small"
  ami           = data.aws_ami.ubuntu_22_04.id

  iam_instance_profile = aws_iam_instance_profile.k3s_instance_profile.name

  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true
  key_name                    = "k3s-keys"

  tags = {
    Name = local.cluster_name
  }

  depends_on = [
    null_resource.docker_build_and_push
  ]

  user_data = templatefile("./user_data.sh.tpl", {
    app_name           = local.app_name
    aws_region         = local.aws_region
    admin_secret       = local.admin_secret
    app_container_port = local.app_container_port
    service_port       = local.service_port
    ecr_registry_id    = aws_ecr_repository.app_repo.registry_id
    ecr_image_full     = "${aws_ecr_repository.app_repo.repository_url}:latest"

  })

  # prevent accidental termination of ec2 instance and data loss
  # if you will need to recreate the instance still (not sure why it can be?), you will need to remove this block manually by next command:
  # > terraform taint aws_instance.app_instance
  lifecycle {
    create_before_destroy = true
    #prevent_destroy       = true
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = 8 // Size in GB for root partition
    volume_type = "gp2"

    # Even if the instance is terminated, the volume will not be deleted, delete it manually if needed
    delete_on_termination = false
  }
}
