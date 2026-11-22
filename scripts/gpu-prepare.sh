#!/usr/bin/env bash
# Prepares a Vultr Cloud GPU server for the GPU tier: NVIDIA driver check + Docker + NVIDIA container toolkit.
# Usage (as root, from the kit root):  bash scripts/gpu-prepare.sh       then:  bash scripts/bootstrap-target.sh gpu
source "$(dirname "$0")/lib.sh"
require_root

if ! nvidia-smi >/dev/null 2>&1; then
  log "No NVIDIA driver found. Trying Ubuntu's recommended datacenter driver"
  apt-get update -q && apt-get install -y -q ubuntu-drivers-common
  ubuntu-drivers install --gpgpu || true
  echo
  echo "Driver installed (or attempted). REBOOT now (reboot), then run this script again."
  echo "If nvidia-smi still fails after the reboot, redeploy the server with Vultr's GPU-ready OS image"
  echo "(Vultr's GPU images ship the matching NVIDIA/vGPU driver)."
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv

install_docker
if ! command -v nvidia-ctk >/dev/null; then
  log "Installing NVIDIA container toolkit"
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -q && apt-get install -y -q nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
fi

log "Checking that containers can see the GPU"
docker run --rm --gpus all ghcr.io/ggml-org/llama.cpp:server-cuda --version 2>&1 | tail -3 || die "container cannot use the GPU"
log "GPU ready. Next: bash scripts/bootstrap-target.sh gpu"
