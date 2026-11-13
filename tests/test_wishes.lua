-- Желания: формат карточки, разбор своего списка, каталог своей и чужой гильдии, порядок пакетов
-- автора, снятие, подсказка предмета, повторы, сохранения, вкладка и пересылка прежней версией.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function codec()
	return T.load({ "Config.lua", "Util.lua", "Codec.lua" }).Codec
end

local function card()
	return { mode = "C", st = 1794412800, guild = "Чиллзон Север", class = "DRUID", level = 22, items = { 2862, 12640, 2852 } }
end

T.test("wishes codec: карточка и снятие читаются обратно", function()
	local Codec = codec()
	local msg = Codec.EncodeWish(card())
	T.ok(msg and #msg <= 255, "сообщение собрано")
	local d = Codec.DecodeWish(msg)
	T.same(d, { mode = "C", st = 1794412800, guild = "Чиллзон Север", class = "DRUID", level = 22, items = { 2852, 2862, 12640 } },
		"предметы — по возрастанию номера")
	local x = Codec.EncodeWish({ mode = "X", st = 1794412800, guild = "Чиллзон" })
	T.eq(x, "V1~X~1794412800~Чиллзон")
	T.same(Codec.DecodeWish(x), { mode = "X", st = 1794412800, guild = "Чиллзон" })
	T.no(Codec.EncodeWish({ mode = "C", st = 1794412800, guild = "Чиллзон", items = {} }), "без предметов карточки нет")
	T.no(Codec.EncodeWish({ mode = "C", st = 0, guild = "Чиллзон", items = { 1 } }), "без времени")
	T.no(Codec.EncodeWish({ mode = "Z", st = 1794412800, guild = "Чиллзон", items = { 1 } }), "незнакомый режим")
end)

T.test("wishes codec: повторы и мусор отбрасываются, длинный список умещается по важности", function()
	local Codec = codec()
	local w = card()
	w.items = { 5, 5, 0, -1, 1.5, "x", 12345678, 7 }
	T.same(Codec.DecodeWish(Codec.EncodeWish(w)).items, { 5, 7 })
	-- 30 предметов с большими номерами и самая длинная гильдия: последние по важности отброшены.
	w.guild, w.items = ("Щ"):rep(24), {}
	for i = 1, 40 do w.items[i] = 9000000 + i * 31337 end
	local msg = Codec.EncodeWish(w)
	T.ok(msg and #msg <= 255, "уместилось: " .. tostring(msg and #msg))
	local d = Codec.DecodeWish(msg)
	T.ok(#d.items > 0 and #d.items <= Codec.WISH_ITEMS, "предметов: " .. #d.items)
	local first = {}
	for _, id in ipairs(d.items) do first[id] = true end
	for i = 1, #d.items do T.ok(first[w.items[i]], "остались первые по важности: " .. i) end
	T.ok(#("M1~A~" .. w.guild .. "~" .. msg) < 400, "конверт подписывается и режется как строка чата")
end)

T.test("wishes codec: мусор не читается, поля следующих версий не мешают, конверт строки чата", function()
	local Codec = codec()
	local base = "V1~C~1794412800~Чиллзон~DR~22~"
	T.ok(Codec.DecodeWish(base .. "21"), "образец читается")
	T.no(Codec.DecodeWish(base), "без предметов")
	T.no(Codec.DecodeWish(base .. "!!"), "мусор в списке")
	T.no(Codec.DecodeWish("V1~C~0~Чиллзон~DR~22~21"), "время 0")
	T.no(Codec.DecodeWish("V1~X~1794412800~"), "снятие без гильдии")
	T.same(Codec.DecodeWish(base .. "21~новое поле").items, { 2, 3 }, "поле следующей версии")
	local msg = Codec.EncodeWish(card())
	local env = Codec.WrapWish(msg)
	T.eq(env, "M1~A~Чиллзон Север~" .. msg)
	local inner, guild = Codec.UnwrapWish(env)
	T.eq(inner, msg)
	T.eq(guild, "Чиллзон Север")
	T.no(Codec.DecodeChat(env), "чат конверт не читает")
	T.no(Codec.UnwrapWish("M1~A~Чиллзон~" .. msg), "гильдия конверта не та")
	T.no(Codec.UnwrapCraft(env), "это не карточка мастера")
end)

---------------------------------------------------------------------------
-- Мир: две гильдии объединения
---------------------------------------------------------------------------
local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN", level = 60 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID", level = 22 })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1, class = "PRIEST", level = 21 })
	w:Run(30)
	w:Init(c.A, c.V)
	w:Pair(c.V, c.K)
	w:Run(400)
	return w, c
end

local function Key(c)
	return c.ns.Util.Key(c:Name())
end

local function Logged(cl, text)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function NoErrors(cl, label)
	local errors = cl.ns.db.errors or {}
	T.eq(#errors, 0, label .. ": " .. table.concat(errors, " | "))
end

-- Подписанные списки, которые клиент отправил своей гильдии.
local function Capture(c)
	local wires, send = {}, c.ns.Comm.Send
	c.ns.Comm.Send = function(dist, payload, opts)
		if dist == "GUILD" and payload:sub(1, 3) == "S1~" and payload:find("~V1~", 1, true) then wires[#wires + 1] = payload end
		return send(dist, payload, opts)
	end
	return wires
end

-- Список мимо сети, как его отдал бы Comm.Dispatch после проверки подписи.
local function Feed(cl, o)
	local ns = cl.ns
	local at = o.at or cl.env.GetServerTime()
	local name = o.name or "Борис Быстрый"
	local guild = o.guild or "Чиллзон Север"
	local cert = o.cert or { key = ns.Util.Key(name), name = name, guild = guild }
	local msg = ns.Codec.EncodeWish({ mode = o.mode or "C", st = at, guild = guild, class = "PRIEST", level = 21, items = o.items or { 2862 } })
	ns.Wishes.Receive(msg, name, o.dist or "RELAY", o.ctx or {
		authenticated = true, certificate = cert, wire = ("S1~fp~%d~%d~x"):format(at, o.seq or 1),
	})
	return cert.key
end

local function NoTrace(cl, label)
	T.eq(cl:Saw("V1~"), 0, label .. ": в чате игры нет списка")
	for _, tier in ipairs({ "A", "C", "L" }) do
		for _, m in ipairs(cl.ns.Chat.History(tier)) do
			T.no(tostring(m.x):find("V1~", 1, true), label .. ": в окне нет списка")
		end
	end
end

local LINK = "|cff1eff00|Hitem:2862::::::::60:::::|h[Грубое точило]|h|r"

---------------------------------------------------------------------------
-- Свой список
---------------------------------------------------------------------------
T.test("wishes: разбор поля — ссылки, номера, названия известных предметов и неузнанные", function()
	local _, c = Build()
	local Wishes = c.A.ns.Wishes
	c.A.items[12640] = true -- игра уже знает шлем: название находится
	c.A.env.GetItemInfo = function(v)
		if v == "Шлем львиного сердца" then return v, "|Hitem:12640|h[Шлем львиного сердца]|h" end
	end
	c.A.env.C_Item.GetItemInfo = c.A.env.GetItemInfo
	local ids, unknown, extra = Wishes.Parse(LINK .. LINK .. "\n2852, [Шлем львиного сердца]; Неведомая вещь\n\n  2862  ")
	T.same(ids, { 2862, 2852, 12640 }, "порядок как в поле, без повторов")
	T.same(unknown, { "Неведомая вещь" })
	T.eq(extra, 0)
	local many = {}
	for i = 1, 35 do many[i] = tostring(1000 + i) end
	ids, _, extra = Wishes.Parse(table.concat(many, ","))
	T.eq(#ids, c.A.ns.Config.WISH_ITEMS)
	T.eq(extra, 5, "лишние посчитаны")
	NoErrors(c.A, "Арагорн")
end)

T.test("wishes: список видят своя гильдия по GUILD и чужая через реле, в подсказке — имя", function()
	local w, c = Build()
	local wires = Capture(c.A)
	local ok, n, unknown = c.A.ns.Wishes.Save(LINK .. "\n12640")
	T.ok(ok, "сохранено: " .. tostring(n))
	T.eq(n, 2)
	T.same(unknown, {})
	w:Run(30)
	T.eq(#wires, 1, "своей гильдии — один пакет")
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		local e = viewer.ns.Wishes.Get(Key(c.A))
		T.ok(e, viewer:Name() .. " видит список")
		T.eq(e.name, "Арагорн Светлый")
		T.eq(e.guild, "Чиллзон")
		T.eq(e.class, "WARRIOR")
		T.same(e.items, { 2862, 12640 })
		local tip = viewer.ns.Wishes.TipLine(2862)
		T.ok(tip and tip:find("Арагорн Светлый", 1, true), viewer:Name() .. ": имя в подсказке")
		T.ok(tip:find(viewer.ns.L.WISH_TIP_NEEDED, 1, true))
		T.no(viewer.ns.Wishes.TipLine(2852), "чужой предмет никому не нужен")
		NoTrace(viewer, viewer:Name())
	end
	T.eq(Logged(c.K, "желания: список Арагорн Светлый <Чиллзон> принят (своя гильдия)"), 1)
	T.eq(Logged(c.V, "желания: список Арагорн Светлый <Чиллзон> принят (реле)"), 1)
	T.no(c.A.ns.Wishes.Get(Key(c.A)), "свой список не из сети")
	T.ok(c.A.ns.Wishes.Own().own)
	T.ok(c.A.ns.Wishes.TipLine(12640):find("Арагорн Светлый", 1, true), "своё имя в своей подсказке")
	-- Переключатель подсказки.
	c.V.ns.Wishes.SetShowTooltip(false)
	T.no(c.V.ns.Wishes.TipLine(2862), "подсказка выключена")
	c.V.ns.Wishes.SetShowTooltip(true)
	T.ok(c.V.ns.Wishes.TipLine(2862))
	for _, cl in pairs(c) do
		NoErrors(cl, cl:Name())
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
	end
end)

T.test("wishes: пустой список снимается у всех, старый пакет его не возвращает", function()
	local w, c = Build()
	local wires = Capture(c.A)
	T.ok(c.A.ns.Wishes.Save("2862"))
	w:Run(40)
	T.ok(c.V.ns.Wishes.Get(Key(c.A)))
	local ok, n = c.A.ns.Wishes.Save("")
	T.ok(ok)
	T.eq(n, 0)
	T.no(c.A.ns.Wishes.Posted())
	T.no(c.A.ns.Wishes.Own())
	w:Run(30)
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		T.no(viewer.ns.Wishes.Get(Key(c.A)), viewer:Name() .. ": список снят")
		T.no(viewer.ns.Wishes.TipLine(2862))
	end
	T.eq(Logged(c.V, "желания: Арагорн Светлый <Чиллзон> снял список (реле)"), 1)
	T.eq(#wires, 2, "размещение и снятие")
	c.K.ns.Comm.Dispatch(wires[1], "Арагорн Светлый-" .. c.A.realm, "GUILD")
	w:Run(5)
	T.no(c.K.ns.Wishes.Get(Key(c.A)), "повтор старого пакета не вернул список")
	-- Одни неузнанные названия список не снимают.
	T.ok(c.A.ns.Wishes.Save("2852"))
	local fail, why, names = c.A.ns.Wishes.Save("Неведомая вещь")
	T.no(fail)
	T.eq(why, "unknown")
	T.same(names, { "Неведомая вещь" })
	T.ok(c.A.ns.Wishes.Posted(), "прежний список на месте")
end)

T.test("wishes: порядок пакетов автора, чужие гильдии, игнор и неподписанное", function()
	local _, c = Build()
	local Wi = c.K.ns.Wishes
	local now = c.K.env.GetServerTime()
	local key = Feed(c.K, { at = now, seq = 5, items = { 1 } })
	T.same(Wi.Get(key).items, { 1 })
	Feed(c.K, { at = now, seq = 4, items = { 2 } })
	Feed(c.K, { at = now - 10, seq = 9, items = { 3 } })
	T.same(Wi.Get(key).items, { 1 }, "старые пакеты не принимаются")
	Feed(c.K, { at = now + 1, seq = 1, items = { 4 } })
	T.same(Wi.Get(key).items, { 4 })
	Feed(c.K, { at = now + 1, seq = 2, mode = "X" })
	T.no(Wi.Get(key), "снят")
	Feed(c.K, { at = now + 1, seq = 1, items = { 5 } })
	T.no(Wi.Get(key), "пакет до снятия его не вернул")
	local late = Feed(c.K, { name = "Вера Верная", at = now - c.K.ns.Config.WISH_KEEP - 10 })
	T.no(Wi.Get(late), "просроченный")
	local bk = c.K.ns.Util.Key("Борис Быстрый")
	Feed(c.K, { guild = "Левая гильдия", at = now + 5 })
	T.no(Wi.Get(bk), "гильдия не в объединении")
	Feed(c.K, { cert = { key = bk, name = "Борис Быстрый", guild = "Чиллзон" }, at = now + 6 })
	T.no(Wi.Get(bk), "гильдия сертификата не та")
	Feed(c.K, { dist = "GUILD", at = now + 7 })
	T.no(Wi.Get(bk), "чужая гильдия по GUILD")
	Feed(c.K, { ctx = {}, at = now + 8 })
	T.no(Wi.Get(bk), "без подписи")
	c.K.ns.store.ignore[bk] = true
	Feed(c.K, { at = now + 9 })
	T.no(Wi.Get(bk), "в игноре")
	NoErrors(c.K, "Карл")
end)

T.test("wishes: список повторяется раз в Every() минут, правка уходит после паузы", function()
	local w, c = Build()
	local C = c.A.ns.Config
	local wires = Capture(c.A)
	T.ok(c.A.ns.Wishes.Save("2862"))
	w:Run(60)
	T.eq(#wires, 1)
	local ok, why, wait = c.A.ns.Wishes.Save("2862, 2852")
	if not ok then
		T.eq(why, "wait")
		w:Run(wait + 1)
		ok = c.A.ns.Wishes.Save("2862, 2852")
	end
	T.ok(ok, "правка сохранена")
	w:Run(5) -- подпись
	T.eq(#wires, 2, "кнопка отправляет сразу")
	w:Run(c.A.ns.Wishes.Every() * 60 - 125)
	T.eq(#wires, 2, "до срока не повторяется")
	w:Run(300)
	T.eq(#wires, 3, "повтор по сроку")
	T.ok(c.A.ns.Wishes.Every() >= C.WISH_EVERY_MIN)
	NoErrors(c.A, "Арагорн")
end)

T.test("wishes: свой список и каталог переживают /reload, испорченное выбрасывается", function()
	local w, c = Build()
	T.ok(c.A.ns.Wishes.Save("2862\n12640"))
	w:Run(40)
	T.ok(c.V.ns.Wishes.Get(Key(c.A)))
	c.V.ns.store.wishes.cards["мусор"] = { name = 1 }
	local db = c.V.ns.db
	c.V:Logout()
	local v = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID", level = 22, db = db, reload = true })
	w:Run(5)
	T.same(v.ns.Wishes.Get(Key(c.A)).items, { 2862, 12640 }, "каталог на месте")
	T.no(v.ns.store.wishes.cards["мусор"], "испорченное выброшено")
	local adb = c.A.ns.db
	c.A:Logout()
	local a = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24, db = adb, reload = true })
	w:Run(5)
	T.eq(a.ns.Wishes.Text(), "2862\n12640", "свой текст на месте")
	T.same(a.ns.Wishes.Items(), { 2862, 12640 })
	T.ok(a.ns.Wishes.Posted())
	NoErrors(v, "Вера")
	NoErrors(a, "Арагорн")
end)

T.test("wishes: реле и репортёр прежней версии пересылают список и молчат о нём", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local c = {}
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, legacy = true })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER", level = 24, legacy = true })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, legacy = true })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3, class = "PRIEST", level = 21, legacy = true })
	w:Run(30)
	w:Init(c.K, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	w:Run(400)
	for _, id in ipairs({ "G", "B" }) do
		local old = c[id]
		old:Logout()
		c[id] = w:Client({ first = old.first, surname = old.surname, guild = old.guild, rank = old.rank, class = old.class,
			level = old.level, db = old.ns.db })
		for _, other in ipairs(w.clients) do other.ns.Roster.Scan() end
		w:Run(1)
	end
	w:Run(200)
	T.no(c.V.ns.Wishes, "у прежней версии желаний нет")
	T.ok(c.G.ns.Wishes.Save("2862"))
	w:Run(30)
	T.ok(c.B.ns.Wishes.Get(Key(c.G)), "список дошёл через 0.9")
	T.ok(c.B.ns.Wishes.Save(""))
	T.ok(c.G.ns.Wishes.Save(""))
	w:Run(60)
	T.no(c.B.ns.Wishes.Get(Key(c.G)), "снятие дошло")
	for _, cl in pairs(c) do
		NoErrors(cl, cl:Name())
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
		NoTrace(cl, cl:Name())
	end
end)

---------------------------------------------------------------------------
-- Вкладка
---------------------------------------------------------------------------
T.test("wishes pane: свой список, строки предметов и карточка предмета с шёпотом", function()
	local w, c = Build()
	local L = c.V.ns.L
	T.ok(c.A.ns.Wishes.Save("2862, 12640"))
	T.ok(c.K.ns.Wishes.Save("2862"))
	w:Run(40)
	c.V.items[2862], c.V.items[12640] = true, true
	c.V.ns.UI.Toggle("wishes")
	w:Run(1)
	local f = c.V.ns.WishesPane.frames
	T.ok(f.pane:IsShown())
	T.ok(f.mine:IsShown())
	T.no(f.card:IsShown())
	T.eq(f.mine.status:GetText(), L.WISH_NOT_POSTED)
	local first = f.rows[1]
	T.ok(first:IsShown())
	T.eq(first.it.id, 2862, "сначала то, что нужно большему числу игроков")
	T.eq(first.name:GetText(), "Грубое точило")
	T.eq(first.count:GetText(), L.WISH_COUNT:format(2))
	T.ok(f.rows[2]:IsShown())
	T.eq(f.rows[2].it.id, 12640)
	-- Поиск по имени и по названию.
	c.V.ns.WishesPane.Search("карл")
	T.ok(f.rows[1]:IsShown() and f.rows[1].it.id == 2862)
	T.no(f.rows[2]:IsShown(), "шлем Карлу не нужен")
	c.V.ns.WishesPane.Search("шлем")
	T.eq(f.rows[1].it.id, 12640)
	c.V.ns.WishesPane.Search("ничегоподобного")
	T.ok(f.empty:IsShown())
	c.V.ns.WishesPane.Search("")
	-- Карточка предмета: кому нужен, «Назад».
	f.rows[1]:Click()
	T.ok(f.card:IsShown())
	T.no(f.mine:IsShown())
	T.ok(f.rows[1].picked:IsShown())
	T.eq(f.card.title:GetText(), "Грубое точило")
	local names = {}
	for _, p in ipairs(f.people) do
		if p:IsShown() then names[#names + 1] = p.name:GetText() end
	end
	T.eq(#names, 2)
	local all = table.concat(names, "\n")
	T.ok(all:find("Арагорн Светлый", 1, true) and all:find("Карл Великий", 1, true))
	f.card.back:Click()
	T.ok(f.mine:IsShown())
	-- Свой список из поля.
	f.mine.edit:SetText("2852")
	f.mine.save:Click()
	T.ok(c.V.ns.Wishes.Posted())
	T.ok(f.mine.status:GetText():find(L.WISH_POSTED:format("1 " .. L.WISH_ITEMS_1), 1, true))
	w:Run(30)
	T.ok(c.A.ns.Wishes.Get(Key(c.V)), "ушёл остальным")
	f.mine.clear:Click()
	T.no(c.V.ns.Wishes.Posted())
	T.eq(f.mine.status:GetText(), L.WISH_CLEARED)
	NoErrors(c.V, "Вера")
end)
