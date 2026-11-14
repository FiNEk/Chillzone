-- Chillzone: вкладка «Группы». Слева доска объявлений объединения, справа — своё: роли,
-- форма объявления, размещённое объявление и заявки к нему. Строки готовит Views.lua,
-- логика — в Groups.lua.
--
-- Название объявления — свободный текст. Список занятий игры (Groups.Catalog) — только
-- подсказка: кнопка «Из списка» подставляет название в поле, и его можно править. Список
-- с поиском по названию встаёт на место формы, а не поверх неё.
--
-- Штатные выпадающие списки и popup игры не используются (taint): подсказка названий — свой
-- список, поля ввода — свои EditBox. Приглашение в группу вызывается только из щелчка.
--
-- Ширины заданы под исходное окно (вставка 804×340). Растянутое окно (Layout) отдаёт лишнюю ширину
-- доске, а правая панель той же ширины стоит у правого края и растёт вниз: длиннее список заявок.
local ADDON, ns = ...

local L = ns.L
local Codec = ns.Codec
local Views = ns.Views
local Groups = ns.Groups

local Pane = { frames = {} }
ns.GroupsPane = Pane

local LIST_W = 468 -- доска; справа от неё полоса прокрутки
local SIDE_X, SIDE_W = 512, 282
local HEADER_H, ROW_H = 22, 38
local APPLICANT_H = 36
local ACTION_W, INFO_W = 96, 112
local BASE_W, BASE_H, SIDE_V = 804, 340, 16 -- вставка исходного окна; панель ниже её верха и выше низа
local listW, sideX = LIST_W, SIDE_X -- доска и правая панель под ширину вставки (Layout)

-- Ширина названия и строки под ним в строке доски: справа сведения и кнопка.
local function TextW() return listW - 6 - ACTION_W - INFO_W - 16 end

local pane, list, listChild, empty, side, divider
local idle, form, own, picker
local rows, filters, applicantRows, pickerRows = {}, {}, {}, {}
local filter -- вид мест или nil — все
local editing -- "G" или "P", пока открыта форма
local picking = false -- открыт список занятий игры: он показан вместо формы
local draft -- то, что в форме не лежит в полях ввода: { mode, edit, kind, cap, roles }

---------------------------------------------------------------------------
-- Детали интерфейса
---------------------------------------------------------------------------
local function FS(parent, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

local function Label(parent, x, y, text, font)
	local fs = FS(parent, font)
	fs:SetPoint("TOPLEFT", x, -y)
	fs:SetWidth(SIDE_W - x)
	if text then fs:SetText(text) end
	return fs
end

local function Tip(owner, fn)
	owner.tip = fn
	owner:SetScript("OnEnter", function(self)
		if not self.tip then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		ns.SafeCall("groups tooltip", self.tip, GameTooltip)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function TextTip(owner, title, text)
	Tip(owner, function(tt)
		tt:AddLine(title, 1, 0.82, 0)
		if text then tt:AddLine(text, 1, 1, 1, true) end
	end)
end

local function Button(parent, text, width, where, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function(self) ns.SafeCall("groups: " .. where, fn, self) end)
	return b
end

-- Ширина надписи; запасной расчёт — для клиента, который её не сообщает.
local function TextWidth(fs, text)
	local w = fs:GetStringWidth()
	if type(w) == "number" and w > 0 then return w end
	return select(2, text:gsub("[^\128-\191]", "")) * 7
end

-- Плоская кнопка-переключатель: фильтры, виды мест, роли, число мест.
local function Chip(parent, text, where, fn)
	local b = CreateFrame("Button", nil, parent)
	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.06)
	b.on = b:CreateTexture(nil, "BORDER")
	b.on:SetAllPoints()
	b.on:SetColorTexture(1, 0.82, 0, 0.25)
	b.on:Hide()
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.08)
	b.label = FS(b, "GameFontHighlightSmall", "CENTER")
	b.label:SetPoint("CENTER")
	b.label:SetText(text)
	b.w = math.floor(TextWidth(b.label, text) + 14)
	b:SetSize(b.w, 20)
	b:SetScript("OnClick", function(self) ns.SafeCall("groups: " .. where, fn, self) end)
	return b
end

local function Mark(chip, on)
	chip.on:SetShown(on and true or false)
	if on then chip.label:SetTextColor(1, 0.82, 0) else chip.label:SetTextColor(1, 1, 1) end
end

-- Кнопки в ряд от x, y; возвращает x после последней.
local function PlaceRow(parent, chips, x, y, gap)
	for _, chip in ipairs(chips) do
		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
		x = x + chip.w + (gap or 4)
	end
	return x
end

local function Input(parent, width, maxBytes)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetAutoFocus(false)
	box:SetFontObject("ChatFontNormal")
	box:SetTextInsets(6, 6, 0, 0)
	box:SetSize(width, 22)
	box:SetMaxBytes(maxBytes + 1)
	local bg = box:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.55)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	return box
end

-- Значок роли, «-», число, «+». get() — текущее число, set(n) — новое.
local function Stepper(parent, role, get, set)
	local s = CreateFrame("Frame", nil, parent)
	s:SetSize(88, 22)
	s.w = 88
	local icon = s:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("LEFT", 0, 0)
	icon:SetTexture(Views.ROLE_ICON[role])
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local function Step(by)
		return function()
			set(math.max(0, math.min(Codec.GROUP_CAP, (get() or 0) + by)))
			s.value:SetText(tostring(get() or 0))
		end
	end
	local minus = Button(s, "-", 22, "less " .. role, Step(-1))
	minus:SetPoint("LEFT", icon, "RIGHT", 3, 0)
	s.value = FS(s, "GameFontHighlight", "CENTER")
	s.value:SetPoint("LEFT", minus, "RIGHT", 0, 0)
	s.value:SetWidth(22)
	local plus = Button(s, "+", 22, "more " .. role, Step(1))
	plus:SetPoint("LEFT", s.value, "RIGHT", 0, 0)
	s:EnableMouse(true)
	TextTip(s, L.GROUPS_STEP_TIP:format(L["GROUPS_ROLE_" .. role:upper() .. "_CAP"]))
	function s.Render() s.value:SetText(tostring(get() or 0)) end
	s.minus, s.plus = minus, plus
	return s
end

-- Три переключателя «Мои роли»: одни и те же сохранённые роли в двух местах панели.
local function RoleChips(parent)
	local chips = {}
	for _, role in ipairs(Groups.ROLES) do
		local text = Views.RoleIcon(role, 14) .. " " .. L["GROUPS_ROLE_" .. role:upper() .. "_CAP"]
		local chip = Chip(parent, text, "role " .. role, function()
			Groups.SetRole(role, Groups.MyRoles()[role] == 0)
		end)
		chip.w = chip.w + 4
		chip:SetSize(chip.w, 22)
		chip.role = role
		chips[#chips + 1] = chip
	end
	return chips
end

local function MarkRoles(chips)
	local mine = Groups.MyRoles()
	for _, chip in ipairs(chips) do Mark(chip, mine[chip.role] > 0) end
end

-- Шёпот в поле чата игры (в режиме геймпада — в окне Chillzone), см. ChatPane.Whisper.
local function Whisper(name)
	ns.ChatPane.Whisper(name)
end

local function Say(why, arg)
	ns.Print("%s", Views.GroupWhy(why, arg))
end

---------------------------------------------------------------------------
-- Доска
---------------------------------------------------------------------------
local function Act(it)
	if it.action == "apply" then
		local ok, why, arg = Groups.Apply(it.key, Groups.MyRoles(), "")
		if not ok then Say(why, arg) end
	elseif it.action == "withdraw" then
		Groups.Withdraw(it.key)
	elseif it.action == "invite" then
		Groups.InvitePlayer(it.key)
	end
end

local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, listChild)
	r:SetWidth(listW)
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:SetColorTexture(1, 1, 1, 0.03)
	r.mine = r:CreateTexture(nil, "BORDER")
	r.mine:SetAllPoints()
	r.mine:SetColorTexture(1, 0.82, 0, 0.1)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.07)
	r.header = FS(r, "GameFontNormal")
	r.header:SetPoint("LEFT", 4, -2)
	r.button = Button(r, "", ACTION_W - 4, "row", function() if r.it then Act(r.it) end end)
	r.button:SetHeight(20)
	r.button:SetPoint("RIGHT", -4, 0)
	r.status = FS(r, "GameFontHighlightSmall", "CENTER")
	r.status:SetPoint("RIGHT", -4, 0)
	r.status:SetWidth(ACTION_W - 4)
	r.right = FS(r, "GameFontHighlightSmall", "RIGHT")
	r.right:SetPoint("TOPRIGHT", -(ACTION_W + 8), -6)
	r.right:SetWidth(INFO_W)
	r.detail = FS(r, "GameFontDisableSmall", "RIGHT")
	r.detail:SetPoint("BOTTOMRIGHT", -(ACTION_W + 8), 6)
	r.detail:SetWidth(INFO_W)
	local textWidth = TextW()
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 6, -5)
	r.name:SetWidth(textWidth)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 6, 6)
	r.sub:SetWidth(textWidth)
	for _, fs in ipairs({ r.name, r.sub, r.right, r.detail, r.status }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self)
		local it = self.it
		if it and not it.own then ns.SafeCall("groups: whisper", Whisper, it.e.name) end
	end)
	Tip(r, nil)
	rows[i] = r
	return r
end

local function RenderList()
	for key, chip in pairs(filters) do Mark(chip, (key == "all" and filter == nil) or key == filter) end
	local items, total = Views.GroupRows(filter)
	local y = 0
	for i, it in ipairs(items) do
		local r = Row(i)
		local header = it.header ~= nil
		r.it = not header and it or nil
		r.tip = it.tip
		r:SetHeight(header and HEADER_H or ROW_H)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y)
		y = y + (header and HEADER_H or ROW_H) + 2
		r.header:SetText(header and it.header or "")
		r.bg:SetShown(not header)
		r.hl:SetAlpha(header and 0 or 1)
		r.mine:SetShown(it.own == true)
		r.name:SetText(header and "" or it.name)
		r.sub:SetText(header and "" or it.sub)
		r.right:SetText(header and "" or it.right)
		local action = not header and it.action ~= nil
		r.button:SetShown(action)
		if action then r.button:SetText(it.actionText) end
		r.status:SetText((header or action) and "" or (it.status or ""))
		r.detail:SetText(header and "" or (action and it.status or it.detail) or "")
		r:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	listChild:SetHeight(math.max(y, 10))
	empty:SetShown(#items == 0)
	empty:SetText(total > 0 and L.GROUPS_EMPTY_FILTER:format(total) or L.GROUPS_EMPTY)
end

local function BuildList()
	local chips = {}
	local function Filter(key, kind, text)
		local chip = Chip(pane, text, "filter", function()
			filter = kind
			if list then list:SetVerticalScroll(0) end
			Pane.Render()
		end)
		filters[key] = chip
		chips[#chips + 1] = chip
	end
	Filter("all", nil, L.GROUPS_FILTER_ALL)
	for _, kind in ipairs(Groups.KINDS) do Filter(kind, kind, L["GROUPS_KIND_" .. kind]) end
	PlaceRow(pane, chips, 8, 8)

	list = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	list:SetPoint("TOPLEFT", 8, -34)
	list:SetPoint("BOTTOMLEFT", 8, 8)
	list:SetWidth(LIST_W)
	listChild = CreateFrame("Frame", nil, list)
	listChild:SetSize(LIST_W, 10)
	list:SetScrollChild(listChild)
	empty = FS(listChild, "GameFontDisable")
	empty:SetPoint("TOPLEFT", 6, -8)
	empty:SetWidth(LIST_W - 12)
	empty:Hide()

	divider = pane:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.08)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", SIDE_X - 8, -10)
	divider:SetPoint("BOTTOMLEFT", SIDE_X - 8, 10)
end

---------------------------------------------------------------------------
-- Справа: ничего не размещено
---------------------------------------------------------------------------
local function DefaultNeed()
	local need, mine = { t = 1, h = 1, d = 3 }, Groups.MyRoles()
	local picked, count = nil, 0
	for _, role in ipairs(Groups.ROLES) do
		if mine[role] > 0 then picked, count = role, count + 1 end
	end
	-- Одна своя роль — её место уже занято; при нескольких неизвестно, кем пойдёт автор.
	if count == 1 then need[picked] = need[picked] - 1 end
	return need
end

-- Список занятий закрывается, на его место возвращается форма: поля и draft не трогаем.
local function ClosePicker()
	picking = false
	if picker then
		picker.search:ClearFocus()
		picker:Hide()
	end
end

local function CloseForm()
	editing, draft = nil, nil
	ClosePicker()
	if form then
		form.name:ClearFocus()
		form.note:ClearFocus()
		form.min:ClearFocus()
	end
end

local function OpenForm(mode)
	ClosePicker()
	local mine = Groups.Mine()
	local edit = mine ~= nil and mine.mode == mode
	draft = {
		mode = mode, edit = edit,
		kind = edit and mine.kind or "D",
		cap = edit and mine.cap > 0 and mine.cap or 5,
		roles = edit and { t = mine.roles.t, h = mine.roles.h, d = mine.roles.d } or DefaultNeed(),
	}
	form.name:SetText(edit and mine.title or "")
	form.note:SetText(edit and mine.note or "")
	form.min:SetText(edit and mine.min > 0 and tostring(mine.min) or "")
	form.announce:SetChecked(Groups.Announcing())
	editing = mode
	Pane.Render()
end

local function BuildIdle()
	idle = CreateFrame("Frame", nil, side)
	idle:SetAllPoints(side)
	Label(idle, 0, 4, L.GROUPS_MY_ROLES, "GameFontNormal")
	idle.roles = RoleChips(idle)
	PlaceRow(idle, idle.roles, 0, 26, 6)
	local group = Button(idle, L.GROUPS_NEW_GROUP, SIDE_W, "new group", function() OpenForm("G") end)
	group:SetPoint("TOPLEFT", 0, -62)
	local player = Button(idle, L.GROUPS_NEW_PLAYER, SIDE_W, "new player", function() OpenForm("P") end)
	player:SetPoint("TOPLEFT", 0, -90)
	local about = Label(idle, 0, 126, L.GROUPS_IDLE_HINT, "GameFontDisableSmall")
	about:SetWidth(SIDE_W)
	idle.group, idle.player = group, player
end

---------------------------------------------------------------------------
-- Справа: форма объявления
---------------------------------------------------------------------------
local function PickerRow(i)
	local r = pickerRows[i]
	if r then return r end
	r = CreateFrame("Button", nil, picker.child)
	r:SetSize(SIDE_W - 26, 18)
	r:SetPoint("TOPLEFT", picker.child, "TOPLEFT", 0, -(i - 1) * 19)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.08)
	r.right = FS(r, "GameFontDisableSmall", "RIGHT")
	r.right:SetPoint("RIGHT", -4, 0)
	r.name = FS(r, "GameFontHighlightSmall")
	r.name:SetPoint("LEFT", 4, 0)
	r.name:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
	if r.name.SetWordWrap then r.name:SetWordWrap(false) end
	r:SetScript("OnClick", function(self)
		local a = self.activity
		if not a or not draft then return end
		ns.SafeCall("groups: pick", function()
			form.name:SetText(a.name)
			draft.kind = a.kind
			if draft.mode == "G" then
				if a.cap >= 2 and a.cap <= Codec.GROUP_CAP then draft.cap = a.cap end
				form.min:SetText(a.min > 1 and tostring(a.min) or "")
			end
			ClosePicker()
			Pane.Render()
		end)
	end)
	pickerRows[i] = r
	return r
end

-- Строки списка по запросу из поля поиска (строки готовит Views.GroupPicks). Запрос и
-- прокрутку не сбрасывает: зовётся и при перерисовке вкладки, пока игрок ищет.
local function RenderPicker()
	local query = picker.search:GetText() or ""
	local items = Views.GroupPicks(query)
	for i, it in ipairs(items) do
		local r = PickerRow(i)
		r.activity = it.activity
		-- Заголовок раздела не щёлкается: подсветка только у занятий.
		r.hl:SetAlpha(it.header and 0 or 1)
		r.name:SetText(it.header or it.name)
		r.right:SetText(it.right or "")
		r:Show()
	end
	for i = #items + 1, #pickerRows do pickerRows[i]:Hide() end
	picker.child:SetHeight(math.max(#items * 19, 10))
	picker.none:SetShown(#items == 0)
	picker.hint:SetShown(query == "")
end

-- «Из списка»: список встаёт на место формы с пустым поиском, прокруткой в начале и
-- фокусом в поле поиска — можно сразу печатать. Щелчок по занятию подставляет название.
local function OpenPicker()
	if not draft or not Groups.Catalog() then return end
	picker.search:SetText("")
	picker.scroll:SetVerticalScroll(0)
	picking = true
	Pane.Render()
	picker.search:SetFocus()
end

local function BuildPicker()
	picker = CreateFrame("Frame", nil, side)
	picker:SetAllPoints(side)
	Label(picker, 0, 4, L.GROUPS_PICK_TITLE, "GameFontNormal")
	picker.search = Input(picker, SIDE_W, 60)
	picker.search:SetPoint("TOPLEFT", 0, -24)
	-- Подсказка лежит на самом поле, иначе её закроет его подложка.
	picker.hint = FS(picker.search, "GameFontDisableSmall")
	picker.hint:SetPoint("LEFT", 6, 0)
	picker.hint:SetText(L.GROUPS_PICK_SEARCH)
	picker.search:SetScript("OnTextChanged", function()
		ns.SafeCall("groups: picker search", function()
			if not picking then return end
			picker.scroll:SetVerticalScroll(0)
			RenderPicker()
		end)
	end)
	picker.scroll = CreateFrame("ScrollFrame", nil, picker, "UIPanelScrollFrameTemplate")
	picker.scroll:SetPoint("TOPLEFT", 0, -52)
	picker.scroll:SetPoint("BOTTOMRIGHT", -24, 30)
	picker.child = CreateFrame("Frame", nil, picker.scroll)
	picker.child:SetSize(SIDE_W - 26, 10)
	picker.scroll:SetScrollChild(picker.child)
	-- Уже панели: справа стоит полоса прокрутки, она видна и при пустом списке.
	picker.none = Label(picker, 2, 56, L.GROUPS_PICK_NONE, "GameFontDisableSmall")
	picker.none:SetWidth(SIDE_W - 30)
	picker.none:Hide()
	picker.close = Button(picker, L.GROUPS_CLOSE, 100, "picker close", function()
		ClosePicker()
		Pane.Render()
	end)
	picker.close:SetPoint("BOTTOMRIGHT", 0, 2)
	picker:Hide()
end

local function Submit()
	if not draft then return end
	local announce = form.announce:GetChecked() and true or false
	if not draft.edit then Groups.SetAnnouncing(announce) end
	local ok, why, arg = Groups.Raise({
		mode = draft.mode, kind = draft.kind, title = form.name:GetText(), note = form.note:GetText(),
		roles = draft.mode == "P" and Groups.MyRoles() or draft.roles,
		cap = draft.cap, min = tonumber(form.min:GetText()) or 0,
		announce = announce and not draft.edit,
	})
	if not ok then
		Say(why, arg)
		return
	end
	CloseForm()
	Pane.Render()
end

local function BuildForm()
	form = CreateFrame("Frame", nil, side)
	form:SetAllPoints(side)
	form.title = Label(form, 0, 4, nil, "GameFontNormal")

	form.kinds = {}
	for _, kind in ipairs(Groups.KINDS) do
		local chip = Chip(form, L["GROUPS_KIND_ONE_" .. kind], "kind", function()
			if draft then draft.kind = kind end
			Pane.Render()
		end)
		chip.kind = kind
		form.kinds[#form.kinds + 1] = chip
	end
	PlaceRow(form, form.kinds, 0, 26, 3)

	form.nameLabel = Label(form, 0, 54, nil, "GameFontDisableSmall")
	form.name = Input(form, SIDE_W, Codec.GROUP_TITLE)
	form.name:SetPoint("TOPLEFT", 0, -68)
	form.pick = Button(form, L.GROUPS_PICK, 84, "picker", OpenPicker)
	form.pick:SetPoint("TOPRIGHT", form, "TOPRIGHT", 0, -68)
	TextTip(form.pick, L.GROUPS_PICK, L.GROUPS_PICK_TIP)

	-- Только у группы: кого ищем, сколько мест, уровень.
	form.needLabel = Label(form, 0, 98, L.GROUPS_FIELD_NEED, "GameFontDisableSmall")
	form.steppers = {}
	for _, role in ipairs(Groups.ROLES) do
		form.steppers[#form.steppers + 1] = Stepper(form, role,
			function() return draft and draft.roles[role] or 0 end,
			function(n) if draft then draft.roles[role] = n end end)
	end
	PlaceRow(form, form.steppers, 0, 112, 9)
	form.capLabel = Label(form, 0, 142, L.GROUPS_FIELD_CAP, "GameFontDisableSmall")
	form.caps = {}
	for _, cap in ipairs(Groups.CAPS) do
		local chip = Chip(form, tostring(cap), "cap", function()
			if draft then draft.cap = cap end
			Pane.Render()
		end)
		chip.w = math.max(chip.w, 30)
		chip:SetSize(chip.w, 20)
		chip.cap = cap
		form.caps[#form.caps + 1] = chip
	end
	PlaceRow(form, form.caps, 0, 156, 3)
	form.minLabel = Label(form, 196, 142, L.GROUPS_FIELD_MIN, "GameFontDisableSmall")
	form.min = Input(form, 44, 2)
	form.min:SetPoint("TOPLEFT", 196, -155)
	if form.min.SetNumeric then form.min:SetNumeric(true) end
	if form.min.SetMaxLetters then form.min:SetMaxLetters(2) end

	-- Только у «ищу группу»: свои роли.
	form.rolesLabel = Label(form, 0, 98, L.GROUPS_MY_ROLES, "GameFontDisableSmall")
	form.roles = RoleChips(form)
	PlaceRow(form, form.roles, 0, 112, 6)

	form.noteLabel = Label(form, 0, 186, L.GROUPS_FIELD_NOTE, "GameFontDisableSmall")
	form.note = Input(form, SIDE_W, Codec.GROUP_NOTE)
	form.note:SetPoint("TOPLEFT", 0, -200)
	form.name:SetScript("OnTabPressed", function() form.note:SetFocus() end)
	form.note:SetScript("OnTabPressed", function() form.name:SetFocus() end)

	form.announce = CreateFrame("CheckButton", nil, form, "UICheckButtonTemplate")
	form.announce:SetSize(24, 24)
	form.announce:SetPoint("TOPLEFT", -4, -230)
	form.announceLabel = FS(form, "GameFontHighlightSmall")
	form.announceLabel:SetPoint("LEFT", form.announce, "RIGHT", 2, 0)
	form.announceLabel:SetText(L.GROUPS_ANNOUNCE)
	TextTip(form.announce, L.GROUPS_ANNOUNCE, L.GROUPS_ANNOUNCE_TIP)

	form.submit = Button(form, L.GROUPS_SUBMIT, 150, "submit", Submit)
	form.submit:SetPoint("BOTTOMLEFT", 0, 2)
	local cancel = Button(form, L.GROUPS_CANCEL, 110, "cancel", function()
		CloseForm()
		Pane.Render()
	end)
	cancel:SetPoint("BOTTOMRIGHT", 0, 2)
	form.cancel = cancel
end

local function RenderForm()
	local group = draft.mode == "G"
	form.title:SetText(draft.edit and L.GROUPS_FORM_EDIT or (group and L.GROUPS_FORM_GROUP or L.GROUPS_FORM_PLAYER))
	for _, chip in ipairs(form.kinds) do Mark(chip, chip.kind == draft.kind) end
	form.nameLabel:SetText(group and L.GROUPS_FIELD_TITLE or L.GROUPS_FIELD_WISH)
	local catalog = Groups.Catalog() ~= nil
	form.pick:SetShown(catalog)
	form.name:SetWidth(catalog and SIDE_W - 90 or SIDE_W)
	form.needLabel:SetShown(group)
	form.capLabel:SetShown(group)
	form.minLabel:SetShown(group)
	form.min:SetShown(group)
	for _, s in ipairs(form.steppers) do
		s:SetShown(group)
		s.Render()
	end
	for _, chip in ipairs(form.caps) do
		chip:SetShown(group)
		Mark(chip, chip.cap == draft.cap)
	end
	form.rolesLabel:SetShown(not group)
	for _, chip in ipairs(form.roles) do chip:SetShown(not group) end
	MarkRoles(form.roles)
	-- О правке в чат не пишем: строка нужна только новому объявлению.
	form.announce:SetShown(not draft.edit)
	form.announceLabel:SetShown(not draft.edit)
	form.submit:SetText(draft.edit and L.GROUPS_SAVE or L.GROUPS_SUBMIT)
end

---------------------------------------------------------------------------
-- Справа: моё объявление и заявки к нему
---------------------------------------------------------------------------
local function ApplicantRow(i)
	local r = applicantRows[i]
	if r then return r end
	r = CreateFrame("Button", nil, own.child)
	r:SetSize(SIDE_W - 26, APPLICANT_H)
	r:SetPoint("TOPLEFT", own.child, "TOPLEFT", 0, -(i - 1) * (APPLICANT_H + 2))
	local bg = r:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1, 0.03)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	r.refuse = Button(r, L.GROUPS_REFUSE, 40, "decline", function() Groups.Decline(r.key) end)
	r.refuse:SetHeight(20)
	r.refuse:SetPoint("RIGHT", -3, 0)
	TextTip(r.refuse, L.GROUPS_REFUSE, L.GROUPS_REFUSE_TIP)
	r.take = Button(r, L.GROUPS_TAKE, 58, "invite", function() Groups.Invite(r.key) end)
	r.take:SetHeight(20)
	r.take:SetPoint("RIGHT", r.refuse, "LEFT", -2, 0)
	TextTip(r.take, L.GROUPS_TAKE, L.GROUPS_TAKE_TIP)
	r.mark = FS(r, "GameFontDisableSmall", "RIGHT")
	r.mark:SetPoint("RIGHT", -6, 0)
	r.mark:SetText(L.GROUPS_INVITED_MARK)
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 5, -4)
	r.name:SetWidth(SIDE_W - 26 - 110)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 5, 5)
	r.sub:SetWidth(SIDE_W - 26 - 110)
	for _, fs in ipairs({ r.name, r.sub }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self)
		if self.who then ns.SafeCall("groups: whisper", Whisper, self.who) end
	end)
	Tip(r, nil)
	applicantRows[i] = r
	return r
end

local function BuildOwn()
	own = CreateFrame("Frame", nil, side)
	own:SetAllPoints(side)
	own.title = Label(own, 0, 4, nil, "GameFontNormal")
	-- Название — одной строкой, примечание — не больше двух: ниже стоят счётчики и заявки.
	own.name = Label(own, 0, 26, nil, "GameFontHighlight")
	own.name:SetWidth(SIDE_W)
	if own.name.SetWordWrap then own.name:SetWordWrap(false) end
	own.note = Label(own, 0, 42, nil, "GameFontDisableSmall")
	own.note:SetWidth(SIDE_W)
	if own.note.SetMaxLines then own.note:SetMaxLines(2) end
	own.info = Label(own, 0, 70, nil, "GameFontHighlightSmall")
	own.info:SetWidth(SIDE_W)
	own.needLabel = Label(own, 0, 92, L.GROUPS_FIELD_NEED, "GameFontDisableSmall")
	own.steppers = {}
	for _, role in ipairs(Groups.ROLES) do
		own.steppers[#own.steppers + 1] = Stepper(own, role,
			function()
				local mine = Groups.Mine()
				return mine and mine.roles[role] or 0
			end,
			function(n) Groups.SetNeed(role, n) end)
	end
	PlaceRow(own, own.steppers, 0, 106, 9)
	own.applicantsLabel = Label(own, 0, 138, nil, "GameFontNormalSmall")
	own.scroll = CreateFrame("ScrollFrame", nil, own, "UIPanelScrollFrameTemplate")
	own.scroll:SetPoint("TOPLEFT", 0, -154)
	own.scroll:SetPoint("BOTTOMRIGHT", -24, 30)
	own.child = CreateFrame("Frame", nil, own.scroll)
	own.child:SetSize(SIDE_W - 26, 10)
	own.scroll:SetScrollChild(own.child)
	own.none = FS(own.child, "GameFontDisableSmall")
	own.none:SetPoint("TOPLEFT", 2, -4)
	own.none:SetWidth(SIDE_W - 30)
	own.none:SetText(L.GROUPS_NO_APPLICANTS)
	own.hint = Label(own, 0, 92, L.GROUPS_MINE_PLAYER_HINT, "GameFontDisableSmall")
	own.hint:SetWidth(SIDE_W)
	local edit = Button(own, L.GROUPS_EDIT, 150, "edit", function()
		local mine = Groups.Mine()
		if mine then OpenForm(mine.mode) end
	end)
	edit:SetPoint("BOTTOMLEFT", 0, 2)
	local lower = Button(own, L.GROUPS_LOWER, 110, "lower", function() Groups.Lower() end)
	lower:SetPoint("BOTTOMRIGHT", 0, 2)
	own.edit, own.lower = edit, lower
end

local function RenderOwn(mine)
	local group = mine.mode == "G"
	own.title:SetText(group and L.GROUPS_MINE_GROUP or L.GROUPS_MINE_PLAYER)
	own.name:SetText(mine.title ~= "" and mine.title or L.GROUPS_ANYWHERE)
	own.note:SetText(mine.note)
	local left = Views.GroupLeft(mine)
	if group then
		local size = math.max(1, GetNumGroupMembers and GetNumGroupMembers() or 0)
		own.info:SetText(L.GROUPS_MINE_SIZE:format(size, mine.cap, left))
	else
		own.info:SetText(L.GROUPS_TIP_ROLES:format(Groups.RoleText(mine.roles)) .. ". " .. L.GROUPS_MINE_LEFT:format(left))
	end
	own.needLabel:SetShown(group)
	for _, s in ipairs(own.steppers) do
		s:SetShown(group)
		s.Render()
	end
	own.applicantsLabel:SetShown(group)
	own.scroll:SetShown(group)
	own.hint:SetShown(not group)
	if not group then return end
	local items = Views.GroupApplicants()
	own.applicantsLabel:SetText(L.GROUPS_APPLICANTS:format(#items))
	for i, it in ipairs(items) do
		local r = ApplicantRow(i)
		r.key, r.who, r.tip = it.key, it.who, it.tip
		r.name:SetText(it.name)
		r.sub:SetText(it.sub)
		r.take:SetShown(not it.invited)
		r.refuse:SetShown(not it.invited)
		r.mark:SetShown(it.invited)
		r:Show()
	end
	for i = #items + 1, #applicantRows do applicantRows[i]:Hide() end
	own.child:SetHeight(math.max(#items * (APPLICANT_H + 2), 10))
	own.none:SetShown(#items == 0)
end

---------------------------------------------------------------------------
-- Вкладка
---------------------------------------------------------------------------
local function RenderSide()
	local mine = Groups.Mine()
	local state = editing and "form" or (mine and "own" or "idle")
	if state ~= "form" and picking then ClosePicker() end
	idle:SetShown(state == "idle")
	-- Список занятий показан вместо формы: под ним ничего не просвечивает.
	form:SetShown(state == "form" and not picking)
	picker:SetShown(state == "form" and picking)
	own:SetShown(state == "own")
	if state == "idle" then
		MarkRoles(idle.roles)
	elseif state == "form" and picking then
		RenderPicker()
	elseif state == "form" then
		RenderForm()
	else
		RenderOwn(mine)
	end
end

function Pane.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	BuildList()
	side = CreateFrame("Frame", nil, pane)
	side:SetPoint("TOPLEFT", SIDE_X, -8)
	side:SetSize(SIDE_W, BASE_H - SIDE_V)
	BuildIdle()
	BuildForm()
	BuildOwn()
	BuildPicker()
	Pane.frames.pane, Pane.frames.rows, Pane.frames.filters = pane, rows, filters
	Pane.frames.idle, Pane.frames.form, Pane.frames.own, Pane.frames.picker = idle, form, own, picker
	Pane.frames.applicants, Pane.frames.pickerRows = applicantRows, pickerRows
	Pane.frames.list, Pane.frames.side = list, side
	pane:Hide()
	return pane
end

-- Раскладка под вставку width×height (UI.lua): доска шире, правая панель у правого края и выше.
-- Её содержимое привязано к её краям: кнопки снизу, списки заявок и занятий тянутся вниз.
function Pane.Layout(width, height)
	if not pane then return end
	local extra = math.max(0, math.floor(width - BASE_W))
	listW, sideX = LIST_W + extra, SIDE_X + extra
	list:SetWidth(listW)
	listChild:SetWidth(listW)
	empty:SetWidth(listW - 12)
	local textWidth = TextW()
	for _, r in ipairs(rows) do
		r:SetWidth(listW)
		r.name:SetWidth(textWidth)
		r.sub:SetWidth(textWidth)
	end
	divider:ClearAllPoints()
	divider:SetPoint("TOPLEFT", sideX - 8, -10)
	divider:SetPoint("BOTTOMLEFT", sideX - 8, 10)
	side:ClearAllPoints()
	side:SetPoint("TOPLEFT", sideX, -8)
	side:SetHeight(math.max(BASE_H, math.floor(height)) - SIDE_V)
end

function Pane.Render()
	if not pane or not pane:IsShown() then return end
	RenderList()
	RenderSide()
end

function Pane.Show()
	if not pane then return end
	-- Доску не переспрашиваем: объявления приходят и при закрытой вкладке, запрос GQ уходит
	-- один раз после входа (Groups.lua).
	pane:Show()
	Pane.Render()
end

function Pane.Hide()
	if not pane or not pane:IsShown() then return end
	CloseForm()
	pane:Hide()
end

-- Форма объявления из кода (команды, тесты): mode — "G" или "P".
function Pane.Open(mode)
	if pane and pane:IsShown() then OpenForm(mode) end
end

-- Изменения доски и своего объявления рисуем сразу. Минуты до снятия объявления идут сами:
-- их раз в полминуты обновляет общий тик окна (UI.lua), своего таймера у вкладки нет.
ns.On("GROUPS", function()
	if pane and pane:IsVisible() then Pane.Render() end
end)
