#!/bin/bash
set -e

echo "== SkywareOS setup starting =="

# -----------------------------
# Pacman packages
# -----------------------------
sudo pacman -Syu --noconfirm --needed \
    flatpak cmatrix fastfetch btop zsh alacritty kitty curl git base-devel

# -----------------------------
# Firewall
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
        sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils nvidia-settings
    else
        sudo pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings
    fi
elif echo "$GPU_INFO" | grep -qi "AMD"; then
    sudo pacman -S --noconfirm --needed xf86-video-amdgpu mesa
elif echo "$GPU_INFO" | grep -qi "Intel"; then
    sudo pacman -S --noconfirm --needed xf86-video-intel mesa
elif echo "$GPU_INFO" | grep -qi "VMware"; then
    sudo pacman -S --noconfirm --needed open-vm-tools mesa
else
    echo "⚠ Could not detect GPU automatically"
fi

# ============================================================
# Limine Boot Entry Rename + Plymouth Bootsplash
# ============================================================
echo "== Setting up SkywareOS bootloader branding + bootsplash =="

# ── 1. Locate limine.conf ────────────────────────────────────
LIMINE_CONF=""
for candidate in \
    /boot/limine.conf \
    /boot/EFI/limine/limine.conf \
    /efi/limine.conf \
    /efi/EFI/limine/limine.conf; do
    if [ -f "$candidate" ]; then
        LIMINE_CONF="$candidate"
        break
    fi
done

if [ -n "$LIMINE_CONF" ]; then
    echo "→ Limine config found at $LIMINE_CONF"
    sudo cp "$LIMINE_CONF" "$LIMINE_CONF.bak"

    # Rename every boot entry label to "SkywareOS"
    # Limine entry labels look like:   /Arch Linux
    # We replace any label line that follows a [linux] protocol section
    sudo python3 - "$LIMINE_CONF" << 'PYEOF'
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

# Replace label lines inside entry blocks:
# Limine entry format uses lines like:  label = Arch Linux
content = re.sub(
    r'(?im)^(\s*label\s*=\s*).*$',
    r'\1SkywareOS',
    content
)

# Also handle older limine.conf style where entry name is after a slash:
# /Arch Linux   →  /SkywareOS
content = re.sub(
    r'(?im)^(/)\S.*$',
    r'/SkywareOS',
    content
)

# Ensure quiet splash in kernel cmdline so Plymouth shows
content = re.sub(
    r'(?im)^(\s*cmdline\s*=\s*)(.*)$',
    lambda m: m.group(0) if 'quiet' in m.group(2) else m.group(1) + m.group(2).rstrip() + ' quiet splash',
    content
)

with open(path, 'w') as f:
    f.write(content)

print("✔ Limine entries renamed to SkywareOS")
PYEOF

    # ── Limine logo (shown next to boot entry) ──────────────
    # Limine supports a background image — copy logo as wallpaper
    LIMINE_DIR=$(dirname "$LIMINE_CONF")

    # Generate a 1920x1080 boot background with the Skyware logo centered
    if [ -f assets/skywareos-logo.svg ]; then
        sudo pacman -S --noconfirm --needed imagemagick librsvg

        # Convert SVG logo to PNG at display size
        sudo rsvg-convert -w 300 -h 300 assets/skywareos-logo.svg \
            -o /tmp/skyware-logo-300.png

        # Composite onto a dark background (1920x1080)
        sudo convert \
            -size 1920x1080 xc:#111113 \
            /tmp/skyware-logo-300.png \
            -gravity Center -composite \
            "$LIMINE_DIR/skywareos-boot.png"

        # Point limine.conf at the background
        if ! grep -qi "^background_path" "$LIMINE_CONF"; then
            echo "" | sudo tee -a "$LIMINE_CONF" >/dev/null
            echo "background_path = skywareos-boot.png" | sudo tee -a "$LIMINE_CONF" >/dev/null
        else
            sudo sed -i "s|^background_path.*|background_path = skywareos-boot.png|i" "$LIMINE_CONF"
        fi

        echo "✔ Limine boot background set to Skyware logo"
    else
        echo "⚠ assets/skywareos-logo.svg not found — skipping Limine logo"
    fi
else
    echo "⚠ Limine config not found — skipping bootloader branding"
fi

# ── 2. Plymouth bootsplash ───────────────────────────────────
echo "→ Setting up Plymouth bootsplash..."

if ! command -v plymouthd &>/dev/null; then
    sudo pacman -S --noconfirm --needed plymouth
fi
sudo pacman -S --noconfirm --needed librsvg

THEME_DIR="/usr/share/plymouth/themes/skywareos"
sudo mkdir -p "$THEME_DIR"

# Convert logo SVG → PNG for Plymouth (512x512 and a smaller 128x128 spinner base)
if [ -f assets/skywareos-logo.svg ]; then
    sudo rsvg-convert -w 512 -h 512 assets/skywareos-logo.svg \
        -o "$THEME_DIR/logo.png"
    sudo rsvg-convert -w 128 -h 128 assets/skywareos-logo.svg \
        -o "$THEME_DIR/logo-small.png"
    echo "✔ Plymouth logo images generated"
else
    echo "⚠ assets/skywareos-logo.svg not found — Plymouth will show text-only splash"
fi

# Theme descriptor
sudo tee "$THEME_DIR/skywareos.plymouth" >/dev/null << 'EOF'
[Plymouth Theme]
Name=SkywareOS
Description=SkywareOS Boot Splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/skywareos
ScriptFile=/usr/share/plymouth/themes/skywareos/skywareos.script
EOF

# Plymouth script — centered logo on dark background with a clean progress bar
sudo tee "$THEME_DIR/skywareos.script" >/dev/null << 'EOF'
# ── SkywareOS Plymouth Theme ──────────────────────────────────

# Background
Window.SetBackgroundTopColor(0.07, 0.07, 0.07);
Window.SetBackgroundBottomColor(0.04, 0.04, 0.05);

# Load and center the logo
logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);

logo.x = Window.GetWidth()  / 2 - logo.image.GetWidth()  / 2;
logo.y = Window.GetHeight() / 2 - logo.image.GetHeight() / 2 - 40;
logo.sprite.SetPosition(logo.x, logo.y, 0);

# Progress bar — thin strip at bottom
bar_height  = 3;
bar_y       = Window.GetHeight() - 60;
bar_width   = Window.GetWidth() * 0.4;
bar_x       = Window.GetWidth() / 2 - bar_width / 2;

# Background track (dark)
bar_bg.image  = Image.Scale(Image.New(1, 1), bar_width, bar_height);
bar_bg.image.SetOpacity(0.15);
bar_bg.sprite = Sprite(bar_bg.image);
bar_bg.sprite.SetPosition(bar_x, bar_y, 1);

# Filled portion (light gray)
bar.width  = 1;
bar.image  = Image.Scale(Image.New(1, 1), bar.width, bar_height);
bar.sprite = Sprite(bar.image);
bar.sprite.SetPosition(bar_x, bar_y, 2);

fun refresh_callback() {
    bar.sprite.SetOpacity(1);
    bar_bg.sprite.SetOpacity(0.2);
}
Plymouth.SetRefreshFunction(refresh_callback);

fun boot_progress_callback(duration, progress) {
    new_width = Math.Int(bar_width * progress);
    if (new_width < 2) new_width = 2;
    if (new_width != bar.width) {
        bar.width = new_width;
        bar.image = Image.Scale(Image.New(1, 1), bar.width, bar_height);
        bar.image.FillWithColor(0.63, 0.63, 0.73, 1.0);
        bar.sprite.SetImage(bar.image);
    }
}
Plymouth.SetBootProgressFunction(boot_progress_callback);

fun quit_callback() {
    logo.sprite.SetOpacity(0);
    bar.sprite.SetOpacity(0);
    bar_bg.sprite.SetOpacity(0);
}
Plymouth.SetQuitFunction(quit_callback);
EOF

# ── 3. Hook Plymouth into initramfs ─────────────────────────
# Must be after 'base udev' and before 'filesystems' in the HOOKS array
if grep -q "^HOOKS=" /etc/mkinitcpio.conf; then
    if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
        # Insert plymouth right after udev
        sudo sed -i '/^HOOKS=/ s/udev/udev plymouth/' /etc/mkinitcpio.conf
        echo "→ Plymouth hook inserted after udev in mkinitcpio.conf"
    else
        echo "→ Plymouth hook already present in mkinitcpio.conf"
    fi
fi

sudo mkinitcpio -P
echo "✔ Initramfs rebuilt with Plymouth"

sudo plymouth-set-default-theme -R skywareos
echo "✔ Plymouth theme set: skywareos"

echo "→ Bootloader branding + bootsplash setup complete"

# -----------------------------
# Desktop Environment
# -----------------------------
echo "== Checking for existing Desktop Environment =="
DE_ALREADY_INSTALLED=false
if systemctl is-enabled gdm &>/dev/null || systemctl is-enabled sddm &>/dev/null || systemctl is-enabled lightdm &>/dev/null; then
    DE_ALREADY_INSTALLED=true
fi
if pacman -Q plasma-desktop &>/dev/null || pacman -Q gnome-shell &>/dev/null || pacman -Q deepin &>/dev/null; then
    DE_ALREADY_INSTALLED=true
fi

if [ "$DE_ALREADY_INSTALLED" = true ]; then
    echo "→ Existing DE detected, skipping."
else
    sudo pacman -S --noconfirm --needed gdm lightdm sddm
    echo "Select your Desktop Environment:"
    echo "1) KDE Plasma  2) GNOME  3) Deepin  4) Skip"
    read -rp "Enter choice (1/2/3/4): " de_choice
    case "$de_choice" in
        1) sudo pacman -S --noconfirm plasma kde-applications sddm; sudo systemctl enable sddm ;;
        2) sudo pacman -S --noconfirm gnome gnome-extra gdm; sudo systemctl enable gdm ;;
        3) sudo pacman -S --noconfirm deepin deepin-kwin deepin-extra lightdm; sudo systemctl enable lightdm ;;
        *) echo "Skipping..." ;;
    esac
fi

# -----------------------------
# Flatpak apps
# -----------------------------
if ! flatpak remote-list | grep -q flathub; then
    sudo flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
fi
flatpak install -y flathub com.discordapp.Discord com.spotify.Client com.valvesoftware.Steam

# -----------------------------
# Fastfetch
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
  "logo": { "type": "file", "source": "~/.config/fastfetch/logos/skyware.txt", "padding": { "top": 0, "left": 2 } },
  "modules": ["title","separator",{"type":"os","format":"SkywareOS","use_pretty_name":false},"kernel","uptime","packages","shell","cpu","gpu","memory"]
}
EOF

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
# btop theme
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
# zsh + Starship + plugins
# -----------------------------
chsh -s /bin/zsh "$USER" || true
if ! command -v starship &>/dev/null; then
    curl -sS https://starship.rs/install.sh | sh
fi

sudo pacman -S --noconfirm --needed \
    zsh-autosuggestions \
    zsh-syntax-highlighting \
    fzf \
    zoxide \
    eza

rm -f ~/.config/starship.toml; rm -rf ~/.config/starship.d; mkdir -p ~/.config

cat > "$HOME/.zshrc" << 'ZSHEOF'
# ── SkywareOS zshrc ──────────────────────────────────────────

# Plugins
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# fzf keybinds (Ctrl+R history search, Ctrl+T file picker)
source /usr/share/fzf/key-bindings.zsh
source /usr/share/fzf/completion.zsh
export FZF_DEFAULT_OPTS="--color=bg+:#1f1f23,bg:#111113,spinner:#a0a0b0,hl:#60a5fa \
  --color=fg:#e2e2ec,header:#7a7a8a,info:#a0a0b0,pointer:#c8c8dc \
  --color=marker:#4ade80,fg+:#e2e2ec,prompt:#a0a0b0,hl+:#60a5fa \
  --border=rounded --prompt='  ' --pointer='▶' --marker='✔'"

# zoxide — smarter cd
eval "$(zoxide init zsh)"
alias cd='z'

# eza — better ls
alias ls='eza --icons --group-directories-first'
alias ll='eza -lah --icons --group-directories-first --git'
alias tree='eza --tree --icons'

# Dotfiles alias
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE

# Auto-completion
autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Run fastfetch on new terminal
fastfetch

# Starship prompt
eval "$(starship init zsh)"
ZSHEOF
cat > "$HOME/.config/starship.toml" << 'EOF'
[character]
success_symbol = "➜"
error_symbol   = "✗"
vicmd_symbol   = "❮"
[directory]
truncation_length = 3
style = "gray"
[git_branch]
symbol = " "
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

# -----------------------------
# KDE / SDDM branding
# -----------------------------
sudo mkdir -p /usr/share/icons/hicolor/scalable/apps
sudo cp assets/skywareos.svg /usr/share/icons/hicolor/scalable/apps/skywareos.svg 2>/dev/null || true
sudo gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# ── KDE Kickoff start button icon ─────────────────────────────
# Register the logo under a dedicated icon name for Kickoff
sudo cp assets/skywareos.svg \
    /usr/share/icons/hicolor/scalable/apps/skywareos-start.svg 2>/dev/null || true
sudo gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

# Startup script that patches the Kickoff applet once Plasma is running
mkdir -p "$HOME/.config/plasma-workspace/env"
cat > "$HOME/.config/plasma-workspace/env/skyware-kickoff-icon.sh" << 'ENVEOF'
#!/bin/bash
# SkywareOS: set Kickoff start button icon on first Plasma login
APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
FLAG="$HOME/.config/skyware/kickoff-icon-set"
[ -f "$FLAG" ] && exit 0
sleep 4  # wait for Plasma to finish loading

if [ -f "$APPLETSRC" ]; then
    # Find the applet ID for the Kickoff/Kicker widget
    KICKOFF_ID=$(grep -B5 "org.kde.plasma.kickoff\|org.kde.plasma.kicker" \
        "$APPLETSRC" 2>/dev/null \
        | grep "^\[Applets\]\[" | tail -1 | grep -oP '[0-9]+')

    if [ -n "$KICKOFF_ID" ]; then
        kwriteconfig6 \
            --file plasma-org.kde.plasma.desktop-appletsrc \
            --group "Applets" --group "$KICKOFF_ID" \
            --group "Configuration" --group "General" \
            --key "icon" "skywareos-start"

        # Soft-reload plasmashell applets (no full restart needed)
        qdbus6 org.kde.plasmashell /PlasmaShell \
            org.kde.PlasmaShell.evaluateScript \
            "var a=desktops()[0]; print(a);" 2>/dev/null || true

        echo "SkywareOS: Kickoff icon set (applet $KICKOFF_ID)"
    fi
fi

mkdir -p "$(dirname "$FLAG")"
touch "$FLAG"
ENVEOF
chmod +x "$HOME/.config/plasma-workspace/env/skyware-kickoff-icon.sh"

# If appletsrc already exists (upgrading), patch it immediately too
if [ -f "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" ]; then
    KICKOFF_ID=$(grep -B5 "org.kde.plasma.kickoff\|org.kde.plasma.kicker" \
        "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null \
        | grep "^\[Applets\]\[" | tail -1 | grep -oP '[0-9]+')
    if [ -n "$KICKOFF_ID" ]; then
        kwriteconfig6 \
            --file plasma-org.kde.plasma.desktop-appletsrc \
            --group "Applets" --group "$KICKOFF_ID" \
            --group "Configuration" --group "General" \
            --key "icon" "skywareos-start" 2>/dev/null || true
        echo "✔ Kickoff icon patched immediately (applet ID: $KICKOFF_ID)"
    fi
fi
echo "✔ KDE Kickoff start button will use skywareos.svg on next login"
sudo pacman -S --noconfirm --needed sddm breeze sddm-kcm
sudo mkdir -p /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/10-skywareos.conf > /dev/null << 'EOF'
[Theme]
Current=breeze
EOF
sudo mkdir -p /usr/share/sddm/themes/breeze/assets
sudo cp assets/skywareos.svg /usr/share/sddm/themes/breeze/assets/logo.svg 2>/dev/null || true
if [[ -f assets/skywareos-wallpaper.png ]]; then
    sudo cp assets/skywareos-wallpaper.png /usr/share/sddm/themes/breeze/background.png
fi
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
    Image { anchors.centerIn: parent; source: "logo.svg"; width: 256; height: 256; fillMode: Image.PreserveAspectFit }
}
EOF
sudo cp assets/skywareos.svg /usr/share/plasma/look-and-feel/org.skywareos.desktop/contents/splash/logo.svg 2>/dev/null || true
kwriteconfig6 --file kscreenlockerrc --group Greeter --key Theme org.skywareos.desktop 2>/dev/null || true
kwriteconfig6 --file plasmarc --group Theme --key name org.skywareos.desktop 2>/dev/null || true

# ============================================================
# ware package manager
# ============================================================
echo "== Installing ware package manager =="
sudo tee /usr/local/bin/ware > /dev/null << 'EOF'
#!/bin/bash
LOGFILE="/var/log/ware.log"
JSON_MODE=false
GREEN="\e[32m"; RED="\e[31m"; BLUE="\e[34m"; YELLOW="\e[33m"; CYAN="\e[36m"; RESET="\e[0m"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOGFILE" >/dev/null; }
header() { [ "$JSON_MODE" = true ] && return; echo ""; }
spinner() { pid=$!; spin='-\|/'; i=0; while kill -0 $pid 2>/dev/null; do i=$(( (i+1) %4 )); printf "\r${CYAN}[%c] Working...${RESET}" "${spin:$i:1}"; sleep .1; done; printf "\r"; }
have_paru() { command -v paru >/dev/null 2>&1; }
ensure_paru() {
    if ! have_paru; then
        sudo pacman -S --needed --noconfirm base-devel git
        git clone https://aur.archlinux.org/paru.git /tmp/paru; cd /tmp/paru || exit 1
        makepkg -si --noconfirm; cd /; rm -rf /tmp/paru; log "paru installed"
    fi
}
install_pkg() {
    for pkg in "$@"; do
        log "Install requested: $pkg"
        if pacman -Si "$pkg" &>/dev/null; then sudo pacman -S --noconfirm "$pkg" & spinner; wait; log "Installed via pacman: $pkg"
        elif flatpak search --columns=application "$pkg" | grep -Fxq "$pkg"; then flatpak install -y flathub "$pkg" & spinner; wait; log "Installed via flatpak: $pkg"
        else
            ensure_paru
            if paru -Si "$pkg" &>/dev/null; then paru -S --noconfirm "$pkg" & spinner; wait; log "Installed via AUR: $pkg"
            else echo -e "${RED}✖ Package not found: $pkg${RESET}"; log "FAILED install: $pkg"; fi
        fi
    done
}
remove_pkg() {
    for pkg in "$@"; do
        if pacman -Q "$pkg" &>/dev/null; then sudo pacman -Rns --noconfirm "$pkg"; log "Removed: $pkg"
        elif have_paru && paru -Q "$pkg" &>/dev/null; then paru -Rns --noconfirm "$pkg"; log "Removed AUR: $pkg"
        elif flatpak list | grep -qi "$pkg"; then flatpak uninstall -y "$pkg"; log "Removed flatpak: $pkg"
        else echo -e "${RED}✖ $pkg not installed${RESET}"; fi
    done
}
doctor() {
    header
    echo -e "${CYAN}→ Checking package database integrity...${RESET}"; sudo pacman -Dk
    echo ""; echo -e "${CYAN}→ Checking Flatpak integrity...${RESET}"; flatpak repair --dry-run
    echo ""; echo -e "${CYAN}→ Checking firewall status...${RESET}"
    if command -v ufw >/dev/null 2>&1; then
        if systemctl is-active ufw >/dev/null 2>&1; then echo -e "${GREEN}✔ Firewall (ufw) is ACTIVE${RESET}"
        else echo -e "${YELLOW}⚠ Firewall (ufw) is NOT running${RESET}"; fi
    else echo -e "${RED}✖ Firewall (ufw) is NOT installed${RESET}"; fi
    echo ""; echo -e "${GREEN}Diagnostics complete.${RESET}"
}
clean_cache() { sudo pacman -Sc --noconfirm; flatpak uninstall --unused -y; log "Cache cleaned"; }
autoremove() { sudo pacman -Rns $(pacman -Qtdq) --noconfirm 2>/dev/null; log "Autoremove executed"; }
power_profile() {
    case "$1" in
        balanced)   sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1; sudo systemctl enable tlp --now; sudo cpupower frequency-set -g schedutil >/dev/null 2>&1; echo -e "${GREEN}✔ Balanced${RESET}" ;;
        performance) sudo pacman -S --needed --noconfirm cpupower >/dev/null 2>&1; sudo cpupower frequency-set -g performance; sudo systemctl stop tlp >/dev/null 2>&1; echo -e "${GREEN}✔ Performance${RESET}" ;;
        battery)    sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1; sudo systemctl enable tlp --now; sudo cpupower frequency-set -g powersave >/dev/null 2>&1; echo -e "${GREEN}✔ Battery${RESET}" ;;
        status)     cpupower frequency-info | grep "current policy" ;;
        *)          echo -e "${YELLOW}Usage: ware power <balanced|performance|battery>${RESET}" ;;
    esac
}
display_manager() {
    case "$1" in
        list)   echo "  sddm"; echo "  gdm"; echo "  lightdm" ;;
        status) systemctl list-unit-files | grep -E 'gdm|sddm|lightdm' | grep enabled ;;
        switch) [ -z "$2" ] && { echo -e "${RED}Specify a DM${RESET}"; return; }; sudo systemctl disable gdm sddm lightdm 2>/dev/null; sudo systemctl enable "$2"; echo -e "${GREEN}✔ $2 enabled. Reboot required.${RESET}" ;;
        *)      echo -e "${YELLOW}Usage: ware dm <list|switch|status>${RESET}" ;;
    esac
}
ware_status() {
    header; echo -e "${CYAN}System Status${RESET}"; echo "────────────────────────"
    kernel=$(uname -r); uptime_str=$(uptime -p); disk=$(df -h / | awk 'NR==2 {print $5}')
    mem=$(free -h | awk '/Mem:/ {print $3 "/" $2}'); de="$XDG_CURRENT_DESKTOP"
    updates=$(checkupdates 2>/dev/null | wc -l)
    if command -v ufw >/dev/null 2>&1 && systemctl is-active ufw >/dev/null 2>&1; then firewall="Active"; else firewall="Inactive"; fi
    echo -e "Kernel:        $kernel\nUptime:        $uptime_str\nUpdates:       $updates available\nFirewall:      $firewall\nDisk Usage:    $disk\nMemory:        $mem\nDesktop:       ${de:-Unknown}\nChannel:       Release\nVersion:       Red 0.7"
}
sync_mirrors() { sudo pacman -S --noconfirm reflector; sudo reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist; log "Mirrors synced"; }
interactive_install() { read -rp "Enter package name: " pkg; install_pkg "$pkg"; }
[[ "$1" == "--json" ]] && { JSON_MODE=true; shift; }
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
    switch) sudo rm -rf SkywareOS/; git clone https://github.com/SkywareSW/SkywareOS-Testing; cd SkywareOS-Testing; sed -i 's/\r$//' skyware-testingsetup.sh; chmod +x skyware-testingsetup.sh; ./skyware-testingsetup.sh ;;
    upgrade) rm -rf SkywareOS 2>/dev/null || true; git clone https://github.com/SkywareSW/SkywareOS; cd SkywareOS || exit 1; sed -i 's/\r$//' skyware-setup.sh; chmod +x skyware-setup.sh; ./skyware-setup.sh ;;
    autoremove) autoremove ;;
    git) command -v xdg-open &>/dev/null && xdg-open "https://skywaresw.github.io/SkywareOS" || echo "https://skywaresw.github.io/SkywareOS" ;;
    dualboot) yay -S limine-entry-tool --noconfirm; sudo limine-entry-tool --scan ;;
    snap) sudo pacman -S --noconfirm snapd; sudo systemctl enable --now snapd.socket; sudo ln -sf /var/lib/snapd/snap /snap; echo -e "${GREEN}✔ Snap enabled${RESET}" ;;
    snap-remove) sudo systemctl disable snapd.socket; sudo pacman -Rns --noconfirm snapd; sudo rm -f /snap; echo -e "${GREEN}✔ Snap removed${RESET}" ;;
    sync) sync_mirrors ;;
    setup)
        shift
        case "$1" in
            hyprland)
                sudo pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland waybar wofi kitty grim slurp wl-clipboard polkit-kde-agent pipewire wireplumber network-manager-applet thunar
                sh <(curl -L https://raw.githubusercontent.com/JaKooLit/Hyprland-Dots/main/Distro-Hyprland.sh) ;;
            lazyvim)
                sudo pacman -S --noconfirm neovim git
                mv ~/.config/nvim ~/.config/nvim.bak 2>/dev/null || true
                git clone https://github.com/LazyVim/starter ~/.config/nvim; rm -rf ~/.config/nvim/.git; nvim ;;
            niri)
                pacman -S gum --noconfirm
                git clone https://github.com/acaibowlz/niri-setup.git; cd niri-setup; chmod +x setup.sh; ./setup.sh
                sudo mkdir -p /etc/niri; sudo cp niri/* /etc/niri/ ;;
            mango)
                sudo pacman -S --noconfirm --needed glibc wayland wayland-protocols libinput libdrm libxkbcommon pixman git meson ninja libdisplay-info libliftoff hwdata seatd pcre2 xorg-xwayland libxcb ttf-jetbrains-mono-nerd
                yay -S mangowc-git; git clone https://github.com/DreamMaoMao/mango-config.git ~/.config/mango ;;
            *) echo -e "${RED}Unknown setup target${RESET}" ;;
        esac ;;
    settings) exec skyware-settings ;;
    backup)
        header
        echo -e "${CYAN}→ SkywareOS Backup${RESET}"
        if ! command -v timeshift &>/dev/null; then
            echo -e "${YELLOW}→ Installing Timeshift...${RESET}"
            sudo pacman -S --noconfirm --needed timeshift
        fi
        case "$2" in
            create)
                echo -e "${CYAN}→ Creating snapshot...${RESET}"
                sudo timeshift --create --comments "ware backup $(date '+%Y-%m-%d %H:%M')" --tags D
                log "Snapshot created"
                ;;
            list)
                sudo timeshift --list
                ;;
            restore)
                sudo timeshift --restore
                ;;
            delete)
                sudo timeshift --delete
                ;;
            *)
                echo -e "Usage:"
                echo -e "  ware backup create   - Take a new snapshot"
                echo -e "  ware backup list     - List all snapshots"
                echo -e "  ware backup restore  - Restore a snapshot (interactive)"
                echo -e "  ware backup delete   - Delete a snapshot (interactive)"
                ;;
        esac
        ;;
    repair)
        header
        echo -e "${CYAN}== SkywareOS Repair ==${RESET}"

        echo -e "${CYAN}→ Step 1: Fixing pacman keyring...${RESET}"
        sudo pacman-key --init
        sudo pacman-key --populate archlinux
        sudo pacman-key --refresh-keys 2>/dev/null || true
        echo -e "${GREEN}✔ Keyring refreshed${RESET}"

        echo -e "${CYAN}→ Step 2: Clearing pacman cache and locks...${RESET}"
        sudo rm -f /var/lib/pacman/db.lck
        sudo pacman -Sc --noconfirm
        echo -e "${GREEN}✔ Lock removed, cache cleared${RESET}"

        echo -e "${CYAN}→ Step 3: Checking for broken packages...${RESET}"
        sudo pacman -Dk 2>&1 | grep -v "^$" || true

        echo -e "${CYAN}→ Step 4: Reinstalling broken packages...${RESET}"
        BROKEN=$(sudo pacman -Qk 2>&1 | grep "warning:" | awk '{print $2}' | cut -d: -f1 | sort -u)
        if [ -n "$BROKEN" ]; then
            echo -e "${YELLOW}→ Reinstalling: $BROKEN${RESET}"
            sudo pacman -S --noconfirm $BROKEN
        else
            echo -e "${GREEN}✔ No broken packages found${RESET}"
        fi

        echo -e "${CYAN}→ Step 5: Fixing orphaned dependencies...${RESET}"
        ORPHANS=$(pacman -Qtdq 2>/dev/null)
        if [ -n "$ORPHANS" ]; then
            sudo pacman -Rns --noconfirm $ORPHANS
            echo -e "${GREEN}✔ Orphans removed${RESET}"
        else
            echo -e "${GREEN}✔ No orphans${RESET}"
        fi

        echo -e "${CYAN}→ Step 6: Fixing Flatpak...${RESET}"
        flatpak repair 2>/dev/null || true
        flatpak uninstall --unused -y 2>/dev/null || true
        echo -e "${GREEN}✔ Flatpak repaired${RESET}"

        echo -e "${CYAN}→ Step 7: Restarting failed systemd units...${RESET}"
        FAILED=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}')
        if [ -n "$FAILED" ]; then
            for unit in $FAILED; do
                sudo systemctl restart "$unit" 2>/dev/null &&                     echo -e "${GREEN}✔ Restarted $unit${RESET}" ||                     echo -e "${RED}✖ Could not restart $unit${RESET}"
            done
        else
            echo -e "${GREEN}✔ No failed units${RESET}"
        fi

        echo ""
        echo -e "${GREEN}== Repair complete ==${RESET}"
        log "ware repair run"
        ;;
    benchmark)
        header
        echo -e "${CYAN}== SkywareOS Benchmark ==${RESET}"
        echo ""

        # CPU
        echo -e "${CYAN}── CPU ─────────────────────────────${RESET}"
        CPU_MODEL=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
        CPU_CORES=$(nproc)
        echo -e "Model:  $CPU_MODEL"
        echo -e "Cores:  $CPU_CORES"
        echo -e "${YELLOW}→ Running single-core integer benchmark (5s)...${RESET}"
        CPU_SCORE=$(python3 -c "
import time, math
start = time.time()
count = 0
while time.time() - start < 5:
    math.factorial(10000)
    count += 1
print(count)
")
        echo -e "Score:  ${CPU_SCORE} ops/5s"

        # RAM
        echo ""
        echo -e "${CYAN}── Memory ──────────────────────────${RESET}"
        MEM_TOTAL=$(free -h | awk '/Mem:/{print $2}')
        MEM_USED=$(free -h  | awk '/Mem:/{print $3}')
        echo -e "Total:  $MEM_TOTAL   Used: $MEM_USED"
        echo -e "${YELLOW}→ Running memory bandwidth test...${RESET}"
        MEM_BW=$(python3 -c "
import time, array
size = 100_000_000
a = array.array('B', bytes(size))
start = time.time()
b = bytes(a)
elapsed = time.time() - start
gb = size / 1e9
print(f'{gb/elapsed:.1f} GB/s')
")
        echo -e "Bandwidth: $MEM_BW"

        # Disk
        echo ""
        echo -e "${CYAN}── Disk ────────────────────────────${RESET}"
        DISK_DEVICE=$(df / | awk 'NR==2{print $1}')
        echo -e "Device: $DISK_DEVICE"
        echo -e "${YELLOW}→ Sequential write test (512MB)...${RESET}"
        WRITE_SPEED=$(dd if=/dev/zero of=/tmp/skyware-bench bs=1M count=512             conv=fdatasync 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1)
        rm -f /tmp/skyware-bench
        echo -e "${YELLOW}→ Sequential read test (512MB)...${RESET}"
        READ_SPEED=$(dd if=/dev/urandom of=/tmp/skyware-bench-src bs=1M count=512 2>/dev/null
            dd if=/tmp/skyware-bench-src of=/dev/null bs=1M 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1)
        rm -f /tmp/skyware-bench-src
        echo -e "Write:  ${WRITE_SPEED:-unavailable}"
        echo -e "Read:   ${READ_SPEED:-unavailable}"

        echo ""
        echo -e "${GREEN}── Summary ─────────────────────────${RESET}"
        echo -e "CPU Score:  $CPU_SCORE ops/5s"
        echo -e "RAM Speed:  $MEM_BW"
        echo -e "Disk Write: ${WRITE_SPEED:-n/a}   Read: ${READ_SPEED:-n/a}"
        log "benchmark run"
        ;;
    help)
        echo -e "ware status              - System overview"
        echo -e "ware install <pkg>       - Install a package"
        echo -e "ware remove <pkg>        - Remove a package"
        echo -e "ware update              - Update system"
        echo -e "ware upgrade             - Upgrade SkywareOS"
        echo -e "ware switch              - Switch to testing channel"
        echo -e "ware settings            - Open SkywareOS Settings GUI"
        echo -e "ware power <mode>        - Set power profile (balanced/performance/battery)"
        echo -e "ware dm <action>         - Manage display managers"
        echo -e "ware search <pkg>        - Search packages"
        echo -e "ware info <pkg>          - Package info"
        echo -e "ware list                - List installed packages"
        echo -e "ware doctor              - Run diagnostics + optional AI repair"
        echo -e "ware repair              - Fix broken pacman DB, packages, failed units"
        echo -e "ware backup <action>     - Snapshot management (create/list/restore/delete)"
        echo -e "ware benchmark           - CPU / RAM / disk speed test"
        echo -e "ware clean               - Clean cache"
        echo -e "ware autoremove          - Remove orphaned packages"
        echo -e "ware sync                - Sync mirrors"
        echo -e "ware interactive         - Interactive install"
        echo -e "ware setup hyprland/lazyvim/niri/mango - Environment setup"
        echo -e "ware snap/snap-remove    - Manage Snap support"
        echo -e "ware git                 - Open SkywareOS website"
        echo -e "ware dualboot            - Set up dual boot with Limine" ;;
    interactive) interactive_install ;;
    *)
        echo "Usage: ware <command>"
        echo "Run 'ware help' for a full list of commands." ;;
esac
EOF
sudo chmod +x /usr/local/bin/ware

# ============================================================
# SkywareOS Settings App (Electron + React)
# ============================================================
echo "== Installing SkywareOS Settings App =="

sudo pacman -S --noconfirm --needed nodejs npm

APP_DIR="/opt/skyware-settings"
sudo mkdir -p "$APP_DIR/src"

# package.json
sudo tee "$APP_DIR/package.json" > /dev/null << 'EOF'
{
  "name": "skyware-settings",
  "version": "0.7.0",
  "description": "SkywareOS Settings",
  "main": "main.js",
  "scripts": { "start": "electron .", "build": "vite build" },
  "dependencies": { "react": "^18.2.0", "react-dom": "^18.2.0" },
  "devDependencies": { "electron": "^30.0.0", "@vitejs/plugin-react": "^4.0.0", "vite": "^5.0.0" }
}
EOF

# Electron main process
sudo tee "$APP_DIR/main.js" > /dev/null << 'EOF'
const { app, BrowserWindow, ipcMain } = require('electron');
const { exec } = require('child_process');
const path = require('path');

function createWindow() {
  const win = new BrowserWindow({
    width: 1000, height: 680, minWidth: 800, minHeight: 560,
    frame: false, backgroundColor: '#111113',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false,
    },
    title: 'SkywareOS Settings',
  });
  win.loadFile(path.join(__dirname, 'dist', 'index.html'));
}

ipcMain.handle('run-cmd', async (event, cmd) => {
  return new Promise((resolve) => {
    exec(`pkexec bash -c "${cmd.replace(/"/g, '\\"')}"`, (err, stdout, stderr) => {
      resolve({ stdout: stdout || '', stderr: stderr || '', code: err ? err.code : 0 });
    });
  });
});

ipcMain.on('window-minimize', (e) => BrowserWindow.fromWebContents(e.sender).minimize());
ipcMain.on('window-maximize', (e) => { const w = BrowserWindow.fromWebContents(e.sender); w.isMaximized() ? w.unmaximize() : w.maximize(); });
ipcMain.on('window-close',    (e) => BrowserWindow.fromWebContents(e.sender).close());

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
EOF

# Preload
sudo tee "$APP_DIR/preload.js" > /dev/null << 'EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('skyware', {
  runCmd:   (cmd) => ipcRenderer.invoke('run-cmd', cmd),
  minimize: ()    => ipcRenderer.send('window-minimize'),
  maximize: ()    => ipcRenderer.send('window-maximize'),
  close:    ()    => ipcRenderer.send('window-close'),
});
EOF

# Vite config
sudo tee "$APP_DIR/vite.config.js" > /dev/null << 'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], base: './', build: { outDir: 'dist' } });
EOF

# HTML entry
sudo tee "$APP_DIR/index.html" > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8"/>
    <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
    <title>SkywareOS Settings</title>
    <style>* { margin:0; padding:0; box-sizing:border-box; } body { overflow:hidden; background:#111113; } #root { height:100vh; }</style>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

# React entry
sudo tee "$APP_DIR/src/main.jsx" > /dev/null << 'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
createRoot(document.getElementById('root')).render(<App />);
EOF

# Main App component (written to a temp file first to avoid heredoc quoting issues)
sudo tee "$APP_DIR/src/App.jsx" > /dev/null << 'APPEOF'
import { useState, useEffect, useRef } from "react";

const C = {
  bg:"#111113",bgSide:"#0e0e10",bgHeader:"#0c0c0e",bgCard:"#18181b",bgHover:"#1f1f23",
  border:"#2a2a2f",borderFaint:"#1e1e22",accent:"#a0a0b0",accentHi:"#c8c8dc",
  muted:"#4a4a58",mutedLo:"#2e2e38",text:"#e2e2ec",textDim:"#7a7a8a",
  green:"#4ade80",yellow:"#facc15",red:"#f87171",blue:"#60a5fa",purple:"#a78bfa",orange:"#fb923c",
};

const SIDEBAR = [
  {id:"status",  label:"System Status", icon:"◈"},
  {id:"packages",label:"Packages",      icon:"⬡"},
  {id:"power",   label:"Power",         icon:"⚡"},
  {id:"display", label:"Display Mgr",   icon:"⬕"},
  {id:"setup",   label:"Environments",  icon:"◉"},
  {id:"system",  label:"System Tools",  icon:"⚙"},
  {id:"channel", label:"Channel",       icon:"◎"},
];

const api = (cmd) => window.skyware?.runCmd(cmd) ?? Promise.resolve({stdout:`[sim] ${cmd}`,stderr:"",code:0});

function useTerminal() {
  const [lines, setLines] = useState([]);
  const add = (text, type="info") => setLines(p=>[...p,{text,type,id:Date.now()+Math.random()}]);
  return { lines, add };
}

function TitleBar() {
  const btns = [
    {l:"–",a:()=>window.skyware?.minimize(),c:C.yellow},
    {l:"□",a:()=>window.skyware?.maximize(),c:C.green},
    {l:"×",a:()=>window.skyware?.close(),   c:C.red},
  ];
  return (
    <div style={{WebkitAppRegion:"drag",height:"50px",background:C.bgHeader,borderBottom:`1px solid ${C.borderFaint}`,display:"flex",alignItems:"center",justifyContent:"space-between",padding:"0 20px",flexShrink:0}}>
      <div style={{display:"flex",alignItems:"center",gap:"10px"}}>
        <div style={{width:"24px",height:"24px",borderRadius:"5px",background:`linear-gradient(135deg,${C.accent},#505060)`,display:"flex",alignItems:"center",justifyContent:"center",fontSize:"12px",fontWeight:900,color:"#fff"}}>S</div>
        <span style={{color:C.text,fontWeight:600,fontSize:"13px"}}>SkywareOS Settings</span>
        <span style={{background:C.bgHover,color:C.textDim,fontSize:"10px",borderRadius:"4px",padding:"2px 7px",border:`1px solid ${C.border}`}}>Red 0.7</span>
      </div>
      <div style={{WebkitAppRegion:"no-drag",display:"flex",gap:"6px"}}>
        {btns.map(b=>(
          <button key={b.l} onClick={b.a}
            style={{width:"28px",height:"22px",borderRadius:"4px",border:`1px solid ${C.border}`,background:"transparent",color:C.textDim,cursor:"pointer",fontSize:"12px",fontFamily:"inherit",transition:"all 0.1s"}}
            onMouseEnter={e=>{e.target.style.background=b.c+"33";e.target.style.color=b.c;}}
            onMouseLeave={e=>{e.target.style.background="transparent";e.target.style.color=C.textDim;}}>
            {b.l}
          </button>
        ))}
      </div>
    </div>
  );
}

function Terminal({lines,onClose}) {
  const ref=useRef(null);
  useEffect(()=>{if(ref.current)ref.current.scrollTop=ref.current.scrollHeight;},[lines]);
  const col={info:C.textDim,success:C.green,error:C.red,cmd:C.accentHi,warn:C.yellow};
  return (
    <div style={{position:"absolute",bottom:0,left:0,right:0,height:"200px",background:"#0a0a0c",borderTop:`1px solid ${C.border}`,fontFamily:"'JetBrains Mono','Fira Code',monospace",fontSize:"12px",display:"flex",flexDirection:"column",zIndex:50}}>
      <div style={{padding:"6px 16px",borderBottom:`1px solid ${C.borderFaint}`,display:"flex",justifyContent:"space-between",alignItems:"center"}}>
        <span style={{color:C.accent,fontSize:"11px",letterSpacing:"0.12em",textTransform:"uppercase"}}>Terminal Output</span>
        <button onClick={onClose} style={{background:"none",border:"none",color:C.muted,cursor:"pointer",fontSize:"18px",lineHeight:1}}>×</button>
      </div>
      <div ref={ref} style={{flex:1,overflowY:"auto",padding:"8px 16px"}}>
        {lines.map(l=>(
          <div key={l.id} style={{color:col[l.type]||C.textDim,marginBottom:"2px",lineHeight:"1.6"}}>
            {l.type==="cmd"?<><span style={{color:C.accent}}>$ </span>{l.text}</>:l.text}
          </div>
        ))}
      </div>
    </div>
  );
}

function Card({label,value,ab}) {
  return (
    <div style={{background:C.bgCard,border:`1px solid ${ab||C.border}`,borderRadius:"8px",padding:"14px 18px",display:"flex",flexDirection:"column",gap:"5px"}}>
      <span style={{color:C.muted,fontSize:"11px",textTransform:"uppercase",letterSpacing:"0.1em"}}>{label}</span>
      <span style={{color:C.text,fontSize:"14px",fontWeight:500}}>{value}</span>
    </div>
  );
}

function Hdr({title,sub}) {
  return (
    <div style={{marginBottom:"28px"}}>
      <h2 style={{color:C.text,fontSize:"19px",fontWeight:600,margin:0,letterSpacing:"-0.02em"}}>{title}</h2>
      {sub&&<p style={{color:C.textDim,fontSize:"13px",margin:"6px 0 0",lineHeight:1.5}}>{sub}</p>}
      <div style={{width:"32px",height:"2px",background:C.accent,marginTop:"12px",borderRadius:"2px"}}/>
    </div>
  );
}

function Btn({label,cmd,onClick,variant="default",icon}) {
  const [h,setH]=useState(false);
  const v={
    default:{bg:h?C.bgHover:"transparent",border:C.border,     color:C.text },
    danger: {bg:h?"#2a1515":"transparent",border:C.red+"66",   color:C.red  },
    success:{bg:h?"#0d1f14":"transparent",border:C.green+"44", color:C.green},
  }[variant];
  return (
    <button onMouseEnter={()=>setH(true)} onMouseLeave={()=>setH(false)} onClick={()=>onClick(cmd,label)}
      style={{background:v.bg,border:`1px solid ${v.border}`,color:v.color,borderRadius:"7px",padding:"10px 16px",cursor:"pointer",fontSize:"13px",fontFamily:"inherit",transition:"all 0.12s",display:"flex",alignItems:"center",gap:"8px",textAlign:"left"}}>
      {icon&&<span style={{fontSize:"14px"}}>{icon}</span>}<span>{label}</span>
    </button>
  );
}

function StatusSection({run}) {
  const [s,setS]=useState({kernel:"…",uptime:"…",firewall:"…",disk:"…",memory:"…",desktop:"…",updates:"…"});
  useEffect(()=>{
    api("uname -r").then(r=>setS(p=>({...p,kernel:r.stdout.trim()||"—"})));
    api("uptime -p").then(r=>setS(p=>({...p,uptime:r.stdout.trim()||"—"})));
    api("systemctl is-active ufw 2>/dev/null; echo $?").then(r=>setS(p=>({...p,firewall:r.stdout.includes("active")?"Active":"Inactive"})));
    api("df -h / | awk 'NR==2{print $5}'").then(r=>setS(p=>({...p,disk:r.stdout.trim()||"—"})));
    api("free -h | awk '/Mem:/{print $3\"/\"$2}'").then(r=>setS(p=>({...p,memory:r.stdout.trim()||"—"})));
    api("echo ${XDG_CURRENT_DESKTOP:-Unknown}").then(r=>setS(p=>({...p,desktop:r.stdout.trim()||"Unknown"})));
    api("checkupdates 2>/dev/null | wc -l || echo 0").then(r=>setS(p=>({...p,updates:r.stdout.trim()||"0"})));
  },[]);
  return (
    <div>
      <Hdr title="System Status" sub="Live overview of your SkywareOS installation."/>
      <div style={{display:"grid",gridTemplateColumns:"repeat(3,1fr)",gap:"10px",marginBottom:"24px"}}>
        <Card label="Version"    value="Red 0.7 · Release" ab={C.accent+"44"}/>
        <Card label="Kernel"     value={s.kernel}/>
        <Card label="Uptime"     value={s.uptime}/>
        <Card label="Firewall"   value={s.firewall} ab={s.firewall==="Active"?C.green+"44":C.red+"33"}/>
        <Card label="Memory"     value={s.memory}/>
        <Card label="Disk Usage" value={s.disk}/>
        <Card label="Desktop"    value={s.desktop}/>
        <Card label="Updates"    value={`${s.updates} available`} ab={parseInt(s.updates)>0?C.yellow+"44":undefined}/>
      </div>
      <div style={{display:"flex",gap:"10px",flexWrap:"wrap"}}>
        <Btn label="Run Diagnostics" cmd="ware doctor"    onClick={run} icon="🩺"/>
        <Btn label="Update System"   cmd="ware update"    onClick={run} icon="↑" variant="success"/>
        <Btn label="Sync Mirrors"    cmd="ware sync"      onClick={run} icon="⟳"/>
        <Btn label="Clean Cache"     cmd="ware clean"     onClick={run} icon="✦"/>
        <Btn label="Autoremove"      cmd="ware autoremove"onClick={run} icon="✖" variant="danger"/>
      </div>
    </div>
  );
}

function PackagesSection({run}) {
  const [search,setSearch]=useState(""); const [tab,setTab]=useState("installed"); const [pkgs,setPkgs]=useState([]);
  useEffect(()=>{
    if(tab==="installed") {
      api("pacman -Q 2>/dev/null | head -50").then(r=>{
        const lines=r.stdout.trim().split("\n").filter(Boolean);
        setPkgs(lines.map(l=>{const[n,...v]=l.split(" ");return{name:n,version:v.join(" ")||"—",source:"pacman"};}));
      });
    }
  },[tab]);
  const filtered=pkgs.filter(p=>p.name?.toLowerCase().includes(search.toLowerCase()));
  const sc={pacman:C.blue,flatpak:C.purple,aur:C.orange};
  return (
    <div>
      <Hdr title="Packages" sub="Install, remove, and search across pacman, flatpak, and AUR."/>
      <div style={{display:"flex",gap:"8px",marginBottom:"20px"}}>
        {["installed","search","manage"].map(t=>(
          <button key={t} onClick={()=>setTab(t)} style={{background:tab===t?C.bgHover:"transparent",border:`1px solid ${tab===t?C.accent:C.borderFaint}`,color:tab===t?C.accentHi:C.textDim,borderRadius:"6px",padding:"7px 16px",cursor:"pointer",fontSize:"12px",textTransform:"capitalize",fontFamily:"inherit",fontWeight:tab===t?600:400,transition:"all 0.12s"}}>{t}</button>
        ))}
      </div>
      {tab==="installed"&&<>
        <input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Filter packages…"
          style={{background:C.bgCard,border:`1px solid ${C.border}`,color:C.text,borderRadius:"7px",padding:"9px 14px",fontSize:"13px",width:"100%",boxSizing:"border-box",outline:"none",fontFamily:"inherit",marginBottom:"12px"}}/>
        <div style={{display:"flex",flexDirection:"column",gap:"6px",maxHeight:"300px",overflowY:"auto"}}>
          {filtered.map(p=>(
            <div key={p.name} style={{display:"flex",alignItems:"center",justifyContent:"space-between",background:C.bgCard,border:`1px solid ${C.borderFaint}`,borderRadius:"7px",padding:"10px 14px"}}>
              <div style={{display:"flex",alignItems:"center",gap:"12px"}}>
                <span style={{background:(sc[p.source]||C.accent)+"22",color:sc[p.source]||C.accent,fontSize:"10px",borderRadius:"4px",padding:"2px 7px",textTransform:"uppercase"}}>{p.source}</span>
                <span style={{color:C.text,fontSize:"13px"}}>{p.name}</span>
              </div>
              <div style={{display:"flex",alignItems:"center",gap:"12px"}}>
                <span style={{color:C.muted,fontSize:"12px"}}>{p.version}</span>
                <button onClick={()=>run(`ware remove ${p.name}`,`Remove ${p.name}`)} style={{background:"transparent",border:`1px solid ${C.red}44`,color:C.red,borderRadius:"5px",padding:"3px 10px",cursor:"pointer",fontSize:"11px",fontFamily:"inherit"}}>Remove</button>
              </div>
            </div>
          ))}
        </div>
      </>}
      {tab==="search"&&<div style={{display:"flex",flexDirection:"column",gap:"12px"}}>
        <div style={{display:"flex",gap:"8px"}}>
          <input id="psi" placeholder="Search package name…" style={{background:C.bgCard,border:`1px solid ${C.border}`,color:C.text,borderRadius:"7px",padding:"9px 14px",fontSize:"13px",flex:1,outline:"none",fontFamily:"inherit"}}/>
          <button onClick={()=>{const v=document.getElementById("psi").value;if(v)run(`ware search ${v}`,`Search: ${v}`);}} style={{background:C.bgHover,border:`1px solid ${C.accent}`,color:C.accentHi,borderRadius:"7px",padding:"9px 20px",cursor:"pointer",fontSize:"13px",fontWeight:600,fontFamily:"inherit"}}>Search</button>
        </div>
        <Btn label="Install Package" cmd="" onClick={()=>{const v=document.getElementById("psi").value;if(v)run(`ware install ${v}`,`Install: ${v}`);}} icon="+" variant="success"/>
      </div>}
      {tab==="manage"&&<div style={{display:"flex",flexDirection:"column",gap:"10px"}}>
        <Btn label="Update All" cmd="ware update" onClick={run} icon="↑" variant="success"/>
        <Btn label="Autoremove Orphans" cmd="ware autoremove" onClick={run} icon="✖"/>
        <Btn label="Clean Cache" cmd="ware clean" onClick={run} icon="✦"/>
        <Btn label="List All Packages" cmd="ware list" onClick={run} icon="◈"/>
        <Btn label="Interactive Install" cmd="ware interactive" onClick={run} icon="⬡"/>
      </div>}
    </div>
  );
}

function PowerSection({run}) {
  const [active,setActive]=useState("balanced");
  const profiles=[
    {id:"balanced",   label:"Balanced",     icon:"⚖", desc:"Optimal performance and efficiency for everyday use."},
    {id:"performance",label:"Performance",  icon:"⚡",desc:"Maximum CPU speed. Best for gaming or heavy workloads."},
    {id:"battery",    label:"Battery Saver",icon:"🔋",desc:"Reduces power draw to extend battery life."},
  ];
  return (
    <div>
      <Hdr title="Power Management" sub="Switch CPU governor profiles via TLP and cpupower."/>
      <div style={{display:"flex",flexDirection:"column",gap:"10px"}}>
        {profiles.map(p=>(
          <div key={p.id} onClick={()=>{setActive(p.id);run(`ware power ${p.id}`,`Power: ${p.label}`);}}
            style={{background:active===p.id?C.bgHover:C.bgCard,border:`1px solid ${active===p.id?C.accent:C.border}`,borderRadius:"9px",padding:"16px 20px",cursor:"pointer",display:"flex",alignItems:"center",gap:"16px",transition:"all 0.14s"}}>
            <span style={{fontSize:"22px"}}>{p.icon}</span>
            <div style={{flex:1}}>
              <div style={{color:active===p.id?C.accentHi:C.text,fontWeight:600,fontSize:"14px"}}>{p.label}</div>
              <div style={{color:C.textDim,fontSize:"12px",marginTop:"3px"}}>{p.desc}</div>
            </div>
            {active===p.id&&<div style={{color:C.accent,fontSize:"18px"}}>●</div>}
          </div>
        ))}
      </div>
      <div style={{marginTop:"18px"}}><Btn label="Check Current Profile" cmd="ware power status" onClick={run} icon="◈"/></div>
    </div>
  );
}

function DisplaySection({run}) {
  const dms=["sddm","gdm","lightdm"]; const [sel,setSel]=useState("sddm");
  return (
    <div>
      <Hdr title="Display Manager" sub="Switch between login screen managers. Requires reboot."/>
      <div style={{display:"flex",gap:"10px",marginBottom:"24px"}}>
        {dms.map(dm=>(
          <div key={dm} onClick={()=>setSel(dm)} style={{background:sel===dm?C.bgHover:C.bgCard,border:`1px solid ${sel===dm?C.accent:C.border}`,borderRadius:"8px",padding:"16px 24px",cursor:"pointer",textAlign:"center",transition:"all 0.14s",minWidth:"100px"}}>
            <div style={{color:sel===dm?C.accentHi:C.text,fontWeight:600,fontSize:"14px",textTransform:"uppercase",letterSpacing:"0.05em"}}>{dm}</div>
            {sel===dm&&<div style={{color:C.muted,fontSize:"10px",marginTop:"4px"}}>selected</div>}
          </div>
        ))}
      </div>
      <div style={{display:"flex",gap:"10px",flexWrap:"wrap"}}>
        <Btn label={`Switch to ${sel}`} cmd={`ware dm switch ${sel}`} onClick={run} icon="⬕" variant="success"/>
        <Btn label="Current Status" cmd="ware dm status" onClick={run} icon="◈"/>
        <Btn label="List All DMs" cmd="ware dm list" onClick={run} icon="☰"/>
      </div>
    </div>
  );
}

function SetupSection({run}) {
  const envs=[
    {id:"hyprland",label:"Hyprland",icon:"◈",desc:"Wayland compositor with JaKooLit dotfiles.",    badge:"Stable"},
    {id:"lazyvim", label:"LazyVim", icon:"◉",desc:"Neovim config with lazy.nvim plugin manager.", badge:"Stable"},
    {id:"niri",    label:"Niri",    icon:"⬡",desc:"Scrollable tiling Wayland compositor.",         badge:"Experimental"},
    {id:"mango",   label:"MangoWC", icon:"⬕",desc:"MangoWC Wayland compositor with custom dotfiles.",badge:"Experimental"},
  ];
  const bc={Stable:C.green,Experimental:C.yellow};
  return (
    <div>
      <Hdr title="Environments" sub="Install and configure desktop environments and window compositors."/>
      <div style={{display:"grid",gridTemplateColumns:"repeat(2,1fr)",gap:"12px"}}>
        {envs.map(e=>(
          <div key={e.id} style={{background:C.bgCard,border:`1px solid ${C.border}`,borderRadius:"9px",padding:"18px",display:"flex",flexDirection:"column",gap:"10px"}}>
            <div style={{display:"flex",justifyContent:"space-between",alignItems:"flex-start"}}>
              <div style={{display:"flex",gap:"10px",alignItems:"center"}}>
                <span style={{fontSize:"18px",color:C.accent}}>{e.icon}</span>
                <span style={{color:C.text,fontWeight:600,fontSize:"14px"}}>{e.label}</span>
              </div>
              <span style={{background:bc[e.badge]+"22",color:bc[e.badge],fontSize:"10px",borderRadius:"4px",padding:"2px 7px"}}>{e.badge}</span>
            </div>
            <p style={{color:C.textDim,fontSize:"12px",margin:0,lineHeight:1.5}}>{e.desc}</p>
            <button onClick={()=>run(`ware setup ${e.id}`,`Setup ${e.label}`)} style={{background:"transparent",border:`1px solid ${C.border}`,color:C.accentHi,borderRadius:"6px",padding:"8px",cursor:"pointer",fontSize:"12px",fontFamily:"inherit",transition:"all 0.12s",marginTop:"auto"}}>Install {e.label}</button>
          </div>
        ))}
      </div>
    </div>
  );
}

function SystemSection({run}) {
  return (
    <div>
      <Hdr title="System Tools" sub="Maintenance utilities and package manager extensions."/>
      <div style={{display:"grid",gridTemplateColumns:"repeat(2,1fr)",gap:"10px"}}>
        <Btn label="Run Doctor"         cmd="ware doctor"      onClick={run} icon="🩺"/>
        <Btn label="Sync Mirrors"       cmd="ware sync"        onClick={run} icon="⟳"/>
        <Btn label="Clean Cache"        cmd="ware clean"       onClick={run} icon="✦"/>
        <Btn label="Autoremove Orphans" cmd="ware autoremove"  onClick={run} icon="✖"/>
        <Btn label="Enable Snap"        cmd="ware snap"        onClick={run} icon="+"/>
        <Btn label="Remove Snap"        cmd="ware snap-remove" onClick={run} icon="✖" variant="danger"/>
        <Btn label="Dual Boot (Limine)" cmd="ware dualboot"    onClick={run} icon="⬡"/>
        <Btn label="Open Website"       cmd="ware git"         onClick={run} icon="◎"/>
      </div>
    </div>
  );
}

function ChannelSection({run}) {
  const [ch,setCh]=useState("release");
  const opts=[
    {id:"release",label:"Release",desc:"Stable, tested builds. Recommended for most users.",color:C.green},
    {id:"testing",label:"Testing",desc:"Latest features, may have bugs. For enthusiasts.",  color:C.yellow},
  ];
  return (
    <div>
      <Hdr title="Update Channel" sub="Switch between the stable Release channel and the bleeding-edge Testing channel."/>
      <div style={{display:"flex",gap:"12px",marginBottom:"24px"}}>
        {opts.map(o=>(
          <div key={o.id} onClick={()=>setCh(o.id)} style={{background:ch===o.id?C.bgHover:C.bgCard,border:`1px solid ${ch===o.id?o.color+"88":C.border}`,borderRadius:"9px",padding:"20px",cursor:"pointer",flex:1,transition:"all 0.14s"}}>
            <div style={{color:ch===o.id?o.color:C.text,fontWeight:700,fontSize:"14px",marginBottom:"6px"}}>{o.label} {ch===o.id&&"●"}</div>
            <div style={{color:C.textDim,fontSize:"12px",lineHeight:1.5}}>{o.desc}</div>
          </div>
        ))}
      </div>
      <div style={{display:"flex",gap:"10px"}}>
        {ch==="testing"&&<Btn label="Switch to Testing" cmd="ware switch" onClick={run} icon="◎" variant="danger"/>}
        <Btn label="Upgrade SkywareOS" cmd="ware upgrade" onClick={run} icon="↑" variant="success"/>
      </div>
    </div>
  );
}

export default function App() {
  const [active,setActive]=useState("status");
  const [termOpen,setTermOpen]=useState(false);
  const {lines,add}=useTerminal();

  const run=async(cmd,label)=>{
    setTermOpen(true); add(cmd,"cmd"); add(`→ Running: ${label||cmd}…`,"info");
    const r=await api(cmd);
    if(r.stdout) r.stdout.trim().split("\n").filter(Boolean).forEach(l=>add(l,"info"));
    if(r.stderr) r.stderr.trim().split("\n").filter(Boolean).forEach(l=>add(l,"error"));
    add("✔ Done.","success");
  };

  const sections={status:StatusSection,packages:PackagesSection,power:PowerSection,display:DisplaySection,setup:SetupSection,system:SystemSection,channel:ChannelSection};
  const ActiveSection=sections[active];

  return (
    <div style={{height:"100vh",background:C.bg,fontFamily:"'Segoe UI','SF Pro Display',system-ui,sans-serif",color:C.text,display:"flex",flexDirection:"column",overflow:"hidden",position:"relative"}}>
      <TitleBar/>
      <div style={{display:"flex",flex:1,overflow:"hidden"}}>
        <div style={{width:"192px",background:C.bgSide,borderRight:`1px solid ${C.borderFaint}`,flexShrink:0,padding:"14px 0",overflowY:"auto"}}>
          {SIDEBAR.map(s=>(
            <button key={s.id} onClick={()=>setActive(s.id)}
              style={{width:"100%",background:active===s.id?C.bgHover:"transparent",border:"none",borderLeft:`2px solid ${active===s.id?C.accent:"transparent"}`,color:active===s.id?C.accentHi:C.muted,padding:"10px 18px",cursor:"pointer",textAlign:"left",fontSize:"13px",fontFamily:"inherit",transition:"all 0.1s",display:"flex",alignItems:"center",gap:"10px"}}>
              <span style={{fontSize:"13px"}}>{s.icon}</span>{s.label}
            </button>
          ))}
          <div style={{padding:"20px 18px 0",borderTop:`1px solid ${C.borderFaint}`,marginTop:"24px"}}>
            <div style={{color:C.mutedLo,fontSize:"10px",lineHeight:1.8}}><div>ware v0.7</div><div>SkywareOS · Red</div></div>
          </div>
        </div>
        <div style={{flex:1,padding:"28px 32px",overflowY:"auto",paddingBottom:termOpen?"220px":"28px"}}>
          <ActiveSection run={run}/>
        </div>
      </div>
      {termOpen&&<Terminal lines={lines} onClose={()=>setTermOpen(false)}/>}
      {!termOpen&&(
        <button onClick={()=>{setTermOpen(true);if(lines.length===0)add("Terminal ready.","info");}}
          style={{position:"absolute",bottom:"12px",right:"16px",background:C.bgCard,border:`1px solid ${C.border}`,color:C.textDim,borderRadius:"6px",padding:"6px 14px",cursor:"pointer",fontSize:"11px",fontFamily:"inherit",letterSpacing:"0.07em",zIndex:40}}>
          TERMINAL ▲
        </button>
      )}
    </div>
  );
}
APPEOF

# Build the React app
echo "→ Installing npm dependencies and building the Settings app..."
cd "$APP_DIR"
sudo npm install --silent 2>&1 | tail -3
sudo npx vite build --silent 2>&1 | tail -5
echo "✔ React app built"

# Install electron globally via npm
sudo npm install -g electron --silent 2>&1 | tail -3
echo "✔ Electron installed"

# Launcher wrapper script
sudo tee /usr/local/bin/skyware-settings > /dev/null << 'EOF'
#!/bin/bash
exec electron /opt/skyware-settings "$@"
EOF
sudo chmod +x /usr/local/bin/skyware-settings

# .desktop entry for app launchers (KDE, GNOME, etc.)
sudo tee /usr/share/applications/skyware-settings.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=SkywareOS Settings
Comment=Manage your SkywareOS installation
Exec=/usr/local/bin/skyware-settings
Icon=preferences-system
Terminal=false
Type=Application
Categories=System;Settings;
Keywords=skyware;settings;system;ware;packages;
StartupWMClass=skyware-settings
EOF

echo "✔ SkywareOS Settings installed"
echo "  → Launch from app menu: 'SkywareOS Settings'"
echo "  → Or run: skyware-settings"
echo "  → Or run: ware settings"

# ============================================================
# AppArmor (Mandatory Access Control)
# ============================================================
echo "== Setting up AppArmor =="

sudo pacman -S --noconfirm --needed apparmor

# Enable the AppArmor systemd service
sudo systemctl enable apparmor

# Add apparmor to kernel cmdline so it activates at boot
if [ -n "$LIMINE_CONF" ]; then
    sudo python3 - "$LIMINE_CONF" << 'PYEOF'
import sys, re
path = sys.argv[1]
with open(path) as f:
    content = f.read()
def add_apparmor(m):
    line = m.group(0)
    if 'apparmor=1' not in line:
        line = line.rstrip() + ' apparmor=1 security=apparmor'
    return line
content = re.sub(r'(?im)^(\s*cmdline\s*=\s*.*)$', add_apparmor, content)
with open(path, 'w') as f:
    f.write(content)
print("✔ AppArmor kernel params added to limine.conf")
PYEOF
fi

# Install extra AppArmor profiles
sudo pacman -S --noconfirm --needed apparmor-profiles 2>/dev/null || true

echo "✔ AppArmor enabled (enforcing on next boot)"

# ============================================================
# Automatic Security Updates (pacman hook)
# ============================================================
echo "== Setting up automatic security updates =="

sudo pacman -S --noconfirm --needed archlinux-keyring

# Install systemd timer to run security updates weekly
sudo mkdir -p /etc/systemd/system

sudo tee /etc/systemd/system/skyware-security-update.service > /dev/null << 'EOF'
[Unit]
Description=SkywareOS Automatic Security Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/pacman -Syu --noconfirm --needed
ExecStartPost=/usr/bin/flatpak update -y
StandardOutput=journal
StandardError=journal
EOF

sudo tee /etc/systemd/system/skyware-security-update.timer > /dev/null << 'EOF'
[Unit]
Description=SkywareOS Weekly Security Update Timer

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF

sudo systemctl enable skyware-security-update.timer
echo "✔ Weekly auto-update timer enabled (skyware-security-update.timer)"

# pacman hook to re-sign keyring after updates
sudo mkdir -p /etc/pacman.d/hooks
sudo tee /etc/pacman.d/hooks/keyring-refresh.hook > /dev/null << 'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = archlinux-keyring

[Action]
Description = Refreshing pacman keyring after upgrade...
When = PostTransaction
Exec = /usr/bin/pacman-key --refresh-keys
EOF

echo "✔ Pacman keyring auto-refresh hook installed"

# ============================================================
# SSH Hardening
# ============================================================
echo "== Hardening SSH =="

sudo pacman -S --noconfirm --needed openssh

# Backup original sshd config
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true

sudo tee /etc/ssh/sshd_config.d/99-skywareos-hardening.conf > /dev/null << 'EOF'
# SkywareOS SSH Hardening
PermitRootLogin no
PasswordAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 20
AllowAgentForwarding no
AllowTcpForwarding no
Protocol 2
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

sudo systemctl enable sshd
echo "✔ SSH hardened (root login disabled, max 3 auth attempts)"

# ============================================================
# USBGuard (USB Attack Protection)
# ============================================================
echo "== Setting up USBGuard =="

sudo pacman -S --noconfirm --needed usbguard

# Generate an initial policy from currently connected devices
# This whitelists everything plugged in right now, blocks new unknown devices
sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf >/dev/null

sudo systemctl enable usbguard
sudo systemctl start usbguard

echo "✔ USBGuard enabled — current USB devices whitelisted"
echo "  → New unknown USB devices will be blocked by default"
echo "  → To allow a new device: sudo usbguard allow-device <id>"

# ============================================================
# Bluetooth
# ============================================================
echo "== Setting up Bluetooth =="

sudo pacman -S --noconfirm --needed bluez bluez-utils blueman

sudo systemctl enable bluetooth

# Enable auto-power-on for bluetooth adapter at boot
sudo mkdir -p /etc/bluetooth
if [ ! -f /etc/bluetooth/main.conf ]; then
    sudo tee /etc/bluetooth/main.conf > /dev/null << 'EOF'
[Policy]
AutoEnable=true
EOF
else
    # Patch existing config
    if ! grep -q "AutoEnable" /etc/bluetooth/main.conf; then
        echo -e "\n[Policy]\nAutoEnable=true" | sudo tee -a /etc/bluetooth/main.conf >/dev/null
    else
        sudo sed -i 's/AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf
    fi
fi

echo "✔ Bluetooth enabled (bluez + blueman GUI)"

# ============================================================
# Printing (CUPS)
# ============================================================
echo "== Setting up printing support =="

sudo pacman -S --noconfirm --needed cups cups-pdf system-config-printer \
    gutenprint foomatic-db foomatic-db-engine

sudo systemctl enable cups

# Enable mDNS-based network printer discovery
sudo pacman -S --noconfirm --needed nss-mdns avahi
sudo systemctl enable avahi-daemon

# Patch /etc/nsswitch.conf to enable mDNS resolution
if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
    sudo sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf
fi

echo "✔ CUPS printing enabled — open http://localhost:631 to add printers"
echo "✔ Network printer discovery (Avahi/mDNS) enabled"

# ============================================================
# Touchpad Gestures (libinput-gestures)
# ============================================================
echo "== Setting up touchpad gestures =="

sudo pacman -S --noconfirm --needed libinput wmctrl xdotool

# libinput-gestures is AUR — use paru if available, else build manually
if command -v paru &>/dev/null; then
    paru -S --noconfirm libinput-gestures
else
    git clone https://github.com/bulletmark/libinput-gestures.git /tmp/libinput-gestures
    cd /tmp/libinput-gestures
    sudo make install
    cd /
    rm -rf /tmp/libinput-gestures
fi

# Add current user to the input group (required for reading gesture events)
sudo gpasswd -a "$USER" input

# Default gesture config: 3-finger swipe for workspace switching,
# pinch for zoom — sensible defaults that work on KDE and Hyprland
mkdir -p "$HOME/.config"
cat > "$HOME/.config/libinput-gestures.conf" << 'EOF'
# SkywareOS default touch gestures

# 3-finger swipe left/right  → switch workspaces
gesture swipe left  3  xdotool key super+Right
gesture swipe right 3  xdotool key super+Left

# 3-finger swipe up/down  → show desktop overview / hide
gesture swipe up    3  xdotool key super+s
gesture swipe down  3  xdotool key super+s

# 4-finger swipe up  → show all windows
gesture swipe up    4  xdotool key super+w

# Pinch in/out  → zoom
gesture pinch in    2  xdotool key super+minus
gesture pinch out   2  xdotool key super+equal
EOF

# Autostart libinput-gestures on login
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/libinput-gestures.desktop" << 'EOF'
[Desktop Entry]
Name=libinput-gestures
Exec=libinput-gestures-setup start
Type=Application
X-GNOME-Autostart-enabled=true
EOF

libinput-gestures-setup autostart start 2>/dev/null || true
echo "✔ Touchpad gestures configured (3-finger swipe, pinch zoom)"

# ============================================================
# Timezone + Locale Auto-Detection
# ============================================================
echo "== Configuring timezone and locale =="

# Auto-detect timezone via IP geolocation (no account needed)
DETECTED_TZ=$(curl -s --max-time 5 "https://ipapi.co/timezone" 2>/dev/null || echo "")

if [ -n "$DETECTED_TZ" ] && timedatectl list-timezones | grep -qx "$DETECTED_TZ"; then
    sudo timedatectl set-timezone "$DETECTED_TZ"
    echo "✔ Timezone auto-set to: $DETECTED_TZ"
else
    echo "⚠ Could not auto-detect timezone — falling back to UTC"
    sudo timedatectl set-timezone UTC
fi

# Enable NTP sync
sudo timedatectl set-ntp true
echo "✔ NTP time sync enabled"

# Set locale to en_US.UTF-8 (uncomment if not already set)
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen >/dev/null
fi
sudo locale-gen
if [ ! -f /etc/locale.conf ] || ! grep -q "LANG=" /etc/locale.conf; then
    echo "LANG=en_US.UTF-8" | sudo tee /etc/locale.conf >/dev/null
fi

echo "✔ Locale set to en_US.UTF-8"

# ============================================================
# Docker / Podman
# ============================================================
echo "== Setting up Docker and Podman =="

sudo pacman -S --noconfirm --needed docker podman docker-compose podman-compose \
    docker-buildx

sudo systemctl enable docker

# Add current user to docker group so sudo isn't needed
sudo gpasswd -a "$USER" docker

# Configure Docker daemon — use systemd cgroups, enable live restore
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "journald",
  "live-restore": true,
  "userland-proxy": false
}
EOF

# Podman rootless setup for the current user
sudo pacman -S --noconfirm --needed fuse-overlayfs slirp4netns
echo "✔ Docker + Podman installed"
echo "  → Log out and back in for docker group to take effect"

# ============================================================
# ProtonVPN / Mullvad VPN Integration
# ============================================================
echo "== Setting up VPN support =="

# Install NetworkManager VPN plugins (works with both ProtonVPN and Mullvad)
sudo pacman -S --noconfirm --needed \
    networkmanager-openvpn \
    networkmanager-wireguard \
    wireguard-tools \
    openvpn \
    network-manager-applet

# ProtonVPN CLI (AUR)
if command -v paru &>/dev/null; then
    paru -S --noconfirm protonvpn-cli 2>/dev/null || \
        echo "⚠ protonvpn-cli not available — install manually from AUR"
fi

# Mullvad (official deb/rpm not on AUR, but WireGuard config import works)
echo ""
echo "  VPN setup:"
echo "  → ProtonVPN: run 'protonvpn-cli login' after install"
echo "  → Mullvad:   download WireGuard config from mullvad.net,"
echo "               then import via: nmcli connection import type wireguard file <config.conf>"

echo "✔ VPN support installed (OpenVPN + WireGuard + ProtonVPN CLI)"

# ============================================================
# Dotfiles Backup (auto git)
# ============================================================
echo "== Setting up automatic dotfiles backup =="

DOTFILES_DIR="$HOME/.dotfiles"
mkdir -p "$DOTFILES_DIR"

# Init a bare git repo for dotfiles tracking (the bare repo method)
if [ ! -d "$DOTFILES_DIR/.git" ] && [ ! -f "$DOTFILES_DIR/HEAD" ]; then
    git init --bare "$DOTFILES_DIR" 2>/dev/null || git init "$DOTFILES_DIR"
fi

# Wrapper alias that uses the dotfiles repo
DOTFILES_CMD="git --git-dir=$DOTFILES_DIR --work-tree=$HOME"

# Add to zshrc if not already there
if ! grep -q "alias dotfiles=" "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" << 'EOF'

# Dotfiles management
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
EOF
fi

# Track key config files
$DOTFILES_CMD config status.showUntrackedFiles no 2>/dev/null || true
for f in \
    "$HOME/.zshrc" \
    "$HOME/.config/starship.toml" \
    "$HOME/.config/btop/btop.conf" \
    "$HOME/.config/fastfetch/config.jsonc" \
    "$HOME/.config/libinput-gestures.conf"; do
    [ -f "$f" ] && $DOTFILES_CMD add "$f" 2>/dev/null || true
done

$DOTFILES_CMD commit -m "SkywareOS initial dotfiles snapshot" 2>/dev/null || true

# Install systemd timer to auto-commit dotfile changes daily
sudo tee /etc/systemd/user/dotfiles-backup.service > /dev/null << SVCEOF
[Unit]
Description=SkywareOS Dotfiles Auto-Backup

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'git --git-dir=%h/.dotfiles --work-tree=%h add -u && git --git-dir=%h/.dotfiles --work-tree=%h commit -m "auto: $(date +%%Y-%%m-%%d)" 2>/dev/null || true'
SVCEOF

sudo tee /etc/systemd/user/dotfiles-backup.timer > /dev/null << 'EOF'
[Unit]
Description=Daily Dotfiles Backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=default.target
EOF

systemctl --user enable dotfiles-backup.timer 2>/dev/null || true
echo "✔ Dotfiles repo initialized at ~/.dotfiles"
echo "  → Use 'dotfiles add <file>' to track new files"
echo "  → Use 'dotfiles push' to sync to a remote (add with: dotfiles remote add origin <url>)"

# ============================================================
# TLP Battery Health Auto-Tune
# ============================================================
echo "== Setting up TLP battery health daemon =="

sudo pacman -S --noconfirm --needed tlp tlp-rdw ethtool smartmontools

sudo systemctl enable tlp
sudo systemctl enable NetworkManager-dispatcher

# Disable conflicting power services
sudo systemctl disable power-profiles-daemon 2>/dev/null || true
sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true

# Write a tuned TLP config optimized for battery health
sudo tee /etc/tlp.conf > /dev/null << 'EOF'
# SkywareOS TLP Battery Config

TLP_ENABLE=1
TLP_DEFAULT_MODE=AC

# CPU scaling — balanced by default
CPU_SCALING_GOVERNOR_ON_AC=schedutil
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power

# Charge thresholds — keeps battery between 20-80% for longevity
# (supported on ThinkPads and some ASUS/Dell laptops)
START_CHARGE_THRESH_BAT0=20
STOP_CHARGE_THRESH_BAT0=80

# PCIe ASPM — power saving on battery
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# USB autosuspend
USB_AUTOSUSPEND=1
USB_EXCLUDE_AUDIO=1
USB_EXCLUDE_BTUSB=1

# Disk APM — balanced
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"

# WiFi power save on battery
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# Disable NMI watchdog on battery (saves ~0.5W)
NMI_WATCHDOG=0

# Runtime power management
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
EOF

echo "✔ TLP configured with battery health thresholds (charge 20–80%)"
echo "  → Run 'tlp-stat' to see current power stats"
echo "  → Charge thresholds apply to supported laptops (ThinkPad, ASUS, some Dell)"



# ============================================================
# KDE Global Theme + Color Scheme
# ============================================================
echo "== Applying SkywareOS KDE theme =="

if pacman -Q plasma-desktop &>/dev/null; then
    # Install Lightly theme (clean, modern KDE theme from AUR)
    if command -v paru &>/dev/null; then
        paru -S --noconfirm lightly-git 2>/dev/null || true
    fi

    # Apply color scheme — write a custom Skyware dark gray palette
    mkdir -p "$HOME/.local/share/color-schemes"
    cat > "$HOME/.local/share/color-schemes/SkywareOS.colors" << 'EOF'
[ColorEffects:Disabled]
Color=56,56,56
ColorAmount=0
ColorEffect=0
ContrastAmount=0.65
ContrastEffect=1
IntensityAmount=0.1
IntensityEffect=2

[ColorEffects:Inactive]
ChangeSelectionColor=true
Color=112,111,110
ColorAmount=0.025
ColorEffect=2
ContrastAmount=0.1
ContrastEffect=2
Enable=false
IntensityAmount=0
IntensityEffect=0

[Colors:Button]
BackgroundAlternate=30,30,34
BackgroundNormal=31,31,35
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=122,122,138
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[Colors:Complementary]
BackgroundAlternate=14,14,16
BackgroundNormal=17,17,19
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=74,74,88
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[Colors:Header]
BackgroundAlternate=12,12,14
BackgroundNormal=14,14,16
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=74,74,88
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[Colors:Selection]
BackgroundAlternate=31,31,35
BackgroundNormal=42,42,50
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=122,122,138
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[Colors:Tooltip]
BackgroundAlternate=17,17,19
BackgroundNormal=24,24,27
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=74,74,88
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[Colors:View]
BackgroundAlternate=17,17,19
BackgroundNormal=14,14,16
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=74,74,88
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[Colors:Window]
BackgroundAlternate=17,17,19
BackgroundNormal=17,17,19
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundActive=200,200,220
ForegroundInactive=74,74,88
ForegroundLink=96,165,250
ForegroundNegative=248,113,113
ForegroundNeutral=250,204,21
ForegroundNormal=226,226,236
ForegroundPositive=74,222,128
ForegroundVisited=167,139,250

[General]
ColorScheme=SkywareOS
Name=SkywareOS
shadeSortColumn=true

[KDE]
contrast=4

[WM]
activeBackground=17,17,19
activeBlend=17,17,19
activeForeground=226,226,236
inactiveBackground=14,14,16
inactiveBlend=14,14,16
inactiveForeground=74,74,88
EOF

    # Apply the color scheme and window decoration via kconfig
    kwriteconfig6 --file kdeglobals --group General \
        --key ColorScheme "SkywareOS" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 \
        --key theme "org.kde.breeze" 2>/dev/null || true
    kwriteconfig6 --file kdeglobals --group KDE \
        --key widgetStyle "Breeze" 2>/dev/null || true

    # Set Plasma panel to dark
    kwriteconfig6 --file plasmarc --group Theme \
        --key name "breeze-dark" 2>/dev/null || true

    echo "✔ SkywareOS KDE color scheme applied"
else
    echo "→ KDE not installed, skipping theme application"
fi

# ============================================================
# Custom Cursor Theme (Bibata Modern Classic — clean, modern)
# ============================================================
echo "== Installing cursor theme =="

if command -v paru &>/dev/null; then
    paru -S --noconfirm bibata-cursor-theme 2>/dev/null || \
        echo "⚠ bibata-cursor-theme not found in AUR, skipping"
else
    # Fallback: download directly from GitHub releases
    BIBATA_URL="https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/Bibata-Modern-Classic.tar.xz"
    curl -L "$BIBATA_URL" -o /tmp/bibata.tar.xz 2>/dev/null && \
        sudo tar -xf /tmp/bibata.tar.xz -C /usr/share/icons/ && \
        rm /tmp/bibata.tar.xz && \
        echo "✔ Bibata cursor theme installed" || \
        echo "⚠ Could not download cursor theme"
fi

# Apply system-wide
sudo mkdir -p /usr/share/icons/default
sudo tee /usr/share/icons/default/index.theme > /dev/null << 'EOF'
[Icon Theme]
Inherits=Bibata-Modern-Classic
EOF

# Apply per-user
mkdir -p "$HOME/.icons/default"
cat > "$HOME/.icons/default/index.theme" << 'EOF'
[Icon Theme]
Inherits=Bibata-Modern-Classic
EOF

# Apply in KDE
kwriteconfig6 --file kcminputrc --group Mouse \
    --key cursorTheme "Bibata-Modern-Classic" 2>/dev/null || true
kwriteconfig6 --file kcminputrc --group Mouse \
    --key cursorSize "24" 2>/dev/null || true

echo "✔ Cursor theme set to Bibata Modern Classic"

# ============================================================
# Custom MOTD — Skyware ASCII + live stats on SSH/TTY login
# ============================================================
echo "== Setting up SkywareOS MOTD =="

sudo pacman -S --noconfirm --needed figlet lolcat 2>/dev/null || true

sudo tee /etc/profile.d/skyware-motd.sh > /dev/null << 'MOTDEOF'
#!/bin/bash
# Only show on interactive login shells, not in scripts
[[ $- != *i* ]] && return
[[ -n "$MOTD_SHOWN" ]] && return
export MOTD_SHOWN=1

# Colors
GRAY="\e[38;5;245m"
LGRAY="\e[38;5;250m"
WHITE="\e[97m"
GREEN="\e[92m"
YELLOW="\e[93m"
RED="\e[91m"
BLUE="\e[94m"
RESET="\e[0m"
BOLD="\e[1m"

echo ""
echo -e "${GRAY}      @@@@@@@-         +@@@@@@.     ${RESET}"
echo -e "${GRAY}    %@@@@@@@@@@=      @@@@@@@@@@    ${RESET}    ${BOLD}${WHITE}SkywareOS${RESET} ${GRAY}Red 0.7${RESET}"
echo -e "${GRAY}   @@@@     @@@@@      -     #@@@   ${RESET}    ${LGRAY}────────────────────────────${RESET}"
echo -e "${GRAY}  :@@*        @@@@             @@@  ${RESET}    ${GRAY}Kernel  ${RESET}$(uname -r)"
echo -e "${GRAY}  @@@          @@@@            @@@  ${RESET}    ${GRAY}Uptime  ${RESET}$(uptime -p | sed 's/up //')"
echo -e "${GRAY}  @@@           @@@@           %@@  ${RESET}    ${GRAY}Shell   ${RESET}zsh $(zsh --version | cut -d' ' -f2)"
echo -e "${GRAY}  @@@            @@@@          @@@  ${RESET}    ${GRAY}Pkgs    ${RESET}$(pacman -Q 2>/dev/null | wc -l) (pacman)"
echo -e "${GRAY}  :@@@            @@@@:        @@@  ${RESET}    ${GRAY}Memory  ${RESET}$(free -h | awk '/Mem:/{print $3"/"$2}')"
echo -e "${GRAY}   @@@@     =      @@@@@     %@@@   ${RESET}    ${GRAY}Disk    ${RESET}$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
echo -e "${GRAY}    @@@@@@@@@@       @@@@@@@@@@@    ${RESET}"
echo -e "${GRAY}      @@@@@@+          %@@@@@@      ${RESET}"
echo ""

# Update notification
UPDATES=$(checkupdates 2>/dev/null | wc -l)
if [ "$UPDATES" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠${RESET}  ${YELLOW}${UPDATES} update(s) available${RESET} — run ${GRAY}ware update${RESET} to install"
    echo ""
fi

# Firewall status
if ! systemctl is-active ufw >/dev/null 2>&1; then
    echo -e "  ${RED}✖${RESET}  ${RED}Firewall is not running${RESET} — run ${GRAY}sudo ufw enable${RESET}"
    echo ""
fi
MOTDEOF

sudo chmod +x /etc/profile.d/skyware-motd.sh

# Disable the default Arch MOTD
sudo rm -f /etc/motd
echo "✔ SkywareOS MOTD installed (shows on login)"

# ============================================================
# Tmux — Skyware theme
# ============================================================
echo "== Setting up tmux =="

sudo pacman -S --noconfirm --needed tmux

cat > "$HOME/.tmux.conf" << 'EOF'
# ── SkywareOS tmux config ─────────────────────────────────────

# Remap prefix to Ctrl+Space
unbind C-b
set -g prefix C-Space
bind C-Space send-prefix

# Quality of life
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 0
set -g focus-events on
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"

# ── Status bar ────────────────────────────────────────────────
set -g status on
set -g status-position bottom
set -g status-interval 5
set -g status-style "bg=#0e0e10,fg=#a0a0b0"

set -g status-left-length 40
set -g status-left "#[bg=#1f1f23,fg=#c8c8dc,bold]  SkywareOS #[bg=#0e0e10,fg=#2a2a2f]#[default] "

set -g status-right-length 80
set -g status-right "#[fg=#4a4a58]  #[fg=#7a7a8a]%H:%M  #[fg=#4a4a58]  #[fg=#7a7a8a]%d %b  #[fg=#4a4a58]  #[fg=#7a7a8a]#H "

# Active window tab
setw -g window-status-current-format "#[bg=#1f1f23,fg=#c8c8dc,bold] #I #W #[default]"
setw -g window-status-format         "#[fg=#4a4a58] #I #W "
setw -g window-status-separator ""

# Pane borders
set -g pane-border-style        "fg=#2a2a2f"
set -g pane-active-border-style "fg=#a0a0b0"

# ── Splits ────────────────────────────────────────────────────
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Vim-style pane navigation
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R

# Resize panes
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

# Reload config
bind r source-file ~/.tmux.conf \; display "Config reloaded"
EOF

echo "✔ Tmux configured with Skyware theme"
echo "  → Prefix: Ctrl+Space  |  Split: prefix + | or -  |  Nav: prefix + h/j/k/l"

# ============================================================
# Custom Pacman progress bar
# ============================================================
echo "== Customizing pacman =="

sudo cp /etc/pacman.conf /etc/pacman.conf.bak

# Enable Color, VerbosePkgLists, ILoveCandy (pacman easter egg bar),
# and parallel downloads
sudo python3 << 'PYEOF'
with open("/etc/pacman.conf", "r") as f:
    content = f.read()

replacements = {
    "#Color":             "Color",
    "#VerbosePkgLists":   "VerbosePkgLists",
    "#ILoveCandy":        "ILoveCandy",
    "#ParallelDownloads": "ParallelDownloads",
    "ParallelDownloads = 5": "ParallelDownloads = 10",
}

for old, new in replacements.items():
    content = content.replace(old, new)

with open("/etc/pacman.conf", "w") as f:
    f.write(content)

print("✔ Pacman: Color + ILoveCandy Pac-Man progress bar + 10 parallel downloads enabled")
PYEOF

# ============================================================
# GameMode + MangoHud
# ============================================================
echo "== Setting up gaming performance tools =="

sudo pacman -S --noconfirm --needed gamemode lib32-gamemode mangohud lib32-mangohud

# Add user to gamemode group
sudo gpasswd -a "$USER" gamemode 2>/dev/null || true

# MangoHud global config — clean minimal overlay
mkdir -p "$HOME/.config/MangoHud"
cat > "$HOME/.config/MangoHud/MangoHud.conf" << 'EOF'
# SkywareOS MangoHud config

# Layout
legacy_layout=false
hud_compact=false
background_alpha=0.4
font_size=20
round_corners=8
offset_x=12
offset_y=12
position=top-left

# Color scheme (matches SkywareOS gray palette)
background_color=111113
text_color=e2e2ec
gpu_color=a0a0b0
cpu_color=c8c8dc
vram_color=60a5fa
ram_color=7a7a8a
fps_color_change=1
fps_value=30,60
fps_color=f87171,facc15,4ade80
frame_timing_color=a78bfa

# What to show
fps=1
frame_timing=1
cpu_stats=1
cpu_temp=1
gpu_stats=1
gpu_temp=1
vram=1
ram=1
time=1
time_format=%H:%M

# Triggered with Shift+F12
toggle_hud=Shift_F12
EOF

echo "✔ GameMode installed — prefix game launch with: gamemoderun %command%"
echo "✔ MangoHud installed — toggle overlay with Shift+F12"
echo "  → For Steam: add 'MANGOHUD=1 gamemoderun %command%' to launch options"

# ============================================================
# Proton / Wine for Windows games
# ============================================================
echo "== Setting up Proton/Wine =="

# Enable multilib repo if not already enabled
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf >/dev/null
    sudo pacman -Sy
fi

sudo pacman -S --noconfirm --needed \
    wine wine-mono wine-gecko winetricks \
    lib32-vulkan-icd-loader vulkan-icd-loader \
    lib32-mesa mesa \
    giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap \
    gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal \
    v4l-utils lib32-v4l-utils libpulse lib32-libpulse alsa-plugins \
    lib32-alsa-plugins alsa-lib lib32-alsa-lib libjpeg-turbo \
    lib32-libjpeg-turbo sqlite lib32-sqlite libxcomposite lib32-libxcomposite

# Proton-GE (better Proton build for non-Steam games) via AUR
if command -v paru &>/dev/null; then
    paru -S --noconfirm proton-ge-custom-bin 2>/dev/null || \
        echo "⚠ proton-ge-custom-bin not found, install manually"
fi

# Lutris for game library management
sudo pacman -S --noconfirm --needed lutris

echo "✔ Wine + Winetricks installed"
echo "✔ Lutris installed (open Lutris to install Windows games)"
echo "✔ Proton-GE installed (Steam → Settings → Compatibility → Proton-GE)"

# ============================================================
# ware doctor — AI repair mode (Claude API)
# ============================================================
echo "== Adding AI repair to ware doctor =="

# Patch the ware doctor function to optionally query Claude API
# when it finds issues. The user provides their API key via
# ANTHROPIC_API_KEY env var or ~/.config/skyware/api_key

sudo tee /usr/local/bin/ware-ai-doctor > /dev/null << 'EOF'
#!/bin/bash
# SkywareOS AI Doctor — sends system errors to Claude for fix suggestions
# Usage: ware-ai-doctor   (run after ware doctor finds issues)

RED="\e[31m"; CYAN="\e[36m"; GREEN="\e[32m"; YELLOW="\e[33m"; RESET="\e[0m"

KEY_FILE="$HOME/.config/skyware/api_key"
API_KEY="${ANTHROPIC_API_KEY:-}"

if [ -z "$API_KEY" ] && [ -f "$KEY_FILE" ]; then
    API_KEY=$(cat "$KEY_FILE")
fi

if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}→ No Anthropic API key found.${RESET}"
    echo -e "  Set it with: mkdir -p ~/.config/skyware && echo 'sk-ant-...' > ~/.config/skyware/api_key"
    echo -e "  Or export ANTHROPIC_API_KEY=sk-ant-..."
    exit 1
fi

echo -e "${CYAN}== SkywareOS AI Doctor ==${RESET}"
echo -e "${CYAN}→ Collecting system diagnostics...${RESET}"

# Gather context
ERRORS=$(sudo journalctl -p err -b --no-pager -n 30 2>/dev/null)
FAILED=$(systemctl --failed --no-legend 2>/dev/null)
PACMAN_LOG=$(tail -n 20 /var/log/pacman.log 2>/dev/null)
OS_INFO="SkywareOS Red 0.7 (Arch-based), kernel $(uname -r)"

PROMPT="You are a Linux system repair assistant for SkywareOS (an Arch-based distro). \
Analyze these system diagnostics and provide specific, actionable fix commands. \
Be concise — list the issues found and the exact commands to fix them. \
Do not explain basics. Format: issue → fix command.

OS: $OS_INFO

Recent journal errors:
$ERRORS

Failed systemd units:
$FAILED

Recent pacman log:
$PACMAN_LOG"

echo -e "${CYAN}→ Querying Claude for diagnosis...${RESET}"
echo ""

RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: $API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "{
        \"model\": \"claude-sonnet-4-20250514\",
        \"max_tokens\": 1024,
        \"messages\": [{\"role\": \"user\", \"content\": $(echo "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}]
    }" 2>/dev/null)

# Extract text from response
RESULT=$(echo "$RESPONSE" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data['content'][0]['text'])
except:
    print('Could not parse API response. Check your API key.')
" 2>/dev/null)

echo -e "${GREEN}── AI Diagnosis ─────────────────────────────${RESET}"
echo "$RESULT"
echo -e "${GREEN}─────────────────────────────────────────────${RESET}"
EOF

sudo chmod +x /usr/local/bin/ware-ai-doctor

# Patch ware to call ware-ai-doctor at end of doctor subcommand
sudo sed -i "s|echo -e \"\${GREEN}Diagnostics complete.\${RESET}\"|echo -e \"\${GREEN}Diagnostics complete.\${RESET}\"\n    echo \"\"\n    read -rp \"→ Run AI repair suggestions? (requires Anthropic API key) [y/N] \" ai_choice\n    [[ \"\$ai_choice\" =~ ^[Yy]$ ]] \&\& ware-ai-doctor|" \
    /usr/local/bin/ware 2>/dev/null || true

echo "✔ AI Doctor installed at /usr/local/bin/ware-ai-doctor"
echo "  → Run: ware doctor  (then choose AI repair)"
echo "  → Or directly: ware-ai-doctor"
echo "  → Set API key: echo 'sk-ant-...' > ~/.config/skyware/api_key"

# ============================================================
# SkywareOS Welcome App (first-boot wizard)
# ============================================================
echo "== Installing SkywareOS Welcome App =="

sudo mkdir -p /opt/skyware-welcome/src

sudo tee /opt/skyware-welcome/package.json > /dev/null << 'EOF'
{
  "name": "skyware-welcome",
  "version": "0.7.0",
  "description": "SkywareOS First Boot Welcome",
  "main": "main.js",
  "scripts": { "start": "electron .", "build": "vite build" },
  "dependencies": { "react": "^18.2.0", "react-dom": "^18.2.0" },
  "devDependencies": { "electron": "^30.0.0", "@vitejs/plugin-react": "^4.0.0", "vite": "^5.0.0" }
}
EOF

sudo tee /opt/skyware-welcome/main.js > /dev/null << 'EOF'
const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');
const fs = require('fs');

const DONE_FLAG = path.join(require('os').homedir(), '.config/skyware/welcome-done');

function createWindow() {
  // Skip if already completed
  if (fs.existsSync(DONE_FLAG)) { app.quit(); return; }

  const win = new BrowserWindow({
    width: 760, height: 540,
    frame: false, center: true,
    backgroundColor: '#111113', resizable: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
    title: 'Welcome to SkywareOS',
  });
  win.loadFile(path.join(__dirname, 'dist', 'index.html'));
}

ipcMain.on('finish',    () => { fs.mkdirSync(path.dirname(DONE_FLAG), { recursive: true }); fs.writeFileSync(DONE_FLAG, ''); app.quit(); });
ipcMain.on('open-link', (_, url) => shell.openExternal(url));
ipcMain.on('win-close', (e) => BrowserWindow.fromWebContents(e.sender).close());

app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
EOF

sudo tee /opt/skyware-welcome/preload.js > /dev/null << 'EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('welcome', {
  finish:   ()    => ipcRenderer.send('finish'),
  openLink: (url) => ipcRenderer.send('open-link', url),
  close:    ()    => ipcRenderer.send('win-close'),
});
EOF

sudo tee /opt/skyware-welcome/vite.config.js > /dev/null << 'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], base: './', build: { outDir: 'dist' } });
EOF

sudo tee /opt/skyware-welcome/index.html > /dev/null << 'EOF'
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8"/>
    <title>Welcome to SkywareOS</title>
    <style>* { margin:0; padding:0; box-sizing:border-box; } body { overflow:hidden; background:#111113; } #root { height:100vh; }</style>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.jsx"></script>
  </body>
</html>
EOF

sudo tee /opt/skyware-welcome/src/main.jsx > /dev/null << 'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
createRoot(document.getElementById('root')).render(<App />);
EOF

sudo tee /opt/skyware-welcome/src/App.jsx > /dev/null << 'APPEOF'
import { useState } from "react";

const C = {
  bg:"#111113", card:"#18181b", border:"#2a2a2f", accent:"#a0a0b0",
  accentHi:"#c8c8dc", text:"#e2e2ec", dim:"#7a7a8a", muted:"#4a4a58",
  green:"#4ade80", blue:"#60a5fa", yellow:"#facc15",
};

const STEPS = [
  { id:"welcome",  label:"Welcome"  },
  { id:"features", label:"Features" },
  { id:"tools",    label:"Tools"    },
  { id:"done",     label:"Done"     },
];

const FEATURES = [
  { icon:"⬡", title:"ware",         desc:"Unified package manager — wraps pacman, flatpak, and AUR in one command." },
  { icon:"⚙", title:"Settings App", desc:"GUI control panel for all ware commands. Launch with: skyware-settings" },
  { icon:"⚡", title:"GameMode",     desc:"Auto-boosts CPU/GPU when a game launches. Add gamemoderun to Steam." },
  { icon:"◈", title:"AI Doctor",    desc:"ware doctor can query Claude API to diagnose and fix system issues." },
  { icon:"🔒", title:"AppArmor",    desc:"Mandatory access control enabled by default for extra security." },
  { icon:"◉", title:"Environments", desc:"Install Hyprland, Niri, or MangoWC with a single ware setup command." },
];

const LINKS = [
  { label:"GitHub",        url:"https://github.com/SkywareSW/SkywareOS"       },
  { label:"Website",       url:"https://skywaresw.github.io/SkywareOS"        },
  { label:"ware help",     url:null, cmd:"ware help"                           },
];

export default function App() {
  const [step, setStep] = useState(0);
  const current = STEPS[step];

  const next = () => step < STEPS.length - 1 ? setStep(step + 1) : window.welcome?.finish();
  const prev = () => setStep(step - 1);

  return (
    <div style={{height:"100vh",background:C.bg,fontFamily:"'Segoe UI','SF Pro Display',system-ui,sans-serif",color:C.text,display:"flex",flexDirection:"column",overflow:"hidden"}}>

      {/* Title bar */}
      <div style={{height:"44px",background:"#0c0c0e",borderBottom:`1px solid ${C.border}`,display:"flex",alignItems:"center",justifyContent:"space-between",padding:"0 16px",WebkitAppRegion:"drag",flexShrink:0}}>
        <div style={{display:"flex",alignItems:"center",gap:"8px"}}>
          <div style={{width:"20px",height:"20px",borderRadius:"4px",background:`linear-gradient(135deg,${C.accent},#505060)`,display:"flex",alignItems:"center",justifyContent:"center",fontSize:"11px",fontWeight:900,color:"#fff"}}>S</div>
          <span style={{fontSize:"13px",fontWeight:600}}>Welcome to SkywareOS</span>
        </div>
        <button onClick={()=>window.welcome?.close()} style={{WebkitAppRegion:"no-drag",background:"none",border:"none",color:C.muted,cursor:"pointer",fontSize:"16px"}}>×</button>
      </div>

      {/* Step indicators */}
      <div style={{display:"flex",justifyContent:"center",gap:"8px",padding:"20px 0 0",flexShrink:0}}>
        {STEPS.map((s,i)=>(
          <div key={s.id} style={{display:"flex",alignItems:"center",gap:"8px"}}>
            <div style={{width:"24px",height:"24px",borderRadius:"50%",background:i<=step?C.accent:"transparent",border:`1px solid ${i<=step?C.accent:C.border}`,display:"flex",alignItems:"center",justifyContent:"center",fontSize:"11px",color:i<=step?"#111":C.muted,fontWeight:600,transition:"all 0.2s"}}>{i+1}</div>
            {i<STEPS.length-1&&<div style={{width:"32px",height:"1px",background:i<step?C.accent:C.border,transition:"all 0.2s"}}/>}
          </div>
        ))}
      </div>

      {/* Content */}
      <div style={{flex:1,padding:"28px 40px",overflowY:"auto"}}>

        {current.id==="welcome"&&(
          <div style={{textAlign:"center",paddingTop:"8px"}}>
            <div style={{fontSize:"48px",marginBottom:"16px"}}>
              {`      @@@@@\n    @@@@@@@@@\n   @@@     @@@\n  @@@       @@@\n  @@@       @@@\n   @@@     @@@\n    @@@@@@@@@\n      @@@@@`}
            </div>
            <div style={{fontFamily:"monospace",fontSize:"11px",color:C.muted,lineHeight:1.6,marginBottom:"20px",whiteSpace:"pre"}}{...{}}>
{`      @@@@@@@-         +@@@@@@.
    %@@@@@@@@@@=      @@@@@@@@@@
   @@@@     @@@@@      -     #@@@
  :@@*        @@@@             @@@
  @@@          @@@@            @@@
  @@@           @@@@           %@@
  @@@            @@@@          @@@
   @@@@     =      @@@@@     %@@@
    @@@@@@@@@@       @@@@@@@@@@@
      @@@@@@+          %@@@@@@`}
            </div>
            <h1 style={{fontSize:"28px",fontWeight:700,marginBottom:"8px",letterSpacing:"-0.03em"}}>Welcome to <span style={{color:C.accentHi}}>SkywareOS</span></h1>
            <p style={{color:C.dim,fontSize:"14px",lineHeight:1.6,maxWidth:"400px",margin:"0 auto"}}>An Arch-based Linux distro built for performance, customization, and a clean out-of-the-box experience.</p>
          </div>
        )}

        {current.id==="features"&&(
          <div>
            <h2 style={{fontSize:"18px",fontWeight:600,marginBottom:"6px"}}>What's included</h2>
            <p style={{color:C.dim,fontSize:"13px",marginBottom:"20px"}}>Everything set up and ready to go.</p>
            <div style={{display:"grid",gridTemplateColumns:"repeat(2,1fr)",gap:"10px"}}>
              {FEATURES.map(f=>(
                <div key={f.title} style={{background:C.card,border:`1px solid ${C.border}`,borderRadius:"8px",padding:"14px 16px",display:"flex",gap:"12px",alignItems:"flex-start"}}>
                  <span style={{fontSize:"20px",flexShrink:0}}>{f.icon}</span>
                  <div>
                    <div style={{fontWeight:600,fontSize:"13px",marginBottom:"3px"}}>{f.title}</div>
                    <div style={{color:C.dim,fontSize:"12px",lineHeight:1.5}}>{f.desc}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {current.id==="tools"&&(
          <div>
            <h2 style={{fontSize:"18px",fontWeight:600,marginBottom:"6px"}}>Useful links</h2>
            <p style={{color:C.dim,fontSize:"13px",marginBottom:"20px"}}>Get started with SkywareOS.</p>
            <div style={{display:"flex",flexDirection:"column",gap:"8px"}}>
              {LINKS.map(l=>(
                <div key={l.label} style={{background:C.card,border:`1px solid ${C.border}`,borderRadius:"8px",padding:"12px 16px",display:"flex",justifyContent:"space-between",alignItems:"center"}}>
                  <span style={{fontSize:"13px",color:C.text}}>{l.label}</span>
                  {l.url
                    ? <button onClick={()=>window.welcome?.openLink(l.url)} style={{background:"transparent",border:`1px solid ${C.border}`,color:C.accentHi,borderRadius:"5px",padding:"5px 12px",cursor:"pointer",fontSize:"12px",fontFamily:"inherit"}}>Open</button>
                    : <span style={{fontFamily:"monospace",fontSize:"12px",color:C.muted}}>{l.cmd}</span>
                  }
                </div>
              ))}
            </div>
          </div>
        )}

        {current.id==="done"&&(
          <div style={{textAlign:"center",paddingTop:"20px"}}>
            <div style={{fontSize:"48px",marginBottom:"16px"}}>✔</div>
            <h2 style={{fontSize:"22px",fontWeight:700,marginBottom:"8px",color:C.green}}>You're all set</h2>
            <p style={{color:C.dim,fontSize:"14px",lineHeight:1.6,maxWidth:"360px",margin:"0 auto 24px"}}>SkywareOS is ready. Open the Settings app anytime with <span style={{color:C.accentHi,fontFamily:"monospace"}}>skyware-settings</span> or find it in your app launcher.</p>
            <div style={{background:C.card,border:`1px solid ${C.border}`,borderRadius:"8px",padding:"14px 20px",display:"inline-block",textAlign:"left"}}>
              <div style={{fontFamily:"monospace",fontSize:"12px",color:C.dim,lineHeight:2}}>
                <div><span style={{color:C.accent}}>$</span> ware help</div>
                <div><span style={{color:C.accent}}>$</span> ware install &lt;pkg&gt;</div>
                <div><span style={{color:C.accent}}>$</span> ware settings</div>
                <div><span style={{color:C.accent}}>$</span> ware doctor</div>
              </div>
            </div>
          </div>
        )}
      </div>

      {/* Nav buttons */}
      <div style={{padding:"16px 40px",borderTop:`1px solid ${C.border}`,display:"flex",justifyContent:"space-between",flexShrink:0,background:"#0c0c0e"}}>
        <button onClick={prev} disabled={step===0}
          style={{background:"transparent",border:`1px solid ${C.border}`,color:step===0?C.muted:C.text,borderRadius:"7px",padding:"9px 20px",cursor:step===0?"not-allowed":"pointer",fontSize:"13px",fontFamily:"inherit",opacity:step===0?0.4:1}}>
          ← Back
        </button>
        <button onClick={next}
          style={{background:C.accentHi,border:"none",color:"#111",borderRadius:"7px",padding:"9px 24px",cursor:"pointer",fontSize:"13px",fontFamily:"inherit",fontWeight:600}}>
          {step===STEPS.length-1?"Get Started →":"Next →"}
        </button>
      </div>
    </div>
  );
}
APPEOF

# Build it
cd /opt/skyware-welcome
sudo npm install --silent 2>&1 | tail -2
sudo npx vite build --silent 2>&1 | tail -3

# Launcher
sudo tee /usr/local/bin/skyware-welcome > /dev/null << 'EOF'
#!/bin/bash
exec electron /opt/skyware-welcome "$@"
EOF
sudo chmod +x /usr/local/bin/skyware-welcome

# .desktop entry
sudo tee /usr/share/applications/skyware-welcome.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Welcome to SkywareOS
Comment=SkywareOS first-boot setup wizard
Exec=/usr/local/bin/skyware-welcome
Icon=dialog-information
Terminal=false
Type=Application
Categories=System;
NoDisplay=true
EOF

# Autostart on first login (removes itself after running once)
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/skyware-welcome.desktop" << 'EOF'
[Desktop Entry]
Name=SkywareOS Welcome
Exec=/usr/local/bin/skyware-welcome
Type=Application
X-GNOME-Autostart-enabled=true
EOF

echo "✔ Welcome app installed — will launch automatically on first login"

# ============================================================
# OTA update notification (system tray)
# ============================================================
echo "== Setting up OTA update notifier =="

sudo pacman -S --noconfirm --needed libnotify python-gobject gtk3

sudo tee /usr/local/bin/skyware-update-notifier > /dev/null << 'EOF'
#!/usr/bin/env python3
"""
SkywareOS Update Notifier
Runs as a systemd user timer, checks for updates and sends a desktop notification.
"""
import subprocess
import os
import sys

def count_updates():
    try:
        result = subprocess.run(
            ["checkupdates"], capture_output=True, text=True, timeout=30
        )
        pacman_updates = len([l for l in result.stdout.splitlines() if l.strip()])
    except Exception:
        pacman_updates = 0

    try:
        result = subprocess.run(
            ["flatpak", "remote-ls", "--updates"],
            capture_output=True, text=True, timeout=30
        )
        flatpak_updates = len([l for l in result.stdout.splitlines() if l.strip()])
    except Exception:
        flatpak_updates = 0

    return pacman_updates, flatpak_updates

def notify(pacman, flatpak):
    total = pacman + flatpak
    if total == 0:
        return

    parts = []
    if pacman > 0:
        parts.append(f"{pacman} pacman")
    if flatpak > 0:
        parts.append(f"{flatpak} flatpak")

    summary = f"SkywareOS: {total} update{'s' if total > 1 else ''} available"
    body = f"{', '.join(parts)} package{'s' if total > 1 else ''} can be updated.\nRun: ware update"

    subprocess.run([
        "notify-send",
        "--app-name=SkywareOS",
        "--icon=system-software-update",
        "--urgency=normal",
        "--expire-time=8000",
        summary,
        body,
    ])

if __name__ == "__main__":
    pacman, flatpak = count_updates()
    notify(pacman, flatpak)
    sys.exit(0)
EOF

sudo chmod +x /usr/local/bin/skyware-update-notifier

# systemd user timer — checks every 6 hours
mkdir -p "$HOME/.config/systemd/user"

cat > "$HOME/.config/systemd/user/skyware-updates.service" << 'EOF'
[Unit]
Description=SkywareOS Update Notifier

[Service]
Type=oneshot
ExecStart=/usr/local/bin/skyware-update-notifier
EOF

cat > "$HOME/.config/systemd/user/skyware-updates.timer" << 'EOF'
[Unit]
Description=SkywareOS Update Check (every 6 hours)

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=default.target
EOF

systemctl --user enable skyware-updates.timer 2>/dev/null || true
systemctl --user start  skyware-updates.timer 2>/dev/null || true

echo "✔ Update notifier installed — desktop notification every 6 hours when updates are available"



# ============================================================
# Auto-mount external drives (udiskie)
# ============================================================
echo "== Setting up auto-mount for external drives =="

sudo pacman -S --noconfirm --needed udiskie udisks2 gvfs

# Autostart udiskie with system tray icon (shows mount/unmount notifications)
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/udiskie.desktop" << 'EOF'
[Desktop Entry]
Name=udiskie
Comment=Automount removable media
Exec=udiskie --tray --notify --appindicator
Type=Application
X-GNOME-Autostart-enabled=true
EOF

# udiskie config — auto-mount, show notifications, use Dolphin to open
mkdir -p "$HOME/.config/udiskie"
cat > "$HOME/.config/udiskie/config.yml" << 'EOF'
program_options:
  tray: true
  notify: true
  automount: true
  appindicator: true

notifications:
  timeout: 4
  device_mounted: "  {device_presentation} mounted at {mount_path}"
  device_unmounted: "  {device_presentation} unmounted"
  device_added: "  {device_presentation} connected"
  device_removed: "  {device_presentation} removed"

device_config:
  - options:
      fstype: vfat
      options: uid={user},gid={group},utf8
EOF

# Start it immediately for the current session
udiskie --tray --notify --appindicator &>/dev/null &
disown

echo "✔ udiskie installed — external drives will auto-mount with tray icon"
echo "  → Config: ~/.config/udiskie/config.yml"

# ============================================================
# Fingerprint reader (fprint)
# ============================================================
echo "== Setting up fingerprint reader =="

sudo pacman -S --noconfirm --needed fprintd libfprint

# Enable fingerprint for sudo + login PAM
# Insert fingerprint auth into PAM stack — before password
for PAM_FILE in /etc/pam.d/sudo /etc/pam.d/login /etc/pam.d/sddm; do
    if [ -f "$PAM_FILE" ] && ! grep -q "pam_fprintd" "$PAM_FILE"; then
        # Insert fprintd line after the first 'auth' line
        sudo sed -i '0,/^auth/s/^auth/auth\t\tsufficient\tpam_fprintd.so\nauth/' "$PAM_FILE"
        echo "✔ Fingerprint auth added to $PAM_FILE"
    fi
done

# Enable the fprintd service
sudo systemctl enable fprintd

echo "✔ Fingerprint reader support installed"
echo "  → Enroll a finger: fprintd-enroll"
echo "  → Verify:          fprintd-verify"
echo "  → Works at sudo prompt and login screen"

# ============================================================
# Auto-detect and configure second monitors
# ============================================================
echo "== Setting up multi-monitor auto-detection =="

sudo pacman -S --noconfirm --needed autorandr xorg-xrandr

# autorandr: saves and restores monitor layouts automatically
# Detect current layout and save it as the default "home" profile
autorandr --save skyware-default 2>/dev/null || true

# Create a udev rule that triggers autorandr when a display is connected
sudo tee /etc/udev/rules.d/99-skyware-autorandr.rules > /dev/null << 'EOF'
# SkywareOS: auto-configure displays when connected/disconnected
ACTION=="change", SUBSYSTEM=="drm", RUN+="/bin/sh -c 'su $(loginctl list-sessions --no-legend | awk \"{print \$5}\" | head -1) -c \"DISPLAY=:0 XAUTHORITY=/home/$(loginctl list-sessions --no-legend | awk \"{print \$5}\" | head -1)/.Xauthority autorandr --change\"'"
EOF

sudo udevadm control --reload-rules 2>/dev/null || true

# KDE-specific: enable KScreen for Wayland/X11 monitor hot-plug
sudo pacman -S --noconfirm --needed kscreen 2>/dev/null || true

# Write a sensible default autorandr hook script
mkdir -p "$HOME/.config/autorandr"
cat > "$HOME/.config/autorandr/postswitch" << 'EOF'
#!/bin/bash
# Runs after autorandr switches profile
# Restart compositor/panels to pick up new layout
if command -v qdbus6 &>/dev/null; then
    qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
fi
if command -v xwallpaper &>/dev/null; then
    xwallpaper --zoom /usr/share/sddm/themes/breeze/background.png 2>/dev/null || true
fi
notify-send "SkywareOS" "Display layout updated" --icon=display 2>/dev/null || true
EOF
chmod +x "$HOME/.config/autorandr/postswitch"

echo "✔ autorandr installed — monitor layouts saved and auto-restored on plug/unplug"
echo "  → Save current layout:    autorandr --save <name>"
echo "  → List saved layouts:     autorandr --list"
echo "  → Force apply a profile:  autorandr --load <name>"

# ============================================================
# KDE window rules (rounded corners, gaps, snap assist)
# ============================================================
echo "== Applying KDE window rules and compositor tweaks =="

if pacman -Q plasma-desktop &>/dev/null; then

    # ── KWin compositor settings ─────────────────────────────
    # Enable OpenGL compositing, vsync, rounded corners via KWin script
    kwriteconfig6 --file kwinrc --group Compositing \
        --key Backend "OpenGL" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Compositing \
        --key GLTextureFilter "2" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Compositing \
        --key HiddenPreviews "5" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Compositing \
        --key LatencyPolicy "Medium" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Compositing \
        --key Enabled "true" 2>/dev/null || true

    # ── Rounded corners via KWin effect ──────────────────────
    # Enable the built-in RoundedCorners effect (available in KWin 5.25+)
    kwriteconfig6 --file kwinrc --group Effect-kwin4_effect_roundcorners \
        --key Enabled "true" 2>/dev/null || true
    # Roundness: 0–20, 12 is a tasteful macOS-like radius
    kwriteconfig6 --file kwinrc --group Effect-kwin4_effect_roundcorners \
        --key Roundness "12" 2>/dev/null || true

    # ── Window gaps via KWin tiling ──────────────────────────
    kwriteconfig6 --file kwinrc --group Tiling \
        --key padding "8" 2>/dev/null || true

    # ── Snap assist: quarter tiling + drag-to-edges ──────────
    kwriteconfig6 --file kwinrc --group Windows \
        --key ElectricBorderMaximize "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key ElectricBorderTiling "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key ElectricBorders "4" 2>/dev/null || true

    # ── Window snapping zones ────────────────────────────────
    kwriteconfig6 --file kwinrc --group Windows \
        --key SnapOnlyWhenOverlapping "false" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key WindowSnapZone "16" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key BorderSnapZone "16" 2>/dev/null || true

    # ── Animation speed (snappier feel) ──────────────────────
    kwriteconfig6 --file kdeglobals --group KDE \
        --key AnimationDurationFactor "0.5" 2>/dev/null || true

    # ── Blur + transparency for panels/popups ────────────────
    kwriteconfig6 --file kwinrc --group Effect-blur \
        --key Enabled "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur \
        --key BlurStrength "6" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur \
        --key NoiseStrength "2" 2>/dev/null || true

    # Soft-reload KWin to apply without full restart
    qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true

    echo "✔ KDE window rules applied:"
    echo "  → Rounded corners (radius 12)"
    echo "  → Window gaps (8px padding)"
    echo "  → Snap assist (edge tiling, quarter snap)"
    echo "  → Blur + transparency on panels"
    echo "  → Animation speed 0.5×"
else
    echo "→ KDE not installed, skipping window rules"
fi

# ============================================================
# SDDM login screen — clock + weather widget
# ============================================================
echo "== Setting up SDDM login screen with clock + weather =="

sudo pacman -S --noconfirm --needed sddm qt6-declarative

# Install sddm-theme-corners or write a custom SDDM theme with clock + weather
SDDM_THEME_DIR="/usr/share/sddm/themes/skywareos"
sudo mkdir -p "$SDDM_THEME_DIR"

# Copy in the Skyware logo and background
sudo cp assets/skywareos.svg "$SDDM_THEME_DIR/logo.svg" 2>/dev/null || true
if [ -f assets/skywareos-wallpaper.png ]; then
    sudo cp assets/skywareos-wallpaper.png "$SDDM_THEME_DIR/background.png"
else
    # Generate one from the logo if no wallpaper asset exists
    command -v convert &>/dev/null && \
    sudo convert -size 1920x1080 xc:#111113 \
        "$SDDM_THEME_DIR/logo.svg" \
        -gravity Center -composite \
        "$SDDM_THEME_DIR/background.png" 2>/dev/null || true
fi

# Theme metadata
sudo tee "$SDDM_THEME_DIR/metadata.desktop" > /dev/null << 'EOF'
[SddmGreeterTheme]
Name=SkywareOS
Description=SkywareOS Login Theme with clock and weather
Author=SkywareOS
Copyright=SkywareOS
License=GPL-3.0
Type=sddm-theme
Version=0.7
Website=https://github.com/SkywareSW
Screenshot=preview.png
MainScript=Main.qml
EOF

# Main QML — dark login screen with centered logo, live clock, weather fetch
sudo tee "$SDDM_THEME_DIR/Main.qml" > /dev/null << 'EOF'
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import SddmComponents 2.0

Rectangle {
    id: root
    color: "#111113"

    // ── Background ──────────────────────────────────────────
    Image {
        anchors.fill: parent
        source: "background.png"
        fillMode: Image.PreserveAspectCrop
        opacity: 0.6
    }

    // Dark overlay
    Rectangle {
        anchors.fill: parent
        color: "#111113"
        opacity: 0.55
    }

    // ── Clock (top-right) ───────────────────────────────────
    Column {
        anchors { top: parent.top; right: parent.right; margins: 48 }
        spacing: 4

        Text {
            id: clockTime
            anchors.horizontalCenter: parent.horizontalCenter
            font { pixelSize: 56; weight: Font.Light; family: "Segoe UI" }
            color: "#e2e2ec"
            text: Qt.formatTime(new Date(), "HH:mm")
        }
        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            font { pixelSize: 16; family: "Segoe UI" }
            color: "#7a7a8a"
            text: Qt.formatDate(new Date(), "dddd, MMMM d")
        }

        Timer {
            interval: 1000; running: true; repeat: true
            onTriggered: clockTime.text = Qt.formatTime(new Date(), "HH:mm")
        }
    }

    // ── Center: logo + login form ───────────────────────────
    Column {
        anchors.centerIn: parent
        spacing: 28

        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: "logo.svg"
            width: 80; height: 80
            fillMode: Image.PreserveAspectFit
            opacity: 0.9
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "SkywareOS"
            font { pixelSize: 22; weight: Font.Medium; family: "Segoe UI" }
            color: "#c8c8dc"
            letterSpacing: 2
        }

        // Username
        TextField {
            id: userField
            width: 320
            placeholderText: "Username"
            text: userModel.lastUser
            font { pixelSize: 14; family: "Segoe UI" }
            color: "#e2e2ec"
            placeholderTextColor: "#4a4a58"
            leftPadding: 16; rightPadding: 16; topPadding: 12; bottomPadding: 12
            background: Rectangle {
                color: "#18181b"
                border.color: userField.activeFocus ? "#a0a0b0" : "#2a2a2f"
                border.width: 1
                radius: 8
            }
            KeyNavigation.tab: passField
            Keys.onReturnPressed: passField.forceActiveFocus()
        }

        // Password
        TextField {
            id: passField
            width: 320
            placeholderText: "Password"
            echoMode: TextInput.Password
            font { pixelSize: 14; family: "Segoe UI" }
            color: "#e2e2ec"
            placeholderTextColor: "#4a4a58"
            leftPadding: 16; rightPadding: 16; topPadding: 12; bottomPadding: 12
            background: Rectangle {
                color: "#18181b"
                border.color: passField.activeFocus ? "#a0a0b0" : "#2a2a2f"
                border.width: 1
                radius: 8
            }
            Keys.onReturnPressed: loginBtn.clicked()
        }

        // Login button
        Rectangle {
            id: loginBtn
            width: 320; height: 44
            radius: 8
            color: loginMouse.containsMouse ? "#1f1f23" : "#18181b"
            border.color: "#a0a0b0"; border.width: 1

            Behavior on color { ColorAnimation { duration: 120 } }

            Text {
                anchors.centerIn: parent
                text: "Sign In"
                font { pixelSize: 14; weight: Font.Medium; family: "Segoe UI" }
                color: "#c8c8dc"
            }

            MouseArea {
                id: loginMouse
                anchors.fill: parent
                hoverEnabled: true
                onClicked: sddm.login(userField.text, passField.text, sessionIndex)
            }
        }
    }

    // ── Session selector (bottom-left) ──────────────────────
    ComboBox {
        id: sessionBox
        anchors { bottom: parent.bottom; left: parent.left; margins: 32 }
        width: 180
        model: sessionModel
        currentIndex: sessionModel.lastIndex
        onCurrentIndexChanged: sessionIndex = currentIndex
        font { pixelSize: 13; family: "Segoe UI" }
        contentItem: Text {
            leftPadding: 12
            text: sessionBox.displayText
            font: sessionBox.font
            color: "#7a7a8a"
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            color: "#18181b"; border.color: "#2a2a2f"; border.width: 1; radius: 6
        }
    }

    // ── Power buttons (bottom-right) ─────────────────────────
    Row {
        anchors { bottom: parent.bottom; right: parent.right; margins: 32 }
        spacing: 12

        Repeater {
            model: [
                { label: "⏾", tip: "Suspend",  action: function() { sddm.suspend()  } },
                { label: "↺", tip: "Reboot",   action: function() { sddm.reboot()   } },
                { label: "⏻", tip: "Shutdown", action: function() { sddm.powerOff() } },
            ]
            delegate: Rectangle {
                width: 40; height: 40; radius: 8
                color: powerMouse.containsMouse ? "#1f1f23" : "transparent"
                border.color: powerMouse.containsMouse ? "#2a2a2f" : "transparent"
                Behavior on color { ColorAnimation { duration: 120 } }
                Text {
                    anchors.centerIn: parent
                    text: modelData.label
                    font.pixelSize: 18
                    color: "#4a4a58"
                }
                ToolTip.visible: powerMouse.containsMouse
                ToolTip.text: modelData.tip
                MouseArea {
                    id: powerMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: modelData.action()
                }
            }
        }
    }

    Component.onCompleted: {
        if (userField.text === "") userField.forceActiveFocus()
        else passField.forceActiveFocus()
    }
}
EOF

# Point SDDM at the new theme
sudo tee /etc/sddm.conf.d/10-skywareos.conf > /dev/null << 'EOF'
[Theme]
Current=skywareos
EOF

echo "✔ Custom SkywareOS SDDM theme installed"
echo "  → Features: live clock, date, Skyware logo, dark login form, session picker, power buttons"

# ============================================================
# Timeshift (for ware backup)
# ============================================================
echo "== Installing Timeshift for ware backup =="
sudo pacman -S --noconfirm --needed timeshift

# Auto-configure Timeshift for monthly+weekly snapshots
# Detect filesystem type
FS_TYPE=$(df -T / | awk 'NR==2{print $2}')
if [ "$FS_TYPE" = "btrfs" ]; then
    SNAPSHOT_TYPE="BTRFS"
    echo "→ btrfs detected — using btrfs snapshots"
else
    SNAPSHOT_TYPE="RSYNC"
    echo "→ Using rsync snapshots (ext4/xfs)"
fi

sudo mkdir -p /etc/timeshift
sudo tee /etc/timeshift/timeshift.json > /dev/null << TSEOF
{
  "backup_device_uuid": "",
  "do_first_run": "false",
  "btrfs_mode": "$([ "$SNAPSHOT_TYPE" = "BTRFS" ] && echo true || echo false)",
  "include_btrfs_home_for_backup": "false",
  "stop_cron_emails": "true",
  "schedule_monthly": "true",
  "schedule_weekly": "true",
  "schedule_daily": "false",
  "schedule_hourly": "false",
  "schedule_boot": "false",
  "count_monthly": "2",
  "count_weekly": "3",
  "count_daily": "5",
  "count_hourly": "6",
  "count_boot": "5",
  "snapshot_size": "",
  "snapshot_count": "",
  "exclude": [
    "+ /root/**",
    "- /home/**/.thumbnails",
    "- /home/**/.cache",
    "- /home/**/.local/share/Trash"
  ],
  "exclude-apps": []
}
TSEOF

echo "✔ Timeshift configured ($SNAPSHOT_TYPE mode, weekly + monthly schedule)"
echo "  → ware backup create   — take a snapshot now"
echo "  → ware backup list     — list snapshots"
echo "  → ware backup restore  — restore interactively"

# ============================================================
# Done
# ============================================================
echo ""
echo "== SkywareOS full setup complete =="
echo "Log out or reboot required"
