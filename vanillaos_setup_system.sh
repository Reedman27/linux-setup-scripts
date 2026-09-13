#!/usr/bin/env bash
# ==============================================================================
# vanillaos_setup_system.sh
# Made by reedman27
# Supports: Vanilla OS 3.x "Reunion" and newer.
# ==============================================================================
# This script is completely safe to rerun (idempotent) and logs actions to a
# file. It assumes you're running it from the DEFAULT terminal (Black Box),
# which drops you inside the VSO subsystem automatically -- that's what makes
# plain `apt` work here even though Vanilla OS's actual host root is immutable.
#
# There is deliberately NO Snap section. Vanilla OS doesn't ship it, doesn't
# need it, and nothing here tries to reintroduce it.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration & Setup
# ------------------------------------------------------------------------------
LOG_FILE="/tmp/vanillaos_setup_$(date +%F_%H-%M-%S).log"
exec > >(tee -i "${LOG_FILE}") 2>&1

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

trap_error() {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"
    echo -e "\n${RED}❌ Error: Command failed on line ${parent_lineno} with exit code ${code}.${NC}"
    echo -e "${YELLOW}Check the log file for details: ${LOG_FILE}${NC}\n"
    exit "${code}"
}
trap 'trap_error ${LINENO} "$BASH_COMMAND" $?' ERR

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -eq 0 ]]; then
    log_error "Please run this script as your regular user (with sudo privileges), not as root directly."
    exit 1
fi

echo "========================================================"
echo "     Vanilla OS Workstation Deployment & Setup Script     "
echo "========================================================"
log_info "Log file: ${LOG_FILE}"

# ------------------------------------------------------------------------------
# System Detection & VSO Sanity Check
# ------------------------------------------------------------------------------
if [ -f /etc/os-release ]; then
    OS_ID=$(grep -oP '(?<=^ID=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)
    OS_VERSION=$(grep -oP '(?<=VERSION_ID=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)
else
    log_error "Could not read /etc/os-release."
    exit 1
fi

if [[ "${OS_ID}" != "vanilla" ]]; then
    log_warn "This doesn't look like Vanilla OS (detected ID='${OS_ID}'). Continuing anyway, but expect surprises."
else
    log_info "Detected Vanilla OS ${OS_VERSION}"
fi

if ! command -v apt >/dev/null 2>&1; then
    log_error "apt isn't available. Are you running this from the default Black Box terminal (inside the VSO subsystem), not the raw host shell?"
    exit 1
fi

# ------------------------------------------------------------------------------
# Base System Prep
# ------------------------------------------------------------------------------
log_info "Refreshing VSO/apt package lists..."
sudo apt update
sudo apt full-upgrade -y

log_info "Installing core system utilities..."
sudo apt install -y \
    curl \
    wget \
    gpg \
    ca-certificates \
    apt-transport-https \
    zsh \
    jq

if [[ "$(basename "${SHELL:-}")" != "zsh" ]]; then
    log_info "Setting zsh as your default shell (takes effect on next login)..."
    chsh -s "$(command -v zsh)" "$USER" || log_warn "Could not change default shell automatically; run 'chsh -s \$(which zsh)' manually."
else
    log_info "zsh is already your default shell."
fi

# ------------------------------------------------------------------------------
# Flatpak Setup
# ------------------------------------------------------------------------------
# Vanilla OS ships Flatpak + Flathub preconfigured out of the box, but this is
# safe to rerun and covers a from-scratch/minimal install too.
log_info "Ensuring Flathub is registered for both scopes..."
sudo flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# ------------------------------------------------------------------------------
# Brave Browser Installation (apt, inside VSO -- Debian sid base)
# ------------------------------------------------------------------------------
if dpkg -s brave-browser >/dev/null 2>&1 || dpkg -s brave-origin >/dev/null 2>&1; then
    log_info "Brave is already installed — skipping repo setup and install."
else
    log_info "Configuring Brave Browser repository..."
    sudo install -d -m 0755 /usr/share/keyrings
    sudo rm -f /etc/apt/sources.list.d/brave-browser-release.sources

    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
        | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >/dev/null

    # Brave's repo uses the literal suite "stable", no Ubuntu-style codename
    # matching needed -- this is one of the few apt repos that's genuinely
    # distro-agnostic, which is exactly why it survives the jump to Vanilla/Debian.
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        | sudo tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null
fi

# ------------------------------------------------------------------------------
# Tailscale Installation
# ------------------------------------------------------------------------------
# Vanilla OS's base (Debian sid) doesn't map cleanly onto Tailscale's
# codename-keyed apt repo the way Ubuntu does, so we use their official
# install script instead -- it detects the underlying distro/repo itself and
# is the officially supported path for anything off the beaten track.
if command -v tailscale >/dev/null 2>&1; then
    log_info "Tailscale is already installed — skipping."
else
    log_info "Installing Tailscale via official install script..."
    curl -fsSL https://tailscale.com/install.sh | sh || log_warn "Tailscale install script failed — install manually from https://tailscale.com/download/linux later."
fi

# ------------------------------------------------------------------------------
# Cider Installation (apt repo, same guarded probe as the Ubuntu script)
# ------------------------------------------------------------------------------
# Same reasoning as before: repo.cider.sh is small and occasionally
# unreachable/rotates its key, so we verify before committing anything and
# never let this one optional repo take the whole run down under `set -e`.
log_info "Configuring Cider repository..."
CIDER_KEY_TMP="$(mktemp)"
if curl -fsSL --connect-timeout 5 -o "${CIDER_KEY_TMP}" https://repo.cider.sh/APT-GPG-KEY 2>/dev/null \
    && gpg --dearmor < "${CIDER_KEY_TMP}" | sudo tee /usr/share/keyrings/cider-archive-keyring.gpg >/dev/null \
    && curl -sSf -o /dev/null --connect-timeout 5 https://repo.cider.sh/apt/dists/stable/Release 2>/dev/null; then
    echo "deb [signed-by=/usr/share/keyrings/cider-archive-keyring.gpg] https://repo.cider.sh/apt stable main" \
        | sudo tee /etc/apt/sources.list.d/cider.list >/dev/null
    log_success "Cider repository verified and configured."
else
    log_warn "Cider repository (repo.cider.sh) is unreachable or its key could not be verified. Skipping — Cider install will fall back to manual AppImage further down."
    sudo rm -f /usr/share/keyrings/cider-archive-keyring.gpg /etc/apt/sources.list.d/cider.list
fi
rm -f "${CIDER_KEY_TMP}"

# ------------------------------------------------------------------------------
# User-Requested CLI/Dev Tools
# ------------------------------------------------------------------------------
log_info "Installing additional CLI/dev tools..."
sudo apt install -y \
    alacritty \
    btop \
    fastfetch \
    git \
    neovim \
    zip \
    unzip

# ------------------------------------------------------------------------------
# User-Requested Desktop Apps (apt where reasonable)
# ------------------------------------------------------------------------------
log_info "Installing additional desktop apps..."
sudo apt install -y \
    gnome-calculator \
    gnome-disk-utility \
    gnome-system-monitor \
    kid3-qt

# ------------------------------------------------------------------------------
# APT Refresh & Target Installation
# ------------------------------------------------------------------------------
log_info "Updating package lists with new sources..."
sudo apt update

if dpkg -s brave-browser >/dev/null 2>&1 || dpkg -s brave-origin >/dev/null 2>&1; then
    log_info "Brave already installed — skipping."
else
    log_info "Installing Brave Browser..."
    if ! sudo apt install -y brave-browser; then
        log_warn "Standard brave-browser package not found. Attempting brave-origin fallback..."
        sudo apt install -y brave-origin
    fi
fi

log_info "Installing Cider..."
if apt-cache show cider >/dev/null 2>&1; then
    sudo apt install -y cider
else
    log_warn "Cider package not available via apt right now. Skipping automated install — grab the AppImage manually from https://cider.sh and run it with 'appimage-run' (installed below) to keep Discord RPC working. Flatpak is intentionally NOT used here since Flatpak's sandboxing breaks Discord RPC."
fi

# ------------------------------------------------------------------------------
# Steam (Flatpak — Debian sid's apt path for Steam is unreliable/needs
# contrib+non-free wrangling; Flatpak is the actually-maintained route here)
# ------------------------------------------------------------------------------
log_info "Installing Steam via Flatpak..."
flatpak install -y --system flathub com.valvesoftware.Steam || log_warn "Failed to install Steam via Flatpak."

# ------------------------------------------------------------------------------
# Discord Installation (official .deb, installed inside the VSO subsystem)
# ------------------------------------------------------------------------------
log_info "Installing Discord..."
DISCORD_DEB="/tmp/discord.deb"
if curl -fsSL -o "${DISCORD_DEB}" "https://discord.com/api/download?platform=linux&format=deb"; then
    sudo apt install -y "${DISCORD_DEB}"
    rm -f "${DISCORD_DEB}"
else
    log_warn "Could not download Discord .deb; skipping."
fi

# ------------------------------------------------------------------------------
# appimage-run (needed for Cider AppImage fallback + LibrePods)
# ------------------------------------------------------------------------------
log_info "Installing appimage-run support..."
sudo apt install -y libfuse2t64 || sudo apt install -y libfuse2 || log_warn "Could not install a libfuse2 package by either name — AppImages may not run without it."
flatpak install -y --user flathub io.github.probonopd.AppImageLauncher 2>/dev/null || true

# ------------------------------------------------------------------------------
# Nheko (Matrix client) - Flatpak, --user scope
# ------------------------------------------------------------------------------
log_info "Installing Nheko (Matrix client) via Flatpak..."
flatpak install -y --user flathub im.nheko.Nheko || log_warn "Failed to install Nheko via Flatpak."

# ------------------------------------------------------------------------------
# Aonsoku (Navidrome/Subsonic music client) - Flatpak, --user scope
# ------------------------------------------------------------------------------
log_info "Installing Aonsoku via Flatpak..."
flatpak install -y --user flathub io.github.victoralvesf.aonsoku || log_warn "Failed to install Aonsoku via Flatpak."

# ------------------------------------------------------------------------------
# GNOME Extension Manager & Tweaks - Flatpak, --user scope
# ------------------------------------------------------------------------------
log_info "Installing GNOME Extension Manager via Flatpak..."
flatpak install -y --user flathub com.mattjakeman.ExtensionManager || log_warn "Failed to install Extension Manager via Flatpak."

log_info "Installing GNOME Tweaks via Flatpak..."
flatpak install -y --user flathub org.gnome.tweaks || log_warn "Failed to install GNOME Tweaks via Flatpak."

# ------------------------------------------------------------------------------
# Additional Flatpak Apps (pulled from your existing Fedora flatpak list)
# ------------------------------------------------------------------------------
log_info "Installing additional Flatpak apps..."
EXTRA_FLATPAKS=(
    "app.openbubbles.OpenBubbles"      # OpenBubbles - iMessage client
    "com.protonvpn.www"                # Proton VPN
    "com.usebottles.bottles"           # Bottles - Wine prefix manager
    "com.vscodium.codium"              # VSCodium
    "io.github.unknownskl.greenlight"  # Greenlight - xCloud/Xbox home streaming
    "net.lrclib.lrcget"                # LRCGET - lyrics downloader
    "org.gnome.Geary"                  # Geary - email client
    "org.localsend.localsend_app"      # LocalSend
    "org.mozilla.thunderbird_esr"      # Thunderbird
    "org.videolan.VLC"                 # VLC
    "org.vinegarhq.Sober"              # Sober - Roblox client
)
for app_id in "${EXTRA_FLATPAKS[@]}"; do
    flatpak install -y --user flathub "${app_id}" || log_warn "Failed to install ${app_id} via Flatpak."
done

# ------------------------------------------------------------------------------
# LibrePods (AirPods on Linux) - AppImage, no apt/Flatpak package
# ------------------------------------------------------------------------------
log_info "Installing LibrePods..."
LIBREPODS_DIR="${HOME}/.local/bin"
mkdir -p "${LIBREPODS_DIR}"

LIBREPODS_RELEASES_JSON=$(curl -fsSL "https://api.github.com/repos/kavishdevar/librepods/releases" || true)
LIBREPODS_URL=""
if [[ -n "${LIBREPODS_RELEASES_JSON}" ]]; then
    LIBREPODS_URL=$(echo "${LIBREPODS_RELEASES_JSON}" | jq -r '
        [.[] | select(any(.assets[]?; .name | test("AppImage"; "i")))][0].assets[]?
        | select(.name | test("AppImage"; "i"))
        | .browser_download_url' 2>/dev/null | head -n1)
fi

if [[ -n "${LIBREPODS_URL}" && "${LIBREPODS_URL}" != "null" ]]; then
    curl -fsSL -o "${LIBREPODS_DIR}/librepods.AppImage" "${LIBREPODS_URL}"
    chmod +x "${LIBREPODS_DIR}/librepods.AppImage"
    log_success "LibrePods installed to ${LIBREPODS_DIR}/librepods.AppImage."
else
    log_warn "Could not find a LibrePods AppImage release. Check https://github.com/kavishdevar/librepods/releases manually."
fi

# ------------------------------------------------------------------------------
# Services & Cleanup
# ------------------------------------------------------------------------------
log_info "Enabling and launching Tailscale engine daemon..."
if command -v tailscale >/dev/null; then
    sudo systemctl enable --now tailscaled 2>/dev/null || log_warn "Could not enable tailscaled via systemctl — check its install manually."
fi

log_info "Cleaning up local packages and cache..."
sudo apt autoremove -y
sudo apt autoclean

# ------------------------------------------------------------------------------
# Interactive Flatpak scope picker (openSUSE-style "user or system?" prompt)
# ------------------------------------------------------------------------------
log_info "Installing interactive Flatpak scope picker into shell configs..."
MARKER="# >>> flatpak scope picker >>>"
read -r -d '' FLATPAK_PICKER_BLOCK <<'EOF' || true

# >>> flatpak scope picker >>>
flatpak() {
    if [[ "$1" == "install" ]]; then
        shift
        local scope_choice
        echo "Flatpak install scope:"
        echo "  1) User   - only your account, no sudo required"
        echo "  2) System - all users on this machine, requires sudo"
        printf '%s' "Select [1/2] (default 1): "
        read -r scope_choice
        case "${scope_choice}" in
            2)
                sudo command flatpak install --system "$@"
                ;;
            *)
                command flatpak install --user "$@"
                ;;
        esac
    else
        command flatpak "$@"
    fi
}
# <<< flatpak scope picker <<<
EOF

for RC_FILE in "${HOME}/.bashrc" "${HOME}/.zshrc"; do
    touch "${RC_FILE}"
    if grep -qF "${MARKER}" "${RC_FILE}"; then
        log_info "Flatpak scope picker already present in ${RC_FILE}, skipping."
    else
        printf '%s\n' "${FLATPAK_PICKER_BLOCK}" >> "${RC_FILE}"
        log_success "Flatpak scope picker installed into ${RC_FILE}."
    fi
done
log_info "Restart your shell (or 'source ~/.zshrc') to use the picker."

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------
echo "========================================================"
echo "                 Setup Verification Status              "
echo "========================================================"

check_install_status() {
    local pkg_name="$1"
    if dpkg -s "$pkg_name" >/dev/null 2>&1; then
        log_success "$pkg_name is installed successfully."
    else
        log_warn "$pkg_name is NOT installed via APT."
    fi
}

check_install_status "brave-browser"
check_install_status "discord"
command -v tailscale >/dev/null 2>&1 && log_success "tailscale is installed successfully." || log_warn "tailscale is NOT installed."

for cli_tool in alacritty btop fastfetch git neovim zip unzip; do
    check_install_status "${cli_tool}"
done

for desktop_app in gnome-calculator gnome-disk-utility gnome-system-monitor kid3-qt; do
    check_install_status "${desktop_app}"
done

if [[ -x "${HOME}/.local/bin/librepods.AppImage" ]]; then
    log_success "LibrePods AppImage is installed."
else
    log_warn "LibrePods AppImage could not be verified."
fi

for fp_app in Steam Nheko Aonsoku "Extension Manager" Tweaks OpenBubbles "Proton VPN" Bottles VSCodium Greenlight LRCGET Geary LocalSend Thunderbird VLC Sober; do
    if flatpak list | grep -q "${fp_app}"; then
        log_success "${fp_app} (Flatpak) is installed."
    else
        log_warn "${fp_app} installation could not be verified."
    fi
done

if dpkg -s "cider" >/dev/null 2>&1; then
    log_success "Cider is installed via apt."
else
    log_warn "Cider is NOT installed via apt — grab the AppImage manually if you still want it (keeps Discord RPC working, unlike Flatpak)."
fi

echo "========================================================"
log_success "Setup complete!"
log_info "To connect to your private network: sudo tailscale up"
echo "========================================================"

# ------------------------------------------------------------------------------
# Ownership Fix
# ------------------------------------------------------------------------------
# A bunch of the steps above ran under sudo (repo files, keyrings, apt itself),
# and it's easy for something under $HOME to accidentally end up root-owned
# along the way. Hand everything in $HOME back to you before finishing up.
log_info "Fixing ownership of ${HOME} back to ${USER}..."
sudo chown -R "${USER}:${USER}" "${HOME}"

REBOOT_CHOICE=""
printf '%s' "Reboot now to make sure the shell/session changes fully apply? [y/N]: "
read -r REBOOT_CHOICE
case "${REBOOT_CHOICE}" in
    [yY]|[yY][eE][sS])
        log_info "Rebooting now..."
        sudo reboot
        ;;
    *)
        log_info "Skipping reboot. Log out/in at least once to pick up the zsh shell change."
        ;;
esac
