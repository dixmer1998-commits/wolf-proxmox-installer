#!/bin/bash
set -euo pipefail

#=============================================================================
# Wolf (Games On Whales) - LXC Container Creation
# Creates a privileged LXC container with GPU passthrough for Wolf
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       Wolf (Games On Whales) - LXC Container Creation      ║"
    echo "║              Phase 2: Privileged LXC Setup                 ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }

# Default values
CONTAINER_ID=""
CONTAINER_HOSTNAME="wolf-gaming"
CONTAINER_RAM=14000
CONTAINER_SWAP=2048
CONTAINER_CORES=11
CONTAINER_DISK="500"
CONTAINER_STORAGE="local-lvm"
CONTAINER_PASSWORD=""
USE_DHCP="y"
CONTAINER_IP=""
CONTAINER_GATEWAY=""

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
}

find_next_id() {
    local max_id
    max_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -1)
    if [[ -z "$max_id" ]]; then
        echo "100"
    else
        echo $((max_id + 1))
    fi
}

check_template() {
    log_step "Checking for Ubuntu 24.04 template..."
    
    local template_pattern="ubuntu-24.04"
    local template
    template=$(pveam list local | grep "$template_pattern" | head -1 | awk '{print $2}')
    
    if [[ -z "$template" ]]; then
        log_warn "Ubuntu 24.04 template not found. Downloading..."
        pveam update
        template=$(pveam list local | grep "$template_pattern" | head -1 | awk '{print $2}')
        
        if [[ -z "$template" ]]; then
            log_error "Could not find Ubuntu 24.04 template. Please download it manually from Proxmox UI."
            exit 1
        fi
    fi
    
    TEMPLATE_FILE="local:vztmpl/${template}"
    log_info "Using template: ${TEMPLATE_FILE}"
}

get_configuration() {
    echo -e "${CYAN}=== LXC Container Configuration ===${NC}"
    echo ""
    
    # Container ID
    local next_id
    next_id=$(find_next_id)
    read -p "Container ID [${next_id}]: " input_id
    CONTAINER_ID="${input_id:-$next_id}"
    
    # Hostname
    read -p "Hostname [${CONTAINER_HOSTNAME}]: " input_hostname
    CONTAINER_HOSTNAME="${input_hostname:-$CONTAINER_HOSTNAME}"
    
    # Password
    while [[ -z "$CONTAINER_PASSWORD" ]]; do
        read -s -p "Root password: " CONTAINER_PASSWORD
        echo ""
        if [[ -z "$CONTAINER_PASSWORD" ]]; then
            log_warn "Password cannot be empty"
        fi
    done
    
    # Disk size
    read -p "Disk size in GB [${CONTAINER_DISK}]: " input_disk
    CONTAINER_DISK="${input_disk:-$CONTAINER_DISK}"
    
    # Storage
    read -p "Storage pool [${CONTAINER_STORAGE}]: " input_storage
    CONTAINER_STORAGE="${input_storage:-$CONTAINER_STORAGE}"
    
    # RAM
    read -p "RAM in MB [${CONTAINER_RAM}]: " input_ram
    CONTAINER_RAM="${input_ram:-$CONTAINER_RAM}"
    
    # CPU cores
    read -p "CPU cores [${CONTAINER_CORES}]: " input_cores
    CONTAINER_CORES="${input_cores:-$CONTAINER_CORES}"
    
    # Network
    echo ""
    read -p "Use DHCP? (y/n) [y]: " input_dhcp
    USE_DHCP="${input_dhcp:-y}"
    
    if [[ "$USE_DHCP" != "y" && "$USE_DHCP" != "Y" ]]; then
        read -p "IP address (CIDR, e.g. 192.168.1.100/24): " CONTAINER_IP
        read -p "Gateway: " CONTAINER_GATEWAY
        
        if [[ -z "$CONTAINER_IP" || -z "$CONTAINER_GATEWAY" ]]; then
            log_error "IP and gateway are required for static configuration"
            exit 1
        fi
    fi
    
    # Summary
    echo ""
    echo -e "${CYAN}=== Configuration Summary ===${NC}"
    echo -e "  Container ID:   ${YELLOW}${CONTAINER_ID}${NC}"
    echo -e "  Hostname:       ${YELLOW}${CONTAINER_HOSTNAME}${NC}"
    echo -e "  Disk:           ${YELLOW}${CONTAINER_DISK} GB on ${CONTAINER_STORAGE}${NC}"
    echo -e "  RAM:            ${YELLOW}${CONTAINER_RAM} MB${NC}"
    echo -e "  CPU Cores:      ${YELLOW}${CONTAINER_CORES}${NC}"
    echo -e "  Network:        ${YELLOW}${USE_DHCP == 'y' || USE_DHCP == 'Y' ? 'DHCP' : "${CONTAINER_IP} gw ${CONTAINER_GATEWAY}"}${NC}"
    echo -e "  Privileged:     ${YELLOW}YES${NC}"
    echo -e "  Template:       ${YELLOW}${TEMPLATE_FILE}${NC}"
    echo ""
    
    read -p "Proceed with creation? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_error "Aborted by user"
        exit 1
    fi
}

create_container() {
    log_step "Creating LXC container ${CONTAINER_ID}..."
    
    # Build network parameter
    local net_param="name=eth0,bridge=vmbr0,hwaddr=auto"
    if [[ "$USE_DHCP" == "y" || "$USE_DHCP" == "Y" ]]; then
        net_param="${net_param},ip=dhcp"
    else
        net_param="${net_param},ip=${CONTAINER_IP},gw=${CONTAINER_GATEWAY}"
    fi
    
    # Create the container
    pct create "$CONTAINER_ID" "$TEMPLATE_FILE" \
        --hostname "$CONTAINER_HOSTNAME" \
        --password "$CONTAINER_PASSWORD" \
        --unprivileged 0 \
        --memory "$CONTAINER_RAM" \
        --swap "$CONTAINER_SWAP" \
        --cores "$CONTAINER_CORES" \
        --rootfs "${CONTAINER_STORAGE}:${CONTAINER_DISK}" \
        --net0 "$net_param" \
        --ostype ubuntu \
        --onboot 1
    
    log_info "Container ${CONTAINER_ID} created successfully"
}

configure_gpu_passthrough() {
    log_step "Configuring GPU passthrough in LXC config..."
    
    local config_file="/etc/pve/lxc/${CONTAINER_ID}.conf"
    
    if [[ ! -f "$config_file" ]]; then
        log_error "Container config not found at ${config_file}"
        exit 1
    fi
    
    # Backup original config
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)"
    
    # Add GPU passthrough configuration
    cat >> "$config_file" << 'EOF'

# === Wolf GPU Passthrough Configuration ===
# Virtual input devices
dev0: /dev/uinput
dev1: /dev/uhid

# Cgroup access - full device access for Wolf
lxc.cgroup2.devices.allow: a
lxc.cap.drop:

# Mount entries for GPU and device access
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/udev none bind,optional,create=dir
lxc.mount.entry: /dev mnt/dev none bind,optional,create=dir
EOF
    
    log_info "GPU passthrough configuration added to ${config_file}"
    
    echo ""
    echo -e "${CYAN}LXC Config contents:${NC}"
    cat "$config_file"
    echo ""
}

start_container() {
    log_step "Starting container ${CONTAINER_ID}..."
    
    pct start "$CONTAINER_ID"
    
    # Wait for container to be ready
    log_info "Waiting for container to initialize..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CONTAINER_ID" -- echo "ready" &>/dev/null; then
            log_info "Container is ready"
            return 0
        fi
        sleep 2
        retries=$((retries - 1))
    done
    
    log_warn "Container may still be starting. Check with: pct status ${CONTAINER_ID}"
}

print_next_steps() {
    local container_ip
    if [[ "$USE_DHCP" == "y" || "$USE_DHCP" == "Y" ]]; then
        container_ip=$(pct exec "$CONTAINER_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<IP>")
    else
        container_ip=$(echo "$CONTAINER_IP" | cut -d'/' -f1)
    fi
    
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                  LXC Container Created!                    ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  Container ID:  ${CONTAINER_ID}                                       ║"
    echo "║  Hostname:      ${CONTAINER_HOSTNAME}                                 ║"
    echo "║  IP:            ${container_ip}                                       ║"
    echo "║                                                            ║"
    echo "║  Next step: Run ./configure-lxc.sh to install Wolf         ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    print_banner
    check_root
    check_proxmox
    check_template
    get_configuration
    create_container
    configure_gpu_passthrough
    start_container
    print_next_steps
}

main "$@"
