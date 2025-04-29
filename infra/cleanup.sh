#!/bin/bash
set -euo pipefail

# ==========================================================================================
# This script deletes the stack named 'MWAABPGSparkMainStack' and all associated resources
# ==========================================================================================

# Variables 
MAIN_STACK_NAME="MWAABPGSparkMainStack"

ECR_REPO_NAME="bpg"
CFN_S3_BUCKET_NAME_PREFIX="mwaa-bpg-spark-cfn-templates"
MWAA_S3_BUCKET_NAME_PREFIX="airflow-bpg-blog"

EKS_CLUSTERS=(
    "datascience-cluster"
    "analytics-cluster"
    "gateway-cluster"
)

GATEWAY_CLUSTER_NAME="gateway-cluster"

IRSA_SERVICE_ACCOUNTS=(
    "emr/emr-containers-sa-spark"
    "kube-system/aws-load-balancer-controller"
)

# Global Variables
AWS_ACCOUNT_ID=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script deletes the stack named 'MWAABPGSparkMainStack' "
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to create resources in"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  ./$(basename "$0")"
    exit 1
}

# Check Dependencies
check_dependencies() {
    command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }
    command -v eksctl >/dev/null 2>&1 || { log "eksctl is required but it's not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log "kubectl is required but it's not installed. Aborting."; exit 1; }
}

# Setup kubectl context
setup_kubectl_context() {
    local cluster_name="$1"

    log "Setting up kubectl context for cluster: $cluster_name"
    
    if ! aws eks update-kubeconfig --name "$cluster_name"; then
        log "Error: Failed to update kubeconfig for cluster $cluster_name"
        return 1
    fi

    if ! kubectl get nodes &>/dev/null; then
        log "Error: Failed to connect to cluster $cluster_name"
        return 1
    fi
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Delete HMS external service and AWS Load Balancer Controller
delete_aws_lb_controller() {
    log "Starting cleanup process for HMS external service and AWS Load Balancer Controller ..."

    # Remove HMS external service
    log "Removing HMS external service..."
    kubectl delete -f "./bpg/bpg-elb-svc.yaml" || true

    # Uninstall AWS Load Balancer Controller
    log "Uninstalling AWS Load Balancer Controller..."
    helm uninstall aws-load-balancer-controller -n kube-system || true

    log "Cleanup process completed for HMS external service and AWS Load Balancer Controller."
}

# Delete Stack
delete_cfn_stack() {
    local stack_arn

    # Check if the stack exists
    if ! aws cloudformation describe-stacks --stack-name "$MAIN_STACK_NAME" &>/dev/null; then
        log "Stack $MAIN_STACK_NAME does not exist. Skipping deletion."
        return 0
    fi

    log "Deleting stack: $MAIN_STACK_NAME"
    aws cloudformation delete-stack --stack-name "$MAIN_STACK_NAME"

    log "Stack deletion initiated. Monitor progress in AWS CloudFormation console: https://console.aws.amazon.com/cloudformation/"
    log "Waiting for stack deletion to complete (timeout set to 30 minutes)..."

    stack_arn=$(aws cloudformation describe-stacks --stack-name "$MAIN_STACK_NAME" --query 'Stacks[0].StackId' --output text)
    aws cloudformation wait stack-delete-complete --stack-name "$stack_arn"

    if [ $? -eq 0 ]; then
        log "Stack $MAIN_STACK_NAME has been successfully deleted."
    else
        log "Error: Stack deletion failed or timed out after 30 minutes."
        return 1
    fi
}

# Function to delete IAM service accounts and associated CloudFormation stacks
delete_iam_serviceaccounts() {

    log "Deleting IAM service accounts and associated CloudFormation stacks..."

    # Loop through each cluster
    for cluster_name in "${EKS_CLUSTERS[@]}"; do
        log "Checking IAM service accounts for cluster: $cluster_name"

        # Loop through each service account
        for sa in "${IRSA_SERVICE_ACCOUNTS[@]}"; do
            # Extract the namespace and the name of the service account
            local namespace=$(echo "$sa" | cut -d '/' -f 1)
            local sa_name=$(echo "$sa" | cut -d '/' -f 2)

            log "Checking IAM service account: $sa_name in namespace: $namespace for cluster: $cluster_name"

            # Check if the IAM service account exists
            if eksctl get iamserviceaccount --name "$sa_name" --namespace "$namespace" --cluster "$cluster_name" > /dev/null 2>&1; then
                log "Deleting IAM service account: $sa_name in namespace: $namespace for cluster: $cluster_name"

                # Delete the IAM service account using eksctl
                eksctl delete iamserviceaccount \
                --name "$sa_name" \
                --namespace "$namespace" \
                --cluster "$cluster_name" \
                --wait
            else
                log "IAM service account: $sa_name in namespace: $namespace for cluster: $cluster_name does not exist. Skipping deletion."
            fi
        done
    done

}

# Delete ECR repo
delete_ecr_repository() {
    log "Deleting all images in $ECR_REPO_NAME"

    # Check if the repository exists
    if ! aws ecr describe-repositories --repository-names "$ECR_REPO_NAME" &>/dev/null; then
        log "Repository $ECR_REPO_NAME does not exist.. Skipping deletion."
        return 0
    fi

    # List all image IDs in the repository
    local image_ids
    image_ids=$(aws ecr list-images --repository-name "$ECR_REPO_NAME" --query 'imageIds[*]' --output json)

    if [[ "$image_ids" == "[]" ]]; then
        log "No images found in the repository."
    else
        # Delete all images
        if aws ecr batch-delete-image --repository-name "$ECR_REPO_NAME" --image-ids "$image_ids"; then
            log "All images deleted successfully."
        else
            log "Error occurred while deleting images."
            return 1
        fi
    fi

    log "Now deleting the repository."
}

# Empty S3 bucket
empty_bpg_s3_bucket() {
    local versions
    local delete_markers
    local s3_bucket_name="${MWAA_S3_BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    if aws s3api head-bucket --bucket "$s3_bucket_name" 2>/dev/null; then
        echo "Bucket $s3_bucket_name exists"

        log "Preparing to empty S3 bucket: $s3_bucket_name"

        # List and delete all versions of objects in the bucket
        versions=$(aws s3api list-object-versions --bucket "$s3_bucket_name" --query 'Versions[].{Key:Key,VersionId:VersionId}' --output json)
        if [[ -z "$versions" || "$versions" == "null" || "$versions" == "[]" ]]; then
        log "No object versions found in the bucket."
        else
            # Delete all object versions
            if aws s3api delete-objects --bucket "$s3_bucket_name" --delete "{\"Objects\": $versions}" --output text; then
                log "All object versions deleted successfully."
            else
                log "Error occurred while deleting object versions."
                return 1
            fi
        fi

        # List and delete all delete markers in the bucket
        delete_markers=$(aws s3api list-object-versions --bucket "$s3_bucket_name" --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json)

        if [[ -z "$delete_markers" || "$delete_markers" == "null" || "$delete_markers" == "[]"  ]]; then
            log "No delete markers found in the bucket."
        else
            # Delete all delete markers
            if aws s3api delete-objects --bucket "$s3_bucket_name" --delete "{\"Objects\": $delete_markers}" --output text; then
                log "All delete markers deleted successfully."
            else
                log "Error occurred while deleting delete markers."
                return 1
            fi
        fi

        log "S3 bucket: $s3_bucket_name emptied"
    else
        echo "Bucket $s3_bucket_name does not exist"
    fi
}

# Delete S3 bucket
delete_s3_bucket() {
    local s3_bucket_name="${CFN_S3_BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"

    if aws s3api head-bucket --bucket "$s3_bucket_name" 2>/dev/null; then
        log "Bucket $s3_bucket_name exists"
        log "Preparing to delete S3 bucket: $s3_bucket_name"

        # Delete the bucket and all its contents
        if aws s3 rb "s3://$s3_bucket_name" --force; then
            log "Bucket $s3_bucket_name and all its contents have been successfully deleted."
        else
            log "Error occurred while deleting the bucket."
            return 1
        fi
    else
        echo "Bucket $s3_bucket_name does not exist"
    fi
}

# Main function
main() {
    log "Cleanup process execution initiated..."

    get_account_id

    # Check if cluster exists
    if ! aws eks describe-cluster --name "$GATEWAY_CLUSTER_NAME" >/dev/null 2>&1; then
        log "Cluster $GATEWAY_CLUSTER_NAME does not exist.. Proceeding..."
    else
        log "Cluster $GATEWAY_CLUSTER_NAME exists.. deleting.."
        setup_kubectl_context "$GATEWAY_CLUSTER_NAME"
        delete_aws_lb_controller
    fi

    delete_ecr_repository
    delete_iam_serviceaccounts
    empty_bpg_s3_bucket
    delete_cfn_stack
    delete_s3_bucket

    log "Cleanup process completed successfully"
}


##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##


# Determine the directory of the script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Set up a trap to ensure popd is called on exit
trap 'popd > /dev/null' EXIT

# Temporarily change to the script's directory
pushd "$SCRIPT_DIR" > /dev/null

# Check for help flag or any arguments
if [ $# -ne 0 ] || { [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; }; then
    usage
fi

# Check for required tools
check_dependencies

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check required environment variables
[[ -z "${AWS_REGION:-}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

# Call Main 
main