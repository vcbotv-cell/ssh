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

# ------------------------------------------
# ROOT CHECK
# ------------------------------------------

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Please run this script as root.${RESET}"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ------------------------------------------
# 1. INSTALL PACKAGES
# ------------------------------------------

echo -e "${CYAN}[1/7] Installing required packages...${RESET}"
echo

apt-get update -y

apt-get install -y \
    openssh-server \
    curl \
    ca-certificates \
    supervisor \
    iproute2

echo
echo -e "${GREEN}Packages installed successfully.${RESET}"
echo

# ------------------------------------------
# 2. CONFIGURE SSH
# ------------------------------------------

echo -e "${CYAN}[2/7] Configuring SSH...${RESET}"
echo

mkdir -p /run/sshd

# Remove old settings to prevent duplicates
sed -i '/^[[:space:]]*PermitRootLogin[[:space:]]/d' /etc/ssh/sshd_config
sed -i '/^[[:space:]]*PasswordAuthentication[[:space:]]/d' /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config <<'EOF'

# R-BOTS SSH
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

# Test SSH config
/usr/sbin/sshd -t

# Start SSH if not already running
if ! ss -lnt 2>/dev/null | grep -q ':22 '; then
    /usr/sbin/sshd
fi

echo -e "${GREEN}SSH is ready on port 22.${RESET}"
echo

# ------------------------------------------
# 3. INSTALL CLOUDFLARED FROM GITHUB
# ------------------------------------------

echo -e "${CYAN}[3/7] Installing Cloudflared from GitHub...${RESET}"
echo

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
echo

rm -f /tmp/cloudflared

curl -fL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    -o /tmp/cloudflared

install -m 755 /tmp/cloudflared /usr/local/bin/cloudflared

rm -f /tmp/cloudflared

echo
echo "Installed:"
/usr/local/bin/cloudflared --version
echo

echo -e "${GREEN}Cloudflared installed successfully.${RESET}"
echo

# ------------------------------------------
# 4. ASK FOR TOKEN
# ------------------------------------------

echo "=========================================="
echo "        CLOUDFLARE TUNNEL TOKEN"
echo "=========================================="
echo
echo "Paste your Cloudflare Tunnel Token."
echo "Your token will remain hidden."
echo

read -rsp "Enter your Cloudflare Tunnel Token: " CF_TOKEN
echo
echo

if [ -z "$CF_TOKEN" ]; then
    echo -e "${RED}Token cannot be empty.${RESET}"
    exit 1
fi

mkdir -p /etc/cloudflared
chmod 700 /etc/cloudflared

# Save token securely
printf '%s' "$CF_TOKEN" > /etc/cloudflared/token
chmod 600 /etc/cloudflared/token

# Remove token from shell variable
unset CF_TOKEN

# ------------------------------------------
# 5. TEST TOKEN / CONNECTION
# ------------------------------------------

echo
echo -e "${CYAN}[4/7] Connecting to Cloudflare Tunnel...${RESET}"
echo

rm -f /tmp/cloudflared-test.log

/usr/local/bin/cloudflared tunnel run \
    --token "$(cat /etc/cloudflared/token)" \
    > /tmp/cloudflared-test.log 2>&1 &

TEST_PID=$!

# Wait for Cloudflare connection
CONNECTED=0

for i in $(seq 1 20); do

    # Process exited = failure
    if ! kill -0 "$TEST_PID" 2>/dev/null; then
        break
    fi

    if grep -Eqi \
        "Registered tunnel connection|Connection .* registered|registered.*connection" \
        /tmp/cloudflared-test.log; then

        CONNECTED=1
        break
    fi

    sleep 1
done

if [ "$CONNECTED" != "1" ]; then

    # Give process a final moment
    sleep 2

    if kill -0 "$TEST_PID" 2>/dev/null; then
        CONNECTED=1
    fi
fi

if [ "$CONNECTED" != "1" ]; then

    echo
    echo -e "${RED}Cloudflare Tunnel failed.${RESET}"
    echo
    echo "Cloudflared output:"
    echo "------------------------------------------"
    cat /tmp/cloudflared-test.log
    echo "------------------------------------------"
    echo
    echo "The token may be invalid or the tunnel may be unavailable."

    rm -f /tmp/cloudflared-test.log

    exit 1
fi

echo
echo -e "${GREEN}Cloudflare Tunnel connected successfully.${RESET}"
echo

# Stop temporary test
kill "$TEST_PID" 2>/dev/null || true
sleep 2
kill -9 "$TEST_PID" 2>/dev/null || true
wait "$TEST_PID" 2>/dev/null || true

rm -f /tmp/cloudflared-test.log

# ------------------------------------------
# 6. ROOT PASSWORD
# ------------------------------------------

echo
echo "=========================================="
echo "          CREATE ROOT PASSWORD"
echo "=========================================="
echo

passwd root

echo
echo -e "${GREEN}Root password configured.${RESET}"
echo

# ------------------------------------------
# 7. SUPERVISOR AUTO RESTART
# ------------------------------------------

echo -e "${CYAN}[5/7] Configuring Cloudflared auto-restart...${RESET}"
echo

mkdir -p /var/log/cloudflared

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
# SSH WATCHDOG
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

# ------------------------------------------
# START SUPERVISOR
# ------------------------------------------

echo -e "${CYAN}[6/7] Starting Supervisor...${RESET}"
echo

if ! pgrep -x supervisord >/dev/null 2>&1; then
    supervisord -c /etc/supervisor/supervisord.conf
    sleep 2
fi

supervisorctl reread
supervisorctl update

# Start Cloudflared
supervisorctl restart cloudflared 2>/dev/null || \
supervisorctl start cloudflared

# Start SSH watchdog
supervisorctl restart ssh-watchdog 2>/dev/null || \
supervisorctl start ssh-watchdog

sleep 5

# ------------------------------------------
# FINAL CHECK
# ------------------------------------------

echo -e "${CYAN}[7/7] Checking services...${RESET}"
echo

echo "SSH:"
if ss -lnt 2>/dev/null | grep -q ':22 '; then
    echo -e "${GREEN}SSH is listening on port 22.${RESET}"
else
    echo -e "${RED}SSH is not listening.${RESET}"
fi

echo
echo "Cloudflared:"
supervisorctl status cloudflared

echo
echo "SSH Watchdog:"
supervisorctl status ssh-watchdog

echo
echo "=========================================="
echo -e "${GREEN}          R-BOTS READY 🚀${RESET}"
echo "=========================================="
echo
echo "SSH User : root"
echo "SSH Port : 22"
echo
echo "Cloudflared log:"
echo "tail -f /var/log/cloudflared/cloudflared.log"
echo
echo "Cloudflared error log:"
echo "tail -f /var/log/cloudflared/cloudflared-error.log"
echo
echo "=========================================="
