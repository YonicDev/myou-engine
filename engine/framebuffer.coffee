{vec2, vec4, mat4} = require 'vmath'

class FbTexture
    type: 'TEXTURE'
    set: (@gl_tex, @gl_target) ->
        @loaded = true
        @bound_unit = -1
        @is_framebuffer_active = false
    load: ->

component_types =
    BYTE: 0x1400
    UNSIGNED_BYTE: 0x1401
    SHORT: 0x1402
    UNSIGNED_SHORT: 0x1403
    INT: 0x1404
    UNSIGNED_INT: 0x1405
    FLOAT: 0x1406
    HALF_FLOAT: 0x8D61

unused_mat4 = mat4.create()

# Framebuffer class. Use it for off-screen rendering, by creating a {Viewport}
# with a framebuffer as `dest_buffer`.
# Also used internally for cubemaps, filters, post-processing effects, etc.
class Framebuffer
    constructor: (args...)->
        @init args...

    init: (@context, @options) ->
        {
            gl, is_webgl2, extensions, has_float_texture_support,
            has_float_fb_support, has_half_float_fb_support,
        } = @context.render_manager
        {
            size
            use_depth=false
            color_type='FLOAT'
            use_mipmap=false
            use_filter=true
        } = @options
        [@size_x, @size_y] = size
        if not @size_x or not @size_y
            throw Error "Invalid framebuffer size"
        @color_type = color_type
        @use_mipmap = use_mipmap # TODO: coffee-loader bug adding @ above?
        @use_filter = use_filter
        @filters_should_blend = false
        # We're using the existing texture if available so when we're restoring
        # the GL context, references to the texture that already exist in
        # material inputs are still valid
        @texture = @texture or new FbTexture
        @texture.set gl.createTexture(), gl.TEXTURE_2D
        @context.render_manager.bind_texture @texture
        if use_filter
            min_filter = mag_filter = gl.LINEAR
            if @use_mipmap
                min_filter = gl.LINEAR_MIPMAP_NEAREST
        else
            min_filter = mag_filter = gl.NEAREST
            if @use_mipmap
                min_filter = gl.NEAREST_MIPMAP_NEAREST
        gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, mag_filter
        gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, min_filter
        gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE
        gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE
        @tex_type = component_types[color_type]
        internal_format = tex_format = gl.RGBA

        if @tex_type == component_types.FLOAT
            if is_webgl2
                internal_format = gl.RGBA32F
            if use_filter
                supports_float =
                    extensions.texture_float_linear? and has_float_fb_support
            else
                supports_float =
                    has_float_texture_support and has_float_fb_support
            if not supports_float
                # Fall back to half_float_linear, then to byte
                supports_half_float = has_half_float_fb_support
                if use_filter
                    supports_half_float = supports_half_float and \
                        extensions.texture_half_float_linear
                if supports_half_float
                    if is_webgl2
                        internal_format = gl.RGBA16F
                    @tex_type = component_types.HALF_FLOAT
                else
                    @tex_type = component_types.UNSIGNED_BYTE

        gl.texImage2D gl.TEXTURE_2D, 0, internal_format, @size_x, @size_y, 0,
            tex_format, @tex_type, null
        if @use_mipmap
            gl.generateMipmap gl.TEXTURE_2D

        @depth_texture = null
        # TODO: Toggle for using depth texture? Have cubemap depth?
        if use_depth and extensions.depth_texture
            @depth_texture = @depth_texture or new FbTexture
            @depth_texture.set gl.createTexture(), gl.TEXTURE_2D
            @context.render_manager.bind_texture @depth_texture
            gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST
            gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST
            gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT
            gl.texParameteri gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT
            if is_webgl2
                if extensions.texture_float_linear
                    gl.texImage2D gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT32F,
                        @size_x, @size_y, 0, gl.DEPTH_COMPONENT, gl.FLOAT, null
                else
                    gl.texImage2D gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24,
                        @size_x, @size_y, 0, gl.DEPTH_COMPONENT,
                        gl.UNSIGNED_INT, null
            else
                # Always asking for UNSIGNED_INT even though the implementation
                # may choose to use 16 or 24 bits instead, otherwise the depth
                # may be too limited in some cases
                # TODO: Test performance compared to UNSIGNED_SHORT textures
                gl.texImage2D gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT, @size_x,
                    @size_y, 0, gl.DEPTH_COMPONENT, gl.UNSIGNED_INT, null

        @framebuffer = fb = gl.createFramebuffer()
        gl.bindFramebuffer gl.FRAMEBUFFER, fb
        gl.framebufferTexture2D gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
            gl.TEXTURE_2D, @texture.gl_tex, 0
        if use_depth
            if @depth_texture
                gl.framebufferTexture2D gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT,
                    gl.TEXTURE_2D, @depth_texture.gl_tex, 0
            else
                @render_buffer = rb = gl.createRenderbuffer()
                gl.bindRenderbuffer gl.RENDERBUFFER, rb
                gl.renderbufferStorage gl.RENDERBUFFER, gl.DEPTH_COMPONENT16,
                    @size_x, @size_y
                gl.framebufferRenderbuffer gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT,
                    gl.RENDERBUFFER, rb

        @is_complete =
            gl.checkFramebufferStatus(gl.FRAMEBUFFER) == gl.FRAMEBUFFER_COMPLETE
        @has_mipmap = false
        # Quick and dirty way to get the inverse projection matrix
        # used to get the original depth
        @last_viewport = null

        @context.render_manager.unbind_texture @texture
        @context.render_manager.unbind_texture @depth_texture if @depth_texture?
        if rb?
            gl.bindRenderbuffer gl.RENDERBUFFER, null
        gl.bindFramebuffer gl.FRAMEBUFFER, null
        Framebuffer.active_buffer = null
        @context.all_framebuffers.push this

    # @private
    # Remakes the framebuffer after a lost context
    recreate: ->
        if @options
            @init @context, @options

    # Sets the framebuffer as the active one for further rendering operations.
    # Lower left corner is (0,0)
    # @param rect [Array<number>]
    #       Viewport rect in pixels: X position, Y position, width, height.
    enable: (rect=null)->
        {gl} = @context.render_manager
        @has_mipmap = false
        if not rect?
            left = bottom = 0
            size_x = @size_x
            size_y = @size_y
        else
            left = rect[0]
            bottom = rect[1]
            size_x = rect[2]
            size_y = rect[3]
        {active_buffer} = Framebuffer
        if active_buffer == this
            {x,y,z,w} = Framebuffer.active_rect
            if left == x and bottom == y and size_x == z and size_y == w
                return
        @current_size_x = size_x
        @current_size_y = size_y
        if @texture?.bound_unit >= 0
            @context.render_manager.unbind_texture @texture
        if @depth_texture?.bound_unit >= 0
            @context.render_manager.unbind_texture @depth_texture
        gl.bindFramebuffer gl.FRAMEBUFFER, @framebuffer
        gl.viewport left, bottom, size_x, size_y
        vec4.set Framebuffer.active_rect, left, bottom, size_x, size_y
        if active_buffer?.texture? and active_buffer != this
            active_buffer.texture.is_framebuffer_active = false
            active_buffer.depth_texture?.is_framebuffer_active = false
        Framebuffer.active_buffer = this
        @texture?.is_framebuffer_active = true
        @depth_texture?.is_framebuffer_active = true
        Framebuffer.filters_should_blend = @filters_should_blend
        return this

    clear: ->
        @enable()
        {gl} = @context.render_manager
        gl.clearColor 0,0,0,0
        gl.clear 16384 # gl.COLOR_BUFFER_BIT

    # Disables the buffer by setting the main screen as output.
    disable: ->
        {gl} = @context.render_manager
        gl.bindFramebuffer gl.FRAMEBUFFER, null
        Framebuffer.active_buffer = null

    draw_with_filter: (filter, inputs={}) ->
        {render_manager} = @context
        {bg_mesh, gl, render_fb} = render_manager
        material = filter.get_material()
        material.inputs.source.value = @texture
        # We're assuming offsets are always 0,0, since the final position of the
        # viewport is only drawn elsewhere in a buffer
        # or screen that is not read back.
        # Also we're assuming it's only one viewport what we've drawn.
        vec2.set material.inputs.source_size.value, @size_x, @size_y
        vec2.set material.inputs.source_size_inverse.value, 1/@size_x, 1/@size_y
        vec2.set material.inputs.source_scale.value,
            @current_size_x/@size_x, @current_size_y/@size_y
        if (depth_sampler = material.inputs.depth_sampler)? and \
                (depth_texture = render_fb.depth_texture)?
            depth_sampler.value = depth_texture
            vec2.set material.inputs.depth_scale.value,
                @current_size_x/@size_x, @current_size_y/@size_y
        for name, value of inputs
            material.inputs[name].value = value
        material.inputs.projection_matrix_inverse?.value =
            @last_viewport.camera.projection_matrix_inv
        gl.depthMask false
        gl.depthFunc gl.ALWAYS
        if Framebuffer.filters_should_blend
            gl.enable gl.BLEND
        {use_frustum_culling} = render_manager
        render_manager.use_frustum_culling = false
        render_manager.draw_mesh(bg_mesh, unused_mat4, -1, material)
        render_manager.use_frustum_culling = use_frustum_culling
        if Framebuffer.filters_should_blend
            gl.disable gl.BLEND
        gl.depthFunc gl.LEQUAL
        gl.depthMask true

    blit_to: (dest, src_rect, dst_rect, options) ->
        {
            components=['color']
            use_filter=false
        } = options ? {}
        {gl, is_webgl2} = @context.render_manager
        mask = 0
        for c in components
            mask |= {
                color: gl.COLOR_BUFFER_BIT
                depth: gl.DEPTH_BUFFER_BIT
                stencil: gl.STENCIL_BUFFER_BIT
            }[c]
        [srcX, srcY, srcW, srcH] = src_rect
        [dstX, dstY, dstW, dstH] = dst_rect
        # write used width/height for use in filters
        dest.current_size_x = dstW
        dest.current_size_y = dstH
        # TODO: add condition? or separate function?
        if 0
            # blitting, available in webgl 2,
            # required for copying framebuffers with multisampling
            # automatically converts types
            # and resizes (with or without filtering)
            if not is_webgl2
                throw Error "WebGL 1.0 doesn't support blitting"
            filter = if use_filter then gl.LINEAR else gl.NEAREST
            @disable()
            gl.bindFramebuffer gl.READ_FRAMEBUFFER, @framebuffer
            gl.bindFramebuffer gl.DRAW_FRAMEBUFFER, dest.framebuffer
            gl.readBuffer gl.COLOR_ATTACHMENT0
            gl.blitFramebuffer srcX, srcY, srcX+srcW, srcY+srcH,
                                dstX, dstY, dstX+dstW, dstY+dstH,
                                mask, filter
            gl.bindFramebuffer gl.FRAMEBUFFER, null
        else
            # copyTexSubImage2D is available in webgl 1
            # can't copy framebuffers with multisampling
            # can't convert types
            # can't resize
            {current_size_x, current_size_y} = this
            @enable src_rect
            if is_webgl2
                gl.readBuffer gl.COLOR_ATTACHMENT0
            @context.render_manager.bind_texture dest.texture
            gl.copyTexSubImage2D gl.TEXTURE_2D, 0, dstX, dstY, srcX, srcY,
                srcW, srcH
            @current_size_x = current_size_x
            @current_size_y = current_size_y



    bind_to_cubemap_side: (cubemap, side) ->
        # NOTE: It has to be enabled
        {gl} = @context.render_manager
        gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
            gl.TEXTURE_CUBE_MAP_POSITIVE_X+side, cubemap.gl_tex, 0)
        cubemap.is_framebuffer_active = true

    unbind_cubemap: (cubemap) ->
        {gl} = @context.render_manager
        gl.framebufferTexture2D gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0,
            gl.TEXTURE_2D, @texture.gl_tex, 0
        cubemap.is_framebuffer_active = false

    get_framebuffer_status: ->
        {gl} = @context.render_manager
        switch gl.checkFramebufferStatus(gl.FRAMEBUFFER)
            when gl.FRAMEBUFFER_COMPLETE
                'COMPLETE'
            when gl.FRAMEBUFFER_INCOMPLETE_ATTACHMENT
                'INCOMPLETE_ATTACHMENT'
            when gl.FRAMEBUFFER_INCOMPLETE_DIMENSIONS
                'INCOMPLETE_DIMENSIONS'
            when gl.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT
                'INCOMPLETE_MISSING_ATTACHMENT'

    generate_mipmap: ->
        {gl} = @context.render_manager
        if @use_mipmap and not @has_mipmap
            if Framebuffer.active_buffer == this
                gl.bindFramebuffer gl.FRAMEBUFFER, null
                Framebuffer.active_buffer = null
            @context.render_manager.bind_texture @texture
            gl.generateMipmap gl.TEXTURE_2D
            @has_mipmap = true

    # Deletes the buffer from GPU memory.
    destroy: (remove_from_context=true) ->
        {gl} = @context.render_manager
        gl.deleteTexture @texture.gl_tex if @texture?
        gl.deleteTexture @depth_texture.gl_tex if @depth_texture?
        gl.deleteRenderbuffer @render_buffer if @render_buffer?
        gl.deleteFramebuffer @framebuffer
        if remove_from_context
            index = @context.all_framebuffers.indexOf(this)
            if index != -1
                @context.all_framebuffers.splice index, 1

class ByteFramebuffer extends Framebuffer
    init: (context, options) ->
        {size, use_depth} = options
        super context, {size, use_depth, color_type: 'UNSIGNED_BYTE'}

class ShortFramebuffer extends Framebuffer
    init: (context, options) ->
        {size, use_depth} = options
        super context, {size, use_depth, color_type: 'UNSIGNED_SHORT'}

class FloatFramebuffer extends Framebuffer
    init: (context, options) ->
        {size, use_depth} = options
        super context, {size, use_depth, color_type: 'FLOAT'}

# Screen framebuffer target. Usually instanced as `render_manager.main_fb`.
class MainFramebuffer extends Framebuffer

    init: (@context)->
        # sizes set in render_manager.resize()
        @texture = @depth_texture = null
        @framebuffer = null
        @is_complete = true

# TODO: move to context
Framebuffer.active_rect = new vec4.create()
Framebuffer.active_buffer = null
Framebuffer.filters_should_blend = false

module.exports = {Framebuffer, ByteFramebuffer, ShortFramebuffer,
    FloatFramebuffer, MainFramebuffer}
