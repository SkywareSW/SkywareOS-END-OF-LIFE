#!/bin/bash
echo "== SkywareOS setup starting =="

# ── Passwordless sudo — applied first so all commands work without tty prompts ──
sudo bash -c "echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-skyware"
sudo chmod 440 /etc/sudoers.d/10-skyware
grep -q 'requiretty' /etc/sudoers 2>/dev/null && sudo sed -i 's/Defaults.*requiretty/Defaults !requiretty/' /etc/sudoers || true
echo "✔ Passwordless sudo configured"

# ── FIX #5: Remove defunct [community] repo references before any pacman call ──
sudo sed -i '/^\[community\]/,/^$/d'         /etc/pacman.conf
sudo sed -i '/^\[community-testing\]/,/^$/d' /etc/pacman.conf
sudo sed -i '/^\[testing\]/,/^$/d'           /etc/pacman.conf
echo "✔ Stale repository entries removed from pacman.conf"

# -----------------------------
# Pacman packages
# FIX #8: add pacman-contrib so checkupdates is available
# -----------------------------
sudo pacman -Syu --noconfirm --needed \
    flatpak cmatrix fastfetch btop zsh alacritty kitty curl git base-devel \
    pacman-contrib

# -----------------------------
# Firewall
# -----------------------------
sudo pacman -S --noconfirm --needed ufw fail2ban
sudo systemctl enable ufw
sudo systemctl enable fail2ban
sudo ufw enable

# -----------------------------
# GPU Driver Selection
# FIX #1: Pascal/Maxwell/Kepler GPUs no longer supported by nvidia>=590
#          → fall back to nvidia-470xx from AUR (Kepler needs nvidia-390xx)
# -----------------------------
echo "== Detecting GPU =="
GPU_INFO=$(lspci | grep -E "VGA|3D")

ensure_paru_bootstrap() {
    if ! command -v paru &>/dev/null; then
        sudo pacman -S --needed --noconfirm base-devel git
        git clone https://aur.archlinux.org/paru.git /tmp/paru
        cd /tmp/paru || exit 1
        makepkg -si --noconfirm
        cd /
        rm -rf /tmp/paru
    fi
}

if echo "$GPU_INFO" | grep -qi "NVIDIA"; then
    echo "→ NVIDIA GPU detected"
    # Turing (20xx), Ampere (30xx), Ada (40xx), Blackwell (50xx) + GTX 16xx → nvidia-open
    if echo "$GPU_INFO" | grep -qiE "RTX|GTX 16[0-9]{2}|GTX 20[0-9]{2}|GTX 30[0-9]{2}"; then
        sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils nvidia-settings
    # Maxwell (GTX 750–980) / Pascal (GTX 10xx) → legacy 470xx driver
    elif echo "$GPU_INFO" | grep -qiE "GTX (750|760|770|780|780 Ti|960|970|980|970M|980M|1[0-9]{3})"; then
        echo "→ Maxwell/Pascal GPU detected — installing legacy nvidia-470xx-dkms from AUR"
        ensure_paru_bootstrap
        paru -S --noconfirm nvidia-470xx-dkms nvidia-470xx-utils 2>/dev/null || \
            echo "⚠ Could not install nvidia-470xx — install manually after setup"
    # Kepler (GTX 600/700) → 390xx
    elif echo "$GPU_INFO" | grep -qiE "GTX [67][0-9]{2}"; then
        echo "→ Kepler GPU detected — installing legacy nvidia-390xx-dkms from AUR"
        ensure_paru_bootstrap
        paru -S --noconfirm nvidia-390xx-dkms nvidia-390xx-utils 2>/dev/null || \
            echo "⚠ Could not install nvidia-390xx — install manually after setup"
    else
        # Unknown NVIDIA — try the modern open driver, fallback to dkms
        sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils nvidia-settings 2>/dev/null || \
            sudo pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings
    fi
elif echo "$GPU_INFO" | grep -qi "AMD"; then
    sudo pacman -S --noconfirm --needed xf86-video-amdgpu mesa vulkan-radeon
elif echo "$GPU_INFO" | grep -qi "Intel"; then
    sudo pacman -S --noconfirm --needed mesa vulkan-intel
elif echo "$GPU_INFO" | grep -qi "VMware"; then
    sudo pacman -S --noconfirm --needed open-vm-tools mesa
else
    echo "⚠ Could not detect GPU automatically"
fi

# ============================================================
# Limine Boot Entry Rename + Plymouth Bootsplash
# ============================================================
echo "== Setting up SkywareOS bootloader branding + bootsplash =="

LIMINE_CONF=""
for candidate in /boot/limine.conf /efi/limine.conf /boot/efi/limine.conf; do
    if [ -f "$candidate" ]; then
        LIMINE_CONF="$candidate"
        break
    fi
done
if [ -z "$LIMINE_CONF" ]; then
    for esp in /boot /efi /boot/efi; do
        if [ -d "$esp" ]; then
            found=$(find "$esp" -maxdepth 5 -iname "limine.conf" 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                LIMINE_CONF="$found"
                break
            fi
        fi
    done
fi

if [ -n "$LIMINE_CONF" ]; then
    echo "→ Limine config found at $LIMINE_CONF"
    sudo cp "$LIMINE_CONF" "$LIMINE_CONF.bak"
    sudo sed -i -E 's/^([[:space:]]*label[[:space:]]*=[[:space:]]*).*/\1SkywareOS/' "$LIMINE_CONF"
    sudo sed -i -E 's|^/[^/].*|/SkywareOS|' "$LIMINE_CONF"
    if grep -qi "^[[:space:]]*cmdline" "$LIMINE_CONF"; then
        # Add quiet splash + AppArmor + Wayland-friendly params in one pass
        sudo sed -i -E '/^[[:space:]]*cmdline/{ /quiet/! s/$/ quiet splash apparmor=1 security=apparmor/ }' "$LIMINE_CONF"
    fi
    echo "✔ Limine entries renamed to SkywareOS"

    LIMINE_DIR=$(dirname "$LIMINE_CONF")
    if [ -f assets/skywareos.svg ]; then
        sudo pacman -S --noconfirm --needed imagemagick librsvg
        sudo rsvg-convert -w 300 -h 300 assets/skywareos.svg -o /tmp/skyware-logo-300.png
        sudo convert \
            -size 1920x1080 xc:#111113 \
            /tmp/skyware-logo-300.png \
            -gravity Center -composite \
            "$LIMINE_DIR/skywareos-boot.png"
        if ! grep -qi "^background_path" "$LIMINE_CONF"; then
            echo "" | sudo tee -a "$LIMINE_CONF" >/dev/null
            echo "background_path = skywareos-boot.png" | sudo tee -a "$LIMINE_CONF" >/dev/null
        else
            sudo sed -i "s|^background_path.*|background_path = skywareos-boot.png|" "$LIMINE_CONF"
        fi
        echo "✔ Limine boot background set to Skyware logo"
    else
        echo "⚠ assets/skywareos.svg not found — skipping Limine logo"
    fi
else
    echo "⚠ Limine config not found — skipping bootloader branding"
fi

# ── Plymouth bootsplash ──────────────────────────────────────
echo "→ Setting up Plymouth bootsplash..."
if ! command -v plymouthd &>/dev/null; then
    sudo pacman -S --noconfirm --needed plymouth
fi
sudo pacman -S --noconfirm --needed librsvg

THEME_DIR="/usr/share/plymouth/themes/skywareos"
sudo mkdir -p "$THEME_DIR"

if [ -f assets/skywareos.svg ]; then
    sudo rsvg-convert -w 512 -h 512 assets/skywareos.svg -o "$THEME_DIR/logo.png"
    sudo rsvg-convert -w 128 -h 128 assets/skywareos.svg -o "$THEME_DIR/logo-small.png"
    echo "✔ Plymouth logo images generated"
else
    echo "⚠ assets/skywareos.svg not found — Plymouth will show text-only splash"
fi

sudo tee "$THEME_DIR/skywareos.plymouth" >/dev/null << 'EOF'
[Plymouth Theme]
Name=SkywareOS
Description=SkywareOS Boot Splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/skywareos
ScriptFile=/usr/share/plymouth/themes/skywareos/skywareos.script
EOF

sudo tee "$THEME_DIR/skywareos.script" >/dev/null << 'EOF'
Window.SetBackgroundTopColor(0.07, 0.07, 0.07);
Window.SetBackgroundBottomColor(0.04, 0.04, 0.05);

logo.image = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.x = Window.GetWidth()  / 2 - logo.image.GetWidth()  / 2;
logo.y = Window.GetHeight() / 2 - logo.image.GetHeight() / 2 - 40;
logo.sprite.SetPosition(logo.x, logo.y, 0);

bar_height  = 3;
bar_y       = Window.GetHeight() - 60;
bar_width   = Window.GetWidth() * 0.4;
bar_x       = Window.GetWidth() / 2 - bar_width / 2;

bar_bg.image  = Image.Scale(Image.New(1, 1), bar_width, bar_height);
bar_bg.image.SetOpacity(0.15);
bar_bg.sprite = Sprite(bar_bg.image);
bar_bg.sprite.SetPosition(bar_x, bar_y, 1);

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

if grep -q "^HOOKS=" /etc/mkinitcpio.conf; then
    if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
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

# -----------------------------
# Desktop Environment
# FIX #2: Wayland-first — install plasma-x11-session explicitly so X11 is
#          available as a fallback, but default session is Wayland.
#          kwin-wayland is now the default; kwin split happened in Plasma 6.4.
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
    echo "Select your Desktop Environment:"
    echo "1) KDE Plasma (Wayland)  2) GNOME (Wayland)  3) Deepin  4) Skip"
    read -rp "Enter choice (1/2/3/4): " de_choice
    case "$de_choice" in
        1)
            # plasma-x11-session keeps X11 login available as fallback
            # SDDM will default to the Wayland session automatically
            sudo pacman -S --noconfirm plasma kde-applications sddm \
                plasma-x11-session xorg-xwayland
            sudo systemctl enable sddm
            echo "✔ KDE Plasma installed (Wayland default, X11 fallback available)"
            ;;
        2)
            sudo pacman -S --noconfirm gnome gnome-extra gdm xorg-xwayland
            sudo systemctl enable gdm
            # GDM defaults to Wayland automatically on supported hardware
            echo "✔ GNOME installed (Wayland default)"
            ;;
        3)
            sudo pacman -S --noconfirm deepin deepin-kwin deepin-extra lightdm xorg-xwayland
            sudo systemctl enable lightdm
            ;;
        *)
            echo "Skipping..."
            ;;
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
VERSION="Crimson(1.0)"
VERSION_ID=Release_1-0
HOME_URL="https://github.com/SkywareSW"
LOGO=skywareos
EOF
sudo tee /usr/lib/os-release > /dev/null << 'EOF'
NAME="SkywareOS"
PRETTY_NAME="SkywareOS"
ID=skywareos
ID_LIKE=arch
VERSION="Crimson(1.0)"
VERSION_ID=Release_1-0
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

rm -f ~/.config/starship.toml
rm -rf ~/.config/starship.d
mkdir -p ~/.config

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
# FIX #9: guard all KDE-specific config behind a KDE install check
# -----------------------------
sudo mkdir -p /usr/share/icons/hicolor/scalable/apps
sudo cp assets/skywareos.svg /usr/share/icons/hicolor/scalable/apps/skywareos.svg 2>/dev/null || true
sudo gtk-update-icon-cache /usr/share/icons/hicolor 2>/dev/null || true

if pacman -Q plasma-desktop &>/dev/null && command -v kwriteconfig6 &>/dev/null; then
    sudo cp assets/skywareos.svg \
        /usr/share/icons/hicolor/scalable/apps/skywareos-start.svg 2>/dev/null || true

    for ICON_SVG in \
        /usr/share/icons/hicolor/scalable/apps/skywareos-start.svg \
        /usr/share/icons/hicolor/scalable/apps/skywareos.svg; do
        if [ -f "$ICON_SVG" ]; then
            sudo sed -i 's/viewBox="[^"]*"//g; s/<svg /<svg viewBox="150 145 215 215" /' "$ICON_SVG"
            echo "✔ viewBox set on $(basename $ICON_SVG)"
        fi
    done

    sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
    sudo kbuildsycoca6 --noincremental 2>/dev/null || true

    mkdir -p "$HOME/.config/autostart-scripts"
    cat > "$HOME/.config/autostart-scripts/skyware-kickoff-icon.sh" << 'ENVEOF'
#!/bin/bash
FLAG="$HOME/.config/skyware/kickoff-icon-set"
[ -f "$FLAG" ] && exit 0
sleep 5

APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
[ -f "$APPLETSRC" ] || exit 0

KICKOFF_ID=$(grep -B5 "org.kde.plasma.kickoff\|org.kde.plasma.kicker" \
    "$APPLETSRC" 2>/dev/null | grep -oP '(?<=\[Applets\]\[)[0-9]+' | tail -1)

if [ -n "$KICKOFF_ID" ]; then
    kwriteconfig6 \
        --file "$APPLETSRC" \
        --group "Applets" --group "$KICKOFF_ID" \
        --group "Configuration" --group "General" \
        --key "icon" "skywareos-start" 2>/dev/null
    qdbus6 org.kde.plasmashell /PlasmaShell \
        org.kde.PlasmaShell.evaluateScript \
        "plasmaShell.loadScriptInApplet('org.kde.plasma.kickoff', '');" \
        2>/dev/null || true
    mkdir -p "$HOME/.config/skyware"
    touch "$FLAG"
fi
ENVEOF
    chmod +x "$HOME/.config/autostart-scripts/skyware-kickoff-icon.sh"

    APPLETSRC="$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc"
    if [ -f "$APPLETSRC" ]; then
        KICKOFF_ID=$(grep -B5 "org.kde.plasma.kickoff\|org.kde.plasma.kicker" \
            "$APPLETSRC" 2>/dev/null | grep -oP '(?<=\[Applets\]\[)[0-9]+' | tail -1)
        if [ -n "$KICKOFF_ID" ]; then
            kwriteconfig6 \
                --file "$APPLETSRC" \
                --group "Applets" --group "$KICKOFF_ID" \
                --group "Configuration" --group "General" \
                --key "icon" "skywareos-start" 2>/dev/null && \
                echo "✔ Kickoff icon patched immediately (applet $KICKOFF_ID)"
        fi
    fi
    echo "✔ KDE Kickoff icon configured"

    sudo pacman -S --noconfirm --needed sddm breeze sddm-kcm
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
    sudo cp assets/skywareos.svg \
        /usr/share/plasma/look-and-feel/org.skywareos.desktop/contents/splash/logo.svg 2>/dev/null || true
    kwriteconfig6 --file kscreenlockerrc --group Greeter --key Theme org.skywareos.desktop 2>/dev/null || true
    kwriteconfig6 --file plasmarc --group Theme --key name org.skywareos.desktop 2>/dev/null || true
fi

# ============================================================
# ware package manager
# ============================================================
echo "== Installing ware package manager =="
sudo tee /usr/local/bin/ware > /dev/null << 'EOF'
#!/bin/bash
LOGFILE="/var/log/ware.log"
JSON_MODE=false

if [ ! -f /etc/sudoers.d/10-skyware ]; then
    sudo bash -c "echo '%wheel ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-skyware" 2>/dev/null && \
        sudo chmod 440 /etc/sudoers.d/10-skyware 2>/dev/null || true
fi
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
autoremove() { ORPHANS=$(pacman -Qtdq 2>/dev/null); if [ -n "$ORPHANS" ]; then sudo pacman -Rns --noconfirm $ORPHANS && log "Autoremove executed"; else echo -e "${GREEN}✔ No orphaned packages${RESET}"; fi; }
power_profile() {
    case "$1" in
        balanced)    sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1; sudo systemctl enable tlp --now; sudo cpupower frequency-set -g schedutil >/dev/null 2>&1; echo -e "${GREEN}✔ Balanced${RESET}" ;;
        performance) sudo pacman -S --needed --noconfirm cpupower >/dev/null 2>&1; sudo cpupower frequency-set -g performance; sudo systemctl stop tlp >/dev/null 2>&1; echo -e "${GREEN}✔ Performance${RESET}" ;;
        battery)     sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1; sudo systemctl enable tlp --now; sudo cpupower frequency-set -g powersave >/dev/null 2>&1; echo -e "${GREEN}✔ Battery${RESET}" ;;
        status)      cpupower frequency-info | grep "current policy" ;;
        *)           echo -e "${YELLOW}Usage: ware power <balanced|performance|battery>${RESET}" ;;
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
    echo -e "Kernel:        $kernel\nUptime:        $uptime_str\nUpdates:       $updates available\nFirewall:      $firewall\nDisk Usage:    $disk\nMemory:        $mem\nDesktop:       ${de:-Unknown}\nChannel:       Crimson\nVersion:       Crimson 1.0"
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
            create)  sudo timeshift --create --comments "ware backup $(date '+%Y-%m-%d %H:%M')" --tags D; log "Snapshot created" ;;
            list)    sudo timeshift --list ;;
            restore) sudo timeshift --restore ;;
            delete)  sudo timeshift --delete ;;
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
                sudo systemctl restart "$unit" 2>/dev/null && \
                    echo -e "${GREEN}✔ Restarted $unit${RESET}" || \
                    echo -e "${RED}✖ Could not restart $unit${RESET}"
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
        echo ""
        echo -e "${CYAN}── Disk ────────────────────────────${RESET}"
        DISK_DEVICE=$(df / | awk 'NR==2{print $1}')
        echo -e "Device: $DISK_DEVICE"
        echo -e "${YELLOW}→ Sequential write test (512MB)...${RESET}"
        WRITE_SPEED=$(dd if=/dev/zero of=/tmp/skyware-bench bs=1M count=512 \
            conv=fdatasync 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1)
        rm -f /tmp/skyware-bench
        echo -e "${YELLOW}→ Sequential read test (512MB)...${RESET}"
        dd if=/dev/urandom of=/tmp/skyware-bench-src bs=1M count=512 2>/dev/null
        READ_SPEED=$(dd if=/tmp/skyware-bench-src of=/dev/null bs=1M 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1)
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
        echo -e "ware doctor              - Run diagnostics"
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

# ── Polkit rule ──
sudo mkdir -p /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/10-skyware.rules > /dev/null << 'POLKITEOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
POLKITEOF

sudo tee /etc/sudoers.d/10-skyware > /dev/null << 'SUDOEOF'
%wheel ALL=(ALL) NOPASSWD: ALL
SUDOEOF
sudo chmod 440 /etc/sudoers.d/10-skyware
sudo visudo -c -f /etc/sudoers.d/10-skyware && echo "✔ Passwordless sudo configured for wheel group" || \
    { echo "⚠ sudoers syntax error — removing"; sudo rm /etc/sudoers.d/10-skyware; }

# ============================================================
# SkywareOS Settings App (Electron + React)
# ============================================================
echo "== Installing SkywareOS Settings App =="
sudo pacman -S --noconfirm --needed nodejs npm

APP_DIR="/opt/skyware-settings"
sudo mkdir -p "$APP_DIR/src"

sudo tee "$APP_DIR/package.json" > /dev/null << 'EOF'
{
  "name": "skyware-settings",
  "version": "1.0.0",
  "description": "SkywareOS Settings",
  "main": "main.js",
  "scripts": { "start": "electron .", "build": "vite build" },
  "dependencies": { "react": "^18.2.0", "react-dom": "^18.2.0" },
  "devDependencies": { "electron": "^30.0.0", "@vitejs/plugin-react": "^4.0.0", "vite": "^5.0.0" }
}
EOF

sudo tee "$APP_DIR/main.js" > /dev/null << 'EOF'
const { app, BrowserWindow, ipcMain } = require('electron');
const { exec } = require('child_process');
const path = require('path');
const fs = require('fs');

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
  const distIndex = path.join(__dirname, 'dist', 'index.html');
  if (fs.existsSync(distIndex)) {
    win.loadFile(distIndex);
  } else {
    win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent([
      '<!DOCTYPE html><html><head><style>',
      'body{background:#111113;color:#e2e2ec;font-family:sans-serif;',
      'display:flex;align-items:center;justify-content:center;',
      'height:100vh;margin:0;flex-direction:column;gap:16px;}',
      'code{background:#18181b;padding:10px 18px;border-radius:8px;',
      'color:#f87171;font-size:13px;border:1px solid #2a2a2f;}',
      '</style></head><body>',
      '<div style="font-size:28px">⚠</div>',
      '<div style="font-size:17px;font-weight:600">Build not found</div>',
      '<code>cd /opt/skyware-settings && npm install && npx vite build</code>',
      '</body></html>'
    ].join('')));
  }
}

ipcMain.handle('run-cmd', async (event, cmd) => {
  return new Promise((resolve) => {
    const env = {
      ...process.env,
      PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:' + (process.env.PATH || ''),
    };
    const TERMINAL_CMDS = ['ware upgrade', 'ware switch', 'ware setup', 'ware snap', 'ware dm switch'];
    const needsTerminal = TERMINAL_CMDS.some(c => cmd.startsWith(c.replace(/^\/usr\/local\/bin\//, '')));
    if (needsTerminal) {
      const { spawn } = require('child_process');
      const tmpScript = '/tmp/skyware-run-' + Date.now() + '.sh';
      require('fs').writeFileSync(tmpScript,
        '#!/bin/bash\n' + cmd + '\necho\nread -p \'Press Enter to close...\'\n'
      );
      require('fs').chmodSync(tmpScript, 0o755);
      const termArgs = [
        ['kitty', [tmpScript]],
        ['alacritty', ['-e', 'bash', tmpScript]],
        ['konsole', ['-e', 'bash', tmpScript]],
        ['xterm', ['-e', 'bash', tmpScript]],
      ];
      let launched = false;
      for (const [t, args] of termArgs) {
        const which = require('child_process').spawnSync('which', [t], { env });
        if (which.status === 0) {
          spawn(t, args, { env, detached: true, stdio: 'ignore' }).unref();
          resolve({ stdout: '→ Opened in ' + t, stderr: '', code: 0 });
          launched = true;
          break;
        }
      }
      if (!launched) {
        const child = exec(
          `bash -c "${cmd.replace(/"/g, '\\"')}"`,
          { env, maxBuffer: 50 * 1024 * 1024, timeout: 300000 },
          (err, stdout, stderr) => {
            resolve({ stdout: stdout || '', stderr: stderr || '', code: err ? err.code : 0 });
          }
        );
        if (child.stdin) child.stdin.end();
      }
      return;
    }
    const child = exec(
      `bash -c "${cmd.replace(/"/g, '\\"')}"`,
      { env, maxBuffer: 50 * 1024 * 1024, timeout: 120000 },
      (err, stdout, stderr) => {
        resolve({ stdout: stdout || '', stderr: stderr || '', code: err ? err.code : 0 });
      }
    );
    if (child.stdin) child.stdin.end();
  });
});

ipcMain.on('window-minimize', (e) => BrowserWindow.fromWebContents(e.sender).minimize());
ipcMain.on('window-maximize', (e) => { const w = BrowserWindow.fromWebContents(e.sender); w.isMaximized() ? w.unmaximize() : w.maximize(); });
ipcMain.on('window-close',    (e) => BrowserWindow.fromWebContents(e.sender).close());

app.whenReady().then(createWindow);
app.on('window-all-closed', () => { if (process.platform !== 'darwin') app.quit(); });
EOF

sudo tee "$APP_DIR/preload.js" > /dev/null << 'EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('skyware', {
  runCmd:   (cmd) => ipcRenderer.invoke('run-cmd', cmd),
  minimize: ()    => ipcRenderer.send('window-minimize'),
  maximize: ()    => ipcRenderer.send('window-maximize'),
  close:    ()    => ipcRenderer.send('window-close'),
});
EOF

sudo tee "$APP_DIR/vite.config.js" > /dev/null << 'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], base: './', build: { outDir: 'dist' } });
EOF

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

sudo tee "$APP_DIR/src/main.jsx" > /dev/null << 'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
createRoot(document.getElementById('root')).render(<App />);
EOF

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

const api = (cmd) => {
  const resolved = cmd.replace(/^ware\b/, '/usr/local/bin/ware');
  return window.skyware?.runCmd(resolved) ?? Promise.resolve({stdout:`[sim] ${resolved}`,stderr:"",code:0});
};

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
        <span style={{background:C.bgHover,color:C.textDim,fontSize:"10px",borderRadius:"4px",padding:"2px 7px",border:`1px solid ${C.border}`}}>Crimson 1.0</span>
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
  const [s,setS]=useState({kernel:"…",uptime:"…",firewall:"…",disk:"…",memory:"…",desktop:"…",updates:"…",session:"…"});
  useEffect(()=>{
    api("uname -r").then(r=>setS(p=>({...p,kernel:r.stdout.trim()||"—"})));
    api("uptime -p").then(r=>setS(p=>({...p,uptime:r.stdout.trim()||"—"})));
    api("systemctl is-active ufw 2>/dev/null; echo $?").then(r=>setS(p=>({...p,firewall:r.stdout.includes("active")?"Active":"Inactive"})));
    api("df -h / | awk 'NR==2{print $5}'").then(r=>setS(p=>({...p,disk:r.stdout.trim()||"—"})));
    api("free -h | awk '/Mem:/{print $3\"/\"$2}'").then(r=>setS(p=>({...p,memory:r.stdout.trim()||"—"})));
    api("echo ${XDG_CURRENT_DESKTOP:-Unknown}").then(r=>setS(p=>({...p,desktop:r.stdout.trim()||"Unknown"})));
    api("checkupdates 2>/dev/null | wc -l || echo 0").then(r=>setS(p=>({...p,updates:r.stdout.trim()||"0"})));
    api("echo ${XDG_SESSION_TYPE:-unknown}").then(r=>setS(p=>({...p,session:r.stdout.trim()||"unknown"})));
  },[]);
  return (
    <div>
      <Hdr title="System Status" sub="Live overview of your SkywareOS installation."/>
      <div style={{display:"grid",gridTemplateColumns:"repeat(3,1fr)",gap:"10px",marginBottom:"24px"}}>
        <Card label="Version"    value="Crimson 1.0 · Release" ab={C.accent+"44"}/>
        <Card label="Kernel"     value={s.kernel}/>
        <Card label="Uptime"     value={s.uptime}/>
        <Card label="Firewall"   value={s.firewall} ab={s.firewall==="Active"?C.green+"44":C.red+"33"}/>
        <Card label="Memory"     value={s.memory}/>
        <Card label="Disk Usage" value={s.disk}/>
        <Card label="Desktop"    value={s.desktop}/>
        <Card label="Session"    value={s.session} ab={s.session==="wayland"?C.green+"44":C.yellow+"33"}/>
        <Card label="Updates"    value={`${s.updates} available`} ab={parseInt(s.updates)>0?C.yellow+"44":undefined}/>
      </div>
      <div style={{display:"flex",gap:"10px",flexWrap:"wrap"}}>
        <Btn label="Run Diagnostics" cmd="echo n | ware doctor" onClick={run} icon="🩺"/>
        <Btn label="Update System"   cmd="ware update"          onClick={run} icon="↑" variant="success"/>
        <Btn label="Sync Mirrors"    cmd="ware sync"            onClick={run} icon="⟳"/>
        <Btn label="Clean Cache"     cmd="ware clean"           onClick={run} icon="✦"/>
        <Btn label="Autoremove"      cmd="ware autoremove"      onClick={run} icon="✖" variant="danger"/>
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
        <Btn label="Update All"          cmd="ware update"      onClick={run} icon="↑" variant="success"/>
        <Btn label="Autoremove Orphans"  cmd="ware autoremove"  onClick={run} icon="✖"/>
        <Btn label="Clean Cache"         cmd="ware clean"       onClick={run} icon="✦"/>
        <Btn label="List All Packages"   cmd="ware list"        onClick={run} icon="◈"/>
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
        <Btn label="List All DMs"   cmd="ware dm list"   onClick={run} icon="☰"/>
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
        <Btn label="Run Doctor"         cmd="echo n | ware doctor" onClick={run} icon="🩺"/>
        <Btn label="AI Doctor"          cmd="ware-ai-doctor"       onClick={run} icon="🤖"/>
        <Btn label="Sync Mirrors"       cmd="ware sync"            onClick={run} icon="⟳"/>
        <Btn label="Clean Cache"        cmd="ware clean"           onClick={run} icon="✦"/>
        <Btn label="Autoremove Orphans" cmd="ware autoremove"      onClick={run} icon="✖"/>
        <Btn label="Enable Snap"        cmd="ware snap"            onClick={run} icon="+"/>
        <Btn label="Remove Snap"        cmd="ware snap-remove"     onClick={run} icon="✖" variant="danger"/>
        <Btn label="Dual Boot (Limine)" cmd="ware dualboot"        onClick={run} icon="⬡"/>
        <Btn label="Open Website"       cmd="ware git"             onClick={run} icon="◎"/>
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
            <div style={{color:C.mutedLo,fontSize:"10px",lineHeight:1.8}}><div>ware v1.0</div><div>SkywareOS · Crimson</div></div>
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

# Build React app as real user (FIX #10: avoid sudo npm permission issues)
echo "→ Building Settings app..."
sudo chown -R "$USER:$USER" "$APP_DIR"
cd "$APP_DIR"
npm install 2>&1 | tail -5

# FIX #10: install electron locally, not globally via sudo
npm install --save-dev electron 2>&1 | tail -3

npx vite build 2>&1 | tail -5
if [ ! -f "$APP_DIR/dist/index.html" ]; then
    echo "✖ Vite build failed — retrying with verbose output:"
    npx vite build
    exit 1
fi
echo "✔ React app built"

sudo chown -R root:root "$APP_DIR"
sudo chmod -R a+rX "$APP_DIR"

# FIX #10: launcher uses npx electron (local install), no sudo npm install -g needed
sudo tee /usr/local/bin/skyware-settings > /dev/null << 'EOF'
#!/bin/bash
cd /opt/skyware-settings
exec npx electron . "$@"
EOF
sudo chmod +x /usr/local/bin/skyware-settings

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

mkdir -p "$HOME/Desktop"
cp /usr/share/applications/skyware-settings.desktop "$HOME/Desktop/skyware-settings.desktop"
chmod +x "$HOME/Desktop/skyware-settings.desktop"

# ============================================================
# AppArmor (Mandatory Access Control)
# FIX #6: apparmor-profiles doesn't exist — just apparmor
# ============================================================
echo "== Setting up AppArmor =="
sudo pacman -S --noconfirm --needed apparmor
sudo systemctl enable apparmor

# Kernel params already added to limine.conf above (in the Limine section)
# so we skip the duplicate sed here

echo "✔ AppArmor enabled (enforcing on next boot)"

# ============================================================
# Automatic Security Updates
# FIX #7: use --ask 4 so unattended pacman doesn't stall on prompts
# ============================================================
echo "== Setting up automatic security updates =="
sudo pacman -S --noconfirm --needed archlinux-keyring

sudo tee /etc/systemd/system/skyware-security-update.service > /dev/null << 'EOF'
[Unit]
Description=SkywareOS Automatic Security Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# --ask 4 auto-answers "yes" to all pacman prompts (prevents stalling)
ExecStart=/usr/bin/pacman -Syu --noconfirm --noprogressbar --ask 4
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
echo "✔ Weekly auto-update timer enabled"

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
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak 2>/dev/null || true
sudo tee /etc/ssh/sshd_config.d/99-skywareos-hardening.conf > /dev/null << 'EOF'
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
echo "✔ SSH hardened"

# ============================================================
# USBGuard
# ============================================================
echo "== Setting up USBGuard =="
sudo pacman -S --noconfirm --needed usbguard
sudo usbguard generate-policy | sudo tee /etc/usbguard/rules.conf >/dev/null
sudo systemctl enable usbguard
sudo systemctl start usbguard
echo "✔ USBGuard enabled"

# ============================================================
# Bluetooth
# ============================================================
echo "== Setting up Bluetooth =="
sudo pacman -S --noconfirm --needed bluez bluez-utils blueman
sudo systemctl enable bluetooth
sudo mkdir -p /etc/bluetooth
if [ ! -f /etc/bluetooth/main.conf ]; then
    sudo tee /etc/bluetooth/main.conf > /dev/null << 'EOF'
[Policy]
AutoEnable=true
EOF
else
    if ! grep -q "AutoEnable" /etc/bluetooth/main.conf; then
        echo -e "\n[Policy]\nAutoEnable=true" | sudo tee -a /etc/bluetooth/main.conf >/dev/null
    else
        sudo sed -i 's/AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf
    fi
fi
echo "✔ Bluetooth enabled"

# ============================================================
# Printing (CUPS) — socket-activated, no boot delay
# ============================================================
echo "== Setting up printing support =="
sudo pacman -S --noconfirm --needed cups cups-pdf system-config-printer \
    gutenprint foomatic-db foomatic-db-engine
sudo systemctl disable cups.service 2>/dev/null || true
sudo systemctl enable cups.socket
sudo systemctl enable cups.service
sudo systemctl stop cups.service 2>/dev/null || true
sudo systemctl disable cups-browsed.service 2>/dev/null || true
sudo systemctl stop cups-browsed.service 2>/dev/null || true
sudo pacman -S --noconfirm --needed nss-mdns avahi
sudo systemctl disable avahi-daemon.service 2>/dev/null || true
sudo systemctl enable avahi-daemon.socket
sudo systemctl enable avahi-daemon.service
if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
    sudo sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
        /etc/nsswitch.conf
fi
echo "✔ CUPS printing enabled (socket-activated)"

# ============================================================
# Touchpad Gestures — Wayland-native via libinput-gestures
# ============================================================
echo "== Setting up touchpad gestures =="
sudo pacman -S --noconfirm --needed libinput
# wmctrl/xdotool are X11 tools; on Wayland use ydotool or wtype instead
sudo pacman -S --noconfirm --needed ydotool 2>/dev/null || true

if command -v paru &>/dev/null; then
    paru -S --noconfirm libinput-gestures 2>/dev/null || true
else
    git clone https://github.com/bulletmark/libinput-gestures.git /tmp/libinput-gestures
    cd /tmp/libinput-gestures
    sudo make install
    cd "$OLDPWD"
    rm -rf /tmp/libinput-gestures
fi

sudo gpasswd -a "$USER" input

mkdir -p "$HOME/.config"
cat > "$HOME/.config/libinput-gestures.conf" << 'EOF'
# SkywareOS Wayland gesture config
# Uses KWin D-Bus calls for workspace switching (works on Wayland)

# 3-finger swipe left/right → switch workspaces
gesture swipe left  3  qdbus6 org.kde.KWin /KWin nextDesktop
gesture swipe right 3  qdbus6 org.kde.KWin /KWin previousDesktop

# 3-finger swipe up → overview
gesture swipe up    3  qdbus6 org.kde.KWin /KWin toggleOverview

# 3-finger swipe down → show desktop
gesture swipe down  3  qdbus6 org.kde.KWin /KWin showDesktop

# 4-finger swipe up → window overview
gesture swipe up    4  qdbus6 org.kde.KWin /KWin showAllWindowsFromCurrentApplication
EOF

mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/libinput-gestures.desktop" << 'EOF'
[Desktop Entry]
Name=libinput-gestures
Exec=libinput-gestures-setup start
Type=Application
X-GNOME-Autostart-enabled=true
EOF

libinput-gestures-setup autostart start 2>/dev/null || true
echo "✔ Touchpad gestures configured (Wayland/KWin D-Bus)"

# ============================================================
# Timezone + Locale
# ============================================================
echo "== Configuring timezone and locale =="
DETECTED_TZ=$(curl -s --max-time 5 "https://ipapi.co/timezone" 2>/dev/null || echo "")
if [ -n "$DETECTED_TZ" ] && timedatectl list-timezones | grep -qx "$DETECTED_TZ"; then
    sudo timedatectl set-timezone "$DETECTED_TZ"
    echo "✔ Timezone auto-set to: $DETECTED_TZ"
else
    echo "⚠ Could not auto-detect timezone — falling back to UTC"
    sudo timedatectl set-timezone UTC
fi
sudo timedatectl set-ntp true
echo "✔ NTP time sync enabled"
if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
    echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen >/dev/null
fi
sudo locale-gen
if [ ! -f /etc/locale.conf ] || ! grep -q "LANG=" /etc/locale.conf; then
    echo "LANG=en_US.UTF-8" | sudo tee /etc/locale.conf >/dev/null
fi
echo "✔ Locale set to en_US.UTF-8"

# ============================================================
# Docker + Podman
# FIX #4: add "ip6tables": false to daemon.json to prevent crash
#          on systems without IPv6
# ============================================================
echo "== Setting up Docker and Podman =="
sudo pacman -S --noconfirm --needed docker podman docker-compose podman-compose \
    docker-buildx
sudo systemctl enable docker
sudo gpasswd -a "$USER" docker
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "journald",
  "live-restore": true,
  "userland-proxy": false,
  "ip6tables": false
}
EOF
sudo pacman -S --noconfirm --needed fuse-overlayfs slirp4netns
echo "✔ Docker + Podman installed (ip6tables workaround applied)"

# ============================================================
# VPN Support
# ============================================================
echo "== Setting up VPN support =="
sudo pacman -S --noconfirm --needed \
    networkmanager-openvpn \
    wireguard-tools \
    openvpn \
    networkmanager \
    network-manager-applet
# Disable NetworkManager-wait-online to avoid 60s+ boot delay
sudo systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
if command -v paru &>/dev/null; then
    paru -S --noconfirm protonvpn-cli 2>/dev/null || \
        echo "⚠ protonvpn-cli not available — install manually from AUR"
fi
echo "✔ VPN support installed (OpenVPN + WireGuard)"

# ============================================================
# Dotfiles Auto-backup
# ============================================================
echo "== Setting up automatic dotfiles backup =="
DOTFILES_DIR="$HOME/.dotfiles"
mkdir -p "$DOTFILES_DIR"
if [ ! -d "$DOTFILES_DIR/.git" ] && [ ! -f "$DOTFILES_DIR/HEAD" ]; then
    git init --bare "$DOTFILES_DIR" 2>/dev/null || git init "$DOTFILES_DIR"
fi
DOTFILES_CMD="git --git-dir=$DOTFILES_DIR --work-tree=$HOME"
if ! grep -q "alias dotfiles=" "$HOME/.zshrc" 2>/dev/null; then
    cat >> "$HOME/.zshrc" << 'EOF'

alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'
EOF
fi
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

mkdir -p "$HOME/.config/systemd/user"
tee "$HOME/.config/systemd/user/dotfiles-backup.service" > /dev/null << SVCEOF
[Unit]
Description=SkywareOS Dotfiles Auto-Backup

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'git --git-dir=%h/.dotfiles --work-tree=%h add -u && git --git-dir=%h/.dotfiles --work-tree=%h commit -m "auto: $(date +%%Y-%%m-%%d)" 2>/dev/null || true'
SVCEOF
tee "$HOME/.config/systemd/user/dotfiles-backup.timer" > /dev/null << 'EOF'
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

# ============================================================
# TLP Battery Health
# ============================================================
echo "== Setting up TLP battery health daemon =="
sudo pacman -S --noconfirm --needed tlp tlp-rdw ethtool smartmontools
sudo systemctl enable tlp
sudo systemctl enable NetworkManager-dispatcher
sudo systemctl disable power-profiles-daemon 2>/dev/null || true
sudo systemctl mask systemd-rfkill.service systemd-rfkill.socket 2>/dev/null || true
sudo tee /etc/tlp.conf > /dev/null << 'EOF'
TLP_ENABLE=1
TLP_DEFAULT_MODE=AC
CPU_SCALING_GOVERNOR_ON_AC=schedutil
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=power
START_CHARGE_THRESH_BAT0=20
STOP_CHARGE_THRESH_BAT0=80
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave
USB_AUTOSUSPEND=1
USB_EXCLUDE_AUDIO=1
USB_EXCLUDE_BTUSB=1
DISK_APM_LEVEL_ON_AC="254 254"
DISK_APM_LEVEL_ON_BAT="128 128"
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on
NMI_WATCHDOG=0
RUNTIME_PM_ON_AC=on
RUNTIME_PM_ON_BAT=auto
EOF
echo "✔ TLP configured (charge thresholds 20–80%)"

# ============================================================
# KDE Global Theme + Color Scheme
# FIX #9: guard fully behind KDE install check
# ============================================================
echo "== Applying SkywareOS KDE theme =="
if pacman -Q plasma-desktop &>/dev/null && command -v kwriteconfig6 &>/dev/null; then
    if command -v paru &>/dev/null; then
        paru -S --noconfirm lightly-git 2>/dev/null || true
    fi
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

[Colors:Complementary]
BackgroundAlternate=14,14,16
BackgroundNormal=17,17,19
DecorationFocus=160,160,176
DecorationHover=160,160,176
ForegroundNormal=226,226,236
ForegroundInactive=74,74,88

[Colors:Header]
BackgroundAlternate=12,12,14
BackgroundNormal=14,14,16
ForegroundNormal=226,226,236
ForegroundInactive=74,74,88

[Colors:Selection]
BackgroundAlternate=31,31,35
BackgroundNormal=42,42,50
ForegroundNormal=226,226,236

[Colors:Tooltip]
BackgroundAlternate=17,17,19
BackgroundNormal=24,24,27
ForegroundNormal=226,226,236

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

    kwriteconfig6 --file kdeglobals --group General \
        --key ColorScheme "SkywareOS" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group org.kde.kdecoration2 \
        --key theme "org.kde.breeze" 2>/dev/null || true
    kwriteconfig6 --file kdeglobals --group KDE \
        --key widgetStyle "Breeze" 2>/dev/null || true
    kwriteconfig6 --file plasmarc --group Theme \
        --key name "breeze-dark" 2>/dev/null || true
    echo "✔ SkywareOS KDE color scheme applied"
else
    echo "→ KDE not installed, skipping theme"
fi

# ============================================================
# Cursor Theme (Bibata Modern Classic)
# ============================================================
echo "== Installing cursor theme =="
if command -v paru &>/dev/null; then
    paru -S --noconfirm bibata-cursor-theme 2>/dev/null || \
        echo "⚠ bibata-cursor-theme not found in AUR, skipping"
else
    BIBATA_URL="https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/Bibata-Modern-Classic.tar.xz"
    curl -L "$BIBATA_URL" -o /tmp/bibata.tar.xz 2>/dev/null && \
        sudo tar -xf /tmp/bibata.tar.xz -C /usr/share/icons/ && \
        rm /tmp/bibata.tar.xz && \
        echo "✔ Bibata cursor theme installed" || \
        echo "⚠ Could not download cursor theme"
fi

sudo mkdir -p /usr/share/icons/default
sudo tee /usr/share/icons/default/index.theme > /dev/null << 'EOF'
[Icon Theme]
Inherits=Bibata-Modern-Classic
EOF
mkdir -p "$HOME/.icons/default"
cat > "$HOME/.icons/default/index.theme" << 'EOF'
[Icon Theme]
Inherits=Bibata-Modern-Classic
EOF
if pacman -Q plasma-desktop &>/dev/null && command -v kwriteconfig6 &>/dev/null; then
    kwriteconfig6 --file kcminputrc --group Mouse \
        --key cursorTheme "Bibata-Modern-Classic" 2>/dev/null || true
    kwriteconfig6 --file kcminputrc --group Mouse \
        --key cursorSize "24" 2>/dev/null || true
fi
echo "✔ Cursor theme set to Bibata Modern Classic"

# ============================================================
# MOTD — FIX #8: checkupdates is now available (pacman-contrib installed above)
# ============================================================
echo "== Setting up SkywareOS MOTD =="
sudo pacman -S --noconfirm --needed figlet lolcat 2>/dev/null || true

sudo tee /etc/profile.d/skyware-motd.sh > /dev/null << 'MOTDEOF'
#!/bin/bash
[[ $- != *i* ]] && return
[[ -n "$MOTD_SHOWN" ]] && return
export MOTD_SHOWN=1

GRAY="\e[38;5;245m"
LGRAY="\e[38;5;250m"
WHITE="\e[97m"
GREEN="\e[92m"
YELLOW="\e[93m"
RED="\e[91m"
RESET="\e[0m"
BOLD="\e[1m"

echo ""
echo -e "${GRAY}      @@@@@@@-         +@@@@@@.     ${RESET}"
echo -e "${GRAY}    %@@@@@@@@@@=      @@@@@@@@@@    ${RESET}    ${BOLD}${WHITE}SkywareOS${RESET} ${GRAY}Crimson 1.0${RESET}"
echo -e "${GRAY}   @@@@     @@@@@      -     #@@@   ${RESET}    ${LGRAY}────────────────────────────${RESET}"
echo -e "${GRAY}  :@@*        @@@@             @@@  ${RESET}    ${GRAY}Kernel  ${RESET}$(uname -r)"
echo -e "${GRAY}  @@@          @@@@            @@@  ${RESET}    ${GRAY}Uptime  ${RESET}$(uptime -p | sed 's/up //')"
echo -e "${GRAY}  @@@           @@@@           %@@  ${RESET}    ${GRAY}Shell   ${RESET}zsh $(zsh --version 2>/dev/null | cut -d' ' -f2)"
echo -e "${GRAY}  @@@            @@@@          @@@  ${RESET}    ${GRAY}Pkgs    ${RESET}$(pacman -Q 2>/dev/null | wc -l) (pacman)"
echo -e "${GRAY}  :@@@            @@@@:        @@@  ${RESET}    ${GRAY}Memory  ${RESET}$(free -h | awk '/Mem:/{print $3"/"$2}')"
echo -e "${GRAY}   @@@@     =      @@@@@     %@@@   ${RESET}    ${GRAY}Disk    ${RESET}$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
echo -e "${GRAY}    @@@@@@@@@@       @@@@@@@@@@@    ${RESET}    ${GRAY}Session ${RESET}${XDG_SESSION_TYPE:-unknown}"
echo -e "${GRAY}      @@@@@@+          %@@@@@@      ${RESET}"
echo ""

UPDATES=$(checkupdates 2>/dev/null | wc -l)
if [ "$UPDATES" -gt 0 ]; then
    echo -e "  ${YELLOW}⚠${RESET}  ${YELLOW}${UPDATES} update(s) available${RESET} — run ${GRAY}ware update${RESET}"
    echo ""
fi
if ! systemctl is-active ufw >/dev/null 2>&1; then
    echo -e "  ${RED}✖${RESET}  ${RED}Firewall is not running${RESET} — run ${GRAY}sudo ufw enable${RESET}"
    echo ""
fi
MOTDEOF
sudo chmod +x /etc/profile.d/skyware-motd.sh
sudo rm -f /etc/motd
echo "✔ MOTD installed"

# ============================================================
# Tmux — Skyware theme
# ============================================================
echo "== Setting up tmux =="
sudo pacman -S --noconfirm --needed tmux
cat > "$HOME/.tmux.conf" << 'EOF'
unbind C-b
set -g prefix C-Space
bind C-Space send-prefix
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 0
set -g focus-events on
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -g status on
set -g status-position bottom
set -g status-interval 5
set -g status-style "bg=#0e0e10,fg=#a0a0b0"
set -g status-left-length 40
set -g status-left "#[bg=#1f1f23,fg=#c8c8dc,bold]  SkywareOS #[bg=#0e0e10,fg=#2a2a2f]#[default] "
set -g status-right-length 80
set -g status-right "#[fg=#4a4a58]  #[fg=#7a7a8a]%H:%M  #[fg=#4a4a58]  #[fg=#7a7a8a]%d %b  #[fg=#4a4a58]  #[fg=#7a7a8a]#H "
setw -g window-status-current-format "#[bg=#1f1f23,fg=#c8c8dc,bold] #I #W #[default]"
setw -g window-status-format "#[fg=#4a4a58] #I #W "
setw -g window-status-separator ""
set -g pane-border-style "fg=#2a2a2f"
set -g pane-active-border-style "fg=#a0a0b0"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5
bind r source-file ~/.tmux.conf \; display "Config reloaded"
EOF
echo "✔ Tmux configured"

# ============================================================
# Custom Pacman progress bar
# FIX #5: also clean any remaining [community] lines not caught earlier
# ============================================================
echo "== Customizing pacman =="
sudo cp /etc/pacman.conf /etc/pacman.conf.bak
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
print("✔ Pacman: Color + ILoveCandy + 10 parallel downloads enabled")
PYEOF

# ============================================================
# GameMode + MangoHud
# ============================================================
echo "== Setting up gaming performance tools =="
if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
    echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" | sudo tee -a /etc/pacman.conf >/dev/null
    sudo pacman -Sy --noconfirm
    echo "✔ multilib enabled"
fi
sudo pacman -S --noconfirm --needed gamemode lib32-gamemode mangohud lib32-mangohud
sudo gpasswd -a "$USER" gamemode 2>/dev/null || true

mkdir -p "$HOME/.config/MangoHud"
cat > "$HOME/.config/MangoHud/MangoHud.conf" << 'EOF'
legacy_layout=false
hud_compact=false
background_alpha=0.4
font_size=20
round_corners=8
offset_x=12
offset_y=12
position=top-left
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
toggle_hud=Shift_F12
EOF
echo "✔ GameMode + MangoHud installed"

# ============================================================
# Wine (wow64 — no lib32 Wine deps needed since Arch Wine 9+)
# FIX #3: Wine is now a pure wow64 build, remove the redundant lib32-* list
# ============================================================
echo "== Setting up Wine =="
sudo pacman -Sy --noconfirm 2>/dev/null || true
sudo pacman -S --noconfirm --needed \
    wine wine-mono wine-gecko winetricks \
    lib32-vulkan-icd-loader vulkan-icd-loader \
    lib32-mesa mesa
# Note: the long list of lib32-* wine deps (libpulse, openal, mpg123, etc.)
# is no longer needed with the wow64 build. Vulkan loaders kept for gaming.
if command -v paru &>/dev/null; then
    paru -S --noconfirm proton-ge-custom-bin 2>/dev/null || \
        echo "⚠ proton-ge-custom-bin not found, install manually"
fi
sudo pacman -S --noconfirm --needed lutris
echo "✔ Wine (wow64) + Lutris installed"

# ============================================================
# AI Doctor
# ============================================================
echo "== Adding AI repair to ware doctor =="
sudo tee /usr/local/bin/ware-ai-doctor > /dev/null << 'EOF'
#!/bin/bash
RED="\e[31m"; CYAN="\e[36m"; GREEN="\e[32m"; YELLOW="\e[33m"; RESET="\e[0m"
KEY_FILE="$HOME/.config/skyware/api_key"
API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$API_KEY" ] && [ -f "$KEY_FILE" ]; then
    API_KEY=$(cat "$KEY_FILE")
fi
if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}→ No Anthropic API key found.${RESET}"
    echo -e "  Set it with: mkdir -p ~/.config/skyware && echo 'sk-ant-...' > ~/.config/skyware/api_key"
    exit 1
fi
echo -e "${CYAN}== SkywareOS AI Doctor ==${RESET}"
echo -e "${CYAN}→ Collecting system diagnostics...${RESET}"
ERRORS=$(sudo journalctl -p err -b --no-pager -n 30 2>/dev/null)
FAILED=$(systemctl --failed --no-legend 2>/dev/null)
PACMAN_LOG=$(tail -n 20 /var/log/pacman.log 2>/dev/null)
OS_INFO="SkywareOS Crimson 1.0 (Arch-based), kernel $(uname -r)"
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
echo "✔ AI Doctor installed"

# ============================================================
# Welcome App
# ============================================================
echo "== Installing SkywareOS Welcome App =="
sudo mkdir -p /opt/skyware-welcome/src

sudo tee /opt/skyware-welcome/package.json > /dev/null << 'EOF'
{
  "name": "skyware-welcome",
  "version": "1.0.0",
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
  if (fs.existsSync(DONE_FLAG)) { app.quit(); return; }
  const win = new BrowserWindow({
    width: 760, height: 540, frame: false, center: true,
    backgroundColor: '#111113', resizable: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
    title: 'Welcome to SkywareOS',
  });
  const distIndex = path.join(__dirname, 'dist', 'index.html');
  fs.existsSync(distIndex) ? win.loadFile(distIndex) : win.loadURL('about:blank');
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
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"/><title>Welcome to SkywareOS</title>
<style>*{margin:0;padding:0;box-sizing:border-box;}body{overflow:hidden;background:#111113;}#root{height:100vh;}</style>
</head><body><div id="root"></div><script type="module" src="/src/main.jsx"></script></body></html>
EOF

sudo tee /opt/skyware-welcome/src/main.jsx > /dev/null << 'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
createRoot(document.getElementById('root')).render(<App />);
EOF

sudo tee /opt/skyware-welcome/src/App.jsx > /dev/null << 'APPEOF'
import { useState } from "react";
const C = { bg:"#111113",card:"#18181b",border:"#2a2a2f",accent:"#a0a0b0",accentHi:"#c8c8dc",text:"#e2e2ec",dim:"#7a7a8a",muted:"#4a4a58",green:"#4ade80",blue:"#60a5fa",yellow:"#facc15" };
const STEPS = [{id:"welcome",label:"Welcome"},{id:"features",label:"Features"},{id:"tools",label:"Tools"},{id:"done",label:"Done"}];
const FEATURES = [
  {icon:"⬡",title:"ware",desc:"Unified package manager — wraps pacman, flatpak, and AUR."},
  {icon:"⚙",title:"Settings App",desc:"GUI control panel. Launch with: skyware-settings"},
  {icon:"⚡",title:"GameMode",desc:"Auto-boosts CPU/GPU for gaming. Add gamemoderun to Steam."},
  {icon:"◈",title:"AI Doctor",desc:"ware-ai-doctor queries Claude API to diagnose system issues."},
  {icon:"🔒",title:"AppArmor",desc:"Mandatory access control enabled by default."},
  {icon:"◉",title:"Wayland",desc:"Wayland-first — all DEs default to Wayland sessions."},
];
const LINKS = [
  {label:"GitHub",url:"https://github.com/SkywareSW/SkywareOS"},
  {label:"Website",url:"https://skywaresw.github.io/SkywareOS"},
];
export default function App() {
  const [step,setStep]=useState(0);
  const current=STEPS[step];
  const next=()=>step<STEPS.length-1?setStep(step+1):window.welcome?.finish();
  const prev=()=>setStep(step-1);
  return (
    <div style={{height:"100vh",background:C.bg,fontFamily:"'Segoe UI',system-ui,sans-serif",color:C.text,display:"flex",flexDirection:"column",overflow:"hidden"}}>
      <div style={{height:"44px",background:"#0c0c0e",borderBottom:`1px solid ${C.border}`,display:"flex",alignItems:"center",justifyContent:"space-between",padding:"0 16px",WebkitAppRegion:"drag",flexShrink:0}}>
        <div style={{display:"flex",alignItems:"center",gap:"8px"}}>
          <div style={{width:"20px",height:"20px",borderRadius:"4px",background:`linear-gradient(135deg,${C.accent},#505060)`,display:"flex",alignItems:"center",justifyContent:"center",fontSize:"11px",fontWeight:900,color:"#fff"}}>S</div>
          <span style={{fontSize:"13px",fontWeight:600}}>Welcome to SkywareOS</span>
        </div>
        <button onClick={()=>window.welcome?.close()} style={{WebkitAppRegion:"no-drag",background:"none",border:"none",color:C.muted,cursor:"pointer",fontSize:"16px"}}>×</button>
      </div>
      <div style={{display:"flex",justifyContent:"center",gap:"8px",padding:"20px 0 0",flexShrink:0}}>
        {STEPS.map((s,i)=>(
          <div key={s.id} style={{display:"flex",alignItems:"center",gap:"8px"}}>
            <div style={{width:"24px",height:"24px",borderRadius:"50%",background:i<=step?C.accent:"transparent",border:`1px solid ${i<=step?C.accent:C.border}`,display:"flex",alignItems:"center",justifyContent:"center",fontSize:"11px",color:i<=step?"#111":C.muted,fontWeight:600}}>{i+1}</div>
            {i<STEPS.length-1&&<div style={{width:"32px",height:"1px",background:i<step?C.accent:C.border}}/>}
          </div>
        ))}
      </div>
      <div style={{flex:1,padding:"28px 40px",overflowY:"auto"}}>
        {current.id==="welcome"&&(
          <div style={{textAlign:"center",paddingTop:"8px"}}>
            <div style={{fontFamily:"monospace",fontSize:"11px",color:C.muted,lineHeight:1.6,marginBottom:"20px",whiteSpace:"pre"}}>
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
            <p style={{color:C.dim,fontSize:"14px",lineHeight:1.6,maxWidth:"400px",margin:"0 auto"}}>An Arch-based Linux distro built for performance, customization, and a clean Wayland-first experience.</p>
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
                  <div><div style={{fontWeight:600,fontSize:"13px",marginBottom:"3px"}}>{f.title}</div><div style={{color:C.dim,fontSize:"12px",lineHeight:1.5}}>{f.desc}</div></div>
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
                  <span style={{fontSize:"13px"}}>{l.label}</span>
                  <button onClick={()=>window.welcome?.openLink(l.url)} style={{background:"transparent",border:`1px solid ${C.border}`,color:C.accentHi,borderRadius:"5px",padding:"5px 12px",cursor:"pointer",fontSize:"12px",fontFamily:"inherit"}}>Open</button>
                </div>
              ))}
            </div>
          </div>
        )}
        {current.id==="done"&&(
          <div style={{textAlign:"center",paddingTop:"20px"}}>
            <div style={{fontSize:"48px",marginBottom:"16px"}}>✔</div>
            <h2 style={{fontSize:"22px",fontWeight:700,marginBottom:"8px",color:C.green}}>You're all set</h2>
            <p style={{color:C.dim,fontSize:"14px",lineHeight:1.6,maxWidth:"360px",margin:"0 auto 24px"}}>SkywareOS is ready. Open settings anytime with <span style={{color:C.accentHi,fontFamily:"monospace"}}>skyware-settings</span>.</p>
            <div style={{background:C.card,border:`1px solid ${C.border}`,borderRadius:"8px",padding:"14px 20px",display:"inline-block",textAlign:"left"}}>
              <div style={{fontFamily:"monospace",fontSize:"12px",color:C.dim,lineHeight:2}}>
                <div><span style={{color:C.accent}}>$</span> ware help</div>
                <div><span style={{color:C.accent}}>$</span> ware install {'<pkg>'}</div>
                <div><span style={{color:C.accent}}>$</span> ware settings</div>
                <div><span style={{color:C.accent}}>$</span> ware doctor</div>
              </div>
            </div>
          </div>
        )}
      </div>
      <div style={{padding:"16px 40px",borderTop:`1px solid ${C.border}`,display:"flex",justifyContent:"space-between",flexShrink:0,background:"#0c0c0e"}}>
        <button onClick={prev} disabled={step===0} style={{background:"transparent",border:`1px solid ${C.border}`,color:step===0?C.muted:C.text,borderRadius:"7px",padding:"9px 20px",cursor:step===0?"not-allowed":"pointer",fontSize:"13px",fontFamily:"inherit",opacity:step===0?0.4:1}}>← Back</button>
        <button onClick={next} style={{background:C.accentHi,border:"none",color:"#111",borderRadius:"7px",padding:"9px 24px",cursor:"pointer",fontSize:"13px",fontFamily:"inherit",fontWeight:600}}>{step===STEPS.length-1?"Get Started →":"Next →"}</button>
      </div>
    </div>
  );
}
APPEOF

# FIX #10: use local electron, not sudo npm install -g
sudo chown -R "$USER:$USER" /opt/skyware-welcome
cd /opt/skyware-welcome
npm install 2>&1 | tail -5
npm install --save-dev electron 2>&1 | tail -3
npx vite build 2>&1 | tail -5
if [ ! -f /opt/skyware-welcome/dist/index.html ]; then
    echo "✖ Welcome app build failed — retrying:"
    npx vite build
fi
echo "✔ Welcome app built"
sudo chown -R root:root /opt/skyware-welcome
sudo chmod -R a+rX /opt/skyware-welcome

sudo tee /usr/local/bin/skyware-welcome > /dev/null << 'EOF'
#!/bin/bash
cd /opt/skyware-welcome
exec npx electron . "$@"
EOF
sudo chmod +x /usr/local/bin/skyware-welcome

sudo tee /usr/share/applications/skyware-welcome.desktop > /dev/null << 'EOF'
[Desktop Entry]
Name=Welcome to SkywareOS
Exec=/usr/local/bin/skyware-welcome
Icon=dialog-information
Terminal=false
Type=Application
Categories=System;
NoDisplay=true
EOF

mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/skyware-welcome.desktop" << 'EOF'
[Desktop Entry]
Name=SkywareOS Welcome
Exec=/usr/local/bin/skyware-welcome
Type=Application
X-GNOME-Autostart-enabled=true
EOF
echo "✔ Welcome app installed"

# ============================================================
# OTA Update Notifier
# ============================================================
echo "== Setting up OTA update notifier =="
sudo pacman -S --noconfirm --needed libnotify python-gobject gtk3

sudo tee /usr/local/bin/skyware-update-notifier > /dev/null << 'EOF'
#!/usr/bin/env python3
import subprocess, sys

def count_updates():
    try:
        r = subprocess.run(["checkupdates"], capture_output=True, text=True, timeout=30)
        pacman = len([l for l in r.stdout.splitlines() if l.strip()])
    except Exception:
        pacman = 0
    try:
        r = subprocess.run(["flatpak","remote-ls","--updates"], capture_output=True, text=True, timeout=30)
        flatpak = len([l for l in r.stdout.splitlines() if l.strip()])
    except Exception:
        flatpak = 0
    return pacman, flatpak

def notify(pacman, flatpak):
    total = pacman + flatpak
    if total == 0:
        return
    parts = []
    if pacman > 0: parts.append(f"{pacman} pacman")
    if flatpak > 0: parts.append(f"{flatpak} flatpak")
    summary = f"SkywareOS: {total} update{'s' if total > 1 else ''} available"
    body = f"{', '.join(parts)} package{'s' if total > 1 else ''} can be updated.\nRun: ware update"
    subprocess.run(["notify-send","--app-name=SkywareOS","--icon=system-software-update",
                    "--urgency=normal","--expire-time=8000",summary,body])

if __name__ == "__main__":
    p, f = count_updates()
    notify(p, f)
    sys.exit(0)
EOF
sudo chmod +x /usr/local/bin/skyware-update-notifier

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
echo "✔ Update notifier installed"

# ============================================================
# Auto-mount (udiskie)
# ============================================================
echo "== Setting up auto-mount for external drives =="
sudo pacman -S --noconfirm --needed udiskie udisks2 gvfs
mkdir -p "$HOME/.config/autostart"
cat > "$HOME/.config/autostart/udiskie.desktop" << 'EOF'
[Desktop Entry]
Name=udiskie
Exec=udiskie --tray --notify --appindicator
Type=Application
X-GNOME-Autostart-enabled=true
EOF
mkdir -p "$HOME/.config/udiskie"
cat > "$HOME/.config/udiskie/config.yml" << 'EOF'
program_options:
  tray: true
  notify: true
  automount: true
  appindicator: true
notifications:
  timeout: 4
EOF
udiskie --tray --notify --appindicator &>/dev/null &
disown
echo "✔ udiskie installed"

# ============================================================
# Fingerprint Reader (fprint)
# ============================================================
echo "== Setting up fingerprint reader =="
sudo pacman -S --noconfirm --needed fprintd libfprint
for PAM_FILE in /etc/pam.d/sudo /etc/pam.d/login /etc/pam.d/sddm; do
    if [ -f "$PAM_FILE" ] && ! grep -q "pam_fprintd" "$PAM_FILE"; then
        sudo sed -i '0,/^auth/s/^auth/auth\t\tsufficient\tpam_fprintd.so\nauth/' "$PAM_FILE"
        echo "✔ Fingerprint auth added to $PAM_FILE"
    fi
done
sudo systemctl enable fprintd
echo "✔ Fingerprint reader support installed"

# ============================================================
# Multi-monitor auto-detect (autorandr — X11 fallback)
# ============================================================
echo "== Setting up multi-monitor support =="
sudo pacman -S --noconfirm --needed autorandr xorg-xrandr
autorandr --save skyware-default 2>/dev/null || true
sudo tee /etc/udev/rules.d/99-skyware-autorandr.rules > /dev/null << 'EOF'
ACTION=="change", SUBSYSTEM=="drm", RUN+="/bin/sh -c 'su $(loginctl list-sessions --no-legend | awk \"{print \$5}\" | head -1) -c \"DISPLAY=:0 XAUTHORITY=/home/$(loginctl list-sessions --no-legend | awk \"{print \$5}\" | head -1)/.Xauthority autorandr --change\"'"
EOF
sudo udevadm control --reload-rules 2>/dev/null || true
# On Wayland, KScreen handles hot-plug natively — install it
sudo pacman -S --noconfirm --needed kscreen 2>/dev/null || true
echo "✔ Multi-monitor support configured (KScreen for Wayland, autorandr for X11)"

# ============================================================
# KDE Window Rules — Wayland compositor tweaks
# FIX #9: guard behind KDE install check
# ============================================================
echo "== Applying KDE window rules =="
if pacman -Q plasma-desktop &>/dev/null && command -v kwriteconfig6 &>/dev/null; then
    kwriteconfig6 --file kwinrc --group Compositing \
        --key Backend "OpenGL" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Compositing \
        --key Enabled "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-kwin4_effect_roundcorners \
        --key Enabled "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-kwin4_effect_roundcorners \
        --key Roundness "12" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Tiling \
        --key padding "8" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key ElectricBorderMaximize "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key ElectricBorderTiling "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key WindowSnapZone "16" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows \
        --key BorderSnapZone "16" 2>/dev/null || true
    kwriteconfig6 --file kdeglobals --group KDE \
        --key AnimationDurationFactor "0.5" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur \
        --key Enabled "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur \
        --key BlurStrength "6" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur \
        --key NoiseStrength "2" 2>/dev/null || true
    qdbus6 org.kde.KWin /KWin reconfigure 2>/dev/null || true
    echo "✔ KDE window rules applied (rounded corners, blur, snap, gaps)"
else
    echo "→ KDE not installed, skipping window rules"
fi

# ============================================================
# SDDM — Wayland-first
# FIX: always use Wayland for SDDM greeter (removed NVIDIA X11 fallback
#      since user explicitly wants Wayland; NVIDIA Wayland support has
#      improved significantly and works with the open kernel modules)
# ============================================================
echo "== Setting up SDDM login screen (Wayland) =="
sudo pacman -S --noconfirm --needed sddm qt6-declarative kwin plasma-workspace

BREEZE_DIR="/usr/share/sddm/themes/breeze"
sudo mkdir -p "$BREEZE_DIR"
sudo cp assets/skywareos.svg "$BREEZE_DIR/assets/logo.svg" 2>/dev/null || true

if [ -f assets/skywareos-wallpaper.png ]; then
    sudo cp assets/skywareos-wallpaper.png "$BREEZE_DIR/background.jpg"
elif command -v convert &>/dev/null && [ -f assets/skywareos.svg ]; then
    sudo rsvg-convert -w 300 -h 300 assets/skywareos.svg -o /tmp/skyware-logo-300.png 2>/dev/null || true
    sudo convert -size 1920x1080 xc:#111113 \
        /tmp/skyware-logo-300.png -gravity Center -composite \
        "$BREEZE_DIR/background.jpg" 2>/dev/null || true
fi

sudo tee "$BREEZE_DIR/theme.conf" > /dev/null << 'THEMEEOF'
[General]
background=/usr/share/sddm/themes/breeze/background.jpg
type=image
color=#111113
fontSize=10
showClock=true
THEMEEOF

if [ ! -f "$BREEZE_DIR/background.jpg" ]; then
    if command -v convert &>/dev/null; then
        sudo convert -size 1920x1080 xc:#111113 "$BREEZE_DIR/background.jpg" 2>/dev/null || true
    else
        sudo sed -i 's|background=.*||; s/type=image/type=color/' "$BREEZE_DIR/theme.conf"
    fi
fi

sudo mkdir -p /etc/sddm.conf.d
sudo tee /etc/sddm.conf.d/10-skywareos.conf > /dev/null << 'SDDMEOF'
[Theme]
Current=breeze

[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
SDDMEOF

sudo systemctl enable sddm
sudo systemctl disable gdm lightdm 2>/dev/null || true
echo "✔ SDDM configured (Wayland greeter)"

# ============================================================
# Timeshift
# ============================================================
echo "== Installing Timeshift =="
sudo pacman -S --noconfirm --needed timeshift
FS_TYPE=$(df -T / | awk 'NR==2{print $2}')
if [ "$FS_TYPE" = "btrfs" ]; then
    SNAPSHOT_TYPE="BTRFS"
else
    SNAPSHOT_TYPE="RSYNC"
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
  "exclude": [
    "+ /root/**",
    "- /home/**/.thumbnails",
    "- /home/**/.cache",
    "- /home/**/.local/share/Trash"
  ],
  "exclude-apps": []
}
TSEOF
echo "✔ Timeshift configured ($SNAPSHOT_TYPE mode)"

# ============================================================
# Done
# ============================================================
echo ""
echo "== SkywareOS setup complete =="
echo "   Reboot required to apply all changes."
