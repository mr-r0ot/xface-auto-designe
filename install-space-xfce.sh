#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# SPACE XFCE — macOS-like / premium XFCE setup
#
# Target:
#   Linux Mint XFCE
#   Ubuntu/Debian XFCE
#
# Main components:
#   Space-dark GTK/XFWM
#   Hatter Icons
#   XFCE Cupertino panel layout
#   XFCE AppMenu / global menu
#   Picom blur + shadows + fading
#   Floating Plank dock
#   Inter + JetBrains Mono
#   macOS-like wallpaper handling
#   XFCE autostart
#
# Safe behavior:
#   - User configuration is backed up.
#   - Themes are installed per-user.
#   - No system files are overwritten except packages.
#
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

log() {
    echo -e "${CYAN}[SPACE]${RESET} $*"
}

ok() {
    echo -e "${GREEN}[  OK ]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[ WARN ]${RESET} $*"
}

fail() {
    echo -e "${RED}[ FAIL ]${RESET} $*" >&2
    exit 1
}

cleanup() {
    [[ -n "${WORKDIR:-}" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Basic checks
# ------------------------------------------------------------

[[ $EUID -ne 0 ]] || fail "Run this as your normal user, not root."

command -v apt-get >/dev/null 2>&1 ||
    fail "This script requires a Debian/Ubuntu/Mint based distribution."

command -v xfconf-query >/dev/null 2>&1 ||
    fail "XFCE is not installed or this is not an XFCE session."

if [[ -z "${DISPLAY:-}" ]]; then
    fail "No X11 DISPLAY detected. This setup is designed for XFCE/X11."
fi

if [[ "${XDG_CURRENT_DESKTOP:-}" != *XFCE* &&
      "${XDG_CURRENT_DESKTOP:-}" != *Xfce* &&
      "${DESKTOP_SESSION:-}" != *xfce* &&
      "${DESKTOP_SESSION:-}" != *Xfce* ]]; then
    warn "Desktop was not clearly identified as XFCE."
    warn "Continuing because xfconf-query is available."
fi

# ------------------------------------------------------------
# Backup
# ------------------------------------------------------------

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$HOME/.space-xfce-backup-$STAMP"

log "Creating backup..."

mkdir -p "$BACKUP"

for ITEM in \
    "$HOME/.config/xfce4" \
    "$HOME/.config/picom" \
    "$HOME/.config/plank" \
    "$HOME/.config/autostart" \
    "$HOME/.themes" \
    "$HOME/.icons" \
    "$HOME/.local/share/icons" \
    "$HOME/.local/share/plank"
do
    if [[ -e "$ITEM" ]]; then
        cp -a "$ITEM" "$BACKUP/" 2>/dev/null || true
    fi
done

ok "Backup: $BACKUP"

# ------------------------------------------------------------
# APT
# ------------------------------------------------------------

log "Updating APT..."

sudo apt-get update

PACKAGES=(
    git
    curl
    wget
    jq
    unzip
    xz-utils
    tar
    ca-certificates

    xfce4
    xfce4-goodies
    xfce4-panel
    xfce4-panel-profiles
    xfce4-whiskermenu-plugin
    xfce4-appmenu-plugin
    xfce4-pulseaudio-plugin
    xfce4-notifyd
    xfce4-power-manager
    xfce4-terminal

    appmenu-gtk2-module
    appmenu-gtk3-module

    plank
    picom
    xfdashboard

    fonts-inter
    fonts-jetbrains-mono

    network-manager-gnome
)

log "Installing required packages..."

sudo apt-get install -y "${PACKAGES[@]}"

ok "Packages installed."

# ------------------------------------------------------------
# Workdir
# ------------------------------------------------------------

WORKDIR="$(mktemp -d)"

mkdir -p \
    "$HOME/.themes" \
    "$HOME/.icons" \
    "$HOME/.local/share/icons" \
    "$HOME/.local/share/backgrounds" \
    "$HOME/.config/picom" \
    "$HOME/.config/plank/dock1/launchers" \
    "$HOME/.config/autostart"

# ------------------------------------------------------------
# Helper: Download latest files from GNOME-Look / Pling
# ------------------------------------------------------------

download_pling_latest() {

    local PRODUCT_ID="$1"
    local DEST="$2"

    mkdir -p "$DEST"

    log "Querying GNOME-Look files for product $PRODUCT_ID..."

    local JSON

    JSON="$(
        curl -Lfs \
            -A "Mozilla/5.0" \
            "https://www.gnome-look.org/p/${PRODUCT_ID}/loadFiles"
    )" || {
        warn "Could not query GNOME-Look product $PRODUCT_ID."
        return 1
    }

    mapfile -t URLS < <(
        printf '%s' "$JSON" |
        jq -r '
            .files |
            first.version as $v |
            .[] |
            select(.version == $v) |
            .url
        ' 2>/dev/null |
        while IFS= read -r URL; do
            python3 - "$URL" <<'PY'
import sys
from urllib.parse import unquote

print(unquote(sys.argv[1]))
PY
        done
    )

    if [[ "${#URLS[@]}" -eq 0 ]]; then
        warn "No downloadable files found for product $PRODUCT_ID."
        return 1
    fi

    local URL
    for URL in "${URLS[@]}"; do
        [[ -n "$URL" ]] || continue

        local NAME
        NAME="$(basename "${URL%%\?*}")"

        log "Downloading: $NAME"

        curl -Lf \
            --retry 3 \
            --retry-delay 2 \
            -A "Mozilla/5.0" \
            "$URL" \
            -o "$DEST/$NAME"
    done

    return 0
}

# ------------------------------------------------------------
# Helper: extract archives
# ------------------------------------------------------------

extract_archive() {

    local FILE="$1"
    local DEST="$2"

    case "$FILE" in

        *.tar.xz)
            tar -xJf "$FILE" -C "$DEST"
            ;;

        *.tar.bz2)
            tar -xjf "$FILE" -C "$DEST"
            ;;

        *.tar.gz|*.tgz)
            tar -xzf "$FILE" -C "$DEST"
            ;;

        *.zip)
            unzip -q "$FILE" -d "$DEST"
            ;;

        *)
            warn "Unknown archive format: $(basename "$FILE")"
            ;;
    esac
}

# ============================================================
# 1. SPACE DARK
# ============================================================

log "Installing Space theme..."

SPACE_DL="$WORKDIR/space-download"
SPACE_EXTRACT="$WORKDIR/space-extracted"

mkdir -p "$SPACE_DL" "$SPACE_EXTRACT"

if download_pling_latest "2131750" "$SPACE_DL"; then

    for FILE in "$SPACE_DL"/*; do
        [[ -f "$FILE" ]] || continue
        extract_archive "$FILE" "$SPACE_EXTRACT"
    done

    FOUND_SPACE=0

    while IFS= read -r -d '' THEME_DIR; do

        [[ -f "$THEME_DIR/index.theme" ]] || continue

        NAME="$(basename "$THEME_DIR")"

        # Space dark/light themes from Pling
        if [[ "$NAME" == *Space* ]]; then

            log "Installing theme: $NAME"

            rm -rf "$HOME/.themes/$NAME"
            cp -a "$THEME_DIR" "$HOME/.themes/$NAME"

            FOUND_SPACE=1
        fi

    done < <(
        find "$SPACE_EXTRACT" \
            -type f \
            -name index.theme \
            -print0 |
        while IFS= read -r -d '' FILE; do
            dirname "$FILE"
        done |
        tr '\n' '\0'
    )

    if [[ "$FOUND_SPACE" -eq 1 ]]; then
        ok "Space theme installed from GNOME-Look."
    else
        warn "Space archives downloaded but theme folder was not detected."
    fi

else

    warn "GNOME-Look Space download failed."
    warn "Falling back to the official GitHub repository."

    git clone \
        --depth 1 \
        https://github.com/EliverLara/Space.git \
        "$WORKDIR/Space"

    rm -rf "$HOME/.themes/Space"
    cp -a "$WORKDIR/Space" "$HOME/.themes/Space"

    ok "Space GitHub theme installed."

fi

# Determine Space theme name.
SPACE_THEME=""

if [[ -d "$HOME/.themes/Space-dark" ]]; then
    SPACE_THEME="Space-dark"
elif [[ -d "$HOME/.themes/Space" ]]; then
    SPACE_THEME="Space"
else
    # Some Pling versions can use a slightly different directory.
    SPACE_THEME="$(
        find "$HOME/.themes" \
            -maxdepth 1 \
            -mindepth 1 \
            -type d \
            \( -iname '*space*dark*' -o -iname 'Space*' \) |
        head -n 1 |
        xargs -r basename
    )"
fi

[[ -n "$SPACE_THEME" ]] ||
    fail "Space theme could not be installed."

ok "Selected theme: $SPACE_THEME"

# ============================================================
# 2. HATTER ICONS
# ============================================================

log "Installing Hatter icons..."

if [[ ! -d "$WORKDIR/Hatter" ]]; then

    git clone \
        --depth 1 \
        https://github.com/Mibea/Hatter.git \
        "$WORKDIR/Hatter"

fi

if [[ -x "$WORKDIR/Hatter/install.sh" ]]; then

    (
        cd "$WORKDIR/Hatter"
        ./install.sh
    ) || warn "Hatter installer returned a non-zero status."

fi

# Hatter installer normally creates the user icon theme.
# Find it automatically.
HATTER_THEME="$(
    find \
        "$HOME/.local/share/icons" \
        "$HOME/.icons" \
        -maxdepth 2 \
        -type f \
        -name index.theme \
        -print 2>/dev/null |
    while IFS= read -r FILE; do
        DIR="$(dirname "$FILE")"
        BASE="$(basename "$DIR")"

        if [[ "$BASE" == Hatter* ]]; then
            printf '%s\n' "$BASE"
            break
        fi
    done
)"

if [[ -z "$HATTER_THEME" ]]; then

    # Direct fallback.
    for DIR in \
        "$WORKDIR/Hatter/Hatter" \
        "$WORKDIR/Hatter/Hatter-Blue" \
        "$WORKDIR/Hatter/Hatter-Slate"
    do
        if [[ -d "$DIR" && -f "$DIR/index.theme" ]]; then
            NAME="$(basename "$DIR")"

            rm -rf "$HOME/.local/share/icons/$NAME"
            mkdir -p "$HOME/.local/share/icons"

            cp -a "$DIR" "$HOME/.local/share/icons/$NAME"

            HATTER_THEME="$NAME"
            break
        fi
    done

fi

if [[ -z "$HATTER_THEME" ]]; then
    warn "Hatter icon theme was not detected."
    warn "Keeping the current icon theme."
else
    ok "Icon theme: $HATTER_THEME"
fi

# ============================================================
# 3. GTK / Xfwm
# ============================================================

log "Applying GTK theme..."

xfconf-query \
    -c xsettings \
    -p /Net/ThemeName \
    -n -t string \
    -s "$SPACE_THEME" \
    2>/dev/null || \
xfconf-query \
    -c xsettings \
    -p /Net/ThemeName \
    -s "$SPACE_THEME"

if [[ -n "$HATTER_THEME" ]]; then

    xfconf-query \
        -c xsettings \
        -p /Net/IconThemeName \
        -n -t string \
        -s "$HATTER_THEME" \
        2>/dev/null || \
    xfconf-query \
        -c xsettings \
        -p /Net/IconThemeName \
        -s "$HATTER_THEME"

fi

if [[ -d "$HOME/.themes/$SPACE_THEME/xfwm4" ]]; then

    xfconf-query \
        -c xfwm4 \
        -p /general/theme \
        -n -t string \
        -s "$SPACE_THEME" \
        2>/dev/null || \
    xfconf-query \
        -c xfwm4 \
        -p /general/theme \
        -s "$SPACE_THEME"

fi

# Inter
xfconf-query \
    -c xsettings \
    -p /Gtk/FontName \
    -n -t string \
    -s "Inter 10" \
    2>/dev/null || \
xfconf-query \
    -c xsettings \
    -p /Gtk/FontName \
    -s "Inter 10"

# Hinting / anti-aliasing
xfconf-query \
    -c xsettings \
    -p /Xft/Antialias \
    -n -t int \
    -s 1 \
    2>/dev/null || true

xfconf-query \
    -c xsettings \
    -p /Xft/Hinting \
    -n -t int \
    -s 1 \
    2>/dev/null || true

xfconf-query \
    -c xsettings \
    -p /Xft/HintStyle \
    -n -t string \
    -s "hintslight" \
    2>/dev/null || true

# ============================================================
# 4. APPMENU / GLOBAL MENU
# ============================================================

log "Configuring global AppMenu..."

xfconf-query \
    -c xsettings \
    -p /Gtk/ShellShowsMenubar \
    -n -t bool \
    -s true \
    2>/dev/null || true

xfconf-query \
    -c xsettings \
    -p /Gtk/ShellShowsAppmenu \
    -n -t bool \
    -s true \
    2>/dev/null || true

xfconf-query \
    -c xsettings \
    -p /Gtk/Modules \
    -n -t string \
    -s "appmenu-gtk-module" \
    2>/dev/null || true

export GTK_MODULES="appmenu-gtk-module"

# ============================================================
# 5. XFCE CUPERTINO PROFILE
# ============================================================

PROFILE="/usr/share/xfce4-panel-profiles/layouts/Cupertino.tar.bz2"

if [[ -f "$PROFILE" ]]; then

    log "Loading official XFCE Cupertino panel profile..."

    # Save current panel first if possible.
    if command -v xfce4-panel-profiles >/dev/null 2>&1; then

        xfce4-panel-profiles save \
            "$BACKUP/original-panel.tar.bz2" \
            >/dev/null 2>&1 || true

        xfce4-panel-profiles load "$PROFILE"

        sleep 2

    fi

    ok "Cupertino panel loaded."

else

    warn "Cupertino profile not found."
    warn "The installed xfce4-panel-profiles package may be too old."

fi

# ============================================================
# 6. TOP PANEL REFINEMENT
# ============================================================

log "Refining top panel..."

# The Cupertino profile uses panel 0 as the top menu bar.

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/size \
    -s 26 \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/icon-size \
    -s 18 \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/length \
    -s 100 \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/position \
    -s "p=6;x=0;y=0" \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/position-locked \
    -s true \
    2>/dev/null || true

# Dark translucent top bar.
xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/background-style \
    -s 0 \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/background-alpha \
    -s 82 \
    2>/dev/null || true

# RGBA: dark charcoal with transparency.
xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-0/background-rgba \
    -n \
    -a \
    -t double -s 0.055 \
    -t double -s 0.060 \
    -t double -s 0.075 \
    -t double -s 0.82 \
    2>/dev/null || true

# ============================================================
# 7. HIDE THE SECOND CUPERTINO PANEL
#    We use Plank instead for a much closer floating dock.
# ============================================================

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-1/autohide-behavior \
    -s 2 \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-1/disable-struts \
    -s true \
    2>/dev/null || true

xfconf-query \
    -c xfce4-panel \
    -p /panels/panel-1/size \
    -s 1 \
    2>/dev/null || true

# ============================================================
# 8. PLANK — FLOATING BOTTOM DOCK
# ============================================================

log "Creating floating dock..."

mkdir -p "$HOME/.local/share/plank/themes/SpaceGlass"

cat > "$HOME/.local/share/plank/themes/SpaceGlass/dock.theme" <<'EOF'
[PlankDockTheme]

TopRoundness=14
BottomRoundness=14

LineWidth=0

OuterStrokeColor=0;;0;;0;;0
InnerStrokeColor=255;;255;;255;;15

FillStartColor=18;;20;;26;;225
FillEndColor=18;;20;;26;;225

HorizPadding=8
TopPadding=6
BottomPadding=6
ItemPadding=4

IndicatorSize=4
IconShadowSize=0

UrgentBounceHeight=2
LaunchBounceHeight=1

FadeOpacity=1
ClickTime=160

ActiveTime=150
PopTime=160
SlideTime=160
FadeTime=160
HideTime=160

GlowSize=0
GlowTime=0
GlowPulseTime=0
EOF

# Kill old Plank.
pkill -x plank 2>/dev/null || true

sleep 1

mkdir -p "$HOME/.config/plank/dock1/launchers"

# Remove previous generated launchers.
rm -f "$HOME/.config/plank/dock1/launchers/space-*.dockitem" 2>/dev/null || true

# Create a Plank settings file.
cat > "$HOME/.config/plank/dock1/settings" <<'EOF'
[PlankDockPreferences]
CurrentWorkspaceOnly=false
IconSize=48
ZoomEnabled=true
ZoomPercent=145

HideMode=0
HideDelay=0
UnhideDelay=0

Monitor=
Position=3
Offset=0

Alignment=3
ItemsAlignment=3

Theme=SpaceGlass

LockItems=false
PressureReveal=false
PinnedOnly=false
AutoPinning=true

ShowDockItem=false
TooltipsEnabled=true
UrgentBounce=true
EOF

# ------------------------------------------------------------
# Helper: create Plank launcher
# ------------------------------------------------------------

add_plank_launcher() {

    local DESKTOP_FILE="$1"
    local ALIAS="$2"

    local SOURCE=""

    if [[ -f "/usr/share/applications/${DESKTOP_FILE}.desktop" ]]; then
        SOURCE="/usr/share/applications/${DESKTOP_FILE}.desktop"
    elif [[ -f "/usr/local/share/applications/${DESKTOP_FILE}.desktop" ]]; then
        SOURCE="/usr/local/share/applications/${DESKTOP_FILE}.desktop"
    elif [[ -f "$HOME/.local/share/applications/${DESKTOP_FILE}.desktop" ]]; then
        SOURCE="$HOME/.local/share/applications/${DESKTOP_FILE}.desktop"
    fi

    [[ -n "$SOURCE" ]] || return 0

    ln -sf \
        "$SOURCE" \
        "$HOME/.config/plank/dock1/launchers/space-${ALIAS}.dockitem"
}

# ------------------------------------------------------------
# Standard macOS-like dock contents.
# ------------------------------------------------------------

add_plank_launcher "firefox" "firefox"
add_plank_launcher "org.mozilla.firefox" "firefox2"
add_plank_launcher "thunar" "files"
add_plank_launcher "xfce4-terminal" "terminal"
add_plank_launcher "org.gnome.Calculator" "calculator"
add_plank_launcher "xfce-settings-manager" "settings"
add_plank_launcher "code" "vscode"
add_plank_launcher "spotify" "spotify"
add_plank_launcher "discord" "discord"

# Add Chromium variants if present.
add_plank_launcher "chromium" "chromium"
add_plank_launcher "chromium-browser" "chromium2"

# ============================================================
# 9. PICOM — BLUR / SHADOW / FADE
# ============================================================

log "Configuring Picom..."

cat > "$HOME/.config/picom/picom.conf" <<'EOF'
# ============================================================
# SPACE XFCE PICOM
# ============================================================

backend = "glx";
vsync = true;

dbus = true;

# Shadows
shadow = true;
shadow-radius = 18;
shadow-opacity = 0.35;
shadow-offset-x = -10;
shadow-offset-y = -10;

# Fading
fading = true;
fade-in-step = 0.035;
fade-out-step = 0.035;
fade-delta = 8;

# Window opacity
active-opacity = 1.0;
inactive-opacity = 0.97;

# Rounded corners where supported
detect-rounded-corners = true;
detect-client-opacity = true;
detect-transient = true;

corner-radius = 12;

# Blur
blur-method = "dual_kawase";
blur-strength = 7;

blur-background = true;
blur-background-frame = true;

# Window type handling
wintypes:
{
    tooltip = {
        fade = true;
        shadow = true;
        opacity = 0.94;
    };

    dock = {
        shadow = false;
    };

    dnd = {
        shadow = false;
    };

    popup_menu = {
        opacity = 0.96;
    };

    dropdown_menu = {
        opacity = 0.96;
    };
};
EOF

# Disable Xfwm compositor because Picom will own compositing.
xfconf-query \
    -c xfwm4 \
    -p /general/use_compositing \
    -n -t bool \
    -s false \
    2>/dev/null || true

# ============================================================
# 10. WALLPAPER
# ============================================================

log "Installing wallpaper..."

WALLDIR="$HOME/.local/share/backgrounds/space-xfce"
mkdir -p "$WALLDIR"

# Try Space repository artwork first.
if [[ ! -d "$WORKDIR/SpaceGit" ]]; then

    git clone \
        --depth 1 \
        https://github.com/EliverLara/Space.git \
        "$WORKDIR/SpaceGit" \
        >/dev/null 2>&1 || true

fi

WALL=""

if [[ -d "$WORKDIR/SpaceGit/Art" ]]; then

    WALL="$(
        find "$WORKDIR/SpaceGit/Art" \
            -type f \
            \( \
                -iname '*.jpg' \
                -o -iname '*.jpeg' \
                -o -iname '*.png' \
                -o -iname '*.webp' \
            \) |
        head -n 1
    )"

fi

# If Space does not ship a usable wallpaper, leave current wallpaper.
if [[ -n "$WALL" && -f "$WALL" ]]; then

    EXT="${WALL##*.}"
    DEST="$WALLDIR/Space-wallpaper.$EXT"

    cp "$WALL" "$DEST"

