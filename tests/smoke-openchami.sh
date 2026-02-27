#!/usr/bin/env bash
# Tier 2: Smoke-test an OpenCHAMI stack for cloud-init / BSS integration.
#
# Expects the OpenCHAMI services (SMD, BSS, cloud-init) to already be
# running and healthy.  Pass the base URL as the first argument:
#
#   ./tests/smoke-openchami.sh http://localhost
#
# The script registers a fake node, creates a cloud-init group, and
# queries the endpoints to verify they return valid data.

set -euo pipefail

BASE="${1:?Usage: $0 <base-url>  (e.g. http://localhost)}"
SMD="$BASE:27779"
BSS="$BASE:27778"
CI="$BASE:27777"
PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

check_http() {
    local label="$1" url="$2" expect="$3"
    local body
    body=$(curl -sf "$url" 2>/dev/null) || { fail "$label -- HTTP request failed"; return; }
    if echo "$body" | grep -q "$expect"; then
        pass "$label"
    else
        fail "$label -- expected '$expect' in response"
        echo "    Got: $(echo "$body" | head -5)"
    fi
}

echo "=== Tier 2: OpenCHAMI smoke test ==="
echo "    SMD: $SMD  BSS: $BSS  cloud-init: $CI"
echo

# ------------------------------------------------------------------
# 1. Service health
# ------------------------------------------------------------------
echo "--- Service health ---"
check_http "SMD ready"        "$SMD/hsm/v2/service/ready"          "healthy"
check_http "BSS ready"        "$BSS/boot/v1/service/status"        ""
check_http "cloud-init alive" "$CI/version"                        ""

# ------------------------------------------------------------------
# 2. Register a fake node in SMD
# ------------------------------------------------------------------
echo "--- Register fake node ---"
XNAME="x3000c1s1b0n0"
MAC="02:00:00:00:00:01"
IP="192.168.0.100"

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$SMD/hsm/v2/State/Components" \
    -H "Content-Type: application/json" \
    -d "{\"Components\":[{\"ID\":\"$XNAME\",\"State\":\"Ready\",\"NetType\":\"Sling\",\"Arch\":\"X86\",\"NID\":100}]}" \
    2>/dev/null)

if [[ "$HTTP_CODE" =~ ^2 ]]; then
    pass "SMD: added component $XNAME"
else
    fail "SMD: add component returned HTTP $HTTP_CODE"
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$SMD/hsm/v2/Inventory/EthernetInterfaces" \
    -H "Content-Type: application/json" \
    -d "{\"Description\":\"test NIC\",\"MACAddress\":\"$MAC\",\"ComponentID\":\"$XNAME\",\"IPAddresses\":[{\"IPAddress\":\"$IP\"}]}" \
    2>/dev/null)

if [[ "$HTTP_CODE" =~ ^2 ]]; then
    pass "SMD: registered MAC $MAC"
else
    fail "SMD: register MAC returned HTTP $HTTP_CODE"
fi

# ------------------------------------------------------------------
# 3. Create a cloud-init group
# ------------------------------------------------------------------
echo "--- Cloud-init group ---"
GROUP_PAYLOAD=$(cat <<'ENDJSON'
{
    "name": "compute",
    "description": "CI test compute group",
    "file": {
        "content": "#cloud-config\nruncmd:\n  - echo smoke-test-ok\n",
        "encoding": "plain"
    }
}
ENDJSON
)

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$CI/admin/groups" \
    -H "Content-Type: application/json" \
    -d "$GROUP_PAYLOAD" \
    2>/dev/null)

if [[ "$HTTP_CODE" =~ ^2 ]]; then
    pass "cloud-init: created compute group"
else
    fail "cloud-init: create group returned HTTP $HTTP_CODE"
fi

# ------------------------------------------------------------------
# 4. Add node to group
# ------------------------------------------------------------------
echo "--- Group membership ---"
HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
    -X POST "$SMD/hsm/v2/groups" \
    -H "Content-Type: application/json" \
    -d "{\"label\":\"compute\",\"description\":\"test\",\"members\":{\"ids\":[\"$XNAME\"]}}" \
    2>/dev/null)

if [[ "$HTTP_CODE" =~ ^2 ]]; then
    pass "SMD: added $XNAME to compute group"
else
    fail "SMD: add to group returned HTTP $HTTP_CODE"
fi

# ------------------------------------------------------------------
# 5. Query cloud-init endpoints (impersonation)
# ------------------------------------------------------------------
echo "--- Cloud-init endpoint queries ---"
check_http "meta-data"   "$CI/admin/impersonation/$XNAME/meta-data"   "instance-id"
check_http "user-data"   "$CI/admin/impersonation/$XNAME/user-data"   "cloud-config"
check_http "vendor-data" "$CI/admin/impersonation/$XNAME/vendor-data" ""

# ------------------------------------------------------------------
# 6. Query BSS for boot parameters
# ------------------------------------------------------------------
echo "--- BSS boot params ---"
BSS_RESP=$(curl -sf "$BSS/boot/v1/bootscript?mac=$MAC" 2>/dev/null) || BSS_RESP=""
if [[ -n "$BSS_RESP" ]]; then
    pass "BSS: returned boot script for MAC $MAC"
else
    # BSS may not have boot params configured yet; that's acceptable
    echo "SKIP: BSS boot script not configured (expected in CI without full boot setup)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
