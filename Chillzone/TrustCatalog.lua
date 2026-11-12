-- Chillzone: каталог доверия своей гильдии по GUILD — корни (KT), владелец объединения (UO),
-- решения главы (KA), допуски издателей (KD) и подписанные главой отзывы (KV). Что входит в
-- каталог, решает Security.Catalog; здесь — когда и кто его рассылает.
--
-- Раньше каждый офицер на каждый вход согильдийца (UQ, K1) через 5 секунд слал гильдии весь
-- каталог: при двадцати офицерах — десятки одинаковых копий, а сервер Forever пропускает по
-- GUILD около одного куска в секунду. Теперь запись уходит в гильдию один раз на всех:
--
-- * Разослано. Запись — точные байты сообщения вместе с префиксом. Она разослана, если такое
--   же сообщение целиком пришло по GUILD от офицера по свежему ростеру (как KT в Security.lua)
--   или я сам его отправил (Comm.Watch: свои сообщения разбор отбрасывает). Время рассылки —
--   начало передачи: вошедший посреди многокускового сообщения его не соберёт. Копия от
--   рядового не в счёт: иначе он заглушал бы рассылку тем, что получатели у него не примут.
--   UO главы несёт его сертификат (доказательство) и покрывает тот же UO без него.
-- * Запрос. UQ и первый K1 соседа просят весь каталог, остальные K1 и плановое объявление
--   офицера (раз в 30 с) — только корни. Запрос запоминается временем прихода. Запись нужна,
--   пока её не разослали после последнего запроса: кто пришёл после рассылки, её не слышал.
-- * Окно. Те же байты — не чаще TRUST_SHARE_WINDOW. Запросы внутри окна ждут его конца, и
--   одна копия обслуживает их все. Корень по одним плановым объявлениям — не чаще
--   TRUST_SHARE_ROOTS: иначе его свежая копия почти всегда держала бы окно для вошедших.
-- * Кто шлёт. У каждой записи свой порядок офицеров на связи (хэш записи и имени, у всех
--   клиентов одинаковый). Первый шлёт через TRUST_SHARE_DELAY..+JITTER секунд, каждый
--   следующий — ещё на TRUST_SHARE_STEP позже, если копии так и не было. Офицеры делят
--   каталог, а не повторяют его, а молчащего (блокировка, старая версия) заменяет следующий.
--   Владелец объединения всегда первый для UO: его копия с доказательством покрывает
--   остальные. Офицер, который сам только что просил каталог (вошёл), в порядок не входит:
--   у него ещё нет записей, и остальные ждали бы его зря.
-- * Порядок. Запись уходит, когда после первого необслуженного запроса разослано то, без чего
--   получатель её не примет (Deps): решение главы — после владельца (иначе ждёт его лишь 30
--   секунд), допуск и отзыв гильдии — после её корня (своей — KT, гильдии объединения — решение
--   главы о ней). Свой офицерский порядок у записи начинается от конца этой рассылки. Копия
--   обслуживает только запросы, после которых раньше неё целиком пришли зависимости (Served):
--   кто спросил между ними или получил допуск раньше корня (прежние версии шлют допуски перед
--   решениями), получит запись следующей копией, а не останется без неё.
-- * Темп. Своих записей каталога в очереди — одна, и не больше TRUST_SHARE_PER_MIN одного
--   вида за минуту: получатель проверяет AUTH_NEW_PER_MIN документов от отправителя, лишние
--   выбрасывает. Первой идёт запись, чей срок наступил раньше: у кого копия старее, тот и
--   впереди, поэтому один офицер с большим каталогом обходит его по кругу, а не с начала.
-- * Перед отправкой запись проверяется ещё раз (Comm opts.skip): пока задание ждало в
--   очереди, её мог разослать другой. Снятое так задание не считается выброшенным. Начатое
--   сообщение досылается.
-- * Срочно (TC.Urgent). Репортёр отвечает на Q1 отчётами, и каталог должен прийти раньше них:
--   записи, не разосланные после последнего запроса каталога спросившим (UQ при входе), уходят
--   сразу и по уровням, без окна и очереди офицеров. Ответ на Q1 — не чаще Q1_GAP. Остальные
--   офицеры, услышав копию от репортёра вскоре после Q1, своё по окну не начинают, пока он шлёт.
-- * Сразу (TC.Direct): новые и изменённые записи (другие байты) и явные действия. Снимается
--   только запись, разосланная меньше окна назад и после всех запросов: её гильдия только что
--   слышала. Задания, ждущие её через before, снятие не держит.
local ADDON, ns = ...
local C = ns.Config

local TC = { stats = { queued = 0, skipped = 0 } }
ns.TrustCatalog = TC

local KINDS = { KT = 1, UO = 1, KA = 2, KD = 3, KV = 3 } -- вид → уровень: порядок в срочной пачке
local HISTORY = 6 -- копий одной записи помнится
local KEEP = 15 * 60 -- столько помнятся запросы и копии
local copies = {} -- [id] = { { at, done, seq, served }, ... } по возрастанию at: рассылки по GUILD
local asks = { all = {}, roots = {} } -- времена запросов по порядку
local bootAt, urgentSince = -1e9, -1e9 -- последний запрос входа; срочно — что не разослано после
local lastAsk = {} -- [Key] = когда согильдиец последний раз попросил весь каталог (UQ при входе)
local mine = {} -- [вид] = { когда ушли мои сообщения этого вида по GUILD }
local queued, queuedCount = {}, 0 -- [slot] = запись: мои задания каталога в очереди
local timerAt
-- Репортёр отвечает на Q1 каталогом сразу (TC.Urgent), и его копии идут подряд. Пока он шлёт
-- (его копия после Q1 гильдии меньше PUSH_AFTER_Q1 назад), своё по окну не начинать: иначе
-- офицер и репортёр начали бы ту же запись в один такт. Через PUSH_QUIET тишины — как обычно.
local PUSH_AFTER_Q1, PUSH_QUIET = 10, 4
local q1At, pushUntil = -1e9, -1e9
local scores, scoreCount = {}, 0
local ranks, rankSig = {}, nil
local catalog, catalogAt = nil, -1e9

local function Id(prefix, wire) return prefix .. "\n" .. wire end

-- Запись каталога: kind — вид (KT, UO, KA, KD, KV), slot — что это (у новой версии тот же slot),
-- wire — сообщение, prefix — префикс аддон-сообщения, key — ключ очереди для TC.Direct.
-- base — тот же UO без доказательства: его копия открывает следующий уровень и для главы.
-- guild — ключ гильдии записи из slot: "KT:<гильдия>", "KA:<гильдия>", "KD:<гильдия>:<имя>".
local function Bare(kind, wire)
	return kind == "UO" and wire:match("^(UO~[%w_-]+)~[%w_-]+$") or nil
end
function TC.Record(kind, slot, wire, prefix, key)
	local bare = Bare(kind, wire)
	local guild = (kind == "KD" or kind == "KV") and slot:match("^%u%u:(.+):[^:]+$") or slot:match("^%u%u:(.+)$")
	return { kind = kind, slot = slot, wire = wire, prefix = prefix, key = key, guild = guild,
		tier = KINDS[kind], id = Id(prefix, wire), base = bare and Id(prefix, bare) }
end

-- seq — порядок, в котором копии пришли целиком: получатель разбирает сообщение, когда оно
-- собрано, поэтому корень, собранный раньше допуска, уже записан, даже если оба в одну секунду.
local seq = 0
local function Note(id, at, done)
	local list = copies[id]
	if not list then list = {}; copies[id] = list end
	for _, c in ipairs(list) do
		if c.at == at then
			if done > c.done then c.done = done end
			return c
		end
	end
	local pos = #list + 1
	while pos > 1 and list[pos - 1].at > at do pos = pos - 1 end
	seq = seq + 1
	local c = { at = at, done = done, seq = seq }
	table.insert(list, pos, c)
	-- Самая поздняя из забытых копий остаётся опорой: по ней видно, что корень был разослан
	-- до давней копии допуска (LastBefore).
	while #list > HISTORY do list.floor = table.remove(list, 1) end
	return c
end

local function Latest(id)
	local list = copies[id]
	return list and list[#list]
end

-- Последняя копия id, пришедшая целиком раньше копии c, или nil.
local function LastBefore(id, c)
	local list = copies[id]
	if not list then return nil end
	local best = list.floor and list.floor.seq < c.seq and list.floor or nil
	for _, d in ipairs(list) do
		if d.seq < c.seq and (not best or d.at > best.at) then best = d end
	end
	return best
end

-- Первый запрос в list позже t или nil.
local function After(list, t)
	local lo, hi = 1, #list
	if hi == 0 or list[hi] <= t then return nil end
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if list[mid] > t then hi = mid else lo = mid + 1 end
	end
	return list[lo]
end

-- Записи каталога по slot и по id.
local function Index(list)
	if not list.bySlot then
		local bySlot, byId = {}, {}
		for _, x in ipairs(list) do bySlot[x.slot], byId[x.id] = x, x end
		list.bySlot, list.byId = bySlot, byId
	end
	return list
end

-- Записи каталога list, без которых получатель не примет r: решение главы — без владельца
-- объединения (ждёт его лишь 30 секунд), допуск и отзыв гильдии — без её корня. Корень своей
-- гильдии приходит её KT, корень гильдии объединения закрепляет решение главы о ней (KA),
-- корень главной — её KT. Прежние версии слали допуски раньше решений: их копия допуска
-- своей гильдии после корня засчитывается, а чужой до решения — нет.
local function Deps(list, r)
	local cache = list.deps
	if not cache then cache = {}; list.deps = cache end
	local deps = cache[r]
	if deps then return deps end
	local by = Index(list).bySlot
	deps = {}
	if r.kind == "KA" then
		deps[1] = by.UO
	elseif (r.kind == "KD" or r.kind == "KV") and r.guild then
		if r.guild == ns.Util.GuildKey(ns.MyGuild()) then
			deps[1] = by["KT:" .. r.guild]
		else
			deps[1] = by["KA:" .. r.guild] or by["KT:" .. r.guild]
		end
	end
	cache[r] = deps
	return deps
end

-- До какого момента запросы обслужены копией c записи r: копия начата позже запроса, а раньше
-- неё после того же запроса целиком пришло (и само обслужило его) всё, без чего её не примут.
-- Иначе вошедший получил бы допуск раньше корня, отбросил бы его, а копия считалась бы
-- доставленной. Ответ запоминается в копии: что пришло раньше неё, уже не меняется, а
-- давние копии корня забываются (HISTORY). Поэтому он считается и сразу, как копия пришла.
local function Served(list, r, c)
	if c.served then return c.served end
	local served = c.at
	for _, low in ipairs(Deps(list, r)) do
		local d = LastBefore(low.id, c)
		local b = low.base and LastBefore(low.base, c)
		if b and (not d or b.at > d.at) then d = b end
		if not d then
			served = -1e9
			break
		end
		local t = Served(list, low, d)
		if t < served then served = t end
	end
	if list[1] then c.served = served end -- без каталога (не офицер) зависимостей не видно
	return served
end

-- Первая копия записи r (или её base), которая обслужила запрос e, или nil.
local function FirstServing(list, r, e)
	local best
	for pass = 1, 2 do
		local id = pass == 1 and r.id or r.base
		for _, c in ipairs(id and copies[id] or {}) do
			if c.at > e and (not best or c.seq < best.seq) and Served(list, r, c) > e then
				best = c
				break
			end
		end
	end
	return best
end

-- Запрос, которого запись r ещё не обслужила, с какого момента окно позволяет её повторить
-- (от начала последней копии) и до какого момента запросы обслужены (served); e = nil — запись
-- никому не нужна. Плановое объявление корней (asks.roots) — не чаще TRUST_SHARE_ROOTS:
-- иначе свежая копия корня почти всегда держала бы окно и задерживала вошедших.
local function Pending(list, r)
	local last = Latest(r.id)
	local at = last and last.at or -1e9
	local served = last and Served(list, r, last) or -1e9
	local e = After(asks.all, served)
	local ready = e and math.max(e, at + C.TRUST_SHARE_WINDOW)
	if r.kind == "KT" then
		local root = After(asks.roots, served)
		local soon = root and math.max(root, at + C.TRUST_SHARE_ROOTS)
		if soon and (not ready or soon < ready) then e, ready = root, soon end
	end
	return e, ready, served
end

local function Push(list, t)
	local n = #list
	-- Запросы почти одновременно (UQ и K1 одного входа) — один запрос, по последнему.
	if n > 0 and t - list[n] < 0.5 then list[n] = math.max(list[n], t) else list[n + 1] = t end
	while list[2] and t - list[1] > KEEP do table.remove(list, 1) end
end

-- Детерминированный хэш строки в [0, P): у всех клиентов одинаковый. Сложение и умножение
-- без битовых операций (их нет в Lua 5.1), возведение в квадрат перемешивает биты.
local P = 67108859
local function Hash(s)
	local h = 5381
	for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
	h = h % P
	for _ = 1, 3 do h = (h * h + 7919) % P end
	return h
end

local function Score(key, slot)
	local k = slot .. "|" .. key
	local s = scores[k]
	if not s then
		if scoreCount >= 4096 then scores, scoreCount = {}, 0 end
		s = Hash(k)
		scores[k], scoreCount = s, scoreCount + 1
	end
	return s
end

-- Моё место в порядке офицеров для записи slot (0 — первый). officers — ключи офицеров на
-- связи вместе со мной; порядок у всех одинаковый при одинаковом списке. lead — кто всегда
-- первый: владелец объединения для UO (его копия с доказательством покрывает остальные).
local function Rank(slot, officers, sig, lead)
	if sig ~= rankSig then ranks, rankSig = {}, sig end
	local rank = ranks[slot]
	if rank then return rank end
	local my = Score(ns.myKey, slot)
	rank = 0
	if lead ~= ns.myKey then
		for _, key in ipairs(officers) do
			if key ~= ns.myKey then
				local s = Score(key, slot)
				if key == lead or s > my or (s == my and key < ns.myKey) then rank = rank + 1 end
			end
		end
	end
	ranks[slot] = rank
	return rank
end

-- Офицеры на связи по порядку, подпись списка для кэша мест и владелец объединения, если он среди них.
-- Кто сам недавно просил каталог (только вошёл), в очередь не встаёт: ему ещё нечего слать.
local function Officers()
	local list, now = {}, ns.Now()
	for _, key in ipairs(ns.Security.ShareOfficers()) do
		if key == ns.myKey or not lastAsk[key] or now - lastAsk[key] >= 2 * C.TRUST_SHARE_WINDOW then
			list[#list + 1] = key
		end
	end
	table.sort(list)
	local owner = ns.UnionAuthority.Current()
	local lead = owner and ns.Util.Key(owner.name)
	local present = false
	for _, key in ipairs(list) do
		if key == lead then present = true end
	end
	lead = present and lead or nil
	return list, table.concat(list, ",") .. "|" .. tostring(lead), lead
end

-- Своя для каждого офицера и записи пауза после запроса e.
local function Jitter(r, e)
	return C.TRUST_SHARE_DELAY + Hash(ns.myKey .. "|" .. r.slot .. "|" .. ("%.1f"):format(e)) / P * C.TRUST_SHARE_JITTER
end

-- Когда запись r можно слать для запроса e: всё, без чего получатель её не примет (Deps),
-- разослано после e — время конца последней такой рассылки, или nil — ещё нет.
local function Gate(list, r, e)
	local open = -1e9
	for _, low in ipairs(Deps(list, r)) do
		local c = FirstServing(list, low, e)
		if not c then return nil end
		if c.done > open then open = c.done end
	end
	return open
end

-- С какого момента можно отправить ещё одну запись вида kind (now — уже можно).
local function Room(kind, now)
	local list = mine[kind]
	local n = 0
	if list then
		while list[1] and now - list[1] >= 60 do table.remove(list, 1) end
		n = #list
	end
	for _, r in pairs(queued) do if r.kind == kind then n = n + 1 end end
	if n < C.TRUST_SHARE_PER_MIN then return now end
	return list and list[1] and list[1] + 60 or now + 60
end

local function Catalog(now)
	if not catalog or now - catalogAt >= 2 then
		catalog, catalogAt = ns.Security.Catalog(), now
	end
	return catalog
end

-- served — до какого момента запросы обслужены (Pending).
local function Priority(served)
	if bootAt > served then return ns.Comm.PRIO_BOOTSTRAP end
	if urgentSince > served or After(asks.all, served) then return true end
	return nil -- только плановое объявление корней: не обгоняет чат
end

-- Запись всё ещё нужно отправить: её не разослали после запроса, окно прошло (или срочно).
local function Wanted(r)
	if not ns.Security.CanAdmin() then return false end
	local e, ready, served = Pending(Catalog(ns.Now()), r)
	if urgentSince > served then return e ~= nil end
	return e ~= nil and ns.Now() >= ready and ns.Now() >= pushUntil
end

local Schedule

local function Queue(r, prio)
	queued[r.slot], queuedCount = r, queuedCount + 1
	local function Done(ok, why)
		if queued[r.slot] == r then queued[r.slot], queuedCount = nil, queuedCount - 1 end
		if why == "skipped" then TC.stats.skipped = TC.stats.skipped + 1 end
		-- Выброшенное (очередь, отказ сервера) — не сразу заново: иначе по кругу.
		Schedule(ns.Now() + ((ok or why == "skipped") and 0 or 5))
	end
	TC.stats.queued = TC.stats.queued + 1
	if not ns.Comm.Send("GUILD", r.wire, { prefix = r.prefix, prio = prio, key = "trust:" .. r.slot,
		skip = function() return not Wanted(r) end, done = Done }) and queued[r.slot] == r then
		queued[r.slot], queuedCount = nil, queuedCount - 1
		Schedule(ns.Now() + 5)
	end
end

-- Срочные записи: все сразу и по уровням, раньше отчётов, которые репортёр ставит следом.
local function QueueUrgent(list, now)
	local urgent = {}
	-- Один приоритет на всю пачку: иначе запись входа обогнала бы корень.
	local prio = true
	for _, r in ipairs(list) do
		local e, _, served = Pending(list, r)
		if not queued[r.slot] and urgentSince > served and e and Room(r.kind, now) <= now then
			urgent[#urgent + 1] = r
			if Priority(served) == ns.Comm.PRIO_BOOTSTRAP then prio = ns.Comm.PRIO_BOOTSTRAP end
		end
	end
	table.sort(urgent, function(a, b)
		if a.tier ~= b.tier then return a.tier < b.tier end
		return a.slot < b.slot
	end)
	for _, r in ipairs(urgent) do
		if Room(r.kind, now) <= now then Queue(r, prio) end
	end
end

local function Pass(urgent)
	timerAt = nil
	if not ns.Security.CanAdmin() or not ns.myKey then return end
	local now = ns.Now()
	local list = Catalog(now)
	if urgent then QueueUrgent(list, now) end
	if queuedCount > 0 then return end -- Done запустит следующий проход
	local officers, sig, lead
	local best, bestBase, bestServed, wake
	for _, r in ipairs(list) do
		local e, ready, served = Pending(list, r)
		-- Зависимости — после первого необслуженного запроса. Кто спросил позже, чем они
		-- ушли, этой копией не обслужен (Served) и получит запись следующей.
		local gate = e and Gate(list, r, e)
		if gate then
			local base
			if urgentSince > served then
				base = gate
			else
				-- Пауза — от запроса (или конца окна), а после зависимостей — секунда: их
				-- рассылка уже развела офицеров.
				if not officers then officers, sig, lead = Officers() end
				base = math.max(ready + Jitter(r, e), gate + C.TRUST_SHARE_DELAY, pushUntil)
					+ Rank(r.slot, officers, sig, r.kind == "UO" and lead or nil) * C.TRUST_SHARE_STEP
			end
			local due = math.max(base, Room(r.kind, now))
			if due <= now then
				-- Из готовых первой — запись с самым ранним своим сроком (чья копия старее), а не
				-- первая по имени: иначе предел в минуту выпускал бы всё время одни и те же.
				if not best or base < bestBase or (base == bestBase and r.slot < best.slot) then
					best, bestBase, bestServed = r, base, served
				end
			elseif not wake or due < wake then
				wake = due
			end
		end
	end
	if best then
		Queue(best, Priority(bestServed))
	elseif wake then
		Schedule(wake)
	end
end

Schedule = function(at)
	local now = ns.Now()
	if at < now then at = now end
	if timerAt and timerAt <= at then return end
	timerAt = at
	ns.After(at - now, "trust catalog", function()
		if timerAt == at then Pass() end
	end)
end

-- Согильдиец key попросил каталог: весь (UQ, первый K1) или только корни (roots: остальные K1,
-- плановое объявление офицера). boot — его первый запрос: записи обгоняют чат.
function TC.Request(key, roots, boot)
	local now = ns.Now()
	if roots then
		Push(asks.roots, now)
	else
		Push(asks.all, now)
		if key then lastAsk[key] = now end
		if boot then bootAt = now end
	end
	Schedule(now + C.TRUST_SHARE_DELAY)
end

-- Репортёр отвечает на Q1 согильдийца key (Census.lua): каталог раньше отчётов. Сразу уходит
-- то, что не разослано после последнего запроса каталога спросившим (UQ при входе), а если
-- его нет или он давний — после этого Q1.
function TC.Urgent(key)
	local now = ns.Now()
	local since = key and lastAsk[key]
	if not since or not asks.all[1] or since < asks.all[1] then
		since = now
		Push(asks.all, now)
		if key then lastAsk[key] = now end
	end
	if since > urgentSince then urgentSince = since end
	Pass(true)
end

-- Рассылала ли гильдия эти байты меньше окна назад и после всех запросов.
local function Heard(r)
	local last = Latest(r.id)
	return last ~= nil and ns.Now() - last.at < C.TRUST_SHARE_WINDOW and not Pending(Catalog(ns.Now()), r)
end

-- Сразу, без окна и очереди офицеров: новая или изменённая запись, явное действие. Не уходит —
-- и при постановке, и перед первым куском — только запись, которую гильдия слышала меньше окна
-- назад и после всех запросов. force — без этой проверки. Возвращает, поставлено ли сообщение.
-- Корень перед сертификатом (KT, затем KP с before) сюда не ходит: Security.ShareRoot шлёт его
-- всегда. А снятое задание Comm сразу убирает из очереди, и ждавшие его через before идут.
function TC.Direct(r, prio, force, guard)
	if not r then return false end
	if not force and Heard(r) then return false end
	return ns.Comm.Send("GUILD", r.wire, { prefix = r.prefix, prio = prio, key = r.key, guard = guard,
		skip = not force and function() return Heard(r) end or nil })
end

-- Копии каталога по GUILD: услышанные от офицеров и свои.
ns.Comm.Watch(function(msg, sender, prefix, started)
	local kind = msg:sub(1, 2)
	local now = ns.Now()
	if kind == "Q1" then
		if sender then q1At = now end
		return
	end
	if not KINDS[kind] then return end
	if sender then
		if not ns.Roster.Fresh() or not ns.Roster.IsOfficerRank(ns.Roster.RankOf(sender)) then return end
		if now - q1At <= PUSH_AFTER_Q1 and ns.Census.Reporter() == ns.Util.Key(sender) then
			pushUntil = now + PUSH_QUIET
		end
	else
		local list = mine[kind] or {}
		mine[kind] = list
		list[#list + 1] = now
	end
	local at, id = started or now, Id(prefix, msg)
	local c = Note(id, at, now)
	-- Что обслужила копия, считается сразу: давние копии корня потом забываются.
	if kind ~= "KT" and kind ~= "UO" and ns.Security.CanAdmin() then
		local list = Catalog(now)
		local r = Index(list).byId[id]
		if r then Served(list, r, c) end
	end
	-- UO главы с доказательством покрывает тот же UO без него (не наоборот).
	local bare = Bare(kind, msg)
	if bare then Note(Id(prefix, bare), at, now) end
	-- Чужая копия могла открыть следующий уровень: проверить сразу, а не в свой срок.
	if sender and queuedCount == 0 then Schedule(now + 0.2) end
end)

ns.On("LOGIN", function()
	ns.Every(60, "trust catalog gc", function()
		local now = ns.Now()
		for id, list in pairs(copies) do
			if now - list[#list].at > KEEP then copies[id] = nil end
		end
		for key, t in pairs(lastAsk) do
			if now - t > KEEP then lastAsk[key] = nil end
		end
	end)
end)

ns.On("GUILD_CHANGED", function()
	copies, asks, lastAsk, mine = {}, { all = {}, roots = {} }, {}, {}
	bootAt, urgentSince, q1At, pushUntil = -1e9, -1e9, -1e9, -1e9
	catalog, ranks, rankSig = nil, {}, nil
end)
