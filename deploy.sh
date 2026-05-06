#!/bin/bash
# Exit immediately if a command exits with a non-zero status.
set -e

echo "============================================================"
echo "Task 1: Setting Environment Variables"
echo "============================================================"
# Fetch current project ID and Number dynamically
export PROJECT_ID=$(gcloud config get-value project)
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format="value(projectNumber)")

export REGION="us-west1"
export ZONE="us-west1-b"
export CLUSTER_1="gke-cluster-1"
export CLUSTER_2="gke-cluster-2"

export WORKLOAD_POOL="${PROJECT_ID}.svc.id.goog"
export MESH_ID="proj-${PROJECT_NUMBER}"
export WORKDIR="${HOME}/secure-gke"

export GIT_USER_EMAIL="you@example.com"
export GIT_USER_NAME="Your Name"

echo "Project ID: ${PROJECT_ID}"
echo "Project Number: ${PROJECT_NUMBER}"
echo "Mesh ID: ${MESH_ID}"

echo "============================================================"
echo "Task 2: Enabling Required Google Cloud APIs"
echo "============================================================"
gcloud services enable \
    --project=${PROJECT_ID} \
    anthos.googleapis.com \
    anthosconfigmanagement.googleapis.com \
    container.googleapis.com \
    stackdriver.googleapis.com \
    monitoring.googleapis.com \
    cloudtrace.googleapis.com \
    logging.googleapis.com \
    meshca.googleapis.com \
    meshtelemetry.googleapis.com \
    meshconfig.googleapis.com \
    multiclustermetering.googleapis.com \
    multiclusteringress.googleapis.com \
    multiclusterservicediscovery.googleapis.com \
    iamcredentials.googleapis.com \
    iam.googleapis.com \
    gkeconnect.googleapis.com \
    gkehub.googleapis.com \
    compute.googleapis.com \
    sourcerepo.googleapis.com \
    osconfig.googleapis.com \
    trafficdirector.googleapis.com \
    networkservices.googleapis.com \
    mesh.googleapis.com \
    cloudresourcemanager.googleapis.com

echo "============================================================"
echo "Task 3: Creating GKE Clusters"
echo "============================================================"
echo "--> Creating ${CLUSTER_1} (Async)..."
gcloud container clusters create ${CLUSTER_1} \
    --node-locations ${ZONE} \
    --location ${REGION} \
    --num-nodes "2" --min-nodes "2" --max-nodes "2" \
    --workload-pool ${WORKLOAD_POOL} \
    --enable-ip-alias \
    --machine-type "e2-standard-4" \
    --node-labels mesh_id=${MESH_ID} \
    --labels mesh_id=${MESH_ID} \
    --fleet-project=${PROJECT_ID} \
    --async

echo "--> Creating ${CLUSTER_2} (Waiting for completion)..."
gcloud container clusters create ${CLUSTER_2} \
    --node-locations ${ZONE} \
    --location ${REGION} \
    --num-nodes "2" --min-nodes "2" --max-nodes "2" \
    --workload-pool ${WORKLOAD_POOL} \
    --enable-ip-alias \
    --machine-type "e2-standard-4" \
    --node-labels mesh_id=${MESH_ID} \
    --labels mesh_id=${MESH_ID} \
    --fleet-project=${PROJECT_ID}

echo "--> Verifying cluster status:"
gcloud container clusters list

echo "============================================================"
echo "Task 4: Setup Working Directory & Enable Fleet Mesh"
echo "============================================================"
mkdir -p ${WORKDIR}
cd ${WORKDIR}

gcloud storage cp -r gs://spls/gsp1241/k8s/ ~
gcloud beta container hub mesh enable --project=${PROJECT_ID}

echo "============================================================"
echo "Task 5: Configuring Mesh on ${CLUSTER_1}"
echo "============================================================"
gcloud container clusters get-credentials ${CLUSTER_1} --region ${REGION}

echo "--> Waiting for controlplanerevisions CRD to be established on ${CLUSTER_1}..."
for NUM in {1..60} ; do
  kubectl get crd | grep controlplanerevisions.mesh.cloud.google.com && break
  sleep 10
done
kubectl wait --for=condition=established crd controlplanerevisions.mesh.cloud.google.com --timeout=10m

echo "--> Updating labels to trigger Managed Mesh on ${CLUSTER_1}..."
gcloud container clusters update ${CLUSTER_1} \
    --project ${PROJECT_ID} \
    --region ${REGION} \
    --update-labels=mesh_id=${MESH_ID}

kubectl apply -f ~/k8s/namespace-istio-system.yaml
kubectl apply -f ~/k8s/controlplanerevision-asm-managed.yaml

echo "--> Waiting for Control Plane Provisioning on ${CLUSTER_1}..."
kubectl wait --for=condition=ProvisioningFinished controlplanerevision asm-managed -n istio-system --timeout 600s

kubectl apply -f ~/k8s/namespace-asm-gateways.yaml
kubectl apply -f ~/k8s/asm-ingressgateway.yaml

echo "============================================================"
echo "Task 6: Configuring Mesh on ${CLUSTER_2}"
echo "============================================================"
gcloud container clusters get-credentials ${CLUSTER_2} --region ${REGION}

echo "--> Waiting for controlplanerevisions CRD to be established on ${CLUSTER_2}..."
for NUM in {1..60} ; do
  kubectl get crd | grep controlplanerevisions.mesh.cloud.google.com && break
  sleep 10
done
kubectl wait --for=condition=established crd controlplanerevisions.mesh.cloud.google.com --timeout=10m

echo "--> Updating labels to trigger Managed Mesh on ${CLUSTER_2}..."
gcloud container clusters update ${CLUSTER_2} \
    --project ${PROJECT_ID} \
    --region ${REGION} \
    --update-labels=mesh_id=${MESH_ID}

kubectl apply -f ~/k8s/namespace-istio-system.yaml
kubectl apply -f ~/k8s/controlplanerevision-asm-managed.yaml

echo "--> Waiting for Control Plane Provisioning on ${CLUSTER_2}..."
kubectl wait --for=condition=ProvisioningFinished controlplanerevision asm-managed -n istio-system --timeout 600s

kubectl apply -f ~/k8s/namespace-asm-gateways.yaml
kubectl apply -f ~/k8s/asm-ingressgateway.yaml

echo "============================================================"
echo "Task 7: IAM Bindings & Git Configuration"
echo "============================================================"
gcloud --project=${PROJECT_ID} iam service-accounts add-iam-policy-binding \
    --role roles/iam.workloadIdentityUser \
    --member "serviceAccount:${PROJECT_ID}.svc.id.goog[config-management-system/root-reconciler]" \
    asm-reader-sa@${PROJECT_ID}.iam.gserviceaccount.com

git config --global user.email "${GIT_USER_EMAIL}"
git config --global user.name "${GIT_USER_NAME}"

echo "============================================================"
echo "SUCCESS: Infrastructure Deployment Complete!"
echo "============================================================"


echo "============================================================"
echo "Task 8: Install Config Sync (Fleet Feature)"
echo "============================================================"
#  UPDATE THIS VARIABLE WITH THE REPO URL FROM YOUR LAB INSTRUCTIONS 
export GIT_SYNC_REPO="https://github.com/GoogleCloudPlatform/anthos-config-management-samples" 
export GIT_SYNC_BRANCH="main"
export AUTH_TYPE="none" # 'none' is used for public repos. Use 'gcpserviceaccount' for private Cloud Source Repos

echo "--> Enabling Config Management feature on the Fleet..."
gcloud beta container hub config-management enable --project=${PROJECT_ID}

echo "--> Installing Config Sync (Defaults) on ${CLUSTER_1} and ${CLUSTER_2}..."
# This mimics "leave all the fields with their default values"
cat <<EOF > default-config-sync.yaml
applySpecVersion: 1
spec:
  configSync:
    enabled: true
EOF

gcloud beta container fleet config-management apply \
    --membership=${CLUSTER_1} \
    --config=default-config-sync.yaml \
    --project=${PROJECT_ID}

gcloud beta container fleet config-management apply \
    --membership=${CLUSTER_2} \
    --config=default-config-sync.yaml \
    --project=${PROJECT_ID}

echo "--> Waiting for Config Sync controllers to initialize (approx 2-3 minutes)..."
# We must wait until the RootSync CRD is established in the clusters before deploying the package
for CLUSTER in ${CLUSTER_1} ${CLUSTER_2}; do
    gcloud container clusters get-credentials ${CLUSTER} --region ${REGION} --project ${PROJECT_ID}
    
    for NUM in {1..30}; do
        kubectl get crd rootsyncs.configsync.gke.io >/dev/null 2>&1 && break
        echo "    ...waiting for RootSync CRD on ${CLUSTER}..."
        sleep 10
    done
    kubectl wait --for=condition=established crd rootsyncs.configsync.gke.io --timeout=5m
done

echo "============================================================"
echo "Task 9: Deploy 'root-sync' Package (Cluster Scoped)"
echo "============================================================"
echo "--> Generating RootSync manifest..."
cat <<EOF > root-sync-package.yaml
apiVersion: configsync.gke.io/v1beta1
kind: RootSync
metadata:
  name: root-sync
  namespace: config-management-system
spec:
  sourceFormat: unstructured
  git:
    repo: "${GIT_SYNC_REPO}"
    branch: "${GIT_SYNC_BRANCH}"
    dir: "/"
    auth: "${AUTH_TYPE}"
EOF

echo "--> Deploying package to ${CLUSTER_1}..."
gcloud container clusters get-credentials ${CLUSTER_1} --region ${REGION} --project ${PROJECT_ID}
kubectl apply -f root-sync-package.yaml

echo "--> Deploying package to ${CLUSTER_2}..."
gcloud container clusters get-credentials ${CLUSTER_2} --region ${REGION} --project ${PROJECT_ID}
kubectl apply -f root-sync-package.yaml

echo "============================================================"
echo "SUCCESS: Config Sync Installed and Git Package Deployed!"
echo "============================================================"
