-- Chillzone: поиск групп. Доска объявлений объединения: «собираю группу» и «ищу группу».
--
-- Объявление G1 подписывается и расходится как строка чата: S1 по GUILD своей гильдии и через
-- реле остальным (режим P). Автор повторяет его раз в every минут. Получатели держат запись
-- два повтора и запас, считая от подписанного времени пакета, поэтому пересланный позже
-- старый пакет срок не продлевает. Порядок пакетов автора — по времени и номеру из конверта
-- S1: снятое объявление (X) старым пакетом не вернуть.
--
-- Заявки (GA), их отзыв (GW) и ответ автора (GR) идут шёпотом напрямую. Отправителя шёпота
-- подтверждает сервер, принадлежность к объединению — сертификат по отпечатку (как OQ в
-- Online.lua). Класс и уровень в заявке — слова просящего.
--
-- Вошедший позже просит объявления запросом GQ по GUILD: авторы из его гильдии повторяют
-- свой последний пакет, репортёр отдаёт чужие (RG) из своей памяти.
--
-- Приглашение в группу — только из щелчка игрока. Роль игрока игра аддону не сообщает:
-- роли называет сам просящий, нужные роли ведёт автор объявления. Имена состава группы
-- по сети не передаются. Название объявления — свободный текст: списка мест в аддоне нет,
-- список занятий игры (C_LFGList) служит только подсказкой. Сроки и лимиты портированы
-- из Olympus Groups.lua и Board.lua.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Groups = {}
ns.Groups = Groups

Groups.KINDS = { "D", "R", "P", "Q", "O" }
Groups.ROLES = { "t", "h", "d" }
Groups.CAPS = { 5, 10, 20, 25, 40 }

local board = {} -- [ключ автора] = объявление с доски
local closed = {} -- [ключ автора] = { at, seq } снятого объявления: старый пакет его не вернёт
local applied = {} -- [ключ автора] = моя заявка: { id, at, state = "sent" | "invited" | "declined" }
local lastApply = {} -- [ключ автора] = когда я просился к нему
local lastHeard = {} -- [ключ просящего] = когда он просился ко мне

local saved -- ns.char.groups: моё объявление, заявки ко мне и мои роли переживают /reload
local mine -- моё объявление: { mode, id, kind, title, note, roles = { t, h, d }, cap, min }
local applicants = {} -- заявки ко мне по порядку: { key, name, guild, class, level, roles, note, at, state }
local declined = {} -- [ключ] = true: кому я отказал по этому объявлению
local myWire -- последний подписанный пакет моего объявления: им же отвечаю на GQ
local sealing, dirty = false, false
local lastSent, nextBeat, sentSize = -1e9, 0, nil
local lastRaise, raises = -1e9, {}
local lastAsk, lastServe, lastServeMine = -1e9, -1e9, -1e9
local askAt -- когда после входа просить объявления; nil — уже просили
local rosterPending = false

Groups.stats = { heard = 0, stale = 0, served = 0 }

---------------------------------------------------------------------------
-- Игрок и его группа
---------------------------------------------------------------------------
local function GroupSize()
	local n = GetNumGroupMembers and GetNumGroupMembers() or 0
	return math.max(1, n)
end

local function InGroup()
	return (IsInGroup and IsInGroup()) and true or false
end

-- Собирать может одиночка или лидер: только он приглашает наверняка.
local function Leading()
	return not InGroup() or ((UnitIsGroupLeader and UnitIsGroupLeader("player")) and true or false)
end

local function Me()
	local _, class = UnitClass("player")
	return class, UnitLevel("player") or 0
end

-- Ключи тех, кто сейчас со мной в группе. Имена остаются на этом клиенте.
local function MemberKeys()
	local out = {}
	local n = GetNumGroupMembers and GetNumGroupMembers() or 0
	if n < 2 or not UnitFullName then return out end
	local raid = IsInRaid and IsInRaid()
	for i = 1, raid and n or n - 1 do
		local name, realm = UnitFullName((raid and "raid" or "party") .. i)
		if type(name) == "string" and name ~= "" then
			local key = U.Key((U.ParsePlayer(name, realm, ns.realm)))
			if key then out[key] = true end
		end
	end
	return out
end

local function AnyRole(r)
	return type(r) == "table" and ((r.t or 0) > 0 or (r.h or 0) > 0 or (r.d or 0) > 0)
end

local function CopyRoles(r, flags)
	local out = {}
	for _, k in ipairs(Groups.ROLES) do
		local n = math.max(0, math.min(Codec.GROUP_CAP, math.floor(tonumber(type(r) == "table" and r[k]) or 0)))
		out[k] = flags and math.min(1, n) or n
	end
	return out
end

-- «танк, 2 лекаря»: counts — писать числа (нужные роли группы), иначе только названия.
function Groups.RoleText(r, counts)
	local out = {}
	for _, k in ipairs(Groups.ROLES) do
		local n = type(r) == "table" and r[k] or 0
		if n > 0 then
			local key = "GROUPS_ROLE_" .. k:upper()
			if counts and n > 1 then
				out[#out + 1] = n .. " " .. U.Plural(n, L[key], L[key .. "_FEW"], L[key .. "_MANY"])
			else
				out[#out + 1] = L[key]
			end
		end
	end
	return table.concat(out, ", ")
end

---------------------------------------------------------------------------
-- Мои роли: запоминаются на персонажа, подставляются в заявку и в «ищу группу»
---------------------------------------------------------------------------
function Groups.MyRoles()
	local r = saved and saved.roles or {}
	return { t = r.t and 1 or 0, h = r.h and 1 or 0, d = r.d and 1 or 0 }
end

function Groups.SetRole(role, on)
	if not saved or (role ~= "t" and role ~= "h" and role ~= "d") then return end
	saved.roles[role] = on and true or false
	ns.Fire("GROUPS")
end

-- Отметка «сообщить в общий чат» при размещении.
function Groups.Announcing()
	return not saved or saved.announce ~= false
end

function Groups.SetAnnouncing(on)
	if saved then saved.announce = on and true or false end
end

---------------------------------------------------------------------------
-- Доска
---------------------------------------------------------------------------
local function Count()
	local n = 0
	for _ in pairs(board) do n = n + 1 end
	return n
end

-- Чем больше объявлений, тем реже каждое повторяется: вся доска — около GROUPS_PER_MIN в минуту.
local function Every()
	return math.max(C.GROUPS_EVERY_MIN, math.min(C.GROUPS_EVERY_MAX, math.ceil((Count() + 1) / C.GROUPS_PER_MIN)))
end

local function Expired(e, now)
	return now >= e.raised + C.GROUPS_LIFE + 60 or now >= e.at + (2 * e.every + 2) * 60
end

local function Stamp(wire)
	local at, seq = (type(wire) == "string" and wire or ""):match("^S1~[%w_-]+~(%d+)~(%d+)~")
	return tonumber(at), tonumber(seq)
end

local function Newer(at, seq, than)
	return not than or at > than.at or (at == than.at and seq > than.seq)
end

local function Drop(key)
	if not board[key] then return false end
	board[key] = nil
	applied[key] = nil
	return true
end

function Groups.Receive(msg, _, dist, ctx)
	if dist ~= "GUILD" and dist ~= "RELAY" then return end
	local c = ctx and ctx.authenticated and ctx.certificate
	if not c or not ns.IsMember() then return end
	local l = Codec.DecodeGroup(msg)
	if not l or not U.IsMemberGuild(l.guild) then return end
	local key = c.key
	if not key or key == ns.myKey or U.GuildKey(c.guild) ~= U.GuildKey(l.guild) then return end
	local own, theirs = U.GuildKey(ns.MyGuild()), U.GuildKey(l.guild)
	if dist == "GUILD" and theirs ~= own then return end -- по GUILD пишут только согильдийцы
	if dist == "RELAY" and theirs == own then return end -- своя гильдия приходит напрямую
	local at, seq = Stamp(ctx.wire)
	if not at then return end
	Groups.stats.heard = Groups.stats.heard + 1
	local old = board[key]
	if not Newer(at, seq, closed[key]) or not Newer(at, seq, old) then
		Groups.stats.stale = Groups.stats.stale + 1
		return
	end
	if l.mode == "X" then
		closed[key] = { at = at, seq = seq }
		if Drop(key) then ns.Fire("GROUPS") end
		return
	end
	l.key, l.name, l.at, l.seq, l.wire, l.cert = key, U.Display(c.name), at, seq, ctx.wire, c.raw
	l.raised = math.min(l.id, at) -- размещено не позже, чем подписано
	local ignored = ns.store and ns.store.ignore[key]
	if ignored or Expired(l, ns.ServerTime()) or (not old and Count() >= C.GROUPS_MAX) then
		if Drop(key) then ns.Fire("GROUPS") end
		return
	end
	-- Новое объявление того же автора: прежняя заявка к нему уже не относится.
	if old and old.id ~= l.id then applied[key] = nil end
	board[key] = l
	ns.Fire("GROUPS")
end
ns.Comm.On("G1", Groups.Receive)

-- Объявления для вкладки: группы и игроки, новые сверху. kind — только этот вид мест.
-- У записи: applied — состояние моей заявки, short — мой уровень ниже нужного.
function Groups.List(kind)
	local groups, players = {}, {}
	local _, level = Me()
	for key, e in pairs(board) do
		if not kind or e.kind == kind then
			local a = applied[key]
			e.applied = a and a.id == e.id and a.state or nil
			e.short = e.min > 0 and level < e.min
			local list = e.mode == "G" and groups or players
			list[#list + 1] = e
		end
	end
	local function order(a, b)
		if a.raised ~= b.raised then return a.raised > b.raised end
		return a.key < b.key
	end
	table.sort(groups, order)
	table.sort(players, order)
	return groups, players
end

function Groups.Get(key)
	return board[key]
end

-- Сколько объявлений на доске, считая моё.
function Groups.Count()
	return Count() + (mine and 1 or 0)
end

---------------------------------------------------------------------------
-- Моё объявление
---------------------------------------------------------------------------
local LOWERED = {
	expired = "GROUPS_LOWERED_EXPIRED", full = "GROUPS_LOWERED_FULL",
	notleader = "GROUPS_LOWERED_NOT_LEADER", joined = "GROUPS_LOWERED_JOINED",
}

local function Forget()
	mine, myWire, dirty, sentSize = nil, nil, false, nil
	wipe(applicants)
	wipe(declined)
	wipe(lastHeard)
	if saved then saved.mine = nil end
end

local function Broadcast(prio)
	local guild = ns.MyGuild()
	if not mine or not guild then return false, "failed" end
	local class, level = Me()
	local size, every = GroupSize(), Every()
	local msg = Codec.EncodeGroup({
		mode = mine.mode, id = mine.id, guild = guild, class = class, level = level, kind = mine.kind,
		roles = mine.roles, size = mine.mode == "G" and size or 1, cap = mine.cap, min = mine.min,
		every = every, title = mine.title, note = mine.note,
	})
	if not msg then return false, "failed" end
	local id, now = mine.id, ns.Now()
	dirty, sealing, lastSent, nextBeat, sentSize = false, true, now, now + every * 60, size
	local ok, why = ns.Security.Seal(msg, function(wire)
		sealing = false
		if not mine or mine.id ~= id then return end -- сняли, пока шла подпись
		if not wire then
			dirty = true
			return
		end
		myWire = wire
		ns.Comm.Send("GUILD", wire, { prio = prio, key = "groups:mine" })
		ns.Relay.Out("P", wire)
	end)
	if not ok then
		sealing, dirty = false, true
		return false, why
	end
	return true
end

function Groups.Mine()
	return mine
end

-- Заявки ко мне, как пришли.
function Groups.Applicants()
	return applicants
end

function Groups.Lower(reason)
	if not mine then return false end
	local id, guild = mine.id, ns.MyGuild()
	Forget()
	local msg = guild and ns.IsMember() and Codec.EncodeGroup({ mode = "X", id = id, guild = guild })
	if msg then
		ns.Security.Seal(msg, function(wire)
			if not wire then return end
			ns.Comm.Send("GUILD", wire, { prio = true, key = "groups:mine" })
			ns.Relay.Out("P", wire)
		end)
	end
	if reason and LOWERED[reason] then ns.Print(L[LOWERED[reason]]) end
	ns.Fire("GROUPS")
	return true
end

-- Сколько секунд до следующего размещения (0 — можно сейчас).
function Groups.RaiseWait()
	local now = ns.Now()
	local wait = math.max(0, lastRaise + C.GROUPS_LIST_GAP - now)
	while raises[1] and now - raises[1] >= 3600 do table.remove(raises, 1) end
	if #raises >= C.GROUPS_LIST_HOUR then wait = math.max(wait, raises[1] + 3600 - now) end
	return math.ceil(wait)
end

local function Normalize(spec)
	local mode = spec.mode == "P" and "P" or "G"
	local cap = math.floor(tonumber(spec.cap) or 5)
	if cap < 2 or cap > Codec.GROUP_CAP then cap = 5 end
	return {
		mode = mode,
		kind = Codec.GROUP_KINDS[spec.kind] and spec.kind or "O",
		title = Codec.GroupText(spec.title, Codec.GROUP_TITLE),
		note = Codec.GroupText(spec.note, Codec.GROUP_NOTE),
		roles = CopyRoles(spec.roles, mode == "P"),
		cap = mode == "G" and cap or 0,
		min = math.max(0, math.min(255, math.floor(tonumber(spec.min) or 0))),
	}
end

-- Строка для общего чата: её видят и те, кто не открывал вкладку.
local function Announce(l)
	if not ns.Chat then return end
	local text
	if l.mode == "G" then
		local need = Groups.RoleText(l.roles, true)
		text = L.GROUPS_ANNOUNCE_G:format(l.title) .. (need ~= "" and (" " .. L.GROUPS_ANNOUNCE_NEED:format(need)) or "")
	else
		local class, level = Me()
		local who = (L.CLASS[class] or "?") .. ", " .. level
		text = L.GROUPS_ANNOUNCE_P:format(who, Groups.RoleText(l.roles))
			.. (l.title ~= "" and (" " .. L.GROUPS_ANNOUNCE_WANT:format(l.title)) or "")
	end
	ns.Chat.Send("A", text .. " " .. L.GROUPS_ANNOUNCE_TAIL)
end

-- Разместить объявление или поправить своё. spec: { mode = "G" | "P", kind, title, note,
-- roles = { t, h, d }, cap, min, announce }. Возвращает true или false и причину:
-- "member", "nocert", "notleader", "ingroup", "title", "roles", "full", "wait" (и секунды),
-- причины Security.Seal. Правка того же вида объявления лимит размещений не тратит.
function Groups.Raise(spec)
	if not ns.IsMember() or not ns.MyGuild() then return false, "member" end
	if not ns.Security.MyCertificate() then return false, "nocert" end
	local l = Normalize(spec or {})
	if l.mode == "G" then
		if not Leading() then return false, "notleader" end
		if l.title == "" then return false, "title" end
		if GroupSize() >= l.cap then return false, "full" end
	else
		if InGroup() then return false, "ingroup" end
		if not AnyRole(l.roles) then return false, "roles" end
	end
	local edit = mine ~= nil and mine.mode == l.mode
	local before = mine
	if not edit then
		local wait = Groups.RaiseWait()
		if wait > 0 then return false, "wait", wait end
		l.id = ns.ServerTime()
	else
		l.id = mine.id
	end
	mine = l
	local ok, why = Broadcast(true)
	if not ok then
		mine = before
		return false, why
	end
	saved.mine = l
	if not edit then
		-- Другое объявление: заявки и пакет прежнего к нему не относятся.
		wipe(applicants)
		wipe(declined)
		wipe(lastHeard)
		myWire = nil
		local now = ns.Now()
		lastRaise, raises[#raises + 1] = now, now
		if spec.announce then ns.SafeCall("groups announce", Announce, l) end
	end
	ns.Fire("GROUPS")
	return true
end

-- Автор сам правит нужные роли: игра не говорит, кем пришёл человек.
function Groups.SetNeed(role, n)
	if not mine or mine.mode ~= "G" or (role ~= "t" and role ~= "h" and role ~= "d") then return end
	n = math.max(0, math.min(Codec.GROUP_CAP, math.floor(tonumber(n) or 0)))
	if mine.roles[role] == n then return end
	mine.roles[role] = n
	dirty = true
	ns.Fire("GROUPS")
end

---------------------------------------------------------------------------
-- Заявки: сторона просящего
---------------------------------------------------------------------------
local function OpenApplies()
	local n = 0
	for _, a in pairs(applied) do
		if a.state == "sent" then n = n + 1 end
	end
	return n
end

-- Попроситься в группу автора key. Причины отказа: "gone", "nocert", "lockdown", "already",
-- "wait", "many", "roles", "level", "failed".
function Groups.Apply(key, roles, note)
	local e = board[key]
	if not e or e.mode ~= "G" then return false, "gone" end
	local cert, guild = ns.Security.MyCertificate(), ns.MyGuild()
	if not cert or not guild then return false, "nocert" end
	if ns.Comm.InLockdown() then return false, "lockdown" end
	local a, now = applied[key], ns.Now()
	if a and a.id == e.id then return false, "already" end
	if lastApply[key] and now - lastApply[key] < C.GROUPS_APPLY_GAP then return false, "wait" end
	if OpenApplies() >= C.GROUPS_APPLY_OPEN then return false, "many" end
	roles = CopyRoles(roles, true)
	if not AnyRole(roles) then return false, "roles" end
	local class, level = Me()
	if e.min > 0 and level < e.min then return false, "level" end
	local entry = { id = e.id, at = now, state = "sent", roles = roles }
	local name = e.name
	ns.Security.Introduce(name) -- автору не придётся спрашивать сертификат отдельно
	local sent = ns.Comm.Send("WHISPER", Codec.EncodeGroupApply(e.id, cert.fp, guild, class, level, roles, note), {
		target = name, prio = true, key = "ga:" .. key,
		done = function(ok)
			if ok or applied[key] ~= entry then return end
			applied[key] = nil
			ns.Print(L.GROUPS_APPLY_FAILED, name)
			ns.Fire("GROUPS")
		end,
	})
	if not sent then return false, "failed" end
	applied[key], lastApply[key] = entry, now
	ns.Fire("GROUPS")
	return true
end

function Groups.Withdraw(key)
	local a = applied[key]
	if not a then return false end
	applied[key] = nil
	local e = board[key]
	if e and e.id == a.id and a.state == "sent" then
		ns.Comm.Send("WHISPER", Codec.EncodeGroupWithdraw(a.id), { target = e.name, key = "gw:" .. key })
	end
	ns.Fire("GROUPS")
	return true
end

-- Ответ принимается только от того, к кому я просился, и только на ту же заявку.
ns.Comm.On("GR", function(msg, sender, dist)
	if dist ~= "WHISPER" then return end
	local id, answer = Codec.DecodeGroupReply(msg)
	local key = U.Key(sender)
	local a = key and applied[key]
	if not id or not a or a.id ~= id or a.state == "declined" then return end
	if answer == "I" then
		a.state = "invited"
		ns.Print(L.GROUPS_INVITED, U.Display(sender))
	else
		a.state = "declined"
		ns.Print(L.GROUPS_DECLINED, U.Display(sender))
	end
	ns.Fire("GROUPS")
end)

---------------------------------------------------------------------------
-- Заявки: сторона автора
---------------------------------------------------------------------------
local function Applicant(key)
	for i, a in ipairs(applicants) do
		if a.key == key then return a, i end
	end
end

local function Reply(a, answer)
	if not mine then return end
	ns.Comm.Send("WHISPER", Codec.EncodeGroupReply(mine.id, answer), { target = a.name, key = "gr:" .. a.key })
end

ns.Comm.On("GA", function(msg, sender, dist)
	if dist ~= "WHISPER" or not mine or mine.mode ~= "G" or not ns.IsMember() then return end
	local a = Codec.DecodeGroupApply(msg)
	local key = U.Key(sender)
	if not a or not key or key == ns.myKey or a.id ~= mine.id then return end
	if declined[key] or (ns.store and ns.store.ignore[key]) then return end
	local now = ns.Now()
	if lastHeard[key] and now - lastHeard[key] < C.GROUPS_APPLY_GAP / 2 then return end
	lastHeard[key] = now -- до проверки сертификата: иначе поток выдуманных отпечатков вызовет поток KQ
	local id = mine.id
	ns.Security.Resolve(a.fp, sender, sender, function(certificate)
		if not mine or mine.id ~= id or not U.IsMemberGuild(certificate.guild) then return end
		local known = Applicant(key)
		if not known then
			if #applicants >= C.GROUPS_APPLICANTS then return end
			known = { key = key, state = "new", at = ns.ServerTime() }
			applicants[#applicants + 1] = known
			ns.Print(L.GROUPS_APPLICANT, U.Display(certificate.name), Groups.RoleText(a.roles))
		end
		-- Гильдия — из сертификата, остальное — слова просящего.
		known.name, known.guild = U.Display(certificate.name), certificate.guild
		known.class, known.level, known.roles, known.note = a.class, a.level, a.roles, a.note
		ns.Fire("GROUPS")
	end)
end)

ns.Comm.On("GW", function(msg, sender, dist)
	if dist ~= "WHISPER" or not mine then return end
	local id, key = Codec.DecodeGroupWithdraw(msg), U.Key(sender)
	if id ~= mine.id or not key then return end
	local _, i = Applicant(key)
	if not i then return end
	table.remove(applicants, i)
	ns.Fire("GROUPS")
end)

local function GameInvite(name)
	local invite = C_PartyInfo and C_PartyInfo.InviteUnit or InviteUnit
	if type(invite) ~= "function" or not pcall(invite, U.TellName(name) or name) then
		ns.Print(L.PARTY_INVITE_UNAVAILABLE)
		return false
	end
	return true
end

-- Пригласить просящего. Только из щелчка игрока: приглашение — действие от его имени.
function Groups.Invite(key)
	local a = Applicant(key)
	if not a or not mine then return false end
	if not GameInvite(a.name) then return false end
	a.state, a.invitedAt = "invited", ns.Now()
	Reply(a, "I")
	ns.Fire("GROUPS")
	return true
end

function Groups.Decline(key)
	local a, i = Applicant(key)
	if not a then return false end
	table.remove(applicants, i)
	declined[key] = true
	Reply(a, "D")
	ns.Fire("GROUPS")
	return true
end

-- Пригласить игрока, который сам ищет группу: объявление «ищу группу» заявок не ждёт.
function Groups.InvitePlayer(key)
	local e = board[key]
	if not e or e.mode ~= "P" then return false end
	return GameInvite(e.name)
end

---------------------------------------------------------------------------
-- Состав группы
---------------------------------------------------------------------------

-- Что стало с моим объявлением после изменений в группе. true — объявление снято.
local function CheckMine()
	if not mine then return true end
	if ns.ServerTime() >= mine.id + C.GROUPS_LIFE then return Groups.Lower("expired") end
	if mine.mode == "P" then
		if InGroup() then return Groups.Lower("joined") end
		return false
	end
	if not Leading() then return Groups.Lower("notleader") end
	local size = GroupSize()
	if size >= mine.cap then return Groups.Lower("full") end
	if size ~= sentSize then dirty = true end
	return false
end

-- Просящий вошёл в группу: его роль больше не нужна. Из его ролей берётся первая ещё
-- нужная, начиная с самых редких; иначе автор поправит числа сам.
local function Joined()
	if not mine or mine.mode ~= "G" or #applicants == 0 then return end
	local members = MemberKeys()
	for i = #applicants, 1, -1 do
		local a = applicants[i]
		if members[a.key] then
			for _, k in ipairs(Groups.ROLES) do
				if (a.roles[k] or 0) > 0 and (mine.roles[k] or 0) > 0 then
					mine.roles[k] = mine.roles[k] - 1
					break
				end
			end
			table.remove(applicants, i)
			dirty = true
		end
	end
end

ns.RegisterEvent("GROUP_ROSTER_UPDATE", function()
	if rosterPending or not mine then return end
	rosterPending = true
	ns.After(1, "groups roster", function()
		rosterPending = false
		Joined()
		CheckMine()
		ns.Fire("GROUPS")
	end)
end)

---------------------------------------------------------------------------
-- Запрос объявлений после входа
---------------------------------------------------------------------------
function Groups.Ask()
	if not ns.IsMember() or ns.Comm.InLockdown() then return false end
	local now = ns.Now()
	if now - lastAsk < C.GROUPS_ASK_GAP then return false end
	lastAsk = now
	ns.Comm.Send("GUILD", "GQ~", { key = "groups-ask" })
	return true
end

ns.Comm.On("GQ", function(_, sender, dist)
	if dist ~= "GUILD" or ns.IsMe(sender) or not ns.IsMember() then return end
	local now = ns.Now()
	-- Своё объявление — тем же пакетом: у видевших его проверка подписи уже в кэше.
	if mine and myWire and now - lastServeMine >= C.GROUPS_SERVE_GAP then
		lastServeMine = now
		ns.After(1 + 3 * math.random(), "groups answer", function()
			if mine and myWire then ns.Comm.Send("GUILD", myWire, { key = "groups:mine" }) end
		end)
	end
	if not ns.Census.IsReporter() or now - lastServe < C.GROUPS_SERVE_GAP then return end
	lastServe = now
	local own, list, time = U.GuildKey(ns.MyGuild()), {}, ns.ServerTime()
	for _, e in pairs(board) do
		if e.wire and e.cert and U.GuildKey(e.guild) ~= own and not Expired(e, time) then list[#list + 1] = e end
	end
	table.sort(list, function(a, b)
		if a.at ~= b.at then return a.at > b.at end
		return a.key < b.key
	end)
	for i = 1, math.min(#list, C.GROUPS_SERVE_MAX) do
		local e = list[i]
		ns.Security.Introduce("GUILD", e.cert)
		ns.Comm.Send("GUILD", Codec.EncodeRM("RG", "P", e.name, e.wire), { key = "gq:" .. e.key })
		Groups.stats.served = Groups.stats.served + 1
	end
end)

---------------------------------------------------------------------------
-- Подсказка названий: список занятий игры. Необязателен: без него форма просто
-- остаётся с пустым полем названия.
---------------------------------------------------------------------------
local KIND_BY_CATEGORY = { [2] = "D", [114] = "R", [116] = "Q", [118] = "P", [120] = "O" }
local KIND_ORDER = { D = 1, R = 2, P = 3, Q = 4, O = 5 }
local catalog -- nil — ещё не читали, false — в этом клиенте списка нет

local function Activity(api, id)
	local name, cap, min
	if type(api.GetActivityInfoTable) == "function" then
		local ok, info = pcall(api.GetActivityInfoTable, id)
		if ok and type(info) == "table" then
			name, cap, min = info.fullName or info.shortName, info.maxNumPlayers, info.minLevel
		end
	end
	if not name and type(api.GetActivityInfo) == "function" then
		local ok, full, short, _, _, _, _, minLevel, maxPlayers = pcall(api.GetActivityInfo, id)
		if ok then name, cap, min = full or short, maxPlayers, minLevel end
	end
	name = type(name) == "string" and Codec.GroupText(name, Codec.GROUP_TITLE) or ""
	if name == "" then return nil end
	return name, math.floor(tonumber(cap) or 0), math.floor(tonumber(min) or 0)
end

-- { { name, kind, cap, min } } или nil. Читается из игры по первой просьбе.
function Groups.Catalog()
	if catalog ~= nil then return catalog or nil end
	local api = C_LFGList
	if type(api) ~= "table" or type(api.GetAvailableCategories) ~= "function"
		or type(api.GetAvailableActivities) ~= "function" then
		catalog = false
		return nil
	end
	local okCategories, categories = pcall(api.GetAvailableCategories)
	if not okCategories or type(categories) ~= "table" then return nil end
	local out, seen = {}, {}
	for _, category in ipairs(categories) do
		local kind = KIND_BY_CATEGORY[category] or "O"
		local okActivities, activities = pcall(api.GetAvailableActivities, category)
		if okActivities and type(activities) == "table" then
			for _, id in ipairs(activities) do
				local name, cap, min = Activity(api, id)
				if name and not seen[kind .. name] then
					seen[kind .. name] = true
					out[#out + 1] = { name = name, kind = kind, cap = cap, min = min }
				end
			end
		end
	end
	if #out == 0 then return nil end -- данные могли ещё не прийти: спросим в следующий раз
	table.sort(out, function(a, b)
		if a.kind ~= b.kind then return KIND_ORDER[a.kind] < KIND_ORDER[b.kind] end
		if a.min ~= b.min then return a.min < b.min end
		return a.name < b.name
	end)
	catalog = out
	return out
end

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
local function Tick()
	local time, now, changed = ns.ServerTime(), ns.Now(), false
	for key, e in pairs(board) do
		if Expired(e, time) then
			Drop(key)
			changed = true
		end
	end
	for key, tomb in pairs(closed) do
		if time - tomb.at > C.GROUPS_WINDOW + 60 then closed[key] = nil end
	end
	for key, a in pairs(applied) do
		local e = board[key]
		if not e or e.id ~= a.id then
			applied[key] = nil
			changed = true
		end
	end
	for key, at in pairs(lastApply) do
		if now - at >= C.GROUPS_APPLY_GAP then lastApply[key] = nil end
	end
	-- Просить объявления есть смысл, когда есть свой сертификат: без корней доверия чужие
	-- подписи проверить нечем, и ответы пропали бы.
	if askAt and now >= askAt and ns.Security.MyCertificate() and Groups.Ask() then askAt = nil end
	if mine and not CheckMine() then
		for _, a in ipairs(applicants) do
			if a.state == "invited" and now - (a.invitedAt or 0) > C.GROUPS_INVITE_WAIT then
				a.state, a.invitedAt = "new", nil
				changed = true
			end
		end
		-- В блокировке сообщение застряло бы в очереди: объявление уйдёт после неё.
		if not sealing and not ns.Comm.InLockdown()
			and ((dirty and now - lastSent >= C.GROUPS_UPDATE_GAP) or now >= nextBeat) then
			Broadcast(false)
		end
	end
	if changed then ns.Fire("GROUPS") end
end
Groups.Tick = Tick

local function Restore()
	ns.char.groups = type(ns.char.groups) == "table" and ns.char.groups or {}
	saved = ns.char.groups
	saved.roles = type(saved.roles) == "table" and saved.roles or {}
	local m = saved.mine
	local valid = type(m) == "table" and (m.mode == "G" or m.mode == "P") and type(m.id) == "number"
		and type(m.title) == "string" and type(m.roles) == "table" and ns.ServerTime() < m.id + C.GROUPS_LIFE
	if not valid then
		saved.mine, saved.applicants, saved.declined = nil, nil, nil
		m = nil
	end
	saved.applicants = type(saved.applicants) == "table" and saved.applicants or {}
	saved.declined = type(saved.declined) == "table" and saved.declined or {}
	applicants, declined = saved.applicants, saved.declined
	for i = #applicants, 1, -1 do
		local a = applicants[i]
		if type(a) ~= "table" or type(a.key) ~= "string" or type(a.name) ~= "string" or type(a.roles) ~= "table" then
			table.remove(applicants, i)
		else
			a.state, a.invitedAt = "new", nil
		end
	end
	if m then
		local l = Normalize(m)
		l.id = m.id
		mine, saved.mine = l, l
		-- Сертификату после входа нужно время: объявление вернётся на доску чуть позже.
		nextBeat = ns.Now() + C.GROUPS_ASK_AFTER
	end
end

local function GuildKeyNow()
	local guild = ns.MyGuild()
	return guild and U.GuildKey(guild) or nil
end

local guildKey -- гильдия, при которой собрана доска

ns.On("LOGIN", function()
	Restore()
	guildKey = GuildKeyNow()
	askAt = ns.Now() + C.GROUPS_ASK_AFTER
	ns.Every(5, "groups tick", Tick)
end)

-- GUILD_CHANGED приходит и без смены гильдии (вход, смена звания): доска сбрасывается
-- только когда гильдия действительно другая.
ns.On("GUILD_CHANGED", function()
	local now, before = GuildKeyNow(), guildKey
	if now == before then return end
	guildKey = now
	if before == nil then return end
	wipe(board)
	wipe(closed)
	wipe(applied)
	if mine then Forget() end
	ns.Fire("GROUPS")
end)

ns.Status(function()
	local own = mine and (mine.mode == "G" and L.GROUPS_STATUS_GROUP or L.GROUPS_STATUS_PLAYER) or L.GROUPS_STATUS_NONE
	return L.GROUPS_STATUS:format(Count(), own, #applicants)
end)
