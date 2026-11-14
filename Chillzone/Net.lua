-- Счётчики сети: сколько аддон-сообщений уходит и приходит по полосам GUILD и WHISPER, каких типов,
-- пик за минуту, отказы сервера, выброшенные задания и ожидание в очереди. Ведутся всегда, без записи
-- журнала, и стоят несколько сложений на кусок. Нужны, чтобы знать бюджет: сервер Forever пропускает
-- по GUILD около 10 сообщений сразу и затем 1 в секунду на отправителя и префикс, а насос Comm
-- отправляет по куску раз в SEND_INTERVAL (у реле — PARTS_RELAY кусков). Формат обмена не меняется.
--
-- Считаются куски: их считает и сервер. Тип — у целого сообщения (Net.Label): снаружи конверт реле
-- (RL, RM, RG), внутри — само сообщение без подписи S1, у конверта строки чата (M1~A~гильдия~G1~...)
-- — вложенный тип. Пик — скользящее окно из шести долей по 10 с; в пике запоминается, из каких типов
-- он сложился.
--
-- Принятое по GUILD слышат все согильдийцы, поэтому журнал любого участника показывает, сколько шлёт
-- каждый отправитель гильдии, в том числе репортёр. Куски принятых считаются по приходу, а типы — по
-- собранным сообщениям, поэтому сумма по типам бывает чуть меньше.
--
-- Сессия лежит в сохранениях (ns.db.net) и переживает /reload: вход того же персонажа той же версии
-- в пределах CONTINUE_GAP после прошлой отметки её продолжает. Прошлые сессии хранятся урезанными.
local ADDON, ns = ...
local L, U = ns.L, ns.Util

local Net = {
	SCHEMA = 1,
	BUCKET = 10,        -- секунд в доле окна
	BUCKETS = 6,        -- долей в окне: пик — за последние 50-60 с
	CONTINUE_GAP = 300, -- вход позже этого после прошлой отметки начинает новую сессию
	HISTORY = 10,       -- сколько прошлых сессий хранить
	TOP_PEAK = 6,       -- сколько типов запоминать в пике
	REPORT_KINDS = 16,  -- сколько типов показывать в отчёте
	WAIT_SHOWN = 5,     -- ожидание типа в очереди показывается с этого числа секунд
	REPORT_SENDERS = 8, -- сколько отправителей GUILD показывать в отчёте
	PAST_SENDERS = 3,   -- и у прошлой сессии
	KEEP_KINDS = 12,    -- сколько типов на полосу оставлять в прошлой сессии
	KEEP_SENDERS = 10,  -- сколько отправителей оставлять в прошлой сессии
}
ns.Net = Net

local floor, max = math.floor, math.max
local DISTS = { "GUILD", "WHISPER" }

---------------------------------------------------------------------------
-- Тип сообщения
---------------------------------------------------------------------------
local ENVELOPE_FIELDS = { RL = 2, RM = 3, RG = 3 } -- полей до вложенного сообщения, считая тип

-- Позиция сразу после n-го знака "~", начиная с p; nil — столько полей нет.
local function After(msg, p, n)
	for _ = 1, n do
		local at = msg:find("~", p, true)
		if not at then return nil end
		p = at + 1
	end
	return p
end

local function Kind(msg, p)
	local kind = msg:sub(p, p + 1)
	return kind:find("^%u[%u%d]$") and kind or nil
end

-- Метка для счётчиков: "H1", "M1", "RG/M1", "RL/R1", "RG/G1". Строк не копирует.
function Net.Label(msg)
	if type(msg) ~= "string" then return "?" end
	local kind = Kind(msg, 1)
	if not kind then return "?" end
	local outer, p = "", 1
	local fields = ENVELOPE_FIELDS[kind]
	if fields then
		p = After(msg, 1, fields)
		kind = p and Kind(msg, p)
		if not kind then return msg:sub(1, 2) end
		outer = msg:sub(1, 2) .. "/"
	end
	if kind == "S1" then
		local q = After(msg, p, 5)
		local inner = q and Kind(msg, q)
		if inner then p, kind = q, inner end
	end
	if kind == "M1" then
		local q = After(msg, p, 3)
		local inner = q and Kind(msg, q)
		if inner and msg:sub(q + 2, q + 2) == "~" then kind = inner end
	end
	return outer .. kind
end

---------------------------------------------------------------------------
-- Скользящее окно: шесть долей по BUCKET секунд. Окна не сохраняются, пики — да.
---------------------------------------------------------------------------
local function NewRate()
	local ring = {}
	for i = 1, Net.BUCKETS do ring[i] = 0 end
	return { at = 0, sum = 0, ring = ring }
end

local function Advance(r, idx)
	local steps = idx - r.at
	if steps == 0 then return end
	local ring, n = r.ring, Net.BUCKETS
	if steps < 0 or steps >= n then
		for i = 1, n do ring[i] = 0 end
		r.sum = 0
	else
		for k = r.at + 1, idx do
			local slot = k % n + 1
			r.sum = r.sum - ring[slot]
			ring[slot] = 0
		end
	end
	r.at = idx
end

-- Добавить n и вернуть сумму окна.
local function Add(r, idx, n)
	Advance(r, idx)
	local slot = idx % Net.BUCKETS + 1
	r.ring[slot] = r.ring[slot] + n
	r.sum = r.sum + n
	return r.sum
end

---------------------------------------------------------------------------
-- Сессия
---------------------------------------------------------------------------
local function NewLane(tx)
	local lane = { n = 0, m = 0, peak = 0, kinds = {} }
	if tx then
		lane.refused, lane.dropped, lane.skipped, lane.pause = {}, {}, 0, 0
		lane.waitN, lane.waitSum, lane.waitMax, lane.queueMax = 0, 0, 0, 0
		lane.ticks, lane.full = 0, 0
	end
	return lane
end

local function NewSession()
	local now = ns.ServerTime()
	local s = {
		schema = Net.SCHEMA, from = now, to = now, version = ns.VERSION, who = ns.me,
		reporterMin = 0, relayMin = 0, tx = {}, rx = {}, senders = {},
	}
	for _, dist in ipairs(DISTS) do s.tx[dist], s.rx[dist] = NewLane(true), NewLane(false) end
	return s
end

local session = NewSession()
-- Окна текущей сессии: live[dir][dist] = { total = окно, kinds = { [метка] = окно } };
-- liveSenders[ключ] = окно.
local live, liveSenders

local function ResetLive()
	live, liveSenders = { tx = {}, rx = {} }, {}
end
ResetLive()

function Net.Session() return session end

local function Lane(dir, dist)
	local lanes = session[dir]
	local lane = lanes[dist]
	if not lane then
		lane = NewLane(dir == "tx")
		lanes[dist] = lane
	end
	return lane
end

local function Live(dir, dist)
	local byDist = live[dir]
	local l = byDist[dist]
	if not l then
		l = { total = NewRate(), kinds = {} }
		byDist[dist] = l
	end
	return l
end

local function Bucket()
	return floor(ns.Now() / Net.BUCKET)
end

-- Из каких типов сложилось окно сейчас: самые большие TOP_PEAK.
local function Composition(l, idx)
	local list = {}
	for label, r in pairs(l.kinds) do
		Advance(r, idx)
		if r.sum > 0 then list[#list + 1] = { label, r.sum } end
	end
	table.sort(list, function(a, b)
		if a[2] ~= b[2] then return a[2] > b[2] end
		return a[1] < b[1]
	end)
	for i = #list, Net.TOP_PEAK + 1, -1 do list[i] = nil end
	return list
end

local function KindStat(lane, label)
	local k = lane.kinds[label]
	if not k then
		k = { n = 0, m = 0 }
		lane.kinds[label] = k
	end
	return k
end

-- Куски по типу: в окно типа и в счётчик типа.
local function CountKind(dir, dist, label, chunks, messages, idx)
	local k = KindStat(Lane(dir, dist), label)
	k.n, k.m = k.n + chunks, k.m + (messages or 0)
	local l = Live(dir, dist)
	local r = l.kinds[label]
	if not r then
		r = NewRate()
		l.kinds[label] = r
	end
	Add(r, idx, chunks)
end

-- Куски полосы: итог, окно и пик с составом.
local function CountTotal(dir, dist, chunks, idx)
	local lane = Lane(dir, dist)
	lane.n = lane.n + chunks
	local l = Live(dir, dist)
	local sum = Add(l.total, idx, chunks)
	if sum > lane.peak then
		lane.peak, lane.peakAt = sum, ns.ServerTime()
		lane.top = Composition(l, idx)
	end
end

---------------------------------------------------------------------------
-- Вызовы из Comm
---------------------------------------------------------------------------
-- Игра приняла кусок к отправке.
function Net.Sent(dist, label)
	local idx = Bucket()
	CountKind("tx", dist, label or "?", 1, 0, idx)
	CountTotal("tx", dist, 1, idx)
end

-- Задание отправлено целиком (ok), снято как ненужное (quiet) или выброшено (why).
function Net.Finished(dist, label, ok, why, quiet)
	local lane = Lane("tx", dist)
	if ok then
		lane.m = lane.m + 1
		local k = KindStat(lane, label or "?")
		k.m = k.m + 1
	elseif quiet then
		lane.skipped = lane.skipped + 1
	else
		why = tostring(why or "?")
		lane.dropped[why] = (lane.dropped[why] or 0) + 1
		local k = KindStat(lane, label or "?")
		k.dropped = (k.dropped or 0) + 1
	end
end

-- Игра отказала: код ответа или "error" (ошибка Lua в вызове).
function Net.Refused(dist, code)
	local lane = Lane("tx", dist)
	code = tostring(code)
	lane.refused[code] = (lane.refused[code] or 0) + 1
end

-- Полоса встала на паузу ещё на seconds после отказа.
function Net.Paused(dist, seconds)
	if seconds <= 0 then return end
	local lane = Lane("tx", dist)
	lane.pause = lane.pause + seconds
end

-- Первый кусок задания ушёл через wait секунд после постановки в очередь.
function Net.Waited(dist, label, wait)
	local lane = Lane("tx", dist)
	wait = max(0, wait)
	lane.waitN, lane.waitSum = lane.waitN + 1, lane.waitSum + wait
	if wait > lane.waitMax then lane.waitMax = wait end
	local k = KindStat(lane, label or "?")
	if wait > (k.waitMax or 0) then k.waitMax = wait end
end

-- В полосе стало size заданий.
function Net.Queued(dist, size)
	local lane = Lane("tx", dist)
	if size > lane.queueMax then lane.queueMax = size end
end

-- Тик насоса: полоса отправила sent кусков; full — вся квота ушла, а задания в полосе остались.
function Net.Tick(dist, sent, full)
	if sent <= 0 then return end
	local lane = Lane("tx", dist)
	lane.ticks = lane.ticks + 1
	if full then lane.full = lane.full + 1 end
end

-- Пришёл кусок (или целое короткое сообщение) от sender, key — его ключ.
function Net.Heard(dist, key, sender)
	local idx = Bucket()
	CountTotal("rx", dist, 1, idx)
	if dist ~= "GUILD" or not key then return end
	local st = session.senders[key]
	if not st then
		st = { name = sender, n = 0, peak = 0 }
		session.senders[key] = st
	end
	st.n = st.n + 1
	local r = liveSenders[key]
	if not r then
		r = NewRate()
		liveSenders[key] = r
	end
	local sum = Add(r, idx, 1)
	if sum > st.peak then st.peak, st.peakAt = sum, ns.ServerTime() end
end

-- Собрано целое сообщение из chunks кусков.
function Net.Assembled(dist, msg, chunks)
	local lane = Lane("rx", dist)
	lane.m = lane.m + 1
	CountKind("rx", dist, Net.Label(msg), chunks, 1, Bucket())
end

---------------------------------------------------------------------------
-- Хранение
---------------------------------------------------------------------------
local function Valid(s)
	return type(s) == "table" and s.schema == Net.SCHEMA and type(s.tx) == "table" and type(s.rx) == "table"
		and type(s.senders) == "table" and type(s.from) == "number"
end

local function Ranked(map, field)
	local list = {}
	for key, v in pairs(map) do list[#list + 1] = { key = key, v = v } end
	table.sort(list, function(a, b)
		local x, y = a.v[field] or 0, b.v[field] or 0
		if x ~= y then return x > y end
		return tostring(a.key) < tostring(b.key)
	end)
	return list
end

local function Keep(map, field, n)
	local out = {}
	for i, e in ipairs(Ranked(map, field)) do
		if i > n then break end
		out[e.key] = e.v
	end
	return out
end

-- Прошлая сессия урезается: в отчёт идут итоги, пики и первые отправители.
local function Archive(store, s)
	for _, dir in ipairs({ "tx", "rx" }) do
		for _, lane in pairs(s[dir]) do lane.kinds = Keep(lane.kinds, "n", Net.KEEP_KINDS) end
	end
	s.senders = Keep(s.senders, "peak", Net.KEEP_SENDERS)
	table.insert(store.history, 1, s)
	for i = #store.history, Net.HISTORY + 1, -1 do store.history[i] = nil end
end

local function Store()
	local db = ns.db
	if not db then return nil end
	if type(db.net) ~= "table" then db.net = {} end
	local store = db.net
	if type(store.history) ~= "table" then store.history = {} end
	return store
end

local function Begin()
	local store = Store()
	if not store then return end
	local prev, now = store.current, ns.ServerTime()
	if Valid(prev) and prev ~= session and prev.who == ns.me and prev.version == ns.VERSION
		and now - (prev.to or prev.from) <= Net.CONTINUE_GAP then
		-- /reload или короткий перезаход: та же сессия, окна начинаются заново.
		session = prev
	else
		if Valid(prev) and prev ~= session then Archive(store, prev) end
		session.who, session.from, session.to = ns.me, now, now
	end
	session.to = now
	store.current = session
	ResetLive()
end

-- Новая сессия с нуля, прошлые стираются (кнопка «Очистить» в журнале).
function Net.Clear()
	session = NewSession()
	ResetLive()
	local store = Store()
	if store then store.current, store.history = session, {} end
end

local function Minute()
	session.to = ns.ServerTime()
	if ns.Census and ns.Census.IsReporter() then session.reporterMin = session.reporterMin + 1 end
	if ns.Relay and ns.Relay.IAmRelay() then session.relayMin = session.relayMin + 1 end
end

ns.On("LOGIN", function()
	Begin()
	-- Без случайного сдвига: раз в минуту одно сложение, разносить по кадрам нечего.
	ns.Every(60, "net minute", Minute, true)
end)

ns.RegisterEvent("PLAYER_LOGOUT", function()
	session.to = ns.ServerTime()
end)

---------------------------------------------------------------------------
-- Отчёт
---------------------------------------------------------------------------
local function Clock(t, fmt)
	return t and date and date(fmt or "%H:%M", t) or L.NET_NONE
end

local function Minutes(s)
	local to = s == session and ns.ServerTime() or (s.to or s.from)
	return max(0, floor((to - s.from) / 60))
end

local function Sum(map)
	local n = 0
	for _, v in pairs(map or {}) do n = n + v end
	return n
end

local function Pairs(map)
	local list = {}
	for key, v in pairs(map or {}) do list[#list + 1] = { key = key, v = v } end
	table.sort(list, function(a, b)
		if a.v ~= b.v then return a.v > b.v end
		return a.key < b.key
	end)
	local out = {}
	for i, e in ipairs(list) do out[i] = ("%s=%d"):format(e.key, e.v) end
	return #out > 0 and table.concat(out, ", ") or L.NET_NONE
end

local function Top(top)
	if not top or #top == 0 then return "" end
	local out = {}
	for i, e in ipairs(top) do out[i] = ("%s %d"):format(e[1], e[2]) end
	return " (" .. table.concat(out, ", ") .. ")"
end

local function LaneLine(lines, dist, dir, lane, minutes)
	lines[#lines + 1] = L.NET_LANE:format(dist, dir == "tx" and L.NET_SENT or L.NET_RECEIVED, lane.n, lane.m,
		lane.n / max(1, minutes), lane.peak, Clock(lane.peakAt), Top(lane.top))
end

local function Kinds(lane, tx)
	local out = {}
	for i, e in ipairs(Ranked(lane.kinds, "n")) do
		if i > Net.REPORT_KINDS then break end
		local k = e.v
		local item, extra = ("%s %d/%d"):format(e.key, k.n, k.m), {}
		if tx and (k.dropped or 0) > 0 then extra[#extra + 1] = L.NET_KIND_DROPPED:format(k.dropped) end
		if tx and (k.waitMax or 0) >= Net.WAIT_SHOWN then extra[#extra + 1] = L.NET_KIND_WAIT:format(floor(k.waitMax)) end
		if #extra > 0 then item = item .. " (" .. table.concat(extra, ", ") .. ")" end
		out[#out + 1] = item
	end
	return #out > 0 and table.concat(out, ", ") or L.NET_NONE
end

local function Senders(s, n)
	local out = {}
	for i, e in ipairs(Ranked(s.senders, "peak")) do
		if i > n then break end
		out[#out + 1] = ("%s %d/%d"):format(U.Display(e.v.name or e.key), e.v.peak, e.v.n)
	end
	return #out > 0 and table.concat(out, ", ") or L.NET_NONE
end

local function SessionLines(lines, s, detailed)
	local minutes = Minutes(s)
	lines[#lines + 1] = L.NET_SESSION:format(s == session and L.NET_CURRENT or L.NET_PAST, U.Display(s.who),
		Clock(s.from, "%m-%d %H:%M"), Clock(s == session and ns.ServerTime() or s.to), minutes, s.version or "?",
		s.reporterMin or 0, s.relayMin or 0)
	for _, dist in ipairs(DISTS) do
		for _, dir in ipairs({ "tx", "rx" }) do
			local lane = s[dir][dist]
			if lane then
				LaneLine(lines, dist, dir, lane, minutes)
				if dir == "tx" and detailed then
					local interval = ns.Comm.SEND_INTERVAL
					lines[#lines + 1] = L.NET_QUEUE:format(lane.waitN > 0 and lane.waitSum / lane.waitN or 0,
						floor(lane.waitMax), lane.queueMax, floor(lane.ticks * interval + 0.5), floor(lane.full * interval + 0.5))
					lines[#lines + 1] = L.NET_LOSS:format(Pairs(lane.refused), floor(lane.pause), Pairs(lane.dropped), lane.skipped)
				elseif dir == "tx" then
					lines[#lines + 1] = L.NET_LOSS_SHORT:format(Sum(lane.refused), Sum(lane.dropped), floor(lane.waitMax))
				end
				if detailed then lines[#lines + 1] = L.NET_KINDS:format(Kinds(lane, dir == "tx")) end
			end
		end
	end
	lines[#lines + 1] = L.NET_SENDERS:format(Senders(s, detailed and Net.REPORT_SENDERS or Net.PAST_SENDERS))
end

-- Раздел «Сеть» для отчёта журнала.
function Net.Report()
	local interval = ns.Comm.SEND_INTERVAL
	local quota = floor(60 / interval + 0.5)
	local lines = { L.NET_TITLE:format(quota, quota * ns.Comm.PARTS_RELAY) }
	SessionLines(lines, session, true)
	local store = ns.db and type(ns.db.net) == "table" and ns.db.net
	local history = store and type(store.history) == "table" and store.history or {}
	local any = false
	for _, s in ipairs(history) do
		if Valid(s) then
			if not any then lines[#lines + 1] = L.NET_HISTORY; any = true end
			SessionLines(lines, s, false)
		end
	end
	return table.concat(lines, "\n")
end
