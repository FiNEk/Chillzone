-- Chillzone: кадры — просьбы офицерам гильдии объединения исключить игрока или пригласить его
-- (перенос из одной гильдии в другую). Сам аддон никого не исключает и не приглашает по
-- чужой просьбе: она лишь появляется во «Входящих» у офицеров гильдии, а исключает или
-- приглашает их щелчок (Uninvite и Invite игры). Своим щелчком просящий сразу исключает
-- только из своей гильдии, если ему это позволяют звание и права игры.
--
-- Кто может просить (получатель проверяет сам, просящий видит то же через Transfer.Rights):
--   - исключить из гильдии G: офицер G по ростеру получателя; владелец или офицер главной
--     гильдии по сертификату с подтверждённой ролью (Security.Level 3);
--   - пригласить в G: те же, а ещё офицер любой гильдии объединения (Security.Level 2 и выше),
--     если вторая гильдия просьбы — его собственная: он переносит своего игрока.
-- Перенос — два шага у просящего: исключить из первой гильдии (своим щелчком или просьбой её
-- офицерам), затем пригласить во вторую. Второй шаг начинается, когда первая гильдия ответила
-- «сделано» или «его нет», либо когда мой ростер больше не видит игрока. «Сделано» получатель
-- видит по своему ростеру: исключённого в нём нет (ростер полный или игрок исчез после щелчка
-- получателя), приглашённый в нём есть.
--
-- Кадры TQ, TA и TC (формат — в Codec.lua) идут прямым WHISPER без реле и без подписи: имя
-- отправителя удостоверяет сервер, гильдию и роль — сертификат по отпечатку (Security.Resolve).
-- Всё хранится только в памяти: /reload забывает и свои просьбы, и входящие.
local ADDON, ns = ...

local U, C, Codec, S, L = ns.Util, ns.Config, ns.Codec, ns.Security, ns.L
local Transfer = {}
ns.Transfer = Transfer

local tasks, byReq = {}, {} -- мои просьбы по порядку; номер текущего запроса -> просьба
local incoming = {} -- [ключ отправителя .. "#" .. номер] = просьба ко мне
local fromTimes, allTimes = {}, {} -- пределы входящих TQ за минуту
local serial, epoch = 0, 0
local lastAct, lastNotice = -math.huge, -math.huge
local NOTICE_GAP = 10

Transfer.stats = { asked = 0, received = 0, rejected = 0, acted = 0 }

local function Fire() ns.Fire("TRANSFER") end
local function Mine(guild)
	local g = ns.MyGuild()
	return g ~= nil and type(guild) == "string" and U.GuildKey(guild) == U.GuildKey(g)
end
local function Home() return U.GuildKey(ns.MyGuild() or "") end
local function Present(name) return ns.Roster.RankOf(name) ~= nil end
local function Officer(name) return ns.RecruitSync.IsOfficer(name) end

-- Владелец или офицер главной гильдии с подтверждённой ролью.
local function MainRole(c)
	return c ~= nil and U.IsMainGuild(c.guild) and S.Level(c) >= 3
end

---------------------------------------------------------------------------
-- Права
---------------------------------------------------------------------------

-- "owner", "main" (офицер главной), "officer" (офицер другой гильдии объединения с
-- подтверждённой ролью), "local" (офицер по ростеру, без сертификата с ролью) или nil.
function Transfer.Rights()
	if not ns.IsMember() or not Officer() then return nil end
	local c = S.MyCertificate()
	if MainRole(c) then
		local owner = ns.UnionAuthority and ns.UnionAuthority.Current()
		return (owner and c.role == "leader" and owner.public == c.public) and "owner" or "main"
	end
	if c and S.Level(c) >= 2 then return "officer" end
	return "local"
end
local function Wide(rights) return rights == "owner" or rights == "main" end

-- Могу ли просить исключить из guild (или исключить сам, если это моя гильдия).
function Transfer.CanKick(guild)
	local rights = Transfer.Rights()
	if not rights or not U.IsMemberGuild(guild) then return false end
	return Mine(guild) or Wide(rights)
end

-- Могу ли перенести игрока из from в to.
function Transfer.CanMove(from, to)
	local rights = Transfer.Rights()
	if not rights or not U.IsMemberGuild(from) or not U.IsMemberGuild(to) then return false end
	if U.GuildKey(from) == U.GuildKey(to) then return false end
	if Wide(rights) then return true end
	return rights == "officer" and Mine(from)
end

-- Исключить сам: права игры, звание игрока известно и ниже моего, это не я.
function Transfer.CanRemove(name)
	if not name or ns.IsMe(name) or not ns.Roster.Fresh() or not CanGuildRemove then return false end
	local ok, can = pcall(CanGuildRemove)
	if not ok or not can then return false end
	local rank, mine = ns.Roster.RankOf(name), ns.Roster.MyRank()
	return rank ~= nil and ns.Roster.rankKnown[U.Key(name)] == true and type(mine) == "number" and rank > mine
end

function Transfer.CanInvite()
	return CanGuildInvite ~= nil and CanGuildInvite() and true or false
end

-- Вызовы игры: только из щелчка игрока. Ошибка игры уходит в журнал.
local function Call(fn, what, name)
	if not fn then ns.Log("кадры: в игре нет функции «%s»", what); return false end
	local ok, err = pcall(fn, U.TellName(name))
	if not ok then ns.Log("кадры: %s %s не удалось: %s", what, U.Display(name), tostring(err)) end
	return ok
end
local function Uninvite(name)
	return Call((C_GuildInfo and C_GuildInfo.Uninvite) or GuildUninvite, "исключить", name)
end
local function Invite(name)
	return Call((C_GuildInfo and C_GuildInfo.Invite) or GuildInvite, "пригласить", name)
end

-- Гильдия игрока: мой ростер, затем сертификаты гильдий объединения, затем отчёты переписи.
function Transfer.GuessGuild(name)
	if not U.Key(name) then return nil end
	if Present(name) then return ns.MyGuild() end
	for _, e in ipairs(S.UnionGuilds()) do
		if not Mine(e.guild) and S.Member(e.guild, name) then return e.guild end
	end
	for _, e in ipairs(S.UnionGuilds()) do
		local row = not Mine(e.guild) and ns.Data.Row(e.guild)
		local r = row and row.r
		if r then
			if U.SameName(r.leader, name) then return e.guild end
			for _, o in ipairs(r.officers or {}) do
				if U.SameName(o.name, name) then return e.guild end
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Просящий
---------------------------------------------------------------------------

-- Кому писать: офицеры гильдии в игре, глава первым. Своей — по ростеру, чужой — по
-- последнему отчёту переписи; известный сертификат рядового исключает адресата.
local function Targets(guild)
	local out, seen = {}, {}
	local function Add(name)
		local key = U.Key(name)
		if not key or seen[key] or ns.IsMe(name) or #out >= C.TRANSFER_TARGETS then return end
		seen[key] = true
		out[#out + 1] = { name = name, key = key, state = "queued" }
	end
	local list = {}
	if Mine(guild) then
		if not ns.Roster.Fresh() then return out end
		for _, m in ipairs(ns.Roster.members) do
			if m.online and Officer(m.name) then list[#list + 1] = { name = m.name, rank = m.rank } end
		end
	else
		local row = ns.Data.Row(guild)
		local r = row and row.r
		if not r then return out end
		local function Allowed(name)
			local c = S.Member(guild, name)
			return not c or c.role == "leader" or c.role == "officer"
		end
		if r.leader and r.leaderOnline and Allowed(r.leader) then list[#list + 1] = { name = r.leader, rank = 0 } end
		for _, o in ipairs(r.officers or {}) do
			if o.online and Allowed(o.name) then list[#list + 1] = { name = o.name, rank = o.rank or 1 } end
		end
	end
	table.sort(list, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return (U.Key(a.name) or "") < (U.Key(b.name) or "")
	end)
	for _, p in ipairs(list) do Add(p.name) end
	return out
end

local function Withdraw(req, except)
	if not req then return end
	byReq[req.id] = nil
	for _, t in ipairs(req.targets) do
		if t.key ~= except and (t.state == "sent" or t.state == "R") then
			ns.Comm.Send("WHISPER", Codec.EncodeTransferCancel(req.id), { target = t.name, key = "tc:" .. req.id .. ":" .. t.key })
			t.state = "cancelled"
		end
	end
end

local function Send(task)
	local req = task.req
	for _, t in ipairs(req.targets) do
		if t.state == "queued" then
			if not Mine(req.guild) then S.Introduce(t.name) end -- получатель сразу проверит мою роль
			local sent = ns.Comm.Send("WHISPER", Codec.EncodeTransfer(req), {
				target = t.name, key = "tq:" .. req.id .. ":" .. t.key, prio = true,
				done = function(ok)
					if task.req ~= req or t.state ~= "queued" then return end
					t.state, t.sentAt = ok and "sent" or "offline", ns.Now()
					Fire()
				end,
			})
			if not sent then t.state = "offline" end
		end
	end
	Transfer.stats.asked = Transfer.stats.asked + 1
	ns.After(C.TRANSFER_WAIT + 1, "transfer wait", Fire)
end

-- Новый запрос текущего шага просьбы: kind "K" — исключить из guild, "I" — пригласить в неё.
local function Ask(task, kind, guild, other)
	Withdraw(task.req)
	serial = serial + 1
	local st = ns.ServerTime()
	local c = S.MyCertificate()
	local req = { id = Codec.Base36(st) .. "." .. Codec.Base36(serial), kind = kind, guild = guild,
		name = U.Display(task.name), other = other, fp = c and c.fp or "0", st = st, at = ns.Now(),
		targets = Targets(guild) }
	task.req, task.localStep = req, nil
	byReq[req.id] = task
	if #req.targets > 0 then Send(task) end
end

local function Finish(task, outcome)
	Withdraw(task.req)
	task.phase, task.outcome, task.doneAt, task.localStep = "done", outcome, ns.Now(), nil
	ns.Log("кадры: %s — %s", U.Display(task.name), outcome)
	Fire()
end

-- Второй шаг переноса: пригласить в to. В свою гильдию — своим щелчком, если могу.
local function StartJoin(task)
	Withdraw(task.req)
	task.phase, task.req, task.tried = "join", nil, nil
	if Mine(task.to) and Transfer.CanInvite() then
		task.localStep = true
	else
		Ask(task, "I", task.to, task.from)
	end
	Fire()
end

-- Первый шаг сделан: state "D" — исключён, "O" — его там и не было.
local function Left(task, state)
	if task.op == "kick" then Finish(task, state == "O" and "absent" or "done") else StartJoin(task) end
end

-- Исключить своим щелчком из своей гильдии.
local function Remove(task)
	local now = ns.Now()
	if now - lastAct < C.TRANSFER_ACT_GAP then ns.Print(L.TRANSFER_WAIT); return false end
	if not Transfer.CanRemove(task.name) then ns.Print(L.TRANSFER_CANT_REMOVE, U.Display(task.name)); return false end
	lastAct = now
	if not Uninvite(task.name) then ns.Print(L.TRANSFER_FAILED); return false end
	task.tried, task.seen = true, true
	Transfer.stats.acted = Transfer.stats.acted + 1
	ns.Log("кадры: исключаю %s своим щелчком", U.Display(task.name))
	ns.Roster.RequestScan(true)
	Fire()
	return true
end

local function NewTask(op, name, from, to)
	local task = { op = op, name = U.Display(name), from = from, to = to, phase = "leave", at = ns.Now(),
		home = Home(), seen = Mine(from) and Present(name) or nil }
	table.insert(tasks, 1, task)
	while #tasks > C.TRANSFER_TASKS do
		local old = table.remove(tasks)
		Withdraw(old.req)
	end
	return task
end

-- Первый шаг: из своей гильдии — своим щелчком, если могу, иначе просьбой её офицерам.
local function StartLeave(task)
	if Mine(task.from) and ns.Roster.Fresh() and not Present(task.name) and ns.Roster.complete then
		Left(task, "O")
	elseif Mine(task.from) and Transfer.CanRemove(task.name) then
		task.localStep = true
		Remove(task)
	else
		Ask(task, "K", task.from, task.to)
	end
	Fire()
end

-- Проверка имени: nil или текст ошибки.
local function BadName(name)
	if not U.Key(name) or #name > 64 or name:find("[~=,:|%c]") then return L.TRANSFER_BAD_NAME end
	if ns.IsMe(name) then return L.TRANSFER_SELF end
	return nil
end

-- Из щелчка игрока: исключить name из guild. Возвращает задачу или nil и текст ошибки.
function Transfer.Kick(name, guild)
	name = U.Trim(name or "")
	local bad = BadName(name)
	if bad then return nil, bad end
	if not Transfer.CanKick(guild) then return nil, L.TRANSFER_NO_RIGHTS end
	if Mine(guild) and ns.Roster.complete and not Present(name) then return nil, L.TRANSFER_NOT_HERE end
	local task = NewTask("kick", name, guild, nil)
	StartLeave(task)
	return task
end

-- Из щелчка игрока: перенести name из from в to.
function Transfer.Move(name, from, to)
	name = U.Trim(name or "")
	local bad = BadName(name)
	if bad then return nil, bad end
	if not Transfer.CanMove(from, to) then return nil, L.TRANSFER_NO_RIGHTS end
	if Mine(to) and Present(name) then return nil, L.TRANSFER_ALREADY end
	local task = NewTask("move", name, from, to)
	StartLeave(task)
	return task
end

-- Кнопка своего шага: исключить или пригласить своим щелчком.
function Transfer.Step(task)
	if not task.localStep or task.phase == "done" then return false end
	if task.phase == "leave" then return Remove(task) end
	local now = ns.Now()
	if now - lastAct < C.TRANSFER_ACT_GAP then ns.Print(L.TRANSFER_WAIT); return false end
	if not Transfer.CanInvite() then ns.Print(L.TRANSFER_CANT_INVITE); return false end
	lastAct = now
	if not Invite(task.name) then ns.Print(L.TRANSFER_FAILED); return false end
	task.tried = true
	Transfer.stats.acted = Transfer.stats.acted + 1
	ns.Log("кадры: приглашаю %s своим щелчком", U.Display(task.name))
	Fire()
	return true
end

-- Спросить заново: тех же офицеров или тех, кто в игре сейчас.
function Transfer.Retry(task)
	if task.phase == "done" or not task.req then return false end
	Ask(task, task.req.kind, task.req.guild, task.req.other)
	Fire()
	return true
end

-- Отозвать просьбу (или убрать завершённую).
function Transfer.Cancel(task)
	for i, t in ipairs(tasks) do
		if t == task then
			table.remove(tasks, i)
			if task.phase ~= "done" then Withdraw(task.req) end
			Fire()
			return true
		end
	end
	return false
end

function Transfer.Tasks() return tasks end

-- Ждём ли ещё ответа хотя бы одного адресата текущего запроса.
function Transfer.Waiting(task)
	local req = task.req
	if not req or task.phase == "done" then return false end
	for _, t in ipairs(req.targets) do
		if t.state == "queued" then return true end
		if t.state == "sent" and ns.Now() - (t.sentAt or req.at) <= C.TRANSFER_WAIT then return true end
	end
	return false
end

-- Ответ получателя.
ns.Comm.On("TA", function(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx then return false end
	local id, state = Codec.DecodeTransferAnswer(msg)
	local task = id and byReq[id]
	if not task or task.phase == "done" or not task.req or task.req.id ~= id then return false end
	local key = U.Key(sender)
	for _, t in ipairs(task.req.targets) do
		if t.key == key then
			if t.state == "cancelled" then return false end
			t.state = state
			if state == "D" or state == "O" then
				Withdraw(task.req, key)
				if task.phase == "leave" then Left(task, state) else Finish(task, "done") end
			end
			Fire()
			return true
		end
	end
	return false
end)

-- Сервер ответил «нет такого игрока»: адресат вышел, его ответа не ждём.
ns.On("WHISPER_UNAVAILABLE", function(key)
	local changed = false
	for _, task in ipairs(tasks) do
		for _, t in ipairs(task.req and task.phase ~= "done" and task.req.targets or {}) do
			if t.key == key and (t.state == "queued" or t.state == "sent") then t.state, changed = "offline", true end
		end
	end
	if changed then Fire() end
end)

---------------------------------------------------------------------------
-- Получатель
---------------------------------------------------------------------------

local function Reply(to, id, state)
	ns.Comm.Send("WHISPER", Codec.EncodeTransferAnswer(id, state), { target = to, key = "ta:" .. id .. ":" .. U.Key(to) })
end

local function Trim(list, now)
	while list[1] and now - list[1] > 60 do table.remove(list, 1) end
end
local function Room(sender)
	local now, key = ns.Now(), U.Key(sender)
	Trim(allTimes, now)
	local mine = fromTimes[key] or {}
	fromTimes[key] = mine
	Trim(mine, now)
	if #allTimes >= C.TRANSFER_ALL_PER_MIN or #mine >= C.TRANSFER_PER_MIN then return false end
	allTimes[#allTimes + 1], mine[#mine + 1] = now, now
	return true
end

function Transfer.Count()
	local n = 0
	for _ in pairs(incoming) do n = n + 1 end
	return n
end

function Transfer.Incoming()
	local list = {}
	for _, item in pairs(incoming) do list[#list + 1] = item end
	table.sort(list, function(a, b)
		if a.at ~= b.at then return a.at > b.at end
		return a.slot < b.slot
	end)
	return list
end

local function Notice(item)
	local now = ns.Now()
	if now - lastNotice < NOTICE_GAP then return end
	lastNotice = now
	if item.kind == "K" then
		ns.Print(L.TRANSFER_NOTICE_KICK, U.Display(item.from), item.byGuild, U.Display(item.name))
	else
		ns.Print(L.TRANSFER_NOTICE_INVITE, U.Display(item.from), item.byGuild, U.Display(item.name))
	end
end

-- role: "leader"/"officer" — роль просящего; byGuild — его гильдия.
local function Accept(q, sender, role, byGuild)
	if not Officer() or not Mine(q.guild) then return end
	local slot = U.Key(sender) .. "#" .. q.id
	if incoming[slot] then Reply(sender, q.id, "R"); return end
	local here = Present(q.name)
	if q.kind == "K" and not here and ns.Roster.complete then Reply(sender, q.id, "O"); return end
	if q.kind == "I" and here then Reply(sender, q.id, "D"); return end
	if Transfer.Count() >= C.TRANSFER_INBOX then
		ns.Log("кадры: входящих больше %d, просьба %s отброшена", C.TRANSFER_INBOX, U.Display(sender))
		return
	end
	local item = { slot = slot, id = q.id, from = sender, role = role, byGuild = byGuild, kind = q.kind,
		guild = ns.MyGuild(), name = q.name, other = q.other, st = q.st, at = ns.Now(), seen = here or nil }
	incoming[slot] = item
	Transfer.stats.received = Transfer.stats.received + 1
	ns.Log("кадры: %s (%s) просит %s %s", U.Display(sender), byGuild, q.kind == "K" and "исключить" or "пригласить",
		U.Display(q.name))
	Reply(sender, q.id, "R")
	Notice(item)
	Fire()
end

-- Право просящего по сертификату: "main" — владелец или офицер главной; "union" — офицер
-- другой гильдии, приглашающий в мою гильдию игрока из своей. Иначе nil.
local function CertRight(c, q)
	if MainRole(c) then return "main" end
	if q.kind == "I" and S.Level(c) >= 2 and q.other and U.GuildKey(q.other) == U.GuildKey(c.guild)
		and U.IsMemberGuild(c.guild) then return "union" end
	return nil
end

ns.Comm.On("TQ", function(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx or ns.IsMe(sender) or not Officer() then return false end
	local q = Codec.DecodeTransfer(msg)
	if not q or not Mine(q.guild) or not U.Key(q.name) then return false end
	local now = ns.ServerTime()
	if q.st > now + 300 or now - q.st > C.TRANSFER_KEEP then return false end
	if not Room(sender) then return false end
	if Officer(sender) then
		-- Офицер моей гильдии: его права видны в моём ростере.
		local role = ns.Roster.RankOf(sender) == 0 and "leader" or "officer"
		Accept(q, sender, role, ns.MyGuild())
		return true
	end
	local mark = epoch
	local asked = S.Resolve(q.fp, sender, sender, function(c)
		if epoch ~= mark then return end
		if not CertRight(c, q) then
			Transfer.stats.rejected = Transfer.stats.rejected + 1
			ns.Log("кадры: просьба %s (%s) без права отклонена", U.Display(sender), c.guild)
			return
		end
		Accept(q, sender, c.role, c.guild)
	end)
	if not asked then Transfer.stats.rejected = Transfer.stats.rejected + 1 end
	return true
end)

-- Просящий отозвал просьбу.
ns.Comm.On("TC", function(msg, sender, dist, ctx)
	if dist ~= "WHISPER" or ctx then return false end
	local id = Codec.DecodeTransferCancel(msg)
	local slot = id and (U.Key(sender) .. "#" .. id)
	if not slot or not incoming[slot] then return false end
	incoming[slot] = nil
	Fire()
	return true
end)

-- Щелчок офицера: исключить или пригласить по просьбе.
function Transfer.Act(item)
	if not item or incoming[item.slot] ~= item then return false end
	local now = ns.Now()
	if now - lastAct < C.TRANSFER_ACT_GAP then ns.Print(L.TRANSFER_WAIT); return false end
	if item.kind == "K" then
		if not Transfer.CanRemove(item.name) then ns.Print(L.TRANSFER_CANT_REMOVE, U.Display(item.name)); return false end
		lastAct = now
		if not Uninvite(item.name) then ns.Print(L.TRANSFER_FAILED); return false end
	else
		if not Transfer.CanInvite() then ns.Print(L.TRANSFER_CANT_INVITE); return false end
		lastAct = now
		if not Invite(item.name) then ns.Print(L.TRANSFER_FAILED); return false end
	end
	-- Тот же игрок мог быть в просьбах нескольких офицеров: щелчок засчитывается всем.
	local key = U.Key(item.name)
	for _, other in pairs(incoming) do
		if other.kind == item.kind and U.Key(other.name) == key then other.tried = true end
	end
	Transfer.stats.acted = Transfer.stats.acted + 1
	ns.Log("кадры: %s %s по просьбе %s", item.kind == "K" and "исключаю" or "приглашаю", U.Display(item.name),
		U.Display(item.from))
	if item.kind == "K" then ns.Roster.RequestScan(true) end
	Fire()
	return true
end

-- Отказ: просящий видит «отклонено».
function Transfer.Decline(item)
	if not item or incoming[item.slot] ~= item then return false end
	incoming[item.slot] = nil
	Reply(item.from, item.id, "N")
	Fire()
	return true
end

---------------------------------------------------------------------------
-- Ростер: сделано ли
---------------------------------------------------------------------------

local function ObserveIncoming(now)
	if not Officer() then
		if next(incoming) then wipe(incoming); return true end
		return false
	end
	local changed = false
	for slot, item in pairs(incoming) do
		local here = Present(item.name)
		if here then item.seen = true end
		local state
		if not Mine(item.guild) or now - item.at > C.TRANSFER_KEEP then
			state = false
		elseif item.kind == "K" and not here and (ns.Roster.complete or (item.tried and item.seen)) then
			state = item.seen and "D" or "O"
		elseif item.kind == "I" and here then
			state = "D"
		end
		if state ~= nil then
			incoming[slot], changed = nil, true
			if state then Reply(item.from, item.id, state) end
		end
	end
	return changed
end

local function ObserveTasks(now)
	local changed = false
	for i = #tasks, 1, -1 do
		local task = tasks[i]
		if task.home ~= Home() then
			Withdraw(task.req)
			table.remove(tasks, i)
			changed = true
		elseif task.phase == "done" then
			if now - task.doneAt > C.TRANSFER_DONE_KEEP then table.remove(tasks, i); changed = true end
		elseif now - task.at > C.TRANSFER_KEEP then
			Withdraw(task.req)
			table.remove(tasks, i)
			changed = true
		elseif task.phase == "leave" and Mine(task.from) then
			if Present(task.name) then
				task.seen = true
			elseif ns.Roster.complete or (task.tried and task.seen) then
				Withdraw(task.req)
				Left(task, task.seen and "D" or "O")
				changed = true
			end
		elseif task.phase == "join" and Mine(task.to) and Present(task.name) then
			Finish(task, "done")
			changed = true
		end
	end
	return changed
end

ns.On("ROSTER", function()
	local now = ns.Now()
	local a = ObserveIncoming(now)
	local b = ObserveTasks(now)
	for key, list in pairs(fromTimes) do
		Trim(list, now)
		if not list[1] then fromTimes[key] = nil end
	end
	if a or b then Fire() end
end)

-- GUILD_CHANGED приходит и при смене звания: забываются только просьбы прежней гильдии
-- (ObserveTasks и ObserveIncoming сверяют гильдию каждой).
ns.On("GUILD_CHANGED", function()
	epoch = epoch + 1
	local now = ns.Now()
	local a = ObserveIncoming(now)
	local b = ObserveTasks(now)
	if a or b then Fire() end
end)

ns.Activity.Probe(function()
	local n = 0
	for _, task in ipairs(tasks) do
		if Transfer.Waiting(task) then n = n + 1 end
	end
	if n > 0 then return { kind = "wait", text = L.ACT_TRANSFER:format(n), detail = L.ACT_TRANSFER_TIP } end
end)

ns.Status(function()
	local n = Transfer.Count()
	if n > 0 or #tasks > 0 then return L.TRANSFER_STATUS:format(#tasks, n) end
end)
