#!/usr/bin/env bash

# To run from Cloud Shell: bash -c "$(curl -fsSL https://raw.githubusercontent.com/eh8/acstor-pgsql/main/csi.sh)"

set -euo pipefail

# Function to print messages in color
print_message() {
    local color_code="$1"
    local message="$2"
    echo -e "\e[${color_code}m${message}\e[0m"
}

# Function to print centered text
print_centered() {
    local term_width=$(tput cols)
    local padding=$(printf '%*s' "$(((term_width - ${#1}) / 2))")
    echo "${padding// / }$1"
}

# Greeting banner
print_centered "    ___                      "
print_centered "   /   |____  __  __________ "
print_centered "  / /| /_  / / / / / ___/ _ \\"
print_centered " / ___ |/ /_/ /_/ / /  /  __/"
print_centered "/_/  |_/___/\\__,_/_/   \\___/ "
echo ""
print_centered "Preparing for PostgreSQL deployment and benchmark"
echo ""
print_centered "You will be using the Azure Disks CSI driver and Premium SSD disks"
echo ""
print_centered "Time is $(date)"

# Set subscription
print_message "34" "Set subscription..."

az account set --subscription "XStore Container Storage" 

# Set environment variables
print_message "34" "Set environment variables..."

export SUFFIX=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-z0-9' | fold -w 8 | head -n 1)
export LOCAL_NAME="cnpg"
export TAGS="owner=user"
export RESOURCE_GROUP_NAME="rg-${LOCAL_NAME}-${SUFFIX}"
export PRIMARY_CLUSTER_REGION="eastus2"
export AKS_PRIMARY_CLUSTER_NAME="aks-primary-${LOCAL_NAME}-${SUFFIX}"
export AKS_PRIMARY_MANAGED_RG_NAME="rg-${LOCAL_NAME}-primary-aksmanaged-${SUFFIX}"
export AKS_PRIMARY_CLUSTER_FED_CREDENTIAL_NAME="pg-primary-fedcred1-${LOCAL_NAME}-${SUFFIX}"
export AKS_PRIMARY_CLUSTER_PG_DNSPREFIX=$(echo $(echo "a$(openssl rand -hex 5 | cut -c1-11)"))
export AKS_UAMI_CLUSTER_IDENTITY_NAME="mi-aks-${LOCAL_NAME}-${SUFFIX}"
export AKS_CLUSTER_VERSION="1.32"
export PG_NAMESPACE="cnpg-database"
export PG_SYSTEM_NAMESPACE="cnpg-system"
export PG_PRIMARY_CLUSTER_NAME="pg-primary-${LOCAL_NAME}-${SUFFIX}"
export PG_PRIMARY_STORAGE_ACCOUNT_NAME="hacnpgpsa${SUFFIX}"
export PG_STORAGE_BACKUP_CONTAINER_NAME="backups"
export ENABLE_AZURE_PVC_UPDATES="true"
export MY_PUBLIC_CLIENT_IP=$(dig +short myip.opendns.com @resolver3.opendns.com)

if [[ -n "${AZUREPS_HOST_ENVIRONMENT-}" ]]; then
  # Install required extensions
  print_message "34" "Install required extensions..."

  az extension add --upgrade --name aks-preview --yes --allow-preview true
  az extension add --upgrade --name k8s-extension --yes --allow-preview false
  az extension add --upgrade --name amg --yes --allow-preview false

  (
    set -x; cd "$(mktemp -d)" &&
    OS="$(uname | tr '[:upper:]' '[:lower:]')" &&
    ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/\(arm\)\(64\)\?.*/\1\2/' -e 's/aarch64$/arm64/')" &&
    KREW="krew-${OS}_${ARCH}" &&
    curl -fsSLO "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" &&
    tar zxvf "${KREW}.tar.gz" &&
    ./"${KREW}" install krew
  )

  export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"

  kubectl krew install cnpg
  
  # Install k9s
  print_message "34" "Install k9s..."
  curl -sS https://webi.sh/k9s | sh; \
  source ~/.config/envman/PATH.env
fi

# Create a resource group
print_message "34" "Create a resource group..."

az group create \
    --name $RESOURCE_GROUP_NAME \
    --location $PRIMARY_CLUSTER_REGION \
    --tags $TAGS \
    --query 'properties.provisioningState' \
    --output tsv

# Create a user-assigned managed identity
print_message "34" "Create a user-assigned managed identity..."

AKS_UAMI_WI_IDENTITY=$(az identity create \
    --name $AKS_UAMI_CLUSTER_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --location $PRIMARY_CLUSTER_REGION \
    --output json)

export AKS_UAMI_WORKLOAD_OBJECTID=$( \
    echo "${AKS_UAMI_WI_IDENTITY}" | jq -r '.principalId')
export AKS_UAMI_WORKLOAD_RESOURCEID=$( \
    echo "${AKS_UAMI_WI_IDENTITY}" | jq -r '.id')
export AKS_UAMI_WORKLOAD_CLIENTID=$( \
    echo "${AKS_UAMI_WI_IDENTITY}" | jq -r '.clientId')

echo "ObjectId: $AKS_UAMI_WORKLOAD_OBJECTID"
echo "ResourceId: $AKS_UAMI_WORKLOAD_RESOURCEID"
echo "ClientId: $AKS_UAMI_WORKLOAD_CLIENTID"

# Create a storage account in the primary region
print_message "34" "Create a storage account in the primary region..."

az storage account create \
    --name $PG_PRIMARY_STORAGE_ACCOUNT_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --location $PRIMARY_CLUSTER_REGION \
    --sku Standard_ZRS \
    --kind StorageV2 \
    --query 'provisioningState' \
    --output tsv

az storage container create \
    --name $PG_STORAGE_BACKUP_CONTAINER_NAME \
    --account-name $PG_PRIMARY_STORAGE_ACCOUNT_NAME \
    --auth-mode login

# Assign RBAC to storage accounts
print_message "34" "Assign RBAC to storage accounts..."

export STORAGE_ACCOUNT_PRIMARY_RESOURCE_ID=$(az storage account show \
    --name $PG_PRIMARY_STORAGE_ACCOUNT_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --query "id" \
    --output tsv)

echo $STORAGE_ACCOUNT_PRIMARY_RESOURCE_ID

az role assignment create \
    --role "Storage Blob Data Contributor" \
    --assignee-object-id $AKS_UAMI_WORKLOAD_OBJECTID \
    --assignee-principal-type ServicePrincipal \
    --scope $STORAGE_ACCOUNT_PRIMARY_RESOURCE_ID \
    --query "id" \
    --output tsv

# Create the AKS cluster to host the PostgreSQL cluster
print_message "34" "Create the AKS cluster to host the PostgreSQL cluster..."

export SYSTEM_NODE_POOL_VMSKU="standard_d16ds_v5"
export USER_NODE_POOL_NAME="postgres"
export USER_NODE_POOL_VMSKU="standard_d16ds_v5"

az aks create \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --tags $TAGS \
    --resource-group $RESOURCE_GROUP_NAME \
    --location $PRIMARY_CLUSTER_REGION \
    --generate-ssh-keys \
    --node-resource-group $AKS_PRIMARY_MANAGED_RG_NAME \
    --enable-managed-identity \
    --assign-identity $AKS_UAMI_WORKLOAD_RESOURCEID \
    --network-plugin azure \
    --network-plugin-mode overlay \
    --network-dataplane cilium \
    --nodepool-name systempool \
    --enable-oidc-issuer \
    --enable-workload-identity \
    --enable-cluster-autoscaler \
    --min-count 2 \
    --max-count 3 \
    --node-vm-size $SYSTEM_NODE_POOL_VMSKU \
    --tier standard \
    --kubernetes-version $AKS_CLUSTER_VERSION \
    --zones 1 2 3 \
    --output table
    # --api-server-authorized-ip-ranges $MY_PUBLIC_CLIENT_IP \
    # --enable-azure-monitor-metrics \
    # --azure-monitor-workspace-resource-id $AMW_RESOURCE_ID \
    # --grafana-resource-id $GRAFANA_RESOURCE_ID \

# Add a user node pool to the AKS cluster using the az aks nodepool add command.
print_message "34" "Add a user node pool to the AKS cluster using the az aks nodepool add command..."

az aks nodepool add \
    --resource-group $RESOURCE_GROUP_NAME \
    --cluster-name $AKS_PRIMARY_CLUSTER_NAME \
    --name $USER_NODE_POOL_NAME \
    --enable-cluster-autoscaler \
    --min-count 3 \
    --max-count 6 \
    --node-vm-size $USER_NODE_POOL_VMSKU \
    --zones 1 2 3 \
    --labels workload=postgres \
    --output table

# Connect to the AKS cluster and create namespaces
print_message "34" "Connect to the AKS cluster and create namespaces..."

az aks get-credentials \
    --resource-group $RESOURCE_GROUP_NAME \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --output none

kubectl create namespace $PG_NAMESPACE --context $AKS_PRIMARY_CLUSTER_NAME
kubectl create namespace $PG_SYSTEM_NAMESPACE --context $AKS_PRIMARY_CLUSTER_NAME

# Create a custom storage class with bursting disabled
print_message "34" "Create a custom storage class with bursting disabled..."

cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: workload-sc
parameters:
  cachingmode: None
  maxShares: "2"
  skuName: Premium_ZRS
provisioner: disk.csi.azure.com
reclaimPolicy: Delete
volumeBindingMode: Immediate
allowVolumeExpansion: true
EOF

export POSTGRES_STORAGE_CLASS="workload-sc"

# Create a public static IP for PostgreSQL cluster ingress
print_message "34" "Create a public static IP for PostgreSQL cluster ingress..."

export AKS_PRIMARY_CLUSTER_NODERG_NAME=$(az aks show \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --query nodeResourceGroup \
    --output tsv)

echo $AKS_PRIMARY_CLUSTER_NODERG_NAME

export AKS_PRIMARY_CLUSTER_PUBLICIP_NAME="$AKS_PRIMARY_CLUSTER_NAME-pip"

az network public-ip create \
    --resource-group $AKS_PRIMARY_CLUSTER_NODERG_NAME \
    --name $AKS_PRIMARY_CLUSTER_PUBLICIP_NAME \
    --location $PRIMARY_CLUSTER_REGION \
    --sku Standard \
    --zone 1 2 3 \
    --allocation-method static \
    --output table

export AKS_PRIMARY_CLUSTER_PUBLICIP_ADDRESS=$(az network public-ip show \
    --resource-group $AKS_PRIMARY_CLUSTER_NODERG_NAME \
    --name $AKS_PRIMARY_CLUSTER_PUBLICIP_NAME \
    --query ipAddress \
    --output tsv)

echo $AKS_PRIMARY_CLUSTER_PUBLICIP_ADDRESS

export AKS_PRIMARY_CLUSTER_NODERG_NAME_SCOPE=$(az group show --name \
    $AKS_PRIMARY_CLUSTER_NODERG_NAME \
    --query id \
    --output tsv)

echo $AKS_PRIMARY_CLUSTER_NODERG_NAME_SCOPE

az role assignment create \
    --assignee-object-id ${AKS_UAMI_WORKLOAD_OBJECTID} \
    --assignee-principal-type ServicePrincipal \
    --role "Network Contributor" \
    --scope ${AKS_PRIMARY_CLUSTER_NODERG_NAME_SCOPE}

# Install the CNPG operator in the AKS cluster

print_message "34" "Install the CNPG operator in the AKS cluster..."
helm repo add cnpg https://cloudnative-pg.github.io/charts

helm upgrade --install cnpg \
    --namespace $PG_SYSTEM_NAMESPACE \
    --create-namespace \
    --kube-context=$AKS_PRIMARY_CLUSTER_NAME \
    cnpg/cloudnative-pg

kubectl get deployment \
    --context $AKS_PRIMARY_CLUSTER_NAME \
    --namespace $PG_SYSTEM_NAMESPACE cnpg-cloudnative-pg

# Create secret for bootstrap app user
print_message "34" "Create secret for bootstrap app user..."

PG_DATABASE_APPUSER_SECRET=$(echo -n | openssl rand -base64 16)

kubectl create secret generic db-user-pass \
    --from-literal=username=app \
    --from-literal=password="${PG_DATABASE_APPUSER_SECRET}" \
    --namespace $PG_NAMESPACE \
    --context $AKS_PRIMARY_CLUSTER_NAME

kubectl get secret db-user-pass --namespace $PG_NAMESPACE --context $AKS_PRIMARY_CLUSTER_NAME

# Set environment variables for the PostgreSQL cluster
print_message "34" "Set environment variables for the PostgreSQL cluster..."

cat <<EOF | kubectl apply --context $AKS_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE -f -
apiVersion: v1
kind: ConfigMap
metadata:
    name: cnpg-controller-manager-config
data:
    ENABLE_AZURE_PVC_UPDATES: 'true'
EOF

# Create a federated credential
print_message "34" "Create a federated credential..."

export AKS_PRIMARY_CLUSTER_OIDC_ISSUER="$(az aks show \
    --name $AKS_PRIMARY_CLUSTER_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --query "oidcIssuerProfile.issuerUrl" \
    --output tsv)"

az identity federated-credential create \
    --name $AKS_PRIMARY_CLUSTER_FED_CREDENTIAL_NAME \
    --identity-name $AKS_UAMI_CLUSTER_IDENTITY_NAME \
    --resource-group $RESOURCE_GROUP_NAME \
    --issuer "${AKS_PRIMARY_CLUSTER_OIDC_ISSUER}" \
    --subject system:serviceaccount:"${PG_NAMESPACE}":"${PG_PRIMARY_CLUSTER_NAME}" \
    --audience api://AzureADTokenExchange

# Deploying PostgreSQL
print_message "34" "Deploying PostgreSQL..."

cat <<EOF | kubectl apply --context $AKS_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE -v 9 -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $PG_PRIMARY_CLUSTER_NAME
spec:
  inheritedMetadata:
    annotations:
      service.beta.kubernetes.io/azure-dns-label-name: $AKS_PRIMARY_CLUSTER_PG_DNSPREFIX
    labels:
      azure.workload.identity/use: "true"

  instances: 3
  startDelay: 30
  stopDelay: 30
  minSyncReplicas: 1
  maxSyncReplicas: 1
  replicationSlots:
    highAvailability:
      enabled: true
    updateInterval: 30

  topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        cnpg.io/cluster: $PG_PRIMARY_CLUSTER_NAME

  affinity:
    nodeSelector:
      workload: postgres

  resources:
    requests:
      memory: '8Gi'
      cpu: 2
    limits:
      memory: '8Gi'
      cpu: 2

  bootstrap:
    initdb:
      database: appdb
      owner: app
      secret:
        name: db-user-pass
      dataChecksums: true

  storage:
    size: 32Gi
    pvcTemplate:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 32Gi
      storageClassName: $POSTGRES_STORAGE_CLASS

  walStorage:
    size: 32Gi
    pvcTemplate:
      accessModes:
        - ReadWriteOnce
      resources:
        requests:
          storage: 32Gi
      storageClassName: $POSTGRES_STORAGE_CLASS

  monitoring:
    enablePodMonitor: true

  postgresql:
    parameters:
      wal_compression: lz4
      max_wal_size: 6GB
      checkpoint_timeout: 15min
      checkpoint_flush_after: 2MB
      wal_writer_flush_after: 2MB
      min_wal_size: 4GB
      shared_buffers: 4GB
      effective_cache_size: 12GB
      work_mem: 62MB
      maintenance_work_mem: 1GB
      autovacuum_vacuum_cost_limit: "2400"
      random_page_cost: "1.1"
      effective_io_concurrency: "64"
      maintenance_io_concurrency: "64"
    pg_hba:
      - host all all all scram-sha-256

  serviceAccountTemplate:
    metadata:
      annotations:
        azure.workload.identity/client-id: "$AKS_UAMI_WORKLOAD_CLIENTID"
      labels:
        azure.workload.identity/use: "true"

  backup:
    barmanObjectStore:
      destinationPath: "https://${PG_PRIMARY_STORAGE_ACCOUNT_NAME}.blob.core.windows.net/backups"
      azureCredentials:
        inheritFromAzureAD: true
    retentionPolicy: '7d'
EOF

# Post installation steps
print_message "34" "Post installation steps..."

print_message "34" "Check pods..."
echo "kubectl get pods --context $AKS_PRIMARY_CLUSTER_NAME --namespace $PG_NAMESPACE -l cnpg.io/cluster=$PG_PRIMARY_CLUSTER_NAME"

# Prepare for benchmark
print_message "34" "Prepare for benchmark..."
kubectl get secret db-user-pass -n "$PG_NAMESPACE" -o yaml | \
sed "s/name: db-user-pass/name: ${PG_PRIMARY_CLUSTER_NAME}-app/" | \
kubectl apply -n "$PG_NAMESPACE" -f -

print_message "34" "Adjust your user environment variables..."
echo 'export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"'
echo 'export AKS_PRIMARY_CLUSTER_NAME'=$AKS_PRIMARY_CLUSTER_NAME
echo 'export PG_PRIMARY_CLUSTER_NAME'=$PG_PRIMARY_CLUSTER_NAME
echo 'export PG_NAMESPACE'=$PG_NAMESPACE

print_message "34" "Initialize benchmark..."
kubectl wait --for=condition=Ready cluster $PG_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE --timeout=30m
kubectl cnpg pgbench $PG_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE --job-name pgbench-init -- -i -s 1000 -d appdb

print_message "34" "Run benchmark..."
echo "kubectl cnpg pgbench $PG_PRIMARY_CLUSTER_NAME -n $PG_NAMESPACE --job-name pgbench -- -c 64 -j 4 -t 50 -P 5 -d appdb"

print_message "34" "View jobs..."
echo "k9s -A"

print_message "32" "All steps completed successfully! Time is $(date)"
