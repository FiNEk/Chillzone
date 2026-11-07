-- Chillzone: журнал действий доверия — /chillzone acts и раздел на вкладке «Отладка».
-- Только то, что увидел сам этот клиент: корень гильдии задан (свой /chillzone trust init, KT от
-- офицера, KA от главной гильдии, связь через link/accept), корень сброшен (свой trust reset
-- или KF от офицера), снят отзыв ключа (KU или подтверждение связи), запрос связи (отправлен
-- или получен) и его подтверждение. У записи: гильдия, кто, когда, откуда известно.
-- Подъём и падение реле сюда не пишутся. До MAX записей в ns.store.acts (своё у группы
-- реалмов и фракции); в сеть и в отчёт об ошибке журнал не уходит.
-- По образцу Olympus Chronicle.lua (MIT, см. THIRD_PARTY.md).
local ADDON, ns = ...

local L = ns.L
local U = ns.Util

local Acts = {}
ns.Acts = Acts

Acts.MAX = 300
Acts.SHOW = 10 -- строк на вкладке «Отладка»

function Acts.List()
	local s = ns.store
	if not s then return {} end
	if type(s.acts) ~= "table" then s.acts = {} end
	return s.acts
end

-- kind: root, reset, unretire, link_out, link_in, link_ok. by — кто (имя), via — откуда
-- (init, own, KT, KA, KF, KU, KL, link, accept), name — корень или собеседник.
function Acts.Add(kind, guild, by, via, name)
	if not ns.store then return end
	local list = Acts.List()
	list[#list + 1] = {
		t = ns.ServerTime(), kind = tostring(kind), guild = guild and tostring(guild) or nil,
		by = by and U.Display(by) or nil, via = via and tostring(via) or nil, name = name and U.Display(name) or nil,
	}
	-- В общий журнал (ns.Log) не пишется: тот уходит в отчёт об ошибке.
	while #list > Acts.MAX do table.remove(list, 1) end
	if ns.Fire then ns.Fire("ACTS") end
end

local function When(t)
	return date and date("%Y-%m-%d %H:%M", t) or tostring(t)
end

-- Строка записи без времени.
function Acts.Text(e)
	local fmt = L.ACT_KIND[e.kind] or e.kind
	local via = L.ACT_VIA[e.via or ""] or e.via or "?"
	return fmt:format(ns.Codec.Plain(e.guild or "?"), e.name or "?") .. " " .. L.ACT_BY:format(e.by or "?", via)
end

function Acts.Line(e)
	return When(e.t) .. "  " .. Acts.Text(e)
end

-- Последние n записей, новые сверху.
function Acts.Recent(n)
	local list, out = Acts.List(), {}
	for i = #list, math.max(1, #list - (n or #list) + 1), -1 do out[#out + 1] = list[i] end
	return out
end

function Acts.Copy()
	local out = { L.ACT_HEAD:format(#Acts.List(), tostring(ns.group), tostring(ns.faction)) }
	for _, e in ipairs(Acts.Recent()) do out[#out + 1] = Acts.Line(e) end
	if #out == 1 then out[#out + 1] = L.ACT_NONE end
	return ns.UI.ShowCopy(L.ACT_TITLE, table.concat(out, "\n"))
end

ns.Command("acts", function(arg)
	arg = (arg or ""):match("^%s*(%S*)")
	if arg == "copy" then return Acts.Copy() end
	local n = math.max(1, math.min(tonumber(arg) or 10, 50))
	local recent = Acts.Recent(n)
	ns.Print(L.ACT_HEAD:format(#Acts.List(), tostring(ns.group), tostring(ns.faction)))
	if #recent == 0 then ns.Print(L.ACT_NONE) end
	for i = #recent, 1, -1 do ns.Print((Acts.Line(recent[i]):gsub("|", "||"))) end
end, L.HELP_ACTS)
