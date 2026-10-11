local ADDON_NAME = ...

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

-- Slider limits. The top of each slider means "no upper limit"
-- and the bottom means "no lower limit".
local SCORE_MIN, SCORE_MAX, SCORE_STEP = 0, 4000, 50
local KEY_MIN, KEY_MAX, KEY_STEP = 2, 25, 1
-- raid sliders: number of tanks / healers / dps in the group (top = "or more")
local RAID_TANK_MAX, RAID_HEALER_MAX, RAID_DPS_MAX = 4, 10, 25

local defaults = {
    enabled    = true,
    -- three-state: 0 = don't care, 1 = group must have one, 2 = group must not
    hasTank    = 0,
    hasHealer  = 0,
    bloodlust  = 0,
    scoreMin   = SCORE_MIN,     -- leader M+ score range
    scoreMax   = SCORE_MAX,
    searchKeyMin = KEY_MIN,     -- key level range sent to Blizzard's search box
    searchKeyMax = KEY_MAX,
    playstyles = {},            -- [generalPlaystyle value] = 1 (include) or 2 (exclude)
    -- raid panel
    raidPlaystyles = {},        -- same as playstyles, but for raids
    raidBosses = {},            -- ["raid:boss"] = 1 (must be killed) or 2 (must be alive)
    raidDifficulty = {},        -- ["normal"|"heroic"|"mythic"] = 1 (include) or 2 (exclude)
    -- raidFilter = normalized name of the raid being filtered on (nil = all raids)
    raidTankMin = 0,   raidTankMax = RAID_TANK_MAX,
    raidHealerMin = 0, raidHealerMax = RAID_HEALER_MAX,
    raidDpsMin = 0,    raidDpsMax = RAID_DPS_MAX,
    partyFit   = false,         -- only show groups with room for my party's roles
    instantSignUp = true,       -- clicking a listing signs up straight away
    dungeons   = {},            -- [challengeMapID] = 1 (include) or 2 (exclude)
    notes      = {},            -- [leader name] = { color = "green"|"red", text = "..." }
    noteAlerts = true,          -- chat alert when a player with a note is in your group
}

local db
local panel                    -- our UI panel (created once the LFG UI exists)
local initialized = false

-- The panel and the filters only work on the Dungeons category of Premade Groups
local DUNGEON_CATEGORY_ID = _G.GROUP_FINDER_CATEGORY_ID_DUNGEONS or 2
local RAID_CATEGORY_ID = _G.GROUP_FINDER_CATEGORY_ID_RAIDS or 3

local dungeonButtons = {}      -- the icon buttons
local dungeonNorm = {}         -- [mapID] = normalized dungeon name
local dungeonGridTop = -344    -- set while building the panel
local dungeonGridLeft = 14
local DUNGEON_GAP = 12         -- gap between dungeon icons (horizontal and vertical)

-- Classes that can provide Bloodlust / Heroism / Time Warp / Primal Rage /
-- Fury of the Aspects. (Hunters need the right pet; we can't see that.)
local BLOODLUST_CLASSES = {
    SHAMAN = true,
    MAGE   = true,
    HUNTER = true,
    EVOKER = true,
}

-- Short names for the dungeon buttons, keyed by normalized English name.
-- Anything not listed here falls back to the initials of the name.
local ABBREVIATIONS = {
    windrunnerspire      = "WS",
    maisaracaverns       = "MC",
    magistersterrace     = "MT",
    nexuspointxenas      = "NPX",
    algetharacademy      = "AA",
    seatofthetriumvirate = "SEAT",
    skyreach             = "SR",
    pitofsaron           = "PoS",
    voidscararena        = "VSA",
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- Midnight can hand addons "secret" values that error if you compare them or
-- do string work on them. This returns false for nil or secret values.
local function usable(v)
    if v == nil then return false end
    if issecretvalue and issecretvalue(v) then return false end
    return true
end

-- lowercase, strip apostrophes, punctuation and spaces:
-- "Magisters' Terrace" -> "magistersterrace"
local function Normalize(s)
    s = s:lower()
    s = s:gsub("\226\128\153", "")   -- right single quote
    s = s:gsub("\226\128\152", "")   -- left single quote
    s = s:gsub("[%p%s]", "")
    return s
end

local function FirstChar(w)
    return w:match("[%z\1-\127\194-\244][\128-\191]*") or ""
end

-- Short name for a dungeon button. The ABBREVIATIONS table wins; otherwise it is
-- the first letter of every word, "of" and "the" included ("Den of Nalorak" ->
-- "DON"), except that a leading "The" is dropped ("The Blinding Vale" -> "BV").
-- One-word names use their first three letters.
local function Abbreviate(name)
    local known = ABBREVIATIONS[Normalize(name)]
    if known then return known end

    local words = {}
    for word in name:gmatch("[^%s%-:]+") do
        words[#words + 1] = word
    end
    if #words > 1 and words[1]:lower() == "the" then
        table.remove(words, 1)
    end

    if #words == 1 then
        local out, count = "", 0
        for ch in words[1]:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
            out = out .. ch
            count = count + 1
            if count == 3 then break end
        end
        return out:upper()
    end

    local out = ""
    for i = 1, math.min(#words, 4) do
        out = out .. FirstChar(words[i]):upper()
    end
    return out
end

-- The list of playstyles comes from the game's own enum, so the checklist
-- matches whatever values the client really uses.
-- What the game's enum names are called on the listings
local PLAYSTYLE_LABELS = {
    Learning   = "Learning",
    FunRelaxed = "Relaxed",
    FunSerious = "Competitive",
    Expert     = "Carry Offered",
}

local function GetPlaystyleEntries()
    local entries = {}
    local enum = Enum and Enum.LFGEntryGeneralPlaystyle
    if type(enum) == "table" then
        for key, value in pairs(enum) do
            if type(value) == "number" and value > 0 then
                -- unknown names fall back to a spaced-out version of the key
                local label = PLAYSTYLE_LABELS[key]
                    or (tostring(key):gsub("(%l)(%u)", "%1 %2"))
                entries[#entries + 1] = { value = value, label = label }
            end
        end
        table.sort(entries, function(a, b) return a.value < b.value end)
    end
    if #entries == 0 then
        -- fallback if the enum isn't available
        entries = {
            { value = 1, label = "Learning" },
            { value = 2, label = "Relaxed" },
            { value = 3, label = "Competitive" },
            { value = 4, label = "Carry Offered" },
        }
    end
    return entries
end

---------------------------------------------------------------------------
-- Filtering
---------------------------------------------------------------------------

local activityNormCache = {}

local function ActivityNorm(activityID)
    local cached = activityNormCache[activityID]
    if cached == nil then
        local info = C_LFGList.GetActivityInfoTable(activityID)
        cached = (info and info.fullName and Normalize(info.fullName)) or false
        activityNormCache[activityID] = cached
    end
    return cached
end

local function MatchesPlaystyle(info, store)
    store = store or db.playstyles
    if next(store) == nil then return true end  -- nothing set = off
    local p = info.generalPlaystyle
    if not usable(p) then return true end

    if store[p] == 2 then return false end      -- excluded

    -- if any playstyle is included, the group must be one of them
    for _, state in pairs(store) do
        if state == 1 then
            return store[p] == 1
        end
    end
    return true   -- only exclusions are set, and this one isn't excluded
end

local function MatchesScore(info)
    local limitLo = db.scoreMin > SCORE_MIN
    local limitHi = db.scoreMax < SCORE_MAX
    if not (limitLo or limitHi) then return true end

    local score = info.leaderOverallDungeonScore
    if score ~= nil and not usable(score) then return true end
    score = score or 0   -- groups with no score count as 0

    if limitLo and score < db.scoreMin then return false end
    if limitHi and score > db.scoreMax then return false end
    return true
end

local function MatchesRoles(resultID)
    if db.hasTank == 0 and db.hasHealer == 0 then return true end
    local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
    if not counts then return true end

    if db.hasTank ~= 0 and usable(counts.TANK) then
        local has = counts.TANK >= 1
        if db.hasTank == 1 and not has then return false end
        if db.hasTank == 2 and has then return false end
    end
    if db.hasHealer ~= 0 and usable(counts.HEALER) then
        local has = counts.HEALER >= 1
        if db.hasHealer == 1 and not has then return false end
        if db.hasHealer == 2 and has then return false end
    end
    return true
end

local function MatchesBloodlust(resultID, info)
    if db.bloodlust == 0 then return true end
    local n = info.numMembers
    if not usable(n) then return true end

    local sawAnyClass, has = false, false
    for i = 1, n do
        local _, classFile = C_LFGList.GetSearchResultMemberInfo(resultID, i)
        if usable(classFile) then
            sawAnyClass = true
            if BLOODLUST_CLASSES[classFile] then
                has = true
                break
            end
        end
    end
    -- If the game gave us no class data at all, don't hide the group.
    if not sawAnyClass then return true end

    if db.bloodlust == 1 then return has end
    return not has
end

-- included / excluded are lists of normalized dungeon names.
-- A group must be in one of the included dungeons (if any are included)
-- and must not be in any excluded dungeon.
local function MatchesDungeon(info, included, excluded)
    if #included == 0 and #excluded == 0 then return true end

    local ids = info.activityIDs or { info.activityID }
    local sawName, inIncluded, inExcluded = false, false, false
    for _, activityID in ipairs(ids) do
        if usable(activityID) then
            local norm = ActivityNorm(activityID)
            if norm then
                sawName = true
                for _, wanted in ipairs(included) do
                    if norm:find(wanted, 1, true) then inIncluded = true end
                end
                for _, unwanted in ipairs(excluded) do
                    if norm:find(unwanted, 1, true) then inExcluded = true end
                end
            end
        end
    end

    if not sawName then return true end   -- unknown activity: don't hide
    if inExcluded then return false end
    if #included > 0 then return inIncluded end
    return true
end

-- How many tanks / healers / dps are in my current group (or just me).
local function GetPartyRoles()
    local roles = { TANK = 0, HEALER = 0, DAMAGER = 0 }

    local function Add(unit)
        local role = UnitGroupRolesAssigned(unit)
        if (role == nil or role == "NONE") and UnitIsUnit(unit, "player") then
            -- no role picked: use the role of my current spec
            local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization)
                or GetSpecialization
            local getRole = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationRole)
                or GetSpecializationRole
            if getSpec and getRole then
                local spec = getSpec()
                role = spec and getRole(spec) or nil
            end
        end
        if roles[role] then
            roles[role] = roles[role] + 1
        else
            roles.DAMAGER = roles.DAMAGER + 1   -- unknown role: count as dps
        end
    end

    if IsInGroup() then
        if IsInRaid() then
            for i = 1, GetNumGroupMembers() do Add("raid" .. i) end
        else
            Add("player")
            for i = 1, GetNumGroupMembers() - 1 do Add("party" .. i) end
        end
    else
        Add("player")
    end
    return roles
end

-- Does my party fit into the open slots of this group?
local function MatchesParty(resultID, party)
    if not db.partyFit then return true end
    local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
    if not counts then return true end

    local function Fits(role, cap)
        local need = party[role]
        if need == 0 then return true end

        -- preferred: the game's own "open slots for this role" number
        local remaining = counts[role .. "_REMAINING"]
        if usable(remaining) and type(remaining) == "number" then
            return remaining >= need
        end
        -- fallback: normal 5-man limits (1 tank, 1 healer, 3 dps)
        local have = counts[role]
        if usable(have) and type(have) == "number" then
            return have + need <= cap
        end
        return true
    end

    return Fits("TANK", 1) and Fits("HEALER", 1) and Fits("DAMAGER", 3)
end

-- Raids -----------------------------------------------------------------------
-- raidData = { { name, norm, bosses = { { name, norm }, ... } }, ... }
-- Built from the Encounter Journal (current expansion) and kept only for raids
-- that the Group Finder lists.
local raidData = {}

local function BuildRaidData()
    local raids = {}
    if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex
            and EJ_SelectInstance and EJ_GetEncounterInfoByIndex) then
        return raids
    end

    -- names of the raids the Group Finder lists
    local listed = {}
    if C_LFGList.GetAvailableActivities then
        for _, activityID in ipairs(C_LFGList.GetAvailableActivities(RAID_CATEGORY_ID) or {}) do
            local norm = ActivityNorm(activityID)
            if norm then listed[#listed + 1] = norm end
        end
    end

    local oldTier = EJ_GetCurrentTier and EJ_GetCurrentTier()
    EJ_SelectTier(EJ_GetNumTiers())

    for index = 1, 20 do
        local instanceID, name, _, bgImage, buttonImage = EJ_GetInstanceByIndex(index, true)
        if not instanceID then break end

        local norm = Normalize(name)
        local isListed = false
        for _, activityNorm in ipairs(listed) do
            if activityNorm:sub(1, #norm) == norm then
                isListed = true
                break
            end
        end

        if isListed then
            EJ_SelectInstance(instanceID)
            local bosses = {}
            for b = 1, 30 do
                local bossName = EJ_GetEncounterInfoByIndex(b)
                if not bossName then break end
                bosses[#bosses + 1] = { name = bossName, norm = Normalize(bossName) }
            end
            raids[#raids + 1] = { name = name, norm = norm, bosses = bosses, image = buttonImage or bgImage }
        end
    end

    if oldTier then EJ_SelectTier(oldTier) end
    return raids
end

-- number of tanks / healers / dps in the group, against the three sliders
local function MatchesRaidRoles(resultID)
    local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
    if not counts then return true end

    local function InRange(n, lo, hi, minValue, maxValue)
        if not usable(n) or type(n) ~= "number" then return true end
        if lo > minValue and n < lo then return false end
        if hi < maxValue and n > hi then return false end
        return true
    end

    return InRange(counts.TANK, db.raidTankMin, db.raidTankMax, 0, RAID_TANK_MAX)
        and InRange(counts.HEALER, db.raidHealerMin, db.raidHealerMax, 0, RAID_HEALER_MAX)
        and InRange(counts.DAMAGER, db.raidDpsMin, db.raidDpsMax, 0, RAID_DPS_MAX)
end

-- The normalized activity name of a listing, e.g. "venomousabyssheroic"
local function ListingActivityNorm(info)
    for _, activityID in ipairs(info.activityIDs or { info.activityID }) do
        if usable(activityID) then
            local norm = ActivityNorm(activityID)
            if norm then return norm end
        end
    end
    return nil
end

-- Which of the current raids a listing is for (nil if none of them)
local function RaidOfListing(info)
    local norm = ListingActivityNorm(info)
    if not norm then return nil end
    for _, r in ipairs(raidData) do
        if norm:sub(1, #r.norm) == r.norm then return r end
    end
    return nil
end

-- Difficulty buttons. The names come from the game so they match your language.
local RAID_DIFFICULTIES = {
    { key = "normal", id = 14, label = "Normal" },
    { key = "heroic", id = 15, label = "Heroic" },
    { key = "mythic", id = 16, label = "Mythic" },
}
local difficultiesReady = false

local function GetRaidDifficulties()
    if not difficultiesReady then
        difficultiesReady = true
        for _, d in ipairs(RAID_DIFFICULTIES) do
            local name = GetDifficultyInfo and GetDifficultyInfo(d.id)
            if usable(name) and type(name) == "string" and name ~= "" then
                d.label = name
            end
            d.norm = Normalize(d.label)
        end
    end
    return RAID_DIFFICULTIES
end

-- "Venomous Abyss (Heroic)": the difficulty is the end of the activity name
local function ListingDifficulty(info)
    local norm = ListingActivityNorm(info)
    if not norm then return nil end
    for _, d in ipairs(GetRaidDifficulties()) do
        if #d.norm > 0 and norm:sub(-#d.norm) == d.norm then return d.key end
    end
    return nil
end

local function MatchesRaidDifficulty(info)
    local store = db.raidDifficulty
    if next(store) == nil then return true end
    local key = ListingDifficulty(info)
    if not key then return true end   -- unknown: don't hide

    if store[key] == 2 then return false end
    for _, state in pairs(store) do
        if state == 1 then return store[key] == 1 end
    end
    return true
end

-- the raid tabs: choosing a raid shows only that raid's listings
local function MatchesRaidChoice(info)
    if not db.raidFilter or #raidData == 0 then return true end
    if not ListingActivityNorm(info) then return true end
    local raid = RaidOfListing(info)
    if not raid then return false end   -- a different raid
    return raid.norm == db.raidFilter
end

-- boss buttons: green = the boss is still alive, red = the group has killed it.
-- Only the buttons of the listing's own raid count.
local function MatchesRaidBosses(resultID, info)
    if next(db.raidBosses) == nil or #raidData == 0 then return true end

    local raid = RaidOfListing(info)
    if not raid then return true end

    local constrained = false
    for _, boss in ipairs(raid.bosses) do
        if db.raidBosses[raid.norm .. ":" .. boss.norm] then
            constrained = true
            break
        end
    end
    if not constrained then return true end

    -- names of the bosses this group has already killed
    local ok, killedList = pcall(C_LFGList.GetSearchResultEncounterInfo, resultID)
    if not ok then return true end
    if killedList ~= nil and (not usable(killedList) or type(killedList) ~= "table") then
        return true
    end
    local killed = {}
    for _, name in ipairs(killedList or {}) do
        if usable(name) and type(name) == "string" then
            killed[#killed + 1] = Normalize(name)
        end
    end

    local function IsKilled(bossNorm)
        for _, k in ipairs(killed) do
            if k == bossNorm then return true end
            -- tolerate small naming differences ("The Lich King" / "Lich King")
            if #k >= 5 and #bossNorm >= 5
                and (k:find(bossNorm, 1, true) or bossNorm:find(k, 1, true)) then
                return true
            end
        end
        return false
    end

    for _, boss in ipairs(raid.bosses) do
        local state = db.raidBosses[raid.norm .. ":" .. boss.norm]
        if state then
            local dead = IsKilled(boss.norm)
            if state == 1 and not dead then return false end
            if state == 2 and dead then return false end
        end
    end
    return true
end

local function PassesRaidFilter(resultID, info)
    return MatchesPlaystyle(info, db.raidPlaystyles)
        and MatchesRaidChoice(info)
        and MatchesRaidDifficulty(info)
        and MatchesRaidRoles(resultID)
        and MatchesRaidBosses(resultID, info)
end

local function PassesFilter(resultID, info, ctx)
    return MatchesPlaystyle(info)
        and MatchesScore(info)
        and MatchesDungeon(info, ctx.included, ctx.excluded)
        and MatchesParty(resultID, ctx.party)
        and MatchesRoles(resultID)
        and MatchesBloodlust(resultID, info)
end

local function FilterResults(searchPanel)
    if not db or not db.enabled then return end
    if not searchPanel.results then return end

    local category = searchPanel.categoryID
    local passes

    if category == DUNGEON_CATEGORY_ID then
        -- Dungeons marked include (1) / exclude (2), as normalized names
        local ctx = { included = {}, excluded = {}, party = nil }
        for mapID, norm in pairs(dungeonNorm) do
            local state = db.dungeons[mapID]
            if state == 1 then
                ctx.included[#ctx.included + 1] = norm
            elseif state == 2 then
                ctx.excluded[#ctx.excluded + 1] = norm
            end
        end
        if db.partyFit then
            ctx.party = GetPartyRoles()
        end
        passes = function(resultID, info) return PassesFilter(resultID, info, ctx) end
    elseif category == RAID_CATEGORY_ID then
        passes = PassesRaidFilter
    else
        return   -- other categories: leave the list alone
    end

    local filtered = {}
    for _, resultID in ipairs(searchPanel.results) do
        local info = C_LFGList.GetSearchResultInfo(resultID)
        if info then
            -- pcall: if a filter errors on some unexpected data,
            -- show the group instead of breaking the whole list.
            local ok, pass = pcall(passes, resultID, info)
            if not ok or pass then
                filtered[#filtered + 1] = resultID
            end
        end
    end

    searchPanel.results = filtered
    searchPanel.totalResults = #filtered
end

local function RefreshList()
    local searchPanel = LFGListFrame and LFGListFrame.SearchPanel
    if searchPanel and searchPanel:IsShown() then
        LFGListSearchPanel_UpdateResultList(searchPanel)
    end
end

local function InstallHooks()
    -- Runs AFTER Blizzard builds the result list. We trim it, then ask
    -- Blizzard to redraw. (This does not start a new server search.)
    hooksecurefunc("LFGListSearchPanel_UpdateResultList", function(searchPanel)
        FilterResults(searchPanel)
        LFGListSearchPanel_UpdateResults(searchPanel)
    end)

    -- Instant sign up -------------------------------------------------------
    -- 1) After Blizzard selects the clicked listing, press its Sign Up button
    --    for us. That opens Blizzard's application dialog...
    -- 2) ...and while we are the ones who opened it, confirm it right away.
    local autoConfirm = false

    hooksecurefunc("LFGListApplicationDialog_Show", function(dialog)
        if not autoConfirm then return end
        local button = dialog and dialog.SignUpButton
        if button and button:IsEnabled() then
            button:Click()
        end
        -- if the button isn't enabled (for example no role is available),
        -- the dialog just stays open for the user to finish.
    end)

    hooksecurefunc("LFGListSearchEntry_OnClick", function(entry, mouseButton)
        if not db or not db.instantSignUp then return end
        if mouseButton ~= "LeftButton" then return end
        -- hold Shift, Ctrl or Alt while clicking to only select the listing
        if IsModifierKeyDown() then return end

        local searchPanel = LFGListFrame and LFGListFrame.SearchPanel
        if not (searchPanel and searchPanel.SignUpButton) then return end
        if not searchPanel.SignUpButton:IsEnabled() then return end

        autoConfirm = true
        local ok, err = pcall(LFGListSearchPanel_SignUp, searchPanel)
        autoConfirm = false
        if not ok then
            print("|cff33ff99BF:|r instant sign up failed:", err)
        end
    end)
end

---------------------------------------------------------------------------
-- UI building blocks
---------------------------------------------------------------------------

-- Look and feel: flat, dark and warm, with thin 1px borders and gold accents
local THEME = {
    bg      = { 0.075, 0.065, 0.055, 0.97 },   -- panel background
    field   = { 0.040, 0.040, 0.040, 0.95 },   -- text boxes, slider tracks
    border  = { 0.210, 0.185, 0.150, 1 },      -- 1px borders and dividers
    gold    = { 1, 0.82, 0 },
}

-- Turns a text box into a flat, bordered one (removes Blizzard's art).
local function SkinEditBox(eb)
    for _, region in ipairs({ eb:GetRegions() }) do
        if region.GetObjectType and region:GetObjectType() == "Texture" then
            region:Hide()
        end
    end
    local edge = eb:CreateTexture(nil, "BACKGROUND", nil, -2)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(THEME.border))
    local bg = eb:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(THEME.field))
    eb:SetTextInsets(6, 6, 0, 0)
    eb:SetFontObject("GameFontHighlightSmall")
end

local function MakeLabel(parent, text, x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
end

-- Toggle buttons -------------------------------------------------------------
-- A flat button that changes colour with its state:
--   "off" = grey, "yes" = green, "no" = red
local TOGGLE_COLORS = {
    off = { bg = { 0.100, 0.090, 0.080, 1 }, border = { 0.240, 0.210, 0.170, 1 }, text = { 1, 0.82, 0 } },
    yes = { bg = { 0.080, 0.240, 0.100, 1 }, border = { 0.200, 0.650, 0.250, 1 }, text = { 0.85, 1, 0.85 } },
    no  = { bg = { 0.300, 0.080, 0.080, 1 }, border = { 0.750, 0.240, 0.240, 1 }, text = { 1, 0.85, 0.85 } },
    sel = { bg = { 0.200, 0.160, 0.050, 1 }, border = { 1.000, 0.820, 0.000, 1 }, text = { 1, 1, 1 } },
}

local function MakeToggleButton(parent, x, y, width)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(width, 22)
    b:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    b.border = b:CreateTexture(nil, "BACKGROUND", nil, -1)
    b.border:SetPoint("TOPLEFT", -1, 1)
    b.border:SetPoint("BOTTOMRIGHT", 1, -1)

    b.bg = b:CreateTexture(nil, "BACKGROUND", nil, 0)
    b.bg:SetAllPoints()

    b.hover = b:CreateTexture(nil, "HIGHLIGHT")
    b.hover:SetAllPoints()
    b.hover:SetColorTexture(1, 0.82, 0, 0.10)

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER")
    b.text:SetWidth(width - 8)

    function b:SetState(kind, label)
        local c = TOGGLE_COLORS[kind] or TOGGLE_COLORS.off
        self.bg:SetColorTexture(unpack(c.bg))
        self.border:SetColorTexture(unpack(c.border))
        self.text:SetTextColor(unpack(c.text))
        self.text:SetText(label)
    end

    return b
end

-- On / off toggle for db[key]
local function MakeCheck(parent, text, x, y, key, width)
    local b = MakeToggleButton(parent, x, y, width or 104)
    local function Apply()
        b:SetState(db[key] and "yes" or "off", text)
    end
    b:SetScript("OnClick", function()
        db[key] = not db[key]
        Apply()
        RefreshList()
    end)
    Apply()
    return b
end

-- Three-state button for one playstyle value, stored in db.playstyles[value]:
--   nil = grey (any), 1 = green (include), 2 = red (exclude)
local function MakePlaystyleCheck(parent, text, x, y, value, store, width)
    store = store or db.playstyles
    local b = MakeToggleButton(parent, x, y, width or 104)

    local function Apply()
        local state = store[value]
        if state == 1 then
            b:SetState("yes", text)
        elseif state == 2 then
            b:SetState("no", "No " .. text)
        else
            b:SetState("off", text)
        end
    end

    b:SetScript("OnClick", function()
        local state = ((store[value] or 0) + 1) % 3  -- grey -> green -> red -> grey
        store[value] = (state ~= 0) and state or nil
        Apply()
        RefreshList()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text)
        GameTooltip:AddLine("Click to cycle: any / include / exclude", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    Apply()
    return b
end

-- A button with three states, stored in db[key]:
--   0 = grey (don't care), 1 = green (required), 2 = red (must not have)
-- names = { off = "...", yes = "...", no = "..." } are the label texts.
local function MakeTriCheck(parent, x, y, key, names)
    local b = MakeToggleButton(parent, x, y, 212)

    local function Apply()
        local state = db[key]
        if state == 1 then
            b:SetState("yes", names.yes)
        elseif state == 2 then
            b:SetState("no", names.no)
        else
            b:SetState("off", names.off)
        end
    end

    b:SetScript("OnClick", function()
        db[key] = (db[key] + 1) % 3   -- grey -> green -> red -> grey
        Apply()
        RefreshList()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(names.off)
        GameTooltip:AddLine("Click to cycle: any / required / excluded", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    Apply()
    return b
end

-- A slider with TWO handles (a min and a max).
-- cfg = { title, minValue, maxValue, step, loKey, hiKey }
-- loKey / hiKey are the names of the saved settings it reads and writes.
local function CreateRangeSlider(parent, x, y, width, cfg)
    local THUMB_W, THUMB_H = 8, 16
    local usableWidth = width - THUMB_W
    local trackY = -32
    local span = cfg.maxValue - cfg.minValue

    local s = CreateFrame("Frame", nil, parent)
    s:SetSize(width, 46)
    s:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    s:EnableMouse(true)

    local title = s:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", s, "TOPLEFT", 0, 0)
    title:SetText(cfg.title)

    local valueText = s:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valueText:SetPoint("TOPLEFT", s, "TOPLEFT", 0, -16)

    local trackEdge = s:CreateTexture(nil, "BACKGROUND", nil, -2)
    trackEdge:SetColorTexture(unpack(THEME.border))
    trackEdge:SetHeight(6)
    trackEdge:SetPoint("LEFT", s, "TOPLEFT", THUMB_W / 2 - 1, trackY)
    trackEdge:SetPoint("RIGHT", s, "TOPLEFT", width - THUMB_W / 2 + 1, trackY)

    local track = s:CreateTexture(nil, "BACKGROUND", nil, -1)
    track:SetColorTexture(unpack(THEME.field))
    track:SetHeight(4)
    track:SetPoint("LEFT", s, "TOPLEFT", THUMB_W / 2, trackY)
    track:SetPoint("RIGHT", s, "TOPLEFT", width - THUMB_W / 2, trackY)

    local fill = s:CreateTexture(nil, "BORDER")
    fill:SetColorTexture(0.85, 0.68, 0.10, 1)
    fill:SetHeight(4)

    local function MakeThumb()
        local t = CreateFrame("Frame", nil, s)
        t:SetSize(THUMB_W, THUMB_H)
        t:SetFrameLevel(s:GetFrameLevel() + 2)
        t:EnableMouse(true)
        t.edge = t:CreateTexture(nil, "BACKGROUND")
        t.edge:SetPoint("TOPLEFT", -1, 1)
        t.edge:SetPoint("BOTTOMRIGHT", 1, -1)
        t.edge:SetColorTexture(0, 0, 0, 1)
        t.tex = t:CreateTexture(nil, "ARTWORK")
        t.tex:SetAllPoints()
        t.tex:SetColorTexture(0.92, 0.82, 0.50, 1)
        return t
    end
    local loThumb, hiThumb = MakeThumb(), MakeThumb()

    local function XFor(value)
        return THUMB_W / 2 + ((value - cfg.minValue) / span) * usableWidth
    end

    local function RangeText(lo, hi)
        if lo <= cfg.minValue and hi >= cfg.maxValue then return "Any" end
        if hi >= cfg.maxValue then return lo .. " or more" end
        if lo <= cfg.minValue then return "up to " .. hi end
        return lo .. " - " .. hi
    end

    local function Layout()
        local lo = math.max(cfg.minValue, math.min(db[cfg.loKey], cfg.maxValue))
        local hi = math.max(cfg.minValue, math.min(db[cfg.hiKey], cfg.maxValue))
        if lo > hi then lo = hi end
        db[cfg.loKey], db[cfg.hiKey] = lo, hi

        loThumb:ClearAllPoints()
        loThumb:SetPoint("CENTER", s, "TOPLEFT", XFor(lo), trackY)
        hiThumb:ClearAllPoints()
        hiThumb:SetPoint("CENTER", s, "TOPLEFT", XFor(hi), trackY)
        fill:ClearAllPoints()
        fill:SetPoint("LEFT", s, "TOPLEFT", XFor(lo), trackY)
        fill:SetPoint("RIGHT", s, "TOPLEFT", XFor(hi), trackY)

        valueText:SetText(RangeText(lo, hi))
        if cfg.onLayout then cfg.onLayout(lo, hi) end
    end

    -- Value (snapped to the step) under the mouse cursor
    local function ValueAtCursor()
        local left = s:GetLeft()
        if not left then return nil end
        local cx = GetCursorPosition() / s:GetEffectiveScale()
        local frac = (cx - left - THUMB_W / 2) / usableWidth
        frac = math.max(0, math.min(1, frac))
        local v = cfg.minValue + frac * span
        v = math.floor(v / cfg.step + 0.5) * cfg.step
        return math.max(cfg.minValue, math.min(cfg.maxValue, v))
    end

    local active          -- "lo" or "hi" while dragging
    local elapsedSince = 0
    local changed = false

    local function Changed()
        if not cfg.noRefresh then RefreshList() end
    end

    local function StopDrag()
        active = nil
        s:SetScript("OnUpdate", nil)
        if changed then
            changed = false
            Changed()
        end
    end

    local function OnDragUpdate(_, elapsed)
        if not IsMouseButtonDown("LeftButton") then
            StopDrag()
            return
        end
        local v = ValueAtCursor()
        if not v then return end

        if active == "lo" then
            v = math.min(v, db[cfg.hiKey])
            if v ~= db[cfg.loKey] then db[cfg.loKey] = v; changed = true end
        else
            v = math.max(v, db[cfg.loKey])
            if v ~= db[cfg.hiKey] then db[cfg.hiKey] = v; changed = true end
        end
        Layout()

        -- refresh the list while dragging, but not on every frame
        elapsedSince = elapsedSince + elapsed
        if changed and elapsedSince > 0.12 then
            elapsedSince = 0
            changed = false
            Changed()
        end
    end

    local function StartDrag(which)
        active = which
        elapsedSince = 0
        s:SetScript("OnUpdate", OnDragUpdate)
    end

    -- When both handles sit on the same spot, pick the one that can still move.
    local function ChooseOwn(own)
        local lo, hi = db[cfg.loKey], db[cfg.hiKey]
        if lo == hi then
            if lo >= cfg.maxValue then return "lo" end
            if hi <= cfg.minValue then return "hi" end
        end
        return own
    end

    loThumb:SetScript("OnMouseDown", function() StartDrag(ChooseOwn("lo")) end)
    hiThumb:SetScript("OnMouseDown", function() StartDrag(ChooseOwn("hi")) end)

    -- Clicking on the bar moves the nearest handle there and starts dragging it
    s:SetScript("OnMouseDown", function()
        local v = ValueAtCursor()
        if not v then return end
        local lo, hi = db[cfg.loKey], db[cfg.hiKey]
        local which
        if v >= hi then
            which = "hi"
        elseif v <= lo then
            which = "lo"
        else
            which = (v - lo <= hi - v) and "lo" or "hi"
        end
        if which == "lo" then db[cfg.loKey] = v else db[cfg.hiKey] = v end
        changed = true
        Layout()
        StartDrag(which)
    end)

    Layout()
    s.Layout = Layout
    return s
end

---------------------------------------------------------------------------
-- Spec icons: replace the class-coloured role icons on dungeon listings
---------------------------------------------------------------------------

local specIconCache         -- ["WARRIOR:fury"] = icon file id
local specSeen = {}        -- [resultID] = { leader, icons } as last seen before applying
local SPEC_SLOT, SPEC_GAP = 18, 2

-- Builds the table of spec icons once, from the game's own class/spec data.
local function BuildSpecIcons()
    specIconCache = {}
    local getNumSpecs = (C_SpecializationInfo and C_SpecializationInfo.GetNumSpecializationsForClassID)
        or GetNumSpecializationsForClassID
    local getSpecInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
        or GetSpecializationInfoForClassID
    if not (getNumSpecs and getSpecInfo and GetClassInfo) then return end

    for classID = 1, (GetNumClasses and GetNumClasses() or 13) do
        local _, classFile = GetClassInfo(classID)
        if classFile then
            for index = 1, (getNumSpecs(classID) or 0) do
                local _, name, _, icon = getSpecInfo(classID, index)
                if name and icon then
                    specIconCache[classFile .. ":" .. Normalize(name)] = icon
                end
            end
        end
    end
end

-- icon for a member, from the class file ("WARRIOR") and the localized spec name ("Fury")
local function SpecIconFor(classFile, specName)
    if not specIconCache then BuildSpecIcons() end
    return specIconCache[classFile .. ":" .. Normalize(specName)]
end

local function CreateSpecSlot(box, index)
    local slot = {}
    slot.border = box:CreateTexture(nil, "BACKGROUND")
    slot.border:SetColorTexture(0, 0, 0, 1)
    slot.tex = box:CreateTexture(nil, "ARTWORK")
    box.slots[index] = slot
    return slot
end

-- vertical offset (from the row's centre) of the playstyle line: the lowest line of text
-- on the left of a listing row
local function PlaystyleLineOffset(entry)
    local nameFS, activityFS = entry.Name, entry.ActivityName
    if not (nameFS and nameFS:GetLeft() and entry:GetCenter()) then return nil end
    local styleFS = entry.PlayStyle and entry.PlayStyle:IsShown() and entry.PlayStyle or nil
    if not styleFS then
        for _, region in ipairs({ entry:GetRegions() }) do
            if region:IsObjectType("FontString") and region:IsShown()
                and region ~= nameFS and region ~= activityFS and region ~= entry.SGFRaidComp
                and region ~= entry.ExpirationTime and region ~= entry.PendingLabel
                and region:GetLeft() and math.abs(region:GetLeft() - nameFS:GetLeft()) < 4
                and region:GetCenter() and (not styleFS or select(2, region:GetCenter()) < select(2, styleFS:GetCenter())) then
                styleFS = region
            end
        end
    end
    if not styleFS or not styleFS:GetCenter() then return nil end
    local _, styleY = styleFS:GetCenter()
    local _, entryY = entry:GetCenter()
    return styleY - entryY
end

-- Draws the group as spec icons (tanks, healers, then dps) plus a dot for each
-- open place, and hides Blizzard's own icons for that row. If anything about the
-- group can't be read, Blizzard's icons are simply left alone.
local function UpdateSpecIcons(entry)
    local box = entry.SGFSpecs
    local function Off()
        if box then box:Hide() end
    end

    local dd = entry.DataDisplay
    local searchPanel = LFGListFrame and LFGListFrame.SearchPanel
    if not db or not dd then return Off() end
    if not searchPanel or searchPanel.categoryID ~= DUNGEON_CATEGORY_ID then return Off() end

    local resultID = entry.resultID
    if not resultID or not usable(resultID) then return Off() end
    -- Blizzard hides its icons on rows you have applied to
    local applied = not dd:IsShown()

    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info or not usable(info.numMembers) then return Off() end
    local numMembers = info.numMembers
    local leader = usable(info.leaderName) and info.leaderName or nil

    local icons
    do
        local byRole = { TANK = {}, HEALER = {}, DAMAGER = {} }
        local ok = true
        for i = 1, numMembers do
            local role, classFile, _, specName = C_LFGList.GetSearchResultMemberInfo(resultID, i)
            if not (usable(role) and usable(classFile) and usable(specName))
                or type(classFile) ~= "string" or type(specName) ~= "string" or not byRole[role] then
                ok = false break
            end
            local icon = SpecIconFor(classFile, specName)
            if not icon then ok = false break end
            table.insert(byRole[role], icon)
        end
        if ok and numMembers > 0 then
            icons = {}
            for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
                for _, icon in ipairs(byRole[role]) do icons[#icons + 1] = icon end
            end
            specSeen[resultID] = { leader = leader, icons = icons }
        end
    end
    -- applied rows may no longer expose the members: use what we saw before applying
    if not icons and applied then
        local seen = specSeen[resultID]
        if seen and seen.leader == leader then icons = seen.icons end
    end
    if not icons then return Off() end

    local maxPlayers = 5
    local activityID = usable(info.activityIDs) and info.activityIDs[1] or info.activityID
    if usable(activityID) then
        local activityInfo = C_LFGList.GetActivityInfoTable(activityID)
        if activityInfo and usable(activityInfo.maxNumPlayers) and activityInfo.maxNumPlayers > 0 then
            maxPlayers = activityInfo.maxNumPlayers
        end
    end
    local total = math.max(maxPlayers, #icons)

    if not box then
        box = CreateFrame("Frame", nil, entry)
        box.slots = {}
        entry.SGFSpecs = box
    end
    box:SetSize(total * SPEC_SLOT + (total - 1) * SPEC_GAP, SPEC_SLOT)
    box:ClearAllPoints()
    if applied then
        -- plain "applied" rows: the icons replace the "Pending" word, the timer stays
        do
            local _, appStatus = C_LFGList.GetApplicationInfo(resultID)
            if usable(appStatus) and appStatus == "applied" and entry.PendingLabel then
                entry.PendingLabel:Hide()
            end
        end
        -- timer and cancel button sit a little higher
        entry.SGFOrig = entry.SGFOrig or {}
        for _, f in ipairs({ entry.PendingLabel, entry.ExpirationTime, entry.CancelButton }) do
            if f then
                if not entry.SGFOrig[f] then
                    local point, rel, relPoint, x, y = f:GetPoint(1)
                    if point then entry.SGFOrig[f] = { point, rel, relPoint, x or 0, y or 0 } end
                end
                local o = entry.SGFOrig[f]
                if o then
                    f:ClearAllPoints()
                    f:SetPoint(o[1], o[2], o[3], o[4], o[5] + 6)
                end
            end
        end

        -- the icons go on the playstyle line, ending where the cancel button ends
        box:SetScale(0.9)
        local lineY = PlaystyleLineOffset(entry)
        local cancel = entry.CancelButton
        if lineY and entry:GetLeft() and cancel and cancel:IsShown() and cancel:GetRight() then
            box:SetPoint("RIGHT", entry, "LEFT", (cancel:GetRight() - entry:GetLeft()) / 0.9, lineY / 0.9)
        else
            box:SetPoint("RIGHT", dd, "RIGHT", -12, 0)
        end
        box:Show()
        -- keep the title from running underneath the timer
        local nameLeft, edge = entry.Name and entry.Name:GetLeft(), nil
        for _, f in ipairs({ entry.PendingLabel, entry.ExpirationTime, entry.CancelButton }) do
            if f and f:IsShown() and f:GetLeft() and (not edge or f:GetLeft() < edge) then edge = f:GetLeft() end
        end
        if nameLeft and edge and edge - nameLeft > 40 and entry.Name:GetWidth() > edge - nameLeft - 4 then
            entry.Name:SetWidth(edge - nameLeft - 4)
        end
    else
        box:SetScale(1)
        box:SetPoint("RIGHT", dd, "RIGHT", -12, 0)
    end

    for i = 1, total do
        local slot = box.slots[i] or CreateSpecSlot(box, i)
        local x = (i - 1) * (SPEC_SLOT + SPEC_GAP)
        slot.border:ClearAllPoints()
        slot.tex:ClearAllPoints()
        if icons[i] then
            slot.border:SetPoint("TOPLEFT", box, "TOPLEFT", x, 0)
            slot.border:SetSize(SPEC_SLOT, SPEC_SLOT)
            slot.border:Show()
            slot.tex:SetPoint("CENTER", slot.border, "CENTER")
            slot.tex:SetSize(SPEC_SLOT - 2, SPEC_SLOT - 2)
            slot.tex:SetTexture(icons[i])
            slot.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            slot.tex:SetVertexColor(1, 1, 1)
        else
            -- an open place: a small grey dot
            slot.border:Hide()
            slot.tex:SetPoint("CENTER", box, "LEFT", x + SPEC_SLOT / 2, 0)
            slot.tex:SetSize(5, 5)
            slot.tex:SetColorTexture(0.35, 0.35, 0.35, 0.8)
        end
        slot.tex:Show()
    end
    for i = total + 1, #box.slots do
        box.slots[i].border:Hide()
        box.slots[i].tex:Hide()
    end

    dd:Hide()
    box:Show()
end

-- Raids: while you are signed up, show the group's role counts under the timer
local raidSeen = {}           -- [resultID] = { leader, t, h, d } as last seen

local function UpdateRaidComp(entry)
    local fs = entry.SGFRaidComp
    local function Off()
        if fs then fs:Hide() end
    end

    local dd = entry.DataDisplay
    local searchPanel = LFGListFrame and LFGListFrame.SearchPanel
    if not db or not dd then return Off() end
    if not searchPanel or searchPanel.categoryID ~= RAID_CATEGORY_ID then return Off() end

    local resultID = entry.resultID
    if not resultID or not usable(resultID) then return Off() end

    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info then return Off() end
    local leader = usable(info.leaderName) and info.leaderName or nil

    -- remember the comp whenever it can be read (before and while the row is shown normally)
    local counts = C_LFGList.GetSearchResultMemberCounts(resultID)
    if type(counts) == "table" and usable(counts.TANK) and usable(counts.HEALER) and usable(counts.DAMAGER)
        and type(counts.TANK) == "number" and type(counts.HEALER) == "number" and type(counts.DAMAGER) == "number"
        and (counts.TANK + counts.HEALER + counts.DAMAGER) > 0 then
        raidSeen[resultID] = { leader = leader, t = counts.TANK, h = counts.HEALER, d = counts.DAMAGER }
    end

    local applied = not dd:IsShown()
    if not applied then return Off() end
    local seen = raidSeen[resultID]
    if not seen or seen.leader ~= leader then return Off() end

    -- the "Pending" word goes, the timer and cancel button stay
    local _, appStatus = C_LFGList.GetApplicationInfo(resultID)
    if usable(appStatus) and appStatus == "applied" and entry.PendingLabel then
        entry.PendingLabel:Hide()
    end

    -- timer and cancel button sit a little higher, clear of the comp icons
    entry.SGFOrig = entry.SGFOrig or {}
    for _, f in ipairs({ entry.PendingLabel, entry.ExpirationTime, entry.CancelButton }) do
        if f then
            if not entry.SGFOrig[f] then
                local point, rel, relPoint, x, y = f:GetPoint(1)
                if point then entry.SGFOrig[f] = { point, rel, relPoint, x or 0, y or 0 } end
            end
            local o = entry.SGFOrig[f]
            if o then
                f:ClearAllPoints()
                f:SetPoint(o[1], o[2], o[3], o[4], o[5] + 6)
            end
        end
    end

    -- the counts go on the playstyle line (the lowest line of text on the left of the row),
    -- to the right of the activity name
    local nameFS = entry.Name
    local activityFS = entry.ActivityName
    if not (nameFS and activityFS and activityFS:GetLeft() and entry:GetLeft()) then return Off() end

    local styleFS = entry.PlayStyle and entry.PlayStyle:IsShown() and entry.PlayStyle or nil
    if not styleFS then
        for _, region in ipairs({ entry:GetRegions() }) do
            if region:IsObjectType("FontString") and region:IsShown() and region ~= entry.SGFRaidComp
                and region ~= nameFS and region ~= activityFS
                and region ~= entry.ExpirationTime and region ~= entry.PendingLabel
                and region:GetLeft() and nameFS:GetLeft() and math.abs(region:GetLeft() - nameFS:GetLeft()) < 4
                and region:GetCenter() and (not styleFS or select(2, region:GetCenter()) < select(2, styleFS:GetCenter())) then
                styleFS = region
            end
        end
    end
    if not styleFS or not styleFS:GetCenter() then return Off() end

    if not fs then
        fs = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        entry.SGFRaidComp = fs
    end
    fs:SetText(string.format("|A:roleicon-tiny-tank:14:14|a %d    |A:roleicon-tiny-healer:14:14|a %d    |A:roleicon-tiny-dps:14:14|a %d",
        seen.t, seen.h, seen.d))
    local _, styleY = styleFS:GetCenter()
    local _, entryY = entry:GetCenter()
    local xOff = activityFS:GetLeft() - entry:GetLeft() + (activityFS:GetStringWidth() or 0) + 14
    fs:ClearAllPoints()
    local cancel = entry.CancelButton
    if cancel and cancel:IsShown() and cancel:GetRight() then
        -- end on the same vertical line as the cancel button
        fs:SetPoint("RIGHT", entry, "LEFT", cancel:GetRight() - entry:GetLeft(), styleY - entryY)
    else
        fs:SetPoint("LEFT", entry, "LEFT", xOff, styleY - entryY)
    end
    fs:Show()
end

local function InstallSpecHooks()
    if LFGListSearchEntry_Update then
        hooksecurefunc("LFGListSearchEntry_Update", function(entry)
            pcall(UpdateSpecIcons, entry)
            pcall(UpdateRaidComp, entry)
        end)
    end
end

---------------------------------------------------------------------------
-- Notes: right-click a group -> add a good (green) or bad (red) note to its leader
---------------------------------------------------------------------------

local NOTE_COLORS = {
    green = { 0.20, 0.80, 0.25 },
    red   = { 0.90, 0.20, 0.20 },
}

local noteDialog
local notesPanel            -- the list of all notes (created on first open)
local notesButtons = {}     -- the "Notes" button of each filter panel
local RefreshNotesPanel     -- assigned further down

-- called whenever a note is added, changed or deleted
local function NotesChanged()
    if RefreshNotesPanel then RefreshNotesPanel() end
    RefreshList()
end

local lastMenuTime = 0      -- last time our entry was added to Blizzard's menu
local menuFallbackShown = false

-- Notes are stored under "Name-Realm". A name without a realm is one of ours,
-- and spaces in realm names are dropped ("Tarren Mill" -> "TarrenMill"), so the
-- same player always gets the same key wherever we meet them.
local function NormalizeName(name)
    if not usable(name) or type(name) ~= "string" or name == "" then return nil end
    local base, realm = name:match("^([^%-]+)%-(.+)$")
    if not base then
        base = name
        realm = GetNormalizedRealmName()
    end
    if realm then realm = realm:gsub("%s", "") end
    if realm and realm ~= "" then return base .. "-" .. realm end
    return base
end

-- The leader's "Name-Realm" for a search result, or nil if we can't read it.
local function LeaderNameOf(resultID)
    if not resultID or not usable(resultID) then return nil end
    local info = C_LFGList.GetSearchResultInfo(resultID)
    return info and NormalizeName(info.leaderName)
end

-- "Name-Realm" of a unit token such as "party1" or "target".
local function KeyOfUnit(unit)
    if not unit or not usable(unit) or not UnitExists(unit) or not UnitIsPlayer(unit) then
        return nil
    end
    local name, realm = UnitFullName(unit)
    if not usable(name) or not name then return nil end
    if usable(realm) and realm and realm ~= "" then
        return NormalizeName(name .. "-" .. realm)
    end
    return NormalizeName(name)
end

-- Works out which player a right-click menu belongs to.
local function PlayerKeyFromMenu(owner, contextData)
    if type(contextData) == "table" then
        if contextData.unit then
            local key = KeyOfUnit(contextData.unit)
            if key then return key end
        end
        if contextData.applicantID and contextData.memberIdx then
            local name = C_LFGList.GetApplicantMemberInfo(contextData.applicantID, contextData.memberIdx)
            local key = NormalizeName(name)
            if key then return key end
        end
        local name, server = contextData.name, contextData.server
        if usable(name) and type(name) == "string" and name ~= "" then
            if not name:find("-", 1, true) and usable(server) and type(server) == "string" and server ~= "" then
                name = name .. "-" .. server
            end
            return NormalizeName(name)
        end
    end
    if owner and owner.unit then return KeyOfUnit(owner.unit) end
    return nil
end

local function OpenNoteDialog(leaderName)
    if not leaderName then return end

    if not noteDialog then
        local d = CreateFrame("Frame", "BetterFiltersNoteDialog", UIParent)
        d:SetSize(300, 170)
        d:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
        d:SetFrameStrata("DIALOG")
        d:SetClampedToScreen(true)
        d:SetMovable(true)
        d:EnableMouse(true)
        d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving)
        d:SetScript("OnDragStop", d.StopMovingOrSizing)
        d:Hide()

        -- same flat look as the main panel
        local edge = d:CreateTexture(nil, "BACKGROUND", nil, -2)
        edge:SetPoint("TOPLEFT", -1, 1)
        edge:SetPoint("BOTTOMRIGHT", 1, -1)
        edge:SetColorTexture(unpack(THEME.border))
        local bg = d:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:SetAllPoints()
        bg:SetColorTexture(unpack(THEME.bg))

        d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        d.title:SetPoint("TOP", d, "TOP", 0, -9)

        local divider = d:CreateTexture(nil, "ARTWORK")
        divider:SetColorTexture(unpack(THEME.border))
        divider:SetHeight(1)
        divider:SetPoint("TOPLEFT", d, "TOPLEFT", 0, -32)
        divider:SetPoint("TOPRIGHT", d, "TOPRIGHT", 0, -32)

        -- colour choice
        d.green = MakeToggleButton(d, 14, -44, 134)
        d.red   = MakeToggleButton(d, 152, -44, 134)

        local function ApplyColor()
            d.green:SetState(d.color == "green" and "yes" or "off", "Good")
            d.red:SetState(d.color == "red" and "no" or "off", "Bad")
        end
        d.ApplyColor = ApplyColor
        d.green:SetScript("OnClick", function() d.color = "green"; ApplyColor() end)
        d.red:SetScript("OnClick", function() d.color = "red"; ApplyColor() end)

        -- text
        MakeLabel(d, "Note", 14, -76)
        d.edit = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
        d.edit:SetSize(272, 22)
        d.edit:SetPoint("TOPLEFT", d, "TOPLEFT", 14, -96)
        SkinEditBox(d.edit)
        d.edit:SetAutoFocus(false)
        d.edit:SetMaxLetters(120)

        -- buttons
        d.save   = MakeToggleButton(d, 14, -134, 86)
        d.delete = MakeToggleButton(d, 107, -134, 86)
        d.cancel = MakeToggleButton(d, 200, -134, 86)
        d.save:SetState("yes", "Save")
        d.delete:SetState("no", "Delete")
        d.cancel:SetState("off", "Cancel")

        local function Save()
            if not d.leader or not d.color then return end
            db.notes[d.leader] = {
                color = d.color,
                text = strtrim(d.edit:GetText() or ""),
            }
            d:Hide()
            NotesChanged()
        end
        d.save:SetScript("OnClick", Save)
        d.edit:SetScript("OnEnterPressed", Save)
        d.edit:SetScript("OnEscapePressed", function() d:Hide() end)

        d.delete:SetScript("OnClick", function()
            if d.leader then db.notes[d.leader] = nil end
            d:Hide()
            NotesChanged()
        end)
        d.cancel:SetScript("OnClick", function() d:Hide() end)

        -- Escape closes the window
        tinsert(UISpecialFrames, "BetterFiltersNoteDialog")

        noteDialog = d
    end

    local d = noteDialog
    local existing = db.notes[leaderName]
    d.leader = leaderName
    d.color = existing and existing.color or "green"
    d.title:SetText(leaderName)
    d.edit:SetText(existing and existing.text or "")
    d.edit:SetCursorPosition(0)
    d.delete:SetShown(existing ~= nil)
    d.ApplyColor()
    d:Show()
    d.edit:SetFocus()
end

-- A thin coloured bar on the left edge of rows whose leader has a note
local function UpdateNoteMarker(entry)
    local mark = entry.SGFNoteMark
    local name = db and LeaderNameOf(entry.resultID)
    local note = name and db.notes[name]
    local c = note and NOTE_COLORS[note.color]
    if not c then
        if mark then mark:Hide() end
        return
    end
    if not mark then
        mark = entry:CreateTexture(nil, "OVERLAY")
        mark:SetPoint("TOPLEFT", entry, "TOPLEFT", 0, 0)
        mark:SetPoint("BOTTOMLEFT", entry, "BOTTOMLEFT", 0, 0)
        mark:SetWidth(3)
        entry.SGFNoteMark = mark
    end
    mark:SetColorTexture(c[1], c[2], c[3], 1)
    mark:Show()
end

-- Adds the note to a tooltip as one line: "Note: good player" (coloured).
-- Long text wraps onto more lines by itself.
local function AddNoteToTooltip(tooltip, note)
    local c = NOTE_COLORS[note.color]
    if not c then return end
    local text = note.text and note.text ~= "" and ("Note: " .. note.text) or "Note"
    tooltip:AddLine(" ")
    tooltip:AddLine(text, c[1], c[2], c[3], true)
end

-- Chat alerts for players with a note who are in your group ---------------------
local seenMembers = {}      -- keys of the players who were in the group last time we looked
local wasGrouped = false

-- Name-Realm keys of everyone in my group except me
local function GroupMemberKeys()
    local keys = {}
    if not IsInGroup() then return keys end

    local prefix, count
    if IsInRaid() then
        prefix, count = "raid", GetNumGroupMembers()
    else
        prefix, count = "party", GetNumGroupMembers() - 1
    end

    local myKey = KeyOfUnit("player")
    for i = 1, count do
        local key = KeyOfUnit(prefix .. i)
        if key and key ~= myKey then keys[key] = true end
    end
    return keys
end

local function AlertNote(key, note, joined)
    local c = NOTE_COLORS[note.color]
    if not c then return end
    local hex = ("%02x%02x%02x"):format(
        math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
    local name = key:match("^([^%-]+)") or key
    local verb = joined and "joined your group" or "is in your group"
    local text = (note.text and note.text ~= "") and (" - Note: " .. note.text:gsub("|", "||")) or ""
    print(("|cff33ff99BF:|r |cff%s%s %s%s|r"):format(hex, name, verb, text))
end

-- Compares the group with last time. silent = just remember who is here.
local function CheckGroupNotes(silent)
    if not db then return end
    local current = GroupMemberKeys()
    local groupedNow = IsInGroup()

    if not silent and db.noteAlerts then
        -- if I wasn't in a group a moment ago, I just joined theirs
        local joined = wasGrouped
        for key in pairs(current) do
            if not seenMembers[key] then
                local note = db.notes[key]
                if note and NOTE_COLORS[note.color] then
                    AlertNote(key, note, joined)
                end
            end
        end
    end

    seenMembers = current
    wasGrouped = groupedNow
end

local function InstallNoteHooks()
    -- the coloured bar
    if LFGListSearchEntry_Update then
        hooksecurefunc("LFGListSearchEntry_Update", function(entry)
            pcall(UpdateNoteMarker, entry)
        end)
    end

    -- the note text in the tooltip
    if LFGListSearchEntry_OnEnter then
        hooksecurefunc("LFGListSearchEntry_OnEnter", function(entry)
            local name = LeaderNameOf(entry.resultID)
            local note = name and db.notes[name]
            if not (note and NOTE_COLORS[note.color]) then return end
            AddNoteToTooltip(GameTooltip, note)
            GameTooltip:Show()
        end)
    end

    -- the entry in Blizzard's right-click menu
    if Menu and Menu.ModifyMenu then
        Menu.ModifyMenu("MENU_LFG_FRAME_SEARCH_ENTRY", function(owner, rootDescription)
            lastMenuTime = GetTime()
            local name = owner and LeaderNameOf(owner.resultID)
            if not name then return end
            rootDescription:CreateDivider()
            rootDescription:CreateButton(
                db.notes[name] and "Edit note" or "Add note",
                function() OpenNoteDialog(name) end)
        end)
    end

    -- Fallback: if a right-click didn't bring up a menu we could add to, open
    -- the note window directly so the feature still works.
    if LFGListSearchEntry_OnClick then
        hooksecurefunc("LFGListSearchEntry_OnClick", function(entry, mouseButton)
            if mouseButton ~= "RightButton" then return end
            local clickTime = GetTime()
            local resultID = entry.resultID
            C_Timer.After(0.25, function()
                if lastMenuTime >= clickTime then return end   -- menu entry was added
                local name = LeaderNameOf(resultID)
                if not name then return end
                if not menuFallbackShown then
                    menuFallbackShown = true
                    print("|cff33ff99BF:|r couldn't add to the right-click menu, opening the note window directly.")
                end
                OpenNoteDialog(name)
            end)
        end)
    end

    -- "Add note" on right-click menus of players: party and raid frames, target,
    -- chat names, friends, guild and so on. (Tags that don't exist are harmless.)
    if Menu and Menu.ModifyMenu then
        local tags = {
            "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER", "MENU_UNIT_RAID",
            "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS", "MENU_UNIT_FRIEND", "MENU_UNIT_FRIEND_OFFLINE",
            "MENU_UNIT_GUILD", "MENU_UNIT_GUILD_OFFLINE", "MENU_UNIT_CHAT_ROSTER",
            "MENU_UNIT_ENEMY_PLAYER", "MENU_UNIT_COMMUNITIES_MEMBER",
            "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_OTHERPLAYER", "MENU_UNIT_SELF",
            "MENU_LFG_FRAME_MEMBER_APPLY",
        }
        for _, tag in ipairs(tags) do
            Menu.ModifyMenu(tag, function(owner, rootDescription, contextData)
                local ok, key = pcall(PlayerKeyFromMenu, owner, contextData)
                if not ok or not key then return end
                if key == KeyOfUnit("player") then return end   -- not for yourself
                rootDescription:CreateDivider()
                rootDescription:CreateButton(
                    db.notes[key] and "Edit note" or "Add note",
                    function() OpenNoteDialog(key) end)
            end)
        end
    end

    -- the note in the tooltip when you hover over a player (target, party, nameplates...)
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
        and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip)
            if tooltip ~= GameTooltip then return end
            pcall(function()
                local _, unit = tooltip:GetUnit()
                local key = KeyOfUnit(unit)
                local note = key and db.notes[key]
                if not (note and NOTE_COLORS[note.color]) then return end
                AddNoteToTooltip(tooltip, note)
            end)
        end)
    end
end

-- The list of all notes -----------------------------------------------------------
local NOTES_VISIBLE, NOTES_ROW_H, NOTES_ROW_GAP = 8, 36, 2

local function SortedNotes()
    local list = {}
    for name, note in pairs(db.notes) do
        list[#list + 1] = { name = name, color = note.color, text = note.text or "" }
    end
    table.sort(list, function(a, b) return a.name:lower() < b.name:lower() end)
    return list
end

local function UpdateNotesButton()
    if not db then return end
    local n = 0
    for _ in pairs(db.notes) do n = n + 1 end
    local label = n > 0 and ("Notes (" .. n .. ")") or "Notes"
    for _, button in ipairs(notesButtons) do
        -- green while the notes panel is open next to this button's panel
        local open = notesPanel and notesPanel:IsShown() and notesPanel:GetParent() == button.ownerPanel
        button:SetState(open and "yes" or "off", label)
    end
end

local function CreateNotesPanel()
    local p = CreateFrame("Frame", "BetterFiltersNotesPanel", panel)
    p:SetSize(280, 70 + NOTES_VISIBLE * (NOTES_ROW_H + NOTES_ROW_GAP) + 18)
    p:SetPoint("TOPLEFT", panel, "TOPRIGHT", 4, 0)
    p:EnableMouse(true)
    p:EnableMouseWheel(true)
    p.offset = 0
    p.rows = {}

    -- same flat look as the main panel
    local edge = p:CreateTexture(nil, "BACKGROUND", nil, -2)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(THEME.border))
    local bg = p:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(THEME.bg))

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", p, "TOP", 0, -9)
    title:SetText("Notes")

    local divider = p:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(THEME.border))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -32)
    divider:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -32)

    -- chat alert toggle, above the list
    local alertCheck = MakeCheck(p, "Chat alert for noted players", 14, -44, "noteAlerts", 252)
    alertCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Chat alert for noted players")
        GameTooltip:AddLine("Prints a coloured message in chat when a player you have a note on is in your group, with their note.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    alertCheck:SetScript("OnLeave", GameTooltip_Hide)

    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p.empty:SetPoint("TOP", p, "TOP", 0, -106)
    p.empty:SetWidth(230)
    p.empty:SetText("No notes yet.\nRight-click a group in the list to add one.")
    p.empty:SetTextColor(0.6, 0.6, 0.6)

    p.hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.hint:SetPoint("BOTTOM", p, "BOTTOM", 0, 4)
    p.hint:SetText("Scroll for more")

    for i = 1, NOTES_VISIBLE do
        local row = CreateFrame("Button", nil, p)
        row:SetSize(252, NOTES_ROW_H)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -70 - (i - 1) * (NOTES_ROW_H + NOTES_ROW_GAP))

        local rowEdge = row:CreateTexture(nil, "BACKGROUND", nil, -2)
        rowEdge:SetPoint("TOPLEFT", -1, 1)
        rowEdge:SetPoint("BOTTOMRIGHT", 1, -1)
        rowEdge:SetColorTexture(unpack(THEME.border))
        local rowBg = row:CreateTexture(nil, "BACKGROUND", nil, -1)
        rowBg:SetAllPoints()
        rowBg:SetColorTexture(0.100, 0.090, 0.080, 1)

        row.hover = row:CreateTexture(nil, "HIGHLIGHT")
        row.hover:SetAllPoints()
        row.hover:SetColorTexture(1, 0.82, 0, 0.10)

        row.bar = row:CreateTexture(nil, "ARTWORK")
        row.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
        row.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        row.bar:SetWidth(3)

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -5)
        row.name:SetWidth(200)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)

        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 5)
        row.text:SetWidth(200)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row.text:SetTextColor(0.7, 0.7, 0.7)

        row.del = MakeToggleButton(row, 0, 0, 22)
        row.del:SetHeight(22)
        row.del:ClearAllPoints()
        row.del:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.del:SetState("no", "x")
        row.del:SetScript("OnClick", function()
            if row.leader then db.notes[row.leader] = nil end
            NotesChanged()
        end)
        row.del:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Delete this note")
            GameTooltip:Show()
        end)
        row.del:SetScript("OnLeave", GameTooltip_Hide)

        row:SetScript("OnClick", function(self)
            if self.leader then OpenNoteDialog(self.leader) end
        end)
        row:SetScript("OnEnter", function(self)
            if not self.leader then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.leader)
            local c = NOTE_COLORS[self.color] or NOTE_COLORS.green
            if self.fullText and self.fullText ~= "" then
                GameTooltip:AddLine(self.fullText, c[1], c[2], c[3], true)
            end
            GameTooltip:AddLine("Click to edit", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)

        p.rows[i] = row
    end

    p:SetScript("OnMouseWheel", function(self, delta)
        local total = 0
        for _ in pairs(db.notes) do total = total + 1 end
        local maxOffset = math.max(0, total - NOTES_VISIBLE)
        self.offset = math.max(0, math.min(maxOffset, self.offset - delta))
        RefreshNotesPanel()
    end)
    p:SetScript("OnShow", function() RefreshNotesPanel() end)
    p:SetScript("OnHide", function() UpdateNotesButton() end)

    return p
end

RefreshNotesPanel = function()
    UpdateNotesButton()
    local p = notesPanel
    if not p or not p:IsShown() then return end

    local list = SortedNotes()
    p.offset = math.max(0, math.min(p.offset, math.max(0, #list - NOTES_VISIBLE)))

    for i, row in ipairs(p.rows) do
        local item = list[p.offset + i]
        if item then
            local c = NOTE_COLORS[item.color] or NOTE_COLORS.green
            row.leader, row.color, row.fullText = item.name, item.color, item.text
            row.bar:SetColorTexture(c[1], c[2], c[3], 1)
            row.name:SetTextColor(c[1], c[2], c[3])
            row.name:SetText(item.name)
            row.text:SetText(item.text ~= "" and item.text or "(no text)")
            row:Show()
        else
            row.leader = nil
            row:Hide()
        end
    end

    p.empty:SetShown(#list == 0)
    p.hint:SetShown(#list > NOTES_VISIBLE)
end

-- The notes panel opens next to whichever filter panel asked for it.
local function ToggleNotesPanel(anchor)
    anchor = anchor or panel
    if not notesPanel then notesPanel = CreateNotesPanel() end

    if notesPanel:GetParent() ~= anchor then
        -- it was next to the other panel: move it here and show it
        notesPanel:Hide()
        notesPanel:SetParent(anchor)
        notesPanel:ClearAllPoints()
        notesPanel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
        notesPanel:Show()
    else
        notesPanel:SetShown(not notesPanel:IsShown())
    end
    UpdateNotesButton()
end

-- The "Notes" button that sits in the top row of a filter panel.
local function MakeNotesButton(parentPanel, x, y)
    local button = MakeToggleButton(parentPanel, x, y, 104)
    button.ownerPanel = parentPanel
    notesButtons[#notesButtons + 1] = button
    button:SetScript("OnClick", function() ToggleNotesPanel(parentPanel) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Notes")
        GameTooltip:AddLine("Open the list of all your saved notes.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)
    UpdateNotesButton()
    return button
end

---------------------------------------------------------------------------
-- Dungeon quick-filter buttons
---------------------------------------------------------------------------

-- Dungeon button states, stored in db.dungeons[mapID]:
--   nil = neutral, 1 = included (gold border), 2 = excluded (red border + X)
local function UpdateDungeonVisuals()
    local anyIncluded = false
    for _, b in ipairs(dungeonButtons) do
        if b:IsShown() and db.dungeons[b.mapID] == 1 then anyIncluded = true end
    end
    for _, b in ipairs(dungeonButtons) do
        local state = db.dungeons[b.mapID]
        if state == 1 then
            b.border:SetColorTexture(1, 0.82, 0, 1)
            b.border:Show()
            b.cross:Hide()
            b.icon:SetAlpha(1)
        elseif state == 2 then
            b.border:SetColorTexture(0.9, 0.15, 0.15, 1)
            b.border:Show()
            b.cross:Show()
            b.icon:SetAlpha(0.35)
        else
            b.border:Hide()
            b.cross:Hide()
            -- dim neutral ones while some dungeons are included
            b.icon:SetAlpha(anyIncluded and 0.45 or 1)
        end
    end
end

local function CreateDungeonButton(index)
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(44, 44)

    local col = (index - 1) % 4
    local row = math.floor((index - 1) / 4)
    b:SetPoint("TOPLEFT", panel, "TOPLEFT",
        dungeonGridLeft + col * (44 + DUNGEON_GAP),
        dungeonGridTop - row * (44 + DUNGEON_GAP))

    b.border = b:CreateTexture(nil, "BACKGROUND")
    b.border:SetPoint("TOPLEFT", -3, 3)
    b.border:SetPoint("BOTTOMRIGHT", 3, -3)
    b.border:SetColorTexture(1, 0.82, 0, 1)
    b.border:Hide()

    -- always-on 1px dark frame around the icon (the state ring sits outside it)
    b.edge = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    b.edge:SetPoint("TOPLEFT", -1, 1)
    b.edge:SetPoint("BOTTOMRIGHT", 1, -1)
    b.edge:SetColorTexture(unpack(THEME.border))

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetAllPoints()
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    b.strip = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.strip:SetPoint("BOTTOMLEFT")
    b.strip:SetPoint("BOTTOMRIGHT")
    b.strip:SetHeight(14)
    b.strip:SetColorTexture(0, 0, 0, 0.65)

    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.text:SetPoint("CENTER", b.strip, "CENTER")

    b.cross = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.cross:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
    b.cross:SetSize(30, 30)
    b.cross:SetPoint("CENTER", b, "CENTER", 0, 4)
    b.cross:Hide()

    b:SetScript("OnClick", function(self)
        -- neutral -> included -> excluded -> neutral
        local state = ((db.dungeons[self.mapID] or 0) + 1) % 3
        db.dungeons[self.mapID] = (state ~= 0) and state or nil
        UpdateDungeonVisuals()
        RefreshList()
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.dungeonName or "")
        GameTooltip:AddLine("Click to cycle: include / exclude / reset", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", GameTooltip_Hide)

    dungeonButtons[index] = b
    return b
end

-- (Re)builds the buttons from the current Mythic+ season's dungeon list.
local function BuildDungeonButtons()
    if not panel then return end

    for _, b in ipairs(dungeonButtons) do b:Hide() end
    wipe(dungeonNorm)

    local maps = C_ChallengeMode.GetMapTable()
    if not maps then return end

    -- alphabetical order (a leading "The" doesn't count)
    local entries = {}
    for _, mapID in ipairs(maps) do
        local name, _, _, texture = C_ChallengeMode.GetMapUIInfo(mapID)
        if name then
            entries[#entries + 1] = {
                mapID = mapID, name = name, texture = texture,
                sortKey = (name:lower():gsub("^the%s+", "")),
            }
        end
    end
    table.sort(entries, function(a, b) return a.sortKey < b.sortKey end)

    for i, entry in ipairs(entries) do
        if i > 8 then break end
        local b = dungeonButtons[i] or CreateDungeonButton(i)
        b.mapID = entry.mapID
        b.dungeonName = entry.name
        b.icon:SetTexture(entry.texture)
        b.text:SetText(Abbreviate(entry.name))
        b:Show()
        dungeonNorm[entry.mapID] = Normalize(entry.name)
    end

    UpdateDungeonVisuals()
end

---------------------------------------------------------------------------
-- Key level range (done by Blizzard's server-side search box)
---------------------------------------------------------------------------

-- Key levels aren't readable by addons, but Blizzard's own search box accepts
-- a range like "8-12" and the server does the filtering. Addons are NOT
-- allowed to write into that box (the game blocks it), so the slider builds
-- the text and the user pastes it in.
local keyRangeBox   -- our small copyable text field

local function BuildKeyRangeText()
    local lo, hi = db.searchKeyMin, db.searchKeyMax
    if lo <= KEY_MIN and hi >= KEY_MAX then
        return nil  -- no restriction
    end
    local hiValue = (hi >= KEY_MAX) and 99 or hi
    return lo .. "-" .. hiValue
end

local function UpdateKeyRangeBox()
    if not keyRangeBox then return end
    keyRangeBox.shownText = BuildKeyRangeText() or ""
    keyRangeBox:SetText(keyRangeBox.shownText)
    keyRangeBox:SetCursorPosition(0)
end

---------------------------------------------------------------------------
-- The panel
---------------------------------------------------------------------------

local function BuildPanel()
    local parent = LFGListFrame
    local anchor = PVEFrame or LFGListFrame

    panel = CreateFrame("Frame", "BetterFiltersPanel", parent)
    panel:SetWidth(240)
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)

    -- flat dark background with a 1px border
    local frameEdge = panel:CreateTexture(nil, "BACKGROUND", nil, -2)
    frameEdge:SetPoint("TOPLEFT", -1, 1)
    frameEdge:SetPoint("BOTTOMRIGHT", 1, -1)
    frameEdge:SetColorTexture(unpack(THEME.border))
    local frameBg = panel:CreateTexture(nil, "BACKGROUND", nil, -1)
    frameBg:SetAllPoints()
    frameBg:SetColorTexture(unpack(THEME.bg))

    -- title with a thin divider underneath
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panel, "TOP", 0, -9)
    title:SetText("Better Filters")

    local divider = panel:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(THEME.border))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -32)
    divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -32)

    -- Layout: every section follows the same rhythm ------------------------
    --   label, then rows 26px apart (22px button + 4px gap),
    --   then a 14px gap before the next section.
    local LEFT, WIDTH = 14, 212          -- content column
    local COL2 = LEFT + 108              -- second column of two-button rows
    local ROW_H, ROW_STEP = 22, 26
    local LABEL_H = 20                   -- space taken by a section label
    local SECTION = 14                   -- gap after the last row of a section

    local y = -44   -- we build the panel top to bottom, moving y down

    -- Master switch + options (no label) -----------------------------------
    MakeCheck(panel, "Filter enabled", LEFT, y, "enabled")

    MakeNotesButton(panel, COL2, y)
    y = y - ROW_STEP

    local partyCheck = MakeCheck(panel, "Fit my party", LEFT, y, "partyFit")
    partyCheck:SetScript("OnEnter", function(self)
        local r = GetPartyRoles()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Fit my party")
        GameTooltip:AddLine("Only shows groups with room for your party's roles.", 1, 1, 1, true)
        GameTooltip:AddLine(("Your party now: %d tank, %d healer, %d dps"):format(r.TANK, r.HEALER, r.DAMAGER), 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    partyCheck:SetScript("OnLeave", GameTooltip_Hide)

    local instantCheck = MakeCheck(panel, "Instant sign up", COL2, y, "instantSignUp")
    instantCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Instant sign up")
        GameTooltip:AddLine("Clicking a listing signs you up straight away, without pressing Sign Up.", 1, 1, 1, true)
        GameTooltip:AddLine("Hold Shift, Ctrl or Alt while clicking to only select it.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    instantCheck:SetScript("OnLeave", GameTooltip_Hide)
    y = y - ROW_H - SECTION

    -- Playstyle -------------------------------------------------------------
    MakeLabel(panel, "Playstyle", LEFT, y)
    y = y - LABEL_H
    local entries = GetPlaystyleEntries()
    local rows = math.ceil(#entries / 2)
    for i, entry in ipairs(entries) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        MakePlaystyleCheck(panel, entry.label, col == 0 and LEFT or COL2, y - row * ROW_STEP, entry.value)
    end
    y = y - (rows - 1) * ROW_STEP - ROW_H - SECTION

    -- Sliders (each has its own title, 46px tall) ----------------------------
    CreateRangeSlider(panel, LEFT, y, WIDTH, {
        title = "Leader M+ score",
        minValue = SCORE_MIN, maxValue = SCORE_MAX, step = SCORE_STEP,
        loKey = "scoreMin", hiKey = "scoreMax",
    })
    y = y - 46 - 8

    CreateRangeSlider(panel, LEFT, y, WIDTH, {
        title = "Key level",
        minValue = KEY_MIN, maxValue = KEY_MAX, step = KEY_STEP,
        loKey = "searchKeyMin", hiKey = "searchKeyMax",
        noRefresh = true,        -- the game's search does this, not us
        onLayout = UpdateKeyRangeBox,
    })
    y = y - 46 - 4

    keyRangeBox = CreateFrame("EditBox", nil, panel, "InputBoxTemplate")
    keyRangeBox:SetSize(WIDTH, ROW_H)
    keyRangeBox:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, y)
    SkinEditBox(keyRangeBox)
    keyRangeBox:SetAutoFocus(false)
    -- read-only: if the user types, put the real text back
    keyRangeBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(self.shownText or "")
            self:HighlightText()
        end
    end)
    keyRangeBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    keyRangeBox:SetScript("OnEnterPressed", keyRangeBox.ClearFocus)
    keyRangeBox:SetScript("OnEscapePressed", keyRangeBox.ClearFocus)
    UpdateKeyRangeBox()
    y = y - ROW_H - SECTION

    -- Group composition -------------------------------------------------------
    MakeLabel(panel, "Group composition", LEFT, y)
    y = y - LABEL_H
    MakeTriCheck(panel, LEFT, y, "hasTank",
        { off = "Tank", yes = "Has a tank", no = "No tank" })
    y = y - ROW_STEP
    MakeTriCheck(panel, LEFT, y, "hasHealer",
        { off = "Healer", yes = "Has a healer", no = "No healer" })
    y = y - ROW_STEP
    MakeTriCheck(panel, LEFT, y, "bloodlust",
        { off = "Bloodlust class", yes = "Has a bloodlust class", no = "No bloodlust class" })
    y = y - ROW_H - SECTION

    -- Dungeons -----------------------------------------------------------------
    MakeLabel(panel, "Dungeons", LEFT, y)

    local clear = MakeToggleButton(panel, 0, 0, 54)
    clear:SetHeight(18)
    clear:ClearAllPoints()
    clear:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -LEFT, y + 3)
    clear:SetState("off", "Clear")
    clear:SetScript("OnClick", function()
        wipe(db.dungeons)
        UpdateDungeonVisuals()
        RefreshList()
    end)
    y = y - LABEL_H

    dungeonGridTop = y
    dungeonGridLeft = LEFT
    BuildDungeonButtons()
    y = y - 2 * 44 - DUNGEON_GAP    -- two rows of 44px icons with one gap between

    panel:SetHeight(-y + 14)

    -- Only show the panel while the Premade Groups search list is open AND it is
    -- searching the Dungeons category (not raids, arenas and so on) ---------
    local searchPanel = LFGListFrame.SearchPanel

    local function UpdatePanelVisibility()
        local show = searchPanel:IsShown() and searchPanel.categoryID == DUNGEON_CATEGORY_ID
        if show then
            if C_MythicPlus and C_MythicPlus.RequestMapInfo then
                C_MythicPlus.RequestMapInfo()
            end
            BuildDungeonButtons()
        end
        panel:SetShown(show)
    end

    searchPanel:HookScript("OnShow", function()
        UpdatePanelVisibility()
        -- the category may be set a moment after the list appears
        C_Timer.After(0, UpdatePanelVisibility)
    end)
    searchPanel:HookScript("OnHide", function() panel:Hide() end)
    if LFGListSearchPanel_SetCategory then
        hooksecurefunc("LFGListSearchPanel_SetCategory", function()
            UpdatePanelVisibility()
        end)
    end
    UpdatePanelVisibility()
end

---------------------------------------------------------------------------
-- The raid panel: shown while searching the Raids category
---------------------------------------------------------------------------

local raidPanel

local function BuildRaidPanel()
    local parent = LFGListFrame
    local anchor = PVEFrame or LFGListFrame

    local p = CreateFrame("Frame", "BetterFiltersRaidPanel", parent)
    raidPanel = p
    p:SetWidth(240)
    p:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    p.tabs = {}
    p.bossButtons = {}

    -- same flat look as the dungeon panel
    local edge = p:CreateTexture(nil, "BACKGROUND", nil, -2)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(THEME.border))
    local bg = p:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(THEME.bg))

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", p, "TOP", 0, -9)
    title:SetText("Better Filters")

    local divider = p:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(THEME.border))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", p, "TOPLEFT", 0, -32)
    divider:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, -32)

    -- same spacing rules as the dungeon panel
    local LEFT, WIDTH = 14, 212
    local COL2 = LEFT + 108
    local ROW_H, ROW_STEP = 22, 26
    local LABEL_H, SECTION = 20, 14

    local y = -44

    -- Filter enabled | Notes ------------------------------------------------
    MakeCheck(p, "Filter enabled", LEFT, y, "enabled")
    MakeNotesButton(p, COL2, y)
    y = y - ROW_STEP

    -- Instant sign up -------------------------------------------------------------
    local instantCheck = MakeCheck(p, "Instant sign up", LEFT, y, "instantSignUp", WIDTH)
    instantCheck:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Instant sign up")
        GameTooltip:AddLine("Clicking a listing signs you up straight away, without pressing Sign Up.", 1, 1, 1, true)
        GameTooltip:AddLine("Hold Shift, Ctrl or Alt while clicking to only select it.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    instantCheck:SetScript("OnLeave", GameTooltip_Hide)
    y = y - ROW_H - SECTION

    -- Playstyle (its own settings, separate from the dungeon panel) -------------------
    MakeLabel(p, "Playstyle", LEFT, y)
    y = y - LABEL_H
    local entries = GetPlaystyleEntries()
    local rows = math.ceil(#entries / 2)
    for i, entry in ipairs(entries) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        MakePlaystyleCheck(p, entry.label, col == 0 and LEFT or COL2, y - row * ROW_STEP,
            entry.value, db.raidPlaystyles)
    end
    y = y - (rows - 1) * ROW_STEP - ROW_H - SECTION

    -- Difficulty ---------------------------------------------------------------------
    MakeLabel(p, "Difficulty", LEFT, y)
    y = y - LABEL_H
    local diffWidth = (WIDTH - 8) / 3
    for i, d in ipairs(GetRaidDifficulties()) do
        MakePlaystyleCheck(p, d.label, LEFT + (i - 1) * (diffWidth + 4), y,
            d.key, db.raidDifficulty, diffWidth)
    end
    y = y - ROW_H - SECTION

    -- Number of tanks / healers / dps in the group ---------------------------------------
    CreateRangeSlider(p, LEFT, y, WIDTH, {
        title = "Tanks in group",
        minValue = 0, maxValue = RAID_TANK_MAX, step = 1,
        loKey = "raidTankMin", hiKey = "raidTankMax",
    })
    y = y - 46 - 8
    CreateRangeSlider(p, LEFT, y, WIDTH, {
        title = "Healers in group",
        minValue = 0, maxValue = RAID_HEALER_MAX, step = 1,
        loKey = "raidHealerMin", hiKey = "raidHealerMax",
    })
    y = y - 46 - 8
    CreateRangeSlider(p, LEFT, y, WIDTH, {
        title = "DPS in group",
        minValue = 0, maxValue = RAID_DPS_MAX, step = 1,
        loKey = "raidDpsMin", hiKey = "raidDpsMax",
    })
    y = y - 46 - SECTION

    -- Bosses ---------------------------------------------------------------------------------
    MakeLabel(p, "Bosses", LEFT, y)

    local clear = MakeToggleButton(p, 0, 0, 54)
    clear:SetHeight(18)
    clear:ClearAllPoints()
    clear:SetPoint("TOPRIGHT", p, "TOPRIGHT", -LEFT, y + 3)
    clear:SetState("off", "Clear")
    y = y - LABEL_H

    local hint = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", p, "TOPLEFT", LEFT, y)
    hint:SetWidth(WIDTH)
    hint:SetJustifyH("LEFT")
    hint:SetText("Green: still alive. Red: already killed.")
    y = y - 16

    local tabsY = y
    y = y - 38 - 8
    local bossY = y

    local noBosses = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    noBosses:SetPoint("TOPLEFT", p, "TOPLEFT", LEFT, bossY)
    noBosses:SetWidth(WIDTH)
    noBosses:SetJustifyH("LEFT")
    noBosses:SetTextColor(0.6, 0.6, 0.6)
    noBosses:SetText("No boss list available for the current raids.")
    noBosses:Hide()

    -- boss buttons ------------------------------------------------------------------------------
    local LayoutRaid   -- defined below

    local function ApplyBoss(btn)
        local state = db.raidBosses[btn.key]
        -- first click (still alive) is green, second (already killed) is red
        btn:SetState(state == 2 and "yes" or (state == 1 and "no" or "off"), btn.bossName)
    end

    local function CreateBossButton(i)
        local btn = MakeToggleButton(p, 0, 0, 104)
        btn.text:SetWordWrap(false)
        btn:SetScript("OnClick", function(self)
            -- grey -> still alive (green) -> already killed (red) -> grey
            local nextState = { [0] = 2, [2] = 1, [1] = 0 }
            local state = nextState[db.raidBosses[self.key] or 0]
            db.raidBosses[self.key] = (state ~= 0) and state or nil
            ApplyBoss(self)
            RefreshList()
        end)
        btn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.bossName or "")
            GameTooltip:AddLine("Click to cycle: any / still alive / already killed", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", GameTooltip_Hide)
        p.bossButtons[i] = btn
        return btn
    end

    local function CreateTab(i)
        local tab = MakeToggleButton(p, 0, 0, 100)
        tab:SetHeight(38)
        tab.text:SetWordWrap(false)
        -- a strip of the raid's artwork behind the abbreviation
        tab.art = tab:CreateTexture(nil, "ARTWORK")
        tab.art:SetAllPoints()
        tab.art:SetTexCoord(0, 0.667, 0.130, 0.612)
        local fontPath = GameFontNormal and GameFontNormal:GetFont()
        if fontPath then tab.text:SetFont(fontPath, 15, "OUTLINE") end
        tab:SetScript("OnClick", function(self)
            -- click a raid to show only that raid; click it again to show all raids
            if db.raidFilter == self.raid.norm then
                db.raidFilter = nil
            else
                db.raidFilter = self.raid.norm
            end
            LayoutRaid()
            RefreshList()
        end)
        tab:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self.raid and self.raid.name or "")
            GameTooltip:AddLine("Click to show only this raid. Click again to show all raids.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        tab:SetScript("OnLeave", GameTooltip_Hide)
        p.tabs[i] = tab
        return tab
    end

    -- (Re)builds the raid tabs and the boss buttons of the selected raid
    LayoutRaid = function()
        if #raidData == 0 then raidData = BuildRaidData() end

        for _, tab in ipairs(p.tabs) do tab:Hide() end
        for _, btn in ipairs(p.bossButtons) do btn:Hide() end

        -- the raid being filtered on (none = all raids, no boss buttons)
        local selected
        for _, raid in ipairs(raidData) do
            if raid.norm == db.raidFilter then selected = raid end
        end
        if not selected then db.raidFilter = nil end

        -- one tab per raid
        local n = #raidData
        local gap = 4
        local tabWidth = (WIDTH - gap * (n - 1)) / math.max(n, 1)
        for i, raid in ipairs(raidData) do
            local tab = p.tabs[i] or CreateTab(i)
            tab.raid = raid
            tab:SetWidth(tabWidth)
            tab.text:SetWidth(tabWidth - 8)
            tab:ClearAllPoints()
            tab:SetPoint("TOPLEFT", p, "TOPLEFT", LEFT + (i - 1) * (tabWidth + gap), tabsY)
            tab:SetState(raid == selected and "sel" or "off", Abbreviate(raid.name))
            if raid.image then
                tab.art:SetTexture(raid.image)
                tab.art:SetTexCoord(0, 0.667, 0.130, 0.612)
                local shade = (raid == selected) and 1 or 0.45
                tab.art:SetVertexColor(shade, shade, shade)
                tab.art:Show()
            else
                tab.art:Hide()
            end
            tab:Show()
        end

        -- two columns of bosses for the selected raid
        local bossCount = selected and #selected.bosses or 0
        for i = 1, bossCount do
            local boss = selected.bosses[i]
            local btn = p.bossButtons[i] or CreateBossButton(i)
            btn.key = selected.norm .. ":" .. boss.norm
            btn.bossName = boss.name
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", p, "TOPLEFT", col == 0 and LEFT or COL2, bossY - row * ROW_STEP)
            ApplyBoss(btn)
            btn:Show()
        end

        if #raidData == 0 then
            noBosses:SetText("No boss list available for the current raids.")
        else
            noBosses:SetText("Pick a raid above to filter by its bosses.")
        end
        noBosses:SetShown(bossCount == 0)
        local bossRows = math.max(1, math.ceil(bossCount / 2))
        p:SetHeight(-(bossY - (bossRows - 1) * ROW_STEP - ROW_H) + 14)
    end

    clear:SetScript("OnClick", function()
        wipe(db.raidBosses)
        LayoutRaid()
        RefreshList()
    end)

    -- Only show this panel while the Premade Groups list is searching Raids ------------------
    local searchPanel = LFGListFrame.SearchPanel

    local function UpdateRaidPanelVisibility()
        local show = searchPanel:IsShown() and searchPanel.categoryID == RAID_CATEGORY_ID
        if show then LayoutRaid() end
        p:SetShown(show)
    end

    searchPanel:HookScript("OnShow", function()
        UpdateRaidPanelVisibility()
        C_Timer.After(0, UpdateRaidPanelVisibility)   -- the category may be set a moment later
    end)
    searchPanel:HookScript("OnHide", function() p:Hide() end)
    if LFGListSearchPanel_SetCategory then
        hooksecurefunc("LFGListSearchPanel_SetCategory", function()
            UpdateRaidPanelVisibility()
        end)
    end
    UpdateRaidPanelVisibility()
end

---------------------------------------------------------------------------
-- Debugging: /sgf debug
---------------------------------------------------------------------------

-- Describes a value without ever concatenating it directly
local function Describe(v)
    if v == nil then return "nil" end
    if issecretvalue and issecretvalue(v) then return "SECRET" end
    local t = type(v)
    if t == "string" then
        return ("string, length %d, escaped: [%s]"):format(#v, (v:gsub("|", "||")))
    end
    return t .. ": " .. tostring(v)
end

local function DebugDump()
    local function Say(...) print("|cff33ff99BF:|r", ...) end

    Say("enabled:", db.enabled,
        "| score:", db.scoreMin, "-", db.scoreMax,
        "| key search:", db.searchKeyMin, "-", db.searchKeyMax)

    local enum = Enum and Enum.LFGEntryGeneralPlaystyle
    if type(enum) == "table" then
        for k, v in pairs(enum) do Say("playstyle enum:", k, "=", v) end
    else
        Say("Enum.LFGEntryGeneralPlaystyle is not available")
    end

    local _, all = C_LFGList.GetFilteredSearchResults()
    if not all or #all == 0 then
        Say("no search results loaded - run a search first.")
        return
    end
    Say("unfiltered results:", #all)

    for i = 1, math.min(3, #all) do
        local info = C_LFGList.GetSearchResultInfo(all[i])
        if info then
            Say("--- result", i, "(id", all[i] .. ")")
            Say("numMembers       ->", Describe(info.numMembers))
            Say("generalPlaystyle ->", Describe(info.generalPlaystyle))
            Say("leaderScore      ->", Describe(info.leaderOverallDungeonScore))
        end
    end
end

-- /sgf spec : what the game says about the members of the first listings
local function DebugSpec()
    local function Say(...) print("|cff33ff99BF:|r", ...) end

    local _, all = C_LFGList.GetFilteredSearchResults()
    if not all or #all == 0 then
        Say("no search results loaded - run a search first.")
        return
    end
    local picks = {}
    for i = 1, math.min(2, #all) do picks[#picks + 1] = i end
    for i = 1, #all do
        local st = C_LFGList.GetApplicationInfo(all[i])
        if st and #picks < 4 and not tContains(picks, i) then picks[#picks + 1] = i; Say("applied row found: result", i, "status", Describe(st)) end
    end
    for _, i in ipairs(picks) do
        local info = C_LFGList.GetSearchResultInfo(all[i])
        if info then
            Say("--- result", i, "| members:", Describe(info.numMembers))
            for m = 1, usable(info.numMembers) and info.numMembers or 0 do
                local r1, r2, r3, r4, r5, r6 = C_LFGList.GetSearchResultMemberInfo(all[i], m)
                Say("member", m, "->", Describe(r1), "|", Describe(r2), "|", Describe(r3), "|", Describe(r4), "|", Describe(r5), "|", Describe(r6))
                if usable(r2) and usable(r4) and type(r2) == "string" and type(r4) == "string" then
                    Say("   spec icon:", SpecIconFor(r2, r4) or "NOT FOUND")
                end
            end
        end
    end
end

SLASH_BETTERFILTERS1 = "/bf"
SLASH_BETTERFILTERS2 = "/sgf"
SlashCmdList["BETTERFILTERS"] = function(msg)
    if not db then return end
    if (msg or ""):lower():match("^debug") then
        local ok, err = pcall(DebugDump)
        if not ok then print("|cff33ff99BF:|r debug error:", err) end
    elseif (msg or ""):lower():match("^spec") then
        local ok, err = pcall(DebugSpec)
        if not ok then print("|cff33ff99BF:|r spec error:", err) end
    else
        print("|cff33ff99BF:|r use '/bf debug' or '/bf spec' to inspect what listing data the game exposes.")
    end
end

---------------------------------------------------------------------------
-- Startup
---------------------------------------------------------------------------

local function InitDB()
    -- settings and notes saved under the old name (Simple Group Filter) carry over once
    if not BetterFiltersDB then
        BetterFiltersDB = SimpleGroupFilterDB and CopyTable(SimpleGroupFilterDB) or {}
    end
    db = BetterFiltersDB
    for k, v in pairs(defaults) do
        if db[k] == nil then
            db[k] = (type(v) == "table") and CopyTable(v) or v
        end
    end

    -- older versions stored checked playstyles as `true`; now 1 (include) / 2 (exclude)
    for value, v in pairs(db.playstyles) do
        if v == true then
            db.playstyles[value] = 1
        elseif v ~= 1 and v ~= 2 then
            db.playstyles[value] = nil
        end
    end

    -- older versions stored selected dungeons as `true`; now 1 (include) / 2 (exclude)
    for mapID, v in pairs(db.dungeons) do
        if v == true then
            db.dungeons[mapID] = 1
        elseif v ~= 1 and v ~= 2 then
            db.dungeons[mapID] = nil
        end
    end

    -- older versions stored these as true/false; now 0 / 1 / 2
    for _, key in ipairs({ "hasTank", "hasHealer", "bloodlust" }) do
        local v = db[key]
        if v == true then
            db[key] = 1
        elseif v ~= 1 and v ~= 2 then
            db[key] = 0
        end
    end
end

-- The LFG UI might not exist yet when our addon loads, so we try on several
-- events and stop as soon as it works.
local function TryInit()
    if initialized or not db then return end
    if not (LFGListFrame and LFGListFrame.SearchPanel and LFGListSearchPanel_UpdateResultList) then
        return
    end
    initialized = true
    InstallHooks()
    InstallNoteHooks()
    InstallSpecHooks()
    BuildPanel()
    BuildRaidPanel()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then InitDB() end
        TryInit()
    elseif event == "PLAYER_LOGIN" then
        TryInit()
        if C_MythicPlus and C_MythicPlus.RequestMapInfo then
            C_MythicPlus.RequestMapInfo()
        end
    elseif event == "CHALLENGE_MODE_MAPS_UPDATE" then
        BuildDungeonButtons()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- after logging in or zooming: just remember who is already in the group
        C_Timer.After(3, function() pcall(CheckGroupNotes, true) end)
    else
        if event == "GROUP_ROSTER_UPDATE" then
            pcall(CheckGroupNotes, false)
        end
        -- party or spec changed: re-check "Fit my party"
        if db and db.partyFit then RefreshList() end
    end
end)
