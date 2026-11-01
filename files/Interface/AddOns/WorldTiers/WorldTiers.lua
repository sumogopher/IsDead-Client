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
G.ARMS, G.SEGMENT, G.NOTABLES, G.BRANCH = 14, 5, 3, 3
G.FINITE = G.SEGMENT * G.NOTABLES
G.MAX_POS = G.FINITE   -- 0.37: the board ends (Paragon past it feeds the skill bank)
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
titleBar:SetScript("OnDragStart", function() if frame:IsMovable() then frame:StartMoving() end end)   -- not while in the World Tiers window
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
    return G.FINITE   -- 0.37: no mastery nodes
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
    -- once at login, so every window that shows the Ascendancy has it from the start
    local login = CreateFrame("Frame")
    login:RegisterEvent("PLAYER_ENTERING_WORLD")
    login:SetScript("OnEvent", function(self)
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        Send("J")
    end)
    SLASH_WORLDTIERSASCEND1 = "/ascend"
    SlashCmdList["WORLDTIERSASCEND"] = function() WT.OpenAscendancy() end
end
-- the support gems (0.37). Generated by tools/gen_gems.py: edit it there.
WT.GEMS = {
  [1] = { key = "ADDED_FIRE", name = "Added Fire Damage", rarity = 0, colour = "red", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits with the supported skill deal an extra {a}% of their damage as Fire." },
  [2] = { key = "ADDED_COLD", name = "Added Cold Damage", rarity = 0, colour = "blue", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits with the supported skill deal an extra {a}% of their damage as Frost." },
  [3] = { key = "ADDED_LIGHTNING", name = "Added Lightning Damage", rarity = 0, colour = "yellow", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits with the supported skill deal an extra {a}% of their damage as Nature." },
  [4] = { key = "ADDED_CHAOS", name = "Added Chaos Damage", rarity = 0, colour = "purple", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits with the supported skill deal an extra {a}% of their damage as Shadow." },
  [5] = { key = "ADDED_ARCANE", name = "Added Arcane Damage", rarity = 0, colour = "white", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits with the supported skill deal an extra {a}% of their damage as Arcane." },
  [6] = { key = "ELEMENTAL_FOCUS", name = "Elemental Focus", rarity = 0, colour = "orange", a1 = 25, a20 = 49, aLow = false, aFix = false, aInt = false, b1 = 30, b20 = 30, bLow = true, bFix = true, text = "{a}% more magic (non-Physical) damage. {b}% less Physical damage." },
  [7] = { key = "BRUTALITY", name = "Brutality", rarity = 0, colour = "red", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 30, b20 = 30, bLow = true, bFix = true, text = "{a}% more Physical damage. {b}% less magic damage." },
  [8] = { key = "CONTROLLED_DESTRUCTION", name = "Controlled Destruction", rarity = 0, colour = "purple", a1 = 25, a20 = 44, aLow = false, aFix = false, aInt = false, b1 = 10, b20 = 10, bLow = true, bFix = true, text = "{a}% more spell damage. {b}% less critical strike chance." },
  [9] = { key = "CONCENTRATED_EFFECT", name = "Concentrated Effect", rarity = 0, colour = "orange", a1 = 25, a20 = 44, aLow = false, aFix = false, aInt = false, b1 = 25, b20 = 25, bLow = true, bFix = true, text = "{a}% more area damage. {b}% smaller area." },
  [10] = { key = "INCREASED_AREA", name = "Increased Area of Effect", rarity = 0, colour = "orange", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 19, bLow = false, bFix = false, text = "{a}% larger area. {b}% more area damage." },
  [11] = { key = "FASTER_CASTING", name = "Faster Casting", rarity = 0, colour = "blue", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% faster cast time." },
  [12] = { key = "FASTER_ATTACKS", name = "Faster Attacks", rarity = 0, colour = "yellow", a1 = 15, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% shorter cooldown and cast time. On Attack or Auto Shot: {a}% faster attacks." },
  [13] = { key = "INSPIRATION", name = "Inspiration", rarity = 0, colour = "blue", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 10, b20 = 19, bLow = false, bFix = false, text = "{a}% less cost. {b}% more damage." },
  [14] = { key = "INCREASED_CRIT", name = "Increased Critical Strikes", rarity = 0, colour = "yellow", a1 = 3, a20 = 6.8, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "+{a}% critical strike chance." },
  [15] = { key = "INCREASED_CRIT_DAMAGE", name = "Increased Critical Damage", rarity = 0, colour = "yellow", a1 = 30, a20 = 58, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "+{a}% critical strike damage." },
  [16] = { key = "LIFE_LEECH", name = "Life Leech", rarity = 0, colour = "red", a1 = 2, a20 = 3.9, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% of the damage dealt is returned to you as health." },
  [17] = { key = "POWER_LEECH", name = "Power Leech", rarity = 0, colour = "blue", a1 = 1, a20 = 2, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% of the damage dealt is returned as mana. Rage, energy and runic power: a point a hit." },
  [18] = { key = "CULLING_STRIKE", name = "Culling Strike", rarity = 0, colour = "red", a1 = 10, a20 = 10, aLow = false, aFix = true, aInt = false, b1 = 0, b20 = 19, bLow = false, bFix = false, text = "Kills enemies (not bosses) left below {a}% health. {b}% more damage." },
  [19] = { key = "EXECUTIONER", name = "Executioner", rarity = 0, colour = "red", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage to bosses and elites." },
  [20] = { key = "CLOSE_COMBAT", name = "Close Combat", rarity = 0, colour = "red", a1 = 30, a20 = 49, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Up to {a}% more damage to close enemies, less with distance (none at 30 yards)." },
  [21] = { key = "FAR_SHOT", name = "Far Shot", rarity = 0, colour = "yellow", a1 = 25, a20 = 44, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Up to {a}% more damage to distant enemies (the most at 30 yards)." },
  [22] = { key = "ONSLAUGHT", name = "Onslaught", rarity = 0, colour = "orange", a1 = 15, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "A kill with the supported skill: {a}% more damage with it for 4 sec." },
  [23] = { key = "HIT_WHILE_HEALTHY", name = "Hit While Healthy", rarity = 0, colour = "green", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage while you are above 90% health." },
  [24] = { key = "CHANCE_TO_BLEED", name = "Chance to Bleed", rarity = 0, colour = "red", a1 = 25, a20 = 25, aLow = false, aFix = true, aInt = false, b1 = 40, b20 = 79, bLow = false, bFix = false, text = "{a}% chance a hit makes the enemy bleed: {b}% of the hit as Physical over 6 sec." },
  [25] = { key = "SWIFT_AFFLICTION", name = "Swift Affliction", rarity = 0, colour = "purple", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 20, b20 = 20, bLow = true, bFix = true, text = "{a}% more damage over time. {b}% shorter duration." },
  [26] = { key = "MAIM", name = "Maim", rarity = 0, colour = "red", a1 = 10, a20 = 19, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits maim for 4 sec: maimed enemies take {a}% more Physical damage from you." },
  [27] = { key = "HYPOTHERMIA", name = "Hypothermia", rarity = 0, colour = "blue", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage to slowed enemies." },
  [28] = { key = "MINION_DAMAGE", name = "Minion Damage", rarity = 1, colour = "green", a1 = 25, a20 = 44, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Pet and minion skills: {a}% more damage." },
  [29] = { key = "MINION_LIFE", name = "Minion Life", rarity = 1, colour = "green", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Pet and minion skills: your pets and minions take {a}% less damage." },
  [30] = { key = "MINION_SPEED", name = "Minion Speed", rarity = 1, colour = "green", a1 = 15, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Pet and minion skills: {a}% chance their hits strike twice." },
  [31] = { key = "FEEDING_FRENZY", name = "Feeding Frenzy", rarity = 1, colour = "green", a1 = 10, a20 = 19, aLow = false, aFix = false, aInt = false, b1 = 5, b20 = 9, bLow = false, bFix = false, text = "Pet and minion skills: {a}% more damage, and while your pet is fighting you deal {b}% more damage with every skill." },
  [32] = { key = "CHAIN", name = "Chain", rarity = 2, colour = "yellow", a1 = 1, a20 = 2, aLow = false, aFix = true, aInt = true, b1 = 60, b20 = 79, bLow = false, bFix = false, text = "Hits chain to {a} more nearby enemy (2 from level 10) for {b}% of the damage." },
  [33] = { key = "MULTIPLE_PROJECTILES", name = "Multiple Projectiles", rarity = 2, colour = "yellow", a1 = 2, a20 = 2, aLow = false, aFix = true, aInt = true, b1 = 45, b20 = 64, bLow = false, bFix = false, text = "Also strikes {a} more enemies near the target for {b}% of the damage." },
  [34] = { key = "PIERCE", name = "Pierce", rarity = 2, colour = "yellow", a1 = 1, a20 = 2, aLow = false, aFix = true, aInt = true, b1 = 70, b20 = 89, bLow = false, bFix = false, text = "Pierces through to {a} more enemy (2 from level 15) for {b}% of the damage." },
  [35] = { key = "ECHO", name = "Spell Echo", rarity = 2, colour = "blue", a1 = 70, a20 = 89, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "The supported skill repeats: a second hit for {a}% of the damage." },
  [36] = { key = "BARRAGE", name = "Barrage", rarity = 2, colour = "yellow", a1 = 2, a20 = 3, aLow = false, aFix = true, aInt = true, b1 = 30, b20 = 49, bLow = false, bFix = false, text = "Fires {a} more times at the target (3 from level 15), each for {b}% of the damage." },
  [37] = { key = "SPELL_CASCADE", name = "Spell Cascade", rarity = 2, colour = "blue", a1 = 2, a20 = 2, aLow = false, aFix = true, aInt = true, b1 = 35, b20 = 54, bLow = false, bFix = false, text = "Area skills: {a} more bursts around the target, each hitting nearby enemies for {b}% of the damage." },
  [38] = { key = "TOTEM", name = "Totem", rarity = 2, colour = "green", a1 = 40, a20 = 59, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Using the skill places a totem for 8 sec (once every 8 sec) that repeats its hit on a nearby enemy every 2 sec for {a}%." },
  [39] = { key = "TRAP", name = "Trap", rarity = 2, colour = "orange", a1 = 100, a20 = 139, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Using the skill also drops a trap at the target (once every 10 sec): 2 sec later it bursts for {a}% of the hit." },
  [40] = { key = "UNLEASH", name = "Unleash", rarity = 2, colour = "blue", a1 = 2, a20 = 2, aLow = false, aFix = true, aInt = true, b1 = 45, b20 = 64, bLow = false, bFix = false, text = "Every 4th use repeats {a} more times, each for {b}% of the damage." },
  [41] = { key = "RUTHLESS", name = "Ruthless", rarity = 2, colour = "red", a1 = 60, a20 = 99, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Every 3rd hit deals {a}% more damage." },
  [42] = { key = "FORTIFY", name = "Fortify", rarity = 2, colour = "white", a1 = 12, a20 = 21, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits fortify you for 6 sec: {a}% less damage taken." },
  [43] = { key = "SHOCKWAVE", name = "Shockwave", rarity = 2, colour = "orange", a1 = 35, a20 = 54, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits send out a shockwave (once a second): {a}% of the hit to enemies within 6 yards of the target." },
  [44] = { key = "CONVERT_FIRE", name = "Elemental Conversion: Fire", rarity = 2, colour = "red", a1 = 10, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage. Counts as Fire for other supports: extra hits it makes are Fire." },
  [45] = { key = "CONVERT_FROST", name = "Elemental Conversion: Frost", rarity = 2, colour = "blue", a1 = 10, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage. Counts as Frost for other supports: extra hits it makes are Frost." },
  [46] = { key = "CONVERT_NATURE", name = "Elemental Conversion: Nature", rarity = 2, colour = "green", a1 = 10, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage. Counts as Nature for other supports: extra hits it makes are Nature." },
  [47] = { key = "CONVERT_SHADOW", name = "Elemental Conversion: Shadow", rarity = 2, colour = "purple", a1 = 10, a20 = 29, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% more damage. Counts as Shadow for other supports: extra hits it makes are Shadow." },
  [48] = { key = "INFUSED_CHANNELLING", name = "Infused Channelling", rarity = 2, colour = "purple", a1 = 15, a20 = 34, aLow = false, aFix = false, aInt = false, b1 = 8, b20 = 15, bLow = false, bFix = false, text = "While you channel the skill: {a}% more damage with it, and {b}% less damage taken." },
  [49] = { key = "PREDATOR", name = "Predator", rarity = 2, colour = "green", a1 = 20, a20 = 39, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Pet and minion skills: {a}% more damage to your own target." },
  [50] = { key = "MINION_INSTABILITY", name = "Minion Instability", rarity = 2, colour = "orange", a1 = 10, a20 = 10, aLow = false, aFix = true, aInt = false, b1 = 50, b20 = 89, bLow = false, bFix = false, text = "Pet and minion skills: {a}% chance a hit explodes, {b}% of it as Fire to enemies within 8 yards." },
  [51] = { key = "DEBILITATE", name = "Debilitate", rarity = 2, colour = "purple", a1 = 8, a20 = 17, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "Hits debilitate for 6 sec: those enemies deal {a}% less damage to you." },
  [52] = { key = "CAST_ON_CRIT", name = "Cast on Critical Strike", rarity = 3, colour = "rare", a1 = 1, a20 = 0.5, aLow = true, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "The supported skill casts itself, free, when another of your skills strikes critically (once every {a} sec)." },
  [53] = { key = "CAST_WHEN_DAMAGE_TAKEN", name = "Cast when Damage Taken", rarity = 3, colour = "rare", a1 = 15, a20 = 8, aLow = true, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "The supported skill casts itself, free, each time you take damage adding up to {a}% of your health." },
  [54] = { key = "CAST_ON_KILL", name = "Cast on Kill", rarity = 3, colour = "rare", a1 = 1, a20 = 0.5, aLow = true, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "The supported skill casts itself, free, when you kill an enemy (once every {a} sec)." },
  [55] = { key = "CAST_WHILE_CHANNELLING", name = "Cast while Channelling", rarity = 3, colour = "rare", a1 = 1, a20 = 0.6, aLow = true, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "The supported skill casts itself, free, every {a} sec while you channel another skill." },
  [56] = { key = "EMPOWER", name = "Empower", rarity = 3, colour = "rare", a1 = 1, a20 = 4, aLow = false, aFix = false, aInt = true, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "+{a} levels to the supported skill." },
  [57] = { key = "ENLIGHTEN", name = "Enlighten", rarity = 3, colour = "rare", a1 = 20, a20 = 58, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "{a}% less cost." },
  [58] = { key = "BLOOD_MAGIC", name = "Blood Magic", rarity = 3, colour = "rare", a1 = 4, a20 = 2, aLow = true, aFix = false, aInt = false, b1 = 10, b20 = 19, bLow = false, bFix = false, text = "Costs no mana, rage, energy or runic power: {a}% of your health instead. {b}% more damage." },
  [59] = { key = "VOLATILE", name = "Volatile", rarity = 3, colour = "rare", a1 = 20, a20 = 20, aLow = false, aFix = true, aInt = false, b1 = 40, b20 = 79, bLow = false, bFix = false, text = "{a}% chance a hit explodes: {b}% of it as Fire to enemies within 8 yards of the target." },
  [60] = { key = "MIRROR_IMAGE", name = "Mirror Image", rarity = 3, colour = "rare", a1 = 35, a20 = 54, aLow = false, aFix = false, aInt = false, b1 = 0, b20 = 0, bLow = false, bFix = false, text = "A mirror image of you uses the skill too: every hit repeats for {a}%." },
}
WT.GEM_COUNT = 60
WT.GEM_AWAKENED_TEXT = "Awakened: +2 levels to the supported skill."
WT.GEM_ITEM_FIRST, WT.GEM_AWAKENED_FIRST, WT.LINKING_ORB, WT.GEMCUTTER_SHARD = 992000, 992100, 992200, 992202

-- ---------------------------------------------------------------------------
-- Skills and support gems (0.37): the World Tiers window's Skills tab, its
-- Keystones tab, the Paragon Board in its own tab, and gem tooltips
-- ---------------------------------------------------------------------------

do
    local skills = { list = {}, byKey = {}, pouch = {}, bags = {}, bank = 0, orbs = 0, shards = 0, linkAt = { 5, 15, 30, 50, 75 } }
    local pending = { list = {}, pouch = {}, bags = {} }
    WT.skills = skills

    local RARITY_COLOUR = { [0] = "|cff1eff00", [1] = "|cff1eff00", [2] = "|cff0070dd", [3] = "|cffa335ee" }
    local RARITY_NAME = { [0] = "Common", [1] = "Pet", [2] = "Uncommon", [3] = "Rare" }

    -- ---- a gem's numbers: the same rules as the server (WorldTiersSkills.cpp) ----
    local function Raw(d, b, level)
        local lo, hi = b and d.b1 or d.a1, b and d.b20 or d.a20
        return lo + (hi - lo) * (math.max(1, math.min(20, level)) - 1) / 19
    end
    local function Val(gem, awk, level, q, b)
        local d = WT.GEMS[gem]
        if not d then return 0 end
        local v = Raw(d, b, level)
        if (b and d.bFix) or (not b and d.aFix) then return v end
        v = v * (1 + math.min(q or 0, 20) / 100)
        if awk then
            if (b and d.bLow) or (not b and d.aLow) then v = v / 1.5 else v = v * 1.5 end
        end
        return v
    end
    local function Count(gem, awk, level)
        local k = WT.GEMS[gem] and WT.GEMS[gem].key
        local n = 0
        if k == "CHAIN" then n = level >= 10 and 2 or 1
        elseif k == "PIERCE" then n = level >= 15 and 2 or 1
        elseif k == "BARRAGE" then n = level >= 15 and 3 or 2
        elseif k == "MULTIPLE_PROJECTILES" or k == "SPELL_CASCADE" or k == "UNLEASH" then n = 2
        elseif k == "EMPOWER" then n = math.floor(Raw(WT.GEMS[gem], false, level) + 0.5) end
        return n + (awk and 1 or 0)
    end
    local function Num(v)
        local s = string.format("%.1f", v)
        return (s:gsub("%.0$", ""))
    end
    function WT.GemText(gem, awk, level, q)
        local d = WT.GEMS[gem]
        if not d then return "" end
        local a = d.aInt and tostring(Count(gem, awk, level)) or Num(Val(gem, awk, level, q, false))
        local b = Num(Val(gem, awk, level, q, true))
        local t = d.text:gsub("{a}", a):gsub("{b}", b)
        if awk then t = t .. "\n|cffff8000" .. WT.GEM_AWAKENED_TEXT .. "|r" end
        return t
    end
    function WT.GemName(gem, awk)
        local d = WT.GEMS[gem]
        if not d then return "?" end
        return (awk and "|cffff8000Awakened " or RARITY_COLOUR[d.rarity]) .. d.name .. "|r"
    end
    function WT.GemIcon(gem, awk)
        local icon = GetItemIcon((awk and WT.GEM_AWAKENED_FIRST or WT.GEM_ITEM_FIRST) + gem)
        return icon or "Interface\\Icons\\INV_Misc_Gem_Variety_01"
    end
    -- the tooltip for a gem: what it does at its level and quality
    function WT.GemTooltip(tt, g, extra)
        local d = WT.GEMS[g.gem]
        if not d then return end
        tt:AddLine(WT.GemName(g.gem, g.awk) .. " Support")
        tt:AddLine(string.format("%s%s support gem  -  level %d%s", g.awk and "Awakened " or "", RARITY_NAME[d.rarity] or "",
            g.level or 1, (g.quality or 0) > 0 and string.format(", %d%% quality", g.quality) or ""), 0.8, 0.8, 0.8)
        tt:AddLine(WT.GemText(g.gem, g.awk, g.level or 1, g.quality or 0), 1, 1, 1, true)
        if g.need and g.need > 0 then
            tt:AddLine(string.format("Experience: %d / %d", g.xp or 0, g.need), 0.6, 0.6, 0.6)
        elseif (g.level or 1) >= 20 then
            tt:AddLine("Level 20: the highest.", 0.6, 0.6, 0.6)
        end
        if d.rarity == 1 then tt:AddLine("Works on pet and minion skills.", 0.5, 0.8, 0.5, true) end
        if extra then tt:AddLine(extra, 0.5, 0.8, 1, true) end
    end

    local function SkillName(s)
        if s.key == 883 then return "Pet" end
        if s.key == 20271 then return "Judgement" end   -- every Judgement is one skill
        local name = GetSpellInfo(s.spell)
        return name or ("Skill " .. s.key)
    end
    local function SkillIcon(s)
        local _, _, icon = GetSpellInfo(s.spell)
        return icon or "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    -- where a skill comes from (0.37.3)
    -- s.from: the keystones (and Ascendancy) that strike with it, by name (0.37.4)
    local function OriginText(s)
        local from = (s.from or ""):gsub(";", ", ")
        local o = s.origin or "L"
        if o == "P" then return "From your weapon poisons" .. (from ~= "" and (", and " .. from) or "") end
        if o == "K" then return from ~= "" and ("From " .. from) or "From a keystone" end
        if o == "LK" then return "Learned as you level, and from " .. (from ~= "" and from or "a keystone") end
        if o == "?" then return "|cffff6060(the server needs the 0.37.4 update)|r" end
        return "Learned as you level"
    end
    WT.SkillOriginText = OriginText
    local function MoreFromLevels(eff)
        local slow = 40
        local l = math.min(eff, slow) + math.max(0, eff - slow) * 0.5
        return (math.pow(1.02, l) - 1) * 100
    end
    local function NextLinkAt(s)
        for _, at in ipairs(skills.linkAt) do if s.level < at then return at end end
        return nil
    end

    -- ---- what the server says ----
    function WT.OnSkillMessage(msg)
        local cmd, rest = msg:match("^(Q%u)|(.*)$")
        if not cmd then return false end
        local f = Split(rest, "|")
        if cmd == "QG" then
            if WT.OnPerksData then WT.OnPerksData(f) end
            return true
        end
        if cmd == "QH" then
            pending = { list = {}, pouch = {}, bags = {} }
            skills.bank = tonumber(f[1]) or 0
            local at = {}
            for n in (f[2] or ""):gmatch("(%d+)") do at[#at + 1] = tonumber(n) end
            if #at > 0 then skills.linkAt = at end
            skills.orbs, skills.shards = tonumber(f[3]) or 0, tonumber(f[4]) or 0
        elseif cmd == "QK" then
            local p = Split(rest, "^")
            local s = { key = tonumber(p[1]) or 0, spell = tonumber(p[2]) or 0, level = tonumber(p[3]) or 0, xp = tonumber(p[4]) or 0,
                need = tonumber(p[5]) or 1, open = tonumber(p[6]) or 0, eff = tonumber(p[7]) or 0, links = {}, origin = p[9] or "?", from = p[10] or "" }
            local i = 0
            for one in ((p[8] or "") .. ","):gmatch("([^,]*),") do
                i = i + 1
                local g = {}
                for piece in one:gmatch("[^%.]+") do g[#g + 1] = piece end
                local gem = tonumber(g[1]) or 0
                if gem > 0 then
                    s.links[i] = { gem = gem, awk = g[2] == "1", level = tonumber(g[3]) or 1, quality = tonumber(g[4]) or 0,
                        xp = tonumber(g[5]) or 0, need = tonumber(g[6]) or 0 }
                end
            end
            pending.list[#pending.list + 1] = s
        elseif cmd == "QP" then
            for one in rest:gmatch("([^~]+)") do
                local p = Split(one, "^")
                pending.pouch[#pending.pouch + 1] = { id = tonumber(p[1]) or 0, gem = tonumber(p[2]) or 0, awk = p[3] == "1",
                    level = tonumber(p[4]) or 1, quality = tonumber(p[5]) or 0, xp = tonumber(p[6]) or 0, need = tonumber(p[7]) or 0 }
            end
        elseif cmd == "QB" then
            for one in rest:gmatch("([^~]+)") do
                local p = Split(one, "^")
                pending.bags[#pending.bags + 1] = { bag = tonumber(p[1]) or 0, slot = tonumber(p[2]) or 0, gem = tonumber(p[3]) or 0,
                    awk = p[4] == "1", level = tonumber(p[5]) or 1, quality = tonumber(p[6]) or 0 }
            end
        elseif cmd == "QE" then
            skills.list, skills.pouch, skills.bags = pending.list, pending.pouch, pending.bags
            skills.byKey = {}
            for _, s in ipairs(skills.list) do skills.byKey[s.key] = s end
            table.sort(skills.list, function(a, b)
                local la, lb = a.level + (next(a.links) and 1000 or 0), b.level + (next(b.links) and 1000 or 0)
                if la ~= lb then return la > lb end
                return SkillName(a) < SkillName(b)
            end)
            table.sort(skills.pouch, function(a, b)
                if a.awk ~= b.awk then return a.awk end
                if a.gem ~= b.gem then return (WT.GEMS[a.gem] and WT.GEMS[a.gem].name or "") < (WT.GEMS[b.gem] and WT.GEMS[b.gem].name or "") end
                return a.level > b.level
            end)
            skills.loaded = true
            if WT.RefreshSkillsPage then WT.RefreshSkillsPage() end
        end
        return true
    end

    -- gem items in the bags: their level and quality in the tooltip
    if hooksecurefunc and GameTooltip then hooksecurefunc(GameTooltip, "SetBagItem", function(tt, bag, slot)
        local link = GetContainerItemLink(bag, slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        if not id then return end
        local awk = id > WT.GEM_AWAKENED_FIRST and id <= WT.GEM_AWAKENED_FIRST + WT.GEM_COUNT
        local gem = awk and id - WT.GEM_AWAKENED_FIRST or ((id > WT.GEM_ITEM_FIRST and id <= WT.GEM_ITEM_FIRST + WT.GEM_COUNT) and id - WT.GEM_ITEM_FIRST)
        if not gem then return end
        local level, quality = 1, 0
        for _, b in ipairs(skills.bags) do
            if b.bag == bag and b.slot == slot and b.gem == gem then level, quality = b.level, b.quality end
        end
        tt:AddLine(" ")
        tt:AddLine(string.format("Level %d%s", level, quality > 0 and string.format(", %d%% quality", quality) or ""), 0.4, 0.8, 1)
        tt:AddLine(WT.GemText(gem, awk, level, quality), 1, 1, 1, true)
        tt:AddLine("Put it in your gem pouch: World Tiers menu, Skills.", 0.5, 0.8, 1, true)
        tt:Show()
    end) end

    -- =======================================================================
    -- The Skills page
    -- =======================================================================
    function WT.BuildSkillsPage(page, H)
        local Section, Button, Tip = H.Section, H.Button, H.Tip
        local selected

        -- ---- the skill list ----
        local listS = Section(16, -60, 296, 516, "Skills", page)
        listS.note:SetText("level")
        local scroll = CreateFrame("ScrollFrame", "WorldTiersSkillsScroll", listS, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 8, -34)
        scroll:SetPoint("BOTTOMRIGHT", -28, 8)
        local body = CreateFrame("Frame", nil, scroll)
        Size(body, 260, 400)
        scroll:SetScrollChild(body)
        local rows = {}
        local function Row(i)
            if rows[i] then return rows[i] end
            local r = CreateFrame("Button", nil, body)
            Size(r, 258, 32)
            r:SetPoint("TOPLEFT", 0, -(i - 1) * 33)
            r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            r.sel = r:CreateTexture(nil, "BACKGROUND")
            r.sel:SetAllPoints()
            r.sel:SetTexture(0.9, 0.7, 0.2, 0.18)
            r.icon = r:CreateTexture(nil, "ARTWORK")
            Size(r.icon, 22, 22)
            r.icon:SetPoint("LEFT", 2, 0)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 6, 2)
            r.name:SetWidth(150)
            r.name:SetJustifyH("LEFT")
            r.origin = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            r.origin:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -2)
            r.origin:SetWidth(170)
            r.origin:SetHeight(11)
            r.origin:SetJustifyH("LEFT")
            r.links = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r.links:SetPoint("RIGHT", -34, 0)
            r.level = r:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            r.level:SetPoint("RIGHT", -4, 0)
            r:SetScript("OnClick", function(self) selected = self.key WT.RefreshSkillsPage() end)
            rows[i] = r
            return r
        end

        -- ---- the chosen skill ----
        local detail = Section(320, -60, 484, 262, "Skill", page)
        local dIcon = detail:CreateTexture(nil, "ARTWORK")
        Size(dIcon, 40, 40)
        dIcon:SetPoint("TOPLEFT", 14, -36)
        local dName = detail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        dName:SetPoint("TOPLEFT", dIcon, "TOPRIGHT", 10, -2)
        local dLevel = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        dLevel:SetPoint("TOPLEFT", dName, "BOTTOMLEFT", 0, -4)
        dLevel:SetWidth(400)
        dLevel:SetJustifyH("LEFT")
        local bar = CreateFrame("StatusBar", nil, detail)
        bar:SetPoint("TOPLEFT", 14, -84)
        Size(bar, 456, 12)
        bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
        bar:SetStatusBarColor(0.9, 0.7, 0.15)
        local barBg = bar:CreateTexture(nil, "BACKGROUND")
        barBg:SetAllPoints()
        barBg:SetTexture(0, 0, 0, 0.6)
        local barText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        barText:SetPoint("CENTER")
        local linksHeader = detail:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        linksHeader:SetPoint("TOPLEFT", 14, -106)
        linksHeader:SetText("Support links")
        local slots = {}
        local slotMenu = CreateFrame("Frame", "WorldTiersGemSlotMenu", UIParent, "UIDropDownMenuTemplate")
        for i = 1, 6 do
            local b = CreateFrame("Button", nil, detail)
            Size(b, 44, 44)
            b:SetPoint("TOPLEFT", 14 + (i - 1) * 76, -126)
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b.bg = b:CreateTexture(nil, "BACKGROUND")
            b.bg:SetAllPoints()
            b.bg:SetTexture("Interface\\Buttons\\UI-EmptySlot-Disabled")
            b.bg:SetTexCoord(0.15, 0.85, 0.15, 0.85)
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetPoint("TOPLEFT", 3, -3)
            b.icon:SetPoint("BOTTOMRIGHT", -3, 3)
            b.lock = b:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            b.lock:SetPoint("CENTER")
            b.label = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            b.label:SetPoint("TOP", b, "BOTTOM", 0, -3)
            b.label:SetWidth(74)
            b.label:SetHeight(26)
            b.label:SetJustifyV("TOP")
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            b.index = i
            slots[i] = b
        end
        local orbB = Button(detail, 150, 22, "Linking Orb")
        orbB:SetPoint("BOTTOMLEFT", 12, 12)
        local bankB = Button(detail, 150, 22, "Skill bank")
        bankB:SetPoint("LEFT", orbB, "RIGHT", 6, 0)
        local help = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        help:SetPoint("LEFT", bankB, "RIGHT", 8, 0)
        help:SetWidth(160)
        help:SetJustifyH("LEFT")
        help:SetText("Click a gem in your pouch to link it; right-click a link to take it out.")

        -- ---- the gem pouch ----
        local pouchS = Section(320, -326, 484, 250, "Gem pouch", page)
        local pScroll = CreateFrame("ScrollFrame", "WorldTiersGemPouchScroll", pouchS, "UIPanelScrollFrameTemplate")
        pScroll:SetPoint("TOPLEFT", 8, -34)
        pScroll:SetPoint("BOTTOMRIGHT", -28, 8)
        local pBody = CreateFrame("Frame", nil, pScroll)
        Size(pBody, 446, 200)
        pScroll:SetScrollChild(pBody)
        local pRows = {}
        local gemMenu = CreateFrame("Frame", "WorldTiersGemMenu", UIParent, "UIDropDownMenuTemplate")
        local function PRow(i)
            if pRows[i] then return pRows[i] end
            local r = CreateFrame("Button", nil, pBody)
            Size(r, 444, 24)
            r:SetPoint("TOPLEFT", 0, -(i - 1) * 25)
            r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            r.icon = r:CreateTexture(nil, "ARTWORK")
            Size(r.icon, 20, 20)
            r.icon:SetPoint("LEFT", 2, 0)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            r.name:SetWidth(280)
            r.name:SetJustifyH("LEFT")
            r.info = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r.info:SetPoint("RIGHT", -6, 0)
            r:SetScript("OnLeave", function() GameTooltip:Hide() end)
            pRows[i] = r
            return r
        end

        local function Selected() return selected and skills.byKey[selected] end

        -- a pouch gem into the chosen skill's first free open link
        local function Link(g)
            local s = Selected()
            if not s then UIErrorsFrame:AddMessage("Choose a skill first (the list on the left).", 1, 0.2, 0.2) return end
            for i = 1, s.open do
                if not s.links[i] then Send(string.format("QS:%d:%d:%d", s.key, i - 1, g.id)) return end
            end
            if s.open == 0 then
                UIErrorsFrame:AddMessage(string.format("%s has no links open yet: the first opens at skill level %d.", SkillName(s), skills.linkAt[1] or 5), 1, 0.2, 0.2)
            else
                UIErrorsFrame:AddMessage("Every open link has a gem: right-click one to take it out first.", 1, 0.2, 0.2)
            end
        end

        StaticPopupDialogs["WORLDTIERS_SKILL_BANK"] = {
            text = "Give skill experience from your bank (%s) to %s. How much?",
            button1 = ACCEPT or "Accept", button2 = CANCEL,
            hasEditBox = 1, maxLetters = 18,
            OnShow = function(self) local e = _G[self:GetName() .. "EditBox"] if e then e:SetText(tostring(skills.bank)) e:SetFocus() e:HighlightText() end end,
            OnAccept = function(self, data)
                local e = _G[self:GetName() .. "EditBox"]
                local n = tonumber(e and e:GetText() or "")
                if n and n > 0 and data then Send(string.format("QX:%d:%d", data, math.floor(n))) end
            end,
            EditBoxOnEnterPressed = function(self)
                local parent = self:GetParent()
                local n = tonumber(self:GetText())
                if n and n > 0 and parent.data then Send(string.format("QX:%d:%d", parent.data, math.floor(n))) end
                parent:Hide()
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0, whileDead = 1, hideOnEscape = 1,
        }
        StaticPopupDialogs["WORLDTIERS_LINKING_ORB"] = {
            text = "Use a Linking Orb on %s? It opens a sixth support link for good.",
            button1 = YES, button2 = NO,
            OnAccept = function(self, data) if data then Send("QL:" .. data) end end,
            timeout = 0, whileDead = 1, hideOnEscape = 1,
        }

        orbB:SetScript("OnClick", function()
            local s = Selected()
            if not s then return end
            local d = StaticPopup_Show("WORLDTIERS_LINKING_ORB", SkillName(s))
            if d then d.data = s.key end
        end)
        local function TipOn(w, fn)
            w:SetScript("OnEnter", function(self) local t, x = fn() if t then Tip(self, t, x) end end)
            w:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        TipOn(orbB, function() return "Linking Orb", string.format("You have %d. Opens a sixth support link on the chosen skill. Raid and world bosses and Tier Keys drop them.", skills.orbs) end)
        bankB:SetScript("OnClick", function()
            local s = Selected()
            if not s then return end
            local d = StaticPopup_Show("WORLDTIERS_SKILL_BANK", tostring(skills.bank), SkillName(s))
            if d then d.data = s.key end
        end)
        TipOn(bankB, function() return "Skill bank", "Skill experience you can give any skill: Paragon experience once your board is complete, and the old board's mastery nodes." end)

        for i, b in ipairs(slots) do
            b:SetScript("OnEnter", function(self)
                local s = Selected()
                if not s then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local g = s.links[i]
                if g then
                    WT.GemTooltip(GameTooltip, g, "Right-click: take it out (back to your pouch). Left-click: more.")
                elseif i <= s.open then
                    GameTooltip:SetText("An open link", 1, 0.82, 0)
                    GameTooltip:AddLine("Click a gem in your pouch below to put it here.", 1, 1, 1, true)
                elseif i == 6 then
                    GameTooltip:SetText("The sixth link", 1, 0.82, 0)
                    GameTooltip:AddLine("A Linking Orb opens it.", 1, 1, 1, true)
                else
                    GameTooltip:SetText("A closed link", 1, 0.82, 0)
                    GameTooltip:AddLine(string.format("Opens at skill level %d.", skills.linkAt[i] or 0), 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            b:SetScript("OnClick", function(self, button)
                local s = Selected()
                if not s then return end
                local g = s.links[i]
                if button == "RightButton" then
                    if g then Send(string.format("QU:%d:%d", s.key, i - 1)) end
                    return
                end
                local menu = {}
                if g then
                    menu[#menu + 1] = { text = WT.GemName(g.gem, g.awk), isTitle = true, notCheckable = true }
                    menu[#menu + 1] = { text = "Take it out", notCheckable = true, func = function() Send(string.format("QU:%d:%d", s.key, i - 1)) end }
                    menu[#menu + 1] = { text = string.format("Gemcutter's Shard: +2%% quality (%d)", skills.shards), notCheckable = true,
                        disabled = skills.shards == 0 or g.quality >= 20, func = function() Send(string.format("QQ:%d:%d", s.key, i - 1)) end }
                elseif i <= s.open then
                    menu[#menu + 1] = { text = "Link a gem", isTitle = true, notCheckable = true }
                    for _, pg in ipairs(skills.pouch) do
                        local pick = pg
                        menu[#menu + 1] = { text = string.format("%s (%d)", WT.GemName(pg.gem, pg.awk), pg.level), notCheckable = true,
                            func = function() Send(string.format("QS:%d:%d:%d", s.key, i - 1, pick.id)) end }
                        if #menu > 30 then break end
                    end
                    if #menu == 1 then menu[2] = { text = "Your gem pouch is empty.", notCheckable = true, disabled = true } end
                elseif i == 6 and skills.orbs > 0 then
                    menu[#menu + 1] = { text = "Use a Linking Orb", notCheckable = true, func = function() orbB:Click() end }
                else
                    return
                end
                EasyMenu(menu, slotMenu, self, 0, 0, "MENU")
            end)
        end

        function WT.RefreshSkillsPage()
            if not page:IsShown() then return end
            if not selected or not skills.byKey[selected] then selected = skills.list[1] and skills.list[1].key end
            -- the list
            for i, s in ipairs(skills.list) do
                local r = Row(i)
                r.key = s.key
                r.icon:SetTexture(SkillIcon(s))
                r.name:SetText(SkillName(s))
                r.origin:SetText(OriginText(s))
                local n = 0
                for _ in pairs(s.links) do n = n + 1 end
                r.links:SetText(s.open > 0 and string.format("|cff66ccff%d/%d|r", n, s.open) or "")
                r.level:SetText(tostring(s.level))
                if s.key == selected then r.sel:Show() else r.sel:Hide() end
                r:Show()
            end
            for i = #skills.list + 1, #rows do rows[i]:Hide() end
            body:SetHeight(math.max(400, #skills.list * 33))
            listS.header:SetText(string.format("Skills (%d)", #skills.list))
            -- the chosen one
            local s = Selected()
            if s then
                dIcon:SetTexture(SkillIcon(s))
                dName:SetText(SkillName(s))
                detail.note:SetWidth(300)
                detail.note:SetJustifyH("RIGHT")
                detail.note:SetText(OriginText(s))
                local nextAt = NextLinkAt(s)
                dLevel:SetText(string.format("Level %d%s  -  |cff1eff00%s%% more damage|r from its levels%s", s.level,
                    s.eff ~= s.level and string.format(" (|cff66ccff%d|r with supports)", s.eff) or "", Num(MoreFromLevels(s.eff)),
                    nextAt and string.format("\nNext support link at level %d.", nextAt) or ""))
                bar:SetMinMaxValues(0, math.max(1, s.need))
                bar:SetValue(s.xp)
                barText:SetText(string.format("%d / %d", s.xp, s.need))
                bar:Show()
                for i, b in ipairs(slots) do
                    local g = s.links[i]
                    if g then
                        b.icon:SetTexture(WT.GemIcon(g.gem, g.awk))
                        b.icon:SetDesaturated(false)
                        b.icon:Show()
                        b.lock:SetText("")
                        b.label:SetText(string.format("%s\n%d", WT.GemName(g.gem, g.awk), g.level))
                    elseif i <= s.open then
                        b.icon:Hide()
                        b.lock:SetText("|cff66ccffopen|r")
                        b.label:SetText("")
                    else
                        b.icon:Hide()
                        b.lock:SetText(i == 6 and "orb" or ("Lv " .. (skills.linkAt[i] or "?")))
                        b.label:SetText("")
                    end
                end
                orbB:SetText(string.format("Linking Orb (%d)", skills.orbs))
                if skills.orbs > 0 and s.open < 6 and s.open >= 0 and not (s.links[6]) then orbB:Enable() else orbB:Disable() end
                bankB:SetText(string.format("Bank: %s", skills.bank >= 1000000 and string.format("%.1fM", skills.bank / 1000000)
                    or skills.bank >= 1000 and string.format("%.1fk", skills.bank / 1000) or tostring(skills.bank)))
                if skills.bank > 0 then bankB:Enable() else bankB:Disable() end
            else
                dName:SetText("No skills yet")
                detail.note:SetText("")
                dLevel:SetText("Use your abilities: every one that deals damage or heals levels as you kill.")
                bar:Hide()
            end
            -- the pouch, then gems that are items in your bags
            local i = 0
            for _, g in ipairs(skills.pouch) do
                i = i + 1
                local r = PRow(i)
                local gem = g
                r.icon:SetTexture(WT.GemIcon(g.gem, g.awk))
                r.name:SetText(WT.GemName(g.gem, g.awk))
                r.info:SetText(string.format("level %d%s", g.level, g.quality > 0 and string.format("  |cff66ccff%d%%|r", g.quality) or ""))
                r:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local d = WT.GEMS[gem.gem]
                    WT.GemTooltip(GameTooltip, gem, "Click: link it to the chosen skill." ..
                        ((not gem.awk and d and d.rarity < 3) and " Right-click: take it out as an item (to trade)." or ""))
                    GameTooltip:Show()
                end)
                r:SetScript("OnClick", function(self, button)
                    if button == "RightButton" then
                        local d = WT.GEMS[gem.gem]
                        if gem.awk or (d and d.rarity >= 3) then
                            UIErrorsFrame:AddMessage("Rare and Awakened gems are bound to you: they stay in your pouch.", 1, 0.2, 0.2)
                        else
                            EasyMenu({ { text = WT.GemName(gem.gem, gem.awk), isTitle = true, notCheckable = true },
                                { text = "Take it out as an item (to trade)", notCheckable = true, func = function() Send("QO:" .. gem.id) end } },
                                gemMenu, self, 0, 0, "MENU")
                        end
                    else
                        Link(gem)
                    end
                end)
                r:Show()
            end
            for _, g in ipairs(skills.bags) do
                i = i + 1
                local r = PRow(i)
                local gem = g
                r.icon:SetTexture(WT.GemIcon(g.gem, g.awk))
                r.name:SetText(WT.GemName(g.gem, g.awk) .. " |cff888888(in your bags)|r")
                r.info:SetText("|cff66ccffclick: into the pouch|r")
                r:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    WT.GemTooltip(GameTooltip, gem, "Click: put it in your gem pouch.")
                    GameTooltip:Show()
                end)
                r:SetScript("OnClick", function() Send(string.format("QD:%d:%d", gem.bag, gem.slot)) end)
                r:Show()
            end
            for j = i + 1, #pRows do pRows[j]:Hide() end
            pBody:SetHeight(math.max(200, i * 25))
            pouchS.header:SetText(string.format("Gem pouch (%d)", #skills.pouch))
            pouchS.note:SetText(i == 0 and "Gems drop from tougher enemies, bosses, Tier Keys and treasure." or "")
        end

        page:SetScript("OnShow", function() Send("QR") WT.RefreshSkillsPage() end)
        -- loot changes the bags (a gem item moved): ask again while the page is open
        local watch = CreateFrame("Frame", nil, page)
        watch:RegisterEvent("BAG_UPDATE")
        local dueAt
        watch:SetScript("OnEvent", function() if page:IsShown() then dueAt = GetTime() + 1 end end)
        watch:SetScript("OnUpdate", function() if dueAt and GetTime() >= dueAt then dueAt = nil Send("QR") end end)
    end

    -- =======================================================================
    -- The Keystones page
    -- =======================================================================
    function WT.BuildKeystonesPage(page, H)
        local Section, Button = H.Section, H.Button
        local s = Section(16, -60, 788, 516, "Keystones", page)
        local info = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        info:SetPoint("TOPLEFT", 14, -36)
        info:SetWidth(740)
        info:SetHeight(48)
        info:SetJustifyV("TOP")
        info:SetJustifyH("LEFT")
        local scroll = CreateFrame("ScrollFrame", "WorldTiersKeystonesScroll", s, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 8, -88)   -- below the two or three lines of text
        scroll:SetPoint("BOTTOMRIGHT", -28, 44)
        local body = CreateFrame("Frame", nil, scroll)
        Size(body, 740, 400)
        scroll:SetScrollChild(body)
        local cards = {}
        local auraB = Button(s, 220, 22, "Keystone auras: on")
        auraB:SetPoint("BOTTOMLEFT", 12, 12)
        auraB:SetScript("OnClick", function() Send("KT") end)
        local boardB = Button(s, 160, 22, "Open the board")
        boardB:SetPoint("LEFT", auraB, "RIGHT", 8, 0)
        boardB:SetScript("OnClick", function() if WT.hubShowPage then WT.hubShowPage("paragon") end end)
        local foot = s:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        foot:SetPoint("LEFT", boardB, "RIGHT", 10, 0)
        foot:SetWidth(360)
        foot:SetJustifyH("LEFT")

        local function Card(i)
            if cards[i] then return cards[i] end
            local c = CreateFrame("Button", nil, body)
            Size(c, 364, 58)
            c:SetPoint("TOPLEFT", ((i - 1) % 2) * 372, -math.floor((i - 1) / 2) * 62)
            c:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                tile = true, tileSize = 16, edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
            c.icon = c:CreateTexture(nil, "ARTWORK")
            Size(c.icon, 36, 36)
            c.icon:SetPoint("LEFT", 10, 0)
            c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, 2)
            c.name:SetWidth(250)
            c.name:SetJustifyH("LEFT")
            c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            c.text:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -2)
            c.text:SetWidth(250)
            c.text:SetHeight(28)
            c.text:SetJustifyH("LEFT")
            c.text:SetJustifyV("TOP")
            c.check = CreateFrame("CheckButton", nil, c, "UICheckButtonTemplate")
            c.check:SetPoint("RIGHT", -6, 0)
            c:SetScript("OnLeave", function() GameTooltip:Hide() end)
            cards[i] = c
            return c
        end

        function WT.RefreshKeystonesPage()
            if not page:IsShown() then return end
            local owned, seen = {}, {}
            for id in pairs(WT.taken) do
                local cell = G.Cell(id)
                local k = cell.kind == 3 and WT.keystones[cell.keystone]
                if k and not seen[k.ks] then seen[k.ks] = true owned[#owned + 1] = k end
            end
            table.sort(owned, function(a, b)
                local ao, bo = WT.activeKs[a.ks] and 1 or 0, WT.activeKs[b.ks] and 1 or 0
                if ao ~= bo then return ao > bo end
                return (a.name or "") < (b.name or "")
            end)
            local sig
            for _, k in pairs(WT.keystones) do if WT.signatureKs and WT.signatureKs > 0 and k.ks == WT.signatureKs then sig = k end end
            info:SetText(string.format("|cffffd100%d of %d|r keystone slots in use. You own %d keystone%s on your board; switch on the ones you want. "
                .. "More slots open at Paragon 100, 250, 500 and 1000 (7 at most).%s", WT.ActiveCount(), WT.ksSlots or 3, #owned,
                #owned == 1 and "" or "s", sig and ("\nSignature Keystone (always on, its own slot): |cffff8000" .. sig.name .. "|r") or ""))
            for i, k in ipairs(owned) do
                local c = Card(i)
                local ks, on = k.ks, WT.activeKs[k.ks] and true or false
                c.icon:SetTexture("Interface\\Icons\\" .. (k.icon or "INV_Misc_QuestionMark"))
                c.icon:SetDesaturated(not on)
                c.name:SetText(on and ("|cff1eff00" .. k.name .. "|r") or k.name)
                c.text:SetText(k.text or "")
                c.check:SetChecked(on)
                c:SetBackdropColor(on and 0.05 or 0.03, on and 0.12 or 0.03, on and 0.05 or 0.05, 0.9)
                c:SetBackdropBorderColor(on and 0.3 or 0.4, on and 0.8 or 0.35, on and 0.3 or 0.25, 0.9)
                local toggle = function() Send((on and "KD:" or "KA:") .. ks) end
                c.check:SetScript("OnClick", function(self) self:SetChecked(on) toggle() end)
                c:SetScript("OnClick", toggle)
                c:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(k.name, 1, 0.82, 0)
                    GameTooltip:AddLine(k.text or "", 1, 1, 1, true)
                    GameTooltip:AddLine(on and "Active: click to switch it off." or "Click to switch it on.", 0.5, 0.8, 1)
                    GameTooltip:Show()
                end)
                c:Show()
            end
            for i = #owned + 1, #cards do cards[i]:Hide() end
            body:SetHeight(math.max(400, math.ceil(#owned / 2) * 62))
            if #owned == 0 then foot:SetText("No keystones yet: they sit at the end of each branch on the Paragon Board.") else foot:SetText("") end
            auraB:SetText(WT.ksAuras ~= false and "Keystone auras: on" or "Keystone auras: off")
        end
        -- the keystone state arrives (KA): the page follows
        local oldRefresh = WT.RefreshKeystoneButton
        WT.RefreshKeystoneButton = function(...)
            if oldRefresh then oldRefresh(...) end
            if WT.RefreshKeystonesPage then WT.RefreshKeystonesPage() end
        end
        page:SetScript("OnShow", function()
            Send("T")   -- the board and keystones, fresh
            WT.RefreshKeystonesPage()
        end)
        local wait = CreateFrame("Frame", nil, page)
        local last = 0
        wait:SetScript("OnUpdate", function()
            if (WT.version or 0) ~= last then last = WT.version or 0 WT.RefreshKeystonesPage() end
        end)
    end

    -- =======================================================================
    -- The Paragon Board in its own tab: the board's window, held inside
    -- =======================================================================
    function WT.EmbedBoard(page)
        local board = _G.WorldTiersParagonFrame
        if not board then return end
        board:SetParent(page)
        board:ClearAllPoints()
        board:SetScale(0.8)
        board:SetPoint("TOPLEFT", page, "TOPLEFT", 16 / 0.8, -56 / 0.8)
        board:SetFrameStrata(page:GetFrameStrata())
        board:SetFrameLevel(page:GetFrameLevel() + 2)
        board:SetMovable(false)
        board.embedded = true
        board:Show()
    end
    function WT.UnembedBoard()
        local board = _G.WorldTiersParagonFrame
        if not board or not board.embedded then return end
        board.embedded = nil
        board:Hide()
        board:SetParent(UIParent)
        board:SetScale(1)
        board:ClearAllPoints()
        board:SetPoint("CENTER")
        board:SetFrameStrata("HIGH")
        board:SetMovable(true)
    end
end
-- Generated by tools/gen_skillgems.py: the skill gems (index -> base spell, class, level).
WT.SKILL_GEM_ITEM_FIRST = 993000
WT.SKILL_GEMS = {
    { 6673, 1, 1 },
    { 2457, 1, 1 },
    { 78, 1, 1 },
    { 100, 1, 4 },
    { 772, 1, 4 },
    { 6343, 1, 6 },
    { 34428, 1, 6 },
    { 1715, 1, 8 },
    { 2687, 1, 10 },
    { 7384, 1, 12 },
    { 72, 1, 12 },
    { 1160, 1, 14 },
    { 6572, 1, 14 },
    { 694, 1, 16 },
    { 2565, 1, 16 },
    { 676, 1, 18 },
    { 845, 1, 20 },
    { 12975, 1, 20 },
    { 12323, 1, 20 },
    { 20230, 1, 20 },
    { 5246, 1, 22 },
    { 5308, 1, 24 },
    { 1161, 1, 26 },
    { 871, 1, 28 },
    { 12809, 1, 30 },
    { 12292, 1, 30 },
    { 20252, 1, 30 },
    { 1464, 1, 30 },
    { 12328, 1, 30 },
    { 18499, 1, 32 },
    { 1680, 1, 36 },
    { 6552, 1, 38 },
    { 23881, 1, 40 },
    { 12294, 1, 40 },
    { 23922, 1, 40 },
    { 50720, 1, 40 },
    { 20243, 1, 50 },
    { 60970, 1, 50 },
    { 1719, 1, 50 },
    { 46924, 1, 60 },
    { 46968, 1, 60 },
    { 23920, 1, 64 },
    { 469, 1, 68 },
    { 3411, 1, 70 },
    { 64382, 1, 71 },
    { 55694, 1, 75 },
    { 57755, 1, 80 },
    { 465, 2, 1 },
    { 635, 2, 1 },
    { 20154, 2, 1 },
    { 19740, 2, 4 },
    { 20271, 2, 4 },
    { 498, 2, 6 },
    { 853, 2, 8 },
    { 1152, 2, 8 },
    { 1022, 2, 10 },
    { 633, 2, 10 },
    { 53408, 2, 12 },
    { 19742, 2, 14 },
    { 31789, 2, 14 },
    { 62124, 2, 16 },
    { 7294, 2, 16 },
    { 25780, 2, 16 },
    { 1044, 2, 18 },
    { 31821, 2, 20 },
    { 20217, 2, 20 },
    { 26573, 2, 20 },
    { 64205, 2, 20 },
    { 879, 2, 20 },
    { 19750, 2, 20 },
    { 20066, 2, 20 },
    { 20375, 2, 20 },
    { 5502, 2, 20 },
    { 34769, 2, 20 },
    { 13819, 2, 20 },
    { 19746, 2, 22 },
    { 20164, 2, 22 },
    { 7328, 2, 12 },
    { 10326, 2, 24 },
    { 1038, 2, 26 },
    { 53407, 2, 28 },
    { 19876, 2, 28 },
    { 20911, 2, 30 },
    { 20216, 2, 30 },
    { 19752, 2, 30 },
    { 20165, 2, 30 },
    { 19888, 2, 32 },
    { 642, 2, 34 },
    { 19891, 2, 36 },
    { 20166, 2, 38 },
    { 23214, 2, 40 },
    { 20925, 2, 40 },
    { 20473, 2, 40 },
    { 34767, 2, 40 },
    { 4987, 2, 42 },
    { 24275, 2, 44 },
    { 6940, 2, 46 },
    { 31935, 2, 50 },
    { 35395, 2, 50 },
    { 31842, 2, 50 },
    { 53595, 2, 50 },
    { 2812, 2, 50 },
    { 25782, 2, 52 },
    { 25894, 2, 54 },
    { 53563, 2, 60 },
    { 53385, 2, 60 },
    { 25898, 2, 60 },
    { 25899, 2, 60 },
    { 32223, 2, 62 },
    { 31801, 2, 64 },
    { 53736, 2, 66 },
    { 31884, 2, 70 },
    { 54428, 2, 71 },
    { 53600, 2, 75 },
    { 53601, 2, 80 },
    { 2973, 4, 1 },
    { 1494, 4, 1 },
    { 13163, 4, 4 },
    { 1978, 4, 4 },
    { 3044, 4, 6 },
    { 1130, 4, 6 },
    { 5116, 4, 8 },
    { 13165, 4, 10 },
    { 19883, 4, 10 },
    { 20736, 4, 12 },
    { 136, 4, 12 },
    { 2974, 4, 12 },
    { 6197, 4, 14 },
    { 1002, 4, 14 },
    { 1513, 4, 14 },
    { 19503, 4, 15 },
    { 5118, 4, 16 },
    { 13795, 4, 16 },
    { 1495, 4, 16 },
    { 2643, 4, 18 },
    { 19884, 4, 18 },
    { 19434, 4, 20 },
    { 34074, 4, 20 },
    { 781, 4, 20 },
    { 1499, 4, 20 },
    { 3043, 4, 22 },
    { 1462, 4, 24 },
    { 19885, 4, 24 },
    { 3045, 4, 26 },
    { 19880, 4, 26 },
    { 13809, 4, 28 },
    { 13161, 4, 30 },
    { 19306, 4, 30 },
    { 5384, 4, 30 },
    { 19577, 4, 30 },
    { 23989, 4, 30 },
    { 34490, 4, 30 },
    { 1543, 4, 32 },
    { 19878, 4, 32 },
    { 13813, 4, 34 },
    { 3034, 4, 36 },
    { 13159, 4, 40 },
    { 19574, 4, 40 },
    { 19882, 4, 40 },
    { 19506, 4, 40 },
    { 1510, 4, 40 },
    { 19386, 4, 40 },
    { 20043, 4, 46 },
    { 3674, 4, 50 },
    { 56641, 4, 50 },
    { 19879, 4, 50 },
    { 53209, 4, 60 },
    { 53301, 4, 60 },
    { 19801, 4, 60 },
    { 34026, 4, 66 },
    { 34600, 4, 68 },
    { 34477, 4, 70 },
    { 61846, 4, 74 },
    { 61005, 4, 75 },
    { 62757, 4, 80 },
    { 60192, 4, 80 },
    { 2098, 8, 1 },
    { 1804, 8, 1 },
    { 1752, 8, 1 },
    { 1784, 8, 1 },
    { 53, 8, 4 },
    { 921, 8, 4 },
    { 1776, 8, 6 },
    { 5277, 8, 8 },
    { 6770, 8, 10 },
    { 5171, 8, 10 },
    { 2983, 8, 10 },
    { 1766, 8, 12 },
    { 8647, 8, 14 },
    { 703, 8, 14 },
    { 1966, 8, 16 },
    { 8676, 8, 18 },
    { 51722, 8, 20 },
    { 14278, 8, 20 },
    { 14183, 8, 20 },
    { 14251, 8, 20 },
    { 1943, 8, 20 },
    { 1725, 8, 22 },
    { 1856, 8, 22 },
    { 1833, 8, 26 },
    { 13877, 8, 30 },
    { 14177, 8, 30 },
    { 1842, 8, 30 },
    { 16511, 8, 30 },
    { 408, 8, 30 },
    { 14185, 8, 30 },
    { 2094, 8, 34 },
    { 13750, 8, 40 },
    { 1329, 8, 40 },
    { 36554, 8, 50 },
    { 51662, 8, 60 },
    { 51690, 8, 60 },
    { 51713, 8, 60 },
    { 32645, 8, 62 },
    { 26679, 8, 64 },
    { 31224, 8, 66 },
    { 5938, 8, 70 },
    { 57934, 8, 75 },
    { 51723, 8, 80 },
    { 2050, 16, 1 },
    { 1243, 16, 1 },
    { 585, 16, 1 },
    { 589, 16, 4 },
    { 17, 16, 6 },
    { 586, 16, 8 },
    { 139, 16, 8 },
    { 8092, 16, 10 },
    { 2006, 16, 10 },
    { 588, 16, 12 },
    { 528, 16, 14 },
    { 8122, 16, 14 },
    { 2054, 16, 16 },
    { 527, 16, 18 },
    { 19236, 16, 20 },
    { 2944, 16, 20 },
    { 6346, 16, 20 },
    { 2061, 16, 20 },
    { 14914, 16, 20 },
    { 15237, 16, 20 },
    { 14751, 16, 20 },
    { 15407, 16, 20 },
    { 453, 16, 20 },
    { 9484, 16, 20 },
    { 2096, 16, 22 },
    { 8129, 16, 24 },
    { 14752, 16, 30 },
    { 605, 16, 30 },
    { 596, 16, 30 },
    { 976, 16, 30 },
    { 15487, 16, 30 },
    { 15286, 16, 30 },
    { 552, 16, 32 },
    { 1706, 16, 34 },
    { 2060, 16, 40 },
    { 724, 16, 40 },
    { 10060, 16, 40 },
    { 15473, 16, 40 },
    { 21562, 16, 48 },
    { 34861, 16, 50 },
    { 33206, 16, 50 },
    { 64044, 16, 50 },
    { 34914, 16, 50 },
    { 27683, 16, 56 },
    { 47585, 16, 60 },
    { 47788, 16, 60 },
    { 47540, 16, 60 },
    { 27681, 16, 60 },
    { 32379, 16, 62 },
    { 32546, 16, 64 },
    { 34433, 16, 66 },
    { 33076, 16, 68 },
    { 32375, 16, 70 },
    { 48045, 16, 75 },
    { 64843, 16, 80 },
    { 63560, 32, 26 },
    { 49222, 32, 45 },
    { 51271, 32, 45 },
    { 55233, 32, 45 },
    { 51052, 32, 55 },
    { 48266, 32, 55 },
    { 45902, 32, 55 },
    { 49158, 32, 55 },
    { 49028, 32, 55 },
    { 47541, 32, 55 },
    { 49576, 32, 55 },
    { 49796, 32, 55 },
    { 49143, 32, 55 },
    { 55050, 32, 55 },
    { 49184, 32, 55 },
    { 49203, 32, 55 },
    { 49016, 32, 55 },
    { 45477, 32, 55 },
    { 49039, 32, 55 },
    { 49005, 32, 55 },
    { 45462, 32, 55 },
    { 48982, 32, 55 },
    { 55090, 32, 55 },
    { 49206, 32, 55 },
    { 49998, 32, 56 },
    { 50842, 32, 56 },
    { 46584, 32, 56 },
    { 48263, 32, 57 },
    { 47528, 32, 57 },
    { 48721, 32, 58 },
    { 45524, 32, 58 },
    { 47476, 32, 59 },
    { 43265, 32, 60 },
    { 49020, 32, 61 },
    { 48792, 32, 62 },
    { 45529, 32, 64 },
    { 48743, 32, 66 },
    { 48707, 32, 68 },
    { 48265, 32, 70 },
    { 47568, 32, 75 },
    { 42650, 32, 80 },
    { 331, 64, 1 },
    { 403, 64, 1 },
    { 8017, 64, 1 },
    { 8042, 64, 4 },
    { 2484, 64, 6 },
    { 324, 64, 8 },
    { 5730, 64, 8 },
    { 8050, 64, 10 },
    { 8024, 64, 10 },
    { 8075, 64, 10 },
    { 2008, 64, 12 },
    { 1535, 64, 12 },
    { 370, 64, 12 },
    { 8071, 64, 4 },
    { 2645, 64, 16 },
    { 57994, 64, 16 },
    { 8143, 64, 18 },
    { 8056, 64, 20 },
    { 8033, 64, 20 },
    { 8004, 64, 20 },
    { 3599, 64, 10 },
    { 55198, 64, 20 },
    { 131, 64, 22 },
    { 8181, 64, 24 },
    { 6196, 64, 26 },
    { 8190, 64, 26 },
    { 5675, 64, 26 },
    { 8184, 64, 28 },
    { 8227, 64, 28 },
    { 546, 64, 28 },
    { 556, 64, 30 },
    { 8177, 64, 30 },
    { 5394, 64, 20 },
    { 10595, 64, 30 },
    { 16188, 64, 30 },
    { 36936, 64, 30 },
    { 8232, 64, 30 },
    { 421, 64, 32 },
    { 8512, 64, 32 },
    { 6495, 64, 34 },
    { 8170, 64, 38 },
    { 1064, 64, 40 },
    { 51886, 64, 40 },
    { 16166, 64, 40 },
    { 16190, 64, 40 },
    { 17364, 64, 40 },
    { 60103, 64, 41 },
    { 974, 64, 50 },
    { 51533, 64, 50 },
    { 30823, 64, 50 },
    { 30706, 64, 50 },
    { 61295, 64, 60 },
    { 51490, 64, 60 },
    { 24398, 64, 62 },
    { 3738, 64, 64 },
    { 2062, 64, 66 },
    { 2825, 64, 70 },
    { 32182, 64, 70 },
    { 60043, 64, 80 },
    { 1459, 128, 1 },
    { 133, 128, 1 },
    { 168, 128, 1 },
    { 5504, 128, 4 },
    { 116, 128, 4 },
    { 587, 128, 6 },
    { 2136, 128, 6 },
    { 5143, 128, 8 },
    { 118, 128, 8 },
    { 122, 128, 10 },
    { 604, 128, 12 },
    { 130, 128, 12 },
    { 1449, 128, 14 },
    { 2120, 128, 16 },
    { 1008, 128, 18 },
    { 475, 128, 18 },
    { 1953, 128, 20 },
    { 10, 128, 20 },
    { 543, 128, 20 },
    { 54646, 128, 20 },
    { 12472, 128, 20 },
    { 1463, 128, 20 },
    { 11366, 128, 20 },
    { 32271, 128, 20 },
    { 3562, 128, 20 },
    { 3567, 128, 20 },
    { 32272, 128, 20 },
    { 3561, 128, 20 },
    { 3563, 128, 20 },
    { 6143, 128, 22 },
    { 2948, 128, 22 },
    { 2139, 128, 24 },
    { 120, 128, 26 },
    { 759, 128, 28 },
    { 11113, 128, 30 },
    { 11958, 128, 30 },
    { 7302, 128, 30 },
    { 45438, 128, 30 },
    { 12043, 128, 30 },
    { 3565, 128, 30 },
    { 3566, 128, 30 },
    { 6117, 128, 34 },
    { 49361, 128, 35 },
    { 49360, 128, 35 },
    { 49358, 128, 35 },
    { 49359, 128, 35 },
    { 12042, 128, 40 },
    { 11129, 128, 40 },
    { 11426, 128, 40 },
    { 32266, 128, 40 },
    { 11416, 128, 40 },
    { 11417, 128, 40 },
    { 32267, 128, 40 },
    { 10059, 128, 40 },
    { 11418, 128, 40 },
    { 31661, 128, 50 },
    { 11419, 128, 50 },
    { 11420, 128, 50 },
    { 31589, 128, 50 },
    { 31687, 128, 50 },
    { 23028, 128, 56 },
    { 44425, 128, 60 },
    { 44572, 128, 60 },
    { 44457, 128, 60 },
    { 33690, 128, 60 },
    { 30482, 128, 62 },
    { 30451, 128, 64 },
    { 33691, 128, 65 },
    { 30455, 128, 66 },
    { 43987, 128, 70 },
    { 53140, 128, 71 },
    { 53142, 128, 74 },
    { 42955, 128, 75 },
    { 44614, 128, 75 },
    { 55342, 128, 80 },
    { 687, 256, 1 },
    { 348, 256, 1 },
    { 686, 256, 1 },
    { 688, 256, 1 },
    { 172, 256, 4 },
    { 702, 256, 4 },
    { 1454, 256, 6 },
    { 980, 256, 8 },
    { 5782, 256, 8 },
    { 6201, 256, 10 },
    { 1120, 256, 10 },
    { 755, 256, 12 },
    { 689, 256, 14 },
    { 5697, 256, 16 },
    { 693, 256, 18 },
    { 5676, 256, 18 },
    { 706, 256, 20 },
    { 18708, 256, 20 },
    { 5784, 256, 20 },
    { 5740, 256, 20 },
    { 698, 256, 20 },
    { 17877, 256, 20 },
    { 19028, 256, 20 },
    { 126, 256, 22 },
    { 5138, 256, 24 },
    { 5500, 256, 24 },
    { 1714, 256, 26 },
    { 132, 256, 26 },
    { 710, 256, 28 },
    { 6366, 256, 28 },
    { 18223, 256, 30 },
    { 47193, 256, 30 },
    { 1098, 256, 30 },
    { 1949, 256, 30 },
    { 1490, 256, 32 },
    { 6229, 256, 32 },
    { 2362, 256, 36 },
    { 17962, 256, 40 },
    { 18220, 256, 40 },
    { 23161, 256, 40 },
    { 5484, 256, 40 },
    { 6789, 256, 42 },
    { 6353, 256, 48 },
    { 30283, 256, 50 },
    { 30146, 256, 50 },
    { 30108, 256, 50 },
    { 50796, 256, 60 },
    { 603, 256, 60 },
    { 48181, 256, 60 },
    { 28176, 256, 62 },
    { 29722, 256, 64 },
    { 29858, 256, 66 },
    { 29893, 256, 68 },
    { 27243, 256, 70 },
    { 47897, 256, 75 },
    { 48018, 256, 80 },
    { 48020, 256, 80 },
    { 5185, 1024, 1 },
    { 1126, 1024, 1 },
    { 5176, 1024, 1 },
    { 8921, 1024, 4 },
    { 774, 1024, 4 },
    { 467, 1024, 6 },
    { 339, 1024, 8 },
    { 99, 1024, 10 },
    { 16689, 1024, 10 },
    { 5229, 1024, 12 },
    { 8936, 1024, 12 },
    { 5211, 1024, 14 },
    { 1066, 1024, 16 },
    { 779, 1024, 16 },
    { 783, 1024, 16 },
    { 770, 1024, 18 },
    { 16857, 1024, 18 },
    { 2637, 1024, 18 },
    { 6807, 1024, 10 },
    { 768, 1024, 20 },
    { 1082, 1024, 20 },
    { 5570, 1024, 20 },
    { 5215, 1024, 20 },
    { 20484, 1024, 20 },
    { 1079, 1024, 20 },
    { 2912, 1024, 20 },
    { 61336, 1024, 20 },
    { 5221, 1024, 22 },
    { 2908, 1024, 22 },
    { 1822, 1024, 24 },
    { 2782, 1024, 24 },
    { 5217, 1024, 24 },
    { 2893, 1024, 26 },
    { 1850, 1024, 26 },
    { 5209, 1024, 28 },
    { 8998, 1024, 28 },
    { 17116, 1024, 30 },
    { 740, 1024, 30 },
    { 22568, 1024, 32 },
    { 6785, 1024, 32 },
    { 5225, 1024, 32 },
    { 22842, 1024, 36 },
    { 9005, 1024, 36 },
    { 9634, 1024, 40 },
    { 16914, 1024, 40 },
    { 29166, 1024, 40 },
    { 24858, 1024, 40 },
    { 18562, 1024, 40 },
    { 22812, 1024, 44 },
    { 33831, 1024, 50 },
    { 21849, 1024, 50 },
    { 50516, 1024, 50 },
    { 33986, 1024, 58 },
    { 33982, 1024, 58 },
    { 50334, 1024, 60 },
    { 33943, 1024, 60 },
    { 48505, 1024, 60 },
    { 48438, 1024, 60 },
    { 22570, 1024, 62 },
    { 33763, 1024, 64 },
    { 33745, 1024, 66 },
    { 33786, 1024, 70 },
    { 40120, 1024, 70 },
    { 62078, 1024, 71 },
    { 52610, 1024, 75 },
    { 50464, 1024, 80 },
    { 71, 1, 10 },
    { 7386, 1, 10 },
    { 355, 1, 10 },
    { 2458, 1, 30 },
    { 883, 4, 10 },
    { 2641, 4, 10 },
    { 6991, 4, 10 },
    { 982, 4, 10 },
    { 1515, 4, 10 },
    { 48778, 32, 55 },
    { 697, 256, 10 },
    { 712, 256, 20 },
    { 691, 256, 30 },
    { 1122, 256, 50 },
    { 18540, 256, 60 },
    { 5487, 1024, 10 },
    { 6795, 1024, 10 },
    { 8946, 1024, 14 },
}

-- ---------------------------------------------------------------------------
-- The Skill Gems tab (0.40, classless): every class skill is a gem. You know
-- the skills in your skill slots; the rest wait in your skill gem pouch.
-- The server sends MH (slots), MS (socketed), MP (pouch), MB (gem items in
-- the bags), ME (done).
-- ---------------------------------------------------------------------------

do
    local CLASSES = { [1] = { "Warrior", "C79C6E" }, [2] = { "Paladin", "F58CBA" }, [4] = { "Hunter", "ABD473" },
        [8] = { "Rogue", "FFF569" }, [16] = { "Priest", "FFFFFF" }, [32] = { "Death Knight", "C41F3B" },
        [64] = { "Shaman", "0070DE" }, [128] = { "Mage", "69CCF0" }, [256] = { "Warlock", "9482C9" }, [1024] = { "Druid", "FF7D0A" } }
    local gems = { open = 0, max = 24, nextAt = 0, slots = {}, pouch = {}, bags = {}, loaded = false }
    local pending
    local picked   -- the pouch gem chosen to go into a slot

    local function Def(gem) return WT.SKILL_GEMS and WT.SKILL_GEMS[gem] end
    local function Spell(gem) local d = Def(gem) return d and d[1] end
    local function GemInfo(gem)
        local d = Def(gem)
        if not d then return "?", "Interface\\Icons\\INV_Misc_QuestionMark", "", 1 end
        local name, _, icon = GetSpellInfo(d[1])
        local c = CLASSES[d[2]]
        return name or ("Skill " .. gem), icon or "Interface\\Icons\\INV_Misc_QuestionMark",
            c and ("|cff" .. c[2] .. c[1] .. "|r") or "", d[3]
    end
    WT.SkillGemInfo = GemInfo

    function WT.OnSkillGemMessage(msg)
        local cmd, rest = msg:match("^(M%u)|(.*)$")
        if not cmd then return false end
        if cmd == "MH" then
            local f = Split(rest, "|")
            pending = { open = tonumber(f[1]) or 0, max = tonumber(f[2]) or 24, nextAt = tonumber(f[3]) or 0, slots = {}, pouch = {}, bags = {}, req = {} }
        elseif pending and cmd == "MS" then
            for one in rest:gmatch("([^~]+)") do
                local p = Split(one, "^")
                pending.slots[(tonumber(p[1]) or 0) + 1] = tonumber(p[2])
                pending.req[(tonumber(p[1]) or 0) + 1] = { text = p[3] or "", met = p[4] ~= "0" }   -- 0.47: what it needs
            end
        elseif pending and cmd == "MP" then
            for one in rest:gmatch("([^~]+)") do
                local p = Split(one, "^")
                pending.pouch[#pending.pouch + 1] = { id = tonumber(p[1]) or 0, gem = tonumber(p[2]) or 0, req = p[3] or "", met = p[4] ~= "0" }
            end
        elseif pending and cmd == "MB" then
            for one in rest:gmatch("([^~]+)") do
                local p = Split(one, "^")
                pending.bags[#pending.bags + 1] = { bag = tonumber(p[1]) or 0, slot = tonumber(p[2]) or 0, gem = tonumber(p[3]) or 0 }
            end
        elseif pending and cmd == "ME" then
            gems.open, gems.max, gems.nextAt = pending.open, pending.max, pending.nextAt
            gems.slots, gems.pouch, gems.bags = pending.slots, pending.pouch, pending.bags
            gems.req = pending.req
            table.sort(gems.pouch, function(a, b)
                local da, db = Def(a.gem) or { 0, 0, 0 }, Def(b.gem) or { 0, 0, 0 }
                if da[2] ~= db[2] then return da[2] < db[2] end
                if da[3] ~= db[3] then return da[3] < db[3] end
                return (GemInfo(a.gem)) < (GemInfo(b.gem))
            end)
            gems.loaded = true
            pending = nil
            if picked then
                local still = false
                for _, g in ipairs(gems.pouch) do if g.id == picked then still = true end end
                if not still then picked = nil end
            end
            if WT.RefreshSkillGemsPage then WT.RefreshSkillGemsPage() end
        end
        return true
    end

    -- a skill gem item in the bags: what it is
    if hooksecurefunc and GameTooltip then hooksecurefunc(GameTooltip, "SetBagItem", function(tt, bag, slot)
        local link = GetContainerItemLink(bag, slot)
        local id = link and tonumber(link:match("item:(%d+)"))
        local first = WT.SKILL_GEM_ITEM_FIRST or 993000
        if not id or id <= first or not Def(id - first) then return end
        local gem = id - first
        local name, _, cls, level = GemInfo(gem)
        tt:AddLine(" ")
        tt:AddLine(string.format("Skill gem: %s (%s), from level %d", name, cls, level), 0.4, 0.8, 1, true)
        tt:AddLine("Put it in your skill gem pouch: World Tiers menu, Gems.", 0.5, 0.8, 1, true)
        tt:Show()
    end) end

    function WT.BuildSkillGemsPage(page, H)
        local Section = H.Section
        -- ---- the slots ----
        local slotS = Section(16, -60, 788, 168, "Skill slots", page)
        local help = slotS:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        help:SetPoint("TOPLEFT", 14, -36)
        help:SetWidth(760)
        help:SetJustifyH("LEFT")
        help:SetText("You know the skills in your slots, at the best rank your level allows, whatever your class. "
            .. "Click a gem in your pouch, then a slot, to put it there; shift-click a pouch gem for the first empty slot. "
            .. "Right-click a slot to take its gem out. Not in combat.")
        local slots = {}
        for i = 1, 24 do
            local b = CreateFrame("Button", nil, slotS)
            Size(b, 40, 40)
            b:SetPoint("TOPLEFT", 16 + ((i - 1) % 12) * 63, -70 - math.floor((i - 1) / 12) * 48)
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b.icon = b:CreateTexture(nil, "ARTWORK")
            b.icon:SetAllPoints()
            b.border = b:CreateTexture(nil, "OVERLAY")
            b.border:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            b.border:SetBlendMode("ADD")
            Size(b.border, 72, 72)
            b.border:SetPoint("CENTER")
            b.label = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            b.label:SetPoint("CENTER")
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            b.index = i
            b:SetScript("OnClick", function(self, button)
                local slot = self.index - 1
                if self.index > gems.open then
                    UIErrorsFrame:AddMessage("That skill slot isn't open yet.", 1, 0.2, 0.2)
                elseif button == "RightButton" then
                    if gems.slots[self.index] then Send("MU:" .. slot) end
                elseif picked then
                    Send(string.format("MS:%d:%d", picked, slot))
                    picked = nil
                end
            end)
            b:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local gem = gems.slots[self.index]
                if self.index > gems.open then
                    GameTooltip:SetText("Locked skill slot", 0.6, 0.6, 0.6)
                    GameTooltip:AddLine("Slots open as you level.", 1, 1, 1, true)
                elseif gem and Spell(gem) then
                    GameTooltip:SetHyperlink("spell:" .. Spell(gem))
                    local _, _, cls, level = GemInfo(gem)
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(string.format("%s skill gem, from level %d", cls, level), 0.4, 0.8, 1)
                    GameTooltip:AddLine("Right-click: back to your pouch.", 0.5, 0.8, 1)
                else
                    GameTooltip:SetText("Empty skill slot")
                    GameTooltip:AddLine(picked and "Click: put the chosen gem here." or "Click a gem in your pouch below, then this slot.", 1, 1, 1, true)
                end
                GameTooltip:Show()
            end)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            slots[i] = b
        end

        -- ---- the pouch ----
        local pouchS = Section(16, -234, 788, 342, "Skill gem pouch", page)
        local scroll = CreateFrame("ScrollFrame", "WorldTiersSkillGemScroll", pouchS, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 8, -34)
        scroll:SetPoint("BOTTOMRIGHT", -28, 8)
        local body = CreateFrame("Frame", nil, scroll)
        Size(body, 748, 300)
        scroll:SetScrollChild(body)
        local rows = {}
        local menu = CreateFrame("Frame", "WorldTiersSkillGemMenu", UIParent, "UIDropDownMenuTemplate")
        local function Row(i)
            if rows[i] then return rows[i] end
            local r = CreateFrame("Button", nil, body)
            Size(r, 370, 26)
            r:SetPoint("TOPLEFT", ((i - 1) % 2) * 376, -math.floor((i - 1) / 2) * 27)
            r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            r.sel = r:CreateTexture(nil, "BACKGROUND")
            r.sel:SetAllPoints()
            r.sel:SetTexture(0.2, 0.6, 1, 0.3)
            r.icon = r:CreateTexture(nil, "ARTWORK")
            Size(r.icon, 22, 22)
            r.icon:SetPoint("LEFT", 2, 0)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.name:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
            r.name:SetWidth(200)
            r.name:SetJustifyH("LEFT")
            r.info = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r.info:SetPoint("RIGHT", -6, 0)
            r:SetScript("OnLeave", function() GameTooltip:Hide() end)
            rows[i] = r
            return r
        end

        function WT.RefreshSkillGemsPage()
            if not page:IsShown() then return end
            local level = UnitLevel("player")
            for i, b in ipairs(slots) do
                local gem = gems.slots[i]
                if i > gems.open then
                    b.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
                    b.icon:SetDesaturated(true)
                    b.icon:SetVertexColor(0.4, 0.4, 0.4)
                    b.label:SetText("|cff888888locked|r")
                    b.border:Hide()
                elseif gem then
                    local _, icon, _, need = GemInfo(gem)
                    local req = gems.req and gems.req[i]
                    local short = req and not req.met and req.text ~= ""
                    b.icon:SetTexture(icon)
                    b.icon:SetDesaturated(need > level or short)
                    b.icon:SetVertexColor(1, short and 0.4 or 1, short and 0.4 or 1)
                    b.label:SetText(need > level and ("|cffff4040" .. need .. "|r") or short and ("|cffff4040" .. req.text .. "|r") or "")
                    b.border:Hide()
                else
                    b.icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
                    b.icon:SetDesaturated(false)
                    b.icon:SetVertexColor(1, 1, 1)
                    b.label:SetText("")
                    if picked then b.border:Show() else b.border:Hide() end
                end
            end
            slotS.header:SetText(string.format("Skill slots (%d open of %d)", gems.open, gems.max))
            slotS.note:SetText(gems.nextAt > 0 and string.format("next slot at level %d", gems.nextAt) or "")

            local i = 0
            for _, g in ipairs(gems.pouch) do
                i = i + 1
                local r = Row(i)
                local name, icon, cls, need = GemInfo(g.gem)
                r.icon:SetTexture(icon)
                r.name:SetText(name)
                local reqText = (g.req or "") ~= "" and ((g.met and "  " or "  |cffff4040") .. g.req:gsub("S", " Str "):gsub("A", " Agi "):gsub("I", " Int ") .. (g.met and "" or "|r")) or ""
                r.info:SetText(string.format("%s  %s%s", cls, need > level and ("|cffff4040level " .. need .. "|r") or ("level " .. need), reqText))
                if picked == g.id then r.sel:Show() else r.sel:Hide() end
                r:SetScript("OnClick", function(_, button)
                    if button == "RightButton" then
                        EasyMenu({ { text = name, isTitle = true, notCheckable = true },
                            { text = "Take it out as an item (to trade)", notCheckable = true, func = function() Send("MO:" .. g.id) end } },
                            menu, "cursor", 0, 0, "MENU")
                    elseif IsShiftKeyDown() then
                        for s = 1, gems.open do
                            if not gems.slots[s] then Send(string.format("MS:%d:%d", g.id, s - 1)) return end
                        end
                        UIErrorsFrame:AddMessage("Every open slot is full: click this gem, then the slot to swap it into.", 1, 0.2, 0.2)
                    else
                        picked = (picked ~= g.id) and g.id or nil
                        WT.RefreshSkillGemsPage()
                    end
                end)
                r:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if Spell(g.gem) then GameTooltip:SetHyperlink("spell:" .. Spell(g.gem)) end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(string.format("%s skill gem, from level %d", cls, need), 0.4, 0.8, 1)
                    GameTooltip:AddLine("Click, then a slot: socket it. Shift-click: the first empty slot. Right-click: more.", 0.5, 0.8, 1, true)
                    GameTooltip:Show()
                end)
                r:Show()
            end
            for _, g in ipairs(gems.bags) do
                i = i + 1
                local r = Row(i)
                local name, icon, cls = GemInfo(g.gem)
                r.icon:SetTexture(icon)
                r.name:SetText(name .. " |cff888888(in your bags)|r")
                r.info:SetText("|cff66ccffclick: into the pouch|r")
                r.sel:Hide()
                r:SetScript("OnClick", function() Send(string.format("MD:%d:%d", g.bag, g.slot)) end)
                r:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    if Spell(g.gem) then GameTooltip:SetHyperlink("spell:" .. Spell(g.gem)) end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(cls .. " skill gem (an item). Click: into your pouch.", 0.4, 0.8, 1, true)
                    GameTooltip:Show()
                end)
                r:Show()
            end
            for j = i + 1, #rows do rows[j]:Hide() end
            Size(body, 748, math.max(300, math.ceil(i / 2) * 27))
            pouchS.header:SetText(string.format("Skill gem pouch (%d)", #gems.pouch))
            pouchS.note:SetText(i == 0 and "Skill gems drop from creatures: more from elites, Champions and bosses." or "")
        end
        page:SetScript("OnShow", function() Send("M") WT.RefreshSkillGemsPage() end)
    end
end

-- ---------------------------------------------------------------------------
-- The Perks tab (0.37.6): small things that take annoyances out of playing,
-- always on. The server sends its numbers (QG).
-- ---------------------------------------------------------------------------

do
    local perks = { recovery = 15, ironWill = 95, snare = 30, flags = 127 }
    local LIST = {
        { bit = 1, name = "Rapid Recovery", icon = "Spell_Nature_Rejuvenation",
          text = function() return string.format("After 3 seconds out of combat you (and your pet) regain |cff1eff00%d%% of your health and mana every second|r until full. Not in battlegrounds.", perks.recovery) end },
        { bit = 2, name = "No Daze", icon = "Ability_Mount_RidingHorse",
          text = function() return "Enemies can no longer |cffff4040Daze|r you or your pet: being struck from behind while moving or mounted never slows you." end },
        { bit = 4, name = "No Resurrection Sickness", icon = "Spell_Holy_Resurrection",
          text = function() return "You never get |cffff4040Resurrection Sickness|r: coming back at a Spirit Healer doesn't weaken you." end },
        { bit = 8, name = "Contented Pets", icon = "Ability_Hunter_BeastTraining",
          text = function() return "Your Hunter pet is always happy: no feeding, and it never deals less damage for being unhappy." end },
        { bit = 16, name = "Endless Ammo", icon = "INV_Ammo_Arrow_02",
          text = function() return "The arrows or bullets you have equipped never run out: your stack refills by itself (keep a little bag space)." end },
        { bit = 32, name = "Iron Will", icon = "Spell_Magic_MageArmor",
          text = function() return string.format("Crowd control on you and your pets (stuns, fears, roots, silences, polymorphs...) lasts |cff1eff00%d%% less|r.", perks.ironWill) end },
        { bit = 64, name = "Snare Breaker", icon = "Ability_Rogue_Sprint",
          text = function() return string.format("Slows on you and your pets are never stronger than |cff1eff00%d%%|r.", perks.snare) end },
    }

    function WT.OnPerksData(f)
        perks.recovery, perks.ironWill, perks.snare = tonumber(f[1]) or 15, tonumber(f[2]) or 95, tonumber(f[3]) or 30
        perks.flags = tonumber(f[4]) or 127
        if WT.RefreshPerksPage then WT.RefreshPerksPage() end
    end

    function WT.BuildPerksPage(page, H)
        local s = H.Section(16, -60, 788, 516, "Perks", page)
        local intro = s:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        intro:SetPoint("TOPLEFT", 14, -38)
        intro:SetWidth(760)
        intro:SetJustifyH("LEFT")
        intro:SetText("Permanent perks for everyone, always on. They're here to take some of the annoyances out of playing: "
            .. "no waiting to drink after every fight, no being dazed off your mount, no feeding your pet or buying arrows, "
            .. "and no being stunlocked from start to finish.")
        local rows = {}
        for i, p in ipairs(LIST) do
            local r = CreateFrame("Frame", nil, s)
            Size(r, 760, 56)
            r:SetPoint("TOPLEFT", 14, -84 - (i - 1) * 60)
            r.icon = r:CreateTexture(nil, "ARTWORK")
            Size(r.icon, 40, 40)
            r.icon:SetPoint("LEFT", 0, 0)
            r.icon:SetTexture("Interface\\Icons\\" .. p.icon)
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            r.name:SetPoint("TOPLEFT", r.icon, "TOPRIGHT", 12, 2)
            r.name:SetText(p.name)
            r.state = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            r.state:SetPoint("LEFT", r.name, "RIGHT", 10, 0)
            r.text = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.text:SetPoint("TOPLEFT", r.name, "BOTTOMLEFT", 0, -4)
            r.text:SetWidth(690)
            r.text:SetJustifyH("LEFT")
            r.perk = p
            rows[i] = r
        end
        function WT.RefreshPerksPage()
            if not page:IsShown() then return end
            for _, r in ipairs(rows) do
                local on = math.floor(perks.flags / r.perk.bit) % 2 == 1
                r.text:SetText(r.perk.text())
                r.state:SetText(on and "|cff1eff00ALWAYS ACTIVE|r" or "|cff888888switched off on this realm|r")
                r.icon:SetDesaturated(not on)
            end
        end
        page:SetScript("OnShow", function() Send("QG") WT.RefreshPerksPage() end)
    end
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
                      [7] = { 0.12, 1, 0.59 },       -- a class set piece (green)
                      [8] = { 0.85, 0.85, 0.85 },    -- the base's built-in line (0.43)
                      [9] = { 1, 0.82, 0 },          -- a Superior or Elite base (gold)
                      [10] = { 0.53, 0.6, 1 },       -- a unique item's line (0.44)
                      [11] = { 0.75, 0.45, 0.15 } }  -- a unique item's verse, shown last
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
    local special, verse
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
        elseif a.rarity == 5 and a.text:find("^Requires ") then
            -- what it needs (0.47): on its own, ruled off from the item's lines below, as in Path of Exile
            tip:AddLine(a.text, 1, 1, 1, true)
            tip:AddLine("--------", 0.4, 0.4, 0.4)
        elseif a.rarity == 10 then
            special = special or "U"   -- a unique item (0.44): its lines, the orange name and border
            tip:AddLine(a.text, c[1], c[2], c[3], true)
        elseif a.rarity == 11 then
            verse = a.text
        elseif a.rarity == 8 then
            -- the built-in line, then a rule before the affixes, as in Path of Exile
            tip:AddLine(a.text, c[1], c[2], c[3], true)
            tip:AddLine("--------", 0.4, 0.4, 0.4)
        else
            tip:AddLine(a.text, c[1], c[2], c[3], true)
        end
    end
    if verse then
        tip:AddLine(" ")
        tip:AddLine(verse, AFFIX_COLOR[11][1], AFFIX_COLOR[11][2], AFFIX_COLOR[11][3], true)
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
        u = u or a.rarity == 6 or a.rarity == 10
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
local forgeMode = "gear"   -- or "codex", or "craft" (0.41)
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
forge.craftTab = ForgeTab("Crafting", 234)

local forgeTier = forge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
forgeTier:SetPoint("LEFT", forge.craftTab, "RIGHT", 12, 0)
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

-- ---------------- the Crafting panel (0.41): orbs on the chosen item ----------------
do
local ORBS = {
    { name = "Orb of Transmutation", icon = "INV_Misc_Orb_02", text = "An item with no affixes gets one (common or uncommon)." },
    { name = "Orb of Alteration", icon = "INV_Elemental_Mote_Mana", text = "Each affix rerolled into another of its rarity and side (prefix or suffix), at a new tier." },
    { name = "Orb of Augmentation", icon = "INV_Elemental_Mote_Water01", text = "One more common or uncommon affix, if the item has room." },
    { name = "Chaos Orb", icon = "INV_Elemental_Mote_Nether", text = "Every affix rerolled: new affixes, and a new number of them." },
    { name = "Exalted Orb", icon = "INV_Misc_RunedOrb_01", text = "One more affix of any rarity (a rare one from World Tier VI), if the item has room." },
    { name = "Orb of Annulment", icon = "INV_Elemental_Mote_Shadow01", text = "One affix, at random, taken off." },
    { name = "Orb of Scouring", icon = "INV_Misc_Orb_03", text = "Every affix taken off." },
    { name = "Divine Orb", icon = "INV_Orb_Arcanite", text = "The size of every affix rerolled within its tier (70-100%). On a unique: its numbers rerolled (the only orb that works on one)." },
}
WT.ORB_NAMES = {}
for i, o in ipairs(ORBS) do WT.ORB_NAMES[i] = o.name end
local craft = CreateFrame("Frame", nil, forge)
forge.craft = craft
craft:SetPoint("TOPLEFT", list, "TOPRIGHT", 16, 0)
Size(craft, 350, ROWS * ROW_H)
craft:Hide()
local cName = craft:CreateFontString(nil, "OVERLAY", "GameFontNormal")
cName:SetPoint("TOPLEFT", 0, -2)
cName:SetWidth(346)
cName:SetJustifyH("LEFT")
local cAffixes = craft:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
cAffixes:SetPoint("TOPLEFT", cName, "BOTTOMLEFT", 0, -6)
cAffixes:SetWidth(346)
cAffixes:SetJustifyH("LEFT")
local cHelp = craft:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
cHelp:SetPoint("BOTTOMLEFT", 0, 0)
cHelp:SetWidth(346)
cHelp:SetJustifyH("LEFT")
cHelp:SetText("Choose an item on the left, then click an orb to use it. Orbs drop from creatures: more from elites, Champions and bosses. "
    .. "Uncommon items carry up to 2 affixes, rare 3, epic and better 4. Class uniques and set powers are never touched.")
local orbButtons = {}
for i, o in ipairs(ORBS) do
    local b = CreateFrame("Button", nil, craft)
    Size(b, 168, 40)
    b:SetPoint("TOPLEFT", ((i - 1) % 2) * 176, -150 - math.floor((i - 1) / 2) * 46)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    Size(b.icon, 36, 36)
    b.icon:SetPoint("LEFT", 2, 0)
    b.icon:SetTexture("Interface\\Icons\\" .. o.icon)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.name:SetPoint("TOPLEFT", b.icon, "TOPRIGHT", 6, -2)
    b.name:SetWidth(122)
    b.name:SetJustifyH("LEFT")
    b.name:SetText(o.name)
    b.count = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.count:SetPoint("BOTTOMLEFT", b.icon, "BOTTOMRIGHT", 6, 2)
    b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    b.orb = i
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(o.name, 1, 0.82, 0)
        GameTooltip:AddLine(o.text, 1, 1, 1, true)
        GameTooltip:AddLine(string.format("You have %d.", (forgeData.orbs or {})[i] or 0), 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        local it = forgeData.items[forgeSelected or ""]
        if not it then UIErrorsFrame:AddMessage("Choose an item on the left first.", 1, 0.2, 0.2) return end
        if ((forgeData.orbs or {})[self.orb] or 0) < 1 then UIErrorsFrame:AddMessage("You have none of those.", 1, 0.2, 0.2) return end
        Send(string.format("FC:%d:%d:%d", self.orb, it.bag, it.slot))
    end)
    orbButtons[i] = b
end

forge.RefreshCraft = function(it)
    if not it then
        cName:SetText("|cff888888Choose an item on the left.|r")
        cAffixes:SetText("")
    else
        cName:SetText((ItemLink(it) or "?"):gsub("[%[%]]", ""))
        local lines = {}
        for _, a in ipairs(it.affixes) do
            local c = ({ [0] = "ffffff", [1] = "1eff00", [2] = "a335ee" })[a.rarity] or "ff8000"
            lines[#lines + 1] = "|cff" .. c .. a.text .. "|r"
        end
        cAffixes:SetText(#lines > 0 and table.concat(lines, "\n") or "|cff888888No affixes.|r")
    end
    for i, b in ipairs(orbButtons) do
        local n = (forgeData.orbs or {})[i] or 0
        b.count:SetText(n > 0 and ("|cffffffff" .. n .. "|r") or "|cff8888880|r")
        b.icon:SetDesaturated(n < 1)
    end
end
end

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
    gearTab:UnlockHighlight() codexTab:UnlockHighlight() forge.craftTab:UnlockHighlight()
    if forgeMode == "codex" then codexTab:LockHighlight() elseif forgeMode == "craft" then forge.craftTab:LockHighlight() else gearTab:LockHighlight() end
    forgeMoney:SetText(WT.MoneyLine())
    local mats = {}
    for _, m in ipairs(forgeData.mats) do
        mats[#mats + 1] = string.format("|cffa335ee%s|r %d%s", m.band, m.essence, m.shards > 0 and string.format(" (+%d shards)", m.shards) or "")
    end
    forgeMats:SetText(#mats > 0 and ("Essence: " .. table.concat(mats, ",  ")) or "|cff888888No Essence yet: bosses at World Tier I and up drop it (raids Essence, dungeons Shards).|r")
    if forgeMode == "codex" then
        list:Hide()
        detail:Hide()
        forge.craft:Hide()
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
    if forgeMode == "craft" then
        detail:Hide()
        forge.craft:Show()
        forge.RefreshCraft(it)
        return
    end
    forge.craft:Hide()
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
            if it.rerollOne > 0 and a.rarity ~= 6 and a.rarity ~= 10 then row.button:Enable() else row.button:Disable() end
            if a.rarity == 6 or a.rarity == 10 then row.cost:SetText("|cffe6cc80unique|r") end
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
    elseif cmd == "FC" and pendingForge then
        pendingForge.orbs = {}
        for n in (rest .. ","):gmatch("([^,]*),") do pendingForge.orbs[#pendingForge.orbs + 1] = tonumber(n) or 0 end
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
forge.craftTab:SetScript("OnClick", function() forgeMode = "craft" RefreshForge() end)

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
    if not info or info.name == "" then return end
    if info.kind == "R" then        -- a rare monster (0.42): 3-4 modifiers
        tip:AddLine("Rare monster: " .. info.name, 1, 1, 0)
        tip:AddLine("It " .. info.text .. ". Tougher; drops orbs and a piece of gear.", 1, 1, 0.6, true)
    elseif info.kind == "M" then    -- a magic monster (0.42): 1-2 modifiers
        tip:AddLine("Magic monster: " .. info.name, 0.4, 0.6, 1)
        tip:AddLine("It " .. info.text .. ". Tougher; more orbs.", 0.7, 0.8, 1, true)
    else
        tip:AddLine(string.format("Champion: %s", info.name), 1, 0.5, 0)
        tip:AddLine(string.format("It %s. Three times the health; drops gear with affixes.", info.text), 1, 0.75, 0.4, true)
    end
    tip:Show()
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
    local info = { name = f[2] or "", text = f[3] or "", kind = f[4] or "C", at = GetTime() }
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
        "Earn points at your highest unlocked tier: dungeon boss 2, raid boss 3, a raid's last boss 8, world boss 6, Tier Key 4 + its level, Champion 1, Treasure Goblin 2. Unlocked tiers are your whole account's. A kill counts at the lowest tier that did enough of the damage." end)

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
    local paragonT = Tile(1, "Spell_Holy_EmpowerChampion", "Passive Tree", function() win:Hide() if WT.OpenPassive then WT.OpenPassive() end end)
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
            need, level = need or 80, (level and level > 0) and level or UnitLevel("player")   -- 0: not heard from the server yet
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
                .. "- " .. W .. "Unlocking the next tier:" .. E .. " earn points at your highest unlocked tier: bosses (a raid's last boss most), Tier Keys, Champions and Treasure Goblins all count. Unlocked tiers are shared by your whole account. "
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

        -- ---------------- the Paragon Board, Keystones and Skills (0.37) ----------------
        local helpers = { Section = Section, Button = Button, Tip = Tip }
        local paragonPage = CreateFrame("Frame", nil, win)
        paragonPage:SetAllPoints()
        paragonPage:Hide()
        hub.pages.paragon = paragonPage
        local keystonesPage = CreateFrame("Frame", nil, win)
        keystonesPage:SetAllPoints()
        keystonesPage:Hide()
        hub.pages.keystones = keystonesPage
        if WT.BuildKeystonesPage then WT.BuildKeystonesPage(keystonesPage, helpers) end
        local skillsPage = CreateFrame("Frame", nil, win)
        skillsPage:SetAllPoints()
        skillsPage:Hide()
        hub.pages.skills = skillsPage
        if WT.BuildSkillsPage then WT.BuildSkillsPage(skillsPage, helpers) end
        local perksPage = CreateFrame("Frame", nil, win)
        perksPage:SetAllPoints()
        perksPage:Hide()
        hub.pages.perks = perksPage
        if WT.BuildPerksPage then WT.BuildPerksPage(perksPage, helpers) end
        local gemsPage = CreateFrame("Frame", nil, win)
        gemsPage:SetAllPoints()
        gemsPage:Hide()
        hub.pages.gems = gemsPage
        if WT.BuildSkillGemsPage then WT.BuildSkillGemsPage(gemsPage, helpers) end
        win:HookScript("OnHide", function() if WT.UnembedBoard then WT.UnembedBoard() end end)

        -- ---------------- the tabs ----------------
        local tabs = {}
        local function ShowPage(name)
            hub.page = name
            for k, pg in pairs(hub.pages) do if k == name then pg:Show() else pg:Hide() end end
            for k, t in pairs(tabs) do if k == name then t:LockHighlight() else t:UnlockHighlight() end end
            if name ~= "overview" and picker then picker:Hide() end
            if name == "paragon" then
                if WT.EmbedBoard then WT.EmbedBoard(paragonPage) end
            elseif WT.UnembedBoard then
                WT.UnembedBoard()
            end
        end
        WT.hubShowPage = ShowPage
        local order = { { "guide", "Guide", 56 }, { "overview", "Overview", 76 }, { "vault", "Vault", 54 },
            { "events", "Events", 60 }, { "paragon", "Passive Tree", 96 }, { "skills", "Skills", 56 },
            { "gems", "Gems", 52 }, { "perks", "Perks", 54 } }
        local right = -44
        for i = #order, 1, -1 do
            local key, label, w = order[i][1], order[i][2], order[i][3]
            local t = Button(win, w, 24, label)
            t:SetPoint("TOPRIGHT", right, -24)
            t:SetFrameLevel(win:GetFrameLevel() + 20)   -- above the drag strip and the pages
            right = right - w - 4
            -- 0.48.2: the Paragon Board is gone: its tab opens the passive tree
            t:SetScript("OnClick", function()
                if key == "paragon" then
                    win:Hide()
                    if WT.OpenPassive then WT.OpenPassive() end
                else
                    ShowPage(key)
                end
            end)
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
        subtitle:SetText(string.format("Level %d  -  %s", h.level or UnitLevel("player"), WT.PassiveSummary and WT.PassiveSummary() or "Passive Tree"))

        -- tier
        local tiers = Flag(HF_TIERS)
        tierName:SetText(h.tierName or "")
        tierNow:SetText(string.format("Creatures you face: |cffff9933%s|r health, |cffff9933%s|r damage", h.curHealth or "-", h.curDamage or "-"))
        tierMax:SetText(string.format("Highest unlocked: |cffffd100%s|r", h.maxName or ""))
        local need = math.max(1, h.need or 1)
        bar:SetMinMaxValues(0, need)
        bar:SetValue(math.min(h.progress or 0, need))
        barText:SetText(string.format("Next tier: %d / %d points", h.progress or 0, need))
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
        paragonT:SetOn(true)   -- 0.46: the passive tree in the Paragon Board's place
        paragonT.sub:SetText(WT.PassiveSummary and WT.PassiveSummary() or "Your passive tree")
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
            -- opened by the server (the menu spell, a Keeper): the Ascendancy too, or it shows as not yet open
            if WT.AskAscendancies then WT.AskAscendancies() end
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
-- listed under the dungeons, once each, in the raid difficulty set on your
-- portrait (right-click it: Raid Difficulty), and queue the same way.
-- ---------------------------------------------------------------------------

do
    local stock
    local function Filter(dungeonID)
        local info = LFGGetDungeonInfoByID and LFGGetDungeonInfoByID(dungeonID)
        if not info then return false end   -- nothing known about it: the stock filter would error on it (0.37.17)
        if stock then
            local ok, show = pcall(stock, dungeonID)
            if ok and show then return true end
        end
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
    local AddRaids
    local function WithRaids(list)
        list = stockOrder(list)
        pcall(AddRaids, list)   -- whatever happens adding raids, the dungeons still list (0.37.17)
        return list
    end
    AddRaids = function(list)
        if WT.raidsInFinder == false or type(GetLFRChoiceOrder) ~= "function" then return list end
        local have = {}
        for _, id in ipairs(list) do have[id] = true end
        -- one line a raid (0.37.3): the entry for the raid difficulty chosen on your portrait (10 / 25, heroic)
        local want = (GetRaidDifficulty and GetRaidDifficulty() or 1) - 1
        local R = LFG_RETURN_VALUES
        local best, order = {}, {}
        for _, id in ipairs(GetLFRChoiceOrder() or {}) do
            -- only raids the Dungeon Finder knows (0.37.17): an id it has no details for broke the whole list
            local info = type(id) == "number" and id > 0 and LFGGetDungeonInfoByID and LFGGetDungeonInfoByID(id)
            if info and not have[id] then
                local name = R and info[R.name] or tostring(id)
                local diff = R and tonumber(info[R.difficulty]) or 0
                -- the exact difficulty, else the same size (10 or 25), else the lowest
                local score = (diff == want) and 0 or ((diff % 2) == (want % 2) and 1 or 2) + diff * 0.01
                if not best[name] then order[#order + 1] = name end
                if not best[name] or score < best[name].score then best[name] = { id = id, score = score } end
            end
        end
        for _, name in ipairs(order) do
            local id = best[name].id
            list[#list + 1] = id
            have[id] = true
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
    pcall(ev.RegisterEvent, ev, "PLAYER_DIFFICULTY_CHANGED")   -- a new raid difficulty: its raids in the list
    ev:SetScript("OnEvent", function()
        Install()
        if LFDQueueFrame and LFDQueueFrame:IsShown() and LFDQueueFrame_Update then LFDQueueFrame_Update() end
    end)
end

-- ---------------------------------------------------------------------------
-- Quieter errors (0.38.1): with a 1.0 sec global cooldown, pressing a key a
-- moment early is normal, so "Ability is not ready yet" and its kin no longer
-- fill the middle of the screen (or play the error sound). Every other error
-- shows as before.
-- ---------------------------------------------------------------------------

do
    local hide = {}
    for _, key in ipairs({ "ERR_ABILITY_COOLDOWN", "ERR_SPELL_COOLDOWN", "SPELL_FAILED_NOT_READY",
                           "SPELL_FAILED_SPELL_IN_PROGRESS" }) do
        if type(_G[key]) == "string" then hide[_G[key]] = true end
    end
    local frame = UIErrorsFrame
    local stock = frame and frame:GetScript("OnEvent")
    if stock then
        frame:SetScript("OnEvent", function(self, event, message, ...)
            if event == "UI_ERROR_MESSAGE" and hide[message] then return end
            return stock(self, event, message, ...)
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Combo points for anyone (0.41): with skill gems any class can use finishers,
-- but the game only shows combo points to Rogues and Druids, on a target they
-- picked. The server sends CP|points; five pips under your portrait show them
-- (not when the game's own already do).
-- ---------------------------------------------------------------------------

do
    local bar = CreateFrame("Frame", "WorldTiersComboPoints", UIParent)
    Size(bar, 5 * 18, 16)
    bar:SetPoint("TOP", PlayerFrame or UIParent, "BOTTOM", 50, 28)
    bar:Hide()
    local pips = {}
    for i = 1, 5 do
        local t = bar:CreateTexture(nil, "ARTWORK")
        Size(t, 14, 14)
        t:SetPoint("LEFT", (i - 1) * 18, 0)
        t:SetTexture("Interface\\ComboFrame\\ComboPoint")
        t:SetTexCoord(0.5625, 1, 0, 1)
        pips[i] = t
    end
    local points = 0
    local function Draw()
        local _, cls = UnitClass("player")
        local native = (cls == "ROGUE" or cls == "DRUID") and UnitExists("target") and (GetComboPoints("player", "target") or 0) > 0
        if points <= 0 or native then bar:Hide() return end
        for i = 1, 5 do pips[i]:SetVertexColor(i <= points and 1 or 0.25, i <= points and 0.82 or 0.25, i <= points and 0 or 0.25) end
        bar:Show()
    end
    function WT.OnComboMessage(msg)
        local n = msg:match("^CP|(%d+)$")
        if not n then return false end
        points = tonumber(n) or 0
        Draw()
        return true
    end
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_TARGET_CHANGED")
    ev:RegisterEvent("UNIT_COMBO_POINTS")
    ev:SetScript("OnEvent", Draw)
end

-- ---------------------------------------------------------------------------
-- The mana shield (0.43.1): cloth's defence, a pool taken before health. The
-- server sends MSH|current|most; a bar under your portrait shows it.
-- ---------------------------------------------------------------------------

do
    local bar = CreateFrame("StatusBar", "WorldTiersManaShield", UIParent)
    Size(bar, 119, 9)
    bar:SetPoint("TOPLEFT", PlayerFrameManaBar or PlayerFrame or UIParent, "BOTTOMLEFT", 0, -2)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.45, 0.6, 1)
    bar:SetMinMaxValues(0, 1)
    bar:Hide()
    local bg = bar:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(bar)
    bg:SetTexture(0, 0, 0, 0.6)
    local text = bar:CreateFontString(nil, "OVERLAY", "TextStatusBarText")
    text:SetPoint("CENTER", bar, "CENTER", 0, 0)
    function WT.OnShieldMessage(msg)
        local cur, most = msg:match("^MSH|(%d+)|(%d+)$")
        if not cur then return false end
        cur, most = tonumber(cur) or 0, tonumber(most) or 0
        if most <= 0 then bar:Hide() return true end
        bar:SetMinMaxValues(0, most)
        bar:SetValue(cur)
        text:SetText(cur .. " / " .. most)
        bar:Show()
        return true
    end
end
-- ---------------------------------------------------------------------------
-- The passive tree's nodes (generated by tools/gen_passive_tree.py: edit it there)
-- ---------------------------------------------------------------------------

WT.PT = { size = 3700, x = {}, y = {}, t = {}, name = {}, text = {}, ks = {}, icon = {}, edges = {}, start = {} }
do
local P = WT.PT
local TX = {"Your class starts here.","+10 Strength","+10 Intellect","+10 Agility","6% increased Shadow Damage","+10 Spell Power","16% increased Shadow Damage\n+1 to the level of your Shadow skills","+25 Spell Power\n+1 to the level of your Shadow skills","Put a jewel in it once you have taken it.","+8 Spirit","6% increased Healing","16% increased Healing\n+1 to the level of your healing skills","7% increased Damage over Time","6% increased Damage over Time","18% increased Damage over Time\n6% increased Damage","6% increased Area Damage","7% increased Area Damage","+1 to the level of your area skills\n6% increased Damage","6% increased Fire Damage","16% increased Fire Damage\n+1 to the level of your Fire skills","+1 to the level of your damage-over-time skills\n6% increased Damage","6% increased Nature Damage","+1 to the level of your Nature skills\n16% increased Nature Damage","+25 Spell Power\n16% increased Nature Damage","+8 Dodge Rating","+120 Evasion","8% increased Evasion","+300 Evasion\n+20 Dodge Rating","+8 Armour Penetration Rating","6% increased Physical Damage","+8 Expertise Rating","+21.6 Expertise Rating\n17.3% increased Physical Damage","+120 Armour","8% increased Armour","+324 Armour\n23.8% increased Armour","7% increased Pet and Minion Damage","+1 to the level of your pet and minion skills\n5.4% increased Maximum Health","19.4% increased Damage over Time\n+1 to the level of your damage-over-time skills","+8 Stamina","+324 Armour\n3.2% reduced damage taken","+1 to the level of your Shadow skills\n17.3% increased Shadow Damage","6% increased Holy Damage","+1 to the level of your Holy skills\n17.3% increased Holy Damage","3% increased Cast Speed","5% increased Spell Damage","+32.4 Spell Power\n15.1% increased Spell Damage","5% faster Mana Shield recharge","8% increased Mana Shield","+200 Mana Shield","23.8% increased Mana Shield\n13% faster Mana Shield recharge","+27 Spell Power\n+1 to the level of your Shadow skills","7.6% increased Cast Speed\n15.1% increased Spell Damage","0.3% of damage dealt returned as health","3% increased Damage","Regain 3.2% of maximum health on kill\n8.6% increased Damage","6.5% increased Damage\n+1 to the level of your area skills","17.3% increased Nature Damage\n+1 to the level of your Nature skills","3% increased Attack Speed","7% increased Projectile Damage","6.5% increased Attack Speed\n+1 to the level of your projectile skills","+324 Evasion\n23.8% increased Evasion","+8 Hit Rating","5% increased Attack Damage","+20 Attack Power","7.6% increased Attack Speed\n+21.6 Hit Rating","+21.6 Dodge Rating\n+324 Evasion","+54 Attack Power\n+21.6 Hit Rating","+54 Attack Power\n15.1% increased Attack Damage","+23.2 Armour Penetration Rating\n18.6% increased Physical Damage","3.5% reduced damage taken\n25.5% increased Armour","6% increased Pet and Minion Damage","5.8% increased Maximum Health\n20.9% increased Pet and Minion Damage","20.9% increased Pet and Minion Damage\n+1 to the level of your pet and minion skills","25.5% increased Armour\n+348 Armour","+348 Armour\n3.5% reduced damage taken","+1 to the level of your Shadow skills\n+29 Spell Power","+29 Spell Power\n+1 to the level of your Shadow skills","6% increased Frost Damage","+29 Spell Power\n18.6% increased Frost Damage","20.9% increased Area Damage\n+1 to the level of your area skills","25.5% increased Mana Shield\n13.9% faster Mana Shield recharge","20.9% increased Pet and Minion Damage\n5.8% increased Maximum Health","13.9% faster Mana Shield recharge\n+580 Mana Shield","25.5% increased Evasion\n+23.2 Dodge Rating","+12 Spell Power","+34.8 Spell Power\n8.1% increased Cast Speed","+23.2 Dodge Rating\n+348 Evasion","18.6% increased Nature Damage\n+29 Spell Power","+1 to the level of your area skills\n20.9% increased Area Damage","8% increased gold found","18.6% increased Nature Damage\n+1 to the level of your Nature skills","+8 Critical Strike Rating","+10 Critical Strike Rating","+29 Critical Strike Rating\n11.6% increased Damage against Bosses","18.6% increased Physical Damage\n+23.2 Armour Penetration Rating","+150 Maximum Health","4% increased Maximum Health","+440.8 Maximum Health\nRegenerate 0.46% of maximum health every 5 sec in combat","+58 Attack Power\n+23.2 Hit Rating","6% increased Armour","+10 Block Rating","+8 Parry Rating","+31 Block Rating\n18.6% increased Armour","+30 Strength","+372 Armour\n27.3% increased Armour","17.4% increased Attack Damage\n8.7% increased Attack Speed","17.4% increased Spell Damage\n8.7% increased Cast Speed","+24.8 Spirit\n19.8% increased Healing","+150 Maximum Mana","5% increased Maximum Mana","3% reduced mana cost of skills","9.9% reduced mana cost of skills\n14.9% increased Maximum Mana","+31 Spell Power\n19.8% increased Frost Damage","+1 to the level of your area skills\n22.3% increased Area Damage","19.8% increased Fire Damage\n+1 to the level of your Fire skills","Regain 1% of maximum health on kill","9.9% increased Damage\n0.99% of damage dealt returned as health","19.8% increased Fire Damage\n+31 Spell Power","19.8% increased Nature Damage\n+1 to the level of your Nature skills","+1 to the level of your Nature skills\n+31 Spell Power","+37.2 Spell Power\n17.4% increased Spell Damage","Regain 3.7% of maximum mana on kill\n9.9% reduced mana cost of skills","14.9% increased Maximum Mana\nRegain 3.7% of maximum mana on kill","+1 to the level of your pet and minion skills\n22.3% increased Pet and Minion Damage","27.3% increased Evasion\n+372 Evasion","4% increased experience","+372 Evasion\n27.3% increased Evasion","+1 to the level of your damage-over-time skills\n7.4% increased Damage","7.4% increased Damage\n+1 to the level of your damage-over-time skills","+24.8 Expertise Rating\n+24.8 Armour Penetration Rating","19.8% increased Armour\n+33 Block Rating","Regain 4% of maximum health on kill\n1.06% of damage dealt returned as health","10.6% increased Damage\n1.06% of damage dealt returned as health","Regenerate 0.15% of maximum health every 5 sec in combat","+501.6 Maximum Health\nRegenerate 0.53% of maximum health every 5 sec in combat","21.1% increased Shadow Damage\n+33 Spell Power","+1 to the level of your Holy skills\n21.1% increased Holy Damage","+26.4 Spirit\n+1 to the level of your healing skills","4% reduced damage taken\n19.8% increased Armour","+1 to the level of your Holy skills\n+33 Spell Power","+33 Spell Power\n21.1% increased Shadow Damage","+30 Intellect","29% increased Mana Shield\n15.8% faster Mana Shield recharge","+39.6 Spell Power\n18.5% increased Spell Damage","+1 to the level of your Frost skills\n+33 Spell Power","15.8% faster Mana Shield recharge\n29% increased Mana Shield","1.06% of damage dealt returned as health\nRegain 4% of maximum health on kill","+1 to the level of your Shadow skills\n+33 Spell Power","9.2% increased Cast Speed\n+39.6 Spell Power","6% increased Arcane Damage","+33 Spell Power\n+1 to the level of your Arcane skills","+26.4 Spirit\n21.1% increased Healing","+39.6 Spell Power\n9.2% increased Cast Speed","+33 Spell Power\n+1 to the level of your Nature skills","10.6% reduced mana cost of skills\n15.8% increased Maximum Mana","10.6% reduced mana cost of skills\nRegain 4% of maximum mana on kill","+1 to the level of your Nature skills\n21.1% increased Nature Damage","+30 Agility","+26.4 Hit Rating\n+66 Attack Power","+1 to the level of your projectile skills\n23.8% increased Projectile Damage","23.8% increased Projectile Damage\n+1 to the level of your projectile skills","+26.4 Haste Rating\n9.2% increased Attack Speed","18.5% increased Attack Damage\n+66 Attack Power","+26.4 Hit Rating\n9.2% increased Attack Speed","+1 to the level of your damage-over-time skills\n23.8% increased Damage over Time","+33 Block Rating\n19.8% increased Armour","11.2% increased Damage\n1.12% of damage dealt returned as health","+35 Spell Power\n+1 to the level of your Shadow skills","+1 to the level of your pet and minion skills\n7% increased Maximum Health","14% increased Maximum Health\n+532 Maximum Health","7% increased Maximum Health\n+1 to the level of your pet and minion skills","+1 to the level of your Holy skills\n22.4% increased Holy Damage","+35 Spell Power\n+1 to the level of your Holy skills","22.4% increased Holy Damage\n+35 Spell Power","22.4% increased Healing\n+1 to the level of your healing skills","Regain 4.2% of maximum mana on kill\n11.2% reduced mana cost of skills","9.8% increased Cast Speed\n+42 Spell Power","+35 Spell Power\n22.4% increased Frost Damage","22.4% increased Arcane Damage\n+1 to the level of your Arcane skills","1.12% of damage dealt returned as health\nRegain 4.2% of maximum health on kill","22.4% increased Fire Damage\n+35 Spell Power","16.8% faster Mana Shield recharge\n+700 Mana Shield","+1 to the level of your Shadow skills\n22.4% increased Shadow Damage","22.4% increased Nature Damage\n+1 to the level of your Nature skills","22.4% increased Nature Damage\n+35 Spell Power","+1 to the level of your Nature skills\n+35 Spell Power","+1 to the level of your damage-over-time skills\n8.4% increased Damage","8.4% increased Damage\n+1 to the level of your area skills","19.6% increased Attack Damage\n+28 Hit Rating","25.2% increased Projectile Damage\n8.4% increased Attack Speed","30.8% increased Evasion\n+28 Dodge Rating","+35 Critical Strike Rating\n14% increased Damage against Bosses","+28 Hit Rating\n19.6% increased Attack Damage","30.8% increased Evasion\n+420 Evasion","14% increased Damage against Bosses\n+35 Critical Strike Rating","9.8% increased Attack Speed\n+28 Hit Rating","Your leech is doubled. Regeneration and health on kill do nothing.","You have no Evasion. 15% less damage taken.","Your skills cost health instead of mana.","Up to 40% more damage the lower your health: 1% for every 2.5% missing.","14.8% increased Maximum Health\nRegenerate 0.59% of maximum health every 5 sec in combat","4.4% reduced damage taken\n+444 Armour","Every skill is supported by level 20 Frost Conversion: your damage is Frost.","+1 to the level of your Holy skills\n+37 Spell Power","Twice the Block Rating. 10% more damage taken.","23.7% increased Holy Damage\n+1 to the level of your Holy skills","23.7% increased Shadow Damage\n+37 Spell Power","Your Holy skills are supported by level 20 Increased Area. 10% less damage taken while above 90% health.","23.7% increased Healing\n+29.6 Spirit","+2 to the level of all your skills. 15% less damage.","17.8% increased Maximum Mana\n11.8% reduced mana cost of skills","30% of damage taken comes from your mana before your health.","Every skill is supported by level 10 Mirror Image. 20% less damage.","50% less maximum health. Twice the Mana Shield. 50% less Shadow damage taken.","Your area skills are supported by level 20 Spell Cascade. Skills cost 15% more mana.","+37 Spell Power\n+1 to the level of your Shadow skills","Every skill is supported by level 20 Fire Conversion: your damage is Fire.","Your leech refills your Mana Shield instead of your health.","Every skill is supported by level 20 Shadow Conversion: your damage is Shadow.","30% more spell damage while below 50% health.","10.4% increased Cast Speed\n+44.4 Spell Power","Your pet and minion skills are supported by level 20 Minion Instability. 10% more pet damage.","20% less damage taken if you haven't been hit in the last 4 sec; 10% more if you have.","20.7% increased Attack Damage\n+74 Attack Power","+44.4 Spell Power\n10.4% increased Cast Speed","Every skill is supported by level 20 Nature Conversion: your damage is Nature.","Your spells are supported by level 20 Totem. 15% less damage of your own.","+1 to the level of your Nature skills\n23.7% increased Nature Damage","While not in a group: 20% more damage and 10% less damage taken.","32.6% increased Evasion\n+444 Evasion","Projectiles deal 30% more damage within 10 yards and 30% less beyond 25.","26.6% increased Damage over Time\n+1 to the level of your damage-over-time skills","50% more pet and minion damage. 15% less damage of your own.","60% more Evasion. 50% less Armour and Mana Shield.","+74 Attack Power\n20.7% increased Attack Damage","30% more damage over time. 15% less damage with direct hits.","32.6% increased Armour\n+444 Armour","8.9% increased Damage\n+1 to the level of your damage-over-time skills","All your Evasion counts as Armour instead.","50% more damage against enemies below 35% health; 10% less against the rest.","Regenerate 0.59% of maximum health every 5 sec in combat\n+562.4 Maximum Health"}
local N = {
  {1,0,520,3,1,"Warrior"},{2,495,161,3,1,"Paladin"},{3,-495,161,3,1,"Hunter"},{4,-306,421,3,1,"Rogue"},{5,495,-161,3,1,"Priest"},{6,306,421,3,1,"Death Knight"},{7,-495,-161,3,1,"Shaman"},{8,306,-421,3,1,"Mage"},{9,0,-520,3,1,"Warlock"},{11,-306,-421,3,1,"Druid"},
  {20,0,330,4,2,""},{21,102,314,4,2,""},{22,194,267,4,2,""},{23,267,194,4,2,""},{24,314,102,4,2,""},{25,330,0,4,2,""},{26,314,-102,4,3,""},{27,267,-194,4,3,""},{28,194,-267,4,3,""},{29,102,-314,4,3,""},
  {30,0,-330,4,3,""},{31,-102,-314,4,3,""},{32,-194,-267,4,3,""},{33,-267,-194,4,3,""},{34,-314,-102,4,4,""},{35,-330,0,4,4,""},{36,-314,102,4,4,""},{37,-267,194,4,4,""},{38,-194,267,4,4,""},{39,-102,314,4,4,""},
  {40,141,861,0,5,""},{41,101,907,0,5,""},{42,30,903,0,6,""},{43,-6,831,0,6,""},{44,31,774,0,6,""},{45,116,781,0,5,""},{46,69,839,1,7,"Umbral Heart"},{47,571,736,0,6,""},{48,490,794,0,6,""},{49,426,699,0,5,""},
  {50,513,646,0,6,""},{51,498,719,1,8,"Whispers"},{52,777,368,5,9,"Jewel Socket"},{53,961,-55,0,10,""},{54,912,-2,0,11,""},{55,825,-33,0,11,""},{56,844,-133,0,11,""},{57,928,-137,0,11,""},{58,889,-73,1,12,"Benediction"},{59,771,-464,0,13,""},
  {60,717,-411,0,14,""},{61,654,-423,0,14,""},{62,626,-499,0,13,""},{63,679,-556,0,13,""},{64,750,-539,0,14,""},{65,699,-484,1,15,"Withering"},{66,460,-803,0,16,""},{67,423,-752,0,16,""},{68,347,-755,0,16,""},{69,315,-839,0,17,""},
  {70,361,-888,0,17,""},{71,428,-881,0,17,""},{72,387,-818,1,18,"Shockwave"},{73,-115,-837,0,19,""},{74,-88,-891,0,6,""},{75,-62,-945,0,6,""},{76,-36,-999,1,20,"Pyromaniac"},{77,-465,-771,0,13,""},{78,-521,-707,0,14,""},{79,-580,-717,0,14,""},
  {80,-614,-787,0,14,""},{81,-559,-852,0,14,""},{82,-490,-836,0,13,""},{83,-540,-780,1,21,"Lingering Death"},{84,-708,-357,0,22,""},{85,-755,-300,0,6,""},{86,-822,-306,0,6,""},{87,-855,-388,0,6,""},{88,-807,-441,0,22,""},{89,-737,-430,0,22,""},
  {90,-782,-370,1,23,"Stormcaller"},{91,-859,78,0,22,""},{92,-911,148,0,22,""},{93,-1001,110,0,22,""},{94,-989,25,0,6,""},{95,-907,7,0,6,""},{96,-934,77,1,24,"Conductivity"},{97,-775,633,0,13,""},{98,-782,573,0,13,""},{99,-788,513,0,14,""},
  {100,-794,454,1,21,"Festering Wounds"},{101,-303,809,0,25,""},{102,-347,866,0,26,""},{103,-426,855,0,27,""},{104,-452,787,0,27,""},{105,-415,733,0,25,""},{106,-336,735,0,26,""},{107,-377,798,1,28,"Windwalker"},{108,157,1231,5,9,"Jewel Socket"},{109,612,1232,0,29,""},
  {110,558,1300,0,29,""},{111,493,1289,0,30,""},{112,464,1213,0,31,""},{113,517,1156,0,30,""},{114,576,1164,0,30,""},{115,537,1228,1,32,"Sundering Strikes"},{116,880,962,0,33,""},{117,791,1033,0,33,""},{118,730,954,0,34,""},{119,807,885,0,34,""},
  {120,805,959,1,35,"Bastion"},{121,946,661,0,36,""},{122,1004,679,0,36,""},{123,1061,696,0,36,""},{124,1119,713,1,37,"Commander"},{125,1278,395,0,14,""},{126,1223,448,0,14,""},{127,1162,436,0,13,""},{128,1131,369,0,13,""},{129,1172,308,0,14,""},
  {130,1248,313,0,13,""},{131,1206,375,1,38,"Wasting Affliction"},{132,1283,107,0,39,""},{133,1268,49,0,34,""},{134,1254,-9,0,39,""},{135,1239,-67,1,40,"Iron Skin"},{136,1333,-334,0,6,""},{137,1282,-276,0,5,""},{138,1216,-287,0,5,""},{139,1185,-359,0,6,""},
  {140,1223,-414,0,6,""},{141,1311,-402,0,6,""},{142,1259,-348,1,41,"Void Touched"},{143,1230,-712,0,6,""},{144,1144,-642,0,42,""},{145,1080,-717,0,6,""},{146,1165,-791,0,6,""},{147,1155,-716,1,43,"Lightbringer"},{148,912,-907,0,44,""},{149,897,-965,0,45,""},
  {150,882,-1023,0,44,""},{151,867,-1081,1,46,"Spellcraft"},{152,635,-1175,0,47,""},{153,593,-1108,0,48,""},{154,511,-1119,0,47,""},{155,485,-1185,0,47,""},{156,526,-1242,0,49,""},{157,606,-1235,0,48,""},{158,560,-1176,1,50,"Arcane Barrier"},{159,274,-1242,0,6,""},
  {160,221,-1174,0,6,""},{161,161,-1181,0,5,""},{162,127,-1263,0,6,""},{163,165,-1312,0,5,""},{164,241,-1308,0,5,""},{165,200,-1246,1,51,"Soul Siphon"},{166,-93,-1297,0,45,""},{167,-153,-1237,0,44,""},{168,-233,-1275,0,45,""},{169,-221,-1362,0,45,""},
  {170,-130,-1375,0,44,""},{171,-167,-1310,1,52,"Thaumaturgy"},{172,-431,-1144,0,53,""},{173,-477,-1084,0,54,""},{174,-545,-1091,0,54,""},{175,-577,-1176,0,54,""},{176,-527,-1226,0,54,""},{177,-458,-1212,0,54,""},{178,-505,-1154,1,55,"Feast of Flesh"},{179,-790,-1012,0,13,""},
  {180,-843,-956,0,13,""},{181,-912,-972,0,14,""},{182,-938,-1035,0,14,""},{183,-882,-1101,0,13,""},{184,-817,-1088,0,13,""},{185,-863,-1029,1,38,"Slow Rot"},{186,-1112,-804,0,16,""},{187,-1092,-748,0,16,""},{188,-1071,-692,0,17,""},{189,-1050,-635,1,56,"Blast Radius"},
  {190,-1200,-323,0,22,""},{191,-1239,-369,0,22,""},{192,-1278,-414,0,6,""},{193,-1317,-460,1,57,"Tempest"},{194,-1335,13,0,58,""},{195,-1279,-9,0,59,""},{196,-1224,-31,0,58,""},{197,-1168,-53,1,60,"Deadeye"},{198,-1200,358,0,26,""},{199,-1244,421,0,27,""},
  {200,-1313,417,0,27,""},{201,-1348,337,0,27,""},{202,-1303,283,0,26,""},{203,-1232,290,0,27,""},{204,-1275,352,1,61,"Shadowstep"},{205,-982,660,0,62,""},{206,-1027,724,0,63,""},{207,-1097,719,0,64,""},{208,-1132,654,0,62,""},{209,-1088,587,0,62,""},
  {210,-1008,598,0,58,""},{211,-1057,655,1,65,"Fervour"},{212,-834,924,0,27,""},{213,-871,971,0,26,""},{214,-908,1018,0,27,""},{215,-946,1065,1,66,"Fleet Foot"},{216,-474,1162,0,58,""},{217,-536,1224,0,63,""},{218,-617,1180,0,63,""},{219,-607,1105,0,63,""},
  {220,-523,1080,0,62,""},{221,-548,1150,1,67,"Battle Rhythm"},{222,-127,1268,0,58,""},{223,-199,1328,0,62,""},{224,-269,1284,0,58,""},{225,-250,1197,0,58,""},{226,-162,1189,0,62,""},{227,-201,1253,1,68,"Relentless Assault"},{228,303,1612,0,29,""},{229,339,1661,0,30,""},
  {230,374,1710,0,30,""},{231,409,1758,1,69,"Iron Will"},{232,799,1584,0,39,""},{233,758,1637,0,34,""},{234,677,1627,0,33,""},{235,651,1558,0,33,""},{236,695,1501,0,39,""},{237,777,1516,0,33,""},{238,725,1570,1,70,"Unbreakable"},{239,1085,1321,0,71,""},
  {240,991,1382,0,36,""},{241,939,1288,0,71,""},{242,1031,1238,0,71,""},{243,1011,1310,1,72,"Loyal Companions"},{244,1356,1074,0,71,""},{245,1295,1131,0,71,""},{246,1214,1087,0,36,""},{247,1223,1011,0,71,""},{248,1311,988,0,71,""},{249,1283,1057,1,73,"Grave Lord"},
  {250,1497,751,5,9,"Jewel Socket"},{251,1605,476,0,39,""},{252,1643,431,0,33,""},{253,1682,385,0,34,""},{254,1721,339,1,74,"Ironwood"},{255,1757,47,0,34,""},{256,1703,100,0,34,""},{257,1623,69,0,39,""},{258,1633,-26,0,39,""},{259,1709,-44,0,34,""},
  {260,1685,27,1,75,"Steelclad"},{261,1760,-345,0,6,""},{262,1699,-283,0,5,""},{263,1619,-321,0,6,""},{264,1631,-408,0,5,""},{265,1723,-421,0,5,""},{266,1686,-356,1,76,"Dark Pact"},{267,1581,-677,0,6,""},{268,1527,-624,0,6,""},{269,1442,-663,0,6,""},
  {270,1454,-749,0,6,""},{271,1539,-766,0,5,""},{272,1509,-697,1,77,"Nightfall"},{273,1363,-938,0,78,""},{274,1330,-988,0,6,""},{275,1297,-1038,0,6,""},{276,1263,-1088,1,79,"Deep Freeze"},{277,1019,-1336,0,16,""},{278,1079,-1342,0,17,""},{279,1138,-1349,0,17,""},
  {280,1198,-1355,1,80,"Wide Reach"},{281,858,-1561,0,49,""},{282,776,-1487,0,48,""},{283,709,-1571,0,48,""},{284,800,-1634,0,47,""},{285,783,-1561,1,81,"Sanctuary of Thought"},{286,483,-1662,0,36,""},{287,411,-1591,0,36,""},{288,341,-1634,0,36,""},{289,353,-1717,0,36,""},
  {290,443,-1733,0,36,""},{291,408,-1666,1,82,"Master of Beasts"},{292,103,-1704,0,49,""},{293,53,-1737,0,49,""},{294,3,-1770,0,47,""},{295,-47,-1804,1,83,"Prismatic Skin"},{296,-363,-1717,5,9,"Jewel Socket"},{297,-796,-1549,0,27,""},{298,-737,-1537,0,26,""},{299,-678,-1525,0,25,""},
  {300,-619,-1513,1,84,"Elusive"},{301,-992,-1381,0,85,""},{302,-1083,-1309,0,85,""},{303,-1141,-1396,0,44,""},{304,-1047,-1455,0,44,""},{305,-1067,-1383,1,86,"Wellspring"},{306,-1253,-1146,0,27,""},{307,-1302,-1111,0,27,""},{308,-1351,-1076,0,25,""},{309,-1400,-1041,1,87,"Phase Walk"},
  {310,-1470,-837,0,22,""},{311,-1503,-787,0,22,""},{312,-1537,-738,0,22,""},{313,-1571,-688,1,88,"Thunderous Roar"},{314,-1574,-399,0,16,""},{315,-1653,-329,0,16,""},{316,-1722,-419,0,17,""},{317,-1643,-479,0,17,""},{318,-1649,-404,1,89,"Cataclysm"},{319,-1602,-103,0,27,""},
  {320,-1633,-52,0,26,""},{321,-1664,-1,0,26,""},{322,-1696,50,1,84,"Shadowstep II"},{323,-1624,343,5,9,"Jewel Socket"},{324,-1581,731,0,90,""},{325,-1233,1024,0,22,""},{326,-1303,1083,0,6,""},{327,-1375,1037,0,6,""},{328,-1356,952,0,22,""},{329,-1272,941,0,6,""},
  {330,-1306,1008,1,91,"Wild Growth"},{331,-1021,1250,0,92,""},{332,-1062,1293,0,93,""},{333,-1104,1336,0,92,""},{334,-1146,1379,1,94,"Coup de Grace"},{335,-695,1545,0,30,""},{336,-766,1608,0,30,""},{337,-839,1559,0,29,""},{338,-823,1481,0,31,""},{339,-726,1472,0,30,""},
  {340,-769,1533,1,95,"Heavy Hitter"},{341,-325,1702,0,96,""},{342,-384,1692,0,97,""},{343,-443,1683,0,96,""},{344,-503,1673,1,98,"Juggernaut"},{345,47,1691,0,58,""},{346,-3,1753,0,63,""},{347,-66,1745,0,64,""},{348,-102,1677,0,58,""},{349,-53,1611,0,58,""},
  {350,22,1625,0,58,""},{351,-27,1681,1,99,"Swift Killer"},{352,441,2102,0,100,""},{353,359,2167,0,101,""},{354,292,2088,0,100,""},{355,388,2021,0,102,""},{356,367,2093,1,103,"Aegis"},{357,724,1933,0,104,""},{358,994,1784,0,39,""},{359,1054,1791,0,33,""},
  {360,1113,1799,0,33,""},{361,1173,1806,1,105,"Bulwark"},{362,1396,1510,0,64,""},{363,1413,1567,0,64,""},{364,1430,1625,0,62,""},{365,1448,1682,1,106,"Weapon Master"},{366,1663,1286,5,9,"Jewel Socket"},{367,1827,936,0,104,""},{368,2058,611,0,104,""},{369,1997,283,0,85,""},
  {370,2035,237,0,85,""},{371,2074,191,0,85,""},{372,2113,145,1,107,"Arcane Focus"},{373,2163,-163,0,10,""},{374,2113,-99,0,11,""},{375,2048,-106,0,10,""},{376,2014,-180,0,11,""},{377,2055,-237,0,11,""},{378,2135,-228,0,11,""},{379,2088,-170,1,108,"Mending"},
  {380,2048,-558,5,9,"Jewel Socket"},{381,1896,-917,5,9,"Jewel Socket"},{382,1777,-1252,0,109,""},{383,1733,-1187,0,109,""},{384,1653,-1198,0,110,""},{385,1627,-1259,0,111,""},{386,1679,-1327,0,109,""},{387,1742,-1319,0,111,""},{388,1702,-1255,1,112,"Clarity"},{389,1474,-1496,0,6,""},
  {390,1394,-1425,0,78,""},{391,1324,-1508,0,6,""},{392,1412,-1573,0,6,""},{393,1399,-1500,1,113,"Glacial Heart"},{394,1181,-1801,0,16,""},{395,1133,-1765,0,16,""},{396,1085,-1729,0,16,""},{397,1037,-1693,1,114,"Devastation"},{398,845,-1920,0,6,""},{399,802,-1855,0,6,""},
  {400,716,-1872,0,6,""},{401,696,-1931,0,6,""},{402,740,-1992,0,19,""},{403,824,-1976,0,19,""},{404,771,-1924,1,115,"Ignition"},{405,505,-2081,0,19,""},{406,446,-2088,0,6,""},{407,386,-2096,0,19,""},{408,327,-2104,1,115,"Fireborn"},{409,95,-2042,0,54,""},
  {410,34,-1989,0,53,""},{411,-39,-2023,0,116,""},{412,-31,-2115,0,116,""},{413,54,-2132,0,116,""},{414,24,-2064,1,117,"Bloodthirst"},{415,-281,-2007,0,19,""},{416,-333,-1951,0,19,""},{417,-424,-1996,0,19,""},{418,-411,-2072,0,19,""},{419,-319,-2089,0,6,""},
  {420,-354,-2023,1,118,"Burning Heart"},{421,-653,-1945,0,22,""},{422,-708,-1874,0,22,""},{423,-798,-1917,0,6,""},{424,-785,-1996,0,6,""},{425,-688,-2009,0,6,""},{426,-728,-1946,1,119,"Earthshaker"},{427,-995,-1769,0,6,""},{428,-1051,-1700,0,6,""},{429,-1135,-1735,0,19,""},
  {430,-1122,-1826,0,6,""},{431,-1037,-1840,0,19,""},{432,-1070,-1772,1,118,"Emberstorm"},{433,-1333,-1618,0,22,""},{434,-1390,-1601,0,6,""},{435,-1448,-1584,0,6,""},{436,-1505,-1567,1,120,"Stormcaller II"},{437,-1595,-1345,0,45,""},{438,-1622,-1292,0,45,""},{439,-1650,-1239,0,45,""},
  {440,-1678,-1185,1,121,"Sorcery"},{441,-1837,-941,0,90,""},{442,-1945,-587,0,110,""},{443,-1986,-532,0,109,""},{444,-2061,-537,0,111,""},{445,-2094,-600,0,111,""},{446,-2040,-671,0,111,""},{447,-1978,-662,0,109,""},{448,-2019,-599,1,122,"Insight"},{449,-2087,-217,5,9,"Jewel Socket"},
  {450,-2073,119,0,111,""},{451,-2121,156,0,110,""},{452,-2168,192,0,111,""},{453,-2216,229,1,123,"Mana Flow"},{454,-2105,525,0,36,""},{455,-2048,541,0,71,""},{456,-1990,558,0,36,""},{457,-1932,574,1,124,"Pack Leader"},{458,-1923,930,5,9,"Jewel Socket"},{459,-1602,1256,0,26,""},
  {460,-1685,1309,0,25,""},{461,-1746,1213,0,26,""},{462,-1653,1163,0,27,""},{463,-1674,1235,1,125,"Phase Walk II"},{464,-1404,1505,0,126,""},{465,-1032,1748,0,25,""},{466,-1088,1816,0,26,""},{467,-1172,1781,0,26,""},{468,-1165,1696,0,26,""},{469,-1081,1673,0,27,""},
  {470,-1107,1743,1,127,"Elusive II"},{471,-818,1990,0,13,""},{472,-784,1940,0,14,""},{473,-751,1891,0,14,""},{474,-717,1841,1,128,"Lingering Death II"},{475,-504,2097,0,13,""},{476,-444,2090,0,13,""},{477,-385,2082,0,13,""},{478,-325,2075,1,129,"Withering II"},{479,62,2165,0,30,""},
  {480,4,2148,0,29,""},{481,-53,2131,0,30,""},{482,-111,2113,1,130,"Bone Breaker"},{483,216,2515,0,101,""},{484,125,2567,0,102,""},{485,72,2472,0,102,""},{486,148,2420,0,100,""},{487,143,2495,1,131,"Shield Wall"},{488,446,2461,0,53,""},{489,506,2462,0,54,""},
  {490,566,2462,0,54,""},{491,626,2463,1,132,"Crimson Tide"},{492,996,2392,0,54,""},{493,941,2444,0,53,""},{494,883,2433,0,116,""},{495,850,2358,0,53,""},{496,887,2305,0,53,""},{497,970,2311,0,116,""},{498,924,2371,1,133,"Hemomancy"},{499,1320,2082,0,134,""},
  {500,1265,2107,0,96,""},{501,1211,2132,0,97,""},{502,1156,2157,1,135,"Unyielding"},{503,1617,1967,0,5,""},{504,1576,1923,0,5,""},{505,1535,1880,0,5,""},{506,1495,1836,1,136,"Void Touched II"},{507,1984,1709,0,6,""},{508,1918,1776,0,6,""},{509,1842,1734,0,42,""},
  {510,1859,1646,0,42,""},{511,1937,1632,0,6,""},{512,1909,1702,1,137,"Zealotry"},{513,2083,1266,0,10,""},{514,2098,1324,0,10,""},{515,2114,1382,0,10,""},{516,2129,1440,1,138,"Renewal"},{517,2349,1014,0,100,""},{518,2308,1067,0,102,""},{519,2233,1061,0,102,""},
  {520,2202,981,0,102,""},{521,2250,929,0,101,""},{522,2326,945,0,102,""},{523,2275,999,1,139,"Stalwart"},{524,2454,644,5,9,"Jewel Socket"},{525,2508,251,5,9,"Jewel Socket"},{526,2576,-82,0,42,""},{527,2533,-123,0,6,""},{528,2490,-165,0,6,""},{529,2447,-207,1,140,"Sanctity"},
  {530,2493,-506,0,6,""},{531,2417,-452,0,6,""},{532,2346,-535,0,6,""},{533,2440,-600,0,5,""},{534,2421,-527,1,141,"Dark Pact II"},{535,2350,-878,0,10,""},{536,2262,-813,0,10,""},{537,2202,-897,0,10,""},{538,2290,-960,0,11,""},{539,2276,-887,1,138,"Lifebloom"},
  {540,2161,-1262,0,142,""},{541,1930,-1579,5,9,"Jewel Socket"},{542,1742,-1864,0,48,""},{543,1683,-1797,0,48,""},{544,1597,-1845,0,48,""},{545,1615,-1924,0,49,""},{546,1705,-1936,0,49,""},{547,1667,-1871,1,143,"Discipline"},{548,1394,-2041,0,85,""},{549,1348,-1987,0,85,""},
  {550,1280,-1994,0,85,""},{551,1247,-2068,0,45,""},{552,1296,-2127,0,85,""},{553,1361,-2120,0,45,""},{554,1321,-2057,1,144,"Quickened Mind"},{555,1095,-2308,0,6,""},{556,1040,-2257,0,78,""},{557,978,-2270,0,6,""},{558,948,-2335,0,6,""},{559,989,-2396,0,6,""},
  {560,1070,-2388,0,6,""},{561,1023,-2330,1,145,"Coldsnap"},{562,705,-2396,0,49,""},{563,619,-2328,0,47,""},{564,556,-2412,0,47,""},{565,640,-2476,0,49,""},{566,631,-2402,1,146,"Mental Ward"},{567,321,-2460,0,54,""},{568,245,-2404,0,54,""},{569,175,-2495,0,116,""},
  {570,254,-2554,0,54,""},{571,248,-2479,1,147,"Vampirism"},{572,-69,-2502,0,6,""},{573,-126,-2434,0,6,""},{574,-208,-2467,0,6,""},{575,-197,-2560,0,6,""},{576,-104,-2570,0,6,""},{577,-144,-2507,1,148,"Whispers II"},{578,-470,-2491,0,45,""},{579,-554,-2425,0,45,""},
  {580,-618,-2515,0,44,""},{581,-532,-2573,0,44,""},{582,-544,-2499,1,149,"Spellcraft II"},{583,-877,-2262,0,6,""},{584,-901,-2317,0,150,""},{585,-926,-2372,0,150,""},{586,-950,-2427,1,151,"Astral Flow"},{587,-1211,-2078,0,11,""},{588,-1243,-2129,0,11,""},{589,-1274,-2180,0,11,""},
  {590,-1306,-2231,1,152,"Faithful"},{591,-1609,-1841,0,85,""},{592,-1586,-1896,0,45,""},{593,-1563,-1952,0,44,""},{594,-1540,-2007,1,153,"Quickened Mind II"},{595,-1795,-1662,0,6,""},{596,-1849,-1595,0,22,""},{597,-1938,-1635,0,6,""},{598,-1929,-1712,0,22,""},{599,-1827,-1728,0,22,""},
  {600,-1870,-1667,1,154,"Thunderous Roar II"},{601,-2224,-1433,0,110,""},{602,-2175,-1398,0,110,""},{603,-2126,-1364,0,109,""},{604,-2077,-1329,1,155,"Deep Wisdom"},{605,-2303,-916,0,111,""},{606,-2293,-975,0,111,""},{607,-2283,-1035,0,110,""},{608,-2274,-1094,1,156,"Wellspring of Power"},{609,-2427,-637,5,9,"Jewel Socket"},
  {610,-2463,-250,0,6,""},{611,-2525,-180,0,22,""},{612,-2608,-228,0,6,""},{613,-2593,-304,0,6,""},{614,-2501,-319,0,22,""},{615,-2538,-254,1,157,"Wild Growth II"},{616,-2498,144,0,158,""},{617,-2408,551,0,64,""},{618,-2451,609,0,62,""},{619,-2527,601,0,58,""},
  {620,-2557,531,0,58,""},{621,-2500,468,0,58,""},{622,-2441,479,0,63,""},{623,-2483,541,1,159,"Brutal Blade"},{624,-2459,891,0,58,""},{625,-2404,914,0,58,""},{626,-2349,938,0,59,""},{627,-2294,961,1,160,"Hunter's Focus"},{628,-2186,1202,0,58,""},{629,-2200,1260,0,59,""},
  {630,-2214,1318,0,58,""},{631,-2228,1377,1,161,"Far Shot"},{632,-1996,1520,0,58,""},{633,-1948,1556,0,58,""},{634,-1900,1592,0,44,""},{635,-1852,1628,1,162,"Lightning Reflexes"},{636,-1685,1975,0,58,""},{637,-1682,1915,0,64,""},{638,-1679,1856,0,58,""},{639,-1676,1796,1,163,"Bladedancer"},
  {640,-1320,2055,5,9,"Jewel Socket"},{641,-926,2293,0,63,""},{642,-979,2347,0,62,""},{643,-1043,2335,0,63,""},{644,-1073,2262,0,64,""},{645,-1019,2202,0,58,""},{646,-946,2221,0,63,""},{647,-999,2274,1,164,"Weapon Master II"},{648,-553,2401,0,13,""},{649,-626,2455,0,14,""},
  {650,-698,2365,0,13,""},{651,-619,2305,0,13,""},{652,-625,2380,1,165,"Wasting Affliction II"},{653,-174,2489,0,101,""},{654,-217,2547,0,102,""},{655,-299,2534,0,100,""},{656,-320,2460,0,102,""},{657,-283,2413,0,100,""},{658,-208,2415,0,101,""},{659,-248,2479,1,166,"Sentinel"},
  {660,366,2896,0,54,""},{661,309,2917,0,116,""},{662,253,2938,0,54,""},{663,197,2960,1,167,"Bloodthirst II"},{664,671,2834,5,9,"Jewel Socket"},{665,1121,2725,0,6,""},{666,1078,2778,0,6,""},{667,1000,2767,0,6,""},{668,974,2695,0,5,""},{669,1025,2638,0,5,""},
  {670,1102,2658,0,6,""},{671,1048,2709,1,168,"Umbral Heart II"},{672,1484,2564,0,71,""},{673,1438,2618,0,71,""},{674,1358,2602,0,71,""},{675,1337,2535,0,36,""},{676,1380,2479,0,71,""},{677,1459,2491,0,36,""},{678,1410,2548,1,169,"Dark Legion"},{679,1709,2393,0,97,""},
  {680,1719,2334,0,134,""},{681,1729,2275,0,96,""},{682,1739,2216,1,170,"Heart of Oak"},{683,2117,2078,0,36,""},{684,2039,2145,0,71,""},{685,1971,2050,0,71,""},{686,2044,1995,0,71,""},{687,2043,2070,1,171,"Pack Leader II"},{688,2368,1776,0,42,""},{689,2310,1761,0,6,""},
  {690,2252,1746,0,6,""},{691,2194,1731,1,172,"Divine Light"},{692,2485,1503,0,42,""},{693,2479,1443,0,42,""},{694,2473,1384,0,42,""},{695,2467,1324,1,173,"Righteous Fury"},{696,2744,1077,0,6,""},{697,2697,1143,0,42,""},{698,2623,1132,0,6,""},{699,2595,1064,0,6,""},
  {700,2646,1002,0,42,""},{701,2709,1010,0,6,""},{702,2669,1073,1,174,"Blessed"},{703,2846,708,0,6,""},{704,2795,766,0,42,""},{705,2731,758,0,6,""},{706,2698,684,0,6,""},{707,2737,629,0,42,""},{708,2815,634,0,42,""},{709,2772,695,1,173,"Righteous Fury II"},
  {710,2885,229,0,42,""},{711,2861,284,0,6,""},{712,2837,339,0,42,""},{713,2813,394,1,174,"Divine Light II"},{714,2867,-79,0,142,""},{715,2894,-564,0,11,""},{716,2881,-505,0,11,""},{717,2868,-447,0,11,""},{718,2856,-388,1,175,"Grace"},{719,2710,-778,0,42,""},
  {720,2741,-829,0,6,""},{721,2772,-881,0,42,""},{722,2803,-932,1,173,"Sanctity II"},{723,2715,-1313,0,110,""},{724,2677,-1266,0,109,""},{725,2640,-1220,0,110,""},{726,2602,-1173,1,176,"Deep Wisdom II"},{727,2394,-1643,0,11,""},{728,2400,-1584,0,11,""},{729,2407,-1524,0,10,""},
  {730,2414,-1465,1,175,"Mending II"},{731,2276,-1880,0,85,""},{732,2216,-1881,0,85,""},{733,2156,-1881,0,85,""},{734,2096,-1882,1,177,"Arcane Focus II"},{735,1992,-2165,0,78,""},{736,1924,-2095,0,78,""},{737,1851,-2134,0,78,""},{738,1859,-2217,0,6,""},{739,1944,-2239,0,78,""},
  {740,1917,-2169,1,178,"Winter's Embrace"},{741,1675,-2389,0,150,""},{742,1637,-2342,0,150,""},{743,1558,-2349,0,6,""},{744,1529,-2423,0,150,""},{745,1571,-2477,0,6,""},{746,1647,-2470,0,6,""},{747,1603,-2409,1,179,"Prismatic Mind"},{748,1337,-2621,0,53,""},{749,1280,-2600,0,53,""},
  {750,1224,-2578,0,54,""},{751,1168,-2557,1,180,"Hemomancy II"},{752,820,-2753,0,6,""},{753,876,-2775,0,6,""},{754,932,-2796,0,6,""},{755,988,-2818,1,181,"Searing Heat"},{756,450,-2747,0,49,""},{757,487,-2794,0,49,""},{758,524,-2842,0,47,""},{759,560,-2889,1,182,"Arcane Barrier II"},
  {760,120,-2939,0,142,""},{761,-207,-2926,0,71,""},{762,-251,-2861,0,36,""},{763,-323,-2867,0,71,""},{764,-355,-2945,0,36,""},{765,-310,-2999,0,71,""},{766,-243,-2994,0,71,""},{767,-282,-2929,1,171,"Master of Beasts II"},{768,-699,-2714,0,5,""},{769,-674,-2768,0,5,""},
  {770,-649,-2823,0,6,""},{771,-624,-2877,1,183,"Nightfall II"},{772,-977,-2775,0,6,""},{773,-1030,-2746,0,22,""},{774,-1083,-2718,0,22,""},{775,-1136,-2690,1,184,"Conductivity II"},{776,-1353,-2564,0,6,""},{777,-1413,-2504,0,6,""},{778,-1496,-2549,0,22,""},{779,-1482,-2629,0,22,""},
  {780,-1404,-2649,0,6,""},{781,-1427,-2578,1,185,"Earthshaker II"},{782,-1692,-2410,0,6,""},{783,-1734,-2368,0,22,""},{784,-1777,-2326,0,6,""},{785,-1820,-2284,1,186,"Tempest II"},{786,-1987,-2098,0,13,""},{787,-2047,-2103,0,13,""},{788,-2107,-2107,0,13,""},{789,-2167,-2111,1,187,"Festering Wounds II"},
  {790,-2291,-1841,0,11,""},{791,-2283,-1782,0,11,""},{792,-2275,-1722,0,11,""},{793,-2267,-1663,1,175,"Lifebloom II"},{794,-2551,-1457,5,9,"Jewel Socket"},{795,-2621,-1072,0,16,""},{796,-2701,-1009,0,16,""},{797,-2770,-1084,0,17,""},{798,-2680,-1157,0,16,""},{799,-2695,-1083,1,188,"Blast Radius II"},
  {800,-2728,-683,0,64,""},{801,-2771,-633,0,64,""},{802,-2845,-642,0,64,""},{803,-2874,-717,0,63,""},{804,-2830,-771,0,64,""},{805,-2753,-760,0,63,""},{806,-2800,-702,1,189,"Bladedancer II"},{807,-2845,-310,0,58,""},{808,-2933,-246,0,58,""},{809,-2994,-327,0,58,""},
  {810,-2920,-395,0,59,""},{811,-2920,-320,1,190,"Marksman"},{812,-2890,17,0,27,""},{813,-2933,60,0,25,""},{814,-2975,103,0,27,""},{815,-3017,145,1,191,"Fleet Foot II"},{816,-2839,470,5,9,"Jewel Socket"},{817,-2651,832,0,6,""},{818,-2709,844,0,22,""},{819,-2768,855,0,22,""},
  {820,-2827,866,1,185,"Stormcaller III"},{821,-2541,1235,0,92,""},{822,-2595,1295,0,92,""},{823,-2666,1277,0,93,""},{824,-2689,1217,0,92,""},{825,-2638,1151,0,93,""},{826,-2568,1163,0,92,""},{827,-2614,1222,1,192,"Vital Strike"},{828,-2346,1572,0,64,""},{829,-2394,1635,0,58,""},
  {830,-2460,1629,0,64,""},{831,-2493,1544,0,58,""},{832,-2455,1498,0,58,""},{833,-2383,1501,0,63,""},{834,-2421,1565,1,193,"Relentless Assault II"},{835,-2158,1857,5,9,"Jewel Socket"},{836,-1960,2122,0,26,""},{837,-1956,2181,0,27,""},{838,-1952,2241,0,27,""},{839,-1948,2301,1,194,"Windwalker II"},
  {840,-1555,2451,0,92,""},{841,-1637,2525,0,92,""},{842,-1705,2448,0,92,""},{843,-1626,2375,0,92,""},{844,-1630,2450,1,195,"Killing Spree"},{845,-1260,2605,5,9,"Jewel Socket"},{846,-824,2775,0,54,""},{847,-868,2837,0,53,""},{848,-945,2827,0,54,""},{849,-973,2760,0,116,""},
  {850,-922,2697,0,53,""},{851,-860,2704,0,53,""},{852,-899,2768,1,180,"Feast of Flesh II"},{853,-510,2843,0,90,""},{854,-44,2866,0,62,""},{855,-97,2919,0,62,""},{856,-166,2903,0,58,""},{857,-191,2847,0,64,""},{858,-153,2782,0,64,""},{859,-69,2788,0,64,""},
  {860,-116,2847,1,196,"Fervour II"},{861,185,3346,2,197,"Vaal Pact"},{862,181,3276,0,116,""},{863,177,3207,0,116,""},{864,568,3193,2,198,"Unwavering Stance"},{865,556,3124,0,71,""},{866,543,3055,0,36,""},{867,952,3113,2,199,"Blood Magic"},{868,932,3046,0,96,""},{869,911,2979,0,134,""},
  {870,1360,3066,2,200,"Berserker's Wrath"},{871,1332,3002,0,78,""},{872,1304,2938,0,78,""},{873,1706,2856,5,9,"Jewel Socket"},{874,2099,2614,0,97,""},{875,2049,2683,0,97,""},{876,1971,2664,0,97,""},{877,1951,2598,0,134,""},{878,2000,2541,0,96,""},{879,2065,2549,0,134,""},
  {880,2024,2612,1,201,"Thick Skin"},{881,2375,2341,0,39,""},{882,2318,2398,0,39,""},{883,2232,2355,0,33,""},{884,2256,2266,0,34,""},{885,2338,2260,0,33,""},{886,2301,2325,1,202,"Iron Skin II"},{887,2624,2078,2,203,"Avatar of Frost"},{888,2569,2035,0,11,""},{889,2515,1991,0,11,""},
  {890,2880,1739,0,39,""},{891,2812,1793,0,33,""},{892,2741,1751,0,34,""},{893,2751,1670,0,33,""},{894,2846,1653,0,39,""},{895,2808,1718,1,202,"Bastion II"},{896,3073,1370,0,42,""},{897,3029,1437,0,42,""},{898,2955,1429,0,42,""},{899,2924,1356,0,42,""},
  {900,2977,1296,0,42,""},{901,3037,1304,0,6,""},{902,2998,1368,1,204,"Zealotry II"},{903,3118,990,2,205,"Glancing Blows"},{904,3051,968,0,42,""},{905,2984,947,0,42,""},{906,3300,531,0,6,""},{907,3291,590,0,42,""},{908,3282,650,0,42,""},{909,3273,709,1,206,"Lightbringer II"},
  {910,3404,220,0,5,""},{911,3348,291,0,6,""},{912,3284,279,0,6,""},{913,3255,208,0,6,""},{914,3299,150,0,6,""},{915,3373,158,0,6,""},{916,3329,219,1,207,"Soul Siphon II"},{917,3320,-183,2,208,"Radiant Faith"},{918,3250,-179,0,109,""},{919,3180,-176,0,109,""},
  {920,3299,-634,0,10,""},{921,3254,-594,0,10,""},{922,3209,-555,0,10,""},{923,3164,-516,1,209,"Renewal II"},{924,3111,-951,2,210,"Prodigy"},{925,3044,-931,0,11,""},{926,2977,-910,0,10,""},{927,3058,-1403,0,111,""},{928,3021,-1356,0,109,""},{929,2984,-1309,0,109,""},
  {930,2947,-1261,1,211,"Clarity II"},{931,2924,-1682,0,6,""},{932,2869,-1631,0,6,""},{933,2787,-1667,0,42,""},{934,2804,-1762,0,42,""},{935,2892,-1767,0,42,""},{936,2852,-1704,1,204,"Blessed II"},{937,2589,-2006,2,212,"Mind over Matter"},{938,2534,-1964,0,42,""},{939,2478,-1921,0,42,""},
  {940,2333,-2309,2,213,"Many Faces"},{941,2284,-2260,0,16,""},{942,2234,-2211,0,16,""},{943,2028,-2560,2,214,"Hollow Vessel"},{944,1984,-2506,0,6,""},{945,1941,-2451,0,6,""},{946,1726,-2822,2,215,"Chain Reaction"},{947,1690,-2763,0,48,""},{948,1653,-2703,0,48,""},{949,1329,-3112,0,5,""},
  {950,1370,-3068,0,6,""},{951,1411,-3024,0,6,""},{952,1452,-2981,1,216,"Void Touched III"},{953,986,-3107,2,217,"Avatar of Flame"},{954,965,-3041,0,13,""},{955,944,-2974,0,14,""},{956,604,-3203,5,9,"Jewel Socket"},{957,217,-3296,2,218,"Ghost Reaver"},{958,212,-3227,0,48,""},{959,208,-3157,0,48,""},
  {960,-179,-3245,5,9,"Jewel Socket"},{961,-582,-3274,2,219,"Avatar of Shadow"},{962,-570,-3205,0,36,""},{963,-558,-3136,0,36,""},{964,-965,-3155,2,220,"Pain Attunement"},{965,-945,-3088,0,14,""},{966,-924,-3021,0,13,""},{967,-1265,-3015,0,44,""},{968,-1306,-2953,0,45,""},{969,-1386,-2961,0,45,""},
  {970,-1412,-3041,0,44,""},{971,-1374,-3087,0,44,""},{972,-1299,-3083,0,44,""},{973,-1340,-3020,1,221,"Sorcery II"},{974,-1699,-2844,2,222,"Volatile Legion"},{975,-1663,-2784,0,26,""},{976,-1627,-2724,0,25,""},{977,-2005,-2587,0,142,""},{978,-2308,-2333,2,223,"Wind Dancer"},{979,-2259,-2283,0,19,""},
  {980,-2210,-2233,0,6,""},{981,-2582,-2045,5,9,"Jewel Socket"},{982,-2726,-1713,0,58,""},{983,-2775,-1643,0,64,""},{984,-2848,-1655,0,62,""},{985,-2874,-1729,0,58,""},{986,-2826,-1784,0,64,""},{987,-2748,-1767,0,62,""},{988,-2801,-1713,1,224,"Brutal Blade II"},{989,-2916,-1359,0,44,""},
  {990,-2954,-1300,0,85,""},{991,-3042,-1310,0,85,""},{992,-3066,-1366,0,44,""},{993,-3019,-1435,0,45,""},{994,-2948,-1426,0,44,""},{995,-2991,-1365,1,225,"Thaumaturgy II"},{996,-3163,-1004,2,226,"Avatar of Storm"},{997,-3097,-983,0,17,""},{998,-3030,-962,0,17,""},{999,-3209,-605,2,227,"Ancestral Bond"},
  {1000,-3140,-592,0,16,""},{1001,-3071,-579,0,16,""},{1002,-3382,-139,0,22,""},{1003,-3356,-193,0,22,""},{1004,-3330,-247,0,6,""},{1005,-3304,-301,1,228,"Thunderous Roar III"},{1006,-3258,180,2,229,"Lone Wolf"},{1007,-3188,176,0,16,""},{1008,-3118,172,0,16,""},{1009,-3180,583,0,26,""},
  {1010,-3255,654,0,26,""},{1011,-3328,562,0,25,""},{1012,-3252,504,0,27,""},{1013,-3255,579,1,230,"Shadowstep III"},{1014,-3120,954,2,231,"Point Blank"},{1015,-3053,934,0,27,""},{1016,-2986,913,0,27,""},{1017,-2907,1329,0,13,""},{1018,-2960,1395,0,13,""},{1019,-3044,1366,0,13,""},
  {1020,-3039,1275,0,13,""},{1021,-2956,1253,0,14,""},{1022,-2982,1323,1,232,"Slow Rot II"},{1023,-2832,1692,2,233,"Unleashed Pack"},{1024,-2772,1656,0,25,""},{1025,-2712,1620,0,27,""},{1026,-2632,2039,2,234,"Acrobatics"},{1027,-2576,1997,0,59,""},{1028,-2521,1954,0,58,""},{1029,-2415,2412,0,63,""},
  {1030,-2380,2363,0,58,""},{1031,-2346,2314,0,63,""},{1032,-2311,2265,1,235,"Swift Killer II"},{1033,-2078,2624,2,236,"Perfect Agony"},{1034,-2035,2569,0,44,""},{1035,-1991,2515,0,44,""},{1036,-1627,2800,0,34,""},{1037,-1687,2804,0,33,""},{1038,-1747,2809,0,33,""},{1039,-1807,2813,1,237,"Unbreakable II"},
  {1040,-1304,3028,0,14,""},{1041,-1395,3093,0,14,""},{1042,-1453,3017,0,13,""},{1043,-1372,2945,0,14,""},{1044,-1378,3020,1,238,"Lingering Death III"},{1045,-1000,3149,2,239,"Iron Reflexes"},{1046,-978,3082,0,13,""},{1047,-957,3016,0,13,""},{1048,-618,3273,2,240,"Executioner"},{1049,-605,3204,0,30,""},
  {1050,-592,3135,0,30,""},{1051,-152,3316,0,96,""},{1052,-193,3273,0,96,""},{1053,-234,3229,0,96,""},{1054,-275,3185,1,241,"Constitution"},{1055,645,507,4,2,""},{1056,113,-865,4,3,""},{1057,-290,-804,4,3,""},{1058,-846,360,4,4,""},{1059,-613,710,4,4,""},
  {1060,1204,-1165,4,3,""},{1061,-155,-1727,4,3,""},{1062,-550,-1627,4,3,""},{1063,-1628,146,4,4,""},{1064,-1603,537,4,4,""},{1065,1233,1679,4,2,""},{1066,1530,1398,4,2,""},{1067,1745,1111,4,2,""},{1068,1943,774,4,2,""},{1069,1972,-737,4,3,""},
  {1070,271,-2065,4,3,""},{1071,-220,2119,4,2,""},{1072,678,2410,4,2,""},{1073,2481,448,4,2,""},{1074,2046,-1421,4,3,""},{1075,-760,-2416,4,3,""},{1076,-1072,-2223,4,3,""},{1077,-2234,-1187,4,4,""},{1078,-2295,1058,4,4,""},{1079,-1815,1736,4,4,""},
  {1080,-1503,2015,4,4,""},{1081,2177,1878,4,2,""},{1082,2838,459,4,2,""},{1083,2874,-292,4,3,""},{1084,2709,-1048,4,3,""},{1085,2558,-1448,4,3,""},{1086,2070,-1988,4,3,""},{1087,-1192,-2655,4,3,""},{1088,-2169,-1972,4,3,""},{1089,-2417,-1619,4,4,""},
  {1090,-2774,657,4,4,""},{1091,133,2892,4,2,""},{1092,323,1012,4,2,""},{1093,503,975,4,2,""},{1094,954,368,4,2,""},{1095,1042,153,4,2,""},{1096,1030,237,4,2,""},{1097,915,-628,4,3,""},{1098,1036,-390,4,3,""},{1099,679,-884,4,3,""},
  {1100,831,-723,4,3,""},{1101,311,-1043,4,3,""},{1102,111,-967,4,3,""},{1103,36,-1036,4,3,""},{1104,-121,-1064,4,3,""},{1105,-949,-594,4,4,""},{1106,-853,-767,4,3,""},{1107,-1028,-356,4,4,""},{1108,-1094,-149,4,4,""},{1109,-991,466,4,4,""},
  {1110,-630,889,4,4,""},{1111,398,1451,4,2,""},{1112,1114,845,4,2,""},{1113,1251,715,4,2,""},{1114,1483,-180,4,3,""},{1115,1121,-948,4,3,""},{1116,958,-1150,4,3,""},{1117,837,-1226,4,3,""},{1118,468,-1417,4,3,""},{1119,-13,-1539,4,3,""},
  {1120,-292,-1540,4,3,""},{1121,-410,-1465,4,3,""},{1122,-632,-1381,4,3,""},{1123,-784,-1279,4,3,""},{1124,-1207,-957,4,3,""},{1125,-1291,-820,4,4,""},{1126,-1454,-193,4,4,""},{1127,-1479,178,4,4,""},{1128,-1447,574,4,4,""},{1129,-1052,997,4,4,""},
  {1130,-847,1226,4,4,""},{1131,-262,1515,4,2,""},{1132,-460,1458,4,4,""},{1133,363,1841,4,2,""},{1134,531,1797,4,2,""},{1135,993,1583,4,2,""},{1136,1240,1416,4,2,""},{1137,1345,1320,4,2,""},{1138,1510,1180,4,2,""},{1139,1580,1018,4,2,""},
  {1140,1662,843,4,2,""},{1141,1851,521,4,2,""},{1142,1871,658,4,2,""},{1143,1684,704,4,2,""},{1144,1820,357,4,2,""},{1145,1886,-489,4,3,""},{1146,1717,-841,4,3,""},{1147,1492,-1093,4,3,""},{1148,1596,-982,4,3,""},{1149,444,-1910,4,3,""},
  {1150,-114,-1872,4,3,""},{1151,-508,-1831,4,3,""},{1152,-1462,-1201,4,3,""},{1153,-1670,-864,4,4,""},{1154,-1570,-1026,4,4,""},{1155,-1904,-318,4,4,""},{1156,-1853,33,4,4,""},{1157,-1848,231,4,4,""},{1158,-1836,442,4,4,""},{1159,-1814,636,4,4,""},
  {1160,-1752,831,4,4,""},{1161,-1617,947,4,4,""},{1162,-1233,1399,4,4,""},{1163,-584,1816,4,2,""},{1164,-385,1896,4,2,""},{1165,-255,1917,4,2,""},{1166,1,1950,4,2,""},{1167,615,2197,4,2,""},{1168,805,2119,4,2,""},{1169,982,2048,4,2,""},
  {1170,1159,1949,4,2,""},{1171,994,2020,4,2,""},{1172,1495,1745,4,2,""},{1173,1315,1857,4,2,""},{1174,1761,1466,4,2,""},{1175,1636,1607,4,2,""},{1176,1873,1276,4,2,""},{1177,1955,1101,4,2,""},{1178,2154,770,4,2,""},{1179,2256,628,4,2,""},
  {1180,2271,244,4,2,""},{1181,2348,-143,4,3,""},{1182,2028,-1090,4,3,""},{1183,680,-2160,4,3,""},{1184,345,-2246,4,3,""},{1185,-483,-2248,4,3,""},{1186,-621,-2217,4,3,""},{1187,-1354,-1861,4,3,""},{1188,-1593,-1632,4,3,""},{1189,-1722,-1470,4,3,""},
  {1190,-1899,-1345,4,4,""},{1191,-2006,-1170,4,4,""},{1192,-2065,-958,4,4,""},{1193,-2257,-427,4,4,""},{1194,-2275,-234,4,4,""},{1195,-2309,150,4,4,""},{1196,-2292,-37,4,4,""},{1197,-2164,922,4,4,""},{1198,-2255,720,4,4,""},{1199,-2055,1066,4,4,""},
  {1200,-1817,1433,4,4,""},{1201,-1543,1710,4,4,""},{1202,-1362,1780,4,4,""},{1203,-1053,2009,4,4,""},{1204,-719,2148,4,4,""},{1205,-364,2251,4,2,""},{1206,217,2742,4,2,""},{1207,406,2678,4,2,""},{1208,589,2648,4,2,""},{1209,1323,2293,4,2,""},
  {1210,1668,2151,4,2,""},{1211,1794,2009,4,2,""},{1212,2289,1384,4,2,""},{1213,2622,440,4,2,""},{1214,2684,268,4,2,""},{1215,2657,464,4,2,""},{1216,2688,86,4,2,""},{1217,2687,-506,4,3,""},{1218,2707,-314,4,3,""},{1219,2419,-1264,4,3,""},
  {1220,2484,-1113,4,3,""},{1221,2281,-1423,4,3,""},{1222,2073,-1730,4,3,""},{1223,1979,-1872,4,3,""},{1224,932,-2585,4,3,""},{1225,187,-2746,4,3,""},{1226,-428,-2720,4,3,""},{1227,-966,-2532,4,3,""},{1228,-798,-2645,4,3,""},{1229,-1328,-2317,4,3,""},
  {1230,-1660,-2132,4,3,""},{1231,-1958,-1905,4,3,""},{1232,-1787,-1997,4,3,""},{1233,-2254,-1607,4,4,""},{1234,-2422,-1216,4,4,""},{1235,-2694,80,4,4,""},{1236,-2749,-105,4,4,""},{1237,-2171,1546,4,4,""},{1238,-2053,1707,4,4,""},{1239,-1473,2215,4,4,""},
  {1240,-1656,2175,4,4,""},{1241,-1152,2470,4,4,""},{1242,-1290,2330,4,4,""},{1243,-404,2689,4,2,""},{1244,-568,2649,4,2,""},{1245,1572,2737,4,2,""},{1246,1707,2625,4,2,""},{1247,2019,2343,4,2,""},{1248,2555,1764,4,2,""},{1249,2702,1400,4,2,""},
  {1250,3068,649,4,2,""},{1251,3080,408,4,2,""},{1252,3070,219,4,2,""},{1253,3061,64,4,2,""},{1254,3074,-579,4,3,""},{1255,2998,-712,4,3,""},{1256,2590,-1655,4,3,""},{1257,1353,-2845,4,3,""},{1258,546,-2999,4,3,""},{1259,712,-2978,4,3,""},
  {1260,-1870,-2478,4,3,""},{1261,-2026,-2345,4,3,""},{1262,-2437,-1943,4,3,""},{1263,-2504,-1747,4,4,""},{1264,-3175,-260,4,4,""},{1265,-3157,-39,4,4,""},{1266,-3010,527,4,4,""},{1267,-2340,1905,4,4,""},{1268,-2168,2272,4,4,""},{1269,-1316,2775,4,4,""},
  {1270,-180,3088,4,2,""},{1271,636,264,4,2,""},{1272,669,-147,4,3,""},{1273,-413,-564,4,3,""},{1274,-677,119,4,4,""},{1275,-638,367,4,4,""},{1276,-168,628,4,4,""},{1277,541,394,4,2,""},{1278,660,64,4,3,""},{1279,669,-147,4,3,""},
  {1280,174,-637,4,3,""},{1281,-507,-389,4,4,""},{1282,-677,-41,4,4,""},{1283,-638,367,4,4,""},{1284,-544,497,4,4,""},
}
for _, r in ipairs(N) do P.x[r[1]], P.y[r[1]], P.t[r[1]], P.text[r[1]], P.name[r[1]] = r[2], r[3], r[4], TX[r[5]], r[6] end
P.edges = {1,20,1,44,1,1276,2,24,2,1271,2,1278,3,36,3,1274,3,1275,3,1283,4,38,4,106,4,1284,5,26,5,61,5,1272,5,1279,6,22,6,49,6,1277,7,34,7,84,7,1282,8,28,8,68,9,30,9,73,9,1280,11,32,11,1273,11,1281,20,21,20,39,21,22,22,23,23,24,24,25,25,26,26,27,27,28,28,29,29,30,30,31,31,32,32,33,33,34,34,35,35,36,36,37,37,38,38,39,40,41,40,45,40,49,41,42,41,108,42,43,43,44,43,46,44,45,47,48,47,118,48,49,48,1092,48,1093,49,50,49,51,50,1055,52,121,52,1055,52,1094,52,1096,52,1271,52,1277,53,54,53,57,53,133,54,55,54,1095,55,56,55,58,55,1278,56,57,56,60,56,1272,56,1279,57,138,57,1098,59,60,60,61,61,62,62,63,62,65,63,64,63,67,64,1097,64,1100,66,67,66,1099,67,68,68,69,68,1280,69,70,69,72,69,1056,70,71,71,154,73,74,73,1057,74,75,74,1056,74,1102,74,1103,74,1104,75,76,77,78,77,1057,78,79,78,1273,79,80,80,81,80,83,80,179,80,1106,81,82,81,173,84,85,84,1281,85,86,86,87,87,88,87,90,87,1107,88,89,88,1105,91,92,91,1274,91,1282,92,93,92,1058,93,94,93,96,93,203,94,95,94,195,94,1108,97,98,97,205,97,212,97,1059,98,99,98,1058,98,1109,98,1275,98,1283,98,1284,99,100,101,102,102,103,102,225,103,104,103,220,103,1110,104,105,104,107,104,1059,105,106,106,1276,108,112,108,222,108,1092,109,110,110,111,110,236,111,112,111,1111,112,113,112,115,113,114,113,1093,116,117,116,119,117,118,117,241,118,119,118,120,121,122,122,123,122,1112,122,1113,123,124,125,126,125,251,126,127,127,128,128,129,128,131,128,1094,129,130,129,1095,132,133,132,257,132,1096,133,134,133,137,134,135,136,137,136,141,136,263,136,1114,137,138,138,139,139,140,139,142,140,141,140,144,143,144,143,146,143,269,144,145,144,1098,145,146,145,147,145,148,145,1097,146,273,148,149,148,1100,148,1115,149,150,149,152,149,1099,149,1116,149,1117,150,151,152,153,152,157,153,154,154,155,154,1101,155,156,155,158,155,159,156,157,156,1118,157,282,159,160,159,164,160,161,161,162,161,1103,162,163,162,165,162,166,163,164,164,287,166,167,166,170,167,168,167,1104,168,169,168,171,168,177,169,170,169,1120,170,1119,172,173,173,174,174,175,175,176,175,178,175,1123,176,177,176,1122,177,1121,179,180,180,181,181,182,181,186,182,183,182,185,183,184,183,302,186,187,186,1124,186,1125,187,188,187,1105,187,1106,188,189,190,191,190,195,190,1107,190,1108,191,192,191,314,192,193,194,195,194,319,194,1126,194,1127,195,196,196,197,198,199,198,1109,199,200,199,209,200,201,200,1128,201,202,201,204,201,323,202,203,205,206,206,207,206,212,207,208,207,329,208,209,208,211,209,210,212,213,212,219,212,1110,213,214,213,331,213,1129,213,1130,214,215,216,217,216,220,216,225,217,218,217,1132,218,219,218,221,218,339,219,220,222,223,223,224,223,349,223,1131,224,225,224,227,225,226,228,229,228,345,228,1111,229,230,229,235,229,1133,229,1134,230,231,232,233,232,358,233,234,233,357,234,235,235,236,235,238,236,237,237,240,239,240,239,1136,240,241,240,1135,241,242,241,243,242,246,244,245,244,248,244,1138,245,246,245,1137,246,247,246,249,247,248,247,1112,248,250,250,1113,250,1139,250,1140,250,1143,251,252,252,253,252,256,252,1141,252,1144,253,254,255,256,255,259,255,369,256,257,257,258,257,260,258,259,258,1114,259,262,261,262,261,376,262,263,263,264,263,266,264,265,265,1145,267,268,267,271,268,269,269,270,269,272,270,271,271,1146,271,1148,273,274,274,275,274,1060,274,1115,274,1147,275,276,277,278,277,281,277,1116,278,279,278,391,278,1060,279,280,281,282,281,284,281,395,282,283,282,1117,283,284,283,285,284,399,286,287,287,288,287,1118,288,289,288,291,289,290,290,1149,292,293,292,1119,293,294,293,410,293,1061,293,1150,294,295,296,416,296,1061,296,1062,296,1120,296,1121,296,1151,297,298,297,301,297,422,297,427,298,299,298,1062,298,1122,299,300,301,302,301,304,301,1123,302,303,302,306,303,304,303,305,303,433,304,428,306,307,307,308,307,310,307,1124,307,1152,307,1154,308,309,310,311,310,1125,311,312,311,317,311,1153,312,313,314,315,314,1126,315,316,316,317,316,318,316,442,316,1155,319,320,320,321,320,1063,320,1156,321,322,323,1063,323,1064,323,1127,323,1157,323,1158,324,328,324,1064,324,1128,324,1159,324,1160,324,1161,325,326,325,329,325,1129,326,327,326,331,327,328,327,330,327,462,328,329,331,332,331,338,332,333,332,1162,333,334,335,336,336,337,336,472,337,338,337,340,337,465,338,339,338,1130,341,342,341,1131,341,1164,342,343,342,1132,342,1163,343,344,345,346,345,350,346,347,346,1166,347,348,347,1165,348,349,348,351,349,350,352,353,352,355,353,354,353,488,354,355,354,356,354,479,355,1133,357,358,357,1134,357,1167,357,1168,357,1171,358,359,358,1135,358,1169,359,360,359,1065,359,1170,359,1173,360,361,362,363,362,1066,362,1136,362,1137,363,364,363,1065,363,1172,363,1175,364,365,366,1066,366,1067,366,1138,366,1139,366,1174,366,1176,367,1067,367,1068,367,1140,367,1177,368,369,368,1068,368,1141,368,1142,368,1178,368,1179,369,370,369,1144,370,371,370,1180,371,372,373,374,373,378,373,1181,374,375,375,376,376,377,376,379,377,378,380,532,380,536,380,1069,380,1145,381,537,381,1069,381,1146,381,1182,382,383,382,387,383,384,384,385,384,1147,384,1148,385,386,385,388,386,387,387,541,389,390,389,392,390,391,391,392,391,393,392,544,394,395,394,550,395,396,395,398,396,397,398,399,399,400,400,401,401,402,401,404,401,405,402,403,402,1183,403,557,405,406,405,563,406,407,406,1070,406,1149,406,1184,407,408,409,410,409,413,409,1070,410,411,411,412,411,414,412,413,412,573,415,416,415,419,415,1150,416,417,417,418,417,420,418,419,418,1185,421,422,421,1151,422,423,423,424,423,426,423,427,424,425,424,583,425,1186,427,428,427,431,428,429,429,430,429,432,429,433,430,431,430,587,430,1187,433,434,434,435,434,437,434,591,434,1188,435,436,437,438,437,1189,438,439,438,1152,438,1190,439,440,441,447,441,1153,441,1154,441,1191,441,1192,442,443,443,444,444,445,444,449,445,446,445,448,445,609,446,447,449,1155,449,1193,449,1194,449,1196,450,451,450,1156,450,1157,451,452,451,1195,452,453,454,455,454,617,454,1198,455,456,455,1158,455,1159,456,457,458,1160,458,1197,458,1199,459,460,459,462,460,461,460,1200,461,462,461,463,462,1161,464,468,464,1162,464,1201,464,1202,465,466,465,469,465,472,466,467,466,1203,467,468,467,470,467,640,468,469,471,472,471,646,471,1204,472,473,472,1163,473,474,475,476,475,651,476,477,476,1071,476,1164,476,1165,476,1205,477,478,479,480,479,486,480,481,480,658,480,1071,480,1166,481,482,483,484,483,486,483,488,484,485,484,1206,485,486,485,487,485,653,488,489,488,1207,489,490,489,1072,489,1167,489,1208,490,491,492,493,492,497,493,494,493,669,494,495,495,496,495,498,495,1072,496,497,496,1168,497,1169,499,500,499,504,500,501,500,1170,500,1171,500,1209,501,502,503,504,503,509,503,1210,503,1211,504,505,504,1172,504,1173,505,506,507,508,507,689,508,509,508,686,509,510,509,512,510,511,510,1174,510,1175,513,514,513,519,513,1176,513,1177,514,515,514,1212,515,516,517,518,517,699,518,519,519,520,520,521,520,523,521,522,521,1178,522,524,524,706,524,1073,524,1179,524,1215,525,526,525,1073,525,1180,525,1213,525,1214,525,1216,526,527,526,714,527,528,527,1181,527,1218,528,529,530,531,530,1217,531,532,532,533,532,534,533,536,533,719,535,536,536,537,537,538,537,539,538,1220,540,1074,540,1182,540,1219,540,1221,541,1074,541,1222,542,543,542,1223,543,544,544,545,544,547,545,546,545,548,546,737,548,549,549,550,550,551,551,552,551,554,552,553,553,743,555,556,556,557,557,558,558,559,558,561,558,562,559,560,559,1224,560,749,562,563,563,564,563,1183,564,565,564,566,565,756,567,568,567,570,568,569,568,1184,569,570,569,571,569,572,570,756,570,1225,572,573,572,576,573,574,574,575,574,577,575,576,575,762,578,579,579,580,579,1185,579,1186,580,581,580,582,580,1075,580,1228,581,768,581,1226,583,584,584,585,584,1075,584,1076,584,1227,585,586,587,588,588,589,588,1076,588,1229,589,590,591,592,591,599,592,593,592,1187,592,1230,592,1232,593,594,595,596,595,599,595,1188,596,597,596,1189,597,598,597,600,597,602,598,599,598,1231,601,602,601,794,601,1233,602,603,602,1077,602,1190,602,1191,603,604,605,606,605,609,606,607,606,795,606,1077,606,1192,606,1234,607,608,609,800,609,1193,610,611,610,614,610,1194,611,612,611,616,612,613,612,615,612,807,612,1236,613,614,616,1195,616,1196,616,1235,617,618,617,622,618,619,618,624,619,620,619,817,620,621,620,623,620,816,621,622,624,625,624,817,624,826,625,626,625,1078,625,1197,625,1198,626,627,628,629,628,1078,628,1199,629,630,629,632,629,821,629,833,630,631,632,633,632,1237,633,634,633,1079,633,1200,633,1238,634,635,636,637,636,836,636,1080,636,1240,637,638,637,1079,637,1201,638,639,640,644,640,1080,640,1202,640,1239,640,1242,641,642,642,643,643,644,643,1241,644,645,644,647,645,646,645,1203,648,649,648,656,649,650,649,851,649,1244,650,651,650,652,651,1204,653,654,654,655,654,858,655,656,655,1243,656,657,656,659,657,658,657,1205,660,661,660,664,660,1207,661,662,661,863,661,1091,661,1206,662,663,664,866,664,869,664,1208,665,666,665,670,666,667,666,872,667,668,668,669,668,671,669,670,670,674,672,673,672,677,673,674,673,1245,674,675,675,676,675,678,676,677,676,1209,679,680,679,878,679,1246,680,681,680,1210,681,682,683,684,683,686,683,884,684,685,684,1247,685,686,685,687,685,1211,686,1081,688,689,688,692,688,889,688,1248,689,690,689,1081,690,691,692,693,692,893,693,694,693,698,693,1212,693,1249,694,695,696,697,697,698,697,900,698,699,699,700,699,702,700,701,701,705,703,704,703,708,703,905,703,1250,704,705,705,706,706,707,706,709,707,708,707,1213,708,1082,710,711,710,714,710,1252,711,712,711,1082,711,1214,711,1215,711,1251,712,713,714,919,714,1083,714,1216,714,1253,715,716,715,719,715,1254,716,717,716,1083,716,1217,716,1218,717,718,719,720,720,721,720,926,720,1084,720,1255,721,722,723,724,723,928,723,1085,724,725,724,1084,724,1219,724,1220,725,726,727,728,727,731,727,1256,728,729,728,1085,728,1221,729,730,731,732,731,939,732,733,732,1086,732,1222,732,1223,733,734,735,736,735,739,735,942,736,737,736,1086,737,738,737,740,738,739,738,741,739,945,741,742,741,746,742,743,743,744,744,745,744,747,744,748,745,746,746,948,748,749,748,1257,749,750,750,751,752,753,752,757,752,1259,753,754,753,955,753,1224,754,755,756,757,757,758,757,1258,758,759,760,761,760,959,760,1225,761,762,761,766,762,763,763,764,763,1226,764,765,764,767,765,766,765,963,766,960,768,769,769,770,770,771,772,773,772,966,772,1228,773,774,773,968,773,1087,773,1227,774,775,776,777,776,1087,777,778,777,1229,778,779,778,781,779,780,779,976,780,969,782,783,783,784,783,1230,783,1260,784,785,786,787,786,1231,786,1232,787,788,787,980,787,1088,787,1261,788,789,790,791,790,1088,790,1262,791,792,791,1089,791,1233,791,1263,792,793,794,983,794,1089,794,1234,795,796,796,797,796,805,797,798,797,799,797,990,800,801,800,805,801,802,802,803,802,810,803,804,803,806,804,805,804,998,807,808,808,809,809,810,809,811,809,1001,809,1264,812,813,812,1235,812,1236,813,814,813,1008,813,1265,814,815,816,1090,816,1266,817,818,818,819,818,1016,818,1090,819,820,821,822,821,826,822,823,822,832,823,824,824,825,824,827,824,1017,825,826,828,829,828,833,828,1237,829,830,830,831,831,832,831,834,831,1025,832,833,835,1238,835,1267,836,837,837,838,837,1035,837,1268,838,839,840,841,840,843,841,842,841,1036,842,843,842,844,843,1239,843,1240,845,849,845,1241,845,1242,845,1269,846,847,846,851,846,853,847,848,848,849,848,1047,849,850,849,852,850,851,853,1050,853,1243,853,1244,854,855,854,1091,855,856,856,857,856,1270,857,858,857,860,858,859,861,862,862,863,864,865,865,866,867,868,868,869,870,871,871,872,873,1245,873,1246,874,875,875,876,876,877,877,878,877,880,878,879,878,1247,881,882,881,885,882,883,883,884,883,886,884,885,887,888,888,889,890,891,890,894,891,892,892,893,892,895,892,1248,893,894,896,897,896,901,897,898,898,899,899,900,899,902,899,1249,900,901,903,904,904,905,906,907,906,911,906,1251,907,908,907,1250,908,909,910,911,911,912,912,913,913,914,913,916,913,1252,913,1253,914,915,917,918,918,919,920,921,921,922,921,1254,921,1255,922,923,924,925,925,926,927,928,927,932,928,929,929,930,931,932,931,935,932,933,933,934,933,936,933,1256,934,935,937,938,938,939,940,941,941,942,943,944,944,945,946,947,947,948,949,950,950,951,950,1257,951,952,953,954,954,955,956,1258,956,1259,957,958,958,959,961,962,962,963,964,965,965,966,967,968,968,969,969,970,970,971,970,973,971,972,974,975,975,976,977,1260,977,1261,978,979,979,980,981,1262,982,983,982,987,982,1263,983,984,984,985,984,994,985,986,985,988,986,987,989,990,989,994,990,991,991,992,992,993,992,995,993,994,996,997,997,998,999,1000,1000,1001,1002,1003,1002,1265,1003,1004,1003,1264,1004,1005,1006,1007,1007,1008,1009,1010,1009,1266,1010,1011,1011,1012,1011,1013,1014,1015,1015,1016,1017,1018,1017,1021,1018,1019,1019,1020,1019,1022,1020,1021,1023,1024,1024,1025,1026,1027,1027,1028,1028,1267,1029,1030,1030,1031,1030,1268,1031,1032,1033,1034,1034,1035,1036,1037,1036,1042,1037,1038,1038,1039,1040,1041,1040,1043,1041,1042,1042,1043,1042,1044,1043,1269,1045,1046,1046,1047,1048,1049,1049,1050,1051,1052,1052,1053,1052,1270,1053,1054,1101,1102,1142,1143}
P.start = {[1]=1,[6]=6,[2]=2,[5]=5,[8]=8,[9]=9,[11]=11,[7]=7,[3]=3,[4]=4}
P.ksicon = {[861]="Interface\\Icons\\Spell_Shadow_BloodBoil",[864]="Interface\\Icons\\Ability_Warrior_ShieldWall",[867]="Interface\\Icons\\Spell_Shadow_LifeDrain",[870]="Interface\\Icons\\Ability_Druid_Berserk",[887]="Interface\\Icons\\Spell_Frost_FrostShock",[903]="Interface\\Icons\\INV_Shield_06",[917]="Interface\\Icons\\Spell_Holy_HolyNova",[924]="Interface\\Icons\\INV_Misc_Book_11",[937]="Interface\\Icons\\Spell_Arcane_ArcaneResilience",[940]="Interface\\Icons\\Spell_Magic_LesserInvisibilty",[943]="Interface\\Icons\\Spell_Shadow_AntiMagicShell",[946]="Interface\\Icons\\Spell_Fire_SelfDestruct",[953]="Interface\\Icons\\Spell_Fire_Fire",[957]="Interface\\Icons\\Spell_Shadow_SoulLeech_3",[961]="Interface\\Icons\\Spell_Shadow_ShadowBolt",[964]="Interface\\Icons\\Spell_Shadow_DeathPact",[974]="Interface\\Icons\\Spell_Shadow_SummonFelHunter",[978]="Interface\\Icons\\Spell_Nature_Cyclone",[996]="Interface\\Icons\\Spell_Nature_Lightning",[999]="Interface\\Icons\\Spell_Nature_StoneSkinTotem",[1006]="Interface\\Icons\\Ability_Hunter_Pet_Wolf",[1014]="Interface\\Icons\\Ability_Hunter_Quickshot",[1023]="Interface\\Icons\\Ability_Hunter_BeastCall",[1026]="Interface\\Icons\\Ability_Rogue_Sprint",[1033]="Interface\\Icons\\Ability_Rogue_DualWeild",[1045]="Interface\\Icons\\Ability_Warrior_DefensiveStance",[1048]="Interface\\Icons\\INV_Axe_17"}
end

-- ---------------------------------------------------------------------------
-- The passive tree (0.46): one great tree, ten class starts (passivedata.lua).
-- Drag to move, the wheel to zoom; click a node next to your path to take it,
-- shift-click to take the whole way there, right-click to give one back.
-- The server decides everything: V (send the tree), VA:id, VR:id, VX.
-- ---------------------------------------------------------------------------

do
    local P = WT.PT
    local SIZE = P.size
    local CLASS_TOKEN = { [1] = "WARRIOR", [2] = "PALADIN", [3] = "HUNTER", [4] = "ROGUE", [5] = "PRIEST", [6] = "DEATHKNIGHT",
                          [7] = "SHAMAN", [8] = "MAGE", [9] = "WARLOCK", [11] = "DRUID" }
    local NODE_SIZE = { [0] = 16, [1] = 30, [2] = 46, [3] = 50, [4] = 11, [5] = 30 }
    local st = { points = 0, spent = 0, class = 0, level = 0, regret = 0, reset = 0, freeBelow = 20 }
    local taken, pending = {}, nil
    local jewels, pendingJewels = {}, nil   -- socket node -> { entry, lines }
    local adj = {}
    for i = 1, #P.edges, 2 do
        local a, b = P.edges[i], P.edges[i + 1]
        adj[a] = adj[a] or {}
        adj[b] = adj[b] or {}
        table.insert(adj[a], b)
        table.insert(adj[b], a)
    end
    local zoom = 0.45
    local search = ""

    -- ---- the window ----
    local win = CreateFrame("Frame", "WorldTiersPassiveFrame", UIParent)
    Size(win, 1000, 700)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetToplevel(true)
    win:SetMovable(true)
    win:EnableMouse(true)
    win:SetClampedToScreen(true)
    win:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark", edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
                      tile = true, tileSize = 32, edgeSize = 24, insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    win:Hide()
    tinsert(UISpecialFrames, "WorldTiersPassiveFrame")
    local titleBar = CreateFrame("Frame", nil, win)
    titleBar:SetPoint("TOPLEFT", 8, -8)
    titleBar:SetPoint("TOPRIGHT", -8, -8)
    titleBar:SetHeight(28)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() win:StartMoving() end)
    titleBar:SetScript("OnDragStop", function() win:StopMovingOrSizing() end)
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 18, -14)
    title:SetText("Passive Tree")
    local info = win:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    info:SetPoint("LEFT", title, "RIGHT", 18, 0)
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    local resetB = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    Size(resetB, 110, 22)
    resetB:SetPoint("TOPRIGHT", -40, -12)
    resetB:SetText("Start over")
    local homeB = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
    Size(homeB, 90, 22)
    homeB:SetPoint("RIGHT", resetB, "LEFT", -6, 0)
    homeB:SetText("My start")
    local box = CreateFrame("EditBox", "WorldTiersPassiveSearch", win, "InputBoxTemplate")
    Size(box, 150, 20)
    box:SetPoint("RIGHT", homeB, "LEFT", -12, 0)
    box:SetAutoFocus(false)
    local boxLabel = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    boxLabel:SetPoint("RIGHT", box, "LEFT", -8, 0)
    boxLabel:SetText("Search")
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 12)
    hint:SetText("Click: take a node next to your path.  Shift-click: take the whole way there.  Right-click: give one back.  Drag: move.  Wheel: zoom.")

    local view = CreateFrame("ScrollFrame", nil, win)
    view:SetPoint("TOPLEFT", 12, -42)
    view:SetPoint("BOTTOMRIGHT", -12, 30)
    local canvas = CreateFrame("Frame", nil, view)
    view:SetScrollChild(canvas)
    local bg = view:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(0.02, 0.02, 0.04, 0.95)

    local function CW() return 2 * SIZE * zoom end
    local function Px(id) return (P.x[id] + SIZE) * zoom end
    local function Py(id) return (SIZE - P.y[id]) * zoom end

    local Draw   -- forward

    local function Clamp(h, v)
        view:SetHorizontalScroll(math.max(0, math.min(h, CW() - view:GetWidth())))
        view:SetVerticalScroll(math.max(0, math.min(v, CW() - view:GetHeight())))
        Draw()
    end
    local function CentreOn(id)
        if not P.x[id] then return end
        Clamp(Px(id) - view:GetWidth() / 2, Py(id) - view:GetHeight() / 2)
    end
    local function SetZoom(z, fx, fy)
        fx, fy = fx or view:GetWidth() / 2, fy or view:GetHeight() / 2
        local tx = (view:GetHorizontalScroll() + fx) / zoom
        local ty = (view:GetVerticalScroll() + fy) / zoom
        zoom = math.max(0.15, math.min(1.3, z))
        Size(canvas, CW(), CW())
        Clamp(tx * zoom - fx, ty * zoom - fy)
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
    view:SetScript("OnUpdate", function(self)
        if not drag then return end
        if not IsMouseButtonDown("LeftButton") then drag = nil return end
        local x, y = GetCursorPosition()
        local s = self:GetEffectiveScale()
        local h, v = drag.h - (x / s - drag.x), drag.v + (y / s - drag.y)
        if h ~= drag.lh or v ~= drag.lv then
            drag.lh, drag.lv = h, v
            Clamp(h, v)
        end
    end)
    view:EnableMouseWheel(true)
    view:SetScript("OnMouseWheel", function(self, delta)
        local x, y = GetCursorPosition()
        local s = self:GetEffectiveScale()
        local fx = x / s - self:GetLeft()
        local fy = self:GetTop() - y / s
        SetZoom(zoom * (delta > 0 and 1.2 or 1 / 1.2), fx, fy)
    end)

    -- ---- which nodes can be taken ----
    local function Have(id) return taken[id] or id == st.class end
    local function Open(id)
        if Have(id) then return false end
        for _, n in ipairs(adj[id] or {}) do
            if Have(n) then return true end
        end
        return false
    end
    -- the shortest way from your path to a node, nearest first
    local function PathTo(goal)
        local prev, queue, head = { [goal] = goal }, { goal }, 1
        while queue[head] do
            local n = queue[head]
            head = head + 1
            if Have(n) then
                local out, at = {}, prev[n]
                while at ~= goal do
                    table.insert(out, at)
                    at = prev[at]
                end
                table.insert(out, goal)
                return out
            end
            for _, m in ipairs(adj[n] or {}) do
                if not prev[m] then
                    prev[m] = n
                    table.insert(queue, m)
                end
            end
        end
        return nil
    end

    -- ---- nodes and lines, only those in sight ----
    local buttons, lines = {}, {}
    local function Matches(id)
        if search == "" then return false end
        local n, t = (P.name[id] or ""):lower(), (P.text[id] or ""):lower()
        return n:find(search, 1, true) or t:find(search, 1, true)
    end
    local function Tip(self)
        local id = self.id
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local kind = P.t[id]
        local head = P.name[id] ~= "" and P.name[id] or (kind == 4 and "Travel" or "Passive")
        local c = kind == 2 and { 1, 0.5, 1 } or kind == 1 and { 1, 0.82, 0 } or { 1, 1, 1 }
        GameTooltip:AddLine(head, c[1], c[2], c[3])
        if kind == 2 then GameTooltip:AddLine("Keystone", 0.8, 0.5, 1) elseif kind == 1 then GameTooltip:AddLine("Notable", 0.9, 0.75, 0.3) end
        local j = jewels[id]
        if kind == 5 and j then
            local name, _, quality = GetItemInfo(j.entry)
            local c2 = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
            GameTooltip:AddLine(name or "Jewel", c2 and c2.r or 0.5, c2 and c2.g or 0.6, c2 and c2.b or 1)
            for _, line in ipairs(j.lines) do GameTooltip:AddLine(line, 0.53, 0.6, 1, true) end
            GameTooltip:AddLine("Click: swap it for another.  Shift-right-click: take it out.", 0.6, 0.6, 0.6)
            GameTooltip:Show()
            return
        end
        for line in string.gmatch(P.text[id] .. "\n", "(.-)\n") do
            if line ~= "" then GameTooltip:AddLine(line, 0.53, 0.6, 1, true) end
        end
        if kind == 5 and taken[id] then
            GameTooltip:AddLine("Click: put a jewel from your bags in it.", 0.3, 1, 0.3)
        end
        if kind ~= 3 then
            if taken[id] then
                GameTooltip:AddLine(st.level < st.freeBelow and "Right-click: give it back (free below level " .. st.freeBelow .. ")"
                    or "Right-click: give it back (an Orb of Regret)", 0.6, 0.6, 0.6)
            elseif Open(id) then
                GameTooltip:AddLine("Click: take it", 0.3, 1, 0.3)
            else
                local path = PathTo(id)
                if path then GameTooltip:AddLine(string.format("Shift-click: take the %d nodes there", #path), 0.6, 0.6, 0.6) end
            end
        end
        GameTooltip:Show()
    end
    local menu = CreateFrame("Frame", "WorldTiersPassiveMenu", UIParent, "UIDropDownMenuTemplate")
    -- the jewels in your bags, to put in a socket
    local function PickJewel(node)
        local list = { { text = "Put a jewel in the socket", isTitle = true, notCheckable = true } }
        for bag = 0, 4 do
            for slot = 1, (GetContainerNumSlots and GetContainerNumSlots(bag) or 0) do
                local link = GetContainerItemLink(bag, slot)
                local id = link and tonumber(link:match("item:(%d+)"))
                if id and id >= 996000 and id < 996100 then
                    local b, sl = bag, slot - 1
                    table.insert(list, { text = link, notCheckable = true, func = function() Send(string.format("VJ:%d:%d:%d", node, b, sl)) end })
                end
            end
        end
        if #list == 1 then
            UIErrorsFrame:AddMessage("You have no jewels in your bags.", 1, 0.2, 0.2)
            return
        end
        table.insert(list, { text = CANCEL, notCheckable = true, func = function() end })
        EasyMenu(list, menu, "cursor", 0, 0, "MENU")
    end
    local function OnClick(self, button)
        local id = self.id
        if P.t[id] == 3 then return end
        if button == "RightButton" then
            if P.t[id] == 5 and jewels[id] and IsShiftKeyDown() then Send("VU:" .. id) return end
            if taken[id] then Send("VR:" .. id) end
            return
        end
        if P.t[id] == 5 and taken[id] then PickJewel(id) return end
        if taken[id] then return end
        if IsShiftKeyDown() then
            local path = PathTo(id)
            if not path then return end
            if #path > st.points - st.spent then
                UIErrorsFrame:AddMessage(string.format("That takes %d points; you have %d free.", #path, st.points - st.spent), 1, 0.2, 0.2)
                return
            end
            for _, n in ipairs(path) do Send("VA:" .. n) end
        else
            Send("VA:" .. id)
        end
    end
    local function Button(i)
        local b = buttons[i]
        if b then return b end
        b = CreateFrame("Button", nil, canvas)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        b.ring = b:CreateTexture(nil, "OVERLAY")
        b.ring:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        b.ring:SetBlendMode("ADD")
        b.ring:SetPoint("CENTER")
        b.glow = b:CreateTexture(nil, "BACKGROUND")
        b.glow:SetTexture("Interface\\Buttons\\UI-Quickslot2")
        b.glow:SetPoint("CENTER")
        b:SetScript("OnEnter", Tip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", OnClick)
        buttons[i] = b
        return b
    end
    local function Line(i)
        local t = lines[i]
        if t then return t end
        t = canvas:CreateTexture(nil, "BORDER")
        lines[i] = t
        return t
    end
    local ROUND = { taken = "Interface\\COMMON\\Indicator-Yellow", open = "Interface\\COMMON\\Indicator-Green", locked = "Interface\\COMMON\\Indicator-Gray" }

    Draw = function()
        if not win:IsShown() then return end
        local x0, y0 = view:GetHorizontalScroll(), view:GetVerticalScroll()
        local x1, y1 = x0 + view:GetWidth(), y0 + view:GetHeight()
        local pad = 60
        local nb = 0
        local shown = {}
        for id in pairs(P.t) do
            local px, py = Px(id), Py(id)
            if px > x0 - pad and px < x1 + pad and py > y0 - pad and py < y1 + pad then
                nb = nb + 1
                shown[id] = true
                local b = Button(nb)
                local kind = P.t[id]
                local sz = math.max(6, NODE_SIZE[kind] * math.max(0.55, zoom * 1.6))
                b.id = id
                Size(b, sz, sz)
                b:ClearAllPoints()
                b:SetPoint("CENTER", canvas, "TOPLEFT", px, -py)
                local have, open = Have(id), Open(id)
                if kind == 5 then
                    local j = jewels[id]
                    b.icon:SetTexture(j and GetItemIcon and GetItemIcon(j.entry) or "Interface\\PaperDoll\\UI-Backpack-EmptySlot")
                    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    b.icon:SetDesaturated(not have)
                    b.icon:SetAlpha(have and 1 or open and 0.95 or 0.6)
                    Size(b.ring, sz * 1.8, sz * 1.8)
                    b.ring:SetVertexColor(0.3, 0.9, 1)
                    b.ring:SetAlpha(have and 1 or open and 0.7 or 0.35)
                    b.ring:Show()
                elseif kind == 0 or kind == 4 then
                    b.icon:SetTexture(have and ROUND.taken or open and ROUND.open or ROUND.locked)
                    b.icon:SetTexCoord(0, 1, 0, 1)
                    b.icon:SetDesaturated(false)
                    b.icon:SetAlpha(have and 1 or open and 0.9 or 0.55)
                    b.ring:Hide()
                elseif kind == 3 then
                    b.icon:SetTexture("Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes")
                    local c = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[CLASS_TOKEN[id] or ""]
                    if c then b.icon:SetTexCoord(c[1], c[2], c[3], c[4]) end
                    b.icon:SetDesaturated(id ~= st.class)
                    b.icon:SetAlpha(id == st.class and 1 or 0.6)
                    b.ring:Hide()
                else
                    b.icon:SetTexture(kind == 2 and (P.ksicon[id] or "Interface\\Icons\\INV_Misc_QuestionMark") or "Interface\\Icons\\INV_Misc_Gem_Variety_02")
                    b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                    b.icon:SetDesaturated(not have)
                    b.icon:SetAlpha(have and 1 or open and 0.95 or 0.6)
                    Size(b.ring, sz * 1.8, sz * 1.8)
                    if kind == 2 then b.ring:SetVertexColor(0.8, 0.4, 1) else b.ring:SetVertexColor(1, 0.8, 0.2) end
                    b.ring:SetAlpha(have and 1 or open and 0.7 or 0.35)
                    b.ring:Show()
                end
                if Matches(id) then
                    Size(b.glow, sz * 2.4, sz * 2.4)
                    b.glow:SetVertexColor(0.2, 1, 1)
                    b.glow:Show()
                else
                    b.glow:Hide()
                end
                b:Show()
            end
        end
        for i = nb + 1, #buttons do buttons[i]:Hide() end
        local nl = 0
        local H = CW()
        for i = 1, #P.edges, 2 do
            local a, b = P.edges[i], P.edges[i + 1]
            if shown[a] or shown[b] then
                nl = nl + 1
                local t = Line(nl)
                local both, one = Have(a) and Have(b), Have(a) or Have(b)
                DrawLine(t, canvas, Px(a), H - Py(a), Px(b), H - Py(b), math.max(6, 18 * zoom))
                if both then t:SetVertexColor(1, 0.8, 0.25, 1) elseif one then t:SetVertexColor(0.45, 0.9, 0.45, 0.8) else t:SetVertexColor(0.5, 0.5, 0.55, 0.45) end
                t:Show()
            end
        end
        for i = nl + 1, #lines do lines[i]:Hide() end
    end

    local function Refresh()
        local free = st.points - st.spent
        info:SetText(string.format("%s%d|r of %d points free     Orbs of Regret: %d", free > 0 and "|cff66ff66" or "|cffffffff", free, st.points, st.regret))
        resetB:SetText(st.reset > 0 and string.format("Start over (%dg)", st.reset) or "Start over")
        Draw()
    end

    StaticPopupDialogs["WORLDTIERS_PASSIVE_RESET"] = {
        text = "Give back every passive node?%s", button1 = YES, button2 = NO,
        OnAccept = function() Send("VX") end, timeout = 0, whileDead = 1, hideOnEscape = 1,
    }
    resetB:SetScript("OnClick", function()
        StaticPopup_Show("WORLDTIERS_PASSIVE_RESET", st.reset > 0 and string.format(" It costs %d gold.", st.reset) or "")
    end)
    homeB:SetScript("OnClick", function() CentreOn(st.class) end)
    box:SetScript("OnTextChanged", function(self) search = (self:GetText() or ""):lower() Draw() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local centred = false
    win:SetScript("OnShow", function()
        PlaySound("igCharacterInfoOpen")
        Size(canvas, CW(), CW())
        Send("V")
    end)
    win:SetScript("OnHide", function() PlaySound("igCharacterInfoClose") end)

    -- VS|points|spent|class|level|regret|resetGold|freeBelow  VN|id,id,...  VE|
    function WT.OnPassiveMessage(msg)
        local cmd = msg:sub(1, 3)
        if cmd == "VS|" then
            local f = Split(msg:sub(4), "|")
            st.points, st.spent, st.class, st.level = tonumber(f[1]) or 0, tonumber(f[2]) or 0, tonumber(f[3]) or 0, tonumber(f[4]) or 0
            st.regret, st.reset, st.freeBelow = tonumber(f[5]) or 0, tonumber(f[6]) or 0, tonumber(f[7]) or 20
            pending = {}
            pendingJewels = {}
            return true
        elseif cmd == "VN|" then
            pending = pending or {}
            for id in string.gmatch(msg:sub(4), "(%d+)") do pending[tonumber(id)] = true end
            return true
        elseif cmd == "VJ|" then
            local f = Split(msg:sub(4), "|")
            local node, entry = tonumber(f[1]), tonumber(f[2])
            if node and entry then
                local lines = {}
                for line in string.gmatch(f[3] or "", "([^~]+)") do lines[#lines + 1] = line end
                pendingJewels = pendingJewels or {}
                pendingJewels[node] = { entry = entry, lines = lines }
            end
            return true
        elseif cmd == "VE|" then
            taken = pending or {}
            pending = nil
            jewels = pendingJewels or {}
            pendingJewels = nil
            if win:IsShown() then
                if not centred then centred = true CentreOn(st.class) end
                Refresh()
            end
            return true
        end
        return false
    end
    function WT.OpenPassive()
        if win:IsShown() then win:Hide() else win:Show() end
    end
    function WT.PassiveSummary()
        local free = st.points - st.spent
        if st.points == 0 then return "Your passive tree" end
        return free > 0 and ("|cff66ff66" .. free .. " point" .. (free == 1 and "" or "s") .. " free|r") or "No points free"
    end
    SLASH_WORLDTIERSPASSIVE1 = "/passive"
    SLASH_WORLDTIERSPASSIVE2 = "/tree"
    SlashCmdList["WORLDTIERSPASSIVE"] = function() WT.OpenPassive() end
    -- 0.48.2: the Talents key (N) and the Talents button open the passive tree instead
    local talentHook = CreateFrame("Frame")
    talentHook:RegisterEvent("PLAYER_LOGIN")
    talentHook:RegisterEvent("ADDON_LOADED")
    talentHook:SetScript("OnEvent", function()
        ToggleTalentFrame = function() WT.OpenPassive() end
        if PlayerTalentFrame and PlayerTalentFrame:IsShown() then HideUIPanel(PlayerTalentFrame) end
        if TalentMicroButton then
            TalentMicroButton:SetScript("OnClick", function() WT.OpenPassive() end)
            TalentMicroButton.tooltipText = "Passive Tree"
        end
    end)
end

-- level 100 (0.46): the game hides the experience bar at its own cap (80); ours is 100
do
    if MAX_PLAYER_LEVEL_TABLE then
        for k in pairs(MAX_PLAYER_LEVEL_TABLE) do MAX_PLAYER_LEVEL_TABLE[k] = 100 end
    end
    MAX_PLAYER_LEVEL = 100
end

-- ---------------------------------------------------------------------------
-- Are this player's client files the ones the server expects? (CV|version|spell)
-- The IsDead Launcher keeps them current; this catches anyone who started
-- Wow.exe straight away after an update.
-- ---------------------------------------------------------------------------

do
    WT.CLIENT_VERSION = "0.37"
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
            if not WT.OnComboMessage(msg) and not WT.OnShieldMessage(msg) and not WT.OnPassiveMessage(msg) and not WT.OnSkillGemMessage(msg) and not WT.OnItemMessage(msg) and not WT.OnBarMessage(msg) and not WT.OnForgeMessage(msg)
                and not WT.OnChampionMessage(msg) and not WT.OnKeyMessage(msg) and not WT.OnLoadoutMessage(msg)
                and not WT.OnPouchMessage(msg) and not WT.OnSellMessage(msg) and not WT.OnGlyphMessage(msg) and not WT.OnVersionMessage(msg) and not WT.OnTreasureMessage(msg) and not WT.OnAscMessage(msg) and not WT.OnTransmogMessage(msg) and not WT.OnHubMessage(msg) and not WT.OnSpecialMessage(msg) and not WT.OnSplashMessage(msg) and not WT.OnLootPreviewMessage(msg) and not WT.OnSkillMessage(msg) then OnMessage(msg) end
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
    if WT.OpenPassive then WT.OpenPassive() return end   -- 0.48.2: the Paragon Board is gone
    if frame:IsShown() then frame:Hide() else frame:Show() end
end

WT.OnMessage, WT.Draw, WT.Reveal, WT.Blocker, WT.RefundBlocker = OnMessage, Draw, Reveal, Blocker, RefundBlocker
