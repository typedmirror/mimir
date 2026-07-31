"""Conformance fixture for COMPAT002: deprecated module and attribute usage."""

# COMPAT002 is warning-severity (similar to P001), so no marker is used.
# Conform must PASS this file even though COMPAT002 warnings are emitted.

import distutils

def setup():
    from collections import MutableMapping
    return MutableMapping
