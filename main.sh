#!/usr/bin/env bash
#
# SmallSur-XFCE installer / reconciler for Linux Mint XFCE
#
# Goal:
#   Reproduce the visual setup of SmallSur manually, but with:
#     - preflight checks
#     - post-step verification
#     - backups before modifying XFCE panel config
#     - idempotent installation
#     - log file
#     - no root execution of user-level theme commands
#
# Upstream components:
#   SmallSur:          https://github.com/jothi-prasath/SmallSur
#   WhiteSur GTK:      https://github.com/vinceliuice/WhiteSur-gtk-theme
#   WhiteSur icons:    https://github.com/vinceliuice/WhiteSur-icon-theme
#   WhiteSur cursors:  https://github.com/vinceliuice/WhiteSur-cursors
#
# Usage:
#   chmod +x install-smallsur-xfce.sh
#   ./install-smallsur-xfce.sh
#
# Optional:
#   DRY_RUN=1 ./install-smallsur-xfce.sh
#

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly STATE_DIR="${HOME}/.local/state/smallsur-xfce"
readonly WORK_DIR="${STATE_DIR}/src"
readonly LOG_FILE="${STATE_DIR}/install.log"
readonly BACKUP_DIR="${STATE_DIR}/backups"

readonly SMALLSUR_REPO="https://github.com/jothi-prasath/SmallSur.git"
readonly WHITESUR_GTK_REPO="https://github.com/vinceliuice/WhiteSur-gtk-theme.git"
readonly WHITESUR_ICON_REPO="https://github.com/vinceliuice/WhiteSur-icon-theme.git"
readonly WHITESUR_CURSOR_REPO="https://github.com/vinceliuice/WhiteSur-cursors.git"

readonly GTK_THEME="WhiteSur-dark"
readonly ICON_THEME="WhiteSur-dark"
readonly CURSOR_THEME="WhiteSur Cursors"

DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$STATE_DIR" "$WORK_DIR" "$BACKUP_DIR"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { printf '[%s] %s\n' "INFO" "$*"; }
ok()   { printf '[%s] %s\n' " OK " "$*"; }
warn() { printf '[%s] %s\n' "WARN" "$*"; }
die()  { printf '[%s] %s\n' "FAIL" "$*" >&2; exit 1; }

trap 'die "Unexpected error at line $LINENO. See $LOG_FILE"' ERR

run() {
    if (( DRY_RUN )); then
        printf '[DRY ]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

is_pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'
}

apt_has_package() {
    apt-cache show "$1" >/dev/null 2>&1
}

apt_install_if_available() {
    local pkg
    local missing=()

    for pkg in "$@"; do
        if is_pkg_installed "$pkg"; then
            continue
        fi
        if apt_has_package "$pkg"; then
            missing+=("$pkg")
        else
            warn "APT package unavailable in current repositories: $pkg"
        fi
    done

    if ((${#missing[@]})); then
        log "Installing: ${missing[*]}"
        run sudo apt-get install -y "${missing[@]}"
    fi
}

verify_pkg() {
    local pkg
    for pkg in "$@"; do
        if ! is_pkg_installed "$pkg"; then
            die "Package verification failed: $pkg"
        fi
    done
}

clone_or_update() {
    local url="$1"
    local dir="$2"

    if [[ -d "$dir/.git" ]]; then
        log "Updating $(basename "$dir")"
        (
            cd "$dir"
            run git fetch --depth=1 origin
            run git reset --hard origin/HEAD
        )
    else
        rm -rf "$dir"
        log "Cloning $(basename "$dir")"
        run git clone --depth=1 "$url" "$dir"
    fi

    [[ -d "$dir/.git" ]] || die "Repository verification failed: $dir"
}

verify_dir() {
    [[ -d "$1" ]] || die "Directory missing: $1"
}

backup_once() {
    local src="$1"
    local name="$2"
    local dst="${BACKUP_DIR}/${name}"

    if [[ -e "$src" && ! -e "$dst" ]]; then
        log "Backing up $src -> $dst"
        run cp -a "$src" "$dst"
        ok "Backup created: $dst"
    fi
}

xfconf_get() {
    xfconf-query "$1" "$2" 2>/dev/null || true
}

set_xfconf() {
    local channel="$1"
    local prop="$2"
    local type="$3"
    local value="$4"

    if xfconf-query -c "$channel" -p "$prop" >/dev/null 2>&1; then
        run xfconf-query -c "$channel" -p "$prop" -s "$value"
    else
        run xfconf-query -c "$channel" -p "$prop" -n -t "$type" -s "$value"
    fi
}

verify_xfconf() {
    local channel="$1"
    local prop="$2"
    local expected="$3"
    local actual

    actual="$(xfconf-query -c "$channel" -p "$prop" 2>/dev/null || true)"
    [[ "$actual" == "$expected" ]] || die "XFConf verification failed: $channel:$prop (expected '$expected', got '$actual')"
}

restart_user_services() {
    if (( DRY_RUN )); then
        return 0
    fi

    if pgrep -x xfce4-panel >/dev/null 2>&1; then
        xfce4-panel -r >/dev/null 2>&1 || true
    else
        xfce4-panel >/dev/null 2>&1 &
    fi

    if pgrep -x plank >/dev/null 2>&1; then
        killall plank >/dev/null 2>&1 || true
    fi
    plank >/dev/null 2>&1 &
}

verify_desktop() {
    [[ "${XDG_CURRENT_DESKTOP:-}" =~ XFCE|Xfce ]] ||
        die "This script is intended for an XFCE session. Current desktop: ${XDG_CURRENT_DESKTOP:-unknown}"

    [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]] ||
        die "No graphical session detected."

    command -v xfconf-query >/dev/null 2>&1 ||
        die "xfconf-query is unavailable."
}

# -------------------------------
# Step 1: Preflight
# -------------------------------

log "=== SmallSur/XFCE setup started ==="
log "Log file: $LOG_FILE"

need_cmd bash
need_cmd sudo
need_cmd apt-get
need_cmd apt-cache
need_cmd dpkg-query

verify_desktop

if [[ $EUID -eq 0 ]]; then
    die "Do not run this script as root. Run it as your normal Mint user."
fi

if [[ -f /etc/linuxmint/info ]]; then
    log "Linux Mint detected."
else
    warn "This does not look like Linux Mint. The script will continue only because XFCE is detected."
fi

# -------------------------------
# Step 2: Base packages
# -------------------------------

log "=== Installing base packages ==="

run sudo apt-get update

apt_install_if_available \
    git \
    curl \
    wget \
    ca-certificates \
    xfce4-goodies \
    xfce4-power-manager \
    plank \
    xfce4-whiskermenu-plugin \
    sassc \
    libglib2.0-dev-bin \
    libglib2.0-dev \
    libxml2-utils \
    imagemagick \
    optipng \
    inkscape

# Global menu: prefer the XFCE panel plugin.
if apt_has_package xfce4-appmenu-plugin; then
    apt_install_if_available \
        xfce4-appmenu-plugin \
        appmenu-gtk2-module \
        appmenu-gtk3-module
else
    warn "xfce4-appmenu-plugin is not available from current APT repositories."
    warn "Global menu will be skipped rather than installing an unverified package."
fi

verify_pkg git plank
ok "Core packages verified."

# -------------------------------
# Step 3: Sources
# -------------------------------

log "=== Obtaining upstream sources ==="

clone_or_update "$SMALLSUR_REPO" "${WORK_DIR}/SmallSur"
clone_or_update "$WHITESUR_GTK_REPO" "${WORK_DIR}/WhiteSur-gtk-theme"
clone_or_update "$WHITESUR_ICON_REPO" "${WORK_DIR}/WhiteSur-icon-theme"
clone_or_update "$WHITESUR_CURSOR_REPO" "${WORK_DIR}/WhiteSur-cursors"

verify_dir "${WORK_DIR}/SmallSur"
verify_dir "${WORK_DIR}/WhiteSur-gtk-theme"
verify_dir "${WORK_DIR}/WhiteSur-icon-theme"
verify_dir "${WORK_DIR}/WhiteSur-cursors"

# -------------------------------
# Step 4: GTK / XFWM / Plank theme
# -------------------------------

log "=== Installing WhiteSur GTK/XFWM/Plank theme ==="

GTK_INSTALL="${WORK_DIR}/WhiteSur-gtk-theme/install.sh"
[[ -x "$GTK_INSTALL" ]] || chmod +x "$GTK_INSTALL"

# Use user-level installation. Do NOT use sudo here.
run "$GTK_INSTALL" -c dark -c light

[[ -d "${HOME}/.themes" ]] || die "~/.themes was not created."

# The upstream installer currently installs XFCE/XFWM and Plank theme files
# as part of the main WhiteSur theme pack.
if [[ ! -d "${HOME}/.themes/WhiteSur-dark" ]]; then
    die "WhiteSur-dark was not installed under ~/.themes"
fi

if [[ ! -d "${HOME}/.themes/WhiteSur" && ! -d "${HOME}/.themes/WhiteSur-light" ]]; then
    warn "Some expected light/default WhiteSur variants are not present; dark theme is present."
fi

ok "WhiteSur GTK/XFWM theme verified."

# -------------------------------
# Step 5: Icons
# -------------------------------

log "=== Installing WhiteSur icons ==="

ICON_INSTALL="${WORK_DIR}/WhiteSur-icon-theme/install.sh"
[[ -x "$ICON_INSTALL" ]] || chmod +x "$ICON_INSTALL"

run "$ICON_INSTALL"

ICON_ROOT="${HOME}/.local/share/icons"
[[ -d "$ICON_ROOT/WhiteSur" ]] || die "WhiteSur icon theme not found in ~/.local/share/icons"

# Current upstream installer uses WhiteSur, WhiteSur-dark and WhiteSur-light variants.
if [[ ! -d "$ICON_ROOT/WhiteSur-dark" ]]; then
    warn "WhiteSur-dark icon variant is not present; falling back to WhiteSur for verification."
fi

ok "WhiteSur icons verified."

# -------------------------------
# Step 6: Cursors
# -------------------------------

log "=== Installing WhiteSur cursors ==="

CURSOR_INSTALL="${WORK_DIR}/WhiteSur-cursors/install.sh"
[[ -x "$CURSOR_INSTALL" ]] || chmod +x "$CURSOR_INSTALL"

run "$CURSOR_INSTALL"

CURSOR_DIR="$ICON_ROOT/$CURSOR_THEME"

if [[ ! -d "$CURSOR_DIR" ]]; then
    # Different upstream revisions can normalize spacing differently.
    alt="$(find "$ICON_ROOT" -maxdepth 1 -mindepth 1 -type d \
        \( -iname 'WhiteSur*Cursor*' -o -iname 'whitesur*cursor*' \) \
        -print -quit 2>/dev/null || true)"

    if [[ -n "$alt" ]]; then
        warn "Cursor directory found under alternate name: $(basename "$alt")"
        CURSOR_THEME="$(basename "$alt")"
        CURSOR_DIR="$alt"
    else
        die "WhiteSur cursor theme was not installed."
    fi
fi

[[ -d "$CURSOR_DIR/cursors" ]] || die "Cursor theme exists but has no cursors directory."
ok "WhiteSur cursors verified: $CURSOR_DIR"

# -------------------------------
# Step 7: Plank themes
# -------------------------------

log "=== Installing Plank themes ==="

PLANK_THEME_DIR="${HOME}/.local/share/plank/themes"
run mkdir -p "$PLANK_THEME_DIR"

# WhiteSur currently ships Plank themes inside the GTK repository.
if [[ -d "${WORK_DIR}/WhiteSur-gtk-theme/src/other/plank" ]]; then
    run cp -a "${WORK_DIR}/WhiteSur-gtk-theme/src/other/plank/." "$PLANK_THEME_DIR/"
else
    warn "WhiteSur Plank theme directory not found in upstream source."
fi

# SmallSur also carries an additional Plank theme.
if [[ -d "${WORK_DIR}/SmallSur/plank" ]]; then
    found_plank=0
    while IFS= read -r -d '' theme_dir; do
        cp -a "$theme_dir" "$PLANK_THEME_DIR/" 2>/dev/null || true
        found_plank=1
    done < <(find "${WORK_DIR}/SmallSur/plank" -mindepth 1 -maxdepth 1 -type d -print0)

    (( found_plank )) || warn "No SmallSur-specific Plank directories found."
fi

if find "$PLANK_THEME_DIR" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then
    ok "Plank themes verified."
else
    warn "No Plank theme directory was found. Plank itself is still installed."
fi

# -------------------------------
# Step 8: Wallpapers
# -------------------------------

log "=== Installing SmallSur wallpapers ==="

PICTURES_DIR="${HOME}/Pictures"
SMALLSUR_WALLPAPER_DIR="${PICTURES_DIR}/SmallSur"
run mkdir -p "$SMALLSUR_WALLPAPER_DIR"

if [[ -d "${WORK_DIR}/SmallSur/wallpaper" ]]; then
    run cp -a "${WORK_DIR}/SmallSur/wallpaper/." "$SMALLSUR_WALLPAPER_DIR/"
else
    warn "SmallSur wallpaper directory not found."
fi

wallpaper_count="$(find "$SMALLSUR_WALLPAPER_DIR" -type f \
    \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.webp' \) \
    2>/dev/null | wc -l)"

if (( wallpaper_count > 0 )); then
    ok "Wallpaper set verified: $wallpaper_count image(s)."
else
    warn "No SmallSur wallpapers were found."
fi

# -------------------------------
# Step 9: Backup current XFCE config
# -------------------------------

log "=== Backing up current XFCE panel configuration ==="

PANEL_XML_DIR="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
PANEL_XML="${PANEL_XML_DIR}/xfce4-panel.xml"

run mkdir -p "$PANEL_XML_DIR"

backup_once "$PANEL_XML" "xfce4-panel.xml.$(date +%Y%m%d-%H%M%S).bak"

# -------------------------------
# Step 10: SmallSur panel layout
# -------------------------------

log "=== Applying SmallSur XFCE panel layout ==="

UPSTREAM_PANEL_XML="${WORK_DIR}/SmallSur/xfce4-panel/xfce4-panel.xml"

if [[ -f "$UPSTREAM_PANEL_XML" ]]; then
    # Stop panel before replacing its saved configuration.
    if ! (( DRY_RUN )); then
        killall xfce4-panel >/dev/null 2>&1 || true
    fi

    run cp -a "$UPSTREAM_PANEL_XML" "$PANEL_XML"
    [[ -f "$PANEL_XML" ]] || die "Panel configuration copy failed."
    ok "SmallSur panel XML installed."

    # Starting the panel validates that XFCE can parse the configuration.
    if ! (( DRY_RUN )); then
        xfce4-panel >/tmp/smallsur-xfce-panel-start.log 2>&1 &
        sleep 2
        if ! pgrep -x xfce4-panel >/dev/null 2>&1; then
            warn "SmallSur panel configuration did not start XFCE panel. Restoring backup is recommended."
            die "xfce4-panel could not be started after applying SmallSur layout."
        fi
    fi
else
    warn "SmallSur panel XML not found; leaving your existing panel configuration unchanged."
fi

# -------------------------------
# Step 11: Apply theme through XFConf
# -------------------------------

log "=== Applying GTK, icon and cursor themes ==="

set_xfconf xsettings /Net/ThemeName string "$GTK_THEME"

# Match SmallSur's own setting when available; otherwise use WhiteSur.
if xfconf-query -c xsettings -p /Net/IconThemeName >/dev/null 2>&1 || true; then
    if [[ -d "$ICON_ROOT/$ICON_THEME" ]]; then
        set_xfconf xsettings /Net/IconThemeName string "$ICON_THEME"
    else
        set_xfconf xsettings /Net/IconThemeName string "WhiteSur"
    fi
fi

set_xfconf xsettings /Gtk/CursorThemeName string "$CURSOR_THEME"

verify_xfconf xsettings /Net/ThemeName "$GTK_THEME"

ICON_ACTUAL="$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || true)"
if [[ "$ICON_ACTUAL" != "$ICON_THEME" && "$ICON_ACTUAL" != "WhiteSur" ]]; then
    die "Icon theme verification failed: got '$ICON_ACTUAL'"
fi

CURSOR_ACTUAL="$(xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null || true)"
[[ "$CURSOR_ACTUAL" == "$CURSOR_THEME" ]] ||
    die "Cursor theme verification failed: expected '$CURSOR_THEME', got '$CURSOR_ACTUAL'"

ok "XFConf theme settings verified."

# -------------------------------
# Step 12: XFWM window manager
# -------------------------------

log "=== Applying XFWM theme ==="

XFWM_STYLE="$GTK_THEME"
if xfconf-query -c xfwm4 -p /general/theme >/dev/null 2>&1; then
    run xfconf-query -c xfwm4 -p /general/theme -s "$XFWM_STYLE"
else
    run xfconf-query -c xfwm4 -p /general/theme -n -t string -s "$XFWM_STYLE"
fi

XFWM_ACTUAL="$(xfconf-query -c xfwm4 -p /general/theme 2>/dev/null || true)"
[[ "$XFWM_ACTUAL" == "$XFWM_STYLE" ]] ||
    die "XFWM theme verification failed: expected '$XFWM_STYLE', got '$XFWM_ACTUAL'"

# Enable compositor for the Big Sur-like desktop effects.
if xfconf-query -c xfwm4 -p /general/use_compositing >/dev/null 2>&1; then
    run xfconf-query -c xfwm4 -p /general/use_compositing -s true
else
    run xfconf-query -c xfwm4 -p /general/use_compositing -n -t bool -s true
fi

ok "XFWM theme/compositing verified."

# -------------------------------
# Step 13: Create/update Plank autostart
# -------------------------------

log "=== Configuring Plank autostart ==="

AUTOSTART_DIR="${HOME}/.config/autostart"
PLANK_DESKTOP="${AUTOSTART_DIR}/plank.desktop"

run mkdir -p "$AUTOSTART_DIR"

run tee "$PLANK_DESKTOP" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Plank
Comment=macOS-style application dock
Exec=plank
Terminal=false
OnlyShowIn=XFCE;
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF

[[ -f "$PLANK_DESKTOP" ]] || die "Plank autostart file was not created."
grep -q '^Exec=plank$' "$PLANK_DESKTOP" ||
    die "Plank autostart verification failed."

ok "Plank autostart verified."

# -------------------------------
# Step 14: Optional global menu
# -------------------------------

log "=== Checking global menu support ==="

if is_pkg_installed xfce4-appmenu-plugin; then
    ok "xfce4-appmenu-plugin is installed."
else
    warn "Global menu plugin is not installed; this component depends on repository support."
fi

# GTK modules differ slightly across Mint/Ubuntu releases.
if is_pkg_installed appmenu-gtk2-module || is_pkg_installed appmenu-gtk3-module; then
    ok "AppMenu GTK module package(s) verified."
else
    warn "AppMenu GTK modules are not installed. Global menus may not appear in every GTK application."
fi

# -------------------------------
# Step 15: Reload session components
# -------------------------------

log "=== Reloading XFCE components ==="

restart_user_services
sleep 2

# Re-verify after reload.
verify_xfconf xsettings /Net/ThemeName "$GTK_THEME"

XFWM_AFTER="$(xfconf-query -c xfwm4 -p /general/theme 2>/dev/null || true)"
[[ "$XFWM_AFTER" == "$XFWM_STYLE" ]] ||
    die "Post-reload XFWM verification failed."

if ! pgrep -x plank >/dev/null 2>&1 && ! (( DRY_RUN )); then
    warn "Plank is not currently running. It will be started automatically on next login."
else
    ok "Plank process verified."
fi

# -------------------------------
# Step 16: Final report
# -------------------------------

printf '\n'
log "=== FINAL VERIFICATION ==="

checks=0
passed=0

check_path() {
    local p="$1"
    local label="$2"
    ((checks+=1))
    if [[ -e "$p" ]]; then
        ok "$label"
        ((passed+=1))
    else
        warn "Missing: $label -> $p"
    fi
}

check_path "${HOME}/.themes/WhiteSur-dark" "WhiteSur-dark GTK theme"
check_path "$ICON_ROOT/WhiteSur" "WhiteSur icon theme"
check_path "$CURSOR_DIR/cursors" "WhiteSur cursor theme"
check_path "$PLANK_THEME_DIR" "Plank theme directory"
check_path "$PLANK_DESKTOP" "Plank autostart"
check_path "$PANEL_XML" "XFCE panel configuration"
check_path "$SMALLSUR_WALLPAPER_DIR" "SmallSur wallpaper directory"

printf '\n'
printf 'Theme:   %s\n' "$(xfconf-query -c xsettings -p /Net/ThemeName 2>/dev/null || echo '<unknown>')"
printf 'Icons:   %s\n' "$(xfconf-query -c xsettings -p /Net/IconThemeName 2>/dev/null || echo '<unknown>')"
printf 'Cursor:  %s\n' "$(xfconf-query -c xsettings -p /Gtk/CursorThemeName 2>/dev/null || echo '<unknown>')"
printf 'XFWM:    %s\n' "$(xfconf-query -c xfwm4 -p /general/theme 2>/dev/null || echo '<unknown>')"
printf 'Log:     %s\n' "$LOG_FILE"
printf 'Backup:  %s\n' "$BACKUP_DIR"

if (( passed == checks )); then
    ok "ALL FILE/CONFIGURATION CHECKS PASSED ($passed/$checks)."
else
    warn "Completed with $passed/$checks checks passing. Review $LOG_FILE."
fi

printf '\n'
warn "A full logout/login is recommended so every GTK/desktop component reloads cleanly."
warn "Do NOT run this script with sudo."
log "=== SmallSur/XFCE setup finished ==="
