"""
    RenderModel

Model to keep track of rendering instructions and background color.

 - `instruction_set::AbstractVector{Tuple}`: set of render instructions (function, array of inputs sans ctx, coordinate_system)
 - `background_color::RGB`: background color

## Fields 
- `instruction_set  :: AbstractVector{Tuple} = Array{Tuple}(undef, 0)`
- `background_color :: RGB = colortheme["background"]`
"""
@with_kw mutable struct RenderModel
    instruction_set  :: AbstractVector{Tuple} = Array{Tuple}(undef, 0)
    background_color :: RGB = colortheme["background"]
end

"""
Add an instruction to the rendermodel

INPUT:
    rendermodel   - the RenderModel we are adding the instruction to
    f             - the function to be called, the first argument must be a CairoContext
    args          - tuple of input arguments to f, skipping the CairoContext
    coordinate_system - in which coordinate system are the coordinates given (one of :scene, :camera_pixels, :camera_relative)
      `:scene` - coordinates are physical coordinates in the world frame in unit [meters]
      `:camera_pixels` - coordinates are in pixels and relative to the rectangle selected by the camera in unit [pixels]
      `:camera_relative` - coordinates are in percentages in the range 0 to 1 of the rectangle selected by the camera

ex: add_instruction!(rendermodel, render_text, ("hello world", 10, 20, 15, [1.0,1.0,1.0]))
"""
function add_instruction!(rm::RenderModel, f::Function, args::Tuple; coordinate_system::Symbol=:scene)
    @assert coordinate_system in (:scene, :camera_pixels, :camera_relative) "Invalid coordinate_system"
    push!(rm.instruction_set, (f, args, coordinate_system))
    rm
end

set_background_color!(rm::RenderModel, color::Colorant) = rm.background_color = convert(RGB{U8}, color)
reset_instructions!(rm::RenderModel) = empty!(rm.instruction_set)

"""
    render(
        renderables::AbstractVector;
        camera::Union{Nothing, Camera} = nothing,
        canvas_width::Int64 = (camera === nothing ? DEFAULT_CANVAS_WIDTH : canvas_width(camera)),
        canvas_height::Int64 = (camera === nothing ? DEFAULT_CANVAS_HEIGHT : canvas_height(camera)),
        surface::CairoSurface = CairoSVGSurface(IOBuffer(), canvas_width, canvas_height)
    )

Draw all `renderables` to a `surface` of dimensions `canvas_width` x `canvas_height`.
All renderables must implement the `add_renderable!` function which adds rendering
instructions to the render model.

The provided `camera` should be updated using the  `update_camera!()` function before calling
`render`. If no `camera` is provided, the render function will default to fitting all renderable
objects to the canvas.
"""
function render(renderables::AbstractVector;
    camera::Union{Nothing, Camera} = nothing,
    canvas_width::Int64 = (camera === nothing ? DEFAULT_CANVAS_WIDTH : canvas_width(camera)),
    canvas_height::Int64 = (camera === nothing ? DEFAULT_CANVAS_HEIGHT : canvas_height(camera)),
    surface::CairoSurface = CairoSVGSurface(IOBuffer(), canvas_width, canvas_height)
)
    rendermodel = RenderModel()
    reset_instructions!(rendermodel)
    ctx = creategc(surface)
    for renderable in renderables
        add_renderable!(rendermodel, renderable)
    end
    if camera === nothing
        camera = camera_fit_to_content(rendermodel, ctx, canvas_width, canvas_height)
    end
    render_to_canvas(rendermodel, camera, ctx)
    return surface
end

function render_to_canvas(rendermodel::RenderModel, camera_state::CameraState, ctx::CairoContext)

    # render text if no other instructions
    if isempty(rendermodel.instruction_set)
        render_text(
            ctx, "No rendering instructions found",
            w/2, h/2, 40, colorant"red", true
        )
        return rendermodel  # terminate here
    end

    # fill with background color
    set_source_rgba(ctx, rendermodel.background_color)
    paint(ctx)

    w, h = canvas_width(camera_state), canvas_height(camera_state)

    # reset the transform
    reset_transform(ctx)
    translate(ctx, w/2, h/2)  # translate to image center
    Cairo.scale(ctx, zoom(camera_state), -zoom(camera_state))    # [pix -> m], negative zoom flips up and down
    rotate(ctx, rotation(camera_state))
    x, y = position(camera_state)
    translate(ctx, -x, -y) # translate to camera location

    # execute all instructions
    for tup in rendermodel.instruction_set
        func, content, coordinate_system = tup

        if coordinate_system in (:camera_pixels, :camera_relative)
            save(ctx)
            reset_transform(ctx)
            if (coordinate_system == :camera_relative) Cairo.scale(ctx, w, h) end
            func(ctx, content...)
            restore(ctx)
        elseif coordinate_system == :scene
            if func == render_text
                # deal with the inverted y-axis issue for text rendered
                mat = get_matrix(ctx)
                mat2 = [mat.xx mat.xy mat.x0;
                        mat.yx mat.yy mat.y0]
                pos = mat2*[content[2] content[3] 1.0]'
                content = tuple(content[1], pos..., content[4:end]...)

                save(ctx)
                reset_transform(ctx)
                render_text(ctx, content... )
                restore(ctx)
            else
                # just use the function normally
                func(ctx, content...)
            end
        else
            throw(ErrorException("Invalid coordinate system $(coordinate_system). Must be one of :scene, :camera_pixels, :camera_relative"))
        end
    end

    ctx
end
function render_to_canvas(rendermodel::RenderModel, camera::Camera, ctx::CairoContext)
    render_to_canvas(rendermodel, camera.state, ctx)
end

function Base.write(filename::String, c::CairoSurface)
    ext = split(filename, ".")[end]
    if ext == "png"
        write_to_png(c, filename)
    elseif ext == "svg" || ext == "pdf"
        typ = ccall((:cairo_surface_get_type, Cairo.libcairo), Cint, (Ptr{Nothing},), c.ptr)
        if ( typ == Cairo.CAIRO_SURFACE_TYPE_PDF && ext == "pdf" ) ||
            ( typ == Cairo.CAIRO_SURFACE_TYPE_SVG && ext == "svg" )
            write_stream(filename, c)
        else
            surf_type = typ == Cairo.CAIRO_SURFACE_TYPE_PDF ? "CairoPDFSurface" : "CairoSVGSurface"
            throw(ErrorException("""
                  AutoViz WriteError: Surface type mismatch! You tried to write a $surf_type to a .$ext file.
                  To solve this problem either change the file extension to match the surface type or change the surface type passed to the render function using the keyword `surface=`.
                  """))
        end
    else 
        throw("AutoViz write error: this file extension is not supported, supported extensions are 'png', 'pdf', 'svg'.")
    end
end

function write_stream(filename::String, surface::Cairo.CairoSurfaceIOStream)
    finish(surface)
    seek(surface.stream, 0)
    open(filename, "w") do io
        write(io, read(surface.stream, String))
    end
    return
end



"""
    camera_fit_to_content(rendermodel::RenderModel, ctx::CairoContext, canvas_width::Integer = DEFAULT_CANVAS_WIDTH, canvas_height::Integer = DEFAULT_CANVAS_HEIGHT; percent_border::Real = 0.0)
Helper function that determines camera parameters such that all rendered content fits on the canvas.
"""
function camera_fit_to_content(
    rendermodel::RenderModel, ctx::CairoContext,
    canvas_width::Integer = DEFAULT_CANVAS_WIDTH,
    canvas_height::Integer = DEFAULT_CANVAS_HEIGHT;
    percent_border::Real = 0.1
)

    xmax, xmin, ymax, ymin = -Inf, Inf, -Inf, Inf

    for tup in rendermodel.instruction_set
        f = tup[1]
        in_camera_frame = tup[3]
        if in_camera_frame != :scene
            continue
        end

        (x,y,flag) = (0,0,false)
        if f == render_circle || f == render_round_rect
            (x,y,flag) = (tup[2][1],tup[2][2],true)
        elseif f == render_text
            (x,y,flag) = (tup[2][2],tup[2][3],true)
        elseif f == render_point_trail || f == render_line ||
               f == render_dashed_line || f == render_fill_region

            pts = tup[2][1]
            if isa(pts, AbstractArray{Float64})
                for i in 1 : size(pts, 2)
                    xmax = max(xmax, pts[1,i])
                    xmin = min(xmin, pts[1,i])
                    ymax = max(ymax, pts[2,i])
                    ymin = min(ymin, pts[2,i])
                end
            elseif isa(pts, AbstractVector{VecE2{T}} where T<:Real)
                for P in pts
                    xmax = max(xmax, P.x)
                    xmin = min(xmin, P.x)
                    ymax = max(ymax, P.y)
                    ymin = min(ymin, P.y)
                end
            end

        # vehicles - center + sqrt((width/2)^2 + (height/2)^2)
        elseif f == render_vehicle
            x = tup[2][1]
            y = tup[2][2]
            width = tup[2][5]
            height = tup[2][4]
            bounding_radius = sqrt((width/2)^2 + (height/2)^2)
            xmax = max(xmax, x + bounding_radius)
            xmin = min(xmin, x - bounding_radius)
            ymax = max(ymax, y + bounding_radius)
            ymin = min(ymin, y - bounding_radius)
        end

        if flag
            xmax = max(xmax, x)
            xmin = min(xmin, x)
            ymax = max(ymax, y)
            ymin = min(ymin, y)
        end
    end

    if isinf(xmin) || isinf(ymin)
        camera_state = CameraState(
            position = VecE2(canvas_width/2, canvas_height/2), # [m]
            zoom     = 1.,                                                 # [pix/m]
            rotation = 0.,                                                 # [rad]
            canvas_width = canvas_width,                                   # [px]
            canvas_height = canvas_height                                  # [px]
        )
        @warn "no render instructions found"
    else

        if xmax < xmin
            xmax = xmin + 1.0
        end
        if ymax < ymin
            ymax = ymin + 1.0
        end

        # compute zoom to fit
        world_width = xmax - xmin
        world_height = ymax - ymin
        canvas_aspect = canvas_width / canvas_height
        world_aspect = world_width / world_height

        if world_aspect > canvas_aspect
            # expand height to fit
            half_diff =  (world_width * canvas_aspect - world_height) / 2
            world_height = world_width * canvas_aspect # [m]
            ymax += half_diff
            ymin -= half_diff
        else
            # expand width to fit
            half_diff = (canvas_aspect * world_height - world_width) / 2
            world_width = canvas_aspect * world_height
            xmax += half_diff
            xmin -= half_diff
        end

        camera_state = CameraState(
            position = VecE2(xmin + world_width/2, ymin + world_height/2), # [m]
            zoom     = (canvas_width*(1-percent_border)) / world_width,    # [pix/m]
            rotation = 0.,                                                 # [rad]
            canvas_width = canvas_width,                                   # [px]
            canvas_height = canvas_height                                  # [px]
        )

    end
    return camera_state
end
