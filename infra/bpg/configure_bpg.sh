#!/bin/bash
set -euo pipefail

# =====================================================================================
# This script automates the process of creating an Amazon Elastic Container Registry (ECR) repository,
# building a Docker image for the Batch Processing Gateway(BPG), pushing the image to ECR, and deploying a Helm chart.
# 
# Key functionalities include:
# - Setting the AWS region and fetching the AWS account ID.
# - Logging into ECR for Docker image uploads.
# - Checking if the ECR repository exists, and creating it if it doesn't.
# - Building the Docker image and pushing it to the specified ECR repository.
# - Packaging and pushing a Helm chart to ECR.
# =====================================================================================

# Constants
ECR_REPO_NAME="bpg"
IMAGE_TAG="latest"
DOCKERFILE_PATH="./Dockerfile"
CHART_PATH="./chart"
RDS_SECRET_NAME="/aurora/bpg/db-secret"
MAIN_STACK_NAME="MWAABPGSparkMainStack"
PROJECT_NAME="MWAA-BPG-Spark-Pipeline"

# EKS Cluster
GATEWAY_CLUSTER_NAME="gateway-cluster"
DATA_PROCESSING_CLUSTERS=(
    "analytics-cluster"
    "datascience-cluster"
)

# Global Variables
AWS_ACCOUNT_ID=""
RDS_PROXY_ENDPOINT=""
RDS_DB_PASSWORD=""

# Logging
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Check Dependencies
check_dependencies() {
    command -v aws >/dev/null 2>&1 || { log "AWS CLI is required but it's not installed. Aborting."; exit 1; }
    command -v docker >/dev/null 2>&1 || { log "Docker is required but it's not installed. Aborting."; exit 1; }
    command -v helm >/dev/null 2>&1 || { log "Helm is required but it's not installed. Aborting."; exit 1; }
    command -v git >/dev/null 2>&1 || { log "git is required but it's not installed. Aborting."; exit 1; }
    command -v eksctl >/dev/null 2>&1 || { log "eksctl is required but it's not installed. Aborting."; exit 1; }
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

# Get Account Id
get_account_id() {
    AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
    log "AWS Account ID: $AWS_ACCOUNT_ID"
}

# Login to ECR
login_to_ecr() {
    log "Logging into ECR..."
    aws ecr get-login-password | docker login --username AWS --password-stdin "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"
}

# Get Subnet IDs
get_subnet_ids() {
    SUBNETS=$(aws ec2 describe-subnets --filters "Name=tag:Name,Values=*${PROJECT_NAME} Private*" --query "Subnets[*].SubnetId" --output text | tr '\t' ',')
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
    
    log "Successfully connected to cluster: $cluster_name"
}

# Get the RDS proxy endpoint
get_rds_proxy_endpoint() {
    # Get RDS Proxy name from CloudFormation stack and return endpoint
    local rds_endpoint=$(aws cloudformation describe-stacks \
        --stack-name "${MAIN_STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`RDSProxyEndpoint`].OutputValue' \
        --output text)
    
    echo "$rds_endpoint"
}

# Get the RDS password
get_rds_password() {
    # BPG DB Password
    local rds_secret_value=$(aws secretsmanager get-secret-value --secret-id "${RDS_SECRET_NAME}" --query "SecretString" --output text)

    # Return password
    echo "$(echo "$rds_secret_value" | jq -r '.password')"
}

# Get BPG Source and patch the config
get_bpg_source() {
    local repo_dir="batch-processing-gateway"
    local bpg_repo_url="https://github.com/apple/batch-processing-gateway.git"
    local stable="aa3e5c8be973bee54ac700ada963667e5913c865"

    
    if [ ! -d "$repo_dir" ] ; then
        log "Cloning BPG repository..."
        git clone "$bpg_repo_url" "$repo_dir"
    fi
    log "Cloning BPG repository is complete"
    cd "$repo_dir"
    # Pin specific git commit
    git checkout "$stable"
    cd ..

    # Patch Dockerfile
    log "Patching Dockerfile..."
    cp patch/Dockerfile "$repo_dir/Dockerfile"
    cp patch/LogDao.java "$repo_dir/src/main/java/com/apple/spark/core/LogDao.java"
    cp patch/pom.xml "$repo_dir/pom.xml"
}

# Build and push Docker image to ECR
build_and_push_image() {
    local ecr_repo_name="$1"
    local image_tag="$2"
    local dockerfile_path="$3"

    cd batch-processing-gateway
    # Patch Dockerfile
    log "Building Docker image..."
    docker build -t "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ecr_repo_name:$image_tag" \
    --platform linux/amd64 -f "$dockerfile_path" .

    log "Pushing Docker image to ECR..."
    docker push "$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/$ecr_repo_name:$image_tag"
    cd ..
}

# Install AWS Load Balancer Controller using Helm
deploy_aws_load_balancer_controller() {
  log "ALB deployment is initiated ..."
  local policy_name="AWSLoadBalancerControllerIAMPolicy-${PROJECT_NAME}"

  # Create AWSLoadBalancerControllerIAMPolicy
  # Check if policy exists
  local existing_policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='${policy_name}'].Arn" --output text)

  if [ -z "$existing_policy_arn" ]; then
      log "Policy ${policy_name} does not exist. Creating..."
      # Download iam_policy.json
      curl -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.12.0/docs/install/iam_policy.json

      # Create Policy
      aws_lb_controller_policy_arn=$(aws iam create-policy \
          --policy-name "${policy_name}" \
          --policy-document file://iam_policy.json \
          --query 'Policy.Arn' \
          --output text)
  else
      aws_lb_controller_policy_arn="$existing_policy_arn"
  fi
  
  eksctl create iamserviceaccount \
    --cluster="${GATEWAY_CLUSTER_NAME}" \
    --namespace=kube-system \
    --name=aws-load-balancer-controller \
    --attach-policy-arn=arn:aws:iam::"${AWS_ACCOUNT_ID}":policy/"${policy_name}" \
    --override-existing-serviceaccounts \
    --region "${AWS_REGION}" \
    --approve

  # Configure Helm repo
  helm repo add eks https://aws.github.io/eks-charts || true
  helm repo update eks

  local vpc_id=$(aws eks describe-cluster --name "$GATEWAY_CLUSTER_NAME" --query 'cluster.resourcesVpcConfig.vpcId' --output text)

  # Install CRDs 
  kubectl apply -f aws_lbc_crds.yaml

  # Install aws-load-balancer-controller chart
  helm upgrade --install --wait aws-load-balancer-controller eks/aws-load-balancer-controller \
    --namespace kube-system \
    --set clusterName="$GATEWAY_CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="aws-load-balancer-controller" \
    --set vpcId="$vpc_id" \
    --set region="$AWS_REGION"

  log "ALB deployment is completed."
}

# Generate configs
generate_bpg_config_yaml() {
  local rds_proxy_endpoint=$(get_rds_proxy_endpoint)
  local rds_db_password=$(get_rds_password)
  local db_user=bpg
  local db_name=bpg

# Start YAML content
cat > bpg-config-generated.yaml <<EOF
plainConfig:
  defaultSparkConf:
    spark.kubernetes.submission.connectionTimeout: 30000
    spark.kubernetes.submission.requestTimeout: 30000
    spark.kubernetes.driver.connectionTimeout: 30000
    spark.kubernetes.driver.requestTimeout: 30000
  sparkClusters:
EOF

# Loop through each cluster and generate configuration
for cluster_name in "${DATA_PROCESSING_CLUSTERS[@]}"; do
    setup_kubectl_context "$cluster_name"
    # Get EMR Cluster ARN
    eksClusterArn=$(aws eks describe-cluster --name "$cluster_name" --query "cluster.arn" --output text)
  
    # Retrieve the master URL for the current cluster context
    serverUrl=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
  
    # Get the secret name associated with the Spark Operator service account
    saSecret=$(kubectl -n spark-operator get sa/emr-containers-sa-spark-operator -o json | jq -r '.secrets[] | .name')
  
    # Retrieve the CA certificate data from the secret
    caCertDataSOPS=$(kubectl -n spark-operator get secret/"$saSecret" -o json | jq -r '.data."ca.crt"')
  
    # Retrieve the token name associated with the Spark Operator service account
    saToken=$(kubectl get -n spark-operator serviceaccount/emr-containers-sa-spark-operator -o jsonpath='{.secrets[0].name}')
  
    # Decode the user token from the secret
    userTokenSOPS=$(kubectl get -n spark-operator secret "$saToken" -o jsonpath='{.data.token}' | base64 --decode)

    cat >> bpg-config-generated.yaml <<EOF
    - weight: 100
      id: ${cluster_name//[-]/}
      eksCluster: ${eksClusterArn}
      masterUrl: ${serverUrl}
      caCertDataSOPS: ${caCertDataSOPS}
      userTokenSOPS: ${userTokenSOPS}
      sparkApplicationNamespace: emr
      sparkServiceAccount: emr-containers-sa-spark
      sparkVersions:
        - 3.5
        - 3.5.0
        - 3.5.2
      queues:
        - dev
      ttlSeconds: 86400
      timeoutMillis: 180000
      sparkUIUrl: http://localhost:8080
      sparkConf:
        spark.kubernetes.executor.podNamePrefix: '{spark-application-resource-name}'
        spark.eventLog.enabled: "false"
        spark.kubernetes.allocation.batch.size: 2000
        spark.kubernetes.allocation.batch.delay: 1s
EOF
done

# Append remaining static configuration
cat >> bpg-config-generated.yaml <<EOF
  sparkImages:
    - name: public.ecr.aws/emr-on-eks/spark/emr-7.5.0:latest
      types:
        - Java
        - Scala
        - python
      version: "3.5"
  allowedUsers:
    - '*'
  queues:
    - name: dev
  maxRunningMillis: 21600000
  dbStorageSOPS:
    connectionString: jdbc:mysql://${rds_proxy_endpoint}:3306/${db_name}?useUnicode=yes&characterEncoding=UTF-8&useLegacyDatetimeCode=false&connectTimeout=10000&socketTimeout=30000
    user: ${db_user}
    password: ${rds_db_password}
  statusCacheExpireMillis: 9000
  server:
    applicationConnectors:
      - type: http
        port: 8080
  logging:
    level: INFO
    loggers:
      com.apple.spark: INFO
EOF

echo "Configuration file 'bpg-config-generated.yaml' generated successfully!"

}

# Push Helm chart to ECR
push_helm_chart() {
    local chart_path="$1"
    local chart_url="oci://$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com"

    log "Packaging Helm chart..."
    helm package "$chart_path" --destination ./charts

    log "Pushing Helm chart to ECR..."
    helm push "$(ls ./charts/*.tgz)" "$chart_url"
}

deploy_bpg_helm() {
    log "Deploying BPG Helm chart..."
    helm uninstall bpg --namespace bpg || true
    helm upgrade --install bpg --namespace bpg batch-processing-gateway/helm/batch-processing-gateway \
        --create-namespace \
        --set image.registry="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com" \
        --set image.repository=bpg \
        --set image.tag=latest \
        --set replicas=1 \
        -f bpg-config-generated.yaml
    
    rm bpg-config-generated.yaml

    log "Successfully deployed BPG Helm chart"
}

# Expose metastore using Kubernetes service of type LoadBalancer and AWS NLB
expose_svc_via_aws_nlb(){

    local template_file="./bpg-elb-svc.tpl"
    local output_file="./bpg-elb-svc.yaml"

    # Process template while preserving quotes
    while IFS= read -r line; do
        # Escape existing double quotes in the line
        escaped_line="${line//\"/\\\"}"
        eval "printf '%s\n' \"$escaped_line\"" 
    done < "$template_file" > "$output_file"

    if [ ! -f "$output_file" ]; then
        echo "Error: Failed to generate manifest file"
        return 1
    fi
    log "Generated Spark Job manifest: $output_file"

    # Create service object
    kubectl apply -f "$output_file"
}

# Main function
main() {
    log "Setting up BPG on EKS cluster: $GATEWAY_CLUSTER_NAME"

    # Setup
    get_account_id
    login_to_ecr

    # ECR Image Setup
    get_bpg_source
    build_and_push_image "$ECR_REPO_NAME" "$IMAGE_TAG" "$DOCKERFILE_PATH"

    # Generate Config
    generate_bpg_config_yaml

    # Deploy Helm Chart on gateway-cluster
    setup_kubectl_context "$GATEWAY_CLUSTER_NAME"
    # Deploy AWS Load Balancer Controller
    #deploy_aws_load_balancer_controller
    deploy_bpg_helm
    get_subnet_ids
    expose_svc_via_aws_nlb

    log "Successfully deployed BPG on EKS cluster: $GATEWAY_CLUSTER_NAME"
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