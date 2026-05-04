#!/bin/bash
# cleanup_ptp_test_vms.sh - Destroy test VMs and clean up resources.
#
# Usage:
#   sudo ./cleanup_ptp_test_vms.sh

set -e

echo "Destroying PTP test VMs..."

for VM in ptp-master ptp-client; do
    if virsh dominfo "$VM" &>/dev/null; then
        virsh destroy "$VM" 2>/dev/null || true
        virsh undefine "$VM" --remove-all-storage 2>/dev/null || true
        echo "  Removed: $VM"
    else
        echo "  Not found: $VM (skipping)"
    fi
done

rm -f /tmp/ptp_test_vms.env
rm -f /tmp/linuxptp-src.tar.gz
rm -rf /tmp/ptp_test_ssh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "Cleanup complete. Test logs preserved in ${SCRIPT_DIR}/logs/"
