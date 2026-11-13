-- Chillzone: раздел «Кадры» во вкладке «Управление» (Transfer.lua) для глав и офицеров гильдий
-- объединения: форма новой просьбы, поле команды, просьбы ко мне, мои просьбы и состав своей
-- гильдии с давностью входа. Исключает и приглашает сам игрок командой в чате игры (Forever не
-- даёт этого ни аддону, ни макросу): раздел показывает команду в своём поле (CommandBox.lua) и
-- сам переходит к следующей, когда системная строка гильдии или ростер покажут итог. Гильдию
-- выбирают в своём списке, а не в UIDropDownMenu: его общие глобалы на Forever дают taint.
local ADDON, ns = ...
local L, U, T = ns.L, ns.Util, ns.Transfer
local P = {}
ns.TransferPane = P

local pane, scroll, child, input, fromButton, toButton, kickButton, moveButton, message, list, empty, box
local rows, headers, items = {}, {}, {}
local from, to -- выбранные гильдии
local picking -- "from" или "to": для какой кнопки открыт список гильдий
local confirming -- ключ кнопки формы, которой нужен второй щелчок: она отправит просьбу офицерам
local note -- итог последнего действия вместо строки о правах
local ROW_HEIGHT, HEADER_HEIGHT, HEADER_GAP, SECTION_GAP, ITEM_H, WIDTH = 36, 24, 4, 14, 20, 760
-- Состав своей гильдии: строки таблицы переставляются под видимую часть прокрутки, как в «Переписи».
local MEMBER_H, MEMBER_ROWS, TABLE_HEAD_H, TOOLS_H = 18, 20, 18, 30
local COLUMNS = {
	{ key = "name", title = "TRANSFER_COL_NAME", x = 28, w = 230 },
	{ key = "level", title = "TRANSFER_COL_LEVEL", x = 262, w = 44 },
	{ key = "rank", title = "TRANSFER_COL_RANK", x = 310, w = 180 },
	{ key = "days", title = "TRANSFER_COL_LAST", x = 494, w = 150 },
}
local members, tools, head = {}, nil, nil -- строки состава, панель отметок и заголовок таблицы
local people, peopleTop = {}, 0 -- отсортированный состав и отметка начала его строк
local sort = { key = "days", desc = true }
local checked = {} -- [ключ] = отмечен для исключения
local gone = {} -- [ключ] = системная строка гильдии сказала, что игрок ушёл
-- Очередь команд в поле: { entries = { { kind = "K" или "I", name } }, index, done }.
local queue

local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("кадры: щелчок", fn) end)
	return b
end
local function Text(parent, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end
local function Caption(text, anchor, x)
	local fs = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	fs:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", x, 3)
	fs:SetText(text)
	return fs
end
local function Name() return U.Trim(input:GetText() or "") end
local function Same(a, b) return a ~= nil and b ~= nil and U.GuildKey(a) == U.GuildKey(b) end
local function Key(kind) return kind .. ":" .. (U.Key(Name()) or "") .. ":" .. (from or "") .. ":" .. (to or "") end

---------------------------------------------------------------------------
-- Поле команды и очередь
---------------------------------------------------------------------------

-- Ждёт ли команда игрока: исключённый ещё в гильдии (или ростер неполный и системной строки не
-- было), приглашённого в ней ещё нет.
local function Pending(e)
	local key = U.Key(e.name)
	if e.kind == "K" then return not gone[key] and (ns.Roster.RankOf(e.name) ~= nil or not ns.Roster.complete) end
	return ns.Roster.RankOf(e.name) == nil
end

local function OpenCurrent()
	local e = queue and queue.entries[queue.index]
	if not e then return end
	local name = U.Display(e.name)
	local title = e.kind == "K" and L.TRANSFER_CMD_KICK:format(name) or L.TRANSFER_CMD_INVITE:format(name)
	local progress = #queue.entries > 1 and L.TRANSFER_QUEUE_PROGRESS:format(queue.index, #queue.entries) or nil
	box:Open(title, T.Command(e.kind, e.name), progress, e.kind == "K" and L.TRANSFER_CMD_KICK_TIP or L.TRANSFER_CMD_INVITE_TIP)
end

-- Следующая команда очереди; resolved — текущая сделана (а не пропущена).
local function Advance(resolved)
	if not queue then return end
	if resolved then queue.done = queue.done + 1 end
	repeat
		queue.index = queue.index + 1
	until not queue.entries[queue.index] or Pending(queue.entries[queue.index])
	if queue.entries[queue.index] then
		OpenCurrent()
		return
	end
	if #queue.entries > 1 then note = L.TRANSFER_QUEUE_DONE:format(queue.done, #queue.entries) end
	queue = nil
	box:Close()
end

local function Run(entries)
	if #entries == 0 then return end
	queue, note, confirming = { entries = entries, index = 1, done = 0 }, nil, nil
	OpenCurrent()
end

local function Act(item)
	local command, why = T.Act(item)
	if not command then note = why; return end
	Run({ { kind = item.kind, name = item.name } })
end
local function Step(task)
	local kind, command = T.Step(task)
	if not kind then note = command; return end -- без права второе значение — причина
	Run({ { kind = kind, name = task.name } })
end

---------------------------------------------------------------------------
-- Список гильдий объединения
---------------------------------------------------------------------------

local function Guilds()
	local out = {}
	for _, e in ipairs(ns.Security.UnionGuilds()) do out[#out + 1] = e end
	table.sort(out, function(a, b)
		if (a.main or false) ~= (b.main or false) then return a.main == true end
		return U.GuildKey(a.guild) < U.GuildKey(b.guild)
	end)
	return out
end
local function Pick(guild)
	if picking == "from" then
		from = guild
		if Same(from, to) then to = nil end
	else
		to = guild
		if Same(from, to) then from = nil end
	end
	list:Hide()
	picking, confirming, note = nil, nil, nil
	P.Render()
end
local function Item(i)
	if items[i] then return items[i] end
	local it = CreateFrame("Button", nil, list)
	it:SetHeight(ITEM_H)
	it:SetPoint("TOPLEFT", list, "TOPLEFT", 6, -6 - (i - 1) * ITEM_H)
	it:SetPoint("RIGHT", list, "RIGHT", -6, 0)
	it.text = Text(it)
	it.text:SetPoint("LEFT", 4, 0)
	it.text:SetPoint("RIGHT", -4, 0)
	local hl = it:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.1)
	it:SetScript("OnClick", function(self) ns.SafeCall("кадры: гильдия", Pick, self.value) end)
	items[i] = it
	return it
end
local function OpenList(which, anchor)
	if list:IsShown() and picking == which then
		list:Hide()
		picking = nil
		return
	end
	picking = which
	local guilds = Guilds()
	for i, e in ipairs(guilds) do
		local it = Item(i)
		it.value = e.guild
		it.text:SetText(e.guild)
		it:Show()
	end
	for i = #guilds + 1, #items do items[i]:Hide() end
	list:ClearAllPoints()
	list:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
	list:SetHeight(12 + #guilds * ITEM_H)
	list:Show()
end

---------------------------------------------------------------------------
-- Форма
---------------------------------------------------------------------------

local function RightsText()
	local rights = T.Rights()
	if rights == "owner" then return L.TRANSFER_RIGHTS_OWNER end
	if rights == "main" then return L.TRANSFER_RIGHTS_MAIN:format(ns.Config.MAIN_GUILD) end
	if rights == "officer" then return L.TRANSFER_RIGHTS_OFFICER end
	return L.TRANSFER_RIGHTS_LOCAL
end

-- Исключение из своей гильдии своей командой ничего никому не отправляет: второй щелчок не нужен.
local function Direct(kind)
	return kind == "kick" and Same(from, ns.MyGuild()) and T.CanRemove(Name())
end

-- Кнопка формы. Просьба другим офицерам уходит со второго щелчка, своя команда — сразу.
local function Start(kind)
	local key = Key(kind)
	if not Direct(kind) and confirming ~= key then
		confirming, note = key, nil
		P.Render()
		return
	end
	confirming = nil
	local task, why
	if kind == "kick" then task, why = T.Kick(Name(), from) else task, why = T.Move(Name(), from, to) end
	if task then
		input:SetText("")
		input:ClearFocus()
		if task.localStep then
			Step(task)
		else
			local req = task.req
			note = (req and #req.targets == 0) and L.TRANSFER_NO_TARGETS:format(req.guild) or L.TRANSFER_STARTED
		end
	else
		note = why
	end
	P.Render()
end

local function RenderForm()
	local named = U.Key(Name()) ~= nil
	fromButton:SetText(from or L.TRANSFER_PICK)
	toButton:SetText(to or L.TRANSFER_PICK)
	kickButton:SetEnabled(named and from ~= nil and T.CanKick(from))
	moveButton:SetEnabled(named and from ~= nil and to ~= nil and T.CanMove(from, to))
	kickButton:SetText(confirming == Key("kick") and L.TRANSFER_CONFIRM or L.TRANSFER_KICK)
	moveButton:SetText(confirming == Key("move") and L.TRANSFER_CONFIRM or L.TRANSFER_MOVE)
	message:SetText(note or RightsText())
end

-- Игрок из состава — в форму: имя и своя гильдия «откуда».
local function Choose(m)
	if not m then return end
	input:SetText(U.Display(m.name))
	from = ns.MyGuild()
	if Same(from, to) then to = nil end
	confirming, note = nil, nil
	P.Render()
end

---------------------------------------------------------------------------
-- Строки просьб
---------------------------------------------------------------------------

local function RowAt(i)
	if rows[i] then return rows[i] end
	local row = CreateFrame("Frame", nil, child)
	row:SetSize(WIDTH, ROW_HEIGHT - 2)
	row.label = Text(row)
	row.label:SetPoint("TOPLEFT", 4, -4)
	row.label:SetPoint("RIGHT", -220, 0)
	row.sub = Text(row, "GameFontDisableSmall")
	row.sub:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -4)
	row.sub:SetPoint("RIGHT", -220, 0)
	row.second = Button(row, "", 104, function() if row.onSecond then row.onSecond() end end)
	row.second:SetPoint("RIGHT", -4, 0)
	row.first = Button(row, "", 104, function() if row.onFirst then row.onFirst() end end)
	row.first:SetPoint("RIGHT", row.second, "LEFT", -6, 0)
	rows[i] = row
	return row
end
local function HeaderAt(i)
	if headers[i] then return headers[i] end
	local header = CreateFrame("Frame", nil, child)
	header:SetSize(WIDTH, HEADER_HEIGHT)
	header.label = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	header.label:SetPoint("LEFT", 4, 0)
	local line = header:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(1, 1, 1, 0.08)
	line:SetPoint("BOTTOMLEFT", 4, 0)
	line:SetPoint("BOTTOMRIGHT", -4, 0)
	line:SetHeight(1)
	header:EnableMouse(true)
	header:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:AddLine(self.tip, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	header:SetScript("OnLeave", function() GameTooltip:Hide() end)
	headers[i] = header
	return header
end

local function FillIncoming(row, item)
	local who, name = U.Display(item.from), U.Display(item.name)
	local text
	if item.kind == "K" then
		text = L.TRANSFER_IN_KICK:format(who, item.byGuild, name)
	elseif item.other then
		text = L.TRANSFER_IN_INVITE_FROM:format(who, item.byGuild, name, item.other)
	else
		text = L.TRANSFER_IN_INVITE:format(who, item.byGuild, name)
	end
	row.label:SetText(text)
	local sub = ns.Views.Ago(ns.Now() - item.at)
	if item.tried then sub = sub .. " — " .. L.TRANSFER_STEP_TRIED end
	row.sub:SetText(sub)
	if item.kind == "K" then
		row.first:SetText(L.TRANSFER_KICK)
		row.first:SetEnabled(T.CanRemove(item.name))
	else
		row.first:SetText(L.TRANSFER_INVITE)
		row.first:SetEnabled(T.CanInvite())
	end
	row.first:Show()
	row.onFirst = function()
		Act(item)
		P.Render()
	end
	row.second:SetText(L.TRANSFER_DECLINE)
	row.second:SetEnabled(true)
	row.second:Show()
	row.onSecond = function()
		T.Decline(item)
		P.Render()
	end
end

local function Names(req, state)
	local out = {}
	for _, t in ipairs(req.targets) do
		if t.state == state then out[#out + 1] = U.Display(t.name) end
	end
	return table.concat(out, ", ")
end
local function TaskState(task)
	if task.phase == "done" then
		return task.outcome == "absent" and L.TRANSFER_OUTCOME_ABSENT or L.TRANSFER_OUTCOME_DONE
	end
	local step = (task.phase == "join" and L.TRANSFER_STEP_JOIN or L.TRANSFER_STEP_LEAVE) .. ": "
	if task.localStep then
		if task.tried then return step .. L.TRANSFER_STEP_TRIED end
		return step .. (task.phase == "join" and L.TRANSFER_STEP_INVITE_LOCAL or L.TRANSFER_STEP_KICK_LOCAL)
	end
	local req = task.req
	if not req or #req.targets == 0 then return step .. L.TRANSFER_STATE_NONE end
	local parts = {}
	local got, declined = Names(req, "R"), Names(req, "N")
	if got ~= "" then parts[#parts + 1] = L.TRANSFER_STATE_GOT:format(got) end
	if declined ~= "" then parts[#parts + 1] = L.TRANSFER_STATE_DECLINED:format(declined) end
	if #parts == 0 then
		if Names(req, "queued") ~= "" then parts[1] = L.TRANSFER_STATE_SENDING
		elseif T.Waiting(task) then parts[1] = L.TRANSFER_STATE_WAIT
		else parts[1] = L.TRANSFER_STATE_SILENT end
	end
	return step .. table.concat(parts, "; ")
end

local function FillTask(row, task)
	local name = U.Display(task.name)
	if task.op == "kick" then
		row.label:SetText(L.TRANSFER_TASK_KICK:format(name, task.from))
	else
		row.label:SetText(L.TRANSFER_TASK_MOVE:format(name, task.from, task.to))
	end
	row.sub:SetText(TaskState(task) .. " — " .. ns.Views.Ago(ns.Now() - task.at))
	local open = task.phase ~= "done"
	if open and task.localStep then
		row.first:SetText(task.phase == "join" and L.TRANSFER_INVITE or L.TRANSFER_KICK)
		row.first:SetEnabled(task.phase == "join" and T.CanInvite() or task.phase == "leave" and T.CanRemove(task.name))
		row.onFirst = function() Step(task); P.Render() end
		row.first:Show()
	elseif open and task.req and not T.Waiting(task) then
		row.first:SetText(L.TRANSFER_RETRY)
		row.first:SetEnabled(true)
		row.onFirst = function() T.Retry(task); P.Render() end
		row.first:Show()
	else
		row.onFirst = nil
		row.first:Hide()
	end
	row.second:SetText(open and L.TRANSFER_CANCEL or L.TRANSFER_DISMISS)
	row.second:SetEnabled(true)
	row.second:Show()
	row.onSecond = function()
		T.Cancel(task)
		P.Render()
	end
end

local function Place(frame, y)
	frame:ClearAllPoints()
	frame:SetPoint("TOPLEFT", 0, -y)
	frame:Show()
end

---------------------------------------------------------------------------
-- Состав своей гильдии
---------------------------------------------------------------------------

local function Days(m) return m.online and -1 or (m.days or 0) end
local function SortPeople()
	local out = {}
	for _, m in ipairs(ns.Roster.members) do out[#out + 1] = m end
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

local function Last(m)
	if m.online then return "|cff40ff40" .. L.TRANSFER_ONLINE .. "|r" end
	local d = math.floor(m.days or 0)
	if d < 1 then return L.TRANSFER_TODAY end
	return L.TRANSFER_DAYS:format(d)
end

local function CheckedCount()
	local n = 0
	for _, m in ipairs(ns.Roster.members) do
		if checked[m.key] and T.CanRemove(m.name) then n = n + 1 end
	end
	return n
end

local function Toggle(m)
	if not m or not T.CanRemove(m.name) then return end
	checked[m.key] = not checked[m.key] or nil
	P.Render()
end

-- Отметить неактивных: не в сети дольше указанного числа дней, кого можно исключить.
local function MarkInactive()
	local limit = tonumber(tools.days:GetText() or "")
	if not limit or limit < 0 then limit = ns.Config.TRANSFER_INACTIVE_DAYS end
	for _, m in ipairs(ns.Roster.members) do
		if not m.online and (m.days or 0) >= limit and T.CanRemove(m.name) then checked[m.key] = true end
	end
	P.Render()
end

-- Очередь /gremove по отмеченным в порядке таблицы.
local function KickChecked()
	local entries = {}
	for _, m in ipairs(people) do
		if checked[m.key] and T.CanRemove(m.name) then entries[#entries + 1] = { kind = "K", name = m.name } end
	end
	Run(entries)
	P.Render()
end

local function MemberAt(i)
	if members[i] then return members[i] end
	local r = CreateFrame("Button", nil, child)
	r:SetSize(WIDTH, MEMBER_H)
	local hl = r:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints()
	hl:SetColorTexture(1, 1, 1, 0.07)
	r.check = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
	r.check:SetSize(20, 20)
	r.check:SetPoint("LEFT", 4, 0)
	r.check:SetScript("OnClick", function() ns.SafeCall("кадры: отметка", Toggle, r.person) end)
	r.cells = {}
	for c, col in ipairs(COLUMNS) do
		local fs = Text(r)
		fs:SetPoint("LEFT", r, "LEFT", col.x + 3, 0)
		fs:SetWidth(col.w - 6)
		r.cells[c] = fs
	end
	r:SetScript("OnClick", function() ns.SafeCall("кадры: игрок", Choose, r.person) end)
	r:Hide()
	members[i] = r
	return r
end

-- Поставить строки состава по текущей прокрутке.
local function PlaceMembers()
	local shown = head and head:IsShown()
	local offset = scroll:GetVerticalScroll() or 0
	local first = math.floor(math.max(0, offset - peopleTop) / MEMBER_H) + 1
	for i = 1, MEMBER_ROWS do
		local r = MemberAt(i)
		local index = first + i - 1
		local m = shown and people[index] or nil
		r.person, r.index = m, index
		if m then
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(peopleTop + (index - 1) * MEMBER_H))
			local can = T.CanRemove(m.name)
			r.check:SetEnabled(can)
			r.check:SetChecked(can and checked[m.key] and true or false)
			r.cells[1]:SetText(ns.Views.Name(U.Display(m.name), m.class))
			r.cells[2]:SetText(tostring(m.level or ""))
			r.cells[3]:SetText(m.rankName or "")
			r.cells[4]:SetText(Last(m))
			r:Show()
		else
			r:Hide()
		end
	end
end

local function BuildRoster()
	tools = CreateFrame("Frame", nil, child)
	tools:SetSize(WIDTH, TOOLS_H)
	tools.label = Text(tools)
	tools.label:SetPoint("LEFT", 6, 0)
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
	tools.unit = Text(tools)
	tools.unit:SetPoint("LEFT", tools.days, "RIGHT", 4, 0)
	tools.unit:SetText(L.TRANSFER_INACTIVE_UNIT)
	tools.mark = Button(tools, L.TRANSFER_MARK, 96, MarkInactive)
	tools.mark:SetPoint("LEFT", tools.unit, "RIGHT", 10, 0)
	tools.unmark = Button(tools, L.TRANSFER_UNMARK, 116, function() wipe(checked); P.Render() end)
	tools.unmark:SetPoint("LEFT", tools.mark, "RIGHT", 6, 0)
	tools.kick = Button(tools, "", 210, KickChecked)
	tools.kick:SetPoint("LEFT", tools.unmark, "RIGHT", 6, 0)
	-- Ростер без игроков не в сети: неактивных в нём нет. Показ — та же настройка, что в окне гильдии.
	tools.showAll = Button(tools, L.TRANSFER_SHOW_OFFLINE, 140, function()
		if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
		ns.Roster.RequestScan(true)
	end)
	tools.showAll:SetPoint("RIGHT", -4, 0)
	tools:Hide()
	head = CreateFrame("Frame", nil, child)
	head:SetSize(WIDTH, TABLE_HEAD_H)
	local bg = head:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.13, 0.13, 0.13, 1)
	head.cells = {}
	for c, col in ipairs(COLUMNS) do
		local h = CreateFrame("Button", nil, head)
		h:SetSize(col.w, TABLE_HEAD_H)
		h:SetPoint("LEFT", head, "LEFT", col.x, 0)
		local hl = h:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(1, 1, 1, 0.07)
		h.label = Text(h, "GameFontNormalSmall")
		h.label:SetPoint("LEFT", 3, 0)
		h.label:SetPoint("RIGHT", -3, 0)
		h:SetScript("OnClick", function() ns.SafeCall("кадры: сортировка", SortBy, col.key) end)
		head.cells[c] = h
	end
	head:Hide()
end

-- Раздел состава с отметки y; возвращает новую отметку. Без свежего ростера раздела нет.
local function RenderRoster(y, headerCount)
	local guild = ns.MyGuild()
	if not guild or not ns.Roster.Fresh() or #ns.Roster.members == 0 then
		tools:Hide()
		head:Hide()
		return y, headerCount
	end
	if headerCount > 0 then y = y + SECTION_GAP end
	headerCount = headerCount + 1
	local header = HeaderAt(headerCount)
	header.tip = L.TRANSFER_ROSTER_TIP
	local title = L.TRANSFER_SECTION_ROSTER:format(guild, #ns.Roster.members)
	if not ns.Roster.complete then title = title .. " |cffff8080" .. L.TRANSFER_ROSTER_PARTIAL .. "|r" end
	header.label:SetText(title .. " |cff808080(?)|r")
	Place(header, y)
	y = y + HEADER_HEIGHT + HEADER_GAP
	local count = CheckedCount()
	tools.kick:SetText(L.TRANSFER_KICK_CHECKED:format(count))
	tools.kick:SetEnabled(count > 0)
	tools.showAll:SetShown(not ns.Roster.complete and SetGuildRosterShowOffline ~= nil)
	Place(tools, y)
	y = y + TOOLS_H
	for c, col in ipairs(COLUMNS) do
		local text = L[col.title]
		if col.key == sort.key then text = "|cffffffff" .. text .. (sort.desc and " v" or " ^") .. "|r" end
		head.cells[c].label:SetText(text)
	end
	Place(head, y)
	y = y + TABLE_HEAD_H
	people, peopleTop = SortPeople(), y
	return y + #people * MEMBER_H, headerCount
end

---------------------------------------------------------------------------
-- Раздел
---------------------------------------------------------------------------

function P.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	input = CreateFrame("EditBox", nil, pane, "InputBoxTemplate")
	input:SetSize(180, 22)
	input:SetPoint("TOPLEFT", 22, -30)
	input:SetAutoFocus(false)
	input:SetMaxLetters(64)
	input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- Имя набирает игрок: гильдию «откуда» подставляем по ростеру, сертификатам и отчётам.
	input:SetScript("OnTextChanged", function(_, userInput)
		if not userInput then return end
		ns.SafeCall("кадры: имя", function()
			confirming, note = nil, nil
			local guess = T.GuessGuild(Name())
			if guess then
				from = guess
				if Same(from, to) then to = nil end
			end
			P.Render()
		end)
	end)
	Caption(L.TRANSFER_NAME, input, -4)
	fromButton = Button(pane, L.TRANSFER_PICK, 160, function() OpenList("from", fromButton) end)
	fromButton:SetPoint("LEFT", input, "RIGHT", 14, 0)
	Caption(L.TRANSFER_FROM, fromButton, 2)
	toButton = Button(pane, L.TRANSFER_PICK, 160, function() OpenList("to", toButton) end)
	toButton:SetPoint("LEFT", fromButton, "RIGHT", 12, 0)
	Caption(L.TRANSFER_TO, toButton, 2)
	kickButton = Button(pane, L.TRANSFER_KICK, 104, function() Start("kick") end)
	kickButton:SetPoint("LEFT", toButton, "RIGHT", 12, 0)
	moveButton = Button(pane, L.TRANSFER_MOVE, 104, function() Start("move") end)
	moveButton:SetPoint("LEFT", kickButton, "RIGHT", 6, 0)
	message = pane:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	message:SetPoint("TOPLEFT", 18, -60)
	message:SetPoint("RIGHT", -16, 0)
	message:SetJustifyH("LEFT")
	box = ns.CommandBox.New(pane, 770,
		function() Advance(false); P.Render() end,
		function() queue = nil; P.Render() end)
	box:SetPoint("TOPLEFT", 12, -54)
	scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("BOTTOMRIGHT", -30, 10)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WIDTH, 10)
	scroll:SetScrollChild(child)
	scroll:HookScript("OnVerticalScroll", function() ns.SafeCall("кадры: прокрутка", PlaceMembers) end)
	empty = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 4, -8)
	empty:SetPoint("RIGHT", -4, 0)
	empty:SetJustifyH("LEFT")
	empty:SetText(L.TRANSFER_EMPTY)
	BuildRoster()
	list = CreateFrame("Frame", nil, pane)
	list:SetWidth(220)
	list:SetFrameStrata("DIALOG")
	list:EnableMouse(true)
	local edge = list:CreateTexture(nil, "BACKGROUND", nil, -1)
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)
	edge:SetColorTexture(0.5, 0.5, 0.5, 0.9)
	local bg = list:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0.06, 0.06, 0.06, 0.96)
	list:Hide()
	P.frames = { pane = pane, input = input, from = fromButton, to = toButton, kick = kickButton, move = moveButton,
		message = message, list = list, items = items, rows = rows, headers = headers, empty = empty, box = box,
		tools = tools, head = head, members = members, scroll = scroll,
		peopleTop = function() return peopleTop end }
	pane:Hide()
end

function P.Render()
	if not pane or not pane:IsShown() then return end
	if not T.Rights() then P.Hide(); return end
	RenderForm()
	-- Поле команды встаёт на место строки о правах, список опускается под него.
	local boxOpen = box:IsShown()
	message:SetShown(not boxOpen)
	scroll:ClearAllPoints()
	scroll:SetPoint("TOPLEFT", 12, boxOpen and -(54 + ns.CommandBox.HEIGHT + 4) or -82)
	scroll:SetPoint("BOTTOMRIGHT", -30, 10)
	local sections = {
		{ title = L.TRANSFER_SECTION_INCOMING, tip = L.TRANSFER_INCOMING_TIP, list = T.Incoming(), fill = FillIncoming },
		{ title = L.TRANSFER_SECTION_MINE, tip = L.TRANSFER_MINE_TIP, list = T.Tasks(), fill = FillTask },
	}
	local y, rowCount, headerCount = 0, 0, 0
	for _, section in ipairs(sections) do
		if #section.list > 0 then
			if headerCount > 0 then y = y + SECTION_GAP end
			headerCount = headerCount + 1
			local header = HeaderAt(headerCount)
			header.tip = section.tip
			header.label:SetText(section.title .. " |cff808080(?)|r")
			Place(header, y)
			y = y + HEADER_HEIGHT + HEADER_GAP
			for _, entry in ipairs(section.list) do
				rowCount = rowCount + 1
				local row = RowAt(rowCount)
				section.fill(row, entry)
				Place(row, y)
				y = y + ROW_HEIGHT
			end
		end
	end
	for i = rowCount + 1, #rows do rows[i]:Hide() end
	empty:SetShown(rowCount == 0 and not ns.Roster.Fresh())
	y, headerCount = RenderRoster(y, headerCount)
	for i = headerCount + 1, #headers do headers[i]:Hide() end
	child:SetHeight(math.max(10, y))
	PlaceMembers()
end

function P.Show()
	if not pane or not T.Rights() then return end
	if not from and not to then from = ns.MyGuild() end
	pane:Show()
	P.Render()
end

-- Очередь команд переживает закрытие окна: игрок мог закрыть его, чтобы ввести команду.
function P.Hide()
	if not pane then return end
	pane:Hide()
	list:Hide()
	input:ClearFocus()
	box.edit:ClearFocus()
	tools.days:ClearFocus()
	picking, confirming = nil, nil
end

-- Для команды и тестов: подставить имя и гильдии в форму.
function P.Fill(name, fromGuild, toGuild)
	if not pane then return end
	input:SetText(name or "")
	from, to, confirming, note = fromGuild, toGuild, nil, nil
	P.Render()
end

-- Для тестов: очередь команд и отметки.
function P.Queue() return queue end
function P.Checked() return checked end

local function RenderIfShown()
	if pane and pane:IsShown() then P.Render() end
end
-- Итог команды: системная строка гильдии или новый ростер. Сделанная команда уступает место
-- следующей в очереди.
ns.On("GUILD_MEMBER", function(what, name)
	local key = U.Key(name)
	if not key then return end
	gone[key] = what == "left" or nil
	if what == "left" then checked[key] = nil end
	local e = queue and queue.entries[queue.index]
	if e and U.Key(e.name) == key and (e.kind == "K") == (what == "left") then Advance(true) end
	RenderIfShown()
end)
ns.On("ROSTER", function()
	local e = queue and queue.entries[queue.index]
	if e and not Pending(e) then Advance(true) end
	for key in pairs(checked) do
		if ns.Roster.complete and ns.Roster.byKey[key] == nil then checked[key] = nil end
	end
	RenderIfShown()
end)
ns.On("TRANSFER", RenderIfShown)
ns.On("UNION", RenderIfShown)
