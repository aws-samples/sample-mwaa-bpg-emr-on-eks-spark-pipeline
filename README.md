# Building End-to-End Apache Spark Pipelines with Amazon MWAA, Batch Processing Gateway, and Multi-Cluster EMR on EKS

Data platforms processing large-scale data volumes often require multiple EMR on EKS clusters. In our previous post [Use Batch Processing Gateway to automate job management in multi-cluster Amazon EMR on EKS environments](https://aws.amazon.com/blogs/big-data/use-batch-processing-gateway-to-automate-job-management-in-multi-cluster-amazon-emr-on-eks-environments/), we introduced the use of [Batch Processing Gateway (BPG)](https://github.com/apple/batch-processing-gateway) as a solution for managing Apache Spark workloads across these clusters. While BPG provides foundational functionality to distribute workloads and support load balancing for Apache Spark jobs in multi-cluster environments, enterprise data platforms require additional features for a comprehensive data processing pipeline.

This repository and the associated blog post [Building End-to-End Apache Spark Pipelines with Amazon MWAA, Batch Processing Gateway, and Multi-Cluster EMR on EKS](https://aws.amazon.com/blogs/big-data/building-end-to-end-apache-spark-pipelines-with-amazon-mwaa-batch-processing-gateway-and-multi-cluster-emr-on-eks/) shows how to enhance our previously discussed multi-cluster solution by integrating Amazon Managed Workflows for Apache Airflow (MWAA) with BPG. By leveraging MWAA, we add job scheduling and orchestration capabilities, enabling you to build a comprehensive end-to-end Apache Spark based data processing pipeline.

## Solution Overview

Our solution consists of integrating MWAA with BPG through a Airflow custom operator for BPG called BPGOperator. This operator encapsulates the infrastructure management logic needed to interact with BPG, which handles the routing and distribution of Apache Spark jobs across multiple EMR on EKS clusters. The BPGOperator provides a clean interface for job submission through MWAA. When executed, the operator communicates with BPG, which then intelligently routes the Spark workloads to available EMR on EKS clusters based on predefined load balancing rules.

The architecture diagram below illustrates the components and their interactions.

![Alt text](images/architecture.png)

The solution works through the following steps:
- MWAA executes scheduled DAGs using the `BPGOperator`. Data engineers create DAGs using this operator, requiring only the Spark application configuration file and basic scheduling parameters.
- The `BPGOperator` authenticates and submits jobs to BPG submit endpoint `POST:/apiv2/spark`. It handles all HTTP communication details, manages authentication tokens, and ensures secure transmission of job configurations.
- BPG routes submitted jobs to EMR on EKS clusters based on predefined routing rules. These routing rules are managed centrally through BPG configuration, allowing rules-based distribution of workloads across multiple clusters.
- The `BPGOperator` monitors job status, captures logs and handles execution retries. It polls BPG job status endpoint `GET:/apiv2/spark/{subID}/status` and streams logs to Airflow by polling `GET:/apiv2/log` endpoint every second. The BPG Log endpoint retrieves most current log information directly from the Spark Driver Pod.
- DAG execution progresses to subsequent tasks based on job completion status and defined dependencies. The BPGOperator communicates job status through Airflow's native task communication system, enabling complex workflow orchestration.


## Prerequisites

Before deploying this solution, ensure the following prerequisites are in place:
-	Access to a valid [AWS account](https://signin.aws.amazon.com/signin?redirect_uri=https%3A%2F%2Fportal.aws.amazon.com%2Fbilling%2Fsignup%2Fresume&client_id=signup)
- The [AWS Command Line Interface](http://aws.amazon.com/cli) (AWS CLI) [installed](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) on your local machine 
- [```git```](https://github.com/git-guides/install-git)
, [```docker```](https://docs.docker.com/engine/install/), [```eksctl```](https://docs.aws.amazon.com/eks/latest/userguide/eksctl.html),[```kubectl```](https://docs.aws.amazon.com/eks/latest/userguide/install-kubectl.html), [```helm```](https://helm.sh/docs/intro/install/), [```jq```](https://jqlang.github.io/jq/) and [```yq```](https://mikefarah.gitbook.io/yq) installed on your local machine
-	Permission to create AWS resources
- Familiarity with [Kubernetes](https://kubernetes.io/), [Amazon EKS](https://aws.amazon.com/eks/), and [Amazon EMR on EKS](https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/emr-eks.html)

## Deploy the solution

- Clone the repository to your local machine and set the two environment variables. Replace `<AWS_REGION>` with the AWS Region where you want to deploy these resources. 

```
git clone git@ssh.gitlab.aws.dev:avidesir/mwaa-bpg-spark-pipeline-blog.git
cd mwaa-bpg-spark-pipeline-blog
export REPO_DIR=$(pwd)
export AWS_REGION=<AWS_REGION>
```

- Execute the following script to create the common infrastructure. 
```
cd ${REPO_DIR}/infra 
./setup.sh 
```

- Deploy BPG on `gateway-cluster` EKS cluster
```
cd ${REPO_DIR}/infra/bpg 
./configure_bpg.sh 
```

- Configure BPGOperator on MWAA
```
cd $REPO_DIR/bpg_operator
./configure_bpg_operator.sh
```

- Configure Airflow Connections for BPG Integration
```
cd $REPO_DIR/airflow
./configure_connections.sh
```

- Configure Airflow DAG to execute Spark jobs
```
cd $REPO_DIR/jobs
./configure_job.sh
```

- Trigger the Amazon MWAA DAG

![Alt text](images/mwaa_dag_summary.png)

- Review the logs of individuals tasks to verify the successful population of the Apache Spark logs into Airflow UI. 
- Cleaning up
```
cd ${REPO_DIR}/setup
./cleanup.sh
```

## Contributing

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

See the [LICENSE](/LICENSE) for more information.

## Disclaimer

This solution deploys the Open Source softwares including [Batch Processing Gateway (BPG)](https://github.com/apple/batch-processing-gateway) in the AWS cloud. AWS makes no claims regarding security properties of any Open Source Softwares. Please evaluate all Open Source Softwares including BPG according to your organization's security best practices before implementing the solution.

