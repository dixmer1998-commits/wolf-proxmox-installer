#!/bin/bash
set -euo pipefail

#=============================================================================
# Wolf (Games On Whales) - Proxmox Installation Script
# Complete installation of Wolf gaming streaming on Proxmox with AMD GPU
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_banner() {
    echo -e "${MAGENTA}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                                                              ║"
    echo "║       🐺  Wolf (Games On Whales) - Proxmox Installer  🐺    ║"
    echo "║                                                              ║"
    echo "║        Complete installation for AMD GPU passthrough         ║"
    echo "║            Wolf + Wolf Den + Gaming Streaming                ║"
    echo "║                                                              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        echo "Usage: sudo ./install.sh"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    log_info "Proxmox detected: $(pveversion | head -1)"
}

print_menu() {
    echo -e "${CYAN}=== Installation Options ===${NC}"
    echo ""
    echo "  1) Full installation (all 3 phases)"
    echo "     - Phase 1: Host configuration (IOMMU, VFIO, drivers)"
    echo "     - Phase 2: Create LXC container"
    echo "     - Phase 3: Install Wolf & Wolf Den"
    echo ""
    echo "  2) Phase 1 only: Configure host (run first, then reboot)"
    echo ""
    echo "  3) Phase 2 only: Create LXC container (after reboot)"
    echo ""
    echo "  4) Phase 3 only: Configure LXC (after container created)"
    echo ""
    echo "  5) Exit"
    echo ""
}

run_phase1() {
    log_step "Running Phase 1: Host Configuration..."
    echo ""
    
    if [[ -f "${SCRIPT_DIR}/host-config.sh" ]]; then
        bash "${SCRIPT_DIR}/host-config.sh"
    else
        log_error "host-config.sh not found in ${SCRIPT_DIR}"
        exit 1
    fi
}

run_phase2() {
    log_step "Running Phase 2: LXC Container Creation..."
    echo ""
    
    if [[ -f "${SCRIPT_DIR}/create-lxc.sh" ]]; then
        bash "${SCRIPT_DIR}/create-lxc.sh"
    else
        log_error "create-lxc.sh not found in ${SCRIPT_DIR}"
        exit 1
    fi
}

run_phase3() {
    log_step "Running Phase 3: LXC Configuration..."
    echo ""
    
    # Get container ID
    read -p "Enter the LXC container ID to configure: " container_id
    
    if [[ -z "$container_id" ]]; then
        log_error "Container ID cannot be empty"
        exit 1
    fi
    
    # Check if container exists
    if ! pct status "$container_id" &>/dev/null; then
        log_error "Container ${container_id} not found"
        exit 1
    fi
    
    # Check if container is running
    local status
    status=$(pct status "$container_id" | awk '{print $2}')
    if [[ "$status" != "running" ]]; then
        log_warn "Container is not running. Starting..."
        pct start "$container_id"
        sleep 5
    fi
    
    # Copy configure-lxc.sh to the container
    log_info "Copying configuration script to container..."
    pct push "$container_id" "${SCRIPT_DIR}/configure-lxc.sh" /tmp/configure-lxc.sh
    
    # Execute the script inside the container
    log_info "Executing configuration inside container..."
    pct exec "$container_id" -- bash /tmp/configure-lxc.sh
    
    # Get container IP
    local container_ip
    container_ip=$(pct exec "$container_id" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")
    
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║           Phase 3 Complete!                                 ║${NC}"
    echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${GREEN}║  Container ID: ${container_id}                                          ║${NC}"
    echo -e "${GREEN}║  Container IP: ${container_ip}                                  ║${NC}"
    echo -e "${GREEN}║  Wolf Den:     http://${container_ip}:8080                  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

run_full_installation() {
    log_step "Starting full installation..."
    echo ""
    
    echo -e "${CYAN}This will:${NC}"
    echo "  1. Configure the host (IOMMU, VFIO, GPU drivers)"
    echo "  2. Reboot the host"
    echo "  3. Create a privileged LXC container with GPU passthrough"
    echo "  4. Install Docker, Wolf, and Wolf Den inside the container"
    echo ""
    
    read -p "Proceed? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        return
    fi
    
    # Phase 1
    run_phase1
    
    # Ask for reboot
    echo ""
    read -p "Phase 1 complete. Reboot now? (y/n): " do_reboot
    if [[ "$do_reboot" == "y" || "$do_reboot" == "Y" ]]; then
        log_info "Rebooting in 5 seconds... Run this script again after reboot."
        sleep 5
        reboot
    else
        log_warn "Please reboot manually before continuing with Phase 2"
        echo ""
        echo -e "${YELLOW}After reboot, run:${NC}"
        echo "  sudo ${SCRIPT_DIR}/install.sh"
        echo "  Then select option 2 or 3"
    fi
}

main() {
    print_banner
    check_root
    check_proxmox
    
    while true; do
        print_menu
        read -p "Select option [1-5]: " choice
        
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
                echo "Exiting..."
                exit 0
                ;;
            *)
                log_warn "Invalid option. Please select 1-5."
                ;;
        esac
    done
}

main "$@"
