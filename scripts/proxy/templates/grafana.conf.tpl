# HTTP redirect to HTTPS
server {
  listen 80;
  listen [::]:80;
  server_name __GRAFANA_DOMAIN__;

  return 301 https://$host$request_uri;
}

# HTTPS vhost
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name __GRAFANA_DOMAIN__;

  ssl_certificate     /etc/letsencrypt/live/__GRAFANA_DOMAIN__/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/__GRAFANA_DOMAIN__/privkey.pem;

  # Security headers (basic)
  add_header X-Frame-Options DENY always;
  add_header X-Content-Type-Options nosniff always;
  add_header X-XSS-Protection "1; mode=block" always;

  # Proxy to local grafana
  location / {
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;

    proxy_pass http://127.0.0.1:__GRAFANA_PORT__;
    proxy_read_timeout  60s;
    proxy_send_timeout  60s;
  }
}
