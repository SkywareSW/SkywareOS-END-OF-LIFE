#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════╗
# ║                    SkywareOS Setup Script v2.0                          ║
# ║                       Maroon Release — 2026                            ║
# ║                  Arch-based · Wayland-first · Ware                      ║
# ╚══════════════════════════════════════════════════════════════════════════╝

set -euo pipefail
IFS=$'\n\t'

# ── Constants ─────────────────────────────────────────────────────────────
readonly SKYWARE_VERSION="2.0"
readonly SKYWARE_RELEASE="Maroon"
readonly SKYWARE_GITHUB="https://github.com/SkywareSW/SkywareOS"
readonly LOGFILE="/var/log/skyware-setup.log"
readonly ASSETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assets"
readonly ORIGINAL_USER="${SUDO_USER:-$USER}"
readonly ORIGINAL_HOME="$(eval echo ~"$ORIGINAL_USER")"

# ── Colors ────────────────────────────────────────────────────────────────
RED='\e[31m'; GREEN='\e[32m'; YELLOW='\e[33m'; BLUE='\e[34m'
CYAN='\e[36m'; WHITE='\e[97m'; BOLD='\e[1m'; DIM='\e[2m'; RESET='\e[0m'

# ── Logging ───────────────────────────────────────────────────────────────
log()     { echo "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$LOGFILE" >/dev/null; }
log_err() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] $*" | tee -a "$LOGFILE" >/dev/null; }

phase()   { echo -e "\n${BOLD}${CYAN}══ $* ══${RESET}"; log "PHASE: $*"; }
ok()      { echo -e "  ${GREEN}✔${RESET}  $*"; log "OK: $*"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET}  $*"; log "WARN: $*"; }
fail()    { echo -e "  ${RED}✖${RESET}  $*"; log_err "FAIL: $*"; }
info()    { echo -e "  ${DIM}→${RESET}  $*"; }

# ── Safety checks ─────────────────────────────────────────────────────────
preflight() {
    phase "Pre-flight checks"

    # Must not run as root directly — use a wheel user + sudo
    if [[ "$EUID" -eq 0 && -z "$SUDO_USER" ]]; then
        fail "Run this script as a regular wheel user: bash skyware-setup.sh"
        exit 1
    fi

    # Ensure we're on an Arch-based system
    if ! command -v pacman &>/dev/null; then
        fail "pacman not found — this script requires an Arch-based distro."
        exit 1
    fi

    # Create log file with correct permissions
    sudo mkdir -p "$(dirname "$LOGFILE")"
    sudo touch "$LOGFILE"
    sudo chmod 666 "$LOGFILE"

    ok "Pre-flight passed (user: $ORIGINAL_USER)"
}

# ── Sudo: passwordless for wheel ─────────────────────────────────────────
configure_sudo() {
    phase "Configuring passwordless sudo"
    sudo bash -c "
        echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-skyware
        chmod 440 /etc/sudoers.d/10-skyware
    "
    # Verify syntax before leaving
    sudo visudo -c -f /etc/sudoers.d/10-skyware &>/dev/null \
        && ok "Passwordless sudo configured" \
        || { warn "Sudoers syntax check failed — removing file"; sudo rm /etc/sudoers.d/10-skyware; }

    # Remove requiretty if present
    sudo sed -i '/Defaults.*requiretty/s/^/#/' /etc/sudoers 2>/dev/null || true
}

# ── Pacman: sanitise config ───────────────────────────────────────────────
configure_pacman() {
    phase "Configuring pacman"

    # Remove defunct repos
    sudo sed -i \
        -e '/^\[community\]/,/^$/d' \
        -e '/^\[community-testing\]/,/^$/d' \
        -e '/^\[testing\]/,/^$/d' \
        /etc/pacman.conf

    # Enable useful options
    sudo python3 - << 'PYEOF'
with open("/etc/pacman.conf", "r") as f:
    c = f.read()
pairs = [
    ("#Color",             "Color"),
    ("#VerbosePkgLists",   "VerbosePkgLists"),
    ("#ILoveCandy",        "ILoveCandy"),
    ("#ParallelDownloads = 5", "ParallelDownloads = 15"),
    ("ParallelDownloads = 5",  "ParallelDownloads = 15"),
]
for old, new in pairs:
    c = c.replace(old, new)
with open("/etc/pacman.conf", "w") as f:
    f.write(c)
print("pacman.conf updated")
PYEOF

    # Enable multilib
    if ! grep -q "^\[multilib\]" /etc/pacman.conf; then
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
        ok "multilib enabled"
    fi

    # Keyring
    sudo pacman-key --init &>/dev/null || true
    sudo pacman-key --populate archlinux &>/dev/null || true

    # Sync
    sudo pacman -Syu --noconfirm --needed 2>&1 | tail -3
    ok "pacman configured (Color, ILoveCandy, 15 parallel downloads, multilib)"
}

# ── AUR helper: paru ─────────────────────────────────────────────────────
ensure_paru() {
    if command -v paru &>/dev/null; then return 0; fi
    info "Installing paru (AUR helper)..."
    sudo pacman -S --needed --noconfirm base-devel git
    local tmpdir
    tmpdir=$(mktemp -d)
    git clone https://aur.archlinux.org/paru.git "$tmpdir/paru"
    (cd "$tmpdir/paru" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"
    ok "paru installed"
}

# ── Base packages ─────────────────────────────────────────────────────────
install_base() {
    phase "Installing base packages"
    sudo pacman -S --noconfirm --needed \
        base-devel git curl wget \
        zsh zsh-autosuggestions zsh-syntax-highlighting \
        fastfetch btop htop \
        alacritty kitty \
        fzf zoxide eza bat fd ripgrep \
        tmux starship \
        pacman-contrib reflector \
        flatpak xdg-desktop-portal xdg-user-dirs \
        pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber \
        networkmanager network-manager-applet \
        polkit polkit-kde-agent \
        p7zip unrar zip unzip \
        imagemagick ghostscript librsvg \
        python python-pip nodejs npm \
        jq bc \
        man-db man-pages \
        2>&1 | tail -5

    # Flatpak remote
    if ! flatpak remote-list 2>/dev/null | grep -q flathub; then
        sudo flatpak remote-add --if-not-exists flathub \
            https://flathub.org/repo/flathub.flatpakrepo
    fi

    ok "Base packages installed"
}

# ── GPU driver detection ─────────────────────────────────────────────────
install_gpu_drivers() {
    phase "GPU driver detection & installation"

    local gpu_info
    gpu_info=$(lspci 2>/dev/null | grep -E "VGA|3D|Display" || echo "")

    if echo "$gpu_info" | grep -qi "NVIDIA"; then
        info "NVIDIA GPU detected"

        # Determine generation
        if echo "$gpu_info" | grep -qiE "RTX [2-9][0-9]{3}|RTX [0-9]{4}|GTX 16[0-9]{2}"; then
            # Turing+ → open kernel modules
            sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils nvidia-settings libva-nvidia-driver
            ok "NVIDIA open kernel modules installed (Turing+)"

        elif echo "$gpu_info" | grep -qiE "GTX (10|9[0-9]|8[0-9]|7[5-9])[0-9]{2}"; then
            # Maxwell/Pascal → legacy 470xx
            ensure_paru
            paru -S --noconfirm nvidia-470xx-dkms nvidia-470xx-utils 2>/dev/null \
                && ok "NVIDIA 470xx legacy drivers installed (Maxwell/Pascal)" \
                || warn "Could not install nvidia-470xx — install manually"

        elif echo "$gpu_info" | grep -qiE "GTX [67][0-9]{2}"; then
            # Kepler → 390xx
            ensure_paru
            paru -S --noconfirm nvidia-390xx-dkms nvidia-390xx-utils 2>/dev/null \
                && ok "NVIDIA 390xx legacy drivers installed (Kepler)" \
                || warn "Could not install nvidia-390xx — install manually"

        else
            # Unknown NVIDIA — try open first
            sudo pacman -S --noconfirm --needed nvidia-open nvidia-utils nvidia-settings 2>/dev/null \
                || sudo pacman -S --noconfirm --needed nvidia-dkms nvidia-utils nvidia-settings
            ok "NVIDIA drivers installed (unknown gen, tried open)"
        fi

        # Enable DRM modesetting for Wayland
        if [[ -f /etc/default/grub ]]; then
            sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="nvidia-drm.modeset=1 /' \
                /etc/default/grub 2>/dev/null || true
        fi

    elif echo "$gpu_info" | grep -qi "AMD"; then
        sudo pacman -S --noconfirm --needed xf86-video-amdgpu mesa vulkan-radeon \
            libva-mesa-driver mesa-vdpau lib32-mesa lib32-vulkan-radeon
        ok "AMD GPU drivers installed"

    elif echo "$gpu_info" | grep -qi "Intel"; then
        sudo pacman -S --noconfirm --needed mesa vulkan-intel \
            intel-media-driver libva-intel-driver lib32-mesa lib32-vulkan-intel
        ok "Intel GPU drivers installed"

    elif echo "$gpu_info" | grep -qi "VMware\|VirtualBox\|QEMU\|virtio"; then
        sudo pacman -S --noconfirm --needed mesa xf86-video-vmware open-vm-tools 2>/dev/null || \
            sudo pacman -S --noconfirm --needed mesa
        ok "Virtual machine GPU drivers installed"

    else
        warn "Could not identify GPU — installing mesa fallback"
        sudo pacman -S --noconfirm --needed mesa vulkan-swrast
    fi

    # Common Vulkan + VA-API
    sudo pacman -S --noconfirm --needed vulkan-icd-loader lib32-vulkan-icd-loader 2>/dev/null || true
}

# ── Desktop environment selection ────────────────────────────────────────
install_desktop() {
    phase "Desktop environment"

    # Check if a DE/greeter is already running
    local already=false
    for svc in sddm gdm lightdm; do
        systemctl is-enabled "$svc" &>/dev/null && already=true && break
    done
    for pkg in plasma-desktop gnome-shell hyprland; do
        pacman -Q "$pkg" &>/dev/null && already=true && break
    done

    if $already; then
        ok "Desktop already installed — skipping"
        return
    fi

    echo -e "\n${BOLD}Select desktop environment:${RESET}"
    echo "  1) KDE Plasma     (Wayland + X11 fallback)  [recommended]"
    echo "  2) GNOME          (Wayland)"
    echo "  3) Hyprland       (Wayland tiling)"
    echo "  4) Deepin         (X11/Wayland)"
    echo "  5) Skip"
    read -rp "  Choice [1-5]: " de_choice

    case "$de_choice" in
        1)
            sudo pacman -S --noconfirm \
                plasma kde-applications sddm plasma-x11-session xorg-xwayland
            sudo systemctl enable sddm
            ok "KDE Plasma installed"
            ;;
        2)
            sudo pacman -S --noconfirm gnome gnome-extra gdm xorg-xwayland
            sudo systemctl enable gdm
            ok "GNOME installed"
            ;;
        3)
            sudo pacman -S --noconfirm \
                hyprland xdg-desktop-portal-hyprland waybar wofi kitty \
                grim slurp wl-clipboard polkit-kde-agent sddm \
                pipewire wireplumber thunar nwg-look
            sudo systemctl enable sddm
            _setup_hyprland_defaults
            ok "Hyprland installed"
            ;;
        4)
            sudo pacman -S --noconfirm deepin deepin-kwin deepin-extra lightdm xorg-xwayland
            sudo systemctl enable lightdm
            ok "Deepin installed"
            ;;
        *) info "Skipping DE installation" ;;
    esac
}

_setup_hyprland_defaults() {
    mkdir -p "$ORIGINAL_HOME/.config/hypr"
    cat > "$ORIGINAL_HOME/.config/hypr/hyprland.conf" << 'HYPREOF'
# SkywareOS Hyprland config
monitor=,preferred,auto,auto

exec-once = waybar
exec-once = /usr/lib/polkit-kde-authentication-agent-1

input {
    kb_layout = us
    follow_mouse = 1
    touchpad { natural_scroll = yes }
    sensitivity = 0
}

general {
    gaps_in = 6
    gaps_out = 12
    border_size = 2
    col.active_border = rgba(a0a0b0ff) rgba(c8c8dcff) 45deg
    col.inactive_border = rgba(2a2a2f88)
    layout = dwindle
    allow_tearing = false
}

decoration {
    rounding = 10
    blur { enabled = yes; size = 8; passes = 2 }
    drop_shadow = yes
    shadow_range = 12
    shadow_render_power = 3
}

animations {
    enabled = yes
    bezier = skyware, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 5, skyware
    animation = windowsOut, 1, 4, default, popin 80%
    animation = fade, 1, 6, default
    animation = workspaces, 1, 5, skyware
}

dwindle { pseudotile = yes; preserve_split = yes }

$mod = SUPER
bind = $mod, Return, exec, kitty
bind = $mod, Q, killactive
bind = $mod SHIFT, E, exit
bind = $mod, E, exec, thunar
bind = $mod, V, togglefloating
bind = $mod, D, exec, wofi --show drun
bind = $mod, F, fullscreen
bind = $mod, P, pseudo
bind = $mod, J, togglesplit
bind = $mod, 1, workspace, 1
bind = $mod, 2, workspace, 2
bind = $mod, 3, workspace, 3
bind = $mod, 4, workspace, 4
bind = $mod, 5, workspace, 5
bind = $mod SHIFT, 1, movetoworkspace, 1
bind = $mod SHIFT, 2, movetoworkspace, 2
bind = $mod SHIFT, 3, movetoworkspace, 3
bindm = $mod, mouse:272, movewindow
bindm = $mod, mouse:273, resizewindow
HYPREOF
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$ORIGINAL_HOME/.config/hypr"
}

# ── SDDM (Wayland greeter) ────────────────────────────────────────────────
configure_sddm() {
    phase "Configuring SDDM (Wayland greeter)"

    if ! pacman -Q sddm &>/dev/null; then
        warn "SDDM not installed — skipping"
        return
    fi

    sudo mkdir -p /etc/sddm.conf.d
    sudo tee /etc/sddm.conf.d/10-skywareos.conf > /dev/null << 'EOF'
[Theme]
Current=breeze

[General]
DisplayServer=wayland
GreeterEnvironment=QT_WAYLAND_SHELL_INTEGRATION=layer-shell

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
EOF

    # Build breeze background from logo if assets available
    local breeze_dir="/usr/share/sddm/themes/breeze"
    sudo mkdir -p "$breeze_dir/assets"

    if [[ -f "$ASSETS_DIR/skywareos.svg" ]]; then
        sudo cp "$ASSETS_DIR/skywareos.svg" "$breeze_dir/assets/logo.svg"
        if command -v convert &>/dev/null; then
            sudo rsvg-convert -w 300 -h 300 "$ASSETS_DIR/skywareos.svg" -o /tmp/sw-logo.png 2>/dev/null || true
            sudo convert -size 1920x1080 xc:#111113 \
                /tmp/sw-logo.png -gravity Center -composite \
                "$breeze_dir/background.jpg" 2>/dev/null || true
            rm -f /tmp/sw-logo.png
        fi
    elif command -v convert &>/dev/null; then
        sudo convert -size 1920x1080 xc:#111113 "$breeze_dir/background.jpg" 2>/dev/null || true
    fi

    sudo tee "$breeze_dir/theme.conf" > /dev/null << 'EOF'
[General]
background=/usr/share/sddm/themes/breeze/background.jpg
type=image
color=#111113
fontSize=10
showClock=true
clockFormat=hh:mm AP
EOF

    ok "SDDM configured (Wayland)"
}

# ── Plymouth bootsplash ───────────────────────────────────────────────────
configure_plymouth() {
    phase "Plymouth bootsplash"

    sudo pacman -S --noconfirm --needed plymouth librsvg

    local theme_dir="/usr/share/plymouth/themes/skywareos"
    sudo mkdir -p "$theme_dir"

    # Generate logo images
    if [[ -f "$ASSETS_DIR/skywareos.svg" ]]; then
        sudo rsvg-convert -w 512 -h 512 "$ASSETS_DIR/skywareos.svg" -o "$theme_dir/logo.png" 2>/dev/null || true
        sudo rsvg-convert -w 128 -h 128 "$ASSETS_DIR/skywareos.svg" -o "$theme_dir/logo-small.png" 2>/dev/null || true
        ok "Plymouth logo generated from SVG"
    else
        warn "assets/skywareos.svg not found — Plymouth will use text-only splash"
    fi

    sudo tee "$theme_dir/skywareos.plymouth" > /dev/null << 'EOF'
[Plymouth Theme]
Name=SkywareOS
Description=SkywareOS Boot Splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/skywareos
ScriptFile=/usr/share/plymouth/themes/skywareos/skywareos.script
EOF

    sudo tee "$theme_dir/skywareos.script" > /dev/null << 'EOF'
Window.SetBackgroundTopColor(0.067, 0.067, 0.075);
Window.SetBackgroundBottomColor(0.040, 0.040, 0.048);

logo.image  = Image("logo.png");
logo.sprite = Sprite(logo.image);
logo.x = Window.GetWidth()  / 2 - logo.image.GetWidth()  / 2;
logo.y = Window.GetHeight() / 2 - logo.image.GetHeight() / 2 - 48;
logo.sprite.SetPosition(logo.x, logo.y, 0);

bar_h = 3;
bar_w = Math.Int(Window.GetWidth() * 0.38);
bar_x = Window.GetWidth()  / 2 - bar_w / 2;
bar_y = Window.GetHeight() - 64;

track_img = Image.Scale(Image.New(1,1), bar_w, bar_h);
track_img.FillWithColor(0.16, 0.16, 0.18, 1.0);
track = Sprite(track_img);
track.SetPosition(bar_x, bar_y, 1);

fill.width = 1;
fill.img   = Image.Scale(Image.New(1,1), fill.width, bar_h);
fill.sprite = Sprite(fill.img);
fill.sprite.SetPosition(bar_x, bar_y, 2);

fun boot_progress_callback(duration, progress) {
    nw = Math.Int(bar_w * progress);
    if (nw < 2) nw = 2;
    if (nw != fill.width) {
        fill.width = nw;
        fill.img   = Image.Scale(Image.New(1,1), fill.width, bar_h);
        fill.img.FillWithColor(0.627, 0.627, 0.722, 1.0);
        fill.sprite.SetImage(fill.img);
    }
}
Plymouth.SetBootProgressFunction(boot_progress_callback);

fun quit_callback() {
    logo.sprite.SetOpacity(0);
    fill.sprite.SetOpacity(0);
    track.SetOpacity(0);
}
Plymouth.SetQuitFunction(quit_callback);
EOF

    # Inject plymouth hook into mkinitcpio
    if grep -q "^HOOKS=" /etc/mkinitcpio.conf; then
        if ! grep -q "plymouth" /etc/mkinitcpio.conf; then
            sudo sed -i '/^HOOKS=/ s/udev/udev plymouth/' /etc/mkinitcpio.conf
            ok "Plymouth hook added to mkinitcpio"
        fi
    fi

    sudo mkinitcpio -P 2>&1 | tail -3
    sudo plymouth-set-default-theme -R skywareos
    ok "Plymouth theme set: skywareos"
}

# ── Limine bootloader branding ────────────────────────────────────────────
configure_limine() {
    phase "Limine bootloader branding"

    local conf=""
    for candidate in \
        /boot/limine.conf \
        /efi/limine.conf \
        /boot/efi/limine.conf; do
        [[ -f "$candidate" ]] && { conf="$candidate"; break; }
    done

    # Wider search if not found in canonical paths
    if [[ -z "$conf" ]]; then
        conf=$(find /boot /efi /boot/efi -maxdepth 5 -iname "limine.conf" 2>/dev/null | head -1 || true)
    fi

    if [[ -z "$conf" ]]; then
        warn "Limine config not found — skipping bootloader branding"
        return
    fi

    info "Limine config: $conf"
    sudo cp "$conf" "$conf.bak"

    sudo sed -i -E 's/^([[:space:]]*label[[:space:]]*=[[:space:]]*).*/\1SkywareOS/' "$conf"
    sudo sed -i -E '/^[[:space:]]*cmdline/{ /quiet/! s/$/ quiet splash apparmor=1 security=apparmor nvidia-drm.modeset=1/ }' "$conf"

    ok "Limine entries branded to SkywareOS"
}

# ── Fastfetch configuration ───────────────────────────────────────────────
configure_fastfetch() {
    phase "Fastfetch"

    local ff_dir="$ORIGINAL_HOME/.config/fastfetch"
    mkdir -p "$ff_dir/logos"

    cat > "$ff_dir/logos/skyware.txt" << 'EOF'
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

    cat > "$ff_dir/config.jsonc" << 'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  "logo": {
    "type": "file",
    "source": "~/.config/fastfetch/logos/skyware.txt",
    "padding": { "top": 1, "left": 2 }
  },
  "modules": [
    "title", "separator",
    { "type": "os",     "format": "SkywareOS {0} ({1})" },
    "kernel", "uptime", "packages", "shell",
    "display", "wm",
    "cpu", "gpu", "memory", "disk",
    "localip", "battery"
  ]
}
EOF

    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$ff_dir"
    ok "Fastfetch configured"
}

# ── OS release branding ───────────────────────────────────────────────────
configure_os_release() {
    phase "OS release branding"

    local release_content
    release_content=$(cat << EOF
NAME="SkywareOS"
PRETTY_NAME="SkywareOS Maroon 2.0"
ID=skywareos
ID_LIKE=arch
VERSION="${SKYWARE_VERSION}"
VERSION_ID="Maroon_2-0"
HOME_URL="${SKYWARE_GITHUB}"
BUG_REPORT_URL="${SKYWARE_GITHUB}/issues"
LOGO=skywareos
ANSI_COLOR="1;36"
EOF
)
    echo "$release_content" | sudo tee /etc/os-release > /dev/null
    echo "$release_content" | sudo tee /usr/lib/os-release > /dev/null

    # Machine info
    sudo hostnamectl set-hostname "skywareos" 2>/dev/null || true
    ok "OS release branded to SkywareOS Maroon 2.0"
}

# ── Shell: Zsh + Starship + plugins ──────────────────────────────────────
configure_shell() {
    phase "Shell (zsh + starship + plugins)"

    sudo pacman -S --noconfirm --needed \
        zsh zsh-autosuggestions zsh-syntax-highlighting \
        fzf zoxide eza bat fd ripgrep

    # Change shell for original user
    sudo chsh -s /bin/zsh "$ORIGINAL_USER" 2>/dev/null || \
        sudo usermod -s /bin/zsh "$ORIGINAL_USER" || true

    # Install Starship as user (no root)
    if ! command -v starship &>/dev/null; then
        sudo -u "$ORIGINAL_USER" bash -c \
            'curl -sS https://starship.rs/install.sh | sh -s -- -y' 2>&1 | tail -3
    fi

    cat > "$ORIGINAL_HOME/.zshrc" << 'ZSHEOF'
# ──────────── SkywareOS zshrc ────────────────────────────────────────────

# Plugins
[[ -f /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
[[ -f /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]] && \
    source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

# fzf
[[ -f /usr/share/fzf/key-bindings.zsh  ]] && source /usr/share/fzf/key-bindings.zsh
[[ -f /usr/share/fzf/completion.zsh    ]] && source /usr/share/fzf/completion.zsh
export FZF_DEFAULT_OPTS="
  --color=bg+:#1f1f23,bg:#111113,spinner:#a0a0b0,hl:#60a5fa
  --color=fg:#e2e2ec,header:#7a7a8a,info:#a0a0b0,pointer:#c8c8dc
  --color=marker:#4ade80,fg+:#e2e2ec,prompt:#a0a0b0,hl+:#60a5fa
  --border=rounded --prompt='  ' --pointer='▶' --marker='✔'
"

# zoxide (smarter cd)
command -v zoxide &>/dev/null && eval "$(zoxide init zsh)" && alias cd='z'

# Better ls
command -v eza &>/dev/null && {
    alias ls='eza --icons --group-directories-first'
    alias ll='eza -lah --icons --group-directories-first --git'
    alias la='eza -a --icons'
    alias tree='eza --tree --icons --level=3'
}

# Better cat
command -v bat &>/dev/null && alias cat='bat --style=plain --paging=never'

# Dotfiles bare repo
alias dotfiles='git --git-dir=$HOME/.dotfiles --work-tree=$HOME'

# Quick ware shortcuts
alias wi='ware install'
alias wr='ware remove'
alias wu='ware update'
alias ws='ware search'

# History
HISTSIZE=50000
SAVEHIST=50000
HISTFILE=~/.zsh_history
setopt SHARE_HISTORY HIST_IGNORE_DUPS HIST_IGNORE_SPACE HIST_VERIFY

# Completion
autoload -Uz compinit && compinit -C
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Word movement
autoload -Uz select-word-style && select-word-style bash
bindkey '^[[1;5C' forward-word
bindkey '^[[1;5D' backward-word

# Fastfetch on new terminal (suppress in scripts/pipes)
[[ -o interactive ]] && [[ -z "$TMUX_PANE" ]] && command -v fastfetch &>/dev/null && fastfetch

# Starship prompt
command -v starship &>/dev/null && eval "$(starship init zsh)"
ZSHEOF

    cat > "$ORIGINAL_HOME/.config/starship.toml" << 'EOF'
add_newline = false
command_timeout = 750

[character]
success_symbol = "[➜](bold gray)"
error_symbol   = "[✗](bold red)"

[directory]
truncation_length = 4
style = "dim white"
truncation_symbol = "…/"

[git_branch]
symbol = " "
style = "bright-black"

[git_status]
style = "bright-black"
conflicted = "✖"
ahead      = "⇡${count}"
behind     = "⇣${count}"
staged     = "+${count}"
deleted    = "✘${count}"
renamed    = "»${count}"
modified   = "!${count}"
untracked  = "?${count}"

[nodejs]
symbol = " "
style = "dim green"

[python]
symbol = " "
style = "dim yellow"

[rust]
symbol = " "
style = "dim red"

[time]
disabled = false
style = "dim white"
format = "[$time]($style) "
time_format = "%H:%M"
EOF

    chown "$ORIGINAL_USER:$ORIGINAL_USER" \
        "$ORIGINAL_HOME/.zshrc" \
        "$ORIGINAL_HOME/.config/starship.toml" 2>/dev/null || true
    ok "Zsh + Starship configured"
}

# ── btop theme ────────────────────────────────────────────────────────────
configure_btop() {
    phase "btop"
    local btop_dir="$ORIGINAL_HOME/.config/btop"
    mkdir -p "$btop_dir/themes"

    cat > "$btop_dir/themes/skyware.theme" << 'EOF'
theme[main_bg]="#111113"
theme[main_fg]="#e2e2ec"
theme[title]="#c8c8dc"
theme[hi_fg]="#a0a0b0"
theme[selected_bg]="#1f1f23"
theme[inactive_fg]="#4a4a58"
theme[graph_text]="#7a7a8a"
theme[meter_bg]="#18181b"
theme[proc_misc]="#a0a0b0"
theme[cpu_box]="#2a2a2f"
theme[download_box]="#2a2a2f"
theme[upload_box]="#2a2a2f"
theme[storage_box]="#2a2a2f"
theme[net_box]="#2a2a2f"
theme[mem_box]="#2a2a2f"
theme[proc_box]="#2a2a2f"
theme[div_line]="#2a2a2f"
theme[temp_start]="#4ade80"
theme[temp_mid]="#facc15"
theme[temp_end]="#f87171"
theme[cpu_start]="#60a5fa"
theme[cpu_mid]="#a78bfa"
theme[cpu_end]="#f87171"
theme[free_start]="#4ade80"
theme[free_mid]="#60a5fa"
theme[free_end]="#a78bfa"
theme[cached_start]="#4ade80"
theme[cached_mid]="#60a5fa"
theme[cached_end]="#a78bfa"
theme[available_start]="#4ade80"
theme[available_mid]="#60a5fa"
theme[available_end]="#a78bfa"
theme[used_start]="#facc15"
theme[used_mid]="#fb923c"
theme[used_end]="#f87171"
theme[download_start]="#4ade80"
theme[download_mid]="#60a5fa"
theme[download_end]="#a78bfa"
theme[upload_start]="#facc15"
theme[upload_mid]="#fb923c"
theme[upload_end]="#f87171"
theme[process_start]="#4ade80"
theme[process_mid]="#60a5fa"
theme[process_end]="#a78bfa"
EOF

    cat > "$btop_dir/btop.conf" << 'EOF'
color_theme = "skyware"
theme_background = True
truecolor = True
force_tty = False
graph_symbol = "braille"
graph_symbol_cpu = "default"
graph_symbol_mem = "default"
graph_symbol_net = "default"
graph_symbol_proc = "default"
shown_boxes = "cpu mem net proc"
update_ms = 2000
proc_sorting = "cpu lazy"
proc_reversed = False
proc_tree = False
proc_colors = True
proc_gradient = True
proc_per_core = False
proc_mem_bytes = True
proc_cpu_graphs = True
proc_info_smaps = False
proc_left = False
cpu_graph_upper = "total"
cpu_graph_lower = "total"
cpu_invert_lower = True
cpu_single_graph = False
cpu_bottom = False
show_uptime = True
check_temp = True
cpu_sensor = "Auto"
show_coretemp = True
cpu_core_map = ""
temp_scale = "celsius"
base_10_sizes = False
show_cpu_freq = True
clock_format = "%H:%M"
background_update = True
custom_cpu_name = ""
disks_filter = ""
mem_graphs = True
mem_below_net = False
show_swap = True
swap_disk = True
show_disks = True
only_physical = True
use_fstab = False
show_io_stat = True
io_mode = False
io_graph_combined = False
io_rx_graph_color = "#60a5fa"
io_tx_graph_color = "#facc15"
net_download = "10M"
net_upload = "10M"
net_auto = True
net_sync = False
net_iface = ""
show_battery = True
selected_battery = "Auto"
log_level = "WARNING"
EOF

    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$btop_dir"
    ok "btop configured with Skyware theme"
}

# ── tmux ──────────────────────────────────────────────────────────────────
configure_tmux() {
    phase "tmux"
    sudo pacman -S --noconfirm --needed tmux

    cat > "$ORIGINAL_HOME/.tmux.conf" << 'EOF'
# ── SkywareOS tmux.conf ───────────────────────────────────────────────────
unbind C-b
set  -g prefix C-Space
bind    C-Space send-prefix

set -g  mouse on
set -g  history-limit 100000
set -g  base-index 1
setw -g pane-base-index 1
set -g  renumber-windows on
set -sg escape-time 0
set -g  focus-events on
set -g  default-terminal "tmux-256color"
set -ag terminal-overrides ",*256col*:Tc"

# Status bar
set -g status on
set -g status-position bottom
set -g status-interval 5
set -g status-style "bg=#0e0e10,fg=#a0a0b0"
set -g status-left-length 40
set -g status-right-length 80
set -g status-left  "#[bg=#1f1f23,fg=#c8c8dc,bold] 󰣇 SkywareOS #[bg=#0e0e10,fg=#1f1f23]#[default] "
set -g status-right "#[fg=#2a2a2f]#[fg=#7a7a8a,bg=#1f1f23] %H:%M  %d %b  #H #[default]"

setw -g window-status-current-format "#[bg=#2a2a2f,fg=#c8c8dc,bold] #I:#W #[default]"
setw -g window-status-format         "#[fg=#4a4a58] #I:#W "
setw -g window-status-separator      " "

# Pane borders
set -g pane-border-style        "fg=#2a2a2f"
set -g pane-active-border-style "fg=#a0a0b0"

# Splits
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
unbind '"'; unbind '%'

# Navigation (vim-style)
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -r H resize-pane -L 5
bind -r J resize-pane -D 5
bind -r K resize-pane -U 5
bind -r L resize-pane -R 5

bind r source-file ~/.tmux.conf \; display "Config reloaded ✔"
bind N new-window -c "#{pane_current_path}"

# Copy mode (vi)
setw -g mode-keys vi
bind -T copy-mode-vi v   send -X begin-selection
bind -T copy-mode-vi y   send -X copy-selection-and-cancel
bind -T copy-mode-vi C-v send -X rectangle-toggle
EOF

    chown "$ORIGINAL_USER:$ORIGINAL_USER" "$ORIGINAL_HOME/.tmux.conf"
    ok "tmux configured"
}

# ── Flatpak apps ──────────────────────────────────────────────────────────
install_flatpak_apps() {
    phase "Flatpak apps"
    for app in \
        com.discordapp.Discord \
        com.spotify.Client \
        com.valvesoftware.Steam \
        org.videolan.VLC \
        com.github.tchx84.Flatseal; do
        flatpak install -y --noninteractive flathub "$app" 2>&1 | tail -2 || \
            warn "Could not install flatpak: $app"
    done
    ok "Flatpak apps installed"
}

# ── Security: firewall + fail2ban + AppArmor + SSH hardening ─────────────
configure_security() {
    phase "Security hardening"

    # Firewall
    sudo pacman -S --noconfirm --needed ufw fail2ban
    sudo systemctl enable --now ufw
    sudo ufw --force enable
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo systemctl enable fail2ban
    ok "UFW firewall enabled (deny in, allow out)"

    # AppArmor
    sudo pacman -S --noconfirm --needed apparmor
    sudo systemctl enable apparmor
    ok "AppArmor enabled"

    # SSH hardening
    sudo pacman -S --noconfirm --needed openssh
    sudo mkdir -p /etc/ssh/sshd_config.d
    sudo tee /etc/ssh/sshd_config.d/99-skywareos.conf > /dev/null << 'EOF'
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
    ok "SSH hardened"

    # USBGuard
    sudo pacman -S --noconfirm --needed usbguard
    sudo usbguard generate-policy 2>/dev/null | sudo tee /etc/usbguard/rules.conf >/dev/null || true
    sudo systemctl enable usbguard
    sudo systemctl start usbguard 2>/dev/null || true
    ok "USBGuard enabled"

    # Polkit rule for wheel group
    sudo mkdir -p /etc/polkit-1/rules.d
    sudo tee /etc/polkit-1/rules.d/10-skyware.rules > /dev/null << 'EOF'
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
EOF
    ok "Polkit rule configured for wheel group"

    # Automatic security updates (weekly)
    sudo tee /etc/systemd/system/skyware-security-update.service > /dev/null << 'EOF'
[Unit]
Description=SkywareOS Automatic Security Update
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/pacman -Syu --noconfirm --noprogressbar --ask 4
ExecStartPost=/usr/bin/flatpak update -y
StandardOutput=journal
StandardError=journal
EOF
    sudo tee /etc/systemd/system/skyware-security-update.timer > /dev/null << 'EOF'
[Unit]
Description=SkywareOS Weekly Security Update

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h

[Install]
WantedBy=timers.target
EOF
    sudo systemctl enable skyware-security-update.timer
    ok "Weekly auto-update timer enabled"

    # Pacman keyring hook
    sudo mkdir -p /etc/pacman.d/hooks
    sudo tee /etc/pacman.d/hooks/keyring-refresh.hook > /dev/null << 'EOF'
[Trigger]
Operation = Upgrade
Type = Package
Target = archlinux-keyring

[Action]
Description = Refreshing pacman keyring...
When = PostTransaction
Exec = /usr/bin/pacman-key --refresh-keys
EOF
    ok "Pacman keyring auto-refresh hook installed"
}

# ── KDE theme + configuration ─────────────────────────────────────────────
configure_kde() {
    if ! pacman -Q plasma-desktop &>/dev/null || ! command -v kwriteconfig6 &>/dev/null; then
        return
    fi

    phase "KDE Plasma configuration"

    # Install logo SVG
    if [[ -f "$ASSETS_DIR/skywareos.svg" ]]; then
        sudo cp "$ASSETS_DIR/skywareos.svg" /usr/share/icons/hicolor/scalable/apps/skywareos.svg
        sudo cp "$ASSETS_DIR/skywareos.svg" /usr/share/icons/hicolor/scalable/apps/skywareos-start.svg
        sudo gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
        sudo kbuildsycoca6 --noincremental 2>/dev/null || true
    fi

    # Color scheme
    mkdir -p "$ORIGINAL_HOME/.local/share/color-schemes"
    cat > "$ORIGINAL_HOME/.local/share/color-schemes/SkywareOS.colors" << 'EOF'
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
contrast=5

[WM]
activeBackground=17,17,19
activeBlend=17,17,19
activeForeground=226,226,236
inactiveBackground=14,14,16
inactiveBlend=14,14,16
inactiveForeground=74,74,88
EOF

    # KDE settings
    kwriteconfig6 --file kdeglobals   --group General       --key ColorScheme     "SkywareOS"   2>/dev/null || true
    kwriteconfig6 --file kwinrc       --group org.kde.kdecoration2 --key theme    "org.kde.breeze" 2>/dev/null || true
    kwriteconfig6 --file kdeglobals   --group KDE           --key widgetStyle     "Breeze"      2>/dev/null || true
    kwriteconfig6 --file plasmarc     --group Theme         --key name            "breeze-dark" 2>/dev/null || true
    kwriteconfig6 --file kdeglobals   --group KDE           --key AnimationDurationFactor "0.5" 2>/dev/null || true
    # Compositing
    kwriteconfig6 --file kwinrc --group Compositing --key Backend  "OpenGL" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Compositing --key Enabled  "true"   2>/dev/null || true
    # Blur
    kwriteconfig6 --file kwinrc --group Effect-blur --key Enabled       "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur --key BlurStrength   "6"   2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Effect-blur --key NoiseStrength  "2"   2>/dev/null || true
    # Window snapping
    kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderMaximize "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderTiling   "true" 2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows --key WindowSnapZone         "16"   2>/dev/null || true
    kwriteconfig6 --file kwinrc --group Windows --key BorderSnapZone         "16"   2>/dev/null || true

    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" \
        "$ORIGINAL_HOME/.local/share/color-schemes" 2>/dev/null || true
    ok "KDE Plasma configured (SkywareOS color scheme, blur, snap)"
}

# ── Cursor theme ─────────────────────────────────────────────────────────
configure_cursor() {
    phase "Cursor theme"
    ensure_paru
    paru -S --noconfirm bibata-cursor-theme 2>/dev/null || {
        warn "bibata-cursor-theme not in AUR, trying direct download"
        local url="https://github.com/ful1e5/Bibata_Cursor/releases/latest/download/Bibata-Modern-Classic.tar.xz"
        curl -L "$url" -o /tmp/bibata.tar.xz 2>/dev/null && \
            sudo tar -xf /tmp/bibata.tar.xz -C /usr/share/icons/ && \
            rm -f /tmp/bibata.tar.xz || warn "Cursor theme download failed"
    }

    sudo mkdir -p /usr/share/icons/default
    echo -e "[Icon Theme]\nInherits=Bibata-Modern-Classic" | sudo tee /usr/share/icons/default/index.theme > /dev/null

    mkdir -p "$ORIGINAL_HOME/.icons/default"
    echo -e "[Icon Theme]\nInherits=Bibata-Modern-Classic" > "$ORIGINAL_HOME/.icons/default/index.theme"

    if pacman -Q plasma-desktop &>/dev/null && command -v kwriteconfig6 &>/dev/null; then
        kwriteconfig6 --file kcminputrc --group Mouse --key cursorTheme "Bibata-Modern-Classic" 2>/dev/null || true
        kwriteconfig6 --file kcminputrc --group Mouse --key cursorSize   "24"                   2>/dev/null || true
    fi

    ok "Cursor theme: Bibata Modern Classic"
}

# ── MOTD ──────────────────────────────────────────────────────────────────
configure_motd() {
    phase "MOTD"

    sudo pacman -S --noconfirm --needed figlet 2>/dev/null || true

    sudo tee /etc/profile.d/skyware-motd.sh > /dev/null << 'MOTDEOF'
#!/bin/bash
[[ $- != *i* ]] && return
[[ -n "$MOTD_SHOWN" ]] && return
export MOTD_SHOWN=1

GRAY="\e[38;5;245m"; LGRAY="\e[38;5;250m"; WHITE="\e[97m"
GREEN="\e[92m"; YELLOW="\e[93m"; RED="\e[91m"; RESET="\e[0m"; BOLD="\e[1m"

echo ""
echo -e "${GRAY}      @@@@@@@-         +@@@@@@.     ${RESET}"
echo -e "${GRAY}    %@@@@@@@@@@=      @@@@@@@@@@    ${RESET}    ${BOLD}${WHITE}SkywareOS${RESET} ${GRAY}Maroon 2.0${RESET}"
echo -e "${GRAY}   @@@@     @@@@@      -     #@@@   ${RESET}    ${LGRAY}────────────────────────────────${RESET}"
echo -e "${GRAY}  :@@*        @@@@             @@@  ${RESET}    ${GRAY}Kernel   ${RESET}$(uname -r)"
echo -e "${GRAY}  @@@          @@@@            @@@  ${RESET}    ${GRAY}Uptime   ${RESET}$(uptime -p 2>/dev/null | sed 's/up //' || echo '—')"
echo -e "${GRAY}  @@@           @@@@           %@@  ${RESET}    ${GRAY}Shell    ${RESET}${SHELL##*/}"
echo -e "${GRAY}  @@@            @@@@          @@@  ${RESET}    ${GRAY}Packages ${RESET}$(pacman -Q 2>/dev/null | wc -l) pacman"
echo -e "${GRAY}  :@@@            @@@@:        @@@  ${RESET}    ${GRAY}Memory   ${RESET}$(free -h | awk '/Mem:/{print $3"/"$2}')"
echo -e "${GRAY}   @@@@     =      @@@@@     %@@@   ${RESET}    ${GRAY}Disk     ${RESET}$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
echo -e "${GRAY}    @@@@@@@@@@       @@@@@@@@@@@    ${RESET}    ${GRAY}Session  ${RESET}${XDG_SESSION_TYPE:-tty}"
echo -e "${GRAY}      @@@@@@+          %@@@@@@      ${RESET}    ${GRAY}DE       ${RESET}${XDG_CURRENT_DESKTOP:-—}"
echo ""

UPDATES=$(checkupdates 2>/dev/null | wc -l)
[[ "$UPDATES" -gt 0 ]] && \
    echo -e "  ${YELLOW}⚠${RESET}  ${YELLOW}${UPDATES} update(s) available${RESET} — ${GRAY}ware update${RESET}\n"

systemctl is-active ufw >/dev/null 2>&1 || \
    echo -e "  ${RED}✖${RESET}  ${RED}Firewall inactive${RESET} — ${GRAY}sudo ufw enable${RESET}\n"
MOTDEOF

    sudo chmod +x /etc/profile.d/skyware-motd.sh
    sudo rm -f /etc/motd
    ok "MOTD installed"
}

# ── Bluetooth ─────────────────────────────────────────────────────────────
configure_bluetooth() {
    phase "Bluetooth"
    sudo pacman -S --noconfirm --needed bluez bluez-utils blueman
    sudo systemctl enable bluetooth

    sudo mkdir -p /etc/bluetooth
    if [[ ! -f /etc/bluetooth/main.conf ]]; then
        printf '[Policy]\nAutoEnable=true\n' | sudo tee /etc/bluetooth/main.conf > /dev/null
    else
        grep -q "AutoEnable" /etc/bluetooth/main.conf \
            && sudo sed -i 's/AutoEnable=false/AutoEnable=true/' /etc/bluetooth/main.conf \
            || printf '\n[Policy]\nAutoEnable=true\n' | sudo tee -a /etc/bluetooth/main.conf > /dev/null
    fi
    ok "Bluetooth configured"
}

# ── Printing (CUPS) ───────────────────────────────────────────────────────
configure_printing() {
    phase "Printing (CUPS)"
    sudo pacman -S --noconfirm --needed \
        cups cups-pdf system-config-printer \
        gutenprint foomatic-db foomatic-db-engine \
        nss-mdns avahi

    sudo systemctl disable cups.service 2>/dev/null || true
    sudo systemctl enable cups.socket cups.service
    sudo systemctl disable avahi-daemon.service 2>/dev/null || true
    sudo systemctl enable avahi-daemon.socket avahi-daemon.service

    if ! grep -q "mdns_minimal" /etc/nsswitch.conf; then
        sudo sed -i 's/^hosts:.*/hosts: mymachines mdns_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] files myhostname dns/' \
            /etc/nsswitch.conf
    fi
    ok "CUPS printing enabled (socket-activated)"
}

# ── Touchpad gestures ─────────────────────────────────────────────────────
configure_gestures() {
    phase "Touchpad gestures"
    sudo pacman -S --noconfirm --needed libinput

    ensure_paru
    paru -S --noconfirm libinput-gestures 2>/dev/null || {
        local tmpdir; tmpdir=$(mktemp -d)
        git clone https://github.com/bulletmark/libinput-gestures.git "$tmpdir/lg"
        (cd "$tmpdir/lg" && sudo make install)
        rm -rf "$tmpdir"
    }

    sudo gpasswd -a "$ORIGINAL_USER" input

    cat > "$ORIGINAL_HOME/.config/libinput-gestures.conf" << 'EOF'
# SkywareOS gesture config (Wayland via KWin D-Bus)
gesture swipe left  3  qdbus6 org.kde.KWin /KWin nextDesktop
gesture swipe right 3  qdbus6 org.kde.KWin /KWin previousDesktop
gesture swipe up    3  qdbus6 org.kde.KWin /KWin toggleOverview
gesture swipe down  3  qdbus6 org.kde.KWin /KWin showDesktop
gesture swipe up    4  qdbus6 org.kde.KWin /KWin showAllWindowsFromCurrentApplication
gesture pinch in    2  qdbus6 org.kde.KWin /KWin Zoom
gesture pinch out   2  qdbus6 org.kde.KWin /KWin UnZoom
EOF

    mkdir -p "$ORIGINAL_HOME/.config/autostart"
    cat > "$ORIGINAL_HOME/.config/autostart/libinput-gestures.desktop" << 'EOF'
[Desktop Entry]
Name=libinput-gestures
Exec=libinput-gestures-setup start
Type=Application
X-GNOME-Autostart-enabled=true
EOF

    libinput-gestures-setup autostart start 2>/dev/null || true
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" \
        "$ORIGINAL_HOME/.config/libinput-gestures.conf" \
        "$ORIGINAL_HOME/.config/autostart/libinput-gestures.desktop" 2>/dev/null || true
    ok "Touchpad gestures configured (KWin D-Bus)"
}

# ── Timezone + locale ─────────────────────────────────────────────────────
configure_locale() {
    phase "Timezone & locale"

    local tz
    tz=$(curl -s --max-time 5 "https://ipapi.co/timezone" 2>/dev/null || echo "")
    if [[ -n "$tz" ]] && timedatectl list-timezones | grep -qx "$tz"; then
        sudo timedatectl set-timezone "$tz"
        ok "Timezone: $tz (auto-detected)"
    else
        warn "Could not auto-detect timezone — using UTC"
        sudo timedatectl set-timezone UTC
    fi

    sudo timedatectl set-ntp true

    grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen || \
        echo "en_US.UTF-8 UTF-8" | sudo tee -a /etc/locale.gen >/dev/null
    sudo locale-gen
    echo "LANG=en_US.UTF-8" | sudo tee /etc/locale.conf >/dev/null
    ok "Locale: en_US.UTF-8"
}

# ── Docker + Podman ───────────────────────────────────────────────────────
configure_containers() {
    phase "Docker + Podman"
    sudo pacman -S --noconfirm --needed \
        docker podman docker-compose podman-compose \
        docker-buildx fuse-overlayfs slirp4netns

    sudo systemctl enable docker
    sudo gpasswd -a "$ORIGINAL_USER" docker

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
    ok "Docker + Podman installed"
}

# ── VPN support ───────────────────────────────────────────────────────────
configure_vpn() {
    phase "VPN support"
    sudo pacman -S --noconfirm --needed \
        networkmanager-openvpn wireguard-tools openvpn
    sudo systemctl disable NetworkManager-wait-online.service 2>/dev/null || true
    ok "VPN support (OpenVPN + WireGuard)"
}

# ── TLP battery management ────────────────────────────────────────────────
configure_tlp() {
    phase "TLP battery management"
    sudo pacman -S --noconfirm --needed tlp tlp-rdw ethtool smartmontools
    sudo systemctl enable tlp
    sudo systemctl enable NetworkManager-dispatcher 2>/dev/null || true
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
    ok "TLP configured (charge thresholds 20-80%)"
}

# ── Gaming: GameMode + MangoHud + Wine ────────────────────────────────────
configure_gaming() {
    phase "Gaming tools"

    sudo pacman -S --noconfirm --needed gamemode lib32-gamemode mangohud lib32-mangohud
    sudo gpasswd -a "$ORIGINAL_USER" gamemode 2>/dev/null || true

    mkdir -p "$ORIGINAL_HOME/.config/MangoHud"
    cat > "$ORIGINAL_HOME/.config/MangoHud/MangoHud.conf" << 'EOF'
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

    # Wine (wow64)
    sudo pacman -S --noconfirm --needed \
        wine wine-mono wine-gecko winetricks \
        lib32-vulkan-icd-loader vulkan-icd-loader \
        lib32-mesa mesa lutris

    ensure_paru
    paru -S --noconfirm proton-ge-custom-bin 2>/dev/null || \
        warn "proton-ge-custom-bin not available — install manually from AUR"

    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$ORIGINAL_HOME/.config/MangoHud"
    ok "Gaming tools: GameMode, MangoHud, Wine (wow64), Lutris"
}

# ── Auto-mount ────────────────────────────────────────────────────────────
configure_automount() {
    phase "Auto-mount (udiskie)"
    sudo pacman -S --noconfirm --needed udiskie udisks2 gvfs

    mkdir -p "$ORIGINAL_HOME/.config/autostart" "$ORIGINAL_HOME/.config/udiskie"

    cat > "$ORIGINAL_HOME/.config/autostart/udiskie.desktop" << 'EOF'
[Desktop Entry]
Name=udiskie
Exec=udiskie --tray --notify --appindicator
Type=Application
X-GNOME-Autostart-enabled=true
EOF

    cat > "$ORIGINAL_HOME/.config/udiskie/config.yml" << 'EOF'
program_options:
  tray: true
  notify: true
  automount: true
  appindicator: true
notifications:
  timeout: 4
EOF
    ok "udiskie configured for auto-mount"
}

# ── Fingerprint reader ────────────────────────────────────────────────────
configure_fingerprint() {
    phase "Fingerprint reader (fprint)"
    sudo pacman -S --noconfirm --needed fprintd libfprint

    for pam_file in /etc/pam.d/sudo /etc/pam.d/login /etc/pam.d/sddm; do
        [[ -f "$pam_file" ]] || continue
        grep -q "pam_fprintd" "$pam_file" && continue
        sudo sed -i '0,/^auth/s/^auth/auth\t\tsufficient\tpam_fprintd.so\nauth/' "$pam_file"
        info "Fingerprint auth added to $pam_file"
    done

    sudo systemctl enable fprintd
    ok "Fingerprint support installed"
}

# ── Multi-monitor ─────────────────────────────────────────────────────────
configure_multimonitor() {
    phase "Multi-monitor support"
    sudo pacman -S --noconfirm --needed autorandr xorg-xrandr
    autorandr --save skyware-default 2>/dev/null || true
    sudo pacman -S --noconfirm --needed kscreen 2>/dev/null || true
    ok "Multi-monitor: KScreen (Wayland) + autorandr (X11)"
}

# ── Timeshift snapshots ───────────────────────────────────────────────────
configure_timeshift() {
    phase "Timeshift snapshots"
    sudo pacman -S --noconfirm --needed timeshift

    local fs_type snap_type
    fs_type=$(df -T / | awk 'NR==2{print $2}')
    [[ "$fs_type" == "btrfs" ]] && snap_type="BTRFS" || snap_type="RSYNC"

    sudo mkdir -p /etc/timeshift
    sudo tee /etc/timeshift/timeshift.json > /dev/null << TSEOF
{
  "backup_device_uuid": "",
  "do_first_run": "false",
  "btrfs_mode": "$([ "$snap_type" = "BTRFS" ] && echo true || echo false)",
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
    ok "Timeshift configured ($snap_type mode)"
}

# ── Dotfiles bare repo ────────────────────────────────────────────────────
configure_dotfiles() {
    phase "Dotfiles auto-backup"

    local dot_dir="$ORIGINAL_HOME/.dotfiles"
    mkdir -p "$dot_dir"

    if [[ ! -d "$dot_dir/.git" ]] && [[ ! -f "$dot_dir/HEAD" ]]; then
        git init --bare "$dot_dir" 2>/dev/null || git init "$dot_dir"
    fi

    local dc="git --git-dir=$dot_dir --work-tree=$ORIGINAL_HOME"
    $dc config status.showUntrackedFiles no 2>/dev/null || true

    for f in \
        "$ORIGINAL_HOME/.zshrc" \
        "$ORIGINAL_HOME/.config/starship.toml" \
        "$ORIGINAL_HOME/.config/btop/btop.conf" \
        "$ORIGINAL_HOME/.config/fastfetch/config.jsonc" \
        "$ORIGINAL_HOME/.tmux.conf"; do
        [[ -f "$f" ]] && $dc add "$f" 2>/dev/null || true
    done
    $dc commit -m "SkywareOS initial dotfiles" 2>/dev/null || true

    # Systemd user timer for daily backup
    mkdir -p "$ORIGINAL_HOME/.config/systemd/user"
    cat > "$ORIGINAL_HOME/.config/systemd/user/dotfiles-backup.service" << SVCEOF
[Unit]
Description=SkywareOS Dotfiles Auto-Backup

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'git --git-dir=%h/.dotfiles --work-tree=%h add -u && git --git-dir=%h/.dotfiles --work-tree=%h commit -m "auto: \$(date +%%Y-%%m-%%d)" 2>/dev/null || true'
SVCEOF

    cat > "$ORIGINAL_HOME/.config/systemd/user/dotfiles-backup.timer" << 'EOF'
[Unit]
Description=Daily Dotfiles Backup

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=default.target
EOF

    sudo -u "$ORIGINAL_USER" systemctl --user enable dotfiles-backup.timer 2>/dev/null || true
    chown -R "$ORIGINAL_USER:$ORIGINAL_USER" \
        "$dot_dir" \
        "$ORIGINAL_HOME/.config/systemd" 2>/dev/null || true
    ok "Dotfiles repo at ~/.dotfiles"
}

# ══════════════════════════════════════════════════════════════════════════
# ware — package manager v2.0
# ══════════════════════════════════════════════════════════════════════════
install_ware() {
    phase "Installing ware package manager v2.0"

    sudo tee /usr/local/bin/ware > /dev/null << 'WAREEOF'
#!/usr/bin/env bash
# ware — SkywareOS package manager v2.0
# ════════════════════════════════════════════

LOGFILE="/var/log/ware.log"
GREEN="\e[32m"; RED="\e[31m"; BLUE="\e[34m"; YELLOW="\e[33m"
CYAN="\e[36m"; WHITE="\e[97m"; BOLD="\e[1m"; DIM="\e[2m"; RESET="\e[0m"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" | sudo tee -a "$LOGFILE" >/dev/null 2>&1 || true; }
info() { log INFO "$@"; }
ok()   { echo -e "  ${GREEN}✔${RESET}  $*"; }
fail() { echo -e "  ${RED}✖${RESET}  $*"; }
warn() { echo -e "  ${YELLOW}⚠${RESET}  $*"; }

# ── Bootstrap passwordless sudo if needed ────────────────────────────────
if [[ ! -f /etc/sudoers.d/10-skyware ]]; then
    sudo bash -c "echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-skyware && chmod 440 /etc/sudoers.d/10-skyware" 2>/dev/null || true
fi

# ── Spinner ──────────────────────────────────────────────────────────────
spinner() {
    local pid=$! spin='-\|/' i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}[%c] Working...${RESET}" "${spin:$((i++ % 4)):1}"
        sleep .1
    done
    printf "\r"
}

# ── AUR helper ───────────────────────────────────────────────────────────
have_paru() { command -v paru >/dev/null 2>&1; }
ensure_paru() {
    have_paru && return
    echo -e "  ${DIM}→${RESET}  Installing paru (AUR helper)..."
    sudo pacman -S --needed --noconfirm base-devel git
    local t; t=$(mktemp -d)
    git clone https://aur.archlinux.org/paru.git "$t/paru"
    (cd "$t/paru" && makepkg -si --noconfirm)
    rm -rf "$t"
    info "paru installed"
}

# ── Package install (pacman → flatpak → AUR) ─────────────────────────────
install_pkg() {
    for pkg in "$@"; do
        echo -e "  ${DIM}→${RESET}  Installing: ${BOLD}$pkg${RESET}"
        info "Install requested: $pkg"
        if sudo pacman -Si "$pkg" &>/dev/null; then
            (sudo pacman -S --noconfirm "$pkg") & spinner; wait
            info "Installed via pacman: $pkg"
        elif flatpak search --columns=application "$pkg" 2>/dev/null | grep -Fxq "$pkg"; then
            (flatpak install -y flathub "$pkg") & spinner; wait
            info "Installed via flatpak: $pkg"
        else
            ensure_paru
            if paru -Si "$pkg" &>/dev/null; then
                (paru -S --noconfirm "$pkg") & spinner; wait
                info "Installed via AUR: $pkg"
            else
                fail "Package not found: $pkg"; info "FAILED install: $pkg"
            fi
        fi
    done
}

# ── Package remove ────────────────────────────────────────────────────────
remove_pkg() {
    for pkg in "$@"; do
        if pacman -Q "$pkg" &>/dev/null; then
            sudo pacman -Rns --noconfirm "$pkg"; info "Removed: $pkg"
        elif have_paru && paru -Q "$pkg" &>/dev/null; then
            paru -Rns --noconfirm "$pkg"; info "Removed AUR: $pkg"
        elif flatpak list 2>/dev/null | grep -qi "$pkg"; then
            flatpak uninstall -y "$pkg"; info "Removed flatpak: $pkg"
        else
            fail "$pkg is not installed"
        fi
    done
}

# ── Doctor ────────────────────────────────────────────────────────────────
doctor() {
    echo -e "\n${CYAN}${BOLD}── SkywareOS Doctor ─────────────────────────────${RESET}"
    # Pacman DB
    echo -e "${DIM}→ Package database integrity...${RESET}"
    sudo pacman -Dk 2>&1 | grep -v "^$" | head -10 || true
    # Flatpak
    echo -e "${DIM}→ Flatpak integrity...${RESET}"
    flatpak repair --dry-run 2>&1 | tail -5 || true
    # Firewall
    echo -e "${DIM}→ Firewall...${RESET}"
    if command -v ufw &>/dev/null && systemctl is-active ufw &>/dev/null; then
        ok "Firewall (ufw) is ACTIVE"
    else
        fail "Firewall (ufw) is NOT active"
    fi
    # Failed units
    echo -e "${DIM}→ Failed systemd units...${RESET}"
    local failed; failed=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}')
    if [[ -n "$failed" ]]; then
        fail "Failed units:"; echo "$failed" | sed 's/^/    /'
    else
        ok "No failed units"
    fi
    # Disk health (if smartctl available)
    if command -v smartctl &>/dev/null; then
        echo -e "${DIM}→ Disk health (first drive)...${RESET}"
        local drive; drive=$(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1}' | head -1)
        [[ -n "$drive" ]] && \
            sudo smartctl -H "/dev/$drive" 2>/dev/null | grep -E "result|PASSED|FAILED" || true
    fi
    echo -e "${GREEN}${BOLD}── Diagnostics complete ─────────────────────────${RESET}\n"
}

# ── System status ─────────────────────────────────────────────────────────
ware_status() {
    echo -e "\n${CYAN}${BOLD}── SkywareOS Status ─────────────────────────────${RESET}"
    echo -e "${DIM}Kernel:   ${RESET}$(uname -r)"
    echo -e "${DIM}Uptime:   ${RESET}$(uptime -p | sed 's/up //')"
    echo -e "${DIM}Memory:   ${RESET}$(free -h | awk '/Mem:/{print $3"/"$2}')"
    echo -e "${DIM}Disk:     ${RESET}$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')"
    echo -e "${DIM}Desktop:  ${RESET}${XDG_CURRENT_DESKTOP:-—}"
    echo -e "${DIM}Session:  ${RESET}${XDG_SESSION_TYPE:-—}"
    echo -e "${DIM}Channel:  ${RESET}Maroon"
    echo -e "${DIM}Version:  ${RESET}2.0"
    local upd; upd=$(checkupdates 2>/dev/null | wc -l)
    local fw; systemctl is-active ufw &>/dev/null && fw="${GREEN}Active${RESET}" || fw="${RED}Inactive${RESET}"
    echo -e "${DIM}Updates:  ${RESET}${upd} available"
    echo -e "${DIM}Firewall: ${RESET}${fw}"
    echo ""
}

# ── Power profiles ────────────────────────────────────────────────────────
power_profile() {
    case "$1" in
        balanced)
            sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1
            sudo systemctl enable tlp --now
            sudo cpupower frequency-set -g schedutil >/dev/null 2>&1 || true
            ok "Power profile: balanced" ;;
        performance)
            sudo pacman -S --needed --noconfirm cpupower >/dev/null 2>&1
            sudo cpupower frequency-set -g performance
            sudo systemctl stop tlp >/dev/null 2>&1 || true
            ok "Power profile: performance" ;;
        battery)
            sudo pacman -S --needed --noconfirm tlp >/dev/null 2>&1
            sudo systemctl enable tlp --now
            sudo cpupower frequency-set -g powersave >/dev/null 2>&1 || true
            ok "Power profile: battery" ;;
        status) cpupower frequency-info 2>/dev/null | grep "current policy" || echo "cpupower not installed" ;;
        *) echo -e "Usage: ware power <balanced|performance|battery|status>" ;;
    esac
}

# ── Display manager ───────────────────────────────────────────────────────
display_manager() {
    case "$1" in
        list)   printf "  sddm\n  gdm\n  lightdm\n" ;;
        status) systemctl list-unit-files | grep -E 'gdm|sddm|lightdm' | grep enabled || echo "  No DM enabled" ;;
        switch)
            [[ -z "$2" ]] && { fail "Specify a DM"; return; }
            sudo systemctl disable gdm sddm lightdm 2>/dev/null || true
            sudo systemctl enable "$2"
            ok "$2 enabled — reboot required" ;;
        *) echo "Usage: ware dm <list|switch <dm>|status>" ;;
    esac
}

# ── Mirror sync ───────────────────────────────────────────────────────────
sync_mirrors() {
    echo -e "  ${DIM}→${RESET}  Syncing mirrors with reflector..."
    sudo pacman -S --noconfirm reflector &>/dev/null
    sudo reflector --latest 10 --sort rate --protocol https \
        --save /etc/pacman.d/mirrorlist
    ok "Mirrorlist updated (top 10 fastest)"
    info "Mirrors synced"
}

# ── Benchmark ─────────────────────────────────────────────────────────────
benchmark() {
    echo -e "\n${CYAN}${BOLD}── SkywareOS Benchmark ──────────────────────────${RESET}"
    echo ""
    # CPU
    local cpu_model; cpu_model=$(grep "model name" /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)
    local cpu_cores; cpu_cores=$(nproc)
    echo -e "${BOLD}CPU${RESET}  $cpu_model  (${cpu_cores} cores)"
    echo -ne "     ${DIM}Running 5s integer test...${RESET} "
    local cpu_score; cpu_score=$(python3 -c "
import time, math
start = time.time()
count = 0
while time.time() - start < 5:
    math.factorial(10000)
    count += 1
print(count)
")
    echo -e "${GREEN}${cpu_score}${RESET} ops/5s"
    # Memory bandwidth
    echo ""
    echo -e "${BOLD}Memory${RESET}  $(free -h | awk '/Mem:/{print $2}') total"
    echo -ne "        ${DIM}Running bandwidth test...${RESET} "
    local mem_bw; mem_bw=$(python3 -c "
import time, array
size = 100_000_000
a = array.array('B', bytes(size))
start = time.time()
b = bytes(a)
elapsed = time.time() - start
print(f'{size/1e9/elapsed:.1f} GB/s')
")
    echo -e "${GREEN}${mem_bw}${RESET}"
    # Disk
    echo ""
    echo -e "${BOLD}Disk${RESET}  $(df -h / | awk 'NR==2{print $1}')"
    echo -ne "       ${DIM}Sequential write (512MB)...${RESET} "
    local write_speed; write_speed=$(dd if=/dev/zero of=/tmp/ware-bench bs=1M count=512 \
        conv=fdatasync 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1)
    rm -f /tmp/ware-bench
    echo -e "${GREEN}${write_speed:-n/a}${RESET}"
    echo -ne "       ${DIM}Sequential read  (512MB)...${RESET} "
    dd if=/dev/urandom of=/tmp/ware-bench-src bs=1M count=512 2>/dev/null
    local read_speed; read_speed=$(dd if=/tmp/ware-bench-src of=/dev/null bs=1M 2>&1 | grep -oP '[0-9.]+ [MG]B/s' | tail -1)
    rm -f /tmp/ware-bench-src
    echo -e "${GREEN}${read_speed:-n/a}${RESET}"
    echo ""
    info "benchmark run"
}

# ── Repair ────────────────────────────────────────────────────────────────
repair() {
    echo -e "\n${CYAN}${BOLD}── SkywareOS Repair ─────────────────────────────${RESET}"
    echo -e "${DIM}[1/7]${RESET} Fixing pacman keyring..."
    sudo pacman-key --init
    sudo pacman-key --populate archlinux
    sudo pacman-key --refresh-keys 2>/dev/null || true
    ok "Keyring refreshed"
    echo -e "${DIM}[2/7]${RESET} Clearing locks and cache..."
    sudo rm -f /var/lib/pacman/db.lck
    sudo pacman -Sc --noconfirm
    ok "Lock removed, cache cleared"
    echo -e "${DIM}[3/7]${RESET} Checking DB integrity..."
    sudo pacman -Dk 2>&1 | grep -v "^$" | head -5 || true
    echo -e "${DIM}[4/7]${RESET} Reinstalling broken packages..."
    local broken; broken=$(sudo pacman -Qk 2>&1 | grep "warning:" | awk '{print $2}' | cut -d: -f1 | sort -u)
    if [[ -n "$broken" ]]; then
        warn "Reinstalling: $broken"
        sudo pacman -S --noconfirm $broken
    else
        ok "No broken packages"
    fi
    echo -e "${DIM}[5/7]${RESET} Removing orphans..."
    local orphans; orphans=$(pacman -Qtdq 2>/dev/null)
    if [[ -n "$orphans" ]]; then
        sudo pacman -Rns --noconfirm $orphans; ok "Orphans removed"
    else
        ok "No orphans"
    fi
    echo -e "${DIM}[6/7]${RESET} Repairing Flatpak..."
    flatpak repair 2>/dev/null || true
    flatpak uninstall --unused -y 2>/dev/null || true
    ok "Flatpak repaired"
    echo -e "${DIM}[7/7]${RESET} Restarting failed units..."
    local failed; failed=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}')
    if [[ -n "$failed" ]]; then
        for unit in $failed; do
            sudo systemctl restart "$unit" 2>/dev/null \
                && ok "Restarted $unit" || fail "Could not restart $unit"
        done
    else
        ok "No failed units"
    fi
    echo -e "\n${GREEN}${BOLD}── Repair complete ──────────────────────────────${RESET}\n"
    info "repair run"
}

# ── Backup (Timeshift + restic) ───────────────────────────────────────────
backup_cmd() {
    case "$2" in
        create)
            if command -v timeshift &>/dev/null; then
                sudo timeshift --create --comments "ware backup $(date '+%Y-%m-%d %H:%M')" --tags D
                info "Snapshot created"
            else
                warn "Timeshift not installed — run: ware install timeshift"; fi ;;
        list)    sudo timeshift --list 2>/dev/null || fail "Timeshift not installed" ;;
        restore) sudo timeshift --restore 2>/dev/null || fail "Timeshift not installed" ;;
        delete)  sudo timeshift --delete 2>/dev/null || fail "Timeshift not installed" ;;
        # restic integration
        restic-init)
            command -v restic &>/dev/null || sudo pacman -S --noconfirm restic
            [[ -z "$RESTIC_REPOSITORY" ]] && { fail "Set RESTIC_REPOSITORY env var first"; return; }
            restic init ;;
        restic-backup)
            command -v restic &>/dev/null || sudo pacman -S --noconfirm restic
            restic backup "$HOME" --exclude="$HOME/.cache" --exclude="$HOME/.local/share/Trash"
            info "restic backup run" ;;
        *)
            echo -e "  ware backup <create|list|restore|delete>"
            echo -e "  ware backup <restic-init|restic-backup>  (set RESTIC_REPOSITORY first)" ;;
    esac
}

# ── Disk health ───────────────────────────────────────────────────────────
disk_health() {
    echo -e "\n${CYAN}${BOLD}── Disk Health ──────────────────────────────────${RESET}"
    if ! command -v smartctl &>/dev/null; then
        sudo pacman -S --noconfirm --needed smartmontools
    fi
    local drives; drives=$(lsblk -nd -o NAME,TYPE | awk '$2=="disk"{print $1}')
    for d in $drives; do
        echo -e "\n${BOLD}/dev/$d${RESET}"
        sudo smartctl -a "/dev/$d" 2>/dev/null | grep -E \
            "Device Model|Serial|Firmware|User Capacity|SMART overall|Reallocated|Power_On|Temperature|Pending|Uncorrectable" \
            || echo "  No SMART data available"
    done
    echo ""
}

# ── Flatpak permissions manager ───────────────────────────────────────────
flatpak_perms() {
    case "$2" in
        list) flatpak permissions 2>/dev/null | head -40 || flatpak list ;;
        reset) [[ -n "$3" ]] && flatpak permission-reset "$3" || fail "Specify an app ID" ;;
        *)
            echo -e "  ware flatpak list         - Show Flatpak permissions"
            echo -e "  ware flatpak reset <app>  - Reset permissions for an app" ;;
    esac
}

# ── AI subcommand ─────────────────────────────────────────────────────────
ai_cmd() {
    case "$2" in
        doctor)  exec /usr/local/bin/ware-ai-doctor ;;
        ask)
            shift 2
            local query="$*"
            [[ -z "$query" ]] && { fail "Provide a question"; return; }
            local KEY_FILE="$HOME/.config/skyware/api_key"
            local API_KEY="${ANTHROPIC_API_KEY:-}"
            [[ -z "$API_KEY" && -f "$KEY_FILE" ]] && API_KEY=$(cat "$KEY_FILE")
            if [[ -z "$API_KEY" ]]; then
                fail "No API key. Set ANTHROPIC_API_KEY or write to ~/.config/skyware/api_key"
                return
            fi
            echo -e "  ${DIM}→${RESET}  Asking Claude: $query"
            local resp; resp=$(curl -s https://api.anthropic.com/v1/messages \
                -H "x-api-key: $API_KEY" \
                -H "anthropic-version: 2023-06-01" \
                -H "content-type: application/json" \
                -d "$(jq -nc --arg q "$query" '{"model":"claude-sonnet-4-20260514","max_tokens":512,"messages":[{"role":"user","content":$q}]}')" 2>/dev/null)
            echo "$resp" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin)['content'][0]['text'])
except:
    print('API error — check your key')
" ;;
        *)
            echo -e "  ware ai doctor   - Run AI system diagnosis"
            echo -e "  ware ai ask <q>  - Ask Claude a question" ;;
    esac
}

# ── Setup environments ────────────────────────────────────────────────────
setup_env() {
    case "$2" in
        hyprland)
            sudo pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland \
                waybar wofi kitty grim slurp wl-clipboard polkit-kde-agent \
                pipewire wireplumber network-manager-applet thunar
            sh <(curl -L https://raw.githubusercontent.com/JaKooLit/Hyprland-Dots/main/Distro-Hyprland.sh) ;;
        lazyvim)
            sudo pacman -S --noconfirm neovim git
            mv ~/.config/nvim ~/.config/nvim.bak 2>/dev/null || true
            git clone https://github.com/LazyVim/starter ~/.config/nvim
            rm -rf ~/.config/nvim/.git
            nvim ;;
        niri)
            sudo pacman -S --noconfirm --needed gum
            git clone https://github.com/acaibowlz/niri-setup.git /tmp/niri-setup
            cd /tmp/niri-setup && chmod +x setup.sh && ./setup.sh ;;
        snap)
            sudo pacman -S --noconfirm snapd
            sudo systemctl enable --now snapd.socket
            sudo ln -sf /var/lib/snapd/snap /snap
            ok "Snap enabled" ;;
        snap-remove)
            sudo systemctl disable --now snapd.socket
            sudo pacman -Rns --noconfirm snapd
            sudo rm -f /snap
            ok "Snap removed" ;;
        *)
            echo -e "  ware setup <hyprland|lazyvim|niri|snap|snap-remove>" ;;
    esac
}

# ── Encryption helper (LUKS) ──────────────────────────────────────────────
luks_cmd() {
    case "$2" in
        list)
            echo -e "\n${CYAN}${BOLD}── LUKS Volumes ─────────────────────────────────${RESET}"
            ls /dev/mapper/ 2>/dev/null || echo "  No mapped devices"
            lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT | grep -E "crypt|NAME" ;;
        open)
            [[ -z "$3" || -z "$4" ]] && { fail "Usage: ware luks open <device> <name>"; return; }
            sudo cryptsetup open "$3" "$4"
            ok "LUKS volume $3 opened as /dev/mapper/$4" ;;
        close)
            [[ -z "$3" ]] && { fail "Usage: ware luks close <name>"; return; }
            sudo cryptsetup close "$3"
            ok "LUKS volume /dev/mapper/$3 closed" ;;
        *)
            echo -e "  ware luks list            - List LUKS/encrypted devices"
            echo -e "  ware luks open <dev> <n>  - Open LUKS device"
            echo -e "  ware luks close <n>       - Close LUKS device" ;;
    esac
}

# ── Network wizard ────────────────────────────────────────────────────────
network_cmd() {
    case "$2" in
        list)
            echo -e "\n${CYAN}${BOLD}── Network Interfaces ───────────────────────────${RESET}"
            ip -br addr
            echo ""
            nmcli device status 2>/dev/null || true ;;
        wifi)
            nmcli dev wifi 2>/dev/null || { fail "NetworkManager not running"; return; }
            echo -ne "\nConnect to SSID: "
            read -r ssid
            echo -ne "Password: "
            read -rs pw; echo ""
            nmcli dev wifi connect "$ssid" password "$pw" \
                && ok "Connected to $ssid" || fail "Connection failed" ;;
        speed)
            command -v speedtest-cli &>/dev/null || sudo pacman -S --noconfirm speedtest-cli
            speedtest-cli 2>/dev/null || fail "speedtest-cli unavailable" ;;
        dns)
            echo -e "\n  Current DNS: $(cat /etc/resolv.conf | grep nameserver)"
            echo -e "  1) Cloudflare (1.1.1.1)  2) Google (8.8.8.8)  3) Quad9 (9.9.9.9)"
            echo -ne "  Choose: "; read -r dns_choice
            case "$dns_choice" in
                1) nmcli con mod "$(nmcli -g name con show --active | head -1)" ipv4.dns "1.1.1.1 1.0.0.1" ;;
                2) nmcli con mod "$(nmcli -g name con show --active | head -1)" ipv4.dns "8.8.8.8 8.8.4.4" ;;
                3) nmcli con mod "$(nmcli -g name con show --active | head -1)" ipv4.dns "9.9.9.9 149.112.112.112" ;;
                *) fail "Invalid choice"; return ;;
            esac
            nmcli con up "$(nmcli -g name con show --active | head -1)" 2>/dev/null || true
            ok "DNS updated" ;;
        *)
            echo -e "  ware network list   - List interfaces"
            echo -e "  ware network wifi   - Connect to WiFi"
            echo -e "  ware network speed  - Run speed test"
            echo -e "  ware network dns    - Change DNS resolver" ;;
    esac
}

# ── Help ──────────────────────────────────────────────────────────────────
show_help() {
    echo -e "\n${BOLD}${CYAN}ware${RESET} — SkywareOS Package Manager v2.0\n"
    echo -e "${BOLD}Package Management${RESET}"
    echo -e "  install <pkg>        Install package (pacman → flatpak → AUR)"
    echo -e "  remove  <pkg>        Remove package"
    echo -e "  update               Update all packages + flatpaks"
    echo -e "  upgrade              Upgrade SkywareOS to latest"
    echo -e "  switch               Switch to testing channel"
    echo -e "  search  <pkg>        Search packages"
    echo -e "  info    <pkg>        Package info"
    echo -e "  list                 List installed packages"
    echo -e "  autoremove           Remove orphaned packages"
    echo -e "  clean                Clean package cache"
    echo -e "\n${BOLD}System${RESET}"
    echo -e "  status               System overview"
    echo -e "  doctor               Run diagnostics"
    echo -e "  repair               Fix broken packages, DB, failed units"
    echo -e "  benchmark            CPU/RAM/disk speed test"
    echo -e "  disk-health          SMART disk health report"
    echo -e "  sync                 Sync pacman mirrorlist"
    echo -e "\n${BOLD}Power & Hardware${RESET}"
    echo -e "  power <mode>         Set power profile (balanced/performance/battery/status)"
    echo -e "  dm <action>          Manage display managers (list/switch/status)"
    echo -e "\n${BOLD}Backup & Security${RESET}"
    echo -e "  backup <action>      Snapshots (create/list/restore/delete/restic-init/restic-backup)"
    echo -e "  luks <action>        LUKS encryption helpers (list/open/close)"
    echo -e "\n${BOLD}AI${RESET}"
    echo -e "  ai doctor            AI-powered system diagnosis"
    echo -e "  ai ask <question>    Ask Claude a question"
    echo -e "\n${BOLD}Networking${RESET}"
    echo -e "  network <action>     Network tools (list/wifi/speed/dns)"
    echo -e "\n${BOLD}Environments & Tools${RESET}"
    echo -e "  setup <env>          Install environments (hyprland/lazyvim/niri)"
    echo -e "  flatpak <action>     Flatpak permissions (list/reset)"
    echo -e "  settings             Open SkywareOS Settings GUI"
    echo -e "  git                  Open SkywareOS website"
    echo -e "  dualboot             Set up dual boot with Limine"
    echo -e "  snap / snap-remove   Manage Snap support"
    echo -e "  interactive          Interactive install wizard"
    echo ""
}

# ── Main dispatcher ───────────────────────────────────────────────────────
case "$1" in
    install)   shift; install_pkg "$@" ;;
    remove)    shift; remove_pkg "$@" ;;
    update)    sudo pacman -Syu; flatpak update -y; info "System updated" ;;
    search)    shift; pacman -Ss "$@"; flatpak search "$@" 2>/dev/null ;;
    info)      shift; pacman -Si "$1" 2>/dev/null || (have_paru && paru -Si "$1") || flatpak info "$1" ;;
    list)      pacman -Q; flatpak list 2>/dev/null ;;
    autoremove)
        orphans=$(pacman -Qtdq 2>/dev/null)
        [[ -n "$orphans" ]] && sudo pacman -Rns --noconfirm $orphans || ok "No orphans" ;;
    clean)     sudo pacman -Sc --noconfirm; flatpak uninstall --unused -y; info "Cache cleaned" ;;
    status)    ware_status ;;
    doctor)    doctor ;;
    repair)    repair ;;
    benchmark) benchmark ;;
    disk-health) disk_health ;;
    sync)      sync_mirrors ;;
    power)     power_profile "$2" ;;
    dm)        display_manager "$@" ;;
    backup)    backup_cmd "$@" ;;
    luks)      luks_cmd "$@" ;;
    ai)        ai_cmd "$@" ;;
    network)   network_cmd "$@" ;;
    setup)     setup_env "$@" ;;
    flatpak)   flatpak_perms "$@" ;;
    settings)  exec skyware-settings ;;
    git)       command -v xdg-open &>/dev/null && xdg-open "https://skywaresw.github.io/SkywareOS" || echo "https://skywaresw.github.io/SkywareOS" ;;
    dualboot)  paru -S --noconfirm limine-entry-tool && sudo limine-entry-tool --scan ;;
    upgrade)
        rm -rf /tmp/SkywareOS 2>/dev/null || true
        git clone https://github.com/SkywareSW/SkywareOS /tmp/SkywareOS
        cd /tmp/SkywareOS
        sed -i 's/\r$//' skyware-setup.sh
        chmod +x skyware-setup.sh
        bash skyware-setup.sh ;;
    switch)
        rm -rf /tmp/SkywareOS-Testing 2>/dev/null || true
        git clone https://github.com/SkywareSW/SkywareOS-Testing /tmp/SkywareOS-Testing
        cd /tmp/SkywareOS-Testing
        sed -i 's/\r$//' skyware-testingsetup.sh
        chmod +x skyware-testingsetup.sh
        bash skyware-testingsetup.sh ;;
    interactive)
        echo -ne "  Package to install: "; read -r pkg; [[ -n "$pkg" ]] && install_pkg "$pkg" ;;
    help|-h|--help) show_help ;;
    "")  ware_status ;;
    *)
        fail "Unknown command: $1"
        echo -e "  Run ${CYAN}ware help${RESET} for available commands." ;;
esac
WAREEOF

    sudo chmod +x /usr/local/bin/ware
    ok "ware v2.0 installed"
}

# ── AI Doctor ─────────────────────────────────────────────────────────────
install_ai_doctor() {
    phase "AI Doctor"

    sudo tee /usr/local/bin/ware-ai-doctor > /dev/null << 'EOF'
#!/usr/bin/env bash
# ware-ai-doctor — AI-powered system diagnosis via Claude API

RED="\e[31m"; CYAN="\e[36m"; GREEN="\e[32m"; YELLOW="\e[33m"; RESET="\e[0m"; BOLD="\e[1m"

KEY_FILE="$HOME/.config/skyware/api_key"
API_KEY="${ANTHROPIC_API_KEY:-}"
[[ -z "$API_KEY" && -f "$KEY_FILE" ]] && API_KEY=$(cat "$KEY_FILE")

if [[ -z "$API_KEY" ]]; then
    echo -e "${YELLOW}⚠  No Anthropic API key.${RESET}"
    echo -e "   Set it with:"
    echo -e "   mkdir -p ~/.config/skyware && echo 'sk-ant-...' > ~/.config/skyware/api_key"
    exit 1
fi

echo -e "\n${CYAN}${BOLD}── SkywareOS AI Doctor ──────────────────────────${RESET}"
echo -e "${CYAN}→${RESET} Collecting diagnostics..."

JOURNAL_ERRORS=$(sudo journalctl -p err -b --no-pager -n 25 2>/dev/null | tail -25)
FAILED_UNITS=$(systemctl --failed --no-legend 2>/dev/null)
PACMAN_LOG=$(tail -n 25 /var/log/pacman.log 2>/dev/null)
OS_INFO="SkywareOS Maroon 2.0 (Arch-based), kernel $(uname -r)"
MEM_INFO=$(free -h | awk '/Mem:/{print $3"/"$2}')
DISK_INFO=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5")"}')

PROMPT="You are a Linux sysadmin assistant for SkywareOS (Arch-based).
Analyze the diagnostics below. Be concise and specific.
Format each finding as: [ISSUE] → [FIX COMMAND]
If everything looks healthy, say so briefly.

OS: $OS_INFO | Memory: $MEM_INFO | Disk: $DISK_INFO

Journal errors (last 25):
$JOURNAL_ERRORS

Failed systemd units:
${FAILED_UNITS:-none}

Recent pacman.log:
$PACMAN_LOG"

echo -e "${CYAN}→${RESET} Consulting Claude...\n"

RESPONSE=$(curl -s https://api.anthropic.com/v1/messages \
    -H "x-api-key: $API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$(jq -nc --arg p "$PROMPT" \
        '{"model":"claude-sonnet-4-20260514","max_tokens":1024,"messages":[{"role":"user","content":$p}]}')" 2>/dev/null)

python3 - << PYEOF
import json, sys
try:
    data = json.loads('''$RESPONSE''')
    print(data['content'][0]['text'])
except Exception as e:
    print(f"Could not parse API response: {e}")
    print("Check your API key or network connection.")
PYEOF

echo -e "\n${GREEN}${BOLD}── End of AI diagnosis ──────────────────────────${RESET}\n"
EOF

    sudo chmod +x /usr/local/bin/ware-ai-doctor
    ok "AI Doctor installed"
}

# ── OTA Update notifier ───────────────────────────────────────────────────
install_update_notifier() {
    phase "Update notifier"
    sudo pacman -S --noconfirm --needed libnotify python-gobject

    sudo tee /usr/local/bin/skyware-update-notifier > /dev/null << 'EOF'
#!/usr/bin/env python3
import subprocess, sys

def count_updates():
    try:
        r = subprocess.run(["checkupdates"], capture_output=True, text=True, timeout=30)
        pacman_count = len([l for l in r.stdout.splitlines() if l.strip()])
    except Exception:
        pacman_count = 0
    try:
        r = subprocess.run(["flatpak","remote-ls","--updates"],
                           capture_output=True, text=True, timeout=30)
        flatpak_count = len([l for l in r.stdout.splitlines() if l.strip()])
    except Exception:
        flatpak_count = 0
    return pacman_count, flatpak_count

def notify(pacman, flatpak):
    total = pacman + flatpak
    if total == 0:
        return
    parts = []
    if pacman  > 0: parts.append(f"{pacman} pacman")
    if flatpak > 0: parts.append(f"{flatpak} flatpak")
    summary = f"SkywareOS: {total} update{'s' if total != 1 else ''} available"
    body = ", ".join(parts) + f" package{'s' if total != 1 else ''} ready.\nRun: ware update"
    subprocess.run(["notify-send",
                    "--app-name=SkywareOS",
                    "--icon=system-software-update",
                    "--urgency=normal",
                    "--expire-time=8000",
                    summary, body])

if __name__ == "__main__":
    p, f = count_updates()
    notify(p, f)
EOF
    sudo chmod +x /usr/local/bin/skyware-update-notifier

    mkdir -p "$ORIGINAL_HOME/.config/systemd/user"
    cat > "$ORIGINAL_HOME/.config/systemd/user/skyware-updates.service" << 'EOF'
[Unit]
Description=SkywareOS Update Notifier
[Service]
Type=oneshot
ExecStart=/usr/local/bin/skyware-update-notifier
EOF
    cat > "$ORIGINAL_HOME/.config/systemd/user/skyware-updates.timer" << 'EOF'
[Unit]
Description=SkywareOS Update Check (6 hourly)
[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
Persistent=true
[Install]
WantedBy=default.target
EOF

    sudo -u "$ORIGINAL_USER" systemctl --user enable skyware-updates.timer 2>/dev/null || true
    ok "Update notifier installed (6-hour checks)"
}

# ══════════════════════════════════════════════════════════════════════════
# Settings App (Electron + React) v2.0
# ══════════════════════════════════════════════════════════════════════════
install_settings_app() {
    phase "SkywareOS Settings App v2.0"

    local app_dir="/opt/skyware-settings"
    sudo mkdir -p "$app_dir/src"
    sudo chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$app_dir"

    # ── package.json ──────────────────────────────────────────────────────
    cat > "$app_dir/package.json" << 'EOF'
{
  "name": "skyware-settings",
  "version": "2.0.0",
  "description": "SkywareOS Settings",
  "main": "main.js",
  "scripts": { "start": "electron .", "build": "vite build" },
  "dependencies": { "react": "^18.3.0", "react-dom": "^18.3.0" },
  "devDependencies": { "electron": "^31.0.0", "@vitejs/plugin-react": "^4.3.0", "vite": "^5.3.0" }
}
EOF

    # ── main.js ───────────────────────────────────────────────────────────
    cat > "$app_dir/main.js" << 'EOF'
const { app, BrowserWindow, ipcMain } = require('electron');
const { exec, spawn } = require('child_process');
const path = require('path');
const fs   = require('fs');
const os   = require('os');

function createWindow() {
  const win = new BrowserWindow({
    width: 1060, height: 700, minWidth: 820, minHeight: 580,
    frame: false, backgroundColor: '#111113',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
    title: 'SkywareOS Settings',
  });
  const dist = path.join(__dirname, 'dist', 'index.html');
  if (fs.existsSync(dist)) {
    win.loadFile(dist);
  } else {
    win.loadURL('data:text/html;charset=utf-8,' + encodeURIComponent(
      '<html><body style="background:#111113;color:#e2e2ec;font-family:sans-serif;display:flex;' +
      'align-items:center;justify-content:center;height:100vh;flex-direction:column;gap:12px">' +
      '<div style="font-size:32px">⚠</div><div>Build not found</div>' +
      '<code style="background:#18181b;padding:8px 16px;border-radius:6px;color:#f87171">' +
      'cd /opt/skyware-settings && npm install && npx vite build</code></body></html>'
    ));
  }
}

const TERMINAL_PREFIXES = ['ware upgrade','ware switch','ware setup','ware snap','ware dm switch'];
const needsTerminal = (cmd) => TERMINAL_PREFIXES.some(p => cmd.startsWith(p));

ipcMain.handle('run-cmd', (_, cmd) => new Promise(resolve => {
  const env = { ...process.env, PATH: '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:' + (process.env.PATH || '') };
  if (needsTerminal(cmd)) {
    const script = path.join(os.tmpdir(), `sw-${Date.now()}.sh`);
    fs.writeFileSync(script, `#!/bin/bash\n${cmd}\necho\nread -p 'Press Enter to close...'\n`);
    fs.chmodSync(script, 0o755);
    for (const [t, args] of [['kitty',[script]],['alacritty',['-e','bash',script]],['konsole',['-e','bash',script]]]) {
      if (require('child_process').spawnSync('which',[t],{env}).status === 0) {
        spawn(t, args, { env, detached: true, stdio: 'ignore' }).unref();
        return resolve({ stdout: `→ Opened in ${t}`, stderr: '', code: 0 });
      }
    }
  }
  exec(`bash -c "${cmd.replace(/"/g,'\\"')}"`,
    { env, maxBuffer: 50 * 1024 * 1024, timeout: 120000 },
    (err, stdout, stderr) => resolve({ stdout: stdout||'', stderr: stderr||'', code: err?.code||0 })
  );
}));

ipcMain.handle('read-file', (_, p) => {
  try { return fs.readFileSync(p, 'utf8'); } catch { return null; }
});
ipcMain.handle('write-file', (_, p, content) => {
  try { fs.writeFileSync(p, content, 'utf8'); return true; } catch { return false; }
});

ipcMain.on('window-minimize', e => BrowserWindow.fromWebContents(e.sender)?.minimize());
ipcMain.on('window-maximize', e => {
  const w = BrowserWindow.fromWebContents(e.sender);
  w?.isMaximized() ? w.unmaximize() : w?.maximize();
});
ipcMain.on('window-close',    e => BrowserWindow.fromWebContents(e.sender)?.close());

app.whenReady().then(createWindow);
app.on('window-all-closed', () => process.platform !== 'darwin' && app.quit());
EOF

    # ── preload.js ────────────────────────────────────────────────────────
    cat > "$app_dir/preload.js" << 'EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('skyware', {
  runCmd:    cmd     => ipcRenderer.invoke('run-cmd', cmd),
  readFile:  path    => ipcRenderer.invoke('read-file', path),
  writeFile: (p, c)  => ipcRenderer.invoke('write-file', p, c),
  minimize:  ()      => ipcRenderer.send('window-minimize'),
  maximize:  ()      => ipcRenderer.send('window-maximize'),
  close:     ()      => ipcRenderer.send('window-close'),
});
EOF

    # ── vite.config.js ────────────────────────────────────────────────────
    cat > "$app_dir/vite.config.js" << 'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins: [react()], base: './', build: { outDir: 'dist' } });
EOF

    # ── index.html ────────────────────────────────────────────────────────
    cat > "$app_dir/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>SkywareOS Settings</title>
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body { overflow: hidden; background: #111113; }
    #root { height: 100vh; }
  </style>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/src/main.jsx"></script>
</body>
</html>
EOF

    mkdir -p "$app_dir/src"
    # ── src/main.jsx ──────────────────────────────────────────────────────
    cat > "$app_dir/src/main.jsx" << 'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
createRoot(document.getElementById('root')).render(<App />);
EOF

    # ── src/App.jsx ───────────────────────────────────────────────────────
    cat > "$app_dir/src/App.jsx" << 'APPEOF'
import { useState, useEffect, useRef } from "react";

const C = {
  bg:"#111113", bgSide:"#0c0c0e", bgHeader:"#0a0a0c", bgCard:"#17171a",
  bgHover:"#1e1e22", border:"#28282d", borderFaint:"#1c1c20",
  accent:"#9090a0", accentHi:"#c0c0d4", muted:"#454552", mutedLo:"#2a2a34",
  text:"#e0e0ea", textDim:"#707080",
  green:"#4ade80", yellow:"#facc15", red:"#f87171", blue:"#60a5fa",
  purple:"#a78bfa", orange:"#fb923c",
};

const SIDEBAR = [
  { id:"status",   label:"Status",    icon:"◈" },
  { id:"packages", label:"Packages",  icon:"⬡" },
  { id:"power",    label:"Power",     icon:"⚡" },
  { id:"display",  label:"Display",   icon:"⬕" },
  { id:"network",  label:"Network",   icon:"◉" },
  { id:"security", label:"Security",  icon:"🔒" },
  { id:"gaming",   label:"Gaming",    icon:"◎" },
  { id:"envs",     label:"Environments", icon:"⬢" },
  { id:"ai",       label:"AI Tools",  icon:"✦" },
  { id:"system",   label:"System",    icon:"⚙" },
];

const api = cmd => window.skyware?.runCmd(cmd) ?? Promise.resolve({ stdout:`[sim] ${cmd}`, stderr:"", code:0 });

/* ── Terminal hook ── */
function useTerminal() {
  const [lines, setLines] = useState([]);
  const add = (text, type="info") => setLines(p => [...p, { text, type, id: Date.now() + Math.random() }]);
  const clear = () => setLines([]);
  return { lines, add, clear };
}

/* ── TitleBar ── */
function TitleBar() {
  const btns = [
    { l:"–", a:()=>window.skyware?.minimize(), c:C.yellow },
    { l:"□", a:()=>window.skyware?.maximize(), c:C.green  },
    { l:"×", a:()=>window.skyware?.close(),    c:C.red    },
  ];
  return (
    <div style={{WebkitAppRegion:"drag",height:"48px",background:C.bgHeader,
      borderBottom:`1px solid ${C.borderFaint}`,display:"flex",alignItems:"center",
      justifyContent:"space-between",padding:"0 18px",flexShrink:0}}>
      <div style={{display:"flex",alignItems:"center",gap:"10px"}}>
        <div style={{width:"22px",height:"22px",borderRadius:"5px",
          background:`linear-gradient(135deg,${C.accent},#404050)`,
          display:"flex",alignItems:"center",justifyContent:"center",
          fontSize:"11px",fontWeight:900,color:"#fff"}}>S</div>
        <span style={{color:C.text,fontWeight:600,fontSize:"13px"}}>SkywareOS Settings</span>
        <span style={{background:C.bgHover,color:C.textDim,fontSize:"10px",
          borderRadius:"4px",padding:"2px 7px",border:`1px solid ${C.border}`}}>v2.0</span>
      </div>
      <div style={{WebkitAppRegion:"no-drag",display:"flex",gap:"6px"}}>
        {btns.map(b=>(
          <button key={b.l} onClick={b.a}
            style={{width:"28px",height:"20px",borderRadius:"4px",
              border:`1px solid ${C.border}`,background:"transparent",
              color:C.textDim,cursor:"pointer",fontSize:"12px",fontFamily:"inherit"}}
            onMouseEnter={e=>{e.target.style.background=b.c+"33";e.target.style.color=b.c;}}
            onMouseLeave={e=>{e.target.style.background="transparent";e.target.style.color=C.textDim;}}>
            {b.l}
          </button>
        ))}
      </div>
    </div>
  );
}

/* ── Terminal panel ── */
function Terminal({lines, onClose, onClear}) {
  const ref = useRef(null);
  useEffect(() => { if(ref.current) ref.current.scrollTop = ref.current.scrollHeight; }, [lines]);
  const col = { info:C.textDim, success:C.green, error:C.red, cmd:C.accentHi, warn:C.yellow };
  return (
    <div style={{position:"absolute",bottom:0,left:0,right:0,height:"210px",
      background:"#090909",borderTop:`1px solid ${C.border}`,
      fontFamily:"'JetBrains Mono','Fira Code',monospace",fontSize:"11px",
      display:"flex",flexDirection:"column",zIndex:50}}>
      <div style={{padding:"6px 16px",borderBottom:`1px solid ${C.borderFaint}`,
        display:"flex",justifyContent:"space-between",alignItems:"center"}}>
        <span style={{color:C.accent,fontSize:"10px",letterSpacing:"0.12em",textTransform:"uppercase"}}>
          Terminal Output
        </span>
        <div style={{display:"flex",gap:"8px"}}>
          <button onClick={onClear} style={{background:"none",border:"none",color:C.muted,cursor:"pointer",fontSize:"11px"}}>Clear</button>
          <button onClick={onClose} style={{background:"none",border:"none",color:C.muted,cursor:"pointer",fontSize:"16px",lineHeight:1}}>×</button>
        </div>
      </div>
      <div ref={ref} style={{flex:1,overflowY:"auto",padding:"8px 16px"}}>
        {lines.map(l=>(
          <div key={l.id} style={{color:col[l.type]||C.textDim,marginBottom:"2px",lineHeight:1.7}}>
            {l.type==="cmd" ? <><span style={{color:C.accent}}>$ </span>{l.text}</> : l.text}
          </div>
        ))}
      </div>
    </div>
  );
}

/* ── Shared components ── */
const Card = ({label,value,highlight}) => (
  <div style={{background:C.bgCard,border:`1px solid ${highlight||C.border}`,
    borderRadius:"8px",padding:"13px 16px",display:"flex",flexDirection:"column",gap:"4px"}}>
    <span style={{color:C.muted,fontSize:"10px",textTransform:"uppercase",letterSpacing:"0.1em"}}>{label}</span>
    <span style={{color:C.text,fontSize:"13px",fontWeight:500,wordBreak:"break-word"}}>{value}</span>
  </div>
);

const Hdr = ({title,sub}) => (
  <div style={{marginBottom:"24px"}}>
    <h2 style={{color:C.text,fontSize:"18px",fontWeight:600,margin:0,letterSpacing:"-0.02em"}}>{title}</h2>
    {sub && <p style={{color:C.textDim,fontSize:"12px",margin:"5px 0 0",lineHeight:1.5}}>{sub}</p>}
    <div style={{width:"28px",height:"2px",background:C.accent,marginTop:"10px",borderRadius:"2px"}}/>
  </div>
);

const Btn = ({label,cmd,onClick,variant="default",icon,disabled}) => {
  const [h,setH]=useState(false);
  const v = {
    default:{ bg:h?C.bgHover:"transparent", bd:C.border,     c:C.text  },
    danger: { bg:h?"#240d0d":"transparent", bd:C.red+"55",   c:C.red   },
    success:{ bg:h?"#0a1a0f":"transparent", bd:C.green+"44", c:C.green },
    accent: { bg:h?C.bgHover:"transparent", bd:C.accent+"66",c:C.accentHi },
  }[variant];
  return (
    <button onMouseEnter={()=>!disabled&&setH(true)} onMouseLeave={()=>setH(false)}
      onClick={()=>!disabled&&onClick(cmd||"",label)}
      disabled={disabled}
      style={{background:v.bg,border:`1px solid ${v.bd}`,color:v.c,borderRadius:"7px",
        padding:"9px 14px",cursor:disabled?"not-allowed":"pointer",fontSize:"12px",
        fontFamily:"inherit",opacity:disabled?0.4:1,transition:"all 0.1s",
        display:"flex",alignItems:"center",gap:"7px",textAlign:"left"}}>
      {icon&&<span style={{fontSize:"13px"}}>{icon}</span>}
      <span>{label}</span>
    </button>
  );
};

/* ── Sections ── */
function StatusSection({run}) {
  const [s,setS]=useState({
    kernel:"loading…",uptime:"loading…",firewall:"…",
    disk:"…",memory:"…",desktop:"…",updates:"…",session:"…",hostname:"…"
  });
  useEffect(()=>{
    api("uname -r").then(r=>setS(p=>({...p,kernel:r.stdout.trim()||"—"})));
    api("uptime -p").then(r=>setS(p=>({...p,uptime:r.stdout.trim().replace("up ","")||"—"})));
    api("systemctl is-active ufw").then(r=>setS(p=>({...p,firewall:r.stdout.trim()==="active"?"Active":"Inactive"})));
    api("df -h / | awk 'NR==2{print $3\"/\"$2\" (\"$5\")\"}'").then(r=>setS(p=>({...p,disk:r.stdout.trim()||"—"})));
    api("free -h | awk '/Mem:/{print $3\"/\"$2}'").then(r=>setS(p=>({...p,memory:r.stdout.trim()||"—"})));
    api("echo ${XDG_CURRENT_DESKTOP:-Unknown}").then(r=>setS(p=>({...p,desktop:r.stdout.trim()||"—"})));
    api("echo ${XDG_SESSION_TYPE:-unknown}").then(r=>setS(p=>({...p,session:r.stdout.trim()||"—"})));
    api("hostname").then(r=>setS(p=>({...p,hostname:r.stdout.trim()||"—"})));
    api("checkupdates 2>/dev/null | wc -l || echo 0").then(r=>setS(p=>({...p,updates:r.stdout.trim()||"0"})));
  },[]);
  const fwHl = s.firewall==="Active" ? C.green+"44" : C.red+"33";
  const updHl = parseInt(s.updates)>0 ? C.yellow+"44" : undefined;
  return (
    <div>
      <Hdr title="System Status" sub="Live overview of your SkywareOS installation."/>
      <div style={{display:"grid",gridTemplateColumns:"repeat(3,1fr)",gap:"8px",marginBottom:"20px"}}>
        <Card label="Version"  value="Maroon 2.0" highlight={C.accent+"44"}/>
        <Card label="Kernel"   value={s.kernel}/>
        <Card label="Uptime"   value={s.uptime}/>
        <Card label="Hostname" value={s.hostname}/>
        <Card label="Session"  value={s.session}/>
        <Card label="Desktop"  value={s.desktop}/>
        <Card label="Firewall" value={s.firewall} highlight={fwHl}/>
        <Card label="Memory"   value={s.memory}/>
        <Card label="Disk"     value={s.disk}/>
        <Card label="Updates"  value={`${s.updates} available`} highlight={updHl}/>
      </div>
      <div style={{display:"flex",gap:"8px",flexWrap:"wrap"}}>
        <Btn label="Update System"   cmd="ware update"      onClick={run} icon="↑" variant="success"/>
        <Btn label="Run Doctor"      cmd="ware doctor"      onClick={run} icon="🩺"/>
        <Btn label="Sync Mirrors"    cmd="ware sync"        onClick={run} icon="⟳"/>
        <Btn label="Clean Cache"     cmd="ware clean"       onClick={run} icon="✦"/>
        <Btn label="Autoremove"      cmd="ware autoremove"  onClick={run} icon="✖" variant="danger"/>
        <Btn label="Disk Health"     cmd="ware disk-health" onClick={run} icon="💾"/>
      </div>
    </div>
  );
}

function PackagesSection({run}) {
  const [tab,setTab]=useState("install");
  const [search,setSearch]=useState("");
  const [pkgs,setPkgs]=useState([]);
  useEffect(()=>{
    if(tab==="installed") {
      api("pacman -Q 2>/dev/null | head -60").then(r=>{
        const lines = r.stdout.trim().split("\n").filter(Boolean);
        setPkgs(lines.map(l=>{const[n,...v]=l.split(" ");return{name:n,version:v.join(" ")||"—",src:"pacman"};}));
      });
    }
  },[tab]);
  const filtered = pkgs.filter(p=>p.name?.toLowerCase().includes(search.toLowerCase()));
  const srcColor = {pacman:C.blue,flatpak:C.purple,aur:C.orange};
  return (
    <div>
      <Hdr title="Packages" sub="Install, remove, and manage packages across pacman, flatpak, and AUR."/>
      <div style={{display:"flex",gap:"6px",marginBottom:"16px"}}>
        {["install","installed","manage"].map(t=>(
          <button key={t} onClick={()=>setTab(t)} style={{background:tab===t?C.bgHover:"transparent",
            border:`1px solid ${tab===t?C.accent:C.borderFaint}`,color:tab===t?C.accentHi:C.textDim,
            borderRadius:"6px",padding:"6px 14px",cursor:"pointer",fontSize:"11px",
            textTransform:"capitalize",fontFamily:"inherit",fontWeight:tab===t?600:400}}>
            {t}
          </button>
        ))}
      </div>
      {tab==="install" && (
        <div style={{display:"flex",flexDirection:"column",gap:"10px"}}>
          <div style={{display:"flex",gap:"8px"}}>
            <input id="pkg-input" placeholder="Package name (pacman, flatpak app ID, or AUR)…"
              style={{background:C.bgCard,border:`1px solid ${C.border}`,color:C.text,
                borderRadius:"7px",padding:"9px 14px",fontSize:"12px",flex:1,outline:"none",fontFamily:"inherit"}}/>
            <button onClick={()=>{const v=document.getElementById("pkg-input")?.value;if(v)run(`ware install ${v}`,`Install: ${v}`);}}
              style={{background:C.accentHi,border:"none",color:"#111",borderRadius:"7px",
                padding:"9px 18px",cursor:"pointer",fontSize:"12px",fontFamily:"inherit",fontWeight:600}}>
              Install
            </button>
          </div>
          <div style={{display:"flex",gap:"8px"}}>
            <input id="pkg-search" placeholder="Search packages…"
              style={{background:C.bgCard,border:`1px solid ${C.border}`,color:C.text,
                borderRadius:"7px",padding:"9px 14px",fontSize:"12px",flex:1,outline:"none",fontFamily:"inherit"}}/>
            <button onClick={()=>{const v=document.getElementById("pkg-search")?.value;if(v)run(`ware search ${v}`,`Search: ${v}`);}}
              style={{background:"transparent",border:`1px solid ${C.border}`,color:C.text,borderRadius:"7px",
                padding:"9px 18px",cursor:"pointer",fontSize:"12px",fontFamily:"inherit"}}>
              Search
            </button>
          </div>
        </div>
      )}
      {tab==="installed" && (
        <>
          <input value={search} onChange={e=>setSearch(e.target.value)} placeholder="Filter…"
            style={{background:C.bgCard,border:`1px solid ${C.border}`,color:C.text,
              borderRadius:"7px",padding:"8px 14px",fontSize:"12px",width:"100%",
              boxSizing:"border-box",outline:"none",fontFamily:"inherit",marginBottom:"10px"}}/>
          <div style={{display:"flex",flexDirection:"column",gap:"4px",maxHeight:"280px",overflowY:"auto"}}>
            {filtered.map(p=>(
              <div key={p.name} style={{display:"flex",alignItems:"center",
                justifyContent:"space-between",background:C.bgCard,
                border:`1px solid ${C.borderFaint}`,borderRadius:"6px",padding:"8px 12px"}}>
                <div style={{display:"flex",alignItems:"center",gap:"10px"}}>
                  <span style={{background:(srcColor[p.src]||C.accent)+"22",
                    color:srcColor[p.src]||C.accent,fontSize:"9px",
                    borderRadius:"4px",padding:"2px 6px",textTransform:"uppercase"}}>{p.src}</span>
                  <span style={{color:C.text,fontSize:"12px"}}>{p.name}</span>
                </div>
                <div style={{display:"flex",alignItems:"center",gap:"10px"}}>
                  <span style={{color:C.muted,fontSize:"11px"}}>{p.version}</span>
                  <button onClick={()=>run(`ware remove ${p.name}`,`Remove ${p.name}`)}
                    style={{background:"transparent",border:`1px solid ${C.red}44`,
                      color:C.red,borderRadius:"4px",padding:"2px 8px",
                      cursor:"pointer",fontSize:"10px",fontFamily:"inherit"}}>
                    Remove
                  </button>
                </div>
              </div>
            ))}
          </div>
        </>
      )}
      {tab==="manage" && (
        <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"8px"}}>
          <Btn label="Update All"      cmd="ware update"     onClick={run} icon="↑" variant="success"/>
          <Btn label="Autoremove"      cmd="ware autoremove" onClick={run} icon="✖" variant="danger"/>
          <Btn label="Clean Cache"     cmd="ware clean"      onClick={run} icon="✦"/>
          <Btn label="List Installed"  cmd="ware list"       onClick={run} icon="◈"/>
          <Btn label="Repair System"   cmd="ware repair"     onClick={run} icon="🔧"/>
          <Btn label="Flatpak Perms"   cmd="ware flatpak list" onClick={run} icon="⬡"/>
        </div>
      )}
    </div>
  );
}

function PowerSection({run}) {
  const [active,setActive]=useState("balanced");
  const profiles = [
    {id:"balanced",   label:"Balanced",      icon:"⚖",  desc:"Optimal for everyday use — schedutil governor + TLP.",       c:C.blue},
    {id:"performance",label:"Performance",   icon:"⚡", desc:"Maximum CPU speed. Best for gaming or heavy compilation.",   c:C.orange},
    {id:"battery",    label:"Battery Saver", icon:"🔋", desc:"Minimises power draw with powersave governor + TLP.",         c:C.green},
  ];
  return (
    <div>
      <Hdr title="Power Management" sub="Switch CPU governor and TLP profiles."/>
      <div style={{display:"flex",flexDirection:"column",gap:"10px",marginBottom:"20px"}}>
        {profiles.map(p=>(
          <div key={p.id} onClick={()=>{setActive(p.id);run(`ware power ${p.id}`,`Power: ${p.label}`);}}
            style={{background:active===p.id?C.bgHover:C.bgCard,
              border:`1px solid ${active===p.id?p.c+"88":C.border}`,
              borderRadius:"9px",padding:"14px 18px",cursor:"pointer",
              display:"flex",alignItems:"center",gap:"14px",transition:"all 0.12s"}}>
            <span style={{fontSize:"20px"}}>{p.icon}</span>
            <div style={{flex:1}}>
              <div style={{color:active===p.id?p.c:C.text,fontWeight:600,fontSize:"13px"}}>{p.label}</div>
              <div style={{color:C.textDim,fontSize:"11px",marginTop:"2px"}}>{p.desc}</div>
            </div>
            {active===p.id && <div style={{color:p.c,fontSize:"14px"}}>●</div>}
          </div>
        ))}
      </div>
      <Btn label="Current Profile Status" cmd="ware power status" onClick={run} icon="◈"/>
    </div>
  );
}

function DisplaySection({run}) {
  const [sel,setSel]=useState("sddm");
  const dms = ["sddm","gdm","lightdm"];
  return (
    <div>
      <Hdr title="Display Manager" sub="Switch login screen managers. A reboot is required."/>
      <div style={{display:"flex",gap:"8px",marginBottom:"20px"}}>
        {dms.map(dm=>(
          <div key={dm} onClick={()=>setSel(dm)} style={{
            background:sel===dm?C.bgHover:C.bgCard,
            border:`1px solid ${sel===dm?C.accent:C.border}`,
            borderRadius:"8px",padding:"14px 20px",cursor:"pointer",
            textAlign:"center",transition:"all 0.12s",flex:1}}>
            <div style={{color:sel===dm?C.accentHi:C.text,fontWeight:600,
              fontSize:"13px",textTransform:"uppercase",letterSpacing:"0.06em"}}>{dm}</div>
            {sel===dm && <div style={{color:C.muted,fontSize:"9px",marginTop:"3px"}}>selected</div>}
          </div>
        ))}
      </div>
      <div style={{display:"flex",gap:"8px",flexWrap:"wrap"}}>
        <Btn label={`Switch to ${sel}`} cmd={`ware dm switch ${sel}`} onClick={run} icon="⬕" variant="success"/>
        <Btn label="Current Status"     cmd="ware dm status"           onClick={run} icon="◈"/>
      </div>
    </div>
  );
}

function NetworkSection({run}) {
  return (
    <div>
      <Hdr title="Network" sub="WiFi, DNS, and network utilities."/>
      <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"8px"}}>
        <Btn label="List Interfaces" cmd="ware network list"  onClick={run} icon="◈"/>
        <Btn label="Speed Test"      cmd="ware network speed" onClick={run} icon="⚡"/>
        <Btn label="Connect to WiFi" cmd="ware network wifi"  onClick={run} icon="◉"/>
        <Btn label="Change DNS"      cmd="ware network dns"   onClick={run} icon="◎"/>
      </div>
    </div>
  );
}

function SecuritySection({run}) {
  return (
    <div>
      <Hdr title="Security" sub="Firewall, LUKS, and system security tools."/>
      <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"8px"}}>
        <Btn label="Firewall Status"    cmd="sudo ufw status verbose"    onClick={run} icon="🔒"/>
        <Btn label="Enable Firewall"    cmd="sudo ufw enable"            onClick={run} icon="✔" variant="success"/>
        <Btn label="List LUKS Volumes"  cmd="ware luks list"             onClick={run} icon="🔐"/>
        <Btn label="USBGuard Status"    cmd="sudo usbguard list-devices" onClick={run} icon="◈"/>
        <Btn label="AppArmor Status"    cmd="sudo aa-status 2>/dev/null" onClick={run} icon="◉"/>
        <Btn label="SSH Status"         cmd="systemctl status sshd"      onClick={run} icon="◎"/>
      </div>
    </div>
  );
}

function GamingSection({run}) {
  return (
    <div>
      <Hdr title="Gaming" sub="GameMode, MangoHud, Wine, and Lutris."/>
      <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"8px",marginBottom:"16px"}}>
        <Btn label="GameMode Status"    cmd="systemctl --user status gamemoded" onClick={run} icon="⚡"/>
        <Btn label="Install Proton-GE"  cmd="paru -S --noconfirm proton-ge-custom-bin" onClick={run} icon="◈"/>
        <Btn label="Open Lutris"        cmd="lutris"                            onClick={run} icon="◎"/>
        <Btn label="MangoHud Test"      cmd="mangohud glxgears"                 onClick={run} icon="◉"/>
      </div>
      <div style={{background:C.bgCard,border:`1px solid ${C.border}`,borderRadius:"8px",padding:"14px 16px"}}>
        <div style={{color:C.textDim,fontSize:"11px",marginBottom:"8px"}}>Steam launch option for GameMode + MangoHud:</div>
        <code style={{color:C.accentHi,fontSize:"11px",fontFamily:"monospace"}}>
          gamemoderun mangohud %command%
        </code>
      </div>
    </div>
  );
}

function EnvsSection({run}) {
  const envs = [
    {id:"hyprland",label:"Hyprland",  icon:"◈", desc:"Tiling Wayland compositor with JaKooLit dotfiles.", badge:"Stable",badge_c:C.green},
    {id:"lazyvim", label:"LazyVim",   icon:"◉", desc:"Neovim with LazyVim starter config.",               badge:"Stable",badge_c:C.green},
    {id:"niri",    label:"Niri",      icon:"⬡", desc:"Scrollable-tiling Wayland compositor.",              badge:"Beta",  badge_c:C.yellow},
    {id:"snap",    label:"Snap",      icon:"⬕", desc:"Enable Snap package support.",                       badge:"Optional",badge_c:C.muted},
  ];
  return (
    <div>
      <Hdr title="Environments" sub="Install desktop environments and compositors."/>
      <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"10px"}}>
        {envs.map(e=>(
          <div key={e.id} style={{background:C.bgCard,border:`1px solid ${C.border}`,
            borderRadius:"9px",padding:"16px",display:"flex",flexDirection:"column",gap:"8px"}}>
            <div style={{display:"flex",justifyContent:"space-between",alignItems:"center"}}>
              <div style={{display:"flex",gap:"8px",alignItems:"center"}}>
                <span style={{color:C.accent,fontSize:"16px"}}>{e.icon}</span>
                <span style={{color:C.text,fontWeight:600,fontSize:"13px"}}>{e.label}</span>
              </div>
              <span style={{background:e.badge_c+"22",color:e.badge_c,fontSize:"9px",
                borderRadius:"4px",padding:"2px 6px"}}>{e.badge}</span>
            </div>
            <p style={{color:C.textDim,fontSize:"11px",lineHeight:1.5,margin:0}}>{e.desc}</p>
            <button onClick={()=>run(`ware setup ${e.id}`,`Setup ${e.label}`)}
              style={{background:"transparent",border:`1px solid ${C.border}`,
                color:C.accentHi,borderRadius:"6px",padding:"7px",cursor:"pointer",
                fontSize:"11px",fontFamily:"inherit",marginTop:"auto"}}>
              Install {e.label}
            </button>
          </div>
        ))}
      </div>
    </div>
  );
}

function AISection({run}) {
  const [question, setQuestion] = useState("");
  const [apiKeyPath] = useState("~/.config/skyware/api_key");
  return (
    <div>
      <Hdr title="AI Tools" sub="Claude-powered system diagnosis and assistant."/>
      <div style={{display:"flex",flexDirection:"column",gap:"12px"}}>
        <Btn label="Run AI Doctor"    cmd="ware ai doctor" onClick={run} icon="🤖" variant="accent"/>
        <div style={{background:C.bgCard,border:`1px solid ${C.border}`,borderRadius:"9px",padding:"16px"}}>
          <div style={{color:C.text,fontWeight:600,fontSize:"13px",marginBottom:"10px"}}>Ask Claude</div>
          <div style={{display:"flex",gap:"8px"}}>
            <input value={question} onChange={e=>setQuestion(e.target.value)}
              placeholder="Ask a Linux question…"
              onKeyDown={e=>e.key==="Enter"&&question&&run(`ware ai ask ${question}`,"AI: Ask")}
              style={{background:"#0e0e10",border:`1px solid ${C.border}`,color:C.text,
                borderRadius:"6px",padding:"8px 12px",fontSize:"12px",flex:1,
                outline:"none",fontFamily:"inherit"}}/>
            <button onClick={()=>question&&run(`ware ai ask ${question}`,"AI: Ask")}
              style={{background:C.accentHi,border:"none",color:"#111",borderRadius:"6px",
                padding:"8px 14px",cursor:"pointer",fontSize:"12px",fontFamily:"inherit",fontWeight:600}}>
              Ask
            </button>
          </div>
        </div>
        <div style={{background:C.bgCard,border:`1px solid ${C.border}`,
          borderRadius:"8px",padding:"14px 16px",fontSize:"11px",color:C.textDim,lineHeight:1.7}}>
          <div style={{color:C.text,marginBottom:"6px",fontWeight:500}}>API Key Setup</div>
          <code style={{color:C.accent}}>mkdir -p ~/.config/skyware</code><br/>
          <code style={{color:C.accent}}>echo 'sk-ant-...' &gt; ~/.config/skyware/api_key</code><br/>
          Or set <code style={{color:C.accent}}>ANTHROPIC_API_KEY</code> environment variable.
        </div>
      </div>
    </div>
  );
}

function SystemSection({run}) {
  return (
    <div>
      <Hdr title="System Tools" sub="Maintenance, backups, and system utilities."/>
      <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"8px"}}>
        <Btn label="Benchmark"          cmd="ware benchmark"      onClick={run} icon="⚡"/>
        <Btn label="Repair System"      cmd="ware repair"         onClick={run} icon="🔧"/>
        <Btn label="Sync Mirrors"       cmd="ware sync"           onClick={run} icon="⟳"/>
        <Btn label="Create Snapshot"    cmd="ware backup create"  onClick={run} icon="💾"/>
        <Btn label="List Snapshots"     cmd="ware backup list"    onClick={run} icon="☰"/>
        <Btn label="Open SkywareOS.io"  cmd="ware git"            onClick={run} icon="◎"/>
        <Btn label="Dual Boot Setup"    cmd="ware dualboot"       onClick={run} icon="⬡"/>
        <Btn label="Upgrade SkywareOS"  cmd="ware upgrade"        onClick={run} icon="↑" variant="success"/>
      </div>
    </div>
  );
}

/* ── Root App ── */
export default function App() {
  const [active, setActive] = useState("status");
  const [termOpen, setTermOpen] = useState(false);
  const { lines, add, clear } = useTerminal();

  const run = async (cmd, label) => {
    if (!cmd) return;
    setTermOpen(true);
    add(cmd, "cmd");
    add(`→ ${label || cmd}…`);
    const r = await api(cmd);
    if (r.stdout) r.stdout.trim().split("\n").filter(Boolean).forEach(l => add(l));
    if (r.stderr) r.stderr.trim().split("\n").filter(Boolean).forEach(l => add(l, "error"));
    add("✔ Done.", "success");
  };

  const sections = {
    status: StatusSection, packages: PackagesSection, power: PowerSection,
    display: DisplaySection, network: NetworkSection, security: SecuritySection,
    gaming: GamingSection, envs: EnvsSection, ai: AISection, system: SystemSection,
  };
  const Section = sections[active] || StatusSection;

  return (
    <div style={{height:"100vh",background:C.bg,
      fontFamily:"'Segoe UI','SF Pro Display',system-ui,sans-serif",
      color:C.text,display:"flex",flexDirection:"column",overflow:"hidden",position:"relative"}}>
      <TitleBar/>
      <div style={{display:"flex",flex:1,overflow:"hidden"}}>
        {/* Sidebar */}
        <div style={{width:"180px",background:C.bgSide,
          borderRight:`1px solid ${C.borderFaint}`,flexShrink:0,
          padding:"12px 0",overflowY:"auto",display:"flex",flexDirection:"column"}}>
          {SIDEBAR.map(s=>(
            <button key={s.id} onClick={()=>setActive(s.id)}
              style={{width:"100%",background:active===s.id?C.bgHover:"transparent",
                border:"none",borderLeft:`2px solid ${active===s.id?C.accent:"transparent"}`,
                color:active===s.id?C.accentHi:C.muted,padding:"9px 16px",
                cursor:"pointer",textAlign:"left",fontSize:"12px",fontFamily:"inherit",
                transition:"all 0.08s",display:"flex",alignItems:"center",gap:"9px"}}>
              <span style={{fontSize:"12px"}}>{s.icon}</span>
              {s.label}
            </button>
          ))}
          <div style={{marginTop:"auto",padding:"16px 16px 8px",
            borderTop:`1px solid ${C.borderFaint}`}}>
            <div style={{color:C.mutedLo,fontSize:"9px",lineHeight:1.9}}>
              <div>ware v2.0</div>
              <div>Maroon 2.0</div>
            </div>
          </div>
        </div>
        {/* Content */}
        <div style={{flex:1,padding:"24px 28px",overflowY:"auto",
          paddingBottom: termOpen ? "226px" : "24px"}}>
          <Section run={run}/>
        </div>
      </div>
      {/* Terminal */}
      {termOpen && <Terminal lines={lines} onClose={()=>setTermOpen(false)} onClear={clear}/>}
      {!termOpen && (
        <button onClick={()=>{setTermOpen(true);if(lines.length===0)add("Terminal ready.","info");}}
          style={{position:"absolute",bottom:"10px",right:"14px",
            background:C.bgCard,border:`1px solid ${C.border}`,
            color:C.textDim,borderRadius:"5px",padding:"5px 12px",
            cursor:"pointer",fontSize:"10px",fontFamily:"inherit",
            letterSpacing:"0.08em",zIndex:40}}>
          TERMINAL ▲
        </button>
      )}
    </div>
  );
}
APPEOF

    # ── Build ─────────────────────────────────────────────────────────────
    info "Installing npm dependencies..."
    cd "$app_dir"
    npm install 2>&1 | tail -5
    npm install --save-dev electron 2>&1 | tail -3

    info "Building React app..."
    npx vite build 2>&1 | tail -5

    if [[ ! -f "$app_dir/dist/index.html" ]]; then
        warn "Vite build failed — retrying with verbose output:"
        npx vite build
    fi

    # Fix ownership back to root
    sudo chown -R root:root "$app_dir"
    sudo chmod -R a+rX "$app_dir"

    # ── Launcher script ───────────────────────────────────────────────────
    sudo tee /usr/local/bin/skyware-settings > /dev/null << 'EOF'
#!/bin/bash
cd /opt/skyware-settings
exec npx electron . "$@"
EOF
    sudo chmod +x /usr/local/bin/skyware-settings

    # ── .desktop ─────────────────────────────────────────────────────────
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

    mkdir -p "$ORIGINAL_HOME/Desktop"
    cp /usr/share/applications/skyware-settings.desktop \
        "$ORIGINAL_HOME/Desktop/skyware-settings.desktop"
    chmod +x "$ORIGINAL_HOME/Desktop/skyware-settings.desktop"
    chown "$ORIGINAL_USER:$ORIGINAL_USER" \
        "$ORIGINAL_HOME/Desktop/skyware-settings.desktop"

    ok "SkywareOS Settings App v2.0 installed"
}

# ══════════════════════════════════════════════════════════════════════════
# Welcome App (first boot)
# ══════════════════════════════════════════════════════════════════════════
install_welcome_app() {
    phase "Welcome App (first boot)"

    local app_dir="/opt/skyware-welcome"
    sudo mkdir -p "$app_dir/src"
    sudo chown -R "$ORIGINAL_USER:$ORIGINAL_USER" "$app_dir"

    cat > "$app_dir/package.json" << 'EOF'
{
  "name": "skyware-welcome",
  "version": "2.0.0",
  "description": "SkywareOS First Boot Welcome",
  "main": "main.js",
  "scripts": { "start": "electron .", "build": "vite build" },
  "dependencies": { "react": "^18.3.0", "react-dom": "^18.3.0" },
  "devDependencies": { "electron": "^31.0.0", "@vitejs/plugin-react": "^4.3.0", "vite": "^5.3.0" }
}
EOF

    cat > "$app_dir/main.js" << 'EOF'
const { app, BrowserWindow, ipcMain, shell } = require('electron');
const path = require('path');
const fs   = require('fs');
const os   = require('os');
const DONE_FLAG = path.join(os.homedir(), '.config/skyware/welcome-done');

function createWindow() {
  if (fs.existsSync(DONE_FLAG)) { app.quit(); return; }
  const win = new BrowserWindow({
    width: 780, height: 560, frame: false, center: true,
    backgroundColor: '#111113', resizable: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
    },
    title: 'Welcome to SkywareOS',
  });
  const dist = path.join(__dirname, 'dist', 'index.html');
  fs.existsSync(dist) ? win.loadFile(dist) : win.loadURL('about:blank');
}

ipcMain.on('finish', () => {
  fs.mkdirSync(path.dirname(DONE_FLAG), { recursive: true });
  fs.writeFileSync(DONE_FLAG, '');
  app.quit();
});
ipcMain.on('open-link', (_, url) => shell.openExternal(url));
ipcMain.on('win-close', e => BrowserWindow.fromWebContents(e.sender)?.close());

app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
EOF

    cat > "$app_dir/preload.js" << 'EOF'
const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('welcome', {
  finish:   ()    => ipcRenderer.send('finish'),
  openLink: url   => ipcRenderer.send('open-link', url),
  close:    ()    => ipcRenderer.send('win-close'),
});
EOF

    cat > "$app_dir/vite.config.js" << 'EOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({ plugins:[react()], base:'./', build:{ outDir:'dist' } });
EOF

    cat > "$app_dir/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8"/>
  <title>Welcome to SkywareOS</title>
  <style>*{margin:0;padding:0;box-sizing:border-box;}body{overflow:hidden;background:#111113;}#root{height:100vh;}</style>
</head>
<body>
  <div id="root"></div>
  <script type="module" src="/src/main.jsx"></script>
</body>
</html>
EOF

    mkdir -p "$app_dir/src"
    cat > "$app_dir/src/main.jsx" << 'EOF'
import React from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.jsx';
createRoot(document.getElementById('root')).render(<App />);
EOF

    cat > "$app_dir/src/App.jsx" << 'WELCOMEEOF'
import { useState } from "react";
const C = {
  bg:"#111113",card:"#17171a",border:"#28282d",accent:"#9090a0",accentHi:"#c0c0d4",
  text:"#e0e0ea",dim:"#707080",muted:"#454552",
  green:"#4ade80",blue:"#60a5fa",yellow:"#facc15",red:"#f87171"
};
const STEPS = [
  {id:"welcome", label:"Welcome"},
  {id:"features",label:"Features"},
  {id:"quickstart",label:"Quick Start"},
  {id:"done",    label:"Done"},
];
const FEATURES = [
  {icon:"⬡",t:"ware",d:"Unified package manager wrapping pacman, flatpak, and AUR."},
  {icon:"⚙",t:"Settings App",d:"Full GUI — packages, power, security, networking, AI."},
  {icon:"⚡",t:"GameMode + MangoHud",d:"Performance overlay and CPU/GPU boost for gaming."},
  {icon:"◈",t:"AI Doctor",d:"ware ai doctor — Claude diagnoses your system issues."},
  {icon:"🔒",t:"Security Suite",d:"UFW, AppArmor, USBGuard, fail2ban — all pre-configured."},
  {icon:"◉",t:"Wayland-first",d:"All DEs default to Wayland. X11 available as fallback."},
  {icon:"💾",t:"Auto-snapshots",d:"Timeshift configured for weekly + monthly backups."},
  {icon:"◎",t:"Network Tools",d:"WiFi wizard, DNS switcher, speed test — all in ware."},
];
const CMDS = [
  ["ware help",           "Full command list"],
  ["ware install <pkg>",  "Install any package"],
  ["ware update",         "Update everything"],
  ["ware ai doctor",      "AI system diagnosis"],
  ["ware benchmark",      "CPU/RAM/disk test"],
  ["ware network wifi",   "Connect to WiFi"],
  ["skyware-settings",    "Open Settings GUI"],
];

export default function App() {
  const [step, setStep] = useState(0);
  const s = STEPS[step];
  const next = () => step < STEPS.length - 1 ? setStep(step + 1) : window.welcome?.finish();

  return (
    <div style={{height:"100vh",background:C.bg,
      fontFamily:"'Segoe UI',system-ui,sans-serif",color:C.text,
      display:"flex",flexDirection:"column",overflow:"hidden"}}>
      {/* Title */}
      <div style={{height:"44px",background:"#0a0a0c",
        borderBottom:`1px solid ${C.border}`,display:"flex",
        alignItems:"center",justifyContent:"space-between",
        padding:"0 16px",WebkitAppRegion:"drag",flexShrink:0}}>
        <div style={{display:"flex",alignItems:"center",gap:"8px"}}>
          <div style={{width:"20px",height:"20px",borderRadius:"4px",
            background:`linear-gradient(135deg,${C.accent},#404050)`,
            display:"flex",alignItems:"center",justifyContent:"center",
            fontSize:"11px",fontWeight:900,color:"#fff"}}>S</div>
          <span style={{fontSize:"12px",fontWeight:600}}>Welcome to SkywareOS</span>
        </div>
        <button onClick={()=>window.welcome?.close()} style={{WebkitAppRegion:"no-drag",
          background:"none",border:"none",color:C.muted,cursor:"pointer",fontSize:"16px"}}>×</button>
      </div>
      {/* Steps */}
      <div style={{display:"flex",justifyContent:"center",gap:"6px",padding:"16px 0 0",flexShrink:0}}>
        {STEPS.map((st,i)=>(
          <div key={st.id} style={{display:"flex",alignItems:"center",gap:"6px"}}>
            <div style={{width:"22px",height:"22px",borderRadius:"50%",
              background:i<=step?C.accent:"transparent",
              border:`1px solid ${i<=step?C.accent:C.border}`,
              display:"flex",alignItems:"center",justifyContent:"center",
              fontSize:"10px",color:i<=step?"#111":C.muted,fontWeight:600}}>{i+1}</div>
            {i<STEPS.length-1 && <div style={{width:"28px",height:"1px",background:i<step?C.accent:C.border}}/>}
          </div>
        ))}
      </div>
      {/* Content */}
      <div style={{flex:1,padding:"20px 36px",overflowY:"auto"}}>
        {s.id==="welcome" && (
          <div style={{textAlign:"center",paddingTop:"4px"}}>
            <pre style={{fontFamily:"monospace",fontSize:"10px",color:C.muted,
              lineHeight:1.6,marginBottom:"16px",display:"inline-block",textAlign:"left"}}>{
`      @@@@@@@-         +@@@@@@.
    %@@@@@@@@@@=      @@@@@@@@@@
   @@@@     @@@@@      -     #@@@
  :@@*        @@@@             @@@
  @@@          @@@@            @@@
  @@@           @@@@           %@@
  @@@            @@@@          @@@
   @@@@     =      @@@@@     %@@@
    @@@@@@@@@@       @@@@@@@@@@@
      @@@@@@+          %@@@@@@`}</pre>
            <h1 style={{fontSize:"26px",fontWeight:700,marginBottom:"6px",
              letterSpacing:"-0.03em"}}>
              Welcome to <span style={{color:C.accentHi}}>SkywareOS</span>
            </h1>
            <p style={{color:C.dim,fontSize:"13px",lineHeight:1.6,maxWidth:"380px",margin:"0 auto"}}>
              An Arch-based Linux distro built for performance, customisation, and a clean Wayland-first experience.
            </p>
            <div style={{display:"flex",justifyContent:"center",gap:"8px",marginTop:"16px",flexWrap:"wrap"}}>
              {["Wayland-first","ware v2.0","AI-powered","Maroon 2.0"].map(tag=>(
                <span key={tag} style={{background:C.card,border:`1px solid ${C.border}`,
                  color:C.dim,fontSize:"10px",borderRadius:"999px",padding:"3px 10px"}}>{tag}</span>
              ))}
            </div>
          </div>
        )}
        {s.id==="features" && (
          <div>
            <h2 style={{fontSize:"16px",fontWeight:600,marginBottom:"4px"}}>What's included</h2>
            <p style={{color:C.dim,fontSize:"11px",marginBottom:"16px"}}>Pre-configured and ready to go.</p>
            <div style={{display:"grid",gridTemplateColumns:"1fr 1fr",gap:"8px"}}>
              {FEATURES.map(f=>(
                <div key={f.t} style={{background:C.card,border:`1px solid ${C.border}`,
                  borderRadius:"8px",padding:"12px 14px",display:"flex",gap:"10px",alignItems:"flex-start"}}>
                  <span style={{fontSize:"18px",flexShrink:0}}>{f.icon}</span>
                  <div>
                    <div style={{fontWeight:600,fontSize:"12px",marginBottom:"2px"}}>{f.t}</div>
                    <div style={{color:C.dim,fontSize:"11px",lineHeight:1.4}}>{f.d}</div>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
        {s.id==="quickstart" && (
          <div>
            <h2 style={{fontSize:"16px",fontWeight:600,marginBottom:"4px"}}>Quick Start</h2>
            <p style={{color:C.dim,fontSize:"11px",marginBottom:"16px"}}>Everything you need to know.</p>
            <div style={{display:"flex",flexDirection:"column",gap:"6px"}}>
              {CMDS.map(([cmd,desc])=>(
                <div key={cmd} style={{background:C.card,border:`1px solid ${C.border}`,
                  borderRadius:"7px",padding:"10px 14px",display:"flex",
                  justifyContent:"space-between",alignItems:"center",gap:"12px"}}>
                  <code style={{color:C.accentHi,fontSize:"12px",fontFamily:"monospace"}}>{cmd}</code>
                  <span style={{color:C.dim,fontSize:"11px",flexShrink:0}}>{desc}</span>
                </div>
              ))}
            </div>
          </div>
        )}
        {s.id==="done" && (
          <div style={{textAlign:"center",paddingTop:"16px"}}>
            <div style={{fontSize:"44px",marginBottom:"12px"}}>✔</div>
            <h2 style={{fontSize:"20px",fontWeight:700,marginBottom:"6px",color:C.green}}>
              You're all set
            </h2>
            <p style={{color:C.dim,fontSize:"13px",lineHeight:1.6,maxWidth:"340px",margin:"0 auto 20px"}}>
              SkywareOS is ready. Open settings with <span style={{color:C.accentHi,fontFamily:"monospace"}}>skyware-settings</span>.
            </p>
            <div style={{background:C.card,border:`1px solid ${C.border}`,borderRadius:"8px",
              padding:"14px 20px",display:"inline-block",textAlign:"left"}}>
              <div style={{fontFamily:"monospace",fontSize:"11px",color:C.dim,lineHeight:2.2}}>
                {[["ware help","→ all commands"],["ware update","→ update system"],
                  ["ware ai doctor","→ AI diagnosis"],["skyware-settings","→ GUI"]].map(([c,d])=>(
                  <div key={c}><span style={{color:C.accent}}>$ </span>{c} <span style={{color:C.muted}}>{d}</span></div>
                ))}
              </div>
            </div>
          </div>
        )}
      </div>
      {/* Footer */}
      <div style={{padding:"14px 36px",borderTop:`1px solid ${C.border}`,
        display:"flex",justifyContent:"space-between",alignItems:"center",
        flexShrink:0,background:"#0a0a0c"}}>
        <button onClick={()=>step>0&&setStep(step-1)} disabled={step===0}
          style={{background:"transparent",border:`1px solid ${C.border}`,
            color:step===0?C.muted:C.text,borderRadius:"6px",padding:"8px 18px",
            cursor:step===0?"not-allowed":"pointer",fontSize:"12px",
            fontFamily:"inherit",opacity:step===0?0.4:1}}>
          ← Back
        </button>
        <div style={{display:"flex",gap:"4px"}}>
          {STEPS.map((_,i)=>(
            <div key={i} style={{width:i===step?16:6,height:6,borderRadius:"999px",
              background:i===step?C.accent:C.border,transition:"all 0.2s"}}/>
          ))}
        </div>
        <button onClick={next}
          style={{background:C.accentHi,border:"none",color:"#111",borderRadius:"6px",
            padding:"8px 22px",cursor:"pointer",fontSize:"12px",
            fontFamily:"inherit",fontWeight:700}}>
          {step===STEPS.length-1?"Get Started →":"Next →"}
        </button>
      </div>
    </div>
  );
}
WELCOMEEOF

    # Build
    cd "$app_dir"
    npm install 2>&1 | tail -5
    npm install --save-dev electron 2>&1 | tail -3
    npx vite build 2>&1 | tail -5

    sudo chown -R root:root "$app_dir"
    sudo chmod -R a+rX "$app_dir"

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

    mkdir -p "$ORIGINAL_HOME/.config/autostart"
    cat > "$ORIGINAL_HOME/.config/autostart/skyware-welcome.desktop" << 'EOF'
[Desktop Entry]
Name=SkywareOS Welcome
Exec=/usr/local/bin/skyware-welcome
Type=Application
X-GNOME-Autostart-enabled=true
EOF
    chown "$ORIGINAL_USER:$ORIGINAL_USER" \
        "$ORIGINAL_HOME/.config/autostart/skyware-welcome.desktop"

    ok "Welcome App installed"
}

# ── Final cleanup + summary ───────────────────────────────────────────────
final_cleanup() {
    phase "Final cleanup"

    # xdg user dirs
    sudo -u "$ORIGINAL_USER" xdg-user-dirs-update 2>/dev/null || true

    # Enable NetworkManager
    sudo systemctl enable NetworkManager 2>/dev/null || true

    # SystemD user services for original user
    sudo -u "$ORIGINAL_USER" systemctl --user daemon-reload 2>/dev/null || true

    # Ensure wheel group exists and user is in it
    sudo groupadd -f wheel
    sudo usermod -aG wheel,docker,audio,video,storage,gamemode "$ORIGINAL_USER" 2>/dev/null || true

    # Remove orphans
    local orphans; orphans=$(pacman -Qtdq 2>/dev/null || true)
    [[ -n "$orphans" ]] && sudo pacman -Rns --noconfirm $orphans 2>/dev/null || true

    ok "Cleanup complete"
}

print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║         SkywareOS Setup Complete!             ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${GREEN}✔${RESET}  SkywareOS Maroon 2.0 fully installed"
    echo -e "  ${GREEN}✔${RESET}  ware v2.0 package manager available"
    echo -e "  ${GREEN}✔${RESET}  Settings app at: ${CYAN}skyware-settings${RESET}"
    echo -e "  ${GREEN}✔${RESET}  AI Doctor at:    ${CYAN}ware ai doctor${RESET}"
    echo -e "  ${GREEN}✔${RESET}  Setup log:       ${CYAN}$LOGFILE${RESET}"
    echo ""
    echo -e "  ${YELLOW}!${RESET}  A ${BOLD}reboot is required${RESET} to apply all changes."
    echo ""
    echo -e "  ${DIM}New in v2.0:${RESET}"
    echo -e "  ${DIM}→${RESET}  ware ai ask <question>   AI assistant in terminal"
    echo -e "  ${DIM}→${RESET}  ware network <action>    Network wizard"
    echo -e "  ${DIM}→${RESET}  ware luks <action>       Encryption helpers"
    echo -e "  ${DIM}→${RESET}  ware disk-health         SMART disk report"
    echo -e "  ${DIM}→${RESET}  ware backup restic-*     restic integration"
    echo -e "  ${DIM}→${RESET}  Settings: 10 sections    AI, gaming, security, network"
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════
# Main execution
# ══════════════════════════════════════════════════════════════════════════
main() {
    echo -e "${BOLD}${CYAN}"
    cat << 'BANNER'
  ╔═══════════════════════════════════════════════╗
  ║        SkywareOS Setup Script v2.0            ║
  ║           Maroon Release — 2026              ║
  ╚═══════════════════════════════════════════════╝
BANNER
    echo -e "${RESET}"

    preflight
    configure_sudo
    configure_pacman
    ensure_paru
    install_base
    install_gpu_drivers
    install_desktop
    configure_sddm
    configure_plymouth
    configure_limine
    configure_fastfetch
    configure_os_release
    configure_shell
    configure_btop
    configure_tmux
    install_flatpak_apps
    configure_security
    configure_kde
    configure_cursor
    configure_motd
    configure_bluetooth
    configure_printing
    configure_gestures
    configure_locale
    configure_containers
    configure_vpn
    configure_tlp
    configure_gaming
    configure_automount
    configure_fingerprint
    configure_multimonitor
    configure_timeshift
    configure_dotfiles
    install_ware
    install_ai_doctor
    install_update_notifier
    install_settings_app
    install_welcome_app
    final_cleanup
    print_summary
}

main "$@"
