-- Chillzone: вкладка «Мастера профессий». Слева каталог мастеров объединения с поиском и фильтром по
-- профессии, справа — своё ремесло (прочитанные профессии, примечание, своя карточка) или
-- карточка выбранного мастера со списком его рецептов. Строки готовит Views.lua, логика — в
-- Crafters.lua. Витрина мастера — значки справа от имени в строке каталога и рецепты первыми в
-- карточке; свою витрину игрок отмечает звёздочками в своей карточке, а кнопка «Витрина» открывает
-- её и до размещения — черновиком, который там же и размещается.
--
-- Поля ввода — свои EditBox, штатные popup и выпадающие списки не используются (taint). Поле
-- ввода и окна чата игры вкладка не трогает: «Шепнуть» и меню правого щелчка открывают шёпот
-- через ChatPane.Whisper.
local ADDON, ns = ...

local U = ns.Util
local L = ns.L
local C = ns.Config
local Codec = ns.Codec
local Views = ns.Views

local Pane = { frames = {} }
ns.CraftersPane = Pane

local LIST_W = 468 -- каталог; справа от него полоса прокрутки
local SIDE_X, SIDE_W = 512, 282
local ROW_H = 38
local ACTION_W = 84
local PROF_ROWS = 6
local LIST_TOP = 60
local SEARCH_DELAY = 0.25
local NAME_W = LIST_W - 6 - ACTION_W - 8 -- имя в строке каталога без витрины
local SHOW_SIZE = 18 -- значок витрины в строке каталога
local NO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local STAR = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_1"

local pane, search, searchHint, loaded, list, listChild, empty, side
local levelLo, levelHi -- требуемый уровень предмета «от» и «до»
local mine, card
local rows, filters, profRows, cardChips, recipeRows = {}, {}, {}, {}, {}
local allChip
local filter -- номер профессии или nil — все
local query = ""
local levels -- диапазон уровней (Views.CraftLevels) или nil
local viewing, viewProf -- мастер и его профессия на правой панели; nil — своё ремесло
local mineWhy, cardWhy -- отказ последнего действия: показывается до следующего
local searchToken, recipeToken = 0, 0 -- отложенный поиск в каталоге и в рецептах карточки

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
		ns.SafeCall("crafters tooltip", self.tip, GameTooltip)
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
	b:SetScript("OnClick", function(self) ns.SafeCall("crafters: " .. where, fn, self) end)
	return b
end

-- Ширина надписи; запасной расчёт — для клиента, который её не сообщает.
local function TextWidth(fs, text)
	local w = fs:GetStringWidth()
	if type(w) == "number" and w > 0 then return w end
	return select(2, text:gsub("|T.-|t", "WW"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[^\128-\191]", "")) * 7
end

-- Плоская кнопка-переключатель: фильтр профессий и профессии мастера.
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
	function b.SetLabel(self, t)
		self.label:SetText(t)
		self.w = math.floor(TextWidth(self.label, t) + 14)
		self:SetSize(self.w, 20)
	end
	b:SetLabel(text)
	b:SetScript("OnClick", function(self) ns.SafeCall("crafters: " .. where, fn, self) end)
	return b
end

local function Mark(chip, on)
	chip.on:SetShown(on and true or false)
	if on then chip.label:SetTextColor(1, 0.82, 0) else chip.label:SetTextColor(1, 1, 1) end
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

-- Шёпот в поле чата игры (в режиме геймпада — в окне Chillzone), см. ChatPane.Whisper.
local function Whisper(name)
	ns.ChatPane.Whisper(name)
end

---------------------------------------------------------------------------
-- Каталог
---------------------------------------------------------------------------
-- Своя строка открывает свою размещённую карточку, как её видят остальные, со своим списком
-- рецептов; «Назад» возвращает к «Моему ремеслу». prof — открыть на этой профессии (значок
-- витрины), иначе — на выбранной фильтром или первой.
local function Open(key, prof)
	cardWhy = nil
	-- Другой мастер или значок витрины — список с начала: витрина в нём первой.
	if card and key and (key ~= viewing or prof) then card.scroll:SetVerticalScroll(0) end
	-- Поиск в рецептах относится к одному мастеру: у другого он начинается с пустого поля.
	if key ~= viewing and card and (card.query ~= "" or (card.search:GetText() or "") ~= "") then
		recipeToken = recipeToken + 1
		card.query = ""
		card.search:SetText("")
		card.search:ClearFocus()
		card.searchHint:Show()
	end
	local own = key ~= nil and key == ns.myKey
	local c
	if own then c = ns.Crafters.Own(true) elseif key then c = ns.Crafters.Get(key) end
	if not key or own and not c then
		viewing, viewProf = nil, nil
		Pane.Render()
		return
	end
	viewing, viewProf = key, nil
	for _, p in ipairs(c and c.profs or {}) do
		if p.id == (prof or filter) then viewProf = p.id end
	end
	viewProf = viewProf or (c and c.profs[1] and c.profs[1].id)
	-- Нет списка или он устарел — запрос уходит сразу; иначе показывается сохранённый.
	if viewProf and not own then ns.Crafters.Want(key, viewProf) end
	Pane.Render()
end
Pane.Open = Open

local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, listChild)
	r:SetWidth(LIST_W)
	r:SetHeight(ROW_H)
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:SetColorTexture(1, 1, 1, 0.03)
	r.mine = r:CreateTexture(nil, "BORDER")
	r.mine:SetAllPoints()
	r.mine:SetColorTexture(1, 0.82, 0, 0.1)
	r.picked = r:CreateTexture(nil, "BORDER")
	r.picked:SetAllPoints()
	r.picked:SetColorTexture(0.5, 0.83, 0.76, 0.12)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.07)
	r.button = Button(r, L.CRAFT_WHISPER, ACTION_W - 4, "row whisper", function()
		if r.it then Whisper(r.it.card.name) end
	end)
	r.button:SetHeight(20)
	r.button:SetPoint("RIGHT", -4, 0)
	r.status = FS(r, "GameFontHighlightSmall", "CENTER")
	r.status:SetPoint("RIGHT", -4, 0)
	r.status:SetWidth(ACTION_W - 4)
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 6, -5)
	r.name:SetWidth(NAME_W)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 6, 6)
	r.sub:SetWidth(NAME_W)
	r.shows = {}
	for _, fs in ipairs({ r.name, r.sub, r.status }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	-- Правый щелчок — то же меню человека, что в чате и переписи: шёпот и приглашение в группу.
	-- Шёпот есть и у мастера без отметки «в игре»: онлайн чужой гильдии виден не всегда.
	r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	r:SetScript("OnClick", function(self, button)
		if not self.it then return end
		if button == "RightButton" then
			if self.it.person then ns.SafeCall("crafters: menu", ns.ChatPane.OpenPersonMenu, self, self.it.person, Whisper) end
			return
		end
		ns.SafeCall("crafters: open", Open, self.it.key)
	end)
	Tip(r, nil)
	rows[i] = r
	return r
end

-- Значок витрины в строке каталога: предмет в золотой рамке, подсказка — предмет, как в игре,
-- щелчок — карточка мастера на профессии этого рецепта.
local function ShowIcon(r, j)
	local b = r.shows[j]
	if b then return b end
	b = CreateFrame("Button", nil, r)
	b:SetSize(SHOW_SIZE, SHOW_SIZE)
	local border = b:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints()
	border:SetColorTexture(1, 0.82, 0, 0.6)
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.2)
	b:SetScript("OnClick", function(self)
		if r.it and self.prof then ns.SafeCall("crafters: showcase", Open, r.it.key, self.prof) end
	end)
	Tip(b, nil)
	r.shows[j] = b
	return b
end

-- Витрина справа от имени, слева от «Шепнуть»; имя укорачивается на её ширину.
local function RenderShowcase(r, show)
	local n = #show
	for j, s in ipairs(show) do
		local b = ShowIcon(r, j)
		b.prof, b.tip = s.prof, Views.CraftShowTip(s.id)
		b.icon:SetTexture(ns.Crafters.RecipeIcon(s.id) or NO_ICON)
		ns.Crafters.RecipeName(s.id) -- игра называет рецепт не сразу: к подсказке строки он уже назван
		b:ClearAllPoints()
		b:SetPoint("TOPRIGHT", r, "TOPRIGHT", -(ACTION_W + 4 + (n - j) * (SHOW_SIZE + 2)), -3)
		b:Show()
	end
	for j = n + 1, #r.shows do r.shows[j]:Hide() end
	r.name:SetWidth(n > 0 and NAME_W - n * (SHOW_SIZE + 2) - 2 or NAME_W)
end

local function FilterChip(id)
	local chip = filters[id]
	if chip then return chip end
	chip = Chip(pane, Views.CraftIcon(id, 16), "filter", function()
		filter = filter ~= id and id or nil
		if list then list:SetVerticalScroll(0) end
		Pane.Render()
	end)
	chip.w = 28
	chip:SetSize(chip.w, 20)
	TextTip(chip, ns.Crafters.ProfName(id), L.CRAFT_FILTER_TIP)
	filters[id] = chip
	return chip
end

local function RenderFilters()
	local profs, x, present = Views.CraftProfs(), 8, {}
	allChip:ClearAllPoints()
	allChip:SetPoint("TOPLEFT", pane, "TOPLEFT", x, -34)
	x = x + allChip.w + 4
	for _, id in ipairs(profs) do
		present[id] = true
		local chip = FilterChip(id)
		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", pane, "TOPLEFT", x, -34)
		chip:Show()
		Mark(chip, filter == id)
		x = x + chip.w + 4
	end
	for id, chip in pairs(filters) do
		if not present[id] then chip:Hide() end
	end
	-- Профессия пропала из каталога — фильтр по ней ничего бы не показал.
	if filter and not present[filter] then filter = nil end
	Mark(allChip, filter == nil)
end

-- Кто из мастеров других гильдий в игре, видно по их спискам Online: пока вкладка на экране,
-- спрашиваем списки гильдий из показанных строк. Частоту и повторы ограничивает Online.Want.
local function WantOnline(items)
	local asked = {}
	for _, it in ipairs(items) do
		local gk = not it.own and U.GuildKey(it.card.guild)
		if gk and not asked[gk] then
			asked[gk] = true
			ns.Online.Want(it.card.guild)
		end
	end
end

local function RenderList()
	RenderFilters()
	local items, total, found = Views.CraftRows(filter, query, levels)
	WantOnline(items)
	local y = 0
	for i, it in ipairs(items) do
		local r = Row(i)
		r.it, r.tip = it, it.tip
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y)
		y = y + ROW_H + 2
		r.mine:SetShown(it.own == true)
		r.picked:SetShown(viewing ~= nil and it.key == viewing)
		r.name:SetText(it.name)
		r.sub:SetText(it.sub)
		RenderShowcase(r, it.show or {})
		r.button:SetShown(it.action == "whisper")
		r.status:SetText(it.action and "" or (it.status or ""))
		r:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	listChild:SetHeight(math.max(y, 10))
	empty:SetShown(#items == 0)
	if not ns.IsMember() then
		empty:SetText(L.CRAFT_NOT_MEMBER)
	else
		empty:SetText(total > 0 and L.CRAFT_EMPTY_FILTER:format(total) or L.CRAFT_EMPTY)
	end
	loaded:SetText(found and L.CRAFT_LOADED:format(found.loaded, found.of) or "")
end

local function Searched()
	searchToken = searchToken + 1
	local token = searchToken
	ns.After(SEARCH_DELAY, "crafters search", function()
		if token ~= searchToken or not search then return end
		query = search:GetText() or ""
		levels = Views.CraftLevels(levelLo:GetText(), levelHi:GetText())
		if list then list:SetVerticalScroll(0) end
		Pane.Render()
	end)
end

-- Поле уровня: две цифры, подсказка «от» или «до» внутри, пока поле пустое.
local function LevelInput(hint)
	local box = Input(pane, 32, 2)
	box:SetNumeric(true)
	box:SetJustifyH("CENTER")
	box.hint = FS(box, "GameFontDisableSmall", "CENTER")
	box.hint:SetPoint("CENTER")
	box.hint:SetText(hint)
	box:SetScript("OnTextChanged", function(self)
		self.hint:SetShown((self:GetText() or "") == "" and not self:HasFocus())
		Searched()
	end)
	box:SetScript("OnEditFocusGained", function(self) self.hint:Hide() end)
	box:SetScript("OnEditFocusLost", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
	TextTip(box, L.CRAFT_LEVEL_TITLE, L.CRAFT_LEVEL_TIP)
	return box
end

local function BuildList()
	search = Input(pane, 178, 60)
	search:SetPoint("TOPLEFT", 8, -6)
	searchHint = FS(search, "GameFontDisableSmall")
	searchHint:SetPoint("LEFT", 8, 0)
	searchHint:SetText(L.CRAFT_SEARCH)
	search:SetScript("OnTextChanged", function(self)
		searchHint:SetShown((self:GetText() or "") == "" and not self:HasFocus())
		Searched()
	end)
	search:SetScript("OnEditFocusGained", function() searchHint:Hide() end)
	search:SetScript("OnEditFocusLost", function(self) searchHint:SetShown((self:GetText() or "") == "") end)
	TextTip(search, L.CRAFT_SEARCH, L.CRAFT_SEARCH_TIP)
	-- Требуемый уровень предмета, как на аукционе: «Уровень [от] — [до]».
	local label = FS(pane, "GameFontHighlightSmall")
	label:SetPoint("LEFT", search, "RIGHT", 8, 0)
	label:SetText(L.CRAFT_LEVEL)
	levelLo = LevelInput(L.CRAFT_LEVEL_FROM)
	levelLo:SetPoint("LEFT", label, "RIGHT", 4, 0)
	local dash = FS(pane, "GameFontHighlightSmall")
	dash:SetPoint("LEFT", levelLo, "RIGHT", 2, 0)
	dash:SetText("—")
	levelHi = LevelInput(L.CRAFT_LEVEL_TO)
	levelHi:SetPoint("LEFT", dash, "RIGHT", 2, 0)
	levelLo:SetScript("OnTabPressed", function() levelHi:SetFocus() end)
	levelHi:SetScript("OnTabPressed", function() levelLo:SetFocus() end)
	-- Справа от уровней остаётся около 140 точек: длинная надпись переносится на вторую строку.
	loaded = FS(pane, "GameFontDisableSmall", "RIGHT")
	loaded:SetPoint("RIGHT", pane, "TOPLEFT", LIST_W + 8, -17)
	loaded:SetWidth(LIST_W - 324)

	allChip = Chip(pane, L.CRAFT_FILTER_ALL, "filter all", function()
		filter = nil
		if list then list:SetVerticalScroll(0) end
		Pane.Render()
	end)

	list = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	list:SetPoint("TOPLEFT", 8, -LIST_TOP)
	list:SetPoint("BOTTOMLEFT", 8, 8)
	list:SetWidth(LIST_W)
	listChild = CreateFrame("Frame", nil, list)
	listChild:SetSize(LIST_W, 10)
	list:SetScrollChild(listChild)
	empty = FS(listChild, "GameFontDisable")
	empty:SetPoint("TOPLEFT", 6, -8)
	empty:SetWidth(LIST_W - 12)
	empty:Hide()

	local divider = pane:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.08)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", SIDE_X - 8, -10)
	divider:SetPoint("BOTTOMLEFT", SIDE_X - 8, 10)
end

---------------------------------------------------------------------------
-- Справа: своё ремесло
---------------------------------------------------------------------------
local function Post()
	local ok, why, arg = ns.Crafters.Post(mine.note:GetText())
	mineWhy = not ok and Views.CraftWhy(why, arg) or nil
	mine.note:ClearFocus()
	if ok then mine.note:SetText(ns.Crafters.Note()) end
	Pane.Render()
end

-- «Витрина»: своя карточка, в том числе неразмещённая (черновик) — в ней рецепты отмечаются
-- звёздочкой, а черновик там же и размещается.
local function Showcase()
	mine.note:ClearFocus()
	if not ns.Crafters.Own(true) then
		mineWhy = Views.CraftWhy(#ns.Crafters.MyProfs() > 0 and "none" or "noprofs")
		Pane.Render()
		return
	end
	mineWhy = nil
	Open(ns.myKey)
end

local function Withdraw()
	if ns.Crafters.Withdraw() then mineWhy = L.CRAFT_WITHDRAWN end
	Pane.Render()
end

local function BuildMine()
	mine = CreateFrame("Frame", nil, side)
	mine:SetAllPoints(side)
	mine.title = Label(mine, 0, 0, L.CRAFT_MINE, "GameFontNormal")
	mine.hint = Label(mine, 0, 18, nil, "GameFontDisableSmall")
	for i = 1, PROF_ROWS do
		local y = 46 + (i - 1) * 26
		local check = CreateFrame("CheckButton", nil, mine, "UICheckButtonTemplate")
		check:SetSize(24, 24)
		check:SetPoint("TOPLEFT", -4, -y)
		check.label = FS(mine, "GameFontHighlightSmall")
		check.label:SetPoint("TOPLEFT", 22, -(y + 1))
		check.label:SetWidth(SIDE_W - 22)
		check.detail = FS(mine, "GameFontDisableSmall")
		check.detail:SetPoint("TOPLEFT", 22, -(y + 13))
		check.detail:SetWidth(SIDE_W - 22)
		check:SetScript("OnClick", function(self)
			ns.SafeCall("crafters: prof", function()
				if self.id then ns.Crafters.SetPost(self.id, self:GetChecked()) end
			end)
		end)
		TextTip(check, L.CRAFT_MINE, L.CRAFT_PROF_TIP:format(C.CRAFT_PROFS))
		profRows[i] = check
	end
	mine.noteLabel = Label(mine, 0, 206, L.CRAFT_NOTE_LABEL, "GameFontDisableSmall")
	mine.note = Input(mine, SIDE_W, Codec.CRAFT_NOTE)
	mine.note:SetPoint("TOPLEFT", 0, -220)
	mine.status = Label(mine, 0, 250, nil, "GameFontHighlightSmall")
	mine.post = Button(mine, L.CRAFT_POST, 104, "post", Post)
	mine.post:SetPoint("BOTTOMLEFT", 0, 2)
	mine.showcase = Button(mine, L.CRAFT_SHOWCASE, 84, "showcase", Showcase)
	mine.showcase:SetPoint("BOTTOMLEFT", 108, 2)
	Tip(mine.showcase, function(tt)
		tt:AddLine(L.CRAFT_SHOW_TITLE, 1, 0.82, 0)
		tt:AddLine(L.CRAFT_SHOWCASE_TIP:format(ns.Crafters.ShowCount(), C.CRAFT_SHOW), 1, 1, 1, true)
	end)
	mine.withdraw = Button(mine, L.CRAFT_WITHDRAW, 86, "withdraw", Withdraw)
	mine.withdraw:SetPoint("BOTTOMRIGHT", 0, 2)
end

local function RenderMine()
	local view = Views.CraftMine()
	mine.hint:SetText(view.hint)
	for i, check in ipairs(profRows) do
		local p = view.profs[i]
		check.id = p and p.id
		check:SetShown(p ~= nil)
		check.label:SetShown(p ~= nil)
		check.detail:SetShown(p ~= nil)
		if p then
			check:SetChecked(p.post)
			check.label:SetText(p.label)
			check.detail:SetText(p.detail)
		end
	end
	mine.status:SetText(mineWhy or view.status)
	mine.post:SetText(view.posted and L.CRAFT_UPDATE or L.CRAFT_POST)
	mine.withdraw:SetEnabled(view.posted)
end

---------------------------------------------------------------------------
-- Справа: карточка мастера
---------------------------------------------------------------------------
local function Pick(id)
	viewProf, cardWhy = id, nil
	if viewing and viewing ~= ns.myKey then ns.Crafters.Want(viewing, id) end
	if card.scroll then card.scroll:SetVerticalScroll(0) end
	Pane.Render()
end

local function CardChip(i)
	local chip = cardChips[i]
	if chip then return chip end
	chip = Chip(card, "", "prof", function(self)
		if self.id then Pick(self.id) end
	end)
	Tip(chip, nil)
	cardChips[i] = chip
	return chip
end

-- «Обновить рецепты» у чужой карточки; в своей та же кнопка — «Разместить» черновик или
-- «Обновить»: отправить правки витрины сразу. Примечание — из поля «Моего ремесла», как у его кнопки.
local function Refresh()
	if viewing and viewing == ns.myKey then
		local ok, why, arg = ns.Crafters.Post(mine.note:GetText())
		cardWhy = not ok and Views.CraftWhy(why, arg) or nil
		if ok then mine.note:SetText(ns.Crafters.Note()) end
		Pane.Render()
		return
	end
	if not viewing or not viewProf then return end
	local ok, why = ns.Crafters.Want(viewing, viewProf, true)
	cardWhy = not ok and why ~= "busy" and Views.CraftWhy(why) or nil
	Pane.Render()
end

-- Список рецептов в карточке: строка — значок и название, щелчок раскрывает под ней реагенты,
-- по одному на строку. Рамок столько, сколько видно, их содержимое меняется при прокрутке: у
-- мастера бывает несколько сотен рецептов.
-- RECIPES_H — высота списка, когда строка состояния над ним в одну строку; длиннее она — короче список
-- (card.listH). LIST_BOTTOM — низ списка от верха панели: ниже кнопки.
local RECIPE_H, REAGENT_H, RECIPES_H, LIST_BOTTOM = 22, 16, 166, 292
local RECIPE_ROWS = math.ceil(RECIPES_H / RECIPE_H) + 1
local RECIPE_NAME_W = SIDE_W - 26 - 26 - 22 -- название рецепта без звёздочки витрины
local PLUS, MINUS = "Interface\\Buttons\\UI-PlusButton-Up", "Interface\\Buttons\\UI-MinusButton-Up"
local expanded = {} -- [номер рецепта] = true: реагенты раскрыты, на сессию

local function Reagents(it)
	local d = ns.Crafters.RecipeDetails(it.id)
	return d.reagents and #d.reagents > 0 and d.reagents or nil
end

-- Высота рецепта в списке: раскрытый выше на свои реагенты.
local function RecipeHeight(it)
	local r = expanded[it.id] and Reagents(it)
	return r and RECIPE_H + #r * REAGENT_H + 4 or RECIPE_H
end

-- Верх каждого рецепта в списке и высота всего списка.
local function Layout()
	local tops, y = {}, 0
	for i, it in ipairs(card.items) do
		tops[i] = y
		y = y + RecipeHeight(it)
	end
	card.tops, card.total = tops, y
end

local PlaceRecipes

-- Пересчитать высоту списка и разложить видимые строки; прокрутка остаётся в пределах списка.
local function Resize()
	Layout()
	card.child:SetHeight(math.max(10, card.total))
	local most = math.max(0, card.total - (card.listH or RECIPES_H))
	if (card.scroll:GetVerticalScroll() or 0) > most then card.scroll:SetVerticalScroll(most) end
	PlaceRecipes()
end

local function Toggle(r)
	if not r.it or not Reagents(r.it) then return end
	expanded[r.it.id] = not expanded[r.it.id] or nil
	Resize()
	-- Подсказка под курсором говорит, что сделает следующий щелчок.
	if r:IsShown() and type(GameTooltip.IsOwned) == "function" and GameTooltip:IsOwned(r) then
		r:GetScript("OnEnter")(r)
	end
end

local function ReagentLine(r, j)
	local fs = r.lines[j]
	if fs then return fs end
	fs = FS(r, "GameFontHighlightSmall")
	fs:SetPoint("TOPLEFT", 26, -(RECIPE_H + (j - 1) * REAGENT_H))
	fs:SetWidth(SIDE_W - 56)
	if fs.SetWordWrap then fs:SetWordWrap(false) end
	r.lines[j] = fs
	return fs
end

-- Звёздочка в своей карточке: выставить рецепт на витрину или убрать с неё.
local function Star(r)
	local it = r.it
	if not it or viewing ~= ns.myKey or not viewProf then return end
	local ok, why = ns.Crafters.SetShow(viewProf, it.id, not it.show)
	cardWhy = not ok and (why == "full" and L.CRAFT_SHOW_FULL:format(C.CRAFT_SHOW) or L.CRAFT_SHOW_MISSING) or nil
	Pane.Render()
end

local function RecipeRow(i)
	local r = CreateFrame("Button", nil, card.child)
	r:SetSize(SIDE_W - 26, RECIPE_H)
	-- Рецепт с витрины подсвечен золотым.
	r.pin = r:CreateTexture(nil, "BACKGROUND")
	r.pin:SetAllPoints()
	r.pin:SetColorTexture(1, 0.82, 0, 0.1)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.07)
	-- Звёздочка: в чужой карточке — пометка витрины, в своей — переключатель у каждого рецепта.
	r.star = CreateFrame("Button", nil, r)
	r.star:SetSize(16, 16)
	r.star:SetPoint("TOPRIGHT", -22, -3)
	r.star.icon = r.star:CreateTexture(nil, "ARTWORK")
	r.star.icon:SetAllPoints()
	r.star.icon:SetTexture(STAR)
	r.star:SetScript("OnClick", function() ns.SafeCall("crafters: star", Star, r) end)
	Tip(r.star, nil)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(18, 18)
	r.icon:SetPoint("TOPLEFT", 2, -2)
	r.toggle = r:CreateTexture(nil, "ARTWORK")
	r.toggle:SetSize(14, 14)
	r.toggle:SetPoint("TOPRIGHT", -4, -4)
	r.name = FS(r, "GameFontHighlightSmall")
	r.name:SetPoint("TOPLEFT", 26, -5)
	r.name:SetWidth(RECIPE_NAME_W)
	if r.name.SetWordWrap then r.name:SetWordWrap(false) end
	r.lines = {}
	r:SetScript("OnClick", function(self) ns.SafeCall("crafters: reagents", Toggle, self) end)
	Tip(r, nil)
	recipeRows[i] = r
	return r
end

-- Первый рецепт, видимый при прокрутке offset.
local function FirstVisible(offset)
	local tops, lo, hi = card.tops, 1, #card.items
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if tops[mid] <= offset then lo = mid else hi = mid - 1 end
	end
	return lo
end

-- Видимые строки списка по текущей прокрутке.
function PlaceRecipes()
	local items = card.items or {}
	local offset = card.scroll:GetVerticalScroll() or 0
	local index = #items > 0 and FirstVisible(offset) or 1
	for i = 1, RECIPE_ROWS do
		local r = recipeRows[i] or RecipeRow(i)
		local it = items[index]
		if it and card.tops[index] >= offset + (card.listH or RECIPES_H) then it = nil end
		r:SetShown(it ~= nil)
		r.it = it
		if it then
			r.top = card.tops[index]
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", card.child, "TOPLEFT", 0, -r.top)
			r:SetHeight(RecipeHeight(it))
			local d = ns.Crafters.RecipeDetails(it.id)
			local open = expanded[it.id] and Reagents(it) ~= nil
			-- Названия реагентов видимых строк игра догружает заранее: к подсказке и раскрытию.
			for _, x in ipairs(d.reagents or {}) do ns.Crafters.ItemName(x.item) end
			r.icon:SetTexture(d.icon or NO_ICON)
			r.name:SetText(Views.CraftRecipeName(it))
			local own = viewing == ns.myKey
			local star = own or it.show ~= nil
			r.pin:SetShown(it.show ~= nil)
			r.star:SetShown(star)
			r.star:EnableMouse(own)
			r.star.icon:SetDesaturated(it.show == nil)
			r.star.icon:SetAlpha(it.show and 1 or 0.35)
			r.star.tip = own and function(tt)
				tt:AddLine(L.CRAFT_SHOW_TITLE, 1, 0.82, 0)
				tt:AddLine(L.CRAFT_SHOW_TIP:format(C.CRAFT_SHOW), 1, 1, 1, true)
				tt:AddLine(it.show and L.CRAFT_SHOW_OFF or L.CRAFT_SHOW_ON, 0.5, 0.83, 0.76)
			end or nil
			r.name:SetWidth(star and RECIPE_NAME_W - 18 or RECIPE_NAME_W)
			r.toggle:SetShown(Reagents(it) ~= nil)
			r.toggle:SetTexture(open and MINUS or PLUS)
			local lines = open and Views.CraftReagents(d) or {}
			for j, text in ipairs(lines) do
				local fs = ReagentLine(r, j)
				fs:SetText(text)
				fs:Show()
			end
			for j = #lines + 1, #r.lines do r.lines[j]:Hide() end
			r.tip = Views.CraftRecipeTip(it.id, open, it.show ~= nil and not own)
		end
		index = index + 1
	end
end

local function BuildCard()
	card = CreateFrame("Frame", nil, side)
	card:SetAllPoints(side)
	card.name = Label(card, 0, 0, nil, "GameFontNormal")
	card.line = Label(card, 0, 18, nil, "GameFontHighlightSmall")
	card.note = Label(card, 0, 34, nil, "GameFontDisableSmall")
	card.state = Label(card, 0, 88, nil, "GameFontDisableSmall")
	-- Поиск в списке рецептов этого мастера: отсеивает по названию с первого знака.
	card.query = ""
	card.search = Input(card, SIDE_W - 24, 60)
	card.search:SetHeight(20)
	card.search:SetPoint("TOPLEFT", 0, -102)
	card.searchHint = FS(card.search, "GameFontDisableSmall")
	card.searchHint:SetPoint("LEFT", 8, 0)
	card.searchHint:SetText(L.CRAFT_RECIPE_SEARCH)
	card.search:SetScript("OnTextChanged", function(self)
		card.searchHint:SetShown((self:GetText() or "") == "" and not self:HasFocus())
		recipeToken = recipeToken + 1
		local token = recipeToken
		ns.After(SEARCH_DELAY, "crafters recipe search", function()
			if token ~= recipeToken then return end
			card.query = self:GetText() or ""
			card.scroll:SetVerticalScroll(0)
			Pane.Render()
		end)
	end)
	card.search:SetScript("OnEditFocusGained", function() card.searchHint:Hide() end)
	card.search:SetScript("OnEditFocusLost", function(self) card.searchHint:SetShown((self:GetText() or "") == "") end)
	TextTip(card.search, L.CRAFT_RECIPE_SEARCH, L.CRAFT_RECIPE_SEARCH_TIP)
	card.scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	card.scroll:SetPoint("TOPLEFT", 0, -126)
	card.scroll:SetSize(SIDE_W - 24, RECIPES_H)
	-- Прокрутка сбрасывается и до первой отрисовки карточки (Open): список пока пуст.
	card.items, card.tops, card.total, card.listH = {}, {}, 0, RECIPES_H
	card.child = CreateFrame("Frame", nil, card.scroll)
	card.child:SetSize(SIDE_W - 24, 10)
	card.scroll:SetScrollChild(card.child)
	card.scroll:HookScript("OnVerticalScroll", function() ns.SafeCall("crafters recipes", PlaceRecipes) end)
	card.empty = FS(card, "GameFontDisableSmall")
	card.empty:SetPoint("TOPLEFT", card.scroll, "TOPLEFT", 4, -4)
	card.empty:SetWidth(SIDE_W - 32)
	card.empty:SetText(L.CRAFT_RECIPE_NONE)
	-- Рецепты персональных при поднятии предметов мастер передать не сможет, поэтому они скрыты.
	-- Переключатель справа от поиска есть, пока такие рецепты есть в списке.
	card.bound = Chip(card, "", "bound", function()
		card.scroll:SetVerticalScroll(0)
		ns.Crafters.SetShowBound(not ns.Crafters.ShowBound())
	end)
	Tip(card.bound, function(tt)
		tt:AddLine(L.CRAFT_BOUND_TITLE, 1, 0.82, 0)
		tt:AddLine(L.CRAFT_BOUND_TIP, 1, 1, 1, true)
		tt:AddLine(ns.Crafters.ShowBound() and L.CRAFT_BOUND_HIDE or L.CRAFT_BOUND_SHOW, 0.5, 0.83, 0.76)
	end)
	card.whisper = Button(card, L.CRAFT_WHISPER, 86, "card whisper", function()
		local c = viewing and ns.Crafters.Get(viewing)
		if c then Whisper(c.name) end
	end)
	card.whisper:SetPoint("BOTTOMLEFT", 0, 2)
	card.refresh = Button(card, L.CRAFT_REFRESH, 124, "refresh", Refresh)
	card.refresh:SetPoint("LEFT", card.whisper, "RIGHT", 4, 0)
	Tip(card.refresh, function(tt)
		if viewing == nil or viewing ~= ns.myKey then
			tt:AddLine(L.CRAFT_REFRESH, 1, 0.82, 0)
			tt:AddLine(L.CRAFT_REFRESH_TIP, 1, 1, 1, true)
		elseif ns.Crafters.Posted() then
			tt:AddLine(L.CRAFT_UPDATE, 1, 0.82, 0)
			tt:AddLine(L.CRAFT_UPDATE_TIP, 1, 1, 1, true)
		else
			tt:AddLine(L.CRAFT_POST, 1, 0.82, 0)
			tt:AddLine(L.CRAFT_POST_TIP, 1, 1, 1, true)
		end
	end)
	card.back = Button(card, L.CRAFT_BACK, 64, "back", function() Open(nil) end)
	card.back:SetPoint("BOTTOMRIGHT", 0, 2)
end

local function RenderCard(view)
	card.name:SetText(view.name)
	card.line:SetText(view.line)
	card.note:SetText(view.note or "")
	-- «Алхимия 1/75», если все профессии помещаются в ширину панели, иначе только «1/75».
	local full = 0
	for i, p in ipairs(view.profs) do
		local chip = CardChip(i)
		chip:SetLabel(Views.CraftIcon(p.id, 14) .. " " .. ns.Crafters.ProfName(p.id) .. " " .. Views.CraftSkill(p))
		full = full + chip.w + 4
	end
	local x = 0
	for i, p in ipairs(view.profs) do
		local chip = CardChip(i)
		chip.id = p.id
		if full - 4 > SIDE_W then chip:SetLabel(Views.CraftIcon(p.id, 14) .. " " .. Views.CraftSkill(p)) end
		chip.tip = function(tt)
			tt:AddLine(ns.Crafters.ProfName(p.id), 1, 0.82, 0)
			tt:AddLine(L.CRAFT_TIP_PROF:format(ns.Crafters.ProfName(p.id), p.skill, p.max, p.n), 1, 1, 1, true)
		end
		chip:ClearAllPoints()
		chip:SetPoint("TOPLEFT", card, "TOPLEFT", x, -62)
		chip:Show()
		Mark(chip, p.id == viewProf)
		x = x + chip.w + 4
	end
	for i = #view.profs + 1, #cardChips do cardChips[i]:Hide() end
	-- Фильтр уровня задают поля над каталогом; в карточке под состоянием видно, что он действует.
	local listState = cardWhy or (viewProf and Views.CraftListState(view.key, viewProf)) or ""
	if view.mine then listState = listState ~= "" and (listState .. "\n" .. view.mine) or view.mine end
	local note = Views.CraftLevelNote(levels)
	if note then listState = listState ~= "" and (listState .. "\n" .. note) or note end
	card.state:SetText(listState)
	local total, bound
	if viewProf then
		card.items, total, bound = Views.CraftRecipes(view.key, viewProf, query, card.query, levels)
	else
		card.items, total, bound = {}, 0, 0
	end
	-- Состояние бывает в две строки (отказ, «Мастер изменил список»): поле поиска и список встают
	-- под него, а список становится короче. Справа от поля — переключатель персональных.
	local top = 88 + math.max(12, math.ceil(card.state:GetStringHeight() or 0)) + 2
	local width = SIDE_W - 24
	card.bound:SetShown(bound > 0)
	if bound > 0 then
		card.bound:SetLabel(L.CRAFT_BOUND:format(bound))
		Mark(card.bound, ns.Crafters.ShowBound())
		card.bound:ClearAllPoints()
		card.bound:SetPoint("TOPRIGHT", card, "TOPLEFT", width, -top)
		width = width - card.bound.w - 4
	end
	card.search:SetWidth(width)
	card.search:ClearAllPoints()
	card.search:SetPoint("TOPLEFT", 0, -top)
	card.scroll:ClearAllPoints()
	card.scroll:SetPoint("TOPLEFT", 0, -(top + 24))
	card.listH = math.max(RECIPE_H, math.min(RECIPES_H, LIST_BOTTOM - top - 24))
	card.scroll:SetHeight(card.listH)
	Resize()
	-- Пусто: ничего не подошло под поиск, нет рецептов этих уровней или все подходящие — персональные.
	card.empty:SetShown(#card.items == 0 and total > 0)
	local why = L.CRAFT_RECIPE_NONE
	if card.query == "" and bound > 0 then
		why = L.CRAFT_RECIPE_ALL_BOUND
	elseif card.query == "" and levels then
		why = L.CRAFT_RECIPE_NO_LEVEL
	end
	card.empty:SetText(why)
	card.whisper:SetShown(not view.own)
	card.whisper:SetEnabled(view.whisper)
	card.refresh:Show()
	card.refresh:SetText(view.own and (view.posted and L.CRAFT_UPDATE or L.CRAFT_POST) or L.CRAFT_REFRESH)
	card.refresh:ClearAllPoints()
	if view.own then
		card.refresh:SetPoint("BOTTOMLEFT", 0, 2)
		card.refresh:SetEnabled(not view.posted or ns.Crafters.Dirty())
	else
		card.refresh:SetPoint("LEFT", card.whisper, "RIGHT", 4, 0)
		local state = viewProf and ns.Crafters.AskState(view.key, viewProf)
		card.refresh:SetEnabled(not (state and state.loading))
	end
end

local function RenderSide()
	local view = viewing and Views.CraftCard(viewing)
	if viewing and not view then viewing, viewProf = nil, nil end
	mine:SetShown(view == nil)
	card:SetShown(view ~= nil)
	if view then RenderCard(view) else RenderMine() end
end

---------------------------------------------------------------------------
-- Вкладка
---------------------------------------------------------------------------
function Pane.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	BuildList()
	side = CreateFrame("Frame", nil, pane)
	side:SetPoint("TOPLEFT", SIDE_X, -8)
	side:SetSize(SIDE_W, 324)
	BuildMine()
	BuildCard()
	Pane.frames.pane, Pane.frames.rows, Pane.frames.filters = pane, rows, filters
	Pane.frames.search, Pane.frames.mine, Pane.frames.card = search, mine, card
	Pane.frames.profs, Pane.frames.cardChips, Pane.frames.all = profRows, cardChips, allChip
	Pane.frames.empty, Pane.frames.loaded, Pane.frames.recipes = empty, loaded, recipeRows
	Pane.frames.levelLo, Pane.frames.levelHi = levelLo, levelHi
	pane:Hide()
	return pane
end

function Pane.Render()
	if not pane or not pane:IsShown() then return end
	RenderList()
	RenderSide()
end

function Pane.Show()
	if not pane then return end
	pane:Show()
	mine.note:SetText(ns.Crafters.Note())
	Pane.Render()
end

function Pane.Hide()
	if not pane or not pane:IsShown() then return end
	search:ClearFocus()
	levelLo:ClearFocus()
	levelHi:ClearFocus()
	card.search:ClearFocus()
	mine.note:ClearFocus()
	pane:Hide()
end

-- Поиск из кода (тесты): сразу, без паузы на набор.
function Pane.Search(text)
	if not search then return end
	search:SetText(text or "")
	searchToken = searchToken + 1
	query = text or ""
	Pane.Render()
end

-- Уровни из кода (тесты): сразу, без паузы на набор.
function Pane.Levels(lo, hi)
	if not levelLo then return end
	levelLo:SetText(lo and tostring(lo) or "")
	levelHi:SetText(hi and tostring(hi) or "")
	searchToken = searchToken + 1
	levels = Views.CraftLevels(lo, hi)
	if list then list:SetVerticalScroll(0) end
	Pane.Render()
end

-- Поиск в списке рецептов открытой карточки из кода (тесты): сразу, без паузы на набор.
function Pane.SearchRecipes(text)
	if not card then return end
	card.search:SetText(text or "")
	recipeToken = recipeToken + 1
	card.query = text or ""
	card.scroll:SetVerticalScroll(0)
	Pane.Render()
end

-- Изменения каталога, своей карточки и названий рецептов рисуем сразу. Давность карточек
-- обновляет общий тик окна (UI.lua) раз в полминуты.
local function Redraw()
	if pane and pane:IsVisible() then Pane.Render() end
end
ns.On("CRAFTERS", Redraw)
ns.On("CRAFTERS_NAMES", Redraw)
ns.On("ONLINE", Redraw)
