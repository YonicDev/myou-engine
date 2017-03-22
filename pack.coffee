require './engine/init.coffee'
{Myou, create_canvas, create_full_window_canvas} = require './engine/myou.coffee'
# Modules
physics = require './engine/physics.coffee'
particles = require './engine/particles.coffee'
sensors = require './engine/sensors.coffee'
actuators = require './engine/actuators.coffee'
glm = {mat2, mat3, mat4, vec2, vec3, vec4, quat} = require './engine/glmatrix_extra.coffee'
# Main classes (not to be used directly when loading scene files)
{Action, Animation, LoopedAnimation, FiniteAnimation} = require './engine/animation.coffee'
{Group} = require './engine/group.coffee'
{Viewport} = require './engine/viewport.coffee'
{Camera} = require './engine/camera.coffee'
{Lamp} = require './engine/lamp.coffee'
{Mesh} = require './engine/mesh.coffee'
{Scene} = require './engine/scene.coffee'
{Curve} = require './engine/curve.coffee'
{GameObject} = require './engine/gameobject.coffee'
{Armature} = require './engine/armature.coffee'
{Texture} = require './engine/texture.coffee'
{Material} = require './engine/material.coffee'

{GLRay} = require './engine/glray.coffee'
{LogicBlock} = require './engine/logic_block.coffee'
{load_scene} = require './engine/loader.coffee'
{fetch_objects} = require './engine/fetch_assets.coffee'
{Framebuffer} = require './engine/framebuffer.coffee'
{Compositor, compositor_shaders} = require './engine/compositor.coffee'
geometry_utils =
    r2: require './engine/geometry_utils/r2.coffee'
    r3: require './engine/geometry_utils/r3.coffee'

module.exports = {
    #myou engine
    Myou, create_canvas, create_full_window_canvas, load_scene, fetch_objects,
    Framebuffer, Compositor, compositor_shaders,
    #Game logic
    LogicBlock, sensors, actuators, glm,
    #Extras
    physics, particles, GLRay, geometry_utils,
    #Animation
    Action, Animation, LoopedAnimation, FiniteAnimation,
    #Scene data classes
    Group, Viewport, Camera, Lamp, Mesh, Scene,
    Curve, GameObject, Armature, Texture, Material,
}
