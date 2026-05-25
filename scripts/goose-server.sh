#!/bin/bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="$HOME/goose"
# FIXED: Restored the correct repository name
REPO="Gemilai/GooseRelayVPN"

BINARY_NAME="goose-server"
CONFIG_NAME="server_config.json"

show_menu() {
    echo -e "${GREEN}GooseRelayVPN User-Space Manager${NC}"
    echo "1) Install"
    echo "2) Update"
    echo "3) Start"
    echo "4) Stop"
    echo "5) Restart"
    echo "6) Uninstall"
    echo "7) Exit"
}

check_dependencies() {
    DEPS=("curl" "tar" "openssl" "jq" "nohup")

    for dep in "${DEPS[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            echo -e "${RED}Missing dependency: $dep${NC}"
            exit 1
        fi
    done
}

get_latest_version() {
    curl -s "https://api.github.com/repos/$REPO/releases/latest" | jq -r .tag_name
}

get_platform() {
    OS=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)

    case "$ARCH" in
        x86_64) ARCH="amd64" ;;
        aarch64) ARCH="arm64" ;;
        armv7l) ARCH="armv7" ;;
        *)
            echo -e "${RED}Unsupported architecture: $ARCH${NC}"
            exit 1
            ;;
    esac

    echo "${OS}-${ARCH}"
}

create_config() {
    if [ ! -f "$INSTALL_DIR/$CONFIG_NAME" ]; then

        echo -e "${YELLOW}Creating config...${NC}"

        curl -s \
        "https://raw.githubusercontent.com/$REPO/main/server_config.example.json" \
        -o "$INSTALL_DIR/$CONFIG_NAME"

        TUNNEL_KEY=$(openssl rand -hex 32)

        jq --arg key "$TUNNEL_KEY" \
        '.tunnel_key = $key' \
        "$INSTALL_DIR/$CONFIG_NAME" \
        > "$INSTALL_DIR/tmp.json"

        mv "$INSTALL_DIR/tmp.json" \
        "$INSTALL_DIR/$CONFIG_NAME"

        echo -e "${GREEN}Tunnel Key:${NC} $TUNNEL_KEY"

        echo ""
        echo "Choose server port:"
        echo "Recommended:"
        echo "2053 / 2083 / 2087 / 2096 / 8443"

        read -p "Port [2053]: " PORT

        PORT=${PORT:-2053}

        jq --argjson port "$PORT" \
        '.server_port = $port' \
        "$INSTALL_DIR/$CONFIG_NAME" \
        > "$INSTALL_DIR/tmp.json"

        mv "$INSTALL_DIR/tmp.json" \
        "$INSTALL_DIR/$CONFIG_NAME"

    fi
}

create_scripts() {

cat > "$INSTALL_DIR/run.sh" <<EOF
#!/bin/bash

cd "$INSTALL_DIR"

while true; do

    "$INSTALL_DIR/$BINARY_NAME" \
    -config "$INSTALL_DIR/$CONFIG_NAME"

    echo "\$(date) crashed restarting..." >> crash.log

    sleep 5

done
EOF

chmod +x "$INSTALL_DIR/run.sh"

cat > "$INSTALL_DIR/start.sh" <<EOF
#!/bin/bash

cd "$INSTALL_DIR"

if [ -f goose.pid ]; then

    PID=\$(cat goose.pid)

    if ps -p \$PID > /dev/null 2>&1; then
        echo "Already running"
        exit 0
    fi

fi

nohup bash "$INSTALL_DIR/run.sh" \
>> "$INSTALL_DIR/server.log" 2>&1 &

echo \$! > goose.pid

echo "Started"
EOF

chmod +x "$INSTALL_DIR/start.sh"

cat > "$INSTALL_DIR/stop.sh" <<EOF
#!/bin/bash

cd "$INSTALL_DIR"

if [ -f goose.pid ]; then

    kill \$(cat goose.pid) 2>/dev/null || true

    rm -f goose.pid

    echo "Stopped"

else

    pkill -f "$BINARY_NAME" || true

fi
EOF

chmod +x "$INSTALL_DIR/stop.sh"

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

    CRON2="* * * * * pgrep -f $BINARY_NAME >/dev/null || $INSTALL_DIR/start.sh"

    (
        crontab -l 2>/dev/null
        echo "$CRON1"
        echo "$CRON2"
    ) | sort -u | crontab -
}

install_app() {

    check_dependencies

    mkdir -p "$INSTALL_DIR"

    cd "$INSTALL_DIR"

    LATEST_VERSION=$(get_latest_version)

    PLATFORM=$(get_platform)

    TARBALL_NAME="GooseRelayVPN-server-$LATEST_VERSION-$PLATFORM.tar.gz"

    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_VERSION/$TARBALL_NAME"

    echo -e "${YELLOW}Downloading:${NC} $TARBALL_NAME"

    curl -fL "$DOWNLOAD_URL" -o goose.tar.gz

    tar -xzf goose.tar.gz

    rm -f goose.tar.gz

    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    create_config

    create_scripts

    setup_cron

    "$INSTALL_DIR/start.sh"

    echo ""
    echo -e "${GREEN}Installed Successfully${NC}"
    echo ""
    echo "Directory:"
    echo "$INSTALL_DIR"
    echo ""
    echo "Commands:"
    echo "$INSTALL_DIR/start.sh"
    echo "$INSTALL_DIR/stop.sh"
    echo "$INSTALL_DIR/restart.sh"
}

update_app() {

    if [ ! -d "$INSTALL_DIR" ]; then
        echo "Not installed"
        exit 1
    fi

    "$INSTALL_DIR/stop.sh"

    cd "$INSTALL_DIR"

    LATEST_VERSION=$(get_latest_version)

    PLATFORM=$(get_platform)

    TARBALL_NAME="GooseRelayVPN-server-$LATEST_VERSION-$PLATFORM.tar.gz"

    DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST_VERSION/$TARBALL_NAME"

    curl -fL "$DOWNLOAD_URL" -o goose.tar.gz

    tar -xzf goose.tar.gz

    rm -f goose.tar.gz

    chmod +x "$INSTALL_DIR/$BINARY_NAME"

    "$INSTALL_DIR/start.sh"

    echo -e "${GREEN}Updated${NC}"
}

uninstall_app() {

    if [ -d "$INSTALL_DIR" ]; then

        "$INSTALL_DIR/stop.sh"

        rm -rf "$INSTALL_DIR"

        crontab -l 2>/dev/null \
        | grep -v "$INSTALL_DIR/start.sh" \
        | grep -v "$BINARY_NAME" \
        | crontab -

        echo -e "${GREEN}Uninstalled${NC}"
    fi
}

if [ "$#" -gt 0 ]; then

    case $1 in
        install)
            install_app
            ;;
        update)
            update_app
            ;;
        start)
            "$INSTALL_DIR/start.sh"
            ;;
        stop)
            "$INSTALL_DIR/stop.sh"
            ;;
        restart)
            "$INSTALL_DIR/restart.sh"
            ;;
        uninstall)
            uninstall_app
            ;;
    esac

    exit 0
fi

while true; do

    show_menu

    read -p "Choice: " choice

    case $choice in
        1)
            install_app
            ;;
        2)
            update_app
            ;;
        3)
            "$INSTALL_DIR/start.sh"
            ;;
        4)
            "$INSTALL_DIR/stop.sh"
            ;;
        5)
            "$INSTALL_DIR/restart.sh"
            ;;
        6)
            uninstall_app
            ;;
        7)
            exit 0
            ;;
    esac

    echo ""
done
