-- Chillzone: рамки ролей вокруг портрета цели и фокуса у игроков гильдий «Чиллзон»:
-- Король — золотая с крыльями, Лорд — серебряная с крыльями, Капитан — серебряная.
-- Кому какая рамка, решает Data.RoleOf. Портировано из Olympus Borders.lua (Rig, Install,
-- Refresh) в урезанном виде: только цель и фокус, только атласы самой игры. Рамки группы,
-- свой портрет, неймплейты и метки в чате не трогаются.
--
-- Как (по Olympus): игра рисует рамку элиты и редкого текстурой контейнера
-- TargetFrame.TargetFrameContainer в TargetFrameMixin:CheckClassification. Её мы не трогаем:
-- на тот же контейнер, на подслой выше, кладём свои скрытые текстуры, по одной на роль, с
-- атласами и смещениями игры. Они создаются, получают точку и размер один раз и только вне
-- боя; дальше — только Show/Hide (для текстуры они не защищены, смена цели в бою безопасна).
-- Кадры игры получают от нас только CreateTexture и пост-хук hooksecurefunc на
-- CheckClassification (их функция остаётся защищённой); после неё рамка показывается заново.
--
-- Нет контейнера или атласа (C_Texture.GetAtlasInfo его не знает: Classic Era, Anniversary) —
-- ничего не рисуется, а без единой текстуры и хук не ставится. В режиме геймпада кадры игры
-- не трогаем: вход с геймпадом — ни текстур, ни хуков; переключение на геймпад прячет рамки
-- (хуки остаются до /reload, но ничего не показывают), обратно — рамки возвращаются.
local ADDON, ns = ...

local L = ns.L
local U = ns.Util

local Borders = {}
ns.Borders = Borders

-- Атласы и смещения — как в Olympus Borders.lua (TIERS): x, y от правого верхнего угла
-- контейнера, где игра ставит свою рамку босса и редкого (GetBossPortraitFrameData).
Borders.ROLES = { "king", "lord", "captain" }
Borders.TIERS = {
	king = { atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged", x = 11, y = -4 },
	lord = { atlas = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Rare-Silver-Winged", x = 8, y = -7 },
	captain = { atlas = "ui-hud-unitframe-target-portraiton-boss-rare-silver", x = 0, y = 1 },
}

local UNITS = { "target", "focus" }
local rigs = {} -- [unit] = { tex = { [роль] = текстура }, shown = роль или nil }
local installed, waiting = false, false

-- Значения, скрытые игрой от аддонов (secret values), считаются отсутствующими.
local function Secret(...)
	if type(issecretvalue) ~= "function" then return false end
	for i = 1, select("#", ...) do
		if issecretvalue((select(i, ...))) then return true end
	end
	return false
end

local function InCombat()
	return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function Gamepad()
	return ns.ChatPane.Gamepad()
end

local function AtlasExists(atlas)
	local get = type(C_Texture) == "table" and C_Texture.GetAtlasInfo
	if type(get) ~= "function" then return false end
	local ok, info = pcall(get, atlas)
	return ok and info ~= nil and not Secret(info)
end

local function FrameOf(unit)
	if unit == "target" then return TargetFrame end
	return FocusFrame
end

-- Что игра говорит об игроке на месте unit (для Data.RoleOf) или nil: не игрок, нет гильдии,
-- нет имени или значение скрыто.
function Borders.Facts(unit)
	if type(UnitExists) ~= "function" or type(UnitIsPlayer) ~= "function" then return nil end
	local exists, player = UnitExists(unit), UnitIsPlayer(unit)
	if Secret(exists, player) or not exists or not player then return nil end
	local faction = UnitFactionGroup(unit)
	local name, realm = UnitFullName(unit)
	local guild, rankName, rankIndex = GetGuildInfo(unit)
	if Secret(faction, name, realm, guild, rankName, rankIndex) then return nil end
	if type(name) ~= "string" or name == "" or type(guild) ~= "string" or guild == "" then return nil end
	local full = U.ParsePlayer(name, realm, ns.realm)
	return { guild = guild, rank = rankIndex, name = full, faction = faction, realm = full:match("%-([^%-]+)$") }
end

-- Роль игрока на месте unit: "king", "lord", "captain" или nil.
function Borders.RoleOf(unit)
	return ns.Data.RoleOf(Borders.Facts(unit))
end

function Borders.Enabled()
	return not (ns.db and ns.db.settings.borders == false)
end

-- Включены, мышь и клавиатура, я в гильдии «Чиллзон».
local function Active()
	return ns.me ~= nil and Borders.Enabled() and not Gamepad() and ns.IsMember()
end

-- Текстуры одного портрета: по одной на роль, чей атлас знает клиент; скрытые, ARTWORK 3
-- (рамка игры — ARTWORK 2), в размер атласа, в точке, где игра ставит свою. nil — ни одной.
local function MakeRig(container)
	local rig, any = { tex = {} }, false
	for _, role in ipairs(Borders.ROLES) do
		local t = Borders.TIERS[role]
		if AtlasExists(t.atlas) then
			local tex = container:CreateTexture(nil, "ARTWORK", nil, 3)
			tex:Hide()
			tex:SetAtlas(t.atlas, true)
			tex:SetPoint("TOPRIGHT", container, "TOPRIGHT", t.x, t.y)
			rig.tex[role], any = tex, true
		end
	end
	return any and rig or nil
end

-- Один раз, с мышью и клавиатурой и вне боя (точки и размер текстуры на кадре игры в бою не
-- наши): текстуры, затем хуки. В бою — после него (PLAYER_REGEN_ENABLED).
function Borders.Install()
	if installed then return true end
	if Gamepad() then return false end
	if InCombat() then
		waiting = true
		return false
	end
	waiting, installed = false, true
	for _, unit in ipairs(UNITS) do
		local frame = FrameOf(unit)
		local container = type(frame) == "table" and frame.TargetFrameContainer or nil
		local rig = type(container) == "table" and type(container.CreateTexture) == "function" and MakeRig(container) or nil
		if rig then
			rigs[unit] = rig
			if type(frame.CheckClassification) == "function" and type(hooksecurefunc) == "function" then
				local where = "borders " .. unit
				hooksecurefunc(frame, "CheckClassification", function() ns.SafeCall(where, Borders.Refresh, unit) end)
			end
		end
	end
	ns.Log("рамки ролей: %s", next(rigs) and "поставлены" or "нет кадров или атласов игры")
	return true
end

-- Только Show/Hide своих текстур: можно и в бою.
local function Show(rig, role)
	if rig.shown == role then return end
	if rig.shown then rig.tex[rig.shown]:Hide() end
	rig.shown = nil
	local tex = role and rig.tex[role]
	if tex then
		tex:Show()
		rig.shown = role
	end
end

-- Рамка на портрете unit заново. Выключены, геймпад, я не в «Чиллзон» — спрятана.
function Borders.Refresh(unit)
	if not Active() then
		if rigs[unit] then Show(rigs[unit], nil) end
		return
	end
	if not installed and not Borders.Install() then return end
	local rig = rigs[unit]
	if rig then Show(rig, Borders.RoleOf(unit)) end
end

function Borders.RefreshAll()
	for _, unit in ipairs(UNITS) do Borders.Refresh(unit) end
end

-- Какая рамка сейчас показана на портрете unit (роль или nil).
function Borders.Shown(unit)
	return rigs[unit] and rigs[unit].shown or nil
end

function Borders.Installed()
	return installed
end

function Borders.SetEnabled(on)
	ns.db.settings.borders = on and true or false
	ns.Print(on and L.BORDERS_ON or L.BORDERS_OFF)
	if on and Gamepad() then ns.Print(L.BORDERS_GAMEPAD) end
	Borders.RefreshAll()
	ns.Fire("SETTINGS")
end

---------------------------------------------------------------------------
-- События
---------------------------------------------------------------------------
ns.On("LOGIN", Borders.RefreshAll)
-- Перепись (капитаны чужих гильдий), свой ростер (офицеры своей), смена своей гильдии.
ns.On("DATA", Borders.RefreshAll)
ns.On("ROSTER", Borders.RefreshAll)
ns.On("GUILD_CHANGED", Borders.RefreshAll)
ns.RegisterEvent("PLAYER_TARGET_CHANGED", function() Borders.Refresh("target") end)
-- Фокуса нет не во всех клиентах: событие регистрируется, где оно есть.
pcall(ns.RegisterEvent, "PLAYER_FOCUS_CHANGED", function() Borders.Refresh("focus") end)
-- Гильдия или имя цели дошли до клиента позже смены цели.
local function UnitChanged(unit)
	if unit == "target" or unit == "focus" then Borders.Refresh(unit) end
end
ns.RegisterEvent("PLAYER_GUILD_UPDATE", UnitChanged)
ns.RegisterEvent("UNIT_NAME_UPDATE", UnitChanged)
ns.RegisterEvent("PLAYER_REGEN_ENABLED", function()
	if waiting then Borders.RefreshAll() end
end)

-- Смена мыши и геймпада. Игра ставит новый стиль до события; работа — на следующем кадре,
-- не посреди перехода игры. К геймпаду — рамки прячутся, обратно — ставятся (вне боя) и
-- показываются.
local switchQueued = false
local function Switched()
	switchQueued = false
	if Gamepad() then
		for _, rig in pairs(rigs) do Show(rig, nil) end
	else
		Borders.RefreshAll()
	end
end
pcall(ns.RegisterEvent, "INPUT_DEVICE_INTERFACE_TRANSITION", function()
	if switchQueued then return end
	switchQueued = true
	ns.After(0, "borders gamepad", Switched)
end)

ns.Command("borders", function(arg)
	arg = U.Fold(U.Trim(arg))
	if arg == "on" or arg == "вкл" then
		Borders.SetEnabled(true)
	elseif arg == "off" or arg == "выкл" then
		Borders.SetEnabled(false)
	else
		Borders.SetEnabled(not Borders.Enabled())
	end
end, L.HELP_BORDERS)

-- /chillzone status: состояние и что игра говорит о цели (видно, приходит ли rankIndex).
local ROLE_NAME = { king = "ROLE_KING", lord = "ROLE_LORD", captain = "ROLE_CAPTAIN" }
ns.Status(function()
	local state
	if not Borders.Enabled() then
		state = L.BORDERS_STATUS_OFF
	elseif Gamepad() then
		state = L.BORDERS_STATUS_GAMEPAD
	elseif not installed then
		state = waiting and L.BORDERS_STATUS_COMBAT or L.BORDERS_STATUS_WAIT
	elseif not next(rigs) then
		state = L.BORDERS_STATUS_NONE
	else
		state = L.BORDERS_STATUS_ON
	end
	local line = L.BORDERS_STATUS:format(state)
	local f = Borders.Facts("target")
	if f then
		local role = ns.Data.RoleOf(f)
		line = line .. L.BORDERS_STATUS_TARGET:format(f.guild, f.rank ~= nil and tostring(f.rank) or "?",
			role and L[ROLE_NAME[role]] or L.BORDERS_NO_ROLE)
	end
	return line
end)
