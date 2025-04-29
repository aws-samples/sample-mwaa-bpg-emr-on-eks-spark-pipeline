#!/bin/bash
set -euo pipefail

# =============================================================================
# RDS Cluster to DB Proxy Association Script
#
# This script associates an Amazon RDS cluster with an existing DB Proxy 
# Target Group and configures the connection pool settings. It is designed 
# to be used as part of a deployment process for a bpg database 
# setup.
#
# =============================================================================

# Script Variables
MAIN_STACK_NAME="MWAABPGSparkMainStack"

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Usage
usage() {
    echo "Usage: $(basename "$0") MAIN_STACK_NAME"
    echo "# This script associates an RDS cluster with an existing DB Proxy Target Group and"
    echo "# configures the connection pool settings."
    echo
    echo "Required environment variables:"
    echo "  AWS_REGION    The AWS region to deploy resources"
    echo
    echo "Example:"
    echo "  export AWS_REGION=us-west-2"
    echo "  $(basename "$0") MWAABPGSparkMainStack"
    exit 1
}

create_db_proxy_target_group() {
    # Get RDS Cluster Identifier from CloudFormation stack
    local db_cluster_identifier=$(aws cloudformation describe-stacks \
        --stack-name "${MAIN_STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`RDSClusterIdentifier`].OutputValue' \
        --output text)

    # Get RDS Proxy name from CloudFormation stack
    local db_proxy_name=$(aws cloudformation describe-stacks \
        --stack-name "${MAIN_STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`RDSProxyName`].OutputValue' \
        --output text)

    # Register DB proxy targets
    if ! aws rds register-db-proxy-targets \
        --db-proxy-name "$db_proxy_name" \
        --target-group-name "default" \
        --db-cluster-identifiers "$db_cluster_identifier"
    then
        log "Failed to associate RDS cluster with DB Proxy Target Group"
        exit 1
    fi

    log "Successfully associated RDS cluster with DB Proxy Target Group"
}

# Main function
main() {
    log "RDS to Proxy association started..."

    create_db_proxy_target_group

    log "RDS to Proxy association completed successfully"
}

##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##
# Start the main function with all the provided arguments
##.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.-.~.##

# Check for correct number of arguments
# Check for help flag or any arguments
if [ $# -ne 0 ] || { [ $# -gt 0 ] && { [ "$1" = "-h" ] || [ "$1" = "--help" ]; }; }; then
    usage
fi

# Check for required tools
command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }

# No AWS CLI Output Paginated Output
export AWS_PAGER=""

# Check for required environment variables
[[ -z "${AWS_REGION}" ]] && { log "Error: AWS_REGION is not set." >&2; exit 1; }
log "AWS Region: $AWS_REGION"

# Check for required positional arguments
if [ $# -gt 0 ]; then
    MAIN_STACK_NAME="$1"
fi

# Call Main 
main