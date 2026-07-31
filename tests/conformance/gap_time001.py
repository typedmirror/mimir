import datetime
from datetime import timezone

naive = datetime.datetime.now()
aware = datetime.datetime.now(tz=timezone.utc)

# Triggers TIME001: mixing naive and aware datetime objects
result = naive - aware
