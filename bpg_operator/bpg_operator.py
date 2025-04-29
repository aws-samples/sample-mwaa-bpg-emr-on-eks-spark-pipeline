import json
import yaml
import requests
import os
import time
import boto3
import re
from requests.auth import HTTPBasicAuth
from airflow.models import BaseOperator
from airflow.hooks.base import BaseHook
from airflow.utils.decorators import apply_defaults
from airflow.configuration import conf
from botocore.exceptions import NoCredentialsError, ClientError

class BPGOperator(BaseOperator):

    BPG_JOB_ENDPOINT = '/skatev2/spark'
    BPG_LOG_ENDPOINT ='/skatev2/log'

    @apply_defaults
    def __init__(self, 
                 application_file: str | None = None, 
                 application_content: str | None = None,
                 application_timeout: int = 3600, # Default to 1 hour
                 log_poll_interval: int = 1,  # Polling every 1 seconds by default
                 connection_id: str | None = None, 
                 *args, **kwargs):
        """
        BPGOperator to send YAML/JSON files to Batch Processing Gateway using Airflow HTTP connection.

        :param application_file: Path to the file (YAML or JSON)
        :param application_content: Inline YAML/JSON content provided directly in the DAG file
        :param connection_id: Airflow Connection ID to retrieve the URL and credentials
        :param poll_interval: Time in seconds to wait between job status checks
        :param application_timeout: Timeout in seconds for the job to complete
        """
        super(BPGOperator, self).__init__(*args, **kwargs)
        self.application_file = application_file
        self.application_content = application_content
        self.connection_id = connection_id
        self.log_poll_interval = log_poll_interval
        self.application_timeout = application_timeout
        
        if application_file:
            self.log.info(f"Using application file: {application_file}")
        if application_content:
            self.log.debug("Using inline application content")

    def execute(self, context):
        if self.application_content:
            file_content = self.application_content
        elif self.application_file:

            file_content = self._fetch_from_s3() if self._is_mwaa() else self._fetch_from_local()
        else:
            raise ValueError("Either 'application_file' or 'application_content' must be provided.")
        
        # Get connection details
        conn = BaseHook.get_connection(self.connection_id)
        url = conn.host
        login, password = self.get_credentials(conn)

        # Send job request
        submission_id = self._submit_job(url, login, password, file_content, context)

        # Poll for job status
        self._poll_job_status(url, submission_id, login, password)

    def _is_mwaa(self):
        """Detects if running in MWAA by checking if AIRFLOW_HOME points to `/usr/local/airflow`."""
        return os.environ.get("AIRFLOW_HOME", "").startswith("/usr/local/airflow")

    def _fetch_from_s3(self):
        """Fetches the application file from S3 (for MWAA)."""
        try:
            if self.application_file.startswith("s3://"):
                s3_uri = self.application_file
            else:
                # Assume relative path inside MWAA S3 bucket
                mwaa_bucket = os.environ.get("MWAA_DAGS_BUCKET", "mwaa-defalt-bucket-name")
                s3_uri = f"s3://{mwaa_bucket}/dags/{self.application_file}"

            self.log.info(f"Fetching application file from S3: {s3_uri}")
            return self._read_application_file_from_s3(s3_uri)
        except Exception as e:
            self.log.error(f"Error fetching file from S3: {e}")
            raise
    
    def _fetch_from_local(self):
        """Fetches the application file from the local filesystem (for standard Airflow)."""
        if not os.path.isfile(self.application_file):
            raise FileNotFoundError(f"Application file not found: {self.application_file}")

        with open(self.application_file, "r", encoding="utf-8") as f:
            content = f.read()

        return content
    
    def _read_application_file_from_s3(self, s3_uri):
        """Fetches YAML/JSON file from S3."""
        match = re.match(r"s3://([^/]+)/(.+)", s3_uri)
        if not match:
            raise ValueError(f"Invalid S3 URI: {s3_uri}")

        s3_bucket, s3_key = match.groups()
        s3 = boto3.client("s3")

        try:
            response = s3.get_object(Bucket=s3_bucket, Key=s3_key)
            content = response["Body"].read().decode("utf-8")
            return content

        except NoCredentialsError:
            raise Exception("AWS credentials not found. Ensure MWAA has permissions to access S3.")
        except ClientError as e:
            raise Exception(f"Error fetching file from S3: {e}")
        
    def _detect_file_type(self, file_path):
        """Detects file type based on extension (YAML/JSON)."""
        if file_path.endswith(".yaml") or file_path.endswith(".yml"):
            return "yaml"
        elif file_path.endswith(".json"):
            return "json"
        else:
            raise ValueError(f"Unsupported file extension for file {file_path}. Supported extensions are .yaml, .yml, .json.")
    
    def _get_content_type(self):
        """Detect the content type based on file extension or inline content."""
        
        if self.application_file:
            file_type = self._detect_file_type(self.application_file)
            self.log.info(f"Detected file type from extension: {file_type}")
        elif self.application_content:
            try:
                json.loads(self.application_content)
                return 'application/json'
            except json.JSONDecodeError:
                try:
                    yaml.safe_load(self.application_content)
                    # Additional check since valid JSON is also valid YAML
                    # If we reach here and it was valid JSON, it would have been caught above
                    return 'application/yaml'
                except Exception as e:
                    self.log.error(f"Error detecting content type: {e}")
                    raise                
            except Exception as e:
                self.log.error(f"Error detecting content type: {e}")
                return 'application/plain'
        

    def _submit_job(self, url, login, password, payload, context):
        """Submit the job and return the submission ID."""
        headers = self._get_headers()

        self.log.info("Preparing to submit Spark job")
        self.log.debug(f"Submission URL: {url}{self.BPG_JOB_ENDPOINT}")
        self.log.debug(f"Headers: {headers}")
        
        try:
            response = requests.post(
                f"{url}{self.BPG_JOB_ENDPOINT}",
                data=payload, headers=headers,
                auth=HTTPBasicAuth(login, password),
                timeout=(5, 30)
            )
            response.raise_for_status()  # Check for HTTP errors

            # Parse the response to get the submission ID
            json_response = response.json()
            submission_id = json_response.get('submissionId')
            self.log.info(f"Spark Job submitted successfully. Submission ID: {submission_id}")
            self.log.debug(f"Full response: {json_response}")

            # Push the submission ID to XCom for future tasks to access
            self.xcom_push(context=context, key='submission_id', value=submission_id)
            return submission_id

        except requests.exceptions.Timeout:
            self.log.error("Job submission timed out")
            raise
        except requests.exceptions.RequestException as e:
            self.log.error(f"HTTP error during job submission: {str(e)}")
            raise
        except Exception as e:
            self.log.error(f"Unexpected error during job submission: {str(e)}")
            raise

    def _poll_job_status(self, url, submission_id, login, password):
        """Poll job status and handle logs."""
        headers = self._get_headers()
        start_time = time.time()
        last_status = None

        while True:
            try:
                elapsed_time = time.time() - start_time

                # Check if we've exceeded the timeout
                if time.time() - start_time > self.application_timeout:
                    raise TimeoutError(f"Job execution exceeded timeout of {self.application_timeout} seconds")

                # Check job status
                response = requests.get(
                    f"{url}{self.BPG_JOB_ENDPOINT}/{submission_id}/status",
                    headers=headers,
                    auth=HTTPBasicAuth(login, password),
                    timeout=(5, 10)
                )

                response.raise_for_status()  # Check for HTTP errors

                status = response.json().get('applicationState')

                # Log status changes or periodic updates
                if status != last_status:
                    if status == "PENDING":
                        self.log.info(f"Job pending initialization. Elapsed time: {int(elapsed_time)}s. Submission ID: {submission_id}")
                    elif status == "SUBMITTED":
                        self.log.info(f"Job submitted and queued. Elapsed time: {int(elapsed_time)}s. Submission ID: {submission_id}")
                    elif status == "UNKNOWN":
                        self.log.warning(f"Job status unknown. Elapsed time: {int(elapsed_time)}s. Submission ID: {submission_id}")
                    elif status == "RUNNING":
                        self.log.info(f"Job is running. Elapsed time: {int(elapsed_time)}s. Retrieving logs...")
                        self._fetch_logs(url, submission_id, login, password)
                    elif status == "FAILED":
                        self.log.error(f"Job failed after {int(elapsed_time)}s. Submission ID: {submission_id}")
                        raise Exception("Job failed")
                    elif status == "COMPLETED":
                        self.log.info(f"Job completed successfully after {int(elapsed_time)}s. Submission ID: {submission_id}")
                        return
                    
                    last_status = status

            except TimeoutError as te:
                self.log.error(str(te))
                raise
            except Exception as e:
                self.log.error(f"Failed to check job status: {str(e)}")
                raise e

            time.sleep(self.log_poll_interval)

    def _fetch_logs(self, url, submission_id, login, password):
        """Fetch and log job logs."""
        try:
            log_url = f"{url}{self.BPG_LOG_ENDPOINT}?subId={submission_id}"
            self.log.info(f"Fetching logs for Submission ID: {submission_id}")
            self.log.debug(f"Log URL: {log_url}")    
            log_url = f"{url}{self.BPG_LOG_ENDPOINT}?subId={submission_id}"
            log_response = requests.get(
                log_url, stream=True, 
                headers=self._get_headers(), auth=HTTPBasicAuth(login, password), timeout=(5, None))
            log_response.raise_for_status()

            self.log.info(f"Fetching logs for Submission ID: {submission_id}")
            for line in log_response.iter_lines():
                if line:
                    decoded_line = line.decode('utf-8')
                    # Categorize log levels if possible
                    if 'ERROR' in decoded_line:
                        self.log.error(f"{decoded_line}")
                    elif 'WARN' in decoded_line:
                        self.log.warning(f"{decoded_line}")
                    else:
                        self.log.info(f"{decoded_line}")

        except requests.exceptions.Timeout:
            self.log.error(f"Timeout while fetching logs for submission {submission_id}")
        except requests.exceptions.RequestException as e:
            self.log.error(f"HTTP error while fetching logs: {str(e)}")
        except Exception as e:
            self.log.error(f"Unexpected error while fetching logs: {str(e)}")

    def get_credentials(self, conn):
        """Retrieve HTTP credentials from the Airflow connection or use default credentials if not provided."""
        login = conn.login or 'admin'
        password = conn.password or 'password'
        if not conn.login or not conn.password:
            self.log.warning("No login/password found in connection, using default credentials. "
                        "This is not recommended for production environments.")
        else:
            self.log.info("Using credentials from Airflow connection")

        return login, password

    def _get_headers(self):
        """Return appropriate headers based on the file type."""
        return {'Content-Type': self._get_content_type()}