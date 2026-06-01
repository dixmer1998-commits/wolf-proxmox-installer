#!/bin/bash
set -uo pipefail

#=============================================================================
# Wolf (Games On Whales) - Instalador para Proxmox
# Instalacion completa de Wolf gaming streaming en Proxmox con AMD GPU
#=============================================================================

REPO_URL="https://raw.githubusercontent.com/dixmer1998-commits/wolf-proxmox-installer/main"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="${BASH_SOURCE[0]:-}"
if [[ -n "$SCRIPT_DIR" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_DIR")" && pwd)"
else
    SCRIPT_DIR="/tmp/wolf-gow-setup"
fi
mkdir -p "$SCRIPT_DIR"

print_banner() {
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║       🐺  Wolf (Games On Whales) - Instalador Proxmox  🐺   ║"
    echo "║                                                              ║"
    echo "║      Instalacion automatica con AMD GPU passthrough          ║"
    echo "║            Wolf + Wolf Den + Gaming Streaming                ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[PASO]${NC} $1"; }

download_helpers() {
    log_step "Descargando scripts auxiliares..."

    local tmp_dir="/tmp/wolf-setup-git-$$"
    local repo_url="https://github.com/dixmer1998-commits/wolf-proxmox-installer.git"

    # Usar git clone para evitar cache de CDN
    if ! git clone --depth 1 "$repo_url" "$tmp_dir" 2>/dev/null; then
        # Fallback: intentar con curl si git no funciona
        log_warn "Git clone fallo, intentando con curl..."
        local scripts=("host-config.sh" "create-lxc.sh" "configure-lxc.sh")
        for script in "${scripts[@]}"; do
            log_info "Descargando ${script}..."
            if ! curl -fsSL "${REPO_URL}/${script}?v=$(date +%s)" -o "${SCRIPT_DIR}/${script}"; then
                log_error "Error al descargar ${script}"
                exit 1
            fi
            chmod +x "${SCRIPT_DIR}/${script}"
        done
        log_info "Scripts descargados correctamente (curl)"
        return 0
    fi

    cp "$tmp_dir/"*.sh "$SCRIPT_DIR/"
    chmod +x "$SCRIPT_DIR/"*.sh
    rm -rf "$tmp_dir"
    log_info "Scripts descargados correctamente (git)"
}

main() {
    print_banner
    check_root
    check_proxmox

    # Asegurar que git esta instalado para descargar helpers
    if ! command -v git &>/dev/null; then
        log_warn "Git no instalado, instalando..."
        apt-get update -qq 2>/dev/null && apt-get install -y -qq git 2>/dev/null || true
    fi

    download_helpers

    while true; do
        print_menu
        read -p "Seleccione una opcion [1-5]: " choice

        case $choice in
            1)
                run_full_installation
                break
                ;;
            2)
                run_phase1
                break
                ;;
            3)
                run_phase2
                break
                ;;
            4)
                run_phase3
                break
                ;;
            5)
                echo "Saliendo..."
                exit 0
                ;;
            *)
                log_warn "Opcion invalida. Seleccione 1-5."
                ;;
        esac
    done
}

main "$@"
