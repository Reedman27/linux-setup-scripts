#!/usr/bin/env bash
# ==============================================================================
# popos_setup_system.sh
# Made by reedman27
# Supports: Pop!_OS 22.04 LTS & newer, including the COSMIC desktop releases.
# ==============================================================================
# This script is completely safe to rerun (idempotent), logs actions to a file,
# and automatically falls back to older Ubuntu-base codenames if third-party
# vendors have not yet published packages for your exact release.
#
# Pop!_OS is a normal mutable Debian/apt root filesystem on top of an Ubuntu
# LTS base -- there is no host/subsystem split and no image-based updates to
# worry about (that's Vanilla OS's model, not this one). Everything below,
# including Tailscale and Brave, installs directly via plain `apt`/`curl` on
# the live system, exactly like ubuntu_setup_system.sh does. Nothing here
# uses `host-shell`, `abroot`, or any other atomic/immutable-host tooling --
# that would assume a system this script doesn't run on.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration & Setup
# ------------------------------------------------------------------------------
LOG_FILE="/tmp/popos_setup_$(date +%F_%H-%M-%S).log"
exec > >(tee -i "${LOG_FILE}") 2>&1

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Error Handler
trap_error() {
    local parent_lineno="$1"
    local message="$2"
    local code="${3:-1}"
    echo -e "\n${RED}❌ Error: Command failed on line ${parent_lineno} (${message}) with exit code ${code}.${NC}"
    echo -e "${YELLOW}Check the log file for details: ${LOG_FILE}${NC}\n"
    exit "${code}"
}
trap 'trap_error ${LINENO} "$BASH_COMMAND" $?' ERR

# Informational headers
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check privileges
if [[ $EUID -eq 0 ]]; then
    log_error "Please run this script as your regular user (with sudo privileges), not as root directly."
    exit 1
fi

echo "========================================================"
echo "      Pop!_OS Workstation Deployment & Setup Script       "
echo "========================================================"
log_info "Log file: ${LOG_FILE}"

# ------------------------------------------------------------------------------
# System Detection
# ------------------------------------------------------------------------------
if [ -f /etc/os-release ]; then
    # Learn variables from os-release without polluting global scope.
    # grep -oP returns exit 1 when the field is absent, which under
    # pipefail would otherwise trip the generic ERR trap instead of
    # this function's own error message, so we tolerate that here.
    OS_ID=$(grep -oP '(?<=^ID=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)
    OS_ID_LIKE=$(grep -oP '(?<=^ID_LIKE=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)
    # Pop!_OS's own VERSION_CODENAME (when present at all) refers to Pop
    # itself, not something any third-party Ubuntu-keyed apt repo (Brave,
    # Tailscale) will recognize. Pop!_OS additionally ships an UBUNTU_CODENAME
    # field naming the actual Ubuntu LTS base it's built on -- prefer that,
    # and fall back to VERSION_CODENAME only if it's somehow absent.
    POP_BASE_CODENAME=$(grep -oP '(?<=^UBUNTU_CODENAME=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)
    UBUNTU_CODENAME="${POP_BASE_CODENAME:-$(grep -oP '(?<=VERSION_CODENAME=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)}"
    UBUNTU_RELEASE=$(grep -oP '(?<=VERSION_ID=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)

    # Refuse to run on anything that isn't actually Pop!_OS. This script
    # purges Snap and rewrites apt sources, so it needs to be sure it's on
    # the OS it thinks it is before touching any of that.
    if [[ "${OS_ID}" != "pop" ]]; then
        log_error "This script requires Pop!_OS (detected ID='${OS_ID}'). Refusing to run — it modifies repos and purges Snap based on assumptions specific to Pop!_OS. Use ubuntu_setup_system.sh on plain Ubuntu instead."
        exit 1
    fi

    if [[ -z "${UBUNTU_CODENAME}" ]]; then
        log_error "Could not determine the Ubuntu base codename (checked UBUNTU_CODENAME and VERSION_CODENAME) from /etc/os-release."
        exit 1
    fi
else
    log_error "Could not read /etc/os-release. Is this a Pop!_OS system?"
    exit 1
fi

log_info "Detected Pop!_OS ${UBUNTU_RELEASE} (Ubuntu base: ${UBUNTU_CODENAME})"

# List of codenames to try in descending chronological order for fallbacks.
# Pop!_OS only ever tracks Ubuntu LTS bases (no interim releases), so this
# list is narrower than ubuntu_setup_system.sh's.
CODENAME_FALLBACKS=("noble" "jammy" "focal")

# Helper to find the best working codename for repositories that check codenames
find_working_codename() {
    local repo_base_url="$1"
    local test_path_suffix="$2" # e.g., "dists/{codename}/Release"

    # First, test the system's actual codename
    local test_url="${repo_base_url}/${test_path_suffix//\{codename\}/${UBUNTU_CODENAME}}"
    if curl -sSf -o /dev/null --connect-timeout 5 "${test_url}" 2>/dev/null; then
        echo "${UBUNTU_CODENAME}"
        return 0
    fi

    # Fallback search
    log_warn "Repository doesn't officially support '${UBUNTU_CODENAME}' yet. Finding best fallback..."
    for fallback in "${CODENAME_FALLBACKS[@]}"; do
        # Skip if it is the same as current (already tested)
        [[ "$fallback" == "$UBUNTU_CODENAME" ]] && continue

        test_url="${repo_base_url}/${test_path_suffix//\{codename\}/${fallback}}"
        if curl -sSf -o /dev/null --connect-timeout 5 "${test_url}" 2>/dev/null; then
            log_info "-> Found working fallback codename: ${fallback}"
            echo "${fallback}"
            return 0
        fi
    done

    # Hard safety default if nothing is reachable
    log_error "Could not verify repository reachability. Defaulting to 'noble' fallback."
    echo "noble"
}

# ------------------------------------------------------------------------------
# Base System Updates & Prep
# ------------------------------------------------------------------------------
log_info "Refreshing system packages..."
sudo apt update
sudo apt full-upgrade -y

log_info "Installing core system utilities..."
sudo apt install -y \
    curl \
    wget \
    gpg \
    ca-certificates \
    software-properties-common \
    apt-transport-https \
    fwupd \
    zsh

# Make zsh the default login shell if it isn't already
if [[ "$(basename "${SHELL:-}")" != "zsh" ]]; then
    log_info "Setting zsh as your default shell (takes effect on next login)..."
    chsh -s "$(command -v zsh)" "$USER" || log_warn "Could not change default shell automatically; run 'chsh -s \$(which zsh)' manually."
else
    log_info "zsh is already your default shell."
fi

# ------------------------------------------------------------------------------
# Snap Removal (Optional, comment out if you prefer Snaps)
# ------------------------------------------------------------------------------
# ------------------------------------------------------------------------------
# Snap Removal (Optional, comment out if you prefer Snaps)
# ------------------------------------------------------------------------------
log_info "Checking for Snap presence..."
# Pop!_OS doesn't ship snapd out of the box, so this block is a no-op on a
# stock install. It's kept anyway in case Snap was added manually later, or
# a home directory was restored from an Ubuntu system. Don't rely on a
# single `dpkg -s snapd` check — look for any of: the snapd package, the
# snap binary, the /snap directory, or leftover snap-store launcher files,
# and if ANY of those are found, run the full purge.
SNAP_PRESENT=0
dpkg -s snapd >/dev/null 2>&1 && SNAP_PRESENT=1
command -v snap >/dev/null 2>&1 && SNAP_PRESENT=1
[ -d /snap ] && SNAP_PRESENT=1
[ -d /var/lib/snapd ] && SNAP_PRESENT=1
dpkg -l | grep -qi '^ii.*snapd' && SNAP_PRESENT=1
ls /var/lib/snapd/desktop/applications/*snap-store* >/dev/null 2>&1 && SNAP_PRESENT=1

if [ "$SNAP_PRESENT" -eq 1 ]; then
    log_warn "Snap components detected — purging Snap environment entirely..."

    # Safety net: before touching anything, mark core desktop packages as
    # manually installed. Purging snapd can leave some desktop components
    # looking "orphaned" to apt if they were ever pulled in as a dependency
    # of a snap-related package, and `autoremove --purge` below would happily
    # take them out along with snapd if we didn't protect them first. This
    # covers both System76's COSMIC desktop (Pop 24.04+) and the legacy
    # GNOME-based desktop (Pop 22.04 and earlier) so it's safe either way.
    log_info "Protecting Pop!_OS desktop packages from autoremove..."
    DESKTOP_GUARD_PKGS=(pop-desktop system76-power cosmic-session cosmic-greeter cosmic-files gnome-shell gnome-session gdm3 gnome-control-center nautilus pop-shell)
    for pkg in "${DESKTOP_GUARD_PKGS[@]}"; do
        dpkg -s "$pkg" >/dev/null 2>&1 && sudo apt-mark manual "$pkg" >/dev/null 2>&1 || true
    done

    # Stop services safely
    sudo systemctl stop snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true
    sudo systemctl disable snapd.service snapd.socket snapd.seeded.service 2>/dev/null || true

    # Remove existing snaps (reverse order to handle dependencies), including
    # the Snap Store itself, base/core snaps, and anything left running
    if command -v snap >/dev/null 2>&1; then
        # Two passes: first regular snaps, then remaining base/core/gnome-* runtime snaps
        for snap in $(snap list 2>/dev/null | awk '!/^Name|^refreshed/ {print $1}' | grep -v -E '^(core|core1[0-9]|core2[0-9]|bare|snapd)$' | tac); do
            sudo snap remove --purge "$snap" 2>/dev/null || true
        done
        for snap in $(snap list 2>/dev/null | awk '!/^Name|^refreshed/ {print $1}' | tac); do
            sudo snap remove --purge "$snap" 2>/dev/null || true
        done
    fi

    # Purge the snapd package and any related packages apt knows about
    sudo apt purge -y snapd 2>/dev/null || true
    sudo apt purge -y $(dpkg -l | awk '/^ii.*snap/ {print $2}') 2>/dev/null || true

    # Guarded autoremove: dry-run first and bail instead of purging if GNOME
    # or the desktop metapackage would be swept up as a side effect.
    AUTOREMOVE_PREVIEW=$(apt-get -s autoremove --purge 2>/dev/null | grep -E '^Remv' || true)
    if echo "${AUTOREMOVE_PREVIEW}" | grep -qiE 'gnome|ubuntu-desktop|pop-desktop|cosmic|gdm3'; then
        log_error "autoremove would remove GNOME/desktop packages as a side effect of the Snap purge — skipping autoremove to protect your desktop."
        log_warn "Review manually with: apt-get -s autoremove --purge"
    else
        sudo apt autoremove -y --purge
    fi

    # Clear lingering directory layouts and desktop launcher leftovers
    rm -rf "$HOME/snap" "$HOME/.snap" "$HOME/.config/snapd"
    sudo rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd /usr/lib/snapd
    sudo rm -f /var/lib/dpkg/info/snapd.* 2>/dev/null || true
    # Remove any stray Snap Store launcher entries that survive the purge
    sudo find /usr/share/applications /var/lib/snapd 2>/dev/null -iname "*snap-store*" -delete 2>/dev/null || true
    rm -f "$HOME/.local/share/applications/"*snap-store* 2>/dev/null || true

    # Prevent snapd from getting reinstalled accidentally by apt updates
    # (e.g. as a dependency of firefox-snap-shim or similar transitional packages)
    cat <<EOF | sudo tee /etc/apt/preferences.d/nosnap.pref >/dev/null
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF
    log_success "Snap completely purged and pinned off."
else
    log_info "No Snap components detected — nothing to remove."
fi

# ------------------------------------------------------------------------------
# Flatpak Setup
# ------------------------------------------------------------------------------
log_info "Setting up Flatpak environment..."
sudo apt install -y flatpak gnome-software gnome-software-plugin-flatpak

# Add Flathub repo for both scopes so either "user" or "system" installs
# work out of the box once the interactive picker (added below) is used.
sudo flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# ------------------------------------------------------------------------------
# Brave Browser Installation
# ------------------------------------------------------------------------------
if dpkg -s brave-browser >/dev/null 2>&1 || dpkg -s brave-origin >/dev/null 2>&1; then
    log_info "Brave is already installed (brave-browser or brave-origin detected) — skipping repo setup and install."
else
    log_info "Configuring Brave Browser repository..."
    sudo install -d -m 0755 /usr/share/keyrings

    # Some Brave installers (or a prior run of this script under a different apt
    # version) can leave behind a deb822-style .sources file that defines the
    # same repo as the .list file below, causing apt to complain the same
    # Packages target is "configured multiple times". Clear it first so we only
    # ever have one definition.
    sudo rm -f /etc/apt/sources.list.d/brave-browser-release.sources

    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
        | sudo tee /usr/share/keyrings/brave-browser-archive-keyring.gpg >/dev/null

    # Note: Brave's stable distribution channel is simply "stable", no codename fallback needed here.
    echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" \
        | sudo tee /etc/apt/sources.list.d/brave-browser-release.list >/dev/null
fi

# ------------------------------------------------------------------------------
# Tailscale Installation
# ------------------------------------------------------------------------------
if dpkg -s tailscale >/dev/null 2>&1; then
    log_info "Tailscale is already installed — skipping repo setup and install."
else
    log_info "Configuring Tailscale repository..."
    # Resolve best Tailscale target codename
    TS_CODENAME=$(find_working_codename "https://pkgs.tailscale.com/stable/ubuntu" "dists/{codename}/Release")

    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${TS_CODENAME}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null

    echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${TS_CODENAME} main" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
fi

# ------------------------------------------------------------------------------
# Cider Installation
# ------------------------------------------------------------------------------
# NOTE: repo.cider.sh is a small third-party repo and has a history of being
# unreachable / rotating its signing key without notice. Because this script
# runs under `set -Eeuo pipefail` with an ERR trap, blindly writing a repo
# file here and letting a later `apt update` fail on it would abort the
# ENTIRE script (Brave, Steam, everything downstream). So: verify
# the key AND the repo respond before committing anything, and never let
# this one optional repo take the whole run down with it.
log_info "Configuring Cider repository..."
# Cider's documented key endpoint is /APT-GPG-KEY (not /apt/pubkey.gpg, which
# was the previous bug here and the actual cause of the NO_PUBKEY errors).
CIDER_KEY_TMP="$(mktemp)"
if curl -fsSL --connect-timeout 5 -o "${CIDER_KEY_TMP}" https://repo.cider.sh/APT-GPG-KEY 2>/dev/null \
    && gpg --dearmor < "${CIDER_KEY_TMP}" | sudo tee /usr/share/keyrings/cider-archive-keyring.gpg >/dev/null \
    && curl -sSf -o /dev/null --connect-timeout 5 https://repo.cider.sh/apt/dists/stable/Release 2>/dev/null; then
    echo "deb [signed-by=/usr/share/keyrings/cider-archive-keyring.gpg] https://repo.cider.sh/apt stable main" \
        | sudo tee /etc/apt/sources.list.d/cider.list >/dev/null
    log_success "Cider repository verified and configured."
else
    log_warn "Cider repository (repo.cider.sh) is unreachable or its key could not be verified. Skipping it so it doesn't break 'apt update' later — Cider install will simply be skipped further down."
    sudo rm -f /usr/share/keyrings/cider-archive-keyring.gpg /etc/apt/sources.list.d/cider.list
fi
rm -f "${CIDER_KEY_TMP}"

# ------------------------------------------------------------------------------
# Fastfetch Repository
# ------------------------------------------------------------------------------
# fastfetch is NOT in noble/jammy's default apt repos at all (it only lands
# in Ubuntu's own Universe archive starting with 26.04 "resolute"), so on
# every Pop!_OS base today the plain `apt install fastfetch` below would 404
# with "Unable to locate package" and, under `set -Eeuo pipefail`, take the
# entire rest of that install line down with it (alacritty/btop/git/neovim/
# zip/unzip never get installed either, even though they were all fine).
# Check first so we don't add a redundant PPA on any future base where
# fastfetch does ship natively, and guard the PPA add the same way as Cider
# above so a flaky Launchpad mirror can't take the whole script down.
log_info "Checking fastfetch availability..."
if apt-cache show fastfetch >/dev/null 2>&1; then
    log_info "fastfetch is already available in existing repos — no PPA needed."
else
    log_info "fastfetch not found in default repos — adding maintainer PPA (ppa:zhangsongcui3371/fastfetch)..."
    if sudo add-apt-repository -y ppa:zhangsongcui3371/fastfetch >/dev/null 2>&1; then
        sudo apt update
        if apt-cache show fastfetch >/dev/null 2>&1; then
            log_success "Fastfetch PPA added; fastfetch is now installable."
        else
            log_warn "Fastfetch PPA was added but fastfetch still isn't showing up — it will likely fail to install below. Grab it manually from https://github.com/fastfetch-cli/fastfetch/releases if so."
        fi
    else
        log_warn "Could not add the fastfetch PPA (Launchpad may be unreachable) — fastfetch install below may fail. Grab it manually from https://github.com/fastfetch-cli/fastfetch/releases if so."
    fi
fi

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
# User-Requested Desktop Apps
# ------------------------------------------------------------------------------
log_info "Installing additional desktop apps..."
sudo apt install -y \
    rhythmbox \
    gnome-calculator \
    gnome-disk-utility \
    gnome-system-monitor \
    kid3-qt

# ------------------------------------------------------------------------------
# Steam Prep (Multiarch)
# ------------------------------------------------------------------------------
log_info "Enabling 32-bit (i386) architecture for Steam..."
sudo dpkg --add-architecture i386

# ------------------------------------------------------------------------------
# GRUB / Dual-Boot (Windows) Detection
# ------------------------------------------------------------------------------
log_info "Configuring GRUB to detect Windows for dual-boot..."
sudo apt install -y os-prober

GRUB_DEFAULT_FILE="/etc/default/grub"
if [[ -f "${GRUB_DEFAULT_FILE}" ]]; then
    # Modern GRUB ships with os-prober disabled by default (CVE-2020-10713
    # hardening). Dual-boot setups need it enabled to detect Windows.
    if grep -q '^GRUB_DISABLE_OS_PROBER=' "${GRUB_DEFAULT_FILE}"; then
        sudo sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "${GRUB_DEFAULT_FILE}"
    elif grep -q '^#GRUB_DISABLE_OS_PROBER=' "${GRUB_DEFAULT_FILE}"; then
        sudo sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "${GRUB_DEFAULT_FILE}"
    else
        echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a "${GRUB_DEFAULT_FILE}" >/dev/null
    fi
    sudo update-grub
    log_success "GRUB updated with os-prober enabled; Windows should now appear in the boot menu."
else
    log_warn "${GRUB_DEFAULT_FILE} not found; skipping GRUB os-prober configuration."
fi

# ------------------------------------------------------------------------------
# APT Refresh & Target Installation
# ------------------------------------------------------------------------------
log_info "Updating system package list with new software sources..."
sudo apt update

# Install Brave
if dpkg -s brave-browser >/dev/null 2>&1 || dpkg -s brave-origin >/dev/null 2>&1; then
    log_info "Brave already installed — skipping."
else
    log_info "Installing Brave Browser..."
    if ! sudo apt install -y brave-browser; then
        log_warn "Standard brave-browser package not found. Attempting brave-origin fallback..."
        sudo apt install -y brave-origin || log_warn "Neither brave-browser nor brave-origin could be installed. Skipping Brave for now."
    fi
fi

# Install Tailscale
if dpkg -s tailscale >/dev/null 2>&1; then
    log_info "Tailscale already installed — skipping."
else
    log_info "Installing Tailscale..."
    sudo apt install -y tailscale
fi

# Install Steam
log_info "Installing Steam..."
if apt-cache show steam-installer >/dev/null 2>&1; then
    sudo apt install -y steam-installer
else
    sudo apt install -y steam:i386
fi

# Install Cider
log_info "Installing Cider..."
if apt-cache show cider >/dev/null 2>&1; then
    sudo apt install -y cider || log_warn "cider package was listed but failed to install — grab the AppImage manually from https://cider.sh instead."
else
    log_warn "Cider package was not found in the custom repository. Skipping (Flatpak build is outdated, not used) — grab the AppImage manually from https://cider.sh if you still want it."
fi

# ------------------------------------------------------------------------------
# Discord Installation (no apt repo; official .deb)
# ------------------------------------------------------------------------------
log_info "Installing Discord..."
DISCORD_DEB="/tmp/discord.deb"
if curl -fsSL -o "${DISCORD_DEB}" "https://discord.com/api/download?platform=linux&format=deb"; then
    sudo apt install -y "${DISCORD_DEB}" || log_warn "Downloaded Discord's .deb but the install failed — check ${DISCORD_DEB} manually."
    rm -f "${DISCORD_DEB}"
else
    log_warn "Could not download Discord .deb; skipping."
fi

# ------------------------------------------------------------------------------
# Nheko (Matrix client) - Flatpak, --user scope to match your existing setup
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
    "org.libreoffice.LibreOffice"      # LibreOffice
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
log_info "Installing AppImage support..."
sudo apt install -y libfuse2t64 || sudo apt install -y libfuse2 || log_warn "Could not install a libfuse2 package by either name — AppImages may not run without it."
sudo apt install -y jq
flatpak install -y --user flathub io.github.probonopd.AppImageLauncher 2>/dev/null || true

log_info "Installing LibrePods..."
LIBREPODS_DIR="${HOME}/.local/bin"
mkdir -p "${LIBREPODS_DIR}"

# NOTE: LibrePods publishes its AppImage as a GitHub *pre-release*, so the
# /releases/latest endpoint (which only returns full releases) misses it.
# We pull the full releases list instead and take the newest entry that
# actually has an AppImage asset attached.
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
    log_success "LibrePods installed to ${LIBREPODS_DIR}/librepods.AppImage (add it to Bluetooth pairing/tray as needed)."
else
    log_warn "Could not find a LibrePods AppImage release (it may only be under GitHub Actions artifacts, which require a logged-in browser to download). Check https://github.com/kavishdevar/librepods/releases manually."
fi

# ------------------------------------------------------------------------------
# Services & Final Verification
# ------------------------------------------------------------------------------
log_info "Enabling and launching Tailscale engine daemon..."
if command -v tailscale >/dev/null; then
    sudo systemctl enable tailscaled
    sudo systemctl start tailscaled
fi

log_info "Cleaning up local packages and cache..."
FINAL_AUTOREMOVE_PREVIEW=$(apt-get -s autoremove 2>/dev/null | grep -E '^Remv' || true)
if echo "${FINAL_AUTOREMOVE_PREVIEW}" | grep -qiE 'gnome|ubuntu-desktop|pop-desktop|cosmic|gdm3'; then
    log_error "Final autoremove would remove GNOME/desktop packages — skipping to protect your desktop."
    log_warn "Review manually with: apt-get -s autoremove"
else
    sudo apt autoremove -y
fi
sudo apt autoclean

# ------------------------------------------------------------------------------
# Interactive Flatpak scope picker (openSUSE-style "user or system?" prompt)
# ------------------------------------------------------------------------------
log_info "Installing interactive Flatpak scope picker into shell configs..."
MARKER="# >>> flatpak scope picker >>>"
read -r -d '' FLATPAK_PICKER_BLOCK <<'EOF' || true

# >>> flatpak scope picker >>>
# Wraps `flatpak install` so it asks whether to install for just you
# (user, no sudo) or for everyone on the machine (system, needs sudo),
# similar to the prompt openSUSE Tumbleweed shows.
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

# Verify installation of core targets
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
check_install_status "tailscale"
check_install_status "discord"

# steam-installer is a bootstrapper metapackage; dpkg may not register a
# package literally named "steam" until Steam's first launch/self-update,
# so check for either name before calling it not-installed.
if dpkg -s "steam-installer" >/dev/null 2>&1 || dpkg -s "steam" >/dev/null 2>&1; then
    log_success "Steam is installed successfully."
else
    log_warn "Steam is NOT installed via APT."
fi

for cli_tool in alacritty btop fastfetch git neovim zip unzip; do
    check_install_status "${cli_tool}"
done

for desktop_app in rhythmbox gnome-calculator gnome-disk-utility gnome-system-monitor kid3-qt; do
    check_install_status "${desktop_app}"
done

if [[ -x "${HOME}/.local/bin/librepods.AppImage" ]]; then
    log_success "LibrePods AppImage is installed."
else
    log_warn "LibrePods AppImage could not be verified."
fi

for fp_app in Nheko Aonsoku "Extension Manager" Tweaks OpenBubbles "Proton VPN" Bottles VSCodium Greenlight LRCGET Geary LibreOffice LocalSend Thunderbird VLC Sober; do
    if flatpak list | grep -q "${fp_app}"; then
        log_success "${fp_app} (Flatpak) is installed."
    else
        log_warn "${fp_app} installation could not be verified."
    fi
done

if dpkg -s "cider" >/dev/null 2>&1; then
    log_success "Cider is installed."
else
    log_warn "Cider is NOT installed via APT."
fi

echo "========================================================"
log_success "Setup complete! Please reboot your system to apply all changes."
log_info "To connect to your private network: sudo tailscale up"
echo "========================================================"

# ------------------------------------------------------------------------------
# Ownership Fix
# ------------------------------------------------------------------------------
# A bunch of the steps above ran under sudo (repo files, keyrings, the Snap
# purge, apt itself), and it's easy for something under $HOME to accidentally
# end up root-owned along the way. Hand everything in $HOME back to you
# before finishing up.
log_info "Fixing ownership of ${HOME} back to ${USER}..."
sudo chown -R "${USER}:${USER}" "${HOME}"

# ------------------------------------------------------------------------------
# Reboot Prompt
# ------------------------------------------------------------------------------
REBOOT_CHOICE=""
printf '%s' "Reboot now to apply all changes? [y/N]: "
read -r REBOOT_CHOICE
case "${REBOOT_CHOICE}" in
    [yY]|[yY][eE][sS])
        log_info "Rebooting now..."
        sudo reboot
        ;;
    *)
        log_info "Skipping reboot. Remember to reboot manually before things like GRUB/Snap changes fully apply."
        ;;
esac
