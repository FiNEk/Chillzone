-- Chillzone: вкладка «Желания». Слева — предметы, которые ищут игроки объединения, с поиском по
-- названию, имени и гильдии; справа — свой список (поле, «Сохранить», «Очистить», переключатель
-- подсказки) или карточка выбранного предмета: кому он нужен, с шёпотом. Строки готовит
-- Views.lua, логика — в Wishes.lua.
--
-- Список предметов собирается заново только при изменении данных и не чаще раза в REDRAW_GAP; на
-- прокрутке и растягивании окна кнопки есть лишь у видимых строк, они перекладываются без нового
-- сбора. Значок и название — только для видимых строк.
--
-- Поля ввода — свои EditBox, штатные popup не используются (taint). Ссылку на предмет в своё
-- поле вставляет Shift+щелчок: ChatLinks.lua после вставки игры (пост-хук) отдаёт её
-- WishesPane.FocusedInput. Поле ввода и окна чата игры вкладка не трогает: «Шепнуть» и меню
-- правого щелчка открывают шёпот через ChatPane.Whisper.
local ADDON, ns = ...

local L = ns.L
local C = ns.Config
local Views = ns.Views

local Pane = { frames = {} }
ns.WishesPane = Pane

local LIST_W = 468 -- список предметов; справа от него полоса прокрутки
local SIDE_X, SIDE_W = 512, 328 -- как у «Мастеров»: панель во всю ширину наименьшего окна
local ROW_H, ROW_STEP = 38, 40
local PERSON_H = 22
local LIST_TOP = 36
local SEARCH_DELAY = 0.25
local REDRAW_GAP = 1 -- новые списки, названия и онлайн перерисовывают вкладку не чаще
local ACTION_W = 84
local NO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local EDIT_H = 176
-- Ширины заданы под наименьшее окно (вставка 850 в ширину), высоты — под исходную вставку 340.
-- Растянутое окно (Layout) отдаёт лишнюю ширину списку предметов, а правая панель той же ширины
-- стоит у правого края и растёт вниз: выше поле своего списка и список игроков у предмета.
local BASE_W, BASE_H, SIDE_V = 850, 340, 16
local listW, sideX, listH, editH = LIST_W, SIDE_X, BASE_H - LIST_TOP - 8, EDIT_H

local pane, search, searchHint, counter, list, listChild, empty, side, divider
local mine, card
local rows, people = {}, {}
local items = {} -- собранные строки (Views.WishRows), кнопки — только у видимых
local query = ""
local viewing -- номер предмета на правой панели; nil — свой список
local mineWhy -- итог последнего «Сохранить»: показывается до следующего
local searchToken = 0
local redrawAt -- когда уйдёт отложенная перерисовка; nil — не ждём

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
		ns.SafeCall("wishes tooltip", self.tip, GameTooltip, self)
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

-- Подсказка предмета, как в игре: в неё же Wishes.lua допишет «Нужно:». Номер — в owner.item:
-- одно замыкание на кнопку, а не на каждую перерисовку.
local function ItemTip(tt, owner)
	local id = owner and owner.item
	if not id then return end
	if not pcall(tt.SetHyperlink, tt, "item:" .. id) then tt:AddLine(Views.WishItemName(id), 1, 1, 1) end
end

local function Button(parent, text, width, where, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function(self) ns.SafeCall("wishes: " .. where, fn, self) end)
	return b
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
	ns.ChatPane.Whisper(name)
end

---------------------------------------------------------------------------
-- Список предметов
---------------------------------------------------------------------------
local PlaceRows

local function Open(id)
	viewing = id
	if card and card.scroll then card.scroll:SetVerticalScroll(0) end
	Pane.Render()
end
Pane.Open = Open

local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, listChild)
	r:SetWidth(listW)
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
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(30, 30)
	r.icon:SetPoint("LEFT", 4, 0)
	r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 40, -5)
	r.name:SetWidth(listW - 40 - ACTION_W)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 40, 6)
	r.sub:SetWidth(listW - 46)
	r.count = FS(r, "GameFontDisableSmall", "RIGHT")
	r.count:SetPoint("TOPRIGHT", -6, -6)
	r.count:SetWidth(ACTION_W)
	for _, fs in ipairs({ r.name, r.sub, r.count }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self)
		if self.it then ns.SafeCall("wishes: open", Open, self.it.id) end
	end)
	Tip(r, ItemTip)
	rows[i] = r
	return r
end

-- Сколько строк помещается в видимую часть списка, с запасом на неполную сверху и снизу.
local function RowCount()
	return math.ceil(listH / ROW_STEP) + 1
end

-- Видимые строки по текущей прокрутке: кнопки только у них.
function PlaceRows()
	local offset = list:GetVerticalScroll() or 0
	local first = math.max(1, math.floor(offset / ROW_STEP) + 1)
	local n = RowCount()
	for i = 1, n do
		local r = rows[i] or Row(i)
		local index = first + i - 1
		local it = items[index]
		r.it, r.item = it, it and it.id
		r:SetShown(it ~= nil)
		if it then
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -(index - 1) * ROW_STEP)
			r.mine:SetShown(it.mine)
			r.picked:SetShown(viewing == it.id)
			r.icon:SetTexture(ns.Crafters.ItemIcon(it.id) or NO_ICON)
			-- Название могло догрузиться после сборки: видимые строки берут свежее.
			r.name:SetText(it.known and it.name or Views.WishItemName(it.id))
			r.sub:SetText(Views.WishSub(it.id))
			r.count:SetText(it.count > 1 and L.WISH_COUNT:format(it.count) or "")
		end
	end
	-- Окно стало ниже: строки сверх нужных остались от высокого.
	for i = n + 1, #rows do rows[i]:Hide() end
end

local function RenderList()
	local total, hidden
	items, total, hidden = Views.WishRows(query)
	listChild:SetHeight(math.max(#items * ROW_STEP, 10))
	PlaceRows()
	empty:SetShown(#items == 0)
	if not ns.IsMember() then
		empty:SetText(L.WISH_NOT_MEMBER)
	elseif total > 0 then
		empty:SetText(L.WISH_EMPTY_FILTER:format(total))
	else
		empty:SetText(L.WISH_EMPTY)
	end
	local n = ns.Wishes.Count()
	counter:SetText(hidden > 0 and L.WISH_HIDDEN:format(hidden) or (n > 0 and L.WISH_LISTS:format(n) or ""))
end

local function Searched()
	searchToken = searchToken + 1
	local token = searchToken
	ns.After(SEARCH_DELAY, "wishes search", function()
		if token ~= searchToken or not search then return end
		query = search:GetText() or ""
		if list then list:SetVerticalScroll(0) end
		Pane.Render()
	end)
end

local function BuildList()
	search = Input(pane, 240, 60)
	search:SetPoint("TOPLEFT", 8, -6)
	searchHint = FS(search, "GameFontDisableSmall")
	searchHint:SetPoint("LEFT", 8, 0)
	searchHint:SetText(L.WISH_SEARCH)
	search:SetScript("OnTextChanged", function(self)
		searchHint:SetShown((self:GetText() or "") == "" and not self:HasFocus())
		Searched()
	end)
	search:SetScript("OnEditFocusGained", function() searchHint:Hide() end)
	search:SetScript("OnEditFocusLost", function(self) searchHint:SetShown((self:GetText() or "") == "") end)
	TextTip(search, L.WISH_SEARCH, L.WISH_SEARCH_TIP)
	counter = FS(pane, "GameFontDisableSmall", "RIGHT")
	counter:SetPoint("RIGHT", pane, "TOPLEFT", LIST_W + 8, -17)
	counter:SetWidth(LIST_W - 260)

	list = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	list:SetPoint("TOPLEFT", 8, -LIST_TOP)
	list:SetPoint("BOTTOMLEFT", 8, 8)
	list:SetWidth(LIST_W)
	listChild = CreateFrame("Frame", nil, list)
	listChild:SetSize(LIST_W, 10)
	list:SetScrollChild(listChild)
	list:HookScript("OnVerticalScroll", function() ns.SafeCall("wishes rows", PlaceRows) end)
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
-- Справа: свой список
---------------------------------------------------------------------------
local function Save()
	local had = ns.Wishes.Posted()
	local ok, a, b, c = ns.Wishes.Save(mine.edit:GetText())
	mine.edit:ClearFocus()
	if not ok and a == "unknown" then
		mineWhy = "|cffff9933" .. L.WISH_UNKNOWN:format(table.concat(b, ", ")) .. "|r"
	elseif not ok then
		mineWhy = Views.WishWhy(a, b)
	elseif a == 0 then
		mine.edit:SetText(ns.Wishes.Text())
		-- Снимать было нечего: очищено только поле.
		mineWhy = had and L.WISH_CLEARED or L.WISH_CLEARED_DRAFT
	else
		mine.edit:SetText(ns.Wishes.Text())
		local notes = {}
		if #b > 0 then notes[#notes + 1] = L.WISH_UNKNOWN:format(table.concat(b, ", ")) end
		if c > 0 then notes[#notes + 1] = L.WISH_TOO_MANY:format(c, C.WISH_ITEMS) end
		mineWhy = #notes > 0 and ("|cffff9933" .. table.concat(notes, " ") .. "|r") or nil
	end
	Pane.Render()
end

local function Clear()
	mine.edit:SetText("")
	Save()
end

local function BuildMine()
	mine = CreateFrame("Frame", nil, side)
	mine:SetAllPoints(side)
	mine.title = Label(mine, 0, 0, L.WISH_MINE, "GameFontNormal")
	mine.hint = Label(mine, 0, 18, L.WISH_MINE_HINT, "GameFontDisableSmall")
	-- Многострочное поле в своей прокрутке: список бывает длиннее поля.
	local scroll = CreateFrame("ScrollFrame", nil, mine, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 0, -50)
	scroll:SetSize(SIDE_W - 24, EDIT_H)
	local bg = mine:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", -2, 2)
	bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 2, -2)
	bg:SetColorTexture(0, 0, 0, 0.55)
	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject("ChatFontNormal")
	edit:SetTextInsets(4, 4, 4, 4)
	edit:SetWidth(SIDE_W - 24)
	edit:SetMaxBytes(4000)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnTextChanged", function(self, user)
		if user then
			mineWhy = nil
			Pane.RenderMine()
		end
	end)
	-- Прокрутка идёт за курсором: длинный список не уводит его из виду.
	edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
		local top, at = -(y or 0), scroll:GetVerticalScroll() or 0
		if top < at then
			scroll:SetVerticalScroll(top)
		elseif top + (h or 0) > at + editH then
			scroll:SetVerticalScroll(top + (h or 0) - editH)
		end
	end)
	scroll:SetScrollChild(edit)
	-- Предмет, взятый из сумки курсором, бросается в поле: Shift+щелчок по стопке в сумке игра
	-- считает невставленным (своего поля чата у неё нет) и открывает разделение стопки, а
	-- отменить это пост-хук не может. Бросок курсором окна разделения не открывает.
	local function Drop()
		local kind, _, link = GetCursorInfo()
		if kind ~= "item" or type(link) ~= "string" then return false end
		ClearCursor()
		-- В конец списка, с новой строки.
		local text = edit:GetText() or ""
		edit:SetCursorPosition(#text)
		if text ~= "" and not text:find("[\n,;]%s*$") then edit:Insert("\n") end
		edit:Insert(link .. "\n")
		edit:SetFocus()
		mineWhy = nil
		Pane.RenderMine()
		return true
	end
	edit:SetScript("OnReceiveDrag", function() ns.SafeCall("wishes: drop", Drop) end)
	edit:SetScript("OnMouseDown", function() ns.SafeCall("wishes: drop", Drop) end)
	-- Щелчок по пустому месту под строками тоже ставит курсор или принимает предмет.
	scroll:EnableMouse(true)
	scroll:SetScript("OnReceiveDrag", function() ns.SafeCall("wishes: drop", Drop) end)
	scroll:SetScript("OnMouseDown", function()
		if not Drop() then edit:SetFocus() end
	end)
	mine.scroll, mine.edit = scroll, edit
	mine.status = Label(mine, 0, 50 + EDIT_H + 8, nil, "GameFontHighlightSmall")
	local check = CreateFrame("CheckButton", nil, mine, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check:SetPoint("BOTTOMLEFT", -4, 26)
	check.label = FS(mine, "GameFontHighlightSmall")
	check.label:SetPoint("LEFT", check, "RIGHT", 0, 1)
	check.label:SetWidth(SIDE_W - 22)
	check.label:SetText(L.WISH_CHECK_TOOLTIP)
	check:SetScript("OnClick", function(self)
		ns.SafeCall("wishes: tooltip", ns.Wishes.SetShowTooltip, self:GetChecked() and true or false)
	end)
	TextTip(check, L.WISH_CHECK_TOOLTIP, L.WISH_CHECK_TOOLTIP_TIP)
	mine.tooltip = check
	mine.save = Button(mine, L.WISH_SAVE, 104, "save", Save)
	mine.save:SetPoint("BOTTOMLEFT", 0, 2)
	TextTip(mine.save, L.WISH_SAVE, L.WISH_SAVE_TIP)
	mine.clear = Button(mine, L.WISH_CLEAR, 86, "clear", Clear)
	mine.clear:SetPoint("BOTTOMRIGHT", 0, 2)
	TextTip(mine.clear, L.WISH_CLEAR, L.WISH_CLEAR_TIP)
end

function Pane.RenderMine()
	if not mine then return end
	local view = Views.WishMine()
	local typed = mine.edit:GetText() or ""
	local status = mineWhy or view.status
	if not mineWhy and typed ~= ns.Wishes.Text() then status = "|cffff9933" .. L.WISH_UNSAVED .. "|r" end
	mine.status:SetText(status)
	mine.tooltip:SetChecked(ns.Wishes.ShowTooltip())
	mine.clear:SetEnabled(view.posted or typed ~= "")
end

---------------------------------------------------------------------------
-- Справа: кому нужен предмет
---------------------------------------------------------------------------
local function Person(i)
	local p = people[i]
	if p then return p end
	p = CreateFrame("Button", nil, card.child)
	p:SetSize(SIDE_W - 24, PERSON_H)
	local hl = p:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	p.name = FS(p, "GameFontHighlightSmall")
	p.name:SetPoint("LEFT", 2, 0)
	p.name:SetWidth(SIDE_W - 24 - ACTION_W)
	if p.name.SetWordWrap then p.name:SetWordWrap(false) end
	p.right = FS(p, "GameFontHighlightSmall", "RIGHT")
	p.right:SetPoint("RIGHT", -2, 0)
	p.right:SetWidth(ACTION_W - 4)
	p.button = Button(p, L.CRAFT_WHISPER, ACTION_W - 4, "whisper", function()
		if p.it then Whisper(p.it.name) end
	end)
	p.button:SetHeight(20)
	p.button:SetPoint("RIGHT", -2, 0)
	p:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	p:SetScript("OnClick", function(self, button)
		if not self.it or not self.it.person then return end
		if button == "RightButton" then
			ns.SafeCall("wishes: menu", ns.ChatPane.OpenPersonMenu, self, self.it.person, Whisper)
		else
			Whisper(self.it.name)
		end
	end)
	Tip(p, nil)
	people[i] = p
	return p
end

local function BuildCard()
	card = CreateFrame("Frame", nil, side)
	card:SetAllPoints(side)
	card.icon = CreateFrame("Button", nil, card)
	card.icon:SetSize(36, 36)
	card.icon:SetPoint("TOPLEFT", 0, 0)
	card.icon.tex = card.icon:CreateTexture(nil, "ARTWORK")
	card.icon.tex:SetAllPoints()
	card.icon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	Tip(card.icon, ItemTip)
	card.title = FS(card, "GameFontNormal")
	card.title:SetPoint("TOPLEFT", 44, -2)
	card.title:SetWidth(SIDE_W - 44)
	card.sub = FS(card, "GameFontDisableSmall")
	card.sub:SetPoint("TOPLEFT", 44, -20)
	card.sub:SetWidth(SIDE_W - 44)
	card.scroll = CreateFrame("ScrollFrame", nil, card, "UIPanelScrollFrameTemplate")
	card.scroll:SetPoint("TOPLEFT", 0, -46)
	card.scroll:SetPoint("BOTTOMRIGHT", -24, 30)
	card.child = CreateFrame("Frame", nil, card.scroll)
	card.child:SetSize(SIDE_W - 24, 10)
	card.scroll:SetScrollChild(card.child)
	card.back = Button(card, L.WISH_BACK, 86, "back", function() Open(nil) end)
	card.back:SetPoint("BOTTOMLEFT", 0, 2)
end

local function RenderCard()
	-- Чужих в игре видно по спискам онлайна их гильдий: спрашиваются только гильдии открытого
	-- предмета, а не всех строк (Online.Want сам не спрашивает чаще ONLINE_REFRESH).
	for _, guild in ipairs(Views.WishGuilds(viewing)) do ns.Online.Want(guild) end
	local view = Views.WishItem(viewing)
	card.icon.tex:SetTexture(view.icon or NO_ICON)
	card.icon.item = view.id
	card.title:SetText(view.name)
	card.sub:SetText(L.WISH_CARD_SUB:format(#view.people))
	local y = 0
	for i, it in ipairs(view.people) do
		local p = Person(i)
		p.it, p.tip = it, it.tip
		p:ClearAllPoints()
		p:SetPoint("TOPLEFT", card.child, "TOPLEFT", 0, -y)
		y = y + PERSON_H
		p.name:SetText(it.text)
		p.button:SetShown(it.whisper)
		p.right:SetText(it.whisper and "" or it.right)
		p:Show()
	end
	for i = #view.people + 1, #people do people[i]:Hide() end
	card.child:SetHeight(math.max(y, 10))
end

local function RenderSide()
	-- Предмет, который больше никому не нужен, закрывается сам.
	if viewing and #ns.Wishes.Who(viewing) == 0 then viewing = nil end
	mine:SetShown(viewing == nil)
	card:SetShown(viewing ~= nil)
	if viewing then RenderCard() else Pane.RenderMine() end
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
	side:SetSize(SIDE_W, BASE_H - SIDE_V)
	BuildMine()
	BuildCard()
	Pane.frames.pane, Pane.frames.rows, Pane.frames.search = pane, rows, search
	Pane.frames.mine, Pane.frames.card, Pane.frames.people, Pane.frames.empty = mine, card, people, empty
	Pane.frames.list, Pane.frames.side = list, side
	pane:Hide()
	return pane
end

-- Раскладка под вставку width×height (UI.lua): список предметов шире и длиннее, правая панель у
-- правого края и выше — выше поле своего списка и список игроков (он привязан к низу панели).
-- live — игрок ещё тянет уголок: видимые строки только перекладываются, без нового сбора.
function Pane.Layout(width, height)
	if not pane then return end
	local extra = math.max(0, math.floor(width - BASE_W))
	local taller = math.max(0, math.floor(height - BASE_H))
	listW, sideX = LIST_W + extra, SIDE_X + extra
	listH, editH = BASE_H - LIST_TOP - 8 + taller, EDIT_H + taller
	list:SetWidth(listW)
	listChild:SetWidth(listW)
	empty:SetWidth(listW - 12)
	counter:ClearAllPoints()
	counter:SetPoint("RIGHT", pane, "TOPLEFT", listW + 8, -17)
	counter:SetWidth(listW - 260)
	for _, r in ipairs(rows) do
		r:SetWidth(listW)
		r.name:SetWidth(listW - 40 - ACTION_W)
		r.sub:SetWidth(listW - 46)
	end
	divider:ClearAllPoints()
	divider:SetPoint("TOPLEFT", sideX - 8, -10)
	divider:SetPoint("BOTTOMLEFT", sideX - 8, 10)
	side:ClearAllPoints()
	side:SetPoint("TOPLEFT", sideX, -8)
	side:SetHeight(BASE_H + taller - SIDE_V)
	mine.scroll:SetHeight(editH)
	mine.status:ClearAllPoints()
	mine.status:SetPoint("TOPLEFT", 0, -(50 + editH + 8))
	if pane:IsShown() then PlaceRows() end
end

function Pane.Render()
	if not pane or not pane:IsShown() then return end
	redrawAt = nil
	RenderList()
	RenderSide()
end

function Pane.Show()
	if not pane then return end
	local was = pane:IsShown()
	pane:Show()
	-- Поле заполняется из сохранённого только при открытии вкладки: общая перерисовка окна раз в
	-- полминуты не должна стирать набранное.
	if not was then
		mine.edit:SetText(ns.Wishes.Text())
		mineWhy = nil
	end
	Pane.Render()
end

function Pane.Hide()
	if not pane or not pane:IsShown() then return end
	search:ClearFocus()
	mine.edit:ClearFocus()
	pane:Hide()
end

-- Своё поле в фокусе: в него Shift+щелчок вставляет ссылку на предмет (ChatLinks.lua).
function Pane.FocusedInput()
	if pane and pane:IsVisible() and mine.edit:HasFocus() then return mine.edit end
end

-- Поиск из кода (тесты): сразу, без паузы на набор.
function Pane.Search(text)
	if not search then return end
	search:SetText(text or "")
	searchToken = searchToken + 1
	query = text or ""
	Pane.Render()
end

-- Новые списки, догруженные названия и онлайн перерисовывают вкладку не чаще раза в REDRAW_GAP:
-- в большом каталоге они приходят пачками. Давность списков обновляет общий тик окна (UI.lua).
local function Redraw()
	if not pane or not pane:IsVisible() or redrawAt then return end
	redrawAt = ns.Now() + REDRAW_GAP
	ns.After(REDRAW_GAP, "wishes redraw", function()
		if redrawAt and pane:IsVisible() then Pane.Render() end
		redrawAt = nil
	end)
end
ns.On("WISHES", Redraw)
ns.On("CRAFTERS_NAMES", Redraw)
ns.On("ONLINE", Redraw)
