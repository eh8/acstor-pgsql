# CloudNativePG on AKS

Short, skimmable lab script. Commands are ready to copy/paste.

## 1) Cloud Shell + Subscription

Open Cloud Shell and target the right subscription so everything lands in the demo environment.

```bash
az account set --subscription <change>
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
```

## 2) Provision AKS

If you need to create the lab environment from scratch, run Terraform; otherwise skip to the prebuilt cluster.

```bash
terraform init
terraform apply
```

## 3) Use the prebuilt cluster

Pull kubeconfig for the shared cluster and confirm the nodes are ready.

```bash
az aks get-credentials --resource-group demo-aks-rg-<change> --name demo-aks-cluster-<change>
kubectl get nodes
```

## 4) Install k9s (optional)

Optional: a fast live view of pods and namespaces while we walk through the lab.

```bash
curl -sS https://webinstall.dev/k9s | bash
k9s -A
```

## 5) Install CloudNativePG operator

Install the CNPG controller, the kubectl cnpg plugin, wait for it to be ready, and confirm the CRDs.

```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.1.yaml

curl -sSfL \
  https://github.com/cloudnative-pg/cloudnative-pg/raw/main/hack/install-cnpg-plugin.sh | \
  sh -s -- -b "$HOME/.local/bin"

kubectl rollout status deployment -n cnpg-system cnpg-controller-manager

kubectl get crd | rg cnpg
```

## 6) StorageClass (Premium SSD v2)

Create a Premium SSD v2 StorageClass that we’ll use for both data and WAL volumes.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: premium2-disk-sc
parameters:
  cachingMode: None
  skuName: PremiumV2_LRS
  DiskIOPSReadWrite: "3000"
  DiskMBpsReadWrite: "125"
provisioner: disk.csi.azure.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
EOF
kubectl get sc
```

## 7) Create a CNPG cluster (Pv2, 10Gi data, 5Gi WAL)

Deploy a 3-instance cluster using the Pv2 StorageClass for data and WAL.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: cnpg-demo
spec:
  instances: 3
  storage:
    size: 10Gi
    storageClass: premium2-disk-sc
  walStorage:
    size: 5Gi
    storageClass: premium2-disk-sc
EOF
```

## 8) Watch it come up

Watch the pods start and use CNPG commands to verify the cluster is healthy.

```bash
k9s -A
kubectl get pods -l cnpg.io/cluster=cnpg-demo -w
```

```bash
kubectl get cluster
kubectl cnpg status cnpg-demo
kubectl get pdb
```

Follow logs from all CNPG pods:

```bash
kubectl logs -f -l cnpg.io/cluster=cnpg-demo --all-containers --tail=100
```

## 9) Connect and add data

Open a psql session, create a sample table, insert rows, and read them back.

```bash
kubectl cnpg psql cnpg-demo
```

```sql
\l
\dt

CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name TEXT NOT NULL,
    email TEXT UNIQUE NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT NOW()
);

INSERT INTO users (name, email) VALUES
    ('Alice', 'alice@example.com'),
    ('Bob',   'bob@example.com'),
    ('Carol', 'carol@example.com');
```

## 10) Verify data on multiple pods

Show that replicas can read the same data by querying from different pods.

```bash
kubectl exec -it pod/cnpg-demo-1 -- psql -U postgres -d postgres -c "SELECT * FROM users;"
kubectl exec -it pod/cnpg-demo-3 -- psql -U postgres -d postgres -c "SELECT * FROM users;"
```

## 11) Scale to 5 instances

Scale the cluster to 5 instances and watch the new pods appear.

```bash
kubectl patch cluster cnpg-demo --type merge -p '{"spec":{"instances":5}}'
kubectl get pods -l cnpg.io/cluster=cnpg-demo -w
```

```bash
k9s -A
```

## 12) Confirm data after scaling

Verify the data is still present after scaling out.

```bash
kubectl exec -it pod/cnpg-demo-5 -- psql -U postgres -d postgres -c "SELECT * FROM users;"
```

## 13) Inspect CNPG secrets (optional)

CNPG creates Kubernetes Secrets for credentials; show where they live and how to view them.

```bash
kubectl get secrets
k9s -A
```

In k9s, run `:secrets`, open a CNPG secret, and press `x` to decode.

## 14) Run a quick pgbench (optional)

Initialize a small dataset and run a short benchmark to validate performance.

```bash
kubectl cnpg pgbench --job-name pgbench-init cnpg-demo -- --initialize --scale 100
kubectl cnpg pgbench cnpg-demo --ttl 600 -- --time 30 --progress 1 --client 4 --jobs 4
```

## Appendix

Delete finished/completed jobs

```bash
kubectl delete job --field-selector=status.successful==1 --all-namespaces
kubectl delete job --field-selector=status.failed>0 --all-namespaces
```

Reset lab to end of Step 5 (keep operator installed)

Aggressive cleanup of CNPG resources and data, but keep the operator running. Not sure how well tihs works.

```bash
kubectl delete cluster --all --all-namespaces
kubectl delete scheduledbackup,backup,pooler,publication,subscription --all --all-namespaces
kubectl delete pvc -l cnpg.io/cluster --all-namespaces
kubectl delete svc -l cnpg.io/cluster --all-namespaces
kubectl delete pdb -l cnpg.io/cluster --all-namespaces
kubectl delete secret -l cnpg.io/cluster --all-namespaces
kubectl delete job -l cnpg.io/cluster --all-namespaces
kubectl delete sc premium2-disk-sc
```

Full wipe (removes operator + CRDs)

Run this only after the cleanup above, or you may leave CNPG resources stuck with finalizers.

```bash
kubectl delete namespace cnpg-system
kubectl get crd | rg cnpg | awk '{print $1}' | xargs -r kubectl delete crd
```
