-- World Notification Mover
-- Lets you drag the "World refresh in N Seconds" notification (or any
-- notification that shows a given piece of text) to a spot of your choice.
--
-- The notification is grabbed by its frame name (KNOWN_FRAME_NAMES). As a
-- fallback, in case a client update renames it, the addon also looks
-- through the visible UI every second for a frame showing the match text
-- ("world refresh" by default).

local ADDON_NAME = ...
local TITLE = "World Notification Mover"

-- Frame names to try first, before searching by text. The "World refresh
-- in N Seconds" notification is ShardTransferImminentFrame (with its
-- minimize button as a child), defined in Blizzard_SocialToast, which the
-- game loads on demand.
local KNOWN_FRAME_NAMES = { "ShardTransferImminentFrame" }
local NOTIFICATION_ADDON = "Blizzard_SocialToast"

local DEFAULT_MATCH_TEXT = "world refresh"
local SCAN_INTERVAL = 1      -- seconds between searches
local SCAN_DEPTH = 5         -- how deep to look inside each top-level frame
local SAMPLE_W, SAMPLE_H = 300, 30

local function Say(msg)
	print("|cff4fd8ff" .. TITLE .. ":|r " .. msg)
end

---------------------------------------------------------------------------
-- Settings (account-wide)
---------------------------------------------------------------------------

local defaults = {
	moved = false,       -- true once you've dragged it somewhere
	x = 0,               -- center of the notification, relative to the
	y = 0,               -- screen center, in UIParent units
	matchText = DEFAULT_MATCH_TEXT,
}

local db

local function LoadSettings()
	if type(WorldNotificationMoverDB) ~= "table" then
		WorldNotificationMoverDB = {}
	end
	db = WorldNotificationMoverDB
	for key, value in pairs(defaults) do
		if type(db[key]) ~= type(value) then
			db[key] = value
		end
	end
	db.frameName = nil   -- setting from 1.0/1.1, no longer used
	if db.matchText == "" then
		db.matchText = DEFAULT_MATCH_TEXT
	end
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

local ownFrames = {}         -- our own frames, never treated as targets

local function IsUsable(frame)
	if type(frame) ~= "table" or type(frame.GetObjectType) ~= "function" then
		return false
	end
	if frame.IsForbidden and frame:IsForbidden() then
		return false
	end
	return true
end

local function Describe(frame)
	if not frame then
		return "nothing"
	end
	local name = frame.GetName and frame:GetName()
	if name then
		return name
	end
	if frame.GetDebugName then
		local ok, debugName = pcall(frame.GetDebugName, frame)
		if ok and debugName and debugName ~= "" then
			return debugName .. " (no global name)"
		end
	end
	return "an unnamed frame"
end

-- UIParent units per frame unit, so offsets line up when a frame has its
-- own scale.
local function ScaleRatio(frame)
	local own = frame:GetEffectiveScale()
	local ui = UIParent:GetEffectiveScale()
	if not own or own == 0 or not ui or ui == 0 then
		return 1
	end
	return own / ui
end

local function CenterOffset(frame)
	local cx, cy = frame:GetCenter()
	local ux, uy = UIParent:GetCenter()
	if not cx or not ux then
		return nil
	end
	local r = ScaleRatio(frame)
	return cx * r - ux, cy * r - uy
end

local function Outline(frame, r, g, b, a, size)
	size = size or 1
	local function Edge(p1, p2, horizontal)
		local t = frame:CreateTexture(nil, "BORDER")
		t:SetColorTexture(r, g, b, a)
		t:SetPoint(p1)
		t:SetPoint(p2)
		if horizontal then
			t:SetHeight(size)
		else
			t:SetWidth(size)
		end
	end
	Edge("TOPLEFT", "TOPRIGHT", true)
	Edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
	Edge("TOPLEFT", "BOTTOMLEFT", false)
	Edge("TOPRIGHT", "BOTTOMRIGHT", false)
end

---------------------------------------------------------------------------
-- Targets: the real notification frame(s) we keep in place
---------------------------------------------------------------------------

local targets = {}           -- frame -> { points = original anchors }
local targetList = {}        -- same frames, in the order found
local applying = false
local pendingAfterCombat = false
local RefreshPanel           -- set when the options panel is built

local function CanMove(frame)
	return not (InCombatLockdown() and frame.IsProtected and frame:IsProtected())
end

local function PlaceOne(frame)
	if not db.moved then
		return
	end
	if not CanMove(frame) then
		pendingAfterCombat = true
		return
	end
	local r = ScaleRatio(frame)
	applying = true
	frame:ClearAllPoints()
	frame:SetPoint("CENTER", UIParent, "CENTER", db.x / r, db.y / r)
	applying = false
end

local function PlaceAll()
	for _, frame in ipairs(targetList) do
		PlaceOne(frame)
	end
end

local function RestoreOriginal(frame)
	local info = targets[frame]
	if not info or #info.points == 0 or not CanMove(frame) then
		return
	end
	applying = true
	frame:ClearAllPoints()
	for _, p in ipairs(info.points) do
		frame:SetPoint(p[1], p[2], p[3], p[4], p[5])
	end
	applying = false
end

local function Adopt(frame, how)
	if targets[frame] or ownFrames[frame] then
		return
	end
	local points = {}
	for i = 1, (frame.GetNumPoints and frame:GetNumPoints() or 0) do
		points[i] = { frame:GetPoint(i) }
	end
	targets[frame] = { points = points }
	targetList[#targetList + 1] = frame

	-- The game re-anchors notifications when it shows them. Put ours back
	-- every time that happens.
	hooksecurefunc(frame, "SetPoint", function(self)
		if not applying then
			PlaceOne(self)
		end
	end)
	frame:HookScript("OnShow", PlaceOne)

	PlaceOne(frame)
	Say("found the notification: " .. Describe(frame) .. " (" .. how .. ").")
	if RefreshPanel then
		RefreshPanel()
	end
end

-- From the frame that owns the text, climb to the biggest ancestor that is
-- still notification-sized, so the icon and border move along with it.
local function NotificationRoot(frame)
	local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
	local best = frame
	local parent = frame:GetParent()
	while parent and parent ~= UIParent and IsUsable(parent) and not ownFrames[parent] do
		local w, h = parent:GetWidth() or 0, parent:GetHeight() or 0
		if w > uw * 0.6 or h > uh * 0.3 then
			break
		end
		best = parent
		parent = parent:GetParent()
	end
	return best
end

-- Returns the frame that owns a FontString containing `needle`, or nil.
local function FindTextOwner(frame, needle, depth)
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "FontString" and region:IsVisible() then
			local text = region:GetText()
			if type(text) == "string" and text:lower():find(needle, 1, true) then
				return frame
			end
		end
	end
	if depth > 0 then
		for _, child in ipairs({ frame:GetChildren() }) do
			if IsUsable(child) and child:IsVisible() and not ownFrames[child] then
				local found = FindTextOwner(child, needle, depth - 1)
				if found then
					return found
				end
			end
		end
	end
	return nil
end

local function FrameByName(name)
	local frame = name and name ~= "" and _G[name]
	if IsUsable(frame) and frame.SetPoint then
		return frame
	end
	return nil
end

local foundByName = false

-- One search pass. Returns true if it found something new.
local function Search()
	if not db then
		return false
	end
	local before = #targetList

	for _, name in ipairs(KNOWN_FRAME_NAMES) do
		local frame = FrameByName(name)
		if frame then
			Adopt(frame, "by known name")
			foundByName = true
			return #targetList > before
		end
	end

	local needle = db.matchText:lower()
	for _, child in ipairs({ UIParent:GetChildren() }) do
		if IsUsable(child) and not ownFrames[child] and child:IsVisible() then
			local ok, owner = pcall(FindTextOwner, child, needle, SCAN_DEPTH)
			if ok and owner then
				local root = NotificationRoot(owner)
				if not targets[root] then
					Adopt(root, "by its text")
				end
			end
		end
	end
	return #targetList > before
end

local function AnyTargetVisible()
	for _, frame in ipairs(targetList) do
		if frame:IsVisible() then
			return frame
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- The mover: a sample notification with a drag handle
---------------------------------------------------------------------------

local handle = CreateFrame("Frame", "WorldNotificationMoverHandle", UIParent)
ownFrames[handle] = true
handle:SetSize(SAMPLE_W, SAMPLE_H)
handle:SetFrameStrata("DIALOG")
handle:SetClampedToScreen(true)
handle:SetMovable(true)
handle:EnableMouse(true)
handle:RegisterForDrag("LeftButton")
if handle.SetDontSavePosition then
	handle:SetDontSavePosition(true)
end
handle:Hide()

local glow = handle:CreateTexture(nil, "BACKGROUND")
glow:SetPoint("TOPLEFT", -3, 3)
glow:SetPoint("BOTTOMRIGHT", 3, -3)
glow:SetColorTexture(0.3, 0.85, 1, 0.18)
Outline(handle, 0.3, 0.85, 1, 1, 2)

-- Look-alike of the real notification: an icon square, then a dark box
-- with a thin grey border and light blue text.
local sample = CreateFrame("Frame", nil, handle)
ownFrames[sample] = true
sample:SetAllPoints()

local iconBox = CreateFrame("Frame", nil, sample)
ownFrames[iconBox] = true
iconBox:SetPoint("TOPLEFT")
iconBox:SetPoint("BOTTOMLEFT")
iconBox:SetWidth(SAMPLE_H)
local iconBg = iconBox:CreateTexture(nil, "BACKGROUND")
iconBg:SetAllPoints()
iconBg:SetColorTexture(0, 0, 0, 0.85)
local icon = iconBox:CreateTexture(nil, "ARTWORK")
icon:SetPoint("TOPLEFT", 2, -2)
icon:SetPoint("BOTTOMRIGHT", -2, 2)
icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

local box = CreateFrame("Frame", nil, sample)
ownFrames[box] = true
box:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 6, 0)
box:SetPoint("BOTTOMRIGHT")
local boxBg = box:CreateTexture(nil, "BACKGROUND")
boxBg:SetAllPoints()
boxBg:SetColorTexture(0.03, 0.03, 0.05, 0.9)
Outline(box, 0.55, 0.55, 0.55, 1, 1)
local sampleText = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
sampleText:SetPoint("LEFT", 8, 0)
sampleText:SetTextColor(0.6, 0.8, 1)
sampleText:SetText("World refresh in 55 Seconds")

local tip = handle:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
tip:SetPoint("TOP", handle, "BOTTOM", 0, -6)
tip:SetText("Drag to move. Right-click to lock.")

local function DefaultSpot()
	-- Roughly where the notification shows up by default: left side of the
	-- screen, a little above the middle.
	return -UIParent:GetWidth() / 2 + SAMPLE_W / 2 + 40, UIParent:GetHeight() * 0.03
end

local function PlaceHandle()
	local x, y
	if db.moved then
		x, y = db.x, db.y
	else
		local real = AnyTargetVisible()
		if real then
			x, y = CenterOffset(real)
		end
		if not x then
			x, y = DefaultSpot()
		end
	end
	handle:ClearAllPoints()
	handle:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

-- Match the handle's size to the real notification when it's on screen;
-- otherwise show the sample at its default size.
local function SizeHandle()
	local real = AnyTargetVisible()
	if real and real:GetWidth() and real:GetWidth() > 0 then
		local r = ScaleRatio(real)
		handle:SetSize(real:GetWidth() * r, real:GetHeight() * r)
		sample:Hide()
	else
		handle:SetSize(SAMPLE_W, SAMPLE_H)
		sample:Show()
	end
end

local function IsUnlocked()
	return handle:IsShown()
end

local function Unlock()
	SizeHandle()
	PlaceHandle()
	handle:Show()
	if RefreshPanel then
		RefreshPanel()
	end
end

local function Lock()
	handle:Hide()
	if RefreshPanel then
		RefreshPanel()
	end
end

local function ResetPosition()
	db.moved = false
	db.x, db.y = 0, 0
	for _, frame in ipairs(targetList) do
		RestoreOriginal(frame)
	end
	if IsUnlocked() then
		PlaceHandle()
	end
	Say("position reset. The notification goes back to its normal spot.")
	if RefreshPanel then
		RefreshPanel()
	end
end

handle:SetScript("OnDragStart", function(self)
	self:StartMoving()
end)

handle:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	if not self.SetDontSavePosition and self.SetUserPlaced then
		self:SetUserPlaced(false)
	end
	local x, y = CenterOffset(self)
	if x then
		db.x = math.floor(x + 0.5)
		db.y = math.floor(y + 0.5)
		db.moved = true
	end
	PlaceHandle()
	PlaceAll()
	if RefreshPanel then
		RefreshPanel()
	end
end)

handle:SetScript("OnMouseUp", function(_, button)
	if button == "RightButton" then
		Lock()
		Say("locked. Open /wnm to move it again.")
	end
end)

---------------------------------------------------------------------------
-- Options panel (Options > AddOns > World Notification Mover)
---------------------------------------------------------------------------

local panel = CreateFrame("Frame", "WorldNotificationMoverOptions")
panel.name = TITLE

local heading = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
heading:SetPoint("TOPLEFT", 16, -16)
heading:SetText(TITLE)

local intro = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
intro:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -8)
intro:SetWidth(560)
intro:SetJustifyH("LEFT")
intro:SetText("Click Move notification, drag the box where you want the \"World refresh\" notification, then click Lock. If the real notification is on screen the box takes its size; otherwise you'll see a sample.")

local function Button(text, width, onClick)
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetSize(width, 24)
	b:SetText(text)
	b:SetScript("OnClick", onClick)
	return b
end

local moveButton = Button("Move notification", 170, function()
	if IsUnlocked() then
		Lock()
	else
		Unlock()
	end
end)
moveButton:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -16)

local resetButton = Button("Reset position", 140, ResetPosition)
resetButton:SetPoint("LEFT", moveButton, "RIGHT", 10, 0)

local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
status:SetPoint("TOPLEFT", moveButton, "BOTTOMLEFT", 0, -16)
status:SetWidth(560)
status:SetJustifyH("LEFT")

RefreshPanel = function()
	if not db then
		return
	end
	moveButton:SetText(IsUnlocked() and "Lock" or "Move notification")
	local found
	if #targetList == 0 then
		found = "Notification: not seen yet this session (it's found automatically when it next appears)."
	else
		local names = {}
		for _, frame in ipairs(targetList) do
			names[#names + 1] = Describe(frame)
		end
		found = "Notification: " .. table.concat(names, ", ")
	end
	local where = db.moved and ("Position: moved (" .. db.x .. ", " .. db.y .. " from screen center)")
		or "Position: game default"
	status:SetText(found .. "\n" .. where)
end

panel:SetScript("OnShow", RefreshPanel)

local category
if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
	category = Settings.RegisterCanvasLayoutCategory(panel, TITLE)
	Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
	InterfaceOptions_AddCategory(panel)
end

local function OpenPanel()
	if category and Settings.OpenToCategory then
		Settings.OpenToCategory(category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(panel)
		InterfaceOptionsFrame_OpenToCategory(panel)
	else
		Unlock()
	end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

local function Help()
	Say("commands:")
	print("  /wnm -- open the options")
	print("  /wnm move -- show the drag box (right-click it to lock)")
	print("  /wnm lock -- hide the drag box")
	print("  /wnm reset -- put the notification back in its normal spot")
	print("  /wnm find -- search for the notification right now")
	print("  /wnm text <words> -- change the text it searches for")
	print("  /wnm status -- show what's been found")
end

SLASH_WORLDNOTIFICATIONMOVER1 = "/wnm"
SLASH_WORLDNOTIFICATIONMOVER2 = "/worldnotificationmover"
SlashCmdList.WORLDNOTIFICATIONMOVER = function(input)
	if not db then
		return
	end
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "" or cmd == "options" or cmd == "config" then
		OpenPanel()
	elseif cmd == "move" or cmd == "unlock" or cmd == "test" then
		Unlock()
	elseif cmd == "lock" then
		Lock()
	elseif cmd == "reset" then
		ResetPosition()
	elseif cmd == "find" then
		if not Search() then
			Say(#targetList > 0 and "nothing new found." or "not on screen right now. It'll be found automatically when it appears.")
		end
	elseif cmd == "text" then
		if rest == "" then
			Say("searching for \"" .. db.matchText .. "\". Use /wnm text <words> to change it.")
		else
			db.matchText = rest:lower()
			Say("now searching for \"" .. db.matchText .. "\".")
		end
	elseif cmd == "status" then
		Say("looking for " .. table.concat(KNOWN_FRAME_NAMES, ", ") .. ", or text \"" .. db.matchText .. "\".")
		if #targetList == 0 then
			Say("not found yet this session.")
		else
			for _, frame in ipairs(targetList) do
				print("  " .. Describe(frame) .. (frame:IsVisible() and " (showing)" or ""))
			end
		end
		Say(db.moved and ("moved to " .. db.x .. ", " .. db.y .. " from screen center.") or "not moved.")
	else
		Help()
	end
end

---------------------------------------------------------------------------
-- Startup and the background search
---------------------------------------------------------------------------

local watcher = CreateFrame("Frame")
ownFrames[watcher] = true
local elapsedSinceScan = 0

watcher:SetScript("OnUpdate", function(_, elapsed)
	elapsedSinceScan = elapsedSinceScan + elapsed
	if elapsedSinceScan < SCAN_INTERVAL then
		return
	end
	elapsedSinceScan = 0
	-- Once the exact frame is known by name there's nothing left to search.
	if foundByName then
		return
	end
	if Search() and IsUnlocked() then
		SizeHandle()
		PlaceHandle()
	end
end)

watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("PLAYER_REGEN_ENABLED")
watcher:SetScript("OnEvent", function(self, event, name)
	if event == "ADDON_LOADED" then
		if name == ADDON_NAME then
			LoadSettings()
			Search()
		elseif name == NOTIFICATION_ADDON and db then
			-- The notification's frame now exists: grab it right away.
			Search()
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if pendingAfterCombat then
			pendingAfterCombat = false
			PlaceAll()
		end
	end
end)
