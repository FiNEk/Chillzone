-- Мастера: формат карточки и списков рецептов, чтение окна профессии, каталог своей и чужой
-- гильдии, порядок пакетов автора, списки рецептов шёпотом, сроки, сохранения и вкладка.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function codec()
	return T.load({ "Config.lua", "Util.lua", "Codec.lua" }).Codec
end

local function card()
	return {
		mode = "C", st = 1794412800, guild = "Чиллзон Север", class = "DRUID", level = 22,
		profs = {
			{ id = 164, skill = 150, max = 225, n = 12, hash = "0a1z" },
			{ id = 186, skill = 75, max = 150, n = 3, hash = "zz00" },
		},
		note = "кую на заказ, свои материалы",
	}
end

T.test("crafters codec: карточка и снятие читаются обратно", function()
	local Codec = codec()
	local msg = Codec.EncodeCraft(card())
	T.ok(msg and #msg <= 255, "сообщение собрано")
	T.same(Codec.DecodeCraft(msg), card())
	local x = Codec.EncodeCraft({ mode = "X", st = 1794412800, guild = "Чиллзон" })
	T.eq(x, "W1~X~1794412800~Чиллзон")
	T.same(Codec.DecodeCraft(x), { mode = "X", st = 1794412800, guild = "Чиллзон" })
end)

T.test("crafters codec: числа в пределах, лишние и повторные профессии отбрасываются", function()
	local Codec = codec()
	local c = card()
	c.profs = {
		{ id = 164, skill = 1200, max = -5, n = 20000, hash = "0a1z" },
		{ id = 164, skill = 1, max = 1, n = 1, hash = "0000" }, -- повтор
		{ id = 0, skill = 1, max = 1, n = 1, hash = "0000" }, -- без номера
		{ id = 165, skill = 1, max = 1, n = 1, hash = "ABCD" }, -- хеш не в нижнем регистре
		{ id = 171, skill = 1, max = 1, n = 1, hash = "0001" },
		{ id = 197, skill = 1, max = 1, n = 1, hash = "0002" },
		{ id = 202, skill = 1, max = 1, n = 1, hash = "0003" },
		{ id = 333, skill = 1, max = 1, n = 1, hash = "0004" },
		{ id = 755, skill = 1, max = 1, n = 1, hash = "0005" }, -- шестая
	}
	local d = Codec.DecodeCraft(Codec.EncodeCraft(c))
	T.eq(#d.profs, 5, "не больше пяти профессий")
	T.same(d.profs[1], { id = 164, skill = 999, max = 0, n = 9999, hash = "0a1z" })
	T.eq(d.profs[5].id, 333)
	c.profs = { { id = 0, hash = "0000" } }
	T.no(Codec.EncodeCraft(c), "без профессий карточки нет")
	T.no(Codec.EncodeCraft({ mode = "C", st = 0, guild = "Чиллзон", profs = card().profs }), "без времени")
	T.no(Codec.EncodeCraft({ mode = "Z", st = 1794412800, guild = "Чиллзон" }), "незнакомый режим")
end)

T.test("crafters codec: длинная гильдия и примечание умещаются в 255 байт", function()
	local Codec = codec()
	local c = card()
	c.guild = ("Щ"):rep(24)
	c.profs = {}
	for i, id in ipairs({ 164, 165, 171, 197, 202 }) do
		c.profs[i] = { id = 9999000 + id, skill = 999, max = 999, n = 9999, hash = "zzzz" }
	end
	c.note = ("я"):rep(60)
	local msg = Codec.EncodeCraft(c)
	T.ok(msg and #msg <= 255, "уместилось: " .. tostring(msg and #msg))
	local d = Codec.DecodeCraft(msg)
	T.eq(#d.profs, 5)
	T.ok(#d.note > 0 and #d.note < 120 and #d.note % 2 == 0, "примечание укорочено по букве")
	c.guild, c.note = "Чиллзон", "  кую | на ~ заказ  "
	T.eq(Codec.DecodeCraft(Codec.EncodeCraft(c)).note, "кую на заказ", "без разметки и разделителей")
end)

T.test("crafters codec: мусор не читается, поля следующих версий не мешают", function()
	local Codec = codec()
	local base = "W1~C~1794412800~Чиллзон~DR~22~"
	T.ok(Codec.DecodeCraft(base .. "164:150:225:12:0a1z~"), "образец читается")
	T.no(Codec.DecodeCraft("W1~C~0~Чиллзон~DR~22~164:150:225:12:0a1z~"), "время 0")
	T.no(Codec.DecodeCraft("W1~Z~1794412800~Чиллзон~DR~22~164:150:225:12:0a1z~"), "незнакомый режим")
	T.no(Codec.DecodeCraft(base .. "~"), "без профессий")
	T.no(Codec.DecodeCraft(base .. "164:150:225:12:0A1Z~"), "хеш в верхнем регистре")
	T.no(Codec.DecodeCraft(base .. "164:150:225:12:0a1~"), "короткий хеш")
	T.no(Codec.DecodeCraft(base .. "164:1000:225:12:0a1z~"), "навык больше 999")
	T.no(Codec.DecodeCraft(base .. "0:150:225:12:0a1z~"), "номер 0")
	T.no(Codec.DecodeCraft(base .. "164:150:225:12:0a1z,164:1:1:1:0000~"), "повтор профессии")
	T.no(Codec.DecodeCraft(base .. "164:150:225:12:0a1z,~"), "пустая запись")
	T.no(Codec.DecodeCraft(base .. "1:1:1:1:0000,2:1:1:1:0000,3:1:1:1:0000,4:1:1:1:0000,5:1:1:1:0000,6:1:1:1:0000~"), "шесть профессий")
	T.no(Codec.DecodeCraft(base .. "164:150:225:12:0a1z~" .. ("x"):rep(255)), "слишком длинно")
	T.no(Codec.DecodeCraft("W1~X~1794412800~"), "снятие без гильдии")
	local d = Codec.DecodeCraft(base .. "164:150:225:12:0a1z:новое,186:1:75:2:0000~заметка~новое поле")
	T.eq(#d.profs, 2)
	T.eq(d.profs[1].hash, "0a1z")
	T.eq(d.note, "заметка")
end)

T.test("crafters codec: витрина — до трёх рецептов на карточку", function()
	local Codec = codec()
	local c = card()
	c.profs[1].show = { 2660, 2661 }
	c.profs[2].show = { 2149 }
	local msg = Codec.EncodeCraft(c)
	T.ok(msg:find("~164:150:225:12:0a1z:2660.2661,186:75:150:3:zz00:2149~", 1, true), "номера через точку после хеша")
	T.same(Codec.DecodeCraft(msg), c)
	-- Больше трёх на карточку, повторы и неподходящие номера отбрасываются.
	c.profs[1].show = { 2660, 2660, 0, 2661, 12345678, 2662 }
	local d = Codec.DecodeCraft(Codec.EncodeCraft(c))
	T.same(d.profs[1].show, { 2660, 2661, 2662 })
	T.no(d.profs[2].show, "на вторую профессию места не осталось")
	-- Чужая витрина читается так же строго, испорченная не мешает карточке.
	local base = "W1~C~1794412800~Чиллзон~DR~22~"
	d = Codec.DecodeCraft(base .. "164:150:225:12:0a1z:1.2.3.4,186:1:75:2:0000:5~")
	T.same(d.profs[1].show, { 1, 2, 3 })
	T.no(d.profs[2].show, "четвёртый — лишний")
	d = Codec.DecodeCraft(base .. "164:150:225:12:0a1z:x1,186:1:75:2:0000:7.7.:8~заметка")
	T.eq(#d.profs, 2, "карточка читается")
	T.no(d.profs[1].show, "не число — витрины нет")
	T.same(d.profs[2].show, { 7 }, "повтор и поле следующей версии не мешают")
	T.eq(d.note, "заметка")
	d = Codec.DecodeCraft(base .. "164:150:225:12:0a1z:0.99999999.5~")
	T.same(d.profs[1].show, { 5 }, "0 и слишком длинный номер пропущены")
	-- Самая длинная карточка с витриной умещается в 255 байт.
	c.guild, c.profs = ("Щ"):rep(24), {}
	for i, id in ipairs({ 164, 165, 171, 197, 202 }) do
		c.profs[i] = { id = 9999000 + id, skill = 999, max = 999, n = 9999, hash = "zzzz" }
	end
	c.profs[5].show = { 9999997, 9999998, 9999999 }
	c.note = ("я"):rep(60)
	msg = Codec.EncodeCraft(c)
	T.ok(msg and #msg <= 255, "уместилось: " .. tostring(msg and #msg))
	T.same(Codec.DecodeCraft(msg).profs[5].show, { 9999997, 9999998, 9999999 }, "витрина цела, укорочено примечание")
end)

T.test("crafters codec: карточка ходит в конверте строки чата", function()
	local Codec = codec()
	local msg = Codec.EncodeCraft(card())
	local env = Codec.WrapCraft(msg)
	T.eq(env, "M1~A~Чиллзон Север~" .. msg)
	local inner, guild = Codec.UnwrapCraft(env)
	T.eq(inner, msg)
	T.eq(guild, "Чиллзон Север")
	T.no(Codec.DecodeChat(env), "чат конверт не читает")
	-- Образец DecodeChat вышедших версий 0.9-0.14.2: третье поле — номер строки, а здесь W1.
	T.no((env:match("^M1~(%u)~([^~|]+)~(%d%d?%d?%d?)~(%u?%u?)~(.+)$")), "вышедшие версии его не читают")
	T.no(Codec.UnwrapGroup(env), "это не объявление")
	local x = Codec.EncodeCraft({ mode = "X", st = 1794412800, guild = "Чиллзон" })
	T.eq((Codec.UnwrapCraft(Codec.WrapCraft(x))), x, "снятие тоже")
	-- Гильдию конверта проверяет подпись, поэтому она должна быть гильдией карточки.
	T.no(Codec.UnwrapCraft("M1~A~Чиллзон~" .. msg), "внутри карточка другой гильдии")
	T.no(Codec.UnwrapCraft("M1~C~Чиллзон Север~" .. msg), "только вид A")
	T.no(Codec.WrapCraft(Codec.EncodeChat("A", "Чиллзон", 12, "MAGE", "привет")), "в конверт идёт только W1")
	local group = Codec.WrapGroup(Codec.EncodeGroup({ mode = "X", id = 1794412800, guild = "Чиллзон" }))
	T.no(Codec.UnwrapCraft(group), "конверт объявления — не карточка")
	T.ok(Codec.UnwrapGroup(group), "и по-прежнему объявление")
end)

T.test("crafters codec: список рецептов упаковывается разностями", function()
	local Codec = codec()
	T.eq((Codec.PackIds({ 1, 2, 3 })), "111")
	T.eq((Codec.PackIds({ 31 })), "V")
	T.eq((Codec.PackIds({ 32 })), "X0", "больше 31 — два знака")
	local packed, n = Codec.PackIds({ 3115, 2660, 2661, 2660, "x", 0, -5, 2.5, 10000000, 16639 })
	T.eq(n, 4, "мусор и повторы выброшены")
	T.same(Codec.UnpackIds(packed), { 2660, 2661, 3115, 16639 })
	T.same(Codec.UnpackIds((Codec.PackIds({ 9999999, 1 }))), { 1, 9999999 }, "большая разность")
	T.eq((Codec.PackIds({})), "")
	T.same(Codec.UnpackIds(""), {})
	T.eq(select(2, Codec.PackIds({ 1, 2, 3 }, 2)), 2, "не больше max")
	T.no(Codec.UnpackIds("111", 2), "больше max не читается")
	T.no(Codec.UnpackIds("1!1"), "чужой знак")
	T.no(Codec.UnpackIds("X"), "оборванное число")
	T.no(Codec.UnpackIds("0"), "номер 0")
	T.no(Codec.UnpackIds("10"), "повтор номера")
	T.no(Codec.UnpackIds("______1"), "число длиннее пяти знаков")
end)

T.test("crafters codec: хеш списка устойчив и меняется с правкой", function()
	local Codec = codec()
	T.eq(Codec.IdsHash(""), "0000")
	T.eq(Codec.IdsHash("1"), "001d")
	local a = Codec.IdsHash((Codec.PackIds({ 2660, 2661, 3115 })))
	T.ok(a:find("^[0-9a-z][0-9a-z][0-9a-z][0-9a-z]$"), "четыре знака base36")
	T.eq(Codec.IdsHash((Codec.PackIds({ 3115, 2661, 2660 }))), a, "порядок номеров не важен")
	T.ok(Codec.IdsHash((Codec.PackIds({ 2660, 2661, 3116 }))) ~= a, "другой список — другой хеш")
end)

T.test("crafters codec: страницы режутся по границам чисел", function()
	local Codec = codec()
	local ids = {}
	for i = 1, 300 do ids[i] = i * 100 end
	local packed = Codec.PackIds(ids)
	T.eq(#packed, 600, "разность 100 — два знака")
	local pages = Codec.CraftPages(packed)
	T.eq(#pages, 3)
	T.eq(table.concat(pages), packed)
	local small = Codec.CraftPages(packed, 7)
	for _, p in ipairs(small) do T.ok(#p <= 7 and #p % 2 == 0, "страница из целых чисел") end
	T.eq(table.concat(small), packed)
	T.same(Codec.CraftPages(""), { "" })
	local hash = Codec.IdsHash(packed)
	local wl = Codec.EncodeCraftPages(164, hash, packed)
	T.eq(#wl, 3)
	local got = {}
	for i, s in ipairs(wl) do
		T.ok(#s <= 255, "страница умещается")
		local p = Codec.DecodeCraftPage(s)
		T.eq(p.prof, 164)
		T.eq(p.hash, hash)
		T.eq(p.i, i)
		T.eq(p.n, 3)
		got[i] = p.data
	end
	T.same(Codec.UnpackIds(table.concat(got)), ids)
	local same = Codec.EncodeCraftPages(164, "0a1z", packed, true)
	T.same(same, { "WL~164~0a1z~0~0~" })
	T.same(Codec.DecodeCraftPage(same[1]), { prof = 164, hash = "0a1z", i = 0, n = 0, data = "" })
	T.no(Codec.DecodeCraftPage("WL~164~0a1z~3~2~11"), "страница за пределом")
	T.no(Codec.DecodeCraftPage("WL~164~0A1Z~1~1~11"), "хеш")
	T.no(Codec.DecodeCraftPage("WL~164~0a1z~1~1~1!"), "чужой знак")
	T.no(Codec.DecodeCraftPage("WL~164~0a1z~1~33~11"), "страниц больше 32")
	T.no(Codec.DecodeCraftPage("WL~0~0a1z~1~1~11"), "профессия 0")
	T.no(Codec.DecodeCraftPage("WL~164~0a1z~1~1~" .. ("1"):rep(201)), "страница длиннее 200")
end)

T.test("crafters codec: запрос списка", function()
	local Codec = codec()
	T.eq(Codec.EncodeCraftQuery(164, "abcdefgh12345678"), "WR~164~abcdefgh12345678~0")
	local prof, fp, hash = Codec.DecodeCraftQuery("WR~164~abcdefgh12345678~0")
	T.eq(prof, 164)
	T.eq(fp, "abcdefgh12345678")
	T.no(hash, "списка у спрашивающего нет")
	prof, fp, hash = Codec.DecodeCraftQuery(Codec.EncodeCraftQuery(171, "abc_-1", "0a1z"))
	T.eq(prof, 171)
	T.eq(fp, "abc_-1")
	T.eq(hash, "0a1z")
	T.no(Codec.DecodeCraftQuery("WR~0~abc~0"), "профессия 0")
	T.no(Codec.DecodeCraftQuery("WR~164~abc~ABCD"), "хеш")
	T.no(Codec.DecodeCraftQuery("WR~164~a|b~0"), "отпечаток")
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

-- Окно кузнечного дела: изучены 2660, 2661 и 2662, 3115 — нет.
local function Smith(skill, recipes)
	return {
		id = 164, skill = skill or 150, max = 225,
		recipes = recipes or { [2660] = true, [2661] = true, [2662] = true, [3115] = false },
	}
end

-- Открыть окно профессии и дать аддону его прочитать.
local function Learn(c, p)
	c:OpenProfession(p)
	c.world:Run(1)
end

-- Мастер с размещённой карточкой кузнеца.
local function Master(c, note)
	Learn(c, Smith())
	c.ns.Crafters.SetPost(164, true)
	local ok, why = c.ns.Crafters.Post(note or "кую на заказ")
	T.ok(ok, "карточка размещена: " .. tostring(why))
	c.world:Run(30)
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

-- Подписанные карточки, которые клиент отправил своей гильдии.
local function Capture(c)
	local wires, send = {}, c.ns.Comm.Send
	c.ns.Comm.Send = function(dist, payload, opts)
		if dist == "GUILD" and payload:sub(1, 3) == "S1~" and payload:find("~W1~", 1, true) then wires[#wires + 1] = payload end
		return send(dist, payload, opts)
	end
	return wires
end

-- Шёпоты клиента вида kind ("WR", "WL"): { payload, target }.
local function Whispers(c, kind)
	local list, send = {}, c.ns.Comm.Send
	c.ns.Comm.Send = function(dist, payload, opts)
		if dist == "WHISPER" and payload:sub(1, #kind + 1) == kind .. "~" then
			list[#list + 1] = { payload = payload, target = opts and opts.target }
		end
		return send(dist, payload, opts)
	end
	return list
end

-- Карточка мимо сети, как её отдал бы Comm.Dispatch после проверки подписи.
local function Feed(cl, o)
	local ns = cl.ns
	local at = o.at or cl.env.GetServerTime()
	local name = o.name or "Борис Быстрый"
	local guild = o.guild or "Чиллзон Север"
	local cert = o.cert or { key = ns.Util.Key(name), name = name, guild = guild }
	local msg = ns.Codec.EncodeCraft({
		mode = o.mode or "C", st = at, guild = guild, class = "PRIEST", level = 21, note = o.note,
		profs = { { id = 164, skill = o.skill or 1, max = 75, n = 1, hash = "0001" } },
	})
	ns.Crafters.Receive(msg, name, o.dist or "RELAY", o.ctx or {
		authenticated = true, certificate = cert, wire = ("S1~fp~%d~%d~x"):format(at, o.seq or 1),
	})
	return cert.key
end

-- Нет следов карточки в чате игры и в окне.
local function NoTrace(cl, label)
	T.eq(cl:Saw("W1~"), 0, label .. ": в чате игры нет карточки")
	for _, tier in ipairs({ "A", "C", "L" }) do
		for _, m in ipairs(cl.ns.Chat.History(tier)) do
			T.no(tostring(m.x):find("W1~", 1, true), label .. ": в окне нет карточки")
		end
	end
end

---------------------------------------------------------------------------
-- Свои профессии
---------------------------------------------------------------------------
T.test("crafters: окно профессии читается, чужое окно, бой и закрытое окно — нет", function()
	local w, c = Build()
	local Cr, L = c.A.ns.Crafters, c.A.ns.L
	T.eq(#Cr.MyProfs(), 0)
	Learn(c.A, Smith())
	local mine = Cr.MyProfs()
	T.eq(#mine, 1)
	T.eq(mine[1].id, 164)
	T.eq(mine[1].skill, 150)
	T.eq(mine[1].max, 225)
	T.eq(mine[1].n, 3, "только изученные")
	T.no(mine[1].post, "в карточку профессия попадает только по отметке")
	T.same(Cr.Recipes(Key(c.A), 164), { 2660, 2661, 2662 })
	T.eq(c.A:Saw(L.CRAFT_HINT:format("Кузнечное дело")), 1, "подсказка в чат")
	T.eq(Logged(c.A, "мастера: прочитана профессия Кузнечное дело: навык 150/225, рецептов 3"), 1)
	-- То же окно ещё раз: ни подсказки, ни записи в журнале.
	c.A:CloseProfession()
	Learn(c.A, Smith())
	T.eq(c.A:Saw(L.CRAFT_HINT:format("Кузнечное дело")), 1)
	T.eq(Logged(c.A, "мастера: прочитана профессия"), 1)
	-- Чужое окно по ссылке и окно у НИП не читаются.
	c.A:CloseProfession()
	Learn(c.A, { id = 197, skill = 300, max = 300, recipes = { [2149] = true }, linked = true })
	T.eq(#Cr.MyProfs(), 1, "по ссылке")
	T.eq(Cr.lastSkip, "external")
	T.eq(c.A.ns.Views.CraftMine().hint, L.CRAFT_SKIP_EXTERNAL)
	c.A:CloseProfession()
	Learn(c.A, { id = 197, skill = 300, max = 300, recipes = { [2149] = true }, npc = true })
	T.eq(#Cr.MyProfs(), 1, "у НИП")
	-- В бою тоже нет; обновление окна после боя читается.
	c.A:CloseProfession()
	c.A.combat = true
	Learn(c.A, { id = 165, skill = 80, max = 150, recipes = { [2149] = true, [2152] = true } })
	T.eq(Cr.lastSkip, "combat")
	T.eq(c.A.ns.Views.CraftMine().hint, L.CRAFT_SKIP_COMBAT)
	T.eq(#Cr.MyProfs(), 1)
	c.A.combat = false
	c.A:Fire("TRADE_SKILL_LIST_UPDATE")
	w:Run(1)
	T.eq(#Cr.MyProfs(), 2)
	T.no(Cr.lastSkip)
	T.eq(Cr.MyProfs()[2].id, 165)
	-- Профессия без изученных рецептов не показывается, закрытое окно не читается.
	c.A:CloseProfession()
	Learn(c.A, { id = 186, skill = 50, max = 75, recipes = {} })
	T.eq(#Cr.MyProfs(), 2, "без рецептов")
	c.A:CloseProfession()
	c.A.profession = { id = 171, skill = 10, max = 75, recipes = { [3104] = true } }
	c.A:Fire("TRADE_SKILL_LIST_UPDATE")
	w:Run(1)
	T.eq(#Cr.MyProfs(), 2, "окно закрыто")
	NoErrors(c.A, "Арагорн")
	T.eq(#c.A:Leaks(), 0, "глобалов нет")
end)

T.test("crafters: без C_TradeSkillUI вкладка объясняет, что читать нечего", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local d = w:Client({ first = "Дина", surname = "Добрая", guild = "Чиллзон", rank = 1, noTradeSkill = true })
	w:Run(5)
	T.no(d.ns.Crafters.CanRead())
	d:OpenProfession(Smith())
	w:Run(1)
	T.eq(#d.ns.Crafters.MyProfs(), 0)
	T.eq(d.ns.Views.CraftMine().hint, d.ns.L.CRAFT_NOAPI)
	T.eq(d.ns.Crafters.RecipeName(2660), nil, "название ещё не спрошено")
	w:Run(1)
	T.eq(d.ns.Crafters.RecipeName(2660), "Грубое точило", "названия берутся у C_Spell")
	local info = d.ns.Crafters.RecipeDetails(2660)
	T.no(info.icon, "значка нет")
	T.no(info.reagents, "реагентов нет")
	T.same(d.ns.Views.CraftReagents(info), {})
	NoErrors(d, "Дина")
	T.eq(#d:Leaks(), 0)
end)

---------------------------------------------------------------------------
-- Карточка в сети
---------------------------------------------------------------------------
T.test("crafters: карточку видят своя гильдия по GUILD и чужая через реле", function()
	local _, c = Build()
	local wires = Capture(c.A)
	Master(c.A)
	T.eq(#wires, 1, "своей гильдии — один пакет")
	local hash = c.A.ns.Crafters.MyProfs()[1].hash
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		local e = viewer.ns.Crafters.Get(Key(c.A))
		T.ok(e, viewer:Name() .. " видит карточку")
		T.eq(e.name, "Арагорн Светлый")
		T.eq(e.guild, "Чиллзон")
		T.eq(e.class, "WARRIOR")
		T.eq(e.level, 24)
		T.eq(e.note, "кую на заказ")
		T.eq(#e.profs, 1)
		T.same(e.profs[1], { id = 164, skill = 150, max = 225, n = 3, hash = hash })
		T.eq(viewer.ns.Crafters.Count(), 1)
		NoTrace(viewer, viewer:Name())
	end
	T.eq(Logged(c.K, "мастера: карточка Арагорн Светлый <Чиллзон> принята (своя гильдия)"), 1)
	T.eq(Logged(c.V, "мастера: карточка Арагорн Светлый <Чиллзон> принята (реле)"), 1)
	T.no(c.A.ns.Crafters.Get(Key(c.A)), "своя карточка не из сети")
	local own = c.A.ns.Crafters.Own()
	T.ok(own and own.own, "своя — из сохранений персонажа")
	T.eq(own.profs[1].id, 164)
	T.eq(c.A.ns.Crafters.Count(), 1)
	T.eq(#c.A.ns.Crafters.Cards(), 0)
	for _, cl in pairs(c) do
		NoErrors(cl, cl:Name())
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
	end
end)

T.test("crafters: снятая карточка пропадает, старый пакет её не возвращает", function()
	local w, c = Build()
	local wires = Capture(c.A)
	Master(c.A)
	T.ok(c.V.ns.Crafters.Want(Key(c.A), 164))
	w:Run(20)
	T.ok(c.V.ns.Crafters.Recipes(Key(c.A), 164), "список рецептов загружен")
	T.ok(c.A.ns.Crafters.Withdraw())
	T.no(c.A.ns.Crafters.Own())
	w:Run(30)
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		T.no(viewer.ns.Crafters.Get(Key(c.A)), viewer:Name() .. ": карточка снята")
	end
	T.no(c.V.ns.Crafters.Recipes(Key(c.A), 164), "список ушёл вместе с карточкой")
	T.eq(Logged(c.V, "мастера: Арагорн Светлый <Чиллзон> снял карточку (реле)"), 1)
	T.eq(#wires, 2, "размещение и снятие")
	c.K.ns.Comm.Dispatch(wires[1], "Арагорн Светлый-" .. c.A.realm, "GUILD")
	w:Run(5)
	T.no(c.K.ns.Crafters.Get(Key(c.A)), "повтор старого пакета не вернул карточку")
	-- Снять ещё раз нечего.
	T.no(c.A.ns.Crafters.Withdraw())
end)

T.test("crafters: порядок пакетов автора — по времени и номеру подписи", function()
	local _, c = Build()
	local Cr = c.K.ns.Crafters
	local now = c.K.env.GetServerTime()
	local key = Feed(c.K, { at = now, seq = 5, note = "первая" })
	T.eq(Cr.Get(key).note, "первая")
	Feed(c.K, { at = now, seq = 4, note = "старее" })
	Feed(c.K, { at = now - 10, seq = 9, note = "раньше" })
	T.eq(Cr.Get(key).note, "первая", "старые пакеты не принимаются")
	T.ok(Cr.stats.stale >= 2)
	Feed(c.K, { at = now, seq = 6, note = "вторая" })
	T.eq(Cr.Get(key).note, "вторая")
	T.eq(Logged(c.K, "мастера: карточка Борис Быстрый <Чиллзон Север> обновлена (реле)"), 0, "примечание — не правка st")
	Feed(c.K, { at = now + 1, seq = 1, skill = 2, note = "вторая" })
	T.eq(Logged(c.K, "мастера: карточка Борис Быстрый <Чиллзон Север> обновлена (реле)"), 1, "новая st — правка")
	Feed(c.K, { at = now + 1, seq = 2, mode = "X" })
	T.no(Cr.Get(key), "снята")
	Feed(c.K, { at = now, seq = 6, note = "вторая" })
	T.no(Cr.Get(key), "пакет до снятия её не вернул")
	Feed(c.K, { at = now + 2, seq = 1, note = "третья" })
	T.eq(Cr.Get(key).note, "третья", "новая карточка после снятия")
	-- Просроченная не принимается.
	local late = Feed(c.K, { name = "Вера Верная", at = now - c.K.ns.Config.CRAFT_KEEP - 10 })
	T.no(Cr.Get(late))
	T.eq(Logged(c.K, "мастера: карточка Вера Верная <Чиллзон Север> не принята: пришла просроченной (реле)"), 1)
	NoErrors(c.K, "Карл")
end)

T.test("crafters: чужие гильдии, гильдия сертификата, игнор и неподписанное не принимаются", function()
	local w, c = Build()
	local K = c.K.ns
	local bk = K.Util.Key("Борис Быстрый")
	Feed(c.K, { guild = "Левая гильдия" })
	T.no(K.Crafters.Get(bk), "гильдия не в объединении")
	Feed(c.K, { cert = { key = bk, name = "Борис Быстрый", guild = "Чиллзон" } })
	T.no(K.Crafters.Get(bk), "гильдия сертификата другая")
	T.eq(Logged(c.K, "мастера: карточка Борис Быстрый не принята: гильдия сертификата <Чиллзон>, в карточке <Чиллзон Север> (реле)"), 1)
	Feed(c.K, { dist = "GUILD" })
	T.no(K.Crafters.Get(bk), "чужая гильдия по GUILD не пишет")
	Feed(c.K, { dist = "WHISPER" })
	T.no(K.Crafters.Get(bk), "шёпотом карточки не ходят")
	Feed(c.K, { name = "Арагорн Светлый", guild = "Чиллзон" })
	T.no(K.Crafters.Get(Key(c.A)), "своя гильдия через реле не пишет")
	Feed(c.K, { ctx = { certificate = { key = bk, name = "Борис Быстрый", guild = "Чиллзон Север" }, wire = "S1~fp~1~1~x" } })
	T.no(K.Crafters.Get(bk), "без подписи")
	Feed(c.K, { name = "Карл Великий", cert = { key = K.myKey, name = "Карл Великий", guild = "Чиллзон Север" } })
	T.no(K.Crafters.Get(K.myKey), "своя карточка из сети не берётся")
	Feed(c.K, {})
	T.ok(K.Crafters.Get(bk), "образец принимается")
	-- Игнор: карточка не показывается и новая не принимается.
	K.store.ignore[bk] = "Борис Быстрый"
	T.eq(#K.Crafters.Cards(), 0, "автор в игноре не показывается")
	Feed(c.K, { at = c.K.env.GetServerTime() + 5 })
	T.no(K.Crafters.Get(bk), "и выброшен из каталога")
	-- В сети: неподписанный конверт и подпись с чужой гильдией внутри.
	Learn(c.A, Smith())
	local msg = c.A.ns.Codec.EncodeCraft({
		mode = "C", st = c.A.env.GetServerTime(), guild = "Чиллзон", class = "WARRIOR", level = 24,
		profs = { { id = 164, skill = 300, max = 300, n = 1, hash = "0001" } },
	})
	c.K.ns.Comm.Dispatch(c.A.ns.Codec.WrapCraft(msg), "Арагорн Светлый-" .. c.A.realm, "GUILD")
	local fake = c.A.ns.Codec.EncodeCraft({
		mode = "C", st = c.A.env.GetServerTime(), guild = "Чиллзон Север", class = "WARRIOR", level = 24,
		profs = { { id = 164, skill = 300, max = 300, n = 1, hash = "0001" } },
	})
	c.A.ns.Security.Seal(c.A.ns.Codec.WrapCraft(fake), function(wire)
		if not wire then return end
		c.A.ns.Comm.Send("GUILD", wire, {})
		c.A.ns.Relay.Out("P", wire)
	end)
	w:Run(30)
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		T.no(viewer.ns.Crafters.Get(Key(c.A)), viewer:Name() .. ": подделки нет")
		NoTrace(viewer, viewer:Name())
		NoErrors(viewer, viewer:Name())
	end
end)

T.test("crafters: автора в игноре не видно, остальные видят", function()
	local _, c = Build()
	c.K.ns.store.ignore[Key(c.A)] = "Арагорн Светлый"
	Master(c.A)
	T.no(c.K.ns.Crafters.Get(Key(c.A)))
	T.ok(c.V.ns.Crafters.Get(Key(c.A)))
end)

T.test("crafters: ушедший из гильдии согильдиец пропадает из каталога", function()
	local w, c = Build()
	Master(c.A)
	T.ok(c.K.ns.Crafters.Get(Key(c.A)))
	c.A.guild = nil
	c.K.ns.Roster.Scan()
	w:Run(1)
	T.no(c.K.ns.Crafters.Get(Key(c.A)))
	T.eq(Logged(c.K, "мастера: карточка Арагорн Светлый <Чиллзон> убрана: его нет в ростере"), 1)
	NoErrors(c.K, "Карл")
end)

T.test("crafters: карточка повторяется раз в Every() минут, правка уходит после паузы", function()
	local w, c = Build()
	local C = c.A.ns.Config
	C.CRAFT_EVERY_MIN, C.CRAFT_EVERY_MAX = 10, 10
	local wires = Capture(c.A)
	Master(c.A)
	T.eq(#wires, 1, "размещение — один пакет")
	w:Run(540)
	T.eq(#wires, 1, "раньше срока не повторяется")
	w:Run(60)
	T.eq(#wires, 2, "повтор")
	T.eq(Logged(c.V, "обновлена"), 0, "повтор — не правка")
	-- Навык вырос: правка уходит не раньше CRAFT_UPDATE_GAP после прошлой отправки.
	Learn(c.A, Smith(155))
	T.ok(c.A.ns.Crafters.Dirty())
	T.ok(c.A.ns.Views.CraftMine().status:find(c.A.ns.L.CRAFT_CHANGED, 1, true), "игрок видит, что есть изменения")
	w:Run(500)
	T.eq(#wires, 2)
	w:Run(120)
	T.eq(#wires, 3, "правка ушла")
	T.no(c.A.ns.Crafters.Dirty())
	T.eq(c.V.ns.Crafters.Get(Key(c.A)).profs[1].skill, 155)
	T.eq(Logged(c.V, "мастера: карточка Арагорн Светлый <Чиллзон> обновлена (реле)"), 1)
	-- «Обновить» уходит сразу, второе нажатие — не раньше CRAFT_POST_GAP.
	T.ok(c.A.ns.Crafters.Post())
	local ok, why = c.A.ns.Crafters.Post()
	T.no(ok)
	T.eq(why, "busy", "пока идёт подпись")
	w:Run(1)
	local wait
	ok, why, wait = c.A.ns.Crafters.Post()
	T.no(ok)
	T.eq(why, "wait")
	T.ok(wait and wait > 0 and wait <= C.CRAFT_POST_GAP)
	w:Run(5)
	T.eq(#wires, 4)
	-- В блокировке повтор ждёт её конца.
	c.A.lockdown = true
	w:Run(700)
	T.eq(#wires, 4, "в блокировке не уходит")
	c.A.lockdown = false
	w:Run(10)
	T.eq(#wires, 5, "после блокировки")
	NoErrors(c.A, "Арагорн")
end)

T.test("crafters: без отметки, без профессий и без сертификата не размещается", function()
	local _, c = Build()
	local Cr = c.A.ns.Crafters
	local ok, why = Cr.Post("x")
	T.no(ok)
	T.eq(why, "noprofs")
	Learn(c.A, Smith())
	ok, why = Cr.Post("x")
	T.no(ok)
	T.eq(why, "none")
	T.no(Cr.Posted())
	Cr.SetPost(164, true)
	Cr.SetPost(999, true)
	T.eq(#Cr.MyProfs(), 1, "непрочитанную профессию не отметить")
	c.A.ns.Security.MyCertificate = function() return nil end
	ok, why = Cr.Post("x")
	T.no(ok)
	T.eq(why, "nocert")
	T.no(Cr.Posted())
end)

T.test("crafters: после /reload карточка не уходит раньше срока, свои данные на месте", function()
	local w, c = Build()
	Master(c.A)
	local db = c.A.ns.db
	c.A:Logout()
	local again = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24, db = db, reload = true })
	local wires = Capture(again)
	w:Run(600)
	T.eq(#wires, 0, "повтор не раньше Every()")
	T.ok(again.ns.Crafters.Posted())
	T.eq(again.ns.Crafters.Note(), "кую на заказ")
	T.eq(again.ns.Crafters.Own().profs[1].id, 164)
	T.same(again.ns.Crafters.Recipes(Key(again), 164), { 2660, 2661, 2662 })
	T.ok(c.V.ns.Crafters.Get(Key(again)), "у остальных карточка осталась")
	NoErrors(again, "после /reload")
end)

T.test("crafters: витрина — свои рецепты, не больше трёх, правка уходит остальным", function()
	local w, c = Build()
	Learn(c.A, Smith(150, { [2660] = true, [2661] = true, [2662] = true, [2663] = true }))
	local Cr = c.A.ns.Crafters
	Cr.SetPost(164, true)
	T.ok(Cr.Post("кую"))
	w:Run(30)
	T.eq(Cr.ShowCount(), 0)
	T.ok(Cr.SetShow(164, 2662, true))
	T.ok(Cr.SetShow(164, 2660, true))
	T.ok(Cr.Dirty(), "витрина — правка карточки")
	T.same(Cr.Own().profs[1].show, { 2662, 2660 }, "по порядку отметки")
	local ok, why = Cr.SetShow(164, 3115, true)
	T.no(ok)
	T.eq(why, "missing", "неизученный рецепт")
	ok, why = Cr.SetShow(165, 2149, true)
	T.no(ok)
	T.eq(why, "missing", "профессии нет в карточке")
	T.ok(Cr.SetShow(164, 2661, true))
	ok, why = Cr.SetShow(164, 2663, true)
	T.no(ok)
	T.eq(why, "full", "больше трёх нельзя")
	T.ok(Cr.SetShow(164, 2660, false))
	T.ok(Cr.SetShow(164, 2663, true), "после снятия место есть")
	T.same(Cr.Own().profs[1].show, { 2662, 2661, 2663 })
	-- Правка уходит сама, не раньше CRAFT_UPDATE_GAP после прошлой отправки.
	w:Run(500)
	T.ok(Cr.Dirty(), "раньше паузы не уходит")
	w:Run(130)
	T.no(Cr.Dirty(), "правка ушла")
	T.same(c.V.ns.Crafters.Get(Key(c.A)).profs[1].show, { 2662, 2661, 2663 }, "другой гильдии — через реле")
	T.same(c.K.ns.Crafters.Get(Key(c.A)).profs[1].show, { 2662, 2661, 2663 }, "своей — по GUILD")
	-- Профессию сняли с карточки и вернули: витрина вернулась вместе с ней.
	Cr.SetPost(164, false)
	T.eq(Cr.ShowCount(), 0)
	Cr.SetPost(164, true)
	T.eq(Cr.ShowCount(), 3)
	-- Витрина переживает /reload автора; у смотрящего испорченная сохранённая витрина чинится.
	local stored = c.V.ns.store.crafters.cards[Key(c.A)]
	stored.profs[1].show = { 2662, "x", 2661, 5, 6 }
	local db, vdb = c.A.ns.db, c.V.ns.db
	c.A:Logout()
	c.V:Logout()
	local again = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24, db = db, reload = true })
	local vera = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID", level = 22, db = vdb, reload = true })
	T.same(again.ns.Crafters.Own().profs[1].show, { 2662, 2661, 2663 })
	T.no(again.ns.Crafters.Dirty(), "после /reload правок нет")
	T.same(vera.ns.Crafters.Get(Key(again)).profs[1].show, { 2662, 2661, 5 })
	NoErrors(again, "Арагорн")
	NoErrors(vera, "Вера")
end)

-- Так было в игре: «Разместить» сразу после /reload, пока ни одно реле ещё не ответило на опрос.
T.test("crafters: карточка, размещённая до ответа реле, уходит другим гильдиям после него", function()
	local w, c = Build()
	Learn(c.A, Smith())
	local db = c.A.ns.db
	c.A:Logout()
	local again = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24, db = db, reload = true })
	w:Run(0) -- вход и сертификат, но реле ещё не спрошено
	again.ns.Crafters.SetPost(164, true)
	T.ok(again.ns.Crafters.Post("кую на заказ"))
	w:Run(1)
	T.eq(Logged(again, "отвечающего реле нет: остальным уйдёт после его ответа"), 1, "реле ещё не ответило")
	T.no(c.V.ns.Crafters.Get(Key(again)), "другой гильдии пока нет")
	w:Run(60)
	T.ok(c.V.ns.Crafters.Get(Key(again)), "дошла после ответа реле")
	T.ok(c.K.ns.Crafters.Get(Key(again)), "своей гильдии — сразу по GUILD")
	NoErrors(again, "после /reload")
end)

T.test("crafters: каталог и списки переживают /reload смотрящего, испорченное выбрасывается", function()
	local w, c = Build()
	Master(c.A)
	T.ok(c.B.ns.Crafters.Want(Key(c.A), 164))
	w:Run(20)
	local store = c.B.ns.store.crafters
	store.cards["мусор"] = { name = 5 }
	store.lists["мусор"] = { [164] = { hash = 1 } }
	local db = c.B.ns.db
	c.B:Logout()
	local b = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1, class = "PRIEST", level = 21, db = db, reload = true })
	w:Run(5)
	local e = b.ns.Crafters.Get(Key(c.A))
	T.ok(e, "карточка восстановлена")
	T.eq(e.note, "кую на заказ")
	T.same(b.ns.Crafters.Recipes(Key(c.A), 164), { 2660, 2661, 2662 }, "список восстановлен")
	T.no(b.ns.Crafters.Get("мусор"))
	T.no(b.ns.store.crafters.lists["мусор"])
	NoErrors(b, "Борис")
end)

T.test("crafters: каталог чистится по сроку и по числу карточек", function()
	local w, c = Build()
	local K = c.K.ns
	K.Config.CRAFT_MAX = 2
	local now = c.K.env.GetServerTime()
	local old = Feed(c.K, { name = "Борис Быстрый", at = now - 1000 })
	Feed(c.K, { name = "Вера Верная", at = now - 100 })
	T.eq(#K.Crafters.Cards(), 2)
	Feed(c.K, { name = "Глеб Гордый", at = now })
	T.eq(#K.Crafters.Cards(), 2, "предел каталога")
	T.no(K.Crafters.Get(old), "вытеснена самая старая")
	K.Config.CRAFT_MAX = 500
	local dying = Feed(c.K, { name = "Дина Добрая", at = now - K.Config.CRAFT_KEEP + 30 })
	T.ok(K.Crafters.Get(dying))
	w:Run(130)
	T.no(K.Crafters.Get(dying), "срок вышел")
	T.eq(Logged(c.K, "мастера: карточка Дина Добрая <Чиллзон Север> пропала из каталога"), 1)
	T.eq(#K.Crafters.Cards(), 2)
	NoErrors(c.K, "Карл")
end)

---------------------------------------------------------------------------
-- Списки рецептов
---------------------------------------------------------------------------
T.test("crafters: список рецептов приходит шёпотом, совпавший не загружается заново", function()
	local w, c = Build()
	Master(c.A)
	local key, V = Key(c.A), c.V.ns
	local wl = Whispers(c.A, "WL")
	T.ok(V.Crafters.Want(key, 164))
	T.ok(V.Crafters.AskState(key, 164).loading)
	T.eq(V.Views.CraftListState(key, 164), V.L.CRAFT_ASKING)
	w:Run(20)
	T.same(V.Crafters.Recipes(key, 164), { 2660, 2661, 2662 })
	T.no(V.Crafters.AskState(key, 164), "запрос закрыт")
	T.eq(#wl, 1, "одна страница")
	T.ok(wl[1].target:find("^Вера Верная"), "ответ — спросившему")
	T.eq(Logged(c.V, "мастера: список рецептов Арагорн Светлый (Кузнечное дело) получен"), 1)
	T.eq(V.Crafters.Presence(V.Crafters.Get(key)), "online", "ответил — значит в игре")
	local ok, why = V.Crafters.Want(key, 164)
	T.no(ok)
	T.eq(why, "fresh")
	ok, why = V.Crafters.Want(key, 164, true)
	T.no(ok)
	T.eq(why, "retry")
	-- «Обновить рецепты» через минуту: список тот же — короткий ответ без страниц.
	w:Run(V.Config.CRAFT_ASK_RETRY)
	T.ok(V.Crafters.Want(key, 164, true))
	w:Run(20)
	T.eq(#wl, 2)
	T.ok(wl[2].payload:find("~0~0~$"), "хеш совпал")
	T.no(V.Crafters.AskState(key, 164))
	T.same(V.Crafters.Recipes(key, 164), { 2660, 2661, 2662 })
	-- Мастер выучил рецепт: список у смотрящего устарел и загружается заново.
	Learn(c.A, Smith(150, { [2660] = true, [2661] = true, [2662] = true, [3115] = true }))
	T.ok(c.A.ns.Crafters.Post())
	w:Run(45)
	T.ok(V.Views.CraftListState(key, 164):find(V.L.CRAFT_LIST_OLD, 1, true), "список устарел")
	T.ok(V.Crafters.Want(key, 164))
	w:Run(20)
	T.same(V.Crafters.Recipes(key, 164), { 2660, 2661, 2662, 3115 })
	T.eq(#wl, 3)
	for _, cl in pairs(c) do NoErrors(cl, cl:Name()) end
end)

T.test("crafters: длинный список приходит страницами, испорченный не сохраняется", function()
	local w, c = Build()
	local recipes = {}
	for i = 1, 500 do recipes[10000 + i * 1000] = true end
	Learn(c.A, Smith(300, recipes))
	c.A.ns.Crafters.SetPost(164, true)
	T.ok(c.A.ns.Crafters.Post())
	w:Run(30)
	local key, V = Key(c.A), c.V.ns
	local wl = Whispers(c.A, "WL")
	T.ok(V.Crafters.Want(key, 164))
	w:Run(60)
	T.ok(#wl > 1, "страниц несколько: " .. #wl)
	T.eq(#(V.Crafters.Recipes(key, 164) or {}), 500)
	local _, n = V.Views.CraftRecipes(key, 164, "")
	T.eq(n, 500)
	-- В карточке строк столько, сколько видно; прокрутка меняет их содержимое.
	V.UI.Toggle("crafters")
	V.CraftersPane.Open(key)
	local f = V.CraftersPane.frames
	T.ok(#f.recipes <= 10, "строк в карточке: " .. #f.recipes)
	local shown = 0
	for _, r in ipairs(f.recipes) do
		if r:IsShown() then shown = shown + 1 end
	end
	T.eq(shown, 8, "видно 166 / 22 строк")
	T.eq(f.recipes[1].it.id, 11000)
	f.card.scroll:SetVerticalScroll(22 * 100)
	T.eq(f.recipes[1].it.id, 10000 + 101 * 1000, "после прокрутки — сто первый")
	T.ok(f.recipes[1].name:GetText():find(V.L.CRAFT_RECIPE_UNKNOWN:format(111000), 1, true))
	V.UI.Toggle("chat")
	-- Борису страницы приходят с ошибкой: список не сохраняется, он видит почему.
	local send = c.A.ns.Comm.Send
	c.A.ns.Comm.Send = function(dist, payload, opts)
		if dist == "WHISPER" and payload:sub(1, 3) == "WL~" then
			payload = payload:sub(1, -2) .. (payload:sub(-1) == "1" and "2" or "1")
		end
		return send(dist, payload, opts)
	end
	T.ok(c.B.ns.Crafters.Want(key, 164))
	w:Run(60)
	T.no(c.B.ns.Crafters.Recipes(key, 164))
	local st = c.B.ns.Crafters.AskState(key, 164)
	T.ok(st and st.failed and st.why == "broken", "ошибка списка")
	T.ok(c.B.ns.Views.CraftListState(key, 164):find(c.B.ns.L.CRAFT_BROKEN, 1, true))
	NoErrors(c.B, "Борис")
end)

T.test("crafters: страницу принимают только от того, кого спросили", function()
	local w, c = Build()
	Master(c.A)
	local key, V = Key(c.A), c.V.ns
	c.B.ns.Comm.Send("WHISPER", "WL~164~0001~1~1~1", { target = "Вера Верная" })
	w:Run(5)
	T.no(V.Crafters.Recipes(Key(c.B), 164))
	-- Пока Вера ждёт ответа Арагорна, страница Бориса тоже не в счёт.
	c.A.lockdown = true
	T.ok(V.Crafters.Want(key, 164))
	c.B.ns.Comm.Send("WHISPER", "WL~164~0001~1~1~1", { target = "Вера Верная" })
	w:Run(5)
	T.no(V.Crafters.Recipes(key, 164))
	T.ok(V.Crafters.AskState(key, 164).loading)
	NoErrors(c.V, "Вера")
end)

T.test("crafters: мастер молчит в блокировке, ушедший мастер — «нет в игре»", function()
	local w, c = Build()
	Master(c.A)
	local key, V = Key(c.A), c.V.ns
	c.A.lockdown = true
	T.ok(V.Crafters.Want(key, 164))
	w:Run(30)
	local st = V.Crafters.AskState(key, 164)
	T.ok(st and st.failed and st.why == "silent", "не ответил")
	T.ok(V.Views.CraftListState(key, 164):find(V.L.CRAFT_SILENT, 1, true))
	T.no(V.Crafters.Recipes(key, 164))
	c.A.lockdown = false
	w:Run(60)
	T.ok(V.Crafters.Want(key, 164))
	w:Run(20)
	T.same(V.Crafters.Recipes(key, 164), { 2660, 2661, 2662 }, "после блокировки ответил")
	-- Смотрящий в блокировке не спрашивает.
	c.B.lockdown = true
	local ok, why = c.B.ns.Crafters.Want(key, 164)
	T.no(ok)
	T.eq(why, "lockdown")
	c.B.lockdown = false
	-- Мастер вышел из игры.
	c.A:Logout()
	c.B.ns.Crafters.Want(key, 164)
	w:Run(30)
	st = c.B.ns.Crafters.AskState(key, 164)
	T.ok(st and st.failed and st.why == "offline", "нет в игре: " .. tostring(st and st.why))
	T.ok(c.B.ns.Views.CraftListState(key, 164):find(c.B.ns.L.CRAFT_OFFLINE, 1, true))
	NoErrors(c.B, "Борис")
	NoErrors(c.V, "Вера")
end)

T.test("crafters: мастер отвечает только объединению и в пределах лимитов", function()
	local w, c = Build()
	w:Guild("Чужаки")
	local x = w:Client({ first = "Ян", surname = "Чужой", guild = "Чужаки", rank = 0 })
	Master(c.A)
	local key = Key(c.A)
	local wl = Whispers(c.A, "WL")
	x.ns.Comm.Send("WHISPER", x.ns.Codec.EncodeCraftQuery(164, "abcdefgh12345678"), { target = "Арагорн Светлый" })
	w:Run(30)
	T.eq(#wl, 0, "чужаку список не уходит")
	-- Неотмеченная профессия не отдаётся.
	local fp = c.V.ns.Security.MyCertificate().fp
	c.V.ns.Comm.Send("WHISPER", c.V.ns.Codec.EncodeCraftQuery(165, fp), { target = "Арагорн Светлый" })
	w:Run(10)
	T.eq(#wl, 0, "профессии нет в карточке")
	-- Лимит в минуту: второй смотрящий ждёт.
	c.A.ns.Config.CRAFT_SERVE_PER_MIN = 1
	T.ok(c.V.ns.Crafters.Want(key, 164))
	T.ok(c.B.ns.Crafters.Want(key, 164))
	w:Run(30)
	T.eq(#wl, 1, "в минуту — один список")
	local got = (c.V.ns.Crafters.Recipes(key, 164) and 1 or 0) + (c.B.ns.Crafters.Recipes(key, 164) and 1 or 0)
	T.eq(got, 1, "список у одного")
	NoErrors(c.A, "Арагорн")
end)

---------------------------------------------------------------------------
-- Прежние версии
---------------------------------------------------------------------------
-- Гибрид tests/wow.lua: Security, Relay и Census версии 0.9, Chat и Comm новые, Crafters.lua нет.
T.test("crafters: реле и репортёр прежней версии пересылают карточку и молчат о ней", function()
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
	T.ok(c.V.ns.Census.IsReporter(), "репортёр Севера — глава на 0.9")
	T.no(c.V.ns.Crafters, "у прежней версии мастеров нет")
	Master(c.G)
	w:Run(30)
	local e = c.B.ns.Crafters.Get(Key(c.G))
	T.ok(e, "карточка дошла через 0.9")
	T.eq(Logged(c.B, "мастера: карточка Глеб Гордый <Орден Чиллзона> принята (реле)"), 1)
	T.ok(c.B.ns.Crafters.Want(Key(c.G), 164))
	w:Run(20)
	T.same(c.B.ns.Crafters.Recipes(Key(c.G), 164), { 2660, 2661, 2662 }, "список напрямую")
	T.ok(c.G.ns.Crafters.Withdraw())
	w:Run(60)
	T.no(c.B.ns.Crafters.Get(Key(c.G)), "снятие дошло")
	for _, cl in pairs(c) do
		NoErrors(cl, cl:Name())
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
		NoTrace(cl, cl:Name())
	end
end)

---------------------------------------------------------------------------
-- Вкладка
---------------------------------------------------------------------------
-- Строки подсказки при наведении на owner.
local function Tip(c, owner)
	local lines = {}
	c.stubs.GameTooltip = true
	c.env.GameTooltip = {
		SetOwner = function() end, Show = function() end, Hide = function() end,
		AddLine = function(_, text) lines[#lines + 1] = text end,
		SetItemByID = function(_, id) lines[#lines + 1] = "item " .. id end,
		SetSpellByID = function(_, id) lines[#lines + 1] = "spell " .. id end,
	}
	owner:GetScript("OnEnter")(owner)
	return table.concat(lines, "\n")
end

-- Видимые строки списка рецептов в карточке, сверху вниз.
local function RecipeRows(viewer)
	local out = {}
	for _, r in ipairs(viewer.ns.CraftersPane.frames.recipes) do
		if r:IsShown() then out[#out + 1] = r end
	end
	return out
end

-- Названия видимых рецептов в карточке, по строке на рецепт.
local function CardText(viewer)
	local names = {}
	for i, r in ipairs(RecipeRows(viewer)) do names[i] = r.name:GetText() end
	return table.concat(names, "\n")
end

-- Строка каталога с мастером author.
local function PaneRow(viewer, author)
	for _, r in ipairs(viewer.ns.CraftersPane.frames.rows) do
		if r:IsShown() and r.it and r.it.key == Key(author) then return r end
	end
end

T.test("crafters pane: профессии в строке и в карточке названы словами", function()
	local w, c = Build()
	Learn(c.A, Smith())
	c.A:CloseProfession()
	Learn(c.A, { id = 165, skill = 80, max = 150, recipes = { [2149] = true } })
	c.A.ns.Crafters.SetPost(164, true)
	c.A.ns.Crafters.SetPost(165, true)
	T.ok(c.A.ns.Crafters.Post("кую и шью"))
	w:Run(30)
	local V = c.V.ns.Views
	T.eq(V.CraftCount(1), "1 рецепт")
	T.eq(V.CraftCount(3), "3 рецепта")
	T.eq(V.CraftCount(11), "11 рецептов")
	T.eq(V.CraftSkill({ skill = 1, max = 75 }), "1/75")
	T.eq(V.CraftSkill({ skill = 5, max = 0 }), "5", "без предела")
	c.V:Slash("/chillzone", "crafters")
	local f = c.V.ns.CraftersPane.frames
	local sub = PaneRow(c.V, c.A).sub:GetText()
	T.ok(sub:find("Кузнечное дело 150/225", 1, true), "первая профессия")
	T.ok(sub:find("Кожевничество 80/150", 1, true), "вторая профессия")
	T.no(sub:find("рецепт", 1, true), "с двумя профессиями число рецептов только в подсказке")
	f.filters[165]:Click()
	sub = PaneRow(c.V, c.A).sub:GetText()
	T.ok(sub:find("Кожевничество 80/150|r|cff999999, 1 рецепт", 1, true), "фильтр — одна профессия с числом рецептов")
	T.no(sub:find("Кузнечное", 1, true))
	-- В карточке две профессии с названиями не помещаются: остаётся навык.
	PaneRow(c.V, c.A):Click()
	w:Run(1)
	T.ok(f.card:IsShown())
	T.ok(f.cardChips[1].label:GetText():find("150/225", 1, true))
	T.no(f.cardChips[1].label:GetText():find("Кузнечное", 1, true), "узко — без названия")
	T.ok(f.cardChips[2].label:GetText():find("80/150", 1, true))
	-- Одна профессия помещается с названием.
	c.A.ns.Crafters.SetPost(165, false)
	T.ok(c.A.ns.Crafters.Post("кую"))
	w:Run(30)
	c.V.ns.CraftersPane.Render()
	T.ok(f.cardChips[1].label:GetText():find("Кузнечное дело 150/225", 1, true), "одна — с названием")
	T.no(f.cardChips[2]:IsShown())
	NoErrors(c.V, "Вера")
end)

T.test("crafters pane: каталог, поиск по рецептам и карточка мастера", function()
	local w, c = Build()
	Master(c.A)
	local L = c.V.ns.L
	c.V:Slash("/chillzone", "crafters")
	local f = c.V.ns.CraftersPane.frames
	T.ok(f.pane:IsShown(), "вкладка открыта")
	T.eq(c.V.ns.UI.Current(), "crafters")
	T.eq(c.V.ns.UI.heading:GetText(), "Мастера профессий", "название вкладки в шапке окна")
	local row = PaneRow(c.V, c.A)
	T.ok(row, "строка мастера")
	T.ok(row.name:GetText():find("Арагорн Светлый", 1, true))
	T.ok(row.name:GetText():find("Чиллзон", 1, true), "гильдия")
	T.ok(row.sub:GetText():find("Кузнечное дело 150/225|r|cff999999, 3 рецепта", 1, true), "профессия, навык и рецепты словами")
	T.ok(row.sub:GetText():find("кую на заказ", 1, true), "примечание")
	T.ok(row.button:IsShown(), "мастер был недавно — можно шепнуть")
	T.ok(row.name:GetText():find("StatusIcon-Away", 1, true), "был недавно — жёлтый значок")
	local tip = Tip(c.V, row)
	T.ok(tip:find(L.CRAFT_TIP_RECENT, 1, true), "подсказка: был недавно")
	T.ok(tip:find(L.CRAFT_TIP_PROF:format("Кузнечное дело", 150, 225, 3), 1, true), "подсказка: профессия")
	T.ok(tip:find("кую на заказ", 1, true), "подсказка: примечание")
	T.ok(Tip(c.V, c.V.ns.UI.tabs.crafters):find(L.TAB_CRAFTERS_COUNT:format(1), 1, true), "число мастеров в подсказке вкладки")
	T.ok(f.filters[164] and f.filters[164]:IsShown(), "фильтр по профессии")
	T.ok(f.mine:IsShown(), "справа — своё ремесло")
	T.eq(f.mine.hint:GetText(), L.CRAFT_MINE_EMPTY)
	-- Фильтр: другой профессии нет — пусто.
	f.filters[164]:Click()
	T.ok(PaneRow(c.V, c.A), "фильтр по своей профессии")
	f.all:Click()
	-- Щелчок по строке: карточка мастера и запрос рецептов.
	row:Click()
	T.ok(f.card:IsShown(), "карточка мастера")
	T.no(f.mine:IsShown())
	T.ok(f.card.name:GetText():find("Арагорн Светлый", 1, true))
	T.eq(f.card.state:GetText(), L.CRAFT_ASKING)
	w:Run(20)
	T.ok(CardText(c.V):find("Грубое точило", 1, true), "рецепты показаны")
	T.ok(f.card.state:GetText():find(L.CRAFT_LIST_AT:format(""), 1, true), "когда получен список")
	T.ok(PaneRow(c.V, c.A).name:GetText():find("StatusIcon-Online", 1, true), "ответил — в игре")
	-- Поиск по названию рецепта находит мастера и поднимает рецепты наверх.
	c.V.ns.CraftersPane.Search("медн")
	w:Run(1)
	row = PaneRow(c.V, c.A)
	T.ok(row and row.sub:GetText():find("Медная кольчуга, Медные поножи", 1, true), "подходящие рецепты в строке")
	T.ok(CardText(c.V):find("^|cffffd100Медная кольчуга"), "подходящие — первыми")
	T.eq(f.loaded:GetText(), L.CRAFT_LOADED:format(1, 1))
	c.V.ns.CraftersPane.Search("зелье")
	T.no(PaneRow(c.V, c.A), "никого")
	T.ok(f.empty:IsShown())
	T.eq(f.empty:GetText(), L.CRAFT_EMPTY_FILTER:format(1))
	c.V.ns.CraftersPane.Search("")
	-- «Назад» — своё ремесло, «Шепнуть» — поле чата игры.
	f.card.back:Click()
	T.ok(f.mine:IsShown())
	T.no(f.card:IsShown())
	PaneRow(c.V, c.A).button:Click()
	T.same(c.V.tells, { "Арагорн Светлый" }, "шёпот мастеру в чате игры")
	T.eq(c.V.ns.UI.Current(), "crafters", "окно остаётся на вкладке")
	NoErrors(c.V, "Вера")
	T.eq(#c.V:Leaks(), 0)
end)

T.test("crafters pane: значок «в игре» по спискам гильдий и ростеру", function()
	local w, c = Build()
	Master(c.A)
	local V, L = c.V.ns, c.V.ns.L
	local key = Key(c.A)
	-- Списка гильдии мастера нет: известна только давность карточки.
	T.eq(V.Crafters.Presence(V.Crafters.Get(key)), "recent", "карточка свежая")
	T.eq(V.Crafters.Presence(V.Crafters.Get(key), false), "recent", "в списке нет, но подписал после него")
	w:Run(V.Config.FRESH + 60)
	T.eq(V.Crafters.Presence(V.Crafters.Get(key)), "away", "списка нет — неизвестно")
	T.eq(V.Crafters.Presence(V.Crafters.Get(key), false), "offline", "в списке нет — не в игре")
	-- Вкладка на экране спрашивает список гильдии мастера; по нему мастер в игре.
	local oq = Whispers(c.V, "OQ")
	c.V:Slash("/chillzone", "crafters")
	local row = PaneRow(c.V, c.A)
	T.ok(row.name:GetText():find("StatusIcon-Offline", 1, true), "до списка — серый значок")
	T.ok(Tip(c.V, row):find(L.CRAFT_TIP_AWAY, 1, true), "подсказка: неизвестно")
	T.no(row.button:IsShown(), "кнопки шёпота нет, есть давность")
	T.eq(#oq, 1, "запрос списка гильдии мастера")
	w:Run(20)
	row = PaneRow(c.V, c.A)
	T.ok(row.name:GetText():find("StatusIcon-Online", 1, true), "мастер в списке — зелёный значок")
	T.ok(Tip(c.V, row):find(L.CRAFT_TIP_ONLINE, 1, true))
	T.ok(row.button:IsShown(), "в игре — можно шепнуть")
	row:Click()
	T.ok(c.V.ns.CraftersPane.frames.card.name:GetText():find("StatusIcon-Online", 1, true), "значок и в карточке")
	-- Другая вкладка — списки не спрашиваются.
	c.V.ns.UI.Toggle("groups")
	T.no(c.V.ns.CraftersPane.frames.pane:IsShown())
	local asked = #oq
	w:Run(c.V.ns.Config.ONLINE_KEEP + 60)
	T.eq(#oq, asked, "без вкладки запросов нет")
	-- Согильдиец — по ростеру: вышел из игры — серый значок.
	c.K:Slash("/chillzone", "crafters")
	T.ok(PaneRow(c.K, c.A).name:GetText():find("StatusIcon-Online", 1, true), "согильдиец в игре")
	c.A:Logout()
	w:AddOffline("Чиллзон", "Арагорн Светлый-" .. c.A.realm, 1, 24, "WARRIOR", 0) -- остался в гильдии
	w:Run(c.K.ns.Config.FRESH + 60)
	c.K.ns.Roster.RequestScan(true)
	w:Run(5)
	T.eq(c.K.ns.Crafters.Presence(c.K.ns.Crafters.Get(key)), "offline", "ростер: не в игре")
	c.K.ns.CraftersPane.Render()
	T.ok(PaneRow(c.K, c.A).name:GetText():find("StatusIcon-Offline", 1, true), "согильдиец вышел — серый значок")
	T.ok(Tip(c.K, PaneRow(c.K, c.A)):find(c.K.ns.L.CRAFT_TIP_OFFLINE, 1, true))
	NoErrors(c.V, "Вера")
	NoErrors(c.K, "Карл")
end)

T.test("crafters pane: правый щелчок по мастеру — меню с шёпотом", function()
	local w, c = Build()
	Master(c.A)
	Master(c.K, "кую и я")
	local L = c.V.ns.L
	c.A:Slash("/chillzone", "crafters")
	local f = c.A.ns.CraftersPane.frames
	local menu = c.A.ns.ChatPane.PersonMenu()
	local function Right(r) r:GetScript("OnClick")(r, "RightButton") end
	-- Левый щелчок — карточка, меню не открывается.
	local karl = PaneRow(c.A, c.K)
	karl:GetScript("OnClick")(karl, "LeftButton")
	T.ok(f.card:IsShown(), "левый — карточка")
	T.no(menu:IsShown(), "левый — без меню")
	-- Правый — меню; согильдиец в игре, его можно и пригласить.
	karl = PaneRow(c.A, c.K)
	Right(karl)
	T.ok(menu:IsShown(), "меню открыто")
	T.ok(menu.title:GetText():find("Карл Великий", 1, true), "в заголовке мастер")
	T.eq(menu.invite.enabled, true, "в игре — приглашение доступно")
	menu.whisper:GetScript("OnClick")(menu.whisper)
	T.no(menu:IsShown(), "меню закрылось")
	T.same(c.A.tells, { "Карл Великий" }, "шёпот мастеру в поле чата игры")
	T.eq(c.A.ns.UI.Current(), "crafters", "окно остаётся на вкладке")
	-- Своя строка меню не открывает, в её подсказке нет правого щелчка.
	c.A:Slash("/chillzone", "crafters")
	local own = PaneRow(c.A, c.A)
	Right(own)
	T.no(menu:IsShown(), "себе меню не нужно")
	T.no(Tip(c.A, own):find(L.TIP_MENU, 1, true))
	T.ok(Tip(c.A, PaneRow(c.A, c.K)):find(L.TIP_MENU, 1, true), "у чужого — подсказка про правый щелчок")
	-- Мастер другой гильдии без отметки «в игре» (списка его гильдии нет): шёпот есть,
	-- приглашения нет.
	c.A.ns.Online.Want = function() end
	Master(c.V, "шью")
	w:Run(c.A.ns.Config.FRESH + 60)
	c.A.ns.CraftersPane.Render()
	local vera = PaneRow(c.A, c.V)
	T.ok(vera, "Вера в каталоге")
	T.no(vera.button:IsShown(), "кнопки «Шепнуть» в строке нет")
	Right(vera)
	T.ok(menu:IsShown(), "меню есть и без отметки «в игре»")
	T.eq(menu.invite.enabled, false, "в группу — только тех, кто в игре")
	NoErrors(c.A, "Арагорн")
end)

T.test("crafters pane: поиск в списке рецептов карточки", function()
	local w, c = Build()
	Learn(c.A, Smith(150, { [2660] = true, [2661] = true, [2662] = true, [2663] = true, [3115] = true }))
	c.A.ns.Crafters.SetPost(164, true)
	T.ok(c.A.ns.Crafters.Post("кую"))
	w:Run(30)
	Master(c.K, "и я кую")
	local P, L = c.V.ns.CraftersPane, c.V.ns.L
	c.V.ns.UI.Toggle("crafters")
	local f = P.frames
	PaneRow(c.V, c.A):Click()
	w:Run(20)
	T.ok(f.card:IsShown(), "карточка открыта")
	T.eq(f.card.searchHint:GetText(), L.CRAFT_RECIPE_SEARCH, "поле поиска в карточке")
	T.eq(#RecipeRows(c.V), 5, "без поиска — все")
	T.no(f.card.empty:IsShown())
	-- С первой буквы, без учёта регистра и «ё», по нескольким словам.
	P.SearchRecipes("мед")
	T.eq(CardText(c.V), "Медная кольчуга\nМедные наручи\nМедные поножи")
	P.SearchRecipes("ТЯЖЕЛ")
	T.eq(CardText(c.V), "Тяжёлое точило")
	P.SearchRecipes("точ гр")
	T.eq(CardText(c.V), "Грубое точило", "все слова")
	P.SearchRecipes("щщщ")
	T.eq(#RecipeRows(c.V), 0)
	T.ok(f.card.empty:IsShown(), "ничего не нашлось")
	T.eq(f.card.empty:GetText(), L.CRAFT_RECIPE_NONE)
	-- Общий поиск по-прежнему ставит подходящие первыми и красит их.
	P.SearchRecipes("")
	T.eq(#RecipeRows(c.V), 5)
	P.Search("наручи")
	P.SearchRecipes("мед")
	T.eq(RecipeRows(c.V)[1].it.id, 2663, "подходящий под общий поиск — первым")
	T.eq(#RecipeRows(c.V), 3)
	P.Search("")
	-- Набор в поле: список меняется после паузы.
	f.card.search:SetText("кольч")
	f.card.search:GetScript("OnTextChanged")(f.card.search)
	T.eq(#RecipeRows(c.V), 3, "сразу не перерисовывается")
	w:Run(0.3)
	T.eq(CardText(c.V), "Медная кольчуга")
	-- Состояние в две строки сдвигает поле и список вниз, список короче, но не уходит на кнопки.
	local oneLine = f.card.listH
	f.card.state.GetStringHeight = function() return 26 end
	P.Render()
	T.eq(f.card.listH, oneLine - 12, "список короче на строку состояния")
	T.ok(88 + 26 + 2 + 24 + f.card.listH <= 292, "низ списка выше кнопок")
	f.card.state.GetStringHeight = nil
	P.Render()
	T.eq(f.card.listH, oneLine)
	-- У другого мастера поиск начинается с пустого поля.
	PaneRow(c.V, c.K):Click()
	w:Run(20)
	T.eq(f.card.search:GetText(), "")
	T.eq(#RecipeRows(c.V), 3, "у Карла все три")
	NoErrors(c.V, "Вера")
end)

T.test("crafters pane: фильтр по уровню предмета, как на аукционе", function()
	local w, c = Build()
	Master(c.A) -- точило без уровня, кольчуга 7, поножи 9
	Master(c.K, "и я кую")
	local V, P, L = c.V.ns, c.V.ns.CraftersPane, c.V.ns.L
	T.eq(V.Views.CraftLevels("", ""), nil, "оба поля пустые — фильтра нет")
	T.same(V.Views.CraftLevels("20", ""), { min = 20 })
	T.same(V.Views.CraftLevels("30", "10"), { min = 10, max = 30 }, "границы меняются местами")
	V.UI.Toggle("crafters")
	local f = P.frames
	T.eq(f.levelLo.hint:GetText(), L.CRAFT_LEVEL_FROM)
	T.ok(Tip(c.V, f.levelHi):find(L.CRAFT_LEVEL_TIP, 1, true))
	-- Пока списки не загружены, по уровню мастеров не найти: уровень есть только у рецептов.
	P.Levels(8, 10)
	T.no(PaneRow(c.V, c.A), "список не загружен")
	T.eq(f.loaded:GetText(), L.CRAFT_LOADED:format(0, 2))
	P.Levels()
	PaneRow(c.V, c.A):Click()
	w:Run(20)
	T.eq(#RecipeRows(c.V), 3, "без уровня — все")
	T.no(f.card.state:GetText():find(L.CRAFT_LEVEL_NOTE:format(""), 1, true), "без уровня — без пометки")
	local listH = f.card.listH
	-- Поножи — девятого уровня: в строке и в карточке остаются только они.
	P.Levels(8, 10)
	local row = PaneRow(c.V, c.A)
	T.ok(row and row.sub:GetText():find("Медные поножи", 1, true), "в строке — рецепт этого уровня")
	T.no(row.sub:GetText():find("кольчуга", 1, true))
	T.no(PaneRow(c.V, c.K), "список Карла не загружен")
	T.eq(f.loaded:GetText(), L.CRAFT_LOADED:format(1, 2))
	T.eq(CardText(c.V), "Медные поножи")
	-- В карточке под состоянием списка видно, что действует фильтр уровня.
	local state = f.card.state:GetText()
	T.ok(state:find(L.CRAFT_LIST_AT:format(""), 1, true), "состояние списка на месте")
	T.ok(state:find("\n|cffffd100" .. L.CRAFT_LEVEL_NOTE:format("8—10") .. "|r", 1, true), "пометка: " .. state)
	T.eq(f.card.listH, listH - 14, "список короче на строку пометки")
	P.Levels(9, 9)
	T.ok(f.card.state:GetText():find(L.CRAFT_LEVEL_NOTE:format("9"), 1, true), "один уровень")
	P.Levels(8)
	T.ok(f.card.state:GetText():find(L.CRAFT_LEVEL_NOTE:format("от 8"), 1, true))
	-- Одна граница: «до 7» — и предметы без требования уровня.
	P.Levels(nil, 7)
	T.ok(f.card.state:GetText():find(L.CRAFT_LEVEL_NOTE:format("до 7"), 1, true))
	T.eq(CardText(c.V), "Грубое точило\nМедная кольчуга")
	-- Со словами: мастер не подошёл по имени — нужны рецепты, подходящие и по названию, и по уровню.
	P.Search("медн")
	row = PaneRow(c.V, c.A)
	T.ok(row and row.sub:GetText():find("Медная кольчуга", 1, true))
	T.no(row.sub:GetText():find("поножи", 1, true), "поножи не того уровня")
	-- Мастер подошёл по имени — в строке его рецепты этого уровня.
	P.Search("арагорн")
	row = PaneRow(c.V, c.A)
	T.ok(row and row.sub:GetText():find("Грубое точило, Медная кольчуга", 1, true))
	P.Search("")
	-- Рецептов этого уровня нет: в карточке подсказка.
	P.Levels(50, 60)
	T.no(PaneRow(c.V, c.A))
	T.eq(#RecipeRows(c.V), 0)
	T.ok(f.card.empty:IsShown())
	T.eq(f.card.empty:GetText(), L.CRAFT_RECIPE_NO_LEVEL)
	-- Набор в полях: фильтр после паузы.
	P.Levels()
	T.no(f.card.state:GetText():find(L.CRAFT_LEVEL_NOTE:format(""), 1, true), "фильтр снят — пометки нет")
	T.eq(f.card.listH, listH)
	f.levelLo:SetText("9")
	f.levelLo:GetScript("OnTextChanged")(f.levelLo)
	T.eq(#RecipeRows(c.V), 3, "сразу не перерисовывается")
	w:Run(0.3)
	T.eq(CardText(c.V), "Медные поножи", "от 9")
	T.ok(PaneRow(c.V, c.A))
	NoErrors(c.V, "Вера")
end)

T.test("crafters pane: рецепты персональных предметов скрыты переключателем", function()
	local w, c = Build()
	Learn(c.A, Smith(150, { [2660] = true, [2661] = true, [16988] = true }))
	c.A.ns.Crafters.SetPost(164, true)
	T.ok(c.A.ns.Crafters.Post("кую"))
	w:Run(30)
	local V, P, L = c.V.ns, c.V.ns.CraftersPane, c.V.ns.L
	T.eq(V.Crafters.ShowBound(), false, "по умолчанию скрыты")
	-- Тип привязки игра знает только после догрузки предмета: до неё рецепт не прячется.
	T.eq(V.Crafters.RecipeBound(16988), nil, "предмет ещё не загружен")
	T.eq(V.Crafters.RecipeBound(2661), nil)
	T.eq(V.Crafters.RecipeBound(7418), false, "зачарование предмета не создаёт")
	w:Run(1)
	T.eq(V.Crafters.RecipeBound(16988), true, "шлем — персональный при поднятии")
	T.eq(V.Crafters.RecipeBound(2661), false, "кольчуга — при надевании")
	V.UI.Toggle("crafters")
	local f = P.frames
	local width -- ширину поля симулятор не хранит
	f.card.search.SetWidth = function(_, v) width = v end
	PaneRow(c.V, c.A):Click()
	w:Run(20)
	T.eq(CardText(c.V), "Грубое точило\nМедная кольчуга", "персональный скрыт")
	T.ok(f.card.bound:IsShown(), "переключатель есть")
	T.eq(f.card.bound.label:GetText(), L.CRAFT_BOUND:format(1))
	T.ok(width < 282 - 24, "поле поиска уступает место переключателю")
	local tip = Tip(c.V, f.card.bound)
	T.ok(tip:find(L.CRAFT_BOUND_TIP, 1, true))
	T.ok(tip:find(L.CRAFT_BOUND_SHOW, 1, true))
	-- Скрытый рецепт не находится и общим поиском.
	P.Search("львин")
	T.no(PaneRow(c.V, c.A), "скрытый рецепт не ищется")
	P.Search("")
	-- Показать: рецепт в списке и в поиске, настройка общая для персонажей.
	f.card.bound:Click()
	T.eq(V.Crafters.ShowBound(), true)
	T.eq(V.db.settings.craftBound, true)
	T.eq(CardText(c.V), "Грубое точило\nМедная кольчуга\nШлем львиного сердца")
	T.ok(Tip(c.V, f.card.bound):find(L.CRAFT_BOUND_HIDE, 1, true))
	P.Search("львин")
	local row = PaneRow(c.V, c.A)
	T.ok(row and row.sub:GetText():find("Шлем львиного сердца", 1, true), "находится, когда показан")
	P.Search("")
	f.card.bound:Click()
	T.eq(V.db.settings.craftBound, nil, "снова скрыты")
	T.eq(#RecipeRows(c.V), 2)
	-- Все рецепты списка персональные: вместо пустого списка — подсказка.
	Learn(c.K, Smith(150, { [16988] = true }))
	c.K.ns.Crafters.SetPost(164, true)
	T.ok(c.K.ns.Crafters.Post("шлемы"))
	w:Run(30)
	PaneRow(c.V, c.K):Click()
	w:Run(20)
	T.eq(#RecipeRows(c.V), 0)
	T.ok(f.card.empty:IsShown())
	T.eq(f.card.empty:GetText(), L.CRAFT_RECIPE_ALL_BOUND)
	-- У мастера без персональных переключателя нет, поле поиска во всю ширину.
	Master(c.B)
	c.V.ns.CraftersPane.Render()
	PaneRow(c.V, c.B):Click()
	w:Run(1)
	T.no(f.card.bound:IsShown(), "переключателя нет")
	T.eq(width, 282 - 24)
	NoErrors(c.V, "Вера")
end)

T.test("crafters pane: значок, реагенты и подсказка рецепта", function()
	local w, c = Build()
	Master(c.A)
	local L = c.V.ns.L
	-- Названия реагентов игра догружает: сначала видны значок и число, потом и название.
	local B = c.B.ns
	local info = B.Crafters.RecipeDetails(2662)
	T.eq(info.item, 2854, "предмет рецепта")
	T.eq(info.icon, 134583, "значок рецепта")
	T.same(info.reagents, { { item = 2840, n = 6 }, { item = 2320, n = 2 } }, "необязательный реагент пропущен")
	local lines = B.Views.CraftReagents(info)
	T.eq(#lines, 2)
	T.ok(lines[1]:find("^|T132840:14|t 6 "), "значок и число сразу")
	T.ok(lines[1]:find(L.CRAFT_ITEM_LOADING, 1, true), "название загружается")
	w:Run(1)
	T.same(B.Views.CraftReagents(info), { "|T132840:14|t 6 Медный слиток", "|T132320:14|t 2 Грубая нить" })
	T.eq(c.B.itemLoads, 2, "каждый предмет догружается один раз")
	B.Views.CraftReagents(info)
	T.eq(c.B.itemLoads, 2)
	-- Зачарование: предмета нет, подсказка — заклинание.
	local enchant = B.Crafters.RecipeDetails(7418)
	T.no(enchant.item)
	T.eq(enchant.icon, 136244)
	lines = {}
	B.Views.CraftRecipeTip(7418)({
		AddLine = function(_, text) lines[#lines + 1] = text end,
		SetSpellByID = function(_, id) lines[#lines + 1] = "spell " .. id end,
	})
	T.eq(lines[1], "spell 7418")
	-- Во вкладке: строка — значок и название, реагенты раскрывает щелчок.
	c.V.ns.UI.Toggle("crafters")
	local f = c.V.ns.CraftersPane.frames
	PaneRow(c.V, c.A):Click()
	w:Run(20)
	local rows = RecipeRows(c.V)
	T.same({ rows[1].it.id, rows[2].it.id, rows[3].it.id }, { 2660, 2661, 2662 }, "по названию")
	local row = rows[3]
	T.eq(row.icon:GetTexture(), 134583)
	T.ok(row.name:GetText():find("Медные поножи", 1, true))
	T.ok(row.toggle:IsShown(), "есть что раскрыть")
	T.ok(row.toggle:GetTexture():find("PlusButton", 1, true))
	T.eq(#row.lines, 0, "реагенты свёрнуты")
	local tip = Tip(c.V, row)
	T.ok(tip:find("^item 2854"), "подсказка — предмет игры")
	T.ok(tip:find(L.CRAFT_REAGENTS, 1, true))
	T.ok(tip:find("2 Грубая нить", 1, true))
	T.ok(tip:find(L.CRAFT_TIP_EXPAND, 1, true))
	-- Раскрыть первый: реагенты под ним, остальные рецепты сдвигаются вниз.
	rows[1]:Click()
	rows = RecipeRows(c.V)
	T.ok(rows[1].toggle:GetTexture():find("MinusButton", 1, true))
	T.ok(rows[1].lines[1]:IsShown())
	T.eq(rows[1].lines[1]:GetText(), "|T132835:14|t 1 Грубый камень")
	T.eq(rows[2].top, 22 + 16 + 4, "следующий ниже на реагенты")
	T.ok(Tip(c.V, rows[1]):find(L.CRAFT_TIP_COLLAPSE, 1, true))
	rows[3]:Click()
	T.eq(RecipeRows(c.V)[3].lines[2]:GetText(), "|T132320:14|t 2 Грубая нить", "раскрыты оба")
	-- Повторный щелчок сворачивает.
	rows[1]:Click()
	rows = RecipeRows(c.V)
	T.no(rows[1].lines[1]:IsShown())
	T.eq(rows[2].top, 22)
	-- Раскрытие переживает перерисовку и возврат к мастеру.
	f.card.back:Click()
	PaneRow(c.V, c.A):Click()
	T.ok(RecipeRows(c.V)[3].lines[1]:IsShown(), "Медные поножи раскрыты")
	NoErrors(c.V, "Вера")
	NoErrors(c.B, "Борис")
end)

T.test("crafters pane: своё ремесло — отметка, примечание, размещение и снятие", function()
	local w, c = Build()
	local L = c.A.ns.L
	c.A.ns.UI.Toggle("crafters")
	local f = c.A.ns.CraftersPane.frames
	T.eq(f.mine.hint:GetText(), L.CRAFT_MINE_EMPTY)
	T.ok(f.empty:IsShown())
	T.eq(f.empty:GetText(), L.CRAFT_EMPTY)
	f.mine.post:Click()
	T.eq(f.mine.status:GetText(), L.CRAFT_WHY_NOPROFS)
	Learn(c.A, Smith())
	T.eq(f.mine.hint:GetText(), L.CRAFT_MINE_HINT)
	T.ok(f.profs[1]:IsShown())
	T.no(f.profs[2]:IsShown())
	T.ok(f.profs[1].label:GetText():find("Кузнечное дело", 1, true))
	T.ok(f.profs[1].detail:GetText():find(L.CRAFT_READ:format(150, 225, 3, ""), 1, true))
	T.no(f.profs[1]:GetChecked())
	f.mine.post:Click()
	T.eq(f.mine.status:GetText(), L.CRAFT_WHY_NONE, "без отметки не размещается")
	f.profs[1]:SetChecked(true) -- игра ставит отметку до OnClick
	f.profs[1]:Click()
	T.ok(c.A.ns.Crafters.MyProfs()[1].post)
	f.mine.note:SetText("кую | на заказ")
	f.mine.post:Click()
	T.ok(c.A.ns.Crafters.Posted())
	T.eq(f.mine.note:GetText(), "кую на заказ", "в поле — то, что ушло")
	T.eq(f.mine.post:GetText(), L.CRAFT_UPDATE)
	T.ok(f.mine.status:GetText():find(L.CRAFT_POSTED, 1, true))
	w:Run(30)
	T.eq(c.V.ns.Crafters.Get(Key(c.A)).note, "кую на заказ")
	-- Своя строка в каталоге — первой, «это вы», без кнопки.
	local row = f.rows[1]
	T.ok(row:IsShown() and row.it.own)
	T.ok(row.status:GetText():find(L.CRAFT_YOU, 1, true))
	T.no(row.button:IsShown())
	-- Щелчок по своей строке — своя карточка, как её видят остальные, со своим списком, без запроса.
	local wr = Whispers(c.A, "WR")
	row:Click()
	w:Run(1)
	T.ok(f.card:IsShown(), "щелчок по своей строке — своя карточка")
	T.no(f.mine:IsShown())
	T.ok(f.rows[1].picked:IsShown(), "своя строка выбрана")
	T.ok(f.card.name:GetText():find("Арагорн Светлый", 1, true))
	T.ok(f.card.line:GetText():find(L.CRAFT_YOU, 1, true), "это вы")
	T.eq(f.card.note:GetText(), "кую на заказ")
	T.ok(CardText(c.A):find("Грубое точило", 1, true), "свои рецепты по названиям")
	T.no(CardText(c.A):find(L.CRAFT_RECIPE_UNKNOWN:format(3115), 1, true), "неизученный не показан")
	T.ok(f.card.state:GetText():find(L.CRAFT_LIST_MINE:format(""), 1, true), "свой список")
	T.no(f.card.whisper:IsShown(), "себе не шепчут")
	T.eq(f.card.refresh:GetText(), L.CRAFT_UPDATE, "свой список не спрашивают: кнопка отправляет правки")
	T.no(f.card.refresh.enabled, "правок нет")
	T.ok(f.card.state:GetText():find(L.CRAFT_SHOW_MINE:format(0, 3), 1, true), "витрина пуста")
	f.cardChips[1]:Click()
	T.eq(#wr, 0, "своей карточке запрос WR не нужен")
	f.card.back:Click()
	T.ok(f.mine:IsShown(), "«Назад» — своё ремесло")
	T.no(f.card:IsShown())
	f.mine.withdraw:Click()
	T.no(c.A.ns.Crafters.Posted())
	T.eq(f.mine.status:GetText(), L.CRAFT_WITHDRAWN)
	T.eq(f.mine.post:GetText(), L.CRAFT_POST)
	w:Run(30)
	T.no(c.V.ns.Crafters.Get(Key(c.A)), "снята у остальных")
	NoErrors(c.A, "Арагорн")
end)

T.test("crafters pane: витрина — значки в строке, первой в карточке, звёздочки в своей", function()
	local w, c = Build()
	Learn(c.A, Smith())
	c.A:CloseProfession()
	Learn(c.A, { id = 165, skill = 80, max = 150, recipes = { [2149] = true } })
	local Cr = c.A.ns.Crafters
	Cr.SetPost(164, true)
	Cr.SetPost(165, true)
	T.ok(Cr.SetShow(164, 2662, true))
	T.ok(Cr.SetShow(165, 2149, true))
	T.ok(Cr.Post("кую и шью"))
	w:Run(30)
	local L = c.V.ns.L
	c.V.ns.UI.Toggle("crafters")
	local f = c.V.ns.CraftersPane.frames
	-- Строка каталога: значки витрины по порядку профессий карточки.
	local row = PaneRow(c.V, c.A)
	T.ok(row.shows[1]:IsShown() and row.shows[2]:IsShown(), "два значка")
	T.no(row.shows[3] and row.shows[3]:IsShown())
	T.eq(row.shows[1].icon:GetTexture(), 134583, "значок рецепта")
	local tip = Tip(c.V, row.shows[1])
	T.ok(tip:find("^item 2854"), "подсказка значка — предмет игры")
	T.ok(tip:find(L.CRAFT_SHOW_PINNED, 1, true))
	w:Run(1)
	local rowTip = Tip(c.V, row)
	T.ok(rowTip:find(L.CRAFT_SHOW_LINE:format("Медные поножи, Кожаные ботинки"), 1, true), "витрина в подсказке строки: " .. rowTip)
	-- Фильтр профессии оставляет её витрину.
	f.filters[165]:Click()
	row = PaneRow(c.V, c.A)
	T.ok(row.shows[1]:IsShown())
	T.eq(row.shows[1].prof, 165)
	T.no(row.shows[2]:IsShown(), "витрина другой профессии скрыта")
	f.all:Click()
	-- Поиск находит мастера по витрине, хотя его список ещё не загружен.
	c.V.ns.CraftersPane.Search("понож")
	row = PaneRow(c.V, c.A)
	T.ok(row and row.sub:GetText():find("Медные поножи", 1, true), "найден по витрине без списка")
	c.V.ns.CraftersPane.Search("")
	-- Щелчок по значку — карточка на профессии этого рецепта; до списка видна одна витрина.
	PaneRow(c.V, c.A).shows[2]:Click()
	T.ok(f.card:IsShown())
	T.ok(f.cardChips[2].on:IsShown(), "открыта профессия рецепта")
	local rows = RecipeRows(c.V)
	T.eq(#rows, 1)
	T.eq(rows[1].it.id, 2149)
	-- Список у одного мастера спрашивают не чаще CRAFT_SERVE_GAP: следующая профессия — после паузы.
	w:Run(50)
	f.cardChips[1]:Click()
	rows = RecipeRows(c.V)
	T.eq(#rows, 1, "кузнечное дело: до списка — только витрина")
	T.eq(rows[1].it.id, 2662)
	T.ok(rows[1].pin:IsShown() and rows[1].star:IsShown(), "витрина подсвечена и со звёздочкой")
	w:Run(20)
	rows = RecipeRows(c.V)
	T.same({ rows[1].it.id, rows[2].it.id, rows[3].it.id }, { 2662, 2660, 2661 }, "витрина — первой, дальше по названию")
	T.ok(rows[1].pin:IsShown())
	T.no(rows[2].pin:IsShown())
	T.no(rows[2].star:IsShown(), "в чужой карточке звёздочка — только у витрины")
	T.ok(Tip(c.V, rows[1]):find(L.CRAFT_SHOW_PINNED, 1, true))
	rows[1].star:Click()
	T.same(c.V.ns.Crafters.Get(Key(c.A)).profs[1].show, { 2662 }, "чужую витрину не поменять")
	-- Своя карточка: звёздочка у каждого рецепта, щелчок ставит и снимает.
	c.A.ns.UI.Toggle("crafters")
	local fa = c.A.ns.CraftersPane.frames
	T.ok(Tip(c.A, fa.mine.showcase):find(L.CRAFT_SHOWCASE_TIP:format(2, 3), 1, true), "на кнопке «Витрина» — сколько выставлено")
	T.ok(fa.rows[1].it.own and fa.rows[1].shows[1]:IsShown(), "своя витрина в своей строке")
	T.ok(Tip(c.A, fa.rows[1]):find(L.CRAFT_TIP_OPEN_OWN, 1, true))
	fa.rows[1]:Click()
	w:Run(1)
	rows = RecipeRows(c.A)
	T.same({ rows[1].it.id, rows[2].it.id, rows[3].it.id }, { 2662, 2660, 2661 })
	for _, r in ipairs(rows) do T.ok(r.star:IsShown(), "звёздочка у каждого рецепта") end
	T.ok(fa.card.state:GetText():find(L.CRAFT_SHOW_MINE:format(2, 3), 1, true), "на витрине два из трёх")
	T.no(fa.card.state:GetText():find(L.CRAFT_SHOW_DIRTY, 1, true))
	T.eq(fa.card.refresh:GetText(), L.CRAFT_UPDATE)
	T.no(fa.card.refresh.enabled, "правок нет")
	T.ok(Tip(c.A, rows[1].star):find(L.CRAFT_SHOW_OFF, 1, true))
	T.ok(Tip(c.A, rows[3].star):find(L.CRAFT_SHOW_ON, 1, true))
	rows[3].star:Click()
	T.same(Cr.Own().profs[1].show, { 2662, 2661 })
	rows = RecipeRows(c.A)
	T.same({ rows[1].it.id, rows[2].it.id, rows[3].it.id }, { 2662, 2661, 2660 }, "отмеченный поднялся к витрине")
	T.ok(fa.card.state:GetText():find(L.CRAFT_SHOW_MINE:format(3, 3), 1, true))
	T.ok(fa.card.state:GetText():find(L.CRAFT_SHOW_DIRTY, 1, true), "правка ещё не ушла")
	T.ok(fa.card.refresh.enabled)
	-- Витрина полна: четвёртый не встаёт, объяснение — над списком.
	rows[3].star:Click()
	T.eq(fa.card.state:GetText():match("^[^\n]*"), L.CRAFT_SHOW_FULL:format(3))
	T.same(Cr.Own().profs[1].show, { 2662, 2661 })
	-- «Обновить» в своей карточке отправляет правки сразу.
	fa.card.refresh:Click()
	w:Run(30)
	T.no(Cr.Dirty())
	T.same(c.V.ns.Crafters.Get(Key(c.A)).profs[1].show, { 2662, 2661 }, "правка дошла")
	T.no(fa.card.refresh.enabled)
	-- Снять звёздочку.
	RecipeRows(c.A)[1].star:Click()
	T.same(Cr.Own().profs[1].show, { 2661 })
	NoErrors(c.V, "Вера")
	NoErrors(c.A, "Арагорн")
end)

T.test("crafters pane: витрина до размещения — черновик своей карточки", function()
	local w, c = Build()
	local L = c.A.ns.L
	local Cr = c.A.ns.Crafters
	c.A.ns.UI.Toggle("crafters")
	local f = c.A.ns.CraftersPane.frames
	-- Без профессий и без отметки черновика нет: объяснение, как у «Разместить».
	f.mine.showcase:Click()
	T.ok(f.mine:IsShown())
	T.eq(f.mine.status:GetText(), L.CRAFT_WHY_NOPROFS)
	Learn(c.A, Smith())
	f.mine.showcase:Click()
	T.eq(f.mine.status:GetText(), L.CRAFT_WHY_NONE)
	T.no(f.card:IsShown())
	-- Отметить профессию и написать примечание: «Витрина» открывает черновик.
	Cr.SetPost(164, true)
	f.mine.note:SetText("кую на заказ")
	local wires = Capture(c.A)
	f.mine.showcase:Click()
	w:Run(1)
	T.ok(f.card:IsShown(), "черновик своей карточки")
	T.no(Cr.Posted())
	T.ok(f.card.line:GetText():find(L.CRAFT_DRAFT, 1, true), "видно, что не размещена")
	T.no(f.card.line:GetText():find(L.CRAFT_YOU, 1, true))
	T.no(PaneRow(c.A, c.A), "в каталоге черновика нет")
	T.ok(CardText(c.A):find("Грубое точило", 1, true), "свои рецепты")
	local rows = RecipeRows(c.A)
	for _, r in ipairs(rows) do T.ok(r.star:IsShown(), "звёздочки у рецептов") end
	T.eq(f.card.refresh:GetText(), L.CRAFT_POST, "кнопка размещает")
	T.ok(f.card.refresh.enabled)
	T.ok(Tip(c.A, f.card.refresh):find(L.CRAFT_POST_TIP, 1, true))
	rows[3].star:Click()
	T.same(Cr.Own(true).profs[1].show, { 2662 })
	T.ok(f.card.state:GetText():find(L.CRAFT_SHOW_MINE:format(1, 3), 1, true))
	T.no(f.card.state:GetText():find(L.CRAFT_SHOW_DIRTY, 1, true), "у черновика правок нет")
	T.eq(#wires, 0, "до размещения в сеть ничего не ушло")
	-- «Разместить» в карточке: витрина и примечание из поля уходят сразу.
	f.card.refresh:Click()
	T.ok(Cr.Posted())
	w:Run(30)
	T.eq(#wires, 1, "одна карточка")
	local seen = c.V.ns.Crafters.Get(Key(c.A))
	T.same(seen.profs[1].show, { 2662 }, "витрина дошла")
	T.eq(seen.note, "кую на заказ", "примечание из поля")
	T.ok(f.card:IsShown(), "карточка остаётся на экране")
	T.ok(f.card.line:GetText():find(L.CRAFT_YOU, 1, true), "теперь размещена")
	T.eq(f.card.refresh:GetText(), L.CRAFT_UPDATE)
	T.no(f.card.refresh.enabled, "правок нет")
	T.ok(PaneRow(c.A, c.A).picked:IsShown(), "своя строка появилась и выбрана")
	f.card.back:Click()
	T.ok(f.mine:IsShown())
	T.eq(f.mine.note:GetText(), "кую на заказ")
	NoErrors(c.A, "Арагорн")
end)
