-- Chillzone: прямой запрос отчёта переписи у его автора, в обход реле.
-- Отчёт гильдии идёт к остальным через реле главной гильдии. Если реле молчат (аддон выключен,
-- шёпот не доходит), отчёт не доходит ни до кого, и взять его у соседа нельзя. Тогда гильдия, у
-- которой чужой отчёт старше PULL_AFTER (дольше REPORT_IDLE: живой репортёр за это время
-- отчитался бы), шепчет запрос RQ участнику той гильдии: сначала автору последнего отчёта (её
-- репортёру тогда), затем случайным из главы, офицеров и связных, которые по тому отчёту были в
-- игре. Ответ RA — отчёт его гильдии, подписанный самим ответившим. Он проверяется как отчёт от
-- реле и уходит гильдии спросившего (RG), как отчёт, пришедший репортёру по аренде.
--
-- Спрашивает репортёр гильдии. Узнать, спрашивает ли он и отвечают ли ему, остальные не могут:
-- шёпот виден только адресату, а репортёр может быть старой версии, в блокировке чата или без
-- ответа от своих адресатов. Поэтому, если отчёт так и не обновился, на PULL_HELPER_DELAY позже
-- спрашивает и первый помощник (Census.Helpers), какой бы версии ни был репортёр.
--
-- Отвечает любой обновлённый участник гильдии. Репортёр (или бывший, до перезагрузки) отдаёт свой
-- последний отчёт (Census.lastRaw), пока тот не устарел. Иначе отвечающий подписывает отчёт своей
-- гильдии по своему ростеру и отдаёт его повторно PULL_ANSWER_KEEP. Такой отчёт не уходит ни через
-- реле, ни своей гильдии и не трогает отчёт репортёра. Одиночка не отвечает: подпись только при
-- свежем ростере и после HELPER_SETTLE приветов, иначе число согильдийцев с аддоном было бы
-- занижено. У спросившего этот отчёт новее и вытесняет прежний; отчёт репортёра с меньшим
-- временем, пришедший позже, будет отклонён как «старее» до его следующего отчёта.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec

local Pull = {}
ns.Pull = Pull

local asks = {} -- [guildKey] = { gk, guild, st, fp, queue, key, deadline, probe }: запрос в пути
local retry = {} -- [guildKey] = { at, pause }: никто не ответил — следующий раунд не раньше at
local served = {} -- [ключ спрашивающего] = когда он спрашивал меня
local serveTimes = {} -- когда я брался отвечать кому-либо: за последнюю минуту
Pull.stats = { asked = 0, got = 0, failed = 0, served = 0 }

-- Отчёт внутри подписанного пакета (открытый текст, подпись не проверяется).
local function ReportOf(wire)
	local clear = type(wire) == "string" and wire:match("^S1~[^~]+~%d+~%d+~[^~]+~(R1~.+)$")
	return clear and Codec.DecodeReport(clear) or nil
end

---------------------------------------------------------------------------
-- Спрашивающий
---------------------------------------------------------------------------

-- Кого спрашивать: автора отчёта, затем случайных из главы, офицеров и связных, которые по тому же
-- отчёту были в игре (как в Online.lua: следующий раунд пробует других). Отчёт устарел, поэтому
-- «в игре» — только подсказка: ушедшего сервер назовёт недоступным, и очередь пойдёт дальше.
local function Candidates(row)
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
	while #rest > 0 and #out < C.PULL_TRIES do
		out[#out + 1] = table.remove(rest, math.random(#rest))
	end
	return out
end

local Next -- вперёд

-- Никто не ответил: следующий раунд не раньше чем через паузу, она растёт вдвое до PULL_RETRY_MAX.
local function Fail(ask)
	asks[ask.gk] = nil
	local prev = retry[ask.gk]
	local pause = prev and math.min(prev.pause * 2, C.PULL_RETRY_MAX) or C.PULL_RETRY
	retry[ask.gk] = { at = ns.Now() + pause, pause = pause }
	Pull.stats.failed = Pull.stats.failed + 1
	ns.Log("отчёт %s напрямую не получен, следующая попытка через %d мин", ask.guild, math.floor(pause / 60))
end

-- Спросить следующего адресата. Ожидание ответа начинается после фактической отправки: своя
-- очередь и блокировка чата не делают адресата молчащим. probe отличает текущий вопрос от
-- прежних: их колбэки и таймеры ничего не трогают.
function Next(ask)
	if asks[ask.gk] ~= ask then return end
	local name = table.remove(ask.queue, 1)
	if not name then Fail(ask); return end
	local probe = {}
	ask.key, ask.deadline, ask.probe = U.Key(name), nil, probe
	Pull.stats.asked = Pull.stats.asked + 1
	ns.Security.Introduce(name) -- адресату не придётся спрашивать мой сертификат
	local sent = ns.Comm.Send("WHISPER", Codec.EncodePullQuery(ask.guild, ask.fp, ask.st), {
		target = name, key = "rq:" .. ask.gk,
		done = function(ok)
			if asks[ask.gk] ~= ask or ask.probe ~= probe then return end
			if not ok then Next(ask); return end
			ask.deadline = ns.Now() + C.PULL_WAIT
			ns.After(C.PULL_WAIT + 1, "pull wait", function()
				if asks[ask.gk] == ask and ask.probe == probe then Next(ask) end
			end)
		end,
	})
	if not sent and asks[ask.gk] == ask and ask.probe == probe then Next(ask) end
end

local function Start(gk, row, fp)
	local queue = Candidates(row)
	if #queue == 0 then
		retry[gk] = { at = ns.Now() + C.PULL_RETRY, pause = C.PULL_RETRY }
		return
	end
	local ask = { gk = gk, guild = row.guild, st = row.st or 0, fp = fp, queue = queue }
	asks[gk] = ask
	ns.Log("отчёт %s устарел на %d мин, запрашиваю его напрямую", row.guild, math.floor((ns.ServerTime() - (row.st or 0)) / 60))
	Next(ask)
end

-- С какого возраста отчёта запрос — моя забота: репортёр спрашивает с PULL_AFTER, первые
-- PULL_HELPERS помощников — на PULL_HELPER_DELAY позже, если отчёт так и не обновился. Какой
-- версии репортёр, не важно: спрашивает ли он и отвечают ли ему, помощник не видит.
local function DutyAfter()
	local Census = ns.Census
	if Census.IsReporter() then return C.PULL_AFTER end
	local slot = Census.HelperSlot()
	if slot and slot <= C.PULL_HELPERS then return C.PULL_AFTER + C.PULL_HELPER_DELAY end
	return nil
end

-- Раз в PULL_TICK: устаревшие отчёты других гильдий, если запрос — моя забота. Сразу после входа
-- не спрашиваю: отчёты сначала приходят ответом на Q1 и через реле.
local function Tick()
	if not ns.IsMember() or not ns.loginAt or ns.Now() - ns.loginAt < C.HELPER_SETTLE then return end
	local mine = ns.Security.MyCertificate()
	if not mine or ns.Comm.InLockdown() or not ns.Roster.Fresh() then return end
	local after = DutyAfter()
	local now, server = ns.Now(), ns.ServerTime()
	local own = ns.MyGuild()
	local ownKey = own and U.GuildKey(own)
	local due = {}
	for gk, row in pairs(ns.store and ns.store.guilds or {}) do
		if not row.mine and gk ~= ownKey and row.r and U.IsMemberGuild(row.guild) then
			local age = server - (row.st or 0)
			if age < C.PULL_AFTER then
				asks[gk], retry[gk] = nil, nil -- отчёт обновился сам
			elseif after and age >= after and not asks[gk] and not (retry[gk] and now < retry[gk].at) then
				due[#due + 1] = gk
			end
		end
	end
	for _, gk in ipairs(due) do Start(gk, ns.store.guilds[gk], mine.fp) end
end

-- Ответ принимается только от того, кого спросили, только про ту гильдию, о которой спрашивали, и
-- только до конца ожидания. Остальное отбрасывается до проверки подписи.
ns.Comm.On("RA", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local guild, wire = Codec.DecodePullAnswer(msg)
	if not guild then return end
	local gk, from = U.GuildKey(guild), U.Key(sender)
	local ask = asks[gk]
	if not ask or ask.key ~= from or (ask.deadline and ns.Now() > ask.deadline) then return end
	local r = ReportOf(wire)
	if not r or U.GuildKey(r.guild) ~= gk or (r.st or 0) <= ask.st then return end
	local probe = ask.probe
	-- Автор пакета должен быть самим ответившим: это проверяет Relay.Direct.
	ns.Relay.Direct(sender, wire, function(taken)
		if asks[gk] ~= ask or ask.probe ~= probe then return end
		local row = ns.Data.Row(ask.guild)
		if taken or (row and (row.st or 0) >= r.st) then
			asks[gk], retry[gk] = nil, nil
			Pull.stats.got = Pull.stats.got + 1
			ns.Log("отчёт %s получен напрямую от %s", r.guild, U.Display(sender))
		else
			Next(ask)
		end
	end)
end)

---------------------------------------------------------------------------
-- Отвечающий
---------------------------------------------------------------------------
local answer -- { wire, st, at }: отчёт, подписанный ради ответа; раздаётся повторно PULL_ANSWER_KEEP
local sealing -- { at, waiters, epoch }: такой отчёт подписывается, waiters — кому его отдать
local epoch = 0 -- меняется со сменой гильдии: прежние подписи никому не отдаются
local SEAL_WAIT = 30 -- подпись дольше этого считается потерянной

local function ServeRoom(now)
	while serveTimes[1] and now - serveTimes[1] > 60 do table.remove(serveTimes, 1) end
	return #serveTimes < C.PULL_SERVE_PER_MIN
end

-- Готовый пакет для ответа: мой последний отчёт репортёра, если он ещё не устарел, иначе
-- подписанный недавно ради ответа. Только своей гильдии и только новее, чем у спросившего.
local function Ready(own, st)
	local server = ns.ServerTime()
	local r = ReportOf(ns.Census.lastRaw)
	if r and U.GuildKey(r.guild) == U.GuildKey(own) and (r.st or 0) > st and server - (r.st or 0) < C.PULL_AFTER then
		return ns.Census.lastRaw
	end
	if answer and ns.Now() - answer.at < C.PULL_ANSWER_KEEP and answer.st > st then return answer.wire end
	return nil
end

-- Могу ли подписать свежий отчёт своей гильдии: ростер свежий и новее, чем у спросившего, а приветы
-- слушаю дольше HELPER_SETTLE, иначе число согильдийцев с аддоном было бы занижено. Одиночка,
-- только что вошедший в игру, не отвечает. Подпись не чаще раза в PULL_ANSWER_KEEP: у кого уже
-- есть недавний ответ, тому новой подписи ради чуть более свежего ростера не будет.
local function CanSeal(st)
	if answer and ns.Now() - answer.at < C.PULL_ANSWER_KEEP then return false end
	local r = ns.Roster.report
	return r ~= nil and (r.st or 0) > st and ns.Roster.Fresh() and ns.Census.Settled()
		and ns.Security.MyCertificate() ~= nil
end

local function Answer(sender, own, wire)
	if not ns.IsMember() then return end
	ns.Security.IntroduceWire(sender, wire)
	ns.Comm.Send("WHISPER", Codec.EncodePullAnswer(own, wire), { target = sender, key = "ra:" .. U.Key(sender) })
	Pull.stats.served = Pull.stats.served + 1
	ns.Log("отчёт своей гильдии отдан напрямую: %s", U.Display(sender))
end

-- Подписать отчёт своей гильдии по своему ростеру и отдать его sender. Этот отчёт не уходит ни
-- через реле, ни своей гильдии и не трогает отчёт репортёра (Census.lastRaw и сравнение в
-- MaybeReport): он хранится здесь. Очередь подписи занята или подпись не удалась — молчу, и
-- спросивший перейдёт к следующему адресату.
local function Seal(sender, own, st)
	local waiter = { sender = sender, st = st }
	if sealing and ns.Now() - sealing.at < SEAL_WAIT then
		sealing.waiters[#sealing.waiters + 1] = waiter
		return
	end
	local r = ns.Roster.report
	local copy = Codec.Shareable(r, true)
	copy.users = ns.Census.Users()
	copy.version = ns.VERSION
	local job = { at = ns.Now(), waiters = { waiter }, epoch = epoch }
	sealing = job
	local queued, why = ns.Security.Seal(Codec.EncodeReport(copy), function(wire, failed)
		if sealing == job then sealing = nil end
		if job.epoch ~= epoch then return end
		if not wire then
			ns.Log("отчёт для ответа напрямую не подписан (%s)", tostring(failed))
			return
		end
		answer = { wire = wire, st = copy.st or 0, at = ns.Now() }
		for _, w in ipairs(job.waiters) do
			if answer.st > w.st then Answer(w.sender, own, wire) end
		end
	end)
	if not queued then
		if sealing == job then sealing = nil end
		ns.Log("отчёт для ответа напрямую не подписан (%s)", tostring(why))
	end
end

-- Отвечаю только участнику другой гильдии объединения и только отчётом своей гильдии новее, чем у
-- спросившего: последним своим отчётом репортёра, отчётом, подписанным недавно ради ответа, или
-- свежим, подписанным сейчас по своему ростеру. Гильдии ничего не рассылаю.
ns.Comm.On("RQ", function(msg, sender, dist)
	if dist ~= "WHISPER" or not ns.IsMember() then return end
	local guild, fp, st = Codec.DecodePullQuery(msg)
	local own = ns.MyGuild()
	if not guild or not own or U.GuildKey(guild) ~= U.GuildKey(own) then return end
	-- В блокировке ответ застрял бы в очереди: пусть спросивший перейдёт к другому адресату.
	if ns.Comm.InLockdown() or not ns.Roster.Fresh() then return end
	if not Ready(own, st) and not CanSeal(st) then return end
	local key, now = U.Key(sender), ns.Now()
	if not key or (served[key] and now - served[key] < C.PULL_SERVE_GAP) or not ServeRoom(now) then return end
	-- До проверки сертификата и подписи: иначе поток выдуманных отпечатков вызвал бы поток KQ.
	served[key] = now
	serveTimes[#serveTimes + 1] = now
	local mine = epoch
	ns.Security.Resolve(fp, sender, sender, function(certificate)
		if mine ~= epoch or not ns.IsMember() then return end
		if not U.IsMemberGuild(certificate.guild) or U.GuildKey(certificate.guild) == U.GuildKey(own) then return end
		local wire = Ready(own, st)
		if wire then
			Answer(sender, own, wire)
		elseif CanSeal(st) then
			Seal(sender, own, st)
		end
	end)
end)

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
function Pull.Asking() return asks end

ns.On("LOGIN", function()
	ns.Every(C.PULL_TICK, "pull check", function()
		Tick()
		local now = ns.Now()
		for key, at in pairs(served) do
			if now - at >= C.PULL_SERVE_GAP then served[key] = nil end
		end
	end)
end)

-- Сервер ответил «нет такого игрока»: адресата нет в игре, его ответа не ждём.
ns.On("WHISPER_UNAVAILABLE", function(key)
	local due = {}
	for _, ask in pairs(asks) do
		if ask.key == key and ask.deadline then due[#due + 1] = ask end
	end
	for _, ask in ipairs(due) do Next(ask) end
end)

ns.On("GUILD_CHANGED", function()
	wipe(asks)
	wipe(retry)
	wipe(served)
	answer, sealing, epoch = nil, nil, epoch + 1
end)

ns.Status(function()
	local s = Pull.stats
	if s.asked == 0 and s.served == 0 then return nil end
	return ns.L.STATUS_PULL:format(s.asked, s.got, s.failed, s.served)
end)
