-- Chillzone: обновление данных по просьбе игрока. Новых сообщений в сети не появляется: те же
-- чтение ростера, Q1 репортёру, RP реле и JQ офицерам, что и по расписанию, только сейчас.
-- Частоту держат REFRESH_GAP здесь и шлюзы в модулях (Q1_GAP, 30 секунд у JQ).
-- Ростер читается первым, чтобы репортёр опубликовал уже свежий.
local ADDON, ns = ...

local L, C, A = ns.L, ns.Config, ns.Activity

local Refresh = {}
ns.Refresh = Refresh

local lastRun = -1e9
local run = nil -- текущий запуск: { announce, left = { [id] = true }, failed = { [id] = true } }

function Refresh.Available()
	return ns.MyGuild() ~= nil
end

function Refresh.Busy()
	return run ~= nil
end

-- Сколько секунд до следующего запуска (0 — можно сейчас).
function Refresh.Wait()
	return math.max(0, lastRun + C.REFRESH_GAP - ns.Now())
end

-- Операция могла закончиться ещё при запуске (подпись бывает синхронной в тестах).
local function Expect(id)
	if id and A.Running(id) then run.left[id] = true end
end

local function Network()
	if ns.IsMember() then
		local id, why = ns.Census.Refresh()
		Expect(id)
		if why == "wait" then run.reportsSkipped = true end
		if why == "failed" then run.failed.report = true end
		-- e.down здесь не сбрасывается, в отличие от /chillzone relay ping: вернувшийся в тройку
		-- мёртвый реле задержал бы чат до ответа на этот опрос.
		ns.Relay.PingAll()
		if ns.Relay.Asking() > 0 then
			A.Start("relays", L.ACT_RELAYS, C.RELAY_TIMEOUT + 2)
			Expect("relays")
		end
	end
	if ns.RecruitSync.RequestSync() then
		-- У JQ нет подтверждения, а заявки может не быть ни одной: просто даём офицерам ответить.
		A.Start("requests", L.ACT_REQUESTS, 4)
		Expect("requests")
	end
end

local function Conclude()
	local finished = run
	run = nil
	local failed = finished.failed
	local text, kind = L.REFRESH_DONE, "done"
	if failed.roster then text, kind = L.REFRESH_NO_ROSTER, "fail"
	elseif failed.relays then text, kind = L.REFRESH_NO_RELAYS, "fail"
	elseif failed.report then text, kind = L.REFRESH_NO_SEAL, "fail"
	elseif finished.reportsSkipped then text = L.REFRESH_PARTIAL:format(math.max(1, math.ceil(ns.Census.RefreshWait())))
	elseif failed.census then text = L.REFRESH_NO_REPORTS end
	A.Note(text, kind)
	if finished.announce then ns.Print(text) end
end

-- Возвращает true или false и причину: "guild", "busy", "wait".
function Refresh.Run(announce)
	if not Refresh.Available() then return false, "guild" end
	if run then return false, "busy" end
	if Refresh.Wait() > 0 then return false, "wait" end
	lastRun = ns.Now()
	run = { announce = announce, left = {}, failed = {} }
	ns.Roster.Load()
	if A.Running("roster") then Expect("roster") else Network() end
	if not next(run.left) then Conclude() end
	return true
end

ns.On("ACTIVITY_DONE", function(id, ok)
	if not run or not run.left[id] then return end
	run.left[id] = nil
	if not ok then run.failed[id] = true end
	if id == "roster" then Network() end
	if not next(run.left) then Conclude() end
end)

-- На опрос ответили все, кого спросили: сертификат от реле тоже считается ответом.
local function RelaysAnswered()
	if A.Running("relays") and ns.Relay.Asking() == 0 then
		A.Finish("relays", ns.Relay.Pick() ~= nil)
	end
end
ns.On("RELAYS", RelaysAnswered)
ns.On("AUTH_PEER", RelaysAnswered)

-- Ответы для прежней гильдии уже не придут или не нужны.
ns.On("GUILD_CHANGED", function()
	run = nil
	for _, id in ipairs({ "roster", "census", "report", "relays", "requests" }) do A.Finish(id, false) end
end)

ns.Command("refresh", function()
	local ok, why = Refresh.Run(true)
	if ok then
		if run then ns.Print(L.REFRESH_STARTED) end
	elseif why == "guild" then
		ns.Print(L.REFRESH_NO_GUILD)
	elseif why == "busy" then
		ns.Print(L.REFRESH_ALREADY)
	else
		ns.Print(L.REFRESH_TOO_SOON, math.ceil(Refresh.Wait()))
	end
end, L.HELP_REFRESH)
