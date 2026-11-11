-- Проверочный аддон tools/ChillzoneProbe (этап 0 плана «общий чат через канал игры»). В релиз
-- Chillzone он не входит, но игроки запускают его в игре: журнал должен честно показывать
-- отправку, эхо, приём и уведомления, а сам аддон — не ломаться и не оставлять лишних глобалов.
-- Симулятор не проверяет аппаратное событие, поэтому здесь проверяется только учёт.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)
local DIR = T.ROOT .. "/tools/ChillzoneProbe/"
local CHANNEL = "ChillzoneProbe"

local function TocFiles()
	local out = {}
	for line in T.read(DIR .. "ChillzoneProbe.toc"):gmatch("[^\r\n]+") do
		if not line:find("^##") and line:find("%S") then out[#out + 1] = (line:gsub("%s+$", "")) end
	end
	return out
end

-- Клиент с Chillzone из симулятора и проверочным аддоном поверх него.
local function Probe(world, opts, db)
	local c = world:Client(opts)
	c.env.ChillzoneProbeDB = db
	local pns = {}
	for _, f in ipairs(TocFiles()) do
		local chunk = assert(loadfile(DIR .. f))
		setfenv(chunk, c.env)("ChillzoneProbe", pns)
	end
	c:Fire("ADDON_LOADED", "ChillzoneProbe")
	c:Fire("PLAYER_ENTERING_WORLD", true, false)
	c.probe = pns.Probe
	return c
end

local function Lines(c, text)
	local out = {}
	for _, line in ipairs(c.env.ChillzoneProbeDB.log) do
		if line:find(text, 1, true) then out[#out + 1] = line end
	end
	return out
end

local function Logged(c, text) return #Lines(c, text) end

local function Pair()
	local w = Wow.World()
	local a = Probe(w, { first = "Автор", surname = "Проверки" })
	local b = Probe(w, { first = "Слушатель", surname = "Проверки" })
	a:Slash("/czp", "join")
	b:Slash("/czp", "join")
	w:Run(4)
	return w, a, b
end

T.test("probe: toc перечисляет существующие файлы", function()
	local files = TocFiles()
	T.ok(#files >= 1, "в toc нет файлов")
	for _, f in ipairs(files) do T.ok(io.open(DIR .. f, "rb"), "нет файла " .. f) end
	local toc = T.read(DIR .. "ChillzoneProbe.toc")
	T.ok(toc:find("## SavedVariables: ChillzoneProbeDB", 1, true), "журнал сохраняется между входами")
end)

T.test("probe: строка из своего поля доходит, своё эхо совпадает", function()
	local w, a, b = Pair()
	T.ok(a.joined[CHANNEL], "автор в канале")
	T.ok(b.joined[CHANNEL], "слушатель в канале")
	a:Slash("/czp", "")
	local box = a.probe.frames.box
	T.ok(box, "окно с полем ввода собрано")
	box:SetText("привет из поля")
	box.scripts.OnEnterPressed(box)
	T.eq(box:GetText(), "", "поле очищено после отправки")
	w:Run(1)
	T.eq(Logged(a, "эхо #1 (поле)"), 1, "эхо найдено")
	T.eq(Logged(a, "совпало"), 1, "эхо совпало байт в байт")
	local heard = Lines(b, "приём от Автор Проверки")
	T.eq(#heard, 1, "слушатель получил строку")
	T.ok(heard[1]:find("«привет из поля»", 1, true), "текст строки в журнале")
	T.ok(heard[1]:find("сумма " .. a.probe.Sum("привет из поля"), 1, true), "сумма совпадает с отправленной")
	T.eq(Logged(b, "эхо #"), 0, "чужая строка не считается своим эхо")
	T.ok(a.probe.Report():find("поле: отправлено 1, эхо 1, изменено 0, без эхо 0, ошибок 0", 1, true), "счётчики пути «поле»")
end)

T.test("probe: слэш, кнопка, несколько строк за нажатие и набор", function()
	local w, a, b = Pair()
	a:Slash("/czp", "обычный текст")
	a:Slash("/czp", "multi 3 частями")
	for _ = 1, #a.probe.KIT do a:Slash("/czp", "kit") end
	a:Slash("/czp", "")
	a.probe.frames.box:SetText("kit")
	a.probe.Submit("кнопка")
	w:Run(1)
	local report = a.probe.Report()
	T.ok(report:find("слэш: отправлено 5, эхо 5", 1, true), "слэш: текст и весь набор")
	T.ok(report:find("слэш x3: отправлено 3, эхо 3", 1, true), "три строки за одно нажатие")
	T.ok(report:find("кнопка: отправлено 1, эхо 1", 1, true), "набор по кнопке пошёл по кругу")
	T.eq(Logged(b, "(3/3)"), 1, "третья часть дошла")
	local long = a.probe.KIT[#a.probe.KIT]
	T.eq(#long, 255, "строка набора на пределе длины")
	T.eq(Logged(b, "255 байт, сумма " .. a.probe.Sum(long)), 1, "длинная строка дошла без изменений")
	T.eq(Logged(b, "приём от Автор Проверки"), 9, "все строки дошли до слушателя")
end)

T.test("probe: изменённое эхо, потеря и отправка из таймера", function()
	local w, a, b = Pair()
	local say = w.Say
	w.Say = function(self, from, msg, id) return say(self, from, (msg:gsub("%s+$", "")), id) end
	a:Slash("/czp", "say хвост ")
	w:Run(1)
	local changed = Lines(a, "ИЗМЕНЕНО")
	T.eq(#changed, 1, "изменение замечено")
	T.ok(changed[1]:find("отправлено 11 байт", 1, true) and changed[1]:find("пришло 10 байт", 1, true), "длины до и после")
	T.ok(changed[1]:find("расхождение с байта 11", 1, true), "место расхождения")
	w.Say = function() end
	a:Slash("/czp", "say пропало")
	w:Run(7)
	T.eq(Logged(a, "нет эхо #2 (слэш)"), 1, "потеря замечена")
	w.Say = say
	a:Slash("/czp", "timer 2 из таймера")
	w:Run(1)
	T.eq(Logged(b, "из таймера"), 0, "таймер ещё не сработал")
	w:Run(2)
	T.eq(Logged(a, "эхо #3 (таймер 2 с)"), 1, "путь таймера учтён отдельно")
	T.ok(a.probe.Report():find("слэш: отправлено 2, эхо 0, изменено 1, без эхо 1", 1, true), "счётчики изменений и потерь")
end)

T.test("probe: игрок без аддона, своя строка из чата игры, уведомления и вход участников", function()
	local w, a = Pair()
	local n = w:Client({ first = "Без", surname = "Аддона" })
	n.env.JoinChannelByName(CHANNEL)
	n.env.SendChatMessage("пишу сам", "CHANNEL", nil, n.joined[CHANNEL])
	a.env.SendChatMessage("из чата игры", "CHANNEL", nil, a.joined[CHANNEL])
	w:Run(1)
	local heard = Lines(a, "приём от Без Аддона")
	T.eq(#heard, 1, "строка игрока без аддона")
	T.ok(heard[1]:find("без GUID", 1, true), "в симуляторе GUID нет, это видно в журнале")
	T.eq(Logged(a, "своя строка не из проверки"), 1, "строка из чата игры отличена от проверки")
	a:Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "OWNER_CHANGED", "Без Аддона", "", "5. " .. CHANNEL, "", "", 0, 5, CHANNEL)
	a:Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "PLAYER_BANNED", "Слушатель Проверки", "", "5. ChillzoneProbe", "Без Аддона", "", 0, 5, CHANNEL)
	a:Fire("CHAT_MSG_CHANNEL_NOTICE_USER", "OWNER_CHANGED", "Кто-то", "", "2. Торговля", "", "", 0, 2, "Торговля")
	a:Fire("CHAT_MSG_CHANNEL_JOIN", "", "Без Аддона", "", "5. " .. CHANNEL, "", "", 0, 5, CHANNEL)
	T.eq(Logged(a, "уведомление (игрок): OWNER_CHANGED, игрок Без Аддона"), 1, "смена владельца")
	T.eq(Logged(a, "PLAYER_BANNED, игрок Слушатель Проверки, второй Без Аддона"), 1, "кто кого забанил")
	T.eq(Logged(a, "Кто-то"), 0, "уведомления чужих каналов не пишутся")
	T.eq(Logged(a, "вошёл в канал: Без Аддона"), 1, "вход участника")
	T.ok(a.probe.Report():find("уведомления канала: OWNER_CHANGED 1, PLAYER_BANNED 1; вошли 1, вышли 0", 1, true), "сводка уведомлений")
end)

T.test("probe: фильтр прячет только свой канал, блокировка и скрытые значения", function()
	local w, a = Pair()
	local function Hidden(name)
		for _, fn in ipairs(a.filters["CHAT_MSG_CHANNEL"] or {}) do
			if fn(nil, "CHAT_MSG_CHANNEL", "строка", "Кто-то", "", "5. " .. name, "", "", 0, 5, name) then return true end
		end
		return false
	end
	T.no(Hidden(CHANNEL), "без фильтра строки канала видны")
	a:Slash("/czp", "filter on")
	T.ok(Hidden(CHANNEL), "фильтр прячет строки канала")
	T.no(Hidden("Торговля"), "фильтр не трогает другие каналы")
	T.ok(a.env.ChillzoneProbeDB.filter, "фильтр помнится до следующего входа")
	a.lockdown = true
	a:Slash("/czp", "в блокировке")
	T.eq(Logged(a, "блокировка да"), 1, "состояние блокировки записано при отправке")
	w:Run(3)
	T.eq(Logged(a, "блокировка сообщений: да"), 1, "смена блокировки замечена без отправки")
	a.env.issecretvalue = function(v) return v == "СЕКРЕТ" end
	a:Fire("CHAT_MSG_CHANNEL", "СЕКРЕТ", "Кто-то", "", "5. " .. CHANNEL, "", "", 0, 5, CHANNEL)
	a:Fire("CHAT_MSG_CHANNEL", "строка", "Кто-то", "", "СЕКРЕТ", "", "", 0, 5, "СЕКРЕТ")
	T.ok(a.probe.Report():find("скрытые значения: в нашем канале 1, имя канала 1", 1, true), "скрытые значения посчитаны")
end)

T.test("probe: автовход после входа в мир, журнал между входами, глобалы", function()
	local w = Wow.World()
	local db = { auto = true, log = { "старая строка" } }
	local c = Probe(w, { first = "Вернулся", surname = "Снова" }, db)
	T.no(c.joined[CHANNEL], "сразу после входа в мир не входит")
	w:Run(20)
	T.ok(c.joined[CHANNEL], "вошёл сам, когда каналы игры не появились за отведённое время")
	T.eq(Logged(c, "автовход через 15 с"), 1, "когда и почему вошёл")
	T.eq(c.env.ChillzoneProbeDB.log[1], "старая строка", "журнал прошлого входа сохранён")
	c:Slash("/czp", "say |cffff0000красный|r")
	T.ok(c.probe.Report():find("||cffff0000красный||r", 1, true), "коды цвета в отчёте экранированы")
	c:Slash("/czp", "leave")
	T.no(c.joined[CHANNEL], "вышел")
	T.no(c.env.ChillzoneProbeDB.auto, "после выхода автовход выключен")
	T.same(c:Leaks(), { "ChillzoneProbeDB" }, "глобалы проверочного аддона")
end)
