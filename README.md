# TUI OS

A text-based shell for Linux that boots into a character-cell interface and switches virtual terminals to launch graphical applications.

## Description

TUI OS is a shell environment for minimal Linux installations. It provides a mouse-driven, grid-based interface rendered with text characters. Graphical applications are launched by switching to a dedicated virtual terminal, then returning to the shell on exit. The implementation uses Python and the Textual framework.

## Requirements

- Minimal Linux installation with no desktop environment (Ubuntu Server, Debian, Arch, or equivalent)
- sudo privileges
- python3 and python3-venv
- Terminal emulator with 256-color support and mouse reporting
- possibly gpm and 

Optional dependencies (installed by the script if available, otherwise the shell falls back):

| Tool | Function |
|---|---|
| yazi or ranger | File manager |
| btop or htop | System monitor |
| micro or helix | Text editor |
| lynx or links | Text-mode web browser |

## Installation
```bash
git clone https://github.com/yourname/tui-os.git
cd tui-os
chmod +x tui-os-installer.sh
sudo ./tui-os-installer.sh --dry-run
sudo ./tui-os-installer.sh
sudo reboot
```
The installer performs the following:

- Installs core system packages and optional TUI tools
- Creates ~/my_tui_os/ containing the shell, session driver, and configuration
- Initializes a Python virtual environment and installs the textual package
- Adds a sudoers entry permitting passwordless execution of chvt
- Configures TTY1 autologin via a systemd unit override
- Appends a marker-guarded block to ~/.bashrc (original file is backed up)

The installer is idempotent.

## Configuration
Edit ~/my_tui_os/config.sh:
```bash
GAME_COMMAND="steam --fullscreen steam://rungameid/2300"
FILES_CMD="yazi"
WEB_CMD="lynx"
EDIT_CMD="micro"
SYS_CMD="btop"
```
Changes take effect on the next shell launch.

## Usage

Click any button to launch the corresponding application. Hovering over a button highlights it. Press ```Ctrl+Q``` to exit the shell and return to a standard shell prompt.

## Recovery

If the shell becomes unresponsive or the configuration prevents normal boot:

- ```Ctrl+Alt+F2``` switches to a standard login on TTY2
- ```Ctrl+Alt+F1``` returns to the shell on TTY1

From TTY2, the configuration can be edited or the project uninstalled.

## Uninstallation
```bash
sudo ./tui-os-installer.sh --uninstall
sudo ./tui-os-installer.sh --uninstall --purge
```

The first command removes hooks and the sudoers entry but retains the application directory. The second command removes all installed files. The original ~/.bashrc is restored from the backup created during installation.

## Troubleshooting

**Graphical application fails to launch.** The virtual terminal handoff requires applications that can run without a display server. Verify the mechanism with a simple application such as glxgears before configuring a full game. Prefer native Linux ports over applications that depend on X11 or Wayland. Confirm the user is a member of the video group: sudo usermod -aG video $USER

**Shell does not start on boot.** Verify the .bashrc hook is present: grep "TUI OS" ~/.bashrc. Inspect the systemd override: systemctl cat getty@tty1.service. Review service logs: journalctl -u getty@tty1.service

**Mouse input is not recognized.** The terminal emulator must support mouse reporting. Most current terminal emulators provide this by default. When connecting via SSH, verify the client is configured to forward mouse events.

**Unable to exit the shell.** Ctrl+Q terminates the shell. If this is ineffective, Ctrl+Alt+F2 provides access to a working login session.

## Contributing

Contributions are accepted. Areas of interest include improved detection of available virtual terminals, packaging for additional distributions, and bug reports with journalctl output.

## License

MIT License.
