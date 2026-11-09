-- Кэш загрузчика не должен объединять окружения и состояние клиентов.
local T = ...

local function Loader(source)
	local calls = {}
	local env = setmetatable({ loadfile = function(path)
		calls[path] = (calls[path] or 0) + 1
		if source then return loadstring(source, "@" .. path) end
		return loadfile(path)
	end }, { __index = _G })
	local chunk = assert(loadfile(T.ROOT .. "/tests/lib.lua"))
	setfenv(chunk, env)
	local loader = chunk()
	loader.ROOT = T.ROOT
	return loader, calls
end

T.test("loader: файл компилируется один раз, состояние и окружения остаются отдельными", function()
	local loader, calls = Loader()
	local a = loader.load({ "Config.lua", "Util.lua" }, setmetatable({
		GetRealmName = function() return "FirstRealm" end,
	}, { __index = _G }))
	local b = loader.load({ "Config.lua", "Util.lua" }, setmetatable({
		GetRealmName = function() return "SecondRealm" end,
	}, { __index = _G }))
	T.eq(calls[T.ROOT .. "/Chillzone/Config.lua"], 1, "повторная компиляция Config.lua")
	T.eq(calls[T.ROOT .. "/Chillzone/Util.lua"], 1, "повторная компиляция Util.lua")
	T.no(a.Config == b.Config, "таблицы настроек независимы")
	a.Config.MAIN_GUILD = "Первая"
	b.Config.MAIN_GUILD = "Вторая"
	T.ok(a.Util.IsMainGuild("Первая"), "замыкание первого клиента")
	T.ok(b.Util.IsMainGuild("Вторая"), "замыкание второго клиента")
	T.eq(a.Util.CurrentRealm(), "FirstRealm", "глобалы первого клиента")
	T.eq(b.Util.CurrentRealm(), "SecondRealm", "глобалы второго клиента")
end)

T.test("loader: кэш различает полные пути при смене корня", function()
	local loader, calls = Loader("local _, ns = ...; ns.loaded = true")
	loader.ROOT = "first"
	T.ok(loader.load({ "Config.lua" }).loaded)
	loader.ROOT = "second"
	T.ok(loader.load({ "Config.lua" }).loaded)
	loader.ROOT = "first"
	T.ok(loader.load({ "Config.lua" }).loaded)
	T.eq(calls["first/Chillzone/Config.lua"], 1)
	T.eq(calls["second/Chillzone/Config.lua"], 1)
end)

T.test("loader: вложенная загрузка и ошибка не меняют окружение внешнего вызова", function()
	local loader, calls = Loader([[
		local _, ns = ...
		local env = getfenv(1)
		if env.nested then env.nested() end
		if env.fail then error("ошибка загрузки") end
		ns.value = getfenv(1).value
	]])
	local path = T.ROOT .. "/Chillzone/probe.lua"
	local function Load(env)
		return loader.load({ "probe.lua" }, setmetatable(env, { __index = _G }))
	end
	local outer = Load({ value = "внешний", nested = function()
		T.eq(Load({ value = "внутренний" }).value, "внутренний")
		local ok, err = pcall(Load, { fail = true })
		T.no(ok, "ошибка передаётся вызывающему коду")
		T.ok(tostring(err):find("ошибка загрузки", 1, true))
	end })
	T.eq(outer.value, "внешний", "окружение восстановлено после вложенных вызовов")
	T.eq(Load({ value = "следующий" }).value, "следующий", "повтор после ошибки")
	T.eq(calls[path], 1, "успешно скомпилированная функция остаётся в кэше")
end)
