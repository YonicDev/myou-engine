
{vec3, quat} = require 'vmath'

is_browser = not process? or process.browser
if is_browser
    # for loading ammo.js relative to the output .js
    # TODO: Make abstraction of this mechanism to load other optional libraries
    scripts = document.querySelectorAll 'script'
    current_script_path =
        scripts[scripts.length-1].src?.split('/')[...-1].join('/') or ''

Ammo = null

class World
    constructor: (@scene) ->
        # read only, set gravity with set_gravity()
        @gravity = vec3.new 0, 0, 9.8
        @physics_fps = 60
        @time_ratio = 1
        # Set to 0 to disable extrapolation
        @max_substeps = 5
        # private vars
        @btworld = @solver = @ghost_pair_callback = \
        @broadphase = @dispatcher = @configuration = null
        @tmp_Vector3 = @tmp_Vector3b = @tmp_Vector3c = @tmp_Quaternion = \
        @tmp_Transform = @tmp_Transform2 = @tmp_ClosestRayResultCallback = null
        @pointer_to_body = {}
        @auto_update_sensors = []
        @auto_update_bodies = []
        @character_bodies = []

    instance: ->
        return if @btworld?
        @configuration = new Ammo.btDefaultCollisionConfiguration
        @dispatcher = new Ammo.btCollisionDispatcher @configuration
        @broadphase = new Ammo.btDbvtBroadphase
        @ghost_pair_callback = new Ammo.btGhostPairCallback
        @broadphase.getOverlappingPairCache()
            .setInternalGhostPairCallback(@ghost_pair_callback)
        @solver = new Ammo.btSequentialImpulseConstraintSolver
        @btworld = new Ammo.btDiscreteDynamicsWorld @dispatcher, @broadphase,
            @solver, @configuration
        @tmp_Vector3 = new Ammo.btVector3 0, 0, 0
        @tmp_Vector3b = new Ammo.btVector3 0, 0, 0
        @tmp_Vector3c = new Ammo.btVector3 0, 0, 0
        @tmp_Quaternion = new Ammo.btQuaternion 0, 0, 0, 0
        @tmp_Transform = new Ammo.btTransform
        @tmp_Transform2 = new Ammo.btTransform
        @tmp_ClosestRayResultCallback = new Ammo.ClosestRayResultCallback \
            new Ammo.btVector3(0, 0, 0), new Ammo.btVector3(0, 0, 0)
        @set_gravity @gravity
        for ob in @scene.children
            ob.body.instance()
        return

    destroy: ->
        return if not @btworld?
        {destroy} = Ammo
        destroy @btworld
        destroy @solver
        destroy @ghost_pair_callback
        destroy @broadphase
        destroy @dispatcher
        destroy @configuration
        destroy @tmp_Vector3
        destroy @tmp_Vector3b
        destroy @tmp_Vector3c
        destroy @tmp_Quaternion
        destroy @tmp_Transform
        destroy @tmp_ClosestRayResultCallback

    set_gravity: (gravity) ->
        vec3.copy @gravity, gravity
        return if not @btworld?
        {x,y,z} = gravity
        @tmp_Vector3.setValue(x, y, z)
        @btworld.setGravity(@tmp_Vector3)
        for b in @character_bodies
            b.btchar.setGravity(-z)
        return

    step: (frame_duration) ->
        return if not @btworld? or not @scene.physics_enabled
        # Getting body velocity of characters (TODO is there another way?)
        for {btbody, last_position} in @character_bodies
            origin = btbody.getWorldTransform().getOrigin()
            vec3.set last_position, origin.x(), origin.y(), origin.z()
        for body in @auto_update_sensors # TODO: skip static objects?
            body.update_transform()
        @btworld.stepSimulation frame_duration * 0.001 * @time_ratio,
            @max_substeps, 1/@physics_fps
        # Copy physics back to objects
        {tmp_Transform} = this
        for {btbody, owner} in @auto_update_bodies
            if btbody.getMotionState
                transform = tmp_Transform
                btbody.getMotionState().getWorldTransform(transform)
            else
                transform = btbody.getWorldTransform()
            origin = transform.getOrigin()
            vec3.set owner.position, origin.x(), origin.y(), origin.z()
            brot = transform.getRotation()
            quat.set owner.rotation, brot.x(), brot.y(), brot.z(), brot.w()
        return

    ray_test: (ray_from, ray_to, int_mask=-1) ->
        if not @btworld?
            return {}
        {tmp_Vector3, tmp_Vector3b} = this
        callback = @tmp_ClosestRayResultCallback
        tmp_Vector3.setValue ray_from.x, ray_from.y, ray_from.z
        tmp_Vector3b.setValue ray_to.x, ray_to.y, ray_to.z
        callback.set_m_rayFromWorld(tmp_Vector3)
        callback.set_m_rayToWorld(tmp_Vector3b)
        callback.set_m_collisionFilterGroup(-1)
        callback.set_m_collisionFilterMask(int_mask)
        callback.set_m_collisionObject(0)
        callback.set_m_closestHitFraction(1)
        callback.set_m_flags(0)
        @btworld.rayTest(tmp_Vector3, tmp_Vector3b, callback)
        if callback.hasHit()
            f = callback.get_m_closestHitFraction()
            point = vec3.lerp vec3.create(), ray_from, ray_to, f
            n = callback.get_m_hitNormalWorld()
            normal = vec3.new n.x(), n.y(), n.z()
            # TODO optim: check if the pointers of members of callback
            # are always the same
            cob = callback.get_m_collisionObject()
            object = @pointer_to_body[cob.ptr]?.owner
            distance = vec3.dist(point, ray_from)
            return {object, point, normal, distance}
        return {}

class Body
    constructor: (@owner) ->
        @btbody = @btchar = @btshape = @btmesh = @btcomp = @btworld = null
        @world = null
        @type = 'NO_COLLISION' # read only, use set_type()
        @shape = 'BOX' # read only, use set_shape()
        @radius = 1 # used only if object has no bound_box
        @use_anisotropic_friction = false
        @friction_coefficients = vec3.new 1, 1, 1
        @group = 0x0001
        @mask = 0xffff
        @margin = 0
        @is_compound = false # read only, use set_shape()
        @mass = 0
        @no_sleeping = false # read only, use (dis)allow_sleeping
        @is_ghost = false # read only, use make_ghost/clear_ghost
        @linear_factor = vec3.new 1, 1, 1
        @angular_factor = vec3.new 1, 1, 1
        @form_factor = 0.4
        @friction = 0.5
        @elasticity = 0
        @half_extents = vec3.create()
        @physics_mesh = null # Mesh GameObject
        @_use_visual_mesh = false
        # for kinematic characters
        @step_height = 0.15
        @jump_force = 10
        @max_fall_speed = 55
        @slope = Math.PI / 4 # 45 degrees
        @last_position = vec3.create()

        @constraints = []

    set_shape: (shape, is_compound=@is_compound) ->
        if @btshape? and shape == @shape and !is_compound == !@is_compound
            return
        @_destroy_shape()
        @shape = shape
        @is_compound = !!is_compound
        @instance()

    set_type: (type) ->
        if @btbody? and type == @type
            return
        @type = type
        @instance()

    instance: (use_visual_mesh=false) ->
        {@world} = @owner.scene
        {@btworld} = @world
        if @btbody?
            @_destroy_body()

        if @type == 'NO_COLLISION' or not @btworld?
            return

        if @owner.parent?.type == 'ARMATURE'
            # this is likely to be part of a ragdoll that needs to be applied
            return

        he = vec3.set @half_extents, 0, 0, 0
        if @owner.bound_box?
            [a,b] = @owner.bound_box
            vec3.sub he, b, a
            vec3.scale he, he, .5
        if vec3.sqrLen(he) < 0.00001
            he = vec3.set he, @radius, @radius, @radius
        if @owner.parent?
            # TODO: Avoid multiple calls to get_world_matrix()
            scale = vec3.fromMat4Scale vec3.create(), @owner.get_world_matrix()
        else
            scale = @owner.scale
        vec3.mul he, he, scale

        {tmp_Vector3} = @world
        if not @btshape? then switch @shape
            when 'BOX'
                tmp_Vector3.setValue he.x, he.y, he.z
                @btshape = new Ammo.btBoxShape tmp_Vector3
            when 'SPHERE'
                radius = Math.max he.x, he.y, he.z
                he.x = he.y = he.z = radius
                @btshape = new Ammo.btSphereShape radius
            when 'CYLINDER'
                radius = Math.max he.x, he.y
                he.x = he.y = radius
                tmp_Vector3.setValue radius, radius, he.z
                @btshape = new Ammo.btCylinderShapeZ tmp_Vector3
            when 'CONE'
                radius = Math.max he.x, he.y
                he.x = he.y = radius
                @btshape = new Ammo.btConeShapeZ radius, he.z*2
            when 'CAPSULE'
                radius = Math.max he.x, he.y
                he.x = he.y = radius
                @btshape = new Ammo.btCapsuleShapeZ radius, (he.z-radius)*2
            when 'CONVEX_HULL', 'TRIANGLE_MESH'
                # Choose which mesh to use as physics
                ob = @get_physics_mesh use_visual_mesh
                use_visual_mesh = ob == @owner
                data = ob.data
                if not data?
                    # TODO: Do this better?
                    ob.pending_bodies.push this
                    return

                @_use_visual_mesh = use_visual_mesh

                # Get "global" scale
                # @half_extents is used as scale for debug objects, so we
                # assign it here as regular scale instead of half-extents
                if @owner.parent
                    # TODO: Avoid multiple calls to get_world_matrix()
                    scale = vec3.fromMat4Scale he, @owner.get_world_matrix()
                else
                    scale = vec3.copy he, @owner.scale
                if @shape == 'CONVEX_HULL'
                    @btshape = @_get_convex_hull_shape data
                else
                    @btshape = @_get_triangle_mesh_shape data
                # TODO: cache different sizes! investigate if
                # several shapes can share same mesh with different scales
                tmp_Vector3.setValue scale.x, scale.y, scale.z
                @btshape.setLocalScaling tmp_Vector3
            else
                throw Error "Unknown shape:" + @shape

        @btshape.setMargin @margin

        # TODO: changing compunds live don't work well
        # unless they're reinstanced in order
        if @is_compound
            pos = vec3.create()
            rot = quat.create()
            {tmp_Quaternion, tmp_Transform} = @world
            {parent} = @owner
            if parent?.body.is_compound
                while parent.parent?.body.is_compound
                    parent = parent.parent

                @owner.get_world_position_rotation_into(pos, rot)
                # TODO: avoid calling this all the time
                # TODO: this probably fails with matrix_parent_inverse
                {position: parent_pos, rotation: parent_rot} = \
                    parent.get_world_position_rotation()
                vec3.sub pos, pos, parent_pos
                inv = quat.invert quat.create(), parent_rot
                vec3.transformQuat pos, pos, inv
                quat.mul rot, inv, rot
                comp = parent.body.btcomp
            else
                @btcomp = comp = new Ammo.btCompoundShape
                comp.children = []
            tmp_Vector3.setValue(pos.x, pos.y, pos.z)
            tmp_Quaternion.setValue(rot.x, rot.y, rot.z, rot.w)
            tmp_Transform.setOrigin(tmp_Vector3)
            tmp_Transform.setRotation(tmp_Quaternion)
            comp.addChildShape(tmp_Transform, @btshape)
            comp.children.push @btshape
            if not @btcomp?
                return
            actual_shape = @btcomp
        else
            actual_shape = @btshape

        {position: pos, rotation: rot} = @owner.get_world_position_rotation()
        # TODO: SOFT_BODY, OCCLUDE, NAVMESH
        switch @type
            when 'RIGID_BODY'
                @owner.rotation_order = 'Q'
                quat.copy @owner.rotation, rot
                @btbody = @_rigid_body @mass, actual_shape, pos, rot, @friction,
                    @elasticity, @form_factor
                @set_linear_factor @linear_factor
                @set_angular_factor @angular_factor
                @world.auto_update_bodies.push @
            when 'DYNAMIC'
                @owner.rotation_order = 'Q'
                quat.copy @owner.rotation, rot
                @btbody = @_rigid_body @mass, actual_shape, pos, rot, @friction,
                    @elasticity, @form_factor
                @set_linear_factor @linear_factor
                @set_angular_factor {x: 0, y:0, z:0}
                @world.auto_update_bodies.push @
            when 'STATIC'
                # TODO: use ghost?
                @btbody = @_rigid_body 0, actual_shape, pos, rot, @friction,
                    @elasticity, 0
            when 'SENSOR'
                @btbody = @_sensor_body actual_shape, pos, rot
                @world.auto_update_sensors.push @
            when 'CHARACTER'
                @owner.rotation_order = 'Q'
                quat.copy @owner.rotation, rot
                @btbody = @_character_body(
                    actual_shape
                    pos
                    rot
                    @step_height
                    2 # Z axis
                    -@world.gravity.z
                    @jump_force
                    @max_fall_speed
                    @slope
                )
                @world.auto_update_bodies.push @
                @world.character_bodies.push @
            else
                throw Error "Type not handled:" + @physics_type

        if @btchar?
            @btworld.addCollisionObject(@btbody, @group, @mask)
            @btworld.addAction(@btchar)
        else
            @btworld.addRigidBody(@btbody, @group, @mask)
        if @no_sleeping or @type == 'SENSOR'
            @disallow_sleeping()
        if @is_ghost or @type == 'SENSOR'
            @make_ghost()
        @update_transform()
        @world.pointer_to_body[@btbody.ptr] = this

    get_physics_mesh: (use_visual_mesh=@_use_visual_mesh) ->
        if @type == 'NO_COLLISION' or
                not /CONVEX_HULL|TRIANGLE_MESH/.test(@shape)
            return null
        if @physics_mesh and not use_visual_mesh
            return @physics_mesh
        return @owner

    destroy: ->
        @_destroy_shape()
        @_destroy_body()

    set_linear_factor: (@linear_factor) ->
        {x,y,z} = @linear_factor
        @world.tmp_Vector3.setValue x,y,z
        @btbody.setLinearFactor(@world.tmp_Vector3)

    set_angular_factor: (@angular_factor) ->
        {x,y,z} = @angular_factor
        @world.tmp_Vector3.setValue x,y,z
        @btbody.setAngularFactor(@world.tmp_Vector3)

    set_deactivation_time: (time) ->
        @btbody.setDeactivationTime(time)

    activate: ->
        @btbody.activate()

    deactivate: ->
        @btbody.setActivationState(2) # ISLAND_SLEEPING

    allow_sleeping: ->
        @no_sleeping = false
        @btbody?.setActivationState(1) # ACTIVE_TAG

    disallow_sleeping: ->
        @no_sleeping = true
        @btbody?.setActivationState(4) # DISABLE_DEACTIVATION

    make_ghost: ->
        @is_ghost = true
        # CF_NO_CONTACT_RESPONSE
        @btbody?.setCollisionFlags(@btbody.getCollisionFlags() | 4)

    clear_ghost: ->
        @is_ghost = false
        # ~CF_NO_CONTACT_RESPONSE
        @btbody?.setCollisionFlags(@btbody.getCollisionFlags() & -5)

    update_transform: ->
        return if not @btbody?
        ob = @owner
        {tmp_Vector3, tmp_Quaternion, tmp_Transform} = @world
        if ob.parent or ob.rotation_order != 'Q'
            {position, rotation} = ob.get_world_position_rotation()
        else
            {position, rotation} = ob
        tmp_Vector3.setValue(position.x, position.y, position.z)
        tmp_Quaternion.setValue(rotation.x, rotation.y, rotation.z, rotation.w)
        tmp_Transform.setOrigin(tmp_Vector3)
        tmp_Transform.setRotation(tmp_Quaternion)
        @btbody.setWorldTransform(tmp_Transform)

    update_rotation: ->
        return if not @btbody?
        ob = @owner
        {tmp_Vector3, tmp_Quaternion, tmp_Transform} = @world
        if @btbody.getMotionState
            transform = tmp_Transform
            @btbody.getMotionState().getWorldTransform(transform)
        else
            transform = @btbody.getWorldTransform()
        if ob.parent or ob.rotation_order != 'Q'
            {position, rotation} = ob.get_world_position_rotation()
        else
            {position, rotation} = ob
        tmp_Quaternion.setValue(rotation.x, rotation.y, rotation.z, rotation.w)
        transform.setRotation(tmp_Quaternion)
        @btbody.setWorldTransform(tmp_Transform)

    update_scale: ->
        if @btshape.setLocalScaling?
            {tmp_Vector3} = @world
            if @owner.parent
                # TODO: Avoid multiple calls to get_world_matrix()
                scale = vec3.fromMat4Scale @half_extents, @owner.get_world_matrix()
            else
                scale = vec3.copy @half_extents, @owner.scale
            tmp_Vector3.setValue scale.x, scale.y, scale.z
            @btshape.setLocalScaling tmp_Vector3
        else
            @_destroy_shape()
            @instance()
        return this

    get_linear_velocity: (local=false)->
        v = @btbody.getLinearVelocity()
        new_v = vec3.new v.x(), v.y(), v.z()
        if local
            ir = quat.invert(quat.create(), @owner.get_world_rotation())
            vec3.transformQuat(new_v, new_v, ir)
        return new_v

    get_angular_velocity: (local=false)->
        v = @btbody.getAngularVelocity()
        new_v = vec3.new v.x(), v.y(), v.z()
        if local
            ir = @btbody.owner.get_world_rotation()
            quat.invert(ir, ir)
            new_v = vec3.transformQuat(new_v, new_v, ir)
        return new_v

    set_linear_velocity: (v)->
        {tmp_Vector3} = @world
        tmp_Vector3.setValue(v.x, v.y, v.z)
        @btbody.setLinearVelocity(tmp_Vector3)

    apply_force: (force, rel_pos)->
        {tmp_Vector3, tmp_Vector3b} = @world
        tmp_Vector3.setValue(force.x, force.y, force.z)
        tmp_Vector3b.setValue(rel_pos.x, rel_pos.y, rel_pos.z)
        @btbody.applyForce(tmp_Vector3, tmp_Vector3b)

    apply_central_force: (force)->
        {tmp_Vector3} = @world
        tmp_Vector3.setValue(force.x, force.y, force.z)
        @btbody.applyCentralForce(tmp_Vector3)

    apply_central_impulse: (force)->
        {tmp_Vector3} = @world
        tmp_Vector3.setValue(force.x, force.y, force.z)
        @btbody.applyCentralImpulse(tmp_Vector3)

    set_friction: (friction) ->
        if Math.abs(@friction-friction) < 0.01
            return
        @friction = friction
        @instance()

    # Character

    # TODO: REVISE API
    set_character_velocity: (v)->
        if not @btchar?
            throw Error "Object '#{@owner.name}' is not a character body"
        inv_fps = 1/@world.physics_fps
        {tmp_Vector3} = @world
        tmp_Vector3.setValue(v.x * inv_fps, v.y * inv_fps, v.z * inv_fps)
        @btchar.setWalkDirection(tmp_Vector3)

    set_character_gravity: (v)->
        {tmp_Vector3} = @world
        @btchar.setGravity(-v.z)

    set_jump_force: (f)->
        if not @btchar?
            throw Error "Object '#{@owner.name}' is not a character body"
        @jump_force = f
        @btchar.setJumpSpeed(f)

    jump: ->
        if not @btchar?
            throw Error "Object '#{@owner.name}' is not a character body"
        @btchar.jump()

    on_ground: ->
        if not @btchar?
            throw Error "Object '#{@owner.name}' is not a character body"
        return @btchar.onGround()

    set_max_fall_speed: (f)->
        if not @btchar?
            throw Error "Object '#{@owner.name}' is not a character body"
        @max_fall_speed = f
        @btchar.setFallSpeed(f)

    set_angular_velocity: (v)->
        {tmp_Vector3} = @world
        tmp_Vector3.setValue(v.x, v.y, v.z)
        @btbody.setAngularVelocity(tmp_Vector3)

    colliding_points: (margin=0, use_ghost=true)->
        ret = []
        {btbody, btworld} = this
        if not btbody?
            return ret
        {pointer_to_body} = @world
        p = btbody.ptr
        if btbody.getOverlappingPairCache? and use_ghost
            # TODO: Should we move this code to C++?
            manifoldArray = new Ammo.btManifoldArray
            pairArray = btbody.getOverlappingPairCache()
                .getOverlappingPairArray()
            for i in [0...pairArray.size()]
                manifoldArray.clear()
                pair = pairArray.at(i)
                collisionPair = btworld.getPairCache().findPair(
                    pair.get_m_pProxy0(), pair.get_m_pProxy1())
                continue if collisionPair.ptr == 0
                algo = collisionPair.get_m_algorithm()
                if algo.ptr != 0
                    algo.getAllContactManifolds manifoldArray

                for j in [0...manifoldArray.size()]
                    manifold = manifoldArray.at(j)
                    b0 = manifold.getBody0().ptr
                    b1 = manifold.getBody1().ptr
                    isFirstBody = b0 == p
                    for j in [0...manifold.getNumContacts()]
                        point = manifold.getContactPoint(j)
                        if point.getDistance() < margin
                            v = point.getPositionWorldOnA()
                            a = vec3.new v.x(), v.y(), v.z()
                            v = point.getPositionWorldOnB()
                            b = vec3.new v.x(), v.y(), v.z()
                            n = point.get_m_normalWorldOnB()
                            if isFirstBody
                                normal = vec3.new -n.x(), -n.y(), -n.z()
                                other = pointer_to_body[b1]
                                ret.push {point_on_body: a, \
                                    point_on_other: b, normal, other}
                            else
                                normal = vec3.new n.x(), n.y(), n.z()
                                other = pointer_to_body[b0]
                                ret.push {point_on_body: b, \
                                    point_on_other: a, normal, other}

            Ammo.destroy manifoldArray
        else
            # This is faster than the above when there's less than
            # ~30 rigid bodies (downside is that it gets duplicates)
            # Should we choose it automatically?
            # TODO: Should we add btPairCachingGhostObject to every rigid body
            # that needs collision checking?
            dispatcher = btworld.getDispatcher()
            for i in [0...dispatcher.getNumManifolds()]
                m = dispatcher.getManifoldByIndexInternal(i)
                num_contacts = m.getNumContacts()
                if num_contacts!=0
                    b0 = m.getBody0().ptr
                    b1 = m.getBody1().ptr
                    if b0 == p or b1 == p
                        for j in [0...num_contacts]
                            point = m.getContactPoint(j)
                            if point.getDistance() < margin
                                v = point.getPositionWorldOnA()
                                a = vec3.new v.x(), v.y(), v.z()
                                v = point.getPositionWorldOnB()
                                b = vec3.new v.x(), v.y(), v.z()
                                n = point.get_m_normalWorldOnB()
                                if b1 == p
                                    normal = vec3.new n.x(), n.y(), n.z()
                                    other = pointer_to_body[b0]
                                    ret.push {point_on_body: b, \
                                        point_on_other: a, normal, other}
                                else
                                    normal = vec3.new -n.x(), -n.y(), -n.z()
                                    other = pointer_to_body[b1]
                                    ret.push {point_on_body: a, \
                                        point_on_other: b, normal, other}
        return ret

    add_point_constraint: (other, point, linked_collision=true) ->
        {tmp_Vector3, tmp_Vector3b, btworld} = @world
        point_in_a = vec3.clone point
        {position, rotation} = @owner.get_world_position_rotation()
        vec3.sub point_in_a, point_in_a, position
        quat.invert rotation, rotation
        vec3.transformQuat point_in_a, point_in_a, rotation
        tmp_Vector3.setValue point_in_a.x, point_in_a.y, point_in_a.z
        if other?
            point_in_b = vec3.clone point
            {position, rotation} = other.owner.get_world_position_rotation()
            vec3.sub point_in_b, point_in_b, position
            quat.invert rotation, rotation
            vec3.transformQuat point_in_b, point_in_b, rotation
            tmp_Vector3b.setValue point_in_b.x, point_in_b.y, point_in_b.z
            c = new Ammo.btPoint2PointConstraint @btbody, other.btbody,
                tmp_Vector3, tmp_Vector3b
        else
            c = new Ammo.btPoint2PointConstraint @btbody, tmp_Vector3
        btworld.addConstraint c, linked_collision
        @constraints.push c
        return new Constraint this, btworld, c

    add_conetwist_constraint: (other, point, rot, limit_twist, limit_y, limit_z,
            linked_collision=true) ->
        {tmp_Vector3, tmp_Transform, tmp_Transform2, tmp_Quaternion} = @world
        point_in_a = vec3.clone point
        {position, rotation} = @owner.get_world_position_rotation()
        vec3.sub point_in_a, point_in_a, position
        quat.invert rotation, rotation
        vec3.transformQuat point_in_a, point_in_a, rotation
        quat.mul rotation, rotation, rot
        tmp_Vector3.setValue point_in_a.x, point_in_a.y, point_in_a.z
        tmp_Quaternion.setValue rotation.x, rotation.y, rotation.z, rotation.w
        tmp_Transform.setOrigin tmp_Vector3
        tmp_Transform.setRotation tmp_Quaternion
        if other?
            point_in_b = vec3.clone point
            {position, rotation} = other.owner.get_world_position_rotation()
            vec3.sub point_in_b, point_in_b, position
            quat.invert rotation, rotation
            vec3.transformQuat point_in_b, point_in_b, rotation
            quat.mul rotation, rotation, rot
            tmp_Vector3.setValue point_in_b.x, point_in_b.y, point_in_b.z
            tmp_Quaternion.setValue rotation.x, rotation.y, rotation.z, rotation.w
            tmp_Transform2.setOrigin tmp_Vector3
            tmp_Transform2.setRotation tmp_Quaternion
            c = new Ammo.btConeTwistConstraint @btbody, other.btbody,
                tmp_Transform, tmp_Transform2
        else
            c = new Ammo.btConeTwistConstraint @btbody, tmp_Transform
        c.setLimit limit_z, limit_y, limit_twist, 1, .3, 1
        @world.btworld.addConstraint c, linked_collision
        @constraints.push c
        return new Constraint this, @world.btworld, c

    _clone_to: (owner) ->
        owner.body = n = new Body owner
        for k,v of this when v? and not v.x? and not v.ptr?
            n[k] = this[k]
        n.owner = owner
        n.friction_coefficients = vec3.clone @friction_coefficients
        n.linear_factor = vec3.clone @linear_factor
        n.angular_factor = vec3.clone @angular_factor
        n.half_extents = vec3.clone @half_extents
        n.last_position = vec3.clone @last_position
        return n

    _get_convex_hull_shape: (mesh_data) ->
        if mesh_data.phy_convex_hull?
            # TODO: check scale!!
            mesh_data.phy_convex_hull.users.push this
            return mesh_data.phy_convex_hull
        vertices = mesh_data.varray
        vstride = mesh_data.stride/4
        vlen = vertices.length/vstride

        # This should be faster but it doesn't work

        #verts = _malloc(vlen*vstride*4)
        #HEAPU32.set(vertices, verts>>2)
        #shape = new Ammo.btConvexHullShape(verts, vlen, vstride*4)
        #_free(verts)
        {tmp_Vector3} = @world
        shape = new Ammo.btConvexHullShape
        i = 0
        last = vlen-1
        for i in [0...vlen]
            j = i*vstride
            tmp_Vector3.setValue vertices[j], vertices[j+1], vertices[j+2]
            shape.addPoint tmp_Vector3, i==last
        mesh_data.phy_convex_hull = shape
        shape.users = [this]
        return shape

    _get_triangle_mesh_shape: (mesh_data) ->
        if mesh_data.phy_mesh?
            # TODO: check scale!!
            mesh_data.phy_mesh.users.push this
            return mesh_data.phy_mesh
        vertices = mesh_data.varray
        # TODO: use all submeshes
        indices = mesh_data.iarray.subarray(0, mesh_data.offsets[3])
        vstride = mesh_data.stride/4
        vlen = vertices.length/vstride
        if not Ammo._malloc
            inds = new Uint32Array(indices)
            verts = new Float32Array(vlen*3)
            offset = 0
            for v in [0...vlen]
                verts.set vertices.subarray(v*vstride,v*vstride+3), offset
                offset += 3
            @btmesh = new Ammo.btTriangleIndexVertexArray \
                indices.length/3, inds.buffer, 3*4, vlen, verts.buffer, 3*4
            @btmesh.things = [inds, verts] # avoid deleting those
            # crashes because wrapbtBvhTriangleMeshShape::calculateLocalInertia
            # is being called for some reason

            ## another failed attempt below
            # mesh = new Ammo.btTriangleMesh(true, true)
            # for i in [0...indices.length] by 3
            #     v = vertices.subarray(indices[i]*vstride,
            #                           indices[i]*vstride + 3)
            #     tmp_Vector3.setValue v[0], v[1], v[2]
            #     v = vertices.subarray(indices[i+1]*vstride,
            #                           indices[i+1]*vstride + 3)
            #     tmp_Vector3b.setValue v[0], v[1], v[2]
            #     v = vertices.subarray(indices[i+2]*vstride,
            #                           indices[i+2]*vstride + 3)
            #     tmp_Vector3c.setValue v[0], v[1], v[2]
            #     mesh.addTriangle tmp_Vector3, tmp_Vector3b, tmp_Vector3c
        else
            inds = Ammo._malloc indices.length*4
            Ammo.HEAPU32.set indices, inds>>2
            verts = Ammo._malloc vlen*3*4
            offset = verts>>2
            HEAPF32 = Ammo.HEAPF32
            for v in [0...vlen]
                HEAPF32.set vertices.subarray(v*vstride,v*vstride+3), offset
                offset += 3
            @btmesh = new Ammo.btTriangleIndexVertexArray \
                indices.length/3, inds, 3*4, vlen, verts, 3*4
        shape =  new Ammo.btBvhTriangleMeshShape @btmesh, true, true
        mesh_data.phy_mesh = shape
        shape.users = [this]
        shape.calculateLocalInertia = -> # TODO: is this still necessary?
        return shape

    _destroy_shape: ->
        if @btcomp?
            Ammo.destroy @btcomp
            for btshape in @btcomp.children
                Ammo.destroy btshape
        else if @btshape?
            {users} = @btshape
            if users? # only happens with convex hull/triangle mesh
                users.splice _,1 if (_ = users.indexOf this)!=-1
                if users.length == 0
                    Ammo.destroy @btshape
                    Ammo.destroy @btmesh if @btmesh?
                    if @type == 'CONVEX_HULL'
                        @owner.data.phy_convex_hull = null
                    else
                        @owner.data.phy_mesh = null
            else
                Ammo.destroy @btshape
        return

    _rigid_body: (mass, shape, position, rotation,
        friction, elasticity, form_factor) ->
        {tmp_Vector3, tmp_Quaternion} = @world
        localInertia =  new Ammo.btVector3 0, 0, 0
        if mass
            shape.calculateLocalInertia mass, localInertia
        startTransform = new Ammo.btTransform
        tmp_Vector3.setValue position.x, position.y, position.z
        startTransform.setOrigin tmp_Vector3
        tmp_Quaternion.setValue rotation.x, rotation.y, rotation.z, rotation.w
        startTransform.setRotation tmp_Quaternion
        myMotionState =  new Ammo.btDefaultMotionState startTransform
        rbInfo = new Ammo.btRigidBodyConstructionInfo \
            mass, myMotionState, shape, localInertia
        rbInfo.set_m_friction friction
        rbInfo.set_m_restitution elasticity
        body =  new Ammo.btRigidBody rbInfo
        body.pointers = [rbInfo, myMotionState, startTransform, localInertia]
        return body

    _character_body: (shape, position, rotation, step_height, axis, gravity,
        jump_speed, fall_speed, max_slope)->
        {tmp_Vector3, tmp_Quaternion} = @world
        body = new Ammo.btPairCachingGhostObject
        body.setCollisionFlags 16 # CF_CHARACTER_OBJECT
        body.setCollisionShape shape
        char = @btchar = new Ammo.btKinematicCharacterController \
            body, shape, step_height, axis
        char.setGravity gravity
        char.setJumpSpeed jump_speed
        char.setFallSpeed fall_speed
        char.setMaxSlope max_slope
        startTransform = new Ammo.btTransform
        tmp_Vector3.setValue position.x, position.y, position.z
        startTransform.setOrigin tmp_Vector3
        tmp_Quaternion.setValue rotation.x, rotation.y, rotation.z, rotation.w
        startTransform.setRotation tmp_Quaternion
        body.setWorldTransform startTransform
        body.pointers = [startTransform]
        return body

    _sensor_body: (shape, position, rotation, is_ghost) ->
        {tmp_Vector3, tmp_Quaternion} = @world
        body = new Ammo.btPairCachingGhostObject
        body.setCollisionShape shape
        startTransform = new Ammo.btTransform
        tmp_Vector3.setValue position.x, position.y, position.z
        startTransform.setOrigin tmp_Vector3
        tmp_Quaternion.setValue rotation.x, rotation.y, rotation.z, rotation.w
        startTransform.setRotation tmp_Quaternion
        body.setWorldTransform startTransform
        body.pointers = [startTransform]
        return body

    _destroy_body: ->
        if @btbody?
            if @btchar?
                @btworld.removeAction(@btchar)
                @btworld.removeCollisionObject(@btbody)
                if (index = @world.character_bodies.indexOf @) != -1
                    @world.character_bodies.splice index,1
                Ammo.destroy @btchar
            else
                @btworld.removeRigidBody(@btbody)
            delete @world.pointer_to_body[@btbody.ptr]
            Ammo.destroy @btbody
            for p in @btbody.pointers
                Ammo.destroy p
            if (index = @world.auto_update_bodies.indexOf @) != -1
                @world.auto_update_bodies.splice index,1
            if (index = @world.auto_update_sensors.indexOf @) != -1
                @world.auto_update_sensors.splice index,1
            @btbody = @btchar = null

class Constraint
    constructor: (@body, @btworld, @btconstraint) ->

    destroy: ->
        if @btconstraint?
            @btworld.removeConstraint @btconstraint
            Ammo.destroy @btconstraint
            @btconstraint = null
            if (index = @body.constraints.indexOf @) != -1
                @body.constraints.splice index,1


load_physics_engine = ->
    # Add promise if it doesn't exist yet (to be used by any engine instance)
    if not window.global_ammo_promise
        if window.Ammo?
            window.global_ammo_promise = Promise.resolve()
        else
            window.global_ammo_promise = new Promise (resolve, reject) ->
                check_ammo_is_loaded = ->
                    if not window.Ammo?
                        if window.Module?.allocate
                            reject("There was an error initializing physics")
                        else
                            setTimeout(check_ammo_is_loaded, 150)
                    else
                        window.Ammo({
                            locateFile: (f) -> physics_engine_url + f
                        }).then (ammo) ->
                            Ammo = ammo
                            resolve()
                setTimeout(check_ammo_is_loaded, 150)

            script = document.createElement 'script'
            script.type = 'text/javascript'
            script.async = true

            if is_browser
                physics_engine_url = current_script_path + "/libs/"
            else
                dirname =  __dirname.replace(/\\/g, '/')   #/)
                physics_engine_url = 'file://' + dirname + "/libs/"
            if window.WebAssembly?
                # window.Ammo = window.Ammo ? {}
                # window.Ammo.locateFile = (f) -> physics_engine_url + f
                script.src = physics_engine_url + "ammo.wasm.js"
            else
                script.src = physics_engine_url + "ammo.asm.js"

            document.body.appendChild script

    return window.global_ammo_promise

module.exports = {World, Body, load_physics_engine}
