-- Chillzone: карточка игрока — боковая рамка у окна Chillzone: имя цветом класса, что о нём
-- известно (Views.PersonCard) и кнопки «Шёпот», «Пригласить», «Кто». Открывается щелчком по имени
-- в карточке гильдии «Переписи», в списке людей чата и в «Королевстве», а также командой
-- /chillzone profile Имя Фамилия; работает с любой вкладки. Образец — карточка человека Olympus
-- (PlayerProfile.lua, UI.lua).
--
-- Чего карточка не делает (taint, см. шапку ChatPane.lua):
-- - не трогает поле ввода и окна чата игры: шёпот — только в своё поле окна (ChatPane.WhisperTo),
--   не ChatFrame_SendTell;
-- - приглашение (C_PartyInfo.InviteUnit) и «Кто» (/who) — только из щелчка по кнопке, синхронно,
--   без таймеров; «Кто» в режиме геймпада скрыт;
-- - открытие карточки ничего не спрашивает у игры и не шлёт в сеть.
local ADDON, ns = ...

local L = ns.L
local U = ns.Util
local Views = ns.Views

local PersonCard = {}
ns.PersonCard = PersonCard

local CARD_W, PAD, TOP, LINE_GAP, BTN_H, BTN_GAP = 270, 12, 30, 3, 22, 6
local TABS_W = 36 -- вкладки-значки на правом краю окна (UI.lua)
local frame, title, name
local lines, buttons = {}, {}
local person -- строка, по которой щёлкнули: из неё карточка собирается заново
local model -- Views.PersonCard(person)

local function Height(fs, fallback)
	local h = fs:GetStringHeight()
	return (type(h) == "number" and h > 0) and h or fallback
end

local function Line(i)
	local fs = lines[i]
	if fs then return fs end
	fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetJustifyH("LEFT")
	fs:SetWidth(CARD_W - 2 * PAD)
	lines[i] = fs
	return fs
end

-- Рядом с окном справа (за вкладками), а если справа не помещается — слева.
local function Place()
	local host = ns.UI.frame
	frame:ClearAllPoints()
	local right = host:GetRight()
	local screen = UIParent and UIParent:GetRight()
	if type(right) == "number" and type(screen) == "number" and right + TABS_W + CARD_W > screen then
		frame:SetPoint("TOPRIGHT", host, "TOPLEFT", -2, 0)
	else
		frame:SetPoint("TOPLEFT", host, "TOPRIGHT", TABS_W, 0)
	end
end

local function Render()
	local c = model
	if not c then return end
	name:SetText(c.title)
	local y = TOP
	name:ClearAllPoints()
	name:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
	y = y + Height(name, 18) + 6
	for i, e in ipairs(c.lines) do
		local fs = Line(i)
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -y)
		fs:SetText(e.text)
		fs:SetTextColor(e.r, e.g, e.b)
		fs:Show()
		y = y + Height(fs, 12) + LINE_GAP
	end
	for i = #c.lines + 1, #lines do lines[i]:Hide() end
	-- Не в игре — только «Кто»; себе — тоже; в режиме геймпада «Кто» нет.
	local shown = {}
	buttons.whisper:SetShown(c.whisper)
	buttons.invite:SetShown(c.invite)
	buttons.who:SetShown(not ns.ChatPane.Gamepad())
	for _, key in ipairs({ "whisper", "invite", "who" }) do
		if buttons[key]:IsShown() then shown[#shown + 1] = buttons[key] end
	end
	y = y + 8
	local width = #shown > 0 and math.floor((CARD_W - 2 * PAD - (#shown - 1) * BTN_GAP) / #shown) or 0
	for i, b in ipairs(shown) do
		b:SetWidth(width)
		b:ClearAllPoints()
		b:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (width + BTN_GAP), -y)
	end
	if #shown > 0 then y = y + BTN_H end
	frame:SetHeight(y + PAD)
end

---------------------------------------------------------------------------
-- Кнопки: всё — прямо в обработчике щелчка, без таймеров.
---------------------------------------------------------------------------
function PersonCard.Whisper()
	local tell = model and model.whisper and model.tell
	if not tell then return false end
	ns.UI.Toggle("chat")
	ns.ChatPane.WhisperTo(tell)
	return true
end

function PersonCard.Invite()
	local tell = model and model.invite and model.tell
	if not tell then return false end
	local party = C_PartyInfo
	if type(party) ~= "table" or type(party.InviteUnit) ~= "function" then
		ns.Print(L.PERSON_NO_INVITE)
		return false
	end
	party.InviteUnit(U.TellName(tell))
	return true
end

function PersonCard.Who()
	local tell = model and model.tell
	if not tell or ns.ChatPane.Gamepad() then return false end
	return ns.Who.SendPlain(('n-"%s"'):format((tell:gsub('["%c]', ""))))
end

local function Button(key, text, tip, fn)
	local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	b:SetHeight(BTN_H)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("person " .. key, fn) end)
	b:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(text, 1, 0.82, 0)
		GameTooltip:AddLine(tip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	buttons[key] = b
	return b
end

local function Build()
	local host = ns.UI.frame
	local ok, f = pcall(CreateFrame, "Frame", "ChillzonePersonCard", host, "BasicFrameTemplateWithInset")
	if not ok or not f then
		f = CreateFrame("Frame", "ChillzonePersonCard", host)
		local bg = f:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0.05, 0.05, 0.05, 0.92)
	end
	frame = f
	f:SetSize(CARD_W, 160)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetFrameLevel((host:GetFrameLevel() or 1) + 10)
	-- Крестик закрывает только карточку и без HideUIPanel (та в бою не работает).
	local close = f.CloseButton
	if close then close:SetScript("OnClick", function() PersonCard.Hide() end) end
	title = f.TitleText or (f.TitleContainer and f.TitleContainer.TitleText)
	if not title then
		title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		title:SetPoint("TOP", 0, -5)
	end
	title:SetText(L.PERSON_TITLE)
	name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	name:SetJustifyH("LEFT")
	name:SetWidth(CARD_W - 2 * PAD)
	Button("whisper", L.PERSON_WHISPER, L.PERSON_WHISPER_TIP, PersonCard.Whisper)
	Button("invite", L.PERSON_INVITE, L.PERSON_INVITE_TIP, PersonCard.Invite)
	Button("who", L.PERSON_WHO, L.PERSON_WHO_TIP, PersonCard.Who)
	-- Окно перетащили к краю экрана — карточка переходит на другую сторону.
	host:HookScript("OnDragStop", function() if f:IsShown() then Place() end end)
	f:Hide()
	PersonCard.frames = { frame = f, name = name, lines = lines, buttons = buttons }
end

---------------------------------------------------------------------------
-- Показ
---------------------------------------------------------------------------
-- Открыть карточку человека p ({ name, ... } — строка списка или одно имя). Окно открывается,
-- если закрыто; вкладка остаётся та же.
function PersonCard.Open(p)
	if type(p) ~= "table" or not U.Key(p.name) then return false end
	if not ns.IsMember() then
		ns.Print(L.PERSON_NOT_MEMBER)
		return false
	end
	if not ns.UI.Current() then ns.UI.Toggle() end
	if not ns.UI.frame then return false end
	if not frame then Build() end
	person = p
	model = Views.PersonCard(p)
	if not model then return false end
	Render()
	Place()
	frame:Show()
	return true
end

function PersonCard.Hide()
	person, model = nil, nil
	if frame then frame:Hide() end
end

function PersonCard.Shown()
	return frame ~= nil and frame:IsShown() and model or nil
end

-- Новые отчёты, ростер и строки чата меняют то, что известно: открытая карточка пересобирается.
local function Refresh()
	if not (frame and frame:IsShown() and person) then return end
	model = Views.PersonCard(person)
	Render()
end
ns.On("DATA", Refresh)
ns.On("ROSTER", Refresh)
ns.On("CHAT", Refresh)
ns.On("GUILD_CHANGED", function()
	if ns.IsMember() then Refresh() else PersonCard.Hide() end
end)

ns.Command("profile", function(arg)
	local who = U.Trim(arg)
	if who == "" then
		ns.Print(L.PERSON_USAGE)
		return
	end
	PersonCard.Open({ name = who })
end, L.HELP_PROFILE)
