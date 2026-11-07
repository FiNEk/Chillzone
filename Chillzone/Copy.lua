-- Chillzone: окно копирования — отчёт об ошибке, профайлер, журнал действий доверия. Строку чата игры скопировать нельзя, поэтому текст стоит в своём многострочном поле
-- только для чтения. Поле не берёт клавиатуру при показе (SetAutoFocus(false)), фокус — по
-- щелчку или кнопке «Выделить всё», Escape отпускает его. Поле ввода чата игры не трогается.
-- Как окно копирования Olympus (UI.ShowCopy).
local ADDON, ns = ...

local L = ns.L
local UI = ns.UI

local WIDTH, HEIGHT = 640, 440
local frame

local function Make()
	local ok, f = pcall(CreateFrame, "Frame", "ChillzoneCopyFrame", UIParent, "BasicFrameTemplateWithInset")
	if not ok or not f then f = CreateFrame("Frame", "ChillzoneCopyFrame", UIParent) end
	f:SetSize(WIDTH, HEIGHT)
	f:SetPoint("CENTER", 0, 30)
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	local title = f.TitleText or f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	if not f.TitleText then title:SetPoint("TOP", 0, -6) end
	f.title = title
	local close = f.CloseButton or rawget(_G, "ChillzoneCopyFrameCloseButton")
	if close then close:SetScript("OnClick", function() f:Hide() end) end
	tinsert(UISpecialFrames, "ChillzoneCopyFrame")

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -30)
	scroll:SetPoint("BOTTOMRIGHT", -32, 44)
	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	edit:SetFontObject(ChatFontNormal)
	edit:SetWidth(WIDTH - 50)
	edit:EnableMouse(true)
	scroll:SetScrollChild(edit)
	-- Только чтение: набранное откатывается к показанному тексту.
	edit:SetScript("OnTextChanged", function(self, user)
		if user and self:GetText() ~= f.text then self:SetText(f.text or "") end
	end)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)
	-- Щелчок по пустому месту под текстом — тоже фокус.
	scroll:EnableMouse(true)
	scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
	f.scroll, f.edit = scroll, edit

	local all = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	all:SetSize(130, 22)
	all:SetPoint("BOTTOMLEFT", 12, 14)
	all:SetText(L.COPY_SELECT_ALL)
	all:SetScript("OnClick", function() UI.SelectCopy() end)
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("LEFT", all, "RIGHT", 10, 0)
	hint:SetText(L.COPY_HINT)
	f.all, f.hint = all, hint
	f.actions = {}
	return f
end

local function ActionButton(f, i)
	local b = f.actions[i]
	if b then return b end
	b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(170, 22)
	if i == 1 then
		b:SetPoint("BOTTOMRIGHT", -14, 14)
	else
		b:SetPoint("RIGHT", f.actions[i - 1], "LEFT", -6, 0)
	end
	f.actions[i] = b
	return b
end

-- Окно с текстом text. opts.actions — до двух кнопок справа внизу: { label, fn, tip }.
function UI.ShowCopy(title, text, opts)
	opts = opts or {}
	frame = frame or Make()
	UI.copy = frame
	text = tostring(text or "")
	frame.text, frame.heading = text, tostring(title or "Chillzone")
	frame.title:SetText(frame.heading)
	frame.edit:SetText(text)
	frame.edit:SetCursorPosition(0)
	frame.edit:ClearFocus()
	local actions = opts.actions or {}
	for i = 1, math.max(#actions, #frame.actions) do
		local a = actions[i]
		local b = ActionButton(frame, i)
		if a then
			b:SetText(a.label)
			b:SetScript("OnClick", function() ns.SafeCall("copy action", a.fn) end)
			b:Show()
		else
			b:Hide()
		end
	end
	frame:Show()
	if frame.scroll.SetVerticalScroll then frame.scroll:SetVerticalScroll(0) end
	return frame
end

-- «Выделить всё»: фокус в поле и весь текст выделен — остаётся Ctrl+C.
function UI.SelectCopy()
	if not frame then return end
	frame.edit:SetFocus()
	frame.edit:HighlightText()
end

function UI.HideCopy()
	if frame then frame:Hide() end
end
