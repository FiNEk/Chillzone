-- Поиск в «Переписи»: что находит Views.CensusRows с запросом и как работает поле над списком —
-- в симуляторе мира с тремя гильдиями.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 11)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	w:AddOffline("Чиллзон Север", "Тихий Друид-CAMWOWUS2Realm7PvE", 3, 41, "DRUID", 2)
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN" })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 2, class = "WARRIOR", zone = "Сумеречный лес" })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID", zone = "Элвиннский лес" })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER" })
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.A)
	w:Pair(c.G, c.A)
	c.V:Slash("/chillzone", "zones on")
	w:Run(600)
	return w, c
end

local function Errors(c)
	for name, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, name .. ": глобалы")
	end
end

-- Ключи гильдий, которые нашёл запрос, и подпись первой строки.
local function Found(cl, query)
	local rows = cl.ns.Views.CensusRows(nil, query)
	local keys = {}
	for i, r in ipairs(rows) do keys[i] = r.key end
	return keys, rows[1] and rows[1].sub or nil, rows
end

T.test("поиск: офицер, связной, глава и название", function()
	local _, c = Build()
	local key = c.G.ns.Util.GuildKey
	local keys, sub = Found(c.G, "арагорн")
	T.eq(#keys, 1, "одна гильдия")
	T.eq(keys[1], key("Чиллзон"), "гильдия офицера")
	T.ok(sub:find("Капитан:", 1, true) and sub:find("Арагорн Светлый", 1, true), "в подписи — кто нашёлся: " .. tostring(sub))
	keys = Found(c.G, "apaг" .. "opн")
	T.eq(keys[1], key("Чиллзон"), "латинские a, o, p в запросе")
	keys, sub = Found(c.G, "БОРИС")
	T.eq(keys[1], key("Чиллзон Север"), "связной Севера")
	T.ok(sub:find("Связной:", 1, true), "подпись связного: " .. tostring(sub))
	keys, sub = Found(c.G, "карл")
	T.eq(#keys, 1, "глава")
	T.ok(sub:find("Глава:", 1, true), "подпись прежняя — глава в ней виден")
	keys, sub = Found(c.G, "орден")
	T.eq(keys[1], key("Орден Чиллзона"), "название")
	T.ok(sub:find("Глава:", 1, true), "подпись прежняя")
	keys = Found(c.G, "чиллз")
	T.eq(#keys, 3, "часть названия у всех")
	keys = Found(c.G, "нет такого")
	T.eq(#keys, 0, "ничего не найдено")
	Errors(c)
end)

T.test("поиск: зоны свежих отчётов", function()
	local _, c = Build()
	local key = c.G.ns.Util.GuildKey
	local keys, sub = Found(c.G, "элвинн")
	T.eq(#keys, 1, "одна гильдия")
	T.eq(keys[1], key("Чиллзон Север"), "Север делится зонами")
	T.ok(sub:find("Где сейчас:", 1, true) and sub:find("Элвиннский лес", 1, true), "зона в подписи: " .. tostring(sub))
	keys = Found(c.G, "штормград")
	for _, k in ipairs(keys) do T.ok(k ~= key("Чиллзон"), "главная зонами не делится") end
	Errors(c)
end)

T.test("поиск: участники своей гильдии, и не в игре", function()
	local _, c = Build()
	local key = c.B.ns.Util.GuildKey
	local keys, sub = Found(c.B, "тихий")
	T.eq(#keys, 1, "своя гильдия")
	T.eq(keys[1], key("Чиллзон Север"))
	T.ok(sub:find("Рядовой:", 1, true) and sub:find("Тихий Друид", 1, true), "звание из ростера: " .. tostring(sub))
	T.eq(#Found(c.G, "тихий"), 0, "чужой ростер не виден: рядовых в отчёте нет")
	keys = Found(c.B, "в")
	T.ok(#keys >= 2, "буква есть во многих гильдиях")
	Errors(c)
end)

T.test("поиск: пустой запрос — прежний список", function()
	local _, c = Build()
	local V = c.B.ns.Views
	local all = V.CensusRows()
	T.eq(#all, 3, "три гильдии")
	for _, q in ipairs({ "", "   ", false }) do
		local rows = V.CensusRows(nil, q or nil)
		T.eq(#rows, #all, "столько же строк")
		for i, r in ipairs(rows) do
			T.eq(r.key, all[i].key, "тот же порядок")
			T.eq(r.sub, all[i].sub, "та же подпись")
		end
	end
	Errors(c)
end)

T.test("поиск: поле над списком, Esc и запрос до конца сессии", function()
	local w, c = Build()
	local B = c.B
	local P = B.ns.CensusPane
	B.ns.UI.Toggle("census")
	local f = P.frames
	local function Shown()
		local n = 0
		for _, r in ipairs(f.rows) do if r:IsShown() then n = n + 1 end end
		return n
	end
	T.eq(Shown(), 3, "без запроса — все")
	T.no(f.search:HasFocus(), "поле само фокус не берёт")
	local sent = #w.log
	f.search:SetFocus()
	f.search:SetText("Тихий")
	f.search.scripts.OnTextChanged(f.search, true)
	T.eq(Shown(), 1, "нашлась своя гильдия")
	T.ok(f.rows[1].sub:GetText():find("Тихий Друид", 1, true), "и кто в ней")
	f.search:SetText("нет такого")
	f.search.scripts.OnTextChanged(f.search, true)
	T.eq(Shown(), 0, "пусто")
	T.ok(f.empty:IsShown() and f.empty:GetText() == "Ничего не найдено.", "подпись: " .. tostring(f.empty:GetText()))
	T.ok(f.card:IsShown(), "карточка выбранной гильдии остаётся")
	f.search.scripts.OnEscapePressed(f.search)
	T.no(f.search:HasFocus(), "Esc убирает курсор")
	f.search:SetText("арагорн")
	f.search.scripts.OnTextChanged(f.search, true)
	T.eq(P.Selected(), B.ns.Util.GuildKey("Чиллзон"), "выбрана найденная гильдия")
	B.ns.UI.Toggle("chat")
	B.ns.UI.Toggle("census")
	T.eq(P.Query(), "арагорн", "запрос держится до конца сессии")
	T.eq(Shown(), 1, "и список отфильтрован")
	T.eq(#w.log, sent, "поиск ничего не отправляет")
	f.search:SetText("")
	f.search.scripts.OnTextChanged(f.search, true)
	T.eq(Shown(), 3, "стёрли — снова все")
	T.eq(f.empty:GetText(), "Пока нет данных о других гильдиях.", "и прежняя подпись")
	Errors(c)
end)
