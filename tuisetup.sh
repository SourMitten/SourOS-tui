#!/usr/bin/env bash
# ============================================================================
#  tui-os-installer.sh
#  Installs a clickable, character-cell "OS shell" on a minimal Linux box.
#  - Boots straight into a mouse-driven TUI on tty1
#  - Launches TUI tools (files/web/edit/sys) in-process
#  - Hands the console over to a real GPU game on tty2, then snaps back
#
#  Usage:  sudo ./tui-os-installer.sh
#          sudo ./tui-os-installer.sh --dry-run
#          sudo ./tui-os-installer.sh --uninstall [--purge]
# ============================================================================
set -euo pipefail

DRY_RUN=0
UNINSTALL=0
PURGE=0
for a in "$@"; do
  case "$a" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge)     PURGE=1 ;;
    *) echo "unknown arg: $a"; exit 1 ;;
  esac
done

REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
APP_DIR="$REAL_HOME/my_tui_os"
MARK_BEGIN="# >>> TUI OS >>>"
MARK_END="# <<< TUI OS <<<"
SUDOERS="/etc/sudoers.d/99-tui-os"
GETTY_OVERRIDE="/etc/systemd/system/getty@tty1.service.d/override.conf"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'  "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n'  "$*" >&2; exit 1; }

run() { if [ "$DRY_RUN" = 1 ]; then echo "  (dry-run) $*"; else "$@"; fi; }

# ----------------------------------------------------------------------------
[ "$(id -u)" = 0 ] || die "run me with sudo:  sudo $0"
[ -n "$REAL_HOME" ] || die "could not resolve home dir for '$REAL_USER'"
CHVT="$(command -v chvt || echo /usr/bin/chvt)"

# ----------------------------------------------------------------------------
# UNINSTALL
# ----------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  say "Uninstalling TUI OS for $REAL_USER"
  if [ -f "$REAL_HOME/.bashrc" ]; then
    sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$REAL_HOME/.bashrc" && say "  stripped .bashrc hook"
  fi
  run rm -f "$SUDOERS"                                      && say "  removed sudoers rule"
  run rm -f "$GETTY_OVERRIDE"                               && say "  removed tty1 autologin"
  run systemctl daemon-reload || true
  if [ "$PURGE" = 1 ]; then run rm -rf "$APP_DIR" && say "  removed $APP_DIR"
  else say "  kept $APP_DIR (use --purge to delete)"; fi
  say "Done. Graphical/normal login restored on next boot."
  exit 0
fi

# ----------------------------------------------------------------------------
# 1. PACKAGES
# ----------------------------------------------------------------------------
say "Installing system packages"
PKGS_CORE="python3 python3-venv python3-pip util-linux"
PKGS_OPT="yazi btop micro lynx ranger"

install_one() {
  local p="$1"
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive run apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1
  elif command -v dnf >/dev/null 2>&1; then
    run dnf install -y "$p" >/dev/null 2>&1
  elif command -v pacman >/dev/null 2>&1; then
    run pacman -Sy --noconfirm "$p" >/dev/null 2>&1
  elif command -v zypper >/dev/null 2>&1; then
    run zypper --non-interactive install "$p" >/dev/null 2>&1
  else
    warn "no known package manager; install '$p' manually"; return 0
  fi
}

# core first (fatal if these fail)
for p in $PKGS_CORE; do install_one "$p" || die "failed to install core package: $p"; done

# optional tools (best effort)
MISSING=""
for p in $PKGS_OPT; do install_one "$p" || MISSING="$MISSING $p"; done
[ -n "$MISSING" ] && warn "optional tools not available (launcher will fall back):$MISSING"

# ----------------------------------------------------------------------------
# 2. APP DIRECTORY + FILES
# ----------------------------------------------------------------------------
say "Writing shell to $APP_DIR"
run mkdir -p "$APP_DIR"
run chown -R "$REAL_USER:$REAL_USER" "$APP_DIR" 2>/dev/null || true

# ---- config.sh -------------------------------------------------------------
run tee "$APP_DIR/config.sh" >/dev/null <<'CFG'
# TUI OS user config — edit freely, takes effect next launch.
GAME_COMMAND=""            # e.g. "steam --fullscreen steam://rungameid/2300"
                           # e.g. "./doom -iwad doom.wad"   (native, no X needed)
FILES_CMD=""               # override: yazi | ranger | nnn | mc
WEB_CMD=""                 # override: lynx | links | elinks | browsh
EDIT_CMD=""                # override: micro | helix | nano
SYS_CMD=""                 # override: btop | htop | gotop
CFG

# ---- main.py (the clickable shell) ----------------------------------------
run tee "$APP_DIR/main.py" >/dev/null <<'PYEOF'
#!/usr/bin/env python3
"""TUI OS shell. Clickable character-cell UI.

Exits with a numeric code; ../run.sh maps it to a program.
  1=files 2=web 3=edit 4=sys 5=game 6=poweroff 7=reboot 0=quit
"""
from __future__ import annotations

from textual import on
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.widgets import Button, Footer, Header, Static

EXIT = {"files": 1, "web": 2, "edit": 3, "sys": 4, "game": 5, "off": 6, "reboot": 7}


class TUIOS(App[None]):
    TITLE = "TUI OS"
    BINDINGS = [("ctrl+q", "quit", "Quit")]

    CSS = """
    Screen { background: #05080f; }
    #menubar {
        height: 3; dock: top; background: #0a1424;
        border: round #1d4ed8; padding: 0 1;
    }
    #grid {
        height: 1fr; grid-size: 2; grid-columns: 1fr 2fr;
        grid-gutter: 1; padding: 1;
    }
    .panel { border: round #1d4ed8; background: #080d18; padding: 1 2; }
    #apps  { layout: vertical; }
    Button {
        width: 100%; height: 3; margin: 0 0 1 0;
        background: #0d1b33; color: #60a5fa; border: tall #1e3a8a;
    }
    Button:hover { background: #1d4ed8; color: #ffffff; text-style: bold; }
    Button.-primary { color: #34d399; border: tall #065f46; }
    Button.-primary:hover { background: #065f46; color: #ecfdf5; }
    Button.-danger { color: #f87171; border: tall #7f1d1d; }
    Button.-danger:hover { background: #7f1d1d; color: #fef2f2; }
    #clock { color: #34d399; padding: 1 2; }
    #title { color: #93c5fd; text-style: bold; }
    #stats { color: #a5b4fc; }
    """

    clock = reactive("")
    stats = reactive("")

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="menubar"):
            yield Button(" FILES ", id="btn_files")
            yield Button(" WEB   ", id="btn_web")
            yield Button(" EDIT  ", id="btn_edit")
            yield Button(" SYS   ", id="btn_sys")
            yield Button(" GAME  ", id="btn_game", variant="primary")
            yield Static("", id="clock")
        with Horizontal(id="grid"):
            with Vertical(classes="panel", id="apps"):
                yield Static("[ applications ]", id="title")
                yield Button("File Manager", id="btn_files")
                yield Button("Web (text)", id="btn_web")
                yield Button("Editor", id="btn_edit")
                yield Button("System Monitor", id="btn_sys")
                yield Button("LAUNCH GAME", id="btn_game", variant="primary")
                yield Button("Power Off", id="btn_off", variant="danger")
            with Vertical(classes="panel", id="info"):
                yield Static("[ node status ]", id="title")
                yield Static("", id="stats")
        yield Footer()

    def on_mount(self) -> None:
        self._tick()
        self.set_interval(1.0, self._tick)

    def _tick(self) -> None:
        import datetime as dt
        self.clock = dt.datetime.now().strftime("%H:%M:%S  %Y-%m-%d")
        self.query_one("#clock", Static).update(self.clock)
        self.query_one("#stats", Static).update(self._sysinfo())

    @staticmethod
    def _sysinfo() -> str:
        try:
            load = " ".join(open("/proc/loadavg").read().split()[:3])
            m = {}
            for line in open("/proc/meminfo"):
                k, v = line.split(":", 1)
                m[k] = int(v.split()[0])
            pct = 100 * (m["MemTotal"] - m["MemAvailable"]) // m["MemTotal"]
            bar = "█" * (pct // 5) + "░" * (20 - pct // 5)
            s = int(float(open("/proc/uptime").read().split()[0]))
            d, s = divmod(s, 86400); h, s = divmod(s, 3600); mi, _ = divmod(s, 60)
            return f"load   {load}\nmem    {bar} {pct:>3}%\nup     {d}d {h:02d}:{mi:02d}\n\nclick anything. the grid is the ui."
        except Exception:
            return "sys  n/a"

    @on(Button.Pressed)
    def pressed(self, event: Button.Pressed) -> None:
        bid = (event.button.id or "").replace("btn_", "")
        self.exit(EXIT.get(bid, 0))


if __name__ == "__main__":
    import sys
    sys.exit(int(TUIOS().run() or 0))
PYEOF

# ---- run.sh (session driver) ----------------------------------------------
run tee "$APP_DIR/run.sh" >/dev/null <<'RUNEOF'
#!/usr/bin/env bash
# TUI OS session driver: runs the shell, maps its exit code to a program.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$DIR/config.sh" ] && . "$DIR/config.sh"

PY="$DIR/.venv/bin/python"
command -v "$PY" >/dev/null 2>&1 || PY="$(command -v python3)"

resolve() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; }

FILES_BIN="${FILES_CMD:-$(resolve yazi ranger nnn mc)}"
WEB_BIN="${WEB_CMD:-$(resolve lynx links elinks browsh)}"
EDIT_BIN="${EDIT_CMD:-$(resolve micro helix nano)}"
SYS_BIN="${SYS_CMD:-$(resolve btop htop gotop)}"
CHVT="$(command -v chvt || echo /usr/bin/chvt)"

say() { printf '\n%s\n' "$*"; sleep 2; }
launch() { clear; "$@" 2>/dev/null; clear; }

if ! "$PY" -c 'import textual' 2>/dev/null; then
  clear; echo "TUI OS: python package 'textual' is missing."; echo "Fix: $DIR/.venv/bin/pip install textual"; sleep 4; exit 1
fi

while :; do
  "$PY" "$DIR/main.py"
  rc=$?
  case "$rc" in
    1) [ -n "$FILES_BIN" ] && launch "$FILES_BIN" || say "no file manager installed";;
    2) [ -n "$WEB_BIN" ]   && launch "$WEB_BIN" https://text.npr.org || say "no text browser installed";;
    3) [ -n "$EDIT_BIN" ]  && launch "$EDIT_BIN" || say "no editor installed";;
    4) [ -n "$SYS_BIN" ]   && launch "$SYS_BIN" || say "no system monitor installed";;
    5)
        if [ -z "${GAME_COMMAND:-}" ]; then
          say "No game configured. Edit: $DIR/config.sh  ->  GAME_COMMAND=\"...\""
          continue
        fi
        sudo -n "$CHVT" 2 || { say "chvt failed (check sudoers)"; continue; }
        sleep 0.5
        eval "$GAME_COMMAND" || true
        sudo -n "$CHVT" 1
        sleep 0.5; clear
        ;;
    6) exec sudo poweroff ;;
    7) exec sudo reboot ;;
    *) exit 0 ;;
  esac
done
RUNEOF

# ----------------------------------------------------------------------------
# 3. PYTHON VENV + textual
# ----------------------------------------------------------------------------
say "Creating python venv + installing textual"
run sudo -u "$REAL_USER" python3 -m venv "$APP_DIR/.venv"
run "$APP_DIR/.venv/bin/pip" install --upgrade pip >/dev/null
run "$APP_DIR/.venv/bin/pip" install textual >/dev/null \
  || warn "pip install failed (offline?); launcher will report it on first run"
run chmod +x "$APP_DIR/run.sh" "$APP_DIR/main.py"
run chown -R "$REAL_USER:$REAL_USER" "$APP_DIR" 2>/dev/null || true

# ----------------------------------------------------------------------------
# 4. PASSWORDLESS chvt (game mode handoff)
# ----------------------------------------------------------------------------
say "Allowing passwordless console switch for $REAL_USER"
run tee "$SUDOERS" >/dev/null <<EOF
# TUI OS: allow console switching for game mode. Nothing else.
$REAL_USER ALL=(ALL) NOPASSWD: $CHVT
EOF
run chmod 0440 "$SUDOERS"
if [ "$DRY_RUN" = 0 ]; then
  visudo -cf "$SUDOERS" >/dev/null || { rm -f "$SUDOERS"; die "sudoers syntax invalid, reverted"; }
fi

# ----------------------------------------------------------------------------
# 5. AUTOLOGIN ON tty1
# ----------------------------------------------------------------------------
say "Setting tty1 autologin for $REAL_USER"
run mkdir -p "$(dirname "$GETTY_OVERRIDE")"
run tee "$GETTY_OVERRIDE" >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $REAL_USER --noclear %I \$TERM
EOF

# ----------------------------------------------------------------------------
# 6. .bashrc HOOK
# ----------------------------------------------------------------------------
say "Wiring shell hook into $REAL_HOME/.bashrc"
touch "$REAL_HOME/.bashrc"
run cp "$REAL_HOME/.bashrc" "$REAL_HOME/.bashrc.tui-os.bak"
if grep -q "$MARK_BEGIN" "$REAL_HOME/.bashrc"; then
  warn "hook already present, leaving .bashrc alone"
else
  run tee -a "$REAL_HOME/.bashrc" >/dev/null <<EOF

$MARK_BEGIN
if [ -z "\${DISPLAY:-}" ] && [ -z "\${WAYLAND_DISPLAY:-}" ] \\
   && [ "\$(tty 2>/dev/null || echo none)" = "/dev/tty1" ]; then
    "\$HOME/my_tui_os/run.sh"
fi
$MARK_END
EOF
  run chown "$REAL_USER:$REAL_USER" "$REAL_HOME/.bashrc"
fi

# ----------------------------------------------------------------------------
say "INSTALL COMPLETE"
cat <<EOF

  next boot -> tty1 autologin -> your clickable shell

  exit hatch (always works):   Ctrl+Alt+F2   -> normal login
  quit the shell:              Ctrl+Q        -> drops to bash
  set a game:                  $APP_DIR/config.sh
  uninstall:                   sudo $0 --uninstall --purge

  NOTE: the autologin only applies on the NEXT boot.
        Do NOT 'systemctl restart getty@tty1' right now, it kills this session.
EOF
