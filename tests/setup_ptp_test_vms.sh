#!/bin/bash
# setup_ptp_test_vms.sh - Create two KVM/libvirt VMs for PTP integration testing.
#
# This script creates a PTP master and PTP client VM on the same virtual bridge
# (virbr0) so they can exchange PTP packets. The client VM runs the patched
# linuxptp with the popcorn filter.
#
# Prerequisites:
#   - Linux host with KVM support (check: lsmod | grep kvm)
#   - Root or sudo access
#   - Internet access (to download the cloud image)
#
# Usage:
#   sudo ./setup_ptp_test_vms.sh
#
# After setup, use run_ptp_integration_test.sh to execute the test.

set -e

IMAGES_DIR="/var/lib/libvirt/images"
CLOUD_IMAGE="CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2"
CLOUD_IMAGE_URL="https://cloud.centos.org/centos/10-stream/x86_64/images/${CLOUD_IMAGE}"
SSH_KEY_DIR="/tmp/ptp_test_ssh"
MASTER_NAME="ptp-master"
CLIENT_NAME="ptp-client"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Preflight checks ---

if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (or with sudo)."
fi

if ! lsmod | grep -q kvm; then
    error "KVM kernel modules not loaded. Ensure hardware virtualization is enabled."
fi

# --- Install dependencies ---

info "Installing KVM/libvirt packages (if not already installed)..."
dnf install -y qemu-kvm libvirt virt-install libvirt-client xorriso 2>&1 | tail -5

info "Starting libvirtd..."
systemctl start libvirtd
systemctl enable libvirtd 2>/dev/null || true

# Ensure default network is active
virsh net-start default 2>/dev/null || true

# --- Download cloud image ---

if [[ ! -f "${IMAGES_DIR}/${CLOUD_IMAGE}" ]]; then
    info "Downloading CentOS Stream 10 cloud image..."
    curl -L -o "${IMAGES_DIR}/${CLOUD_IMAGE}" "${CLOUD_IMAGE_URL}"
else
    info "Cloud image already exists, skipping download."
fi

# --- Clean up any existing test VMs ---

for VM in ${MASTER_NAME} ${CLIENT_NAME}; do
    if virsh dominfo "$VM" &>/dev/null; then
        warn "Destroying existing VM: $VM"
        virsh destroy "$VM" 2>/dev/null || true
        virsh undefine "$VM" --remove-all-storage 2>/dev/null || true
    fi
done

# --- Create disk images (thin-provisioned, backed by cloud image) ---

info "Creating VM disk images..."
qemu-img create -f qcow2 -b "${IMAGES_DIR}/${CLOUD_IMAGE}" -F qcow2 \
    "${IMAGES_DIR}/${MASTER_NAME}.qcow2" 10G
qemu-img create -f qcow2 -b "${IMAGES_DIR}/${CLOUD_IMAGE}" -F qcow2 \
    "${IMAGES_DIR}/${CLIENT_NAME}.qcow2" 10G

# --- Generate ephemeral SSH key ---

info "Generating ephemeral SSH key pair..."
rm -rf "${SSH_KEY_DIR}"
mkdir -p "${SSH_KEY_DIR}"
chmod 700 "${SSH_KEY_DIR}"
ssh-keygen -t ed25519 -f "${SSH_KEY_DIR}/id_ed25519" -N "" -q
SSH_PUBKEY=$(cat "${SSH_KEY_DIR}/id_ed25519.pub")

# --- Create cloud-init ISOs ---

info "Creating cloud-init configuration..."

TMPDIR=$(mktemp -d)
trap "rm -rf ${TMPDIR}" EXIT

for VM in ${MASTER_NAME} ${CLIENT_NAME}; do
    mkdir -p "${TMPDIR}/${VM}"

    cat > "${TMPDIR}/${VM}/meta-data" << EOF
instance-id: ${VM}
local-hostname: ${VM}
EOF

    cat > "${TMPDIR}/${VM}/user-data" << EOF
#cloud-config
ssh_authorized_keys:
  - ${SSH_PUBKEY}
packages:
  - gcc
  - make
runcmd:
  - systemctl disable --now firewalld || true
EOF

    xorriso -as mkisofs -o "${IMAGES_DIR}/${VM}-cidata.iso" -V cidata -J -r \
        "${TMPDIR}/${VM}/" 2>/dev/null
done

# --- Create VMs ---

info "Creating ${MASTER_NAME} VM..."
virt-install \
    --name "${MASTER_NAME}" \
    --memory 2048 \
    --vcpus 2 \
    --disk "${IMAGES_DIR}/${MASTER_NAME}.qcow2" \
    --disk "${IMAGES_DIR}/${MASTER_NAME}-cidata.iso,device=cdrom" \
    --os-variant centos-stream9 \
    --network network=default \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import

info "Creating ${CLIENT_NAME} VM..."
virt-install \
    --name "${CLIENT_NAME}" \
    --memory 2048 \
    --vcpus 2 \
    --disk "${IMAGES_DIR}/${CLIENT_NAME}.qcow2" \
    --disk "${IMAGES_DIR}/${CLIENT_NAME}-cidata.iso,device=cdrom" \
    --os-variant centos-stream9 \
    --network network=default \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import

# --- Wait for VMs to boot and get IPs ---

info "Waiting for VMs to boot and cloud-init to finish..."
BOOT_WAIT=90
for (( i=0; i<BOOT_WAIT; i++ )); do
    pct=$(( i * 100 / BOOT_WAIT ))
    filled=$(( i * 30 / BOOT_WAIT ))
    printf "\r  Booting VMs [%-30s] %3d%% (%d/%ds)" \
        "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null))" "$pct" "$i" "$BOOT_WAIT"
    sleep 1
done
printf "\r  Booting VMs [%-30s] 100%% (%d/%ds)\n" \
    "$(printf '#%.0s' $(seq 1 30))" "$BOOT_WAIT" "$BOOT_WAIT"

MASTER_IP=$(virsh domifaddr ${MASTER_NAME} | awk '/ipv4/ {split($4,a,"/"); print a[1]}')
CLIENT_IP=$(virsh domifaddr ${CLIENT_NAME} | awk '/ipv4/ {split($4,a,"/"); print a[1]}')

if [[ -z "$MASTER_IP" || -z "$CLIENT_IP" ]]; then
    error "Failed to get VM IP addresses. Check: virsh domifaddr ${MASTER_NAME}"
fi

info "VM IPs:"
info "  ${MASTER_NAME}: ${MASTER_IP}"
info "  ${CLIENT_NAME}: ${CLIENT_IP}"

# --- Store IPs for the test script ---

cat > /tmp/ptp_test_vms.env << EOF
MASTER_IP=${MASTER_IP}
CLIENT_IP=${CLIENT_IP}
VM_USER=cloud-user
SSH_KEY=${SSH_KEY_DIR}/id_ed25519
EOF

info "VM info saved to /tmp/ptp_test_vms.env"

# --- Copy and build linuxptp source on both VMs ---

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY_DIR}/id_ed25519"

info "Creating linuxptp source tarball..."
tar czf /tmp/linuxptp-src.tar.gz -C "${SCRIPT_DIR}" \
    --exclude='.git' --exclude='*.o' --exclude='*.d' \
    --exclude='ptp4l' --exclude='test_popcorn_filter' .

for VM_IP in ${MASTER_IP} ${CLIENT_IP}; do
    info "Copying and building linuxptp on ${VM_IP}..."
    scp ${SSH_OPTS} /tmp/linuxptp-src.tar.gz \
        cloud-user@${VM_IP}:/tmp/linuxptp-src.tar.gz
    ssh ${SSH_OPTS} cloud-user@${VM_IP} \
        "mkdir -p ~/linuxptp && cd ~/linuxptp && tar xzf /tmp/linuxptp-src.tar.gz && make ptp4l 2>&1 | tail -3"
done

info ""
info "========================================="
info " Setup complete!"
info "========================================="
info ""
info " Run the integration test with:"
info "   sudo ./run_ptp_integration_test.sh"
info ""
info " Or manually:"
info "   Master: ssh ${SSH_OPTS} cloud-user@${MASTER_IP} 'cd ~/linuxptp && sudo ./ptp4l -i enp1s0 -m -S --priority1 100'"
info "   Client: ssh ${SSH_OPTS} cloud-user@${CLIENT_IP} 'cd ~/linuxptp && sudo ./ptp4l -i enp1s0 -f configs/popcorn_filter.cfg -s -m -S -l 7'"
info ""
