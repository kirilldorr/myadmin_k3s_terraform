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
  config_path = "../../k3s.yaml" # Шлях до kubeconfig у папці deploy/
}

provider "helm" {
  kubernetes = {
    config_path = "../../k3s.yaml" # Шлях до kubeconfig у папці deploy/
  }
}

data "local_file" "config_file" {
  filename = "../../terraform_outputs.json" # Шлях до файлу на одну папку вище
}

locals {
  config = jsondecode(data.local_file.config_file.content)
}

# Цей ресурс, як і раніше, залежить від отримання kubeconfig
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
  chart            = "../helm_charts" # Шлях до чартів у папці deploy/helm/
  namespace        = kubernetes_namespace.myappk3s.metadata.0.name
  create_namespace = false

  set = [
    {
      name  = "ecrImageFull"
      value = local.config.ecr_repository_url.value # Використовуємо пряме посилання
    },
    {
      name  = "image.tag"
      value = "latest" # Це було жорстко прописано, так і залишаємо
    },
    {
      name  = "adminSecret"
      value = var.admin_secret # <-- ЗМІНА
    },
    {
      name  = "ingress.enabled"
      value = "true"
    },
    {
      name  = "ingress.hosts[0].host"
      value = "${local.config.instance_public_ip.value}.nip.io" # Використовуємо пряме посилання
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
      value = var.cluster_name # <-- ЗМІНА (або var.app_name, залежно від вашої логіки)
    }
  ]
  depends_on = [kubernetes_namespace.myappk3s]
}
