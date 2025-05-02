# Azure Container Storage for PostgreSQL

This project sets up a PostgreSQL cluster on Azure Kubernetes Service (AKS) using the [CloudNativePG](https://cloudnative-pg.io/) operator. It's designed to get you ready for benchmarking with `pgbench`.

- 💻 Runs out of the box in [Azure Cloud Shell](https://shell.azure.com/) – no local setup required (but I personally run this on WSL anyways)
- 📚 Based on official [PostgreSQL on AKS documentation](https://aka.ms/pgsql) – built with best practices in mind
- 🛠️ Powered by [CloudNativePG](https://cloudnative-pg.io/) – for high availability and simplified maintenance
- ⚙️ Uses 16-core Azure VMs by default – ensuring strong performance for realistic testing
- ☁️ Automated backups to Azure Blob Storage via Barman – for safe, periodic database backups

## Azure Container Storage (Local NVMe Drives)

Creates a PostgreSQL cluster using [Azure Container Storage](https://aka.ms/acstor) on high-speed [local NVMe drives](https://learn.microsoft.com/en-us/azure/storage/container-storage/use-container-storage-with-local-disk#what-is-ephemeral-disk).

```bash
bash -c "$(curl -fsSL <https://raw.githubusercontent.com/eh8/acstor-pgsql/main/acstor.sh>)"
```

## Azure Disks CSI Driver (Premium SSDs)

Creates a PostgreSQL cluster using the [Azure Disks CSI driver](https://learn.microsoft.com/en-us/azure/aks/azure-disk-csi) with Premium SSD storage.

```bash
bash -c "$(curl -fsSL <https://raw.githubusercontent.com/eh8/acstor-pgsql/main/csi.sh>)"
```
