-- Chillzone: чего аддон сейчас ждёт. Только учёт: ничего не шлёт и у игры не спрашивает.
-- Операция — ожидание с понятным концом: чтение ростера, запрос отчётов, опрос реле.
-- Проба — состояние, которое и так живёт в модуле (очередь отправки, подписи, блокировка):
-- модуль отдаёт строку, а окно спрашивает её, только пока открыто.
-- Фон (приветы, плановые чтения, продление аренд) сюда не попадает намеренно: индикатор
-- показывает то, чего ждёт игрок, и то, что ему мешает.
local ADDON, ns = ...

local Activity = {}
ns.Activity = Activity

local NOTE_TTL = 6 -- столько секунд виден итог обновления
local ORDER = { block = 1, wait = 2, work = 3 }

local ops = {} -- [id] = { id, text, kind, count, token }
local probes = {}
local note = nil -- { text, kind, untilAt }
local lastToken = 0

-- Новый срок отменяет прежний: старый таймер увидит чужой token и ничего не сделает.
local function Arm(op, ttl)
	lastToken = lastToken + 1
	local token = lastToken
	op.token = token
	ns.After(ttl, "activity timeout", function()
		if ops[op.id] == op and op.token == token then Activity.Finish(op.id, op.count > 0) end
	end)
end

-- Операция началась или её просят снова: срок считается заново, накопленные ответы остаются.
-- kind — "wait" (ждём других, по умолчанию), "work" (считаем сами) или "block" (мешает причина).
function Activity.Start(id, text, ttl, kind)
	local op = ops[id]
	if not op then
		op = { id = id, count = 0 }
		ops[id] = op
	end
	op.text, op.kind = text, kind or "wait"
	Arm(op, ttl)
end

-- Пришёл ответ: сдвинуть срок и посчитать. Без начатой операции ничего не делает, поэтому
-- звать можно из обработчиков, которые работают и без запроса.
function Activity.Touch(id, ttl, add)
	local op = ops[id]
	if not op then return false end
	op.count = op.count + (add or 0)
	if ttl then Arm(op, ttl) end
	return true
end

-- ok: nil и true — успех. По истечении срока операция успешна, если ответы были.
function Activity.Finish(id, ok)
	if not ops[id] then return false end
	ops[id] = nil
	ns.Fire("ACTIVITY_DONE", id, ok ~= false)
	return true
end

function Activity.Running(id)
	return ops[id] ~= nil
end

-- fn() возвращает { kind = "block"|"wait"|"work", text = ..., detail = ... } или nil.
function Activity.Probe(fn)
	probes[#probes + 1] = fn
end

-- Всё активное, сначала то, что мешает. Окно зовёт это несколько раз в секунду, поэтому
-- сломанная проба снимается после первой ошибки и не забивает журнал.
function Activity.List()
	local out = {}
	for _, op in pairs(ops) do
		out[#out + 1] = { id = op.id, kind = op.kind, text = op.text }
	end
	for i = #probes, 1, -1 do
		local ok, row = pcall(probes[i])
		if not ok then
			ns.CaptureError("activity probe", row)
			table.remove(probes, i)
		elseif row then
			out[#out + 1] = row
		end
	end
	table.sort(out, function(a, b)
		local ra, rb = ORDER[a.kind] or 4, ORDER[b.kind] or 4
		if ra ~= rb then return ra < rb end
		return a.text < b.text
	end)
	return out
end

-- Итог: виден, когда ничего активного нет. kind — "done" или "fail".
function Activity.Note(text, kind, ttl)
	note = { text = text, kind = kind or "done", untilAt = ns.Now() + (ttl or NOTE_TTL) }
end

function Activity.LastNote()
	if note and ns.Now() >= note.untilAt then note = nil end
	return note
end
