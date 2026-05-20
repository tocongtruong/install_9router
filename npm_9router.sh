#!/bin/bash
# ============================================================
#  9Router Auto Installer
#  Hỗ trợ: Ubuntu 20.04 / 22.04 / 24.04
#  Cài đặt: Node.js 20, 9Router, PM2, Nginx, SSL (Certbot)
# ============================================================

set -e

# ─── Màu sắc terminal ───────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Helpers ────────────────────────────────────────────────
info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
success() { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; \
            echo -e "${BOLD}${CYAN}  $1${NC}"; \
            echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"; }

# ─── Kiểm tra root ──────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Script cần chạy với quyền root. Hãy dùng: sudo bash $0"
fi

# ─── Banner ─────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ___  ____            _
 / _ \|  _ \ ___  _  _| |_ ___ _ __
| (_) | |_) / _ \| || |  _/ -_) '__|
 \___/|____/\___/ \_,_|\__\___|_|

  Auto Installer — VPS + Domain + SSL
EOF
echo -e "${NC}"

# ─── Thu thập thông tin ─────────────────────────────────────
step "Nhập thông tin cài đặt"

read -rp "$(echo -e "${BOLD}Domain của bạn${NC} (vd: ai.example.com): ")" DOMAIN
[[ -z "$DOMAIN" ]] && error "Domain không được để trống."

read -rp "$(echo -e "${BOLD}Email (dùng cho SSL Certbot)${NC}: ")" EMAIL
[[ -z "$EMAIL" ]] && error "Email không được để trống."

read -rsp "$(echo -e "${BOLD}Mật khẩu đăng nhập Dashboard${NC} (mặc định: 123456): ")" INIT_PASSWORD
echo ""
INIT_PASSWORD="${INIT_PASSWORD:-123456}"

read -rp "$(echo -e "${BOLD}Cài SSL tự động? (y/n)${NC} [y]: ")" INSTALL_SSL
INSTALL_SSL="${INSTALL_SSL:-y}"

read -rp "$(echo -e "${BOLD}Port 9Router${NC} [20128]: ")" APP_PORT
APP_PORT="${APP_PORT:-20128}"

INSTALL_DIR="/opt/9router"
DATA_DIR="/var/lib/9router"

# ─── Tạo secret ngẫu nhiên ──────────────────────────────────
JWT_SECRET=$(openssl rand -hex 32)
API_KEY_SECRET=$(openssl rand -hex 24)
MACHINE_ID_SALT=$(openssl rand -hex 16)

echo ""
echo -e "${BOLD}Xác nhận cài đặt:${NC}"
echo -e "  Domain    : ${GREEN}$DOMAIN${NC}"
echo -e "  Email     : ${GREEN}$EMAIL${NC}"
echo -e "  Port      : ${GREEN}$APP_PORT${NC}"
echo -e "  Cài SSL   : ${GREEN}$INSTALL_SSL${NC}"
echo -e "  Thư mục   : ${GREEN}$INSTALL_DIR${NC}"
echo ""
read -rp "Tiếp tục? (y/n) [y]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && echo "Đã huỷ." && exit 0

# ─── Bước 1: Cập nhật hệ thống ──────────────────────────────
step "1/7 · Cập nhật hệ thống"
apt-get update -qq && apt-get upgrade -y -qq
success "Hệ thống đã cập nhật."

# ─── Bước 2: Cài Node.js 20 ─────────────────────────────────
step "2/7 · Cài Node.js 20"
if node -v 2>/dev/null | grep -q "v2[0-9]"; then
  success "Node.js $(node -v) đã có sẵn, bỏ qua."
else
  info "Đang cài Node.js 20..."
  apt-get install -y -qq curl ca-certificates gnupg
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - > /dev/null 2>&1
  apt-get install -y -qq nodejs
  success "Node.js $(node -v) đã cài xong."
fi

# ─── Bước 3: Cài Git & PM2 ──────────────────────────────────
step "3/7 · Cài Git & PM2"
apt-get install -y -qq git
success "Git $(git --version | awk '{print $3}') sẵn sàng."

if ! command -v pm2 &>/dev/null; then
  npm install -g pm2 --silent
  success "PM2 đã cài xong."
else
  success "PM2 đã có sẵn."
fi

# ─── Bước 4: Clone & Build 9Router ──────────────────────────
step "4/7 · Clone & Build 9Router"

if [[ -d "$INSTALL_DIR" ]]; then
  warn "Thư mục $INSTALL_DIR đã tồn tại → đang cập nhật..."
  cd "$INSTALL_DIR"
  git pull origin master
else
  git clone --depth 1 https://github.com/decolua/9router.git "$INSTALL_DIR"
  cd "$INSTALL_DIR"
fi

info "Đang cài npm dependencies..."
npm install --silent

# Tạo thư mục data
mkdir -p "$DATA_DIR"

# Tạo .env
cat > "$INSTALL_DIR/.env" << EOF
# 9Router Environment — được tạo tự động bởi install-9router.sh
# $(date)

JWT_SECRET="${JWT_SECRET}"
INITIAL_PASSWORD="${INIT_PASSWORD}"
DATA_DIR="${DATA_DIR}"
PORT=${APP_PORT}
HOSTNAME=0.0.0.0
NODE_ENV=production

BASE_URL=https://${DOMAIN}
NEXT_PUBLIC_BASE_URL=https://${DOMAIN}
NEXT_PUBLIC_CLOUD_URL=https://9router.com
CLOUD_URL=https://9router.com

API_KEY_SECRET="${API_KEY_SECRET}"
MACHINE_ID_SALT="${MACHINE_ID_SALT}"

AUTH_COOKIE_SECURE=true
REQUIRE_API_KEY=true
ENABLE_REQUEST_LOGS=false
EOF

info "Đang build production..."
npm run build
success "Build xong!"

# ─── Bước 5: Cài & Khởi động PM2 ────────────────────────────
step "5/7 · Cài dịch vụ PM2"

# Dừng instance cũ nếu có
pm2 delete 9router 2>/dev/null || true

# Tạo ecosystem file
cat > "$INSTALL_DIR/ecosystem.config.js" << EOF
module.exports = {
  apps: [{
    name: '9router',
    script: 'npm',
    args: 'start',
    cwd: '${INSTALL_DIR}',
    env: {
      NODE_ENV: 'production',
      PORT: ${APP_PORT},
      HOSTNAME: '0.0.0.0',
    },
    restart_delay: 3000,
    max_restarts: 10,
    watch: false,
    log_date_format: 'YYYY-MM-DD HH:mm:ss',
  }]
};
EOF

pm2 start "$INSTALL_DIR/ecosystem.config.js"
pm2 save

# Đăng ký khởi động cùng hệ thống
PM2_STARTUP=$(pm2 startup systemd -u root --hp /root 2>&1 | grep "sudo" || true)
if [[ -n "$PM2_STARTUP" ]]; then
  eval "$PM2_STARTUP" > /dev/null 2>&1 || true
fi

success "9Router đang chạy trên port $APP_PORT."

# ─── Bước 6: Cài & Cấu hình Nginx ───────────────────────────
step "6/7 · Cài & Cấu hình Nginx"

apt-get install -y -qq nginx

NGINX_CONF="/etc/nginx/sites-available/9router"

cat > "$NGINX_CONF" << EOF
# 9Router — Nginx config — ${DOMAIN}
# Tạo bởi install-9router.sh lúc $(date)

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Cho Certbot verify (ACME challenge)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # Redirect HTTP → HTTPS (sẽ hoạt động sau khi cài SSL)
    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    # SSL — Certbot sẽ tự điền sau
    # ssl_certificate ...
    # ssl_certificate_key ...

    # Bảo mật header
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Tăng giới hạn upload (cho document/file)
    client_max_body_size 50M;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;

        proxy_set_header Upgrade           \$http_upgrade;
        proxy_set_header Connection        'upgrade';
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass                 \$http_upgrade;

        # Quan trọng: SSE / Streaming
        proxy_buffering         off;
        proxy_read_timeout      3600s;
        proxy_send_timeout      3600s;
        chunked_transfer_encoding on;
    }
}
EOF

# Xoá default site nếu còn
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

# Kích hoạt site
ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/9router

nginx -t && systemctl reload nginx
success "Nginx đã được cấu hình."

# ─── Bước 7: SSL với Certbot ─────────────────────────────────
step "7/7 · Cài SSL (Let's Encrypt)"

if [[ "$INSTALL_SSL" == "y" || "$INSTALL_SSL" == "Y" ]]; then
  apt-get install -y -qq certbot python3-certbot-nginx

  info "Đang cấp chứng chỉ SSL cho $DOMAIN..."
  certbot --nginx \
    -d "$DOMAIN" \
    --email "$EMAIL" \
    --agree-tos \
    --non-interactive \
    --redirect \
    2>&1 | tail -5

  # Gia hạn tự động
  systemctl enable certbot.timer 2>/dev/null || true

  success "SSL đã được cài và sẽ tự gia hạn."
else
  warn "Bỏ qua SSL. Bạn có thể chạy sau: certbot --nginx -d $DOMAIN"
fi

# ─── Hoàn tất ───────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
cat << 'EOF'
  ╔══════════════════════════════════════════╗
  ║        CÀI ĐẶT THÀNH CÔNG! 🎉            ║
  ╚══════════════════════════════════════════╝
EOF
echo -e "${NC}"

echo -e "  ${BOLD}Dashboard:${NC}     https://${DOMAIN}/dashboard"
echo -e "  ${BOLD}API Endpoint:${NC}  https://${DOMAIN}/v1"
echo -e "  ${BOLD}Mật khẩu:${NC}      ${INIT_PASSWORD}"
echo -e "  ${BOLD}Thư mục app:${NC}   ${INSTALL_DIR}"
echo -e "  ${BOLD}Data:${NC}          ${DATA_DIR}"
echo ""
echo -e "  ${YELLOW}Lệnh quản lý PM2:${NC}"
echo -e "    pm2 status           — xem trạng thái"
echo -e "    pm2 logs 9router     — xem log"
echo -e "    pm2 restart 9router  — khởi động lại"
echo ""
echo -e "  ${YELLOW}Lệnh cập nhật 9Router:${NC}"
echo -e "    cd ${INSTALL_DIR} && git pull && npm install && npm run build && pm2 restart 9router"
echo ""
echo -e "  ${CYAN}Nhớ trỏ DNS: A record ${DOMAIN} → $(curl -s ifconfig.me 2>/dev/null || echo 'IP_VPS')${NC}"
echo ""
