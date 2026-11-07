-- Chillzone: ядро — события, таймеры, сохранённые данные, кто я, команды /chillzone.
-- Шина событий и таймеры устроены как в Olympus Core.lua.
local ADDON, ns = ...

local L = ns.L
local U = ns.Util
local C = ns.Config

ns.VERSION = C.VERSION
ns.PREFIX = C.PREFIX

---------------------------------------------------------------------------
-- Вывод и журнал
---------------------------------------------------------------------------
ns.COLOR = "|cff7fd4c1"

function ns.Print(msg, ...)
	if select("#", ...) > 0 then msg = msg:format(...) end
	local frame = DEFAULT_CHAT_FRAME
	if frame then frame:AddMessage(ns.COLOR .. "Chillzone|r: " .. tostring(msg)) end
end

function ns.Log(fmt, ...)
	local msg
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, fmt, ...)
		msg = ok and res or tostring(fmt)
	else
		msg = tostring(fmt)
	end
	local db = ns.db
	if not db then return end
	local log = db.log
	log[#log + 1] = (date and date("%m-%d %H:%M:%S ") or "") .. msg
	while #log > 300 do table.remove(log, 1) end
	if db.settings.debug then ns.Print("|cff999999" .. msg .. "|r") end
end

---------------------------------------------------------------------------
-- Защищённые вызовы: ошибка одного обработчика не ломает остальные. Ошибка попадает в
-- db.errors записью { where, msg, stack, count, first, last, version }, новые первыми; повтор
-- того же where|msg только считается. Стек снимает обработчик xpcall в месте ошибки (в игре
-- debugstack, в тестах debug.traceback). Устроено как Olympus Diagnostics.lua.
---------------------------------------------------------------------------
ns.MAX_ERRORS = 50
ns.STACK_LINES = 12
local warnedError = false
local early = {} -- ошибки до загрузки сохранённых данных

function ns.Stamp()
	return date and date("%Y-%m-%d %H:%M:%S") or "?"
end

local function Lines(s, skip)
	local out = {}
	for line in tostring(s or ""):gmatch("[^\n]+") do
		line = line:gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" and not (skip and #out == 0 and skip(line)) then out[#out + 1] = line end
		if #out >= ns.STACK_LINES then break end
	end
	return table.concat(out, "\n")
end

-- Стек вызовов с уровня level: 1 — сама Stack, 2 — кто её позвал. skip(line) — какие
-- верхние строки выбросить.
local function Stack(level, skip)
	local s
	if type(debugstack) == "function" then
		s = debugstack(level, ns.STACK_LINES + 6, 0)
	else
		local dbg = debug
		if type(dbg) == "table" and type(dbg.traceback) == "function" then s = dbg.traceback("", level) end
	end
	s = tostring(s or ""):gsub("^%s*stack traceback:%s*", "")
	return Lines(s, skip)
end

local function Record(where, msg, stack)
	where, msg = tostring(where or "?"), tostring(msg or "?")
	local db = ns.db
	if not db then
		if #early < 20 then early[#early + 1] = { where = where, msg = msg, stack = stack } end
		return nil
	end
	if type(db.errors) ~= "table" then db.errors = {} end
	local list, now = db.errors, ns.Stamp()
	for i, e in ipairs(list) do
		if type(e) == "table" and e.where == where and e.msg == msg then
			e.count, e.last = (tonumber(e.count) or 1) + 1, now
			if i > 1 then table.insert(list, 1, table.remove(list, i)) end
			return e
		end
	end
	local e = { where = where, msg = msg, stack = stack or "", count = 1, first = now, last = now, version = ns.VERSION }
	table.insert(list, 1, e)
	while #list > ns.MAX_ERRORS do table.remove(list) end
	ns.Log("ошибка в %s: %s", where, msg)
	if not warnedError then
		warnedError = true
		ns.Print(L.ERROR_ONCE)
	end
	return e
end

-- Обработчик xpcall: стек снимается здесь, пока он ещё на месте ошибки (1 — Stack,
-- 2 — этот обработчик, 3 — где ошибка).
local function Handler(err)
	return { msg = tostring(err), stack = Stack(3) }
end

-- В Lua 5.1 xpcall не передаёт аргументы: они уходят через замыкание.
function ns.SafeCall(where, fn, ...)
	local ok, res
	local n = select("#", ...)
	if n == 0 then
		ok, res = xpcall(fn, Handler)
	else
		local args = { ... }
		ok, res = xpcall(function() return fn(unpack(args, 1, n)) end, Handler)
	end
	if not ok then
		if type(res) ~= "table" then res = { msg = tostring(res), stack = "" } end
		Record(where, res.msg, res.stack)
	end
	return ok
end

-- Ошибка, пойманная не SafeCall (например, задача подписи): стек — того, кто её передал.
function ns.CaptureError(where, err)
	return Record(where, err, Stack(3))
end

-- Записи прежних версий — строки «где: что»; ошибки до загрузки данных.
local function LoadErrors(db)
	local out = {}
	for _, e in ipairs(type(db.errors) == "table" and db.errors or {}) do
		if type(e) == "string" then
			local where, msg = e:match("^(.-): (.*)$")
			out[#out + 1] = { where = where or "?", msg = msg or e, stack = "", count = 1, first = "?", last = "?", version = "?" }
		elseif type(e) == "table" and e.msg ~= nil then
			e.where, e.msg, e.count = tostring(e.where or "?"), tostring(e.msg), tonumber(e.count) or 1
			if type(e.stack) ~= "string" then e.stack = "" end
			out[#out + 1] = e
		end
		if #out >= ns.MAX_ERRORS then break end
	end
	db.errors = out
	if type(db.blocked) ~= "table" then db.blocked = {} end
	local pending = early
	early = {}
	for _, x in ipairs(pending) do Record(x.where, x.msg, x.stack) end
end

local listeners = {}

function ns.On(name, fn)
	listeners[name] = listeners[name] or {}
	table.insert(listeners[name], fn)
end
function ns.Fire(name, ...)
	local l = listeners[name]
	if not l then return end
	for i = 1, #l do ns.SafeCall("callback " .. name, l[i], ...) end
end

local eventFrame = CreateFrame("Frame")
local handlers = {}
function ns.RegisterEvent(event, fn)
	if not handlers[event] then
		handlers[event] = {}
		eventFrame:RegisterEvent(event)
	end
	table.insert(handlers[event], fn)
end
eventFrame:SetScript("OnEvent", function(_, event, ...)
	local h = handlers[event]
	if not h then return end
	for i = 1, #h do ns.SafeCall("event " .. event, h[i], ...) end
end)

---------------------------------------------------------------------------
-- Игра запретила этому аддону защищённый вызов (taint). Это не ошибка Lua: такие случаи
-- хранятся в db.blocked, одна запись на вызов, со стеком места, где игра отказала (событие
-- приходит внутри запрещённого вызова). Чужие аддоны — только строка журнала. Как в Olympus
-- Diagnostics.lua, без seterrorhandler.
---------------------------------------------------------------------------
ns.MAX_BLOCKED = 10
ns.blockedSession = 0

-- Верхние строки стека — свой разбор события и xpcall, а не тот, кто сделал вызов.
local function OwnFrame(line)
	return line:find("Chillzone[\\/]Core%.lua") ~= nil or line:find("in function [`'<]?x?pcall") ~= nil
		or line:find("^%[C%]: %?") ~= nil
end

local function OnBlocked(event, addon, func)
	if addon ~= ADDON then
		ns.Log("%s: %s, %s", event, tostring(addon), tostring(func))
		return
	end
	func = tostring(func or "?")
	ns.blockedSession = ns.blockedSession + 1
	local db = ns.db
	if not db then return end
	if type(db.blocked) ~= "table" then db.blocked = {} end
	local list, now = db.blocked, ns.Stamp()
	if ns.blockedSession <= 3 then ns.Log("%s: %s", event, func) end
	for i, b in ipairs(list) do
		if type(b) == "table" and b.event == event and b.func == func then
			b.count, b.last = (tonumber(b.count) or 1) + 1, now
			if i > 1 then table.insert(list, 1, table.remove(list, i)) end
			return
		end
	end
	table.insert(list, 1, { event = event, func = func, count = 1, first = now, last = now, version = ns.VERSION, stack = Stack(3, OwnFrame) })
	while #list > ns.MAX_BLOCKED do table.remove(list) end
end

for _, event in ipairs({ "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
	ns.RegisterEvent(event, function(addon, func) OnBlocked(event, addon, func) end)
end

function ns.After(seconds, where, fn)
	C_Timer.After(seconds, function() ns.SafeCall(where, fn) end)
end

-- Повторяющийся таймер. Стартует со случайным сдвигом (до 10 с), чтобы десяток
-- таймеров после входа не срабатывал в одном кадре.
function ns.Every(seconds, where, fn, noSpread)
	local ticker, cancelled = nil, false
	local handle = {}
	function handle.Cancel()
		cancelled = true
		if ticker and ticker.Cancel then ticker:Cancel() end
	end
	local function Tick() if not cancelled then ns.SafeCall(where, fn) end end
	local spread = noSpread and 0 or math.min(seconds, 10) * math.random()
	C_Timer.After(spread, function()
		if not cancelled then ticker = C_Timer.NewTicker(seconds, Tick) end
	end)
	return handle
end

function ns.Now() return GetTime() end
function ns.ServerTime() return (GetServerTime and GetServerTime()) or time() end

-- Фильтр строк чата (в новых клиентах функция живёт в ChatFrameUtil).
function ns.AddChatFilter(event, fn)
	local add = rawget(_G, "ChatFrame_AddMessageEventFilter")
	if type(add) ~= "function" then
		local CFU = rawget(_G, "ChatFrameUtil")
		add = type(CFU) == "table" and rawget(CFU, "AddMessageEventFilter") or nil
	end
	if type(add) == "function" then pcall(add, event, fn) end
end

---------------------------------------------------------------------------
-- Сохранённые данные
---------------------------------------------------------------------------
local function Defaults(t, d)
	for k, v in pairs(d) do
		if type(v) == "table" then
			if type(t[k]) ~= "table" then t[k] = {} end
			Defaults(t[k], v)
		elseif t[k] == nil then
			t[k] = v
		end
	end
	return t
end

local DB_DEFAULTS = {
	schema = 1,
	settings = { showMap = true, minimap = { angle = 200, hide = false }, debug = false, frame = {} },
	chars = {},
	realms = {},
	log = {},
	errors = {},
	blocked = {},
}

local CHAR_DEFAULTS = {
	shareZones = false, chatOn = true, chatWindow = false, warned = false,
	chatMirror = true, chatTime = false, chatChannel = false, history = { G = {}, O = {} }, historyGuild = false, drafts = {},
}
local STORE_DEFAULTS = { guilds = {}, relays = {}, manual = {}, ignore = {}, chat = { A = {}, C = {}, L = {} } }

local function LoadDB()
	ChillzoneDB = Defaults(type(ChillzoneDB) == "table" and ChillzoneDB or {}, DB_DEFAULTS)
	ns.db = ChillzoneDB
	LoadErrors(ns.db)
end

ns.RegisterEvent("ADDON_LOADED", function(name)
	if name ~= ADDON then return end
	LoadDB()
	ns.Fire("INIT")
end)

function ns.Faction()
	local f = UnitFactionGroup and UnitFactionGroup("player")
	return (f == "Horde" or f == "Alliance") and f or "Neutral"
end

-- Кто я: полное имя, ключ, реалм, группа реалмов. На Forever выясняется, делит ли
-- игра имена (splitNames), — от этого зависят все сравнения имён.
function ns.Identify()
	ns.realm = U.CurrentRealm()
	local name, realm
	if UnitFullName then name, realm = UnitFullName("player") end
	local full, split = U.ParsePlayer(name, realm, ns.realm)
	if split then ns.splitNames = true end
	ns.me = full
	ns.myKey = U.Key(full)
	ns.group = U.GroupOf(ns.realm)
	ns.faction = ns.Faction()
end

function ns.IsMe(name)
	return ns.myKey ~= nil and U.Key(name) == ns.myKey
end

ns.RegisterEvent("PLAYER_LOGIN", function()
	if not ns.db then LoadDB() end
	ns.Identify()
	local db = ns.db
	db.chars[ns.myKey] = Defaults(db.chars[ns.myKey] or {}, CHAR_DEFAULTS)
	ns.char = db.chars[ns.myKey]
	db.realms[ns.group] = db.realms[ns.group] or {}
	db.realms[ns.group][ns.faction] = Defaults(db.realms[ns.group][ns.faction] or {}, STORE_DEFAULTS)
	ns.store = db.realms[ns.group][ns.faction]
	ns.loginAt = ns.Now()
	ns.Log("---- %s, v%s, реалм %s, группа %s, %s, splitNames=%s ----", ns.me, ns.VERSION, ns.realm, ns.group, ns.faction, tostring(ns.splitNames))
	ns.Fire("LOGIN")
end)

---------------------------------------------------------------------------
-- Гильдия игрока
---------------------------------------------------------------------------

-- Название моей гильдии, мой rankIndex (0 — глава) и название звания, или nil.
function ns.MyGuild()
	if not (IsInGuild and IsInGuild()) then return nil end
	local guild, rankName, rankIndex = GetGuildInfo("player")
	if not guild or guild == "" then return nil end
	return guild, rankIndex, rankName
end

-- Моя роль в связи (U.TrustRole): "leader", "officer", "rank", "member" или nil.
function ns.MyTrust()
	local g, rank, rankName = ns.MyGuild()
	if not g or not U.IsMemberGuild(g) then return nil end
	return U.TrustRole(rank, rankName, ns.Roster.IsOfficerRank(rank))
end

-- Я в «своей» гильдии.
function ns.IsMember()
	local g = ns.MyGuild()
	return g ~= nil and U.IsMemberGuild(g)
end

---------------------------------------------------------------------------
-- Управление: /chillzone <команда> [аргументы]. Короткие алиасы принадлежат чату.
---------------------------------------------------------------------------
local commands, order = {}, {}
function ns.Command(name, fn, help)
	if not commands[name] then order[#order + 1] = name end
	commands[name] = { fn = fn, help = help }
end

local statusLines = {}
-- Модули добавляют свои строки в /chillzone status; fn() возвращает строку или nil.
function ns.Status(fn)
	statusLines[#statusLines + 1] = fn
end

-- Строки /chillzone status: их же пишет в отчёт /chillzone bug.
function ns.StatusLines()
	local out = {}
	local guild, rank = ns.MyGuild()
	out[#out + 1] = L.STATUS_ME:format(U.Display(ns.me), ns.myKey or "?", ns.realm or "?", ns.group or "?", tostring(ns.splitNames or false), ns.faction or "?")
	if guild then
		out[#out + 1] = L.STATUS_GUILD:format(guild, rank or -1, U.IsMemberGuild(guild) and L.YES or L.NO, U.IsMainGuild(guild) and L.YES or L.NO)
	else
		out[#out + 1] = L.STATUS_NO_GUILD
	end
	for _, fn in ipairs(statusLines) do
		ns.SafeCall("status", function()
			local line = fn()
			if line then out[#out + 1] = tostring(line) end
		end)
	end
	return out
end

ns.Command("help", function()
	ns.Print(L.HELP_HEADER)
	for _, name in ipairs(order) do
		local c = commands[name]
		if c.help then DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/chillzone " .. name .. "|r — " .. c.help) end
	end
	DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/cz1 /cz2 /cz3|r — " .. L.HELP_CHAT)
	DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/cz текст|r — " .. L.HELP_CHAT_TEXT)
	DEFAULT_CHAT_FRAME:AddMessage("  " .. ns.COLOR .. "/чз /чз1 /чз2 /чз3|r — " .. L.HELP_RU)
end, L.HELP_HELP)

ns.Command("status", function()
	for _, line in ipairs(ns.StatusLines()) do ns.Print(line) end
end, L.HELP_STATUS)

ns.Command("debug", function()
	ns.db.settings.debug = not ns.db.settings.debug
	ns.Print(ns.db.settings.debug and L.DEBUG_ON or L.DEBUG_OFF)
end, L.HELP_DEBUG)

-- Ошибка одной строкой: «[3x] где: что».
function ns.ErrorLine(e)
	if type(e) ~= "table" then return tostring(e) end
	return ("[%sx] %s: %s"):format(tostring(e.count or 1), tostring(e.where or "?"), tostring(e.msg or "?"))
end

ns.Command("log", function(arg)
	local n = tonumber(arg) or 20
	local log = ns.db.log
	for i = math.max(1, #log - n + 1), #log do DEFAULT_CHAT_FRAME:AddMessage("|cff999999" .. log[i] .. "|r") end
	local errors = ns.db.errors or {}
	for i = 1, math.min(3, #errors) do DEFAULT_CHAT_FRAME:AddMessage("|cffff6060" .. ns.ErrorLine(errors[i]):gsub("|", "||") .. "|r") end
	if #errors > 0 or #(ns.db.blocked or {}) > 0 then ns.Print(L.LOG_MORE:format(#errors, #(ns.db.blocked or {}))) end
end, L.HELP_LOG)

SLASH_CHILLZONE1 = "/chillzone"
SlashCmdList.CHILLZONE = function(msg)
	if not ns.me then return end
	local name, rest = U.Trim(msg):match("^(%S*)%s*(.-)$")
	name = U.Fold(name or "")
	if name == "" then
		if ns.UI and ns.UI.Toggle then return ns.UI.Toggle() end
		name = "help"
	end
	local c = commands[name]
	-- Метка — имя команды, а не набранное слово: в журнале ошибок и профайлере нет ввода игрока.
	if not c then name, c = "help", commands.help end
	ns.SafeCall("/chillzone " .. name, c.fn, rest)
end
