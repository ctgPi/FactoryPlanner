-- This contains both the UI handling for view states, as well as the amount conversions
view_state = {}

-- ** LOCAL UTIL **
local function cycle_views(player, direction)
    local ui_state = data_util.get("ui_state", player)

    if ui_state.view_states and main_dialog.is_in_focus(player) or compact_dialog.is_in_focus(player) then
        local selected_view_id, view_state_count = ui_state.view_states.selected_view_id, #ui_state.view_states
        local new_view_id = nil  -- need to make sure this is wrapped properly in either direction
        if direction == "standard" then
            new_view_id = (selected_view_id == view_state_count) and 1 or (selected_view_id + 1)
        else  -- direction == "reverse"
            new_view_id = (selected_view_id == 1) and view_state_count or (selected_view_id - 1)
        end
        view_state.select(player, new_view_id)

        local compact_view = data_util.get("flags", player).compact_view
        if compact_view then compact_subfactory.refresh(player)
        else main_dialog.refresh(player, "production") end

        -- This avoids the game focusing a random textfield when pressing Tab to change states
        local main_frame = ui_state.main_elements.main_frame
        if main_frame ~= nil then main_frame.focus() end
    end
end


local processors = {}  -- individual functions for each kind of view state
function processors.items_per_timescale(metadata, raw_amount, item_proto, _)
    local number = ui_util.format_number(raw_amount, metadata.formatting_precision)

    local plural_parameter = (number == "1") and 1 or 2
    local type_string = (item_proto.type == "fluid") and {"fp.l_fluid"} or {"fp.pl_item", plural_parameter}
    local tooltip = {"", number, " ", type_string, "/", metadata.timescale_string}

    return number, tooltip
end

function processors.belts_or_lanes(metadata, raw_amount, item_proto, _)
    if item_proto.type == "entity" then return nil, nil end  -- raw ores don't make sense here

    local divisor = (item_proto.type == "fluid") and 50 or 1
    local raw_number = raw_amount * metadata.throughput_multiplier * metadata.timescale_inverse / divisor
    local number = ui_util.format_number(raw_number, metadata.formatting_precision)

    local plural_parameter = (number == "1") and 1 or 2
    local tooltip = {"", number, " ", {"fp.pl_" .. metadata.belt_or_lane, plural_parameter}}

    local return_number = (metadata.round_button_numbers) and math.ceil(raw_number - 0.001) or number
    return return_number, tooltip
end

function processors.wagons_per_timescale(metadata, raw_amount, item_proto, _)
    if item_proto.type == "entity" then return nil, nil end  -- raw ores don't make sense here

    local wagon_capacity = (item_proto.type == "fluid") and metadata.fluid_wagon_capacity
      or metadata.cargo_wagon_capactiy * item_proto.stack_size
    local wagon_count = raw_amount / wagon_capacity
    local number = ui_util.format_number(wagon_count, metadata.formatting_precision)

    local plural_parameter = (number == "1") and 1 or 2
    local tooltip = {"", number, " ", {"fp.pl_wagon", plural_parameter}, "/", metadata.timescale_string}

    return number, tooltip
end

function processors.items_per_second_per_machine(metadata, raw_amount, item_proto, machine_count)
    if machine_count == 0 then return 0, "" end  -- avoid division by zero
    if item_proto.type == "entity" then return nil, nil end  -- raw ores don't make sense here

    local raw_number = raw_amount * metadata.timescale_inverse / (math.ceil((machine_count or 1) - 0.001))
    local number = ui_util.format_number(raw_number, metadata.formatting_precision)

    local plural_parameter = (number == "1") and 1 or 2
    local type_string = (item_proto.type == "fluid") and {"fp.l_fluid"} or {"fp.pl_item", plural_parameter}
    -- If machine_count is nil, this shouldn't show /machine
    local per_machine = (machine_count ~= nil) and {"", "/", {"fp.pl_machine", 1}} or ""
    local tooltip = {"", number, " ", type_string, "/", {"fp.second"}, per_machine}

    return number, tooltip
end


-- ** TOP LEVEL **
-- Creates metadata relevant for a whole batch of items
function view_state.generate_metadata(player, subfactory)
    local player_table = data_util.get("table", player)

    local view_states = player_table.ui_state.view_states
    local current_view_name = view_states[view_states.selected_view_id].name
    local belts_or_lanes = player_table.settings.belts_or_lanes
    local round_button_numbers = player_table.preferences.round_button_numbers
    local throughput = prototyper.defaults.get(player, "belts").throughput
    local throughput_divisor = (belts_or_lanes == "belts") and throughput or (throughput / 2)
    local cargo_wagon_capactiy = prototyper.defaults.get(player, "wagons", global.all_wagons.map["cargo-wagon"]).storage
    local fluid_wagon_capacity = prototyper.defaults.get(player, "wagons", global.all_wagons.map["fluid-wagon"]).storage

    return {
        processor = processors[current_view_name],
        timescale_inverse = 1 / subfactory.timescale,
        timescale_string = {"fp." .. TIMESCALE_MAP[subfactory.timescale]},
        adjusted_margin_of_error = MARGIN_OF_ERROR * subfactory.timescale,
        belt_or_lane = belts_or_lanes:sub(1, -2),
        round_button_numbers = round_button_numbers,
        throughput_multiplier = 1 / throughput_divisor,
        formatting_precision = 4,
        cargo_wagon_capactiy = cargo_wagon_capactiy,
        fluid_wagon_capacity = fluid_wagon_capacity
    }
end

function view_state.process_item(metadata, item, item_amount, machine_count)
    local raw_amount = item_amount or item.amount
    if raw_amount == nil or (raw_amount ~= 0 and raw_amount < metadata.adjusted_margin_of_error) then
        return -1, nil
    end

    return metadata.processor(metadata, raw_amount, item.proto, machine_count)
end


function view_state.rebuild_state(player)
    local ui_state = data_util.get("ui_state", player)
    local subfactory = ui_state.context.subfactory

    -- If no subfactory exists yet, choose a default timescale so the UI can build properly
    local timescale = (subfactory) and TIMESCALE_MAP[subfactory.timescale] or "second"
    local singular_bol = data_util.get("settings", player).belts_or_lanes:sub(1, -2)
    local belt_proto = prototyper.defaults.get(player, "belts")
    local cargo_train_proto = prototyper.defaults.get(player, "wagons", global.all_wagons.map["cargo-wagon"])
    local fluid_train_proto = prototyper.defaults.get(player, "wagons", global.all_wagons.map["fluid-wagon"])

    local new_view_states = {
        [1] = {
            name = "items_per_timescale",
            caption = {"", {"fp.pu_item", 2}, "/", {"fp.unit_" .. timescale}},
            tooltip = {"fp.view_state_tt", {"fp.items_per_timescale", {"fp." .. timescale}}}
        },
        [2] = {
            name = "belts_or_lanes",
            caption = {"", belt_proto.rich_text, " ", {"fp.pu_" .. singular_bol, 2}},
            tooltip = {"fp.view_state_tt", {"fp.belts_or_lanes", {"fp.pl_" .. singular_bol, 2},
              belt_proto.rich_text, belt_proto.localised_name}}
        },
        [3] = {
            name = "wagons_per_timescale",
            caption = {"", {"fp.pu_wagon", 2}, "/", {"fp.unit_" .. timescale}},
            tooltip = {"fp.view_state_tt", {"fp.wagons_per_timescale", {"fp." .. timescale},
              cargo_train_proto.rich_text, cargo_train_proto.localised_name,
              fluid_train_proto.rich_text, fluid_train_proto.localised_name}}
        },
        [4] = {
            name = "items_per_second_per_machine",
            caption = {"", {"fp.pu_item", 2}, "/", {"fp.unit_second"}, "/[img=fp_generic_assembler]"},
            tooltip = {"fp.view_state_tt", {"fp.items_per_second_per_machine"}}
        },
        selected_view_id = nil,  -- set below
        timescale = timescale  -- conserve the timescale to rebuild the state
    }

    -- Conserve the previous view selection if possible
    local old_view_states = ui_state.view_states
    local selected_view_id = (old_view_states) and old_view_states.selected_view_id or "items_per_timescale"

    ui_state.view_states = new_view_states
    view_state.select(player, selected_view_id)
end

function view_state.build(player, parent_element)
    local view_states = data_util.get("ui_state", player).view_states

    local table_view_state = parent_element.add{type="table", column_count=#view_states}
    table_view_state.style.horizontal_spacing = 0

    -- Using ipairs is important as we only want to iterate the array-part
    for view_id, _ in ipairs(view_states) do
        table_view_state.add{type="button", tags={mod="fp", on_gui_click="change_view_state", view_id=view_id},
          style="fp_button_push", mouse_button_filter={"left"}}
    end

    return table_view_state
end

function view_state.refresh(player, table_view_state)
    local ui_state = data_util.get("ui_state", player)

    -- Automatically detects a timescale change and refreshes the state if necessary
    local subfactory = ui_state.context.subfactory
    if not subfactory then
        return
    elseif subfactory.current_timescale ~= ui_state.view_states.timescale then
        view_state.rebuild_state(player)
    end

    for _, view_button in ipairs(table_view_state.children) do
        local view_state = ui_state.view_states[view_button.tags.view_id]
        view_button.caption, view_button.tooltip = view_state.caption, view_state.tooltip
        view_button.style = (view_state.selected) and "fp_button_push_active" or "fp_button_push"
        view_button.style.padding = {0, 12}  -- needs to be re-set when changing the style
        view_button.enabled = (not view_state.selected)
    end
end

function view_state.select(player, selected_view)
    local view_states = data_util.get("ui_state", player).view_states

    -- Selected view can be either an id or a name, so we might need to match an id to a name
    local selected_view_id = selected_view
    if type(selected_view) == "string" then
        for view_id, view_state in ipairs(view_states) do
            if view_state.name == selected_view then
                selected_view_id = view_id
                break
            end
        end
    end

    -- Only run any code if the selected view did indeed change
    if view_states.selected_view_id ~= selected_view_id then
        for view_id, view_state in ipairs(view_states) do
            if view_id == selected_view_id then
                view_states.selected_view_id = selected_view_id
                view_state.selected = true
            else
                view_state.selected = false
            end
        end
    end
end


-- ** EVENTS **
view_state.gui_events = {
    on_gui_click = {
        {
            name = "change_view_state",
            handler = (function(player, tags, _)
                view_state.select(player, tags.view_id)

                local compact_view = data_util.get("flags", player).compact_view
                if compact_view then compact_subfactory.refresh(player)
                else main_dialog.refresh(player, "production") end
            end)
        }
    }
}

view_state.misc_events = {
    fp_cycle_production_views = (function(player, _)
        cycle_views(player, "standard")
    end),
    fp_reverse_cycle_production_views = (function(player, _)
        cycle_views(player, "reverse")
    end)
}
