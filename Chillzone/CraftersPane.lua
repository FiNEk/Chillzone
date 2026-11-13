-- Chillzone: вкладка «Мастера». Слева каталог мастеров объединения с поиском и фильтром по
-- профессии, справа — своё ремесло (прочитанные профессии, примечание, своя карточка) или
-- карточка выбранного мастера со списком его рецептов. Строки готовит Views.lua, логика — в
-- Crafters.lua.
--
-- Поля ввода — свои EditBox, штатные popup и выпадающие списки не используются (taint). Поле
-- ввода и окна чата игры вкладка не трогает: «Шепнуть» открывает шёпот на вкладке чата окна.
local ADDON, ns = ...

local L = ns.L
local C = ns.Config
local Codec = ns.Codec
local Views = ns.Views

local Pane = { frames = {} }
ns.CraftersPane = Pane

local LIST_W = 468 -- каталог; справа от него полоса прокрутки
local SIDE_X, SIDE_W = 512, 282
local ROW_H = 38
local ACTION_W, INFO_W = 84, 70
local PROF_ROWS = 6
local LIST_TOP = 60
local SEARCH_DELAY = 0.25

local pane, search, searchHint, loaded, list, listChild, empty, side
local mine, card
local rows, filters, profRows, cardChips, recipeRows = {}, {}, {}, {}, {}
local allChip
local filter -- номер профессии или nil — все
local query = ""
local viewing, viewProf -- мастер и его профессия на правой панели; nil — своё ремесло
local mineWhy, cardWhy -- отказ последнего действия: показывается до следующего
local searchToken = 0

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

local function Whisper(name)
	ns.UI.Toggle("chat")
	ns.ChatPane.WhisperTo(name)
end

---------------------------------------------------------------------------
-- Каталог
---------------------------------------------------------------------------
-- Своя строка открывает свою размещённую карточку, как её видят остальные, со своим списком
-- рецептов; «Назад» возвращает к «Моему ремеслу».
local function Open(key)
	cardWhy = nil
	local own = key ~= nil and key == ns.myKey
	local c
	if own then c = ns.Crafters.Own() elseif key then c = ns.Crafters.Get(key) end
	if not key or own and not c then
		viewing, viewProf = nil, nil
		Pane.Render()
		return
	end
	viewing, viewProf = key, nil
	for _, p in ipairs(c and c.profs or {}) do
		if p.id == filter then viewProf = p.id end
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
	r.right = FS(r, "GameFontHighlightSmall", "RIGHT")
	r.right:SetPoint("TOPRIGHT", -(ACTION_W + 4), -6)
	r.right:SetWidth(INFO_W)
	local textWidth = LIST_W - 6 - ACTION_W - INFO_W - 12
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 6, -5)
	r.name:SetWidth(textWidth)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 6, 6)
	r.sub:SetWidth(LIST_W - 6 - ACTION_W - 8)
	for _, fs in ipairs({ r.name, r.sub, r.right, r.status }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self)
		if self.it then ns.SafeCall("crafters: open", Open, self.it.key) end
	end)
	Tip(r, nil)
	rows[i] = r
	return r
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

local function RenderList()
	RenderFilters()
	local items, total, found = Views.CraftRows(filter, query)
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
		r.right:SetText(it.right or "")
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
		if list then list:SetVerticalScroll(0) end
		Pane.Render()
	end)
end

local function BuildList()
	search = Input(pane, 220, 60)
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
	loaded = FS(pane, "GameFontDisableSmall", "RIGHT")
	loaded:SetPoint("TOPRIGHT", pane, "TOPLEFT", LIST_W + 8, -11)
	loaded:SetWidth(LIST_W - 240)

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
	mine.post = Button(mine, L.CRAFT_POST, 150, "post", Post)
	mine.post:SetPoint("BOTTOMLEFT", 0, 2)
	mine.withdraw = Button(mine, L.CRAFT_WITHDRAW, 110, "withdraw", Withdraw)
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

local function Refresh()
	if not viewing or not viewProf or viewing == ns.myKey then return end
	local ok, why = ns.Crafters.Want(viewing, viewProf, true)
	cardWhy = not ok and why ~= "busy" and Views.CraftWhy(why) or nil
	Pane.Render()
end

-- Список рецептов в карточке: строка — значок и название, щелчок раскрывает под ней реагенты,
-- по одному на строку. Рамок столько, сколько видно, их содержимое меняется при прокрутке: у
-- мастера бывает несколько сотен рецептов.
local RECIPE_H, REAGENT_H, RECIPES_H = 22, 16, 188
local RECIPE_ROWS = math.ceil(RECIPES_H / RECIPE_H) + 1
local NO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
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
	local most = math.max(0, card.total - RECIPES_H)
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

local function RecipeRow(i)
	local r = CreateFrame("Button", nil, card.child)
	r:SetSize(SIDE_W - 26, RECIPE_H)
	r.hl = r:CreateTexture(nil, "HIGHLIGHT")
	r.hl:SetAllPoints()
	r.hl:SetColorTexture(1, 1, 1, 0.07)
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(18, 18)
	r.icon:SetPoint("TOPLEFT", 2, -2)
	r.toggle = r:CreateTexture(nil, "ARTWORK")
	r.toggle:SetSize(14, 14)
	r.toggle:SetPoint("TOPRIGHT", -4, -4)
	r.name = FS(r, "GameFontHighlightSmall")
	r.name:SetPoint("TOPLEFT", 26, -5)
	r.name:SetWidth(SIDE_W - 26 - 26 - 22)
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
		if it and card.tops[index] >= offset + RECIPES_H then it = nil end
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
			r.toggle:SetShown(Reagents(it) ~= nil)
			r.toggle:SetTexture(open and MINUS or PLUS)
			local lines = open and Views.CraftReagents(d) or {}
			for j, text in ipairs(lines) do
				local fs = ReagentLine(r, j)
				fs:SetText(text)
				fs:Show()
			end
			for j = #lines + 1, #r.lines do r.lines[j]:Hide() end
			r.tip = Views.CraftRecipeTip(it.id, open)
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
	card.scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	card.scroll:SetPoint("TOPLEFT", 0, -104)
	card.scroll:SetSize(SIDE_W - 24, RECIPES_H)
	card.child = CreateFrame("Frame", nil, card.scroll)
	card.child:SetSize(SIDE_W - 24, 10)
	card.scroll:SetScrollChild(card.child)
	card.scroll:HookScript("OnVerticalScroll", function() ns.SafeCall("crafters recipes", PlaceRecipes) end)
	card.whisper = Button(card, L.CRAFT_WHISPER, 86, "card whisper", function()
		local c = viewing and ns.Crafters.Get(viewing)
		if c then Whisper(c.name) end
	end)
	card.whisper:SetPoint("BOTTOMLEFT", 0, 2)
	card.refresh = Button(card, L.CRAFT_REFRESH, 124, "refresh", Refresh)
	card.refresh:SetPoint("LEFT", card.whisper, "RIGHT", 4, 0)
	TextTip(card.refresh, L.CRAFT_REFRESH, L.CRAFT_REFRESH_TIP)
	card.back = Button(card, L.CRAFT_BACK, 64, "back", function() Open(nil) end)
	card.back:SetPoint("BOTTOMRIGHT", 0, 2)
end

local function RenderCard(view)
	card.name:SetText(view.name)
	card.line:SetText(view.line)
	card.note:SetText(view.note or "")
	local x = 0
	for i, p in ipairs(view.profs) do
		local chip = CardChip(i)
		chip.id = p.id
		chip:SetLabel(Views.CraftIcon(p.id, 14) .. " " .. p.skill)
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
	card.state:SetText(cardWhy or (viewProf and Views.CraftListState(view.key, viewProf)) or "")
	card.items = viewProf and Views.CraftRecipes(view.key, viewProf, query) or {}
	Resize()
	card.whisper:SetShown(not view.own)
	card.refresh:SetShown(not view.own)
	card.whisper:SetEnabled(view.whisper)
	local state = viewProf and ns.Crafters.AskState(view.key, viewProf)
	card.refresh:SetEnabled(not (state and state.loading))
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

-- Изменения каталога, своей карточки и названий рецептов рисуем сразу. Давность карточек
-- обновляет общий тик окна (UI.lua) раз в полминуты.
local function Redraw()
	if pane and pane:IsVisible() then Pane.Render() end
end
ns.On("CRAFTERS", Redraw)
ns.On("CRAFTERS_NAMES", Redraw)
