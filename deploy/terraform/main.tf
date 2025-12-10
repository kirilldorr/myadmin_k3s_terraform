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
  app_name             = "myadmink3s"
  app_source_code_path = "../../"
  ansible_dir          = "../ansible/playbooks"
  app_files            = fileset(local.app_source_code_path, "**")

  image_tag = sha256(join("", [
    for f in local.app_files :
    try(filesha256("${local.app_source_code_path}/${f}"), "")
    if length(regexall("^deploy/", f)) == 0
    && length(regexall("^\\.vscode/", f)) == 0
    && length(regexall("^node_modules/", f)) == 0
    && length(regexall("^\\.gitignore", f)) == 0
  ]))

  ingress_ports = [
    { from = 22, to = 22, protocol = "tcp", desc = "SSH" },
    { from = 80, to = 80, protocol = "tcp", desc = "App HTTP (Traefik)" },
    { from = 443, to = 443, protocol = "tcp", desc = "App HTTPS (Traefik)" },
    { from = 6443, to = 6443, protocol = "tcp", desc = "Kubernetes API" }
  ]
}

provider "aws" {
  region  = local.aws_region
  profile = "myaws"
}

data "aws_ami" "ubuntu_22_04" {
  most_recent = true
  owners      = ["099720109477"] # Canonical ubuntu account ID

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "app_deployer" {
  key_name   = "terraform-deploy_${local.app_name}-key"
  public_key = file("../.keys/id_rsa.pub") # Path to your public SSH key
}

resource "aws_instance" "ec2_instance" {
  instance_type = "t3a.small"
  ami           = data.aws_ami.ubuntu_22_04.id

  iam_instance_profile = aws_iam_instance_profile.instance_profile.name

  subnet_id                   = aws_subnet.public_a.id
  vpc_security_group_ids      = [aws_security_group.app_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.app_deployer.key_name

  tags = {
    Name = local.app_name
  }

  depends_on = [
    null_resource.docker_build_and_push
  ]

  # prevent accidental termination of ec2 instance and data loss
  lifecycle {
    create_before_destroy = true #uncomment in production
    #prevent_destroy       = true       #uncomment in production
    ignore_changes = [ami]
    replace_triggered_by = [
      null_resource.docker_build_and_push
    ]
  }

  root_block_device {
    volume_size = 10 // Size in GB for root partition
    volume_type = "gp2"

    # Even if the instance is terminated, the volume will not be deleted, delete it manually if needed
    delete_on_termination = true #change to false in production if data persistence is needed
  }

}


resource "local_file" "ansible_inventory" {
  content = <<EOF
[k3s_nodes]
${aws_instance.ec2_instance.public_ip} ansible_user=ubuntu ansible_ssh_private_key_file=../.keys/id_rsa
EOF

  filename = "../ansible/inventory.ini"
}

resource "null_resource" "wait_ssh" {
  depends_on = [aws_instance.ec2_instance]

  triggers = (
    {
      instance_id = aws_instance.ec2_instance.id
    }
  )

  provisioner "local-exec" {
    command = <<EOT
    bash -c '
    for i in {1..10}; do
      nc -zv ${aws_instance.ec2_instance.public_ip} 22 && echo "SSH is ready!" && exit 0
      sleep 5
    done
    exit 1
    '
    EOT
  }
}

resource "null_resource" "ansible_provision" {
  depends_on = [
    aws_instance.ec2_instance,
    local_file.ansible_inventory,
    null_resource.wait_ssh,
    local_file.image_tag
  ]

  triggers = {
    instance_id = aws_instance.ec2_instance.id
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]

    command = <<-EOT
      set -e
      ANSIBLE_HOST_KEY_CHECKING=False ansible-galaxy collection install community.kubernetes
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -i ${path.module}/../ansible/inventory.ini ${local.ansible_dir}/playbook.yaml 
    EOT
  }
}
