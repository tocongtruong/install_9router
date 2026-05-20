#!/usr/bin/env bash
# 9Router auto installer for Ubuntu 20.04 / 22.04 / 24.04.
# Supports two runtime modes:
#   1. Docker image: faster, uses decolua/9router:latest.
#   2. PM2 source build: clones GitHub source, installs Node.js, builds locally.
# Supports three public access modes:
#   1. Nginx reverse proxy with domain.
#   2. Existing Caddy/other reverse proxy.
#   3. Direct IP:port without reverse proxy.

set -Eeuo pipefail

APP_NAME="9router"
REPO_URL="https://github.com/decolua/9router.git"
REPO_BRANCH="master"
DOCKER_IMAGE="decolua/9router:latest"
NODE_MAJOR="22"

INSTALL_ROOT="/opt/9router"
SOURCE_DIR="${INSTALL_ROOT}/app"
DATA_DIR="/var/lib/9router"
PM2_ECOSYSTEM="${INSTALL_ROOT}/ecosystem.config.js"

NGINX_CONF="/etc/nginx/sites-available/9router"
NGINX_LINK="/etc/nginx/sites-enabled/9router"

UPDATE_SCRIPT="/usr/local/bin/9router-update"
UPDATE_SERVICE="/etc/systemd/system/9router-update.service"
UPDATE_TIMER="/etc/systemd/system/9router-update.timer"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "%b[INFO]%b  %s\n" "$BLUE" "$NC" "$1"; }
success() { printf "%b[OK]%b    %s\n" "$GREEN" "$NC" "$1"; }
warn()    { printf "%b[WARN]%b  %s\n" "$YELLOW" "$NC" "$1"; }
error()   { printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1" >&2; exit 1; }

step() {
  printf "\n%b%s%b\n" "$BOLD$CYAN" "========================================" "$NC"
  printf "%b  %s%b\n" "$BOLD$CYAN" "$1" "$NC"
  printf "%b%s%b\n" "$BOLD$CYAN" "========================================" "$NC"
}

trap 'rc=$?; printf "%b[ERROR]%b Failed at line %s: %s\n" "$RED" "$NC" "$LINENO" "$BASH_COMMAND" >&2; exit "$rc"' ERR

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

is_yes() {
  case "${1:-}" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    error "Run this script as root: sudo bash $0"
  fi
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 )) || return 1
  [[ "$port" != "80" && "$port" != "443" ]]
}

read_env_value_from_file() {
  local file="$1"
  local key="$2"
  local line value

  [[ -f "$file" ]] || return 1
  line="$(grep -E "^${key}=" "$file" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1

  value="${line#*=}"
  if [[ "$value" == \"*\" && "$value" == *\" && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' && ${#value} -ge 2 ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf "%s" "$value"
}

read_existing_env_value() {
  local key="$1"
  local candidate
  for candidate in "${ENV_FILE:-}" "${SOURCE_DIR}/.env" "${INSTALL_ROOT}/.env"; do
    [[ -n "$candidate" ]] || continue
    if read_env_value_from_file "$candidate" "$key" >/dev/null 2>&1; then
      read_env_value_from_file "$candidate" "$key"
      return 0
    fi
  done
  return 1
}

existing_or_random_hex() {
  local key="$1"
  local bytes="$2"
  local existing

  existing="$(read_existing_env_value "$key" 2>/dev/null || true)"
  if [[ -n "$existing" ]]; then
    printf "%s" "$existing"
  else
    openssl rand -hex "$bytes"
  fi
}

dotenv_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

env_file_value() {
  local value="$1"

  value="${value//$'\r'/}"
  value="${value//$'\n'/}"

  if [[ "${INSTALL_METHOD:-}" == "docker" ]]; then
    # Docker --env-file does not strip quotes; write raw values for containers.
    printf "%s" "$value"
  else
    dotenv_quote "$value"
  fi
}

banner() {
  clear 2>/dev/null || true
  printf "%b" "$BOLD$CYAN"
  cat <<'EOF'
  ___  ____            _
 / _ \|  _ \ ___  _  _| |_ ___ _ __
| (_) | |_) / _ \| || |  _/ -_) '__|
 \___/|____/\___/ \_,_|\__\___|_|

  Auto Installer - Docker / PM2 + Domain or IP:port
EOF
  printf "%b\n" "$NC"
}

select_install_method() {
  local choice
  while true; do
    printf "%bInstall method%b\n" "$BOLD" "$NC"
    printf "  1) Docker image - faster, recommended\n"
    printf "  2) PM2 source build - builds from GitHub source\n"
    read -rp "Choose [1]: " choice
    choice="${choice:-1}"
    case "$choice" in
      1|docker|Docker|DOCKER)
        INSTALL_METHOD="docker"
        ENV_FILE="${INSTALL_ROOT}/.env"
        return 0
        ;;
      2|pm2|PM2)
        INSTALL_METHOD="pm2"
        ENV_FILE="${SOURCE_DIR}/.env"
        return 0
        ;;
      *)
        warn "Invalid choice. Enter 1 or 2."
        ;;
    esac
  done
}

select_access_mode() {
  local choice
  while true; do
    printf "\n%bPublic access mode%b\n" "$BOLD" "$NC"
    printf "  1) Nginx reverse proxy + domain + optional SSL\n"
    printf "  2) Existing Caddy/other reverse proxy - script will not touch port 80/443\n"
    printf "  3) Direct IP:port - no reverse proxy\n"
    read -rp "Choose [3]: " choice
    choice="${choice:-3}"
    case "$choice" in
      1|nginx|Nginx|NGINX)
        ACCESS_MODE="nginx"
        CONFIGURE_NGINX="true"
        APP_LISTEN_HOST="127.0.0.1"
        DOCKER_HOST_BIND="127.0.0.1"
        return 0
        ;;
      2|caddy|Caddy|CADDY|proxy|Proxy|PROXY)
        ACCESS_MODE="external-proxy"
        CONFIGURE_NGINX="false"
        INSTALL_SSL="n"
        APP_LISTEN_HOST="127.0.0.1"
        DOCKER_HOST_BIND="127.0.0.1"
        return 0
        ;;
      3|direct|Direct|DIRECT|ip|IP)
        ACCESS_MODE="direct"
        CONFIGURE_NGINX="false"
        APP_LISTEN_HOST="0.0.0.0"
        DOCKER_HOST_BIND="0.0.0.0"
        return 0
        ;;
      *)
        warn "Invalid choice. Enter 1, 2, or 3."
        ;;
    esac
  done
}

detect_server_ip() {
  local ip

  if command_exists curl; then
    ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] && { printf "%s" "$ip"; return 0; }
    ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    [[ -n "$ip" ]] && { printf "%s" "$ip"; return 0; }
  fi

  ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [[ -n "$ip" ]] && { printf "%s" "$ip"; return 0; }

  printf "SERVER_IP"
}

collect_inputs() {
  local existing_password password_input detected_ip public_host

  step "Install settings"
  select_install_method

  read -rp "$(printf "%b9Router host port%b [20128]: " "$BOLD" "$NC")" APP_PORT
  APP_PORT="${APP_PORT:-20128}"
  validate_port "$APP_PORT" || error "Invalid port. Use 1-65535, except 80 and 443."

  select_access_mode

  case "$ACCESS_MODE" in
    nginx)
      read -rp "$(printf "%bDomain%b (example: ai.example.com): " "$BOLD" "$NC")" DOMAIN
      validate_domain "$DOMAIN" || error "Invalid domain. Use a normal hostname, for example ai.example.com."

      read -rp "$(printf "%bInstall SSL with Certbot?%b (y/n) [y]: " "$BOLD" "$NC")" INSTALL_SSL
      INSTALL_SSL="${INSTALL_SSL:-y}"

      if is_yes "$INSTALL_SSL"; then
        read -rp "$(printf "%bEmail for Let's Encrypt%b: " "$BOLD" "$NC")" EMAIL
        validate_email "$EMAIL" || error "Invalid email address."
        BASE_URL="https://${DOMAIN}"
        AUTH_COOKIE_SECURE="true"
      else
        EMAIL=""
        BASE_URL="http://${DOMAIN}"
        AUTH_COOKIE_SECURE="false"
      fi
      ;;
    external-proxy)
      read -rp "$(printf "%bPublic domain%b handled by Caddy/proxy (example: ai.example.com): " "$BOLD" "$NC")" DOMAIN
      validate_domain "$DOMAIN" || error "Invalid domain. Use a normal hostname, for example ai.example.com."

      read -rp "$(printf "%bPublic URL scheme%b (http/https) [https]: " "$BOLD" "$NC")" PUBLIC_SCHEME
      PUBLIC_SCHEME="${PUBLIC_SCHEME:-https}"
      [[ "$PUBLIC_SCHEME" == "http" || "$PUBLIC_SCHEME" == "https" ]] || error "Scheme must be http or https."

      BASE_URL="${PUBLIC_SCHEME}://${DOMAIN}"
      AUTH_COOKIE_SECURE="false"
      if [[ "$PUBLIC_SCHEME" == "https" ]]; then
        AUTH_COOKIE_SECURE="true"
      fi
      ;;
    direct)
      read -rp "$(printf "%bNeed SSL/domain?%b (y/n) [n]: " "$BOLD" "$NC")" INSTALL_SSL
      INSTALL_SSL="${INSTALL_SSL:-n}"

      if is_yes "$INSTALL_SSL"; then
        warn "Direct IP:port cannot use normal Certbot SSL. Switching to Nginx + domain mode."
        ACCESS_MODE="nginx"
        CONFIGURE_NGINX="true"
        APP_LISTEN_HOST="127.0.0.1"
        DOCKER_HOST_BIND="127.0.0.1"

        read -rp "$(printf "%bDomain%b (example: ai.example.com): " "$BOLD" "$NC")" DOMAIN
        validate_domain "$DOMAIN" || error "Invalid domain. Use a normal hostname, for example ai.example.com."

        read -rp "$(printf "%bEmail for Let's Encrypt%b: " "$BOLD" "$NC")" EMAIL
        validate_email "$EMAIL" || error "Invalid email address."

        BASE_URL="https://${DOMAIN}"
        AUTH_COOKIE_SECURE="true"
      else
        detected_ip="$(detect_server_ip)"
        read -rp "$(printf "%bPublic IP for display/BASE_URL%b [%s]: " "$BOLD" "$NC" "$detected_ip")" public_host
        public_host="${public_host:-$detected_ip}"

        DOMAIN="$public_host"
        EMAIL=""
        BASE_URL="http://${public_host}:${APP_PORT}"
        AUTH_COOKIE_SECURE="false"
      fi
      ;;
  esac

  existing_password="$(read_existing_env_value "INITIAL_PASSWORD" 2>/dev/null || true)"
  if [[ -n "$existing_password" ]]; then
    read -rsp "$(printf "%bDashboard password%b (leave blank to keep current): " "$BOLD" "$NC")" password_input
    printf "\n"
    INIT_PASSWORD="${password_input:-$existing_password}"
  else
    read -rsp "$(printf "%bDashboard password%b [123456]: " "$BOLD" "$NC")" password_input
    printf "\n"
    INIT_PASSWORD="${password_input:-123456}"
  fi

  read -rp "$(printf "%bEnable daily auto-update timer?%b (y/n) [n]: " "$BOLD" "$NC")" ENABLE_AUTO_UPDATE
  ENABLE_AUTO_UPDATE="${ENABLE_AUTO_UPDATE:-n}"

  printf "\n%bConfirm settings%b\n" "$BOLD" "$NC"
  printf "  Runtime      : %b%s%b\n" "$GREEN" "$INSTALL_METHOD" "$NC"
  printf "  Access mode  : %b%s%b\n" "$GREEN" "$ACCESS_MODE" "$NC"
  printf "  Public URL   : %b%s%b\n" "$GREEN" "$BASE_URL" "$NC"
  printf "  Host bind    : %b%s:%s%b\n" "$GREEN" "$APP_LISTEN_HOST" "$APP_PORT" "$NC"
  printf "  Docker bind  : %b%s:%s%b\n" "$GREEN" "$DOCKER_HOST_BIND" "$APP_PORT" "$NC"
  printf "  SSL by script: %b%s%b\n" "$GREEN" "$INSTALL_SSL" "$NC"
  printf "  Auto-update  : %b%s%b\n" "$GREEN" "$ENABLE_AUTO_UPDATE" "$NC"
  printf "  Config dir   : %b%s%b\n" "$GREEN" "$INSTALL_ROOT" "$NC"
  printf "  Data dir     : %b%s%b\n" "$GREEN" "$DATA_DIR" "$NC"
  printf "\n"

  read -rp "Continue? (y/n) [y]: " CONFIRM
  CONFIRM="${CONFIRM:-y}"
  is_yes "$CONFIRM" || { echo "Cancelled."; exit 0; }
}

install_base_packages() {
  step "Installing base packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg openssl
  success "Base packages are ready."
}

install_nodejs() {
  local major version

  if command_exists node; then
    version="$(node -v 2>/dev/null || true)"
    major="${version#v}"
    major="${major%%.*}"
    if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= NODE_MAJOR )); then
      success "Node.js ${version} is already installed."
      return 0
    fi
  fi

  step "Installing Node.js ${NODE_MAJOR}"
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" -o /tmp/nodesource_setup.sh
  bash /tmp/nodesource_setup.sh >/dev/null
  rm -f /tmp/nodesource_setup.sh
  apt-get install -y -qq nodejs
  success "Node.js $(node -v) installed."
}

install_pm2() {
  if command_exists pm2; then
    success "PM2 is already installed."
    return 0
  fi

  step "Installing PM2"
  npm install -g pm2
  success "PM2 installed."
}

install_docker_engine() {
  step "Installing Docker"
  if ! command_exists docker; then
    apt-get install -y -qq docker.io
  fi

  systemctl enable --now docker >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || error "Docker is installed but the daemon is not running."
  success "Docker is ready."
}

reload_nginx() {
  if command_exists systemctl; then
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1
  else
    service nginx reload >/dev/null 2>&1 || service nginx restart >/dev/null 2>&1
  fi
}

stop_other_runtime() {
  if [[ "$INSTALL_METHOD" == "docker" ]]; then
    if command_exists pm2; then
      pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
      pm2 save >/dev/null 2>&1 || true
    fi
  else
    if command_exists docker; then
      docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
    fi
  fi
}

sync_source() {
  step "Cloning or updating 9Router source"
  install -d -m 0755 "$INSTALL_ROOT"

  if [[ -d "$SOURCE_DIR/.git" ]]; then
    cd "$SOURCE_DIR"
    git fetch origin "$REPO_BRANCH"
    git pull --ff-only origin "$REPO_BRANCH"
  elif [[ -d "$SOURCE_DIR" ]] && [[ -n "$(find "$SOURCE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
    error "$SOURCE_DIR exists but is not a git repository. Move it away or choose Docker mode."
  else
    rm -rf "$SOURCE_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$SOURCE_DIR"
  fi

  success "Source is ready at $SOURCE_DIR."
}

write_env_file() {
  local runtime_data_dir runtime_hostname runtime_port jwt_secret api_key_secret machine_id_salt

  install -d -m 0755 "$INSTALL_ROOT"
  install -d -m 0750 "$DATA_DIR"

  if [[ "$INSTALL_METHOD" == "docker" ]]; then
    runtime_data_dir="/app/data"
    runtime_hostname="0.0.0.0"
    runtime_port="20128"
    ENV_FILE="${INSTALL_ROOT}/.env"
  else
    runtime_data_dir="$DATA_DIR"
    runtime_hostname="$APP_LISTEN_HOST"
    runtime_port="$APP_PORT"
    ENV_FILE="${SOURCE_DIR}/.env"
  fi

  jwt_secret="$(existing_or_random_hex "JWT_SECRET" 32)"
  api_key_secret="$(existing_or_random_hex "API_KEY_SECRET" 24)"
  machine_id_salt="$(existing_or_random_hex "MACHINE_ID_SALT" 16)"

  cat > "$ENV_FILE" <<EOF
# 9Router environment generated by install_9router.sh
# Generated at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

JWT_SECRET=$(env_file_value "$jwt_secret")
INITIAL_PASSWORD=$(env_file_value "$INIT_PASSWORD")
DATA_DIR=$(env_file_value "$runtime_data_dir")
PORT=${runtime_port}
HOSTNAME=$(env_file_value "$runtime_hostname")
NODE_ENV=$(env_file_value "production")

BASE_URL=$(env_file_value "$BASE_URL")
NEXT_PUBLIC_BASE_URL=$(env_file_value "$BASE_URL")
NEXT_PUBLIC_CLOUD_URL=$(env_file_value "https://9router.com")
CLOUD_URL=$(env_file_value "https://9router.com")

API_KEY_SECRET=$(env_file_value "$api_key_secret")
MACHINE_ID_SALT=$(env_file_value "$machine_id_salt")

AUTH_COOKIE_SECURE=${AUTH_COOKIE_SECURE}
REQUIRE_API_KEY=true
ENABLE_REQUEST_LOGS=false
OBSERVABILITY_ENABLED=true
EOF

  chmod 600 "$ENV_FILE"
  success "Environment file written to $ENV_FILE."
}

install_pm2_mode() {
  step "Installing 9Router with PM2"
  install_base_packages
  apt-get install -y -qq git python3 make g++
  install_nodejs
  install_pm2
  stop_other_runtime
  sync_source
  write_env_file

  cd "$SOURCE_DIR"
  info "Installing npm dependencies..."
  npm install

  info "Building production app..."
  npm run build

  cat > "$PM2_ECOSYSTEM" <<EOF
module.exports = {
  apps: [{
    name: '${APP_NAME}',
    script: 'npm',
    args: 'start',
    cwd: '${SOURCE_DIR}',
    env: {
      NODE_ENV: 'production',
      PORT: ${APP_PORT},
      HOSTNAME: '${APP_LISTEN_HOST}'
    },
    restart_delay: 3000,
    max_restarts: 10,
    watch: false,
    log_date_format: 'YYYY-MM-DD HH:mm:ss'
  }]
};
EOF

  pm2 delete "$APP_NAME" >/dev/null 2>&1 || true
  pm2 start "$PM2_ECOSYSTEM"
  pm2 save
  pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || warn "PM2 startup registration failed. App is running, but may not auto-start after reboot."

  success "9Router is running with PM2 on ${APP_LISTEN_HOST}:${APP_PORT}."
}

install_docker_mode() {
  step "Installing 9Router with Docker"
  install_base_packages
  install_docker_engine
  stop_other_runtime
  write_env_file

  docker pull "$DOCKER_IMAGE"
  docker rm -f "$APP_NAME" >/dev/null 2>&1 || true
  docker run -d \
    --name "$APP_NAME" \
    --restart unless-stopped \
    --env-file "$ENV_FILE" \
    -p "${DOCKER_HOST_BIND}:${APP_PORT}:20128" \
    -v "${DATA_DIR}:/app/data" \
    "$DOCKER_IMAGE"

  success "9Router is running in Docker on ${DOCKER_HOST_BIND}:${APP_PORT}."
}

check_nginx_port_conflicts() {
  local listeners

  command_exists ss || return 0

  listeners="$(ss -ltnp 2>/dev/null | awk 'NR > 1 && $4 ~ /:80$/ && $0 !~ /nginx/ {print}' || true)"
  if [[ -n "$listeners" ]]; then
    printf "%s\n" "$listeners" >&2
    error "Port 80 is already used by another service. Choose direct IP:port mode or use the existing proxy."
  fi

  if is_yes "$INSTALL_SSL"; then
    listeners="$(ss -ltnp 2>/dev/null | awk 'NR > 1 && $4 ~ /:443$/ && $0 !~ /nginx/ {print}' || true)"
    if [[ -n "$listeners" ]]; then
      printf "%s\n" "$listeners" >&2
      error "Port 443 is already used by another service. Choose direct IP:port mode or use the existing proxy."
    fi
  fi
}

write_nginx_config() {
  step "Configuring Nginx"
  check_nginx_port_conflicts
  apt-get install -y -qq nginx
  install -d -m 0755 /var/www/html

  cat > "$NGINX_CONF" <<EOF
# 9Router Nginx config for ${DOMAIN}
# Generated by install_9router.sh at $(date -u +"%Y-%m-%dT%H:%M:%SZ")

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 50M;

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        proxy_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        chunked_transfer_encoding on;
    }
}
EOF

  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
  ln -sf "$NGINX_CONF" "$NGINX_LINK"
  nginx -t
  reload_nginx
  success "Nginx HTTP proxy is ready."
}

install_ssl() {
  if ! is_yes "$INSTALL_SSL"; then
    warn "SSL skipped. Public URL is ${BASE_URL}."
    return 0
  fi

  step "Installing SSL with Certbot"
  apt-get install -y -qq certbot python3-certbot-nginx

  certbot --nginx \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --redirect

  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
  nginx -t
  reload_nginx
  success "SSL is installed and auto-renewal is enabled."
}

write_update_script() {
  step "Writing update helper"

  cat > "$UPDATE_SCRIPT" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="${APP_NAME}"
METHOD="${INSTALL_METHOD}"
REPO_BRANCH="${REPO_BRANCH}"
SOURCE_DIR="${SOURCE_DIR}"
DOCKER_IMAGE="${DOCKER_IMAGE}"
ENV_FILE="${ENV_FILE}"
DATA_DIR="${DATA_DIR}"
APP_PORT="${APP_PORT}"
DOCKER_HOST_BIND="${DOCKER_HOST_BIND}"

log() { printf '[INFO] %s\\n' "\$1"; }
ok() { printf '[OK] %s\\n' "\$1"; }

if [[ "\$METHOD" == "docker" ]]; then
  log "Pulling \$DOCKER_IMAGE"
  docker pull "\$DOCKER_IMAGE"

  current_image="\$(docker inspect -f '{{.Image}}' "\$APP_NAME" 2>/dev/null || true)"
  latest_image="\$(docker image inspect -f '{{.Id}}' "\$DOCKER_IMAGE")"

  if [[ -n "\$current_image" && "\$current_image" == "\$latest_image" ]]; then
    ok "Docker container already uses the latest image."
    exit 0
  fi

  docker rm -f "\$APP_NAME" >/dev/null 2>&1 || true
  docker run -d \\
    --name "\$APP_NAME" \\
    --restart unless-stopped \\
    --env-file "\$ENV_FILE" \\
    -p "\${DOCKER_HOST_BIND}:\${APP_PORT}:20128" \\
    -v "\${DATA_DIR}:/app/data" \\
    "\$DOCKER_IMAGE"
  ok "Docker container updated."
else
  cd "\$SOURCE_DIR"
  old_rev="\$(git rev-parse HEAD)"
  git fetch origin "\$REPO_BRANCH"
  new_rev="\$(git rev-parse "origin/\$REPO_BRANCH")"

  if [[ "\$old_rev" == "\$new_rev" ]]; then
    ok "Source tree is already up to date."
    exit 0
  fi

  git pull --ff-only origin "\$REPO_BRANCH"
  npm install
  npm run build
  pm2 restart "\$APP_NAME" --update-env
  pm2 save
  ok "PM2 app updated."
fi
EOF

  chmod +x "$UPDATE_SCRIPT"
  success "Update helper written to $UPDATE_SCRIPT."
}

enable_update_timer() {
  if ! is_yes "$ENABLE_AUTO_UPDATE"; then
    return 0
  fi

  if ! command_exists systemctl; then
    warn "systemctl is not available, auto-update timer was not enabled."
    return 0
  fi

  cat > "$UPDATE_SERVICE" <<EOF
[Unit]
Description=Update 9Router

[Service]
Type=oneshot
ExecStart=${UPDATE_SCRIPT}
EOF

  cat > "$UPDATE_TIMER" <<'EOF'
[Unit]
Description=Daily 9Router update check

[Timer]
OnCalendar=daily
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now 9router-update.timer
  success "Daily auto-update timer enabled."
}

print_summary() {
  local update_status

  if is_yes "$ENABLE_AUTO_UPDATE"; then
    update_status="enabled"
  else
    update_status="disabled"
  fi

  printf "\n%b%s%b\n" "$BOLD$GREEN" "Install completed." "$NC"
  printf "  Dashboard    : %s/dashboard\n" "$BASE_URL"
  printf "  API endpoint : %s/v1\n" "$BASE_URL"
  printf "  Runtime      : %s\n" "$INSTALL_METHOD"
  printf "  Access mode  : %s\n" "$ACCESS_MODE"
  printf "  Host port    : %s\n" "$APP_PORT"
  printf "  Config       : %s\n" "$ENV_FILE"
  printf "  Data         : %s\n" "$DATA_DIR"
  printf "  Update       : %s (%s)\n" "$UPDATE_SCRIPT" "$update_status"
  printf "\n"

  if [[ "$ACCESS_MODE" == "direct" ]]; then
    printf "Direct mode note:\n"
    printf "  Open TCP port %s in your VPS firewall/security group if it is not reachable.\n" "$APP_PORT"
    printf "\n"
  elif [[ "$ACCESS_MODE" == "external-proxy" ]]; then
    printf "Caddy example:\n"
    printf "  %s {\n" "$DOMAIN"
    printf "      reverse_proxy 127.0.0.1:%s\n" "$APP_PORT"
    printf "  }\n"
    printf "\n"
  fi

  if [[ "$INSTALL_METHOD" == "docker" ]]; then
    printf "Manage commands:\n"
    printf "  docker logs -f %s\n" "$APP_NAME"
    printf "  docker restart %s\n" "$APP_NAME"
    printf "  %s\n" "$UPDATE_SCRIPT"
  else
    printf "Manage commands:\n"
    printf "  pm2 status\n"
    printf "  pm2 logs %s\n" "$APP_NAME"
    printf "  pm2 restart %s\n" "$APP_NAME"
    printf "  %s\n" "$UPDATE_SCRIPT"
  fi
}

main() {
  require_root
  banner
  collect_inputs

  if [[ "$INSTALL_METHOD" == "docker" ]]; then
    install_docker_mode
  else
    install_pm2_mode
  fi

  if [[ "$CONFIGURE_NGINX" == "true" ]]; then
    write_nginx_config
    install_ssl
  else
    info "Skipping Nginx/Certbot configuration for ${ACCESS_MODE} mode."
  fi

  write_update_script
  enable_update_timer
  print_summary
}

main "$@"
