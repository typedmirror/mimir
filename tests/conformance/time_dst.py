# §15 Time/Encoding — TIME002 (naive now) and TIME003 (DST-unsafe arithmetic)
# Verified via: mimir check (warnings from time_encoding analysis)

import datetime
from datetime import timedelta, timezone

# TIME002: naive datetime.now()
naive = datetime.datetime.now()  # TIME002 fires here (warning, not error — checked via mimir check directly)

# TIME003: DST-unsafe arithmetic on aware datetime
aware = datetime.datetime.now(tz=timezone.utc)
result = aware + timedelta(hours=2)  # TIME003 fires here (warning)

# OK: timedelta with days (not DST-sensitive)
safe = aware + timedelta(days=1)
