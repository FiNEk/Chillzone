-- Счётчики сети (Net.lua): метки сообщений, отправка по полосам, пик за минуту, приём по GUILD и
-- WHISPER с отправителями, сессия в сохранениях и раздел «Сеть» в отчёте журнала.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local TARGET = "Ника Маковка"

-- Клиент, у которого игра отвечает по полосам: codes[dist] — код ответа (по умолчанию 0, принято).
local function Fresh(codes)
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local c = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север" })
	w.now = 100
	codes = codes or {}
	local sent = {}
	c.env.C_ChatInfo.SendAddonMessage = function(_, msg, dist, target)
		local code = codes[dist] or 0
		if code == 0 then sent[#sent + 1] = { msg = msg, dist = dist, target = target } end
		return code
	end
	c.ns.Net.Clear()
	return w, c, c.ns.Comm, sent, codes
end

local function Tx(c, dist) return c.ns.Net.Session().tx[dist] end
local function Rx(c, dist) return c.ns.Net.Session().rx[dist] end

local function Drain(w, comm)
	for _ = 1, 200 do
		if comm.QueueSize() == 0 then return end
		w.now = w.now + comm.SEND_INTERVAL
		comm.Pump()
	end
end

T.test("net: метка — конверт реле снаружи, подпись снята, вложенное в строку чата", function()
	local _, c = Fresh()
	local Label = c.ns.Net.Label
	local signed = "S1~fp_1~123~4~sig-x~"
	T.eq(Label("H1~0.15.0~z"), "H1")
	T.eq(Label("Q1~"), "Q1")
	T.eq(Label(signed .. "M1~A~Чиллзон~12~WA~привет"), "M1", "номер строки чата — не тип")
	T.eq(Label(signed .. "M1~A~Чиллзон~G1~G~1~Чиллзон"), "G1")
	T.eq(Label("RL~P~" .. signed .. "M1~A~Чиллзон~W1~C~1"), "RL/W1")
	T.eq(Label("RG~L~Вера Верная~" .. signed .. "R1~Чиллзон~10"), "RG/R1")
	T.eq(Label("RM~P~Вера Верная~M1~C~Чиллзон~7~WA~текст"), "RM/M1")
	T.eq(Label("RG~L~Вера"), "RG", "обрезанный конверт — по внешнему типу")
	T.eq(Label("S1~fp~1~2"), "S1", "обрезанная подпись — как есть")
	T.eq(Label("x1~"), "?")
	T.eq(Label(""), "?")
	T.eq(Label(nil), "?")
end)

T.test("net: отправка — куски и сообщения по типам, отказы, пауза, выброс, снятие, ожидание", function()
	local w, c, comm, sent, codes = Fresh({ GUILD = 3 })
	comm.Send("GUILD", "H1~a", { prio = comm.PRIO_CONTROL })
	comm.Pump()
	local g = Tx(c, "GUILD")
	T.eq(g.refused["3"], 1, "отказ сервера по коду")
	T.eq(g.pause, 2, "пауза после первого отказа")
	T.eq(g.n, 0)
	codes.GUILD = 0
	w.now = w.now + 2.5
	comm.Pump()
	T.eq(g.n, 1)
	T.eq(g.m, 1)
	T.same({ g.kinds.H1.n, g.kinds.H1.m }, { 1, 1 })
	T.ok(g.waitMax >= 2.5 and g.waitMax < 3, "ожидание от постановки до первого куска: " .. g.waitMax)
	-- Длинное сообщение: куски считаются по одному, сообщение — когда ушло целиком.
	local long = "KD~" .. string.rep("y", 600)
	local parts = #c.ns.Codec.Pack(long, "1")
	T.ok(parts > 1)
	comm.Send("GUILD", long)
	Drain(w, comm)
	T.same({ g.kinds.KD.n, g.kinds.KD.m }, { parts, 1 })
	T.eq(#sent, 1 + parts)
	-- Снятое как ненужное — не выброс.
	comm.Send("GUILD", "KT~skip", { skip = function() return true end })
	comm.Pump()
	T.eq(g.skipped, 1)
	T.eq(next(g.dropped), nil)
	-- Давнее задание стоявшей полосы — выброс по причине и по типу.
	c.lockdown = true
	comm.Send("GUILD", "KT~stale")
	comm.Pump()
	w.now = w.now + comm.HOLD_MAX + 10
	c.lockdown = false
	comm.Pump()
	T.eq(g.dropped.stale, 1)
	T.eq(g.kinds.KT.dropped, 1)
	-- Очередь: наибольшая длина и тик, когда квота кончилась, а задания остались.
	for i = 1, 3 do comm.Send("GUILD", "ZZ~" .. i) end
	T.ok(g.queueMax >= 3)
	local full = g.full
	w.now = w.now + comm.SEND_INTERVAL
	comm.Pump()
	T.eq(g.full, full + 1, "очередь не успевает")
	Drain(w, comm)
	T.eq(g.kinds.ZZ.m, 3)
	-- Шёпот — своя полоса со своими отказами.
	codes.WHISPER = 9
	comm.Send("WHISPER", "GA~1", { target = TARGET, prio = true })
	comm.Pump()
	T.eq(Tx(c, "WHISPER").refused["9"], 1)
	T.eq(g.refused["9"], nil)
	T.eq(g.n, #sent, "по GUILD считано столько кусков, сколько принято игрой")
end)

T.test("net: пик — скользящая минута и её состав, простой окно обнуляет", function()
	local w, c, comm = Fresh()
	local function Stream(n, kind)
		for i = 1, n do comm.Send("GUILD", kind .. "~" .. i) end
		Drain(w, comm)
	end
	Stream(60, "ZA")
	local g = Tx(c, "GUILD")
	local perMinute = math.floor(60 / comm.SEND_INTERVAL)
	T.ok(g.peak >= perMinute - 10 and g.peak <= perMinute, "пик за минуту: " .. g.peak)
	T.ok(type(g.peakAt) == "number")
	T.same(g.top[1], { "ZA", g.peak }, "пик сложился из одного типа")
	local peak = g.peak
	w.now = w.now + 120
	Stream(60, "ZB")
	T.eq(g.peak, peak, "после простоя окно начинается заново, пик тот же")
	T.eq(g.n, 120)
end)

T.test("net: приём — куски по приходу, типы по сборке, отправители GUILD, своё эхо не в счёт", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local a = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1 })
	local b = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 3 })
	w:Run(30)
	local long = "ZQ~" .. string.rep("z", 600)
	local parts = #a.ns.Codec.Pack(long, "1")
	local before = Rx(b, "GUILD").n
	local key = b.ns.Util.Key(a:Name())
	local heard = b.ns.Net.Session().senders[key]
	local fromA = heard and heard.n or 0
	a.ns.Comm.Send("GUILD", long)
	a.ns.Comm.Send("GUILD", "ZW~short")
	a.ns.Comm.Send("WHISPER", "ZY~private", { target = b:Name() })
	w:Run(15)
	local g = Rx(b, "GUILD")
	T.same({ g.kinds.ZQ.n, g.kinds.ZQ.m }, { parts, 1 }, "куски собранного сообщения")
	T.same({ g.kinds.ZW.n, g.kinds.ZW.m }, { 1, 1 })
	T.ok(g.n - before >= parts + 1)
	heard = b.ns.Net.Session().senders[key]
	T.ok(heard.n - fromA >= parts + 1, "куски записаны за отправителем")
	T.ok(heard.peak >= parts + 1)
	T.eq(heard.name and b.ns.Util.Key(heard.name), key)
	T.same({ Rx(b, "WHISPER").kinds.ZY.n, Rx(b, "WHISPER").kinds.ZY.m }, { 1, 1 })
	T.eq(Rx(a, "GUILD").kinds.ZQ, nil, "игра возвращает своё GUILD, но счётчик его не видит")
	T.eq(a.ns.Net.Session().senders[a.ns.Util.Key(a:Name())], nil)
	local report = b.ns.Net.Report()
	T.ok(report:find("Борис Быстрый " .. heard.peak .. "/" .. heard.n, 1, true), "отправитель в отчёте без реалма")
	T.ok(report:find("ZQ " .. parts .. "/1", 1, true))
end)

T.test("net: сессия — переживает /reload, давняя уходит в прошлые, очистка всё стирает", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local opts = { first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1 }
	local c = w:Client(opts)
	w:Run(30)
	c.ns.Comm.Send("GUILD", "ZQ~1")
	w:Run(130)
	local s = c.ns.Net.Session()
	local n, from = s.tx.GUILD.n, s.from
	T.ok(s.tx.GUILD.kinds.ZQ.n == 1 and n >= 1)
	T.ok(s.to > s.from, "отметка времени идёт")
	T.eq(c.ns.db.net.current, s, "сессия лежит в сохранениях")
	-- /reload: та же сессия.
	local db = c.ns.db
	c:Logout()
	w:Run(20)
	c = w:Client(setmetatable({ db = db, reload = true }, { __index = opts }))
	s = c.ns.Net.Session()
	T.eq(s.from, from, "после /reload сессия продолжается")
	T.ok(s.tx.GUILD.n >= n)
	T.eq(#db.net.history, 0)
	-- Вход через полчаса: новая сессия, прошлая урезана и в истории.
	c.ns.Comm.Send("GUILD", "ZQ~2")
	w:Run(30)
	n = s.tx.GUILD.n
	c:Logout()
	w:Run(c.ns.Net.CONTINUE_GAP + 1500)
	c = w:Client(setmetatable({ db = db }, { __index = opts }))
	local fresh = c.ns.Net.Session()
	T.ok(fresh ~= s and fresh.from > from)
	T.eq(fresh.tx.GUILD.kinds.ZQ, nil)
	T.eq(#db.net.history, 1)
	T.eq(db.net.history[1].tx.GUILD.n, n)
	T.eq(db.net.history[1].tx.GUILD.kinds.ZQ.n, 2)
	local L = c.ns.L
	local report = c.ns.Diagnostics.Report()
	T.ok(report:find(L.NET_HISTORY, 1, true))
	T.ok(report:find("(" .. L.NET_PAST .. ")", 1, true))
	T.ok(report:find("(" .. L.NET_CURRENT .. ")", 1, true))
	T.ok(report:find(L.NET_TITLE:format(50, 200), 1, true), "раздел «Сеть» с квотой насоса")
	-- История ограничена.
	for _ = 1, c.ns.Net.HISTORY + 3 do
		c:Logout()
		w:Run(c.ns.Net.CONTINUE_GAP + 600)
		c = w:Client(setmetatable({ db = db }, { __index = opts }))
	end
	T.eq(#db.net.history, c.ns.Net.HISTORY)
	-- «Очистить» в журнале: новая сессия, прошлых нет.
	c.ns.UI.Toggle("journal")
	local f = c.ns.JournalPane.frames
	f.clear.scripts.OnClick(f.clear)
	T.eq(#db.net.history, 0)
	T.eq(db.net.current, c.ns.Net.Session())
	T.eq(c.ns.Net.Session().tx.GUILD.n, 0)
	T.no(c.ns.Diagnostics.Report():find(L.NET_HISTORY, 1, true))
	T.eq(#c.ns.db.errors, 0)
end)

T.test("net: чужая или испорченная запись в сохранениях не ломает вход и отчёт", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local opts = { first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1 }
	for _, net in ipairs({ "строка", { current = "x", history = "y" }, { current = { schema = 99 }, history = { 1, {} } } }) do
		local c = w:Client(setmetatable({ db = { net = net } }, { __index = opts }))
		w:Run(5)
		T.ok(c.ns.Diagnostics.Report():find(c.ns.L.NET_TITLE:format(50, 200), 1, true))
		T.eq(c.ns.db.net.current, c.ns.Net.Session())
		T.eq(#c.ns.db.errors, 0)
		c:Logout()
	end
end)
