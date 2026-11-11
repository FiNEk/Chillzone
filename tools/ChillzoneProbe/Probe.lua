-- ChillzoneProbe: проверка обычного текста в пользовательском канале на WoW: Forever.
-- Отдельный аддон для этапа 0 плана «общий чат через канал игры», в релиз Chillzone не входит.
-- С сетью Chillzone не связан: аддон-сообщений не шлёт, подписей и префиксов не трогает,
-- поле ввода игры не меняет. Окна чата игры трогают только команды hide, show, last и filter,
-- которые игрок вызывает сам. Всё, что видно аддону, пишется в журнал, а журнал копируется
-- из своего окна, как «Журнал» Chillzone (JournalPane.lua). Порядок проверки — в README.md.
--
-- Что измеряется: доходит ли строка, отправленная кодом аддона из своего поля по Enter,
-- из слэш-команды, по щелчку и (для сравнения) из таймера; сколько отправок проходит за одно
-- нажатие; совпадает ли эхо байт в байт; что меняет блокировка сообщений в подземелье; какие
-- уведомления канала приходят (владелец, пароль, бан, мут, вход и выход); есть ли GUID и класс
-- у строки; сдвигает ли вход номера каналов игры; что делают фильтр строк и скрытие из окон.
local ADDON, ns = ...

local VERSION = "0.1.0"
local DEFAULT_CHANNEL = "ChillzoneProbe"
local ECHO_WAIT = 6  -- столько секунд ждём свою строку обратно
local WATCH = 8      -- системные строки и ошибки пишутся столько секунд после своего действия
local JOIN_BY = 15   -- автовход после входа в мир: не позже стольких секунд
local MAX_LOG = 1500 -- строк журнала в сохранённых данных
local VIEW_LINES = 500
local MAX_MULTI = 5

local P = { frames = {}, revision = 0 }
ns.Probe = P

local db
local early = {} -- строки журнала до загрузки сохранённых данных
local stats
local pending = {} -- свои отправки без эхо: { n, text, path, at }
local seq = 0
local watchUntil = -math.huge
local filtersOn = false
local lockdownSeen
local refused = {}
local Refresh

local function ResetStats()
	stats = {
		sent = {}, echoed = {}, changed = {}, lost = {}, failed = {},
		heard = 0, from = {}, guid = 0, noGuid = 0, class = 0,
		secret = 0, secretOther = 0, notices = {}, joins = 0, leaves = 0, blocked = 0,
	}
end
ResetStats()

---------------------------------------------------------------------------
-- Мелочи
---------------------------------------------------------------------------
local function API(name)
	local f = rawget(_G, name)
	return type(f) == "function" and f or nil
end

local function Secret(v)
	return type(issecretvalue) == "function" and issecretvalue(v) and true or false
end

local function Safe(v)
	if Secret(v) then return "скрыто" end
	if v == nil or v == "" then return "нет" end
	return tostring(v)
end

local function Count(t, key) t[key] = (t[key] or 0) + 1 end

local function Total(t)
	local n = 0
	for _, v in pairs(t) do n = n + v end
	return n
end

-- Короткая сумма для сравнения строк между журналами разных игроков. Меньше 2^31,
-- чтобы формат %x не зависел от разрядности long в клиенте.
local function Sum(s)
	local h = 0
	for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
	return ("%08x"):format(h)
end
P.Sum = Sum

local function FirstDiff(a, b)
	local n = math.min(#a, #b)
	for i = 1, n do
		if a:byte(i) ~= b:byte(i) then return i end
	end
	return n + 1
end

local function Quote(text) return "«" .. text .. "»" end

local function Trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function Print(text)
	local frame = rawget(_G, "DEFAULT_CHAT_FRAME")
	if frame then frame:AddMessage("|cff7fd4c1ChillzoneProbe|r: " .. text) end
end

local function Stamp()
	local server = API("GetServerTime") and GetServerTime() or time()
	return ("%s %8.2f"):format(date("!%H:%M:%S", server), GetTime())
end

local function Log(fmt, ...)
	local ok, text = pcall(string.format, fmt, ...)
	if not ok then text = fmt .. " [ошибка формата]" end
	local line = Stamp() .. " " .. text
	local log = db and db.log or early
	log[#log + 1] = line
	while #log > MAX_LOG do table.remove(log, 1) end
	P.revision = P.revision + 1
	local view = P.frames.view
	if view and not P.copying then view:AddMessage((line:gsub("|", "||")), 0.85, 0.85, 0.85) end
	if Refresh then Refresh() end
end
P.Log = Log

local function Watch() watchUntil = GetTime() + WATCH end
local function Watching() return GetTime() <= watchUntil end

---------------------------------------------------------------------------
-- Состояние канала и игрока
---------------------------------------------------------------------------
local function ChannelName() return db and db.channel or DEFAULT_CHANNEL end

local function Fold(s) return (s:gsub("^%d+%.%s*", ""):lower()) end

-- Наш канал в любом из видов имени, которые дают события («ChillzoneProbe», «5. ChillzoneProbe»).
local function Ours(...)
	local want = Fold(ChannelName())
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if not Secret(v) and type(v) == "string" and v ~= "" and Fold(v) == want then return true end
	end
	return false
end

local function Index()
	local get = API("GetChannelName")
	if not get then return 0 end
	local ok, id = pcall(get, ChannelName())
	if not ok or Secret(id) then return 0 end
	return tonumber(id) or 0
end

local function Lockdown()
	local chat = rawget(_G, "C_ChatInfo")
	local f = type(chat) == "table" and chat.InChatMessagingLockdown
	if type(f) ~= "function" then return "нет API" end
	local ok, on, why = pcall(f)
	if not ok then return "ошибка" end
	if Secret(on) then return "скрыто" end
	if not on then return "нет" end
	if why ~= nil and not Secret(why) then return "да, " .. tostring(why) end
	return "да"
end

local function Where()
	local zone = API("GetRealZoneText") and GetRealZoneText() or nil
	local inside, kind = false, nil
	if API("IsInInstance") then inside, kind = IsInInstance() end
	if inside then return ("зона %s, подземелье %s"):format(Safe(zone), Safe(kind)) end
	return "зона " .. Safe(zone)
end

local function ChannelList()
	local get = API("GetChannelList")
	if not get then return "нет GetChannelList" end
	local list = { get() }
	local stride = type(list[3]) == "boolean" and 3 or 2
	local out = {}
	for i = 1, #list, stride do
		local off = stride == 3 and list[i + 2] == true
		out[#out + 1] = Safe(list[i]) .. ". " .. Safe(list[i + 1]) .. (off and " (выкл.)" or "")
	end
	return #out > 0 and table.concat(out, ", ") or "пусто"
end

local function WindowCount() return tonumber(rawget(_G, "NUM_CHAT_WINDOWS")) or 10 end

-- Номера окон чата, в настройках которых есть наш канал.
local function Windows()
	local get = API("GetChatWindowChannels")
	if not get then return "нет GetChatWindowChannels" end
	local want, found = Fold(ChannelName()), {}
	for i = 1, WindowCount() do
		local ok, list = pcall(function() return { get(i) } end)
		if ok then
			for k = 1, #list, 2 do
				local v = list[k]
				if not Secret(v) and type(v) == "string" and Fold(v) == want then
					found[#found + 1] = tostring(i)
					break
				end
			end
		end
	end
	return #found > 0 and table.concat(found, ", ") or "нет"
end

local function Snapshot(why)
	Log("%s: канал %s №%d, окна с ним: %s, блокировка %s, %s", why, ChannelName(), Index(), Windows(), Lockdown(), Where())
	Log("каналы: %s", ChannelList())
end

local function MyGuid()
	local get = API("UnitGUID")
	if not get then return nil end
	local guid = get("player")
	if Secret(guid) or type(guid) ~= "string" or guid == "" then return nil end
	return guid
end

local function MyName()
	local get = API("UnitFullName") or API("UnitName")
	if not get then return nil, nil end
	local name, realm = get("player")
	if Secret(name) or type(name) ~= "string" or name == "" then return nil, nil end
	if Secret(realm) or type(realm) ~= "string" then realm = nil end
	return name, realm
end

local function Plain(name) return (name:gsub("%-", " "):lower()) end

-- Своя строка: по GUID, а без него — по началу имени (на Forever имя приходит в разных видах:
-- «Имя Фамилия-Реалм», «Имя-Фамилия-Реалм»).
local function IsMe(sender, guid)
	local mine = MyGuid()
	if mine and not Secret(guid) and type(guid) == "string" and guid ~= "" then return guid == mine end
	local name = MyName()
	if not name or type(sender) ~= "string" then return false end
	local s, m = Plain(sender), Plain(name)
	return s == m or s:sub(1, #m + 1) == m .. " "
end

-- GUID и класс отправителя; count — учитывать в счётчиках чужих строк.
local function ClassOf(guid, count)
	if Secret(guid) then return "GUID скрыт" end
	if type(guid) ~= "string" or guid == "" then
		if count then stats.noGuid = stats.noGuid + 1 end
		return "без GUID"
	end
	if count then stats.guid = stats.guid + 1 end
	local get = API("GetPlayerInfoByGUID")
	if not get then return "GUID есть, нет GetPlayerInfoByGUID" end
	local ok, _, class, _, _, _, name, realm = pcall(get, guid)
	if not ok then return "GUID есть, ошибка GetPlayerInfoByGUID" end
	if Secret(class) or Secret(name) or Secret(realm) then return "GUID есть, ответ скрыт" end
	if count and class then stats.class = stats.class + 1 end
	return ("GUID есть, класс %s, имя %s, реалм %s"):format(Safe(class), Safe(name), Safe(realm))
end

---------------------------------------------------------------------------
-- Вход и выход
---------------------------------------------------------------------------
function P.Join(name, password)
	if name and name ~= "" and Fold(name) ~= Fold(ChannelName()) then
		if Index() > 0 then P.Leave() end
		db.channel = name
	end
	if name and name ~= "" then db.password = password end
	db.auto = true
	if Index() > 0 then
		Snapshot("уже в канале")
		return
	end
	local join = API("JoinChannelByName")
	if not join then
		Log("вход: нет JoinChannelByName")
		return
	end
	Watch()
	Log("вход в канал %s%s; каналы до входа: %s", ChannelName(), db.password and " с паролем" or "", ChannelList())
	local ok, err = pcall(join, ChannelName(), db.password)
	if not ok then
		Log("вход: ошибка %s", tostring(err))
		return
	end
	C_Timer.After(3, function() Snapshot("через 3 с после входа в канал") end)
end

function P.Leave()
	db.auto = false
	local id = Index()
	if id <= 0 then
		Log("выход: не в канале %s", ChannelName())
		return
	end
	local leave = API("LeaveChannelByName")
	if not leave then
		Log("выход: нет LeaveChannelByName")
		return
	end
	Watch()
	local ok, err = pcall(leave, ChannelName())
	Log("выход из канала %s (был №%d)%s", ChannelName(), id, ok and "" or (": ошибка " .. tostring(err)))
end

-- Автовход после каналов игры, как в прежнем Channel.lua Chillzone: ждём, пока появится канал №1,
-- ещё две секунды, но не дольше JOIN_BY. Если игра вернула канал сама, это видно в журнале.
local function JoinSoon(t, seenAt)
	local id = Index()
	if id > 0 then
		Log("автовход не нужен: канал уже №%d через %d с после входа в мир", id, t)
		return
	end
	local get, first = API("GetChannelName"), nil
	if get then
		local _, n = get(1)
		if not Secret(n) and type(n) == "string" and n ~= "" then first = n end
	end
	if first then seenAt = seenAt or t end
	if t >= JOIN_BY or (seenAt and t - seenAt >= 2) then
		Log("автовход через %d с после входа в мир, канал №1: %s", t, Safe(first))
		P.Join()
		return
	end
	C_Timer.After(1, function() JoinSoon(t + 1, seenAt) end)
end

-- Наш канал в конец списка, за каналами игры (KeepLast прежнего Channel.lua).
function P.Last()
	local id = Index()
	local chat = rawget(_G, "C_ChatInfo")
	local swap = type(chat) == "table" and chat.SwapChatChannelsByChannelIndex
	local infoOf = type(chat) == "table" and chat.GetChannelInfoFromIdentifier
	if id <= 0 then
		Log("перестановка: не в канале")
		return
	end
	if type(swap) ~= "function" or type(infoOf) ~= "function" or not API("GetChannelList") then
		Log("перестановка: нет API")
		return
	end
	Log("перестановка, до: %s", ChannelList())
	local list = { GetChannelList() }
	local stride = type(list[3]) == "boolean" and 3 or 2
	local after = {}
	for i = 1, #list, stride do
		local n = tonumber(list[i])
		local ok, info = pcall(infoOf, list[i + 1])
		if n and n > id and ok and type(info) == "table" and (tonumber(info.zoneChannelID) or 0) > 0 then after[#after + 1] = n end
	end
	table.sort(after)
	local at = id
	for _, n in ipairs(after) do
		local ok, err = pcall(swap, at, n)
		if not ok then
			Log("перестановка %d и %d: ошибка %s", at, n, tostring(err))
			break
		end
		at = n
	end
	Log("перестановка, после: %s", ChannelList())
end

---------------------------------------------------------------------------
-- Отправка
---------------------------------------------------------------------------
local function SendApi()
	local f = API("SendChatMessage")
	if f then return f, "SendChatMessage" end
	local chat = rawget(_G, "C_ChatInfo")
	if type(chat) == "table" and type(chat.SendChatMessage) == "function" then return chat.SendChatMessage, "C_ChatInfo.SendChatMessage" end
end

local function Drop(item)
	for i, other in ipairs(pending) do
		if other == item then
			table.remove(pending, i)
			return true
		end
	end
	return false
end

-- Одна строка в канал. Вызывается синхронно из обработчика нажатия: аппаратное событие
-- есть только в нём. path — откуда отправка, по нему ведутся счётчики.
local function Send(text, path)
	if type(text) ~= "string" or not text:find("%S") then return false end
	local id = Index()
	if id <= 0 then
		Log("отправка (%s) не сделана: нет канала %s, сначала /czp join", path, ChannelName())
		return false
	end
	local send, api = SendApi()
	if not send then
		Log("отправка (%s) не сделана: нет SendChatMessage", path)
		return false
	end
	seq = seq + 1
	local item = { n = seq, text = text, path = path, at = GetTime() }
	pending[#pending + 1] = item
	Count(stats.sent, path)
	Watch()
	Log("отправка #%d (%s): %d байт, сумма %s, канал №%d, блокировка %s, %s, %s — %s",
		item.n, path, #text, Sum(text), id, Lockdown(), Where(), api, Quote(text))
	local ok, err = pcall(send, text, "CHANNEL", nil, id)
	if not ok then
		Drop(item)
		Count(stats.failed, path)
		Log("отправка #%d (%s): ошибка %s", item.n, path, tostring(err))
		return false
	end
	C_Timer.After(ECHO_WAIT, function()
		if Drop(item) then
			Count(stats.lost, path)
			Log("нет эхо #%d (%s) за %d с", item.n, path, ECHO_WAIT)
		end
	end)
	return true
end
P.Send = Send

-- Набор проверочных строк: по одной за нажатие.
local KIT = {
	"Проверка 1: кириллица АБВГДЕЁЖЗ абвгдеёжз, «кавычки» — тире, №5",
	"Check 2: ASCII 0123456789 .,:;!?()[]{}<>@#$%^&*_+=~'\"/\\",
	"Проверка 3: два  пробела, три   пробела и пробел в конце ",
}
do
	local s = "Проверка 4: длина ровно 255 байт "
	while #s + 2 <= 255 do s = s .. "я" end
	if #s < 255 then s = s .. "." end
	KIT[#KIT + 1] = s
end
P.KIT = KIT

local function Kit(path)
	db.kit = (tonumber(db.kit) or 0) % #KIT + 1
	return Send(KIT[db.kit], path)
end

-- Несколько строк за одно нажатие: проходят ли вторая и третья.
local function Multi(rest, path)
	local n, text = rest:match("^(%d+)%s+(.+)$")
	n = tonumber(n)
	if not n or n < 1 or n > MAX_MULTI or not text:find("%S") then
		Print(("multi N текст, N от 1 до %d"):format(MAX_MULTI))
		return
	end
	local label = ("%s x%d"):format(path, n)
	for k = 1, n do Send(("%s (%d/%d)"):format(text, k, n), label) end
end

-- Поле окна и кнопка «Отправить»: текст, а также multi и kit.
local function Submit(path)
	local box = P.frames.box
	if not box then return end
	local text = box:GetText() or ""
	if not text:find("%S") then
		box:ClearFocus()
		return
	end
	box:SetText("")
	local word, rest = Trim(text):match("^(%S+)%s*(.-)$")
	word = word:lower()
	if word == "multi" then
		Multi(rest, path)
	elseif word == "kit" then
		Kit(path)
	else
		Send(text, path)
	end
end
P.Submit = Submit

---------------------------------------------------------------------------
-- Приём
---------------------------------------------------------------------------
local function SecretLine(ours, what)
	if ours then
		stats.secret = stats.secret + 1
		if stats.secret <= 5 or stats.secret % 20 == 0 then Log("строка нашего канала со скрытыми полями (%s), всего %d", what, stats.secret) end
	else
		stats.secretOther = stats.secretOther + 1
		if stats.secretOther <= 3 then Log("строка канала со скрытым именем канала, всего %d", stats.secretOther) end
	end
end

-- Своя строка: ищем отправку с тем же текстом, иначе считаем изменённой самую раннюю из ждущих.
local function Take(text)
	for i, item in ipairs(pending) do
		if item.text == text then return table.remove(pending, i), true end
	end
	if pending[1] then return table.remove(pending, 1), false end
	return nil, false
end

local function OnEcho(text, sender, who)
	local item, exact = Take(text)
	if not item then
		Log("своя строка не из проверки (из чата игры?): %d байт, сумма %s, отправитель %s, %s — %s", #text, Sum(text), sender, who, Quote(text))
		return
	end
	local delay = GetTime() - item.at
	if exact then
		Count(stats.echoed, item.path)
		Log("эхо #%d (%s) через %.2f с: совпало, отправитель %s, %s", item.n, item.path, delay, sender, who)
	else
		Count(stats.changed, item.path)
		Log("эхо #%d (%s) через %.2f с: ИЗМЕНЕНО, отправлено %d байт %s, пришло %d байт %s, расхождение с байта %d — %s",
			item.n, item.path, delay, #item.text, Sum(item.text), #text, Sum(text), FirstDiff(item.text, text), Quote(text))
	end
end

local function OnChannel(text, sender, _, channelName, _, flags, _, index, baseName, _, lineId, guid)
	if Secret(baseName) or Secret(channelName) then
		SecretLine(false)
		return
	end
	if not Ours(baseName, channelName) then return end
	if Secret(text) or Secret(sender) then
		SecretLine(true, "текст или отправитель")
		return
	end
	if type(text) ~= "string" or type(sender) ~= "string" then return end
	if IsMe(sender, guid) then
		OnEcho(text, sender, ClassOf(guid, false))
		return
	end
	stats.heard = stats.heard + 1
	Count(stats.from, sender)
	local flag = (not Secret(flags) and type(flags) == "string" and flags ~= "") and (", флаг " .. flags) or ""
	Log("приём от %s: %d байт, сумма %s, канал №%s, строка %s, %s%s — %s",
		sender, #text, Sum(text), Safe(index), Safe(lineId), ClassOf(guid, true), flag, Quote(text))
end

local function Who(v, prefix)
	if Secret(v) then return prefix .. "скрыто" end
	if type(v) ~= "string" or v == "" then return "" end
	return prefix .. v
end

-- CHAT_MSG_CHANNEL_NOTICE и CHAT_MSG_CHANNEL_NOTICE_USER: (тип, игрок, язык, «5. Канал», второй
-- игрок, флаги, зона, номер, «Канал»). Для бана и кика первый — с кем случилось, второй — кто сделал.
local function OnNotice(kind, notice, player, _, channelName, player2, _, _, _, baseName)
	if Secret(baseName) or Secret(channelName) or Secret(notice) then return end
	if not Ours(baseName, channelName) then return end
	Count(stats.notices, tostring(notice))
	Log("уведомление (%s): %s%s%s", kind, Safe(notice), Who(player, ", игрок "), Who(player2, ", второй "))
end

local function OnMember(joined, _, player, _, channelName, _, _, _, _, baseName)
	if Secret(baseName) or Secret(channelName) then return end
	if not Ours(baseName, channelName) then return end
	if joined then stats.joins = stats.joins + 1 else stats.leaves = stats.leaves + 1 end
	Log("%s: %s", joined and "вошёл в канал" or "вышел из канала", Safe(player))
end

---------------------------------------------------------------------------
-- Фильтр строк и скрытие из окон
---------------------------------------------------------------------------
local FILTER_EVENTS = { "CHAT_MSG_CHANNEL", "CHAT_MSG_CHANNEL_NOTICE", "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE" }

local function Filter(_, _, ...)
	local channelName, baseName = select(4, ...), select(9, ...)
	return Ours(baseName, channelName)
end

local function FilterApi(kind)
	local name = kind .. "MessageEventFilter"
	local f = API("ChatFrame_" .. name)
	if f then return f, "ChatFrame_" .. name end
	local util = rawget(_G, "ChatFrameUtil")
	if type(util) == "table" and type(util[name]) == "function" then return util[name], "ChatFrameUtil." .. name end
end

function P.SetFilter(on)
	on = on and true or false
	db.filter = on
	if on == filtersOn then
		Log("фильтр строк канала уже %s", on and "включён" or "выключен")
		return
	end
	local fn, api = FilterApi(on and "Add" or "Remove")
	if not fn then
		Log("фильтр строк канала: нет API для «%s»", on and "включить" or "выключить")
		return
	end
	for _, event in ipairs(FILTER_EVENTS) do pcall(fn, event, Filter) end
	filtersOn = on
	Watch()
	Log("фильтр строк канала %s (%s)", on and "включён" or "выключен", api)
end

local function ChatFrameFn(kind)
	local f = API("ChatFrame_" .. kind)
	if f then return f, "ChatFrame_" .. kind end
	local util = rawget(_G, "ChatFrameUtil")
	if type(util) == "table" and type(util[kind]) == "function" then return util[kind], "ChatFrameUtil." .. kind end
end

-- hide — убрать канал из всех окон чата; show — вернуть только в первое окно.
function P.Windows(hide)
	local kind = hide and "RemoveChannel" or "AddChannel"
	local fn, api = ChatFrameFn(kind)
	local name, done = ChannelName(), 0
	Watch()
	for i = 1, hide and WindowCount() or 1 do
		local cf = rawget(_G, "ChatFrame" .. i)
		if type(cf) == "table" then
			local ok = false
			if fn then
				ok = pcall(fn, cf, name)
			elseif type(cf[kind]) == "function" then
				ok, api = pcall(cf[kind], cf, name), "ChatFrame:" .. kind
			end
			if ok then done = done + 1 end
		end
	end
	Log("%s: %s, окон %d; окна с каналом теперь: %s", hide and "скрыть из окон" or "вернуть в окно 1", api or "нет API", done, Windows())
end

---------------------------------------------------------------------------
-- Отчёт
---------------------------------------------------------------------------
local function Paths()
	local seen, out = {}, {}
	for _, t in ipairs({ stats.sent, stats.echoed, stats.changed, stats.lost, stats.failed }) do
		for k in pairs(t) do
			if not seen[k] then
				seen[k] = true
				out[#out + 1] = k
			end
		end
	end
	table.sort(out)
	return out
end

local function Pairs(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys)
	local out = {}
	for _, k in ipairs(keys) do out[#out + 1] = ("%s %d"):format(k, t[k]) end
	return #out > 0 and table.concat(out, ", ") or "нет"
end

local function CVar(name)
	local cvar = rawget(_G, "C_CVar")
	local get = (type(cvar) == "table" and type(cvar.GetCVar) == "function" and cvar.GetCVar) or API("GetCVar")
	if not get then return "нет API" end
	local ok, v = pcall(get, name)
	return ok and Safe(v) or "ошибка"
end

local function AddonText(name)
	local addons = rawget(_G, "C_AddOns")
	local loaded = (type(addons) == "table" and addons.IsAddOnLoaded) or API("IsAddOnLoaded")
	local meta = (type(addons) == "table" and addons.GetAddOnMetadata) or API("GetAddOnMetadata")
	if type(loaded) ~= "function" then return "нет API" end
	local ok, on = pcall(loaded, name)
	if not ok or not on then return "не загружен" end
	local version = type(meta) == "function" and select(2, pcall(meta, name, "Version")) or nil
	return "загружен, версия " .. Safe(version)
end

local function ApiText()
	local have, missing = {}, {}
	local chat, util = rawget(_G, "C_ChatInfo"), rawget(_G, "ChatFrameUtil")
	local function Field(t, k) return type(t) == "table" and type(t[k]) == "function" end
	local list = {
		{ "SendChatMessage", API("SendChatMessage") },
		{ "C_ChatInfo.SendChatMessage", Field(chat, "SendChatMessage") },
		{ "C_ChatInfo.InChatMessagingLockdown", Field(chat, "InChatMessagingLockdown") },
		{ "C_ChatInfo.SwapChatChannelsByChannelIndex", Field(chat, "SwapChatChannelsByChannelIndex") },
		{ "JoinChannelByName", API("JoinChannelByName") },
		{ "GetChannelList", API("GetChannelList") },
		{ "GetChatWindowChannels", API("GetChatWindowChannels") },
		{ "GetPlayerInfoByGUID", API("GetPlayerInfoByGUID") },
		{ "DisplayChannelOwner", API("DisplayChannelOwner") },
		{ "ListChannelByName", API("ListChannelByName") },
		{ "ChatFrame_RemoveChannel", API("ChatFrame_RemoveChannel") },
		{ "ChatFrameUtil.RemoveChannel", Field(util, "RemoveChannel") },
		{ "ChatFrame_AddMessageEventFilter", API("ChatFrame_AddMessageEventFilter") },
		{ "ChatFrameUtil.AddMessageEventFilter", Field(util, "AddMessageEventFilter") },
	}
	for _, row in ipairs(list) do
		if row[2] then have[#have + 1] = row[1] else missing[#missing + 1] = row[1] end
	end
	return ("есть: %s; нет: %s"):format(#have > 0 and table.concat(have, ", ") or "ничего", #missing > 0 and table.concat(missing, ", ") or "ничего")
end

function P.Report()
	local out = {}
	local function Add(fmt, ...) out[#out + 1] = fmt:format(...) end
	local server = API("GetServerTime") and GetServerTime() or time()
	Add("ChillzoneProbe %s, отчёт %s UTC", VERSION, date("!%Y-%m-%d %H:%M:%S", server))
	local name, realm = MyName()
	local guild, rank
	if API("GetGuildInfo") then guild, rank = GetGuildInfo("player") end
	Add("Игрок: %s, реалм %s (%s), GUID %s, фракция %s, гильдия %s (%s), уровень %s",
		Safe(name), Safe(realm), Safe(API("GetRealmName") and GetRealmName()), MyGuid() and "есть" or "нет",
		Safe(API("UnitFactionGroup") and UnitFactionGroup("player")), Safe(guild), Safe(rank),
		Safe(API("UnitLevel") and UnitLevel("player")))
	local version, build, _, toc
	if API("GetBuildInfo") then version, build, _, toc = GetBuildInfo() end
	Add("Клиент: %s (%s), интерфейс %s, язык %s, фильтр брани %s",
		Safe(version), Safe(build), Safe(toc), Safe(API("GetLocale") and GetLocale()), CVar("profanityFilter"))
	Add("Chillzone: %s", AddonText("Chillzone"))
	Add("API: %s", ApiText())
	if #refused > 0 then Add("События, которых нет в клиенте: %s", table.concat(refused, ", ")) end
	Add("Канал: %s №%d, окна с ним: %s, фильтр строк %s, блокировка %s, %s",
		ChannelName(), Index(), Windows(), filtersOn and "включён" or "выключен", Lockdown(), Where())
	Add("Каналы: %s", ChannelList())
	Add("Счётчики с загрузки интерфейса или очистки журнала:")
	local paths = Paths()
	if #paths == 0 then Add("  отправок не было") end
	for _, path in ipairs(paths) do
		Add("  %s: отправлено %d, эхо %d, изменено %d, без эхо %d, ошибок %d", path,
			stats.sent[path] or 0, stats.echoed[path] or 0, stats.changed[path] or 0, stats.lost[path] or 0, stats.failed[path] or 0)
	end
	local senders = 0
	for _ in pairs(stats.from) do senders = senders + 1 end
	Add("  принято %d строк от %d игроков: %s", stats.heard, senders, Pairs(stats.from))
	Add("  GUID у чужих строк: есть %d, нет %d, класс получен %d", stats.guid, stats.noGuid, stats.class)
	Add("  уведомления канала: %s; вошли %d, вышли %d", Pairs(stats.notices), stats.joins, stats.leaves)
	Add("  скрытые значения: в нашем канале %d, имя канала %d; заблокировано игрой %d", stats.secret, stats.secretOther, stats.blocked)
	Add("---- журнал ----")
	for _, line in ipairs(db and db.log or early) do out[#out + 1] = line end
	return (table.concat(out, "\n"):gsub("|", "||"))
end

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------
local W, H = 680, 470
local HINT = "Enter в поле — отправить в канал. multi 3 текст — три строки за нажатие, kit — следующая строка набора. /czp help — все команды."
local COPY_HINT = "Ctrl+A и Ctrl+C — скопировать отчёт целиком. Esc или «Назад» — к журналу."

local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function()
		local ok, err = pcall(fn)
		if not ok then Log("ошибка кнопки «%s»: %s", text, tostring(err)) end
	end)
	return b
end

local function StatusText()
	return ("Канал %s №%d; отправлено %d, эхо %d, изменено %d, без эхо %d; принято %d; блокировка %s"):format(
		ChannelName(), Index(), Total(stats.sent), Total(stats.echoed), Total(stats.changed), Total(stats.lost), stats.heard, Lockdown())
end

Refresh = function()
	local f = P.frames
	if f.main and f.main:IsShown() then f.status:SetText(StatusText()) end
end

local function RenderLog()
	local f = P.frames
	f.view:Clear()
	local log = db and db.log or early
	for i = math.max(1, #log - VIEW_LINES + 1), #log do
		f.view:AddMessage((log[i]:gsub("|", "||")), 0.85, 0.85, 0.85)
	end
	f.view:ScrollToBottom()
end

local function Back()
	local f = P.frames
	P.copying = false
	f.copyBox:ClearFocus()
	f.export:Hide()
	f.back:Hide()
	f.view:Show()
	f.hint:SetText(HINT)
	RenderLog()
end

function P.Copy()
	local f = P.Show()
	P.copying = true
	f.view:Hide()
	f.export:Show()
	f.back:Show()
	local report = P.Report()
	f.measure:SetText(report)
	f.copyBox:SetHeight(math.max(300, f.measure:GetStringHeight() + 16))
	f.copyBox:SetText(report)
	f.export:SetVerticalScroll(0)
	f.copyBox:SetFocus()
	f.copyBox:HighlightText()
	f.hint:SetText(COPY_HINT)
	Log("отчёт открыт для копирования")
end

function P.Clear()
	if db then db.log = {} end
	ResetStats()
	Log("журнал и счётчики очищены")
	if P.frames.view then RenderLog() end
end

local function HookLinks()
	local hook = API("hooksecurefunc")
	if not hook then return end
	local function OnInsert(text)
		local box = P.frames.box
		if box and box:HasFocus() and type(text) == "string" and not Secret(text) then box:Insert(text) end
	end
	local util = rawget(_G, "ChatFrameUtil")
	if type(util) == "table" and type(util.InsertLink) == "function" then
		pcall(hook, util, "InsertLink", OnInsert)
	elseif API("ChatEdit_InsertLink") then
		pcall(hook, "ChatEdit_InsertLink", OnInsert)
	end
end

function P.Build()
	local f = P.frames
	if f.main then return f end
	local main = CreateFrame("Frame", "ChillzoneProbeFrame", UIParent, "BasicFrameTemplateWithInset")
	f.main = main
	main:SetSize(W, H)
	main:SetPoint("CENTER", 0, 60)
	main:SetFrameStrata("MEDIUM")
	main:SetToplevel(true)
	main:SetClampedToScreen(true)
	main:SetMovable(true)
	main:EnableMouse(true)
	main:RegisterForDrag("LeftButton")
	main:SetScript("OnDragStart", main.StartMoving)
	main:SetScript("OnDragStop", main.StopMovingOrSizing)
	main:SetScript("OnShow", function() Refresh() end)
	local title = "Chillzone: проверка канала " .. VERSION
	if type(main.SetTitle) == "function" then
		main:SetTitle(title)
	else
		local text = main.TitleText or (main.TitleContainer and main.TitleContainer.TitleText)
		if text then text:SetText(title) end
	end
	local close = main.CloseButton or rawget(_G, "ChillzoneProbeFrameCloseButton")
	if close then close:SetScript("OnClick", function() main:Hide() end) end
	if type(rawget(_G, "UISpecialFrames")) == "table" then tinsert(UISpecialFrames, "ChillzoneProbeFrame") end

	local join = Button(main, "Войти", 80, function() P.Join() end)
	join:SetPoint("TOPLEFT", 12, -30)
	local leave = Button(main, "Выйти", 80, function() P.Leave() end)
	leave:SetPoint("LEFT", join, "RIGHT", 6, 0)
	local state = Button(main, "Состояние", 100, function() Snapshot("по кнопке") end)
	state:SetPoint("LEFT", leave, "RIGHT", 6, 0)
	local kit = Button(main, "Набор", 80, function() Kit("кнопка") end)
	kit:SetPoint("LEFT", state, "RIGHT", 6, 0)
	local copy = Button(main, "Копировать отчёт", 150, function() P.Copy() end)
	copy:SetPoint("LEFT", kit, "RIGHT", 6, 0)
	local clear = Button(main, "Очистить", 100, function() P.Clear() end)
	clear:SetPoint("LEFT", copy, "RIGHT", 6, 0)

	f.status = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.status:SetPoint("TOPLEFT", 14, -58)
	f.status:SetPoint("TOPRIGHT", -14, -58)
	f.status:SetJustifyH("LEFT")

	local view = CreateFrame("ScrollingMessageFrame", nil, main)
	view:SetPoint("TOPLEFT", 14, -76)
	view:SetPoint("BOTTOMRIGHT", -14, 66)
	view:SetFontObject("ChatFontNormal")
	view:SetJustifyH("LEFT")
	view:SetFading(false)
	view:SetMaxLines(VIEW_LINES + 100)
	view:EnableMouseWheel(true)
	view:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	f.view = view

	local export = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
	export:SetPoint("TOPLEFT", 14, -76)
	export:SetPoint("BOTTOMRIGHT", -34, 66)
	local copyBox = CreateFrame("EditBox", nil, export)
	copyBox:SetMultiLine(true)
	copyBox:SetAutoFocus(false)
	copyBox:SetFontObject("ChatFontNormal")
	copyBox:SetTextInsets(4, 4, 4, 4)
	copyBox:SetWidth(W - 60)
	copyBox:SetHeight(300)
	copyBox:SetMaxLetters(0)
	export:SetScrollChild(copyBox)
	copyBox:SetScript("OnTextChanged", function() export:UpdateScrollChildRect() end)
	copyBox:SetScript("OnEscapePressed", function() Back() end)
	f.export, f.copyBox = export, copyBox
	f.measure = main:CreateFontString(nil, "OVERLAY", "ChatFontNormal")
	f.measure:SetWidth(W - 68)
	f.measure:SetWordWrap(true)
	f.measure:Hide()
	export:Hide()

	f.hint = main:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.hint:SetPoint("BOTTOMLEFT", 14, 42)
	f.hint:SetPoint("BOTTOMRIGHT", -14, 42)
	f.hint:SetJustifyH("LEFT")
	f.hint:SetText(HINT)

	local box = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
	box:SetSize(W - 170, 22)
	box:SetPoint("BOTTOMLEFT", 20, 12)
	box:SetAutoFocus(false)
	box:SetMaxBytes(255)
	box:SetScript("OnEnterPressed", function()
		local ok, err = pcall(Submit, "поле")
		if not ok then Log("ошибка поля: %s", tostring(err)) end
	end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	f.box = box
	local send = Button(main, "Отправить", 120, function() Submit("кнопка") end)
	send:SetPoint("LEFT", box, "RIGHT", 10, 0)
	f.back = Button(main, "Назад", 120, function() Back() end)
	f.back:SetPoint("BOTTOMRIGHT", -14, 12)
	f.back:Hide()

	main:Hide()
	RenderLog()
	return f
end

function P.Show()
	local f = P.Build()
	f.main:Show()
	Refresh()
	return f
end

function P.Toggle()
	local f = P.Build()
	if f.main:IsShown() then f.main:Hide() else P.Show() end
end

---------------------------------------------------------------------------
-- Команды
---------------------------------------------------------------------------
local HELP = {
	"/czp — окно журнала; /czp help — эта подсказка",
	"/czp join [канал] [пароль] — войти (по умолчанию " .. DEFAULT_CHANNEL .. "), /czp leave — выйти",
	"/czp текст или /czp say текст — отправить из слэш-команды; в окне — Enter в поле или кнопка",
	"/czp multi 3 текст — три строки за одно нажатие; /czp kit — следующая строка набора",
	"/czp timer [секунд] текст — отправка из таймера для сравнения (игра может её заблокировать)",
	"/czp state, owner, members — состояние, владелец канала, список участников",
	"/czp filter on или off, hide, show, last — фильтр строк, скрыть из окон, вернуть, канал в конец",
	"/czp copy — отчёт для копирования, /czp clear — очистить журнал и счётчики",
}

local commands = {}

commands.help = function()
	for _, line in ipairs(HELP) do Print(line) end
end

commands.join = function(rest)
	local name, password = rest:match("^(%S+)%s*(%S*)")
	P.Join(name, password ~= "" and password or nil)
end

commands.leave = function() P.Leave() end
commands.say = function(rest, path) Send(rest, path) end
commands.multi = function(rest, path) Multi(rest, path) end
commands.kit = function(_, path) Kit(path) end
commands.state = function() Snapshot("по команде") end
commands.last = function() P.Last() end
commands.hide = function() P.Windows(true) end
commands.show = function() P.Windows(false) end
commands.copy = function() P.Copy() end
commands.clear = function() P.Clear() end

commands.timer = function(rest)
	local delay, text = rest:match("^(%d+%.?%d*)%s+(.+)$")
	delay = tonumber(delay)
	if not delay then delay, text = 1, rest end
	if not text:find("%S") then
		Print("timer [секунд] текст")
		return
	end
	local label = ("таймер %s с"):format(delay)
	Log("отправка (%s) запланирована", label)
	C_Timer.After(delay, function()
		local ok, err = pcall(Send, text, label)
		if not ok then Log("ошибка отправки из таймера: %s", tostring(err)) end
	end)
end

commands.filter = function(rest)
	local arg = Trim(rest):lower()
	if arg == "on" then
		P.SetFilter(true)
	elseif arg == "off" then
		P.SetFilter(false)
	else
		Print("filter on или filter off")
	end
end

local function Call(api, what)
	local f = API(api)
	Watch()
	if not f then
		Log("%s: нет %s", what, api)
		return
	end
	local ok, err = pcall(f, ChannelName())
	Log("%s: запрошено%s", what, ok and "" or (", ошибка " .. tostring(err)))
end

commands.owner = function() Call("DisplayChannelOwner", "владелец канала") end
commands.members = function() Call("ListChannelByName", "участники канала") end

-- Пробелы в конце не срезаются: они тоже часть проверки «байт в байт».
function P.Slash(input)
	if not db then return end
	local text = (input or ""):gsub("^%s+", "")
	if text == "" then
		P.Toggle()
		return
	end
	local word, rest = text:match("^(%S+)%s?(.*)$")
	local fn = commands[word:lower()]
	if fn then fn(rest, "слэш") else Send(text, "слэш") end
end

SLASH_CHILLZONEPROBE1 = "/czp"
SLASH_CHILLZONEPROBE2 = "/чзп"
SlashCmdList.CHILLZONEPROBE = function(input)
	local ok, err = pcall(P.Slash, input)
	if not ok then Log("ошибка команды: %s", tostring(err)) end
end

---------------------------------------------------------------------------
-- События
---------------------------------------------------------------------------
local function WatchLockdown()
	local now = Lockdown()
	if now ~= lockdownSeen then
		if lockdownSeen ~= nil then Log("блокировка сообщений: %s, %s", now, Where()) end
		lockdownSeen = now
	end
	C_Timer.After(2, WatchLockdown)
end

local function Init()
	local saved = ChillzoneProbeDB
	if type(saved) ~= "table" then saved = {} end
	if type(saved.log) ~= "table" then saved.log = {} end
	if type(saved.channel) ~= "string" or saved.channel == "" then saved.channel = DEFAULT_CHANNEL end
	ChillzoneProbeDB = saved
	db = saved
	for _, line in ipairs(early) do db.log[#db.log + 1] = line end
	early = {}
	while #db.log > MAX_LOG do table.remove(db.log, 1) end
	Log("---- ChillzoneProbe %s загружен, канал %s, автовход %s ----", VERSION, db.channel, db.auto and "да" or "нет")
	if #refused > 0 then Log("событий нет в клиенте: %s", table.concat(refused, ", ")) end
	HookLinks()
	if db.filter then P.SetFilter(true) end
end

local handlers = {}
local started = false

handlers.ADDON_LOADED = function(name)
	if name == ADDON and not db then Init() end
end

handlers.PLAYER_ENTERING_WORLD = function(initial, reload)
	if not db then return end
	local name, realm = MyName()
	local kind = initial and "первый вход" or (reload and "перезагрузка интерфейса" or "смена мира")
	Log("вход в мир (%s): %s, реалм %s, GUID %s", kind, Safe(name), Safe(realm), MyGuid() and "есть" or "нет")
	Snapshot("при входе в мир")
	if not started then
		started = true
		WatchLockdown()
	end
	if not (initial or reload) then return end
	C_Timer.After(5, function() Snapshot("через 5 с после входа в мир") end)
	C_Timer.After(20, function() Snapshot("через 20 с после входа в мир") end)
	if db.auto then C_Timer.After(1, function() JoinSoon(1, nil) end) end
end

handlers.ZONE_CHANGED_NEW_AREA = function()
	if db then Log("зона: %s, блокировка %s", Where(), Lockdown()) end
end

handlers.CHAT_MSG_CHANNEL = OnChannel
handlers.CHAT_MSG_CHANNEL_NOTICE = function(...) OnNotice("канал", ...) end
handlers.CHAT_MSG_CHANNEL_NOTICE_USER = function(...) OnNotice("игрок", ...) end
handlers.CHAT_MSG_CHANNEL_JOIN = function(...) OnMember(true, ...) end
handlers.CHAT_MSG_CHANNEL_LEAVE = function(...) OnMember(false, ...) end

handlers.CHAT_MSG_CHANNEL_LIST = function(text, _, _, channelName, _, _, _, _, baseName)
	if Secret(baseName) or Secret(channelName) or not Ours(baseName, channelName) then return end
	Log("участники: %s", Safe(text))
end

handlers.CHANNEL_PASSWORD_REQUEST = function(name)
	if Ours(name) then Log("игра просит пароль канала %s", Safe(name)) end
end

handlers.CHAT_MSG_SYSTEM = function(text)
	if Watching() then Log("система: %s", Safe(text)) end
end

handlers.UI_ERROR_MESSAGE = function(_, message)
	if Watching() then Log("ошибка игры: %s", Safe(message)) end
end

handlers.ADDON_ACTION_BLOCKED = function(addon, func)
	stats.blocked = stats.blocked + 1
	Log("игра заблокировала %s, аддон %s", Safe(func), Safe(addon))
end

handlers.ADDON_ACTION_FORBIDDEN = function(addon, func)
	stats.blocked = stats.blocked + 1
	Log("игра запретила %s, аддон %s", Safe(func), Safe(addon))
end

local events = CreateFrame("Frame")
events:SetScript("OnEvent", function(_, event, ...)
	local fn = handlers[event]
	if not fn then return end
	local ok, err = pcall(fn, ...)
	if not ok then Log("ошибка в %s: %s", event, tostring(err)) end
end)
do
	local names = {}
	for event in pairs(handlers) do names[#names + 1] = event end
	table.sort(names)
	for _, event in ipairs(names) do
		if not pcall(events.RegisterEvent, events, event) then refused[#refused + 1] = event end
	end
end
