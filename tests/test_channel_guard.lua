-- Страж канала игры (Channel.lua, по образцу Olympus): пока канал у клиента объединения
-- (владелец или модератор), он снимает пароль и баны, увиденные в канале; «стук» снимает бан,
-- которого никто не видел; закрытый канал клиент пробует снова сам. Симулятор держит канал
-- на сервере: владелец, модераторы, баны, пароль (tests/wow.lua).
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local CHAN = "ChillzoneChatA"
local STRANGER = "Злой Чужак-CAMWOWUS2Realm7PvE" -- вне объединения, без аддона
local MODER = "Хитрый Модер-CAMWOWUS2Realm7PvE" -- модератор канала без аддона

-- stranger — посторонний входит в канал раньше всех и становится владельцем.
-- blocked — игра не пускает команды канала (w.channelOpsBlocked) с самого входа.
local function Build(opts)
	opts = opts or {}
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 41)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	if opts.stranger then w:ChanStranger(CHAN, STRANGER) end
	if opts.blocked then w.channelOpsBlocked = opts.blocked end
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

local function Full(cl)
	return cl:Name() .. "-" .. cl.realm
end

-- Клиент, который на сервере владеет каналом.
local function Owner(w, c)
	local owner = w:ChanOwner(CHAN)
	for name, cl in pairs(c) do
		if cl:Name() == owner then return cl, name end
	end
end

local function Logged(cl, text)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

-- Вызовы команд канала; без op — вызовы стража (снятия), без запроса владельца.
local function Ops(cl, op)
	local n = 0
	for _, e in ipairs(cl.chanOps or {}) do
		if e.op == op or (not op and e.op ~= "owner") then n = n + 1 end
	end
	return n
end

-- Перезаход персонажа (не /reload): те же сохранения, в канал входит заново.
local function Relog(w, c, name)
	local old = c[name]
	local db = old.ns.db
	old:Logout()
	local cl = w:Client({ first = old.first, surname = old.surname, guild = old.guild, rank = old.rank, class = old.class, db = db })
	cl.ns.Roster.Scan()
	c[name] = cl
	w:Run(45)
	return cl
end

local function Clean(c)
	for name, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, name .. ": глобалы " .. table.concat(cl:Leaks(), ", "))
		T.eq(cl.blocked, nil, name .. ": отправка в канал не из нажатия клавиши")
	end
end

T.test("channel guard: первый вошедший — владелец, подсказка один раз, место переживает /reload", function()
	local w, c = Build()
	local owner, key = Owner(w, c)
	T.ok(owner, "канал у клиента объединения")
	T.ok(owner.ns.Channel.Seated(), "клиент знает, что он владелец")
	T.eq(Ops(owner, "owner"), 1, "создателю игра не сообщает — спросил владельца сам")
	T.eq(Logged(owner, "OWNER_CHANGED"), 0)
	T.eq(owner:Saw("сделала вас владельцем канала " .. CHAN), 1, "подсказка")
	for name, cl in pairs(c) do
		if cl ~= owner then T.no(cl.ns.Channel.Seated(), name .. " без места") end
	end
	owner:Slash("/chillzone", "status")
	T.eq(owner:Saw("страж канала: моё место — владелец, банов к снятию 0, работает"), 1)
	local R = w:Reload(owner)
	c[key] = R
	w:Run(30)
	T.ok(R.ns.Channel.Seated(), "после /reload место прежнее")
	T.eq(R:Saw("сделала вас владельцем"), 0, "подсказка один раз на персонажа")
	T.eq(Ops(R), 0, "лечить нечего — вызовов нет")
	T.eq(Ops(R, "owner"), 1, "после /reload сверил место")
	Clean(c)
end)

T.test("channel guard: бан постороннего снимает участник объединения, к которому перешёл канал", function()
	local w, c = Build({ stranger = true })
	T.eq(w:ChanOwner(CHAN), "Злой Чужак", "канал у постороннего")
	for name, cl in pairs(c) do T.no(cl.ns.Channel.Seated(), name .. " без места") end
	w:ChanBan(CHAN, STRANGER, Full(c.B))
	w:Run(5)
	T.ok(w.channels[CHAN].banned["Борис Быстрый"], "Борис забанен")
	T.eq(c.A.ns.Channel.Pending(), 1, "свидетели запомнили бан")
	T.eq(Logged(c.A, "PLAYER_BANNED Борис Быстрый, Злой Чужак"), 1, "бан в журнале")
	-- Борис перезаходит: бан на месте, канал не пускает.
	local B = Relog(w, c, "B")
	T.eq(B.ns.Channel.State(), "locked", "забаненного не пускает и после перезахода")
	T.eq(B:Saw("не пускает вас"), 1)
	-- Посторонний уходит: канал переходит к первому вошедшему клиенту, тот снимает бан.
	w:ChanStranger(CHAN, STRANGER, true)
	w:Run(10)
	local owner = Owner(w, c)
	T.ok(owner, "канал перешёл к клиенту объединения")
	T.eq(owner:Saw("сделала вас владельцем"), 1, "подсказка новому владельцу")
	T.eq(Ops(owner, "unban"), 1, "один вызов снятия")
	T.eq(w.channels[CHAN].banned["Борис Быстрый"], nil, "бан снят")
	for name, cl in pairs(c) do
		if name ~= "B" then T.eq(cl.ns.Channel.Pending(), 0, name .. ": снятый бан забыт") end
		if cl ~= owner then T.eq(Ops(cl), 0, name .. ": без места не вызывает") end
	end
	w:Run(700)
	T.ok(B.joined[CHAN], "Борис вошёл сам, без перезахода")
	T.eq(B.ns.Channel.State(), "ok")
	Clean(c)
end)

T.test("channel guard: стук — бан, которого никто не видел, снимается по подписанной строке", function()
	local w, c = Build()
	local owner = Owner(w, c)
	T.ok(owner and owner ~= c.B, "канал у клиента объединения, не у Бориса")
	-- Бан до обновления: свидетелей нет, списков нет.
	w.channels[CHAN].banned["Борис Быстрый"] = true
	local B = Relog(w, c, "B")
	T.eq(B.ns.Channel.State(), "locked")
	T.eq(owner.ns.Channel.Pending(), 0, "владелец о бане не знает")
	B:Slash("/cz1", "меня не пускают")
	w:Run(40)
	for name, cl in pairs(c) do
		if cl ~= B then T.eq(cl:Saw("меня не пускают"), 1, name .. ": строка дошла подписью") end
	end
	w:Run(200)
	T.eq(Logged(owner, "Борис Быстрый пришла подписью без копии из канала"), 1, "стук")
	T.eq(w.channels[CHAN].banned["Борис Быстрый"], nil, "бан снят")
	for name, cl in pairs(c) do
		if cl ~= owner then T.eq(Ops(cl), 0, name .. ": без места не стучит") end
	end
	w:Run(700)
	T.ok(B.joined[CHAN], "Борис снова в канале")
	B:Slash("/cz1", "я вернулся")
	w:Run(200)
	T.eq(Logged(owner, "пришла подписью без копии из канала"), 1, "строка с копией из канала — без стука")
	T.eq(Ops(owner, "unban"), 1, "одно снятие")
	Clean(c)
end)

T.test("channel guard: стук в незабаненного безвреден и не чаще раза в полчаса", function()
	local w, c = Build()
	local owner = Owner(w, c)
	local B = c.B
	T.ok(owner and owner ~= B, "канал не у Бориса")
	B.ns.Channel.SetEnabled(false) -- Борис пишет только подписью
	w:Run(5)
	B:Slash("/cz1", "без канала раз")
	w:Run(200)
	T.eq(Ops(owner, "unban"), 1, "стук")
	T.eq(Logged(owner, ": PLAYER_NOT_BANNED"), 1, "сервер: бана нет")
	T.eq(owner.ns.Channel.Pending(), 0)
	B:Slash("/cz1", "без канала два")
	w:Run(200)
	T.eq(Ops(owner, "unban"), 1, "второй стук не раньше чем через полчаса")
	w:Run(owner.ns.Channel.KNOCK_GAP)
	B:Slash("/cz1", "без канала три")
	w:Run(200)
	T.eq(Ops(owner, "unban"), 2, "через полчаса — снова")
	Clean(c)
end)

T.test("channel guard: стук, на который сервер ответил «не найден», не повторяется", function()
	local w, c = Build()
	w.unbanNotFound = true
	local owner = Owner(w, c)
	local B = c.B
	T.ok(owner and owner ~= B, "канал не у Бориса")
	B.ns.Channel.SetEnabled(false)
	w:Run(5)
	B:Slash("/cz1", "без канала")
	w:Run(200)
	T.eq(Ops(owner, "unban"), 1, "стук")
	T.eq(Logged(owner, ": PLAYER_NOT_FOUND Борис Быстрый"), 1, "сервер: не найден")
	T.eq(Logged(owner, "Борис Быстрый не найден — стук не повторяю"), 1)
	T.eq(owner.ns.Channel.Pending(), 0, "в работу не вернулся")
	w:Run(7200)
	T.eq(Ops(owner, "unban"), 1, "и через два часа не повторил")
	Clean(c)
end)

T.test("channel guard: пароль постороннего снимает страж; под паролем сам вход — только при входе в игру", function()
	local w, c = Build({ stranger = true })
	w:ChanPassword(CHAN, STRANGER, "secret")
	w:Run(5)
	local B = Relog(w, c, "B")
	T.eq(B.ns.Channel.State(), "locked", "без пароля не пускает")
	T.eq(B.refusedJoins, 1, "одна попытка")
	T.eq(Logged(B, "WRONG_PASSWORD, попытка 1), следующая — при входе в игру"), 1, "окно пароля и отказ — одна попытка")
	T.eq(B:Saw("нажмите «Отмена»"), 1, "подсказка про окно пароля")
	w:ChanStranger(CHAN, STRANGER, true)
	w:Run(10)
	local owner = Owner(w, c)
	T.eq(Ops(owner, "password"), 1, "страж снял пароль")
	T.eq(w.channels[CHAN].password, nil)
	w:Run(3600)
	T.eq(B.refusedJoins, 1, "сам больше не пробует: окна пароля нет")
	T.no(B.joined[CHAN])
	local R = w:Reload(B)
	c.B = R
	w:Run(120)
	T.eq(R.joins, nil, "и после /reload не пробует")
	T.eq(R.refusedJoins, nil)
	R:Slash("/chillzone", "status")
	T.eq(R:Saw("снова при следующем входе в игру"), 1)
	B = Relog(w, c, "B")
	T.ok(B.joined[CHAN], "при входе в игру вошёл")
	T.eq(B.ns.Channel.State(), "ok")
	Clean(c)
end)

T.test("channel guard: под паролем игрок входит сам, снова включив канал", function()
	local w, c = Build({ stranger = true })
	w:ChanPassword(CHAN, STRANGER, "secret")
	w:Run(5)
	local B = Relog(w, c, "B")
	T.eq(B.ns.Channel.State(), "locked")
	w:ChanPassword(CHAN, STRANGER, "")
	w:Run(700)
	T.no(B.joined[CHAN], "сам не пробует")
	B.ns.Channel.SetEnabled(true)
	w:Run(5)
	T.ok(B.joined[CHAN], "включил настройку — вошёл")
	T.eq(B.ns.Channel.State(), "ok")
	T.eq(B.ns.char.channelLocked, nil, "отметка снята")
	Clean(c)
end)

T.test("channel guard: свой бан страж не снимает, его снимает следующий владелец", function()
	local w, c = Build()
	local owner, key = Owner(w, c)
	local victim = owner == c.M and c.K or c.M
	w:ChanBan(CHAN, Full(owner), Full(victim)) -- владелец набрал /ban сам
	w:Run(10)
	T.eq(Ops(owner), 0, "свой бан не снимает")
	T.ok(w.channels[CHAN].banned[victim:Name()], "бан на месте")
	owner:Logout()
	c[key] = nil
	w:Run(10)
	local heir = Owner(w, c)
	T.ok(heir and heir ~= victim, "канал перешёл к другому клиенту")
	T.eq(Ops(heir, "unban"), 1)
	T.eq(w.channels[CHAN].banned[victim:Name()], nil, "следующий владелец снял бан")
	Clean(c)
end)

-- Ответ сервера «нет такого игрока» на снятие бана прячет фильтр стража.
local function Hidden(cl, name)
	local text = cl.env.ERR_CHAT_PLAYER_NOT_FOUND_S:format(name)
	for _, fn in ipairs(cl.filters.CHAT_MSG_SYSTEM or {}) do
		if fn(nil, "CHAT_MSG_SYSTEM", text) then return true end
	end
	return false
end

-- Посторонний модератор канала без аддона.
local function Moder(w)
	w:ChanStranger(CHAN, MODER)
	w.channels[CHAN].mods["Хитрый Модер"] = true
end

T.test("channel guard: бан участника вне игры снимается позже и всё реже, строка «нет такого игрока» спрятана", function()
	local w, c = Build()
	local owner = Owner(w, c)
	T.ok(owner and owner ~= c.B, "канал не у Бориса")
	Moder(w)
	c.B:Logout()
	w:ChanBan(CHAN, MODER, Full(c.B))
	w:Run(2.2)
	T.eq(Ops(owner, "unban"), 1, "страж пробует сразу")
	T.ok(Hidden(owner, "Борис Быстрый"), "ответ сервера спрятан")
	w:Run(5)
	T.eq(owner.ns.Channel.Pending(), 1, "бан ждёт, пока игрок вернётся")
	T.no(Hidden(owner, "Борис Быстрый"), "чужие такие строки не прячем")
	w:Run(120)
	T.eq(Ops(owner, "unban"), 1, "раньше срока не повторяет")
	w:Run(200)
	T.eq(Ops(owner, "unban"), 2, "через 5 минут снова")
	w:Run(400)
	T.eq(Ops(owner, "unban"), 2, "второй раз «нет такого игрока» — ждёт вдвое дольше")
	local B = Relog(w, c, "B")
	T.eq(B.ns.Channel.State(), "locked")
	w:Run(300)
	T.eq(Ops(owner, "unban"), 3)
	T.eq(w.channels[CHAN].banned["Борис Быстрый"], nil, "бан снят, когда игрок вернулся")
	T.eq(owner.ns.Channel.Pending(), 0)
	w:Run(700)
	T.ok(B.joined[CHAN], "Борис вошёл сам")
	Clean(c)
end)

T.test("channel guard: бан постороннего участником объединения держится и после смены владельца", function()
	local w, c = Build()
	local owner, key = Owner(w, c)
	w:ChanStranger(CHAN, STRANGER)
	w:ChanBan(CHAN, Full(owner), STRANGER) -- спамер в канале: владелец набрал /ban
	w:Run(10)
	for name, cl in pairs(c) do
		T.eq(cl.ns.Channel.Pending(), 0, name .. ": посторонний не в списке к снятию")
		if cl ~= owner then T.eq(Logged(cl, "Злой Чужак не из объединения"), 1, name .. ": в журнале") end
	end
	owner:Logout()
	c[key] = nil
	w:Run(10)
	local heir = Owner(w, c)
	T.ok(heir, "канал перешёл к клиенту объединения")
	T.eq(Ops(heir), 0, "наследник бан не снимает")
	T.ok(w.channels[CHAN].banned["Злой Чужак"], "спамер по-прежнему забанен")
	Clean(c)
end)

T.test("channel guard: модератор не трогает пароль и не теряет место, баны снимает", function()
	local w, c = Build({ stranger = true })
	local A = c.A
	w.channels[CHAN].mods[A:Name()] = true
	w:ChanNotify(CHAN, "SET_MODERATOR", Full(A))
	w:Run(5)
	T.ok(A.ns.Channel.Seated(), "Арагорн — модератор")
	T.eq(A:Saw("сделала вас модератором канала " .. CHAN), 1)
	w:ChanPassword(CHAN, STRANGER, "secret")
	w:ChanBan(CHAN, STRANGER, Full(c.B))
	w:Run(10)
	T.eq(Ops(A, "password"), 0, "пароль снимает только владелец")
	T.eq(Ops(A, "unban"), 1, "бан снимает и модератор")
	T.eq(w.channels[CHAN].banned["Борис Быстрый"], nil)
	T.ok(A.ns.Channel.Seated(), "место модератора на месте")
	T.ok(w.channels[CHAN].password, "пароль ждёт владельца из объединения")
	Clean(c)
end)

T.test("channel guard: бан из канала другой стороны не трогает", function()
	local w, c = Build()
	local owner = Owner(w, c)
	local g = owner.ns.store.channelGuard
	g.banned["ордынецдальний"] = { n = "Ордынец Дальний", ch = "ChillzoneChatH", t = owner.ns.ServerTime() }
	owner.ns.Channel.Heal()
	w:Run(70)
	T.eq(Ops(owner), 0, "чужой канал — не мой")
	T.eq(owner.ns.Channel.Pending(), 0, "в счёт этого канала не идёт")
	T.ok(g.banned["ордынецдальний"], "запись ждёт персонажа той стороны")
	Clean(c)
end)

T.test("channel guard: место, которое ушло во время /reload, сверяется запросом владельца", function()
	local w, c = Build()
	local owner, key = Owner(w, c)
	local R = w:Reload(owner)
	c[key] = R
	-- Пока интерфейс перезагружался, канал перешёл к другому, уведомление потерялось.
	local heir = owner == c.K and c.A or c.K
	w.channels[CHAN].owner, w.channels[CHAN].mods = heir:Name(), {}
	w:Run(30)
	T.eq(Ops(R, "owner"), 1, "после /reload спросил владельца")
	T.no(R.ns.Channel.Seated(), "сервер назвал другого владельца")
	T.eq(R.ns.Channel.owner, heir:Name())
	w:ChanBan(CHAN, Full(heir), Full(c.B))
	w:Run(10)
	T.eq(Ops(R), 0, "без места не вызывает")
	Clean(c)
end)

T.test("channel guard: без запроса владельца ушедшее место снимается по отказу сервера", function()
	local w, c = Build()
	local owner, key = Owner(w, c)
	local R = w:Reload(owner)
	c[key] = R
	R.env.DisplayChannelOwner = nil
	local heir = owner == c.K and c.A or c.K
	w.channels[CHAN].owner, w.channels[CHAN].mods = heir:Name(), {}
	w:Run(30)
	T.eq(Logged(R, "нет DisplayChannelOwner"), 1, "в журнале: спросить нечем")
	T.ok(R.ns.Channel.Seated(), "клиент ещё считает себя владельцем")
	local victim = c.B
	T.ok(victim ~= R and victim ~= heir)
	w:ChanBan(CHAN, Full(heir), Full(victim))
	w:Run(10)
	T.eq(Ops(R, "unban"), 1, "попробовал снять")
	T.no(R.ns.Channel.Seated(), "NOT_MODERATOR — места больше нет")
	T.eq(Ops(heir), 0, "новый владелец свой бан не снимает")
	T.ok(w.channels[CHAN].banned["Борис Быстрый"], "бан на месте")
	Clean(c)
end)

T.test("channel guard: из таймера игра не пускает — страж снимает бан при отправке строки", function()
	local w, c = Build()
	local owner = Owner(w, c)
	T.ok(owner ~= c.B)
	w.channelOpsBlocked = "timer"
	Moder(w)
	w:ChanBan(CHAN, MODER, Full(c.B))
	w:Run(10)
	T.eq(Ops(owner), 1, "одна попытка из таймера")
	T.eq(Logged(owner, "игра не пускает вызовы стража из таймера"), 1)
	T.eq(owner.ns.Channel.Pending(), 1, "бан остался в работе")
	owner:Slash("/chillzone", "status")
	T.eq(owner:Saw("работает только при отправке строки /cz"), 1)
	w:Run(600)
	T.eq(Ops(owner), 1, "из таймера больше не пробует")
	owner:Slash("/cz1", "всем привет")
	w:Run(5)
	T.eq(Ops(owner, "unban"), 2, "снятие из нажатия Enter")
	T.eq(w.channels[CHAN].banned["Борис Быстрый"], nil, "бан снят")
	T.eq(owner.ns.Channel.State(), "ok")
	Clean(c)
end)

T.test("channel guard: игра запретила вызов стража и из нажатия — страж выключен до новой версии, отправка в канал работает", function()
	local w, c = Build()
	local owner, key = Owner(w, c)
	T.ok(owner ~= c.B)
	w.channelOpsBlocked = true
	Moder(w)
	w:ChanBan(CHAN, MODER, Full(c.B))
	w:Run(10)
	T.eq(Ops(owner), 1, "одна попытка из таймера")
	T.eq(Logged(owner, "страж выключен"), 0, "после первого отказа ещё не выключен")
	owner:Slash("/cz1", "после запрета")
	w:Run(5)
	T.eq(Ops(owner), 2, "попытка из нажатия")
	T.eq(Logged(owner, "страж выключен до новой версии аддона"), 1)
	T.eq(owner.ns.Channel.State(), "ok", "отправку в канал не выключили")
	owner:Slash("/chillzone", "status")
	T.eq(owner:Saw("выключен до новой версии: игра запретила"), 1)
	local sent = 0
	for _, e in ipairs(w.log) do
		if e.dist == "CHANNEL" and e.msg == "после запрета" then sent = sent + 1 end
	end
	T.eq(sent, 1, "строка ушла в канал")
	owner:Slash("/cz1", "ещё строка")
	w:Run(600)
	T.eq(Ops(owner), 2, "больше не пробует")
	local R = w:Reload(owner)
	c[key] = R
	w:Run(600)
	T.eq(Ops(R), 0, "и после /reload")
	Clean(c)
end)

T.test("channel guard: из таймера игра не пускает и запрос владельца — он уходит при отправке строки", function()
	local w, c = Build({ blocked = "timer" })
	local owner = Owner(w, c)
	T.ok(owner, "канал у клиента объединения")
	T.no(owner.ns.Channel.Seated(), "из таймера владельца не узнать")
	T.eq(Ops(owner, "owner"), 1, "одна попытка из таймера")
	T.eq(Logged(owner, "игра не пускает вызовы стража из таймера"), 1)
	w:Run(600)
	T.eq(Ops(owner, "owner"), 1, "из таймера больше не пробует")
	owner:Slash("/cz1", "всем привет")
	w:Run(5)
	T.eq(Ops(owner, "owner"), 2, "спросил из нажатия Enter")
	T.ok(owner.ns.Channel.Seated(), "теперь знает, что владелец")
	T.eq(owner:Saw("сделала вас владельцем"), 1)
	owner:Slash("/cz1", "ещё строка")
	w:Run(5)
	T.eq(Ops(owner, "owner"), 2, "больше не спрашивает")
	T.eq(Ops(owner), 0, "снимать нечего")
	Clean(c)
end)
