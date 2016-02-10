{mat2, mat3, mat4, vec2, vec3, vec4, quat} = require 'gl-matrix'
phy = require './physics'

# Returns [body, point, normal]
pointer_over = (pointer_event, cam, int_mask)->
    scene = cam.scene
    context = cam.scene.context
    events = context.events
    pos = cam.get_world_position()
    {width, height} = context.canvas_rect

    {x,y} = pointer_event
    x = x/width
    y = y/height

    rayto = cam.get_ray_direction(x,y)

    vec3.add(rayto, rayto, pos)
    vec3.copy(context.objects.Icosphere.position, rayto)

    return phy.ray_intersect_body_absolute scene, pos, rayto, int_mask

module.exports = {pointer_over}
