-- Chillzone: вкладка «Перепись» — слева список гильдий, справа карточка выбранной, как вкладка
-- «Сведения» окна гильдии: крупные числа, руководство, полоса классов, гистограмма уровней,
-- зоны полосками. Данные — Views.CensusRows и Views.GuildCard; здесь только рисование.
-- Живёт во вставке окна (UI.lua body, у исходного окна 804×340). Ширины заданы под исходное окно;
-- растянутое окно отдаёт лишнюю ширину карточке (Layout), список гильдий остаётся прежним.
local ADDON, ns = ...

local L = ns.L
local Views = ns.Views

local CensusPane = {}
ns.CensusPane = CensusPane

local BAR = "Interface\\TargetingFrame\\UI-StatusBar"
local ROLE_ICON = {
	leader = "Interface\\GroupFrame\\UI-Group-LeaderIcon",
	officer = "Interface\\GroupFrame\\UI-Group-AssistantIcon",
}
local LIST_W, ROW_H = 236, 38
local CARD_X, CARD_W = 288, 486
local TILE_GAP = 8
local COL_L_W, COL_R_X = 200, 220
local COL_GAP = COL_R_X - COL_L_W
local LEVEL_BAR_H, PERSON_H, ZONE_H = 40, 16, 16
-- Вставка исходного окна; карточка — от CARD_X до полосы прокрутки у правого края.
local BASE_H, CARD_RIGHT = 340, 30 -- CARD_X + CARD_W + CARD_RIGHT = 804, ширина исходной вставки
-- Карточка и её колонки под ширину вставки (Layout): руководству — треть прибавки, остальное — классам.
local cardW, colLW, colRX = CARD_W, COL_L_W, COL_R_X
local colRW = cardW - colRX
local ZONE_NAME_W = 170
-- Строка «Все гильдии» над списком.
local ALL_KEY, ALL_H, ALL_TOP = "*", 26, 28
local ONLINE_TICK = 15 -- как часто открытая вкладка проверяет, не устарел ли список

-- Таблица людей в игре. Строк столько, сколько закрывает область прокрутки, с запасом на строку,
-- обрезанную сверху: у исходного окна она 322 в высоту и строк 22. Больше их не создаётся при
-- любой длине списка — только когда окно вытянули выше (Layout).
local TABLE_HEAD_H, TABLE_COLS = 18, 6
local CARD_V = 18 -- карточка короче вставки: отступ сверху и снизу
local function TableRows(h) return math.floor((h - CARD_V) / PERSON_H) + 2 end
local tableRows = TableRows(BASE_H)
local CLASS_ICONS = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
local ADDON_ICON = "Interface\\AddOns\\" .. ADDON .. "\\media\\icon"
-- icon — поле строки со значком: такая колонка рисует его вместо текста. w — ширина в исходном окне,
-- grow — доля колонки в прибавке ширины растянутого окна.
local COL_LEVEL = { key = "level", title = L.ONLINE_COL_LEVEL, w = 38, justify = "CENTER" }
local COL_CLASS = { key = "class", title = L.ONLINE_COL_CLASS, w = 50, justify = "CENTER", icon = "classIcon" }
local COL_NAME = { key = "name", title = L.ONLINE_COL_NAME, w = 150, grow = 2 }
local COL_ADDON = { key = "addon", title = L.ONLINE_COL_ADDON, w = 30, justify = "CENTER", icon = "addonIcon" }
local COL_RANK = { key = "rank", title = L.ONLINE_COL_RANK, w = 100, grow = 1 }
local TABLE_ALL = { COL_LEVEL, COL_CLASS, COL_NAME, COL_ADDON, { key = "guild", title = L.ONLINE_COL_GUILD, w = 118, grow = 1 }, COL_RANK }
local TABLE_MINE = { COL_LEVEL, COL_CLASS, COL_NAME, COL_ADDON, { key = "zone", title = L.ONLINE_COL_ZONE, w = 118, grow = 1 }, COL_RANK }
local TABLE_OTHER = {
	COL_LEVEL, COL_CLASS,
	{ key = "name", title = L.ONLINE_COL_NAME, w = 210, grow = 1 },
	COL_ADDON,
	{ key = "rank", title = L.ONLINE_COL_RANK, w = 158, grow = 1 },
}

local pane, list, listChild, empty, card, cardChild
local allRow, all, allChild, cardTable, allTable
local shownCard, shownAll -- данные на экране: растянутое окно перерисовывает их без нового сбора
local rows, people, segments, levels, zones, legend = {}, {}, {}, {}, {}, {}
local LEGEND_COLS, LEGEND_H = 2, 14
local w = {} -- надписи карточки
local selected -- U.GuildKey выбранной гильдии или ALL_KEY

local function FS(parent, font, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY", font)
	fs:SetJustifyH(justify or "LEFT")
	return fs
end

-- Высота надписи после SetText (у переносимых — по ширине); fallback — если клиент не знает.
local function Height(fs, fallback)
	local h = fs:GetStringHeight()
	return (type(h) == "number" and h > 0) and h or fallback
end

local function Place(region, x, y)
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", cardChild, "TOPLEFT", x, -y)
end

local function ClassRGB(class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then return c.r, c.g, c.b end
	return 0.6, 0.6, 0.6
end

local function Tooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	return GameTooltip
end

-- «Шёпот» из меню человека в карточке — в поле чата игры (в режиме геймпада — в окне Chillzone).
local function Whisper(name)
	ns.ChatPane.Whisper(name)
end

---------------------------------------------------------------------------
-- Список гильдий
---------------------------------------------------------------------------
local function Row(i)
	local r = rows[i]
	if r then return r end
	r = CreateFrame("Button", nil, listChild)
	r:SetSize(LIST_W, ROW_H)
	r:SetPoint("TOPLEFT", listChild, "TOPLEFT", 0, -(i - 1) * (ROW_H + 2))
	r.bg = r:CreateTexture(nil, "BACKGROUND")
	r.bg:SetAllPoints()
	r.bg:SetColorTexture(1, 1, 1, 0.03)
	r.sel = r:CreateTexture(nil, "BORDER")
	r.sel:SetAllPoints()
	r.sel:SetColorTexture(1, 0.82, 0, 0.14)
	r.sel:Hide()
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	r.right = FS(r, "GameFontHighlightSmall", "RIGHT")
	r.right:SetPoint("TOPRIGHT", -6, -6)
	r.name = FS(r, "GameFontHighlight")
	r.name:SetPoint("TOPLEFT", 6, -5)
	r.name:SetPoint("RIGHT", r.right, "LEFT", -6, 0)
	r.sub = FS(r, "GameFontHighlightSmall")
	r.sub:SetPoint("BOTTOMLEFT", 6, 5)
	r.sub:SetPoint("BOTTOMRIGHT", -6, 5)
	for _, fs in ipairs({ r.name, r.sub }) do
		if fs.SetWordWrap then fs:SetWordWrap(false) end
	end
	r:SetScript("OnClick", function(self) ns.SafeCall("census select", CensusPane.Select, self.key) end)
	rows[i] = r
	return r
end

-- Пустой список: «ещё запрашиваем» и «данных нет» — разные вещи. Окно зовёт это по тику.
function CensusPane.RenderEmpty()
	if empty then empty:SetText(ns.Activity.Running("census") and L.CENSUS_LOADING or L.CENSUS_EMPTY) end
end

local function RenderList(items)
	for i, it in ipairs(items) do
		local r = Row(i)
		r.key = it.key
		r.name:SetText(it.text)
		r.right:SetText(it.right)
		r.sub:SetText(it.sub)
		r.sel:SetShown(it.key == selected)
		r:Show()
	end
	for i = #items + 1, #rows do rows[i]:Hide() end
	listChild:SetHeight(math.max(#items * (ROW_H + 2), 10))
	empty:SetShown(#items == 0)
	CensusPane.RenderEmpty()
end

---------------------------------------------------------------------------
-- Карточка
---------------------------------------------------------------------------
-- Строка человека: подсветка, подсказка и меню по правой кнопке. Общая для руководства и таблицы.
local function PersonButton(parent, width)
	local p = CreateFrame("Button", nil, parent)
	p:SetSize(width, PERSON_H)
	local hl = p:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	p:SetScript("OnEnter", function(self)
		if not self.person then return end
		ns.SafeCall("census person tip", Views.PersonTip, Tooltip(self), self.person)
		GameTooltip:Show()
	end)
	p:SetScript("OnLeave", function() GameTooltip:Hide() end)
	p:RegisterForClicks("RightButtonUp")
	p:SetScript("OnClick", function(self, button)
		if button == "RightButton" and self.person then
			ns.SafeCall("census menu", ns.ChatPane.OpenPersonMenu, self, self.person, Whisper)
		end
	end)
	return p
end

local function NewPerson(parent, width)
	local p = PersonButton(parent, width)
	p.icon = p:CreateTexture(nil, "ARTWORK")
	p.icon:SetSize(12, 12)
	p.icon:SetPoint("LEFT", 2, 0)
	p.level = FS(p, "GameFontDisableSmall", "RIGHT")
	p.level:SetPoint("RIGHT", -2, 0)
	p.name = FS(p, "GameFontHighlightSmall")
	p.name:SetPoint("LEFT", p.icon, "RIGHT", 4, 0)
	p.name:SetPoint("RIGHT", p.level, "LEFT", -4, 0)
	if p.name.SetWordWrap then p.name:SetWordWrap(false) end
	return p
end

local function Person(i)
	people[i] = people[i] or NewPerson(cardChild, colLW)
	return people[i]
end

local function Segment(i)
	local t = segments[i]
	if t then return t end
	t = w.classBar:CreateTexture(nil, "ARTWORK")
	t:SetTexture(BAR)
	t:SetHeight(10)
	segments[i] = t
	return t
end

-- Строка подписи под полосой классов: квадратик цвета класса, класс, число справа.
-- Отдельными надписями, а не одной строкой через запятую: та переносилась посреди «Жрец 6».
local function LegendItem(i)
	local e = legend[i]
	if e then return e end
	e = {}
	e.swatch = cardChild:CreateTexture(nil, "ARTWORK")
	e.swatch:SetTexture(BAR)
	e.swatch:SetSize(8, 8)
	e.name = FS(cardChild, "GameFontHighlightSmall")
	if e.name.SetWordWrap then e.name:SetWordWrap(false) end
	e.count = FS(cardChild, "GameFontHighlightSmall", "RIGHT")
	legend[i] = e
	return e
end

local function Zone(i)
	local z = zones[i]
	if z then return z end
	z = {}
	z.name = FS(cardChild, "GameFontHighlightSmall")
	z.name:SetWidth(ZONE_NAME_W)
	if z.name.SetWordWrap then z.name:SetWordWrap(false) end
	z.bar = cardChild:CreateTexture(nil, "ARTWORK")
	z.bar:SetTexture(BAR)
	z.bar:SetVertexColor(0.25, 0.6, 0.9)
	z.bar:SetHeight(10)
	z.count = FS(cardChild, "GameFontHighlightSmall", "RIGHT")
	zones[i] = z
	return z
end

-- Руководство: левая колонка с y; возвращает её высоту.
local function RenderPeople(c, y)
	Place(w.leaders, 0, y)
	local h = 20
	for i, person in ipairs(c.people) do
		local p = Person(i)
		Place(p, 0, y + h)
		p.person = person
		p.icon:SetTexture(ROLE_ICON[person.role])
		local dot = person.online and "|TInterface\\FriendsFrame\\StatusIcon-Online:10|t " or "|TInterface\\FriendsFrame\\StatusIcon-Offline:10|t "
		local name = Views.Name(person.name, person.class)
		if not person.online then name = "|cff808080" .. ns.Codec.Plain(person.name) .. "|r" end
		p.name:SetText(dot .. name)
		p.level:SetText(person.level and person.level > 0 and tostring(person.level) or "")
		p:Show()
		h = h + PERSON_H
	end
	for i = #c.people + 1, #people do people[i]:Hide() end
	w.noLeaders:SetShown(#c.people == 0)
	if #c.people == 0 then
		Place(w.noLeaders, 0, y + h)
		h = h + 14
	end
	return h
end

-- Классы и уровни: правая колонка с y; возвращает её высоту.
local function RenderMix(c, y)
	local shown = c.classes ~= nil
	for _, region in ipairs({ w.classes, w.classBar, w.classLegend, w.levels }) do region:SetShown(shown) end
	if not shown then
		for _, e in ipairs(legend) do
			for _, region in ipairs({ e.swatch, e.name, e.count }) do region:Hide() end
		end
	end
	for _, col in ipairs(levels) do
		for _, region in ipairs({ col.bar, col.count, col.label }) do region:SetShown(shown) end
	end
	w.stale:SetShown(not shown)
	if not shown then
		Place(w.stale, colRX, y)
		w.stale:SetText(c.staleNote or "")
		for _, t in ipairs(segments) do t:Hide() end
		return Height(w.stale, 28)
	end
	Place(w.classes, colRX, y)
	Place(w.classBar, colRX, y + 20)
	-- Полоса: отрезки цветом класса, длина — доля в игре.
	local x = 0
	for i, e in ipairs(c.classes) do
		local t = Segment(i)
		local width = c.classTotal > 0 and math.floor(colRW * e.count / c.classTotal + 0.5) or 0
		if i == #c.classes then width = colRW - x end
		t:ClearAllPoints()
		t:SetPoint("LEFT", w.classBar, "LEFT", x, 0)
		t:SetWidth(math.max(width, 1))
		t:SetVertexColor(ClassRGB(e.class))
		t:SetShown(width > 0)
		x = x + width
	end
	for i = #c.classes + 1, #segments do segments[i]:Hide() end
	-- Подпись — таблицей в две колонки, по убыванию сверху вниз: сначала левая, потом правая.
	local n = #c.classes
	local perCol = math.ceil(n / LEGEND_COLS)
	local colW = math.floor(colRW / LEGEND_COLS)
	for i, e in ipairs(c.classes) do
		local item = LegendItem(i)
		local col, line = math.floor((i - 1) / perCol), (i - 1) % perCol
		local lx, ly = colRX + col * colW, y + 36 + line * LEGEND_H
		Place(item.swatch, lx, ly + 3)
		item.swatch:SetVertexColor(ClassRGB(e.class))
		item.name:SetText(Views.Name(e.name, e.class))
		item.name:ClearAllPoints()
		item.name:SetPoint("TOPLEFT", cardChild, "TOPLEFT", lx + 12, -ly)
		item.name:SetPoint("TOPRIGHT", cardChild, "TOPLEFT", lx + colW - 34, -ly)
		item.count:SetText(tostring(e.count))
		item.count:ClearAllPoints()
		item.count:SetPoint("TOPRIGHT", cardChild, "TOPLEFT", lx + colW - 10, -ly)
		for _, region in ipairs({ item.swatch, item.name, item.count }) do region:Show() end
	end
	for i = n + 1, #legend do
		for _, region in ipairs({ legend[i].swatch, legend[i].name, legend[i].count }) do region:Hide() end
	end
	w.classLegend:SetShown(n == 0)
	local legendH
	if n == 0 then
		w.classLegend:SetText(L.CARD_NOBODY)
		Place(w.classLegend, colRX, y + 36)
		legendH = Height(w.classLegend, 12)
	else
		legendH = perCol * LEGEND_H
	end
	local h = 36 + legendH + 12
	-- Уровни: семь столбиков, высота — доля от самого большого.
	Place(w.levels, colRX, y + h)
	h = h + 20
	local levelW = colRW / #levels
	for i, col in ipairs(levels) do
		local e = c.levels[i]
		local cx = colRX + (i - 1) * levelW
		local barH = c.levelMax > 0 and math.floor(LEVEL_BAR_H * e.count / c.levelMax + 0.5) or 0
		col.count:SetText(e.count > 0 and tostring(e.count) or "")
		col.count:ClearAllPoints()
		col.count:SetPoint("BOTTOM", cardChild, "TOPLEFT", cx + levelW / 2, -(y + h + 12 + LEVEL_BAR_H - barH) + 1)
		col.bar:ClearAllPoints()
		col.bar:SetPoint("BOTTOM", cardChild, "TOPLEFT", cx + levelW / 2, -(y + h + 12 + LEVEL_BAR_H))
		col.bar:SetHeight(math.max(barH, 1))
		col.bar:SetShown(barH > 0)
		col.label:SetText(e.label)
		col.label:ClearAllPoints()
		col.label:SetPoint("TOP", cardChild, "TOPLEFT", cx + levelW / 2, -(y + h + 12 + LEVEL_BAR_H + 2))
	end
	return h + 12 + LEVEL_BAR_H + 16
end

local function RenderZones(c, y)
	local shown = c.zones ~= nil
	w.zones:SetShown(shown)
	w.zonesNote:SetShown(shown and c.zonesNote ~= nil)
	local n = shown and #c.zones or 0
	for i = n + 1, #zones do
		local z = zones[i]
		z.name:Hide()
		z.bar:Hide()
		z.count:Hide()
	end
	if not shown then return 0 end
	Place(w.zones, 0, y)
	local h = 20
	local barMax = cardW - ZONE_NAME_W - 10 - 40
	for i, e in ipairs(c.zones) do
		local z = Zone(i)
		z.name:SetText(e.name)
		Place(z.name, 0, y + h)
		z.bar:ClearAllPoints()
		z.bar:SetPoint("LEFT", z.name, "RIGHT", 10, 0)
		z.bar:SetWidth(math.max(1, math.floor(barMax * e.count / math.max(c.zoneMax, 1) + 0.5)))
		z.count:SetText(tostring(e.count))
		z.count:ClearAllPoints()
		z.count:SetPoint("RIGHT", cardChild, "TOPRIGHT", 0, -(y + h + 6))
		z.name:Show()
		z.bar:Show()
		z.count:Show()
		h = h + ZONE_H
	end
	if c.zonesNote then
		w.zonesNote:SetText(c.zonesNote)
		Place(w.zonesNote, 0, y + h)
		h = h + Height(w.zonesNote, 14)
	end
	return h
end

---------------------------------------------------------------------------
-- Таблица людей в игре: строка на человека, щелчок по заголовку сортирует. Строки живут в
-- содержимом прокрутки и переставляются под видимую часть, заголовок прилипает к её верху.
---------------------------------------------------------------------------
local function DefaultSort()
	return { key = "level", desc = true }
end

-- Поставить заголовок и строки по текущей прокрутке.
local function PlaceRows(t)
	local offset = t.scroll:GetVerticalScroll() or 0
	t.head:ClearAllPoints()
	t.head:SetPoint("TOPLEFT", t.parent, "TOPLEFT", 0, -math.max(t.y, offset))
	local top = t.y + TABLE_HEAD_H
	local first = math.floor(math.max(0, offset - top) / PERSON_H) + 1
	for i, r in ipairs(t.rows) do
		local index = first + i - 1
		local person = t.people[index]
		r:SetShown(person ~= nil)
		r.person = person
		if person then
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", t.parent, "TOPLEFT", 0, -(top + (index - 1) * PERSON_H))
			local cells = Views.OnlineCells(person)
			for c, col in ipairs(t.columns) do
				if not col.icon then r.cells[c]:SetText(cells[col.key]) end
			end
			local coords = person.class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[person.class]
			if coords then r.classIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4]) end
			r.classIcon:SetShown(coords ~= nil)
			r.addonIcon:SetShown(person.addon == true)
		end
	end
end

-- Первый щелчок по уровню — сначала старшие, по аддону — сначала те, у кого он есть, по остальным
-- — по алфавиту. Повторный разворачивает.
local function SortBy(t, key)
	if t.sort.key == key then
		t.sort.desc = not t.sort.desc
	else
		t.sort.key, t.sort.desc = key, key == "level" or key == "addon"
	end
	-- После сортировки нужно начало таблицы, а не случайная её середина.
	if (t.scroll:GetVerticalScroll() or 0) > t.y then t.scroll:SetVerticalScroll(t.y) end
	CensusPane.Render()
end

local function NewTableRow(parent)
	local r = PersonButton(parent, cardW)
	r.classIcon = r:CreateTexture(nil, "ARTWORK")
	r.classIcon:SetSize(14, 14)
	r.classIcon:SetTexture(CLASS_ICONS)
	r.addonIcon = r:CreateTexture(nil, "ARTWORK")
	r.addonIcon:SetSize(12, 12)
	r.addonIcon:SetTexture(ADDON_ICON)
	r.addonIcon:Hide()
	r.cells = {}
	for c = 1, TABLE_COLS do
		r.cells[c] = FS(r, "GameFontHighlightSmall")
		if r.cells[c].SetWordWrap then r.cells[c]:SetWordWrap(false) end
	end
	r:Hide()
	return r
end

local function NewTable(scroll, parent)
	local t = { scroll = scroll, parent = parent, heads = {}, rows = {}, people = {}, sort = DefaultSort(), y = 0 }
	t.head = CreateFrame("Frame", nil, parent)
	t.head:SetSize(cardW, TABLE_HEAD_H)
	t.head:SetFrameLevel(parent:GetFrameLevel() + 5) -- прилипший заголовок лежит поверх строк
	local bg = t.head:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.13, 0.13, 0.13, 1)
	for c = 1, TABLE_COLS do
		local h = CreateFrame("Button", nil, t.head)
		h:SetHeight(TABLE_HEAD_H)
		local hl = h:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.07)
		h.label = FS(h, "GameFontNormalSmall")
		h.label:SetPoint("LEFT", 3, 0)
		h.label:SetPoint("RIGHT", -3, 0)
		h:SetScript("OnClick", function(self) ns.SafeCall("census sort", SortBy, t, self.key) end)
		t.heads[c] = h
	end
	for i = 1, tableRows do t.rows[i] = NewTableRow(parent) end
	scroll:HookScript("OnVerticalScroll", function() ns.SafeCall("census table", PlaceRows, t) end)
	return t
end

-- Ширины колонок на ширину total: прибавка к исходной ширине делится по долям grow, остаток
-- от округления — последней растущей колонке.
local function Widths(columns, total)
	local base, weight = 0, 0
	for _, col in ipairs(columns) do base, weight = base + col.w, weight + (col.grow or 0) end
	local extra, out, given, last = math.max(0, total - base), {}, 0, nil
	for i, col in ipairs(columns) do
		local add = weight > 0 and math.floor(extra * (col.grow or 0) / weight) or 0
		out[i], given = col.w + add, given + add
		if (col.grow or 0) > 0 then last = i end
	end
	if last then out[last] = out[last] + extra - given end
	return out
end
CensusPane.Widths = Widths

-- Разложить колонки вида: карточка своей гильдии и чужой показывают разные.
local function ApplyColumns(t, columns)
	if t.columns == columns and t.width == cardW then return end
	t.columns, t.width = columns, cardW
	local widths, x = Widths(columns, cardW), 0
	for c = 1, TABLE_COLS do
		local col, h, cw = columns[c], t.heads[c], widths[c]
		h:SetShown(col ~= nil)
		if col then
			h.key = col.key
			h:SetWidth(cw)
			h:ClearAllPoints()
			h:SetPoint("LEFT", t.head, "LEFT", x, 0)
			h.label:SetJustifyH(col.justify or "LEFT")
		end
		for _, r in ipairs(t.rows) do
			local fs = r.cells[c]
			fs:SetShown(col ~= nil and not col.icon)
			if col and col.icon then
				r[col.icon]:ClearAllPoints()
				r[col.icon]:SetPoint("CENTER", r, "LEFT", x + cw / 2, 0)
			elseif col then
				fs:ClearAllPoints()
				fs:SetPoint("LEFT", r, "LEFT", x + 3, 0)
				fs:SetWidth(cw - 6)
				fs:SetJustifyH(col.justify or "LEFT")
			end
		end
		x = x + (cw or 0)
	end
end

-- Заполнить таблицу с отметки y; возвращает её высоту (пустая не занимает места). light — окно
-- тянут: без сортировки и раскладки колонок, строки только переезжают, если текст выше переносится
-- иначе. Это самая дорогая часть вкладки, её полная раскладка — по отпусканию.
local function RenderTable(t, columns, persons, y, light)
	if light then
		if t.y ~= y then
			t.y = y
			PlaceRows(t)
		end
		return #t.people > 0 and TABLE_HEAD_H + #t.people * PERSON_H or 0
	end
	ApplyColumns(t, columns)
	local known = false
	for _, col in ipairs(columns) do known = known or col.key == t.sort.key end
	if not known then t.sort = DefaultSort() end -- например, «Зона» осталась от своей гильдии
	Views.SortOnline(persons, t.sort.key, t.sort.desc)
	for c, col in ipairs(columns) do
		local active = col.key == t.sort.key
		t.heads[c].label:SetText(active and ("|cffffffff" .. col.title .. (t.sort.desc and " v" or " ^") .. "|r") or col.title)
	end
	t.people, t.y = persons, y
	t.head:SetShown(#persons > 0)
	PlaceRows(t)
	return #persons > 0 and TABLE_HEAD_H + #persons * PERSON_H or 0
end

local function RenderAll(c, light)
	all:SetShown(c ~= nil)
	if not c then return end
	w.allCount:SetText(L.ONLINE_ALL_COUNT:format(ns.Util.Num(c.known), ns.Util.Num(c.online)))
	local y = ALL_TOP
	w.allStatus:SetShown(c.status ~= "")
	if c.status ~= "" then
		w.allStatus:SetText(c.status)
		y = y + 14
	end
	allChild:SetHeight(y + RenderTable(allTable, TABLE_ALL, c.people, y, light) + 8)
end

local function RenderCard(c, light)
	card:SetShown(c ~= nil)
	if not c then return end
	w.title:SetText(c.guild)
	if c.main then w.title:SetTextColor(1, 0.82, 0) else w.title:SetTextColor(1, 1, 1) end
	w.marks:SetText(c.marks)
	w.updated:SetText(c.updated)
	local y = 28
	w.conflict:SetShown(c.conflict and true or false)
	if c.conflict then
		Place(w.conflict, 0, y)
		y = y + Height(w.conflict, 28) + 6
	end
	for i, tile in ipairs(w.tiles) do
		local st = c.stats[i]
		Place(tile, (i - 1) * (tile.width + TILE_GAP), y)
		tile.value:SetText(st.value)
		if st.green then tile.value:SetTextColor(0.25, 1, 0.25) else tile.value:SetTextColor(1, 1, 1) end
		tile.label:SetText(st.label)
	end
	y = y + 48 + 6
	w.extra:SetText(c.extra)
	Place(w.extra, 0, y)
	y = y + Height(w.extra, 12) + 14
	local left = RenderPeople(c, y)
	local right = RenderMix(c, y)
	y = y + math.max(left, right) + 12
	y = y + RenderZones(c, y) + 8
	w.onlineTitle:SetText(c.onlineGroup.title)
	Place(w.onlineTitle, 0, y)
	y = y + 18
	y = y + RenderTable(cardTable, c.onlineGroup.mine and TABLE_MINE or TABLE_OTHER, c.onlineGroup.people, y, light)
	cardChild:SetHeight(y + 8)
end

---------------------------------------------------------------------------
-- Сборка и показ
---------------------------------------------------------------------------
function CensusPane.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)

	-- Строка «Все гильдии» — вне прокрутки: общий список доступен при любой длине списка гильдий.
	allRow = CreateFrame("Button", nil, pane)
	allRow:SetSize(LIST_W, ALL_H)
	allRow:SetPoint("TOPLEFT", 8, -8)
	allRow.bg = allRow:CreateTexture(nil, "BACKGROUND")
	allRow.bg:SetAllPoints()
	allRow.bg:SetColorTexture(1, 1, 1, 0.03)
	allRow.sel = allRow:CreateTexture(nil, "BORDER")
	allRow.sel:SetAllPoints()
	allRow.sel:SetColorTexture(1, 0.82, 0, 0.14)
	allRow.sel:Hide()
	local allHighlight = allRow:CreateTexture(nil, "HIGHLIGHT")
	allHighlight:SetAllPoints()
	allHighlight:SetColorTexture(1, 1, 1, 0.07)
	allRow.right = FS(allRow, "GameFontHighlightSmall", "RIGHT")
	allRow.right:SetPoint("RIGHT", -6, 0)
	allRow.name = FS(allRow, "GameFontHighlight")
	allRow.name:SetPoint("LEFT", 6, 0)
	allRow.name:SetPoint("RIGHT", allRow.right, "LEFT", -6, 0)
	allRow:SetScript("OnClick", function() ns.SafeCall("census select", CensusPane.Select, ALL_KEY) end)

	list = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	list:SetPoint("TOPLEFT", 8, -(8 + ALL_H + 4))
	list:SetPoint("BOTTOMLEFT", 8, 8)
	list:SetWidth(LIST_W)
	listChild = CreateFrame("Frame", nil, list)
	listChild:SetSize(LIST_W, 10)
	list:SetScrollChild(listChild)
	empty = FS(listChild, "GameFontDisable")
	empty:SetPoint("TOPLEFT", 6, -6)
	empty:SetWidth(LIST_W - 12)
	empty:SetText(L.CENSUS_EMPTY)
	empty:Hide()
	CensusPane.empty = empty

	local divider = pane:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(1, 1, 1, 0.08)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", 276, -10)
	divider:SetPoint("BOTTOMLEFT", 276, 10)

	card = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	card:SetPoint("TOPLEFT", CARD_X, -10)
	card:SetPoint("BOTTOMRIGHT", -30, 8)
	cardChild = CreateFrame("Frame", nil, card)
	cardChild:SetSize(CARD_W, 10)
	card:SetScrollChild(cardChild)
	cardTable = NewTable(card, cardChild)
	w.onlineTitle = FS(cardChild, "GameFontNormal")
	w.onlineTitle:SetWidth(CARD_W)
	if w.onlineTitle.SetWordWrap then w.onlineTitle:SetWordWrap(false) end

	-- Вид «Все гильдии» стоит на месте карточки и показывается вместо неё.
	all = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	all:SetPoint("TOPLEFT", CARD_X, -10)
	all:SetPoint("BOTTOMRIGHT", -30, 8)
	allChild = CreateFrame("Frame", nil, all)
	allChild:SetSize(CARD_W, 10)
	all:SetScrollChild(allChild)
	all:Hide()
	allTable = NewTable(all, allChild)
	w.allTitle = FS(allChild, "GameFontNormalLarge")
	w.allTitle:SetPoint("TOPLEFT", 0, 0)
	w.allTitle:SetText(L.ONLINE_ALL_TITLE)
	w.allCount = FS(allChild, "GameFontDisableSmall", "RIGHT")
	w.allCount:SetPoint("TOPRIGHT", 0, -5)
	w.allStatus = FS(allChild, "GameFontDisableSmall")
	w.allStatus:SetPoint("TOPLEFT", 0, -ALL_TOP)
	w.allStatus:SetWidth(CARD_W)
	if w.allStatus.SetWordWrap then w.allStatus:SetWordWrap(false) end

	w.title = FS(cardChild, "GameFontNormalLarge")
	w.title:SetPoint("TOPLEFT", 0, 0)
	w.marks = FS(cardChild, "GameFontDisableSmall")
	w.marks:SetPoint("BOTTOMLEFT", w.title, "BOTTOMRIGHT", 8, 1)
	w.updated = FS(cardChild, "GameFontDisableSmall", "RIGHT")
	w.updated:SetPoint("TOPRIGHT", 0, -5)
	w.conflict = FS(cardChild, "GameFontHighlightSmall")
	w.conflict:SetWidth(CARD_W)
	w.conflict:SetTextColor(1, 0.3, 0.3)
	w.conflict:SetText(L.TIP_CONFLICT)

	-- Четыре плитки с крупными числами: участники, в игре, офицеры, средний уровень.
	w.tiles = {}
	local tileW = math.floor((CARD_W - 3 * TILE_GAP) / 4)
	for i = 1, 4 do
		local tile = CreateFrame("Frame", nil, cardChild)
		tile:SetSize(tileW, 48)
		tile.width = tileW
		local bg = tile:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(1, 1, 1, 0.05)
		tile.value = FS(tile, "GameFontNormalHuge", "CENTER")
		tile.value:SetPoint("TOP", 0, -6)
		tile.label = FS(tile, "GameFontDisableSmall", "CENTER")
		tile.label:SetPoint("BOTTOM", 0, 6)
		w.tiles[i] = tile
	end
	w.extra = FS(cardChild, "GameFontDisableSmall")
	w.extra:SetWidth(CARD_W)

	w.leaders = FS(cardChild, "GameFontNormal")
	w.leaders:SetText(L.CARD_LEADERS)
	w.noLeaders = FS(cardChild, "GameFontDisableSmall")
	w.noLeaders:SetText(L.CARD_NO_LEADERS)

	w.classes = FS(cardChild, "GameFontNormal")
	w.classes:SetText(L.CARD_CLASSES)
	w.classBar = CreateFrame("Frame", nil, cardChild)
	w.classBar:SetSize(colRW, 10)
	local barBg = w.classBar:CreateTexture(nil, "BACKGROUND")
	barBg:SetAllPoints()
	barBg:SetColorTexture(0, 0, 0, 0.45)
	w.classLegend = FS(cardChild, "GameFontDisableSmall") -- «Сейчас никого нет в игре.»
	w.classLegend:SetWidth(colRW)
	w.levels = FS(cardChild, "GameFontNormal")
	w.levels:SetText(L.CARD_LEVELS)
	for i = 1, 7 do
		local col = {}
		col.bar = cardChild:CreateTexture(nil, "ARTWORK")
		col.bar:SetTexture(BAR)
		col.bar:SetVertexColor(0.95, 0.75, 0.2)
		col.bar:SetWidth(22)
		col.count = FS(cardChild, "GameFontHighlightSmall", "CENTER")
		col.label = FS(cardChild, "GameFontDisableSmall", "CENTER")
		levels[i] = col
	end
	w.stale = FS(cardChild, "GameFontDisableSmall")
	w.stale:SetWidth(colRW)

	w.zones = FS(cardChild, "GameFontNormal")
	w.zones:SetText(L.CARD_ZONES)
	w.zonesNote = FS(cardChild, "GameFontDisableSmall")
	w.zonesNote:SetWidth(CARD_W)

	pane:Hide()
	CensusPane.frames = {
		pane = pane, rows = rows, people = people, segments = segments, levels = levels, zones = zones, legend = legend,
		w = w, card = card, allRow = allRow, all = all, cardTable = cardTable, allTable = allTable,
	}
	return pane
end

-- Перерисовать: выбор держится, пока гильдия в списке; иначе — своя гильдия, иначе первая.
-- Поимённые списки запрашиваются только для того, что сейчас на экране.
function CensusPane.Render()
	if not pane then return end
	local items = Views.CensusRows()
	local pick
	for _, it in ipairs(items) do
		if it.key == selected then pick = it end
	end
	local showAll = selected == ALL_KEY and #items > 0
	if not pick and not showAll then
		for _, it in ipairs(items) do
			if it.s.mine then pick = it end
		end
		pick = pick or items[1]
	end
	selected = showAll and ALL_KEY or (pick and pick.key or nil)
	for _, it in ipairs(items) do
		if it.s.fresh and (showAll or it == pick) then ns.Online.Want(it.s.guild) end
	end
	RenderList(items)
	local row = Views.AllOnlineRow()
	allRow.name:SetText(row.text)
	allRow.right:SetText(row.right)
	allRow.sel:SetShown(showAll)
	allRow:SetShown(#items > 0)
	shownAll = showAll and Views.AllOnline() or nil
	shownCard = pick and Views.GuildCard(pick.s) or nil
	RenderAll(shownAll)
	RenderCard(shownCard)
end

-- Раскладка под вставку w×h (UI.lua). Лишняя ширина уходит карточке: плиткам, полосе классов,
-- зонам и колонкам таблицы; лишняя высота — строкам таблицы. live — окно ещё тянут: открытая
-- вкладка перекладывает карточку из того, что уже на экране, а таблицу людей не трогает. Без
-- live строки и колонки готовятся к полной отрисовке, её делает UI.Render после раскладки.
function CensusPane.Layout(width, height, live)
	if not pane then return end
	cardW = math.max(CARD_W, math.floor(width - CARD_X - CARD_RIGHT))
	colLW = COL_L_W + math.floor((cardW - CARD_W) / 3)
	colRX = colLW + COL_GAP
	colRW = cardW - colRX
	cardChild:SetWidth(cardW)
	allChild:SetWidth(cardW)
	for _, fs in ipairs({ w.onlineTitle, w.allStatus, w.conflict, w.extra, w.zonesNote }) do fs:SetWidth(cardW) end
	local tileW = math.floor((cardW - 3 * TILE_GAP) / 4)
	for _, tile in ipairs(w.tiles) do
		tile:SetWidth(tileW)
		tile.width = tileW
	end
	w.classBar:SetWidth(colRW)
	w.classLegend:SetWidth(colRW)
	w.stale:SetWidth(colRW)
	for _, p in ipairs(people) do p:SetWidth(colLW) end
	for _, t in ipairs({ cardTable, allTable }) do t.head:SetWidth(cardW) end
	if live then
		if pane:IsShown() then
			RenderAll(shownAll, true)
			RenderCard(shownCard, true)
		end
		return
	end
	tableRows = math.max(tableRows, TableRows(height))
	for _, t in ipairs({ cardTable, allTable }) do
		for _, r in ipairs(t.rows) do r:SetWidth(cardW) end
		for i = #t.rows + 1, tableRows do t.rows[i] = NewTableRow(t.parent) end
		t.width = nil -- колонки разложатся заново, в том числе у новых строк
	end
end

function CensusPane.Select(key)
	if key == selected then return end
	selected = key
	if card then card:SetVerticalScroll(0) end
	if all then all:SetVerticalScroll(0) end
	CensusPane.Render()
end

function CensusPane.Selected() return selected end

function CensusPane.Show()
	if not pane then return end
	pane:Show()
	CensusPane.Render()
end

function CensusPane.Hide()
	if pane then pane:Hide() end
end

-- Пока вкладка на экране, списки обновляются сами. IsVisible учитывает и закрытое окно.
local function RenderIfVisible()
	if pane and pane:IsVisible() then CensusPane.Render() end
end
ns.On("ONLINE", RenderIfVisible)
ns.On("LOGIN", function()
	ns.Every(ONLINE_TICK, "census online", RenderIfVisible)
end)
