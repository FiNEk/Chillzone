-- Chillzone: мастера. Каталог ремесленников объединения: кто какой профессией владеет, навык и
-- изученные рецепты. Без заказов, сделок и рейтинга.
--
-- Свои профессии аддон читает из открытого окна профессии (C_TradeSkillUI): навык и номера
-- изученных рецептов. Чужое окно (по ссылке, гильдейское, у НИП) и чтение в бою пропускаются.
-- Чтение и проверка чужого окна портированы из Olympus Crafters.lua (ReadModern, External).
--
-- Карточка W1 — отмеченные профессии с навыком, числом рецептов и хешем списка, витрина (до
-- CRAFT_SHOW своих рецептов, которые видны в строке каталога и первыми в карточке), примечание. Она
-- подписывается и расходится только в конверте строки чата (Codec.WrapCraft): S1 по GUILD своей
-- гильдии и через реле остальным (режим P). Реле, репортёры и чат 0.14.2 и старше пересылают
-- конверт как строку чата и молча его отбрасывают, поэтому Security.lua новый вид не нужен.
-- Автор повторяет карточку раз в Every() минут; время прошлой отправки хранится у персонажа и
-- переживает /reload и перезаход. Порядок пакетов автора — по времени и номеру подписи S1:
-- снятая карточка (X) старым пакетом не вернётся.
--
-- Список рецептов смотрящий просит у мастера прямым шёпотом WR, мастер отвечает страницами WL,
-- как OQ/OL в Online.lua. Страницы не подписаны: отправителя шёпота подтверждает сервер, а
-- список смотрящий сверяет с хешем на странице. По сети идут только номера рецептов: названия
-- каждый клиент берёт у игры сам.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Crafters = {}
ns.Crafters = Crafters

-- Профессии с рецептами по номеру базовой профессии игры. Названия — L.CRAFT_PROF.
Crafters.PROFS = { 164, 165, 197, 171, 202, 333, 755, 773, 186, 185, 129 }
Crafters.ICONS = {
	[171] = "Interface\\Icons\\Trade_Alchemy",
	[164] = "Interface\\Icons\\Trade_BlackSmithing",
	[333] = "Interface\\Icons\\Trade_Engraving",
	[202] = "Interface\\Icons\\Trade_Engineering",
	[165] = "Interface\\Icons\\Trade_LeatherWorking",
	[197] = "Interface\\Icons\\Trade_Tailoring",
	[185] = "Interface\\Icons\\INV_Misc_Food_15",
	[129] = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
	[186] = "Interface\\Icons\\Trade_Mining",
	[755] = "Interface\\Icons\\INV_Misc_Gem_01",
	[773] = "Interface\\Icons\\INV_Inscription_Tradeskill01",
}
local ORDER = {}
for i, id in ipairs(Crafters.PROFS) do ORDER[id] = i end

-- В каталог попадают только профессии из PROFS: ни свои, ни из чужих карточек. Остальное —
-- прежде всего рыбная ловля, у которой на Forever бывают «рецепты», — выбрасывается, в том числе
-- из карточек старых версий, которые её ещё рассылают.
local function Known(id)
	return ORDER[id] ~= nil
end

local saved -- ns.char.crafts: свои профессии, отметки, примечание, своя карточка
local cards -- ns.store.crafters.cards: [ключ автора] = карточка
local lists -- ns.store.crafters.lists: [ключ автора] = { [профессия] = { hash, ids, at } }
local closed = {} -- [ключ автора] = { at, seq } снятой карточки: старый пакет её не вернёт
local unpacked = {} -- [ключ автора] = { [профессия] = { hash, ids } }: распакованное на сессию
local ownSets = {} -- [профессия] = { hash, set }: свои изученные рецепты для проверки витрины
local asks = {} -- [ключ мастера] = мой запрос списка: { key, name, prof, have, deadline, hash, n, got, pages }
local failedAsk = {} -- ["ключ:профессия"] = { at, why }: мастер не ответил
local lastAsk = {} -- ["ключ:профессия"] = когда я спрашивал
local answered = {} -- [ключ мастера] = когда он ответил на мой запрос
local lastQuery = {} -- ["ключ:профессия"] = когда спрашивающий просил у меня список
local serving = {} -- [ключ спрашивающего] = true, пока ему уходит список
local served = {} -- когда начинались мои ответы за последнюю минуту
local sealing = false
local lastPost = -1e9
local firstAt -- после входа своя карточка проверяется не раньше
local shown, pendingRead = false, false
local lastClean = -1e9

Crafters.stats = { heard = 0, stale = 0, served = 0, read = 0 }

local function Changed()
	ns.Fire("CRAFTERS")
end

function Crafters.ProfName(id)
	return (L.CRAFT_PROF and L.CRAFT_PROF[id]) or L.CRAFT_PROF_UNKNOWN:format(tonumber(id) or 0)
end

function Crafters.ProfOrder(id)
	return ORDER[id] or 100 + (tonumber(id) or 0) / 1e7
end

-- С какой версии интерфейса профессия есть в игре: ювелирное дело — с TBC, начертание — с WotLK.
local SINCE = { [755] = 20000, [773] = 30000 }
local gameProfs

-- Профессии, которые есть в этом клиенте, по порядку PROFS: фильтр каталога показывает их все,
-- даже без мастеров, чтобы было видно, что таких нет.
function Crafters.GameProfs()
	if not gameProfs then
		local ui = tonumber((select(4, GetBuildInfo()))) or 0
		gameProfs = {}
		for _, id in ipairs(Crafters.PROFS) do
			if ui >= (SINCE[id] or 0) then gameProfs[#gameProfs + 1] = id end
		end
	end
	return gameProfs
end

---------------------------------------------------------------------------
-- Каталог
---------------------------------------------------------------------------
local function Stamp(wire)
	local at, seq = (type(wire) == "string" and wire or ""):match("^S1~[%w_-]+~(%d+)~(%d+)~")
	return tonumber(at), tonumber(seq)
end

local function Newer(at, seq, than)
	return not than or at > than.at or (at == than.at and seq > than.seq)
end

local function Count()
	local n = 0
	for _ in pairs(cards or {}) do n = n + 1 end
	return n
end

local function DropList(key, prof)
	if lists[key] then
		lists[key][prof] = nil
		if not next(lists[key]) then lists[key] = nil end
	end
	if unpacked[key] then unpacked[key][prof] = nil end
end

local function Drop(key)
	local had = cards[key] ~= nil
	cards[key], lists[key], unpacked[key] = nil, nil, nil
	asks[key] = nil
	return had
end

local function HasProf(card, prof)
	for _, p in ipairs(card and card.profs or {}) do
		if p.id == prof then return p end
	end
end

-- Самая старая карточка по времени подписи.
local function Oldest()
	local key, at
	for k, card in pairs(cards) do
		if not at or card.at < at then key, at = k, card.at end
	end
	return key
end

local function TrimLists()
	local all = {}
	for key, byProf in pairs(lists) do
		for prof, entry in pairs(byProf) do all[#all + 1] = { key = key, prof = prof, at = entry.at } end
	end
	if #all <= C.CRAFT_LISTS_MAX then return end
	table.sort(all, function(a, b) return a.at < b.at end)
	for i = 1, #all - C.CRAFT_LISTS_MAX do DropList(all[i].key, all[i].prof) end
end

-- Чистка: срок карточки, предел каталога, списки без карточки или профессии.
local function Clean()
	local time, changed = ns.ServerTime(), false
	for key, card in pairs(cards) do
		if time - card.at > C.CRAFT_KEEP then
			ns.Log("мастера: карточка %s <%s> пропала из каталога: автор её не повторил", card.name, card.guild)
			Drop(key)
			changed = true
		end
	end
	local n = Count()
	while n > C.CRAFT_MAX do
		Drop(Oldest())
		n, changed = n - 1, true
	end
	for key, byProf in pairs(lists) do
		for prof in pairs(byProf) do
			if not HasProf(cards[key], prof) then DropList(key, prof) end
		end
	end
	TrimLists()
	for key, tomb in pairs(closed) do
		if time - tomb.at > C.CHAT_DEDUPE + 60 then closed[key] = nil end
	end
	return changed
end

function Crafters.Receive(msg, _, dist, ctx)
	if dist ~= "GUILD" and dist ~= "RELAY" then return end
	local c = ctx and ctx.authenticated and ctx.certificate
	if not c or not cards or not ns.IsMember() then return end
	local w = Codec.DecodeCraft(msg)
	if not w or not U.IsMemberGuild(w.guild) then return end
	local key, name = c.key, U.Display(c.name)
	if not key or key == ns.myKey then return end -- своё показывается из ns.char
	local own, theirs = U.GuildKey(ns.MyGuild()), U.GuildKey(w.guild)
	local via = dist == "GUILD" and "своя гильдия" or "реле"
	if U.GuildKey(c.guild) ~= theirs then
		ns.Log("мастера: карточка %s не принята: гильдия сертификата <%s>, в карточке <%s> (%s)", name, c.guild, w.guild, via)
		return
	end
	if dist == "GUILD" and theirs ~= own then return end -- по GUILD пишут только согильдийцы
	if dist == "RELAY" and theirs == own then return end -- своя гильдия приходит напрямую
	local at, seq = Stamp(ctx.wire)
	if not at then return end
	Crafters.stats.heard = Crafters.stats.heard + 1
	local old = cards[key]
	if not Newer(at, seq, closed[key]) or not Newer(at, seq, old) then
		Crafters.stats.stale = Crafters.stats.stale + 1
		return
	end
	if w.mode == "X" then
		closed[key] = { at = at, seq = seq }
		if Drop(key) then
			ns.Log("мастера: %s <%s> снял карточку (%s)", name, w.guild, via)
			Changed()
		end
		return
	end
	local profs = {}
	for _, p in ipairs(w.profs) do
		if Known(p.id) then profs[#profs + 1] = p end
	end
	if #profs == 0 then
		-- Только рыбная ловля и прочее не из каталога: прежняя карточка автора больше не верна,
		-- и старый пакет её не вернёт, как после снятия.
		closed[key] = { at = at, seq = seq }
		if Drop(key) then
			ns.Log("мастера: карточка %s <%s> убрана: в ней нет профессий каталога (%s)", name, w.guild, via)
			Changed()
		end
		return
	end
	if ns.store.ignore[key] then
		if Drop(key) then Changed() end
		return
	end
	if ns.ServerTime() - at > C.CRAFT_KEEP then
		ns.Log("мастера: карточка %s <%s> не принята: пришла просроченной (%s)", name, w.guild, via)
		return
	end
	if not old and Count() >= C.CRAFT_MAX then Drop(Oldest()) end
	-- Журнал: новая карточка и правка. Повтор той же карточки не пишется.
	if not old then
		ns.Log("мастера: карточка %s <%s> принята (%s)", name, w.guild, via)
	elseif old.st ~= w.st then
		ns.Log("мастера: карточка %s <%s> обновлена (%s)", name, w.guild, via)
	end
	cards[key] = {
		key = key, name = name, guild = w.guild, class = w.class, level = w.level, st = w.st,
		at = at, seq = seq, note = w.note, profs = profs,
	}
	-- Список профессии, которой в карточке больше нет, не нужен.
	for prof in pairs(lists[key] or {}) do
		if not HasProf(cards[key], prof) then DropList(key, prof) end
	end
	Changed()
end
ns.Comm.On("W1", Crafters.Receive)

function Crafters.Get(key)
	return cards and cards[key]
end

-- Видимые карточки: гильдия в объединении, автор не в игноре. Своя — отдельно (Crafters.Own).
function Crafters.Cards()
	local out = {}
	for key, card in pairs(cards or {}) do
		if U.IsMemberGuild(card.guild) and not ns.store.ignore[key] then out[#out + 1] = card end
	end
	return out
end

-- Сколько карточек в каталоге, считая свою.
function Crafters.Count()
	return #Crafters.Cards() + (Crafters.Own() and 1 or 0)
end

-- Согильдиец, которого нет в свежем ростере, ушёл из гильдии: его карточка не показывается.
ns.On("ROSTER", function()
	if not cards or not ns.Roster.Fresh() then return end
	local own, changed = U.GuildKey(ns.MyGuild()), false
	for key, card in pairs(cards) do
		if U.GuildKey(card.guild) == own and ns.Roster.byKey[key] == nil then
			ns.Log("мастера: карточка %s <%s> убрана: его нет в ростере", card.name, card.guild)
			Drop(key)
			changed = true
		end
	end
	if changed then Changed() end
end)

---------------------------------------------------------------------------
-- Кто в игре: "online" — согильдиец по ростеру, чужой в списке Online или только что ответил на
-- запрос рецептов; "recent" — карточку подписали недавно; "offline" — по ростеру или списку
-- Online мастера в игре нет; "away" — списка гильдии нет, известна только давность карточки.
-- listed — есть ли мастер в списке Online его гильдии (false — список есть, мастера в нём нет);
-- nil — посмотреть самим.
---------------------------------------------------------------------------
function Crafters.Presence(card, listed)
	if card.own then return "online" end
	local key = card.key
	if U.GuildKey(card.guild) == U.GuildKey(ns.MyGuild()) and ns.Roster.Fresh() then
		return ns.Roster.online[key] and "online" or "offline"
	end
	if answered[key] and ns.Now() - answered[key] < C.CRAFT_ANSWERED then return "online" end
	if listed == nil then
		local list = ns.Online.Get(card.guild)
		if list and list.at then
			listed = false
			for _, p in ipairs(list.people or {}) do
				if U.Key(p.name) == key then listed = true; break end
			end
		end
	end
	if listed then return "online" end
	-- Список бывает старше карточки: подписанная недавно значит, что мастер заходил после него.
	if ns.ServerTime() - card.at < C.FRESH then return "recent" end
	return listed == false and "offline" or "away"
end

---------------------------------------------------------------------------
-- Свои профессии
---------------------------------------------------------------------------
local function TradeSkill()
	return type(C_TradeSkillUI) == "table" and C_TradeSkillUI or nil
end

-- Открыто чужое окно: по ссылке, гильдейское, у НИП.
local function External()
	local T = TradeSkill()
	for _, f in ipairs({ "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting" }) do
		local fn = T and T[f]
		if type(fn) == "function" then
			local ok, v = pcall(fn)
			if ok and v then return true end
		end
	end
	if type(IsTradeSkillLinked) == "function" then
		local ok, v = pcall(IsTradeSkillLinked)
		if ok and v then return true end
	end
	return false
end

-- Читать рецепты эта версия игры умеет: есть C_TradeSkillUI.
function Crafters.CanRead()
	local T = TradeSkill()
	return T ~= nil and type(T.GetBaseProfessionInfo) == "function" and type(T.GetRecipeInfo) == "function"
end

-- Открытое окно профессии: { id, skill, max, ids } или nil, причина.
local function Read()
	if not Crafters.CanRead() then return nil, "noapi" end
	if External() then return nil, "external" end
	if InCombatLockdown and InCombatLockdown() then return nil, "combat" end
	local T = TradeSkill()
	local ok, base = pcall(T.GetBaseProfessionInfo)
	local id = ok and type(base) == "table" and tonumber(base.professionID)
	if not id or id < 1 then return nil, "empty" end
	local skill = base
	if type(T.GetChildProfessionInfo) == "function" then
		local okc, child = pcall(T.GetChildProfessionInfo)
		if okc and type(child) == "table" and (tonumber(child.skillLevel) or 0) > 0 then skill = child end
	end
	local all
	for _, f in ipairs({ "GetAllRecipeIDs", "GetFilteredRecipeIDs" }) do
		if not all and type(T[f]) == "function" then
			local okr, r = pcall(T[f])
			if okr and type(r) == "table" then all = r end
		end
	end
	local ids = {}
	for _, rid in ipairs(all or {}) do
		local okr, info = pcall(T.GetRecipeInfo, rid)
		if okr and type(info) == "table" and info.learned then ids[#ids + 1] = rid end
	end
	return {
		id = math.floor(id), skill = math.floor(tonumber(skill.skillLevel) or 0),
		max = math.floor(tonumber(skill.maxSkillLevel) or 0), ids = ids,
	}
end

-- Окно профессии открыто или обновилось: запомнить профессию. Первое чтение неразмещённой
-- профессии — одна подсказка в чат на профессию и персонажа.
function Crafters.Opened()
	if not saved then return end
	local p, why = Read()
	if not p then
		if why ~= "empty" then Crafters.lastSkip = why end
		return
	end
	Crafters.lastSkip = nil
	if #p.ids == 0 or not Known(p.id) then return end -- собирательные, рыбная ловля и пустые не показываются
	local packed, n = Codec.PackIds(p.ids, C.CRAFT_RECIPES_MAX)
	local hash = Codec.IdsHash(packed)
	local old = saved.profs[p.id]
	saved.profs[p.id] = { id = p.id, skill = p.skill, max = p.max, n = n, ids = packed, hash = hash, readAt = ns.ServerTime() }
	if unpacked[ns.myKey] then unpacked[ns.myKey][p.id] = nil end
	Crafters.stats.read = Crafters.stats.read + 1
	if not old or old.hash ~= hash or old.skill ~= p.skill or old.max ~= p.max then
		ns.Log("мастера: прочитана профессия %s: навык %d/%d, рецептов %d", Crafters.ProfName(p.id), p.skill, p.max, n)
	end
	if not old and not saved.post[p.id] and not saved.hinted[p.id] then
		saved.hinted[p.id] = true
		ns.Print(L.CRAFT_HINT:format(Crafters.ProfName(p.id)))
	end
	Changed()
end

local function Soon()
	if pendingRead then return end
	pendingRead = true
	ns.After(0.5, "crafters read", function()
		pendingRead = false
		if shown then Crafters.Opened() end
	end)
end

-- Свои прочитанные профессии по порядку: { id, skill, max, n, hash, readAt, post }.
function Crafters.MyProfs()
	local out = {}
	for id, p in pairs(saved and saved.profs or {}) do
		out[#out + 1] = { id = id, skill = p.skill, max = p.max, n = p.n, hash = p.hash, readAt = p.readAt, post = saved.post[id] == true }
	end
	table.sort(out, function(a, b) return Crafters.ProfOrder(a.id) < Crafters.ProfOrder(b.id) end)
	return out
end

function Crafters.SetPost(id, on)
	if not saved or not saved.profs[id] then return end
	saved.post[id] = on and true or nil
	Changed()
end

function Crafters.Note()
	return saved and saved.note or ""
end

function Crafters.Posted()
	return saved ~= nil and saved.posted == true
end

-- Рецепт есть в своём прочитанном списке профессии.
local function Learned(prof, id)
	local p = saved and saved.profs[prof]
	if not p then return false end
	local memo = ownSets[prof]
	if not memo or memo.hash ~= p.hash then
		memo = { hash = p.hash, set = {} }
		for _, r in ipairs(Crafters.Recipes(ns.myKey, prof) or {}) do memo.set[r] = true end
		ownSets[prof] = memo
	end
	return memo.set[id] == true
end

-- Витрина карточки из отметок list (по умолчанию сохранённых): { [профессия] = { номера } } и
-- сколько всего. Только профессии карточки chosen и изученные рецепты, по порядку отметки, не
-- больше CRAFT_SHOW. Отметки снятой с карточки профессии хранятся и вернутся вместе с ней.
local function Showcase(chosen, list)
	local posted, out, n = {}, {}, 0
	for _, p in ipairs(chosen) do posted[p.id] = true end
	for _, s in ipairs(list or saved.show) do
		if n < C.CRAFT_SHOW and posted[s.prof] and Learned(s.prof, s.id) then
			out[s.prof] = out[s.prof] or {}
			table.insert(out[s.prof], s.id)
			n = n + 1
		end
	end
	return out, n
end

-- Отмеченные профессии для карточки: не больше CRAFT_PROFS, у каждой — её витрина (show).
local function Chosen()
	local out = {}
	for _, p in ipairs(Crafters.MyProfs()) do
		if p.post and #out < C.CRAFT_PROFS then out[#out + 1] = p end
	end
	local show = Showcase(out)
	for _, p in ipairs(out) do p.show = show[p.id] end
	return out
end

-- Сколько рецептов на своей витрине.
function Crafters.ShowCount()
	if not saved then return 0 end
	return (select(2, Showcase(Chosen())))
end

-- Поставить свой рецепт профессии prof на витрину (on) или убрать с неё. false, причина: full —
-- витрина полна, missing — профессии нет в карточке или рецепта нет в её списке.
function Crafters.SetShow(prof, id, on)
	if not saved then return false, "failed" end
	-- Отметки рецептов, которых больше нет в своих списках, при этом выбрасываются.
	local keep = {}
	for _, s in ipairs(saved.show) do
		if not (s.prof == prof and s.id == id) and Learned(s.prof, s.id) then keep[#keep + 1] = s end
	end
	if on then
		local chosen = Chosen()
		if not HasProf({ profs = chosen }, prof) or not Learned(prof, id) then return false, "missing" end
		if select(2, Showcase(chosen, keep)) >= C.CRAFT_SHOW then return false, "full" end
		keep[#keep + 1] = { prof = prof, id = id }
	end
	while #keep > C.CRAFT_SHOW * C.CRAFT_PROFS do table.remove(keep, 1) end
	saved.show = keep
	Changed()
	return true
end

-- Что в карточке, кроме времени, класса и уровня: смена — правка, а не повтор.
local function Signature()
	local parts = { tostring(ns.MyGuild()), saved.note or "" }
	for _, p in ipairs(Chosen()) do
		local entry = ("%d:%d:%d:%d:%s"):format(p.id, p.skill, p.max, p.n, p.hash)
		if p.show then entry = entry .. ":" .. table.concat(p.show, ".") end
		parts[#parts + 1] = entry
	end
	return table.concat(parts, "~")
end

-- Размещённая карточка отличается от того, что ушло в сеть: правка уйдёт после паузы.
function Crafters.Dirty()
	return saved ~= nil and saved.posted and Signature() ~= saved.sentSig
end

-- Своя карточка в том же виде, что чужие, пока она размещена. draft — и неразмещённая: черновик,
-- в котором до размещения выставляется витрина. nil — нет отмеченных профессий.
function Crafters.Own(draft)
	if not saved or not (saved.posted or draft) then return nil end
	local profs = Chosen()
	if #profs == 0 then return nil end
	local _, class = UnitClass("player")
	return {
		key = ns.myKey, name = U.Display(ns.me), guild = ns.MyGuild() or "", class = class,
		level = UnitLevel("player") or 0, note = saved.note or "", profs = profs, own = true,
		at = saved.sentAt or ns.ServerTime(), st = saved.st, posted = saved.posted == true,
	}
end

---------------------------------------------------------------------------
-- Своя карточка в сети
---------------------------------------------------------------------------
-- Чем больше карточек слышно, тем реже каждая повторяется: весь каталог — около CRAFT_PER_MIN в минуту.
local function Every()
	local n, time = 0, ns.ServerTime()
	for _, card in pairs(cards or {}) do
		if time - card.at < C.CRAFT_EVERY_MAX * 60 then n = n + 1 end
	end
	return math.max(C.CRAFT_EVERY_MIN, math.min(C.CRAFT_EVERY_MAX, math.ceil((n + 1) / C.CRAFT_PER_MIN)))
end
Crafters.Every = Every

local function Broadcast(prio)
	local guild = ns.MyGuild()
	local profs = Chosen()
	if not guild or #profs == 0 then return false, "none" end
	local _, class = UnitClass("player")
	local msg = Codec.EncodeCraft({
		mode = "C", st = saved.st or ns.ServerTime(), guild = guild, class = class, level = UnitLevel("player") or 0,
		profs = profs, note = saved.note,
	})
	local inner = msg and Codec.WrapCraft(msg)
	if not inner then return false, "failed" end
	local sig, first = Signature(), saved.sentSig == nil
	sealing = true
	local ok, why = ns.Security.Seal(inner, function(wire, failed)
		sealing = false
		if not saved.posted then return end -- сняли, пока шла подпись
		if not wire then
			saved.sentSig = nil -- уйдёт правкой после паузы
			ns.Log("мастера: своя карточка не подписана: %s", tostring(failed))
			return
		end
		ns.Comm.Send("GUILD", wire, { prio = prio, key = "crafters:mine" })
		local relayed = ns.Relay.Out("P", wire)
		-- Повторы в журнал не идут, пока реле отвечает: иначе запись на каждый повтор. Без
		-- отвечающего реле Relay.Out держит карточку и отправляет, когда реле ответит на опрос.
		if not relayed then
			ns.Log("мастера: своя карточка ушла гильдии, отвечающего реле нет: остальным уйдёт после его ответа")
		elseif first then
			ns.Log("мастера: своя карточка ушла гильдии и реле")
		end
	end)
	if not ok then
		sealing = false
		return false, why
	end
	saved.sentAt, saved.sentSig = ns.ServerTime(), sig
	return true
end

-- Сколько секунд до следующего «Разместить» (0 — можно сейчас).
function Crafters.PostWait()
	return math.max(0, math.ceil(lastPost + C.CRAFT_POST_GAP - ns.Now()))
end

-- «Разместить» и «Обновить»: карточка уходит сразу. note — текст поля примечания.
-- false, причина[, секунды]: notmember, nocert, noprofs, none, wait, busy, failed.
function Crafters.Post(note)
	if not saved then return false, "failed" end
	if not ns.IsMember() then return false, "notmember" end
	if not ns.Security.MyCertificate() then return false, "nocert" end
	if note ~= nil then saved.note = Codec.GroupText(note, Codec.CRAFT_NOTE) end
	if #Chosen() == 0 then return false, next(saved.profs) and "none" or "noprofs" end
	if sealing then return false, "busy" end
	local wait = Crafters.PostWait()
	if wait > 0 then return false, "wait", wait end
	local was, st = saved.posted, saved.st
	saved.posted = true
	if not was or Signature() ~= saved.sentSig then saved.st = ns.ServerTime() end
	local ok, why = Broadcast(true)
	if not ok then
		saved.posted, saved.st = was, st
		return false, why
	end
	lastPost = ns.Now()
	ns.Log("мастера: своя карточка %s", was and "обновлена" or "размещена")
	Changed()
	return true
end

-- «Снять»: карточка пропадает у остальных сразу.
function Crafters.Withdraw()
	if not saved or not saved.posted then return false end
	saved.posted, saved.sentSig = false, nil
	local guild = ns.MyGuild()
	local msg = guild and ns.IsMember() and Codec.EncodeCraft({ mode = "X", st = ns.ServerTime(), guild = guild })
	local inner = msg and Codec.WrapCraft(msg)
	if inner then
		ns.Security.Seal(inner, function(wire)
			if not wire then return end
			ns.Comm.Send("GUILD", wire, { prio = true, key = "crafters:mine" })
			ns.Relay.Out("P", wire)
		end)
	end
	ns.Log("мастера: своя карточка снята")
	Changed()
	return true
end

---------------------------------------------------------------------------
-- Списки рецептов
---------------------------------------------------------------------------
-- Распакованный список: свой из ns.char, чужой из сохранённых. Второе значение — запись
-- { hash, at } (у своего — время чтения).
function Crafters.Recipes(key, prof)
	local entry
	if key == ns.myKey then
		local p = saved and saved.profs[prof]
		entry = p and { hash = p.hash, ids = p.ids, at = p.readAt }
	else
		entry = lists and lists[key] and lists[key][prof]
	end
	if not entry then return nil end
	unpacked[key] = unpacked[key] or {}
	local memo = unpacked[key][prof]
	if not memo or memo.hash ~= entry.hash then
		memo = { hash = entry.hash, ids = Codec.UnpackIds(entry.ids, C.CRAFT_RECIPES_MAX) or {} }
		unpacked[key][prof] = memo
	end
	return memo.ids, entry
end

-- Загружен ли у мастера список профессии prof (nil — хоть один).
function Crafters.HasList(key, prof)
	local byProf
	if key == ns.myKey then byProf = saved and saved.profs else byProf = lists and lists[key] end
	if not byProf then return false end
	if prof then return byProf[prof] ~= nil end
	return next(byProf) ~= nil
end

local function Fail(ask, why)
	if asks[ask.key] ~= ask then return end
	asks[ask.key] = nil
	failedAsk[ask.key .. ":" .. ask.prof] = { at = ns.Now(), why = why or "silent" }
	ns.Log("мастера: %s не прислал список рецептов (%s)", ask.name, why or "нет ответа")
	Changed()
end

-- Что с запросом: { loading = true, got, n } | { failed = true, why } | nil.
function Crafters.AskState(key, prof)
	local ask = asks[key]
	if ask and ask.prof == prof then return { loading = true, got = ask.got or 0, n = ask.n } end
	local f = failedAsk[key .. ":" .. prof]
	if f and ns.Now() - f.at < C.CRAFT_ASK_RETRY then return { failed = true, why = f.why } end
end

-- Попросить список рецептов профессии prof у автора карточки. force — даже если сохранённый
-- список совпадает с карточкой («Обновить рецепты»). false, причина: nocard, fresh, busy, retry,
-- nocert, lockdown, offline.
function Crafters.Want(key, prof, force)
	local card = cards and cards[key]
	local p = HasProf(card, prof)
	if not p then return false, "nocard" end
	local id, now = key .. ":" .. prof, ns.Now()
	local entry = lists[key] and lists[key][prof]
	if entry and entry.hash == p.hash and not force then return false, "fresh" end
	if asks[key] then return false, "busy" end
	if lastAsk[id] and now - lastAsk[id] < C.CRAFT_ASK_RETRY then return false, "retry" end
	local mine = ns.Security.MyCertificate()
	if not mine then return false, "nocert" end
	if ns.Comm.InLockdown() then return false, "lockdown" end
	local ask = { key = key, name = card.name, prof = prof, have = entry and entry.hash, deadline = now + C.CRAFT_ASK_WAIT, got = 0, pages = {} }
	asks[key], lastAsk[id], failedAsk[id] = ask, now, nil
	ns.Security.Introduce(card.name) -- мастеру не придётся спрашивать мой сертификат отдельно
	local sent, why = ns.Comm.Send("WHISPER", Codec.EncodeCraftQuery(prof, mine.fp, ask.have), {
		target = card.name, prio = true, key = "wr:" .. key,
		done = function(ok, reason)
			if not ok then Fail(ask, reason == "offline" and "offline" or "silent") end
		end,
	})
	if not sent then
		Fail(ask, why == "offline" and "offline" or "silent")
		return false, why == "offline" and "offline" or "failed"
	end
	Changed()
	return true
end

-- Сервер ответил «нет такого игрока»: мастера нет в игре, ответа не ждём.
ns.On("WHISPER_UNAVAILABLE", function(key)
	if asks[key] then Fail(asks[key], "offline") end
end)

ns.Activity.Probe(function()
	local n = 0
	for _ in pairs(asks) do n = n + 1 end
	if n > 0 then return { kind = "wait", text = L.ACT_CRAFT:format(n), detail = L.ACT_CRAFT_TIP } end
end)

local function Save(key, prof, hash, packed)
	lists[key] = lists[key] or {}
	lists[key][prof] = { hash = hash, ids = packed, at = ns.ServerTime() }
	if unpacked[key] then unpacked[key][prof] = nil end
	TrimLists()
end

-- Страница принимается только от того, кого спросили, и только пока ждём.
ns.Comm.On("WL", function(msg, sender, dist)
	if dist ~= "WHISPER" or not lists then return end
	local page = Codec.DecodeCraftPage(msg)
	local key = U.Key(sender)
	local ask = key and asks[key]
	if not page or not ask or page.prof ~= ask.prof then return end
	answered[key] = ns.Now()
	if page.n == 0 then
		-- Хеш совпал: мой список актуален.
		local entry = lists[key] and lists[key][ask.prof]
		if entry and ask.have == page.hash and entry.hash == page.hash then entry.at = ns.ServerTime() end
		asks[key] = nil
		Changed()
		return
	end
	if page.hash ~= ask.hash or page.n ~= ask.n then
		ask.hash, ask.n, ask.got, ask.pages = page.hash, page.n, 0, {}
	end
	if not ask.pages[page.i] then
		ask.pages[page.i] = page.data
		ask.got = ask.got + 1
	end
	ask.deadline = ns.Now() + C.CRAFT_ASK_WAIT
	if ask.got >= ask.n then
		local packed = table.concat(ask.pages, "", 1, ask.n)
		if Codec.IdsHash(packed) ~= page.hash or not Codec.UnpackIds(packed, C.CRAFT_RECIPES_MAX) then
			Fail(ask, "broken")
			return
		end
		asks[key] = nil
		Save(key, ask.prof, page.hash, packed)
		ns.Log("мастера: список рецептов %s (%s) получен", ask.name, Crafters.ProfName(ask.prof))
	end
	Changed()
end)

---------------------------------------------------------------------------
-- Мастер: ответ на запрос списка
---------------------------------------------------------------------------
local function ServingCount()
	local n = 0
	for _ in pairs(serving) do n = n + 1 end
	return n
end

-- Страницы уходят по одной: следующая встаёт в очередь, когда ушла предыдущая, поэтому список
-- не занимает очередь и не задерживает чат.
local function Serve(sender, key, prof, have)
	local p = saved and saved.profs[prof]
	if not p or serving[key] or ServingCount() >= C.CRAFT_SERVE_MAX then return end
	local now = ns.Now()
	while served[1] and now - served[1] >= 60 do table.remove(served, 1) end
	if #served >= C.CRAFT_SERVE_PER_MIN then return end
	served[#served + 1] = now
	local pages, i = Codec.EncodeCraftPages(prof, p.hash, p.ids, have == p.hash), 0
	serving[key] = true
	Crafters.stats.served = Crafters.stats.served + 1
	local function Step(ok)
		if ok and i < #pages then
			i = i + 1
			if ns.Comm.Send("WHISPER", pages[i], { target = sender, key = "wl:" .. key, done = Step }) then return end
		end
		serving[key] = nil
	end
	Step(true)
end

ns.Comm.On("WR", function(msg, sender, dist)
	if dist ~= "WHISPER" or not saved or not ns.IsMember() then return end
	local prof, fp, have = Codec.DecodeCraftQuery(msg)
	if not prof or not saved.posted or not saved.post[prof] or not saved.profs[prof] then return end
	-- В блокировке ответ застрял бы в очереди: смотрящий спросит позже.
	if ns.Comm.InLockdown() then return end
	local key, now = U.Key(sender), ns.Now()
	if not key or key == ns.myKey then return end
	local id = key .. ":" .. prof
	if lastQuery[id] and now - lastQuery[id] < C.CRAFT_SERVE_GAP then return end
	lastQuery[id] = now -- до проверки сертификата: иначе поток выдуманных отпечатков вызовет поток KQ
	ns.Security.Resolve(fp, sender, sender, function(certificate)
		if U.IsMemberGuild(certificate.guild) then Serve(sender, key, prof, have) end
	end)
end)

---------------------------------------------------------------------------
-- Названия рецептов: у игры, порциями, с кэшем на сессию
---------------------------------------------------------------------------
local names, folded = {}, {} -- [номер] = название или false; [номер] = U.Fold(название)
local queue, queued, pumping = {}, {}, false
local NAMES_PER_STEP = 200

local function Lookup(id)
	if type(C_Spell) == "table" and type(C_Spell.GetSpellName) == "function" then
		local ok, v = pcall(C_Spell.GetSpellName, id)
		if ok and type(v) == "string" and v ~= "" then return v end
	end
	local T = TradeSkill()
	if T and type(T.GetRecipeInfo) == "function" then
		local ok, info = pcall(T.GetRecipeInfo, id)
		if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then return info.name end
	end
	return false
end

local function Pump()
	if pumping then return end
	pumping = true
	ns.After(0, "crafters names", function()
		pumping = false
		local done = 0
		while #queue > 0 and done < NAMES_PER_STEP do
			local id = table.remove(queue)
			queued[id] = nil
			if names[id] == nil then names[id] = Lookup(id) end
			done = done + 1
		end
		if #queue > 0 then Pump() end
		ns.Fire("CRAFTERS_NAMES")
	end)
end

-- Название рецепта или nil (ещё не спрошено у игры или игра его не знает). Неизвестное встаёт
-- в очередь: названия разрешаются порциями по NAMES_PER_STEP за шаг.
function Crafters.RecipeName(id)
	local n = names[id]
	if n ~= nil then return n or nil end
	if not queued[id] then
		queued[id] = true
		queue[#queue + 1] = id
		Pump()
	end
	return nil
end

-- Название в нижнем регистре для поиска (U.Fold) или nil.
function Crafters.FoldedName(id)
	local f = folded[id]
	if f then return f end
	local n = Crafters.RecipeName(id)
	if not n then return nil end
	f = U.Fold(n)
	folded[id] = f
	return f
end

-- Сколько названий ещё ждут очереди.
function Crafters.NamesPending()
	return #queue
end

---------------------------------------------------------------------------
-- Значок, предмет и реагенты рецепта: у игры по номеру, только для видимых строк, с кэшем на
-- сессию. По сети они не ходят. Названия реагентов игра может догружать с сервера.
---------------------------------------------------------------------------
local details = {} -- [номер рецепта] = { icon, item, reagents = { { item, n } } }
local icons = {} -- [номер рецепта] = значок или false: только для витрины в строках каталога
local itemNames, itemWait = {}, {} -- [предмет] = название; [предмет] = true — игра догружает
local recipeItems = {} -- [номер рецепта] = предмет или false: рецепт предмета не создаёт
local itemFacts = {} -- [предмет] = { bound — персональный при поднятии, level — требуемый уровень }
local itemRedraw = false

local function Call(t, f, ...)
	local fn = type(t) == "table" and t[f]
	if type(fn) ~= "function" then return nil end
	local ok, a, b = pcall(fn, ...)
	if ok then return a, b end
end

local function Texture(v)
	if type(v) == "number" and v > 0 or type(v) == "string" and v ~= "" then return v end
end

-- Обязательные реагенты из схемы рецепта; необязательные (required = false) пропускаются.
local function Reagents(id)
	local s = Call(TradeSkill(), "GetRecipeSchematic", id, false)
	if type(s) ~= "table" or type(s.reagentSlotSchematics) ~= "table" then return nil end
	local out = {}
	for _, slot in ipairs(s.reagentSlotSchematics) do
		local r = type(slot) == "table" and slot.required ~= false and type(slot.reagents) == "table" and slot.reagents[1]
		local item, n = type(r) == "table" and r.itemID, type(slot) == "table" and tonumber(slot.quantityRequired)
		if type(item) == "number" and item > 0 and n and n > 0 then out[#out + 1] = { item = item, n = n } end
	end
	return out
end

-- Значок рецепта и предмет, который он создаёт; чего игра не знает — nil.
local function Look(id)
	local T = TradeSkill()
	local made = Call(T, "GetRecipeOutputItemData", id)
	local item = type(made) == "table" and type(made.itemID) == "number" and made.itemID > 0 and made.itemID or nil
	local info = Call(T, "GetRecipeInfo", id)
	local icon = Texture(type(info) == "table" and info.icon) or Texture(type(made) == "table" and made.icon)
		or item and Texture(Call(C_Item, "GetItemIconByID", item)) or Texture(Call(C_Spell, "GetSpellTexture", id))
	return icon, item
end

-- { icon, item, reagents } рецепта; поля, которых игра не знает, — nil.
function Crafters.RecipeDetails(id)
	local d = details[id]
	if d then return d end
	local icon, item = Look(id)
	d = { icon = icon, item = item, reagents = Reagents(id) }
	details[id] = d
	return d
end

-- Только значок рецепта, без реагентов: витрина видна в каждой строке каталога.
function Crafters.RecipeIcon(id)
	local d = details[id]
	if d then return d.icon end
	local icon = icons[id]
	if icon == nil then
		icon = Look(id) or false
		icons[id] = icon
	end
	return icon or nil
end

function Crafters.ItemIcon(item)
	return Texture(Call(C_Item, "GetItemIconByID", item))
end

-- Название предмета или nil: тогда игра догружает его, и вкладка перерисуется.
function Crafters.ItemName(item)
	local n = itemNames[item]
	if n then return n end
	n = Call(C_Item, "GetItemNameByID", item)
	if type(n) == "string" and n ~= "" then
		itemNames[item] = n
		return n
	end
	if not itemWait[item] and type(C_Item) == "table" then
		itemWait[item] = true
		Call(C_Item, "RequestLoadItemDataByID", item)
	end
	return nil
end

-- Предмет, который создаёт рецепт, или nil. Только номер, без значка и реагентов: фильтрам
-- персональных и уровня он нужен для всего списка мастера сразу.
function Crafters.RecipeItem(id)
	local item = recipeItems[id]
	if item == nil then
		local made = Call(TradeSkill(), "GetRecipeOutputItemData", id)
		item = type(made) == "table" and type(made.itemID) == "number" and made.itemID > 0 and made.itemID or false
		recipeItems[id] = item
	end
	return item or nil
end

-- Из ответа GetItemInfo: пятое значение — требуемый уровень, четырнадцатое — тип привязки
-- (1 — персональный при поднятии). Без названия игра предмета ещё не знает.
local function PickFacts(ok, name, _, _, _, level, ...)
	if not ok or not name then return nil end
	return { bound = select(9, ...) == 1, level = type(level) == "number" and level or 0 }
end

local function ItemInfo(item)
	local get = type(C_Item) == "table" and C_Item.GetItemInfo
	if type(get) ~= "function" then get = GetItemInfo end
	if type(get) ~= "function" then return nil end
	return PickFacts(pcall(get, item))
end

-- { bound, level } предмета или nil: игра ещё не знает предмет, она его догружает, и вкладка
-- перерисуется.
local function ItemFacts(item)
	local facts = itemFacts[item]
	if facts then return facts end
	if itemWait[item] then return nil end
	facts = ItemInfo(item)
	if facts then
		itemFacts[item] = facts
		return facts
	end
	if type(C_Item) == "table" then
		itemWait[item] = true
		Call(C_Item, "RequestLoadItemDataByID", item)
	end
	return nil
end

-- Предмет становится персональным при поднятии: true или false, nil — пока неизвестно.
function Crafters.ItemBound(item)
	local facts = ItemFacts(item)
	if facts then return facts.bound end
end

-- Рецепт создаёт персональный при поднятии предмет: такой мастер не сможет передать. Рецепт без
-- предмета (зачарование) — false; nil — пока неизвестно.
function Crafters.RecipeBound(id)
	local item = Crafters.RecipeItem(id)
	if not item then return false end
	return Crafters.ItemBound(item)
end

-- Требуемый уровень предмета, который создаёт рецепт (0 — без требования). false — рецепт
-- предмета не создаёт (зачарование), nil — пока неизвестно.
function Crafters.RecipeLevel(id)
	local item = Crafters.RecipeItem(id)
	if not item then return false end
	local facts = ItemFacts(item)
	return facts and facts.level
end

-- Показывать ли рецепты персональных предметов. Настройка общая для персонажей, по умолчанию
-- они скрыты.
function Crafters.ShowBound()
	return ns.db.settings.craftBound == true
end

function Crafters.SetShowBound(on)
	ns.db.settings.craftBound = on and true or nil
	ns.Fire("CRAFTERS_NAMES")
end

-- Ответы игры на догрузку приходят пачкой: перерисовка одна на пачку.
local function ItemLoaded(item)
	if not itemWait[item] then return end
	itemWait[item] = nil
	if itemRedraw then return end
	itemRedraw = true
	ns.After(0.2, "crafters items", function()
		itemRedraw = false
		ns.Fire("CRAFTERS_NAMES")
	end)
end

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
local function Tick()
	local now = ns.Now()
	for _, ask in pairs(asks) do
		if now >= ask.deadline then Fail(ask, "silent") end
	end
	for id, at in pairs(lastQuery) do
		if now - at >= C.CRAFT_SERVE_GAP then lastQuery[id] = nil end
	end
	if now - lastClean >= 60 then
		lastClean = now
		if Clean() then Changed() end
	end
	if not saved or not saved.posted or sealing or now < firstAt then return end
	-- В блокировке сообщение застряло бы в очереди: карточка уйдёт после неё.
	if ns.Comm.InLockdown() or not ns.IsMember() or not ns.Security.MyCertificate() or #Chosen() == 0 then return end
	local since = ns.ServerTime() - (saved.sentAt or 0)
	if since < -3600 then since = math.huge end -- часы ушли назад
	if Signature() ~= saved.sentSig then
		if since >= C.CRAFT_UPDATE_GAP then
			saved.st = ns.ServerTime()
			Broadcast(false)
		end
	elseif since >= Every() * 60 then
		Broadcast(false)
	end
end
Crafters.Tick = Tick

local function Valid(card, key)
	if type(card) ~= "table" or type(card.name) ~= "string" or type(card.guild) ~= "string" or type(card.at) ~= "number"
		or type(card.seq) ~= "number" or type(card.profs) ~= "table" or #card.profs == 0 then return false end
	card.key = key
	card.note = type(card.note) == "string" and card.note or ""
	local profs = {}
	for _, p in ipairs(card.profs) do
		if type(p) ~= "table" or type(p.id) ~= "number" or type(p.hash) ~= "string" then return false end
		p.skill, p.max, p.n = tonumber(p.skill) or 0, tonumber(p.max) or 0, tonumber(p.n) or 0
		local show = {}
		for _, id in ipairs(type(p.show) == "table" and p.show or {}) do
			if type(id) == "number" and #show < C.CRAFT_SHOW then show[#show + 1] = id end
		end
		p.show = #show > 0 and show or nil
		if Known(p.id) then profs[#profs + 1] = p end
	end
	-- Рыбная ловля, сохранённая прежней версией, выбрасывается; без остального карточки нет.
	card.profs = profs
	return #profs > 0
end

local function Restore()
	ns.char.crafts = type(ns.char.crafts) == "table" and ns.char.crafts or {}
	saved = ns.char.crafts
	for _, k in ipairs({ "profs", "post", "hinted" }) do
		saved[k] = type(saved[k]) == "table" and saved[k] or {}
	end
	-- Рыбную ловлю прочитала прежняя версия: из своих профессий и отметок она уходит, а карточка без
	-- неё уйдёт остальным правкой.
	for id, p in pairs(saved.profs) do
		if type(id) ~= "number" or not Known(id) or type(p) ~= "table" or type(p.ids) ~= "string" or type(p.hash) ~= "string" then
			saved.profs[id] = nil
		else
			p.skill, p.max, p.n = tonumber(p.skill) or 0, tonumber(p.max) or 0, tonumber(p.n) or 0
			p.readAt = tonumber(p.readAt) or 0
		end
	end
	for id in pairs(saved.post) do
		if not Known(id) then saved.post[id] = nil end
	end
	local show = {}
	for _, s in ipairs(type(saved.show) == "table" and saved.show or {}) do
		if type(s) == "table" and type(s.prof) == "number" and Known(s.prof) and type(s.id) == "number" then
			show[#show + 1] = { prof = s.prof, id = s.id }
		end
	end
	saved.show = show
	saved.note = type(saved.note) == "string" and saved.note or ""
	saved.posted = saved.posted == true
	saved.sentAt = tonumber(saved.sentAt)
	if type(saved.sentSig) ~= "string" then saved.sentSig = nil end
	local store = ns.store.crafters
	if type(store) ~= "table" then
		store = {}
		ns.store.crafters = store
	end
	store.cards = type(store.cards) == "table" and store.cards or {}
	store.lists = type(store.lists) == "table" and store.lists or {}
	cards, lists = store.cards, store.lists
	for key, card in pairs(cards) do
		if type(key) ~= "string" or not Valid(card, key) then cards[key] = nil end
	end
	for key, byProf in pairs(lists) do
		if type(byProf) ~= "table" then
			lists[key] = nil
		else
			for prof, entry in pairs(byProf) do
				if type(entry) ~= "table" or type(entry.hash) ~= "string" or type(entry.ids) ~= "string" or type(entry.at) ~= "number" then
					byProf[prof] = nil
				end
			end
			if not next(byProf) then lists[key] = nil end
		end
	end
	Clean()
end

ns.On("LOGIN", function()
	Restore()
	-- Сертификату после входа нужно время, а перезаходы не должны плодить пакеты: своя
	-- карточка проверяется через случайные 2-5 минут.
	firstAt = ns.Now() + math.random(C.CRAFT_FIRST_MIN, C.CRAFT_FIRST_MAX)
	ns.Every(5, "crafters tick", Tick)
	-- Регистрация события, которого нет в этой версии игры, падает: каждое — через pcall.
	pcall(ns.RegisterEvent, "TRADE_SKILL_SHOW", function()
		shown = true
		Soon()
	end)
	pcall(ns.RegisterEvent, "TRADE_SKILL_CLOSE", function() shown = false end)
	for _, event in ipairs({ "TRADE_SKILL_LIST_UPDATE", "TRADE_SKILL_DATA_SOURCE_CHANGED" }) do
		pcall(ns.RegisterEvent, event, function() if shown then Soon() end end)
	end
	pcall(ns.RegisterEvent, "GET_ITEM_INFO_RECEIVED", ItemLoaded)
end)

ns.Status(function()
	local own = Crafters.Posted() and L.CRAFT_STATUS_POSTED or L.CRAFT_STATUS_NONE
	return L.CRAFT_STATUS:format(#Crafters.Cards(), own)
end)
