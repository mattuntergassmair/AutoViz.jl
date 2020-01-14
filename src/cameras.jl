"""
Representation of camera parameters such as position, rotation and zoom level.

 - `camera_center::VecE2`: position of camera in [N,E] relative to the mean point. meters
 - `camera_zoom::Float64`: camera zoom in [pix/m]
 - `camera_rotation::Float64`: camera rotation in [rad]
"""
@with_kw mutable struct CameraState
    position  :: VecE2 = VecE2(0.,0.)
    zoom      :: Float64 = 1.
    rotation  :: Float64 = 0.
    canvas_width  :: Int64 = DEFAULT_CANVAS_WIDTH
    canvas_height :: Int64 = DEFAULT_CANVAS_HEIGHT
end
position(cs::CameraState) = cs.position
zoom(cs::CameraState) = cs.zoom
rotation(cs::CameraState) = cs.rotation
canvas_width(cs::CameraState) = cs.canvas_width
canvas_height(cs::CameraState) = cs.canvas_height

camera_move!(cs::CameraState, dx::Real, dy::Real) = cs.position = cs.position + VecE2(dx, dy)
camera_move!(cs::CameraState, Δ::VecE2) = cs.position = cs.position + Δ
camera_move_pix!(cs::CameraState, dx::Real, dy::Real) = cs.position = cs.position + VecE2(dx/cs.zoom, dy/cs.zoom)
camera_move_pix!(cs::CameraState, Δ::VecE2) = cs.position = cs.position + VecE2(Δ.x/cs.zoom, Δ.y/cs.zoom)
camera_rotate!(cs::CameraState, θ::Real) = cs.rotation += θ # [radians]
camera_zoom!(cs::CameraState, factor::Real) = cs.zoom *= factor

function set_camera!(
    cs::CameraState;
    x::Real=cs.position.x,
    y::Real=cs.position.y,
    zoom::Real=cs.zoom,
    rotation::Real=cs.rotation
)
    cs.position = VecE2(x,y)
    cs.zoom = zoom
    cs.rotation = rotation
    return cs
end
reset_camera!(cs::CameraState) = set_camera!(cs, x=0., y=0., zoom=1., rotation=0.)


"""
Camera abstract type
"""
abstract type Camera end
position(c::Camera) = position(c.state)
zoom(c::Camera) = zoom(c.state)
rotation(c::Camera) = rotation(c.state)
canvas_width(c::Camera) = canvas_width(c.state)
canvas_height(c::Camera) = canvas_height(c.state)

"""
Static  camera, does nothing
"""
struct StaticCamera <: Camera
    state::CameraState
end
StaticCamera(;kwargs...) = StaticCamera(CameraState(;kwargs...))
update_camera!(::StaticCamera, ::Frame) = nothing

"""
Camera which follows the vehicle with ID `target_id`.
By default, the target vehicle is tracked in x and y direction.
Tracking in either direction can be disabled by setting the 
`x` or `y` keys to a desired value.
"""
mutable struct TargetFollowCamera{I} <: Camera where I
    state::CameraState
    target_id::I
    x::Float64
    y::Float64
end
function TargetFollowCamera(target_id; x=NaN, y=NaN, kwargs...)
    TargetFollowCamera(CameraState(;kwargs...), target_id, x, y)
end

function update_camera!(camera::TargetFollowCamera{I}, scene::Frame{Entity{S,D,I}}) where {S,D,I}
    target = get_by_id(scene, camera.target_id)
    x, y = posg(target.state)[1:2]
    x = isnan(camera.x) ? x : camera.x
    y = isnan(camera.y) ? y : camera.y
    set_camera!(camera.state, x=x, y=y)
end

"""
Camera which gradually changes the zoom level of the scene to `zoom_target` with step size `dz`.
"""
mutable struct ZoomingCamera <: Camera
    state::CameraState
    zoom_target::Float64
    dz::Float64
end
function ZoomingCamera(;zoom_target=20., dz=.5, kwargs...)
    ZoomingCamera(CameraState(;kwargs...), zoom_target, dz)
end

function update_camera!(camera::ZoomingCamera, scene::Frame{E}) where {E<:Entity}
    zt, zc = camera.zoom_target, zoom(camera)
    if zt < zc  # zooming in 
        set_camera!(camera.cs, zoom=max(zt, zc-camera.dz))
    elseif zt > zc  # zooming out
        set_camera!(camera.cs, zoom=min(zt, zc+camera.dz))
    end
end

"""
    SceneFollowCamera{R<:Real}

Camera centered over all vehicles.

By default, the scene is tracked in x and y direction and the zoom level 
is adapted to fit all vehicles in the scene. Tracking in either direction
can be disabled by setting the `x` or `y` keys to a desired value. The
zoom level can be fixed by passing a value to `zoom`.
The value of `padding` specifies the width of the additional border around
the zoomed-in area.
"""
struct SceneFollowCamera <: Camera
    state::CameraState
    x::Float64
    y::Float64
    zoom::Float64
    padding::Float64
    min_width::Float64
    min_height::Float64
end
SceneFollowCamera(; x=NaN, y=NaN, zoom=NaN, padding=4., kwargs...) = SceneFollowCamera(CameraState(;kwargs...), x, y, zoom, padding, 10, 10)
function update_camera!(camera::SceneFollowCamera, scene::Frame{E}) where {E<:Entity}
    if isnan(camera.zoom)
        pos = [posg(veh.state) for veh in scene]
        X = [p.x for p in pos]
        Y = [p.y for p in pos]
        p = camera.padding
        x_min, x_max = minimum(X)-p, maximum(X)+p
        y_min, y_max = minimum(Y)-p, maximum(Y)+p
        width = max(x_max-x_min, camera.min_width)
        height = max(y_max-y_min, camera.min_height)
        x_zoom = canvas_width(camera) / width
        y_zoom = canvas_height(camera) / height
        x_zoom, y_zoom
        x = isnan(camera.x) ? (x_min+x_max)/2 : camera.x
        y = isnan(camera.y) ? (y_min+y_max)/2 : camera.y
        zoom = min(x_zoom, y_zoom)
    else
        # TODO: is following the center of mass really the best thing to do?
        C = sum([posg(veh.state)[1:2] for veh in scene])/length(scene)  # center of mass
        x = isnan(camera.x) ? C[1] : camera.x
        y = isnan(camera.y) ? C[2] : camera.y
        zoom = camera.zoom
    end
    
    set_camera!(camera.state, x=x, y=y, zoom=zoom)
end


"""
Composition of several cameras. The `update_camera` actions of the individual cameras are applied in the order in which they are saved in the `cameras` array.
States of individual cameras are ignored, the state of the composed camera is the one that will be used for rendering.

Example Usage

    cam = ComposedCamera(cameras=[SceneFollowCamera(), ZoomingCamera()])
"""
mutable struct ComposedCamera <: Camera
    state::CameraState
    cameras::Array{Camera}
end
ComposedCamera(cameras; kwargs...) = ComposedCamera(CameraState(;kwargs...), cameras)

function update_camera!(camera::ComposedCamera, scene::Frame{E}) where {E<:Entity}
    for cam in camera.cameras
        update_camera!(camera.cs, cam, scene)
    end
end
