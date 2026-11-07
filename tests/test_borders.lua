-- Рамки ролей: роль по данным (Data.RoleOf), отрисовка на цели и фокусе (Borders.lua),
-- атласы, геймпад, бой и настройка.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local KING = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Gold-Winged"
local LORD = "UI-HUD-UnitFrame-Target-PortraitOn-Boss-Rare-Silver-Winged"
local CAPTAIN = "ui-hud-unitframe-target-portraiton-boss-rare-silver"
local ATLASES = { [KING] = true, [LORD] = true, [CAPTAIN] = true }

-- Мир: главная гильдия, ещё одна «Чиллзон», своя гильдия зрителя и посторонняя.
local function World()
	math.randomseed(5)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	w:Guild("Олимп")
	return w
end

-- Зритель — рядовой «Ордена Чиллзона». opts — поля World:Client поверх.
local function Viewer(w, opts)
	local o = { first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 3 }
	for k, v in pairs(opts or {}) do o[k] = v end
	local c = w:Client(o)
	w:Run(2)
	return c
end

-- Подписанный (как его принимает перепись через реле) отчёт гильдии guild.
local function Signed(ns, guild, origin, st, leader, officers, signed)
	local r = {
		guild = guild, total = 10, online = 4, leader = leader or "Вера Верная", leaderOnline = true,
		leaderDays = 0, leaderClass = "DRUID", leaderLevel = 60, users = 2,
		zones = {}, classes = { DRUID = 1 }, levels = { 0, 0, 0, 0, 0, 1, 3 },
		ranks = { { name = "Глава", count = 1 }, { name = "Офицер", count = 1 }, { name = "Рядовой", count = 8 } },
		officers = officers or { { name = "Борис Быстрый", online = true, days = 0, class = "WARRIOR", level = 60, rank = 1 } },
		veterans = {}, inactive7 = 0, inactive30 = 0, avgLevel = 55.5, faction = "Alliance", st = st,
	}
	local raw = ns.Codec.EncodeReport(r)
	local ctx = signed ~= false and { authenticated = true, wire = raw } or nil
	T.ok(ns.Data.Take(ns.Codec.DecodeReport(raw), raw, origin, st, ctx), "отчёт принят: " .. guild)
end

local function P(guild, rank, name, extra)
	local p = { guild = guild, rank = rank, name = name or "Кто Угодно", faction = "Alliance" }
	for k, v in pairs(extra or {}) do p[k] = v end
	return p
end

T.test("borders: роль по данным — Король, Лорд, рядовой, чужие", function()
	local w = World()
	local ns = Viewer(w).ns
	local D = ns.Data
	T.eq(D.RoleOf(P("Чиллзон", 0, "Карл Великий")), "king", "глава главной гильдии — Король")
	T.eq(D.RoleOf(P("ЧИЛЛЗОН", 0, "Карл Великий")), "king", "регистр названия не важен")
	T.eq(D.RoleOf(P("Чиллзон Север", 0, "Вера Верная")), "lord", "глава другой — Лорд")
	T.eq(D.RoleOf(P("Чиллзон Юг", 0)), "lord", "Лорд и без отчёта: звание даёт сервер")
	T.eq(D.RoleOf(P("Чиллзон Север", 3)), nil, "рядовой")
	T.eq(D.RoleOf(P("Олимп", 0)), nil, "не «Чиллзон»")
	T.eq(D.RoleOf(P("Чиллзон", 0, "Карл Великий", { faction = "Horde" })), nil, "чужая фракция")
	T.eq(D.RoleOf(P("Чиллзон", 0, "Карл Великий", { realm = "CAMWOWUS2Realm7PvP" })), nil, "чужая группа реалмов")
	T.eq(D.RoleOf(P("Чиллзон", 0, "Карл Великий", { realm = "CAMWOWUS2Realm9PvE" })), "king", "другой реалм той же группы")
	T.eq(D.RoleOf(P(nil, 0)), nil, "без гильдии")
	T.eq(D.RoleOf(nil), nil, "нет данных")
end)

T.test("borders: Капитан своей гильдии — по флагу «Офицер» в ростере", function()
	local w = World()
	w:AddOffline("Орден Чиллзона", "Ирина Иная-CAMWOWUS2Realm7PvE", 1)
	w:AddOffline("Орден Чиллзона", "Пётр Простой-CAMWOWUS2Realm7PvE", 2)
	local ns = Viewer(w).ns
	w:Run(10)
	local D = ns.Data
	T.eq(D.RoleOf(P("Орден Чиллзона", 1, "Ирина Иная")), "captain", "звание с флагом «Офицер»")
	T.eq(D.RoleOf(P("Орден Чиллзона", 2, "Пётр Простой")), nil, "звание без флага")
	T.eq(D.RoleOf(P("Орден Чиллзона", 0, "Глава Ордена")), "lord", "глава своей неглавной гильдии — Лорд")
	T.eq(D.RoleOf(P("Орден Чиллзона", nil, "Ирина Иная")), "captain", "сервер не дал звание — по ростеру")
	T.eq(D.RoleOf(P("Орден Чиллзона", nil, "Не Из Ростера")), nil, "нет ни звания, ни строки ростера")
	-- Флаг меняется в настройках гильдии: звание 2 становится офицерским.
	w.guilds["Орден Чиллзона"].officers[2] = true
	ns.Roster.Scan()
	T.eq(D.RoleOf(P("Орден Чиллзона", 2, "Пётр Простой")), "captain", "флаг после скана")
end)

T.test("borders: Капитан чужой гильдии — по свежему подписанному отчёту", function()
	local w = World()
	local ns = Viewer(w).ns
	local D, C = ns.Data, ns.Config
	local now = ns.ServerTime()
	local captain = P("Чиллзон Север", 1, "Борис Быстрый")
	T.eq(D.RoleOf(captain, now), nil, "нет отчёта — нет Капитана")
	Signed(ns, "Чиллзон Север", "Свидетель Первый", now)
	T.eq(D.RoleOf(captain, now), "captain", "офицер из отчёта")
	T.eq(D.RoleOf(P("Чиллзон Север", 1, "борис быстрый"), now), "captain", "имя без учёта регистра")
	T.eq(D.RoleOf(P("Чиллзон Север", 3, "Мира Тихая"), now), nil, "рядовой: нет в officers")
	T.eq(D.RoleOf(P("Чиллзон Север", nil, "Вера Верная"), now), "lord", "сервер не дал звание — глава из отчёта")
	T.eq(D.RoleOf(P("Чиллзон Север", 3, "Вера Верная"), now), nil, "звание сервера важнее отчёта")
	T.eq(D.RoleOf(captain, now + C.FRESH), "captain", "свежий на границе")
	T.eq(D.RoleOf(captain, now + C.FRESH + 1), nil, "устаревший отчёт")
	T.eq(D.RoleOf(P("Чиллзон Север", 1, "Борис Быстрый", { faction = "Horde" }), now), nil, "чужая фракция")
	-- Неподписанный отчёт другой гильдии Капитанов не даёт.
	Signed(ns, "Чиллзон Юг", "Свидетель Второй", now, "Юрий Южный", nil, false)
	T.eq(D.RoleOf(P("Чиллзон Юг", 1, "Борис Быстрый"), now), nil, "отчёт без подписи")
	-- Разные подписи руководства от разных отправителей: конфликт, Капитанов нет.
	Signed(ns, "Чиллзон Север", "Свидетель Третий", now + 10, "Самозванец Ложный")
	T.ok(D.Row("Чиллзон Север").conflict, "конфликт подписей")
	T.eq(D.RoleOf(captain, now + 10), nil, "при конфликте подписей")
end)

T.test("borders: роль игрока на месте цели", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local horde = w:Client({ first = "Гром", surname = "Чужой", guild = "Чиллзон", rank = 0, faction = "Horde" })
	local c = Viewer(w)
	local B = c.ns.Borders
	T.eq(B.RoleOf("target"), nil, "нет цели")
	c.units.target = king
	T.eq(B.RoleOf("target"), "king", "Король")
	local f = B.Facts("target")
	T.eq(f.name, "Карл Великий-CAMWOWUS2Realm7PvE", "фамилия на месте реалма — часть имени")
	T.eq(f.rank, 0, "rankIndex")
	c.units.target = horde
	T.eq(B.RoleOf("target"), nil, "чужая фракция")
	c.units.target = { first = "Волк", surname = "Серый", guild = "Чиллзон", rank = 0, faction = "Alliance", npc = true }
	T.eq(B.RoleOf("target"), nil, "не игрок")
	c.units.target = king
	c.env.issecretvalue = function(v) return v == "Чиллзон" end
	T.eq(B.RoleOf("target"), nil, "скрытое значение (secret) — ничего")
end)

-- Сколько раз аддон поставил пост-хук на метод кадра игры.
local function Hooks(c, method)
	local n = 0
	for _, h in ipairs(c.methodHooks) do
		if h.method == method then n = n + 1 end
	end
	return n
end

-- Текстуры, которые аддон создал на портрете (контейнере) кадра frame, или nil.
local function Textures(c, frame)
	return rawget(c.env[frame].TargetFrameContainer, "textures")
end

-- Текстура рамки с атласом atlas на портрете (контейнере) кадра frame или nil.
local function Tex(c, frame, atlas)
	for _, t in ipairs(Textures(c, frame) or {}) do
		if t.atlas == atlas then return t end
	end
	return nil
end

-- Какие текстуры рамок на кадре сейчас видны (атласы через запятую).
local function Visible(c, frame)
	local out = {}
	for _, t in ipairs(Textures(c, frame) or {}) do
		if t.shown then out[#out + 1] = t.atlas end
	end
	return table.concat(out, ",")
end

T.test("borders: рамка на цели и фокусе, смена цели в бою", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local lord = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0 })
	local mate = w:Client({ first = "Ирина", surname = "Иная", guild = "Орден Чиллзона", rank = 1 })
	local c = Viewer(w, { unitFrames = true, atlases = ATLASES })
	local B = c.ns.Borders
	T.ok(B.Installed(), "поставлены при входе")
	T.eq(Hooks(c, "CheckClassification"), 2, "хук на цели и на фокусе")
	T.eq(#Textures(c, "TargetFrame"), 3, "три текстуры на цели")
	T.eq(#Textures(c, "FocusFrame"), 3, "три текстуры на фокусе")
	local tex = Tex(c, "TargetFrame", KING)
	T.eq(tex.layer, "ARTWORK", "слой")
	T.eq(tex.sublevel, 3, "над рамкой игры")
	T.eq(Visible(c, "TargetFrame"), "", "сначала скрыты")

	c.units.target = king
	c:Fire("PLAYER_TARGET_CHANGED")
	T.eq(B.Shown("target"), "king", "Король")
	T.eq(Visible(c, "TargetFrame"), KING, "видна только золотая")
	-- Обновление кадра игрой (CheckClassification) показывает рамку заново.
	c.combat = true
	c.units.target = lord
	c.env.TargetFrame:CheckClassification()
	T.eq(Visible(c, "TargetFrame"), LORD, "смена цели в бою: Лорд")
	c.units.focus = mate
	c:Fire("PLAYER_FOCUS_CHANGED")
	T.eq(Visible(c, "FocusFrame"), CAPTAIN, "фокус: Капитан своей гильдии")
	c.units.target = nil
	c:Fire("PLAYER_TARGET_CHANGED")
	T.eq(Visible(c, "TargetFrame"), "", "нет цели — нет рамки")
	T.eq(Visible(c, "FocusFrame"), CAPTAIN, "фокус не тронут")
	T.eq(#Textures(c, "TargetFrame"), 3, "в бою новых текстур нет")
	c.combat = false
	-- Гильдия цели дошла позже смены цели.
	local late = { first = "Тихон", surname = "Поздний", faction = "Alliance", rank = 0 }
	c.units.target = late
	c:Fire("PLAYER_TARGET_CHANGED")
	T.eq(B.Shown("target"), nil, "гильдия ещё неизвестна")
	late.guild = "Чиллзон Север"
	c:Fire("PLAYER_GUILD_UPDATE", "target")
	T.eq(B.Shown("target"), "lord", "после PLAYER_GUILD_UPDATE")
	T.eq(#c:Leaks(), 0, "глобалы не утекли: " .. table.concat(c:Leaks(), ", "))
end)

T.test("borders: без атласа или кадров игры ничего не рисуется", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local c = Viewer(w, { unitFrames = true })
	c.units.target = king
	c:Fire("PLAYER_TARGET_CHANGED")
	T.eq(Textures(c, "TargetFrame"), nil, "ни одной текстуры")
	T.eq(Hooks(c, "CheckClassification"), 0, "без текстур и хука нет")
	T.eq(c.ns.Borders.Shown("target"), nil, "ничего не показано")
	-- Клиент знает только один атлас: только эта рамка.
	local d = Viewer(World(), { first = "Дина", surname = "Другая", unitFrames = true, atlases = { [LORD] = true } })
	T.eq(#Textures(d, "TargetFrame"), 1, "только известный атлас")
	d.units.target = { first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, faction = "Alliance" }
	d:Fire("PLAYER_TARGET_CHANGED")
	T.eq(d.ns.Borders.Shown("target"), nil, "атласа Короля нет — рамки нет")
	-- Нет кадров с контейнером (Classic Era): нет ни текстур, ни хуков, ни ошибок.
	local e = Viewer(World(), { first = "Ефим", surname = "Ещё", atlases = ATLASES })
	e.units.target = king
	e:Fire("PLAYER_TARGET_CHANGED")
	T.eq(Hooks(e, "CheckClassification"), 0, "хуков нет")
	T.eq(e.ns.Borders.Shown("target"), nil, "рамки нет")
	T.eq(#(e.ns.db.errors or {}), 0, "без ошибок")
end)

T.test("borders: в режиме геймпада хуки не ставятся, переключение без /reload", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local c = Viewer(w, { unitFrames = true, atlases = ATLASES, gamepad = true })
	local B = c.ns.Borders
	c.units.target = king
	c:Fire("PLAYER_TARGET_CHANGED")
	T.no(B.Installed(), "при входе с геймпадом не поставлены")
	T.eq(Hooks(c, "CheckClassification"), 0, "хуков нет")
	T.eq(Textures(c, "TargetFrame"), nil, "текстур нет")
	-- На мышь и клавиатуру: рамки ставятся и показываются.
	c.gamepad = false
	c:Fire("INPUT_DEVICE_INTERFACE_TRANSITION", 0, 1)
	w:Run(0.1)
	T.ok(B.Installed(), "поставлены после переключения")
	T.eq(Hooks(c, "CheckClassification"), 2, "хуки поставлены")
	T.eq(Visible(c, "TargetFrame"), KING, "рамка видна")
	-- Обратно на геймпад: рамки прячутся, хук ничего не показывает.
	c.gamepad = true
	c:Fire("INPUT_DEVICE_INTERFACE_TRANSITION", 1, 0)
	w:Run(0.1)
	T.eq(Visible(c, "TargetFrame"), "", "спрятана")
	c.env.TargetFrame:CheckClassification()
	c:Fire("PLAYER_TARGET_CHANGED")
	T.eq(Visible(c, "TargetFrame"), "", "хук и событие ничего не показывают")
	T.eq(Hooks(c, "CheckClassification"), 2, "повторных хуков нет")
	c.gamepad = false
	c:Fire("INPUT_DEVICE_INTERFACE_TRANSITION", 0, 1)
	w:Run(0.1)
	T.eq(Visible(c, "TargetFrame"), KING, "снова видна")
	T.eq(Hooks(c, "CheckClassification"), 2, "хуки не удвоились")
end)

T.test("borders: вход в бою — после боя", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local c = Viewer(w, { unitFrames = true, atlases = ATLASES, combat = true })
	local B = c.ns.Borders
	c.units.target = king
	c:Fire("PLAYER_TARGET_CHANGED")
	T.no(B.Installed(), "в бою не ставятся")
	T.eq(Textures(c, "TargetFrame"), nil, "текстур нет")
	c.combat = false
	c:Fire("PLAYER_REGEN_ENABLED")
	T.ok(B.Installed(), "после боя")
	T.eq(Visible(c, "TargetFrame"), KING, "рамка видна")
end)

T.test("borders: выключенная настройка прячет рамку", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local c = Viewer(w, { unitFrames = true, atlases = ATLASES })
	local B = c.ns.Borders
	c.units.target = king
	c:Fire("PLAYER_TARGET_CHANGED")
	T.eq(Visible(c, "TargetFrame"), KING, "видна")
	c:Slash("/chillzone", "borders off")
	T.eq(c.ns.db.settings.borders, false, "сохранено")
	T.no(B.Enabled(), "выключены")
	T.eq(Visible(c, "TargetFrame"), "", "спрятана")
	T.ok(c:Saw("рамки ролей выключены") > 0, "сказано в чат")
	c.env.TargetFrame:CheckClassification()
	T.eq(Visible(c, "TargetFrame"), "", "хук не показывает")
	c:Slash("/chillzone", "status")
	T.ok(c:Saw("Рамки ролей: выключены; цель: «Чиллзон», звание 0, роль: Король") > 0, "статус и что пришло о цели")
	c:Slash("/chillzone", "borders вкл")
	T.ok(B.Enabled(), "включены")
	T.eq(Visible(c, "TargetFrame"), KING, "снова видна")
	c:Slash("/chillzone", "borders")
	T.no(B.Enabled(), "без аргумента — переключение")
end)

T.test("borders: вне гильдий «Чиллзон» рамок нет", function()
	local w = World()
	local king = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0 })
	local c = Viewer(w, { guild = "Олимп", unitFrames = true, atlases = ATLASES })
	c.units.target = king
	c:Fire("PLAYER_TARGET_CHANGED")
	T.no(c.ns.Borders.Installed(), "не ставятся")
	T.eq(c.ns.Borders.Shown("target"), nil, "рамки нет")
end)
