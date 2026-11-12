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

T.test("trust-catalog: восемь офицеров и один вошедший — каждая запись примерно один раз", function()
	local w, k, _, m, officers = Build(8)
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
	T.ok(RunUntil(w, function()
		for _, e in ipairs(heard) do
			if e.kind == "UO" and e.started >= t0 then owner = e; return true end
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
T.test("trust-catalog: допуск раньше корня не засчитывается — вошедший получает его следующей копией", function()
	local w, k, _, m, officers = Build(3)
	local old = officers[1]
	OldOfficer(old, true, true)
	local heard = Listen(m)
	local t0 = w.now
	local g = Join(w, "Первый")
	local window = k.ns.Config.TRUST_SHARE_WINDOW
	T.ok(RunUntil(w, function() return HasCatalog(k, g) end, 2 * window + 30), "вошедший получил весь каталог")
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
	T.ok(early, "прежний прислал допуск раньше корня")
	T.ok(late, "новый офицер повторил допуск после корня")
	Errors(w)
end)
