--[[
    Oracle // Engine Probe — Loader
    Place this LocalScript in StarterPlayerScripts (or run via executor).
    Fetches each chunk from GitHub and executes them in order,
    passing a shared table G so all chunks share the same namespace.
--]]

local G    = {}
local Http = game:GetService("HttpService")
local BASE = "https://raw.githubusercontent.com/E7neverBl4Te/oracle/main/"

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
        local src    = Http:GetAsync(BASE .. name)
        local fn, pe = loadstring(src)
        assert(fn, "Parse error in " .. name .. ": " .. tostring(pe))
        fn(G)
    end)
    if not ok then
        warn("[Oracle] Failed on " .. name .. " — " .. tostring(err))
        return
    end
end
