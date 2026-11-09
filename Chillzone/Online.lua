-- Chillzone: поимённый список тех, кто в игре, в других гильдиях объединения.
-- Список велик и нужен только тому, кто его смотрит, поэтому он не ходит с переписью через
-- реле. Зритель шепчет запрос OQ репортёру гильдии (запасные адресаты — глава, офицеры и
-- связные, которые по отчёту в игре), тот отвечает страницами OL из своего ростера.
-- Шептать может только участник с действующим сертификатом объединения: отправителя шёпота
-- подтверждает сервер, принадлежность к гильдии — сертификат. Содержимое списка, как и отчёт
-- переписи, остаётся заявлением ответившего, поэтому страницы не подписываются.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec

local Online = {}
ns.Online = Online

local lists = {} -- [guildKey] = { guild, st, at, people }: последний целиком полученный список
local asks = {} -- [guildKey] = запрос в пути: { gk, guild, fp, queue, key, deadline, st, n, got, pages }
local failed = {} -- [guildKey] = до какого времени не спрашивать: никто не ответил
local lastQuery = {} -- [ключ спрашивающего] = когда он спрашивал меня
local serving = {} -- [ключ спрашивающего] = true, пока ему уходит список

local function Merge(pages, n)
	local out, seen = {}, {}
	for i = 1, n or 0 do
		for _, p in ipairs(pages[i] or {}) do
			local k = U.Key(p.name)
			if k and not seen[k] then
				seen[k] = true
				out[#out + 1] = p
			end
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Зритель
---------------------------------------------------------------------------

-- Кого спрашивать: сначала репортёра, затем случайных из руководства в игре. Случайно — чтобы
-- зрители не собирались у одних и тех же и повторный запрос пробовал других.
local function Candidates(guild)
	local row = ns.Data.Row(guild)
	if not row or not row.r or not ns.Data.IsFresh(row) then return {} end
	local out, rest, seen = {}, {}, { [ns.myKey] = true }
	local function add(list, name, online)
		local k = online and U.Key(name)
		if k and not seen[k] then
			seen[k] = true
			list[#list + 1] = name
		end
	end
	add(out, row.origin, true)
	add(rest, row.r.leader, row.r.leaderOnline)
	for _, p in ipairs(row.r.officers or {}) do add(rest, p.name, p.online) end
	for _, p in ipairs(row.r.veterans or {}) do add(rest, p.name, p.online) end
	while #rest > 0 and #out < C.ONLINE_TRIES do
		out[#out + 1] = table.remove(rest, math.random(#rest))
	end
	return out
end

-- Спросить следующего адресата; кончились — запомнить неудачу.
local function Next(ask)
	if asks[ask.gk] ~= ask then return end
	local name = table.remove(ask.queue, 1)
	if not name then
		asks[ask.gk] = nil
		failed[ask.gk] = ns.Now() + C.ONLINE_RETRY
		ns.Fire("ONLINE", ask.gk)
		return
	end
	local key = U.Key(name)
	ask.key, ask.deadline = key, ns.Now() + C.ONLINE_WAIT
	ask.st, ask.n, ask.got, ask.pages = nil, nil, 0, {}
	ns.Security.Introduce(name) -- адресату не придётся спрашивать сертификат отдельно
	local sent = ns.Comm.Send("WHISPER", Codec.EncodeOnlineQuery(ask.guild, ask.fp), {
		target = name, prio = true, key = "oq:" .. ask.gk,
		done = function(ok)
			if not ok and ask.key == key then Next(ask) end
		end,
	})
	if not sent and ask.key == key then Next(ask) end
end

-- Попросить список гильдии, если его нет или он устарел. Без запроса — своя гильдия (она видна
-- по ростеру), блокировка чата, нет своего сертификата или нет свежего отчёта с адресатами.
function Online.Want(guild)
	local gk = guild and U.GuildKey(guild)
	local own = ns.MyGuild()
	if not gk or asks[gk] or (own and U.GuildKey(own) == gk) then return end
	local now, list = ns.Now(), lists[gk]
	if (list and now - list.at < C.ONLINE_REFRESH) or (failed[gk] and now < failed[gk]) then return end
	local mine = ns.Security.MyCertificate()
	if not mine or ns.Comm.InLockdown() then return end
	local queue = Candidates(guild)
	if #queue == 0 then return end
	failed[gk] = nil
	local ask = { gk = gk, guild = guild, fp = mine.fp, queue = queue }
	asks[gk] = ask
	Next(ask)
	ns.Fire("ONLINE", gk)
end

-- Что показать про гильдию: { people, at — когда получен список, loading, got, n, failed }.
function Online.Get(guild)
	local gk = U.GuildKey(guild)
	local list, ask = lists[gk], asks[gk]
	if list and ns.Now() - list.at > C.ONLINE_KEEP then
		lists[gk], list = nil, nil
	end
	if list then return { people = list.people, at = list.at } end
	if ask then return { people = Merge(ask.pages, ask.n), loading = true, got = ask.got, n = ask.n } end
	return { people = {}, failed = failed[gk] ~= nil }
end

local function Take(ask, page)
	if page.st ~= ask.st or page.n ~= ask.n then
		ask.st, ask.n, ask.got, ask.pages = page.st, page.n, 0, {}
	end
	if not ask.pages[page.i] then
		ask.pages[page.i] = page.people
		ask.got = ask.got + 1
	end
	ask.deadline = ns.Now() + C.ONLINE_WAIT
	if ask.got >= ask.n then
		asks[ask.gk] = nil
		lists[ask.gk] = { guild = ask.guild, st = ask.st, at = ns.Now(), people = Merge(ask.pages, ask.n) }
	end
	ns.Fire("ONLINE", ask.gk)
end

-- Принимается только от того, кого спросили, и только если его сертификат — той самой гильдии.
ns.Comm.On("OL", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local page = Codec.DecodeOnlinePage(msg)
	if not page or not U.IsMemberGuild(page.guild) then return end
	local gk, from = U.GuildKey(page.guild), U.Key(sender)
	local ask = asks[gk]
	if not ask or ask.key ~= from then return end
	ns.Security.Resolve(page.fp, sender, sender, function(certificate)
		if asks[gk] == ask and ask.key == from and U.GuildKey(certificate.guild) == gk then Take(ask, page) end
	end)
end)

---------------------------------------------------------------------------
-- Отвечающий
---------------------------------------------------------------------------
local function ServingCount()
	local n = 0
	for _ in pairs(serving) do n = n + 1 end
	return n
end

-- Страницы уходят по одной: следующая встаёт в очередь, когда ушла предыдущая, поэтому
-- длинный список не занимает очередь и не задерживает чат.
local function Serve(sender, key, guild)
	local mine, report = ns.Security.MyCertificate(), ns.Roster.report
	if not mine or not report or serving[key] or ServingCount() >= C.ONLINE_SERVE_MAX then return end
	local people = {}
	for _, m in ipairs(ns.Roster.members) do
		if m.online then people[#people + 1] = { name = U.Display(m.name), class = m.class, level = m.level } end
	end
	local pages, i = Codec.EncodeOnlinePages(guild, mine.fp, report.st, people), 0
	serving[key] = true
	ns.Security.Introduce(sender) -- новый адресат мог ещё не знать мой сертификат
	local function Step(ok)
		if ok and i < #pages then
			i = i + 1
			if ns.Comm.Send("WHISPER", pages[i], { target = sender, key = "ol:" .. key, done = Step }) then return end
		end
		serving[key] = nil
	end
	Step(true)
end

ns.Comm.On("OQ", function(msg, sender, dist)
	if dist ~= "WHISPER" or not ns.IsMember() then return end
	local guild, fp = Codec.DecodeOnlineQuery(msg)
	local own = ns.MyGuild()
	if not guild or U.GuildKey(guild) ~= U.GuildKey(own) then return end
	-- В блокировке ответ застрял бы в очереди: пусть зритель спросит запасного адресата.
	if ns.Comm.InLockdown() or not ns.Roster.Fresh() then return end
	local key, now = U.Key(sender), ns.Now()
	if not key or (lastQuery[key] and now - lastQuery[key] < C.ONLINE_SERVE_GAP) then return end
	lastQuery[key] = now -- до проверки сертификата: иначе поток выдуманных отпечатков вызовет поток KQ
	ns.Security.Resolve(fp, sender, sender, function(certificate)
		if U.IsMemberGuild(certificate.guild) and U.GuildKey(certificate.guild) ~= U.GuildKey(own) then
			Serve(sender, key, own)
		end
	end)
end)

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
ns.On("LOGIN", function()
	ns.Every(2, "online deadlines", function()
		local now, due = ns.Now(), {}
		-- Сначала список: Next будит окно, а оно может добавить запрос прямо во время обхода.
		for _, ask in pairs(asks) do
			if now >= ask.deadline then due[#due + 1] = ask end
		end
		for _, ask in ipairs(due) do Next(ask) end
		for key, at in pairs(lastQuery) do
			if now - at >= C.ONLINE_SERVE_GAP then lastQuery[key] = nil end
		end
	end)
end)

ns.On("GUILD_CHANGED", function()
	wipe(lists)
	wipe(asks)
	wipe(failed)
end)
