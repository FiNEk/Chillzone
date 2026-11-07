-- Chillzone: профайлер для игроков, у которых с аддоном подтормаживает игра.
-- /chillzone perf on — включить (остаётся включённым и после /reload), off — выключить,
-- reset — стереть замеры, без аргумента — отчёт в окне копирования.
--
-- Выключенный не стоит ничего: ns.SafeCall — тот, что в Core.lua, ни обёртки, ни OnUpdate, в
-- сохранённые данные ничего не пишется. Включённый подменяет ns.SafeCall обёрткой, которая
-- меряет вызов по debugprofilestop. Через ns.SafeCall идут события, подписчики шины, таймеры,
-- команды, приём сообщений и щелчки, так что видно почти всё. Время вызова включает вложенные
-- вызовы; собственная работа профайлера внутри внешнего вызова из его времени вычтена. По
-- метке хранятся число вызовов, сумма и самый долгий; отдельно — 20 самых долгих вызовов и
-- кадры, где аддон занял FRAME_MS и больше (своё OnUpdate складывает вызовы верхнего уровня
-- между двумя кадрами). Проверка подписей Ed25519 идёт кусками по кадру мимо ns.SafeCall:
-- её профайлер меряет, подменяя публичное поле Ed.after (libs/ не правятся).
-- Метка хранится без того, что меняется от вызова к вызову: у команды — только её имя, после
-- «|» — ничего, числа от двух цифр — «#». Имён игроков и набранного текста в метках нет.
-- По образцу Olympus Perf.lua (MIT, см. THIRD_PARTY.md), без памяти и подписчиков по номерам.
local ADDON, ns = ...

local L = ns.L

local Perf = {}
ns.Perf = Perf

Perf.FRAME_MS = 20    -- кадр, где аддон занял столько, считается тяжёлым
Perf.SLOW_KEEP = 20   -- самых долгих вызовов
Perf.WORST_KEEP = 10  -- худших кадров
Perf.MAX_LABELS = 300 -- меток; следующие идут в «прочее»
Perf.LABEL_MAX = 60   -- длина метки в байтах
Perf.TOP = 25         -- строк «больше всего времени» в отчёте
Perf.ED = "ed25519"   -- метка кусков проверки подписей
Perf.OTHER = "(other)"

local on = false        -- меряем сейчас
local installed = false -- наша обёртка в цепочке ns.SafeCall
local inner             -- ns.SafeCall, который зовёт наша обёртка
local data              -- ns.db.perf, пока включено
local frame             -- свой фрейм для OnUpdate
local depth = 0         -- сколько измеряемых вызовов идёт сейчас (0 — верхний уровень)
local ownMs = 0         -- своё время профайлера внутри вызовов (только растёт)
local frameSum, frameTop, frameTopMs = 0, nil, 0
local edInner, edMine   -- Ed.after, который зовёт наш, и наш

local function Clock() return debugprofilestop() end

-- Метка без данных: см. шапку.
function Perf.Label(s)
	s = tostring(s or "?")
	local cmd = s:match("^/chillzone%s+(%S*)")
	if cmd then s = "/chillzone " .. cmd:lower() end
	s = s:gsub("|.*$", ""):gsub("%d%d+", "#"):gsub("%s+$", "")
	if #s > Perf.LABEL_MAX then
		local cut = Perf.LABEL_MAX
		-- Не резать посреди буквы: байты 0x80-0xBF продолжают её.
		while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
		s = s:sub(1, cut)
	end
	return s
end

local function Fresh()
	return { on = false, stats = {}, slow = {}, worst = {}, frames = 0, heavy = 0, measured = 0, labels = 0, since = ns.Stamp() }
end

-- ns.db.perf с полями по умолчанию; после /reload — то, что замерено до него.
local function Data()
	local d = ns.db.perf
	if type(d) ~= "table" then
		d = Fresh()
		ns.db.perf = d
	end
	for k, v in pairs(Fresh()) do
		if type(d[k]) ~= type(v) then d[k] = v end
	end
	local n = 0
	for _ in pairs(d.stats) do n = n + 1 end
	d.labels = n
	return d
end

-- Вставка в список, отсортированный по убыванию ms, не длиннее keep.
local function Keep(list, item, keep)
	if #list >= keep and item.ms <= list[#list].ms then return end
	local i = #list + 1
	while i > 1 and list[i - 1].ms < item.ms do i = i - 1 end
	table.insert(list, i, item)
	while #list > keep do table.remove(list) end
end

local function Record(label, dt)
	if dt < 0 then dt = 0 end
	local key = label == Perf.ED and label or Perf.Label(label)
	local s = data.stats[key]
	if not s then
		if data.labels >= Perf.MAX_LABELS then
			key = Perf.OTHER
			s = data.stats[key]
		end
		if not s then
			s = { n = 0, total = 0, max = 0 }
			data.stats[key] = s
			data.labels = data.labels + 1
		end
	end
	s.n = s.n + 1
	s.total = s.total + dt
	if dt > s.max then s.max = dt end
	Keep(data.slow, { label = key, ms = dt, at = ns.Stamp() }, Perf.SLOW_KEEP)
	if depth == 0 then
		frameSum = frameSum + dt
		if dt > frameTopMs then frameTop, frameTopMs = key, dt end
	end
end

-- После измеренного вызова: записать, а время записи вычесть из внешнего вызова.
local function Done(label, t0, t1, own0)
	if not on then return end
	local fine, err = pcall(Record, label, t1 - t0 - (ownMs - own0))
	if depth > 0 then ownMs = ownMs + (Clock() - t1) end
	if not fine then
		-- Сбой профайлера не ломает измеренный вызов: профайлер выключается и пишет почему.
		Perf.Stop()
		if ns.CaptureError then ns.CaptureError("perf", err) end
	end
end

local function Timed(where, fn, ...)
	if not on then return inner(where, fn, ...) end
	depth = depth + 1
	local own0 = ownMs
	local t0 = Clock()
	local ok = inner(where, fn, ...)
	local t1 = Clock()
	depth = depth - 1
	Done(where, t0, t1, own0)
	return ok
end

-- Кусок проверки подписи (Ed.after(Step)): своя строка в отчёте.
local function EdWrap(fn)
	return edInner(function()
		if not on then return fn() end
		depth = depth + 1
		local own0 = ownMs
		local t0 = Clock()
		local ok, err = pcall(fn)
		local t1 = Clock()
		depth = depth - 1
		Done(Perf.ED, t0, t1, own0)
		if not ok and ns.CaptureError then ns.CaptureError(Perf.ED, err) end
	end)
end

local function WrapEd()
	local Ed = ns.Ed25519
	if not Ed or edMine or type(Ed.after) ~= "function" then return end
	edInner, edMine = Ed.after, EdWrap
	Ed.after = edMine
end

local function UnwrapEd()
	local Ed = ns.Ed25519
	if Ed and edMine and Ed.after == edMine then Ed.after = edInner end
	edInner, edMine = nil, nil
end

-- Конец кадра: сумма вызовов верхнего уровня с прошлого кадра.
local function FrameDone(_, elapsed)
	if not on then return end
	data.frames = data.frames + 1
	data.measured = data.measured + (tonumber(elapsed) or 0)
	if frameSum >= Perf.FRAME_MS then
		data.heavy = data.heavy + 1
		Keep(data.worst, { ms = frameSum, top = frameTop, topMs = frameTopMs, at = ns.Stamp() }, Perf.WORST_KEEP)
	end
	frameSum, frameTop, frameTopMs = 0, nil, 0
end

function Perf.On() return on end

function Perf.Start()
	if on or not ns.db then return end
	data = Data()
	data.on = true
	if not installed then
		inner = ns.SafeCall
		ns.SafeCall = Timed
		installed = true
	end
	depth, ownMs = 0, 0
	frameSum, frameTop, frameTopMs = 0, nil, 0
	on = true
	frame = frame or CreateFrame("Frame")
	Perf.frame = frame
	frame:SetScript("OnUpdate", FrameDone)
	WrapEd()
end

-- Выключить: ns.SafeCall снова свой (если поверх нашей обёртки никто не обернул — тогда
-- она остаётся в цепочке и только передаёт вызовы), OnUpdate снят. Намеренное остаётся.
function Perf.Stop()
	if ns.db and type(ns.db.perf) == "table" then ns.db.perf.on = false end
	if not on then return end
	on = false
	if installed and ns.SafeCall == Timed then
		ns.SafeCall = inner
		installed = false
	end
	if frame then frame:SetScript("OnUpdate", nil) end
	UnwrapEd()
end

function Perf.Reset()
	if not ns.db then return end
	ns.db.perf = Fresh()
	ns.db.perf.on = on
	if on then data = ns.db.perf end
	frameSum, frameTop, frameTopMs = 0, nil, 0
end

local function Ms(v)
	return ("%.2f"):format(tonumber(v) or 0)
end

-- Отчёт текстом.
function Perf.Text()
	local d = type(ns.db and ns.db.perf) == "table" and ns.db.perf or nil
	local out = {}
	local function add(s) out[#out + 1] = s end
	add(L.PERF_HEAD:format(tostring(ns.VERSION), on and L.PERF_STATE_ON or L.PERF_STATE_OFF, ns.Stamp()))
	if not d then
		add(L.PERF_EMPTY)
		return table.concat(out, "\n")
	end
	add(L.PERF_SPAN:format(tostring(d.since or "?"), ("%.0f"):format(d.measured or 0), d.frames or 0, d.heavy or 0, Perf.FRAME_MS))
	local list, total = {}, 0
	for label, s in pairs(d.stats or {}) do
		list[#list + 1] = { label = label, s = s }
		total = total + (s.total or 0)
	end
	table.sort(list, function(a, b) return a.s.total > b.s.total or (a.s.total == b.s.total and a.label < b.label) end)
	add("")
	add(L.PERF_TOP:format(#list, Ms(total)))
	if #list == 0 then add("  " .. L.PERF_NONE) end
	for i = 1, math.min(#list, Perf.TOP) do
		local x = list[i]
		add(("  %s ms  %sx  max %s  avg %s  %s"):format(Ms(x.s.total), x.s.n, Ms(x.s.max), Ms(x.s.total / math.max(1, x.s.n)), x.label))
	end
	add("")
	add(L.PERF_SLOW)
	if #(d.slow or {}) == 0 then add("  " .. L.PERF_NONE) end
	for _, x in ipairs(d.slow or {}) do
		add(("  %s ms  %s  (%s)"):format(Ms(x.ms), tostring(x.label), tostring(x.at)))
	end
	add("")
	add(L.PERF_WORST)
	if #(d.worst or {}) == 0 then add("  " .. L.PERF_NONE) end
	for _, x in ipairs(d.worst or {}) do
		add(("  %s ms  %s %s ms  (%s)"):format(Ms(x.ms), tostring(x.top or "?"), Ms(x.topMs), tostring(x.at)))
	end
	return table.concat(out, "\n")
end

function Perf.Show()
	return ns.UI.ShowCopy(L.PERF_TITLE, Perf.Text())
end

ns.Command("perf", function(arg)
	arg = (arg or ""):lower():match("^%s*(%S*)")
	if arg == "on" then
		Perf.Start()
		ns.Print(L.PERF_ON:format(Perf.FRAME_MS))
	elseif arg == "off" then
		Perf.Stop()
		ns.Print(L.PERF_OFF)
	elseif arg == "reset" then
		Perf.Reset()
		ns.Print(L.PERF_RESET)
	else
		Perf.Show()
	end
end, L.HELP_PERF)

-- После /reload профайлер включается снова, если был включён.
ns.On("INIT", function()
	if type(ns.db.perf) == "table" and ns.db.perf.on then Perf.Start() end
end)
