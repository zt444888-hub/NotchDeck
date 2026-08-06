#!/bin/bash
#
# Deploy the CloudKit schema for the Remote AI Conversation feature (v1.2.0)
# from the DEVELOPMENT environment to PRODUCTION.
#
# Why: CloudKit auto-creates record types only in the development environment
# (first save from a development-signed build). Production is empty until you
# import a schema — every query/save from a released app would fail.
#
# Usage:
#   1. xcrun cktool auth login --environment development   # one-time auth
#   2. ./deploy-cloudkit-schema.sh
#
# The script exports the schema that the dev app already created, then imports
# it into production. Afterwards, verify the query/sort indexes in the CloudKit
# Dashboard (https://icloud.developer.apple.com):
#   recordType RemoteConversation → fields:
#     status     → Queryable (used by poll: status IN [pending])
#     updatedAt  → Queryable + Sortable (list ordering)
#   If the export doesn't include them, add them in the Dashboard and re-run
#   the import (import merges, it won't clobber).
#
set -euo pipefail

CONTAINER="iCloud.com.notchdeck"
TMPDIR_MY=$(mktemp -d)
trap 'rm -rf "$TMPDIR_MY"' EXIT

echo "==> 1/3 Exporting development schema (auto-created by the dev app)"
xcrun cktool schema export \
    --environment development \
    --container-id "$CONTAINER" \
    --file "$TMPDIR_MY/schema.json"

echo "==> Schema exported:"
python3 -c "
import json,sys
d=json.load(open('$TMPDIR_MY/schema.json'))
for rt,defn in d.get('recordTypes',{}).items():
    print('  recordType', rt)
    print('  fields:', ', '.join(defn.get('fields',{}).keys()) or '(none)')
"

echo "==> 2/3 Checking required query/sort indexes"
python3 - "$TMPDIR_MY/schema.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
rt=d.get('recordTypes',{}).get('RemoteConversation')
if not rt:
    print('  WARNING: RemoteConversation recordType missing — run the dev app once')
    print('  so CloudKit auto-creates it, then re-run this script.')
    sys.exit(0)
idx=rt.get('indexes',[])
def has(field, kind):
    return any(i.get('fieldName')==field and i.get('indexType')==kind for i in idx)
for f,k,need in [('status','queryable',True),('updatedAt','queryable',True),('updatedAt','sortable',True)]:
    ok=has(f,k)
    print(f"  {'OK ' if ok else 'MISSING'} {f} {k}")
PY

echo "==> 3/3 Importing into production"
xcrun cktool schema import \
    --environment production \
    --container-id "$CONTAINER" \
    --file "$TMPDIR_MY/schema.json"

echo "==> Done. Missing indexes: add them in the CloudKit Dashboard, then re-run"
echo "    the import — it merges, existing data is untouched."
