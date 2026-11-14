-- Chillzone: желания. Списки предметов, которые ищут игроки объединения: свой список игрок
-- записывает на вкладке «Желания», а у остальных в подсказке предмета видно, кому он нужен.
-- Идея и разбор списка — из аддона JustWishList; там списки ходили по гильдии, здесь — по
-- объединению, тем же путём, что карточки мастеров.
--
-- Карточка V1 — номера предметов по порядку важности, не больше WISH_ITEMS. Она подписывается
-- и расходится только в конверте строки чата (Codec.WrapWish): S1 по GUILD своей гильдии и через
-- реле остальным (режим P). Реле, репортёры и чат 0.15.0 и старше пересылают конверт как строку
-- чата и молча его отбрасывают, поэтому Security.lua новый вид не нужен. Автор повторяет
-- карточку раз в Every() минут; время прошлой отправки хранится у персонажа и переживает /reload.
-- Порядок пакетов автора — по времени и номеру подписи S1: снятый список (X) старым пакетом не
-- вернётся. По сети идут только номера: названия каждый клиент берёт у игры сам.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Wishes = {}
ns.Wishes = Wishes

local saved -- ns.char.wishes: свой текст, номера предметов, своя карточка
local cards -- ns.store.wishes.cards: [ключ автора] = карточка
local closed = {} -- [ключ автора] = { at, seq } снятого списка: старый пакет его не вернёт
local byItem -- [номер предмета] = { ключи авторов }; nil — пересобрать
local sealing = false
local lastPost = -1e9
local firstAt -- после входа свой список проверяется не раньше
local lastClean = -1e9

Wishes.stats = { heard = 0, stale = 0 }

local function Changed()
	byItem = nil
	ns.Fire("WISHES")
end

---------------------------------------------------------------------------
-- Разбор своего списка
---------------------------------------------------------------------------
local function ItemByName(name)
	local get = type(C_Item) == "table" and C_Item.GetItemInfo
	if type(get) ~= "function" then get = GetItemInfo end
	if type(get) ~= "function" then return nil end
	local ok, _, link = pcall(get, name)
	return ok and type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Текст поля: ссылки на предметы (Shift+щелчок), номера и названия — с новой строки, через
-- запятую или точку с запятой. Название находится, только если игра уже знает предмет.
-- Возвращает номера по порядку (без повторов, не больше WISH_ITEMS) и названия, которые не
-- узнаны. Третье значение — сколько предметов не уместилось.
function Wishes.Parse(text)
	local ids, unknown, seen, extra = {}, {}, {}, 0
	local function Add(id)
		if not id or id < 1 or seen[id] then return end
		seen[id] = true
		if #ids >= C.WISH_ITEMS then
			extra = extra + 1
		else
			ids[#ids + 1] = id
		end
	end
	text = tostring(text or "")
	-- Сначала ссылки целиком: в названиях бывают запятые.
	text = text:gsub("|c%x%x%x%x%x%x%x%x(|Hitem:[^|]*|h%[.-%]|h)|r", "%1")
	text = text:gsub("|Hitem:(%d+)[^|]*|h%[.-%]|h", function(id)
		Add(tonumber(id))
		return "\n"
	end)
	-- Прочие ссылки (рецепты, заклинания) — их текстом.
	text = text:gsub("|H[^|]*|h%[(.-)%]|h", "%1")
	text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	for part in text:gmatch("[^\n,;]+") do
		local name = U.Trim((part:gsub("[%[%]]", "")))
		if name ~= "" then
			local id = name:match("^%d+$") and tonumber(name) or ItemByName(name)
			if id then Add(id) else unknown[#unknown + 1] = name end
		end
	end
	return ids, unknown, extra
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

local function Drop(key)
	local had = cards[key] ~= nil
	cards[key] = nil
	return had
end

local function Oldest()
	local key, at
	for k, card in pairs(cards) do
		if not at or card.at < at then key, at = k, card.at end
	end
	return key
end

-- Чистка: срок списка и предел каталога.
local function Clean()
	local time, changed = ns.ServerTime(), false
	for key, card in pairs(cards) do
		if time - card.at > C.WISH_KEEP then
			ns.Log("желания: список %s <%s> пропал: автор его не повторил", card.name, card.guild)
			Drop(key)
			changed = true
		end
	end
	local n = Count()
	while n > C.WISH_MAX do
		Drop(Oldest())
		n, changed = n - 1, true
	end
	for key, tomb in pairs(closed) do
		if time - tomb.at > C.CHAT_DEDUPE + 60 then closed[key] = nil end
	end
	return changed
end

function Wishes.Receive(msg, _, dist, ctx)
	if dist ~= "GUILD" and dist ~= "RELAY" then return end
	local c = ctx and ctx.authenticated and ctx.certificate
	if not c or not cards or not ns.IsMember() then return end
	local w = Codec.DecodeWish(msg)
	if not w or not U.IsMemberGuild(w.guild) then return end
	local key, name = c.key, U.Display(c.name)
	if not key or key == ns.myKey then return end -- свой показывается из ns.char
	local own, theirs = U.GuildKey(ns.MyGuild()), U.GuildKey(w.guild)
	local via = dist == "GUILD" and "своя гильдия" or "реле"
	if U.GuildKey(c.guild) ~= theirs then
		ns.Log("желания: список %s не принят: гильдия сертификата <%s>, в списке <%s> (%s)", name, c.guild, w.guild, via)
		return
	end
	if dist == "GUILD" and theirs ~= own then return end -- по GUILD пишут только согильдийцы
	if dist == "RELAY" and theirs == own then return end -- своя гильдия приходит напрямую
	local at, seq = Stamp(ctx.wire)
	if not at then return end
	Wishes.stats.heard = Wishes.stats.heard + 1
	local old = cards[key]
	if not Newer(at, seq, closed[key]) or not Newer(at, seq, old) then
		Wishes.stats.stale = Wishes.stats.stale + 1
		return
	end
	if w.mode == "X" then
		closed[key] = { at = at, seq = seq }
		if Drop(key) then
			ns.Log("желания: %s <%s> снял список (%s)", name, w.guild, via)
			Changed()
		end
		return
	end
	if ns.store.ignore[key] then
		if Drop(key) then Changed() end
		return
	end
	if ns.ServerTime() - at > C.WISH_KEEP then
		ns.Log("желания: список %s <%s> не принят: пришёл просроченным (%s)", name, w.guild, via)
		return
	end
	if not old and Count() >= C.WISH_MAX then Drop(Oldest()) end
	-- Журнал: новый список и правка. Повтор того же списка не пишется.
	if not old then
		ns.Log("желания: список %s <%s> принят (%s)", name, w.guild, via)
	elseif old.st ~= w.st then
		ns.Log("желания: список %s <%s> обновлён (%s)", name, w.guild, via)
	end
	cards[key] = {
		key = key, name = name, guild = w.guild, class = w.class, level = w.level, st = w.st,
		at = at, seq = seq, items = w.items,
	}
	Changed()
end
ns.Comm.On("V1", Wishes.Receive)

function Wishes.Get(key)
	return cards and cards[key]
end

-- Видимые списки: гильдия в объединении, автор не в игноре. Свой — отдельно (Wishes.Own).
function Wishes.Cards()
	local out = {}
	for key, card in pairs(cards or {}) do
		if U.IsMemberGuild(card.guild) and not ns.store.ignore[key] then out[#out + 1] = card end
	end
	return out
end

-- Сколько списков в каталоге, считая свой.
function Wishes.Count()
	return #Wishes.Cards() + (Wishes.Own() and 1 or 0)
end

-- Согильдиец, которого нет в свежем ростере, ушёл из гильдии: его список не показывается.
ns.On("ROSTER", function()
	if not cards or not ns.Roster.Fresh() then return end
	local own, changed = U.GuildKey(ns.MyGuild()), false
	for key, card in pairs(cards) do
		if U.GuildKey(card.guild) == own and ns.Roster.byKey[key] == nil then
			ns.Log("желания: список %s <%s> убран: его нет в ростере", card.name, card.guild)
			Drop(key)
			changed = true
		end
	end
	if changed then Changed() end
end)

-- Свой список в том же виде, что чужие, пока он размещён; nil — списка нет.
function Wishes.Own()
	if not saved or not saved.posted or #saved.items == 0 then return nil end
	local _, class = UnitClass("player")
	return {
		key = ns.myKey, name = U.Display(ns.me), guild = ns.MyGuild() or "", class = class,
		level = UnitLevel("player") or 0, items = saved.items, own = true,
		at = saved.sentAt or ns.ServerTime(), st = saved.st,
	}
end

-- Кому нужен предмет: карточки (своя первой), остальные — сначала те, кто в игре, затем по имени.
function Wishes.Who(item)
	if not item then return {} end
	if not byItem then
		byItem = {}
		local all = Wishes.Cards()
		local own = Wishes.Own()
		if own then table.insert(all, 1, own) end
		for _, card in ipairs(all) do
			for _, id in ipairs(card.items) do
				byItem[id] = byItem[id] or {}
				table.insert(byItem[id], card)
			end
		end
	end
	local list = byItem[item]
	if not list then return {} end
	local out = {}
	for i, card in ipairs(list) do out[i] = card end
	return out
end

---------------------------------------------------------------------------
-- Свой список
---------------------------------------------------------------------------
function Wishes.Text()
	return saved and saved.text or ""
end

function Wishes.Items()
	return saved and saved.items or {}
end

function Wishes.Posted()
	return saved ~= nil and saved.posted == true and #saved.items > 0
end

-- Что в карточке, кроме времени, класса и уровня: смена — правка, а не повтор.
local function Signature()
	return tostring(ns.MyGuild()) .. "~" .. table.concat(saved.items, ",")
end

-- Размещённый список отличается от того, что ушло в сеть: правка уйдёт после паузы.
function Wishes.Dirty()
	return Wishes.Posted() and Signature() ~= saved.sentSig
end

-- Чем больше списков слышно, тем реже каждый повторяется: весь каталог — около WISH_PER_MIN в минуту.
local function Every()
	local n, time = 0, ns.ServerTime()
	for _, card in pairs(cards or {}) do
		if time - card.at < C.WISH_EVERY_MAX * 60 then n = n + 1 end
	end
	return math.max(C.WISH_EVERY_MIN, math.min(C.WISH_EVERY_MAX, math.ceil((n + 1) / C.WISH_PER_MIN)))
end
Wishes.Every = Every

local function Seal(msg, prio, done)
	local inner = msg and Codec.WrapWish(msg)
	if not inner then return false, "failed" end
	return ns.Security.Seal(inner, function(wire, failed)
		if wire then
			ns.Comm.Send("GUILD", wire, { prio = prio, key = "wishes:mine" })
			done(wire, ns.Relay.Out("P", wire))
		else
			done(nil, nil, failed)
		end
	end)
end

local function Broadcast(prio)
	local guild = ns.MyGuild()
	if not guild or #saved.items == 0 then return false, "none" end
	local _, class = UnitClass("player")
	local msg = Codec.EncodeWish({
		mode = "C", st = saved.st or ns.ServerTime(), guild = guild, class = class,
		level = UnitLevel("player") or 0, items = saved.items,
	})
	local sig, first = Signature(), saved.sentSig == nil
	sealing = true
	local ok, why = Seal(msg, prio, function(wire, relayed, failed)
		sealing = false
		if not wire then
			saved.sentSig = nil -- уйдёт правкой после паузы
			ns.Log("желания: свой список не подписан: %s", tostring(failed))
			return
		end
		-- Без отвечающего реле Relay.Out держит список и отправляет, когда реле ответит на опрос.
		if not relayed then
			ns.Log("желания: свой список ушёл гильдии, отвечающего реле нет: остальным уйдёт после его ответа")
		elseif first then
			ns.Log("желания: свой список ушёл гильдии и реле")
		end
	end)
	if not ok then
		sealing = false
		return false, why
	end
	saved.sentAt, saved.sentSig = ns.ServerTime(), sig
	return true
end

-- Сколько секунд до следующего «Сохранить» (0 — можно сейчас).
function Wishes.PostWait()
	return math.max(0, math.ceil(lastPost + C.WISH_POST_GAP - ns.Now()))
end

-- Снять свой список: он пропадает у остальных сразу.
local function Withdraw()
	saved.posted, saved.sentSig = false, nil
	local guild = ns.MyGuild()
	local msg = guild and ns.IsMember() and Codec.EncodeWish({ mode = "X", st = ns.ServerTime(), guild = guild })
	if msg then Seal(msg, true, function() end) end
	ns.Log("желания: свой список снят")
end

-- «Сохранить»: текст поля разбирается, список уходит сразу; пустой список снимается.
-- true, сколько предметов, неузнанные названия, сколько не уместилось — или false, причина[, секунды
-- или названия]: unknown (ни одного предмета не узнано), notmember, nocert, wait, busy, failed.
function Wishes.Save(text)
	if not saved then return false, "failed" end
	local ids, unknown, extra = Wishes.Parse(text)
	-- Ни одного узнанного предмета, но что-то написано: список не снимается молча.
	if #ids == 0 and #unknown > 0 then return false, "unknown", unknown end
	if #ids > 0 then
		if not ns.IsMember() then return false, "notmember" end
		if not ns.Security.MyCertificate() then return false, "nocert" end
		if sealing then return false, "busy" end
		local wait = Wishes.PostWait()
		if wait > 0 then return false, "wait", wait end
	end
	local was, st, oldText, oldItems = saved.posted, saved.st, saved.text, saved.items
	saved.text, saved.items = U.Trim(tostring(text or "")), ids
	if #ids == 0 then
		if was then Withdraw() end
		Changed()
		return true, 0, unknown, extra
	end
	saved.posted = true
	if not was or Signature() ~= saved.sentSig then saved.st = ns.ServerTime() end
	local ok, why = Broadcast(true)
	if not ok then
		saved.posted, saved.st, saved.text, saved.items = was, st, oldText, oldItems
		return false, why
	end
	lastPost = ns.Now()
	ns.Log("желания: свой список %s, предметов %d", was and "обновлён" or "размещён", #ids)
	Changed()
	return true, #ids, unknown, extra
end

---------------------------------------------------------------------------
-- Подсказка предмета: «Нужно: Имя, Имя и ещё 3»
---------------------------------------------------------------------------
function Wishes.ShowTooltip()
	return ns.db.settings.wishTooltip ~= false
end

function Wishes.SetShowTooltip(on)
	if on then ns.db.settings.wishTooltip = nil else ns.db.settings.wishTooltip = false end
	ns.Fire("WISHES")
end

local RANK = { own = 0, online = 1, recent = 2, away = 3, offline = 4 }

-- Строка подсказки для предмета или nil: никому не нужен или подсказка выключена.
function Wishes.TipLine(item)
	if not saved or not Wishes.ShowTooltip() then return nil end
	local who = Wishes.Who(item)
	if #who == 0 then return nil end
	local ranked = {}
	for i, card in ipairs(who) do
		ranked[i] = { card = card, rank = card.own and 0 or RANK[ns.Crafters.Presence(card)] or 3 }
	end
	table.sort(ranked, function(a, b)
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.card.name < b.card.name
	end)
	local names = {}
	for i = 1, math.min(#ranked, C.WISH_TIP_NAMES) do
		local r = ranked[i]
		local name = ns.Views.Name(r.card.name, r.card.class)
		if r.rank >= RANK.offline then name = "|cff808080" .. Codec.Plain(r.card.name) .. "|r" end
		names[i] = name
	end
	local line = ns.COLOR .. L.WISH_TIP_NEEDED .. "|r " .. table.concat(names, ", ")
	if #ranked > C.WISH_TIP_NAMES then
		line = line .. " |cffaaaaaa" .. L.WISH_TIP_MORE:format(#ranked - C.WISH_TIP_NAMES) .. "|r"
	end
	return line
end

local function ItemOf(tt)
	if type(tt) ~= "table" or type(tt.GetItem) ~= "function" then return nil end
	local ok, _, link = pcall(tt.GetItem, tt)
	return ok and type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

-- Сравнение с надетым предметом подсказки не нужна: строка уже есть в основной.
local function Shopping(tt)
	return tt == rawget(_G, "ShoppingTooltip1") or tt == rawget(_G, "ShoppingTooltip2")
end

local function AddTo(tt, item)
	if Shopping(tt) then return false end
	if issecretvalue and item and issecretvalue(item) then return false end
	local line = Wishes.TipLine(item or ItemOf(tt))
	if not line then return false end
	tt:AddLine(line, 1, 1, 1, true)
	return true
end
Wishes.AddTo = AddTo

-- Только пост-хуки: подсказка игры дописывается после того, как её заполнила игра.
local function HookTooltips()
	local processor = rawget(_G, "TooltipDataProcessor")
	if type(processor) == "table" and type(processor.AddTooltipPostCall) == "function"
		and type(Enum) == "table" and type(Enum.TooltipDataType) == "table" and Enum.TooltipDataType.Item then
		processor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
			local id = type(data) == "table" and data.id or nil
			if issecretvalue and id and issecretvalue(id) then id = nil end
			ns.SafeCall("wishes tooltip", AddTo, tt, type(id) == "number" and id or nil)
		end)
		return
	end
	for _, name in ipairs({ "GameTooltip", "ItemRefTooltip" }) do
		local tt = rawget(_G, name)
		if type(tt) == "table" and type(tt.HookScript) == "function" then
			pcall(tt.HookScript, tt, "OnTooltipSetItem", function(self)
				ns.SafeCall("wishes tooltip", function()
					if AddTo(self) then self:Show() end
				end)
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Расписание
---------------------------------------------------------------------------
local function Tick()
	local now = ns.Now()
	if now - lastClean >= 60 then
		lastClean = now
		if Clean() then Changed() end
	end
	if not Wishes.Posted() or sealing or now < firstAt then return end
	-- В блокировке сообщение застряло бы в очереди: список уйдёт после неё.
	if ns.Comm.InLockdown() or not ns.IsMember() or not ns.Security.MyCertificate() then return end
	local since = ns.ServerTime() - (saved.sentAt or 0)
	if since < -3600 then since = math.huge end -- часы ушли назад
	if Signature() ~= saved.sentSig then
		if since >= C.WISH_UPDATE_GAP then
			saved.st = ns.ServerTime()
			Broadcast(false)
		end
	elseif since >= Every() * 60 then
		Broadcast(false)
	end
end
Wishes.Tick = Tick

local function Valid(card, key)
	if type(card) ~= "table" or type(card.name) ~= "string" or type(card.guild) ~= "string" or type(card.at) ~= "number"
		or type(card.seq) ~= "number" or type(card.items) ~= "table" then return false end
	card.key = key
	card.items = Codec.WishIds(card.items)
	return #card.items > 0
end

local function Restore()
	ns.char.wishes = type(ns.char.wishes) == "table" and ns.char.wishes or {}
	saved = ns.char.wishes
	saved.text = type(saved.text) == "string" and saved.text or ""
	saved.items = Codec.WishIds(type(saved.items) == "table" and saved.items or {}, C.WISH_ITEMS)
	saved.posted = saved.posted == true
	saved.st = tonumber(saved.st)
	saved.sentAt = tonumber(saved.sentAt)
	if type(saved.sentSig) ~= "string" then saved.sentSig = nil end
	local store = ns.store.wishes
	if type(store) ~= "table" then
		store = {}
		ns.store.wishes = store
	end
	store.cards = type(store.cards) == "table" and store.cards or {}
	cards = store.cards
	for key, card in pairs(cards) do
		if type(key) ~= "string" or not Valid(card, key) then cards[key] = nil end
	end
	Clean()
	byItem = nil
end

ns.On("LOGIN", function()
	Restore()
	-- Сертификату после входа нужно время, а перезаходы не должны плодить пакеты: свой список
	-- проверяется через случайные 2,5-5,5 минуты.
	firstAt = ns.Now() + math.random(C.WISH_FIRST_MIN, C.WISH_FIRST_MAX)
	ns.Every(5, "wishes tick", Tick)
	HookTooltips()
end)

-- Имена в подсказке красятся по присутствию: оно меняется с ростером и списками Online.
ns.On("ROSTER", function() byItem = nil end)

ns.Status(function()
	local own = Wishes.Posted() and L.WISH_STATUS_POSTED:format(#saved.items) or L.WISH_STATUS_NONE
	return L.WISH_STATUS:format(#Wishes.Cards(), own)
end)
