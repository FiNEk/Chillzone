-- Кадры (Transfer.lua, TransferPane.lua, CommandBox.lua): просьбы офицерам гильдии исключить или
-- пригласить игрока, команды /gremove и /ginvite, которые игрок вводит сам, итог по системным
-- строкам гильдии и ростеру, права просящего, состав гильдии и очередь исключения.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local NORTH, ORDER, MAIN = "Чиллзон Север", "Орден Чиллзона", "Чиллзон"
local REALM = "-CAMWOWUS2Realm7PvE"

-- Три гильдии, как в test_pull: в главной глава Карл (владелец ключа объединения), офицер Арагорн
-- и рядовая Мира; в Севере глава Вера и рядовой Борис; в Ордене глава Глеб и рядовая без аддона.
local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild(MAIN)
	w:Guild(NORTH)
	w:Guild(ORDER)
	w:AddOnline(ORDER, "Тень Тихая" .. REALM, 3)
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
		T.eq(#cl.forbidden, 0, name .. ": вызов, запрещённый игрой: " .. table.concat(cl.forbidden, " | "))
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

local function Has(text, part) return type(text) == "string" and text:find(part, 1, true) ~= nil end

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

T.test("кадры: системные строки гильдии, форматы с номерами аргументов и команды", function()
	local w = Wow.World()
	w:Guild(NORTH)
	local cl = w:Client({ first = "Вера", surname = "Верная", guild = NORTH, rank = 0 })
	w:Run(5)
	local R = cl.ns.Roster
	local args = R.MatchFormat("Вера Верная: из гильдии исключён Борис Быстрый.", "%2$s: из гильдии исключён %1$s.")
	T.eq(args[1], "Борис Быстрый", "первый аргумент формата")
	T.eq(args[2], "Вера Верная", "второй аргумент формата")
	T.eq(R.MatchFormat("100% (X)", "100%% (%s)")[1], "X", "%% и скобки — обычные знаки")
	T.eq(R.MatchFormat("Другая строка.", "%s has left the guild."), nil)
	T.eq(R.MatchFormat("уровень 12", "уровень %d")[1], "12")
	T.eq(R.PlainName("|Hplayer:Борис Быстрый|h[Борис Быстрый]|h"), "Борис Быстрый", "ссылка игрока")
	T.eq(R.PlainName("|cffffffff[Борис Быстрый]|r"), "Борис Быстрый", "цвет и скобки")
	local what, name = R.GuildEvent("|Hplayer:Борис Быстрый|h[Борис Быстрый]|h has joined the guild.")
	T.eq(what, "joined")
	T.eq(name, "Борис Быстрый")
	what, name = R.GuildEvent("Борис Быстрый has been kicked out of the guild by Вера Верная.")
	T.eq(what, "left", "исключён")
	T.eq(name, "Борис Быстрый", "имя исключённого, не того, кто исключил")
	T.eq((R.GuildEvent("Борис Быстрый has left the guild.")), "left", "ушёл сам")
	T.eq(R.GuildEvent("Вера Верная has joined the guild."), nil, "строка о себе")
	T.eq(R.GuildEvent("Что-то другое."), nil)
	-- В переводе игры порядок аргументов бывает другим.
	cl.env.ERR_GUILD_REMOVE_SS = "%2$s исключает из гильдии: %1$s."
	what, name = R.GuildEvent("Вера Верная исключает из гильдии: Борис Быстрый.")
	T.eq(what, "left")
	T.eq(name, "Борис Быстрый")
	T.eq(R.GuildCommand("K", "Борис Быстрый" .. REALM), "/gremove Борис Быстрый", "без реалма")
	T.eq(R.GuildCommand("I", "Борис Быстрый"), "/ginvite Борис Быстрый")
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

T.test("кадры: владелец просит исключить из другой гильдии, её глава вводит команду", function()
	local w, c = Build()
	local task = c.K.ns.Transfer.Kick(Short(c.B), NORTH)
	T.ok(task, "просьба создана")
	T.eq(#task.req.targets, 1, "адресат — глава Севера по отчёту")
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 1 end), "просьба во входящих Веры")
	T.ok(Until(w, function() return Target(task, c.V).state == "R" end), "Вера подтвердила получение")
	T.ok(c.V:Saw("просит исключить") > 0, "Вера увидела уведомление")
	local item = c.V.ns.Transfer.Incoming()[1]
	T.eq(item.kind, "K")
	T.eq(item.byGuild, MAIN)
	local command = c.V.ns.Transfer.Act(item)
	T.eq(command, "/gremove " .. Short(c.B), "щелчок Веры даёт команду")
	T.eq(c.B.guild, NORTH, "сам аддон никого не исключает")
	T.ok(item.tried)
	c.V:GuildCommand(command)
	T.eq(c.B.guild, nil, "Борис вне гильдии")
	T.ok(Until(w, function() return task.phase == "done" end), "владелец получил «сделано»")
	T.eq(task.outcome, "done")
	T.eq(c.V.ns.Transfer.Count(), 0, "входящая просьба закрыта по сообщению гильдии")
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

T.test("кадры: перенос своего игрока — своя команда исключения, приглашение по просьбе", function()
	local w, c = Build()
	local V = c.V.ns
	local task = V.Transfer.Move(Short(c.B), NORTH, ORDER)
	T.ok(task, "перенос начат")
	T.ok(task.localStep, "из своей гильдии Вера исключает сама")
	T.eq(c.B.guild, NORTH, "аддон сам не исключает")
	local kind, command = V.Transfer.Step(task)
	T.eq(kind, "K")
	T.eq(command, "/gremove " .. Short(c.B))
	c.V:GuildCommand(command)
	T.ok(Until(w, function() return task.phase == "join" end), "второй шаг начался по сообщению гильдии")
	T.ok(Until(w, function() return c.G.ns.Transfer.Count() == 1 end), "просьба пригласить у Глеба")
	local item = c.G.ns.Transfer.Incoming()[1]
	T.eq(item.kind, "I")
	T.eq(item.other, NORTH)
	command = c.G.ns.Transfer.Act(item)
	T.eq(command, "/ginvite " .. Short(c.B))
	T.ok(c.G:GuildCommand(command))
	T.eq(c.G.invites[1], Short(c.B), "Глеб пригласил своей командой")
	-- Борис принял приглашение.
	w:Join(ORDER, c.B, 3)
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
	c.K:GuildCommand(c.K.ns.Transfer.Act(c.K.ns.Transfer.Incoming()[1]))
	T.eq(c.M.guild, nil, "Мира исключена командой главы")
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
	for i = 1, 3 do w:AddOnline(NORTH, ("Новичок%d Севера" .. REALM):format(i), 3) end
	c.V.ns.Roster.Scan()
	for i = 1, 3 do c.K.ns.Transfer.Kick(("Новичок%d Севера"):format(i), NORTH) end
	w:Run(20)
	T.eq(c.V.ns.Transfer.Count(), 2, "третья просьба за минуту отброшена")
	Errors(c)
end)

T.test("кадры: раздел «Управления» — просьба со вторым щелчком, команда в своём поле", function()
	local w, c = Build()
	local P, L = c.K.ns.TransferPane, c.K.ns.L
	c.M.ns.UI.Toggle("transfer")
	T.ok(c.M.ns.UI.Current() ~= "transfer", "рядовой раздел не видит")
	c.M:Slash("/chillzone", "transfer")
	T.ok(c.M:Saw(c.M.ns.L.TRANSFER_ONLY_OFFICERS) > 0, "команда объясняет почему")
	c.K.ns.UI.Toggle("transfer")
	T.eq(c.K.ns.UI.Current(), "transfer")
	T.ok(c.K.ns.UI.tabs.manage:GetChecked(), "«Кадры» — раздел «Управления»")
	T.ok(c.K.ns.UI.switcher:IsShown(), "переключатель разделов на месте названия")
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
	T.no(P.frames.box:IsShown(), "просьба офицерам — без команды у просящего")
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 1 end))
	-- У Веры просьба — строка с кнопками. Число просьб — на переключателе.
	c.V.ns.UI.Toggle("transfer")
	local VP = c.V.ns.TransferPane.frames
	local section = c.V.ns.UI.sections.transfer
	T.eq(section.text:GetText(), L.TAB_TRANSFER_COUNT:format(1), "число просьб на кнопке раздела")
	local row
	for _, r in ipairs(VP.rows) do
		if r:IsShown() and r.first:IsShown() then row = r end
	end
	T.ok(row, "строка входящей просьбы")
	T.ok(row.first.enabled)
	row.first:Click()
	T.ok(VP.box:IsShown(), "щелчок показывает команду")
	T.eq(VP.box:Command(), "/gremove " .. Short(c.B))
	T.ok(VP.box.edit:HasFocus(), "команда выделена для копирования")
	T.no(VP.box.skip:IsShown(), "одна команда — пропускать нечего")
	T.no(VP.message:IsShown(), "поле команды на месте строки о правах")
	T.eq(c.B.guild, NORTH, "сам аддон не исключает")
	-- Поле только для чтения: набранное заменяется командой.
	VP.box.edit:SetText("/gremove Кто-то Другой")
	VP.box.edit:GetScript("OnTextChanged")(VP.box.edit, true)
	T.eq(VP.box.edit:GetText(), "/gremove " .. Short(c.B))
	c.V:GuildCommand(VP.box:Command())
	T.ok(Until(w, function() return not VP.box:IsShown() end), "сообщение гильдии убрало команду")
	T.ok(Until(w, function() return c.K.ns.Transfer.Tasks()[1].phase == "done" end))
	T.ok(Until(w, function() return c.V.ns.Transfer.Count() == 0 end))
	T.eq(section.text:GetText(), L.TAB_TRANSFER, "после решения числа на кнопке нет")
	T.ok(VP.message:IsShown())
	Errors(c)
end)

T.test("кадры: состав гильдии — давность входа, отметки и очередь команд", function()
	local w, c = Build()
	w:AddOffline(NORTH, "Старик Давний" .. REALM, 3, 60, "MAGE", 90)
	w:AddOffline(NORTH, "Сонный Ленивый" .. REALM, 3, 40, "ROGUE", 45)
	w:AddOffline(NORTH, "Свежий Новый" .. REALM, 3, 20, "PRIEST", 2)
	local V, L = c.V.ns, c.V.ns.L
	V.Roster.Scan()
	V.UI.Toggle("transfer")
	local f = V.TransferPane.frames
	T.ok(f.tools:IsShown(), "панель отметок")
	T.ok(f.head:IsShown(), "заголовок таблицы")
	T.no(f.tools.showAll:IsShown(), "ростер полный — показывать всех не нужно")
	T.ok(Has(f.members[1].cells[1]:GetText(), "Старик Давний"), "дольше всех не заходивший — сверху")
	T.eq(f.members[1].cells[4]:GetText(), L.TRANSFER_DAYS:format(90))
	local selfRow
	for _, r in ipairs(f.members) do
		if r:IsShown() and r.person and V.IsMe(r.person.name) then selfRow = r end
	end
	T.ok(selfRow, "своя строка в составе")
	T.no(selfRow.check.enabled, "себя отметить нельзя")
	-- Щелчок по строке подставляет игрока в форму.
	f.members[1]:Click()
	T.eq(f.input:GetText(), "Старик Давний")
	-- Сортировка по имени и обратно.
	f.head.cells[1]:Click()
	T.ok(Has(f.members[1].cells[1]:GetText(), "Борис Быстрый"), "по имени")
	f.head.cells[1]:Click()
	T.ok(Has(f.members[1].cells[1]:GetText(), "Старик Давний"), "по имени в обратном порядке")
	f.head.cells[4]:Click()
	-- Отметить не заходивших дольше 30 дней.
	f.tools.days:SetText("30")
	f.tools.mark:Click()
	T.eq(f.tools.kick:GetText(), L.TRANSFER_KICK_CHECKED:format(2))
	T.ok(f.tools.kick.enabled)
	f.tools.kick:Click()
	T.ok(f.box:IsShown(), "очередь команд")
	T.eq(f.box:Command(), "/gremove Старик Давний")
	T.ok(Has(f.box.title:GetText(), L.TRANSFER_QUEUE_PROGRESS:format(1, 2)))
	T.ok(f.box.skip:IsShown())
	c.V:GuildCommand(f.box:Command())
	T.ok(Until(w, function() return f.box:Command() == "/gremove Сонный Ленивый" end),
		"следующая команда — после сообщения гильдии")
	T.ok(Has(f.box.title:GetText(), L.TRANSFER_QUEUE_PROGRESS:format(2, 2)))
	T.eq(f.tools.kick:GetText(), L.TRANSFER_KICK_CHECKED:format(1), "исключённый снят с отметок")
	f.box.skip:Click()
	T.no(f.box:IsShown(), "очередь закончилась")
	T.eq(f.message:GetText(), L.TRANSFER_QUEUE_DONE:format(1, 2))
	T.eq(f.tools.kick:GetText(), L.TRANSFER_KICK_CHECKED:format(1), "пропущенный остался отмеченным")
	f.tools.unmark:Click()
	T.eq(f.tools.kick:GetText(), L.TRANSFER_KICK_CHECKED:format(0))
	T.no(f.tools.kick.enabled)
	-- Длинный состав: строк таблицы немного, прокрутка переставляет их на видимую часть.
	for i = 1, 40 do w:AddOffline(NORTH, ("Игрок%02d Севера" .. REALM):format(i), 3, 30, "MAGE", 100 + i) end
	V.Roster.Scan()
	T.ok(Has(f.members[1].cells[1]:GetText(), "Игрок40 Севера"), "сверху дольше всех не заходивший")
	f.scroll:SetVerticalScroll(f.peopleTop() + 10 * 18)
	local top
	for _, r in ipairs(f.members) do
		if r:IsShown() and (not top or r.index < top.index) then top = r end
	end
	T.ok(Has(top.cells[1]:GetText(), "Игрок30 Севера"), "после прокрутки на 10 строк")
	Errors(c)
end)

T.test("кадры: неполный ростер — исключение засчитывает только сообщение гильдии", function()
	local w, c = Build()
	w:AddOffline(NORTH, "Старик Давний" .. REALM, 3, 60, "MAGE", 90)
	c.V.hideOffline = true
	local V, L = c.V.ns, c.V.ns.L
	V.Roster.Scan()
	T.no(V.Roster.complete, "игроки не в сети скрыты")
	V.UI.Toggle("transfer")
	local f = V.TransferPane.frames
	local partial = false
	for _, h in ipairs(f.headers) do
		if h:IsShown() and Has(h.label:GetText(), L.TRANSFER_ROSTER_PARTIAL) then partial = true end
	end
	T.ok(partial, "заголовок состава предупреждает о скрытых")
	T.ok(f.tools.showAll:IsShown())
	-- Из своей гильдии — без второго щелчка: просьба никуда не уходит, команда сразу в поле.
	V.TransferPane.Fill(Short(c.B), NORTH, nil)
	f.kick:Click()
	T.ok(f.box:IsShown(), "своя команда сразу")
	T.eq(f.box:Command(), "/gremove " .. Short(c.B))
	local task = V.Transfer.Tasks()[1]
	T.ok(task and task.localStep)
	-- Бориса нет в неполном ростере, но системной строки не было: ничего не засчитано.
	w:Uninvite(NORTH, Short(c.B))
	V.Roster.Scan()
	w:Run(5)
	T.eq(task.phase, "leave", "отсутствие в неполном ростере ничего не доказывает")
	T.ok(f.box:IsShown(), "команда ещё ждёт")
	w:GuildSystem(NORTH, c.V.env.ERR_GUILD_REMOVE_SS:format(Short(c.B), c.V:Name()))
	T.ok(Until(w, function() return task.phase == "done" end), "сообщение гильдии закрыло шаг")
	T.no(f.box:IsShown())
	-- «Показать всех» — та же настройка, что в окне гильдии.
	f.tools.showAll:Click()
	T.ok(Until(w, function() return V.Roster.complete end), "ростер снова полный")
	T.no(f.tools.showAll:IsShown())
	Errors(c)
end)
