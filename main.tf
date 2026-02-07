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

variable "storage_account_name_prefix" {
  description = "Storage account name prefix (lowercase letters/numbers). A 6-char random suffix is appended."
  type        = string
  default     = "cnpgdemo001"
}

variable "storage_container_name" {
  description = "Blob container name for CNPG backups."
  type        = string
  default     = "cnpg-backups"
}

resource "azurerm_resource_group" "rg" {
  name     = "demo-aks-rg-${random_string.storage_account_suffix.result}"
  location = "eastus"
}

resource "random_string" "storage_account_suffix" {
  length  = 6
  upper   = false
  special = false
  numeric = true
}

locals {
  storage_account_name = "${var.storage_account_name_prefix}${random_string.storage_account_suffix.result}"
  name_suffix          = random_string.storage_account_suffix.result
}

resource "azurerm_storage_account" "backups" {
  name                     = local.storage_account_name
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

output "storage_account_name" {
  value = azurerm_storage_account.backups.name
}

output "resource_group_name" {
  value = azurerm_resource_group.rg.name
}

output "aks_cluster_name" {
  value = azurerm_kubernetes_cluster.aks.name
}

output "storage_container_name" {
  value = azurerm_storage_container.backups.name
}

output "storage_account_key" {
  value     = azurerm_storage_account.backups.primary_access_key
  sensitive = true
}
