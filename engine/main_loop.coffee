{evaluate_all_animations} = require './animation.coffee'
{get_last_char_phy, step_world, step_world, phy_to_ob} = require './physics.coffee'
# Logic assumes a frame won't be longer than this
# Below that point, things go slow motion
MAX_FRAME_DURATION = 167  # 6 fps

class MainLoop

    constructor: (context)->
        # All milliseconds
        @frame_duration = 16
        @last_frame_durations = [16, 16, 16, 16, 16, 16, 16, 16, 16, 16]
        @_fdi = 0
        @timeout_time = context.MYOU_PARAMS.timeout
        @reset_timeout()
        @last_time = 0
        @enabled = false
        @stopped = true
        @context = context
        @_bound_tick = @tick.bind @
        @_bound_run = @run.bind @
        @_frame_callbacks = []
        @frame_number = 0

    run: ->
        @stopped = false
        if @enabled
            return
        @req_tick = requestAnimationFrame @_bound_tick
        @enabled = true
        @last_time = performance.now()


    stop: ->
        if @req_tick?
            cancelAnimationFrame @req_tick
            @req_tick = null
        @enabled = false
        @stopped = true

    sleep: (time)->
        if @sleep_timeout_id?
            clearTimeout(@sleep_timeout_id)
            @sleep_timeout_id = null
        if @enabled
            @stop()
        @sleep_timeout_id = setTimeout(@_bound_run, time)

    add_frame_callback: (callback)->
        @_frame_callbacks.push callback

    timeout: (time)->
        if @stopped
            return
        if @timeout_id?
            clearTimeout(@timeout_id)
            @timeout_id = null
        @enabled = true
        @timeout_id = setTimeout((=>@enabled = false), time)

    reset_timeout: =>
        if @timeout_time
            @timeout(@timeout_time)

    tick: ->
        @req_tick = requestAnimationFrame @_bound_tick
        time = performance.now()
        @frame_duration = frame_duration = Math.min(time - @last_time, MAX_FRAME_DURATION)
        @last_time = time

        if not @enabled
            return
        @last_frame_durations[@_fdi] = frame_duration
        @_fdi = (@_fdi+1) % @last_frame_durations.length


        if @_frame_callbacks.length != 0
            @_frame_callbacks.shift()()

        for scene in @context.loaded_scenes

            for callback in scene.pre_draw_callbacks
                callback scene, frame_duration

            for logic_tick in scene.logic_ticks
                logic_tick frame_duration

            for p in scene.active_particle_systems
                p._eval()

            if scene.rigid_bodies.length or scene.kinematic_characters.length
                get_last_char_phy scene.kinematic_characters
                step_world scene.world, frame_duration * 0.001
                phy_to_ob scene.rigid_bodies


        evaluate_all_animations @context, frame_duration
        # for s in @context.active_sprites
        #     s.evaluate_sprite frame_duration
        @context.render_manager.draw_all()

        for scene in @context.loaded_scenes
            for f in scene.post_draw_callbacks
                f scene, frame_duration

        @context.events.reset_frame_events()
        @frame_number += 1

module.exports = {MainLoop}
