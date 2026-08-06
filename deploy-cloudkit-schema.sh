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
#   1. Obtain a CloudKit management token from the CloudKit Dashboard
#      (https://icloud.developer.apple.com → Settings → API Access → create a
#      token, or use `xcrun cktool get-teams` to check connectivity) and save
#      it once:
#        xcrun cktool save-token --method keychain
#      (it prompts for the token interactively; saved in the keychain)
#   2. ./deploy-cloudkit-schema.sh
#
# The script exports the schema the dev app already created, then imports it
# into production. Afterwards, verify the query/sort indexes in the CloudKit
# Dashboard:
#   recordType RemoteConversation → fields:
#     status     → Queryable  (used by poll: status IN [pending])
#     updatedAt  → Queryable + Sortable (list ordering)
#   If the export doesn't include them, add them in the Dashboard and re-run
#   the import (import merges, it won't clobber existing data).
#
set -euo pipefail

CONTAINER="iCloud.com.notchdeck"
TEAM_ID="${NOTCHDECK_TEAM_ID:-2VBHV3VJ8N}"
TMPDIR_MY=$(mktemp -d)
trap 'rm -rf "$TMPDIR_MY"' EXIT

echo "==> 0/3 Checking auth (get-teams; must not error)"
xcrun cktool get-teams >/dev/null 2>&1 \
    && echo "    auth OK" \
    || { echo "    auth missing — run: xcrun cktool save-token --method keychain"; exit 1; }

echo "==> 1/3 Exporting development schema (auto-created by the dev app)"
xcrun cktool export-schema \
    --team-id "$TEAM_ID" \
    --container-id "$CONTAINER" \
    --environment development \
    --output-file "$TMPDIR_MY/schema.json"

echo "==> Schema exported:"
python3 -c "
import json,sys
d=json.load(open('$TMPDIR_MY/schema.json'))
rts=d.get('recordTypes',{})
if not rts:
    print('  (empty — the dev app has not written any record yet)')
for rt,defn in rts.items():
    print('  recordType', rt)
    print('  fields:', ', '.join(defn.get('fields',{}).keys()) or '(none)')
    for i in defn.get('indexes',[]):
        print('    index:', i.get('fieldName'), i.get('indexType'))
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
for f,k in [('status','queryable'),('updatedAt','queryable'),('updatedAt','sortable')]:
    print(f"  {'OK ' if has(f,k) else 'MISSING'} {f} {k}")
PY

echo "==> 3/3 Importing into production (with validation)"
xcrun cktool import-schema \
    --team-id "$TEAM_ID" \
    --container-id "$CONTAINER" \
    --environment production \
    --validate \
    --file "$TMPDIR_MY/schema.json"

echo "==> Done. Missing indexes: add them in the CloudKit Dashboard, then re-run"
echo "    the import — it merges, existing data is untouched."
