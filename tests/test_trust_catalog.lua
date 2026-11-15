-- Каталог доверия по GUILD (TrustCatalog.lua): запись уходит в гильдию один раз на всех офицеров,
-- и каждый вошедший получает весь каталог.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local MAIN, NORTH = "Чиллзон", "Чиллзон Север"
local NAMES = { "Анна", "Борис", "Глеб", "Дина", "Егор", "Жанна", "Зоя", "Игорь", "Кира", "Лев" }
local KINDS = { KT = true, UO = true, KA = true, KD = true, KV = true }

-- Глава и корень главной гильдии k, глава второй гильдии объединения v, рядовой m и officers офицеров.
local function Build(officers, seed)
	math.randomseed(seed or 11)
	local w = Wow.World()
	w:Guild(MAIN)
	w:Guild(NORTH)
	local k = w:Client({ first = "Карл", surname = "Великий", guild = MAIN, rank = 0, class = "PALADIN" })
	local v = w:Client({ first = "Вера", surname = "Верная", guild = NORTH, rank = 0, class = "DRUID" })
	local m = w:Client({ first = "Могаю", surname = "Прохожих", guild = MAIN, rank = 3, class = "WARRIOR" })
	local list = {}
	for i = 1, officers do
		list[i] = w:Client({ first = NAMES[i], surname = "Дозорная", guild = MAIN, rank = 1, class = "PRIEST" })
	end
	w:Run(30)
	w:Init(k, v)
	w:Pair(v, k)
	w:Run(240)
	return w, k, v, m, list
end

-- Вошедший. Остальные клиенты сразу перечитывают ростер: иначе его сообщения по GUILD они
-- отбрасывали бы до своего очередного чтения, а проверяется здесь не ростер.
local function Join(w, surname)
	local g = w:Client({ first = "Гость", surname = surname, guild = MAIN, rank = 3, class = "ROGUE" })
	for _, c in ipairs(w.clients) do
		if c ~= g then c.ns.Roster.Scan() end
	end
	return g
end

local function RunUntil(w, ok, limit)
	local stop = w.now + limit
	while w.now < stop do
		w:Run(1)
		if ok() then return true end
	end
	return ok()
end

-- Весь каталог главы k у вошедшего g: корень своей гильдии, владелец объединения, допуски своей
-- гильдии и все отзывы, действующие решения. Сравнение по байтам сохранённых записей.
local function HasCatalog(k, g)
	local U = k.ns.Util
	local gk = U.GuildKey(k.guild)
	local ks, gs = k.ns.store.security, g.ns.store and g.ns.store.security
	if not gs then return false end
	local root, mine = ks.roots[gk], gs.roots and gs.roots[gk]
	if not root or not mine or mine.public ~= root.public then return false end
	if ks.owner and (not gs.owner or gs.owner.raw ~= ks.owner.raw) then return false end
	for guild, list in pairs(ks.issuers or {}) do
		for key, d in pairs(list) do
			if d.active == false or guild == gk then
				local other = gs.issuers and gs.issuers[guild] and gs.issuers[guild][key]
				if not other or other.raw ~= d.raw then return false end
			end
		end
	end
	for guild, p in pairs(ks.policies or {}) do
		if p.durable then
			local other = gs.policies and gs.policies[guild]
			if not other or other.wire ~= p.wire then return false end
		end
	end
	return true
end

-- Целые записи каталога, которые слышит c по GUILD: { id, kind, from, started, at }.
local function Listen(c)
	local heard = {}
	c.ns.Comm.Watch(function(msg, sender, prefix, started)
		local kind = msg:sub(1, 2)
		if KINDS[kind] and sender then
			heard[#heard + 1] = { id = prefix .. "\n" .. msg, kind = kind, from = c.ns.Util.Key(sender),
				started = started, at = c.world.now }
		end
	end)
	return heard
end

local function Keys(list)
	local out = {}
	for _, c in ipairs(list) do out[c.ns.myKey] = true end
	return out
end

-- Сколько копий каждой записи от senders пришло с since: [id] = n.
local function Copies(heard, since, senders)
	local out = {}
	for _, e in ipairs(heard) do
		if e.started >= since and (not senders or senders[e.from]) then out[e.id] = (out[e.id] or 0) + 1 end
	end
	return out
end

-- Копии от by, начатые, когда та же запись от офицера уже пришла целиком после since меньше окна
-- назад: её гильдия только что слышала. Корень (KT) не в счёт: перед сертификатом его
-- по-прежнему шлёт Security.ShareRoot, без проверки. Времена — у слушателя, задержка доставки
-- у всех одна: копия, собранная в тот же миг, когда пришёл первый кусок другой, ушла с ней
-- в один такт — отправитель второй её ещё не слышал (встречные копии, а не повтор).
local function Repeats(heard, since, officers, window, by)
	local done, out = {}, {}
	by = by or officers
	for _, e in ipairs(heard) do
		if e.started >= since and by[e.from] and e.kind ~= "KT" then
			for _, f in ipairs(heard) do
				if f ~= e and f.id == e.id and f.started >= since and officers[f.from]
					and f.at < e.started and e.started - f.at < window and not done[e] then
					done[e] = true
					out[#out + 1] = ("%s от %s в %.2f после копии в %.2f"):format(e.kind, e.from, e.started, f.at)
				end
			end
		end
	end
	return out
end

local function None(list, what)
	T.eq(#list, 0, what .. ": " .. table.concat(list, "; "))
end

local function Errors(w)
	for _, c in ipairs(w.clients) do T.eq(#c.ns.db.errors, 0, c:Name() .. ": без ошибок") end
end

-- Порядок офицеров и паузы зависят от случайных чисел симулятора, а последовательность
-- math.random у Lua 5.1 и LuaJIT разная: на одном seed удачный порядок скрывал лишнюю копию.
-- Поэтому сценарий проверяется на нескольких seed.
local function EightOfficers(seed)
	local w, k, _, m, officers = Build(8, seed)
	local senders = Keys(officers)
	senders[k.ns.myKey] = true
	local heard = Listen(m)
	local t0 = w.now
	local dropped = k.ns.Comm.stats.dropped + m.ns.Comm.stats.dropped
	local g = Join(w, "Первый")
	w:Run(90)
	T.ok(HasCatalog(k, g), "вошедший получил весь каталог")
	T.ok(g.ns.IsMember(), "и свой сертификат: корень дошёл раньше него")
	local copies = Copies(heard, t0, senders)
	local records, total, n = k.ns.Security.Catalog(), 0, 0
	for _, r in ipairs(records) do
		if r.kind ~= "KT" then
			local got = copies[r.id] or 0
			if r.kind == "UO" and r.base then got = got + (copies[r.base] or 0) end
			n, total = n + 1, total + got
			T.ok(got >= 1, r.slot .. ": разослана")
			T.ok(got <= 2, r.slot .. ": копий " .. got .. ", а не по одной от каждого офицера")
		end
	end
	T.ok(n >= 10, "в каталоге решения, владелец и допуски всех офицеров: " .. n)
	T.ok(total <= n + 2, ("копий %d на %d записей"):format(total, n))
	None(Repeats(heard, t0, senders, k.ns.Config.TRUST_SHARE_WINDOW), "услышанное не повторяется")
	for _, r in ipairs(records) do
		if r.kind == "KT" then T.ok((copies[r.id] or 0) <= 4, r.slot .. ": корней " .. tostring(copies[r.id])) end
	end
	T.eq(k.ns.Comm.stats.dropped + m.ns.Comm.stats.dropped, dropped, "ничего не выброшено")
	Errors(w)
end

for _, seed in ipairs({ 3, 4, 6, 9, 11, 15 }) do
	T.test(("trust-catalog: восемь офицеров и один вошедший — каждая запись примерно один раз, seed %d"):format(seed),
		function() EightOfficers(seed) end)
end

-- UQ и первый K1 одного входа приходят порознь: между ними куски привета вошедшего. Первый K1
-- засчитывался вторым запросом всего каталога, и его запрос сдвигался за уже разосланное:
-- офицеры повторяли каталог после окна, а репортёр на Q1 — сразу. Здесь K1 ждёт, пока гильдия
-- не разошлёт по UQ хотя бы UO главы (с доказательством: копия без него запись главы не покрывает).
T.test("trust-catalog: первый K1 вскоре после UQ того же входа не повторяет разосланное", function()
	local w, k, _, m, officers = Build(3)
	local senders = Keys(officers)
	senders[k.ns.myKey] = true
	local heard = Listen(m)
	local t0 = w.now
	local g = Join(w, "Первый")
	local held, send = nil, g.ns.Comm.Send
	g.ns.Comm.Send = function(dist, msg, opts)
		if dist == "GUILD" and msg:find("^K1~") then
			held = held or { msg = msg, opts = opts }
			return true
		end
		return send(dist, msg, opts)
	end
	-- Окно отсчитывается от входа, а UQ уходит позже: K1 уходит меньше окна после UQ.
	local window, owner = k.ns.Config.TRUST_SHARE_WINDOW, k.ns.UnionAuthority.Record().id
	T.ok(RunUntil(w, function() return Copies(heard, t0, senders)[owner] ~= nil end, window), "владелец разослан по UQ")
	T.ok(held ~= nil and not g.ns.Security.MyCertificate(), "K1 ещё не ушёл")
	g.ns.Comm.Send = send
	local t1 = w.now
	send("GUILD", held.msg, held.opts)
	T.ok(RunUntil(w, function() return g.ns.Security.MyCertificate() ~= nil end, 20), "K1 дошёл: сертификат выдан")
	w:Run(2 * window)
	T.ok(HasCatalog(k, g), "вошедший получил весь каталог")
	-- Разосланное между UQ и K1 после K1 не повторяется. Остальное — ответ на UQ, оно уходит после K1.
	local all, after, checked = Copies(heard, t0, senders), Copies(heard, t1, senders), 0
	for _, r in ipairs(k.ns.Security.Catalog()) do
		if r.kind ~= "KT" and (all[r.id] or 0) > (after[r.id] or 0) then
			checked = checked + 1
			T.eq((after[r.id] or 0) + (r.base and after[r.base] or 0), 0, r.slot .. ": копий после K1")
		end
	end
	T.ok(checked > 0, "до K1 разослан хотя бы владелец")
	Errors(w)
end)

-- UQ не дошёл (например, отказ сервера): первый K1 соседа сам запускает доставку всего
-- каталога. Q1 тоже не уходит: на него каталог шлёт репортёр.
T.test("trust-catalog: без UQ первый K1 вошедшего запускает доставку каталога", function()
	local w, k = Build(3)
	local g = Join(w, "Первый")
	local send = g.ns.Comm.Send
	g.ns.Comm.Send = function(dist, msg, opts)
		if dist == "GUILD" and (msg == "UQ~1" or msg:find("^Q1~")) then return true end
		return send(dist, msg, opts)
	end
	T.ok(RunUntil(w, function() return HasCatalog(k, g) end, 50), "каталог пришёл по K1")
	Errors(w)
end)

T.test("trust-catalog: вошедший сразу после рассылки получает весь каталог в пределах окна", function()
	local w, k, _, m, officers = Build(4)
	local senders = Keys(officers)
	senders[k.ns.myKey] = true
	local heard = Listen(m)
	local g1 = Join(w, "Первый")
	T.ok(RunUntil(w, function() return HasCatalog(k, g1) end, 90), "первый получил каталог")
	-- Второй входит, пока копии для первого ещё свежие: окно их не повторяет до своего конца.
	local t1 = w.now
	local g2 = Join(w, "Второй")
	local window = k.ns.Config.TRUST_SHARE_WINDOW
	T.ok(RunUntil(w, function() return HasCatalog(k, g2) end, window + 30), "второй тоже, в пределах окна")
	local copies = Copies(heard, t1 + 0.1, senders)
	for _, r in ipairs(k.ns.Security.Catalog()) do
		if r.kind ~= "KT" then
			local got = (copies[r.id] or 0) + (r.base and copies[r.base] or 0)
			T.ok(got >= 1, r.slot .. ": разослана после второго запроса")
		end
	end
	None(Repeats(heard, t1 + 0.1, senders, window), "одна копия на запрос")
	Errors(w)
end)

-- Один офицер (глава) и 22 допуска: получатель проверяет не больше AUTH_NEW_PER_MIN допусков от
-- отправителя за минуту, поэтому каталог идёт частями, и вошедшие подряд получают все допуски.
T.test("trust-catalog: один офицер и 22 допуска — вошедшие получают все, не больше 20 за минуту", function()
	local w, k, _, m = Build(0)
	local Ed, letters = k.ns.Ed25519, { "А", "Б", "В", "Г", "Д", "Е", "Ж", "З", "И", "К", "Л",
		"М", "Н", "О", "П", "Р", "С", "Т", "У", "Ф", "Х", "Ц" }
	local names = {}
	for i, l in ipairs(letters) do
		names[i] = "Страж " .. l .. "ронов"
		w:AddOffline(MAIN, names[i] .. "-" .. k.realm, 1)
	end
	for _, c in ipairs(w.clients) do c.ns.Roster.Scan() end
	for i, name in ipairs(names) do
		T.ok(k.ns.Issuers.Grant(name, Ed.ToB64(Ed.PublicKey(string.rep(string.char(i), 32)))), name .. ": допуск")
		w:Run(3)
	end
	w:Run(180)
	local gk, kds = k.ns.Util.GuildKey(MAIN), 0
	for _, d in pairs(k.ns.store.security.issuers[gk] or {}) do
		if d.active then kds = kds + 1 end
	end
	T.eq(kds, 22, "у главы 22 действующих допуска")
	-- Свои отправки KD главы: время, когда сообщение ушло целиком, и что именно.
	local sent, order = {}, {}
	k.ns.Comm.Watch(function(msg, sender)
		if not sender and msg:sub(1, 2) == "KD" then
			sent[#sent + 1] = w.now
			order[#order + 1] = msg
		end
	end)
	local guests = {}
	for i = 1, 10 do
		guests[i] = { c = Join(w, "Г" .. i), at = w.now }
		w:Run(20)
	end
	w:Run(150)
	for i, e in ipairs(guests) do
		local ok = HasCatalog(k, e.c)
		T.ok(ok, "гость " .. i .. " получил все допуски")
	end
	T.ok(HasCatalog(k, m), "и рядовой, который всё это время в игре")
	local most = 0
	for i = 1, #sent do
		local n = 0
		for j = i, #sent do
			if sent[j] - sent[i] < 60 then n = n + 1 end
		end
		if n > most then most = n end
	end
	T.ok(most <= k.ns.Config.AUTH_NEW_PER_MIN, "допусков за минуту от главы не больше предела получателя: " .. most)
	T.ok(#sent >= 22, "все допуски разосланы: " .. #sent)
	-- Первый заход упирается в предел; следующий начинается с того, что в первый не вошло.
	local cap, first, rest = k.ns.Config.TRUST_SHARE_PER_MIN, {}, 0
	for i = 1, cap do first[order[i] or ""] = true end
	for i = cap + 1, 22 do
		if order[i] and not first[order[i]] then rest = rest + 1 end
	end
	T.eq(rest, 22 - cap, "второй заход — с допусков, не вошедших в первый")
	Errors(w)
end)

T.test("trust-catalog: копии рядового и чужие байты не заглушают офицеров", function()
	local w, k, _, m, officers = Build(3)
	local senders = Keys(officers)
	senders[k.ns.myKey] = true
	local g = Join(w, "Первый")
	local heard = Listen(g)
	local t0 = w.now
	w:Run(0.5)
	-- Рядовой повторяет каталог байт в байт, офицер шлёт допуски с лишним символом.
	local records = k.ns.Security.Catalog()
	for _, r in ipairs(records) do
		m.ns.Comm.Send("GUILD", r.wire, { prefix = r.prefix, prio = m.ns.Comm.PRIO_CONTROL })
		if r.kind == "KD" then
			officers[1].ns.Comm.Send("GUILD", r.wire .. "A", { prefix = r.prefix, prio = officers[1].ns.Comm.PRIO_CONTROL })
		end
	end
	w:Run(90)
	T.ok(HasCatalog(k, g), "вошедший получил весь каталог")
	local copies = Copies(heard, t0, senders)
	for _, r in ipairs(records) do
		local got = (copies[r.id] or 0) + (r.base and copies[r.base] or 0)
		T.ok(got >= 1, r.slot .. ": офицеры разослали сами")
	end
end)

T.test("trust-catalog: новая запись и явное действие уходят сразу", function()
	local w, k, _, m, officers = Build(3)
	local heard = Listen(m)
	local g = Join(w, "Первый")
	local t0 = w.now
	local owner
	-- Ждать именно UO главы с доказательством. Репортёр на Q1 вошедшего может успеть раньше со
	-- своим UO без доказательства, а он запись главы не покрывает: глава шлёт её всё равно.
	local id = k.ns.UnionAuthority.Record().id
	T.ok(RunUntil(w, function()
		for _, e in ipairs(heard) do
			if e.id == id and e.started >= t0 then owner = e; return true end
		end
	end, 60), "владелец разослан для вошедшего")
	-- Гильдия только что слышала владельца: тот же UO не повторяется, а явное действие — да.
	T.eq(k.ns.UnionAuthority.Share("GUILD"), false, "тот же владелец сразу после рассылки не повторяется")
	T.ok(k.ns.UnionAuthority.Share("GUILD", nil, true), "с force — уходит")
	T.ok(RunUntil(w, function() return HasCatalog(k, g) end, 60))
	-- Отзыв допуска: новые байты уходят сразу, хотя каталог только что разослан.
	local t1 = w.now
	T.ok(k.ns.Issuers.Revoke(officers[1]:Name()), "допуск отозван")
	local gk = k.ns.Util.GuildKey(MAIN)
	local wire
	local ok = RunUntil(w, function()
		local d = k.ns.store.security.issuers[gk][officers[1].ns.myKey]
		if d and not d.active then wire = "KD~" .. k.ns.Ed25519.ToB64(d.raw) end
		for _, e in ipairs(heard) do
			if wire and e.id == k.ns.PREFIX .. "\n" .. wire then return true end
		end
	end, 10)
	T.ok(ok, "рядовой услышал отзыв меньше чем за 10 секунд: " .. (w.now - t1))
	T.ok(owner ~= nil)
	Errors(w)
end)

T.test("trust-catalog: привет в ответ на запросы каталога — не чаще окна", function()
	local w, k, _, _, officers = Build(1)
	local o = officers[1]
	local window = o.ns.Config.TRUST_SHARE_WINDOW
	local function Hellos(from, to)
		local n = 0
		for _, e in ipairs(w.log) do
			if e.from == o:Name() and e.dist == "GUILD" and e.msg:sub(1, 2) == "H1" and e.t >= from and e.t < to then n = n + 1 end
		end
		return n
	end
	-- Без запросов — плановый привет раз в HELLO_EVERY.
	local t0 = w.now
	w:Run(180)
	local every = o.ns.Config.HELLO_EVERY
	T.ok(Hellos(t0, w.now) >= math.floor(180 / every) - 1, "плановый привет идёт: " .. Hellos(t0, w.now))
	-- Запрос каждые две секунды: привет — не чаще окна, плюс плановые.
	local t1 = w.now
	for _ = 1, 60 do
		T.ok(o.ns.Security.ShareTrust(false, k.ns.myKey))
		w:Run(2)
	end
	local n = Hellos(t1, w.now)
	T.ok(n <= math.ceil(120 / window) + math.ceil(120 / every) + 1, "приветов за 120 с: " .. n)
	-- Сменилась готовность — привет сразу, даже внутри окна.
	local calls, send = 0, o.ns.Census.SendHello
	o.ns.Census.SendHello = function(...) calls = calls + 1; return send(...) end
	o.ns.Census.Hello(window)
	o.ns.Census.Hello(window)
	T.ok(calls <= 1)
	local before = calls
	o.ns.Census.Hello(window)
	T.eq(calls, before, "внутри окна — без привета")
	local cert = o.ns.Security.MyCertificate
	o.ns.Security.MyCertificate = function() return nil end
	o.ns.Census.Hello(window)
	o.ns.Security.MyCertificate = cert
	T.eq(calls, before + 1, "готовность сменилась — сразу")
end)

T.test("trust-catalog: без входов корень повторяется не чаще TRUST_SHARE_ROOTS, новому соседу — в окне", function()
	local w, k, _, m = Build(2)
	local C = k.ns.Config
	local heard = Listen(m)
	local root = k.ns.store.security.roots[k.ns.Util.GuildKey(k.guild)]
	local id = k.ns.PREFIX .. "\n" .. "KT~" .. root.guild .. "~" .. root.name .. "~" .. root.public
	local function Count(since)
		local n, last = 0, nil
		for _, e in ipairs(heard) do
			if e.id == id and e.started >= since then n, last = n + 1, e.started end
		end
		return n, last
	end
	local function Admins(fn)
		for _, c in ipairs(w.clients) do
			if c.guild == k.guild and c.ns.Security.CanAdmin() then fn(c) end
		end
	end
	-- Без входов корень просят только K1 раз в минуту и плановое объявление офицера.
	local t0 = w.now
	w:Run(3 * C.TRUST_SHARE_ROOTS)
	local n = Count(t0)
	T.ok(n >= 1 and n <= 4, "копий корня за " .. 3 * C.TRUST_SHARE_ROOTS .. " с: " .. n)
	-- Сразу после копии плановые запросы её не повторяют.
	local t1 = w.now
	T.ok(RunUntil(w, function() return Count(t1) > 0 end, C.TRUST_SHARE_ROOTS + 60), "копия корня по плановым запросам")
	local _, copied = Count(t1)
	Admins(function(c) c.ns.TrustCatalog.Request(nil, true) end)
	w:Run(90)
	T.eq(Count(copied + 0.5), 0, "плановый запрос через 90 с после копии")
	-- Корни новому соседу — через окно, а не через TRUST_SHARE_ROOTS.
	local t2 = w.now
	Admins(function(c) c.ns.TrustCatalog.Request(m.ns.myKey, true, nil, true) end)
	T.ok(RunUntil(w, function() return Count(t2) > 0 end, C.TRUST_SHARE_DELAY + C.TRUST_SHARE_JITTER + 5),
		"новому соседу корень пришёл через " .. (w.now - t2) .. " с")
	T.eq(#k.ns.db.errors, 0, "без ошибок")
end)

T.test("trust-catalog: продление сертификата идёт без корня, первый сертификат вошедшему — с корнем", function()
	local w, k, _, _, officers = Build(1)
	local o, C = officers[1], k.ns.Config
	-- Корень перед выданным сертификатом (Security.ShareRoot) — KT с before = "credential:<ключ>".
	-- Продлевает издатель-корень (Карл) и роль офицера, и свою.
	local roots, renewals = 0, { [o.ns.myKey] = 0, [k.ns.myKey] = 0 }
	local send = k.ns.Comm.Send
	k.ns.Comm.Send = function(dist, msg, opts)
		if dist == "GUILD" and opts and msg:sub(1, 3) == "KT~" and tostring(opts.before):find("^credential:") then
			roots = roots + 1
		end
		local to = dist == "GUILD" and opts and msg:sub(1, 3) == "KP~" and tostring(opts.key):match("^credential:(.+)$")
		if to and renewals[to] then renewals[to] = renewals[to] + 1 end
		return send(dist, msg, opts)
	end
	local since = k.ns.ServerTime()
	w:Run(2 * C.AUTH_RENEW + 60)
	T.ok(renewals[o.ns.myKey] >= 1, "роль офицера продлена: " .. renewals[o.ns.myKey])
	T.ok(renewals[k.ns.myKey] >= 1, "своя роль главы продлена: " .. renewals[k.ns.myKey])
	T.eq(roots, 0, "корень перед продлением не уходит")
	local mine = o.ns.Security.MyCertificate()
	T.ok(mine and mine.issued >= since, "офицер принял продлённый сертификат")
	local g = Join(w, "Новичок")
	T.ok(RunUntil(w, function() return g.ns.Security.MyCertificate() ~= nil end, 120), "вошедший получил сертификат")
	T.ok(roots >= 1, "перед первым сертификатом — корень: " .. roots)
	T.eq(#k.ns.db.errors, 0, "без ошибок")
end)

-- Офицер прежней версии: на каждый запрос шлёт весь каталог (или только корни) сразу, без окна.
-- reversed — в обратном порядке: допуски и решения раньше корня и владельца; once — весь каталог
-- только на первый запрос, дальше молчит.
local function OldOfficer(old, reversed, once)
	local TC = old.ns.TrustCatalog
	local sent = false
	local function OldShare(roots)
		if once and (sent or roots) then return end
		sent = true
		local list = old.ns.Security.Catalog()
		for i = 1, #list do
			local r = list[reversed and #list + 1 - i or i]
			if not roots or r.kind == "KT" then
				old.ns.Comm.Send("GUILD", r.wire, { prefix = r.prefix, prio = true, key = "old:" .. r.slot })
			end
		end
	end
	TC.Request = function(_, roots) OldShare(roots) end
	TC.Urgent = function() OldShare(false) end
	-- Новой очереди каталога у него нет.
	local send = old.ns.Comm.Send
	old.ns.Comm.Send = function(dist, payload, opts)
		if opts and type(opts.key) == "string" and opts.key:find("^trust:") then return false end
		return send(dist, payload, opts)
	end
end

-- Офицер прежней версии шлёт весь каталог на каждый запрос, как раньше. Новые офицеры его слышат
-- и того, что он уже разослал, не повторяют.
T.test("trust-catalog: смешанная сеть — копии офицера прежней версии засчитываются", function()
	local w, k, _, m, officers = Build(4)
	local old = officers[1]
	OldOfficer(old)
	local senders = Keys(officers)
	senders[k.ns.myKey] = true
	local fresh = {}
	for key in pairs(senders) do fresh[key] = key ~= old.ns.myKey or nil end
	local heard = Listen(m)
	local t0 = w.now
	local g = Join(w, "Первый")
	w:Run(90)
	T.ok(HasCatalog(k, g), "вошедший получил весь каталог")
	local fromOld = Copies(heard, t0, { [old.ns.myKey] = true })
	T.ok(next(fromOld) ~= nil, "офицер прежней версии разослал каталог")
	-- Новые офицеры не начинают то, что уже пришло от прежнего меньше окна назад.
	None(Repeats(heard, t0, senders, k.ns.Config.TRUST_SHARE_WINDOW, fresh), "услышанное от прежнего не повторяется")
	local copies = Copies(heard, t0, fresh)
	local total, n = 0, 0
	for _, r in ipairs(k.ns.Security.Catalog()) do
		if r.kind == "KD" or r.kind == "KA" then
			n = n + 1
			total = total + (copies[r.id] or 0)
		end
	end
	T.ok(total <= n, ("новые офицеры: %d копий допусков и решений на %d записей"):format(total, n))
	Errors(w)
end)

-- Допуск, пришедший раньше корня, вошедший отбрасывает. Такая копия его не обслужила: новые
-- офицеры повторяют допуск после корня, а не считают его разосланным. Прежний офицер здесь
-- отвечает один раз: иначе вошедший взял бы допуск из его следующей пачки.
-- Придёт ли его допуск раньше корня, решают паузы офицеров (случайные числа симулятора, у Lua 5.1
-- и LuaJIT разные) и плановое объявление корня незадолго до запроса: корень мог прийти первым,
-- тогда допуск принят и повторять нечего. Поэтому вход проверяется на нескольких seed: весь
-- каталог вошедший получает всегда, а где допуск пришёл раньше корня, его повторяет новый офицер.
-- Возвращает, пришёл ли допуск раньше корня.
local function EarlyPermit(seed)
	local w, k, _, m, officers = Build(3, seed)
	local old = officers[1]
	OldOfficer(old, true, true)
	local heard = Listen(m)
	local t0 = w.now
	local g = Join(w, "Первый")
	local window = k.ns.Config.TRUST_SHARE_WINDOW
	T.ok(RunUntil(w, function() return HasCatalog(k, g) end, 2 * window + 30),
		("seed %d: вошедший получил весь каталог"):format(seed))
	-- Прежний прислал допуск раньше корня; новый повторил его после корня.
	local fresh = Keys(officers)
	fresh[old.ns.myKey], fresh[k.ns.myKey] = nil, true
	local kt = "KT:" .. k.ns.Util.GuildKey(MAIN)
	local root, early, late
	for _, r in ipairs(k.ns.Security.Catalog()) do
		if r.slot == kt then root = r.id end
	end
	local firstRoot
	for _, e in ipairs(heard) do
		if e.id == root and e.started >= t0 and not firstRoot then firstRoot = e.at end
	end
	for _, e in ipairs(heard) do
		if e.kind == "KD" and e.started >= t0 then
			if e.from == old.ns.myKey and firstRoot and e.at < firstRoot then early = true end
			if fresh[e.from] and firstRoot and e.started > firstRoot then late = true end
		end
	end
	if early then T.ok(late, ("seed %d: новый офицер повторил допуск после корня"):format(seed)) end
	Errors(w)
	return early
end

T.test("trust-catalog: допуск раньше корня не засчитывается — вошедший получает его следующей копией", function()
	local early = 0
	for _, seed in ipairs({ 11, 1, 2, 3, 4 }) do
		if EarlyPermit(seed) then early = early + 1 end
	end
	T.ok(early > 0, "хотя бы на одном seed прежний прислал допуск раньше корня")
end)

-- Записи каталога, которые отправили сами clients (свои отправки Comm.Watch, без отправителя): [id] = n.
local function Sent(clients)
	local out = {}
	for _, c in ipairs(clients) do
		c.ns.Comm.Watch(function(msg, sender, prefix)
			if not sender and KINDS[msg:sub(1, 2)] then
				local id = prefix .. "\n" .. msg
				out[id] = (out[id] or 0) + 1
			end
		end)
	end
	return out
end

-- Сообщения GUILD от c в журнале мира начиная с from, которые начинаются с head.
local function Logged(w, c, from, head)
	local out = {}
	for i = from, #w.log do
		local e = w.log[i]
		if e.dist == "GUILD" and e.from == c:Name() and e.msg:sub(1, #head) == head then out[#out + 1] = e.msg end
	end
	return out
end

T.test("trust-catalog: хэш сверки — шесть знаков, у всех одинаковый, UO главы и без доказательства совпадают", function()
	local _, k, _, m = Build(1)
	local TC, seen = k.ns.TrustCatalog, {}
	for _, r in ipairs(k.ns.Security.Catalog()) do
		local d = TC.Digest(r)
		T.ok(#d == TC.DIGEST and d:match("^[%w_-]+$") ~= nil, r.slot .. ": " .. d)
		T.eq(m.ns.TrustCatalog.Digest(r), d, r.slot .. ": у рядового тот же")
		T.ok(not seen[d], r.slot .. ": хэш не повторяется")
		seen[d] = true
	end
	local uo = k.ns.UnionAuthority.Record()
	T.ok(uo.base ~= nil, "у главы UO с доказательством")
	local bare = TC.Record("UO", "UO", uo.base:match("\n(.*)$"), uo.prefix)
	T.eq(TC.Digest(bare), TC.Digest(uo), "UO без доказательства — тот же хэш")
end)

-- /reload рядового: k, офицеры и сам рядовой; drop — что рядовой после перезагрузки не отправит,
-- idle — сколько он перед этим в игре. Возвращает перезагруженного, отправленные офицерами
-- записи, начало журнала и офицеров с главой.
local function Reload(w, k, m, officers, drop, idle)
	local senders = { k }
	for _, o in ipairs(officers) do senders[#senders + 1] = o end
	w:Run(idle or 60)
	local sent, from = Sent(senders), #w.log + 1
	local m2 = w:Reload(m)
	if drop then
		local send = m2.ns.Comm.Send
		m2.ns.Comm.Send = function(dist, msg, opts)
			if dist == "GUILD" and msg:find(drop) then return true end
			return send(dist, msg, opts)
		end
	end
	w:Run(120)
	return m2, sent, from, senders
end

-- После /reload записи каталога у рядового есть: сверка (UH) перед UQ называет их, и офицеры не
-- повторяют ничего — ни по UQ, ни репортёр на Q1. Прежде каждый /reload стоил гильдии всего каталога.
-- Перезагрузка — через KEEP после входа: офицеры уже забыли и его прежний запрос, и свои копии.
T.test("trust-catalog: /reload рядового с полным каталогом — сверка вместо каталога", function()
	local w, k, _, m, officers = Build(3)
	T.ok(HasCatalog(k, m), "у рядового весь каталог")
	local m2, sent, from, senders = Reload(w, k, m, officers, nil, 16 * 60)
	T.ok(HasCatalog(k, m2), "каталог на месте")
	T.ok(m2.ns.IsMember(), "и членство")
	local uh = Logged(w, m2, from, "UH~")
	T.eq(#uh, 1, "сверка ушла один раз")
	T.eq(#Logged(w, m2, from, "UQ~1"), 1, "и UQ")
	-- Ответ репортёра на его Q1 (Census.lua): кто бы ни был репортёром, срочно — ничего.
	for _, o in ipairs(senders) do o.ns.Security.ShareTrust(false, m2.ns.myKey, true) end
	w:Run(30)
	local set = {}
	for i = 4, #(uh[1] or ""), 6 do set[uh[1]:sub(i, i + 5)] = true end
	for _, r in ipairs(k.ns.Security.Catalog()) do
		T.ok(set[k.ns.TrustCatalog.Digest(r)], r.slot .. ": есть в сверке рядового")
		-- Корень (KT) не в счёт: перед сертификатами авторов отчётов его шлёт Security.ShareRoot.
		local got = (sent[r.id] or 0) + (r.base and sent[r.base] or 0)
		if r.kind ~= "KT" then T.eq(got, 0, r.slot .. ": не повторялась") end
	end
	Errors(w)
end)

-- Сверка не дошла (или прежняя версия): UQ просит весь каталог, как прежде.
T.test("trust-catalog: /reload без сверки — весь каталог, как прежде", function()
	local w, k, _, m, officers = Build(3)
	local m2, sent = Reload(w, k, m, officers, "^UH~")
	T.ok(HasCatalog(k, m2), "каталог на месте")
	for _, r in ipairs(k.ns.Security.Catalog()) do
		local got = (sent[r.id] or 0) + (r.base and sent[r.base] or 0)
		T.ok(got >= 1, r.slot .. ": разослана")
	end
	Errors(w)
end)

-- Пока рядового не было, у него пропал допуск офицера: сверка его не называет, и приходит только
-- он и корень гильдии, без которого допуск не примут.
T.test("trust-catalog: после сверки — только недостающая запись и её корень", function()
	local w, k, _, m, officers = Build(3)
	local gk = k.ns.Util.GuildKey(MAIN)
	local key = officers[2].ns.myKey
	local d = k.ns.store.security.issuers[gk][key]
	T.ok(d and d.active, "у офицера допуск")
	m.ns.store.security.issuers[gk][key] = nil
	T.no(HasCatalog(k, m), "у рядового его нет")
	local m2, sent = Reload(w, k, m, officers)
	T.ok(HasCatalog(k, m2), "допуск пришёл")
	local wire = "KD~" .. k.ns.Ed25519.ToB64(d.raw)
	for _, r in ipairs(k.ns.Security.Catalog()) do
		local got = (sent[r.id] or 0) + (r.base and sent[r.base] or 0)
		if r.wire == wire then
			T.ok(got >= 1 and got <= 2, r.slot .. ": недостающий допуск, копий " .. got)
		elseif r.slot == "KT:" .. gk then
			T.ok(got >= 1, "корень гильдии — перед ним: " .. got)
		elseif r.kind ~= "KT" then
			T.eq(got, 0, r.slot .. ": не повторялась")
		end
	end
	Errors(w)
end)

-- Без входов каталог не повторяется: копии забываются через KEEP, и запросы — тоже, вместе с
-- последним (иначе забытая копия снова делала запись неразосланной). UO главы с продлённым
-- сертификатом (новые байты раз в AUTH_RENEW) — тот же владелец: его не повторяют. Корни идут
-- плановым объявлением, как прежде.
T.test("trust-catalog: без входов каталог не повторяется — ни после KEEP, ни после продления главы", function()
	local w, k, _, _, officers = Build(3)
	local senders = { k }
	for _, o in ipairs(officers) do senders[#senders + 1] = o end
	local sent = Sent(senders)
	w:Run(45 * 60)
	for _, r in ipairs(k.ns.Security.Catalog()) do
		local got = (sent[r.id] or 0) + (r.base and sent[r.base] or 0)
		if r.kind ~= "KT" then T.eq(got, 0, r.slot .. ": копий без входов") end
	end
	local other = 0
	for id, n in pairs(sent) do
		if not id:find("\nKT~") then other = other + n end
	end
	T.eq(other, 0, "и прежних байтов той же записи (UO до продления)")
	Errors(w)
end)
