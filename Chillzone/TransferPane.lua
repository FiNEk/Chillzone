-- Chillzone: раздел «Кадры» во вкладке «Управление» (Transfer.lua) для глав и офицеров гильдий
-- объединения: форма новой просьбы, строка команды, просьбы ко мне и мои просьбы. Состав своей
-- гильдии и исключение по очереди — в соседнем разделе «Состав» (RosterPane.lua). Исключает и
-- приглашает сам игрок командой в чате игры (Forever не даёт этого ни аддону, ни макросу): раздел
-- показывает команду в своей строке (CommandBox.lua), а итог узнаёт по системной строке гильдии или
-- ростеру. Гильдию выбирают в своём списке, а не в UIDropDownMenu: его общие глобалы на Forever дают taint.
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

-- Команда в строке над списками: исключить или пригласить одного игрока.
local function Act(item)
	local command, why = T.Act(item)
	if not command then note = why; return end
	box:Run({ { kind = item.kind, name = item.name } })
end
local function Step(task)
	local kind, command = T.Step(task)
	if not kind then note = command; return end -- без права второе значение — причина
	box:Run({ { kind = kind, name = task.name } })
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
	-- Строка команды встаёт на место строки о правах, списки под ней не сдвигаются.
	box = ns.CommandBox.New(pane, 770, function() P.Render() end)
	box:SetPoint("TOPLEFT", 12, -54)
	scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -82)
	scroll:SetPoint("BOTTOMRIGHT", -30, 10)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(WIDTH, 10)
	scroll:SetScrollChild(child)
	empty = child:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	empty:SetPoint("TOPLEFT", 4, -8)
	empty:SetPoint("RIGHT", -4, 0)
	empty:SetJustifyH("LEFT")
	empty:SetText(L.TRANSFER_EMPTY)
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
		scroll = scroll }
	pane:Hide()
end

function P.Render()
	if not pane or not pane:IsShown() then return end
	if not T.Rights() then P.Hide(); return end
	RenderForm()
	message:SetShown(not box:IsShown())
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
	empty:SetShown(rowCount == 0)
	for i = headerCount + 1, #headers do headers[i]:Hide() end
	child:SetHeight(math.max(10, y))
end

function P.Show()
	if not pane or not T.Rights() then return end
	if not from and not to then from = ns.MyGuild() end
	pane:Show()
	P.Render()
end

-- Команда переживает закрытие окна: игрок мог закрыть его, чтобы ввести команду.
function P.Hide()
	if not pane then return end
	pane:Hide()
	list:Hide()
	input:ClearFocus()
	box.edit:ClearFocus()
	picking, confirming = nil, nil
end

-- Для команды и тестов: подставить имя и гильдии в форму.
function P.Fill(name, fromGuild, toGuild)
	if not pane then return end
	input:SetText(name or "")
	from, to, confirming, note = fromGuild, toGuild, nil, nil
	P.Render()
end

local function RenderIfShown()
	if pane and pane:IsShown() then P.Render() end
end
-- Итог команды двигает строку команды сама (CommandBox.lua), здесь — только новые состояния просьб.
ns.On("GUILD_MEMBER", RenderIfShown)
ns.On("ROSTER", RenderIfShown)
ns.On("TRANSFER", RenderIfShown)
ns.On("UNION", RenderIfShown)
