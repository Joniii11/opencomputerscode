local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local add = eeprom.getLabel()
local PORT = 1234
local uptime = computer.uptime

-- HARDWARE SIDES (Adjust if needed!)
local SIDE_COMMAND  = 1  -- Output to Weichen (East)
local SIDE_FEEDBACK = 0  -- Input from Weichen (West)

local zustaendigkeit = {}
local colorMap = {} 
local last_lage = {}
local active_pulses = {} -- Stores [colorIndex] = time_to_turn_off
local next_poll = 0 

modem.open(PORT)

-- 1. Helper Functions
local function serialize(tbl)
  local function ser(val)
    if type(val) == "number" then return tostring(val)
    elseif type(val) == "boolean" then return val and "true" or "false"
    elseif type(val) == "string" then return string.format("%q", val)
    elseif type(val) == "table" then
      local items = {}
      for k, v in pairs(val) do items[#items + 1] = "[" .. ser(k) .. "]=" .. ser(v) end
      return "{" .. table.concat(items, ",") .. "}"
    else return "nil" end
  end
  return ser(tbl)
end

local function unserialize(str)
  local f = load("return " .. str)
  if f then return f() end
  return nil
end

local function readWeichenlage(id)
  local idx = colorMap[tostring(id)]
  if not idx then return "+" end
  
  -- Read from Feedback Side
  local inputs = redstone.getBundledInput(SIDE_FEEDBACK) or {}
  local val = inputs[idx - 1] or 0
  
  -- If Signal is ON (>0) -> "-" (Abzweig), else "+" (Gerade)
  return (val > 0) and "-" or "+"
end

local function triggerSwitchPulse(target_lage, id)
  local strID = tostring(id)
  local current_real_lage = readWeichenlage(id)

  if current_real_lage == target_lage then
    modem.broadcast(PORT, serialize({event = "ack", id = id, lage = current_real_lage}))
    return
  end

  local idx = colorMap[strID]
  if not idx then return end

  local colorIndex = idx - 1

  -- Turn Output ON
  local currentValues = redstone.getBundledOutput(SIDE_COMMAND) or {}
  for i=0,15 do currentValues[i] = currentValues[i] or 0 end
  currentValues[colorIndex] = 255 -- ON
  redstone.setBundledOutput(SIDE_COMMAND, currentValues)

  -- Schedule Turn OFF in 1.0 second (Non-blocking)
  active_pulses[colorIndex] = uptime() + 1.0
end

-- ============================================================================
-- 2. RE-INITIALIZATION FUNCTION
-- This consolidated function is called on startup and on server restart
-- ============================================================================
local function initialize_weichen_state(ids)
    for _, MY_ID in ipairs(ids) do
        local strID = tostring(MY_ID)
        local current = readWeichenlage(MY_ID)
        last_lage[strID] = current
        -- Send ACK with the current physical state
        modem.broadcast(PORT, serialize({event = "ack", id = MY_ID, lage = current}))
        modem.broadcast(9999, "Re-ACK ID: " .. strID .. " Lage: " .. current)
    end
end

-- 3. Startup Loop (Get ID)
local last_req_time = 0

-- Function to handle the ID list response, common to startup and restart
local function handle_zustaendigkeit_response(data)
    zustaendigkeit = unserialize(data.zustaendigkeit)
    colorMap = {}
    last_lage = {}
    for i, MY_ID in ipairs(zustaendigkeit) do
        colorMap[tostring(MY_ID)] = i
    end
    modem.broadcast(PORT, serialize({event = "ack", id = add, zustaendigkeit = data.zustaendigkeit}))
    -- Report the status of all assigned weichen immediately after getting the list
    initialize_weichen_state(zustaendigkeit)
end


while #zustaendigkeit == 0 do
  local now = uptime()
  
  if now - last_req_time > 2 then
    modem.broadcast(PORT, serialize({event = "zustaendigkeit_request", id = add}))
    last_req_time = now
  end

  local event, _, _, port, _, msg = computer.pullSignal(0.1)

  if event == "modem_message" and port == PORT then
    local data = unserialize(msg)
    if data then
      if data.event == "initial_startup" then last_req_time = 0 end
      
      -- Check for Zustaendigkeit response
      if tostring(data.id) == tostring(add) and data.event == "zustaendigkeit_response" then
          handle_zustaendigkeit_response(data)
      end
    end
  end
end


-- 4. Main Loop
next_poll = uptime() + 2

while true do
  local now = uptime()
  
  -- A. PULSE MANAGEMENT (Turn off signals that have been on for 1s)
  local pulses_changed = false
  local output_values = nil 

  for cIdx, turn_off_time in pairs(active_pulses) do
    if now >= turn_off_time then
      if not output_values then 
         output_values = redstone.getBundledOutput(SIDE_COMMAND) or {}
         for i=0,15 do output_values[i] = output_values[i] or 0 end
      end
      output_values[cIdx] = 0 -- Turn OFF
      active_pulses[cIdx] = nil 
      pulses_changed = true
    end
  end

  if pulses_changed then
    redstone.setBundledOutput(SIDE_COMMAND, output_values)
  end

  -- B. TIMER CALCULATION
  local time_left = next_poll - now
  if time_left < 0.1 then time_left = 0.1 end
  
  local event, _, _, port, _, msg = computer.pullSignal(time_left)
  now = uptime()

  -- C. FEEDBACK POLL (Every 2 seconds)
  if now >= next_poll then
    next_poll = now + 2
    for _, MY_ID in ipairs(zustaendigkeit) do
       local strID = tostring(MY_ID)
       local current = readWeichenlage(MY_ID)
       
       if last_lage[strID] ~= current then
          last_lage[strID] = current
          modem.broadcast(PORT, serialize({event = "ack", id = MY_ID, lage = current}))
       end
    end
  end

  -- D. MESSAGE HANDLING
  if event == "modem_message" and port == PORT then
    local data = unserialize(msg)
    if data then
       local dataID = tostring(data.id)
       
       -- *** FIX: Server Restart Handling ***
       if data.event == "initial_startup" then
          -- Re-request responsibility immediately, resetting the timer
          modem.broadcast(PORT, serialize({event = "zustaendigkeit_request", id = add}))
       
       -- Check if this is the response to the Zustaendigkeit request
       elseif data.event == "zustaendigkeit_response" and tostring(data.id) == tostring(add) then
           -- Process the new list and immediately report physical states
           handle_zustaendigkeit_response(data)
       
       -- Switch Commands
       elseif colorMap[dataID] then
          if data.event == "umstellauftrag" then
             triggerSwitchPulse(data.lage, dataID)
             
          elseif data.event == "request_lage" then
             local current = readWeichenlage(dataID)
             modem.broadcast(PORT, serialize({event = "ack", id = dataID, lage = current}))
          end
       end
    end
  end
end