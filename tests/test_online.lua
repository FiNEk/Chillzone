-- Поимённый онлайн других гильдий: формат, запрос шёпотом, права и запасные адресаты.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:AddOffline("Чиллзон Север", "Тихий Друид-CAMWOWUS2Realm7PvE", 3, 41, "DRUID", 2)
	w:AddOnline("Чиллзон Север", "Живой Безаддонный-CAMWOWUS2Realm7PvE", 3, 37, "MAGE")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID" })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1, class = "WARRIOR" })
	w:Run(30)
	w:Init(c.A, c.V)
	w:Pair(c.V, c.K)
	w:Run(400)
	return w, c
end

-- Сообщения вида kind в журнале мира начиная с индекса from (и целые, и куски не различает).
local function Sent(w, kind, from)
	local out = {}
	for i = from or 1, #w.log do
		local e = w.log[i]
		if e.msg:sub(1, 2) == kind or e.msg:find(":" .. kind .. "~", 1, true) then out[#out + 1] = e end
	end
	return out
end

local function Names(state)
	local out = {}
	for _, p in ipairs(state.people) do out[p.name] = p end
	return out
end

local function Reporter(c, guild)
	return c.ns.Data.Row(guild).origin
end

-- Клиент с заданным именем из таблицы клиентов.
local function ByName(c, name)
	for _, cl in pairs(c) do
		if cl:Name() == name then return cl end
	end
end

local function Other(c, guild, name)
	for _, cl in pairs(c) do
		if cl.guild == guild and cl:Name() ~= name then return cl end
	end
end

---------------------------------------------------------------------------
-- Формат
---------------------------------------------------------------------------
T.test("online: страницы кодируются и читаются без потерь", function()
	local _, c = Build()
	local Codec = c.A.ns.Codec
	local people = {}
	for i = 1, 150 do
		people[i] = { name = ("Персонаж%03d Длинноимённый"):format(i), class = "PRIEST", level = 60 }
	end
	local pages = Codec.EncodeOnlinePages("Чиллзон", "abcdefghijklmnop", c.A.ns.ServerTime(), people)
	T.ok(#pages > 1, "больше одной страницы")
	local got = {}
	for i, wire in ipairs(pages) do
		T.ok(#wire <= Codec.ONLINE_PAGE, "страница не длиннее четырёх кусков")
		local page = assert(Codec.DecodeOnlinePage(wire), "страница " .. i)
		T.eq(page.guild, "Чиллзон", "гильдия")
		T.eq(page.i, i, "номер")
		T.eq(page.n, #pages, "всего страниц")
		for _, p in ipairs(page.people) do got[#got + 1] = p end
	end
	T.eq(#got, 150, "все люди")
	T.eq(got[150].name, "Персонаж150 Длинноимённый", "порядок")
	T.eq(got[1].class, "PRIEST", "класс")
	T.eq(got[1].level, 60, "уровень")
end)

T.test("online: в страницу не проходят служебные символы и неверные поля", function()
	local _, c = Build()
	local Codec = c.A.ns.Codec
	local wire = Codec.EncodeOnlinePages("Гильдия", "abcdefghijklmnop", 100, { { name = "Имя~:,=|Фамилия", class = "MAGE", level = 10 } })[1]
	T.eq(assert(Codec.DecodeOnlinePage(wire)).people[1].name, "ИмяФамилия", "имя очищено")
	T.eq(Codec.DecodeOnlinePage("OL~Г~fp~2s~3~2~Имя:MA:10"), nil, "номер больше числа страниц")
	T.eq(Codec.DecodeOnlinePage("OL~Г~fp~2s~0~2~Имя:MA:10"), nil, "нулевой номер")
	T.eq(Codec.DecodeOnlinePage("OL~Г~fp~2s~1~65~Имя:MA:10"), nil, "слишком много страниц")
	T.eq(Codec.DecodeOnlinePage("OL~Г~fp~2s~1~1~Имя"), nil, "запись без полей")
	T.eq(Codec.DecodeOnlinePage("OL~Г~fp~2s~1~1~" .. ("я"):rep(30) .. ":MA:10"), nil, "слишком длинное имя")
	T.eq(Codec.DecodeOnlineQuery("OQ~Гильдия"), nil, "запрос без отпечатка")
	T.eq(select(2, Codec.DecodeOnlineQuery("OQ~Гильдия~abc")), "abc", "отпечаток запроса")
end)

---------------------------------------------------------------------------
-- Запрос и ответ
---------------------------------------------------------------------------
T.test("online: зритель получает всех в игре другой гильдии, без зон и реле", function()
	local w, c = Build()
	local from = #w.log + 1
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(20)
	local state = c.K.ns.Online.Get("Чиллзон Север")
	T.ok(state.at, "список получен")
	local names = Names(state)
	T.ok(names["Вера Верная"], "глава")
	T.ok(names["Борис Быстрый"], "офицер")
	local plain = names["Живой Безаддонный"]
	T.ok(plain, "игрок без аддона тоже в списке")
	T.eq(plain.class, "MAGE", "класс")
	T.eq(plain.level, 37, "уровень")
	T.eq(names["Тихий Друид"], nil, "кто не в игре, того в списке нет")
	local queries, pages = Sent(w, "OQ", from), Sent(w, "OL", from)
	T.eq(#queries, 1, "один запрос")
	T.eq(queries[1].dist, "WHISPER", "запрос шёпотом")
	T.eq(queries[1].target, Reporter(c.K, "Чиллзон Север"), "первым спрашивают репортёра")
	T.ok(#pages > 0, "ответ есть")
	for _, e in ipairs(pages) do
		T.eq(e.dist, "WHISPER", "ответ шёпотом")
		T.eq(e.target, "Карл Великий", "только спросившему")
		T.ok(not e.msg:find("RM~", 1, true) and not e.msg:find("RL~", 1, true), "не через реле")
	end
end)

T.test("online: свежий список не запрашивается повторно, устаревший — да", function()
	local w, c = Build()
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(20)
	local from = #w.log + 1
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(5)
	T.eq(#Sent(w, "OQ", from), 0, "свежий список не спрашиваем")
	w:Run(c.K.ns.Config.ONLINE_REFRESH)
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(5)
	T.eq(#Sent(w, "OQ", from), 1, "устаревший — спрашиваем заново")
end)

T.test("online: свою гильдию не спрашивают, она видна по ростеру", function()
	local w, c = Build()
	local from = #w.log + 1
	c.K.ns.Online.Want("Чиллзон")
	w:Run(5)
	T.eq(#Sent(w, "OQ", from), 0, "запроса нет")
	local mine
	for _, s in ipairs(c.K.ns.Data.Summary()) do
		if s.mine then mine = s end
	end
	local group = c.K.ns.Views.OnlineGroup(mine, "В игре")
	T.eq(#group.people, 2, "двое в игре из ростера")
end)

T.test("online: большая гильдия приходит целиком постранично", function()
	local w, c = Build()
	for i = 1, 120 do
		w:AddOnline("Чиллзон Север", ("Боец%03d Длиннофамильный-CAMWOWUS2Realm7PvE"):format(i), 3, 60, "ROGUE")
	end
	w:Run(130)
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(150)
	local state = c.K.ns.Online.Get("Чиллзон Север")
	T.ok(state.at, "список получен")
	T.eq(#state.people, 123, "все в игре")
	T.ok(Names(state)["Боец120 Длиннофамильный"], "и последний")
end)

---------------------------------------------------------------------------
-- Запасные адресаты
---------------------------------------------------------------------------
T.test("online: молчащий репортёр заменяется запасным адресатом", function()
	local w, c = Build()
	local name = Reporter(c.K, "Чиллзон Север")
	local reporter = ByName(c, name)
	reporter.ns.Comm.On("OQ", nil) -- как клиент старой версии: тип неизвестен
	local from = #w.log + 1
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(c.K.ns.Config.ONLINE_WAIT + 15)
	local state = c.K.ns.Online.Get("Чиллзон Север")
	T.ok(state.at, "ответил запасной")
	local queries = Sent(w, "OQ", from)
	T.eq(#queries, 2, "два адресата")
	T.eq(queries[1].target, name, "сначала репортёр")
	T.eq(queries[2].target, Other(c, "Чиллзон Север", name):Name(), "затем другой из руководства")
end)

T.test("online: если не ответил никто, это видно и повтор откладывается", function()
	local w, c = Build()
	c.V.ns.Comm.On("OQ", nil)
	c.B.ns.Comm.On("OQ", nil)
	c.K.ns.Online.Want("Чиллзон Север")
	T.ok(c.K.ns.Online.Get("Чиллзон Север").loading, "сначала запрос в пути")
	w:Run(c.K.ns.Config.ONLINE_WAIT * 3 + 10)
	T.ok(c.K.ns.Online.Get("Чиллзон Север").failed, "неудача отмечена")
	local from = #w.log + 1
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(3)
	T.eq(#Sent(w, "OQ", from), 0, "сразу не повторяем")
	w:Run(c.K.ns.Config.ONLINE_RETRY)
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(3)
	T.eq(#Sent(w, "OQ", from), 1, "после паузы пробуем снова")
end)

T.test("online: адресат в блокировке чата не отвечает, чтобы зритель спросил другого", function()
	local w, c = Build()
	local name = Reporter(c.K, "Чиллзон Север")
	local reporter = ByName(c, name)
	reporter.ns.Comm.InLockdown = function() return true end
	local from = #w.log + 1
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(c.K.ns.Config.ONLINE_WAIT + 15)
	T.ok(c.K.ns.Online.Get("Чиллзон Север").at, "ответил другой")
	for _, e in ipairs(Sent(w, "OL", from)) do
		T.ok(e.from ~= name, "из блокировки ничего не ушло")
	end
end)

---------------------------------------------------------------------------
-- Права и лимиты
---------------------------------------------------------------------------
T.test("online: без действующего сертификата объединения списка нет", function()
	local w, c = Build()
	w:Guild("Посторонние")
	local X = w:Client({ first = "Хитрый", surname = "Чужак", guild = "Посторонние", rank = 0 })
	w:Run(30)
	local from = #w.log + 1
	local name = Reporter(c.K, "Чиллзон Север")
	local Codec = X.ns.Codec
	-- Отпечаток настоящего сертификата участника, но шепчет другой игрок.
	local fp = c.K.ns.Security.MyCertificate().fp
	X.ns.Comm.Send("WHISPER", Codec.EncodeOnlineQuery("Чиллзон Север", fp), { target = name })
	w:Run(30)
	X.ns.Comm.Send("WHISPER", Codec.EncodeOnlineQuery("Чиллзон Север", "abcdefghijklmnop"), { target = name })
	w:Run(60)
	T.eq(#Sent(w, "OL", from), 0, "ответа нет")
end)

T.test("online: страницы принимаются только от спрошенного участника той гильдии", function()
	local w, c = Build()
	local Codec = c.K.ns.Codec
	local name = Reporter(c.K, "Чиллзон Север")
	local reporter = ByName(c, name)
	local fp = reporter.ns.Security.MyCertificate().fp
	local fake = Codec.EncodeOnlinePages("Чиллзон Север", fp, 100, { { name = "Подставной Игрок", class = "MAGE", level = 1 } })[1]
	-- Не спрашивали — страница не нужна, даже от настоящего участника.
	reporter.ns.Comm.Send("WHISPER", fake, { target = "Карл Великий" })
	w:Run(5)
	T.ok(not c.K.ns.Online.Get("Чиллзон Север").at, "без запроса не принято")
	-- Спросили репортёра, а отвечает другой: и подпись его сертификата настоящая.
	reporter.ns.Comm.On("OQ", nil)
	c.K.ns.Online.Want("Чиллзон Север")
	local other = Other(c, "Чиллзон Север", name)
	other.ns.Comm.On("OQ", nil)
	local otherFp = other.ns.Security.MyCertificate().fp
	local wrong = Codec.EncodeOnlinePages("Чиллзон Север", otherFp, 100, { { name = "Подставной Игрок", class = "MAGE", level = 1 } })[1]
	other.ns.Comm.Send("WHISPER", wrong, { target = "Карл Великий" })
	w:Run(5)
	T.eq(#c.K.ns.Online.Get("Чиллзон Север").people, 0, "ответ не от спрошенного отброшен")
end)

T.test("online: страница с чужой гильдией в сертификате отбрасывается", function()
	local w, c = Build()
	local name = Reporter(c.K, "Чиллзон Север")
	local reporter = ByName(c, name)
	reporter.ns.Comm.On("OQ", nil)
	c.K.ns.Online.Want("Чиллзон Север")
	w:Run(1)
	-- Отвечает названный адресат, но предъявляет сертификат другой гильдии (Карла).
	local fp = c.K.ns.Security.MyCertificate().fp
	local Codec = c.K.ns.Codec
	local wire = Codec.EncodeOnlinePages("Чиллзон Север", fp, 100, { { name = "Подставной Игрок", class = "MAGE", level = 1 } })[1]
	reporter.ns.Comm.Send("WHISPER", wire, { target = "Карл Великий" })
	w:Run(5)
	T.eq(#c.K.ns.Online.Get("Чиллзон Север").people, 0, "чужой сертификат не годится")
end)

-- Гильдия с большим онлайном: её список занимает несколько страниц.
local function Crowd(w)
	for i = 1, 120 do
		w:AddOnline("Чиллзон Север", ("Боец%03d Длиннофамильный-CAMWOWUS2Realm7PvE"):format(i), 3, 60, "ROGUE")
	end
	w:Run(130)
end

-- Подождать первую страницу, чтобы проверять поведение посреди передачи.
local function FirstPage(w, from)
	for _ = 1, 40 do
		if #Sent(w, "OL", from) > 0 then return end
		w:Run(0.25)
	end
	error("передача не началась")
end

T.test("online: занятый клиент не берёт лишних зрителей и освобождается после передачи", function()
	local w, c = Build()
	Crowd(w)
	local guild, name = "Чиллзон Север", Reporter(c.K, "Чиллзон Север")
	ByName(c, name).ns.Config.ONLINE_SERVE_MAX = 1
	local from = #w.log + 1
	local function ToA()
		local n = 0
		for _, e in ipairs(Sent(w, "OL", from)) do
			if e.from == name and e.target and e.target:find("Арагорн", 1, true) then n = n + 1 end
		end
		return n
	end
	c.K.ns.Online.Want(guild)
	FirstPage(w, from)
	T.ok(not c.K.ns.Online.Get(guild).at, "первый список ещё идёт")
	c.A.ns.Online.Want(guild)
	w:Run(90) -- ожидание первого адресата и восемь страниц от запасного
	T.ok(c.K.ns.Online.Get(guild).at, "первый зритель получил список")
	T.eq(ToA(), 0, "второму занятый клиент не отвечал")
	T.ok(c.A.ns.Online.Get(guild).at, "второй получил список у запасного адресата")
	local Codec = c.A.ns.Codec
	c.A.ns.Comm.Send("WHISPER", Codec.EncodeOnlineQuery(guild, c.A.ns.Security.MyCertificate().fp), { target = name })
	w:Run(30) -- запрос и страница ждут своей очереди за обычным трафиком реле
	T.ok(ToA() > 0, "после передачи клиент снова отвечает")
end)

T.test("online: одному спрашивающему не отвечают чаще GAP", function()
	local w, c = Build()
	local name = Reporter(c.K, "Чиллзон Север")
	local reporter = ByName(c, name)
	local Codec = c.K.ns.Codec
	local fp = c.K.ns.Security.MyCertificate().fp
	local function Ask() c.K.ns.Comm.Send("WHISPER", Codec.EncodeOnlineQuery("Чиллзон Север", fp), { target = name }) end
	local from = #w.log + 1
	Ask()
	w:Run(5)
	local first = #Sent(w, "OL", from)
	T.ok(first > 0, "первый запрос обслужен")
	Ask()
	w:Run(10)
	T.eq(#Sent(w, "OL", from), first, "повтор в пределах GAP не обслужен")
	w:Run(reporter.ns.Config.ONLINE_SERVE_GAP)
	Ask()
	w:Run(10)
	T.ok(#Sent(w, "OL", from) > first, "после GAP обслужен снова")
end)

T.test("online: передача большого списка не задерживает чат отправителя", function()
	local w, c = Build()
	Crowd(w)
	local guild, name = "Чиллзон Север", Reporter(c.K, "Чиллзон Север")
	local reporter, mate = ByName(c, name), Other(c, "Чиллзон Север", name)
	local from = #w.log + 1
	c.K.ns.Online.Want(guild)
	FirstPage(w, from)
	reporter:Slash("/cz1", "не ждёт списка")
	for _ = 1, 40 do
		T.ok(reporter.ns.Comm.Queued("ol:", false) <= 1, "в очереди отправителя одна страница за раз")
		if mate:Saw("не ждёт списка") > 0 then break end
		w:Run(0.25)
	end
	T.ok(mate:Saw("не ждёт списка") > 0, "строка чата дошла")
	T.ok(not c.K.ns.Online.Get(guild).at, "раньше, чем закончился список")
	w:Run(150)
	T.ok(c.K.ns.Online.Get(guild).at, "и список всё равно дошёл")
end)

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------
T.test("online: вкладка показывает список и запрашивает только выбранное", function()
	local w, c = Build()
	local K = c.K
	local P = K.ns.CensusPane
	K.ns.UI.Toggle("census")
	local f = P.frames
	local key = K.ns.Util.GuildKey
	local from = #w.log + 1
	w:Run(3)
	T.eq(#Sent(w, "OQ", from), 0, "своя гильдия выбрана: шёпотов нет")
	T.eq(f.cardGrid.heads[1]:IsShown(), true, "заголовок своего списка виден")
	P.Select(key("Чиллзон Север"))
	w:Run(15)
	T.eq(#Sent(w, "OQ", from), 1, "запрос выбранной гильдии")
	local shown = {}
	for _, cell in ipairs(f.cardGrid.cells) do
		if cell:IsShown() then shown[cell.person.name] = cell.person end
	end
	T.ok(shown["Живой Безаддонный"], "в карточке есть игрок без аддона")
	T.eq(shown["Вера Верная"].role, "leader", "глава отмечен")
	T.eq(shown["Живой Безаддонный"].role, "member", "рядовой")
	-- Другая вкладка ничего не запрашивает, даже когда список устарел.
	K.ns.UI.Toggle("settings")
	T.ok(not f.pane:IsShown(), "вкладка «Перепись» закрыта")
	local after = #w.log + 1
	w:Run(K.ns.Config.ONLINE_REFRESH + 30)
	T.eq(#Sent(w, "OQ", after), 0, "закрытая вкладка не шепчет")
end)

T.test("online: вид «Все гильдии» группирует людей по гильдиям", function()
	local w, c = Build()
	local K = c.K
	local P = K.ns.CensusPane
	K.ns.UI.Toggle("census")
	local f = P.frames
	T.ok(f.allRow:IsShown(), "строка видна")
	f.allRow.scripts.OnClick(f.allRow)
	T.eq(P.Selected(), "*", "выбран общий вид")
	T.ok(f.all:IsShown(), "вид показан")
	T.ok(not f.card:IsShown(), "карточка убрана")
	w:Run(15)
	T.eq(f.allGrid.heads[1]:IsShown(), true, "заголовок первой гильдии")
	T.eq(f.allGrid.heads[2]:IsShown(), true, "заголовок второй")
	local names = {}
	for _, cell in ipairs(f.allGrid.cells) do
		if cell:IsShown() then names[cell.person.name] = true end
	end
	T.ok(names["Карл Великий"], "своя гильдия")
	T.ok(names["Живой Безаддонный"], "чужая гильдия")
	P.Select(K.ns.Util.GuildKey("Чиллзон"))
	T.ok(not f.all:IsShown(), "возврат к карточке прячет общий вид")
	T.ok(f.card:IsShown(), "и показывает карточку")
end)
