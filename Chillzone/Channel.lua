-- Chillzone: канал игры для строк общего чата (/cz1). На Forever аддон-сообщения в каналах
-- не доставляются, а обычный текст, отправленный из нажатия клавиши (Enter или слэш-команда),
-- доходит всем в канале. Строка уходит читаемым текстом от имени игрока: игроки без аддона
-- читают её и пишут в канал сами. Гильдию автора получатель определяет по имени
-- (Chat.Attribute), из текста ничего не берёт; строки канала не подписаны и прав не дают.
-- Подписанный путь через реле идёт параллельно, копии сводит Chat.lua.
--
-- Что показала проверка в игре (2026-11-11), и как это учтено здесь:
-- - сервер пропускает 3 строки игрока за скользящие ~30 с, лишние не раздаёт и отвечает
--   уведомлением THROTTLED. Аддон считает свои строки сам (бюджет C.CHANNEL_BUDGET за
--   C.CHANNEL_WINDOW по эху и отправкам без эха), THROTTLED считает истиной сервера;
-- - клиент может не знать, что он вне канала (бан без уведомления, «призрачное» членство) —
--   лечит только перезаход персонажа. Надёжный признак — нет эха своей строки. Такой канал
--   считается сломанным до перезахода (ns.char.channelBroken);
-- - отказ при входе (пароль, BANNED, NOT_ALLOWED_IN_CHANNEL) перезаход не лечит, если это бан:
--   список банов живёт, пока канал не пуст. Вход повторяется сам (LOCKED_RETRY), см. «Страж»;
-- - отправка из таймера даёт окно ошибки игры и ADDON_ACTION_BLOCKED: тогда отправка в канал
--   выключается до перезагрузки интерфейса;
-- - вход из аддона номера каналов игры не сдвигает, перестановка каналов не нужна.
-- Вход после каналов игры — из Chillzone 0.1 (по образцу Olympus Comm.lua / ChatHall.lua).
-- Страж канала — по образцу Olympus 1.5.0 Comm.lua (HealChannel), плюс «стук» (Channel.Knock).
-- Окна чата игры не трогаем (taint): сырые строки и уведомления канала прячет фильтр.
local ADDON, ns = ...

local C = ns.Config
local U = ns.Util
local L = ns.L

local Channel = {}
ns.Channel = Channel

local JOIN_BY = 15 -- не позже стольких секунд после входа
-- Канал не пускает (пароль, бан, отказ сервера): следующий вход через столько секунд, дальше
-- раз в 10 минут. Как в Olympus: другого названия нет, стучимся в ту же дверь.
Channel.LOCKED_RETRY = { 60, 120, 300, 600 }
-- Канал под паролем — реже: каждая попытка показывает окно пароля игры (его не трогаем, taint).
Channel.PASSWORD_RETRY = { 600, 1800, 3600 }
local LOCKED_TELL = 3600 -- подсказка о закрытом канале не чаще (переживает /reload)
Channel.ECHO_WAIT = 5 -- своя строка без эха дольше этого — канал под сомнением
local BROKEN_AFTER = 2 -- столько строк подряд без эха (или THROTTLED при свободном бюджете) — сломан
local joined -- имя канала, в который вошли
local index = 0
local lock -- канал не пускает: { why, tries, try, nextAt }
local joinTries = 0 -- вызовов JoinChannelByName: один отказ считается один раз, сколько бы уведомлений ни пришло
-- Свои строки в окне бюджета, старые первыми: { t, text, state, only }. state: wait — ждёт эха,
-- echo — вернулась, lost — эха не было, hand — эхо строки, набранной в канал вручную.
-- Отклонённые сервером (THROTTLED) в счёт не идут и из списка убираются.
local lines = {}
local throttledUntil = -1e9 -- до этого времени сервер строк не примет
local misses, throttles = 0, 0 -- подряд: строк без эха, THROTTLED при свободном бюджете
local actionBlocked = false -- игра заблокировала действие аддона: до перезагрузки интерфейса

-- sent — строк передано игре, failed — игра отказала сразу, echoed — своих строк вернулось
-- эхом, heard — чужих строк, notices — уведомлений канала, lost — своих строк без эха,
-- throttled — уведомлений THROTTLED, over — строк /cz1 сверх бюджета (ушли только подписью).
Channel.stats = { sent = 0, failed = 0, echoed = 0, heard = 0, notices = 0, lost = 0, throttled = 0, over = 0 }
Channel.notice = nil -- последнее уведомление: { kind, who, at }
Channel.owner = nil -- владелец канала по уведомлениям
Channel.announce = nil -- объявления входа и выхода: true, false или nil (неизвестно)

-- Forever может отдать поля события закрытыми значениями: тогда их нельзя даже сравнивать.
local function Secret(value)
	return type(issecretvalue) == "function" and issecretvalue(value)
end

-- Канал включён автором аддона (Config) и игроком (настройки персонажа).
function Channel.Enabled()
	if C.CHANNEL_CHAT ~= true or type(C.CHANNEL) ~= "table" then return false end
	return not (ns.char and ns.char.chatViaChannel == false)
end

function Channel.Name()
	if type(C.CHANNEL) ~= "table" then return nil end
	return C.CHANNEL[ns.faction or "Alliance"] or C.CHANNEL.Alliance
end

function Channel.Index()
	if not joined or not GetChannelName then return 0 end
	index = tonumber((GetChannelName(joined))) or 0
	return index
end

-- ok — исправен; doubt — под сомнением (последняя строка без эха или THROTTLED при свободном
-- бюджете); broken — сломан до перезахода персонажа; blocked — игра заблокировала отправку,
-- до перезагрузки интерфейса; locked — канал не пускает, вход повторяется сам.
function Channel.State()
	if actionBlocked then return "blocked" end
	if ns.char and ns.char.channelBroken then return "broken" end
	if lock and Channel.Index() <= 0 then return "locked" end
	if misses > 0 or throttles > 0 then return "doubt" end
	return "ok"
end

-- В канал можно писать сейчас: включён, я в объединении, канал исправен, вошёл, нет блокировки
-- сообщений. Бюджет здесь не учитывается: его проверяет Chat.Send (Channel.Free).
function Channel.Ready()
	if not Channel.Enabled() or not ns.IsMember() then return false end
	local state = Channel.State()
	if state == "broken" or state == "blocked" then return false end
	return Channel.Index() > 0 and not ns.Comm.InLockdown()
end

---------------------------------------------------------------------------
-- Бюджет: сервер пропускает C.CHANNEL_BUDGET строк игрока за скользящее окно
---------------------------------------------------------------------------
local function Budget()
	return tonumber(C.CHANNEL_BUDGET) or 3
end

local function Window()
	return tonumber(C.CHANNEL_WINDOW) or 35
end
Channel.Budget, Channel.Window = Budget, Window

local function Prune(now)
	while lines[1] and lines[1].state ~= "wait" and now - lines[1].t >= Window() do
		table.remove(lines, 1)
	end
end

-- Сколько строк можно отправить в канал сейчас.
function Channel.Free()
	local now = ns.Now()
	if now < throttledUntil then return 0 end
	Prune(now)
	return math.max(0, Budget() - #lines)
end

-- Через сколько секунд в канал уйдут n строк подряд; nil — никогда (n больше бюджета).
function Channel.WaitFor(n)
	local budget = Budget()
	if n > budget then return nil end
	local now = ns.Now()
	Prune(now)
	local at = math.max(now, throttledUntil)
	local k = #lines - (budget - n) -- столько старых строк должно выйти из окна
	if k > 0 then at = math.max(at, lines[k].t + Window()) end
	return math.max(1, math.ceil(at - now))
end

---------------------------------------------------------------------------
-- Состояние канала
---------------------------------------------------------------------------
-- Канал сломан до перезахода персонажа: в него не пишем и не входим заново. Состояние
-- переживает /reload (ns.char), сбрасывается при входе персонажа (PLAYER_ENTERING_WORLD).
local function Break(why)
	if not ns.char or ns.char.channelBroken then return end
	ns.char.channelBroken = { why = why, at = ns.ServerTime() }
	ns.Log("канал %s сломан до перезахода персонажа: %s", joined or Channel.Name() or "?", why)
	ns.Print(L.CHANNEL_BROKEN)
end
Channel.Break = Break

-- Своя строка не вернулась за ECHO_WAIT.
local function Missed(line)
	if line.state ~= "wait" then return end
	line.state = "lost"
	Channel.stats.lost = Channel.stats.lost + 1
	if line.only then ns.Print(L.CHAT_NO_ECHO) end
	-- Блокировка сообщений и заблокированная игрой отправка объясняют тишину сами.
	if actionBlocked or ns.Comm.InLockdown() or not Channel.Enabled() then return end
	misses = misses + 1
	ns.Log("канал %s: нет эха своей строки за %d с (подряд %d)", joined or "?", Channel.ECHO_WAIT, misses)
	if misses >= BROKEN_AFTER then Break(L.CHANNEL_WHY_ECHO) end
end

-- Эхо своей строки: строка, которую отправил аддон, или набранная игроком вручную.
-- Фильтр брани меняет текст прямо в событии, поэтому сравнение и по маске (U.MaskMatch).
local function Echo(text)
	Channel.stats.echoed = Channel.stats.echoed + 1
	misses, throttles = 0, 0
	for pass = 1, 2 do
		for _, line in ipairs(lines) do
			if (line.state == "wait" or line.state == "lost") and line.text
				and (line.text == text or (pass == 2 and U.MaskMatch(line.text, text))) then
				line.state = "echo"
				return
			end
		end
	end
	lines[#lines + 1] = { t = ns.Now(), state = "hand" }
end

-- THROTTLED: сервер не принял строку. Это истина сервера: до конца окна строк не шлём, каким
-- бы ни был свой счёт (лимит может оказаться общим на все каналы игрока). Если свой счёт
-- не исчерпан два раза подряд — так сервер отвечает забаненному: канал сломан.
local function Throttled()
	local now = ns.Now()
	Channel.stats.throttled = Channel.stats.throttled + 1
	Prune(now)
	for i, line in ipairs(lines) do
		if line.state == "wait" then
			table.remove(lines, i)
			line.state = "throttled"
			if line.only then ns.Print(L.CHAT_CHANNEL_THROTTLED) end
			break
		end
	end
	throttledUntil = now + Window()
	if #lines < Budget() then
		throttles = throttles + 1
		if throttles >= BROKEN_AFTER then Break("THROTTLED") end
	end
end

-- Пометка «выключен» у нашего канала в списке каналов игры.
local function Disabled(name)
	if not name or not GetChannelList then return false end
	local list = { GetChannelList() }
	if type(list[3]) ~= "boolean" then return false end
	for i = 1, #list, 3 do
		local id, chan, off = list[i], list[i + 1], list[i + 2]
		if not Secret(chan) and type(chan) == "string" and U.Fold(chan) == U.Fold(name) then
			return not Secret(off) and off == true and (tonumber(id) or 0) > 0
		end
	end
	return false
end

---------------------------------------------------------------------------
-- Страж канала (по образцу Olympus 1.5.0 Comm.lua). Наш канал — обычный канал игры: владелец —
-- кто дольше всех в нём, при его выходе игра сама отдаёт канал (и место модератора) другому
-- участнику, так что владельцем может оказаться и посторонний, и любой клиент Chillzone.
-- Владелец может поставить пароль (вошедшие после этого не попадут в канал) и банить; бан
-- переживает перезаход забаненного, пока канал не опустеет, а он не пустеет никогда.
-- Аддон этими правами против игроков не пользуется. Пока канал у клиента объединения (он
-- владелец или модератор), он только снимает вред: пароль (только владелец: модератору сервер
-- ответил бы NOT_OWNER) и баны участников объединения, которые видели в этом канале клиенты
-- этой учётной записи (список в ns.store.channelGuard, у каждой записи свой канал). Свой ручной
-- бан свой клиент не снимает — его снимет следующий страж. Бан, которого никто не видел (до
-- обновления или без свидетелей), снимает «стук» (Channel.Knock): подписанная строка /cz1 автора
-- пришла, а копии из канала за CHAT_DEDUPE нет — значит, автора в канале нет, и страж снимает с
-- него бан на случай, если тот есть. Лишнее снятие безвредно: сервер отвечает PLAYER_NOT_BANNED.
--
-- Чем это отличается от Olympus, и почему:
-- - баны посторонних не трогаем: строки канала видны в общем чате, и бан спамера участником
--   объединения должен держаться. Olympus снимал любой увиденный бан при каждой смене владельца;
-- - пароль снимаем только после увиденной чужой смены (Olympus снимал его и «на всякий случай»
--   после /reload, а это уведомление о смене пароля всем в канале, в том числе без аддона);
-- - за проход не больше HEAL_BURST вызовов, «нет такого игрока» откладывает снятие всё дольше;
-- - закрытый паролем канал пробуем реже (PASSWORD_RETRY): каждая попытка — окно пароля игры;
-- - если игра не пускает вызовы стража из таймера, страж переходит на нажатие клавиши (строка
--   /cz, Channel.Pressed) и выключается до новой версии аддона, только если и оттуда нельзя.
--   Так окно ошибки игры игрок видит не больше двух раз, а не теряет стража после первого.
---------------------------------------------------------------------------
local HEAL_GAP = 60 -- один и тот же вызов стража не чаще
local HEAL_BURST = 3 -- вызовов стража за один проход, остальные — через HEAL_GAP
local OFFLINE_RECHECK = 300 -- бан игрока вне игры снять снова не раньше (дальше — вдвое дольше)
local OFFLINE_MAX = 3600 -- ...но не реже
Channel.KNOCK_GAP = 1800 -- стук одного автора не чаще
local BAN_MAX = 20 -- банов к снятию в памяти: старые уходят первыми
local BAN_KEEP = 7 * 86400 -- бан к снятию хранится не дольше
local ASK_WAIT = 5 -- ответ сервера на вызов стража ждём столько секунд

local seat = {} -- моё место в канале по уведомлениям: owner, moderator (переживает /reload)
local passwordSet = false -- пароль поставил кто-то другой, пока я в канале (переживает /reload)
local healAt = {} -- [вызов] = когда сделан
local healPending, recheckPending, seatPending = false, false, false
local healing, healCallAt, sendAt = false, -1e9, -1e9
local healRefused = false
local pressing = false -- идёт нажатие клавиши (Channel.Pressed)
local blockedNow = false -- игра заблокировала вызов стража, пока он шёл
local callPressed = false -- последний вызов стража был из нажатия клавиши
local tried = {} -- вызовы последнего прохода: вернуть, если игра их заблокировала
local asked = {} -- [Key] = { entry, at }: бан только что снят, ждём ответа «нет такого игрока»
local knocked = {} -- [Key] = время стука
local byMe = {} -- [Key] = true: забанил я сам — свой бан не снимаю

local function Store()
	local s = ns.store
	if type(s) ~= "table" then return nil end
	if type(s.channelGuard) ~= "table" then s.channelGuard = {} end
	if type(s.channelGuard.banned) ~= "table" then s.channelGuard.banned = {} end
	return s.channelGuard
end

local function Seated()
	return seat.owner == true or seat.moderator == true
end
Channel.Seated = Seated

-- Игра запретила аддону вызовы стража (и из нажатия клавиши): в этой сессии или в этой версии.
local function Refused()
	if healRefused then return true end
	local g = Store()
	return g ~= nil and g.refused == ns.VERSION
end

-- Игра не пускает вызовы стража из таймера: в этой версии аддона — только из нажатия клавиши.
local function PressOnly()
	local g = Store()
	return g ~= nil and g.press == ns.VERSION
end

local function SetPassword(on)
	passwordSet = on and true or false
	if ns.char then ns.char.channelPassword = on and true or nil end
end

-- Участник объединения по имени (свой ростер, сертификат, перепись, онлайн): только с таких
-- страж снимает увиденные баны.
local function InUnion(name)
	return ns.Chat ~= nil and ns.Chat.Attribute ~= nil and ns.Chat.Attribute(name) ~= nil
end

-- Бан к снятию. name — имя из уведомления или автора строки, by — кто забанил (для журнала),
-- knock — автор подписанной строки (участник объединения по подписи).
local function Remember(name, by, knock)
	local g, key, ch = Store(), U.Key(name), joined or Channel.Name()
	if not g or not key or not ch then return end
	if not knock and not InUnion(name) then
		ns.Log("канал %s: %s не из объединения — его бан не трогаю", ch, U.Display(name))
		return
	end
	local now, list = ns.ServerTime(), g.banned
	local n, oldest = 0, nil
	for k, b in pairs(list) do
		if type(b) ~= "table" or type(b.n) ~= "string" or now - (tonumber(b.t) or 0) > BAN_KEEP then
			list[k] = nil
		else
			n = n + 1
			if not oldest or (tonumber(b.t) or 0) < (tonumber(list[oldest].t) or 0) then oldest = k end
		end
	end
	if not list[key] and n >= BAN_MAX and oldest then list[oldest] = nil end
	list[key] = { n = U.TellName(name), ch = ch, t = now, by = by and U.Display(by) or nil, knock = knock or nil }
end

local function Forget(name)
	local g, key = Store(), U.Key(name)
	if not key then return end
	if g then g.banned[key] = nil end
	asked[key], byMe[key] = nil, nil
end

-- Согильдиец, которого свежий ростер показывает вне игры: снимать с него бан рано, сервер
-- ответил бы «нет такого игрока».
local function Offline(key)
	local R = ns.Roster
	return R ~= nil and R.online ~= nil and R.online[key] == false and R.Fresh() == true
end

-- Один вызов стража, защищённый, тот же не чаще HEAL_GAP: done, failed, later (рано),
-- missing (в клиенте нет такой функции), blocked (игра заблокировала, попробуем из нажатия
-- клавиши) или refused (игра запретила и оттуда).
local function Call(what, fn, ...)
	if Refused() then return "refused" end
	if type(fn) ~= "function" then return "missing" end
	local now = ns.Now()
	if now - (healAt[what] or -1e9) < HEAL_GAP then return "later" end
	healAt[what] = now
	healCallAt, healing, blockedNow, callPressed = now, true, false, pressing
	local ok, err = pcall(fn, ...)
	healing = false
	if blockedNow then
		healAt[what] = nil -- не сделан: из нажатия клавиши — сразу
		return Refused() and "refused" or "blocked"
	end
	ns.Log("канал %s: страж — %s%s", joined or "?", what, ok and "" or (", ошибка: " .. tostring(err)))
	return ok and "done" or "failed"
end

-- Игра заблокировала вызовы прохода (её событие может прийти и после вызова): вернуть их в
-- работу, чтобы снять из нажатия клавиши.
local function Untry()
	local g = Store()
	for _, t in ipairs(tried) do
		if t.password then
			SetPassword(true)
		elseif g and not g.banned[t.key] then
			g.banned[t.key], asked[t.key] = t.entry, nil
		end
	end
	tried = {}
end

local function HealSoon(delay)
	if healPending then return end
	healPending = true
	ns.After(delay or 2, "channel heal", function()
		healPending = false
		Channel.Heal()
	end)
end

-- Баны игроков вне игры ждут своего таймера: снятие по уведомлению за ним не стоит.
local function RecheckSoon()
	if recheckPending then return end
	recheckPending = true
	ns.After(OFFLINE_RECHECK + 1, "channel heal recheck", function()
		recheckPending = false
		Channel.Heal()
	end)
end

-- Только пока канал мой (владелец или модератор) и я в нём, только против вреда: пароль —
-- после чужой смены и только владельцем; баны из списка этого канала — кроме игроков вне игры
-- (их — позже). Если игра пускает вызовы стража только из нажатия клавиши — только оттуда.
function Channel.Heal()
	if not Seated() or Refused() or (PressOnly() and not pressing) then return end
	if not Channel.Enabled() or not ns.IsMember() or Channel.Index() <= 0 then return end
	local state = Channel.State()
	if state == "broken" or state == "blocked" then return end
	-- В блокировке сообщений игра может заблокировать и вызов стража: это не её ответ стражу.
	if ns.Comm.InLockdown() then
		HealSoon(HEAL_GAP)
		return
	end
	local g = Store()
	if not g then return end
	local name, later, away, calls = joined, false, false, 0
	tried = {}
	-- Вызов прохода: nil — дальше, true — проход окончен (игра заблокировала вызов; сам вызов
	-- остаётся в работе, а прежние вызовы прохода прошли).
	local function Try(what, fn, arg, t)
		if calls >= HEAL_BURST then later = true; return nil, "later" end
		local r = Call(what, fn, name, arg)
		if r == "blocked" or r == "refused" then return true, r end
		if r == "later" then later = true else calls = calls + 1 end
		if r == "done" then tried[#tried + 1] = t end
		return nil, r
	end
	if passwordSet and seat.owner then
		local stop, r = Try(L.CHANNEL_HEAL_PASSWORD, SetChannelPassword, "", { password = true })
		if stop then return end
		if r ~= "later" then SetPassword(false) end
	end
	local now, server = ns.Now(), ns.ServerTime()
	for key, a in pairs(asked) do
		if now - a.at > ASK_WAIT then asked[key] = nil end
	end
	-- Баны другого канала (персонажа другой стороны учётной записи) не мои.
	local keys = {}
	for key, b in pairs(g.banned) do
		if type(b) ~= "table" or b.ch == name then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local b = g.banned[key]
		if type(b) ~= "table" or type(b.n) ~= "string" or byMe[key] or ns.IsMe(b.n)
			or server - (tonumber(b.t) or 0) > BAN_KEEP then
			g.banned[key] = nil
		elseif (tonumber(b.wait) or 0) > server or Offline(key) then
			away = true
		else
			local stop, r = Try(L.CHANNEL_HEAL_UNBAN:format(b.n), ChannelUnban, b.n, { key = key, entry = b })
			if stop then return end
			if r ~= "later" and r ~= "missing" then
				g.banned[key] = nil
				if r == "done" then asked[key] = { entry = b, at = now } end
			end
		end
	end
	if later then HealSoon(HEAL_GAP) end
	if away then RecheckSoon() end
end

-- Нажатие клавиши (строка /cz, Chat.Send): если игра пускает вызовы стража только оттуда, лечим
-- здесь, после строки в канал.
function Channel.Pressed()
	if not PressOnly() or Refused() or not Seated() then return end
	pressing = true
	local ok, err = pcall(Channel.Heal)
	pressing = false
	if not ok then error(err, 0) end
end

-- Сервер ответил, что снятого игрока нет в игре: его бан снимем позже, и с каждым таким
-- ответом всё позже (вдвое, но не реже OFFLINE_MAX).
local function NotFound(key)
	local a = key and asked[key]
	if not a or ns.Now() - a.at > ASK_WAIT or a.missed then return end
	a.missed = true
	local g = Store()
	if g and not g.banned[key] then
		local miss = (tonumber(a.entry.miss) or 0) + 1
		a.entry.miss = miss
		a.entry.wait = ns.ServerTime() + math.min(OFFLINE_RECHECK * 2 ^ (miss - 1), OFFLINE_MAX)
		g.banned[key] = a.entry
	end
	ns.Log("канал %s: %s не в игре, бан сниму позже", joined or "?", tostring(a.entry.n))
	RecheckSoon()
end

-- Стук: подписанная строка /cz1 автора пришла, а копии из канала нет (Chat.lua). Только пока
-- канал мой; один автор не чаще KNOCK_GAP; свой бан не снимаю.
function Channel.Knock(sender)
	if not Seated() or Refused() or type(sender) ~= "string" or ns.IsMe(sender) then return end
	if Channel.Index() <= 0 then return end
	local key = U.Key(sender)
	if not key or byMe[key] then return end
	local now = ns.Now()
	if knocked[key] and now - knocked[key] < Channel.KNOCK_GAP then return end
	knocked[key] = now
	local g = Store()
	if not g or g.banned[key] then return end
	ns.Log("канал %s: строка %s пришла подписью без копии из канала — снимаю бан, если он есть", joined or "?", U.Display(sender))
	Remember(sender, nil, true)
	HealSoon()
end

local function SaveSeat()
	if not ns.char then return end
	ns.char.channelSeat = Seated() and { owner = seat.owner, moderator = seat.moderator } or nil
end

-- Место пришло: подсказка игроку один раз на персонажа, потом страж. Через 2 с, чтобы два
-- уведомления владельца (OWNER_CHANGED и SET_MODERATOR) дали одну подсказку.
local function SeatGiven()
	if seatPending then return end
	seatPending = true
	ns.After(2, "channel seat", function()
		seatPending = false
		if not Seated() then return end
		if ns.char and not ns.char.channelSeatTold then
			ns.char.channelSeatTold = true
			ns.Print(L.CHANNEL_SEAT_YOU, seat.owner and L.CHANNEL_SEAT_OWNER_OF or L.CHANNEL_SEAT_MODERATOR_OF, joined or Channel.Name() or "?")
		end
		Channel.Heal()
	end)
end

local function SetSeat(role, on)
	local was = Seated()
	seat[role] = on and true or nil
	SaveSeat()
	if Seated() and not was then
		ns.Log("канал %s: моё место — %s", joined or "?", seat.owner and L.CHANNEL_SEAT_OWNER or L.CHANNEL_SEAT_MODERATOR)
		SeatGiven()
	elseif was and not Seated() then
		ns.Log("канал %s: места владельца или модератора у меня больше нет", joined or "?")
	end
end

local function LoseSeat(why)
	if not Seated() then return end
	seat = {}
	SaveSeat()
	ns.Log("канал %s: места у меня нет (%s)", joined or "?", why)
end

-- Канал не пускает: подсказка не чаще LOCKED_TELL, вход — снова через LOCKED_RETRY.
local function Locked(why)
	local now = ns.Now()
	if not lock then
		lock = { why = why, tries = 0 }
		local server = ns.ServerTime()
		if ns.char and server - (tonumber(ns.char.channelLockedTold) or 0) >= LOCKED_TELL then
			ns.char.channelLockedTold = server
			ns.Print(L.CHANNEL_LOCKED, Channel.Name() or "?")
		end
	end
	lock.why = why
	if lock.try == joinTries then return end
	lock.try = joinTries
	lock.tries = lock.tries + 1
	local retry = why == "WRONG_PASSWORD" and Channel.PASSWORD_RETRY or Channel.LOCKED_RETRY
	lock.nextAt = now + retry[math.min(lock.tries, #retry)]
	ns.Log("канал %s не пускает (%s, попытка %d), следующая через %d с", Channel.Name() or "?", why, lock.tries,
		math.floor(lock.nextAt - now + 0.5))
end

local function Unlocked()
	if not lock then return end
	ns.Log("канал %s снова пускает, попыток было %d", joined or Channel.Name() or "?", lock.tries)
	lock = nil
end

---------------------------------------------------------------------------
-- Вход и выход
---------------------------------------------------------------------------
-- Название канала из события: базовое (arg9) или из строки «5. Название».
local function BaseName(baseName, channelName)
	if type(baseName) == "string" and baseName ~= "" then return baseName end
	if type(channelName) == "string" then return channelName:match("^%d+%.%s*(.-)%s*$") or channelName end
	return nil
end

local function Ours(baseName, channelName)
	local name, base = Channel.Name(), BaseName(baseName, channelName)
	return name ~= nil and base ~= nil and U.Fold(base) == U.Fold(name)
end
Channel.Ours = Ours

-- force — повторить вход, даже если канал недавно отказал (игрок сам включил настройку).
-- Сломанный канал не лечится повторным входом: только перезаходом персонажа. Канал, который
-- не пускает, пробуем снова по расписанию LOCKED_RETRY.
function Channel.Join(force)
	if not Channel.Enabled() or not ns.IsMember() or not JoinChannelByName then return end
	if Channel.State() == "broken" then return end
	if not force and lock and ns.Now() < (lock.nextAt or 0) then return end
	local name = Channel.Name()
	joined = name
	local id = tonumber((GetChannelName(name))) or 0
	if id > 0 then
		index = id
		Unlocked()
		if Seated() then HealSoon() end -- после /reload: место прежнее, список банов мог пополниться
		return
	end
	joinTries = joinTries + 1
	ns.Log("вход в канал %s", name)
	JoinChannelByName(name)
	ns.After(3, "channel check", function()
		index = tonumber((GetChannelName(name))) or 0
		if index <= 0 then
			ns.Log("канал %s: войти не удалось", name)
		elseif Disabled(name) then
			Break(L.CHANNEL_WHY_DISABLED)
		else
			Unlocked()
		end
	end)
end

-- Выходим только из канала, в который вошли сами; force — по названию (игрок выключил канал).
function Channel.Leave(force)
	local name = joined or (force and Channel.Name()) or nil
	if name and LeaveChannelByName and (tonumber((GetChannelName(name))) or 0) > 0 then
		LeaveChannelByName(name)
		ns.Log("выход из канала %s", name)
	end
	joined, index = nil, 0
	LoseSeat(L.CHANNEL_SEAT_WHY_LEFT)
end

-- Настройка «Общий чат через канал игры».
function Channel.SetEnabled(on)
	if not ns.char then return end
	ns.char.chatViaChannel = on and true or false
	if on then Channel.Join(true) else Channel.Leave(true) end
end

local function JoinSoon(t, seenAt)
	local _, first = GetChannelName(1)
	if first and first ~= "" then seenAt = seenAt or t end
	if t >= JOIN_BY or (seenAt and t - seenAt >= 2) then
		Channel.Join()
		return
	end
	ns.After(1, "join channel", function() JoinSoon(t + 1, seenAt) end)
end

local function Keep()
	if Channel.Enabled() and ns.IsMember() then
		if Channel.State() == "broken" then return end
		if Channel.Index() <= 0 then
			Channel.Join()
		elseif Disabled(joined) then
			Break(L.CHANNEL_WHY_DISABLED)
		end
	elseif joined then
		Channel.Leave()
	end
end

---------------------------------------------------------------------------
-- Отправка и приём
---------------------------------------------------------------------------
-- Строка в канал обычным текстом. Только синхронно из нажатия клавиши (Enter или
-- слэш-команда): отправку из таймера сервер не пропустит. Бюджет проверяет вызывающий
-- (Channel.Free). only — другого пути у строки нет: если эха не будет, игрок узнает.
-- true — строка передана игре; дошла ли она, показывает эхо.
function Channel.Send(text, only)
	if type(text) ~= "string" or text == "" or #text > 255 then return false end
	if not Channel.Ready() then return false end
	sendAt = ns.Now()
	local ok = pcall(SendChatMessage, text, "CHANNEL", nil, index)
	if not ok then
		Channel.stats.failed = Channel.stats.failed + 1
		return false
	end
	Channel.stats.sent = Channel.stats.sent + 1
	local line = { t = ns.Now(), text = text, state = "wait", only = only or nil }
	lines[#lines + 1] = line
	ns.After(Channel.ECHO_WAIT, "channel echo", function() Missed(line) end)
	return true
end

-- Строки канала: (текст, автор, язык, «5. Название», …, базовое название, язык, номер строки, GUID).
ns.RegisterEvent("CHAT_MSG_CHANNEL", function(text, sender, _, channelName, _, _, _, _, baseName, _, _, guid)
	if Secret(text) or Secret(sender) or Secret(channelName) or Secret(baseName) then return end
	if type(text) ~= "string" or type(sender) ~= "string" or not Ours(baseName, channelName) then return end
	if not Channel.Enabled() or not ns.IsMember() then return end
	if ns.IsMe(sender) then
		Echo(text)
	else
		Channel.stats.heard = Channel.stats.heard + 1
	end
	if Secret(guid) or type(guid) ~= "string" then guid = nil end
	ns.Chat.ReceivePlain(text, sender, guid)
end)

-- Уведомления канала: (вид, игрок, язык, «5. Название», второй игрок, флаги, зона, номер,
-- базовое название). Всё — в журнал; владелец, объявления, отказы — в состояние.
local function Notice(notice, player, _, channelName, player2, _, _, number, baseName)
	if Secret(notice) or Secret(player) or Secret(player2) or Secret(channelName) or Secret(baseName) then return end
	if type(notice) ~= "string" or not Ours(baseName, channelName) then return end
	player = type(player) == "string" and player ~= "" and U.Display(player) or nil
	player2 = type(player2) == "string" and player2 ~= "" and U.Display(player2) or nil
	local who, who2 = player, player2 -- как их назвал сервер: для снятия бана
	player = type(player) == "string" and player ~= "" and U.Display(player) or nil
	player2 = type(player2) == "string" and player2 ~= "" and U.Display(player2) or nil
	Channel.stats.notices = Channel.stats.notices + 1
	Channel.notice = { kind = notice, who = player, at = ns.ServerTime() }
	ns.Log("канал %s: %s%s%s", BaseName(baseName, channelName) or "?", notice,
		player and (" " .. player) or "", player2 and (", " .. player2) or "")
	local me = player ~= nil and ns.IsMe(who)
	if notice == "YOU_JOINED" or notice == "YOU_CHANGED" then
		index = tonumber(number) or index
		SetPassword(false) -- вошёл без пароля: пароля сейчас нет
		Unlocked()
	elseif notice == "YOU_LEFT" or notice == "SUSPENDED" then
		index = 0
		LoseSeat(notice)
	elseif notice == "WRONG_PASSWORD" or notice == "BANNED" or notice == "NOT_ALLOWED_IN_CHANNEL" then
		Locked(notice)
	elseif notice == "THROTTLED" then
		Throttled()
	elseif notice == "CHANNEL_OWNER" or notice == "OWNER_CHANGED" then
		Channel.owner = player
		SetSeat("owner", me)
	elseif notice == "SET_MODERATOR" or notice == "UNSET_MODERATOR" then
		if me then SetSeat("moderator", notice == "SET_MODERATOR") end
	elseif notice == "PASSWORD_CHANGED" then
		if not me then SetPassword(true) end
	elseif notice == "PLAYER_BANNED" then
		-- Забаненному игра ничего не шлёт; кто видит бан, запоминает его, кроме своего.
		if player and not me then
			if player2 and ns.IsMe(who2) then
				byMe[U.Key(who)] = true
			else
				Remember(who, who2)
			end
		end
	elseif notice == "PLAYER_UNBANNED" or notice == "PLAYER_NOT_BANNED" then
		if player then Forget(who) end
	elseif notice == "PLAYER_NOT_FOUND" then
		if player then NotFound(U.Key(who)) end
	elseif notice == "NOT_OWNER" then
		-- Ответ на снятие пароля: владелец уже не я, а место модератора могло остаться.
		if ns.Now() - healCallAt <= ASK_WAIT and seat.owner then
			SetSeat("owner", false)
			if not Seated() then LoseSeat(notice) end
		end
	elseif notice == "NOT_MODERATOR" or notice == "NOT_MEMBER" then
		-- Ответ на вызов стража: место, сохранённое до /reload, уже не моё.
		if ns.Now() - healCallAt <= ASK_WAIT then LoseSeat(notice) end
	elseif notice == "ANNOUNCEMENTS_ON" then
		Channel.announce = true
	elseif notice == "ANNOUNCEMENTS_OFF" then
		Channel.announce = false
	end
	if Seated() then HealSoon() end
end
ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", Notice)
ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", Notice)

-- Игра просит пароль нашего канала (своё окно игры, его не трогаем): то же, что неверный пароль.
ns.RegisterEvent("CHANNEL_PASSWORD_REQUEST", function(channel)
	if Secret(channel) or type(channel) ~= "string" or not Ours(nil, channel) then return end
	Locked("WRONG_PASSWORD")
end)

-- «Нет такого игрока» на снятие бана: игрок вне игры, снимем позже. Строку прячем.
local function NotFoundKey(text)
	local key = ns.Comm.NotFoundKey(text)
	local a = key and asked[key]
	if a and ns.Now() - a.at <= ASK_WAIT then return key end
end
ns.RegisterEvent("CHAT_MSG_SYSTEM", function(text)
	local key = NotFoundKey(text)
	if key then NotFound(key) end
end)
ns.AddChatFilter("CHAT_MSG_SYSTEM", function(_, _, text)
	return NotFoundKey(text) ~= nil
end)

-- Отправка из таймера: окно «ошибка интерфейсной операции» и ADDON_ACTION_BLOCKED. Второго
-- такого окна игрок видеть не должен: до перезагрузки интерфейса в канал не пишем. Вызов стража
-- (имя функции или событие во время вызова, позже своей отправки; Forever называет функцию
-- UNKNOWN()) отправку не выключает: заблокированный из таймера страж переходит на нажатие
-- клавиши, а заблокированный и оттуда выключается до новой версии аддона.
local function ActionBlocked(addon, func)
	if Secret(addon) or addon ~= ADDON then return end
	local fname = not Secret(func) and tostring(func) or "?"
	if healing or fname:find("ChannelUnban", 1, true) or fname:find("SetChannelPassword", 1, true)
		or (ns.Now() - healCallAt <= 1 and healCallAt >= sendAt) then
		if healing then blockedNow = true else Untry() end
		if Refused() then return end
		local g = Store()
		if callPressed then -- последний вызов был из нажатия клавиши: и оттуда нельзя
			healRefused = true
			if g then g.refused = ns.VERSION end
			ns.Log("игра запретила аддону управлять каналом (%s): страж выключен до новой версии аддона", fname)
		elseif not PressOnly() then
			if g then g.press = ns.VERSION end
			ns.Log("игра не пускает вызовы стража из таймера (%s): дальше — только при отправке строки /cz", fname)
		end
		return
	end
	if actionBlocked then return end
	actionBlocked = true
	ns.Log("игра заблокировала действие аддона (%s): отправка в канал выключена до перезагрузки интерфейса", fname)
end
ns.RegisterEvent("ADDON_ACTION_BLOCKED", ActionBlocked)
ns.RegisterEvent("ADDON_ACTION_FORBIDDEN", ActionBlocked)

-- Сырые строки канала и его уведомления не показываются: строку покажет Chat.ReceivePlain
-- в привычном виде. Игроку, у которого канал выключен, ничего не прячем.
local function Filter(_, _, _, _, _, channelName, _, _, _, _, baseName)
	if Secret(channelName) or Secret(baseName) then return false end
	return Channel.Enabled() and ns.IsMember() and Ours(baseName, channelName)
end
for _, event in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
	ns.AddChatFilter(event, Filter)
end

-- Сломанный канал лечит только перезаход персонажа, не /reload. После /reload персонаж остаётся
-- в канале, а уведомлений о месте игра заново не пришлёт: место берём из сохранённого.
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function(isInitialLogin)
	if not ns.char then return end
	if isInitialLogin ~= true then
		local s = ns.char.channelSeat
		if type(s) == "table" then
			seat.owner, seat.moderator = s.owner == true or nil, s.moderator == true or nil
		end
		passwordSet = ns.char.channelPassword == true
		return
	end
	ns.char.channelSeat, ns.char.channelPassword = nil, nil
	if not ns.char.channelBroken then return end
	ns.char.channelBroken = nil
	ns.Log("вход персонажа: канал игры снова считается исправным")
end)

ns.On("LOGIN", function()
	ns.After(1, "join channel", function() JoinSoon(1, nil) end)
	ns.Every(60, "channel keep", Keep)
end)
ns.On("GUILD_CHANGED", Keep)
ns.On("UNION", Keep)

local STATE_TEXT = { ok = "CHANNEL_STATE_OK", doubt = "CHANNEL_STATE_DOUBT", broken = "CHANNEL_STATE_BROKEN", blocked = "CHANNEL_STATE_BLOCKED" }

local function StateText()
	local state = Channel.State()
	if state == "locked" then
		return L.CHANNEL_STATE_LOCKED:format(lock.why, math.max(0, math.ceil((lock.nextAt or 0) - ns.Now())))
	end
	return L[STATE_TEXT[state]]
end

ns.Status(function()
	if not Channel.Enabled() then return L.STATUS_CHANNEL_OFF end
	local s = Channel.stats
	local last = Channel.notice and Channel.notice.kind or "—"
	local announce = Channel.announce == true and L.CHANNEL_ANNOUNCE_ON
		or Channel.announce == false and L.CHANNEL_ANNOUNCE_OFF or "—"
	return L.STATUS_CHANNEL:format(joined or Channel.Name() or "—", Channel.Index(), StateText(),
		Channel.Free(), Budget(), s.sent, s.echoed, s.lost, s.throttled, s.over, s.heard,
		Channel.owner or "—", announce, last)
end)

-- Сколько банов этого канала страж держит к снятию.
function Channel.Pending()
	local g, n, ch = Store(), 0, joined or Channel.Name()
	for _, b in pairs(g and g.banned or {}) do
		if type(b) == "table" and b.ch == ch then n = n + 1 end
	end
	return n
end

ns.Status(function()
	if not Channel.Enabled() then return nil end
	local role = seat.owner and L.CHANNEL_SEAT_OWNER or seat.moderator and L.CHANNEL_SEAT_MODERATOR or L.CHANNEL_SEAT_MEMBER
	local mode = Refused() and L.CHANNEL_GUARD_REFUSED or PressOnly() and L.CHANNEL_GUARD_PRESS or L.CHANNEL_GUARD_ON
	return L.STATUS_CHANNEL_GUARD:format(role, Channel.Pending(), mode)
end)
