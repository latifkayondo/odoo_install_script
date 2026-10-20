#!/bin/bash
################################################################################
# Odoo 20 installer for Ubuntu 24.04
#-------------------------------------------------------------------------------
# Usage:
#   sudo nano odoo-install.sh        # paste this content
#   sudo chmod +x odoo-install.sh
#   sudo ./odoo-install.sh
#
# Requirements (Odoo 20): Python 3.12+, PostgreSQL 16+, wkhtmltopdf 0.12.6 (patched Qt)
# Multiple instances: change OE_USER, OE_PORT and GEVENT_PORT for each one.
################################################################################
set -euo pipefail

#--------------------------------------------------
# Settings
#--------------------------------------------------
OE_USER="odoo20"
OE_HOME="/$OE_USER"                      # home dir of the system user
OE_HOME_EXT="/opt/$OE_USER"              # Odoo source + venv
OE_VERSION="20.0"
OE_PORT="8020"                           # HTTP port
GEVENT_PORT="8072"                       # websocket port (needs workers > 0)
OE_CONFIG="$OE_USER"
OE_DATA_DIR="/var/lib/$OE_USER"
OE_LOG_DIR="/var/log/$OE_USER"

IS_ENTERPRISE="False"                    # needs access to github.com/odoo/enterprise
INSTALL_WKHTMLTOPDF="True"
INSTALL_NGINX="False"
ENABLE_SSL="False"                       # needs a real WEBSITE_NAME and ADMIN_EMAIL
WEBSITE_NAME="_"                         # e.g. erp.example.com
ADMIN_EMAIL="odoo@example.com"           # real email, only used for certbot

# Superadmin (database manager) password.
# "True" = generate randomly, "False" = use OE_SUPERADMIN below.
GENERATE_RANDOM_PASSWORD="True"
OE_SUPERADMIN="admin_passwd"

# Optional third-party addons repo (leave empty to skip). Must have a 20.0-compatible branch.
# COMMUNITY_ADDONS_REPO="https://github.com/Kaylat30/community-addons"
# COMMUNITY_ADDONS_BRANCH="main"
# COMMUNITY_ADDONS_SUBDIRS="accountant_community payroll_community studio_community ai_community"
COMMUNITY_ADDONS_REPO=""
COMMUNITY_ADDONS_BRANCH=""
COMMUNITY_ADDONS_SUBDIRS=""

# Workers: leave empty for auto (based on CPU and RAM), or set a number (min 2).
WORKERS=""

CREDENTIALS_FILE="/root/${OE_USER}-credentials.txt"

#--------------------------------------------------
# Helpers
#--------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root: sudo ./odoo-install.sh" >&2
  exit 1
fi

gen_pass() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-24; }

if ! grep -q "Ubuntu 24.04" /etc/os-release 2>/dev/null; then
  echo "WARNING: this script targets Ubuntu 24.04. Continuing anyway..."
fi

export DEBIAN_FRONTEND=noninteractive

DB_PASSWORD="$(gen_pass)"
if [ "$GENERATE_RANDOM_PASSWORD" = "True" ]; then
  OE_SUPERADMIN="$(gen_pass)"
fi

#--------------------------------------------------
# Update server + build dependencies
#--------------------------------------------------
echo -e "\n---- Update server ----"
apt-get update -y
apt-get upgrade -y
apt-get install -y git curl openssl ca-certificates gnupg \
  build-essential python3 python3-dev python3-pip python3-venv \
  libpq-dev libldap2-dev libsasl2-dev libxml2-dev libxslt1-dev \
  libjpeg-dev zlib1g-dev libssl-dev libffi-dev

PYV="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' \
  || { echo "Odoo 20 needs Python 3.12+, found $PYV" >&2; exit 1; }

#--------------------------------------------------
# PostgreSQL 16 (in Ubuntu 24.04 repos) + pgvector (Odoo AI features)
#--------------------------------------------------
echo -e "\n---- Install PostgreSQL 16 + pgvector ----"
apt-get install -y postgresql-16 postgresql-client-16 postgresql-16-pgvector
systemctl enable --now postgresql
until sudo -u postgres pg_isready >/dev/null 2>&1; do sleep 1; done

# Created in template1 so every new Odoo database inherits it
sudo -u postgres psql -v ON_ERROR_STOP=1 -d template1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"

echo -e "\n---- Create PostgreSQL user ----"
if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$OE_USER'" | grep -q 1; then
  sudo -u postgres createuser -d -R -S "$OE_USER"
fi
sudo -u postgres psql -v ON_ERROR_STOP=1 \
  -c "ALTER USER \"$OE_USER\" WITH PASSWORD '$DB_PASSWORD';"

#--------------------------------------------------
# System user, folders
#--------------------------------------------------
echo -e "\n---- Create system user and folders ----"
if ! id "$OE_USER" >/dev/null 2>&1; then
  adduser --system --quiet --shell=/usr/sbin/nologin --home="$OE_HOME" \
    --gecos 'ODOO' --group "$OE_USER"
fi
mkdir -p "$OE_LOG_DIR" "$OE_DATA_DIR"
chown "$OE_USER:$OE_USER" "$OE_LOG_DIR" "$OE_DATA_DIR"

#--------------------------------------------------
# Odoo source (clone BEFORE creating the venv: git needs an empty target dir)
#--------------------------------------------------
echo -e "\n==== Download Odoo $OE_VERSION ===="
if [ -d "$OE_HOME_EXT/.git" ]; then
  echo "Odoo already cloned in $OE_HOME_EXT, skipping."
else
  [ -d "$OE_HOME_EXT" ] && [ -n "$(ls -A "$OE_HOME_EXT" 2>/dev/null)" ] && {
    echo "$OE_HOME_EXT exists and is not empty. Remove it or choose another OE_USER." >&2; exit 1; }
  git clone --depth 1 --single-branch --branch "$OE_VERSION" \
    https://github.com/odoo/odoo "$OE_HOME_EXT"
fi

echo -e "\n---- Create virtual environment and install Python requirements ----"
python3 -m venv "$OE_HOME_EXT/venv"
"$OE_HOME_EXT/venv/bin/pip" install --upgrade pip setuptools wheel
"$OE_HOME_EXT/venv/bin/pip" install -r "$OE_HOME_EXT/requirements.txt"
"$OE_HOME_EXT/venv/bin/pip" install phonenumbers

echo -e "\n---- Install nodejs, npm and rtlcss ----"
apt-get install -y nodejs npm
npm install -g rtlcss

#--------------------------------------------------
# wkhtmltopdf 0.12.6.1 (patched Qt build, needed for PDF headers/footers)
#--------------------------------------------------
if [ "$INSTALL_WKHTMLTOPDF" = "True" ]; then
  echo -e "\n---- Install wkhtmltopdf 0.12.6.1 ----"
  case "$(dpkg --print-architecture)" in
    amd64) WK_ARCH="amd64" ;;
    arm64) WK_ARCH="arm64" ;;
    *)     WK_ARCH="" ;;
  esac
  WK_OK="False"
  if [ -n "$WK_ARCH" ]; then
    WK_DEB="/tmp/wkhtmltox_0.12.6.1-3.jammy_${WK_ARCH}.deb"
    WK_URL="https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.jammy_${WK_ARCH}.deb"
    if curl -fL -o "$WK_DEB" "$WK_URL" && apt-get install -y "$WK_DEB"; then
      WK_OK="True"
    fi
    rm -f "$WK_DEB"
  fi
  if [ "$WK_OK" != "True" ]; then
    echo "WARNING: patched wkhtmltopdf could not be installed. Installing the Ubuntu"
    echo "         package instead (PDF headers/footers will NOT work)."
    apt-get install -y wkhtmltopdf || echo "WARNING: wkhtmltopdf not installed."
  fi
  command -v wkhtmltopdf >/dev/null 2>&1 && wkhtmltopdf --version || true
fi

#--------------------------------------------------
# Enterprise (optional)
#--------------------------------------------------
if [ "$IS_ENTERPRISE" = "True" ]; then
  echo -e "\n---- Install Odoo Enterprise ----"
  "$OE_HOME_EXT/venv/bin/pip" install psycopg2-binary pdfminer.six num2words ofxparse dbfread \
    firebase_admin pyOpenSSL
  npm install -g less less-plugin-clean-css
  if [ ! -d "$OE_HOME_EXT/enterprise/.git" ]; then
    git clone --depth 1 --single-branch --branch "$OE_VERSION" \
      https://github.com/odoo/enterprise "$OE_HOME_EXT/enterprise" \
      || { echo "Enterprise clone failed. You need access to github.com/odoo/enterprise." >&2; exit 1; }
  fi
fi

#--------------------------------------------------
# Custom + community addons
#--------------------------------------------------
echo -e "\n---- Create custom addons directory ----"
mkdir -p "$OE_HOME_EXT/custom-addons"

if [ -n "$COMMUNITY_ADDONS_REPO" ] && [ ! -d "$OE_HOME_EXT/community-addons/.git" ]; then
  echo -e "\n---- Download community addons ----"
  git clone --depth 1 --single-branch --branch "$COMMUNITY_ADDONS_BRANCH" \
    "$COMMUNITY_ADDONS_REPO" "$OE_HOME_EXT/community-addons" \
    || echo "WARNING: community addons could not be cloned, skipping."
fi

# Build addons_path from folders that really exist (enterprise must come first)
ADDONS_PATH=""
add_path() { [ -d "$1" ] && ADDONS_PATH="${ADDONS_PATH:+$ADDONS_PATH,}$1" || true; }
[ "$IS_ENTERPRISE" = "True" ] && add_path "$OE_HOME_EXT/enterprise"
add_path "$OE_HOME_EXT/addons"
add_path "$OE_HOME_EXT/odoo/addons"
add_path "$OE_HOME_EXT/custom-addons"
add_path "$OE_HOME_EXT/community-addons"
for d in $COMMUNITY_ADDONS_SUBDIRS; do add_path "$OE_HOME_EXT/community-addons/$d"; done

chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT/custom-addons"
[ -d "$OE_HOME_EXT/community-addons" ] && chown -R "$OE_USER:$OE_USER" "$OE_HOME_EXT/community-addons"
# Odoo source and venv stay root-owned (read-only for the service user)

#--------------------------------------------------
# Server config
#--------------------------------------------------
echo -e "\n---- Create server config file ----"

if [ -z "$WORKERS" ]; then
  CPUS="$(nproc)"
  RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
  W_CPU=$((CPUS * 2 + 1))
  W_RAM=$((RAM_MB / 1024))          # roughly 1 worker per GB of RAM
  WORKERS=$(( W_CPU < W_RAM ? W_CPU : W_RAM ))
  [ "$WORKERS" -lt 2 ] && WORKERS=2
fi

PROXY_MODE="False"
[ "$INSTALL_NGINX" = "True" ] && PROXY_MODE="True"

cat > "/etc/${OE_CONFIG}.conf" <<EOF
[options]
; Password that protects database operations (create/drop/backup)
admin_passwd = ${OE_SUPERADMIN}
db_host = localhost
db_port = 5432
db_user = ${OE_USER}
db_password = ${DB_PASSWORD}
http_port = ${OE_PORT}
gevent_port = ${GEVENT_PORT}
addons_path = ${ADDONS_PATH}
data_dir = ${OE_DATA_DIR}
logfile = ${OE_LOG_DIR}/${OE_CONFIG}.log
proxy_mode = ${PROXY_MODE}
workers = ${WORKERS}
max_cron_threads = 2
limit_memory_soft = 2147483648
limit_memory_hard = 2684354560
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
;dbfilter = ^%d$
;list_db = False
;http_interface = 0.0.0.0
EOF
chown "$OE_USER:$OE_USER" "/etc/${OE_CONFIG}.conf"
chmod 640 "/etc/${OE_CONFIG}.conf"

cat > "/etc/logrotate.d/${OE_CONFIG}" <<EOF
${OE_LOG_DIR}/*.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF

#--------------------------------------------------
# systemd service
#--------------------------------------------------
echo -e "\n---- Create systemd service ----"
cat > "/etc/systemd/system/${OE_CONFIG}.service" <<EOF
[Unit]
Description=Odoo ${OE_VERSION} (${OE_CONFIG})
Requires=postgresql.service
After=network.target postgresql.service

[Service]
Type=simple
SyslogIdentifier=${OE_CONFIG}
User=${OE_USER}
Group=${OE_USER}
ExecStart=${OE_HOME_EXT}/venv/bin/python3 ${OE_HOME_EXT}/odoo-bin -c /etc/${OE_CONFIG}.conf
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "/etc/systemd/system/${OE_CONFIG}.service"
systemctl daemon-reload
systemctl enable "${OE_CONFIG}"

#--------------------------------------------------
# Nginx
#--------------------------------------------------
if [ "$INSTALL_NGINX" = "True" ]; then
  echo -e "\n---- Install and configure Nginx ----"
  apt-get install -y nginx

  cat > "/etc/nginx/sites-available/${OE_USER}" <<'EOF'
# Websocket upgrade helper (Odoo live chat / bus)
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

upstream @@USER@@_backend   { server 127.0.0.1:@@PORT@@; }
upstream @@USER@@_websocket { server 127.0.0.1:@@GEVENT@@; }

server {
  listen 80;
  server_name @@SERVER_NAME@@;

  access_log /var/log/nginx/@@USER@@-access.log;
  error_log  /var/log/nginx/@@USER@@-error.log;

  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Host $host;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header X-Real-IP $remote_addr;
  add_header X-Frame-Options "SAMEORIGIN";
  add_header X-Content-Type-Options "nosniff";

  proxy_buffers 16 64k;
  proxy_buffer_size 128k;
  proxy_read_timeout 900s;
  proxy_connect_timeout 900s;
  proxy_send_timeout 900s;
  proxy_next_upstream error timeout invalid_header http_500 http_502 http_503;

  types {
    text/less less;
    text/scss scss;
  }

  gzip on;
  gzip_min_length 1100;
  gzip_buffers 4 32k;
  gzip_types text/css text/less text/plain text/xml application/xml application/json application/javascript image/svg+xml;
  gzip_vary on;

  client_header_buffer_size 4k;
  large_client_header_buffers 4 64k;
  client_max_body_size 512m;

  location /websocket {
    proxy_pass http://@@USER@@_websocket;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Real-IP $remote_addr;
  }

  location / {
    proxy_pass http://@@USER@@_backend;
    proxy_redirect off;
  }

  location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff2?)$ {
    expires 2d;
    proxy_pass http://@@USER@@_backend;
    add_header Cache-Control "public, no-transform";
  }
}
EOF
  sed -i \
    -e "s|@@USER@@|${OE_USER}|g" \
    -e "s|@@PORT@@|${OE_PORT}|g" \
    -e "s|@@GEVENT@@|${GEVENT_PORT}|g" \
    -e "s|@@SERVER_NAME@@|${WEBSITE_NAME}|g" \
    "/etc/nginx/sites-available/${OE_USER}"

  ln -sf "/etc/nginx/sites-available/${OE_USER}" "/etc/nginx/sites-enabled/${OE_USER}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t
  systemctl reload nginx
  echo "Nginx configured: /etc/nginx/sites-available/${OE_USER}"
else
  echo "Nginx not installed (user choice)."
fi

#--------------------------------------------------
# SSL with certbot
#--------------------------------------------------
if [ "$INSTALL_NGINX" = "True" ] && [ "$ENABLE_SSL" = "True" ] \
   && [ "$ADMIN_EMAIL" != "odoo@example.com" ] && [ "$WEBSITE_NAME" != "_" ]; then
  echo -e "\n---- Enable SSL with certbot ----"
  apt-get install -y snapd
  snap install core
  snap refresh core
  snap install --classic certbot
  ln -sf /snap/bin/certbot /usr/bin/certbot
  certbot --nginx -d "$WEBSITE_NAME" --non-interactive --agree-tos \
    --email "$ADMIN_EMAIL" --redirect
  systemctl reload nginx
  echo "SSL/HTTPS enabled."
else
  echo "SSL/HTTPS not enabled (disabled, or WEBSITE_NAME/ADMIN_EMAIL not set to real values)."
fi

#--------------------------------------------------
# Start + summary
#--------------------------------------------------
echo -e "\n---- Start Odoo ----"
systemctl start "${OE_CONFIG}"

umask 077
cat > "$CREDENTIALS_FILE" <<EOF
Odoo superadmin (master) password: ${OE_SUPERADMIN}
PostgreSQL user: ${OE_USER}
PostgreSQL password: ${DB_PASSWORD}
EOF

echo "-----------------------------------------------------------"
echo "Done! Odoo ${OE_VERSION} is installed."
echo "HTTP port:        ${OE_PORT} (websocket: ${GEVENT_PORT}, workers: ${WORKERS})"
echo "Service user:     ${OE_USER}"
echo "Config file:      /etc/${OE_CONFIG}.conf"
echo "Log file:         ${OE_LOG_DIR}/${OE_CONFIG}.log"
echo "Code location:    ${OE_HOME_EXT}"
echo "Addons path:      ${ADDONS_PATH}"
echo "Credentials file: ${CREDENTIALS_FILE} (root only)"
echo "Start:   systemctl start ${OE_CONFIG}"
echo "Stop:    systemctl stop ${OE_CONFIG}"
echo "Restart: systemctl restart ${OE_CONFIG}"
echo "Logs:    journalctl -u ${OE_CONFIG} -f   or   tail -f ${OE_LOG_DIR}/${OE_CONFIG}.log"
[ "$INSTALL_NGINX" = "True" ] && echo "Open: http://<server-ip>/  (nginx -> port ${OE_PORT})" \
  || echo "Open: http://<server-ip>:${OE_PORT}/"
echo "-----------------------------------------------------------"
