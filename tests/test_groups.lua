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
