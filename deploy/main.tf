
locals {
  app_name = "testtf"
  aws_region = "us-west-2"
}

provider "aws" {
  region = local.aws_region
  profile = "myaws"
}

data "aws_ami" "ubuntu_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

data "aws_vpc" "default" {
  default = true
}

resource "aws_eip" "eip" {
 domain = "vpc"
}

resource "aws_eip_association" "eip_assoc" {
 instance_id   = aws_instance.app_instance.id
 allocation_id = aws_eip.eip.id
}

data "aws_subnet" "default_subnet" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone"
    values = ["${local.aws_region}a"]
  }
}

resource "aws_security_group" "instance_sg" {
  name   = "${local.app_name}-instance-sg"
  vpc_id = data.aws_vpc.default.id

  ingress {
    description = "Allow HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow Docker registry"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH
  ingress {
    description = "Allow SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_key_pair" "app_deployer" {
  key_name   = "terraform-deploy_${local.app_name}-key"
  public_key = file("./.keys/id_rsa.pub") # Path to your public SSH key
}

resource "aws_instance" "app_instance" {
  ami                    = data.aws_ami.ubuntu_linux.id
  instance_type          = "t3a.small"  # just change it to another type if you need, check https://instances.vantage.sh/
  subnet_id              = data.aws_subnet.default_subnet.id
  vpc_security_group_ids = [aws_security_group.instance_sg.id]
  key_name               = aws_key_pair.app_deployer.key_name
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  # prevent accidental termination of ec2 instance and data loss
  # if you will need to recreate the instance still (not sure why it can be?), you will need to remove this block manually by next command:
  # > terraform taint aws_instance.app_instance
  lifecycle {
    prevent_destroy = true
    ignore_changes = [ami]
  }

  root_block_device {
    volume_size = 20 // Size in GB for root partition
    volume_type = "gp2"
    
    # Even if the instance is terminated, the volume will not be deleted, delete it manually if needed
    delete_on_termination = false
  }

  user_data = <<-EOF
    #!/bin/bash
    sudo apt-get update
    sudo apt-get install ca-certificates curl python3 python3-pip -y
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc

    # Add the repository to Apt sources:
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt-get update

    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin screen

    systemctl start docker
    systemctl enable docker
    usermod -a -G docker ubuntu

    sudo snap install aws-cli --classic

    echo "done" > /home/ubuntu/user_data_done

  EOF

  tags = {
    Name = "${local.app_name}-instance"
  }
}

resource "null_resource" "wait_for_user_data" {
  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for EC2 software install to finish...'",
      "while [ ! -f /home/ubuntu/user_data_done ]; do echo '...'; sleep 2; done",
      "echo 'EC2 software install finished.'"
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("./.keys/id_rsa")
      host        = aws_eip_association.eip_assoc.public_ip
    }
  }

  depends_on = [aws_instance.app_instance]
}

resource "aws_ecr_repository" "myadmin_repo" {
  name = "${local.app_name}-myadmin"
  force_delete = true
}

resource "aws_ecr_lifecycle_policy" "safe_cleanup" {
  repository = aws_ecr_repository.myadmin_repo.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Delete untagged images older than 7 days"
        selection = {
          tagStatus     = "untagged"
          countType     = "sinceImagePushed"
          countUnit     = "days"
          countNumber   = 7
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

resource "local_file" "compose_env" {
  content  = "MYADMIN_REPO=${aws_ecr_repository.myadmin_repo.repository_url}"
  filename = "${path.module}/.env.ecr"
}

// allow ec2 instance to login to ECR too pull images
resource "aws_iam_role" "ec2_role" {
  name = "${local.app_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ec2.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecr_access" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${local.app_name}-instance-profile"
  role = aws_iam_role.ec2_role.name
}

resource "null_resource" "sync_files_and_run" {

  provisioner "local-exec" {
    command = <<-EOF
      aws ecr get-login-password --region ${local.aws_region} --profile myaws | docker login --username AWS --password-stdin ${aws_ecr_repository.myadmin_repo.repository_url}

      echo "Running build"
      env $(cat .env.ecr | grep -v "#" | xargs) docker buildx bake --progress=plain --push --allow=fs.read=.. -f compose.yml

      # if you will change host, pleasee add -o StrictHostKeyChecking=no
      echo "Copy files to the instance" 
      rsync -t -avz --mkpath -e "ssh -i ./.keys/id_rsa -o StrictHostKeyChecking=no" \
        --delete \
        --exclude '.terraform' \
        --exclude '.keys' \
        --exclude 'tfplan' \
        . ubuntu@${aws_eip_association.eip_assoc.public_ip}:/home/ubuntu/app/deploy/

      EOF
  }

  # Run docker compose after files have been copied
  provisioner "remote-exec" {
    inline = [<<-EOF
      aws ecr get-login-password --region ${local.aws_region} | docker login --username AWS --password-stdin ${aws_ecr_repository.myadmin_repo.repository_url}

      cd /home/ubuntu/app/deploy

      echo "Spinning up the app"
      docker compose --progress=plain -p app  --env-file .env.ecr -f compose.yml up -d --remove-orphans

      # cleanup unused cache (run in background to not block terraform)
      screen -dm docker system prune -f
    EOF
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = file("./.keys/id_rsa")
      host        = aws_eip_association.eip_assoc.public_ip
    }


  }

  # Ensure the resource is triggered every time based on timestamp or file hash
  triggers = {
    always_run = timestamp()
  }

  depends_on = [aws_eip_association.eip_assoc, null_resource.wait_for_user_data]
}


output "instance_public_ip" {
  value = aws_eip_association.eip_assoc.public_ip
}


######### META, tf state ##############


# S3 bucket for storing Terraform state
resource "aws_s3_bucket" "terraform_state" {
  bucket = "${local.app_name}-terraform-state"
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.bucket

  rule {
    status = "Enabled"
    id = "Keep only the latest version of the state file"

    filter {
      prefix = ""
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.bucket

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.bucket

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "AES256"
    }
  }
}

# Configure the backend to use the S3 bucket
terraform {
 backend "s3" {
   bucket         = "testtf-terraform-state"
   key            = "state.tfstate"  # Define a specific path for the state file
   region         = "us-west-2"
   profile        = "myaws"
   use_lockfile   = true
 }
}

