-- Ответ на Q1 из кэша соседей (Census.lua): репортёр отвечает первым, остальные по общей очереди
-- досылают то, чего никто не показал гильдии.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

-- Три гильдии, как в test_relay: в главной глава Карл, офицер Арагорн и рядовая Мира; extra —
-- столько ещё рядовых главной гильдии. Канал игры выключен: проверяется только путь через реле.
-- versions: номер аддона клиента по его имени в c (A, K, R1...), all — у остальных; по умолчанию
-- все — версия с помощниками (Wow.HELPER_VERSION).
local function Build(extra, versions)
	versions = versions or {}
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w.version = versions.all or Wow.HELPER_VERSION
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local cfg = { CHANNEL_CHAT = false }
	local c = {}
	c.A = w:Client({ version = versions.A, first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, config = cfg })
	c.K = w:Client({ version = versions.K, first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, realm = "CAMWOWUS2Realm3PvE", class = "PALADIN", config = cfg })
	c.M = w:Client({ version = versions.M, first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST", config = cfg })
	c.B = w:Client({ version = versions.B, first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR", config = cfg })
	c.V = w:Client({ version = versions.V, first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, realm = "CAMWOWUS2Realm5PvE", class = "DRUID", config = cfg })
	c.G = w:Client({ version = versions.G, first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER", config = cfg })
	for i = 1, extra or 0 do
		c["R" .. i] = w:Client({ version = versions["R" .. i], first = ("Рядовой%02d"):format(i), surname = "Чиллзонов", guild = "Чиллзон", rank = 3, config = cfg })
	end
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	w:Run(400)
	return w, c
end

local function Key(cl, name) return cl.ns.Util.Key(name) end

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

-- Главная гильдия: репортёр, второй офицер и рядовая Мира.
local function MainRoles(c)
	local reporter = c.K.ns.Census.IsReporter() and c.K or c.A
	T.ok(reporter.ns.Census.IsReporter(), "у главной гильдии есть репортёр")
	T.no(c.M.ns.Census.IsReporter(), "рядовая не репортёр")
	return reporter, reporter == c.K and c.A or c.K, c.M
end

-- Репортёр жив, но на Q1 не отвечает.
local function Mute(cl)
	cl.ns.Comm.On("Q1", function() end)
end

-- Отметки повтора (RELAY_DEDUPE) живут только в памяти: после входа в игру их нет. Forget стирает
-- одни отчёты, и без ожидания клиент отбросил бы как повтор тот же пакет, если получил его недавно.
-- Ждать можно, только когда новых отчётов не будет: остальные гильдии вышли.
local function Settle(w, cl)
	w:Run(cl.ns.Config.RELAY_DEDUPE + 1)
end

-- Клиент забывает переписи других гильдий.
local function Forget(cl)
	for gk, row in pairs(cl.ns.store.guilds) do
		if not row.mine then cl.ns.store.guilds[gk] = nil end
	end
end

-- Отчёт внутри подписанного пакета.
local function SignedReport(cl, wire)
	local clear = (wire or ""):match("^S1~[^~]+~%d+~%d+~[^~]+~(R1~.+)$")
	return clear and cl.ns.Codec.DecodeReport(clear), clear
end

-- Новый отчёт гильдии репортёра cl: подписан, но реле не достался. Возвращает пакет и время отчёта.
local function UnsentReport(w, cl)
	local relay = cl.ns.Relay
	local out = relay.Out
	relay.Out = function() return true end
	w:Run(65)
	cl.ns.Roster.Scan()
	local st = cl.ns.Roster.report.st
	cl.ns.Census.MaybeReport(true)
	w:Run(5)
	relay.Out = out
	local wire = cl.ns.Census.lastRaw
	local r = SignedReport(cl, wire)
	T.ok(r and r.st == st, "новый отчёт подписан")
	return wire, st
end

-- Пакет достаётся только клиенту cl, как будто он один получил его от реле.
local function Give(cl, wire, author)
	local _, clear = SignedReport(cl, wire)
	cl.ns.Comm.Inject(clear, author:Name(), { via = "RM", authenticated = true, wire = wire })
end

-- Счётчик RG отчётов в гильдию: сколько раз каждый клиент отдал гильдии пакет. sent[пакет][имя].
local function CountGuildReports(c)
	local sent = {}
	for id, cl in pairs(c) do
		local send = cl.ns.Comm.Send
		cl.ns.Comm.Send = function(dist, payload, opts)
			local ok, why = send(dist, payload, opts)
			if dist == "GUILD" and type(payload) == "string" and payload:sub(1, 5) == "RG~L~" then
				local inner = payload:match("^RG~L~[^~]+~(.+)$")
				local job = { payload = payload, guard = opts and opts.guard }
				sent[inner] = sent[inner] or {}
				sent[inner][id] = job
			end
			return ok, why
		end
	end
	return sent
end

-- Сколько раз пакет начал уходить гильдии после записи журнала мира номер from: первый кусок RG
-- содержит начало пакета. Задание, отменённое проверкой «уже показано», в журнал не попадает.
local function Sends(w, from, inner)
	local n, head = 0, "RG~L~"
	for i = from + 1, #w.log do
		local entry = w.log[i]
		if entry.dist == "GUILD" and entry.msg:find(head, 1, true) and entry.msg:find(inner:sub(1, 60), 1, true) then n = n + 1 end
	end
	return n
end

local function Until(w, check, limit)
	for _ = 1, limit or 180 do
		if check() then return true end
		w:Run(1)
	end
	return check()
end

T.test("q1: репортёр молчит — спросивший получает отчёты от соседа", function()
	local w, c = Build()
	local reporter, officer, member = MainRoles(c)
	Mute(reporter)
	local north, order = officer.ns.Data.Row("Чиллзон Север"), officer.ns.Data.Row("Орден Чиллзона")
	T.ok(north and north.signed and order and order.signed, "у офицера есть отчёты обеих гильдий")
	Forget(member)
	T.eq(member.ns.Census.Refresh(), "census", "рядовая спрашивает гильдию")
	T.ok(Until(w, function()
		local n, o = member.ns.Data.Row("Чиллзон Север"), member.ns.Data.Row("Орден Чиллзона")
		return n and o and n.st >= north.st and o.st >= order.st
	end), "рядовая получила обе переписи, хотя репортёр молчит")
	T.ok(Logged(officer, "ответ на Q1 вместо репортёра") >= 1, "ответил офицер, первый в очереди помощников")
	NoErrors(c)
end)

T.test("q1: сосед досылает отчёт свежее, чем показал репортёр", function()
	local w, c = Build()
	local reporter, asker, member = MainRoles(c)
	local guild = c.G.guild
	local wire, st = UnsentReport(w, c.G)
	Give(member, wire, c.G)
	T.eq(member.ns.Data.Row(guild).st, st, "у рядовой отчёт Ордена свежее")
	T.ok(reporter.ns.Data.Row(guild).st < st, "репортёр знает только прежний")
	local sent = CountGuildReports(c)
	asker.ns.store.guilds[asker.ns.Util.GuildKey(guild)] = nil
	asker.ns.Census.Refresh()
	T.ok(Until(w, function()
		local row = asker.ns.Data.Row(guild)
		return row and row.st == st
	end), "спросивший получил свежий отчёт от рядовой")
	T.ok(sent[wire] and sent[wire].M, "рядовая отдала свой свежий отчёт")
	local north = member.ns.Data.Row("Чиллзон Север").signed
	T.no(sent[north] and sent[north].M, "отчёт Севера, показанный репортёром, рядовая не повторяет")
	NoErrors(c)
end)

T.test("q1: при одинаковом кэше у десятков клиентов отчёт выкладывают один-два", function()
	local w, c = Build(24)
	local reporter, _, member = MainRoles(c)
	Mute(reporter)
	-- Остальные гильдии выходят: новых отчётов нет, считаются только ответы на Q1.
	for _, id in ipairs({ "B", "V", "G" }) do c[id]:Logout() end
	Settle(w, member)
	local wires, holders = {}, {}
	for _, guild in ipairs({ "Чиллзон Север", "Орден Чиллзона" }) do
		wires[guild], holders[guild] = member.ns.Data.Row(guild).signed, 0
		for _, cl in pairs(c) do
			local row = cl.guild == "Чиллзон" and cl.ns.Data.Row(guild)
			if row and row.signed == wires[guild] then holders[guild] = holders[guild] + 1 end
		end
		T.ok(holders[guild] >= 20, guild .. ": тот же пакет у " .. holders[guild] .. " клиентов главной гильдии")
	end
	local from = #w.log
	Forget(member)
	member.ns.Census.Refresh()
	w:Run(240)
	for guild, wire in pairs(wires) do
		local row = member.ns.Data.Row(guild)
		T.eq(row and row.signed, wire, "спросившая получила " .. guild)
		local n = Sends(w, from, wire)
		T.ok(n >= 1 and n <= 2, guild .. ": отчёт выложили " .. n .. " раз")
	end
	T.eq(Logged(member, "слишком много отчётов не от репортёра"), 0, "ответ не упирается в лимит получателя")
	NoErrors(c)
end)

-- Подделка: отчёт Ордена с подписью настоящего пакета, но другим временем.
local function Forge(cl, genuine, st)
	local r, clear = SignedReport(cl, genuine)
	r.st = st
	return genuine:sub(1, #genuine - #clear) .. cl.ns.Codec.EncodeReport(r)
end

T.test("q1: подделка под показанный отчёт не глушит честный ответ", function()
	local w, c = Build(1)
	local reporter, helper = MainRoles(c)
	local attacker, asker = c.M, c.R1
	Mute(reporter)
	Mute(attacker) -- изменённый клиент сам не помогает
	local guild = c.G.guild
	-- Остальные гильдии выходят: отчёт Ордена не обновится за время теста.
	for _, id in ipairs({ "B", "V", "G" }) do c[id]:Logout() end
	Settle(w, asker)
	local genuine = helper.ns.Data.Row(guild).signed
	T.eq(helper.ns.Census.HelperSlot(Key(helper, asker:Name())), 1, "офицер — первый помощник")
	local function Show(wire)
		w:Deliver(attacker, "GUILD", attacker.ns.PREFIX, attacker.ns.Codec.EncodeRM("RG", "L", c.G:Name(), wire), nil, false)
	end
	local function Ask()
		Forget(asker)
		T.eq(asker.ns.Census.Refresh(), "census", "спросивший шлёт Q1")
		w:Run(1)
	end

	-- Подделка с большим временем совпадает с настоящим отчётом только по названию гильдии.
	Ask()
	Show(Forge(attacker, genuine, attacker.ns.ServerTime() + 60))
	T.ok(Until(w, function()
		local row = asker.ns.Data.Row(guild)
		return row and row.signed == genuine
	end), "спросивший получил настоящий отчёт от помощника")

	-- Согильдиец выбирает свой лимит подделками, потом повторяет настоящий пакет: у спросившего
	-- повтор упирается в лимит, и помощник не считает его показанным. Сначала у спросившего истекает
	-- отметка повтора от первого ответа: без неё он примет тот же пакет снова.
	w:Run(math.max(asker.ns.Census.RefreshWait(), asker.ns.Config.RELAY_DEDUPE) + 1)
	Ask()
	for i = 1, asker.ns.Config.RG_SIDE_PER_MIN do Show(Forge(attacker, genuine, attacker.ns.ServerTime() + 60 + i)) end
	Show(genuine)
	w:Run(5)
	T.eq(asker.ns.Data.Row(guild), nil, "повтор настоящего отчёта спросивший отклонил по лимиту")
	T.ok(Until(w, function()
		local row = asker.ns.Data.Row(guild)
		return row and row.signed == genuine
	end), "помощник всё равно ответил")
	NoErrors(c)
end)

T.test("q1: под номером вышедшей версии помощников нет, отвечает только репортёр", function()
	local w, c = Build(nil, { all = Wow.RELEASED_VERSION })
	local reporter, officer, member = MainRoles(c)
	Mute(reporter)
	for _, id in ipairs({ "B", "V", "G" }) do c[id]:Logout() end
	Settle(w, member)
	T.eq(#officer.ns.Census.Helpers(), 0, "очередь помощников пуста")
	Forget(member)
	member.ns.Census.Refresh()
	w:Run(120)
	T.eq(member.ns.Data.Row("Чиллзон Север"), nil, "без репортёра отчёта нет")
	T.eq(Logged(officer, "ответ на Q1 вместо репортёра"), 0, "офицер вместо репортёра не отвечал")
	NoErrors(c)
end)

T.test("q1: клиент с номером вышедшей версии в очередь помощников не входит", function()
	local w, c = Build(1, { K = Wow.RELEASED_VERSION })
	local reporter, officer, member = MainRoles(c)
	T.ok(officer == c.K, "второй офицер — Карл с номером вышедшей версии")
	Mute(reporter)
	local asker = Key(member, member:Name())
	T.eq(c.K.ns.Census.HelperSlot(asker), nil, "Карл себя помощником не считает")
	T.eq(c.R1.ns.Census.HelperSlot(asker), 1, "первый помощник — рядовой новой версии")
	for _, cl in ipairs({ c.R1, member }) do
		for _, key in ipairs(cl.ns.Census.Helpers()) do
			T.ok(key ~= Key(cl, c.K:Name()), cl:Name() .. ": Карла нет в очереди")
		end
	end
	local north = c.R1.ns.Data.Row("Чиллзон Север")
	Forget(member)
	member.ns.Census.Refresh()
	T.ok(Until(w, function()
		local row = member.ns.Data.Row("Чиллзон Север")
		return row and row.st >= north.st
	end), "рядовая получила перепись от помощника")
	T.ok(Logged(c.R1, "ответ на Q1 вместо репортёра") >= 1, "ответил рядовой новой версии")
	T.eq(Logged(c.K, "ответ на Q1 вместо репортёра"), 0, "Карл не отвечал")
	NoErrors(c)
end)

T.test("q1: клиенты двух версий с помощниками считают очередь одинаково", function()
	local newer = (Wow.HELPER_VERSION:gsub("(%d+)$", function(d) return tostring(tonumber(d) + 1) end))
	local _, c = Build(3, { K = newer, R2 = newer })
	local first = table.concat(c.A.ns.Census.Helpers(), ",")
	T.ok(#c.A.ns.Census.Helpers() >= 4, "в очереди обе версии: " .. first)
	for _, id in ipairs({ "K", "M", "R1", "R2", "R3" }) do
		T.eq(table.concat(c[id].ns.Census.Helpers(), ","), first, id .. ": та же очередь")
	end
	NoErrors(c)
end)

---------------------------------------------------------------------------
-- Смешанная сеть: настоящие Security, Relay и Census версии 0.9 (tests/legacy/0.9).
---------------------------------------------------------------------------
local function LegacyNetwork()
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
	c.m = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, legacy = true })
	-- Офицер обновился, Нина пришла сразу с новой версией.
	local db = c.o.ns.db
	c.o:Logout()
	c.o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, db = db })
	c.n = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон", rank = 3 })
	w:Run(400)
	-- Север выходит: новых отчётов нет, считаются только ответы на Q1.
	c.v:Logout()
	c.b:Logout()
	Settle(w, c.n)
	T.ok(c.k.ns.Census.IsReporter(), "репортёр главной гильдии — глава на 0.9")
	for _, id in ipairs({ "m", "o", "n" }) do
		local row = c[id].ns.Data.Row(c.v.guild)
		T.ok(row and row.signed, id .. ": отчёт Севера известен")
	end
	return w, c
end

local function Legacy(c)
	for _, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
	end
end

T.test("q1: клиент 0.9 спрашивает как раньше, новые не повторяют ответ его репортёра", function()
	local w, c = LegacyNetwork()
	local guild = c.v.guild
	local wire = c.k.ns.Data.Row(guild).signed
	local from = #w.log
	Forget(c.m)
	c.m.ns.Comm.Send("GUILD", "Q1~")
	w:Run(200)
	local row = c.m.ns.Data.Row(guild)
	T.eq(row and row.signed, wire, "старая участница получила отчёт от старого репортёра")
	T.eq(Sends(w, from, wire), 1, "отчёт выложил только репортёр")
	T.eq(Logged(c.m, "отклонён"), 0, "старой участнице нечего отклонять")
	Legacy(c)
end)

T.test("q1: старый репортёр молчит — новые получают отчёт от помощника, 0.9 его отклоняет", function()
	local w, c = LegacyNetwork()
	local guild = c.v.guild
	Mute(c.k)
	Forget(c.m)
	Forget(c.n)
	c.n.ns.Census.Refresh()
	T.ok(Until(w, function()
		local row = c.n.ns.Data.Row(guild)
		return row and row.signed ~= nil
	end), "новая участница получила отчёт от обновлённого офицера")
	T.eq(c.m.ns.Data.Row(guild), nil, "старая участница отчёт не взяла")
	T.ok(Logged(c.m, "RG от " .. c.o:Name() .. " отклонён: он не репортёр гильдии") >= 1, "и записала отказ в журнал")
	Legacy(c)
end)
