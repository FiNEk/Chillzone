-- Chillzone: вкладка «Отладка» для глав и офицеров гильдий «Чиллзон». На ней: кем меня считает
-- аддон, реле и их состояние, репортёры, которые зарегистрировались у меня, согильдийцы с аддоном,
-- отчёты гильдий, счётчики, последние ошибки и блокировки, журнал действий доверия. Автору
-- аддона (Config.AUTHOR) вкладка видна всегда; у него же — принятые отчёты об ошибках.
-- Строки устроены как у «Королевства» ({ text, right, header, indent, gap, tip, onClick }),
-- рисует их UI.lua.
local ADDON, ns = ...

local U = ns.Util
local C = ns.Config
local Codec = ns.Codec
local L = ns.L

local Debug = {}
ns.Debug = Debug

local GOLD, GREY, RED, GREEN, WHITE = "|cffffd100", "|cff999999", "|cffff4040", "|cff40ff40", "|cffffffff"
local ICON_ON = "|TInterface\\FriendsFrame\\StatusIcon-Online:12|t"
local ICON_OFF = "|TInterface\\FriendsFrame\\StatusIcon-Offline:12|t"
local MAX_ERRORS = 5
local STATE_COLOR = { ok = GREEN, down = RED, asked = GOLD, unknown = GREY }

-- Вкладку видят главы и офицеры (офицер — по флагу звания) и автор аддона. У автора в
-- «Просмотре как» — как у выбранного уровня.
function Debug.Allowed()
	local A = ns.Author
	local view = A and A.ViewLevel()
	if view ~= nil then return view >= 2 end
	if A and A.IsMe() then return true end
	return ns.Chat.MyLevel() >= 2
end

-- 42 → «42 с», 300 → «5 мин», 7200 → «2 ч».
function Debug.Span(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds < 60 then return L.DBG_S:format(seconds) end
	if seconds < 3600 then return L.DBG_M:format(math.floor(seconds / 60)) end
	return L.DBG_H:format(math.floor(seconds / 3600))
end

local function Ago(seconds)
	return L.DBG_AGO:format(Debug.Span(seconds))
end

local function Paint(color, s)
	return color .. tostring(s) .. "|r"
end

local function YesNo(v)
	return v and L.YES or L.NO
end

local function Add(lines, line)
	lines[#lines + 1] = line
	return line
end

local function Header(lines, text, first)
	Add(lines, { text = Paint(GOLD, text), header = true, gap = not first })
end

local function RoleLabel(role)
	return L.DBG_ROLE[role or "none"] or tostring(role)
end

---------------------------------------------------------------------------
-- Я
---------------------------------------------------------------------------
-- Откуда офицерские права: звание главы, игровой флаг «офицер» или, если игра флаг не
-- сказала, номер звания (Config.OFFICER_RANK).
local function OfficerSource(rank)
	if type(rank) ~= "number" then return "?" end
	if rank == 0 then return L.DBG_SRC_LEADER end
	if ns.Roster.RankFlagOfficer(rank) ~= nil then return L.DBG_SRC_FLAG end
	return L.DBG_SRC_UNKNOWN
end
Debug.OfficerSource = OfficerSource

local function Me(lines)
	Header(lines, L.DBG_ME, true)
	Add(lines, {
		text = Paint(WHITE, U.Display(ns.me)) .. "  " .. Paint(GREY, L.DBG_KEY:format(ns.myKey or "?")),
		right = Paint(GREY, L.DBG_VERSION:format(ns.VERSION or "?")),
		tip = function(tt)
			tt:AddLine(U.Display(ns.me))
			tt:AddLine(L.DBG_REALM:format(ns.realm or "?", ns.group or "?", tostring(ns.splitNames or false), ns.faction or "?"), 0.8, 0.8, 0.8, true)
		end,
	})
	local guild, rank, rankName = ns.MyGuild()
	if not guild then
		Add(lines, { text = Paint(GREY, L.DBG_NO_GUILD) })
		return
	end
	local kind = ""
	if not U.IsMemberGuild(guild) then
		kind = Paint(RED, L.DBG_NOT_MEMBER)
	elseif U.IsMainGuild(guild) then
		kind = Paint(GOLD, L.DBG_MAIN)
	end
	Add(lines, { text = L.DBG_GUILD:format(Codec.Plain(guild), tostring(rank or "?"), Codec.Plain(rankName or "?")), right = kind })
	Add(lines, {
		text = L.DBG_OFFICER:format(YesNo(ns.Roster.IsOfficerRank(rank))) .. "  " .. Paint(GREY, "(" .. OfficerSource(rank) .. ")"),
		right = Paint(GREY, L.DBG_LEVEL:format(ns.Chat.MyLevel())),
	})
	Add(lines, {
		text = L.DBG_TRUST:format(RoleLabel(ns.MyTrust())),
		right = Paint(GREY, C.TRUST_ANY_MEMBER and L.DBG_TRUST_ANY or L.DBG_TRUST_RANK:format(C.RELAY_RANK)),
	})
end

---------------------------------------------------------------------------
-- Реле
---------------------------------------------------------------------------
local function RelayTip(e, now, trust)
	return function(tt)
		local R = ns.Relay
		tt:AddLine(U.Display(e.name))
		tt:AddLine(L.DBG_KEY:format(e.key), 0.8, 0.8, 0.8)
		tt:AddLine(L.DBG_TIP_TRUST:format(L.DBG_SRC_RELAY[trust] or tostring(trust)), 0.8, 0.8, 0.8)
		tt:AddLine(L.DBG_TIP_STATE:format((R.StateOf(e, now))), 0.8, 0.8, 0.8)
		if e.verified then tt:AddLine(L.DBG_TIP_VERIFIED:format(Ago(now - e.verified)), 0.8, 0.8, 0.8) end
		if e.asked then tt:AddLine(L.DBG_TIP_ASKED:format(Ago(now - e.asked)), 0.8, 0.8, 0.8) end
		if e.down and now < e.down then tt:AddLine(L.DBG_TIP_DOWN:format(Debug.Span(e.down - now)), 1, 0.4, 0.4) end
		local learned = ns.store and ns.store.relays[e.key]
		if learned then
			local by = learned.by and ns.Relay.Known()[learned.by]
			tt:AddLine(L.DBG_TIP_LEARNED:format(by and U.Display(by.name) or tostring(learned.by or "?"), Ago(ns.ServerTime() - (learned.t or 0))), 0.8, 0.8, 0.8)
		end
		local peer = ns.Census.Peers()[e.key]
		if peer then tt:AddLine(L.DBG_TIP_PEER:format(Codec.Plain(peer.version or "?")), 0.8, 0.8, 0.8) end
	end
end

local function Reporters(lines, now)
	local R = ns.Relay
	Add(lines, { text = Paint(GOLD, L.DBG_REPORTERS), gap = true })
	local regs = {}
	for gk, r in pairs(R.Reporters()) do regs[#regs + 1] = { gk = gk, r = r } end
	table.sort(regs, function(a, b) return a.gk < b.gk end)
	if #regs == 0 then Add(lines, { text = Paint(GREY, L.DBG_NO_REPORTERS), indent = 1 }) end
	for _, x in ipairs(regs) do
		local row = ns.Data.Row(x.gk)
		local guild = row and row.guild or x.gk
		local age = now - (x.r.t or now)
		local stale = age > R.REG_TTL
		Add(lines, {
			text = Codec.Plain(guild) .. ": " .. Paint(WHITE, U.Display(x.r.name)),
			right = stale and Paint(RED, L.DBG_STALE:format(Ago(age))) or Paint(GREEN, Ago(age)),
			indent = 1,
		})
	end
end

local function Relays(lines, now)
	local R = ns.Relay
	Header(lines, L.DBG_RELAYS)
	-- Реле рассылает свои сообщения само (Relay.Out), остальные — через Relay.Pick.
	local iAmRelay = R.IAmRelay()
	local pick = not iAmRelay and R.Pick() or nil
	local via
	if iAmRelay then
		via = Paint(GREEN, L.DBG_RELAY_SELF)
	else
		via = pick and Paint(GREEN, U.Display(pick.name)) or Paint(RED, "—")
	end
	Add(lines, { text = L.DBG_I_AM_RELAY:format(YesNo(iAmRelay)), right = L.DBG_MY_RELAY:format(via) })
	local s, hold = R.stats, R.HoldSize()
	Add(lines, {
		text = Paint(GREY, L.DBG_RELAY_STATS:format(s.forwarded, s.delivered, s.dropped, s.untrusted)),
		right = L.DBG_HOLD:format(hold > 0 and Paint(RED, hold) or hold),
	})
	if ns.Census.IsReporter() or R.lastRegister then
		Add(lines, { text = Paint(GREY, L.DBG_REGISTERED:format(R.lastRegister and Ago(now - R.lastRegister) or L.DBG_NEVER)) })
	end
	local list = R.Candidates()
	table.sort(list, function(a, b) return U.Display(a.name or a.key) < U.Display(b.name or b.key) end)
	if #list == 0 then Add(lines, { text = Paint(GREY, L.DBG_NO_RELAYS), indent = 1 }) end
	for _, e in ipairs(list) do
		local state, code = R.StateOf(e, now)
		local trust = R.TrustOf(e.name)
		local when
		if e.down and now < e.down then
			when = L.DBG_DOWN_LEFT:format(Debug.Span(e.down - now))
		elseif e.verified then
			when = Ago(now - e.verified)
		elseif e.asked then
			when = Ago(now - e.asked)
		end
		local mark = (pick and pick.key == e.key) and ("  " .. Paint(GOLD, L.DBG_PICKED)) or ""
		if R.IsMainOfficer(e.name) then mark = mark .. "  " .. Paint(GREEN, L.DBG_RELAY_OFFICER) end
		Add(lines, {
			text = (code == "ok" and ICON_ON or ICON_OFF) .. Paint(WHITE, U.Display(e.name)) .. mark .. "  " .. Paint(GREY, L.DBG_SRC_RELAY[trust] or tostring(trust)),
			right = Paint(STATE_COLOR[code] or GREY, state) .. (when and Paint(GREY, ", " .. when) or ""),
			indent = 1,
			tip = RelayTip(e, now, trust),
		})
	end
	if iAmRelay then Reporters(lines, now) end
end

---------------------------------------------------------------------------
-- Перепись моей гильдии: репортёр и согильдийцы с аддоном
---------------------------------------------------------------------------
local function Census(lines, now)
	Header(lines, L.DBG_CENSUS)
	if not ns.IsMember() then
		Add(lines, { text = Paint(GREY, L.DBG_NOT_MEMBER) })
		return
	end
	local rep = ns.Census.Reporter()
	local who
	if not rep then
		who = Paint(RED, "—")
	elseif rep == ns.myKey then
		who = Paint(GREEN, L.DBG_REPORTER_ME)
	else
		who = Paint(WHITE, ns.Census.ReporterName() or rep)
	end
	Add(lines, {
		text = L.DBG_REPORTER:format(who),
		right = Paint(GREY, L.DBG_ZONES:format(YesNo(ns.char and ns.char.shareZones))),
	})
	local peers = {}
	for key, p in pairs(ns.Census.Peers()) do peers[#peers + 1] = { key = key, p = p } end
	table.sort(peers, function(a, b) return U.Display(a.p.name) < U.Display(b.p.name) end)
	if #peers == 0 then Add(lines, { text = Paint(GREY, L.DBG_NO_PEERS), indent = 1 }) end
	for _, x in ipairs(peers) do
		local p = x.p
		local age = now - (p.t or now)
		local live = age <= C.PEER_WINDOW
		local version = Codec.Plain(p.version or "?")
		local flags = { version == ns.VERSION and ("v" .. version) or Paint(RED, "v" .. version) }
		if p.z then flags[#flags + 1] = L.DBG_PEER_ZONES end
		if p.r then flags[#flags + 1] = L.DBG_PEER_RELAY end
		flags[#flags + 1] = live and Ago(age) or Paint(RED, L.DBG_PEER_QUIET:format(Ago(age)))
		local mark = x.key == rep and ("  " .. Paint(GOLD, L.DBG_PEER_REPORTER)) or ""
		Add(lines, {
			text = (live and ICON_ON or ICON_OFF) .. Paint(WHITE, U.Display(p.name)) .. mark .. "  " .. Paint(GREY, RoleLabel(ns.Roster.TrustOfKey(x.key))),
			right = Paint(GREY, table.concat(flags, ", ")),
			indent = 1,
		})
	end
end

---------------------------------------------------------------------------
-- Отчёты гильдий, счётчики, ошибки
---------------------------------------------------------------------------
local function Reports(lines)
	Header(lines, L.DBG_REPORTS)
	local now = ns.ServerTime()
	local list = ns.Data.Summary(now)
	if #list == 0 then Add(lines, { text = Paint(GREY, L.DBG_NO_REPORTS), indent = 1 }) end
	for _, s in ipairs(list) do
		local row = ns.Data.Row(s.guild)
		local from = s.mine and L.DBG_REPORT_MINE or L.DBG_REPORT_FROM:format(Codec.Plain(row and row.origin or "?"), Ago(s.age))
		Add(lines, {
			text = Paint(s.main and GOLD or WHITE, Codec.Plain(s.guild)) .. (s.conflict and (" " .. Paint(RED, "!")) or ""),
			right = Paint(s.fresh and GREEN or GREY, from),
			indent = 1,
			tip = function(tt)
				tt:AddLine(Codec.Plain(s.guild))
				tt:AddLine(L.DBG_TIP_ONLINE:format(s.r.online or 0, s.r.total or 0), 0.8, 0.8, 0.8)
				tt:AddLine(L.DBG_TIP_LEADERS:format(#(s.r.officers or {}), #(s.r.veterans or {})), 0.8, 0.8, 0.8)
				if s.conflict then tt:AddLine(L.TIP_CONFLICT, 1, 0.4, 0.4, true) end
			end,
		})
	end
	local why = {}
	for reason, n in pairs(ns.Data.rejected) do why[#why + 1] = { reason = reason, n = n } end
	table.sort(why, function(a, b) return a.n > b.n or (a.n == b.n and a.reason < b.reason) end)
	if #why > 0 then
		local parts = {}
		for _, x in ipairs(why) do parts[#parts + 1] = x.reason .. " " .. x.n end
		Add(lines, { text = Paint(GREY, L.DBG_REJECTED:format(table.concat(parts, ", "))), indent = 1 })
	end
end

local function Counters(lines)
	Header(lines, L.DBG_COMM)
	local s = ns.Comm.stats
	Add(lines, {
		text = L.DBG_COMM_LINE:format(s.sent, s.recv, s.fails, s.retried, s.dropped),
		right = Paint(GREY, L.DBG_QUEUE:format(ns.Comm.QueueSize())),
	})
	local c = ns.Chat.stats
	Add(lines, { text = L.DBG_CHAT_LINE:format(c.sent, c.shown, c.dupes, c.refused, c.limited) })
end

-- Ошибка целиком: для окна копирования и подсказки.
local function ErrorText(e)
	if type(e) ~= "table" then return Codec.Plain(e) end
	local out = {
		Codec.Plain(ns.ErrorLine(e)),
		L.DBG_ERR_WHEN:format(tostring(e.first or "?"), tostring(e.last or "?"), tostring(e.version or "?")),
	}
	for line in tostring(e.stack or ""):gmatch("[^\n]+") do out[#out + 1] = "  " .. Codec.Plain(line) end
	return table.concat(out, "\n")
end

local function Copy(title, text)
	return function() ns.UI.ShowCopy(title, text) end
end

local function Errors(lines)
	Header(lines, L.DBG_ERRORS)
	local errors = (ns.db and ns.db.errors) or {}
	if #errors == 0 then Add(lines, { text = Paint(GREY, L.DBG_NO_ERRORS), indent = 1 }) end
	for i = 1, math.min(MAX_ERRORS, #errors) do
		local e = errors[i]
		local text = ErrorText(e)
		Add(lines, {
			text = Paint(RED, Codec.Plain(ns.ErrorLine(e))),
			right = type(e) == "table" and Paint(GREY, tostring(e.last or "")) or nil,
			indent = 1,
			tip = function(tt)
				for line in text:gmatch("[^\n]+") do tt:AddLine(line, 1, 0.6, 0.6, true) end
				tt:AddLine(L.DBG_CLICK_COPY, 0.5, 0.8, 1)
			end,
			onClick = Copy(L.DBG_ERRORS, text),
		})
	end
	if #errors > MAX_ERRORS then Add(lines, { text = Paint(GREY, L.DBG_MORE_ERRORS:format(#errors - MAX_ERRORS)), indent = 1 }) end
	local blocked = (ns.db and ns.db.blocked) or {}
	if #blocked > 0 then
		local b = blocked[1]
		Add(lines, {
			text = Paint(RED, L.DBG_BLOCKED:format(#blocked, Codec.Plain(b.func or "?"))),
			right = Paint(GREY, tostring(b.last or "")),
			indent = 1,
			tip = function(tt)
				for _, x in ipairs(blocked) do
					tt:AddLine(("[%sx] %s %s"):format(tostring(x.count or 1), tostring(x.event), Codec.Plain(x.func or "?")), 1, 0.6, 0.6)
				end
			end,
		})
	end
	Add(lines, { text = Paint(GOLD, L.DBG_BUG_REPORT), indent = 1, onClick = function() ns.Report.Show() end })
end

-- Журнал действий доверия (Acts.lua): последние записи, щелчок — весь журнал.
local function TrustActs(lines)
	local A = ns.Acts
	if not A then return end
	Header(lines, L.DBG_ACTS)
	local recent = A.Recent(A.SHOW)
	if #recent == 0 then Add(lines, { text = Paint(GREY, L.ACT_NONE), indent = 1 }) end
	for _, e in ipairs(recent) do
		Add(lines, {
			text = Codec.Plain(A.Text(e)),
			right = Paint(GREY, Ago(ns.ServerTime() - (e.t or 0))),
			indent = 1,
		})
	end
	Add(lines, { text = Paint(GOLD, L.DBG_ACTS_ALL:format(#A.List())), indent = 1, onClick = function() A.Copy() end })
end

-- Только у автора: «Просмотр как» и принятые отчёты.
local function AuthorLines(lines)
	local A = ns.Author
	if not (A and A.IsMe()) then return end
	Header(lines, L.DBG_AUTHOR)
	Add(lines, { text = L.VIEW_BUTTON:format(A.ViewLabel()), right = Paint(GREY, L.DBG_VIEW_HINT), indent = 1, onClick = function() A.CycleView() end })
	local inbox = A.Inbox()
	if #inbox == 0 then Add(lines, { text = Paint(GREY, L.DBG_INBOX_EMPTY), indent = 1 }) end
	for i = 1, math.min(#inbox, 10) do
		local e = inbox[i]
		local first = Codec.Plain((e.text or ""):match("^[^\n]*") or "")
		Add(lines, {
			text = Paint(WHITE, Codec.Plain(e.from or "?")) .. "  " .. Paint(GREY, first),
			right = Paint(GREY, Ago(ns.ServerTime() - (e.t or 0))),
			indent = 1,
			onClick = function() A.Open(i) end,
		})
	end
	if #inbox > 10 then Add(lines, { text = Paint(GREY, L.DBG_INBOX_MORE:format(#inbox - 10)), indent = 1 }) end
end

-- Строки вкладки «Отладка».
function Debug.Lines()
	local lines = {}
	local now = ns.Now()
	Me(lines)
	AuthorLines(lines)
	Relays(lines, now)
	Census(lines, now)
	Reports(lines)
	Counters(lines)
	Errors(lines)
	TrustActs(lines)
	Add(lines, { text = Paint(GREY, L.DBG_HINT), gap = true })
	return lines
end
