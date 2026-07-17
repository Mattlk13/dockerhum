#!/bin/bash

# Prefix each output line with the supervisor process name, keeping stdout/stderr separate.
PREFIX="[${SUPERVISOR_PROCESS_NAME:-humhub-app-log}]"
exec > >(while IFS= read -r line; do printf '%s %s\n' "$PREFIX" "$line"; done) \
     2> >(while IFS= read -r line; do printf '%s %s\n' "$PREFIX" "$line"; done >&2)

exec tail -F /data/logs/app.log
