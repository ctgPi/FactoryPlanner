local simplex_solver = {}

local AffineExpression = require "affine_expression"
local Simplex = require "kernel"

local _1 = AffineExpression._1

function simplex_solver.solve(subfactory_data)
    local solver = Simplex:new()

    local item_flows = {}
    for _, line in pairs(subfactory_data.top_floor.lines) do
        local recipe_key = "recipe." .. line.recipe_proto.name
        -- How many times can this recipe run in one second?
        local effective_rate = 1 / line.recipe_proto.energy * line.machine_proto.speed * (1 + math.max(-0.8, line.total_effects.speed))
        local effective_productivity = (1 + line.machine_proto.base_productivity) * (1 + line.total_effects.productivity)

        for _, ingredient in pairs(line.recipe_proto.ingredients) do
            local item_key = ingredient.type .. "." .. ingredient.name
            local amount = ingredient.amount

            item_flows[item_key] = item_flows[item_key] or AffineExpression:new{}
            item_flows[item_key][recipe_key] = (item_flows[item_key][recipe_key] or 0) - amount * effective_rate
        end
        for _, product in pairs(line.recipe_proto.products) do
            local item_key = product.type .. "." .. product.name
            local amount = product.amount
            local proddable_amount = product.proddable_amount
            local effective_amount = (amount - proddable_amount) + proddable_amount * effective_productivity

            item_flows[item_key] = item_flows[item_key] or AffineExpression:new{}
            item_flows[item_key][recipe_key] = (item_flows[item_key][recipe_key] or 0) + effective_amount * effective_rate
        end
    end

    local objective = AffineExpression:new{}
    local constrained_items = {}
    local item_deficit = {}
    for _, product in pairs(subfactory_data.top_level_products) do
        local item_key = product.proto.type .. "." .. product.proto.name

        item_deficit[item_key] = item_key .. ".deficit"
        solver:add_constraint(AffineExpression:new{[item_deficit[item_key]] = 1, [item_key .. ".deficit" .. ".slack"] = 1, [_1] = -1})
        objective[item_deficit[item_key]] = 1

        constrained_items[item_key] = true
        -- TODO: don't edit this stuff in-place, introduce a variable or something
        item_flows[item_key][item_deficit[item_key]] = product.amount
        item_flows[item_key][_1] = -product.amount
    end

    for item_key, _ in pairs(item_flows) do
        local is_input = false
        local is_output = false
        for recipe_key, _ in pairs(item_flows[item_key]) do
            if item_flows[item_key][recipe_key] < 0 then
                is_input = true
            end
            if item_flows[item_key][recipe_key] > 0 then
                is_output = true
            end
        end
        if is_input and is_output then
            constrained_items[item_key] = true
        end
    end

    for item_key, _ in pairs(constrained_items) do
        solver:add_constraint(item_flows[item_key])
    end

    print(serpent.dump(solver))
    print(serpent.dump(objective))
    local obj, ans = solver:solve(objective)
    print(obj)
    print(serpent.dump(ans))

    --[[
    calculation.interface.set_line_result{
        player_index = subfactory_data.player_index,
        floor_id = floor.id,
        line_id = line.id,
        machine_count = line_aggregate.machine_count,
        energy_consumption = line_aggregate.energy_consumption,
        pollution = line_aggregate.pollution,
        production_ratio = line_aggregate.production_ratio,
        uncapped_production_ratio = line_aggregate.uncapped_production_ratio,
        Product = line_aggregate.Product,
        Byproduct = line_aggregate.Byproduct,
        Ingredient = line_aggregate.Ingredient,
        fuel_amount = line_aggregate.fuel_amount
    }
    --]]

    print("---\n")
end

return simplex_solver