#!/bin/bash

# GooseRelayVPN User-Space Manager (Full Features)
# Based on original script by Kianmhz

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

INSTALL_DIR="$HOME/goose"

# ==========================================
# HYBRID REPOSITORY SETUP
# ==========================================
BIN_REPO="Kianmhz/GooseRelayVPN"
SCRIPT_REPO="Gemilai/GooseRelayVPN"
# ==========================================

BINARY_NAME="goose-server"
CONFIG_NAME="server_config.json"

show_menu() {
    echo -e "${GREEN}GooseRelayVPN Non-Root Manager${NC}"
    echo "1) Install GooseRelayVPN"
    echo "2) Update GooseRelayVPN"
    echo "3) Reconfigure GooseRelayVPN"
    echo "4) Start Service"
    echo "5) Stop Service"
    echo "6) Restart Service"
    echo "7) Uninstall GooseRelayVPN"
    echo "8) Exit"
}

check_dependencies() {
    echo -e "${YELLOW}Checking dependencies...${NC}"
    DEPS=("curl" "tar" "openssl" "jq" "nohup" "sha256sum")
    MISSING_DEPS=()
    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            MISSING_DEPS+=("$dep")
        fi
    done

    if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing dependencies required for non-root install: ${MISSING_DEPS[*]}${NC}"
        echo "Please ask your server administrator to install them, or run:"
        echo "sudo apt-get install ${MISSING_DEPS[*]}"
        exit 1
    fi
}

get_latest_version() {
    curl -s "https://api.github.com/repos/$BIN_REPO/releases/latest" | jq -r .tag_name
}

get_bin_version() {
    local bin_path=$1
    if [ ! -f "$bin_path" ]; then echo "none"; return; fi
    
    local ver=$("$bin_path" -version 2>/dev/null | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" || echo "")
    if [ -n "$ver" ]; then echo "$ver"; return; fi
    
    ver=$(strings "$bin_path" | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | head -n 1 || echo "")
    if [ -n "$ver" ]; then echo "$ver"; return; fi
    
    echo "unknown"
}

get_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *) echo -e "${RED}Unsupported architecture: $ARCH${NC}"; exit 1 ;;
    esac
    echo "${OS}-${ARCH}"
}

create_user_scripts() {
    # run.sh (Infinite loop to keep it alive)
    cat > "$INSTALL_DIR/run.sh" <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
while true; do
    "$INSTALL_DIR/$BINARY_NAME" -config "$INSTALL_DIR/$CONFIG_NAME"
    echo "\$(date) crashed restarting..." >> crash.log
    sleep 5
done
EOF
    chmod +x "$INSTALL_DIR/run.sh"

    # start.sh
    cat > "$INSTALL_DIR/start.sh" <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
if [ -f goose.pid ]; then
    PID=\$(cat goose.pid)
    if ps -p \$PID > /dev/null 2>&1; then
        echo -e "\033[0;32mGooseRelayVPN is already running (PID: \$PID)\033[0m"
        exit 0
    fi
fi
nohup bash "$INSTALL_DIR/run.sh" >> "$INSTALL_DIR/server.log" 2>&1 &
echo \$! > goose.pid
echo -e "\033[0;32mGooseRelayVPN Started\033[0m"
EOF
    chmod +x "$INSTALL_DIR/start.sh"

    # stop.sh
    cat > "$INSTALL_DIR/stop.sh" <<EOF
#!/bin/bash
cd "$INSTALL_DIR"
if [ -f goose.pid ]; then
    PID=\$(cat goose.pid)
    kill \$PID 2>/dev/null || true
    pkill -f "$BINARY_NAME -config" || true
    rm -f goose.pid
    echo -e "\033[0;31mGooseRelayVPN Stopped\033[0m"
else
    pkill -f "$BINARY_NAME -config" || true
    echo -e "\033[0;31mGooseRelayVPN processes cleared\033[0m"
fi
EOF
    chmod +x "$INSTALL_DIR/stop.sh"

    # restart.sh
    cat > "$INSTALL_DIR/restart.sh" <<EOF
#!/bin/bash
"$INSTALL_DIR/stop.sh"
sleep 2
"$INSTALL_DIR/start.sh"
EOF
    chmod +x "$INSTALL_DIR/restart.sh"
}

setup_cron() {
    CRON1="@reboot sleep 15 && $INSTALL_DIR/start.sh"
    CRON2="* * * * * pgrep -f \"$BINARY_NAME -config\" >/dev/null || $INSTALL_DIR/start.sh"
    (
        crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/start.sh"
        echo "$CRON1"
        echo "$CRON2"
    ) | sort -u | crontab -
}

install_or_update() {
    local is_update=$1
    check_dependencies

    LATEST_VERSION=$(get_latest_version)
    EXISTING_BIN="$INSTALL_DIR/$BINARY_NAME"
    
    if [ -f "$EXISTING_BIN" ]; then
        CURRENT_VERSION=$(get_bin_version "$EXISTING_BIN")
        echo -e "Found existing installation at ${YELLOW}$EXISTING_BIN${NC} (Version: ${GREEN}$CURRENT_VERSION${NC})"
        
        if [ "$CURRENT_VERSION" == "$LATEST_VERSION" ] && [ "$is_update" == "true" ]; then
            echo -e "${GREEN}GooseRelayVPN is already up to date.${NC}"
            read -p "Force update anyway? (y/n): " force
            if [[ "$force" != "y" ]]; then return; fi
        fi
    else
        if [ "$is_update" == "true" ]; then
            echo -e "${RED}No existing installation found to update.${NC}"
            return
        fi
        echo -e "${YELLOW}Installing GooseRelayVPN $LATEST_VERSION...${NC}"
    fi

    # 1. Shutdown if running
    if [ -f "$INSTALL_DIR/stop.sh" ]; then
        echo -e "${YELLOW}Stopping service...${NC}"
        "$INSTALL_DIR/stop.sh" || true
    fi

    # 2. Prepare directory
    mkdir -p "$INSTALL_DIR"
    
    # 3. Handle config creation
    if [ ! -f "$INSTALL_DIR/$CONFIG_NAME" ]; then
        echo -e "${YELLOW}Creating fresh configuration...${NC}"
        curl -s "https://raw.githubusercontent.com/$SCRIPT_REPO/main/server_config.example.json" -o "$INSTALL_DIR/$CONFIG_NAME"
        TUNNEL_KEY=$(openssl rand -hex 32)
        jq --arg key "$TUNNEL_KEY" '.tunnel_key = $key' "$INSTALL_DIR/$CONFIG_NAME" > "$INSTALL_DIR/tmp.json" && mv "$INSTALL_DIR/tmp.json" "$INSTALL_DIR/$CONFIG_NAME"
        echo -e "${GREEN}Generated tunnel_key: $TUNNEL_KEY${NC}"
        
        echo -e "\nRoute all outbound connections through a local SOCKS5 proxy? (Cloudflare WARP)"
        read -p "Activate upstream_proxy? (y/n): " use_proxy
        if [[ "$use_proxy" == "y" ]]; then
            jq '.upstream_proxy = "socks5://127.0.0.1:40000"' "$INSTALL_DIR/$CONFIG_NAME" > "$INSTALL_DIR/tmp.json" && mv "$INSTALL_DIR/tmp.json" "$INSTALL_DIR/$CONFIG_NAME"
        else
            jq 'del(.upstream_proxy)' "$INSTALL_DIR/$CONFIG_NAME" > "$INSTALL_DIR/tmp.json" && mv "$INSTALL_DIR/tmp.json" "$INSTALL_DIR/$CONFIG_NAME"
        fi
    fi

    # 4. Download and Verify Binary
    PLATFORM=$(get_platform)
    TARBALL_NAME="GooseRelayVPN-server-$LATEST_VERSION-$PLATFORM.tar.gz"
    DOWNLOAD_URL="https://github.com/$BIN_REPO/releases/download/$LATEST_VERSION/$TARBALL_NAME"
    SUMS_URL="https://github.com/$BIN_REPO/releases/download/$LATEST_VERSION/SHA256SUMS.txt"
    
    echo -e "${YELLOW}Downloading $LATEST_VERSION for $PLATFORM...${NC}"
    curl -fL "$DOWNLOAD_URL" -o "/tmp/goose.tar.gz"
    curl -fLs "$SUMS_URL" -o "/tmp/goose.sums.txt"

    echo -e "${YELLOW}Verifying checksum...${NC}"
    EXPECTED=$(awk -v f="$TARBALL_NAME" '{sub(/^\.\//,"",$2)} $2==f {print $1}' "/tmp/goose.sums.txt")
    ACTUAL=$(sha256sum "/tmp/goose.tar.gz" | awk '{print $1}')
    
    if [ -z "$EXPECTED" ]; then
        echo -e "${RED}Could not find $TARBALL_NAME in SHA256SUMS.txt — aborting${NC}"
        rm -f /tmp/goose.tar.gz /tmp/goose.sums.txt
        exit 1
    fi
    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo -e "${RED}Checksum mismatch for $TARBALL_NAME${NC}"
        rm -f /tmp/goose.tar.gz /tmp/goose.sums.txt
        exit 1
    fi
    echo -e "${GREEN}Checksum OK${NC}"

    # 5. Extract and locate binary
    tar -xzf "/tmp/goose.tar.gz" -C "$INSTALL_DIR"
    rm /tmp/goose.tar.gz /tmp/goose.sums.txt

    if [ ! -f "$INSTALL_DIR/$BINARY_NAME" ]; then
        FIND_BIN=$(find "$INSTALL_DIR" -type f -name "$BINARY_NAME" | head -n 1)
        if [ -n "$FIND_BIN" ]; then
            mv "$FIND_BIN" "$INSTALL_DIR/$BINARY_NAME"
            # Cleanup any empty leftover directories from extraction
            find "$INSTALL_DIR" -type d -empty -delete 2>/dev/null || true
        else
            echo -e "${RED}Error: Could not locate the binary after extraction.${NC}"
            exit 1
        fi
    fi
    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    # 6. Setup scripts & auto-start
    create_user_scripts
    setup_cron
    "$INSTALL_DIR/start.sh"

    # 7. Print Manual Firewall Warning
    PORT=$(jq -r '.server_port // 8443' "$INSTALL_DIR/$CONFIG_NAME")
    echo -e "\n${YELLOW}================================================${NC}"
    echo -e "${GREEN}GooseRelayVPN is now running from $INSTALL_DIR!${NC}"
    echo -e "${RED}IMPORTANT: You are running in user-space (non-root).${NC}"
    echo -e "You MUST manually ensure port ${YELLOW}$PORT/tcp${NC} is open on your firewall or hosting provider dashboard."
    echo -e "${YELLOW}================================================${NC}\n"
}

reconfigure_server() {
    if [ ! -f "$INSTALL_DIR/$CONFIG_NAME" ]; then
        echo -e "${RED}Configuration not found at $INSTALL_DIR/$CONFIG_NAME${NC}"
        return
    fi
    echo "1) Regenerate tunnel_key"
    echo "2) Toggle upstream_proxy"
    read -p "Choice: " choice
    case $choice in
        1)
            NEW_KEY=$(openssl rand -hex 32)
            jq --arg key "$NEW_KEY" '.tunnel_key = $key' "$INSTALL_DIR/$CONFIG_NAME" > "$INSTALL_DIR/tmp.json" && mv "$INSTALL_DIR/tmp.json" "$INSTALL_DIR/$CONFIG_NAME"
            echo -e "${GREEN}New tunnel_key: $NEW_KEY${NC}"
            "$INSTALL_DIR/restart.sh"
            ;;
        2)
            HAS_PROXY=$(jq '.upstream_proxy' "$INSTALL_DIR/$CONFIG_NAME")
            if [ "$HAS_PROXY" != "null" ]; then
                jq 'del(.upstream_proxy)' "$INSTALL_DIR/$CONFIG_NAME" > "$INSTALL_DIR/tmp.json" && mv "$INSTALL_DIR/tmp.json" "$INSTALL_DIR/$CONFIG_NAME"
                echo "Upstream proxy disabled."
            else
                jq '.upstream_proxy = "socks5://127.0.0.1:40000"' "$INSTALL_DIR/$CONFIG_NAME" > "$INSTALL_DIR/tmp.json" && mv "$INSTALL_DIR/tmp.json" "$INSTALL_DIR/$CONFIG_NAME"
                echo "Upstream proxy enabled."
            fi
            "$INSTALL_DIR/restart.sh"
            ;;
    esac
}

uninstall_server() {
    if [ ! -d "$INSTALL_DIR" ]; then
        echo -e "${RED}GooseRelayVPN is not installed.${NC}"
        return
    fi
    read -p "Uninstall GooseRelayVPN from $INSTALL_DIR? (y/n): " choice
    if [[ "$choice" == "y" ]]; then
        "$INSTALL_DIR/stop.sh" || true
        crontab -l 2>/dev/null | grep -v "$INSTALL_DIR/start.sh" | crontab -
        rm -rf "$INSTALL_DIR"
        echo -e "${GREEN}Uninstalled successfully.${NC}"
    fi
}

# Process Command Line Arguments
if [ "$#" -gt 0 ]; then
    case $1 in
        install) install_or_update "false" ;;
        update) install_or_update "true" ;;
        reconfigure) reconfigure_server ;;
        start) "$INSTALL_DIR/start.sh" ;;
        stop) "$INSTALL_DIR/stop.sh" ;;
        restart) "$INSTALL_DIR/restart.sh" ;;
        uninstall) uninstall_server ;;
        *) show_menu ;;
    esac
    exit 0
fi

# Interactive Menu Loop
while true; do
    show_menu
    read -p "Enter choice [1-8]: " choice
    case $choice in
        1) install_or_update "false" ;;
        2) install_or_update "true" ;;
        3) reconfigure_server ;;
        4) "$INSTALL_DIR/start.sh" ;;
        5) "$INSTALL_DIR/stop.sh" ;;
        6) "$INSTALL_DIR/restart.sh" ;;
        7) uninstall_server ;;
        8) exit 0 ;;
    esac
    echo ""
done
