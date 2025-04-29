#!/bin/bash
set -euo pipefail

# =====================================================================================
# This script configures the Airflow connection for BPG.
# 
# Key functionalities include:
# - Get MWAA Environment Details
# - Get BPG Service Endpoint
# - Create / Update Connection
# =====================================================================================

# Constants
MAIN_STACK_NAME="MWAABPGSparkMainStack"

# MWAA Instance Name
MWAA_INSTANCE_NAME="airflow-environment"
BPG_CONN_ID="bpg_connection"

# Global Variables

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check Dependencies
check_dependencies() {
    command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { log "kubectl is required but it's not installed. Aborting."; exit 1; }
    command -v jq >/dev/null 2>&1 || { log "jq is required but it's not installed. Aborting."; exit 1; }
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

# Function to get MWAA environment details
get_mwaa_environment() {
    log "Getting MWAA environment details..."
    
    MWAA_ENV_DETAILS=$(aws mwaa get-environment --name "${MWAA_INSTANCE_NAME}")
    MWAA_WEBSERVER_HOSTNAME=$(echo "${MWAA_ENV_DETAILS}" | jq -r '.Environment.WebserverUrl' | sed 's/https:\/\///')
    
    if [ -z "$MWAA_WEBSERVER_HOSTNAME" ]; then
        log "Error: Could not get MWAA webserver hostname"
        exit 1
    fi
    
    log "MWAA webserver hostname: $MWAA_WEBSERVER_HOSTNAME"
}

# Function to get BPG service endpoint
get_bpg_service_endpoint() {
    log "Getting BPG service endpoint..."
    BPG_ENDPOINT=$(kubectl get svc bpg-elb-svc -n bpg -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
    
    if [ -z "$BPG_ENDPOINT" ]; then
        log "Error: Could not get BPG service endpoint"
        exit 1
    fi
    
    log "BPG endpoint: $BPG_ENDPOINT"
}

# Function to create or update BPG connection
create_bpg_connection() {
    local conn_id=$1
    local host=$2

    local cli_token=$(aws mwaa create-cli-token --name "${MWAA_INSTANCE_NAME}" | jq -r '.CliToken')
        
    log "Creating/Updating BPG connection: ${conn_id}"
    
    # Delete existing connection if it exists
    curl --request POST "https://${MWAA_WEBSERVER_HOSTNAME}/aws_mwaa/cli" \
        --header "Authorization: Bearer ${cli_token}" \
        --header "Content-Type: text/plain" \
        --data-raw "connections delete ${conn_id}" || true
    
    # Create new connection
    curl --request POST "https://${MWAA_WEBSERVER_HOSTNAME}/aws_mwaa/cli" \
        --header "Authorization: Bearer ${cli_token}" \
        --header "Content-Type: text/plain" \
        --data-raw "connections add ${BPG_CONN_ID} --conn-type 'http' --conn-host 'http://${host}' --conn-port '80' --conn-schema 'http'"
        
    log "Successfully created BPG connection"
}

# Main function
main() {
    log "Configuring BPG operator for MWAA environment: $MWAA_INSTANCE_NAME"

    # Get MWAA environment details
    get_mwaa_environment

    # Get BPG service endpoint
    get_bpg_service_endpoint
    
    # Create BPG connection
    create_bpg_connection "${BPG_CONN_ID}" "${BPG_ENDPOINT}"
    
    
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
