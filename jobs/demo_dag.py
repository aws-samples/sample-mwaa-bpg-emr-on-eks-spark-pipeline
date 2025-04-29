from airflow import DAG
from airflow.utils.dates import days_ago
from bpg_operator import BPGOperator
from airflow.operators.dummy_operator import DummyOperator

with DAG(
    'MWAASparkPipelineDemoJob',
    default_args={'owner': 'avidesir', 'start_date': days_ago(1)},
    schedule_interval=None,
    description='A multi-step Spark workflow'
) as dag:
    
    # Start task
    start = DummyOperator(task_id='start')
    
    # Pi calculation task
    calculate_pi = BPGOperator(
        task_id='calculate_pi',
        application_content='''{
            "applicationName": "SparkPiCalculation",
            "type": "Scala",
            "queue": "dev",
            "sparkVersion": "3.5",
            "mainApplicationFile": "local:///usr/lib/spark/examples/jars/spark-examples.jar",
            "mainClass":"org.apache.spark.examples.SparkPi",
            "driver": {
                "cores": 1,
                "memory": "2g",
                "serviceAccount": "emr-containers-sa-spark"
            },
            "executor": {
                "instances": 1,
                "cores": 1,
                "memory": "2g"
            }
        }''',
        connection_id='bpg_connection'
    )
    
    # Word count example
    word_count = BPGOperator(
        task_id='word_count',
        application_content='''{
            "applicationName": "SparkWordCount",
            "type": "Scala",
            "queue": "dev",
            "sparkVersion": "3.5",
            "mainApplicationFile": "local:///usr/lib/spark/examples/jars/spark-examples.jar",
            "mainClass":"org.apache.spark.examples.JavaWordCount",
            "arguments": ["file:///usr/lib/spark/examples/src/main/resources/people.txt", "file:///tmp/wordcount_output"],
            "driver": {
                "cores": 1,
                "memory": "2g",
                "serviceAccount": "emr-containers-sa-spark"
            },
            "executor": {
                "instances": 1,
                "cores": 1,
                "memory": "2g"
            }
        }''',
        connection_id='bpg_connection'
    )
    
    # Statistics calculation
    statistics_calc = BPGOperator(
        task_id='statistics_calc',
        application_content='''{
            "applicationName": "SparkStatistics",
            "type": "Scala",
            "queue": "dev",
            "sparkVersion": "3.5",
            "mainApplicationFile": "local:///usr/lib/spark/examples/jars/spark-examples.jar",
            "mainClass":"org.apache.spark.examples.SparkLR",
            "driver": {
                "cores": 1,
                "memory": "2g",
                "serviceAccount": "emr-containers-sa-spark"
            },
            "executor": {
                "instances": 1,
                "cores": 1,
                "memory": "2g"
            }
        }''',
        connection_id='bpg_connection'
    )
    
    # End task
    end = DummyOperator(task_id='end')

    # Define the task dependencies
    start >> [calculate_pi, word_count] >> statistics_calc >> end
