FROM openresty/openresty:jammy

RUN luarocks install nginx-lua-prometheus

COPY lib/ /usr/local/openresty/lualib/

COPY t/integration/certs/server.crt /etc/nginx/certs/server.crt
COPY t/integration/certs/server.key /etc/nginx/certs/server.key
COPY t/openresty-integration/conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

EXPOSE 443 9092
CMD ["openresty", "-g", "daemon off;"]
