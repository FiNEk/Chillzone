-- Системные ошибки служебных шёпотов: локализация, очередь и повторная связь. Полосы
-- отправки GUILD и WHISPER: свои паузы, квоты и выброс давних заданий, порядок before.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local TARGET = "Ника Маковка"

local function Fresh(chatFilterAPI)
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local c = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", chatFilterAPI = chatFilterAPI })
	w.now = 100
	local sent = {}
	c.env.C_ChatInfo.SendAddonMessage = function(_, msg, dist, target)
		sent[#sent + 1] = { msg = msg, dist = dist, target = target }
		return 0
	end
	return w, c, c.ns.Comm, sent
end

local function Hidden(c, text)
	for _, filter in ipairs(c.filters.CHAT_MSG_SYSTEM or {}) do
		if filter(nil, "CHAT_MSG_SYSTEM", text) then return true end
	end
	return false
end

for _, template in ipairs({
	"No player named '%s' is currently playing.",
	'Персонаж по имени "%s" в игре не найден.',
}) do
	local format = template
	T.test("comm: недоступный адресат — " .. format, function()
		local _, c, comm = Fresh()
		local text = format:format(TARGET)
		T.no(Hidden(c, text), "без служебного шёпота ошибка видна")
		T.ok(comm.SendNow("WHISPER", "KQ~test", TARGET))
		T.ok(Hidden(c, text), "ошибка скрыта ещё до обработчика события")
		c:Fire("CHAT_MSG_SYSTEM", text)
		T.ok(Hidden(c, text), "ошибка скрыта и после обработчика события")
		T.no(comm.Send("WHISPER", "KQ~again", { target = TARGET }), "новые задания не копятся")
		T.no(comm.SendNow("WHISPER", "KQ~again", TARGET), "прямая отправка тоже остановлена")
	end)
end

T.test("comm: недоступный адресат — отмена очереди и продолжение остальных", function()
	local _, c, comm, sent = Fresh()
	local results = {}
	local function Done(ok, why) results[#results + 1] = { ok, why } end
	comm.Send("WHISPER", string.rep("x", 1000), { target = TARGET, done = Done })
	comm.Send("WHISPER", "KQ~test", { target = TARGET, done = Done })
	comm.Send("WHISPER", "KQ~other", { target = "Другой Игрок" })
	comm.Send("GUILD", "H1~test")
	comm.Pump()
	T.eq(#sent, 2, "у каждой полосы свой кусок за тик")
	T.eq(sent[1].target, TARGET, "отправлен первый кусок шёпота")
	T.eq(sent[2].dist, "GUILD", "и сообщение гильдии")
	c:Fire("CHAT_MSG_SYSTEM", ('Персонаж по имени "%s" в игре не найден.'):format(TARGET))
	T.eq(comm.QueueSize(), 1, "убраны и начатое сообщение, и следующее тому же игроку")
	T.same(results, { { false, "offline" }, { false, "offline" } }, "отмена вызывает done ровно один раз")
	comm.Pump()
	T.eq(#sent, 3, "остальная очередь работает")
	T.eq(sent[3].target, "Другой Игрок")
end)

T.test("comm: недоступный адресат — срок ошибки и повторной попытки", function()
	local w, c, comm = Fresh()
	local text = c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET)
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", text)
	w.now = w.now + 11
	T.no(Hidden(c, text), "давняя ошибка не скрывает обычный шёпот игрока")
	T.no(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "пауза ещё действует")
	w.now = w.now + c.ns.Config.RELAY_DOWN
	T.ok(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "после паузы можно проверить доступность")
end)

T.test("comm: недоступный адресат — ответ снимает паузу", function()
	local _, c, comm = Fresh()
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET))
	c:Fire("CHAT_MSG_ADDON", "OTHER", "ZZ~test", "WHISPER", TARGET)
	T.no(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "чужой префикс не снимает паузу")
	c:Fire("CHAT_MSG_ADDON", c.ns.PREFIX, "ZZ~test", "WHISPER", TARGET)
	T.ok(comm.Send("WHISPER", "KQ~test", { target = TARGET }), "свой ответ подтверждает доступность")
end)

T.test("comm: недоступный адресат — чужие и просроченные ошибки видны", function()
	local w, c, comm = Fresh()
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	local text = c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format("Другой Игрок")
	T.no(Hidden(c, text))
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.ok(comm.Send("WHISPER", "KQ~test", { target = "Другой Игрок" }))
	w.now = w.now + 11
	text = c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET)
	T.no(Hidden(c, text))
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.ok(comm.Send("WHISPER", "KQ~test", { target = TARGET }))
end)

T.test("comm: Forever — фильтр через ChatFrameUtil без старой глобальной функции", function()
	local _, c, comm = Fresh("modern")
	T.eq(c.env.ChatFrame_AddMessageEventFilter, nil, "в клиенте нет старой функции")
	T.eq(type(c.env.ChatFrameUtil.AddMessageEventFilter), "function")
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	local text = ('Персонаж по имени "%s" в игре не найден.'):format(TARGET)
	T.ok(Hidden(c, text), "фильтр зарегистрирован через актуальный API")
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.ok(Hidden(c, text), "строка скрыта и после отмены очереди")
end)

for _, logged in ipairs({ false, true }) do
	local useLogged = logged
	T.test("comm: Forever — TargetOffline прекращает отправки, logged=" .. tostring(useLogged), function()
		local _, c, comm = Fresh("modern")
		local calls, cancelled, failures = 0, 0, 0
		local function Offline()
			calls = calls + 1
			return 12 -- Enum.SendAddonMessageResult.TargetOffline
		end
		c.env.C_ChatInfo.SendAddonMessage = Offline
		c.env.C_ChatInfo.SendAddonMessageLogged = Offline
		local function Done(ok, why)
			T.no(ok)
			T.eq(why, "offline")
			cancelled = cancelled + 1
		end
		c.ns.On("WHISPER_UNAVAILABLE", function() failures = failures + 1 end)
		comm.Send("WHISPER", string.rep("x", 1000), { target = TARGET, logged = useLogged, done = Done })
		comm.Send("WHISPER", "KQ~test", { target = TARGET, logged = useLogged, done = Done })
		-- Текстовая строка вообще не приходит: достаточно результата API.
		comm.Pump(); comm.Pump()
		T.eq(calls, 1, "остальная очередь недоступному персонажу не отправляется")
		T.eq(comm.QueueSize(), 0)
		T.eq(cancelled, 2, "каждый callback вызван ровно один раз")
		T.eq(failures, 1, "маршрутизация узнаёт о недоступности сразу")
		T.eq(comm.stats.dropped, 2)
		T.no(comm.Send("WHISPER", "KQ~again", { target = TARGET }))
		T.eq(#c.ns.db.errors, 0, "без скрытых ошибок callback")
	end)
end

T.test("comm: Forever — синхронная ошибка не вызывает callback повторно", function()
	local _, c, comm = Fresh("modern")
	local cancelled = 0
	c.env.C_ChatInfo.SendAddonMessage = function()
		c:Fire("CHAT_MSG_SYSTEM", c.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(TARGET))
		return 0
	end
	comm.Send("WHISPER", "KQ~test", { target = TARGET, done = function(ok, why)
		T.no(ok)
		T.eq(why, "offline")
		cancelled = cancelled + 1
	end })
	comm.Pump()
	T.eq(cancelled, 1)
	T.eq(comm.QueueSize(), 0)
	T.eq(comm.stats.dropped, 1)
	T.eq(#c.ns.db.errors, 0, "насос не завершает отменённое задание повторно")
end)

T.test("comm: диагностика — принятый API шёпот виден с адресатом и кодом", function()
	local _, c, comm = Fresh()
	c.ns.db.settings.debug = true
	T.ok(comm.SendNow("WHISPER", "KQ~private-payload", TARGET))
	local log = table.concat(c.ns.db.log, "\n")
	T.ok(log:find(TARGET, 1, true), "виден фактический адресат")
	T.ok(log:find("KQ", 1, true), "виден тип пакета")
	T.ok(log:find("результат 0", 1, true), "успех API не выдаётся за подтверждённую доставку")
	T.no(log:find("private-payload", 1, true), "содержимое пакета не записывается")
end)

T.test("comm: диагностика — системные строки не зависят от давности наших шёпотов", function()
	local w, c, comm = Fresh()
	c.ns.db.settings.debug = true
	local text = 'Неизвестный ответ |cffffff00"Ника Маковка"|r'
	local before = #c.ns.db.log
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.eq(#c.ns.db.log, before + 1, "ответ виден даже без служебного шёпота")
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", text)
	local log = table.concat(c.ns.db.log, "\n")
	T.ok(log:find("ответ системы после шёпота", 1, true))
	T.ok(log:find("||cffffff00", 1, true), "разметка видна в журнале, а не применяется")
	local n = #c.ns.db.log
	w.now = w.now + 11
	c:Fire("CHAT_MSG_SYSTEM", text)
	T.eq(#c.ns.db.log, n + 1, "отложенные ответы тоже видны")
end)

T.test("comm: диагностика — закрытая строка не читается и не скрывается", function()
	local _, c, comm = Fresh()
	c.ns.db.settings.debug = true
	comm.SendNow("WHISPER", "KQ~test", TARGET)
	local secret = setmetatable({}, { __tostring = function() error("чтение закрытого текста") end })
	c.env.issecretvalue = function(value) return rawequal(value, secret) end
	c:Fire("CHAT_MSG_SYSTEM", secret)
	T.ok(table.concat(c.ns.db.log, "\n"):find("защищённая строка", 1, true))
	T.no(Hidden(c, secret), "нельзя скрывать неизвестную закрытую строку")
	T.eq(#c.ns.db.errors, 0, "защищённый текст не индексируется и не форматируется")
end)

T.test("comm: диагностика — без debug подробные записи отключены", function()
	local _, c, comm = Fresh()
	local before = #c.ns.db.log
	comm.SendNow("WHISPER", "KQ~private-payload", TARGET)
	c:Fire("CHAT_MSG_SYSTEM", "Неизвестный ответ системы")
	T.eq(#c.ns.db.log, before)
end)

---------------------------------------------------------------------------
-- Полосы отправки
---------------------------------------------------------------------------
-- Клиент, у которого игра отвечает по полосам: codes[dist] — код ответа (по умолчанию 0,
-- принято). tried — все попытки, sent — принятые.
local function Lanes(codes)
	local w, c, comm, sent = Fresh()
	codes = codes or {}
	local tried = {}
	c.env.C_ChatInfo.SendAddonMessage = function(_, msg, dist, target)
		local e = { msg = msg, dist = dist, target = target }
		tried[#tried + 1] = e
		local code = codes[dist] or 0
		if code == 0 then sent[#sent + 1] = e end
		return code
	end
	return w, c, comm, sent, tried
end

local function Count(list, dist)
	local n = 0
	for _, e in ipairs(list) do
		if e.dist == dist then n = n + 1 end
	end
	return n
end

T.test("comm: полосы — отказ сервера по GUILD не задерживает шёпот, и наоборот", function()
	local codes = { GUILD = 3 }
	local w, _, comm, sent, tried = Lanes(codes)
	comm.Send("GUILD", "H1~a", { prio = comm.PRIO_CONTROL })
	comm.Send("WHISPER", "GA~1", { target = TARGET, prio = true })
	comm.Send("WHISPER", "GA~2", { target = "Другой Игрок", prio = true })
	comm.Pump()
	T.eq(Count(tried, "GUILD"), 1, "сервер отказал по GUILD")
	T.eq(Count(sent, "WHISPER"), 1, "шёпот ушёл в тот же тик")
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	T.eq(Count(tried, "GUILD"), 1, "GUILD ждёт свою паузу")
	T.eq(Count(sent, "WHISPER"), 2, "а шёпот идёт дальше")
	-- Наоборот: отказ шёпоту не держит GUILD.
	codes.GUILD, codes.WHISPER = 0, 9
	w.now = w.now + 30
	comm.Send("WHISPER", "GA~3", { target = TARGET, prio = true })
	comm.Pump()
	T.eq(Count(sent, "GUILD"), 1, "GUILD после паузы ушёл")
	comm.Send("GUILD", "H1~b", { prio = comm.PRIO_CONTROL })
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	T.eq(Count(sent, "GUILD"), 2, "отказ шёпоту не держит GUILD")
	T.eq(Count(tried, "WHISPER"), 3, "шёпот ждёт своей паузы")
	T.eq(comm.QueueSize("WHISPER"), 1)
end)

for _, relay in ipairs({ false, true }) do
	local isRelay = relay
	T.test("comm: полосы — поток GUILD с приоритетом выше не задерживает шёпот, реле=" .. tostring(isRelay), function()
		local w, c, comm, sent = Lanes()
		c.ns.Relay.IAmRelay = function() return isRelay end
		local parts = isRelay and comm.PARTS_RELAY or 1
		for i = 1, 30 do comm.Send("GUILD", "H1~" .. i, { prio = comm.PRIO_CONTROL }) end
		local delivered
		comm.Send("WHISPER", "GA~1", { target = TARGET, prio = true, done = function(ok) delivered = ok end })
		comm.Pump()
		T.eq(Count(sent, "GUILD"), parts, "GUILD отправил свою квоту")
		T.eq(delivered, true, "шёпот ушёл в первый же тик")
		-- И обычный шёпот получает квоту каждый тик, сколько бы ни ждало в GUILD.
		for i = 1, parts + 1 do comm.Send("WHISPER", "OQ~" .. i, { target = TARGET }) end
		w.now = w.now + comm.SEND_INTERVAL
		comm.Pump()
		T.eq(Count(sent, "WHISPER"), 1 + parts)
		T.eq(Count(sent, "GUILD"), 2 * parts)
	end)
end

T.test("comm: полосы — блокировка чата держит обе", function()
	local codes = {}
	local w, c, comm, sent = Lanes(codes)
	c.lockdown = true
	comm.Send("GUILD", "H1~a", { prio = comm.PRIO_CONTROL })
	comm.Send("WHISPER", "GA~1", { target = TARGET, prio = true })
	comm.Pump()
	comm.Flush(2)
	T.eq(#sent, 0, "в блокировке ничего не уходит")
	c.lockdown = false
	comm.Pump()
	T.eq(#sent, 2, "после неё уходят обе полосы")
	-- Ответ игры «блокировка» (11) на GUILD останавливает и шёпот.
	codes.GUILD = 11
	comm.Send("GUILD", "H1~b", { prio = comm.PRIO_CONTROL })
	comm.Send("WHISPER", "GA~2", { target = TARGET, prio = true })
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	T.eq(#sent, 2, "шёпот ждёт вместе с GUILD")
	codes.GUILD = 0
	w.now = w.now + 3
	comm.Pump()
	T.eq(#sent, 4)
	-- Блокировка дольше HOLD_MAX выбрасывает давние задания обеих полос.
	local why = {}
	c.lockdown = true
	comm.Send("GUILD", "H1~c", { done = function(_, reason) why.guild = reason end })
	comm.Send("WHISPER", "GA~3", { target = TARGET, done = function(_, reason) why.whisper = reason end })
	comm.Pump()
	w.now = w.now + comm.HOLD_MAX + 10
	c.lockdown = false
	comm.Pump()
	T.same(why, { guild = "stale", whisper = "stale" })
	T.eq(#sent, 4)
end)

for _, dist in ipairs({ "GUILD", "WHISPER" }) do
	local held = dist
	local other = held == "GUILD" and "WHISPER" or "GUILD"
	T.test("comm: полосы — простой " .. held .. " выбрасывает только её давние задания", function()
		local codes = { [held] = 9 }
		local w, _, comm, sent = Lanes(codes)
		local results = {}
		local function Opts(d, name)
			return { target = d == "WHISPER" and TARGET or nil, done = function(ok, why) results[name] = why or ok end }
		end
		comm.Send(held, "ZZ~first", Opts(held, "first"))
		comm.Pump()
		w.now = w.now + 1
		comm.Pump() -- полоса стоит: пауза после отказа
		comm.Send(held, "ZZ~held", Opts(held, "held"))
		comm.Send(other, "ZZ~other", Opts(other, "other"))
		w.now = w.now + comm.HOLD_MAX + 10
		codes[held] = 0
		comm.Pump()
		T.eq(results.first, "stale", "начатое после отказа, но не отправленное — выброшено")
		T.eq(results.held, "stale", "давнее задание стоявшей полосы выброшено")
		T.eq(results.other, true, "задание другой полосы не выброшено и ушло")
		T.eq(#sent, 1)
		T.eq(sent[1].msg, "ZZ~other")
	end)
end

T.test("comm: полосы — Flush берёт первое срочное задание открытой полосы", function()
	local _, _, comm, sent, tried = Lanes({ GUILD = 3 })
	comm.Send("GUILD", "H1~a", { prio = comm.PRIO_CONTROL })
	comm.Flush(1)
	T.eq(Count(tried, "GUILD"), 1, "сервер отказал по GUILD")
	comm.Send("WHISPER", "OQ~plain", { target = TARGET })
	comm.Flush(1)
	T.eq(#tried, 1, "обычное задание Flush не отправляет")
	comm.Send("WHISPER", "GA~1", { target = TARGET, prio = true })
	comm.Flush(2)
	T.eq(Count(tried, "GUILD"), 1, "полоса на паузе пропущена")
	T.eq(#sent, 1)
	T.eq(sent[1].msg, "GA~1", "ушло срочное задание открытой полосы")
end)

T.test("comm: полосы — before держит KP шёпотом до KT по GUILD, другие шёпоты не ждут", function()
	local codes = { GUILD = 3 }
	local w, _, comm, sent = Lanes(codes)
	-- Первый KP уже в очереди, когда корень ставится перед ним; второй ставится позже, пока
	-- корень ещё ждёт (так делает обработчик K1 в Security.lua для двух вошедших подряд).
	comm.Send("WHISPER", "KP~a", { target = TARGET, prio = true, key = "kp-own:a" })
	comm.Send("GUILD", "KT~root", { prio = true, key = "root:g", before = "kp-own:a" })
	comm.Send("GUILD", "KT~root", { prio = true, key = "root:g", before = "kp-own:b" })
	comm.Send("WHISPER", "KP~b", { target = "Другой Игрок", prio = true, key = "kp-own:b" })
	comm.Send("WHISPER", "GA~1", { target = "Третий Игрок", prio = true })
	comm.Pump()
	T.eq(#sent, 1, "KT не принят, KP ждут")
	T.eq(sent[1].msg, "GA~1", "ждущие KP не задерживают другой шёпот")
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	comm.Flush(2)
	T.eq(#sent, 1, "ни насос, ни Flush не отправляют KP раньше корня")
	codes.GUILD = 0
	w.now = w.now + 3
	comm.Pump()
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	local order = {}
	for i, e in ipairs(sent) do order[e.msg] = i end
	T.ok(order["KT~root"], "корень ушёл")
	T.ok(order["KP~a"] and order["KP~a"] > order["KT~root"], "стоявший в очереди KP — после корня")
	T.ok(order["KP~b"] and order["KP~b"] > order["KT~root"], "поставленный позже KP — после корня")
	T.eq(comm.QueueSize(), 0)
end)

T.test("comm: полосы — начатый KP досылается после корня, поставленного перед ним", function()
	local codes = {}
	local w, _, comm, sent = Lanes(codes)
	comm.Send("WHISPER", "KP~" .. string.rep("x", 600), { target = TARGET, prio = true, key = "kp-own:a" })
	comm.Pump()
	T.eq(#sent, 1, "первый кусок KP ушёл")
	codes.GUILD = 3
	comm.Send("GUILD", "KT~root", { prio = true, key = "root:g", before = "kp-own:a" })
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	T.eq(#sent, 1, "остаток KP ждёт корня")
	codes.GUILD = 0
	w.now = w.now + 3
	comm.Pump()
	T.eq(sent[2].msg, "KT~root", "корень раньше остатка")
	T.eq(sent[3].dist, "WHISPER", "остаток KP следом")
end)

T.test("comm: полосы — «сервер просит подождать», только пока стоит полоса с сообщениями", function()
	local _, c, comm = Lanes({ WHISPER = 9 })
	local L = c.ns.L
	local function Throttled()
		for _, row in ipairs(c.ns.Activity.List()) do
			if row.text == L.ACT_THROTTLED then return row end
		end
	end
	comm.Send("WHISPER", "KQ~test", { target = TARGET })
	comm.Pump()
	local row = Throttled()
	T.ok(row, "шёпот ждёт паузы сервера")
	T.eq(row and row.detail, L.ACT_THROTTLED_TIP:format(1), "подсказка называет ждущие сообщения")
	comm.Send("GUILD", "H1~a")
	c:Fire("CHAT_MSG_SYSTEM", ('Персонаж по имени "%s" в игре не найден.'):format(TARGET))
	T.eq(comm.QueueSize("WHISPER"), 0, "шёпот отменён")
	T.eq(comm.QueueSize("GUILD"), 1)
	T.no(Throttled(), "пустая полоса на паузе не выдаётся за ожидание")
end)
