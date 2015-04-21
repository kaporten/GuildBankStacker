require "Apollo"
require "Window"

-- Addon class itself
local GuildBankStacker = {}

function GuildBankStacker:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self 
    return o
end

function GuildBankStacker:Init()
	Apollo.RegisterAddon(self, true, "GuildBankStacker", nil)	
end

function GuildBankStacker:OnLoad()	
	-- Register for bank-tab updated events
	Apollo.RegisterEventHandler("GuildBankTab",		"OnGuildBankTab",	self) 	-- Guild bank tab opened/changed.
	Apollo.RegisterEventHandler("GuildBankItem",	"OnGuildBankItem",	self)	-- Guild bank tab contents changed.

	-- Register command /stacktab 
	Apollo.RegisterSlashCommand("stacktab", "Stack", self)
	
    -- Load form for later use
	self.xmlDoc = XmlDoc.CreateFromFile("GuildBankStacker.xml")
end

-- Whenever bank tab is changed, interrupt stacking (if it is in progress) and calc stackability
function GuildBankStacker:OnGuildBankTab(guildOwner, nTab)	
	-- Load-once; Search for the Bank window, attach overlay form if not already done
	local guildBankAddon = Apollo.GetAddon("GuildBank")
	if self.xmlDoc ~= nil and (self.overlayForm == nil or guildBankAddon.tWndRefs.wndMain:FindChild("StackButtonOverlayForm") == nil) then		
		if guildBankAddon ~= nil then
			self.overlayForm = Apollo.LoadForm(self.xmlDoc, "StackButtonOverlayForm", guildBankAddon.tWndRefs.wndMain, self)			
		end
	end

	self.bIsStacking = false
	self:UpdateStackableList(guildOwner, nTab)	
end

-- React to bank changes by re-calculating stackability
-- If stacking is in progress, mark progress on the current stacking (pendingUpdates)
function GuildBankStacker:OnGuildBankItem(guildOwner, nTab, nInventorySlot, itemUpdated, bRemoved)
	self:UpdateStackableList(guildOwner, nTab)
	
	-- Remove pending update-event matched by this update-event (if any)
	if self.pendingUpdates ~= nil then
		for idx,nSlot in ipairs(self.pendingUpdates) do
			if nSlot == nInventorySlot then
				table.remove(self.pendingUpdates, idx)
			end
		end
	end
		
	-- If stacking is in progress - and last pending update was just completed - continue stacking
	if self.bIsStacking == true and self.pendingUpdates ~= nil and #self.pendingUpdates == 0 then
		self:Stack()
	end	
end

-- Identifies which slots can be stacked. Table of stackable slots is stored in self.tStackable
function GuildBankStacker:UpdateStackableList(guildOwner, nTab)
	-- Build table containing 
	--  key = itemId, 
	--  value = list of stackable slots
	local tStackableItems = {}
	
	-- Identify all stackable slots in the current tab, and add to tStackableItems
	for _,tSlot in ipairs(guildOwner:GetBankTab(nTab)) do
		if tSlot ~= nil and self:IsItemStackable(tSlot.itemInSlot) then
			local nItemId = tSlot.itemInSlot:GetItemId()
			
			-- Add current tSlot to tSlots-list containing all slots for this itemId
			local tSlots = tStackableItems[nItemId] or {}
			tSlots[#tSlots+1] = tSlot
			
			-- Add slot details to list of stackable items
			tStackableItems[nItemId] = tSlots
		end
	end
	
	-- Addon-scoped resulting list of stackable slots on current bank tab
	self.tStackable = {}
	self.nTab = nTab
	self.guildOwner = guildOwner
	
	for itemId,tSlots in pairs(tStackableItems) do
		-- More than one stackable stack of this stackable item? If so, add to tStackable. Stack!
		if #tSlots > 1 then 		
			self.tStackable[#self.tStackable+1] = tSlots
		end
	end
	
	-- Update the button enable-status accordingly
	self:UpdateStackButton()
end

function GuildBankStacker:UpdateStackButton()
	-- Do nothing if overlay form is not loaded
	if self.overlayForm == nil then
		return
	end
	
	bEnable = self.tStackable ~= nil and #self.tStackable > 0
	self.overlayForm:FindChild("StackButton"):Enable(bEnable)	
end

-- An item is considered stackable if it has a current stacksize < max stacksize.
-- TODO: Manually handle BoE bags and other stackable items with a non-visible max stack size.
function GuildBankStacker:IsItemStackable(tItem)	
	return tItem:GetMaxStackCount() > 1 and tItem:GetStackCount() < tItem:GetMaxStackCount()
end

-- Performs one single stacking operation.
-- Sets a flag indicating if further stacking is possible, but takes no further action 
-- (awaits Event indicating this stacking-operation has fully completed)
function GuildBankStacker:Stack()
	-- Set flag for retriggering another stack after this one	
	self.bIsStacking = true

	-- Reset opacity, then stack
	self:SetOpacity(1)
	
	-- Safeguard, but should only happen if someone calls :Stack() before opening the guild bank
	if self.tStackable == nil then
		self.bIsStacking = false
		return
	end
	
	-- Grab last element from the tStackable list of item-types
	local tSlots = table.remove(self.tStackable)
	
	-- Nothing in self.tStackable? Just die quietly then.
	if tSlots == nil then
		self.bIsStacking = false
		return
	end

	-- Shorthands for first slot (target) and last slot (source)
	local tFirstSlot = tSlots[1]
	local tLastSlot = tSlots[#tSlots]

	-- Determine current stack move size
	local nRoomInFirstSlot = tLastSlot.itemInSlot:GetMaxStackCount() - tFirstSlot.itemInSlot:GetStackCount()
	local nItemsToMove = math.min(nRoomInFirstSlot, tLastSlot.itemInSlot.GetStackCount())			
			
	-- Make a note of slot-indices that are being updated. We need to await events for both slots before triggering next pass.
	self.pendingUpdates = {tFirstSlot.nIndex, tLastSlot.nIndex}
	
	-- Fire off the update by beginning and ending the bank transfer
	self.guildOwner:BeginBankItemTransfer(tLastSlot.itemInSlot, nItemsToMove)
	self.guildOwner:EndBankItemTransfer(self.nTab, tFirstSlot.nIndex) -- Expected to trigger OnGuildBankItem
end

-- When the stack-button is clicked, execute the stack operation
function GuildBankStacker:OnButtonSignal(wndHandler, wndControl, eMouseButton)
	self:Stack()
end

-- When mousing over the button, change bank-slot opacity to identify stackables
function GuildBankStacker:OnMouseEnter(wndHandler, wndControl, x, y)
	if wndControl:IsEnabled() then
		self:SetOpacity(0.3)
	end
end

-- When no longer hovering over the button, reset opacity for stackables
function GuildBankStacker:OnMouseExit(wndHandler, wndControl, x, y)
	self:SetOpacity(1)
end

-- Pulse all items-to-stack on the current tab
function GuildBankStacker:SetOpacity(nOpacity)
	local guildBankAddon = Apollo.GetAddon("GuildBank")
	if guildBankAddon ~= nil then
		for itemId,tSlots in pairs(self.tStackable) do
			for _,tSlot in ipairs(tSlots) do
				guildBankAddon.tWndRefs.tBankItemSlots[tSlot.nIndex]:TransitionPulse()
				guildBankAddon.tWndRefs.tBankItemSlots[tSlot.nIndex]:SetOpacity(nOpacity)
			end
		end
	end	
end

-- Standard addon initialization
GuildBankStackerInst = GuildBankStacker:new()
GuildBankStackerInst:Init()