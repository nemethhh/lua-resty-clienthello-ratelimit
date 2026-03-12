package = "lua-resty-clienthello-ratelimit"
version = "0.2.0-1"

source = {
    url = "git+https://github.com/nemethhh/lua-resty-clienthello-ratelimit.git",
    tag = "v0.2.0",
}

description = {
    summary = "Three-tier TLS ClientHello rate limiter for OpenResty and APISIX",
    detailed = [[
        Rate limits TLS ClientHello requests using a three-tier approach:
        IP blocklist (T0), per-IP leaky bucket (T1), and per-SNI leaky bucket (T2).
        Ships with adapters for vanilla OpenResty and Apache APISIX.
    ]],
    homepage = "https://github.com/nemethhh/lua-resty-clienthello-ratelimit",
    license = "MIT",
}

dependencies = {
    "lua >= 5.1",
}

build = {
    type = "builtin",
    modules = {
        ["resty.clienthello.ratelimit"]            = "lib/resty/clienthello/ratelimit/init.lua",
        ["resty.clienthello.ratelimit.config"]     = "lib/resty/clienthello/ratelimit/config.lua",
        ["resty.clienthello.ratelimit.openresty"]  = "lib/resty/clienthello/ratelimit/openresty.lua",
        ["resty.clienthello.ratelimit.apisix"]     = "lib/resty/clienthello/ratelimit/apisix.lua",
    },
}
