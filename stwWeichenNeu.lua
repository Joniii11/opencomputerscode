local component = require("component")
local computer = require("computer")

-- Hardware proxies
local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local add = eeprom.getLabel()
local PORT = 1234

-- Directional sides: adjust if wiring differs
local OUTPUT_SIDE = 1 -- east side: commands to weichen
local FEEDBACK_SIDE = 0 -- west side: feedback from weichen

local zustaendigkeit = {}
local colorMap = {} -- id (string) -> color index (1-based for colorBits)
local last_lage = {} -- id -> last reported lage
local colorBits = {
	"white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
	"lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black"
}

modem.open(PORT)

local function serialize(tbl)
	local function ser(val)
		if type(val) == "number" then return tostring(val)
		elseif type(val) == "boolean" then return val and "true" or "false"
		elseif type(val) == "string" then
			return '"' .. val:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
		elseif type(val) == "table" then
			local items = {}
			for k, v in pairs(val) do
				items[#items + 1] = "[" .. ser(k) .. "]=" .. ser(v)
			end
			return "{" .. table.concat(items, ",") .. "}"
		else return "nil" end
	end
	return ser(tbl)
end

local function unserialize(str)
	local f = load("return " .. str)
	if not f then return nil end
	return f()
end

local function setRedstone(lage, id)
	local idx = colorMap[tostring(id)] or colorMap[id]
	if not idx then
		modem.broadcast(9999, "ID " .. tostring(id) .. " not found in zustaendigkeit")
		return
	end

	local colorIndex = idx - 1 -- bundled index
	local level = (lage == "-") and 255 or 0

	local currentValues = redstone.getBundledOutput(OUTPUT_SIDE) or {}
	currentValues[colorIndex] = level
	redstone.setBundledOutput(OUTPUT_SIDE, currentValues)

	modem.broadcast(9999, "Set redstone for ID " .. tostring(id) .. " color " .. (colorBits[idx] or "?") .. " (index " .. colorIndex .. ") to " .. level)
end

local function readWeichenlage(id)
	local idx = colorMap[tostring(id)] or colorMap[id]
	if not idx then return nil end

	local colorIndex = idx - 1
	local inputs = redstone.getBundledInput(FEEDBACK_SIDE) or {}
	local level = inputs[colorIndex] or 0
	-- Off -> "+"; On -> "-"
	return (level > 0) and "-" or "+"
end

-- Request responsibility map
modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))

while #zustaendigkeit == 0 do
	local eventType, _, _, port, _, message = computer.pullSignal()
	if eventType ~= "modem_message" then goto continue end
	if port ~= PORT then goto continue end

	local data = unserialize(message)
	if not data then goto continue end
	if data.id ~= add then goto continue end

	if data.event == "initial_startup" then
		modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))
	end

	if data.event == "zustaendigkeit_response" and data.id == add then
		zustaendigkeit = unserialize(data.zustaendigkeit)
		colorMap = {}

		for i, MY_ID in ipairs(zustaendigkeit) do
			colorMap[tostring(MY_ID)] = i
		end

		modem.broadcast(PORT, serialize({ event = "ack", id = add, zustaendigkeit = data.zustaendigkeit }))
	end

	::continue::
end

-- On startup: report initial lage from feedback instead of requesting
for _, MY_ID in ipairs(zustaendigkeit) do
	local lage = readWeichenlage(MY_ID) or "+"
	last_lage[MY_ID] = lage
	modem.broadcast(PORT, serialize({ event = "ack", id = MY_ID, lage = lage }))
end

while true do
	local eventType, _, _, port, _, message = computer.pullSignal(5) -- 5s poll window
	if eventType == nil then
		-- timeout: poll feedback for changes
		for _, MY_ID in ipairs(zustaendigkeit) do
			local sensed = readWeichenlage(MY_ID) or "+"
			if last_lage[MY_ID] ~= sensed then
				last_lage[MY_ID] = sensed
				modem.broadcast(PORT, serialize({ event = "ack", id = MY_ID, lage = sensed }))
			end
		end
		goto continue
	end
	if eventType ~= "modem_message" then goto continue end
	if port ~= PORT then goto continue end

	local data = unserialize(message)
	if not data then goto continue end

	if data.event == "initial_startup" then
		modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))
	end

	local dataId = tonumber(data.id) or data.id

	local isResponsible = false
	for _, MY_ID in ipairs(zustaendigkeit) do
		if dataId == MY_ID then
			isResponsible = true
			break
		end
	end

	if not isResponsible then goto continue end

	if data.event == "umstellauftrag" then
		modem.broadcast(9999, "umstellauftrag " .. tostring(dataId))
		setRedstone(data.lage, dataId)
		local lage = readWeichenlage(dataId) or data.lage or "+"
		last_lage[dataId] = lage
		modem.broadcast(PORT, serialize({ event = "ack", id = dataId, lage = lage }))
	elseif data.event == "request_lage" then
		local lage = readWeichenlage(dataId) or "+"
		last_lage[dataId] = lage
		modem.broadcast(PORT, serialize({ event = "ack", id = dataId, lage = lage }))
	elseif data.event == "lage_response" then
		-- Treat as confirmation request; echo back sensed state
		local lage = readWeichenlage(dataId) or data.lage or "+"
		last_lage[dataId] = lage
		modem.broadcast(PORT, serialize({ event = "ack", id = dataId, lage = lage }))
	end

	::continue::
end
