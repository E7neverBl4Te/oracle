--[[
    Oracle // Engine Probe — Loader
    Paste into your executor and run.
    Uses executor HTTP (not HttpService — that's client-blocked).
--]]

local G    = {}
local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/oracle/main/"

-- Cross-executor HTTP GET
local function httpGet(url)
    if syn and syn.request then
        return syn.request({Url=url, Method="GET"}).Body
    elseif http_request then
        return http_request({Url=url, Method="GET"}).Body
    elseif request then
        return request({Url=url, Method="GET"}).Body
    elseif (fluxus and fluxus.request) then
        return fluxus.request({Url=url, Method="GET"}).Body
    end
    error("No HTTP function found — executor may not support HTTP requests")
end

local CHUNKS = {
    "01_core.lua",
    "02_oracle.lua",
    "03_dashboard.lua",
    "04_target.lua",
    "05_compose.lua",
    "06_init.lua",
}

for _, name in ipairs(CHUNKS) do
    local ok, err = pcall(function()
        local src    = httpGet(BASE .. name)
        local fn, pe = loadstring(src)
        assert(fn, "Parse error in " .. name .. ": " .. tostring(pe))
        fn(G)
    end)
    if not ok then
        warn("[Oracle] Failed on " .. name .. " — " .. tostring(err))
        return
    end
end
