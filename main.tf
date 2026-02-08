terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
}

resource "azurerm_resource_group" "rg" {
  name     = "demo-aks-rg-${random_string.storage_account_suffix.result}"
  location = "eastus2"
}

resource "random_string" "storage_account_suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

locals {
  name_suffix = random_string.storage_account_suffix.result
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "demo-aks-cluster-${local.name_suffix}"
  dns_prefix          = "demo-aks-${local.name_suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  default_node_pool {
    name       = "systempool"
    vm_size    = "Standard_D4s_v5"
    node_count = 3
    zones      = ["1"]
  }

  identity {
    type = "SystemAssigned"
  }
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}
