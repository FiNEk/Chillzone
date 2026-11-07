-- Карточка игрока: что знает о человеке Views.PersonCard, где она открывается (перепись,
-- «Королевство», люди в чате, /chillzone profile) и что делают кнопки «Шёпот», «Пригласить»
-- и «Кто» — в симуляторе мира с тремя гильдиями. В сеть карточка ничего не шлёт.
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
	w:Run(600)
	return w, c
end

local function Errors(c)
	for name, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, name .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, name .. ": глобалы")
	end
end

-- Строки карточки одной строкой: так проще искать.
local function Text(card)
	local out = {}
	for i, e in ipairs(card.lines) do out[i] = e.text end
	return table.concat(out, " | ")
end

local function Has(card, text)
	return Text(card):find(text, 1, true) ~= nil
end

local function Click(b)
	T.ok(b and b.scripts.OnClick, "есть обработчик щелчка")
	b.scripts.OnClick(b, "LeftButton")
end

T.test("карточка: роли, звание, зона и «не в игре»", function()
	local _, c = Build()
	local V = c.B.ns.Views
	-- Глава своей гильдии (Север — не главная): Лорд, звание, зона, версия аддона.
	local card = V.PersonCard({ name = "Вера Верная" })
	T.eq(card.name, "Вера Верная", "имя")
	T.ok(card.title:find("Вера Верная", 1, true), "заголовок с именем")
	T.ok(Has(card, "Лорд, гильдия «Чиллзон Север»"), "роль и гильдия: " .. Text(card))
	T.ok(Has(card, "Звание: Глава"), "звание из ростера")
	T.ok(Has(card, "Уровень 60"), "уровень")
	T.ok(Has(card, "в игре"), "в игре")
	T.ok(Has(card, "Где сейчас: Элвиннский лес"), "зона своей гильдии")
	T.ok(Has(card, "Chillzone " .. c.B.ns.VERSION), "версия аддона у согильдийца")
	T.ok(card.whisper and card.invite, "шёпот и приглашение можно")
	T.eq(card.tell, "Вера Верная", "шептать — без реалма")
	-- Связной своей гильдии — тоже из ростера; карточка самого себя.
	card = c.V.ns.Views.PersonCard({ name = "Борис Быстрый" })
	T.ok(Has(card, "Связной, гильдия «Чиллзон Север»"), "звание «Ветеран» — связной: " .. Text(card))
	card = V.PersonCard({ name = "Борис Быстрый" })
	T.ok(card.me, "это я")
	T.no(card.whisper or card.invite, "себе не шепчут и не приглашают")
	T.ok(Has(card, "Chillzone " .. c.B.ns.VERSION), "своя версия")
	-- Не в игре: из своего ростера, только «Кто».
	card = V.PersonCard({ name = "Тихий Друид" })
	T.ok(Has(card, "Звание: Рядовой"), "звание: " .. Text(card))
	T.ok(Has(card, "не в игре 2 дн."), "дней не в игре")
	T.no(Has(card, "Где сейчас"), "зоны нет")
	T.no(card.whisper or card.invite, "не в игре — ни шёпота, ни приглашения")
	-- Чужие гильдии — по отчётам переписи: Король, Капитан.
	card = V.PersonCard({ name = "Карл Великий" })
	T.ok(Has(card, "Король, гильдия «Чиллзон»"), "глава главной — Король: " .. Text(card))
	T.no(Has(card, "Звание:"), "звание чужой гильдии не показываем")
	T.no(Has(card, "Где сейчас"), "зону чужой гильдии не показываем")
	card = V.PersonCard({ name = "арагорн светлый" })
	T.eq(card.name, "Арагорн Светлый", "имя как в отчёте, хоть щёлкнули строчными")
	T.ok(Has(card, "Капитан, гильдия «Чиллзон»"), "офицер — Капитан: " .. Text(card))
	-- Неизвестный: только «ничего не известно», но шептать можно.
	card = V.PersonCard({ name = "Некто Неизвестный" })
	T.ok(Has(card, "ничего"), "о нём ничего не известно: " .. Text(card))
	T.ok(card.whisper, "шёпот — можно попробовать")
	T.eq(V.PersonCard({ name = "" }), nil, "пустое имя — нет карточки")
	Errors(c)
end)

T.test("карточка: сертификат подтверждает роль", function()
	local _, c = Build()
	local S = c.B.ns.Security
	local cert = S.Member("Чиллзон Север", "Вера Верная")
	T.ok(cert, "у главы Севера есть сертификат")
	local card = c.B.ns.Views.PersonCard({ name = "Вера Верная" })
	T.ok(Has(card, "Роль подтверждена сертификатом: глава"), "строка сертификата: " .. Text(card))
	card = c.B.ns.Views.PersonCard({ name = "Тихий Друид" })
	T.ok(Has(card, "Роль не подтверждена сертификатом"), "без сертификата: " .. Text(card))
	Errors(c)
end)

T.test("карточка: щелчок в переписи и кнопки, в сеть ничего", function()
	local w, c = Build()
	local B = c.B
	local before = #w.log
	B.ns.UI.Toggle("census")
	local first = B.ns.CensusPane.frames.people[1]
	T.ok(first:IsShown() and first.person.name == "Вера Верная", "глава Севера первой")
	Click(first)
	local f = B.ns.PersonCard.frames
	T.ok(f and f.frame:IsShown(), "карточка открыта")
	T.eq(B.ns.UI.Current(), "census", "вкладка та же")
	T.ok(f.name:GetText():find("Вера Верная", 1, true), "имя в карточке")
	T.eq(B.ns.PersonCard.Shown().name, "Вера Верная", "чья карточка")
	local buttons = f.buttons
	T.ok(buttons.whisper:IsShown() and buttons.invite:IsShown() and buttons.who:IsShown(), "три кнопки")
	-- «Пригласить»: имя без реалма, прямо из щелчка.
	Click(buttons.invite)
	T.eq(#B.partyInvites, 1, "одно приглашение")
	T.eq(B.partyInvites[1], "Вера Верная", "без реалма")
	-- «Кто»: один /who по имени; повтор во время паузы отклонён.
	Click(buttons.who)
	T.eq(#B.whoQueries, 1, "один /who")
	T.eq(B.whoQueries[1], 'n-"Вера Верная"', "по имени")
	Click(buttons.who)
	T.eq(#B.whoQueries, 1, "повтор во время паузы не ушёл")
	T.ok(B:Saw("/who можно повторить через"), "сказали, когда можно")
	-- «Шёпот»: окно переходит на чат, в поле — /w Имя Фамилия.
	Click(buttons.whisper)
	T.eq(B.ns.UI.Current(), "chat", "открыт чат")
	T.eq(B.ns.ChatPane.frames.box:GetText(), "/w Вера Верная ", "шёпот в поле")
	T.ok(f.frame:IsShown(), "карточка остаётся на другой вкладке")
	T.eq(#w.log, before, "в сеть ничего не ушло")
	-- Пауза /who прошла — снова можно.
	w:Run(11)
	B.ns.UI.Toggle("census")
	Click(first)
	Click(f.buttons.who)
	T.eq(#B.whoQueries, 2, "после паузы — второй /who")
	Errors(c)
end)

T.test("карточка: «Королевство», люди в чате, команда, закрытие, геймпад", function()
	local _, c = Build()
	local B = c.B
	local PC = B.ns.PersonCard
	-- «Королевство»: щелчок по строке Короля.
	B.ns.UI.Toggle("kingdom")
	local king
	for _, r in ipairs(B.ns.UI.rows) do
		if r:IsShown() and r.person and r.person.name == "Карл Великий" then king = r end
	end
	T.ok(king, "строка Короля в «Королевстве»")
	Click(king)
	T.eq(PC.Shown() and PC.Shown().name, "Карл Великий", "карточка Короля")
	T.ok(Has(PC.Shown(), "Король"), "роль в карточке")
	T.eq(B.ns.UI.Current(), "kingdom", "вкладка та же")
	-- Люди справа в чате: щелчок — карточка, а не шёпот.
	B.ns.UI.Toggle("chat")
	B.ns.ChatPane.Select("G")
	B.ns.ChatPane.RenderPeople()
	local row
	for _, r in ipairs(B.ns.ChatPane.peopleRows) do
		if r:IsShown() and r.person and r.person.name == "Вера Верная" then row = r end
	end
	T.ok(row, "Вера в списке людей гильдии")
	B.ns.ChatPane.frames.box:SetText("")
	Click(row)
	T.eq(PC.Shown() and PC.Shown().name, "Вера Верная", "карточка из списка людей")
	T.eq(B.ns.ChatPane.frames.box:GetText(), "", "в поле ничего не вписано")
	-- Не в игре — только «Кто».
	PC.Open({ name = "Тихий Друид" })
	local buttons = PC.frames.buttons
	T.no(buttons.whisper:IsShown() or buttons.invite:IsShown(), "не в игре: шёпота и приглашения нет")
	T.ok(buttons.who:IsShown(), "«Кто» есть")
	T.no(PC.Whisper() or PC.Invite(), "и вызовом их не обойти")
	T.eq(#B.partyInvites, 0, "приглашений нет")
	-- Окно закрыли — карточка тоже; команда открывает и окно.
	B.ns.UI.frame:Hide()
	T.eq(PC.Shown(), nil, "закрылась с окном")
	B:Slash("/chillzone", "profile Глеб Гордый")
	T.ok(B.ns.UI.Current(), "окно открылось")
	T.eq(PC.Shown() and PC.Shown().name, "Глеб Гордый", "карточка по команде")
	B:Slash("/chillzone", "profile")
	T.ok(B:Saw("/chillzone profile Имя Фамилия"), "подсказка без имени")
	-- Геймпад: «Кто» скрыт и не срабатывает.
	local gamepad = B.ns.ChatPane.Gamepad
	B.ns.ChatPane.Gamepad = function() return true end
	PC.Open({ name = "Вера Верная" })
	T.no(PC.frames.buttons.who:IsShown(), "в режиме геймпада «Кто» нет")
	T.no(PC.Who(), "и не срабатывает")
	T.eq(#B.whoQueries, 0, "/who не ушёл")
	B.ns.ChatPane.Gamepad = gamepad
	-- Крестик закрывает только карточку.
	PC.Hide()
	T.eq(PC.Shown(), nil, "закрыта")
	T.ok(B.ns.UI.Current(), "окно открыто")
	Errors(c)
end)
