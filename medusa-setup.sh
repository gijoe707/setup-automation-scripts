#!/bin/bash

echo "==== STEP 1: Install Node.js 20 & PM2 ===="
curl -sL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs build-essential
sudo npm install -g pm2

echo "==== STEP 2: Install PostgreSQL ===="
sudo apt-get update
sudo apt-get install -y postgresql postgresql-contrib

echo "==== STEP 3: Modify pg_hba.conf (peer → md5) ===="
PG_HBA=$(sudo find /etc/postgresql -name pg_hba.conf)

sudo sed -i 's/peer/md5/g' $PG_HBA
sudo sed -i 's/trust/md5/g' $PG_HBA

echo "Restarting PostgreSQL..."
sudo systemctl restart postgresql

echo "==== STEP 4: Create PostgreSQL user & DB for Medusa ===="
read -p "Enter Medusa DB Username: " DB_USER
read -p "Enter Medusa DB Password: " DB_PASS
read -p "Enter Medusa Database Name: " DB_NAME

sudo -u postgres psql <<EOF
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS' CREATEDB;
CREATE DATABASE $DB_NAME OWNER $DB_USER;
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
\c $DB_NAME
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;
EOF

echo "==== STEP 5: Create Medusa project ===="
mkdir -p /var/www/medusa
cd /var/www/medusa
npx create-medusa-app@latest .

echo "==== STEP 6: Configure Medusa CORS for domain ===="
read -p "Enter your domain (example: api.domain.com): " DOMAIN

sed -i "s|localhost:7001|$DOMAIN|g" medusa-config.js
sed -i "s|127.0.0.1|0.0.0.0|g" medusa-config.js

echo "==== STEP 7: Inject database ENV variables ===="
cat <<EOT > .env
DATABASE_URL=postgres://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME
ADMIN_ONBOARDING=true
JWT_SECRET=$(openssl rand -hex 16)
COOKIE_SECRET=$(openssl rand -hex 16)
EOT

echo "==== STEP 8: Install dependencies ===="
npm install

echo "==== STEP 9: Build Medusa for production ===="
npm run build

echo "==== STEP 10: Start Medusa with PM2 ===="
pm2 start "npm run start" --name medusa
pm2 save
pm2 startup systemd -u $USER --hp $HOME

echo "==== SETUP COMPLETE ===="
echo "Medusa API is now running at: http://$DOMAIN"
echo "Use 'pm2 logs medusa' to monitor."
