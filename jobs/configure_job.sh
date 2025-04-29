#!/bin/bash
set -euo pipefail

# =====================================================================================
# This script configures example DAG files in the Airflow environment.
# 
# Key functionalities include:
# - Get DAGs location from MWAA Environment
# - Upload DAG files
# =====================================================================================

# Constants
MAIN_STACK_NAME="MWAABPGSparkMainStack"

# MWAA Instance Name
MWAA_INSTANCE_NAME="airflow-environment"
PLUGINS_S3_PREFIX="plugins"
REQUIREMENTS_S3_PREFIX="requirements"

# Global Variables
AWS_ACCOUNT_ID=""
MWAA_S3_BUCKET=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check Dependencies
check_dependencies() {
    command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }
}

# Usage
usage() {
    echo "Usage: $(basename "$0") CLUSTER_NAME"
    echo "This script sets up Amazon EMR on EKS cluster with Spark Operator."
    echo
    echo "CLUSTER_NAME must be one of:"
    echo "  datascience-cluster"
    echo "  analytics-cluster"
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to deploy resources"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  $(basename "$0") datascience-cluster"
    exit 1
}


# Get MWAA Environment Details
get_mwaa_environment() {
    log "Getting MWAA environment details..."
    local mwaa_env=$(aws mwaa get-environment \
        --name "$MWAA_INSTANCE_NAME" \
        --query "Environment.[DagS3Path,SourceBucketArn]" \
        --output text)
    
    if [ -z "$mwaa_env" ]; then
        log "Error: MWAA environment not found"
        exit 1
    fi
    
    MWAA_S3_BUCKET=$(echo "$mwaa_env" | cut -f2 -d' ' | cut -d':' -f6)
    MWAA_EXECUTION_ROLE=$(echo "$mwaa_env" | cut -f2 -d' ')
    
    log "MWAA S3 Bucket: $MWAA_S3_BUCKET"
    
}

# Package and upload plugins
upload_app() {
    log "Upload sample app and dag file"
        
    # Upload to S3
    aws s3 cp demo_dag.py  "s3://${MWAA_S3_BUCKET}/dags/"
    
    log "Successfully uploaded sample app and dag file"
}


# Main function
main() {
    log "Configuring BPG operator for MWAA environment: $MWAA_INSTANCE_NAME"

    # Get MWAA environment details
    get_mwaa_environment
    
    # Upload sample app & dag files
    upload_app
    
    
    log "Successfully configured BPG operator for MWAA environment: $MWAA_INSTANCE_NAME"
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

# Check for required environment variables
[[ -z "${AWS_REGION}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

# Call Main 
main
