# Dev-Container für backlog-manager

Podman-Container für die Entwicklung des Backlog Managers, für Dauerbetrieb in einem **privilegierten** Debian-LXC auf Proxmox. Claude Code läuft darin per Remote Control, steuerbar über die Claude-App.

## Inhalt des Images

| Bereich | Enthalten |
|---|---|
| Basis | Debian trixie (slim), läuft als `root` |
| Claude Code | Nativer Installer, Config unter `~/.claude` |
| Flutter | Stable, Linux-Desktop-Target, Dart; Analytics deaktiviert |
| Node | Node.js 22 |
| Python | uv/uvx |
| Git/GitHub | git, gh, openssh-client |
| Code-Review | CodeRabbit CLI + `review`-Skript mit Ollama-Fallback (siehe unten) |
| Task-Runner | go-task (`task --list`) |
| Container | podman-remote, podman-compose |
| Datenbank | postgresql-client |

Nicht enthalten: Chromium/Flutter Web, Rust/Tauri, Java.

## Voraussetzungen im LXC

1. LXC **privilegiert** anlegen (Proxmox: "Unprivileged container" abwählen, oder `unprivileged: 0` in `/etc/pve/lxc/<id>.conf` + Neustart), dazu `nesting=1` und `keyctl=1`.
2. Podman-Socket systemweit aktivieren: `systemctl enable --now podman.socket` (liegt dann unter `/run/podman/podman.sock`).
3. Leeres Clone-Ziel anlegen: `mkdir -p ~/work/backlog-manager`. Nur dafür - `Containerfile`/`compose.yaml` gehören in ein eigenes Verzeichnis, sonst ist der Ordner nicht mehr leer und der Clone beim Start schlägt mit `destination path already exists` fehl.

## Build und Start

Nötige Dateien statt Copy-Paste herunterladen:

```bash
mkdir -p ~/claude-devcontainer && cd ~/claude-devcontainer
curl -fsSLO https://raw.githubusercontent.com/theoleuthardt/claude-devcontainer/main/compose.yaml

# nur für lokalen Build zusätzlich nötig:
curl -fsSLO https://raw.githubusercontent.com/theoleuthardt/claude-devcontainer/main/compose.build.yaml
curl -fsSLO https://raw.githubusercontent.com/theoleuthardt/claude-devcontainer/main/Containerfile
mkdir -p scripts && curl -fsSL -o scripts/review.sh https://raw.githubusercontent.com/theoleuthardt/claude-devcontainer/main/scripts/review.sh
```

```bash
# fertiges ghcr.io-Image
podman-compose pull && podman-compose up -d

# oder lokal bauen
podman-compose -f compose.yaml -f compose.build.yaml up -d --build
```

Ohne compose, per `podman run`:

```bash
podman run -d --name blm-dev \
  --network=host \
  -v ~/work/backlog-manager:/workspace \
  -v /run/podman/podman.sock:/run/podman.sock \
  -v blm-claude:/root/.claude \
  -v blm-gh:/root/.config/gh \
  --init --restart=unless-stopped \
  ghcr.io/theoleuthardt/claude-devcontainer:latest   # oder ein lokal gebautes blm-dev
```

`.github/workflows/build-image.yml` baut das Image bei jedem relevanten Push auf `main` und pusht nach `ghcr.io/theoleuthardt/claude-devcontainer:latest`/`:<sha>`.

## Erste Einrichtung (einmalig, im Container)

```bash
podman exec -it blm-dev tmux attach -t claude
```

Zuerst eine Fehlermeldung, weil Claude Code noch nicht angemeldet ist (normal). Mit `Strg-b c` ein zweites Fenster öffnen und dort einrichten:

| Schritt | Befehl | Persistenz |
|---|---|---|
| Claude Code | `claude` in `/workspace`, `/login`, Ordner-Vertrauen bestätigen, beenden | Volume `blm-claude` |
| GitHub | `gh auth login && gh auth setup-git` | Volume `blm-gh` |
| CodeRabbit | `coderabbit auth login --api-key "cr-..."` | nicht persistent |
| Git-Identität | `git config --global user.name/user.email` | nicht persistent |

Danach verbindet sich Fenster 0 beim nächsten Retry (alle 15s) selbst. Fenster/Session verlassen ohne sie zu killen: `Strg-b d` (nicht `exit`, das beendet die Session).

## Remote Control

Verbindet Claude-App/claude.ai/code mit der Claude-Code-Session im Container. Standard hier: Server-Modus (`claude remote-control`).

- Anmeldung nur per claude.ai-Abo über `/login`. API-Keys/Tokens funktionieren nicht.
- Kein `ANTHROPIC_BASE_URL`, kein LLM-Gateway - eigener Endpunkt schaltet Remote Control ab.
- Nicht setzen: `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`.

## Review mit Ollama-Fallback

`review [base-branch]` (Default `main`) läuft `coderabbit review --agent`, bei Fehlschlag Fallback auf Ollama. Ausgabe beider Quellen ist NDJSON im CodeRabbit-`--agent`-Schema (`type`, `severity`, `fileName`, `codegenInstructions`, `suggestions`, `comment`), damit Claude sie gleich behandeln kann.

Weder `OLLAMA_REVIEW_MODEL` noch `OLLAMA_API_KEY` stehen im Image - in der eigenen `compose.yaml` ergänzen, Key nicht im Klartext, sondern über `.env` (gitignored):

```yaml
services:
  blm-dev:
    environment:
      OLLAMA_REVIEW_MODEL: <modellname>
    env_file: .env   # enthält OLLAMA_API_KEY=...
```

Danach `podman-compose up -d --force-recreate`.

| Variable | Bedeutung | Standard |
|---|---|---|
| `OLLAMA_REVIEW_MODEL` | Fallback-Modell, ohne Wert kein Fallback | nicht gesetzt |
| `OLLAMA_URL` | Ollama-Server | `https://ollama.com` (Cloud) |
| `OLLAMA_API_KEY` | Bearer-Token für Ollama Cloud | nicht gesetzt |
| `OLLAMA_NUM_CTX` | Kontextfenster | `65536` |
| `REVIEW_MAX_BYTES` | max. Diff-Größe | `150000` |

Für einen lokalen Server statt Cloud: `OLLAMA_URL=http://127.0.0.1:11434` (dank `--network=host`), kein Key nötig.

**Exit-Codes:** `0` geliefert, `1` Fallback nicht konfiguriert, `2` beide Quellen fehlgeschlagen. Ollama sieht nur den Diff, nicht das Repo - als zweite Meinung behandeln, Befunde gegen den Code prüfen.

**Claude nutzt `review` statt des eigenen `/code-review`-Skills:** `blm-start` schreibt die Regel (`scripts/claude-review-rule.md`) beim ersten Boot nach `~/.claude/CLAUDE.md`, falls die Datei noch nicht existiert (eigene Edits dort bleiben danach unberührt). Kein manueller Schritt nötig - nur falls `~/.claude/CLAUDE.md` schon vor dem ersten Start existierte (z. B. Volume von einem älteren Setup übernommen), die Regel von Hand ergänzen.

## Testcontainers & podman im Container

- `DOCKER_HOST=unix:///run/podman.sock` - Testcontainers sprechen mit dem Podman des LXC, Geschwister-Container landen direkt dort.
- `TESTCONTAINERS_RYUK_DISABLED=true` (Ryuk macht mit Podman Probleme) - Reste selbst aufräumen: `podman ps -a` / `podman rm -f`.
- Ohne `--network=host` zusätzlich `TESTCONTAINERS_HOST_OVERRIDE=host.containers.internal` setzen.
- Im Container gibt es nur `podman-remote`; ein `/usr/local/bin/podman`-Wrapper ruft es auf, weil `podman-compose` intern `podman` erwartet.

## Flutter

- Linux-Desktop aktiviert, `flutter build linux` / `flutter test` laufen im Container.
- Integrationstests ohne Display: `xvfb-run flutter test integration_test -d linux`.
- Kein Windows/macOS/iOS-Build (braucht Mac bzw. passende CI-Runner), keine sichtbare GUI-Ausgabe (kein Display im Container).

## Sicherheit

LXC ist privilegiert, Container läuft als root mit Zugriff auf den System-Podman-Socket - wer den Container kontrolliert, kontrolliert praktisch den ganzen LXC. Deshalb: eigenen, isolierten LXC nur für diesen Dev-Container verwenden, keinen mit produktiven Diensten drauf.

## Fehlersuche

| Symptom | Ursache |
|---|---|
| Remote Control erscheint nicht in der App | Noch nicht angemeldet, oder gesperrtes Setup (Gateway, Telemetrie-Variablen) |
| `Clone fehlgeschlagen` | Clone-Ziel nicht leer (z. B. `compose.yaml` liegt versehentlich darin) oder kein Netzwerk |
| `tmux attach -t claude` → `no sessions` | In Fenster 0 wurde `exit` statt `Strg-b d` getippt - `podman restart blm-dev` behebt es |
| Testcontainers finden keinen Docker-Host | Socket nicht gemountet oder `podman.socket` im LXC nicht aktiv |
| `crun: mount sysfs to sys: Operation not permitted` beim Start | LXC ist nicht privilegiert |
| Container-Ports nicht erreichbar | Container ohne `--network=host` gestartet |
