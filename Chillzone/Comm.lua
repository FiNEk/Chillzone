-- Chillzone: аддон-сообщения. Очередь отправки с двумя полосами, GUILD и WHISPER (раз в 1.2 с
-- каждая полоса отправляет кусок, у реле — 4 куска), повтор при «не сейчас» от игры, блокировка
-- чата в подземельях, сборка кусков и разбор входящих по типам. Правила очереди — из Olympus Comm.lua.
--
-- Полосы. Сервер Forever режет аддон-сообщения GUILD: около 10 сразу, затем 1 в секунду на
-- префикс, лишнее получает код 3. Шёпот вне подземелий этот лимит не трогает. Поэтому порядок
-- заданий общий (приоритеты, ключи, before, переполнение), а отказы подряд, пауза и выброс
-- давних заданий — у каждой полосы свои. За тик полоса отправляет первое по порядку своё
-- задание и так до своей квоты: отказ сервера по GUILD и поток GUILD любого приоритета не
-- задерживают прямые шёпоты (заявки, ответы реле, KP), и наоборот. Блокировка чата (InLockdown
-- и код 11) держит обе полосы.
--
-- Порядок между полосами задаёт только before: задание с ключом K не уходит, пока в очереди
-- есть другое задание, поставленное «перед K», даже если они в разных полосах (KT по GUILD
-- перед KP шёпотом вошедшему, Security.lua). Ждущее так задание пропускается, остальные
-- задания его полосы идут своим порядком.
local ADDON, ns = ...

local U = ns.Util
local Codec = ns.Codec

local Comm = {}
ns.Comm = Comm

Comm.SEND_INTERVAL = 1.2
Comm.PARTS_RELAY = 4
Comm.MAX_QUEUE = 200
Comm.HOLD_MAX = 600 -- не начатое и ждавшее столько, пока его полоса стояла, — выбрасывается
-- Управление связью (опрос корня, отзыв, соединение, приветствия) идёт первым, объявления
-- ключей — следом. Сертификаты идут наравне с чатом (prio = true — уровень 1), в порядке
-- очереди: так поток чата их не задерживает бесконечно, а пачка сертификатов — строки чата.
-- Приоритет упорядочивает задания внутри полосы; GUILD шёпот не обгоняет и не задерживает.
Comm.PRIO_BOOTSTRAP = 2
Comm.PRIO_CONTROL = 3
Comm.PRIO_LINK = 4 -- ручное соединение обгоняет фоновые опросы и их повторы

-- Ответы игры «не сейчас»: AddonMessageThrottle (3), ChannelThrottle (8), GeneralError (9),
-- AddOnMessageLockdown (11). Сообщение остаётся на месте, его полоса ждёт всё дольше;
-- на код 11 ждут обе полосы.
local LOCKDOWN = 11
local TARGET_OFFLINE = 12 -- Enum.SendAddonMessageResult.TargetOffline в API Forever
local RETRYABLE = { [3] = true, [8] = true, [9] = true, [LOCKDOWN] = true }
local RETRY_WAIT = { 2, 4, 8, 15, 30 }
local RETRY_MAX = 5

local queue = {}
local handlers = {}
local assemblers = {}
local nextId = math.random(0, 1000)
-- Полосы по dist: refused — отказов подряд, waitUntil — пауза после отказа, held — полоса
-- стояла (пауза или блокировка): когда она пойдёт, её давние задания выбрасываются.
local lanes, laneOrder = {}, {}
local function Lane(dist)
	local lane = lanes[dist]
	if not lane then
		lane = { dist = dist, refused = 0, waitUntil = 0 }
		lanes[dist] = lane
		laneOrder[#laneOrder + 1] = lane
	end
	return lane
end
Lane("GUILD")
Lane("WHISPER")
local unavailable = {} -- [Key] = до какого времени не шептать недоступному адресату
local MarkUnavailable -- вызывается и по результату отправки, и по системной строке
local WHISPER_FRESH = 10 -- системная ошибка относится только к недавней отправке аддона
Comm.stats = { sent = 0, recv = 0, fails = 0, retried = 0, dropped = 0, queued = 0 }
Comm.lastWhisper = {} -- [Key] = когда шептали (для системного «нет такого игрока»)

-- Типы, текст которых никогда не содержит "|": чистятся целиком до разбора.
local PLAIN = { H1 = true, Q1 = true, RP = true, RY = true, RR = true, RU = true, R1 = true, OQ = true, OL = true, RQ = true }

function Comm.On(kind, fn)
	handlers[kind] = fn
end

local function NewId()
	nextId = (nextId + 1) % 46656
	return Codec.Base36(nextId)
end

function Comm.InLockdown()
	return C_ChatInfo and C_ChatInfo.InChatMessagingLockdown and C_ChatInfo.InChatMessagingLockdown() and true or false
end

local function IsSuccess(res)
	return res == nil or res == true or res == 0
end

local function Unavailable(target)
	local key = U.Key(target)
	local untilAt = key and unavailable[key]
	return untilAt ~= nil and ns.Now() < untilAt
end

local function Tracing()
	return ns.db and ns.db.settings and ns.db.settings.debug
end

-- Одно сообщение прямо сейчас: true или false, код.
function Comm.SendNow(dist, msg, target, logged, prefix, kind, source)
	if Comm.InLockdown() then return false, LOCKDOWN end
	local to = nil
	if dist == "WHISPER" then
		if Unavailable(target) then return false, "offline" end
		to = U.TellName(target)
		Comm.lastWhisper[U.Key(target)] = ns.Now()
	end
	local send = (logged and C_ChatInfo.SendAddonMessageLogged) or C_ChatInfo.SendAddonMessage
	local ok, res = ns.Diagnostics.SendAddon(send, prefix or ns.PREFIX, msg, dist, to, logged, source)
	if dist == "WHISPER" and Tracing() then
		ns.Log("шёпот %s, тип %s, logged=%s: результат %s", to, kind or msg:sub(1, 2), tostring(logged == true), ok and tostring(res) or "ошибка Lua")
	end
	if dist == "WHISPER" and ((ok and res == TARGET_OFFLINE) or Unavailable(target)) then
		Comm.stats.fails = Comm.stats.fails + 1
		if ok and res == TARGET_OFFLINE then MarkUnavailable(U.Key(target), "код TargetOffline") end
		return false, "offline"
	end
	if ok and IsSuccess(res) then
		Comm.stats.sent = Comm.stats.sent + 1
		Lane(dist).refused = 0
		return true
	end
	if ok and RETRYABLE[res] then
		-- Пауза — только полосе этого сообщения: лимит GUILD шёпот не задерживает.
		for _, lane in ipairs(res == LOCKDOWN and laneOrder or { Lane(dist) }) do
			lane.refused = lane.refused + 1
			lane.waitUntil = ns.Now() + RETRY_WAIT[math.min(lane.refused, #RETRY_WAIT)]
		end
	end
	Comm.stats.fails = Comm.stats.fails + 1
	ns.Log("не отправлено %s для %s: %s", dist, to or "гильдии", tostring(res))
	if ok then return false, res end
	return false, "error"
end

local function Finish(job, ok, why)
	if job.finished then return end
	job.finished = true
	for i, j in ipairs(queue) do
		if j == job then
			table.remove(queue, i)
			break
		end
	end
	if not ok then Comm.stats.dropped = Comm.stats.dropped + 1 end
	if job.done then ns.SafeCall("send done", job.done, ok, why) end
end

MarkUnavailable = function(key, why)
	local now = ns.Now()
	if unavailable[key] and now < unavailable[key] then return end
	unavailable[key] = now + ns.Config.RELAY_DOWN
	-- Сначала снимок: done может поставить в очередь другое сообщение.
	local cancelled = {}
	for _, job in ipairs(queue) do
		if job.dist == "WHISPER" and U.Key(job.target) == key then cancelled[#cancelled + 1] = job end
	end
	for _, job in ipairs(cancelled) do Finish(job, false, "offline") end
	ns.Log("адресат шёпота %s недоступен: %s, отменено %d", key, why, #cancelled)
	ns.Fire("WHISPER_UNAVAILABLE", key)
end

---------------------------------------------------------------------------
-- «Нет такого игрока» относится ко всем служебным шёпотам, включая обмен ключами.
-- На Forever серверная строка может отличаться от локализованного шаблона клиента.
-- Фильтр не меняет состояние: его могут вызвать несколько окон до или после события.
---------------------------------------------------------------------------
local notFound
function Comm.NotFoundKey(text)
	if type(text) ~= "string" then return nil end
	if type(issecretvalue) == "function" and issecretvalue(text) then return nil end
	if not notFound and type(ERR_CHAT_PLAYER_NOT_FOUND_S) == "string" then
		notFound = "^" .. (ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("%%%%s", "(.+)")) .. "$"
	end
	local who = (notFound and text:match(notFound)) or text:match('^Персонаж по имени "(.+)" в игре не найден%.$')
	return who and U.Key(who)
end

local function OursNotFound(text)
	local key = Comm.NotFoundKey(text)
	local last = key and ns.Diagnostics.Enabled() and ns.Diagnostics.LastSend(key)
	if last and not last.owned then return nil end
	local at = key and Comm.lastWhisper[key]
	if at and ns.Now() - at <= WHISPER_FRESH then return key end
end

ns.RegisterEvent("CHAT_MSG_SYSTEM", function(text)
	local key = OursNotFound(text)
	if not key then return end
	MarkUnavailable(key, "системная строка")
end)

ns.AddChatFilter("CHAT_MSG_SYSTEM", function(_, _, text)
	return OursNotFound(text) ~= nil
end)

local function Priority(prio)
	return prio == true and 1 or (type(prio) == "number" and prio or 0)
end

local function BeforeIndex(key, prio)
	if not key then return end
	for i, pending in ipairs(queue) do
		if pending.key == key and Priority(pending.prio) == Priority(prio) then return i end
	end
end

local function Enqueue(job, before)
	local pos = #queue + 1
	if job.prio then
		pos = 1
		while queue[pos] and Priority(queue[pos].prio) >= Priority(job.prio) do pos = pos + 1 end
	end
	local target = BeforeIndex(before, job.prio)
	if target and target < pos then pos = target end
	table.insert(queue, pos, job)
end

-- Задание с ключом key не уйдёт, пока job в очереди (и в другой полосе тоже). Ключи копятся:
-- замена по ключу (повторное объявление корня) не отменяет прежних обязательств.
local function AddBefore(job, key)
	if not key or key == job.key then return end
	job.before = job.before or {}
	job.before[key] = true
end

-- В очередь. opts: target (шёпот), key (новое заменяет ещё не начатое с тем же ключом),
-- prio (true или числовой приоритет, больше — раньше), logged (текст игрока), done(ok, why).
-- before — перед заданием с этим ключом: оно уже стоит в очереди (даже отправляется) или
-- будет поставлено, пока это не завершено. Действует и между полосами; в своей полосе
-- задание того же приоритета ещё и ставится прямо перед ним.
-- prefix — явно старый транспорт для каталогов 0.8; новые KA/UQ по умолчанию отделены.
function Comm.Send(dist, payload, opts)
	opts = opts or {}
	if type(payload) ~= "string" or payload == "" then return false end
	if dist == "WHISPER" and not opts.target then return false end
	if dist == "WHISPER" and Unavailable(opts.target) then return false, "offline" end
	Lane(dist)
	local kind = payload:sub(1, 2)
	local source = dist == "WHISPER" and ns.Diagnostics.Callsite() or nil
	local prefix = opts.prefix or ((kind == "KA" or kind == "UQ" or kind == "UO") and ns.Config.UNION_PREFIX) or ns.PREFIX
	local now = ns.Now()
	if opts.key then
		for i, job in ipairs(queue) do
			if job.key == opts.key and job.prefix == prefix and job.dist == dist and job.i == 1 then
				job.parts, job.at, job.target, job.done = Codec.Pack(payload, NewId()), now, opts.target, opts.done
				job.guard = opts.guard
				job.kind, job.source = kind, source
				AddBefore(job, opts.before)
				-- Ответ на срочный запрос мог заменить ещё не отправленное объявление.
				local promoted = Priority(opts.prio) > Priority(job.prio)
				if promoted then job.prio = opts.prio end
				local target = BeforeIndex(opts.before, job.prio)
				if promoted or (target and target < i) then
					table.remove(queue, i)
					Enqueue(job, opts.before)
				end
				return true
			end
		end
	end
	local job = {
		kind = kind, source = source,
		prefix = prefix,
		dist = dist, target = opts.target, parts = Codec.Pack(payload, NewId()), i = 1,
		key = opts.key, prio = opts.prio, logged = opts.logged, at = now, tries = 0, done = opts.done, guard = opts.guard,
	}
	AddBefore(job, opts.before)
	Enqueue(job, opts.before)
	Comm.stats.queued = Comm.stats.queued + 1
	-- Переполнение: выбрасывается самое старое обычное, ещё не начатое.
	while #queue > Comm.MAX_QUEUE do
		local victim
		for _, j in ipairs(queue) do
			if not j.prio and j.i == 1 and j ~= job then
				victim = j
				break
			end
		end
		if not victim then Finish(job, false, "dropped"); return false end
		Finish(victim, false, "dropped")
	end
	return true
end

-- Сколько заданий в очереди; dist — только в этой полосе.
function Comm.QueueSize(dist)
	if not dist then return #queue end
	local n = 0
	for _, job in ipairs(queue) do
		if job.dist == dist then n = n + 1 end
	end
	return n
end

-- Сколько заданий в очереди (и начатых) с ключом, который начинается с prefix; exact — ровно с этим ключом.
function Comm.Queued(prefix, exact)
	local n = 0
	for _, job in ipairs(queue) do
		local key = job.key
		if key and (key == prefix or (not exact and key:sub(1, #prefix) == prefix)) then n = n + 1 end
	end
	return n
end

-- Первое по порядку очереди задание, которое можно отправлять: open(полоса) — полоса открыта,
-- и задание не ждёт другого, поставленного перед ним (before).
local function Next(open)
	local waiting
	for _, j in ipairs(queue) do
		if j.before then
			waiting = waiting or {}
			for key in pairs(j.before) do waiting[key] = true end
		end
	end
	for _, j in ipairs(queue) do
		if open(lanes[j.dist]) and not (waiting and j.key and waiting[j.key]) then return j end
	end
end

-- Очередной кусок задания. false — полоса на этот тик всё: отказ игры или ошибка.
local function SendPart(job)
	if job.guard and not job.guard() then Finish(job, false, "authority changed"); return true end
	if job.dist == "GUILD" and not ns.MyGuild() then
		Finish(job, false, "no guild")
		return true
	end
	local sent, why = Comm.SendNow(job.dist, job.parts[job.i], job.target, job.logged, job.prefix, job.kind, job.source)
	-- Синхронное событие или TargetOffline могли уже отменить и это задание.
	if job.finished then return true end
	if not sent then
		if RETRYABLE[why] then
			if why ~= LOCKDOWN then job.tries = job.tries + 1 end
			if job.tries < RETRY_MAX then
				Comm.stats.retried = Comm.stats.retried + 1
				return false
			end
		end
		Finish(job, false, why or "failed")
		return false
	end
	job.i = job.i + 1
	if job.i > #job.parts then Finish(job, true) end
	return true
end

-- Отметить стоящие полосы; полоса, которая снова пошла, выбрасывает свои не начатые задания,
-- ждавшие HOLD_MAX и дольше. Простой одной полосы задания другой не трогает.
-- true — блокировка чата: стоят обе полосы.
local function Release(now)
	local lockdown = Comm.InLockdown()
	for _, lane in ipairs(laneOrder) do
		if lockdown or now < lane.waitUntil then
			lane.held = true
		elseif lane.held then
			lane.held = nil
			-- Сначала снимок: done может поставить в очередь другое сообщение.
			local stale = {}
			for _, j in ipairs(queue) do
				if j.dist == lane.dist and j.i == 1 and now - j.at >= Comm.HOLD_MAX then stale[#stale + 1] = j end
			end
			for _, j in ipairs(stale) do Finish(j, false, "stale") end
		end
	end
	return lockdown
end

-- Тик насоса: каждая полоса отправляет до своей квоты кусков (у реле — PARTS_RELAY), беря
-- первое по порядку очереди своё задание. Квота своя у каждой полосы: иначе поток GUILD с
-- приоритетом выше, который сервер принимает, навсегда обгонял бы шёпот.
function Comm.Pump()
	if not queue[1] then return end
	local now = ns.Now()
	if Release(now) then return end
	local R = ns.Relay
	local parts = (R and R.IAmRelay and R.IAmRelay()) and Comm.PARTS_RELAY or 1
	local left = {}
	for _, lane in ipairs(laneOrder) do left[lane] = parts end
	local function Open(lane)
		return (left[lane] or 0) > 0 and now >= lane.waitUntil
	end
	while true do
		local job = Next(Open)
		if not job then return end
		local lane = lanes[job.dist]
		left[lane] = SendPart(job) and left[lane] - 1 or 0
	end
end

-- Срочное прямо сейчас, не дожидаясь насоса: до n кусков. Каждый раз — первое по порядку
-- задание с приоритетом, чья полоса не на паузе; обычное задание на очереди — конец.
function Comm.Flush(n)
	local now = ns.Now()
	if Release(now) then return end
	local function Open(lane)
		return now >= lane.waitUntil
	end
	for _ = 1, n or 1 do
		local job = Next(Open)
		if not job or not job.prio then return end
		-- Отказ ставит на паузу только полосу этого задания: следующий кусок — из другой.
		SendPart(job)
	end
end

---------------------------------------------------------------------------
-- Приём
---------------------------------------------------------------------------

-- Разбор целого сообщения. ctx — откуда оно пришло, если не напрямую: { via = "RM"|"RG"|"RL"|"self",
-- relay = имя реле }. sender — автор (для RM/RG — origin из конверта).
function Comm.Dispatch(msg, sender, dist, ctx)
	local kind = msg:sub(1, 2)
	-- Объявление о группе в конверте строки чата (Codec.WrapGroup) читает доска, а не чат.
	-- Конверт приходит только подписанным: без ctx он остаётся строкой, и чат его отбросит.
	if kind == "M1" and ctx then
		local group = Codec.UnwrapGroup(msg)
		if group then msg, kind, ctx.wrapped = group, "G1", true end
	end
	local h = handlers[kind]
	if not h then return end
	if PLAIN[kind] then msg = Codec.Plain(msg) end
	Comm.stats.recv = Comm.stats.recv + 1
	ns.SafeCall("recv " .. kind, h, msg, sender, dist, ctx)
end

-- Вложенное сообщение из конверта реле: только R1, M1 и G1.
function Comm.Inject(inner, origin, ctx)
	if not Codec.InnerType(inner) then return end
	Comm.Dispatch(inner, origin, "RELAY", ctx)
end

local function OnAddon(prefix, msg, dist, sender)
	local control = ns.Config.UNION_PREFIX and prefix == ns.Config.UNION_PREFIX
	if (prefix ~= ns.PREFIX and not control) or not ns.me or type(msg) ~= "string" or type(sender) ~= "string" then return end
	if dist ~= "GUILD" and dist ~= "WHISPER" then return end
	sender = U.Normal(sender)
	local realm = sender:match("%-([^%-]+)$")
	if realm and realm ~= ns.realm and U.GroupOf(realm) ~= ns.group then return end
	if ns.IsMe(sender) then return end
	if dist == "GUILD" and (not ns.Roster.Fresh() or ns.Roster.RankOf(sender) == nil) then return end
	local senderKey = U.Key(sender)
	if senderKey then unavailable[senderKey] = nil end
	if msg:byte(1) == 67 then -- "C": кусок
		local key = prefix .. ":" .. dist
		local a = assemblers[key]
		if not a then
			a = Codec.NewAssembler()
			assemblers[key] = a
		end
		msg = Codec.Feed(a, U.Key(sender), msg, ns.Now())
		if not msg then return end
	end
	local kind = msg:sub(1, 2)
	if control and kind ~= "KA" and kind ~= "UQ" and kind ~= "UO" then return end
	if (kind == "UQ" or kind == "UO") and not control then return end
	local ctx = (kind == "KA" or kind == "UQ" or kind == "UO") and { unionControl = control and true or false } or nil
	Comm.Dispatch(msg, sender, dist, ctx)
end

ns.RegisterEvent("CHAT_MSG_ADDON", OnAddon)
ns.RegisterEvent("CHAT_MSG_ADDON_LOGGED", OnAddon)

if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
	C_ChatInfo.RegisterAddonMessagePrefix(ns.PREFIX)
	if ns.Config.UNION_PREFIX then C_ChatInfo.RegisterAddonMessagePrefix(ns.Config.UNION_PREFIX) end
end

ns.On("LOGIN", function()
	ns.Every(Comm.SEND_INTERVAL, "send pump", Comm.Pump, true)
	ns.Every(30, "assembler gc", function()
		local now = ns.Now()
		for key, at in pairs(Comm.lastWhisper) do
			if now - at > WHISPER_FRESH then Comm.lastWhisper[key] = nil end
		end
		for key, untilAt in pairs(unavailable) do
			if now >= untilAt then unavailable[key] = nil end
		end
		for _, a in pairs(assemblers) do Codec.Gc(a, now) end
	end)
end)

ns.Activity.Probe(function()
	local n, L = #queue, ns.L
	if n == 0 then return nil end
	if Comm.InLockdown() then return { kind = "block", text = L.ACT_LOCKDOWN, detail = L.ACT_LOCKDOWN_TIP:format(n) } end
	-- Сервер просит подождать полосу, в которой есть сообщения; их и называет подсказка.
	local now, held = ns.Now(), 0
	for _, job in ipairs(queue) do
		if now < lanes[job.dist].waitUntil then held = held + 1 end
	end
	if held > 0 then return { kind = "wait", text = L.ACT_THROTTLED, detail = L.ACT_THROTTLED_TIP:format(held) } end
	-- Одно-два сообщения уходят за пару секунд, отдельной строки они не стоят.
	if n >= 3 then return { kind = "work", text = L.ACT_SENDING:format(n) } end
end)

ns.Status(function()
	local s = Comm.stats
	return ns.L.STATUS_COMM:format(s.sent, s.recv, #queue, s.fails, s.dropped)
end)
