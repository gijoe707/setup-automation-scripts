#!/usr/bin/env bash
set -euo pipefail

########################
# CONFIG - edit if needed
########################
# Domain where Vendure will be served (for Nginx)
DOMAIN="${DOMAIN:-vendure.example.com}"

# PostgreSQL credentials
PG_DB="${PG_DB:-vendure}"
PG_USER="${PG_USER:-vendure}"
PG_PASS="${PG_PASS:-VendureP@ssw0rd!}"

# Vendure project dir
APP_DIR="${APP_DIR:-/var/www/vendure-demo}"

# Vendure superadmin (the demo repo has populate script; we pass envs)
SUPERADMIN_EMAIL="${SUPERADMIN_EMAIL:-superadmin@example.com}"
SUPERADMIN_PASSWORD="${SUPERADMIN_PASSWORD:-superadmin}"

# Node version (set to 20 by default; change to 18 if you prefer)
NODE_VERSION="${NODE_VERSION:-20}"

# pm2 (process manager) user
RUN_AS_USER="${RUN_AS_USER:-$SUDO_USER}"
RUN_AS_USER="${RUN_AS_USER:-$(whoami)}"

########################
# Helpers
########################
info(){ echo -e "\n\033[1;34m==>\033[0m $*\n"; }
err(){ echo -e "\n\033[1;31mERROR:\033[0m $*\n" >&2; }

if [ "$(id -u)" -ne 0 ]; then
  err "Please run as root (sudo)."
  exit 1
fi

########################
# 1) Basic packages
########################
info "Updating apt and installing base packages..."
apt-get update -y
apt-get install -y curl wget git build-essential apt-transport-https ca-certificates gnupg lsb-release unzip

########################
# 2) Install Node.js
########################
info "Installing Node.js ${NODE_VERSION}..."
# nodesource installer
curl -sL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" -o /tmp/nodesource_setup.sh
bash /tmp/nodesource_setup.sh
apt-get install -y nodejs
node -v || { err "Node installation failed"; exit 1; }
npm -v

# install pm2 globally
npm install -g pm2@latest
pm2 -v || true

########################
# 3) Install PostgreSQL
########################
info "Installing PostgreSQL..."
apt-get install -y postgresql postgresql-contrib

# ensure pg_hba.conf uses md5 (password auth) for local connections
PG_HBA_FILE=$(find /etc/postgresql -type f -name pg_hba.conf | head -n1)
if [ -z "$PG_HBA_FILE" ]; then
  err "Could not find pg_hba.conf"
  exit 1
fi

info "Configuring PostgreSQL auth (pg_hba.conf -> md5) at ${PG_HBA_FILE}"
# replace peer/trust with md5 for local connections
sed -i.bak -E 's/^(local\s+all\s+all\s+)(peer|trust)/\1md5/' "$PG_HBA_FILE" || true
sed -i.bak -E 's/^(host\s+all\s+all\s+127\.0\.0\.1\/32\s+)(peer|trust)/\1md5/' "$PG_HBA_FILE" || true
sed -i.bak -E 's/^(host\s+all\s+all\s+::1\/128\s+)(peer|trust)/\1md5/' "$PG_HBA_FILE" || true

info "Restarting PostgreSQL..."
systemctl restart postgresql

# create DB & user (idempotent)
info "Creating PostgreSQL user and database..."
sudo -u postgres psql -v ON_ERROR_STOP=1 <<SQL
DO
\$do\$
BEGIN
   IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${PG_USER}') THEN
      CREATE ROLE ${PG_USER} LOGIN PASSWORD '${PG_PASS}';
   END IF;
END
\$do\$;
CREATE DATABASE ${PG_DB} WITH OWNER = ${PG_USER};
GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};
-- ensure privileges on future tables
\c ${PG_DB}
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${PG_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${PG_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${PG_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${PG_USER};
SQL

########################
# 4) Install Redis
########################
info "Installing Redis..."
apt-get install -y redis-server
systemctl enable --now redis-server

########################
# 5) Clone Vendure demo
########################
info "Cloning Vendure demo into ${APP_DIR}..."
if [ -d "$APP_DIR" ] && [ -f "$APP_DIR/package.json" ]; then
  info "Existing directory looks like a project. Skipping clone."
else
  rm -rf "${APP_DIR}"
  git clone https://github.com/vendure-ecommerce/vendure-demo.git "${APP_DIR}"
fi

cd "${APP_DIR}"

########################
# 6) Environment
########################
info "Writing .env (database & redis & admin credentials)..."
cat > .env <<EOF
DATABASE_TYPE=postgres
DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=${PG_USER}
DB_PASSWORD=${PG_PASS}
DB_DATABASE=${PG_DB}

REDIS_URL=redis://localhost:6379

ADMIN_API_PATH=/admin
SHOP_API_PATH=/shop-api

# vendure demo may include a populate script which uses these
SUPERADMIN_USERNAME=superadmin
SUPERADMIN_PASSWORD=${SUPERADMIN_PASSWORD}
SUPERADMIN_EMAIL=${SUPERADMIN_EMAIL}

APP_PORT=3000
APP_HOST=0.0.0.0
EOF

########################
# 7) Install deps & build
########################
info "Installing Node dependencies (this may take several minutes)..."
# use npm ci if package-lock exists, otherwise npm install
if [ -f package-lock.json ]; then
  npm ci --no-audit --no-fund
else
  npm install --no-audit --no-fund
fi

# build vendure (the demo project defines build/start scripts)
info "Building project..."
npm run build || info "Build may have warnings; continuing."

########################
# 8) Run DB migrations & populate (demo)
########################
info "Running migrations / populate (if available)..."
# Many Vendure demos include scripts like "populate" or "setup". We'll attempt populate if present.
if npm run | grep -q populate; then
  info "Running npm run populate (demo data)..."
  npm run populate || info "Populate script failed or partly succeeded; check logs."
else
  info "No populate script found; proceed without sample data."
fi

########################
# 9) Start Vendure via pm2
########################
info "Starting Vendure with pm2 (app name: vendure-server)..."
# create a pm2 ecosystem file (to ensure restart on reboot)
cat > ecosystem.config.js <<'EOM'
module.exports = {
  apps: [
    {
      name: "vendure-server",
      script: "node",
      args: "dist/index-server.js",
      env: {
        NODE_ENV: "production",
        PORT: process.env.APP_PORT || 3000,
        HOST: process.env.APP_HOST || "0.0.0.0"
      }
    },
    {
      name: "vendure-worker",
      script: "node",
      args: "dist/index-worker.js",
      env: {
        NODE_ENV: "production",
      }
    }
  ]
}
EOM

# start or restart
pm2 describe vendure-server >/dev/null 2>&1 && pm2 delete vendure-server || true
pm2 start ecosystem.config.js
pm2 save
pm2 startup systemd -u "${RUN_AS_USER}" --hp "/home/${RUN_AS_USER}" || true

########################
# 10) Nginx reverse proxy (HTTP)
########################
info "Configuring Nginx reverse proxy for ${DOMAIN} (HTTP)."
apt-get install -y nginx

NGINX_CONF="/etc/nginx/sites-available/vendure"
cat > "${NGINX_CONF}" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /admin/ {
        proxy_pass http://127.0.0.1:3000/admin/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        proxy_pass http://127.0.0.1:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

ln -sf "${NGINX_CONF}" /etc/nginx/sites-enabled/vendure
nginx -t && systemctl reload nginx

########################
# 11) Final output & verification
########################
info "Setup complete. Verifying services..."

sleep 2
systemctl is-active --quiet postgresql && echo "postgresql: running" || echo "postgresql: not running"
systemctl is-active --quiet redis-server && echo "redis: running" || echo "redis: not running"
pm2 show vendure-server >/dev/null 2>&1 && echo "pm2 vendure-server: running" || echo "pm2 vendure-server: not running"

echo
echo "Visit: http://${DOMAIN}/admin (or http://<server-ip>:3000/admin if DNS not set)"
echo "Vendure server is running on http://127.0.0.1:3000 (proxied by nginx at /)"
echo "Superadmin credentials:"
echo "  username: superadmin"
echo "  email: ${SUPERADMIN_EMAIL}"
echo "  password: ${SUPERADMIN_PASSWORD}"
echo
echo "To view logs: pm2 logs vendure-server"
echo "To stop: pm2 stop vendure-server    To restart: pm2 restart vendure-server"
echo
echo "If you want HTTPS, run:"
echo "  sudo apt install certbot python3-certbot-nginx"
echo "  sudo certbot --nginx -d ${DOMAIN}"
echo
info "Done."
