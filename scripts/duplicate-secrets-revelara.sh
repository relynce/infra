#!/usr/bin/env bash
# Duplicate all relynce-prod-* GCP secrets to revelara-prod-* equivalents.
# Both sets coexist during the domain transition (Phase 0).
#
# Two secrets get updated values (new redirect URIs):
#   - workos-redirect-uri
#   - google-oauth-redirect-uri
#
# Usage: ./duplicate-secrets-revelara.sh [--dry-run]

set -euo pipefail

PROJECT_ID="incident-kb"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    echo "=== DRY RUN MODE ==="
fi

# Secrets that need new values instead of copying the old value
declare -A OVERRIDE_VALUES
OVERRIDE_VALUES["workos-redirect-uri"]="https://api.revelara.ai/api/v1/auth/workos/callback"
OVERRIDE_VALUES["google-oauth-redirect-uri"]="https://api.revelara.ai/api/v1/integrations/google/callback"

# Get all relynce-prod secrets
SECRETS=$(gcloud secrets list --format="value(name)" --project="$PROJECT_ID" 2>/dev/null | grep "^relynce-prod-" | sort)

if [[ -z "$SECRETS" ]]; then
    echo "ERROR: No relynce-prod-* secrets found in project $PROJECT_ID"
    exit 1
fi

echo "Found secrets to duplicate:"
echo "$SECRETS" | while read -r s; do echo "  $s"; done
echo ""

CREATED=0
SKIPPED=0
FAILED=0

while read -r OLD_NAME; do
    # Derive new name: relynce-prod-foo -> revelara-prod-foo
    SUFFIX="${OLD_NAME#relynce-prod-}"
    NEW_NAME="revelara-prod-${SUFFIX}"

    # Check if new secret already exists
    if gcloud secrets describe "$NEW_NAME" --project="$PROJECT_ID" &>/dev/null 2>&1; then
        echo "SKIP: $NEW_NAME already exists"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Determine the value to use
    if [[ -v "OVERRIDE_VALUES[$SUFFIX]" ]]; then
        VALUE="${OVERRIDE_VALUES[$SUFFIX]}"
        echo "CREATE: $NEW_NAME (override value: ${VALUE})"
    else
        # Copy value from the old secret's latest version
        VALUE=$(gcloud secrets versions access latest --secret="$OLD_NAME" --project="$PROJECT_ID" 2>/dev/null)
        if [[ -z "$VALUE" ]]; then
            echo "FAIL: Could not read value from $OLD_NAME"
            FAILED=$((FAILED + 1))
            continue
        fi
        echo "CREATE: $NEW_NAME (copied from $OLD_NAME)"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        CREATED=$((CREATED + 1))
        continue
    fi

    # Create the new secret and add the initial version
    if gcloud secrets create "$NEW_NAME" --project="$PROJECT_ID" --replication-policy="automatic" 2>/dev/null; then
        if echo -n "$VALUE" | gcloud secrets versions add "$NEW_NAME" --project="$PROJECT_ID" --data-file=- 2>/dev/null; then
            CREATED=$((CREATED + 1))
        else
            echo "FAIL: Created $NEW_NAME but could not add version"
            FAILED=$((FAILED + 1))
        fi
    else
        echo "FAIL: Could not create $NEW_NAME"
        FAILED=$((FAILED + 1))
    fi

done <<< "$SECRETS"

echo ""
echo "=== Summary ==="
echo "Created: $CREATED"
echo "Skipped: $SKIPPED"
echo "Failed:  $FAILED"
