-- Shim: APISIX plugin loader expects apisix.plugins.<name>
-- Delegates to the actual adapter module
return require("tls-clienthello-limiter.adapters.apisix")
