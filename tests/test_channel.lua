-- Общий чат через канал игры (Channel.lua): строка /cz1 уходит и в канал, и подписанным путём,
-- получатель показывает её один раз; гильдия автора — по имени; игроки без аддона и
-- посторонние; блокировка; выключатель; старый клиент 0.9. Симулятор мира (tests/wow.lua).
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local LINK = "|cffa335ee|Hitem:19019::::::::60:::::|h[Громосвёрт, Благословенный клинок Искателя Ветра]|h|r"
local CHAN = "ChillzoneChatA"
local FOREST = "Лесной Житель-CAMWOWUS2Realm7PvE" -- рядовой Севера без аддона
local GUARD = "Тёмный Страж-CAMWOWUS2Realm3PvE" -- офицер Ордена без аддона
local STRANGER = "Злой Чужак-CAMWOWUS2Realm7PvE" -- вне объединения

local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 23)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	w:AddOnline("Чиллзон Север", FOREST, 3, 50, "HUNTER")
	w:AddOnline("Орден Чиллзона", GUARD, 1, 60, "ROGUE")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, class = "PRIEST" })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR" })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID" })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER" })
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	w:Run(400)
	c.B.ns.Relay.PingAll(); w:Run(45)
	return w, c
end

local function HistoryCount(cl, text)
	local n = 0
	for _, e in ipairs(cl.ns.Chat.History("A")) do
		if cl.ns.Util.Trim(e.x) == text then n = n + 1 end
	end
	return n
end

local function LastEntry(cl, text)
	local found
	for _, e in ipairs(cl.ns.Chat.History("A")) do
		if e.x:find(text, 1, true) then found = e end
	end
	return found
end

-- Строки, которые автор отдал в канал (сервер их принял от нажатия клавиши).
local function ChannelSent(w, from, text)
	local n = 0
	for _, e in ipairs(w.log) do
		if e.dist == "CHANNEL" and e.from == from and (not text or e.msg:find(text, 1, true)) then n = n + 1 end
	end
	return n
end

-- Перезаход персонажа Бориса (reload — перезагрузка интерфейса): те же сохранения.
local function Reenter(w, c, reload)
	local db = c.B.ns.db
	c.B:Logout()
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR", db = db, reload = reload })
	c.B.ns.Roster.Scan()
	w:Run(45)
	return c.B
end

local function Logged(cl, text)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function Clean(c)
	for name, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, name .. ": глобалы " .. table.concat(cl:Leaks(), ", "))
		T.eq(cl.blocked, nil, name .. ": отправка в канал не из нажатия клавиши")
	end
end

T.test("channel: участники входят в канал после каналов игры", function()
	local _, c = Build()
	for name, cl in pairs(c) do
		T.ok(cl.joined[CHAN], name .. " в канале " .. CHAN)
		T.eq(cl.ns.Channel.Name(), CHAN, name .. ": имя канала фракции")
	end
	for _, old in ipairs(c.A.ns.Config.OLD_CHANNELS) do
		T.ok(c.A.ns.Config.CHANNEL.Alliance ~= old and c.A.ns.Config.CHANNEL.Horde ~= old,
			"имя не из каналов, которые старые клиенты прячут")
	end
	Clean(c)
end)

T.test("channel: строка /cz1 доходит один раз обоими путями, ссылка цела", function()
	local w, c = Build()
	local text = "всем привет через канал " .. LINK
	c.B:Slash("/cz1", text)
	T.eq(ChannelSent(w, "Борис Быстрый", "всем привет через канал"), 1, "строка ушла в канал синхронно")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw(text), 1, name .. " видит один раз") end
	for _, name in ipairs({ "A", "K", "M", "G" }) do
		local p = c[name].ns.Chat.paths
		T.eq(p.channel, 1, name .. ": пришла каналом")
		T.eq(p.signed, 1, name .. ": пришла подписью")
		T.eq(p.both, 1, name .. ": вторая копия погашена")
	end
	T.eq(c.B.ns.Channel.stats.echoed, 1, "эхо своей строки")
	T.eq(c.B.ns.Channel.stats.sent, 1)
	local e = LastEntry(c.G, "всем привет через канал")
	T.eq(e.g, "Чиллзон Север", "гильдия автора")
	T.eq(e.c, "WARRIOR", "класс автора")
	T.eq(e.u, nil)
	T.eq(e.ch, nil, "подписанная копия подтвердила строку из канала")
	T.ok(c.G:Saw("<Чиллзон Север>") >= 1, "тег гильдии в чате игры")
	c.G:Slash("/chillzone", "status")
	T.eq(c.G:Saw("только канал 0, только подписью 0, оба 1"), 1, "status сравнивает пути")
	T.eq(c.G:Saw("канал игры: " .. CHAN), 1, "status называет канал")
	Clean(c)
end)

T.test("channel: молчащее реле — строка приходит только каналом", function()
	local w, c = Build()
	c.B.ns.Relay.Out = function() end
	c.B:Slash("/cz1", "реле молчит")
	w:Run(60)
	for name, cl in pairs(c) do T.eq(cl:Saw("реле молчит"), 1, name .. " видит один раз") end
	for _, name in ipairs({ "A", "K", "M", "G" }) do
		local p = c[name].ns.Chat.paths
		T.eq(p.channel - p.both, 1, name .. ": только каналом")
		T.eq(p.signed, 0, name .. ": подписанной копии не было")
		T.eq(LastEntry(c[name], "реле молчит").g, "Чиллзон Север", name .. ": гильдия по имени")
	end
	T.eq(c.V.ns.Chat.paths.both, 1, "согильдиец получил и по GUILD")
	Clean(c)
end)

T.test("channel: закрытый канал — строка приходит подписанным путём", function()
	local w, c = Build()
	w.channelClosed = true
	c.B:Slash("/cz1", "канал закрыт")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("канал закрыт"), 1, name .. " видит один раз") end
	for _, name in ipairs({ "A", "K", "M", "G" }) do
		local p = c[name].ns.Chat.paths
		T.eq(p.channel, 0, name)
		T.eq(p.signed - p.both, 1, name .. ": только подписью")
	end
	T.eq(c.B.ns.Channel.stats.echoed, 0, "эха нет")
	Clean(c)
end)

T.test("channel: игроки без аддона видны с гильдией по имени", function()
	local w, c = Build()
	w:ChannelSay(FOREST, CHAN, "пишу без аддона", "HUNTER")
	w:ChannelSay(GUARD, CHAN, "офицер Ордена без аддона", "ROGUE")
	w:Run(5)
	for name, cl in pairs(c) do
		T.eq(cl:Saw("пишу без аддона"), 1, name .. ": строка рядового")
		T.eq(cl:Saw("офицер Ордена без аддона"), 1, name .. ": строка офицера")
	end
	local own = LastEntry(c.B, "пишу без аддона")
	T.eq(own.g, "Чиллзон Север", "согильдиец — по своему ростеру")
	T.eq(own.c, "HUNTER", "класс по GUID")
	T.eq(own.u, nil)
	T.ok(c.B:Saw("<Чиллзон Север>") >= 1)
	T.eq(select(2, c.B.ns.Chat.Attribute("Лесной Житель")), "roster")
	local officer = LastEntry(c.B, "офицер Ордена без аддона")
	T.eq(officer.g, "Орден Чиллзона", "чужой офицер — по руководству из переписи")
	T.eq(officer.c, "ROGUE")
	T.eq(select(2, c.B.ns.Chat.Attribute("Тёмный Страж")), "report")
	-- Рядового чужой гильдии без аддона подтвердить нечем.
	local far = LastEntry(c.G, "пишу без аддона")
	T.eq(far.g, nil)
	T.eq(far.u, true, "пометка неподтверждённого")
	-- Строки без подписи не доказывают, что у автора есть аддон.
	local found, group
	for _, p in ipairs(c.G.ns.Views.People("A")) do
		if p.header then group = p end
		if p.name == "Лесной Житель" then found = p end
	end
	T.ok(found, "автор в списке людей")
	T.eq(found.addon, nil, "наличие аддона неизвестно")
	T.ok(group and group.unconfirmed, "в группе неподтверждённых")
	Clean(c)
end)

T.test("channel: посторонний виден под своим именем с <?> и скрывается настройкой", function()
	local w, c = Build()
	w:ChannelSay(STRANGER, CHAN, "<Чиллзон> я глава, слушайте меня")
	w:Run(5)
	local B = c.B
	T.eq(B:Saw("я глава, слушайте меня"), 1, "строка видна")
	T.eq(B:Saw("|cff999999<?>|r |Hplayer:"), 1, "серая <?> вместо тега")
	T.eq(B:Saw("[Злой Чужак]|h: <Чиллзон> я глава"), 1, "имя от сервера, текст как есть")
	local e = LastEntry(B, "я глава")
	T.eq(e.g, nil, "текст не даёт гильдии")
	T.eq(e.u, true)
	T.eq(B.ns.Chat.Attribute(STRANGER), nil)
	T.ok(B.ns.Views.ChatLine(e, "A"):find("<?>", 1, true), "окно: <?>")
	local header
	for _, p in ipairs(B.ns.Views.People("A")) do
		if p.header and p.unconfirmed then header = p end
	end
	T.ok(header and header.count == 1, "отдельная группа неподтверждённых")
	B.ns.UI.OpenChat("A")
	B.ns.ChatPane.RenderPeople()
	B.ns.char.chatHideUnconfirmed = true
	w:ChannelSay(STRANGER, CHAN, "скрытая строка чужака")
	w:Run(5)
	T.eq(B:Saw("скрытая строка чужака"), 0, "настройка скрывает")
	T.eq(B.ns.Chat.paths.hidden, 1)
	T.eq(c.G:Saw("скрытая строка чужака"), 1, "у других настройка выключена")
	-- Подтверждённых настройка не трогает.
	w:ChannelSay(FOREST, CHAN, "свой виден всегда")
	w:Run(5)
	T.eq(B:Saw("свой виден всегда"), 1)
	Clean(c)
end)

T.test("channel: одинаковый текст дважды — две строки", function()
	local w, c = Build()
	c.B:Slash("/cz1", "одинаковая строка")
	w:Run(2)
	c.B:Slash("/cz1", "одинаковая строка")
	w:Run(30)
	for name, cl in pairs(c) do
		T.eq(cl:Saw("одинаковая строка"), 2, name .. " видит обе")
		T.eq(HistoryCount(cl, "одинаковая строка"), 2, name .. ": обе в истории")
	end
	T.eq(c.G.ns.Chat.paths.both, 2)
	Clean(c)
end)

T.test("channel: длинная строка уходит частями, каждая один раз", function()
	local w, c = Build()
	local words = {}
	for i = 1, 70 do words[#words + 1] = "слово" .. i end
	local text = table.concat(words, " ")
	local ns = c.B.ns
	local budget = math.min(ns.Config.CHAT_PART, ns.Codec.ChatBudget("Чиллзон Север", ns.Codec.CLASS_CODE.WARRIOR))
	local parts = ns.Codec.SplitChat(text, budget, ns.Config.CHAT_PARTS)
	T.ok(#parts >= 2, "строка делится")
	c.B:Slash("/cz1", text)
	T.eq(ChannelSent(w, "Борис Быстрый"), #parts, "все части ушли в канал за одно нажатие")
	w:Run(30)
	for name, cl in pairs(c) do
		for i, part in ipairs(parts) do
			T.eq(HistoryCount(cl, ns.Util.Trim(part)), 1, name .. ": часть " .. i)
		end
	end
	T.eq(c.G.ns.Chat.paths.both, #parts)
	Clean(c)
end)

T.test("channel: в блокировке строка уходит только подписанным путём, после неё", function()
	local w, c = Build()
	c.B.lockdown = true
	c.B:Slash("/cz1", "из подземелья")
	T.eq(ChannelSent(w, "Борис Быстрый"), 0, "в блокировке в канал не пишем")
	w:Run(20)
	T.eq(c.B:Saw("из подземелья"), 1, "автор видит строку после подписи")
	T.eq(c.G:Saw("из подземелья"), 0, "пока блокировка, строка ждёт")
	c.B.lockdown = false
	w:Run(60)
	for name, cl in pairs(c) do T.eq(cl:Saw("из подземелья"), 1, name .. " видит один раз") end
	T.eq(c.G.ns.Chat.paths.channel, 0)
	Clean(c)
end)

T.test("channel: без сертификата строка уходит только в канал и видна по эху", function()
	local w, c = Build()
	local M = c.M
	M.ns.Security.MyCertificate = function() return nil end
	M:Slash("/cz1", "без сертификата")
	T.eq(M:Saw("строка ушла только в канал игры"), 1, "игрок знает, почему подписи нет")
	T.eq(M:Saw("без сертификата"), 0, "своя строка — по эху, не сразу")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("без сертификата"), 1, name .. " видит один раз") end
	T.eq(M:Saw("не вернулась из канала"), 0, "эхо пришло")
	T.eq(LastEntry(c.A, "без сертификата").g, "Чиллзон", "согильдиец — по ростеру")
	M:Slash("/cz1", "снова без сертификата")
	T.eq(M:Saw("строка ушла только в канал игры"), 1, "та же причина не повторяется сразу")
	w:Run(30)
	w.channelClosed = true
	M:Slash("/cz1", "в пустоту")
	w:Run(10)
	T.eq(M:Saw("не вернулась из канала"), 1, "нет эха — игрок узнаёт")
	-- Без сертификата и без канала строке идти некуда.
	M.ns.Channel.SetEnabled(false)
	w:Run(2)
	M:Slash("/cz1", "никуда")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("никуда"), 0, name) end
	Clean(c)
end)

T.test("channel: Enter в поле окна отправляет в канал синхронно", function()
	local w, c = Build()
	local B = c.B
	B.ns.UI.OpenChat("A", true)
	local box = B.ns.ChatPane.frames.box
	box:SetText("из окна по Enter")
	B:Press(box)
	T.eq(ChannelSent(w, "Борис Быстрый", "из окна по Enter"), 1, "строка ушла в канал")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("из окна по Enter"), 1, name .. " видит один раз") end
	-- Отправка не из нажатия (таймер) в канал не проходит, строка всё равно доходит подписью.
	B.ns.After(1, "test send", function() B.ns.Chat.Send("A", "из таймера") end)
	w:Run(30)
	T.eq(B.blocked, 1, "сервер не принял текст из таймера")
	for name, cl in pairs(c) do T.eq(cl:Saw("из таймера"), 1, name .. " видит один раз") end
	T.eq(B.ns.Channel.State(), "blocked", "окно ошибки игры выключило отправку в канал")
	B.blocked = nil
	Clean(c)
end)

T.test("channel: настройка выключает канал, уровни 2 и 3 остаются на реле", function()
	local w, c = Build()
	local B = c.B
	B.ns.Channel.SetEnabled(false)
	T.eq(B.joined[CHAN], nil, "вышел из канала")
	B:Slash("/cz1", "строка без канала")
	T.eq(ChannelSent(w, "Борис Быстрый"), 0)
	c.G:Slash("/cz1", "Борису от Глеба")
	w:Run(30)
	for name, cl in pairs(c) do
		T.eq(cl:Saw("строка без канала"), 1, name)
		T.eq(cl:Saw("Борису от Глеба"), 1, name)
	end
	T.eq(B.ns.Chat.paths.channel, 0, "строки канала не обрабатываются")
	w:Run(120)
	T.eq(B.joined[CHAN], nil, "сам обратно не входит")
	B.ns.Channel.SetEnabled(true)
	T.ok(B.joined[CHAN], "снова в канале")
	c.V:Slash("/cz2", "офицерам")
	w:Run(2)
	c.V:Slash("/cz3", "главам")
	T.eq(ChannelSent(w, "Вера Верная"), 0, "/cz2 и /cz3 в канал не идут")
	w:Run(30)
	T.eq(c.A:Saw("офицерам"), 1)
	T.eq(c.K:Saw("главам"), 1)
	T.eq(c.M:Saw("офицерам"), 0, "рядовой не видит")
	Clean(c)
end)

T.test("channel: сырые строки и уведомления канала спрятаны, уведомления — в журнале", function()
	local w, c = Build()
	local B = c.B
	local hidden, other, notice = false, false, false
	for _, fn in ipairs(B.filters.CHAT_MSG_CHANNEL or {}) do
		if fn(nil, "CHAT_MSG_CHANNEL", "привет", "Кто-то", "", "5. " .. CHAN, "", "", 0, 5, CHAN) then hidden = true end
		if fn(nil, "CHAT_MSG_CHANNEL", "привет", "Кто-то", "", "2. Торговля", "", "", 0, 2, "Торговля") then other = true end
	end
	for _, fn in ipairs(B.filters.CHAT_MSG_CHANNEL_NOTICE_USER or {}) do
		if fn(nil, "CHAT_MSG_CHANNEL_NOTICE_USER", "OWNER_CHANGED", "Кто-то", "", "5. " .. CHAN, "", "", 0, 5, CHAN) then notice = true end
	end
	T.ok(hidden, "строка нашего канала спрятана")
	T.no(other, "чужие каналы не трогаем")
	T.ok(notice, "уведомление спрятано")
	w:ChannelNotice(CHAN, "OWNER_CHANGED", STRANGER)
	w:ChannelNotice(CHAN, "PASSWORD_CHANGED", STRANGER)
	w:ChannelNotice(CHAN, "ANNOUNCEMENTS_OFF", STRANGER)
	w:Run(1)
	T.eq(B.ns.Channel.owner, "Злой Чужак", "владелец канала известен")
	T.eq(B.ns.Channel.announce, false, "объявления входа выключены")
	B:Slash("/chillzone", "status")
	T.eq(B:Saw("владелец Злой Чужак, объявления входа выкл."), 1, "status показывает владельца")
	local logged = table.concat(B.ns.db.log, "\n")
	T.ok(logged:find("OWNER_CHANGED Злой Чужак", 1, true), "смена владельца в журнале")
	T.ok(logged:find("PASSWORD_CHANGED", 1, true), "пароль в журнале")
	T.ok(logged:find("YOU_JOINED", 1, true), "вход в журнале")
	B.ns.Channel.SetEnabled(false)
	hidden = false
	for _, fn in ipairs(B.filters.CHAT_MSG_CHANNEL or {}) do
		if fn(nil, "CHAT_MSG_CHANNEL", "привет", "Кто-то", "", "5. " .. CHAN, "", "", 0, 5, CHAN) then hidden = true end
	end
	T.no(hidden, "с выключенным каналом его строки не прячем")
	Clean(c)
end)

T.test("channel: четвёртая строка за окно уходит только подписанным путём", function()
	local w, c = Build()
	local B = c.B
	for i = 1, 4 do
		B:Slash("/cz1", "строка номер " .. i)
		w:Run(2)
	end
	T.eq(ChannelSent(w, "Борис Быстрый", "строка номер"), 3, "в канал ушли три строки")
	T.eq(ChannelSent(w, "Борис Быстрый", "строка номер 4"), 0, "четвёртая — нет")
	T.eq(B.throttled, nil, "сервер ни разу не отказал")
	T.eq(B.ns.Channel.stats.over, 1, "строка сверх бюджета посчитана")
	w:Run(30)
	for name, cl in pairs(c) do
		for i = 1, 4 do T.eq(cl:Saw("строка номер " .. i), 1, name .. ": строка " .. i .. " один раз") end
	end
	local p = c.G.ns.Chat.paths
	T.eq(p.both, 3)
	T.eq(p.signed - p.both, 1, "четвёртая только подписью")
	T.eq(B.ns.Channel.State(), "ok")
	w:Run(10)
	B:Slash("/cz1", "после окна")
	T.eq(ChannelSent(w, "Борис Быстрый", "после окна"), 1, "после окна бюджет вернулся")
	B:Slash("/chillzone", "status")
	T.ok(B:Saw("сверх бюджета 1") >= 1, "status: сверх бюджета")
	Clean(c)
end)

T.test("channel: строки, набранные в канал вручную, входят в бюджет", function()
	local w, c = Build()
	local B = c.B
	B:Hardware(B.env.SendChatMessage, "набрал в канал сам", "CHANNEL", nil, B.joined[CHAN])
	w:Run(2)
	T.eq(B.ns.Channel.Free(), 2, "ручная строка посчитана по эху")
	B:Slash("/cz1", "первая после ручной")
	w:Run(2)
	B:Slash("/cz1", "вторая после ручной")
	w:Run(2)
	B:Slash("/cz1", "третья после ручной")
	T.eq(ChannelSent(w, "Борис Быстрый", "третья после ручной"), 0, "бюджет исчерпан")
	T.eq(B.throttled, nil, "сервер не отказывал")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("третья после ручной"), 1, name) end
	Clean(c)
end)

T.test("channel: THROTTLED — бюджет исчерпан до конца окна, эхо возвращает доверие", function()
	local w, c = Build()
	local B = c.B
	w.channelLimit = 1 -- лимит оказался общим: строку игрок уже потратил в другом канале
	B:Slash("/cz1", "первая строка")
	w:Run(2)
	B:Slash("/cz1", "вторая строка")
	w:Run(2)
	T.eq(B.throttled, 1, "сервер отказал")
	T.eq(ChannelSent(w, "Борис Быстрый", "вторая строка"), 0)
	T.eq(B.ns.Channel.Free(), 0, "до конца окна строк не шлём")
	T.eq(B.ns.Channel.State(), "doubt", "свой счёт не исчерпан — под сомнением")
	B:Slash("/cz1", "третья строка")
	T.eq(B.throttled, 1, "третья в канал не пошла")
	T.eq(B.ns.Channel.stats.over, 1)
	w:Run(40)
	for name, cl in pairs(c) do
		for _, text in ipairs({ "первая строка", "вторая строка", "третья строка" }) do
			T.eq(cl:Saw(text), 1, name .. ": " .. text)
		end
	end
	B:Slash("/cz1", "после окна")
	w:Run(2)
	T.eq(ChannelSent(w, "Борис Быстрый", "после окна"), 1)
	T.eq(B.ns.Channel.State(), "ok", "эхо вернуло доверие")
	T.eq(B:Saw("перезайдите персонажем"), 0)
	Clean(c)
end)

T.test("channel: THROTTLED при свободном бюджете дважды — сломан до перезахода, /reload не лечит", function()
	local w, c = Build()
	local B = c.B
	B.channelRefused = "throttled" -- так сервер отвечает забаненному
	B:Slash("/cz1", "забанен раз")
	w:Run(40)
	T.eq(B.ns.Channel.State(), "doubt")
	B:Slash("/cz1", "забанен два")
	w:Run(5)
	T.eq(B.ns.Channel.State(), "broken")
	T.eq(B:Saw("перезайдите персонажем"), 1, "подсказка")
	B:Slash("/cz1", "забанен три")
	T.eq(B.throttled, 2, "в сломанный канал не пишем")
	w:Run(130)
	T.eq(B:Saw("перезайдите персонажем"), 1, "подсказка один раз")
	for name, cl in pairs(c) do
		for _, text in ipairs({ "забанен раз", "забанен два", "забанен три" }) do
			T.eq(cl:Saw(text), 1, name .. ": " .. text .. " через реле")
		end
	end
	B:Slash("/chillzone", "status")
	T.eq(B:Saw("сломан до перезахода персонажа"), 1, "status показывает состояние")
	local R = Reenter(w, c, true)
	T.eq(R.ns.Channel.State(), "broken", "/reload не лечит")
	T.eq(R.joins, nil, "после /reload в канал не входит")
	R:Slash("/cz1", "после перезагрузки")
	T.eq(ChannelSent(w, "Борис Быстрый", "после перезагрузки"), 0)
	R = Reenter(w, c, false)
	T.eq(R.ns.Channel.State(), "ok", "перезаход персонажа лечит")
	T.ok(R.joined[CHAN], "снова в канале")
	w:Run(30)
	R:Slash("/cz1", "после перезахода")
	T.eq(ChannelSent(w, "Борис Быстрый", "после перезахода"), 1)
	Clean(c)
end)

T.test("channel: канал-призрак — без эха подсказка один раз, дальше через реле без повторных входов", function()
	local w, c = Build()
	local B = c.B
	B.channelRefused = true -- сервер молча не раздаёт строки, клиент о бане не знает
	B:Slash("/cz1", "призрак раз")
	w:Run(6)
	T.eq(B.ns.Channel.State(), "doubt", "первая строка без эха — под сомнением")
	T.eq(B:Saw("перезайдите персонажем"), 0)
	B:Slash("/cz1", "призрак два")
	w:Run(6)
	T.eq(B.ns.Channel.State(), "broken", "вторая подряд — сломан")
	T.eq(B:Saw("перезайдите персонажем"), 1)
	B:Slash("/cz1", "призрак три")
	T.eq(ChannelSent(w, "Борис Быстрый", "призрак три"), 0, "в сломанный канал не пишем")
	-- Клиент потерял канал, сервер держит игрока: повторный вход не помог бы.
	B.joinedById[B.joined[CHAN]], B.joined[CHAN] = nil, nil
	local joins = B.joins or 0
	w:Run(180)
	T.eq(B.joins or 0, joins, "в канал заново не входит")
	T.eq(B:Saw("перезайдите персонажем"), 1, "подсказка один раз")
	for name, cl in pairs(c) do
		for _, text in ipairs({ "призрак раз", "призрак два", "призрак три" }) do
			T.eq(cl:Saw(text), 1, name .. ": " .. text)
		end
	end
	T.eq(Logged(B, "нет эха своей строки"), 2)
	Clean(c)
end)

T.test("channel: NOT_ALLOWED_IN_CHANNEL — вход повторяется всё реже; пометка выключен — сломан", function()
	local w, c = Build()
	local B = c.B
	B.channelNotAllowed = true
	B.joinedById[B.joined[CHAN]], B.joined[CHAN] = nil, nil
	w:Run(65)
	T.eq(B.ns.Channel.State(), "locked", "вход отклонён — канал не пускает")
	T.eq(B:Saw("не пускает вас"), 1, "подсказка")
	T.eq(B:Saw("перезайдите персонажем"), 0, "перезаход тут не поможет")
	B:Slash("/chillzone", "status")
	T.eq(B:Saw("не пускает (NOT_ALLOWED_IN_CHANNEL), снова через"), 1, "status показывает повтор")
	w:Run(780)
	local tries = Logged(B, CHAN .. ": NOT_ALLOWED_IN_CHANNEL")
	T.ok(tries >= 4 and tries <= 5, "через 1, 2, 5 минут и дальше реже: " .. tries)
	w:Run(1320)
	T.ok(Logged(B, CHAN .. ": NOT_ALLOWED_IN_CHANNEL") - tries <= 2, "дальше не чаще раза в 10 минут")
	T.eq(B:Saw("не пускает вас"), 1, "подсказка не чаще раза в час")
	B.channelNotAllowed = nil
	w:Run(700)
	T.ok(B.joined[CHAN], "снова в канале без перезахода")
	T.eq(B.ns.Channel.State(), "ok")
	T.eq(Logged(B, "снова пускает"), 1)
	B:Slash("/cz1", "вернулся")
	T.eq(ChannelSent(w, "Борис Быстрый", "вернулся"), 1)
	local V = c.V
	V.channelDisabled = CHAN
	w:Run(65)
	T.eq(V.ns.Channel.State(), "broken", "канал выключен в списке — сломан")
	V:Slash("/cz1", "из выключенного")
	T.eq(ChannelSent(w, "Вера Верная", "из выключенного"), 0)
	w:Run(30)
	T.eq(c.G:Saw("из выключенного"), 1, "строка дошла через реле")
	Clean(c)
end)

T.test("channel: фильтр брани у получателя и у автора — строка одна", function()
	local w, c = Build()
	c.G.profanity = { "брань" }
	c.B.profanity = { "брань" }
	c.B:Slash("/cz1", "это брань и всё")
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("и всё"), 1, name .. " видит один раз") end
	T.eq(c.G.ns.Chat.paths.both, 1, "копии сведены по маске")
	T.eq(c.A:Saw("это брань и всё"), 1, "без фильтра — исходный текст")
	T.eq(c.B.ns.Channel.stats.echoed, 1)
	T.eq(c.B.ns.Channel.State(), "ok", "эхо с маской засчитано своей строке")
	-- Похожие строки без маски не склеиваются: «ок.» и «ок!» — разные.
	c.K:Slash("/cz1", "ок.")
	w:Run(2)
	c.K:Slash("/cz1", "ок!")
	w:Run(30)
	T.eq(c.G:Saw("]|h: ок."), 1)
	T.eq(c.G:Saw("]|h: ок!"), 1)
	Clean(c)
end)

T.test("channel: без сертификата сверх бюджета — отказ, текст остаётся в поле", function()
	local w, c = Build()
	local M = c.M
	M.ns.Security.MyCertificate = function() return nil end
	for i = 1, 3 do
		M:Slash("/cz1", "без подписи " .. i)
		w:Run(2)
	end
	M.ns.UI.OpenChat("A", true)
	local box = M.ns.ChatPane.frames.box
	box:SetText("четвёртая без подписи")
	box.scripts.OnTextChanged(box, true) -- набрано игроком: черновик канала
	M:Press(box)
	T.eq(box:GetText(), "четвёртая без подписи", "текст остался в поле")
	T.eq(M:Saw("Повторите через 29 с"), 1, "игрок знает, сколько ждать")
	T.eq(ChannelSent(w, "Мира Тихая", "четвёртая"), 0)
	T.eq(M:Saw("не вернулась из канала"), 0)
	w:Run(30)
	M:Press(box)
	T.eq(ChannelSent(w, "Мира Тихая", "четвёртая без подписи"), 1, "после окна ушла")
	T.eq(box:GetText(), "")
	w:Run(10)
	for name, cl in pairs(c) do T.eq(cl:Saw("четвёртая без подписи"), 1, name) end
	Clean(c)
end)

T.test("channel: ADDON_ACTION_BLOCKED выключает отправку в канал до перезагрузки", function()
	local w, c = Build()
	local B = c.B
	B:Fire("ADDON_ACTION_BLOCKED", "ДругойАддон", "CastSpellByName()")
	T.eq(B.ns.Channel.State(), "ok", "чужой аддон не в счёт")
	B:Fire("ADDON_ACTION_BLOCKED", "Chillzone", "UNKNOWN()")
	T.eq(B.ns.Channel.State(), "blocked")
	T.eq(Logged(B, "игра заблокировала действие аддона (UNKNOWN())"), 1)
	B:Slash("/cz1", "после блокировки")
	T.eq(ChannelSent(w, "Борис Быстрый", "после блокировки"), 0)
	w:Run(30)
	for name, cl in pairs(c) do T.eq(cl:Saw("после блокировки"), 1, name) end
	local R = Reenter(w, c, true)
	T.eq(R.ns.Channel.State(), "ok", "перезагрузка интерфейса снимает запрет")
	R:Slash("/cz1", "после перезагрузки")
	T.eq(ChannelSent(w, "Борис Быстрый", "после перезагрузки"), 1)
	Clean(c)
end)

T.test("channel: подписанная строка без копии из канала у слышанного автора — счётчик глухого канала", function()
	local w, c = Build()
	c.B:Slash("/cz1", "слышно в канале")
	w:Run(30)
	c.G.channelDeaf = true -- сервер больше не шлёт Глебу строк канала, клиент не знает
	c.B:Slash("/cz1", "глухой канал")
	w:Run(200)
	T.eq(c.G:Saw("глухой канал"), 1, "строка дошла подписью")
	T.eq(c.G.ns.Chat.paths.deaf, 1, "глухой канал посчитан")
	T.eq(Logged(c.G, "пришла подписью, а из канала игры нет"), 1)
	T.eq(c.A.ns.Chat.paths.deaf, 0, "у слышащих ничего")
	T.eq(c.B.ns.Chat.paths.deaf, 0, "свои строки не считаются")
	Clean(c)
end)

T.test("channel: вне объединения в канал не входит", function()
	local w = Wow.World()
	w:Guild("Чужая гильдия")
	local x = w:Client({ first = "Чужой", surname = "Игрок", guild = "Чужая гильдия", rank = 0 })
	local y = w:Client({ first = "Без", surname = "Гильдии" })
	w:Run(120)
	T.eq(next(x.joined), nil)
	T.eq(next(y.joined), nil)
	Clean({ x = x, y = y })
end)

-- Старые клиенты без Channel.lua: строка от нового доходит через реле, канал им не нужен.
T.test("channel: клиент 0.9 получает строку через реле и в канал не входит", function()
	math.randomseed(37)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.k = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, legacy = true })
	c.o = w:Client({ first = "Офицер", surname = "Главный", guild = "Чиллзон", rank = 1, legacy = true })
	c.v = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, legacy = true })
	c.b = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3, legacy = true })
	w:Run(30)
	w:Init(c.k, c.v)
	w:Pair(c.v, c.k)
	w:Run(180)
	local db = c.b.ns.db
	c.b:Logout()
	c.b = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3, db = db })
	for _, cl in pairs(c) do cl.ns.Roster.Scan() end
	w:Run(45)
	T.ok(c.b.joined[CHAN], "новый клиент в канале")
	for _, name in ipairs({ "k", "o", "v" }) do T.eq(next(c[name].joined), nil, name .. ": 0.9 в канал не входит") end
	c.b:Slash("/cz1", "новый пишет старым")
	T.eq(ChannelSent(w, "Борис Быстрый", "новый пишет старым"), 1)
	w:Run(40)
	for name, cl in pairs(c) do T.eq(cl:Saw("новый пишет старым"), 1, name .. " видит один раз") end
	c.k:Slash("/cz1", "старый пишет новому")
	w:Run(40)
	T.eq(c.b:Saw("старый пишет новому"), 1, "новый получил подписанную строку старого")
	T.eq(c.b.ns.Chat.paths.signed - c.b.ns.Chat.paths.both, 1, "только подписью")
	Clean(c)
end)
