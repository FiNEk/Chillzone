-- Размер окна (UI.lua): уголок растягивания, пределы от исходного размера до экрана, сохранение
-- размера между /reload и раздача лишней ширины колонкам. Строки вкладок под высокое окно
-- проверяют наборы самих вкладок: test_online («Перепись»), test_crafters, test_transfer («Состав»).
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	local c = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN",
		config = { CHANNEL_CHAT = false } })
	-- Экран 1920×1080: справа за окном ещё столбец значков шириной 40.
	c.env.UIParent.GetWidth = function() return 1920 end
	c.env.UIParent.GetHeight = function() return 1080 end
	w:Run(30)
	return w, c
end

local function Errors(c)
	local errors = c.ns.db.errors or {}
	T.eq(#errors, 0, table.concat(errors, " | "))
end

T.test("window: размер не меньше исходного и не больше экрана, исходный не записывается", function()
	local _, c = Build()
	local UI, db = c.ns.UI, c.ns.db
	T.same({ UI.Size() }, { 814, 426 }, "исходный размер")
	T.same({ UI.InsetSize() }, { 804, 340 }, "вставка исходного окна")
	T.same({ UI.Resize(500, 300) }, { 814, 426 }, "меньше исходного не бывает")
	T.no(db.settings.frame.w, "исходный размер не записывается")
	T.same({ UI.Resize(1000.4, 600.6) }, { 1000, 601 }, "размер в целых точках")
	T.same({ UI.InsetSize() }, { 990, 515 })
	T.eq(db.settings.frame.w, 1000)
	T.eq(db.settings.frame.h, 601)
	T.same({ UI.Resize(5000, 5000) }, { 1880, 1080 }, "не шире экрана без столбца значков и не выше экрана")
	UI.Resize(814, 426)
	T.no(db.settings.frame.w, "вернули исходный — запись убрана")
	T.no(db.settings.frame.h)
	Errors(c)
end)

T.test("window: уголок меняет размер, после /reload окно того же размера", function()
	local w, c = Build()
	local UI = c.ns.UI
	UI.Toggle("chat")
	local grip, frame = UI.grip, UI.frame
	T.ok(grip, "уголок есть")
	local started
	frame.StartSizing = function(_, point) started = point end
	grip.scripts.OnMouseDown(grip, "RightButton")
	T.no(started, "правая кнопка не тянет")
	grip.scripts.OnMouseDown(grip, "LeftButton")
	T.eq(started, "BOTTOMRIGHT")
	-- Пока игрок тянет, игра шлёт размер каждый кадр.
	frame.scripts.OnSizeChanged(frame, 900, 500)
	frame.scripts.OnSizeChanged(frame, 1100.2, 650.7)
	T.same({ UI.Size() }, { 1100, 651 })
	T.no(c.ns.db.settings.frame.w, "до отпускания размер не записан")
	grip.scripts.OnMouseUp(grip)
	T.eq(c.ns.db.settings.frame.w, 1100)
	T.eq(c.ns.db.settings.frame.h, 651)
	-- Окно закрыли посреди растягивания: размер всё равно записан.
	grip.scripts.OnMouseDown(grip, "LeftButton")
	frame.scripts.OnSizeChanged(frame, 1200, 700)
	frame:Hide()
	T.eq(c.ns.db.settings.frame.w, 1200)
	Errors(c)
	local again = w:Reload(c)
	again.env.UIParent.GetWidth = function() return 1920 end
	again.env.UIParent.GetHeight = function() return 1080 end
	w:Run(5)
	again.ns.UI.Toggle("chat")
	T.same({ again.ns.UI.Size() }, { 1200, 700 }, "размер из сохранений")
	Errors(again)
end)

-- Окно с геометрией: игра после StartSizing и StopMovingOrSizing сама перепривязывает его к
-- ближайшему углу экрана и отмечает поставленным игроком (кэш расположения).
local function Geometry(c, frame)
	local g = { points = {}, size = { 814, 426 }, placed = nil, left = 100, top = 900 }
	c.env.UIParent.GetTop = function() return 1080 end
	frame.GetLeft = function() return g.left end
	frame.GetTop = function() return g.top end
	frame.GetWidth = function() return g.size[1] end
	frame.GetHeight = function() return g.size[2] end
	frame.ClearAllPoints = function() g.points = {} end
	frame.SetPoint = function(_, ...) g.points[#g.points + 1] = { ... } end
	frame.GetPoint = function(_, i)
		local p = g.points[i or 1]
		if p then return p[1], p[2], p[3], p[4], p[5] end
	end
	frame.SetSize = function(_, w, h) g.size = { w, h } end
	frame.SetUserPlaced = function(_, on) g.placed = on end
	local corner = function()
		g.points = { { "BOTTOMRIGHT", c.env.UIParent, "BOTTOMRIGHT", -5, 3 } }
		g.placed = true
	end
	frame.StartMoving, frame.StopMovingOrSizing = corner, corner
	-- Как окно было привязано, когда игра начала растягивание.
	frame.StartSizing = function(_, point)
		local p = g.points[1]
		g.start = { #g.points, p[1], p[3], p[4], p[5], g.size[1], g.size[2], point }
		corner()
	end
	return g
end

local function Pinned(c, g, x, y)
	T.eq(#g.points, 1, "одна точка")
	local p = g.points[1]
	T.ok(p[2] == c.env.UIParent, "к экрану")
	T.same({ p[1], p[3], p[4], p[5] }, { "TOPLEFT", "TOPLEFT", x, y }, "левый верхний угол от верха экрана")
	T.eq(g.placed, false, "кэш расположения игры выключен")
end

T.test("window: окно держится за левый верхний угол, кэш расположения игры выключен", function()
	local _, c = Build()
	local UI = c.ns.UI
	UI.Toggle("chat")
	local grip, frame = UI.grip, UI.frame
	local g = Geometry(c, frame)
	grip.scripts.OnMouseDown(grip, "LeftButton")
	T.same(g.start, { 1, "TOPLEFT", "TOPLEFT", 100, -180, 814, 426, "BOTTOMRIGHT" },
		"тянется правый нижний угол окна, привязанного одной точкой за левый верхний")
	g.size = { 1000, 600 }
	frame.scripts.OnSizeChanged(frame, 1000, 600)
	grip.scripts.OnMouseUp(grip)
	Pinned(c, g, 100, -180)
	T.same(g.size, { 1000, 600 })
	local saved = c.ns.db.settings.frame
	T.same({ saved.point, saved.rel, saved.x, saved.y, saved.w, saved.h }, { "TOPLEFT", "TOPLEFT", 100, -180, 1000, 600 })
	-- Перетаскивание тоже оставляет одну точку и не включает кэш игры.
	g.left, g.top = 300, 800
	frame.scripts.OnDragStart(frame)
	frame.scripts.OnDragStop(frame)
	Pinned(c, g, 300, -280)
	T.same(g.size, { 1000, 600 })
	T.eq(c.ns.db.settings.frame.x, 300)
	Errors(c)
end)

T.test("window: размер, сменившийся без уголка, возвращается и пишется в журнал", function()
	local _, c = Build()
	local UI = c.ns.UI
	UI.Toggle("chat")
	local grip, frame = UI.grip, UI.frame
	local g = Geometry(c, frame)
	grip.scripts.OnMouseDown(grip, "LeftButton")
	g.size = { 1000, 600 }
	frame.scripts.OnSizeChanged(frame, 1000, 600)
	grip.scripts.OnMouseUp(grip)
	frame:Hide()
	frame:Show()
	-- Так выглядела ошибка в игре: окно после нового открытия становилось больше само.
	g.size = { 1798, 1139 }
	frame.scripts.OnSizeChanged(frame, 1798, 1139)
	T.same(g.size, { 1000, 600 }, "прежний размер вернулся")
	T.same({ UI.Size() }, { 1000, 600 })
	T.eq(c.ns.db.settings.frame.w, 1000)
	local log = c.ns.db.log
	T.ok(log[#log]:find("1798x1139 без уголка", 1, true), log[#log])
	-- Ответное OnSizeChanged с прежним размером ничего не меняет.
	frame.scripts.OnSizeChanged(frame, 1000, 600)
	T.same({ UI.Size() }, { 1000, 600 })
	Errors(c)
end)

T.test("window: лишняя ширина делится между колонками по долям, остаток — последней растущей", function()
	local _, c = Build()
	local Widths = c.ns.CensusPane.Widths
	local columns = { { w = 100, grow = 2 }, { w = 50 }, { w = 80, grow = 1 }, { w = 30 } }
	T.same(Widths(columns, 260), { 100, 50, 80, 30 }, "исходная ширина")
	T.same(Widths(columns, 200), { 100, 50, 80, 30 }, "уже исходной колонки не сжимаются")
	T.same(Widths(columns, 360), { 166, 50, 114, 30 }, "две трети и треть, остаток округления — третьей")
end)
