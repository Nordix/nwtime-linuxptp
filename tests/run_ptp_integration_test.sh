#!/bin/bash
# run_ptp_integration_test.sh - Run the popcorn filter integration test.
#
# This script:
#   1. Starts ptp4l as grandmaster on the master VM
#   2. Starts the patched ptp4l (with popcorn filter) as client on the client VM
#   3. Waits for the servo to lock
#   4. Injects a clock step on the master to create a spike
#   5. Checks if the popcorn filter suppressed the spike
#
# Prerequisites:
#   - Run setup_ptp_test_vms.sh first to create the VMs
#   - VMs must be running (check: sudo virsh list)
#
# Usage:
#   sudo ./run_ptp_integration_test.sh
#
# Options:
#   SPIKE_SIZE   - Clock step size in seconds (default: 0.01 = 10ms)
#   LOCK_WAIT    - Seconds to wait for servo to lock (default: 35)
#   POST_WAIT    - Seconds to observe after spike injection (default: 20)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()  { echo -e "${CYAN}[STEP]${NC} $*"; }

# Progress timer: wait_with_progress <seconds> <message>
wait_with_progress() {
    local total=$1 msg=$2
    local i=0 bar_len=30
    while (( i < total )); do
        local pct=$(( i * 100 / total ))
        local filled=$(( i * bar_len / total ))
        local empty=$(( bar_len - filled ))
        printf "\r  %s [%-${bar_len}s] %3d%% (%d/%ds)" \
            "$msg" "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null))" "$pct" "$i" "$total"
        sleep 1
        (( ++i ))
    done
    printf "\r  %s [%-${bar_len}s] 100%% (%d/%ds)\n" \
        "$msg" "$(printf '#%.0s' $(seq 1 $bar_len))" "$total" "$total"
}

# --- Configuration ---

SPIKE_SIZE="${SPIKE_SIZE:-0.01}"
LOCK_WAIT="${LOCK_WAIT:-45}"
POST_WAIT="${POST_WAIT:-20}"
CLIENT_TIMEOUT=$((LOCK_WAIT + POST_WAIT + 10))

# Load VM info
if [[ -f /tmp/ptp_test_vms.env ]]; then
    source /tmp/ptp_test_vms.env
else
    # Try to detect from virsh
    MASTER_IP=$(virsh domifaddr ptp-master 2>/dev/null | awk '/ipv4/ {split($4,a,"/"); print a[1]}')
    CLIENT_IP=$(virsh domifaddr ptp-client 2>/dev/null | awk '/ipv4/ {split($4,a,"/"); print a[1]}')
    VM_USER="cloud-user"
    SSH_KEY="/tmp/ptp_test_ssh/id_ed25519"
fi

if [[ -z "$MASTER_IP" || -z "$CLIENT_IP" ]]; then
    error "Cannot find VM IPs. Run setup_ptp_test_vms.sh first, or ensure VMs are running."
fi

if [[ ! -f "$SSH_KEY" ]]; then
    error "SSH key not found at ${SSH_KEY}. Run setup_ptp_test_vms.sh first."
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}"
SSH_MASTER="ssh ${SSH_OPTS} ${VM_USER}@${MASTER_IP}"
SSH_CLIENT="ssh ${SSH_OPTS} ${VM_USER}@${CLIENT_IP}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="${LOG_DIR}/ptp-client-${TIMESTAMP}.log"

# Ensure logs are accessible by the invoking (non-root) user
if [[ -n "$SUDO_USER" ]]; then
    chown "$SUDO_USER":"$SUDO_USER" "${LOG_DIR}"
fi

# --- Preflight ---

info "Integration test configuration:"
info "  Master VM:    ${MASTER_IP}"
info "  Client VM:    ${CLIENT_IP}"
info "  Spike size:   ${SPIKE_SIZE}s"
info "  Lock wait:    ${LOCK_WAIT}s"
info "  Post wait:    ${POST_WAIT}s"
info "  Log file:     ${LOG_FILE}"
echo ""

# Verify VMs are reachable
${SSH_MASTER} "true" 2>/dev/null || error "Cannot SSH to master VM (${MASTER_IP})"
${SSH_CLIENT} "true" 2>/dev/null || error "Cannot SSH to client VM (${CLIENT_IP})"

# --- Step 1: Kill any existing ptp4l processes ---

step "1/5 Cleaning up any existing ptp4l processes..."
${SSH_MASTER} "sudo killall ptp4l 2>/dev/null || true"
${SSH_CLIENT} "sudo killall ptp4l 2>/dev/null || true"
sleep 2

# --- Step 2: Start PTP grandmaster ---

step "2/5 Starting ptp4l as grandmaster on master VM (${MASTER_IP})..."
${SSH_MASTER} "cd ~/linuxptp && sudo sh -c './ptp4l -i enp1s0 -m -S --priority1 100 > /tmp/ptp-master.log 2>&1 &'"
wait_with_progress 10 "Waiting for master MASTER state"

# Verify master is running
MASTER_STATE=$(${SSH_MASTER} "cat /tmp/ptp-master.log" 2>/dev/null)
if echo "$MASTER_STATE" | grep -q "MASTER"; then
    info "  Master is in MASTER state."
else
    warn "  Master may not have reached MASTER state yet (will retry during test)."
fi

# --- Step 3: Start PTP client with popcorn filter ---

step "3/5 Starting ptp4l client with popcorn filter on client VM (${CLIENT_IP})..."
${SSH_CLIENT} "cd ~/linuxptp && sudo timeout ${CLIENT_TIMEOUT} ./ptp4l -i enp1s0 \
    -f configs/popcorn_filter.cfg -s -m -S -l 7 2>&1" > "${LOG_FILE}" &
CLIENT_PID=$!

info "  Client running (local PID: ${CLIENT_PID}), waiting ${LOCK_WAIT}s for servo to lock..."
wait_with_progress "${LOCK_WAIT}" "Waiting for servo to lock"

# --- Step 4: Inject clock step to trigger spike ---

step "4/5 Injecting clock step of ${SPIKE_SIZE}s on master to trigger spike..."
${SSH_MASTER} "sudo date -s '+${SPIKE_SIZE} seconds'" 2>/dev/null
info "  Clock stepped. Waiting ${POST_WAIT}s for filter to react..."
wait_with_progress "${POST_WAIT}" "Observing filter reaction"

# --- Step 5: Collect results ---

step "5/5 Collecting results..."
wait ${CLIENT_PID} 2>/dev/null || true

echo ""
echo "============================================="
echo " INTEGRATION TEST RESULTS"
echo "============================================="
echo ""

# Check for popcorn filter messages
FILTER_MSGS=$(grep -i "popcorn" "${LOG_FILE}" 2>/dev/null | grep -v "config item" || true)

if [[ -n "$FILTER_MSGS" ]]; then
    SPIKE_COUNT=$(echo "$FILTER_MSGS" | grep -c "spike suppressed" || echo "0")
    echo -e "${GREEN}PASS${NC}: Popcorn filter triggered - ${SPIKE_COUNT} spike(s) suppressed"
    echo ""
    echo "Filter messages:"
    echo "$FILTER_MSGS" | head -10
else
    echo -e "${YELLOW}NOTE${NC}: No popcorn filter messages found."
    echo "  This may happen if:"
    echo "  - The servo didn't reach LOCKED state (check log)"
    echo "  - The spike wasn't large enough relative to jitter"
    echo "  - The spike_gate multiplier is too high"
fi

echo ""

# Check servo transitions
if grep -q "UNCALIBRATED to SLAVE" "${LOG_FILE}"; then
    echo -e "${GREEN}PASS${NC}: Client synchronized with master (reached SLAVE state)"
else
    echo -e "${RED}FAIL${NC}: Client never reached SLAVE state"
fi

if grep -q "s2 freq" "${LOG_FILE}"; then
    echo -e "${GREEN}PASS${NC}: Servo reached locked state (s2)"
else
    echo -e "${RED}FAIL${NC}: Servo never locked"
fi

echo ""
echo "Full log: ${LOG_FILE}"
echo "Log line count: $(wc -l < "${LOG_FILE}")"
echo ""

# --- Collect master log ---

MASTER_LOG="${LOG_DIR}/ptp-master-${TIMESTAMP}.log"
${SSH_MASTER} "cat /tmp/ptp-master.log" > "${MASTER_LOG}" 2>/dev/null || true
info "Master log saved to: ${MASTER_LOG}"
info "Client log saved to: ${LOG_FILE}"

# Fix ownership so non-root user can manage log files
if [[ -n "$SUDO_USER" ]]; then
    chown -R "$SUDO_USER":"$SUDO_USER" "${LOG_DIR}"
fi

# Exit with appropriate code
if [[ -n "$FILTER_MSGS" ]]; then
    exit 0
else
    exit 1
fi
