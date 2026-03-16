import pickle
import json

def test_tainted_pickle(request):
    data = pickle.loads(request.body)  # SER001  # E

def test_dict_dumps(user):
    json.dumps(user.__dict__)  # SER003 (Warning, not caught by marker)

def test_safe_json():
    json.dumps({"key": "value"})  # OK — no __dict__
