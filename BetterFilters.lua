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
-- applicant item level slider (bottom = no lower limit, top = no upper limit)
local ILVL_MIN, ILVL_MAX, ILVL_STEP = 250, 350, 1
local APP_SCORE_MAX = 4200

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
    overviewMode = "ilvl",     -- Group Overview: "ilvl" | "class" | "tier" | "buff" | "prog"
    overviewLeft = false,      -- Group Overview: keep players who recently left the group
    overviewRaid = 0,          -- Group Overview, Progress view: Raider.IO id of the raid shown
    minimapAngle = 215,         -- where the minimap button sits (degrees around the minimap)
    minimapHidden = false,
    reskin = true,              -- restyle the Dungeons & Raids window and put our panels inside it
    signUpRoles = {},           -- [classFile] = "TANK"|"HEALER"|"DAMAGER": role you sign up as
    signUpNote = "",            -- text put in the note box when you sign up to a group
    dungeons   = {},            -- [challengeMapID] = 1 (include) or 2 (exclude)
    notes      = {},            -- [leader name] = { color = "green"|"red", text = "..." }
    noteAlerts = true,          -- chat alert when a player with a note is in your group
    -- applicant filters (when you list your own dungeon group)
    appEnabled = true,
    appRoles   = {},            -- ["TANK"|"HEALER"|"DAMAGER"] = 1 (include) or 2 (exclude)
    appClasses = {},            -- [classFile] = 1 (include) or 2 (exclude)
    appBloodlust = 0,           -- 0 any, 1 only bloodlust classes, 2 none
    appFit = false,             -- only show applicants for the roles my group is missing
    -- applicant filters for your own raid listing
    appRaidEnabled = true,
    raidBuffsIgnored = {},      -- [classFile] = true for raid buffs you don't care about
    appRaidRoles = {},
    appRaidClasses = {},
    appRaidBloodlust = 0,
    appRaidBadNote = false,
    appRaidGoodNote = false,
    appRaidIlvlMin = ILVL_MIN, appRaidIlvlMax = ILVL_MAX,
    appBadNote = false,         -- hide applicants you have a bad note on
    appGoodNote = false,        -- only show applicants you have a good note on
    appIlvlMin = ILVL_MIN,  appIlvlMax = ILVL_MAX,
    appScoreMin = SCORE_MIN, appScoreMax = APP_SCORE_MAX,
}

local db
local panel                    -- our UI panel (created once the LFG UI exists)
local appPanel                 -- the applicant filter panel (while you have a dungeon listing up)
local appRaidPanel             -- the applicant filter panel for a raid listing
local ApplyPreferredRole       -- sets the role boxes of the sign-up dialog (defined further down)
local InstallSkin, DumpFrames  -- the window skin and its debug dump (defined further down)
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

-- One member of a listing: role ("TANK"/"HEALER"/"DAMAGER"), class file ("WARRIOR") and
-- localized spec name. The game replaced GetSearchResultMemberInfo with
-- GetSearchResultPlayerInfo (which returns a table), so both are supported.
local function GetMember(resultID, index)
    if C_LFGList.GetSearchResultPlayerInfo then
        local t = C_LFGList.GetSearchResultPlayerInfo(resultID, index)
        if type(t) == "table" then
            return t.assignedRole, t.classFilename, t.specName, t
        end
        return nil
    end
    if C_LFGList.GetSearchResultMemberInfo then
        local role, classFile, _, specName = C_LFGList.GetSearchResultMemberInfo(resultID, index)
        return role, classFile, specName
    end
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
        local _, classFile = GetMember(resultID, i)
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

    -- on a brand-new character the Encounter Journal data may not be loaded yet:
    -- report "nothing yet" and try again the next time the raid panel is shown
    local numTiers = EJ_GetNumTiers()
    if type(numTiers) ~= "number" or numTiers < 1 then return raids end

    local oldTier = EJ_GetCurrentTier and EJ_GetCurrentTier()
    EJ_SelectTier(numTiers)

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

    if type(oldTier) == "number" and oldTier >= 1 then EJ_SelectTier(oldTier) end
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
        if ApplyPreferredRole then pcall(ApplyPreferredRole, dialog) end
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

-- Sign-up note box -----------------------------------------------------------
-- Addons are not allowed to write into Blizzard's sign-up note box, so instead of
-- filling it in we move Blizzard's own box into our panel. What you type there is
-- what gets sent when you sign up. Outside the Dungeons and Raids panels the box
-- goes back to its normal place in the sign-up dialog.
local noteSlots = {}          -- the slot in each of our panels
local noteOriginal            -- where Blizzard's box lived before we moved it
local noteHiddenRegions = {}

local function PlaceSignUpNote()
    local desc = LFGListApplicationDialog and LFGListApplicationDialog.Description
    if not desc then return end
    local edit = desc.EditBox

    local slot
    for _, candidate in ipairs(noteSlots) do
        if candidate:IsVisible() then slot = candidate break end
    end

    if slot then
        if not noteOriginal then
            noteOriginal = { parent = desc:GetParent(), points = {}, width = desc:GetWidth(), height = desc:GetHeight() }
            for i = 1, desc:GetNumPoints() do
                noteOriginal.points[i] = { desc:GetPoint(i) }
            end
            if edit then
                noteOriginal.editWidth, noteOriginal.editHeight = edit:GetSize()
                noteOriginal.maxLetters = edit:GetMaxLetters()
            end
        end
        desc:SetParent(slot)
        desc:ClearAllPoints()
        desc:SetPoint("TOPLEFT", slot, "TOPLEFT", 0, 0)
        desc:SetSize(slot:GetWidth(), slot:GetHeight())
        if edit then
            edit:SetSize(slot:GetWidth() - 8, slot:GetHeight())
            edit:SetMaxLetters(60)
        end
        -- flat look: hide Blizzard's frame art, our slot draws the border
        wipe(noteHiddenRegions)
        for _, region in ipairs({ desc:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "Texture" and region:IsShown() then
                region:Hide()
                noteHiddenRegions[#noteHiddenRegions + 1] = region
            end
        end
        if desc.CharCount then desc.CharCount:SetAlpha(0) end
        desc:Show()
    elseif noteOriginal then
        desc:SetParent(noteOriginal.parent)
        desc:ClearAllPoints()
        for _, pt in ipairs(noteOriginal.points) do
            desc:SetPoint(unpack(pt))
        end
        desc:SetSize(noteOriginal.width, noteOriginal.height)
        if edit and noteOriginal.editWidth then
            edit:SetSize(noteOriginal.editWidth, noteOriginal.editHeight)
            if noteOriginal.maxLetters then edit:SetMaxLetters(noteOriginal.maxLetters) end
        end
        for _, region in ipairs(noteHiddenRegions) do region:Show() end
        wipe(noteHiddenRegions)
        if desc.CharCount then desc.CharCount:SetAlpha(1) end
    end
end

-- Each panel registers a function that pulls everything under the note box up when the
-- box is not there (so no blank row is left behind).
local noteCollapsers = {}
local instantChecks = {}      -- the Instant sign up button of each panel (kept in step)

-- owner: the panel; slotY: the y of the note box in it; shift: how far to pull things up;
-- extra(collapsed): anything else the panel needs to do (optional)
local function BuildNoteCollapser(owner, slotY, shift, extra)
    local items = {}
    local function Collect(obj)
        local n = obj:GetNumPoints()
        if n == 0 then return end
        local pts = {}
        for i = 1, n do
            local point, rel, relPoint, x, y = obj:GetPoint(i)
            if rel ~= owner or not y or y >= slotY - 2 then return end   -- not below the box
            pts[i] = { point, rel, relPoint, x or 0, y }
        end
        items[#items + 1] = { obj = obj, pts = pts }
    end
    for _, child in ipairs({ owner:GetChildren() }) do Collect(child) end
    for _, region in ipairs({ owner:GetRegions() }) do Collect(region) end

    local function Apply(collapsed)
        for _, item in ipairs(items) do
            item.obj:ClearAllPoints()
            for _, pt in ipairs(item.pts) do
                item.obj:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5] + (collapsed and shift or 0))
            end
        end
        if extra then extra(collapsed) end
    end
    noteCollapsers[#noteCollapsers + 1] = Apply
    return Apply
end

-- the note box only lives in our panels while Instant sign up is on
local function UpdateNoteSlots()
    for _, slot in ipairs(noteSlots) do
        slot:SetShown(db and db.instantSignUp and true or false)
    end
    local collapsed = not (db and db.instantSignUp)
    for _, apply in ipairs(noteCollapsers) do pcall(apply, collapsed) end
    for _, check in ipairs(instantChecks) do
        if check.Refresh then check:Refresh() end
    end
    pcall(PlaceSignUpNote)
end

local function MakeSignUpNoteBox(parent, x, y, width)
    local slot = CreateFrame("Frame", nil, parent)
    slot:SetSize(width, 22)
    slot:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

    local edge = slot:CreateTexture(nil, "BACKGROUND", nil, -2)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(THEME.border))
    local bg = slot:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(THEME.field))

    slot:SetShown(db and db.instantSignUp and true or false)
    slot:SetScript("OnShow", function() pcall(PlaceSignUpNote) end)
    slot:SetScript("OnHide", function() C_Timer.After(0, function() pcall(PlaceSignUpNote) end) end)
    noteSlots[#noteSlots + 1] = slot
    return slot
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
local function MakeCheck(parent, text, x, y, key, width, onChange)
    local b = MakeToggleButton(parent, x, y, width or 104)
    local function Apply()
        b:SetState(db[key] and "yes" or "off", text)
    end
    b:SetScript("OnClick", function()
        db[key] = not db[key]
        Apply()
        ;(onChange or RefreshList)()
    end)
    b.Refresh = Apply
    Apply()
    return b
end

-- Three-state button for one playstyle value, stored in db.playstyles[value]:
--   nil = grey (any), 1 = green (include), 2 = red (exclude)
local function MakePlaystyleCheck(parent, text, x, y, value, store, width, onChange)
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
        ;(onChange or RefreshList)()
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
local function MakeTriCheck(parent, x, y, key, names, onChange)
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
        ;(onChange or RefreshList)()
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
        if cfg.onChange then cfg.onChange() elseif not cfg.noRefresh then RefreshList() end
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

-- (kept inside a do-block: the game allows at most 200 top-level locals per file)
local SpecIconFor, TIER_TOKEN, ROLE_ATLAS, InstallSpecHooks
do
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
function SpecIconFor(classFile, specName)
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
            local role, classFile, specName = GetMember(resultID, i)
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

-- Raids: how many players of your own class are already in each group, shown on the
-- playstyle line as "[class icon] 3", under the tank / healer / dps numbers
-- Midnight tier tokens are shared by armor type
TIER_TOKEN = {
    MAGE = "Woven", PRIEST = "Woven", WARLOCK = "Woven",
    DEMONHUNTER = "Cured", DRUID = "Cured", MONK = "Cured", ROGUE = "Cured",
    EVOKER = "Cast", HUNTER = "Cast", SHAMAN = "Cast",
    DEATHKNIGHT = "Forged", PALADIN = "Forged", WARRIOR = "Forged",
}

local function UpdateRaidClassCount(entry)
    local fs = entry.SGFClassCount
    local function Off()
        if fs then fs:Hide() end
    end

    local dd = entry.DataDisplay
    local searchPanel = LFGListFrame and LFGListFrame.SearchPanel
    local isRaid = searchPanel and searchPanel.categoryID == RAID_CATEGORY_ID

    -- Blizzard's tank / healer / dps numbers sit a little higher on raid rows, to leave
    -- room for our line under them (and go back to normal in other categories)
    if dd and dd.GetNumPoints and dd:GetNumPoints() == 1 or entry.SGFDDOrig then
        if isRaid and not entry.SGFDDOrig then
            local point, rel, relPoint, x, y = dd:GetPoint(1)
            if point then entry.SGFDDOrig = { point, rel, relPoint, x or 0, y or 0 } end
        end
        local o = entry.SGFDDOrig
        if o then
            dd:ClearAllPoints()
            dd:SetPoint(o[1], o[2], o[3], o[4], o[5] + (isRaid and 7 or 0))
        end
    end

    if not db or not dd or not isRaid then return Off() end
    local resultID = entry.resultID
    if not resultID or not usable(resultID) then return Off() end

    local info = C_LFGList.GetSearchResultInfo(resultID)
    if not info or not usable(info.numMembers) or type(info.numMembers) ~= "number" then return Off() end

    local myClass = UnitClassBase and UnitClassBase("player")
    if not myClass then return Off() end

    local myToken = TIER_TOKEN[myClass]
    local count, tokenCount = 0, 0
    for i = 1, info.numMembers do
        local _, classFile = GetMember(resultID, i)
        if not usable(classFile) or type(classFile) ~= "string" then return Off() end   -- can't read: show nothing
        if classFile == myClass then count = count + 1 end
        if myToken and TIER_TOKEN[classFile] == myToken then tokenCount = tokenCount + 1 end
    end

    local lineY = PlaystyleLineOffset(entry)
    if not (lineY and entry:GetLeft()) then return Off() end

    if not fs then
        fs = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        entry.SGFClassCount = fs
    end
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[myClass]
    local hex = (count > 0 and color and color.colorStr) and color.colorStr or "ff808080"
    local text = ("|A:classicon-%s:14:14|a |c%s%d|r"):format(myClass:lower(), hex, count)
    if myToken then
        -- players on the same tier token (your class included), then your own class
        text = ("|cffffd100Tier|r |cffffffff%d|r   "):format(tokenCount) .. text
    end
    fs:SetText(text)
    fs:ClearAllPoints()
    local comp = entry.SGFRaidComp
    if not dd:IsShown() and comp and comp:IsShown() then
        -- applied row: the role counts we draw sit on this line, so go just left of them
        fs:SetPoint("RIGHT", comp, "LEFT", -10, 0)
    else
        -- centred under Blizzard's tank / healer / dps numbers
        local centerX = dd:GetCenter()
        if not (centerX and usable(centerX)) then return Off() end
        fs:SetPoint("CENTER", entry, "LEFT", centerX - entry:GetLeft() + 14, lineY)
    end
    fs:Show()
end

-- The role you signed up as, shown to the left of the timer on rows you applied to
local appliedRole = {}           -- [resultID] = role of your application, as sent
ROLE_ATLAS = { TANK = "roleicon-tiny-tank", HEALER = "roleicon-tiny-healer", DAMAGER = "roleicon-tiny-dps" }

local function UpdateRoleIcon(entry)
    local icon = entry.BFRoleIcon
    local function Off() if icon then icon:Hide() end end

    local timer = entry.ExpirationTime
    local resultID = entry.resultID
    if not (resultID and usable(resultID) and timer and timer:IsShown()) then return Off() end

    local _, _, _, _, role = C_LFGList.GetApplicationInfo(resultID)
    if not (usable(role) and role and ROLE_ATLAS[role]) then role = appliedRole[resultID] end
    if not (role and ROLE_ATLAS[role]) then return Off() end

    if not icon then
        icon = entry:CreateTexture(nil, "OVERLAY")
        icon:SetSize(16, 16)
        entry.BFRoleIcon = icon
    end
    icon:SetAtlas(ROLE_ATLAS[role])
    -- sit just left of the timer's text, even if the text box is wider than the text
    local extra = 0
    local boxW, textW = timer:GetWidth(), timer:GetStringWidth()
    if usable(boxW) and usable(textW) and type(boxW) == "number" and type(textW) == "number"
        and boxW > textW and timer:GetJustifyH() == "RIGHT" then
        extra = boxW - textW
    end
    icon:ClearAllPoints()
    icon:SetPoint("RIGHT", timer, "LEFT", -4 + extra, 0)
    icon:Show()
end

function InstallSpecHooks()
    if LFGListSearchEntry_Update then
        hooksecurefunc("LFGListSearchEntry_Update", function(entry)
            pcall(UpdateSpecIcons, entry)
            pcall(UpdateRaidComp, entry)
            pcall(UpdateRaidClassCount, entry)
            pcall(UpdateRoleIcon, entry)
        end)
    end
    -- remember the role each application was sent with (the game may not tell us later)
    if C_LFGList and C_LFGList.ApplyToGroup then
        hooksecurefunc(C_LFGList, "ApplyToGroup", function(resultID, tank, healer, dps)
            pcall(function()
                if not usable(resultID) then return end
                appliedRole[resultID] = (tank and "TANK") or (healer and "HEALER") or (dps and "DAMAGER") or nil
            end)
        end)
    end
end
end   -- spec icons and raid counts

-- (kept inside a do-block: the game allows at most 200 top-level locals per file)
local NormalizeName, CheckGroupNotes, InstallNoteHooks, MakeNotesButton
do
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
function NormalizeName(name)
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
function CheckGroupNotes(silent)
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

function InstallNoteHooks()
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
function MakeNotesButton(parentPanel, x, y)
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
end   -- notes

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

---------------------------------------------------------------------------
-- Sign up as: pick the role you sign up with
---------------------------------------------------------------------------

-- the roles each class can play (only classes with more than one get buttons)
local CLASS_ROLES = {
    WARRIOR = { "TANK", "DAMAGER" },
    PALADIN = { "TANK", "HEALER", "DAMAGER" },
    DEATHKNIGHT = { "TANK", "DAMAGER" },
    DEMONHUNTER = { "TANK", "DAMAGER" },
    DRUID = { "TANK", "HEALER", "DAMAGER" },
    MONK = { "TANK", "HEALER", "DAMAGER" },
    PRIEST = { "HEALER", "DAMAGER" },
    SHAMAN = { "HEALER", "DAMAGER" },
    EVOKER = { "HEALER", "DAMAGER" },
}
local ROLE_LABELS = { TANK = "Tank", HEALER = "Healer", DAMAGER = "DPS" }
local ROLE_BUTTON_FIELDS = { TANK = "TankButton", HEALER = "HealerButton", DAMAGER = "DamagerButton" }
local roleButtons = {}            -- the role buttons of every panel (kept in step)

local function PlayerRoleList()
    local _, file = UnitClass("player")
    return file and CLASS_ROLES[file] or nil, file
end

-- the role you chose for this class, or nil
local function SelectedRole()
    local list, file = PlayerRoleList()
    local role = file and db.signUpRoles[file]
    if list and role then
        for _, r in ipairs(list) do
            if r == role then return role end
        end
    end
    return nil
end

local function RefreshRoleButtons()
    local role = SelectedRole()
    for _, b in ipairs(roleButtons) do
        b:SetState(b.role == role and "yes" or "off", ROLE_LABELS[b.role])
    end
end

-- Makes the Tank / Healer / DPS buttons at (x, y). Returns true if the class has a choice.
local function MakeRoleButtons(parent, x, y, width)
    local list = PlayerRoleList()
    if not list or #list < 2 then return false end
    local gap = 4
    local w = (width - gap * (#list - 1)) / #list
    for i, role in ipairs(list) do
        local b = MakeToggleButton(parent, x + (i - 1) * (w + gap), y, w)
        b.role = role
        b:SetScript("OnClick", function()
            local _, file = PlayerRoleList()
            if not file then return end
            db.signUpRoles[file] = (db.signUpRoles[file] ~= role) and role or nil
            RefreshRoleButtons()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Sign up as " .. ROLE_LABELS[role])
            GameTooltip:AddLine("Click again to go back to the game's own choice.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        roleButtons[#roleButtons + 1] = b
    end
    RefreshRoleButtons()
    return true
end

-- tick only the chosen role in the sign-up dialog (runs each time the dialog opens)
function ApplyPreferredRole(dialog)
    local role = SelectedRole()
    if not (role and dialog) then return end
    local chosen = dialog[ROLE_BUTTON_FIELDS[role]]
    local chosenBox = chosen and chosen.CheckButton
    if not chosenBox then return end
    for r, field in pairs(ROLE_BUTTON_FIELDS) do
        local box = dialog[field] and dialog[field].CheckButton
        if box then box:SetChecked(r == role) end
    end
    if LFGListApplicationDialog_UpdateValidState then
        LFGListApplicationDialog_UpdateValidState(dialog)
    end
end

---------------------------------------------------------------------------
-- Your keystone: a button that shows it and lists it as a group
---------------------------------------------------------------------------

local keyButton

-- { activityID, level, name } for the keystone your character holds, or nil
local function GetOwnedKey()
    if not (C_LFGList and C_LFGList.GetOwnedKeystoneActivityAndGroupAndLevel) then return nil end
    local activityID, _, level = C_LFGList.GetOwnedKeystoneActivityAndGroupAndLevel(false)
    if not usable(activityID) or not usable(level) or not activityID or not level then return nil end
    local info = C_LFGList.GetActivityInfoTable(activityID)
    local name = info and usable(info.fullName) and info.fullName or nil
    if name then name = name:gsub("%s*%b()", ""):gsub("%s+$", "") end
    return { activityID = activityID, level = level, name = name or "Keystone" }
end

local function UpdateKeyButton()
    if not keyButton then return end
    local key = GetOwnedKey()
    keyButton.key = key
    if key then
        keyButton:SetState("off", ("+%d  %s"):format(key.level, Abbreviate(key.name)))
    else
        keyButton:SetState("off", "No keystone")
    end
end

-- Opens the Group Finder's own "Start a Group" page with your key's dungeon
-- selected. (A listing needs a title from Blizzard's own page, which addons
-- can't fill in, so you press List Group there yourself.)
local function KeyStep(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        print("|cff33ff99BF:|r key button step '" .. label .. "' failed: " .. tostring(err))
    end
    return ok
end

local function ListKey()
    local key = GetOwnedKey()
    if not key then
        print("|cff33ff99BF:|r you don't have a keystone to list.")
        return
    end
    if C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo() then
        print("|cff33ff99BF:|r you already have a listing up; delist it first.")
        return
    end
    local _, groupID = C_LFGList.GetOwnedKeystoneActivityAndGroupAndLevel(false)
    if not usable(groupID) then groupID = 0 end

    KeyStep("open window", function()
        if PVEFrame and not PVEFrame:IsShown() then PVEFrame_ToggleFrame() end
    end)
    KeyStep("premade tab", function()
        if GroupFinderFrameGroupButton3 then
            GroupFinderFrameGroupButton3:Click()
        else
            PVEFrame_ShowFrame("GroupFinderFrame")
        end
    end)
    -- press the game's own buttons instead of calling its functions, which
    -- the game blocks when an addon does it
    KeyStep("dungeons category", function()
        local cs = LFGListFrame.CategorySelection
        for _, btn in pairs(cs.CategoryButtons or {}) do
            if btn.categoryID == 2 and btn:IsShown() then btn:Click() break end
        end
        cs.StartGroupButton:Click()
    end)
end

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
    instantCheck:HookScript("OnClick", UpdateNoteSlots)
    instantChecks[#instantChecks + 1] = instantCheck
    y = y - ROW_STEP

    local noteY = y
    MakeSignUpNoteBox(panel, LEFT, y, WIDTH)
    y = y - ROW_H - SECTION
    -- Sign up as: Tank / Healer / DPS (only for classes that can play more than one)
    y = y + SECTION - 4
    if MakeRoleButtons(panel, LEFT, y, WIDTH) then
        y = y - ROW_H - SECTION
    else
        y = y - SECTION + 4
    end

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

    -- your keystone ----------------------------------------------------------
    y = y - 4
    keyButton = MakeToggleButton(panel, LEFT, y, WIDTH)
    keyButton:SetHeight(28)
    keyButton:SetScript("OnClick", ListKey)
    keyButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Your keystone")
        GameTooltip:AddLine("Click to open the listing page with your key's dungeon selected.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    keyButton:SetScript("OnLeave", GameTooltip_Hide)
    UpdateKeyButton()
    y = y - 28

    local baseHeight = -y + 14
    local baseGridTop = dungeonGridTop
    panel:SetHeight(baseHeight)
    BuildNoteCollapser(panel, noteY, ROW_STEP, function(collapsed)
        panel:SetHeight(baseHeight - (collapsed and ROW_STEP or 0))
        -- dungeon icons can be created later too, so place them from the grid position
        dungeonGridTop = baseGridTop + (collapsed and ROW_STEP or 0)
        for i, b in ipairs(dungeonButtons) do
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", panel, "TOPLEFT",
                dungeonGridLeft + ((i - 1) % 4) * (44 + DUNGEON_GAP),
                dungeonGridTop - math.floor((i - 1) / 4) * (44 + DUNGEON_GAP))
        end
    end)(not db.instantSignUp)

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
    instantCheck:HookScript("OnClick", UpdateNoteSlots)
    instantChecks[#instantChecks + 1] = instantCheck
    y = y - ROW_STEP

    local noteY = y
    MakeSignUpNoteBox(p, LEFT, y, WIDTH)
    y = y - ROW_H - SECTION
    y = y + SECTION - 4
    if MakeRoleButtons(p, LEFT, y, WIDTH) then
        y = y - ROW_H - SECTION
    else
        y = y - SECTION + 4
    end

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
    local noteShift = 0   -- how far the tabs and boss buttons are pulled up (note box not shown)

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
        if #raidData == 0 then
            local ok, result = pcall(BuildRaidData)
            if ok and result then raidData = result end
        end

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
            tab:SetPoint("TOPLEFT", p, "TOPLEFT", LEFT + (i - 1) * (tabWidth + gap), tabsY + noteShift)
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
            btn:SetPoint("TOPLEFT", p, "TOPLEFT", col == 0 and LEFT or COL2, bossY + noteShift - row * ROW_STEP)
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
        p:SetHeight(-(bossY + noteShift - (bossRows - 1) * ROW_STEP - ROW_H) + 14)
    end

    clear:SetScript("OnClick", function()
        wipe(db.raidBosses)
        LayoutRaid()
        RefreshList()
    end)

    -- pull everything up when the sign-up note box is not in this panel
    BuildNoteCollapser(p, noteY, ROW_STEP, function(collapsed)
        noteShift = collapsed and ROW_STEP or 0
        if p:IsShown() then LayoutRaid() end
    end)(not db.instantSignUp)

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
-- Applicants: filter the people who apply to your own dungeon listing
---------------------------------------------------------------------------
-- The game fills the applicant list itself; after it does, we rebuild it without
-- the applicants who don't match the filters. Nobody is declined: hidden
-- applicants come back as soon as you loosen a filter.

local APP_ROLES = {
    { value = "TANK", label = "Tank" },
    { value = "HEALER", label = "Healer" },
    { value = "DAMAGER", label = "DPS" },
}
local APP_CLASS_FILES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "DEATHKNIGHT",
    "SHAMAN", "MAGE", "WARLOCK", "MONK", "DRUID", "DEMONHUNTER", "EVOKER" }

local appSummaries = {}       -- ["dungeon"|"raid"] = "Showing 5 / 8" text
local applyingAppFilter = false

-- "dungeon" or "raid" while the listing you have up is one of those, else nil
local function ListingKind()
    if not (C_LFGList and C_LFGList.GetActiveEntryInfo) then return nil end
    local info = C_LFGList.GetActiveEntryInfo()
    if type(info) ~= "table" or not info.activityIDs then return nil end
    local id = info.activityIDs[1]
    if not usable(id) or not id then return nil end
    local a = C_LFGList.GetActivityInfoTable(id)
    if not (a and usable(a.categoryID)) then return nil end
    if a.categoryID == DUNGEON_CATEGORY_ID then return "dungeon" end
    if a.categoryID == RAID_CATEGORY_ID then return "raid" end
    return nil
end

-- the saved settings of each panel start with this
local function Prefix(kind) return kind == "raid" and "appRaid" or "app" end

-- { name, class, itemLevel, score, role } for one member of an applicant
local function ApplicantMember(appID, idx)
    local name, class, _, _, itemLevel, _, tank, healer, damage, assignedRole, _, score, _, _, _, specID =
        C_LFGList.GetApplicantMemberInfo(appID, idx)
    if type(name) == "table" then
        local t = name
        name, class, itemLevel, score = t.name, t.classFilename or t.class, t.itemLevel, t.dungeonScore
        tank, healer, damage, assignedRole = t.tank, t.healer, t.damage, t.assignedRole
        specID = t.specID
    end
    local role = assignedRole
    if not usable(role) or not role or role == "NONE" then
        role = (usable(tank) and tank and "TANK") or (usable(healer) and healer and "HEALER")
            or (usable(damage) and damage and "DAMAGER") or nil
    end
    return {
        name = usable(name) and name or nil,
        class = usable(class) and class or nil,
        itemLevel = usable(itemLevel) and itemLevel or nil,
        score = usable(score) and score or nil,
        specID = usable(specID) and specID or nil,
        role = role,
    }
end

-- Filters for a group of applicants (one person or a party). A group is hidden if
-- ANY member matches something you exclude, and shown if ANY member matches
-- something you include.

-- store[value] = 1 (include) / 2 (exclude); getValue(m) gives a member's value
local function GroupTriPass(store, members, field)
    local anyInclude, included = false, false
    for _, v in pairs(store) do
        if v == 1 then anyInclude = true break end
    end
    for _, m in ipairs(members) do
        local state = m[field] and store[m[field]]
        if state == 2 then return false end
        if state == 1 then included = true end
    end
    return (not anyInclude) or included
end

-- roles my group still needs (a dungeon group is 1 tank, 1 healer, 3 dps)
local function MissingRoles()
    local r = GetPartyRoles()
    return { TANK = r.TANK < 1, HEALER = r.HEALER < 1, DAMAGER = r.DAMAGER < 3 }
end

-- roles my group still needs (a dungeon group is 1 tank, 1 healer, 3 dps)
local function MissingRoles()
    local r = GetPartyRoles()
    return { TANK = r.TANK < 1, HEALER = r.HEALER < 1, DAMAGER = r.DAMAGER < 3 }
end

local function GroupPasses(members, kind)
    local P = Prefix(kind)
    local function get(name) return db[P .. name] end

    if kind == "dungeon" and db.appFit then
        local missing = MissingRoles()
        if missing.TANK or missing.HEALER or missing.DAMAGER then
            local fits = false
            for _, m in ipairs(members) do
                if m.role and missing[m.role] then fits = true break end
            end
            if not fits then return false end
        end
    end
    if not GroupTriPass(get("Roles"), members, "role") then return false end
    if not GroupTriPass(get("Classes"), members, "class") then return false end

    local bl = get("Bloodlust")
    if bl ~= 0 then
        local any = false
        for _, m in ipairs(members) do
            if m.class and BLOODLUST_CLASSES[m.class] then any = true break end
        end
        if bl == 1 and not any then return false end
        if bl == 2 and any then return false end
    end

    -- ranges: at least one member inside (members the game gives no number for count as inside)
    local lo, hi = get("IlvlMin"), get("IlvlMax")
    if lo > ILVL_MIN or hi < ILVL_MAX then
        local ok = false
        for _, m in ipairs(members) do
            local v = m.itemLevel
            if not v or ((lo <= ILVL_MIN or v >= lo) and (hi >= ILVL_MAX or v <= hi)) then
                ok = true break
            end
        end
        if not ok then return false end
    end
    if kind == "dungeon" and (db.appScoreMin > SCORE_MIN or db.appScoreMax < APP_SCORE_MAX) then
        local ok = false
        for _, m in ipairs(members) do
            local v = m.score
            if not v or ((db.appScoreMin <= SCORE_MIN or v >= db.appScoreMin)
                and (db.appScoreMax >= APP_SCORE_MAX or v <= db.appScoreMax)) then
                ok = true break
            end
        end
        if not ok then return false end
    end

    if get("BadNote") or get("GoodNote") then
        local good, bad = false, false
        for _, m in ipairs(members) do
            local note = m.name and db.notes[NormalizeName(m.name) or ""]
            if note and note.color == "red" then bad = true end
            if note and note.color == "green" then good = true end
        end
        if get("BadNote") and bad then return false end
        if get("GoodNote") and not good then return false end
    end
    return true
end

local function ApplicantPasses(appID, kind)
    kind = kind or ListingKind() or "dungeon"
    local a, _, _, d = C_LFGList.GetApplicantInfo(appID)
    local numMembers = (type(a) == "table") and a.numMembers or d
    if not usable(numMembers) or not numMembers then return true end
    local members = {}
    for idx = 1, numMembers do
        local ok, m = pcall(ApplicantMember, appID, idx)
        if ok and m then members[#members + 1] = m end
    end
    if #members == 0 then return true end
    return GroupPasses(members, kind)
end

local function ApplyApplicantFilter(viewer)
    if applyingAppFilter then return end
    viewer = viewer or (LFGListFrame and LFGListFrame.ApplicationViewer)
    local box = viewer and viewer.ScrollBox
    if not (box and box.GetDataProvider and box.SetDataProvider and CreateDataProvider) then return end
    local dp = box:GetDataProvider()
    if not (dp and dp.Enumerate) then return end

    local kind = ListingKind()
    local filtering = kind and db[Prefix(kind) .. "Enabled"]
    local filtered, total, shown = CreateDataProvider(), 0, 0
    for _, elem in dp:Enumerate() do
        total = total + 1
        local id
        if type(elem) == "number" then
            id = elem
        elseif type(elem) == "table" then
            id = elem.applicantID or elem.id or elem.applicantId
            if not id then
                for _, v in pairs(elem) do
                    if type(v) == "number" then id = v break end
                end
            end
        end
        if not filtering or not id or ApplicantPasses(id, kind) then
            filtered:Insert(elem)
            shown = shown + 1
        end
    end
    local text = appSummaries[kind or ""]
    if text then
        text:SetText(total > 0 and ("Showing %d / %d"):format(shown, total) or "No applicants")
    end
    if shown ~= total then
        applyingAppFilter = true
        box:SetDataProvider(filtered, ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
        applyingAppFilter = false
    end
end

-- re-run the game's own list update, which runs our filter straight after it
local function RefreshApplicants()
    local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
    if viewer and LFGListApplicationViewer_UpdateResults then
        local ok, err = pcall(LFGListApplicationViewer_UpdateResults, viewer)
        if not ok then print("|cff33ff99BF:|r couldn't refresh applicants:", err) end
    end
end

local function UpdateApplicantPanels()
    local viewer = LFGListFrame and LFGListFrame.ApplicationViewer
    local kind = viewer and viewer:IsShown() and ListingKind() or nil
    if appPanel then appPanel:SetShown(kind == "dungeon") end
    if appRaidPanel then appRaidPanel:SetShown(kind == "raid") end
end

local MissingBuffClasses
-- Each raid buff and the class that brings it (edit here if the game changes them)
local RAID_BUFFS = {
    { class = "MAGE",        buff = "Arcane Intellect" },
    { class = "WARRIOR",     buff = "Battle Shout" },
    { class = "PRIEST",      buff = "Power Word: Fortitude" },
    { class = "DRUID",       buff = "Mark of the Wild" },
    { class = "SHAMAN",      buff = "Skyfury" },
    { class = "EVOKER",      buff = "Blessing of the Bronze" },
    { class = "MONK",        buff = "Mystic Touch" },
    { class = "DEMONHUNTER", buff = "Chaos Brand" },
    { class = "HUNTER",      buff = "Hunter's Mark" },
    { class = "PALADIN",     buff = "Devotion Aura" },
    { class = "ROGUE",       buff = "Atrophic Poison" },
    { class = "WARLOCK",     buff = "Curses/Gates" },
}

-- classes with a raid buff you care about that nobody in my group (me included) can provide
function MissingBuffClasses()
    local have = {}
    local function Add(unit)
        if not UnitExists(unit) then return end
        local _, file = UnitClass(unit)
        if usable(file) and file then have[file] = true end
    end
    Add("player")
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do Add("raid" .. i) end
    elseif IsInGroup() then
        for i = 1, GetNumGroupMembers() - 1 do Add("party" .. i) end
    end
    local missing = {}
    for _, b in ipairs(RAID_BUFFS) do
        if not have[b.class] and not db.raidBuffsIgnored[b.class] then
            missing[#missing + 1] = b.class
        end
    end
    return missing
end

---------------------------------------------------------------------------
-- Group Overview: your group or raid, regrouped by item level / class / tier / raid buff
---------------------------------------------------------------------------

-- (kept inside a do-block: the game allows at most 200 top-level locals per file)
local ToggleOverview, CacheApplicantLevels
local overviewButtons = {}     -- the Group Overview buttons (green while the popup is open)
do
local applicantIlvl = {}     -- [Name-Realm] = item level seen on the applicant list
local inspectIlvl = {}       -- [guid] = item level read by inspecting
local applicantSpec = {}     -- [Name-Realm] = specID seen on the applicant list
local inspectSpec = {}       -- [guid] = specID read by inspecting
local inspectTried = {}      -- [guid] = when we last tried to inspect them
local pendingInspect         -- guid of the inspect in progress
local overview               -- the popup (created on first open)
local LF = { seen = {}, left = {} }   -- roster memory: who is here, and who recently left

-- remember every applicant's item level, so we still know it once they have joined
function CacheApplicantLevels()
    local list = C_LFGList.GetApplicants()
    if not list then return end
    for _, id in ipairs(list) do
        local a, _, _, d = C_LFGList.GetApplicantInfo(id)
        local n = (type(a) == "table") and a.numMembers or d
        if usable(n) and type(n) == "number" then
            for idx = 1, n do
                local ok, m = pcall(ApplicantMember, id, idx)
                if ok and m and m.name then
                    local key = NormalizeName(m.name)
                    if key and m.itemLevel and m.itemLevel > 0 then applicantIlvl[key] = m.itemLevel end
                    if key and m.specID and m.specID > 0 then applicantSpec[key] = m.specID end
                end
            end
        end
    end
end

-- everyone in your group (just you when solo)
local function OverviewMembers()
    local units = {}
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do units[#units + 1] = "raid" .. i end
    elseif IsInGroup() then
        units[1] = "player"
        for i = 1, GetNumGroupMembers() - 1 do units[#units + 1] = "party" .. i end
    else
        units[1] = "player"
    end

    local out = {}
    for _, unit in ipairs(units) do
        if UnitExists(unit) then
            local name = UnitName(unit)
            local _, classFile = UnitClass(unit)
            if usable(name) and name and usable(classFile) and classFile then
                local isMe = UnitIsUnit(unit, "player")
                local fullName, fullRealm = UnitFullName(unit)
                local role = UnitGroupRolesAssigned(unit)
                if (role == nil or role == "NONE") and isMe then
                    local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
                    local getRole = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationRole) or GetSpecializationRole
                    if getSpec and getRole then
                        local spec = getSpec()
                        role = spec and getRole(spec) or nil
                    end
                end
                if not ROLE_ATLAS[role or ""] then role = "DAMAGER" end

                local ilvl, specID
                if isMe then
                    local _, equipped = GetAverageItemLevel()
                    ilvl = equipped
                    local getSpec = (C_SpecializationInfo and C_SpecializationInfo.GetSpecialization) or GetSpecialization
                    local getInfo = (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo) or GetSpecializationInfo
                    local idx = getSpec and getSpec()
                    if idx and getInfo then specID = getInfo(idx) end
                else
                    local fullName, realm = UnitFullName(unit)
                    local key = usable(fullName) and fullName and NormalizeName(
                        (usable(realm) and realm and realm ~= "") and (fullName .. "-" .. realm) or fullName)
                    local guid = UnitGUID(unit) or ""
                    ilvl = (key and applicantIlvl[key]) or inspectIlvl[guid]
                    specID = (key and applicantSpec[key]) or inspectSpec[guid]
                end
                local spec
                if type(specID) == "number" and usable(specID) and specID > 0 and GetSpecializationInfoByID then
                    spec = select(2, GetSpecializationInfoByID(specID))
                    if not (usable(spec) and type(spec) == "string") then spec = nil end
                end
                if not (type(ilvl) == "number" and usable(ilvl) and ilvl > 0) then ilvl = nil end
                local guid = UnitGUID(unit)
                out[#out + 1] = { unit = unit, name = name, class = classFile, role = role, ilvl = ilvl, spec = spec,
                    guid = usable(guid) and guid or nil,
                    fullName = usable(fullName) and fullName or nil,
                    realm = usable(fullRealm) and fullRealm or nil }
            end
        end
    end
    return out
end

local function ClassName(file)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file]) or file
end

local function LeftKey(m) return m.guid or m.fullName or m.name end

-- compare the group against the last one we saw; whoever vanished has "recently left"
function LF.Update()
    if not IsInGroup() then
        wipe(LF.seen); wipe(LF.left)
        return
    end
    local now = {}
    for _, m in ipairs(OverviewMembers()) do
        local key = LeftKey(m)
        if key then
            now[key] = true
            local copy = {}
            for k, v in pairs(m) do copy[k] = v end
            copy.unit = nil
            LF.seen[key] = copy
            LF.left[key] = nil          -- came back
        end
    end
    for key, member in pairs(LF.seen) do
        if not now[key] then
            LF.left[key] = { member = member, when = GetTime() }
            LF.seen[key] = nil
        end
    end
end

-- keep watching the group even while the window is closed
do
    local watcher = CreateFrame("Frame")
    watcher:RegisterEvent("GROUP_ROSTER_UPDATE")
    watcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    watcher:SetScript("OnEvent", function() pcall(LF.Update) end)
end

local function SortByIlvl(list)
    table.sort(list, function(a, b)
        if (a.left and true or false) ~= (b.left and true or false) then return not a.left end
        if (a.ilvl or 0) ~= (b.ilvl or 0) then return (a.ilvl or 0) > (b.ilvl or 0) end
        return a.name < b.name
    end)
end

-- groups = { { title, sub, color, members } ... } for the chosen mode
local function BuildOverviewGroups(members, mode)
    local groups, byKey = {}, {}
    local function Add(key, title, sub, color, m)
        local g = byKey[key]
        if not g then
            g = { title = title, sub = sub, color = color, members = {} }
            byKey[key] = g
            groups[#groups + 1] = g
        end
        g.members[#g.members + 1] = m
    end

    if mode == "class" then
        local files = {}
        for _, m in ipairs(members) do files[m.class] = true end
        local order = {}
        for file in pairs(files) do order[#order + 1] = file end
        table.sort(order, function(a, b) return ClassName(a) < ClassName(b) end)
        for _, file in ipairs(order) do
            local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[file]
            byKey[file] = { title = ClassName(file), color = c and { c.r, c.g, c.b }, members = {} }
            groups[#groups + 1] = byKey[file]
        end
        for _, m in ipairs(members) do table.insert(byKey[m.class].members, m) end
    elseif mode == "tier" then
        local order, classesOf = { "Woven", "Cured", "Cast", "Forged" }, {}
        for file, token in pairs(TIER_TOKEN) do
            classesOf[token] = classesOf[token] or {}
            table.insert(classesOf[token], ClassName(file))
        end
        for _, token in ipairs(order) do
            table.sort(classesOf[token] or {})
            byKey[token] = { title = token, sub = table.concat(classesOf[token] or {}, ", "), members = {} }
            groups[#groups + 1] = byKey[token]
        end
        for _, m in ipairs(members) do
            local token = TIER_TOKEN[m.class]
            if token then table.insert(byKey[token].members, m) else Add("none", "No tier set", nil, nil, m) end
        end
    elseif mode == "buff" then
        local buffOf = {}
        for _, b in ipairs(RAID_BUFFS) do buffOf[b.class] = b end
        for _, b in ipairs(RAID_BUFFS) do
            byKey[b.class] = { title = b.buff, sub = ClassName(b.class), members = {} }
            groups[#groups + 1] = byKey[b.class]
        end
        for _, m in ipairs(members) do
            if buffOf[m.class] then
                table.insert(byKey[m.class].members, m)
            else
                Add("none", "No raid buff", nil, nil, m)
            end
        end
    elseif mode == "prog" then
        for _, m in ipairs(members) do
            if m.pkey then
                Add(m.pkey, m.ptitle, nil, m.pcolor, m)
                byKey[m.pkey].rank = m.prank
            end
        end
        table.sort(groups, function(a, b) return (a.rank or 0) > (b.rank or 0) end)
    else   -- "ilvl": by role
        local titles = { TANK = "Tanks", HEALER = "Healers", DAMAGER = "DPS" }
        for _, role in ipairs({ "TANK", "HEALER", "DAMAGER" }) do
            byKey[role] = { title = titles[role], members = {} }
            groups[#groups + 1] = byKey[role]
        end
        for _, m in ipairs(members) do table.insert(byKey[m.role].members, m) end
    end

    -- drop empty groups, sort the rest by item level, work out the averages
    local out = {}
    for _, g in ipairs(groups) do
        if #g.members > 0 then
            SortByIlvl(g.members)
            local sum, n, present = 0, 0, 0
            for _, m in ipairs(g.members) do
                if not m.left then
                    present = present + 1
                    if m.ilvl then sum = sum + m.ilvl; n = n + 1 end
                end
            end
            g.present = present
            g.avg = n > 0 and (sum / n) or nil
            out[#out + 1] = g
        end
    end
    return out
end

-- Progress view: raid progress of the group, from Raider.IO (kills per boss and difficulty)
-- and from the game's own achievements (Ahead of the Curve / Cutting Edge) when in range
local PG = { ach = {}, tried = {}, bosses = {}, bossTries = {}, raids = {}, cur = nil, pending = nil }
_G.BetterFiltersPG = PG

local DIFF_LETTER = { [1] = "N", [2] = "H", [3] = "M" }
local DIFF_NAME = { [1] = "Normal", [2] = "Heroic", [3] = "Mythic" }
local DIFF_COLOR = { [1] = "1eff00", [2] = "a335ee", [3] = "ff8000" }

function PG.Profile(unit, fullName, realm)
    local rio = _G.RaiderIO
    if not (rio and rio.GetProfile) then return nil end
    local ok, res
    if unit then
        ok, res = pcall(rio.GetProfile, unit)
    elseif fullName then
        -- someone who has left: no unit any more, so by name
        ok, res = pcall(rio.GetProfile, fullName, (realm and realm ~= "") and realm or GetRealmName())
    else
        return nil
    end
    if ok and type(res) == "table" and type(res.raidProfile) == "table" then return res.raidProfile end
end

local function EachRaidEntry(profile, fn)
    for _, key in ipairs({ "progress", "mainProgress" }) do
        local list = profile[key]
        if type(list) == "table" then
            for _, e in ipairs(list) do
                if type(e) == "table" and type(e.raid) == "table" and e.raid.id then fn(e) end
            end
        end
    end
end

-- boss names of a raid from the Encounter Journal (Raider.IO lists kills in that order).
-- The journal functions have moved around between game versions: try each way.
local function JournalInstance(mapId)
    local list = {
        C_EncounterJournal and C_EncounterJournal.GetInstanceForGameMap or false,
        _G.EJ_GetInstanceForMap or false,
    }
    for i = 1, 2 do
        local fn = list[i]
        if fn then
            local ok, id = pcall(fn, mapId)
            if ok and type(id) == "number" and id > 0 then return id end
        end
    end
end

local function JournalBossName(index, instanceID, selected)
    local list = {
        C_EncounterJournal and C_EncounterJournal.GetEncounterInfoByIndex or false,
        _G.EJ_GetEncounterInfoByIndex or false,
    }
    for i = 1, 2 do
        local fn = list[i]
        if fn then
            -- with the instance given, or (once it is selected) without
            local ok, a = pcall(fn, index, instanceID)
            if ok then
                if type(a) == "string" and a ~= "" then return a end
                if type(a) == "table" and type(a.name) == "string" and a.name ~= "" then return a.name end
            end
            if selected then
                ok, a = pcall(fn, index)
                if ok and type(a) == "string" and a ~= "" then return a end
            end
        end
    end
end

function PG.Bosses(raid)
    local cached = PG.bosses[raid.id]
    if cached then return cached end
    local ej = raid.mapId and JournalInstance(raid.mapId)
    local names, real = {}, true
    local selected = false
    for i = 1, raid.bossCount or 0 do
        local name = ej and JournalBossName(i, ej, selected)
        if ej and not name and not selected and _G.EJ_SelectInstance then
            -- some versions only answer for the journal's selected instance
            selected = pcall(EJ_SelectInstance, ej)
            if selected then name = JournalBossName(i, ej, true) end
        end
        if not name then real = false end
        names[i] = name or ("Boss " .. i)
    end
    PG.bossTries[raid.id] = (PG.bossTries[raid.id] or 0) + 1
    if real or PG.bossTries[raid.id] >= 3 then PG.bosses[raid.id] = names end
    return names
end

-- Every Ahead of the Curve / Cutting Edge achievement the game has. Going through all the
-- achievements takes a couple of seconds, so it is done a little at a time in the
-- background (and kept in the saved variables until the game updates).
local ACHIEVEMENT_ROOT = 168      -- the "Dungeons & Raids" achievement category

local function UnderRoot(cat)
    local guard = 0
    while cat and cat > 0 and guard < 10 do
        if cat == ACHIEVEMENT_ROOT then return true end
        local _, parent = GetCategoryInfo(cat)
        cat = parent
        guard = guard + 1
    end
    return false
end

function PG.StartScan()
    if PG.scanning or not (GetCategoryList and GetCategoryNumAchievements and GetAchievementInfo and GetCategoryInfo) then return end
    PG.scanning = true
    local cats, all = {}, GetCategoryList()
    for _, cat in ipairs(all) do
        if UnderRoot(cat) then cats[#cats + 1] = cat end
    end
    if #cats == 0 then cats = all end       -- the root category was not found: look everywhere
    local list, ci, ai, n = {}, 1, 1, nil
    local function Step()
        local start = debugprofilestop()
        while ci <= #cats do
            local cat = cats[ci]
            n = n or (GetCategoryNumAchievements(cat) or 0)
            while ai <= n do
                local id, name = GetAchievementInfo(cat, ai)
                if id and type(name) == "string" then
                    if name:find("Ahead of the Curve", 1, true) then list[#list + 1] = { id = id, name = name, kind = "aotc" }
                    elseif name:find("Cutting Edge", 1, true) then list[#list + 1] = { id = id, name = name, kind = "ce" } end
                end
                ai = ai + 1
                if debugprofilestop() - start > 6 then
                    C_Timer.After(0, Step)
                    return
                end
            end
            ci, ai, n = ci + 1, 1, nil
        end
        PG.list = list
        PG.scanning = false
        db.achList = { build = select(2, GetBuildInfo()), list = list }
        if PG.refresh then pcall(PG.refresh) end
    end
    C_Timer.After(0, Step)
end

function PG.AchList()
    if PG.list then return PG.list end
    local saved = db.achList
    if type(saved) == "table" and saved.build == select(2, GetBuildInfo()) and type(saved.list) == "table" and #saved.list > 0 then
        PG.list = saved.list
        return PG.list
    end
    PG.StartScan()
    return {}
end

-- the two achievements of a raid: they are named after its last boss
function PG.AchFor(raid)
    local names = PG.Bosses(raid)
    local last = names[#names]
    local aotc, ce
    if last and not last:match("^Boss %d+$") then
        for _, a in ipairs(PG.AchList()) do
            if a.name:sub(-(#last + 2)) == ": " .. last then
                if a.kind == "aotc" then aotc = a.id else ce = a.id end
            end
        end
    end
    return aotc, ce
end

local function Done(id)
    local _, _, _, completed = GetAchievementInfo(id)
    return completed and true or false
end

-- work out, for the chosen raid, what each member has done and which group they belong in
function PG.Prepare(members)
    local byId, raids = {}, {}
    local anyProfile = false
    for _, m in ipairs(members) do
        m.rp = PG.Profile(m.unit, m.fullName, m.realm)
        if m.rp then
            anyProfile = true
            EachRaidEntry(m.rp, function(e)
                local r = e.raid
                if not byId[r.id] then
                    byId[r.id] = { id = r.id, name = r.name or ("Raid " .. r.id), ordinal = r.ordinal or 99,
                        bossCount = r.bossCount or 0, mapId = r.mapId, shortName = r.shortName }
                    raids[#raids + 1] = byId[r.id]
                end
            end)
        end
    end
    table.sort(raids, function(a, b)
        if a.ordinal ~= b.ordinal then return a.ordinal < b.ordinal end
        return a.name < b.name
    end)
    PG.raids = raids
    local raid = byId[db.overviewRaid or 0] or raids[1]
    PG.cur = nil
    if not raid then return nil, anyProfile end

    local aotcID, ceID = PG.AchFor(raid)
    PG.cur = { raid = raid, aotc = aotcID, ce = ceID }

    for _, m in ipairs(members) do
        local diffs = {}
        if m.rp then
            EachRaidEntry(m.rp, function(e)
                if e.raid.id == raid.id and e.difficulty then
                    local cur = diffs[e.difficulty]
                    local kills = e.progressCount or 0
                    if not cur then
                        diffs[e.difficulty] = { kills = kills, per = e.killsPerBoss }
                    else
                        if kills > cur.kills then cur.kills = kills end
                        if not cur.per and e.killsPerBoss then cur.per = e.killsPerBoss end
                    end
                end
            end)
        end
        m.diffs = diffs

        local state = PG.ach[m.guid or ""]
        local isMe = (not m.left) and m.unit and UnitIsUnit(m.unit, "player")
        m.aotc = aotcID and ((isMe and Done(aotcID)) or (state and state[aotcID])) or false
        m.ce = ceID and ((isMe and Done(ceID)) or (state and state[ceID])) or false
        m.achKnown = isMe or (state ~= nil)

        local function K(d) return diffs[d] and diffs[d].kills or 0 end
        local total = raid.bossCount
        if m.ce then
            m.pkey, m.ptitle, m.prank, m.pcolor = "ce", "Cutting Edge", 1000, { 1, 0.5, 0 }
        elseif K(3) > 0 then
            m.pkey, m.ptitle, m.prank, m.pcolor = "m" .. K(3), ("Mythic %d/%d"):format(K(3), total), 900 + K(3), { 1, 0.5, 0 }
        elseif m.aotc then
            m.pkey, m.ptitle, m.prank, m.pcolor = "aotc", "Ahead of the Curve", 800, { 0.64, 0.21, 0.93 }
        elseif K(2) > 0 then
            m.pkey, m.ptitle, m.prank, m.pcolor = "h" .. K(2), ("Heroic %d/%d"):format(K(2), total), 700 + K(2), { 0.64, 0.21, 0.93 }
        elseif K(1) > 0 then
            m.pkey, m.ptitle, m.prank, m.pcolor = "n" .. K(1), ("Normal %d/%d"):format(K(1), total), 600 + K(1), { 0.12, 1, 0 }
        elseif m.rp then
            m.pkey, m.ptitle, m.prank = "none", "No progress", 100
        else
            m.pkey, m.ptitle, m.prank = "nodata", "No Raider.IO data", 50
        end

        local parts = {}
        for d = 3, 1, -1 do
            if K(d) > 0 then parts[#parts + 1] = ("|cff%s%s %d/%d|r"):format(DIFF_COLOR[d], DIFF_LETTER[d], K(d), total) end
        end
        m.psummary = table.concat(parts, "  ")
        local tags = {}
        if m.ce then tags[#tags + 1] = "|cffff8000CE|r" end
        if m.aotc then tags[#tags + 1] = "|cffa335eeAotC|r" end
        m.ptags = table.concat(tags, " ")
    end
    return raid, anyProfile
end

-- one achievement-comparison read at a time, like the item level inspects
function PG.NextAch()
    if not (overview and overview:IsShown()) or db.overviewMode ~= "prog" or PG.pending then return end
    local cur = PG.cur
    if not (cur and (cur.aotc or cur.ce)) or not SetAchievementComparisonUnit then return end
    if AchievementFrame and AchievementFrame:IsShown() then return end
    local now = GetTime()
    for _, m in ipairs(OverviewMembers()) do
        local guid = UnitGUID(m.unit)
        if usable(guid) and guid and not UnitIsUnit(m.unit, "player") and PG.ach[guid] == nil
            and (not PG.tried[guid] or now - PG.tried[guid] > 30)
            and UnitIsConnected(m.unit) and CanInspect(m.unit) then
            PG.tried[guid] = now
            PG.pending = guid
            if not pcall(SetAchievementComparisonUnit, m.unit) then PG.pending = nil end
            C_Timer.After(4, function()
                if PG.pending == guid then
                    PG.pending = nil
                    if ClearAchievementComparisonUnit then pcall(ClearAchievementComparisonUnit) end
                end
            end)
            return
        end
    end
end

function PG.AchReady(guid)
    if not guid or guid ~= PG.pending then return end
    PG.pending = nil
    local state = {}
    for _, a in ipairs(PG.AchList()) do
        local ok, done = pcall(GetAchievementComparisonInfo, a.id)
        state[a.id] = ok and done and true or false
    end
    PG.ach[guid] = state
    if ClearAchievementComparisonUnit then pcall(ClearAchievementComparisonUnit) end
end

-- hover: boss by boss
function PG.Tooltip(line)
    local m, cur = line.prog, PG.cur
    if not (m and cur) then return end
    GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
    GameTooltip:SetText(m.name .. " - " .. cur.raid.name)
    local names = PG.Bosses(cur.raid)
    for i = 1, cur.raid.bossCount do
        local parts = {}
        for d = 1, 3 do
            local per = m.diffs[d] and m.diffs[d].per
            local k = per and per[i]
            if type(k) == "number" and k > 0 then
                parts[#parts + 1] = ("|cff%s%s %d|r"):format(DIFF_COLOR[d], DIFF_LETTER[d], k)
            end
        end
        if #parts > 0 then
            GameTooltip:AddDoubleLine(names[i], table.concat(parts, "  "), 1, 1, 1)
        else
            GameTooltip:AddDoubleLine(names[i], "-", 0.6, 0.6, 0.6, 0.6, 0.6, 0.6)
        end
    end
    if not m.achKnown and (cur.aotc or cur.ce) then
        GameTooltip:AddLine("Ahead of the Curve / Cutting Edge not read yet (needs to be in range).", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
end

local OVERVIEW_W, OVERVIEW_LINE = 340, 18
local OVERVIEW_MODES = {
    { key = "ilvl",  label = "Ilvl" },
    { key = "class", label = "Class" },
    { key = "tier",  label = "Tier Set" },
    { key = "buff",  label = "Raid Buff" },
    { key = "prog",  label = "Progress" },
}

local function OverviewLine(i)
    local l = overview.lines[i]
    if l then return l end
    l = CreateFrame("Frame", nil, overview.child)
    l:SetSize(OVERVIEW_W, OVERVIEW_LINE)
    l.bg = l:CreateTexture(nil, "BACKGROUND")
    l.bg:SetAllPoints()
    l.role = l:CreateTexture(nil, "ARTWORK")
    l.role:SetSize(14, 14)
    l.role:SetPoint("LEFT", 4, 0)
    l.name = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.name:SetPoint("LEFT", 22, 0)
    l.name:SetWidth(120)
    l.name:SetJustifyH("LEFT")
    l.class = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.class:SetPoint("LEFT", 146, 0)
    l.class:SetWidth(90)
    l.class:SetJustifyH("LEFT")
    l.ilvl = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.ilvl:SetPoint("RIGHT", -6, 0)
    l.ilvl:SetJustifyH("RIGHT")
    l.head = l:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    l.head:SetPoint("LEFT", 6, 0)
    l.head:SetJustifyH("LEFT")
    -- member lines can be clicked to inspect that player
    l:EnableMouse(true)
    l.hl = l:CreateTexture(nil, "HIGHLIGHT")
    l.hl:SetAllPoints()
    l.hl:SetColorTexture(1, 0.82, 0, 0.12)
    l:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" then return end
        if self.leftKey then                      -- a "Left" line: clicking clears it
            LF.left[self.leftKey] = nil
            self.leftKey = nil
            if PG.refresh then PG.refresh() end
            return
        end
        if not self.unit then return end
        local unit = self.unit
        if UnitGUID(unit) ~= self.guid then return end     -- the group changed
        if not (UnitIsConnected(unit) and CanInspect(unit)) then
            print("|cff33ff99BF:|r can't inspect " .. (UnitName(unit) or "that player") .. " (too far away or offline).")
            return
        end
        local ok, err = pcall(InspectUnit, unit)
        if not ok then print("|cff33ff99BF:|r couldn't inspect:", err) end
    end)
    l:SetScript("OnEnter", function(self) if self.prog then pcall(PG.Tooltip, self) end end)
    l:SetScript("OnLeave", function() GameTooltip:Hide() end)
    l.sub = l:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    l.sub:SetJustifyH("LEFT")
    l.sub:SetTextColor(0.6, 0.6, 0.6)
    overview.lines[i] = l
    return l
end

local function RefreshOverview()
    if not (overview and overview:IsShown()) then return end
    local mode = db.overviewMode
    for _, b in ipairs(overview.modeButtons) do
        b:SetState(b.key == mode and "sel" or "off", b.label)
    end

    pcall(LF.Update)
    local members = OverviewMembers()
    -- players who recently left, when asked for
    if db.overviewLeft then
        for _, entry in pairs(LF.left) do
            local copy = {}
            for k, v in pairs(entry.member) do copy[k] = v end
            copy.unit, copy.left = nil, true
            members[#members + 1] = copy
        end
    end
    local present = 0
    for _, m in ipairs(members) do if not m.left then present = present + 1 end end
    local progRaid, progData
    if mode == "prog" then progRaid, progData = PG.Prepare(members) end
    local groups = BuildOverviewGroups(members, mode)

    -- the raid picker only belongs to the Progress view
    local top = (mode == "prog") and 102 or 74
    overview.picker:SetShown(mode == "prog")
    if mode ~= "prog" then overview.menu:Hide() end
    overview.scroll:SetPoint("TOPLEFT", overview, "TOPLEFT", 12, -top)
    if mode == "prog" then
        overview.picker:SetState("off", progRaid and (progRaid.name .. "  v") or "No raid data  v")
    end

    local n, y = 0, 0
    -- height: how tall this line is (default one line)
    local function Next(height)
        n = n + 1
        local l = OverviewLine(n)
        height = height or OVERVIEW_LINE
        l:ClearAllPoints()
        l:SetPoint("TOPLEFT", overview.child, "TOPLEFT", 0, -y)
        l:SetHeight(height)
        l:Show()
        y = y + height
        -- reset what a line may have been used for before
        l.head:ClearAllPoints()
        l.head:SetPoint("LEFT", 6, 0)
        l.head:SetWidth(OVERVIEW_W - 90)
        l.head:SetWordWrap(false)
        l.sub:Hide()
        l.head:SetFontObject("GameFontNormal")
        l.unit, l.guid, l.prog = nil, nil, nil
        l.hl:SetShown(false)
        l.ilvl:ClearAllPoints()
        l.ilvl:SetPoint("RIGHT", -6, 0)
        return l
    end

    -- Ilvl view starts with the average of everyone
    if mode == "ilvl" then
        local sum, known = 0, 0
        for _, m in ipairs(members) do
            if m.ilvl and not m.left then sum = sum + m.ilvl; known = known + 1 end
        end
        local l = Next(26)
        l.bg:SetColorTexture(1, 0.82, 0, 0.20)
        l.role:Hide(); l.name:Hide(); l.class:Hide(); l.ilvl:Hide()
        l.head:Show()
        l.head:SetFontObject("GameFontNormal")
        l.head:SetWidth(OVERVIEW_W - 12)
        l.head:SetTextColor(1, 1, 1)
        if known > 0 then
            l.head:SetText(("Average item level: |cffffd100%d|r"):format(math.floor(sum / known + 0.5))
                .. (known < present and ("  |cff999999(%d/%d known)|r"):format(known, present) or ""))
        else
            l.head:SetText("Average item level: |cffffd100?|r")
        end
    end

    for _, g in ipairs(groups) do
        -- a long note (the classes of a tier set) goes on a second row so it can't run into the average
        local twoRows = g.sub and #g.sub > 14
        local l = Next(twoRows and (OVERVIEW_LINE + 14) or nil)
        l.bg:SetColorTexture(1, 0.82, 0, 0.12)
        l.role:Hide(); l.name:Hide(); l.class:Hide()
        l.head:Show()
        local c = g.color
        if c then l.head:SetTextColor(c[1], c[2], c[3]) else l.head:SetTextColor(1, 0.82, 0) end
        if twoRows then
            l.head:ClearAllPoints()
            l.head:SetPoint("TOPLEFT", 6, -3)
            l.head:SetText(("%s (%d)"):format(g.title, g.present or #g.members))
            l.ilvl:ClearAllPoints()
            l.ilvl:SetPoint("TOPRIGHT", -6, -4)
            l.sub:ClearAllPoints()
            l.sub:SetPoint("TOPLEFT", 6, -OVERVIEW_LINE - 1)
            l.sub:SetWidth(OVERVIEW_W - 12)
            l.sub:SetText(g.sub)
            l.sub:Show()
        else
            l.head:SetText(("%s (%d)%s"):format(g.title, g.present or #g.members, g.sub and ("  |cff999999" .. g.sub .. "|r") or ""))
        end
        l.ilvl:SetTextColor(0.8, 0.8, 0.8)
        l.ilvl:SetText(g.avg and ("avg %d"):format(math.floor(g.avg + 0.5)) or "")
        l.ilvl:Show()
        for _, m in ipairs(g.members) do
            local r = Next()
            r.bg:SetColorTexture(1, 1, 1, 0.03)
            r.unit, r.guid = m.unit, m.unit and UnitGUID(m.unit) or nil
            r.hl:SetShown(m.unit ~= nil or m.left == true)
            r.leftKey = m.left and LeftKey(m) or nil
            r.head:Hide()
            r.role:SetAtlas(ROLE_ATLAS[m.role]); r.role:Show()
            local c2 = RAID_CLASS_COLORS and RAID_CLASS_COLORS[m.class]
            r.name:SetTextColor(c2 and c2.r or 1, c2 and c2.g or 1, c2 and c2.b or 1)
            r.name:SetText(m.name); r.name:Show()
            r.class:SetTextColor(0.65, 0.65, 0.65)
            r.class:SetText(m.spec or ClassName(m.class)); r.class:Show()
            r.ilvl:SetTextColor(1, 1, 1)
            if mode == "prog" then
                r.prog = m
                r.class:SetText(m.ptags ~= "" and m.ptags or (m.spec or ClassName(m.class)))
                r.ilvl:SetText(m.psummary ~= "" and m.psummary or "")
            else
                r.ilvl:SetText(m.ilvl and ("%d"):format(math.floor(m.ilvl + 0.5)) or "?")
            end
            r.ilvl:Show()
            if m.left then
                r.bg:SetColorTexture(0.85, 0.15, 0.15, 0.28)
                r.class:SetTextColor(1, 0.45, 0.45)
                r.class:SetText("Left")
                r.prog = nil
                r.ilvl:SetText(m.ilvl and ("%d"):format(math.floor(m.ilvl + 0.5)) or "?")
            end
        end
    end

    -- Raid Buff view: say which buffs nobody brings
    if mode == "buff" then
        local missing = MissingBuffClasses()
        local names = {}
        for _, file in ipairs(missing) do
            for _, b in ipairs(RAID_BUFFS) do
                if b.class == file then names[#names + 1] = b.buff end
            end
        end
        local l = Next()
        l.bg:SetColorTexture(0.9, 0.2, 0.2, #names > 0 and 0.12 or 0)
        l.role:Hide(); l.name:Hide(); l.class:Hide(); l.ilvl:Hide()
        l.head:Show()
        l.head:SetTextColor(1, 0.8, 0.8)
        -- may need several lines: wrap it and make the line as tall as the text
        l.head:ClearAllPoints()
        l.head:SetPoint("TOPLEFT", 6, -4)
        l.head:SetWidth(OVERVIEW_W - 12)
        l.head:SetWordWrap(true)
        l.head:SetText(#names > 0 and ("Missing: " .. table.concat(names, ", ")) or "Every raid buff is covered")
        local h = math.max(OVERVIEW_LINE, math.ceil(l.head:GetStringHeight() or 0) + 10)
        l:SetHeight(h)
        y = y - OVERVIEW_LINE + h
    end

    if mode == "prog" and not progRaid then
        local l = Next()
        l.bg:SetColorTexture(0.9, 0.2, 0.2, 0.12)
        l.role:Hide(); l.name:Hide(); l.class:Hide(); l.ilvl:Hide()
        l.head:Show(); l.head:SetTextColor(1, 0.8, 0.8)
        l.head:SetWidth(OVERVIEW_W - 12)
        l.head:SetText(_G.RaiderIO and "Raider.IO has no raid progress for this group."
            or "Raider.IO is not installed: it is where the raid progress comes from.")
    end

    for i = n + 1, #overview.lines do overview.lines[i]:Hide() end
    if #members == 0 then
        local l = Next()
        l.bg:SetColorTexture(0, 0, 0, 0)
        l.role:Hide(); l.name:Hide(); l.class:Hide(); l.ilvl:Hide()
        l.head:Show(); l.head:SetTextColor(0.7, 0.7, 0.7); l.head:SetText("Nobody in your group.")
    end

    -- as tall as the content, up to what fits on screen below the window's top edge
    local maxH = math.max(300, (UIParent:GetHeight() or 900) - 140 - 84 - 40)
    overview.child:SetSize(OVERVIEW_W, math.max(y, 1))
    overview:SetHeight(top + 10 + math.min(y, maxH))
    overview.scroll:SetVerticalScroll(math.min(overview.scroll:GetVerticalScroll(), math.max(0, y - maxH)))
end

PG.refresh = RefreshOverview

-- read the item level of one group member we do not know yet (one at a time)
local function InspectNext()
    if not (overview and overview:IsShown()) or pendingInspect then return end
    if InspectFrame and InspectFrame:IsShown() then return end
    local now = GetTime()
    for _, m in ipairs(OverviewMembers()) do
        local guid = UnitGUID(m.unit)
        if (not m.ilvl or not m.spec) and usable(guid) and guid and not UnitIsUnit(m.unit, "player")
            and (not inspectTried[guid] or now - inspectTried[guid] > 30)
            and UnitIsConnected(m.unit) and CanInspect(m.unit) then
            inspectTried[guid] = now
            pendingInspect = guid
            NotifyInspect(m.unit)
            C_Timer.After(3, function() if pendingInspect == guid then pendingInspect = nil end end)
            return
        end
    end
end

local function CreateOverview()
    overview = CreateFrame("Frame", "BetterFiltersOverview", UIParent)
    overview:SetSize(OVERVIEW_W + 24, 200)
    -- anchored by its top edge, so changing tabs grows and shrinks it downwards only
    overview:SetPoint("TOP", UIParent, "TOP", 0, -140)
    overview:SetFrameStrata("DIALOG")
    overview:SetMovable(true)
    overview:SetClampedToScreen(true)
    overview:EnableMouse(true)
    overview:RegisterForDrag("LeftButton")
    overview:SetScript("OnDragStart", overview.StartMoving)
    overview:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- keep the top-left corner as the anchor wherever it was dropped
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        end
    end)
    overview.lines = {}
    overview:Hide()

    local edge = overview:CreateTexture(nil, "BACKGROUND", nil, -2)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(THEME.border))
    local bg = overview:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(THEME.bg))

    local title = overview:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", overview, "TOP", 0, -9)
    title:SetText("Group Overview")

    local close = MakeToggleButton(overview, 0, 0, 20)
    close:SetHeight(18)
    close:ClearAllPoints()
    close:SetPoint("TOPRIGHT", overview, "TOPRIGHT", -8, -8)
    close:SetState("no", "x")
    close:SetScript("OnClick", function() overview:Hide() end)

    -- "Recently Left" checkbox, top left (off by default)
    local leftBox = CreateFrame("Button", nil, overview)
    leftBox:SetSize(18, 18)
    leftBox:SetPoint("TOPLEFT", overview, "TOPLEFT", 8, -8)
    local boxEdge = leftBox:CreateTexture(nil, "BACKGROUND")
    boxEdge:SetAllPoints()
    boxEdge:SetColorTexture(unpack(THEME.border))
    local boxBg = leftBox:CreateTexture(nil, "BORDER")
    boxBg:SetPoint("TOPLEFT", 1, -1)
    boxBg:SetPoint("BOTTOMRIGHT", -1, 1)
    boxBg:SetColorTexture(unpack(THEME.bg))
    local tick = leftBox:CreateTexture(nil, "ARTWORK")
    tick:SetPoint("TOPLEFT", 4, -4)
    tick:SetPoint("BOTTOMRIGHT", -4, 4)
    tick:SetColorTexture(0.85, 0.2, 0.2, 1)
    local function ApplyBox() tick:SetShown(db.overviewLeft and true or false) end
    ApplyBox()
    leftBox:SetScript("OnClick", function()
        db.overviewLeft = not db.overviewLeft
        ApplyBox()
        RefreshOverview()
    end)
    leftBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Recently Left")
        GameTooltip:AddLine("Keep players who left your group in the list, marked in red.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    leftBox:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local divider = overview:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(THEME.border))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", overview, "TOPLEFT", 0, -32)
    divider:SetPoint("TOPRIGHT", overview, "TOPRIGHT", 0, -32)

    -- how to group
    overview.modeButtons = {}
    local gap = 4
    local w = (OVERVIEW_W - gap * (#OVERVIEW_MODES - 1)) / #OVERVIEW_MODES
    for i, mode in ipairs(OVERVIEW_MODES) do
        local b = MakeToggleButton(overview, 12 + (i - 1) * (w + gap), -42, w)
        b.key, b.label = mode.key, mode.label
        b:SetScript("OnClick", function()
            db.overviewMode = mode.key
            RefreshOverview()
        end)
        overview.modeButtons[#overview.modeButtons + 1] = b
    end

    -- Progress view: which raid to compare
    overview.picker = MakeToggleButton(overview, 12, -74, OVERVIEW_W)
    overview.picker:SetState("off", "Raid")
    overview.picker:Hide()
    overview.menu = CreateFrame("Frame", nil, overview)
    overview.menu:SetFrameStrata("FULLSCREEN_DIALOG")
    overview.menu:SetPoint("TOPLEFT", overview.picker, "BOTTOMLEFT", 0, -2)
    overview.menu:SetSize(OVERVIEW_W, 22)
    overview.menu:Hide()
    overview.menu.items = {}
    local menuEdge = overview.menu:CreateTexture(nil, "BACKGROUND", nil, -2)
    menuEdge:SetPoint("TOPLEFT", -1, 1)
    menuEdge:SetPoint("BOTTOMRIGHT", 1, -1)
    menuEdge:SetColorTexture(unpack(THEME.border))
    local menuBg = overview.menu:CreateTexture(nil, "BACKGROUND", nil, -1)
    menuBg:SetAllPoints()
    menuBg:SetColorTexture(unpack(THEME.bg))
    overview.picker:SetScript("OnClick", function()
        local menu = overview.menu
        if menu:IsShown() then menu:Hide() return end
        for i, raid in ipairs(PG.raids) do
            local b = menu.items[i]
            if not b then
                b = MakeToggleButton(menu, 0, -(i - 1) * 22, OVERVIEW_W)
                menu.items[i] = b
            end
            b:SetState((PG.cur and PG.cur.raid.id == raid.id) and "sel" or "off", raid.name)
            b:SetScript("OnClick", function()
                db.overviewRaid = raid.id
                menu:Hide()
                RefreshOverview()
            end)
            b:Show()
        end
        for i = #PG.raids + 1, #menu.items do menu.items[i]:Hide() end
        menu:SetHeight(math.max(22, #PG.raids * 22))
        menu:Show()
    end)

    overview.scroll = CreateFrame("ScrollFrame", nil, overview)
    overview.scroll:SetPoint("TOPLEFT", overview, "TOPLEFT", 12, -74)
    overview.scroll:SetPoint("BOTTOMRIGHT", overview, "BOTTOMRIGHT", -12, 10)
    overview.child = CreateFrame("Frame", nil, overview.scroll)
    overview.child:SetSize(OVERVIEW_W, 1)
    overview.scroll:SetScrollChild(overview.child)
    overview.scroll:EnableMouseWheel(true)
    overview.scroll:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, overview.child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(max, self:GetVerticalScroll() - delta * OVERVIEW_LINE * 2)))
    end)

    local function UpdateButtons()
        for _, b in ipairs(overviewButtons) do
            b:SetState(overview:IsShown() and "yes" or "off", "Group Overview")
        end
    end
    overview:SetScript("OnShow", function()
        UpdateButtons()
        RefreshOverview()
        InspectNext()
    end)
    overview:HookScript("OnHide", UpdateButtons)
    local elapsed = 0
    overview:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed > 2.5 then
            elapsed = 0
            pcall(InspectNext)
            pcall(PG.NextAch)
        end
    end)
    overview:RegisterEvent("GROUP_ROSTER_UPDATE")
    overview:RegisterEvent("INSPECT_READY")
    overview:RegisterEvent("INSPECT_ACHIEVEMENT_READY")
    overview:SetScript("OnEvent", function(_, event, guid)
        if event == "INSPECT_ACHIEVEMENT_READY" then
            pcall(PG.AchReady, guid)
        elseif event == "INSPECT_READY" then
            if guid and guid == pendingInspect then
                pendingInspect = nil
                for _, m in ipairs(OverviewMembers()) do
                    if UnitGUID(m.unit) == guid then
                        local ilvl = C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel
                            and C_PaperDollInfo.GetInspectItemLevel(m.unit)
                        if type(ilvl) == "number" and usable(ilvl) and ilvl > 0 then inspectIlvl[guid] = ilvl end
                        local specID = GetInspectSpecialization and GetInspectSpecialization(m.unit)
                        if type(specID) == "number" and usable(specID) and specID > 0 then inspectSpec[guid] = specID end
                        break
                    end
                end
                if ClearInspectPlayer then ClearInspectPlayer() end
            end
        end
        pcall(RefreshOverview)
    end)
    tinsert(UISpecialFrames, "BetterFiltersOverview")
end

function ToggleOverview()
    if not overview then CreateOverview() end
    overview:SetShown(not overview:IsShown())
end
end   -- Group Overview

-- kind = "dungeon" or "raid"; the raid panel has no Fit my group and no rating
local function BuildApplicantPanel(kind)
    local viewer = LFGListFrame.ApplicationViewer
    if not viewer then return end
    local isRaid = kind == "raid"
    local P = Prefix(kind)
    local anchor = PVEFrame or LFGListFrame

    local panelF = CreateFrame("Frame", isRaid and "BetterFiltersRaidApplicantPanel" or "BetterFiltersApplicantPanel", LFGListFrame)
    panelF:SetWidth(240)
    panelF:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 4, 0)
    if isRaid then appRaidPanel = panelF else appPanel = panelF end

    local edge = panelF:CreateTexture(nil, "BACKGROUND", nil, -2)
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(unpack(THEME.border))
    local bg = panelF:CreateTexture(nil, "BACKGROUND", nil, -1)
    bg:SetAllPoints()
    bg:SetColorTexture(unpack(THEME.bg))

    local title = panelF:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", panelF, "TOP", 0, -9)
    title:SetText("Better Filters")
    local divider = panelF:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(unpack(THEME.border))
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", panelF, "TOPLEFT", 0, -32)
    divider:SetPoint("TOPRIGHT", panelF, "TOPRIGHT", 0, -32)

    local LEFT, WIDTH = 14, 212
    local COL2 = LEFT + 108
    local ROW_H, ROW_STEP, LABEL_H, SECTION = 22, 26, 20, 14
    local y = -44

    MakeCheck(panelF, "Filter enabled", LEFT, y, P .. "Enabled", nil, RefreshApplicants)
    local summary = panelF:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    summary:SetPoint("CENTER", panelF, "TOPLEFT", COL2 + 52, y - 11)
    summary:SetText("")
    appSummaries[kind] = summary
    y = y - ROW_STEP

    -- Group Overview: your group or raid regrouped by item level / class / tier / buff
    local ovButton = MakeToggleButton(panelF, LEFT, y, WIDTH)
    local ov = _G.BetterFiltersOverview
    ovButton:SetState(ov and ov:IsShown() and "yes" or "off", "Group Overview")
    overviewButtons[#overviewButtons + 1] = ovButton
    ovButton:SetScript("OnClick", function() pcall(ToggleOverview) end)
    ovButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Group Overview")
        GameTooltip:AddLine("Shows your group or raid by item level, class, tier set or raid buff.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    ovButton:SetScript("OnLeave", GameTooltip_Hide)
    y = y - ROW_H - SECTION

    -- Role
    MakeLabel(panelF, "Role", LEFT, y)
    y = y - LABEL_H
    for i, r in ipairs(APP_ROLES) do
        MakePlaystyleCheck(panelF, r.label, LEFT + (i - 1) * 72, y, r.value, db[P .. "Roles"], 68, RefreshApplicants)
    end
    y = y - ROW_STEP
    if not isRaid then
        local fitCheck = MakeCheck(panelF, "Fit my group", LEFT, y, "appFit", WIDTH, RefreshApplicants)
        fitCheck:SetScript("OnEnter", function(self)
            local m = MissingRoles()
            local need = {}
            if m.TANK then need[#need + 1] = "tank" end
            if m.HEALER then need[#need + 1] = "healer" end
            if m.DAMAGER then need[#need + 1] = "dps" end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Fit my group")
            GameTooltip:AddLine("Only shows applicants for the roles your group is missing.", 1, 1, 1, true)
            GameTooltip:AddLine(#need > 0 and ("Missing now: " .. table.concat(need, ", ")) or "Your group has every role.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        fitCheck:SetScript("OnLeave", GameTooltip_Hide)
        y = y - ROW_STEP
    end
    y = y - (ROW_H - ROW_STEP) - SECTION     -- the last row of the section is ROW_H tall

    -- Sliders
    CreateRangeSlider(panelF, LEFT, y, WIDTH, {
        title = "Item level",
        minValue = ILVL_MIN, maxValue = ILVL_MAX, step = ILVL_STEP,
        loKey = P .. "IlvlMin", hiKey = P .. "IlvlMax",
        onChange = RefreshApplicants,
    })
    y = y - 46 - (isRaid and SECTION or 8)
    if not isRaid then
        CreateRangeSlider(panelF, LEFT, y, WIDTH, {
            title = "Dungeon rating",
            minValue = SCORE_MIN, maxValue = APP_SCORE_MAX, step = SCORE_STEP,
            loKey = "appScoreMin", hiKey = "appScoreMax",
            onChange = RefreshApplicants,
        })
        y = y - 46 - SECTION
    end

    -- Bloodlust and notes
    MakeLabel(panelF, "Applicant", LEFT, y)
    y = y - LABEL_H
    MakeTriCheck(panelF, LEFT, y, P .. "Bloodlust",
        { off = "Bloodlust class", yes = "Bloodlust class only", no = "No bloodlust class" }, RefreshApplicants)
    y = y - ROW_STEP
    local function NoteToggle(key, label, state, tip)
        local b = MakeToggleButton(panelF, LEFT, y, WIDTH)
        local function Apply() b:SetState(db[key] and state or "off", label) end
        b:SetScript("OnClick", function()
            db[key] = not db[key]
            Apply()
            RefreshApplicants()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(label)
            GameTooltip:AddLine(tip, 1, 1, 1, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        Apply()
        y = y - ROW_STEP
    end
    NoteToggle(P .. "BadNote", "Hide bad notes", "no", "Hides applicants (or parties) with someone you have a bad note on.")
    NoteToggle(P .. "GoodNote", "Only good notes", "yes", "Only shows applicants (or parties) with someone you have a good note on.")
    y = y + ROW_STEP
    y = y - ROW_H - SECTION

    -- Class
    MakeLabel(panelF, "Class", LEFT, y)
    local classHeaderY = y
    local clear = MakeToggleButton(panelF, 0, 0, 54)
    clear:SetHeight(18)
    clear:ClearAllPoints()
    clear:SetPoint("TOPRIGHT", panelF, "TOPRIGHT", -LEFT, y + 3)
    clear:SetState("off", "Clear")
    local classButtons = {}
    y = y - LABEL_H

    -- class icons, 4 per row; click cycles include (gold ring) / exclude (red ring + cross) / reset
    local classes = {}
    for _, file in ipairs(APP_CLASS_FILES) do
        classes[#classes + 1] = { file = file, name = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file]) or file }
    end
    table.sort(classes, function(a, b) return a.name < b.name end)
    local SIZE, GAP = 44, 12

    local function ClassVisuals()
        local anyIncluded = false
        for _, v in pairs(db[P .. "Classes"]) do
            if v == 1 then anyIncluded = true break end
        end
        for _, b in ipairs(classButtons) do
            local state = db[P .. "Classes"][b.classFile]
            if state == 1 then
                b.border:SetColorTexture(1, 0.82, 0, 1)
                b.border:Show(); b.cross:Hide(); b.icon:SetAlpha(1)
            elseif state == 2 then
                b.border:SetColorTexture(0.9, 0.15, 0.15, 1)
                b.border:Show(); b.cross:Show(); b.icon:SetAlpha(0.35)
            else
                b.border:Hide(); b.cross:Hide()
                b.icon:SetAlpha(anyIncluded and 0.45 or 1)
            end
        end
    end
    clear:SetScript("OnClick", function()
        wipe(db[P .. "Classes"])
        ClassVisuals()
        RefreshApplicants()
    end)

    for i, c in ipairs(classes) do
        local col = (i - 1) % 4
        local row = math.floor((i - 1) / 4)
        local b = CreateFrame("Button", nil, panelF)
        b:SetSize(SIZE, SIZE)
        b:SetPoint("TOPLEFT", panelF, "TOPLEFT", LEFT + col * (SIZE + GAP), y - row * (SIZE + GAP))
        b.classFile = c.file

        b.border = b:CreateTexture(nil, "BACKGROUND")
        b.border:SetPoint("TOPLEFT", -3, 3)
        b.border:SetPoint("BOTTOMRIGHT", 3, -3)
        b.border:Hide()
        b.edge = b:CreateTexture(nil, "BACKGROUND", nil, 1)
        b.edge:SetPoint("TOPLEFT", -1, 1)
        b.edge:SetPoint("BOTTOMRIGHT", 1, -1)
        b.edge:SetColorTexture(unpack(THEME.border))

        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        local atlas = "classicon-" .. c.file:lower()
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
            b.icon:SetAtlas(atlas)
        else
            b.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
            local tc = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[c.file]
            if tc then b.icon:SetTexCoord(unpack(tc)) end
        end

        b.cross = b:CreateTexture(nil, "OVERLAY", nil, 2)
        b.cross:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
        b.cross:SetSize(30, 30)
        b.cross:SetPoint("CENTER", b, "CENTER", 0, 0)
        b.cross:Hide()

        b:SetScript("OnClick", function(self)
            local state = ((db[P .. "Classes"][self.classFile] or 0) + 1) % 3
            db[P .. "Classes"][self.classFile] = (state ~= 0) and state or nil
            ClassVisuals()
            RefreshApplicants()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.file]
            if color then
                GameTooltip:SetText(c.name, color.r, color.g, color.b)
            else
                GameTooltip:SetText(c.name)
            end
            GameTooltip:AddLine("Click to cycle: include / exclude / reset", 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        classButtons[#classButtons + 1] = b
    end
    ClassVisuals()

    -- Missing buffs (raid only): select the classes that bring a raid buff nobody in
    -- your group brings yet
    if isRaid then
        local mb = MakeToggleButton(panelF, 0, 0, 80)
        mb:SetHeight(18)
        mb:ClearAllPoints()
        mb:SetPoint("TOPRIGHT", panelF, "TOPRIGHT", -(LEFT + 80), classHeaderY + 3)
        mb:SetState("off", "Missing buffs")
        mb:SetScript("OnClick", function()
            local missing = MissingBuffClasses()
            wipe(db[P .. "Classes"])
            for _, file in ipairs(missing) do db[P .. "Classes"][file] = 1 end
            ClassVisuals()
            RefreshApplicants()
            if #missing == 0 then print("|cff33ff99BF:|r your group already has every raid buff.") end
        end)
        mb:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Missing buffs")
            GameTooltip:AddLine("Clears the class filters and selects the classes that bring a raid buff your group doesn't have yet.", 1, 1, 1, true)
            local missing = MissingBuffClasses()
            local names = {}
            for _, file in ipairs(missing) do
                names[#names + 1] = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[file]) or file
            end
            GameTooltip:AddLine(#names > 0 and ("Missing now: " .. table.concat(names, ", ")) or "Your group has every raid buff.", 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        mb:SetScript("OnLeave", GameTooltip_Hide)

        -- cogwheel: pick the raid buffs you care about
        local cog = CreateFrame("Button", nil, panelF)
        cog:SetSize(18, 18)
        cog:SetPoint("TOPRIGHT", panelF, "TOPRIGHT", -(LEFT + 58), classHeaderY + 3)
        local cogEdge = cog:CreateTexture(nil, "BACKGROUND", nil, -1)
        cogEdge:SetPoint("TOPLEFT", -1, 1)
        cogEdge:SetPoint("BOTTOMRIGHT", 1, -1)
        cogEdge:SetColorTexture(unpack(TOGGLE_COLORS.off.border))
        local cogBg = cog:CreateTexture(nil, "BACKGROUND", nil, 0)
        cogBg:SetAllPoints()
        cogBg:SetColorTexture(unpack(TOGGLE_COLORS.off.bg))
        local cogIcon = cog:CreateTexture(nil, "ARTWORK")
        cogIcon:SetPoint("TOPLEFT", 2, -2)
        cogIcon:SetPoint("BOTTOMRIGHT", -2, 2)
        cogIcon:SetTexture("Interface\\Buttons\\UI-OptionsButton")
        local cogHover = cog:CreateTexture(nil, "HIGHLIGHT")
        cogHover:SetAllPoints()
        cogHover:SetColorTexture(1, 0.82, 0, 0.10)

        local pop = CreateFrame("Frame", nil, panelF)
        pop:SetSize(220, 34 + #RAID_BUFFS * 24 + 4)
        pop:SetPoint("TOPRIGHT", cog, "BOTTOMRIGHT", 0, -4)
        pop:SetFrameStrata("DIALOG")
        pop:EnableMouse(true)
        pop:Hide()
        local pEdge = pop:CreateTexture(nil, "BACKGROUND", nil, -2)
        pEdge:SetPoint("TOPLEFT", -1, 1)
        pEdge:SetPoint("BOTTOMRIGHT", 1, -1)
        pEdge:SetColorTexture(unpack(THEME.border))
        local pBg = pop:CreateTexture(nil, "BACKGROUND", nil, -1)
        pBg:SetAllPoints()
        pBg:SetColorTexture(unpack(THEME.bg))
        local pTitle = pop:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        pTitle:SetPoint("TOP", pop, "TOP", 0, -9)
        pTitle:SetText("Raid buffs I care about")
        for i, rb in ipairs(RAID_BUFFS) do
            local cname = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[rb.class]) or rb.class
            local label = cname .. ": " .. rb.buff
            local row = MakeToggleButton(pop, 10, -(30 + (i - 1) * 24), 200)
            local function Apply()
                row:SetState(db.raidBuffsIgnored[rb.class] and "off" or "yes", label)
            end
            row:SetScript("OnClick", function()
                db.raidBuffsIgnored[rb.class] = (not db.raidBuffsIgnored[rb.class]) or nil
                Apply()
            end)
            Apply()
        end
        cog:SetScript("OnClick", function() pop:SetShown(not pop:IsShown()) end)
        cog:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Raid buffs I care about")
            GameTooltip:AddLine("Choose which buffs the Missing buffs button looks for.", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        cog:SetScript("OnLeave", GameTooltip_Hide)
        panelF:HookScript("OnHide", function() pop:Hide() end)
    end
    local classRows = math.ceil(#classes / 4)
    y = y - classRows * SIZE - (classRows - 1) * GAP

    panelF:SetHeight(-y + 14)
    panelF:Hide()
end

local appHooksInstalled = false

local function InstallApplicantHooks()
    if appHooksInstalled then return end
    appHooksInstalled = true
    local viewer = LFGListFrame.ApplicationViewer
    if not viewer then return end

    viewer:HookScript("OnShow", function()
        UpdateApplicantPanels()
        C_Timer.After(0, UpdateApplicantPanels)
    end)
    viewer:HookScript("OnHide", function()
        if appPanel then appPanel:Hide() end
        if appRaidPanel then appRaidPanel:Hide() end
    end)
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
    ev:SetScript("OnEvent", UpdateApplicantPanels)

    -- Applicants who wrote a note with their sign-up get a gold tint, so you know there is
    -- something to read without hovering them
    local function ApplicantComment(appID)
        local info = { C_LFGList.GetApplicantInfo(appID) }
        local comment
        if type(info[1]) == "table" then comment = info[1].comment else comment = info[6] end
        if usable(comment) and type(comment) == "string" and comment:match("%S") then return true end
        return false
    end

    local function NoteGlow(row, show)
        local g = row.BFNoteGlow
        if not g then
            if not show then return end
            g = {}
            g.fill = row:CreateTexture(nil, "ARTWORK", nil, -8)
            g.fill:SetAllPoints(row)
            g.fill:SetColorTexture(1, 0.82, 0, 0.13)
            g.bar = row:CreateTexture(nil, "ARTWORK", nil, -7)
            g.bar:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
            g.bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            g.bar:SetWidth(2)
            g.bar:SetColorTexture(1, 0.82, 0, 0.9)
            row.BFNoteGlow = g
        end
        g.fill:SetShown(show)
        g.bar:SetShown(show)
    end

    -- Also hide the rows themselves as the game draws them (works even where the
    -- list can't be rebuilt)
    if LFGListApplicationViewer_UpdateApplicantMember then
        hooksecurefunc("LFGListApplicationViewer_UpdateApplicantMember", function(member, appID)
            pcall(function()
                local row = member and member:GetParent()
                if not (row and appID and usable(appID)) then return end
                local kind = ListingKind()
                local filtering = kind and db[Prefix(kind) .. "Enabled"]
                row:SetShown(not filtering or ApplicantPasses(appID, kind))
                NoteGlow(row, ApplicantComment(appID))
            end)
        end)
    end
    if LFGListApplicationViewer_UpdateResults then
        hooksecurefunc("LFGListApplicationViewer_UpdateResults", function(self)
            pcall(CacheApplicantLevels)
            pcall(ApplyApplicantFilter, self)
        end)
    else
        print("|cff33ff99BF:|r the applicant list wasn't found, applicant filters are off.")
    end
end

local function BuildApplicantPanels()
    for _, kind in ipairs({ "dungeon", "raid" }) do
        local ok, err = pcall(BuildApplicantPanel, kind)
        if not ok then print("|cff33ff99BF:|r couldn't build the " .. kind .. " applicant panel:", err) end
    end
    InstallApplicantHooks()
    UpdateApplicantPanels()
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
                local role, classFile, specName, raw = GetMember(all[i], m)
                Say("member", m, "->", Describe(role), "|", Describe(classFile), "|", Describe(specName))
                if type(raw) == "table" then
                    Say("   raw fields:", Describe(raw.className), "|", Describe(raw.classFilename), "|",
                        Describe(raw.specName), "|", Describe(raw.assignedRole))
                end
                if usable(classFile) and usable(specName) and type(classFile) == "string" and type(specName) == "string" then
                    Say("   spec icon:", SpecIconFor(classFile, specName) or "NOT FOUND")
                end
            end
        end
    end
end


local function DebugApp()
    local v = LFGListFrame and LFGListFrame.ApplicationViewer
    local function p(...) print("|cff33ff99BF app:|r", ...) end
    p("viewer", v ~= nil, "ScrollBox", v and v.ScrollBox ~= nil,
      "UpdateResults", LFGListApplicationViewer_UpdateResults ~= nil,
      "UpdateApplicantMember", LFGListApplicationViewer_UpdateApplicantMember ~= nil)
    p("listing kind", tostring(ListingKind()), "filter on", tostring(db.appEnabled), tostring(db.appRaidEnabled))
    local dp = v and v.ScrollBox and v.ScrollBox.GetDataProvider and v.ScrollBox:GetDataProvider()
    p("dataProvider", dp ~= nil, "Enumerate", dp and dp.Enumerate ~= nil)
    local apps = C_LFGList.GetApplicants() or {}
    p("applicants", #apps)
    for i = 1, math.min(#apps, 3) do
        local id = apps[i]
        local a, b, c, d = C_LFGList.GetApplicantInfo(id)
        p(i, "id", Describe(id), "info", type(a), Describe(d), "passes", tostring(ApplicantPasses(id)))
        local ok, m = pcall(ApplicantMember, id, 1)
        if ok then
            p("  member", Describe(m.name), "class", Describe(m.class), "role", Describe(m.role),
              "ilvl", Describe(m.itemLevel), "score", Describe(m.score))
        else
            p("  member error", m)
        end
    end
    if dp and dp.Enumerate then
        local n = 0
        for _, e in dp:Enumerate() do
            n = n + 1
            if n <= 2 then
                local keys = {}
                if type(e) == "table" then for k in pairs(e) do keys[#keys + 1] = tostring(k) end end
                p("element", type(e), table.concat(keys, ","))
            end
        end
        p("elements", n)
    end
end

SLASH_BETTERFILTERS1 = "/bf"
SLASH_BETTERFILTERS2 = "/sgf"
SlashCmdList["BETTERFILTERS"] = function(msg)
    if not db then return end
    if (msg or ""):lower():match("^debug") then
        local ok, err = pcall(DebugDump)
        if not ok then print("|cff33ff99BF:|r debug error:", err) end
    elseif (msg or ""):lower():match("^geo") then
        local ok, err = pcall(DumpFrames, "geo")
        if not ok then print("|cff33ff99BF:|r geo error:", err) end
    elseif (msg or ""):lower():match("^frames") then
        local ok, err = pcall(DumpFrames)
        if not ok then print("|cff33ff99BF:|r frames error:", err) end
    elseif (msg or ""):lower():match("^skin") then
        db.reskin = not (db.reskin ~= false)
        print("|cff33ff99BF:|r window skin " .. (db.reskin and "on" or "off") .. ". Type /reload to apply.")
    elseif (msg or ""):lower():match("^minimap") then
        db.minimapHidden = not db.minimapHidden
        if _G.BetterFiltersMinimapButton then _G.BetterFiltersMinimapButton:SetShown(not db.minimapHidden) end
        print("|cff33ff99BF:|r minimap button " .. (db.minimapHidden and "hidden" or "shown") .. ".")
    elseif (msg or ""):lower():match("^bosses") then
        local ok, err = pcall(_G.BetterFiltersDumpBosses, msg)
        if not ok then print("|cff33ff99BF:|r bosses error:", err) end
    elseif (msg or ""):lower():match("^prog") then
        local ok, err = pcall(_G.BetterFiltersDumpProgress, msg)
        if not ok then print("|cff33ff99BF:|r prog error:", err) end
    elseif (msg or ""):lower():match("^g") then
        local ok, err = pcall(ToggleOverview)
        if not ok then print("|cff33ff99BF:|r overview error:", err) end
    elseif (msg or ""):lower():match("^app") then
        local ok, err = pcall(DebugApp)
        if not ok then print("|cff33ff99BF:|r app error:", err) end
    elseif (msg or ""):lower():match("^spec") then
        local ok, err = pcall(DebugSpec)
        if not ok then print("|cff33ff99BF:|r spec error:", err) end
    else
        print("|cff33ff99BF:|r use '/bf g' to open the group overview, or '/bf debug' / '/bf spec' to inspect what listing data the game exposes.")
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

    -- applicant filter changes: note filters are plain on/off, ranges were widened
    if type(db.appBadNote) ~= "boolean" then db.appBadNote = db.appBadNote == 2 end
    if type(db.appGoodNote) ~= "boolean" then db.appGoodNote = db.appGoodNote == 1 end
    if db.appIlvlMax == 300 then db.appIlvlMax = ILVL_MAX end
    if db.appIlvlMin < ILVL_MIN then db.appIlvlMin = ILVL_MIN end
    if db.appScoreMax == SCORE_MAX then db.appScoreMax = APP_SCORE_MAX end

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
---------------------------------------------------------------------------
-- Raider.IO: keep its side panel to the right of ours
---------------------------------------------------------------------------
-- Raider.IO hangs its panel on a tiny 16x16 frame that is attached to the right edge of
-- the Group Finder window, which is where our panel goes. While one of our panels is
-- showing, that one frame (and nothing else) is attached to our panel instead.

local placingRaiderIO = false

-- the panel of ours that is showing, if any
local function ShownPanel()
    if panel and panel:IsShown() then return panel end
    if raidPanel and raidPanel:IsShown() then return raidPanel end
    if appPanel and appPanel:IsShown() then return appPanel end
    if appRaidPanel and appRaidPanel:IsShown() then return appRaidPanel end
end

local function PlaceRaiderIO()
    local anchor = _G.RaiderIO_ProfileTooltipAnchor
    local window = PVEFrame or LFGListFrame
    if not (anchor and anchor.SetPoint and window) then return end

    local target = ShownPanel()

    placingRaiderIO = true
    anchor:ClearAllPoints()
    if target then
        -- its panel starts at the anchor's right edge, which is 16 pixels wide
        anchor:SetPoint("TOPLEFT", target, "TOPRIGHT", 4 - 16, 0)
    else
        anchor:SetPoint("TOPLEFT", window, "TOPRIGHT", -16, 0)   -- where Raider.IO puts it
    end
    placingRaiderIO = false
end

local function InstallRaiderIOSupport()
    local function Update() pcall(PlaceRaiderIO) end

    for _, f in ipairs({ panel, raidPanel, appPanel, appRaidPanel }) do
        if f then
            f:HookScript("OnShow", Update)
            f:HookScript("OnHide", Update)
        end
    end
    LFGListFrame:HookScript("OnShow", function()
        Update()
        -- Raider.IO may build or reposition its frames a moment later
        C_Timer.After(0.5, Update)
        C_Timer.After(2, Update)
    end)

    -- Raider.IO moves the anchor again whenever any tooltip shows (hovering one of our
    -- buttons, for instance): put it back straight after it does
    local function HookAnchor()
        local anchor = _G.RaiderIO_ProfileTooltipAnchor
        if anchor and not anchor.BetterFiltersHooked then
            anchor.BetterFiltersHooked = true
            hooksecurefunc(anchor, "SetPoint", function(_, _, relativeTo)
                if placingRaiderIO then return end
                local target = ShownPanel()
                if target and relativeTo ~= target then
                    pcall(PlaceRaiderIO)
                end
            end)
        end
    end
    HookAnchor()
    C_Timer.After(2, HookAnchor)
    LFGListFrame:HookScript("OnShow", HookAnchor)

    local function HookTooltip()
        local tip = _G.RaiderIO_ProfileTooltip
        if tip and tip.HookScript and not tip.BetterFiltersHooked then
            tip.BetterFiltersHooked = true
            tip:HookScript("OnShow", Update)
        end
    end
    HookTooltip()
    C_Timer.After(2, HookTooltip)
    LFGListFrame:HookScript("OnShow", HookTooltip)
    Update()
end

---------------------------------------------------------------------------
-- Listing tooltips above Raider.IO's panel
---------------------------------------------------------------------------
-- The tooltip of a listing opens to the right of the Group Finder window, on top of the
-- panels we and Raider.IO put there. Raider.IO's panel was drawn over it, hiding part of
-- the text, so the tooltip is raised above that panel while a listing is hovered.

local function RaiseListingTooltip()
    local other = _G.RaiderIO_ProfileTooltip
    if not GameTooltip then return end

    -- put the tooltip right after the last panel on that side, so nothing can cover it
    local after
    if other and other.IsShown and other:IsShown() and other:GetRight() and usable(other:GetRight()) then
        after = other
    elseif panel and panel:IsShown() then
        after = panel
    elseif raidPanel and raidPanel:IsShown() then
        after = raidPanel
    elseif appPanel and appPanel:IsShown() then
        after = appPanel
    elseif appRaidPanel and appRaidPanel:IsShown() then
        after = appRaidPanel
    end
    if after and GameTooltip:IsShown() then
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint("TOPLEFT", after, "TOPRIGHT", 6, 0)
    end

    -- and keep it above Raider.IO's panel in case it still overlaps
    if other and other.GetFrameLevel then
        local strata, level = other:GetFrameStrata(), other:GetFrameLevel()
        if type(level) == "number" and strata then
            GameTooltip:SetFrameStrata(strata)
            GameTooltip:SetFrameLevel(level + 10)
        end
    end
end

local function InstallTooltipFix()
    if LFGListSearchEntry_OnEnter then
        hooksecurefunc("LFGListSearchEntry_OnEnter", function()
            pcall(RaiseListingTooltip)
        end)
    end
end

---------------------------------------------------------------------------
-- Skin: restyle the Dungeons & Raids window and fit our panels inside it
---------------------------------------------------------------------------
-- Everything here is visual only. Each piece is applied on its own and guarded, so a
-- name that does not exist in this game version is simply skipped.

do
local PANEL_W, EXTRA = 240, 240              -- our panels, and how much wider the window gets

-- The window's own art is remembered as it is hidden, so Player vs. Player and Mythic+
-- Dungeons (which are not ours to change) can have the game's window back.
local WS = { stripped = {}, skinned = false, saved = {}, wasIn = nil }

-- is the Dungeons & Raids tab the one showing?
function WS.InDungeons()
    local gf = _G.GroupFinderFrame
    return (gf and gf:IsVisible()) and true or false
end

-- the game's own anchors of a frame we move, kept so the other tabs can have them back
function WS.SaveNative(f)
    if not f or f.BFNative or not f.GetNumPoints then return end
    local pts = {}
    for i = 1, f:GetNumPoints() do
        local pt, rel, relPt, x, y = f:GetPoint(i)
        pts[i] = { pt, rel, relPt, x, y }
    end
    f.BFNative = pts
    WS.saved[#WS.saved + 1] = f
end

function WS.RestoreNative(f)
    local pts = f.BFNative
    if not pts or #pts == 0 then return end
    f:ClearAllPoints()
    for _, p in ipairs(pts) do
        local rel = p[2]
        -- the Premade Groups page of the PvP tab hangs on its own stub
        if rel == _G.LFGListPVEStub and _G.LFGListPVPStub then rel = _G.LFGListPVPStub end
        f:SetPoint(p[1], rel, p[3], p[4], p[5])
    end
end
function WS.Log(o)
    if WS.record and o and o.GetAlpha and o.BFOrigAlpha == nil then
        o.BFOrigAlpha = o:GetAlpha()
        o.BFOrigShown = o:IsShown()
        WS.record[#WS.record + 1] = o
    end
end

-- hide the art of a Blizzard frame without hiding the frame (its children stay)
local function Strip(f)
    if not f then return end
    if f.GetRegions then
        for _, r in ipairs({ f:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" and not r.BFOwn then
                WS.Log(r)
                r:SetAlpha(0)
                r:Hide()
            end
        end
    end
    for _, key in ipairs({ "NineSlice", "Bg", "BG", "Background", "Border", "TopTileStreaks", "shadows", "Shadows" }) do
        local o = f[key]
        if o and o.Hide then WS.Log(o); o:SetAlpha(0); o:Hide() end
    end
end

-- a flat 1px-bordered box behind a frame
local function FlatBox(f, bg, border, inset)
    if f.BFBox then return f.BFBox end
    inset = inset or 0
    local e = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    e:SetPoint("TOPLEFT", f, "TOPLEFT", -1 + inset, 1 - inset)
    e:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 1 - inset, -1 + inset)
    e.BFOwn = true
    e:SetColorTexture(unpack(border or THEME.border))
    local b = f:CreateTexture(nil, "BACKGROUND", nil, -7)
    b.BFOwn = true
    b:SetPoint("TOPLEFT", f, "TOPLEFT", inset, -inset)
    b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -inset, inset)
    b:SetColorTexture(unpack(bg or THEME.bg))
    f.BFBox = { edge = e, bg = b }
    return f.BFBox
end

-- a Blizzard text button -> flat button
local function SkinButton(btn)
    if not btn or btn.BFSkinned then return end
    btn.BFSkinned = true
    Strip(btn)
    for _, key in ipairs({ "Left", "Middle", "Right", "Center", "TopLeft", "TopRight", "BottomLeft", "BottomRight" }) do
        local o = btn[key]
        if o and o.SetAlpha then o:SetAlpha(0) end
    end
    for _, fn in ipairs({ "SetNormalTexture", "SetPushedTexture", "SetDisabledTexture", "SetHighlightTexture" }) do
        if btn[fn] then pcall(btn[fn], btn, "") end
    end
    FlatBox(btn, TOGGLE_COLORS.off.bg, TOGGLE_COLORS.off.border)
    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover.BFOwn = true
    hover:SetAllPoints()
    hover:SetColorTexture(1, 0.82, 0, 0.10)
end

local function SkinTab(tab, selected)
    if not tab then return end
    Strip(tab)
    for _, key in ipairs({ "Left", "Middle", "Right", "LeftActive", "MiddleActive", "RightActive", "LeftDisabled", "MiddleDisabled", "RightDisabled", "Center" }) do
        local o = tab[key]
        if o and o.SetAlpha then o:SetAlpha(0); o:Hide() end
    end
    local c = selected and TOGGLE_COLORS.sel or TOGGLE_COLORS.off
    local box = FlatBox(tab, c.bg, c.border, 2)
    box.bg:SetColorTexture(unpack(c.bg))
    box.edge:SetColorTexture(unpack(c.border))
    if not tab.BFHover then
        tab.BFHover = tab:CreateTexture(nil, "HIGHLIGHT")
        tab.BFHover.BFOwn = true
        tab.BFHover:SetPoint("TOPLEFT", 2, -2)
        tab.BFHover:SetPoint("BOTTOMRIGHT", -2, 2)
        tab.BFHover:SetColorTexture(1, 0.82, 0, 0.10)
    end
end

local function SkinTabs()
    for i = 1, 8 do
        local tab = _G["PVEFrameTab" .. i]
        if tab then
            -- the selected tab is the one the game has disabled
            local selected = tab.IsEnabled and not tab:IsEnabled()
            SkinTab(tab, selected)
        end
    end
end

-- The window's background: a frame behind everything else in the window. It also covers
-- the Dungeon Finder / Raid Finder / Premade Groups column, which sticks out to the left
-- of the window's own edge.
local function SkinWindowBackground()
    if not PVEFrame then return end
    local bg = PVEFrame.BFWindowBG
    if not bg then
        bg = CreateFrame("Frame", nil, PVEFrame)
        bg:SetFrameLevel(PVEFrame:GetFrameLevel())
        PVEFrame.BFWindowBG = bg
        FlatBox(bg, THEME.bg, THEME.border)
    end
    local out = 0
    local first = GroupFinderFrame and GroupFinderFrame.groupButton1
    local winLeft, btnLeft = PVEFrame:GetLeft(), first and first:GetLeft()
    if winLeft and btnLeft and btnLeft < winLeft then out = winLeft - btnLeft + 6 end
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", PVEFrame, "TOPLEFT", -out, 0)
    bg:SetPoint("BOTTOMRIGHT", PVEFrame, "BOTTOMRIGHT", 0, 0)
end

function WS.Core()
    if not PVEFrame then return end
    Strip(PVEFrame)
    for _, name in ipairs({ "PVEFrameBlueBG", "PVEFrameLeftInset", "PVEFrameBg", "PVEFrameTitleBg",
        "PVEFrameBottomBg", "PVEFrameTopBorder", "PVEFramePortrait", "PVEFrameShadows" }) do
        Strip(_G[name])
        local o = _G[name]
        WS.Log(o)
        if o and o.SetAlpha then o:SetAlpha(0) end
    end
    for _, key in ipairs({ "Inset", "PortraitContainer", "LeftInset" }) do Strip(PVEFrame[key]) end
    if PVEFrame.PortraitContainer then WS.Log(PVEFrame.PortraitContainer); PVEFrame.PortraitContainer:SetAlpha(0) end
    WS.record = nil

    -- (the background itself is a frame of its own: see SkinWindowBackground)

    -- title in the addon's gold
    local title = PVEFrame.TitleContainer and PVEFrame.TitleContainer.TitleText
    if title and title.SetTextColor then
        if not title.BFOrigColor then title.BFOrigColor = { title:GetTextColor() } end
        title:SetTextColor(unpack(THEME.gold))
    end

    -- close button -> a small flat "x"
    local close = PVEFrame.CloseButton or _G.PVEFrameCloseButton
    if close and not close.BFSkinned then
        close.BFSkinned = true
        -- the button keeps working but is invisible; a small "x" of ours is drawn over it
        close:SetAlpha(0)
        local xf = CreateFrame("Frame", nil, PVEFrame)
        xf:SetAllPoints(close)
        xf:SetFrameLevel((LFGListFrame and LFGListFrame:GetFrameLevel() or 1) + 60)
        xf.text = xf:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        xf.text:SetPoint("CENTER", 0, 1)
        xf.text:SetText("x")
        close.BFX = xf
    end

    -- keep the close button on top of our panel, which now sits under the window's corner
    local closeBtn = PVEFrame.CloseButton or _G.PVEFrameCloseButton
    if closeBtn and closeBtn.SetFrameLevel and LFGListFrame then
        pcall(closeBtn.SetFrameLevel, closeBtn, LFGListFrame:GetFrameLevel() + 50)
    end

    SkinWindowBackground()
    SkinTabs()
    WS.skinned = true
end

local function SkinWindow()
    WS.record = WS.stripped
    local ok, err = pcall(WS.Core)
    WS.record = nil
    if not ok then error(err, 0) end
end

-- Dungeons & Raids gets our look; the other tabs get the game's own window back
function WS.Set(on)
    if not PVEFrame or #WS.stripped == 0 then return end
    for _, o in ipairs(WS.stripped) do
        if on then
            o:SetAlpha(0)
            if o.GetObjectType and o:GetObjectType() == "Texture" then o:Hide() end
        else
            o:SetAlpha(o.BFOrigAlpha or 1)
            if o.BFOrigShown then o:Show() end
        end
    end
    if PVEFrame.BFWindowBG then PVEFrame.BFWindowBG:SetShown(on) end
    if _G.LFGListFrame and LFGListFrame.BFBack then LFGListFrame.BFBack:SetShown(on) end
    local close = PVEFrame.CloseButton or _G.PVEFrameCloseButton
    if close then
        close:SetAlpha(on and 0 or 1)
        if close.BFX then close.BFX:SetShown(on) end
    end
    local title = PVEFrame.TitleContainer and PVEFrame.TitleContainer.TitleText
    if title and title.BFOrigColor and not on then title:SetTextColor(unpack(title.BFOrigColor)) end
    if title and on then title:SetTextColor(unpack(THEME.gold)) end
    WS.skinned = on
end

-- the Premade Groups pages
function WS.PremadeCore()
    local f = LFGListFrame
    if not f then return end
    Strip(f)
    local back = f.BFBack
    if not back then
        back = CreateFrame("Frame", nil, f)
        back:SetAllPoints(f)
        back:SetFrameLevel(math.max(0, f:GetFrameLevel() - 1))
        f.BFBack = back
        FlatBox(back, { 0.062, 0.054, 0.047, 1 }, THEME.border)
    end

    for _, pageKey in ipairs({ "CategorySelection", "SearchPanel", "EntryCreation", "ApplicationViewer" }) do
        local page = f[pageKey]
        if page then
            Strip(page)
            for _, key in ipairs({ "Inset", "ResultsInset", "InfoBackground", "NineSlice" }) do Strip(page[key]) end
        end
    end

    -- text buttons
    local cs, sp, ec, av = f.CategorySelection, f.SearchPanel, f.EntryCreation, f.ApplicationViewer
    for _, b in ipairs({
        cs and cs.FindGroupButton, cs and cs.StartGroupButton,
        sp and sp.BackButton, sp and sp.BackToGroupButton, sp and sp.SignUpButton,
        ec and ec.ListGroupButton, ec and ec.CancelButton,
        av and av.BrowseGroupsButton, av and av.RemoveEntryButton, av and av.EditButton,
    }) do
        pcall(SkinButton, b)
    end

    -- search box
    if sp and sp.SearchBox and not sp.SearchBox.BFSkinned then
        sp.SearchBox.BFSkinned = true
        pcall(SkinEditBox, sp.SearchBox)
    end
end

local function SkinPremade()
    -- the Premade Groups page of the Player vs. Player tab is not ours to change
    if not WS.InDungeons() then return end
    WS.record = WS.stripped
    local ok, err = pcall(WS.PremadeCore)
    WS.record = nil
    if not ok then error(err, 0) end
end

-- The Dungeon Finder / Raid Finder / Premade Groups buttons: the game's own buttons are
-- laid out by the game (it puts them straight back when moved), so they are hidden and
-- three flat buttons of ours take their place in the title bar. Clicking one presses the
-- game's button.
local GROUP_BTN_W, GROUP_BTN_H = 102, 40
local groupTabs = {}
local GROUP_EDGE = 6      -- the buttons' distance from the window's left and top edges

local groupOrig = {}
local ReflowPages, PagesMoved, FitWindow, LayoutTabs, NarrowPage

local function UpdateGroupTabs()
    local gf = GroupFinderFrame
    -- our title-bar buttons belong to the Dungeons & Raids tab only
    local inTab = (gf and gf:IsVisible()) and true or false
    for _, tab in ipairs(groupTabs) do tab:SetShown(inTab) end
    if WS.skinned ~= inTab then pcall(WS.Set, inTab) end
    if WS.wasIn ~= inTab then
        WS.wasIn = inTab
        if not inTab then
            for _, f in ipairs(WS.saved) do pcall(WS.RestoreNative, f) end
        end
    end
    local title = PVEFrame and PVEFrame.TitleContainer and PVEFrame.TitleContainer.TitleText
    if title then title:SetAlpha(inTab and 0 or 1) end
    local selected
    -- the game moves its selection marker onto the chosen button
    if gf and gf.selection and gf.selection.GetPoint then
        local ok, _, rel = pcall(gf.selection.GetPoint, gf.selection, 1)
        if ok and rel then
            for i, o in ipairs(groupOrig) do
                if o == rel then selected = i end
            end
        end
    end
    if not selected then
        if _G.LFDParentFrame and LFDParentFrame:IsVisible() then selected = 1 end
        if _G.RaidFinderFrame and RaidFinderFrame:IsVisible() then selected = 2 end
        if _G.LFGListFrame and LFGListFrame:IsVisible() then selected = 3 end
    end
    for i, tab in ipairs(groupTabs) do
        if tab.refresh and not (tab.iconDone and tab.ringDone) then tab.refresh() end
        local c = (i == selected) and TOGGLE_COLORS.sel or TOGGLE_COLORS.off
        tab.edge:SetColorTexture(unpack(c.border))
        tab.bg:SetColorTexture(unpack(c.bg))
    end
end

-- text and the round icon / ring of one of the game's group buttons, wherever it keeps them
local function ButtonParts(orig)
    local name, icon, ring
    local gname = orig.GetName and orig:GetName()
    name = orig.name or orig.Name or orig.Text or (gname and _G[gname .. "Name"])
    icon = orig.icon or orig.Icon or (gname and _G[gname .. "Icon"])
    ring = orig.ring or orig.Ring or (gname and _G[gname .. "Ring"])
    if not (name and name.GetText) then
        name = nil
        for _, r in ipairs({ orig:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "FontString" and (r:GetText() or "") ~= "" then name = r break end
        end
    end
    if not (icon and icon.GetTexture) then
        icon, ring = nil, nil
        local textures = {}
        for _, r in ipairs({ orig:GetRegions() }) do
            if r.GetObjectType and r:GetObjectType() == "Texture" and (r:GetAtlas() or r:GetTexture()) then
                textures[#textures + 1] = r
            end
        end
        -- the icon is the one drawn smallest of the textures that are not backgrounds
        table.sort(textures, function(a, b) return (a:GetWidth() or 0) < (b:GetWidth() or 0) end)
        icon = textures[1]
        ring = textures[2]
    end
    return name, icon, ring
end

local GROUP_NAMES = {
    _G.LOOKING_FOR_DUNGEON or "Dungeon Finder",
    _G.RAID_FINDER or "Raid Finder",
    _G.LFGLIST_NAME or "Premade Groups",
}

local function BuildGroupTabs()
    local gf = GroupFinderFrame
    if not (gf and PVEFrame) or #groupTabs > 0 then return end

    local n = 0
    for i = 1, 3 do
        local orig = gf["groupButton" .. i]
        if orig then
            n = n + 1
            local tab = CreateFrame("Button", nil, PVEFrame)
            tab:SetSize(GROUP_BTN_W, GROUP_BTN_H)
            tab:SetPoint("TOPLEFT", PVEFrame, "TOPLEFT", GROUP_EDGE + (n - 1) * (GROUP_BTN_W + 3), -GROUP_EDGE)
            tab:SetFrameLevel(PVEFrame:GetFrameLevel() + 30)

            tab.edge = tab:CreateTexture(nil, "BACKGROUND", nil, -8)
            tab.edge:SetAllPoints()
            tab.bg = tab:CreateTexture(nil, "BACKGROUND", nil, -7)
            tab.bg:SetPoint("TOPLEFT", 1, -1)
            tab.bg:SetPoint("BOTTOMRIGHT", -1, 1)
            local hover = tab:CreateTexture(nil, "HIGHLIGHT")
            hover:SetAllPoints()
            hover:SetColorTexture(1, 0.82, 0, 0.10)

            -- the same round icon as the game's button, smaller
            tab.icon = tab:CreateTexture(nil, "ARTWORK")
            tab.icon:SetSize(22, 22)
            tab.icon:SetPoint("LEFT", 5, 0)
            tab.ring = tab:CreateTexture(nil, "OVERLAY")
            tab.ring:SetSize(30, 30)
            tab.ring:SetPoint("CENTER", tab.icon, "CENTER", 0, 0)
            local function Copy(from, to)
                if not (from and to) then return end
                local atlas = from.GetAtlas and from:GetAtlas()
                if atlas then
                    to:SetAtlas(atlas)
                else
                    to:SetTexture(from:GetTexture())
                    to:SetTexCoord(from:GetTexCoord())
                end
            end
            local nameFS, iconTex, ringTex = ButtonParts(orig)
            -- the game sets the icons after it builds the buttons: copy again until they exist
            tab.refresh = function()
                if iconTex and not tab.iconDone then
                    local has = (iconTex.GetAtlas and iconTex:GetAtlas()) or iconTex:GetTexture()
                    if has then
                        pcall(Copy, iconTex, tab.icon)
                        tab.iconDone = true
                    end
                end
                if ringTex and not tab.ringDone then
                    local has = (ringTex.GetAtlas and ringTex:GetAtlas()) or ringTex:GetTexture()
                    if has then
                        pcall(Copy, ringTex, tab.ring)
                        tab.ringDone = true
                    end
                end
            end
            tab.refresh()
            groupOrig[n] = orig

            tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            tab.text:SetPoint("LEFT", 38, 0)
            tab.text:SetWidth(GROUP_BTN_W - 42)
            tab.text:SetJustifyH("LEFT")
            tab.text:SetJustifyV("MIDDLE")
            tab.text:SetWordWrap(true)
            tab.text:SetMaxLines(2)
            local label = nameFS and nameFS:GetText()
            if not label or label == "" then label = GROUP_NAMES[i] end
            tab.text:SetText(label)

            tab:SetScript("OnClick", function()
                orig:Click()
                C_Timer.After(0, UpdateGroupTabs)
            end)
            groupTabs[n] = tab

            -- the game's button stays, invisible and out of the way
            orig:SetAlpha(0)
            orig:EnableMouse(false)
        end
    end
    if gf.selection then gf.selection:SetAlpha(0) end
    -- keep the highlight and the page layout right whatever the game does
    local acc = 0
    PVEFrame:HookScript("OnUpdate", function(_, elapsed)
        acc = acc + elapsed
        if acc < 0.15 then return end
        acc = 0
        UpdateGroupTabs()
        if FitWindow then pcall(FitWindow) end
        if LayoutTabs then pcall(LayoutTabs) end
        if PagesMoved and PagesMoved() then pcall(ReflowPages) end
    end)
    local title = PVEFrame.TitleContainer and PVEFrame.TitleContainer.TitleText
    if title then title:SetAlpha(0) end

    for _, page in ipairs({ _G.LFDParentFrame, _G.RaidFinderFrame, _G.LFGListPVEStub, _G.LFGListFrame }) do
        if page and page.HookScript then
            page:HookScript("OnShow", function() C_Timer.After(0, UpdateGroupTabs) end)
        end
    end
    if _G.GroupFinderFrame_SelectGroupButton then
        hooksecurefunc("GroupFinderFrame_SelectGroupButton", function() C_Timer.After(0, UpdateGroupTabs) end)
    end
    UpdateGroupTabs()
end

local function SkinGroupButtons()
    BuildGroupTabs()
    UpdateGroupTabs()
end

-- The pages take the room the left column used to have. The game anchors them to its own
-- frames (and sets those anchors again now and then), so each page is anchored to the
-- window itself and put back whenever the game moves it.
local extendedNow = false          -- is our panel making the window wider? (see FitWindow)
local pageAnchoring = false

local SEARCH_LIFT, BOTTOM_PAD = 30, 8
local SEARCH_PAD = 6     -- Back / Sign Up: the same distance from the left, right and bottom edges

-- The Dungeon Finder anchors its role buttons and its Type dropdown to the BOTTOM of its
-- page, so moving the page's top never moved them. They are placed here, 10 lower.
local LFD_LOWER = 10
local function LFDPieces()
    local q = _G.LFDQueueFrame
    if not q then return {} end
    return {
        { _G.LFDQueueFrameRoleButtonTank, 50, 334 - LFD_LOWER, q },
        { _G.LFDQueueFrameTypeDropdown, 131, 287 - LFD_LOWER, q },
    }
end

local function SearchButtons()
    local sp = _G.LFGListFrame and LFGListFrame.SearchPanel
    if not sp then return {} end
    return {
        { sp.BackButton, "BOTTOMLEFT", SEARCH_PAD, sp },
        { sp.SignUpButton, "BOTTOMRIGHT", -SEARCH_PAD, sp },
    }
end
local CATEGORY_LIFT = 34       -- the category list sits higher: it has its own space at the top

local function PageSpecs()
    local specs = {}
    local list = _G.LFGListFrame
    if list then
        specs[#specs + 1] = { list, 2, 8, -(8 + (extendedNow and EXTRA or 0)), -(GROUP_BTN_H + 6), PVEFrame }
        if list.CategorySelection then
            specs[#specs + 1] = { list.CategorySelection, 2, 0, 0, CATEGORY_LIFT, list }
        end
        -- the group list and the applicants: a little higher, and off the bottom edge
        if list.SearchPanel then
            specs[#specs + 1] = { list.SearchPanel, 2, 0, 0, SEARCH_LIFT, list, 0 }
        end
        if list.ApplicationViewer then
            specs[#specs + 1] = { list.ApplicationViewer, 2, 0, 0, SEARCH_LIFT, list, BOTTOM_PAD }
        end
        if list.EntryCreation then
            specs[#specs + 1] = { list.EntryCreation, 2, 0, 0, CATEGORY_LIFT, list }
        end
    end
    -- Dungeon Finder / Raid Finder keep their own width: centred in the window
    local cx = -(extendedNow and EXTRA / 2 or 0)
    if _G.LFDParentFrame then specs[#specs + 1] = { LFDParentFrame, 1, cx, nil, -25, PVEFrame } end
    -- the Raid Finder lays its top part out lower than the Dungeon Finder does
    if _G.RaidFinderFrame then specs[#specs + 1] = { RaidFinderFrame, 1, cx, nil, -10, PVEFrame } end
    return specs
end

local function Near(a, b) return math.abs((a or 0) - (b or 0)) < 0.5 end

-- did the game move any of the pages since we placed them?
function PagesMoved()
    if not PVEFrame or not WS.InDungeons() then return false end
    for _, sp in ipairs(PageSpecs()) do
        local page, rel0 = sp[1], sp[6]
        if page:GetNumPoints() ~= sp[2] then return true end
        local _, rel, _, x, y = page:GetPoint(1)
        if rel ~= rel0 or not Near(y, sp[5]) then return true end
        if sp[2] == 2 then
            local _, rel2, _, x2, y2 = page:GetPoint(2)
            if rel2 ~= rel0 or not Near(x, sp[3]) or not Near(x2, sp[4]) or not Near(y2, sp[7] or 0) then return true end
        elseif not Near(x, sp[3]) or not Near(page:GetHeight(), PVEFrame:GetHeight() + sp[5]) then
            return true
        end
    end
    for _, e in ipairs(LFDPieces()) do
        local f = e[1]
        if f then
            local _, rel, _, x, y = f:GetPoint(1)
            if rel ~= e[4] or not Near(x, e[2]) or not Near(y, e[3]) then return true end
        end
    end
    for _, e in ipairs(SearchButtons()) do
        local b = e[1]
        if b then
            local _, rel, _, x, y = b:GetPoint(1)
            if b:GetNumPoints() ~= 1 or rel ~= e[4] or not Near(x, e[3]) or not Near(y, SEARCH_PAD) then return true end
        end
    end
    return false
end

function ReflowPages()
    if pageAnchoring or not PVEFrame or not WS.InDungeons() then return end
    pageAnchoring = true
    local ok, err = pcall(function()
        for _, sp in ipairs(PageSpecs()) do
            local page, rel = sp[1], sp[6]
            WS.SaveNative(page)
            page:ClearAllPoints()
            if sp[2] == 2 then
                page:SetPoint("TOPLEFT", rel, "TOPLEFT", sp[3], sp[5])
                page:SetPoint("BOTTOMRIGHT", rel, "BOTTOMRIGHT", sp[4], sp[7] or 0)
            else
                page:SetPoint("TOP", rel, "TOP", sp[3], sp[5])
                -- ends at the bottom of the window, so the Find Group button sits at the
                -- same distance from the bottom as on the Premade Groups pages
                page:SetHeight(math.max(100, PVEFrame:GetHeight() + sp[5]))
            end
        end
        for _, e in ipairs(LFDPieces()) do
            if e[1] then
                WS.SaveNative(e[1])
                e[1]:ClearAllPoints()
                e[1]:SetPoint("BOTTOMLEFT", e[4], "BOTTOMLEFT", e[2], e[3])
            end
        end
        for _, e in ipairs(SearchButtons()) do
            if e[1] then
                WS.SaveNative(e[1])
                e[1]:ClearAllPoints()
                e[1]:SetPoint(e[2], e[4], e[2], e[3], SEARCH_PAD)
            end
        end
    end)
    pageAnchoring = false
    if not ok then print("|cff33ff99BF:|r page layout:", err) end
    pcall(LayoutTabs)
end

-- The tabs under the window (Dungeons & Raids / Player vs. Player / Mythic+ Dungeons):
-- sized to fit the window and centred under it, clear of our panel on the right.
local tabsAnchoring, tabsBaseY = false, nil

function LayoutTabs()
    if tabsAnchoring or not PVEFrame then return end
    -- the three buttons in the title bar: fixed size on the narrow pages, filling the
    -- window's width on the wide ones
    local gt = #groupTabs
    if gt > 0 then
        local baseW = (PVEFrame:GetWidth() or 0) - (extendedNow and EXTRA or 0)
        local gw = NarrowPage() and GROUP_BTN_W or math.floor((baseW - 2 * GROUP_EDGE - 3 * (gt - 1)) / gt)
        if groupTabs[1].curW ~= gw then
            for i, t in ipairs(groupTabs) do
                t.curW = gw
                t:SetWidth(gw)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", PVEFrame, "TOPLEFT", GROUP_EDGE + (i - 1) * (gw + 3), -GROUP_EDGE)
                t.text:SetWidth(gw - 42)
            end
        end
    end
    local tabs = {}
    for i = 1, 8 do
        local t = _G["PVEFrameTab" .. i]
        if t and t:IsShown() then tabs[#tabs + 1] = t end
    end
    if #tabs == 0 then return end
    if not tabsBaseY then
        local pt, _, relPt, _, y = tabs[1]:GetPoint(1)
        tabsBaseY = (pt == "TOPLEFT" and relPt == "BOTTOMLEFT" and y) or -2
    end
    local W = (PVEFrame:GetWidth() or 0) - (extendedNow and EXTRA or 0)
    local gap = 3
    local w = math.max(96, math.min(150, math.floor((W - 16 - gap * (#tabs - 1)) / #tabs)))
    local x0 = math.floor((W - (w * #tabs + gap * (#tabs - 1))) / 2)
    local fine = true
    for i, t in ipairs(tabs) do
        local _, rel, _, x = t:GetPoint(1)
        if t:GetNumPoints() ~= 1 or rel ~= PVEFrame or not Near(x, x0 + (i - 1) * (w + gap)) or not Near(t:GetWidth(), w) then
            fine = false
        end
    end
    if fine then return end
    tabsAnchoring = true
    for i, t in ipairs(tabs) do
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", PVEFrame, "BOTTOMLEFT", x0 + (i - 1) * (w + gap), tabsBaseY)
        t:SetWidth(w)
    end
    tabsAnchoring = false
end

local premadeHooked = false

local function ReflowPremade()
    ReflowPages()
    if premadeHooked then return end
    premadeHooked = true
    local list = _G.LFGListFrame
    local pages = { list and list.SearchPanel and list.SearchPanel.BackButton, list and list.SearchPanel and list.SearchPanel.SignUpButton, list, list and list.CategorySelection, list and list.EntryCreation, list and list.SearchPanel, list and list.ApplicationViewer, _G.LFDParentFrame, _G.RaidFinderFrame }
    for _, page in pairs(pages) do
        for _, fn in ipairs({ "SetPoint", "SetAllPoints", "ClearAllPoints" }) do
            hooksecurefunc(page, fn, function()
                if not pageAnchoring then C_Timer.After(0, function() pcall(ReflowPages) end) end
            end)
        end
    end
    -- put things right the moment a page shows or hides, not a moment later
    local function Refit()
        pcall(UpdateGroupTabs)
        if FitWindow then pcall(FitWindow) end
        pcall(ReflowPages)
    end
    local shown = { list, _G.LFDParentFrame, _G.RaidFinderFrame, _G.LFGListPVEStub, _G.GroupFinderFrame }
    if list then
        for _, k in ipairs({ "CategorySelection", "SearchPanel", "EntryCreation", "ApplicationViewer" }) do
            shown[#shown + 1] = list[k]
        end
    end
    for _, f in pairs(shown) do
        if f.HookScript then
            f:HookScript("OnShow", Refit)
            f:HookScript("OnHide", Refit)
        end
    end
end

local nativeW, nativeH, lastFit
local fitting = false
local NARROW_W = 354

local function AnyOurPanelShown()
    for _, p in ipairs({ panel, raidPanel, appPanel, appRaidPanel }) do
        if p and p:IsShown() then return true end
    end
    return false
end

-- the tallest of our panels that is showing
local function PanelHeight()
    local h = 0
    for _, p in ipairs({ panel, raidPanel, appPanel, appRaidPanel }) do
        if p and p:IsShown() then h = math.max(h, p:GetHeight() or 0) end
    end
    return h
end

-- The Premade Groups pages may or may not stretch with the window by themselves. Any
-- that did not get the extra height here, so the list shows more groups.
local function StretchPages(delta)
    local list = LFGListFrame
    if not list then return end
    -- LFGListFrame is anchored to LFGListPVEStub, which has a fixed height of its own:
    -- that is the one that has to grow (the pages are anchored to LFGListFrame)
    local frames = { _G.LFGListPVEStub, list, list.CategorySelection, list.SearchPanel, list.EntryCreation, list.ApplicationViewer }
    for _, f in ipairs(frames) do
        if f and not f.BFBaseHeight then f.BFBaseHeight = f:GetHeight() end
    end
    C_Timer.After(0, function()
        for _, f in ipairs(frames) do
            local base = f and f.BFBaseHeight
            if base and base > 0 then
                if delta > 0 then
                    if f:GetHeight() < base + delta - 1 then
                        f:SetHeight(base + delta)
                        f.BFStretched = true
                    end
                elseif f.BFStretched then
                    f:SetHeight(base)
                    f.BFStretched = nil
                end
            end
        end
    end)
end

-- make the window wide and tall enough for our panel while one is showing
-- the pages that only hold a short column (the finders, the category list) get a narrow
-- window; the group lists and forms get the full width
function NarrowPage()
    if _G.LFDParentFrame and LFDParentFrame:IsVisible() then return true end
    if _G.RaidFinderFrame and RaidFinderFrame:IsVisible() then return true end
    local l = _G.LFGListFrame
    if l and l:IsVisible() and l.CategorySelection and l.CategorySelection:IsShown() then return true end
    if l and l:IsVisible() and l.EntryCreation and l.EntryCreation:IsShown() then return true end
    if l and l:IsVisible() and l.ApplicationViewer and l.ApplicationViewer:IsShown() then return true end
    return false
end

function FitWindow()
    if not PVEFrame or fitting then return end
    -- Player vs. Player and Mythic+ Dungeons size the window themselves: hands off
    local inTab = WS.InDungeons()
    if not inTab then
        lastFit = nil
        extendedNow = false
        -- the game does not always resize the window when the tab changes: whatever size
        -- of ours is still on it goes back to the normal one
        if nativeW and WS.ourW and WS.ourH then
            fitting = true
            if Near(PVEFrame:GetHeight(), WS.ourH) then PVEFrame:SetHeight(nativeH) end
            if Near(PVEFrame:GetWidth(), WS.ourW) then PVEFrame:SetWidth(nativeW) end
            fitting = false
            WS.ourW, WS.ourH = nil, nil
        end
        return
    end
    if not nativeW then nativeW, nativeH = PVEFrame:GetWidth(), PVEFrame:GetHeight() end
    local w = NarrowPage() and NARROW_W or nativeW
    local h = nativeH
    local panelShown = inTab and AnyOurPanelShown()
    if panelShown then
        w = w + EXTRA
        h = math.max(nativeH, PanelHeight())
    end
    local key = w .. "x" .. h
    if key == lastFit and Near(PVEFrame:GetWidth(), w) and Near(PVEFrame:GetHeight(), h) then return end
    lastFit = key
    extendedNow = panelShown
    fitting = true
    PVEFrame:SetSize(w, h)
    fitting = false
    WS.ourW, WS.ourH = w, h
    pcall(ReflowPremade)
    StretchPages(h - nativeH)
end

-- our panel becomes the right-hand column of the window, flush with its top and edge
local function DockPanel(p)
    if not (p and PVEFrame) then return end
    p:ClearAllPoints()
    p:SetPoint("TOPRIGHT", PVEFrame, "TOPRIGHT", 0, 0)
    p:HookScript("OnShow", function() pcall(FitWindow) end)
    p:HookScript("OnHide", function() C_Timer.After(0, function() pcall(FitWindow) end) end)
    -- some panels change height (the note box folding away): follow it
    hooksecurefunc(p, "SetHeight", function() if p:IsShown() then pcall(FitWindow) end end)
    if p:IsShown() then pcall(FitWindow) end
end

function InstallSkin()
    if db.reskin == false then return end
    local steps = {
        { "window", SkinWindow },
        { "premade pages", SkinPremade },
        { "group buttons", SkinGroupButtons },
        { "premade room", ReflowPremade },
        { "dock panels", function()
            for _, p in ipairs({ panel, raidPanel, appPanel, appRaidPanel }) do DockPanel(p) end
        end },
    }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step[2])
        if not ok then print("|cff33ff99BF:|r skin step '" .. step[1] .. "' failed:", err) end
    end

    -- the game restyles tabs when they change; restyle them again straight after
    if PanelTemplates_SelectTab then
        hooksecurefunc("PanelTemplates_SelectTab", function(tab)
            if tab and tab.GetParent and tab:GetParent() == PVEFrame then pcall(SkinTab, tab, true) end
        end)
    end
    if PanelTemplates_DeselectTab then
        hooksecurefunc("PanelTemplates_DeselectTab", function(tab)
            if tab and tab.GetParent and tab:GetParent() == PVEFrame then pcall(SkinTab, tab, false) end
        end)
    end
    -- the game lays the bottom tabs out again every time the window opens: put them back
    -- the instant it does, so they never show in the game's places
    for i = 1, 8 do
        local tab = _G["PVEFrameTab" .. i]
        if tab then
            for _, fn in ipairs({ "SetPoint", "SetWidth", "Show" }) do
                hooksecurefunc(tab, fn, function()
                    if not tabsAnchoring then pcall(LayoutTabs) end
                end)
            end
        end
    end
    -- pages can be built the first time they are opened: run again when the window shows
    -- the window must be the right size the moment it opens, not a few frames later: fit
    -- it straight away, and again whenever the game sets its size
    local function Resync()
        lastFit = nil
        pcall(FitWindow)
        pcall(ReflowPages)
        pcall(LayoutTabs)
        pcall(UpdateGroupTabs)
    end
    for _, fn in ipairs({ "SetSize", "SetWidth", "SetHeight" }) do
        hooksecurefunc(PVEFrame, fn, function()
            if not fitting then
                lastFit = nil
                pcall(FitWindow)
            end
        end)
    end
    PVEFrame:HookScript("OnShow", function()
        pcall(SkinWindow)
        pcall(SkinPremade)
        pcall(SkinGroupButtons)
        pcall(ReflowPremade)
        Resync()
        -- the left column is only laid out once the window is up: measure again
        C_Timer.After(0, function() pcall(SkinWindowBackground) end)
    end)
    LFGListFrame:HookScript("OnShow", function()
        C_Timer.After(0, function() pcall(SkinPremade) end)
    end)
end

-- /bf geo : sizes and anchors of the Premade Groups pieces (for fixing the layout)
local function DumpGeo()
    local function Say(...) print("|cff33ff99BF geo:|r", ...) end
    local function Show(label, f)
        if not f then Say(label, "not found") return end
        Say(label, ("size %.0f x %.0f"):format(f:GetWidth() or 0, f:GetHeight() or 0), "points:", f:GetNumPoints())
        for i = 1, f:GetNumPoints() do
            local point, rel, relPoint, x, y = f:GetPoint(i)
            local relName = rel and (rel.GetName and rel:GetName()) or tostring(rel)
            Say("   ", point, "->", tostring(relName), relPoint, ("%.0f"):format(x or 0), ("%.0f"):format(y or 0))
        end
    end
    -- what is inside the Dungeon Finder / Raid Finder pages and where it really is
    local function Walk(f, depth)
        -- texts and pictures the frame keeps under a key (Name, ItemLevel, ...)
        for k, v in pairs(f) do
            if type(k) == "string" and type(v) == "table" and v.GetObjectType and v.GetPoint and not v.GetChildren then
                local ok, ot = pcall(v.GetObjectType, v)
                if ok and (ot == "FontString" or ot == "Texture") and v.GetNumPoints and v:GetNumPoints() > 0 then
                    local pt, rel, relPt, x, y = v:GetPoint(1)
                    local relName = rel and (rel.GetName and rel:GetName()) or tostring(rel)
                    local top = v.GetTop and v:GetTop()
                    local txt = ""
                    if ot == "FontString" then local okT, t = pcall(v.GetText, v); txt = okT and tostring(t) or "" end
                    Say(("  "):rep(depth), "." .. k, ot,
                        top and ("top %.0f"):format(PVEFrame:GetTop() - top) or "no top",
                        ("size %.0f x %.0f"):format(v:GetWidth() or 0, v:GetHeight() or 0),
                        tostring(pt), "->", tostring(relName), tostring(relPt), ("%.0f"):format(x or 0), ("%.0f"):format(y or 0), txt)
                end
            end
        end
        for _, child in ipairs({ f:GetChildren() }) do
            local top = child.GetTop and child:GetTop()
            local pt, rel, relPt, x, y = child:GetPoint(1)
            local relName = rel and (rel.GetName and rel:GetName()) or tostring(rel)
            local par = child:GetParent()
            Say(("  "):rep(depth), child:GetName() or ("<" .. child:GetObjectType() .. ">"),
                top and ("top %.0f"):format(PVEFrame:GetTop() - top) or "no top",
                ("size %.0f x %.0f"):format(child:GetWidth() or 0, child:GetHeight() or 0),
                tostring(pt), "->", tostring(relName), tostring(relPt), ("%.0f"):format(x or 0), ("%.0f"):format(y or 0),
                "parent", tostring(par and par.GetName and par:GetName()))
            if depth < 3 then Walk(child, depth + 1) end
        end
    end
    local viewer = _G.LFGListFrame and LFGListFrame.ApplicationViewer
    if viewer and viewer:IsVisible() and PVEFrame then
        Say("ApplicationViewer contents:")
        local seen = 0
        Walk(viewer, 1)
        local box = viewer.ScrollBox
        if box and box.ForEachFrame then
            box:ForEachFrame(function(row)
                seen = seen + 1
                if seen == 1 then
                    Say("first applicant row:", row:GetName() or "<row>", ("size %.0f x %.0f"):format(row:GetWidth() or 0, row:GetHeight() or 0))
                    Walk(row, 1)
                end
            end)
        end
    end
    local queue = _G.LFDParentFrame and _G.LFDParentFrame:IsVisible() and _G.LFDQueueFrame
    if queue and PVEFrame then
        Say("LFDQueueFrame contents:")
        Walk(queue, 1)
    end
    for _, name in ipairs({ "LFDQueueFrameRoleButtonTank", "LFDQueueFrameRoleButtonHealer", "LFDQueueFrameRoleButtonDPS", "LFDQueueFrameRoleButtonLeader", "LFDQueueFrameTypeDropdown", "LFDQueueFrameTypeDropDown" }) do
        local f = _G[name]
        if f and PVEFrame and f:IsVisible() then
            local pt, rel, relPt, x, y = f:GetPoint(1)
            local par = f:GetParent()
            Say(name, ("top %.0f"):format(PVEFrame:GetTop() - (f:GetTop() or 0)), tostring(pt), "->",
                tostring(rel and rel.GetName and rel:GetName()), tostring(relPt), ("%.0f"):format(x or 0), ("%.0f"):format(y or 0),
                "parent", tostring(par and par.GetName and par:GetName()))
        end
    end
    local list = LFGListFrame
    Show("GroupFinderFrame", GroupFinderFrame)
    Show("LFGListPVEStub", _G.LFGListPVEStub)
    Show("LFDParentFrame", _G.LFDParentFrame)
    Show("RaidFinderFrame", _G.RaidFinderFrame)
    Show("groupButton1", GroupFinderFrame and GroupFinderFrame.groupButton1)
    Show("PVEFrame", PVEFrame)
    Show("LFGListFrame", list)
    if list then
        local sp = list.SearchPanel
        Show("SearchPanel", sp)
        if sp then
            Show("ScrollBox", sp.ScrollBox)
            Show("ResultsInset", sp.ResultsInset)
            Show("BackButton", sp.BackButton)
            Show("SignUpButton", sp.SignUpButton)
        end
        Show("CategorySelection", list.CategorySelection)
        Show("EntryCreation", list.EntryCreation)
        Show("ApplicationViewer", list.ApplicationViewer)
    end
end

-- /bf frames : names of what is inside the window (for fixing the skin after a patch)
function DumpFrames(which)
    if which == "geo" then return DumpGeo() end
    local function Say(...) print("|cff33ff99BF frames:|r", ...) end
    local function List(label, f)
        if not f then Say(label, "not found") return end
        Say(label, f:GetObjectType(), "children:", f:GetNumChildren(), "regions:", f:GetNumRegions())
        local keys = {}
        for k, v in pairs(f) do
            if type(k) == "string" and type(v) == "table" and v.GetObjectType then
                keys[#keys + 1] = k .. "=" .. v:GetObjectType()
            end
        end
        table.sort(keys)
        if #keys > 0 then Say("  keys:", table.concat(keys, ", ")) end
    end
    List("PVEFrame", PVEFrame)
    List("GroupFinderFrame", GroupFinderFrame)
    List("LFGListFrame", LFGListFrame)
    if LFGListFrame then
        for _, k in ipairs({ "CategorySelection", "SearchPanel", "EntryCreation", "ApplicationViewer" }) do
            List("LFGListFrame." .. k, LFGListFrame[k])
        end
    end
    for i = 1, 4 do
        local t = _G["PVEFrameTab" .. i]
        if t then Say("PVEFrameTab" .. i, tostring(t:GetText()), "enabled:", tostring(t:IsEnabled())) end
    end
end
end   -- Skin

local function TryInit()
    if initialized or not db then return end
    if not (LFGListFrame and LFGListFrame.SearchPanel and LFGListSearchPanel_UpdateResultList) then
        return
    end
    initialized = true

    -- each part is set up on its own, so a problem in one cannot stop the others
    local steps = {
        { "hooks", InstallHooks },
        { "note hooks", InstallNoteHooks },
        { "spec icons", InstallSpecHooks },
        { "dungeon panel", BuildPanel },
        { "raid panel", BuildRaidPanel },
        { "applicant panels", BuildApplicantPanels },
        { "Raider.IO support", InstallRaiderIOSupport },
        { "tooltip fix", InstallTooltipFix },
        { "skin", InstallSkin },
    }
    for _, step in ipairs(steps) do
        local ok, err = pcall(step[2])
        if not ok then
            print("|cff33ff99BF:|r couldn't set up " .. step[1] .. ":", err)
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("CHALLENGE_MODE_MAPS_UPDATE")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_ROLES_ASSIGNED")
frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
frame:RegisterEvent("BAG_UPDATE_DELAYED")
frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then InitDB() end
        TryInit()
    elseif event == "PLAYER_LOGIN" then
        TryInit()
        pcall(_G.BetterFiltersBuildMinimap)
        if C_MythicPlus and C_MythicPlus.RequestMapInfo then
            C_MythicPlus.RequestMapInfo()
        end
    elseif event == "CHALLENGE_MODE_MAPS_UPDATE" then
        BuildDungeonButtons()
        pcall(UpdateKeyButton)
    elseif event == "BAG_UPDATE_DELAYED" then
        pcall(UpdateKeyButton)
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- after logging in or zooming: just remember who is already in the group
        C_Timer.After(3, function() pcall(CheckGroupNotes, true) end)
    else
        if event == "GROUP_ROSTER_UPDATE" then
            pcall(CheckGroupNotes, false)
        end
        if db and db.appFit and appPanel and appPanel:IsShown() then
            pcall(RefreshApplicants)
        end
        -- party or spec changed: re-check "Fit my party"
        if db and db.partyFit then RefreshList() end
    end
end)


---------------------------------------------------------------------------
-- /bf prog : what raid progress data this game and Raider.IO can give us (diagnostic)
---------------------------------------------------------------------------
function _G.BetterFiltersDumpProgress(msg)
    local function Say(...) print("|cff33ff99BF prog:|r", ...) end

    -- 1. the game's own comparison functions
    for _, name in ipairs({ "SetAchievementComparisonUnit", "ClearAchievementComparisonUnit", "GetAchievementComparisonInfo",
        "GetComparisonStatistic", "GetStatistic", "GetStatisticsCategoryList", "GetCategoryNumAchievements", "GetAchievementInfo" }) do
        Say("function", name, type(_G[name]))
    end
    Say("C_AchievementInfo", type(_G.C_AchievementInfo), "C_ChallengeMode", type(_G.C_ChallengeMode))

    -- 2. raid achievements (newest first)
    if _G.GetCategoryList and _G.GetCategoryNumAchievements and _G.GetAchievementInfo then
        local found = {}
        for _, cat in ipairs(GetCategoryList()) do
            for i = 1, (GetCategoryNumAchievements(cat) or 0) do
                local id, name, _, completed = GetAchievementInfo(cat, i)
                if id and name and (name:find("Ahead of the Curve", 1, true) or name:find("Cutting Edge", 1, true)) then
                    found[#found + 1] = { id = id, name = name, done = completed, cat = cat }
                end
            end
        end
        table.sort(found, function(a, b) return a.id > b.id end)
        Say("AotC / Cutting Edge achievements found:", #found, "(newest 14)")
        for i = 1, math.min(14, #found) do
            local f = found[i]
            Say("  ", f.id, f.name, f.done and "(you have it)" or "(you do not)")
        end
    end

    -- 3. statistics categories that look like the current raids
    if _G.GetStatisticsCategoryList then
        local names = {}
        for _, cat in ipairs(GetStatisticsCategoryList()) do
            local name = GetCategoryInfo and GetCategoryInfo(cat)
            if name then names[#names + 1] = tostring(cat) .. "=" .. name end
        end
        Say("statistics categories:", #names)
        Say(table.concat(names, ", "))
    end

    -- 4. Raider.IO: its profile for you, or for a name given after the command
    local rio = _G.RaiderIO
    Say("RaiderIO addon", rio and "loaded" or "not loaded")
    if rio then
        local keys = {}
        for k, v in pairs(rio) do keys[#keys + 1] = tostring(k) .. "=" .. type(v) end
        table.sort(keys)
        Say("RaiderIO keys:", table.concat(keys, ", "))
        local unit = "player"
        local name, realm = (msg or ""):match("^%s*%S+%s+([^%s%-]+)%-?(%S*)")
        local profile
        if rio.GetProfile then
            local ok, res
            if name then ok, res = pcall(rio.GetProfile, name, realm ~= "" and realm or GetRealmName())
            else ok, res = pcall(rio.GetProfile, unit) end
            profile = ok and res or nil
            if not ok then Say("GetProfile error:", res) end
        end
        if not profile then Say("no profile returned") return end
        local lines, maxLines = 0, 70
        local function Dump(t, indent, depth)
            if type(t) ~= "table" or depth > 4 then return end
            local keys2 = {}
            for k in pairs(t) do keys2[#keys2 + 1] = k end
            table.sort(keys2, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys2) do
                if lines >= maxLines then return end
                local v = t[k]
                if type(v) == "table" then
                    lines = lines + 1
                    Say(indent .. tostring(k) .. " = {")
                    Dump(v, indent .. "  ", depth + 1)
                else
                    lines = lines + 1
                    Say(indent .. tostring(k) .. " = " .. tostring(v))
                end
            end
        end
        -- the Encounter Journal: which functions exist and what they return for the first raid
        local first = profile.raidProfile and profile.raidProfile.mainProgress and profile.raidProfile.mainProgress[1]
        local raidInfo = first and first.raid
        Say("EncounterJournal globals:", "EJ_GetInstanceForMap", type(_G.EJ_GetInstanceForMap),
            "EJ_GetEncounterInfoByIndex", type(_G.EJ_GetEncounterInfoByIndex),
            "C_EncounterJournal", type(_G.C_EncounterJournal))
        if C_EncounterJournal then
            local keys = {}
            for k, v in pairs(C_EncounterJournal) do
                if tostring(k):find("Instance") or tostring(k):find("Encounter") then keys[#keys + 1] = tostring(k) end
            end
            table.sort(keys)
            Say("C_EncounterJournal:", table.concat(keys, ", "))
        end
        if raidInfo then
            Say("first raid", raidInfo.name, "mapId", tostring(raidInfo.mapId), "id", tostring(raidInfo.id))
            if type(raidInfo.dungeon) == "table" then
                local dk = {}
                for k, v in pairs(raidInfo.dungeon) do dk[#dk + 1] = tostring(k) .. "=" .. type(v) end
                table.sort(dk)
                Say("raid.dungeon has:", table.concat(dk, ", "))
            end
            for _, fn in ipairs({ { "C_EncounterJournal.GetInstanceForGameMap", C_EncounterJournal and C_EncounterJournal.GetInstanceForGameMap or false },
                { "EJ_GetInstanceForMap", _G.EJ_GetInstanceForMap or false } }) do
                if fn[2] then
                    local ok, res = pcall(fn[2], raidInfo.mapId)
                    Say(fn[1], "->", ok and tostring(res) or ("error: " .. tostring(res)))
                    if ok and type(res) == "number" and res > 0 then
                        for _, enc in ipairs({ { "C_EncounterJournal.GetEncounterInfoByIndex", C_EncounterJournal and C_EncounterJournal.GetEncounterInfoByIndex or false },
                            { "EJ_GetEncounterInfoByIndex", _G.EJ_GetEncounterInfoByIndex or false } }) do
                            if enc[2] then
                                local ok2, a, b2 = pcall(enc[2], 1, res)
                                Say("  ", enc[1], "(1) ->", ok2 and (type(a) == "table" and ("table name=" .. tostring(a.name)) or tostring(a)) or ("error: " .. tostring(a)))
                            end
                        end
                    end
                end
            end
        end
        Say("profile keys:")
        local raid = profile.raidProfile
        if raid then Say("raidProfile found"); Dump(raid, "  ", 1) else
            local top = {}
            for k, v in pairs(profile) do top[#top + 1] = tostring(k) .. "=" .. type(v) end
            Say("no raidProfile; profile has:", table.concat(top, ", "))
        end
    end
end


-- /bf bosses [mapId] : every way of getting boss names, and what each gives (diagnostic)
function _G.BetterFiltersDumpBosses(msg)
    local function Say(...) print("|cff33ff99BF bosses:|r", ...) end
    local map = tonumber((msg or ""):match("%d+")) or 3004
    Say("map", map)
    local ids = {}
    if C_EncounterJournal and C_EncounterJournal.GetInstanceForGameMap then
        local ok, id = pcall(C_EncounterJournal.GetInstanceForGameMap, map)
        Say("C_EncounterJournal.GetInstanceForGameMap ->", ok and tostring(id) or ("error " .. tostring(id)))
        if ok and type(id) == "number" and id > 0 then ids[#ids + 1] = id end
    end
    if EJ_GetInstanceForMap then
        local ok, id = pcall(EJ_GetInstanceForMap, map)
        Say("EJ_GetInstanceForMap ->", ok and tostring(id) or ("error " .. tostring(id)))
        if ok and type(id) == "number" and id > 0 then ids[#ids + 1] = id end
    end
    for _, id in ipairs(ids) do
        if EJ_GetInstanceInfo then
            Say("EJ_GetInstanceInfo(" .. id .. ") ->", tostring((select(1, pcall(EJ_GetInstanceInfo, id)) and select(2, pcall(EJ_GetInstanceInfo, id)))))
        end
        if EJ_GetEncounterInfoByIndex then
            local ok, a, b, c = pcall(EJ_GetEncounterInfoByIndex, 1, id)
            Say("EJ_GetEncounterInfoByIndex(1, " .. id .. ") ->", ok and (tostring(a) .. " | " .. tostring(c)) or ("error " .. tostring(a)))
        end
        if EJ_SelectInstance and EJ_GetEncounterInfoByIndex then
            local okS = pcall(EJ_SelectInstance, id)
            local ok, a = pcall(EJ_GetEncounterInfoByIndex, 1)
            Say("after EJ_SelectInstance(" .. id .. ") selected=" .. tostring(okS) .. ", EJ_GetEncounterInfoByIndex(1) ->", ok and tostring(a) or ("error " .. tostring(a)))
        end
    end
    if C_EncounterJournal and C_EncounterJournal.GetEncountersOnMap then
        local ok, list = pcall(C_EncounterJournal.GetEncountersOnMap, map)
        Say("GetEncountersOnMap(" .. map .. ") ->", ok and (type(list) == "table" and (#list .. " entries") or tostring(list)) or ("error " .. tostring(list)))
    end
    -- by name: walk the journal's raids
    if EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex then
        local found = 0
        for t = 1, EJ_GetNumTiers() do
            pcall(EJ_SelectTier, t)
            for i = 1, 30 do
                local ok, id, name = pcall(EJ_GetInstanceByIndex, i, true)
                if not ok or not id then break end
                if type(name) == "string" and (name:find("Venomous", 1, true) or name:find("Dreamrift", 1, true)) then
                    Say("journal raid", id, name, "tier", t)
                    found = found + 1
                end
            end
        end
        Say("journal raids found by name:", found)
    end
end


---------------------------------------------------------------------------
-- Minimap button: opens the Group Overview. Drag it to move it around the minimap.
---------------------------------------------------------------------------
function _G.BetterFiltersBuildMinimap()
    if _G.BetterFiltersMinimapButton or not Minimap or not db then return end
    local b = CreateFrame("Button", "BetterFiltersMinimapButton", Minimap)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = b:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture("Interface\\AddOns\\BetterFilters\\icon")
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    local function Place()
        local a = math.rad(db.minimapAngle or 215)
        local r = (Minimap:GetWidth() / 2) + 5
        local x, y = math.cos(a) * r, math.sin(a) * r
        local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
        if shape ~= "ROUND" then     -- square minimaps: follow the edge
            x = math.max(-r, math.min(x * 1.4142, r))
            y = math.max(-r, math.min(y * 1.4142, r))
        end
        b:ClearAllPoints()
        b:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    b:SetScript("OnDragStart", function(self)
        self.dragging = true
        GameTooltip:Hide()
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            if mx and px then
                db.minimapAngle = math.deg(math.atan2(py / scale - my, px / scale - mx))
                Place()
            end
        end)
    end)
    b:SetScript("OnDragStop", function(self)
        self.dragging = nil
        self:SetScript("OnUpdate", nil)
    end)
    b:SetScript("OnClick", function()
        if ToggleOverview then
            local ok, err = pcall(ToggleOverview)
            if not ok then print("|cff33ff99BF:|r overview error:", err) end
        end
    end)
    b:SetScript("OnEnter", function(self)
        if self.dragging then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Better Filters")
        GameTooltip:AddLine("Left-click: Group Overview", 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)

    Place()
    b:SetShown(not db.minimapHidden)
    _G.BetterFiltersMinimapButton = b
end