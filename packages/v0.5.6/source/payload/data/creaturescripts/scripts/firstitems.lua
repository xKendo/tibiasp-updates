-- TibiaSP v0.5.6: starter items ONLY on the first login of a new character.
-- mace=2398, jacket=2650, torch=2050, backpack=1988, club=2382.
function onLogin(player)
    if player:getLastLoginSaved() ~= 0 then
        return true
    end

    -- Remove the obsolete starter club if a character template supplied it.
    local left = player:getSlotItem(CONST_SLOT_LEFT)
    if left and left:getId() == 2382 then
        left:remove()
    end
    local right = player:getSlotItem(CONST_SLOT_RIGHT)
    if right and right:getId() == 2382 then
        right:remove()
    end

    left = player:getSlotItem(CONST_SLOT_LEFT)
    right = player:getSlotItem(CONST_SLOT_RIGHT)
    local hasMace = (left and left:getId() == 2398) or (right and right:getId() == 2398)
    if not hasMace and not left then
        player:addItem(2398, 1, false, 1, CONST_SLOT_LEFT)
    end

    local armor = player:getSlotItem(CONST_SLOT_ARMOR)
    if armor and armor:getId() == 2651 then
        -- The old starter outfit used a coat instead of the requested jacket.
        armor:remove()
        armor = nil
    end
    if not armor then
        player:addItem(2650, 1, false, 1, CONST_SLOT_ARMOR)
    end
    if not player:getSlotItem(CONST_SLOT_AMMO) then
        player:addItem(2050, 1, false, 1, CONST_SLOT_AMMO)
    end
    if not player:getSlotItem(CONST_SLOT_BACKPACK) then
        local backpack = player:addItem(1988, 1, false, 1, CONST_SLOT_BACKPACK)
        if backpack then
            backpack:addItem(2674, 1)
        end
    end
    return true
end
