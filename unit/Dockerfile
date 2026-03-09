FROM openresty/openresty:jammy

RUN apt-get update && apt-get install -y --no-install-recommends \
        luarocks \
    && rm -rf /var/lib/apt/lists/* \
    && luarocks install busted

WORKDIR /tests

# Copy Lua source and specs
COPY lua/ /tests/lua/
COPY spec/ /tests/spec/

# busted needs the lua source on the path
ENV LUA_PATH="/tests/lua/?.lua;/tests/?.lua;;"

CMD ["busted", "--verbose", "spec/"]
