-- Example APISIX plugin shim
-- Place this file at: apisix/plugins/tls-clienthello-limiter.lua
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
