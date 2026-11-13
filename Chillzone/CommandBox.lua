-- Chillzone: строка с готовой командой игры (/gremove, /ginvite) для «Состава», «Кадров» и «Заявок».
-- Forever не даёт ни аддону, ни макросу исключать и приглашать в гильдию: команду вводит сам
-- игрок в чате игры. Поле — своё: поле ввода чата игры аддон не трогает (taint), игрок
-- копирует команду (Ctrl+C) и вставляет её сам. Строка ведёт и очередь команд: следующая
-- появляется, только когда системная строка гильдии (Roster.GuildEvent, событие GUILD_MEMBER) или
-- ростер покажут итог текущей. Таймеров нет: «Пропустить» и «Стоп» — у игрока.
local ADDON, ns = ...
local L, U = ns.L, ns.Util

local Box = { HEIGHT = 24 }
ns.CommandBox = Box

local boxes = {} -- все строки: итог команды двигает очередь в каждой
local gone = {} -- [ключ] = системная строка гильдии сказала, что игрок ушёл

local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("команда: щелчок", fn) end)
	return b
end

-- Ушёл ли игрок по системной строке гильдии (при неполном ростере только она это доказывает).
function Box.Gone(name)
	local key = U.Key(name)
	return key ~= nil and gone[key] == true
end

-- Ждёт ли команда игрока: исключённый ещё в гильдии (или ростер неполный и системной строки не
-- было), приглашённого в ней ещё нет.
function Box.Pending(e)
	if e.kind == "K" then return not Box.Gone(e.name) and (ns.Roster.RankOf(e.name) ~= nil or not ns.Roster.complete) end
	return ns.Roster.RankOf(e.name) == nil
end

-- Строка на parent шириной width; место ей задаёт владелец (SetPoint). onChange(event, done, total)
-- зовётся после каждого шага очереди: "next" — новая команда, "finish" — очередь кончилась,
-- "stop" — игрок её остановил.
function Box.New(parent, width, onChange)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(width, Box.HEIGHT)
	local function Changed(event, done, total)
		if onChange then onChange(event, done, total) end
	end
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.title:SetPoint("LEFT", 4, 0)
	f.title:SetJustifyH("LEFT")
	f.title:SetWordWrap(false)
	local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	edit:SetSize(230, 22)
	edit:SetPoint("LEFT", f.title, "RIGHT", 12, 0)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(80)
	f.edit = edit
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetPoint("LEFT", edit, "RIGHT", 10, 0)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetWordWrap(false)
	f.close = Button(f, L.COMMAND_CLOSE, 80, function() f:Stop() end)
	f.close:SetPoint("RIGHT", -4, 0)
	f.skip = Button(f, L.COMMAND_SKIP, 96, function() f:Advance(false) end)
	f.alt = Button(f, "", 96, function()
		local fn = f.altFn
		f:Stop()
		if fn then fn() end
	end)
	-- Поле только для чтения: набранное заменяется командой, выделенной для копирования.
	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput and f.command and self:GetText() ~= f.command then
			self:SetText(f.command)
			self:HighlightText()
		end
	end)
	edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- После Ctrl+C фокус уходит из поля: следующий Enter уже открывает чат игры.
	edit:SetScript("OnKeyDown", function(self, key)
		if key == "C" and IsControlKeyDown and IsControlKeyDown() then
			f.hint:SetText(L.COMMAND_COPIED)
			ns.After(0.05, "команда скопирована", function() self:ClearFocus() end)
		end
	end)
	edit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(f.title:GetText() or "", 1, 0.82, 0, true)
		GameTooltip:AddLine(f.tip or L.COMMAND_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	edit:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Кнопки справа налево: «Закрыть» или «Стоп», «Пропустить» (в очереди), своя кнопка владельца.
	local function Layout(many)
		f.skip:SetShown(many)
		f.alt:SetShown(not many and f.altFn ~= nil)
		f.close:SetText(many and L.COMMAND_STOP or L.COMMAND_CLOSE)
		local last = f.close
		for _, b in ipairs({ f.skip, f.alt }) do
			if b:IsShown() then
				b:ClearAllPoints()
				b:SetPoint("RIGHT", last, "LEFT", -6, 0)
				last = b
			end
		end
		f.hint:SetPoint("RIGHT", last, "LEFT", -8, 0)
	end

	-- Показать текущую команду очереди. Фокус — только в видимом окне: очередь идёт дальше и при
	-- закрытом, а скрытое поле не должно забирать клавиатуру.
	local function Open()
		local q = f.queue
		local e = q.entries[q.index]
		local many = #q.entries > 1
		local title = e.kind == "K" and L.COMMAND_KICK or L.COMMAND_INVITE
		if many then title = title .. " " .. L.COMMAND_PROGRESS:format(q.index, #q.entries) end
		f.command = ns.Roster.GuildCommand(e.kind, e.name)
		f.tip = q.tip or (e.kind == "K" and L.COMMAND_KICK_TIP or L.COMMAND_INVITE_TIP)
		f.title:SetText(title .. ":")
		f.hint:SetText(L.COMMAND_HINT)
		Layout(many)
		f:Show()
		edit:SetText(f.command)
		if parent:IsVisible() and f:IsVisible() then
			edit:SetFocus()
			edit:HighlightText()
		end
	end

	local function Finish(event)
		local q = f.queue
		f.queue, f.command, f.altFn = nil, nil, nil
		edit:ClearFocus()
		f:Hide()
		if q then Changed(event, q.done, #q.entries) end
	end

	-- Следующая команда, которая ещё ждёт игрока; resolved — текущая сделана, а не пропущена.
	function f.Advance(self, resolved)
		local q = self.queue
		if not q then return end
		if resolved then q.done = q.done + 1 end
		repeat
			q.index = q.index + 1
		until not q.entries[q.index] or Box.Pending(q.entries[q.index])
		if q.entries[q.index] then
			Open()
			Changed("next", q.done, #q.entries)
		else
			Finish("finish")
		end
	end

	-- Команды по одной: entries = { { kind = "K" или "I", name } }. opts.alt = { text, fn } — своя
	-- кнопка у одиночной команды (сама строка при этом закрывается), opts.tip — подсказка поля.
	function f.Run(self, entries, opts)
		opts = opts or {}
		self.queue = { entries = entries, index = 0, done = 0, tip = opts.tip }
		self.altFn = opts.alt and opts.alt.fn or nil
		if opts.alt then self.alt:SetText(opts.alt.text) end
		self:Advance(false)
	end
	function f.Stop(self)
		if self.queue then Finish("stop") else self:Hide() end
	end
	-- Текущая команда: { kind, name } или nil.
	function f.Current(self)
		local q = self.queue
		return q and q.entries[q.index] or nil
	end
	function f.Command(self) return self:IsShown() and self.command or nil end
	f:Hide()
	boxes[#boxes + 1] = f
	return f
end

-- Итог команды: системная строка гильдии или новый ростер. Сделанная команда уступает место
-- следующей в очереди.
ns.On("GUILD_MEMBER", function(what, name)
	local key = U.Key(name)
	if not key then return end
	gone[key] = what == "left" or nil
	for _, f in ipairs(boxes) do
		local e = f:Current()
		if e and U.Key(e.name) == key and (e.kind == "K") == (what == "left") then f:Advance(true) end
	end
end)
ns.On("ROSTER", function()
	for _, f in ipairs(boxes) do
		local e = f:Current()
		if e and not Box.Pending(e) then f:Advance(true) end
	end
end)
