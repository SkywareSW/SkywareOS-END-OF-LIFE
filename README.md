# SkywareOS

<details>
<summary>Update Logs</summary>
<br>

# Red (V0.6.1)

* Added Version display to ware status

# Red (V0.6)

* Added snap support (ware setup snap)
* Made GPU Drivers get automatically detected instead of having to be manually selected
* Dramatically improved ware search

# Red (V0.5)

* Made installation significantly faster by adding --needed to most installation commands
* Made installer change to sed (was broken before)
* ware optimizations


</details>

<details>
<summary>Installation</summary>
<br>

# Installation

Run this in your install

git clone https://github.com/SkywareSW/SkywareOS \
cd SkywareOS\
chmod +x skyware-setup.sh\
./skyware-setup.sh
</details>


<details>
<summary>Documentation</summary>
<br>

# Documentation

* Ware

* ware status - Shows kernel and version, Uptime, Available updates, Firewall status, Disk usage, Memory usage, Current Desktop, Current channel and current version

* ware install <pkg> - Searches for said package through pacman, flatpak and aur and then proceeds to install it

* ware remove <pkg>  - Removes package from system

* ware update - Updates system and or specific package

* ware upgrade - Installs and runs the latest version of SkywareOS

* ware switch - Switches from the Release channel to the Testing channel

* ware power (balanced/performance/battery) - Switches power mode to either of those three depending on the selection

* ware dm list - Lists available display managers

* ware dm status - Shows currently active display manager

* ware dm switch(sddm/gdm/lightdm) - Switch between the available display managers

* ware search <pkg> - Searches for the package or closest matching keyword in pacman, flatpak and aur

* ware info <pkg> - Gives available information on a package

* ware list - Shows installed packages

* ware doctor - Searches for and fixes any corrupt or broken packages/dependencies, then checks the firewall status

* ware clean - Removes unused repositories/packages

* ware autoremove - Automatically removes unused packages

* ware sync - Syncs mirrors

* ware interactive - Simpler way to install a package

* ware --json <command> - Run a custom command/script using JSON

* ware setup hyprland - Automatically Sets up hyprland with jakoolit's dotfiles\

* ware setup lazyvim - Automatically sets up Lazyvim

* ware setup niri - Automatically sets up Niri (EXPERIMENTAL)

* ware setup mango - Automatically sets up MangoWC (EXPERIMENTAL)

* ware setup snap - Installs and enables the Snap package manager

* ware setup snap-remove - Removes the Snap package manager


</details>
