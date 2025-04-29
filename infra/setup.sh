#!/bin/bash
set -euo pipefail

# =====================================================================================
# This script creates an S3 bucket, uploads CloudFormation templates, executes the
# main stack, waits, and then executes few additional scripts.
#
# Key functionalities include:
# - Setting up an S3 bucket
# - Uploading CloudFormation templates
# - Executing the main CloudFormation stack
# - Setup EKS Clusters
# - Setup ECR for Batch Processing Gateway
# - Setup EMR on EKS Clusters
# - Setup RDS Proxy
# - Setup Sample App
#
#  This script takes about 32 minutes to complete.
#
# To delete resources, use:
# ./cleanup.sh
# =====================================================================================

# Constants
BUCKET_NAME_PREFIX="mwaa-bpg-spark-cfn-templates"
MAIN_STACK_NAME="MWAABPGSparkMainStack"
MAIN_TEMPLATE_FILE="main-stack.yaml"
TEMPLATE_FILES=(
    "main-stack.yaml"
    "network-stack.yaml"
    "ecr-stack.yaml"
    "s3-stack.yaml"
    "eks-stack.yaml"
    "emr-on-eks-roles-stack.yaml"
    "rds-stack.yaml"
    "rds-proxy-stack.yaml"
    "mwaa-stack.yaml"
)

# Scripts
EKS_CONFIGURE_SCRIPT="eks/configure_eks_cluster.sh"
EMR_EKS_SCRIPT="emr_on_eks/configure_emr_on_eks.sh"
RDS_PROXY_SCRIPT="rds/associate_rds_to_proxy.sh"

# EKS Clusters
DATA_SCIENCE_CLUSTER="datascience-cluster"
ANALYTICS_CLUSTER="analytics-cluster"
GATEWAY_CLUSTER="gateway-cluster"

# EKS Cluster
GATEWAY_CLUSTER="gateway-cluster"
DATA_PROCESSING_CLUSTERS=(
    $DATA_SCIENCE_CLUSTER
    $ANALYTICS_CLUSTER
)

# Global Variables
AWS_ACCOUNT_ID=""
S3_BUCKET_NAME=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: ./$(basename "$0")"
    echo "This script sets up an S3 bucket, uploads CFN templates, deploys the main stack, and runs additional scripts."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to create resources in"
    echo "  REPO_DIR      The directory containing the CloudFormation templates and scripts"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  export REPO_DIR=/path/to/blog/directory"
    echo "  ./$(basename "$0")"
    exit 1
}

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Setup S3 bucket
setup_s3_bucket() {
    S3_BUCKET_NAME="${BUCKET_NAME_PREFIX}-${AWS_ACCOUNT_ID}-${AWS_REGION}"
    log "Setting up S3 bucket: ${S3_BUCKET_NAME}..."
    
    if ! aws s3api head-bucket --bucket "${S3_BUCKET_NAME}" 2>/dev/null; then
        if [[ $AWS_REGION != "us-east-1" ]]; then
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_NAME}" \
                --region "${AWS_REGION}" \
                --create-bucket-configuration LocationConstraint="${AWS_REGION}" || { log "Error: Failed to create S3 bucket ${S3_BUCKET_NAME}."; return 1; }
        else
            aws s3api create-bucket \
                --bucket "${S3_BUCKET_NAME}" \
                --region "${AWS_REGION}" || { log "Error: Failed to create S3 bucket ${S3_BUCKET_NAME}."; return 1; }
        fi
        log "Created S3 bucket: ${S3_BUCKET_NAME}"
    else
        log "S3 bucket ${S3_BUCKET_NAME} already exists"
    fi

    # Enable default encryption
    aws s3api put-bucket-encryption \
        --bucket "${S3_BUCKET_NAME}" \
        --server-side-encryption-configuration '{"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]}' || { log "Error: Failed to enable encryption for ${S3_BUCKET_NAME}."; return 1; }
    log "Enabled default encryption on S3 bucket: ${S3_BUCKET_NAME}"
}

# Upload templates
upload_templates() {
    log "Uploading CloudFormation templates..."
    for template in "${TEMPLATE_FILES[@]}"; do
        aws s3 cp "./cloudformation/${template}" "s3://${S3_BUCKET_NAME}/cloudformation/" || { log "Error: Failed to upload ${template}."; return 1; }
        log "Uploaded ${template}"
    done
    log "All templates uploaded successfully"
}

# Deploy main stack
deploy_main_stack() {
    log "Deploying main CloudFormation stack..."
    
    if aws cloudformation describe-stacks --stack-name "${MAIN_STACK_NAME}" >/dev/null 2>&1; then
        aws cloudformation update-stack \
            --stack-name "${MAIN_STACK_NAME}" \
            --disable-rollback \
            --template-url "https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${MAIN_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters ParameterKey=TemplateBucketName,ParameterValue="${S3_BUCKET_NAME}" || { log "Error: Failed to update main stack."; return 1; }
        log "Updating main stack: ${MAIN_STACK_NAME}"
    else
        aws cloudformation create-stack \
            --stack-name "${MAIN_STACK_NAME}" \
            --disable-rollback \
            --template-url "https://${S3_BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/cloudformation/${MAIN_TEMPLATE_FILE}" \
            --capabilities CAPABILITY_NAMED_IAM \
            --parameters ParameterKey=TemplateBucketName,ParameterValue="${S3_BUCKET_NAME}" || { log "Error: Failed to create main stack."; return 1; }
        log "Creating main stack: ${MAIN_STACK_NAME}"
    fi

    aws cloudformation wait stack-create-complete --stack-name "${MAIN_STACK_NAME}" 2>/dev/null || \
    aws cloudformation wait stack-update-complete --stack-name "${MAIN_STACK_NAME}" || \
    { log "Error: Stack creation/update failed or timed out."; return 1; }

    log "Main stack deployment completed successfully"
}

# EKS Configure script
execute_eks_configure_script() {
    local cluster_name=$1

    log "Executing $EKS_CONFIGURE_SCRIPT..."
    bash "${EKS_CONFIGURE_SCRIPT}" "$cluster_name" || { log "Error: Failed to execute $EKS_CONFIGURE_SCRIPT."; return 1; }
    log "$EKS_CONFIGURE_SCRIPT executed successfully for $cluster_name"
}

# Execute EMR EKS script for both clusters
execute_emr_eks_script() {
    local cluster_name=$1

    log "Configuring $cluster_name..."
    bash "${EMR_EKS_SCRIPT}" "$cluster_name" || \
    { log "Error: Failed to execute $EMR_EKS_SCRIPT for $cluster_name."; return 1; }
    log "$cluster_name successfully configured"
}

# Execute RDS Proxy script
execute_rds_proxy_script() {

    # Note: There is a known issue with AWS::RDS::DBProxyTargetGroup in CloudFormation
    # where it fails to register the proxy with the database correctly.
    # As a workaround, this function uses the AWS CLI method to
    # register the proxy with the database after the CloudFormation stack is created.

    log "Configuring RDS..."
    bash "${RDS_PROXY_SCRIPT}" || \
    { log "Error: Failed to execute $RDS_PROXY_SCRIPT for RDS cluster."; return 1; }
    log "RDS Proxy successfully configured"
}

# Main function
main() {
    log "Setup script execution initiated..."

    # Get Account ID
    get_account_id

    # Setup and Deploy CloudFormation Stacks
    setup_s3_bucket
    upload_templates
    deploy_main_stack

    # Configure Gateway EKS Cluster
    execute_eks_configure_script "$GATEWAY_CLUSTER"

    # Configure Data Processing EKS Clusters
    for cluster_name in "${DATA_PROCESSING_CLUSTERS[@]}"; do
        # Setup EKS Cluster
        execute_eks_configure_script "$cluster_name"
        # Setup EMR on EKS Cluster
        execute_emr_eks_script "$cluster_name"
    done

    # Setup RDS Proxy
    execute_rds_proxy_script

    log "Process completed successfully"
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
command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check required environment variables
[[ -z "${AWS_REGION:-}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

## Check if Docker is running
if ! docker info &> /dev/null; then
    echo "Error: Docker is not running. Please start Docker and try again."
    exit 1
fi
echo "Docker is running. Proceeding with further operations..."

# Call Main 
main
