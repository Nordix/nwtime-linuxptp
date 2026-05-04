# Popcorn Filter Tests

This directory contains unit and integration tests for the popcorn spike filter.

## Quick Start

```bash
# Unit tests (no hardware needed, runs on any Linux box)
make test

# Integration tests (requires KVM support)
sudo tests/setup_ptp_test_vms.sh    # one-time VM setup
sudo tests/run_ptp_integration_test.sh   # run the test
sudo tests/cleanup_ptp_test_vms.sh  # tear down VMs when done
```

## Unit Tests

**File:** `tests/test_popcorn_filter.c`

Exercises the popcorn filter logic in isolation using stub implementations of
the clock and port functions. No PTP hardware or network required.

| Test | What it verifies |
|------|-----------------|
| `test_create_destroy` | Allocation and zero-initialization |
| `test_jitter_calculation` | Offset jitter (stddev) math correctness |
| `test_accepts_samples_when_unlocked` | No filtering before servo locks |
| `test_accepts_normal_samples_when_locked` | Small offsets pass through |
| `test_rejects_spike_when_locked` | Large spike rejected while locked |
| `test_accepts_after_long_gap` | Spike accepted when dt >> sync interval |
| `test_buffer_wraps_correctly` | Ring buffer index wrap-around |

### Build & Run

```bash
make test                    # build and run
make test_popcorn_filter     # build only
./test_popcorn_filter        # run only
```

Exit code 0 = all tests pass, 1 = at least one failure.

## Integration Tests

End-to-end test using two KVM/libvirt VMs on the same virtual bridge:

- **ptp-master** — runs stock `ptp4l` as PTP grandmaster
- **ptp-client** — runs patched `ptp4l` with popcorn filter enabled

The test script injects a clock step on the master after the client's servo
locks, then verifies the popcorn filter suppresses the resulting spike.

### Prerequisites

- Linux host with KVM support (`lsmod | grep kvm`)
- Root/sudo access
- Internet access (to download CentOS cloud image, ~2GB)
- ~5GB free disk space in `/var/lib/libvirt/images/`

### Step-by-Step

#### 1. Create the test VMs (one-time setup)

```bash
sudo tests/setup_ptp_test_vms.sh
```

This will:
- Install `qemu-kvm`, `libvirt`, `virt-install` (if missing)
- Download CentOS Stream 10 cloud image
- Create two VMs (`ptp-master`, `ptp-client`) on `virbr0`
- Wait for cloud-init to finish
- Copy and build the patched linuxptp on the client VM

#### 2. Run the integration test

```bash
sudo tests/run_ptp_integration_test.sh
```

This will:
1. Start `ptp4l` as grandmaster on ptp-master
2. Start patched `ptp4l` (with popcorn filter) as client on ptp-client
3. Wait 35s for the servo to lock (state `s2`)
4. Step the master's system clock by 10ms to inject a spike
5. Wait 20s for the filter to react
6. Check logs for "popcorn filter: spike suppressed" messages

**Expected output:**
```
PASS: Popcorn filter triggered - 7 spike(s) suppressed
PASS: Client synchronized with master (reached SLAVE state)
PASS: Servo reached locked state (s2)
```

#### 3. Customize the test

Environment variables:
```bash
SPIKE_SIZE=0.05  # step size in seconds (default: 0.01)
LOCK_WAIT=60     # seconds to wait for lock (default: 35)
POST_WAIT=30     # seconds to observe after spike (default: 20)
sudo tests/run_ptp_integration_test.sh
```

#### 4. Clean up

```bash
sudo tests/cleanup_ptp_test_vms.sh
```

### Manual Testing

If you prefer to run things manually (or debug issues):

```bash
# Get VM IPs
sudo virsh domifaddr ptp-master
sudo virsh domifaddr ptp-client

# SSH into VMs (uses ephemeral key generated during setup)
ssh -i /tmp/ptp_test_ssh/id_ed25519 cloud-user@<master-ip>
ssh -i /tmp/ptp_test_ssh/id_ed25519 cloud-user@<client-ip>

# On master VM:
sudo ptp4l -i enp1s0 -m -S --priority1 100

# On client VM:
cd ~/linuxptp
sudo ./ptp4l -i enp1s0 -f configs/popcorn_filter.cfg -s -m -S -l 7

# Inject spike (on master):
sudo date -s '+0.01 seconds'
```

### Notes

- Software timestamping (`-S`) is used since VMs lack PTP hardware clocks.
  Offset jitter will be higher (~100µs) compared to hardware timestamping.
- The popcorn filter config is at `configs/popcorn_filter.cfg` with
  `popcorn_spike_filter 1` and `popcorn_spike_gate 3`.
- VM access uses an ephemeral SSH key generated at setup time in `/tmp/ptp_test_ssh/`.
