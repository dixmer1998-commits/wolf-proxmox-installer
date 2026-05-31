#!/bin/bash
set -euo pipefail

#=============================================================================
# Wolf (Games On Whales) - LXC Container Configuration
# Installs Docker, Wolf, Wolf Den, and pairing helper inside the LXC
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
    echo "║       Wolf (Games On Whales) - LXC Configuration           ║"
    echo "║         Phase 3: Docker, Wolf & Wolf Den Setup             ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root inside the LXC container"
        exit 1
    fi
}

check_lxc_environment() {
    log_step "Verifying LXC environment..."
    
    # Check if we're in a container
    if [[ ! -f /.dockerenv ]] && ! grep -q "lxc" /proc/1/cgroup 2>/dev/null; then
        log_warn "This doesn't appear to be a container environment"
        read -p "Continue anyway? (y/n): " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            exit 1
        fi
    fi
    
    # Check for GPU devices
    if [[ ! -d /dev/dri ]]; then
        log_error "/dev/dri not found. GPU passthrough may not be configured."
        log_error "Make sure the LXC config has: lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
        exit 1
    fi
    
    log_info "GPU devices found:"
    ls -la /dev/dri/
    
    # Check for uinput
    if [[ ! -c /dev/uinput ]]; then
        log_warn "/dev/uinput not found. Gamepad support may not work."
    else
        log_info "/dev/uinput found"
    fi
    
    # Check for uhid
    if [[ ! -c /dev/uhid ]]; then
        log_warn "/dev/uhid not found. DualSense emulation may not work."
    else
        log_info "/dev/uhid found"
    fi
}

install_dependencies() {
    log_step "Installing system dependencies..."
    
    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        gnupg \
        ca-certificates \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        jq
    
    log_info "Dependencies installed"
}

install_docker() {
    log_step "Installing Docker..."
    
    if command -v docker &>/dev/null; then
        log_info "Docker already installed: $(docker --version)"
    else
        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        
        # Add the repository
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        
        log_info "Docker installed: $(docker --version)"
    fi
    
    # Enable and start Docker
    systemctl enable --now docker
    log_info "Docker service enabled"
}

detect_render_node() {
    log_step "Detecting GPU render node..."
    
    local render_nodes=()
    for node in /dev/dri/renderD*; do
        if [[ -e "$node" ]]; then
            render_nodes+=("$node")
        fi
    done
    
    if [[ ${#render_nodes[@]} -eq 0 ]]; then
        log_error "No render nodes found in /dev/dri/"
        WOLF_RENDER_NODE="/dev/dri/renderD128"
    elif [[ ${#render_nodes[@]} -eq 1 ]]; then
        WOLF_RENDER_NODE="${render_nodes[0]}"
        log_info "Found render node: ${WOLF_RENDER_NODE}"
    else
        log_info "Multiple render nodes found:"
        for i in "${!render_nodes[@]}"; do
            local driver_link
            driver_link=$(ls -l /sys/class/drm/$(basename "${render_nodes[$i]}")/device/driver 2>/dev/null || echo "unknown")
            echo -e "  ${i}) ${render_nodes[$i]} -> ${driver_link}"
        done
        
        local default_idx=0
        read -p "Select render node [${default_idx}]: " node_idx
        node_idx="${node_idx:-$default_idx}"
        WOLF_RENDER_NODE="${render_nodes[$node_idx]}"
        log_info "Selected: ${WOLF_RENDER_NODE}"
    fi
}

create_directories() {
    log_step "Creating Wolf directories..."
    
    mkdir -p /etc/wolf/cfg
    mkdir -p /etc/wolf/profile_data
    mkdir -p /etc/wolf/covers
    mkdir -p /etc/wolf/compatibilitytools.d
    mkdir -p /etc/wolf/wolf-den
    
    log_info "Directories created under /etc/wolf/"
}

create_wolf_config() {
    log_step "Creating Wolf configuration..."
    
    local config_file="/etc/wolf/cfg/config.toml"
    
    if [[ -f "$config_file" ]]; then
        log_info "Wolf config already exists"
        read -p "Overwrite? (y/n): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            return
        fi
    fi
    
    # Generate a UUID
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)
    
    cat > "$config_file" << EOF
hostname = "wolf"
support_hevc = true
config_version = 2
uuid = "${uuid}"

paired_clients = []
profiles = []

gstreamer = {}
EOF
    
    log_info "Wolf config created at ${config_file}"
}

create_docker_compose() {
    log_step "Creating docker-compose.yml..."
    
    local compose_file="/etc/wolf/docker-compose.yml"
    
    if [[ -f "$compose_file" ]]; then
        log_warn "docker-compose.yml already exists"
        read -p "Overwrite? (y/n): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            return
        fi
        cp "$compose_file" "${compose_file}.backup.$(date +%Y%m%d%H%M%S)"
    fi
    
    cat > "$compose_file" << 'COMPOSE_EOF'
version: "3"
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_STOP_CONTAINER_ON_EXIT=TRUE
      - WOLF_RENDER_NODE=__WOLF_RENDER_NODE__
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
    volumes:
      - /etc/wolf/:/etc/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /mnt/dev:/dev:rw
      - /mnt/udev:/run/udev:rw
      - /var/run/wolf:/var/run/wolf
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    ports:
      - 8080:8080
    environment:
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
    volumes:
      - /etc/wolf/wolf-den:/app/wolf-den/
      - /var/run/wolf:/var/run/wolf
      - /etc/wolf/covers:/etc/wolf/covers
      - /etc/wolf/compatibilitytools.d:/etc/wolf/compatibilitytools.d
    network_mode: host
    restart: unless-stopped
COMPOSE_EOF
    
    # Replace render node placeholder
    sed -i "s|__WOLF_RENDER_NODE__|${WOLF_RENDER_NODE}|g" "$compose_file"
    
    log_info "docker-compose.yml created at ${compose_file}"
    echo ""
    log_info "Contents:"
    cat "$compose_file"
    echo ""
}

create_pairing_helper() {
    log_step "Creating Wolf pairing helper..."
    
    local helper_file="/usr/local/bin/wolf-pair"
    
    cat > "$helper_file" << 'HELPER_EOF'
#!/bin/bash
#=============================================================================
# Wolf Pairing Helper
# Displays the Moonlight pairing URL in real-time
#=============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                  Wolf Pairing Helper                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Get server IP
SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}Steps:${NC}"
echo -e "  1. Open Moonlight and connect to: ${YELLOW}${SERVER_IP}${NC}"
echo -e "  2. Moonlight will show a PIN code"
echo -e "  3. The pairing URL will appear below"
echo -e "  4. Open the URL in your browser and enter the PIN"
echo ""
echo -e "${YELLOW}Waiting for Moonlight connection...${NC}"
echo ""

# Monitor Wolf logs for pairing URL
docker logs -f wolf 2>&1 | grep --line-buffered -oP 'http://[^\s]*pin[^\s]*' | while read -r url; do
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  PAIRING URL:                                               ║${NC}"
    echo -e "${GREEN}║  ${url}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
done
HELPER_EOF
    
    chmod +x "$helper_file"
    log_info "Pairing helper created at ${helper_file}"
    log_info "Use: wolf-pair"
}

create_status_helper() {
    log_step "Creating Wolf status helper..."
    
    local helper_file="/usr/local/bin/wolf-status"
    
    cat > "$helper_file" << 'STATUS_EOF'
#!/bin/bash
#=============================================================================
# Wolf Status Helper
# Shows Wolf and Wolf Den status
#=============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== Wolf Status ===${NC}"
echo ""

# Docker containers
echo -e "${YELLOW}Docker Containers:${NC}"
docker ps -a --filter "name=wolf" --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

# Server IP
SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}Server IP:${NC} ${SERVER_IP}"
echo ""

# Wolf ports
echo -e "${YELLOW}Moonlight Ports:${NC}"
echo "  HTTPS:  ${SERVER_IP}:47984/tcp"
echo "  HTTP:   ${SERVER_IP}:47989/tcp"
echo "  Control: ${SERVER_IP}:47999/udp"
echo "  RTSP:   ${SERVER_IP}:48010/tcp"
echo "  Video:  ${SERVER_IP}:48100/udp"
echo "  Audio:  ${SERVER_IP}:48200/udp"
echo ""

# Wolf Den
echo -e "${YELLOW}Wolf Den:${NC} http://${SERVER_IP}:8080"
echo ""

# Wolf socket
if [[ -S /var/run/wolf/wolf.sock ]]; then
    echo -e "${GREEN}Wolf socket: OK${NC}"
else
    echo -e "${RED}Wolf socket: NOT FOUND (Wolf may not be running)${NC}"
fi
STATUS_EOF
    
    chmod +x "$helper_file"
    log_info "Status helper created at ${helper_file}"
    log_info "Use: wolf-status"
}

start_wolf() {
    log_step "Starting Wolf and Wolf Den..."
    
    cd /etc/wolf
    
    docker compose pull
    docker compose up -d
    
    log_info "Wolf services started"
    
    # Wait a moment for containers to initialize
    sleep 5
    
    # Check status
    docker compose ps
}

print_final_info() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')
    
    echo ""
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                Wolf Installation Complete!                 ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  Server IP:     ${server_ip}                                   ║"
    echo "║                                                            ║"
    echo "║  Moonlight:                                                 ║"
    echo "║    - Open Moonlight on your client device                  ║"
    echo "║    - Add host: ${server_ip}                                ║"
    echo "║    - Run 'wolf-pair' to see pairing URL                    ║"
    echo "║                                                            ║"
    echo "║  Wolf Den (Web UI):                                        ║"
    echo "║    http://${server_ip}:8080                                ║"
    echo "║                                                            ║"
    echo "║  Useful commands:                                          ║"
    echo "║    wolf-pair    - Show pairing URL for Moonlight           ║"
    echo "║    wolf-status  - Show Wolf status and ports               ║"
    echo "║    cd /etc/wolf && docker compose logs -f  - View logs     ║"
    echo "║    cd /etc/wolf && docker compose restart - Restart Wolf   ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    print_banner
    check_root
    check_lxc_environment
    install_dependencies
    install_docker
    detect_render_node
    create_directories
    create_wolf_config
    create_docker_compose
    create_pairing_helper
    create_status_helper
    start_wolf
    print_final_info
}

main "$@"
