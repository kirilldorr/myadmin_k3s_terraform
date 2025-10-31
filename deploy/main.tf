terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

locals {
  aws_region        = "us-west-2"
  vpc_cidr          = "10.0.0.0/16"
  subnet_a_cidr     = "10.0.10.0/24"
  subnet_b_cidr     = "10.0.11.0/24"
  az_a              = "us-west-2a"
  az_b              = "us-west-2b"
  cluster_name      = "myapp-eks"
  node_group_name   = "myapp-nodes"
  app_name          = "myapp"
  app_container_port = 3500
  service_port       = 80
  admin_secret       = "your_secret"
  kubernetes_cluster_tag = "kubernetes.io/cluster/myapp-eks"
  kubernetes_elb_tag     = "kubernetes.io/role/elb"
  ingress_ports = [
    { from = 22, to = 22, protocol = "tcp" },
    { from = 80, to = 80, protocol = "tcp" }
  ]
  node_group_scaling = {
    desired = 1
    min     = 1
    max     = 2
  }
}

provider "aws" {
  region = local.aws_region
}

provider "kubernetes" {
  host                   = aws_eks_cluster.eks.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.eks.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.eks.token
}

data "aws_eks_cluster_auth" "eks" {
  name = aws_eks_cluster.eks.name
}

resource "aws_vpc" "main" {
  cidr_block = local.vpc_cidr
  tags       = { Name = "main-vpc" }
}

resource "aws_subnet" "public_a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnet_a_cidr
  map_public_ip_on_launch = true
  availability_zone       = local.az_a
  tags = {
    Name                              = "public-a"
    "${local.kubernetes_cluster_tag}" = "shared"
    "${local.kubernetes_elb_tag}"     = "1"
  }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.subnet_b_cidr
  map_public_ip_on_launch = true
  availability_zone       = local.az_b
  tags = {
    Name                              = "public-b"
    "${local.kubernetes_cluster_tag}" = "shared"
    "${local.kubernetes_elb_tag}"     = "1"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "main-igw" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "public-rt" }
}

resource "aws_route_table_association" "public_a_assoc" {
  subnet_id      = aws_subnet.public_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_b_assoc" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_security_group" "app_sg" {
  name   = "app-sg"
  vpc_id = aws_vpc.main.id

  dynamic "ingress" {
    for_each = local.ingress_ports
    content {
      from_port   = ingress.value.from
      to_port     = ingress.value.to
      protocol    = ingress.value.protocol
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "eks_cluster_role" {
  name = "eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster_role.name
}

resource "aws_iam_role" "eks_node_role" {
  name = "eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy_attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy_attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "ecr_read_only_attach" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_iam_role_policy_attachment" "ssm_core_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.eks_node_role.name
}

resource "aws_eks_cluster" "eks" {
  name     = local.cluster_name
  role_arn = aws_iam_role.eks_cluster_role.arn

  vpc_config {
    subnet_ids         = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    security_group_ids = [aws_security_group.app_sg.id]
  }
}

resource "aws_eks_node_group" "node_group" {
  cluster_name    = aws_eks_cluster.eks.name
  node_group_name = local.node_group_name
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.public_a.id, aws_subnet.public_b.id]

  scaling_config {
    desired_size = local.node_group_scaling.desired
    max_size     = local.node_group_scaling.max
    min_size     = local.node_group_scaling.min
  }
  instance_types = ["t3a.small"]
}

data "aws_ecr_repository" "app_repo" {
  name = "myadmin"
}

resource "kubernetes_deployment" "app" {
  depends_on = [aws_eks_node_group.node_group]

  metadata {
    name = "${local.app_name}-deployment"
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = local.app_name }
    }

    template {
      metadata {
        labels = { app = local.app_name }
      }

      spec {
        container {
          name  = local.app_name
          image = "${data.aws_ecr_repository.app_repo.repository_url}:latest"
          port {
            container_port = local.app_container_port
          }
          env {
            name  = "ADMINFORTH_SECRET"
            value = local.admin_secret
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "app_service" {
  metadata {
    name = "${local.app_name}-service"
    annotations = {
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-path"      = "/"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-port"      = "traffic-port"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-interval"  = "30"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-timeout"   = "5"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-healthy-threshold"   = "2"
      "service.beta.kubernetes.io/aws-load-balancer-healthcheck-unhealthy-threshold" = "2"
    }
  }

  spec {
    selector = { app = local.app_name }
    type     = "LoadBalancer"

    port {
      port        = local.service_port
      target_port = local.app_container_port
    }
  }
}

output "app_service_endpoint" {
  value = kubernetes_service.app_service.status[0].load_balancer[0].ingress[0].hostname
}
