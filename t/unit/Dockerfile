FROM openresty/openresty:jammy

RUN luarocks install busted

COPY . /src
WORKDIR /src/t/unit
ENV LUA_PATH="/src/lib/?.lua;/src/lib/?/init.lua;;"
CMD ["busted", "--verbose", "spec/"]
