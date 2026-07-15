import pickle
import json
import yaml

def test_tainted_pickle(request):
    data = pickle.loads(request.body)  # SER001  # E[SER001|T007]

def test_dict_dumps(user):
    json.dumps(user.__dict__)  # SER003 (Warning, not caught by marker)

def test_safe_json():
    json.dumps({"key": "value"})  # OK — no __dict__

# SER004: Unvalidated config deserialization (Warning, not caught by marker)
class AppConfig:
    host: str
    port: int

def test_config_from_yaml(f):
    config = AppConfig(**yaml.safe_load(f))  # SER004

def test_safe_config(f):
    data = yaml.safe_load(f)
    config = AppConfig(host=data["host"], port=data["port"])  # OK — explicit fields
