-- Chillzone: экран вступления, собственное окно письма и отдельная вкладка заявок.
-- Порядок действий — из Olympus Recruit.lua (MIT); игровые popup и поле чата не трогаем.
local ADDON, ns = ...

local L, U, R = ns.L, ns.Util, ns.Recruit
local Pane = { frames = {}, requestRows = {}, guildRows = {} }
ns.RecruitPane = Pane
local guildRows, replyRows = Pane.guildRows, {}
local pane, child, intro, note, inbox, inboxChild, inboxHint, inboxEmpty, inboxBox
local wide = 0 -- насколько вставка шире исходной: столько же получают строки и тексты (Pane.Layout)

local function Label(parent, x, y, width, font)
	local f = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	f:SetPoint("TOPLEFT", x, -y)
	f:SetWidth(width)
	f:SetJustifyH("LEFT")
	return f
end
local function Button(parent, text, width, fn)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(width, 22)
	b:SetText(text)
	b:SetScript("OnClick", function() ns.SafeCall("заявки: щелчок", fn) end)
	return b
end

function Pane.Build(parent)
	pane = CreateFrame("Frame", nil, parent)
	pane:SetAllPoints(parent)
	Label(pane, 16, 12, 720, "GameFontNormalLarge"):SetText(L.RECRUIT_TITLE)
	-- Вступление бывает в одну строку и в три (гильдия не в объединении): кнопка и список под ним.
	intro = Label(pane, 16, 40, 740)
	intro:SetText(L.RECRUIT_INTRO)
	local search = Button(pane, L.RECRUIT_SEARCH, 190, function() R.Search() end)
	search:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
	note = Label(pane, 0, 0, 530)
	note:ClearAllPoints()
	note:SetPoint("LEFT", search, "RIGHT", 16, 0)
	local scroll = CreateFrame("ScrollFrame", nil, pane, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -12)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	child = CreateFrame("Frame", nil, scroll)
	child:SetSize(740, 10)
	scroll:SetScrollChild(child)
	Pane.frames.pane, Pane.frames.intro, Pane.frames.search, Pane.frames.note = pane, intro, search, note
	pane:Hide()
	return pane
end

-- Строка под названием гильдии: офицеры в игре (первые несколько) и свободные места.
local function GuildLine(g)
	local names = {}
	for i = 1, math.min(#g.officers, R.OFFICERS_SHOWN) do names[i] = U.Display(g.officers[i].name) end
	local list = #names > 0 and table.concat(names, ", ") or L.RECRUIT_OFFICERS_UNKNOWN
	if #g.officers > R.OFFICERS_SHOWN then list = L.RECRUIT_OFFICERS_MORE:format(list, #g.officers - R.OFFICERS_SHOWN) end
	return L.RECRUIT_GUILD:format(list, g.free and tostring(g.free) or "?")
end

-- Почему в гильдию сейчас некому написать: мест нет, всем офицерам уже написали или их не видно.
local function Unavailable(guild, officers)
	if not R.HasSpace(guild) then return L.RECRUIT_NO_PLACES end
	return officers > 0 and L.RECRUIT_NOBODY or L.RECRUIT_NO_OFFICERS
end

-- Кнопка поиска показывает, когда сервер примет следующий /who. Окно зовёт это по тику.
function Pane.RenderSearch()
	local search = Pane.frames.search
	if not search then return end
	local wait, busy = ns.Who.Wait(), ns.Who.IsPending()
	search:SetEnabled(not busy and wait <= 0)
	if busy then search:SetText(L.RECRUIT_SEARCHING)
	elseif wait > 0 then search:SetText(L.RECRUIT_SEARCH_IN:format(math.ceil(wait)))
	else search:SetText(L.RECRUIT_SEARCH) end
end

function Pane.Render()
	if not pane then return end
	Pane.RenderSearch()
	-- Экран виден только вне объединения. Игрок в гильдии должен понять, что его гильдия
	-- не подключена, а не что аддон сломался, и знать, кто её подключает.
	local own = ns.MyGuild()
	intro:SetText(own and L.RECRUIT_UNCONNECTED:format(own) or L.RECRUIT_INTRO)
	local guilds, y = R.Guilds(), 0
	local action, _, hint = R.NextSearch()
	local open = false
	for _, g in ipairs(guilds) do open = open or g.free ~= 0 end
	if ns.Who.IsPending() then note:SetText(L.RECRUIT_SEARCHING)
	elseif action == "guild" then note:SetText(L.RECRUIT_GUILD_NEXT:format(hint.name, hint.free))
	elseif action == "verify" then note:SetText(L.RECRUIT_VERIFY_NEXT:format(hint.name, hint.free))
	elseif #guilds == 0 then note:SetText(L.RECRUIT_EMPTY)
	elseif ns.Who.missing then note:SetText(L.RECRUIT_MORE_SEARCH)
	else note:SetText(open and L.RECRUIT_SEARCH_DONE or L.RECRUIT_ALL_FULL) end
	for i, g in ipairs(guilds) do
		local row = guildRows[i]
		if not row then
			row = CreateFrame("Frame", nil, child)
			row:SetSize(730 + wide, 54)
			row.title = Label(row, 0, 1, 480 + wide, "GameFontNormal")
			row.sub = Label(row, 0, 23, 480 + wide)
			row.ask = Button(row, L.RECRUIT_ASK, 210, function()
				local p = R.NextContact(row.guild)
				if p then R.Prompt(p) else ns.Print(Unavailable(row.guild, #R.Officers(row.guild))) end
			end)
			row.ask:SetPoint("TOPRIGHT", 0, -5)
			guildRows[i] = row
		end
		row.guild = g.name
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
		row.title:SetText(ns.Codec.Plain(g.name))
		row.sub:SetText(GuildLine(g))
		local contact = R.NextContact(g.name)
		row.ask:SetText(contact and L.RECRUIT_ASK or Unavailable(g.name, #g.officers))
		row.ask:SetEnabled(contact ~= nil)
		row:Show()
		y = y + 54
	end
	for i = #guilds + 1, #guildRows do guildRows[i]:Hide() end
	local replies = {}
	for key, text in pairs(R.replied) do replies[#replies + 1] = { key = key, text = text } end
	table.sort(replies, function(a, b) return a.key < b.key end)
	for i, reply in ipairs(replies) do
		local label = replyRows[i] or Label(child, 0, 0, 725 + wide)
		replyRows[i] = label
		label:ClearAllPoints()
		label:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y)
		label:SetText(L.RECRUIT_REPLY:format(R.replyNames[reply.key] or reply.key, reply.text))
		label:SetTextColor(0.4, 1, 0.4)
		label:Show()
		y = y + math.max(36, label:GetStringHeight() or 0) + 6
	end
	for i = #replies + 1, #replyRows do replyRows[i]:Hide() end
	child:SetHeight(math.max(10, y))
end
function Pane.Show() if pane then pane:Show(); Pane.Render() end end
function Pane.Hide() if pane then pane:Hide() end; R.Cancel() end

function Pane.CloseDialog()
	local d = Pane.frames.dialog
	if d then d:Hide() end
end
function Pane.ShowDialog(contact, message)
	local f = Pane.frames
	if not f.dialog then
		local d = CreateFrame("Frame", "ChillzoneRecruitDialog", UIParent, "BasicFrameTemplateWithInset")
		d:SetSize(480, 226)
		d:SetPoint("CENTER")
		d:SetFrameStrata("DIALOG")
		if d.TitleText then d.TitleText:SetText(L.RECRUIT_TITLE) end
		f.to = Label(d, 16, 36, 448, "GameFontNormal")
		local box = CreateFrame("EditBox", nil, d)
		box:SetMultiLine(true)
		box:SetAutoFocus(false)
		box:SetFontObject("ChatFontNormal")
		box:SetTextInsets(6, 6, 6, 6)
		box:SetSize(448, 94)
		box:SetPoint("TOPLEFT", 16, -62)
		box:SetMaxBytes(250)
		local bg = box:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		bg:SetColorTexture(0, 0, 0, 0.55)
		local function Send()
			if R.pending then R.Ask(R.pending, box:GetText()) end
		end
		f.send = Button(d, L.RECRUIT_SEND, 120, Send)
		f.send:SetPoint("BOTTOMRIGHT", -148, 16)
		local cancel = Button(d, L.RECRUIT_CANCEL, 120, R.Cancel)
		cancel:SetPoint("BOTTOMRIGHT", -16, 16)
		box:SetScript("OnEscapePressed", R.Cancel)
		box:SetScript("OnEnterPressed", Send)
		d:SetScript("OnHide", function() R.pending = nil; box:ClearFocus() end)
		table.insert(UISpecialFrames, "ChillzoneRecruitDialog")
		f.dialog, f.box = d, box
	end
	f.to:SetText(L.RECRUIT_TO:format(U.Display(contact.name), contact.guild))
	f.box:SetText(message)
	f.dialog:Show()
	f.box:SetFocus()
end

function Pane.BuildInbox(parent)
	inbox = CreateFrame("Frame", nil, parent)
	inbox:SetAllPoints(parent)
	inboxHint = Label(inbox, 16, 14, 570)
	-- Команда /ginvite встаёт на место подсказки: игра не даёт аддону приглашать.
	inboxBox = ns.CommandBox.New(inbox, 740, function() Pane.RenderInbox() end)
	inboxBox:SetPoint("TOPLEFT", 8, -8)
	local scroll = CreateFrame("ScrollFrame", nil, inbox, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -58)
	scroll:SetPoint("BOTTOMRIGHT", -30, 12)
	inboxChild = CreateFrame("Frame", nil, scroll)
	inboxChild:SetSize(740, 10)
	scroll:SetScrollChild(inboxChild)
	inboxEmpty = Label(inboxChild, 0, 12, 730, "GameFontDisable")
	inboxEmpty:SetText(L.RECRUIT_INBOX_EMPTY)
	inbox:SetScript("OnShow", function() ns.RecruitSync.RequestSync() end)
	Pane.frames.inbox, Pane.frames.inboxEmpty, Pane.frames.inboxBox = inbox, inboxEmpty, inboxBox
	inbox:Hide()
end

function Pane.RenderInbox()
	if not inbox then return end
	local reqs = {}
	for _, req in ipairs(R.Requests()) do reqs[#reqs + 1] = req end
	table.sort(reqs, function(a, b)
		if a.t ~= b.t then return a.t > b.t end
		return a.name < b.name
	end)
	local shared = ns.RecruitSync.IsOfficer()
	inboxHint:SetText(shared and (R.CanInvite() and L.RECRUIT_INBOX_SHARED or L.RECRUIT_INBOX_NO_INVITE) or L.RECRUIT_INBOX_PERSONAL)
	-- Новичок вступил или заявку закрыли: команда больше не нужна.
	local open = inboxBox:IsShown() and inboxBox.req
	if open then
		local still = false
		for _, req in ipairs(reqs) do if req == open then still = true end end
		if not still then
			inboxBox.req = nil
			inboxBox:Stop()
		end
	end
	inboxHint:SetShown(not inboxBox:IsShown())
	inboxEmpty:SetShown(#reqs == 0)
	local y = 0
	for count, req in ipairs(reqs) do
		local row = Pane.requestRows[count]
		if not row then
			row = CreateFrame("Frame", nil, inboxChild)
			row:SetSize(730 + wide, 98)
			row:EnableMouse(true)
			row:SetScript("OnEnter", function(self)
				if not self.req then return end
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(L.RECRUIT_TO:format(U.Display(self.req.name), self.req.guild), 1, 0.82, 0, true)
				GameTooltip:AddLine(self.req.text or L.RECRUIT_NO_TEXT, 1, 1, 1, true)
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", function() GameTooltip:Hide() end)
			row.title = Label(row, 0, 0, 730 + wide, "GameFontNormal")
			row.message = Label(row, 0, 20, 730 + wide)
			row.message:SetHeight(26)
			row.source = Label(row, 0, 48, 730 + wide, "GameFontDisableSmall")
			row.accept = Button(row, L.RECRUIT_INVITE, 140, function() Pane.Invite(row.req) end)
			row.accept:SetPoint("TOPLEFT", 0, -66)
			row.decline = Button(row, L.RECRUIT_DECLINE, 130, function() R.Decline(row.req) end)
			row.decline:SetPoint("TOPLEFT", 148, -66)
			row.point = Button(row, L.RECRUIT_POINT, 226, function() R.Point(row.req) end)
			row.point:SetPoint("TOPLEFT", 0, -66)
			row.dismiss = Button(row, L.RECRUIT_DISMISS, 170, function() R.Dismiss(row.req) end)
			row.dismiss:SetPoint("TOPLEFT", 300, -66)
			Pane.requestRows[count] = row
		end
		row.req = req
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", inboxChild, "TOPLEFT", 0, -y)
		row.title:SetText(L.RECRUIT_REQUEST:format(U.Display(req.name), req.level, L.CLASS[req.class] or "", ns.Views.Ago(ns.Now() - req.t)))
		row.message:SetText(req.text or L.RECRUIT_NO_TEXT)
		local source = L.RECRUIT_SOURCE:format(U.Display(req.origin or ns.me))
		if req.invited then source = source .. " — " .. L.RECRUIT_INVITED end
		row.source:SetText(source)
		row.accept:SetShown(R.CanInvite())
		row.decline:SetShown(R.CanInvite())
		row.point:SetShown(not R.CanInvite() and R.Officer() ~= nil)
		row.dismiss:SetText(shared and L.RECRUIT_CLOSE or L.RECRUIT_DISMISS)
		row:Show()
		y = y + 98
	end
	for i = #reqs + 1, #Pane.requestRows do Pane.requestRows[i]:Hide() end
	inboxChild:SetHeight(math.max(y, 60))
end
-- «Пригласить»: команда /ginvite в своём поле, её вводит сам офицер.
function Pane.Invite(req)
	local command = R.Accept(req)
	if not command or not inboxBox then return end
	inboxBox.req = req
	inboxBox:Run({ { kind = "I", name = req.name } }, { tip = L.RECRUIT_CMD_TIP })
	Pane.RenderInbox()
end
-- Раскладка под вставку width×height (UI.lua): строки, тексты и строка команды тянутся по ширине.
-- Высота ответов зависит от ширины, поэтому открытый экран вступления перекладывается заново.
function Pane.Layout(width)
	wide = math.max(0, math.floor(width) - 804)
	if pane then
		intro:SetWidth(740 + wide)
		note:SetWidth(530 + wide)
		child:SetWidth(740 + wide)
		for _, row in ipairs(guildRows) do
			row:SetWidth(730 + wide)
			row.title:SetWidth(480 + wide)
			row.sub:SetWidth(480 + wide)
		end
		for _, label in ipairs(replyRows) do label:SetWidth(725 + wide) end
		if pane:IsShown() then Pane.Render() end
	end
	if inbox then
		inboxHint:SetWidth(570 + wide)
		inboxBox:SetWidth(740 + wide)
		inboxChild:SetWidth(740 + wide)
		inboxEmpty:SetWidth(730 + wide)
		for _, row in ipairs(Pane.requestRows) do
			row:SetWidth(730 + wide)
			row.title:SetWidth(730 + wide)
			row.message:SetWidth(730 + wide)
			row.source:SetWidth(730 + wide)
		end
	end
end
function Pane.ShowInbox() if inbox then inbox:Show(); Pane.RenderInbox() end end
function Pane.HideInbox()
	if not inbox then return end
	inbox:Hide()
	inboxBox.edit:ClearFocus()
end
