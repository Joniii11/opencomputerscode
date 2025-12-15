local redstone = component.proxy(component.list("redstone")())
local modem = component.proxy(component.list("modem")())
local eeprom = component.proxy(component.list("eeprom")())

local add = eeprom.getLabel()
local PORT = 1234
local uptime = computer.uptime

-- HARDWARE SIDES
local SIDE_COMMAND  = 1  -- Output
local SIDE_FEEDBACK = 0  -- Input

local zustaendigkeit = {}
local colorMap = {} 
local last_lage = {}
local active_pulses = {} 
local next_poll = 0 

modem.open(PORT)

-- HELPER FUNCTIONS
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
  
  local inputs = redstone.getBundledInput(SIDE_FEEDBACK) or {}
  local val = inputs[idx - 1] or 0
  
  return (val > 0) and "-" or "+"
end

local function triggerSwitchPulse(target_lage, id)
  local strID = tostring(id)
  local current_real_lage = readWeichenlage(id)

  -- Don't pulse if already in position (prevents flip-flop error)
  if current_real_lage == target_lage then
    modem.broadcast(PORT, serialize({event = "ack", id = id, lage = current_real_lage}))
    return
  end

  local idx = colorMap[strID]
  if not idx then return end
  local colorIndex = idx - 1

  local currentValues = redstone.getBundledOutput(SIDE_COMMAND) or {}
  for i=0,15 do currentValues[i] = currentValues[i] or 0 end
  
  currentValues[colorIndex] = 255
  redstone.setBundledOutput(SIDE_COMMAND, currentValues)

  active_pulses[colorIndex] = uptime() + 1.0
end

local function handle_zustaendigkeit_response(data)
    zustaendigkeit = unserialize(data.zustaendigkeit) or {}
    colorMap = {}
    last_lage = {}
    
    for i, MY_ID in ipairs(zustaendigkeit) do
        colorMap[tostring(MY_ID)] = i
        local current = readWeichenlage(MY_ID)
        last_lage[tostring(MY_ID)] = current
        modem.broadcast(PORT, serialize({event = "ack", id = MY_ID, lage = current}))
    end
    
    modem.broadcast(PORT, serialize({event = "ack", id = add, zustaendigkeit = data.zustaendigkeit}))
end

-- STARTUP LOOP
local last_req_time = 0

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
      if data.event == "initial_startup" then 
          last_req_time = 0 
      end
      
      if tostring(data.id) == tostring(add) and data.event == "zustaendigkeit_response" then
          handle_zustaendigkeit_response(data)
      end
    end
  end
end

-- MAIN LOOP
next_poll = uptime() + 2

while true do
  local now = uptime()
  
  -- Pulse Management
  local pulses_changed = false
  local output_values = nil 

  for cIdx, turn_off_time in pairs(active_pulses) do
    if now >= turn_off_time then
      if not output_values then 
         output_values = redstone.getBundledOutput(SIDE_COMMAND) or {}
         for i=0,15 do output_values[i] = output_values[i] or 0 end
      end
      output_values[cIdx] = 0
      active_pulses[cIdx] = nil 
      pulses_changed = true
    end
  end

  if pulses_changed then
    redstone.setBundledOutput(SIDE_COMMAND, output_values)
  end

  -- Calc Sleep
  local time_left = next_poll - now
  if time_left < 0.1 then time_left = 0.1 end
  
  local event, _, _, port, _, msg = computer.pullSignal(time_left)
  now = uptime()

  -- Feedback Poll
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

  -- Message Handling
  if event == "modem_message" and port == PORT then
    local data = unserialize(msg)
    if data then
       local dataID = tostring(data.id)
       
       if data.event == "initial_startup" then
          modem.broadcast(PORT, serialize({event = "zustaendigkeit_request", id = add}))
       
       elseif data.event == "zustaendigkeit_response" and tostring(data.id) == tostring(add) then
           handle_zustaendigkeit_response(data)
       
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