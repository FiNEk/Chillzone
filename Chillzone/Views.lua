-- Chillzone: содержимое вкладок окна — список гильдий и карточка гильдии «Переписи», дерево
-- «Королевства» (строки { text, right, indent, tip(tooltip) }, их рисует UI.lua), шапка окна,
-- строки и люди чата, подсказки.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Views = {}
ns.Views = Views

local ICON_ON = "|TInterface\\FriendsFrame\\StatusIcon-Online:12|t"
local ICON_OFF = "|TInterface\\FriendsFrame\\StatusIcon-Offline:12|t"
local ICON_KING = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:14|t"
local ICON_OFFICER = "|TInterface\\GroupFrame\\UI-Group-AssistantIcon:12|t"
local GOLD, GREY, RED, WHITE = "|cffffd100", "|cff999999", "|cffff4040", "|cffffffff"
local GREEN = "|cff40ff40"
local ORANGE = "|cffff9933"

function Views.Ago(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds < 60 then return L.AGO_NOW end
	if seconds < 3600 then return L.AGO_MIN:format(math.floor(seconds / 60)) end
	if seconds < 86400 then return L.AGO_HOUR:format(math.floor(seconds / 3600)) end
	return L.AGO_DAY:format(math.floor(seconds / 86400))
end

-- Имя цветом класса (имена из чужих отчётов — только простой текст).
function Views.Name(name, class)
	name = Codec.Plain(name or "?")
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.colorStr then return "|c" .. color.colorStr .. name .. "|r" end
	return name
end

local function Dot(online)
	return online and ICON_ON or ICON_OFF
end

local function GuildLabel(s)
	local name = Codec.Plain(s.guild)
	if s.main then name = GOLD .. name .. "|r" end
	if s.mine then name = name .. " " .. GREY .. L.MINE_MARK .. "|r" end
	if s.conflict then name = name .. " " .. RED .. "!|r" end
	return name
end

---------------------------------------------------------------------------
-- Карточка гильдии на «Переписи» (CensusPane.lua рисует её справа от списка)
---------------------------------------------------------------------------
local function SortedMap(map)
	local list = {}
	for k, v in pairs(map or {}) do list[#list + 1] = { k = k, v = v } end
	table.sort(list, function(a, b)
		if a.v ~= b.v then return a.v > b.v end
		return tostring(a.k) < tostring(b.k)
	end)
	return list
end

-- «в игре», «не в игре меньше дня», «не в игре 3 дн.»
function Views.State(online, days)
	if online then return L.ONLINE end
	days = math.floor(days or 0)
	if days < 1 then return L.OFFLINE_TODAY end
	return L.OFFLINE_DAYS:format(days)
end

-- 13.5 → «13,5»: в русском дробная часть — через запятую.
function Views.Decimal(x)
	return (("%.1f"):format(tonumber(x) or 0):gsub("%.", ","))
end

local LEVEL_LABELS = { "1-9", "10-19", "20-29", "30-39", "40-49", "50-59", "60" }
local ZONES_SHOWN = 8

-- Всё, что знаем о гильдии s (строка Data.Summary), разложенное для карточки:
-- { guild, marks, updated, conflict, stats = { {value, label, green} x4 }, extra, people,
--   classes = { {class, name, count} }, classTotal, levels = { {label, count} x7 }, levelMax,
--   zones = { {name, count} }, zoneMax, zonesNote, staleNote }.
-- Классы, уровни и зоны — только из свежего отчёта (кто в игре сейчас).
function Views.GuildCard(s)
	local r = s.r
	local card = { guild = Codec.Plain(s.guild), main = s.main, mine = s.mine, conflict = s.conflict }
	local marks = {}
	if s.main then marks[#marks + 1] = L.CARD_MAIN end
	if s.mine then marks[#marks + 1] = L.CARD_MINE end
	card.marks = table.concat(marks, ", ")
	card.updated = s.mine and L.TIP_FROM_ROSTER or L.TIP_UPDATED:format(Views.Ago(s.age))
	local officers = #(r.officers or {})
	card.stats = {
		{ value = s.total and U.Num(s.total) or "?", label = U.Plural(s.total or 0, L.HEAD_MEMBER_1, L.HEAD_MEMBER_2, L.HEAD_MEMBER_5) },
		{ value = s.online and U.Num(s.online) or "?", label = L.CARD_ONLINE, green = s.online ~= nil },
		{ value = U.Num(officers), label = U.Plural(officers, L.CARD_OFFICER_1, L.CARD_OFFICER_2, L.CARD_OFFICER_5) },
		{ value = Views.Decimal(r.avgLevel), label = L.CARD_AVG },
	}
	card.extra = L.CARD_EXTRA:format(r.users or 0, r.inactive7 or 0, r.inactive30 or 0)
	card.people = {}
	local function person(p, role)
		card.people[#card.people + 1] = {
			name = p.name, class = p.class, level = p.level, days = p.days, role = role,
			online = (s.fresh and p.online) and true or false, guild = s.guild, main = s.main,
		}
	end
	if r.leader then
		person({ name = r.leader, class = r.leaderClass, level = r.leaderLevel, online = r.leaderOnline, days = r.leaderDays }, "leader")
	end
	for _, o in ipairs(r.officers or {}) do person(o, "officer") end
	if s.fresh then
		card.classes, card.classTotal = {}, 0
		for _, e in ipairs(SortedMap(r.classes)) do
			card.classes[#card.classes + 1] = { class = e.k, name = L.CLASS[e.k] or tostring(e.k), count = e.v }
			card.classTotal = card.classTotal + e.v
		end
		card.levels, card.levelMax = {}, 0
		for i, label in ipairs(LEVEL_LABELS) do
			local n = (r.levels or {})[i] or 0
			card.levels[i] = { label = label, count = n }
			if n > card.levelMax then card.levelMax = n end
		end
		card.zones, card.zoneMax = {}, 0
		for i, e in ipairs(SortedMap(r.zones)) do
			if i > ZONES_SHOWN then break end
			card.zones[i] = { name = ns.Zones.NameForKey(e.k), count = e.v }
			if e.v > card.zoneMax then card.zoneMax = e.v end
		end
		if #card.zones == 0 then card.zonesNote = s.mine and L.CARD_NO_ZONES or L.TIP_NO_ZONES end
	else
		card.staleNote = L.CARD_STALE
	end
	card.onlineGroup = Views.OnlineGroup(s, L.ONLINE_HEAD)
	return card
end

-- Заголовок окна: «Chillzone», а если вышла версия новее (Update.Available) — с просьбой обновиться.
function Views.Title()
	local v = ns.Update.Available()
	if not v then return "Chillzone" end
	return "Chillzone " .. ORANGE .. "(" .. L.UPDATE_TITLE:format(v) .. ")|r"
end

---------------------------------------------------------------------------
-- Вкладка «Перепись»
---------------------------------------------------------------------------
-- Шапка окна, как у Olympus: крупно — сколько всего участников во всех гильдиях «Чиллзон»,
-- мелко — сколько в игре, сколько гильдий и когда пришёл самый свежий отчёт.
-- { big, small, guilds, total, online, newest (возраст в секундах) }.
function Views.Status(now)
	now = now or ns.ServerTime()
	local st = { guilds = 0, total = 0, online = 0 }
	for _, s in ipairs(ns.Data.Summary(now)) do
		if s.recent then
			st.guilds = st.guilds + 1
			st.total = st.total + (s.total or 0)
			st.online = st.online + (s.online or 0)
			if not st.newest or s.age < st.newest then st.newest = s.age end
		end
	end
	if st.guilds == 0 then
		st.big, st.small = L.HEAD_WAIT, L.HEAD_WAIT_SUB
		return st
	end
	st.big = U.Num(st.total) .. " " .. U.Plural(st.total, L.HEAD_MEMBER_1, L.HEAD_MEMBER_2, L.HEAD_MEMBER_5)
	st.small = L.HEAD_SUB:format(
		GREEN .. U.Num(st.online) .. "|r",
		WHITE .. st.guilds .. "|r " .. U.Plural(st.guilds, L.HEAD_GUILD_1, L.HEAD_GUILD_2, L.HEAD_GUILD_5),
		Views.Ago(st.newest))
	return st
end

-- Подсказка шапки: по гильдиям, сколько в игре из скольких.
function Views.StatusTip(tt, now)
	now = now or ns.ServerTime()
	local st = Views.Status(now)
	tt:AddLine(st.big, 1, 0.82, 0)
	tt:AddLine(st.small, 0.7, 0.7, 0.7)
	local list = ns.Data.Summary(now)
	if #list > 0 then tt:AddLine(" ") end
	for _, s in ipairs(list) do
		if s.recent then
			local name = Codec.Plain(s.guild) .. (s.mine and (" " .. L.MINE_MARK) or "")
			local online = s.online and (GREEN .. U.Num(s.online) .. "|r") or (GREY .. "?|r")
			local r, g, b = 1, 1, 1
			if s.main then r, g, b = 1, 0.82, 0 end
			tt:AddDoubleLine(name, online .. GREY .. " / |r" .. U.Num(s.total or 0), r, g, b, 1, 1, 1)
		end
	end
	tt:AddLine(" ")
	tt:AddLine(L.HEAD_TIP_MORE, 0.6, 0.6, 0.6)
end

---------------------------------------------------------------------------
-- Что идёт сейчас: строка внизу окна и подсказки к ней и к кнопке обновления.
---------------------------------------------------------------------------
local HOLD_LAST = 1 -- столько держим последнюю строку, чтобы короткие очереди не мигали
local lastActivity

-- { text, kind } или nil, если показывать нечего. kind: block, wait, work, done, fail.
function Views.Activity(now)
	now = now or ns.Now()
	local list = ns.Activity.List()
	local top = list[1]
	if top then
		local text = top.text
		if #list > 1 then text = L.ACT_MORE:format(text, #list - 1) end
		lastActivity = { text = text, kind = top.kind, at = now }
		return lastActivity
	end
	local note = ns.Activity.LastNote()
	if note then
		lastActivity = nil
		return note
	end
	if lastActivity and now - lastActivity.at < HOLD_LAST then return lastActivity end
	lastActivity = nil
	return nil
end

-- Насколько свежи данные: общий хвост обеих подсказок.
local function Freshness(tt, now)
	local scanned = ns.Roster.scannedAt
	tt:AddLine(L.ACT_TIP_ROSTER:format(scanned and Views.Ago(now - scanned) or L.ACT_TIP_NEVER), 0.7, 0.7, 0.7)
	if not ns.IsMember() then return end
	local newest = Views.Status().newest
	tt:AddLine(L.ACT_TIP_CENSUS:format(newest and Views.Ago(newest) or L.ACT_TIP_NEVER), 0.7, 0.7, 0.7)
	local ok, list = 0, ns.Relay.Candidates()
	for _, e in ipairs(list) do
		local _, code = ns.Relay.StateOf(e, now)
		if code == "ok" then ok = ok + 1 end
	end
	tt:AddLine(L.ACT_TIP_RELAYS:format(ok, #list), 0.7, 0.7, 0.7)
end

local ACTIVITY_COLOR = { block = { 1, 0.35, 0.35 }, wait = { 1, 0.82, 0 }, work = { 1, 0.82, 0 } }

function Views.ActivityTip(tt, now)
	now = now or ns.Now()
	local list = ns.Activity.List()
	if #list == 0 then tt:AddLine(L.ACT_TIP_IDLE, 1, 1, 1) end
	for _, row in ipairs(list) do
		local c = ACTIVITY_COLOR[row.kind] or ACTIVITY_COLOR.wait
		tt:AddLine(row.text, c[1], c[2], c[3])
		if row.detail then tt:AddLine(row.detail, 0.8, 0.8, 0.8, true) end
	end
	tt:AddLine(" ")
	Freshness(tt, now)
end

function Views.RefreshTip(tt, now)
	now = now or ns.Now()
	tt:AddLine(L.REFRESH, 1, 1, 1)
	tt:AddLine(L.REFRESH_TIP, 0.8, 0.8, 0.8, true)
	local wait = ns.Refresh.Wait()
	if wait > 0 then tt:AddLine(L.REFRESH_TIP_WAIT:format(math.ceil(wait)), 1, 0.82, 0) end
	local reports = ns.IsMember() and ns.Census.RefreshWait() or 0
	if reports > 0 then tt:AddLine(L.REFRESH_TIP_REPORTS:format(math.ceil(reports)), 1, 0.82, 0) end
	tt:AddLine(" ")
	Freshness(tt, now)
end

-- Список гильдий слева на «Переписи»: { key, s, text, right, sub }. Подробности — Views.GuildCard.
function Views.CensusRows(now)
	local out = {}
	for _, s in ipairs(ns.Data.Summary(now)) do
		local right
		if s.recent then
			right = (s.online and (GREEN .. U.Num(s.online) .. "|r") or (GREY .. "?|r")) .. GREY .. " / |r" .. U.Num(s.total or 0)
		else
			right = GREY .. L.CENSUS_OLD:format(Views.Ago(s.age)) .. "|r"
		end
		local leader = s.r.leader and (Dot(s.fresh and s.r.leaderOnline) .. Views.Name(s.r.leader, s.r.leaderClass)) or GREY .. "—|r"
		out[#out + 1] = {
			key = U.GuildKey(s.guild), s = s, text = GuildLabel(s), right = right,
			sub = GREY .. L.CENSUS_LEADER .. "|r " .. leader,
		}
	end
	return out
end

---------------------------------------------------------------------------
-- Вкладка «Королевство»
---------------------------------------------------------------------------
local function PersonTip(p, role, guild)
	return function(tt)
		tt:AddLine(Views.Name(p.name, p.class))
		tt:AddLine(role .. ", " .. Codec.Plain(guild), 0.8, 0.8, 0.8)
		if p.level and p.level > 0 then tt:AddLine(L.TIP_LEVEL:format(p.level), 0.8, 0.8, 0.8) end
		tt:AddLine(Views.State(p.online, p.days), 0.6, 0.6, 0.6)
	end
end

local function Captains(lines, node, indent)
	for _, c in ipairs(node.captains) do
		lines[#lines + 1] = {
			text = ICON_OFFICER .. " " .. Dot(c.online) .. Views.Name(c.name, c.class),
			right = GREY .. L.ROLE_CAPTAIN .. "|r", indent = indent,
			tip = PersonTip(c, L.ROLE_CAPTAIN, node.guild),
		}
	end
end

function Views.Kingdom()
	local lines = {}
	local tree = ns.Data.Kingdom()
	lines[#lines + 1] = { text = GOLD .. L.KINGDOM_KING .. "|r", header = true }
	local king = tree.king
	if king then
		lines[#lines + 1] = {
			text = ICON_KING .. " " .. Dot(king.leaderOnline) .. Views.Name(king.leader, king.leaderClass) .. "  " .. GREY .. "<" .. Codec.Plain(king.guild) .. ">|r" .. (king.conflict and (" " .. RED .. "!|r") or ""),
			right = GOLD .. L.ROLE_KING .. "|r",
			tip = PersonTip({ name = king.leader, class = king.leaderClass, level = king.leaderLevel, online = king.leaderOnline, days = king.leaderDays }, L.ROLE_KING, king.guild),
		}
		Captains(lines, king, 1)
	else
		lines[#lines + 1] = { text = GREY .. L.KINGDOM_NO_KING:format(C.MAIN_GUILD) .. "|r", wrap = true }
	end
	local lords = 0
	for _, node in ipairs(tree.guilds) do
		if not node.main then
			if lords == 0 then lines[#lines + 1] = { text = GOLD .. L.KINGDOM_LORDS .. "|r", header = true, gap = true } end
			lords = lords + 1
			local lord = node.leader and (Dot(node.leaderOnline) .. Views.Name(node.leader, node.leaderClass)) or (GREY .. "—|r")
			lines[#lines + 1] = {
				text = lord .. "  " .. GREY .. "<" .. Codec.Plain(node.guild) .. ">|r" .. (node.conflict and (" " .. RED .. "!|r") or ""),
				right = GREY .. L.ROLE_LORD .. "|r",
				tip = node.leader and PersonTip({ name = node.leader, class = node.leaderClass, level = node.leaderLevel, online = node.leaderOnline, days = node.leaderDays }, L.ROLE_LORD, node.guild) or nil,
			}
			Captains(lines, node, 1)
		end
	end
	if lords == 0 then
		lines[#lines + 1] = { text = GOLD .. L.KINGDOM_LORDS .. "|r", header = true, gap = true }
		lines[#lines + 1] = { text = GREY .. L.KINGDOM_NO_LORDS .. "|r", wrap = true }
	end
	return lines
end

---------------------------------------------------------------------------
-- Окно чата: строки сообщений и список людей справа
---------------------------------------------------------------------------
local ACTIVE_WINDOW = 3600 -- «писал за последний час»
local ROLE_ORDER = { leader = 0, officer = 1, member = 2, active = 3 }

-- Строка канала для окна: [время] [Имя] <Гильдия>: текст. Имя — ссылка player.
-- Гильдия автора строки из канала игры может быть не подтверждена (e.g пусто): серое <?>.
function Views.ChatLine(e, channel, showTime)
	local link = "|Hplayer:" .. (U.TellName(e.s) or "?") .. "|h[" .. Views.Name(e.s, e.c) .. "]|h"
	local guild = ""
	if not ns.Chat.GUILD_CHANNELS[channel] then guild = " " .. GREY .. "<" .. (e.g and ns.Chat.GuildTag(e.g) or "?") .. ">|r" end
	local stamp = (showTime and date) and (GREY .. date("%H:%M", e.t or 0) .. "|r ") or ""
	return stamp .. link .. guild .. ": " .. Codec.SanitizeChat(e.x)
end

local function ByRole(a, b)
	if ROLE_ORDER[a.role] ~= ROLE_ORDER[b.role] then return ROLE_ORDER[a.role] < ROLE_ORDER[b.role] end
	if a.role == "active" then return (a.wrote or 0) > (b.wrote or 0) end
	if (a.online and 1 or 0) ~= (b.online and 1 or 0) then return a.online and true or false end
	if (a.rank or 9) ~= (b.rank or 9) then return (a.rank or 9) < (b.rank or 9) end
	return a.name < b.name
end

-- Аддон у согильдийца по приветам H1 (Census.Addon). «Нет» — только про того, кто в игре:
-- от вышедшего привета и не должно быть.
local function GuildAddon(key, online)
	local has, version = ns.Census.Addon(key)
	if has == false and not online then has = nil end
	return has, version
end

-- Кто из других гильдий точно с аддоном: писал в общие каналы подписанной строкой или прислал
-- отчёт переписи. Строку из канала игры (e.ch) может написать и игрок без аддона.
-- Остальных не знаем: приветы H1 ходят только внутри гильдии.
local function AddonKnown(summary)
	local known = {}
	for tier in pairs(ns.Chat.TIER_LEVEL) do
		for _, e in ipairs(ns.Chat.History(tier)) do
			local k = not e.ch and U.Key(e.s)
			if k then known[k] = true end
		end
	end
	for _, s in ipairs(summary) do
		local k = U.Key(s.origin)
		if k then known[k] = true end
	end
	return known
end

-- Своя гильдия по ростеру: в G — кто в игре, в O — офицеры (в игре первыми).
local function GuildPeople(channel)
	local list = {}
	for _, m in ipairs(ns.Roster.members or {}) do
		local rank = m.rank or 9
		local officer = ns.Roster.IsOfficerRank(rank)
		if (channel == "G" and m.online) or (channel == "O" and officer) then
			local addon, version = GuildAddon(m.key, m.online)
			list[#list + 1] = {
				name = U.Display(m.name), class = m.class, level = m.level, online = m.online, days = m.days,
				rank = rank, rankName = m.rankName, zone = m.zone, guild = ns.Roster.guild,
				role = rank == 0 and "leader" or (officer and "officer" or "member"),
				addon = addon, version = version,
			}
		end
	end
	table.sort(list, function(a, b)
		if (a.online and 1 or 0) ~= (b.online and 1 or 0) then return a.online and true or false end
		if a.rank ~= b.rank then return a.rank < b.rank end
		return a.name < b.name
	end)
	return list
end

-- Люди канала для правой панели: { header = true, guild, main, count } и строки людей
-- { name, class, level, online, days, role, guild, wrote, addon, version }. Второе значение —
-- сколько в сети. addon: true — аддон есть, false — нет, nil — неизвестно.
-- Уровни «Чиллзон»: главы и офицеры гильдий из переписи (в «Главах» — только главы и офицеры
-- главной гильдии) плюс те, кто писал в канал за последний час. Авторы строк из канала игры,
-- чья гильдия не подтверждена, — последней группой { unconfirmed = true }.
function Views.People(channel, now)
	now = now or ns.ServerTime()
	local out, online = {}, 0
	local function add(p)
		out[#out + 1] = p
		if p.online then online = online + 1 end
	end
	if ns.Chat.GUILD_CHANNELS[channel] then
		for _, p in ipairs(GuildPeople(channel)) do add(p) end
		return out, online
	end
	local level = ns.Chat.TIER_LEVEL[channel] or 1
	local active, seen = {}, {}
	for _, e in ipairs(ns.Chat.History(channel)) do
		local k = U.Key(e.s)
		if k and now - (e.t or 0) <= ACTIVE_WINDOW then active[k] = e end
	end
	local groups, order = {}, {}
	local function group(guild, main)
		local gk = U.GuildKey(guild) or "?"
		if not groups[gk] then
			groups[gk] = { guild = guild, main = main, people = {} }
			order[#order + 1] = gk
		end
		return groups[gk]
	end
	local unconfirmed = { unconfirmed = true, people = {} }
	local summary = ns.Data.Summary(now)
	local known, mine = AddonKnown(summary), U.GuildKey(ns.MyGuild())
	local function addon(k, guild, inGame)
		if mine and U.GuildKey(guild) == mine then
			local has, version = GuildAddon(k, inGame)
			if has ~= nil then return has, version end
		end
		return known[k] or nil
	end
	for _, s in ipairs(summary) do
		if s.recent then
			local g = group(s.guild, s.main)
			local r = s.r
			local function person(p, role)
				local k = U.Key(p.name)
				if not k or seen[k] then return end
				seen[k] = true
				local on = (s.fresh and p.online) and true or false
				local has, version = addon(k, s.guild, on)
				g.people[#g.people + 1] = {
					name = p.name, class = p.class, level = p.level, online = on,
					days = p.days, role = role, rank = p.rank, guild = s.guild, main = s.main, wrote = active[k] and active[k].t,
					addon = has, version = version,
				}
			end
			if r.leader then person({ name = r.leader, class = r.leaderClass, level = r.leaderLevel, online = r.leaderOnline, days = r.leaderDays, rank = 0 }, "leader") end
			if level < 3 or s.main then
				for _, o in ipairs(r.officers or {}) do person(o, "officer") end
			end
		end
	end
	for k, e in pairs(active) do
		if not seen[k] then
			seen[k] = true
			local g = e.g and group(e.g, U.IsMainGuild(e.g)) or unconfirmed
			local on = now - (e.t or 0) <= C.FRESH
			local has, version = addon(k, e.g, on)
			g.people[#g.people + 1] = { name = e.s, class = e.c, online = on, role = "active", guild = e.g, wrote = e.t, addon = has, version = version }
		end
	end
	order[#order + 1] = "?unconfirmed"
	groups["?unconfirmed"] = unconfirmed
	for _, gk in ipairs(order) do
		local g = groups[gk]
		if #g.people > 0 then
			table.sort(g.people, ByRole)
			out[#out + 1] = { header = true, guild = g.guild, main = g.main, unconfirmed = g.unconfirmed, count = #g.people }
			for _, p in ipairs(g.people) do add(p) end
		end
	end
	return out, online
end

---------------------------------------------------------------------------
-- Поимённый онлайн на «Переписи»: своя гильдия — из ростера, чужие — запросом (Online.lua)
---------------------------------------------------------------------------
local function OnlineNote(state)
	if state.at then return L.TIP_UPDATED:format(Views.Ago(ns.Now() - state.at)) end
	if state.loading then
		return state.n and L.ONLINE_PROGRESS:format(state.got, state.n) or L.ONLINE_LOADING
	end
	return state.failed and L.ONLINE_NO_ANSWER or L.ONLINE_UNAVAILABLE
end

-- Кто в игре в гильдии s (строка Data.Summary): { title, people, mine, loading, missing };
-- label — начало заголовка. loading — список ещё идёт, missing — его нет и никто его не несёт.
-- known — результат AddonKnown: общему виду незачем собирать его заново для каждой гильдии.
function Views.OnlineGroup(s, label, known)
	local people, note, loading, missing
	if s.mine then
		people, note = GuildPeople("G"), L.TIP_FROM_ROSTER
	else
		local state = ns.Online.Get(s.guild)
		people, note = {}, OnlineNote(state)
		loading, missing = state.loading, not state.at and not state.loading
		local roles = {}
		local r = s.r or {}
		if r.leader then roles[U.Key(r.leader)] = "leader" end
		for _, o in ipairs(r.officers or {}) do roles[U.Key(o.name)] = "officer" end
		known = known or AddonKnown(ns.Data.Summary())
		for _, p in ipairs(state.people) do
			local k = U.Key(p.name)
			people[#people + 1] = {
				name = p.name, class = p.class, level = p.level, online = true, days = 0,
				role = roles[k] or "member", guild = s.guild, main = s.main,
				addon = (p.addon or known[k]) and true or nil,
			}
		end
	end
	local count = #people > 0 and (" " .. GREY .. "(" .. U.Num(#people) .. ")|r") or ""
	return {
		people = people, title = label .. count .. "  " .. GREY .. note .. "|r",
		mine = s.mine, loading = loading, missing = missing,
	}
end

-- Все гильдии со свежим отчётом в одной таблице: { people, known — сколько в списке,
-- online — по отчётам, status — чьих списков пока нет, "" если все пришли }.
function Views.AllOnline(now)
	local out = { people = {}, known = 0, online = 0 }
	local loading, missing = {}, {}
	local summary = ns.Data.Summary(now)
	local known = AddonKnown(summary)
	for _, s in ipairs(summary) do
		if s.fresh then
			local group = Views.OnlineGroup(s, "", known)
			for _, p in ipairs(group.people) do out.people[#out.people + 1] = p end
			out.online = out.online + (s.online or 0)
			local absent = group.loading and loading or (group.missing and missing)
			if absent then absent[#absent + 1] = Codec.Plain(s.guild) end
		end
	end
	out.known = #out.people
	local parts = {}
	if #loading > 0 then parts[#parts + 1] = L.ONLINE_ALL_LOADING:format(table.concat(loading, ", ")) end
	if #missing > 0 then parts[#parts + 1] = L.ONLINE_ALL_MISSING:format(table.concat(missing, ", ")) end
	out.status = table.concat(parts, ". ")
	return out
end

-- Чем сравнивать людей в таблице «кто в игре», по ключам колонок.
local ONLINE_SORT = {
	level = function(p) return p.level or 0 end,
	class = function(p) return p.class and L.CLASS[p.class] or "" end,
	name = function(p) return U.Key(p.name) or "" end,
	guild = function(p) return U.GuildKey(p.guild) or "" end,
	zone = function(p) return p.zone and U.Fold(p.zone) or "" end,
	rank = function(p) return (ROLE_ORDER[p.role] or 9) * 100 + (p.rank or 99) end,
	addon = function(p) return p.addon == true and 1 or 0 end,
}

-- Сортирует people на месте. При равенстве — по имени и всегда по возрастанию.
-- Значения считаются один раз: свёртка регистра кириллицы в сравнении обошлась бы дорого.
function Views.SortOnline(people, key, desc)
	local value = ONLINE_SORT[key] or ONLINE_SORT.level
	for _, p in ipairs(people) do
		p.sortValue, p.sortName = value(p), U.Key(p.name) or ""
	end
	table.sort(people, function(a, b)
		if a.sortValue ~= b.sortValue then
			if desc then return a.sortValue > b.sortValue end
			return a.sortValue < b.sortValue
		end
		return a.sortName < b.sortName
	end)
end

-- Подписи ячеек таблицы по ключам колонок. Класс таблица рисует значком.
function Views.OnlineCells(p)
	local crown = p.role == "leader" and (" " .. ICON_KING) or (p.role == "officer" and (" " .. ICON_OFFICER) or "")
	return {
		level = (p.level and p.level > 0) and tostring(p.level) or "",
		name = Views.Name(p.name, p.class) .. crown,
		guild = Codec.Plain(p.guild or "?"),
		zone = p.zone and Codec.Plain(p.zone) or "",
		rank = Views.Role(p),
	}
end

-- Строка «Все гильдии» над списком на «Переписи»: { text, right }.
function Views.AllOnlineRow(now)
	return { text = L.ONLINE_ALL, right = GREEN .. U.Num(Views.Status(now).online) .. "|r" }
end

-- Подпись роли человека в списке справа.
function Views.Role(p)
	if p.role == "active" then return L.ROLE_ACTIVE end
	if p.rankName then return Codec.Plain(p.rankName) end -- своя гильдия: ранг из ростера
	if p.role == "leader" then return p.main and L.ROLE_KING or L.ROLE_LORD end
	if p.role == "officer" then return L.ROLE_CAPTAIN end
	return ""
end

function Views.PersonTip(tt, p)
	tt:AddLine(Views.Name(p.name, p.class))
	local role = Views.Role(p)
	local guild = p.guild and Codec.Plain(p.guild) or L.CHAT_UNCONFIRMED_GROUP
	tt:AddLine((role ~= "" and (role .. ", ") or "") .. guild, 0.8, 0.8, 0.8)
	if p.level and p.level > 0 then
		tt:AddLine(L.TIP_LEVEL:format(p.level) .. (p.class and L.CLASS[p.class] and (", " .. L.CLASS[p.class]) or ""), 0.8, 0.8, 0.8)
	end
	if p.zone and p.online then tt:AddLine(Codec.Plain(p.zone), 0.8, 0.8, 0.8) end
	if p.role ~= "active" then tt:AddLine(Views.State(p.online, p.days), 0.6, 0.6, 0.6) end
	if p.wrote then tt:AddLine(L.TIP_WROTE:format(Views.Ago(ns.ServerTime() - p.wrote)), 0.6, 0.6, 0.6) end
	if p.addon then
		tt:AddLine(Views.AddonText(p), 0.25, 1, 0.25)
	else
		tt:AddLine(Views.AddonText(p), 0.6, 0.6, 0.6)
	end
	tt:AddLine(L.TIP_MENU, 0.5, 0.83, 0.76)
end

-- Приглашать в группу можно того, кто сейчас в игре, и не себя.
function Views.CanInvite(p)
	return p.online == true and not ns.IsMe(p.name)
end

-- Строка подсказки про аддон у человека из списка: есть (с версией, если знаем), нет, неизвестно.
function Views.AddonText(p)
	if p.addon then
		local version = Codec.Plain(p.version)
		if version ~= "" then return L.TIP_ADDON_VERSION:format(version) end
		return L.TIP_ADDON_YES
	end
	if p.addon == false then return L.TIP_ADDON_NO end
	return L.TIP_ADDON_UNKNOWN
end

---------------------------------------------------------------------------
-- Кнопка у миникарты: подсказка
---------------------------------------------------------------------------
function Views.MinimapTip(tt)
	local status = Views.Status()
	tt:AddLine("Chillzone", 0.5, 0.83, 0.76)
	tt:AddLine(status.big, 1, 0.82, 0)
	tt:AddLine(status.small, 0.7, 0.7, 0.7)
	local tree = ns.Data.Kingdom()
	if tree.king then tt:AddLine(L.ROLE_KING .. ": " .. Views.Name(tree.king.leader, tree.king.leaderClass), 1, 0.82, 0) end
	tt:AddLine(" ")
	tt:AddLine(L.MINIMAP_LEFT, 0.6, 0.6, 0.6)
	tt:AddLine(L.MINIMAP_RIGHT, 0.6, 0.6, 0.6)
	tt:AddLine(L.MINIMAP_DRAG, 0.6, 0.6, 0.6)
end

---------------------------------------------------------------------------
-- Вкладка «Группы»: строки доски, подсказки, причины отказа
---------------------------------------------------------------------------
-- Значки ролей — обычные значки умений из самой первой версии игры: они есть в любом клиенте.
Views.ROLE_ICON = {
	t = "Interface\\Icons\\Ability_Defend",
	h = "Interface\\Icons\\Spell_Holy_Heal",
	d = "Interface\\Icons\\Ability_DualWield",
}

function Views.RoleIcon(role, size)
	size = size or 14
	return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(Views.ROLE_ICON[role] or Views.ROLE_ICON.d, size, size)
end

-- Роли значками: counts — с числами (кого ищет группа), иначе только значки (кем может идти игрок).
function Views.GroupRoles(roles, counts)
	local out = {}
	for _, k in ipairs(ns.Groups.ROLES) do
		local n = type(roles) == "table" and roles[k] or 0
		if n > 0 then out[#out + 1] = Views.RoleIcon(k) .. (counts and (WHITE .. n .. "|r") or "") end
	end
	return table.concat(out, " ")
end

-- Почему не получилось разместить объявление или подать заявку.
function Views.GroupWhy(why, arg)
	if why == "nocert" then return ns.Security.NotReadyReason() end
	if why == "wait" then
		-- С числом — лимит размещений (секунды), без числа — пауза между заявками одному автору.
		if not arg then return L.GROUPS_WHY_SOON end
		if arg >= 90 then return L.GROUPS_WHY_WAIT_MIN:format(math.ceil(arg / 60)) end
		return L.GROUPS_WHY_WAIT:format(arg)
	end
	return rawget(L, "GROUPS_WHY_" .. tostring(why):upper()) or L.GROUPS_WHY_FAILED
end

-- Сколько минут объявлению осталось до снятия.
function Views.GroupLeft(l)
	return math.max(1, math.ceil((l.id + C.GROUPS_LIFE - ns.ServerTime()) / 60))
end

local function GroupTip(e, own)
	return function(tt)
		tt:AddLine(Views.Name(e.name, e.class))
		local who = Codec.Plain(e.guild)
		if e.level and e.level > 0 then who = who .. ", " .. L.TIP_LEVEL:format(e.level) end
		if e.class and L.CLASS[e.class] then who = who .. ", " .. L.CLASS[e.class] end
		tt:AddLine(who, 0.8, 0.8, 0.8)
		tt:AddLine(" ")
		if e.mode == "G" then
			tt:AddLine(e.title, 1, 1, 1, true)
			local need = ns.Groups.RoleText(e.roles, true)
			tt:AddLine(need ~= "" and L.GROUPS_TIP_NEED:format(need) or L.GROUPS_TIP_NEED_ANY, 1, 0.82, 0, true)
			tt:AddLine(L.GROUPS_TIP_SIZE:format(e.size, e.cap), 0.8, 0.8, 0.8)
			if e.min > 0 then tt:AddLine(L.GROUPS_TIP_MIN:format(e.min), 0.8, 0.8, 0.8) end
		else
			tt:AddLine(e.title ~= "" and e.title or L.GROUPS_ANYWHERE, 1, 1, 1, true)
			tt:AddLine(L.GROUPS_TIP_ROLES:format(ns.Groups.RoleText(e.roles)), 1, 0.82, 0, true)
		end
		if e.note ~= "" then tt:AddLine(e.note, 0.8, 0.8, 0.8, true) end
		tt:AddLine(L.GROUPS_TIP_KIND:format(L["GROUPS_KIND_" .. e.kind]), 0.6, 0.6, 0.6)
		if not own then
			tt:AddLine(L.GROUPS_TIP_AGE:format(Views.Ago(ns.ServerTime() - e.raised)), 0.6, 0.6, 0.6)
			tt:AddLine(L.GROUPS_TIP_WHISPER, 0.5, 0.83, 0.76)
		end
	end
end

-- Одна запись доски. action: "apply", "withdraw", "invite" или nil; status — что написать
-- вместо кнопки или под ней.
local function GroupRow(e, own)
	local level = (e.level and e.level > 0) and (", " .. e.level) or ""
	local row = {
		key = e.key, e = e, own = own,
		name = Views.Name(e.name, e.class) .. "  " .. GREY .. Codec.Plain(e.guild) .. level .. "|r",
		tip = GroupTip(e, own),
	}
	local note = e.note ~= "" and (GREY .. " — " .. e.note .. "|r") or ""
	if e.mode == "G" then
		local need = Views.GroupRoles(e.roles, true)
		row.sub = WHITE .. e.title .. "|r" .. note
		row.right = need ~= "" and need or (GREY .. L.GROUPS_NEED_ANY .. "|r")
		row.detail = e.size .. "/" .. e.cap .. (e.min > 0 and (", " .. L.GROUPS_FROM_LEVEL:format(e.min)) or "")
	else
		row.sub = WHITE .. (e.title ~= "" and e.title or L.GROUPS_ANYWHERE) .. "|r" .. note
		row.right = Views.GroupRoles(e.roles)
		row.detail = e.class and L.CLASS[e.class] or ""
	end
	if own then
		row.status = GOLD .. L.GROUPS_YOURS .. "|r"
	elseif e.mode == "P" then
		row.action, row.actionText = "invite", L.GROUPS_INVITE
	elseif e.applied == "sent" then
		row.action, row.actionText = "withdraw", L.GROUPS_WITHDRAW
		row.status = GREEN .. L.GROUPS_APPLIED .. "|r"
	elseif e.applied == "invited" then
		row.status = GREEN .. L.GROUPS_YOU_INVITED .. "|r"
	elseif e.applied == "declined" then
		row.status = GREY .. L.GROUPS_YOU_DECLINED .. "|r"
	elseif e.short then
		row.status = ORANGE .. L.GROUPS_NEED_LEVEL:format(e.min) .. "|r"
	else
		row.action, row.actionText = "apply", L.GROUPS_APPLY
	end
	return row
end

-- Моё объявление в том же виде, в каком его видят остальные.
local function OwnEntry()
	local mine = ns.Groups.Mine()
	if not mine then return nil end
	local _, class = UnitClass("player")
	local size = mine.mode == "G" and math.max(1, GetNumGroupMembers and GetNumGroupMembers() or 0) or 1
	return {
		key = ns.myKey, name = U.Display(ns.me), guild = ns.MyGuild() or "", class = class, level = UnitLevel("player") or 0,
		mode = mine.mode, id = mine.id, raised = mine.id, kind = mine.kind, title = mine.title, note = mine.note,
		roles = mine.roles, size = size, cap = mine.cap, min = mine.min,
	}
end

-- Строки доски: { header = текст } перед разделом и записи GroupRow. kind — только этот вид
-- мест (nil — все). Второе значение — сколько объявлений всего, без учёта фильтра.
function Views.GroupRows(kind)
	local groups, players = ns.Groups.List(kind)
	local own = OwnEntry()
	local rows = {}
	local function Section(list, mode, title)
		local mine = own and own.mode == mode and (not kind or own.kind == kind) and own or nil
		local n = #list + (mine and 1 or 0)
		if n == 0 then return end
		rows[#rows + 1] = { header = title:format(n) }
		if mine then rows[#rows + 1] = GroupRow(mine, true) end
		for _, e in ipairs(list) do rows[#rows + 1] = GroupRow(e, false) end
	end
	Section(groups, "G", L.GROUPS_SECTION_GROUPS)
	Section(players, "P", L.GROUPS_SECTION_PLAYERS)
	return rows, ns.Groups.Count()
end

-- Заявки ко мне: { key, who, name, sub, tip, invited }; who — имя для шёпота, name — с цветом класса.
function Views.GroupApplicants()
	local out = {}
	for _, a in ipairs(ns.Groups.Applicants()) do
		local who = Codec.Plain(a.guild or "")
		if a.level and a.level > 0 then who = who .. ", " .. a.level end
		local roles = Views.GroupRoles(a.roles)
		out[#out + 1] = {
			key = a.key, who = a.name, name = Views.Name(a.name, a.class), invited = a.state == "invited",
			sub = (roles ~= "" and (roles .. " ") or "") .. GREY .. who .. "|r",
			tip = function(tt)
				tt:AddLine(Views.Name(a.name, a.class))
				local line = Codec.Plain(a.guild or "")
				if a.level and a.level > 0 then line = line .. ", " .. L.TIP_LEVEL:format(a.level) end
				if a.class and L.CLASS[a.class] then line = line .. ", " .. L.CLASS[a.class] end
				tt:AddLine(line, 0.8, 0.8, 0.8)
				tt:AddLine(L.GROUPS_TIP_ROLES:format(ns.Groups.RoleText(a.roles)), 1, 0.82, 0, true)
				if a.note and a.note ~= "" then tt:AddLine(a.note, 0.8, 0.8, 0.8, true) end
				tt:AddLine(L.GROUPS_TIP_CLAIM, 0.6, 0.6, 0.6, true)
				tt:AddLine(L.GROUPS_TIP_WHISPER, 0.5, 0.83, 0.76)
			end,
		}
	end
	return out
end
