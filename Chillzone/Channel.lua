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
-- - клиент может не знать, что он вне канала (бан без уведомления, «призрачное» членство,
--   NOT_ALLOWED_IN_CHANNEL при входе) — лечит только перезаход персонажа. Надёжный признак —
--   нет эха своей строки. Такой канал считается сломанным до перезахода (ns.char.channelBroken);
-- - отправка из таймера даёт окно ошибки игры и ADDON_ACTION_BLOCKED: тогда отправка в канал
--   выключается до перезагрузки интерфейса;
-- - вход из аддона номера каналов игры не сдвигает, перестановка каналов не нужна.
-- Вход после каналов игры — из Chillzone 0.1 (по образцу Olympus Comm.lua / ChatHall.lua).
-- Окна чата игры не трогаем (taint): сырые строки и уведомления канала прячет фильтр.
local ADDON, ns = ...

local C = ns.Config
local U = ns.Util
local L = ns.L

local Channel = {}
ns.Channel = Channel

local JOIN_BY = 15 -- не позже стольких секунд после входа
local LOCKED_RETRY = 600 -- пароль или бан: повторный вход не чаще
Channel.ECHO_WAIT = 5 -- своя строка без эха дольше этого — канал под сомнением
local BROKEN_AFTER = 2 -- столько строк подряд без эха (или THROTTLED при свободном бюджете) — сломан
local joined -- имя канала, в который вошли
local index = 0
local lockedUntil = -1e9
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
-- до перезагрузки интерфейса.
function Channel.State()
	if actionBlocked then return "blocked" end
	if ns.char and ns.char.channelBroken then return "broken" end
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
-- Сломанный канал не лечится повторным входом: только перезаходом персонажа.
function Channel.Join(force)
	if not Channel.Enabled() or not ns.IsMember() or not JoinChannelByName then return end
	if Channel.State() == "broken" then return end
	if not force and ns.Now() < lockedUntil then return end
	local name = Channel.Name()
	joined = name
	local id = tonumber((GetChannelName(name))) or 0
	if id > 0 then
		index = id
		return
	end
	ns.Log("вход в канал %s", name)
	JoinChannelByName(name)
	ns.After(3, "channel check", function()
		index = tonumber((GetChannelName(name))) or 0
		if index <= 0 then
			ns.Log("канал %s: войти не удалось", name)
		elseif Disabled(name) then
			Break(L.CHANNEL_WHY_DISABLED)
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
	Channel.stats.notices = Channel.stats.notices + 1
	Channel.notice = { kind = notice, who = player, at = ns.ServerTime() }
	ns.Log("канал %s: %s%s%s", BaseName(baseName, channelName) or "?", notice,
		player and (" " .. player) or "", player2 and (", " .. player2) or "")
	if notice == "YOU_JOINED" or notice == "YOU_CHANGED" then
		index = tonumber(number) or index
		lockedUntil = -1e9
	elseif notice == "YOU_LEFT" or notice == "SUSPENDED" then
		index = 0
	elseif notice == "WRONG_PASSWORD" or notice == "BANNED" then
		lockedUntil = ns.Now() + LOCKED_RETRY
	elseif notice == "THROTTLED" then
		Throttled()
	elseif notice == "NOT_ALLOWED_IN_CHANNEL" then
		Break(notice)
	elseif notice == "CHANNEL_OWNER" or notice == "OWNER_CHANGED" then
		Channel.owner = player
	elseif notice == "ANNOUNCEMENTS_ON" then
		Channel.announce = true
	elseif notice == "ANNOUNCEMENTS_OFF" then
		Channel.announce = false
	end
end
ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", Notice)
ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", Notice)

-- Отправка из таймера: окно «ошибка интерфейсной операции» и ADDON_ACTION_BLOCKED. Второго
-- такого окна игрок видеть не должен: до перезагрузки интерфейса в канал не пишем.
local function ActionBlocked(addon, func)
	if Secret(addon) or addon ~= ADDON or actionBlocked then return end
	actionBlocked = true
	ns.Log("игра заблокировала действие аддона (%s): отправка в канал выключена до перезагрузки интерфейса",
		not Secret(func) and tostring(func) or "?")
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

-- Сломанный канал лечит только перезаход персонажа, не /reload.
ns.RegisterEvent("PLAYER_ENTERING_WORLD", function(isInitialLogin)
	if isInitialLogin ~= true or not ns.char or not ns.char.channelBroken then return end
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

ns.Status(function()
	if not Channel.Enabled() then return L.STATUS_CHANNEL_OFF end
	local s = Channel.stats
	local last = Channel.notice and Channel.notice.kind or "—"
	local announce = Channel.announce == true and L.CHANNEL_ANNOUNCE_ON
		or Channel.announce == false and L.CHANNEL_ANNOUNCE_OFF or "—"
	return L.STATUS_CHANNEL:format(joined or Channel.Name() or "—", Channel.Index(), L[STATE_TEXT[Channel.State()]],
		Channel.Free(), Budget(), s.sent, s.echoed, s.lost, s.throttled, s.over, s.heard,
		Channel.owner or "—", announce, last)
end)
