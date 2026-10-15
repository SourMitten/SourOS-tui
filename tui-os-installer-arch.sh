#!/usr/bin/env bash
# tui-os-installer.sh — Arch Linux installer for the TUI OS shell.
# Assumes Arch Linux is already installed and bootable.
#
# Usage:
#   sudo ./tui-os-installer.sh
#   sudo ./tui-os-installer.sh --dry-run
#   sudo ./tui-os-installer.sh --uninstall [--purge]

set -Eeuo pipefail
IFS=$'\n\t'
umask 022

DRY_RUN=0
UNINSTALL=0
PURGE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --uninstall) UNINSTALL=1 ;;
        --purge) PURGE=1 ;;
        -h|--help)
            sed -n '2,8p' "$0"
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
run()  {
    if (( DRY_RUN )); then
        printf '  (dry-run)'; printf ' %q' "$@"; printf '\n'
    else
        "$@"
    fi
}
write_file() {
    local target=$1 mode=${2:-0644}
    if (( DRY_RUN )); then
        printf '  (dry-run) write %s (mode %s)\n' "$target" "$mode"
        cat >/dev/null
    else
        install -D -m "$mode" /dev/stdin "$target"
    fi
}

(( EUID == 0 )) || die "Run with sudo: sudo $0"
command -v pacman >/dev/null 2>&1 || die "This installer is for Arch Linux (pacman not found)."
command -v systemctl >/dev/null 2>&1 || die "systemd/systemctl is required."

REAL_USER="${SUDO_USER:-}"
[[ -n "$REAL_USER" && "$REAL_USER" != root ]] || die "Run with sudo from a regular user account; refusing to configure autologin for root."
PASSWD_ENTRY="$(getent passwd "$REAL_USER" || true)"
[[ -n "$PASSWD_ENTRY" ]] || die "Could not resolve account: $REAL_USER"
REAL_HOME="$(cut -d: -f6 <<<"$PASSWD_ENTRY")"
REAL_GROUP="$(id -gn "$REAL_USER")"
LOGIN_SHELL="$(cut -d: -f7 <<<"$PASSWD_ENTRY")"
[[ "${LOGIN_SHELL##*/}" == bash ]] || die "The TUI hook currently requires Bash as the login shell (found: $LOGIN_SHELL). Change the account shell to bash or adapt the profile hook first."
[[ -n "$REAL_HOME" && -d "$REAL_HOME" ]] || die "Home directory does not exist for $REAL_USER."

APP_DIR="$REAL_HOME/my_tui_os"
PROFILE="$REAL_HOME/.bash_profile"
MARK_BEGIN="# >>> TUI OS >>>"
MARK_END="# <<< TUI OS <<<"
GETTY_DIR="/etc/systemd/system/getty@tty1.service.d"
GETTY_OVERRIDE="$GETTY_DIR/override.conf"

if (( UNINSTALL )); then
    say "Uninstalling TUI OS for $REAL_USER"
    if [[ -f "$PROFILE" ]]; then
        if (( DRY_RUN )); then
            say "(dry-run) remove TUI OS hook from $PROFILE"
        else
            sed -i "\|^${MARK_BEGIN}$|,\|^${MARK_END}$|d" "$PROFILE"
            chown "$REAL_USER:$REAL_GROUP" "$PROFILE"
        fi
    fi
    if [[ -f "$GETTY_OVERRIDE.tui-os.bak" ]]; then
        if (( DRY_RUN )); then
            say "(dry-run) restore previous getty override from $GETTY_OVERRIDE.tui-os.bak"
        else
            mv -f "$GETTY_OVERRIDE.tui-os.bak" "$GETTY_OVERRIDE"
        fi
    else
        run rm -f "$GETTY_OVERRIDE"
    fi
    if [[ -d "$GETTY_DIR" ]] && ! (( DRY_RUN )); then
        rmdir "$GETTY_DIR" 2>/dev/null || true
    fi
    run systemctl daemon-reload
    if (( PURGE )); then
        run rm -rf -- "$APP_DIR"
    else
        say "Keeping $APP_DIR (use --purge to delete it)."
    fi
    say "Uninstall complete. Autologin and the TUI hook have been removed."
    exit 0
fi

say "Installing required and optional Arch packages"
# One full upgrade transaction avoids unsafe partial upgrades on Arch.
PKGS=(python python-pip util-linux sudo)
OPTIONAL_PKGS=(yazi btop micro lynx)
if (( DRY_RUN )); then
    printf '  (dry-run) pacman -Syu --needed --noconfirm'
    printf ' %q' "${PKGS[@]}" "${OPTIONAL_PKGS[@]}"
    printf '\n'
else
    pacman -Syu --needed --noconfirm "${PKGS[@]}" "${OPTIONAL_PKGS[@]}" ||
        die "Package installation failed. No autologin configuration has been applied yet."
fi

say "Preparing application directory: $APP_DIR"
run install -d -o "$REAL_USER" -g "$REAL_GROUP" -m 0755 "$APP_DIR"

write_file "$APP_DIR/config.sh" 0644 <<'CFG'
# TUI OS user configuration. Edit these values; changes apply next launch.
# GAME_COMMAND is a shell command string executed as your regular user.
# For a native game, configure the command appropriate to your setup.
GAME_COMMAND=""
FILES_CMD=""   # Optional override, e.g. yazi
WEB_CMD=""     # Optional override, e.g. lynx
EDIT_CMD=""    # Optional override, e.g. micro
SYS_CMD=""     # Optional override, e.g. btop
CFG

write_file "$APP_DIR/main.py" 0755 <<'PYEOF'
#!/usr/bin/env python3
"""Clickable character-cell TUI shell. Return codes are handled by run.sh."""

from __future__ import annotations

from datetime import datetime
from pathlib import Path

from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical
from textual.reactive import reactive
from textual.widgets import Button, Footer, Header, Static

EXIT_CODES = {
    "files": 1, "web": 2, "edit": 3, "sys": 4,
    "game": 5, "off": 6, "reboot": 7,
}


class TUIOS(App[int]):
    TITLE = "TUI OS"
    BINDINGS = [("ctrl+q", "quit_shell", "Quit to shell")]

    CSS = """
    Screen { background: #05080f; }
    #menubar {
        height: 3; dock: top; background: #0a1424;
        border: round #1d4ed8; padding: 0 1;
    }
    #menubar Button { width: auto; min-width: 9; margin-right: 1; }
    #workspace { height: 1fr; padding: 1; }
    .panel { border: round #1d4ed8; background: #080d18; padding: 1 2; }
    #apps { width: 1fr; }
    #info { width: 2fr; }
    Button {
        width: 100%; height: 3; margin: 0 0 1 0;
        background: #0d1b33; color: #60a5fa; border: tall #1e3a8a;
    }
    Button:hover { background: #1d4ed8; color: #ffffff; text-style: bold; }
    Button.-primary { color: #34d399; border: tall #065f46; }
    Button.-primary:hover { background: #065f46; color: #ecfdf5; }
    Button.-danger { color: #f87171; border: tall #7f1d1d; }
    Button.-danger:hover { background: #7f1d1d; color: #fef2f2; }
    #clock { color: #34d399; padding: 1 2; width: 1fr; }
    .panel-title { color: #93c5fd; text-style: bold; margin-bottom: 1; }
    #stats { color: #a5b4fc; }
    """

    clock = reactive("")

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Horizontal(id="menubar"):
            yield Button("FILES", id="top_files")
            yield Button("WEB", id="top_web")
            yield Button("EDIT", id="top_edit")
            yield Button("SYS", id="top_sys")
            yield Button("GAME", id="top_game", variant="primary")
            yield Static("", id="clock")
        with Horizontal(id="workspace"):
            with Vertical(classes="panel", id="apps"):
                yield Static("[ applications ]", classes="panel-title")
                yield Button("File Manager", id="files")
                yield Button("Text Web Browser", id="web")
                yield Button("Editor", id="edit")
                yield Button("System Monitor", id="sys")
                yield Button("LAUNCH GAME", id="game", variant="primary")
                yield Button("Power Off", id="off", variant="danger")
                yield Button("Reboot", id="reboot", variant="danger")
            with Vertical(classes="panel", id="info"):
                yield Static("[ node status ]", classes="panel-title")
                yield Static("", id="stats")
        yield Footer()

    def on_mount(self) -> None:
        self._tick()
        self.set_interval(1.0, self._tick)

    def _tick(self) -> None:
        self.clock = datetime.now().strftime("%H:%M:%S  %Y-%m-%d")
        self.query_one("#clock", Static).update(self.clock)
        self.query_one("#stats", Static).update(self._sysinfo())

    @staticmethod
    def _sysinfo() -> str:
        try:
            load = " ".join(Path("/proc/loadavg").read_text().split()[:3])
            mem = {}
            for line in Path("/proc/meminfo").read_text().splitlines():
                key, value = line.split(":", 1)
                mem[key] = int(value.split()[0])
            total = mem["MemTotal"]
            available = mem["MemAvailable"]
            pct = max(0, min(100, 100 * (total - available) // total))
            blocks = pct // 5
            bar = "█" * blocks + "░" * (20 - blocks)
            uptime = int(float(Path("/proc/uptime").read_text().split()[0]))
            days, rem = divmod(uptime, 86400)
            hours, rem = divmod(rem, 3600)
            minutes, _ = divmod(rem, 60)
            return (
                f"load   {load}\n"
                f"mem    {bar} {pct:>3}%\n"
                f"up     {days}d {hours:02d}:{minutes:02d}\n\n"
                "Select an item to launch it.\n"
                "Ctrl+Q returns to the login shell."
            )
        except (OSError, ValueError, KeyError, ZeroDivisionError):
            return "System status unavailable."

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id or ""
        action = button_id.removeprefix("top_")
        self.exit(EXIT_CODES.get(action, 0))

    def action_quit_shell(self) -> None:
        self.exit(0)


if __name__ == "__main__":
    import sys
    sys.exit(int(TUIOS().run() or 0))
PYEOF

write_file "$APP_DIR/run.sh" 0755 <<'RUNEOF'
#!/usr/bin/env bash
set -u
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -r "$DIR/config.sh" ]] && source "$DIR/config.sh"

PY="$DIR/.venv/bin/python"
if [[ ! -x "$PY" ]]; then
    printf 'TUI OS: Python virtual environment is missing: %s\n' "$PY" >&2
    printf 'Re-run the installer to repair it.\n' >&2
    read -r -p 'Press Enter to exit...'
    exit 1
fi

resolve() {
    local cmd
    for cmd in "$@"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            command -v "$cmd"
            return 0
        fi
    done
    return 1
}

FILES_BIN="${FILES_CMD:-$(resolve yazi ranger nnn mc || true)}"
WEB_BIN="${WEB_CMD:-$(resolve lynx links elinks || true)}"
EDIT_BIN="${EDIT_CMD:-$(resolve micro helix nano vi || true)}"
SYS_BIN="${SYS_CMD:-$(resolve btop htop top || true)}"

pause_message() {
    printf '\n%s\n' "$*"
    read -r -p 'Press Enter to return...' _ || true
}

launch() {
    clear
    "$@"
    local rc=$?
    clear
    return "$rc"
}

if ! "$PY" -c 'import textual' >/dev/null 2>&1; then
    printf 'TUI OS: Textual is not installed in %s\n' "$PY" >&2
    printf 'Re-run the installer with network access to install it.\n' >&2
    read -r -p 'Press Enter to exit...' _ || true
    exit 1
fi

while true; do
    "$PY" "$DIR/main.py"
    rc=$?
    case "$rc" in
        1)
            if [[ -n "$FILES_BIN" ]]; then launch "$FILES_BIN" || true
            else pause_message "No file manager found. Install yazi or configure FILES_CMD."; fi
            ;;
        2)
            if [[ -n "$WEB_BIN" ]]; then launch "$WEB_BIN" https://text.npr.org || true
            else pause_message "No text browser found. Install lynx or configure WEB_CMD."; fi
            ;;
        3)
            if [[ -n "$EDIT_BIN" ]]; then launch "$EDIT_BIN" || true
            else pause_message "No editor found. Install micro or configure EDIT_CMD."; fi
            ;;
        4)
            if [[ -n "$SYS_BIN" ]]; then launch "$SYS_BIN" || true
            else pause_message "No system monitor found. Install btop or configure SYS_CMD."; fi
            ;;
        5)
            if [[ -z "${GAME_COMMAND:-}" ]]; then
                pause_message "No game configured. Edit $DIR/config.sh and set GAME_COMMAND."
                continue
            fi
            if ! command -v openvt >/dev/null 2>&1; then
                pause_message "openvt is unavailable; install util-linux and check tty2 permissions."
                continue
            fi
            # The command runs as the logged-in user, not as root. Direct-console
            # GPU games may additionally require correct seat/device permissions.
            clear
            if openvt -c 2 -s -- /usr/bin/bash -lc "$GAME_COMMAND"; then
                clear
            else
                clear
                pause_message "Game launch on tty2 failed. Check GAME_COMMAND and console permissions."
            fi
            ;;
        6)
            sudo poweroff
            pause_message "Poweroff did not complete (cancelled or permission denied)."
            ;;
        7)
            sudo reboot
            pause_message "Reboot did not complete (cancelled or permission denied)."
            ;;
        *)
            clear
            exit 0
            ;;
    esac
done
RUNEOF

say "Creating Python virtual environment and installing Textual"
if (( DRY_RUN )); then
    printf '  (dry-run) sudo -u %q python -m venv %q\n' "$REAL_USER" "$APP_DIR/.venv"
    printf '  (dry-run) %q install textual\n' "$APP_DIR/.venv/bin/pip"
else
    if [[ ! -x "$APP_DIR/.venv/bin/python" ]]; then
        run sudo -u "$REAL_USER" python -m venv "$APP_DIR/.venv"
    fi
    run chown -R "$REAL_USER:$REAL_GROUP" "$APP_DIR"
    if ! sudo -u "$REAL_USER" "$APP_DIR/.venv/bin/python" -m pip install --upgrade textual; then
        die "Could not install Textual. Check network access and retry; autologin has not been configured."
    fi
fi

say "Configuring tty1 autologin"
if [[ -e "$GETTY_OVERRIDE" && ! -e "$GETTY_OVERRIDE.tui-os.bak" ]]; then
    if (( DRY_RUN )); then
        say "(dry-run) back up existing $GETTY_OVERRIDE"
    else
        cp -a "$GETTY_OVERRIDE" "$GETTY_OVERRIDE.tui-os.bak"
    fi
fi
write_file "$GETTY_OVERRIDE" 0644 <<EOF
[Service]
ExecStart=
ExecStart=-/usr/bin/agetty --autologin $REAL_USER --noclear %I linux
EOF

say "Adding a guarded TUI launch hook to $PROFILE"
if (( DRY_RUN )); then
    say "(dry-run) back up and add the TUI hook in $PROFILE"
else
    touch "$PROFILE"
    chown "$REAL_USER:$REAL_GROUP" "$PROFILE"
    if ! grep -Fq "$MARK_BEGIN" "$PROFILE"; then
        cp -a "$PROFILE" "$PROFILE.tui-os.bak"
        cat >>"$PROFILE" <<'HOOK'

# >>> TUI OS >>>
if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" &&
      "$(tty 2>/dev/null || true)" == "/dev/tty1" &&
      -x "$HOME/my_tui_os/run.sh" ]]; then
    "$HOME/my_tui_os/run.sh"
fi
# <<< TUI OS <<<
HOOK
        chown "$REAL_USER:$REAL_GROUP" "$PROFILE"
    else
        warn "TUI OS hook already exists in $PROFILE; leaving it unchanged."
    fi
fi

if (( ! DRY_RUN )); then
    systemctl daemon-reload
    # Validate the installed unit before asking systemd to use it.
    systemd-analyze verify "$GETTY_OVERRIDE" >/dev/null 2>&1 ||
        warn "systemd-analyze could not verify the override; inspect $GETTY_OVERRIDE before rebooting."
fi

say "INSTALL COMPLETE"
cat <<EOF

  Next boot: tty1 autologin -> TUI OS
  Exit TUI:  Ctrl+Q (returns to the login shell)
  Switch to another VT manually: Ctrl+Alt+F2
  Configure a game: $APP_DIR/config.sh
  Uninstall: sudo $0 --uninstall
  Uninstall and delete app files: sudo $0 --uninstall --purge

  Security note: tty1 autologin bypasses the account password on that console.
  Game-on-tty2 support depends on console permissions and the game's graphics/audio
  setup; it is not a guarantee that every desktop/Steam game can run without a
  graphical session.
EOF
