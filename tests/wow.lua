-- Симулятор мира WoW: Forever для тестов. Несколько клиентов, каждый со своим окружением
-- (setfenv) и своей копией аддона; гильдии, ростер, GUILD/WHISPER аддон-сообщения,
-- обычный текст в канале, системное «нет такого игрока», таймеры и общие часы.
-- Текст в канал сервер принимает только из нажатия клавиши: Client:Slash и Client:Press
-- ставят признак, SendChatMessage в CHANNEL без него строку не доставляет (c.blocked) и
-- игра шлёт ADDON_ACTION_BLOCKED. Сервер пропускает channelLimit строк игрока за скользящие
-- channelWindow секунд, лишние не раздаёт и отвечает автору THROTTLED (как в игре 2026-11-11).
-- Лимит сервера на аддон-сообщения GUILD (World:GuildRefused) по умолчанию выключен.
local T = ...

local Wow = {}

local SERVER0 = 1793000000
-- Названия рецептов, которые знает игра (C_Spell.GetSpellName, C_TradeSkillUI.GetRecipeInfo).
-- Номер 2660 и его название проверены в игре 2026-11-13.
Wow.RECIPE_NAMES = {
	[2660] = "Грубое точило", [2661] = "Медная кольчуга", [2662] = "Медные поножи", [2663] = "Медные наручи",
	[2664] = "Рунический медный пояс", [3115] = "Тяжёлое точило", [3116] = "Грубый точильный камень",
	[7408] = "Тяжёлая медная кольчуга", [9983] = "Медный когтевой клинок", [16639] = "Плотное точило",
	[2149] = "Кожаные ботинки", [2152] = "Лёгкая обработанная кожа", [3104] = "Бронзовый топор", [7418] = "Чары для наручей",
	[16988] = "Шлем львиного сердца",
}
-- Предмет, значок и реагенты рецепта (C_TradeSkillUI.GetRecipeOutputItemData, GetRecipeInfo().icon,
-- GetRecipeSchematic): reagents — { предмет, число[, необязательный] }. Рецепт без предмета — как у
-- зачарования. Названия предметов (C_Item) клиент знает только после догрузки с сервера.
Wow.RECIPES = {
	[2660] = { item = 2862, icon = 135248, reagents = { { 2835, 1 } } },
	[2661] = { item = 2852, icon = 132624, reagents = { { 2840, 8 } } },
	[2662] = { item = 2854, icon = 134583, reagents = { { 2840, 6 }, { 2320, 2 }, { 4357, 1, true } } },
	[7418] = { icon = 136244, reagents = { { 10940, 1 } } },
	[16988] = { item = 12640, icon = 133073, reagents = { { 12359, 80 } } },
}
Wow.ITEM_NAMES = {
	[2862] = "Грубое точило", [2852] = "Медная кольчуга", [2854] = "Медные поножи", [2835] = "Грубый камень",
	[2840] = "Медный слиток", [2320] = "Грубая нить", [4357] = "Грубый порох", [10940] = "Странная пыль",
	[12640] = "Шлем львиного сердца", [12359] = "Ториевый слиток",
}
-- Тип привязки предмета (14-е значение GetItemInfo): 1 — персональный при поднятии, 2 — при
-- надевании; остальные — 0.
Wow.ITEM_BIND = { [12640] = 1, [2852] = 2, [2854] = 2 }
-- Требуемый уровень предмета (5-е значение GetItemInfo); остальные — 0.
Wow.ITEM_LEVEL = { [2852] = 7, [2854] = 9, [12640] = 56 }
local NOT_FOUND = "No player named '%s' is currently playing."

local World = {}
World.__index = World

-- channelClosed — сервер не доставляет строки каналов никому; guidClass — классы игроков
-- без аддона по GUID (World:ChannelSay); channelLimit и channelWindow — лимит строк игрока в канал.
function Wow.World()
	local w = setmetatable({ now = 0, timers = {}, seq = 0, clients = {}, guilds = {}, channels = {}, log = {}, guidClass = {}, lineId = 0,
		channelLimit = 3, channelWindow = 30 }, World)
	return w
end

function World:Schedule(at, fn, client)
	self.seq = self.seq + 1
	self.timers[#self.timers + 1] = { at = at, fn = fn, seq = self.seq, client = client }
end

-- Часы идут до t, по пути срабатывают таймеры (в порядке времени).
function World:Run(seconds)
	local stop = self.now + seconds
	while true do
		local best, bi
		for i, t in ipairs(self.timers) do
			if t.at <= stop and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then best, bi = t, i end
		end
		if not best then break end
		table.remove(self.timers, bi)
		if best.at > self.now then self.now = best.at end
		if not best.client or best.client.online then best.fn() end
	end
	self.now = stop
end

-- Офицеры задают корни доверия своих гильдий (/chillzone trust init): раз на гильдию.
function World:Init(...)
	local list = { ... }
	for _, c in ipairs(list) do assert(c.ns.Security.Init(), c:Name() .. ": /chillzone trust init отклонён") end
	self:Run(12)
	for _, c in ipairs(list) do
		local root = c.ns.Security.Roots()[c.ns.Util.GuildKey(c.guild)]
		assert(root and root.name == c:Name(), c:Name() .. ": корень не задан")
	end
end

function World:Pair(source, receiver)
	assert(source.ns.Security.Link(receiver:Name()), "officer could not initiate pairing")
	self:Run(5)
	assert(receiver.ns.Security.Accept(source:Name()), "receiving officer could not approve pairing")
	self:Run(10)
end

---------------------------------------------------------------------------
-- Гильдии: участники — клиенты или просто строки ростера (не в игре)
---------------------------------------------------------------------------
-- officers — rankIndex званий с игровым флагом «офицер» (по умолчанию 0 и 1).
function World:Guild(name, ranks, officers)
	local g = {
		name = name, ranks = ranks or { "Глава", "Офицер", "Ветеран", "Рядовой" }, members = {},
		officers = officers or { [0] = true, [1] = true },
	}
	self.guilds[name] = g
	return g
end

function World:AddOffline(guild, full, rank, level, class, days)
	local g = self.guilds[guild]
	g.members[#g.members + 1] = { full = full, rank = rank, level = level or 60, class = class or "WARRIOR", days = days or 3 }
end

-- Согильдиец в игре без аддона: есть в ростере, но клиента у него нет.
function World:AddOnline(guild, full, rank, level, class)
	local g = self.guilds[guild]
	g.members[#g.members + 1] = { full = full, rank = rank, level = level or 60, class = class or "WARRIOR", online = true }
end

-- Системные строки гильдии (в игре — свои для языка клиента).
local ERR_GUILD_REMOVE_SS = "%s has been kicked out of the guild by %s."
local ERR_GUILD_LEAVE_S = "%s has left the guild."
local ERR_GUILD_JOIN_S = "%s has joined the guild."

-- Системная строка гильдии: её видят все её участники в игре.
function World:GuildSystem(guild, text)
	for _, c in ipairs(self.clients) do
		if c.online and c.guild == guild then
			self:Schedule(self.now + 0.05, function() c:Fire("CHAT_MSG_SYSTEM", text) end, c)
		end
	end
end

-- Исключение: клиент теряет гильдию, строка ростера пропадает. name — «Имя Фамилия».
-- by — кто исключил (клиент): тогда гильдия получает системную строку, как в игре.
function World:Uninvite(guild, name, by)
	local short = name:gsub("%-.*$", "")
	local done = false
	for _, o in ipairs(self.clients) do
		if not done and o.guild == guild and (o.first .. " " .. o.surname) == short then
			o.guild = nil
			if o.online then o:Fire("PLAYER_GUILD_UPDATE", "player") end
			done = true
		end
	end
	local g = self.guilds[guild]
	for i, m in ipairs(g and g.members or {}) do
		if not done and m.full:gsub("%-.*$", "") == short then
			table.remove(g.members, i)
			done = true
		end
	end
	if done and by then self:GuildSystem(guild, ERR_GUILD_REMOVE_SS:format(short, by:Name())) end
	return done
end

-- Игрок вступил в гильдию (принял приглашение): who — клиент или «Имя Фамилия-Реалм» строки
-- ростера без клиента. Гильдия получает системную строку.
function World:Join(guild, who, rank)
	local g = self.guilds[guild]
	rank = rank or #g.ranks - 1
	local short
	if type(who) == "table" then
		who.guild, who.rank = guild, rank
		short = who:Name()
		if who.online then who:Fire("PLAYER_GUILD_UPDATE", "player") end
	else
		g.members[#g.members + 1] = { full = who, rank = rank, level = 60, class = "WARRIOR", days = 0 }
		short = who:gsub("%-.*$", "")
	end
	self:GuildSystem(guild, ERR_GUILD_JOIN_S:format(short))
end

local CLASS_LOCAL = { WARRIOR = "Воин", MAGE = "Маг", PRIEST = "Жрец", PALADIN = "Паладин", DRUID = "Друид", ROGUE = "Разбойник", HUNTER = "Охотник", WARLOCK = "Чернокнижник", SHAMAN = "Шаман" }

---------------------------------------------------------------------------
-- Клиент
---------------------------------------------------------------------------
local Client = {}
Client.__index = Client

local function Stamp(c)
	return c.first .. " " .. c.surname .. "-" .. c.realm
end

function World:FindByTell(name)
	for _, c in ipairs(self.clients) do
		if c.online and (c.first .. " " .. c.surname) == name then return c end
	end
	return nil
end

function World:Deliver(from, dist, prefix, msg, target, logged)
	local event = logged and "CHAT_MSG_ADDON_LOGGED" or "CHAT_MSG_ADDON"
	self.log[#self.log + 1] = { t = self.now, from = from.first .. " " .. from.surname, dist = dist, msg = msg, target = target }
	if dist == "GUILD" then
		local g = from.guild
		for _, c in ipairs(self.clients) do
			if c.online and c.guild == g then
				local stamp = Stamp(from)
				self:Schedule(self.now + 0.05, function() c:Fire(event, prefix, msg, "GUILD", stamp) end, c)
			end
		end
		return 0
	elseif dist == "WHISPER" then
		local to = self:FindByTell(target)
		if not to or (to.faction ~= from.faction) then
			self:Schedule(self.now + 0.05, function() from:Fire("CHAT_MSG_SYSTEM", NOT_FOUND:format(target)) end, from)
			return 0
		end
		local stamp = Stamp(from)
		self:Schedule(self.now + 0.05, function() to:Fire(event, prefix, msg, "WHISPER", stamp) end, to)
		return 0
	end
	return 4
end

-- Лимит сервера на аддон-сообщения GUILD, как на Forever: ведро на клиента и префикс — burst
-- сразу, затем rate в секунду; лишнее не доставляется и получает код 3 (AddonMessageThrottle).
-- Включается полем guildLimit мира или клиента: true — 10 сразу и 1 в секунду, либо таблица
-- { burst, rate }. По умолчанию выключен. Отказы клиента считает c.guildRefused.
function World:GuildRefused(c, prefix)
	local limit = c.guildLimit
	if limit == nil then limit = self.guildLimit end
	if not limit then return false end
	local burst = type(limit) == "table" and limit.burst or 10
	local rate = type(limit) == "table" and limit.rate or 1
	c.guildBuckets = c.guildBuckets or {}
	local b = c.guildBuckets[prefix]
	if not b then
		b = { n = burst, at = self.now }
		c.guildBuckets[prefix] = b
	end
	b.n = math.min(burst, b.n + (self.now - b.at) * rate)
	b.at = self.now
	if b.n < 1 then
		c.guildRefused = (c.guildRefused or 0) + 1
		return true
	end
	b.n = b.n - 1
	return false
end

-- Фильтр брани клиента: слова из c.profanity заменяются знаками прямо в тексте события, как
-- в игре (у владельца вернулось «#$%^&*!@а»). Длина замены другая, чем у слова.
local function Profane(c, msg)
	for _, word in ipairs(c.profanity or {}) do
		msg = msg:gsub(word:gsub("%p", "%%%0"), "#$%%^&*!@")
	end
	return msg
end

-- Строка в канал всем, кто в нём: (текст, автор, язык, «5. Название», …, номер, название,
-- язык, номер строки, GUID), как CHAT_MSG_CHANNEL в игре. channelDeaf — сервер держит
-- клиента вне канала, а клиент об этом не знает (бан без уведомления): строк он не получает.
function World:ChannelDeliver(stamp, guid, chan, msg)
	if self.channelClosed then return end
	self.lineId = self.lineId + 1
	local line = self.lineId
	for _, c in ipairs(self.clients) do
		if c.online and c.joined and c.joined[chan] and not c.channelDeaf then
			local cid, text = c.joined[chan], Profane(c, msg)
			self:Schedule(self.now + 0.05, function() c:Fire("CHAT_MSG_CHANNEL", text, stamp, "", cid .. ". " .. chan, "", "", 0, cid, chan, 0, line, guid) end, c)
		end
	end
end

-- Уведомление канала одному клиенту, как CHAT_MSG_CHANNEL_NOTICE в игре.
function World:NoticeTo(c, chan, notice)
	local cid = c.joined[chan] or 0
	self:Schedule(self.now + 0.05, function() c:Fire("CHAT_MSG_CHANNEL_NOTICE", notice, "", "", cid .. ". " .. chan, "", "", 0, cid, chan) end, c)
end

-- Текст клиента в канал. Без нажатия клавиши (таймер, обратный вызов) сервер его не принимает,
-- а игра шлёт ADDON_ACTION_BLOCKED. channelRefused — сервер молча не раздаёт строки этого
-- игрока («призрачное» членство); "throttled" — отвечает на каждую THROTTLED (так отвечают
-- забаненному). Сверх channelLimit строк за channelWindow — THROTTLED, в счёт не идёт.
function World:Say(from, msg, id)
	local chan = from.joinedById[id]
	if not chan then return end
	if not from.hardware then
		from.blocked = (from.blocked or 0) + 1
		from:Fire("ADDON_ACTION_BLOCKED", "Chillzone", "UNKNOWN()")
		return
	end
	if from.channelRefused == "throttled" then
		from.throttled = (from.throttled or 0) + 1
		self:NoticeTo(from, chan, "THROTTLED")
		return
	end
	local said = from.channelSaid or {}
	from.channelSaid = said
	while said[1] and self.now - said[1] >= self.channelWindow do table.remove(said, 1) end
	if #said >= self.channelLimit then
		from.throttled = (from.throttled or 0) + 1
		self:NoticeTo(from, chan, "THROTTLED")
		return
	end
	said[#said + 1] = self.now
	self.log[#self.log + 1] = { t = self.now, from = from.first .. " " .. from.surname, dist = "CHANNEL", msg = msg, chan = chan }
	if from.channelRefused then return end
	self:ChannelDeliver(Stamp(from), from:Guid(), chan, msg)
end

-- Игрок без аддона пишет в канал сам: full — «Имя Фамилия-Реалм».
function World:ChannelSay(full, chan, msg, class)
	local guid = "Player-" .. full:gsub("[%s%-]", "")
	self.guidClass[guid] = class or "WARRIOR"
	self.log[#self.log + 1] = { t = self.now, from = full, dist = "CHANNEL", msg = msg, chan = chan }
	self:ChannelDeliver(full, guid, chan, msg)
end

-- Уведомление канала всем, кто в нём: (вид, игрок, язык, «5. Название», второй игрок, …).
function World:ChannelNotice(chan, notice, player, player2)
	for _, c in ipairs(self.clients) do
		if c.online and c.joined and c.joined[chan] then
			local cid = c.joined[chan]
			self:Schedule(self.now + 0.05, function() c:Fire("CHAT_MSG_CHANNEL_NOTICE_USER", notice, player or "", "", cid .. ". " .. chan, player2 or "", "", 0, cid, chan) end, c)
		end
	end
end

-- Обычный чат гильдии и офицеров: сервер отдаёт строку всем в игре (и автору), офицерам — по рангу.
function World:GuildSay(from, msg, kind)
	local event = kind == "OFFICER" and "CHAT_MSG_OFFICER" or "CHAT_MSG_GUILD"
	self.log[#self.log + 1] = { t = self.now, from = from:Name(), dist = kind, msg = msg }
	for _, c in ipairs(self.clients) do
		if c.online and c.guild == from.guild and (kind ~= "OFFICER" or c.rank <= 1) then
			local stamp = Stamp(from)
			self:Schedule(self.now + 0.05, function() c:Fire(event, msg, stamp, "", "", stamp, "", 0, 0, "", 0, 1, from:Guid()) end, c)
		end
	end
end

function World:Whisper(from, msg, target)
	self.log[#self.log + 1] = { t = self.now, from = from:Name(), dist = "CHAT_WHISPER", msg = msg, target = target }
	local to = self:FindByTell(target)
	if not to then return end
	local stamp = Stamp(from)
	self:Schedule(self.now + 0.05, function() to:Fire("CHAT_MSG_WHISPER", msg, stamp) end, to)
end

-- Любое неизвестное поле кадра: и вызывается, и индексируется, ничего не делая.
local NOOP = setmetatable({}, { __call = function() return nil end })
getmetatable(NOOP).__index = function() return NOOP end

-- Кадр-заглушка. Show/Hide зовут OnShow/OnHide; поле ввода хранит текст и фокус;
-- ScrollingMessageFrame записывает строки в lines.
local function NewFrame(c, name)
	local f = { scripts = {}, shown = false, text = "", lines = {}, name = name }
	if name then c.named[name] = f end
	local methods = {}
	function methods.RegisterEvent(self, e)
		c.handlers[e] = c.handlers[e] or {}
		table.insert(c.handlers[e], self)
	end
	function methods.SetScript(self, k, fn) self.scripts[k] = fn end
	function methods.GetScript(self, k) return self.scripts[k] end
	function methods.GetVerticalScroll(self) return rawget(self, "verticalScroll") or 0 end
	function methods.SetVerticalScroll(self, offset)
		self.verticalScroll = offset
		if self.scripts.OnVerticalScroll then self.scripts.OnVerticalScroll(self, offset) end
	end
	function methods.GetFrameLevel(self) return rawget(self, "frameLevel") or 1 end
	function methods.SetFrameLevel(self, level) self.frameLevel = level end
	function methods.HookScript(self, k, fn)
		local original = self.scripts[k]
		self.scripts[k] = function(...)
			if original then original(...) end
			fn(...)
		end
	end
	function methods.IsShown(self) return self.shown end
	function methods.IsVisible(self) return self.shown end
	function methods.Show(self)
		if self.shown then return end
		self.shown = true
		if self.scripts.OnShow then self.scripts.OnShow(self) end
	end
	function methods.Hide(self)
		if not self.shown then return end
		self.shown = false
		if self.scripts.OnHide then self.scripts.OnHide(self) end
	end
	function methods.SetShown(self, on) if on then self:Show() else self:Hide() end end
	function methods.CreateFontString() return NewFrame(c) end
	function methods.CreateTexture() return NewFrame(c) end
	function methods.SetText(self, t) self.text = t or "" end
	function methods.SetTexture(self, t) self.texture = t end
	function methods.GetTexture(self) return rawget(self, "texture") end
	function methods.GetText(self) return self.text end
	function methods.GetStringHeight(self) return 14 * (1 + select(2, self.text:gsub("\n", ""))) end
	function methods.Click(self) if self.scripts.OnClick then self.scripts.OnClick(self) end end
	function methods.Insert(self, t) self.text = self.text .. (t or "") end
	function methods.SetFocus(self)
		local previous = c.focus
		c.focus = self
		if previous and previous ~= self and previous.scripts.OnEditFocusLost then
			previous.scripts.OnEditFocusLost(previous)
		end
	end
	function methods.ClearFocus(self)
		if c.focus ~= self then return end
		c.focus = nil
		if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
	end
	function methods.HasFocus(self) return c.focus == self end
	function methods.SetChecked(self, on) self.checked = on and true or false end
	function methods.GetChecked(self) return self.checked end
	function methods.SetEnabled(self, on) self.enabled = on and true or false end
	function methods.AddMessage(self, t, r, g, b)
		self.lines[#self.lines + 1] = t
		self.color = { r, g, b }
	end
	function methods.Clear(self) self.lines = {} end
	function methods.AtBottom() return true end
	return setmetatable(f, { __index = function(_, k) return methods[k] or NOOP end })
end

-- Окружение клиента: всё, к чему аддон обращается как к глобалам.
local function Env(c)
	local w = c.world
	local env = {}
	env._G = env
	env.UIParent = NewFrame(c, "UIParent")
	env.UIParent.GetEffectiveScale = function() return 1 end
	env.bit = require("bit")
	env.debugprofilestop = function() return os.clock() * 1000 end
	env.GetTime = function() return w.now end
	env.GetServerTime = function() return SERVER0 + math.floor(w.now) + (c.clockSkew or 0) end
	env.time = env.GetServerTime
	env.date = os.date
	env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	env.tinsert = table.insert
	env.C_Timer = {
		After = function(s, fn) w:Schedule(w.now + s, fn, c) end,
		NewTicker = function(s, fn)
			local h = { cancelled = false }
			function h.Cancel() h.cancelled = true end
			local function tick()
				if h.cancelled then return end
				fn()
				w:Schedule(w.now + s, tick, c)
			end
			w:Schedule(w.now + s, tick, c)
			return h
		end,
	}
	env.CreateFrame = function(_, name, _, template)
		local frame = NewFrame(c, name)
		if template == "ChatConfigCheckboxWithSwatchTemplate" then
			frame.CheckButton = NewFrame(c)
			frame.CheckButton.Text = NewFrame(c)
			frame.ColorSwatch = NewFrame(c)
			local texture = NewFrame(c)
			frame.ColorSwatch.GetNormalTexture = function() return texture end
		end
		return frame
	end
	env.GameTooltip = NewFrame(c, "GameTooltip")
	-- Группа игрока: c.party — остальные её участники (клиенты), c.raid — это рейд,
	-- c.partyLeader == false — лидер не я. Без c.party игрок один.
	env.UnitFullName = function(unit)
		if unit == "player" then return c.first, c.surname end
		local kind, index = tostring(unit):match("^(%a+)(%d+)$")
		local member = (kind == "party" or kind == "raid") and c.party and c.party[tonumber(index)]
		if member then return member.first, member.surname end
	end
	env.GetNumGroupMembers = function() return c.party and #c.party + 1 or 0 end
	env.IsInGroup = function() return c.party ~= nil end
	env.IsInRaid = function() return c.party ~= nil and c.raid == true end
	env.UnitIsGroupLeader = function() return c.party ~= nil and c.partyLeader ~= false end
	env.GetNormalizedRealmName = function() return c.realm end
	env.GetRealmName = function() return c.realm end
	-- Версия интерфейса: по умолчанию классическая, как у Forever; c.interface — другой клиент.
	env.GetBuildInfo = function() return "1.15.7", "60000", "Jan 1 2026", c.interface or 11507 end
	env.UnitFactionGroup = function() return c.faction end
	env.UnitClass = function() return CLASS_LOCAL[c.class], c.class end
	env.UnitLevel = function() return c.level end
	env.issecretvalue = function() return false end
	env.GetMaxPlayerLevel = function() return 60 end
	c.invites, c.partyInvites, c.whoQueries = {}, {}, {}
	env.InviteUnit = function(name) c.partyInvites[#c.partyInvites + 1] = name end
	env.IsMouseButtonDown = function(button) return c.mouseDown == button end
	env.GetCursorPosition = function() return 400, 300 end
	env.CanGuildInvite = function()
		if c.canInvite ~= nil then return c.canInvite end
		return c.guild ~= nil and c.rank <= 1
	end
	c.uninvites = {}
	env.CanGuildRemove = function()
		if c.canRemove ~= nil then return c.canRemove end
		return c.guild ~= nil and c.rank <= 1
	end
	-- Исключать и приглашать в гильдию Forever не даёт ни аддону, ни макросу: вызов записывается
	-- в c.forbidden и падает, как ADDON_ACTION_FORBIDDEN в игре. Команду игрок вводит сам —
	-- Client:GuildCommand; она и пишет c.invites и c.uninvites.
	c.forbidden = {}
	local function Forbidden(what)
		return function(name)
			c.forbidden[#c.forbidden + 1] = what .. " " .. tostring(name)
			error("ADDON_ACTION_FORBIDDEN " .. what)
		end
	end
	env.GuildInvite, env.GuildUninvite = Forbidden("GuildInvite"), Forbidden("GuildUninvite")
	env.C_FriendList = {
		SetWhoToUi = function(on) c.whoToUi = on end,
		SendWho = function(query)
			c.whoQueries[#c.whoQueries + 1] = query
			if c.whoTimeout then return end
			local rows = {}
			local Fold = c.ns.Util.Fold
			local token = query:match('g%-"([^"]+)"')
			-- Имя — строка в кавычках без префикса, как /who "Имя Фамилия" на Forever.
			local named = query:match('^"([^"]+)"$')
			local low, high = query:match(" (%d+)%-(%d+)$")
			for _, other in ipairs(w.clients) do
				if other.online and other.faction == c.faction and other.guild
					and c.ns.Util.GroupOf(other.realm) == c.ns.group
					and ((token and Fold(other.guild):find(Fold(token), 1, true))
						or (named and Fold(other.first .. " " .. other.surname):find(Fold(named), 1, true)))
					and (not low or (other.level >= tonumber(low) and other.level <= tonumber(high))) then
					rows[#rows + 1] = { fullName = Stamp(other), fullGuildName = other.guild, level = other.level, filename = other.class }
				end
			end
			-- whoRows: готовая выдача или функция (запрос, честная выдача) -> выдача.
			local results = rows
			if type(c.whoRows) == "function" then results = c.whoRows(query, rows) elseif c.whoRows then results = c.whoRows end
			w:Schedule(w.now + 0.1, function()
				c.whoResults = results
				c:Fire("WHO_LIST_UPDATE")
			end, c)
		end,
		GetNumWhoResults = function() return math.min(50, #(c.whoResults or {})), #(c.whoResults or {}) end,
		GetWhoInfo = function(i) return c.whoResults[i] end,
	}
	env.SendWho = function(query) return env.C_FriendList.SendWho(query) end
	env.GetNumWhoResults = function() return env.C_FriendList.GetNumWhoResults() end
	env.GetWhoInfo = function(i)
		local row = env.C_FriendList.GetWhoInfo(i)
		return row.fullName, row.fullGuildName, row.level, "Человек", CLASS_LOCAL[row.filename], c.zone, row.filename
	end
	env.IsInGuild = function() return c.guild ~= nil end
	env.GetGuildInfo = function()
		if not c.guild then return nil end
		local g = w.guilds[c.guild]
		return c.guild, g.ranks[c.rank + 1], c.rank
	end
	-- Строки ростера. c.hideOffline — в окне гильдии снят «Показать всех»: игра отдаёт только
	-- тех, кто в игре, а GetNumGuildMembers по-прежнему считает всех. all — все строки.
	local function Rows(all)
		local g = c.guild and w.guilds[c.guild]
		local rows = {}
		if not g then return rows end
		for _, o in ipairs(w.clients) do
			if o.guild == c.guild then
				rows[#rows + 1] = { full = Stamp(o), rank = o.rank, level = o.level, class = o.class, online = o.online, zone = o.zone, days = 0 }
			end
		end
		for _, m in ipairs(g.members) do
			rows[#rows + 1] = { full = m.full, rank = m.rank, level = m.level, class = m.class, online = m.online or false, days = m.days }
		end
		if c.hideOffline and not all then
			for i = #rows, 1, -1 do if not rows[i].online then table.remove(rows, i) end end
		end
		return rows
	end
	env.GetNumGuildMembers = function()
		local rows, on = Rows(true), 0
		for _, r in ipairs(rows) do if r.online then on = on + 1 end end
		return #rows, on, on
	end
	env.GetGuildRosterShowOffline = function() return not c.hideOffline end
	env.SetGuildRosterShowOffline = function(on) c.hideOffline = not on end
	-- Зажатый Ctrl: тест ставит c.ctrl перед нажатием клавиши в поле.
	env.IsControlKeyDown = function() return c.ctrl == true end
	env.GetGuildRosterInfo = function(i)
		local r = Rows()[i]
		if not r then return nil end
		local g = w.guilds[c.guild]
		return r.full, g.ranks[r.rank + 1], r.rank, r.level, CLASS_LOCAL[r.class], r.zone, "", "", r.online, 0, r.class
	end
	env.GetGuildRosterLastOnline = function(i)
		local r = Rows()[i]
		if not r or r.online then return nil end
		return 0, 0, math.floor(r.days or 0), 0
	end
	env.C_GuildInfo = {
		Invite = env.GuildInvite,
		Uninvite = env.GuildUninvite,
		GuildRoster = function() w:Schedule(w.now + 0.2, function() c:Fire("GUILD_ROSTER_UPDATE") end, c) end,
		-- Права звания rankOrder (с 1): таблица из 24 флагов, [22] — «офицер».
		GuildControlGetRankFlags = function(order)
			local g = c.guild and w.guilds[c.guild]
			assert(type(order) == "number" and order >= 1, "звания считаются с 1")
			local flags = {}
			for i = 1, 24 do flags[i] = false end
			if g and order <= #g.ranks then flags[22] = g.officers[order - 1] == true end
			return flags
		end,
	}
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function() return true end,
		SendAddonMessage = function(prefix, msg, dist, target)
			assert(#msg <= 255, "сообщение длиннее 255 байт")
			if dist == "GUILD" and w:GuildRefused(c, prefix) then return 3 end
			return w:Deliver(c, dist, prefix, msg, target, false)
		end,
		SendAddonMessageLogged = function(prefix, msg, dist, target)
			assert(#msg <= 255, "сообщение длиннее 255 байт")
			if dist == "GUILD" and w:GuildRefused(c, prefix) then return 3 end
			return w:Deliver(c, dist, prefix, msg, target, true)
		end,
		InChatMessagingLockdown = function() return c.lockdown == true end,
	}
	env.GetChannelName = function(id)
		if type(id) == "number" then
			for name, n in pairs(c.joined) do if n == id then return n, name end end
			return 0, nil
		end
		return c.joined[id] or 0, id
	end
	env.JoinChannelByName = function(name)
		-- Сервер держит игрока в канале, а клиент его потерял: вход отклоняется.
		if c.channelNotAllowed then
			w:Schedule(w.now + 0.1, function() c:Fire("CHAT_MSG_CHANNEL_NOTICE", "NOT_ALLOWED_IN_CHANNEL", "", "", "0. " .. name, "", "", 0, 0, name) end, c)
			return
		end
		c.joins = (c.joins or 0) + 1
		c.nextChan = (c.nextChan or 4) + 1
		local id = c.nextChan
		c.joined[name], c.joinedById[id] = id, name
		w:Schedule(w.now + 0.1, function() c:Fire("CHAT_MSG_CHANNEL_NOTICE", "YOU_JOINED", "", "", id .. ". " .. name, "", "", 0, id, name) end, c)
	end
	env.GetChannelList = function()
		local out = {}
		for id, name in pairs(c.joinedById) do out[#out + 1] = { id, name } end
		table.sort(out, function(a, b) return a[1] < b[1] end)
		local flat = {}
		for _, e in ipairs(out) do
			flat[#flat + 1], flat[#flat + 2], flat[#flat + 3] = e[1], e[2], c.channelDisabled == e[2]
		end
		return unpack(flat)
	end
	env.LeaveChannelByName = function(name)
		local id = c.joined[name]
		if id then c.joinedById[id] = nil end
		c.joined[name] = nil
	end
	env.SendChatMessage = function(msg, kind, _, id)
		assert(#msg <= 255, "строка чата длиннее 255 байт")
		if kind == "CHANNEL" then return w:Say(c, msg, id) end
		if kind == "GUILD" or kind == "OFFICER" then return w:GuildSay(c, msg, kind) end
		if kind == "WHISPER" then return w:Whisper(c, msg, id) end
		error("SendChatMessage: " .. tostring(kind))
	end
	env.GetPlayerInfoByGUID = function(guid)
		for _, o in ipairs(w.clients) do
			if o:Guid() == guid then return CLASS_LOCAL[o.class], o.class end
		end
		local class = w.guidClass[guid]
		if class then return CLASS_LOCAL[class], class end
	end
	env.hooksecurefunc = function(name, fn, callback)
		if type(name) == "table" then
			local original = name[fn]
			c.hooks[fn] = c.hooks[fn] or {}
			table.insert(c.hooks[fn], callback)
			name[fn] = function(...)
				local result = original(...)
				callback(...)
				return result
			end
			return
		end
		if name == "SendWho" or name == "SendChatMessage" then
			local original = env[name]
			env[name] = function(...)
				local result = original(...)
				fn(...)
				return result
			end
		end
		c.hooks[name] = c.hooks[name] or {}
		table.insert(c.hooks[name], fn)
	end
	env.debugstack = function() return "Interface\\AddOns\\OtherAddon\\Sender.lua:42: вызов" end
	env.GetBindingKey = function(action) if action == "OPENCHAT" then return "ENTER" end end
	env.ClearOverrideBindings = function(owner)
		for k, b in pairs(c.bindings) do if b.owner == owner then c.bindings[k] = nil end end
	end
	env.SetOverrideBindingClick = function(owner, _, key, button)
		assert(not c.combat, "привязка в бою")
		c.bindings[key] = { owner = owner, button = button }
	end
	env.InCombatLockdown = function() return c.combat == true end
	env.IsShiftKeyDown = function() return c.shift == true end
	env.ChatFrame_RemoveChannel = function() end
	local function AddChatFilter(event, fn)
		c.filters[event] = c.filters[event] or {}
		table.insert(c.filters[event], fn)
	end
	-- SendTell: шёпот в штатном поле чата игры; c.tells — кому открыт.
	c.tells = {}
	env.ChatFrameUtil = {
		InsertLink = function() return false end,
		SendTell = function(name) c.tells[#c.tells + 1] = name end,
	}
	if c.chatFilterAPI == "modern" then
		env.ChatFrameUtil.AddMessageEventFilter = AddChatFilter
	else
		env.ChatFrame_AddMessageEventFilter = AddChatFilter
	end
	env.ChatFrame1EditBox = NewFrame(c, "ChatFrame1EditBox")
	env.ChatFrame2EditBox = NewFrame(c, "ChatFrame2EditBox")
	env.DEFAULT_CHAT_FRAME = { editBox = env.ChatFrame1EditBox, AddMessage = function(_, text) c.printed[#c.printed + 1] = text end }
	-- Вкладки чата: 1 — основное окно, 2 — журнал боя; ещё вкладки заводит Client:ChatWindow.
	env.ChatFrame1 = env.DEFAULT_CHAT_FRAME
	env.ChatFrame2 = NewFrame(c, "ChatFrame2")
	env.COMBATLOG = env.ChatFrame2
	c.windows = { { name = "Общий", shown = true, docked = 1 }, { name = "Журнал боя", docked = 2 } }
	env.GetChatWindowInfo = function(i)
		local win = c.windows[i] or { name = "" }
		return win.name, 14, 1, 1, 1, 0, win.shown == true, false, win.docked
	end
	env.NUM_CHAT_WINDOWS = 10
	env.FCF_GetCurrentChatFrame = function() return c.currentChatFrame end
	c.createdWindows = {}
	env.FCF_GetNumActiveChatFrames = function()
		local count = 0
		for _, win in pairs(c.windows) do
			if win.shown or win.docked then count = count + 1 end
		end
		return count
	end
	env.FCF_CanOpenNewWindow = function()
		return env.FCF_GetNumActiveChatFrames() < env.NUM_CHAT_WINDOWS
	end
	env.FCF_OpenNewWindow = function(name, noDefaultChannels)
		assert(not c.combat, "создание вкладки в бою")
		c.createdWindows[#c.createdWindows + 1] = { name = name, noDefaultChannels = noDefaultChannels }
		for i = 3, env.NUM_CHAT_WINDOWS do
			local win = c.windows[i]
			if not win or not (win.shown or win.docked) then return c:ChatWindow(i, name), i end
		end
	end
	env.SlashCmdList = {}
	env.UISpecialFrames = {}
	env.RAID_CLASS_COLORS = {}
	env.CLASS_ICON_TCOORDS = { DRUID = { 0.74, 0.98, 0, 0.25 }, PALADIN = { 0, 0.25, 0.5, 0.75 } }
	env.ERR_CHAT_PLAYER_NOT_FOUND_S = "No player named '%s' is currently playing."
	-- Окно профессии (Crafters.lua): c.profession = { id, skill, max, recipes = { [номер] = изучен },
	-- linked — чужое окно по ссылке, npc — окно у НИП }. Client:OpenProfession открывает его.
	env.C_TradeSkillUI = {
		GetBaseProfessionInfo = function()
			local p = c.profession
			if not p then return { professionID = 0 } end
			return { professionID = p.id, professionName = "?", skillLevel = p.skill, maxSkillLevel = p.max }
		end,
		GetChildProfessionInfo = function()
			local p = c.profession
			return p and { skillLevel = p.skill, maxSkillLevel = p.max } or {}
		end,
		GetAllRecipeIDs = function()
			local out = {}
			for id in pairs(c.profession and c.profession.recipes or {}) do out[#out + 1] = id end
			table.sort(out)
			return out
		end,
		GetRecipeInfo = function(id)
			local p = c.profession
			local learned = p and p.recipes and p.recipes[id]
			local name = Wow.RECIPE_NAMES[id]
			if learned == nil and not name then return nil end
			return { recipeID = id, name = name, learned = learned == true, icon = Wow.RECIPES[id] and Wow.RECIPES[id].icon }
		end,
		GetRecipeOutputItemData = function(id)
			local r = Wow.RECIPES[id]
			return { itemID = r and r.item }
		end,
		GetRecipeSchematic = function(id)
			local slots = {}
			for _, x in ipairs(Wow.RECIPES[id] and Wow.RECIPES[id].reagents or {}) do
				slots[#slots + 1] = { reagents = { { itemID = x[1] } }, quantityRequired = x[2], required = not x[3] }
			end
			return { recipeID = id, reagentSlotSchematics = slots }
		end,
		IsTradeSkillLinked = function() return c.profession ~= nil and c.profession.linked == true end,
		IsTradeSkillGuild = function() return false end,
		IsTradeSkillGuildMember = function() return false end,
		IsNPCCrafting = function() return c.profession ~= nil and c.profession.npc == true end,
	}
	env.C_Spell = { GetSpellName = function(id) return Wow.RECIPE_NAMES[id] end }
	c.items = {} -- предметы, названия которых клиент уже догрузил
	c.itemLoads = 0
	local function ItemInfo(id)
		local name = c.items[id] and Wow.ITEM_NAMES[id]
		if not name then return nil end
		return name, "|Hitem:" .. id .. "|h[" .. name .. "]|h", 2, 20, Wow.ITEM_LEVEL[id] or 0, "Armor", "Mail", 1, "", 130000 + id, 100, 4, 3,
			Wow.ITEM_BIND[id] or 0
	end
	env.GetItemInfo = ItemInfo
	env.C_Item = {
		GetItemInfo = ItemInfo,
		GetItemNameByID = function(id) return c.items[id] and Wow.ITEM_NAMES[id] or nil end,
		GetItemIconByID = function(id) return Wow.ITEM_NAMES[id] and 130000 + id or nil end,
		RequestLoadItemDataByID = function(id)
			c.itemLoads = c.itemLoads + 1
			w:Schedule(w.now + 0.1, function()
				c.items[id] = true
				c:Fire("GET_ITEM_INFO_RECEIVED", id, Wow.ITEM_NAMES[id] ~= nil)
			end, c)
		end,
	}
	if c.noTradeSkill then env.C_TradeSkillUI = nil end
	env.ERR_GUILD_REMOVE_SS, env.ERR_GUILD_LEAVE_S, env.ERR_GUILD_JOIN_S = ERR_GUILD_REMOVE_SS, ERR_GUILD_LEAVE_S, ERR_GUILD_JOIN_S
	c.stubs = {}
	for k in pairs(env) do c.stubs[k] = true end
	return setmetatable(env, { __index = _G })
end

-- opts: first, surname, realm, faction, guild, rank, class, level, zone, config (поля Config
-- поверх Config.lua), chatFilterAPI ("modern" — только ChatFrameUtil, иначе старый API),
-- db (сохранения прежнего клиента), reload (перезагрузка интерфейса, а не вход персонажа),
-- version (номер аддона вместо Config.VERSION; по умолчанию world.version, если он задан, —
-- кроме клиентов 0.9).
function World:Client(opts)
	local version = opts.version or (not opts.legacy and self.version) or nil
	if version then
		local config = { VERSION = version }
		for k, v in pairs(opts.config or {}) do config[k] = v end
		opts = setmetatable({ config = config }, { __index = opts })
	end
	local c = setmetatable({
		world = self, first = opts.first, surname = opts.surname, realm = opts.realm or "CAMWOWUS2Realm7PvE",
		faction = opts.faction or "Alliance", guild = opts.guild, rank = opts.rank or 3, class = opts.class or "MAGE",
		level = opts.level or 60, zone = opts.zone or "Штормград", online = true, clockSkew = opts.clockSkew,
		chatFilterAPI = opts.chatFilterAPI, noTradeSkill = opts.noTradeSkill, interface = opts.interface,
		handlers = {}, filters = {}, printed = {}, joined = {}, joinedById = {},
		named = {}, hooks = {}, bindings = {},
	}, Client)
	c.env = Env(c)
	c.env.ChillzoneDB = opts.db
	c.ns = {}
	for _, f in ipairs(T.tocFiles()) do
		if (not f:find("^libs/") or f == "libs/Ed25519.lua")
			and not (opts.legacy and (f == "Issuers.lua" or f == "IssuerRevocations.lua" or f == "UnionAuthority.lua" or f == "TrustCatalog.lua" or f == "Online.lua" or f == "Pull.lua" or f == "Channel.lua" or f == "Groups.lua" or f == "Crafters.lua")) then
			if opts.legacy and (f == "Config.lua" or f == "Util.lua" or f == "Security.lua" or f == "Relay.lua" or f == "Census.lua") then
				local chunk = assert(loadfile(T.ROOT .. "/tests/legacy/0.9/" .. f))
				setfenv(chunk, c.env)("Chillzone", c.ns)
			else
				T.load({ f }, c.env, c.ns)
			end
			if f == "Config.lua" then
				for k, v in pairs(opts.config or {}) do c.ns.Config[k] = v end
			end
		end
	end
	self.clients[#self.clients + 1] = c
	c:Fire("ADDON_LOADED", "Chillzone")
	c:Fire("PLAYER_LOGIN")
	-- Клиент 0.9 читает настройку «делиться зонами»; у вышедших версий она включена, пока игрок её
	-- не выключил. Новый Core её больше не заводит.
	if opts.legacy and c.ns.char and c.ns.char.shareZones == nil then c.ns.char.shareZones = true end
	-- Вход персонажа или перезагрузка интерфейса (opts.reload).
	c:Fire("PLAYER_ENTERING_WORLD", not opts.reload, opts.reload == true)
	return c
end

function Client:Fire(event, ...)
	for _, f in ipairs(self.handlers[event] or {}) do
		local fn = f.scripts.OnEvent
		if fn then fn(f, event, ...) end
	end
end

function Client:Name()
	return self.first .. " " .. self.surname
end

-- Открыть окно профессии: p — { id, skill, max, recipes = { [номер] = изучен }, linked, npc }.
-- Аддон читает его через полсекунды после события: нужно World:Run.
function Client:OpenProfession(p)
	self.profession = p
	self:Fire("TRADE_SKILL_SHOW")
end

function Client:CloseProfession()
	self.profession = nil
	self:Fire("TRADE_SKILL_CLOSE")
end

function Client:Guid()
	return "Player-" .. self.first .. "-" .. self.surname
end

-- Вызвать пост-хуки, поставленные аддоном через hooksecurefunc(name, ...).
function Client:CallHooks(name, ...)
	for _, fn in ipairs(self.hooks[name] or {}) do fn(...) end
end

-- Нажатие клавиши: пока fn выполняется, сервер принимает текст в канал.
function Client:Hardware(fn, ...)
	local was = self.hardware
	self.hardware = true
	local ok, res = pcall(fn, ...)
	self.hardware = was
	if not ok then error(res, 0) end
	return res
end

-- Слэш-команда ищется, как в игре: по глобалам SLASH_<ключ><n>, которые завёл аддон.
-- Её выполняет Enter в игровом чате — это нажатие клавиши.
function Client:Slash(cmd, text)
	for key, fn in pairs(self.env.SlashCmdList) do
		local i = 1
		while rawget(self.env, "SLASH_" .. key .. i) do
			if rawget(self.env, "SLASH_" .. key .. i) == cmd then return self:Hardware(fn, text or "") end
			i = i + 1
		end
	end
	error("нет слэш-команды " .. cmd)
end

-- Команда гильдии, которую игрок ввёл в чате сам: "/gremove Имя Фамилия" или "/ginvite ...".
-- Без права игры команда молча ничего не делает, как в игре. Исключение проходит сразу, а
-- приглашённый вступает, когда примет приглашение (World:Join).
function Client:GuildCommand(text)
	local cmd, name = text:match("^(/%a+) (.+)$")
	if cmd == "/gremove" then
		if not self.env.CanGuildRemove() then return false end
		self.uninvites[#self.uninvites + 1] = name
		return self.world:Uninvite(self.guild, name, self)
	elseif cmd == "/ginvite" then
		if not self.env.CanGuildInvite() then return false end
		self.invites[#self.invites + 1] = name
		return true
	end
	error("неизвестная команда гильдии " .. tostring(text))
end

-- Enter в поле ввода (окно Chillzone, вкладка чата): нажатие клавиши.
function Client:Press(box)
	return self:Hardware(box.scripts.OnEnterPressed, box)
end

function Client:Logout()
	self.online = false
	for i, c in ipairs(self.world.clients) do
		if c == self then
			table.remove(self.world.clients, i)
			break
		end
	end
end

-- Вкладка чата игры номер i (3 и дальше) с названием name, пристыкованная к основному окну;
-- closed — вкладку закрыли, название у окна осталось. Строки вкладки — в lines возвращённого окна.
function Client:ChatWindow(i, name, closed)
	local key, env = "ChatFrame" .. i, self.env
	local f = rawget(env, key)
	if not f then
		f = NewFrame(self, key)
		env[key], self.stubs[key] = f, true
	end
	if i > env.NUM_CHAT_WINDOWS then env.NUM_CHAT_WINDOWS = i end
	self.windows[i] = { name = name, shown = not closed, docked = not closed and i or nil }
	return f
end

-- Строки, которые клиент вывел в чат и которые содержат text.
function Client:Saw(text)
	local n = 0
	for _, line in ipairs(self.printed) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

-- Глобалы, которые аддон создал сам (кроме разрешённых).
function Client:Leaks()
	local out = {}
	for k in pairs(self.env) do
		if not self.stubs[k] and k ~= "ChillzoneDB" and not tostring(k):find("^SLASH_CHILLZONE") then out[#out + 1] = tostring(k) end
	end
	table.sort(out)
	return out
end

-- Ранг name в guild, который подтверждает свежий сертификат (глава — 0), или nil.
function Wow.CertRank(ns, guild, name)
	local c = ns.Security.Member(guild, name)
	if c and ns.Security.Level(c) > 1 then return c.role == "leader" and 0 or c.rank end
	return nil
end

Wow.SERVER0 = SERVER0

-- Клиент прежней версии с выключенной настройкой «делиться зонами»: привет без флага зон, в
-- выборах репортёра себя считает не делящимся, отчёт без зон. Новые клиенты зонами делятся всегда,
-- а такой привет по-прежнему уступает выборы.
function Wow.ZonesOff(cl)
	local Codec = cl.ns.Codec
	local hello, pick, shareable = Codec.EncodeHello, Codec.PickReporter, Codec.Shareable
	Codec.EncodeHello = function(version, _, ...) return hello(version, false, ...) end
	Codec.PickReporter = function(me, _, ...) return pick(me, false, ...) end
	Codec.Shareable = function(r) return shareable(r, false) end
	cl.ns.Census.SendHello()
end

-- Номер вышедшей версии без помощников репортёра (Config.LAST_WITHOUT_HELPERS) и следующий за ним.
-- Номер аддона в ветке может совпадать с вышедшим: тогда помощников нет, и тестам помощников нужны
-- клиенты с номером выше (World.version или opts.version).
do
	local config = T.load({ "Config.lua" }).Config
	local head, tail = config.LAST_WITHOUT_HELPERS:match("^(.-)(%d+)$")
	Wow.RELEASED_VERSION = config.LAST_WITHOUT_HELPERS
	Wow.HELPER_VERSION = head .. (tonumber(tail) + 1)
end

return Wow
