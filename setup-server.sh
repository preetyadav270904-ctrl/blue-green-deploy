#!/usr/bin/env bash

set -euo pipefail

echo "=================================================="
echo "Configuring Amazon Linux 2023 Server Environment"
echo "=================================================="

# Update package repository and install Docker, Git, Nginx
sudo dnf update -y
sudo dnf install -y docker git nginx

sudo systemctl enable --now docker

sudo usermod -aG docker "$USER"

DOCKER_CONFIG=${DOCKER_CONFIG:-/usr/local/lib/docker}
sudo mkdir -p "$DOCKER_CONFIG/cli-plugins"
sudo curl -SL https://github.com/docker/compose/releases/download/v2.24.5/docker-compose-linux-$(uname -m) -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
sudo chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"

sudo mkdir -p /etc/nginx/conf.d
sudo chown -R "$USER:$USER" /etc/nginx/conf.d

cat << 'EOF' > /etc/nginx/conf.d/active_upstream.conf
server 127.0.0.1:8081 max_fails=3 fail_timeout=10s;
EOF

# Configure Nginx reverse proxy
cat << 'EOF' | sudo tee /etc/nginx/conf.d/blue_green.conf > /dev/null
upstream backend_nodes {
    include /etc/nginx/conf.d/active_upstream.conf;
}

server {
    listen 80 default_server;
    server_name _;

    location / {
        proxy_pass http://backend_nodes;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_connect_timeout 2s;
        proxy_read_timeout 5s;
    }
}
EOF

# Validate Nginx configuration and start service
sudo nginx -t
sudo systemctl enable --now nginx

echo "=================================================="
echo "Host setup complete! Log out and log back in to apply docker group permissions."
echo "=================================================="
