function render!(
    rendermodel::RenderModel,
    veh::Vehicle1D,
    color::Colorant=RGB(rand(), rand(), rand())
    )

    s = veh.state.s
    add_instruction!(rendermodel, render_vehicle, (s, 0.0, 0.0, veh.def.length, veh.def.width, color))
    return rendermodel
end

function render!(
    rendermodel::RenderModel,
    veh::Vehicle,
    color::Colorant=RGB(rand(), rand(), rand())
    )

    p = veh.state.posG
    add_instruction!(rendermodel, render_vehicle, (p.x, p.y, p.θ, veh.def.length, veh.def.width, color))
    return rendermodel
end
function render!(
    rendermodel::RenderModel,
    veh::Entity{VehicleState, BicycleModel, Int},
    color::Colorant=RGB(rand(), rand(), rand())
    )

    veh2 = Vehicle(veh.state, veh.def.def, veh.id)
    render!(rendermodel, veh2, color)
end