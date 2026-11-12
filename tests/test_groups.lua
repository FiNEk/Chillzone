-- Поиск групп: формат объявлений и заявок, доска в своей и чужой гильдии, заявки,
-- приглашения, сроки, запрос объявлений после входа.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local function codec()
	return T.load({ "Config.lua", "Util.lua", "Codec.lua" }).Codec
end

local function listing()
	return {
		mode = "G", id = 1794412800, guild = "Чиллзон Север", class = "PALADIN", level = 23, kind = "D",
		roles = { t = 1, h = 0, d = 2 }, size = 2, cap = 5, min = 18, every = 5,
		title = "Мёртвые копи", note = "идём до конца, без спешки",
	}
end

T.test("groups codec: объявление читается обратно", function()
	local Codec = codec()
	local msg = Codec.EncodeGroup(listing())
	T.ok(msg and #msg <= 255, "сообщение собрано")
	T.same(Codec.DecodeGroup(msg), listing())
	T.eq(Codec.InnerType(msg), "G1", "реле узнаёт тип")
end)

T.test("groups codec: название — любой текст, но без разметки и разделителей", function()
	local Codec = codec()
	local l = listing()
	l.title = "  Случайное   приключение: ловим |cffff0000рыбу|r ~ и бьём = босса  "
	local d = Codec.DecodeGroup(Codec.EncodeGroup(l))
	T.no(d.title:find("[|~]"), "ни | ни ~")
	T.ok(d.title:find("Случайное приключение: ловим", 1, true), "текст автора сохранён")
	T.ok(#d.title <= Codec.GROUP_TITLE, "длина ограничена")
	-- Длинное название режется по букве, а не посередине.
	l.title = ("Ю"):rep(60)
	d = Codec.DecodeGroup(Codec.EncodeGroup(l))
	T.eq(d.title, ("Ю"):rep(32))
end)

T.test("groups codec: сообщение всегда умещается в 255 байт", function()
	local Codec = codec()
	local l = listing()
	l.guild = ("Щ"):rep(24)
	l.title, l.note = ("Ж"):rep(40), ("я"):rep(90)
	local msg = Codec.EncodeGroup(l)
	T.ok(msg and #msg <= 255, "уместилось")
	local d = Codec.DecodeGroup(msg)
	T.eq(d.title, ("Ж"):rep(32))
	T.ok(#d.note > 0 and #d.note % 2 == 0, "примечание укорочено по букве")
end)

T.test("groups codec: игрок ищет группу и снятие объявления", function()
	local Codec = codec()
	local l = listing()
	l.mode, l.title, l.roles, l.cap, l.size = "P", "", { t = 0, h = 1, d = 1 }, 0, 1
	local d = Codec.DecodeGroup(Codec.EncodeGroup(l))
	T.eq(d.mode, "P")
	T.eq(d.title, "", "у игрока название необязательно")
	T.same(d.roles, { t = 0, h = 1, d = 1 })
	T.same(Codec.DecodeGroup(Codec.EncodeGroup({ mode = "X", id = 1794412800, guild = "Чиллзон" })),
		{ mode = "X", id = 1794412800, guild = "Чиллзон" })
end)

T.test("groups codec: мусор не читается", function()
	local Codec = codec()
	local l = listing()
	l.title = ""
	T.no(Codec.EncodeGroup(l), "группа без названия")
	T.no(Codec.DecodeGroup("G1~G~0~Чиллзон~PA~23~D~1.0.2~2~5~18~5~Копи~"), "номер 0")
	T.no(Codec.DecodeGroup("G1~Z~1794412800~Чиллзон~PA~23~D~1.0.2~2~5~18~5~Копи~"), "незнакомый режим")
	T.no(Codec.DecodeGroup("G1~G~1794412800~Чиллзон~PA~23~D~1.0~2~5~18~5~Копи~"), "роли не тройкой")
	T.no(Codec.DecodeGroup("G1~G~1794412800~Чиллзон~PA~23~D~1.0.2~2~5~18~5~~"), "пустое название группы")
	T.no(Codec.DecodeGroup(("G1~G~1794412800~Чиллзон~PA~23~D~1.0.2~2~5~18~5~Копи~" .. ("x"):rep(300))), "слишком длинно")
	-- Незнакомый вид места и поля следующих версий объявление не ломают.
	local d = Codec.DecodeGroup("G1~G~1794412800~Чиллзон~PA~23~Z~1.0.2~2~5~18~5~Копи~заметка~новое поле")
	T.eq(d.kind, "O")
	T.eq(d.note, "заметка")
end)

T.test("groups codec: заявка, отзыв и ответ", function()
	local Codec = codec()
	local msg = Codec.EncodeGroupApply(1794412800, "abcdefgh12345678", "Чиллзон", "DRUID", 22, { t = 0, h = 1, d = 1 }, "могу | лечить ~ и бить")
	local a = Codec.DecodeGroupApply(msg)
	T.eq(a.id, 1794412800)
	T.eq(a.fp, "abcdefgh12345678")
	T.eq(a.guild, "Чиллзон")
	T.eq(a.class, "DRUID")
	T.eq(a.level, 22)
	T.same(a.roles, { t = 0, h = 1, d = 1 })
	T.eq(a.note, "могу лечить и бить")
	T.eq(Codec.DecodeGroupWithdraw(Codec.EncodeGroupWithdraw(1794412800)), 1794412800)
	local id, answer = Codec.DecodeGroupReply(Codec.EncodeGroupReply(1794412800, "I"))
	T.eq(id, 1794412800)
	T.eq(answer, "I")
	T.no(Codec.DecodeGroupReply("GR~1794412800~Z"), "незнакомый ответ")
	T.no(Codec.DecodeGroupApply("GA~1794412800~abc"), "обрывок заявки")
end)

---------------------------------------------------------------------------
-- Мир: две гильдии объединения
---------------------------------------------------------------------------
local function Build()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	local c = {}
	c.A = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24 })
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, class = "PALADIN", level = 60 })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, class = "DRUID", level = 22 })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 1, class = "PRIEST", level = 21 })
	w:Run(30)
	w:Init(c.A, c.V)
	w:Pair(c.V, c.K)
	w:Run(400)
	return w, c
end

local function Spec(over)
	local spec = {
		mode = "G", kind = "D", title = "Мёртвые копи", note = "без спешки",
		roles = { t = 0, h = 1, d = 2 }, cap = 5, min = 18,
	}
	for k, v in pairs(over or {}) do spec[k] = v end
	return spec
end

-- Объявление автора на доске клиента или nil.
local function Seen(viewer, author)
	return viewer.ns.Groups.Get(viewer.ns.Util.Key(author:Name()))
end

local function Key(c)
	return c.ns.Util.Key(c:Name())
end

-- Подписанные пакеты объявлений, которые клиент отправил в гильдию.
local function Capture(c)
	local wires, send = {}, c.ns.Comm.Send
	c.ns.Comm.Send = function(dist, payload, opts)
		if dist == "GUILD" and payload:find("~G1~", 1, true) and payload:sub(1, 2) == "S1" then wires[#wires + 1] = payload end
		return send(dist, payload, opts)
	end
	return wires
end

T.test("groups: объявление видят своя гильдия и чужая через реле", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()), "размещено")
	w:Run(30)
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		local e = Seen(viewer, c.A)
		T.ok(e, viewer:Name() .. " видит объявление")
		T.eq(e.title, "Мёртвые копи")
		T.eq(e.note, "без спешки")
		T.eq(e.guild, "Чиллзон")
		T.eq(e.name, "Арагорн Светлый")
		T.eq(e.class, "WARRIOR")
		T.eq(e.level, 24)
		T.same(e.roles, { t = 0, h = 1, d = 2 })
		T.eq(e.size, 1)
		T.eq(e.cap, 5)
		T.eq(e.min, 18)
	end
	T.no(Seen(c.A, c.A), "своё объявление на доску не попадает")
	T.eq(c.A.ns.Groups.Mine().title, "Мёртвые копи")
	local groups, players = c.V.ns.Groups.List()
	T.eq(#groups, 1)
	T.eq(#players, 0)
	T.eq(#c.V.ns.Groups.List("R"), 0, "фильтр по виду места")
	T.eq(c.V.ns.Groups.Count(), 1)
	T.eq(#c.A:Leaks(), 0, "глобалов нет")
end)

T.test("groups: название — свободный текст", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec({ kind = "O", title = "Ловим рыбу в Пиратской бухте и поём", roles = { t = 0, h = 0, d = 0 } })))
	w:Run(30)
	local e = Seen(c.V, c.A)
	T.eq(e.title, "Ловим рыбу в Пиратской бухте и поём")
	T.eq(e.kind, "O")
	T.same(e.roles, { t = 0, h = 0, d = 0 })
end)

T.test("groups: снятое объявление пропадает, старый пакет его не возвращает", function()
	local w, c = Build()
	local wires = Capture(c.A)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.ok(Seen(c.K, c.A) and Seen(c.V, c.A), "объявление на досках")
	T.ok(c.A.ns.Groups.Lower())
	w:Run(30)
	T.no(Seen(c.K, c.A), "своя гильдия")
	T.no(Seen(c.V, c.A), "чужая гильдия")
	T.no(c.A.ns.Groups.Mine())
	-- Тот же подписанный пакет, присланный ещё раз, остаётся снятым.
	T.ok(wires[1], "пакет объявления пойман")
	c.K.ns.Comm.Dispatch(wires[1], "Арагорн Светлый-" .. c.A.realm, "GUILD")
	w:Run(5)
	T.no(Seen(c.K, c.A), "повтор старого пакета не вернул объявление")
	T.ok(c.K.ns.Groups.stats.stale > 0, "повтор отброшен как устаревший")
end)

T.test("groups: неподписанное объявление не принимается", function()
	local w, c = Build()
	local msg = c.A.ns.Codec.EncodeGroup({
		mode = "G", id = c.A.env.GetServerTime(), guild = "Чиллзон", class = "WARRIOR", level = 24, kind = "D",
		roles = { t = 1, h = 1, d = 3 }, size = 1, cap = 5, min = 0, every = 5, title = "Подделка", note = "",
	})
	c.K.ns.Comm.Dispatch(msg, "Арагорн Светлый-" .. c.A.realm, "GUILD")
	w:Run(5)
	T.no(Seen(c.K, c.A))
end)

T.test("groups: заявка, приглашение и вход в группу", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec({ roles = { t = 0, h = 1, d = 3 } })))
	w:Run(30)
	local ok, why = c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 }, "лечу деревом")
	T.ok(ok, "заявка ушла: " .. tostring(why))
	T.eq(Seen(c.V, c.A) and c.V.ns.Groups.List()[1].applied, "sent")
	w:Run(15)
	local list = c.A.ns.Groups.Applicants()
	T.eq(#list, 1, "заявка дошла")
	T.eq(list[1].name, "Вера Верная")
	T.eq(list[1].guild, "Чиллзон Север", "гильдия из сертификата")
	T.eq(list[1].class, "DRUID")
	T.eq(list[1].level, 22)
	T.same(list[1].roles, { t = 0, h = 1, d = 0 })
	T.eq(list[1].note, "лечу деревом")
	T.ok(c.A:Saw("Вера Верная") > 0, "автору сказано о заявке")
	-- Повторная заявка на то же объявление не уходит.
	local again, reason = c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 })
	T.no(again)
	T.eq(reason, "already")
	T.ok(c.A:Hardware(c.A.ns.Groups.Invite, Key(c.V)), "приглашение")
	T.eq(c.A.partyInvites[1], "Вера Верная")
	w:Run(10)
	T.eq(c.V.ns.Groups.List()[1].applied, "invited")
	T.ok(c.V:Saw("Арагорн Светлый") > 0, "просящему сказано о приглашении")
	-- Вера вошла: её роль больше не нужна, размер группы обновляется у всех.
	c.A.party = { c.V }
	c.A:Fire("GROUP_ROSTER_UPDATE")
	w:Run(40)
	T.eq(#c.A.ns.Groups.Applicants(), 0, "вошедший убран из заявок")
	T.same(c.A.ns.Groups.Mine().roles, { t = 0, h = 0, d = 3 })
	local e = Seen(c.B, c.A)
	T.eq(e.size, 2)
	T.same(e.roles, { t = 0, h = 0, d = 3 })
end)

T.test("groups: отказ и отзыв заявки", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.ok(c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 }))
	T.ok(c.B.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 1 }))
	w:Run(15)
	T.eq(#c.A.ns.Groups.Applicants(), 2)
	T.ok(c.B.ns.Groups.Withdraw(Key(c.A)), "Борис передумал")
	T.ok(c.A.ns.Groups.Decline(Key(c.V)), "Вере отказано")
	w:Run(15)
	T.eq(#c.A.ns.Groups.Applicants(), 0)
	T.eq(c.V.ns.Groups.List()[1].applied, "declined")
	T.no(c.B.ns.Groups.List()[1].applied, "отозванная заявка не числится")
	-- После отказа заявка этого игрока на то же объявление не принимается.
	local ok, why = c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 })
	T.no(ok)
	T.eq(why, "already")
	T.eq(#c.A.partyInvites, 0, "никого не пригласили")
end)

T.test("groups: заявка без ролей и ниже уровня не уходит", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec({ min = 23 })))
	w:Run(30)
	local ok, why = c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 0, d = 0 })
	T.no(ok)
	T.eq(why, "roles")
	ok, why = c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 })
	T.no(ok)
	T.eq(why, "level")
	T.ok(c.V.ns.Groups.List()[1].short, "вкладка знает, что уровня не хватает")
	w:Run(15)
	T.eq(#c.A.ns.Groups.Applicants(), 0)
end)

T.test("groups: заявку принимают только на текущее объявление", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	local mine = c.V.ns.Security.MyCertificate()
	local stale = c.V.ns.Codec.EncodeGroupApply(c.A.ns.Groups.Mine().id - 100, mine.fp, "Чиллзон Север", "DRUID", 22, { t = 0, h = 1, d = 0 }, "")
	c.V.ns.Comm.Send("WHISPER", stale, { target = "Арагорн Светлый" })
	w:Run(15)
	T.eq(#c.A.ns.Groups.Applicants(), 0)
end)

T.test("groups: игрок ищет группу, его приглашают щелчком", function()
	local w, c = Build()
	local ok, why = c.B.ns.Groups.Raise({ mode = "P", kind = "D", title = "любые подземелья", roles = { t = 0, h = 1, d = 1 } })
	T.ok(ok, tostring(why))
	w:Run(30)
	local groups, players = c.A.ns.Groups.List()
	T.eq(#groups, 0)
	T.eq(#players, 1)
	T.eq(players[1].name, "Борис Быстрый")
	T.eq(players[1].class, "PRIEST")
	T.eq(players[1].level, 21)
	T.same(players[1].roles, { t = 0, h = 1, d = 1 })
	T.eq(players[1].title, "любые подземелья")
	T.ok(c.A:Hardware(c.A.ns.Groups.InvitePlayer, Key(c.B)))
	T.eq(c.A.partyInvites[1], "Борис Быстрый")
	-- Вошёл в группу: объявление снимается само.
	c.B.party, c.B.partyLeader = { c.A }, false
	c.B:Fire("GROUP_ROSTER_UPDATE")
	w:Run(30)
	T.no(c.B.ns.Groups.Mine())
	T.no(Seen(c.A, c.B), "объявление снято у остальных")
	T.no(Seen(c.V, c.B), "и в своей гильдии")
end)

T.test("groups: без ролей «ищу группу» не размещается, участник чужой группы не собирает свою", function()
	local _, c = Build()
	local ok, why = c.B.ns.Groups.Raise({ mode = "P", title = "что угодно", roles = { t = 0, h = 0, d = 0 } })
	T.no(ok)
	T.eq(why, "roles")
	ok, why = c.B.ns.Groups.Raise(Spec({ title = "" }))
	T.no(ok)
	T.eq(why, "title")
	c.B.party, c.B.partyLeader = { c.V }, false
	ok, why = c.B.ns.Groups.Raise(Spec())
	T.no(ok)
	T.eq(why, "notleader")
	ok, why = c.B.ns.Groups.Raise({ mode = "P", roles = { t = 0, h = 1, d = 0 } })
	T.no(ok)
	T.eq(why, "ingroup")
end)

T.test("groups: полная группа снимает объявление", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec({ cap = 3 })))
	w:Run(30)
	c.A.party = { c.K, c.V }
	c.A:Fire("GROUP_ROSTER_UPDATE")
	w:Run(30)
	T.no(c.A.ns.Groups.Mine())
	T.no(Seen(c.B, c.A))
	T.ok(c.A:Saw("Группа собрана") > 0, "автору сказано, почему объявление снято")
end)

T.test("groups: правка сохраняет объявление и заявки, новое размещение ждёт", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	local id = c.A.ns.Groups.Mine().id
	T.ok(c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 }))
	w:Run(15)
	T.ok(c.A.ns.Groups.Raise(Spec({ title = "Мёртвые копи, героик", roles = { t = 1, h = 1, d = 1 } })), "правка")
	w:Run(30)
	T.eq(c.A.ns.Groups.Mine().id, id, "номер объявления прежний")
	T.eq(#c.A.ns.Groups.Applicants(), 1, "заявки остались")
	local e = Seen(c.V, c.A)
	T.eq(e.title, "Мёртвые копи, героик")
	T.same(e.roles, { t = 1, h = 1, d = 1 })
	T.eq(c.V.ns.Groups.List()[1].applied, "sent", "заявка всё ещё к этому объявлению")
	-- Автор сам правит нужные роли: правка уходит с задержкой, а не на каждый щелчок.
	c.A.ns.Groups.SetNeed("d", 0)
	c.A.ns.Groups.SetNeed("t", 0)
	w:Run(40)
	T.same(Seen(c.B, c.A).roles, { t = 0, h = 1, d = 0 })
	-- Новое объявление сразу после прежнего разместить нельзя.
	T.ok(c.A.ns.Groups.Lower())
	T.ok(c.A.ns.Groups.Raise(Spec({ title = "Другое место" })), "с прошлого размещения прошло больше полминуты")
	T.ok(c.A.ns.Groups.Lower())
	local ok, why, wait = c.A.ns.Groups.Raise(Spec())
	T.no(ok)
	T.eq(why, "wait")
	T.ok(wait and wait > 0, "известно, сколько ждать")
end)

T.test("groups: объявление повторяется, а после выхода автора пропадает", function()
	local w, c = Build()
	local wires = Capture(c.A)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.eq(#wires, 1)
	w:Run(6 * 60)
	T.ok(#wires >= 2, "автор повторил объявление")
	T.ok(Seen(c.V, c.A), "на доске оно держится")
	c.A:Logout()
	w:Run(10 * 60)
	T.ok(Seen(c.V, c.A), "два повтора ещё не прошли")
	w:Run(4 * 60)
	T.no(Seen(c.V, c.A), "автор молчит дольше двух повторов")
	T.no(Seen(c.K, c.A))
end)

T.test("groups: объявление снимается через час", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(59 * 60)
	T.ok(c.A.ns.Groups.Mine(), "час ещё не прошёл")
	T.ok(Seen(c.V, c.A))
	w:Run(2 * 60)
	T.no(c.A.ns.Groups.Mine())
	T.no(Seen(c.V, c.A))
	T.ok(c.A:Saw("Объявление снято") > 0, "автору сказано")
end)

T.test("groups: вошедший позже получает объявления своей и чужой гильдии", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	T.ok(c.B.ns.Groups.Raise({ mode = "P", title = "куда позовут", roles = { t = 0, h = 1, d = 0 } }))
	w:Run(60)
	-- Новый участник главной гильдии: объявление А — от самого автора, объявление Б — от репортёра.
	local late = w:Client({ first = "Леголас", surname = "Зоркий", guild = "Чиллзон", rank = 3, class = "HUNTER" })
	w:Run(200)
	T.ok(late.ns.Security.MyCertificate(), "новичок получил сертификат")
	T.ok(Seen(late, c.A), "объявление согильдийца")
	T.ok(Seen(late, c.B), "объявление чужой гильдии от репортёра")
	T.eq(Seen(late, c.B).title, "куда позовут")
end)

T.test("groups: объявление и заявки переживают перезагрузку интерфейса", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.ok(c.V.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 }))
	w:Run(15)
	local id, db = c.A.ns.Groups.Mine().id, c.A.ns.db
	c.A.ns.Groups.SetRole("t", true)
	c.A:Logout()
	local again = w:Client({ first = "Арагорн", surname = "Светлый", guild = "Чиллзон", rank = 1, class = "WARRIOR", level = 24, db = db, reload = true })
	T.eq(again.ns.Groups.Mine().id, id, "объявление восстановлено")
	T.eq(again.ns.Groups.Mine().title, "Мёртвые копи")
	T.eq(#again.ns.Groups.Applicants(), 1, "заявки восстановлены")
	T.same(again.ns.Groups.MyRoles(), { t = 1, h = 0, d = 0 }, "роли персонажа запомнены")
	w:Run(120)
	local e = Seen(c.V, again)
	T.ok(e and e.id == id, "объявление снова расходится")
	T.ok(again:Hardware(again.ns.Groups.Invite, Key(c.V)), "заявку можно принять после перезагрузки")
	T.eq(again.partyInvites[1], "Вера Верная")
end)

T.test("groups: в общий чат уходит строка о новой группе, о правке — нет", function()
	local w, c = Build()
	c.A:Hardware(function() T.ok(c.A.ns.Groups.Raise(Spec({ announce = true }))) end)
	w:Run(30)
	local function Lines(viewer)
		local n = 0
		for _, m in ipairs(viewer.ns.Chat.History("A")) do
			if tostring(m.x):find("Мёртвые копи", 1, true) then n = n + 1 end
		end
		return n
	end
	T.eq(Lines(c.V), 1, "строка дошла до другой гильдии")
	c.A:Hardware(function() T.ok(c.A.ns.Groups.Raise(Spec({ announce = true, note = "поправил" }))) end)
	w:Run(30)
	T.eq(Lines(c.V), 1, "правка в чат не пишет")
end)

local function Logged(cl, text)
	local n = 0
	for _, line in ipairs(cl.ns.db.log) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

T.test("groups: журнал показывает, что объявление дошло, снято или пропало", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.eq(Logged(c.A, "группы: своё объявление ушло гильдии и реле"), 1)
	T.eq(Logged(c.K, "группы: объявление Арагорн Светлый <Чиллзон> принято (своя гильдия)"), 1)
	T.eq(Logged(c.V, "группы: объявление Арагорн Светлый <Чиллзон> принято (реле)"), 1)
	T.eq(Logged(c.B, "группы: объявление Арагорн Светлый <Чиллзон> принято (реле)"), 1)
	-- Повторы того же объявления журнал не засоряют.
	w:Run(6 * 60)
	T.ok(Seen(c.V, c.A), "объявление на доске")
	T.eq(Logged(c.V, "объявление Арагорн Светлый <Чиллзон> принято"), 1)
	T.eq(Logged(c.A, "своё объявление ушло"), 1)
	T.ok(c.A.ns.Groups.Lower())
	w:Run(30)
	T.eq(Logged(c.A, "группы: своё объявление снято (сам автор)"), 1)
	T.eq(Logged(c.K, "группы: Арагорн Светлый <Чиллзон> снял объявление (своя гильдия)"), 1)
	T.eq(Logged(c.V, "группы: Арагорн Светлый <Чиллзон> снял объявление (реле)"), 1)
	-- Автор вышел, не сняв объявление: видно, что оно пропало само, а не снято.
	T.ok(c.B.ns.Groups.Raise({ mode = "P", title = "куда позовут", roles = { t = 0, h = 1, d = 0 } }))
	w:Run(30)
	T.ok(Seen(c.A, c.B))
	c.B:Logout()
	w:Run(15 * 60)
	T.no(Seen(c.A, c.B))
	T.eq(Logged(c.A, "группы: объявление Борис Быстрый <Чиллзон Север> пропало с доски: автор его не повторил"), 1)
	T.eq(Logged(c.A, "Борис Быстрый <Чиллзон Север> снял объявление"), 0)
end)

-- Случай из игры: рядовой другой гильдии, которого получатель ещё не слышал, сообщает о своём
-- объявлении в общий чат. Строка из канала приходит раньше подписанной, и подтвердить гильдию
-- автора по имени нечем.
T.test("groups: строка о группе от незнакомого рядового — <?> в чате игры, гильдия в окне", function()
	local w, c = Build()
	local new = w:Client({ first = "Нина", surname = "Новая", guild = "Чиллзон Север", rank = 3, class = "WARLOCK", level = 30 })
	w:Run(200)
	T.ok(new.ns.Security.MyCertificate(), "новичок получил сертификат")
	T.eq(c.A.ns.Chat.Attribute(new:Name()), nil, "в другой гильдии его по имени не знают")
	new:Hardware(function()
		T.ok(new.ns.Groups.Raise({ mode = "P", kind = "D", title = "Даларан", roles = { t = 0, h = 0, d = 1 }, announce = true }))
	end)
	w:Run(30)
	local line
	for _, m in ipairs(c.A.ns.Chat.History("A")) do
		if tostring(m.x):find("Хочу: Даларан", 1, true) then
			T.eq(line, nil, "строка одна")
			line = m
		end
	end
	T.ok(line, "строка о группе дошла")
	T.eq(c.A:Saw("|cff999999<?>|r |Hplayer:"), 1, "в чате игры она напечатана с <?>")
	T.eq(line.g, "Чиллзон Север", "в окне гильдию подтвердила подписанная копия")
	T.eq(line.u, nil)
	T.eq(Logged(c.A, "строка канала от Нина Новая показана без гильдии: подпись <Чиллзон Север> пришла через"), 1)
	T.ok(Seen(c.A, new), "объявление на доске")
	T.eq(Logged(c.A, "группы: объявление Нина Новая <Чиллзон Север> принято (реле)"), 1)
	T.eq(select(2, c.A.ns.Chat.Attribute(new:Name())), "cert", "следующую строку автора подтвердит сертификат")
end)

T.test("groups: клиент прежней версии объявления и запросы молча пропускает", function()
	local w, c = Build()
	local old = w:Client({ first = "Олег", surname = "Старый", guild = "Чиллзон", rank = 3, legacy = true })
	w:Run(120)
	T.eq(old.ns.Groups, nil, "у прежней версии модуля групп нет")
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.ok(Seen(c.K, c.A), "обновлённый согильдиец объявление видит")
	-- Запрос объявлений по GUILD доходит и до прежней версии.
	c.K.ns.Groups.Ask()
	c.A.ns.Groups.SetNeed("d", 1)
	w:Run(60)
	T.ok(c.A.ns.Groups.Lower())
	w:Run(30)
	T.eq(#(old.ns.db.errors or {}), 0, "ошибок нет: " .. tostring((old.ns.db.errors or {})[1]))
	T.eq(old:Saw("Мёртвые копи"), 0, "в чат ничего не выведено")
	T.eq(#(c.A.ns.db.errors or {}), 0, "у автора ошибок нет")
end)

---------------------------------------------------------------------------
-- Конверт строки чата: объявление через реле и репортёров 0.13.1 и старше
---------------------------------------------------------------------------
T.test("groups codec: конверт строки чата для реле прежних версий", function()
	local Codec = codec()
	local msg = Codec.EncodeGroup(listing())
	local env = Codec.WrapGroup(msg)
	T.eq(env, "M1~A~Чиллзон Север~" .. msg)
	local inner, guild = Codec.UnwrapGroup(env)
	T.eq(inner, msg)
	T.eq(guild, "Чиллзон Север")
	T.eq(Codec.InnerType(env), "M1", "реле видит строку чата")
	T.no(Codec.DecodeChat(env), "чат конверт не читает")
	-- Образец DecodeChat вышедших версий 0.9-0.14.0: третье поле — номер строки, а здесь G1.
	T.no((env:match("^M1~(%u)~([^~|]+)~(%d%d?%d?%d?)~(%u?%u?)~(.+)$")), "вышедшие версии его не читают")
	local x = Codec.EncodeGroup({ mode = "X", id = 1794412800, guild = "Чиллзон" })
	T.eq((Codec.UnwrapGroup(Codec.WrapGroup(x))), x, "снятие тоже")
	-- Гильдию конверта проверяет подпись, поэтому она должна быть гильдией объявления.
	T.no(Codec.UnwrapGroup("M1~A~Чиллзон~" .. msg), "внутри объявление другой гильдии")
	T.no(Codec.UnwrapGroup("M1~C~Чиллзон Север~" .. msg), "только вид A")
	T.no(Codec.UnwrapGroup(Codec.EncodeChat("A", "Чиллзон Север", 12, "MAGE", msg)), "строка чата с текстом объявления")
	T.no(Codec.UnwrapGroup("M1~A~Чиллзон Север~G1~G~1794412800~Чиллзон Север~" .. ("x"):rep(300)), "слишком длинно")
	T.no(Codec.WrapGroup(Codec.EncodeChat("A", "Чиллзон", 12, "MAGE", "привет")), "в конверт идёт только G1")
	T.no(Codec.WrapGroup("G1~G~1794412800~Чиллзон~" .. ("x"):rep(260)), "длинное G1")
	-- Самое длинное объявление в конверте подписывается: предел — размер подписанного пакета.
	local l = listing()
	l.guild, l.title, l.note = ("Щ"):rep(24), ("Ж"):rep(40), ("я"):rep(90)
	local long = Codec.WrapGroup(Codec.EncodeGroup(l))
	T.ok(long and #long > 255 and Codec.UnwrapGroup(long), "конверт длиннее 255 байт читается")
end)

-- Вложенное подписанного пакета: "G1" — родной пакет, "M1G1" — конверт, "M1" — строка чата.
local Codec0 = codec()
local function Kind(wire)
	local inner = wire:match("^S1~[^~]+~%d+~%d+~[^~]+~(.+)$") or ""
	if Codec0.UnwrapGroup(inner) then return "M1G1" end
	return inner:sub(1, 2)
end

-- Репортёр «Чиллзон Север» и второй её участник (выборы решают сами клиенты).
local function North(c)
	if c.V.ns.Census.IsReporter() then return c.V, c.B end
	T.ok(c.B.ns.Census.IsReporter(), "у Севера есть репортёр")
	return c.B, c.V
end

-- Пакеты автора через реле: перехватываются и никуда не уходят, раздаёт их тест (Share).
local function Hold(c)
	local held = {}
	c.ns.Relay.Out = function(_, wire)
		held[#held + 1] = wire
		return true
	end
	return held
end

-- Пакеты автора через реле с видом и временем; уходят как обычно.
local function Outs(c)
	local list, out = {}, c.ns.Relay.Out
	c.ns.Relay.Out = function(mode, wire)
		list[#list + 1] = { t = c.world.now, kind = Kind(wire), mode = mode }
		return out(mode, wire)
	end
	return list
end

-- Репортёр отдаёт пакет автора своей гильдии, как после RM от реле.
local function Share(rep, author, wire)
	rep.ns.Security.Introduce("GUILD", author.ns.Security.MyCertificate().raw)
	rep.ns.Comm.Send("GUILD", rep.ns.Codec.EncodeRM("RG", "P", author:Name(), wire), {})
end

local function NoTrace(cl, label)
	T.eq(cl:Saw("G1~"), 0, label .. ": в чате игры нет конверта")
	for _, tier in ipairs({ "A", "C", "L" }) do
		for _, m in ipairs(cl.ns.Chat.History(tier)) do
			T.no(tostring(m.x):find("G1~", 1, true), label .. ": в окне нет конверта")
		end
	end
	T.eq(Logged(cl, "отклонен"), 0, label .. ": в журнале нет отказов")
end

T.test("groups: через реле объявление идёт и в конверте строки чата, своей гильдии — только родное", function()
	local w, c = Build()
	local guild, outs = Capture(c.A), Outs(c.A)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.eq(#guild, 1, "своей гильдии — один родной пакет")
	T.eq(#outs, 2, "через реле — два пакета")
	T.eq(outs[1].kind, "G1", "сначала родной")
	T.eq(outs[2].kind, "M1G1", "затем конверт")
	for _, viewer in ipairs({ c.V, c.B }) do
		local e = Seen(viewer, c.A)
		T.ok(e, viewer:Name() .. " видит объявление")
		T.eq(e.title, "Мёртвые копи")
		T.ok(e.wrapped and e.native, "на доске конверт, родной пакет при нём")
		T.eq(Kind(e.native), "G1")
		T.eq(viewer.ns.Groups.stats.wrapped, 1)
		T.eq(Logged(viewer, "объявление Арагорн Светлый <Чиллзон> принято"), 1, "в журнале одна запись")
		NoTrace(viewer, viewer:Name())
	end
	T.eq(c.K.ns.Groups.stats.wrapped, 0, "своей гильдии конверт не приходит")
	NoTrace(c.K, c.K:Name())
	-- Снятие — тоже двумя пакетами через реле.
	T.ok(c.A.ns.Groups.Lower())
	w:Run(30)
	T.eq(#outs, 4)
	T.same({ outs[3].kind, outs[4].kind }, { "G1", "M1G1" })
	T.no(Seen(c.V, c.A))
	T.no(Seen(c.B, c.A))
	T.eq(Logged(c.V, "Арагорн Светлый <Чиллзон> снял объявление"), 1)
	for _, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
	end
end)

T.test("groups: две копии в любом порядке — одно объявление, заявка не сбрасывается, старое не возвращается", function()
	local w, c = Build()
	local rep, reader = North(c)
	local held = Hold(c.A)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(10)
	T.eq(#held, 2)
	local native1, env1 = held[1], held[2]
	T.eq(Kind(native1), "G1")
	T.eq(Kind(env1), "M1G1")
	-- Конверт пришёл раньше родной копии.
	Share(rep, c.A, env1)
	w:Run(10)
	local e = Seen(reader, c.A)
	T.ok(e and e.wrapped, "объявление из конверта")
	T.eq(e.title, "Мёртвые копи")
	T.eq(Logged(reader, "группы: объявление Арагорн Светлый <Чиллзон> принято (реле, в конверте чата)"), 1)
	T.ok(reader.ns.Groups.Apply(Key(c.A), { t = 0, h = 1, d = 0 }))
	local stale = reader.ns.Groups.stats.stale
	Share(rep, c.A, native1)
	w:Run(10)
	T.eq(Seen(reader, c.A), e, "запись на доске прежняя")
	T.eq(e.native, native1, "родной пакет запомнен")
	T.eq(reader.ns.Groups.stats.stale, stale + 1)
	T.eq(Logged(reader, "объявление Арагорн Светлый <Чиллзон> принято"), 1, "в журнале одна запись")
	T.eq(reader.ns.Groups.List()[1].applied, "sent", "заявка не сброшена")
	-- Правка: родной пакет сразу, конверт — после паузы GROUPS_WRAP_GAP.
	T.ok(c.A.ns.Groups.Raise(Spec({ title = "Мёртвые копи, героик" })))
	w:Run(10)
	T.eq(#held, 3, "конверт правки ждёт")
	local native2 = held[3]
	T.eq(Kind(native2), "G1")
	Share(rep, c.A, native2)
	w:Run(10)
	e = Seen(reader, c.A)
	T.eq(e.title, "Мёртвые копи, героик")
	T.no(e.wrapped, "на доске родной пакет")
	T.eq(reader.ns.Groups.List()[1].applied, "sent", "правка заявку не сбрасывает")
	w:Run(c.A.ns.Config.GROUPS_WRAP_GAP)
	T.eq(#held, 4, "пауза прошла — конверт правки ушёл")
	local env2 = held[4]
	T.eq(Kind(env2), "M1G1")
	T.ok(env2:find("Мёртвые копи, героик", 1, true), "в конверте последняя правка")
	-- Конверт правки пришёл позже: запись сменилась, родной пакет правки остался при ней.
	Share(rep, c.A, env2)
	w:Run(10)
	e = Seen(reader, c.A)
	T.ok(e.wrapped)
	T.eq(e.native, native2, "родной пакет с тем же текстом, хоть и подписан раньше")
	T.eq(reader.ns.Groups.List()[1].applied, "sent")
	-- Снятие: доходит только конверт X, родной X и прежние пакеты приходят следом.
	T.ok(c.A.ns.Groups.Lower())
	w:Run(10)
	T.eq(#held, 6, "снятие — родной пакет и конверт")
	local lowered = {}
	for i = 5, 6 do lowered[Kind(held[i])] = held[i] end
	T.ok(lowered.G1 and lowered.M1G1)
	Share(rep, c.A, lowered.M1G1)
	w:Run(10)
	T.no(Seen(reader, c.A), "снято конвертом")
	T.eq(Logged(reader, "группы: Арагорн Светлый <Чиллзон> снял объявление (реле, в конверте чата)"), 1)
	-- Прежний пакет, который этот читатель ещё не видел, и родное снятие следом ничего не меняют.
	Share(rep, c.A, lowered.G1)
	w:Run(10)
	T.no(Seen(reader, c.A))
	T.eq(Logged(reader, "снял объявление"), 1)
	NoTrace(reader, reader:Name())
	T.eq(#reader.ns.db.errors, 0, table.concat(reader.ns.db.errors, " | "))
end)

T.test("groups: прежний конверт после новой родной копии не откатывает правку", function()
	local w, c = Build()
	local rep, reader = North(c)
	local held = Hold(c.A)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(10)
	local env1 = held[2]
	T.ok(c.A.ns.Groups.Raise(Spec({ title = "Мёртвые копи, героик" })))
	w:Run(10)
	Share(rep, c.A, held[3])
	w:Run(10)
	T.eq(Seen(reader, c.A).title, "Мёртвые копи, героик")
	local stale = reader.ns.Groups.stats.stale
	Share(rep, c.A, env1)
	w:Run(10)
	T.eq(Seen(reader, c.A).title, "Мёртвые копи, героик", "правка осталась")
	T.no(Seen(reader, c.A).wrapped)
	T.eq(reader.ns.Groups.stats.stale, stale + 1, "прежний конверт отброшен")
end)

T.test("groups: конверт с объявлением другой гильдии не читается ни доской, ни чатом", function()
	local w, c = Build()
	local rep, reader = North(c)
	local held = Hold(c.A)
	-- Член «Чиллзон» подписывает конверт своей гильдии с объявлением «Чиллзон Север» внутри.
	local fake = c.A.ns.Codec.EncodeGroup({
		mode = "G", id = c.A.env.GetServerTime(), guild = "Чиллзон Север", class = "WARRIOR", level = 24, kind = "D",
		roles = { t = 1, h = 1, d = 3 }, size = 1, cap = 5, min = 0, every = 5, title = "Подделка", note = "",
	})
	T.ok(c.A.ns.Security.Seal("M1~A~Чиллзон~" .. fake, function(wire) held[#held + 1] = wire end))
	w:Run(5)
	T.eq(#held, 1)
	T.eq(Kind(held[1]), "M1", "это не конверт объявления")
	Share(rep, c.A, held[1])
	w:Run(10)
	T.no(Seen(reader, c.A), "на доске нет")
	T.eq(reader.ns.Groups.stats.heard, 0)
	NoTrace(reader, reader:Name())
	T.eq(#reader.ns.db.errors, 0, table.concat(reader.ns.db.errors, " | "))
end)

T.test("groups: отвечая на GQ, репортёр отдаёт родной пакет, а конверт — только если родного нет", function()
	local w, c = Build()
	local rep = North(c)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	T.ok(c.K.ns.Groups.Raise({ mode = "P", title = "куда позовут", roles = { t = 0, h = 1, d = 0 } }))
	w:Run(60)
	local a, k = Seen(rep, c.A), Seen(rep, c.K)
	T.ok(a and a.wrapped and a.native, "у репортёра конверт и родной пакет А")
	-- Объявление К будто бы пришло через реле 0.13.1: только конверт.
	T.ok(k and k.wrapped)
	k.native, k.nativeAt = nil, nil
	local served = {}
	local send = rep.ns.Comm.Send
	rep.ns.Comm.Send = function(dist, payload, opts)
		local kind, _, origin, inner = rep.ns.Codec.DecodeRelay(payload)
		local what = kind == "RG" and dist == "GUILD" and Kind(inner)
		if what == "G1" or what == "M1G1" then served[origin] = what end
		return send(dist, payload, opts)
	end
	local late = w:Client({ first = "Леголас", surname = "Зоркий", guild = "Чиллзон Север", rank = 3, class = "HUNTER" })
	w:Run(200)
	T.eq(served["Арагорн Светлый"], "G1", "А — родным пакетом")
	T.eq(served["Карл Великий"], "M1G1", "К — конвертом")
	T.eq(Logged(rep, "отдано чужих объявлений: 2, из них в конверте чата: 1"), 1)
	T.ok(Seen(late, c.A) and not Seen(late, c.A).wrapped, "новичок принял родной пакет")
	T.ok(Seen(late, c.K) and Seen(late, c.K).wrapped, "и конверт")
	NoTrace(late, late:Name())
end)

local function Lines(viewer, text)
	local n = 0
	for _, m in ipairs(viewer.ns.Chat.History("A")) do
		if tostring(m.x):find(text, 1, true) then n = n + 1 end
	end
	return n
end

T.test("groups: размещение с объявлением в чат — через реле три пакета, строка чата первой", function()
	local w, c = Build()
	local outs = Outs(c.A)
	c.A:Hardware(function() T.ok(c.A.ns.Groups.Raise(Spec({ announce = true }))) end)
	w:Run(30)
	local kinds = {}
	for _, o in ipairs(outs) do kinds[#kinds + 1] = o.kind end
	T.same(kinds, { "G1", "M1", "M1G1" }, "родной пакет, строка чата, конверт")
	T.eq(c.K.ns.Relay.stats.dropped, 0, "реле ничего не отбросило по лимиту")
	for _, viewer in ipairs({ c.K, c.V, c.B }) do
		T.eq(Lines(viewer, "Мёртвые копи"), 1, viewer:Name() .. ": строка о группе одна")
		T.ok(Seen(viewer, c.A), viewer:Name() .. ": объявление на доске")
		NoTrace(viewer, viewer:Name())
	end
	-- Автор правит объявление и пишет в чат: конверт правок не чаще GROUPS_WRAP_GAP, и за минуту
	-- через реле уходит меньше RELAY_PER_MIN пакетов — строкам чата место остаётся.
	local C = c.A.ns.Config
	local from = #outs
	for i = 1, 8 do
		c.A.ns.Groups.SetNeed("d", i % 3)
		w:Run(16)
		if i % 2 == 0 then
			c.A:Hardware(function() c.A.ns.Chat.Send("A", "строка " .. i) end)
		end
	end
	w:Run(C.GROUPS_WRAP_GAP)
	local wraps, worst = 0, 0
	for i = from + 1, #outs do
		if outs[i].kind == "M1G1" then wraps = wraps + 1 end
		local n = 0
		for j = i, #outs do
			if outs[j].t - outs[i].t < 60 then n = n + 1 end
		end
		worst = math.max(worst, n)
	end
	T.ok(wraps >= 1 and wraps <= math.ceil((8 * 16 + C.GROUPS_WRAP_GAP) / C.GROUPS_WRAP_GAP), "конвертов правок: " .. wraps)
	T.ok(worst < C.RELAY_PER_MIN, "через реле за минуту не больше " .. worst)
	T.eq(c.K.ns.Relay.stats.dropped, 0, "реле ничего не отбросило")
	for i = 2, 8, 2 do
		T.eq(Lines(c.B, "строка " .. i), 1, "строка " .. i .. " дошла")
	end
	local last = c.A.ns.Groups.Mine().roles
	T.same(Seen(c.B, c.A).roles, last, "последняя правка дошла")
	T.ok(Seen(c.B, c.A).wrapped, "и в конверте")
	T.same(c.A.ns.Codec.DecodeGroup(Seen(c.B, c.A).text).roles, last)
end)

T.test("groups: в блокировке сообщений правка и её конверт ждут её конца", function()
	local w, c = Build()
	local outs = Outs(c.A)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.eq(#outs, 2)
	c.A.lockdown = true
	c.A.ns.Groups.SetNeed("d", 0)
	w:Run(c.A.ns.Config.GROUPS_WRAP_GAP + 60)
	T.eq(#outs, 2, "в блокировке через реле ничего не ушло")
	c.A.lockdown = false
	w:Run(30)
	local kinds = {}
	for i = 3, #outs do kinds[#kinds + 1] = outs[i].kind end
	T.same(kinds, { "G1", "M1G1" }, "после блокировки — правка и её конверт")
	local reader = select(2, North(c))
	T.eq(Seen(reader, c.A).roles.d, 0, "правка дошла")
end)

-- Гибрид tests/wow.lua: Security, Relay и Census версии 0.9 G1 не пересылают, а строку чата — да.
-- Чат и Comm у гибрида новые, поэтому то, что старый чат конверт молча отбрасывает, проверяет
-- только сценарий с клиентами из тегов (вне репозитория: CI тегов не видит).
T.test("groups: реле и репортёр прежней версии пересылают объявление в конверте", function()
	math.randomseed(tonumber(os.getenv("CZ_SEED") or "") or 7)
	local w = Wow.World()
	w:Guild("Чиллзон")
	w:Guild("Чиллзон Север")
	w:Guild("Орден Чиллзона")
	local c = {}
	-- Автор не в главной гильдии: иначе он сам реле и шлёт объявление репортёрам напрямую.
	-- Все начинают на 0.9: состав объединения обновлённые автор и читатель берут из своих
	-- сохранений, ведь глава на 0.9 нового решения о составе не подпишет.
	c.K = w:Client({ first = "Карл", surname = "Великий", guild = "Чиллзон", rank = 0, legacy = true })
	c.G = w:Client({ first = "Глеб", surname = "Гордый", guild = "Орден Чиллзона", rank = 0, class = "HUNTER", level = 24, legacy = true })
	c.V = w:Client({ first = "Вера", surname = "Верная", guild = "Чиллзон Север", rank = 0, legacy = true })
	c.B = w:Client({ first = "Борис", surname = "Быстрый", guild = "Чиллзон Север", rank = 3, class = "PRIEST", level = 21, legacy = true })
	w:Run(30)
	w:Init(c.K, c.V, c.G)
	w:Pair(c.V, c.K)
	w:Pair(c.G, c.K)
	w:Run(400)
	for _, id in ipairs({ "G", "B" }) do
		local old = c[id]
		old:Logout()
		c[id] = w:Client({ first = old.first, surname = old.surname, guild = old.guild, rank = old.rank, class = old.class,
			level = old.level, db = old.ns.db })
		for _, other in ipairs(w.clients) do other.ns.Roster.Scan() end
		w:Run(1)
	end
	w:Run(200)
	T.ok(c.V.ns.Census.IsReporter(), "репортёр Севера — глава на 0.9")
	T.ok(c.B.ns.Util.IsMemberGuild("Орден Чиллзона"), "читатель знает гильдию автора")
	local outs = Outs(c.G)
	c.G:Hardware(function() T.ok(c.G.ns.Groups.Raise(Spec({ announce = true }))) end)
	w:Run(60)
	T.eq(#outs, 3, "через реле — родной пакет, строка чата и конверт")
	local e = Seen(c.B, c.G)
	T.ok(e, "объявление дошло через 0.9")
	T.ok(e and e.wrapped and not e.native, "только в конверте")
	T.eq(e and e.title, "Мёртвые копи")
	T.eq(Logged(c.B, "группы: объявление Глеб Гордый <Орден Чиллзона> принято (реле, в конверте чата)"), 1)
	T.eq(Lines(c.B, "Мёртвые копи"), 1, "строка о группе одна")
	T.ok(c.B.ns.Groups.Apply(Key(c.G), { t = 0, h = 1, d = 0 }))
	w:Run(15)
	T.eq(#c.G.ns.Groups.Applicants(), 1, "заявка дошла напрямую")
	T.ok(c.G.ns.Groups.Lower())
	w:Run(60)
	T.no(Seen(c.B, c.G), "снятие дошло")
	T.eq(Logged(c.B, "группы: Глеб Гордый <Орден Чиллзона> снял объявление (реле, в конверте чата)"), 1)
	for _, cl in pairs(c) do
		T.eq(#cl.ns.db.errors, 0, cl:Name() .. ": ошибки " .. table.concat(cl.ns.db.errors, " | "))
		T.eq(#cl:Leaks(), 0, cl:Name() .. ": глобалы")
		T.eq(cl:Saw("G1~"), 0, cl:Name() .. ": конверт в чате")
	end
end)

---------------------------------------------------------------------------
-- Вкладка: то, что видно симулятору (кадры, надписи, щелчки)
---------------------------------------------------------------------------
local function NoErrors(c, label)
	local errors = c.ns.db.errors or {}
	T.eq(#errors, 0, label .. ": " .. tostring(errors[1]))
end

-- Строки подсказки при наведении на owner.
local function Tip(c, owner)
	local lines = {}
	c.stubs.GameTooltip = true
	c.env.GameTooltip = {
		SetOwner = function() end, Show = function() end, Hide = function() end,
		AddLine = function(_, text) lines[#lines + 1] = text end,
	}
	owner:GetScript("OnEnter")(owner)
	return table.concat(lines, "\n")
end

-- Строка доски с объявлением автора.
local function BoardRow(viewer, author)
	for _, r in ipairs(viewer.ns.GroupsPane.frames.rows) do
		if r:IsShown() and r.it and r.it.key == Key(author) then return r end
	end
end

T.test("groups pane: доска, заявка щелчком и приглашение из списка заявок", function()
	local w, c = Build()
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	local L = c.V.ns.L
	c.V.ns.UI.Toggle("groups")
	local f = c.V.ns.GroupsPane.frames
	T.ok(f.pane:IsShown(), "вкладка открыта")
	T.eq(c.V.ns.UI.Current(), "groups")
	T.eq(f.rows[1].header:GetText(), L.GROUPS_SECTION_GROUPS:format(1), "заголовок раздела")
	local row = BoardRow(c.V, c.A)
	T.ok(row, "строка объявления")
	T.ok(row.sub:GetText():find("Мёртвые копи", 1, true), "название в строке")
	T.ok(row.name:GetText():find("Арагорн Светлый", 1, true), "автор в строке")
	T.eq(row.button:GetText(), L.GROUPS_APPLY)
	T.ok(f.idle:IsShown(), "справа — роли и кнопки размещения")
	local tip = Tip(c.V, row)
	T.ok(tip:find("Мёртвые копи", 1, true), "подсказка: название")
	T.ok(tip:find("без спешки", 1, true), "подсказка: примечание")
	T.ok(tip:find(L.GROUPS_TIP_SIZE:format(1, 5), 1, true), "подсказка: состав")
	T.ok(tip:find(L.GROUPS_TIP_MIN:format(18), 1, true), "подсказка: уровень")
	T.ok(Tip(c.V, c.V.ns.UI.tabs.groups):find(L.TAB_GROUPS_COUNT:format(1), 1, true), "число объявлений в подсказке вкладки")

	-- Без отмеченных ролей заявка не уходит, игрок видит почему.
	row.button:Click()
	T.eq(c.V:Saw(L.GROUPS_WHY_ROLES), 1, "подсказка про роли")
	T.eq(#c.A.ns.Groups.Applicants(), 0)
	f.idle.roles[2]:Click()
	T.same(c.V.ns.Groups.MyRoles(), { t = 0, h = 1, d = 0 }, "роль отмечена щелчком")
	row.button:Click()
	row = BoardRow(c.V, c.A)
	T.eq(row.button:GetText(), L.GROUPS_WITHDRAW, "после заявки — «Отозвать»")
	w:Run(15)

	-- Автор: своё объявление справа, заявка в списке, приглашение щелчком.
	c.A.ns.UI.Toggle("groups")
	local fa = c.A.ns.GroupsPane.frames
	T.ok(fa.own:IsShown(), "панель своей группы")
	T.no(fa.idle:IsShown())
	T.ok(fa.own.title:GetText() == c.A.ns.L.GROUPS_MINE_GROUP)
	T.ok(fa.own.name:GetText():find("Мёртвые копи", 1, true))
	local applicant = fa.applicants[1]
	T.ok(applicant and applicant:IsShown(), "строка заявки")
	T.ok(applicant.name:GetText():find("Вера Верная", 1, true))
	T.ok(applicant.take:IsShown())
	local who = Tip(c.A, applicant)
	T.ok(who:find("Чиллзон Север", 1, true), "подсказка заявки: гильдия")
	T.ok(who:find(c.A.ns.L.GROUPS_TIP_CLAIM, 1, true), "подсказка заявки: сведения со слов игрока")
	T.ok(Tip(c.A, fa.rows[2]):find("Мёртвые копи", 1, true), "подсказка своей строки")
	T.ok(Tip(c.A, applicant.take) ~= "", "подсказка кнопки")
	c.A:Hardware(function() applicant.take:Click() end)
	T.eq(c.A.partyInvites[1], "Вера Верная", "приглашение ушло из щелчка")
	T.no(fa.applicants[1].take:IsShown(), "кнопки сменились отметкой «приглашён»")
	T.ok(fa.applicants[1].mark:IsShown())
	w:Run(15)
	T.ok(BoardRow(c.V, c.A).status:GetText():find(L.GROUPS_YOU_INVITED, 1, true), "заявитель видит приглашение")

	-- Нужные роли правятся на месте.
	fa.own.steppers[3].plus:Click()
	T.eq(c.A.ns.Groups.Mine().roles.d, 3)
	fa.own.lower:Click()
	T.no(c.A.ns.Groups.Mine(), "снято кнопкой")
	T.ok(fa.idle:IsShown())
	w:Run(30)
	T.no(BoardRow(c.V, c.A), "строка пропала с доски")
	T.ok(f.rows[1] == nil or not f.rows[1]:IsShown(), "доска пуста")
	NoErrors(c.A, "автор")
	NoErrors(c.V, "заявитель")
	T.eq(#c.A:Leaks(), 0, "глобалов нет")
end)

T.test("groups pane: форма со свободным названием, правка и «ищу группу»", function()
	local w, c = Build()
	local L = c.B.ns.L
	c.B.ns.UI.Toggle("groups")
	local f = c.B.ns.GroupsPane.frames
	T.ok(f.idle:IsShown())
	f.idle.group:Click()
	T.ok(f.form:IsShown(), "форма открыта")
	T.no(f.idle:IsShown())
	T.eq(f.form.title:GetText(), L.GROUPS_FORM_GROUP)
	T.eq(f.form.nameLabel:GetText(), L.GROUPS_FIELD_TITLE, "подпись названия у группы")
	T.no(f.form.pick:IsShown(), "без списка игры кнопки «Из списка» нет")

	-- Пустое название не проходит, форма остаётся.
	c.B:Hardware(function() f.form.submit:Click() end)
	T.eq(c.B:Saw(L.GROUPS_WHY_TITLE), 1)
	T.ok(f.form:IsShown())

	f.form.name:SetText("Идём куда глаза глядят")
	f.form.note:SetText("берём всех")
	f.form.kinds[5]:Click()
	f.form.caps[2]:Click()
	f.form.steppers[1].minus:Click()
	f.form.steppers[2].plus:Click()
	f.form.min:SetText("15")
	c.B:Hardware(function() f.form.submit:Click() end)
	local mine = c.B.ns.Groups.Mine()
	T.ok(mine, "размещено из формы")
	T.eq(mine.title, "Идём куда глаза глядят")
	T.eq(mine.note, "берём всех")
	T.eq(mine.kind, "O")
	T.eq(mine.cap, 10)
	T.eq(mine.min, 15)
	T.same(mine.roles, { t = 0, h = 2, d = 3 })
	T.ok(f.own:IsShown(), "после размещения — панель своей группы")
	w:Run(30)
	T.eq(Seen(c.A, c.B).title, "Идём куда глаза глядят")

	-- Своё объявление — первой строкой раздела, без кнопки.
	T.ok(f.rows[2].it.own, "своя строка на доске")
	T.no(f.rows[2].button:IsShown())

	-- Правка: форма заполнена прежними значениями, номер объявления сохраняется.
	local id = mine.id
	f.own.edit:Click()
	T.eq(f.form.title:GetText(), L.GROUPS_FORM_EDIT)
	T.eq(f.form.name:GetText(), "Идём куда глаза глядят")
	T.eq(f.form.min:GetText(), "15")
	T.no(f.form.announce:IsShown(), "о правке в чат не пишем")
	f.form.name:SetText("Идём в Мёртвые копи")
	c.B:Hardware(function() f.form.submit:Click() end)
	T.eq(c.B.ns.Groups.Mine().id, id)
	T.eq(c.B.ns.Groups.Mine().title, "Идём в Мёртвые копи")
	T.eq(c.B.ns.Groups.Mine().cap, 10, "число мест не сбросилось")
	w:Run(30)
	T.eq(Seen(c.A, c.B).title, "Идём в Мёртвые копи")

	-- Отмена правки ничего не меняет.
	f.own.edit:Click()
	f.form.name:SetText("не сохранять")
	f.form.cancel:Click()
	T.ok(f.own:IsShown())
	T.eq(c.B.ns.Groups.Mine().title, "Идём в Мёртвые копи")

	-- «Ищу группу»: роли обязательны, название — нет.
	f.own.lower:Click()
	f.idle.player:Click()
	T.eq(f.form.title:GetText(), L.GROUPS_FORM_PLAYER)
	T.eq(f.form.nameLabel:GetText(), L.GROUPS_FIELD_WISH, "подпись названия у «ищу группу»")
	T.no(f.form.steppers[1]:IsShown(), "у игрока нет «кого ищем»")
	T.ok(f.form.roles[1]:IsShown())
	c.B:Hardware(function() f.form.submit:Click() end)
	T.eq(c.B:Saw(L.GROUPS_WHY_ROLES), 1, "без ролей не размещается")
	f.form.roles[2]:Click()
	w:Run(40) -- пауза между размещениями
	c.B:Hardware(function() f.form.submit:Click() end)
	T.eq(c.B.ns.Groups.Mine().mode, "P")
	T.eq(f.own.title:GetText(), L.GROUPS_MINE_PLAYER)
	T.ok(f.own.hint:IsShown())
	w:Run(30)

	-- Лидер другой гильдии видит игрока во втором разделе и зовёт его щелчком.
	c.A.ns.UI.Toggle("groups")
	local row = BoardRow(c.A, c.B)
	T.ok(row, "игрок на доске")
	T.eq(row.button:GetText(), c.A.ns.L.GROUPS_INVITE)
	local tip = Tip(c.A, row)
	T.ok(tip:find("Борис Быстрый", 1, true), "подсказка: кто ищет группу")
	T.ok(tip:find(c.A.ns.L.GROUPS_ANYWHERE, 1, true), "подсказка: без названия — «куда позовут»")
	T.ok(Tip(c.B, f.form.steppers[1]) ~= "", "подсказка счётчика")
	c.A:Hardware(function() row.button:Click() end)
	T.eq(c.A.partyInvites[1], "Борис Быстрый")

	-- Фильтр по разделу и закрытие окна.
	c.A.ns.GroupsPane.frames.filters.R:Click()
	T.no(BoardRow(c.A, c.B), "в «Рейдах» пусто")
	c.A.ns.GroupsPane.frames.filters.all:Click()
	T.ok(BoardRow(c.A, c.B))
	c.B.ns.UI.Toggle()
	T.no(f.pane:IsShown(), "вкладка закрыта вместе с окном")
	c.B.ns.UI.Toggle("census")
	T.no(f.pane:IsShown(), "на другой вкладке панели групп нет")
	NoErrors(c.A, "лидер")
	NoErrors(c.B, "автор")
end)

T.test("groups pane: список занятий игры только подставляет название", function()
	local _, c = Build()
	-- Список игры: одно подземелье. Поля — как в справке API, на Forever не проверены.
	c.B.env.C_LFGList = {
		GetAvailableCategories = function() return { 2 } end,
		GetAvailableActivities = function(category) return category == 2 and { 801 } or {} end,
		GetActivityInfoTable = function(id)
			if id == 801 then return { fullName = "Мёртвые копи", categoryID = 2, maxNumPlayers = 5, minLevel = 17 } end
		end,
	}
	c.B.ns.UI.Toggle("groups")
	local f = c.B.ns.GroupsPane.frames
	f.idle.group:Click()
	T.ok(f.form.pick:IsShown(), "кнопка «Из списка» появилась")
	f.form.pick:Click()
	T.ok(f.picker:IsShown())
	T.no(f.form:IsShown(), "список стоит на месте формы, форма под ним скрыта")
	T.ok(f.picker.search:HasFocus(), "фокус в поле поиска")
	local pick
	for _, r in ipairs(f.pickerRows) do
		if r:IsShown() and r.activity then pick = r end
	end
	T.ok(pick, "занятие в списке")
	T.eq(pick.name:GetText(), "Мёртвые копи")
	pick:Click()
	T.no(f.picker:IsShown(), "список закрылся")
	T.ok(f.form:IsShown(), "форма вернулась")
	T.no(f.picker.search:HasFocus(), "фокус с поля поиска снят")
	T.eq(f.form.name:GetText(), "Мёртвые копи", "название подставлено")
	T.eq(f.form.min:GetText(), "17")
	-- Подставленное можно переписать как угодно.
	f.form.name:SetText("Мёртвые копи, только сундуки")
	c.B:Hardware(function() f.form.submit:Click() end)
	T.eq(c.B.ns.Groups.Mine().title, "Мёртвые копи, только сундуки")
	T.eq(c.B.ns.Groups.Mine().kind, "D")
	NoErrors(c.B, "автор")
end)

T.test("groups pane: поиск в списке занятий игры", function()
	local w, c = Build()
	local L = c.B.ns.L
	-- Три подземелья и рейд; в названиях — символы шаблонов Lua и «е» вместо «ё».
	local info = {
		[801] = { "Зул'Фаррак", 5, 39 },
		[802] = { "Забытый город (север)", 5, 50 },
		[803] = { "Верхняя часть пика Черной горы", 10, 55 },
		[901] = { "Зул'Гуруб", 20, 58 },
	}
	c.B.env.C_LFGList = {
		GetAvailableCategories = function() return { 2, 114 } end,
		GetAvailableActivities = function(category)
			if category == 2 then return { 801, 802, 803 } end
			if category == 114 then return { 901 } end
			return {}
		end,
		GetActivityInfoTable = function(id)
			local a = info[id]
			if a then return { fullName = a[1], maxNumPlayers = a[2], minLevel = a[3] } end
		end,
	}
	c.B.ns.UI.Toggle("groups")
	local f = c.B.ns.GroupsPane.frames
	local picker = f.picker
	-- Видимые строки списка по порядку: заголовки разделов в скобках, занятия — названием.
	-- rawget: незаданное поле кадра-заглушки не nil.
	local function Shown()
		local out = {}
		for _, r in ipairs(f.pickerRows) do
			if r:IsShown() then
				local a = rawget(r, "activity")
				out[#out + 1] = a and a.name
					or ("[" .. r.name:GetText():gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "]")
			end
		end
		return out
	end
	-- В игре SetText поля сам зовёт OnTextChanged, в симуляторе — нет.
	local function Search(text)
		picker.search:SetText(text)
		picker.search:GetScript("OnTextChanged")(picker.search, true)
	end
	local D, R = "[" .. L.GROUPS_KIND_D .. "]", "[" .. L.GROUPS_KIND_R .. "]"
	local all = { D, "Зул'Фаррак", "Забытый город (север)", "Верхняя часть пика Черной горы", R, "Зул'Гуруб" }

	f.idle.group:Click()
	f.form.pick:Click()
	T.ok(picker:IsShown(), "список открыт")
	T.no(f.form:IsShown(), "форма под списком скрыта")
	T.eq(picker.search:GetText(), "", "поле поиска пустое")
	T.ok(picker.search:HasFocus(), "можно сразу печатать")
	T.ok(picker.hint:IsShown(), "подсказка в пустом поле")
	T.no(picker.none:IsShown())
	T.same(Shown(), all, "без запроса — весь список")
	T.eq(f.pickerRows[2].right:GetText(), L.GROUPS_PICK_LEVEL:format(39) .. ", " .. L.GROUPS_PICK_CAP:format(5))

	picker.scroll:SetVerticalScroll(40)
	Search("ЗУЛ")
	T.same(Shown(), { D, "Зул'Фаррак", R, "Зул'Гуруб" }, "регистр кириллицы не важен")
	T.no(picker.hint:IsShown(), "подсказка скрыта, пока в поле есть текст")
	T.eq(picker.scroll:GetVerticalScroll(), 0, "новый запрос — прокрутка в начале")
	Search("чёрной")
	T.same(Shown(), { D, "Верхняя часть пика Черной горы" }, "«ё» находит «е»")
	Search("  забытый   север ")
	T.same(Shown(), { D, "Забытый город (север)" }, "каждое слово — в названии")
	Search("забытый юг")
	T.same(Shown(), {}, "одного слова нет — занятие не подходит")
	Search("гуруб")
	T.same(Shown(), { R, "Зул'Гуруб" }, "раздел без подходящих занятий не выводится")
	Search("(север)")
	T.same(Shown(), { D, "Забытый город (север)" }, "скобки в запросе не мешают")
	-- Пробелы и знаки не учитываются ни в названии, ни в запросе.
	Search("верхняячастьпикачернойгоры")
	T.same(Shown(), { D, "Верхняя часть пика Черной горы" }, "слитный запрос")
	Search("чернойгоры")
	T.same(Shown(), { D, "Верхняя часть пика Черной горы" }, "слитно два слова названия")
	Search("зулфаррак")
	T.same(Shown(), { D, "Зул'Фаррак" }, "слитно через апостроф")
	Search("городсевер")
	T.same(Shown(), { D, "Забытый город (север)" }, "слитно через скобку")
	Search("горы пика")
	T.same(Shown(), { D, "Верхняя часть пика Черной горы" }, "порядок слов не важен")
	Search("'")
	T.same(Shown(), all, "запрос из одних знаков — весь список")
	T.no(picker.none:IsShown())
	Search("( )")
	T.same(Shown(), all, "скобки с пробелом — весь список")
	T.no(picker.none:IsShown())
	Search("%a")
	T.same(Shown(), {}, "запрос не шаблон Lua")
	T.ok(picker.none:IsShown(), "ничего не найдено — подсказка")
	T.eq(picker.none:GetText(), L.GROUPS_PICK_NONE)
	Search("")
	T.same(Shown(), all, "очистка запроса возвращает весь список")
	T.no(picker.none:IsShown())
	T.ok(picker.hint:IsShown())

	-- Перерисовка вкладки во время поиска (пришло чужое объявление, тик окна) запрос и
	-- прокрутку не сбрасывает.
	Search("зул")
	picker.scroll:SetVerticalScroll(19)
	T.ok(c.A.ns.Groups.Raise(Spec()))
	w:Run(30)
	T.ok(BoardRow(c.B, c.A), "объявление пришло и нарисовано")
	T.ok(picker:IsShown(), "список не закрылся")
	T.no(f.form:IsShown())
	T.eq(picker.search:GetText(), "зул", "запрос на месте")
	T.same(Shown(), { D, "Зул'Фаррак", R, "Зул'Гуруб" }, "результат на месте")
	T.eq(picker.scroll:GetVerticalScroll(), 19, "прокрутка на месте")

	-- Выбор найденного подставляет название и возвращает форму.
	Search("забытый")
	local pick
	for _, r in ipairs(f.pickerRows) do
		if r:IsShown() and rawget(r, "activity") then pick = r end
	end
	T.eq(pick.name:GetText(), "Забытый город (север)")
	pick:Click()
	T.no(picker:IsShown(), "список закрылся")
	T.ok(f.form:IsShown(), "форма вернулась")
	T.no(picker.search:HasFocus(), "фокус с поля поиска снят")
	T.eq(f.form.name:GetText(), "Забытый город (север)", "название подставлено")
	T.eq(f.form.min:GetText(), "50")

	-- Повторное открытие — с пустым поиском и всем списком; «Закрыть» оставляет поля формы.
	f.form.note:SetText("на сундуки")
	f.form.pick:Click()
	T.eq(picker.search:GetText(), "", "поиск снова пустой")
	T.same(Shown(), all)
	T.eq(picker.scroll:GetVerticalScroll(), 0)
	picker.close:Click()
	T.no(picker:IsShown())
	T.ok(f.form:IsShown())
	T.no(picker.search:HasFocus())
	T.eq(f.form.name:GetText(), "Забытый город (север)", "название не потерялось")
	T.eq(f.form.note:GetText(), "на сундуки", "примечание не потерялось")

	-- Закрытие окна при открытом списке закрывает и форму, и список.
	f.form.pick:Click()
	c.B.ns.UI.Toggle()
	T.no(picker:IsShown(), "список закрыт вместе с окном")
	T.no(picker.search:HasFocus())
	c.B.ns.UI.Toggle("groups")
	T.ok(f.idle:IsShown(), "после окна — снова роли и кнопки")
	T.no(picker:IsShown())
	NoErrors(c.B, "автор")
end)
