import flask
import requests

app = flask.Flask(__name__)

def fetch(url: str) -> str:
    response = requests.get(url)
    return response.text
