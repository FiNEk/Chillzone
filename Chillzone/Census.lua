-- Chillzone: перепись. Привет H1 в гильдию, выборы репортёра (один на гильдию),
-- отчёты через реле, запрос Q1 при входе и ответы на него из кэша.
-- Расписание и выборы — по образцу Olympus Comm.lua.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Census = {}
ns.Census = Census

local peers = {} -- [Key] = { t, since, z, r, name, version, unready }: согильдийцы с аддоном
-- since — с какого привета согильдиец на связи без перерыва дольше PEER_WINDOW.
local helloReady -- готовность, объявленная в последнем H1
local helloAt = -1e9 -- когда последний H1 поставлен в очередь
-- С какого момента слушаем приветы своей гильдии (вход, смена гильдии). Каждый клиент шлёт H1
-- раз в HELLO_EVERY, поэтому через HEARD_ALL молчание согильдийца в игре значит: аддона нет.
local listenSince
local HEARD_ALL = C.HELLO_EVERY + 30
local lastSent, lastSentAt = nil, -1e9
local lastQ1Answer = -1e9
local trustCatchupPending = false

function Census.Peers()
	return peers
end

local function Live(now)
	local out = {}
	for k, p in pairs(peers) do
		if now - p.t <= C.PEER_WINDOW then out[k] = p end
	end
	return out
end

-- Сколько согильдийцев с аддоном на связи (вместе со мной).
function Census.Users()
	local n = 1
	for _ in pairs(Live(ns.Now())) do n = n + 1 end
	return n
end

-- Есть ли аддон у согильдийца с ключом key (U.Key имени). true — это я или от него был привет
-- H1 после входа; false — привета нет, хотя приветы слушаем дольше HEARD_ALL (верно только для
-- того, кто сейчас в игре); nil — пока не знаю. Второе значение — версия его аддона.
function Census.Addon(key)
	if not key then return nil end
	if key == ns.myKey then return true, ns.VERSION end
	local p = peers[key]
	if p then return true, p.version end
	if listenSince and ns.Now() - listenSince >= HEARD_ALL then return false end
	return nil
end

-- Кандидат в репортёры: глава, офицер или связной по моему ростеру; пока
-- Config.TRUST_ANY_MEMBER — любой согильдиец из ростера.
local function Trusted(key)
	return ns.Roster.TrustOfKey(key) ~= nil
end

-- Ключ репортёра гильдии. withoutMe — выбор без меня: кто пересылает гильдии, пока я после
-- входа молчу (LOGIN_QUIET), хотя гильдия уже выбрала меня. Вышедшего из игры снимает свежий
-- ростер: окно приветов (PEER_WINDOW) втрое длиннее аренды у реле, и всё это время гильдия
-- ждала бы пересылки от того, кого нет. Ростер читают не одновременно, и выбор может
-- разойтись, но лишь пока кто-то ещё выбирает ушедшего: он ничего не пересылает, а убрать
-- невыбранного значит не изменить выбор, поэтому двух действующих репортёров не бывает.
function Census.Reporter(withoutMe)
	if not ns.myKey then return nil end
	local now = ns.Now()
	local live = Live(now)
	local me = not withoutMe and helloReady ~= false and ns.Security.MyCertificate() and ns.myKey or nil
	local officers = me and ns.Roster.Fresh() and ns.Roster.IsOfficerRank(ns.Roster.RankOf(ns.me))
	for key, peer in pairs(live) do
		if peer.unready or ns.Roster.LeftGame(key, peer.t) then
			live[key] = nil
		elseif ns.Roster.IsOfficerRank(ns.Roster.byKey[key]) then
			officers = true
		end
	end
	local function eligible(key)
		if not Trusted(key) then return false end
		return not officers or ns.Roster.IsOfficerRank(ns.Roster.byKey[key])
	end
	-- Зонами я делюсь всегда; флаг зон из чужих приветов по-прежнему важен: старые клиенты с
	-- выключенной настройкой выборы уступают.
	return Codec.PickReporter(me, true, live, now, C.PEER_WINDOW, eligible)
end

local acting, handingUntil = false, nil -- я репортёр; до каких пор я передаю аренду
local deafUntil = 0 -- до каких пор приветы могли до меня не дойти: блокировка чата и LOGIN_QUIET после неё

-- В блокировке чата клиент может не слышать приветы дольше PEER_WINDOW. Тогда согильдийцы для
-- него исчезают, он выбирает себя и после блокировки шлёт гильдии свой кэш, а его RG никто не
-- принимает. Поэтому новым репортёром можно стать только через LOGIN_QUIET после блокировки,
-- когда приветы уже дошли. Действующий репортёр остаётся: короткий бой не должен стоить
-- гильдии передачи дел и новой регистрации у реле.
function Census.IsReporter()
	if not ns.IsMember() or not ns.loginAt then return false end
	local now = ns.Now()
	if ns.Comm.InLockdown() then deafUntil = now + C.LOGIN_QUIET end
	if now - ns.loginAt < C.LOGIN_QUIET then return false end
	if now < deafUntil and not acting then return false end
	return Census.Reporter() == ns.myKey
end

---------------------------------------------------------------------------
-- Смена репортёра. Новый репортёр регистрируется у реле не сразу: после входа он молчит
-- LOGIN_QUIET, у реле — раз в 15 секунд. Всё это время реле шлют RM прежнему по его аренде.
-- Поэтому прежний ещё REPORTER_HANDOVER секунд пересылает их гильдии и называет реле
-- преемника (RU), а гильдия принимает RG и от него.
---------------------------------------------------------------------------
local elected, previous = nil, nil -- ключ выбранного репортёра; { key, untilAt } — прежний
local inheritedUntil -- до каких пор вошедший репортёр может узнать своего предшественника

function Census.Track()
	local now = ns.Now()
	-- Сообщить о получении или потере сертификата, не дожидаясь очередного привета.
	if helloReady ~= (ns.Security.MyCertificate() ~= nil) then Census.SendHello() end
	local key = Census.Reporter()
	if key ~= elected then
		previous = elected and { key = elected, untilAt = now + C.REPORTER_HANDOVER } or nil
		elected = key
		inheritedUntil = nil
	end
	local me = Census.IsReporter()
	local changed = me ~= acting
	if changed then
		acting = me
		handingUntil = not me and now + C.REPORTER_HANDOVER or nil
		-- Вошедший клиент мог с самого начала выбирать себя и не увидеть смену elected.
		-- Его предшественник ещё пересылает пакеты, пока реле принимают новую регистрацию.
		inheritedUntil = me and not previous and now + C.REPORTER_HANDOVER or nil
	end
	if inheritedUntil and now <= inheritedUntil then
		local predecessor = Census.Reporter(true)
		if predecessor then
			previous = { key = predecessor, untilAt = inheritedUntil }
			inheritedUntil = nil
		end
	end
	if changed then ns.Fire("REPORTER", me) end
end

-- Я был репортёром и передаю дела: пересылаю гильдии RM по старой аренде.
function Census.Handing()
	Census.Track()
	return handingUntil ~= nil and ns.Now() <= handingUntil
end

-- Я пересылаю гильдии то, что приходит от реле: репортёр или передающий дела.
function Census.Forwarding()
	return Census.IsReporter() or Census.Handing()
end

-- Имя преемника, которому я передаю аренду, или nil.
function Census.Successor()
	local p = elected and elected ~= ns.myKey and peers[elected]
	return p and p.name or nil
end

-- Принимать ли от key пересланное гильдии (RG): от выбранного репортёра, от прежнего, пока
-- он передаёт дела. Вошедший репортёр сохраняет того, кого выбрали бы без него, и после
-- LOGIN_QUIET: реле могут ещё слать пакеты по старой аренде.
function Census.MayForward(key)
	if not key then return false end
	Census.Track()
	if key == elected then return true end
	if previous and previous.key == key and ns.Now() <= previous.untilAt then return true end
	return elected == ns.myKey and not acting and key == Census.Reporter(true)
end

-- Имя репортёра для показа.
function Census.ReporterName()
	local key = Census.Reporter()
	if not key then return nil end
	if key == ns.myKey then return U.Display(ns.me) end
	return peers[key] and U.Display(peers[key].name) or key
end

---------------------------------------------------------------------------
-- Помощники репортёра. Общие обязанности гильдии (ответ на Q1, прямой запрос отчёта) сначала
-- выполняет репортёр, а если он молчит или знает меньше — следующие по очереди. Очередь у всех
-- клиентов одна и та же, как и выборы: офицеры, затем делящиеся зонами, затем по ключу. В ней
-- только согильдийцы на связи новее Config.LAST_WITHOUT_HELPERS, которые слушают гильдию дольше
-- HELPER_SETTLE: прежние версии этих обязанностей не знают, а только что вошедший сам за них ещё
-- не берётся. Граница версии — общая постоянная, а не моя версия: иначе клиенты двух версий с
-- помощниками считали бы очередь по-разному. except — кого не считать (спросивший сам себе не
-- отвечает).
---------------------------------------------------------------------------
local function Settled(since, now)
	return since ~= nil and now - since >= C.HELPER_SETTLE
end

local function Helps(version)
	return U.VersionNewer(version, C.LAST_WITHOUT_HELPERS)
end

-- Слушаю приветы своей гильдии дольше HELPER_SETTLE: число согильдийцев с аддоном уже известно.
function Census.Settled()
	return Settled(listenSince, ns.Now())
end

function Census.Helpers(except)
	if not ns.myKey then return {} end
	local now = ns.Now()
	local reporter = Census.Reporter()
	local list = {}
	local function add(key, officer, zones)
		if key ~= reporter and key ~= except and Trusted(key) then
			list[#list + 1] = { key = key, officer = officer and true or false, zones = zones and true or false }
		end
	end
	if not Helps(ns.VERSION) then return list end
	if helloReady ~= false and ns.Security.MyCertificate() and Settled(listenSince, now) then
		add(ns.myKey, ns.Roster.IsOfficerRank(ns.Roster.RankOf(ns.me)), true)
	end
	for key, p in pairs(Live(now)) do
		if not p.unready and Settled(p.since, now) and Helps(p.version)
			and not ns.Roster.LeftGame(key, p.t) then
			add(key, ns.Roster.IsOfficerRank(ns.Roster.byKey[key]), p.z)
		end
	end
	table.sort(list, function(a, b)
		if a.officer ~= b.officer then return a.officer end
		if a.zones ~= b.zones then return a.zones end
		return a.key < b.key
	end)
	local out = {}
	for i, e in ipairs(list) do out[i] = e.key end
	return out
end

-- Моё место в очереди помощников (1 — первый после репортёра) или nil.
function Census.HelperSlot(except)
	for i, key in ipairs(Census.Helpers(except)) do
		if key == ns.myKey then return i end
	end
	return nil
end

function Census.SendHello()
	if not ns.IsMember() then return end
	local R = ns.Relay
	local ready = ns.Security.MyCertificate() ~= nil
	local hello = Codec.EncodeHello(ns.VERSION, true, R and R.IAmRelay() or false, not ready)
	if ns.Comm.Send("GUILD", hello, { prio = ns.Comm.PRIO_CONTROL, key = "hello" }) then
		helloReady, helloAt = ready, ns.Now()
	end
end

-- Привет в ответ на запрос каталога доверия (Security.ShareTrust): не чаще раза в gap
-- секунд. Сменилась готовность — сразу, как в Track. Плановый привет (HELLO_EVERY) и
-- ответ новому соседу (H1) идут как прежде.
function Census.Hello(gap)
	if helloReady ~= (ns.Security.MyCertificate() ~= nil) or ns.Now() - helloAt >= gap then Census.SendHello() end
end

ns.Comm.On("H1", function(msg, sender, dist)
	if dist ~= "GUILD" then return end
	local h = Codec.DecodeHello(msg)
	if not h then return end
	local key, now = U.Key(sender), ns.Now()
	local known = peers[key]
	local since = known and now - known.t <= C.PEER_WINDOW and known.since or now
	peers[key] = { t = now, since = since, z = h.zones, r = h.relay, name = sender, version = h.version, unready = h.unready }
	ns.Update.Heard(key, h.version)
	-- Новый согильдиец с аддоном: ответить своим приветом, чтобы выборы сошлись быстрее,
	-- и отметить его в списке людей окна.
	if not known or known.version ~= h.version then ns.Fire("PEERS") end
	if not known then ns.After(math.random(2, 6), "hello back", Census.SendHello) end
end)

---------------------------------------------------------------------------
-- Отчёты
---------------------------------------------------------------------------

-- Отчёт подписывается асинхронно (Security.Seal). Отправленным он считается только после
-- подписи: если она не удалась, следующая проверка через 10 секунд попробует снова.
-- signing — подпись уже идёт (не ставить вторую); epoch меняется со сменой гильдии.
local signing, epoch = nil, 0
local SIGN_WAIT = 30 -- подпись дольше этого считается потерянной
local lastRefresh = -1e9 -- когда игрок последний раз просил обновить перепись

function Census.MaybeReport(force)
	if not Census.IsReporter() then return end
	local r = ns.Roster.report
	if not r then return end
	local now = ns.Now()
	if signing and now - signing < SIGN_WAIT then return end
	if not force and now - lastSentAt < C.REPORT_EVERY - 5 then return end
	r.users = Census.Users()
	r.version = ns.VERSION
	local shareable = Codec.Shareable(r, true)
	local raw = Codec.EncodeReport(shareable)
	-- Время исключаем только из сравнения, не из отправляемого отчёта.
	-- Shareable вернул копию: время ростера и все поля (включая связных) сохраняются.
	shareable.st = 0
	local body = Codec.EncodeReport(shareable)
	if not force and body == lastSent and now - lastSentAt < C.REPORT_IDLE then return end
	local mine, online, total = epoch, r.online, r.total
	signing = now
	local queued, why = ns.Security.Seal(raw, function(wire, failed)
		if mine ~= epoch then return end
		signing = nil
		ns.Activity.Finish("report", wire ~= nil)
		if not wire then
			ns.Log("отчёт не подписан (%s), повтор при следующей проверке", tostring(failed))
			return
		end
		lastSent, lastSentAt = body, ns.Now()
		Census.lastRaw = wire
		ns.Relay.EnsureRegistered()
		ns.Relay.Out("L", wire)
		ns.Log("отчёт отправлен: %d/%d онлайн", online, total)
	end)
	if not queued then
		signing = nil
		ns.Log("отчёт не подписан (%s), повтор при следующей проверке", tostring(why))
	end
	return queued and true or false
end

ns.On("ROSTER", function(r)
	if ns.IsMember() then ns.Data.SetLocal(r) end
end)

-- Состав мог прийти уже после первого H1: подключённый клиент сразу участвует
-- в выборах, не ждёт минутного таймера и публикует свой прочитанный ростер. Только при
-- входе в состав: глава продлевает решения раз в 10 минут, и привет на каждое было бы лишним.
local wasMember = false
ns.On("UNION", function()
	local member = ns.IsMember()
	if member and not wasMember then
		if ns.Roster.report then ns.Data.SetLocal(ns.Roster.report) end
		Census.SendHello()
	end
	wasMember = member
	Census.Track()
end)

-- Чужой отчёт приходит только внутри конверта реле.
ns.Comm.On("R1", function(msg, sender, dist, ctx)
	if dist ~= "RELAY" or not ctx or not ctx.authenticated then return end
	local r = Codec.DecodeReport(msg)
	if not r then return end
	-- Версию берём из любого подписанного отчёта, даже если сам отчёт не нужен (повтор, своя гильдия).
	ns.Update.Heard(U.Key(sender), r.version)
	local ok, why = ns.Data.Take(r, msg, sender, nil, ctx)
	if not ok and why ~= "повтор" then ns.Log("отчёт %s от %s не принят: %s", r.guild, U.Display(sender), tostring(why)) end
	-- Обычная доставка идёт от репортёра и в журнал не пишется; эта строка показывает, что отчёт
	-- пришёл в обход него.
	if ok and ctx.side then ns.Log("отчёт %s принят от %s: он не репортёр гильдии", r.guild, U.Display(ctx.relay)) end
	-- Перезашедшее реле присылает последний известный ему отчёт, а гильдии нужен только новый.
	-- taken — отчёт оказался новым для меня: реле делится таким со своей гильдией.
	ctx.outdated, ctx.taken = why == "старее", ok or nil
end)

---------------------------------------------------------------------------
-- Q1: вошедший просит у репортёра своей гильдии всё, что тот знает.
---------------------------------------------------------------------------
-- Ответов на Q1 бывает сколько угодно и ни одного: репортёр молчит при пустом кэше и чаще
-- Q1_GAP. Поэтому конец ожидания — тишина (отчёты считает обработчик RG в Relay).
local function AskReports(key)
	ns.Activity.Start("census", L.ACT_CENSUS, C.CENSUS_WAIT)
	ns.Comm.Send("GUILD", "Q1~", { key = key })
end

-- Сколько секунд до следующего запроса отчётов (0 — можно сейчас). Репортёр считает Q1_GAP от
-- получения Q1, а запрос сначала лежит в очереди: без запаса он промолчал бы на новый запрос.
local REFRESH_MARGIN = 15
function Census.RefreshWait()
	return math.max(0, lastRefresh + C.Q1_GAP + REFRESH_MARGIN - ns.Now())
end

-- Обновление по просьбе игрока. Репортёр сам отчитывается за гильдию, остальные спрашивают
-- его. Возвращает операцию, которую стоит дождаться, или nil и причину: "wait" — запрашивать
-- рано, "failed" — отчёт поставить в подпись не удалось (интервал тогда не тратится).
function Census.Refresh()
	if not ns.IsMember() then return nil end
	if Census.RefreshWait() > 0 then return nil, "wait" end
	if Census.IsReporter() then
		ns.Activity.Start("report", L.ACT_REPORT, SIGN_WAIT)
		-- Уже идущая подпись тоже годится: её колбэк закроет операцию.
		if not Census.MaybeReport(true) and not signing then
			ns.Activity.Finish("report", false)
			return nil, "failed"
		end
		lastRefresh = ns.Now()
		return "report"
	end
	lastRefresh = ns.Now()
	AskReports("census-request")
	return "census"
end

---------------------------------------------------------------------------
-- Ответ на Q1 из кэша соседей. Репортёр отвечает сразу, как раньше. Остальные слушают, какие
-- отчёты после Q1 показаны гильдии (RG), и досылают из своего кэша то, чего никто не показал:
-- первый помощник — после Q1_HELPER_WAIT секунд без RG отчётов, каждый следующий — на
-- Q1_HELPER_STEP позже. Услышанный RG отчёта начинает тишину заново: пока кто-то отвечает,
-- остальные ждут. «Показано» — пакет побайтно совпал с моим сохранённым, а не открытый текст
-- чужого RG: подделка с большим временем честный ответ не заглушит. Q1 в пределах Q1_GAP от
-- начала раунда входит в тот же раунд, как и у репортёра: вошедший шлёт Q1 дважды.
---------------------------------------------------------------------------
local round -- { at, last, shown = { [пакет] = true }, slot }: раунд Q1
local mySide = {} -- когда я отдавал гильдии RG отчёта: за последнюю минуту
local SIDE_SPARE = 2 -- столько RG за минуту остаётся реле (Relay.Forward) сверх ответа на Q1

local function SideSent(now)
	while mySide[1] and now - mySide[1] > 60 do table.remove(mySide, 1) end
	return #mySide
end

-- Отчёт (пакет S1) показан гильдии: услышан в RG от репортёра или в пределах лимита согильдийца
-- (Relay.lua), own — отдан гильдии мной. Свои RG ещё и считаются: получатель берёт отчёты не от
-- репортёра не чаще RG_SIDE_PER_MIN за минуту от одного отправителя.
function Census.Shown(wire, own)
	local now = ns.Now()
	if own then mySide[#mySide + 1] = now end
	if not round then return end
	round.shown[wire] = true
	if not own then round.last = now end
end

local function Turn(r)
	return r.last + C.Q1_HELPER_WAIT + (r.slot - 1) * C.Q1_HELPER_STEP
end

-- Моя очередь: дослать то, чего никто не показал. Свежие отчёты — первыми; сколько уйдёт, решает
-- лимит получателя. Ответ встаёт в очередь отправки с проверкой: если чужая копия будет показана
-- раньше, моя не уйдёт.
local function Help(r)
	local now = ns.Now()
	if not ns.IsMember() or not ns.Roster.Fresh() or ns.Comm.InLockdown() or Census.IsReporter() then return end
	if now - lastQ1Answer < C.Q1_GAP then return end
	local missing = {}
	for _, c in ipairs(ns.Data.Cached()) do
		if not r.shown[c.raw] then missing[#missing + 1] = c end
	end
	local room = C.RG_SIDE_PER_MIN - SIDE_SPARE - SideSent(now)
	if #missing == 0 or room <= 0 then return end
	table.sort(missing, function(a, b)
		if a.st ~= b.st then return a.st > b.st end
		return a.key < b.key
	end)
	lastQ1Answer = now
	for i = 1, math.min(room, #missing) do
		local c = missing[i]
		mySide[#mySide + 1] = now
		ns.Security.IntroduceWire("GUILD", c.raw, true) -- спросивший мог ещё не знать автора
		ns.Comm.Send("GUILD", Codec.EncodeRM("RG", "L", c.origin, c.raw), { key = "q1:" .. c.key,
			guard = function() return not r.shown[c.raw] end })
	end
	ns.Log("ответ на Q1 вместо репортёра: %d из %d отчётов", math.min(room, #missing), #missing)
end

local function Wait(r)
	ns.After(math.max(0.5, Turn(r) - ns.Now()), "q1 helper", function()
		if round ~= r or not r.slot then return end
		if ns.Now() < Turn(r) then Wait(r); return end
		r.slot = nil
		Help(r)
	end)
end

-- Q1 открывает раунд, если прошлый начался раньше Q1_GAP. Помощники — только первые Q1_HELPERS
-- по очереди, без спросившего.
local function StartRound(asker, now)
	if round and now - round.at < C.Q1_GAP then return end
	local slot = not Census.IsReporter() and Census.HelperSlot(asker) or nil
	round = { at = now, last = now, shown = {}, slot = slot and slot <= C.Q1_HELPERS and slot or nil }
	if round.slot then Wait(round) end
end

ns.Comm.On("Q1", function(_, sender, dist)
	if dist ~= "GUILD" then return end
	local now = ns.Now()
	StartRound(U.Key(sender), now)
	if not Census.IsReporter() or now - lastQ1Answer < C.Q1_GAP then return end
	if #ns.Data.Cached() == 0 then return end
	lastQ1Answer = now
	-- Каталог доверия (корни, допуски) — раньше самих конвертов: срочно, без окна каталога.
	ns.Security.ShareTrust(false, U.Key(sender), true)
	for _, c in ipairs(ns.Data.Cached()) do
		ns.Security.IntroduceWire("GUILD", c.raw, true) -- спросивший мог отбросить прежний KP
		ns.Comm.Send("GUILD", Codec.EncodeRM("RG", "L", c.origin, c.raw), { key = "q1:" .. c.key })
		Census.Shown(c.raw, true)
	end
end)

-- Отчёты, пришедшие до подтверждения нового корня, были отброшены. Один раз запросить их у
-- репортёра своей гильдии, выждав обычную паузу Q1. Несколько корней подряд — один запрос;
-- авторам отчётов ничего не шлём.
ns.On("AUTH_ROOT", function()
	if trustCatchupPending then return end
	trustCatchupPending = true
	ns.After(C.Q1_GAP + math.random(5, 15), "census after trust bootstrap", function()
		trustCatchupPending = false
		if not ns.IsMember() then return end
		for _, root in pairs(ns.Security.Roots()) do
			local row = ns.Data.Row(root.guild)
			if not row or not row.r then
				AskReports("census-request")
				return
			end
		end
	end)
end)

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
ns.On("LOGIN", function()
	listenSince = ns.Now()
	ns.After(3, "first hello", Census.SendHello)
	ns.After(15, "census ask", function()
		if ns.IsMember() then AskReports() end
	end)
	ns.After(35, "census ask after trust bootstrap", function()
		if ns.IsMember() then AskReports("census-request") end
	end)
	ns.Every(C.HELLO_EVERY, "hello", Census.SendHello)
	ns.Every(5, "reporter change", Census.Track)
	ns.Every(10, "report check", function() Census.MaybeReport(false) end)
	ns.Every(300, "prune", function() ns.Data.Prune() end)
end)

ns.On("GUILD_CHANGED", function()
	wipe(peers)
	helloReady, helloAt = nil, -1e9
	listenSince = ns.Now()
	elected, previous, acting, handingUntil = nil, nil, false, nil
	inheritedUntil = nil
	lastSent, lastSentAt, signing, epoch = nil, -1e9, nil, epoch + 1
	lastRefresh = -1e9
	round, mySide = nil, {}
	ns.After(3, "hello after guild change", Census.SendHello)
end)

-- Настройки «делиться зонами» больше нет: зоны своей гильдии отправляются всегда. Команда
-- осталась, чтобы привычное /chillzone zones on|off не называлось неизвестным; в справке её нет.
ns.Command("zones", function() ns.Print(L.ZONES_ALWAYS) end)

ns.Status(function()
	local n = 0
	for _ in pairs(Live(ns.Now())) do n = n + 1 end
	return L.STATUS_CENSUS:format(Census.ReporterName() or "—", Census.IsReporter() and L.YES or L.NO, n)
end)

ns.Status(function()
	if not ns.IsMember() then return nil end
	if C.TRUST_ANY_MEMBER then return L.STATUS_TRUST_ANY end
	if not Census.Reporter() then return L.STATUS_NO_REPORTER:format(C.RELAY_RANK) end
	local role = ns.MyTrust()
	local me = role == "leader" and L.TRUST_LEADER or role == "officer" and L.TRUST_OFFICER or role == "rank" and L.TRUST_RANK or L.TRUST_NONE
	return L.STATUS_TRUST:format(me, C.RELAY_RANK)
end)
