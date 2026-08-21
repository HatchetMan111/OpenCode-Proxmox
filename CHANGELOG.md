# Changelog

## 1.9.1

- **SSH ist jetzt optional statt Pflicht (wichtigste Änderung):**
  `wait_for_setup()` prüft den Fertig-Marker (`/var/lib/opencode/installed-at`)
  primär über den QEMU Guest-Agent (`qm guest exec`) — komplett ohne SSH.
  Ein SSH-Fehlschlag führt nie mehr zum Abbruch; vorher brach die Installation
  ab, wenn SSH nach 3 Minuten nicht erreichbar war, obwohl cloud-init das
  Setup längst erfolgreich ausgeführt hätte. SSH wird nur noch einmalig als
  optionaler Fallback versucht, um fehlende Dateien zu übergeben bzw. das
  Setup zu beschleunigen. Architektur damit konsequent:
  Guest-Agent → cloud-init → systemd → OpenCode.
- **Port-4096-Konflikt sauber aufgelöst:** Belegt ein Fremdprozess den Port
  (z.B. manuell gestartetes `opencode web`), wird er jetzt per
  `fuser -k 4096/tcp` beendet, bevor `opencode.service` startet. Ein reines
  `systemctl restart` hätte einen Nicht-systemd-Prozess unberührt gelassen
  und der Dienst wäre trotzdem im ServeError-Loop geblieben.
- `get_ip()` filtert jetzt auch Link-Local-Adressen (`169.254.x.x`), damit
  bei hängendem DHCP nicht eine nutzlose APIPA-Adresse als VM-IP gemeldet
  wird.
- `psmisc` explizit in der VM installiert (für `fuser`).
- Ungenutzte Variablen `HOSTNAME`/`HOSTNAME_DEFAULT` entfernt.

## 1.9.0

- **Fix (Ursache des `volume 'local:snippets/opencode-<VMID>.yaml' does not
  exist`-Startfehlers):** Das Cloud-Init-Snippet wird nicht mehr beim
  Script-Ende gelöscht. Die VM-Konfiguration referenziert es dauerhaft über
  `cicustom` — der komplette `cleanup()`-Exit-Trap (samt `KEEP_SNIPPET`) ist
  entfernt. Das Snippet bleibt absichtlich dauerhaft auf dem Proxmox-Host.
- **Fix (`EACCES: permission denied, mkdir '/home/opencode/.local/state'`):**
  `/home/opencode/.local` und `/home/opencode/.local/state` werden jetzt im
  Setup-Script explizit mit `install -d -o opencode -g opencode -m 0700`
  angelegt, danach zusätzlich `chown -R opencode:opencode /home/opencode`.
- **Port-Konflikt verhindert (ServeError):** Vor dem Start von
  `opencode.service` prüft das Setup-Script per `ss`, ob Port 4096 bereits
  belegt ist, und startet den Dienst dann neu statt erneut zu starten.
  systemd ist damit die einzige Instanz, die OpenCode verwaltet — ein
  manueller `opencode web ...`-Aufruf ist nicht mehr nötig und führt sonst
  nur zum doppelten Port-Bindung-Fehler (`ServeError`).
- `iproute2` explizit in der VM installiert (für den `ss`-Port-Check).

## 1.8.0

- **Fix (Ursache des "hängt bei Warte auf SSH"-Fehlers):** `--cicustom "user=<snippet>"`
  ersetzt bei Proxmox das komplette automatisch generierte Cloud-Init-user-data.
  Dadurch wurden `--ciuser`, `--cipassword` und `--sshkeys` in `create_vm()`
  stillschweigend ignoriert und der SSH-Public-Key kam nie in der VM an —
  root war für SSH und Konsole dauerhaft unerreichbar. SSH-Key, Root-Passwort,
  `ssh_pwauth: true` und `disable_root: false` werden jetzt direkt im
  Cloud-Init-Snippet selbst gesetzt.
- Entfernt die dadurch wirkungslosen `--ciuser/--cipassword/--sshkeys`-Flags aus
  `create_vm()`.
- Neu: Diagnose läuft jetzt primär über den QEMU Guest-Agent (`qm guest exec`),
  der schon lange vor SSH erreichbar ist. Zeigt cloud-init-Status, ob
  `authorized_keys` in der VM angekommen ist, Setup-Log, Service-Status und
  cloud-init-Log — auch wenn SSH nie funktioniert.
- Die SSH-Wartschleife zeigt jetzt live den cloud-init-Status statt eines
  stummen Zählers.
- Neu: informativer (nicht-destruktiver) Hinweis auf VMs mit Tag `opencode`
  aus früheren Versuchen samt Aufräum-Befehl, damit keine verwaisten VMs
  unbemerkt liegen bleiben.
- Entfernt ungenutzte Konstante `UBUNTU_VERSION` (shellcheck SC2034).
- Initial GitHub-ready release.
- Ubuntu 24.04 LTS Cloud Image based VM installation.
- SHA256 verification against Ubuntu's published checksums.
- OpenCode Web systemd service.
- LAN-only UFW rules.
- Generated Web UI credentials.
- OpenCode provider/model setup remains user-configurable.
