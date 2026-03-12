FROM openresty/openresty:jammy

COPY lib/ /usr/local/openresty/site/lualib/
COPY bench/ /bench/

WORKDIR /bench
ENTRYPOINT ["resty", "jit_trace.lua"]
