# Default User-Agent sent with all HTTP requests.
USER_AGENT = "FeedmineVerify/1.0"

# HTTP defaults
DEFAULT_CONCURRENCY = 100
DEFAULT_TIMEOUT = 15
DEFAULT_RETRIES = 1

# Only fetch the first N bytes for content / freshness checks.
MAX_BODY_BYTES = 64 * 1024  # 64 KB

# A feed is "stale" when its newest post is older than this many days.
STALE_THRESHOLD_DAYS = 30

# Recognised feed root elements (case-insensitive, namespace-stripped).
# RSS 1.0 documents have an ``rdf:RDF`` root, which becomes ``rdf`` once the
# namespace is stripped.
FEED_ROOT_TAGS = {"rss", "feed", "rdf"}

# HTTP statuses that confirm a feed is permanently gone.  Only these are safe
# to remove with ``--clean``; unresolved DNS/TLS/429/5xx are transient.
PERMANENT_DEAD_STATUSES = {404, 410}

# HTTP statuses that should NOT be retried.
NO_RETRY_STATUSES = {401, 403, 404, 410}

# HTTP status we treat as "rate-limited" — honour Retry-After.
RATE_LIMIT_STATUS = 429
