-- Chillzone: канал игры для строк общего чата (/cz1). На Forever аддон-сообщения в каналах
-- не доставляются, а обычный текст, отправленный из нажатия клавиши (Enter или слэш-команда),
-- доходит всем в канале. Строка уходит читаемым текстом от имени игрока: игроки без аддона
-- читают её и пишут в канал сами. Гильдию автора получатель определяет по имени
-- (Chat.Attribute), из текста ничего не берёт; строки канала не подписаны и прав не дают.
-- Подписанный путь через реле идёт параллельно, копии сводит Chat.lua.
-- Вход после каналов игры и KeepLast — из Chillzone 0.1 (по образцу Olympus Comm.lua / ChatHall.lua).
-- Окна чата игры не трогаем (taint): сырые строки и уведомления канала прячет фильтр.
local ADDON, ns = ...

local C = ns.Config
local U = ns.Util
local L = ns.L

local Channel = {}
ns.Channel = Channel

local JOIN_BY = 15 -- не позже стольких секунд после входа
local LOCKED_RETRY = 600 -- пароль или бан: повторный вход не чаще
local joined -- имя канала, в который вошли
local index = 0
local lockedUntil = -1e9
-- sent — строк передано игре, failed — игра отказала сразу, echoed — своих строк вернулось
-- эхом, heard — чужих строк, notices — уведомлений канала.
Channel.stats = { sent = 0, failed = 0, echoed = 0, heard = 0, notices = 0 }
Channel.notice = nil -- последнее уведомление: { kind, who, at }

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

-- В канал можно писать сейчас: включён, я в объединении, вошёл, нет блокировки сообщений.
function Channel.Ready()
	return Channel.Enabled() and ns.IsMember() and Channel.Index() > 0 and not ns.Comm.InLockdown()
end

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

-- Наш канал — после каналов игры: если вошли раньше General, тот получил бы /2.
local function KeepLast()
	if not joined or not GetChannelList then return end
	local swap = C_ChatInfo and C_ChatInfo.SwapChatChannelsByChannelIndex
	local infoOf = C_ChatInfo and C_ChatInfo.GetChannelInfoFromIdentifier
	if not swap or not infoOf then return end
	local ours = tonumber((GetChannelName(joined))) or 0
	if ours <= 0 then return end
	local list = { GetChannelList() }
	local stride = type(list[3]) == "boolean" and 3 or 2
	local after = {}
	for i = 1, #list, stride do
		local id = tonumber(list[i])
		local ok, info = pcall(infoOf, list[i + 1])
		if id and id > ours and ok and type(info) == "table" and (tonumber(info.zoneChannelID) or 0) > 0 then after[#after + 1] = id end
	end
	if #after == 0 then return end
	table.sort(after)
	local at = ours
	for _, id in ipairs(after) do
		if not pcall(swap, at, id) then break end
		at = id
	end
end

-- force — повторить вход, даже если канал недавно отказал (игрок сам включил настройку).
function Channel.Join(force)
	if not Channel.Enabled() or not ns.IsMember() or not JoinChannelByName then return end
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
		if index <= 0 then ns.Log("канал %s: войти не удалось", name) end
		ns.SafeCall("channel last", KeepLast)
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
		if Channel.Index() <= 0 then Channel.Join() end
	elseif joined then
		Channel.Leave()
	end
end

-- Строка в канал обычным текстом. Только синхронно из нажатия клавиши (Enter или
-- слэш-команда): отправку из таймера сервер не пропустит. true — строка передана игре;
-- дошла ли она, показывает эхо (Chat.ReceivePlain).
function Channel.Send(text)
	if type(text) ~= "string" or text == "" or #text > 255 then return false end
	if not Channel.Ready() then return false end
	local ok = pcall(SendChatMessage, text, "CHANNEL", nil, index)
	if ok then
		Channel.stats.sent = Channel.stats.sent + 1
	else
		Channel.stats.failed = Channel.stats.failed + 1
	end
	return ok
end

-- Строки канала: (текст, автор, язык, «5. Название», …, базовое название, язык, номер строки, GUID).
ns.RegisterEvent("CHAT_MSG_CHANNEL", function(text, sender, _, channelName, _, _, _, _, baseName, _, _, guid)
	if Secret(text) or Secret(sender) or Secret(channelName) or Secret(baseName) then return end
	if type(text) ~= "string" or type(sender) ~= "string" or not Ours(baseName, channelName) then return end
	if not Channel.Enabled() or not ns.IsMember() then return end
	if ns.IsMe(sender) then
		Channel.stats.echoed = Channel.stats.echoed + 1
	else
		Channel.stats.heard = Channel.stats.heard + 1
	end
	if Secret(guid) or type(guid) ~= "string" then guid = nil end
	ns.Chat.ReceivePlain(text, sender, guid)
end)

-- Уведомления канала: (вид, игрок, язык, «5. Название», второй игрок, флаги, зона, номер,
-- базовое название). Смена владельца, пароль, бан, мут и прочее — в журнал.
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
	end
end
ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE", Notice)
ns.RegisterEvent("CHAT_MSG_CHANNEL_NOTICE_USER", Notice)

-- Сырые строки канала и его уведомления не показываются: строку покажет Chat.ReceivePlain
-- в привычном виде. Игроку, у которого канал выключен, ничего не прячем.
local function Filter(_, _, _, _, _, channelName, _, _, _, _, baseName)
	if Secret(channelName) or Secret(baseName) then return false end
	return Channel.Enabled() and ns.IsMember() and Ours(baseName, channelName)
end
for _, event in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }) do
	ns.AddChatFilter(event, Filter)
end

ns.On("LOGIN", function()
	ns.After(1, "join channel", function() JoinSoon(1, nil) end)
	ns.Every(60, "channel keep", Keep)
end)
ns.On("GUILD_CHANGED", Keep)
ns.On("UNION", Keep)

ns.Status(function()
	if not Channel.Enabled() then return L.STATUS_CHANNEL_OFF end
	local s = Channel.stats
	local last = Channel.notice and Channel.notice.kind or "—"
	return L.STATUS_CHANNEL:format(joined or Channel.Name() or "—", Channel.Index(), s.sent, s.echoed, s.heard, last)
end)
