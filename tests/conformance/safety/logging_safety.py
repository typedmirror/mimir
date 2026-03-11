# Tests for SAF007 (sensitive-log-data) and SAF008 (expensive-log-format)
# Verified via: mimir safety tests/conformance/safety/logging_safety.py

import logging
import json

logger = logging.getLogger()

def test_logging():
    # SAF007: sensitive data in logs
    password = "secret123"
    logger.info(f"Login with password: {password}")  # SAF007

    # SAF007: token in log
    api_token = "abc"
    logger.warning(f"Using api_token: {api_token}")  # SAF007

    # SAF008: expensive formatting in debug
    huge_object = {"key": "value"}
    logger.debug(f"Data: {json.dumps(huge_object)}")  # SAF008

    # OK: no sensitive names
    username = "alice"
    logger.info(f"User: {username}")

    # OK: error level with expensive format is acceptable
    logger.error(f"Failed: {json.dumps(huge_object)}")
