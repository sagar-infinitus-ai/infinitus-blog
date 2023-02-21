#!/usr/bin/env bash
# Installs a whole cluster from scratch and provisions all the necessary services
set -eu -o pipefail

# Let's make sure we're in a known directory
cd "$(dirname "$0")"

setup_workload_identity() {
    local gcp_project_id="${1-}"
    local namespace="${2-}"
    local kube_service_account="${3-}"
    local google_service_account="${4-}"

    if [ "$1" = "" ] || \
           [ "$2" = "" ] || \
           [ "$3" = "" ] || \
           [ "$4" = "" ]; then
        log_err "setup_workload_identity needs four args. got: '$1' '$2' '$3' '$4'"
        exit 1
    fi

    # Setup service account for Workload Identity
    # ref: https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity
    echo "Creating k8s service account ${kube_service_account} in namespace ${namespace} for Workload Identity..."
    kubectl -n "${namespace}" create serviceaccount "${kube_service_account}"

    # Add permissions for our K8s service account to use the provided google service account
    echo "Adding IAM policy binding for k8s service account ${gcp_project_id}.svc.id.goog[${namespace}/${kube_service_account}]..."
    gcloud iam service-accounts add-iam-policy-binding \
           --project="${gcp_project_id}" \
           --role roles/iam.workloadIdentityUser \
           --member "serviceAccount:${gcp_project_id}.svc.id.goog[${namespace}/${kube_service_account}]" \
           "${google_service_account}"

    # Point the K8s service account to the Google service account
    echo "Annotating the k8s service account for Workload Identity ${kube_service_account}..."
    kubectl annotate serviceaccount --overwrite \
            --namespace "${namespace}" "${kube_service_account}" \
            iam.gke.io/gcp-service-account="${google_service_account}"
}

gcp_service_account_exists() {
    local gcp_project_id="${1-}"
    local sa_email="${2-}"

    local sa_exists
    sa_exists=$(gcloud --project="${gcp_project_id}" iam service-accounts list --filter="email=${sa_email}" --format="json" | jq -r '.[].displayName')
    test "$sa_exists" != ""
}

gcp_project_id="${1-}"
gcloud_cmd="gcloud --project=${gcp_project_id}"

zone="${2-}"

case "$zone" in
    "")
        echo "usage: full-installation.sh <project-id> <zone>"
        exit 1
        ;;
    *)
        zone=$($gcloud_cmd compute zones list --filter="name=$zone" --format "value(name)")
        if [ "$zone" = "" ]; then
            echo "zone ${2-} is not valid"
            exit 1
        fi
esac


region_link=$($gcloud_cmd compute zones describe "$zone" --format="value(region)")
region=$($gcloud_cmd compute regions describe "$region_link" --format="value(name)")

# A note on permissions
# When we create a cluster, we set up workload identities using service accounts in the project
# being used. This means that when setting up a cluster in a project other than backend-232322,
# permissions have to be explicitly granted outside of this script for anything to work.
# I feel like this is a more explicit way to express access than to use service accounts from
# the production project for workload identity

# The cluster will assume this name
CLUSTER_BASENAME=infinitus-blog
network_name="infinitus-blog"
network_self_link=$($gcloud_cmd compute networks describe "${network_name}" --format="value(selfLink)")

# Service account names to be used for workload identities
# We'll assume that these exist. Why not create them if they don't exist?
# - these should be created as part of setting up roles and accounts for the project
# - hard-coding permissions for these accounts here will be a maintenance mess
#
# required service accounts are "backend", "nlp-server", "auto-dialer" and "prometheus"

blog_sa="infinitus-blog@${gcp_project_id}.iam.gserviceaccount.com"

echo "Checking if required service accounts exist..."
missing_service_accounts=""
for sa_email in $blog_sa; do
    if ! gcp_service_account_exists "$gcp_project_id" "$sa_email"; then
        missing_service_accounts="$missing_service_accounts, $sa_email"
    fi
done
if [ "$missing_service_accounts" != "" ]; then
    echo "Missing service accounts: $missing_service_accounts"
    echo "Aborting..."
    exit 1
fi

cluster_name="${CLUSTER_BASENAME}-${zone}"

# Hard-coding these for now
subnet_cidr="192.168.1.0/24"

master_cidr="172.16.0.0/28"

# Create the cluster
echo "Creating new K8s cluster with name '${cluster_name}'..."
$gcloud_cmd deployment-manager deployments create "${cluster_name}" \
       --properties="network:${network_self_link},zone:${zone},region:${region},master_cidr:${master_cidr},subnet_cidr:${subnet_cidr}" \
       --template=gke-cluster.jinja

# Get kubectl credentials
echo "Obtaining kubectl credentials..."
$gcloud_cmd container clusters get-credentials "${cluster_name}" --zone "${zone}"

# # Install nginx ingress
# echo "Installing NGINX Ingress..."
# ./nginx/ingress-nginx.sh

# # Install cert-manager
# echo "Installing cert-manager..."
# ./cert-manager.sh

# Setup namespaces
echo "Creating wp-blog namespace..."
kubectl create namespace wp-blog

# Set up workload identities
setup_workload_identity "$gcp_project_id" "wp-blog" "infinitus-blog" "${blog_sa}"


echo -e "\n${cluster_name} has been provisioned."
