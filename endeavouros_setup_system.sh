#!/usr/bin/env bash
# ==============================================================================
# endeavouros_setup_system.sh
# Made by reedman27
# Supports: EndeavourOS (rolling release, any current ISO/point release).
# ==============================================================================
# This script is completely safe to rerun (idempotent) and logs actions to a
# file, same as the other scripts in this repo. EndeavourOS is vanilla Arch
# underneath (pacman, no dpkg/apt anywhere), so the package-manager plumbing
# here looks nothing like the Ubuntu/Pop!_OS/Vanilla scripts even though the
# end result (Waterfox, Tailscale, Steam, Discord, Cider, LibrePods, the shared
# zsh setup) is the same lineup.
#
# There is deliberately NO Snap section -- Arch doesn't ship it and nothing
# here pulls it in.
# ==============================================================================

set -Eeuo pipefail

# ------------------------------------------------------------------------------
# Configuration & Setup
# ------------------------------------------------------------------------------
LOG_FILE="/tmp/endeavouros_setup_$(date +%F_%H-%M-%S).log"
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
    echo -e "\n${RED}❌ Error: Command failed on line ${parent_lineno} (${message}) with exit code ${code}.${NC}"
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
echo "    EndeavourOS Workstation Deployment & Setup Script     "
echo "========================================================"
log_info "Log file: ${LOG_FILE}"

# ------------------------------------------------------------------------------
# System Detection
# ------------------------------------------------------------------------------
if [ -f /etc/os-release ]; then
    OS_ID=$(grep -oP '(?<=^ID=).*' /etc/os-release 2>/dev/null | tr -d '"' || true)
else
    log_error "Could not read /etc/os-release. Is this an EndeavourOS system?"
    exit 1
fi

if [[ "${OS_ID}" != "endeavouros" ]]; then
    log_error "This script requires EndeavourOS (detected ID='${OS_ID}'). Refusing to run — it assumes pacman + an AUR helper are the package managers, and installs an EndeavourOS-specific package set."
    exit 1
fi
log_info "Detected EndeavourOS."

if ! command -v pacman >/dev/null 2>&1; then
    log_error "pacman isn't available — this doesn't look like a working Arch/EndeavourOS install."
    exit 1
fi

# ------------------------------------------------------------------------------
# Base System Updates & Prep
# ------------------------------------------------------------------------------
log_info "Refreshing mirrors and upgrading the system..."
sudo pacman -Syu --noconfirm

log_info "Installing core system utilities..."
# base-devel + git are the actual prerequisites for building an AUR helper
# below (makepkg lives in base-devel); everything else here mirrors the
# curl/wget/gpg/zsh basics the other scripts install.
sudo pacman -S --needed --noconfirm \
    base-devel \
    git \
    curl \
    wget \
    gnupg \
    fwupd \
    jq \
    zsh

# Make zsh the default login shell if it isn't already
if [[ "$(basename "${SHELL:-}")" != "zsh" ]]; then
    log_info "Setting zsh as your default shell (takes effect on next login)..."
    chsh -s "$(command -v zsh)" "$USER" || log_warn "Could not change default shell automatically; run 'chsh -s \$(which zsh)' manually."
else
    log_info "zsh is already your default shell."
fi

# ------------------------------------------------------------------------------
# AUR Helper (paru)
# ------------------------------------------------------------------------------
# Cider and Waterfox below only exist in the AUR, not the official repos, so
# an AUR helper is a hard requirement here, not an optional nicety. paru-bin is
# used instead of plain `paru` so bootstrapping it doesn't require compiling
# Rust from source on a machine that, at this point in the script, has
# nothing but base-devel on it yet.
if command -v paru >/dev/null 2>&1; then
    log_info "paru is already installed — skipping."
else
    log_info "Installing paru (AUR helper)..."
    PARU_BUILD_DIR="$(mktemp -d)"
    if git clone --depth=1 https://aur.archlinux.org/paru-bin.git "${PARU_BUILD_DIR}/paru-bin"; then
        (cd "${PARU_BUILD_DIR}/paru-bin" && makepkg -si --noconfirm) \
            && log_success "paru installed." \
            || log_error "makepkg failed to build/install paru-bin. Check the output above and re-run."
    else
        log_error "Could not clone paru-bin from the AUR — check your network connection and re-run."
    fi
    rm -rf "${PARU_BUILD_DIR}"
fi

if ! command -v paru >/dev/null 2>&1; then
    log_error "paru still isn't on PATH after the install attempt above — AUR packages (Waterfox, Cider) will be skipped further down."
fi

# ------------------------------------------------------------------------------
# Flatpak Setup
# ------------------------------------------------------------------------------
log_info "Setting up Flatpak environment..."
sudo pacman -S --needed --noconfirm flatpak
sudo flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --if-not-exists --user flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# ------------------------------------------------------------------------------
# Multilib (needed for Steam)
# ------------------------------------------------------------------------------
log_info "Checking multilib repo (required for Steam)..."
if grep -qE '^\[multilib\]' /etc/pacman.conf; then
    log_info "multilib is already enabled."
else
    log_info "Enabling multilib in /etc/pacman.conf..."
    # The stock file has multilib commented out as a paired block:
    #   #[multilib]
    #   #Include = /etc/pacman.d/mirrorlist
    # Uncomment both lines of that specific pair rather than every commented
    # line in the file.
    sudo sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
    if grep -qE '^\[multilib\]' /etc/pacman.conf; then
        log_success "multilib enabled."
    else
        log_warn "Could not find/enable the commented [multilib] block in /etc/pacman.conf — enable it manually, then 'sudo pacman -Sy', if Steam fails to install below."
    fi
fi
sudo pacman -Sy --noconfirm

# ------------------------------------------------------------------------------
# Waterfox Browser (AUR)
# ------------------------------------------------------------------------------
if pacman -Qi waterfox-bin >/dev/null 2>&1; then
    log_info "Waterfox is already installed — skipping."
elif command -v paru >/dev/null 2>&1; then
    log_info "Installing Waterfox (waterfox-bin, AUR)..."
    paru -S --noconfirm waterfox-bin || log_warn "Failed to install waterfox-bin via paru."
else
    log_warn "Skipping Waterfox — no AUR helper available."
fi

# ------------------------------------------------------------------------------
# Tailscale (official extra repo)
# ------------------------------------------------------------------------------
if pacman -Qi tailscale >/dev/null 2>&1; then
    log_info "Tailscale is already installed — skipping."
else
    log_info "Installing Tailscale..."
    sudo pacman -S --needed --noconfirm tailscale
fi

# ------------------------------------------------------------------------------
# Steam (multilib)
# ------------------------------------------------------------------------------
log_info "Installing Steam..."
sudo pacman -S --needed --noconfirm steam

# ------------------------------------------------------------------------------
# Cider (AUR, guarded the same way as the apt scripts probe repo.cider.sh)
# ------------------------------------------------------------------------------
# NOTE: Cider Collective requires a purchased license from cider.sh to
# actually use it even though the package installs for free.
log_info "Installing Cider..."
if command -v paru >/dev/null 2>&1; then
    if paru -Si cider-bin >/dev/null 2>&1; then
        paru -S --noconfirm cider-bin \
            && log_success "Cider installed — remember it needs a purchased license from https://cider.sh to actually run." \
            || log_warn "cider-bin was found in the AUR but failed to build/install — grab the AppImage manually from https://cider.sh instead."
    else
        log_warn "cider-bin isn't in the AUR right now — grab the AppImage manually from https://cider.sh if you still want it."
    fi
else
    log_warn "Skipping Cider — no AUR helper available."
fi

# ------------------------------------------------------------------------------
# Discord (official extra repo)
# ------------------------------------------------------------------------------
log_info "Installing Discord..."
sudo pacman -S --needed --noconfirm discord

# ------------------------------------------------------------------------------
# Fastfetch (in official repos on Arch -- no PPA-style workaround needed here)
# ------------------------------------------------------------------------------
log_info "Installing fastfetch..."
sudo pacman -S --needed --noconfirm fastfetch

# ------------------------------------------------------------------------------
# User-Requested CLI/Dev Tools
# ------------------------------------------------------------------------------
log_info "Installing additional CLI/dev tools..."
sudo pacman -S --needed --noconfirm \
    alacritty \
    btop \
    neovim \
    zip \
    unzip

# ------------------------------------------------------------------------------
# User-Requested Desktop Apps
# ------------------------------------------------------------------------------
log_info "Installing additional desktop apps..."
sudo pacman -S --needed --noconfirm \
    rhythmbox \
    gnome-calculator \
    gnome-disk-utility \
    gnome-system-monitor \
    kid3-qt

# ------------------------------------------------------------------------------
# Additional Flatpak Apps
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
    "im.nheko.Nheko"                   # Nheko - Matrix client
    "io.github.victoralvesf.aonsoku"   # Aonsoku - Navidrome/Subsonic client
    "com.mattjakeman.ExtensionManager" # GNOME Extension Manager
    "org.gnome.tweaks"                 # GNOME Tweaks
)
for app_id in "${EXTRA_FLATPAKS[@]}"; do
    flatpak install -y --user flathub "${app_id}" || log_warn "Failed to install ${app_id} via Flatpak."
done

# ------------------------------------------------------------------------------
# LibrePods (AirPods on Linux) - AppImage, no pacman/AUR/Flatpak package
# ------------------------------------------------------------------------------
log_info "Installing AppImage support..."
sudo pacman -S --needed --noconfirm fuse2
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
# Bootloader / Dual-Boot (Windows) Detection
# ------------------------------------------------------------------------------
# EndeavourOS defaults to GRUB on most installs, but its own installer also
# offers systemd-boot as a choice, so detect which one is actually active
# instead of assuming GRUB (same approach as popos_setup_system.sh).
log_info "Detecting active bootloader for Windows dual-boot support..."

GRUB_DEFAULT_FILE="/etc/default/grub"
BOOTLOADER=""
if [[ -f "${GRUB_DEFAULT_FILE}" ]]; then
    BOOTLOADER="grub"
elif command -v bootctl >/dev/null 2>&1 && bootctl status 2>/dev/null | grep -qi "systemd-boot"; then
    BOOTLOADER="systemd-boot"
fi

case "${BOOTLOADER}" in
    grub)
        log_info "GRUB detected — configuring os-prober..."
        sudo pacman -S --needed --noconfirm os-prober
        if grep -q '^GRUB_DISABLE_OS_PROBER=' "${GRUB_DEFAULT_FILE}"; then
            sudo sed -i 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "${GRUB_DEFAULT_FILE}"
        elif grep -q '^#GRUB_DISABLE_OS_PROBER=' "${GRUB_DEFAULT_FILE}"; then
            sudo sed -i 's/^#GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "${GRUB_DEFAULT_FILE}"
        else
            echo 'GRUB_DISABLE_OS_PROBER=false' | sudo tee -a "${GRUB_DEFAULT_FILE}" >/dev/null
        fi
        sudo grub-mkconfig -o /boot/grub/grub.cfg
        log_success "GRUB updated with os-prober enabled; Windows should now appear in the boot menu."
        ;;
    systemd-boot)
        log_info "systemd-boot detected. Heads up: it only auto-lists EFI loaders sitting on its OWN ESP — if Windows lives on a separate ESP (common on machines with multiple distros/OEM partition layouts), it's real and bootable but genuinely won't appear in EndeavourOS's boot menu. That's an architectural limit, not something to configure around."

        if command -v efibootmgr >/dev/null 2>&1; then
            LIVE_PARTUUIDS=$(lsblk -no PARTUUID 2>/dev/null | tr '[:upper:]' '[:lower:]')
            WIN_ENTRY_FOUND=false
            while IFS= read -r win_line; do
                WIN_GPT_UUID=$(echo "${win_line}" | grep -oP '(?<=GPT,)[0-9a-fA-F-]{36}' | tr '[:upper:]' '[:lower:]')
                [[ -z "${WIN_GPT_UUID}" ]] && continue
                if echo "${LIVE_PARTUUIDS}" | grep -qx "${WIN_GPT_UUID}"; then
                    WIN_PART=$(lsblk -no NAME,PARTUUID | awk -v u="${WIN_GPT_UUID}" 'tolower($2)==u{print $1}')
                    log_success "Live Windows Boot Manager confirmed on partition ${WIN_PART}. Use your machine's firmware boot menu at power-on (commonly F12/F10/Esc) to reach it, or run 'sudo efibootmgr' to note its Boot#### number and boot it once with 'sudo efibootmgr -n <num>' + reboot."
                    WIN_ENTRY_FOUND=true
                fi
            done < <(sudo efibootmgr -v 2>/dev/null | grep -i "windows boot manager")

            if [[ "${WIN_ENTRY_FOUND}" == false ]]; then
                log_warn "No live Windows Boot Manager entry found — any 'Windows Boot Manager' lines in 'sudo efibootmgr -v' point to partitions that no longer exist on this disk (stale NVRAM from a previous drive/install)."
            fi
        else
            log_warn "efibootmgr not found — install it to check Windows dual-boot status ('sudo pacman -S efibootmgr')."
        fi
        ;;
    *)
        log_warn "Could not determine active bootloader (no /etc/default/grub, and 'bootctl status' didn't report systemd-boot) — skipping Windows dual-boot detection."
        ;;
esac

# ------------------------------------------------------------------------------
# Oh My Zsh + Plugins (the shared .zshrc pulled below assumes these exist)
# ------------------------------------------------------------------------------
log_info "Setting up Oh My Zsh..."
export ZSH="${HOME}/.oh-my-zsh"
if [[ -d "${ZSH}" ]]; then
    log_info "Oh My Zsh is already installed — skipping."
else
    # --unattended: don't drop into a new zsh session mid-script.
    # KEEP_ZSHRC=yes: we overwrite ~/.zshrc ourselves right after this, but
    # keep the installer from touching it (and from making its own backup)
    # first. CHSH=no: we already handle the default-shell switch above.
    if RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"; then
        log_success "Oh My Zsh installed to ${ZSH}."
    else
        log_warn "Oh My Zsh install script failed — the .zshrc pulled below won't work until you install it manually from https://ohmyz.sh."
    fi
fi

log_info "Installing zsh plugins (autosuggestions, syntax-highlighting, completions)..."
ZSH_CUSTOM="${ZSH_CUSTOM:-${ZSH}/custom}"
declare -A ZSH_PLUGIN_REPOS=(
    [zsh-autosuggestions]="https://github.com/zsh-users/zsh-autosuggestions"
    [zsh-syntax-highlighting]="https://github.com/zsh-users/zsh-syntax-highlighting"
    [zsh-completions]="https://github.com/zsh-users/zsh-completions"
)
for plugin_name in "${!ZSH_PLUGIN_REPOS[@]}"; do
    plugin_dir="${ZSH_CUSTOM}/plugins/${plugin_name}"
    if [[ -d "${plugin_dir}" ]]; then
        log_info "${plugin_name} already present — skipping."
    elif git clone --depth=1 "${ZSH_PLUGIN_REPOS[${plugin_name}]}" "${plugin_dir}"; then
        log_success "${plugin_name} installed."
    else
        log_warn "Failed to clone ${plugin_name} — the .zshrc's plugins=() line will error on it until you install it manually."
    fi
done

# ------------------------------------------------------------------------------
# Zsh Config (pulled straight from your linux-setup-scripts repo)
# ------------------------------------------------------------------------------
log_info "Fetching your .zshrc from linux-setup-scripts..."
ZSHRC_URL="https://github.com/Reedman27/linux-setup-scripts/raw/refs/heads/main/.zshrc"
if [[ -f "${HOME}/.zshrc" ]]; then
    cp "${HOME}/.zshrc" "${HOME}/.zshrc.bak.$(date +%s)"
    log_info "Backed up existing ~/.zshrc before overwriting."
fi
if curl -fsSL -o "${HOME}/.zshrc" "${ZSHRC_URL}"; then
    log_success "Downloaded .zshrc to ${HOME}/.zshrc."
else
    log_warn "Could not download .zshrc from ${ZSHRC_URL} — leaving your existing config as-is."
fi
log_info "Restart your shell (or 'source ~/.zshrc') to pick up the new config."

# ------------------------------------------------------------------------------
# Services & Final Verification
# ------------------------------------------------------------------------------
log_info "Enabling and launching Tailscale engine daemon..."
if command -v tailscale >/dev/null; then
    sudo systemctl enable tailscaled
    sudo systemctl start tailscaled
fi

log_info "Cleaning up orphaned packages and cache..."
ORPHANS=$(pacman -Qtdq 2>/dev/null || true)
if [[ -n "${ORPHANS}" ]]; then
    echo "${ORPHANS}" | sudo pacman -Rns --noconfirm - || log_warn "Some orphaned packages could not be removed — review manually with 'pacman -Qtdq'."
else
    log_info "No orphaned packages found."
fi
sudo pacman -Sc --noconfirm

echo "========================================================"
echo "                 Setup Verification Status              "
echo "========================================================"

check_install_status() {
    local pkg_name="$1"
    if pacman -Qi "$pkg_name" >/dev/null 2>&1; then
        log_success "$pkg_name is installed successfully."
    else
        log_warn "$pkg_name is NOT installed via pacman."
    fi
}

command -v paru >/dev/null 2>&1 && log_success "paru is installed." || log_warn "paru is NOT installed."

check_install_status "waterfox-bin"
check_install_status "tailscale"
check_install_status "discord"
check_install_status "steam"

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

if pacman -Qi cider-bin >/dev/null 2>&1; then
    log_success "Cider is installed (remember: still needs a purchased license from https://cider.sh to actually run)."
else
    log_warn "Cider is NOT installed via the AUR."
fi

if [[ -d "${HOME}/.oh-my-zsh" ]]; then
    log_success "Oh My Zsh is installed."
else
    log_warn "Oh My Zsh could not be verified."
fi

echo "========================================================"
log_success "Setup complete! Please reboot your system to apply all changes."
log_info "To connect to your private network: sudo tailscale up"
echo "========================================================"

# ------------------------------------------------------------------------------
# Ownership Fix
# ------------------------------------------------------------------------------
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
        log_info "Skipping reboot. Remember to reboot manually before things like GRUB/bootloader changes fully apply."
        ;;
esac
