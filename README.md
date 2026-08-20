# Proxmox OpenCode

One-command installer for running **OpenCode Web** permanently inside an isolated Ubuntu 24.04 LTS virtual machine on Proxmox VE.

> This project is community-maintained and is not affiliated with or endorsed by OpenCode, Proxmox or Canonical.

## What it does

The installer runs on a Proxmox VE host and automatically:

- creates a dedicated Ubuntu 24.04 LTS VM
- chooses a free VM ID
- downloads the official Ubuntu Cloud Image
- verifies the image with Ubuntu's published SHA256 checksum
- configures Cloud-Init
- installs QEMU Guest Agent
- installs OpenCode using the official installer
- runs `opencode web` as a systemd service
- starts OpenCode automatically after reboots
- creates `/home/opencode/projects`
- protects the Web UI with HTTP Basic Authentication
- enables a VM firewall that only permits OpenCode from private IPv4 networks
- prints the VM IP and Web UI URL when installation is complete

Ubuntu publishes official 24.04 LTS Cloud Images and SHA256 checksums:
https://cloud-images.ubuntu.com/releases/server/24.04/release/

OpenCode documents `opencode web --hostname 0.0.0.0`, port 4096, HTTP Basic Authentication and mDNS:
https://opencode.ai/docs/web/

## One-line installation

After publishing this repository to GitHub, run the following on your **Proxmox VE host as root**:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOUR-USER/proxmox-opencode/main/install.sh)"
```

Replace `YOUR-USER` with your GitHub username.

## Result

At the end, the installer prints something like:

```text
============================================================
                 OpenCode ist bereit
============================================================

  Web UI:
    http://192.168.178.123:4096

  Benutzer:
    opencode

  Web-Passwort:
    xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

  VM:
    120 (opencode)

============================================================
```

Open the displayed address in a browser on your LAN.

## Model providers

The VM does **not** hard-code a single AI provider.

OpenCode currently supports 75+ LLM providers and local models. Provider credentials can be configured from OpenCode using:

```text
/connect
```

Models can then be selected using:

```text
/models
```

See the official OpenCode provider documentation:

https://opencode.ai/docs/providers/

and model documentation:

https://opencode.ai/docs/models/

This means the same server can be used with the providers available to your OpenCode installation instead of limiting the VM to one model vendor.

### Important

The installer cannot magically provide paid models without credentials/subscriptions. You still need to authenticate the providers you want to use.

## LAN-only security

The VM listens on:

```text
0.0.0.0:4096
```

because that is required for other devices on the LAN to reach the Web UI.

The VM's UFW firewall only allows TCP/4096 from:

- `10.0.0.0/8`
- `172.16.0.0/12`
- `192.168.0.0/16`

SSH is restricted to the same private IPv4 ranges.

### Router

Do **not** create a port-forward from the Internet to port `4096`.

For remote access, use a VPN such as WireGuard or Tailscale rather than exposing OpenCode directly to the Internet.

## VM defaults

| Setting | Default |
|---|---:|
| OS | Ubuntu Server 24.04 LTS |
| CPU | 4 vCPU |
| RAM | 8 GB |
| Disk | 32 GB |
| Network | DHCP |
| Bridge | `vmbr0` |
| OpenCode port | `4096` |
| VM name | `opencode` |
| Project directory | `/home/opencode/projects` |

## OpenCode service

OpenCode runs as:

```text
systemctl status opencode
```

Follow logs:

```bash
journalctl -u opencode -f
```

The server is configured with:

```bash
opencode web --hostname 0.0.0.0 --port 4096
```

OpenCode's official Web documentation describes the same server mode and HTTP Basic Authentication via `OPENCODE_SERVER_PASSWORD`.

## Updating OpenCode

Inside the VM:

```bash
sudo /usr/local/bin/opencode-update
```

Check the installed version:

```bash
/usr/local/bin/opencode-version
```

## Accessing the VM

The installer creates the Linux user:

```text
opencode
```

The generated password is printed once at the end of the installation.

You can also use the Proxmox console:

```text
VM → Console
```

## Backups

The OpenCode state, authentication data, sessions and projects live inside the VM.

For a homelab setup, back up the entire Proxmox VM.

In particular, do not publish:

- OpenCode provider credentials
- API keys
- OAuth tokens
- generated passwords
- `/home/opencode/.local/share/opencode/`
- private project repositories

## Requirements

- Proxmox VE
- x86_64/AMD64 host
- root access on the Proxmox host
- an active network bridge, normally `vmbr0`
- Internet access from the Proxmox host during installation
- enough storage for the Ubuntu image and VM disk

## Repository layout

```text
proxmox-opencode/
├── install.sh
├── README.md
├── LICENSE
├── .gitignore
└── CHANGELOG.md
```

## Disclaimer

This script creates a VM, installs packages and changes firewall configuration inside that VM.

Review the script before running it on production infrastructure.

Use backups and test it on a non-critical Proxmox host first.

## License

MIT License. See `LICENSE`.

OpenCode, Ubuntu and Proxmox are trademarks and/or projects of their respective owners.
