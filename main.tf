terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.10.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.0.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = <your-subscription-id>
}

# Provider for Kubernetes with aks credentials
provider "kubernetes" {
  host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
  client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
  client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
  cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)

}

provider "helm" {
  kubernetes {
    host                   = azurerm_kubernetes_cluster.aks.kube_config.0.host
    client_certificate     = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_certificate)
    client_key             = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.client_key)
    cluster_ca_certificate = base64decode(azurerm_kubernetes_cluster.aks.kube_config.0.cluster_ca_certificate)
  }
}

# Variables
variable "location" {
  default = "East US"
}

variable "resource_group" {
  default = "my-resource-group"
}

# Resource Group
resource "azurerm_resource_group" "resource_group" {
  name     = var.resource_group
  location = var.location
}

# Event Hub Namespace
resource "azurerm_eventhub_namespace" "namespace" {
  name                = "my-eventhub-namespace-random9494838823418"
  location            = azurerm_resource_group.resource_group.location
  resource_group_name = azurerm_resource_group.resource_group.name
  sku                 = "Standard"
  capacity            = 1

  depends_on = [ 
    azurerm_resource_group.resource_group
  ]
}

# Event Hub Namespace Authorization Rule
resource "azurerm_eventhub_namespace_authorization_rule" "my_custom_auth_rule" {
  name                = "MyCustomAuthRule"
  namespace_name      = azurerm_eventhub_namespace.namespace.name
  resource_group_name = azurerm_resource_group.resource_group.name
  listen              = true
  send                = true
  manage              = true

  depends_on = [ 
    azurerm_eventhub_namespace.namespace
  ]
}

# Event Hub
resource "azurerm_eventhub" "eventhub" {
  name                = "my-eventhub"
  namespace_name      = azurerm_eventhub_namespace.namespace.name
  resource_group_name = azurerm_resource_group.resource_group.name
  partition_count     = 2
  message_retention   = 1

  depends_on = [ 
    azurerm_eventhub_namespace.namespace
  ]  
}

resource "azurerm_eventhub_consumer_group" "consumer_group" {
  name                = "my-consumer-group"
  namespace_name      = azurerm_eventhub_namespace.namespace.name
  eventhub_name       = azurerm_eventhub.eventhub.name
  resource_group_name = azurerm_resource_group.resource_group.name
  depends_on = [ 
    azurerm_eventhub_namespace.namespace
  ]    
}

# AKS Cluster
resource "azurerm_kubernetes_cluster" "aks" {
  name                = "myAKSCluster"
  location            = azurerm_resource_group.resource_group.location
  resource_group_name = azurerm_resource_group.resource_group.name
  dns_prefix          = "myaksrandom54554858548854"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "standard_b2pls_v2"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin = "azure"
  }
}

# Kubernetes Namespace
resource "kubernetes_namespace" "kafka_app" {
  metadata {
    name = "kafka-app"
  }

  depends_on = [
    azurerm_kubernetes_cluster.aks
  ]
}

# Kubernetes Secrets
resource "kubernetes_secret" "eventhub_secrets" {
  metadata {
    name      = "eventhub-secrets"
    namespace = kubernetes_namespace.kafka_app.metadata[0].name
  }

  data = {
    EVENT_HUB_CONNECTION_STRING = base64encode(azurerm_eventhub_namespace_authorization_rule.my_custom_auth_rule.primary_connection_string)
    EVENT_HUB_NAME              = base64encode(azurerm_eventhub.eventhub.name)
    CONSUMER_GROUP              = base64encode(azurerm_eventhub_consumer_group.consumer_group.name)
  }
  depends_on = [
    azurerm_eventhub_namespace_authorization_rule.my_custom_auth_rule,
    azurerm_eventhub.eventhub,
    azurerm_eventhub_consumer_group.consumer_group
  ]
}

# Kubernetes Service for kafka-consumer
resource "kubernetes_service" "kafka_consumer_service" {
  metadata {
    name      = "kafka-consumer-service"
    namespace = kubernetes_namespace.kafka_app.metadata[0].name
  }

  spec {
    selector = {
      app = "kafka_consumer"
    }

    port {
      port        = 80
      target_port = 8080
    }

    type = "ClusterIP"
  }
}

# Kubernetes Service for kafka-producer
resource "kubernetes_service" "kafka_producer_service" {
  metadata {
    name      = "kafka-producer-service"
    namespace = kubernetes_namespace.kafka_app.metadata[0].name
    labels = {
      app = "kafka_producer"
    }
  }

  spec {
    type = "ClusterIP"  # Change the service type to LoadBalancer

    selector = {
      app = "kafka_producer"
    }

    port {
      port        = 80
      target_port = 8080
    }
  }
  depends_on = [
    kubernetes_deployment.kafka_producer_deployment
  ]
}

resource "helm_release" "nginx_ingress" {
  name       = "nginx-ingress"
  namespace  = kubernetes_namespace.kafka_app.metadata[0].name
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = "4.11.3"

  set {
    name  = "controller.service.type"
    value = "LoadBalancer"
  }
}

# Kubernetes Ingress
resource "kubernetes_ingress_v1" "ingress_nginx" {
  metadata {
    name      = "nginx-ingress"
    namespace = kubernetes_namespace.kafka_app.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/rewrite-target" = "/$1"
    }
  }

  spec {
    ingress_class_name = "nginx"  # Specify the Ingress class name here

    rule {
      http {
        path {
          path = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.kafka_producer_service.metadata[0].name
              port {
                number = kubernetes_service.kafka_producer_service.spec[0].port[0].port
              }
            }
          }
        }
        path {
          path = "/consumer(/|$)(.*)"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.kafka_consumer_service.metadata[0].name
              port {
                number = kubernetes_service.kafka_consumer_service.spec[0].port[0].port
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_service.kafka_producer_service,
    kubernetes_service.kafka_consumer_service
  ]
}


resource "kubernetes_deployment" "kafka_producer_deployment" {
  metadata {
    name      = "kafka-producer-deployment"
    namespace = kubernetes_namespace.kafka_app.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "kafka_producer"
      }
    }

    template {
      metadata {
        labels = {
          app = "kafka_producer"
        }
      }

      spec {
        container {
          image = "nikose/demoazurehubwithpython:producer.1.3"
          name  = "kafka-producer-container"
          port {
            container_port = 8080
          }
          env {
            name = "EVENT_HUB_CONNECTION_STRING"
            value_from {
              secret_key_ref {
                name = "eventhub-secrets"
                key  = "EVENT_HUB_CONNECTION_STRING"
              }
            }
          }
          env {
            name = "EVENT_HUB_NAME"
            value_from {
              secret_key_ref {
                name = "eventhub-secrets"
                key  = "EVENT_HUB_NAME"
              }
            }
          }
        }
      }
    }
  }
  depends_on = [
    kubernetes_secret.eventhub_secrets
  ]
}

resource "kubernetes_deployment" "kafka_consumer_deployment" {
  metadata {
    name      = "kafka-consumer-deployment"
    namespace = kubernetes_namespace.kafka_app.metadata[0].name
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "kafka_consumer"
      }
    }

    template {
      metadata {
        labels = {
          app = "kafka_consumer"
        }
      }

      spec {
        container {
          image = "nikose/demoazurehubwithpython:consumer.2.1"
          name  = "kafka-consumer-container"
          port {
            container_port = 8080
          }
          env {
            name = "EVENT_HUB_CONNECTION_STRING"
            value_from {
              secret_key_ref {
                name = "eventhub-secrets"
                key  = "EVENT_HUB_CONNECTION_STRING"
              }
            }
          }
          env {
            name = "EVENT_HUB_NAME"
            value_from {
              secret_key_ref {
                name = "eventhub-secrets"
                key  = "EVENT_HUB_NAME"
              }
            }
          }
          env {
            name = "CONSUMER_GROUP"
            value_from {
              secret_key_ref {
                name = "eventhub-secrets"
                key  = "CONSUMER_GROUP"
              }
            }
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_secret.eventhub_secrets
  ]
}