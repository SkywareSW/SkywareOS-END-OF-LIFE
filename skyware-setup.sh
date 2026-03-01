#!/bin/bash
set -e

echo "== SkywareOS setup starting =="

# -----------------------------
# Pacman packages (Kitty included)
# -----------------------------
sudo pacman -Syu --noconfirm --needed \
    flatpak cmatrix fastfetch btop zsh alacritty kitty curl git base-devel

# -----------------------------
# Firewall (finally)
# -----------------------------
sudo pacman -S --noconfirm --needed ufw fail2ban
sudo systemctl enable ufw
sudo systemctl enable fail2ban
sudo ufw enable

# -----------------------------
# GPU Driver Selection
# -----------------------------
echo "== Detecting GPU =="

GPU_INFO=$(lspci | grep -E "VGA|3D")

if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
    echo "→ NVIDIA GPU detected"

    if echo "$GPU_INFO" | grep -qi "RTX\|GTX 16"; then
        echo "Installing modern NVIDIA (nvidia-open)..."
        sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils nvidia-settings
    else
        echo "Installing NVIDIA DKMS..."
        sudo pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings
    fi

elif echo "$GPU_INFO" | grep -qi "AMD"; then
    echo "→ AMD GPU detected"
    sudo pacman -S --noconfirm --needed xf86-video-amdgpu mesa

elif echo "$GPU_INFO" | grep -qi "Intel"; then
    echo "→ Intel GPU detected"
    sudo pacman -S --noconfirm --needed xf86-video-intel mesa

elif echo "$GPU_INFO" | grep -qi "VMware"; then
    echo "→ VMware detected"
    sudo pacman -S --noconfirm --needed open-vm-tools mesa

else
    echo "⚠ Could not detect GPU automatically"
fi

# ============================================================
# SkywareOS: Limine Boot Entry + Static Plymouth Logo Setup
# ============================================================

echo "== Setting up SkywareOS bootloader and static boot splash =="

# -----------------------------
# Detect Limine
# -----------------------------
if [ -f /boot/limine.conf ]; then
    LIMINE_CONF="/boot/limine.conf"
elif [ -f /boot/EFI/limine/limine.conf ]; then
    LIMINE_CONF="/boot/EFI/limine/limine.conf"
fi

if [ -n "$LIMINE_CONF" ]; then
    echo "→ Limine detected at $LIMINE_CONF"

    # Rename default boot entry
    sudo sed -i '/^:default$/,/^$/{
        s|^\(\s*\)#*\s*title.*$|    title SkywareOS|
        t
        /linux/ i\    title SkywareOS
    }' "$LIMINE_CONF"

    echo "✔ Limine default entry renamed to SkywareOS"

    # Ensure quiet splash in options
    sudo sed -i '/^:default$/,/^$/ s|options \(.*\)|options \1 quiet splash|' "$LIMINE_CONF"
    echo "✔ Kernel options updated for boot splash"
else
    echo "⚠ Limine not detected, skipping bootloader setup"
fi

# -----------------------------
# Install Plymouth
# -----------------------------
if ! command -v plymouthd &>/dev/null; then
    echo "→ Installing Plymouth..."
    sudo pacman -S --noconfirm plymouth
fi

# Install librsvg for SVG -> PNG conversion
sudo pacman -S --noconfirm librsvg

# Create theme directory
sudo mkdir -p /usr/share/plymouth/themes/skywareos

# Convert SVG logo to PNG
if [ -f assets/skywareos-logo.svg ]; then
    sudo rsvg-convert -w 512 -h 512 -o /usr/share/plymouth/themes/skywareos/logo.png \
        assets/skywareos-logo.svg
    echo "✔ Logo converted from SVG to PNG and installed"
else
    echo "⚠ Logo not found: assets/skywareos-logo.svg"
fi

# Descriptor
sudo tee /usr/share/plymouth/themes/skywareos/skywareos.plymouth > /dev/null << 'EOF'
[Plymouth Theme]
Name=SkywareOS
Description=SkywareOS Static Boot Splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/skywareos
ScriptFile=/usr/share/plymouth/themes/skywareos/skywareos.script
EOF

# Minimal script: black background + centered logo
sudo tee /usr/share/plymouth/themes/skywareos/skywareos.script > /dev/null << 'EOF'
plymouth.set_background_color(0,0,0)
plymouth.image("logo.png")
EOF

# -----------------------------
# 3️⃣ Ensure Plymouth hook in mkinitcpio
# -----------------------------
if ! grep -q plymouth /etc/mkinitcpio.conf; then
    echo "→ Adding plymouth hook to mkinitcpio.conf"
    sudo sed -i '/^HOOKS=/ s/)/ plymouth)/' /etc/mkinitcpio.conf
fi

# Rebuild initramfs
sudo mkinitcpio -P
echo "✔ Initramfs rebuilt with Plymouth hook"

# Set default Plymouth theme
sudo plymouth-set-default-theme -R skywareos
echo "✔ Plymouth theme set as default"

echo "→ SkywareOS bootloader + static boot setup complete"

# -----------------------------
# Desktop Environment / Compositor Selection
# -----------------------------

echo "== Checking for existing Desktop Environment =="

DE_ALREADY_INSTALLED=false

# Check for enabled display managers
if systemctl is-enabled gdm &>/dev/null || \
   systemctl is-enabled sddm &>/dev/null || \
   systemctl is-enabled lightdm &>/dev/null; then
    DE_ALREADY_INSTALLED=true
fi

# Check for common DE packages
if pacman -Q plasma-desktop &>/dev/null || \
   pacman -Q gnome-shell &>/dev/null || \
   pacman -Q deepin &>/dev/null; then
    DE_ALREADY_INSTALLED=true
fi

if [ "$DE_ALREADY_INSTALLED" = true ]; then
    echo "→ Existing Desktop Environment detected."
    echo "→ Skipping DE installation."
else
    echo "No Desktop Environment detected."
    sudo pacman -S --noconfirm --needed gdm lightdm sddm

    echo "Select your Desktop Environment:"
    echo "1) KDE Plasma"
    echo "2) GNOME"
    echo "3) Deepin"
    echo "4) Skip"

    read -rp "Enter choice (1/2/3/4): " de_choice

    case "$de_choice" in
        1)
            echo "Installing KDE Plasma..."
            sudo pacman -S --noconfirm plasma kde-applications sddm
            sudo systemctl enable sddm
            ;;
        2)
            echo "Installing GNOME..."
            sudo pacman -S --noconfirm gnome gnome-extra gdm
            sudo systemctl enable gdm
            ;;
        3)
            echo "Installing Deepin..."
            sudo pacman -S --noconfirm deepin deepin-kwin deepin-extra lightdm
            sudo systemctl enable lightdm
            ;;
        4)
            echo "Skipping..."
            ;;
        *)
            echo "Invalid choice, skipping DE installation."
            ;;
    esac
fi

# -----------------------------
# Flatpak apps
# -----------------------------
if ! flatpak remote-list | grep -q flathub; then
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
fi

flatpak install -y flathub \
    com.discordapp.Discord \
    com.spotify.Client \
    com.valvesoftware.Steam

# -----------------------------
# Fastfetch setup (ASCII logo)
# -----------------------------
FASTFETCH_DIR="$HOME/.config/fastfetch"
mkdir -p "$FASTFETCH_DIR/logos"

cat > "$FASTFETCH_DIR/logos/skyware.txt" << 'EOF'
      @@@@@@@-         +@@@@@@.     
    %@@@@@@@@@@=      @@@@@@@@@@   
   @@@@     @@@@@      -     #@@@  
  :@@*        @@@@             @@@ 
  @@@          @@@@            @@@ 
  @@@           @@@@           %@@ 
  @@@            @@@@          @@@ 
  :@@@            @@@@:        @@@ 
   @@@@     =      @@@@@     %@@@  
    @@@@@@@@@@       @@@@@@@@@@@   
      @@@@@@+          %@@@@@@     
EOF

cat > "$FASTFETCH_DIR/config.jsonc" << 'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "~/.config/fastfetch/logos/skyware.txt",
    "padding": { "top": 0, "left": 2 }
  },
  "modules": [
    "title",
    "separator",
    { "type": "os", "format": "SkywareOS", "use_pretty_name": false },
    "kernel",
    "uptime",
    "packages",
    "shell",
    "cpu",
    "gpu",
    "memory"
  ]
}
EOF

# -----------------------------
# Patch /etc/os-release
# -----------------------------
if [ -w /etc/os-release ] || sudo -n true 2>/dev/null; then
    echo "== Patching /etc/os-release for SkywareOS =="
    sudo cp /etc/os-release /etc/os-release.backup
    sudo sed -i 's/^NAME=.*/NAME="SkywareOS"/' /etc/os-release
    sudo sed -i 's/^PRETTY_NAME=.*/PRETTY_NAME="SkywareOS"/' /etc/os-release
else
    echo "⚠️ Cannot write to /etc/os-release, skipping system-wide branding"
fi

# -----------------------------
# btop theme + config
# -----------------------------
BTOP_DIR="$HOME/.config/btop"
mkdir -p "$BTOP_DIR/themes"

cat > "$BTOP_DIR/themes/skyware-red.theme" << 'EOF'
theme[main_bg]="#0a0000"
theme[main_fg]="#f2dada"
theme[title]="#ff4d4d"
theme[hi_fg]="#ff6666"
theme[selected_bg]="#2a0505"
theme[inactive_fg]="#8a5a5a"

theme[cpu_box]="#ff4d4d"
theme[cpu_core]="#ff6666"
theme[cpu_misc]="#ff9999"

theme[mem_box]="#ff6666"
theme[mem_used]="#ff4d4d"
theme[mem_free]="#ff9999"
theme[mem_cached]="#ffb3b3"

theme[net_box]="#ff6666"
theme[net_download]="#ff9999"
theme[net_upload]="#ff4d4d"

theme[temp_start]="#ff9999"
theme[temp_mid]="#ff6666"
theme[temp_end]="#ff3333"
EOF

cat > "$BTOP_DIR/btop.conf" << 'EOF'
color_theme = "skyware-red"
rounded_corners = True
vim_keys = True
graph_symbol = "block"
update_ms = 2000
EOF

# -----------------------------
# zsh + Starship
# -----------------------------
chsh -s /bin/zsh "$USER" || true

if ! command -v starship &>/dev/null; then
    curl -sS https://starship.rs/install.sh | sh
fi

# Delete old configs to avoid warnings
rm -f ~/.config/starship.toml
rm -rf ~/.config/starship.d

mkdir -p ~/.config
cat > "$HOME/.zshrc" << 'EOF'
# Load Starship prompt
eval "$(starship init zsh)"
alias ll='ls -lah'
EOF

cat > "$HOME/.config/starship.toml" << 'EOF'
[character]
success_symbol = "➜"
error_symbol   = "✗"
vicmd_symbol   = "❮"

[directory]
truncation_length = 3
style = "gray"

[git_branch]
symbol = " "
style = "bright-gray"

[git_status]
style = "gray"
conflicted = "✖"
ahead = "↑"
behind = "↓"
staged = "●"
deleted = "✖"
renamed = "➜"
modified = "!"
untracked = "?"
EOF

echo "== Finalizing Installation =="

# -----------------------------
# OS release branding
# -----------------------------
sudo tee /etc/os-release > /dev/null << 'EOF'
NAME="SkywareOS"
PRETTY_NAME="SkywareOS"
ID=skywareos
ID_LIKE=arch
VERSION="Red(0.7)"
VERSION_ID=Release_0-7
HOME_URL="https://github.com/SkywareSW"
LOGO=skywareos
EOF

sudo tee /usr/lib/os-release > /dev/null << 'EOF'
NAME="SkywareOS"
PRETTY_NAME="SkywareOS"
ID=skywareos
ID_LIKE=arch
VERSION="Red(0.7)"
VERSION_ID=Release_0-7
LOGO=skywareos
EOF

# -----------------------------
# Install distro logo (for KDE)
# -----------------------------
sudo mkdir -p /usr/share/icons/hicolor/scalable/apps
sudo cp assets/skywareos.svg \
  /usr/share/icons/hicolor/scalable/apps/skywareos.svg

sudo gtk-update-icon-cache /usr/share/icons/hicolor

# -----------------------------
# SDDM branding (login screen)
# -----------------------------
sudo pacman -S --noconfirm --needed sddm breeze sddm-kcm

sudo mkdir -p /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/10-skywareos.conf > /dev/null << 'EOF'
[Theme]
Current=breeze
EOF

sudo mkdir -p /usr/share/sddm/themes/breeze/assets
sudo cp assets/skywareos.svg \
  /usr/share/sddm/themes/breeze/assets/logo.svg

# SDDM background
if [[ -f assets/skywareos-wallpaper.png ]]; then
  sudo cp assets/skywareos-wallpaper.png \
    /usr/share/sddm/themes/breeze/background.png
fi

# -----------------------------
# Plasma Splash Screen (Look & Feel)
# -----------------------------
sudo mkdir -p /usr/share/plasma/look-and-feel/org.skywareos.desktop/contents/splash

sudo tee /usr/share/plasma/look-and-feel/org.skywareos.desktop/metadata.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=SkywareOS
Comment=SkywareOS Plasma Look and Feel
Type=Service
X-KDE-ServiceTypes=Plasma/LookAndFeel
X-KDE-PluginInfo-Name=org.skywareos.desktop
X-KDE-PluginInfo-Author=SkywareOS
X-KDE-PluginInfo-Version=1.0
X-KDE-PluginInfo-License=GPL
EOF

sudo tee /usr/share/plasma/look-and-feel/org.skywareos.desktop/contents/splash/Splash.qml > /dev/null << 'EOF'
import QtQuick 2.15

Rectangle {
    color: "#1e1e1e"

    Image {
        anchors.centerIn: parent
        source: "logo.svg"
        width: 256
        height: 256
        fillMode: Image.PreserveAspectFit
    }
}
EOF

sudo cp assets/skywareos.svg \
  /usr/share/plasma/look-and-feel/org.skywareos.desktop/contents/splash/logo.svg

# Set Plasma splash automatically
kwriteconfig6 --file kscreenlockerrc --group Greeter --key Theme org.skywareos.desktop
kwriteconfig6 --file plasmarc --group Theme --key name org.skywareos.desktop

echo "→ SkywareOS Finalization Complete"

echo "== Creating SkywareOS distro-grade package manager (ware) =="

sudo tee /usr/local/bin/ware > /dev/null << 'EOF'
#!/bin/bash

LOGFILE="/var/log/ware.log"
JSON_MODE=false

GREEN="\e[32m"
RED="\e[31m"
BLUE="\e[34m"
YELLOW="\e[33m"
CYAN="\e[36m"
RESET="\e[0m"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOGFILE" >/dev/null
}

header() {
    [ "$JSON_MODE" = true ] && return
    echo ""
}

spinner() {
    pid=$!
    spin='-\|/'
    i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r${CYAN}[%c] Working...${RESET}" "${spin:$i:1}"
        sleep .1
    done
    printf "\r"
}

have_paru() {
    command -v paru >/dev/null 2>&1
}

ensure_paru() {
    if ! have_paru; then
        echo -e "${YELLOW}→ Installing paru (AUR helper)...${RESET}"
        sudo pacman -S --needed --noconfirm base-devel git
        git clone https://aur.archlinux.org/paru.git /tmp/paru
        cd /tmp/paru || exit 1
        makepkg -si --noconfirm
        cd /
        rm -rf /tmp/paru
        log "paru installed"
    fi
}

install_pkg() {
    for pkg in "$@"; do
        log "Install requested: $pkg"

        if pacman -Si "$pkg" &>/dev/null; then
            sudo pacman -S --noconfirm "$pkg" &
            spinner
            wait
            log "Installed via pacman: $pkg"

        elif flatpak search --columns=application "$pkg" | grep -Fxq "$pkg"; then
            flatpak install -y flathub "$pkg" &
            spinner
            wait
            log "Installed via flatpak: $pkg"

        else
            ensure_paru
            if paru -Si "$pkg" &>/dev/null; then
                paru -S --noconfirm "$pkg" &
                spinner
                wait
                log "Installed via AUR: $pkg"
            else
                echo -e "${RED}✖ Package not found: $pkg${RESET}"
                log "FAILED install: $pkg"
            fi
        fi
    done
}

remove_pkg() {
    for pkg in "$@"; do
        if pacman -Q "$pkg" &>/dev/null; then
            sudo pacman -Rns --noconfirm "$pkg"
            log "Removed: $pkg"
        elif have_paru && paru -Q "$pkg" &>/dev/null; then
            paru -Rns --noconfirm "$pkg"
            log "Removed AUR: $pkg"
        elif flatpak list | grep -qi "$pkg"; then
            flatpak uninstall -y "$pkg"
            log "Removed flatpak: $pkg"
        else
            echo -e "${RED}✖ $pkg not installed${RESET}"
        fi
    done
}

doctor() {
    header

    echo -e "${CYAN}→ Checking package database integrity...${RESET}"
    sudo pacman -Dk

    echo ""
    echo -e "${CYAN}→ Checking Flatpak integrity...${RESET}"
    flatpak repair --dry-run

    echo ""
    echo -e "${CYAN}→ Checking firewall status...${RESET}"

    if command -v ufw >/dev/null 2>&1; then
        if systemctl is-enabled ufw >/dev/null 2>&1; then
            if systemctl is-active ufw >/dev/null 2>&1; then
                echo -e "${GREEN}✔ Firewall (ufw) is installed and ACTIVE${RESET}"
            else
                echo -e "${YELLOW}⚠ Firewall (ufw) is installed but NOT running${RESET}"
                echo -e "  → Start it with: sudo systemctl start ufw"
            fi
        else
            echo -e "${YELLOW}⚠ Firewall (ufw) is installed but NOT enabled${RESET}"
            echo -e "  → Enable it with: sudo systemctl enable ufw"
        fi
    else
        echo -e "${RED}✖ Firewall (ufw) is NOT installed${RESET}"
        echo -e "  → Install with: sudo pacman -S ufw"
    fi

    echo ""
    echo -e "${GREEN}Diagnostics complete.${RESET}"
}


clean_cache() {
    sudo pacman -Sc --noconfirm
    flatpak uninstall --unused -y
    log "Cache cleaned"
}

autoremove() {
    sudo pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null
    log "Autoremove executed"
}

power_profile() {
    profile="$1"

    case "$profile" in
        balanced)
            echo -e "${CYAN}→ Setting Balanced mode...${RESET}"
            sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1
            sudo systemctl enable tlp --now
            sudo cpupower frequency-set -g schedutil >/dev/null 2>&1
            echo -e "${GREEN}✔ Balanced profile applied${RESET}"
            ;;
        performance)
            echo -e "${CYAN}→ Setting Performance mode...${RESET}"
            sudo pacman -S --needed --noconfirm cpupower >/dev/null 2>&1
            sudo cpupower frequency-set -g performance
            sudo systemctl stop tlp >/dev/null 2>&1
            echo -e "${GREEN}✔ Performance profile applied${RESET}"
            ;;
        battery)
            echo -e "${CYAN}→ Setting Battery Saver mode...${RESET}"
            sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1
            sudo systemctl enable tlp --now
            sudo cpupower frequency-set -g powersave >/dev/null 2>&1
            echo -e "${GREEN}✔ Battery profile applied${RESET}"
            ;;
        status)
            echo -e "${CYAN}Power Profile Status:${RESET}"
            cpupower frequency-info | grep "current policy"
            ;;
        *)
            echo -e "${YELLOW}Usage: ware power <balanced|performance|battery>${RESET}"
            ;;
    esac
}

display_manager() {
    action="$1"
    dm="$2"

    case "$action" in
        list)
            echo -e "${CYAN}Available Display Managers:${RESET}"
            echo "  sddm"
            echo "  gdm"
            echo "  lightdm"
            ;;
        status)
            current=$(systemctl list-unit-files | grep -E 'gdm|sddm|lightdm' | grep enabled)
            echo -e "${CYAN}Current enabled DM:${RESET}"
            echo "$current"
            ;;
        switch)
            if [[ -z "$dm" ]]; then
                echo -e "${RED}Specify a display manager${RESET}"
                return
            fi

            echo -e "${YELLOW}→ Switching to $dm...${RESET}"

            sudo systemctl disable gdm sddm lightdm 2>/dev/null
            sudo systemctl enable "$dm"

            echo -e "${GREEN}✔ $dm enabled. Reboot required.${RESET}"
            ;;
        *)
            echo -e "${YELLOW}Usage: ware dm <list|switch|status>${RESET}"
            ;;
    esac
}

ware_status() {
    header

    echo -e "${CYAN}System Status${RESET}"
    echo "────────────────────────"

    kernel=$(uname -r)
    uptime=$(uptime -p)
    disk=$(df -h / | awk 'NR==2 {print $5}')
    mem=$(free -h | awk '/Mem:/ {print $3 "/" $2}')
    de="$XDG_CURRENT_DESKTOP"

    updates=$(checkupdates 2>/dev/null | wc -l)

    if command -v ufw >/dev/null 2>&1 && systemctl is-active ufw >/dev/null 2>&1; then
        firewall="Active"
    else
        firewall="Inactive"
    fi

    echo -e "Kernel:        $kernel"
    echo -e "Uptime:        $uptime"
    echo -e "Updates:       $updates available"
    echo -e "Firewall:      $firewall"
    echo -e "Disk Usage:    $disk"
    echo -e "Memory:        $mem"
    echo -e "Desktop:       ${de:-Unknown}"
    echo -e "Channel:       Release"
    echo -e "Version:       Red 0.7"
}


sync_mirrors() {
    sudo pacman -S --noconfirm reflector
    sudo reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
    log "Mirrors synced"
}

interactive_install() {
    read -rp "Enter package name: " pkg
    install_pkg "$pkg"
}

if [[ "$1" == "--json" ]]; then
    JSON_MODE=true
    shift
fi

case "$1" in
    install) shift; header; install_pkg "$@" ;;
    remove) shift; header; remove_pkg "$@" ;;
    update) header; sudo pacman -Syu; flatpak update -y; log "System updated" ;;
    search) shift; header; pacman -Ss "$@"; flatpak search "$@" ;;
    info) shift; header; pacman -Si "$1" 2>/dev/null || (have_paru && paru -Si "$1") || flatpak info "$1" ;;
    list) header; pacman -Q; flatpak list ;;
    doctor) doctor ;;
    power) shift; power_profile "$1" ;;
    dm) shift; display_manager "$@" ;;
    status) ware_status ;;
    clean) clean_cache ;;
    switch)
        sudo rm -rf SkywareOS/
        git clone https://github.com/SkywareSW/SkywareOS-Testing
        cd SkywareOS-Testing
        sed -i 's/\r$//' skyware-testingsetup.sh
        chmod +x skyware-testingsetup.sh
        ./skyware-testingsetup.sh
        ;;
    setup)
        shift
        case "$1" in
            hyprland)
                header
                echo -e "${YELLOW}→ Installing Hyprland environment...${RESET}"
                log "Hyprland setup started"

                sudo pacman -S --noconfirm \
                    hyprland \
                    xdg-desktop-portal-hyprland \
                    waybar \
                    wofi \
                    kitty \
                    grim \
                    slurp \
                    wl-clipboard \
                    polkit-kde-agent \
                    pipewire wireplumber \
                    network-manager-applet \
                    thunar

                echo -e "${GREEN}✔ Base Hyprland packages installed${RESET}"

                echo -e "${YELLOW}→ Running Skyware Hyprland dotfiles setup(jakoolit)...${RESET}"
                sh <(curl -L https://raw.githubusercontent.com/JaKooLit/Hyprland-Dots/main/Distro-Hyprland.sh)

                log "Hyprland setup completed"
                echo -e "${GREEN}✔ Hyprland setup complete${RESET}"
                ;;
            lazyvim)
                header
                echo "Installing LazyVim..."

                sudo pacman -S --noconfirm neovim git

                # Backup old nvim configs safely
                mv ~/.config/nvim ~/.config/nvim.bak 2>/dev/null || true
                mv ~/.local/share/nvim ~/.local/share/nvim.bak 2>/dev/null || true
                mv ~/.local/state/nvim ~/.local/state/nvim.bak 2>/dev/null || true
                mv ~/.cache/nvim ~/.cache/nvim.bak 2>/dev/null || true

                git clone https://github.com/LazyVim/starter ~/.config/nvim
                rm -rf ~/.config/nvim/.git

                echo "LazyVim installed."
                nvim
                ;;
            niri)
                header
                echo -e "${YELLOW}→ Installing Niri environment...${RESET}"
                log "niri setup started"
                pacman -S gum --noconfirm
                echo -e "${GREEN} Gum installed.${RESET}"
                echo -e "${YELLOW}→ Running Skyware Niri dotfiles setup...${RESET}"
                echo -e "${RED} Installing alongside hyprland is NOT recommended.${RESET}"
                git clone https://github.com/acaibowlz/niri-setup.git
                cd niri-setup
                chmod +x setup.sh
                ./setup.sh
                sudo mkdir -p /etc/niri
                sudo cp niri/* /etc/niri/
                cd niri-setup/
                ./setup
                log "Niri setup completed"
                echo -e "${GREEN}✔ Niri setup complete${RESET}"
                echo -e "${YELLOW} Reboot Recommended{RESET}"
                ;;
            mango)
                header
                echo -e "${YELLOW}→ Installing MangoWC environment...${RESET}"
                log "mangowc setup started"
                sudo pacman -S --noconfirm --needed glibc wayland wayland-protocols libinput libdrm libxkbcommon pixman git meson ninja libdisplay-info libliftoff hwdata seatd pcre2 xorg-xwayland libxcb ttf-jetbrains-mono-nerd
                echo -e "${GREEN} Dependencies installed.${RESET}"
                echo -e "${YELLOW}→ Installing MangoWC...${RESET}"
                yay -S mangowc-git
                echo -e "${GREEN} MangoWC installed.${RESET}"
                echo -e "${YELLOW}→ Setting up MangoWC Dotfiles...${RESET}"
                yay -S --noconfirm rofi foot xdg-desktop-portal-wlr swaybg waybar wl-clip-persist cliphist wl-clipboard wlsunset xfce-polkit swaync pamixer wlr-dpms sway-audio-idle-inhibit-git swayidle dimland-git brightnessctl swayosd wlr-randr grim slurp satty swaylock-effects-git wlogout sox
                git clone https://github.com/DreamMaoMao/mango-config.git ~/.config/mango
                log "MangoWC setup completed"
                echo -e "${GREEN}✔ MangoWC setup complete${RESET}"
                echo -e "${YELLOW} Reboot Recommended{RESET}"
                ;;
            *)
                echo -e "${RED}Unknown setup target${RESET}"
                ;;
        esac
        ;;
    upgrade)
        header
        echo "Updating and running latest Skyware installer..."

        rm -rf SkywareOS 2>/dev/null || true
        git clone https://github.com/SkywareSW/SkywareOS
        cd SkywareOS || exit 1
        sed -i 's/\r$//' skyware-setup.sh
        chmod +x skyware-setup.sh
        ./skyware-setup.sh
        ;;
    autoremove) autoremove ;;
    git)
        header
        echo "→ Opening SkywareOS website..."
        # Try xdg-open (Linux standard) to open default browser
        if command -v xdg-open &>/dev/null; then
            xdg-open "https://skywaresw.github.io/SkywareOS"
            echo "✔ Website opened in default browser"
        else
            echo "⚠ xdg-open not found. Please open the URL manually:"
            echo "  https://skywaresw.github.io/SkywareOS"
        fi
        ;;
    dualboot)
        header
        echo "→ Installing limine-entry-tool"
        yay -S limine-entry-tool --noconfirm
        echo -e "${YELLOW}→ Select the OS you want to add to limine...${RESET}"
        echo -e "${GREEN}→ Probably (1. Windows Boot Manager)...${RESET}"
        sudo limine-entry-tool --scan
        ;;
    snap)
        header
        echo -e "${YELLOW}→ Installing Snap support...${RESET}"
        log "Snap setup started"

        sudo pacman -S --noconfirm snapd
        sudo systemctl enable --now snapd.socket
        sudo ln -sf /var/lib/snapd/snap /snap

        echo -e "${GREEN}✔ Snap support enabled${RESET}"
        log "Snap setup completed"
        ;;
    snap-remove)
        header
        echo -e "${YELLOW}→ Removing Snap support...${RESET}"

        sudo systemctl disable snapd.socket
        sudo pacman -Rns --noconfirm snapd
        sudo rm -f /snap

        echo -e "${GREEN}✔ Snap removed${RESET}"
        ;;
    sync) sync_mirrors ;;
    help)
        echo -e "ware status - Shows kernel and version, Uptime, Available updates, Firewall status, Disk usage, Memory usage, Current desktop and current channel"
        echo -e "ware install - Searches for said package through pacman, flatpak and aur and then proceeds to install it"
        echo -e "ware remove - Removes package from system"
        echo -e "ware update - Updates system and or specific package"
        echo -e "ware upgrade - Installs and runs the latest version of SkywareOS"
        echo -e "ware switch - Switches from the Release channel to the Testing channel"
        echo -e "ware git - Opens the git website for SkywareOS"
        echo -e "ware power (balanced/performance/battery) - Switches power mode to either of those three depending on the selection"
        echo -e "ware dm list - Lists available display managers"
        echo -e "ware dm status - Shows currently active display manager"
        echo -e "ware dm switch(sddm/gdm/lightdm) - Switch between the available display managers"
        echo -e "ware search - Searches for the package or closest matching keyword in pacman, flatpak and aur"
        echo -e "ware info - Gives available information on a package"
        echo -e "ware list - Shows installed packages"
        echo -e "ware doctor - Searches for and fixes any corrupt or broken packages/dependencies, then checks the firewall status"
        echo -e "ware clean - Removes unused repositories/packages"
        echo -e "ware autoremove - Automatically removes unused packages"
        echo -e "ware sync - Syncs mirrors"
        echo -e "ware interactive - Simpler way to install a package"
        echo -e "ware --json - Run a custom command/script using JSON"
        echo -e "ware setup hyprland - Automatically Sets up hyprland with jakoolit's dotfiles"
        echo -e "ware setup lazyvim - Automatically sets up Lazyvim"
        echo -e "ware setup niri - Automatically sets up Niri (EXPERIMENTAL)"
        echo -e "ware setup mango - Automatically sets up MangoWC (EXPERIMENTAL)"
        echo -e "ware setup snap - Installs and enables the Snap package manager"
        echo -e "ware setup snap-remove - Removes the Snap package manager"
        ;;
    interactive) interactive_install ;;
    *) 
        header
        echo "Usage:"
        echo "  ware status"
        echo "  ware help"
        echo "  ware install <pkg>"
        echo "  ware remove <pkg>"
        echo "  ware update"
        echo "  ware upgrade"
        echo "  ware switch"
        echo "  ware git"
        echo "  ware power (balanced/performance/battery)"
        echo "  ware dm (switch/list/status)"
        echo "  ware search <pkg>"
        echo "  ware info <pkg>"
        echo "  ware list"
        echo "  ware doctor"
        echo "  ware clean"
        echo "  ware autoremove"
        echo "  ware sync"
        echo "  ware interactive"
        echo "  ware --json <command>"
        echo "  ware setup (hyprland/lazyvim)"
        echo "  ware setup niri(experimental)"
        echo "  ware setup mango(experimental)"
        echo "  ware setup snap"
        echo "  ware setup snap-remove"
        ;;
esac
EOF

sudo chmod +x /usr/local/bin/ware


# -----------------------------
# Done
# -----------------------------
echo "== SkywareOS full setup complete =="
echo "Log out or reboot required"
