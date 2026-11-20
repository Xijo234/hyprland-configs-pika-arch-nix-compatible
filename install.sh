#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_ROOT="${HOME}/.local/state/arch-configs-backups/$(date +%Y%m%d-%H%M%S)"
DRY_RUN=0
PACKAGES_ONLY=0
CONFIGS_ONLY=0
NO_BACKUP=0

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]
  --dry-run       Show actions without changing anything
  --configs-only  Deploy configs without installing packages
  --packages-only Install packages without deploying configs
  --no-backup     Do not back up existing destinations
  -h, --help      Show this help

Wallpaper folders and image assets are intentionally not touched.
USAGE
}

for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --packages-only) PACKAGES_ONLY=1 ;;
        --configs-only) CONFIGS_ONLY=1 ;;
        --no-backup) NO_BACKUP=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

if (( PACKAGES_ONLY && CONFIGS_ONLY )); then
    echo 'Choose either --packages-only or --configs-only, not both.' >&2
    exit 2
fi

for required in hyprlite fastfetch starship; do
    if [[ ! -d "$REPO_ROOT/$required" ]]; then
        printf 'Missing repository directory: %s\n' "$REPO_ROOT/$required" >&2
        exit 1
    fi
done

run() {
    if (( DRY_RUN )); then
        printf '[DRY RUN]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

backup_target() {
    local target="$1"
    local relative backup_path

    if (( NO_BACKUP )); then
        printf 'Backup disabled: %s\n' "$target"
        return 0
    fi
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        printf 'No existing destination to back up: %s\n' "$target"
        return 0
    fi
    case "$target" in
        "$HOME"/*) relative="${target#"$HOME"/}" ;;
        *) echo "Refusing to back up a path outside HOME: $target" >&2; return 1 ;;
    esac
    backup_path="$BACKUP_ROOT/$relative"

    if (( DRY_RUN )); then
        printf '[DRY RUN] backup %q -> %q\n' "$target" "$backup_path"
        return 0
    fi

    mkdir -p -- "$(dirname -- "$backup_path")"
    if [[ -e "$backup_path" || -L "$backup_path" ]]; then
        printf 'Backup already exists; refusing to overwrite it: %s\n' "$backup_path" >&2
        return 1
    fi
    cp -a -- "$target" "$backup_path"
    printf 'Backed up: %s -> %s\n' "$target" "$backup_path"
}

deploy_file() {
    local source="$1" destination="$2"
    [[ -f "$source" ]] || { printf 'Missing source file: %s\n' "$source" >&2; return 1; }
    if [[ -d "$destination" && ! -L "$destination" ]]; then
        printf 'Destination is a directory, expected a file: %s\n' "$destination" >&2
        return 1
    fi
    backup_target "$destination"
    run mkdir -p -- "$(dirname -- "$destination")"
    run install -m "$(stat -c '%a' "$source")" -- "$source" "$destination"
    printf '%s: %s\n' "$([[ $DRY_RUN == 1 ]] && echo 'Would install' || echo 'Installed')" "$destination"
}

deploy_tree() {
    local source="$1" destination="$2"
    [[ -d "$source" ]] || { printf 'Missing source directory: %s\n' "$source" >&2; return 1; }
    if [[ -f "$destination" && ! -L "$destination" ]]; then
        printf 'Destination is a file, expected a directory: %s\n' "$destination" >&2
        return 1
    fi
    backup_target "$destination"
    run mkdir -p -- "$destination"
    if (( DRY_RUN )); then
        printf '[DRY RUN] copy contents of %q -> %q\n' "$source" "$destination"
    else
        cp -a -- "$source/." "$destination/"
        printf 'Installed directory contents: %s -> %s\n' "$source" "$destination"
    fi
}

install_arch_packages() {
    local packages=(
        hyprland waybar hyprpaper hyprlock rofi-wayland kitty yazi
        fastfetch starship btop playerctl wl-clipboard cliphist
        python ttf-jetbrains-mono-nerd
    )
    run sudo pacman -S --needed "${packages[@]}"
}

install_debian_packages() {
    local packages=(
        hyprland waybar hyprpaper hyprlock rofi kitty yazi fastfetch
        starship btop playerctl wl-clipboard cliphist python3 fonts-jetbrains-mono
    )
    local available=() package
    for package in "${packages[@]}"; do
        if apt-cache show "$package" >/dev/null 2>&1; then
            available+=("$package")
        else
            printf 'Skipping package not found in configured apt sources: %s\n' "$package"
        fi
    done
    if ((${#available[@]} == 0)); then
        echo 'No listed packages were found in apt sources; nothing to install.'
        return 0
    fi
    run sudo apt update
    run sudo apt install -y "${available[@]}"
}

install_nix_packages() {
    local packages=(
        nixpkgs#hyprland nixpkgs#waybar nixpkgs#hyprpaper nixpkgs#hyprlock
        nixpkgs#rofi nixpkgs#kitty nixpkgs#yazi nixpkgs#fastfetch
        nixpkgs#starship nixpkgs#btop nixpkgs#playerctl nixpkgs#wl-clipboard
        nixpkgs#cliphist nixpkgs#python3 nixpkgs#nerd-fonts.jetbrains-mono
    )
    run nix profile install "${packages[@]}"
    echo 'Note: this uses a user Nix profile; it does not edit configuration.nix or Home Manager.'
}

install_packages() {
    [[ -r /etc/os-release ]] || { echo 'Cannot read /etc/os-release.' >&2; return 1; }
    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        arch|cachyos|manjaro) install_arch_packages ;;
        pika|pikaos|debian|ubuntu|linuxmint) install_debian_packages ;;
        nixos) install_nix_packages ;;
        *)
            case " ${ID_LIKE:-} " in
                *' arch '*) install_arch_packages ;;
                *' debian '*) install_debian_packages ;;
                *) printf 'Unsupported distribution ID=%s ID_LIKE=%s\n' "${ID:-unknown}" "${ID_LIKE:-}" >&2; return 1 ;;
            esac
            ;;
    esac
}

install_configs() {
    # hyprlite includes hyprland.lua, Waybar, and its helper script.
    deploy_tree "$REPO_ROOT/hyprlite" "$HOME/.config/hyprlite"

    # Only deploy the two Rofi files supplied by this repo; preserve other Rofi assets.
    deploy_file "$REPO_ROOT/hyprlite/rofi/config.rasi" "$HOME/.config/rofi/config.rasi"
    deploy_file "$REPO_ROOT/hyprlite/rofi/theme.rasi" "$HOME/.config/rofi/theme.rasi"

    # Fastfetch config only. User manages needle.png separately.
    deploy_tree "$REPO_ROOT/fastfetch" "$HOME/.config/fastfetch"

    # pill.toml is active; all other layouts remain available under layouts/.
    deploy_file "$REPO_ROOT/starship/layouts/pill.toml" "$HOME/.config/starship.toml"
    deploy_tree "$REPO_ROOT/starship" "$HOME/.config/starship"

    echo 'Wallpapers and ~/Pictures/Wallpapers were not touched.'
    echo 'Fastfetch image assets were not copied; manage needle.png yourself.'
}

printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Backup destination: %s\n' "$BACKUP_ROOT"
if (( DRY_RUN )); then echo 'DRY RUN: no files or packages will be changed.'; fi

if (( ! CONFIGS_ONLY )); then install_packages; fi
if (( ! PACKAGES_ONLY )); then install_configs; fi

printf '\n%s\n' 'Installer finished.'
if (( ! NO_BACKUP && ! DRY_RUN )); then
    printf 'Existing destinations backed up under: %s\n' "$BACKUP_ROOT"
fi
