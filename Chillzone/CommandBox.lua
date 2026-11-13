-- Chillzone: поле с готовой командой игры (/gremove, /ginvite) для «Кадров» и «Заявок».
-- Forever не даёт ни аддону, ни макросу исключать и приглашать в гильдию: команду вводит сам
-- игрок в чате игры. Поле — своё: поле ввода чата игры аддон не трогает (taint), игрок
-- копирует команду (Ctrl+C) и вставляет её сам. Итог владелец поля узнаёт по системным строкам
-- гильдии и ростеру (Roster.GuildEvent), здесь только показ.
local ADDON, ns = ...
local L = ns.L

local Box = { HEIGHT = 40 }
ns.CommandBox = Box

local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("команда: щелчок", fn) end)
	return b
end

-- Поле на parent шириной width; место ему задаёт владелец (SetPoint). onSkip — «Пропустить»
-- (виден, только когда Open передал progress), onClose — «Закрыть».
function Box.New(parent, width, onSkip, onClose)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(width, Box.HEIGHT)
	f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	f.title:SetPoint("TOPLEFT", 4, 0)
	f.title:SetPoint("RIGHT", -4, 0)
	f.title:SetJustifyH("LEFT")
	f.title:SetWordWrap(false)
	local edit = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
	edit:SetSize(250, 22)
	edit:SetPoint("TOPLEFT", 10, -16)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(80)
	f.edit = edit
	f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	f.hint:SetPoint("LEFT", edit, "RIGHT", 10, 0)
	f.hint:SetJustifyH("LEFT")
	f.close = Button(f, L.COMMAND_CLOSE, 90, function()
		f:Close()
		if onClose then onClose() end
	end)
	f.close:SetPoint("TOPRIGHT", -4, -16)
	f.skip = Button(f, L.COMMAND_SKIP, 100, function() if onSkip then onSkip() end end)
	f.skip:SetPoint("RIGHT", f.close, "LEFT", -6, 0)
	f.hint:SetPoint("RIGHT", f.skip, "LEFT", -8, 0)
	-- Поле только для чтения: набранное заменяется командой, выделенной для копирования.
	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput and f.command and self:GetText() ~= f.command then
			self:SetText(f.command)
			self:HighlightText()
		end
	end)
	edit:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- После Ctrl+C фокус уходит из поля: следующий Enter уже открывает чат игры.
	edit:SetScript("OnKeyDown", function(self, key)
		if key == "C" and IsControlKeyDown and IsControlKeyDown() then
			f.hint:SetText(L.COMMAND_COPIED)
			ns.After(0.05, "команда скопирована", function() self:ClearFocus() end)
		end
	end)
	edit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine(f.title:GetText() or "", 1, 0.82, 0, true)
		GameTooltip:AddLine(f.tip or L.COMMAND_TIP, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	edit:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- Показать команду: title — что сделать, progress — «2 из 5» для очереди, tip — подсказка
	-- с запасным путём через окно гильдии. Фокус — только в видимом окне: очередь идёт дальше и
	-- при закрытом, а скрытое поле не должно забирать клавиатуру.
	function f.Open(self, title, command, progress, tip)
		self.command, self.tip = command, tip
		self.title:SetText(progress and (title .. "  |cffffffff" .. progress .. "|r") or title)
		self.hint:SetText(L.COMMAND_HINT)
		self.skip:SetShown(progress ~= nil and onSkip ~= nil)
		self:Show()
		self.edit:SetText(command)
		if self:IsVisible() then
			self.edit:SetFocus()
			self.edit:HighlightText()
		end
	end
	function f.Close(self)
		self.edit:ClearFocus()
		self.command = nil
		self:Hide()
	end
	function f.Command(self) return self:IsShown() and self.command or nil end
	f:Hide()
	return f
end

