-- Chillzone: вкладка «Желания». Слева — предметы, которые ищут игроки объединения, с поиском по
-- названию, имени и гильдии; справа — свой список (поле, «Сохранить», «Очистить», переключатель
-- подсказки) или карточка выбранного предмета: кому он нужен, с шёпотом. Строки готовит
-- Views.lua, логика — в Wishes.lua.
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
local SIDE_X, SIDE_W = 512, 282
local ROW_H = 38
local PERSON_H = 22
local LIST_TOP = 36
local SEARCH_DELAY = 0.25
local ACTION_W = 84
local NO_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local EDIT_H = 176

local pane, search, searchHint, counter, list, listChild, empty, side
local mine, card
local rows, people = {}, {}
local query = ""
local viewing -- номер предмета на правой панели; nil — свой список
local mineWhy -- итог последнего «Сохранить»: показывается до следующего
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
		ns.SafeCall("wishes tooltip", self.tip, GameTooltip)
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

-- Подсказка предмета, как в игре: в неё же Wishes.lua допишет «Нужно:».
local function ItemTip(owner, id)
	owner.tip = function(tt)
		if not pcall(tt.SetHyperlink, tt, "item:" .. id) then tt:AddLine(Views.WishItemName(id), 1, 1, 1) end
	end
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
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(30, 30)
	r.icon:SetPoint("LEFT", 4, 0)
	r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 40, -5)
	r.name:SetWidth(LIST_W - 40 - ACTION_W)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 40, 6)
	r.sub:SetWidth(LIST_W - 46)
	r.count = FS(r, "GameFontDisableSmall", "RIGHT")
	r.count:SetPoint("TOPRIGHT", -6, -6)
	r.count:SetWidth(ACTION_W)
	for _, fs in ipairs({ r.name, r.sub, r.count }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self)
		if self.it then ns.SafeCall("wishes: open", Open, self.it.id) end
	end)
	Tip(r, nil)
	rows[i] = r
	return r
end

local function RenderList()
	local items, total, hidden = Views.WishRows(query)
	local y = 0
	for i, it in ipairs(items) do
		local r = Row(i)
		r.it = it
		ItemTip(r, it.id)
		r:ClearAllPoints()
		r:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -y)
		y = y + ROW_H + 2
		r.mine:SetShown(it.mine)
		r.picked:SetShown(viewing == it.id)
		r.icon:SetTexture(it.icon or NO_ICON)
		r.name:SetText(it.name)
		r.sub:SetText(it.sub)
		r.count:SetText(it.count > 1 and L.WISH_COUNT:format(it.count) or "")
		r:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	listChild:SetHeight(math.max(y, 10))
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
-- Справа: свой список
---------------------------------------------------------------------------
local function Save()
	local ok, a, b, c = ns.Wishes.Save(mine.edit:GetText())
	mine.edit:ClearFocus()
	if not ok and a == "unknown" then
		mineWhy = "|cffff9933" .. L.WISH_UNKNOWN:format(table.concat(b, ", ")) .. "|r"
	elseif not ok then
		mineWhy = Views.WishWhy(a, b)
	elseif a == 0 then
		mine.edit:SetText(ns.Wishes.Text())
		mineWhy = L.WISH_CLEARED
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
		local top, at, view = -(y or 0), scroll:GetVerticalScroll(), scroll:GetHeight() or EDIT_H
		if top < at then
			scroll:SetVerticalScroll(top)
		elseif top + (h or 0) > at + view then
			scroll:SetVerticalScroll(top + (h or 0) - view)
		end
	end)
	scroll:SetScrollChild(edit)
	-- Щелчок по пустому месту под строками тоже ставит курсор.
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
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
	Tip(card.icon, nil)
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
	local view = Views.WishItem(viewing)
	card.icon.tex:SetTexture(view.icon or NO_ICON)
	ItemTip(card.icon, view.id)
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
	side:SetSize(SIDE_W, 324)
	BuildMine()
	BuildCard()
	Pane.frames.pane, Pane.frames.rows, Pane.frames.search = pane, rows, search
	Pane.frames.mine, Pane.frames.card, Pane.frames.people, Pane.frames.empty = mine, card, people, empty
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
	mine.edit:SetText(ns.Wishes.Text())
	mineWhy = nil
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

-- Изменения списков и догруженные названия предметов рисуем сразу. Давность списков обновляет
-- общий тик окна (UI.lua) раз в полминуты.
local function Redraw()
	if pane and pane:IsVisible() then Pane.Render() end
end
ns.On("WISHES", Redraw)
ns.On("CRAFTERS_NAMES", Redraw)
ns.On("ONLINE", Redraw)
