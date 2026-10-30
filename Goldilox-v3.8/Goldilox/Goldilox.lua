addon.name      = 'Goldilox'
addon.author    = 'Dewin (UI rewrite)'
addon.version   = '3.8'
addon.desc      = 'Keeps track of Goblin dailies.  Exclusively for CatsEye XI.'
addon.link      = 'https://github.com/dewiniaid/ffxi-ashita-goldilox'

--[[
    Goldilox 3.5
    Based on Goldilox 1.0 by Dewin (MIT licensed, see LICENSE.md).  The Sea (Palalumin) section follows the chat
    formats used by seekey13's Goldilox-UI (MIT); no code was copied from it.

    What changed from 1.0:
      * The status display is a frameless card in the same look as YunaUI: dark violet panel, thin violet edge, a
        pink-to-violet line along the top, thin progress bars.  The card can be dragged and remembers where you put it.
      * Chat parsing no longer cares which chat mode a line arrives in (VanaCore may not send NPC dialogue under the
        mode number the original expected).  Goblin lines are recognized by what they say.
      * The old chat report is still there as `/goldilox chat`.
    This addon does not copy any code from YunaUI; only the colors and general look are imitated.
]]

require('common')
local chat     = require('chat')
local settings = require('settings')

-- ImGui is optional so the tracker keeps working without it.
local imgui_ok, imgui = pcall(require, 'imgui')

----------------------------------------------------------------------------------------------------
-- UI state (declared early: saved-state code below resets some of it)
----------------------------------------------------------------------------------------------------
local ui = {
    open        = true,   -- Window visible?
    last_check  = 0,
    error_seen  = false,
    pos_applied = false,  -- Has the saved window position been applied yet this session / character?
    save_at     = nil,    -- When to write a moved window position to disk (debounced).
    font        = nil,
    font_sized  = nil,    -- Does this ImGui push fonts at any size (VanaCore's) or only as loaded?
    printing    = false,  -- True while the addon prints to chat, so it never parses its own output.
}

local function say_chat(text)
    ui.printing = true
    print(text)
    ui.printing = false
end

local function trim(s)
    return (string.match(s, '^%s*(.-)%s*$'))
end

----------------------------------------------------------------------------------------------------
-- Saved state
----------------------------------------------------------------------------------------------------
local STATUS_VERSION = 1           -- Nuke all stored data if version mismatches.
local JST_OFFSET     = 60 * 60 * 9 -- JST is 9 hours ahead of UTC.  Used to find Japanese midnight.

local default_status = T{
    deadline      = 0,              -- Deadline to complete current dailies.  Reset all data if deadline passes.
    version       = STATUS_VERSION,
    goldilox_time = 0,              -- Equals `deadline` once today's Goldilox reward has been collected.
    dailies       = {},             -- Storage for goblin dailies.
    sea           = {},             -- Storage for Palalumin's (Sea) dailies.
    ui            = { x = 120, y = 160, mini = false, min = false, w = 380, clear = false, scale = 1 },  -- Position, mini size, minimized, width, transparent.
}

local status               = nil
local current_character_id = nil    -- Detect character changes

local function get_deadline()
    -- Floor time down to nearest JST day, then add one day.
    return 86400 + (math.floor((os.time() + JST_OFFSET) / 86400) * 86400) - JST_OFFSET
end

-- Loads (or reloads) saved state.  Returns true if state is available.
local function update_status()
    local new_character_id = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)
    if new_character_id == 0 then
        return status ~= nil  -- Not in game yet.  Don't create settings for a nonexistent character.
    end
    if (status == nil) or (new_character_id ~= current_character_id) then
        status = settings.load(default_status)
        current_character_id = new_character_id
        ui.pos_applied = false
        ui.mini = (status.ui ~= nil and status.ui.mini) and true or false
        ui.min  = (status.ui ~= nil and status.ui.min) and true or false
        ui.w    = status.ui and tonumber(status.ui.w) or nil
        ui.clear = (status.ui ~= nil and status.ui.clear) and true or false
        ui.scale = status.ui and tonumber(status.ui.scale) or 1
    end

    local deadline = get_deadline()
    if status.version ~= STATUS_VERSION then
        status.version = STATUS_VERSION
        status.dailies = {}
        status.sea = {}
        status.deadline = deadline
        status.goldilox_time = 0
        settings.save()
    elseif status.deadline ~= deadline then
        status.dailies = {}
        status.sea = {}
        status.deadline = deadline
        settings.save()
    end
    if status.dailies == nil then
        status.dailies = {}
    end
    if status.sea == nil then
        status.sea = {}  -- (saved by a version from before the Sea section)
    end
    return true
end

----------------------------------------------------------------------------------------------------
-- Goblin definitions
----------------------------------------------------------------------------------------------------
--[[
    Dialogue examples:
        Fishstix : Go to Yughott Grotto, find and open my Secret Treasure Chest!
        Murdox : Go to Bhaflau Thickets and kill 20 Treants!
        Mistrix : Craft me up a signed serving of goblin stir-fry and trade it to me!
        Saltlix : Go to Dangruf Wadi and kill Teporingo!
        Beetrix : Go to Gusgen Mines, get a Gusgen Clay and trade it to me!

    talk(data, prev)  parses the NPC's dialogue into `data`.  `prev` is today's earlier entry for that NPC, if any.
    describe(data)    returns task text, an optional location, and an optional link { label, query, kind } (the label
                      is the NM / item name as it appears in the task text; query is what the database is searched
                      for), or nil if parsing failed.
    progress(data)    (optional) returns killed, total.
]]
local goblin_order = { 'Fishstix', 'Murdox', 'Mistrix', 'Saltlix', 'Beetrix' }

local handlers = {
    Fishstix = {
        talk = function(data, prev)
            data.zone = string.match(data.message, 'Go to (.-),')
        end,
        describe = function(data)
            if data.zone then
                return 'Find and open the secret treasure chest', data.zone
            end
        end,
    },
    Murdox = {
        talk = function(data, prev)
            data.zone, data.count, data.target = string.match(data.message, 'Go to (.+) and kill (%d+) (.+)!')
            if (prev and prev.message == data.message) then
                data.remaining = prev.remaining
                data.mob = prev.mob
            end
        end,
        describe = function(data)
            if data.count and data.target then
                local how_many = data.remaining and (data.remaining .. ' more') or data.count
                -- The dialogue says "Treants" but the database only knows "Olden Treant": prefer the exact name from the
                -- "kills remain" line, else drop the plural.
                local query = data.mob
                if not query then
                    query = data.target
                    if tonumber(data.count) ~= 1 then
                        query = string.gsub(query, 's$', '')
                    end
                end
                return ('Kill %s %s'):format(how_many, data.target), data.zone,
                    { label = data.target, query = query, kind = 'mob' }
            end
        end,
        progress = function(data)
            local total = tonumber(data.count)
            if not total or total <= 0 then
                return nil
            end
            local left = tonumber(data.remaining) or total
            return math.max(0, math.min(total, total - left)), total
        end,
    },
    Mistrix = {
        talk = function(data, prev)
            data.item = string.match(data.message, 'Craft me up %a+ signed (.+) and trade it to me!')
        end,
        describe = function(data)
            if data.item then
                local name = (string.gsub(data.item, '^[Ss]erving of ', ''))  -- "serving of goblin stir-fry" -> the item
                return 'Craft a signed one and trade it to Mistrix', nil, nil, { { name = name, count = 1 } }
            end
        end,
    },
    Saltlix = {
        talk = function(data, prev)
            data.zone, data.target = string.match(data.message, 'Go to (.+) and kill (.+)!')
        end,
        describe = function(data)
            if data.target then
                return 'Kill ' .. data.target, data.zone, { label = data.target, query = data.target, kind = 'mob' }
            end
        end,
        progress = function(data)
            return 0, 1  -- One NM: the counter shows 0 / 1 until the kill message turns it into "return".
        end,
    },
    Beetrix = {
        talk = function(data, prev)
            data.zone, data.item = string.match(data.message, 'Go to (.+), get %a+ (.+) and trade it to me!')
        end,
        describe = function(data)
            if data.item then
                return 'Get it and trade it to Beetrix', data.zone, nil, { { name = data.item, count = 1 } }
            end
        end,
    },
}

----------------------------------------------------------------------------------------------------
-- Turning saved state into something displayable
----------------------------------------------------------------------------------------------------
-- States: 'new' (not talked to), 'active', 'return' (ready to turn in), 'done'
local tags = {
    new        = 'NOT STARTED',
    active     = 'IN PROGRESS',
    ['return'] = 'TURN IN',
    done       = 'DONE',
}

local function describe(npc)
    local daily = status and status.dailies[npc]
    if daily == nil then
        return { state = 'new', task = 'Talk to ' .. npc .. ' in Lower Jeuno' }
    elseif daily.status == 'complete' then
        return { state = 'done', task = 'Completed for today' }
    elseif daily.status == 'return' then
        return { state = 'return', task = 'Return to ' .. npc .. ' to claim your reward' }
    end

    local handler = handlers[npc]
    local task, where, link, items = nil, nil, nil, nil
    if handler and handler.describe then
        task, where, link, items = handler.describe(daily)
    end
    local result = { state = 'active', task = task or daily.message or '?', where = where, link = link, items = items }
    if handler and handler.progress then
        local killed, total = handler.progress(daily)
        if killed then
            result.killed, result.total = killed, total
        end
    end
    return result
end

----------------------------------------------------------------------------------------------------
-- Sea dailies: Palalumin, Grand Palace of Hu'Xzoi
----------------------------------------------------------------------------------------------------
--[[
    Talking to Palalumin lists his three dailies, one chat line each, with a diamond in front (open for unfinished,
    filled for finished):
        <open diamond> Find flux: <where>
        <open diamond> Item request: <Item> x<N>, <Item> x<N>
        <open diamond> Defeat mobs: <Mob> (<Zone>) <killed>/<total>
    Kill progress then arrives as "Defeat Mobs 1/10 (Zdei in Grand Palace of HuXzoi)", and finishing a quest prints
    "Quest Completed".  (These formats were taken from seekey13's Goldilox-UI, MIT licensed; the code here is new.)
]]
local sea_order = { 'Find flux', 'Item request', 'Defeat mobs' }  -- The order he lists them in
local SEA_KEYS  = { ['find flux'] = 'Find flux', ['item request'] = 'Item request', ['defeat mobs'] = 'Defeat mobs' }
local SEA_TITLE = { ['Find flux'] = 'Find the Flux', ['Item request'] = 'Item request', ['Defeat mobs'] = 'Defeat mobs' }

-- "Ancient Beastcoin x3, Cosmo-Coin" -> { { name = 'Ancient Beastcoin', count = 3 }, { name = 'Cosmo-Coin', count = 1 } }
local function parse_items(text)
    local items = {}
    for entry in string.gmatch(text, '([^,]+)') do
        entry = trim(entry)
        local name, count = string.match(entry, '^(.-)%s+x(%d+)$')
        if name then
            items[#items + 1] = { name = name, count = tonumber(count) }
        elseif entry ~= '' then
            items[#items + 1] = { name = entry, count = 1 }
        end
    end
    return items
end

local sea_handlers = {
    ['Find flux'] = {
        talk = function(data)
            data.zone = data.message
        end,
    },
    ['Item request'] = {
        talk = function(data)
            data.items = parse_items(data.message)
        end,
    },
    ['Defeat mobs'] = {
        talk = function(data)
            if data.completed then
                return
            end
            local target, zone, killed, total = string.match(data.message, '(.+)%s+%((.+)%)%s+(%d+)/(%d+)')
            if target then
                data.target, data.zone = target, zone
                data.killed, data.total = tonumber(killed), tonumber(total)
            end
        end,
    },
}

-- Same shape as describe(), plus `title` (the row heading) and `items` (for the item request); nil if not talked to.
local function describe_sea(key)
    local q = status and status.sea and status.sea[key]
    if q == nil then
        return nil
    end
    local title = SEA_TITLE[key]
    if q.completed then
        return { state = 'done', title = title, task = 'Completed for today' }
    end

    if key == 'Find flux' then
        return { state = 'active', title = title, task = 'Find the Flux', where = q.zone }
    elseif key == 'Item request' then
        if q.items and #q.items > 0 then
            return { state = 'active', title = title, task = 'Trade these items', items = q.items }
        end
        local text = (q.message and q.message ~= '') and q.message or 'the requested items'
        return { state = 'active', title = title, task = 'Trade ' .. text }
    end

    -- Defeat mobs
    if q.total and q.killed then
        if q.killed >= q.total then
            return { state = 'return', title = title, task = 'Return to Palalumin to claim your reward' }
        end
        local d = {
            state = 'active', title = title, where = q.zone, killed = math.max(0, q.killed), total = q.total,
            task = q.target and ('Kill ' .. q.target) or 'Defeat the mobs',
        }
        if q.target then
            d.link = { label = q.target, query = q.target, kind = 'mob' }
        end
        return d
    end
    return { state = 'active', title = title, task = (q.message and q.message ~= '') and q.message or 'Defeat the mobs' }
end

----------------------------------------------------------------------------------------------------
-- Inventory: how many of each requested item you are carrying (main bag; only that can be traded)
----------------------------------------------------------------------------------------------------
local INV_CONTAINERS = { 0 }
local inv = { at = -10, ok = false, names = {}, counts = {} }

local function scan_inventory(force)
    local now = os.clock()
    if not force and now - inv.at < 1 then
        return
    end
    inv.at = now
    local ok = pcall(function()
        local inventory = AshitaCore:GetMemoryManager():GetInventory()
        local res = AshitaCore:GetResourceManager()
        local counts = {}
        for _, c in ipairs(INV_CONTAINERS) do
            for i = 0, inventory:GetContainerCountMax(c) do
                local it = inventory:GetContainerItem(c, i)
                local id = it and it.Id
                if id and id ~= 0 and id ~= 65535 then
                    local name = inv.names[id]
                    if name == nil then
                        local r = res:GetItemById(id)
                        local n = r and r.Name and (r.Name[1] or r.Name[0])
                        name = (type(n) == 'string' and n ~= '') and string.lower(n) or false
                        inv.names[id] = name
                    end
                    if name then
                        counts[name] = (counts[name] or 0) + (tonumber(it.Count) or 1)
                    end
                end
            end
        end
        inv.counts = counts
    end)
    inv.ok = ok
end

-- How many of `name` are in the bag.  An exact (case-insensitive) match wins; otherwise a name that contains the other
-- one counts (so "serving of goblin stir-fry" still finds "Goblin Stir-fry").
local function have_count(name)
    local key = string.lower(name or '')
    local exact = inv.counts[key]
    if exact then
        return exact
    end
    local sum = 0
    if #key >= 4 then
        for k, v in pairs(inv.counts) do
            if #k >= 4 and (string.find(k, key, 1, true) or string.find(key, k, 1, true)) then
                sum = sum + v
            end
        end
    end
    return sum
end

-- "Ancient Beastcoin 2/3, Cosmo-Coin 0/1" for the chat report.
local function items_text(items)
    local parts = {}
    for _, it in ipairs(items) do
        if inv.ok then
            parts[#parts + 1] = ('%s %d/%d'):format(it.name, have_count(it.name), it.count)
        else
            parts[#parts + 1] = ('%s x%d'):format(it.name, it.count)
        end
    end
    return table.concat(parts, ', ')
end

----------------------------------------------------------------------------------------------------
-- Chat report (the original 1.0 output)
----------------------------------------------------------------------------------------------------
local function print_report()
    scan_inventory(true)
    if not update_status() then
        say_chat(chat.header(addon.name) .. 'Character data is not available yet.')
        return
    end
    local completed = 0
    for _, npc in ipairs(goblin_order) do
        local d = describe(npc)
        local preamble = chat.header(addon.name) .. npc .. ': '
        if d.state == 'new' then
            say_chat(preamble .. chat.color1(68, 'Not talked to today.'))
        elseif d.state == 'done' then
            say_chat(preamble .. chat.color1(72, 'Complete!'))
            completed = completed + 1
        elseif d.state == 'return' then
            say_chat(preamble .. chat.color1(2, 'Return to ' .. npc .. '.'))
        else
            local line = d.task
            if d.items then
                line = line .. ': ' .. items_text(d.items)
            end
            if d.where then
                line = line .. ' at ' .. d.where
            end
            if d.total then
                line = line .. ' ' .. chat.color1(6, ('(%d/%d)'):format(d.killed, d.total))
            end
            say_chat(preamble .. line)
        end
    end
    if completed > 0 then
        local preamble = chat.header(addon.name) .. 'Goldilox: '
        if status.goldilox_time == status.deadline then
            say_chat(preamble .. chat.color1(72, 'Complete!'))
        else
            say_chat(preamble .. chat.color1(68, 'Reward not collected.'))
        end
    end

    local first = true
    for _, key in ipairs(sea_order) do
        local d = describe_sea(key)
        if d then
            if first then
                say_chat(chat.header(addon.name) .. 'Sea (Palalumin):')
                first = false
            end
            local preamble = chat.header(addon.name) .. d.title .. ': '
            if d.state == 'done' then
                say_chat(preamble .. chat.color1(72, 'Complete!'))
            elseif d.state == 'return' then
                say_chat(preamble .. chat.color1(2, 'Return to Palalumin.'))
            else
                local line = d.task
                if d.items then
                    line = line .. ': ' .. items_text(d.items)
                end
                if d.where then
                    line = line .. ' at ' .. d.where
                end
                if d.total then
                    line = line .. ' ' .. chat.color1(6, ('(%d/%d)'):format(d.killed, d.total))
                end
                say_chat(preamble .. line)
            end
        end
    end
end

----------------------------------------------------------------------------------------------------
-- The window: a frameless card, drawn by hand
----------------------------------------------------------------------------------------------------
-- Palette: the dark violet card, violet edge and pink-to-violet accent line YunaUI uses.
local COL = {
    bg         = { 0.068, 0.066, 0.088, 0.94 },   -- near-black with a hint of violet (YunaUI's settings panel)
    edge       = { 0.62, 0.40, 1.00, 0.55 },
    neon       = { 0.86, 0.24, 0.86, 1.00 },      -- bar gradient: magenta ...
    neon2      = { 1.00, 0.42, 0.72, 1.00 },      -- ... to pink
    violet     = { 0.62, 0.40, 1.00, 0.90 },
    btn        = { 0.10, 0.09, 0.13, 1.00 },
    heading    = { 0.93, 0.90, 1.00, 1.00 },
    text       = { 0.91, 0.922, 0.957, 1.00 },
    soft       = { 0.72, 0.74, 0.82, 1.00 },
    faint      = { 0.545, 0.576, 0.667, 1.00 },
    track      = { 0.20, 0.19, 0.25, 1.00 },
    line       = { 1.00, 1.00, 1.00, 0.08 },
    new        = { 0.545, 0.576, 0.667, 1.00 },
    active     = { 0.55, 0.88, 1.00, 1.00 },
    ['return'] = { 1.00, 0.80, 0.40, 1.00 },
    done       = { 0.40, 1.00, 0.82, 1.00 },
}

local W, PAD = 400, 14      -- Default card width and inner margin, in pixels.
local W_MIN, W_MAX = 350, 720  -- How narrow / wide the card can be dragged.

local function card_width()
    return math.max(W_MIN, math.min(W_MAX, ui.w or W))
end

-- Stores a UI setting (size, minimized, width) with the character's saved state; written to disk shortly after.
local function remember(key, value)
    ui[key] = value
    if status then
        status.ui = status.ui or {}
        status.ui[key] = value
        ui.save_at = os.clock() + 0.5
    end
end

-- Scale: the user's factor (0.75 - 3), kept to steps of 0.05.
local SCALE_MIN, SCALE_MAX = 0.75, 3.0
local function scale_value()
    return math.max(SCALE_MIN, math.min(SCALE_MAX, tonumber(ui.scale) or 1))
end

local function set_scale(v)
    v = math.max(SCALE_MIN, math.min(SCALE_MAX, math.floor(v * 20 + 0.5) / 20))
    remember('scale', v)
    return v
end

-- A scale that suits the screen: 1.0 at 1080p high, growing with the resolution, in steps of 0.25.
local function auto_scale()
    local ok, h = pcall(function()
        local ds = imgui.GetIO().DisplaySize
        return ds.y or ds[2]
    end)
    if ok and tonumber(h) then
        return math.max(1, math.floor(tonumber(h) / 1080 * 4 + 0.5) / 4)
    end
    return 1
end

-- The window's origin and factor for this frame.  Drawing, hit areas and the cursor all go through these so the layout
-- code can stay in logical pixels.
ui.s, ui.ox, ui.oy = 1, 0, 0

local function cursor_at(p)
    local s = ui.s
    imgui.SetCursorScreenPos({ ui.ox + (p[1] - ui.ox) * s, ui.oy + (p[2] - ui.oy) * s })
end

local function hit_area(id, size)
    return imgui.InvisibleButton(id, { size[1] * ui.s, size[2] * ui.s })
end

local function get_dl()
    local real = imgui.GetWindowDrawList()
    local s, ox, oy = ui.s, ui.ox, ui.oy
    if s == 1 then
        return real
    end
    local function P(p)
        return { ox + (p[1] - ox) * s, oy + (p[2] - oy) * s }
    end
    return {
        AddText = function(_, p, c, t) real:AddText(P(p), c, t) end,
        AddRectFilled = function(_, a, b, c, r) real:AddRectFilled(P(a), P(b), c, (r or 0) * s) end,
        AddRect = function(_, a, b, c, r, f, t) real:AddRect(P(a), P(b), c, (r or 0) * s, f or 0, (t or 1) * s) end,
        AddLine = function(_, a, b, c, t) real:AddLine(P(a), P(b), c, (t or 1) * s) end,
        AddCircleFilled = function(_, p, r, c, n) real:AddCircleFilled(P(p), r * s, c, n or 16) end,
        AddCircle = function(_, p, r, c, n, t) real:AddCircle(P(p), r * s, c, n or 16, (t or 1) * s) end,
        AddRectFilledMultiColor = function(_, a, b, c1, c2, c3, c4) real:AddRectFilledMultiColor(P(a), P(b), c1, c2, c3, c4) end,
    }
end

local function alpha(c, a)
    return { c[1], c[2], c[3], (c[4] or 1) * a }
end

local function u32(c)
    return imgui.GetColorU32(c)
end

-- Everything is laid out in "logical" pixels (scale 1); the text is measured at the current scale and divided back.
local function text_width(s)
    local w = imgui.CalcTextSize(s)
    if type(w) == 'table' then
        w = w.x or w[1]
    end
    if tonumber(w) then
        return tonumber(w) / (ui.s or 1)
    end
    return #s * 7
end

-- Capitals with a little air between the letters, the way YunaUI writes its headings and buttons.
local function spaced_width(str, gap)
    local w = 0
    for i = 1, #str do
        w = w + text_width(string.sub(str, i, i)) + gap
    end
    return math.max(0, w - gap)
end

local function spaced_text(dl, x, y, str, col, gap)
    local cx = x
    for i = 1, #str do
        local ch = string.sub(str, i, i)
        dl:AddText({ cx, y }, col, ch)
        cx = cx + text_width(ch) + gap
    end
    return cx - x - gap
end

local fit_cache = {}
local function fit(s, max_w)
    local key = s .. '|' .. max_w
    local cached = fit_cache[key]
    if cached then
        return cached
    end
    local out = s
    if text_width(out) > max_w then
        while #out > 1 and text_width(out .. '..') > max_w do
            out = string.sub(out, 1, -2)
        end
        out = out .. '..'
    end
    fit_cache[key] = out
    return out
end

local function window_pos()
    local x, y = imgui.GetWindowPos()
    if type(x) == 'table' then
        x, y = x.x or x[1], x.y or x[2]
    end
    return tonumber(x) or 0, tonumber(y) or 0
end

-- Vertical layout of one goblin entry.  Used for both the card's height and the drawing so they always agree.
local function layout(d)
    if ui.mini then
        return { name = 0, h = 22 }  -- Mini size: one line per goblin.
    end
    local o = { name = 0, task = 18 }
    local y = 36
    if d.where then
        o.where = y
        y = y + 16
    end
    if d.items and #d.items > 0 then
        o.items = y  -- One line per requested item: name, have / need, and a bar.
        y = y + 26 * #d.items
    end
    if d.total then
        o.bar = y + 3
        y = y + 13
    end
    o.h = y + 6
    return o
end

local HEAD_H, FOOT_H, SEA_H = 46, 66, 26

-- Re-check saved state about once a second so the card rolls over at JP midnight even if nothing is said in chat.
local function refresh_status()
    local now = os.time()
    if now ~= ui.last_check then
        ui.last_check = now
        update_status()
    end
    return status ~= nil
end

local function format_countdown(seconds)
    seconds = math.max(0, seconds)
    return ('%dh %02dm'):format(math.floor(seconds / 3600), math.floor((seconds % 3600) / 60))
end

-- Pulses between ~0.65 and 1.0, for things that want attention.
local function pulse()
    return 0.825 + 0.175 * math.sin(os.clock() * 4)
end

local function gradient_bar(dl, x1, y1, x2, y2)
    if x2 > x1 then
        local ok = pcall(function()
            dl:AddRectFilledMultiColor({ x1, y1 }, { x2, y2 }, u32(COL.neon), u32(COL.neon2), u32(COL.neon2), u32(COL.neon))
        end)
        if not ok then
            dl:AddRectFilled({ x1, y1 }, { x2, y2 }, u32(COL.neon), 3)
        end
    end
end

-- A progress bar: dark rounded track, magenta-to-pink fill.
local function thin_bar(dl, x, y, w, frac)
    dl:AddRectFilled({ x, y }, { x + w, y + 6 }, u32(COL.track), 3)
    frac = math.max(0, math.min(1, frac))
    gradient_bar(dl, x, y, x + math.floor(w * frac), y + 6)
end

local function draw_card(dl, wx, wy, w, h)
    -- Transparent mode: the panel fill and edge fade right back so the game shows through; text and bars stay solid.
    local bg, edge = COL.bg, COL.edge
    if ui.clear then
        bg, edge = alpha(COL.bg, 0.22), alpha(COL.edge, 0.45)
    end
    dl:AddRectFilled({ wx, wy }, { wx + w, wy + h }, u32(bg), 10)
    dl:AddRect({ wx, wy }, { wx + w, wy + h }, u32(edge), 10, 0, 1)
end

-- The small "x" at the card's top right.
local function draw_close(dl, wx, wy, w)
    pcall(function()
        cursor_at({ wx + w - 26, wy + 5 })
        local clicked = hit_area('##goldilox_close', { 20, 20 })
        local hovered = imgui.IsItemHovered()
        local col = hovered and COL.text or COL.faint
        dl:AddText({ wx + w - 20, wy + 7 }, u32(col), 'x')
        if clicked then
            ui.open = false
        end
    end)
end

-- A rounded button in YunaUI's style: dark inside, pink edge (or a faint white one when quiet), spaced capitals.
-- Returns clicked.
local function pill_button(dl, id, x, y, w, h, label, gap, quiet)
    local clicked, hovered = false, false
    pcall(function()
        cursor_at({ x, y })
        clicked = hit_area(id, { w, h })
        hovered = imgui.IsItemHovered()
    end)
    local rr = math.floor(h * 0.45)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, u32(hovered and { 0.15, 0.14, 0.19, 1 } or COL.btn), rr)
    local edge = quiet and { 1, 1, 1, hovered and 0.25 or 0.14 } or alpha(COL.neon2, hovered and 1 or 0.8)
    dl:AddRect({ x, y }, { x + w, y + h }, u32(edge), rr, 0, quiet and 1 or 1.5)
    spaced_text(dl, x + (w - spaced_width(label, gap)) / 2, y + (h - 15) / 2, label, u32(COL.heading), gap)
    return clicked
end

-- The MINI / FULL button left of the minimize button.  Returns its width so the header can leave room for it.
local function draw_size_button(dl, wx, wy, w)
    local label = ui.mini and 'FULL' or 'MINI'
    local bw = math.floor(spaced_width(label, 2) + 22)
    if pill_button(dl, '##goldilox_size', wx + w - 56 - bw, wy + 6, bw, 20, label, 2) then
        remember('mini', not ui.mini)
    end
    return bw
end

-- The minimize "-" between the size pill and the close button.  Collapses the card to just the word Goldilox.
local function draw_min_button(dl, wx, wy, w)
    pcall(function()
        local bx, by = wx + w - 48, wy + 5
        cursor_at({ bx, by })
        local clicked = hit_area('##goldilox_min', { 20, 20 })
        local hovered = imgui.IsItemHovered()
        dl:AddLine({ bx + 5, by + 12 }, { bx + 15, by + 12 }, u32(hovered and COL.text or COL.faint), 1.5)
        if clicked then
            remember('min', true)
        end
    end)
end

-- The transparency toggle: a switch like YunaUI's (dark pill, white knob on the right when the card is see-through).
local function draw_clear_button(dl, bx, wy)
    pcall(function()
        local by = wy + 5
        cursor_at({ bx, by })
        local clicked = hit_area('##goldilox_clear', { 38, 20 })
        local hovered = imgui.IsItemHovered()
        local on = ui.clear and true or false
        local x, y, sw, sh = bx + 2, by + 1, 34, 18
        local fill = on and { COL.neon[1] * 0.42, COL.neon[2] * 0.42, COL.neon[3] * 0.42, 1 }
            or (hovered and { 0.14, 0.13, 0.18, 1 } or COL.btn)
        dl:AddRectFilled({ x, y }, { x + sw, y + sh }, u32(fill), sh / 2)
        dl:AddCircleFilled({ on and (x + sw - sh / 2) or (x + sh / 2), y + sh / 2 }, sh / 2 - 3, u32(on and { 1, 1, 1, 1 } or { 0.55, 0.53, 0.62, 1 }), 24)
        if clicked then
            remember('clear', not ui.clear)
        end
    end)
end

-- Drag handle in the bottom right corner: dragging sideways changes the card's width.  (Its height always follows
-- what is listed, so there is never empty space or clipped rows.)
local function draw_grip(dl, wx, wy, w, h)
    pcall(function()
        local gx, gy = wx + w - 16, wy + h - 16
        cursor_at({ gx, gy })
        hit_area('##goldilox_grip', { 14, 14 })
        local hovered = imgui.IsItemHovered()
        local active = imgui.IsItemActive()
        if (hovered or active) and rawget(_G, 'ImGuiMouseCursor_ResizeEW') then
            pcall(imgui.SetMouseCursor, ImGuiMouseCursor_ResizeEW)
        end
        if active then
            local mx = imgui.GetMousePos()
            if type(mx) == 'table' then
                mx = mx.x or mx[1]
            end
            if tonumber(mx) then
                local nw = math.max(W_MIN, math.min(W_MAX, math.floor((mx - wx) / ui.s + 7)))
                if nw ~= ui.w then
                    remember('w', nw)
                end
            end
        end
        local col = u32((hovered or active) and COL.text or COL.faint)
        dl:AddLine({ gx + 12, gy + 4 }, { gx + 4, gy + 12 }, col, 1)
        dl:AddLine({ gx + 12, gy + 8 }, { gx + 8, gy + 12 }, col, 1)
    end)
end

local PILL_W, PILL_H = 124, 28

-- The minimized card: just the word Goldilox.  A click (without dragging) opens it again; dragging still moves it.
local function draw_pill(wx, wy, w, h)
    local dl = get_dl()
    local hovered = false
    pcall(function() hovered = imgui.IsWindowHovered() end)
    draw_card(dl, wx, wy, w, h)
    local label = 'GOLDILOX'
    spaced_text(dl, wx + (w - spaced_width(label, 2.5)) / 2, wy + 6, label, u32(hovered and COL.text or COL.heading), 2.5)
    pcall(function()
        if hovered and imgui.IsMouseClicked(0) then
            ui.press = { wx, wy }
        end
        if imgui.IsMouseReleased(0) then
            local p = ui.press
            ui.press = nil
            if p and hovered and math.abs(p[1] - wx) < 2 and math.abs(p[2] - wy) < 2 then
                remember('min', false)
            end
        end
    end)
end

-- Links: an NM or item name in a task opens catseyexi.com's database search for it in your browser.  The database page
-- reads only `q` (3+ letters) and always opens on its Items tab, so for monsters you click its "Monsters" tab.
local LINK_URL = 'https://catseyexi.com/database?q=%s'
local COL_LINK = { 0.80, 0.66, 1.00, 1.00 }

local function url_encode(s)
    return (string.gsub(s, '[^%w%-%._~]', function(c)
        return ('%%%02X'):format(string.byte(c))
    end))
end

local function open_link(query)
    local url = LINK_URL:format(url_encode(query))
    local ok = pcall(function()
        ashita.misc.open_url(url)
    end)
    if not ok then
        say_chat(chat.header(addon.name) .. 'Could not open your browser.  Link: ' .. url)
    end
end

-- The task line.  If the task names an NM or item, that name is drawn as a link (violet, underlined, hand cursor).
local function draw_task(dl, npc, d, x, y, max_w)
    local link = d.link
    local pre, post
    if link and link.label and #link.label >= 3 and link.query and #link.query >= 3 then
        local s, e = string.find(d.task, link.label, 1, true)
        if s then
            pre, post = string.sub(d.task, 1, s - 1), string.sub(d.task, e + 1)
        end
    end
    local pw = pre and text_width(pre) or 0
    local lw = pre and text_width(link.label) or 0
    if not pre or pw + lw > max_w then
        dl:AddText({ x, y }, u32(COL.soft), fit(d.task, max_w))  -- Plain text (no link, or no room for one).
        return
    end

    if pre ~= '' then
        dl:AddText({ x, y }, u32(COL.soft), pre)
    end
    local lx = x + pw
    pcall(function()
        cursor_at({ lx, y })
        local clicked = hit_area('##goldilox_link_' .. npc, { lw, 15 })
        local hovered = imgui.IsItemHovered()
        dl:AddText({ lx, y }, u32(hovered and COL.text or COL_LINK), link.label)
        dl:AddLine({ lx, y + 14 }, { lx + lw, y + 14 }, u32(alpha(hovered and COL.text or COL_LINK, hovered and 1 or 0.55)), 1)
        if hovered then
            if rawget(_G, 'ImGuiMouseCursor_Hand') then
                pcall(imgui.SetMouseCursor, ImGuiMouseCursor_Hand)
            end
            local tip = 'Search "' .. link.query .. '" on catseyexi.com'
            if link.kind == 'mob' then
                tip = tip .. '  (click its Monsters tab)'
            end
            pcall(imgui.SetTooltip, tip)
        end
        if clicked then
            open_link(link.query)
        end
    end)
    if post ~= '' then
        dl:AddText({ lx + lw, y }, u32(COL.soft), fit(post, max_w - pw - lw))
    end
end

local function draw_body(rows, info, wx, wy, w, h)
    local dl = get_dl()
    draw_card(dl, wx, wy, w, h)

    -- Header: name, how many are done, and the overall bar.
    local done, total = info.done, info.total
    spaced_text(dl, wx + PAD, wy + 8, 'GOLDILOX', u32(COL.heading), 2.5)
    local count = ('%d / %d'):format(done, total)
    local btn_w = draw_size_button(dl, wx, wy, w)
    draw_min_button(dl, wx, wy, w)
    draw_clear_button(dl, wx + w - 56 - btn_w - 42, wy)
    dl:AddText({ wx + w - 108 - btn_w - text_width(count), wy + 8 }, u32(done == total and COL.done or COL.active), count)
    thin_bar(dl, wx + PAD, wy + 32, w - PAD * 2, done / total)

    -- One entry per goblin / Sea quest, with a section label ("SEA") in between.
    local y = wy + HEAD_H
    local x0 = wx + PAD
    local right = wx + w - PAD
    local text_max = right - x0
    for _, row in ipairs(rows) do
        if row.divider then
            local lw = spaced_text(dl, wx + PAD, y + 3, row.label, u32(COL.heading), 2.5)
            local c = ('%d / %d'):format(row.done, row.total)
            dl:AddText({ right - text_width(c), y + 3 }, u32(row.done == row.total and COL.done or COL.soft), c)
            dl:AddLine({ wx + PAD + lw + 14, y + 12 }, { right - text_width(c) - 10, y + 12 }, u32(COL.line), 1)
            y = y + row.h
        else
            local d, o = row.d, row.o
            local id = row.id or row.npc
            local sc = COL[d.state]
            local a = (d.state == 'return') and pulse() or 1

            local tag = tags[d.state]
            if ui.mini and d.total and d.state == 'active' then
                tag = ('%d / %d'):format(d.killed, d.total)  -- Kill progress doubles as the mini status.
            elseif ui.mini and d.items and inv.ok and d.state == 'active' then
                local got, need = 0, 0
                for _, it in ipairs(d.items) do
                    got = got + math.min(have_count(it.name), it.count)
                    need = need + it.count
                end
                tag = ('%d / %d'):format(got, need)  -- Items carried doubles as the mini status.
            end
            dl:AddText({ x0, y + o.name }, u32(COL.text), row.title or row.npc)
            local tw = text_width(tag)
            dl:AddRectFilled({ right - tw - 14, y + o.name - 1 }, { right, y + o.name + 17 }, u32(alpha(sc, 0.16 * a)), 9)
            dl:AddRect({ right - tw - 14, y + o.name - 1 }, { right, y + o.name + 17 }, u32(alpha(sc, 0.45 * a)), 9, 0, 1)
            dl:AddText({ right - tw - 7, y + o.name }, u32(alpha(sc, a)), tag)
            if o.task then
                draw_task(dl, id, d, x0, y + o.task, text_max)
            end
            if o.where then
                dl:AddText({ x0, y + o.where }, u32(COL.faint), fit('in ' .. d.where, text_max - 50))
            end
            if o.items then
                for i, it in ipairs(d.items) do
                    local iy = y + o.items + (i - 1) * 26
                    local have = inv.ok and have_count(it.name) or nil
                    local counter = have and ('%d / %d'):format(have, it.count) or ('x%d'):format(it.count)
                    local cw = text_width(counter)
                    draw_task(dl, id .. '_' .. i, { task = it.name, link = { label = it.name, query = it.name, kind = 'item' } },
                        x0, iy, text_max - cw - 10)
                    dl:AddText({ right - cw, iy }, u32((have and have >= it.count) and COL.done or COL.soft), counter)
                    if have then
                        thin_bar(dl, x0, iy + 18, right - x0, have / it.count)
                    end
                end
            end
            if o.bar then
                local label = ('%d / %d'):format(d.killed, d.total)
                if o.where then
                    dl:AddText({ right - text_width(label), y + o.where }, u32(COL.faint), label)
                end
                thin_bar(dl, x0, y + o.bar, right - x0, d.killed / d.total)
            end
            y = y + o.h
        end
    end

    -- Footer: reward status on the left, time to reset on the right.
    dl:AddLine({ wx + PAD, y + 2 }, { right, y + 2 }, u32(COL.line), 1)
    if info.gdone > 0 then
        if status.goldilox_time == status.deadline then
            dl:AddText({ wx + PAD, y + 9 }, u32(COL.done), 'Reward collected')
        else
            dl:AddText({ wx + PAD, y + 9 }, u32(COL['return']), 'Reward not collected')
        end
    elseif info.ready > 0 then
        dl:AddText({ wx + PAD, y + 9 }, u32(COL['return']), ('%d ready to turn in'):format(info.ready))
    end
    local reset = 'resets in ' .. format_countdown(status.deadline - os.time())
    dl:AddText({ right - 12 - text_width(reset), y + 9 }, u32(COL.faint), reset)

    -- Bottom row: smaller / bigger (A- 100% A+) and CLOSE.
    local by, px = y + 32, wx + PAD
    if pill_button(dl, '##goldilox_scale_down', px, by, 28, 24, 'A-', 0, true) then
        set_scale(scale_value() - 0.25)
    end
    local pct = ('%d%%'):format(math.floor(scale_value() * 100 + 0.5))
    dl:AddText({ px + 28 + (38 - text_width(pct)) / 2, by + 4 }, u32(COL.soft), pct)
    if pill_button(dl, '##goldilox_scale_up', px + 66, by, 28, 24, 'A+', 0, true) then
        set_scale(scale_value() + 0.25)
    end
    if pill_button(dl, '##goldilox_close_btn', px + 100, by, w - PAD * 2 - 100, 24, 'CLOSE', 3, true) then
        ui.open = false
    end

    draw_close(dl, wx, wy, w)
    draw_grip(dl, wx, wy, w, h)
end

local function draw_waiting(wx, wy, w, h)
    local dl = get_dl()
    draw_card(dl, wx, wy, w, h)
    spaced_text(dl, wx + PAD, wy + 8, 'GOLDILOX', u32(COL.heading), 2.5)
    dl:AddText({ wx + PAD, wy + 36 }, u32(COL.faint), 'Waiting for character data...')
    draw_close(dl, wx, wy, w)
end

-- Fonts: use YunaUI's font if it is installed (so the two match), else Segoe UI, else ImGui's own.
local function load_font()
    local candidates = {}
    local vana = rawget(_G, 'vana')
    if vana and vana.paths and vana.paths.addons then
        candidates[#candidates + 1] = vana.paths.addons .. '\\vanacore\\yunaui\\fonts\\texgyreadventor-regular.otf'
    end
    candidates[#candidates + 1] = (os.getenv('WINDIR') or 'C:\\Windows') .. '\\Fonts\\segoeui.ttf'
    for _, path in ipairs(candidates) do
        local f = io.open(path, 'rb')
        if f then
            f:close()
            local ok, font = pcall(imgui.AddFontFromFileTTF, path, 17)
            if ok and font then
                ui.font = font
                return
            end
        end
    end
end

local function push_font(s)
    local f = ui.font
    if f == nil then
        return false
    end
    if ui.font_sized == nil then
        local ok, legacy = pcall(function() return f.LegacySize end)
        ui.font_sized = (ok and legacy ~= nil) and true or false
    end
    if ui.font_sized then
        return (pcall(imgui.PushFont, f, 17 * s))
    end
    return (pcall(imgui.PushFont, f))
end

local window_flags = nil
local function get_window_flags()
    if window_flags == nil then
        local ok, flags = pcall(function()
            return bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoResize, ImGuiWindowFlags_NoCollapse,
                ImGuiWindowFlags_NoSavedSettings, ImGuiWindowFlags_NoBackground, ImGuiWindowFlags_NoScrollbar,
                ImGuiWindowFlags_NoScrollWithMouse, ImGuiWindowFlags_NoFocusOnAppearing, ImGuiWindowFlags_NoNav)
        end)
        window_flags = ok and flags or 0
    end
    return window_flags
end

-- Remember where the card was dragged to (written to disk once it has stopped moving).
local function note_position(x, y)
    if status == nil then
        return
    end
    if status.ui == nil then
        status.ui = { x = x, y = y }
    end
    if math.abs((status.ui.x or 0) - x) >= 1 or math.abs((status.ui.y or 0) - y) >= 1 then
        status.ui.x, status.ui.y = x, y
        ui.save_at = os.clock() + 1.0
    end
end

local function draw_window()
    if ui.save_at and os.clock() >= ui.save_at then  -- (first, so settings are written even while the card is hidden)
        ui.save_at = nil
        settings.save()
    end
    if not ui.open then
        return
    end
    local have_status = refresh_status()
    scan_inventory()

    -- Work out what to show and how tall the card is before the window starts.  Only NPCs you have talked to today
    -- get a row, and the card stays hidden until there is at least one.
    local rows, h = {}, 70
    local info = { done = 0, gdone = 0, ready = 0, total = 0 }  -- gdone: goblins done (for the Goldilox reward line)
    if have_status then
        local rows_h = 0
        for _, npc in ipairs(goblin_order) do
            if status.dailies[npc] ~= nil then
                local d = describe(npc)
                local o = layout(d)
                rows[#rows + 1] = { npc = npc, d = d, o = o }
                rows_h = rows_h + o.h
                if d.state == 'done' then
                    info.done = info.done + 1
                    info.gdone = info.gdone + 1
                elseif d.state == 'return' then
                    info.ready = info.ready + 1
                end
            end
        end
        local goblins = #rows
        if goblins > 0 then
            table.insert(rows, 1, { divider = true, label = 'DAILIES', done = info.gdone, total = #goblin_order, h = SEA_H })
            rows_h = rows_h + SEA_H
        end

        local sea_rows, sea_done = {}, 0
        for _, key in ipairs(sea_order) do
            local d = describe_sea(key)
            if d then
                local o = layout(d)
                sea_rows[#sea_rows + 1] = { npc = key, title = d.title, id = 'sea_' .. string.gsub(key, ' ', '_'), d = d, o = o }
                if d.state == 'done' then
                    sea_done = sea_done + 1
                elseif d.state == 'return' then
                    info.ready = info.ready + 1
                end
            end
        end
        if #sea_rows > 0 then
            rows[#rows + 1] = { divider = true, label = 'SEA', done = sea_done, total = #sea_order, h = SEA_H }
            rows_h = rows_h + SEA_H
            for _, r in ipairs(sea_rows) do
                rows[#rows + 1] = r
                rows_h = rows_h + r.o.h
            end
            info.done = info.done + sea_done
        end
        info.total = (goblins > 0 and #goblin_order or 0) + (#sea_rows > 0 and #sea_order or 0)
        h = HEAD_H + rows_h + FOOT_H
    end
    if not have_status or info.total == 0 then
        return
    end

    local cw = card_width()
    if ui.min then
        cw, h = PILL_W, PILL_H  -- Minimized: just the word Goldilox.
    end
    local sc = scale_value()
    ui.s = sc
    imgui.SetNextWindowSize({ cw * sc, h * sc }, ImGuiCond_Always)
    if have_status and not ui.pos_applied then
        local p = status.ui or {}
        imgui.SetNextWindowPos({ tonumber(p.x) or 120, tonumber(p.y) or 160 }, ImGuiCond_Always)
        ui.pos_applied = true
    else
        imgui.SetNextWindowPos({ 120, 160 }, ImGuiCond_FirstUseEver)
    end

    local pushed = push_font(sc)
    if imgui.Begin('Goldilox##goldilox_main', { true }, get_window_flags()) then
        local base = pushed and 0.92 or 1.15
        imgui.SetWindowFontScale((pushed and ui.font_sized) and base or base * sc)  -- (sized fonts are loaded at 17 * scale)
        local wx, wy = window_pos()
        ui.ox, ui.oy = wx, wy
        local ok, err
        if ui.min then
            ok, err = pcall(draw_pill, wx, wy, cw, h)
        else
            ok, err = pcall(draw_body, rows, info, wx, wy, cw, h)
        end
        if not ok and not ui.error_seen then
            ui.error_seen = true
            say_chat(chat.header(addon.name) .. chat.color1(68, 'UI error: ' .. tostring(err)))
        end
        imgui.SetWindowFontScale(1)
        if have_status and ui.pos_applied then
            note_position(wx, wy)
        end
    end
    imgui.End()
    if pushed then
        imgui.PopFont()
    end

    if ui.save_at and os.clock() >= ui.save_at then
        ui.save_at = nil
        settings.save()
    end
end

if imgui_ok then
    local registered, err = pcall(function()
        ashita.events.register('load', 'goldilox_load_cb', function()
            pcall(load_font)
        end)
        ashita.events.register('d3d_present', 'goldilox_present_cb', function()
            draw_window()
        end)
    end)
    if not registered then
        imgui_ok = false
        say_chat(chat.header(addon.name) .. 'Could not register the UI (' .. tostring(err) .. '); using chat output only.')
    end
end

----------------------------------------------------------------------------------------------------
-- Message parsing
----------------------------------------------------------------------------------------------------
-- Strips the game's color/control codes so the patterns below see plain text.
local function clean(s)
    s = string.gsub(s, '[\30\31\127].', '')                 -- Color and control codes are two bytes each.
    s = string.gsub(s, '[\1-\6\8\9\11-\31]', '')            -- Other control characters (keeps newline and \7).
    return s
end

-- Cheap test so ordinary chat (including busy combat spam) costs almost nothing.
local quick = {
    'Fishstix', 'Murdox', 'Mistrix', 'Saltlix', 'Beetrix', 'please return to', 'Daily Quest', 'Dice roll',
    'Find flux', 'Item request', 'Defeat mobs', 'Defeat Mobs', 'Quest Completed',  -- Palalumin (Sea)
}
local function worth_parsing(msg)
    for _, needle in ipairs(quick) do
        if string.find(msg, needle, 1, true) then
            return true
        end
    end
    return false
end

local function handle_dialogue(npc, message)
    if not update_status() then
        return
    end
    local data = { message = message }
    if string.find(message, 'completed') then
        data.status = 'complete'
    else
        handlers[npc].talk(data, status.dailies[npc])
    end
    status.dailies[npc] = data
    settings.save()
end

-- Diamonds in front of Palalumin's quest lines.  The game sends them as Shift-JIS bytes; the UTF-8 forms are accepted
-- too in case a client re-encodes chat.  Without one of them a line is never treated as a quest line, so a player
-- typing "Defeat mobs: ..." in chat does nothing.
local DIAMONDS = {
    { '\129\158', false }, { '\129\159', true },
    { '\226\151\135', false }, { '\226\151\134', true },
}

-- If `line` is one of Palalumin's quest lines, returns the quest key, whether it is finished, and the objective text.
local function sea_quest_line(line)
    local lower = string.lower(line)
    for _, key in ipairs(sea_order) do
        local s, e = string.find(lower, string.lower(key) .. '%s*:')
        if s then
            local before = string.sub(line, math.max(1, s - 4), s - 1)
            for _, d in ipairs(DIAMONDS) do
                if string.find(before, d[1], 1, true) then
                    local objective = trim(string.sub(line, e + 1))
                    if objective ~= '' then
                        return key, d[2], objective
                    end
                end
            end
        end
    end
end

local function handle_sea_dialogue(key, completed, objective)
    if not update_status() then
        return
    end
    local data = { message = objective }
    if completed then
        data.completed = true
    end
    sea_handlers[key].talk(data)
    status.sea[key] = data
    settings.save()
end

-- "Defeat Mobs 1/10 (Zdei in Grand Palace of HuXzoi)"
local function handle_sea_progress(killed, total, target, zone)
    if not update_status() then
        return
    end
    local q = status.sea['Defeat mobs']
    if q == nil then
        q = { message = '' }
        status.sea['Defeat mobs'] = q
    end
    q.killed, q.total, q.target, q.zone = tonumber(killed), tonumber(total), target, zone
    settings.save()
end

local function current_target_name()
    local ok, name = pcall(function()
        local target = AshitaCore:GetMemoryManager():GetTarget()
        if target == nil then
            return nil
        end
        local index
        if target:GetIsSubTargetActive() == 0 then
            index = target:GetTargetIndex(0)
        else
            index = target:GetTargetIndex(1)
        end
        local entity = GetEntity(index)
        return entity and entity.Name or nil
    end)
    return ok and name or nil
end

-- "Quest Completed" doesn't say which quest it was, so it is worked out from who you are facing: the Lumorian Flux is
-- the flux quest; Palalumin is the item request if you have just traded him something, otherwise the kill quest
-- (once the kills are in).  Talking to Palalumin again fixes up anything missed here (finished quests get a filled
-- diamond).
local function handle_sea_completed()
    if not update_status() then
        return
    end
    local target = current_target_name()
    local changed = false
    local function finish(key)
        local q = status.sea[key]
        if q and not q.completed then
            q.completed = true
            changed = true
        end
    end
    if target == 'Lumorian Flux' then
        finish('Find flux')
    elseif target == 'Palalumin' then
        local traded = ui.trade_at ~= nil and (os.clock() - ui.trade_at) < 60
        local kills = status.sea['Defeat mobs']
        if traded then
            finish('Item request')
        elseif kills and kills.killed and kills.total and kills.killed >= kills.total then
            finish('Defeat mobs')
        end
    end
    if changed then
        settings.save()
    end
end

local function process_line(line)
    -- Never parse the addon's own output.
    if string.find(line, '^%[Goldilox%]') then
        return
    end

    -- Palalumin (Sea)
    local key, finished, objective = sea_quest_line(line)
    if key then
        return handle_sea_dialogue(key, finished, objective)
    end
    local killed, total, mob, zone = string.match(line, 'Defeat Mobs (%d+)/(%d+) %((.+) in (.+)%)')
    if killed then
        return handle_sea_progress(killed, total, mob, zone)
    end
    if string.find(line, 'Quest Completed', 1, true) then
        return handle_sea_completed()
    end

    -- "Fishstix : Go to Yughott Grotto, ..."  (any chat mode)
    for _, npc in ipairs(goblin_order) do
        local message = string.match(line, '%f[%a]' .. npc .. '%s*:%s*(.+)$')
        if message then
            return handle_dialogue(npc, trim(message))
        end
    end

    --[[
        You've killed enough Olden Treants, please return to Murdox to claim your reward!
        You've killed Teporingo, please return to Saltlix to claim your reward!
        You found the Secret Treasure Chest, please return to Fishstix to claim your reward!
    ]]
    local npc = string.match(line, 'please return to (%a+) to claim your reward')
    if npc and handlers[npc] then
        if not update_status() then
            return
        end
        if status.dailies[npc] == nil then
            status.dailies[npc] = { message = '<unknown previous message>' }
        end
        status.dailies[npc].status = 'return'
        settings.save()
        return
    end

    --[[
        Daily Quest: 19 kills remain. (Olden Treant in Bhaflau Thickets)
    ]]
    local kills = string.match(line, 'Daily Quest: (%d+) kills? remain')
    if kills then
        if update_status() and status.dailies.Murdox then
            status.dailies.Murdox.remaining = kills
            -- The exact mob name, for the database link: "(Olden Treant in Bhaflau Thickets)".
            local mob = string.match(line, 'kills? remain.-%((.-) in ')
            if mob and mob ~= '' then
                status.dailies.Murdox.mob = mob
            end
            settings.save()
        end
        return
    end

    if string.match(line, 'Dice roll!.*rolls.*%(.*%)') then
        if update_status() then
            status.goldilox_time = status.deadline
            settings.save()
        end
    end
end

local debug_enabled = false

local function debug_log(e, text)
    local shown = string.gsub(trim(text), '[\128-\255]', '?')
    if string.find(shown, '^%[Goldilox%]') then
        return  -- Our own output.
    end
    say_chat(chat.header(addon.name) .. ('mode=%s injected=%s | %s'):format(
        tostring(e.mode % 256), tostring(e.injected), shown))
end

ashita.events.register('text_in', 'goldilox_text_in_cb', function(e)
    if ui.printing then
        return
    end
    local msg = e.message
    if msg == nil or #msg > 2048 or not worth_parsing(msg) then
        return
    end
    local text = clean(msg)
    if debug_enabled then
        debug_log(e, text)
    end
    for line in (text .. '\n'):gmatch('([^\n\7]*)[\n\7]') do
        line = trim(line)
        if line ~= '' then
            local ok, err = pcall(process_line, line)
            if not ok and debug_enabled then
                say_chat(chat.header(addon.name) .. 'Parse error: ' .. tostring(err))
            end
        end
    end
end)

-- Remember when you last handed something over (outgoing trade packet), to tell an item-request turn-in apart from the
-- other Palalumin quests.
pcall(function()
    ashita.events.register('packet_out', 'goldilox_packet_out_cb', function(e)
        if e.id == 0x0036 then
            ui.trade_at = os.clock()
        end
    end)
end)

----------------------------------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------------------------------
ashita.events.register('command', 'goldilox_command_cb', function(e)
    local args = e.command:args()
    if #args == 0 then
        return
    end
    local cmd = string.lower(args[1])
    if cmd ~= '/goldilox' and cmd ~= '/dailies' then
        return
    end
    e.blocked = true

    local sub = args[2] and string.lower(args[2]) or nil
    if sub == 'chat' or sub == 'report' or not imgui_ok then
        print_report()
    elseif sub == 'debug' then
        debug_enabled = not debug_enabled
        say_chat(chat.header(addon.name) .. 'Debug logging ' .. (debug_enabled and 'ON' or 'OFF')
            .. '.  Goblin-related chat lines are listed as they arrive.')
    elseif sub == 'mini' or sub == 'full' then
        update_status()
        remember('mini', sub == 'mini')
    elseif sub == 'clear' or sub == 'transparent' or sub == 'trans' then
        update_status()
        remember('clear', not ui.clear)
    elseif sub == 'min' or sub == 'minimize' then
        update_status()
        remember('min', true)
    elseif sub == 'scale' or sub == 'size' then
        update_status()
        local arg = string.lower(args[3] or '')
        local now
        if arg == '+' or arg == 'up' then
            now = set_scale(scale_value() + 0.25)
        elseif arg == '-' or arg == 'down' then
            now = set_scale(scale_value() - 0.25)
        elseif arg == 'auto' then
            now = set_scale(auto_scale())
        elseif arg == 'reset' then
            now = set_scale(1)
        elseif tonumber(arg) then
            local n = tonumber(arg)
            now = set_scale(n > 5 and n / 100 or n)  -- 150 or 1.5
        end
        say_chat(chat.header(addon.name) .. ('Scale %d%%.'):format(math.floor(scale_value() * 100 + 0.5))
            .. (now and '' or '  Use /goldilox scale 1.5 (or 150), + , - , auto or reset.'))
    elseif sub == 'show' then
        ui.open = true
        update_status()
        remember('min', false)
    elseif sub == 'hide' then
        ui.open = false
    elseif sub == 'help' then
        say_chat(chat.header(addon.name) .. '/goldilox  - show or hide the window (it appears once you have talked to a goblin or Palalumin)')
        say_chat(chat.header(addon.name) .. '/goldilox mini | full  - switch the window size')
        say_chat(chat.header(addon.name) .. '/goldilox clear  - toggle a see-through background')
        say_chat(chat.header(addon.name) .. '/goldilox scale <0.75-3 | + | - | auto | reset>  - make the card bigger or smaller (also the A- / A+ buttons)')
        say_chat(chat.header(addon.name) .. '/goldilox min  - collapse to just the word Goldilox (click it, or /goldilox show, to reopen)')
        say_chat(chat.header(addon.name) .. '/goldilox chat  - print the status to chat')
        say_chat(chat.header(addon.name) .. '/goldilox show | hide')
        say_chat(chat.header(addon.name) .. '/goldilox debug  - list goblin-related chat lines (troubleshooting)')
    else
        ui.open = not ui.open
    end
end)
