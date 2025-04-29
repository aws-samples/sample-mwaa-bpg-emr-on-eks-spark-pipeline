from airflow.plugins_manager import AirflowPlugin
from bpg_operator import BPGOperator

class BPGMWAAPlugin(AirflowPlugin):
    name = "bpg_mwaa_plugin"
    operators = [BPGOperator]

