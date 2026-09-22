addon.author   = 'Thorny';
addon.name     = 'AbsorbMonitor';
addon.desc     = 'Shows Absorb-TP Usage';
addon.version  = '1.0';

require ('common');
local ffi = require('ffi');
ffi.cdef[[
    int32_t memcmp(const void* buff1, const void* buff2, size_t count);
]];
local fonts = require('fonts');
local scaling = require('scaling');
local font_settings = T{
    visible = true,
    font_family = 'Arial',
    font_height = 12,
    color = 0xFFFFFFFF,
    color_outline = 0xFF000000,
    draw_flags = FontDrawFlags.Outlined,
    --position_x = scaling.window.w,
	position_x = 1,
    left_justified = true,
    --right_justified = true,
    position_y = 30,
    background = T{
        visible = true,
        color = 0x80000000,
    },
};
local font;
local state = {};

ashita.events.register('load', 'load_cb', function ()
    font = fonts.new(font_settings);
end);

ashita.events.register('unload', 'unload_cb', function ()
    if (font ~= nil) then
        font:destroy();
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    local name = "Unknown";
    if state.LastTime ~= nil then
        if state.Index == nil then
            local index = bit.band(state.Target, 0x7FF);
            if AshitaCore:GetMemoryManager():GetEntity():GetServerId(index) == state.Target then
                state.Index = index;
            end
        end
        if state.Index ~= nil then
            name = AshitaCore:GetMemoryManager():GetEntity():GetName(state.Index);
            if (AshitaCore:GetMemoryManager():GetEntity():GetHPPercent(state.Index) == 0) then
                state.LastTime = nil;
            end
        end
    end

    if state.LastTime ~= nil then
        local output = T{};
        output:append(string.format("Last amount absorbed:%u TP", state.LastAmount));
        output:append(string.format("Last absorb time:%.2f seconds", os.clock()-state.LastTime));
        output:append(string.format("WS Count:%u [%s]", state.WSCount, name or "Unknown"));
        font.text = table.concat(output, "\n");
    else
        font.text = "AbsorbMonitor: N/A";
    end
end);

local bitData;
local bitOffset;
local function UnpackBits(length)
    local value = ashita.bits.unpack_be(bitData, 0, bitOffset, length);
    bitOffset = bitOffset + length;
    return value;
end

local function ParseActionPacket(e)
    bitData = e.data_raw;
    bitOffset = 40;
    local PendingActionPacket = T{};
    PendingActionPacket.UserId = UnpackBits(32);
    local targetCount = UnpackBits(6);
    --Unknown 4 bits
    bitOffset = bitOffset + 4;
    PendingActionPacket.Type = UnpackBits(4);
    PendingActionPacket.Id = UnpackBits(32);
    --Unknown 32 bits
    bitOffset = bitOffset + 32;

    PendingActionPacket.Targets = T{};
    for i = 1,targetCount do
        local target = T{};
        target.Id = UnpackBits(32);
        local actionCount = UnpackBits(4);
        target.Actions = T{};
        for j = 1,actionCount do
            local action = {};
            action.Reaction = UnpackBits(5);
            action.Animation = UnpackBits(12);
            action.SpecialEffect = UnpackBits(7);
            action.Knockback = UnpackBits(3);
            action.Param = UnpackBits(17);
            action.Message = UnpackBits(10);
            action.Flags = UnpackBits(31);

            local hasAdditionalEffect = (UnpackBits(1) == 1);
            if hasAdditionalEffect then
                local additionalEffect = {};
                additionalEffect.Damage = UnpackBits(10);
                additionalEffect.Param = UnpackBits(17);
                additionalEffect.Message = UnpackBits(10);
                action.AdditionalEffect = additionalEffect;
            end

            local hasSpikesEffect = (UnpackBits(1) == 1);
            if hasSpikesEffect then
                local spikesEffect = {};
                spikesEffect.Damage = UnpackBits(10);
                spikesEffect.Param = UnpackBits(14);
                spikesEffect.Message = UnpackBits(10);
                action.SpikesEffect = spikesEffect;
            end

            target.Actions:append(action);
        end
        PendingActionPacket.Targets:append(target);
    end
    
    return PendingActionPacket;
end

local incomingChunkBuffer;
local incomingReferenceBuffer = T{};

ashita.events.register('packet_in', 'HandleIncomingPacket', function (e)
    local isDuplicate = false;
    if ffi.C.memcmp(e.data_raw, e.chunk_data_raw, e.size) == 0 then
        if #incomingReferenceBuffer > 2 then
            incomingReferenceBuffer[#incomingReferenceBuffer] = nil
        end

        if incomingChunkBuffer then
            table.insert(incomingReferenceBuffer, 1, incomingChunkBuffer)
        end

        incomingChunkBuffer = T{};
        local offset = 0;

        while (offset < e.chunk_size) do
            local size = ashita.bits.unpack_be(e.chunk_data_raw, offset, 9, 7) * 4;
            local chunk_packet = struct.unpack('c' .. size, e.chunk_data, offset + 1);
            incomingChunkBuffer:append(chunk_packet)
            offset = offset + size;
        end
    end

    local packet = struct.unpack('c' .. e.size, e.data, 1)
    for _, chunk in ipairs(incomingReferenceBuffer) do
        for _, bufferEntry in ipairs(chunk) do
            if packet == bufferEntry then
                isDuplicate = true;
                break;
            end
        end
    end

    if not isDuplicate then
        if (e.id == 0x28) then
            local action = ParseActionPacket(e);
            if (action.Type == 4) and (action.Id == 275) then
                local target = action.Targets[1];
                local subAction = target.Actions[1];
                if (subAction.Message == 454) then
                    state.LastTime = os.clock();
                    state.LastAmount = subAction.Param;
                    state.Target = target.Id;
                    state.WSCount = 0;
                end
            end
            
            if (action.Type == 3) then
                for _,target in pairs(action.Targets) do
                    if (target.Id == state.Target) then
                        state.WSCount = state.WSCount + 1;
                    end
                end
            end
        end
    end
end)