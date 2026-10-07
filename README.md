# Dev-Container für backlog-manager

Podman-Container für die Entwicklung des Backlog Managers, gedacht für den Dauerbetrieb in einem **privilegierten** Debian-LXC auf Proxmox. Claude Code läuft darin per Remote Control und ist über die Claude-App steuerbar.

## Inhalt des Images

| Bereich | Enthalten |
|---|---|
| Basis | Debian trixie (slim), läuft als `root` |
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

## Repo-Layout

```
Containerfile                   Image-Definition
compose.yaml                     podman-compose, nutzt per Default das ghcr.io-Image
compose.build.yaml               Override: lokal mit Containerfile bauen statt pullen
scripts/review.sh                Quelle für /usr/local/bin/review im Image
.github/workflows/build-image.yml  baut das Image und pusht es nach ghcr.io
```

## Funktionsweise

- **Podman-Container im LXC, als root:** Der Dev-Container läuft als normaler (rootful) Podman-Container im LXC, nicht verschachtelt. Kein UID-Mapping, kein `--userns`, dafür braucht der LXC selbst **privilegiert** zu sein (siehe [Voraussetzungen im LXC](#voraussetzungen-im-lxc)) - rootless + `--network=host` bricht an einer Podman-Upstream-Grenze (`--userns` und `--network=host` vertragen sich nicht, crun kann dann kein frisches sysfs mounten), und rootless + `slirp4netns` braucht `/dev/net/tun`, das ein unprivilegierter LXC nicht hat. Root im Container + privilegierter LXC umgeht beides.
- **Socket durchreichen:** Der System-Podman-Socket des LXC wird in den Container gemountet (`/run/podman.sock`). Container, die der Dev-Container startet (z. B. Testcontainers, `podman compose`), laufen als Geschwister-Container direkt im Podman des LXC.
- **`--network=host`:** Von Geschwister-Containern veröffentlichte Ports liegen auf dem LXC und sind im Dev-Container unter `localhost` erreichbar, `TESTCONTAINERS_HOST_OVERRIDE` ist nicht nötig. Entwicklungs-Server im Container sind direkt über die LXC-IP erreichbar.
- **Startskript `/usr/local/bin/blm-start`** (Container-CMD):
  1. Klont das Repo nach `/workspace`, falls dort noch kein `.git` liegt.
  2. Startet in einer tmux-Session `claude` die Schleife `claude remote-control --name backlog-manager` (Neustart nach 15 s, falls der Prozess endet).
  3. Hält den Container mit `sleep infinity` am Leben.

## Voraussetzungen im LXC

1. LXC **privilegiert** anlegen (in Proxmox beim Erstellen "Unprivileged container" abwählen, oder bei einem bestehenden LXC `unprivileged: 0` in `/etc/pve/lxc/<id>.conf` setzen und neu starten), dazu die Optionen `nesting=1` und `keyctl=1`.
2. Podman-Socket systemweit aktivieren:
   ```bash
   systemctl enable --now podman.socket
   ```
   Der Socket liegt danach unter `/run/podman/podman.sock`.
3. Arbeitsverzeichnis anlegen (leer lassen):
   ```bash
   mkdir -p ~/work/backlog-manager
   ```

## Build und Start

**Option A - lokal bauen:**

```bash
podman build -t blm-dev -f Containerfile .

podman run -d --name blm-dev \
  --network=host \
  -v ~/work/backlog-manager:/workspace \
  -v /run/podman/podman.sock:/run/podman.sock \
  -v blm-claude:/root/.claude \
  -v blm-gh:/root/.config/gh \
  --init --restart=unless-stopped \
  blm-dev
```

**Option B - fertiges Image von ghcr.io:**

```bash
podman run -d --name blm-dev \
  --network=host \
  -v ~/work/backlog-manager:/workspace \
  -v /run/podman/podman.sock:/run/podman.sock \
  -v blm-claude:/root/.claude \
  -v blm-gh:/root/.config/gh \
  --init --restart=unless-stopped \
  ghcr.io/theoleuthardt/claude-devcontainer:latest
```

Alternativ mit `compose.yaml` (podman-compose), Image-Referenz ist dort bereits auf `ghcr.io/theoleuthardt/claude-devcontainer:latest` gesetzt. `build` und `image: ghcr.io/...` dürfen in einem Service nicht gemeinsam auf eine Registry zeigen (sonst `OSError: Dockerfile not found`, wenn das Image noch nicht lokal vorhanden ist), deshalb liegt der Build-Teil in einer separaten Override-Datei `compose.build.yaml`:

```bash
# fertiges ghcr.io-Image nutzen
podman-compose pull && podman-compose up -d

# oder lokal bauen und starten
podman-compose -f compose.yaml -f compose.build.yaml up -d --build
```

- Die Datei `scripts/review.sh` muss relativ zur `Containerfile` unter `scripts/` liegen (Build-Kontext), sonst scheitert der `COPY`-Schritt. Ein fehlendes Ausführungsrecht ist unkritisch, die Containerfile setzt es selbst.
- `--init` sorgt dafür, dass der Container sauber auf Stop-Signale reagiert.
- Build-Args mit Standardwerten: `NODE_MAJOR=22`, `FLUTTER_REF=stable` (Branch oder Tag, z. B. `3.35.0`).
- Umgebungsvariable `REPO_URL` (im Image gesetzt) bestimmt, welches Repo beim ersten Start geklont wird.

## Image aus ghcr.io

`.github/workflows/build-image.yml` baut das Image bei jedem Push auf `main` (der relevanten Dateien) und bei manuellem Trigger, und pusht es nach `ghcr.io/theoleuthardt/claude-devcontainer:latest` sowie `:<sha>`.

```bash
podman pull ghcr.io/theoleuthardt/claude-devcontainer:latest
```

Das Package ist an den Workflow-Run gebunden, nicht an GitHub Releases. Sichtbarkeit (öffentlich/privat) richtet sich nach den Package-Einstellungen in GitHub.

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

Das Skript `/usr/local/bin/review` (Quelle: `scripts/review.sh` im Repo) startet zuerst `coderabbit review --agent --base <branch>`. Ist CodeRabbit nicht nutzbar, fragt es stattdessen ein Ollama-Modell. Claude Code ruft nur noch `review` auf. Das Skript läuft als eigener Prozess und beeinflusst Remote Control nicht.

```bash
review            # Basis-Branch main
review develop    # anderer Basis-Branch
```

**Ablauf**
1. CodeRabbit läuft mit `--agent` (strukturierte JSON-Ausgabe, eine Zeile pro Finding). Bei Exit-Code 0 und gültiger Ausgabe wird sie unverändert ausgegeben, mit der Kopfzeile `[review] source: CodeRabbit`.
2. Bei Exit-Code ungleich 0, oder wenn die Ausgabe wie eine Limit-/Anmeldemeldung aussieht, greift der Fallback.
3. Der Fallback sendet den Diff gegenüber dem Merge-Base des Basis-Branches (committed und uncommitted, nur getrackte Dateien) an die Ollama-HTTP-API (`/api/generate`). Die Kopfzeile lautet dann `[review] source: Ollama (<modell>) ...`.

**Ollama-Fallback-Prompt:** strikt formuliert, Prioritätenliste (Correctness > Security > Concurrency > Error-Handling > Breaking Changes > Tests), Style-Nitpicks explizit ausgeschlossen. Die Ausgabe ist NDJSON im Schema der CodeRabbit-CLI (`--agent`): pro Fund eine Zeile `{"type":"finding","severity":...,"fileName":...,"codegenInstructions":...,"suggestions":[...],"comment":...}`, `severity` eines von `critical`, `major`, `minor`, `trivial`, `info`, `none`. Zum Schluss immer eine Zeile `{"type":"complete","findings":<anzahl>}`. Damit ist die Ausgabe unabhängig von der Quelle (CodeRabbit oder Ollama) gleich aufgebaut.

**Umgebungsvariablen**

| Variable | Bedeutung | Standard |
|---|---|---|
| `OLLAMA_REVIEW_MODEL` | Modell für den Fallback, ohne Wert gibt es keinen Fallback | nicht gesetzt |
| `OLLAMA_URL` | Adresse des Ollama-Servers | `https://ollama.com` (Ollama Cloud) |
| `OLLAMA_API_KEY` | bei Ollama Cloud erforderlich, wird als Bearer-Token gesendet | nicht gesetzt |
| `OLLAMA_NUM_CTX` | Kontextfenster der Anfrage | `65536` |
| `REVIEW_MAX_BYTES` | maximale Diff-Größe, größere Diffs werden abgeschnitten | `150000` |

Setzen beim Start des Containers, zum Beispiel `-e OLLAMA_REVIEW_MODEL=<modell> -e OLLAMA_API_KEY=<key>` im `podman run`. Für einen lokalen Ollama-Server stattdessen `OLLAMA_URL=http://127.0.0.1:11434` setzen (kein Key nötig).

**Exit-Codes:** `0` Review geliefert, `1` Fallback nicht konfiguriert, `2` CodeRabbit und Ollama fehlgeschlagen.

**Voraussetzungen und Grenzen**
- Standard ist Ollama Cloud (`https://ollama.com`) mit `OLLAMA_API_KEY`. Für einen lokalen Server (z. B. auf dem LXC, dank `--network=host` über `127.0.0.1`) stattdessen `OLLAMA_URL` umbiegen.
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

- Der LXC ist **privilegiert** und der Dev-Container läuft als **root** mit Zugriff auf den System-Podman-Socket. Wer das Image oder den Container kontrolliert, kontrolliert damit praktisch den ganzen LXC (und je nach Proxmox-Konfiguration potenziell mehr - privilegierte LXCs haben einen deutlich größeren Blast-Radius als unprivilegierte).
- Empfehlung: einen eigenen, isolierten LXC nur für diesen Dev-Container verwenden, nicht einen, der auch produktive Dienste (z. B. das Prod-Backend) hostet.
- Kein Secrets-Zugriff über das Image hinaus nötig geben: Claude- und gh-Login liegen in eigenen Volumes, nicht im Image.

## Wartung

| Aufgabe | Vorgehen |
|---|---|
| Image neu bauen | `podman build ...` wie oben, dann `podman rm -f blm-dev` und `podman run ...` erneut ausführen, oder das von `build-image.yml` gepushte Image aus ghcr.io pullen |
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
| Zugriff auf den Socket verweigert | `/run/podman/podman.sock` nicht gemountet, oder `podman.socket` im LXC nicht als root/systemweit aktiv (siehe [Voraussetzungen im LXC](#voraussetzungen-im-lxc)) |
| `crun: mount sysfs to sys: Operation not permitted` beim Start | LXC ist nicht privilegiert (siehe [Voraussetzungen im LXC](#voraussetzungen-im-lxc)) |
| Container-Ports nicht erreichbar | Container wurde ohne `--network=host` gestartet |
| Download des Claude-Code- oder CodeRabbit-Installers schlägt beim Build fehl | Netzwerk im Build-Kontext prüfen, Build wiederholen |
