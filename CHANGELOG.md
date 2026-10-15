# Changelog

## 2.0.0

- **OpenCode v2:** Der Installer nutzt jetzt den offiziellen v2-Installer
  (`https://opencode.ai/v2/install`, Konstante `OPENCODE_INSTALLER` in
  `install.sh`) statt dem v1-Installer. Es kommt also immer das aktuellste
  v2-Release (`@opencode/cli`) in die VM.
- **Systemd läuft jetzt `opencode serve` statt `opencode web`:** `serve` ist
  laut offizieller v2-Doku die Foreground-Variante für Supervisoren wie
  systemd/Docker (`opencode serve --hostname 0.0.0.0 --port 4096`).
  `OPENCODE_SERVER_USERNAME`/`OPENCODE_SERVER_PASSWORD` aus
  `/etc/opencode/server.env` aktivieren weiterhin HTTP Basic Auth (opt-in).
- **Config angepasst:** `~/.config/opencode/opencode.json` enthält kein
  `server`-Objekt und kein `autoupdate: false` mehr (v1-Schema), sondern nur
  noch `"update": "disable"` (v2-Schema). Hostname/Port kommen aus den
  `serve`-Flags der systemd-Unit.
- **Health-Check angepasst:** Gewartet wird auf HTTP-Antwort von `/`
  (mit Basic Auth). Der v1-Endpoint `/global/health` existiert in v2 nicht
  mehr (v2 nutzt `/api/health` bzw. Session-Cookie/pair-Auth) — jede
  HTTP-Antwort (200/401/302/...) zählt als "Dienst lebt".
- README auf v2-Doku-Links (`/v2/docs/...`) und `serve`-Befehl umgestellt.
- `SCRIPT_VERSION` auf `2.0.0` angehoben.

## 1.10.1

- Dateiserver-Login vereinfacht: `opencode` / `opencode` statt
  `admin` / `admin` (reines Heimnetz, per UFW auf private Netze begrenzt).
- Die Dateiserver-Weboberfläche (`http://<VM-IP>:8080`) wird in der
  Abschluss-Ausgabe zusammen mit Login und Dateien-Verzeichnis angezeigt.

## 1.10.0

- **Neu: Dateiserver (dufs v0.46.0) auf Port 8080.** Web-UI mit Upload per
  Drag&Drop, Foto-Vorschau, Text-Editor im Browser und WebDAV-Zugriff.
  Dateien liegen in `/home/opencode/files`. Standard-Login `admin` / `admin`
  (LAN-only via UFW, bitte nach der Installation mit
  `sudo fileserver-password <neues-passwort>` ändern).
- Bewusst **kein FileBrowser**: Das Projekt ist seit 01.09.2026 archiviert
  (read-only, keine Security-Fixes, offene Lücken bei Command-Execution und
  Sessions). dufs ist aktiv gepflegt und eine einzige statische Binary ohne
  Zusatzabhängigkeiten.
- Neuer systemd-Dienst `fileserver.service` (User `opencode`), mit demselben
  Port-Konflikt-Schutz per `fuser -k` wie `opencode.service`.
- `wait_for_service()` wartet zusätzlich auf den dufs-Health-Endpoint
  (`/__dufs__/health`, ohne Login abfragbar) — nicht fatal, nur Warnung.
- Diagnose (`vm_triage`) und Ergebnis-Ausgabe um den Dateiserver erweitert.

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
