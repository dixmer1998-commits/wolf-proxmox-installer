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

    local scripts=("host-config.sh" "create-lxc.sh" "configure-lxc.sh")
    local missing=()

    for script in "${scripts[@]}"; do
        if [[ ! -f "${SCRIPT_DIR}/${script}" ]]; then
            missing+=("$script")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Todos los scripts ya estan descargados"
        return 0
    fi

    for script in "${missing[@]}"; do
        log_info "Descargando ${script}..."
        if ! curl -fsSL "${REPO_URL}/${script}" -o "${SCRIPT_DIR}/${script}"; then
            log_error "Error al descargar ${script}"
            exit 1
        fi
        chmod +x "${SCRIPT_DIR}/${script}"
    done

    log_info "Scripts auxiliares descargados correctamente"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
        echo "Uso: sudo ./install.sh"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log_error "Este script debe ejecutarse en un host Proxmox VE"
        exit 1
    fi
    log_info "Proxmox detectado: $(pveversion | head -1)"
}

print_menu() {
    echo -e "${CYAN}=== Opciones de Instalacion ===${NC}"
    echo ""
    echo "  1) Instalacion completa (las 3 fases)"
    echo "     - Fase 1: Configuracion del host (firmware, udev rules)"
    echo "     - Fase 2: Crear contenedor LXC"
    echo "     - Fase 3: Instalar Wolf y Wolf Den"
    echo ""
    echo "  2) Solo Fase 1: Configurar host (sin reinicio necesario)"
    echo ""
    echo "  3) Solo Fase 2: Crear contenedor LXC"
    echo ""
    echo "  4) Solo Fase 3: Configurar LXC (despues de crear el contenedor)"
    echo ""
    echo "  5) Salir"
    echo ""
}

run_phase1() {
    log_step "Ejecutando Fase 1: Configuracion del Host..."
    echo ""
    bash "${SCRIPT_DIR}/host-config.sh"
}

run_phase2() {
    log_step "Ejecutando Fase 2: Creacion del Contenedor LXC..."
    echo ""
    bash "${SCRIPT_DIR}/create-lxc.sh"
}

run_phase3() {
    log_step "Ejecutando Fase 3: Configuracion del LXC..."
    echo ""

    read -p "Ingrese el ID del contenedor LXC a configurar: " container_id

    if [[ -z "$container_id" ]]; then
        log_error "El ID del contenedor no puede estar vacio"
        exit 1
    fi

    if ! pct status "$container_id" &>/dev/null; then
        log_error "Contenedor ${container_id} no encontrado"
        exit 1
    fi

    local status
    status=$(pct status "$container_id" | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_warn "El contenedor no esta corriendo. Iniciando..."
        pct start "$container_id"
        sleep 5
    fi

    log_info "Copiando script de configuracion al contenedor..."
    pct push "$container_id" "${SCRIPT_DIR}/configure-lxc.sh" /tmp/configure-lxc.sh

    log_info "Ejecutando configuracion dentro del contenedor..."
    pct exec "$container_id" -- bash /tmp/configure-lxc.sh

    local container_ip
    container_ip=$(pct exec "$container_id" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "desconocida")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║             Fase 3 Completada!                              ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  ID Contenedor:  ${container_id}                                         ║${NC}"
    echo -e "${GREEN}║  IP Contenedor:  ${container_ip}                                 ║${NC}"
    echo -e "${GREEN}║  Wolf Den:       http://${container_ip}:8080                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

run_full_installation() {
    log_step "Iniciando instalacion completa..."
    echo ""

    echo -e "${CYAN}Esto hara:${NC}"
    echo "  1. Configurar el host (firmware AMD, udev rules de input)"
    echo "  2. Crear contenedor LXC privilegiado con GPU compartida"
    echo "  3. Instalar Docker, Wolf y Wolf Den dentro del contenedor"
    echo ""
    echo -e "${YELLOW}NOTA: Tu GPU AMD seguira disponible en el host para otras tareas.${NC}"
    echo ""

    read -p "Proceder? (s/n): " confirm
    if [[ "$confirm" != "s" && "$confirm" != "S" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi

    # Fase 1
    run_phase1

    # Fase 2
    echo ""
    run_phase2

    # Fase 3
    echo ""
    run_phase3
}

main() {
    print_banner
    check_root
    check_proxmox
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
