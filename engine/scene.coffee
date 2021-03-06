{mat4, vec3, quat, color4} = require 'vmath'
{fetch_objects} = require './fetch_assets'
loader = null
{Probe} = require './probe'
{World, load_physics_engine} = require './physics/bullet'
{CanvasScreen} = require './screen'

_collision_seq = 0

class Scene
    type: 'SCENE'
    constructor: (context, name, options={})->
        existing = context.scenes[name]
        return existing if existing
        @context = context
        @name = name
        if context.scenes[name]?
            throw Error "Scene #{name} already exists"
        context.scenes[name] = @
        @enabled = false
        @children = []
        @auto_updated_children = []
        @mesh_passes = [[], [], []]
        @bg_pass = []
        @fg_pass = []
        @lamps = []
        @armatures = []
        @objects = dict()
        # Just like objects but used for parenting (no global name collision)
        @parents = dict()
        @materials = dict()
        @textures = dict()
        @active_camera = null
        @physics_enabled = false
        @world = new World this
        @background_color = color4.new 0,0,0,1
        @ambient_color = color4.new 0,0,0,1
        @bsdf_samples = 16
        @lod_bias = -0.5
        @world_material = null
        @background_probe = null
        @background_probe_data = null
        @probes = []
        @_children_are_ordered = true
        @last_shadow_render_tick = 0
        @last_update_matrices_tick = 0
        @pre_draw_callbacks = []
        @post_draw_callbacks = []
        @frame_start = 0
        @frame_end = 0
        @anim_fps = 30
        @markers = []
        @markers_by_name = dict()
        @extra_data = null
        @data_dir = context.options.data_dir
        @original_scene_name = ''
        @foreground_planes = []
        @_debug_draw = null
        @shader_library = ''
        @groups = {}
        @_active_camera_name = ''
        {add_to_loaded_scenes=true} = options
        if add_to_loaded_scenes
            context.loaded_scenes.push name

    add_object: (ob, name='no_name', parent_name='', parent_bone)->
        if ob.scene?
            if ob.scene == this
                return
            else
                ob.scene.remove_object ob
        ob.scene = @

        @children.push ob
        if not ob.static
            @auto_updated_children.push ob

        n = name
        while @context.objects[n]
            _collision_seq += 1
            n = name + '$' + _collision_seq
        ob.name = n
        ob.original_name = name
        @objects[n] = @context.objects[n] = ob
        @parents[name] = ob
        #print "Added", name

        # Objects are always ordered parent-first
        p = @parents[parent_name]
        if p
            ob.parent = p
            p.children.push ob
            if p.type=='ARMATURE' and parent_bone
                bone = p.bones[parent_bone]
                if bone?
                    ob.parent_bone_index = p._bone_list.indexOf bone
                    bone.object_children.push ob

        if ob.type=='MESH'
            for p in [0..2]  # TODO: not having number of passes hardcoded
                if p in ob.passes
                    if ob.properties.foreground_pass
                        @fg_pass.push ob
                    else if p == 0 and ob.properties.background_pass
                        @bg_pass.push ob
                    else
                        @mesh_passes[p].push ob
        if ob.type=='LAMP'
            @lamps.push ob
        if ob.type=='ARMATURE'
            @armatures.push ob
        return

    remove_object: (ob, recursive=true)->
        @children.splice _,1 if (_ = @children.indexOf ob) != -1
        if not ob.static
            if (index = @auto_updated_children.indexOf ob) != -1
                @auto_updated_children.splice index,1
        delete @objects[ob.name]
        delete @parents[ob.original_name]
        if ob.type=='MESH'
            # TODO: remake this when remaking the pass system
            # NOTE: not removing from translucent pass because it's unused
            @mesh_passes[0].splice _,1 if (_ = @mesh_passes[0].indexOf ob)!=-1
            @mesh_passes[1].splice _,1 if (_ = @mesh_passes[1].indexOf ob)!=-1
            if @fg_pass? and (_ = @fg_pass.indexOf ob)!=-1
                @fg_pass.splice _,1
            if @bg_pass? and (_ = @bg_pass.indexOf ob)!=-1
                @bg_pass.splice _,1
            ob.data?.remove ob
        if ob.type=='LAMP'
            ob.destroy_shadow()
            @lamps.splice _,1 if (_ = @lamps.indexOf ob)!=-1
        if ob.type=='ARMATURE'
            @armatures.splice _,1 if (_ = @armatures.indexOf ob)!=-1
            if ob.parent_bone_index != -1
                oc = ob.parent._bone_list[ob.parent_bone_index].object_children
                oc.splice _,1 if (_ = oc.indexOf ob)!=-1

        ob.body.destroy()

        # TODO: Remove probes if they have no users

        for b in ob.behaviours
            b.unassign ob

        if recursive
            for child in ob.children by -1
                @remove_object child
        return

    make_parent: (parent, child, options={})->
        if typeof options == 'boolean'
            console.warn "Deprecated parenting call,
                use {keep_transform: #{options}} instead of #{options}"
            options = {keep_transform: options}
        {keep_transform=true} = options
        if child.parent
            @clear_parent child, keep_transform
        auchildren = @auto_updated_children
        # TODO: should we store the index in the objects
        # to make this check faster?
        parent_index = auchildren.indexOf(parent)
        child_index = auchildren.indexOf(child)
        if parent_index == -1
            throw Error "Object '#{parent.name}' is not part of scene
                '#{@name}'. Both parent and child must belong to it."
        if child_index == -1
            throw Error "Object '#{parent.name}' is not part of scene
                '#{@name}'. Both parent and child must belong to it."
        if keep_transform
            wm = child.get_world_matrix()
            {position, rotation} = parent.get_world_position_rotation()
            {rotation_order} = child
            child.set_rotation_order 'Q'
            rot = child.rotation
            p_rot = quat.invert quat.create(), rotation
            quat.mul rot, p_rot, rot
            child.set_rotation_order rotation_order
            {scale} = child
            {m00, m01, m02, m04, m05, m06, m08, m09, m10} = parent.world_matrix
            scale.x /= Math.sqrt m00*m00 + m01*m01 + m02*m02
            scale.y /= Math.sqrt m04*m04 + m05*m05 + m06*m06
            scale.z /= Math.sqrt m08*m08 + m09*m09 + m10*m10
            parent_inv = mat4.invert mat4.create(), parent.world_matrix
            mat4.mul wm, parent_inv, wm
            vec3.set child.position, wm.m12, wm.m13, wm.m14
        mat4.identity child.matrix_parent_inverse
        child.parent = parent
        parent.children.push child
        if parent_index > child_index
            # When this is set to false, reorder_children() is called
            # in update_all_matrices()
            @_children_are_ordered = false

    clear_parent: (child, options={})->
        parent = child.parent
        if parent?
            if typeof options == 'boolean'
                console.warn "Deprecated parenting call,
                    use {keep_transform: #{options}} instead of #{options}"
                options = {keep_transform: options}
            {keep_transform=true} = options
            if keep_transform
                {rotation_order} = child
                {position, rotation} = child.get_world_position_rotation()
                vec3.copy child.position, position
                quat.copy child.rotation, rotation
                child.rotation_order = 'Q'
                child.set_rotation_order rotation_order
                {scale, world_matrix} = child
                {m00, m01, m02, m04, m05, m06, m08, m09, m10} = world_matrix
                scale.x = Math.sqrt m00*m00 + m01*m01 + m02*m02
                scale.y = Math.sqrt m04*m04 + m05*m05 + m06*m06
                scale.z = Math.sqrt m08*m08 + m09*m09 + m10*m10
            if (index = parent.children.indexOf child) != -1
                parent.children.splice index,1
            child.parent = null
            child.parent_bone_index = -1

    # Makes sure all scene children are in order for correct matrix calculations
    reorder_children: ->
        # TODO: Only the objects marked as unordered need to be resolved here!
        #       (make a new list and append to children)
        children = @auto_updated_children
        index = 0
        reorder = (ob)->
            if not ob.static
                children[index++] = ob
            for c in ob.children
                reorder c
        # this @children is not a typo
        for ob in @children when not ob.parent
            reorder ob
        @_children_are_ordered = true

    update_all_matrices: ->
        if @_children_are_ordered == false
            @reorder_children()
        # TODO: do this only for visible and modified objects
        #       (also, this is used in LookAt and other nodes)
        for ob in @armatures
            # TODO: Be smarter about when this is needed
            # (and) when to draw meshes with armatures too
            ob.recalculate_bone_matrices()
            # for c in ob.children
            #     if c.visible
            #         ob.recalculate_bone_matrices()
            #         break
        for ob in @auto_updated_children
            ob._update_matrices()
        return

    set_objects_auto_update_matrix: (objects, auto_update) ->
        static_ = not auto_update
        for ob in objects
            ob.static = static_
        # TODO for performance: do this only once? push and pop objects?
        count = 0
        for ob in @children when not ob.static
            count++
        @auto_updated_children.length = count
        @_children_are_ordered = false
        return

    destroy: ->
        for ob in @children[...]
            @remove_object ob, false
            delete @context.objects[ob.name]
        @world.destroy()

        # Reduce itself to a stub by deleting itself and copying callbacks
        stub = @context.scenes[@name] = new Scene @context
        stub.name = @name
        stub.pre_draw_callbacks = @pre_draw_callbacks
        stub.post_draw_callbacks = @post_draw_callbacks
        stub.logic_ticks = @logic_ticks

        # TODO: unload textures, etc (or defer unloading to next scene load)
        # remove texture.users and garabage collect them after textures
        # of the next scene are enumerated

        # TODO: test this
        for screen in @context.screens
            for v,i in screen.viewports by -1
                if v.camera.scene == @
                    screen.viewports.splice i, 1
        return

    # Loads data required to use the scene. The things that can be loaded are:
    #
    # * visible: Loads visible meshes and the textures of their materials.
    # * physics: Loads the physics engine and meshes used for physics.
    #
    # @param items... [Array<String>] List of elements to load. Each one must be
    #       one of: 'visible', 'physics', 'all'
    # @option options [boolean] fetch_textures
    #       Whether to fetch textures when they're not loaded already.
    # @option options [number] texture_size_ratio
    #       Quality of textures specified in ratio of number of pixels.
    # @option options [boolean] load_videos
    #       Whether to load video textures.
    # @option options [number] max_mesh_lod
    #       Quality of meshes specified in LoD polycount ratio.
    # @return [Promise]
    load: (items...) ->
        options = {}
        if typeof items[items.length-1] == 'object'
            options = items.pop()

        {visible, physics, all} =
            @_ensure_items items, ['visible', 'physics', 'all']

        objects = []

        for ob in @children
            ob_being_loaded = null
            if all or (visible and ob.visible)
                ob_being_loaded = ob
                objects.push ob

            if physics
                phy_mesh = ob.body.get_physics_mesh()
                if phy_mesh? and phy_mesh != ob_being_loaded \
                        and not phy_mesh.data?
                    objects.push phy_mesh

        promise = fetch_objects(objects, options).then(=>@)

        if physics
            # TODO: Handle case without webpack
            if @context.webpack_flags?.include_bullet
                phy_promise = load_physics_engine()
                promise = Promise.all([promise, phy_promise]).then =>
                    @world.instance()
            else
                throw Error "Bullet has not been included in this build.
                    Enable the flag 'include_bullet' in webpack.config.js,
                    or don't load/enable physics."
        if visible or all
            promise = Promise.all([
                promise
                @world_material?.load(options) or Promise.resolve()
            ])
        return promise.then(=>this)

    # Loads a list of objects, returns a promise
    # @param list [array] List of objects to load.
    # @option options [boolean] fetch_textures
    #       Whether to fetch textures when they're not loaded already.
    # @option options [number] texture_size_ratio
    #       Quality of textures specified in ratio of number of pixels.
    # @option options [number] max_mesh_lod
    #       Quality of meshes specified in LoD polycount ratio.
    # @return [Promise]
    load_objects: (list, options={})->
        if not list?.length?
            throw  Error "Invalid arguments, expects (list, options). Did you
                        mean 'load_all_objects()'?"
        # TODO: This may not work the second time is not called.
        # Meshes should always return data's promises

        return Promise.all([
            fetch_objects(list, options)
            @world_material?.load(options) or Promise.resolve()
        ]).then(=>@)

    unload_invisible_objects: (options) ->
        invisible_objects = for ob in @children when not ob.visible and ob.data
            ob
        @unload_objects invisible_objects, options

    unload_objects: (list, options={}) ->
        # TODO: Cancel/ignore pending fetches!!
        # TODO: Add unique IDs to speed up presence lookup in lists?
        # TODO: Textures will be moved from shader to material.
        # TODO: Have an option for just unloading from GPU?
        {unload_textures=true} = options
        used_textures = []
        if unload_textures
            for _,ob of @context.objects when ob.type=='MESH' and ob not in list
                for mat in ob.materials
                    for tex in mat.last_shader?.textures or []
                        used_textures.push tex
        for ob in list when ob.type == 'MESH'
            ob_data = ob.data?.remove ob
            if unload_textures
                for mat in ob.materials
                    for tex in mat.last_shader?.textures or []
                        if tex not in used_textures
                            tex.unload()
            for lod_ob in ob.lod_objects or []
                lod_ob.object.data?.remove lod_ob
                # We're assuming lod objects have same materials
                # NOTE: should we?
        return

    unload_all: ->
        @unload_objects @children

    merge_scene: (other_scene, options) ->
        for ob in other_scene.children
            if ob.name of @objects
                console.warn "Moving object #{ob.name} from #{other_scene.name}
                    which already exists in #{@name}"
                # TODO: parents are not managed but it should work as it is now
                # ideally their children should be orphaned in add_object
                # except when called from here
                @add_object ob
        return

    extend: (name, options={})->
        loader ?= require './loader'
        {
            data_dir=@context.MYOU_PARAMS.data_dir
            original_scene_name=name
            skip_if_already_exists=true
        } = options

        scene = @

        url = "#{data_dir}/scenes/#{original_scene_name}/all.json"
        return fetch(url).then (response) ->
            if not response.ok
                return Promise.reject "Scene '#{name}' could not be loaded from URL
                    '#{url}' with error '#{response.status} #{response.statusText}'"
            return response.json()
        .then (data) ->
            for d in data
                loader.load_datablock scene, d, scene.context, {
                    skip_scene:true, skip_if_already_exists, original_scene_name,
                }
            return scene

    add_object_to_group: (ob, group_name)->
        if (not group_name) or typeof(group_name) != 'string'
            throw 'Group name ' + group_name + ' is not a string.'
        else
            group = @groups[group_name] = @groups[group_name] or {}
            ob.add_to_group group_name


    # Enables features of the scene. The things that can be enabled are:
    #
    # * render: Enables rendering of visual elements (meshes, background, etc).
    # * physics: Enables physics movement. Note that some features of physics
    #            can still be used without this (e.g. ray test).
    #
    # @param items... [Array<String>] List of features to enable.
    #       Each one must be one of: 'render', 'physics', 'all'
    # @option options [boolean] fetch_textures
    #       Whether to fetch textures when they're not loaded already.
    # @option options [number] texture_size_ratio
    #       Quality of textures specified in ratio of number of pixels.
    # @option options [number] max_mesh_lod
    #       Quality of meshes specified in LoD polycount ratio.
    # @return [Promise]
    enable: (items...) ->
        {render, physics, all} =
            @_ensure_items items, ['render', 'physics', 'all']
        if render or all
            if not @active_camera?
                console.warn "Scene '#{@name}' has no active camera,
                    nothing will be rendered."
            @enabled = true
            if @background_probe? and not @background_probe.auto_refresh
                @background_probe.render()
        if physics or all
            if not @world.btworld?
                console.warn "Scene '#{@name}' has no working physics world.
                    Make sure the physics engine has loaded."
            @physics_enabled = true
        return

    disable: (items...) ->
        {render, physics, all} =
            @_ensure_items items, ['render', 'physics', 'all']
        if render or all
            @enabled = false
        if physics or all
            @physics_enabled = false
        return

    # Sets the active camera of the scene, adds it if necessary, and if there's
    # no screen it creates a screen and a viewport filling the screen.
    # @param camera [Camera] The camera object
    set_active_camera: (camera) ->
        @active_camera = camera
        if camera.scene != this
            @add_object camera, camera.name or 'Camera'
        if not @context.canvas_screen?
            screen = new CanvasScreen @context
            screen.add_viewport camera
        return

    instance_probe: ->
        if @background_probe
            return @background_probe
        if @background_probe_data?
            if not @background_probe_data.size
                console.error "Background probe of scene #{@name} has size 0"
                return null
            if @background_probe_data.compute_sh and not @background_probe_data.sh_quality
                console.error "Background probe of scene #{@name} has sh_quality 0"
                return null
            @background_probe = new Probe @, @background_probe_data
            if @enabled and not @background_probe.auto_refresh
                @background_probe.render()
        return @background_probe

    set_samples: (@bsdf_samples) ->
        for probe in @probes
            probe.set_lod_factor()
        return

    # Returns a DebugDraw instance for this scene, creating it if necessary.
    # @return [DebugDraw]
    get_debug_draw: (options) ->
        if not @_debug_draw?
            @_debug_draw = new @context.DebugDraw this, options
        return @_debug_draw

    # Returns whether it has a DebugDraw instance
    # @return [boolean]
    has_debug_draw: -> @_debug_draw?

    # Destroys the DebugDraw instance of this scene, if any
    remove_debug_draw: ->
        if @_debug_draw?
            if @_debug_draw.shape_instances.length != 0
                console.warn "There are debug shape instances in debug draw of
                            #{@name}. The debug draw instance will be deleted
                            nevertheless."
            delete @_debug_draw
            @_debug_draw = null
        return

    ### private methods ###

    # @nodoc
    _ensure_items: (items, possible) ->
        if items.length == 0
            throw Error "No items supplied. Supply one or more of:
                '#{possible.join "', '"}'"
        if Array.isArray items[0]
            throw Error "Remove the [ ] of the array, pass the elements as
                individual arguments."
        r = {}
        for item in items
            if item not in possible
                throw Error "Item '#{item}' is not allowed.
                    Must be one of: '#{possible.join "', '"}'"
            r[item] = true
        return r


# Using objects as dicts by disabling hidden object optimization
# @nodoc
dict = ->
    d = {}
    delete d.x
    d

module.exports = {Scene}
