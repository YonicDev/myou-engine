
{vec3} = require 'vmath'
{addListener, removeListener} = require 'spur-events'

class Behaviour
    id = ''
    constructor: (@scene, options={})->
        if @scene?.type != 'SCENE'
            throw 'Expected a scene'
        {@context} = @scene
        {
            objects
            @viewports=@context.canvas_screen.viewports[...]
            #TODO: destroy or improve when we have GLRay
            @ray_int_mask=-1
        } = options
        if not @id
            @id = (Math.random()+'')[2...]

        @assignment_times = {}
        @objects = []
        if objects
            for ob,i in objects
                if ob?
                    @assign ob
                else
                    throw "Behaviour 'objects' list has a null element at index #{i}"

        @_root = @context.root
        @context.behaviours.push @
        @init_time = performance.now()
        @_enabled = false
        @_object_under_pointer = {}
        @_last_hit = {}
        @_objects_frame_callback = _frame_callback = null
        @_prev_events = {}
        @_over_viewport = null
        @_locked_viewport = null
        @_real_viewports = @viewports # to be modified by debug camera
        @_menu_prevent_default = null
        @_object_picking_method = ''
        @_pick_on_move = false
        @enable()
        @on_init?()
        if @_object_picking_method == '' and (@on_object_pointer_down? or @on_object_pointer_up?\
            or @on_object_pointer_move? or @on_object_pointer_over? or @on_object_pointer_out?)
                # TODO: Warn with a timer?
                console.warn "There are on_object_pointer_* events but object picking is disabled."
                console.warn 'Add "this.enable_object_picking()" to on_init()'

    enable: ->
        if not @_enabled
            @_create_events()
            @scene.post_draw_callbacks.push @_add_callbacks
            if @_menu_prevent_default?
                @_root.addEventListener 'contextmenu', @_menu_prevent_default
            @_enabled = true

    disable: ->
        if @_enabled
            @_destroy_events()
            @scene.post_draw_callbacks.push @_remove_callbacks
            if @_menu_prevent_default?
                @_root.removeEventListener 'contextmenu', @_menu_prevent_default
            @_enabled = false

    age: ->
        performance.now() - @init_time

    assignment_age: (object)->
        performance.now() - @assignment_times[object.name]

    assign: (object)->
        if @id of object.behaviours
            throw "#{object.name} already has a behaviour with id #{@id}"
        if object.scene != @scene
            throw "Object #{object.name} is not in expected scene #{@scene.name}"
        object.behaviours[@id] = @
        @objects.push(object)
        @assignment_times[object.name] = performance.now()
        @on_init?(object)

    unassign: (object)->
        i = object.behaviours.indexOf @
        if i > -1 then object.behaviours.splice(i, 1)

        i = @objects.indexOf object
        if i > -1 then @objects.splice(i, 1)

    disable_context_menu: ->
        if not @_menu_prevent_default?
            @_menu_prevent_default = (e) -> e.preventDefault()
            if @_enabled
                @_root.addEventListener 'contextmenu', @_menu_prevent_default
        return

    enable_context_menu: ->
        if @_menu_prevent_default?
            @_root.removeEventListener 'contextmenu', @_menu_prevent_default
            @_menu_prevent_default = null
        return

    enable_object_picking: (options={}) ->
        {
            method='physics'
        } = options
        @disable_object_picking()
        if @_enabled
            # TODO: make more efficient?
            @_destroy_events()
            @_create_events()
        method = {physics: 'phy'}[method]
        if not method?
            throw "Object picking method not supported: "+method
        @_object_picking_method = method
        return

    disable_object_picking: ->
        @_object_picking_method = ''
        @_pick_on_move = false
        return

    pick_object: (x, y, viewport) ->
        switch @_object_picking_method
            when ''
                null
            when 'phy'
                if not viewport?
                    {x, y, viewport} = @context.canvas_screen.get_viewport_coordinates x, y
                {width, height} = viewport
                camera = viewport.debug_camera or viewport.camera
                pos = camera.get_world_position()
                rayto = camera.get_ray_direction(x/width, y/height)
                vec3.add rayto, rayto, pos
                return @scene.world.ray_test pos, rayto, @int_mask
        return {}

    _add_callbacks: =>
        @_remove_callbacks()
        if @on_tick?
            @_frame_callback = (scene, frame_duration) =>
                @on_tick frame_duration
            @scene.pre_draw_callbacks.push @_frame_callback
        if @on_object_tick?
            @_objects_frame_callback = (scene, frame_duration) =>
                for ob in @objects
                    @on_object_tick(ob, frame_duration)
                return
            @scene.pre_draw_callbacks.push @_objects_frame_callback
        return

    _remove_callbacks: =>
        pdc = @scene.pre_draw_callbacks
        if @_objects_frame_callback?
            pdc.splice pdc.indexOf(@_objects_frame_callback), 1
        if @_frame_callback?
            pdc.splice pdc.indexOf(@_frame_callback), 1
        @_objects_frame_callback = _frame_callback = null

    _on_pointer_down: (event) =>
        x = event.clientX - @context.root_rect.left - pageXOffset
        y = event.clientY - @context.root_rect.top - pageYOffset
        prev = @_prev_events['mouse']
        if not prev?
            prev = @_prev_events['mouse'] = {x, y}
        prev.x = x; prev.y = y
        {x, y, viewport} = @context.canvas_screen.get_viewport_coordinates x, y
        if viewport in @_real_viewports
            {button, buttons, shiftKey, ctrlKey, altKey, metaKey} = event
            @_locked_viewport = viewport
            @on_pointer_down? {x, y, delta_x: 0, delta_y: 0, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport}
            if @on_object_pointer_down?
                {object, point, normal} = @pick_object x, y, viewport
                if object?
                    @on_object_pointer_down {
                        x, y, delta_x: 0, delta_y: 0, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport
                        object, point, normal
                    }
        return

    _on_pointer_up: (event) =>
        x = event.clientX - @context.root_rect.left - pageXOffset
        y = event.clientY - @context.root_rect.top - pageYOffset
        prev = @_prev_events['mouse']
        if not prev?
            prev = @_prev_events['mouse'] = {x, y}
        delta_x = x - prev.x
        delta_y = y - prev.y
        prev.x = x; prev.y = y
        # TODO: Should we only lock outside the window?
        if @_locked_viewport?
            viewport = @_locked_viewport
            {x, y} = viewport.get_viewport_coordinates x, y
            @_locked_viewport = null
        else
            {x, y, viewport} = @context.canvas_screen.get_viewport_coordinates x, y
        if viewport in @_real_viewports
            {button, buttons, shiftKey, ctrlKey, altKey, metaKey} = event
            @on_pointer_up {x, y, delta_x, delta_y, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport}
            if @on_object_pointer_up?
                {object, point, normal} = @pick_object x, y, viewport
                if object?
                    @on_object_pointer_up {
                        x, y, delta_x: 0, delta_y: 0, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport
                        object, point, normal
                    }
        return

    _on_pointer_move: (event) =>
        # TODO: Use pointer IDs, both for deltas and for viewport/object over/out
        x = event.clientX - @context.root_rect.left - pageXOffset
        y = event.clientY - @context.root_rect.top - pageYOffset
        prev = @_prev_events['mouse']
        if not prev?
            prev = @_prev_events['mouse'] = {x, y}
        delta_x = x - prev.x
        delta_y = y - prev.y
        prev.x = x; prev.y = y
        {button, buttons, shiftKey, ctrlKey, altKey, metaKey} = event
        # TODO: Should we only lock outside the window?
        if @_locked_viewport?
            viewport = @_locked_viewport
            {x, y} = viewport.get_viewport_coordinates x, y
        else
            if event.type != 'pointerout'
                {x, y, viewport} = @context.canvas_screen.get_viewport_coordinates x, y
                if @_pick_on_move and viewport?
                    # we rely in these being hoisted to the top as "undefined"
                    {object, point, normal} = @pick_object x, y, viewport
        if @_over_object? and @_over_object != object
            @on_object_pointer_out? {
                x, y, delta_x: 0, delta_y: 0, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport
                object: @_over_object, point, normal
            }
        if @_over_viewport? and @_over_viewport != viewport
            @on_pointer_out? {x, y, delta_x, delta_y, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport: @_over_viewport}
            @_over_viewport = null
        if viewport in @_real_viewports
            if object? and @_over_object != object
                @on_object_pointer_over? {
                    x, y, delta_x: 0, delta_y: 0, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport
                    object, point, normal
                }
                @_over_object = object
            out_event = {x, y, delta_x, delta_y, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport}
            if not @_over_viewport?
                @_over_viewport = viewport
                @on_pointer_over? out_event
            if event.type != 'pointerout'
                @on_pointer_move? out_event
                object? and @on_object_pointer_move? {
                    x, y, delta_x: 0, delta_y: 0, button, buttons, shiftKey, ctrlKey, altKey, metaKey, viewport
                    object, point, normal
                }
        return

    # TODO: Detect full screen canvas/root to decide whether to fire the events
    # always or only after clicking ("focusing") it
    _on_key_down: (event) =>
        # Only sending members that are well supported, easy, and not obsolete
        {key, location, shiftKey, ctrlKey, altKey, metaKey} = event
        @on_key_down({key, location, shiftKey, ctrlKey, altKey, metaKey})

    _on_key_up: (event) =>
        {key, location, shiftKey, ctrlKey, altKey, metaKey} = event
        @on_key_up({key, location, shiftKey, ctrlKey, altKey, metaKey})

    _on_wheel_listener: (event) =>
        x = event.clientX - @context.root_rect.left - pageXOffset
        y = event.clientY - @context.root_rect.top - pageYOffset
        if @_locked_viewport?
            viewport = @_locked_viewport
            {x, y} = viewport.get_viewport_coordinates x, y
        else
            {x, y, viewport} = @context.canvas_screen.get_viewport_coordinates x, y
        if viewport in @_real_viewports
            {deltaX: delta_x, deltaY: delta_y, shiftKey, ctrlKey, altKey, metaKey} = event
            if event.deltaMode == 1
                delta_x *= 18
                delta_y *= 18
            steps_x = Math.round delta_x / (18*3)
            steps_y = Math.round delta_y / (18*3)
            @on_wheel {delta_x, delta_y, steps_x, steps_y, x, y, shiftKey, ctrlKey, altKey, metaKey}

    _create_events: ->
        root = @_root
        @on_pointer_over? and addListener root, 'pointerover', @_on_pointer_over
        @on_pointer_out? and addListener root, 'pointerout', @_on_pointer_out
        if @on_pointer_down? or @on_object_pointer_down?
            addListener root, 'pointerdown', @_on_pointer_down
        if @on_pointer_up? or @on_object_pointer_up?
            addListener root, 'pointerup', @_on_pointer_up
        if @on_pointer_move? or @on_pointer_over? or @on_pointer_out? or\
                @on_object_pointer_move? or @on_object_pointer_over? or @on_object_pointer_out?
            addListener window, 'pointermove', @_on_pointer_move
            addListener window, 'pointerout', @_on_pointer_move
        @_pick_on_move = @on_object_pointer_move? or @on_object_pointer_over?
        @on_key_down? and window.addEventListener 'keydown', @_on_key_down
        @on_key_up? and window.addEventListener 'keyup', @_on_key_up
        @on_wheel? and root.addEventListener 'wheel', @_on_wheel_listener
        # @on_click? and addListener root, 'click', @on_click

    _destroy_events: ->
        root = @_root
        @on_pointer_over? and removeListener root, 'pointerover', @_on_pointer_over
        @on_pointer_out? and removeListener root, 'pointerout', @_on_pointer_out
        if @on_pointer_down? or @on_object_pointer_down?
            removeListener root, 'pointerdown', @_on_pointer_down
        if @on_pointer_up? or @on_object_pointer_up?
            removeListener root, 'pointerup', @_on_pointer_up
        if @on_pointer_move? or @on_pointer_over? or @on_pointer_out? or\
                @on_object_pointer_over? or @on_object_pointer_out?
            removeListener window, 'pointermove', @_on_pointer_move
            removeListener window, 'pointerout', @_on_pointer_move
        @on_key_down? and window.removeEventListener 'keydown', @_on_key_down
        @on_key_up? and window.removeEventListener 'keyup', @_on_key_up
        @on_wheel? and root.removeEventListener 'wheel', @_on_wheel_listener
        # @on_click? and removeListener root, 'click', @on_click



module.exports = {Behaviour}