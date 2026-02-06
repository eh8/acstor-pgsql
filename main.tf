terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
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

variable "storage_account_name" {
  description = "Globally-unique storage account name (3-24 lowercase letters/numbers)."
  type        = string
  default     = "acstorcnpgdemo001a3f9c7d"
}

variable "storage_container_name" {
  description = "Blob container name for CNPG backups."
  type        = string
  default     = "cnpg-backups"
}

resource "azurerm_resource_group" "rg" {
  name     = "demo-aks-rg-001"
  location = "eastus"
}

resource "azurerm_storage_account" "backups" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "backups" {
  name                  = var.storage_container_name
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
}

resource "azurerm_kubernetes_cluster" "aks" {
  name                = "demo-aks-cluster-001"
  dns_prefix          = "demo-aks"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name

  default_node_pool {
    name       = "systempool"
    vm_size    = "Standard_D4s_v5"
    node_count = 3
  }

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_kubernetes_cluster_extension" "container_storage" {
  # NOTE: the `name` parameter must be "acstor" for Azure CLI compatibility
  name           = "acstor"
  cluster_id     = azurerm_kubernetes_cluster.aks.id
  extension_type = "microsoft.azurecontainerstoragev2"
}

output "storage_account_name" {
  value = azurerm_storage_account.backups.name
}

output "storage_container_name" {
  value = azurerm_storage_container.backups.name
}

output "storage_account_key" {
  value     = azurerm_storage_account.backups.primary_access_key
  sensitive = true
}
