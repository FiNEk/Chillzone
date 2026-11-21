-- Реалм, который игра не назвала (Forever с 19–20.11.2026: пустые GetNormalizedRealmName и
-- GetRealmName при входе). Группа реалмов входит в каждую подпись, поэтому группа «?» выбивала
-- клиента из доверия своей гильдии: новое хранилище, новый ключ, сертификаты не сходятся.
local T = ...
local Wow = assert(loadfile(T.ROOT .. "/tests/wow.lua"))(T)

local PVP = "CAMWOWUS2Realm7PvP"

-- Корень доверия — офицер, а не глава, как в настоящей главной гильдии.
local function Build()
    local w = Wow.World()
    w:Guild("Чиллзон")
    local c = {}
    c.K = w:Client({ first = "Король", surname = "Первый", guild = "Чиллзон", rank = 0, realm = PVP })
    c.O = w:Client({ first = "Офицер", surname = "Корневой", guild = "Чиллзон", rank = 1, realm = PVP })
    c.M = w:Client({ first = "Мира", surname = "Тихая", guild = "Чиллзон", rank = 3, realm = PVP })
    w:Run(30)
    w:Init(c.O)
    w:Run(120)
    T.ok(c.M.ns.Security.MyCertificate(), "до поломки у Миры есть сертификат")
    return w, c
end

local function Errors(c)
    for name, client in pairs(c) do
        T.eq(#client.ns.db.errors, 0, name .. ": " .. table.concat(client.ns.db.errors, " | "))
        T.eq(#client:Leaks(), 0, name .. ": глобалы")
    end
end

-- Перезаход, после которого игра перестала называть реалм.
local function Hide(w, c, name)
    c[name].hideRealm = true
    c[name] = w:Reload(c[name])
    w:Run(1) -- открытый ключ восстанавливается асинхронно
    return c[name]
end

T.test("realm: без реалма клиент остаётся в своей группе — тот же ключ, хранилище и сертификат", function()
    local w, c = Build()
    local db, before = c.M.ns.db, c.M.ns.Security.MyCertificate()
    T.eq(c.M.ns.char.group, "ForeverPvP", "группа запомнена при известном реалме")
    local store = db.realms.ForeverPvP.Alliance
    local M = Hide(w, c, "M")
    T.eq(M.ns.realm, "?", "игра реалм не назвала")
    T.eq(M.ns.group, "ForeverPvP", "группа — прежняя")
    T.ok(M.ns.store == store, "хранилище — прежнее")
    T.no(db.realms["?"], "хранилища «?» нет")
    local mine = M.ns.Security.MyCertificate()
    T.ok(mine and mine.public == before.public, "ключ и сертификат прежние сразу после входа")
    -- Корень тоже без реалма: выдача и подписи продолжают работать.
    local O = Hide(w, c, "O")
    T.eq(O.ns.group, "ForeverPvP", "у корня — та же группа")
    T.ok(O.ns.Security.Roots()[O.ns.Util.GuildKey("Чиллзон")], "у корня есть корень своей гильдии")
    w:Run(60)
    M:Slash("/cz1", "строка без реалма")
    w:Run(40)
    T.eq(c.K:Saw("строка без реалма"), 1, "подписанная строка дошла до клиента с реалмом")
    T.ok(table.concat(M.ns.db.log, "|"):find("игра не назвала реалм: группа ForeverPvP взята из персонажа", 1, true),
        "причина в журнале")
    Errors(c)
end)

T.test("realm: сохранения до правки — группа по ключу подписи, данные группы «?» удаляются", function()
    local w, c = Build()
    local db, key = c.M.ns.db, c.M.ns.myKey
    local before = c.M.ns.Security.MyCertificate()
    -- Так оставляла сохранения версия без правки: группа не запомнена, после входа без реалма
    -- заведены хранилище «?» и ключ «?». Ключ другой группы старше — его не берём.
    db.chars[key].group = nil
    db.realms["?"] = { Alliance = { security = { version = 1, roots = {}, certs = {}, policies = {} } } }
    db.securityKeys["?:Alliance:" .. key] = { seed = "AAAA", sequence = 9e15 }
    db.securityKeys["ForeverPvE:Alliance:" .. key] = { seed = "BBBB", sequence = 1 }
    local M = Hide(w, c, "M")
    T.eq(M.ns.group, "ForeverPvP", "группа — по самому свежему ключу персонажа")
    T.eq(M.ns.groupFrom, "ключа подписи", "откуда взята группа")
    T.no(db.realms["?"], "хранилище «?» удалено")
    T.no(db.securityKeys["?:Alliance:" .. key], "ключ «?» удалён")
    T.ok(db.securityKeys["ForeverPvE:Alliance:" .. key], "ключи других групп не тронуты")
    local mine = M.ns.Security.MyCertificate()
    T.ok(mine and mine.public == before.public, "сертификат прежний")
    T.no(M.ns.char.group, "без реалма группа не запоминается")
    Errors(c)
end)

T.test("realm: новый персонаж без реалма и сохранений — группа главной гильдии, сертификат от корня", function()
    local w, c = Build()
    c.N = w:Client({ first = "Новичок", surname = "Свежий", guild = "Чиллзон", rank = 3, realm = PVP, hideRealm = true })
    T.eq(c.N.ns.group, c.N.ns.Config.HOME_GROUP, "группа главной гильдии")
    for _, other in pairs(c) do other.ns.Roster.Scan() end
    w:Run(120)
    T.ok(c.N.ns.Security.MyCertificate(), "корень с реалмом выдал сертификат новичку без реалма")
    Errors(c)
end)
