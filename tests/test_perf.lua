-- Замер производительности: своё время вложенных вызовов, длинные кадры, отчёт в журнале.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

-- Клиент с ручными часами и счётчиком памяти: результаты замера не зависят от машины.
local function Fresh()
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Замер", surname = "Кадров", guild = "Чиллзон", rank = 3 })
	w.now = 100
	local clock = { ms = 1000, kb = 5000 }
	c.env.debugprofilestop = function() return clock.ms end
	c.env.collectgarbage = function(opt) return opt == "count" and clock.kb or 0 end
	return w, c, clock
end

-- Включает запись и пропускает первый кадр: он начался ещё до включения.
local function Started(c)
	T.ok(c.ns.Perf.Start())
	c.ns.Perf.Tick(0.016)
	return c.ns.Perf
end

local function Work(clock, ms, kb)
	clock.ms = clock.ms + ms
	clock.kb = clock.kb + (kb or 0)
	clock.inFrame = (clock.inFrame or 0) + ms
end

-- Конец кадра длиной seconds: часы доходят до его конца, работа Work уже внутри кадра.
local function Frame(P, clock, seconds)
	clock.ms = clock.ms + seconds * 1000 - (clock.inFrame or 0)
	clock.inFrame = 0
	P.Tick(seconds)
end

T.test("perf: без записи обычные функции не подменены", function()
	local _, c = Fresh()
	local P, plain, after = c.ns.Perf, c.ns.SafeCall, c.ns.Ed25519.after
	T.no(P.Enabled())
	T.eq(P.Report(), nil)
	local calls = 0
	local wrapped = P.Wrap("метка", function(a, b) calls = calls + 1; return a + b, "готово" end)
	local sum, text = wrapped(2, 3)
	T.eq(sum, 5)
	T.eq(text, "готово")
	T.eq(calls, 1)
	P.Start()
	T.ok(c.ns.SafeCall ~= plain, "запись подменила SafeCall")
	T.ok(c.ns.Ed25519.after ~= after, "запись видит шаг криптографии")
	P.Stop()
	T.eq(c.ns.SafeCall, plain)
	T.eq(c.ns.Ed25519.after, after)
	T.no(P.Session().stats["метка"], "выключенная обёртка ничего не записала")
end)

T.test("perf: своё время и память не включают вложенные вызовы", function()
	local _, c, clock = Fresh()
	local P = Started(c)
	c.ns.SafeCall("внешний", function()
		Work(clock, 2, 10)
		c.ns.SafeCall("вложенный", function() Work(clock, 7, 30) end)
		Work(clock, 1, 5)
	end)
	local stats = P.Session().stats
	T.eq(stats["внешний"].ms, 3)
	T.eq(stats["внешний"].kb, 15)
	T.eq(stats["вложенный"].ms, 7)
	T.eq(stats["вложенный"].kb, 30)
	T.eq(stats["вложенный"].over5, 1)
	T.eq(stats["внешний"].over5, 0)
	P.Tick(0.016)
	T.eq(P.Session().oursMs, 10, "в кадр попадает только верхний вызов")
	T.eq(P.Session().oursKb, 45)
	T.eq(P.Session().peakFrame, 10)
end)

T.test("perf: ошибка обработчика не сбивает учёт вложенности", function()
	local _, c, clock = Fresh()
	local P = Started(c)
	T.no(c.ns.SafeCall("сбой", function() Work(clock, 4); error("сломалось") end))
	T.ok(c.ns.db.errors[1]:find("сломалось", 1, true), "ошибка сохранена, как без записи")
	local ok, err = pcall(P.Wrap("обёртка", function() Work(clock, 3); error("снаружи", 0) end))
	T.no(ok)
	T.eq(err, "снаружи", "обёртка передаёт ошибку дальше")
	c.ns.SafeCall("после", function() Work(clock, 2) end)
	T.eq(P.Session().stats["обёртка"].ms, 3)
	P.Tick(0.016)
	T.eq(P.Session().oursMs, 9, "все три вызова остались верхними")
end)

T.test("perf: рывок запоминает длину кадра, нашу долю и главные метки", function()
	local w, c, clock = Fresh()
	local P = Started(c)
	for _ = 1, 10 do P.Tick(0.016) end
	w.now = 130
	for i = 1, 5 do c.ns.SafeCall("метка " .. i, function() Work(clock, i * 2, 100) end) end
	clock.kb = clock.kb - 900 -- сборщик освободил больше, чем мы выделили
	Frame(P, clock, 0.1)
	local s = P.Session()
	T.eq(s.hitches, 1)
	T.eq(s.ourHitches, 1)
	local r = s.worst[1]
	T.eq(r.ms, 100)
	T.eq(r.ours, 30)
	T.eq(r.at, 30)
	T.eq(r.kb, 500)
	T.eq(r.freed, 400)
	T.eq(#r.labels, 3, "у кадра только главные метки")
	T.eq(r.labels[1].where, "метка 5")
	T.eq(r.labels[1].ms, 10)
	T.eq(s.times[1], 30)
	P.Tick(0.2)
	T.eq(s.hitches, 2)
	T.eq(s.ourHitches, 1, "кадр без нашей работы не наш")
	T.eq(s.worst[1].ours, 30, "первым остаётся кадр с наибольшей нашей долей")
	T.eq(#s.worst[2].labels, 0, "метки прошлого кадра сброшены")
end)

-- Игра считает elapsed до событий кадра, поэтому в отчёте шли пары «кадр 6 мс, наших 77 мс»
-- и следом «кадр 81 мс, наших 0.1 мс».
T.test("perf: рывок считается кадру, в котором была наша работа, а не следующему", function()
	local _, c, clock = Fresh()
	local P = Started(c)
	for _ = 1, 10 do Frame(P, clock, 0.006) end
	c.ns.SafeCall("тяжёлая", function() Work(clock, 77) end)
	clock.ms = clock.ms + 4 -- остаток кадра, а elapsed ещё про прошлый короткий кадр
	clock.inFrame = 0
	P.Tick(0.006)
	clock.ms = clock.ms + 6
	P.Tick(0.081)
	local s = P.Session()
	T.eq(s.hitches, 1, "короткий кадр после тяжёлого не рывок")
	T.eq(s.ourHitches, 1)
	T.eq(s.worst[1].ms, 81)
	T.eq(s.worst[1].ours, 77)
end)

T.test("perf: сброшенный общий таймер не портит длину кадра", function()
	local _, c, clock = Fresh()
	local P = Started(c)
	clock.ms = 5 -- другой аддон вызвал debugprofilestart
	P.Tick(0.02)
	T.eq(P.Session().frames, 1)
	T.eq(P.Session().frameMs, 20)
end)

T.test("perf: тяжёлый для нас кадр запоминается и без рывка", function()
	local _, c, clock = Fresh()
	local P = Started(c)
	for _ = 1, 10 do P.Tick(0.016) end
	c.ns.SafeCall("тяжёлая", function() Work(clock, P.HEAVY_MS) end)
	P.Tick(0.03)
	T.eq(P.Session().hitches, 0)
	T.eq(#P.Session().worst, 1)
	T.eq(P.Session().worst[1].labels[1].where, "тяжёлая")
end)

T.test("perf: постоянно долгие кадры перестают считаться рывками", function()
	local _, c = Fresh()
	local P = Started(c)
	for _ = 1, 10 do P.Tick(0.016) end
	for _ = 1, 150 do P.Tick(0.07) end
	local before = P.Session().hitches
	T.ok(before > 0, "сначала кадр 70 мс выделяется на фоне 16 мс")
	for _ = 1, 150 do P.Tick(0.07) end
	T.eq(P.Session().hitches, before)
end)

T.test("perf: хранится ограниченное число кадров и отметок времени", function()
	local _, c, clock = Fresh()
	local P = Started(c)
	for i = 1, P.KEEP_WORST + 10 do
		for _ = 1, 3 do P.Tick(0.016) end
		c.ns.SafeCall("кадр", function() Work(clock, i) end)
		Frame(P, clock, 0.2)
	end
	for _ = 1, P.KEEP_TIMES do
		for _ = 1, 3 do P.Tick(0.016) end
		P.Tick(0.2)
	end
	local s = P.Session()
	T.eq(#s.worst, P.KEEP_WORST)
	T.eq(s.worst[1].ours, P.KEEP_WORST + 10, "самый тяжёлый кадр не вытеснен")
	T.eq(#s.times, P.KEEP_TIMES)
end)

T.test("perf: экран загрузки и кадр до включения не считаются", function()
	local _, c, clock = Fresh()
	local P = c.ns.Perf
	P.Start()
	c.ns.SafeCall("до кадра", function() Work(clock, 40) end)
	P.Tick(0.5)
	P.Tick(0.016)
	P.Tick(P.LOADING_S + 1)
	local s = P.Session()
	T.eq(s.hitches, 0)
	T.eq(s.frames, 1)
	T.eq(s.oursMs, 0)
end)

T.test("perf: шаг криптографии и обработка результата измеряются отдельно", function()
	local w, c = Fresh()
	local P = Started(c)
	local done = false
	T.ok(c.ns.Security.Control.Job(function() return "готово" end, function(value) done = value end))
	w:Run(1)
	T.eq(done, "готово")
	local stats = P.Session().stats
	T.ok(stats["crypto slice"] and stats["crypto slice"].n >= 1, "шаг виден в записи")
	T.ok(stats["signature done"].n >= 1, "обработка результата видна отдельно")
end)

T.test("perf: ошибка обработки подписи сохраняется", function()
	local w, c = Fresh()
	T.ok(c.ns.Security.Control.Job(function() return true end, function() error("после подписи") end))
	w:Run(1)
	T.ok(c.ns.db.errors[1]:find("после подписи", 1, true))
end)

T.test("perf: фильтр чата и OnUpdate окна видны, результат фильтра не меняется", function()
	local _, c = Fresh()
	local filter = c.filters.CHAT_MSG_SYSTEM[1]
	local plain = { filter(nil, "CHAT_MSG_SYSTEM", "обычная строка") }
	local P = Started(c)
	T.same({ filter(nil, "CHAT_MSG_SYSTEM", "обычная строка") }, plain)
	T.eq(P.Session().stats["chat filter CHAT_MSG_SYSTEM"].n, 1)
	c.ns.UI.Toggle("journal")
	local pane = c.ns.JournalPane.frames.pane
	pane.scripts.OnUpdate(pane, 0.016)
	T.eq(P.Session().stats["journal update"].n, 1)
end)

T.test("perf: команда и кнопка управляют записью, отчёт попадает в журнал", function()
	local _, c, clock = Fresh()
	c:Slash("/chillzone", "perf")
	T.ok(c.ns.Perf.Enabled())
	T.eq(c.ns.UI.Current(), "journal")
	T.eq(c:Saw("замер"), 0, "команда не пишет в обычный чат")
	local f = c.ns.JournalPane.frames
	T.eq(f.perf:GetText(), c.ns.L.PERF_STOP)
	c.ns.Perf.Tick(0.016)
	for _ = 1, 5 do c.ns.Perf.Tick(0.016) end
	c.ns.SafeCall("метка отчёта", function() Work(clock, 60, 200) end)
	Frame(c.ns.Perf, clock, 0.15)
	f.perf:Click()
	T.no(c.ns.Perf.Enabled())
	T.eq(f.perf:GetText(), c.ns.L.PERF_START)
	T.ok(table.concat(c.ns.db.log, "\n"):find("рывков 1", 1, true), "итог записан в журнал")
	f.copy:Click()
	local report = f.box:GetText()
	T.ok(report:find(c.ns.L.PERF_STOPPED, 1, true))
	T.ok(report:find("кадр 150.0 мс, наших 60.0 мс", 1, true))
	T.ok(report:find("метка отчёта 60.0", 1, true))
	T.ok(report:find("метка отчёта: вызовов 1, всего 60.0 мс", 1, true))
	T.ok(report:find(c.ns.L.JOURNAL_EVENTS, 1, true), "отчёт журнала на месте")
	f.back:Click()
	f.clear:Click()
	T.eq(c.ns.Perf.Report(), nil, "очистка убирает завершённый замер")
	T.eq(#c.ns.db.errors, 0)
end)

T.test("perf: очистка журнала не прерывает идущий замер", function()
	local _, c = Fresh()
	local P = Started(c)
	c.ns.Diagnostics.Clear()
	T.ok(P.Enabled())
	T.ok(P.Report():find(c.ns.L.PERF_RUNNING, 1, true))
end)

T.test("perf: без точного таймера запись не включается", function()
	local _, c = Fresh()
	local plain = c.ns.SafeCall
	c.env.debugprofilestop = false
	T.no(c.ns.Perf.Start())
	T.no(c.ns.Perf.Enabled())
	T.eq(c.ns.SafeCall, plain)
end)
