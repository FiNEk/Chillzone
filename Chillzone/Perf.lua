-- Замер производительности по запросу: /chillzone perf или кнопка на вкладке «Журнал».
-- Пока запись выключена, ns.SafeCall обычный, а цена обёрток Perf.Wrap — одна проверка флага.
-- Запись подменяет ns.SafeCall: через него идут события игры, таймеры, шина и приём сообщений,
-- и у каждого вызова уже есть метка. Постоянные OnUpdate, фильтры чата и шаг криптографии идут
-- мимо него, поэтому они обёрнуты отдельно. Сторонние библиотеки из libs/ здесь не видны.
--
-- Вызовы вложены: событие зовёт шину, шина зовёт подписчиков. У каждого считается своё время
-- без вложенных, поэтому сумма по меткам равна нашему времени в кадре, ничего не считается дважды.
--
-- Средний расход статтеры не объясняет, поэтому главный результат — длинные кадры: сколько длился
-- кадр, сколько в нём заняли мы и какие метки. Сборщик мусора общий для всех аддонов, наш мусор
-- может притормозить чужой кадр, поэтому отдельно считаются выделенная и освобождённая память.
local ADDON, ns = ...
local L = ns.L

local Perf = {
	HITCH_MS = 50,     -- кадр короче этого рывком не считается
	HITCH_FACTOR = 2,  -- рывок ещё и во столько раз длиннее обычного кадра
	HEAVY_MS = 16,     -- кадр с таким нашим временем запоминается и без рывка
	OURS_SHARE = 0.25, -- с такой доли кадра рывок считается нашим
	LOADING_S = 5,     -- кадр длиннее этого — экран загрузки
	KEEP_WORST = 20,   -- сколько худших кадров хранить
	KEEP_TIMES = 120,  -- сколько последних отметок времени рывков хранить
	TOP_LABELS = 3,    -- сколько меток показывать у кадра
	REPORT_LABELS = 20, -- сколько меток в каждом списке отчёта
}
ns.Perf = Perf

local floor, max, min = math.floor, math.max, math.min

local active, skipFrame = false, false
local session, plainSafeCall, plainAfter, tickFrame
local depth, childMs, childKb = 0, {}, {}
local frameOurs, frameKb, frameLabels, lastMemory, lastTick = 0, 0, {}, 0, 0

local function NewSession()
	return {
		startedAt = ns.Now(), stats = {}, frames = 0, frameMs = 0, oursMs = 0, oursKb = 0, peakFrame = 0,
		over5 = 0, over16 = 0, over50 = 0, hitches = 0, ourHitches = 0, worst = {}, times = {},
	}
end

local function Begin()
	depth = depth + 1
	childMs[depth], childKb[depth] = 0, 0
end

-- Другой аддон может сбросить общий таймер (debugprofilestart), а сборщик мусора — уменьшить
-- память посреди вызова, поэтому отрицательные разности считаются нулём.
local function Finish(where, startedAt, memory)
	local ms = max(0, debugprofilestop() - startedAt)
	local kb = max(0, collectgarbage("count") - memory)
	local own, ownKb = max(0, ms - childMs[depth]), max(0, kb - childKb[depth])
	depth = depth - 1
	if depth > 0 then
		childMs[depth], childKb[depth] = childMs[depth] + ms, childKb[depth] + kb
	else
		frameOurs, frameKb = frameOurs + ms, frameKb + kb
	end
	local st = session.stats[where]
	if not st then
		st = { n = 0, ms = 0, max = 0, over5 = 0, over16 = 0, kb = 0 }
		session.stats[where] = st
	end
	st.n, st.ms, st.kb = st.n + 1, st.ms + own, st.kb + ownKb
	if own > st.max then st.max = own end
	if own > 5 then st.over5 = st.over5 + 1 end
	if own > 16 then st.over16 = st.over16 + 1 end
	frameLabels[where] = (frameLabels[where] or 0) + own
end

-- Сначала память, потом часы, а на выходе наоборот: сам замер не попадает в измеренное время.
local function MeasuredSafeCall(where, fn, ...)
	Begin()
	local memory, startedAt = collectgarbage("count"), debugprofilestop()
	local ok = plainSafeCall(where, fn, ...)
	Finish(where, startedAt, memory)
	return ok
end

local function Done(where, startedAt, memory, ok, ...)
	Finish(where, startedAt, memory)
	if not ok then error((...), 0) end
	return ...
end

local function Measure(where, fn, ...)
	Begin()
	local memory, startedAt = collectgarbage("count"), debugprofilestop()
	return Done(where, startedAt, memory, pcall(fn, ...))
end

-- Обёртка для обработчика вне ns.SafeCall. Ошибки и возвращаемые значения передаются как есть.
function Perf.Wrap(where, fn)
	return function(...)
		if not active then return fn(...) end
		return Measure(where, fn, ...)
	end
end

local stepFn, stepWrapped
local function MeasuredAfter(fn)
	if fn ~= stepFn then stepFn, stepWrapped = fn, Perf.Wrap("crypto slice", fn) end
	return plainAfter(stepWrapped)
end

local function Worse(a, b)
	if a.ours ~= b.ours then return a.ours > b.ours end
	return a.ms > b.ms
end

local function TopLabels()
	local list = {}
	for where, ms in pairs(frameLabels) do list[#list + 1] = { where = where, ms = ms } end
	table.sort(list, function(a, b)
		if a.ms ~= b.ms then return a.ms > b.ms end
		return a.where < b.where
	end)
	for i = #list, Perf.TOP_LABELS + 1, -1 do list[i] = nil end
	return list
end

local function Remember(s, record)
	local worst = s.worst
	if #worst >= Perf.KEEP_WORST and not Worse(record, worst[#worst]) then return end
	record.labels = TopLabels()
	worst[#worst + 1] = record
	table.sort(worst, Worse)
	worst[Perf.KEEP_WORST + 1] = nil
end

local function EndFrame(ms)
	local s = session
	local ours, kb = frameOurs, frameKb
	local memory = collectgarbage("count")
	local freed = max(0, lastMemory - memory)
	frameOurs, frameKb, lastMemory = 0, 0, memory
	s.frames, s.frameMs = s.frames + 1, s.frameMs + ms
	s.oursMs, s.oursKb = s.oursMs + ours, s.oursKb + kb
	if ours > s.peakFrame then s.peakFrame = ours end
	if ours > 5 then s.over5 = s.over5 + 1 end
	if ours > 16 then s.over16 = s.over16 + 1 end
	if ours > 50 then s.over50 = s.over50 + 1 end
	-- Обычная длина кадра следует за игрой (в рейде кадры дольше всегда), а отдельный рывок
	-- сдвигает её мало: вклад кадра ограничен четырьмя обычными.
	local baseline = s.baseline or ms
	local hitch = ms >= max(Perf.HITCH_MS, baseline * Perf.HITCH_FACTOR)
	s.baseline = baseline + (min(ms, baseline * 4) - baseline) * 0.02
	if not hitch and ours < Perf.HEAVY_MS then return end
	local at = floor(ns.Now() - s.startedAt)
	if hitch then
		s.hitches = s.hitches + 1
		if ours >= ms * Perf.OURS_SHARE then s.ourHitches = s.ourHitches + 1 end
		s.times[#s.times + 1] = at
		if #s.times > Perf.KEEP_TIMES then table.remove(s.times, 1) end
	end
	Remember(s, { at = at, ms = ms, ours = ours, kb = kb, freed = freed,
		combat = InCombatLockdown() and true or false, tab = ns.UI and ns.UI.Current() or nil })
end

-- Один вызов на кадр. Длину кадра считаем сами: игра измеряет elapsed в начале кадра, до событий,
-- и наша работа попала бы только в elapsed следующего кадра, рывок достался бы кадру без нашей
-- работы. Промежуток между двумя вызовами всегда содержит всё, что мы сделали между ними.
-- Другой аддон может сбросить общий таймер (debugprofilestart): тогда разность не больше нуля
-- и остаётся elapsed.
function Perf.Tick(elapsed)
	local now = debugprofilestop()
	local ms = now - lastTick
	lastTick = now
	if ms <= 0 then ms = elapsed * 1000 end
	-- Первый кадр записи начался до её включения.
	if skipFrame or ms >= Perf.LOADING_S * 1000 or elapsed >= Perf.LOADING_S then
		skipFrame, frameOurs, frameKb, lastMemory = false, 0, 0, collectgarbage("count")
	else
		EndFrame(ms)
	end
	if next(frameLabels) then wipe(frameLabels) end
end

function Perf.Enabled() return active end

function Perf.Session() return session end

local function Duration(s)
	return max(0, (s.stoppedAt or ns.Now()) - s.startedAt)
end

function Perf.Start()
	if active then return true end
	if type(debugprofilestop) ~= "function" then
		ns.Log(L.PERF_UNAVAILABLE)
		return false
	end
	session = NewSession()
	frameOurs, frameKb, lastMemory, skipFrame, lastTick = 0, 0, collectgarbage("count"), true, debugprofilestop()
	wipe(frameLabels)
	plainSafeCall, ns.SafeCall = ns.SafeCall, MeasuredSafeCall
	local Ed = ns.Ed25519
	if Ed then plainAfter, Ed.after = Ed.after, MeasuredAfter end
	if not tickFrame then
		tickFrame = CreateFrame("Frame")
		tickFrame:SetScript("OnUpdate", function(_, elapsed) plainSafeCall("perf tick", Perf.Tick, elapsed) end)
	end
	tickFrame:Show()
	active = true
	ns.Log(L.PERF_ON)
	return true
end

function Perf.Stop()
	if not active then return end
	active = false
	ns.SafeCall = plainSafeCall
	if ns.Ed25519 then ns.Ed25519.after = plainAfter end
	tickFrame:Hide()
	local s = session
	s.stoppedAt = ns.Now()
	ns.Log(L.PERF_OFF, floor(Duration(s)), s.hitches, s.ourHitches, s.peakFrame)
end

function Perf.Toggle()
	if active then Perf.Stop() else Perf.Start() end
end

-- Завершённый замер уходит вместе с журналом. Идущий продолжается.
function Perf.Clear()
	if not active then session = nil end
end

local function YesNo(value) return value and L.YES or L.NO end

local function Ranked(field)
	local list = {}
	for where, st in pairs(session.stats) do list[#list + 1] = { where = where, st = st } end
	table.sort(list, function(a, b)
		if a.st[field] ~= b.st[field] then return a.st[field] > b.st[field] end
		return a.where < b.where
	end)
	return list
end

local function AddLabels(lines, title, field)
	local list = Ranked(field)
	if #list == 0 then return end
	lines[#lines + 1] = title
	for i = 1, min(#list, Perf.REPORT_LABELS) do
		local where, st = list[i].where, list[i].st
		lines[#lines + 1] = L.PERF_LABEL:format(where, st.n, st.ms, st.ms / st.n, st.max, st.over5, st.over16, st.kb)
	end
end

-- Текст для отчёта журнала или nil, если замера не было.
function Perf.Report()
	local s = session
	if not s then return nil end
	local seconds = Duration(s)
	local lines = {
		L.PERF_HEADER:format(active and L.PERF_RUNNING or L.PERF_STOPPED, floor(seconds), s.frames,
			s.frames > 0 and s.frameMs / s.frames or 0),
		L.PERF_CONTEXT:format(#(ns.Roster.members or {}), YesNo(ns.Census.IsReporter()), YesNo(ns.Relay.IAmRelay()),
			ns.UI.Current() or L.PERF_NO_TAB),
		L.PERF_OURS:format(s.oursMs, s.frameMs > 0 and 100 * s.oursMs / s.frameMs or 0, s.peakFrame, s.over5, s.over16, s.over50),
		L.PERF_MEMORY:format(s.oursKb, seconds > 0 and s.oursKb / seconds or 0, collectgarbage("count")),
		L.PERF_HITCHES:format(Perf.HITCH_MS, s.hitches, floor(Perf.OURS_SHARE * 100 + 0.5), s.ourHitches),
	}
	if #s.times > 0 then lines[#lines + 1] = L.PERF_TIMES .. table.concat(s.times, " ") end
	if #s.worst > 0 then
		lines[#lines + 1] = L.PERF_WORST
		for _, r in ipairs(s.worst) do
			local parts = {}
			for i, label in ipairs(r.labels) do parts[i] = ("%s %.1f"):format(label.where, label.ms) end
			lines[#lines + 1] = L.PERF_WORST_LINE:format(r.at, r.ms, r.ours, r.kb, r.freed, YesNo(r.combat),
				r.tab or L.PERF_NO_TAB, table.concat(parts, ", "))
		end
	end
	AddLabels(lines, L.PERF_BY_MAX, "max")
	AddLabels(lines, L.PERF_BY_TOTAL, "ms")
	return table.concat(lines, "\n")
end
