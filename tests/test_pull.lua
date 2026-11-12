-- Прямой запрос отчёта переписи у его автора (Pull.lua): RQ и RA шёпотом, без реле.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

-- Три гильдии, как в test_q1: в главной глава Карл, офицер Арагорн и рядовая Мира; в Севере глава
-- Вера и Борис; в Ордене глава Глеб и, если opts.order2, офицер Ян. extra — ещё рядовые главной.
local function Build(opts)
	opts = opts or {}
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w.version = Wow.HELPER_VERSION -- помощники есть только у версий новее вышедшей
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local cfg = { CHANNEL_CHAT = false }
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, config = cfg })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, realm = "CAMWOWUS2Realm3PvE", class = "PALADIN", config = cfg })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST", config = cfg })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR", config = cfg })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, realm = "CAMWOWUS2Realm5PvE", class = "DRUID", config = cfg })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER", config = cfg })
	if opts.order2 then
		c.Y = w:Client({ first = "Ян", surname = "Ясный", guild = "Орден Чиллзона", rank = 1, class = "MAGE", config = cfg })
	end
	for i = 1, opts.extra or 0 do
		c["R" .. i] = w:Client({ first = ("Рядовой%02d"):format(i), surname = "Чиллзонов", guild = "Чиллзон", rank = 3, config = cfg })
	end
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	w:Run(400)
	T.ok(c.V.ns.Census.IsReporter(), "репортёр Севера — Вера")
	T.ok(c.G.ns.Census.IsReporter(), "репортёр Ордена — Глеб")
	local row = c.V.ns.Data.Row(c.G.guild)
	T.ok(row and row.signed and c.V.ns.Util.SameName(row.origin, c.G:Name()), "Север знает отчёт Ордена от Глеба")
	return w, c
end

local function NoErrors(c)
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | ")) end
end

local function Logged(cl, text)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if tostring(line):find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function Until(w, check, limit)
	for _ = 1, limit or 60 do
		if check() then return true end
		w:Run(1)
	end
	return check()
end

local function Has(cl, guild, st)
	local row = cl.ns.Data.Row(guild)
	return row ~= nil and row.st ~= nil and row.st >= st
end

-- Реле главной гильдии в игре, но пакеты авторов (RL) до них не доходят: отчёты других гильдий
-- никуда не уходят. Свой отчёт главная гильдия по-прежнему рассылает сама.
local function SilenceRelays(c)
	for _, cl in pairs(c) do
		if cl.guild == "Чиллзон" then cl.ns.Comm.On("RL", function() end) end
	end
end

-- Главная гильдия сама отчёты не запрашивает: иначе её реле раздали бы полученный отчёт и Северу,
-- и нельзя было бы проверить, кто в Севере спрашивал.
local function NoMainPull(c)
	for _, cl in pairs(c) do
		if cl.guild == "Чиллзон" then cl.ns.Config.PULL_AFTER = math.huge end
	end
end

-- Запросы RQ клиента cl теряются по дороге: он спрашивает, но ему никто не отвечает, а другие
-- этого не видят. В журнал мира они попадают.
local function LoseRequests(w, cl)
	local deliver = w.Deliver
	w.Deliver = function(self, from, dist, prefix, msg, target, logged)
		if from == cl and dist == "WHISPER" and type(msg) == "string" and msg:find("RQ~", 1, true) then
			self.log[#self.log + 1] = { t = self.now, from = from:Name(), dist = dist, msg = msg, target = target }
			return 0
		end
		return deliver(self, from, dist, prefix, msg, target, logged)
	end
end

-- Согильдиец в игре без аддона: шёпот доходит, но никто не отвечает.
local function SilentAddon(w, cl)
	cl:Logout()
	w:AddOnline(cl.guild, cl:Name() .. "-" .. cl.realm, cl.rank, cl.level, cl.class)
	local find, name = w.FindByTell, cl:Name()
	w.FindByTell = function(self, target)
		if target == name then return { faction = cl.faction, online = true, Fire = function() end } end
		return find(self, target)
	end
end

-- Сколько раз клиент cl отправил своей гильдии (GUILD) что-либо с отчётом своей гильдии.
local function WatchOwnBroadcast(cl)
	local n = { count = 0 }
	local send, mark = cl.ns.Comm.Send, "R1~" .. cl.guild .. "~"
	cl.ns.Comm.Send = function(dist, payload, opts)
		if dist == "GUILD" and type(payload) == "string" and payload:find(mark, 1, true) then n.count = n.count + 1 end
		return send(dist, payload, opts)
	end
	return n
end

-- Шёпоты с запросом (RQ~) или ответом (RA~) после записи журнала мира номер from.
local function Whispers(w, from, kind, who, guild)
	local out = {}
	for i = from + 1, #w.log do
		local e = w.log[i]
		if e.dist == "WHISPER" and e.msg:find(kind .. "~", 1, true) and (not who or e.from == who)
			and (not guild or e.msg:find(kind .. "~" .. guild .. "~", 1, true)) then
			out[#out + 1] = e
		end
	end
	return out
end

-- Отчёт внутри подписанного пакета.
local function SignedReport(cl, wire)
	local clear = (wire or ""):match("^S1~[^~]+~%d+~%d+~[^~]+~(R1~.+)$")
	return clear and cl.ns.Codec.DecodeReport(clear), clear
end

-- Пакет достаётся только клиенту cl, как будто он получил его от реле.
local function Give(cl, wire, author)
	local _, clear = SignedReport(cl, wire)
	cl.ns.Comm.Inject(clear, author:Name(), { via = "RM", authenticated = true, wire = wire })
end

-- Новый отчёт гильдии репортёра cl: подписан, но никуда не ушёл. Возвращает пакет и время отчёта.
local function UnsentReport(w, cl)
	local relay = cl.ns.Relay
	local out = relay.Out
	relay.Out = function() return true end
	w:Run(65)
	cl.ns.Roster.Scan()
	cl.ns.Census.MaybeReport(true)
	w:Run(5)
	relay.Out = out
	local wire = cl.ns.Census.lastRaw
	local r = SignedReport(cl, wire)
	T.ok(r ~= nil, "новый отчёт подписан")
	return wire, r and r.st
end

-- Подделка: отчёт с подписью настоящего пакета, но другим временем.
local function Forge(cl, genuine, st)
	local r, clear = SignedReport(cl, genuine)
	r.st = st
	return genuine:sub(1, #genuine - #clear) .. cl.ns.Codec.EncodeReport(r)
end

T.test("pull: формат RQ и RA, порог выше интервалов отчёта", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local cl = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3 })
	local Codec, C = cl.ns.Codec, cl.ns.Config
	local q = Codec.EncodePullQuery("Орден Чиллзона", "abc_-1", 1234567)
	local guild, fp, st = Codec.DecodePullQuery(q)
	T.eq(guild, "Орден Чиллзона")
	T.eq(fp, "abc_-1")
	T.eq(st, 1234567)
	T.eq(select(3, Codec.DecodePullQuery(Codec.EncodePullQuery("Орден", "f", nil))), 0, "нет отчёта — время 0")
	T.eq(Codec.DecodePullQuery("RQ~Орден~f~ZZ"), nil, "время не base36")
	T.eq(Codec.DecodePullQuery("RQ~" .. ("я"):rep(40) .. "~f~1"), nil, "слишком длинное название")
	local wire = "S1~fp~1~2~sig~R1~Орден~1"
	local g2, w2 = Codec.DecodePullAnswer(Codec.EncodePullAnswer("Орден", wire))
	T.eq(g2, "Орден")
	T.eq(w2, wire)
	T.eq(Codec.DecodePullAnswer("RA~Орден~S1~fp~1~2~sig~M1~L~Орден~1~WA~привет"), nil, "внутри только отчёт")
	T.eq(Codec.DecodePullAnswer("RA~Орден~R1~Орден~1"), nil, "отчёт без подписи не принимается")
	T.ok(C.PULL_AFTER > C.REPORT_IDLE + C.SCAN_EVERY and C.PULL_AFTER > C.REPORT_EVERY,
		"живой репортёр отчитывается раньше порога, даже по ростеру минутной давности")
	T.ok(C.PULL_AFTER + C.PULL_TICK + C.PULL_TRIES * C.PULL_WAIT < C.FRESH,
		"раунд запросов успевает, пока отчёт ещё свежий")
	T.ok(C.PULL_WAIT < C.PULL_RETRY and C.PULL_RETRY <= C.PULL_RETRY_MAX, "паузы между раундами длиннее ожидания")
end)

T.test("pull: реле молчат — отчёт берётся у автора после порога, и гильдия его видит", function()
	local w, c = Build()
	SilenceRelays(c)
	local guild = c.G.guild
	local broadcast = WatchOwnBroadcast(c.G)
	local old = c.V.ns.Data.Row(guild).st
	local from = #w.log
	local age
	T.ok(Until(w, function()
		if not age and #Whispers(w, from, "RQ", c.V:Name(), guild) > 0 then age = c.V.ns.ServerTime() - old end
		return Has(c.B, guild, old + 1)
	end, 1500), "Борис получил новый отчёт Ордена, хотя реле молчат")
	local C = c.V.ns.Config
	T.ok(age and age >= C.PULL_AFTER, "запрос не раньше порога: " .. tostring(age))
	T.ok(age and age <= C.PULL_AFTER + C.PULL_TICK + 15, "и не намного позже: " .. tostring(age))
	local asked = Whispers(w, from, "RQ", c.V:Name(), guild)
	T.eq(#asked, 1, "один запрос")
	T.eq(asked[1].target, c.G:Name(), "автору отчёта")
	T.ok(Logged(c.V, "получен напрямую от " .. c.G:Name()) >= 1, "Вера записала ответ в журнал")
	T.ok(Logged(c.G, "отдан напрямую") >= 1, "Глеб отдал свой отчёт")
	T.eq(#Whispers(w, from, "RQ", c.B:Name()), 0, "второй клиент Севера не спрашивал")
	-- Главная гильдия тоже не получила отчёт Ордена и спросила сама — одним клиентом.
	local main = {}
	for _, e in ipairs(Whispers(w, from, "RQ", nil, guild)) do
		if e.from ~= c.V:Name() then main[e.from] = true end
	end
	local n = 0
	for _ in pairs(main) do n = n + 1 end
	T.ok(n <= 1, "в главной гильдии спрашивал не больше одного клиента")
	T.eq(broadcast.count, 0, "Глеб не рассылал свой отчёт гильдии")
	NoErrors(c)
end)

T.test("pull: запросы репортёра не доходят — после задержки спрашивает помощник", function()
	local w, c = Build()
	SilenceRelays(c)
	NoMainPull(c)
	LoseRequests(w, c.V)
	local guild = c.G.guild
	local old = c.V.ns.Data.Row(guild).st
	local from = #w.log
	local age
	T.ok(Until(w, function()
		if not age and #Whispers(w, from, "RQ", c.B:Name(), guild) > 0 then age = c.B.ns.ServerTime() - old end
		return Has(c.V, guild, old + 1)
	end, 1800), "Вера получила новый отчёт Ордена от помощника")
	local C = c.B.ns.Config
	T.ok(#Whispers(w, from, "RQ", c.V:Name(), guild) >= 1, "Вера спрашивала первой")
	T.ok(age and age >= C.PULL_AFTER + C.PULL_HELPER_DELAY, "помощник ждал задержку: " .. tostring(age))
	T.ok(age and age <= C.PULL_AFTER + C.PULL_HELPER_DELAY + C.PULL_TICK + 15, "и не намного дольше: " .. tostring(age))
	T.ok(Logged(c.B, "получен напрямую от " .. c.G:Name()) >= 1, "Борису ответил Глеб")
	NoErrors(c)
end)

T.test("pull: репортёр получает ответы — помощник не спрашивает", function()
	local w, c = Build()
	SilenceRelays(c)
	NoMainPull(c)
	local guild = c.G.guild
	local from = #w.log
	local C = c.B.ns.Config
	w:Run(2 * (C.PULL_AFTER + C.PULL_HELPER_DELAY))
	T.ok(Logged(c.V, "получен напрямую от " .. c.G:Name()) >= 2, "Вера получала отчёт Ордена не раз")
	T.eq(#Whispers(w, from, "RQ", c.B:Name()), 0, "Борис ни разу не спрашивал")
	T.ok(c.B.ns.ServerTime() - c.B.ns.Data.Row(guild).st < C.PULL_AFTER + C.PULL_HELPER_DELAY, "у Бориса отчёт не старше задержки")
	NoErrors(c)
end)

-- Сколько раз клиент cl отдал реле свой отчёт (Relay.Out с R1 внутри).
local function WatchRelayOut(cl)
	local n = { count = 0 }
	local out = cl.ns.Relay.Out
	cl.ns.Relay.Out = function(kind, wire, ...)
		if type(wire) == "string" and wire:find("R1~", 1, true) then n.count = n.count + 1 end
		return out(kind, wire, ...)
	end
	return n
end

-- Сколько отчётов своей гильдии клиент cl отдал на подпись; raw — последний из них.
local function WatchSeals(cl)
	local n = { count = 0 }
	local seal = cl.ns.Security.Seal
	cl.ns.Security.Seal = function(raw, ...)
		if type(raw) == "string" and raw:find("R1~", 1, true) == 1 then n.count, n.raw = n.count + 1, raw end
		return seal(raw, ...)
	end
	return n
end

-- Запрос RQ от asker к target о гильдии target; st — время отчёта у asker (по умолчанию нет).
local function AskFor(w, asker, target, st)
	local fp = asker.ns.Security.MyCertificate().fp
	w:Deliver(asker, "WHISPER", asker.ns.PREFIX, asker.ns.Codec.EncodePullQuery(target.guild, fp, st or 0), target:Name())
end

T.test("pull: автор отчёта больше не репортёр — отвечает отчётом, подписанным заново по своему ростеру", function()
	local w, c = Build()
	SilenceRelays(c)
	NoMainPull(c)
	local G = c.G
	local guild = G.guild
	-- В Орден входит офицер Аким: по ключу он раньше Глеба и становится репортёром.
	c.Z = w:Client({ first = "Аким", surname = "Алый", guild = guild, rank = 1, class = "ROGUE", config = { CHANNEL_CHAT = false } })
	T.ok(Until(w, function() return c.Z.ns.Census.IsReporter() and not G.ns.Census.IsReporter() end, 600), "репортёр Ордена теперь Аким")
	local gWire = G.ns.Census.lastRaw
	-- Север знает последний отчёт Глеба: нового отчёта репортёра у Глеба нет.
	Give(c.V, gWire, G)
	Give(c.B, gWire, G)
	local old = SignedReport(c.V, gWire).st
	T.eq(c.V.ns.Data.Row(guild).st, old, "у Севера последний отчёт Глеба")
	local broadcast, relayed, seals = WatchOwnBroadcast(G), WatchRelayOut(G), WatchSeals(G)
	local from = #w.log
	T.ok(Until(w, function() return Has(c.B, guild, old + 1) end, 1500), "Север получил новый отчёт Ордена")
	local asked = Whispers(w, from, "RQ", c.V:Name(), guild)
	T.eq(#asked, 1, "один запрос")
	T.eq(asked[1].target, G:Name(), "автору последнего отчёта")
	T.ok(Logged(c.V, "получен напрямую от " .. G:Name()) >= 1, "ответил Глеб")
	T.eq(seals.count, 1, "Глеб подписал отчёт ради ответа")
	T.eq(G.ns.Census.lastRaw, gWire, "свой последний отчёт репортёра Глеб не трогал")
	local row = c.B.ns.Data.Row(guild)
	T.ok(c.B.ns.Util.SameName(row.origin, G:Name()), "у Бориса отчёт Глеба")
	local r = SignedReport(c.B, row.signed)
	T.eq(r.version, G.ns.VERSION, "с версией ответившего")
	T.eq(r.users, G.ns.Census.Users(), "и числом согильдийцев с аддоном по его приветам")
	T.ok(r.users >= 2, "Глеб слышал Акима: " .. r.users)
	T.eq(relayed.count, 0, "через реле этот отчёт не уходил")
	T.eq(broadcast.count, 0, "и своей гильдии тоже")
	NoErrors(c)
end)

T.test("pull: запросы к репортёру теряются — отвечает офицер, и подписи гильдии сходятся", function()
	local w, c = Build({ order2 = true })
	SilenceRelays(c)
	NoMainPull(c)
	local G, Y, V = c.G, c.Y, c.V
	local guild = G.guild
	-- Запросы к Глебу теряются по дороге: он остаётся репортёром, но не отвечает.
	local deliver = w.Deliver
	w.Deliver = function(self, from, dist, prefix, msg, target, logged)
		if target == G:Name() and dist == "WHISPER" and type(msg) == "string" and msg:find("RQ~", 1, true) then
			self.log[#self.log + 1] = { t = self.now, from = from:Name(), dist = dist, msg = msg, target = target }
			return 0
		end
		return deliver(self, from, dist, prefix, msg, target, logged)
	end
	local broadcast, relayed = WatchOwnBroadcast(Y), WatchRelayOut(Y)
	local old = V.ns.Data.Row(guild).st
	local from = #w.log
	T.ok(Until(w, function() return Has(c.B, guild, old + 1) end, 1500), "Север получил новый отчёт Ордена")
	T.ok(G.ns.Census.IsReporter() and not Y.ns.Census.IsReporter(), "репортёр Ордена по-прежнему Глеб")
	local asked = Whispers(w, from, "RQ", V:Name(), guild)
	T.eq(asked[1].target, G:Name(), "сначала автору отчёта")
	T.eq(asked[2] and asked[2].target, Y:Name(), "потом офицеру")
	T.ok(Logged(V, "получен напрямую от " .. Y:Name()) >= 1, "ответил Ян")
	T.eq(Y.ns.Census.lastRaw, nil, "отчёта репортёра у Яна нет")
	T.eq(relayed.count, 0, "через реле Ян ничего не отдавал")
	T.eq(broadcast.count, 0, "и своей гильдии тоже")
	local row = V.ns.Data.Row(guild)
	T.ok(V.ns.Util.SameName(row.origin, Y:Name()), "у Веры отчёт Яна")
	local yst = row.st
	-- Следующий отчёт репортёра по тому же ростеру не противоречит отчёту Яна.
	local fresh, freshSt = UnsentReport(w, G)
	T.ok(freshSt > yst, "отчёт Глеба новее")
	Give(V, fresh, G)
	row = V.ns.Data.Row(guild)
	T.eq(row.st, freshSt, "Вера приняла отчёт Глеба")
	T.eq(row.conflict, nil, "состав главы и офицеров у Глеба и Яна одинаков")
	NoErrors(c)
end)

T.test("pull: отчёт, подписанный ради ответа, отдаётся повторно, а не подписывается на каждый запрос", function()
	local w, c = Build({ order2 = true, extra = 4 })
	local Y = c.Y
	local C = Y.ns.Config
	local broadcast, relayed, seals = WatchOwnBroadcast(Y), WatchRelayOut(Y), WatchSeals(Y)
	T.ok(not Y.ns.Census.IsReporter() and Y.ns.Census.lastRaw == nil, "Ян не репортёр и отчётов не подписывал")
	local from = #w.log
	AskFor(w, c.R1, Y)
	AskFor(w, c.R2, Y)
	w:Run(30)
	T.eq(#Whispers(w, from, "RA", Y:Name()), 2, "ответ обоим")
	T.eq(seals.count, 1, "одна подпись на два запроса")
	local st = Y.ns.Codec.DecodeReport(seals.raw).st
	-- Ростер Яна обновился, но у спросившего уже есть его ответ: ради чуть более свежего ростера
	-- Ян заново не подписывает.
	w:Run(2 * C.SCAN_EVERY)
	T.ok(Y.ns.Roster.report.st > st, "ростер Яна новее ответа")
	from = #w.log
	AskFor(w, c.R3, Y, st)
	w:Run(10)
	T.eq(#Whispers(w, from, "RA", Y:Name()), 0, "у спросившего уже есть этот отчёт — ответа нет")
	T.eq(seals.count, 1, "и новой подписи тоже")
	w:Run(C.PULL_ANSWER_KEEP - 2 * C.SCAN_EVERY - 60)
	AskFor(w, c.R4, Y)
	w:Run(10)
	T.eq(#Whispers(w, from, "RA", Y:Name()), 1, "новый спрашивающий получил ответ")
	T.eq(seals.count, 1, "пока ответ не устарел, он отдаётся без новой подписи")
	w:Run(C.PULL_ANSWER_KEEP)
	from = #w.log
	AskFor(w, c.R1, Y)
	w:Run(30)
	T.eq(#Whispers(w, from, "RA", Y:Name()), 1, "позже снова ответ")
	T.eq(seals.count, 2, "и новая подпись")
	T.eq(Y.ns.Census.lastRaw, nil, "отчёт репортёра у Яна так и не появился")
	T.eq(relayed.count, 0, "через реле ничего не уходило")
	T.eq(broadcast.count, 0, "своей гильдии тоже")
	NoErrors(c)
end)

T.test("pull: подпись не удалась или игрок только что вошёл — он молчит", function()
	local w, c = Build({ order2 = true, extra = 4 })
	local Y = c.Y
	local seal = Y.ns.Security.Seal
	-- Очередь подписи занята.
	Y.ns.Security.Seal = function() return false, "очередь занята" end
	local from = #w.log
	AskFor(w, c.R1, Y)
	w:Run(30)
	T.eq(#Whispers(w, from, "RA", Y:Name()), 0, "без подписи нет ответа")
	-- Подпись взялась, но не удалась.
	Y.ns.Security.Seal = function(_, done)
		done(nil, "ошибка")
		return true
	end
	AskFor(w, c.R2, Y)
	w:Run(30)
	T.eq(#Whispers(w, from, "RA", Y:Name()), 0, "неудачная подпись — тоже")
	T.ok(Logged(Y, "отчёт для ответа напрямую не подписан") >= 2, "обе неудачи в журнале")
	Y.ns.Security.Seal = seal
	-- Только что вошедший офицер: ростер свежий, сертификат есть, но приветы он слышит недолго.
	c.Z = w:Client({ first = "Зоя", surname = "Зоркая", guild = Y.guild, rank = 1, class = "PRIEST", config = { CHANNEL_CHAT = false } })
	local Z = c.Z
	T.ok(Until(w, function() return Z.ns.Roster.Fresh() and Z.ns.Security.MyCertificate() ~= nil end, 120), "у Зои ростер и сертификат")
	T.no(Z.ns.Census.Settled(), "Зоя слушает гильдию меньше HELPER_SETTLE")
	from = #w.log
	AskFor(w, c.R3, Z)
	w:Run(30)
	T.eq(#Whispers(w, from, "RA", Z:Name()), 0, "одиночка без приветов не отвечает")
	T.ok(Until(w, function() return Z.ns.Census.Settled() end, Z.ns.Config.HELPER_SETTLE), "Зоя дослушала приветы")
	from = #w.log
	AskFor(w, c.R4, Z)
	w:Run(30)
	T.eq(#Whispers(w, from, "RA", Z:Name()), 1, "после этого отвечает")
	NoErrors(c)
end)

T.test("pull: автор в игре без аддона — после ожидания отвечает запасной адресат", function()
	local w, c = Build({ order2 = true })
	SilenceRelays(c)
	local guild = c.G.guild
	local old = c.V.ns.Data.Row(guild).st
	SilentAddon(w, c.G)
	c.G = nil
	local from = #w.log
	T.ok(Until(w, function() return Has(c.B, guild, old + 1) end, 1500), "Север получил отчёт Ордена")
	local asked = Whispers(w, from, "RQ", c.V:Name(), guild)
	T.eq(#asked, 2, "два запроса")
	T.eq(asked[1].target, "Глеб Гордый", "сначала молчащему автору")
	T.eq(asked[2].target, c.Y:Name(), "потом офицеру")
	T.ok(asked[2].t - asked[1].t >= c.V.ns.Config.PULL_WAIT, "молчащего ждали до конца")
	T.ok(Logged(c.V, "получен напрямую от " .. c.Y:Name()) >= 1, "ответил Ян")
	T.eq(#Whispers(w, from, "RQ", c.B:Name()), 0, "Борис не спрашивал")
	NoErrors(c)
end)

T.test("pull: никто не отвечает — раунды всё реже, в раунде не больше PULL_TRIES шёпотов", function()
	local w, c = Build({ order2 = true })
	SilenceRelays(c)
	local guild = c.G.guild
	SilentAddon(w, c.G)
	SilentAddon(w, c.Y)
	c.G, c.Y = nil, nil
	local from = #w.log
	w:Run(1000 + 7200)
	local asked = Whispers(w, from, "RQ", c.V:Name(), guild)
	local rounds = {}
	for _, e in ipairs(asked) do
		if e.target == "Глеб Гордый" then rounds[#rounds + 1] = e.t end
	end
	T.ok(#rounds >= 3 and #rounds <= 5, "раундов за два часа после порога: " .. #rounds)
	T.ok(#asked <= 2 * #rounds, "в раунде не больше двух шёпотов: " .. #asked)
	for i = 3, #rounds do
		T.ok(rounds[i] - rounds[i - 1] > rounds[i - 1] - rounds[i - 2], "пауза растёт: " .. table.concat(rounds, ", "))
	end
	-- Помощник не видит, что Вере не отвечают, и спрашивает сам: позже Веры и так же редко.
	local C = c.B.ns.Config
	local helper, helperRounds = Whispers(w, from, "RQ", c.B:Name(), guild), {}
	for _, e in ipairs(helper) do
		if e.target == "Глеб Гордый" then helperRounds[#helperRounds + 1] = e.t end
	end
	T.ok(#helperRounds >= 1 and helperRounds[1] - rounds[1] >= C.PULL_HELPER_DELAY - C.PULL_TICK,
		"помощник начал на задержку позже Веры: " .. table.concat(helperRounds, ", "))
	T.ok(#helperRounds <= #rounds and #helper <= 2 * #helperRounds, "и спрашивает не чаще: " .. #helper)
	T.ok(Logged(c.V, "отчёт Орден Чиллзона напрямую не получен") >= #rounds - 1, "неудачные раунды в журнале")
	NoErrors(c)
end)

T.test("pull: вышедшего из игры адресата не ждут", function()
	local w, c = Build({ order2 = true })
	SilenceRelays(c)
	local guild = c.G.guild
	local gk = c.V.ns.Util.GuildKey(guild)
	c.G:Logout()
	SilentAddon(w, c.Y)
	c.G, c.Y = nil, nil
	local asking = c.V.ns.Pull.Asking()
	local from = #w.log
	local started, second
	T.ok(Until(w, function()
		if not started and asking[gk] then started = w.now end
		if started and not second then
			for _, e in ipairs(Whispers(w, from, "RQ", c.V:Name(), guild)) do
				if e.target == "Ян Ясный" then second = e.t end
			end
		end
		return second ~= nil
	end, 1500), "Вера спросила Яна")
	-- Между запросами только очередь отправки: знакомство с сертификатом и сам запрос.
	T.ok(second - started < c.V.ns.Config.PULL_WAIT, "Глеба, которого нет в игре, не ждали: " .. (second - started))
	NoErrors(c)
end)

T.test("pull: ответ не от того, не о той гильдии и не вовремя отбрасывается до подписи", function()
	local w, c = Build({ order2 = true })
	SilenceRelays(c)
	local guild = c.G.guild
	local V = c.V
	-- Новый отчёт Глеба и Яна: подписаны, но никуда не ушли.
	local fresh, freshSt = UnsentReport(w, c.G)
	local old = V.ns.Data.Row(guild).st
	T.ok(freshSt > old, "у Глеба отчёт новее, чем у Севера")
	-- Ян не репортёр: его отчёт подписывается в обход выборов.
	local isReporter = c.Y.ns.Census.IsReporter
	c.Y.ns.Census.IsReporter = function() return true end
	local yWire = UnsentReport(w, c.Y)
	c.Y.ns.Census.IsReporter = isReporter
	local mainWire = V.ns.Data.Row("Чиллзон").signed
	T.ok(mainWire, "у Севера есть подписанный отчёт главной гильдии")
	-- Глеб получает запрос, но отвечать не будет, пока не разрешим.
	local hold = true
	local send = c.G.ns.Comm.Send
	c.G.ns.Comm.Send = function(dist, payload, opts)
		if hold and type(payload) == "string" and payload:sub(1, 3) == "RA~" then return true end
		return send(dist, payload, opts)
	end
	local direct, opened = 0, 0
	local Direct, Open = V.ns.Relay.Direct, V.ns.Security.Open
	V.ns.Relay.Direct = function(...) direct = direct + 1; return Direct(...) end
	V.ns.Security.Open = function(wire, ...)
		if wire == fresh or wire == yWire then opened = opened + 1 end
		return Open(wire, ...)
	end
	local from = #w.log
	T.ok(Until(w, function() return #Whispers(w, from, "RQ", V:Name(), guild) > 0 end, 1500), "Вера спросила Глеба")
	local sentAt = Whispers(w, from, "RQ", V:Name(), guild)[1].t
	local Codec = V.ns.Codec
	local function RA(sender, msg, dist)
		w:Deliver(sender, dist or "WHISPER", sender.ns.PREFIX, msg, dist ~= "GUILD" and V:Name() or nil)
		w:Run(0.2)
	end
	RA(c.Y, Codec.EncodePullAnswer(guild, yWire)) -- спросили не Яна
	RA(c.G, Codec.EncodePullAnswer("Чиллзон", mainWire)) -- о главной гильдии не спрашивали
	RA(c.G, Codec.EncodePullAnswer(guild, mainWire)) -- внутри отчёт другой гильдии
	RA(c.G, Codec.EncodePullAnswer(guild, V.ns.Data.Row(guild).signed)) -- не новее, чем у Веры
	RA(c.B, Codec.EncodePullAnswer(guild, fresh), "GUILD") -- не шёпотом
	T.eq(direct, 0, "до проверки подписи не дошло ни одно")
	T.eq(opened, 0, "подпись не проверялась")
	-- Прошли первые проверки, но подпись не сходится: пакет Яна от Глеба и подделка времени.
	RA(c.G, Codec.EncodePullAnswer(guild, yWire))
	RA(c.G, Codec.EncodePullAnswer(guild, Forge(c.G, fresh, freshSt + 30)))
	w:Run(2)
	T.eq(direct, 2, "два ответа дошли до проверки подписи")
	T.eq(V.ns.Data.Row(guild).st, old, "ни один не принят")
	-- Настоящий ответ, но после конца ожидания.
	w:Run(sentAt + V.ns.Config.PULL_WAIT + 0.5 - w.now)
	RA(c.G, Codec.EncodePullAnswer(guild, fresh))
	T.eq(direct, 2, "опоздавший ответ отброшен")
	T.eq(V.ns.Data.Row(guild).st, old, "и не принят")
	-- Глеб отвечает сам в следующем раунде.
	hold = false
	T.ok(Until(w, function() return Has(c.B, guild, freshSt) end, 2400), "следующий раунд принёс отчёт Глеба гильдии")
	T.ok(Has(V, guild, freshSt), "и Вере")
	NoErrors(c)
end)

T.test("pull: отвечающий соблюдает лимиты и отвечает только участникам других гильдий", function()
	local w, c = Build({ order2 = true, extra = 5 })
	local G, Y = c.G, c.Y
	local guild = G.guild
	local Codec, C = G.ns.Codec, G.ns.Config
	local broadcast = WatchOwnBroadcast(G)
	local function RQ(cl, about)
		local fp = cl.ns.Security.MyCertificate().fp
		w:Deliver(cl, "WHISPER", cl.ns.PREFIX, Codec.EncodePullQuery(about or guild, fp, 0), G:Name())
	end
	local function Answered(from)
		local out, n = {}, 0
		for _, e in ipairs(Whispers(w, from, "RA", G:Name())) do
			out[e.target] = (out[e.target] or 0) + 1
			n = n + 1
		end
		return out, n
	end
	local from = #w.log
	RQ(Y) -- свой
	RQ(c.R1, "Чиллзон Север") -- не о моей гильдии
	w:Run(30)
	T.eq(select(2, Answered(from)), 0, "своему и о чужой гильдии Глеб не отвечает")
	w:Run(35) -- запрос своего занял место в минутном лимите: оно освобождается
	from = #w.log
	RQ(c.R1)
	RQ(c.R1)
	for i = 2, 5 do RQ(c["R" .. i]) end
	w:Run(150)
	local answered, n = Answered(from)
	T.eq(n, C.PULL_SERVE_PER_MIN, "за минуту не больше " .. C.PULL_SERVE_PER_MIN .. " ответов")
	T.eq(answered[c.R1:Name()], 1, "одному спрашивающему — один ответ")
	T.eq(answered[c.R5:Name()], nil, "сверх лимита — без ответа")
	-- Через минуту место освобождается, но повторно тому же — не раньше PULL_SERVE_GAP.
	from = #w.log
	RQ(c.R1)
	RQ(c.R5)
	w:Run(60)
	answered = Answered(from)
	T.eq(answered[c.R1:Name()], nil, "повтор раньше PULL_SERVE_GAP без ответа")
	T.eq(answered[c.R5:Name()], 1, "через минуту новый спрашивающий получает ответ")
	T.eq(broadcast.count, 0, "отвечающий не рассылает свой отчёт гильдии")
	NoErrors(c)
end)

---------------------------------------------------------------------------
-- Смешанная сеть: настоящие Security, Relay и Census версии 0.9 (tests/legacy/0.9).
---------------------------------------------------------------------------
T.test("pull: клиент 0.9 запросы не знает — молчит без ошибок, а спрашивает за его гильдию помощник", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 37)
	local w = Wow.World()
	w.version = Wow.HELPER_VERSION -- обновлённые клиенты; 0.9 — свои
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, legacy = true })
	c.o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, legacy = true })
	c.v = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, legacy = true })
	c.b = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3, legacy = true })
	w:Run(30)
	w:Init(c.k, c.v)
	w:Pair(c.v, c.k)
	w:Run(180)
	-- Офицер обновился, Нина пришла сразу с новой версией.
	local db = c.o.ns.db
	c.o:Logout()
	c.o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, db = db })
	c.n = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон", rank = 3 })
	w:Run(400)
	T.ok(c.k.ns.Census.IsReporter(), "репортёр главной гильдии — глава на 0.9")
	local guild = c.v.guild
	local row = c.o.ns.Data.Row(guild)
	T.ok(row and row.signed, "офицер знает отчёт Севера")
	local old = row.st
	SilenceRelays(c)
	local from = #w.log
	local age
	T.ok(Until(w, function()
		if #Whispers(w, from, "RQ", c.o:Name(), guild) > 0 then age = c.o.ns.ServerTime() - old end
		return age ~= nil
	end, 1800), "обновлённый офицер спросил вместо старого репортёра")
	local C = c.o.ns.Config
	local after = C.PULL_AFTER + C.PULL_HELPER_DELAY
	T.ok(age >= after and age <= after + C.PULL_TICK + 15, "после задержки помощника: " .. age)
	-- Старому клиенту приходят и запрос, и ответ: оба он отбрасывает молча.
	w:Deliver(c.n, "WHISPER", c.n.ns.PREFIX, c.n.ns.Codec.EncodePullAnswer(guild, row.signed), c.v:Name())
	w:Run(7200)
	for _, id in ipairs({ "k", "v", "b" }) do
		T.eq(#Whispers(w, from, "RA", c[id]:Name()), 0, id .. ": 0.9 не отвечает")
		T.eq(#Whispers(w, from, "RQ", c[id]:Name()), 0, id .. ": 0.9 не спрашивает")
	end
	local asked = #Whispers(w, from, "RQ", c.o:Name(), guild)
	T.ok(asked >= 3 and asked <= 5, "за два часа запросов: " .. asked)
	T.eq(#Whispers(w, from, "RQ", c.n:Name()), 0, "второй новый клиент не спрашивал")
	for _, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
	end
end)

T.test("pull: репортёр гильдии на 0.9 — отвечает обновлённый офицер, подписав отчёт заново", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 37)
	local w = Wow.World()
	w.version = Wow.HELPER_VERSION
	w:Guild("Чиллзон")
	w:Guild("Орден Чиллзона")
	local c = {}
	c.k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, legacy = true })
	c.o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1 })
	c.g = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, legacy = true })
	c.y = w:Client({ first = "Ян", surname = "Ясный", guild = "Орден Чиллзона", rank = 1 })
	w:Run(30)
	w:Init(c.k, c.g)
	w:Pair(c.g, c.k)
	w:Run(400)
	T.ok(c.g.ns.Census.IsReporter() and not c.y.ns.Census.IsReporter(), "репортёр Ордена — глава на 0.9")
	local guild = c.g.guild
	local row = c.o.ns.Data.Row(guild)
	T.ok(row and row.signed, "офицер главной гильдии знает отчёт Ордена")
	local old = row.st
	SilenceRelays(c)
	local from = #w.log
	T.ok(Until(w, function() return Has(c.o, guild, old + 1) end, 1800), "офицер получил новый отчёт Ордена")
	local asked = Whispers(w, from, "RQ", c.o:Name(), guild)
	T.eq(asked[1].target, c.g:Name(), "сначала автору на 0.9")
	T.eq(asked[2] and asked[2].target, c.y:Name(), "потом обновлённому офицеру")
	T.ok(Logged(c.o, "получен напрямую от " .. c.y:Name()) >= 1, "ответил Ян")
	T.eq(c.y.ns.Census.lastRaw, nil, "отчёта репортёра у Яна нет")
	for _, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
	end
end)
