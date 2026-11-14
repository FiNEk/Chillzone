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

T.test("window: лишняя ширина делится между колонками по долям, остаток — последней растущей", function()
	local _, c = Build()
	local Widths = c.ns.CensusPane.Widths
	local columns = { { w = 100, grow = 2 }, { w = 50 }, { w = 80, grow = 1 }, { w = 30 } }
	T.same(Widths(columns, 260), { 100, 50, 80, 30 }, "исходная ширина")
	T.same(Widths(columns, 200), { 100, 50, 80, 30 }, "уже исходной колонки не сжимаются")
	T.same(Widths(columns, 360), { 166, 50, 114, 30 }, "две трети и треть, остаток округления — третьей")
end)
