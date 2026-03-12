-- Shim: APISIX plugin loader expects apisix.plugins.<name>
-- Delegates to the LuaRocks-installed adapter module
local adapter = require("resty.clienthello.ratelimit.apisix")
return adapter
