FROM openresty/openresty:jammy

# Install nginx-lua-prometheus (api7 fork with TTL support)
RUN luarocks install nginx-lua-prometheus

# Copy certs and config
COPY certs/server.crt /etc/nginx/certs/server.crt
COPY certs/server.key /etc/nginx/certs/server.key
COPY openresty-conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# custom-plugins will be mounted as a volume at runtime
EXPOSE 443 9092

CMD ["openresty", "-g", "daemon off;"]
