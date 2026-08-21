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
readonly SCRIPT_VERSION="1.8.0"
readonly VM_NAME_DEFAULT="opencode"
readonly HOSTNAME_DEFAULT="opencode"
readonly UBUNTU_BASE="https://cloud-images.ubuntu.com/releases/server/24.04/release"
readonly UBUNTU_IMAGE="ubuntu-24.04-server-cloudimg-amd64.img"
readonly OPENCODE_PORT="4096"

VMID=""
SSH_KEY="/root/.ssh/id_ed25519"
SSH_PUBKEY="${SSH_KEY}.pub"
VM_NAME="${VM_NAME_DEFAULT}"
HOSTNAME="${HOSTNAME_DEFAULT}"
STORAGE=""
BRIDGE="vmbr0"
DISK="32G"
RAM="8192"
CORES="${CORES:-2}"
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

# Read a single property for a storage from /etc/pve/storage.cfg. Storage
# type is stored as the section header ('dir:', 'lvmthin:', ...), everything
# else as indented '<key> <value>' lines. Works on any Proxmox host and
# never aborts under set -e when the storage does not exist.
pvesm_cfg() {
  awk -v s="$1" -v k="$2" '
    /^[^ \t]/ && $1 ~ /:$/ && $2 == s {
      if (k == "type") { sub(/:$/, "", $1); print $1; exit }
      in_section = 1
      next
    }
    in_section && $1 == k { sub(/^[ \t]+/, ""); sub(/^[^ \t]+[ \t]+/, ""); print; exit }
  ' /etc/pve/storage.cfg || true
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

ensure_ssh_key() {
  if [[ ! -f "$SSH_KEY" ]]; then
    command -v ssh-keygen >/dev/null || die "ssh-keygen fehlt."
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    info "Erzeuge SSH-Keysatz für den VM-Zugriff ($SSH_KEY) ..."
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY" -C "opencode-proxmox" >/dev/null || die "SSH-Key konnte nicht erzeugt werden."
  fi
}

# Run a command inside the VM over SSH (root key login). Silent on failure.
sshe() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=5 -o PreferredAuthentications=publickey -o BatchMode=yes \
    "root@${VM_IP}" "$@"
}

ssh_ready() {
  sshe true >/dev/null 2>&1
}

ssh_has_marker() {
  sshe "test -f /var/lib/opencode/installed-at" >/dev/null 2>&1
}

ssh_setup_running() {
  sshe "pgrep -f /usr/local/sbin/opencode-setup >/dev/null" >/dev/null 2>&1
}

# --- Guest-Agent-Diagnose (funktioniert schon, bevor/falls SSH nie klappt) ---
# Der QEMU Guest Agent laeuft schon vor jeglichem SSH-Zugriff (wir nutzen ihn
# bereits in get_ip). Darueber koennen wir Diagnosebefehle in der VM
# ausfuehren, ganz ohne SSH-Login - das ist unsere Rueckfallebene, damit die
# Ausgabe auch dann etwas Nuetzliches zeigt, wenn SSH (noch) nicht geht.

guest_agent_ready() {
  qm agent "$VMID" ping >/dev/null 2>&1
}

# Fuehrt einen Shell-Befehl per Guest-Agent in der VM aus und gibt nur die
# Standardausgabe zurueck. Liefert nichts bei Fehler/Timeout.
gexec_out() {
  local timeout="$1"
  shift
  qm guest exec "$VMID" --timeout "$timeout" -- bash -lc "$*" 2>/dev/null |
    jq -r '.["out-data"] // empty' 2>/dev/null
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

  local pubkey_content
  pubkey_content="$(cat "$SSH_PUBKEY" 2>/dev/null || true)"
  [[ -n "$pubkey_content" ]] || die "SSH-Public-Key '$SSH_PUBKEY' ist leer oder fehlt."

  # Credentials are generated per installation and written only to the VM's
  # cloud-init seed. They are never stored in the Git repository.
  #
  # WICHTIG (root cause of the historical "haengt bei Warte auf SSH"-Bugs):
  # Sobald --cicustom "user=<snippet>" gesetzt ist, ersetzt Proxmox das
  # KOMPLETTE automatisch generierte user-data 1:1 durch dieses Snippet.
  # --ciuser, --cipassword und --sshkeys (siehe create_vm/qm set) werden
  # dabei STILLSCHWEIGEND ignoriert - bestaetigtes, dokumentiertes
  # Proxmox-Verhalten (siehe forum.proxmox.com, Threads 78070, 154766,
  # 170295 u.a.: "Using a custom user snippet overrides the complete user
  # config set via qm set. If you set ciuser/cipassword/sshkeys in the CLI
  # AND add a custom user snippet, only the options in the snippet count.").
  # Der SSH-Key und das Passwort muessen deshalb HIER im Snippet selbst
  # gesetzt werden - sonst bekommt root nie einen Login und jeder SSH-Warte-
  # loop laeuft garantiert in den Timeout, egal wie lange man wartet.
  # Zusaetzlich muss disable_root: false gesetzt werden, weil Ubuntu-Cloud-
  # Images sonst jedem Root-Login per Key ein "Please login as ubuntu..."-
  # Forced-Command unterschieben und die Verbindung sofort wieder trennen.
  cat >"$SNIPPET_PATH" <<EOF
#cloud-config

hostname: opencode
manage_etc_hosts: true

users:
  - name: root
    lock_passwd: false
    ssh_authorized_keys:
      - ${pubkey_content}

ssh_pwauth: true
disable_root: false

chpasswd:
  expire: false
  list: |
    root:${CI_PASSWORD}

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
      # BEGIN_OPENCODE_SETUP
      #!/usr/bin/env bash
      set -Eeuo pipefail
      trap 'echo "FEHLER in Zeile \$LINENO: \$BASH_COMMAND" >&2' ERR

      echo "=== opencode-setup gestartet: \$(date -Is) ==="

      # The cloud-init user is now "root" (ciuser=root), so create the
      # dedicated opencode user here and give it the web password as its
      # shell password as well.
      if ! getent passwd opencode >/dev/null; then
        useradd -m -s /bin/bash opencode
        echo 'opencode ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/opencode
      fi
      if [[ -r /etc/opencode/server.env ]]; then
        local_pw="\$(grep '^OPENCODE_SERVER_PASSWORD=' /etc/opencode/server.env | cut -d= -f2- || true)"
        [[ -n "\$local_pw" ]] && echo "opencode:\$local_pw" | chpasswd
      fi

      export DEBIAN_FRONTEND=noninteractive
      echo "[1/7] Installiere Abhaengigkeiten ..."
      apt-get update
      apt-get install -y ca-certificates curl git jq ripgrep unzip ufw qemu-guest-agent

      USER="opencode"
      HOME_DIR="/home/opencode"
      BIN="\$HOME_DIR/.opencode/bin/opencode"
      PROJECTS="\$HOME_DIR/projects"

      echo "[2/7] Erstelle Verzeichnisse und Konfiguration ..."
      install -d -o "\$USER" -g "\$USER" "\$PROJECTS"
      install -d -o "\$USER" -g "\$USER" "\$HOME_DIR/.config"
      install -d -o "\$USER" -g "\$USER" "\$HOME_DIR/.local/share"
      install -d -o "\$USER" -g "\$USER" "\$HOME_DIR/.config/opencode"

      cat >"\$HOME_DIR/.config/opencode/opencode.json" <<'JSON'
      {
        "\$schema": "https://opencode.ai/config.json",
        "autoupdate": false,
        "server": {
          "port": ${OPENCODE_PORT},
          "hostname": "0.0.0.0",
          "mdns": false
        }
      }
      JSON
      chown "\$USER:\$USER" "\$HOME_DIR/.config/opencode/opencode.json"

      echo "[3/7] Installiere OpenCode ..."
      if [[ ! -x "\$BIN" ]]; then
        runuser -u "\$USER" -- env HOME="\$HOME_DIR" bash -lc 'curl -fsSL https://opencode.ai/install | bash'
      fi
      test -x "\$BIN"

      echo "[4/7] Erstelle systemd-Unit ..."
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

      echo "[5/7] Konfiguriere Firewall ..."
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

      echo "[6/7] Bereite Verzeichnisse vor ..."
      chown -R opencode:opencode "\$PROJECTS" "\$HOME_DIR/.config" "\$HOME_DIR/.local/share"

      echo "[7/7] Starte Dienste ..."
      systemctl daemon-reload
      systemctl enable --now qemu-guest-agent.service
      systemctl enable --now opencode.service

      # Store a non-secret readiness marker.
      install -d -m 0755 /var/lib/opencode
      date -Is >/var/lib/opencode/installed-at
      chmod 0644 /var/lib/opencode/installed-at

      echo "=== opencode-setup abgeschlossen: \$(date -Is) ==="
      # END_OPENCODE_SETUP

runcmd:
  - [bash, -lc, "/usr/local/sbin/opencode-setup > /var/log/opencode-setup.log 2>&1"]

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

  # Kein --ciuser/--cipassword/--sshkeys hier: die sind durch --cicustom
  # "user=..." unten sowieso wirkungslos (siehe Kommentar in
  # create_cloud_init). Root-Zugang kommt komplett aus dem Snippet.
  qm set "$VMID" \
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

# Sammelt Diagnosedaten aus der VM. Nutzt in erster Linie den QEMU
# Guest-Agent (der laeuft schon lange bevor SSH je klappen wuerde), SSH nur
# ergaenzend falls es bereits erreichbar ist. So zeigt die Ausgabe auch dann
# etwas Brauchbares, wenn SSH komplett hangt.
vm_triage() {
  echo
  info "Sammle Diagnose aus der VM ..."

  if guest_agent_ready; then
    echo "----- Guest-Agent-Diagnose (ohne SSH) -----"

    echo "cloud-init Status:"
    gexec_out 10 "cloud-init status --long 2>&1 || echo '<cloud-init-Status nicht abrufbar>'"

    echo
    echo "Root-SSH-Zugang vorbereitet? (das war die Ursache frueherer Haenger)"
    gexec_out 5 "test -s /root/.ssh/authorized_keys && printf 'authorized_keys vorhanden (%s Zeile/n)\n' \"\$(wc -l < /root/.ssh/authorized_keys)\" || echo 'authorized_keys FEHLT -> SSH-Key kam nicht in der VM an'"

    echo
    echo "opencode-setup / server.env vorhanden?"
    gexec_out 5 "test -x /usr/local/sbin/opencode-setup && echo 'setup-script vorhanden' || echo 'setup-script FEHLT'"
    gexec_out 5 "test -f /etc/opencode/server.env && echo 'server.env vorhanden' || echo 'server.env FEHLT'"

    echo
    echo "/var/log/opencode-setup.log (Ende):"
    gexec_out 5 "tail -n 30 /var/log/opencode-setup.log 2>/dev/null || echo '<kein Setup-Log>'"

    echo
    echo "opencode.service:"
    gexec_out 5 "systemctl is-active opencode 2>/dev/null || echo '<inaktiv>'"
    gexec_out 6 "journalctl -u opencode -n 20 --no-pager 2>/dev/null || echo '<kein Journal>'"

    echo
    echo "/var/log/cloud-init.log (Ende, evtl. Fehlerursache):"
    gexec_out 8 "tail -n 20 /var/log/cloud-init.log 2>/dev/null || echo '<kein cloud-init.log>'"
  else
    warn "Guest-Agent antwortet gerade nicht - VM bootet evtl. noch."
  fi

  if ssh_ready; then
    echo
    echo "----- Zusaetzliche SSH-Diagnose -----"
    sshe "test -s /var/lib/cloud/instance/user-data.txt 2>/dev/null && echo user-data vorhanden || echo user-data FEHLT" 2>/dev/null || true
  fi

  echo "----- Ende Diagnose -----"
}

wait_for_ip() {
  info "Starte VM und warte auf QEMU Guest Agent ..."

  if ! qm start "$VMID" >/dev/null 2>&1; then
    # Some nodes restrict the number of vCPUs per VM (e.g. "MAX 2 vcpus
    # allowed per VM on this node"). Detect the limit and re-adjust.
    local err maxv
    err="$(qm start "$VMID" 2>&1 || true)"
    maxv="$(printf '%s' "$err" | grep -oiE 'MAX [0-9]+ vcpus' | grep -oE '[0-9]+' | head -n1)"
    if [[ -n "$maxv" ]]; then
      warn "Knoten erlaubt maximal ${maxv} vCPUs pro VM. Reduziere Cores auf ${maxv}."
      qm set "$VMID" --cores "$maxv" >/dev/null
      CORES="$maxv"
      ok "VM-Konfiguration angepasst (Cores=${maxv})."
      qm start "$VMID" >/dev/null || die "VM-Start fehlgeschlagen."
    else
      warn "VM-Start fehlgeschlagen."
      die "${err:-Fehler beim Starten der VM}"
    fi
  fi

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

# Wait for opencode-setup to finish inside the VM, driving it over SSH.
wait_for_setup() {
  local i

  info "Warte bis opencode-setup in der VM abgeschlossen ist (bis zu 15 Min) ..."

  # 0) Wait until the VM accepts SSH as root (cloud-init injected our key).
  info "Warte auf SSH-Zugang zur VM (root@${VM_IP}) ..."
  for i in {1..36}; do
    if ssh_ready; then
      ok "SSH-Zugang verfügbar."
      break
    fi
    if (( i % 6 == 0 )); then
      local ci_status=""
      if guest_agent_ready; then
        ci_status="$(gexec_out 5 "cloud-init status 2>&1")"
      fi
      info "Warte auf SSH ... (${i}/36)${ci_status:+ — cloud-init: ${ci_status}}"
    fi
    sleep 5
  done
  if ! ssh_ready; then
    if timeout 3 bash -c "</dev/tcp/${VM_IP}/22" >/dev/null 2>&1; then
      warn "SSH-Port 22 an ${VM_IP} ist NICHT erreichbar (Netzwerk/Firewall?)."
    else
      warn "SSH-Port 22 ist offen, aber Root-Login mit dem Key schlägt fehl."
      warn "(Frueher meist: authorized_keys fehlt in der VM - siehe Diagnose unten.)"
    fi
    warn "Kein SSH-Zugang zu ${VM_IP}."
    return 1
  fi

  # 1) Push the provisioning files if they are missing.
  if ! sshe "test -x /usr/local/sbin/opencode-setup" >/dev/null 2>&1; then
    info "Übergebe opencode-setup und server.env per SSH in die VM ..."
    sed -n '/# BEGIN_OPENCODE_SETUP/,/# END_OPENCODE_SETUP/p' "$SNIPPET_PATH" | \
      sed '1d;$d' | sed 's/^      //' |
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "root@${VM_IP}" \
        'cat > /usr/local/sbin/opencode-setup && chmod 0755 /usr/local/sbin/opencode-setup' 2>/dev/null || true
    printf 'OPENCODE_SERVER_USERNAME=opencode\nOPENCODE_SERVER_PASSWORD=%s\n' "$SERVER_PASSWORD" |
      ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=5 "root@${VM_IP}" \
        'install -d -m 0700 /etc/opencode && cat > /etc/opencode/server.env && chmod 0600 /etc/opencode/server.env' 2>/dev/null || true
  fi
  if ! sshe "test -x /usr/local/sbin/opencode-setup" >/dev/null 2>&1; then
    warn "Übertragen der Dateien per SSH fehlgeschlagen."
    return 1
  fi
  ok "opencode-setup und server.env sind in der VM."

  # 2) Start the setup only if it has not run yet (marker check) and is not
  #    already being driven by cloud-init's runcmd.
  if ! ssh_has_marker && ! ssh_setup_running; then
    info "Starte opencode-setup in der VM (per SSH) ..."
    sshe "nohup /usr/local/sbin/opencode-setup > /var/log/opencode-setup.log 2>&1 < /dev/null &" >/dev/null 2>&1 || true
  fi

  # 3) Wait for the marker.
  for i in {1..120}; do
    if ssh_has_marker; then
      ok "opencode-setup abgeschlossen (Marker gefunden)."
      return 0
    fi
    if (( i % 12 == 0 )); then
      info "Warte auf opencode-setup ... (${i}/120)"
    fi
    sleep 5
  done

  warn "opencode-setup wurde in 10 Minuten nicht abgeschlossen."
  return 1
}

wait_for_service() {
  local port=0 http_code i
  info "Warte auf OpenCode Web (bis zu 10 Minuten, erste Einrichtung läuft) ..."

  for i in {1..300}; do
    if timeout 3 bash -c "</dev/tcp/${VM_IP}/${OPENCODE_PORT}" >/dev/null 2>&1; then
      port=1
      if curl -fsS --max-time 3 -u "opencode:${SERVER_PASSWORD}" \
        "http://${VM_IP}:${OPENCODE_PORT}/global/health" >/dev/null 2>&1; then
        ok "OpenCode Web ist erreichbar."
        return
      fi
      http_code="$(curl -s --max-time 3 -u "opencode:${SERVER_PASSWORD}" \
        -o /dev/null -w '%{http_code}' "http://${VM_IP}:${OPENCODE_PORT}/" 2>/dev/null || true)"
      if [[ "$http_code" =~ ^[0-9]{3}$ ]]; then
        ok "OpenCode Web antwortet (HTTP ${http_code})."
        return
      fi
    fi
    if (( i % 30 == 0 )); then
      local snippet
      snippet="$(gexec_out 5 "tail -n 1 /var/log/opencode-setup.log 2>/dev/null")"
      [[ -n "$snippet" ]] || snippet="opencode-setup-Log noch leer/nicht vorhanden"
      info "Warte weiter ... (${i}/300) — ${snippet}"
    fi
    sleep 2
  done

  warn "OpenCode Web ist noch nicht bereit."
  if [[ "$port" -eq 1 ]]; then
    warn "Der Port ${OPENCODE_PORT} ist offen, aber der Dienst startet vermutlich gerade."
  else
    warn "Der Port ${OPENCODE_PORT} ist (noch) nicht erreichbar."
    warn "Die Ersteinrichtung dauert nach dem Boot einige Minuten."
  fi

  vm_triage
  sleep 150
  warn "Zweite Diagnose (falls cloud-init noch lief) ..."
  vm_triage

  warn "Falls die Diagnose leer bleibt, läuft cloud-init in der VM noch und der"
  warn "Guest-Agent antwortet noch nicht. Prüfe dann von Hand:"
  warn "  qm terminal ${VMID}"
  warn "    systemctl status opencode"
  warn "    journalctl -u opencode -e"
  warn "    cat /var/log/opencode-setup.log"
  warn "    ip a"
}

print_result() {
  cat <<EOF

============================================================
                 OpenCode ist bereit
============================================================

  🌐  Web-UI im Browser öffnen:

       http://${VM_IP}:${OPENCODE_PORT}

  📋  Login (beim ersten Screen der Web-UI):

       Benutzer:      opencode
       Web-Passwort:  ${SERVER_PASSWORD}

------------------------------------------------------------
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
    Öffne die Web-UI und nutze /connect.
    OpenCode unterstützt 75+ Anbieter und auch lokale Modelle.
    API-/OAuth-Zugangsdaten werden von OpenCode in der VM gespeichert.

============================================================
 LAN-ONLY
============================================================

  Port ${OPENCODE_PORT} wird nur aus privaten IPv4-Netzen
  (10/8, 172.16/12, 192.168/16) durch die VM-Firewall erlaubt.

  Trotzdem keinen Router-Port-Forward auf ${OPENCODE_PORT} setzen.

============================================================
 TROUBLESHOOTING
============================================================

  Falls das Dashboard nicht lädt, verbinde dich zur VM:

    qm terminal ${VMID}

  und prüfe:

    a. IP prüfen:  ip a
    b. Dienst:     systemctl status opencode
    c. Logs:       journalctl -u opencode -e
    d. Setup-Log:  cat /var/log/opencode-setup.log

  Die Ersteinrichtung installiert nach dem ersten Boot noch
  einige Minuten lang Pakete und OpenCode.

============================================================

EOF
}

# Rein informativ: weist auf VMs mit dem Tag "opencode" aus frueheren
# (evtl. fehlgeschlagenen) Laeufen hin. Wird NICHTS geloescht oder
# automatisch angefasst - jeder Lauf legt bewusst eine frische VM an, damit
# nie versehentlich eine noch benutzte Installation angetastet wird.
list_existing_opencode_vms() {
  local id name status found=0
  while read -r id name status; do
    [[ -n "$id" ]] || continue
    if qm config "$id" 2>/dev/null | grep -q '^tags:.*opencode'; then
      warn "Vorhandene VM ${id} (${name}, Status: ${status}) traegt bereits den Tag 'opencode' - evtl. Rest eines frueheren Versuchs."
      warn "  Aufraeumen falls nicht mehr gebraucht: qm stop ${id}; qm destroy ${id} --purge"
      found=1
    fi
  done < <(qm list 2>/dev/null | awk 'NR>1 {print $1, $2, $3}')
  [[ "$found" -eq 1 ]] && echo
  return 0
}

main() {
  info "${APP_NAME}-Proxmox Installer v${SCRIPT_VERSION}"
  require_root
  install_dependencies
  list_existing_opencode_vms
  choose_storage
  choose_snippet_storage
  next_vmid
  prepare_credentials
  ensure_ssh_key

  info "Storage: $STORAGE"
  info "Snippet-Storage: $SNIPPET_STORAGE"
  info "VMID: $VMID"

  download_image
  create_cloud_init
  [[ -s "$SNIPPET_PATH" ]] || die "Snippet '$SNIPPET_PATH' konnte nicht geschrieben werden."
  create_vm
  wait_for_ip
  if wait_for_setup; then
    wait_for_service
    print_result
  else
    vm_triage
    warn "Die Installation in der VM war nicht erfolgreich."
    warn "Verbinde dich zur VM-Konsole und prüfe:"
    warn "  qm terminal ${VMID}"
    warn "  Login: root / ${CI_PASSWORD}"
    warn "  cloud-init status --long"
    warn "  cat /var/log/opencode-setup.log"
    die "OpenCode-Installation in der VM fehlgeschlagen — siehe Diagnose oben."
  fi
}

main "$@"
