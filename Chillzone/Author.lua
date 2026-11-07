-- Chillzone: персонаж автора аддона (Config.AUTHOR). Сетевой власти у автора нет: всё, что здесь
-- есть, рисуется только на его экране, плюс приём отчётов об ошибках.
--
-- «Просмотр как» (только у автора, до конца сессии): вне связи, участник, Капитан, Лорд/Король.
-- Подменяет уровень только там, где решается, что показать: каналы окна чата (Chat.Channels)
-- и вкладка «Отладка» (Debug.Allowed). Chat.MyLevel не трогается — по нему Chat.Send и
-- Chat.Receive решают, что отправлять и принимать, и это остаётся настоящим.
--
-- Отчёт автору: кнопка «Отправить автору» в окне /chillzone bug, когда автор в игре (виден в
-- своём ростере или в свежем отчёте переписи). Отчёт уходит прямым шёпотом на «Имя Фамилия»
-- без реалма кусками B1, по образцу V5/V6 Olympus Workshop.lua: сначала один кусок, остальные —
-- после ответа автора (B2~id~1), по одному через очередь Comm; B2~id~2 — отчёт собран. Не
-- чаще раза в COOLDOWN, не длиннее BUG_MAX байт. Чужой клиент B1 не разбирает, B2 принимается
-- только от автора. У автора принятые отчёты лежат в ChillzoneDB.authorInbox (до INBOX_MAX),
-- список — на вкладке «Отладка», щелчок открывает отчёт в окне копирования.
-- По образцу Olympus ViewAs.lua и Workshop.lua (MIT, см. THIRD_PARTY.md).
local ADDON, ns = ...

local L = ns.L
local U = ns.Util
local C = ns.Config

local Author = {}
ns.Author = Author

Author.COOLDOWN = 600   -- секунд между отчётами одного игрока
Author.BUG_MAX = 4800   -- байт отчёта после кодирования
Author.PIECE = 200      -- байт текста в куске B1
Author.MAX_PIECES = 25
Author.ACK_WAIT = 20    -- ждать ответа автора
Author.PIECE_WAIT = 4   -- запас времени на кусок
Author.INBOX_MAX = 30
Author.PER_HOUR = 3     -- отчётов от одного игрока в час (у автора)
Author.PARTIAL_MAX = 10 -- одновременно собираемых отчётов
Author.PARTIAL_TTL = 120

local CUT_MARK = "\\n[...]"

local view       -- nil — как есть; 0..3 — уровень для показа
local sending    -- отправляемый отчёт: { id, pieces, stage }
local serial = 0
local partial = {} -- у автора: [ключ отправителя] = собираемый отчёт
local rate = {}    -- у автора: [ключ отправителя] = { время начала отчёта, ... }

function Author.IsMe()
	return ns.me ~= nil and U.IsAuthor(ns.me, ns.group)
end

---------------------------------------------------------------------------
-- «Просмотр как»
---------------------------------------------------------------------------
function Author.ViewLevel()
	if view ~= nil and Author.IsMe() then return view end
	return nil
end

function Author.ViewLabel()
	if view == nil then return L.VIEW_REAL end
	return L.VIEW_LEVEL[view] or tostring(view)
end

local function Redraw()
	ns.Fire("SETTINGS")
	local P = ns.ChatPane
	if P and P.Current and P.Current() then P.Select(P.Current()) end
end

-- level: 0..3 или nil (как есть). Только у автора.
function Author.SetView(level)
	if not Author.IsMe() then return false end
	if level ~= nil and (type(level) ~= "number" or level < 0 or level > 3 or level % 1 ~= 0) then return false end
	view = level
	Redraw()
	return true
end

-- Кнопка в «Настройках»: как есть → вне связи → участник → Капитан → Лорд/Король → как есть.
function Author.CycleView()
	if view == nil then return Author.SetView(0) end
	if view >= 3 then return Author.SetView(nil) end
	return Author.SetView(view + 1)
end

ns.Command("view", function(arg)
	if not Author.IsMe() then
		ns.Print(L.VIEW_ONLY_AUTHOR)
		return
	end
	arg = (arg or ""):match("^%s*(%S*)")
	local level = tonumber(arg)
	if arg == "" then
		Author.CycleView()
	else
		Author.SetView(level)
	end
	ns.Print(L.VIEW_NOW:format(Author.ViewLabel()))
end) -- в /chillzone help не показывается: команда автора

---------------------------------------------------------------------------
-- Автор в игре?
---------------------------------------------------------------------------
-- По своему ростеру, иначе по свежим отчётам переписи (глава, офицеры, связные).
function Author.Online()
	local a = C.AUTHOR
	if type(a) ~= "table" or ns.group ~= a.group or Author.IsMe() then return false end
	local key = U.Key(a.name)
	for _, row in ipairs(ns.Roster.members or {}) do
		if row.key == key then return row.online and true or false end
	end
	for _, s in ipairs(ns.Data.Summary(ns.ServerTime())) do
		if s.fresh and s.r then
			local r = s.r
			if r.leader and U.Key(r.leader) == key then return r.leaderOnline and true or false end
			for _, list in ipairs({ r.officers or {}, r.veterans or {} }) do
				for _, o in ipairs(list) do
					if U.Key(o.name) == key then return o.online and true or false end
				end
			end
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Кодирование: «\» в отчёте — «/», перевод строки — «\n». Режется на куски не посреди буквы
-- и не посреди «\n».
---------------------------------------------------------------------------
local function Encode(text)
	return (tostring(text or ""):gsub("|", "!"):gsub("\\", "/"):gsub("[%z\1-\9\11-\31]", ""):gsub("\n", "\\n"))
end

-- Принятое — обычный текст: без кодов игры и управляющих байтов.
local function Decode(text)
	return (text:gsub("|", "!"):gsub("[%z\1-\31]", ""):gsub("\\n", "\n"))
end

local function Cut(s, n)
	if #s <= n then return s, "" end
	local cut = n
	while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
	if s:sub(cut, cut) == "\\" then cut = cut - 1 end
	return s:sub(1, cut), s:sub(cut + 1)
end

function Author.Pieces(text)
	local body, rest = Cut(Encode(text), Author.BUG_MAX - #CUT_MARK)
	if rest ~= "" then body = body .. CUT_MARK end
	local out = {}
	while body ~= "" and #out < Author.MAX_PIECES do
		local piece
		piece, body = Cut(body, Author.PIECE)
		out[#out + 1] = piece
	end
	return out
end

---------------------------------------------------------------------------
-- Отправка (у игрока)
---------------------------------------------------------------------------
local function Piece(job, i)
	return "B1~" .. job.id .. "~" .. i .. "~" .. #job.pieces .. "~" .. job.pieces[i]
end

local function Fail(job, text, again)
	if sending ~= job then return end
	sending = nil
	-- Автора не нашли — отчёт не дошёл, можно отправить снова, не дожидаясь COOLDOWN.
	if again and ns.db then ns.db.bugSentAt = nil end
	ns.Print(text)
end

local function Wait(job, seconds, stage)
	ns.After(seconds, "author wait", function()
		if sending == job and job.stage == stage then Fail(job, L.AUTHOR_NO_ANSWER) end
	end)
end

local function SendRest(job, i)
	if sending ~= job then return end
	if i > #job.pieces then
		job.stage = "last"
		Wait(job, Author.ACK_WAIT, "last")
		return
	end
	ns.Comm.Send("WHISPER", Piece(job, i), {
		target = C.AUTHOR.name,
		done = function(sent)
			if sending ~= job then return end
			if not sent then return Fail(job, L.AUTHOR_FAIL) end
			SendRest(job, i + 1)
		end,
	})
end

-- Можно ли отправить сейчас: true или false и почему.
function Author.CanSend()
	if Author.IsMe() then return false, L.AUTHOR_SELF end
	if sending then return false, L.AUTHOR_BUSY end
	local left = ((ns.db and ns.db.bugSentAt) or 0) + Author.COOLDOWN - ns.ServerTime()
	if left > 0 then return false, L.AUTHOR_WAIT:format(math.ceil(left / 60)) end
	if not Author.Online() then return false, L.AUTHOR_OFFLINE end
	return true
end

function Author.Send(text)
	local ok, why = Author.CanSend()
	if not ok then
		ns.Print(why)
		return false
	end
	local pieces = Author.Pieces(text)
	if #pieces == 0 then return false end
	serial = serial + 1
	local id = ns.Codec.Base36(math.random(0, 46655)) .. ns.Codec.Base36(serial % 1296)
	local job = { id = id, pieces = pieces, stage = "first" }
	sending = job
	ns.db.bugSentAt = ns.ServerTime()
	ns.Print(L.AUTHOR_SENDING:format(#pieces))
	ns.Comm.Send("WHISPER", Piece(job, 1), {
		target = C.AUTHOR.name,
		prio = true,
		done = function(sent)
			if sending ~= job then return end
			if not sent then return Fail(job, L.AUTHOR_FAIL, true) end
			Wait(job, Author.ACK_WAIT, "first")
		end,
	})
	return true
end

function Author.Sending() return sending ~= nil end

-- Кнопка для окна отчёта (Report.Show) или nil, если автор не в игре.
function Author.SendAction(text)
	if Author.IsMe() or not Author.Online() then return nil end
	return { label = L.AUTHOR_SEND, fn = function() Author.Send(text) end }
end

ns.Comm.On("B2", function(msg, sender, dist)
	if dist ~= "WHISPER" or not U.IsAuthor(sender, ns.group) then return end
	local id, code = msg:match("^B2~(%w+)~([12])$")
	local job = sending
	if not job or id ~= job.id then return end
	if code == "2" then
		sending = nil
		ns.Print(L.AUTHOR_DELIVERED)
	elseif job.stage == "first" then
		job.stage = "rest"
		Wait(job, Author.ACK_WAIT + #job.pieces * Author.PIECE_WAIT, "rest")
		SendRest(job, 2)
	end
end)

-- «Нет такого игрока» сразу после шёпота автору: автор вышел. Строка скрывается.
local notFound
local function NotFoundAuthor(text)
	if not sending or type(text) ~= "string" then return false end
	if type(issecretvalue) == "function" and issecretvalue(text) then return false end
	if not notFound then
		local f = type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" and ERR_CHAT_PLAYER_NOT_FOUND_S or nil
		if not f then return false end
		notFound = "^" .. (f:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.+)")) .. "$"
	end
	local who = text:match(notFound)
	return who ~= nil and U.SameName(who, C.AUTHOR.name)
end

ns.RegisterEvent("CHAT_MSG_SYSTEM", function(text)
	if NotFoundAuthor(text) then Fail(sending, L.AUTHOR_OFFLINE, true) end
end)

if ChatFrame_AddMessageEventFilter then
	ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, text)
		return NotFoundAuthor(text)
	end)
end

---------------------------------------------------------------------------
-- Приём (у автора)
---------------------------------------------------------------------------
function Author.Inbox()
	if not ns.db then return {} end
	if type(ns.db.authorInbox) ~= "table" then ns.db.authorInbox = {} end
	return ns.db.authorInbox
end

local function Reply(sender, id, code)
	ns.Comm.Send("WHISPER", "B2~" .. id .. "~" .. code, { target = sender, prio = true })
end

-- Не больше PER_HOUR отчётов от одного игрока в час.
local function Allow(key)
	local now = ns.ServerTime()
	local list = rate[key] or {}
	for i = #list, 1, -1 do
		if now - list[i] > 3600 then table.remove(list, i) end
	end
	rate[key] = list
	if #list >= Author.PER_HOUR then return false end
	list[#list + 1] = now
	return true
end

local function Gc(now)
	for key, p in pairs(partial) do
		if now - p.at > Author.PARTIAL_TTL then partial[key] = nil end
	end
end

local function Keep(p)
	local inbox = Author.Inbox()
	table.insert(inbox, 1, { from = p.from, t = ns.ServerTime(), text = Decode(table.concat(p.parts)) })
	while #inbox > Author.INBOX_MAX do table.remove(inbox) end
	ns.Print(L.AUTHOR_GOT:format(p.from))
	ns.Fire("SETTINGS")
end

ns.Comm.On("B1", function(msg, sender, dist)
	if dist ~= "WHISPER" or not Author.IsMe() then return end
	local id, i, n, piece = msg:match("^B1~(%w+)~(%d+)~(%d+)~(.*)$")
	i, n = tonumber(i), tonumber(n)
	if not id or #id > 8 or not i or not n or n < 1 or n > Author.MAX_PIECES or i < 1 or i > n
		or #piece > Author.PIECE + 8 then return end
	local key = U.Key(sender)
	if not key then return end
	local now = ns.Now()
	Gc(now)
	local p = partial[key]
	if i == 1 then
		if p and p.id == id then return end
		if not p then
			local count = 0
			for _ in pairs(partial) do count = count + 1 end
			if count >= Author.PARTIAL_MAX then return end
		end
		if not Allow(key) then return end
		p = { id = id, n = n, parts = {}, got = 0, at = now, from = U.Display(sender) }
		partial[key] = p
	elseif not p or p.id ~= id or p.n ~= n then
		return
	end
	if not p.parts[i] then
		p.parts[i] = piece
		p.got = p.got + 1
	end
	p.at = now
	if p.got >= p.n then
		partial[key] = nil
		Keep(p)
		Reply(sender, id, 2)
	elseif i == 1 then
		Reply(sender, id, 1)
	end
end)

-- Принятый отчёт в окне копирования.
function Author.Open(i)
	local e = Author.Inbox()[i]
	if not e then return end
	return ns.UI.ShowCopy(L.AUTHOR_INBOX_TITLE:format(e.from or "?"), e.text or "")
end
