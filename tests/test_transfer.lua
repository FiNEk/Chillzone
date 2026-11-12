-- Кадры (Transfer.lua, TransferPane.lua): просьбы офицерам гильдии исключить или пригласить
-- игрока, ответы по ростеру, права просящего и вкладка «Кадры».
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local NORTH, ORDER, MAIN = "Чиллзон Север", "Орден Чиллзона", "Чиллзон"

-- Три гильдии, как в test_pull: в главной глава Карл (владелец ключа объединения), офицер Арагорн
-- и рядовая Мира; в Севере глава Вера и рядовой Борис; в Ордене глава Глеб и рядовая без аддона.
local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild(MAIN)
	w:Guild(NORTH)
	w:Guild(ORDER)
	w:AddOnline(ORDER, "Тень Тихая-CAMWOWUS2Realm7PvE", 3)
	local cfg = { CHANNEL_CHAT = false }
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = MAIN, rank = 1, config = cfg })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = MAIN, rank = 0, class = "PALADIN", config = cfg })
	c.M = w:Client({ first = "Мира", surname = "Тихая", guild = MAIN, rank = 3, class = "PRIEST", config = cfg })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = NORTH, rank = 2, class = "WARRIOR", config = cfg })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = NORTH, rank = 0, class = "DRUID", config = cfg })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = ORDER, rank = 0, class = "HUNTER", config = cfg })
	w:Run(30)
	w:Init(c.A, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	w:Run(400)
	T.ok(c.K.ns.Data.Row(NORTH), "главная знает отчёт Севера")
	T.ok(c.V.ns.Data.Row(ORDER), "Север знает отчёт Ордена")
	return w, c
end

local function Errors(c)
	for name, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, name .. ": " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, name .. ": глобалы")
	end
end

local function Until(w, check, limit)
	for _ = 1, limit or 60 do
		if check() then return true end
		w:Run(1)
	end
	return check()
end

local function Target(task, cl)
	for _, t in ipairs(task.req and task.req.targets or {}) do
		if cl.ns.Util.SameName(t.name, cl:Name()) then return t end
	end
end

local function Short(cl) return cl.first .. " " .. cl.surname end

T.test("кадры: кодек просьбы, ответа и отзыва", function()
	local w = Wow.World()
	w:Guild(MAIN)
	local cl = w:Client({ first = "Карл", surname = "Великий", guild = MAIN, rank = 0 })
	local Codec = cl.ns.Codec
	local q = { id = "abc.1", kind = "I", guild = NORTH, name = "Борис Быстрый", other = MAIN, fp = "AbCdEfGh_-123456", st = 1700000000 }
	local back = Codec.DecodeTransfer(Codec.EncodeTransfer(q))
	T.same(back, q)
	q.other = nil
	back = Codec.DecodeTransfer(Codec.EncodeTransfer(q))
	T.eq(back.other, nil, "без второй гильдии")
	T.eq(Codec.DecodeTransfer("TQ~1~abc~X~" .. NORTH .. "~Имя~~0~1"), nil, "неизвестный вид")
	T.eq(Codec.DecodeTransfer("TQ~1~" .. ("a"):rep(30) .. "~K~" .. NORTH .. "~Имя~~0~1"), nil, "слишком длинный номер")
	local id, state = Codec.DecodeTransferAnswer(Codec.EncodeTransferAnswer("abc.1", "D"))
	T.eq(id, "abc.1")
	T.eq(state, "D")
	T.eq(Codec.DecodeTransferAnswer("TA~1~abc.1~X"), nil)
	T.eq(Codec.DecodeTransferCancel(Codec.EncodeTransferCancel("abc.1")), "abc.1")
end)

T.test("кадры: права — владелец, офицер главной, глава другой гильдии, рядовые", function()
	local w, c = Build()
	T.eq(c.K.ns.Transfer.Rights(), "owner")
	T.eq(c.A.ns.Transfer.Rights(), "main")
	T.eq(c.V.ns.Transfer.Rights(), "officer")
	T.eq(c.M.ns.Transfer.Rights(), nil)
	T.eq(c.B.ns.Transfer.Rights(), nil)
	T.ok(c.K.ns.Transfer.CanKick(ORDER), "владелец просит любую гильдию")
	T.ok(c.A.ns.Transfer.CanKick(NORTH), "офицер главной просит любую гильдию")
	T.ok(c.V.ns.Transfer.CanKick(NORTH), "из своей — можно")
	T.no(c.V.ns.Transfer.CanKick(ORDER), "из чужой — только главная")
	T.ok(c.V.ns.Transfer.CanMove(NORTH, ORDER), "своего игрока — в другую гильдию")
	T.no(c.V.ns.Transfer.CanMove(ORDER, MAIN), "чужого — нельзя")
	T.ok(c.K.ns.Transfer.CanMove(ORDER, NORTH))
	T.no(c.K.ns.Transfer.CanMove(NORTH, NORTH), "в ту же гильдию — нет")
	T.no(c.K.ns.Transfer.CanKick("Чужая гильдия"), "гильдия вне объединения")
	local _, why = c.V.ns.Transfer.Kick("Тень Тихая", ORDER)
	T.eq(why, c.V.ns.L.TRANSFER_NO_RIGHTS)
	w:Run(5)
	Errors(c)
end)

T.test("кадры: владелец просит исключить из другой гильдии, её глава исключает щелчком", function()
	local w, c = Build()
	local task = c.K.ns.Transfer.Kick(Short(c.B), NORTH)
	T.ok(task, "просьба создана")
	T.eq(#task.req.targets, 1, "адресат — глава Севера по отчёту")
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 1 end), "просьба во входящих Веры")
	T.ok(Until(w, function() return Target(task, c.V).state == "R" end), "Вера подтвердила получение")
	T.ok(c.V:Saw("просит исключить") > 0, "Вера увидела уведомление")
	T.eq(#c.V.uninvites, 0, "сам аддон никого не исключает")
	local item = c.V.ns.Transfer.Incoming()[1]
	T.eq(item.kind, "K")
	T.eq(item.byGuild, MAIN)
	T.ok(c.V.ns.Transfer.Act(item), "щелчок Веры")
	T.eq(c.V.uninvites[1], Short(c.B))
	T.eq(c.B.guild, nil, "Борис вне гильдии")
	T.ok(Until(w, function() return task.phase == "done" end), "владелец получил «сделано»")
	T.eq(task.outcome, "done")
	T.eq(c.V.ns.Transfer.Count(), 0, "входящая просьба закрыта по ростеру")
	Errors(c)
end)

T.test("кадры: просьбы без права отклоняет сам получатель", function()
	local w, c = Build()
	local V, G = c.V.ns, c.G.ns
	local fp = V.Security.MyCertificate().fp
	V.Security.Introduce(c.G:Name())
	local function Ask(kind, other, id)
		V.Comm.Send("WHISPER", V.Codec.EncodeTransfer({ id = id, kind = kind, guild = ORDER, name = "Тень Тихая",
			other = other, fp = fp, st = V.ServerTime() }), { target = c.G:Name() })
	end
	Ask("K", nil, "x.1") -- исключить из чужой гильдии может только главная
	Ask("I", MAIN, "x.2") -- пригласить можно только своего игрока
	w:Run(20)
	T.eq(G.Transfer.Count(), 0, "Глеб ничего не получил")
	T.ok(G.Transfer.stats.rejected >= 2, "обе просьбы отклонены")
	-- Офицер главной вправе просить, а отказ Глеба видит просящий.
	local task = c.A.ns.Transfer.Kick("Тень Тихая", ORDER)
	T.ok(Until(w, function() return G.Transfer.Count() == 1 end), "просьба офицера главной принята")
	T.ok(G.Transfer.Decline(G.Transfer.Incoming()[1]))
	T.ok(Until(w, function() return Target(task, c.G).state == "N" end), "просящий видит отказ")
	T.eq(task.phase, "leave", "просьба не закрыта")
	Errors(c)
end)

T.test("кадры: перенос своего игрока — исключение своим щелчком, приглашение по просьбе", function()
	local w, c = Build()
	local task = c.V.ns.Transfer.Move(Short(c.B), NORTH, ORDER)
	T.ok(task, "перенос начат")
	T.eq(c.V.uninvites[1], Short(c.B), "из своей гильдии Вера исключает сама")
	T.ok(Until(w, function() return task.phase == "join" end), "второй шаг начался по ростеру")
	T.ok(Until(w, function() return c.G.ns.Transfer.Count() == 1 end), "просьба пригласить у Глеба")
	local item = c.G.ns.Transfer.Incoming()[1]
	T.eq(item.kind, "I")
	T.eq(item.other, NORTH)
	T.ok(c.G.ns.Transfer.Act(item))
	T.eq(c.G.invites[1], Short(c.B), "приглашение отправлено щелчком Глеба")
	-- Борис принял приглашение.
	c.B.guild, c.B.rank = ORDER, 3
	c.B:Fire("PLAYER_GUILD_UPDATE", "player")
	c.G.ns.Roster.Scan()
	T.ok(Until(w, function() return task.phase == "done" end), "Вера получила «сделано»")
	T.eq(c.G.ns.Transfer.Count(), 0)
	Errors(c)
end)

T.test("кадры: офицер без права исключать просит офицеров своей гильдии", function()
	local w, c = Build()
	c.A.canRemove = false
	local task = c.A.ns.Transfer.Kick(Short(c.M), MAIN)
	T.ok(task and task.req, "просьба ушла офицерам своей гильдии")
	T.ok(Target(task, c.K), "адресат — глава")
	T.ok(Until(w, function() return c.K.ns.Transfer.Count() == 1 end))
	T.ok(c.K.ns.Transfer.Act(c.K.ns.Transfer.Incoming()[1]))
	T.eq(c.M.guild, nil, "Мира исключена щелчком главы")
	T.ok(Until(w, function() return task.phase == "done" end))
	Errors(c)
end)

T.test("кадры: «игрока нет», отзыв просьбы и предел входящих", function()
	local w, c = Build()
	local absent = c.K.ns.Transfer.Kick("Никто Никакой", NORTH)
	T.ok(Until(w, function() return absent.phase == "done" end), "Вера ответила сразу")
	T.eq(absent.outcome, "absent")
	T.eq(c.V.ns.Transfer.Count(), 0, "во входящие не попало")
	local task = c.K.ns.Transfer.Kick(Short(c.B), NORTH)
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 1 end))
	T.ok(c.K.ns.Transfer.Cancel(task))
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 0 end), "отзыв убрал просьбу у Веры")
	-- Больше TRANSFER_PER_MIN просьб от одного отправителя за минуту не принимается.
	w:Run(61)
	c.V.ns.Config.TRANSFER_PER_MIN = 2
	for i = 1, 3 do w:AddOnline(NORTH, ("Новичок%d Севера-CAMWOWUS2Realm7PvE"):format(i), 3) end
	c.V.ns.Roster.Scan()
	for i = 1, 3 do c.K.ns.Transfer.Kick(("Новичок%d Севера"):format(i), NORTH) end
	w:Run(20)
	T.eq(c.V.ns.Transfer.Count(), 2, "третья просьба за минуту отброшена")
	Errors(c)
end)

T.test("кадры: вкладка — форма с подтверждением и кнопки входящих", function()
	local w, c = Build()
	local P, L = c.K.ns.TransferPane, c.K.ns.L
	c.M.ns.UI.Toggle("transfer")
	T.ok(c.M.ns.UI.Current() ~= "transfer", "рядовой вкладку не видит")
	c.M:Slash("/chillzone", "transfer")
	T.ok(c.M:Saw(c.M.ns.L.TRANSFER_ONLY_OFFICERS) > 0, "команда объясняет почему")
	c.K.ns.UI.Toggle("transfer")
	T.eq(c.K.ns.UI.Current(), "transfer")
	T.ok(P.frames.pane:IsShown())
	P.Fill(Short(c.B), NORTH, nil)
	T.ok(P.frames.kick.enabled, "исключить можно")
	T.no(P.frames.move.enabled, "перенос без второй гильдии недоступен")
	P.frames.kick:Click()
	T.eq(P.frames.kick:GetText(), L.TRANSFER_CONFIRM, "первый щелчок просит подтверждения")
	T.eq(#c.K.ns.Transfer.Tasks(), 0)
	P.frames.kick:Click()
	T.eq(#c.K.ns.Transfer.Tasks(), 1, "второй щелчок создаёт просьбу")
	T.eq(P.frames.message:GetText(), L.TRANSFER_STARTED)
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 1 end))
	-- У Веры просьба — строка с кнопками; исключение тоже со вторым щелчком.
	c.V.ns.UI.Toggle("transfer")
	local row
	for _, r in ipairs(c.V.ns.TransferPane.frames.rows) do
		if r:IsShown() and r.first:IsShown() then row = r end
	end
	T.ok(row, "строка входящей просьбы")
	T.ok(row.first.enabled)
	row.first:Click()
	T.eq(#c.V.uninvites, 0, "первый щелчок только просит подтверждения")
	row.first:Click()
	T.eq(c.V.uninvites[1], Short(c.B))
	T.ok(Until(w, function() return c.K.ns.Transfer.Tasks()[1].phase == "done" end))
	Errors(c)
end)
