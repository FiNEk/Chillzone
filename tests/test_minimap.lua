-- Настоящие LibDataBroker и LibDBIcon: регистрация, миграция и действия кнопки.
local T = ...

local LIBS = {
	"libs/LibStub/LibStub.lua",
	"libs/CallbackHandler-1.0/CallbackHandler-1.0.lua",
	"libs/LibDataBroker-1.1/LibDataBroker-1.1.lua",
	"libs/LibDBIcon-1.0/LibDBIcon-1.0.lua",
}

local function Harness(saved, loginFirst)
	local h = { named = {}, frames = {}, events = {}, commands = {}, errors = {}, cursor = { 0, 0 } }
	local methods = {}
	local function Noop() end
	local function Frame(parent, name)
		local f = setmetatable({ parent = parent, scripts = {}, shown = true, width = 140, height = 140 }, {
			__index = function(_, key) return methods[key] or Noop end,
		})
		h.frames[#h.frames + 1] = f
		if name then h.named[name] = f end
		return f
	end
	function methods:SetScript(event, fn) self.scripts[event] = fn end
	function methods:GetScript(event) return self.scripts[event] end
	function methods:HookScript(event, fn)
		local old = self.scripts[event]
		self.scripts[event] = function(...)
			if old then old(...) end
			fn(...)
		end
	end
	function methods:RegisterEvent(event) self.event = event end
	function methods:GetParent() return self.parent end
	function methods:CreateTexture() return Frame(self) end
	function methods:CreateAnimationGroup() return Frame(self) end
	function methods:CreateAnimation() return Frame(self) end
	function methods:GetVertexColor() return 1, 1, 1 end
	function methods:SetTexCoord(...) self.coords = { ... } end
	function methods:SetTexture(texture) self.texture = texture end
	function methods:SetSize(w, height) self.width, self.height = w, height end
	function methods:GetWidth() return self.width end
	function methods:GetHeight() return self.height end
	function methods:GetCenter() return 0, 0 end
	function methods:GetEffectiveScale() return 1 end
	function methods:SetPoint(...) self.point = { ... } end
	function methods:Show() self.shown = true end
	function methods:Hide() self.shown = false end
	function methods:SetShown(on) self.shown = on end
	function methods:IsShown() return self.shown end
	function methods:SetOwner(owner) self.owner = owner end
	local env = setmetatable({}, { __index = _G })
	env._G = env
	env.UIParent, env.Minimap = Frame(), Frame()
	env.GameTooltip = Frame()
	env.CreateFrame = function(_, name, parent) return Frame(parent, name) end
	env.GetCursorPosition = function() return unpack(h.cursor) end
	env.geterrorhandler = function() return function(err) error(err) end end
	local ns = {
		Util = {}, db = { settings = { minimap = saved or { angle = 200, hide = false }, showMap = true } },
		On = function(event, fn) h.events[event] = fn end,
		Command = function(command, fn) h.commands[command] = fn end,
		Print = Noop,
		SafeCall = function(_, fn, ...)
			local ok, err = pcall(fn, ...)
			if not ok then h.errors[#h.errors + 1] = err end
		end,
		Views = { MinimapTip = function(tt) h.tip = tt end },
	}
	ns.Map = { SetEnabled = function(on) ns.db.settings.showMap = on end }
	T.load(LIBS, env, ns)
	h.lib, h.ldb = env.LibStub("LibDBIcon-1.0"), env.LibStub("LibDataBroker-1.1")
	local function LibraryLogin()
		for _, f in ipairs(h.frames) do
			if f.event == "PLAYER_LOGIN" and f.scripts.OnEvent then f.scripts.OnEvent(f) end
		end
	end
	if loginFirst then LibraryLogin() end
	T.load({ "Locale.lua", "UI.lua" }, env, ns)
	h.toggles = 0
	ns.UI.Toggle = function() h.toggles = h.toggles + 1 end
	h.events.LOGIN()
	if not loginFirst then LibraryLogin() end
	h.ns, h.env = ns, env
	h.button = h.lib:GetMinimapButton("Chillzone")
	return h
end

T.test("minimap: зависимости включены в toc до интерфейса", function()
	local positions = {}
	for i, file in ipairs(T.tocFiles()) do positions[file] = i end
	for i, file in ipairs(LIBS) do
		T.ok(positions[file], "нет библиотеки в toc: " .. file)
		T.ok(positions[file] < positions["UI.lua"], "библиотека после UI.lua")
		if i > 1 then T.ok(positions[LIBS[i - 1]] < positions[file], "порядок зависимостей") end
	end
end)

T.test("minimap: стандартная кнопка и launcher без дублей при повторном обновлении", function()
	for _, loginFirst in ipairs({ false, true }) do
		local h = Harness(nil, loginFirst)
		T.ok(h.button, "кнопка не зарегистрирована в LibDBIcon")
		T.eq(h.named.ChillzoneMinimapButton, nil, "самописной кнопки больше нет")
		T.eq(h.named.LibDBIcon10_Chillzone, h.button)
		local obj = h.ldb:GetDataObjectByName("Chillzone")
		T.eq(obj.type, "launcher")
		T.eq(obj.label, "Chillzone")
		T.eq(obj.icon, "Interface\\AddOns\\Chillzone\\media\\icon")
		T.eq(h.button.dataObject, obj)
		T.eq(h.button.db, h.ns.db.settings.minimap)
		h.ns.UI.UpdateMinimapButton()
		h.events.LOGIN()
		T.eq(h.lib:GetMinimapButton("Chillzone"), h.button)
		T.eq(#h.lib:GetButtonList(), 1)
	end
end)

T.test("minimap: прежний угол переносится, перетаскивание и перезагрузка сохраняют новый", function()
	local saved = { angle = -45, hide = false }
	local h = Harness(saved)
	T.ok(h.button, "кнопка LibDBIcon")
	T.eq(saved.minimapPos, -45)
	T.eq(h.button.point[2], h.env.Minimap)
	h.cursor = { 0, 75 }
	h.button.scripts.OnDragStart(h.button)
	h.button.scripts.OnUpdate(h.button)
	h.button.scripts.OnDragStop(h.button)
	T.eq(h.button.scripts.OnUpdate, nil)
	T.eq(saved.minimapPos, 90)
	h.ns.UI.UpdateMinimapButton()
	T.eq(saved.minimapPos, 90, "старый angle не затирает перетаскивание")
	local reload = Harness(saved)
	T.eq(reload.button.db.minimapPos, 90)
	T.ok(math.abs(reload.button.point[4]) < 0.00001)
	T.eq(reload.button.point[5], 75)
	T.eq(Harness({ minimapPos = 0, angle = 200 }).button.db.minimapPos, 0, "нулевой угол сохранён")
	T.eq(Harness({}).button.db.minimapPos, 200, "угол по умолчанию")
end)

T.test("minimap: скрытие из настроек и команды сохраняется после перезагрузки", function()
	local saved = { angle = 123, hide = true }
	local h = Harness(saved)
	T.ok(h.button, "кнопка LibDBIcon")
	T.no(h.button:IsShown())
	h.commands.minimap()
	T.no(saved.hide)
	T.ok(h.button:IsShown())
	saved.hide = true
	h.ns.UI.UpdateMinimapButton()
	T.no(h.button:IsShown())
	T.no(Harness(saved).button:IsShown())
	h.commands.minimap()
	T.ok(h.button:IsShown())
	T.eq(saved.minimapPos, 123)
end)

T.test("minimap: клики и подсказка работают через LibDBIcon и сам launcher", function()
	local h = Harness()
	T.ok(h.button, "кнопка LibDBIcon")
	h.button.scripts.OnClick(h.button, "LeftButton")
	T.eq(h.toggles, 1)
	h.button.scripts.OnClick(h.button, "RightButton")
	T.no(h.ns.db.settings.showMap)
	local obj = h.ldb:GetDataObjectByName("Chillzone")
	obj.OnClick({}, "RightButton")
	T.ok(h.ns.db.settings.showMap)
	h.button.scripts.OnEnter(h.button)
	T.eq(h.tip, h.lib.tooltip)
	T.ok(h.tip:IsShown())
	h.button.scripts.OnLeave(h.button)
	T.no(h.tip:IsShown())
	obj.OnTooltipShow(h.env.GameTooltip)
	T.eq(h.tip, h.env.GameTooltip, "подсказка в сторонней панели")
	h.ns.Views.MinimapTip = function() error("ошибка подсказки") end
	obj.OnTooltipShow(h.env.GameTooltip)
	T.eq(#h.errors, 1, "ошибка остаётся в SafeCall")
end)
