-- WorldTiers: the Paragon Board window, the Forge, item tooltips, the
-- Paragon bar and the character-sheet panel for mod-world-tiers (WotLK 3.3.5a).
--
-- The server decides everything: what you have taken and what you may take.
-- This file draws what it is sent and asks for what you click, on the "WTP"
-- addon channel (the addon whispers its own player; the server reads that and
-- answers the same way). The board's shape it works out itself, integer for
-- integer the same as the server (WorldTiersGrid.h).
--
-- /paragon (or /wt) opens the board, as does the World Tiers spell's menu.
--   left-click a node: take it          right-click a node: give it back

local PREFIX = "WTP"
local CELL, PAD = 30, 90                  -- one cell's size and the margin, unzoomed
local SIZE = { [0] = 30, [1] = 16, [2] = 23, [3] = 28 }   -- origin, small, notable, keystone
local REVEAL = 3                          -- cells shown around everything you have
local ORIGIN_ICON = "Interface\\Icons\\Spell_Holy_EmpowerChampion"

local WT = {
    stats = {},       -- stat id -> { name, text, icon, per, cap }
    keystones = {},   -- keystone id -> { name, text, icon }
    taken = {},       -- cell id -> true
    totals = {}, pendingTotals = {},
    state = { level = 0, spent = 0, free = 0, xp = 0, xpNext = 1, respec = 0 },
    zoom = 1, receiving = false,
    activeKs = {}, ksSlots = 3,
    buttons = {}, lines = {},
}
_G.WorldTiers = WT

local function Send(msg)
    SendAddonMessage(PREFIX, msg, "WHISPER", UnitName("player"))
end

local function Split(s, sep)
    local out = {}
    for piece in string.gmatch(s .. sep, "(.-)" .. sep) do
        out[#out + 1] = piece
    end
    return out
end

function WT.ActiveCount()
    local n = 0
    for _ in pairs(WT.activeKs) do n = n + 1 end
    return n
end

local function Size(f, w, h)
    f:SetWidth(w)
    f:SetHeight(h)
end
-- ---------------------------------------------------------------------------
-- The board's shape: the same rules, number for number, as the server's
-- WorldTiersGrid.h. Change one, change both.
--
-- Fourteen arms, one per stat (every stat on every board; the class's best first). Each arm: 4 small nodes and a notable, three
-- times; off each notable a branch of 2 empower nodes and a keystone; past the
-- third notable, mastery nodes without end. Node ids: (arm + 1) * 100000 +
-- branch * 10000 + position (branch 0: the main line). The centre is 0.
-- ---------------------------------------------------------------------------

local G = {}
G.ARMS, G.SEGMENT, G.NOTABLES, G.BRANCH, G.MAX_POS = 14, 5, 3, 3, 9999
G.FINITE = G.SEGMENT * G.NOTABLES
G.ORIGIN = 0
G.SECTOR_STAT = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13 }
-- kinds: 0 origin, 1 small, 2 notable, 3 keystone, 4 empower, 5 mastery
G.ORIGIN_KIND, G.SMALL, G.NOTABLE, G.KEYSTONE, G.EMPOWER, G.MASTERY = 0, 1, 2, 3, 4, 5

function G.Id(arm, branch, pos) return (arm + 1) * 100000 + branch * 10000 + pos end
function G.Arm(id) return math.floor(id / 100000) - 1 end
function G.Branch(id) return math.floor(id / 10000) % 10 end
function G.Pos(id) return id % 10000 end

function G.Valid(id)
    if id == 0 then return true end
    local a, b, p = G.Arm(id), G.Branch(id), G.Pos(id)
    if a < 0 or a >= G.ARMS or p < 1 then return false end
    if b == 0 then return p <= G.MAX_POS end
    return b <= G.NOTABLES and p <= G.BRANCH
end

function G.Parent(id)
    local a, b, p = G.Arm(id), G.Branch(id), G.Pos(id)
    if b == 0 then
        if p == 1 then return 0 end
        return G.Id(a, 0, p - 1)
    end
    if p == 1 then return G.Id(a, 0, b * G.SEGMENT) end
    return G.Id(a, b, p - 1)
end

function G.Children(id)
    local out = {}
    if id == 0 then
        for a = 0, G.ARMS - 1 do out[#out + 1] = G.Id(a, 0, 1) end
        return out
    end
    local a, b, p = G.Arm(id), G.Branch(id), G.Pos(id)
    if b == 0 then
        if p < G.MAX_POS then out[#out + 1] = G.Id(a, 0, p + 1) end
        if p % G.SEGMENT == 0 and p <= G.FINITE then out[#out + 1] = G.Id(a, p / G.SEGMENT, 1) end
    elseif p < G.BRANCH then
        out[#out + 1] = G.Id(a, b, p + 1)
    end
    return out
end

local cellCache = {}
function G.Cell(id)
    local c = cellCache[id]
    if c then return c end
    c = { kind = 0, stat = 0, second = 0, keystone = 0, sector = 0 }
    if id ~= 0 and G.Valid(id) then
        local a, b, p = G.Arm(id), G.Branch(id), G.Pos(id)
        c.sector = a
        c.stat = G.SECTOR_STAT[a + 1]
        if b > 0 then
            c.keystone = a * G.NOTABLES + b
            c.kind = (p == G.BRANCH) and G.KEYSTONE or G.EMPOWER
        elseif p % G.SEGMENT == 0 and p <= G.FINITE then
            c.kind = G.NOTABLE
            local n = ((p / G.SEGMENT) % 2 == 1) and ((a + 1) % G.ARMS) or ((a + G.ARMS - 1) % G.ARMS)
            c.second = G.SECTOR_STAT[n + 1]
        else
            c.kind = (p > G.FINITE) and G.MASTERY or G.SMALL
        end
    end
    cellCache[id] = c
    return c
end

-- the stat on each arm of this character's board (a class board, or the general one)
function G.SetWedges(list)
    if #list == G.ARMS then
        G.SECTOR_STAT = list
        cellCache = {}
    end
end

-- every node from the ones you have out to `id`, nearest first (empty if taken)
function G.PathTo(id, taken)
    local path = {}
    local at = id
    while at ~= 0 and not taken[at] do
        table.insert(path, 1, at)
        at = G.Parent(at)
    end
    return path
end
WT.G = G

-- ---------------------------------------------------------------------------
-- Your Paragon bonuses, condensed: one row per stat (percent and flat side by
-- side), the extra effects in short rows, empowered keystones and owned
-- keystones on one line each. Shown in a scrolling list (board side panel and
-- the character sheet's panel) so it never runs into the buttons below.
-- ---------------------------------------------------------------------------

do
    local FLAT = {
        ["strength"] = { "Strength" }, ["agility"] = { "Agility" }, ["stamina"] = { "Stamina" },
        ["intellect"] = { "Intellect" }, ["spirit"] = { "Spirit" }, ["armor"] = { "Armor" },
        ["critical strike rating"] = { "Critical Strike", " rating" }, ["haste rating"] = { "Haste", " rating" },
        ["dodge rating"] = { "Avoidance", " dodge" }, ["strength and agility"] = { "Strength & Agility" },
        ["spell power"] = { "Spell Power" },
    }
    -- the extra effects (past soft caps, keystones, glyphs): short label, and the sign it reads with
    local EXTRA = {
        ["Critical Damage"] = { "Critical Damage" },
        ["shorter cooldowns"] = { "Cooldowns", "-" },
        ["of Leech overhealing kept as a shield"] = { "Overheal to shield" },
        ["less damage taken"] = { "Damage taken", "-" },
        ["mounted speed"] = { "Mounted speed" },
        ["experience"] = { "Experience" },
        ["gold from creatures"] = { "Gold from creatures" },
        ["damage to creatures"] = { "Damage to creatures" },
        ["damage from creatures"] = { "Damage from creatures" },
    }

    -- lines (as the server sends them) -> items: { l, v } rows, { h } headers, { t } text
    function WT.CompactTotals(lines, tail)
        local stats, byLabel, extra, emp, ks, other = {}, {}, {}, {}, {}, {}
        local empPct
        local function Row(label)
            local r = byLabel[label]
            if not r then r = { l = label, vals = {} } byLabel[label] = r stats[#stats + 1] = r end
            return r
        end
        for _, line in ipairs(lines or {}) do
            local pct, name = line:match("^([%+%-][%d%.]+%%) ([%a &]+)$")
            local n, what = line:match("^%+(%d+) (.+)$")
            local ename, epct = line:match("^(.+) empowered: (%+[%d%.]+%%)$")
            local kname = line:match("^Keystone: (.+)$")
            local ov, otext = line:match("^([%+%-]?[%d%.]+%%) (.-) %(.*%)$")
            local flat = n and FLAT[what:lower()]
            if pct then
                local r = Row(name) table.insert(r.vals, 1, pct)
            elseif flat then
                local r = Row(flat[1]) r.vals[#r.vals + 1] = "+" .. n .. (flat[2] or "")
            elseif n and what:find("^attack power") then
                local share = tonumber(what:match("(%d+)%% as spell power"))
                local v = "+" .. n
                if share then v = v .. string.format(" (+%d SP)", math.floor(tonumber(n) * share / 100 + 0.5)) end
                local r = Row("Attack Power") r.vals[#r.vals + 1] = v
            elseif ename then
                emp[#emp + 1] = ename empPct = epct
            elseif kname then
                ks[#ks + 1] = kname
            elseif ov then
                local e = EXTRA[otext]
                local label = e and e[1] or (otext:sub(1, 1):upper() .. otext:sub(2))
                local v = ov
                if e and e[2] == "-" and v:sub(1, 1) ~= "-" then v = "-" .. v:gsub("^%+", "") end
                extra[#extra + 1] = { l = label, v = v }
            else
                other[#other + 1] = line
            end
        end
        local items = {}
        for _, r in ipairs(stats) do items[#items + 1] = { l = r.l, v = table.concat(r.vals, "  ") } end
        if #extra > 0 then
            items[#items + 1] = { h = "Extra effects" }
            for _, r in ipairs(extra) do items[#items + 1] = r end
        end
        if #ks > 0 then items[#items + 1] = { t = "|cffffd100Keystones:|r " .. table.concat(ks, ", "), gap = true } end
        if #emp > 0 then items[#items + 1] = { t = "|cffffd100Empowered (" .. empPct .. "):|r " .. table.concat(emp, ", "), gap = #ks == 0 } end
        local first = true
        for _, line in ipairs(other) do
            items[#items + 1] = { t = line:gsub("^(.- set %(%d+%):)", "|cffa335ee%1|r"), gap = first }
            first = false
        end
        for _, line in ipairs(tail or {}) do items[#items + 1] = { t = line, gap = true } end
        return items
    end

    -- a scrolling list in parent; place it with list.scroll:SetPoint(...). Set(lines, tail) fills it.
    local count = 0
    function WT.TotalsList(parent, width)
        count = count + 1
        local name = "WorldTiersTotals" .. count
        local scroll = CreateFrame("ScrollFrame", name, parent, "UIPanelScrollFrameTemplate")
        local child = CreateFrame("Frame", nil, scroll)
        child:SetWidth(width) child:SetHeight(10)
        scroll:SetScrollChild(child)
        local list = { scroll = scroll, child = child, pool = {}, height = 0 }
        local function FS(i, kind)
            local p = list.pool[i]
            if not p then
                p = {}
                p.left = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                p.left:SetJustifyH("LEFT")
                p.right = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                p.right:SetJustifyH("RIGHT")
                list.pool[i] = p
            end
            return p
        end
        function list:Set(lines, tail)
            local items = WT.CompactTotals(lines, tail)
            if #items == 0 then items = { { t = "Nothing yet. Each Paragon level is a point to spend." } } end
            list:SetItems(items)
        end
        -- items ready made: { l, v } rows, { h } headers (h, and hc a colour), { t } text (gap: space above)
        function list:SetItems(items)
            local y = 0
            for i, it in ipairs(items) do
                local p = FS(i)
                p.left:ClearAllPoints() p.right:ClearAllPoints()
                if it.gap or it.h then y = y + 6 end
                if it.l then
                    p.left:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                    p.left:SetWidth(width * 0.55)
                    p.left:SetText(it.l)
                    p.left:SetTextColor(0.9, 0.9, 0.9)
                    p.right:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                    p.right:SetWidth(width * 0.6)
                    p.right:SetText(it.v)
                    p.right:SetTextColor(0.3, 1, 0.3)
                    p.right:Show()
                    y = y + 13
                else
                    p.left:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
                    p.left:SetWidth(width)
                    p.left:SetText(it.h or it.t)
                    if it.h then
                        local c = it.hc or { 1, 0.82, 0 }
                        p.left:SetTextColor(c[1], c[2], c[3])
                    else
                        p.left:SetTextColor(1, 1, 1)
                    end
                    p.right:Hide()
                    y = y + math.max(13, (p.left:GetHeight() or 13) + 2)
                end
                p.left:Show()
            end
            for i = #items + 1, #list.pool do list.pool[i].left:Hide() list.pool[i].right:Hide() end
            list.height = y
            child:SetHeight(math.max(10, y))
            if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
            list:Fit()
        end
        -- the scroll bar only when it doesn't all fit
        function list:Fit()
            local bar = _G[name .. "ScrollBar"]
            if not bar then return end
            local h = scroll:GetHeight() or 0
            if h > 0 and list.height > h + 1 then bar:Show() else bar:Hide() scroll:SetVerticalScroll(0) end
        end
        scroll:SetScript("OnSizeChanged", function() list:Fit() end)
        return list
    end
end

-- ---------------------------------------------------------------------------
-- The window
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "WorldTiersParagonFrame", UIParent)
Size(frame, 900, 640)
frame:SetPoint("CENTER")
frame:SetFrameStrata("HIGH")
frame:SetToplevel(true)
frame:EnableMouse(true)
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
frame:Hide()
tinsert(UISpecialFrames, "WorldTiersParagonFrame")

local titleBar = CreateFrame("Frame", nil, frame)
titleBar:SetPoint("TOPLEFT", 12, -8)
titleBar:SetPoint("TOPRIGHT", -40, -8)
titleBar:SetHeight(26)
titleBar:EnableMouse(true)
titleBar:RegisterForDrag("LeftButton")
titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", 0, -16)
title:SetText("Paragon Board")

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -6, -6)

local view = CreateFrame("ScrollFrame", nil, frame)
view:SetPoint("TOPLEFT", 20, -44)
Size(view, 620, 574)
local viewBg = view:CreateTexture(nil, "BACKGROUND")
viewBg:SetAllPoints()
viewBg:SetTexture(0, 0, 0, 0.65)

local canvas = CreateFrame("Frame", nil, view)
Size(canvas, 100, 100)
view:SetScrollChild(canvas)

-- side panel
local side = CreateFrame("Frame", nil, frame)
side:SetPoint("TOPLEFT", view, "TOPRIGHT", 14, 0)
side:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 20)

local pointsText = side:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
pointsText:SetPoint("TOPLEFT", 0, 0)
pointsText:SetJustifyH("LEFT")

local levelText = side:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
levelText:SetPoint("TOPLEFT", pointsText, "BOTTOMLEFT", 0, -6)
levelText:SetWidth(220)
levelText:SetJustifyH("LEFT")

local totalsHeader = side:CreateFontString(nil, "OVERLAY", "GameFontNormal")
totalsHeader:SetPoint("TOPLEFT", levelText, "BOTTOMLEFT", 0, -14)
totalsHeader:SetText("Your Paragon bonuses")

-- condensed and scrolling: ends above the keystone button and loadouts
local totalsList = WT.TotalsList(side, 200)
totalsList.scroll:SetPoint("TOPLEFT", totalsHeader, "BOTTOMLEFT", 0, -6)
totalsList.scroll:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", -24, 236)

local hint = side:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
hint:SetPoint("BOTTOMLEFT", 0, 34)
hint:SetWidth(220)
hint:SetJustifyH("LEFT")
hint:SetText("Drag to move, mouse wheel to zoom. Left-click a node next to yours to take it; right-click to give it back for free. Each stat has its own direction: head out through yours. Keystones (purple) are further out.")

local resetButton = CreateFrame("Button", nil, side, "UIPanelButtonTemplate")
Size(resetButton, 100, 24)
resetButton:SetPoint("BOTTOMLEFT", 0, 0)
resetButton:SetText("Reset tree")

local centerButton = CreateFrame("Button", nil, side, "UIPanelButtonTemplate")
Size(centerButton, 100, 24)
centerButton:SetPoint("LEFT", resetButton, "RIGHT", 8, 0)
centerButton:SetText("Centre")

StaticPopupDialogs["WORLDTIERS_RESET_TREE"] = {
    text = "Reset your whole Paragon Board for %s gold? Every point comes back.\n\n(Right-clicking a node gives back just that one, for free.)",
    button1 = YES, button2 = NO,
    OnAccept = function() Send("R") end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}
resetButton:SetScript("OnClick", function()
    StaticPopup_Show("WORLDTIERS_RESET_TREE", tostring(WT.state.respec))
end)

-- A rotated line texture between two points (relative to the canvas's
-- BOTTOMLEFT), the way Blizzard's taxi map draws its routes.
local LINEFACTOR_2 = (128 / 126) / 2
local function DrawLine(T, C, sx, sy, ex, ey, w)
    T:SetTexture("Interface\\TaxiFrame\\UI-Taxi-Line")
    local dx, dy = ex - sx, ey - sy
    local cx, cy = (sx + ex) / 2, (sy + ey) / 2
    if dx < 0 then dx, dy = -dx, -dy end
    local l = math.sqrt(dx * dx + dy * dy)
    T:ClearAllPoints()
    if l == 0 then
        T:SetTexCoord(0, 0, 0, 0, 0, 0, 0, 0)
        T:SetPoint("BOTTOMLEFT", C, "BOTTOMLEFT", cx, cy)
        T:SetPoint("TOPRIGHT", C, "BOTTOMLEFT", cx, cy)
        return
    end
    local s, c = -dy / l, dx / l
    local sc = s * c
    local Bwid, Bhgt, BLx, BLy, TLx, TLy, TRx, TRy, BRx, BRy
    if dy >= 0 then
        Bwid = ((l * c) - (w * s)) * LINEFACTOR_2
        Bhgt = ((w * c) - (l * s)) * LINEFACTOR_2
        BLx, BLy, BRy = (w / l) * sc, s * s, (l / w) * sc
        BRx, TLx, TLy, TRx = 1 - BLy, BLy, 1 - BRy, 1 - BLx
        TRy = BRx
    else
        Bwid = ((l * c) + (w * s)) * LINEFACTOR_2
        Bhgt = ((w * c) + (l * s)) * LINEFACTOR_2
        BLx, BLy, BRx = s * s, -(l / w) * sc, 1 + (w / l) * sc
        BRy, TLx, TLy, TRy = BLx, 1 - BRx, 1 - BLx, 1 - BLy
        TRx = TLy
    end
    T:SetTexCoord(TLx, TLy, BLx, BLy, TRx, TRy, BRx, BRy)
    T:SetPoint("BOTTOMLEFT", C, "BOTTOMLEFT", cx - Bwid, cy - Bhgt)
    T:SetPoint("TOPRIGHT", C, "BOTTOMLEFT", cx + Bwid, cy + Bhgt)
end
-- ---------------------------------------------------------------------------
-- The character sheet's World Tiers panel, in three tabs (0.31):
--   Paragon  the board's stats, extra effects, glyphs and keystones
--   Gear     class sets, uniques, affix sets and runes you wear
--   Powers   your Ascendancy and its Mastery, Signature Keystone, Tier Key, Gold Reserve
-- ---------------------------------------------------------------------------

do
local panel = CreateFrame("Frame", "WorldTiersCharacterPanel", PaperDollFrame)
panel:SetPoint("TOPLEFT", CharacterFrame, "TOPRIGHT", -34, -14)
Size(panel, 246, 80)
panel:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
panel:SetBackdropColor(0, 0, 0, 0.85)
local panelTitle = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
panelTitle:SetPoint("TOPLEFT", 10, -10)

-- the tabs
local TABS = { "Paragon", "Gear", "Powers" }
local tabButtons = {}
local function CurrentTab()
    local t = WorldTiersCharDB and WorldTiersCharDB.panelTab
    return (t == 2 or t == 3) and t or 1
end
for i, name in ipairs(TABS) do
    local b = CreateFrame("Button", "WorldTiersPanelTab" .. i, panel, "UIPanelButtonTemplate")
    Size(b, 72, 18)
    b:SetPoint("TOPLEFT", 8 + (i - 1) * 76, -28)
    b:SetText(name)
    tabButtons[i] = b
end

local PANEL_MAX = 330   -- taller than this and the list scrolls
local panelList = WT.TotalsList(panel, 210)
panelList.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -52)
panelList.scroll:SetWidth(210)
panelList.scroll:SetHeight(40)
local panelButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
Size(panelButton, 110, 20)
panelButton:SetPoint("BOTTOMLEFT", 8, 8)
panelButton:SetText("Paragon Board")
panelButton:SetScript("OnClick", function() frame:Show() end)

-- colours: set pieces green, uniques orange (the same as their tooltips and glow)
local SET_HEX, UNIQUE_HEX = "|cff1eff96", "|cffff8000"
WT.SET_COLOR, WT.UNIQUE_COLOR = { 0.12, 1, 0.59 }, { 1, 0.5, 0 }

-- the Gear tab: class sets, then uniques, affix sets, runes
local function GearItems()
    local items = {}
    local by = { S = {}, U = {}, A = {}, R = {} }
    for _, g in ipairs(WT.gearLines or {}) do
        if by[g.kind] then table.insert(by[g.kind], g.text) end
    end
    if #by.S > 0 then
        items[#items + 1] = { h = "Class Sets", hc = WT.SET_COLOR }
        for _, line in ipairs(by.S) do
            if line:match("%(%d/4%)$") then
                items[#items + 1] = { t = SET_HEX .. line .. "|r", gap = true }
            elseif line:find("^|cff808080") then
                items[#items + 1] = { t = line .. "|r" }
            else
                items[#items + 1] = { t = "|cffb0ffd0" .. line .. "|r" }
            end
        end
    end
    if #by.U > 0 then
        items[#items + 1] = { h = "Uniques", hc = WT.UNIQUE_COLOR, }
        for _, line in ipairs(by.U) do
            -- "[Unique: Tree] Name: what it does" -> the name in orange, then what it does
            local name, what = line:match("^%[Unique: [^%]]+%] ([^:]+): (.*)$")
            items[#items + 1] = { t = name and (UNIQUE_HEX .. name .. ":|r " .. what) or line, gap = true }
        end
    end
    if #by.A > 0 then
        items[#items + 1] = { h = "Affix Sets" }
        for _, line in ipairs(by.A) do items[#items + 1] = { t = line, gap = true } end
    end
    if #by.R > 0 then
        items[#items + 1] = { h = "Runes" }
        for _, line in ipairs(by.R) do items[#items + 1] = { t = line, gap = true } end
    end
    if #items == 0 then
        items[1] = { t = "No set pieces, uniques, affix sets or runes worn yet. Wear three pieces whose affixes share a family (Inferno, Frost...) for an affix set." }
    end
    return items
end

-- the Powers tab
local function PowerItems()
    local items = {}
    local asc, sig
    for _, p in ipairs(WT.powerLines or {}) do
        if p.kind == "A" then asc = p.text elseif p.kind == "K" then sig = p.text end
    end
    items[#items + 1] = { h = "Ascendancy", hc = { 1, 0.5, 0 } }
    if asc then
        local f = Split(asc, "|")
        local rank, picks = tonumber(f[2]) or 0, f[3] or ""
        items[#items + 1] = { t = "|cffff8000" .. (f[1] or "?") .. "|r  -  Mastery " .. rank .. "/5" }
        local chosen = {}
        for r = 1, math.min(5, rank) do
            local o = tonumber(picks:sub(r, r)) or 0
            local m = WT.ASC_MASTERY and WT.ASC_MASTERY[r] and WT.ASC_MASTERY[r][o]
            chosen[#chosen + 1] = m and m[1] or ("|cff808080rank " .. r .. ": not chosen|r")
        end
        if #chosen > 0 then items[#items + 1] = { t = "Mastery: " .. table.concat(chosen, ", ") } end
    else
        items[#items + 1] = { t = "|cff808080None chosen. From level 80: World Tiers window, Overview (or /ascend).|r" }
    end
    items[#items + 1] = { h = "Signature Keystone", hc = { 0.75, 0.5, 1 } }
    items[#items + 1] = { t = sig and ("|cffbf80ff" .. sig .. "|r") or "|cff808080None chosen. From level 10: World Tiers window, Overview.|r" }
    if WT.key and WT.key.text ~= "" then
        items[#items + 1] = { h = "Tier Key", hc = { 0.64, 0.21, 0.93 } }
        items[#items + 1] = { t = WT.key.text .. (WT.key.best > 0 and ("  (best +" .. WT.key.best .. ")") or "") }
    end
    if WT.reserve and #WT.reserve > 4 and WT.GoldFromCopperString then
        items[#items + 1] = { h = "Gold Reserve" }
        items[#items + 1] = { t = "|cffffd100" .. WT.GoldFromCopperString(WT.reserve) .. "|r" }
    end
    return items
end

local function RefreshPanel()
    local s = WT.state
    panelTitle:SetText(string.format("Paragon %d%s", s.level, s.free > 0 and string.format("  |cff20ff20(%d free)|r", s.free) or ""))
    local tab = CurrentTab()
    for i, b in ipairs(tabButtons) do
        if i == tab then b:LockHighlight() b:SetText("|cffffffff" .. TABS[i] .. "|r")
        else b:UnlockHighlight() b:SetText(TABS[i]) end
    end
    if tab == 1 then
        panelList:Set(WT.totals)
    elseif tab == 2 then
        panelList:SetItems(GearItems())
    else
        panelList:SetItems(PowerItems())
    end
    local h = math.min(PANEL_MAX, math.max(20, panelList.height))
    panelList.scroll:SetHeight(h)
    panelList.scroll:SetVerticalScroll(0)
    panelList:Fit()
    Size(panel, 246, h + 90)
end
for i, b in ipairs(tabButtons) do
    b:SetScript("OnClick", function()
        WorldTiersCharDB = WorldTiersCharDB or {}
        WorldTiersCharDB.panelTab = i
        RefreshPanel()
    end)
end
panel:SetScript("OnShow", function() Send("H") RefreshPanel() end)
WT.RefreshPanel = RefreshPanel

-- gear changed while the panel is open: ask again (once, a moment later)
local gearWatch = CreateFrame("Frame")
gearWatch:RegisterEvent("UNIT_INVENTORY_CHANGED")
gearWatch:SetScript("OnEvent", function(self, event, unit)
    if unit == "player" and panel:IsVisible() then
        self.wait = 0.5
        self:Show()
    end
end)
gearWatch:Hide()
gearWatch:SetScript("OnUpdate", function(self, elapsed)
    self.wait = (self.wait or 0) - elapsed
    if self.wait <= 0 then
        self:Hide()
        if panel:IsVisible() then Send("H") end
    end
end)
end
-- ---------------------------------------------------------------------------
-- The board: eleven arms, drawn as spokes around the centre
-- ---------------------------------------------------------------------------

local Draw, OnMessage, Reveal, Blocker, RefundBlocker
do

local R0, STEP, BSTEP = 80, 44, 40          -- first node's distance, main-line spacing, branch spacing (unzoomed)
local TILT = 0.75                          -- how far a branch leans off its arm (radians)
local NODE = { [0] = 36, [1] = 18, [2] = 28, [3] = 36, [4] = 20, [5] = 16 }   -- by kind
local MASTERY_AHEAD = 3                    -- mastery nodes shown past the furthest you have
local ARM_COLOR = {                        -- by stat (ParagonStat)
    [0] = { 0.85, 0.25, 0.2 }, [1] = { 0.3, 0.85, 0.35 }, [2] = { 0.95, 0.7, 0.2 }, [3] = { 0.35, 0.55, 1 },
    [4] = { 0.55, 0.85, 1 }, [5] = { 1, 0.45, 0.15 }, [6] = { 1, 0.85, 0.2 }, [7] = { 0.4, 1, 0.85 },
    [8] = { 0.7, 0.7, 0.75 }, [9] = { 0.8, 0.2, 0.45 }, [10] = { 0.45, 1, 0.5 }, [11] = { 0.9, 0.9, 0.5 },
    [12] = { 0.85, 0.65, 0.4 }, [13] = { 0.75, 0.5, 0.25 }, [14] = { 0.9, 0.3, 0.9 }, [15] = { 0.9, 0.5, 0.3 },
}
local ROMAN = { "I", "II", "III" }

WT.zoom = 0.75
WT.search = ""
local furthest = {}      -- arm -> furthest main-line position you have
local radius = 600       -- the canvas's half size, unzoomed (grows with mastery)

local function MainShown(arm)
    return math.max(G.FINITE + MASTERY_AHEAD, (furthest[arm] or 0) + MASTERY_AHEAD)
end

local function Measure()
    furthest = {}
    for id in pairs(WT.taken) do
        if G.Branch(id) == 0 then
            local a = G.Arm(id)
            furthest[a] = math.max(furthest[a] or 0, G.Pos(id))
        end
    end
    local far = 0
    for a = 0, G.ARMS - 1 do far = math.max(far, MainShown(a)) end
    radius = R0 + (far - 1) * STEP + 120
end

-- a node's place, unzoomed, from the centre (x right, y up)
local function World(id)
    if id == 0 then return 0, 0 end
    local a, b, p = G.Arm(id), G.Branch(id), G.Pos(id)
    local t = a * 2 * math.pi / G.ARMS
    if b == 0 then
        local r = R0 + (p - 1) * STEP
        return math.sin(t) * r, math.cos(t) * r
    end
    local nx, ny = World(G.Id(a, 0, b * G.SEGMENT))
    local side = (b % 2 == 1) and 1 or -1
    local bt = t + side * TILT
    local d = p * BSTEP
    return nx + math.sin(bt) * d, ny + math.cos(bt) * d
end

-- canvas coordinates, unzoomed (origin top-left, y down)
local function Pos(id)
    local x, y = World(id)
    return radius + x, radius - y
end
local function CanvasW() return 2 * radius end
local function CanvasH() return 2 * radius end

local function Takeable(id)
    local up = G.Parent(id)
    return up == 0 or WT.taken[up]
end

Blocker = function(id)
    if id == 0 or WT.taken[id] then return "taken" end
    if not Takeable(id) then return "Take the node before it first (shift-click takes the whole path)." end
    if WT.state.free <= 0 then return "No free points: each Paragon level gives one." end
    return nil
end

RefundBlocker = function(id)
    if not WT.taken[id] then return "not taken" end
    for _, kid in ipairs(G.Children(id)) do
        if WT.taken[kid] then return "Nodes further out need it: give those back first." end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Scrolling and zoom
-- ---------------------------------------------------------------------------


local function ClampScroll(h, v)
    local maxH = math.max(0, CanvasW() * WT.zoom - view:GetWidth())
    local maxV = math.max(0, CanvasH() * WT.zoom - view:GetHeight())
    view:SetHorizontalScroll(math.max(0, math.min(h, maxH)))
    view:SetVerticalScroll(math.max(0, math.min(v, maxV)))
    Draw()
end

local function CentreOn(wx, wy)
    ClampScroll((radius + wx) * WT.zoom - view:GetWidth() / 2, (radius - wy) * WT.zoom - view:GetHeight() / 2)
end

-- the board point at the middle of the view, to keep it there through changes
local function Middle()
    local z = WT.zoom
    local px = (view:GetHorizontalScroll() + view:GetWidth() / 2) / z
    local py = (view:GetVerticalScroll() + view:GetHeight() / 2) / z
    return px - radius, radius - py
end

local function SetZoom(z)
    local mx, my = Middle()
    WT.zoom = math.max(0.25, math.min(1.6, z))
    Size(canvas, CanvasW() * WT.zoom, CanvasH() * WT.zoom)
    WT.lastDraw = nil
    CentreOn(mx, my)
end

local drag
view:EnableMouse(true)
view:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    local x, y = GetCursorPosition()
    local s = self:GetEffectiveScale()
    drag = { x = x / s, y = y / s, h = self:GetHorizontalScroll(), v = self:GetVerticalScroll() }
end)
view:SetScript("OnMouseUp", function() drag = nil end)
view:SetScript("OnHide", function() drag = nil end)
local lastH, lastV
view:SetScript("OnUpdate", function(self)
    if drag then
        if not IsMouseButtonDown("LeftButton") then drag = nil return end
        local x, y = GetCursorPosition()
        local s = self:GetEffectiveScale()
        local h, v = drag.h - (x / s - drag.x), drag.v + (y / s - drag.y)
        if h ~= lastH or v ~= lastV then
            lastH, lastV = h, v
            ClampScroll(h, v)
        end
    end
end)

view:EnableMouseWheel(true)
view:SetScript("OnMouseWheel", function(self, delta)
    SetZoom(WT.zoom * (delta > 0 and 1.2 or 1 / 1.2))
end)

centerButton:SetScript("OnClick", function() SetZoom(0.75) CentreOn(0, 0) end)

local overviewButton = CreateFrame("Button", nil, side, "UIPanelButtonTemplate")
Size(overviewButton, 100, 24)
overviewButton:SetPoint("BOTTOMLEFT", resetButton, "TOPLEFT", 0, 4)
overviewButton:SetText("Overview")
overviewButton:SetScript("OnClick", function()
    SetZoom(math.max(0.25, math.min(view:GetWidth(), view:GetHeight()) / CanvasW()))
    CentreOn(0, 0)
end)

-- search: light up every node of a stat, or a keystone, by name
local searchBox = CreateFrame("EditBox", "WorldTiersBoardSearch", side, "InputBoxTemplate")
Size(searchBox, 100, 20)
searchBox:SetPoint("LEFT", overviewButton, "RIGHT", 14, 0)
searchBox:SetAutoFocus(false)
searchBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Find", 1, 0.82, 0)
    GameTooltip:AddLine("Type a stat (crit, movement) or a keystone's name: every node that matches lights up.", 1, 1, 1, true)
    GameTooltip:Show()
end)
searchBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
searchBox:SetScript("OnTextChanged", function(self)
    WT.search = (self:GetText() or ""):lower()
    WT.lastDraw = nil
    Draw()
end)
searchBox:SetScript("OnEscapePressed", function(self) self:SetText("") self:ClearFocus() end)
searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

hint:ClearAllPoints()
hint:SetPoint("BOTTOMLEFT", overviewButton, "TOPLEFT", 0, 6)
hint:SetText("Click: take. Shift-click: take the whole path. Right-click: give back (free). Empower nodes (purple) strengthen the keystone they lead to.")

-- ---------------------------------------------------------------------------
-- What a node gives, and what you have from the board (before keystones and caps)
-- ---------------------------------------------------------------------------

local function Per(stat) local st = WT.stats[stat] return tonumber(st and st.per) or 0 end
local function Flat(stat) local st = WT.stats[stat] return tonumber(st and st.flat) or 0 end
local function KeystoneAt(c) return WT.keystones[c.keystone] end

-- { stat -> percent }, { stat -> flat } a node gives
local function Gives(id)
    local c = G.Cell(id)
    local pct, flat = {}, {}
    if c.kind == G.SMALL or c.kind == G.MASTERY then
        pct[c.stat], flat[c.stat] = Per(c.stat), Flat(c.stat)
    elseif c.kind == G.NOTABLE then
        pct[c.stat], flat[c.stat] = 3 * Per(c.stat), 3 * Flat(c.stat)
        pct[c.second] = (pct[c.second] or 0) + Per(c.second)
    elseif c.kind == G.EMPOWER then
        local k = KeystoneAt(c)
        pct[c.stat] = Per(c.stat)
        flat[c.stat] = (k and k.emp) and Flat(c.stat) or 2 * Flat(c.stat)
    end
    return pct, flat
end

local function BoardTotal(stat)
    local total = 0
    for id in pairs(WT.taken) do
        local pct = Gives(id)
        total = total + (pct[stat] or 0)
    end
    return total
end

local function Num(v) return tostring(math.floor(v * 100 + 0.5) / 100) end

local FLAT_NAME = { [0] = "Strength", [1] = "Agility", [2] = "Stamina", [3] = "Intellect", [4] = "Spirit",
    [5] = "attack power", [6] = "crit rating", [7] = "haste rating", [8] = "armor", [10] = "spell power",
    [12] = "dodge rating", [15] = "Strength and Agility" }

local function AddGives(id)
    local pct, flat = Gives(id)
    for stat, v in pairs(pct) do
        local st = WT.stats[stat]
        if st and v > 0 then
            local have = BoardTotal(stat)
            local after = WT.taken[id] and have or have + v
            GameTooltip:AddDoubleLine(string.format("+%s%s", Num(v), st.text or ""), string.format("board: %s%% > %s%%", Num(have), Num(after)),
                0.4, 1, 0.4, 0.6, 0.6, 0.6)
        end
    end
    for stat, v in pairs(flat) do
        if v > 0 and FLAT_NAME[stat] then
            GameTooltip:AddLine(string.format("+%s %s", Num(v), FLAT_NAME[stat]), 0.4, 1, 0.4)
        end
    end
end

local function EmpowerCount(c)
    local n = 0
    for p = 1, G.BRANCH - 1 do
        if WT.taken[G.Id(c.sector, c.keystone - c.sector * G.NOTABLES, p)] then n = n + 1 end
    end
    return n
end

local function ShowTooltip(self)
    local id = self.id
    local c = G.Cell(id)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if id == 0 then
        GameTooltip:AddLine("Paragon", 1, 0.82, 0)
        GameTooltip:AddLine("The centre: every arm starts here. Each arm is one stat; its branches lead to keystones.", 1, 1, 1, true)
        GameTooltip:Show()
        return
    end
    local st = WT.stats[c.stat]
    if c.kind == G.KEYSTONE then
        local k = KeystoneAt(c)
        GameTooltip:AddLine("Keystone: " .. (k and k.name or "?"), 0.75, 0.4, 1)
        if k then GameTooltip:AddLine(k.text, 1, 1, 1, true) end
        if k and k.emp then
            local n = EmpowerCount(c)
            GameTooltip:AddLine(string.format("Empowered: +%s%% (%d of %d empower nodes before it)", Num(n * (WT.empowerPct or 15)), n, G.BRANCH - 1),
                n > 0 and 0.4 or 0.6, n > 0 and 1 or 0.6, n > 0 and 0.4 or 0.6, true)
        end
        if WT.taken[id] and k then
            if WT.activeKs[k.ks] then
                GameTooltip:AddLine("Active. Shift-click to switch it off.", 0.2, 1, 0.2, true)
            else
                GameTooltip:AddLine(string.format("Not active (%d of %d slots in use). Shift-click to switch it on.",
                    WT.ActiveCount(), WT.ksSlots or 3), 1, 0.5, 0.2, true)
            end
        end
    elseif c.kind == G.EMPOWER then
        local k = KeystoneAt(c)
        GameTooltip:AddLine("Empower: " .. (k and k.name or "?"), 0.85, 0.55, 1)
        AddGives(id)
        if k and k.emp then
            GameTooltip:AddLine(string.format("+%s%% to %s's numbers (damage, healing, shields...)", Num(WT.empowerPct or 15), k.name), 0.85, 0.55, 1, true)
        else
            GameTooltip:AddLine("This keystone has no numbers to grow, so this node gives double flat stat instead.", 0.7, 0.7, 0.7, true)
        end
    elseif c.kind == G.NOTABLE then
        GameTooltip:AddLine(string.format("Notable: %s %s", st and st.name or "?", ROMAN[G.Pos(id) / G.SEGMENT] or ""), 1, 0.5, 0)
        AddGives(id)
        if WT.GlyphNodeTooltip then WT.GlyphNodeTooltip(id) end
    else
        GameTooltip:AddLine((c.kind == G.MASTERY and "Mastery: " or "") .. (st and st.name or "?"), 1, 1, 1)
        AddGives(id)
        if c.kind == G.MASTERY then GameTooltip:AddLine("Mastery nodes go on without end: no point is ever wasted.", 0.6, 0.6, 0.6, true) end
        if st and tonumber(st.cap) and tonumber(st.cap) > 0 then
            GameTooltip:AddLine(string.format("Slows down past %s%%, but every point still counts.", st.cap), 0.6, 0.6, 0.6, true)
        end
    end
    GameTooltip:AddLine(" ")
    if WT.taken[id] then
        local why = RefundBlocker(id)
        GameTooltip:AddLine("Taken", 1, 0.82, 0)
        if why then GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
        else GameTooltip:AddLine("Right-click to give it back (free)", 0.6, 0.8, 1) end
    else
        local why = Blocker(id)
        if not why then
            GameTooltip:AddLine("Click to take it (1 point)", 0.2, 1, 0.2)
        elseif not Takeable(id) then
            local path = G.PathTo(id, WT.taken)
            local ok = #path <= WT.state.free
            GameTooltip:AddLine(string.format("Shift-click: take the path here (%d point%s)", #path, #path == 1 and "" or "s"),
                ok and 0.2 or 1, ok and 1 or 0.3, ok and 0.2 or 0.3, true)
        else
            GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
        end
    end
    GameTooltip:Show()
end

local function OnClickNode(self, button)
    local id = self.id
    if id == 0 then return end
    if button == "RightButton" then
        if not WT.taken[id] then return end
        local why = RefundBlocker(id)
        if why then UIErrorsFrame:AddMessage(why, 1, 0.2, 0.2) return end
        Send("U:" .. id)
        return
    end
    if WT.taken[id] then
        local c = G.Cell(id)
        local k = c.kind == G.KEYSTONE and KeystoneAt(c)
        if k and IsShiftKeyDown() then Send((WT.activeKs[k.ks] and "KD:" or "KA:") .. k.ks) end
        return
    end
    if IsShiftKeyDown() and not Takeable(id) then
        local path = G.PathTo(id, WT.taken)
        if #path > WT.state.free then
            UIErrorsFrame:AddMessage(string.format("That path takes %d points; you have %d.", #path, WT.state.free), 1, 0.2, 0.2)
            return
        end
        Send("AP:" .. id)
        return
    end
    local why = Blocker(id)
    if why then UIErrorsFrame:AddMessage(why, 1, 0.2, 0.2) return end
    Send("A:" .. id)
end

local function NewButton()
    local b = CreateFrame("Button", nil, canvas)
    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetTexture("Interface\\Buttons\\WHITE8X8")
    b.border:SetAllPoints()
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetPoint("TOPLEFT", 2, -2)
    b.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.glow = b:CreateTexture(nil, "OVERLAY")
    b.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    b.glow:SetBlendMode("ADD")
    b.glow:SetPoint("CENTER")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", OnClickNode)
    b:SetScript("OnEnter", ShowTooltip)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function NewLine() return canvas:CreateTexture(nil, "BORDER") end
WT.ClickForTest = function(id) OnClickNode({ id = id }, "LeftButton") end
WT.TooltipForTest = function(id) ShowTooltip({ id = id }) end

local function IconFor(id, c)
    if id == 0 then return ORIGIN_ICON end
    if c.kind == G.KEYSTONE then
        local k = KeystoneAt(c)
        return "Interface\\Icons\\" .. (k and k.icon or "INV_Misc_QuestionMark")
    end
    local st = WT.stats[c.stat]
    return "Interface\\Icons\\" .. (st and st.icon or "INV_Misc_QuestionMark")
end

local function Matches(c)
    local q = WT.search
    if q == "" then return false end
    if c.kind == G.KEYSTONE or c.kind == G.EMPOWER then
        local k = KeystoneAt(c)
        if k and k.name and k.name:lower():find(q, 1, true) then return true end
        if c.kind == G.KEYSTONE then return false end
    end
    for stat in pairs((Gives(c.id))) do
        local st = WT.stats[stat]
        if st and st.name and st.name:lower():find(q, 1, true) then return true end
    end
    return false
end

-- every node to draw: the centre, each arm's main line (mastery a little past
-- your furthest), and every branch
local function Shown()
    local list = { 0 }
    for a = 0, G.ARMS - 1 do
        for p = 1, MainShown(a) do list[#list + 1] = G.Id(a, 0, p) end
        for b = 1, G.NOTABLES do
            for p = 1, G.BRANCH do list[#list + 1] = G.Id(a, b, p) end
        end
    end
    return list
end

-- labels (each arm's stat) and rings (where each notable sits)
local labels, dots = {}, {}

Draw = function()
    if not frame:IsShown() then return end
    local z = WT.zoom
    local h, v = view:GetHorizontalScroll() / z, view:GetVerticalScroll() / z
    local w, hh = view:GetWidth() / z, view:GetHeight() / z
    local key = table.concat({ math.floor(h / 40), math.floor(v / 40), z, WT.version or 0, WT.search }, ":")
    if key == WT.lastDraw then return end
    WT.lastDraw = key
    local margin = 60
    local function inView(px, py) return px > h - margin and px < h + w + margin and py > v - margin and py < v + hh + margin end

    -- rings at each notable's distance
    local nd = 0
    for n = 1, G.NOTABLES do
        local r = R0 + (n * G.SEGMENT - 1) * STEP
        local count = math.floor(r / 9)
        for i = 1, count do
            local t = i * 2 * math.pi / count
            local px, py = radius + math.sin(t) * r, radius - math.cos(t) * r
            if inView(px, py) then
                nd = nd + 1
                local d = dots[nd]
                if not d then
                    d = canvas:CreateTexture(nil, "BACKGROUND")
                    d:SetTexture("Interface\\Buttons\\WHITE8X8")
                    dots[nd] = d
                end
                local s = math.max(1, 2 * z)
                Size(d, s, s)
                d:ClearAllPoints()
                d:SetPoint("CENTER", canvas, "TOPLEFT", px * z, -py * z)
                d:SetVertexColor(0.8, 0.7, 0.4, 0.18)
                d:Show()
            end
        end
    end
    for i = nd + 1, #dots do dots[i]:Hide() end

    -- arm labels, between the first and second ring
    for a = 0, G.ARMS - 1 do
        local l = labels[a]
        if not l then
            l = canvas:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            labels[a] = l
        end
        local stat = G.SECTOR_STAT[a + 1]
        local st = WT.stats[stat]
        local t = a * 2 * math.pi / G.ARMS + 0.24
        local r = R0 + 6.5 * STEP
        local px, py = radius + math.sin(t) * r, radius - math.cos(t) * r
        if z >= 0.45 and st and inView(px, py) then
            local col = ARM_COLOR[stat] or { 1, 1, 1 }
            l:SetText(st.name or "")
            l:SetTextColor(col[1], col[2], col[3], 0.9)
            l:ClearAllPoints()
            l:SetPoint("CENTER", canvas, "TOPLEFT", px * z, -py * z)
            l:Show()
        else
            l:Hide()
        end
    end

    local nb, nl = 0, 0
    local canvasH = CanvasH()
    local function line(aid, bid, r, g, b2, a)
        local ax, ay = Pos(aid)
        local bx, by = Pos(bid)
        if not inView(ax, ay) and not inView(bx, by) then return end
        nl = nl + 1
        local t = WT.lines[nl]
        if not t then t = NewLine() WT.lines[nl] = t end
        DrawLine(t, canvas, ax * z, (canvasH - ay) * z, bx * z, (canvasH - by) * z, math.max(6, 14 * z))
        t:SetVertexColor(r, g, b2, a)
        t:Show()
    end

    for _, id in ipairs(Shown()) do
        local c = G.Cell(id)
        c.id = id
        local taken = id == 0 or WT.taken[id]
        local col = ARM_COLOR[c.stat] or { 0.6, 0.6, 0.6 }
        if id ~= 0 then
            local up = G.Parent(id)
            local upTaken = up == 0 or WT.taken[up]
            if taken then line(up, id, 1, 0.82, 0, 0.95)
            elseif upTaken then line(up, id, 0.35, 0.9, 0.35, 0.6)
            else line(up, id, col[1] * 0.6, col[2] * 0.6, col[3] * 0.6, 0.35) end
        end
        local px, py = Pos(id)
        if inView(px, py) then
            nb = nb + 1
            local b = WT.buttons[nb]
            if not b then b = NewButton() WT.buttons[nb] = b end
            b.id = id
            local s = math.max(6, NODE[c.kind] * z)
            Size(b, s, s)
            b:ClearAllPoints()
            b:SetPoint("CENTER", canvas, "TOPLEFT", px * z, -py * z)
            b.icon:SetTexture(IconFor(id, c))
            local k = taken and c.kind == G.KEYSTONE and KeystoneAt(c)
            if k and not WT.activeKs[k.ks] then
                b.border:SetVertexColor(0.55, 0.35, 0.8, 1)   -- a keystone you own that is switched off
                b.icon:SetDesaturated(true)
                b:SetAlpha(1)
            elseif taken then
                b.border:SetVertexColor(1, 0.82, 0, 1)
                b.icon:SetDesaturated(false)
                b:SetAlpha(1)
            elseif Blocker(id) == nil then
                b.border:SetVertexColor(0.25, 0.95, 0.25, 1)
                b.icon:SetDesaturated(false)
                b:SetAlpha(1)
            else
                if c.kind == G.KEYSTONE then b.border:SetVertexColor(0.6, 0.3, 0.85, 1)
                elseif c.kind == G.EMPOWER then b.border:SetVertexColor(0.5, 0.3, 0.65, 1)
                elseif c.kind == G.NOTABLE then b.border:SetVertexColor(col[1] * 0.8, col[2] * 0.8, col[3] * 0.8, 1)
                else b.border:SetVertexColor(col[1] * 0.35, col[2] * 0.35, col[3] * 0.35, 1) end
                b.icon:SetDesaturated(true)
                b:SetAlpha((c.kind == G.KEYSTONE or c.kind == G.NOTABLE) and 0.9 or 0.65)
            end
            if Matches(c) or (WT.glyphHi and WT.glyphHi[id]) then
                if WT.glyphHi and WT.glyphHi[id] then b.glow:SetVertexColor(0.75, 0.4, 1) else b.glow:SetVertexColor(0.3, 0.9, 1) end
                Size(b.glow, s * 1.9, s * 1.9)
                b.glow:Show()
            else
                b.glow:Hide()
            end
            b:Show()
        end
    end
    for i = nb + 1, #WT.buttons do WT.buttons[i]:Hide() end
    for i = nl + 1, #WT.lines do WT.lines[i]:Hide() end
    if WT.GlyphDraw then WT.GlyphDraw(z, Pos, inView) end
end

local function RefreshSide()
    local s = WT.state
    pointsText:SetText(string.format("%d point%s free", s.free, s.free == 1 and "" or "s"))
    levelText:SetText(string.format("Paragon level %d - %d on the board\nNext level: %d / %d XP", s.level, s.spent, s.xp, s.xpNext))
    totalsList:Set(WT.totals)
    if WT.RefreshPanel then WT.RefreshPanel() end
end

-- a change to what is taken: measure again, keep the view where it was
local function Rebuild()
    WT.version = (WT.version or 0) + 1
    local mx, my = Middle()
    Measure()
    Size(canvas, CanvasW() * WT.zoom, CanvasH() * WT.zoom)
    CentreOn(mx, my)
    RefreshSide()
end
Reveal = Measure

-- ---------------------------------------------------------------------------
-- What the server says
-- ---------------------------------------------------------------------------

OnMessage = function(msg)
    local cmd, rest = msg:match("^([^|]+)|?(.*)$")
    if not cmd then return end
    if cmd == "S" then
        local f = Split(rest, "|")
        local s = WT.state
        s.level, s.spent, s.free = tonumber(f[1]) or 0, tonumber(f[2]) or 0, tonumber(f[3]) or 0
        s.xp, s.xpNext, s.respec = tonumber(f[4]) or 0, tonumber(f[5]) or 1, tonumber(f[6]) or 0
    elseif cmd == "T" then
        WT.pendingTotals[#WT.pendingTotals + 1] = rest
    elseif cmd == "TG" or cmd == "TP" then
        -- the character window's Gear and Powers tabs (0.31): kind|text
        local kind, text = rest:match("^(%a)|(.*)$")
        local into = cmd == "TG" and "pendingGear" or "pendingPowers"
        WT[into] = WT[into] or {}
        if kind then table.insert(WT[into], { kind = kind, text = text }) end
    elseif cmd == "TE" then
        WT.totals, WT.pendingTotals = WT.pendingTotals, {}
        WT.gearLines, WT.pendingGear = WT.pendingGear or {}, {}
        WT.powerLines, WT.pendingPowers = WT.pendingPowers or {}, {}
        if not WT.receiving then
            WT.version = (WT.version or 0) + 1   -- free points change what is green
            RefreshSide()
            Draw()
        end
    elseif cmd == "D" then
        local f = Split(rest, "|")
        local id = tonumber(f[1])
        if id then WT.stats[id] = { name = f[2], text = f[3], icon = f[4], per = f[5], cap = f[6], flat = f[7] } end
    elseif cmd == "K" then
        local f = Split(rest, "|")
        local id = tonumber(f[1])
        if id then WT.keystones[id] = { name = f[2], text = f[3], icon = f[4], ks = tonumber(f[5]) or id, emp = f[6] == "1" } end
    elseif cmd == "BW" then
        local f = Split(rest, "|")
        local list = {}
        for n in (f[1] or ""):gmatch("(%d+)") do list[#list + 1] = tonumber(n) end
        G.SetWedges(list)
        WT.boardName = f[2] or ""
        WT.empowerPct = tonumber(f[3] or "") or 15
        if title then title:SetText((WT.boardName ~= "" and WT.boardName ~= "General") and (WT.boardName .. " Paragon Board") or "Paragon Board") end
    elseif cmd == "KA" then
        local f = Split(rest, "|")
        WT.ksSlots = tonumber(f[1]) or 3
        WT.activeKs = {}
        for n in (f[2] or ""):gmatch("(%d+)") do WT.activeKs[tonumber(n)] = true end
        WT.signatureKs = tonumber(f[3] or "") or 0
        WT.ksAuras = f[4] ~= "0"
        if WT.RefreshHubAuras then WT.RefreshHubAuras() end
        if WT.RefreshKeystoneButton then WT.RefreshKeystoneButton() end
        if WT.drawn and not WT.receiving then WT.lastDraw = nil Draw() end
    elseif cmd == "AB" then
        WT.taken = {}
        WT.receiving = true
    elseif cmd == "A" then
        for id in string.gmatch(rest, "(%d+)") do WT.taken[tonumber(id)] = true end
    elseif cmd == "AE" then
        WT.receiving = false
        local first = not WT.drawn
        WT.drawn = true
        if first then
            WT.version = (WT.version or 0) + 1
            Measure()
            Size(canvas, CanvasW() * WT.zoom, CanvasH() * WT.zoom)
            CentreOn(0, 0)
            RefreshSide()
        else
            Rebuild()
        end
    elseif cmd == "+" then
        local id = tonumber(rest)
        if id then
            WT.taken[id] = true
            PlaySound("igMainMenuOptionCheckBoxOn")
            Rebuild()
        end
    elseif cmd == "-" then
        local id = tonumber(rest)
        if id then
            WT.taken[id] = nil
            PlaySound("igMainMenuOptionCheckBoxOff")
            Rebuild()
        end
    elseif cmd == "O" then
        WT.serverOpened = true   -- the board follows; no need to ask for it
        frame:Show()
    elseif cmd == "E" then
        UIErrorsFrame:AddMessage(rest, 1, 0.2, 0.2)
    end
end

end

-- ---------------------------------------------------------------------------
-- Paragon Board loadouts: three saved boards, on the board's side panel
-- ---------------------------------------------------------------------------

do
    local loadouts = {}
    local header = side:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    header:SetPoint("BOTTOMLEFT", 0, 182)
    header:SetText("Loadouts")

    -- the keystones you own, a few switched on at a time
    local ksButton = CreateFrame("Button", nil, side, "UIPanelButtonTemplate")
    Size(ksButton, 220, 22)
    ksButton:SetPoint("BOTTOMLEFT", 0, 206)
    local ksMenu = CreateFrame("Frame", "WorldTiersKeystoneMenu", UIParent, "UIDropDownMenuTemplate")
    function WT.RefreshKeystoneButton()
        ksButton:SetText(string.format("Keystones: %d of %d active", WT.ActiveCount(), WT.ksSlots or 3))
    end
    WT.RefreshKeystoneButton()
    ksButton:SetScript("OnClick", function(self)
        local menu = { { text = string.format("Keystones (%d of %d slots)", WT.ActiveCount(), WT.ksSlots or 3), isTitle = true, notCheckable = true } }
        local seen = {}
        for id in pairs(WT.taken) do
            local c = G.Cell(id)
            local k = c.kind == 3 and WT.keystones[c.keystone]
            if k and not seen[k.ks] then
                seen[k.ks] = true
                local ks, on = k.ks, WT.activeKs[k.ks] and true or false
                menu[#menu + 1] = { text = k.name, checked = on, keepShownOnClick = false, tooltipTitle = k.name, tooltipText = k.text,
                    func = function() Send((on and "KD:" or "KA:") .. ks) end }
            end
        end
        if #menu == 1 then menu[2] = { text = "You own no keystones yet: take one on the board.", notCheckable = true, disabled = true } end
        local sig
        for _, k in pairs(WT.keystones) do if WT.signatureKs and WT.signatureKs > 0 and k.ks == WT.signatureKs then sig = k end end
        if sig then
            menu[#menu + 1] = { text = "Signature: " .. sig.name .. " (always on)", notCheckable = true, tooltipTitle = sig.name, tooltipText = sig.text,
                func = function() if WT.OpenHub then WT.OpenHub() end end }
        end
        menu[#menu + 1] = { text = "Keystone auras (always-on keystones)", checked = WT.ksAuras ~= false, keepShownOnClick = false,
            tooltipTitle = "Keystone Auras", tooltipText = "Turn every always-on keystone off or on at once (auras, forms, companions). Also /wtaura.",
            func = function() Send("KT") end }
        menu[#menu + 1] = { text = "More slots open at Paragon 100, 250, 500 and 1000.", notCheckable = true, disabled = true }
        EasyMenu(menu, ksMenu, self, 0, 0, "MENU")
    end)

    StaticPopupDialogs["WORLDTIERS_SAVE_LOADOUT"] = {
        text = "Save your Paragon Board as loadout %s. Name it:",
        button1 = SAVE or "Save", button2 = CANCEL,
        hasEditBox = 1, maxLetters = 24,
        OnShow = function(self) local e = _G[self:GetName() .. "EditBox"] if e then e:SetText(self.data and self.data.name or "") e:SetFocus() end end,
        OnAccept = function(self, data)
            local e = _G[self:GetName() .. "EditBox"]
            Send(string.format("LS:%d:%s", data.slot, (e and e:GetText() or ""):gsub("[|:^~]", "")))
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            Send(string.format("LS:%d:%s", parent.data.slot, self:GetText():gsub("[|:^~]", "")))
            parent:Hide()
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }

    local rows = {}
    for i = 1, 3 do
        local r = CreateFrame("Frame", nil, side)
        Size(r, 220, 22)
        r:SetPoint("BOTTOMLEFT", 0, 182 - i * 24)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 0, 0)
        r.text:SetWidth(110)
        r.text:SetJustifyH("LEFT")
        r.load = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        Size(r.load, 50, 20)
        r.load:SetPoint("LEFT", r.text, "RIGHT", 4, 0)
        r.load:SetText("Load")
        r.load:SetScript("OnClick", function() Send("LL:" .. (i - 1)) end)
        r.save = CreateFrame("Button", nil, r, "UIPanelButtonTemplate")
        Size(r.save, 50, 20)
        r.save:SetPoint("LEFT", r.load, "RIGHT", 4, 0)
        r.save:SetText("Save")
        r.save:SetScript("OnClick", function()
            local d = StaticPopup_Show("WORLDTIERS_SAVE_LOADOUT", tostring(i))
            if d then d.data = { slot = i - 1, name = loadouts[i - 1] and loadouts[i - 1].name or "" } end
        end)
        rows[i] = r
    end

    local function Refresh()
        for i = 1, 3 do
            local l = loadouts[i - 1]
            if l and l.name ~= "" then
                rows[i].text:SetText(string.format("%d. %s |cff888888(%d)|r", i, l.name, l.nodes))
                rows[i].load:Enable()
            else
                rows[i].text:SetText(string.format("%d. |cff888888empty|r", i))
                rows[i].load:Disable()
            end
        end
    end
    Refresh()

    -- LO|slot|name|nodes   LE|
    function WT.OnLoadoutMessage(msg)
        local cmd = msg:match("^(L[OE])|")
        if not cmd then return false end
        if cmd == "LO" then
            local f = Split(msg:sub(4), "|")
            loadouts[tonumber(f[1]) or 0] = { name = f[2] or "", nodes = tonumber(f[3]) or 0 }
        else
            Refresh()
        end
        return true
    end
end
-- Generated by tools/gen_glyphs.py: edit that, not this.
WT.GLYPH = { maxLevel = 20, boostMin = 20.0, boostMax = 58.0,
    KIND = { small = 1, notable = 2, empower = 4 }, defs = {
    [1] = { name = "Titan", icon = "Ability_Warrior_StrengthOfArms", stat = 0, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [2] = { name = "Ogre's Grip", icon = "Ability_Warrior_BattleShout", stat = 0, kind = 0, need = 5, bonus = 13, lo = 10.00, hi = 80.00, text = "+%s Strength" },
    [3] = { name = "Earthbreaker", icon = "Ability_Warrior_Rampage", stat = 0, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [4] = { name = "Colossus", icon = "Ability_Warrior_DefensiveStance", stat = 0, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [5] = { name = "Ranger", icon = "Ability_Hunter_RunningShot", stat = 1, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [6] = { name = "Shadowstep", icon = "Ability_Rogue_Shadowstep", stat = 1, kind = 0, need = 5, bonus = 11, lo = 2.00, hi = 8.00, text = "%s%% movement speed" },
    [7] = { name = "Duelist", icon = "Ability_Parry", stat = 1, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Avoidance (board)" },
    [8] = { name = "Viper", icon = "Ability_Hunter_AspectOfTheViper", stat = 1, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [9] = { name = "Bastion", icon = "Spell_Holy_DevotionAura", stat = 2, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [10] = { name = "Lifeblood", icon = "Spell_Nature_Regenerate", stat = 2, kind = 0, need = 5, bonus = 8, lo = 0.50, hi = 2.00, text = "%s%% of damage dealt returned as health" },
    [11] = { name = "Mountain", icon = "Spell_Nature_EarthShock", stat = 2, kind = 0, need = 5, bonus = 13, lo = 10.00, hi = 80.00, text = "+%s Stamina" },
    [12] = { name = "Undying", icon = "Spell_Shadow_DeathPact", stat = 2, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Armor (board)" },
    [13] = { name = "Archmage", icon = "Spell_Holy_MagicalSentry", stat = 3, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [14] = { name = "Sage", icon = "INV_Misc_Book_09", stat = 3, kind = 0, need = 5, bonus = 9, lo = 5.00, hi = 20.00, text = "%s%% more experience and Paragon experience" },
    [15] = { name = "Arcanist", icon = "Spell_Nature_EnchantArmor", stat = 3, kind = 0, need = 5, bonus = 5, lo = 2.00, hi = 8.00, text = "%s%% shorter cooldowns" },
    [16] = { name = "Wellspring", icon = "Spell_Arcane_ManaTap", stat = 3, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Spirit (board)" },
    [17] = { name = "Serenity", icon = "Spell_Holy_PrayerOfSpirit", stat = 4, kind = 0, need = 5, bonus = 3, lo = 4.00, hi = 14.00, text = "%s%% more healing done" },
    [18] = { name = "Meditation", icon = "Spell_Nature_Sleep", stat = 4, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Intellect (board)" },
    [19] = { name = "Clarity", icon = "Spell_Holy_InnerFire", stat = 4, kind = 0, need = 5, bonus = 5, lo = 2.00, hi = 8.00, text = "%s%% shorter cooldowns" },
    [20] = { name = "Zen", icon = "Spell_Holy_HolyProtection", stat = 4, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [21] = { name = "Executioner", icon = "INV_Axe_09", stat = 5, kind = 0, need = 5, bonus = 6, lo = 4.00, hi = 15.00, text = "%s%% more damage to bosses" },
    [22] = { name = "Warmonger", icon = "Ability_Warrior_Rampage", stat = 5, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [23] = { name = "Carnage", icon = "Ability_Warrior_Cleave", stat = 5, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [24] = { name = "Ruin", icon = "Spell_Shadow_UnholyFrenzy", stat = 5, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Haste (board)" },
    [25] = { name = "Precision", icon = "Ability_Hunter_SniperShot", stat = 6, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [26] = { name = "Assassin", icon = "Ability_Rogue_Eviscerate", stat = 6, kind = 0, need = 5, bonus = 6, lo = 4.00, hi = 15.00, text = "%s%% more damage to bosses" },
    [27] = { name = "Eagle Eye", icon = "Ability_Hunter_EagleEye", stat = 6, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Critical Strike (board)" },
    [28] = { name = "Fortune", icon = "INV_Misc_Coin_02", stat = 6, kind = 0, need = 5, bonus = 10, lo = 5.00, hi = 25.00, text = "%s%% more gold from creatures" },
    [29] = { name = "Tempo", icon = "Spell_Nature_TimeStop", stat = 7, kind = 0, need = 5, bonus = 5, lo = 2.00, hi = 8.00, text = "%s%% shorter cooldowns" },
    [30] = { name = "Whirlwind", icon = "Ability_Whirlwind", stat = 7, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [31] = { name = "Quicksilver", icon = "Spell_Nature_Swiftness", stat = 7, kind = 0, need = 5, bonus = 11, lo = 2.00, hi = 8.00, text = "%s%% movement speed" },
    [32] = { name = "Momentum", icon = "Spell_Nature_Bloodlust", stat = 7, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Haste (board)" },
    [33] = { name = "Fortress", icon = "INV_Shield_06", stat = 8, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [34] = { name = "Ironskin", icon = "Spell_Holy_DevotionAura", stat = 8, kind = 0, need = 5, bonus = 13, lo = 150.00, hi = 1200.00, text = "+%s armor" },
    [35] = { name = "Bulwark", icon = "Ability_Defend", stat = 8, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Avoidance (board)" },
    [36] = { name = "Stoneheart", icon = "Spell_Nature_StoneSkinTotem", stat = 8, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Stamina (board)" },
    [37] = { name = "Vampire", icon = "Spell_Shadow_LifeDrain02", stat = 9, kind = 0, need = 5, bonus = 8, lo = 0.50, hi = 2.00, text = "%s%% of damage dealt returned as health" },
    [38] = { name = "Bloodlust", icon = "Spell_Shadow_BloodBoil", stat = 9, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [39] = { name = "Sanguine", icon = "Spell_Shadow_VampiricAura", stat = 9, kind = 0, need = 5, bonus = 3, lo = 4.00, hi = 14.00, text = "%s%% more healing done" },
    [40] = { name = "Hunger", icon = "Ability_Druid_Ravage", stat = 9, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Haste (board)" },
    [41] = { name = "Mender", icon = "Spell_Holy_FlashHeal", stat = 10, kind = 0, need = 5, bonus = 3, lo = 4.00, hi = 14.00, text = "%s%% more healing done" },
    [42] = { name = "Lightwell", icon = "Spell_Holy_SummonLightwell", stat = 10, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Spirit (board)" },
    [43] = { name = "Martyr", icon = "Spell_Holy_PainSupression", stat = 10, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [44] = { name = "Renewal", icon = "Spell_Holy_Renew", stat = 10, kind = 0, need = 5, bonus = 8, lo = 0.50, hi = 2.00, text = "%s%% of damage dealt returned as health" },
    [45] = { name = "Windrunner", icon = "Ability_Rogue_Sprint", stat = 11, kind = 0, need = 5, bonus = 11, lo = 2.00, hi = 8.00, text = "%s%% movement speed" },
    [46] = { name = "Pathfinder", icon = "INV_Misc_Map_01", stat = 11, kind = 0, need = 5, bonus = 9, lo = 5.00, hi = 20.00, text = "%s%% more experience and Paragon experience" },
    [47] = { name = "Gale", icon = "Spell_Nature_Cyclone", stat = 11, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Haste (board)" },
    [48] = { name = "Nomad", icon = "INV_Misc_Bag_10", stat = 11, kind = 0, need = 5, bonus = 10, lo = 5.00, hi = 25.00, text = "%s%% more gold from creatures" },
    [49] = { name = "Phantom", icon = "Spell_Shadow_Twilight", stat = 12, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [50] = { name = "Evasion", icon = "Spell_Shadow_ShadowWard", stat = 12, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Avoidance (board)" },
    [51] = { name = "Riposte", icon = "Ability_Warrior_Challange", stat = 12, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [52] = { name = "Shroud", icon = "Ability_Stealth", stat = 12, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Agility (board)" },
    [53] = { name = "Packleader", icon = "Ability_Hunter_BeastCall", stat = 13, kind = 0, need = 5, bonus = 7, lo = 6.00, hi = 25.00, text = "%s%% more damage from your pets and minions" },
    [54] = { name = "Beastmaster", icon = "Ability_Hunter_BeastMastery", stat = 13, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [55] = { name = "Summoner", icon = "Spell_Shadow_SummonFelGuard", stat = 13, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Stamina (board)" },
    [56] = { name = "Kinship", icon = "Ability_Hunter_Pet_Bear", stat = 13, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [57] = { name = "Giantslayer", icon = "Ability_Warrior_Decisivestrike", stat = 5, kind = 0, need = 5, bonus = 6, lo = 4.00, hi = 15.00, text = "%s%% more damage to bosses" },
    [58] = { name = "Dragonbane", icon = "INV_Misc_Head_Dragon_01", stat = 5, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [59] = { name = "Champion", icon = "Achievement_Boss_Ragnaros", stat = 5, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [60] = { name = "Conqueror", icon = "INV_Misc_Coin_04", stat = 5, kind = 0, need = 5, bonus = 10, lo = 5.00, hi = 25.00, text = "%s%% more gold from creatures" },
    [61] = { name = "Warlord", icon = "Ability_Warrior_WarCry", stat = 0, kind = 0, need = 5, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [62] = { name = "Gladiator", icon = "INV_Sword_48", stat = 1, kind = 0, need = 5, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
    [63] = { name = "Vanguard", icon = "Ability_Warrior_ShieldWall", stat = 0, kind = 0, need = 5, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [64] = { name = "Hunter's Mark", icon = "Ability_Hunter_SniperShot", stat = 1, kind = 0, need = 5, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Haste (board)" },
    [65] = { name = "Resonance", icon = "Spell_Arcane_ArcaneResilience", stat = 255, kind = 4, need = 2, bonus = 1, lo = 3.00, hi = 10.00, text = "%s%% more damage dealt" },
    [66] = { name = "Echo", icon = "Spell_Arcane_Blink", stat = 255, kind = 4, need = 2, bonus = 5, lo = 2.00, hi = 8.00, text = "%s%% shorter cooldowns" },
    [67] = { name = "Ascendant", icon = "Spell_Holy_AuraMastery", stat = 255, kind = 2, need = 1, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Damage (board)" },
    [68] = { name = "Crown", icon = "INV_Crown_01", stat = 255, kind = 2, need = 1, bonus = 2, lo = 2.00, hi = 8.00, text = "%s%% less damage taken" },
    [69] = { name = "Legion", icon = "INV_Misc_Head_Orc_01", stat = 255, kind = 2, need = 1, bonus = 6, lo = 4.00, hi = 15.00, text = "%s%% more damage to bosses" },
    [70] = { name = "Multitude", icon = "Spell_Holy_PrayerOfFortitude", stat = 255, kind = 1, need = 6, bonus = 9, lo = 5.00, hi = 20.00, text = "%s%% more experience and Paragon experience" },
    [71] = { name = "Foundation", icon = "INV_Stone_15", stat = 255, kind = 1, need = 6, bonus = 12, lo = 4.00, hi = 16.00, text = "+%s%% Stamina (board)" },
    [72] = { name = "Spark", icon = "Spell_Fire_Fireball", stat = 255, kind = 1, need = 6, bonus = 4, lo = 6.00, hi = 25.00, text = "%s%% more critical strike damage" },
} }

-- ---------------------------------------------------------------------------
-- Paragon Glyphs: a socket on each arm's second notable, a picker, and the
-- collection (the table is glyphdata.lua, generated with the server's)
-- ---------------------------------------------------------------------------

do
    local GL = WT.GLYPH
    local SOCKET_POS = 2 * G.SEGMENT
    local EMPTY_SOCKET = "Interface\\ItemSocketingFrame\\UI-EmptySocket-Prismatic"
    WT.glyphs, WT.socketGlyph = {}, {}
    local pending, found, total = nil, 0, 0
    local sockets = {}

    local function Lerp(lo, hi, level)
        local l = math.max(1, math.min(GL.maxLevel, level or 1))
        return lo + (hi - lo) * (l - 1) / (GL.maxLevel - 1)
    end
    local function Num(v)
        local s = string.format("%.1f", v)
        return (s:gsub("%.0$", ""))
    end
    local function Range(level) return (level or 1) >= 20 and 6 or ((level or 1) >= 10 and 5 or 4) end
    local function KindOk(want, kind)
        if want == 0 then return true end
        if want == GL.KIND.small then return kind == G.SMALL or kind == G.MASTERY end
        if want == GL.KIND.notable then return kind == G.NOTABLE end
        if want == GL.KIND.empower then return kind == G.EMPOWER end
        return false
    end
    local function What(d)
        if d.stat ~= 255 then local st = WT.stats[d.stat] return st and st.name or "?" end
        if d.kind == GL.KIND.empower then return "empower" end
        if d.kind == GL.KIND.notable then return "notable" end
        return "small"
    end
    local function BonusText(d, level)
        return (d.text:gsub("%%s", Num(Lerp(d.lo, d.hi, level))):gsub("%%%%", "%%"))
    end

    -- every node within range of a socket, along the board's links (the server's GlyphReach)
    function WT.GlyphReach(socket, range)
        local out, seen, q = {}, { [socket] = true }, { { socket, 0 } }
        local i = 1
        while q[i] do
            local id, d = q[i][1], q[i][2]
            i = i + 1
            out[#out + 1] = id
            if d < range then
                local nxt = G.Children(id)
                if id ~= 0 then nxt[#nxt + 1] = G.Parent(id) end
                for _, n in ipairs(nxt) do
                    if n ~= 0 and not seen[n] then seen[n] = true q[#q + 1] = { n, d + 1 } end
                end
            end
        end
        return out
    end

    -- the matching nodes you have in range
    local function Matching(gid, socket, level)
        local d = GL.defs[gid]
        local n, set = 0, {}
        for _, id in ipairs(WT.GlyphReach(socket, Range(level))) do
            set[id] = true
            if WT.taken[id] then
                local c = G.Cell(id)
                if KindOk(d.kind, c.kind) and (d.stat == 255 or c.stat == d.stat) then n = n + 1 end
            end
        end
        return n, set
    end

    local function GlyphTooltip(gid, socket)
        local d = GL.defs[gid]
        if not d then return end
        local g = WT.glyphs[gid]
        local level = g and g.level or 1
        GameTooltip:AddLine("Glyph: " .. d.name, 0.75, 0.4, 1)
        if g then
            GameTooltip:AddLine(string.format("Level %d%s", level,
                level < GL.maxLevel and string.format("  (%d / %d experience)", g.xp, g.need) or "  (highest)"), 1, 0.82, 0)
        else
            GameTooltip:AddLine("Not found yet: Tier Keys and raid or world bosses drop glyphs, more often at higher tiers.", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:AddLine(string.format("Range %d: +%s%% to the %s nodes you have in range.", Range(level),
            Num(Lerp(GL.boostMin, GL.boostMax, level)), What(d)), 1, 1, 1, true)
        GameTooltip:AddLine(string.format("Bonus: %s, while %d %s node%s you have are in range.", BonusText(d, level), d.need, What(d),
            d.need == 1 and "" or "s"), 0.4, 1, 0.4, true)
        if socket then
            local n = Matching(gid, socket, level)
            GameTooltip:AddLine(string.format("Here: %d matching node%s in range%s", n, n == 1 and "" or "s",
                n >= d.need and " - bonus on" or string.format(" - bonus needs %d", d.need)), n >= d.need and 0.4 or 1, n >= d.need and 1 or 0.4, 0.4)
        end
        if level < GL.maxLevel then
            GameTooltip:AddLine(string.format("At level %d: +%s%%, range 6, %s.", GL.maxLevel, Num(GL.boostMax), BonusText(d, GL.maxLevel)),
                0.6, 0.6, 0.6, true)
        end
        if g then
            GameTooltip:AddLine("Socketed glyphs gain experience from bosses, Tier Keys and Champions.", 0.6, 0.6, 0.6, true)
        end
    end

    -- ---------------- the picker / collection ----------------
    local ROWS, ROW_H = 10, 42
    local pick = CreateFrame("Frame", "WorldTiersGlyphFrame", UIParent)
    Size(pick, 380, 520)
    pick:SetPoint("CENTER", 300, 0)
    pick:SetFrameStrata("DIALOG")
    pick:SetToplevel(true)
    pick:EnableMouse(true)
    pick:SetMovable(true)
    pick:SetClampedToScreen(true)
    pick:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    pick:Hide()
    tinsert(UISpecialFrames, "WorldTiersGlyphFrame")
    pick:RegisterForDrag("LeftButton")
    pick:SetScript("OnDragStart", function(self) self:StartMoving() end)
    pick:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local ptitle = pick:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    ptitle:SetPoint("TOP", 0, -16)
    local psub = pick:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    psub:SetPoint("TOP", ptitle, "BOTTOM", 0, -4)
    psub:SetWidth(340)
    local pclose = CreateFrame("Button", nil, pick, "UIPanelCloseButton")
    pclose:SetPoint("TOPRIGHT", -6, -6)
    local fit = CreateFrame("CheckButton", "WorldTiersGlyphFit", pick, "UICheckButtonTemplate")
    Size(fit, 22, 22)
    fit:SetPoint("TOPLEFT", 18, -58)
    local fitText = _G["WorldTiersGlyphFitText"]
    if fitText then fitText:SetText("Only glyphs that fit this arm") fitText:SetFontObject("GameFontHighlightSmall") end
    local remove = CreateFrame("Button", nil, pick, "UIPanelButtonTemplate")
    Size(remove, 110, 22)
    remove:SetPoint("TOPRIGHT", -20, -58)
    remove:SetText("Empty socket")
    local list = CreateFrame("Frame", nil, pick)
    list:SetPoint("TOPLEFT", 18, -86)
    Size(list, 344, ROWS * ROW_H)
    list:EnableMouseWheel(true)
    local bg = list:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0, 0, 0, 0.45)

    local state = { socket = nil, offset = 0, onlyFit = true }
    local shown = {}
    local rows = {}

    local function Fits(gid, socket)
        local d = GL.defs[gid]
        if d.stat == 255 or not socket then return true end
        return G.Cell(socket).stat == d.stat
    end

    local function Build()
        shown = {}
        local owned, missing = {}, {}
        for gid, d in ipairs(GL.defs) do
            local onBoard = d.stat == 255
            if not onBoard then for _, s in ipairs(G.SECTOR_STAT) do if s == d.stat then onBoard = true end end end
            if onBoard and (not state.socket or not state.onlyFit or Fits(gid, state.socket)) then
                if WT.glyphs[gid] then owned[#owned + 1] = gid else missing[#missing + 1] = gid end
            end
        end
        table.sort(owned, function(a, b) return (WT.glyphs[a].level > WT.glyphs[b].level) or (WT.glyphs[a].level == WT.glyphs[b].level and a < b) end)
        for _, g in ipairs(owned) do shown[#shown + 1] = g end
        if not state.socket then for _, g in ipairs(missing) do shown[#shown + 1] = g end end
    end

    function WT.RefreshGlyphPicker()
        if not pick:IsShown() then return end
        Build()
        state.offset = math.max(0, math.min(state.offset, #shown - ROWS))
        if state.socket then
            local st = WT.stats[G.Cell(state.socket).stat]
            ptitle:SetText("Socket a glyph")
            psub:SetText(string.format("%s arm, second notable. Click a glyph to put it here.", st and st.name or "This"))
            fit:Show()
            if WT.socketGlyph[state.socket] then remove:Show() else remove:Hide() end
        else
            ptitle:SetText(string.format("Glyphs  |cffffffff%d / %d found|r", found, total))
            psub:SetText("Socket them on the board: the small socket by each arm's second notable. Tier Keys and raid / world bosses drop them.")
            fit:Hide()
            remove:Hide()
        end
        fit:SetChecked(state.onlyFit)
        for i = 1, ROWS do
            local r, gid = rows[i], shown[state.offset + i]
            r.gid = gid
            if gid then
                local d, g = GL.defs[gid], WT.glyphs[gid]
                r.icon:SetTexture("Interface\\Icons\\" .. d.icon)
                r.icon:SetDesaturated(not g)
                r.name:SetText((g and "|cffc080ff" or "|cff777777") .. d.name .. "|r" .. (g and string.format("  |cffffd100%d|r", g.level) or ""))
                r.sub:SetText(string.format("%s nodes: %s", What(d), BonusText(d, g and g.level or 1)))
                local where = g and g.socket and g.socket ~= 0
                r.mark:SetText(where and (g.socket == state.socket and "|cff66ff66here|r" or "|cff999999in use|r") or "")
                r:Show()
            else
                r:Hide()
            end
        end
    end

    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        Size(r, 344, ROW_H)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        Size(r.icon, 34, 34)
        r.icon:SetPoint("LEFT", 4, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 8, -2)
        r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.sub:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -3)
        r.sub:SetWidth(290)
        r.sub:SetJustifyH("LEFT")
        r.mark = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.mark:SetPoint("TOPRIGHT", -6, -4)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r:SetScript("OnClick", function(self)
            if self.gid and state.socket and WT.glyphs[self.gid] then
                Send(string.format("YS:%d:%d", self.gid, state.socket))
                pick:Hide()
            end
        end)
        r:SetScript("OnEnter", function(self)
            if not self.gid then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GlyphTooltip(self.gid, state.socket)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = r
    end
    list:SetScript("OnMouseWheel", function(self, delta)
        state.offset = math.max(0, math.min(math.max(0, #shown - ROWS), state.offset - delta * 2))
        WT.RefreshGlyphPicker()
    end)
    fit:SetScript("OnClick", function(self) state.onlyFit = self:GetChecked() and true or false state.offset = 0 WT.RefreshGlyphPicker() end)
    remove:SetScript("OnClick", function() if state.socket then Send("YU:" .. state.socket) pick:Hide() end end)
    pick:SetScript("OnShow", function() WT.RefreshGlyphPicker() end)

    function WT.OpenGlyphs(socket)
        state.socket, state.offset = socket, 0
        if pick:IsShown() then WT.RefreshGlyphPicker() else pick:Show() end
    end

    -- the Glyphs button on the board's side panel
    local open = CreateFrame("Button", "WorldTiersGlyphButton", side, "UIPanelButtonTemplate")
    Size(open, 76, 20)
    open:SetPoint("TOPRIGHT", side, "TOPRIGHT", 0, 2)
    open:SetText("Glyphs")
    open:SetScript("OnClick", function() WT.OpenGlyphs(nil) end)
    open:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Paragon Glyphs", 0.75, 0.4, 1)
        GameTooltip:AddLine(string.format("%d of %d found. Each arm's second notable has a socket: click it to put a glyph in.", found, total),
            1, 1, 1, true)
        GameTooltip:Show()
    end)
    open:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- ---------------- sockets on the board ----------------
    local function NewSocket()
        local b = CreateFrame("Button", nil, canvas)
        b.ring = b:CreateTexture(nil, "BACKGROUND")
        b.ring:SetTexture("Interface\\Buttons\\WHITE8X8")
        b.ring:SetAllPoints()
        b.ring:SetVertexColor(0.6, 0.3, 0.9, 1)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetPoint("TOPLEFT", 1, -1)
        b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        b:SetFrameLevel(canvas:GetFrameLevel() + 5)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" and WT.socketGlyph[self.node] then Send("YU:" .. self.node) return end
            WT.OpenGlyphs(self.node)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local gid = WT.socketGlyph[self.node]
            if gid then
                GlyphTooltip(gid, self.node)
                GameTooltip:AddLine("Click: change glyph. Right-click: empty the socket.", 0.6, 0.8, 1, true)
                local _, set = Matching(gid, self.node, WT.glyphs[gid] and WT.glyphs[gid].level)
                WT.glyphHi = set
            else
                GameTooltip:AddLine("Glyph socket", 0.75, 0.4, 1)
                GameTooltip:AddLine("Click to put a glyph in. It boosts the matching nodes you have nearby, and has a bonus of its own.", 1, 1, 1, true)
                local set = {}
                for _, id in ipairs(WT.GlyphReach(self.node, 4)) do set[id] = true end
                WT.glyphHi = set
            end
            GameTooltip:Show()
            WT.lastDraw = nil
            if WT.Draw then WT.Draw() end
        end)
        b:SetScript("OnLeave", function()
            GameTooltip:Hide()
            WT.glyphHi = nil
            WT.lastDraw = nil
            if WT.Draw then WT.Draw() end
        end)
        return b
    end

    function WT.GlyphDraw(z, Pos, inView)
        local n = 0
        for a = 0, G.ARMS - 1 do
            local id = G.Id(a, 0, SOCKET_POS)
            local px, py = Pos(id)
            if WT.taken[id] and inView(px, py) then
                n = n + 1
                local b = sockets[n]
                if not b then b = NewSocket() sockets[n] = b end
                b.node = id
                local s = math.max(8, 18 * z)
                Size(b, s, s)
                b:ClearAllPoints()
                b:SetPoint("CENTER", canvas, "TOPLEFT", (px + 18) * z, -(py - 18) * z)
                local gid = WT.socketGlyph[id]
                if gid and GL.defs[gid] then
                    b.icon:SetTexture("Interface\\Icons\\" .. GL.defs[gid].icon)
                    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    b.ring:SetVertexColor(0.75, 0.4, 1, 1)
                else
                    b.icon:SetTexture(EMPTY_SOCKET)
                    b.icon:SetTexCoord(0, 1, 0, 1)
                    b.ring:SetVertexColor(0.35, 0.2, 0.5, 1)
                end
                b:Show()
            end
        end
        for i = n + 1, #sockets do sockets[i]:Hide() end
    end

    function WT.GlyphNodeTooltip(id)
        if G.Branch(id) ~= 0 or G.Pos(id) ~= SOCKET_POS then return end
        local gid = WT.socketGlyph[id]
        if gid and GL.defs[gid] then
            GameTooltip:AddLine("Glyph: " .. GL.defs[gid].name .. " (hover the socket beside it)", 0.75, 0.4, 1)
        else
            GameTooltip:AddLine("Has a glyph socket once taken.", 0.75, 0.4, 1)
        end
    end

    -- YB|  YG|id^level^xp^need^socket~...  YE|found|total
    function WT.OnGlyphMessage(msg)
        local cmd = msg:match("^(Y[BGE])|")
        if not cmd then return false end
        local rest = msg:sub(4)
        if cmd == "YB" then
            pending = {}
        elseif cmd == "YG" and pending then
            for one in rest:gmatch("([^~]+)") do
                local f = Split(one, "^")
                local id = tonumber(f[1])
                if id then
                    pending[id] = { level = tonumber(f[2]) or 1, xp = tonumber(f[3]) or 0, need = tonumber(f[4]) or 0, socket = tonumber(f[5]) or 0 }
                end
            end
        elseif cmd == "YE" then
            if pending then
                WT.glyphs, pending = pending, nil
                WT.socketGlyph = {}
                for gid, g in pairs(WT.glyphs) do if g.socket ~= 0 then WT.socketGlyph[g.socket] = gid end end
            end
            local f = Split(rest, "|")
            found, total = tonumber(f[1]) or 0, tonumber(f[2]) or #GL.defs
            open:SetText(string.format("Glyphs %d", found))
            WT.lastDraw = nil
            if WT.drawn and frame:IsShown() and WT.Draw then WT.Draw() end
            WT.RefreshGlyphPicker()
        end
        return true
    end
end

-- ---------------------------------------------------------------------------
-- Ascendancies: from level 80, one of four for your class, each a big
-- defining power of its own, on top of whatever keystones you run. Chosen in
-- this window, opened from the World Tiers window (Overview) or /ascend.
-- JA|slot|name|icon||text   JE|chosen|level needed|character level
-- Mastery (0.30): JT|<points for ranks 1-5>   JM|slot|points|rank|picks; JP:rank:choice back
-- (the empty field once named keystones it empowered; shown if a server sends one)
-- ---------------------------------------------------------------------------

do
    local asc = { list = {}, building = nil, chosen = 0, need = 80, level = 0, mastery = {}, at = { 250, 800, 2000, 4500, 9000 } }
    -- the Mastery choices, rank by rank (the server works the same ones)
    local MASTERY = {
        { { "Potency", "Your Ascendancy's own strikes, bursts, pulses, shields and heals are 25% stronger." },
          { "Reach", "Its areas are 30% larger, and its effects that pick targets take one more." } },
        { { "Tempo", "Its timed effects come 25% sooner, its chances are 25% higher, and its counted hits come one sooner." },
          { "Fortitude", "You take 8% less damage, and its strikes heal you for 1% of your health (once a second)." } },
        { { "Fervor", "Its percentage bonuses are 30% larger: damage, damage reduction, leech, healing, pet power and stats, kill stacks." },
          { "Resonance", "Its strikes echo a second later for 35% of their damage." } },
        { { "Dominion", "Every kill: 2% more damage for 15 sec, up to 10 times." },
          { "Bulwark", "Below half health you take 20% less damage." } },
        { { "Apotheosis", "Every 60 sec in combat you ascend for 8 sec: its strikes, bursts and heals are doubled." },
          { "Overflow", "15% of the damage its strikes deal heals you." } },
    }
    WT.ASC_MASTERY = MASTERY

    local f = CreateFrame("Frame", "WorldTiersAscendancyFrame", UIParent)
    Size(f, 660, 596)
    f:SetPoint("CENTER", 0, 20)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:Hide()
    tinsert(UISpecialFrames, "WorldTiersAscendancyFrame")
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -18)
    title:SetText("Ascendancy")
    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)
    sub:SetWidth(600)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)

    StaticPopupDialogs["WORLDTIERS_ASCEND"] = {
        text = "%s",
        button1 = ACCEPT, button2 = CANCEL,
        OnAccept = function(self, data) if data then Send("JC:" .. data) end end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }

    local cards = {}
    for i = 1, 4 do
        local c = CreateFrame("Frame", nil, f)
        Size(c, 304, 176)
        c:SetPoint("TOPLEFT", 20 + ((i - 1) % 2) * 316, -62 - math.floor((i - 1) / 2) * 186)
        c:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        c.icon = c:CreateTexture(nil, "ARTWORK")
        Size(c.icon, 40, 40)
        c.icon:SetPoint("TOPLEFT", 12, -12)
        c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 10, -2)
        c.name:SetWidth(232)
        c.name:SetJustifyH("LEFT")
        c.ks = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.ks:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
        c.ks:SetWidth(232)
        c.ks:SetJustifyH("LEFT")
        c.ks:SetTextColor(1, 0.82, 0)
        c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.text:SetPoint("TOPLEFT", 12, -60)
        c.text:SetWidth(280)
        c.text:SetHeight(84)
        c.text:SetJustifyH("LEFT")
        c.text:SetJustifyV("TOP")
        c.button = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
        Size(c.button, 110, 22)
        c.button:SetPoint("BOTTOMRIGHT", -10, 10)
        c.state = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        c.state:SetPoint("BOTTOMLEFT", 12, 14)
        cards[i] = c
    end
    -- ---------------- Mastery: the chosen one's ranks ----------------
    local mf = CreateFrame("Frame", nil, f)
    Size(mf, 620, 132)
    mf:SetPoint("TOPLEFT", 20, -432)
    mf:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                     tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    mf:SetBackdropColor(0.08, 0.05, 0.02, 0.9)
    mf:SetBackdropBorderColor(1, 0.5, 0, 0.8)
    local mTitle = mf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mTitle:SetPoint("TOPLEFT", 12, -10)
    mTitle:SetTextColor(1, 0.5, 0)
    local mBar = CreateFrame("StatusBar", nil, mf)
    Size(mBar, 260, 14)
    mBar:SetPoint("TOPRIGHT", -12, -10)
    mBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    mBar:SetStatusBarColor(1, 0.5, 0)
    mBar:SetMinMaxValues(0, 1)
    local mBarBg = mBar:CreateTexture(nil, "BACKGROUND")
    mBarBg:SetAllPoints()
    mBarBg:SetTexture(0, 0, 0, 0.6)
    local mBarText = mBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    mBarText:SetPoint("CENTER", 0, 0)
    local mEmpty = mf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mEmpty:SetPoint("CENTER", 0, -10)
    mEmpty:SetWidth(560)
    local mCols = {}
    for r = 1, 5 do
        local col = { buttons = {} }
        col.label = mf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        col.label:SetPoint("TOPLEFT", 12 + (r - 1) * 121, -34)
        col.label:SetWidth(116)
        col.label:SetJustifyH("LEFT")
        for o = 1, 2 do
            local b = CreateFrame("Button", nil, mf, "UIPanelButtonTemplate")
            Size(b, 114, 22)
            b:SetPoint("TOPLEFT", 12 + (r - 1) * 121, -50 - (o - 1) * 26)
            b:SetText(MASTERY[r][o][1])
            b:SetScript("OnClick", function()
                if b.open and not b.mine then Send("JP:" .. r .. ":" .. o) end
            end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(MASTERY[r][o][1], 1, 0.5, 0)
                GameTooltip:AddLine(MASTERY[r][o][2], 1, 1, 1, true)
                if self.mine then GameTooltip:AddLine("Chosen. The other one can be chosen instead, out of combat.", 0.4, 1, 0.4, true)
                elseif not self.open then GameTooltip:AddLine(string.format("Mastery rank %d: %d Mastery.", r, asc.at[r] or 0), 1, 0.3, 0.3, true)
                else GameTooltip:AddLine("Click to choose it (free, any time out of combat).", 0.6, 0.6, 0.6, true) end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            col.buttons[o] = b
        end
        mCols[r] = col
    end
    local mFoot = mf:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    mFoot:SetPoint("BOTTOMLEFT", 12, 8)
    mFoot:SetWidth(596)
    mFoot:SetJustifyH("LEFT")
    mFoot:SetText("Mastery comes from kills while an Ascendancy is chosen (bosses most). Each of your four keeps its own.")

    local function RefreshMastery()
        local a = asc.list[asc.chosen]
        local m = asc.mastery[asc.chosen]
        if not a or not m then
            mTitle:SetText("Mastery")
            mEmpty:SetText(asc.level >= asc.need and "Choose an Ascendancy above to earn its Mastery: five ranks, each a choice of two."
                or "Each Ascendancy grows with use: five ranks of Mastery, each a choice of two.")
            mEmpty:Show()
            mBar:Hide()
            for _, col in ipairs(mCols) do col.label:Hide() for _, b in ipairs(col.buttons) do b:Hide() end end
            return
        end
        mEmpty:Hide()
        mBar:Show()
        mTitle:SetText(string.format("%s Mastery: rank %d of 5", a.name, m.rank))
        local nextAt = asc.at[m.rank + 1]
        if nextAt then
            local from = m.rank > 0 and asc.at[m.rank] or 0
            mBar:SetValue(math.max(0, math.min(1, (m.points - from) / math.max(1, nextAt - from))))
            mBarText:SetText(string.format("%d / %d to rank %d", m.points, nextAt, m.rank + 1))
        else
            mBar:SetValue(1)
            mBarText:SetText(string.format("%d: mastered", m.points))
        end
        for r, col in ipairs(mCols) do
            local open = m.rank >= r
            col.label:SetText(open and string.format("|cffff8000Rank %d|r", r) or string.format("|cff808080Rank %d  (%d)|r", r, asc.at[r] or 0))
            col.label:Show()
            for o, b in ipairs(col.buttons) do
                b.open, b.mine = open, open and m.picks[r] == o
                b:Show()
                if open then b:Enable() else b:Disable() end
                if b.mine then
                    b:LockHighlight()
                    b:SetText("|cffff8000" .. MASTERY[r][o][1] .. "|r")
                else
                    b:UnlockHighlight()
                    b:SetText(MASTERY[r][o][1])
                end
            end
        end
    end

    local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOM", 0, 18)
    note:SetWidth(600)
    note:SetText("An Ascendancy stands on its own: it works with any talents and any keystones. Change it any time out of combat.")

    local function Refresh()
        local open = asc.level >= asc.need
        if open then
            sub:SetText(asc.chosen > 0 and "Your Ascendancy is chosen. You can change it any time out of combat."
                or "|cff20ff20Choose one.|r Each is a power of its own, on top of everything else you build.")
        else
            sub:SetText(string.format("Ascendancies open at |cffff8000level %d|r (you are level %d). A look at what's ahead:", asc.need, asc.level))
        end
        for i, c in ipairs(cards) do
            local a = asc.list[i]
            if a then
                c.icon:SetTexture("Interface\\Icons\\" .. (a.icon or "INV_Misc_QuestionMark"))
                c.name:SetText(a.name)
                if a.ks and a.ks ~= "" then
                    c.ks:SetText("Empowers, when on: " .. a.ks)
                    c.ks:Show()
                else
                    c.ks:SetText("")
                    c.ks:Hide()
                end
                c.text:SetText(a.text or "")
                local mine = asc.chosen == i
                if mine then
                    c:SetBackdropColor(0.22, 0.13, 0.02, 0.95)
                    c:SetBackdropBorderColor(1, 0.5, 0)
                    local m = asc.mastery[i]
                    c.state:SetText("|cffff8000Ascended|r" .. (m and m.rank > 0 and ("  |cffffd100Mastery " .. m.rank .. "/5|r") or ""))
                    c.button:SetText("Give it up")
                    c.button:SetScript("OnClick", function()
                        local d = StaticPopup_Show("WORLDTIERS_ASCEND", "Give up " .. a.name .. "?")
                        if d then d.data = 0 end
                    end)
                else
                    c:SetBackdropColor(0.05, 0.05, 0.08, 0.9)
                    c:SetBackdropBorderColor(0.5, 0.42, 0.25)
                    local m = asc.mastery[i]
                    c.state:SetText(m and m.rank > 0 and ("|cffbbbbbbMastery " .. m.rank .. "/5|r") or "")
                    c.button:SetText("Ascend")
                    c.button:SetScript("OnClick", function()
                        local d = StaticPopup_Show("WORLDTIERS_ASCEND", "Ascend as " .. a.name .. "?" ..
                            (asc.chosen > 0 and ("\n\n" .. (asc.list[asc.chosen] and asc.list[asc.chosen].name or "Your Ascendancy") .. " is given up.") or ""))
                        if d then d.data = i end
                    end)
                end
                if open then c.button:Enable() else c.button:Disable() end
                c:Show()
            else
                c:Hide()
            end
        end
        RefreshMastery()
    end

    function WT.OpenAscendancy()
        if f:IsShown() then f:Hide() else f:Show() end
    end
    f:SetScript("OnShow", function() Send("J") Refresh() end)

    function WT.OnAscMessage(msg)
        local cmd = msg:match("^(J[AEMT])|")
        if not cmd then return false end
        local p = Split(msg:sub(4), "|")
        if cmd == "JT" then
            local at = {}
            for v in string.gmatch(p[1] or "", "%d+") do at[#at + 1] = tonumber(v) end
            if #at == 5 then asc.at = at end
        elseif cmd == "JM" then
            local slot = tonumber(p[1]) or 0
            local picks = {}
            for k = 1, 5 do picks[k] = tonumber((p[4] or ""):sub(k, k)) or 0 end
            asc.mastery[slot] = { points = tonumber(p[2]) or 0, rank = tonumber(p[3]) or 0, picks = picks }
        elseif cmd == "JA" then
            asc.building = asc.building or {}
            asc.building[tonumber(p[1]) or 0] = { name = p[2] or "?", icon = p[3], ks = p[4], text = p[5] }
        else
            asc.list, asc.building = asc.building or asc.list, nil
            asc.chosen, asc.need, asc.level = tonumber(p[1]) or 0, tonumber(p[2]) or 80, tonumber(p[3]) or 0
            if f:IsShown() then Refresh() end
            if WT.RefreshHubAscendancy then WT.RefreshHubAscendancy() end
        end
        return true
    end

    -- what the World Tiers window shows: the list, the one chosen, when they open
    function WT.AscInfo()
        return asc.list, asc.chosen, asc.need, asc.level, asc.mastery
    end
    function WT.AskAscendancies() Send("J") end
    SLASH_WORLDTIERSASCEND1 = "/ascend"
    SlashCmdList["WORLDTIERSASCEND"] = function() WT.OpenAscendancy() end
end
-- ---------------------------------------------------------------------------
-- Item tooltips: the stats an item gives you at your World Tier
--
-- The game draws an item's tooltip from the item's base numbers. The server
-- scales them for you, so this asks it (I:<bag>:<slot>) what the item is
-- worth to you, and rewrites the tooltip's numbers to match: white stats,
-- armour, weapon damage and DPS, and green "Equip:" ratings. Enchants, gems,
-- set bonuses and "Use:" lines are left as they are (they do not scale).
-- ---------------------------------------------------------------------------

local itemCache, itemPending, affixPending = {}, {}, {}
-- common, uncommon, rare; then Primal, a rune, and a grey note
local AFFIX_COLOR = { [0] = { 0.45, 0.65, 1 }, [1] = { 0.75, 0.45, 1 }, [2] = { 1, 0.5, 0 },
                      [3] = { 1, 0.19, 0.19 }, [4] = { 0.25, 0.88, 0.82 }, [5] = { 0.6, 0.6, 0.6 },
                      [6] = { 1, 0.5, 0 },           -- a class unique (orange)
                      [7] = { 0.12, 1, 0.59 } }      -- a class set piece (green)
WT.AFFIX_COLOR = AFFIX_COLOR

local function Round(n) return string.format("%d", math.floor(n + 0.5)) end

local function ScaleLine(fs, info)
    local text = fs:GetText()
    if not text or text == "" then return end
    local r, g, b = fs:GetTextColor()
    local white = r > 0.95 and g > 0.95 and b > 0.95
    local green = r < 0.25 and g > 0.9 and b < 0.25
    local new

    if info.armor ~= 1 and text:match("^%d+ Armor$") then
        new = text:gsub("^(%d+)", function(n) return Round(tonumber(n) * info.armor) end, 1)
    elseif info.dps ~= 1 and text:match("^%(([%d%.]+) damage per second%)$") then
        new = text:gsub("([%d%.]+)", function(n) return string.format("%.1f", tonumber(n) * info.dps) end, 1)
    elseif info.dps ~= 1 and text:match("Damage$") and text:match("^%+? ?%d+ %- %d+") then
        new = text:gsub("(%d+) %- (%d+)", function(a, c)
            return Round(tonumber(a) * info.dps) .. " - " .. Round(tonumber(c) * info.dps)
        end, 1)
    elseif info.stat ~= 1 and white and text:match("^%+%d+ %a") and not text:match("Resistance") then
        new = text:gsub("^%+(%d+)", function(n) return "+" .. Round(tonumber(n) * info.stat) end, 1)
    elseif info.stat ~= 1 and green and text:match("^Equip: ") then
        new = text:gsub("by (%d+)%.$", function(n) return "by " .. Round(tonumber(n) * info.stat) .. "." end, 1)
        new = new:gsub("^Equip: Restores (%d+) ", function(n) return "Equip: Restores " .. Round(tonumber(n) * info.stat) .. " " end, 1)
    end
    if new and new ~= text then fs:SetText(new) end
end

local function Decorate(tip, info)
    if not info or (not info.scaled and info.tier == "" and #info.affixes == 0) then return end
    local name = tip:GetName()
    for i = 2, tip:NumLines() do
        local fs = _G[name .. "TextLeft" .. i]
        if fs then ScaleLine(fs, info) end
    end
    if info.scaled then
        tip:AddLine(string.format("World Tier: item level %d (base %d)", info.eff, info.own), 1, 0.6, 0.2)
    end
    if info.tier ~= "" then
        tip:AddLine("Earned at " .. info.tier, 1, 0.6, 0.2)
    end
    if info.power ~= "" then
        tip:AddLine("Tier Power " .. info.power .. " damage", 1, 0.6, 0.2)
    end
    local special
    for _, a in ipairs(info.affixes) do
        local c = AFFIX_COLOR[a.rarity] or AFFIX_COLOR[0]
        if a.rarity == 6 then
            -- a class unique: its own block, the name in orange
            special = special or "U"
            local tree, uname, what = a.text:match("^%[Unique: ([^%]]+)%] ([^:]+): (.*)$")
            tip:AddLine(" ")
            tip:AddLine("Unique: " .. (uname or a.text), c[1], c[2], c[3])
            if what then
                tip:AddLine(what, 1, 0.85, 0.6, true)
                tip:AddLine(tree, 0.55, 0.55, 0.55)
            end
        elseif a.rarity == 7 then
            -- a class set piece: set~worn~two-piece~four-piece~whose
            special = special == "U" and "B" or "S"
            local f = {}
            for part in string.gmatch(a.text .. "~", "(.-)~") do f[#f + 1] = part end
            local worn = tonumber(f[2]) or 0
            tip:AddLine(" ")
            tip:AddLine(string.format("Set: %s (%d/4)", f[1] or "?", math.min(4, worn)), c[1], c[2], c[3])
            for i, need in ipairs({ 2, 4 }) do
                local on = worn >= need
                tip:AddLine(string.format("(%d) %s", need, f[2 + i] or ""), on and 0.7 or 0.5, on and 1 or 0.5, on and 0.8 or 0.5, true)
            end
            if f[5] and f[5] ~= "" then tip:AddLine(f[5], 1, 0.3, 0.3) end
        else
            tip:AddLine(a.text, c[1], c[2], c[3], true)
        end
    end
    if special then
        -- the name in its colour, a tag on the top line, and a coloured border
        local c = special == "U" and AFFIX_COLOR[6] or AFFIX_COLOR[7]
        local left, right = _G[name .. "TextLeft1"], _G[name .. "TextRight1"]
        if left then left:SetTextColor(c[1], c[2], c[3]) end
        if right then
            right:SetText(special == "U" and "UNIQUE" or special == "S" and "SET" or "UNIQUE  SET")
            right:SetTextColor(c[1], c[2], c[3])
            right:Show()
        end
        if tip.SetBackdropBorderColor then tip:SetBackdropBorderColor(c[1], c[2], c[3]) tip.wtBorder = true end
    end
    tip:Show()
end
-- a tooltip that showed one: back to the usual border
local function ResetBorder(tip)
    if tip.wtBorder and tip.SetBackdropBorderColor then
        tip:SetBackdropBorderColor(TOOLTIP_DEFAULT_COLOR and TOOLTIP_DEFAULT_COLOR.r or 1, TOOLTIP_DEFAULT_COLOR and TOOLTIP_DEFAULT_COLOR.g or 1,
            TOOLTIP_DEFAULT_COLOR and TOOLTIP_DEFAULT_COLOR.b or 1)
        tip.wtBorder = nil
    end
end
WT.ResetTooltipBorder = ResetBorder

-- Every tooltip that shows your items: the main one and the comparison ones
-- ("Currently Equipped"), which the game fills from the item's base numbers too.
local tips = { GameTooltip }

-- Look the item up (or ask for it); fill the tooltip in when the answer comes.
local function Lookup(tip, bag, slot, link, redo)
    if not link then return end
    local key = bag .. ":" .. slot
    local hit = itemCache[key]
    tip.wtKey, tip.wtRedo, tip.wtDone = key, redo, nil
    if hit and hit.link == link then
        tip.wtDone = true
        Decorate(tip, hit.info)
        return
    end
    local now = GetTime()
    if not itemPending[key] or now - itemPending[key] > 2 then
        itemPending[key] = now
        itemPending[key .. "link"] = link
        Send("I:" .. bag .. ":" .. slot)
    end
end

hooksecurefunc(GameTooltip, "SetBagItem", function(tip, bag, slot)
    Lookup(tip, bag, slot - 1, GetContainerItemLink(bag, slot), function() tip:SetBagItem(bag, slot) end)
end)

hooksecurefunc(GameTooltip, "SetInventoryItem", function(tip, unit, invSlot)
    if unit ~= "player" or not invSlot then return end
    local bag, slot
    if invSlot >= 1 and invSlot <= 19 then
        bag, slot = -2, invSlot - 1
    elseif invSlot >= 40 and invSlot <= 67 then
        bag, slot = -1, invSlot - 40      -- the bank's own 28 slots
    else
        return
    end
    Lookup(tip, bag, slot, GetInventoryItemLink("player", invSlot), function() tip:SetInventoryItem("player", invSlot) end)
end)

-- An item in the loot window (0.34): the server rolls it as you look, and
-- the tooltip shows what it will be; looting it gives exactly that.
local lootCache, lootPending = {}, {}
hooksecurefunc(GameTooltip, "SetLootItem", function(tip, slot)
    local link = GetLootSlotLink and GetLootSlotLink(slot)
    local id = link and tonumber(link:match("item:(%d+)"))
    if not id then return end
    local key = "L:" .. id
    tip.wtKey, tip.wtRedo, tip.wtDone = key, function() tip:SetLootItem(slot) end, nil
    if lootCache[id] then
        tip.wtDone = true
        Decorate(tip, lootCache[id])
        return
    end
    local now = GetTime()
    if not lootPending[id] or now - lootPending[id] > 2 then
        lootPending[id] = now
        Send("IL:" .. id)
    end
end)
-- LX|entry|rarity|text ... LP|entry|scaled|effIlvl|ownIlvl|stat|dps|armor|tier|power
local lootAffixes = {}
function WT.OnLootPreviewMessage(msg)
    local cmd = msg:sub(1, 3)
    if cmd ~= "LX|" and cmd ~= "LP|" then return false end
    local f = Split(msg:sub(4), "|")
    local id = tonumber(f[1])
    if not id then return true end
    if cmd == "LX|" then
        lootAffixes[id] = lootAffixes[id] or {}
        table.insert(lootAffixes[id], { rarity = tonumber(f[2]) or 0, text = f[3] or "" })
        return true
    end
    lootCache[id] = {
        scaled = f[2] == "1", eff = tonumber(f[3]) or 0, own = tonumber(f[4]) or 0,
        stat = tonumber(f[5]) or 1, dps = tonumber(f[6]) or 1, armor = tonumber(f[7]) or 1,
        tier = f[8] or "", power = f[9] or "", affixes = lootAffixes[id] or {},
    }
    lootAffixes[id], lootPending[id] = nil, nil
    if WT.PaintLootGlows then WT.PaintLootGlows() end   -- a unique or set piece glows in the loot window
    if GameTooltip:IsShown() and GameTooltip.wtKey == "L:" .. id and not GameTooltip.wtDone then
        GameTooltip.wtDone = true
        Decorate(GameTooltip, lootCache[id])
    end
    return true
end
-- what a loot window item will be, if it has been rolled: "U" a unique, "S" a set piece, "B" both (nil: neither)
function WT.LootItemKind(id)
    local info = id and lootCache[id]
    if not info then return nil end
    local u, st
    for _, a in ipairs(info.affixes) do
        u = u or a.rarity == 6
        st = st or a.rarity == 7
    end
    return (u and st) and "B" or u and "U" or st and "S" or nil
end
-- a new loot window: new rolls, asked for every item at once (so a unique or
-- set piece glows before you even look); the server keeps each roll, so
-- reopening shows the same ones
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("LOOT_OPENED")
    f:RegisterEvent("LOOT_CLOSED")
    f:SetScript("OnEvent", function(self, event)
        lootCache, lootPending, lootAffixes = {}, {}, {}
        if event ~= "LOOT_OPENED" or not GetNumLootItems then return end
        local now = GetTime()
        for slot = 1, GetNumLootItems() do
            local link = GetLootSlotLink and GetLootSlotLink(slot)
            local id = link and tonumber(link:match("item:(%d+)"))
            if id and not lootPending[id] then
                lootPending[id] = now
                Send("IL:" .. id)
            end
        end
    end)
end

GameTooltip:HookScript("OnTooltipCleared", function(tip) tip.wtKey, tip.wtRedo, tip.wtDone = nil, nil, nil ResetBorder(tip) end)

-- A comparison tooltip shows one of your equipped items: find which slot, and
-- scale it like any other. Two of the same ring? The index says which.
local function HookCompare(tip)
    if not tip or not tip.SetHyperlinkCompareItem then return end
    tips[#tips + 1] = tip
    hooksecurefunc(tip, "SetHyperlinkCompareItem", function(self, link, index, shift, main)
        local _, shown = self:GetItem()
        if not shown then return end
        local id = shown:match("item:(%d+)")
        local found, seen
        for inv = 1, 19 do
            local l = GetInventoryItemLink("player", inv)
            if l and (l == shown or (id and l:match("item:(%d+)") == id)) then
                seen = (seen or 0) + 1
                found = inv
                if l == shown and (seen >= (index or 1)) then break end
            end
        end
        if not found then return end
        Lookup(self, -2, found - 1, GetInventoryItemLink("player", found), function()
            if self:IsShown() then self:SetHyperlinkCompareItem(link, index, shift, main) end
        end)
    end)
    tip:HookScript("OnTooltipCleared", function(self) self.wtKey, self.wtRedo, self.wtDone = nil, nil, nil ResetBorder(self) end)
end
for _, name in ipairs({ "ShoppingTooltip1", "ShoppingTooltip2", "ShoppingTooltip3", "ItemRefShoppingTooltip1", "ItemRefShoppingTooltip2", "ItemRefShoppingTooltip3" }) do
    HookCompare(_G[name])
end

-- I|bag|slot|entry|scaled|effIlvl|ownIlvl|stat|dps|armor|tier|power, and IC| (forget everything)
function WT.OnItemMessage(msg)
    if msg:sub(1, 3) == "IX|" then
        local f = Split(msg:sub(4), "|")
        local key = f[1] .. ":" .. f[2]
        affixPending[key] = affixPending[key] or {}
        table.insert(affixPending[key], { rarity = tonumber(f[3]) or 0, text = f[4] or "" })
        return true
    end
    if msg:sub(1, 3) == "IC|" then
        itemCache, itemPending, affixPending = {}, {}, {}
        for _, tip in ipairs(tips) do
            if tip:IsShown() and tip.wtRedo then tip.wtRedo() end
        end
        return true
    end
    if msg:sub(1, 2) ~= "I|" then return false end
    local f = Split(msg:sub(3), "|")
    local key = f[1] .. ":" .. f[2]
    itemCache[key] = {
        link = itemPending[key .. "link"],
        info = {
            scaled = f[4] == "1", eff = tonumber(f[5]) or 0, own = tonumber(f[6]) or 0,
            stat = tonumber(f[7]) or 1, dps = tonumber(f[8]) or 1, armor = tonumber(f[9]) or 1,
            tier = f[10] or "", power = f[11] or "",
            affixes = affixPending[key] or {},
        },
    }
    affixPending[key] = nil
    itemPending[key] = nil
    -- fill in every tooltip waiting for this item, where it stands (the comparison tooltips stay put)
    for _, tip in ipairs(tips) do
        if tip:IsShown() and tip.wtKey == key and not tip.wtDone then
            tip.wtDone = true
            Decorate(tip, itemCache[key].info)
        end
    end
    return true
end

local itemEvents = CreateFrame("Frame")
itemEvents:RegisterEvent("BAG_UPDATE")
itemEvents:RegisterEvent("UNIT_INVENTORY_CHANGED")
itemEvents:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
itemEvents:SetScript("OnEvent", function(self, event, unit)
    if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end
    itemCache = {}
end)

-- ---------------------------------------------------------------------------
-- Uniques and set pieces glow (0.31): a pulsing border on them in your bags,
-- the bank and the character window (Blizzard's bags, or Bagnon / Combuctor), orange for a unique and green for a
-- set piece. The server says where they are (UG|bag,slot,kind;... UGE|),
-- asked again when your bags change. And a moment when one drops: a toast,
-- a sound (UF|kind|name|item).
-- ---------------------------------------------------------------------------

do
    local COLORS = { U = { 1, 0.5, 0 }, S = { 0.12, 1, 0.59 }, B = { 1, 0.85, 0.2 } }
    local where, building = {}, {}
    local glows = {}

    local function Glow(button)
        if not button then return nil end
        local g = button.wtGlow
        if not g then
            g = button:CreateTexture(nil, "OVERLAY")
            g:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            g:SetBlendMode("ADD")
            local w = (button:GetWidth() or 37)
            Size(g, w * 1.9, w * 1.9)
            g:SetPoint("CENTER", button, "CENTER", 0, 0)
            g:Hide()
            button.wtGlow = g
            glows[#glows + 1] = g
        end
        return g
    end

    local function Paint(button, bag, slot)
        if not button then return end
        local kind = where[bag .. ":" .. slot]
        if kind then
            local g = Glow(button)
            local c = COLORS[kind] or COLORS.S
            g:SetVertexColor(c[1], c[2], c[3])
            g:Show()
        elseif button.wtGlow then
            button.wtGlow:Hide()
        end
    end

    -- the bags (and bank bags): the frame's id is the bag, each button's id its slot (from 1)
    local function PaintContainer(frame)
        if not frame or not frame:IsShown() then return end
        local bag = frame:GetID()
        local name = frame:GetName()
        for i = 1, 36 do
            local b = _G[name .. "Item" .. i]
            if not b then break end
            if b:IsShown() then Paint(b, bag, b:GetID() - 1) elseif b.wtGlow then b.wtGlow:Hide() end
        end
    end
    local SLOTS = { "Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands",
                    "Finger0", "Finger1", "Trinket0", "Trinket1", "Back", "MainHand", "SecondaryHand", "Ranged", "Tabard" }
    -- Bagnon and Combuctor (WotLK): their own item buttons, one class for all of
    -- them (ItemSlot). Each button's parent is its bag, its id the slot (from 1).
    -- Another character's bags (Bagnon can show them) never glow.
    local bagButtons = setmetatable({}, { __mode = "k" })
    local me = UnitName and UnitName("player")
    local function PaintBagButton(item)
        if not item then return end
        bagButtons[item] = true
        if not item:IsVisible() then return end
        local owner = item.GetPlayer and item:GetPlayer()
        if (owner and owner ~= me) or not (item.GetBag and item:GetID()) then
            if item.wtGlow then item.wtGlow:Hide() end
            return
        end
        Paint(item, item:GetBag(), item:GetID() - 1)
        -- its own quality border would mix with the glow: the glow wins
        if item.wtGlow and item.wtGlow:IsShown() and item.border and item.border.Hide then item.border:Hide() end
    end
    local hooked = {}
    local function HookBagAddons()
        for _, name in ipairs({ "Bagnon", "Combuctor" }) do
            local addon = _G[name]
            if not addon and LibStub then
                local ace = LibStub("AceAddon-3.0", true)
                addon = ace and ace:GetAddon(name, true)
            end
            local class = addon and addon.ItemSlot
            if class and not hooked[name] and type(class.Update) == "function" then
                hooked[name] = true
                hooksecurefunc(class, "Update", PaintBagButton)
                if type(class.UpdateBorder) == "function" then hooksecurefunc(class, "UpdateBorder", PaintBagButton) end
            end
        end
    end
    HookBagAddons()
    WT.HookBagAddons = HookBagAddons

    local function PaintAll()
        for i = 1, (NUM_CONTAINER_FRAMES or 13) do PaintContainer(_G["ContainerFrame" .. i]) end
        for item in pairs(bagButtons) do PaintBagButton(item) end
        for i = 1, 28 do
            local b = _G["BankFrameItem" .. i]
            if b and b:IsVisible() then Paint(b, -1, i - 1) end
        end
        for i, s in ipairs(SLOTS) do Paint(_G["Character" .. s .. "Slot"], -2, i - 1) end
    end
    WT.PaintGlows = PaintAll

    -- the loot window (0.34): its items are rolled when it opens (tooltips.lua),
    -- so a unique or set piece glows there before it is picked up
    function WT.PaintLootGlows()
        for i = 1, 40 do
            local b = _G["LootButton" .. i]
            if not b then break end
            local kind
            if b:IsShown() and b.slot and GetLootSlotLink and WT.LootItemKind then
                local link = GetLootSlotLink(b.slot)
                kind = WT.LootItemKind(link and tonumber(link:match("item:(%d+)")))
            end
            if kind then
                local g = Glow(b)
                local c = COLORS[kind]
                g:SetVertexColor(c[1], c[2], c[3])
                g:Show()
            elseif b.wtGlow then
                b.wtGlow:Hide()
            end
        end
    end
    if LootFrame_UpdateButton then hooksecurefunc("LootFrame_UpdateButton", function() WT.PaintLootGlows() end) end
    if LootFrame_Update then hooksecurefunc("LootFrame_Update", function() WT.PaintLootGlows() end) end

    if ContainerFrame_Update then hooksecurefunc("ContainerFrame_Update", function(frame) PaintContainer(frame) end) end
    if PaperDollItemSlotButton_Update then
        hooksecurefunc("PaperDollItemSlotButton_Update", function(button)
            local id = button and button:GetID()
            if id and id >= 1 and id <= 19 then Paint(button, -2, id - 1) end
        end)
    end
    if BankFrameItemButton_Update then
        hooksecurefunc("BankFrameItemButton_Update", function(button)
            if button and not button.isBag and button:GetParent() == BankFrame then Paint(button, -1, button:GetID() - 1) end
        end)
    end

    -- one gentle pulse for all of them
    local pulse = CreateFrame("Frame")
    local t = 0
    pulse:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        local a = 0.55 + 0.45 * math.sin(t * 3)
        for _, g in ipairs(glows) do if g:IsShown() then g:SetAlpha(a) end end
    end)

    -- ask where they are: on login, when bags change (once a second at most), at the bank
    local ask = CreateFrame("Frame")
    ask:RegisterEvent("PLAYER_ENTERING_WORLD")
    ask:RegisterEvent("ADDON_LOADED")
    ask:RegisterEvent("BAG_UPDATE")
    ask:RegisterEvent("UNIT_INVENTORY_CHANGED")
    ask:RegisterEvent("BANKFRAME_OPENED")
    ask:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
    ask:Hide()
    ask:SetScript("OnEvent", function(self, event, unit)
        if event == "ADDON_LOADED" then HookBagAddons() return end   -- a bag addon loaded after us
        if event == "PLAYER_ENTERING_WORLD" then me = UnitName("player") HookBagAddons() end
        if event == "UNIT_INVENTORY_CHANGED" and unit ~= "player" then return end
        self.wait = event == "PLAYER_ENTERING_WORLD" and 3 or 1
        self:Show()
    end)
    ask:SetScript("OnUpdate", function(self, elapsed)
        self.wait = (self.wait or 0) - elapsed
        if self.wait <= 0 then
            self:Hide()
            Send("UG")
        end
    end)

    -- the toast
    local toast = CreateFrame("Frame", "WorldTiersLootToast", UIParent)
    Size(toast, 340, 64)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -170)
    toast:SetFrameStrata("HIGH")
    toast:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    toast:SetBackdropColor(0.05, 0.04, 0.02, 0.92)
    toast:Hide()
    local tIcon = toast:CreateTexture(nil, "ARTWORK")
    Size(tIcon, 40, 40)
    tIcon:SetPoint("LEFT", 12, 0)
    local tHead = toast:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    tHead:SetPoint("TOPLEFT", tIcon, "TOPRIGHT", 10, 0)
    tHead:SetWidth(270)
    tHead:SetJustifyH("LEFT")
    local tText = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tText:SetPoint("TOPLEFT", tHead, "BOTTOMLEFT", 0, -4)
    tText:SetWidth(270)
    tText:SetJustifyH("LEFT")
    toast:SetScript("OnUpdate", function(self, elapsed)
        self.left = (self.left or 0) - elapsed
        if self.left <= 0 then self:Hide() return end
        self:SetAlpha(math.min(1, self.left))   -- fades out over the last second
    end)
    local function Toast(kind, name, item, entry)
        -- 0.35: the big announcement in the middle of the screen (splash.lua)
        if WT.Splash then
            local id = tonumber(entry)
            local icon = id and GetItemIcon and GetItemIcon(id)
            local itemText = item or ""
            if id and GetItemInfo then
                local _, _, quality = GetItemInfo(id)
                local qc = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
                if qc and qc.hex then itemText = qc.hex .. itemText .. "|r" end
            end
            WT.Splash({
                title = kind == "U" and "Unique Found" or kind == "S" and "Set Piece Found" or "Unique Set Piece",
                sub = name or "",
                detail = (kind == "U" and "on " or "") .. itemText,
                color = COLORS[kind] or COLORS.S,
                icon = icon or (kind == "U" and "Interface\\Icons\\INV_Misc_Gem_Variety_02" or "Interface\\Icons\\INV_Chest_Plate02"),
                sound = "Sound\\Spells\\AchievmentSound1.wav",
            })
            return
        end
        local c = COLORS[kind] or COLORS.S
        tIcon:SetTexture(kind == "U" and "Interface\\Icons\\INV_Misc_Gem_Variety_02" or "Interface\\Icons\\INV_Chest_Plate02")
        tHead:SetText(kind == "U" and "Unique found!" or "Set piece found!")
        tHead:SetTextColor(c[1], c[2], c[3])
        tText:SetText((item or "") .. "|n|cffbbbbbb" .. (kind == "U" and "carries " or "part of ") .. (name or "") .. "|r")
        toast:SetBackdropBorderColor(c[1], c[2], c[3])
        toast.left = 5
        toast:SetAlpha(1)
        toast:Show()
        if PlaySoundFile then
            PlaySoundFile(kind == "U" and "Sound\\Spells\\AchievmentSound1.wav" or "Sound\\Interface\\LevelUp.wav")
        end
    end
    WT.LootToast = Toast

    function WT.OnSpecialMessage(msg)
        local cmd = msg:match("^(U[GF]E?)|")
        if not cmd then return false end
        local rest = msg:sub(#cmd + 2)
        if cmd == "UG" then
            for bag, slot, kind in string.gmatch(rest, "(%-?%d+),(%d+),(%a);") do
                building[bag .. ":" .. slot] = kind
            end
        elseif cmd == "UGE" then
            where, building = building, {}
            PaintAll()
        elseif cmd == "UF" then
            local f = Split(rest, "|")
            Toast(f[1], f[2], f[3], f[4])
        end
        return true
    end
end

-- ---------------------------------------------------------------------------
-- Announcements in the middle of the screen (0.35): a Paragon level gained,
-- and a unique or set piece looted. A wide banner, big lettering, a sound;
-- it grows in, holds, and fades. Several at once wait their turn.
--   PL|level|gained|free       a Paragon level
--   (WT.Splash is also called for UF| by glow.lua)
-- ---------------------------------------------------------------------------

do
    local f = CreateFrame("Frame", "WorldTiersSplash", UIParent)
    Size(f, 640, 132)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 170)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:EnableMouse(false)
    f:Hide()

    -- the banner: dark in the middle, fading out to either side, a coloured line above and below
    local function Half(point, l2r)
        local t = f:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(1, 1, 1, 1)
        t:SetPoint("TOP", 0, -14)
        t:SetPoint("BOTTOM", 0, 14)
        t:SetWidth(320)
        t:SetPoint(point, f, "CENTER", 0, 0)
        if t.SetGradientAlpha then
            if l2r then t:SetGradientAlpha("HORIZONTAL", 0, 0, 0, 0, 0, 0, 0, 0.78)
            else t:SetGradientAlpha("HORIZONTAL", 0, 0, 0, 0.78, 0, 0, 0, 0) end
        else
            t:SetVertexColor(0, 0, 0, 0.6)
        end
        return t
    end
    Half("RIGHT", true)
    Half("LEFT", false)
    local lines = {}
    for i, y in ipairs({ -12, 12 }) do
        for side = 1, 2 do
            local t = f:CreateTexture(nil, "ARTWORK")
            t:SetTexture(1, 1, 1, 1)
            t:SetHeight(2)
            t:SetWidth(300)
            t:SetPoint(side == 1 and "RIGHT" or "LEFT", f, i == 1 and (side == 1 and "TOP" or "TOP") or "BOTTOM", 0, y)
            lines[#lines + 1] = { tex = t, fadeToRight = side == 2 }
        end
    end

    local icon = f:CreateTexture(nil, "ARTWORK")
    Size(icon, 52, 52)
    icon:SetPoint("CENTER", f, "TOP", 0, -6)
    local iconRing = f:CreateTexture(nil, "OVERLAY")
    iconRing:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    iconRing:SetBlendMode("ADD")
    Size(iconRing, 100, 100)
    iconRing:SetPoint("CENTER", icon, "CENTER")

    local head = f:CreateFontString(nil, "OVERLAY")
    head:SetFont("Fonts\\MORPHEUS.TTF", 34, "OUTLINE")
    head:SetPoint("TOP", 0, -36)
    local sub = f:CreateFontString(nil, "OVERLAY")
    sub:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE")
    sub:SetPoint("TOP", head, "BOTTOM", 0, -6)
    sub:SetWidth(600)
    local detail = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detail:SetPoint("TOP", sub, "BOTTOM", 0, -4)
    detail:SetWidth(600)

    local queue, t, phase = {}, 0, nil
    local IN, HOLD, OUT = 0.35, 3.6, 1.0

    local function ShowNext()
        local a = table.remove(queue, 1)
        if not a then f:Hide() phase = nil return end
        local c = a.color
        head:SetText(a.title)
        head:SetTextColor(c[1], c[2], c[3])
        sub:SetText(a.sub or "")
        detail:SetText(a.detail or "")
        for _, l in ipairs(lines) do
            if l.tex.SetGradientAlpha then
                if l.fadeToRight then l.tex:SetGradientAlpha("HORIZONTAL", c[1], c[2], c[3], 1, c[1], c[2], c[3], 0)
                else l.tex:SetGradientAlpha("HORIZONTAL", c[1], c[2], c[3], 0, c[1], c[2], c[3], 1) end
            else
                l.tex:SetVertexColor(c[1], c[2], c[3], 0.8)
            end
        end
        if a.icon then
            icon:SetTexture(a.icon)
            icon:Show()
            iconRing:SetVertexColor(c[1], c[2], c[3])
            iconRing:Show()
        else
            icon:Hide()
            iconRing:Hide()
        end
        if a.sound and PlaySoundFile then PlaySoundFile(a.sound) end
        t, phase = 0, "in"
        f:SetAlpha(0)
        f:SetScale(1.25)
        f:Show()
    end

    f:SetScript("OnUpdate", function(self, elapsed)
        t = t + elapsed
        if phase == "in" then
            local k = math.min(1, t / IN)
            self:SetAlpha(k)
            self:SetScale(1.25 - 0.25 * k)   -- grows in, settling to its size
            if k >= 1 then phase, t = "hold", 0 end
        elseif phase == "hold" then
            if t >= HOLD then phase, t = "out", 0 end
        elseif phase == "out" then
            local k = math.min(1, t / OUT)
            self:SetAlpha(1 - k)
            if k >= 1 then ShowNext() end
        end
    end)

    -- { title, sub, detail, color = {r,g,b}, icon, sound }
    function WT.Splash(a)
        if not a or not a.title then return end
        a.color = a.color or { 1, 0.82, 0 }
        queue[#queue + 1] = a
        if not phase then ShowNext() end
    end

    function WT.OnSplashMessage(msg)
        if msg:sub(1, 3) ~= "PL|" then return false end
        local p = Split(msg:sub(4), "|")
        local level, gained, free = tonumber(p[1]) or 0, tonumber(p[2]) or 1, tonumber(p[3]) or 0
        WT.Splash({
            title = "Paragon Level " .. level,
            sub = gained > 1 and string.format("+%d Paragon points", gained) or "+1 Paragon point",
            detail = string.format("%d to spend on your Paragon Board (/paragon)", free),
            color = { 0.4, 0.8, 1 },
            icon = "Interface\\Icons\\Spell_Holy_EmpowerChampion",
            sound = "Sound\\Interface\\LevelUp.wav",
        })
        return true
    end

    SLASH_WORLDTIERSSPLASH1 = "/wtsplash"
    SlashCmdList["WORLDTIERSSPLASH"] = function()   -- a look at all three
        WT.OnSplashMessage("PL|151|1|3")
        WT.Splash({ title = "Unique Found", sub = "Colossus Smash", detail = "on Helm of the Example", color = { 1, 0.5, 0 },
                    icon = "Interface\\Icons\\INV_Misc_Gem_Variety_02", sound = "Sound\\Spells\\AchievmentSound1.wav" })
        WT.Splash({ title = "Set Piece Found", sub = "Battlegear of the Colossus", detail = "Helm of the Example", color = { 0.12, 1, 0.59 },
                    icon = "Interface\\Icons\\INV_Chest_Plate02", sound = "Sound\\Spells\\AchievmentSound1.wav" })
    end
end

-- ---------------------------------------------------------------------------
-- The Paragon experience bar: at the level cap, where the experience bar was
-- ---------------------------------------------------------------------------

local function Commas(n)
    local s = string.format("%d", n)
    local out, count = "", 0
    for i = #s, 1, -1 do
        out = s:sub(i, i) .. out
        count = count + 1
        if count % 3 == 0 and i > 1 then out = "," .. out end
    end
    return out
end

local bar = CreateFrame("StatusBar", "WorldTiersParagonBar", MainMenuBar)
bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
bar:SetStatusBarColor(0.58, 0.2, 0.9)
bar:SetMinMaxValues(0, 1)
bar:SetValue(0)
bar:SetFrameLevel(MainMenuBar:GetFrameLevel() + 5)
bar:EnableMouse(true)
bar:Hide()

local barBg = bar:CreateTexture(nil, "BACKGROUND")
barBg:SetAllPoints()
barBg:SetTexture(0, 0, 0, 0.6)

local barSpark = bar:CreateTexture(nil, "OVERLAY")
barSpark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
barSpark:SetBlendMode("ADD")
Size(barSpark, 16, 24)

local barText = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
barText:SetPoint("CENTER", 0, 1)
barText:Hide()

WT.bar = { level = 0, xp = 0, xpNext = 1, atCap = false }

local function PlaceBar()
    bar:ClearAllPoints()
    if ReputationWatchBar and ReputationWatchBar:IsShown() then
        -- a watched reputation has the experience bar's spot: sit just above it
        bar:SetPoint("BOTTOMLEFT", ReputationWatchBar, "TOPLEFT", 0, 1)
        bar:SetPoint("BOTTOMRIGHT", ReputationWatchBar, "TOPRIGHT", 0, 1)
        bar:SetHeight(8)
    else
        bar:SetPoint("TOPLEFT", MainMenuExpBar, "TOPLEFT", 0, 0)
        bar:SetPoint("BOTTOMRIGHT", MainMenuExpBar, "BOTTOMRIGHT", 0, 0)
    end
end

local function UpdateBar()
    local b = WT.bar
    if not b.atCap then bar:Hide() return end
    PlaceBar()
    local max = math.max(1, b.xpNext)
    bar:SetMinMaxValues(0, max)
    bar:SetValue(b.xpNext > 0 and math.min(b.xp, max) or max)
    local pct = b.xpNext > 0 and (b.xp / max) or 1
    barSpark:ClearAllPoints()
    barSpark:SetPoint("CENTER", bar, "LEFT", bar:GetWidth() * pct, 0)
    if b.xpNext > 0 then
        barText:SetText(string.format("Paragon %d  -  %s / %s (%d%%)", b.level, Commas(b.xp), Commas(b.xpNext), math.floor(pct * 100)))
    else
        barText:SetText(string.format("Paragon %d  -  highest level", b.level))
    end
    bar:Show()
end

bar:SetScript("OnSizeChanged", UpdateBar)
bar:SetScript("OnEnter", function(self)
    barText:Show()
    local b = WT.bar
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine(string.format("Paragon level %d", b.level), 0.75, 0.5, 1)
    if b.xpNext > 0 then
        GameTooltip:AddLine(string.format("%s / %s experience (%s to go)", Commas(b.xp), Commas(b.xpNext), Commas(b.xpNext - b.xp)), 1, 1, 1)
        GameTooltip:AddLine("Every Paragon level is a point for the Paragon Tree.", 0.8, 0.8, 0.8, true)
    end
    if WT.state.free > 0 then
        GameTooltip:AddLine(string.format("%d point%s to spend.", WT.state.free, WT.state.free == 1 and "" or "s"), 0.2, 1, 0.2)
    end
    GameTooltip:AddLine("Click to open the Paragon Tree.", 0.6, 0.8, 1)
    GameTooltip:Show()
end)
bar:SetScript("OnLeave", function()
    barText:Hide()
    GameTooltip:Hide()
end)
bar:SetScript("OnMouseUp", function() frame:Show() end)

if ReputationWatchBar_Update then hooksecurefunc("ReputationWatchBar_Update", function() if bar:IsShown() then PlaceBar() end end) end

-- P|level|xp|xpNext|atCap
function WT.OnBarMessage(msg)
    if msg:sub(1, 2) ~= "P|" then return false end
    local f = Split(msg:sub(3), "|")
    local b = WT.bar
    b.level, b.xp, b.xpNext, b.atCap = tonumber(f[1]) or 0, tonumber(f[2]) or 0, tonumber(f[3]) or 0, f[4] == "1"
    UpdateBar()
    return true
end

-- ---------------------------------------------------------------------------
-- The Forge: reforge one piece to your tier, reroll its affixes
-- ---------------------------------------------------------------------------

local ROWS, ROW_H = 10, 40

-- ---------------------------------------------------------------------------
-- The Gold Reserve: gold past the game's cap, kept by the server without a
-- limit. Shown in the Forge, under the backpack's money, and on the panel.
-- ---------------------------------------------------------------------------

WT.reserve = "0"
local reserveText
if ContainerFrame1MoneyFrame then
    reserveText = ContainerFrame1MoneyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    reserveText:SetPoint("TOPRIGHT", ContainerFrame1MoneyFrame, "BOTTOMRIGHT", -4, -2)
    reserveText:Hide()
end

function WT.SetReserve(copper)
    WT.reserve = (copper or "0"):gsub("%D", "")
    if WT.reserve == "" then WT.reserve = "0" end
    if reserveText then
        if #WT.reserve > 4 then
            reserveText:SetText("|cffffd100+" .. WT.GoldFromCopperString(WT.reserve) .. " in Reserve|r")
            reserveText:Show()
        else
            reserveText:Hide()
        end
    end
    if WT.RefreshPanel then WT.RefreshPanel() end
    if WT.forgeMoneyRefresh then WT.forgeMoneyRefresh() end
end

function WT.MoneyLine()
    local line = "Your gold: " .. (GetCoinTextureString and GetCoinTextureString(GetMoney()) or tostring(math.floor(GetMoney() / 10000)) .. "g")
    if #WT.reserve > 4 then line = line .. "   |cffffd100Reserve: " .. WT.GoldFromCopperString(WT.reserve) .. "|r" end
    return line
end
local forgeData = { items = {}, order = {}, tier = 0, tierName = "", money = 0, runes = {}, mats = {}, codex = {}, trees = {} }
local forgeMode = "gear"   -- or "codex"
local pendingForge = nil
local forgeOffset, forgeSelected = 0, nil

local function GroupDigits(digits)
    local out = digits:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- copper (a decimal string of any length) as "1,234,567 gold"
local function GoldFromCopperString(s)
    s = (s or "0"):gsub("%D", "")
    if #s <= 4 then return "0 gold" end
    return GroupDigits(s:sub(1, #s - 4)) .. " gold"
end
WT.GoldFromCopperString = GoldFromCopperString

local function Money(copper)
    if copper >= 1e8 then return GoldFromCopperString(string.format("%.0f", copper)) end
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return string.format("%dg %ds", math.floor(copper / 10000), math.floor(copper / 100) % 100)
end

local function ItemLink(it)
    if it.bag == -2 then return GetInventoryItemLink("player", it.slot + 1) end
    return GetContainerItemLink(it.bag, it.slot + 1)
end

local function ItemIcon(it)
    if it.bag == -2 then return GetInventoryItemTexture("player", it.slot + 1) end
    return (GetContainerItemInfo(it.bag, it.slot + 1))
end

local function ItemTooltip(owner, it)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if it.bag == -2 then GameTooltip:SetInventoryItem("player", it.slot + 1) else GameTooltip:SetBagItem(it.bag, it.slot + 1) end
    GameTooltip:Show()
end

local forge = CreateFrame("Frame", "WorldTiersForgeFrame", UIParent)
Size(forge, 720, 530)
forge:SetPoint("CENTER")
forge:SetFrameStrata("HIGH")
forge:SetToplevel(true)
forge:EnableMouse(true)
forge:SetMovable(true)
forge:SetClampedToScreen(true)
forge:SetBackdrop(frame:GetBackdrop() or {
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
})
forge:Hide()
tinsert(UISpecialFrames, "WorldTiersForgeFrame")

local forgeDrag = CreateFrame("Frame", nil, forge)
forgeDrag:SetPoint("TOPLEFT", 12, -8)
forgeDrag:SetPoint("TOPRIGHT", -40, -8)
forgeDrag:SetHeight(26)
forgeDrag:EnableMouse(true)
forgeDrag:RegisterForDrag("LeftButton")
forgeDrag:SetScript("OnDragStart", function() forge:StartMoving() end)
forgeDrag:SetScript("OnDragStop", function() forge:StopMovingOrSizing() end)

local forgeTitle = forge:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
forgeTitle:SetPoint("TOP", 0, -16)
forgeTitle:SetText("The Forge")

local forgeClose = CreateFrame("Button", nil, forge, "UIPanelCloseButton")
forgeClose:SetPoint("TOPRIGHT", -6, -6)

-- Gear | Power Codex
local function ForgeTab(text, x)
    local b = CreateFrame("Button", nil, forge, "UIPanelButtonTemplate")
    Size(b, 104, 22)
    b:SetPoint("TOPLEFT", x, -34)
    b:SetText(text)
    return b
end
local gearTab = ForgeTab("Gear", 18)
local codexTab = ForgeTab("Power Codex", 126)

local forgeTier = forge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
forgeTier:SetPoint("LEFT", codexTab, "RIGHT", 12, 0)
forgeTier:SetPoint("RIGHT", forge, "RIGHT", -22, 0)
forgeTier:SetJustifyH("LEFT")

local forgeMoney = forge:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
forgeMoney:SetPoint("BOTTOMLEFT", 24, 22)
local forgeMats = forge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
forgeMats:SetPoint("BOTTOMLEFT", forgeMoney, "TOPLEFT", 0, 6)
forgeMats:SetWidth(670)
forgeMats:SetJustifyH("LEFT")

-- the list
local list = CreateFrame("Frame", nil, forge)
list:SetPoint("TOPLEFT", 18, -60)
Size(list, 320, ROWS * ROW_H)
local listBg = list:CreateTexture(nil, "BACKGROUND")
listBg:SetAllPoints()
listBg:SetTexture(0, 0, 0, 0.5)
list:EnableMouseWheel(true)

local RefreshForge -- forward
local rows = {}
for i = 1, ROWS do
    local r = CreateFrame("Button", nil, list)
    Size(r, 320, ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r.icon = r:CreateTexture(nil, "ARTWORK")
    Size(r.icon, 32, 32)
    r.icon:SetPoint("LEFT", 4, 0)
    r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, -2)
    r.name:SetWidth(270)
    r.name:SetJustifyH("LEFT")
    r.sub = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.sub:SetPoint("BOTTOMLEFT", r.icon, "BOTTOMRIGHT", 6, 2)
    r.sub:SetWidth(270)
    r.sub:SetJustifyH("LEFT")
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetTexture(1, 0.82, 0, 0.18)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r:SetScript("OnClick", function(self) forgeSelected = self.key RefreshForge() end)
    r:SetScript("OnEnter", function(self) local it = forgeData.items[self.key] if it then ItemTooltip(self, it) end end)
    r:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[i] = r
end
list:SetScript("OnMouseWheel", function(self, delta)
    forgeOffset = math.max(0, math.min(math.max(0, #forgeData.order - ROWS), forgeOffset - delta))
    RefreshForge()
end)

-- the detail panel
local detail = CreateFrame("Frame", nil, forge)
detail:SetPoint("TOPLEFT", list, "TOPRIGHT", 16, 0)
Size(detail, 350, ROWS * ROW_H)

local dIcon = CreateFrame("Button", nil, detail)
Size(dIcon, 40, 40)
dIcon:SetPoint("TOPLEFT", 0, 0)
dIcon.tex = dIcon:CreateTexture(nil, "ARTWORK")
dIcon.tex:SetAllPoints()
dIcon:SetScript("OnEnter", function(self) local it = forgeData.items[forgeSelected or ""] if it then ItemTooltip(self, it) end end)
dIcon:SetScript("OnLeave", function() GameTooltip:Hide() end)

local dName = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
dName:SetPoint("TOPLEFT", dIcon, "TOPRIGHT", 8, -2)
dName:SetWidth(300)
dName:SetJustifyH("LEFT")
local dInfo = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
dInfo:SetPoint("TOPLEFT", dName, "BOTTOMLEFT", 0, -4)
dInfo:SetWidth(300)
dInfo:SetJustifyH("LEFT")

local affixHeader = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
affixHeader:SetPoint("TOPLEFT", dIcon, "BOTTOMLEFT", 0, -16)
affixHeader:SetText("Affixes")

local affixRows = {}
for i = 1, 4 do
    local a = CreateFrame("Frame", nil, detail)
    Size(a, 350, 38)
    a:SetPoint("TOPLEFT", affixHeader, "BOTTOMLEFT", 0, -6 - (i - 1) * 40)
    a.text = a:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    a.text:SetPoint("TOPLEFT", 0, 0)
    a.text:SetWidth(260)
    a.text:SetJustifyH("LEFT")
    a.button = CreateFrame("Button", nil, a, "UIPanelButtonTemplate")
    Size(a.button, 80, 20)
    a.button:SetPoint("TOPRIGHT", 0, 2)
    a.button:SetText("Reroll")
    a.cost = a:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    a.cost:SetPoint("TOP", a.button, "BOTTOM", 0, -2)
    affixRows[i] = a
end
local noAffix = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
noAffix:SetPoint("TOPLEFT", affixHeader, "BOTTOMLEFT", 0, -6)
noAffix:SetWidth(340)
noAffix:SetJustifyH("LEFT")

-- the unique power: to the Codex, or one from it
local uniqueText = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
uniqueText:SetPoint("BOTTOMLEFT", 0, 126)
uniqueText:SetWidth(196)
uniqueText:SetJustifyH("LEFT")
local imprintButton = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
Size(imprintButton, 70, 20)
imprintButton:SetPoint("BOTTOMRIGHT", -8, 124)
imprintButton:SetText("Imprint")
local extractButton = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
Size(extractButton, 70, 20)
extractButton:SetPoint("RIGHT", imprintButton, "LEFT", -4, 0)
extractButton:SetText("To Codex")
local imprintMenu = CreateFrame("Frame", "WorldTiersImprintMenu", UIParent, "UIDropDownMenuTemplate")

-- the rune socket
local runeText = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
runeText:SetPoint("BOTTOMLEFT", 0, 96)
runeText:SetWidth(250)
runeText:SetJustifyH("LEFT")
local runeButton = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
Size(runeButton, 86, 20)
runeButton:SetPoint("BOTTOMRIGHT", -8, 94)
runeButton:SetText("Forge rune")
local runeMenu = CreateFrame("Frame", "WorldTiersRuneMenu", UIParent, "UIDropDownMenuTemplate")

local reforgeButton = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
Size(reforgeButton, 340, 26)
reforgeButton:SetPoint("BOTTOMLEFT", 0, 34)
local reforgeNeed = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
reforgeNeed:SetPoint("BOTTOMLEFT", reforgeButton, "TOPLEFT", 0, 3)
reforgeNeed:SetWidth(340)
reforgeNeed:SetJustifyH("LEFT")
local rerollButton = CreateFrame("Button", nil, detail, "UIPanelButtonTemplate")
Size(rerollButton, 340, 26)
rerollButton:SetPoint("BOTTOMLEFT", 0, 0)

-- ---------------- the Power Codex page ----------------
local codexPage = CreateFrame("Frame", nil, forge)
codexPage:SetPoint("TOPLEFT", 18, -60)
Size(codexPage, 686, ROWS * ROW_H)
codexPage:Hide()
local codexCols, codexCards = {}, {}
for col = 1, 4 do
    local h = codexPage:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    h:SetPoint("TOPLEFT", (col - 1) * 172 + 4, -2)
    h:SetWidth(160)
    h:SetJustifyH("LEFT")
    codexCols[col] = h
    for row = 1, 3 do
        local c = CreateFrame("Frame", nil, codexPage)
        Size(c, 164, 112)
        c:SetPoint("TOPLEFT", (col - 1) * 172, -22 - (row - 1) * 118)
        c:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        c.name:SetPoint("TOPLEFT", 8, -8)
        c.name:SetWidth(148)
        c.name:SetJustifyH("LEFT")
        c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        c.text:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)
        c.text:SetWidth(148)
        c.text:SetHeight(58)
        c.text:SetJustifyH("LEFT")
        c.text:SetJustifyV("TOP")
        c.status = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        c.status:SetPoint("BOTTOMLEFT", 8, 8)
        c.status:SetWidth(148)
        c.status:SetJustifyH("LEFT")
        c:EnableMouse(true)
        c:SetScript("OnEnter", function(self)
            if not self.power then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self.power.name, 0.9, 0.8, 0.5)
            GameTooltip:AddLine(self.power.text, 1, 1, 1, true)
            GameTooltip:AddLine(self.power.known and string.format("In your Codex at %d%%. Imprint it from the Gear tab.", self.power.roll)
                or "Not found yet. Uniques drop from rare or better gear at World Tier III and up; extract one here to keep its power.", 0.6, 0.8, 1, true)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        codexCards[#codexCards + 1] = c
    end
end
local codexNote = codexPage:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
codexNote:SetPoint("BOTTOMLEFT", 2, 6)
codexNote:SetWidth(680)
codexNote:SetJustifyH("LEFT")

local function RefreshCodex()
    local byTree = { [0] = {}, {}, {}, {} }
    local found = 0
    for _, p in ipairs(forgeData.codex) do
        table.insert(byTree[p.tree] or byTree[0], p)
        if p.known then found = found + 1 end
    end
    for col = 1, 4 do
        local tree = col - 1
        local have = 0
        for _, p in ipairs(byTree[tree]) do if p.known then have = have + 1 end end
        codexCols[col]:SetText(string.format("%s  |cff888888%d/%d|r", forgeData.trees[tree] or "", have, #byTree[tree]))
        for row = 1, 3 do
            local c, p = codexCards[(col - 1) * 3 + row], byTree[tree][row]
            c.power = p
            if p then
                c.name:SetText(p.name)
                c.text:SetText(p.text)
                if p.known then
                    c.name:SetTextColor(0.9, 0.8, 0.5)
                    c.text:SetTextColor(1, 1, 1)
                    c.status:SetText(string.format("|cff20ff20In your Codex|r  -  %d%%", p.roll))
                    c:SetBackdropColor(0.16, 0.12, 0.04, 0.9)
                    c:SetBackdropBorderColor(0.9, 0.8, 0.5)
                else
                    c.name:SetTextColor(0.55, 0.55, 0.55)
                    c.text:SetTextColor(0.5, 0.5, 0.5)
                    c.status:SetText("Not found yet")
                    c:SetBackdropColor(0.05, 0.05, 0.07, 0.85)
                    c:SetBackdropBorderColor(0.35, 0.35, 0.35)
                end
                c:Show()
            else
                c:Hide()
            end
        end
    end
    codexNote:SetText(string.format("|cffe6cc80%d of %d|r powers found, for every character of your account. On the Gear tab, |cffffffffTo Codex|r "
        .. "extracts a unique (the piece is destroyed) and |cffffffffImprint|r puts a power from here onto any rare or better piece.", found, #forgeData.codex))
end

StaticPopupDialogs["WORLDTIERS_FORGE"] = {
    text = "%s",
    button1 = ACCEPT, button2 = CANCEL,
    OnAccept = function(self, data) if data then Send(data) end end,
    timeout = 0, whileDead = 1, hideOnEscape = 1,
}
local function Confirm(text, cmd)
    local d = StaticPopup_Show("WORLDTIERS_FORGE", text)
    if d then d.data = cmd end
end

local function ItemName(it)
    local link = ItemLink(it)
    return link and link:gsub("[%[%]]", "") or "?"
end

RefreshForge = function()
    forgeTier:SetText(string.format("World Tier |cffff9933%s|r. A piece reforges up to 3 tiers above where it dropped.", forgeData.tierName))
    if forgeMode == "codex" then gearTab:UnlockHighlight() codexTab:LockHighlight() else codexTab:UnlockHighlight() gearTab:LockHighlight() end
    forgeMoney:SetText(WT.MoneyLine())
    local mats = {}
    for _, m in ipairs(forgeData.mats) do
        mats[#mats + 1] = string.format("|cffa335ee%s|r %d%s", m.band, m.essence, m.shards > 0 and string.format(" (+%d shards)", m.shards) or "")
    end
    forgeMats:SetText(#mats > 0 and ("Essence: " .. table.concat(mats, ",  ")) or "|cff888888No Essence yet: bosses at World Tier I and up drop it (raids Essence, dungeons Shards).|r")
    if forgeMode == "codex" then
        list:Hide()
        detail:Hide()
        codexPage:Show()
        RefreshCodex()
        return
    end
    codexPage:Hide()
    list:Show()
    local order = forgeData.order
    if not forgeSelected or not forgeData.items[forgeSelected] then forgeSelected = order[1] end
    for i = 1, ROWS do
        local r = rows[i]
        local key = order[forgeOffset + i]
        local it = key and forgeData.items[key]
        if it then
            r.key = key
            r.icon:SetTexture(ItemIcon(it) or "Interface\\Icons\\INV_Misc_QuestionMark")
            r.name:SetText(ItemName(it))
            local where = it.bag == -2 and "worn" or "bag"
            r.sub:SetText(string.format("%s%s - item level %d - %d affix%s%s", it.primal and "|cffff3030Primal|r " or "",
                it.tier > 0 and ("Tier " .. it.tier) or "no tier", it.eff, #it.affixes, #it.affixes == 1 and "" or "es",
                it.target > it.tier and (it.canPay and "  |cff20ff20(can reforge)|r" or "  |cffaaaaaa(reforge: need Essence)|r") or "")
                .. "  |cff888888" .. where .. "|r")
            if key == forgeSelected then r.sel:Show() else r.sel:Hide() end
            r:Show()
        else
            r:Hide()
        end
    end

    local it = forgeData.items[forgeSelected or ""]
    if not it then
        detail:Hide()
        return
    end
    detail:Show()
    dIcon.tex:SetTexture(ItemIcon(it) or "Interface\\Icons\\INV_Misc_QuestionMark")
    dName:SetText(ItemName(it))
    dInfo:SetText(string.format("%s%s\nItem level %d for you (its own is %d)%s", it.primal and "|cffff3030Primal|r - " or "",
        it.tier > 0 and ("Tier " .. it.tier) or "Not from a World Tier", it.eff, it.own,
        it.origin > 0 and string.format("\n|cff888888Dropped at Tier %d: reforges up to Tier %d|r", it.origin, it.origin + 3) or ""))

    -- the rune socket
    local runeName = it.rune > 0 and (WT.RUNE_NAMES[it.rune] or ("Rune " .. it.rune)) or nil
    runeText:SetText(runeName and ("|cff40e0d0" .. runeName .. "|r") or "|cff888888No rune|r")
    if #forgeData.runes > 0 and it.rerollAll > 0 then
        runeButton:Enable()
        runeButton:SetScript("OnClick", function(self)
            local menu = { { text = "Forge a rune into " .. ItemName(it), isTitle = true, notCheckable = true } }
            for _, r in ipairs(forgeData.runes) do
                menu[#menu + 1] = { text = string.format("%s (%d): %s", r.name, r.count, r.text), notCheckable = true, func = function()
                    Confirm(string.format("Forge %s into %s?%s", r.name, ItemName(it), runeName and ("\n\nThe " .. runeName .. " in it is destroyed.") or ""),
                        string.format("FN:%d:%d:%d", it.bag, it.slot, r.id))
                end }
            end
            menu[#menu + 1] = { text = CANCEL, notCheckable = true }
            EasyMenu(menu, runeMenu, self, 0, 0, "MENU")
        end)
    else
        runeButton:Disable()
    end

    -- the unique power has its own row below
    local shown = {}
    for idx, a in ipairs(it.affixes) do
        if a.rarity ~= 6 then shown[#shown + 1] = { a = a, idx = idx - 1 } end
    end
    for i = 1, 4 do
        local row, a, idx = affixRows[i], shown[i] and shown[i].a, shown[i] and shown[i].idx
        if a then
            local c = WT.AFFIX_COLOR[a.rarity] or WT.AFFIX_COLOR[0]
            row.text:SetText(a.text)
            row.text:SetTextColor(c[1], c[2], c[3])
            row.cost:SetText(Money(it.rerollOne))
            row.button:SetScript("OnClick", function()
                Confirm(string.format("Reroll \"%s\" on %s for %s?\n\nIt becomes another affix of the same kind.", a.text, ItemName(it), Money(it.rerollOne)),
                    string.format("F1:%d:%d:%d", it.bag, it.slot, idx))
            end)
            if it.rerollOne > 0 and a.rarity ~= 6 then row.button:Enable() else row.button:Disable() end
            if a.rarity == 6 then row.cost:SetText("|cffe6cc80unique|r") end
            row:Show()
        else
            row:Hide()
        end
    end
    -- the unique power
    local u = it.unique
    local known = {}
    for _, p in ipairs(forgeData.codex) do if p.known then known[#known + 1] = p end end
    if u then
        uniqueText:SetText(string.format("|cffe6cc80%s|r |cff888888(%d%%)|r", u.name or "Unique power", u.roll))
    else
        uniqueText:SetText(#forgeData.codex > 0 and "|cff888888No unique power|r" or "")
    end
    if u and it.bag ~= -2 then
        extractButton:Enable()
        extractButton:SetScript("OnClick", function()
            Confirm(string.format("Extract |cffe6cc80%s|r into your Power Codex?\n\n%s is destroyed. The power stays in your Codex for every character "
                .. "of your account, at the best roll you have found.", u.name or "its power", ItemName(it)), string.format("FK:%d:%d", it.bag, it.slot))
        end)
    else
        extractButton:Disable()
    end
    if it.canTake and #known > 0 then
        imprintButton:Enable()
        imprintButton:SetScript("OnClick", function(self)
            local cost = Money(it.imprintGold) .. (it.imprintMats ~= "" and (" and " .. it.imprintMats) or "")
            local menu = { { text = "Imprint onto " .. ItemName(it) .. ": " .. cost, isTitle = true, notCheckable = true } }
            for _, p in ipairs(known) do
                menu[#menu + 1] = { text = string.format("%s (%d%%)", p.name, p.roll), notCheckable = true,
                    tooltipTitle = p.name, tooltipText = p.text, func = function()
                        if not it.imprintPay then
                            UIErrorsFrame:AddMessage("Not enough Essence: " .. it.imprintMats .. ".", 1, 0.2, 0.2)
                            return
                        end
                        Confirm(string.format("Imprint |cffe6cc80%s|r onto %s for %s?%s", p.name, ItemName(it), cost,
                            u and ("\n\nIt replaces " .. (u.name or "its unique power") .. ".") or ""), string.format("FP:%d:%d:%d", it.bag, it.slot, p.index))
                    end }
            end
            menu[#menu + 1] = { text = CANCEL, notCheckable = true }
            EasyMenu(menu, imprintMenu, self, 0, 0, "MENU")
        end)
    else
        imprintButton:Disable()
    end
    if #forgeData.codex == 0 then imprintButton:Hide() extractButton:Hide() else imprintButton:Show() extractButton:Show() end

    if #shown == 0 then
        noAffix:SetText(it.rerollAll > 0 and "No affixes yet. Roll some below." or "Only uncommon (green) or better gear carries affixes.")
        noAffix:Show()
    else
        noAffix:Hide()
    end

    if it.target > it.tier then
        reforgeButton:SetText(string.format("Reforge to Tier %d - %s", it.target, Money(it.reforge)))
        reforgeNeed:SetText((it.canPay and "|cff20ff20Costs|r " or "|cffff4040Needs|r ") .. it.mats)
        if it.canPay then reforgeButton:Enable() else reforgeButton:Disable() end
        reforgeButton:SetScript("OnClick", function()
            Confirm(string.format("Reforge %s to Tier %d for %s and %s?\n\nIts stats grow to that tier. Its affixes stay as they are.", ItemName(it), it.target, it.mats, Money(it.reforge)),
                string.format("FR:%d:%d", it.bag, it.slot))
        end)
    else
        reforgeNeed:SetText("")
        reforgeButton:SetText(forgeData.tier == 0 and "Choose a World Tier to reforge to"
            or (it.tier >= forgeData.tier and "Already at your World Tier" or "As high as it goes (3 tiers above where it dropped)"))
        reforgeButton:Disable()
    end
    if it.rerollAll > 0 then
        local verb = #it.affixes > 0 and "Reroll all affixes" or "Roll affixes"
        rerollButton:SetText(string.format("%s - %s", verb, Money(it.rerollAll)))
        rerollButton:Enable()
        rerollButton:SetScript("OnClick", function()
            Confirm(string.format("%s on %s for %s?\n\nEvery affix is replaced, and how many it gets is rolled again.", verb, ItemName(it), Money(it.rerollAll)),
                string.format("FA:%d:%d", it.bag, it.slot))
        end)
    else
        rerollButton:SetText("No affixes on this kind of item")
        rerollButton:Disable()
    end
end

-- FB|money|reserve  FI|bag|slot|tier|eff|own|reforge|rerollAll|rerollOne|n|target|materials|canPay|rune|primal|origin
-- FX|bag|slot|i|rarity|text  FN|rune|count|name|text  FM|band|essence|shards  FE|tier|name  FO|
WT.RUNE_NAMES = { "Rune of Ferocity", "Rune of the Bulwark", "Rune of Life", "Rune of the Leech", "Rune of Fortune",
                  "Rune of Echoes", "Rune of Wrath", "Rune of Warding" }
function WT.OnForgeMessage(msg)
    if msg:sub(1, 3) == "GR|" then
        WT.SetReserve(msg:sub(4))
        return true
    end
    local cmd = msg:match("^(F%u)|")
    if not cmd then return false end
    local rest = msg:sub(4)
    if cmd == "FO" then
        WT.forgeServerOpened = true
        forge:Show()
    elseif cmd == "FB" then
        local f = Split(rest, "|")
        pendingForge = { items = {}, order = {}, money = tonumber(f[1]) or 0, runes = {}, mats = {}, codex = {}, trees = {} }
        if f[2] then WT.SetReserve(f[2]) end
    elseif cmd == "FI" and pendingForge then
        local f = Split(rest, "|")
        local it = { bag = tonumber(f[1]), slot = tonumber(f[2]), tier = tonumber(f[3]) or 0, eff = tonumber(f[4]) or 0, own = tonumber(f[5]) or 0,
                     reforge = tonumber(f[6]) or 0, rerollAll = tonumber(f[7]) or 0, rerollOne = tonumber(f[8]) or 0, affixes = {},
                     target = tonumber(f[10]) or 0, mats = f[11] or "", canPay = f[12] == "1", rune = tonumber(f[13]) or 0,
                     primal = f[14] == "1", origin = tonumber(f[15]) or 0 }
        local key = f[1] .. ":" .. f[2]
        pendingForge.items[key] = it
        pendingForge.order[#pendingForge.order + 1] = key
    elseif cmd == "FX" and pendingForge then
        local f = Split(rest, "|")
        local it = pendingForge.items[f[1] .. ":" .. f[2]]
        if it then table.insert(it.affixes, { rarity = tonumber(f[4]) or 0, text = f[5] or "" }) end
    elseif cmd == "FU" and pendingForge then
        -- FU|bag|slot|unique(-1)|roll%|canTake|imprintGold|materials|canPay
        local f = Split(rest, "|")
        local it = pendingForge.items[f[1] .. ":" .. f[2]]
        if it then
            local u = tonumber(f[3]) or -1
            it.unique = u >= 0 and { index = u, roll = tonumber(f[4]) or 0 } or nil
            it.canTake, it.imprintGold, it.imprintMats, it.imprintPay = f[5] == "1", tonumber(f[6]) or 0, f[7] or "", f[8] == "1"
        end
    elseif cmd == "FT" and pendingForge then
        local f = Split(rest, "|")
        pendingForge.trees = { [0] = f[1], f[2], f[3], f[4] }
    elseif cmd == "FQ" and pendingForge then
        -- FQ|index|tree|name|known|roll%|text
        local f = Split(rest, "|")
        table.insert(pendingForge.codex, { index = tonumber(f[1]) or 0, tree = tonumber(f[2]) or 0, name = f[3] or "?",
            known = f[4] == "1", roll = tonumber(f[5]) or 100, text = f[6] or "" })
    elseif cmd == "FN" and pendingForge then
        local f = Split(rest, "|")
        local id = tonumber(f[1]) or 0
        WT.RUNE_NAMES[id] = f[3]
        table.insert(pendingForge.runes, { id = id, count = tonumber(f[2]) or 0, name = f[3] or "", text = f[4] or "" })
    elseif cmd == "FM" and pendingForge then
        local f = Split(rest, "|")
        table.insert(pendingForge.mats, { band = f[1] or "", essence = tonumber(f[2]) or 0, shards = tonumber(f[3]) or 0 })
    elseif cmd == "FE" and pendingForge then
        local f = Split(rest, "|")
        pendingForge.tier, pendingForge.tierName = tonumber(f[1]) or 0, f[2] or ""
        -- each item's unique by name (the Codex list knows every power of your class)
        local names = {}
        for _, p in ipairs(pendingForge.codex) do names[p.index] = p.name end
        for _, it in pairs(pendingForge.items) do
            if it.unique then
                it.unique.name = names[it.unique.index]
                if not it.unique.name then
                    for _, a in ipairs(it.affixes) do
                        if a.rarity == 6 then it.unique.name = (a.text:match("%] ([^:]+):") or "Unique power") end
                    end
                end
            end
        end
        forgeData, pendingForge = pendingForge, nil
        forgeOffset = math.min(forgeOffset, math.max(0, #forgeData.order - ROWS))
        if forge:IsShown() then RefreshForge() end
    else
        return false
    end
    return true
end

gearTab:SetScript("OnClick", function() forgeMode = "gear" RefreshForge() end)
codexTab:SetScript("OnClick", function() forgeMode = "codex" RefreshForge() end)

forge:SetScript("OnShow", function()
    PlaySound("igCharacterInfoOpen")
    if WT.forgeServerOpened then WT.forgeServerOpened = false else Send("F") end
    RefreshForge()
end)
forge:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") end)
forge:RegisterEvent("PLAYER_MONEY")
forge:SetScript("OnEvent", function() if forge:IsShown() then forgeMoney:SetText(WT.MoneyLine()) end end)

WT.forgeMoneyRefresh = function() if forge:IsShown() then forgeMoney:SetText(WT.MoneyLine()) end end

SLASH_WORLDTIERSFORGE1 = "/forge"
SlashCmdList["WORLDTIERSFORGE"] = function()
    if forge:IsShown() then forge:Hide() else forge:Show() end
end

-- /codex: the Forge, on its Power Codex tab
SLASH_WORLDTIERSCODEX1 = "/codex"
SlashCmdList["WORLDTIERSCODEX"] = function()
    forgeMode = "codex"
    if forge:IsShown() then RefreshForge() else forge:Show() end
end

-- ---------------------------------------------------------------------------
-- Champions: named on their tooltip (the server says which creatures are)
-- ---------------------------------------------------------------------------

local champCache = {}   -- guid hex -> { name, text, at }

local function ChampionLine(tip, info)
    if info and info.name ~= "" then
        tip:AddLine(string.format("Champion: %s", info.name), 1, 0.5, 0)
        tip:AddLine(string.format("It %s. Three times the health; drops gear with affixes.", info.text), 1, 0.75, 0.4, true)
        tip:Show()
    end
end

GameTooltip:HookScript("OnTooltipSetUnit", function(tip)
    local _, unit = tip:GetUnit()
    if not unit or UnitIsPlayer(unit) or not UnitCanAttack("player", unit) then return end
    local guid = UnitGUID(unit)
    if not guid then return end
    local hex = guid:gsub("^0x", "")
    local hit = champCache[hex]
    if hit and GetTime() - hit.at < 20 then
        ChampionLine(tip, hit)
        return
    end
    if not hit or GetTime() - hit.at >= 20 then
        champCache[hex] = { name = "", text = "", at = GetTime() }
        Send("C:" .. hex)
    end
end)

-- CH|guid|name|text
function WT.OnChampionMessage(msg)
    if msg:sub(1, 3) ~= "CH|" then return false end
    local f = Split(msg:sub(4), "|")
    local info = { name = f[2] or "", text = f[3] or "", at = GetTime() }
    champCache[f[1] or ""] = info
    local _, unit = GameTooltip:GetUnit()
    if unit and GameTooltip:IsShown() then
        local guid = UnitGUID(unit)
        if guid and guid:gsub("^0x", "") == f[1] then ChampionLine(GameTooltip, info) end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Tier Keys: the run's clock, under the minimap while a keyed run is on
-- ---------------------------------------------------------------------------

WT.key = { text = "", best = 0 }
local keyRun = nil

local keyFrame = CreateFrame("Frame", "WorldTiersKeyFrame", UIParent)
Size(keyFrame, 220, 74)
keyFrame:SetPoint("TOPRIGHT", MinimapCluster or UIParent, "BOTTOMRIGHT", -10, -10)
keyFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = true, tileSize = 16, edgeSize = 16,
    insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
keyFrame:SetBackdropColor(0, 0, 0, 0.75)
keyFrame:SetMovable(true)
keyFrame:EnableMouse(true)
keyFrame:RegisterForDrag("LeftButton")
keyFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
keyFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
keyFrame:Hide()

local keyTitle = keyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
keyTitle:SetPoint("TOPLEFT", 10, -9)
keyTitle:SetWidth(200)
keyTitle:SetJustifyH("LEFT")
local keyClock = keyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
keyClock:SetPoint("TOPLEFT", keyTitle, "BOTTOMLEFT", 0, -3)
local keyMods = keyFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
keyMods:SetPoint("TOPLEFT", keyClock, "BOTTOMLEFT", 0, -3)
keyMods:SetWidth(200)
keyMods:SetJustifyH("LEFT")

local function Clock(sec)
    sec = math.max(0, math.floor(sec))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

local keyElapsed = 0
keyFrame:SetScript("OnUpdate", function(self, dt)
    if not keyRun then return end
    keyElapsed = keyElapsed + dt
    if keyElapsed < 0.2 then return end
    keyElapsed = 0
    local used = (GetTime() - keyRun.startedAt) + keyRun.elapsed
    local left = keyRun.par - used
    if left >= 0 then
        local pace = used <= keyRun.par * 0.6 and " |cff20ff20+3|r" or used <= keyRun.par * 0.8 and " |cff20ff20+2|r" or " |cffffd100+1|r"
        keyClock:SetText(Clock(used) .. " / " .. Clock(keyRun.par) .. pace)
        keyClock:SetTextColor(1, 1, 1)
    else
        keyClock:SetText(Clock(used) .. " / " .. Clock(keyRun.par) .. " |cffff4040late|r")
        keyClock:SetTextColor(1, 0.4, 0.4)
    end
end)

-- KY|key text|best   KR|dungeon|level|mods|par|elapsed|deaths   KE|
function WT.OnKeyMessage(msg)
    local cmd = msg:match("^(K[YRE])|")
    if not cmd then return false end
    local f = Split(msg:sub(4), "|")
    if cmd == "KY" then
        WT.key.text, WT.key.best = f[1] or "", tonumber(f[2]) or 0
        if WT.RefreshPanel then WT.RefreshPanel() end
    elseif cmd == "KR" then
        keyRun = { dungeon = f[1] or "", level = tonumber(f[2]) or 0, mods = f[3] or "", par = tonumber(f[4]) or 1800,
                   elapsed = tonumber(f[5]) or 0, deaths = tonumber(f[6]) or 0, startedAt = GetTime() }
        keyTitle:SetText(string.format("|cffa335eeTier Key +%d|r  %s", keyRun.level, keyRun.dungeon))
        keyMods:SetText(keyRun.mods .. (keyRun.deaths > 0 and string.format("   |cffff8080%d death%s|r", keyRun.deaths,
            keyRun.deaths == 1 and "" or "s") or ""))
        keyElapsed = 1
        keyFrame:Show()
    elseif cmd == "KE" then
        keyRun = nil
        keyFrame:Hide()
    end
    return true
end

-- ---------------------------------------------------------------------------
-- The Materials Pouch: every crafting material, account-wide, no limit
-- ---------------------------------------------------------------------------

do
    local ROWS, ROW_H = 12, 32
    local TABS = { { 0, "All" }, { 1, "Cloth" }, { 2, "Leather" }, { 3, "Metal" }, { 4, "Herb" }, { 5, "Enchant" },
                   { 6, "Element" }, { 7, "Gem" }, { 8, "Cook" }, { 9, "Eng." }, { 10, "Other" } }
    local items, pending, shown = {}, nil, {}
    local auto, tab, offset, search = true, 0, 0, ""

    local win = CreateFrame("Frame", "WorldTiersPouchFrame", UIParent)
    Size(win, 520, 560)
    win:SetPoint("CENTER", 120, 0)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:SetBackdrop(frame:GetBackdrop() or {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    win:Hide()
    tinsert(UISpecialFrames, "WorldTiersPouchFrame")

    local drag = CreateFrame("Frame", nil, win)
    drag:SetPoint("TOPLEFT", 12, -8)
    drag:SetPoint("TOPRIGHT", -40, -8)
    drag:SetHeight(26)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() win:StartMoving() end)
    drag:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Materials Pouch")
    local closeB = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeB:SetPoint("TOPRIGHT", -6, -6)

    local sub = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 22, -42)
    sub:SetText("Shared by every character on your account. No limit. Crafting takes what it needs from here.")

    local box = CreateFrame("EditBox", "WorldTiersPouchSearch", win, "InputBoxTemplate")
    Size(box, 160, 20)
    box:SetPoint("TOPLEFT", 26, -62)
    box:SetAutoFocus(false)
    local boxHint = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    boxHint:SetPoint("LEFT", 2, 0)
    boxHint:SetText("Search...")

    local count = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("LEFT", box, "RIGHT", 12, 0)

    local tabButtons = {}
    for i, t in ipairs(TABS) do
        local b = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
        Size(b, 44, 20)
        b:SetPoint("TOPLEFT", 18 + (i - 1) * 44, -88)
        b:SetText(t[2])
        local fs = b:GetFontString()
        if fs then fs:SetFontObject("GameFontHighlightSmall") end
        b:SetScript("OnClick", function() tab = t[1] offset = 0 WT.RefreshPouch() end)
        tabButtons[i] = b
    end

    local list = CreateFrame("Frame", nil, win)
    list:SetPoint("TOPLEFT", 18, -114)
    Size(list, 484, ROWS * ROW_H)
    local listBg = list:CreateTexture(nil, "BACKGROUND")
    listBg:SetAllPoints()
    listBg:SetTexture(0, 0, 0, 0.5)
    list:EnableMouseWheel(true)

    StaticPopupDialogs["WORLDTIERS_POUCH_TAKE"] = {
        text = "Take how many %s out of the pouch?",
        button1 = ACCEPT, button2 = CANCEL,
        hasEditBox = 1, maxLetters = 7,
        OnShow = function(self) local e = _G[self:GetName() .. "EditBox"] if e then e:SetText("") e:SetFocus() end end,
        OnAccept = function(self, data)
            local e = _G[self:GetName() .. "EditBox"]
            local n = tonumber(e and e:GetText() or "")
            if n and n > 0 then Send(string.format("PW:%d:%d", data, n)) end
        end,
        EditBoxOnEnterPressed = function(self)
            local parent = self:GetParent()
            local n = tonumber(self:GetText())
            if n and n > 0 then Send(string.format("PW:%d:%d", parent.data, n)) end
            parent:Hide()
        end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }

    local rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, list)
        Size(r, 484, ROW_H)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        Size(r.icon, 28, 28)
        r.icon:SetPoint("LEFT", 4, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetWidth(300)
        r.name:SetJustifyH("LEFT")
        r.num = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.num:SetPoint("RIGHT", -10, 0)
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        r:SetScript("OnClick", function(self, button)
            local it = self.item
            if not it then return end
            if IsShiftKeyDown() or button == "RightButton" then
                local d = StaticPopup_Show("WORLDTIERS_POUCH_TAKE", it.name)
                if d then d.data = it.entry end
            else
                local stack = select(8, GetItemInfo(it.entry)) or 20
                Send(string.format("PW:%d:%d", it.entry, stack))
            end
        end)
        r:SetScript("OnEnter", function(self)
            if not self.item then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.item.entry)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click: take a stack.  Shift- or right-click: take how many you choose.", 0.6, 0.8, 1, true)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = r
    end

    local deposit = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    Size(deposit, 200, 24)
    deposit:SetPoint("BOTTOMLEFT", 22, 20)
    deposit:SetText("Store every material in my bags")
    deposit:SetScript("OnClick", function() Send("PD") end)

    local autoBox = CreateFrame("CheckButton", "WorldTiersPouchAuto", win, "UICheckButtonTemplate")
    autoBox:SetPoint("LEFT", deposit, "RIGHT", 14, 0)
    local autoText = _G["WorldTiersPouchAutoText"]
    if autoText then autoText:SetText("Store looted materials by themselves") end
    autoBox:SetScript("OnClick", function(self) Send("PA:" .. (self:GetChecked() and "1" or "0")) end)

    local function Filtered()
        local out = {}
        local s = search:lower()
        for _, it in ipairs(items) do
            local t = it.tab
            if (tab == 0 or t == tab or (tab == 10 and t == 0)) and (s == "" or it.name:lower():find(s, 1, true)) then
                out[#out + 1] = it
            end
        end
        return out
    end

    function WT.RefreshPouch()
        shown = Filtered()
        offset = math.max(0, math.min(offset, #shown - ROWS))
        for i = 1, ROWS do
            local r, it = rows[i], shown[offset + i]
            r.item = it
            if it then
                local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality]
                r.icon:SetTexture(GetItemIcon(it.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
                r.name:SetText(it.name)
                if c then r.name:SetTextColor(c.r, c.g, c.b) end
                r.num:SetText(it.countText)
                r:Show()
            else
                r:Hide()
            end
        end
        count:SetText(string.format("%d kind%s%s", #items, #items == 1 and "" or "s",
            #shown ~= #items and string.format(" (%d shown)", #shown) or ""))
        autoBox:SetChecked(auto)
        for i, t in ipairs(TABS) do
            if t[1] == tab then tabButtons[i]:LockHighlight() else tabButtons[i]:UnlockHighlight() end
        end
    end

    list:SetScript("OnMouseWheel", function(self, delta)
        offset = math.max(0, math.min(math.max(0, #shown - ROWS), offset - delta * 3))
        WT.RefreshPouch()
    end)
    box:SetScript("OnTextChanged", function(self)
        search = self:GetText() or ""
        if search == "" then boxHint:Show() else boxHint:Hide() end
        offset = 0
        WT.RefreshPouch()
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local function Thousands(s)
        local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
        return (out:gsub("^,", ""))
    end

    -- PO|  PB|auto  PI|entry^count^tab^quality^name~...  PE|kinds  PC| (changed: ask again)
    function WT.OnPouchMessage(msg)
        local cmd = msg:match("^(P[OBIEC])|")
        if not cmd then return false end
        local rest = msg:sub(4)
        if cmd == "PO" then
            win.serverOpened = true
            win:Show()
        elseif cmd == "PB" then
            pending = {}
            auto = rest == "1"
        elseif cmd == "PI" and pending then
            for one in rest:gmatch("([^~]+)") do
                local f = Split(one, "^")
                local n = (f[2] or "0"):gsub("%D", "")
                pending[#pending + 1] = { entry = tonumber(f[1]) or 0, countText = Thousands(n), tab = tonumber(f[3]) or 0,
                                          quality = tonumber(f[4]) or 1, name = f[5] or "?" }
            end
        elseif cmd == "PE" and pending then
            table.sort(pending, function(a, b) return a.name < b.name end)
            items, pending = pending, nil
            if win:IsShown() then WT.RefreshPouch() end
        elseif cmd == "PC" then
            if win:IsShown() then Send("P") end
        end
        return true
    end

    win:SetScript("OnShow", function()
        PlaySound("igBackPackOpen")
        if win.serverOpened then win.serverOpened = false else Send("P") end
        WT.RefreshPouch()
    end)
    win:SetScript("OnHide", function() PlaySound("igBackPackClose") end)

    SLASH_WORLDTIERSPOUCH1 = "/pouch"
    SlashCmdList["WORLDTIERSPOUCH"] = function() if win:IsShown() then win:Hide() else win:Show() end end

    -- The profession window: "From Pouch" takes out what the chosen number
    -- of crafts needs beyond what the bags hold.
    local function HookTradeSkill()
        if WT.tradeHooked or not TradeSkillFrame or not TradeSkillCreateAllButton then return end
        WT.tradeHooked = true
        local b = CreateFrame("Button", "WorldTiersFromPouch", TradeSkillFrame, "UIPanelButtonTemplate")
        Size(b, 80, 22)
        b:SetPoint("BOTTOMLEFT", TradeSkillCreateAllButton, "TOPLEFT", 0, 4)
        b:SetText("From Pouch")
        b:SetScript("OnClick", function()
            local id = GetTradeSkillSelectionIndex()
            if not id or id == 0 then return end
            local n = TradeSkillInputBox and TradeSkillInputBox:GetNumber() or 1
            if not n or n < 1 then n = 1 end
            local want = {}
            for i = 1, GetTradeSkillNumReagents(id) do
                local _, _, need, have = GetTradeSkillReagentInfo(id, i)
                local link = GetTradeSkillReagentItemLink(id, i)
                local entry = link and tonumber(link:match("item:(%d+)"))
                if entry and need and need * n > (have or 0) then
                    want[#want + 1] = entry .. "*" .. (need * n)
                end
            end
            if #want > 0 then Send("PR:" .. table.concat(want, ",")) end
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("From Pouch")
            GameTooltip:AddLine("Takes the reagents for the number of crafts in the box out of your Materials Pouch. (Crafting also takes them by itself, one at a time.)", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    local hook = CreateFrame("Frame")
    hook:RegisterEvent("ADDON_LOADED")
    hook:RegisterEvent("TRADE_SKILL_SHOW")
    hook:SetScript("OnEvent", function() HookTradeSkill() end)
end

-- ---------------------------------------------------------------------------
-- Auto-Sell: a loot filter. What you don't want sells the moment you loot it
-- (the Auto-Sell spell, /autosell)
-- ---------------------------------------------------------------------------

do
    local AS_ENABLED, AS_POOR, AS_COMMON, AS_UNCOMMON, AS_RARE = 1, 2, 4, 8, 16
    local AS_GEAR_ONLY, AS_KEEP_UPGRADES, AS_KEEP_BOE, AS_ANNOUNCE = 32, 64, 128, 256
    local KEEP_ROWS, KEEP_H = 6, 26
    local state = { flags = 0, soldCount = 0, soldCopper = 0, nowCount = 0, nowCopper = 0 }
    local keep, pending, keepOffset = {}, nil, 0

    local function Has(bit) return math.floor(state.flags / bit) % 2 == 1 end
    local function Money(c)
        c = tonumber(c) or 0
        if GetCoinTextureString then return GetCoinTextureString(c) end
        return string.format("%dg %ds %dc", math.floor(c / 10000), math.floor(c / 100) % 100, c % 100)
    end

    local win = CreateFrame("Frame", "WorldTiersSellFrame", UIParent)
    Size(win, 440, 560)
    win:SetPoint("CENTER", 160, 0)
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    win:Hide()
    tinsert(UISpecialFrames, "WorldTiersSellFrame")

    local drag = CreateFrame("Frame", nil, win)
    drag:SetPoint("TOPLEFT", 12, -8)
    drag:SetPoint("TOPRIGHT", -40, -8)
    drag:SetHeight(44)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() win:StartMoving() end)
    drag:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)

    local crest = win:CreateTexture(nil, "ARTWORK")
    Size(crest, 36, 36)
    crest:SetPoint("TOPLEFT", 24, -20)
    crest:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", crest, "TOPRIGHT", 10, -1)
    title:SetText("Auto-Sell")
    local subtitle = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    subtitle:SetText("Sells what you don't want the moment you loot it.")
    local closeB = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeB:SetPoint("TOPRIGHT", -6, -6)

    local function Header(text, y)
        local h = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        h:SetPoint("TOPLEFT", 24, y)
        h:SetText(text)
        local line = win:CreateTexture(nil, "ARTWORK")
        line:SetTexture(1, 0.82, 0, 0.25)
        line:SetHeight(1)
        line:SetPoint("TOPLEFT", h, "BOTTOMLEFT", 0, -3)
        line:SetPoint("RIGHT", win, "RIGHT", -24, 0)
        return h
    end

    local checks = {}
    local function Check(name, bit, text, tip, x, y)
        local c = CreateFrame("CheckButton", "WorldTiersSell" .. name, win, "UICheckButtonTemplate")
        Size(c, 24, 24)
        c:SetPoint("TOPLEFT", x, y)
        local label = _G["WorldTiersSell" .. name .. "Text"]
        if label then label:SetText(text) label:SetFontObject("GameFontHighlight") end
        c.label = label
        c.bit = bit
        c:SetScript("OnClick", function(self)
            local on = self:GetChecked() and true or false
            local f = state.flags
            if Has(bit) ~= on then f = on and (f + bit) or (f - bit) end
            state.flags = f
            Send("ZF:" .. f)
        end)
        if tip then
            c:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(text)
                GameTooltip:AddLine(tip, 1, 1, 1, true)
                GameTooltip:Show()
            end)
            c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        checks[#checks + 1] = c
        return c
    end

    Check("On", AS_ENABLED, "Auto-Sell is on", "Off: nothing sells by itself, not even at vendors.", 22, -70)

    Header("Sell these when I loot them", -102)
    local QUAL = { { "Poor", AS_POOR, 0 }, { "Common", AS_COMMON, 1 }, { "Uncommon", AS_UNCOMMON, 2 }, { "Rare", AS_RARE, 3 } }
    for i, q in ipairs(QUAL) do
        local c = Check(q[1], q[2], q[1], nil, 22 + (i - 1) * 100, -124)
        local col = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q[3]]
        if col and c.label then c.label:SetTextColor(col.r, col.g, col.b) end
    end
    local epicNote = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    epicNote:SetPoint("TOPLEFT", 26, -152)
    epicNote:SetText("Epic and better never sell. Poor items in your bags also sell when you open a vendor.")

    Header("Keep", -176)
    Check("Gear", AS_GEAR_ONLY, "Above Poor, only sell weapons and armor",
        "Common and better trade goods, consumables, recipes and the like stay in your bags.", 22, -198)
    Check("Upgrades", AS_KEEP_UPGRADES, "Keep upgrades for me",
        "Weapons and armor you can use that are better (higher item level) than what you wear in that slot.", 22, -222)
    Check("BoE", AS_KEEP_BOE, "Keep Bind on Equip pieces I haven't bound",
        "Worth more on the auction house than at a vendor.", 22, -246)
    Check("Announce", AS_ANNOUNCE, "Tell me in chat what sold", nil, 22, -270)

    -- the never-sell list
    Header("Never sell", -302)
    local keepHint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    keepHint:SetPoint("TOPLEFT", 26, -322)
    keepHint:SetWidth(390)
    keepHint:SetJustifyH("LEFT")
    keepHint:SetText("Alt-click an item in your bags while this window is open, or drop one on the box below.")

    local list = CreateFrame("Button", nil, win)
    list:SetPoint("TOPLEFT", 22, -338)
    Size(list, 396, KEEP_ROWS * KEEP_H)
    local listBg = list:CreateTexture(nil, "BACKGROUND")
    listBg:SetAllPoints()
    listBg:SetTexture(0, 0, 0, 0.45)
    local empty = list:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER")
    empty:SetText("Drop an item here")
    list:EnableMouseWheel(true)

    local function AddCursorItem()
        local kind, id = GetCursorInfo()
        if kind == "item" and id then
            Send("ZK:" .. id)
            ClearCursor()
            return true
        end
    end
    list:SetScript("OnReceiveDrag", AddCursorItem)
    list:SetScript("OnClick", AddCursorItem)

    local rows = {}
    for i = 1, KEEP_ROWS do
        local r = CreateFrame("Button", nil, list)
        Size(r, 396, KEEP_H)
        r:SetPoint("TOPLEFT", 0, -(i - 1) * KEEP_H)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        Size(r.icon, 20, 20)
        r.icon:SetPoint("LEFT", 6, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetWidth(300)
        r.name:SetJustifyH("LEFT")
        r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        r:SetScript("OnReceiveDrag", AddCursorItem)
        r:SetScript("OnEnter", function(self)
            if not self.item then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.item.entry)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnClick", function(self) if not AddCursorItem() and self.item and IsModifiedClick() then
            HandleModifiedItemClick(select(2, GetItemInfo(self.item.entry))) end end)
        local x = CreateFrame("Button", nil, r, "UIPanelCloseButton")
        Size(x, 22, 22)
        x:SetPoint("RIGHT", -4, 0)
        x:SetScript("OnClick", function() if r.item then Send("ZU:" .. r.item.entry) end end)
        x:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Take it off the list (it can sell again)")
            GameTooltip:Show()
        end)
        x:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = r
    end
    local keepCount = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    keepCount:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", 0, -3)

    -- bottom: this session, and what would sell now
    local session = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    session:SetPoint("BOTTOMLEFT", 26, 52)
    session:SetJustifyH("LEFT")
    local now = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    now:SetPoint("BOTTOMLEFT", 26, 36)
    now:SetJustifyH("LEFT")
    local never = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    never:SetPoint("BOTTOMLEFT", 26, 20)
    never:SetText("Never sold: class uniques, Primals, runed gear, quest items, things that open.")

    StaticPopupDialogs["WORLDTIERS_SELL_NOW"] = {
        text = "Sell %s from your bags now? (The last 12 can be bought back at any vendor.)",
        button1 = ACCEPT, button2 = CANCEL,
        OnAccept = function() Send("ZN") end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    local sellNow = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    Size(sellNow, 110, 24)
    sellNow:SetPoint("BOTTOMRIGHT", -24, 40)
    sellNow:SetText("Sell now")
    sellNow:SetScript("OnClick", function()
        StaticPopup_Show("WORLDTIERS_SELL_NOW", string.format("%d item%s for %s", state.nowCount,
            state.nowCount == 1 and "" or "s", Money(state.nowCopper)))
    end)
    sellNow:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Sell now")
        GameTooltip:AddLine("Sells everything in your bags that matches the filter above, from anywhere.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sellNow:SetScript("OnLeave", function() GameTooltip:Hide() end)

    function WT.RefreshSell()
        for _, c in ipairs(checks) do
            c:SetChecked(Has(c.bit))
            if c.bit ~= AS_ENABLED then
                if Has(AS_ENABLED) then c:Enable() else c:Disable() end
                if c.label and c.label.SetAlpha then c.label:SetAlpha(Has(AS_ENABLED) and 1 or 0.45) end
            end
        end
        keepOffset = math.max(0, math.min(keepOffset, #keep - KEEP_ROWS))
        for i = 1, KEEP_ROWS do
            local r, it = rows[i], keep[keepOffset + i]
            r.item = it
            if it then
                local col = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality]
                r.icon:SetTexture(GetItemIcon(it.entry) or "Interface\\Icons\\INV_Misc_QuestionMark")
                r.name:SetText(it.name)
                if col then r.name:SetTextColor(col.r, col.g, col.b) end
                r:Show()
            else
                r:Hide()
            end
        end
        if #keep == 0 then empty:Show() else empty:Hide() end
        keepCount:SetText(#keep > KEEP_ROWS and string.format("%d items (scroll)", #keep) or "")
        session:SetText(string.format("This session: |cffffffff%d|r item%s sold for %s", state.soldCount,
            state.soldCount == 1 and "" or "s", Money(state.soldCopper)))
        if state.nowCount > 0 then
            now:SetText(string.format("In your bags now: |cffffffff%d|r item%s match (%s)", state.nowCount,
                state.nowCount == 1 and "" or "s", Money(state.nowCopper)))
            sellNow:Enable()
        else
            now:SetText("In your bags now: nothing matches")
            sellNow:Disable()
        end
    end

    list:SetScript("OnMouseWheel", function(self, delta)
        keepOffset = math.max(0, math.min(math.max(0, #keep - KEEP_ROWS), keepOffset - delta))
        WT.RefreshSell()
    end)

    -- ZO|  ZS|flags|sold|copper|now|nowCopper  ZK|entry^quality^name~...  ZE|kept  ZC| (something sold)
    function WT.OnSellMessage(msg)
        local cmd = msg:match("^(Z[OSKEC])|")
        if not cmd then return false end
        local rest = msg:sub(4)
        if cmd == "ZO" then
            win.serverOpened = true
            win:Show()
        elseif cmd == "ZS" then
            local f = Split(rest, "|")
            state.flags = tonumber(f[1]) or 0
            state.soldCount = tonumber(f[2]) or 0
            state.soldCopper = tonumber(f[3]) or 0
            state.nowCount = tonumber(f[4]) or 0
            state.nowCopper = tonumber(f[5]) or 0
            pending = {}
        elseif cmd == "ZK" and pending then
            for one in rest:gmatch("([^~]+)") do
                local f = Split(one, "^")
                pending[#pending + 1] = { entry = tonumber(f[1]) or 0, quality = tonumber(f[2]) or 1, name = f[3] or "?" }
            end
        elseif cmd == "ZE" then
            if pending then
                table.sort(pending, function(a, b) return a.name < b.name end)
                keep, pending = pending, nil
            end
            if win:IsShown() then WT.RefreshSell() end
        elseif cmd == "ZC" then
            if win:IsShown() then Send("Z") end
        end
        return true
    end

    -- Alt-click in the bags while the window is open: never sell it
    local function OnBagClick(self, button)
        if not win:IsShown() or not IsAltKeyDown() then return end
        local link = GetContainerItemLink(self:GetParent():GetID(), self:GetID())
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then Send("ZK:" .. id) end
    end
    if ContainerFrameItemButton_OnModifiedClick then
        hooksecurefunc("ContainerFrameItemButton_OnModifiedClick", OnBagClick)
    end

    -- the bags change: what would sell now changes too (a short wait, then ask once)
    local watch = CreateFrame("Frame")
    local askAt
    watch:RegisterEvent("BAG_UPDATE")
    watch:SetScript("OnEvent", function() if win:IsShown() then askAt = GetTime() + 0.5 end end)
    watch:SetScript("OnUpdate", function()
        if askAt and GetTime() >= askAt then askAt = nil Send("Z") end
    end)

    win:SetScript("OnShow", function()
        PlaySound("igCharacterInfoOpen")
        if win.serverOpened then win.serverOpened = false else Send("Z") end
        WT.RefreshSell()
    end)
    win:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") end)
    WT.SellFrame = win

    SLASH_WORLDTIERSSELL1 = "/autosell"
    SlashCmdList["WORLDTIERSSELL"] = function() if win:IsShown() then win:Hide() else win:Show() end end
end

-- ---------------------------------------------------------------------------
-- The loot window, every item at once: no pages. The stock window keeps all
-- its own behaviour (clicks, tooltips, Bind on Pickup, master loot); it only
-- gets as many buttons as the loot has, laid out in columns, a clean frame,
-- and Loot All.
-- ---------------------------------------------------------------------------

do
    local ROW_H, PER_COL, COL_W, TEXT_W = 40, 10, 214, 158
    local TOP, SIDE, BOTTOM = 46, 14, 40
    local styled, made = false, 4

    local function Btn(i) return _G["LootButton" .. i] end

    -- one row: the icon, then the name on a dark bar
    local function StyleButton(b)
        if not b or b.wtStyled then return end
        b.wtStyled = true
        local nf = _G[b:GetName() .. "NameFrame"]
        if nf then nf:Hide() end
        local bar = b:CreateTexture(nil, "BACKGROUND")
        bar:SetTexture(1, 1, 1, 0.07)
        bar:SetPoint("TOPLEFT", b, "TOPRIGHT", 2, -1)
        bar:SetPoint("BOTTOMLEFT", b, "BOTTOMRIGHT", 2, 1)
        bar:SetWidth(TEXT_W + 10)
        local text = _G[b:GetName() .. "Text"]
        if text then
            text:SetWidth(TEXT_W)
            text:SetHeight(36)
            text:ClearAllPoints()
            text:SetPoint("LEFT", b, "RIGHT", 8, 0)
        end
    end

    local function Ensure(n)
        for i = made + 1, n do
            local b = CreateFrame("Button", "LootButton" .. i, LootFrame, "LootButtonTemplate")
            b:SetID(i)
            b:Hide()
            made = i
        end
        for i = 1, made do StyleButton(Btn(i)) end
        LOOTFRAME_NUMBUTTONS = math.max(4, n, made)
    end

    local function Style()
        if styled or not LootFrame then return end
        styled = true
        for _, r in ipairs({ LootFrame:GetRegions() }) do r:Hide() end   -- the old art, "ITEMS", PREV / NEXT
        LootFrame:SetBackdrop({
            bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        LootFrame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
        if LootFrame.SetHitRectInsets then LootFrame:SetHitRectInsets(0, 0, 0, 0) end
        local t = LootFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t:SetPoint("TOPLEFT", 16, -14)
        LootFrame.wtTitle = t
        if LootCloseButton then
            LootCloseButton:ClearAllPoints()
            LootCloseButton:SetPoint("TOPRIGHT", -4, -4)
        end
        for _, n in ipairs({ "LootFrameUpButton", "LootFrameDownButton", "LootFramePrev", "LootFrameNext" }) do
            local f = _G[n]
            if f then f:Hide() f.Show = f.Hide end      -- there is only one page
        end
        local all = CreateFrame("Button", "WorldTiersLootAll", LootFrame, "UIPanelButtonTemplate")
        Size(all, 90, 22)
        all:SetPoint("BOTTOMRIGHT", -12, 10)
        all:SetText("Loot All")
        all:SetScript("OnClick", function()
            for slot = GetNumLootItems(), 1, -1 do
                if LootSlotIsItem(slot) or LootSlotIsCoin(slot) then LootSlot(slot) end
            end
        end)
        LootFrame.wtAll = all
    end

    local function SizeFor(n)
        local cols = math.max(1, math.ceil(n / PER_COL))
        local rowsN = math.max(1, math.min(n, PER_COL))
        LootFrame:SetWidth(SIDE * 2 + cols * COL_W - 10)
        LootFrame:SetHeight(TOP + rowsN * ROW_H + BOTTOM)
    end

    -- lay the shown buttons out in order, and size the window to them
    local function Layout()
        if not styled then return end
        local shown = 0
        for i = 1, made do
            local b = Btn(i)
            if b and b:IsShown() then
                local col, row = math.floor(shown / PER_COL), shown % PER_COL
                b:ClearAllPoints()
                b:SetPoint("TOPLEFT", LootFrame, "TOPLEFT", SIDE + col * COL_W, -(TOP + row * ROW_H))
                shown = shown + 1
            end
        end
        SizeFor(shown)
        if LootFrame.wtTitle then
            LootFrame.wtTitle:SetText(shown > 0 and string.format("Loot  |cff999999(%d)|r", shown) or "Loot  |cff999999(empty)|r")
        end
        if LootFrame.wtAll then if shown > 1 then LootFrame.wtAll:Show() else LootFrame.wtAll:Hide() end end
    end
    WT.LootLayout = Layout

    local function Install()
        if WT.lootInstalled or not LootFrame or not LootFrame_Show then return end
        WT.lootInstalled = true
        Style()
        local stockShow = LootFrame_Show
        LootFrame_Show = function(self, ...)
            local n = GetNumLootItems()
            Ensure(n)
            SizeFor(n)        -- before the panel is placed, so it is placed at its real size
            self.page = 1
            stockShow(self, ...)
            Layout()
        end
        LootFrame:HookScript("OnEvent", function(self, event)
            if event == "LOOT_SLOT_CLEARED" or event == "LOOT_SLOT_CHANGED" then Layout() end
        end)
    end
    WT.InstallLoot = Install
    Install()
end

-- ---------------------------------------------------------------------------
-- No "this item will bind to you" question when looting or rolling on
-- Bind on Pickup items: answered yes straight away. /wtbind turns the
-- question back on (or off again), per character.
-- ---------------------------------------------------------------------------

do
    local function Auto()
        return not (WorldTiersCharDB and WorldTiersCharDB.askBind)
    end
    local QUIET = { LOOT_BIND = true, CONFIRM_LOOT_ROLL = true }
    -- answered on the next frame: the client only starts waiting for the
    -- answer once its question has gone out, and a yes given in the same
    -- moment is lost (the item then took a second click)
    local pendingSlot, pendingRoll, pendingRollType
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("LOOT_BIND_CONFIRM")
    ev:RegisterEvent("CONFIRM_LOOT_ROLL")
    ev:RegisterEvent("LOOT_CLOSED")
    ev:Hide()
    ev:SetScript("OnEvent", function(self, event, a, b)
        if event == "LOOT_CLOSED" then
            pendingSlot = nil
            return
        end
        if not Auto() or not a then return end
        if event == "LOOT_BIND_CONFIRM" then
            pendingSlot = a
            StaticPopup_Hide("LOOT_BIND")
        elseif event == "CONFIRM_LOOT_ROLL" then
            pendingRoll, pendingRollType = a, b
            StaticPopup_Hide("CONFIRM_LOOT_ROLL")
        end
        self:Show()
    end)
    ev:SetScript("OnUpdate", function(self)
        self:Hide()
        if pendingSlot then
            local slot = pendingSlot
            pendingSlot = nil
            ConfirmLootSlot(slot)
            StaticPopup_Hide("LOOT_BIND")
        end
        if pendingRoll then
            local id, kind = pendingRoll, pendingRollType
            pendingRoll, pendingRollType = nil, nil
            ConfirmLootRoll(id, kind)
            StaticPopup_Hide("CONFIRM_LOOT_ROLL")
        end
    end)
    -- whichever runs first, the question never stays on screen
    hooksecurefunc("StaticPopup_Show", function(which)
        if QUIET[which] and Auto() then StaticPopup_Hide(which) end
    end)
    SLASH_WORLDTIERSBIND1 = "/wtbind"
    SlashCmdList["WORLDTIERSBIND"] = function()
        WorldTiersCharDB = WorldTiersCharDB or {}
        WorldTiersCharDB.askBind = not WorldTiersCharDB.askBind
        DEFAULT_CHAT_FRAME:AddMessage(WorldTiersCharDB.askBind
            and "|cffff9933World Tiers:|r you'll be asked again before looting Bind on Pickup items."
            or "|cffff9933World Tiers:|r Bind on Pickup items are looted without asking.")
    end
end

-- ---------------------------------------------------------------------------
-- Instance maps on the world map (M): inside a dungeon or raid the game has
-- no map for (most Classic and Burning Crusade ones), the world map shows
-- its map from Atlas, with its bosses down the side. Instances that have
-- their own map (Wrath) keep it. Needs the Atlas addon (it ships with the
-- client). Atlas itself still opens every map with /atlas.
-- ---------------------------------------------------------------------------

do
    local MAP_PATH = "Interface\\AddOns\\Atlas\\Images\\Maps\\"
    local overlay, pages, page, openedOn = nil, {}, 1, nil
    local wanted = true      -- the player's choice for this instance (Show / World map)

    local function Clean(name)
        name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        name = name:gsub("%s*%[%a%]", ""):gsub("%s*%b()", "")
        return (name:gsub("^%s+", ""):gsub("%s+$", ""))
    end

    -- the Atlas maps of the instance you are in: an exact name first
    -- ("Hellfire Ramparts", "Ulduar" [A]..[E]), else every wing of it
    -- ("Scarlet Monastery": its four wings)
    local function MapsHere()
        if type(AtlasMaps) ~= "table" then return {} end
        local here = {}
        for _, n in ipairs({ GetRealZoneText and GetRealZoneText() or "", GetInstanceInfo and (GetInstanceInfo()) or "" }) do
            if n and n ~= "" then here[n] = true end
        end
        local exact, wing = {}, {}
        for key, m in pairs(AtlasMaps) do
            local zn = type(m) == "table" and m.ZoneName and m.ZoneName[1]
            if type(zn) == "string" and not key:match("Ent$") then
                local full = Clean(zn)
                local parent, child = full:match("^(.-):%s*(.+)$")
                if here[full] or (child and here[child]) then
                    exact[#exact + 1] = key
                elseif parent and here[parent] then
                    wing[#wing + 1] = key
                end
            end
        end
        local out = #exact > 0 and exact or wing
        table.sort(out)
        return out
    end

    local function Build()
        if overlay or not WorldMapDetailFrame then return end
        overlay = CreateFrame("Frame", "WorldTiersInstanceMap", WorldMapDetailFrame)
        overlay:SetAllPoints(WorldMapDetailFrame)
        overlay:SetFrameLevel((WorldMapButton and WorldMapButton:GetFrameLevel() or WorldMapDetailFrame:GetFrameLevel()) + 10)
        overlay:EnableMouse(true)        -- clicks stay here: a click would zoom the world map out
        local bg = overlay:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(0, 0, 0, 1)
        overlay.map = overlay:CreateTexture(nil, "ARTWORK")
        overlay.map:SetPoint("TOPLEFT", 0, 0)
        overlay.map:SetPoint("BOTTOMLEFT", 0, 0)
        overlay.map:SetWidth(668)
        local side = CreateFrame("Frame", nil, overlay)
        side:SetPoint("TOPLEFT", overlay.map, "TOPRIGHT", 12, -12)
        side:SetPoint("BOTTOMRIGHT", -12, 44)
        overlay.title = side:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        overlay.title:SetPoint("TOPLEFT", 0, 0)
        overlay.title:SetWidth(310)
        overlay.title:SetJustifyH("LEFT")
        overlay.sub = side:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        overlay.sub:SetPoint("TOPLEFT", overlay.title, "BOTTOMLEFT", 0, -4)
        overlay.sub:SetWidth(310)
        overlay.sub:SetJustifyH("LEFT")
        overlay.legend = side:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        overlay.legend:SetPoint("TOPLEFT", overlay.sub, "BOTTOMLEFT", 0, -10)
        overlay.legend:SetPoint("BOTTOMRIGHT", side, "BOTTOMRIGHT", 0, 0)
        overlay.legend:SetJustifyH("LEFT")
        overlay.legend:SetJustifyV("TOP")

        local function Btn(text, w)
            local b = CreateFrame("Button", nil, overlay, "UIPanelButtonTemplate")
            Size(b, w, 22)
            b:SetText(text)
            return b
        end
        overlay.prev = Btn("<", 30)
        overlay.prev:SetPoint("BOTTOMLEFT", overlay.map, "BOTTOMRIGHT", 12, 12)
        overlay.prev:SetScript("OnClick", function() page = page > 1 and page - 1 or #pages WT.DrawInstanceMap() end)
        overlay.pageText = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        overlay.pageText:SetPoint("LEFT", overlay.prev, "RIGHT", 6, 0)
        overlay.next = Btn(">", 30)
        overlay.next:SetPoint("LEFT", overlay.pageText, "RIGHT", 6, 0)
        overlay.next:SetScript("OnClick", function() page = page < #pages and page + 1 or 1 WT.DrawInstanceMap() end)
        overlay.world = Btn("World map", 90)
        overlay.world:SetPoint("BOTTOMRIGHT", -12, 12)
        overlay.world:SetScript("OnClick", function() wanted = false overlay:Hide() WT.UpdateInstanceMapButton() end)

        -- on the world map's own frame: bring the instance map back
        local show = CreateFrame("Button", "WorldTiersInstanceMapButton", WorldMapFrame, "UIPanelButtonTemplate")
        Size(show, 120, 22)
        show:SetPoint("BOTTOMLEFT", WorldMapDetailFrame, "TOPLEFT", 0, 4)
        show:SetText("Instance map")
        show:SetScript("OnClick", function() wanted = true WT.ShowInstanceMap() end)
        show:Hide()
        overlay.show = show
        overlay:Hide()
    end

    function WT.DrawInstanceMap()
        if not overlay or #pages == 0 then return end
        page = math.max(1, math.min(page, #pages))
        local key = pages[page]
        local m = AtlasMaps[key] or {}
        overlay.map:SetTexture(MAP_PATH .. key)
        overlay.title:SetText(Clean(m.ZoneName and m.ZoneName[1] or key))
        local bits = {}
        if m.LevelRange then bits[#bits + 1] = "Levels " .. m.LevelRange end
        if m.PlayerLimit then bits[#bits + 1] = m.PlayerLimit .. " players" end
        if m.Location and m.Location[1] then bits[#bits + 1] = m.Location[1] end
        overlay.sub:SetText(table.concat(bits, "   "))
        local text = {}
        for _, line in ipairs(m) do
            if type(line) == "table" and type(line[1]) == "string" and line[1] ~= "" then text[#text + 1] = line[1] end
            if #text >= 44 then break end
        end
        overlay.legend:SetText(table.concat(text, "\n"))
        overlay.pageText:SetText(#pages > 1 and string.format("%d / %d", page, #pages) or "")
        if #pages > 1 then overlay.prev:Show() overlay.next:Show() else overlay.prev:Hide() overlay.next:Hide() end
    end

    local function InInstanceWithoutMap()
        local inside, kind = IsInInstance()
        if not inside or (kind ~= "party" and kind ~= "raid") then return false end
        if GetNumDungeonMapLevels and GetNumDungeonMapLevels() > 0 then return false end
        return true
    end

    function WT.UpdateInstanceMapButton()
        if not overlay then return end
        if InInstanceWithoutMap() and #pages > 0 and not overlay:IsShown() then overlay.show:Show() else overlay.show:Hide() end
    end

    function WT.ShowInstanceMap()
        Build()
        if not overlay then return end
        pages = MapsHere()
        if #pages == 0 or not InInstanceWithoutMap() then overlay:Hide() WT.UpdateInstanceMapButton() return end
        openedOn = GetMapInfo and GetMapInfo() or ""
        WT.DrawInstanceMap()
        overlay:Show()
        WT.UpdateInstanceMapButton()
    end

    local ev = CreateFrame("Frame")
    ev:RegisterEvent("WORLD_MAP_UPDATE")
    ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function(self, event)
        if event ~= "WORLD_MAP_UPDATE" then
            wanted, page = true, 1        -- a new place: its map first
            if overlay then overlay:Hide() end
            return
        end
        if not WorldMapFrame or not WorldMapFrame:IsShown() then return end
        if overlay and overlay:IsShown() then
            -- the player browsed elsewhere on the world map: step aside
            if (GetMapInfo and GetMapInfo() or "") ~= openedOn then overlay:Hide() end
            WT.UpdateInstanceMapButton()
        end
    end)
    if WorldMapFrame then
        WorldMapFrame:HookScript("OnShow", function()
            if wanted then WT.ShowInstanceMap() else Build() WT.UpdateInstanceMapButton() end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- The transmog window: your character, the slots, every collected look
-- ---------------------------------------------------------------------------

do
    local COLS, ROWS = 6, 3
    local PER_PAGE = COLS * ROWS
    local HIDDEN = 1
    -- server equipment slot, client slot name, label, camera (zoom, height)
    local SLOTS = {
        { 0, "HeadSlot", "Head", 1.7, -0.62 },          { 2, "ShoulderSlot", "Shoulders", 1.2, -0.45 },
        { 14, "BackSlot", "Back", 0.2, -0.1 },           { 4, "ChestSlot", "Chest", 0.9, -0.25 },
        { 3, "ShirtSlot", "Shirt", 0.9, -0.25 },         { 18, "TabardSlot", "Tabard", 0.9, -0.25 },
        { 8, "WristSlot", "Wrists", 0.9, -0.1 },         { 9, "HandsSlot", "Hands", 0.9, -0.05 },
        { 5, "WaistSlot", "Waist", 1.1, -0.05 },         { 6, "LegsSlot", "Legs", 0.6, 0.25 },
        { 7, "FeetSlot", "Feet", 1.1, 0.55 },            { 15, "MainHandSlot", "Main Hand", 0.2, 0 },
        { 16, "SecondaryHandSlot", "Off Hand", 0.2, 0 }, { 17, "RangedSlot", "Ranged", 0.2, 0 },
    }
    local ARMOR_SLOTS = { [0] = true, [2] = true, [4] = true, [5] = true, [6] = true, [7] = true, [8] = true, [9] = true }
    local FILTERS = { { 0, "All" }, { 1, "Cloth" }, { 2, "Leather" }, { 3, "Mail" }, { 4, "Plate" } }

    local tm = { state = {}, building = nil, pending = {}, outfits = {}, building_outfits = nil,
                 slot = 0, page = 1, filter = 0, search = "", hiddenOk = true, mode = "looks" }
    WT.transmog = tm   -- for /dump and tests
    local SlotInfo = {}
    for _, s in ipairs(SLOTS) do SlotInfo[s[1]] = s end

    local win = CreateFrame("Frame", "WorldTiersTransmogFrame", UIParent)
    Size(win, 1000, 640)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    win:Hide()
    tinsert(UISpecialFrames, "WorldTiersTransmogFrame")

    local drag = CreateFrame("Frame", nil, win)
    drag:SetPoint("TOPLEFT", 12, -8)
    drag:SetPoint("TOPRIGHT", -40, -8)
    drag:SetHeight(28)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() win:StartMoving() end)
    drag:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)

    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOP", 0, -16)
    title:SetText("Transmogrification")
    local closeB = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeB:SetPoint("TOPRIGHT", -6, -6)

    local function Button(parent, w, h, text)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        Size(b, w, h)
        b:SetText(text)
        return b
    end

    local looksTab = Button(win, 130, 26, "Appearances")
    looksTab:SetPoint("TOPLEFT", 24, -44)
    local outfitsTab = Button(win, 110, 26, "Outfits")
    outfitsTab:SetPoint("LEFT", looksTab, "RIGHT", 6, 0)
    local tagline = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tagline:SetPoint("LEFT", outfitsTab, "RIGHT", 12, 0)
    tagline:SetText("Account-wide collection - looks only, stats untouched - always free")
    local status = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    status:SetPoint("TOPRIGHT", -30, -50)

    -- ---------------- the character ----------------
    local left = CreateFrame("Frame", nil, win)
    left:SetPoint("TOPLEFT", 20, -76)
    Size(left, 380, 500)
    left:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                       tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    left:SetBackdropColor(0.08, 0.04, 0.14, 0.9)

    local model = CreateFrame("DressUpModel", "WorldTiersTransmogModel", left)
    model:SetPoint("TOPLEFT", 60, -10)
    Size(model, 260, 420)
    model.rotation, model.zoom = 0.3, 0
    model:EnableMouse(true)
    model:EnableMouseWheel(true)
    model:SetScript("OnMouseDown", function(self) self.dragX = GetCursorPosition() end)
    model:SetScript("OnMouseUp", function(self) self.dragX = nil end)
    model:SetScript("OnUpdate", function(self)
        if self.dragX then
            local x = GetCursorPosition()
            self.rotation = self.rotation + (x - self.dragX) / 80
            self.dragX = x
            self:SetRotation(self.rotation)
        end
    end)
    model:SetScript("OnMouseWheel", function(self, d)
        self.zoom = math.max(0, math.min(2.5, self.zoom + d * 0.25))
        self:SetPosition(self.zoom, 0, 0)
    end)

    local slotButtons = {}
    local RefreshAll -- forward
    for i, s in ipairs(SLOTS) do
        local b = CreateFrame("Button", nil, left)
        Size(b, 40, 40)
        local col, row = (i <= 7) and 0 or 1, (i - 1) % 7
        b:SetPoint("TOPLEFT", col == 0 and 10 or 330, -10 - row * 52)
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.mark = b:CreateTexture(nil, "OVERLAY")
        b.mark:SetPoint("BOTTOMLEFT", 0, -4)
        b.mark:SetPoint("BOTTOMRIGHT", 0, -4)
        b.mark:SetHeight(3)
        b.sel = b:CreateTexture(nil, "OVERLAY")
        b.sel:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        b.sel:SetBlendMode("ADD")
        b.sel:SetAllPoints()
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b.slot = s[1]
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                WT.RestoreOriginal(self.slot)
                return
            end
            tm.slot, tm.page = self.slot, 1
            tm.mode = "looks"
            WT.RequestLooks()
            RefreshAll()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local st = tm.state[self.slot]
            GameTooltip:SetText(SlotInfo[self.slot][3])
            local p = tm.pending[self.slot]
            if p ~= nil then
                GameTooltip:AddLine(p == 0 and "Pending: your own look" or p == HIDDEN and "Pending: hidden" or ("Pending: " .. (GetItemInfo(p) or ("item " .. p))), 0.2, 1, 0.2)
            elseif st and st.look and st.look > 0 then
                GameTooltip:AddLine(st.look == HIDDEN and "Hidden" or ("Showing: " .. (GetItemInfo(st.look) or ("item " .. st.look))), 1, 0.82, 0)
            elseif not st or st.item == 0 then
                GameTooltip:AddLine("Nothing equipped here.", 0.6, 0.6, 0.6)
            else
                GameTooltip:AddLine("Original look", 0.7, 0.7, 0.7)
            end
            if st and st.item > 0 then
                GameTooltip:AddLine("Left-click: choose a look. Right-click: back to the original look.", 0.6, 0.8, 1, true)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        slotButtons[i] = b
    end

    local function ModelButton(text, x, fn)
        local b = Button(left, 40, 22, text)
        b:SetPoint("BOTTOMLEFT", x, 40)
        b:SetScript("OnClick", fn)
        return b
    end
    ModelButton("<", 60, function() model.rotation = model.rotation - 0.4 model:SetRotation(model.rotation) end)
    ModelButton(">", 104, function() model.rotation = model.rotation + 0.4 model:SetRotation(model.rotation) end)
    ModelButton("+", 148, function() model.zoom = math.min(2.5, model.zoom + 0.4) model:SetPosition(model.zoom, 0, 0) end)
    ModelButton("-", 192, function() model.zoom = math.max(0, model.zoom - 0.4) model:SetPosition(model.zoom, 0, 0) end)
    local resetView = Button(left, 70, 22, "Reset")
    resetView:SetPoint("BOTTOMLEFT", 240, 40)
    local viewHint = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    viewHint:SetPoint("BOTTOM", 0, 16)
    viewHint:SetText("Drag to turn - wheel to zoom")

    -- ---------------- the looks ----------------
    local right = CreateFrame("Frame", nil, win)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 10, 0)
    right:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -20, 64)
    right:SetBackdrop(left:GetBackdrop())
    right:SetBackdropColor(0.08, 0.04, 0.14, 0.9)

    local slotTitle = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    slotTitle:SetPoint("TOPLEFT", 14, -12)
    local slotCount = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    slotCount:SetPoint("LEFT", slotTitle, "RIGHT", 10, 0)

    local hideB = Button(right, 90, 22, "Hide slot")
    local ownB = Button(right, 130, 22, "Restore original")
    local search = CreateFrame("EditBox", "WorldTiersTransmogSearch", right, "InputBoxTemplate")
    Size(search, 150, 20)
    search:SetPoint("TOPRIGHT", -14, -12)
    search:SetAutoFocus(false)
    local searchHint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    searchHint:SetPoint("LEFT", 2, 0)
    ownB:SetPoint("RIGHT", search, "LEFT", -10, 0)
    hideB:SetPoint("RIGHT", ownB, "LEFT", -6, 0)

    -- what this slot shows now / after Apply
    local slotState = right:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    slotState:SetPoint("TOPRIGHT", -14, -44)
    slotState:SetJustifyH("RIGHT")

    local filterButtons = {}
    for i, f in ipairs(FILTERS) do
        local b = Button(right, 64, 20, f[2])
        b:SetPoint("TOPLEFT", 14 + (i - 1) * 68, -40)
        b:SetScript("OnClick", function() tm.filter, tm.page = f[1], 1 WT.RequestLooks() RefreshAll() end)
        filterButtons[i] = b
    end

    local cells = {}
    local CELL_W, CELL_H = 84, 112
    for i = 1, PER_PAGE do
        local c = CreateFrame("Button", nil, right)
        Size(c, CELL_W, CELL_H)
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        c:SetPoint("TOPLEFT", 14 + col * (CELL_W + 8), -68 - row * (CELL_H + 22))
        c:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        c:SetBackdropColor(0.18, 0.08, 0.3, 0.9)
        c.model = CreateFrame("DressUpModel", nil, c)
        c.model:SetPoint("TOPLEFT", 4, -4)
        c.model:SetPoint("BOTTOMRIGHT", -4, 4)
        c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        c.name:SetPoint("TOP", c, "BOTTOM", 0, -2)
        c.name:SetWidth(CELL_W + 6)
        c.name:SetHeight(20)
        c.name:SetJustifyV("TOP")
        c.check = c:CreateTexture(nil, "OVERLAY")
        Size(c.check, 20, 20)
        c.check:SetPoint("TOPRIGHT", -2, -2)
        c.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
        c:RegisterForClicks("LeftButtonUp")
        c:SetScript("OnClick", function(self)
            if not self.entry then return end
            tm.pending[tm.slot] = self.entry
            RefreshAll()
        end)
        c:SetScript("OnEnter", function(self)
            if not self.entry then return end
            model:TryOn("item:" .. self.entry)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. self.entry)
            GameTooltip:AddLine("Click to choose - Apply to keep", 0.6, 0.8, 1)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() WT.DressModel() end)
        cells[i] = c
    end

    local prevB = Button(right, 34, 22, "<")
    prevB:SetPoint("BOTTOMRIGHT", -54, 10)
    local nextB = Button(right, 34, 22, ">")
    nextB:SetPoint("BOTTOMRIGHT", -14, 10)
    local pageText = right:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    pageText:SetPoint("RIGHT", prevB, "LEFT", -10, 0)
    local pickHint = right:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    pickHint:SetPoint("BOTTOMLEFT", 14, 14)
    pickHint:SetText("Click to choose - hover to try on - Restore original (or right-click the slot) to go back")

    -- outfits view (shares the right panel)
    local outfitRows = {}
    for i = 1, 12 do
        local r = CreateFrame("Frame", nil, right)
        Size(r, 540, 28)
        r:SetPoint("TOPLEFT", 14, -40 - (i - 1) * 32)
        r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.text:SetPoint("LEFT", 0, 0)
        r.text:SetWidth(320)
        r.text:SetJustifyH("LEFT")
        r.wear = Button(r, 90, 22, "Wear")
        r.wear:SetPoint("LEFT", r.text, "RIGHT", 8, 0)
        r.del = Button(r, 80, 22, "Delete")
        r.del:SetPoint("LEFT", r.wear, "RIGHT", 6, 0)
        outfitRows[i] = r
    end
    local noOutfits = right:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    noOutfits:SetPoint("TOPLEFT", 14, -46)
    noOutfits:SetText("No outfits yet. Choose a look, then Save as outfit.")

    -- ---------------- the bottom bar ----------------
    local resetAll = Button(win, 170, 26, "Restore all originals")
    resetAll:SetPoint("BOTTOMLEFT", 24, 24)
    local saveOutfit = Button(win, 140, 26, "Save as outfit")
    saveOutfit:SetPoint("LEFT", resetAll, "RIGHT", 6, 0)
    local applyB = Button(win, 200, 30, "Apply")
    applyB:SetPoint("BOTTOMRIGHT", -26, 22)
    local undoB = Button(win, 140, 26, "Undo changes")
    undoB:SetPoint("RIGHT", applyB, "LEFT", -8, 0)
    local liveText = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    liveText:SetPoint("RIGHT", undoB, "LEFT", -12, 0)

    StaticPopupDialogs["WORLDTIERS_SAVE_OUTFIT"] = {
        text = "Name this outfit:",
        button1 = SAVE or "Save", button2 = CANCEL,
        hasEditBox = 1, maxLetters = 24,
        OnShow = function(self) local e = _G[self:GetName() .. "EditBox"] if e then e:SetText("") e:SetFocus() end end,
        OnAccept = function(self, data) local e = _G[self:GetName() .. "EditBox"] WT.SaveOutfit(e and e:GetText() or "") end,
        EditBoxOnEnterPressed = function(self) WT.SaveOutfit(self:GetText()) self:GetParent():Hide() end,
        EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
        timeout = 0, whileDead = 1, hideOnEscape = 1,
    }

    -- what each slot will show after Apply
    local function Wanted(slot)
        local p = tm.pending[slot]
        if p ~= nil then return p end
        local st = tm.state[slot]
        return st and st.look or 0
    end

    function WT.DressModel()
        model:SetUnit("player")
        model:SetRotation(model.rotation)
        model:SetPosition(model.zoom, 0, 0)
        for _, s in ipairs(SLOTS) do
            local p = tm.pending[s[1]]
            if p and p > HIDDEN then
                model:TryOn("item:" .. p)
            elseif p == 0 and tm.state[s[1]] and tm.state[s[1]].item > 0 then
                model:TryOn("item:" .. tm.state[s[1]].item)
            end
        end
    end

    -- back to the item's own look (applied with Apply, like any other choice)
    function WT.RestoreOriginal(slot)
        local st = tm.state[slot]
        if not st or st.item == 0 then return end
        if (st.look or 0) == 0 then tm.pending[slot] = nil else tm.pending[slot] = 0 end
        WT.DressModel()
        RefreshAll()
    end

    function WT.SaveOutfit(name)
        name = (name or ""):gsub("[|:^~,=]", "")
        local parts = {}
        for _, s in ipairs(SLOTS) do
            local w = Wanted(s[1])
            if w and w > 0 then parts[#parts + 1] = s[1] .. "=" .. w end
        end
        if name == "" or #parts == 0 then
            UIErrorsFrame:AddMessage("Name the outfit, and choose a look for at least one slot.", 1, 0.2, 0.2)
            return
        end
        Send("XS:" .. name .. ":" .. table.concat(parts, ","))
    end

    -- The server pages, filters and searches: ask for one page at a time.
    function WT.RequestLooks()
        local q = (tm.search or ""):gsub("[:|~^]", ""):sub(1, 30)
        tm.loading = true
        Send(string.format("XL:%d:%d:%d:%s", tm.slot, tm.filter, tm.page, q))
    end

    RefreshAll = function()
        -- slots
        local changed = 0
        for i, s in ipairs(SLOTS) do
            local b, st = slotButtons[i], tm.state[s[1]]
            local _, emptyTex = GetInventorySlotInfo(s[2])
            local w = Wanted(s[1])
            local tex = (w and w > HIDDEN and GetItemIcon(w)) or GetInventoryItemTexture("player", s[1] + 1) or emptyTex
            b.icon:SetTexture(tex)
            b.icon:SetDesaturated(w == HIDDEN and 1 or nil)
            if tm.pending[s[1]] ~= nil then b.mark:SetTexture(0.2, 1, 0.2) b.mark:Show()
            elseif st and st.look and st.look > 0 then b.mark:SetTexture(1, 0.82, 0) b.mark:Show()
            else b.mark:Hide() end
            if s[1] == tm.slot then b.sel:Show() else b.sel:Hide() end
            if st and st.look and st.look > 0 then changed = changed + 1 end
        end
        status:SetText(string.format("|cffffd100%d|r of 14 transmogged", changed))
        local npend = 0
        for _ in pairs(tm.pending) do npend = npend + 1 end
        liveText:SetText(npend > 0 and string.format("|cff20ff20%d change%s to apply|r", npend, npend == 1 and "" or "s") or "Your look is live.")
        if npend > 0 then applyB:Enable() undoB:Enable() else applyB:Disable() undoB:Disable() end

        local looks = tm.mode == "looks"
        for _, c in ipairs(cells) do if looks then c:Show() else c:Hide() end end
        for _, b in ipairs(filterButtons) do if looks and ARMOR_SLOTS[tm.slot] then b:Show() else b:Hide() end end
        for _, r in ipairs(outfitRows) do r:Hide() end
        noOutfits:Hide()
        for _, w in ipairs({ prevB, nextB, pageText, pickHint, hideB, ownB, search, slotCount, slotState }) do if looks then w:Show() else w:Hide() end end
        if looks then looksTab:LockHighlight() outfitsTab:UnlockHighlight() else outfitsTab:LockHighlight() looksTab:UnlockHighlight() end

        if not looks then
            slotTitle:SetText("Outfits")
            for i, r in ipairs(outfitRows) do
                local o = tm.outfits[i]
                if o then
                    r.text:SetText(string.format("|cffffd100%s|r  |cff888888(%d slot%s)|r", o.name, #o.looks, #o.looks == 1 and "" or "s"))
                    r.wear:SetScript("OnClick", function()
                        for _, l in ipairs(o.looks) do tm.pending[l[1]] = l[2] end
                        WT.DressModel()
                        RefreshAll()
                    end)
                    r.del:SetScript("OnClick", function() Send("XD:" .. o.id) end)
                    r:Show()
                end
            end
            if #tm.outfits == 0 then noOutfits:Show() end
            return
        end

        local info = SlotInfo[tm.slot]
        slotTitle:SetText(info[3])
        local view = tm.view and tm.view.slot == tm.slot and tm.view or nil
        local st = tm.state[tm.slot]
        if not st or st.item == 0 then
            slotCount:SetText("|cff888888nothing equipped here|r")
        else
            slotCount:SetText(view and (view.total .. " look" .. (view.total == 1 and "" or "s")) or "loading...")
        end
        if tm.hiddenOk and st and st.item > 0 then hideB:Enable() else hideB:Disable() end
        if st and st.item > 0 and Wanted(tm.slot) ~= 0 then ownB:Enable() else ownB:Disable() end
        local function LookName(e) return e == HIDDEN and "hidden" or (GetItemInfo(e) or ("item " .. e)) end
        if not st or st.item == 0 then
            slotState:SetText("")
        elseif tm.pending[tm.slot] ~= nil then
            local p = tm.pending[tm.slot]
            slotState:SetText("|cff20ff20After Apply: " .. (p == 0 and "original look" or LookName(p)) .. "|r")
        elseif (st.look or 0) > 0 then
            slotState:SetText("|cffffd100Transmogged: " .. LookName(st.look) .. "|r")
        else
            slotState:SetText("|cff999999Original look|r")
        end
        for i, f in ipairs(FILTERS) do
            if f[1] == tm.filter then filterButtons[i]:LockHighlight() else filterButtons[i]:UnlockHighlight() end
        end

        local vis = view and view.items or {}
        local pages = view and view.pages or 1
        pageText:SetText(view and string.format("%d shown - page %d / %d", view.total, view.page, pages) or "")
        if tm.page > 1 then prevB:Enable() else prevB:Disable() end
        if tm.page < pages then nextB:Enable() else nextB:Disable() end
        local want = Wanted(tm.slot)
        for i, c in ipairs(cells) do
            local it = vis[i]
            c.entry = it and it.entry
            if it then
                local q = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[it.quality]
                c.name:SetText(it.name)
                if q then
                    c.name:SetTextColor(q.r, q.g, q.b)
                    c:SetBackdropBorderColor(q.r, q.g, q.b)
                end
                if c.shown ~= it.entry or c.shownSlot ~= tm.slot then
                    c.shown, c.shownSlot = it.entry, tm.slot
                    c.model:SetUnit("player")
                    c.model:Undress()
                    c.model:SetPosition(info[4], 0, info[5])
                    c.model:SetRotation(0.25)
                    c.model:TryOn("item:" .. it.entry)
                end
                if want == it.entry then c.check:Show() else c.check:Hide() end
                c:Show()
            else
                c:Hide()
            end
        end
    end

    -- buttons
    looksTab:SetScript("OnClick", function() tm.mode = "looks" RefreshAll() end)
    outfitsTab:SetScript("OnClick", function() tm.mode = "outfits" Send("XU") RefreshAll() end)
    local function Turn(d)
        local pages = tm.view and tm.view.pages or 1
        local p = math.max(1, math.min(pages, tm.page + d))
        if p ~= tm.page then tm.page = p WT.RequestLooks() end
    end
    prevB:SetScript("OnClick", function() Turn(-1) end)
    nextB:SetScript("OnClick", function() Turn(1) end)
    right:EnableMouseWheel(true)
    right:SetScript("OnMouseWheel", function(self, d) if tm.mode == "looks" then Turn(-d) end end)
    hideB:SetScript("OnClick", function() tm.pending[tm.slot] = HIDDEN WT.DressModel() RefreshAll() end)
    ownB:SetScript("OnClick", function() WT.RestoreOriginal(tm.slot) end)
    search:SetScript("OnTextChanged", function(self)
        tm.search = self:GetText() or ""
        if tm.search == "" then searchHint:SetText("Search " .. SlotInfo[tm.slot][3]:lower() .. "...") searchHint:Show() else searchHint:Hide() end
        tm.page = 1
        tm.searchAt = GetTime() + 0.35   -- ask once typing pauses
    end)
    win:SetScript("OnUpdate", function()
        if tm.searchAt and GetTime() >= tm.searchAt then tm.searchAt = nil WT.RequestLooks() end
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    resetView:SetScript("OnClick", function() model.rotation, model.zoom = 0.3, 0 WT.DressModel() end)
    resetAll:SetScript("OnClick", function()
        for _, s in ipairs(SLOTS) do
            local st = tm.state[s[1]]
            if st and st.item > 0 and st.look and st.look > 0 then tm.pending[s[1]] = 0 end
        end
        WT.DressModel()
        RefreshAll()
    end)
    undoB:SetScript("OnClick", function() tm.pending = {} WT.DressModel() RefreshAll() end)
    saveOutfit:SetScript("OnClick", function() StaticPopup_Show("WORLDTIERS_SAVE_OUTFIT") end)
    applyB:SetScript("OnClick", function()
        local parts = {}
        for slot, entry in pairs(tm.pending) do
            local st = tm.state[slot]
            if st and st.item > 0 and entry ~= (st.look or 0) then parts[#parts + 1] = slot .. "=" .. entry end
        end
        tm.pending = {}
        if #parts > 0 then Send("XA:" .. table.concat(parts, ",")) else RefreshAll() end
    end)

    -- XO|  XB|hiddenOk|collection  XS|slot|item|look  XE|n
    -- XP|slot|page|pages|total  XI|entry^quality^subclass^name~...  XQ|slot  XU|id|name|data  XV|
    function WT.OnTransmogMessage(msg)
        local cmd = msg:match("^(X[OBSEPIQUV])|")
        if not cmd then return false end
        local f = Split(msg:sub(4), "|")
        if cmd == "XO" then
            win.serverOpened = true
            tm.view = nil
            win:Show()
        elseif cmd == "XB" then
            tm.hiddenOk = f[1] == "1"
            tm.newState = {}
        elseif cmd == "XS" and tm.newState then
            tm.newState[tonumber(f[1]) or 0] = { item = tonumber(f[2]) or 0, look = tonumber(f[3]) or 0 }
        elseif cmd == "XE" and tm.newState then
            local old = tm.state[tm.slot]
            local new = tm.newState[tm.slot]
            local again = not tm.view or tm.view.slot ~= tm.slot or not old or not new or old.item ~= new.item
            tm.state, tm.newState = tm.newState, nil
            WT.DressModel()
            if win:IsShown() then
                if again then WT.RequestLooks() end
                RefreshAll()
            end
        elseif cmd == "XP" then
            local slot = tonumber(f[1]) or 0
            tm.building = { slot = slot, page = tonumber(f[2]) or 1, pages = tonumber(f[3]) or 1, total = tonumber(f[4]) or 0, items = {} }
        elseif cmd == "XI" and tm.building then
            for one in (f[1] or ""):gmatch("([^~]+)") do
                local p = Split(one, "^")
                table.insert(tm.building.items, { entry = tonumber(p[1]) or 0, quality = tonumber(p[2]) or 1, sub = tonumber(p[3]) or 0, name = p[4] or "?" })
            end
        elseif cmd == "XQ" and tm.building then
            if tm.building.slot == tm.slot then
                tm.view, tm.page = tm.building, tm.building.page
            end
            tm.building, tm.loading = nil, false
            if win:IsShown() then RefreshAll() end
        elseif cmd == "XU" then
            tm.building_outfits = tm.building_outfits or {}
            local looks = {}
            for pair in (f[3] or ""):gmatch("([^,]+)") do
                local s, e = pair:match("(%d+)=(%d+)")
                if s then looks[#looks + 1] = { tonumber(s), tonumber(e) } end
            end
            table.insert(tm.building_outfits, { id = tonumber(f[1]) or 0, name = f[2] or "", looks = looks })
        elseif cmd == "XV" then
            tm.outfits, tm.building_outfits = tm.building_outfits or {}, nil
            if win:IsShown() then RefreshAll() end
        end
        return true
    end

    win:SetScript("OnShow", function()
        PlaySound("igCharacterInfoOpen")
        if win.serverOpened then win.serverOpened = false else Send("X") end
        tm.pending = {}
        searchHint:SetText("Search " .. SlotInfo[tm.slot][3]:lower() .. "...")
        WT.DressModel()
        RefreshAll()
    end)
    win:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") end)

    SLASH_WORLDTIERSTRANSMOG1 = "/transmog"
    SLASH_WORLDTIERSTRANSMOG2 = "/tmog"
    SlashCmdList["WORLDTIERSTRANSMOG"] = function() if win:IsShown() then win:Hide() else win:Show() end end
end

-- ---------------------------------------------------------------------------
-- Treasure Maps: a small compass that points to the spot your map marks,
-- and a pin on the world map. TM|kind|cursed|zone|x|y (a map in use),
-- TC|yards|angle (each second; -1: another continent), TX| (done).
-- ---------------------------------------------------------------------------

do
    local KINDS = {
        [0] = { "Worn Map", { 0.12, 1, 0 }, "Interface\\Icons\\INV_Misc_Map_01" },
        [1] = { "Detailed Map", { 0, 0.44, 0.87 }, "Interface\\Icons\\INV_Misc_Map06" },
        [2] = { "Ancient Map", { 0.64, 0.21, 0.93 }, "Interface\\Icons\\INV_Scroll_05" },
        [3] = { "Legendary Map", { 1, 0.5, 0 }, "Interface\\Icons\\Racial_Dwarf_FindTreasure" },
    }
    local DIG_RANGE = 12
    local active = nil   -- { kind, cursed, zone, x, y, yards, angle }

    local f = CreateFrame("Frame", "WorldTiersTreasureFrame", UIParent)
    Size(f, 230, 70)
    f:SetPoint("TOP", UIParent, "TOP", 0, -110)
    f:SetFrameStrata("MEDIUM")
    f:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    f:SetBackdropColor(0.05, 0.04, 0.02, 0.88)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    f:Hide()

    local icon = f:CreateTexture(nil, "ARTWORK")
    Size(icon, 34, 34)
    icon:SetPoint("LEFT", 10, 0)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 2)
    title:SetWidth(130)
    title:SetJustifyH("LEFT")
    local zoneText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    zoneText:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    zoneText:SetWidth(130)
    zoneText:SetJustifyH("LEFT")
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", zoneText, "BOTTOMLEFT", 0, -3)
    hint:SetWidth(130)
    hint:SetJustifyH("LEFT")

    local arrow = f:CreateTexture(nil, "OVERLAY")
    Size(arrow, 40, 40)
    arrow:SetPoint("RIGHT", -12, 4)
    arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    local yards = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    yards:SetPoint("TOP", arrow, "BOTTOM", 0, 2)

    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    Size(close, 20, 20)
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() f:Hide() end)

    -- the arrow image turned by a (counter-clockwise, radians)
    local function Turn(tex, a)
        local c, s = math.cos(a), math.sin(a)
        local function corner(x, y)
            local tx, ty = x * c + y * s, -x * s + y * c
            return 0.5 + tx, 0.5 - ty
        end
        local ulx, uly = corner(-0.5, 0.5)
        local llx, lly = corner(-0.5, -0.5)
        local urx, ury = corner(0.5, 0.5)
        local lrx, lry = corner(0.5, -0.5)
        tex:SetTexCoord(ulx, uly, llx, lly, urx, ury, lrx, lry)
    end
    WT.TurnTexture = Turn

    local function Refresh()
        if not active then return end
        local k = KINDS[active.kind] or KINDS[0]
        icon:SetTexture(k[3])
        title:SetText((active.cursed and "Cursed " or "") .. k[1])
        title:SetTextColor(k[2][1], k[2][2], k[2][3])
        zoneText:SetText(string.format("%s  |cffffffff%d, %d|r", active.zone or "?", math.floor((active.x or 0) + 0.5), math.floor((active.y or 0) + 0.5)))
        local y = active.yards
        if not y then
            hint:SetText("")
            yards:SetText("")
            arrow:Hide()
        elseif y < 0 then
            hint:SetText("On another continent.")
            yards:SetText("")
            arrow:Hide()
        elseif y <= DIG_RANGE then
            hint:SetText("|cff20ff20You're there: use the map to dig!|r")
            yards:SetText("|cff20ff20here|r")
            arrow:Hide()
        else
            hint:SetText("Follow the arrow.")
            yards:SetText(y >= 1000 and string.format("%.1fk yd", y / 1000) or (y .. " yd"))
            arrow:Show()
        end
    end

    f:SetScript("OnUpdate", function()
        if active and active.angle and arrow:IsShown() and GetPlayerFacing then
            Turn(arrow, active.angle - (GetPlayerFacing() or 0))
        end
    end)

    -- ---------------- the world map pin ----------------
    local pin
    local function PlacePin()
        if not WorldMapButton then return end
        if not pin then
            pin = CreateFrame("Frame", nil, WorldMapButton)
            Size(pin, 22, 22)
            pin:SetFrameLevel(WorldMapButton:GetFrameLevel() + 10)
            pin.tex = pin:CreateTexture(nil, "OVERLAY")
            pin.tex:SetAllPoints()
            pin:EnableMouse(true)
            pin:SetScript("OnEnter", function(self)
                if not active then return end
                WorldMapTooltip:SetOwner(self, "ANCHOR_RIGHT")
                WorldMapTooltip:AddLine((active.cursed and "Cursed " or "") .. (KINDS[active.kind] or KINDS[0])[1], 1, 0.82, 0)
                WorldMapTooltip:AddLine("The spot your treasure map marks.", 1, 1, 1)
                WorldMapTooltip:Show()
            end)
            pin:SetScript("OnLeave", function() WorldMapTooltip:Hide() end)
        end
        pin:Hide()
        if not active or not active.zone then return end
        local cont, zone = GetCurrentMapContinent(), GetCurrentMapZone()
        if not cont or cont < 1 or not zone or zone < 1 then return end
        local name = select(zone, GetMapZones(cont))
        if name ~= active.zone then return end
        local w, h = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
        pin.tex:SetTexture((KINDS[active.kind] or KINDS[0])[3])
        pin:ClearAllPoints()
        pin:SetPoint("CENTER", WorldMapButton, "TOPLEFT", active.x / 100 * w, -active.y / 100 * h)
        pin:Show()
    end
    local mapEvents = CreateFrame("Frame")
    mapEvents:RegisterEvent("WORLD_MAP_UPDATE")
    mapEvents:SetScript("OnEvent", function() if WorldMapFrame and WorldMapFrame:IsShown() then PlacePin() end end)
    if WorldMapFrame then WorldMapFrame:HookScript("OnShow", PlacePin) end

    function WT.OnTreasureMessage(msg)
        local cmd = msg:match("^(T[MCX])|")
        if not cmd then return false end
        local p = Split(msg:sub(4), "|")
        if cmd == "TM" then
            active = { kind = tonumber(p[1]) or 0, cursed = p[2] == "1", zone = p[3], x = tonumber(p[4]) or 0, y = tonumber(p[5]) or 0 }
            f:Show()
            Refresh()
            PlacePin()
        elseif cmd == "TC" and active then
            active.yards = tonumber(p[1])
            local a = tonumber(p[2])
            active.angle = a and a / 1000 or nil
            Refresh()
        elseif cmd == "TX" then
            active = nil
            f:Hide()
            if pin then pin:Hide() end
        end
        return true
    end
end

-- ---------------------------------------------------------------------------
-- The World Tiers window: tier, Paragon, gear, Tier Key and the Signature
-- Keystone in one place (the menu spell and the Keeper open it)
-- ---------------------------------------------------------------------------

do
    local HF_TIERS, HF_PARAGON, HF_GEAR, HF_KEY, HF_KEYPORT, HF_TRANSMOG, HF_POUCH, HF_SIGNATURE, HF_PARAGON_LIVE =
        1, 2, 4, 8, 16, 32, 64, 128, 256
    local hub = { h = {}, key = {}, ports = {}, reforge = { 0, "" }, sig = { slot = 10, ks = 0 }, options = {}, building = false,
        vault = { rows = {}, offers = {}, left = 0 }, events = {} }
    local function Flag(bit) return math.floor((hub.h.flags or 0) / bit) % 2 == 1 end

    local W, H = 820, 590
    local win = CreateFrame("Frame", "WorldTiersHubFrame", UIParent)
    Size(win, W, H)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:EnableMouse(true)
    win:SetMovable(true)
    win:SetClampedToScreen(true)
    win:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    win:Hide()
    tinsert(UISpecialFrames, "WorldTiersHubFrame")

    local drag = CreateFrame("Frame", nil, win)
    drag:SetPoint("TOPLEFT", 12, -8)
    drag:SetPoint("TOPRIGHT", -40, -8)
    drag:SetHeight(44)
    drag:EnableMouse(true)
    drag:RegisterForDrag("LeftButton")
    drag:SetScript("OnDragStart", function() win:StartMoving() end)
    drag:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)

    local crest = win:CreateTexture(nil, "ARTWORK")
    Size(crest, 40, 40)
    crest:SetPoint("TOPLEFT", 24, -18)
    crest:SetTexture("Interface\\Icons\\Spell_Holy_EmpowerChampion")
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
    title:SetPoint("TOPLEFT", crest, "TOPRIGHT", 10, -2)
    title:SetText("World Tiers")
    local subtitle = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    local closeB = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    closeB:SetPoint("TOPRIGHT", -6, -6)

    local function Button(parent, w, h, text)
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        Size(b, w, h)
        b:SetText(text)
        return b
    end

    local function Tip(owner, title, text, r, g, b)
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0)
        if text and text ~= "" then GameTooltip:AddLine(text, r or 1, g or 1, b or 1, true) end
        GameTooltip:Show()
    end
    local function TipOn(widget, fn)
        widget:SetScript("OnEnter", function(self) local t, x = fn() if t then Tip(self, t, x) end end)
        widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    -- the pages: Overview, Weekly Vault, Events (tabs at the top right)
    local overview = CreateFrame("Frame", nil, win)
    overview:SetAllPoints()
    hub.pages = { overview = overview }

    -- a section: a dark inset with a gold header and a rule under it
    local function Section(x, y, w, h, header, parent)
        local s = CreateFrame("Frame", nil, parent or overview)
        s:SetPoint("TOPLEFT", x, y)
        Size(s, w, h)
        s:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 14,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        s:SetBackdropColor(0.04, 0.04, 0.06, 0.85)
        s:SetBackdropBorderColor(0.55, 0.45, 0.25, 0.9)
        s.header = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        s.header:SetPoint("TOPLEFT", 12, -10)
        s.header:SetText(header)
        local rule = s:CreateTexture(nil, "ARTWORK")
        rule:SetTexture(0.75, 0.6, 0.3, 0.35)
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", 10, -28)
        rule:SetPoint("TOPRIGHT", -10, -28)
        s.note = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        s.note:SetPoint("TOPRIGHT", -12, -12)
        return s
    end

    local function Text(parent, font, x, y, w)
        local t = parent:CreateFontString(nil, "OVERLAY", font)
        t:SetPoint("TOPLEFT", x, y)
        if w then t:SetWidth(w) end
        t:SetJustifyH("LEFT")
        return t
    end

    -- ======================= World Tier =======================
    local tierS = Section(20, -72, 390, 250, "World Tier")
    local tierName = Text(tierS, "GameFontNormalHuge", 14, -38, 362)
    tierName:SetTextColor(1, 0.6, 0.2)
    local tierNow = Text(tierS, "GameFontHighlightSmall", 14, -68, 362)
    local tierMax = Text(tierS, "GameFontHighlightSmall", 14, -84, 362)

    local bar = CreateFrame("StatusBar", nil, tierS)
    bar:SetPoint("TOPLEFT", 14, -108)
    Size(bar, 362, 16)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.85, 0.45, 0.1)
    bar:SetMinMaxValues(0, 1)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetTexture(0, 0, 0, 0.6)
    local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    barText:SetPoint("CENTER", 0, 0)
    TipOn(bar, function() return "Unlocking the next tier",
        "Defeat dungeon or raid bosses at your highest unlocked tier. A kill counts at the lowest tier that did enough of the damage." end)

    local tierNext = Text(tierS, "GameFontHighlightSmall", 14, -132, 362)
    tierNext:SetTextColor(0.75, 0.75, 0.75)

    local lowerB = Button(tierS, 86, 24, "Lower")
    lowerB:SetPoint("TOPLEFT", 14, -164)
    local raiseB = Button(tierS, 86, 24, "Raise")
    raiseB:SetPoint("LEFT", lowerB, "RIGHT", 6, 0)
    local maxB = Button(tierS, 86, 24, "Highest")
    maxB:SetPoint("LEFT", raiseB, "RIGHT", 6, 0)
    local normalB = Button(tierS, 86, 24, "Normal")
    normalB:SetPoint("LEFT", maxB, "RIGHT", 6, 0)
    TipOn(normalB, function() return "World Tier 0 (Normal)", "The game as it was made: no syncing, no tier gear." end)

    local goLabel = Text(tierS, "GameFontNormalSmall", 14, -206)
    goLabel:SetText("Go to tier:")
    local goBox = CreateFrame("EditBox", "WorldTiersHubTierBox", tierS, "InputBoxTemplate")
    Size(goBox, 70, 20)
    goBox:SetPoint("LEFT", goLabel, "RIGHT", 12, 0)
    goBox:SetAutoFocus(false)
    goBox:SetNumeric(true)
    goBox:SetMaxLetters(7)
    local goB = Button(tierS, 60, 22, "Go")
    goB:SetPoint("LEFT", goBox, "RIGHT", 8, 0)
    local function GoTier()
        local n = tonumber(goBox:GetText() or "")
        goBox:ClearFocus()
        if n then Send("WT:" .. n) end
    end
    goB:SetScript("OnClick", GoTier)
    goBox:SetScript("OnEnterPressed", GoTier)
    goBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    lowerB:SetScript("OnClick", function() Send("WT:" .. math.max(0, (hub.h.tier or 0) - 1)) end)
    raiseB:SetScript("OnClick", function() Send("WT:" .. ((hub.h.tier or 0) + 1)) end)
    maxB:SetScript("OnClick", function() Send("WT:" .. (hub.h.maxTier or 0)) end)
    normalB:SetScript("OnClick", function() Send("WT:0") end)

    -- ======================= Tier Key =======================
    local keyS = Section(20, -330, 390, 200, "Tier Key")
    local keyIcon = keyS:CreateTexture(nil, "ARTWORK")
    Size(keyIcon, 36, 36)
    keyIcon:SetPoint("TOPLEFT", 14, -38)
    keyIcon:SetTexture("Interface\\Icons\\INV_Misc_Key_13")
    local keyName = Text(keyS, "GameFontHighlight", 58, -38, 318)
    local keyBest = Text(keyS, "GameFontHighlightSmall", 58, -56, 318)
    keyBest:SetTextColor(0.75, 0.75, 0.75)
    local activateB = Button(keyS, 160, 24, "Activate Key")
    activateB:SetPoint("TOPLEFT", 14, -84)
    activateB:SetScript("OnClick", function() StaticPopup_Show("WORLDTIERS_HUB_KEY", hub.key.text or "your key") end)
    TipOn(activateB, function()
        if hub.key.can then return "Start the clock", "Finish in time to upgrade your key." end
        return "Not here", hub.key.why
    end)
    local portHeader = Text(keyS, "GameFontNormalSmall", 14, -118)
    portHeader:SetText("Teleport into a key's dungeon")
    local portButtons = {}
    for i = 1, 3 do
        local b = Button(keyS, 362, 20, "")
        b:SetPoint("TOPLEFT", 14, -134 - (i - 1) * 22)
        local fs = b:GetFontString()
        if fs then fs:SetJustifyH("LEFT") end
        b:SetScript("OnClick", function(self) if self.map then Send("WG:" .. self.map) end end)
        portButtons[i] = b
    end
    local portNone = Text(keyS, "GameFontDisableSmall", 14, -136, 362)

    StaticPopupDialogs["WORLDTIERS_HUB_KEY"] = {
        text = "Start the clock on %s?", button1 = ACCEPT or "Accept", button2 = CANCEL,
        OnAccept = function() Send("WK") end, timeout = 0, whileDead = 1, hideOnEscape = 1,
    }

    -- ======================= Character (tiles) =======================
    local tileS = Section(418, -72, 382, 250, "Your Character")
    local tiles = {}
    local function Tile(i, icon, name, onClick)
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local t = CreateFrame("Button", nil, tileS)
        Size(t, 175, 62)
        t:SetPoint("TOPLEFT", 12 + col * 183, -36 - row * 68)
        t:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 12,
            insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        t:SetBackdropColor(0.12, 0.1, 0.08, 0.9)
        t:SetBackdropBorderColor(0.45, 0.4, 0.3, 0.9)
        t.icon = t:CreateTexture(nil, "ARTWORK")
        Size(t.icon, 40, 40)
        t.icon:SetPoint("LEFT", 10, 0)
        t.icon:SetTexture("Interface\\Icons\\" .. icon)
        t.name = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t.name:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 8, -2)
        t.name:SetWidth(112)
        t.name:SetJustifyH("LEFT")
        t.name:SetText(name)
        t.sub = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t.sub:SetPoint("TOPLEFT", t.name, "BOTTOMLEFT", 0, -3)
        t.sub:SetWidth(112)
        t.sub:SetJustifyH("LEFT")
        local hl = t:CreateTexture(nil, "HIGHLIGHT")
        hl:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
        hl:SetBlendMode("ADD")
        hl:SetPoint("TOPLEFT", 4, -4)
        hl:SetPoint("BOTTOMRIGHT", -4, 4)
        hl:SetVertexColor(1, 0.8, 0.4, 0.35)
        t:SetScript("OnClick", function(self) if self.enabled then PlaySound("igMainMenuOptionCheckBoxOn") onClick() end end)
        t.SetOn = function(self, on)
            self.enabled = on
            self.icon:SetDesaturated(not on)
            self:SetAlpha(on and 1 or 0.45)
        end
        tiles[i] = t
        return t
    end
    local paragonT = Tile(1, "Spell_Holy_EmpowerChampion", "Paragon Board", function() win:Hide() frame:Show() end)
    local forgeT = Tile(2, "Trade_BlackSmithing", "The Forge", function() win:Hide() Send("WF") end)
    local transmogT = Tile(3, "INV_Arcane_Orb", "Transmogrify", function() win:Hide() Send("WX") end)
    local pouchT = Tile(4, "INV_Misc_Bag_10", "Materials Pouch", function() win:Hide() Send("WM") end)
    local reforgeT = Tile(5, "INV_Hammer_20", "Quick Reforge", function()
        StaticPopup_Show("WORLDTIERS_HUB_REFORGE", tostring(hub.reforge[1]), hub.reforge[2])
    end)
    local reportT = Tile(6, "INV_Misc_Note_01", "Gear Report", function() Send("WI") end)
    transmogT.sub:SetText("Free, account-wide looks")
    pouchT.sub:SetText("Every crafting material")
    forgeT.sub:SetText("Reforge, reroll affixes")
    reportT.sub:SetText("Item levels, in chat")
    TipOn(paragonT, function() return "Paragon Board", "Spend Paragon points on stats and keystones. Also /paragon." end)
    TipOn(reforgeT, function()
        if hub.reforge[1] > 0 then return "Quick Reforge", "Bring every piece you wear up to your current tier, paying Essence from bosses at that tier as well as gold." end
        return "Quick Reforge", "Everything you wear is already at your tier, or as high as it can go."
    end)

    StaticPopupDialogs["WORLDTIERS_HUB_REFORGE"] = {
        text = "Reforge %s equipped pieces to your tier for %s, plus Essence?", button1 = ACCEPT or "Accept", button2 = CANCEL,
        OnAccept = function() Send("WR") end, timeout = 0, whileDead = 1, hideOnEscape = 1,
    }

    -- ======================= Signature Keystone =======================
    -- (the left half; the Ascendancy beside it, built in BuildAscendancy)
    local sigS = Section(418, -330, 188, 200, "Signature Keystone")
    local sigFrame = CreateFrame("Button", nil, sigS)
    Size(sigFrame, 40, 40)
    sigFrame:SetPoint("TOPLEFT", 12, -38)
    local sigIcon = sigFrame:CreateTexture(nil, "ARTWORK")
    sigIcon:SetAllPoints()
    local sigBorder = sigFrame:CreateTexture(nil, "OVERLAY")
    sigBorder:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    sigBorder:SetBlendMode("ADD")
    sigBorder:SetVertexColor(0.75, 0.5, 1)
    Size(sigBorder, 72, 72)
    sigBorder:SetPoint("CENTER")
    local sigName = Text(sigS, "GameFontNormal", 58, -40, 120)
    sigName:SetTextColor(0.75, 0.5, 1)
    local sigText = Text(sigS, "GameFontHighlightSmall", 12, -84, 164)
    sigText:SetHeight(72)
    sigText:SetJustifyV("TOP")
    local chooseB = Button(sigS, 100, 22, "Choose...")
    chooseB:SetPoint("BOTTOMLEFT", 12, 12)
    TipOn(chooseB, function() return "Signature Keystone", "Always on, at any level. Uses no board slot. Free to change out of combat." end)

    -- the chooser: every class keystone, the locked ones greyed with their level
    local picker = CreateFrame("Frame", "WorldTiersSignaturePicker", win)
    picker:SetPoint("TOPLEFT", win, "TOPRIGHT", -6, -60)
    Size(picker, 300, 12 * 34 + 74)
    picker:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 8, right = 8, top = 8, bottom = 8 },
    })
    picker:EnableMouse(true)
    picker:Hide()
    local pickTitle = picker:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pickTitle:SetPoint("TOP", 0, -16)
    pickTitle:SetText("Choose a Signature Keystone")
    local pickClose = CreateFrame("Button", nil, picker, "UIPanelCloseButton")
    pickClose:SetPoint("TOPRIGHT", -2, -2)
    local pickRows = {}
    for i = 1, 12 do
        local r = CreateFrame("Button", nil, picker)
        Size(r, 268, 32)
        r:SetPoint("TOPLEFT", 16, -38 - (i - 1) * 34)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        Size(r.icon, 28, 28)
        r.icon:SetPoint("LEFT", 2, 0)
        r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        r.name:SetPoint("LEFT", r.icon, "RIGHT", 8, 0)
        r.name:SetWidth(170)
        r.name:SetJustifyH("LEFT")
        r.level = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        r.level:SetPoint("RIGHT", -6, 0)
        r.sel = r:CreateTexture(nil, "BACKGROUND")
        r.sel:SetAllPoints()
        r.sel:SetTexture(0.6, 0.35, 0.9, 0.3)
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
        hl:SetBlendMode("ADD")
        r:SetScript("OnClick", function(self)
            if self.ks and self.open then
                Send("WS:" .. self.ks)
                picker:Hide()
            end
        end)
        r:SetScript("OnEnter", function(self)
            local o = self.option
            if not o then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(o.name, 0.75, 0.5, 1)
            GameTooltip:AddLine(o.text, 1, 1, 1, true)
            if not self.open then GameTooltip:AddLine("Available from level " .. o.level .. ".", 1, 0.3, 0.3, true) end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pickRows[i] = r
    end
    local clearB = Button(picker, 120, 22, "Clear")
    clearB:SetPoint("BOTTOM", 0, 14)
    clearB:SetScript("OnClick", function() Send("WS:0") picker:Hide() end)

    local function RefreshPicker()
        local lvl = hub.h.level or UnitLevel("player")
        for i, r in ipairs(pickRows) do
            local o = hub.options[i]
            r.option = o
            if o then
                r.ks, r.open = o.ks, lvl >= o.level and lvl >= hub.sig.slot
                r.icon:SetTexture("Interface\\Icons\\" .. o.icon)
                r.icon:SetDesaturated(not r.open)
                r.name:SetText(o.name)
                if r.open then r.name:SetTextColor(1, 1, 1) else r.name:SetTextColor(0.5, 0.5, 0.5) end
                r.level:SetText(r.open and "" or ("Level " .. o.level))
                if o.ks == hub.sig.ks then r.sel:Show() else r.sel:Hide() end
                r:Show()
            else
                r:Hide()
            end
        end
        if hub.sig.ks > 0 then clearB:Enable() else clearB:Disable() end
    end
    chooseB:SetScript("OnClick", function()
        if picker:IsShown() then picker:Hide() else RefreshPicker() picker:Show() end
    end)
    TipOn(sigFrame, function()
        for _, o in ipairs(hub.options) do if o.ks == hub.sig.ks then return o.name, o.text end end
        return "No Signature Keystone", "Choose one of your class keystones."
    end)

    -- ======================= Experience rate (0.33) =======================
    -- levelling only: from Off up to the server's own rate; Paragon is never touched
    local function BuildXpRate()
        local b = Button(tierS, 126, 22, "Experience")
        b:SetPoint("TOPRIGHT", tierS, "TOPRIGHT", -14, -201)
        local pop = CreateFrame("Frame", "WorldTiersXpRateFrame", win)
        Size(pop, 300, 120)
        pop:SetPoint("TOPLEFT", b, "BOTTOMLEFT", -170, -4)
        pop:SetFrameStrata("DIALOG")
        pop:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                          tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        pop:EnableMouse(true)
        pop:Hide()
        local title = Text(pop, "GameFontNormal", 14, -12, 272)
        title:SetText("Levelling Experience")
        local slider = CreateFrame("Slider", "WorldTiersXpRateSlider", pop, "OptionsSliderTemplate")
        Size(slider, 260, 16)
        slider:SetPoint("TOP", 0, -42)
        slider:SetValueStep(1)
        local low, high = _G["WorldTiersXpRateSliderLow"], _G["WorldTiersXpRateSliderHigh"]
        local value = _G["WorldTiersXpRateSliderText"]
        local note = Text(pop, "GameFontDisableSmall", 14, -72, 272)
        note:SetText("Levels 1-80 only. Paragon is never affected. World Tier and event bonuses still add on top.")
        local setB = Button(pop, 80, 22, "Set")
        setB:SetPoint("BOTTOMRIGHT", -12, 10)
        local function Label(v, max)
            if v <= 0 then return "Off (no experience)" end
            if v >= max then return string.format("%dx (the server's rate)", v) end
            return string.format("%dx%s", v, v == 1 and " (as the game was made)" or "")
        end
        slider:SetScript("OnValueChanged", function(self, v)
            v = math.floor(v + 0.5)
            if value then value:SetText(Label(v, hub.xp.max)) end
        end)
        setB:SetScript("OnClick", function()
            Send("WL:" .. math.floor(slider:GetValue() + 0.5))
            pop:Hide()
        end)
        b:SetScript("OnClick", function()
            if pop:IsShown() then pop:Hide() return end
            slider:SetMinMaxValues(0, hub.xp.max)
            if low then low:SetText("Off") end
            if high then high:SetText(hub.xp.max .. "x") end
            slider:SetValue(hub.xp.cur)
            if value then value:SetText(Label(hub.xp.cur, hub.xp.max)) end
            pop:Show()
        end)
        TipOn(b, function()
            return "Experience rate", string.format("How fast you level: from Off up to the server's %dx. Kills, quests and exploration. "
                .. "Paragon experience is never affected. Also /wtxp <rate>.", hub.xp.max)
        end)
        local function Refresh()
            local x = hub.xp
            if not x.on then b:Hide() return end
            b:Show()
            b:SetText(x.cur <= 0 and "Experience: Off" or string.format("Experience: %dx", x.cur))
            if x.atCap then b:Disable() else b:Enable() end
        end
        return Refresh
    end
    hub.xp = { cur = 10, max = 10, on = false, atCap = false }
    local RefreshXpRate = BuildXpRate()

    -- ======================= Ascendancy =======================
    -- (the right half beside the Signature Keystone; the four to choose from
    -- are in the Ascendancy window, ascend.lua)
    local function BuildAscendancy()
        local s = Section(612, -330, 188, 200, "Ascendancy")
        local iconB = CreateFrame("Button", nil, s)
        Size(iconB, 40, 40)
        iconB:SetPoint("TOPLEFT", 12, -38)
        local icon = iconB:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        local border = iconB:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        border:SetBlendMode("ADD")
        border:SetVertexColor(1, 0.5, 0)
        Size(border, 72, 72)
        border:SetPoint("CENTER")
        local name = Text(s, "GameFontNormal", 58, -40, 120)
        name:SetTextColor(1, 0.5, 0)
        local text = Text(s, "GameFontHighlightSmall", 12, -84, 164)
        text:SetHeight(72)
        text:SetJustifyV("TOP")
        local b = Button(s, 100, 22, "Choose...")
        b:SetPoint("BOTTOMLEFT", 12, 12)
        b:SetScript("OnClick", function() if WT.OpenAscendancy then WT.OpenAscendancy() end end)
        iconB:SetScript("OnClick", function() if WT.OpenAscendancy then WT.OpenAscendancy() end end)
        local function Mine()
            if not WT.AscInfo then return nil end
            local list, chosen, need, level, mastery = WT.AscInfo()
            return list[chosen], need, level, mastery and mastery[chosen]
        end
        TipOn(iconB, function()
            local a, need = Mine()
            if a then return a.name, a.text end
            return "Ascendancy", string.format("From level %d: one of four powers for your class, on top of everything else you build.", need or 80)
        end)
        TipOn(b, function() return "Ascendancy", "Choose one of four, or change it, and its Mastery: free, any time out of combat. Also /ascend." end)
        local function Refresh()
            if not WT.AscInfo then return end
            local a, need, level, m = Mine()
            need, level = need or 80, level or UnitLevel("player")
            if level < need then
                icon:SetTexture("Interface\\Icons\\INV_Misc_Key_03")
                icon:SetDesaturated(true)
                name:SetText("Opens at level " .. need)
                text:SetText("One of four powers for your class, on top of everything else you build.")
                b:SetText("Preview...")
                border:Hide()
            elseif a then
                icon:SetTexture("Interface\\Icons\\" .. (a.icon or "INV_Misc_QuestionMark"))
                icon:SetDesaturated(false)
                name:SetText(a.name)
                -- its first sentence here, all of it on the icon's tooltip
                local first = (a.text or ""):match("^(.-[%.!])%s") or a.text or ""
                text:SetText((m and m.rank > 0 and string.format("|cffffd100Mastery %d/5.|r ", m.rank) or "") .. first)
                b:SetText("Change...")
                border:Show()
            else
                icon:SetTexture("Interface\\Icons\\Spell_Holy_AuraMastery")
                icon:SetDesaturated(false)
                name:SetText("Choose an Ascendancy")
                text:SetText("One of four powers for your class, on top of everything else you build. Free to change out of combat.")
                b:SetText("Choose...")
                border:Hide()
            end
        end
        WT.RefreshHubAscendancy = function() if win:IsShown() then Refresh() end end
        return Refresh
    end
    local RefreshAscendancy = BuildAscendancy()

    -- ======================= Footer =======================
    local helpB = Button(overview, 140, 24, "How It Works")
    helpB:SetPoint("BOTTOMLEFT", 24, 22)
    helpB:SetScript("OnClick", function() Send("WQ") end)
    local respecB = Button(overview, 220, 24, "Reset Paragon Board")
    respecB:SetPoint("BOTTOMRIGHT", -24, 22)
    respecB:SetScript("OnClick", function()
        local g = hub.h.respecGold or 0
        StaticPopup_Show("WORLDTIERS_HUB_RESPEC", g > 0 and (" for " .. g .. " gold") or "")
    end)
    StaticPopupDialogs["WORLDTIERS_HUB_RESPEC"] = {
        text = "Free every Paragon point to spend again%s?", button1 = ACCEPT or "Accept", button2 = CANCEL,
        OnAccept = function() Send("WB") end, timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    -- one switch for every always-on keystone (auras, forms, companions)
    local auraB = Button(overview, 230, 24, "Keystone Auras: On")
    auraB:SetPoint("BOTTOM", 0, 22)
    auraB:SetScript("OnClick", function() Send("WA") end)
    TipOn(auraB, function()
        return "Keystone Auras", "Turns every always-on keystone off or on at once: auras like Living Consecration, permanent forms, "
            .. "and companions. They also step aside by themselves while you ride. Also /wtaura."
    end)


    -- ======================= Weekly Vault and Events =======================
    -- (built in a function of their own: the window already has many locals)
    local function BuildPages()
        local function Bar(parent, w, h)
            local bar = CreateFrame("StatusBar", nil, parent)
            Size(bar, w, h)
            bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
            bar:SetMinMaxValues(0, 1)
            local bg = bar:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture(0, 0, 0, 0.6)
            bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            bar.text:SetPoint("CENTER", 0, 0)
            return bar
        end
        local function Text(parent, font, x, y, w)
            local t = parent:CreateFontString(nil, "OVERLAY", font)
            t:SetPoint("TOPLEFT", x, y)
            if w then t:SetWidth(w) end
            t:SetJustifyH("LEFT")
            return t
        end

        -- ---------------- Weekly Vault ----------------
        local vault = CreateFrame("Frame", nil, win)
        vault:SetAllPoints()
        vault:Hide()
        hub.pages.vault = vault
        local rowsS = Section(20, -72, 780, 300, "Weekly Vault: this week", vault)
        local ROW_TEXT = {
            [0] = "Finish Tier Keys, any level. Rewards: gear at your tier plus your best key's level.",
            [1] = "Kill dungeon or raid bosses at World Tier I or higher. Rewards: gear at your best tier.",
            [2] = "Gain levels: character or Paragon. Rewards: Essence (or gold before your first tier).",
        }
        local ROW_ICON = { [0] = "INV_Misc_Key_13", [1] = "Achievement_Boss_KingYmiron_01", [2] = "Spell_Holy_EmpowerChampion" }
        local rows = {}
        for r = 0, 2 do
            local y = -40 - r * 84
            local icon = rowsS:CreateTexture(nil, "ARTWORK")
            Size(icon, 36, 36)
            icon:SetPoint("TOPLEFT", 14, y)
            icon:SetTexture("Interface\\Icons\\" .. ROW_ICON[r])
            local name = Text(rowsS, "GameFontNormal", 58, y, 260)
            local desc = Text(rowsS, "GameFontHighlightSmall", 58, y - 18, 330)
            desc:SetText(ROW_TEXT[r])
            local bar = Bar(rowsS, 300, 16)
            bar:SetPoint("TOPLEFT", 58, y - 50)
            bar:SetStatusBarColor(0.64, 0.21, 0.93)
            local slots = {}
            for k = 1, 3 do
                local slot = CreateFrame("Frame", nil, rowsS)
                Size(slot, 46, 46)
                slot:SetPoint("TOPLEFT", 420 + (k - 1) * 112, y + 4)
                slot.icon = slot:CreateTexture(nil, "ARTWORK")
                slot.icon:SetAllPoints()
                slot.icon:SetTexture("Interface\\Icons\\INV_Box_04")
                slot.label = slot:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                slot.label:SetPoint("LEFT", slot, "RIGHT", 6, 0)
                slot.label:SetWidth(58)
                slot.label:SetJustifyH("LEFT")
                slots[k] = slot
            end
            rows[r] = { name = name, bar = bar, slots = slots }
        end
        local rewardS = Section(20, -380, 780, 152, "Weekly Vault: your reward", vault)
        local rewardNote = Text(rewardS, "GameFontHighlightSmall", 14, -40, 750)
        local offerButtons = {}
        for i = 1, 9 do
            local b = Button(rewardS, 244, 26, "")
            local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
            b:SetPoint("TOPLEFT", 14 + col * 252, -40 - row * 32)
            local fs = b:GetFontString()
            if fs then fs:SetWidth(230) end
            b:SetScript("OnClick", function(self)
                if self.index then StaticPopup_Show("WORLDTIERS_HUB_VAULT", self.offer or "this reward") end
                hub.pickIndex = self.index
            end)
            b:SetScript("OnEnter", function(self)
                if not self.offer then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:AddLine(self.offer, 1, 1, 1, true)
                GameTooltip:AddLine("You can take one reward: the others are gone.", 1, 0.5, 0.2, true)
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            offerButtons[i] = b
        end
        StaticPopupDialogs["WORLDTIERS_HUB_VAULT"] = {
            text = "Take %s?\n\nThe Vault gives one reward a week: the others are gone.", button1 = ACCEPT or "Accept", button2 = CANCEL,
            OnAccept = function() if hub.pickIndex then Send("WV:" .. hub.pickIndex) end end, timeout = 0, whileDead = 1, hideOnEscape = 1,
        }

        local function Duration(sec)
            sec = tonumber(sec) or 0
            local d, h, m = math.floor(sec / 86400), math.floor(sec / 3600) % 24, math.floor(sec / 60) % 60
            if d > 0 then return string.format("%dd %dh", d, h) end
            if h > 0 then return string.format("%dh %dm", h, m) end
            return string.format("%dm", m)
        end

        hub.RefreshVault = function()
            local v = hub.vault
            rowsS.note:SetText("Resets in " .. Duration(v.left))
            for r = 0, 2 do
                local row, data = rows[r], v.rows[r]
                if data then
                    local t = data.th
                    row.name:SetText(data.name .. (r == 0 and data.best > 0 and string.format("  |cff999999(best +%d)|r", data.best)
                        or r == 1 and data.best > 0 and string.format("  |cff999999(best Tier %d)|r", data.best) or ""))
                    row.bar:SetMinMaxValues(0, t[3])
                    row.bar:SetValue(math.min(data.count, t[3]))
                    row.bar.text:SetText(string.format("%d / %d", data.count, data.count < t[1] and t[1] or data.count < t[2] and t[2] or t[3]))
                    for k = 1, 3 do
                        local slot, open = row.slots[k], data.count >= t[k]
                        slot.icon:SetDesaturated(not open)
                        slot:SetAlpha(open and 1 or 0.45)
                        slot.label:SetText(open and "|cff66ff66Unlocked|r" or string.format("%d / %d", math.min(data.count, t[k]), t[k]))
                    end
                end
            end
            local any = #v.offers > 0
            for i, b in ipairs(offerButtons) do
                local o = v.offers[i]
                if o then
                    b.index, b.offer = o.index, o.text
                    b:SetText(o.text)
                    b:Show()
                else
                    b.index, b.offer = nil, nil
                    b:Hide()
                end
            end
            if any then
                rewardNote:SetText("")
                rewardS.header:SetText("Weekly Vault: choose one reward")
            else
                rewardS.header:SetText("Weekly Vault: your reward")
                rewardNote:SetText("Every slot you unlock this week becomes a reward to choose from after the weekly reset (in "
                    .. Duration(v.left) .. "). You take one of them. Unlock more slots for more to choose from.")
            end
        end

        -- ---------------- Events ----------------
        local events = CreateFrame("Frame", nil, win)
        events:SetAllPoints()
        events:Hide()
        hub.pages.events = events
        local zoneS = Section(20, -72, 390, 208, "Empowered Zone", events)
        local dungS = Section(418, -72, 382, 208, "Empowered Dungeon", events)
        local function EventBlock(s, icon)
            local b = {}
            b.icon = s:CreateTexture(nil, "ARTWORK")
            Size(b.icon, 44, 44)
            b.icon:SetPoint("TOPLEFT", 14, -40)
            b.icon:SetTexture("Interface\\Icons\\" .. icon)
            b.name = Text(s, "GameFontNormalLarge", 66, -42, s:GetWidth() - 80)
            b.name:SetTextColor(1, 0.82, 0)
            b.sub = Text(s, "GameFontHighlightSmall", 66, -64, s:GetWidth() - 80)
            b.effects = Text(s, "GameFontHighlightSmall", 14, -100, s:GetWidth() - 28)
            b.effects:SetTextColor(0.6, 1, 0.6)
            b.bar = Bar(s, s:GetWidth() - 28, 18)
            b.bar:SetPoint("TOPLEFT", 14, -150)
            b.bar:SetStatusBarColor(1, 0.6, 0.1)
            b.reward = Text(s, "GameFontHighlightSmall", 14, -176, s:GetWidth() - 28)
            b.reward:SetTextColor(0.85, 0.85, 0.85)
            return b
        end
        local zb = EventBlock(zoneS, "INV_Misc_Map_01")
        local db = EventBlock(dungS, "INV_Misc_Key_14")
        -- this week's modifier, in every dungeon and raid
        local weekS = Section(20, -288, 780, 138, "This week in dungeons and raids", events)
        local wk = {}
        wk.icon = weekS:CreateTexture(nil, "ARTWORK")
        Size(wk.icon, 44, 44)
        wk.icon:SetPoint("TOPLEFT", 14, -40)
        wk.name = Text(weekS, "GameFontNormalLarge", 66, -42, 690)
        wk.name:SetTextColor(1, 0.6, 0.2)
        wk.challenge = Text(weekS, "GameFontHighlightSmall", 66, -64, 690)
        wk.reward = Text(weekS, "GameFontHighlightSmall", 66, -82, 690)
        wk.reward:SetTextColor(0.6, 1, 0.6)
        wk.next = Text(weekS, "GameFontDisableSmall", 14, -112, 750)

        local aboutS = Section(20, -434, 780, 98, "How events work", events)
        local about = Text(aboutS, "GameFontHighlightSmall", 14, -40, 750)
        about:SetText("Every hour a new zone and a new dungeon are empowered for each band of ten levels: these are the ones for "
            .. "your level. Go there for faster levelling, more Champions and Treasure Goblins, extra boss loot, and a reward chest "
            .. "(gear, gold, and Essence from World Tier I). Each chest once an hour. Queue for the dungeon in the Dungeon Finder, "
            .. "or walk in.")

        hub.RefreshEvents = function()
            local e = hub.events
            local x = e.effects or {}
            local w = e.week
            if w and w.name ~= "" then
                wk.icon:SetTexture("Interface\\Icons\\" .. (w.icon or "INV_Misc_QuestionMark"))
                wk.icon:Show()
                wk.name:SetText(w.name)
                wk.challenge:SetText(w.challenge or "")
                wk.reward:SetText("Reward: " .. (w.reward or ""))
                weekS.note:SetText("Changes in " .. Duration(w.left or 0))
                wk.next:SetText(string.format("Next week: |T%s:14|t %s - %s %s", "Interface\\Icons\\" .. (w.nextIcon or "INV_Misc_QuestionMark"),
                    w.nextName or "?", w.nextChallenge or "", w.nextReward and ("(" .. w.nextReward .. ")") or ""))
            else
                wk.icon:Hide()
                wk.name:SetText("No weekly modifier on this realm")
                wk.challenge:SetText("")
                wk.reward:SetText("")
                wk.next:SetText("")
                weekS.note:SetText("")
            end
            if e.zone and e.zone ~= "" then
                zb.name:SetText(e.zone)
                zb.sub:SetText(string.format("For %s  -  %d min left this hour", e.band or "", e.minutes or 0))
                zb.effects:SetText(string.format("+%s%% experience (and Paragon experience)\n%sx Champions\n%sx Treasure Goblins",
                    x.xp or "50", x.champ or "3", x.goblin or "3"))
                zb.bar:SetMinMaxValues(0, math.max(1, e.goal or 1))
                zb.bar:SetValue(math.min(e.kills or 0, e.goal or 1))
                zb.bar.text:SetText(e.zoneDone and "Reward chest claimed this hour" or string.format("%d / %d kills", e.kills or 0, e.goal or 0))
                zb.reward:SetText(e.zoneDone and "Come back next hour for the next zone." or "Reward chest at the goal: gear, gold and Essence.")
                zb.bar:Show()
            else
                zb.name:SetText("No zone right now")
                zb.sub:SetText("")
                zb.effects:SetText("")
                zb.bar:Hide()
                zb.reward:SetText("")
            end
            if e.dungeon and e.dungeon ~= "" then
                db.name:SetText(e.dungeon)
                db.sub:SetText(string.format("For %s  -  %d min left this hour", e.band or "", e.minutes or 0))
                db.effects:SetText(string.format("+%s%% experience (and Paragon experience)\n+%s boss loot roll%s\nReward chest for clearing it",
                    x.xp or "50", x.rolls or "1", (tonumber(x.rolls) or 1) == 1 and "" or "s"))
                db.bar:SetMinMaxValues(0, 1)
                db.bar:SetValue(e.dungeonDone and 1 or 0)
                db.bar.text:SetText(e.dungeonDone and "Cleared: chest claimed this hour" or "Not cleared yet")
                db.reward:SetText(e.dungeonDone and "Come back next hour for the next dungeon." or "Clear it (its last boss) for the chest.")
                db.bar:Show()
            else
                db.name:SetText("No dungeon for your level yet")
                db.sub:SetText("Dungeons start around level 13.")
                db.effects:SetText("")
                db.bar:Hide()
                db.reward:SetText("")
            end
        end

        -- ---------------- Getting Started ----------------
        local G = "|cffffd100"
        local W = "|cffffffff"
        local E = "|r"
        local TOPICS = {
            { "Welcome", G .. "Welcome to IsDead WoW" .. E .. "\n\n"
                .. "This realm is built so one player can do everything: levelling, dungeons and raids, alone or with friends and bots, "
                .. "and keep getting stronger with no ceiling.\n\n"
                .. G .. "Where to start" .. E .. "\n"
                .. "- Level as usual. Every 10 levels you get a " .. W .. "Milestone Pack" .. E .. " (a bag), gold and rations in the mail.\n"
                .. "- You know " .. W .. "every profession" .. E .. " already, and can ride from level 1.\n"
                .. "- Once you are comfortable, pick a " .. W .. "World Tier" .. E .. " (Overview tab). Tier I is where the fun starts.\n"
                .. "- Choose a " .. W .. "Signature Keystone" .. E .. " from level 10 (Overview tab): a power that changes how your class plays.\n"
                .. "- Use the " .. W .. "Dungeon Finder" .. E .. " (the eye by your minimap, or I): solo queues go straight in, raids included.\n\n"
                .. "Every topic on the left explains one part. This tab is always here: /wtguide opens it." },
            { "World Tiers", G .. "World Tiers" .. E .. "\n\n"
                .. "Your World Tier is yours alone: a friend at another tier fights the same creature at theirs.\n\n"
                .. "- " .. W .. "Tier I and up:" .. E .. " everything below your level is raised to your level (open world, dungeons, raids), "
                .. "so old places stay worth your time and drop gear for your level.\n"
                .. "- Each tier above I makes creatures tougher for you, and pays you back: more experience, better gear "
                .. "(+15 item levels per tier), more gold.\n"
                .. "- " .. W .. "Unlocking the next tier:" .. E .. " defeat a few dungeon, raid or world bosses at your highest unlocked tier. "
                .. "The Overview tab shows your progress.\n"
                .. "- You can change tier any time out of combat, down as well as up.\n"
                .. "- Below level 80 you can reach Tier II; past that opens at the level cap." },
            { "Gear and the Forge", G .. "Gear, affixes and the Forge" .. E .. "\n\n"
                .. "- Gear is stamped with the tier it was earned at, and grows with it. Your tooltip shows the item level it counts as.\n"
                .. "- Dropped gear rolls " .. W .. "affixes" .. E .. ": extra lines that grow with its tier. Rare drops can carry a " .. W .. "class unique" .. E
                .. " that changes one of your spells (orange), or come out " .. W .. "Primal" .. E .. " (perfect affixes).\n"
                .. "- " .. W .. "Class sets" .. E .. " (green): three for each class, one for each talent tree. A rare-or-better Head, Shoulders, "
                .. "Chest, Hands, Legs or Feet can drop as a set piece; two pieces give the set's first bonus, four its second. "
                .. "Uniques and set pieces glow in your bags; the character window's Gear tab shows what you wear.\n"
                .. "- Legendaries and crafted rare-or-better gear keep pace with your level.\n"
                .. "- The " .. W .. "Forge" .. E .. " (/forge) reforges a piece up to your current tier and rerolls its affixes, all at once "
                .. "or one line at a time. It costs gold, Essence and Shards.\n"
                .. "- " .. W .. "Runes" .. E .. " drop from bosses at higher tiers: forge one into a piece for a special effect.\n"
                .. "- Wearing several pieces from the same affix family gives a set bonus.\n"
                .. "- The " .. W .. "Power Codex" .. E .. " (the Forge's second tab, or /codex): extract a class unique there (the piece is "
                .. "destroyed) to keep its power for your whole account, then imprint it onto any rare or better piece.\n"
                .. "- " .. W .. "Treasure Maps" .. E .. " drop from Champions, bosses, Tier Keys and Treasure Goblins. Use one to see "
                .. "where it leads (a compass points the way), and again at the spot to dig. Better maps have guardians and "
                .. "better chests; four Map Fragments make a Legendary Map." },
            { "Paragon and Keystones", G .. "Paragon and Keystones" .. E .. "\n\n"
                .. "- Experience past the level cap fills " .. W .. "Paragon levels" .. E .. ", without end. Each gives a point.\n"
                .. "- Spend points on the " .. W .. "Paragon Board" .. E .. " (/paragon): fourteen arms, one for every stat, your class's most useful first. Walk out from the centre; "
                .. "notables are big steps, and branches off them end in " .. W .. "keystones" .. E .. ".\n"
                .. "- Keystones change how you play. A few can be switched on at once; " .. W .. "class keystones" .. E
                .. " are built around your class's own spells.\n"
                .. "- Shift-click a node to take the whole path to it. Search finds any stat or keystone. Three loadouts save whole boards.\n"
                .. "- Your " .. W .. "Signature Keystone" .. E .. " (Overview tab, from level 10) is a class keystone that is always on, "
                .. "outside the board's slots, long before Paragon.\n"
                .. "- Keystones that strike by themselves run as auras: /wtaura (or the Overview button) switches them all on or off.\n"
                .. "- " .. W .. "Ascendancies" .. E .. " (from level 80, Overview tab beside your Signature Keystone, or /ascend): choose one of four "
                .. "for your class, each a big power of its own on top of any talents and keystones. Free to change out of combat.\n"
                .. "- " .. W .. "Glyphs" .. E .. ": each arm's second notable has a socket. A glyph boosts the matching nodes near it and "
                .. "has a bonus of its own. 72 to find, from Tier Keys and raid or world bosses (more often at higher tiers); "
                .. "they level up as you use them. The Glyphs button on the board shows your collection.\n"
                .. "- Capped stats never waste points: past their caps Crit adds critical damage, Haste shortens cooldowns, "
                .. "Leech turns overhealing into a shield, Avoidance into less damage taken, Movement into mounted speed." },
            { "Dungeons and Raids", G .. "Dungeons and Raids" .. E .. "\n\n"
                .. "- The " .. W .. "Dungeon Finder" .. E .. " works solo: queue, and you go straight in. Loot is yours, no rolls.\n"
                .. "- Dungeons and raids are " .. W .. "sized to who is inside" .. E .. ": alone they are made for one, and get harder "
                .. "with every player (bots count).\n"
                .. "- From Tier I, dungeons and raids you have " .. W .. "outlevelled" .. E .. " stay in the list, raised to your level.\n"
                .. "- " .. W .. "Raids" .. E .. " are in the Dungeon Finder too, under the dungeons: pick 10 or 25, normal or heroic. "
                .. "Teleport out and back in from the eye, like any dungeon.\n"
                .. "- Raids " .. W .. "never lock you out" .. E .. ". To start one fresh, right-click your portrait: Reset all instances.\n"
                .. "- Mechanics a few players can't do (orbs, tank swaps, marks) are taken out while your raid is short of its size.\n"
                .. "- Bosses drop extra loot. Press M inside any instance for its map (/atlas browses them all)." },
            { "Tier Keys", G .. "Tier Keys" .. E .. "\n\n"
                .. "- At level 80, finish a Wrath dungeon at Tier I or higher to earn a " .. W .. "Tier Key" .. E .. ": a dungeon, a level and modifiers.\n"
                .. "- Go there (the Overview tab can teleport you), start the key, and race a 30-minute clock. Beat it and the key goes up; "
                .. "the higher the key, the tougher the run and the better the reward.\n"
                .. "- Keys you finish count towards your Weekly Vault." },
            { "Vault and Events", G .. "Weekly Vault" .. E .. "\n\n"
                .. "- Three rows fill during the week: " .. W .. "Tier Keys" .. E .. " finished, " .. W .. "bosses" .. E .. " killed at Tier I or higher, "
                .. "and " .. W .. "levels" .. E .. " gained (character or Paragon).\n"
                .. "- Each threshold opens a reward slot. At the weekly reset you choose one reward from the slots you opened.\n\n"
                .. G .. "Events" .. E .. "\n\n"
                .. "- Every hour, one zone and one dungeon for your level range are " .. W .. "empowered" .. E .. ": more experience, more "
                .. "Champions and Treasure Goblins, an extra boss loot roll, and a reward chest for a kill goal or a clear.\n"
                .. "- The Events tab shows yours and the minutes left.\n"
                .. "- Every week one " .. W .. "modifier" .. E .. " is on in all dungeons and raids: a challenge with a reward "
                .. "(Events tab, and said in chat as you go in)." },
            { "Champions and Goblins", G .. "Champions and Treasure Goblins" .. E .. "\n\n"
                .. "- " .. W .. "Champions" .. E .. " are bigger, stronger creatures with an affix (hover over one to see it). "
                .. "They hit harder and drop gear for your level.\n"
                .. "- " .. W .. "Treasure Goblins" .. E .. " appear at Tier I and up. Hit one and it runs: kill it within 15 seconds for gold, "
                .. "Shards, runes and gear, or it escapes." },
            { "Handy Tools", G .. "Handy tools" .. E .. " (in the General tab of your spellbook)\n\n"
                .. "- " .. W .. "World Tiers" .. E .. ": this window, anywhere.\n"
                .. "- " .. W .. "Materials Pouch" .. E .. " (/pouch): every crafting material for your whole account, no limit, no bag space. "
                .. "Crafting takes what it needs from it.\n"
                .. "- " .. W .. "Auto-Sell" .. E .. " (/autosell): choose what sells itself the moment you loot it. Sold items stay in buyback.\n"
                .. "- " .. W .. "Transmogrify" .. E .. " (/transmog): wear any look you have collected, for free.\n"
                .. "- The loot window shows everything at once, with Loot All.\n"
                .. "- " .. W .. "Gold has no cap" .. E .. ": past 200,000 the rest waits in your Gold Reserve and tops your wallet up." },
            { "Commands", G .. "Commands" .. E .. "\n\n"
                .. W .. "/worldtiers" .. E .. "  this window\n"
                .. W .. "/wtguide" .. E .. "  this guide\n"
                .. W .. "/paragon" .. E .. "  the Paragon Board\n"
                .. W .. "/forge" .. E .. "  the Forge\n"
                .. W .. "/pouch" .. E .. "  the Materials Pouch\n"
                .. W .. "/autosell" .. E .. "  Auto-Sell\n"
                .. W .. "/transmog" .. E .. "  Transmogrify\n"
                .. W .. "/wtaura" .. E .. "  keystone auras on / off\n"
                .. W .. "/atlas" .. E .. "  every instance map\n\n"
                .. W .. ".tier" .. E .. "  your tier and progress     " .. W .. ".tier gear" .. E .. "  what your gear counts as\n"
                .. W .. ".tier gold" .. E .. "  wallet and Gold Reserve     " .. W .. ".paragon" .. E .. "  your Paragon level and points" },
        }
        local guide = CreateFrame("Frame", nil, win)
        guide:SetAllPoints()
        guide:Hide()
        hub.pages.guide = guide
        local listS = Section(20, -72, 190, 496, "Topics", guide)
        local textS = Section(218, -72, 582, 496, "", guide)
        local scroll = CreateFrame("ScrollFrame", "WorldTiersGuideScroll", textS, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 14, -12)
        scroll:SetPoint("BOTTOMRIGHT", -32, 12)
        local body = CreateFrame("Frame", nil, scroll)
        Size(body, 530, 400)
        scroll:SetScrollChild(body)
        local text = body:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOPLEFT", 0, 0)
        text:SetWidth(530)
        text:SetJustifyH("LEFT")
        text:SetJustifyV("TOP")
        text:SetSpacing(3)
        local topicButtons = {}
        local function ShowTopic(i)
            text:SetText(TOPICS[i][2])
            body:SetHeight(math.max(400, (text:GetStringHeight() or 400) + 10))
            scroll:SetVerticalScroll(0)
            for j, b in ipairs(topicButtons) do if j == i then b:LockHighlight() else b:UnlockHighlight() end end
            hub.guideTopic = i
        end
        for i, t in ipairs(TOPICS) do
            local b = Button(listS, 166, 24, t[1])
            b:SetPoint("TOPLEFT", 12, -36 - (i - 1) * 28)
            b:SetScript("OnClick", function() ShowTopic(i) end)
            topicButtons[i] = b
        end
        guide:SetScript("OnShow", function() ShowTopic(hub.guideTopic or 1) end)

        -- ---------------- the tabs ----------------
        local tabs = {}
        local function ShowPage(name)
            hub.page = name
            for k, pg in pairs(hub.pages) do if k == name then pg:Show() else pg:Hide() end end
            for k, t in pairs(tabs) do if k == name then t:LockHighlight() else t:UnlockHighlight() end end
            if name ~= "overview" and picker then picker:Hide() end
        end
        local order = { { "guide", "Getting Started", 124 }, { "overview", "Overview", 100 }, { "vault", "Weekly Vault", 110 },
            { "events", "Events", 90 } }
        local right = -44
        for i = #order, 1, -1 do
            local key, label, w = order[i][1], order[i][2], order[i][3]
            local t = Button(win, w, 24, label)
            t:SetPoint("TOPRIGHT", right, -24)
            t:SetFrameLevel(win:GetFrameLevel() + 20)   -- above the drag strip and the pages
            right = right - w - 4
            t:SetScript("OnClick", function() ShowPage(key) end)
            tabs[key] = t
        end
        -- the drag strip stops short of the tabs, so a click on a tab is never a drag
        drag:ClearAllPoints()
        drag:SetPoint("TOPLEFT", 12, -8)
        drag:SetPoint("TOPRIGHT", right - 4, -8)
        hub.ShowPage = ShowPage
        ShowPage("overview")
    end

    -- ======================= Drawing =======================
    local function Enable(b, on) if on then b:Enable() else b:Disable() end end

    local function Refresh()
        local h = hub.h
        subtitle:SetText(string.format("Level %d  -  Paragon %d", h.level or UnitLevel("player"), h.paragon or 0))

        -- tier
        local tiers = Flag(HF_TIERS)
        tierName:SetText(h.tierName or "")
        tierNow:SetText(string.format("Creatures you face: |cffff9933%s|r health, |cffff9933%s|r damage", h.curHealth or "-", h.curDamage or "-"))
        tierMax:SetText(string.format("Highest unlocked: |cffffd100%s|r", h.maxName or ""))
        local need = math.max(1, h.need or 1)
        bar:SetMinMaxValues(0, need)
        bar:SetValue(math.min(h.progress or 0, need))
        barText:SetText(string.format("Next tier: %d / %d bosses", h.progress or 0, need))
        if h.nextName and h.nextName ~= "" then
            tierNext:SetText(string.format("%s: %s health, %s damage, +%d item levels", h.nextName, h.nextHealth, h.nextDamage, h.nextIlvl or 0))
        else
            tierNext:SetText("You are at your highest unlocked tier.")
        end
        local t, mt = h.tier or 0, h.maxTier or 0
        Enable(lowerB, tiers and t > 0)
        Enable(raiseB, tiers and t < mt)
        Enable(maxB, tiers and t ~= mt)
        Enable(normalB, tiers and t ~= 0)
        Enable(goB, tiers)

        -- key
        local k = hub.key
        if not Flag(HF_KEY) then
            keyName:SetText("Tier Keys are off on this realm.")
            keyBest:SetText("")
            activateB:Disable()
        elseif k.has then
            keyName:SetText(k.text or "")
            keyBest:SetText(string.format("Best: +%d", k.best or 0))
            Enable(activateB, k.can)
        else
            keyName:SetText("No Tier Key yet")
            keyBest:SetText("Finish a Wrath dungeon at World Tier I or higher, at level 80.")
            activateB:Disable()
        end
        keyIcon:SetDesaturated(not k.has)
        for i, b in ipairs(portButtons) do
            local p = hub.ports[i]
            if p and Flag(HF_KEYPORT) then
                b.map = p.map
                b:SetText("  " .. p.name .. "  |cff999999(" .. p.whose .. ")|r")
                b:Show()
            else
                b.map = nil
                b:Hide()
            end
        end
        if #hub.ports == 0 or not Flag(HF_KEYPORT) then
            portNone:SetText(Flag(HF_KEYPORT) and "No key dungeon to go to (you are there, or no one has a key)." or "Key teleports are off.")
            portNone:Show()
        else
            portNone:Hide()
        end

        -- tiles
        paragonT:SetOn(Flag(HF_PARAGON))
        local free = h.free or 0
        paragonT.sub:SetText(Flag(HF_PARAGON_LIVE) and string.format("Level %d, %s", h.paragon or 0,
            free > 0 and ("|cff66ff66" .. free .. " point" .. (free == 1 and "" or "s") .. " free|r") or "no points free")
            or "Opens at the level cap")
        forgeT:SetOn(Flag(HF_GEAR))
        transmogT:SetOn(Flag(HF_TRANSMOG))
        pouchT:SetOn(Flag(HF_POUCH))
        reforgeT:SetOn(Flag(HF_GEAR) and hub.reforge[1] > 0)
        reforgeT.sub:SetText(hub.reforge[1] > 0 and string.format("%d piece%s, %s", hub.reforge[1], hub.reforge[1] == 1 and "" or "s", hub.reforge[2])
            or "All at your tier")
        reportT:SetOn(Flag(HF_GEAR))
        Enable(respecB, Flag(HF_PARAGON))
        respecB:SetText((h.respecGold or 0) > 0 and string.format("Reset Paragon Board (%dg)", h.respecGold) or "Reset Paragon Board")

        -- signature
        local lvl = h.level or UnitLevel("player")
        local chosen
        for _, o in ipairs(hub.options) do if o.ks == hub.sig.ks then chosen = o end end
        if not Flag(HF_SIGNATURE) then
            sigIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
            sigIcon:SetDesaturated(true)
            sigName:SetText("Not for your class yet")
            sigText:SetText("Classes with their own Paragon Board choose one of their keystones here. Your class's board is on the way.")
            chooseB:Disable()
            sigBorder:Hide()
        elseif lvl < (hub.sig.slot or 10) then
            sigIcon:SetTexture("Interface\\Icons\\INV_Misc_Key_03")
            sigIcon:SetDesaturated(true)
            sigName:SetText("Opens at level " .. hub.sig.slot)
            sigText:SetText("Choose one of your class keystones to have on at any level, from the start of your journey.")
            chooseB:Disable()
            sigBorder:Hide()
        elseif chosen then
            sigIcon:SetTexture("Interface\\Icons\\" .. chosen.icon)
            sigIcon:SetDesaturated(lvl < chosen.level)
            sigName:SetText(chosen.name)
            sigText:SetText(chosen.text .. (lvl < chosen.level and ("|n|cffff4444Works from level " .. chosen.level .. ".|r") or ""))
            chooseB:Enable()
            chooseB:SetText("Change...")
            sigBorder:Show()
        else
            sigIcon:SetTexture("Interface\\Icons\\INV_Misc_Gem_Variety_01")
            sigIcon:SetDesaturated(false)
            sigName:SetText("Choose a keystone")
            sigText:SetText("One of your class keystones, on at any level without a slot on the board. Free to change out of combat.")
            chooseB:Enable()
            chooseB:SetText("Choose...")
            sigBorder:Hide()
        end
        if picker:IsShown() then RefreshPicker() end
        if hub.RefreshVault then hub.RefreshVault() end
        if hub.RefreshEvents then hub.RefreshEvents() end
        RefreshAscendancy()
        RefreshXpRate()
        auraB:SetText(WT.ksAuras == false and "Keystone Auras: |cffff6666Off|r" or "Keystone Auras: |cff66ff66On|r")
    end
    WT.RefreshHubAuras = function() if win:IsShown() then Refresh() end end

    BuildPages()
    win:SetScript("OnShow", function() PlaySound("igCharacterInfoOpen") end)
    win:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") picker:Hide() if WorldTiersXpRateFrame then WorldTiersXpRateFrame:Hide() end end)

    SLASH_WORLDTIERSXP1 = "/wtxp"
    SlashCmdList["WORLDTIERSXP"] = function(arg)
        local n = tonumber((arg or ""):match("%d+"))
        if (arg or ""):lower():find("off") then n = 0 end
        if n then Send("WL:" .. n)
        else DEFAULT_CHAT_FRAME:AddMessage("|cffff9933World Tiers:|r /wtxp <rate>, from 0 (off) up to the server's rate, while levelling.") end
    end

    local wantOpen = false
    function WT.OpenHub()
        wantOpen = true
        Send("W")
        if WT.AskAscendancies then WT.AskAscendancies() end
    end

    -- WW| WH| WK| WP| WR| WS| WO| WE| WZ| WC|
    function WT.OnHubMessage(msg)
        local cmd = msg:match("^(W[WHKPRSOEZCVL])|") or msg:match("^(V[RTO])|") or msg:match("^(E[ZDXWN])|")
        if not cmd then return false end
        local f = Split(msg:sub(4), "|")
        if cmd == "WW" then
            wantOpen = true
        elseif cmd == "WH" then
            hub.ports, hub.options = {}, {}
            hub.h = {
                tier = tonumber(f[1]) or 0, tierName = f[2], maxTier = tonumber(f[3]) or 0, maxName = f[4],
                progress = tonumber(f[5]) or 0, need = tonumber(f[6]) or 1, nextName = f[7], nextHealth = f[8], nextDamage = f[9],
                nextIlvl = tonumber(f[10]) or 0, curHealth = f[11], curDamage = f[12], paragon = tonumber(f[13]) or 0,
                free = tonumber(f[14]) or 0, respecGold = tonumber(f[15]) or 0, flags = tonumber(f[16]) or 0, level = tonumber(f[17]),
            }
            hub.key, hub.reforge = {}, { 0, "" }
            hub.vault = { rows = {}, offers = {}, left = 0 }
            hub.events = {}
        elseif cmd == "VR" then
            local th = {}
            for n in (f[5] or ""):gmatch("(%d+)") do th[#th + 1] = tonumber(n) end
            if #th == 3 then
                hub.vault.rows[tonumber(f[1]) or 0] = { name = f[2] or "", count = tonumber(f[3]) or 0, best = tonumber(f[4]) or 0, th = th }
            end
        elseif cmd == "VT" then
            hub.vault.left = tonumber(f[1]) or 0
        elseif cmd == "VO" then
            hub.vault.offers[#hub.vault.offers + 1] = { index = tonumber(f[1]) or 0, text = f[2] or "" }
        elseif cmd == "EZ" then
            local e = hub.events
            e.zone, e.band, e.minutes, e.kills, e.goal, e.zoneDone = f[1], f[2], tonumber(f[3]) or 0, tonumber(f[4]) or 0,
                tonumber(f[5]) or 0, f[6] == "1"
        elseif cmd == "ED" then
            local e = hub.events
            e.dungeon, e.minutes, e.dungeonDone = f[1], tonumber(f[2]) or e.minutes, f[3] == "1"
        elseif cmd == "EW" then
            -- EW|name|icon|challenge|reward|secondsLeft|nextName|nextIcon   EN|nextChallenge|nextReward
            hub.events.week = { name = f[1] or "", icon = f[2], challenge = f[3], reward = f[4], left = tonumber(f[5]) or 0,
                                nextName = f[6], nextIcon = f[7] }
        elseif cmd == "EN" then
            if hub.events.week then hub.events.week.nextChallenge, hub.events.week.nextReward = f[1], f[2] end
        elseif cmd == "WV" then
            -- Volatile: a creature next to you is about to burst
            if RaidNotice_AddMessage and RaidWarningFrame then
                RaidNotice_AddMessage(RaidWarningFrame, "|cffff6020Volatile!|r Move away from the body.", ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] or { r = 1, g = 0.3, b = 0.1 })
            end
            PlaySound("RaidWarning")
        elseif cmd == "EX" then
            hub.events.effects = { xp = f[1], champ = f[2], goblin = f[3], rolls = f[4] }
        elseif cmd == "WK" then
            hub.key = { has = f[1] == "1", text = f[2], best = tonumber(f[3]) or 0, can = f[4] == "1", why = f[5] }
        elseif cmd == "WP" then
            hub.ports[#hub.ports + 1] = { map = tonumber(f[1]), name = f[2] or "", whose = f[3] or "" }
        elseif cmd == "WR" then
            hub.reforge = { tonumber(f[1]) or 0, f[2] or "" }
        elseif cmd == "WS" then
            hub.sig = { slot = tonumber(f[1]) or 10, ks = tonumber(f[2]) or 0 }
            WT.ksAuras = f[3] ~= "0"
        elseif cmd == "WO" then
            hub.options[#hub.options + 1] = { ks = tonumber(f[1]), level = tonumber(f[2]) or 1, name = f[3] or "", text = f[4] or "", icon = f[5] or "INV_Misc_QuestionMark" }
        elseif cmd == "WL" then
            -- WL|chosen|highest|at the cap
            hub.xp = { cur = tonumber(f[1]) or 0, max = math.max(1, tonumber(f[2]) or 1), on = true, atCap = f[3] == "1" }
        elseif cmd == "WE" then
            Refresh()
            if wantOpen then
                wantOpen = false
                if not win:IsShown() then win:Show() end
                if hub.openGuide and hub.ShowPage then hub.openGuide = nil hub.ShowPage("guide") end
            end
        elseif cmd == "WZ" then
            UIErrorsFrame:AddMessage(f[1] or "", 1, 0.2, 0.2)
        elseif cmd == "WC" then
            win:Hide()
        end
        return true
    end

    -- the guide: /wtguide, and once by itself on a character's first login
    function WT.OpenGuide()
        hub.openGuide = true
        WT.OpenHub()
    end
    SLASH_WORLDTIERSGUIDE1 = "/wtguide"
    SlashCmdList["WORLDTIERSGUIDE"] = function() WT.OpenGuide() end
    local firstLogin = CreateFrame("Frame")
    firstLogin:RegisterEvent("PLAYER_ENTERING_WORLD")
    firstLogin:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        if type(WorldTiersCharDB) ~= "table" then WorldTiersCharDB = {} end
        if not WorldTiersCharDB.guideSeen then
            WorldTiersCharDB.guideSeen = true
            WT.OpenGuide()
        end
    end)

    SLASH_WORLDTIERSAURA1 = "/wtaura"
    SlashCmdList["WORLDTIERSAURA"] = function() Send("KT") end

    SLASH_WORLDTIERSHUB1 = "/worldtiers"
    SLASH_WORLDTIERSHUB2 = "/wtm"
    SlashCmdList["WORLDTIERSHUB"] = function()
        if win:IsShown() then win:Hide() else WT.OpenHub() end
    end
end

-- ---------------------------------------------------------------------------
-- The Dungeon Finder: show dungeons you've outlevelled when the server lets
-- you queue for them (World Tiers sync them up to you). The stock list hides
-- any dungeon past its maximum level before it asks the server. Raids are
-- listed under the dungeons, and queue the same way.
-- ---------------------------------------------------------------------------

do
    local stock
    local function Filter(dungeonID)
        if stock and stock(dungeonID) then return true end
        local info = LFGGetDungeonInfoByID and LFGGetDungeonInfoByID(dungeonID)
        local R = LFG_RETURN_VALUES
        if not info or not R then return false end
        local level = UnitLevel("player")
        return info[R.groupID] ~= 0 and (EXPANSION_LEVEL or 2) >= (info[R.expansionLevel] or 0)
            and level >= (info[R.minLevel] or 0) and level > (info[R.maxLevel] or 0)
            and LFGLockList ~= nil and not LFGLockList[dungeonID]   -- the server says you can go
    end
    -- Raids in the list too, after the dungeons (the server queues them like
    -- dungeons: Raids.InFinder). The stock list only ever holds dungeons.
    local stockOrder
    local function WithRaids(list)
        list = stockOrder(list)
        if WT.raidsInFinder == false or type(GetLFRChoiceOrder) ~= "function" then return list end
        local have = {}
        for _, id in ipairs(list) do have[id] = true end
        for _, id in ipairs(GetLFRChoiceOrder() or {}) do
            if not have[id] then list[#list + 1] = id have[id] = true end
        end
        return list
    end
    local function Install()
        if not stockOrder and type(GetLFDChoiceOrder) == "function" then
            stockOrder = GetLFDChoiceOrder
            GetLFDChoiceOrder = WithRaids
        end
        if stock or type(LFDList_DefaultFilterFunction) ~= "function" then return end
        stock = LFDList_DefaultFilterFunction
        LFDList_DefaultFilterFunction = Filter
        if LFD_CURRENT_FILTER == stock or LFD_CURRENT_FILTER == nil then LFD_CURRENT_FILTER = Filter end
    end
    WT.LfdFilter = Filter
    Install()
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_LOGIN")
    ev:RegisterEvent("LFG_LOCK_INFO_RECEIVED")
    ev:SetScript("OnEvent", function()
        Install()
        if LFDQueueFrame and LFDQueueFrame:IsShown() and LFDQueueFrame_Update then LFDQueueFrame_Update() end
    end)
end

-- ---------------------------------------------------------------------------
-- Are this player's client files the ones the server expects? (CV|version|spell)
-- The IsDead Launcher keeps them current; this catches anyone who started
-- Wow.exe straight away after an update.
-- ---------------------------------------------------------------------------

do
    WT.CLIENT_VERSION = "0.35"
    local warned = false
    StaticPopupDialogs["WORLDTIERS_OUTDATED"] = {
        text = "|cffff9933Your IsDead WoW client files are out of date.|r\n\n%s\n\nClose the game and start it with |cffffffffIsDead Launcher|r: it updates everything by itself.",
        button1 = OKAY,
        timeout = 0, whileDead = 1, hideOnEscape = 1, showAlert = 1,
    }
    -- "0.26" newer than "0.23.1"? part by part, as numbers
    local function Newer(a, b)
        local pa, pb = {}, {}
        for n in a:gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
        for n in b:gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
        for i = 1, math.max(#pa, #pb) do
            local x, y = pa[i] or 0, pb[i] or 0
            if x ~= y then return x > y end
        end
        return false
    end
    function WT.OnVersionMessage(msg)
        local want, probe = msg:match("^CV|([^|]*)|(%d*)")
        if not want then return false end
        if warned then return true end
        local why
        if want ~= "" and Newer(want, WT.CLIENT_VERSION) then   -- an addon newer than the server is fine
            why = string.format("Your World Tiers addon is %s; the server is on %s.", WT.CLIENT_VERSION, want)
        elseif tonumber(probe) and tonumber(probe) > 0 and not GetSpellInfo(tonumber(probe)) then
            why = "Your patch file (patch-enUS-W.MPQ) is older than the server's."
        end
        if why then
            warned = true
            StaticPopup_Show("WORLDTIERS_OUTDATED", why)
            if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cffff9933IsDead WoW:|r " .. why .. " Run IsDead Launcher to update.") end
        end
        return true
    end
end

-- ---------------------------------------------------------------------------
-- Events and the slash command
-- ---------------------------------------------------------------------------

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_ADDON")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:RegisterEvent("PLAYER_LEVEL_UP")
events:SetScript("OnEvent", function(self, event, prefix, msg, channel, sender)
    if event == "CHAT_MSG_ADDON" then
        if prefix == PREFIX and sender == UnitName("player") then
            if not WT.OnItemMessage(msg) and not WT.OnBarMessage(msg) and not WT.OnForgeMessage(msg)
                and not WT.OnChampionMessage(msg) and not WT.OnKeyMessage(msg) and not WT.OnLoadoutMessage(msg)
                and not WT.OnPouchMessage(msg) and not WT.OnSellMessage(msg) and not WT.OnGlyphMessage(msg) and not WT.OnVersionMessage(msg) and not WT.OnTreasureMessage(msg) and not WT.OnAscMessage(msg) and not WT.OnTransmogMessage(msg) and not WT.OnHubMessage(msg) and not WT.OnSpecialMessage(msg) and not WT.OnSplashMessage(msg) and not WT.OnLootPreviewMessage(msg) then OnMessage(msg) end
        end
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LEVEL_UP" then
        Send("H")
    end
end)

frame:SetScript("OnShow", function()
    PlaySound("igCharacterInfoOpen")
    if WT.serverOpened then WT.serverOpened = false else Send("T") end
    if WT.drawn then WT.lastDraw = nil Draw() end
end)
frame:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") end)

SLASH_WORLDTIERSPARAGON1 = "/paragon"
SLASH_WORLDTIERSPARAGON2 = "/wt"
SlashCmdList["WORLDTIERSPARAGON"] = function()
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

WT.OnMessage, WT.Draw, WT.Reveal, WT.Blocker, WT.RefundBlocker = OnMessage, Draw, Reveal, Blocker, RefundBlocker
