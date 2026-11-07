-- Диагностика: записи ошибок (дедуп, стек, миграция), блокировки игрой, отчёт об ошибке без
-- секретов, профайлер, журнал действий доверия и персонаж автора («Просмотр как», отчёт
-- автору кусками B1/B2, отказ не автору).
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local PVP = "CAMWOWEU1Realm12PvP"

local function One(opts)
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client(opts or { first = "Ошибка", surname = "Тестовая", guild = "Чиллзон", rank = 0 })
	return w, c
end

-- Все строки длиной от 32 знаков внутри таблицы (ключи, подписи, сертификаты).
local function Secrets(t, out, seen)
	out, seen = out or {}, seen or {}
	if type(t) ~= "table" or seen[t] then return out end
	seen[t] = true
	for k, v in pairs(t) do
		for _, x in ipairs({ k, v }) do
			if type(x) == "string" and #x >= 32 then out[#out + 1] = x end
			if type(x) == "table" then Secrets(x, out, seen) end
		end
	end
	return out
end

local function Printed(c, text)
	return c:Saw(text) > 0
end

T.test("диагностика: ошибки — запись со стеком, дедуп, лимит, аргументы", function()
	local _, c = One()
	local ns = c.ns
	local function Boom() error("сломалось") end
	T.no(ns.SafeCall("проба", Boom), "ошибка — false")
	T.no(ns.SafeCall("проба", Boom))
	local errors = ns.db.errors
	T.eq(#errors, 1, "повтор — та же запись")
	local e = errors[1]
	T.eq(e.where, "проба")
	T.ok(e.msg:find("сломалось", 1, true), "текст ошибки")
	T.eq(e.count, 2, "счётчик повторов")
	T.eq(e.version, ns.VERSION)
	T.ok(type(e.first) == "string" and type(e.last) == "string", "когда")
	T.ok(type(e.stack) == "string" and e.stack:find("test_diag", 1, true), "стек ведёт к месту ошибки: " .. tostring(e.stack))
	T.eq(c:Saw("внутренняя ошибка"), 1, "игроку сказано один раз")
	ns.SafeCall("другое", function() error({}) end)
	T.eq(#errors, 2)
	T.eq(errors[1].where, "другое", "новая — первой")
	ns.SafeCall("проба", Boom)
	T.eq(errors[1].where, "проба", "повтор поднимается наверх")
	T.eq(errors[1].count, 3)
	-- Аргументы, в том числе nil в середине и в конце, доходят как есть.
	local got
	T.ok(ns.SafeCall("args", function(...) got = { n = select("#", ...), ... } end, 1, nil, 3, nil))
	T.eq(got.n, 4, "число аргументов")
	T.eq(got[1], 1); T.eq(got[2], nil); T.eq(got[3], 3)
	for i = 1, 70 do ns.SafeCall("много " .. i, Boom) end
	T.eq(#errors, ns.MAX_ERRORS, "не больше MAX_ERRORS")
	c:Slash("/chillzone", "log 1")
	T.ok(Printed(c, "[1x] много 70"), "/chillzone log показывает ошибки")
	T.ok(Printed(c, "/chillzone bug"), "и куда смотреть дальше")
end)

T.test("диагностика: старые записи-строки переводятся в таблицы", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Старая", surname = "Версия", guild = "Чиллзон", db = { errors = { "место: сломалось: совсем", 42, { where = "x", msg = "y" } } } })
	local errors = c.ns.db.errors
	T.eq(#errors, 2, "мусор отброшен")
	T.eq(errors[1].where, "место")
	T.eq(errors[1].msg, "сломалось: совсем")
	T.eq(errors[1].count, 1)
	T.eq(errors[1].stack, "")
	T.eq(errors[2].where, "x")
	T.eq(#c:Leaks(), 0, "утечки: " .. table.concat(c:Leaks(), ", "))
end)

T.test("диагностика: блокировки игрой — только свои, со счётчиком", function()
	local _, c = One()
	c:Fire("ADDON_ACTION_BLOCKED", "Chillzone", "CastSpellByName()")
	c:Fire("ADDON_ACTION_BLOCKED", "Chillzone", "CastSpellByName()")
	c:Fire("ADDON_ACTION_FORBIDDEN", "Chillzone", "TargetUnit()")
	c:Fire("ADDON_ACTION_BLOCKED", "OtherAddon", "UseAction()")
	local list = c.ns.db.blocked
	T.eq(#list, 2, "чужой аддон не записан")
	T.eq(list[1].func, "TargetUnit()")
	T.eq(list[1].event, "ADDON_ACTION_FORBIDDEN")
	T.eq(list[2].count, 2)
	T.eq(type(list[2].stack), "string")
	T.eq(#c.ns.db.errors, 0)
end)

T.test("отчёт об ошибке: клиент, пробы API, ошибки — и ни ключей, ни сертификатов", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 0 })
	local O = w:Client({ first = "Олег", surname = "Смелый", guild = "Чиллзон", rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	w:Run(30)
	w:Init(A, V)
	w:Pair(V, A)
	w:Run(120)
	local secrets = Secrets(A.ns.db.securityKeys)
	for _, s in ipairs(Secrets(A.ns.store.security)) do secrets[#secrets + 1] = s end
	T.ok(#secrets > 3, "у офицера есть ключи и сертификаты")
	-- Ключ, попавший в текст ошибки, тоже вычищается.
	local pub = A.ns.db.securityKeys[next(A.ns.db.securityKeys)].public
	A.ns.SafeCall("утечка", function() error("ключ " .. tostring(pub)) end)
	A:Slash("/chillzone", "bug")
	local copy = A.ns.UI.copy
	T.ok(copy and copy:IsShown(), "окно копирования открыто")
	T.eq(copy.heading, A.ns.L.BUG_TITLE)
	local text = copy.text
	for _, s in ipairs(secrets) do T.no(text:find(s, 1, true), "секрет в отчёте: " .. s:sub(1, 12)) end
	T.no(text:find(tostring(pub), 1, true), "ключ из текста ошибки")
	T.ok(text:find("[ключ скрыт]", 1, true), "на месте ключа — метка")
	for _, want in ipairs({ "Chillzone " .. A.ns.VERSION, "1.15.7", "ruRU", "Арагорн Светлый", "ForeverPvE", "гильдия: Чиллзон",
		"офицер: да", "уровень чата: 3", "пробы API:", "флаги звания (GuildControlGetRankFlags): индекс 1", "[22]=true",
		"GetServerTime() - time() = 0", "UnitFullName: «Арагорн», «Светлый»", "режим геймпада: нет", "утечка",
		"/chillzone status:", "журнал, последние строки" }) do
		T.ok(text:find(want, 1, true), "в отчёте есть «" .. want .. "»")
	end
	T.no(text:find("|", 1, true), "без кодов игры")
	T.no(text:find("корень доверия —", 1, true), "журнал действий доверия в отчёт не попал")
	T.ok(#A.ns.Acts.List() > 0, "а сам журнал есть")
	-- Офицерам чужой гильдии и рядовым — тот же отчёт; кнопка в «Настройках» есть у всех.
	O:Slash("/chillzone", "bug")
	T.ok(O.ns.UI.copy.text:find("Олег Смелый", 1, true))
	-- «Выделить всё» ставит фокус в своё поле, а не в поле ввода чата.
	A.ns.UI.SelectCopy()
	T.ok(copy.edit:HasFocus(), "фокус в поле окна копирования")
	T.no(A.env.ChatFrame1EditBox:HasFocus(), "поле ввода чата не тронуто")
	for _, cl in ipairs({ A, O, V }) do T.eq(#cl:Leaks(), 0, cl:Name() .. ": утечки " .. table.concat(cl:Leaks(), ", ")) end
end)

T.test("профайлер: включение, метки без ввода, вложенность, Ed25519, выключение, /reload", function()
	local w, c = One({ first = "Проф", surname = "Тестовый", guild = "Чиллзон", rank = 0 })
	local ns = c.ns
	local plain, edAfter = ns.SafeCall, ns.Ed25519.after
	T.eq(ns.db.perf, nil, "пока не включали — ничего не сохранено")
	c:Slash("/chillzone", "perf on")
	T.ok(ns.Perf.On())
	T.ok(ns.SafeCall ~= plain, "ns.SafeCall обёрнут")
	T.ok(ns.Ed25519.after ~= edAfter, "Ed.after обёрнут")
	T.ok(ns.db.perf.on)
	ns.SafeCall("/chillzone ignore Вася Пупкин", function() end)
	ns.SafeCall("timer 12345|секрет", function() end)
	ns.SafeCall("outer", function() ns.SafeCall("inner", function() end) end)
	local stats = ns.db.perf.stats
	T.ok(stats["/chillzone ignore"], "команда — без аргументов")
	T.ok(stats["timer #"], "числа и хвост после | убраны")
	for label in pairs(stats) do T.no(label:find("Вася", 1, true) or label:find("секрет", 1, true), "метка без ввода: " .. label) end
	T.eq(stats.outer.n, 1)
	T.eq(stats.inner.n, 1)
	T.ok(stats.outer.total >= stats.inner.total, "время внешнего включает вложенный")
	-- Кусок проверки подписи — своя строка.
	local ran = false
	ns.Ed25519.after(function() ran = true end)
	w:Run(1)
	T.ok(ran)
	T.ok(stats[ns.Perf.ED] and stats[ns.Perf.ED].n >= 1, "строка ed25519")
	-- Кадры: своё OnUpdate.
	local f = ns.Perf.frame
	ns.Perf.FRAME_MS = 0
	ns.SafeCall("кадр", function() end)
	f.scripts.OnUpdate(f, 0.02)
	T.eq(ns.db.perf.frames, 1)
	T.eq(ns.db.perf.heavy, 1)
	T.eq(#ns.db.perf.worst, 1)
	ns.Perf.FRAME_MS = 20
	T.ok(#ns.db.perf.slow > 0 and #ns.db.perf.slow <= ns.Perf.SLOW_KEEP)
	c:Slash("/chillzone", "perf")
	T.eq(ns.UI.copy.heading, ns.L.PERF_TITLE)
	T.ok(ns.UI.copy.text:find("/chillzone ignore", 1, true))
	T.ok(ns.UI.copy.text:find("ed25519", 1, true))
	-- После /reload включается снова, замеры на месте.
	c:Logout()
	local again = w:Client({ first = "Проф", surname = "Тестовый", guild = "Чиллзон", rank = 0, db = c.env.ChillzoneDB })
	T.ok(again.ns.Perf.On(), "включён после /reload")
	T.ok(again.ns.db.perf.stats.outer, "замеры сохранились")
	local function Source(fn) return debug.getinfo(fn, "S").source end
	T.ok(Source(again.ns.Ed25519.after):find("Perf.lua", 1, true), "Ed.after снова обёрнут")
	again:Slash("/chillzone", "perf off")
	T.ok(Source(again.ns.Ed25519.after):find("Ed25519.lua", 1, true), "Ed.after — снова из библиотеки")
	T.no(again.ns.Perf.On())
	T.no(again.ns.db.perf.on)
	T.ok(again.ns.db.perf.stats.outer, "выключение не стирает")
	T.eq(again.ns.Perf.frame.scripts.OnUpdate, nil, "OnUpdate снят")
	again.ns.SafeCall("после выключения", function() end)
	T.eq(again.ns.db.perf.stats["после выключения"], nil, "выключенный не меряет")
	again:Slash("/chillzone", "perf reset")
	T.eq(next(again.ns.db.perf.stats), nil, "reset стирает")
	-- Выключенный — ровно прежние функции.
	c = again
	ns = c.ns
	c:Slash("/chillzone", "perf on")
	c:Slash("/chillzone", "perf off")
	local fresh = w:Client({ first = "Без", surname = "Профайлера", guild = "Чиллзон" })
	T.eq(Source(ns.SafeCall), Source(fresh.ns.SafeCall), "ns.SafeCall снова из Core.lua")
	T.ok(Source(ns.SafeCall):find("Core.lua", 1, true))
	T.eq(#c.ns.db.errors, 0, T.errors(c.ns.db.errors))
	T.eq(#c:Leaks(), 0, "утечки: " .. table.concat(c:Leaks(), ", "))
end)

T.test("журнал действий доверия: корни, связь, сброс, снятие отзыва — только своё", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 0 })
	local O = w:Client({ first = "Олег", surname = "Смелый", guild = "Чиллзон", rank = 1 })
	local V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	w:Run(30)
	w:Init(A, V)
	w:Pair(V, A)
	w:Run(60)
	local function Has(cl, kind, guild, by, via)
		for _, e in ipairs(cl.ns.Acts.List()) do
			if e.kind == kind and (not guild or e.guild == guild) and (not by or e.by == by) and (not via or e.via == via) then return e end
		end
		return nil
	end
	T.ok(Has(A, "root", "Чиллзон", "Арагорн Светлый", "init"), "свой trust init")
	T.ok(Has(O, "root", "Чиллзон", "Арагорн Светлый", "KT"), "корень своей гильдии от офицера (KT)")
	T.ok(Has(V, "link_out", nil, "Вера Верная", "link"), "свой запрос связи")
	T.ok(Has(A, "link_in", "Чиллзон Север", "Вера Верная", "KL"), "чужой запрос связи")
	T.ok(Has(A, "root", "Чиллзон Север", "Арагорн Светлый", "accept"), "корень чужой гильдии после accept")
	T.ok(Has(A, "link_ok", "Чиллзон Север", "Арагорн Светлый", "accept"), "подтверждение связи")
	T.ok(Has(V, "root", "Чиллзон", "Арагорн Светлый", "link"), "корень по ответу на link")
	T.ok(Has(V, "link_ok", "Чиллзон"), "у второй стороны — тоже")
	T.ok(Has(O, "root", "Чиллзон Север", "Арагорн Светлый", "KT"), "корень чужой гильдии от своего офицера")
	T.no(Has(O, "link_in"), "чужой запрос связи видит только адресат")
	-- Повторный KT того же корня — не новое действие.
	local before = #O.ns.Acts.List()
	A.ns.Security.ShareTrust()
	w:Run(30)
	T.eq(#O.ns.Acts.List(), before, "без изменений — без записи")
	-- Сброс: свой и полученный от офицера (KF).
	local gk = A.ns.Util.GuildKey("Чиллзон Север")
	local northRoot = O.ns.Security.Roots()[gk].public
	T.ok(A.ns.Security.Reset("Чиллзон Север"))
	w:Run(10)
	T.ok(Has(A, "reset", "Чиллзон Север", "Арагорн Светлый", "own"), "свой trust reset")
	T.ok(Has(O, "reset", "Чиллзон Север", "Арагорн Светлый", "KF"), "сброс от офицера (KF)")
	-- Снятие отзыва (KU) от офицера своей гильдии.
	A.ns.Comm.Send("GUILD", "KU~Чиллзон Север~" .. northRoot, { prio = true })
	w:Run(10)
	T.ok(Has(O, "unretire", "Чиллзон Север", "Арагорн Светлый", "KU"), "KU")
	-- Подписи из журнала не уходят в сеть.
	for _, m in ipairs(w.log) do T.no(m.msg:find("корень доверия", 1, true), "журнал в сети") end
	-- Команда и окно.
	O:Slash("/chillzone", "acts")
	T.ok(O:Saw("Журнал действий доверия") > 0)
	T.ok(O:Saw("от офицера (KF)") > 0)
	O:Slash("/chillzone", "acts copy")
	T.eq(O.ns.UI.copy.heading, O.ns.L.ACT_TITLE)
	T.ok(O.ns.UI.copy.text:find("корень доверия", 1, true))
	-- На «Отладке» офицера — раздел и строка «весь журнал».
	local found = false
	for _, l in ipairs(O.ns.Debug.Lines()) do
		if l.onClick and l.text:find("весь журнал", 1, true) then found = true; l.onClick() end
	end
	T.ok(found, "строка «весь журнал» на «Отладке»")
	-- Лимит.
	for i = 1, 320 do O.ns.Acts.Add("root", "Гильдия " .. i, "Кто", "KT", "Кто") end
	T.eq(#O.ns.Acts.List(), O.ns.Acts.MAX)
	T.eq(O.ns.Acts.List()[O.ns.Acts.MAX].guild, "Гильдия 320", "новые в конце")
	for _, cl in ipairs({ A, O, V }) do T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": " .. T.errors(cl.ns.db.errors)) end
end)

T.test("автор: Config.AUTHOR и U.IsAuthor", function()
	local _, c = One()
	local U, C = c.ns.Util, c.ns.Config
	T.eq(C.AUTHOR.name, "Могаю Прохожих")
	T.eq(U.GroupOf(PVP), C.AUTHOR.group, "группа автора — как её считает U.GroupOf")
	T.ok(U.IsAuthor("Могаю Прохожих", "ForeverPvP"))
	T.ok(U.IsAuthor("Могаю Прохожих-" .. PVP, "ForeverPvP"), "с реалмом")
	T.ok(U.IsAuthor("могаю прохожих", "ForeverPvP"), "регистр имени не важен")
	T.no(U.IsAuthor("Могаю Прохожих", "ForeverPvE"), "другая группа")
	T.no(U.IsAuthor("Могаю Другой", "ForeverPvP"))
	T.no(U.IsAuthor(nil, "ForeverPvP"))
	T.no(c.ns.Author.IsMe())
end)

T.test("автор: «Просмотр как» меняет показ, но не Chat.MyLevel", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local P = w:Client({ first = "Могаю", surname = "Прохожих", realm = PVP, guild = "Чиллзон", rank = 3 })
	local N = w:Client({ first = "Могаю", surname = "Прохожих", realm = "CAMWOWUS2Realm7PvE", guild = "Чиллзон", rank = 3 })
	w:Run(30)
	local A, Chat, Debug = P.ns.Author, P.ns.Chat, P.ns.Debug
	T.ok(A.IsMe(), "автор на PvP")
	T.no(N.ns.Author.IsMe(), "тёзка в другой группе реалмов — не автор")
	T.eq(Chat.MyLevel(), 1, "автор — рядовой участник")
	T.ok(Debug.Allowed(), "автору «Отладка» видна всегда")
	T.no(N.ns.Debug.Allowed(), "рядовому — нет")
	local function Chans(cl) return table.concat(cl.ns.Chat.Channels(), ",") end
	T.eq(Chans(P), "G,A")
	T.ok(A.SetView(3))
	T.eq(Chans(P), "G,A,C,L", "как Лорд/Король")
	T.ok(Debug.Allowed())
	T.eq(Chat.MyLevel(), 1, "настоящий уровень не тронут")
	T.ok(A.SetView(2))
	T.eq(Chans(P), "G,A,C", "как Капитан")
	T.ok(A.SetView(1))
	T.eq(Chans(P), "G,A")
	T.no(Debug.Allowed(), "участнику «Отладка» не видна")
	T.ok(A.SetView(0))
	T.eq(Chans(P), "G", "вне связи")
	T.no(A.SetView(7), "неверный уровень")
	A.CycleView()
	T.eq(A.ViewLevel(), 1, "кнопка идёт по кругу")
	T.ok(A.SetView(nil))
	T.eq(A.ViewLevel(), nil)
	T.no(N.ns.Author.SetView(3), "не автору нельзя")
	T.eq(N.ns.Author.ViewLevel(), nil)
	N:Slash("/chillzone", "view 3")
	T.ok(N:Saw(N.ns.L.VIEW_ONLY_AUTHOR) > 0)
	P:Slash("/chillzone", "view 2")
	T.eq(A.ViewLevel(), 2)
	-- Раздел автора на «Отладке».
	local author = false
	for _, l in ipairs(Debug.Lines()) do if l.text:find("Автор аддона", 1, true) then author = true end end
	T.ok(author)
	for _, l in ipairs(N.ns.Debug.Lines()) do T.no(l.text:find("Автор аддона", 1, true), "у не автора раздела нет") end
	-- Настоящий уровень решает отправку: рядовой в «Просмотре как Король» в канал глав не пишет.
	local before = #w.log
	Chat.Send("L", "проверка")
	for i = before + 1, #w.log do T.no(w.log[i].msg:find("проверка", 1, true), "уровень L не отправлен") end
	for _, cl in ipairs({ P, N }) do T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": " .. T.errors(cl.ns.db.errors)) end
end)

T.test("автор: отчёт кусками по шёпоту, ответы автора, лимиты, отказ не автору", function()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local P = w:Client({ first = "Могаю", surname = "Прохожих", realm = PVP, guild = "Чиллзон", rank = 3 })
	local X = w:Client({ first = "Игрок", surname = "Тестов", realm = PVP, guild = "Чиллзон", rank = 3 })
	local Y = w:Client({ first = "Яна", surname = "Вторая", realm = PVP, guild = "Чиллзон", rank = 3 })
	local N = w:Client({ first = "Нина", surname = "Ничья", realm = PVP, guild = "Чиллзон", rank = 3 })
	w:Run(30)
	T.ok(X.ns.Author.Online(), "автор в ростере и в игре")
	T.no(P.ns.Author.Online(), "сам себе не отправляет")
	X:Slash("/chillzone", "bug")
	local copy = X.ns.UI.copy
	local send = copy.actions[1]
	T.ok(send and send:IsShown(), "кнопка «Отправить автору»")
	T.eq(send.text, X.ns.L.AUTHOR_SEND)
	local report = copy.text
	local mark = #w.log
	send.scripts.OnClick(send)
	w:Run(120)
	T.ok(X:Saw(X.ns.L.AUTHOR_DELIVERED) > 0, "автор подтвердил приём")
	local inbox = P.ns.Author.Inbox()
	T.eq(#inbox, 1)
	T.eq(inbox[1].from, "Игрок Тестов")
	T.eq(inbox[1].text, report:gsub("\\", "/"), "отчёт собран целиком, с переводами строк")
	-- Куски: только шёпот на «Имя Фамилия» без реалма, каждый в пределах 255 байт.
	local pieces = 0
	for i = mark + 1, #w.log do
		local m = w.log[i]
		if m.msg:sub(1, 2) == "B1" then
			pieces = pieces + 1
			T.eq(m.dist, "WHISPER")
			T.eq(m.target, "Могаю Прохожих")
			T.ok(#m.msg <= 255, "кусок не длиннее 255 байт")
		end
		if m.msg:sub(1, 2) == "B2" then T.eq(m.from, "Могаю Прохожих", "отвечает только автор") end
	end
	T.ok(pieces > 1, "отчёт ушёл несколькими кусками: " .. pieces)
	-- Не чаще раза в 10 минут.
	T.no(X.ns.Author.Send("ещё"), "второй отчёт сразу — нельзя")
	T.ok(X:Saw("следующий отчёт можно отправить через 8 мин") > 0, "осталось 8 минут из 10")
	-- B2 не от автора не считается.
	T.ok(Y.ns.Author.Send("проба Яны"))
	local id
	for _ = 1, 50 do
		w:Run(0.2)
		for i = #w.log, 1, -1 do
			local m = w.log[i]
			if m.from == "Яна Вторая" and m.msg:sub(1, 2) == "B1" then id = m.msg:match("^B1~(%w+)~") break end
		end
		if id then break end
	end
	T.ok(id, "первый кусок Яны ушёл")
	Y.ns.Comm.Dispatch("B2~" .. id .. "~2", "Нина Ничья-" .. PVP, "WHISPER")
	T.ok(Y.ns.Author.Sending(), "чужое подтверждение не принято")
	w:Run(60)
	T.no(Y.ns.Author.Sending())
	T.ok(Y:Saw(Y.ns.L.AUTHOR_DELIVERED) > 0)
	-- Не автору B1 ничего не даёт: ни отчёта, ни ответа.
	mark = #w.log
	X.ns.Comm.Send("WHISPER", "B1~zz~1~1~привет", { target = "Нина Ничья", prio = true })
	w:Run(10)
	T.eq(#N.ns.Author.Inbox(), 0, "не автор отчёты не хранит")
	for i = mark + 1, #w.log do T.no(w.log[i].from == "Нина Ничья" and w.log[i].msg:sub(1, 2) == "B2", "не автор не отвечает") end
	-- У автора: не больше трёх отчётов в час от одного игрока.
	for i = 1, 3 do
		X.ns.db.bugSentAt = nil
		X.ns.Author.Send("проба " .. i)
		w:Run(40)
	end
	local fromX = 0
	for _, e in ipairs(inbox) do if e.from == "Игрок Тестов" then fromX = fromX + 1 end end
	T.eq(fromX, 3, "четвёртый за час не принят")
	T.ok(X:Saw(X.ns.L.AUTHOR_NO_ANSWER) > 0, "игроку сказано, что ответа нет")
	-- Принятые — на «Отладке» автора, щелчок открывает отчёт.
	local opened = false
	for _, l in ipairs(P.ns.Debug.Lines()) do
		if l.onClick and l.text:find("Игрок Тестов", 1, true) and not opened then
			l.onClick()
			opened = true
		end
	end
	T.ok(opened)
	T.ok(P.ns.UI.copy.heading:find("Отчёт от", 1, true))
	-- Автор вышел — кнопки нет.
	P:Logout()
	X:Fire("GUILD_ROSTER_UPDATE")
	w:Run(30)
	X.ns.db.bugSentAt = nil
	X:Slash("/chillzone", "bug")
	T.no(X.ns.UI.copy.actions[1] and X.ns.UI.copy.actions[1]:IsShown(), "без автора в игре кнопки нет")
	for _, cl in ipairs({ X, Y, N }) do
		T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": " .. T.errors(cl.ns.db.errors))
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": утечки " .. table.concat(cl:Leaks(), ", "))
	end
end)
