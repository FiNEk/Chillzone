-- Ссылки в собственных окнах чата и ссылки на мастеров профессий.
--
-- Игровое поле ввода остаётся под управлением WoW. Одно исключение — ChatLinks.Share: Shift+щелчок
-- по мастеру в «Мастерах профессий» вставляет текст ссылки методом Insert в поле чата игры, только
-- если оно уже открыто, как игра вставляет предмет по Shift+щелчку в сумке. Какое поле открыто, аддон
-- только читает (GetActiveWindow); фокус, атрибуты, скрипты поля и остальные функции ChatEdit_* не
-- трогает. В режиме геймпада поле игры не трогается вовсе.
--
-- Ссылка на мастера ходит по сети обычным текстом «[Профессия: Имя Фамилия]» (Crafters.LinkText).
-- Клиент с аддоном делает из него ссылку addon:Chillzone:craft:<профессия>:<Имя Фамилия> в своих
-- окнах (Views.ChatLine, Chat.Format) и в чате игры фильтром строк (ChatLinks.Crafts), если мастер
-- есть в каталоге. Щелчок открывает его карточку в окне Chillzone (ChatLinks.OpenCraft): в своих
-- окнах — OnHyperlinkClick, в чате игры — пост-хук SetItemRef, как у метки канала (Chat.lua).
local ADDON, ns = ...

local Codec, U, L = ns.Codec, ns.Util, ns.L
local ChatLinks = {}
ns.ChatLinks = ChatLinks

ChatLinks.CRAFT_LINK = "addon:Chillzone:craft:"
local CRAFT_COLOR = "|cffffd000" -- цвет ссылки на профессию в игре

local itemLinks = { item = true, spell = true, enchant = true, quest = true, talent = true }

local function LinkType(link)
	return type(link) == "string" and link:match("^([^:]+)") or nil
end

local function Insert(box, text)
	if not box or type(text) ~= "string" or Codec.LinkAt(text, 1) ~= #text then return false end
	box:Insert(text)
	return true
end

-- Щелчок со «ссылкой в чат» (по умолчанию Shift), как у предметов в игре.
function ChatLinks.Linking()
	local modified = rawget(_G, "IsModifiedClick")
	if type(modified) == "function" then return modified("CHATLINK") and true or false end
	return IsShiftKeyDown ~= nil and IsShiftKeyDown() and true or false
end

function ChatLinks.Whisper(box, name)
	if not box or type(name) ~= "string" or name == "" then return end
	box:SetText("/w " .. Codec.Plain(U.TellName(name) or name) .. " ")
	box:SetFocus()
end

local function OpenItem(link)
	local tooltip = rawget(_G, "ItemRefTooltip")
	if not tooltip or type(tooltip.ItemRefSetHyperlink) ~= "function" then return end
	if not tooltip:IsShown() then tooltip:SetOwner(UIParent, "ANCHOR_PRESERVE") end
	tooltip:ItemRefSetHyperlink(link)
	tooltip:Show()
end

---------------------------------------------------------------------------
-- Ссылка на мастера
---------------------------------------------------------------------------
-- Профессия и имя из ссылки addon:Chillzone:craft:<профессия>:<Имя Фамилия> или nil.
local function CraftOf(link)
	if type(link) ~= "string" or link:sub(1, #ChatLinks.CRAFT_LINK) ~= ChatLinks.CRAFT_LINK then return nil end
	local prof, name = link:sub(#ChatLinks.CRAFT_LINK + 1):match("^(%d+):([^:|]+)$")
	if prof then return tonumber(prof), name end
end
ChatLinks.CraftOf = CraftOf

-- Текст «[Профессия: Имя Фамилия]» знакомого мастера — ссылкой, остальное как есть. Скобки внутри
-- чужих ссылок (|h[...]|h) не трогаются: рецепты тоже называются «Формула: ...».
function ChatLinks.Crafts(text)
	if type(text) ~= "string" or not text:find("[", 1, true) or not ns.Crafters then return text end
	return (text:gsub("()(%[([^%[%]|]+)%])", function(at, whole, inner)
		if at > 2 and text:sub(at - 2, at - 1) == "|h" then return nil end
		local card, prof = ns.Crafters.FromLink(inner)
		if not card then return nil end
		return CRAFT_COLOR .. "|H" .. ChatLinks.CRAFT_LINK .. prof .. ":" .. Codec.Plain(U.Display(card.name)) .. "|h" .. whole .. "|h|r"
	end))
end

-- Щелчок по ссылке на мастера: окно на «Мастерах профессий», справа — его карточка на этой
-- профессии (список рецептов, если его нет, спрашивается у мастера). false — ссылка не на мастера.
function ChatLinks.OpenCraft(link, button)
	local prof, name = CraftOf(link)
	if not prof then return false end
	if button and button ~= "LeftButton" then return true end
	local card = ns.Crafters.Find(name, prof)
	if not card then
		ns.Print(L.CRAFT_LINK_GONE:format(Codec.Plain(name), ns.Crafters.ProfName(prof)))
		return true
	end
	ns.UI.Toggle("crafters")
	ns.CraftersPane.Open(card.key, prof)
	return true
end

-- Поле чата игры, если оно уже открыто, или nil. В режиме геймпада — nil: чат геймпада читает
-- taint поля (как в ChatPane.Whisper).
local function GameInput()
	if ns.ChatPane and ns.ChatPane.Gamepad() then return nil end
	local api = rawget(_G, "ChatFrameUtil")
	local get = type(api) == "table" and api.GetActiveWindow
	if type(get) ~= "function" then get = rawget(_G, "ChatEdit_GetActiveWindow") end
	if type(get) ~= "function" then return nil end
	local ok, box = pcall(get)
	if ok and type(box) == "table" and type(box.Insert) == "function" and box:IsShown() then return box end
end

-- Текст ссылки на мастера — в поле ввода: в поле Chillzone с курсором (вкладка «Чиллзон», окно
-- чата), иначе в открытое поле чата игры. false — открытого поля нет.
function ChatLinks.Share(text)
	if type(text) ~= "string" or text == "" then return false end
	local box = ns.ChatTab and ns.ChatTab.FocusedInput()
	if not box and ns.ChatPane then box = ns.ChatPane.FocusedInput() end
	box = box or GameInput()
	if not box then return false end
	box:Insert(text)
	return true
end

---------------------------------------------------------------------------
-- Свои окна чата
---------------------------------------------------------------------------
local function OnClick(getBox, link, text, button)
	local kind = LinkType(link)
	if kind == "addon" and CraftOf(link) then
		if (not button or button == "LeftButton") and ChatLinks.Linking() then
			-- Shift+щелчок — тот же текст в своё поле: ссылку можно переслать.
			local box = getBox()
			local plain = type(text) == "string" and text:match("|h(%[[^|]+%])|h")
			if box and plain then
				box:Insert(plain)
				box:SetFocus()
			end
		else
			ChatLinks.OpenCraft(link, button)
		end
	elseif kind == "addon" and button == "RightButton" then
		ns.Chat.TagClick(link, text, button)
	elseif kind == "addon" and ns.Chat.TagTier(link, button) == "A" then
		local box = getBox()
		if box then box:SetFocus() end
	elseif kind == "player" then
		local name = link:match("^player:([^:]+)")
		if not name then return end
		if button == "RightButton" then
			-- Меню получает имя без привязки к нашему ScrollingMessageFrame.
			local menu = rawget(_G, "FriendsFrame_ShowDropdown")
			if type(menu) == "function" then menu(U.TellName(name) or name, 1) end
		elseif not button or button == "LeftButton" then
			ChatLinks.Whisper(getBox(), name)
		end
	elseif itemLinks[kind or ""] and (not button or button == "LeftButton") then
		if ChatLinks.Linking() then
			local box = getBox()
			if Insert(box, text) then box:SetFocus() end
		else
			OpenItem(link)
		end
	end
end

function ChatLinks.Attach(messages, getBox)
	messages:SetScript("OnHyperlinkEnter", function(self, link)
		if not itemLinks[LinkType(link) or ""] then return end
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		if pcall(GameTooltip.SetHyperlink, GameTooltip, link) then GameTooltip:Show() else GameTooltip:Hide() end
	end)
	messages:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	messages:SetScript("OnHyperlinkClick", function(_, link, text, button)
		ns.SafeCall("chat link", OnClick, getBox, link, text, button)
	end)
end

local function OnInsertLink(text)
	local box = ns.ChatTab and ns.ChatTab.FocusedInput()
	if not box and ns.ChatPane then box = ns.ChatPane.FocusedInput() end
	if not box and ns.WishesPane then box = ns.WishesPane.FocusedInput() end
	Insert(box, text)
end

---------------------------------------------------------------------------
-- Чат игры: текст ссылки на мастера становится ссылкой фильтром строк. Строку игра показывает
-- сама; фильтр меняет только текст и только если в нём есть знакомый мастер. Закрытые значения
-- Forever (issecretvalue) не читаются.
---------------------------------------------------------------------------
local function IsSecret(v)
	return type(issecretvalue) == "function" and issecretvalue(v)
end

function ChatLinks.Filter(_, _, text, ...)
	if IsSecret(text) or type(text) ~= "string" or not text:find("[", 1, true) then return false end
	local out = ChatLinks.Crafts(text)
	if out == text then return false end
	return false, out, ...
end

ChatLinks.EVENTS = {
	"CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
	"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
	"CHAT_MSG_RAID_WARNING", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_CHANNEL",
}
for _, event in ipairs(ChatLinks.EVENTS) do
	ns.AddChatFilter(event, ChatLinks.Filter)
end

-- Щелчок по ссылке в чате игры. Ссылки addon: игра на Forever отдаёт своему обработчику, который
-- ничего не делает; Shift+щелчок игра обрабатывает сама — окно тогда не открываем.
local function GameClick(link, _, button)
	if not CraftOf(link) or ChatLinks.Linking() then return end
	ChatLinks.OpenCraft(link, button)
end

ns.On("LOGIN", function()
	local hook = rawget(_G, "hooksecurefunc")
	if type(hook) ~= "function" then return end
	-- В Forever сумки вызывают метод напрямую. Старый глобал — запасной путь.
	local chat = rawget(_G, "ChatFrameUtil")
	if type(chat) == "table" and type(chat.InsertLink) == "function" then
		pcall(hook, chat, "InsertLink", OnInsertLink)
	else
		pcall(hook, "ChatEdit_InsertLink", OnInsertLink)
	end
	pcall(hook, "SetItemRef", function(link, text, button)
		ns.SafeCall("craft link", GameClick, link, text, button)
	end)
end)
