#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build.sh — Build a hardened Ubuntu 22.04 golden image using QEMU (GPL v2)
# Replaces Packer (BSL) with fully open-source tooling
#
# Runs on: Ubuntu Linux (KVM acceleration required)
#
# Output: output/ubuntu22-hardened.vmdk — ready to import into VMware
#
# Prerequisites:
#   sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils sshpass ansible python3
#   sudo usermod -aG kvm $USER   # log out and back in after this
#   ansible-galaxy install -r ../collections/requirements.yml
#   ~/.ansible_vault_pass must exist
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
VM_NAME="ubuntu22-hardened"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
CLOUD_IMG_FILE="${SCRIPT_DIR}/iso/jammy-server-cloudimg-amd64.img"
DISK_FILE="${SCRIPT_DIR}/output/${VM_NAME}.qcow2"
VMDK_FILE="${SCRIPT_DIR}/output/${VM_NAME}.vmdk"
SEED_DIR="${SCRIPT_DIR}/tmp/seed"
SEED_ISO="${SCRIPT_DIR}/tmp/seed.iso"
DISK_SIZE="20G"
CPUS=2
MEMORY=4096
SSH_PORT=2222
BUILD_USER="builder"
BUILD_PASS="builder123"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

check_linux() {
  if [ "$(uname)" != "Linux" ]; then
    echo "ERROR: This script is Linux-only. Detected OS: $(uname)"
    exit 1
  fi
}

check_kvm() {
  if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm not found. Enable KVM:"
    echo "  sudo usermod -aG kvm \$USER  (then log out and back in)"
    exit 1
  fi
  if [ ! -r /dev/kvm ]; then
    echo "ERROR: No permission to access /dev/kvm."
    echo "  sudo usermod -aG kvm \$USER  (then log out and back in)"
    exit 1
  fi
}

check_deps() {
  local missing=()
  for cmd in qemu-system-x86_64 qemu-img cloud-localds ansible-playbook sshpass python3; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing dependencies: ${missing[*]}"
    echo "  sudo apt-get install -y qemu-system-x86 qemu-utils cloud-image-utils sshpass ansible python3"
    exit 1
  fi
}

wait_for_ssh() {
  log "Waiting for SSH on port ${SSH_PORT} (up to 5 min)..."
  for i in $(seq 1 30); do
    if sshpass -p "${BUILD_PASS}" ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 \
        -o UserKnownHostsFile=/dev/null \
        -p "${SSH_PORT}" "${BUILD_USER}@127.0.0.1" true 2>/dev/null; then
      log "SSH is up."
      return 0
    fi
    echo "  attempt ${i}/30..."
    sleep 10
  done
  echo "ERROR: SSH never came up."
  kill_qemu
  exit 1
}

run_ssh() {
  sshpass -p "${BUILD_PASS}" ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -p "${SSH_PORT}" "${BUILD_USER}@127.0.0.1" "$@"
}

kill_qemu() {
  if [ -f /tmp/qemu-build.pid ]; then
    kill "$(cat /tmp/qemu-build.pid)" 2>/dev/null || true
    rm -f /tmp/qemu-build.pid
  fi
}

cleanup() {
  log "Cleaning up..."
  kill_qemu
  rm -rf "${SEED_DIR}" "${SEED_ISO}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 1 — Checks
# ---------------------------------------------------------------------------
check_linux
check_kvm
check_deps
mkdir -p "${SCRIPT_DIR}/iso" "${SCRIPT_DIR}/output" "${SCRIPT_DIR}/tmp"

# ---------------------------------------------------------------------------
# Step 2 — Download Ubuntu 22.04 cloud image (skip if cached)
# ---------------------------------------------------------------------------
if [ ! -f "${CLOUD_IMG_FILE}" ]; then
  log "Downloading Ubuntu 22.04 cloud image (~600MB)..."
  curl -L --progress-bar -o "${CLOUD_IMG_FILE}" "${CLOUD_IMG_URL}"
else
  log "Using cached cloud image: ${CLOUD_IMG_FILE}"
fi

# ---------------------------------------------------------------------------
# Step 3 — Create working disk from cloud image
# ---------------------------------------------------------------------------
log "Creating working disk (${DISK_SIZE})..."
qemu-img convert -f qcow2 -O qcow2 "${CLOUD_IMG_FILE}" "${DISK_FILE}"
qemu-img resize "${DISK_FILE}" "${DISK_SIZE}"

# ---------------------------------------------------------------------------
# Step 4 — Create cloud-init seed ISO
# ---------------------------------------------------------------------------
log "Creating cloud-init seed ISO..."
mkdir -p "${SEED_DIR}"

BUILD_PASS_HASH=$(python3 -c "import crypt; print(crypt.crypt('${BUILD_PASS}', crypt.mksalt(crypt.METHOD_SHA512)))")

cat > "${SEED_DIR}/user-data" << EOF
#cloud-config
hostname: ubuntu-hardened
users:
  - name: ${BUILD_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: false
    passwd: ${BUILD_PASS_HASH}
    ssh_authorized_keys: []
ssh_pwauth: true
chpasswd:
  expire: false
package_update: true
packages:
  - openssh-server
  - python3
  - python3-apt
runcmd:
  - systemctl enable ssh
  - systemctl start ssh
EOF

cat > "${SEED_DIR}/meta-data" << EOF
instance-id: ubuntu-hardened-build
local-hostname: ubuntu-hardened
EOF

cloud-localds "${SEED_ISO}" "${SEED_DIR}/user-data" "${SEED_DIR}/meta-data"
log "Seed ISO created."

# ---------------------------------------------------------------------------
# Step 5 — Boot VM
# ---------------------------------------------------------------------------
log "Starting VM (KVM accelerated)..."
qemu-system-x86_64 \
  -name "${VM_NAME}" \
  -m "${MEMORY}" \
  -smp "${CPUS}" \
  -machine type=q35,accel=kvm \
  -cpu host \
  -drive file="${DISK_FILE}",if=virtio,format=qcow2 \
  -drive file="${SEED_ISO}",media=cdrom,readonly=on \
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -daemonize \
  -pidfile /tmp/qemu-build.pid

wait_for_ssh

# ---------------------------------------------------------------------------
# Step 6 — Wait for cloud-init to finish
# ---------------------------------------------------------------------------
log "Waiting for cloud-init to complete..."
run_ssh "sudo cloud-init status --wait || true"
log "Cloud-init done."

# ---------------------------------------------------------------------------
# Step 7 — Run Ansible site.yml (common → cis → common post-re-apply)
# ---------------------------------------------------------------------------
log "Running Ansible site.yml..."
ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
  -i "127.0.0.1," \
  -u "${BUILD_USER}" \
  -e "ansible_port=${SSH_PORT}" \
  -e "ansible_ssh_pass=${BUILD_PASS}" \
  -e "ansible_become_pass=${BUILD_PASS}" \
  -e "target=all" \
  --vault-password-file ~/.ansible_vault_pass \
  "${SCRIPT_DIR}/../site.yml"

# ---------------------------------------------------------------------------
# Step 8 — Clean up build user and shut down
# ---------------------------------------------------------------------------
log "Removing build user and shutting down VM..."
run_ssh "sudo userdel -r ${BUILD_USER} 2>/dev/null || true; sudo cloud-init clean --logs; sudo sync; sudo shutdown -P now" || true

log "Waiting for VM to power off..."
sleep 20

# ---------------------------------------------------------------------------
# Step 9 — Convert qcow2 → VMDK for VMware
# ---------------------------------------------------------------------------
log "Converting qcow2 → VMDK (VMware compatible)..."
qemu-img convert \
  -f qcow2 \
  -O vmdk \
  -o adapter_type=lsilogic,subformat=streamOptimized \
  "${DISK_FILE}" \
  "${VMDK_FILE}"

log ""
log "=========================================="
log "Build complete!"
log "Output: ${VMDK_FILE}"
log "Import into VMware: File → New VM → Use existing virtual disk"
log "=========================================="
