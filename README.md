# CloudNativePG on AKS with Premium SSD v2 (Azure Disk CSI) Lab

This lab walks through creating a 3-node HA PostgreSQL cluster on AKS using CloudNativePG (CNPG) and Azure Premium SSD v2 disks (Azure Disk CSI). It includes benchmark steps, sample data, and backup/restore using the Barman Cloud plugin.

## Prereqs

- Azure subscription + Azure CLI
- Terraform >= 1.5
- kubectl, Helm (for operator install)
- Barman Cloud plugin (CNPG-I)

## Provision AKS + Azure Container Storage

Start a new Bash-based Azure Cloud Shell.

Set relevant subscription.

```bash
az account set --subscription <your subscription>
```

Then export `ARM_SUBSCRIPTION_ID` so Terraform knows where to deploy.

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

Use the provided Terraform template:

```bash
terraform init
terraform apply
```

Terraform appends a 6-character lowercase+number suffix to the prefix for uniqueness.

After apply, fetch kubeconfig:

```bash
az aks get-credentials --resource-group demo-aks-rg-<suffix> --name demo-aks-cluster-<suffix>
```

Note: Premium SSD v2 requires zonal node pools in regions/zones that support it. This Terraform config pins the system node pool to zone 1. If your region doesn't support Premium SSD v2 (or zone 1), pick a supported region/zone before applying Terraform.

### Get Azure Blob backup details (fast, non-prod)

Terraform creates a storage account and container for backups. Export the values you need for the CNPG secret and ObjectStore destination path:

```bash
export AZ_SA=$(terraform output -raw storage_account_name)
export AZ_CONTAINER=$(terraform output -raw storage_container_name)
export AZ_KEY=$(terraform output -raw storage_account_key)
```

Single-line version:

```bash
export AZ_SA=$(terraform output -raw storage_account_name) AZ_CONTAINER=$(terraform output -raw storage_container_name) AZ_KEY=$(terraform output -raw storage_account_key)
```

These are **lab-only** exports (account keys in a Secret).

Set passwords for the app and superuser Secrets:

```bash
export APP_PASSWORD=$(openssl rand -hex 24)
export SUPERUSER_PASSWORD=$(openssl rand -hex 24)
```

## Install the CNPG operator

Option A (Helm, recommended):

```bash
helm repo add cnpg https://cloudnative-pg.github.io/charts
helm upgrade --install cnpg \
  --namespace cnpg-system \
  --create-namespace \
  cnpg/cloudnative-pg
```

Option B (kubectl + cnpg plugin to generate manifests):

```bash
kubectl cnpg install generate -n cnpg-system > cnpg-operator.yaml
kubectl apply -f cnpg-operator.yaml
```

Verify the operator is ready:

```bash
kubectl get deploy -n cnpg-system
```

## Install the Barman Cloud plugin (CNPG-I)

This lab uses the plugin-based backup/WAL archiving flow (recommended by CNPG).
Install the Barman Cloud plugin and restart the operator so it discovers the
plugin.

- Use `docs/cnpg_i.md` for CNPG-I registration details.
- Follow the Barman Cloud plugin documentation referenced in that file.

## Create namespace + secrets + sample data

Edit these values before applying:

- `01-secrets.yaml`: `REPLACE_ME_*`
- `03-objectstore.yaml`: `destinationPath` placeholders

Fast, non-prod secret + destination updates using the exports above:

```bash
sed -i "s/REPLACE_ME_APP_PASSWORD/$APP_PASSWORD/" 01-secrets.yaml
sed -i "s/REPLACE_ME_SUPERUSER_PASSWORD/$SUPERUSER_PASSWORD/" 01-secrets.yaml
sed -i "s/REPLACE_ME_STORAGE_ACCOUNT/$AZ_SA/" 01-secrets.yaml
sed -i "s/REPLACE_ME_STORAGE_KEY/$AZ_KEY/" 01-secrets.yaml
sed -i "s/REPLACE_ME_ACCOUNT/$AZ_SA/" 03-objectstore.yaml
sed -i "s/REPLACE_ME_CONTAINER/$AZ_CONTAINER/" 03-objectstore.yaml
```

One-liner equivalent (safe for values containing `/`):

```bash
sed -i "s|REPLACE_ME_APP_PASSWORD|$APP_PASSWORD|" 01-secrets.yaml && sed -i "s|REPLACE_ME_SUPERUSER_PASSWORD|$SUPERUSER_PASSWORD|" 01-secrets.yaml && sed -i "s|REPLACE_ME_STORAGE_ACCOUNT|$AZ_SA|" 01-secrets.yaml && sed -i "s|REPLACE_ME_STORAGE_KEY|$AZ_KEY|" 01-secrets.yaml && sed -i "s|REPLACE_ME_ACCOUNT|$AZ_SA|" 03-objectstore.yaml && sed -i "s|REPLACE_ME_CONTAINER|$AZ_CONTAINER|" 03-objectstore.yaml
```

Apply:

```bash
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-secrets.yaml
kubectl apply -f 02-sample-data-configmap.yaml
kubectl apply -f 03-objectstore.yaml
```

## Create the Premium SSD v2 StorageClass

The lab uses a StorageClass named `premiumv2-disk-sc` with provisioner `disk.csi.azure.com`. It sets performance to 3000 IOPS and 125 MBps.

```bash
kubectl apply -f 04-storageclass-premiumv2.yaml
kubectl get storageclass premiumv2-disk-sc
```

## Create the 3-node CNPG cluster

```bash
kubectl apply -f 05-cluster.yaml
kubectl get pods -n cnpg-lab
```

CNPG creates services for the cluster. The read/write service is named `<cluster>-rw` (here `cnpg-demo-rw`). Use it for connections.

## Check sample data

The sample tables and rows are created during bootstrap via `postInitApplicationSQLRefs`.

Run a quick query:

```bash
kubectl run psql --rm -i --attach --restart=Never --image=postgres:17 -n cnpg-lab \
  --env=PGHOST=cnpg-demo-rw.cnpg-lab.svc \
  --env=PGUSER=app \
  --env=PGPASSWORD=$(kubectl get secret app-user -n cnpg-lab -o jsonpath='{.data.password}' | base64 -d) \
  --env=PGDATABASE=app \
  -- bash -lc "psql -c \"SELECT to_regclass('public.accounts') AS accounts_table\""
```

## CNPG benchmark (pgbench)

Initialize the benchmark data:

```bash
kubectl apply -f 06-pgbench-init-job.yaml
kubectl logs -n cnpg-lab job/pgbench-init
```

Run the benchmark:

```bash
kubectl apply -f 07-pgbench-run-job.yaml
kubectl logs -n cnpg-lab job/pgbench-run
```

## Backup with Barman Cloud plugin (Azure Blob)

Trigger an on-demand backup:

```bash
kubectl apply -f 08-backup.yaml
kubectl get backups -n cnpg-lab
```

Create a scheduled backup (daily at 02:00:00):

```bash
kubectl apply -f 09-scheduled-backup.yaml
```

Note: CNPG scheduled backups use a 6-field cron format (includes seconds).

## Recover from backup (Barman Cloud plugin)

Restore into a **new** cluster (CNPG does not do in-place restores). The
recovery bootstrap uses the object store and restores the latest available
backup/WALs.

```bash
kubectl apply -f 10-restore-cluster.yaml
kubectl get pods -n cnpg-lab
```

Verify data is present in the restored cluster:

```bash
kubectl run psql --rm -i --attach --restart=Never --image=postgres:17 -n cnpg-lab \
  --env=PGHOST=cnpg-restore-rw.cnpg-lab.svc \
  --env=PGUSER=app \
  --env=PGPASSWORD=$(kubectl get secret app-user -n cnpg-lab -o jsonpath='{.data.password}' | base64 -d) \
  --env=PGDATABASE=app \
  -- bash -lc "psql -c \"SELECT to_regclass('public.accounts') AS accounts_table\""
```

Important: the restore cluster uses a **different** `serverName` in the plugin
configuration so its WAL/backup stream doesn't overwrite the original cluster.

## Tear down / cleanup

Delete CNPG clusters and jobs:

```bash
kubectl delete -f 10-restore-cluster.yaml --ignore-not-found
kubectl delete -f 05-cluster.yaml --ignore-not-found
kubectl delete -f 06-pgbench-init-job.yaml --ignore-not-found
kubectl delete -f 07-pgbench-run-job.yaml --ignore-not-found
kubectl delete -f 08-backup.yaml --ignore-not-found
kubectl delete -f 09-scheduled-backup.yaml --ignore-not-found
kubectl delete -f 03-objectstore.yaml --ignore-not-found
```

Delete PVCs (if any remain):

```bash
kubectl delete pvc -n cnpg-lab -l cnpg.io/cluster=cnpg-demo --ignore-not-found
kubectl delete pvc -n cnpg-lab -l cnpg.io/cluster=cnpg-restore --ignore-not-found
```

Delete the namespace (cleans remaining resources):

```bash
kubectl delete namespace cnpg-lab --ignore-not-found
```

Optionally delete the StorageClass if you created it manually:

```bash
kubectl delete -f 04-storageclass-premiumv2.yaml --ignore-not-found
```

Tear down AKS and Azure resources:

```bash
terraform destroy
```

If cleanup hangs, check for stuck PVCs or Pods and delete them before re-running `terraform destroy`.
