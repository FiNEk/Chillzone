-- Chillzone: отчёт об ошибке — /chillzone bug и кнопка в «Настройках» (всем, не только офицерам).
-- Открывается в окне копирования, откуда игрок копирует его автору. Что в отчёте: версия и клиент, кто я и моя гильдия, откуда известно
-- офицерство, уровень чата, роль в связи, реле и репортёр, счётчики, строки /chillzone status,
-- пробы API игры, ошибки со стеком, блокировки игрой и последние строки журнала.
-- Чего в нём нет: ничего из ns.store.security и ChillzoneDB.securityKeys (секрет, ключи,
-- сертификаты), журнала действий доверия (Acts.lua) и ростера по именам. Сверх этого
-- длинные строки base64 (так выглядят ключи и подписи) и сам секрет вычищаются из текста.
-- По образцу Olympus Diagnostics.lua (ns.StatusText, ns.BuildBugReport).
local ADDON, ns = ...

local L = ns.L
local U = ns.Util

local Report = {}
ns.Report = Report

Report.LOG_LINES = 25
Report.ERRORS = 8 -- ошибок со стеком
Report.BLOCKED = 3

local function Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d = pcall(fn, ...)
	if ok then return a, b, c, d end
	return nil
end

local function YesNo(v)
	return v and L.YES or L.NO
end

-- Текст без кодов игры: цвета и значки убраны, остальная «|» — «!». В окне копирования
-- это обычный текст.
function Report.Plain(s)
	s = tostring(s or "")
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1")
	return (s:gsub("|", "!"))
end

-- Секреты вон: сам seed и открытые ключи этого аккаунта — дословно, а любая строка base64url
-- (так их пишет Ed.ToB64) длиной от 32 знаков с буквами и цифрами — ключ, подпись,
-- сертификат — меткой. «/», «\» и «.» её рвут, так что пути в стеке остаются целыми.
function Report.Scrub(text)
	text = tostring(text or "")
	local keys = ns.db and ns.db.securityKeys
	if type(keys) == "table" then
		for _, k in pairs(keys) do
			if type(k) == "table" then
				for _, field in ipairs({ "seed", "public" }) do
					local v = k[field]
					if type(v) == "string" and #v >= 8 then
						local a, b = text:find(v, 1, true)
						while a do
							text = text:sub(1, a - 1) .. L.BUG_KEY .. text:sub(b + 1)
							a, b = text:find(v, a + #L.BUG_KEY, true)
						end
					end
				end
			end
		end
	end
	return (text:gsub("[%w_%-]+", function(w)
		if #w >= 32 and w:find("%d") and w:find("%a") then return L.BUG_KEY end
	end))
end

local function ClientLine()
	local version, build, _, toc = Try(GetBuildInfo)
	local locale = Try(GetLocale)
	return L.BUG_CLIENT:format(tostring(version or "?"), tostring(build or "?"), tostring(toc or "?"), tostring(locale or "?"))
end

-- Флаги звания так, как их отдала игра: «22=да» и список включённых.
local function RankFlags(rank)
	local info = rawget(_G, "C_GuildInfo")
	local get = type(info) == "table" and info.GuildControlGetRankFlags
	if type(rank) ~= "number" then return L.BUG_NO_RANK end
	if type(get) ~= "function" then return L.BUG_NO_API end
	local ok, flags = pcall(get, rank + 1)
	if not ok then return L.BUG_API_ERROR:format(tostring(flags)) end
	if type(issecretvalue) == "function" and issecretvalue(flags) then return "secret" end
	if type(flags) ~= "table" then return tostring(flags) end
	local on, n = {}, 0
	for k, v in pairs(flags) do
		n = n + 1
		if v == true then on[#on + 1] = tostring(k) end
	end
	table.sort(on, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
	return L.BUG_FLAGS:format(rank + 1, n, tostring(flags[22]), #on > 0 and table.concat(on, ",") or "-")
end

local function ProbeLines(add)
	add(L.BUG_PROBES)
	local guild, rankName, rankIndex = Try(GetGuildInfo, "player")
	add("  " .. L.BUG_PROBE_FLAGS:format(RankFlags(rankIndex)))
	local R = ns.Roster
	local rosterRank = R and ns.myKey and R.byKey[ns.myKey]
	local rosterName = R and ns.myKey and R.rankNames[ns.myKey]
	add("  " .. L.BUG_PROBE_RANK:format(tostring(guild and rankName or "-"), tostring(rankIndex or "-"), tostring(rosterName or "-"), tostring(rosterRank or "-")))
	local name, realm = Try(UnitFullName, "player")
	add("  " .. L.BUG_PROBE_NAME:format(tostring(name), tostring(realm), tostring(ns.splitNames or false), tostring(ns.me)))
	local server, here = Try(GetServerTime), Try(time)
	add("  " .. L.BUG_PROBE_TIME:format((server and here) and tostring(server - here) or "?"))
	local zones, seen = {}, {}
	for _, row in ipairs(R and R.members or {}) do
		if row.zone and row.zoneKey and row.zoneKey:sub(1, 1) == "t" and not seen[row.zone] then
			seen[row.zone] = true
			zones[#zones + 1] = row.zone
		end
	end
	table.sort(zones)
	add("  " .. L.BUG_PROBE_ZONES:format(#zones > 0 and table.concat(zones, ", ", 1, math.min(#zones, 12)) or "-"))
	add("  " .. L.BUG_PROBE_GAMEPAD:format(YesNo(ns.ChatPane and ns.ChatPane.Gamepad())))
end

local function MeLines(add)
	add(L.BUG_ME:format(tostring(ns.me), tostring(ns.realm), tostring(ns.group), tostring(ns.splitNames or false), tostring(ns.faction)))
	local guild, rank, rankName = ns.MyGuild()
	if not guild then
		add(L.STATUS_NO_GUILD)
	else
		add(L.BUG_GUILD:format(guild, tostring(rank), tostring(rankName), YesNo(U.IsMemberGuild(guild)), YesNo(U.IsMainGuild(guild))))
		local officer = ns.Roster.IsOfficerRank(rank)
		local source = ns.Debug and ns.Debug.OfficerSource and ns.Debug.OfficerSource(rank) or "?"
		add(L.BUG_OFFICER:format(YesNo(officer), source))
	end
	local role = ns.MyTrust()
	add(L.BUG_LEVEL:format(ns.Chat.MyLevel(), L.DBG_ROLE[role or "none"] or tostring(role)))
	local Rl, Cs = ns.Relay, ns.Census
	local pick = Rl and not Rl.IAmRelay() and Rl.Pick() or nil
	add(L.BUG_RELAY:format(YesNo(Rl and Rl.IAmRelay()), pick and U.Display(pick.name) or "-",
		tostring(Cs and Cs.ReporterName() or "-"), YesNo(Cs and Cs.IsReporter())))
	local c, ch, s, r = ns.Comm.stats, ns.Chat.stats, ns.Security.stats, Rl and Rl.stats or {}
	add(L.BUG_COUNT_COMM:format(c.sent, c.recv, c.fails, c.retried, c.dropped, ns.Comm.QueueSize()))
	add(L.BUG_COUNT_CHAT:format(ch.sent, ch.shown, ch.dupes, ch.refused, ch.limited))
	add(L.BUG_COUNT_AUTH:format(s.verified, s.rejected, s.limited, YesNo(ns.Security.MyCertificate())))
	add(L.BUG_COUNT_RELAY:format(r.forwarded or 0, r.delivered or 0, r.dropped or 0, r.untrusted or 0))
end

local function StackLines(add, stack, limit)
	local n = 0
	for line in tostring(stack or ""):gmatch("[^\n]+") do
		n = n + 1
		if n > limit then break end
		add("      " .. line)
	end
end

local function BlockedLines(add)
	local list = ns.db and ns.db.blocked or {}
	add(L.BUG_BLOCKED:format(#list, ns.blockedSession or 0))
	for i = 1, math.min(#list, Report.BLOCKED) do
		local b = list[i]
		add(("  [%sx] %s %s (%s .. %s, v%s)"):format(tostring(b.count or 1), tostring(b.event), tostring(b.func),
			tostring(b.first), tostring(b.last), tostring(b.version or "?")))
		StackLines(add, b.stack, 8)
	end
end

local function ErrorLines(add)
	local list = ns.db and ns.db.errors or {}
	add(L.BUG_ERRORS:format(#list))
	if #list == 0 then add("  " .. L.DBG_NO_ERRORS) end
	for i = 1, math.min(#list, Report.ERRORS) do
		local e = list[i]
		add(("  [%sx] %s (%s .. %s, v%s)"):format(tostring(e.count or 1), tostring(e.where), tostring(e.first),
			tostring(e.last), tostring(e.version or "?")))
		add("    " .. tostring(e.msg))
		StackLines(add, e.stack, ns.STACK_LINES or 12)
	end
	if #list > Report.ERRORS then
		for i = Report.ERRORS + 1, #list do add("  " .. ns.ErrorLine(list[i])) end
	end
end

-- Весь отчёт одним текстом.
function Report.Build()
	local out = {}
	local function add(s) out[#out + 1] = s end
	add(L.BUG_HEAD:format(tostring(ns.VERSION), ns.Stamp()))
	add(ClientLine())
	MeLines(add)
	add("")
	add(L.BUG_STATUS)
	for _, line in ipairs(ns.StatusLines()) do add("  " .. line) end
	add("")
	ProbeLines(add)
	add("")
	BlockedLines(add)
	add("")
	ErrorLines(add)
	add("")
	local log = ns.db and ns.db.log or {}
	add(L.BUG_LOG:format(math.min(#log, Report.LOG_LINES)))
	for i = math.max(1, #log - Report.LOG_LINES + 1), #log do add("  " .. tostring(log[i])) end
	return Report.Scrub(Report.Plain(table.concat(out, "\n")))
end

function Report.Show()
	return ns.UI.ShowCopy(L.BUG_TITLE, Report.Build())
end

ns.Command("bug", function() Report.Show() end, L.HELP_BUG)
