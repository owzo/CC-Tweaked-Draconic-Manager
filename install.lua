-- Installation Script
-- Save as: install.lua

local files = {
    "config.lua",
    "main_control.lua",
    "reac_utils.lua",
    "monitor_utils.lua",
    "stat_utils.lua",
    "energy_core_utils.lua",
}

local baseUrl = "https://raw.githubusercontent.com/owzo/CC-Tweaked-Draconic-Manager/main/"

for _, file in ipairs(files) do
    local url = baseUrl .. file
    local content = http.get(url)

    if content then
        local handle = fs.open(file, "w")
        handle.write(content.readAll())
        handle.close()
        content.close()
        print("Downloaded: " .. file)
    else
        print("Failed to download: " .. file)
    end
end

print("Installation complete. Run 'main_control.lua' to start the program.")
