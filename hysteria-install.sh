#!/bin/bash
# Hysteria 2 Manager
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

HYSTERIA_DIR="/etc/hysteria"
CONFIG_FILE="${HYSTERIA_DIR}/config.yaml"
SETTINGS_FILE="${HYSTERIA_DIR}/settings.conf"
CLIENTS_DIR="${HYSTERIA_DIR}/clients"
BIN_PATH="/usr/local/bin/hysteria"
CLIENT_LIST="${HYSTERIA_DIR}/clients.list"

if [[ "$EUID" -ne 0 ]]; then
    echo -e "${RED}Error: You must run this as root${NC}"
    exit 1
fi

# ==========================================
# SYSTEM DETECTION & HELPERS
# ==========================================
detect_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) ARCH="amd64" ;;
        aarch64 | arm64) ARCH="arm64" ;;
        armv7l | armv8l | arm) ARCH="arm" ;;
        i386 | i686) ARCH="386" ;;
        s390x) ARCH="s390x" ;;
        *) echo -e "${RED}Unsupported architecture: $(uname -m)${NC}"; exit 1 ;;
    esac
}

install_deps() {
    echo -e "${GREEN}Checking and installing missing dependencies...${NC}"
    local FW_PKG=""
    if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
        FW_PKG="nftables"
    else
        FW_PKG="iptables"
    fi
    if [ -x "$(command -v apt-get)" ]; then
        apt-get update && apt-get install -y curl openssl qrencode jq $FW_PKG
    elif [ -x "$(command -v dnf)" ]; then
        dnf install -y curl openssl qrencode jq $FW_PKG
    elif [ -x "$(command -v yum)" ]; then
        yum install -y curl openssl epel-release qrencode jq $FW_PKG
    elif [ -x "$(command -v pacman)" ]; then
        pacman -Sy --noconfirm curl openssl qrencode jq $FW_PKG
    elif [ -x "$(command -v zypper)" ]; then
        zypper install -y curl openssl qrencode jq $FW_PKG
    else
        echo -e "${RED}Unsupported package manager. Please install curl, jq, openssl, qrencode, and $FW_PKG manually.${NC}"
        exit 1
    fi
}

get_public_ip() {
    local local_ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7}')
    # Fallback for IPv6-only servers
    if [[ -z "$local_ip" ]]; then
        local_ip=$(ip -6 route get 2001:4860:4860::8888 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1)
    fi
    if [[ "$local_ip" =~ ^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^192\.168\.|^fd|^fc ]] || [[ -z "$local_ip" ]]; then
        curl -s https://1.1.1.1/cdn-cgi/trace | grep "ip=" | cut -d= -f2 || curl -s https://ifconfig.me
    else
        echo "$local_ip"
    fi
}

# ==========================================
# CORE FUNCTIONS
# ==========================================
save_server_config() {
    source $SETTINGS_FILE

    # Build listen line based on Port Hopping method
    local LISTEN_LINE="listen: :$PORT"
    if [[ -n "$HOP_RANGE" && "$HOP_METHOD" == "native" ]]; then
        LISTEN_LINE="listen: :$PORT,$HOP_RANGE"
    fi

    cat <<EOF > $CONFIG_FILE
$LISTEN_LINE
auth:
  type: password
  password: $PASSWORD
masquerade:
  type: proxy
  proxy:
    url: https://$MASQ_DOMAIN
    rewriteHost: true
EOF

    if [[ "$OBFS_ENABLED" == "true" ]]; then
        if [[ "$OBFS_TYPE" == "gecko" ]]; then
            cat <<EOF >> $CONFIG_FILE
obfs:
  type: gecko
  gecko:
    password: $OBFS_PASSWORD
    minPacketSize: ${OBFS_MIN_PKT:-512}
    maxPacketSize: ${OBFS_MAX_PKT:-1200}
EOF
        else
            # Default — salamander
            cat <<EOF >> $CONFIG_FILE
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD
EOF
        fi
    fi

    if [[ "$CERT_TYPE" == "acme" ]]; then
        cat <<EOF >> $CONFIG_FILE
tls:
  type: acme
  acme:
    domains:
      - $DOMAIN
    email: $ACME_EMAIL
EOF
    else
        cat <<EOF >> $CONFIG_FILE
tls:
  cert: ${HYSTERIA_DIR}/server.crt
  key: ${HYSTERIA_DIR}/server.key
EOF
    fi

    cat <<EOF > /etc/systemd/system/hysteria.service
[Unit]
Description=Hysteria 2 Service
After=network.target

[Service]
EOF

    if [[ -n "$FIREWALL_BACKEND" ]]; then
        echo "Environment=\"HYSTERIA_FIREWALL_BACKEND=$FIREWALL_BACKEND\"" >> /etc/systemd/system/hysteria.service
    fi

    # Manual redirect rules ONLY if HOP_METHOD is not native
    if [[ -n "$HOP_RANGE" && "$HOP_METHOD" != "native" ]]; then
        if [[ "$FIREWALL_BACKEND" == "nftables" ]]; then
            local NFT_CMD=$(command -v nft)
            cat <<EOF >> /etc/systemd/system/hysteria.service
ExecStartPre=+${NFT_CMD} add table ip hysteria_nat
ExecStartPre=+${NFT_CMD} add chain ip hysteria_nat prerouting { type nat hook prerouting priority dstnat \; }
ExecStartPre=+${NFT_CMD} add rule ip hysteria_nat prerouting udp dport $HOP_RANGE counter redirect to :$PORT
ExecStopPost=+${NFT_CMD} delete table ip hysteria_nat
EOF
        else
            local IPTABLES_CMD=$(command -v iptables)
            local IPT_RANGE=${HOP_RANGE//-/:}
            cat <<EOF >> /etc/systemd/system/hysteria.service
ExecStartPre=+${IPTABLES_CMD} -t nat -A PREROUTING -p udp --dport $IPT_RANGE -j REDIRECT --to-ports $PORT
ExecStopPost=+${IPTABLES_CMD} -t nat -D PREROUTING -p udp --dport $IPT_RANGE -j REDIRECT --to-ports $PORT
EOF
        fi
    fi

    cat <<EOF >> /etc/systemd/system/hysteria.service
ExecStart=$BIN_PATH server -c $CONFIG_FILE
WorkingDirectory=$HYSTERIA_DIR
Restart=always
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl restart hysteria
}

install_hysteria() {
    echo -e "${BLUE}--- Hysteria 2 Universal Installation ---${NC}"
    detect_arch
    echo -e "${GREEN}Detected architecture: ${ARCH}${NC}"

    SERVER_IP=$(get_public_ip)

    read -p "Main Server Port (e.g. 443) [443]: " PORT
    PORT=${PORT:-443}

    echo -e "
${YELLOW}Port Hopping allows you to bypass UDP blocking by listening on a range of ports.${NC}"
    read -p "Add a Port Hopping range? [y/N]: " ENABLE_HOPPING
    if [[ "$ENABLE_HOPPING" =~ ^[Yy]$ ]]; then
        read -p "Enter port range (e.g., 20000-50000) [20000-50000]: " HOP_RANGE
        HOP_RANGE=${HOP_RANGE:-20000-50000}

        echo -e "
Port Hopping method:"
        echo "1) Native (Hysteria handles firewall rules automatically - RECOMMENDED)"
        echo "2) Manual via iptables (older OS or CentOS/Alma)"
        echo "3) Manual via nftables (modern Debian/Ubuntu)"
        read -p "Choice [1-3]: " HOP_CHOICE
        case "$HOP_CHOICE" in
            2) HOP_METHOD="iptables"; FIREWALL_BACKEND="iptables" ;;
            3) HOP_METHOD="nftables"; FIREWALL_BACKEND="nftables" ;;
            *) HOP_METHOD="native"; FIREWALL_BACKEND="" ;;
        esac
    else
        HOP_RANGE=""
        HOP_METHOD=""
        FIREWALL_BACKEND=""
    fi

    echo -e "
Certificate Type:"
    echo "1) Let's Encrypt (Domain)"
    echo "2) Self-Signed (Using Server IP: $SERVER_IP)"
    read -p "Choice [1-2]: " CERT_CHOICE
    if [[ "$CERT_CHOICE" == "1" ]]; then
        read -p "Enter domain: " DOMAIN
        read -p "Enter email: " ACME_EMAIL
        CERT_TYPE="acme"
        SERVER_ADDR=$DOMAIN
        INSECURE_FLAG="false"
        SNI=$DOMAIN
    else
        CERT_TYPE="self"
        SERVER_ADDR=$SERVER_IP
        read -p "Enter fake SNI [bing.com]: " SNI
        SNI=${SNI:-bing.com}
        INSECURE_FLAG="true"
    fi

    read -p "Masquerade site [bing.com]: " MASQ_DOMAIN
    MASQ_DOMAIN=${MASQ_DOMAIN:-bing.com}

    echo -e "
Obfuscation (hides QUIC traffic signature):"
    echo "1) Disabled (mimics standard HTTP/3)"
    echo "2) Salamander (random-looking bytes)"
    echo "3) Gecko (random bytes + packet size randomization)"
    read -p "Choice [1-3]: " OBFS_CHOICE
    case "$OBFS_CHOICE" in
        2)
            OBFS_ENABLED="true"
            OBFS_TYPE="salamander"
            OBFS_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 16 | head -n 1)
            OBFS_MIN_PKT=""; OBFS_MAX_PKT=""
            ;;
        3)
            OBFS_ENABLED="true"
            OBFS_TYPE="gecko"
            OBFS_PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 16 | head -n 1)
            read -p "Gecko minPacketSize [512]: " OBFS_MIN_PKT
            read -p "Gecko maxPacketSize [1200]: " OBFS_MAX_PKT
            OBFS_MIN_PKT=${OBFS_MIN_PKT:-512}
            OBFS_MAX_PKT=${OBFS_MAX_PKT:-1200}
            ;;
        *)
            OBFS_ENABLED="false"
            OBFS_TYPE=""
            OBFS_PASSWORD=""
            OBFS_MIN_PKT=""; OBFS_MAX_PKT=""
            ;;
    esac

    PASSWORD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 16 | head -n 1)

    install_deps

    echo -e "${GREEN}Downloading Hysteria 2 for linux-${ARCH}...${NC}"
    curl -fSL -o $BIN_PATH "https://github.com/apernet/hysteria/releases/latest/download/hysteria-linux-${ARCH}"
    chmod +x $BIN_PATH

    mkdir -p $HYSTERIA_DIR $CLIENTS_DIR

    if [[ "$CERT_TYPE" == "self" ]]; then
        echo -e "${GREEN}Generating self-signed certificate...${NC}"
        openssl ecparam -genkey -name prime256v1 -out ${HYSTERIA_DIR}/server.key 2>/dev/null
        openssl req -new -x509 -days 36500 -key ${HYSTERIA_DIR}/server.key -out ${HYSTERIA_DIR}/server.crt -subj "/CN=$SERVER_IP" 2>/dev/null
    fi

    cat <<EOF > $SETTINGS_FILE
SERVER_ADDR=$SERVER_ADDR
PORT=$PORT
HOP_RANGE=$HOP_RANGE
HOP_METHOD=$HOP_METHOD
PASSWORD=$PASSWORD
INSECURE_FLAG=$INSECURE_FLAG
SNI=$SNI
OBFS_ENABLED=$OBFS_ENABLED
OBFS_TYPE=$OBFS_TYPE
OBFS_PASSWORD=$OBFS_PASSWORD
OBFS_MIN_PKT=$OBFS_MIN_PKT
OBFS_MAX_PKT=$OBFS_MAX_PKT
MASQ_DOMAIN=$MASQ_DOMAIN
CERT_TYPE=$CERT_TYPE
DOMAIN=$DOMAIN
ACME_EMAIL=$ACME_EMAIL
FIREWALL_BACKEND=$FIREWALL_BACKEND
EOF

    save_server_config
    systemctl enable hysteria
    systemctl start hysteria

    echo -e "${GREEN}Hysteria 2 Installed Successfully!${NC}"
    add_client
}

update_hysteria() {
    echo -e "
${BLUE}--- Core Update ---${NC}"
    CURRENT_VER=$($BIN_PATH -v | grep "version" | awk '{print $3}')
    echo -e "Current version: ${YELLOW}$CURRENT_VER${NC}"
    echo "Checking for updates on GitHub..."
    LATEST_VER=$(curl -s https://api.github.com/repos/apernet/hysteria/releases/latest | grep -o '"tag_name": "[^"]*' | grep -o '[^"]*$')
    if [[ -z "$LATEST_VER" ]]; then
        echo -e "${RED}Failed to fetch the latest version. Check your network.${NC}"
        return
    fi
    echo -e "Latest version:  ${GREEN}$LATEST_VER${NC}"

    if [[ "$CURRENT_VER" == "$LATEST_VER" ]] || [[ "v$CURRENT_VER" == "$LATEST_VER" ]]; then
        echo -e "${GREEN}You are already running the latest version!${NC}"
        return
    fi

    read -p "Do you want to update to $LATEST_VER? [y/N]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        detect_arch
        echo -e "${GREEN}Downloading version $LATEST_VER for linux-${ARCH}...${NC}"
        systemctl stop hysteria
        curl -fSL -o $BIN_PATH "https://github.com/apernet/hysteria/releases/download/${LATEST_VER}/hysteria-linux-${ARCH}"
        chmod +x $BIN_PATH
        systemctl start hysteria
        echo -e "${GREEN}Hysteria 2 updated successfully!${NC}"
    else
        echo "Update canceled."
    fi
}

add_client() {
    source $SETTINGS_FILE
    echo -e "
${BLUE}--- Add Client ---${NC}"
    read -p "Client Name (leave blank to go back): " CLIENT_NAME
    if [[ -z "$CLIENT_NAME" ]]; then return; fi
    CLIENT_NAME=$(echo $CLIENT_NAME | tr -d ' ')

    echo "Choose Congestion Control:"
    echo "1) Brutal"
    echo "2) BBR"
    echo "3) Reno"
    echo "0) Back"
    read -p "Choice [1-3]: " CC_CHOICE
    if [[ "$CC_CHOICE" == "0" ]]; then return; fi

    CLIENT_CONFIG_FILE="${CLIENTS_DIR}/${CLIENT_NAME}.yaml"

    local CLIENT_PORTS="$PORT"
    if [[ -n "$HOP_RANGE" ]]; then
        CLIENT_PORTS="${PORT},${HOP_RANGE}"
    fi

    cat <<EOF > $CLIENT_CONFIG_FILE
server: $SERVER_ADDR:$CLIENT_PORTS
auth: $PASSWORD
tls:
  sni: $SNI
  insecure: $INSECURE_FLAG
EOF

    HY2_LINK="hy2://${PASSWORD}@${SERVER_ADDR}:${CLIENT_PORTS}/?insecure=${INSECURE_FLAG}&sni=${SNI}"

    case $CC_CHOICE in
        1)
            read -p "Downlink Mbps [100]: " DOWN
            read -p "Uplink Mbps [20]: " UP
            DOWN=${DOWN:-100}
            UP=${UP:-20}
            echo -e "bandwidth:
  up: $UP mbps
  down: $DOWN mbps" >> $CLIENT_CONFIG_FILE
            HY2_LINK="${HY2_LINK}&up=${UP}&down=${DOWN}"
            ;;
        2) HY2_LINK="${HY2_LINK}&cc=bbr" ;;
        3) HY2_LINK="${HY2_LINK}&cc=reno" ;;
    esac

    if [[ "$OBFS_ENABLED" == "true" ]]; then
        if [[ "$OBFS_TYPE" == "gecko" ]]; then
            cat <<EOF >> $CLIENT_CONFIG_FILE
obfs:
  type: gecko
  gecko:
    password: $OBFS_PASSWORD
    minPacketSize: ${OBFS_MIN_PKT:-512}
    maxPacketSize: ${OBFS_MAX_PKT:-1200}
EOF
            HY2_LINK="${HY2_LINK}&obfs=gecko&obfs-password=${OBFS_PASSWORD}"
        else
            cat <<EOF >> $CLIENT_CONFIG_FILE
obfs:
  type: salamander
  salamander:
    password: $OBFS_PASSWORD
EOF
            HY2_LINK="${HY2_LINK}&obfs=salamander&obfs-password=${OBFS_PASSWORD}"
        fi
    fi

    HY2_LINK="${HY2_LINK}#${CLIENT_NAME}"

    cp $CLIENT_CONFIG_FILE "${HOME}/${CLIENT_NAME}_hysteria.yaml"
    echo -e "${GREEN}Config saved to ${HOME}/${CLIENT_NAME}_hysteria.yaml${NC}"
    qrencode -t ANSIUTF8 "$HY2_LINK"
    echo -e "${YELLOW}Link: ${NC}$HY2_LINK"
    echo "$CLIENT_NAME | $HY2_LINK" >> $CLIENT_LIST
}

list_clients() {
    if [ ! -f "$CLIENT_LIST" ] || [ ! -s "$CLIENT_LIST" ]; then
        echo -e "${RED}No clients found.${NC}"
        return
    fi
    echo -e "
${BLUE}--- Current Clients ---${NC}"
    local names=()
    local links=()
    local i=1
    while IFS='|' read -r name link; do
        name=$(echo "$name" | xargs)
        link=$(echo "$link" | xargs)
        if [[ -n "$name" ]]; then
            echo "$i) $name"
            names+=("$name")
            links+=("$link")
            ((i++))
        fi
    done < "$CLIENT_LIST"
    echo ""
    read -p "Enter client number to show QR (leave blank to go back): " CLIENT_NUM
    if [[ -z "$CLIENT_NUM" ]]; then return; fi
    if [[ "$CLIENT_NUM" =~ ^[0-9]+$ ]] && [ "$CLIENT_NUM" -ge 1 ] && [ "$CLIENT_NUM" -le "${#names[@]}" ]; then
        local idx=$((CLIENT_NUM - 1))
        echo ""
        echo -e "Client: ${YELLOW}${names[$idx]}${NC}"
        qrencode -t ANSIUTF8 "${links[$idx]}"
        echo -e "Link: ${links[$idx]}"
    else
        echo -e "${RED}Invalid selection.${NC}"
    fi
}

delete_client() {
    if [ ! -f "$CLIENT_LIST" ] || [ ! -s "$CLIENT_LIST" ]; then
        echo -e "${RED}No clients to delete.${NC}"
        return
    fi
    echo -e "
${BLUE}--- Delete Client ---${NC}"
    local names=()
    local i=1
    while IFS='|' read -r name link; do
        name=$(echo "$name" | xargs)
        if [[ -n "$name" ]]; then
            echo "$i) $name"
            names+=("$name")
            ((i++))
        fi
    done < "$CLIENT_LIST"
    echo ""
    read -p "Enter client number to delete (leave blank to go back): " DEL_NUM
    if [[ -z "$DEL_NUM" ]]; then return; fi
    if [[ "$DEL_NUM" =~ ^[0-9]+$ ]] && [ "$DEL_NUM" -ge 1 ] && [ "$DEL_NUM" -le "${#names[@]}" ]; then
        local idx=$((DEL_NUM - 1))
        local DEL_NAME="${names[$idx]}"
        sed -i "/^$DEL_NAME |/d" $CLIENT_LIST
        rm -f "${CLIENTS_DIR}/${DEL_NAME}.yaml"
        rm -f "${HOME}/${DEL_NAME}_hysteria.yaml"
        echo -e "${GREEN}Client '$DEL_NAME' removed successfully.${NC}"
    else
        echo -e "${RED}Invalid selection.${NC}"
    fi
}

modify_settings() {
    source $SETTINGS_FILE
    echo -e "
${BLUE}--- Server Settings ---${NC}"
    echo "1) Change Main Port ($PORT)"
    echo "2) Toggle/Change Port Hopping Range (${HOP_RANGE:-Disabled})"
    echo "3) Change Masquerade ($MASQ_DOMAIN)"
    echo "4) Toggle/Change Obfuscation (${OBFS_ENABLED:-false}, type=${OBFS_TYPE:-none})"
    echo "0) Back"
    read -p "Choice: " MOD_CHOICE
    case $MOD_CHOICE in
        1)
            read -p "New Main Port (e.g. 443): " NEW_PORT
            if [[ -n "$NEW_PORT" ]]; then
                sed -i "s/^PORT=.*/PORT=$NEW_PORT/" $SETTINGS_FILE
                PORT=$NEW_PORT
            fi
            ;;
        2)
            echo -e "
${YELLOW}Current Range: ${HOP_RANGE:-None}  |  Method: ${HOP_METHOD:-none}${NC}"
            read -p "Enter new range (e.g., 20000-50000) or '0' to disable: " NEW_RANGE
            if [[ "$NEW_RANGE" == "0" ]]; then
                sed -i "s/^HOP_RANGE=.*/HOP_RANGE=/" $SETTINGS_FILE
                sed -i "s/^HOP_METHOD=.*/HOP_METHOD=/" $SETTINGS_FILE
                HOP_RANGE=""
                HOP_METHOD=""
            elif [[ -n "$NEW_RANGE" && "$NEW_RANGE" == *-* ]]; then
                grep -q "^HOP_RANGE=" $SETTINGS_FILE && sed -i "s/^HOP_RANGE=.*/HOP_RANGE=$NEW_RANGE/" $SETTINGS_FILE || echo "HOP_RANGE=$NEW_RANGE" >> $SETTINGS_FILE
                HOP_RANGE=$NEW_RANGE

                echo -e "
Port Hopping method:"
                echo "1) Native (Hysteria handles firewall rules - RECOMMENDED)"
                echo "2) Manual via iptables"
                echo "3) Manual via nftables"
                read -p "Choice [1-3]: " HOP_CHOICE
                case "$HOP_CHOICE" in
                    2) NEW_METHOD="iptables"; NEW_FW="iptables"; CMD_CHECK="iptables" ;;
                    3) NEW_METHOD="nftables"; NEW_FW="nftables"; CMD_CHECK="nft" ;;
                    *) NEW_METHOD="native"; NEW_FW=""; CMD_CHECK="" ;;
                esac
                grep -q "^HOP_METHOD=" $SETTINGS_FILE && sed -i "s/^HOP_METHOD=.*/HOP_METHOD=$NEW_METHOD/" $SETTINGS_FILE || echo "HOP_METHOD=$NEW_METHOD" >> $SETTINGS_FILE
                HOP_METHOD=$NEW_METHOD
                if [[ -n "$NEW_FW" ]]; then
                    grep -q "^FIREWALL_BACKEND=" $SETTINGS_FILE && sed -i "s/^FIREWALL_BACKEND=.*/FIREWALL_BACKEND=$NEW_FW/" $SETTINGS_FILE || echo "FIREWALL_BACKEND=$NEW_FW" >> $SETTINGS_FILE
                    FIREWALL_BACKEND=$NEW_FW
                    if ! command -v $CMD_CHECK >/dev/null 2>&1; then install_deps; fi
                else
                    sed -i "s/^FIREWALL_BACKEND=.*/FIREWALL_BACKEND=/" $SETTINGS_FILE
                    FIREWALL_BACKEND=""
                fi
            fi
            ;;
        3)
            read -p "New Masquerade: " MASQ_DOMAIN
            sed -i "s/^MASQ_DOMAIN=.*/MASQ_DOMAIN=$MASQ_DOMAIN/" $SETTINGS_FILE
            ;;
        4)
            echo -e "
Current: enabled=${OBFS_ENABLED:-false}, type=${OBFS_TYPE:-none}"
            echo "1) Disable"
            echo "2) Enable Salamander"
            echo "3) Enable Gecko"
            read -p "Choice [1-3]: " OBFS_MOD
            case "$OBFS_MOD" in
                1)
                    sed -i "s/^OBFS_ENABLED=.*/OBFS_ENABLED=false/" $SETTINGS_FILE
                    sed -i "s/^OBFS_TYPE=.*/OBFS_TYPE=/" $SETTINGS_FILE
                    OBFS_ENABLED="false"; OBFS_TYPE=""
                    ;;
                2)
                    NEW_PWD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 16 | head -n 1)
                    sed -i "s/^OBFS_ENABLED=.*/OBFS_ENABLED=true/" $SETTINGS_FILE
                    sed -i "s/^OBFS_TYPE=.*/OBFS_TYPE=salamander/" $SETTINGS_FILE
                    grep -q "^OBFS_PASSWORD=" $SETTINGS_FILE && sed -i "s/^OBFS_PASSWORD=.*/OBFS_PASSWORD=$NEW_PWD/" $SETTINGS_FILE || echo "OBFS_PASSWORD=$NEW_PWD" >> $SETTINGS_FILE
                    sed -i "s/^OBFS_MIN_PKT=.*/OBFS_MIN_PKT=/" $SETTINGS_FILE
                    sed -i "s/^OBFS_MAX_PKT=.*/OBFS_MAX_PKT=/" $SETTINGS_FILE
                    OBFS_ENABLED="true"; OBFS_TYPE="salamander"; OBFS_PASSWORD=$NEW_PWD
                    ;;
                3)
                    NEW_PWD=$(tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w 16 | head -n 1)
                    read -p "Gecko minPacketSize [512]: " NEW_MIN
                    read -p "Gecko maxPacketSize [1200]: " NEW_MAX
                    NEW_MIN=${NEW_MIN:-512}; NEW_MAX=${NEW_MAX:-1200}
                    sed -i "s/^OBFS_ENABLED=.*/OBFS_ENABLED=true/" $SETTINGS_FILE
                    sed -i "s/^OBFS_TYPE=.*/OBFS_TYPE=gecko/" $SETTINGS_FILE
                    grep -q "^OBFS_PASSWORD=" $SETTINGS_FILE && sed -i "s/^OBFS_PASSWORD=.*/OBFS_PASSWORD=$NEW_PWD/" $SETTINGS_FILE || echo "OBFS_PASSWORD=$NEW_PWD" >> $SETTINGS_FILE
                    grep -q "^OBFS_MIN_PKT=" $SETTINGS_FILE && sed -i "s/^OBFS_MIN_PKT=.*/OBFS_MIN_PKT=$NEW_MIN/" $SETTINGS_FILE || echo "OBFS_MIN_PKT=$NEW_MIN" >> $SETTINGS_FILE
                    grep -q "^OBFS_MAX_PKT=" $SETTINGS_FILE && sed -i "s/^OBFS_MAX_PKT=.*/OBFS_MAX_PKT=$NEW_MAX/" $SETTINGS_FILE || echo "OBFS_MAX_PKT=$NEW_MAX" >> $SETTINGS_FILE
                    OBFS_ENABLED="true"; OBFS_TYPE="gecko"; OBFS_PASSWORD=$NEW_PWD
                    OBFS_MIN_PKT=$NEW_MIN; OBFS_MAX_PKT=$NEW_MAX
                    ;;
            esac
            ;;
        0) return ;;
        *) echo "Invalid choice." ; return ;;
    esac
    save_server_config
    echo -e "${GREEN}Updated! Please recreate client configs/QR codes (they use the new port links).${NC}"
}

# MAIN LOOP
if [ ! -f "$BIN_PATH" ]; then
    install_hysteria
fi

while true; do
    echo -e "
${BLUE}Hysteria 2 Manager${NC}"
    echo "1) Add Client"
    echo "2) List/QR Clients"
    echo "3) Delete Client"
    echo "4) Server Settings"
    echo "5) Update Hysteria Core"
    echo "6) Uninstall"
    echo "0) Exit"
    read -p "Choice: " MAIN_CHOICE
    case $MAIN_CHOICE in
        1) add_client ;;
        2) list_clients ;;
        3) delete_client ;;
        4) modify_settings ;;
        5) update_hysteria ;;
        6)
            read -p "Are you sure? [y/N]: " CONFIRM
            if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
                systemctl stop hysteria 2>/dev/null
                systemctl disable hysteria 2>/dev/null
                # Clean up possible leftover firewall rules
                if command -v nft >/dev/null 2>&1; then
                    nft delete table ip hysteria_nat 2>/dev/null
                fi
                if command -v iptables >/dev/null 2>&1; then
                    iptables -t nat -D PREROUTING -p udp -j REDIRECT 2>/dev/null
                fi
                rm -rf $HYSTERIA_DIR /etc/systemd/system/hysteria.service $BIN_PATH
                systemctl daemon-reload
                echo -e "${GREEN}Uninstalled.${NC}"
                break
            fi
            ;;
        0) exit 0 ;;
        *) echo -e "${RED}Invalid choice.${NC}" ;;
    esac
done
