#!/bin/bash

set -euo pipefail

#################################################
# Docker Hub - Delete unused images
#
# An image is considered "unused" when all of its tags match the immutable
# tag format (<branch>-YYYYMMDDHHMMSS-<sha>) and none of its tags is a
# mutable reference such as "master" or "develop".
#
# An image is considered "used" when it carries at least one tag that does
# NOT match the immutable tag pattern, indicating it is actively referenced.
#
# Usage:
#   ./dockerhub-cleanup-unused.sh [OPTIONS]
#
# Options:
#   -r, --repository   Repository name (without namespace, e.g. myimage)
#   -N, --namespace    Docker Hub namespace / organisation (default: username)
#   -u, --username     Docker Hub username (for authentication)
#   -p, --password     Docker Hub password or access token
#   -n, --dry-run      Print what would be deleted without deleting
#   -h, --help         Show this help
#
# Environment variables (fallbacks):
#   DOCKERHUB_REPOSITORY
#   DOCKERHUB_NAMESPACE
#   DOCKERHUB_USERNAME
#   DOCKERHUB_PASSWORD
#################################################

DOCKERHUB_API="https://hub.docker.com/v2"

DRY_RUN=false
REPOSITORY="${DOCKERHUB_REPOSITORY:-}"
NAMESPACE="${DOCKERHUB_NAMESPACE:-}"
USERNAME="${DOCKERHUB_USERNAME:-}"
PASSWORD="${DOCKERHUB_PASSWORD:-}"

usage() {
    awk '/^#{10,}/{n++; next} n==1{sub(/^# ?/, ""); print} n>=2{exit}' "$0"
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

#################################################
# Parse CLI arguments
#################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--repository)  REPOSITORY="$2";  shift 2 ;;
        -N|--namespace)   NAMESPACE="$2";   shift 2 ;;
        -u|--username)    USERNAME="$2";    shift 2 ;;
        -p|--password)    PASSWORD="$2";    shift 2 ;;
        -n|--dry-run)     DRY_RUN=true;     shift   ;;
        -h|--help)        usage ;;
        *) die "Unknown argument: $1" ;;
    esac
done

#################################################
# Validate required parameters
#################################################
[[ -n "$REPOSITORY" ]] || die "Repository is required. Use -r or set DOCKERHUB_REPOSITORY."
[[ -n "$USERNAME"   ]] || die "Username is required. Use -u or set DOCKERHUB_USERNAME."
[[ -n "$PASSWORD"   ]] || die "Password is required. Use -p or set DOCKERHUB_PASSWORD."

[[ -n "$NAMESPACE" ]] || NAMESPACE="$USERNAME"

echo "Namespace  : $NAMESPACE"
echo "Repository : $REPOSITORY"
echo "Username   : $USERNAME"
echo "Dry-run    : $DRY_RUN"
echo ""

#################################################
# Authenticate
#
# Two separate tokens are required:
#
#   HUB_TOKEN     — JWT from hub.docker.com, used to list tags via the
#                   Docker Hub REST API (/v2/repositories/...)
#
#   REGISTRY_TOKEN — Bearer token from auth.docker.io, used to delete
#                   manifests via the Docker Registry API
#                   (registry-1.docker.io/v2/...). Requires pull+delete
#                   scope; push scope is included as Hub requires it for
#                   delete operations.
#################################################
echo "Authenticating with Docker Hub..."
# Build the JSON payload via Python to safely handle special characters in
# the password (e.g. quotes, exclamation marks) that would break inline shell
# string interpolation inside a JSON literal passed to curl -d.
LOGIN_JSON=$(python3 -c "import json,sys; print(json.dumps({'username':sys.argv[1],'password':sys.argv[2]}))" "$USERNAME" "$PASSWORD")
LOGIN_RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST "$DOCKERHUB_API/users/login" \
    -H "Content-Type: application/json" \
    -d "$LOGIN_JSON")
LOGIN_HTTP_STATUS=$(echo "$LOGIN_RESPONSE" | tail -n1)
LOGIN_BODY=$(echo "$LOGIN_RESPONSE" | head -n-1)

if [[ "$LOGIN_HTTP_STATUS" != "200" ]]; then
    die "Authentication failed (HTTP $LOGIN_HTTP_STATUS): $LOGIN_BODY"
fi

HUB_TOKEN=$(echo "$LOGIN_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$HUB_TOKEN" ]] || die "Authentication failed — no token in response: $LOGIN_BODY"
echo "Authtication HUB successful"

REGISTRY_RESPONSE=$(curl -sS -w "\n%{http_code}" \
    -u "$USERNAME:$PASSWORD" \
    "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$NAMESPACE/$REPOSITORY:pull,push,delete")
REGISTRY_HTTP_STATUS=$(echo "$REGISTRY_RESPONSE" | tail -n1)
REGISTRY_BODY=$(echo "$REGISTRY_RESPONSE" | head -n-1)

if [[ "$REGISTRY_HTTP_STATUS" != "200" ]]; then
    die "Failed to obtain registry token (HTTP $REGISTRY_HTTP_STATUS): $REGISTRY_BODY"
fi

REGISTRY_TOKEN=$(echo "$REGISTRY_BODY" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)
[[ -n "$REGISTRY_TOKEN" ]] || die "Failed to obtain registry token — no token in response: $REGISTRY_BODY"
echo "Authentication REGISTRY successful."
echo ""

#################################################
# Fetch all tags (pagination) and identify unused
#
# All tags are fetched and grouped by digest. A digest is "unused" when
# every tag associated with it matches the immutable tag pattern:
#
#   ^.+-[0-9]{14}-[0-9a-f]{7}$
#
# i.e. <branch>-YYYYMMDDHHMMSS-<short-sha>
#
# If a digest has at least one tag that does NOT match (e.g. "master" or
# "develop"), it is considered actively used and skipped.
#################################################
echo "Fetching tags..."

ALL_TAGS_JSON="[]"
PAGE_SIZE=100
NEXT_URL="$DOCKERHUB_API/repositories/$NAMESPACE/$REPOSITORY/tags?page_size=$PAGE_SIZE&page=1"

while [[ -n "$NEXT_URL" && "$NEXT_URL" != "null" ]]; do
    RESPONSE=$(curl -fsSL \
        -H "Authorization: Bearer $HUB_TOKEN" \
        "$NEXT_URL")

    ALL_TAGS_JSON=$(echo "$ALL_TAGS_JSON $RESPONSE" | python3 -c "
import sys, json
parts = sys.stdin.read().split(None, 1)
accumulated = json.loads(parts[0])
page = json.loads(parts[1])
accumulated.extend(page.get('results', []))
print(json.dumps(accumulated))
")

    NEXT_URL=$(echo "$RESPONSE" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('next') or '')
" 2>/dev/null || true)
done

UNUSED_DIGESTS=()
while IFS= read -r digest; do
    [[ -n "$digest" ]] && UNUSED_DIGESTS+=("$digest")
done < <(echo "$ALL_TAGS_JSON" | python3 -c "
import sys, json, re

IMMUTABLE = re.compile(r'^.+-[0-9]{14}-[0-9a-f]{7}$')

tags = json.load(sys.stdin)

# Group tag names by digest
digest_tags = {}
for t in tags:
    digest = t.get('digest', '')
    name   = t.get('name', '')
    if not digest:
        continue
    digest_tags.setdefault(digest, []).append(name)

# A digest is unused when ALL its tags are immutable
for digest, names in digest_tags.items():
    if all(IMMUTABLE.match(n) for n in names):
        print(digest)
")

#################################################
# Report findings
#################################################
TOTAL=${#UNUSED_DIGESTS[@]}

if [[ $TOTAL -eq 0 ]]; then
    echo "No unused images found. Nothing to do."
    exit 0
fi

echo "Found $TOTAL unused image(s)."
echo ""

#################################################
# Delete (or report) each unused digest
#################################################
DELETED=0
FAILED=0

for DIGEST in "${UNUSED_DIGESTS[@]}"; do
    if [[ "$DRY_RUN" == true ]]; then
        echo "[DRY-RUN] Would delete: $DIGEST"
    else
        echo "Deleting: $DIGEST"
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE \
            -H "Authorization: Bearer $REGISTRY_TOKEN" \
            "https://registry-1.docker.io/v2/$NAMESPACE/$REPOSITORY/manifests/$DIGEST")

        if [[ "$HTTP_STATUS" == "202" ]]; then
            echo "  Deleted."
            (( DELETED++ )) || true
        else
            echo "  WARNING: Unexpected HTTP status $HTTP_STATUS for digest $DIGEST" >&2
            (( FAILED++ )) || true
        fi
    fi
done

echo ""
if [[ "$DRY_RUN" == true ]]; then
    echo "Dry-run complete. $TOTAL image(s) would be deleted."
else
    echo "Done. Deleted: $DELETED  Failed: $FAILED"
    [[ $FAILED -eq 0 ]] || exit 1
fi
