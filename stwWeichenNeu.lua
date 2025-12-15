-- Hardware proxies
local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local add = eeprom.getLabel() -- This is always a string
local PORT = 1234
local uptime = computer.uptime

-- Directional sides
local OUTPUT_SIDE = 4 -- east
local FEEDBACK_SIDE = 5 -- west

local zustaendigkeit = {}
local colorMap = {}
local last_lage = {}
local next_poll = 0
local colorBits = {
    "white", "orange", "magenta", "lightBlue", "yellow", "lime", "pink", "gray",
    "lightGray", "cyan", "purple", "blue", "brown", "green", "red", "black"
}

modem.open(PORT)

-- Basic serialization helper
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
    local success, res = pcall(f)
    if success then return res else return nil end
end

local function setRedstone(lage, id)
    local idx = colorMap[tostring(id)]
    if not idx then return end

    local colorIndex = idx - 1 -- 0-15 based index for bundled
    local level = (lage == "-") and 255 or 0

    local currentValues = redstone.getBundledOutput(OUTPUT_SIDE) or {}
    -- Ensure table has 16 entries to be safe, though OC handles sparse tables usually
    for i=0,15 do currentValues[i] = currentValues[i] or 0 end
    
    currentValues[colorIndex] = level
    redstone.setBundledOutput(OUTPUT_SIDE, currentValues)
end

local function readWeichenlage(id)
    local idx = colorMap[tostring(id)]
    if not idx then return nil end

    local colorIndex = idx - 1
    local inputs = redstone.getBundledInput(FEEDBACK_SIDE) or {}
    local level = inputs[colorIndex] or 0
    return (level > 0) and "-" or "+"
end

-- ============================================================================
-- 1. INITIAL SETUP LOOP
-- ============================================================================
modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))
local last_req = uptime()

while #zustaendigkeit == 0 do
    -- Short timeout to keep checking; doesn't block retry logic significantly
    local eventType, _, _, port, _, message = computer.pullSignal(0.5) 

    -- Retry logic (runs regardless of whether a signal was received)
    if (uptime() - last_req) > 2 then
        modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))
        last_req = uptime()
    end

    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        if data then
            -- Handle server restart trigger
            if data.event == "initial_startup" then
                modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))
            end

            -- FIX: Compare IDs as strings to avoid Type Mismatch
            if tostring(data.id) == tostring(add) and data.event == "zustaendigkeit_response" then
                zustaendigkeit = unserialize(data.zustaendigkeit) or {}
                colorMap = {}

                for i, MY_ID in ipairs(zustaendigkeit) do
                    colorMap[tostring(MY_ID)] = i
                    -- Report initial status immediately
                    local lage = readWeichenlage(MY_ID) or "+"
                    last_lage[tostring(MY_ID)] = lage
                end

                modem.broadcast(PORT, serialize({ event = "ack", id = add, zustaendigkeit = data.zustaendigkeit }))
            end
        end
    end
end

-- ============================================================================
-- 2. MAIN LOOP
-- ============================================================================
next_poll = uptime() + 2

while true do
    local now = uptime()
    
    -- FIX: Dynamic timeout calculation
    -- We calculate how long to wait until the next poll is due.
    -- If a message arrives earlier, pullSignal returns earlier.
    local time_to_wait = next_poll - now
    if time_to_wait < 0.1 then time_to_wait = 0.1 end -- Prevent 0 or negative wait
    
    local eventType, _, _, port, _, message = computer.pullSignal(time_to_wait)
    
    -- Update time after waking up
    now = uptime()

    -- A. PERIODIC FEEDBACK POLL
    if now >= next_poll then
        next_poll = now + 2
        for _, MY_ID in ipairs(zustaendigkeit) do
            local strID = tostring(MY_ID)
            local sensed = readWeichenlage(MY_ID) or "+"
            
            if last_lage[strID] ~= sensed then
                last_lage[strID] = sensed
                modem.broadcast(PORT, serialize({ event = "ack", id = MY_ID, lage = sensed }))
                -- Debug broadcast
                modem.broadcast(9999, "feedback change " .. strID .. " -> " .. sensed)
            end
        end
    end

    -- B. MESSAGE HANDLING
    if eventType == "modem_message" and port == PORT then
        local data = unserialize(message)
        
        if data then
            -- Handle global restart
            if data.event == "initial_startup" then
                -- On main loop restart, we might want to re-verify, but usually just ack
                modem.broadcast(PORT, serialize({ event = "zustaendigkeit_request", id = add }))
            else
                local dataIdStr = tostring(data.id)
                
                -- Check if we are responsible for this ID
                if colorMap[dataIdStr] then
                    if data.event == "umstellauftrag" then
                        modem.broadcast(9999, "umstellauftrag " .. dataIdStr)
                        setRedstone(data.lage, dataIdStr)
                        
                        -- Read back confirmation
                        local lage = readWeichenlage(dataIdStr) or data.lage or "+"
                        last_lage[dataIdStr] = lage
                        modem.broadcast(PORT, serialize({ event = "ack", id = dataIdStr, lage = lage }))
                    
                    elseif data.event == "request_lage" or data.event == "lage_response" then
                        local lage = readWeichenlage(dataIdStr) or "+"
                        last_lage[dataIdStr] = lage
                        modem.broadcast(PORT, serialize({ event = "ack", id = dataIdStr, lage = lage }))
                    end
                end
            end
        end
    end
end