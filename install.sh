#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 proxmox-opencode contributors
#
# Proxmox OpenCode Community Script
# Installs OpenCode Web in an Ubuntu 24.04 LTS VM.
#
# Usage:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/HatchetMan111/OpenCode-Proxmox/main/install.sh)"

set -Eeuo pipefail

readonly APP_NAME="OpenCode"
readonly VM_NAME_DEFAULT="opencode"
readonly HOSTNAME_DEFAULT="opencode"
readonly UBUNTU_VERSION="24.04"
readonly UBUNTU_BASE="https://cloud-images.ubuntu.com/releases/server/24.04/release"
readonly UBUNTU_IMAGE="ubuntu-24.04-server-cloudimg-amd64.img"
readonly OPENCODE_PORT="4096"

VMID=""
VM_NAME="${VM_NAME_DEFAULT}"
HOSTNAME="${HOSTNAME_DEFAULT}"
STORAGE=""
BRIDGE="vmbr0"
DISK="32G"
RAM="8192"
CORES="4"
CI_USER="opencode"
CI_PASSWORD=""
SERVER_PASSWORD=""
IMAGE_PATH=""
SNIPPET_STORAGE=""
SNIPPET_PATH=""
VM_IP=""
KEEP_SNIPPET="no"

cleanup() {
  [[ -n "${SNIPPET_PATH:-}" && "${KEEP_SNIPPET:-no}" != "yes" ]] && rm -f "$SNIPPET_PATH" 2>/dev/null || true
}
trap cleanup EXIT

info() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
ok() { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

trap 'die "Installation abgebrochen in Zeile ${LINENO}: ${BASH_COMMAND}"' ERR

require_root() {
  [[ $EUID -eq 0 ]] || die "Dieses Script muss als root auf einem Proxmox VE Host ausgeführt werden."
  command -v qm >/dev/null || die "Proxmox qm wurde nicht gefunden."
  command -v pvesm >/dev/null || die "Proxmox pvesm wurde nicht gefunden."
  command -v pvesh >/dev/null || die "Proxmox pvesh wurde nicht gefunden."
}

install_dependencies() {
  local packages=()

  command -v curl >/dev/null || packages+=(curl)
  command -v openssl >/dev/null || packages+=(openssl)
  command -v sha256sum >/dev/null || packages+=(coreutils)
  command -v awk >/dev/null || packages+=(gawk)
  command -v jq >/dev/null || packages+=(jq)

  if ((${#packages[@]})); then
    info "Installiere benötigte Host-Pakete: ${packages[*]}"
    apt-get update -qq
    apt-get install -y "${packages[@]}"
  fi
}

choose_storage() {
  if [[ -n "$STORAGE" ]]; then
    pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "Storage '$STORAGE' existiert nicht."
    return
  fi

  local candidate
  for candidate in local-lvm local-zfs local; do
    if pvesm status --storage "$candidate" >/dev/null 2>&1; then
      if pvesm status --storage "$candidate" 2>/dev/null | awk 'NR>1 {print $3}' | grep -q '^active$'; then
        STORAGE="$candidate"
        return
      fi
    fi
  done

  STORAGE="$(pvesm status --content images 2>/dev/null | awk 'NR>1 && $3=="active" && $1 !~ /:/ && $2 != "pbs" {print $1; exit}' || true)"
  [[ -n "$STORAGE" ]] || die "Kein aktiver Storage für VM-Disks gefunden."
}

# Read a single value from `pvesm config <storage>` output. Robust against
# leading whitespace and the "key:" or "key" output formats. Never aborts
# under set -e even when the storage does not exist.
pvesm_cfg() {
  pvesm config "$1" 2>/dev/null | awk -v k="$2" '{gsub(/^[ \t]+/,"")} $1 ~ "^"k":?$" {print $2; exit}' || true
}

choose_snippet_storage() {
  local s cfg_type cfg_path content new_content

  # 1. Use an existing snippets-enabled directory storage.
  while read -r s; do
    [[ -z "$s" || "$s" == *:* ]] && continue
    cfg_type="$(pvesm_cfg "$s" type)"
    cfg_path="$(pvesm_cfg "$s" path)"
    if [[ "$cfg_type" == "dir" && "$cfg_path" == /* && -d "$cfg_path" ]]; then
      SNIPPET_STORAGE="$s"
      return
    fi
  done < <(pvesm status --content snippets 2>/dev/null | awk 'NR>1 && $1 !~ /:/ && $2 != "pbs" {print $1}')

  # 2. Enable snippets on any existing directory storage.
  while read -r s; do
    [[ -z "$s" || "$s" == *:* ]] && continue
    cfg_type="$(pvesm_cfg "$s" type)"
    cfg_path="$(pvesm_cfg "$s" path)"
    [[ "$cfg_type" == "dir" && "$cfg_path" == /* && -d "$cfg_path" ]] || continue

    content="$(pvesm_cfg "$s" content)"
    if [[ "$content" != *snippets* ]]; then
      info "Aktiviere Proxmox-Snippets auf Storage '$s'."
      new_content="$content"
      [[ -n "$new_content" ]] && new_content+=","
      new_content+="snippets"
      pvesm set "$s" --content "$new_content" >/dev/null
    fi
    mkdir -p "$cfg_path/snippets"
    SNIPPET_STORAGE="$s"
    return
  done < <(pvesm status 2>/dev/null | awk 'NR>1 && $1 !~ /:/ && $2 != "pbs" {print $1}')

  # 3. No directory storage at all — create a dedicated one for snippets.
  local new_id="opencode-snippets"
  local new_path="/var/lib/opencode/snippets"

  if pvesm status --storage "$new_id" >/dev/null 2>&1; then
    SNIPPET_STORAGE="$new_id"
    return
  fi

  info "Kein Directory-Storage gefunden. Lege Storage '$new_id' an."
  mkdir -p "$new_path"
  pvesm add dir "$new_id" --path "$new_path" --content snippets >/dev/null
  SNIPPET_STORAGE="$new_id"
}

next_vmid() {
  VMID="$(pvesh get /cluster/nextid)"
  [[ "$VMID" =~ ^[0-9]+$ ]] || die "Konnte keine freie VMID ermitteln."
}

random_password() {
  openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
  printf '\n'
}

prepare_credentials() {
  CI_PASSWORD="$(random_password)"
  SERVER_PASSWORD="$(random_password)"
}

download_image() {
  local dir="/var/lib/vz/template/iso"
  mkdir -p "$dir"
  IMAGE_PATH="$dir/$UBUNTU_IMAGE"

  # Verify the image against Ubuntu's published SHA256. Prints nothing and
  # returns non-zero when the hash does not match.
  verify_image() {
    local sums expected
    sums="$(mktemp)"
    curl -fsSL -o "$sums" "$UBUNTU_BASE/SHA256SUMS"
    expected="$(awk -v f="$UBUNTU_IMAGE" '{sub(/^\*/, "", $2)} $2=="./"f || $2==f {print $1; exit}' "$sums")"
    rm -f "$sums"

    [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || die "SHA256 des Ubuntu Images konnte nicht aus SHA256SUMS gelesen werden."
    printf '%s  %s\n' "$expected" "$IMAGE_PATH" | sha256sum -c - >/dev/null
  }

  if [[ -s "$IMAGE_PATH" ]]; then
    info "Ubuntu Cloud Image ist bereits vorhanden."
    if verify_image; then
      ok "Ubuntu 24.04 LTS Cloud Image verifiziert."
      return
    fi
    warn "Vorhandenes Ubuntu Image ist beschädigt. Lade es erneut herunter ..."
    rm -f "$IMAGE_PATH"
  fi

  info "Lade offizielles Ubuntu 24.04 LTS Cloud Image herunter ..."
  curl -fL --progress-bar -o "$IMAGE_PATH" "$UBUNTU_BASE/$UBUNTU_IMAGE"

  verify_image || die "Ubuntu Cloud Image SHA256-Prüfung fehlgeschlagen."
  ok "Ubuntu 24.04 LTS Cloud Image verifiziert."
}

create_cloud_init() {
  local cfg_path
  cfg_path="$(pvesm_cfg "$SNIPPET_STORAGE" path)"
  [[ -n "$cfg_path" ]] || die "Snippet-Storage '$SNIPPET_STORAGE' hat keinen Directory-Pfad."
  local snippet_dir="$cfg_path/snippets"

  mkdir -p "$snippet_dir"
  SNIPPET_PATH="$snippet_dir/opencode-${VMID}.yaml"

  # Credentials are generated per installation and written only to the VM's
  # cloud-init seed. They are never stored in the Git repository.
  cat >"$SNIPPET_PATH" <<EOF
#cloud-config

package_update: true
package_upgrade: false

packages:
  - ca-certificates
  - curl
  - git
  - jq
  - ripgrep
  - unzip
  - qemu-guest-agent
  - ufw

write_files:
  - path: /etc/opencode/server.env
    owner: root:root
    permissions: '0600'
    content: |
      OPENCODE_SERVER_USERNAME=opencode
      OPENCODE_SERVER_PASSWORD=${SERVER_PASSWORD}

  - path: /usr/local/sbin/opencode-setup
    owner: root:root
    permissions: '0755'
    content: |
      #!/usr/bin/env bash
      set -Eeuo pipefail

      USER="opencode"
      HOME_DIR="/home/opencode"
      BIN="\$HOME_DIR/.opencode/bin/opencode"
      PROJECTS="\$HOME_DIR/projects"

      install -d -o "\$USER" -g "\$USER" "\$PROJECTS"
      install -d -o "\$USER" -g "\$USER" "\$HOME_DIR/.config"
      install -d -o "\$USER" -g "\$USER" "\$HOME_DIR/.local/share"

      if [[ ! -x "\$BIN" ]]; then
        runuser -u "\$USER" -- env HOME="\$HOME_DIR" bash -lc 'curl -fsSL https://opencode.ai/install | bash'
      fi

      test -x "\$BIN"

      cat >/etc/systemd/system/opencode.service <<'UNIT'
      [Unit]
      Description=OpenCode Web Server
      After=network-online.target
      Wants=network-online.target

      [Service]
      Type=simple
      User=opencode
      Group=opencode
      WorkingDirectory=/home/opencode/projects
      Environment=HOME=/home/opencode
      Environment=PATH=/home/opencode/.opencode/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      EnvironmentFile=/etc/opencode/server.env
      ExecStart=/home/opencode/.opencode/bin/opencode web --hostname 0.0.0.0 --port ${OPENCODE_PORT}
      Restart=always
      RestartSec=5
      UMask=0077

      [Install]
      WantedBy=multi-user.target
      UNIT

      cat >/usr/local/bin/opencode-update <<'UPDATE'
      #!/usr/bin/env bash
      set -euo pipefail
      runuser -u opencode -- env HOME=/home/opencode bash -lc 'curl -fsSL https://opencode.ai/install | bash'
      systemctl restart opencode.service
      /home/opencode/.opencode/bin/opencode --version
      UPDATE
      chmod 0755 /usr/local/bin/opencode-update

      cat >/usr/local/bin/opencode-version <<'VERSION'
      #!/usr/bin/env bash
      set -euo pipefail
      /home/opencode/.opencode/bin/opencode --version
      VERSION
      chmod 0755 /usr/local/bin/opencode-version

      # Local-network-only firewall. No public/WAN address is intentionally opened.
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow from 10.0.0.0/8 to any port 4096 proto tcp
      ufw allow from 172.16.0.0/12 to any port 4096 proto tcp
      ufw allow from 192.168.0.0/16 to any port 4096 proto tcp
      ufw allow from 10.0.0.0/8 to any port 22 proto tcp
      ufw allow from 172.16.0.0/12 to any port 22 proto tcp
      ufw allow from 192.168.0.0/16 to any port 22 proto tcp
      ufw --force enable

      chown -R opencode:opencode "\$PROJECTS" "\$HOME_DIR/.config" "\$HOME_DIR/.local/share"

      systemctl daemon-reload
      systemctl enable --now qemu-guest-agent.service
      systemctl enable --now opencode.service

      # Store a non-secret readiness marker.
      install -d -m 0755 /var/lib/opencode
      date -Is >/var/lib/opencode/installed-at
      chmod 0644 /var/lib/opencode/installed-at

runcmd:
  - [bash, -lc, "/usr/local/sbin/opencode-setup > /var/log/opencode-setup.log 2>&1"]
  - [bash, -lc, "cloud-init clean --logs || true"]

final_message: "OpenCode VM provisioning finished."
EOF

  chmod 0600 "$SNIPPET_PATH"
}

create_vm() {
  local mac
  mac="02:$(openssl rand -hex 5 | sed 's/../&:/g;s/:$//')"

  info "Erstelle VM $VMID ..."

  qm create "$VMID" \
    --name "$VM_NAME" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --ostype l26 \
    --agent enabled=1 \
    --onboot 1 \
    --tablet 0 \
    --scsihw virtio-scsi-single \
    --net0 "virtio=${mac},bridge=${BRIDGE}" \
    --serial0 socket \
    --vga serial0 \
    --tags "opencode;ai;community-script"

  info "Importiere Ubuntu Disk ..."
  qm importdisk "$VMID" "$IMAGE_PATH" "$STORAGE" --format raw >/dev/null

  local unused
  unused="$(qm config "$VMID" | awk -F': ' '/^unused0:/{print $2; exit}')"
  [[ -n "$unused" ]] || die "Importierte Ubuntu Disk wurde nicht gefunden."

  qm set "$VMID" --scsi0 "$unused,discard=on,ssd=1" >/dev/null
  qm set "$VMID" --efidisk0 "$STORAGE:0,efitype=4m" >/dev/null
  qm set "$VMID" --ide2 "$STORAGE:cloudinit" >/dev/null

  qm set "$VMID" \
    --ciuser "$CI_USER" \
    --cipassword "$CI_PASSWORD" \
    --ipconfig0 ip=dhcp \
    --nameserver "1.1.1.1 9.9.9.9" \
    --cicustom "user=${SNIPPET_STORAGE}:snippets/$(basename "$SNIPPET_PATH")" \
    --boot "order=scsi0" \
    --description "OpenCode Web - Ubuntu 24.04 LTS - LAN only" \
    >/dev/null

  qm resize "$VMID" scsi0 "$DISK" >/dev/null

  ok "VM $VMID wurde erstellt."
}

get_ip() {
  qm guest cmd "$VMID" network-get-interfaces 2>/dev/null |
    jq -r '
      .[]?["ip-addresses"][]?
      | select(.["ip-address-type"]=="ipv4")
      | .["ip-address"]
    ' 2>/dev/null |
    grep -v '^127\.' |
    head -n1 || true
}

wait_for_ip() {
  info "Starte VM und warte auf QEMU Guest Agent ..."

  qm start "$VMID" >/dev/null

  for _ in {1..120}; do
    VM_IP="$(get_ip)"
    if [[ "$VM_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      ok "VM IP: $VM_IP"
      return
    fi
    sleep 2
  done

  die "Keine IPv4-Adresse über den QEMU Guest Agent erhalten. Prüfe die VM-Konsole."
}

wait_for_service() {
  info "Warte auf OpenCode Web ..."

  for _ in {1..180}; do
    if curl -fsS --max-time 3 -u "opencode:${SERVER_PASSWORD}" \
      "http://${VM_IP}:${OPENCODE_PORT}/global/health" >/dev/null 2>&1; then
      ok "OpenCode Web ist erreichbar."
      return
    fi
    sleep 2
  done

  warn "OpenCode ist noch nicht über den Health-Endpunkt erreichbar."
  warn "Prüfe mit: qm terminal ${VMID}"
  warn "Logs in der VM: journalctl -u opencode -f"
}

print_result() {
  cat <<EOF

============================================================
                 OpenCode ist bereit
============================================================

  Web UI:
    http://${VM_IP}:${OPENCODE_PORT}

  Benutzer:
    opencode

  Web-Passwort:
    ${SERVER_PASSWORD}

  VM:
    ${VMID} (${VM_NAME})

  Ressourcen:
    ${CORES} CPU / ${RAM} MB RAM / ${DISK} Disk

  Projekte:
    /home/opencode/projects

  Update:
    sudo /usr/local/bin/opencode-update

  Version:
    /usr/local/bin/opencode-version

  Service:
    systemctl status opencode

  Logs:
    journalctl -u opencode -f

  Modellanbieter:
    Öffne die Web UI und nutze /connect.
    OpenCode unterstützt 75+ Anbieter und auch lokale Modelle.
    API-/OAuth-Zugangsdaten werden von OpenCode in der VM gespeichert.

============================================================
 LAN-ONLY
============================================================

  Port ${OPENCODE_PORT} wird nur aus privaten IPv4-Netzen
  (10/8, 172.16/12, 192.168/16) durch die VM-Firewall erlaubt.

  Trotzdem keinen Router-Port-Forward auf ${OPENCODE_PORT} setzen.

============================================================

EOF
}

main() {
  require_root
  install_dependencies
  choose_storage
  choose_snippet_storage
  next_vmid
  prepare_credentials

  info "Storage: $STORAGE"
  info "Snippet-Storage: $SNIPPET_STORAGE"
  info "VMID: $VMID"

  download_image
  create_cloud_init
  create_vm
  wait_for_ip
  wait_for_service
  print_result
}

main "$@"
