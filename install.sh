#!/bin/bash
set -e

# ==========================================
# R-BOTS SSH + CLOUDFLARED INSTALLER
# ==========================================

GREEN="\033[0;32m"
RED="\033[0;31m"
CYAN="\033[0;36m"
YELLOW="\033[1;33m"
RESET="\033[0m"

echo
echo "=========================================="
echo "       R-BOTS SSH + CLOUDFLARED"
echo "=========================================="
echo

# Root check
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Run this script as root.${RESET}"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ==========================================
# 1. INSTALL REQUIRED PACKAGES
# ==========================================

echo -e "${CYAN}[1/7] Installing required packages...${RESET}"

apt-get update -y

apt-get install -y \
    openssh-server \
    curl \
    ca-certificates \
    supervisor \
    iproute2 \
    python3

echo -e "${GREEN}Packages installed.${RESET}"
echo

# ==========================================
# 2. CONFIGURE SSH
# ==========================================

echo -e "${CYAN}[2/7] Configuring SSH...${RESET}"

mkdir -p /run/sshd

# Remove old/conflicting values
sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config <<'EOF'

# R-BOTS SSH
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOF

/usr/sbin/sshd -t

echo -e "${GREEN}SSH configuration OK.${RESET}"
echo

# ==========================================
# 3. INSTALL CLOUDFLARED FROM GITHUB
# ==========================================

echo -e "${CYAN}[3/7] Installing Cloudflared from GitHub...${RESET}"

ARCH=$(dpkg --print-architecture)

case "$ARCH" in
    amd64)
        CF_ARCH="amd64"
        ;;
    arm64)
        CF_ARCH="arm64"
        ;;
    armhf)
        CF_ARCH="arm"
        ;;
    *)
        echo -e "${RED}Unsupported architecture: $ARCH${RESET}"
        exit 1
        ;;
esac

echo "Architecture: $CF_ARCH"

curl -fL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    -o /tmp/cloudflared

install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared

rm -f /tmp/cloudflared

echo
/usr/local/bin/cloudflared --version
echo

echo -e "${GREEN}Cloudflared installed.${RESET}"
echo

# ==========================================
# 4. CLOUDFLARE TOKEN
# ==========================================

echo "=========================================="
echo "        CLOUDFLARE TUNNEL TOKEN"
echo "=========================================="
echo
echo "Paste your Cloudflare Tunnel Token."
echo "The token will not be displayed."
echo

read -rsp "Tunnel Token: " CF_TOKEN
echo
echo

if [ -z "$CF_TOKEN" ]; then
    echo -e "${RED}Token cannot be empty.${RESET}"
    exit 1
fi

mkdir -p /etc/cloudflared
chmod 700 /etc/cloudflared

printf '%s' "$CF_TOKEN" > /etc/cloudflared/token
chmod 600 /etc/cloudflared/token

unset CF_TOKEN

echo
echo -e "${CYAN}[4/7] Testing Cloudflare Tunnel...${RESET}"
echo

rm -f /tmp/cloudflared-test.log

/usr/local/bin/cloudflared tunnel run \
    --token "$(cat /etc/cloudflared/token)" \
    > /tmp/cloudflared-test.log 2>&1 &

TEST_PID=$!

# Give cloudflared time to connect
sleep 12

if ! kill -0 "$TEST_PID" 2>/dev/null; then
    echo
    echo -e "${RED}Cloudflare Tunnel failed.${RESET}"
    echo
    cat /tmp/cloudflared-test.log
    echo
    exit 1
fi

# Check for successful connection
if grep -Eqi \
    "Registered tunnel connection|Connection .* registered|connected" \
    /tmp/cloudflared-test.log; then

    echo -e "${GREEN}Cloudflare Tunnel connected successfully.${RESET}"

else
    echo -e "${YELLOW}Tunnel process is running.${RESET}"
    echo "Cloudflare did not print a connection message yet."
    echo
    echo "Recent log:"
    tail -20 /tmp/cloudflared-test.log
fi

# Stop temporary test
kill "$TEST_PID" 2>/dev/null || true
sleep 2
kill -9 "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true

rm -f /tmp/cloudflared-test.log

echo

# ==========================================
# 5. ROOT PASSWORD
# ==========================================

echo "=========================================="
echo "          CREATE ROOT PASSWORD"
echo "=========================================="
echo

passwd root

echo

# ==========================================
# 6. SSH + CLOUDFLARED AUTO RESTART
# ==========================================

echo -e "${CYAN}[6/7] Configuring automatic services...${RESET}"

mkdir -p /var/log/cloudflared

# ------------------------------------------
# Cloudflared supervisor
# ------------------------------------------

cat > /etc/supervisor/conf.d/cloudflared.conf <<'EOF'
[program:cloudflared]
command=/bin/bash -c '/usr/local/bin/cloudflared tunnel run --token "$(cat /etc/cloudflared/token)"'
directory=/root

autostart=true
autorestart=true
startsecs=5
startretries=999999

stopasgroup=true
killasgroup=true

stdout_logfile=/var/log/cloudflared/cloudflared.log
stderr_logfile=/var/log/cloudflared/cloudflared-error.log

stdout_logfile_maxbytes=10MB
stderr_logfile_maxbytes=10MB

stdout_logfile_backups=3
stderr_logfile_backups=3
EOF

# ------------------------------------------
# SSH watchdog
# ------------------------------------------

cat > /usr/local/bin/ssh-watchdog.sh <<'EOF'
#!/bin/bash

while true
do
    if ! ss -lnt 2>/dev/null | grep -q ':22 '; then
        mkdir -p /run/sshd
        /usr/sbin/sshd
    fi

    sleep 5
done
EOF

chmod +x /usr/local/bin/ssh-watchdog.sh

cat > /etc/supervisor/conf.d/ssh-watchdog.conf <<'EOF'
[program:ssh-watchdog]
command=/usr/local/bin/ssh-watchdog.sh
directory=/root

autostart=true
autorestart=true
startsecs=2
startretries=999999

stdout_logfile=/var/log/ssh-watchdog.log
stderr_logfile=/var/log/ssh-watchdog-error.log

stdout_logfile_maxbytes=5MB
stderr_logfile_maxbytes=5MB

stdout_logfile_backups=2
stderr_logfile_backups=2
EOF

echo -e "${GREEN}Auto-restart configured.${RESET}"
echo

# ==========================================
# 7. START SERVICES
# ==========================================

echo -e "${CYAN}[7/7] Starting services...${RESET}"

mkdir -p /run/sshd

# Start SSH
if ! ss -lnt 2>/dev/null | grep -q ':22 '; then
    /usr/sbin/sshd
fi

# Start supervisor manually because Railway
# containers normally don't run systemd
if ! pgrep -x supervisord >/dev/null 2>&1; then
    supervisord -c /etc/supervisor/supervisord.conf
    sleep 2
fi

supervisorctl reread
supervisorctl update

supervisorctl restart cloudflared 2>/dev/null || \
supervisorctl start cloudflared

supervisorctl restart ssh-watchdog 2>/dev/null || \
supervisorctl start ssh-watchdog

sleep 5

# ==========================================
# FINAL STATUS
# ==========================================

echo
echo "=========================================="
echo "          INSTALLATION COMPLETE"
echo "=========================================="
echo

echo -e "${GREEN}SSH:${RESET}"
echo "  User : root"
echo "  Port : 22"

echo
echo -e "${GREEN}SSH Status:${RESET}"
ss -lnt 2>/dev/null | grep ':22 ' || true

echo
echo -e "${GREEN}Cloudflared Status:${RESET}"
supervisorctl status cloudflared

echo
echo -e "${GREEN}SSH Watchdog:${RESET}"
supervisorctl status ssh-watchdog

echo
echo "Cloudflared log:"
echo "  tail -f /var/log/cloudflared/cloudflared.log"

echo
echo "Cloudflared error log:"
echo "  tail -f /var/log/cloudflared/cloudflared-error.log"

echo
echo "=========================================="
echo -e "${GREEN}          R-BOTS READY 🚀${RESET}"
echo "=========================================="
echo
