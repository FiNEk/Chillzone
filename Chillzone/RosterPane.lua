-- Chillzone: раздел «Состав» во вкладке «Управление» для глав и офицеров гильдий объединения
-- (права — Transfer.Rights): состав своей гильдии с давностью входа и исключение. Исключает сам
-- игрок командой в чате игры (CommandBox.lua): щелчок по строке показывает команду для этого
-- игрока, «Исключать по очереди» — по одной для всех, кто не заходил дольше заданного числа дней,
-- начиная с самых давних. Строка команды встаёт на место строки отметок, таблица не сдвигается.
-- Строки таблицы переставляются под видимую часть прокрутки, как в «Переписи». В широком окне
-- лишнее место получают имя и звание, в высоком — число строк (P.Layout).
local ADDON, ns = ...
local L, U, T = ns.L, ns.Util, ns.Transfer
local P = {}
ns.RosterPane = P

local pane, tools, box, head, scroll, child, empty
local rows = {}
local people = {} -- отсортированный состав
local sort = { key = "days", desc = true }
local note -- итог последней очереди или щелчка вместо числа участников
local ROW_H, HEAD_H, BASE_W, GAP = 18, 18, 760, 4
local WIDTH, VISIBLE = BASE_W, 15
local ROWS = VISIBLE + 2
local TOP = 8 + ns.CommandBox.HEIGHT + 6 -- заголовок таблицы под строкой отметок или команды
-- base — ширина в исходном окне, grow — доля лишней ширины; x считает Columns.
local COLUMNS = {
	{ key = "name", title = "TRANSFER_COL_NAME", base = 290, grow = 3 },
	{ key = "level", title = "TRANSFER_COL_LEVEL", base = 50, grow = 0 },
	{ key = "rank", title = "TRANSFER_COL_RANK", base = 210, grow = 2 },
	{ key = "days", title = "TRANSFER_COL_LAST", base = 170, grow = 0 },
}

-- Ширины и отступы колонок под ширину таблицы WIDTH (в исходной: x = 4, 298, 352, 566).
-- Остаток округления достаётся имени.
local function Columns()
	local extra, weight = math.max(0, WIDTH - BASE_W), 0
	for _, col in ipairs(COLUMNS) do weight = weight + col.grow end
	local adds, left = {}, extra
	for i, col in ipairs(COLUMNS) do
		adds[i] = col.grow > 0 and math.floor(extra * col.grow / weight) or 0
		left = left - adds[i]
	end
	adds[1] = adds[1] + left
	local x = GAP
	for i, col in ipairs(COLUMNS) do
		col.x, col.w = x, col.base + adds[i]
		x = x + col.w + GAP
	end
end
Columns()
local INACTIVE = "|cffff8a5c" -- давность тех, кто попадёт в очередь

local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("состав: щелчок", fn) end)
	return b
end
local function Text(parent, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end
local function Tip(owner, text)
	owner:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	owner:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function Limit()
	local n = tonumber(tools.days:GetText() or "")
	if not n or n < 0 then n = ns.Config.TRANSFER_INACTIVE_DAYS end
	return n
end
local function Inactive(m, limit) return not m.online and (m.days or 0) >= limit end

local function Days(m) return m.online and -1 or (m.days or 0) end
-- Состав без тех, о ком гильдия уже сообщила «исключён» или «покинул»: ростер перечитается позже.
local function Members()
	local out = {}
	for _, m in ipairs(ns.Roster.members) do
		if not ns.CommandBox.Gone(m.name) then out[#out + 1] = m end
	end
	return out
end
local function SortPeople()
	local out = Members()
	local key, desc = sort.key, sort.desc
	table.sort(out, function(a, b)
		local x, y
		if key == "name" then x, y = a.key or "", b.key or ""
		elseif key == "level" then x, y = a.level or 0, b.level or 0
		elseif key == "rank" then x, y = a.rank or 9, b.rank or 9
		else x, y = Days(a), Days(b) end
		if x ~= y then
			if desc then return x > y end
			return x < y
		end
		return (a.key or "") < (b.key or "")
	end)
	return out
end
local function SortBy(key)
	if sort.key == key then
		sort.desc = not sort.desc
	else
		sort.key, sort.desc = key, key == "days" or key == "level"
	end
	P.Render()
end

-- Кого исключать по очереди: давно не заходившие, кого позволяет исключить звание; самые давние первыми.
local function Candidates()
	local limit, out = Limit(), {}
	for _, m in ipairs(Members()) do
		if Inactive(m, limit) and T.CanRemove(m.name) then out[#out + 1] = m end
	end
	table.sort(out, function(a, b)
		if (a.days or 0) ~= (b.days or 0) then return (a.days or 0) > (b.days or 0) end
		return (a.key or "") < (b.key or "")
	end)
	return out
end

local function Last(m)
	if m.online then return "|cff40ff40" .. L.TRANSFER_ONLINE .. "|r" end
	local d = math.floor(m.days or 0)
	if d < 1 then return L.TRANSFER_TODAY end
	return L.TRANSFER_DAYS:format(d)
end

-- Строку текущей команды очереди — в видимую часть таблицы.
local function Reveal()
	local e = box:Current()
	local key = e and U.Key(e.name)
	if not key then return end
	for i, m in ipairs(people) do
		if m.key == key then
			local first = math.floor((scroll:GetVerticalScroll() or 0) / ROW_H) + 1
			if i < first or i > first + VISIBLE - 1 then
				local offset = (i - 1) * ROW_H
				local range = scroll.GetVerticalScrollRange and scroll:GetVerticalScrollRange()
				if type(range) == "number" then offset = math.min(offset, range) end
				scroll:SetVerticalScroll(offset)
			end
			return
		end
	end
end

local function KickInactive()
	local entries = {}
	for _, m in ipairs(Candidates()) do entries[#entries + 1] = { kind = "K", name = m.name } end
	if #entries == 0 then return end
	note = nil
	tools.days:ClearFocus()
	box:Run(entries)
end

-- «Перенести»: игрок — в форму «Кадров», гильдия «откуда» — своя.
local function Move(m)
	ns.UI.Toggle("transfer")
	ns.TransferPane.Fill(U.Display(m.name), ns.MyGuild(), nil)
end

-- Щелчок по строке: команда исключения этого игрока. Идущую очередь щелчок не сбивает.
local function Choose(m)
	if not m or ns.IsMe(m.name) then return end
	local e = box:Current()
	if e and box.queue and #box.queue.entries > 1 then return end
	if not T.CanRemove(m.name) then
		note = L.TRANSFER_CANT_REMOVE:format(U.Display(m.name))
		P.Render()
		return
	end
	note = nil
	box:Run({ { kind = "K", name = m.name } }, { alt = { text = L.TRANSFER_MOVE, fn = function() Move(m) end } })
end

local function RowAt(i)
	if rows[i] then return rows[i] end
	local r = CreateFrame("Button", nil, child)
	r:SetSize(WIDTH, ROW_H)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	r.current = r:CreateTexture(nil, "BACKGROUND")
	r.current:SetAllPoints()
	r.current:SetColorTexture(1, 0.82, 0, 0.18)
	r.current:Hide()
	r.cells = {}
	for c, col in ipairs(COLUMNS) do
		local fs = Text(r)
		fs:SetPoint("LEFT", r, "LEFT", col.x + 3, 0)
		fs:SetWidth(col.w - 6)
		r.cells[c] = fs
	end
	r:SetScript("OnClick", function() ns.SafeCall("состав: игрок", Choose, r.person) end)
	r:Hide()
	rows[i] = r
	return r
end

-- Поставить строки таблицы по текущей прокрутке.
local function PlaceRows()
	local shown = head:IsShown()
	local first = math.floor((scroll:GetVerticalScroll() or 0) / ROW_H) + 1
	local e = box:Current()
	local current = e and U.Key(e.name)
	local limit = Limit()
	for i = 1, ROWS do
		local r = RowAt(i)
		local index = first + i - 1
		local m = shown and people[index] or nil
		r.person, r.index = m, index
		if m then
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(index - 1) * ROW_H)
			r.current:SetShown(m.key == current)
			r.cells[1]:SetText(ns.Views.Name(U.Display(m.name), m.class))
			r.cells[2]:SetText(tostring(m.level or ""))
			r.cells[3]:SetText(m.rankName or "")
			local last = Last(m)
			if Inactive(m, limit) and T.CanRemove(m.name) then last = INACTIVE .. last .. "|r" end
			r.cells[4]:SetText(last)
			r:Show()
		else
			r:Hide()
		end
	end
	for i = ROWS + 1, #rows do rows[i]:Hide() end
end

local function BuildTools()
	tools = CreateFrame("Frame", nil, pane)
	tools:SetSize(WIDTH, ns.CommandBox.HEIGHT)
	tools:SetPoint("TOPLEFT", 8, -8)
	tools.label = Text(tools)
	tools.label:SetPoint("LEFT", 4, 0)
	tools.label:SetText(L.TRANSFER_INACTIVE_LABEL)
	tools.days = CreateFrame("EditBox", nil, tools, "InputBoxTemplate")
	tools.days:SetSize(34, 20)
	tools.days:SetPoint("LEFT", tools.label, "RIGHT", 10, 0)
	tools.days:SetAutoFocus(false)
	tools.days:SetNumeric(true)
	tools.days:SetMaxLetters(3)
	tools.days:SetText(tostring(ns.Config.TRANSFER_INACTIVE_DAYS))
	tools.days:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	tools.days:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	tools.days:SetScript("OnTextChanged", function(_, userInput)
		if userInput then ns.SafeCall("состав: дни", function() note = nil; P.Render() end) end
	end)
	tools.unit = Text(tools)
	tools.unit:SetPoint("LEFT", tools.days, "RIGHT", 4, 0)
	tools.unit:SetText(L.TRANSFER_INACTIVE_UNIT)
	tools.count = Text(tools, "GameFontNormalSmall")
	tools.count:SetPoint("LEFT", tools.unit, "RIGHT", 4, 0)
	tools.kick = Button(tools, L.TRANSFER_KICK_QUEUE, 170, KickInactive)
	tools.kick:SetPoint("LEFT", tools.count, "RIGHT", 12, 0)
	Tip(tools.kick, L.TRANSFER_KICK_QUEUE_TIP)
	-- Ростер без игроков не в сети: неактивных в нём нет. Показ — та же настройка, что в окне гильдии.
	tools.showAll = Button(tools, L.TRANSFER_SHOW_OFFLINE, 130, function()
		if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
		ns.Roster.RequestScan(true)
	end)
	tools.showAll:SetPoint("RIGHT", -4, 0)
	tools.info = Text(tools)
	tools.info:SetJustifyH("RIGHT")
	tools.info:SetPoint("RIGHT", -4, 0)
end

local function BuildHead()
	head = CreateFrame("Frame", nil, pane)
	head:SetSize(WIDTH, HEAD_H)
	head:SetPoint("TOPLEFT", 8, -TOP)
	local bg = head:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.13, 0.13, 0.13, 1)
	head.cells = {}
	for c, col in ipairs(COLUMNS) do
		local h = CreateFrame("Button", nil, head)
		h:SetSize(col.w, HEAD_H)
		h:SetPoint("LEFT", head, "LEFT", col.x, 0)
		local hl = h:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.07)
		h.label = Text(h, "GameFontNormalSmall")
		h.label:SetPoint("LEFT", 3, 0)
		h.label:SetPoint("RIGHT", -3, 0)
		h:SetScript("OnClick", function() ns.SafeCall("состав: сортировка", SortBy, col.key) end)
		head.cells[c] = h
	end
end

function P.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	BuildTools()
	box = ns.CommandBox.New(pane, WIDTH, function(event, done, total)
		if (event == "finish" or event == "stop") and total > 1 then note = L.TRANSFER_QUEUE_DONE:format(done, total) end
		P.Render()
		if event == "next" and pane:IsShown() then Reveal() end
	end)
	box:SetPoint("TOPLEFT", 8, -8)
	BuildHead()
	scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -(TOP + HEAD_H))
	scroll:SetPoint("BOTTOMRIGHT", -30, 8)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WIDTH, 10)
	scroll:SetScrollChild(child)
	scroll:HookScript("OnVerticalScroll", function() ns.SafeCall("состав: прокрутка", PlaceRows) end)
	empty = pane:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 16, -16)
	empty:SetPoint("RIGHT", -16, 0)
	empty:SetJustifyH("LEFT")
	empty:SetText(L.ROSTER_EMPTY)
	P.frames = { pane = pane, tools = tools, box = box, head = head, rows = rows, scroll = scroll, empty = empty }
	pane:Hide()
end

local function PlaceCell(cell, owner, col, pad)
	cell:ClearAllPoints()
	cell:SetPoint("LEFT", owner, "LEFT", col.x + pad, 0)
	cell:SetWidth(col.w - 2 * pad)
end

-- Раскладка под вставку width×height (UI.lua): шире таблица и её колонки, выше — больше строк.
function P.Layout(width, height)
	if not pane then return end
	WIDTH = math.max(BASE_W, math.floor(width) - 44)
	VISIBLE = math.max(15, math.floor((height - TOP - HEAD_H - 8) / ROW_H))
	ROWS = VISIBLE + 2
	Columns()
	tools:SetWidth(WIDTH)
	box:SetWidth(WIDTH)
	head:SetWidth(WIDTH)
	child:SetWidth(WIDTH)
	for c, col in ipairs(COLUMNS) do PlaceCell(head.cells[c], head, col, 0) end
	for _, r in ipairs(rows) do
		r:SetWidth(WIDTH)
		for c, col in ipairs(COLUMNS) do PlaceCell(r.cells[c], r, col, 3) end
	end
	if pane:IsShown() then PlaceRows() end
end

function P.Render()
	if not pane or not pane:IsShown() then return end
	if not T.Rights() then P.Hide(); return end
	local fresh = ns.MyGuild() ~= nil and ns.Roster.Fresh() and #ns.Roster.members > 0
	people = fresh and SortPeople() or {}
	empty:SetShown(not fresh)
	head:SetShown(fresh)
	tools:SetShown(fresh and not box:IsShown())
	if fresh then
		local count = #Candidates()
		tools.count:SetText(INACTIVE .. count .. "|r")
		tools.kick:SetEnabled(count > 0)
		local partial = not ns.Roster.complete
		tools.showAll:SetShown(partial and SetGuildRosterShowOffline ~= nil)
		tools.info:ClearAllPoints()
		if tools.showAll:IsShown() then
			tools.info:SetPoint("RIGHT", tools.showAll, "LEFT", -8, 0)
		else
			tools.info:SetPoint("RIGHT", -4, 0)
		end
		tools.info:SetText(note or partial and ("|cffff8080" .. L.TRANSFER_ROSTER_PARTIAL .. "|r")
			or L.TRANSFER_TOTAL:format(#people))
		for c, col in ipairs(COLUMNS) do
			local text = L[col.title]
			if col.key == sort.key then text = "|cffffffff" .. text .. (sort.desc and " v" or " ^") .. "|r" end
			head.cells[c].label:SetText(text)
		end
	end
	child:SetHeight(math.max(10, #people * ROW_H))
	PlaceRows()
end

function P.Show()
	if not pane or not T.Rights() then return end
	note = nil
	pane:Show()
	P.Render()
	-- Очередь шла при закрытом окне: команда снова выделена для копирования.
	if box:IsShown() then
		box.edit:SetFocus()
		box.edit:HighlightText()
	end
end

-- Очередь команд переживает закрытие окна: игрок мог закрыть его, чтобы ввести команду.
function P.Hide()
	if not pane then return end
	pane:Hide()
	box.edit:ClearFocus()
	tools.days:ClearFocus()
end

local function RenderIfShown()
	if pane and pane:IsShown() then P.Render() end
end
ns.On("ROSTER", RenderIfShown)
ns.On("GUILD_MEMBER", RenderIfShown)
ns.On("UNION", RenderIfShown)
