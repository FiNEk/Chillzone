-- Индикатор асинхронных операций и обновление данных по просьбе игрока.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Solo(opts)
	opts = opts or {}
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = opts.rank or 0 })
	return w, c
end

local function Homeless()
	local w = Wow.World()
	local c = w:Client({ first = "Новичок", surname = "Бездомный" })
	return w, c
end

-- Две гильдии, реле и репортёры: всё, что нужно для настоящего ответа на Q1.
local function Network()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2 })
	w:Run(30)
	w:Init(c.A, c.V)
	w:Pair(c.V, c.K)
	w:Run(400)
	return w, c
end

-- Кто в гильдии Север репортёр, а кто нет.
local function Roles(c)
	if c.V.ns.Census.IsReporter() then return c.V, c.B end
	return c.B, c.V
end

local function Spy(c)
	local sent = {}
	local original = c.ns.Comm.Send
	c.ns.Comm.Send = function(dist, msg, opts)
		local kind = msg:sub(1, 2)
		sent[kind] = (sent[kind] or 0) + 1
		return original(dist, msg, opts)
	end
	return sent
end

-- Все итоги обновления по порядку.
local function Notes(c)
	local notes = {}
	local original = c.ns.Activity.Note
	c.ns.Activity.Note = function(text, kind, ttl)
		notes[#notes + 1] = text
		return original(text, kind, ttl)
	end
	return notes
end

local function Find(c, text)
	for _, row in ipairs(c.ns.Activity.List()) do
		if row.text == text then return row end
	end
end

local function Errors(...)
	for _, c in ipairs({ ... }) do
		T.eq(#(c.ns.db.errors or {}), 0, "ошибки Lua: " .. tostring((c.ns.db.errors or {})[1]))
	end
end

local function Tick(c)
	local frame = c.ns.UI.frame
	frame.scripts.OnUpdate(frame, 0.3)
end

-- Строки подсказки при наведении на owner.
local function Tip(c, owner)
	local lines = {}
	c.stubs.GameTooltip = true
	c.env.GameTooltip = {
		SetOwner = function() end, Show = function() end, Hide = function() end,
		AddLine = function(_, text) lines[#lines + 1] = text end,
	}
	owner:GetScript("OnEnter")(owner)
	return table.concat(lines, "\n")
end

---------------------------------------------------------------------------
-- Трекер
---------------------------------------------------------------------------
T.test("activity: по истечении срока успех — только если были ответы", function()
	local w, c = Solo()
	local A, done = c.ns.Activity, {}
	c.ns.On("ACTIVITY_DONE", function(id, ok) done[id] = ok end)
	A.Start("silent", "Жду", 5)
	A.Start("answered", "Жду", 5)
	T.ok(A.Running("silent"))
	T.ok(A.Touch("answered", nil, 1))
	w:Run(6)
	T.eq(done.silent, false, "никто не ответил")
	T.eq(done.answered, true, "ответ был")
	T.no(A.Running("silent"))
	T.no(A.Touch("silent", 5, 1), "законченную операцию не трогаем")
	Errors(c)
end)

T.test("activity: ответ переносит срок, старый таймер ничего не закрывает", function()
	local w, c = Solo()
	local A, done = c.ns.Activity, {}
	c.ns.On("ACTIVITY_DONE", function(id, ok) done[id] = ok end)
	A.Start("x", "Жду", 5)
	w:Run(3)
	A.Touch("x", 10, 1)
	w:Run(4)
	T.ok(A.Running("x"), "первый срок прошёл, но перенесён")
	w:Run(7)
	T.eq(done.x, true)
end)

T.test("activity: повторный запрос продлевает ту же операцию, событие одно", function()
	local w, c = Solo()
	local A, n = c.ns.Activity, 0
	c.ns.On("ACTIVITY_DONE", function(id) if id == "x" then n = n + 1 end end)
	A.Start("x", "Жду", 5)
	A.Touch("x", nil, 2)
	w:Run(3)
	A.Start("x", "Снова жду", 5)
	T.eq(Find(c, "Снова жду").kind, "wait")
	w:Run(6)
	T.eq(n, 1)
	T.no(A.Finish("x"), "закончить второй раз нечего")
	T.eq(n, 1)
end)

T.test("activity: сначала то, что мешает, сломанная проба снимается", function()
	local _, c = Solo()
	local A = c.ns.Activity
	A.Probe(function() return { kind = "work", text = "работа" } end)
	A.Probe(function() return { kind = "block", text = "помеха" } end)
	A.Probe(function() error("сломано") end)
	A.Start("x", "ожидание", 5)
	local list = A.List()
	T.eq(list[1].text, "помеха")
	T.eq(list[2].text, "ожидание")
	T.eq(list[3].text, "работа")
	T.eq(#c.ns.db.errors, 1, "ошибка записана")
	A.List()
	T.eq(#c.ns.db.errors, 1, "только один раз")
end)

T.test("activity: итог виден недолго и уступает активной работе", function()
	local w, c = Solo()
	w:Run(10)
	local A, V = c.ns.Activity, c.ns.Views
	A.Note("Готово")
	T.eq(V.Activity().text, "Готово")
	T.eq(V.Activity().kind, "done")
	A.Start("x", "Жду", 30)
	T.eq(V.Activity().text, "Жду", "активное важнее итога")
	A.Finish("x")
	T.eq(V.Activity().text, "Готово", "итог ещё не истёк")
	w:Run(7)
	T.eq(A.LastNote(), nil, "итог истёк")
end)

T.test("activity: несколько строк сворачиваются, короткая не мигает", function()
	local w, c = Solo()
	w:Run(10)
	local A, V = c.ns.Activity, c.ns.Views
	A.Start("a", "Первая", 30)
	A.Start("b", "Вторая", 30)
	T.eq(V.Activity().text, "Вторая, ещё 1", "порядок не зависит от очерёдности запуска")
	A.Finish("a")
	A.Finish("b")
	T.eq(V.Activity().text, "Вторая, ещё 1", "последнюю строку держим секунду")
	w:Run(1.5)
	T.eq(V.Activity(), nil)
end)

---------------------------------------------------------------------------
-- Пробы модулей
---------------------------------------------------------------------------
T.test("activity: запрет отправки виден, пока есть что отправить", function()
	local w, c = Solo()
	w:Run(1)
	local L = c.ns.L
	T.eq(Find(c, L.ACT_LOCKDOWN), nil, "пустая очередь — запрет не мешает")
	c.lockdown = true
	c.ns.Comm.Send("GUILD", "Q1~")
	local row = c.ns.Activity.List()[1]
	T.eq(row.kind, "block")
	T.eq(row.text, L.ACT_LOCKDOWN)
	T.ok(row.detail:find("1", 1, true), "сколько сообщений ждёт")
	c.lockdown = false
	w:Run(8)
	T.eq(Find(c, L.ACT_LOCKDOWN), nil, "запрет снят, очередь ушла")
	Errors(c)
end)

T.test("activity: участник без сертификата видит причину, но не сразу после входа", function()
	local w, c = Solo()
	local L = c.ns.L
	T.eq(Find(c, L.ACT_NO_CERT), nil, "сразу после входа рано")
	w:Run(25)
	local row = Find(c, L.ACT_NO_CERT)
	T.ok(row, "через 20 секунд причина видна")
	T.eq(row.kind, "block")
	T.eq(row.detail, c.ns.Security.NotReadyReason())
	Errors(c)
end)

T.test("activity: вне объединения нет строки о сертификате", function()
	local w, c = Homeless()
	w:Run(25)
	T.eq(Find(c, c.ns.L.ACT_NO_CERT), nil)
	Errors(c)
end)

T.test("activity: строка чата подписывается видимо", function()
	local w, c = Network()
	local L = c.A.ns.L
	T.ok(c.A.ns.Chat.Send("A", "проверка"))
	T.ok(Find(c.A, L.ACT_CHAT), "подпись идёт")
	w:Run(15)
	T.eq(Find(c.A, L.ACT_CHAT), nil, "подпись закончена")
	Errors(c.A)
end)

T.test("activity: перепись, запрос после входа виден и заканчивается сам", function()
	local w, c = Solo({ rank = 3 })
	w:Run(16)
	if c.ns.Census.IsReporter() then return end
	T.ok(c.ns.Activity.Running("census"), "Q1 ушёл, ждём ответ")
	w:Run(60)
	T.no(c.ns.Activity.Running("census"), "никто не ответил — не ждём вечно")
	Errors(c)
end)

---------------------------------------------------------------------------
-- Обновление
---------------------------------------------------------------------------
T.test("refresh: вне гильдии недоступно и объясняется", function()
	local _, c = Homeless()
	T.no(c.ns.Refresh.Available())
	local ok, why = c.ns.Refresh.Run(false)
	T.eq(ok, false)
	T.eq(why, "guild")
	c:Slash("/chillzone", "refresh")
	T.eq(c:Saw(c.ns.L.REFRESH_NO_GUILD), 1)
	Errors(c)
end)

T.test("refresh: участник читает ростер, потом спрашивает репортёра и реле", function()
	local w, c = Network()
	local _, member = Roles(c)
	local ns = member.ns
	T.no(ns.Census.IsReporter())
	local sent = Spy(member)
	local before = ns.Roster.scannedAt
	T.ok(ns.Refresh.Run(false))
	T.ok(ns.Refresh.Busy())
	T.ok(ns.Activity.Running("roster"))
	T.eq(sent.Q1, nil, "сеть ждёт свежий ростер")
	w:Run(3)
	T.ok(ns.Roster.scannedAt > before, "ростер прочитан")
	T.eq(sent.Q1, 1, "репортёра спросили")
	w:Run(60)
	T.no(ns.Refresh.Busy(), "обновление закончилось")
	T.no(ns.Activity.Running("census"))
	T.no(ns.Activity.Running("relays"))
	T.eq(sent.Q1, 1, "ровно один запрос")
	Errors(member)
end)

T.test("refresh: итог называет ответ репортёра", function()
	local w, c = Network()
	local _, member = Roles(c)
	local notes = Notes(member)
	T.ok(member.ns.Refresh.Run(false))
	w:Run(60)
	T.eq(#notes, 1, "итог один")
	T.eq(notes[1], member.ns.L.REFRESH_DONE)
end)

T.test("refresh: повтор раньше Q1_GAP говорит, что отчёты не запрошены", function()
	local w, c = Network()
	local _, member = Roles(c)
	local ns, L = member.ns, member.ns.L
	local sent, notes = Spy(member), Notes(member)
	T.ok(ns.Refresh.Run(false))
	w:Run(ns.Config.REFRESH_GAP + 20)
	T.eq(notes[1], L.REFRESH_DONE, "первый запуск спросил репортёра")
	T.ok(ns.Refresh.Run(false))
	w:Run(40)
	T.eq(sent.Q1, 1, "второго запроса нет")
	T.ok(notes[2]:find("^Ростер обновлён, отчёты — через %d+ с$"), notes[2])
	member.ns.UI.Toggle("settings")
	local tip = Tip(member, member.ns.UI.refreshButton)
	T.ok(tip:find("Отчёты можно запросить через", 1, true), tip)
	w:Run(ns.Census.RefreshWait() + 1)
	T.eq(ns.Census.RefreshWait(), 0)
	T.no(Tip(member, member.ns.UI.refreshButton):find("Отчёты можно запросить", 1, true), "срок прошёл")
	T.ok(ns.Refresh.Run(false))
	w:Run(60)
	T.eq(sent.Q1, 2, "интервал прошёл — снова спрашиваем")
	T.eq(notes[3], L.REFRESH_DONE)
	Errors(member)
end)

T.test("refresh: отчёт не ушёл в подпись — итог об этом, интервал не тратится", function()
	local w, c = Network()
	local reporter = Roles(c)
	local ns = reporter.ns
	ns.Security.Seal = function() return false, "nocert" end
	w:Run(11) -- идущая подпись закончилась, следующая проверка отчёта получила отказ
	local notes = Notes(reporter)
	T.ok(ns.Refresh.Run(false))
	w:Run(40)
	T.no(ns.Refresh.Busy())
	T.eq(notes[1], ns.L.REFRESH_NO_SEAL)
	T.eq(ns.Census.RefreshWait(), 0, "отчёта не было — интервал не начался")
	Errors(reporter)
end)

T.test("refresh: интервал и шлюз запроса отчётов держат сеть", function()
	local w, c = Network()
	local _, member = Roles(c)
	local ns = member.ns
	local sent = Spy(member)
	T.ok(ns.Refresh.Run(false))
	local again, why = ns.Refresh.Run(false)
	T.eq(again, false)
	T.eq(why, "busy", "пока идёт — не запускается")
	w:Run(ns.Config.REFRESH_GAP + 20)
	T.no(ns.Refresh.Busy())
	T.ok(ns.Refresh.Run(false), "после интервала можно")
	w:Run(ns.Config.REFRESH_GAP - 5)
	T.eq(sent.Q1, 1, "второй Q1 раньше Q1_GAP не уходит")
	T.ok(ns.Refresh.Wait() > 0)
	local soon, reason = ns.Refresh.Run(false)
	T.eq(soon, false)
	T.eq(reason, "wait", "интервал ещё не прошёл")
	Errors(member)
end)

T.test("refresh: команда говорит, почему не запустилась", function()
	local w, c = Solo()
	w:Run(70) -- запросы отчётов после входа уже закончились и не продлят ожидание
	c:Slash("/chillzone", "refresh")
	T.eq(c:Saw(c.ns.L.REFRESH_STARTED), 1)
	c:Slash("/chillzone", "refresh")
	T.eq(c:Saw(c.ns.L.REFRESH_ALREADY), 1)
	w:Run(c.ns.Config.CENSUS_WAIT + 10)
	T.no(c.ns.Refresh.Busy())
	local finished = 0
	for _, text in ipairs({ c.ns.L.REFRESH_DONE, c.ns.L.REFRESH_NO_REPORTS, c.ns.L.REFRESH_NO_RELAYS, c.ns.L.REFRESH_NO_SEAL }) do
		finished = finished + c:Saw(text)
	end
	T.eq(finished, 1, "итог в чат при запуске командой")
	Errors(c)
end)

T.test("refresh: из окна итог в чат не печатается", function()
	local w, c = Solo()
	w:Run(70)
	T.ok(c.ns.Refresh.Run(false))
	w:Run(c.ns.Config.CENSUS_WAIT + 10)
	T.no(c.ns.Refresh.Busy())
	T.eq(c:Saw(c.ns.L.REFRESH_DONE) + c:Saw(c.ns.L.REFRESH_NO_REPORTS) + c:Saw(c.ns.L.REFRESH_NO_SEAL), 0)
end)

T.test("refresh: репортёр публикует отчёт сам и Q1 не шлёт", function()
	local w, c = Network()
	local reporter = Roles(c)
	local ns = reporter.ns
	local sent, reports = Spy(reporter), 0
	local out = ns.Relay.Out
	ns.Relay.Out = function(mode, raw)
		if mode == "L" then reports = reports + 1 end
		return out(mode, raw)
	end
	T.ok(ns.Refresh.Run(false))
	w:Run(40)
	T.no(ns.Refresh.Busy())
	T.eq(sent.Q1, nil, "репортёр никого не спрашивает")
	T.ok(reports >= 1, "отчёт ушёл по реле")
	Errors(reporter)
end)

T.test("refresh: мёртвое реле не воскрешается и не задерживает чат", function()
	local w, c = Network()
	local reporter, member = Roles(c)
	local ns = member.ns
	-- Вышли все: сообщение реле или пересланный репортёром сертификат сняли бы отметку законно.
	c.A:Logout()
	c.K:Logout()
	reporter:Logout()
	w:Run(ns.Relay.REG_TTL)
	local until_ = ns.Now() + 500
	local count = 0
	for _, e in pairs(ns.Relay.Known()) do
		e.down, e.asked, count = until_, nil, count + 1
	end
	T.ok(count > 0, "реле известны")
	local sent = Spy(member)
	T.ok(ns.Refresh.Run(false))
	w:Run(5)
	T.eq(sent.RP, nil, "мёртвых не опрашиваем")
	for _, e in pairs(ns.Relay.Known()) do T.eq(e.down, until_, "отметка «офлайн» сохранена") end
	T.no(ns.Activity.Running("relays"))
	Errors(member)
end)

T.test("refresh: глава запрашивает заявки, рядовой — нет", function()
	local w, officer = Solo()
	w:Run(50) -- прошёл интервал запросов JQ после входа
	local sent = Spy(officer)
	T.ok(officer.ns.Refresh.Run(false))
	w:Run(45)
	T.eq(sent.JQ, 1, "глава спросил офицеров")
	Errors(officer)

	local w2, member = Solo({ rank = 3 })
	w2:Run(10)
	local sent2 = Spy(member)
	T.ok(member.ns.Refresh.Run(false))
	w2:Run(45)
	T.eq(sent2.JQ, nil, "рядовому общая очередь не положена")
	Errors(member)
end)

T.test("refresh: смена гильдии закрывает ожидание", function()
	local w, c = Solo()
	w:Run(10)
	T.ok(c.ns.Refresh.Run(false))
	T.ok(c.ns.Activity.Running("roster"))
	c.ns.Fire("GUILD_CHANGED")
	T.no(c.ns.Refresh.Busy())
	T.no(c.ns.Activity.Running("roster"))
	w:Run(40)
	T.eq(c.ns.Activity.LastNote(), nil, "итога прерванного запуска нет")
	Errors(c)
end)

---------------------------------------------------------------------------
-- Окно
---------------------------------------------------------------------------
T.test("activity: окно, кнопка показывает ход, интервал и возвращается", function()
	local w, c = Solo()
	w:Run(10)
	c.ns.UI.Toggle("settings")
	local UI, L, A = c.ns.UI, c.ns.L, c.ns.Activity
	local b = UI.refreshButton
	Tick(c)
	T.ok(b:IsShown())
	T.eq(b:GetText(), L.REFRESH)
	T.eq(b.enabled, true)
	b:Click()
	T.eq(b.enabled, false, "пока идёт — нажать нельзя")
	T.eq(b:GetText(), L.REFRESH_BUSY)
	T.ok(UI.activity:IsShown())
	T.eq(UI.activity.text:GetText(), L.ACT_ROSTER)
	w:Run(3)
	for _, id in ipairs({ "census", "report", "relays", "requests" }) do A.Finish(id) end
	T.no(c.ns.Refresh.Busy())
	Tick(c)
	T.ok(b:GetText():find("^Обновить %(%d+%)$"), "обратный отсчёт: " .. b:GetText())
	T.eq(b.enabled, false)
	T.eq(UI.activity.text:GetText(), L.REFRESH_DONE, "итог виден")
	w:Run(c.ns.Config.REFRESH_GAP + 1)
	Tick(c)
	T.eq(b:GetText(), L.REFRESH)
	T.eq(b.enabled, true)
	Errors(c)
end)

T.test("activity: окно, вне гильдии кнопки нет, а поиск виден в индикаторе", function()
	local w, c = Homeless()
	w:Run(10)
	c.ns.UI.Toggle("join")
	Tick(c)
	local UI, L, Pane = c.ns.UI, c.ns.L, c.ns.RecruitPane
	T.no(UI.refreshButton:IsShown())
	local search = Pane.frames.search
	T.eq(search:GetText(), L.RECRUIT_SEARCH)
	T.eq(search.enabled, true)
	search:Click()
	T.eq(search.enabled, false, "ответа ещё нет")
	T.eq(search:GetText(), L.RECRUIT_SEARCHING)
	Tick(c)
	T.eq(UI.activity.text:GetText(), L.ACT_WHO)
	w:Run(c.ns.Who.TIMEOUT + 1)
	Tick(c)
	T.ok(search:GetText():find("^Найти гильдии %(%d+%)$"), "обратный отсчёт: " .. search:GetText())
	T.eq(search.enabled, false)
	w:Run(c.ns.Who.LATE + 1)
	Tick(c)
	T.eq(search:GetText(), L.RECRUIT_SEARCH)
	T.eq(search.enabled, true)
	Errors(c)
end)

T.test("activity: окно, подсказки называют работу и свежесть данных", function()
	local w, c = Solo()
	w:Run(10)
	c.ns.UI.Toggle("settings")
	local UI, L = c.ns.UI, c.ns.L
	Tick(c)
	c.ns.Activity.Start("x", "Важное ожидание", 30)
	Tick(c)
	local tip = Tip(c, UI.activity)
	T.ok(tip:find("Важное ожидание", 1, true), tip)
	T.ok(tip:find("Ростер:", 1, true), tip)
	T.ok(tip:find("Реле отвечают:", 1, true), tip)
	c.ns.Activity.Finish("x")
	local button = Tip(c, UI.refreshButton)
	T.ok(button:find(L.REFRESH_TIP, 1, true), button)
	Errors(c)
end)

T.test("activity: окно, пульс только у ожидания, красная точка неподвижна", function()
	local w, c = Solo()
	w:Run(10)
	c.ns.UI.Toggle("settings")
	local UI = c.ns.UI
	local alpha
	UI.activity.dot.SetAlpha = function(_, a) alpha = a end
	c.ns.Activity.Start("x", "Жду", 30)
	Tick(c)
	T.ok(alpha >= 0.45 and alpha <= 1, "альфа в пределах пульса")
	c.ns.Activity.Finish("x")
	c.ns.Activity.Start("x", "Мешает", 30, "block")
	Tick(c)
	T.eq(alpha, 1)
	Errors(c)
end)

T.test("activity: перепись, пустой список отличает запрос от отсутствия данных", function()
	local w, c = Solo({ rank = 3 })
	w:Run(5)
	c.ns.UI.Toggle("census")
	local L, empty = c.ns.L, c.ns.CensusPane.empty
	T.eq(empty:GetText(), L.CENSUS_EMPTY)
	c.ns.Activity.Start("census", L.ACT_CENSUS, 30)
	Tick(c)
	T.eq(empty:GetText(), L.CENSUS_LOADING, "пока ждём ответ")
	c.ns.Activity.Finish("census", false)
	Tick(c)
	T.eq(empty:GetText(), L.CENSUS_EMPTY, "ответа не было")
	Errors(c)
end)
