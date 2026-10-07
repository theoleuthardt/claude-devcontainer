# Dev-Container für backlog-manager

Podman-Container für die Entwicklung des Backlog Managers, gedacht für den Dauerbetrieb in einem Debian-LXC auf Proxmox. Claude Code läuft darin per Remote Control und ist über die Claude-App steuerbar.

## Inhalt des Images

| Bereich | Enthalten |
|---|---|
| Basis | Debian trixie (slim), Nutzer `dev` (UID/GID per Build-Arg) |
| Claude Code | Nativer Installer (`claude`), Konfiguration unter `~/.claude` |
| Flutter | Stable-Kanal, Linux-Desktop-Target, Dart; Analytics deaktiviert |
| Flutter-Linux-Abhängigkeiten | clang, cmake, ninja-build, libgtk-3-dev, libglu1-mesa |
| Headless-Tests | xvfb, libgl1-mesa-dri, libegl1 |
| Node | Node.js 22 (NodeSource) |
| Python | uv/uvx (verwaltet Python selbst, z. B. für das Litestar-Backend) |
| Git/GitHub | git, gh (GitHub CLI), openssh-client |
| Code-Review | CodeRabbit CLI, dazu das Skript `review` mit Ollama-Fallback (siehe [Review mit Ollama-Fallback](#review-mit-ollama-fallback)) |
| Task-Runner | go-task (`task`) für die `Taskfile.yml` des Repos (`task --list` zeigt alle Befehle) |
| Container | podman-remote, podman-compose, `podman`-Wrapper |
| Datenbank | postgresql-client (`psql`) |
| Sonstiges | build-essential, pkg-config, unzip, xz-utils, zip, jq, ripgrep, less, procps, nano, tmux |

Nicht enthalten: Chromium/Flutter Web, Rust/Tauri, Java (siehe [Optionale Erweiterungen](#optionale-erweiterungen)).

## Funktionsweise

- **Podman-Container im LXC (rootless):** Der Dev-Container läuft als normaler Podman-Container im LXC, nicht verschachtelt.
- **Socket durchreichen:** Der Podman-Socket des LXC-Users wird in den Container gemountet (`/run/podman.sock`). Container, die der Dev-Container startet (z. B. Testcontainers, `podman compose`), laufen als Geschwister-Container direkt im Podman des LXC.
- **`--userns=keep-id`:** Der Nutzer im Container hat dieselbe UID wie der LXC-User und darf deshalb den Socket benutzen. Das Image muss mit derselben UID gebaut werden (`--build-arg UID=$(id -u) --build-arg GID=$(id -g)`).
- **`--network=host`:** Von Geschwister-Containern veröffentlichte Ports liegen auf dem LXC. Mit Host-Netzwerk sind sie im Dev-Container unter `localhost` erreichbar, `TESTCONTAINERS_HOST_OVERRIDE` ist nicht nötig. Entwicklungs-Server im Container sind direkt über die LXC-IP erreichbar.
- **Startskript `/usr/local/bin/blm-start`** (Container-CMD):
  1. Klont das Repo nach `/workspace`, falls dort noch kein `.git` liegt.
  2. Startet in einer tmux-Session `claude` die Schleife `claude remote-control --name backlog-manager` (Neustart nach 15 s, falls der Prozess endet).
  3. Hält den Container mit `sleep infinity` am Leben.

## Voraussetzungen im LXC

1. Podman funktioniert im LXC (Proxmox-Optionen `nesting=1` und `keyctl=1` am Container).
2. Podman-Socket für den Nutzer aktivieren:
   ```bash
   systemctl --user enable --now podman.socket
   loginctl enable-linger $USER
   ```
   Der Socket liegt danach unter `/run/user/<UID>/podman/podman.sock`.
3. Arbeitsverzeichnis anlegen (leer lassen):
   ```bash
   mkdir -p ~/work/backlog-manager
   ```

## Build und Start

```bash
podman build -t blm-dev -f Containerfile \
  --build-arg UID=$(id -u) --build-arg GID=$(id -g) .

podman run -d --name blm-dev \
  --userns=keep-id --network=host \
  -v ~/work/backlog-manager:/workspace \
  -v /run/user/$(id -u)/podman/podman.sock:/run/podman.sock \
  -v blm-claude:/home/dev/.claude \
  -v blm-gh:/home/dev/.config/gh \
  --init --restart=unless-stopped \
  blm-dev
```

- Die Datei `review` muss im selben Verzeichnis wie die `Containerfile` liegen (Build-Kontext), sonst scheitert der `COPY`-Schritt. Ein fehlendes Ausführungsrecht ist unkritisch, die Containerfile setzt es selbst.
- `--init` sorgt dafür, dass der Container sauber auf Stop-Signale reagiert.
- Build-Args mit Standardwerten: `NODE_MAJOR=22`, `FLUTTER_REF=stable` (Branch oder Tag, z. B. `3.35.0`), `USERNAME=dev`.
- Umgebungsvariable `REPO_URL` (im Image gesetzt) bestimmt, welches Repo beim ersten Start geklont wird.

## Erste Einrichtung (einmalig, im Container)

```bash
podman exec -it blm-dev tmux attach -t claude
```

In der Session läuft zunächst eine Fehlermeldung, weil Claude Code noch nicht angemeldet ist. Mit `Strg-b c` ein zweites tmux-Fenster öffnen und dort einrichten:

| Schritt | Befehl | Persistenz |
|---|---|---|
| Claude Code anmelden | `claude` in `/workspace` starten, `/login` mit claude.ai-Abo, Ordner-Vertrauen bestätigen, danach beenden | Volume `blm-claude` |
| GitHub | `gh auth login && gh auth setup-git` | Volume `blm-gh` |
| CodeRabbit | `coderabbit auth login --api-key "cr-..."` | nicht persistent |
| Git-Identität | `git config --global user.name "..."` und `git config --global user.email "..."` | nicht persistent |

Danach verbindet sich Fenster 0 beim nächsten Retry (alle 15 s) selbst mit Remote Control. tmux verlassen ohne Abbruch: `Strg-b d`.

Hinweise:
- Der Clone beim ersten Start geht ohne Login (öffentliches Repo über HTTPS). Zum Pushen ist `gh auth setup-git` nötig.
- Schlägt der Clone fehl, steht `Clone fehlgeschlagen` im tmux-Fenster. Häufigste Ursache: `~/work/backlog-manager` ist nicht leer und enthält kein Git-Repo.
- Der CodeRabbit-Login und die Git-Identität gehen bei einer Neuanlage des Containers verloren. Ein Volume auf `~/.coderabbit` würde die installierte Binary überdecken, deshalb gibt es keins.

## Remote Control

Remote Control verbindet die Claude-App und claude.ai/code mit einer Claude-Code-Session, die im Container läuft. Mindestversion laut Doku: Claude Code v2.1.51. Der native Installer holt die aktuelle Version.

**Standard in diesem Container: Server-Modus** (`claude remote-control`). Aus der App lassen sich darin neue Chats starten und bestehende verwalten. Im tmux-Fenster siehst du nur den Server-Status.

**Alternative: interaktive Session** mit `claude --remote-control backlog-manager`. Dann gibt es eine einzelne Session, in der du im Terminal tippen kannst, während sie auch in der App sichtbar ist. Dafür den Befehl in der `rc_loop`-Zeile des Startskripts in der Containerfile austauschen. Weitere Varianten: `/remote-control` (oder `/rc`) mitten in einer Session, oder in `/config` die Option für alle Sessions aktivieren.

**Voraussetzungen und Stolperfallen:**
- Anmeldung nur per claude.ai-Abo über `/login`. API-Keys sowie Tokens aus `setup-token` oder `CLAUDE_CODE_OAUTH_TOKEN` funktionieren nicht.
- Kein `ANTHROPIC_BASE_URL` und kein LLM-Gateway (z. B. 9Router) in diesem Container, ein eigener Endpunkt schaltet Remote Control ab.
- Nicht setzen: `DISABLE_TELEMETRY`, `DO_NOT_TRACK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`. Sie deaktivieren die Funktionsprüfung, von der Remote Control abhängt.
- Amazon Bedrock, Google Cloud und Microsoft Foundry werden nicht unterstützt.
- Bei Team/Enterprise muss ein Owner Remote Control in den Admin-Einstellungen aktivieren.
- Solange eine Session verbunden ist, liegt das Transkript laut Doku auf Anthropic-Servern.
- Pro Claude-Code-Prozess gibt es außerhalb des Server-Modus nur eine Remote-Session.

Ansehen und Mitmachen per Terminal: SSH auf den LXC, dann `podman exec -it blm-dev tmux attach -t claude` oder `podman exec -it blm-dev bash`.

## Review mit Ollama-Fallback

Das Skript `/usr/local/bin/review` (Quelle: Datei `review` im Repo) startet zuerst `coderabbit review --agent --base <branch>`. Ist CodeRabbit nicht nutzbar, fragt es stattdessen ein Ollama-Modell. Claude Code ruft nur noch `review` auf. Das Skript läuft als eigener Prozess und beeinflusst Remote Control nicht.

```bash
review            # Basis-Branch main
review develop    # anderer Basis-Branch
```

**Ablauf**
1. CodeRabbit läuft mit `--agent` (strukturierte JSON-Ausgabe, eine Zeile pro Finding). Bei Exit-Code 0 und gültiger Ausgabe wird sie unverändert ausgegeben, mit der Kopfzeile `[review] Quelle: CodeRabbit`.
2. Bei Exit-Code ungleich 0, oder wenn die Ausgabe wie eine Limit-/Anmeldemeldung aussieht, greift der Fallback.
3. Der Fallback sendet den Diff gegenüber dem Merge-Base des Basis-Branches (committed und uncommitted, nur getrackte Dateien) an die Ollama-HTTP-API (`/api/generate`). Die Kopfzeile lautet dann `[review] Quelle: Ollama (<modell>) ...`.

**Umgebungsvariablen**

| Variable | Bedeutung | Standard |
|---|---|---|
| `OLLAMA_REVIEW_MODEL` | Modell für den Fallback, ohne Wert gibt es keinen Fallback | nicht gesetzt |
| `OLLAMA_URL` | Adresse des Ollama-Servers | `http://127.0.0.1:11434` |
| `OLLAMA_API_KEY` | optional, wird als Bearer-Token gesendet | nicht gesetzt |
| `OLLAMA_NUM_CTX` | Kontextfenster der Anfrage | `65536` |
| `REVIEW_MAX_BYTES` | maximale Diff-Größe, größere Diffs werden abgeschnitten | `150000` |

Setzen beim Start des Containers, zum Beispiel `-e OLLAMA_REVIEW_MODEL=<modell> -e OLLAMA_URL=http://127.0.0.1:11434` im `podman run`.

**Exit-Codes:** `0` Review geliefert, `1` Fallback nicht konfiguriert, `2` CodeRabbit und Ollama fehlgeschlagen.

**Voraussetzungen und Grenzen**
- Ein Ollama-Server muss für den Container erreichbar sein, zum Beispiel auf dem LXC (dank `--network=host` über `127.0.0.1`). Für Cloud-Modelle muss der Server bei Ollama angemeldet sein. Eine direkte Nutzung der Ollama-Cloud-API mit `OLLAMA_URL` und `OLLAMA_API_KEY` sollte ebenfalls möglich sein, ist hier aber nicht getestet.
- Die Ollama-CLI ist nicht im Image nötig, das Skript nutzt `curl` und `jq`.
- Das Ollama-Review sieht nur den Diff und nicht den Rest des Repos. Es ist eine zweite Meinung. Befunde müssen gegen den Code geprüft werden, bevor etwas geändert wird.
- Das Kontextfenster ist wichtig: Ollama arbeitet sonst mit kleinen Standardwerten und kürzt lange Diffs. Deshalb sendet das Skript `num_ctx`.
- Das Skript ersetzt nicht die automatischen PR-Reviews der CodeRabbit-GitHub-App.
- Ob die CodeRabbit-CLI bei einem Limit mit Fehlercode endet, ist nicht dokumentiert. Die Erkennung beruht auf Exit-Code und Textmuster (`rate limit`, `quota`, `unauthorized` u. ä.) und sollte einmal real getestet werden.

**Regel für Claude (in die `CLAUDE.md` des Repos oder in `~/.claude/CLAUDE.md` im Container):**

```markdown
## Code review

Run `review [base-branch]` (default: main) instead of calling `coderabbit` directly.
It uses CodeRabbit and falls back to an Ollama model when CodeRabbit is unavailable.
The first output line names the source.
- CodeRabbit findings (JSON lines, see `codegenInstructions`) are actionable.
- Ollama output only sees the diff: treat it as a second opinion and verify every point
  against the code before changing anything.
Run it before opening a PR.
```

## Testcontainers

Testcontainers sprechen über `DOCKER_HOST=unix:///run/podman.sock` mit dem Podman des LXC.

- `TESTCONTAINERS_RYUK_DISABLED=true`: Ryuk macht mit Podman oft Probleme. Nachteil: Bei abgestürzten Tests bleiben Container eventuell liegen. Aufräumen mit `podman ps -a` und `podman rm -f ...`.
- Falls du auf Host-Netzwerk verzichtest, braucht Testcontainers `TESTCONTAINERS_HOST_OVERRIDE` (z. B. `host.containers.internal`).
- Podman-in-Podman (verschachtelt) wird bewusst nicht verwendet, es ist fummelig und braucht erweiterte Rechte.

## podman und podman-compose im Container

- Im Container gibt es nur den Remote-Client `podman-remote`, konfiguriert über `CONTAINER_HOST`.
- Ein Wrapper `/usr/local/bin/podman` ruft `podman-remote` auf, weil `podman-compose` intern den Befehl `podman` verwendet.
- Damit funktionieren `podman ps`, `podman compose up` und `podman-compose up` gegen den Podman des LXC.
- Wenige Compose-Features, die direkten Daemon-Zugriff brauchen, können sich über den Remote-Client anders verhalten als im LXC selbst.

## Flutter

- Aktiviert: Linux-Desktop. `flutter build linux` und `flutter test` laufen im Container.
- Integrationstests ohne Display: `xvfb-run flutter test integration_test -d linux`.
- Prüfung der Installation: `flutter doctor -v`.
- Nicht möglich im Linux-Container: Windows-, macOS- und iOS-Builds. Dafür braucht es einen Mac bzw. CI mit passenden Runnern (z. B. GitHub Actions mit macOS-Runner).
- Eine sichtbare Ausgabe der Linux-App gibt es im Container nicht (kein Display), Claude kann bauen und testen, aber nicht visuell prüfen.

## Sicherheit

- Wer den Podman-Socket hat, kontrolliert alle rootless Container dieses LXC-Users. Läuft Claude Code mit großzügigen Rechten, entspricht das praktisch Zugriff auf alles, was dieser User betreibt.
- Empfehlung: einen eigenen LXC-User für den Dev-Container verwenden, nicht den, unter dem produktive Container (z. B. das Prod-Backend) laufen.

## Wartung

| Aufgabe | Vorgehen |
|---|---|
| Image neu bauen | `podman build ...` wie oben, dann `podman rm -f blm-dev` und `podman run ...` erneut ausführen |
| Verlorene Logins nach Neuanlage | Claude und gh bleiben (Volumes). CodeRabbit und Git-Identität neu einrichten |
| Claude Code aktualisieren | Updates laufen im Hintergrund, wirken beim nächsten Start. Ein Image-Rebuild holt ebenfalls die neueste Version |
| Flutter-Version festnageln | Build-Arg `FLUTTER_REF` setzen |
| Node-Version ändern | Build-Arg `NODE_MAJOR` setzen (aktuell 22) |
| Testcontainer-Reste aufräumen | `podman ps -a` im LXC prüfen, übrig gebliebene Container mit `podman rm -f` entfernen |

## Optionale Erweiterungen

- **Java:** Viele OpenAPI-Generatoren (z. B. für einen Flutter-Client aus der Litestar-OpenAPI-Spec) brauchen Java. Reine Dart-Generatoren wie `swagger_parser` kommen ohne aus.
- **Quadlet:** Systemd-Unit statt `--restart=unless-stopped` für den 24/7-Betrieb.
- **Chromium/Flutter Web:** Entfernt, da kein Web-Target geplant ist.
- **Rust/Tauri:** Entfällt, sobald der Flutter-Client fertig ist.

## Fehlersuche

| Symptom | Mögliche Ursache |
|---|---|
| Remote Control erscheint nicht in der App | Noch nicht angemeldet, Ordner-Vertrauen nicht bestätigt, oder ein gesperrtes Setup (Gateway, API-Key, Telemetrie-Variablen) |
| `Clone fehlgeschlagen` | Arbeitsverzeichnis nicht leer oder kein Netzwerk |
| Testcontainers finden keinen Docker-Host | Socket nicht gemountet oder `podman.socket` im LXC nicht aktiv |
| Zugriff auf den Socket verweigert | UID im Image passt nicht zur LXC-UID (Build-Args), oder `--userns=keep-id` fehlt |
| Container-Ports nicht erreichbar | Container wurde ohne `--network=host` gestartet |
| Download des Claude-Code- oder CodeRabbit-Installers schlägt beim Build fehl | Netzwerk im Build-Kontext prüfen, Build wiederholen |
