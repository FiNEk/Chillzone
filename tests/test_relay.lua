-- Интеграция: три гильдии, реле, перепись, чат — в симуляторе мира.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

-- Доверие по званию (как до TRUST_ANY_MEMBER): только глава, офицеры и «Ветеран».
-- Канал игры для /cz1 в этих сценариях выключен (Config.CHANNEL_CHAT): строки должны доходить
-- через реле, а не по параллельному пути. Вместе их проверяет tests/test_channel.lua.
local RANKS = { TRUST_ANY_MEMBER = false }
local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт, Благословенный клинок Искателя Ветра]|h|r"

local function Build(opts)
	opts = opts or {}
	math.randomseed(opts.seed or tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	w:AddOffline("Чиллзон", "Старый Воин-CAMWOWUS2Realm3PvE", 3, 60, "WARRIOR", 40)
	w:AddOffline("Чиллзон Север", "Тихий Друид-CAMWOWUS2Realm7PvE", 3, 41, "DRUID", 2)
	for i = 1, (opts.officers or 0) do
		w:AddOffline("Орден Чиллзона", ("Офицерскийперсонаж%02d Длиннофамильный-CAMWOWUS2Realm3PvE"):format(i), 1, 60, "PRIEST", i)
	end
	local cfg = { CHANNEL_CHAT = false }
	for k, v in pairs(opts.config or {}) do cfg[k] = v end
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, zone = "Штормград", config = cfg })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, realm = "CAMWOWUS2Realm3PvE", class = "PALADIN", config = cfg })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST", config = cfg })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR", zone = "Тернистая долина", config = cfg })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, realm = "CAMWOWUS2Realm5PvE", class = "DRUID", config = cfg })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER", config = cfg })
	if not opts.run or opts.run > 30 then
		w:Run(30)
		w:Init(c.A, c.V, c.G)
		w:Pair(c.V, c.K)
		w:Pair(c.G, c.K)
	end
	w:Run(opts.run or 400)
	if not opts.run or opts.run > 30 then
		-- Boris is an active sender: first learn discovery hints from the root,
		-- then fetch the other candidates' credentials. Passive readers do neither.
		c.B.ns.Relay.PingAll(); w:Run(45)
		c.B.ns.Relay.PingAll(); w:Run(45)
	end
	return w, c
end

local function Key(c, name) return c.ns.Util.Key(name) end

-- Выход из игры как на сервере: строка ростера остаётся, но уже вне игры.
local function Quit(w, cl)
	cl:Logout()
	w:AddOffline(cl.guild, cl:Name() .. "-" .. cl.realm, cl.rank, cl.level, cl.class, 0)
end

-- Клиент, который в блокировке чата не слышит аддон-сообщений. Сам симулятор доставляет их
-- и в блокировке, а приходят ли они в игре, неизвестно: тесты берут худший случай.
local function Deafen(cl)
	local fire = cl.Fire
	cl.Fire = function(self, event, ...)
		if self.lockdown and (event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_ADDON_LOGGED") then return end
		return fire(self, event, ...)
	end
end

-- Сколько раз cl отказал name в пересылке гильдии (RG).
local function RejectedRG(cl, name)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if tostring(line):find("RG от " .. name .. " отклонён", 1, true) then n = n + 1 end
	end
	return n
end

-- Единственный клиент гильдии с настоящими выборами, но без сети: сертификат считается выданным.
local function LoneMember()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	c.ns.Security.MyCertificate = function() return {} end
	c.ns.Security.Seal = function(raw, done) done(raw); return true end
	c.ns.Relay.Out = function() end
	return w, c
end

-- Настоящие ростер и перепись, но без фоновых таймеров: проверяем точные границы
-- REPORT_EVERY / REPORT_IDLE и не смешиваем отправку отчёта с доставкой по сети.
local function CensusReports(withVeteran)
	local w = Wow.World()
	w:Guild("Чиллзон")
	if withVeteran then
		w:AddOffline("Чиллзон", "Тихий Ветеран-CAMWOWUS2Realm7PvE", 2, 60, "WARRIOR", 3)
	end
	local c = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local reports = {}
	-- Только расписание: считаем репортёра сертифицированным, подпись завершаем синхронно.
	-- Настоящие подписи и выдача сертификатов проверяются в сетевых тестах.
	c.ns.Security.MyCertificate = function() return {} end
	c.ns.Security.Seal = function(raw, done) done(raw); return true end
	c.ns.Relay.Out = function(mode, raw)
		T.eq(mode, "L", "режим переписи")
		reports[#reports + 1] = raw
	end
	local function reportAt(seconds)
		w.now = 1000 + seconds
		c.ns.Roster.Scan()
		local st = c.ns.Roster.report.st
		c.ns.Census.MaybeReport(false)
		T.eq(c.ns.Roster.report.st, st, "сравнение не меняет время исходного ростера")
	end
	return w, c, reports, reportAt
end

T.test("census: оглохший в блокировке не выбирает себя и не шлёт гильдии свой кэш", function()
	local w, c = Build()
	local yana = w:Client({ first = "Яна", surname = "Последняя", guild = "Чиллзон", rank = 3 })
	Deafen(yana)
	w:Run(300)
	local census = yana.ns.Census
	T.ok(yana.ns.Security.MyCertificate(), "сертификат получен")
	T.ok(#yana.ns.Data.Cached() > 0, "в кэше есть чужие отчёты")
	T.no(census.IsReporter(), "пока слышит гильдию, репортёром не выбрана")

	yana.lockdown = true
	w:Run(yana.ns.Config.PEER_WINDOW + 20)
	T.eq(census.Reporter(), yana.ns.myKey, "приветы устарели, и выбрать больше некого")
	T.no(census.IsReporter(), "в блокировке себя не назначает")

	yana.lockdown = false
	w:Run(120)
	T.no(census.IsReporter(), "после блокировки снова слышит офицеров")
	T.eq(RejectedRG(c.M, "Яна Последняя"), 0, "гильдия не получила от неё RG")
	for _, name in ipairs({ "A", "K", "M" }) do
		T.eq(#c[name].ns.db.errors, 0, name .. ": ошибки " .. table.concat(c[name].ns.db.errors, " | "))
	end
end)

T.test("census: после блокировки новый репортёр ждёт LOGIN_QUIET", function()
	local w, c = LoneMember()
	local quiet = c.ns.Config.LOGIN_QUIET
	c.lockdown = true
	w:Run(quiet + 30)
	T.no(c.ns.Census.IsReporter(), "в блокировке себя не назначает")
	c.lockdown = false
	w:Run(quiet - 10)
	T.no(c.ns.Census.IsReporter(), "приветы ещё могли не дойти")
	w:Run(15)
	T.ok(c.ns.Census.IsReporter(), "окно истекло, а других кандидатов нет")
end)

T.test("census: действующий репортёр переживает блокировку без передачи дел", function()
	local w, c = LoneMember()
	w:Run(c.ns.Config.LOGIN_QUIET + 10)
	T.ok(c.ns.Census.IsReporter(), "репортёр до блокировки")
	local changes = 0
	c.ns.On("REPORTER", function() changes = changes + 1 end)
	c.lockdown = true
	w:Run(40)
	T.ok(c.ns.Census.IsReporter(), "в блокировке остаётся репортёром")
	c.lockdown = false
	w:Run(40)
	T.ok(c.ns.Census.IsReporter(), "после блокировки остаётся репортёром")
	T.eq(changes, 0, "ни передачи дел, ни новой регистрации")
	T.no(c.ns.Census.Handing(), "дела никому не передаёт")
end)

for _, withVeteran in ipairs({ false, true }) do
	local hasVeteran = withVeteran
	T.test("census: неизменный отчёт ждёт REPORT_IDLE, связные " .. (hasVeteran and "есть" or "отсутствуют"), function()
		local _, c, reports, reportAt = CensusReports(hasVeteran)
		reportAt(0)
		T.eq(#reports, 1, "первый отчёт отправлен")
		local first = assert(c.ns.Codec.DecodeReport(reports[1]))
		T.eq(first.st, c.ns.ServerTime(), "в отправленном отчёте настоящее время")
		T.eq(#first.veterans, hasVeteran and 1 or 0, "связные сохранены в отчёте")
		reportAt(c.ns.Config.REPORT_EVERY)
		T.eq(#reports, 1, "новое время не считается изменением переписи")
		reportAt(c.ns.Config.REPORT_IDLE - 1)
		T.eq(#reports, 1, "до REPORT_IDLE повторов нет")
		reportAt(c.ns.Config.REPORT_IDLE)
		T.eq(#reports, 2, "по REPORT_IDLE перепись обновляется")
		local refreshed = assert(c.ns.Codec.DecodeReport(reports[2]))
		T.eq(refreshed.st, c.ns.ServerTime(), "повторный отчёт содержит свежее время")
		T.eq(refreshed.st - first.st, c.ns.Config.REPORT_IDLE, "время не обнулено")
	end)
end

T.test("census: изменение состава отправляется по REPORT_EVERY", function()
	local w, c, reports, reportAt = CensusReports(false)
	reportAt(0)
	w:AddOffline("Чиллзон", "Новый Участник-CAMWOWUS2Realm7PvE", 3, 20, "MAGE", 1)
	reportAt(c.ns.Config.REPORT_EVERY - 6)
	T.eq(#reports, 1, "изменение ждёт обычного интервала")
	reportAt(c.ns.Config.REPORT_EVERY)
	T.eq(#reports, 2, "изменённый состав не ждёт REPORT_IDLE")
	T.eq(assert(c.ns.Codec.DecodeReport(reports[2])).total, 2, "новый участник учтён")
end)

T.test("census: изменение списка связных не теряется при сравнении", function()
	local w, c, reports, reportAt = CensusReports(true)
	reportAt(0)
	-- Меняется только имя связного: все числовые поля и распределение званий прежние.
	w.guilds["Чиллзон"].members[1].full = "Другой Ветеран-CAMWOWUS2Realm7PvE"
	reportAt(c.ns.Config.REPORT_EVERY)
	T.eq(#reports, 2, "изменённый список учтён до REPORT_IDLE")
	local changed = assert(c.ns.Codec.DecodeReport(reports[2]))
	T.eq(#changed.veterans, 1, "новый связной сохранён")
	T.eq(changed.veterans[1].name, "Другой Ветеран", "имя связного")
end)

T.test("census: отчёт считается отправленным только после подписи", function()
	local w, c, reports, reportAt = CensusReports(false)
	local S = c.ns.Security
	-- Подпись не встала в очередь: отчёта нет, и следующая проверка не ждёт REPORT_EVERY.
	S.Seal = function() return false, "busy" end
	reportAt(0)
	T.eq(#reports, 0, "очередь подписей полна — отчёта нет")
	-- Подпись не удалась уже в колбэке.
	S.Seal = function(_, done) done(nil, "failed"); return true end
	reportAt(10)
	T.eq(#reports, 0, "подпись не удалась — отчёта нет")
	-- Подпись идёт долго: вторую не ставим, время отправки — по завершении.
	local calls, pending = 0, nil
	S.Seal = function(raw, done) calls = calls + 1; pending = function() done(raw) end; return true end
	reportAt(20)
	reportAt(30)
	T.eq(calls, 1, "пока идёт подпись, вторая не ставится")
	T.eq(#reports, 0, "до конца подписи отчёт не ушёл")
	w.now = w.now + 5
	pending()
	T.eq(#reports, 1, "подписанный отчёт ушёл")
	reportAt(35 + c.ns.Config.REPORT_EVERY - 6)
	T.eq(#reports, 1, "интервал считается от конца подписи")
	T.eq(calls, 1, "неизменный отчёт не подписывается заново")
	T.eq(#c.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: глобалы не утекают", function()
	local _, c = Build({ run = 5 })
	for name, cl in pairs(c) do
		local leaks = cl:Leaks()
		T.eq(#leaks, 0, name .. ": утечки " .. table.concat(leaks, ", "))
	end
end)

T.test("relay: выборы репортёра одинаковы у всех", function()
	local _, c = Build()
	T.eq(c.B.ns.Census.Reporter(), Key(c.B, "Вера Верная"), "officer has reporter priority")
	T.eq(c.V.ns.Census.Reporter(), Key(c.V, "Вера Верная"), "all peers agree on officer priority")
	T.ok(c.V.ns.Census.IsReporter(), "leader reports while online")
	T.eq(c.M.ns.Census.Reporter(), Key(c.M, "Арагорн Светлый"), "главная")
	T.ok(c.A.ns.Relay.IAmRelay() and c.K.ns.Relay.IAmRelay(), "офицеры главной — реле")
	T.no(c.B.ns.Relay.IAmRelay(), "Борис не реле")
end)

T.test("relay: зонами делятся все, а привет старого клиента без зон уступает выборы", function()
	local w, c = Build()
	-- Арагорн — клиент прежней версии с выключенной настройкой: его привет без зон.
	Wow.ZonesOff(c.A)
	w:Run(200)
	for _, n in ipairs({ "K", "A", "M" }) do
		T.eq(c[n].ns.Census.Reporter(), Key(c[n], "Карл Великий"), n .. ": репортёр главной — Карл, он делится зонами")
	end
	w:Run(200)
	local row = c.G.ns.Data.Row("Чиллзон Север")
	T.ok(row and next(row.r.zones), "зоны Севера видны")
	-- Оба офицера главной — старые клиенты без зон: офицер важнее рядовой, отчёт главной без зон.
	Wow.ZonesOff(c.K)
	w:Run(400)
	for _, n in ipairs({ "K", "A", "M" }) do
		T.eq(c[n].ns.Census.Reporter(), Key(c[n], "Арагорн Светлый"), n .. ": репортёр главной — снова Арагорн")
	end
	local main = c.G.ns.Data.Row("Чиллзон")
	T.ok(c.G.ns.Util.SameName(main.origin, "Арагорн Светлый"), "у Глеба отчёт Арагорна")
	T.eq(next(main.r.zones), nil, "зон главной гильдии от старого клиента нет")
end)

T.test("relay: перепись сходится у всех", function()
	local _, c = Build()
	for name, cl in pairs(c) do
		local mine = cl.ns.MyGuild()
		for _, g in ipairs({ "Чиллзон", "Чиллзон Север", "Орден Чиллзона" }) do
			local row = cl.ns.Data.Row(g)
			T.ok(row and row.r, name .. " знает " .. g)
			T.eq(row.mine == true, g == mine, name .. ": своя гильдия только из ростера, " .. g)
		end
	end
	local row = c.G.ns.Data.Row("Чиллзон")
	T.eq(row.r.leader, "Карл Великий", "глава главной")
	T.eq(row.r.total, 4, "численность главной")
	T.eq(row.r.online, 3, "онлайн главной")
	T.eq(Wow.CertRank(c.B.ns, "Чиллзон", "Арагорн Светлый"), 1, "ранг офицера главной")
	T.eq(Wow.CertRank(c.B.ns, "Орден Чиллзона", "Глеб Гордый-CAMWOWUS2Realm7PvE"), 0, "ранг главы")
end)

T.test("relay: карта учитывает три гильдии в одной зоне у репортёров и читателей", function()
	local _, clients = Build()
	for name, cl in pairs(clients) do
		local key = cl.ns.Zones.KeyForName("Штормград")
		local zone = cl.ns.Data.ZoneCounts()[key]
		T.ok(zone, name .. ": зона есть в сводке карты")
		T.eq(zone.total, 5, name .. ": участники трёх гильдий учтены")
		T.same(zone.guilds, { ["Чиллзон"] = 3, ["Чиллзон Север"] = 1, ["Орден Чиллзона"] = 1 },
			name .. ": третья гильдия не исчезает из сводки")
	end
end)

T.test("relay: реле выучено из ответа доверенного реле", function()
	local _, c = Build({ config = RANKS })
	local learned = c.B.ns.store.relays[Key(c.B, "Карл Великий")]
	T.ok(learned, "Карл выучен")
	T.eq(c.B.ns.Relay.TrustOf("Карл Великий"), "officer", "signed officer credential")
	T.eq(c.B.ns.Relay.TrustOf("Мира Тихая"), nil, "не офицер — не реле")
end)

T.test("relay: без проверки звания любой участник — репортёр, реле и пересылает RG", function()
	local w, c = Build()
	T.ok(c.M.ns.Relay.IAmRelay(), "«Рядовой» главной — реле")
	T.eq(c.A.ns.Relay.TrustOf("Мира Тихая"), "member", "согильдийцы — по ростеру")
	T.eq(c.B.ns.Relay.TrustOf("Мира Тихая"), "member", "member credential verified independently of gossip")
	-- Рядовой Аким по имени раньше Бориса: пока в игре Вера, репортёр она, после её ухода — Аким.
	local Ak = w:Client({ first = "Аким", surname = "Альфа", guild = "Чиллзон Север", rank = 3 })
	w:Run(200)
	T.eq(Ak.ns.Census.Reporter(), Key(Ak, "Вера Верная"), "name order does not preempt an officer")
	c.V:Logout()
	w:Run(220)
	for _, cl in ipairs({ c.B, Ak }) do
		T.eq(cl.ns.Census.Reporter(), Key(cl, "Аким Альфа"), cl:Name() .. ": репортёр — Аким")
	end
	T.ok(Ak.ns.Census.IsReporter(), "Аким репортёр")
	T.eq(Ak.ns.Roster.TrustOf("Аким Альфа"), "member", "роль — участник")
	-- Строка Глеба доходит до Севера через Акима (RM от реле, затем RG гильдии).
	c.G:Slash("/cz1", "привет Северу через рядового")
	w:Run(30)
	for _, cl in ipairs({ c.B, Ak }) do T.eq(cl:Saw("привет Северу через рядового"), 1, cl:Name() .. " видит") end
	T.ok(Ak.ns.Relay.stats.delivered > 0, "certified ordinary reporter delivered real signed messages")
	Ak:Slash("/chillzone", "status")
	T.ok(Ak:Saw("может быть любой участник") >= 1, "status объясняет режим")
end)

T.test("relay: строка чата доходит один раз до всех (GUILD + реле), ссылка цела", function()
	local w, c = Build()
	local text = "всем привет " .. LINK
	c.B:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	for _, e in ipairs(w.log) do T.no(e.dist == "CHANNEL", "в канал ничего не уходит") end
	for name, cl in pairs(c) do T.eq(next(cl.joined), nil, name .. ": ни в каком канале") end
end)

T.test("relay: реле пишет само — без шёпота RL", function()
	local w, c = Build()
	w:Run(c.A.ns.Config.RELAY_SETTLE) -- сразу после входа реле шлёт своё и через других
	local text = "слово реле"
	local before = #w.log
	c.A:Slash("/cz1", text)
	w:Run(30)
	for i = before + 1, #w.log do
		local e = w.log[i]
		T.no(e.from == "Арагорн Светлый" and e.dist == "WHISPER" and e.msg:find("^RL~"), "реле не шепчет RL себе")
	end
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит") end
end)

T.test("relay: вопрос сразу после ответа не делает живое реле офлайн", function()
	local w, c = Build()
	local B = c.B
	local e = B.ns.Relay.Known()[Key(B, c.A:Name())]
	T.ok(e, "Борис знает реле")
	w:Run(10)
	e.asked, e.down = nil, nil
	B.ns.Relay.PingAll()
	T.ok(e.asked, "вопрос задан")
	for _ = 1, 100 do
		w:Run(0.1)
		if not e.asked then break end
	end
	T.no(e.asked, "реле ответило")
	B.ns.Relay.PingAll()
	w:Run(B.ns.Config.RELAY_TIMEOUT + 2)
	T.no(e.down, "реле живо, хотя второй вопрос пришёлся на его паузу")
	B.ns.Relay.PingAll()
	T.ok(e.asked, "после паузы реле снова спрашивают")
end)

T.test("relay: задержка своей очереди не делает живое реле офлайн", function()
	local w, c = Build()
	local B = c.B.ns
	local e = B.Relay.Known()[Key(c.B, c.A:Name())]
	w:Run(10)
	e.asked, e.down, e.verified = nil, nil, w.now - 10
	local send = B.Comm.SendNow
	B.Comm.SendNow = function() return false, 11 end
	B.Relay.PingAll()
	w:Run(B.Config.RELAY_TIMEOUT + 5)
	T.no(e.down, "запрос ещё в очереди, реле не виновато")
	B.Comm.SendNow = send
	w:Run(25)
	T.no(e.down, "после отправки реле ответило")
	T.ok(e.verified and w.now - e.verified < 30, "связь подтверждена")
	T.eq(#c.B.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: своя блокировка после запроса не делает живое реле офлайн", function()
	local w, c = Build()
	local B = c.B.ns
	local e = B.Relay.Known()[Key(c.B, c.A:Name())]
	w:Run(10)
	e.asked, e.down, e.verified = nil, nil, w.now - 10
	Deafen(c.B)
	local send = B.Comm.SendNow
	local blocked = false
	B.Comm.SendNow = function(dist, msg, target, ...)
		local ok, why = send(dist, msg, target, ...)
		if ok and dist == "WHISPER" and target == c.A:Name() and msg:sub(1, 3) == "RP~" then
			c.B.lockdown, blocked = true, true
		end
		return ok, why
	end
	B.Relay.PingAll()
	w:Run(B.Config.RELAY_TIMEOUT + 10)
	T.ok(blocked, "запрос ушёл до начала блокировки")
	T.no(e.down, "ответ не слышен из-за своей блокировки")
	B.Comm.SendNow = send
	c.B.lockdown = false
	B.Relay.PingAll()
	w:Run(25)
	T.no(e.down, "после блокировки реле доступно")
	T.ok(e.verified and w.now - e.verified < 30, "ответ снова получен")
	T.eq(#c.B.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: отказ очереди не запускает ожидание ответа", function()
	local w, c = Build()
	local B = c.B.ns
	local e = B.Relay.Known()[Key(c.B, c.A:Name())]
	w:Run(10)
	e.asked, e.down, e.verified = nil, nil, w.now - 10
	local send = B.Comm.Send
	B.Comm.Send = function() return false end
	B.Relay.PingAll()
	T.no(e.asked, "неотправленный запрос не ждёт ответа")
	B.Comm.Send = send
end)

T.test("relay: отправленный запрос без ответа по-прежнему исключает реле", function()
	local w, c = Build()
	local B = c.B.ns
	local e = B.Relay.Known()[Key(c.B, c.A:Name())]
	w:Run(10)
	e.asked, e.down, e.verified = nil, nil, w.now - 10
	c.A.ns.Comm.On("RP", function() end)
	B.Relay.PingAll()
	w:Run(B.Config.RELAY_TIMEOUT + 15)
	T.ok(e.down and e.down > w.now, "молчащее реле исключено после отправки")
end)

T.test("relay: повторный опрос не возвращает заведомо недоступное реле в тройку", function()
	local _, c = Build()
	local B = c.B.ns
	local e = B.Relay.Known()[Key(c.B, c.A:Name())]
	B.Comm.SendNow("WHISPER", "ZZ~test", c.A:Name())
	c.B:Fire("CHAT_MSG_SYSTEM", c.B.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(c.A:Name()))
	T.ok(e.down, "транспорт подтвердил недоступность")
	c.B:Slash("/chillzone", "relay ping")
	T.ok(e.down, "отказ транспорта сохраняет исключение из тройки")
	T.no(e.asked, "ответа на заведомо неотправленный запрос не ждём")
end)

T.test("relay: потерянный ответ не останавливает обмен на десять минут", function()
	local w, c = Build()
	local V = c.V.ns
	local e = V.Relay.Known()[Key(c.V, c.A:Name())]
	w:Run(10)
	e.asked, e.down, e.verified = nil, nil, w.now - 10
	local fire, blocked = c.A.Fire, true
	c.A.Fire = function(self, event, prefix, msg, dist, sender, ...)
		if blocked and event == "CHAT_MSG_ADDON" and dist == "WHISPER"
			and msg:sub(1, 3) == "RR~" and Key(c.V, sender) == V.myKey then return end
		return fire(self, event, prefix, msg, dist, sender, ...)
	end
	V.Relay.Register()
	w:Run(V.Config.RELAY_TIMEOUT + 15)
	T.ok(e.down and e.down > w.now, "на время выбираются другие реле")
	T.ok(e.down - w.now <= 60, "потеря ответа требует короткой повторной проверки")
	blocked = false
	w:Run(90)
	T.no(e.down, "регистрация сама восстановилась")
	local held = c.A.ns.Relay.Reporters()[V.Util.GuildKey(c.V.guild)]
	T.ok(held and w.now - held.t < c.A.ns.Relay.REG_TTL, "аренда снова продлевается")
	for i = 1, 318 do w:AddOnline(c.V.guild, ("Участник%03d Игрок"):format(i), 3) end
	V.Roster.Scan()
	V.Census.MaybeReport(true)
	w:Run(25)
	local row = c.M.ns.Data.Row(c.V.guild)
	T.ok(row and c.M.ns.Data.IsFresh(row), "главная гильдия получила свежую перепись")
	T.eq(row.r.online, 320, "передан весь онлайн, включая игроков без аддона")
end)

T.test("relay: регистрация уходит, даже если реле только что подтвердилось", function()
	local w, c = Build()
	local V = c.V
	local gk = V.ns.Util.GuildKey("Чиллзон Север")
	local e = V.ns.Relay.Known()[Key(V, c.A:Name())]
	T.ok(e, "Вера знает реле")
	T.ok(V.ns.Census.IsReporter(), "Вера — репортёр")
	-- Сертификат реле обновляет verified так же, как ответ: продлевать аренду это не мешает.
	local ttl = c.A.ns.Relay.REG_TTL
	for _ = 1, ttl * 2 do
		e.verified = w.now
		w:Run(1)
	end
	local held = c.A.ns.Relay.Reporters()[gk]
	T.ok(held and held.key == Key(c.A, V:Name()), "аренда у Веры")
	T.ok(w.now - held.t <= ttl, "аренда продлевается")
	T.no(e.asked, "ответа на паузе реле не ждём")
	T.no(e.down, "живое реле не считается офлайн")
	T.eq(#V.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: зоны отправляются всегда, даже у выключившего их раньше", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local fresh = w:Client({ first = "Новый", surname = "Игрок", guild = "Чиллзон", rank = 1 })
	-- Сохранения прежней версии, где игрок выключил зоны.
	local db = { chars = { [Key(fresh, "Старый Игрок")] = { shareZones = false, zonesDefaulted = true } } }
	local old = w:Client({ first = "Старый", surname = "Игрок", guild = "Чиллзон", rank = 3, db = db })
	w:Run(30)
	w:Init(fresh)
	w:Run(70)
	T.ok(fresh.ns.Census.Peers()[old.ns.myKey].z, "привет выключавшего — с зонами")
	T.ok(old.ns.Census.Peers()[fresh.ns.myKey].z, "привет нового — тоже")
	old:Slash("/chillzone", "zones off")
	T.eq(old:Saw("зоны своей гильдии теперь отправляются всегда"), 1, "команда только объясняет")
	old:Slash("/chillzone", "help")
	T.eq(old:Saw("/chillzone zones"), 0, "в справке её нет")
	w:Run(70)
	T.ok(fresh.ns.Census.Peers()[old.ns.myKey].z, "и ничего не выключает")
end)

T.test("relay: офицер, выключавший зоны в прежней версии, — репортёр, и его отчёт с зонами", function()
	local w, c = Build()
	local guild = c.G.guild
	-- Аким входит с сохранениями прежней версии, где выключил зоны. По имени он раньше Глеба, и
	-- выбрать его должны все, включая его самого.
	local db = { chars = { [Key(c.G, "Аким Альфа")] = { shareZones = false, zonesDefaulted = true } } }
	local Ak = w:Client({ first = "Аким", surname = "Альфа", guild = guild, rank = 1, db = db, config = { CHANNEL_CHAT = false } })
	T.eq(Ak.ns.char.shareZones, false, "сохранённое «выключено» на месте")
	w:Run(300)
	for _, cl in ipairs({ Ak, c.G }) do
		T.eq(cl.ns.Census.Reporter(), Key(cl, "Аким Альфа"), cl:Name() .. ": репортёр Ордена — Аким")
	end
	T.ok(Ak.ns.Census.IsReporter() and not c.G.ns.Census.IsReporter(), "отчитывается Аким, а не Глеб")
	-- Отчёт Акима, принятый другими гильдиями, — с зонами.
	local function Got(cl)
		local row = cl.ns.Data.Row(guild)
		return row and cl.ns.Util.SameName(row.origin, "Аким Альфа") and row or nil
	end
	for _ = 1, 600 do
		if Got(c.V) and Got(c.K) then break end
		w:Run(1)
	end
	for _, cl in ipairs({ c.V, c.K }) do
		local row = Got(cl)
		T.ok(row, cl:Name() .. ": отчёт Ордена от Акима")
		T.ok(row and next(row.r.zones), cl:Name() .. ": с зонами")
	end
	T.eq(#Ak.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: уровни чата — офицеры и главы", function()
	local w, c = Build()
	c.B:Slash("/cz2", "можно мне?")
	T.ok(c.B:Saw("можно писать только") >= 1, "Борису отказано")
	w:Run(5)
	c.V:Slash("/cz2", "офицерам привет")
	w:Run(30)
	for _, n in ipairs({ "A", "K", "G", "V" }) do T.eq(c[n]:Saw("офицерам привет"), 1, n .. " видит офицерский") end
	T.eq(c.M:Saw("офицерам привет"), 0, "рядовой не видит")
	T.eq(c.B:Saw("офицерам привет"), 0, "не офицер не видит")
	c.G:Slash("/cz3", "главам слово")
	w:Run(30)
	for _, n in ipairs({ "A", "K", "V", "G" }) do T.eq(c[n]:Saw("главам слово"), 1, n .. " видит") end
	T.eq(c.B:Saw("главам слово"), 0, "Борис не видит")
end)

T.test("relay: строка не пропадает молча, если подпись не удалась", function()
	local w, c = Build()
	local S = c.B.ns.Security
	local seal = S.Seal
	S.Seal = function() return false, "busy" end
	c.B:Slash("/cz1", "строка без подписи")
	T.eq(c.B:Saw("подписи не успевают"), 1, "очередь полна — причина видна")
	-- Подпись встала в очередь, но не удалась: причина — один раз на строку из нескольких частей.
	S.Seal = function(_, done) w:Schedule(w.now + 1, function() done(nil, "failed") end, c.B); return true end
	c.B:Slash("/cz1", ("длинная строка "):rep(30))
	w:Run(5)
	T.eq(c.B:Saw("подписать её не удалось"), 1, "сбой в колбэке — причина видна один раз")
	S.Seal = function() return false, "nocert" end
	c.B:Slash("/cz1", "строка до сертификата")
	T.eq(c.B:Saw("Ключ ещё не подтверждён"), 1, "нет сертификата — причина видна")
	w:Run(30)
	for name, cl in pairs(c) do
		T.eq(cl:Saw("строка без подписи"), 0, name .. ": неподписанная строка никуда не ушла")
	end
	S.Seal = seal
	c.B:Slash("/cz1", "строка после сбоя")
	w:Run(30)
	T.eq(c.G:Saw("строка после сбоя"), 1, "после сбоя строка уходит сразу, без «слишком часто»")
	T.eq(#c.B.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: уровень канала у отправителя — по сертификату, как у получателей", function()
	local w, c = Build()
	local V = c.V
	local clock = V.ns.ServerTime
	-- Звание в ростере Веры прежнее, а роль в сертификате уже не подтверждена (AUTH_ROLE_TTL).
	local issued = V.ns.Security.MyCertificate().issued
	V.ns.ServerTime = function() return issued + V.ns.Config.AUTH_ROLE_TTL + 1 end
	T.eq(V.ns.Chat.MyLevel(), 3, "по званию Вера — глава")
	T.eq(V.ns.Security.Level(V.ns.Security.MyCertificate()), 1, "по сертификату — нет")
	V:Slash("/cz3", "глава без свежей роли")
	T.ok(V:Saw("сертификат больше не подтверждает") >= 1, "Вера видит причину")
	V.ns.ServerTime = clock
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("глава без свежей роли"), 0, name .. ": строка не ушла") end
	V:Slash("/cz3", "глава со свежей ролью")
	w:Run(30)
	T.eq(c.G:Saw("глава со свежей ролью"), 1, "со свежей ролью строка доходит")
end)

T.test("census: новый репортёр сохраняет прежнего после начала работы, но лишь на время передачи", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local A = w:Client({ first = "Алла", surname = "Альфа", guild = "Чиллзон Север", rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local B = w:Client({ first = "Бетта", surname = "Быстрая", guild = "Чиллзон Север", rank = 1 })
	local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
	local census, C = A.ns.Census, A.ns.Config
	local vera, betta = Key(A, V:Name()), Key(A, B:Name())
	A.ns.store.security.union[A.ns.Util.GuildKey(A.guild)] = { active = true }
	A.ns.Security.MyCertificate = function() return {} end -- проверяем только окно передачи
	A.ns.Roster.Scan()
	census.Peers()[vera] = { t = w.now, name = V:Name() }
	census.Track()
	w.now = C.LOGIN_QUIET - 0.01
	T.ok(census.MayForward(vera), "до начала работы прежний репортёр принимается")
	w.now = C.LOGIN_QUIET + 0.5
	T.ok(census.IsReporter(), "новый репортёр уже работает")
	T.ok(census.MayForward(vera), "прежний ещё может пересылать по живой аренде")
	local deadline = w.now + C.REPORTER_HANDOVER
	census.Peers()[betta] = { t = w.now, name = B:Name() }
	T.eq(census.Reporter(true), betta, "позже появился другой кандидат")
	T.ok(census.MayForward(vera), "запомнен именно прежний репортёр")
	T.no(census.MayForward(betta), "новый кандидат не подменяет прежнего во время передачи")
	T.no(census.MayForward(Key(A, N:Name())), "рядовой не получает права пересылки")
	w.now = deadline
	A.ns.Roster.Scan()
	census.Peers()[vera].t = w.now
	T.ok(census.MayForward(vera), "последняя граница окна включена")
	w.now = deadline + 0.01
	census.Peers()[vera].t = w.now
	T.no(census.MayForward(vera), "новые приветствия не продлевают завершённую передачу")
	A.ns.Fire("GUILD_CHANGED")
	T.no(census.MayForward(vera), "смена гильдии сбрасывает прежнего репортёра")
	T.eq(#A.ns.db.errors, 0, "без ошибок")
end)

T.test("census: новый репортёр узнаёт прежнего после начала работы без продления окна", function()
	local w = Wow.World()
	w:Guild("Чиллзон Север")
	local A = w:Client({ first = "Алла", surname = "Альфа", guild = "Чиллзон Север", rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local census, C = A.ns.Census, A.ns.Config
	local vera = Key(A, V:Name())
	A.ns.store.security.union[A.ns.Util.GuildKey(A.guild)] = { active = true }
	A.ns.Security.MyCertificate = function() return {} end -- проверяем только окно передачи
	A.ns.Roster.Scan()
	w.now = C.LOGIN_QUIET
	census.Track()
	T.no(census.MayForward(vera), "неизвестный аддон ещё не имеет права пересылки")
	w.now = C.LOGIN_QUIET + 5
	census.Peers()[vera] = { t = w.now, name = V:Name() }
	T.ok(census.MayForward(vera), "запоздавшее приветствие прежнего репортёра принято")
	w.now = C.LOGIN_QUIET + C.REPORTER_HANDOVER + 0.01
	A.ns.Roster.Scan()
	census.Peers()[vera].t = w.now
	T.no(census.MayForward(vera), "срок считается от начала работы, а не от запоздавшего приветствия")
	T.eq(#A.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: смена репортёра — чат гильдии не теряется, аренда переходит преемнику", function()
	local w, c = Build()
	local U = c.A.ns.Util
	local gk = U.GuildKey("Чиллзон Север")
	local vera, alla = Key(c.A, "Вера Верная"), Key(c.A, "Алла Альфа")
	local relays = { c.A, c.K, c.M }
	local function Holders()
		local out = {}
		for _, r in ipairs(relays) do
			local held = r.ns.Relay.Reporters()[gk]
			if held and r.ns.Now() - held.t <= 60 then out[held.key] = (out[held.key] or 0) + 1 end
		end
		return out
	end
	T.ok(Holders()[vera], "до смены аренда у Веры")
	-- Входит офицер Севера, которого выборы ставят выше Веры: меньший ключ.
	local Al = w:Client({ first = "Алла", surname = "Альфа", guild = "Чиллзон Север", rank = 1 })
	c.B.ns.Roster.Scan(); c.V.ns.Roster.Scan()
	local lines = {}
	local function Line(i)
		lines[i] = ("смена репортёра %02d"):format(i)
		c.G:Slash("/cz1", lines[i])
	end
	w:Run(15); Line(1)
	w:Run(15); Line(2)
	-- Кандидатом Алла становится, когда получит сертификат и объявит готовность в H1.
	for _ = 1, 30 do
		if c.B.ns.Census.Reporter() == alla then break end
		w:Run(1)
	end
	T.eq(c.B.ns.Census.Reporter(), alla, "гильдия уже выбрала Аллу; членство=" .. tostring(Al.ns.IsMember())
		.. "; сертификат=" .. tostring(Al.ns.Security.MyCertificate() ~= nil) .. "; ошибки=" .. table.concat(Al.ns.db.errors, "; "))
	T.no(Al.ns.Census.IsReporter(), "Алла после входа ещё молчит")
	-- Рядовой Севера пробует перехватить аренду, пока она передаётся: назвать себя
	-- преемником (RU) и зарегистрироваться (RR).
	local cert = c.B.ns.Security.MyCertificate()
	for _, r in ipairs(relays) do
		c.B.ns.Comm.Send("WHISPER", "RU~Чиллзон Север~Борис Быстрый", { target = r:Name(), prio = true })
		c.B.ns.Comm.Send("WHISPER", "RR~Чиллзон Север~" .. cert.fp, { target = r:Name(), prio = true })
	end
	w:Run(5)
	T.ok(Holders()[vera], "аренда всё ещё у Веры")
	T.eq(Holders()[Key(c.A, "Борис Быстрый")], nil, "рядовой аренду не перехватил")
	for i = 3, 10 do w:Run(15); Line(i) end
	w:Run(30)
	T.ok(Al.ns.Census.IsReporter(), "Алла — репортёр")
	local held = Holders()
	T.ok(held[alla], "аренда перешла к Алле")
	T.eq(held[vera], nil, "у Веры аренды больше нет")
	for i, text in ipairs(lines) do
		for _, cl in ipairs({ c.B, c.V, Al }) do T.eq(cl:Saw(text), 1, cl:Name() .. " видит строку " .. i .. " один раз") end
	end
	-- После передачи рядовой тоже не перехватывает аренду Аллы.
	for _, r in ipairs(relays) do
		c.B.ns.Comm.Send("WHISPER", "RU~Чиллзон Север~Борис Быстрый", { target = r:Name(), prio = true })
		c.B.ns.Comm.Send("WHISPER", "RR~Чиллзон Север~" .. cert.fp, { target = r:Name(), prio = true })
	end
	w:Run(5)
	T.ok(Holders()[alla], "аренда у Аллы")
	T.eq(Holders()[Key(c.A, "Борис Быстрый")], nil, "рядовой аренду не перехватил")
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": без ошибок") end
	T.eq(#Al.ns.db.errors, 0, "Алла: без ошибок")
end)

T.test("relay: офицер без сертификата не прерывает доставку чата", function()
	local w, c = Build()
	local guild = "Чиллзон Север"
	local config = c.B.ns.Config
	local boris = Key(c.B, c.B:Name())
	-- Вера — единственный издатель. После её выхода аренду держит сертифицированный ветеран.
	c.V:Logout()
	w:Run(config.PEER_WINDOW + config.LOGIN_QUIET)
	T.ok(c.B.ns.Security.MyCertificate(), "у Бориса есть сертификат")
	T.ok(c.B.ns.Census.IsReporter(), "Борис стал репортёром")
	c.G:Slash("/cz1", "Строка до входа офицера")
	w:Run(30)
	T.eq(c.B:Saw("Строка до входа офицера"), 1)

	local alla = w:Client({ first = "Алла", surname = "Альфа", guild = guild, rank = 1 })
	-- Состав подтвердить некому, а без него Алла не шлёт H1 и флаг n не дойдёт до Бориса.
	alla.ns.store.security.union[alla.ns.Util.GuildKey(guild)] = { active = true }
	w:Run(config.REPORTER_HANDOVER + config.LOGIN_QUIET)
	T.ok(alla.ns.IsMember(), "Алла в составе объединения")
	T.no(alla.ns.Security.MyCertificate(), "издателя нет, Алла ждёт сертификат")
	T.ok(c.B.ns.Census.Peers()[Key(c.B, alla:Name())].unready, "Борис знает, что Алла не готова")
	c.G:Slash("/cz1", "Строка в ожидании сертификата")
	w:Run(30)
	T.eq(c.B:Saw("Строка в ожидании сертификата"), 1, "доставка сохраняется и после окна передачи")
	T.eq(c.B.ns.Census.Reporter(), boris, "Борис сохраняет роль репортёра")
	T.eq(alla.ns.Census.Reporter(), boris, "Алла тоже выбирает Бориса")

	w:Client({ first = c.V.first, surname = c.V.surname, realm = c.V.realm, guild = guild, rank = c.V.rank, db = c.V.ns.db })
	w:Run(config.REPORTER_HANDOVER + config.LOGIN_QUIET + 30)
	T.ok(alla.ns.Security.MyCertificate(), "вернувшийся издатель выдал сертификат")
	T.ok(alla.ns.Census.IsReporter(), "Алла принимает роль репортёра")
	T.eq(c.B.ns.Census.Reporter(), Key(c.B, alla:Name()), "Борис выбирает Аллу после выдачи")
	c.G:Slash("/cz1", "Строка после передачи роли")
	w:Run(30)
	T.eq(c.B:Saw("Строка после передачи роли"), 1)
	T.eq(alla:Saw("Строка после передачи роли"), 1)
end)

T.test("census: ростер снимает с выборов только того, кто молчит с момента чтения", function()
	local w = Wow.World()
	local guild = "Чиллзон Север"
	w:Guild(guild)
	local A = w:Client({ first = "Алла", surname = "Альфа", guild = guild, rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = guild, rank = 1 })
	local census, roster, C = V.ns.Census, V.ns.Roster, V.ns.Config
	local alla, vera = Key(V, A:Name()), V.ns.myKey
	V.ns.Security.MyCertificate = function() return {} end -- проверяем только выбор
	Quit(w, A)
	w.now = 1000
	roster.Scan()
	local heard = w.now + 1
	census.Peers()[alla] = { t = heard, name = A:Name(), z = true }
	w.now = heard + 4
	T.eq(census.Reporter(), alla, "привет новее ростера: тот мог не успеть узнать о входе")
	w.now = heard + C.ROSTER_LAG
	roster.Scan()
	T.eq(census.Reporter(), alla, "привет в пределах отставания ростера")
	w.now = heard + C.ROSTER_LAG + 1
	roster.Scan()
	T.eq(census.Reporter(), vera, "ростер прочитан позже и показывает её вне игры")
	w.now = roster.scannedAt + C.AUTH_ROSTER_TTL + 1
	T.ok(w.now - heard <= C.PEER_WINDOW, "окно приветов ещё не кончилось")
	T.eq(census.Reporter(), alla, "без свежего ростера остаётся только окно приветов")
	T.eq(#V.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: вышедшего репортёра сменяет тот, кого ростер видит в игре, раньше конца окна приветов", function()
	local w, c = Build()
	local guild = "Чиллзон Север"
	local config = c.B.ns.Config
	local Ya = w:Client({ first = "Яна", surname = "Ясная", guild = guild, rank = 3 })
	w:Run(200)
	T.eq(Ya.ns.Census.Reporter(), Key(Ya, "Вера Верная"), "до выхода репортёр — Вера")
	Quit(w, c.V)
	-- Минута до чтения ростера и запас на регистрацию у реле, пока истекает аренда Веры.
	local waited = config.SCAN_EVERY + 45
	T.ok(waited + 20 < config.PEER_WINDOW - 30, "сценарий заканчивается заметно раньше PEER_WINDOW")
	w:Run(waited)
	T.ok(c.B.ns.Census.IsReporter(), "Борис стал репортёром")
	T.eq(Ya.ns.Census.Reporter(), Key(Ya, "Борис Быстрый"), "Яна выбирает Бориса")
	c.G:Slash("/cz1", "строка после выхода репортёра")
	w:Run(20)
	T.eq(c.B:Saw("строка после выхода репортёра"), 1, "репортёр видит строку")
	T.eq(Ya:Saw("строка после выхода репортёра"), 1, "рядовая видит строку через нового репортёра")
	T.eq(#Ya.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: RG от рядового отклоняется — и чат, и отчёт", function()
	local w, c = Build({ config = RANKS })
	local M = c.M -- «Рядовой» главной гильдии
	local Codec = M.ns.Codec
	-- То, что рядовой мог бы отправить одной /run: строку «от главы Севера» и строку
	-- «от Глеба» (уровень всех), обе как будто их переслал репортёр.
	local fake1 = Codec.EncodeRM("RG", "P", "Вера Верная", Codec.EncodeChat("L", "Чиллзон Север", 4242, "DRUID", "поддельный приказ главы"))
	local fake2 = Codec.EncodeRM("RG", "P", "Глеб Гордый", Codec.EncodeChat("A", "Орден Чиллзона", 4243, "HUNTER", "поддельный привет"))
	w:Deliver(M, "GUILD", M.ns.PREFIX, fake1, nil, true)
	w:Deliver(M, "GUILD", M.ns.PREFIX, fake2, nil, true)
	-- И отчёт Севера, где глава — Мира.
	local real = c.K.ns.Data.Row("Чиллзон Север")
	T.ok(real and real.r.leader == "Вера Верная", "настоящий отчёт Севера известен")
	local r = Codec.DecodeReport(real.raw)
	r.leader, r.st = "Мира Тихая", M.ns.ServerTime() + 200
	w:Deliver(M, "GUILD", M.ns.PREFIX, Codec.EncodeRM("RG", "L", "Вера Верная", Codec.EncodeReport(r)), nil, false)
	w:Run(5)
	for _, n in ipairs({ "K", "A" }) do
		T.eq(c[n]:Saw("поддельный приказ главы"), 0, n .. " не видит поддельную строку глав")
		T.eq(c[n]:Saw("поддельный привет"), 0, n .. " не видит поддельную строку всех")
		T.eq(c[n].ns.Data.Row("Чиллзон Север").r.leader, "Вера Верная", n .. ": глава Севера прежний")
		T.ok(c[n].ns.Relay.stats.untrusted >= 3, n .. ": RG посчитаны как недоверенные")
	end
end)

T.test("relay: рядовой не становится репортёром — ни с первым именем, ни с зонами", function()
	local w, c = Build({ config = RANKS })
	local Ak = w:Client({ first = "Аким", surname = "Альфа", guild = "Чиллзон Север", rank = 3, config = RANKS })
	w:Run(200)
	for _, cl in ipairs({ c.B, c.V, Ak }) do
		T.eq(cl.ns.Census.Reporter(), Key(cl, "Вера Верная"), cl:Name() .. ": officer has priority over veteran")
	end
	T.eq(c.B.ns.Roster.TrustOf("Борис Быстрый"), "rank", "Борис — «Ветеран»")
	T.eq(c.B.ns.Roster.TrustOf("Аким Альфа"), nil, "Аким — рядовой")
	-- Ушли Борис и Вера — в Севере некому быть репортёром.
	c.B:Logout()
	c.V:Logout()
	w:Run(200)
	T.eq(Ak.ns.Census.Reporter(), nil, "репортёра нет")
	Ak:Slash("/chillzone", "status")
	T.ok(Ak:Saw("нет главы, офицера или «Ветеран»") >= 1, "status объясняет")
end)

T.test("relay: связной главной гильдии — реле, другие гильдии его узнают", function()
	local w, c = Build({ config = RANKS })
	local Vt = w:Client({ first = "Вадим", surname = "Ветров", guild = "Чиллзон", rank = 2, class = "ROGUE", config = RANKS })
	T.no(c.M.ns.Relay.IAmRelay(), "«Рядовой» главной — нет")
	w:Run(700)
	c.B.ns.Relay.PingAll(); w:Run(30)
	c.B.ns.Relay.PingAll(); w:Run(30)
	T.ok(Vt.ns.Relay.IAmRelay(), "veteran relays after native membership certification")
	local row = c.B.ns.Data.Row("Чиллзон")
	local listed = false
	for _, v in ipairs(row.r.veterans or {}) do if v.name == "Вадим Ветров" then listed = true end end
	T.ok(listed, "связной — в отчёте главной")
	T.eq(c.B.ns.Relay.TrustOf("Вадим Ветров"), "member", "certified veteran is a nonofficer transport")
	T.eq(c.K.ns.Relay.TrustOf("Вадим Ветров"), "member", "certified veteran is not an officer")
	-- Без звания связных в настройках «Ветеран» — обычный участник.
	Vt.ns.Config.RELAY_RANK = ""
	T.no(Vt.ns.Relay.IAmRelay(), "RELAY_RANK пустой — не реле")
end)

T.test("relay: офицер — по игровому флагу звания, а не по номеру ранга", function()
	local w, c = Build()
	-- В главной гильдии звание 1 без офицерских прав, в Севере офицеры — звание 2 («Ветеран»).
	w.guilds["Чиллзон"].officers = { [0] = true }
	w.guilds["Чиллзон Север"].officers = { [0] = true, [2] = true }
	for _, cl in pairs(c) do cl:Fire("GUILD_RANKS_UPDATE") end
	w:Run(400)
	T.eq(c.B.ns.Chat.MyLevel(), 2, "Борис (звание 2 с флагом) — офицер")
	T.eq(c.A.ns.Chat.MyLevel(), 1, "Арагорн (звание 1 без флага) — участник")
	T.ok(c.B.ns.GuildChat.CanOfficer(), "Борису доступен офицерский чат гильдии")
	T.no(c.A.ns.GuildChat.CanOfficer(), "Арагорну — нет")
	-- Борис — репортёр Севера, его сертификат приходит к Глебу вместе с переписью. Без
	-- сертификата перепись сама офицерских прав не даёт.
	c.G.ns.store.security.certs[c.G.ns.Util.GuildKey("Чиллзон Север")][Key(c.G, "Борис Быстрый")] = nil
	T.eq(Wow.CertRank(c.G.ns, "Чиллзон Север", "Борис Быстрый"), nil, "перепись не выдаёт Борису офицерские права")
	T.eq(Wow.CertRank(c.G.ns, "Чиллзон", "Арагорн Светлый"), nil, "Арагорна в офицерах главной нет")
	c.B:Slash("/cz2", "офицер по флагу")
	w:Run(30)
	T.eq(Wow.CertRank(c.G.ns, "Чиллзон Север", "Борис Быстрый"), 2, "Глеб проверил отдельный офицерский сертификат Бориса")
	for _, n in ipairs({ "K", "V", "G" }) do T.eq(c[n]:Saw("офицер по флагу"), 1, n .. " видит") end
	T.eq(c.A:Saw("офицер по флагу"), 0, "Арагорн без флага не видит")
	T.eq(c.M:Saw("офицер по флагу"), 0, "рядовой не видит")
	c.A:Slash("/cz2", "можно мне?")
	T.ok(c.A:Saw("можно писать только") >= 1, "Арагорну отказано")
end)

T.test("relay: без флагов звания офицер — по номеру звания (OFFICER_RANK)", function()
	local w = Wow.World()
	w:Guild("Чиллзон", nil, { [0] = true, [1] = false }) -- по флагу звание 1 — не офицер
	local X = w:Client({ first = "Ксения", surname = "Иксова", guild = "Чиллзон", rank = 2 })
	local R = X.ns.Roster
	X:Fire("GUILD_RANKS_UPDATE")
	T.eq(R.RankFlagOfficer(1), false, "игра сказала флаг")
	T.no(R.IsOfficerRank(1), "флаг игры важнее номера звания")
	local secret = {}
	local answers = {
		{ "пустая таблица", function() return {} end },
		{ "ошибка", function() error("нельзя") end },
		{ "не таблица", function() return nil end },
		{ "нет флага 22", function() return { true, false } end },
		{ "secret-таблица", function() return secret end },
	}
	X.env.issecretvalue = function(v) return v == secret end
	for _, a in ipairs(answers) do
		X.env.C_GuildInfo.GuildControlGetRankFlags = a[2]
		X:Fire("GUILD_RANKS_UPDATE")
		T.eq(R.RankFlagOfficer(1), nil, a[1] .. ": флаг неизвестен")
		T.ok(R.IsOfficerRank(1), a[1] .. ": звание 1 — офицер по OFFICER_RANK")
		T.no(R.IsOfficerRank(2), a[1] .. ": звание 2 — нет")
		T.ok(R.IsOfficerRank(0), a[1] .. ": глава — всегда")
	end
	X.env.C_GuildInfo.GuildControlGetRankFlags = nil
	X:Fire("GUILD_RANKS_UPDATE")
	T.ok(R.IsOfficerRank(1), "нет API: звание 1 — офицер")
	T.no(R.IsOfficerRank(3), "рядовой остаётся рядовым")
	T.ok(R.IsOfficerRank(0), "глава — всегда")
	X.ns.Config.OFFICER_RANK = 0
	X:Fire("GUILD_RANKS_UPDATE")
	T.no(R.IsOfficerRank(1), "OFFICER_RANK = 0: офицер только глава")
	T.eq(#X.ns.db.errors, 0, "без ошибок")
end)

-- Часы клиента cl на время t; все известные ему реле отвечают.
local function AtWindow(cl, t)
	cl.ns.Now = function() return t end
	for _, e in pairs(cl.ns.Relay.Known()) do e.verified, e.asked, e.down = t, nil, nil end
end

T.test("relay: из отвечающих реле первыми выбираются глава и офицеры главной", function()
	local _, c = Build()
	local B, A = c.B, c.A
	local clockB, clockA = B.ns.Now, A.ns.Now
	local base = clockB()
	local known = B.ns.Relay.Known()
	for _, k in ipairs({ "арагорн светлый", "карл великий", "мира тихая" }) do
		T.ok(known[k], "Борис знает реле " .. k)
	end
	local gk = B.ns.Util.GuildKey("Чиллзон Север")
	local picked, plain = {}, {}
	for i = 1, 60 do
		local t = base + i * 600
		AtWindow(B, t)
		picked[B.ns.Relay.Pick().key] = true
		plain[B.ns.Codec.PickRelay(gk, { "арагорн светлый", "карл великий", "мира тихая" }, t, 600)] = true
	end
	T.ok(plain["мира тихая"], "без приоритета Мира иногда была бы выбрана")
	T.no(picked["мира тихая"], "рядовая Мира не выбирается, пока офицеры отвечают")
	T.ok(picked["арагорн светлый"] and picked["карл великий"], "глава и офицер чередуются")
	T.ok(B.ns.Relay.IsMainOfficer("Карл Великий") and not B.ns.Relay.IsMainOfficer("Мира Тихая"), "по отчёту главной")

	-- Глава и офицер не в игре: сообщения идут через участника.
	local t = base + 61 * 600
	AtWindow(B, t)
	known["арагорн светлый"].down = t + 100
	known["карл великий"].down = t + 100
	T.eq(B.ns.Relay.Pick().key, "мира тихая", "офицеры не в игре — Мира")

	-- Руководство главной в отчётах расходится: офицерам из отчёта не верим, приоритета нет.
	B.ns.Data.Row("Чиллзон").conflict = true
	picked = {}
	for i = 62, 121 do
		AtWindow(B, base + i * 600)
		picked[B.ns.Relay.Pick().key] = true
	end
	T.no(picked["мира тихая"], "untrusted census conflicts cannot demote certified officers")
	B.ns.Data.Row("Чиллзон").conflict = nil

	-- В главной гильдии — по своему ростеру: у Арагорна из Карла и Миры всегда Карл.
	T.ok(A.ns.Relay.Known()["мира тихая"], "Арагорн знает Миру")
	picked, plain = {}, {}
	local agk = A.ns.Util.GuildKey("Чиллзон")
	for i = 1, 60 do
		local at = base + i * 600
		AtWindow(A, at)
		picked[A.ns.Relay.Pick().key] = true
		plain[A.ns.Codec.PickRelay(agk, { "карл великий", "мира тихая" }, at, 600)] = true
	end
	T.ok(plain["мира тихая"], "без приоритета Арагорн иногда выбрал бы Миру")
	T.no(picked["мира тихая"], "Арагорн выбирает Карла")
	B.ns.Now, A.ns.Now = clockB, clockA
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": без ошибок") end
end)

T.test("relay: из старых скрытых каналов аддон выходит, их строки спрятаны", function()
	local w = Build()
	local N = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3 })
	N.joined["ChillzoneA"], N.joinedById[7] = 7, "ChillzoneA"
	w:Run(10)
	T.eq(N.joined["ChillzoneA"], nil, "вышла из ChillzoneA")
	local hidden, shown = false, false
	for _, fn in ipairs(N.filters["CHAT_MSG_CHANNEL"] or {}) do
		if fn(nil, "CHAT_MSG_CHANNEL", "M1~A~x", "Кто-то", "", "7. ChillzoneA", "", "", 0, 7, "ChillzoneA") then hidden = true end
		if fn(nil, "CHAT_MSG_CHANNEL", "привет", "Кто-то", "", "2. Торговля", "", "", 0, 2, "Торговля") then shown = true end
	end
	T.ok(hidden, "строка старого канала спрятана")
	T.no(shown, "чужие каналы не трогаем")
	T.eq(#N.ns.db.errors, 0, "без ошибок")
end)

T.test("relay: длинный отчёт (несколько кусков) доходит целым", function()
	local w, c = Build({ officers = 30, run = 500 })
	local chunked = false
	for _, e in ipairs(w.log) do
		if e.from == "Глеб Гордый" and e.msg:find("^C") then chunked = true end
	end
	T.ok(chunked, "отчёт шёл кусками")
	local ref = c.A.ns.Data.Row("Орден Чиллзона")
	T.ok(ref and #ref.r.officers == 30, "30 офицеров у реле")
	for _, n in ipairs({ "K", "M", "B", "V" }) do
		local row = c[n].ns.Data.Row("Орден Чиллзона")
		T.ok(row, n .. " получил")
		local received, expected = c[n].ns.Codec.DecodeReport(row.raw), c[n].ns.Codec.DecodeReport(ref.raw)
		received.st, expected.st = 0, 0
		T.eq(c[n].ns.Codec.EncodeReport(received), c[n].ns.Codec.EncodeReport(expected), n .. ": complete data, excluding snapshot time")
		T.ok(row.signed, n .. ": retains the original signed envelope")
	end
end)

T.test("relay: участник главной вне тройки реле пишет всем через реле", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local c = {}
	-- Четыре офицера главной: тройка реле — Арагорн, Богдан, Виктор. Карл и Мира вне её.
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.O1 = w:Client({ first = "Богдан", surname = "Бравый", guild = "Чиллзон", rank = 1 })
	c.O2 = w:Client({ first = "Виктор", surname = "Верный", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	-- Здесь проверяется доставка вне тройки, а не обнаружение: после знакомства с главой
	-- репортёры получают настоящие сертификаты всех трёх более ранних кандидатов.
	for _, target in ipairs({ c.V, c.G }) do
		for _, source in ipairs({ c.A, c.O1, c.O2 }) do
			c.A.ns.Security.Introduce(target:Name(), source.ns.Security.MyCertificate().raw)
		end
	end
	w:Run(400)
	T.no(c.M.ns.Relay.Serving(), "у Миры репортёры не регистрируются")
	local candidates = {}
	for _, cl in ipairs({ c.V, c.G }) do
		for _, e in ipairs(cl.ns.Relay.Candidates()) do
			candidates[#candidates + 1] = cl:Name() .. ": " .. e.name .. "=" .. tostring(cl.ns.Relay.TrustOf(e.name))
		end
	end
	T.no(c.K.ns.Relay.Serving(), "у Карла тоже: " .. table.concat(candidates, "; "))
	c.M:Slash("/cz1", "рядовая главной пишет всем")
	w:Run(5)
	c.K:Slash("/cz1", "глава вне тройки пишет всем")
	w:Run(30)
	for _, n in ipairs({ "B", "V", "G" }) do
		T.eq(c[n]:Saw("рядовая главной пишет всем"), 1, n .. " видит строку Миры")
		T.eq(c[n]:Saw("глава вне тройки пишет всем"), 1, n .. " видит строку Карла")
	end
	for n, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, n .. ": без ошибок") end
end)

-- Одна главная гильдия с выданными сертификатами и счётчик сборок списка реле у Новичка.
local function PoolWorld()
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.N = w:Client({ first = "Новичок", surname = "Главный", guild = "Чиллзон", rank = 3 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	w:Run(30)
	w:Init(c.A)
	w:Run(60)
	local counter = { n = 0 }
	for _, cl in ipairs({ c.N, c.V }) do
		local certificates = cl.ns.Security.Certificates
		cl.ns.Security.Certificates = function(guild)
			counter.n = counter.n + 1
			return certificates(guild)
		end
	end
	return w, c, counter
end

T.test("relay: список реле не пересобирается каждый кадр и истекает по сроку", function()
	local w, c, counter = PoolWorld()
	local N = c.N.ns
	N.Relay.Invalidate()
	N.Relay.Candidates()
	T.eq(counter.n, 1)
	for _ = 1, 20 do
		w.now = w.now + 0.016
		N.Relay.Candidates()
		N.Relay.Pick()
	end
	T.eq(counter.n, 1, "кадры не пересобирают список")
	w.now = w.now + N.Config.RELAY_POOL_TTL
	N.Relay.Candidates()
	T.eq(counter.n, 2, "по истечении срока список собран заново")
end)

T.test("relay: список реле сбрасывают только события, меняющие доверие", function()
	local _, c, counter = PoolWorld()
	local N, V = c.N.ns, c.V.ns
	local function Rebuilt(ns, fire, ...)
		ns.Relay.Invalidate()
		ns.Relay.Candidates()
		local before = counter.n
		ns.Fire(fire, ...)
		ns.Relay.Candidates()
		return counter.n > before
	end
	T.ok(Rebuilt(N, "AUTH_CHANGED", "Чиллзон"), "сертификат главной гильдии")
	T.no(Rebuilt(N, "AUTH_CHANGED", "Чиллзон Север"), "сертификат другой гильдии")
	T.ok(Rebuilt(N, "AUTH_ROOT", "Чиллзон"), "корень")
	T.ok(Rebuilt(N, "ISSUER_REVOCATION", "KD~", "ключ"), "отзыв допуска")
	T.ok(Rebuilt(N, "ROSTER", N.Roster.report), "свежий ростер главной гильдии")
	T.no(Rebuilt(V, "ROSTER", V.Roster.report), "ростер другой гильдии на доверие не влияет")
end)

T.test("relay: сертификат, принятый после сборки, виден сразу", function()
	local _, c = PoolWorld()
	local N, S = c.N.ns, c.N.ns.Security
	local gk, mira = N.Util.GuildKey("Чиллзон"), N.Util.Key(c.M:Name())
	local certs = N.store.security.certs[gk]
	local raw = certs[mira]
	T.ok(raw, "у Новичка есть сертификат Миры")
	local function Listed()
		for _, e in ipairs(N.Relay.Candidates()) do
			if e.key == mira then return true end
		end
		return false
	end
	T.ok(Listed(), "Мира в списке")
	certs[mira] = nil
	N.Relay.Invalidate()
	T.no(Listed(), "без сертификата Миры нет")
	T.ok(S.CheckCertificate(raw, nil, function() end))
	T.ok(Listed(), "сертификат принят, часы не двигались")
	T.eq(N.Relay.TrustOf(c.M:Name()), "member")
end)

-- Новичок главной гильдии, как в первые минуты после установки: из реле он слышал только
-- рядовую Миру, а корень Арагорна ещё не спрашивал.
local function Newcomer()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.O1 = w:Client({ first = "Богдан", surname = "Бравый", guild = "Чиллзон", rank = 1 })
	c.O2 = w:Client({ first = "Виктор", surname = "Верный", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.N = w:Client({ first = "Новичок", surname = "Главный", guild = "Чиллзон", rank = 3 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	w:Run(30)
	w:Init(c.A, c.V)
	w:Pair(c.V, c.K)
	for _, source in ipairs({ c.A, c.O1, c.O2 }) do
		c.A.ns.Security.Introduce(c.V:Name(), source.ns.Security.MyCertificate().raw)
	end
	w:Run(400)
	local N, U = c.N.ns, c.N.ns.Util
	local mira, root = U.Key(c.M:Name()), U.Key(c.A:Name())
	local certificates = N.Security.Certificates
	N.Security.Certificates = function(guild)
		local out = {}
		for _, cert in ipairs(certificates(guild)) do
			if U.Key(cert.name) == mira then out[#out + 1] = cert end
		end
		return out
	end
	N.Census.Peers = function() return {} end
	N.Relay.Invalidate()
	N.Relay.Candidates()
	local now = N.Now()
	for _, e in pairs(N.Relay.Known()) do e.verified, e.asked, e.down = nil, nil, nil end
	N.Relay.Known()[mira].verified = now
	T.eq(N.Relay.Pick().key, mira, "из подтверждённых у новичка только Мира")
	T.no(c.M.ns.Relay.Serving(), "у Миры нет аренд чужих гильдий")
	return w, c, root
end

T.test("relay: новичок главной спрашивает офицера раньше, чем писать через рядового", function()
	local w, c, root = Newcomer()
	c.N:Slash("/cz1", "первая строка новичка")
	w:Run(30)
	T.eq(c.V:Saw("первая строка новичка"), 1, "строка дошла до другой гильдии")
	T.eq(c.A:Saw("первая строка новичка"), 1, "своя гильдия видит один раз")
	T.ok(c.N.ns.Relay.Known()[root].verified, "офицер подтверждён")
	T.eq(c.N.ns.Relay.HoldSize(), 0, "очередь разобрана")
	for n, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, n .. ": без ошибок") end
end)

T.test("relay: офицер не в игре — очередь новичка не ждёт таймера", function()
	local w, c, root = Newcomer()
	c.A:Logout()
	c.N:Slash("/cz1", "офицера нет в игре")
	w:Run(5)
	T.ok(c.N.ns.Relay.Known()[root].down, "офицер помечен недоступным")
	T.eq(c.N.ns.Relay.HoldSize(), 0, "строка не осталась в очереди")
	for n, cl in pairs(c) do
		if n ~= "A" then T.eq(#cl.ns.db.errors, 0, n .. ": без ошибок") end
	end
end)

-- Главная гильдия и две подключённые: main — участники главной (root — глава, он же корень),
-- Север и Орден знают сертификаты общей тройки реле top. Юг подключается позже и знает только корень.
local function PartialNetwork(main, top)
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	for _, g in ipairs({ "Чиллзон", "Чиллзон Север", "Орден Чиллзона", "Чиллзон Юг" }) do w:Guild(g) end
	local c = {}
	for id, m in pairs(main) do
		c[id] = w:Client({ first = m[1], surname = m[2], guild = "Чиллзон", rank = m[3] })
	end
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2 })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0 })
	w:Run(30)
	w:Init(c.root, c.V, c.G)
	w:Pair(c.V, c.root)
	w:Pair(c.G, c.root)
	for _, target in ipairs({ c.V, c.G }) do
		for _, id in ipairs(top) do
			c.root.ns.Security.Introduce(target:Name(), c[id].ns.Security.MyCertificate().raw)
		end
	end
	w:Run(200)
	return w, c
end

local function ConnectSouth(w, c)
	c.J = w:Client({ first = "Юрий", surname = "Южный", guild = "Чиллзон Юг", rank = 0 })
	w:Run(30)
	w:Init(c.J)
	w:Pair(c.J, c.root)
end

-- Живая аренда гильдии guild у реле cl или nil.
local function Lease(cl, guild)
	local held = cl.ns.Relay.Reporters()[cl.ns.Util.GuildKey(guild)]
	return held and cl.ns.Now() - held.t <= cl.ns.Relay.REG_TTL and held or nil
end

local function NoErrors(c)
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | ")) end
end

-- Рядовые с меньшими ключами идут раньше офицера, пока сертификат офицера неизвестен.
local RANK_AND_FILE = {
	root = { "Карл", "Великий", 0 }, O = { "Олег", "Старший", 1 },
	R1 = { "Вадим", "Рядовой", 3 }, R2 = { "Галина", "Рядовая", 3 },
	R3 = { "Дарья", "Рядовая", 3 }, R4 = { "Евгений", "Рядовой", 3 },
}

T.test("relay: реле вне тройки с арендой одной гильдии пишет всем гильдиям", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	ConnectSouth(w, c)
	for _ = 1, 200 do
		if Lease(c.R2, "Чиллзон Юг") then break end
		w:Run(1)
	end
	T.ok(Lease(c.R2, "Чиллзон Юг"), "Юг зарегистрировался у Галины")
	T.eq(Lease(c.R2, "Чиллзон Север"), nil, "Север у Галины не зарегистрирован")
	T.eq(Lease(c.R2, "Орден Чиллзона"), nil, "Орден у Галины не зарегистрирован")
	T.ok(c.R2.ns.Relay.Serving(), "Галина считает, что обслуживает гильдии")
	local text = "рядовая с арендой одной гильдии"
	c.R2:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: перезашедшее реле из тройки пишет всем, пока аренды неполные", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	-- Перезаход без паузы: репортёры не успевают заметить, что реле выходило.
	local db = c.O.ns.db
	c.O:Logout()
	c.O = w:Client({ first = "Олег", surname = "Старший", guild = "Чиллзон", rank = 1, db = db })
	local back, have, miss = c.O, "Чиллзон Север", "Орден Чиллзона"
	-- Первый RR может прийти до чтения ростера. Даём завершиться его тайм-ауту,
	-- короткой паузе и очередной регистрации (раз в 15 секунд).
	for _ = 1, back.ns.Config.RELAY_TIMEOUT + back.ns.Config.RELAY_RETRY + 30 do
		if Lease(back, have) or Lease(back, miss) then break end
		w:Run(1)
	end
	if not Lease(back, have) then have, miss = miss, have end
	T.ok(Lease(back, have), "одна из гильдий уже зарегистрировалась")
	-- Вторая гильдия ещё не успела: её репортёр сам недавно зашёл.
	back.ns.Relay.Reporters()[back.ns.Util.GuildKey(miss)] = nil
	T.ok(back.ns.Relay.Serving(), "реле обслуживает гильдию")
	T.ok(back.ns.Relay.InTop(), "реле в общей тройке")
	local text = "сразу после перезахода"
	back:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)

	-- Когда все вернулись, лишний путь через тройку закрывается.
	w:Run(back.ns.Config.RELAY_SETTLE)
	T.ok(Lease(back, "Чиллзон Север") and Lease(back, "Орден Чиллзона"), "аренды обеих гильдий")
	local picks, pick = 0, back.ns.Relay.Pick
	back.ns.Relay.Pick = function()
		picks = picks + 1
		return pick()
	end
	text = "реле давно в игре"
	back:Slash("/cz1", text)
	w:Run(30)
	T.eq(picks, 0, "через других реле строка не идёт")
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: вернувшееся реле пишет и тем, кто ещё считает его офлайн", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	local db = c.O.ns.db
	c.O:Logout()
	c.O = w:Client({ first = "Олег", surname = "Старший", guild = "Чиллзон", rank = 1, db = db })
	local back, have, miss = c.O, "Чиллзон Север", "Орден Чиллзона"
	for _ = 1, back.ns.Config.RELAY_TIMEOUT + back.ns.Config.RELAY_RETRY + 30 do
		if Lease(back, have) or Lease(back, miss) then break end
		w:Run(1)
	end
	if not Lease(back, have) then have, miss = miss, have end
	T.ok(Lease(back, have), "одна из гильдий уже зарегистрировалась")
	-- Вторая гильдия заметила выход и до конца RELAY_DOWN у этого реле не регистрируется. Состояние
	-- ставится каждую секунду: ответ на RR, уже идущий к её репортёру, снял бы отметку «офлайн».
	local down, key, gk = back.ns.Config.RELAY_DOWN, back.ns.Util.Key(back:Name()), back.ns.Util.GuildKey(miss)
	local function Away()
		for _, cl in pairs(c) do
			local e = cl.guild == miss and cl.ns.Relay.Known()[key]
			if e then e.down, e.asked, e.verified = w.now + down, nil, nil end
		end
		back.ns.Relay.Reporters()[gk] = nil
	end
	for _ = 1, down / 2 do
		Away()
		w:Run(1)
	end
	Away()
	T.ok(Lease(back, have), "первая гильдия держит аренду")
	T.eq(Lease(back, miss), nil, "вторая гильдия так и не зарегистрировалась")
	T.ok(back.ns.Relay.Serving(), "реле обслуживает гильдию")
	T.ok(back.ns.Relay.InTop(), "реле в общей тройке")
	local text = "реле вернулось несколько минут назад"
	back:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: новая гильдия узнаёт общую тройку от реле вне её", function()
	local w, c = PartialNetwork(RANK_AND_FILE, { "root", "O", "R1" })
	ConnectSouth(w, c)
	w:Run(180)
	T.ok(Lease(c.O, "Чиллзон Юг"), "Юг зарегистрировался у офицера: тройка та же, что у всех")
	T.eq(Lease(c.R2, "Чиллзон Юг"), nil, "у рядовой вне тройки аренда Юга истекла")
	local text = "офицер пишет после подключения Юга"
	c.O:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: автор после долгого молчания пишет через общую тройку", function()
	-- Общая тройка — молчащие офицеры прежней версии, зоны у них выключены. Репортёр главной гильдии — четвёртый
	-- офицер: только его сертификат расходится с отчётами, но аренд других гильдий у него нет.
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
		O4 = { "Дмитрий", "Четвёртый", 1 },
		R1 = { "Адам", "Рядовой", 3 }, R2 = { "Алина", "Рядовая", 3 },
	}, { "O1", "O2", "O3" })
	for _, id in ipairs({ "O1", "O2", "O3" }) do Wow.ZonesOff(c[id]) end
	w:Run(240)
	T.ok(c.O4.ns.Census.IsReporter(), "репортёр главной — четвёртый офицер")
	local author = c.B
	T.no(author.ns.Census.IsReporter(), "Борис не репортёр")
	-- Автор давно в сети: сертификаты главной гильдии у него уже есть.
	for _, id in ipairs({ "root", "O1", "O2", "O3", "O4", "R1", "R2" }) do
		c.root.ns.Security.Introduce(author:Name(), c[id].ns.Security.MyCertificate().raw)
	end
	w:Run(30)
	author:Slash("/cz1", "до молчания")
	w:Run(60)
	T.eq(c.G:Saw("до молчания"), 1, "пока роли свежие, строка доходит")
	w:Run(author.ns.Config.AUTH_ROLE_TTL + 300)
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		T.eq(author.ns.Relay.TrustOf(c[id]:Name()), "officer", id .. ": роль у молчавшего автора свежая")
	end
	local text = "первая строка после молчания"
	author:Slash("/cz1", text)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	NoErrors(c)
end)

T.test("relay: отчёты доходят до гильдии, зарегистрированной только вне общей тройки", function()
	-- Корень — глава с большим ключом, в общую тройку офицеров не входит. Рядовые с малыми ключами
	-- идут у Юга сразу за корнем, поэтому никого из общей тройки Юг сначала не спрашивает.
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
		R1 = { "Адам", "Рядовой", 3 }, R2 = { "Алина", "Рядовая", 3 },
	}, { "O1", "O2", "O3" })
	ConnectSouth(w, c)
	w:Run(180)
	-- Отчёт длинный и идёт кусками в общей очереди: ждём приход, а не фиксированную паузу.
	local function Fresh(reader, reporter, guild)
		w:Run(65)
		reporter.ns.Roster.Scan()
		local st = reporter.ns.Roster.report.st
		reporter.ns.Census.MaybeReport(true)
		local row
		for _ = 1, 120 do
			row = reader.ns.Data.Row(guild)
			if row and row.r and row.r.st >= st then break end
			w:Run(1)
		end
		T.ok(row and row.r, reader:Name() .. " знает " .. guild)
		T.ok(row.r.st >= st, reader:Name() .. " получил свежий отчёт " .. guild .. ": " .. row.r.st .. " против " .. st)
	end
	Fresh(c.J, c.V, "Чиллзон Север")
	Fresh(c.J, c.G, "Орден Чиллзона")
	Fresh(c.V, c.J, "Чиллзон Юг")
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		T.ok(Lease(c[id], "Чиллзон Юг"), id .. ": Юг зарегистрирован у общей тройки")
	end
	NoErrors(c)
end)

T.test("relay: входящий отчёт проходит через реле вне тройки без аренды получателя", function()
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
	}, { "O1", "O2", "O3" })
	ConnectSouth(w, c)
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		c.root.ns.Security.Introduce(c.J:Name(), c[id].ns.Security.MyCertificate().raw, true)
	end
	w:Run(90)
	c.J.ns.Relay.Register(); w:Run(20)
	T.no(c.root.ns.Relay.InTop(), "выбранное автором реле вне общей тройки")
	for _, id in ipairs({ "O1", "O2", "O3" }) do T.ok(Lease(c[id], c.J.guild), "тройка обслуживает получателя") end
	c.root.ns.Relay.Reporters()[c.root.ns.Util.GuildKey(c.J.guild)] = nil
	local rootPeer = { key = c.root.ns.myKey, name = c.root:Name() }
	c.V.ns.Relay.Pick = function() return rootPeer end
	w:Run(65)
	c.V.ns.Roster.Scan()
	local stamp = c.V.ns.Roster.report.st
	c.V.ns.Census.MaybeReport(true); w:Run(90)
	local row = c.J.ns.Data.Row(c.V.guild)
	T.ok(row and row.r.st >= stamp, "отчёт передан тройке и доставлен без аренды у первого реле")
	-- При поиске следующего реле нельзя склеить отчёты разных гильдий в один S1.
	local pick = c.root.ns.Relay.Pick
	c.root.ns.Relay.Pick = function() return nil end
	c.G.ns.Relay.Pick = function() return rootPeer end
	w:Run(65)
	c.V.ns.Roster.Scan(); c.G.ns.Roster.Scan()
	local northStamp, orderStamp = c.V.ns.Roster.report.st, c.G.ns.Roster.report.st
	c.V.ns.Census.MaybeReport(true); c.G.ns.Census.MaybeReport(true); w:Run(10)
	c.root.ns.Relay.Pick = pick
	c.O1.ns.Comm.Send("WHISPER", "RY~", { target = c.root:Name(), prio = true }); w:Run(90)
	T.ok(c.J.ns.Data.Row(c.V.guild).r.st >= northStamp, "очередь сохранила отчёт Севера")
	T.ok(c.J.ns.Data.Row(c.G.guild).r.st >= orderStamp, "очередь сохранила отчёт Ордена")
	local text = "через запасное реле без аренды"
	c.V:Slash("/cz1", text); w:Run(35)
	T.eq(c.J:Saw(text), 1, "строка тоже доходит один раз")
	NoErrors(c)
end)

T.test("relay: старый отчёт от реле не вытесняет новый из очереди гильдии", function()
	local w, c = Build()
	local reporter = c.V.ns.Census.IsReporter() and c.V or c.B
	local member = reporter == c.V and c.B or c.V
	T.ok(reporter.ns.Census.IsReporter(), "у Севера есть репортёр")
	local guild, comm = "Орден Чиллзона", reporter.ns.Comm
	local function Until(check)
		for _ = 1, 30 do
			if check() then return true end
			w:Run(1)
		end
		return check()
	end
	local function HasReport(cl, st)
		return function()
			local row = cl.ns.Data.Row(guild)
			return row and row.r.st >= st
		end
	end
	local old = c.G.ns.Census.lastRaw
	T.ok(old, "у Ордена уже есть отчёт")
	-- Перезашедшее реле отдаёт отчёт позже, чем истекает защита от повторов.
	w:Run(reporter.ns.Config.RELAY_DEDUPE + 30)

	-- Очередь репортёра стоит, как при всплеске трафика: новый отчёт ждёт отправки гильдии.
	local free = comm.InLockdown
	comm.InLockdown = function() return true end
	c.G.ns.Roster.Scan()
	local st = c.G.ns.Roster.report.st
	c.G.ns.Census.MaybeReport(true)
	T.ok(Until(HasReport(reporter, st)), "репортёр получил новый отчёт")

	c.A.ns.Comm.Send("WHISPER", c.A.ns.Codec.EncodeRM("RM", "L", "Глеб Гордый", old), { target = reporter:Name() })
	T.ok(Until(function()
		for _, line in ipairs(reporter.ns.db.log) do
			if line:find("старее", 1, true) then return true end
		end
		return false
	end), "репортёр отклонил старый отчёт")

	comm.InLockdown = free
	T.ok(Until(HasReport(member, st)), "участник получил новый отчёт")
	NoErrors(c)
end)

---------------------------------------------------------------------------
-- Отчёт в обход репортёра: гильдия берёт отчёт новее сохранённого у любого согильдийца, а реле
-- главной гильдии отдаёт чужой отчёт своей гильдии само.
---------------------------------------------------------------------------

-- Отчёт внутри подписанного пакета и всё, что стоит перед ним (отпечаток, время, подпись).
local function SignedReport(cl, wire)
	local head, clear = (wire or ""):match("^(S1~[^~]+~%d+~%d+~[^~]+~)(R1~.+)$")
	return clear and cl.ns.Codec.DecodeReport(clear), head
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

-- Главная гильдия из Build: репортёр, второй офицер и рядовая Мира.
local function MainRoles(c)
	local reporter = c.K.ns.Census.IsReporter() and c.K or c.A
	T.ok(reporter.ns.Census.IsReporter(), "у главной гильдии есть репортёр")
	T.no(c.M.ns.Census.IsReporter(), "рядовая не репортёр")
	return reporter, reporter == c.K and c.A or c.K, c.M
end

-- Сколько раз cl открывал подписанный пакет, начинающийся с head.
local function CountOpens(cl, head)
	local count, open = { n = 0 }, cl.ns.Security.Open
	cl.ns.Security.Open = function(wire, ...)
		if type(wire) == "string" and wire:sub(1, #head) == head then count.n = count.n + 1 end
		return open(wire, ...)
	end
	return count
end

local function Logged(cl, text)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if tostring(line):find(text, 1, true) then n = n + 1 end
	end
	return n
end

-- Клиент в игре, но шёпот аддона до него не доходит; в гильдии он слышит и пишет как обычно.
local function DeafToWhispers(cl)
	local fire = cl.Fire
	cl.Fire = function(self, event, prefix, msg, dist, ...)
		if (event == "CHAT_MSG_ADDON" or event == "CHAT_MSG_ADDON_LOGGED") and dist == "WHISPER" then return end
		return fire(self, event, prefix, msg, dist, ...)
	end
end

T.test("relay: отчёт новее сохранённого гильдия принимает и не от репортёра", function()
	local w, c = Build()
	local guild = c.G.guild
	local reporter, officer, carrier = MainRoles(c)
	local old = c.G.ns.Census.lastRaw
	local wire, st = UnsentReport(w, c.G)
	local readers = { reporter, officer }
	local _, head = SignedReport(c.G, wire)
	local _, oldHead = SignedReport(c.G, old)
	local opens, oldOpens, untrusted = {}, {}, {}
	for i, cl in ipairs(readers) do
		T.ok(cl.ns.Data.Row(guild).st < st, cl:Name() .. ": нового отчёта ещё нет")
		opens[i], oldOpens[i] = CountOpens(cl, head), CountOpens(cl, oldHead)
		untrusted[i] = cl.ns.Relay.stats.untrusted
	end
	local function Share(raw)
		carrier.ns.Comm.Send("GUILD", carrier.ns.Codec.EncodeRM("RG", "L", c.G:Name(), raw))
		w:Run(20)
	end
	Share(wire)
	for i, cl in ipairs(readers) do
		T.eq(cl.ns.Data.Row(guild).st, st, cl:Name() .. ": отчёт принят от рядовой")
		T.eq(opens[i].n, 1, cl:Name() .. ": подпись автора проверена")
		T.eq(Logged(cl, "принят от " .. carrier:Name() .. ": он не репортёр гильдии"), 1, cl:Name() .. ": журнал называет, кто принёс отчёт")
	end
	-- Тот же отчёт ещё раз и прежний отчёт: дальше сравнения времени дело не идёт.
	Share(wire)
	Share(old)
	for i, cl in ipairs(readers) do
		T.eq(opens[i].n, 1, cl:Name() .. ": повтор не доходит до проверки подписи")
		T.eq(oldOpens[i].n, 0, cl:Name() .. ": старый отчёт не доходит до проверки подписи")
		T.eq(cl.ns.Data.Row(guild).st, st, cl:Name() .. ": отчёт остался новым")
		T.eq(cl.ns.Relay.stats.untrusted, untrusted[i], cl:Name() .. ": повторы не считаются недоверенными")
		T.eq(RejectedRG(cl, carrier:Name()), 0, cl:Name() .. ": в журнале нет отказов")
	end
	NoErrors(c)
end)

T.test("relay: подделки под новый отчёт не от репортёра упираются в лимит", function()
	local w, c = Build()
	local guild = c.G.guild
	local _, reader, carrier = MainRoles(c)
	local Codec, limit = reader.ns.Codec, reader.ns.Config.RG_SIDE_PER_MIN
	local r, head = SignedReport(reader, reader.ns.Data.Row(guild).signed)
	T.ok(r and r.leader == c.G:Name(), "настоящий отчёт Ордена известен")
	local opens, untrusted = CountOpens(reader, head), reader.ns.Relay.stats.untrusted
	r.leader = carrier:Name()
	-- Время подделки — чуть впереди часов: плановый отчёт Ордена, пришедший по ходу теста, её не обгонит.
	local function Forge(i)
		r.st = reader.ns.ServerTime() + i
		w:Deliver(carrier, "GUILD", reader.ns.PREFIX, Codec.EncodeRM("RG", "L", c.G:Name(), head .. Codec.EncodeReport(r)), nil, false)
	end
	for i = 1, limit + 5 do Forge(i) end
	w:Run(5)
	T.eq(opens.n, limit, "до проверки подписи дошло не больше лимита")
	T.eq(reader.ns.Relay.stats.untrusted - untrusted, 5, "остальные отклонены без проверки")
	T.eq(Logged(reader, "RG от " .. carrier:Name() .. " отклонён: слишком много отчётов не от репортёра"), 1, "в журнале один отказ на окно")
	T.eq(reader.ns.Data.Row(guild).r.leader, c.G:Name(), "подделки не приняты")
	w:Run(61)
	Forge(limit + 6)
	w:Run(5)
	T.eq(opens.n, limit + 1, "через минуту лимит восстановлен")
	T.eq(reader.ns.Data.Row(guild).r.leader, c.G:Name(), "подделка снова не принята")

	-- Выдуманный отпечаток сертификата: такой пакет ждёт сертификат молча. Запрос KQ по GUILD
	-- отправил бы каждый клиент гильдии на каждую подделку.
	local asked, send = 0, reader.ns.Comm.Send
	reader.ns.Comm.Send = function(dist, payload, ...)
		if type(payload) == "string" and payload:sub(1, 3) == "KQ~" then asked = asked + 1 end
		return send(dist, payload, ...)
	end
	local fp = head:match("^S1~([^~]+)~")
	local unknown = "S1~" .. ("x"):rep(#fp) .. head:sub(#fp + 4)
	local reached = CountOpens(reader, unknown)
	w:Run(61)
	r.st = reader.ns.ServerTime() + limit + 7
	w:Deliver(carrier, "GUILD", reader.ns.PREFIX, Codec.EncodeRM("RG", "L", c.G:Name(), unknown .. Codec.EncodeReport(r)), nil, false)
	w:Run(5)
	T.eq(reached.n, 1, "пакет дошёл до ожидания сертификата")
	T.eq(asked, 0, "сертификат автора у гильдии не запрашивается")
	NoErrors(c)
end)

T.test("relay: отчёт, принятый от согильдийца, реле всё равно рассылает по арендам", function()
	local w, c = Build()
	local guild = c.G.guild
	local _, relay, carrier = MainRoles(c)
	local wire, st = UnsentReport(w, c.G)
	T.ok(Lease(relay, "Чиллзон Север"), "Север зарегистрирован у реле")
	carrier.ns.Comm.Send("GUILD", carrier.ns.Codec.EncodeRM("RG", "L", c.G:Name(), wire))
	w:Run(20)
	T.eq(relay.ns.Data.Row(guild).st, st, "реле приняло отчёт от рядовой")
	T.ok(c.V.ns.Data.Row(guild).st < st, "Север отчёта ещё не видел")
	c.G.ns.Comm.Send("WHISPER", c.G.ns.Codec.EncodeRL("L", wire), { target = relay:Name() })
	-- Отчёт идёт кусками через три очереди: реле, репортёр Севера, его гильдия.
	for _ = 1, 120 do
		if c.V.ns.Data.Row(guild).st == st and c.B.ns.Data.Row(guild).st == st then break end
		w:Run(1)
	end
	for _, cl in ipairs({ c.V, c.B }) do
		T.eq(cl.ns.Data.Row(guild).st, st, cl:Name() .. ": отчёт дошёл по аренде")
	end
	NoErrors(c)
end)

T.test("relay: репортёр пересылает гильдии отчёт по аренде, даже если уже принял его от согильдийца", function()
	local w, c = Build()
	local guild = c.G.guild
	local reporter, relay, carrier = MainRoles(c)
	local wire, st = UnsentReport(w, c.G)
	carrier.ns.Comm.Send("GUILD", carrier.ns.Codec.EncodeRM("RG", "L", c.G:Name(), wire))
	w:Run(20)
	T.eq(reporter.ns.Data.Row(guild).st, st, "репортёр принял отчёт от рядовой")
	local sent, send = 0, reporter.ns.Comm.Send
	reporter.ns.Comm.Send = function(dist, payload, ...)
		if dist == "GUILD" and payload:sub(1, 5) == "RG~L~" and payload:find(wire, 1, true) then sent = sent + 1 end
		return send(dist, payload, ...)
	end
	relay.ns.Comm.Send("WHISPER", relay.ns.Codec.EncodeRM("RM", "L", c.G:Name(), wire), { target = reporter:Name() })
	w:Run(20)
	T.eq(sent, 1, "клиенты до этой правки берут RG только от репортёра")
	NoErrors(c)
end)

T.test("relay: репортёр не отдаёт гильдии второй раз отчёт, который она слышала от репортёра", function()
	local w, c = Build()
	local guild = c.G.guild
	local reporter, relay, carrier = MainRoles(c)
	-- carrier будто прежний репортёр, который ещё передаёт дела: его RG гильдия принимает, а реле
	-- шлют пакет по аренде уже новому.
	local mayForward, carrierKey = reporter.ns.Census.MayForward, Key(reporter, carrier:Name())
	reporter.ns.Census.MayForward = function(key) return key == carrierKey or mayForward(key) end
	local wire, st = UnsentReport(w, c.G)
	carrier.ns.Comm.Send("GUILD", carrier.ns.Codec.EncodeRM("RG", "L", c.G:Name(), wire))
	w:Run(20)
	T.eq(reporter.ns.Data.Row(guild).st, st, "репортёр принял отчёт от прежнего репортёра")
	T.eq(Logged(reporter, "принят от " .. carrier:Name()), 0, "отчёт принят как от репортёра")
	local sent, send = 0, reporter.ns.Comm.Send
	reporter.ns.Comm.Send = function(dist, payload, ...)
		if dist == "GUILD" and payload:sub(1, 3) == "RG~" and payload:find(wire, 1, true) then sent = sent + 1 end
		return send(dist, payload, ...)
	end
	relay.ns.Comm.Send("WHISPER", relay.ns.Codec.EncodeRM("RM", "L", c.G:Name(), wire), { target = reporter:Name() })
	w:Run(20)
	T.eq(sent, 0, "гильдия уже получила отчёт от репортёра")
	NoErrors(c)
end)

T.test("relay: реле отдаёт чужой отчёт своей гильдии само, без аренды её репортёра", function()
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
		R1 = { "Адам", "Рядовой", 3 },
	}, { "O1", "O2", "O3" })
	local relay = c.root
	T.no(relay.ns.Relay.InTop(), "реле автора вне общей тройки")
	T.no(relay.ns.Census.IsReporter(), "реле автора не репортёр своей гильдии")
	T.eq(Lease(relay, "Чиллзон"), nil, "репортёр главной гильдии у него не зарегистрирован")
	-- Автор знает только это реле, а оно не может передать отчёт общей тройке.
	local peer = { key = relay.ns.myKey, name = relay:Name() }
	c.V.ns.Relay.Pick = function() return peer end
	relay.ns.Relay.Pick = function() return nil end
	w:Run(65)
	c.V.ns.Roster.Scan()
	local st = c.V.ns.Roster.report.st
	c.V.ns.Census.MaybeReport(true)
	w:Run(60)
	for _, id in ipairs({ "O1", "O2", "O3", "R1" }) do
		local row = c[id].ns.Data.Row(c.V.guild)
		T.ok(row and row.st >= st, id .. ": отчёт пришёл от реле своей гильдии")
		T.ok(Logged(c[id], "принят от " .. relay:Name() .. ": он не репортёр гильдии") >= 1, id .. ": журнал называет реле")
	end
	NoErrors(c)
end)

T.test("relay: репортёр главной гильдии не слышит шёпот — гильдия получает отчёты от реле", function()
	local w, c = Build()
	local reporter = MainRoles(c)
	-- Читатель вне тройки реле: отчёт до неё доходит только через гильдию.
	local reader = w:Client({ first = "Яна", surname = "Последняя", guild = "Чиллзон", rank = 3 })
	w:Run(300)
	T.ok(reader.ns.Security.MyCertificate(), "читатель получил сертификат")
	T.no(reader.ns.Relay.InTop(), "читатель вне тройки реле")
	DeafToWhispers(reporter)
	w:Run(240)
	T.ok(reporter.ns.Census.IsReporter(), "оглохший остаётся репортёром: в гильдии его слышно")
	T.eq(reader.ns.Census.Reporter(), Key(reader, reporter:Name()), "читатель выбирает его же")
	local author = c.V.ns.Census.IsReporter() and c.V or c.B
	T.ok(author.ns.Census.IsReporter(), "у Севера есть репортёр")
	author.ns.Roster.Scan()
	local st = author.ns.Roster.report.st
	author.ns.Census.MaybeReport(true)
	local row
	for _ = 1, 120 do
		row = reader.ns.Data.Row(author.guild)
		if row and row.st >= st then break end
		w:Run(1)
	end
	T.ok(row and row.st >= st, "читатель получил свежий отчёт Севера мимо оглохшего репортёра")
	NoErrors(c)
	T.eq(#reader.ns.db.errors, 0, "читатель: ошибки " .. table.concat(reader.ns.db.errors, " | "))
end)

---------------------------------------------------------------------------
-- Реле получает пакет и как читатель (RG, RM), и как реле (RL). Первое не должно отменять второе:
-- аренды, которые есть только у этого реле, иначе пакета не получат.
---------------------------------------------------------------------------

-- Запасное реле — глава Ярослав (корень) с большим ключом, вне общей тройки офицеров. Юг
-- зарегистрирован только у тройки. Зонами делится один reporter: остальные — клиенты прежней версии
-- с выключенными зонами (Wow.ZonesOff), и репортёр главной гильдии — он.
local function SpareRelay(reporter)
	local w, c = PartialNetwork({
		root = { "Ярослав", "Старший", 0 }, O1 = { "Богдан", "Бравый", 1 },
		O2 = { "Виктор", "Верный", 1 }, O3 = { "Глафира", "Гордая", 1 },
	}, { "O1", "O2", "O3" })
	for _, id in ipairs({ "root", "O1", "O2", "O3" }) do
		if id ~= reporter then Wow.ZonesOff(c[id]) end
	end
	ConnectSouth(w, c)
	for _, id in ipairs({ "O1", "O2", "O3" }) do
		c.root.ns.Security.Introduce(c.J:Name(), c[id].ns.Security.MyCertificate().raw, true)
	end
	w:Run(90)
	c.J.ns.Relay.Register(); w:Run(20)
	T.ok(c[reporter].ns.Census.IsReporter(), reporter .. ": репортёр главной гильдии")
	local own = Lease(c[reporter], "Чиллзон")
	T.ok(own and own.key == c[reporter].ns.myKey, reporter .. ": аренда своей гильдии у себя")
	T.no(c.root.ns.Relay.InTop(), "запасное реле вне общей тройки")
	for _, id in ipairs({ "O1", "O2", "O3" }) do T.ok(Lease(c[id], c.J.guild), id .. ": Юг зарегистрирован у тройки") end
	c.root.ns.Relay.Reporters()[c.root.ns.Util.GuildKey(c.J.guild)] = nil
	return w, c
end

-- Север знает только запасное реле. Его отчёт и строка должны дойти до Юга и Ордена, которые
-- зарегистрированы только у тройки; строку каждый видит один раз. Строка офицерская (/cz2): она
-- идёт только через реле, а /cz1 дошла бы и по каналу игры. before() — перед каждой отправкой.
local function ThroughSpare(w, c, before)
	local relay = c.root
	-- Сколько раз каждый клиент отдал своей гильдии (RG) пакет, содержащий marker.
	local marker, given = nil, {}
	for id, cl in pairs(c) do
		local send = cl.ns.Comm.Send
		cl.ns.Comm.Send = function(dist, payload, ...)
			if marker and dist == "GUILD" and type(payload) == "string" and payload:sub(1, 3) == "RG~"
				and payload:find(marker, 1, true) then given[id] = (given[id] or 0) + 1 end
			return send(dist, payload, ...)
		end
	end
	local wire, st = UnsentReport(w, c.V)
	before()
	marker = wire
	c.V.ns.Comm.Send("WHISPER", c.V.ns.Codec.EncodeRL("L", wire), { target = relay:Name() })
	local function Has(cl)
		local row = cl.ns.Data.Row(c.V.guild)
		return row and row.st >= st
	end
	for _ = 1, 120 do
		if Has(c.J) and Has(c.G) then break end
		w:Run(1)
	end
	T.ok(Has(c.J), "Юг получил отчёт Севера через запасное реле")
	T.ok(Has(c.G), "Орден получил отчёт Севера через запасное реле")
	for id, n in pairs(given) do T.eq(n, 1, id .. ": отчёт отдан гильдии не больше одного раза") end
	local peer = { key = relay.ns.myKey, name = relay:Name() }
	c.V.ns.Relay.Pick = function() return peer end
	before()
	local text = "через запасное реле"
	marker, given = text, {}
	c.V:Slash("/cz2", text)
	w:Run(35)
	for name, cl in pairs(c) do
		if name == "B" then
			T.eq(cl:Saw(text), 0, "Борис не офицер и офицерскую строку не видит")
		else
			T.eq(cl:Saw(text), 1, name .. " видит строку один раз")
		end
	end
	local byGuild = {}
	for id, n in pairs(given) do byGuild[c[id].guild] = (byGuild[c[id].guild] or 0) + n end
	for _, guild in ipairs({ "Чиллзон", "Орден Чиллзона", "Чиллзон Юг" }) do
		T.eq(byGuild[guild], 1, guild .. ": строка отдана гильдии один раз")
	end
	T.eq(byGuild["Чиллзон Север"], nil, "своя гильдия автора получает строку напрямую")
	NoErrors(c)
end

T.test("relay: реле тройки раздаёт пакет по арендам, хотя уже слышало его от репортёра своей гильдии", function()
	-- Запасное реле само репортёр главной гильдии: отдаёт пакет ей (RG), потом пересылает реле
	-- тройки (RL). Реле тройки слышит RG раньше, чем RL.
	local w, c = SpareRelay("root")
	ThroughSpare(w, c, function() end)
end)

T.test("relay: реле-репортёр раздаёт пакет по арендам, хотя уже получило его по своей аренде", function()
	-- Репортёр главной гильдии — реле тройки Богдан. Он считал Глафиру недоступной и
	-- зарегистрировался у запасного реле, поэтому оно шлёт ему пакет по аренде (RM), а затем
	-- пересылает ему же (RL).
	local w, c = SpareRelay("O1")
	local x, relay = c.O1, c.root
	local fp = x.ns.Security.MyCertificate().fp
	local peer = { key = x.ns.myKey, name = x:Name() }
	relay.ns.Relay.Pick = function() return peer end
	ThroughSpare(w, c, function()
		x.ns.Comm.Send("WHISPER", "RR~" .. x.ns.Codec.Clean(x.guild) .. "~" .. fp, { target = relay:Name(), prio = true })
		w:Run(2)
		local held = Lease(relay, "Чиллзон")
		T.ok(held and held.key == x.ns.myKey, "у запасного реле аренда главной гильдии — Богдан")
	end)
end)

-- Репортёр главной гильдии (реле с арендой своей гильдии) уже знает новый отчёт Ордена, а ему снова
-- приходит прежний: по аренде от другого реле (ByLease) или на рассылку от автора (ToRelay).
-- Счётчики: rg — сколько раз прежний отчёт ушёл гильдии, opened — сколько раз репортёр обработал
-- его у себя.
local function StaleReport()
	local w, c = Build()
	local reporter, relay = MainRoles(c)
	local own = Lease(reporter, "Чиллзон")
	T.ok(own and own.key == reporter.ns.myKey, "репортёр главной гильдии — реле с арендой своей гильдии")
	local guild, dedupe = c.G.guild, reporter.ns.Config.RELAY_DEDUPE
	local old = c.G.ns.Census.lastRaw
	T.ok(old, "у Ордена уже есть отчёт")
	-- Перезашедшее реле отдаёт отчёт позже, чем истекает защита от повторов.
	w:Run(dedupe + 30)
	local wire, st = UnsentReport(w, c.G)
	c.G.ns.Comm.Send("WHISPER", c.G.ns.Codec.EncodeRL("L", wire), { target = reporter:Name() })
	for _ = 1, 60 do
		if reporter.ns.Data.Row(guild).st == st then break end
		w:Run(1)
	end
	T.eq(reporter.ns.Data.Row(guild).st, st, "репортёр получил новый отчёт")
	local s = { w = w, c = c, reporter = reporter, guild = guild, st = st, dedupe = dedupe, rg = 0, opened = 0 }
	local send, inject = reporter.ns.Comm.Send, reporter.ns.Comm.Inject
	reporter.ns.Comm.Send = function(dist, payload, ...)
		if dist == "GUILD" and payload:sub(1, 3) == "RG~" and payload:find(old, 1, true) then s.rg = s.rg + 1 end
		return send(dist, payload, ...)
	end
	reporter.ns.Comm.Inject = function(inner, origin, ctx)
		if ctx and ctx.wire == old then s.opened = s.opened + 1 end
		return inject(inner, origin, ctx)
	end
	function s.ByLease()
		relay.ns.Comm.Send("WHISPER", relay.ns.Codec.EncodeRM("RM", "L", c.G:Name(), old), { target = reporter:Name() })
		w:Run(15)
	end
	function s.ToRelay()
		c.G.ns.Comm.Send("WHISPER", c.G.ns.Codec.EncodeRL("L", old), { target = reporter:Name() })
		w:Run(15)
	end
	return s
end

T.test("relay: реле-репортёр не отдаёт гильдии устаревший отчёт ни по аренде, ни из рассылки", function()
	local s = StaleReport()
	s.ByLease(); s.ToRelay()
	T.eq(s.rg, 0, "сначала по аренде: устаревший отчёт гильдии не отдан")
	s.w:Run(s.dedupe + 30)
	s.ToRelay(); s.ByLease()
	T.eq(s.rg, 0, "сначала на рассылку: устаревший отчёт гильдии не отдан")
	T.eq(s.reporter.ns.Data.Row(s.guild).st, s.st, "у репортёра остался новый отчёт")
	NoErrors(s.c)
end)

T.test("relay: повтор устаревшего отчёта отсекается молча", function()
	-- Повторы в жизни шлёт CatchUp: репортёру с новой или истёкшей арендой реле отдаёт все
	-- известные отчёты, а регистрируется он у нескольких реле сразу.
	local s = StaleReport()
	local reporter, text = s.reporter, "не принят: старее"
	local function Phase(name, steps)
		local logged, opened = Logged(reporter, text), s.opened
		for _, step in ipairs(steps) do step() end
		T.eq(Logged(reporter, text) - logged, 1, name .. ": в журнале одна строка")
		T.eq(s.opened - opened, 1, name .. ": отчёт обработан один раз")
		s.w:Run(s.dedupe + 30)
	end
	Phase("четыре раза по аренде", { s.ByLease, s.ByLease, s.ByLease, s.ByLease })
	Phase("по аренде, на рассылку, по аренде", { s.ByLease, s.ToRelay, s.ByLease })
	Phase("на рассылку, по аренде, по аренде", { s.ToRelay, s.ByLease, s.ByLease })
	T.eq(s.rg, 0, "устаревший отчёт гильдии не отдан")
	-- За три окна Орден успевает прислать и плановый отчёт.
	T.ok(reporter.ns.Data.Row(s.guild).st >= s.st, "прежний отчёт не вытеснил новый")
	NoErrors(s.c)
end)

T.test("relay: реле вышло из игры — сообщение уходит через другое", function()
	local w, c = Build()
	local pick = c.B.ns.Relay.Pick()
	T.ok(pick, "у Бориса есть реле")
	local function Client(key)
		for _, cl in pairs(c) do
			if Key(c.B, cl:Name()) == key then return cl end
		end
	end
	local gone = Client(pick.key)
	T.ok(gone, "реле Бориса — один из клиентов")
	gone:Logout()
	local text = "реле ушло, а я пишу"
	c.B:Slash("/cz1", text)
	w:Run(60)
	T.ok(c.B.ns.Relay.Known()[pick.key].down, "ушедшее реле помечено")
	local now = c.B.ns.Relay.Pick()
	T.ok(now and now.key ~= pick.key, "Борис перешёл на другое реле")
	T.eq(c.G:Saw(text), 1, "Глеб видит")
	T.eq(Client(now.key):Saw(text), 1, "второе реле видит")
	local hidden = false
	for _, fn in ipairs(c.B.filters["CHAT_MSG_SYSTEM"] or {}) do
		if fn(nil, "CHAT_MSG_SYSTEM", ("No player named '%s' is currently playing."):format(pick.name)) then hidden = true end
	end
	T.no(hidden, "через 60 с строка уже не скрывается")
end)

T.test("relay: ошибка Forever снимает аренду репортёра и остаётся скрытой", function()
	local _, c = Build()
	local gk = c.A.ns.Util.GuildKey("Чиллзон Север")
	local relay
	for _, cl in pairs(c) do
		local held = cl.ns.Relay.Reporters()[gk]
		if held and held.key == Key(cl, c.V:Name()) then relay = cl; break end
	end
	T.ok(relay, "есть реле с арендой Веры")
	local text = ('Персонаж по имени "%s" в игре не найден.'):format(c.V:Name())
	relay.ns.Comm.SendNow("WHISPER", "ZZ~test", c.V:Name())
	relay:Fire("CHAT_MSG_SYSTEM", text)
	T.eq(relay.ns.Relay.Reporters()[gk], nil, "аренда снята сразу")
	for _ = 1, 2 do
		local hidden = false
		for _, filter in ipairs(relay.filters.CHAT_MSG_SYSTEM or {}) do
			if filter(nil, "CHAT_MSG_SYSTEM", text) then hidden = true end
		end
		T.ok(hidden, "строка скрыта и после снятия аренды, в каждом окне")
	end
end)

T.test("relay: Q1 после /reload восполняет перепись", function()
	local w, c = Build()
	-- Мира перезаходит с пустыми данными.
	c.M:Logout()
	local M2 = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	T.eq(M2.ns.Data.Row("Орден Чиллзона"), nil, "сначала пусто")
	w:Run(40)
	T.ok(M2.ns.Data.Row("Орден Чиллзона"), "Орден пришёл по Q1")
	T.ok(M2.ns.Data.Row("Чиллзон Север"), "Север пришёл по Q1")
end)

T.test("relay: команды выполняются, обычный текст коротких алиасов доходит в общий чат", function()
	local w, c = Build()
	local toggles, toggle = 0, c.B.ns.UI.Toggle
	c.B.ns.UI.Toggle = function() toggles = toggles + 1 end
	c.B:Slash("/chillzone", "")
	for _, cmd in ipairs({ "/chillzone", "/cz", "/чз", "/чиллзон" }) do
		c.B:Slash(cmd, "status")
	end
	c.B.ns.UI.Toggle = toggle
	T.eq(toggles, 1, "без текста — окно")
	T.eq(c.B.ns.Chat.stats.sent, 0, "команды не ушли в чат")
	T.eq(c.B:Saw("перепись: репортёр"), 4, "status выполнен каждым алиасом")
	local lines = {
		{ c.B, "/чз", "Привет кириллицей" },
		{ c.B, "/cz", "привет без номера" },
		{ c.B, "/чиллзон", "ещё одно сообщение" },
		{ c.B, "/cz1", "status" },
		{ c.B, "/чз1", "привет через чз1" },
		{ c.V, "/чз2", "офицерам через чз2" },
		{ c.G, "/чз3", "главам через чз3" },
	}
	for _, l in ipairs(lines) do
		l[1]:Slash(l[2], l[3])
	w:Run(30)
	end
	for name, cl in pairs(c) do
		T.eq(cl:Saw("Привет кириллицей"), 1, name .. ": /чз текст")
		T.eq(cl:Saw("привет без номера"), 1, name .. ": /cz текст")
		T.eq(cl:Saw("ещё одно сообщение"), 1, name .. ": /чиллзон текст")
		T.eq(cl:Saw("status"), 1, name .. ": слово команды — текст через /cz1")
		T.eq(cl:Saw("привет через чз1"), 1, name .. ": /чз1")
	end
	for _, n in ipairs({ "A", "K", "G", "V" }) do T.eq(c[n]:Saw("офицерам через чз2"), 1, n .. ": /чз2") end
	T.eq(c.M:Saw("офицерам через чз2"), 0, "рядовой не видит /чз2")
	for _, n in ipairs({ "A", "K", "V", "G" }) do T.eq(c[n]:Saw("главам через чз3"), 1, n .. ": /чз3") end
	for name, cl in pairs(c) do T.eq(#cl.ns.db.errors, 0, name .. ": без ошибок") end
end)

T.test("relay: команды, окно и вкладки без ошибок", function()
	local w, c = Build()
	for _, cmd in ipairs({ "", "help", "status", "relay", "relay ping", "zones", "chat", "chat off", "chat on", "history 1", "history 3", "map off", "map on", "minimap", "minimap", "census", "ignore", "log 5", "debug", "debug", "нетакой" }) do
		c.B:Slash("/chillzone", cmd)
		c.A:Slash("/chillzone", cmd)
	end
	c.B:Slash("/chillzone", "ignore Глеб Гордый")
	c.G:Slash("/cz1", "меня не видно")
	w:Run(30)
	T.eq(c.B:Saw("меня не видно"), 0, "игнор работает")
	T.eq(c.A:Saw("меня не видно"), 1, "у других видно")
	c.B.ns.Map.RefreshNow()
	local census = c.B.ns.Views.CensusRows()
	local function has(lines, text, field)
		for _, l in ipairs(lines) do
			if (l[field or "text"] or ""):find(text, 1, true) then return true end
		end
		return false
	end
	T.ok(has(census, "Орден Чиллзона") and has(census, "Чиллзон Север"), "перепись")
	T.ok(has(census, "Карл Великий", "sub") and has(census, "Глеб Гордый", "sub") and has(census, "Вера Верная", "sub"), "главы гильдий")
	local king
	c.B.ns.Views.MinimapTip(setmetatable({}, { __index = function(_, k)
		if k == "AddLine" then
			return function(_, text)
				if text:find("Король: ", 1, true) then king = text end
			end
		end
		return function() end
	end }))
	T.ok(king and king:find("Карл Великий", 1, true), "король в подсказке миникарты: " .. tostring(king))
	for _, l in ipairs(census) do
		if l.tip then l.tip(setmetatable({}, { __index = function() return function() end end })) end
	end
	for name, cl in pairs(c) do
		local errors = cl.ns.db.errors
		T.eq(#errors, 0, name .. ": ошибки " .. table.concat(errors, " | "))
	end
end)

---------------------------------------------------------------------------
-- Отчёт — двум реле (Relay.Out).
---------------------------------------------------------------------------

-- Репортёр Севера.
local function NorthReporter(c)
	local rep = c.V.ns.Census.IsReporter() and c.V or c.B
	T.ok(rep.ns.Census.IsReporter(), "у Севера есть репортёр")
	return rep
end

-- Шёпоты RL клиента cl: список { target, mode, inner }.
local function WatchRL(cl)
	local list, send = {}, cl.ns.Comm.Send
	cl.ns.Comm.Send = function(dist, payload, opts)
		if dist == "WHISPER" and type(payload) == "string" and payload:sub(1, 3) == "RL~" then
			local _, mode, _, inner = cl.ns.Codec.DecodeRelay(payload)
			list[#list + 1] = { target = opts and opts.target, mode = mode, inner = inner }
		end
		return send(dist, payload, opts)
	end
	return list
end

local function RLOf(list, inner)
	local out = {}
	for _, m in ipairs(list) do
		if m.inner == inner then out[#out + 1] = m.target end
	end
	return out
end

local function ClientByKey(c, key)
	for _, cl in pairs(c) do
		if cl.ns.myKey == key then return cl end
	end
end

-- Аддон выключен, персонаж в игре: ростер видит его в игре, шёпот принимается молча, без
-- «игрок не найден», в гильдию он ничего не пишет.
local function SilentAddon(w, cl)
	cl:Logout()
	w:AddOnline(cl.guild, cl:Name() .. "-" .. cl.realm, cl.rank, cl.level, cl.class)
	local find, name = w.FindByTell, cl:Name()
	w.FindByTell = function(self, target)
		if target == name then return { faction = cl.faction, online = true, Fire = function() end } end
		return find(self, target)
	end
end

-- Новый отчёт гильдии репортёра cl обычным путём (Census.MaybeReport, затем Relay.Out).
-- before() — прямо перед отправкой. Возвращает пакет и время отчёта.
local function NewReport(w, cl, before)
	local old = cl.ns.Census.lastRaw
	w:Run(65)
	cl.ns.Roster.Scan()
	local st = cl.ns.Roster.report.st
	if before then before() end
	cl.ns.Census.MaybeReport(true)
	for _ = 1, 40 do
		if cl.ns.Census.lastRaw ~= old then break end
		w:Run(0.25)
	end
	local wire = cl.ns.Census.lastRaw
	T.ok(wire ~= old, "новый отчёт подписан")
	return wire, st
end

local function Has(cl, guild, st)
	local row = cl.ns.Data.Row(guild)
	return row ~= nil and row.st ~= nil and row.st >= st
end

local function Until(w, check, limit)
	for _ = 1, limit or 60 do
		if check() then return true end
		w:Run(1)
	end
	return check()
end

-- Сколько раз каждый клиент принял отчёт (Data.Take) и отдал его гильдии (RG). Считается
-- пакет seen.marker.
local function WatchPath(c)
	local seen = { marker = nil, taken = {}, given = {} }
	for id, cl in pairs(c) do
		local take, send = cl.ns.Data.Take, cl.ns.Comm.Send
		cl.ns.Data.Take = function(r, raw, ...)
			local ok, why = take(r, raw, ...)
			if ok and seen.marker and seen.marker:sub(-#raw) == raw then seen.taken[id] = (seen.taken[id] or 0) + 1 end
			return ok, why
		end
		cl.ns.Comm.Send = function(dist, payload, ...)
			if seen.marker and dist == "GUILD" and type(payload) == "string" and payload:sub(1, 3) == "RG~"
				and payload:find(seen.marker, 1, true) then seen.given[id] = (seen.given[id] or 0) + 1 end
			return send(dist, payload, ...)
		end
	end
	return seen
end

T.test("relay: отчёт уходит и второму реле — молчащее первое его не теряет", function()
	local w, c = Build()
	local rep = NorthReporter(c)
	local rl = WatchRL(rep)
	local silent
	local wire, st = NewReport(w, rep, function()
		local pick = rep.ns.Relay.Pick()
		T.ok(pick, "у репортёра Севера есть реле")
		silent = ClientByKey(c, pick.key)
		T.ok(silent, "его реле — клиент главной гильдии")
		SilentAddon(w, silent)
	end)
	T.ok(Until(w, function() return Has(c.G, rep.guild, st) end, 15), "Орден получил отчёт Севера сразу, без тайм-аута")
	for _, cl in pairs(c) do
		if cl ~= silent and cl.guild == "Чиллзон" then T.ok(Has(cl, rep.guild, st), cl:Name() .. ": главная гильдия получила отчёт") end
	end
	local targets = RLOf(rl, wire)
	T.eq(#targets, 2, "отчёт ушёл двум реле")
	T.ok(targets[1] ~= targets[2], "реле разные")
	T.ok(targets[1] == silent:Name() or targets[2] == silent:Name(), "одно из них молчит")
	for id, cl in pairs(c) do
		if cl ~= silent then T.eq(#cl.ns.db.errors, 0, id .. ": ошибки " .. table.concat(cl.ns.db.errors, " | ")) end
	end
end)

T.test("relay: отчёт через два реле — каждый принимает и отдаёт гильдии один раз", function()
	local w, c = Build()
	local rep = NorthReporter(c)
	local rl = WatchRL(rep)
	local seen = WatchPath(c)
	-- Пакет известен только после подписи, а уходит сразу: считаем всё, что содержит отчёт
	-- Севера с новым временем, и сверяем с пакетом потом.
	local relay = rep.ns.Relay
	local out = relay.Out
	relay.Out = function(mode, inner)
		if mode == "L" then seen.marker = inner end
		return out(mode, inner)
	end
	local wire, st = NewReport(w, rep)
	relay.Out = out
	T.eq(seen.marker, wire, "считается новый пакет")
	T.ok(Until(w, function() return Has(c.G, rep.guild, st) and Has(c.M, rep.guild, st) end, 30), "отчёт дошёл")
	w:Run(30)
	local targets = RLOf(rl, wire)
	T.eq(#targets, 2, "отчёт ушёл двум реле")
	T.ok(targets[1] ~= targets[2], "реле разные")
	for id, cl in pairs(c) do
		if cl.guild ~= rep.guild then T.eq(seen.taken[id] or 0, 1, id .. ": отчёт принят один раз") end
		T.ok((seen.given[id] or 0) <= 1, id .. ": отдал гильдии " .. (seen.given[id] or 0) .. " раз")
	end
	T.eq(seen.given.G or 0, 1, "репортёр Ордена отдал отчёт гильдии один раз")
	NoErrors(c)
end)

T.test("relay: строка чата по-прежнему уходит одному реле", function()
	local w, c = Build()
	local rep = NorthReporter(c)
	local rl = WatchRL(rep)
	local text = "строка одному реле"
	rep:Slash("/cz1", text)
	w:Run(20)
	local chat = 0
	for _, m in ipairs(rl) do
		if m.mode == "P" then chat = chat + 1 end
	end
	T.eq(chat, 1, "строка ушла одному реле")
	T.eq(c.G:Saw(text), 1, "Орден видит строку один раз")
	T.eq(c.M:Saw(text), 1, "главная гильдия видит строку один раз")
	NoErrors(c)
end)

T.test("relay: без второго отвечающего реле отчёт уходит одному", function()
	local w, c = Build()
	local rep = NorthReporter(c)
	local rl = WatchRL(rep)
	local wire, st = NewReport(w, rep, function()
		local pick = rep.ns.Relay.Pick()
		for key, e in pairs(rep.ns.Relay.Known()) do
			if key ~= pick.key then e.verified = nil end
		end
	end)
	T.ok(Until(w, function() return Has(c.G, rep.guild, st) end, 15), "Орден получил отчёт")
	T.eq(#RLOf(rl, wire), 1, "отчёт ушёл одному реле")
	NoErrors(c)
end)

T.test("relay: отчёт из очереди ожидания уходит после ответа реле", function()
	local w, c = Build()
	local rep = NorthReporter(c)
	local rl = WatchRL(rep)
	local wire, st = NewReport(w, rep, function()
		for _, e in pairs(rep.ns.Relay.Known()) do e.verified, e.asked, e.probe = nil, nil, nil end
	end)
	-- Реле, ответившее этому репортёру меньше PONG_GAP назад, на новый вопрос молчит, и опрос может
	-- уйти в тайм-аут: тогда отчёт ждёт повторной проверки через RELAY_RETRY.
	local C = rep.ns.Config
	T.ok(Until(w, function() return Has(c.G, rep.guild, st) end, C.RELAY_TIMEOUT + C.RELAY_RETRY + 20), "Орден получил отчёт после ответа реле")
	local n = #RLOf(rl, wire)
	T.ok(n >= 1 and n <= 2, "отчёт ушёл " .. n .. " реле")
	NoErrors(c)
end)

T.test("relay: реле из тройки пишет отчёт само, без шёпота RL", function()
	local w, c = Build()
	local reporter = MainRoles(c)
	w:Run(reporter.ns.Config.RELAY_SETTLE)
	T.ok(reporter.ns.Relay.InTop(), "репортёр главной гильдии — реле из тройки")
	T.ok(reporter.ns.Relay.Serving(), "у него аренды других гильдий")
	local rl = WatchRL(reporter)
	local _, st = NewReport(w, reporter)
	T.ok(Until(w, function() return Has(c.G, reporter.guild, st) and Has(c.B, reporter.guild, st) end, 60), "другие гильдии получили отчёт")
	T.eq(#rl, 0, "шёпота RL нет")
	NoErrors(c)
end)

-- Дефект Ask из прогона 2026-11-10: повтор опроса на 30-й секунде сдвигал e.asked, и таймер
-- ответа не срабатывал никогда. Исправлен в c7993f9 (маркер e.probe); тест его держит.
T.test("relay: молчащее реле репортёр исключает за один тайм-аут опроса", function()
	local w, c = Build()
	local rep = NorthReporter(c)
	local pick = rep.ns.Relay.Pick()
	T.ok(pick, "у репортёра Севера есть реле")
	local e = rep.ns.Relay.Known()[pick.key]
	SilentAddon(w, ClientByKey(c, pick.key))
	local C = rep.ns.Config
	-- Опрос раз в 15 секунд, первый может прийтись на паузу после ответа, затем тайм-аут.
	T.ok(Until(w, function() return e.down ~= nil and e.down > w.now end, C.RELAY_TIMEOUT + 2 * 15 + 5), "молчащее реле исключено")
	local now = rep.ns.Relay.Pick()
	T.ok(now and now.key ~= pick.key, "репортёр перешёл на другое реле")
	w:Run(5 * 60)
	T.ok(e.down ~= nil, "и не вернул молчащее за пять минут")
end)
