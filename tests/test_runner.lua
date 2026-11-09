-- Разбиение обязано сохранять полный набор и код ошибки каждого процесса.
local T = ...

local function Runner(options, fail)
	local seen, output = {}, {}
	local env = setmetatable({
		os = { getenv = function(name) return options[name] end },
		io = { write = function(...)
			for i = 1, select("#", ...) do output[#output + 1] = tostring(select(i, ...)) end
		end },
	}, { __index = _G })
	local chunk = assert(loadfile(T.ROOT .. "/tests/lib.lua"))
	setfenv(chunk, env)
	local runner = chunk()
	for i = 1, 10 do
		local id = i
		runner.test((i % 2 == 1 and "keep" or "other") .. i, function()
			seen[#seen + 1] = id
			if id == fail then error("проверка ошибки части") end
		end)
	end
	return runner, seen, output
end

T.test("runner: обычный запуск выполняет все тесты по порядку", function()
	local runner, seen = Runner({})
	T.ok(runner.run())
	T.same(seen, { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 })
end)

T.test("runner: четыре части выполняют каждый тест ровно один раз", function()
	local all = {}
	local expected = { { 1, 5, 9 }, { 2, 6, 10 }, { 3, 7 }, { 4, 8 } }
	for index = 1, 4 do
		local runner, seen = Runner({ CZ_TEST_SHARD_INDEX = tostring(index), CZ_TEST_SHARD_COUNT = "4" })
		T.ok(runner.run())
		T.same(seen, expected[index])
		for _, id in ipairs(seen) do all[id] = (all[id] or 0) + 1 end
	end
	for id = 1, 10 do T.eq(all[id], 1, "тест " .. id) end
end)

T.test("runner: фильтр совместим с частями и пустая часть успешна", function()
	local runner, seen = Runner({ CZ_TEST_SHARD_INDEX = "1", CZ_TEST_SHARD_COUNT = "4", CZ_TEST_FILTER = "keep" })
	T.ok(runner.run())
	T.same(seen, { 1, 5, 9 })
	runner, seen = Runner({ CZ_TEST_SHARD_INDEX = "2", CZ_TEST_SHARD_COUNT = "4", CZ_TEST_FILTER = "keep" })
	T.ok(runner.run())
	T.eq(#seen, 0)
end)

T.test("runner: ошибка влияет только на часть, содержащую упавший тест", function()
	local runner, seen, output = Runner({ CZ_TEST_SHARD_INDEX = "1", CZ_TEST_SHARD_COUNT = "4" }, 5)
	T.no(runner.run())
	T.same(seen, { 1, 5, 9 }, "после ошибки часть продолжает проверки")
	T.eq(runner.failed, 1)
	T.ok(table.concat(output):find("FAIL keep5", 1, true))
	runner = Runner({ CZ_TEST_SHARD_INDEX = "2", CZ_TEST_SHARD_COUNT = "4" }, 5)
	T.ok(runner.run(), "ошибка другой части не запускается")
end)

T.test("runner: неверные и неполные параметры частей отклоняются", function()
	for _, pair in ipairs({ { "1" }, { false, "4" }, { "0", "4" }, { "5", "4" },
		{ "1", "0" }, { "1.5", "4" }, { "1", "2.5" }, { "bad", "4" }, { "1", "" } }) do
		local runner, seen = Runner({ CZ_TEST_SHARD_INDEX = pair[1] or nil, CZ_TEST_SHARD_COUNT = pair[2] })
		T.no(pcall(runner.run), "неверные параметры не дают зелёный прогон")
		T.eq(#seen, 0, "ошибка обнаружена до выполнения тестов")
	end
end)
