#!/bin/sh

URL="https://localhost"

# -k: ignore self-signed certificates
# -f: fail on HTTP errors (>= 400)
# -s: silent mode
# -o /dev/null: discard output
# --max-time 2: timeout after 5 seconds
curl -k -f -s -o /dev/null --max-time 2 "$URL"

exit $?
