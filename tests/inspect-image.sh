#!/usr/bin/env bash
# Tier 1: Inspect a built bootc image to verify OpenCHAMI-required contents.
#
# Usage:
#   ./tests/inspect-image.sh <image-ref>
#
# The script creates a temporary container from the image, mounts its
# filesystem, runs assertions, then cleans up.  Exits 0 on success, 1
# on the first failure.

set -euo pipefail

IMAGE="${1:?Usage: $0 <image-ref>}"
PASS=0
FAIL=0

fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }

CTR=$(buildah from "$IMAGE")
MNT=$(buildah mount "$CTR")
trap 'buildah umount "$CTR" >/dev/null 2>&1; buildah rm "$CTR" >/dev/null 2>&1' EXIT

echo "=== Tier 1: Image inspection for $IMAGE ==="
echo "    Mounted at $MNT"
echo

# --- Cloud-init datasource config ---
CFG="$MNT/etc/cloud/cloud.cfg.d/99_openchami.cfg"
if [[ -f "$CFG" ]]; then
    pass "99_openchami.cfg exists"
else
    fail "99_openchami.cfg missing at /etc/cloud/cloud.cfg.d/"
fi

if [[ -f "$CFG" ]] && grep -q 'NoCloud' "$CFG"; then
    pass "99_openchami.cfg contains NoCloud datasource"
else
    fail "99_openchami.cfg does not reference NoCloud datasource"
fi

# --- Required binaries ---
for bin in usr/bin/cloud-init usr/sbin/sshd usr/bin/ipmitool usr/sbin/lldpd usr/bin/tmux usr/bin/jq usr/bin/htop; do
    if [[ -f "$MNT/$bin" ]]; then
        pass "$bin present"
    else
        fail "$bin missing"
    fi
done

# --- Systemd service enablement ---
# Enabled services have symlinks under /etc/systemd/system/
for svc in sshd cloud-init cloud-init-local cloud-config cloud-final lldpd; do
    found=false
    for link in "$MNT"/etc/systemd/system/*.wants/"${svc}.service" \
                "$MNT"/etc/systemd/system/*.wants/"${svc}".service; do
        if [[ -L "$link" ]] || [[ -f "$link" ]]; then
            found=true
            break
        fi
    done
    if $found; then
        pass "systemd: $svc enabled"
    else
        fail "systemd: $svc not enabled"
    fi
done

# --- User setup ---
if grep -q 'bootc-user' "$MNT/etc/passwd"; then
    pass "bootc-user account exists"
else
    fail "bootc-user account missing"
fi

if [[ -f "$MNT/etc/sudoers.d/wheel-sudo" ]]; then
    pass "wheel-sudo passwordless config exists"
else
    fail "wheel-sudo config missing"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
