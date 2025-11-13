terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0, < 3.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0.0"
    }
  }
}

provider "kubernetes" {
  config_path = "../../k3s.yaml"
}

provider "helm" {
  kubernetes = {
    config_path = "../../k3s.yaml"
  }
}

data "local_file" "config_file" {
  filename = "../../terraform_outputs.json"
}

locals {
  config = jsondecode(data.local_file.config_file.content)
}

resource "kubernetes_namespace" "myappk3s" {
  metadata {
    name = "myappk3s"

    labels = {
      "app.kubernetes.io/managed-by" = "Helm"
    }

    annotations = {
      "meta.helm.sh/release-name"      = "myapp"
      "meta.helm.sh/release-namespace" = "myappk3s"
    }
  }
}

resource "helm_release" "myapp" {
  name             = "myapp"
  chart            = "../helm_charts"
  namespace        = kubernetes_namespace.myappk3s.metadata.0.name
  create_namespace = false

  set = [
    {
      name  = "ecrImageFull"
      value = local.config.ecr_repository_url.value
    },
    {
      name  = "image.tag"
      value = "latest"
    },
    {
      name  = "adminSecret"
      value = var.admin_secret
    },
    {
      name  = "ingress.enabled"
      value = "true"
    },
    {
      name  = "ingress.hosts[0].host"
      value = "${local.config.instance_public_ip.value}.nip.io"
    },
    {
      name  = "ingress.hosts[0].paths[0].path"
      value = "/"
    },
    {
      name  = "ingress.hosts[0].paths[0].pathType"
      value = "Prefix"
    },
    {
      name  = "appName"
      value = var.cluster_name
    }
  ]
  depends_on = [kubernetes_namespace.myappk3s]
}
