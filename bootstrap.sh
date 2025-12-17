#!/usr/bin/env bash
set -euo pipefail

# Ensure bash
if [ -z "$BASH_VERSION" ]; then
  echo "Error: run with bash, not sh." >&2
  exit 1
fi

# Check sudo
if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

have() { command -v "$1" >/dev/null 2>&1; }

# basic deps
for bin in git nixos-generate-config nixos-rebuild; do
  if ! have "$bin"; then
    echo "Missing required command: $bin" >&2
    exit 1
  fi
done

# Determine hostname: either from arg or interactively
if [[ $# -ge 1 && -n "${1:-}" ]]; then
  HOSTNAME="$1"
else
  DEFAULT_HOSTNAME="$(hostname)"
  read -rp "Enter hostname for this box [${DEFAULT_HOSTNAME}]: " HOSTNAME
  HOSTNAME="${HOSTNAME:-$DEFAULT_HOSTNAME}"
fi

TARGET_ETC="/etc/nixos"
REPO_URL="https://github.com/roguenand/fleetcommandav-nixos.git"

# 1) Ensure /etc/nixos contains our base repo
if [[ ! -d "$TARGET_ETC/.git" ]]; then
  TS="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="/etc/nixos-pre-bootstrap-${TS}"
  echo "Backing up existing /etc/nixos to $BACKUP_DIR..."
  mv "$TARGET_ETC" "$BACKUP_DIR"

  echo "Cloning base config repo into $TARGET_ETC..."
  git clone "$REPO_URL" "$TARGET_ETC"
else
  echo "/etc/nixos is already a git repo."
  read -rp "Pull latest changes from origin? [y/N]: " PULL
  PULL="${PULL:-N}"
  if [[ "$PULL" =~ ^[Yy]$ ]]; then
    echo "Pulling latest changes..."
    (cd "$TARGET_ETC" && git pull --ff-only || true)
  fi
fi

cd "$TARGET_ETC"

# 2) (Re)generate hardware-configuration.nix for this machine
echo "Generating hardware-configuration.nix..."
nixos-generate-config --show-hardware-config > hardware-configuration.nix

# 3) Ensure host.nix exists (repo should have a template already)
if [[ ! -f host.nix ]]; then
  echo "host.nix not found, creating a new one."
  cat > host.nix <<EOF
{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  networking.hostName = "${HOSTNAME}";
  time.timeZone = "America/New_York";
  zramSwap.memoryPercent = 50;

  services.tailscale = {
    enable = true;
    # useRoutingFeatures = "client";
    # useRoutingFeatures = "server";  # Subnet support
    useRoutingFeatures = "both";  # Subnet + Exit node

    extraUpFlags = [
      "--ssh"
      "--advertise-exit-node"
      # "--advertise-routes=192.168.10.0/24"
      "--hostname=\${config.networking.hostName}"
    ];
  };

  system.stateVersion = "25.11";
}
EOF
fi

# 4) Edit host.nix
echo "Opening /etc/nixos/host.nix in an editor. Edit as needed, then save & exit."
if [[ -n "${EDITOR:-}" ]] && command -v "$EDITOR" >/dev/null 2>&1; then
  "$EDITOR" host.nix
else
  for ed in micro nano vim vi; do
    if command -v "$ed" >/dev/null 2>&1; then
      "$ed" host.nix
      break
    fi
  done
fi

# 5) Switch to the new config
echo "Running nixos-rebuild switch for ${HOSTNAME}..."
nixos-rebuild switch -I nixos-config="${TARGET_ETC}/configuration.nix"

echo "Bootstrap complete for ${HOSTNAME}."
