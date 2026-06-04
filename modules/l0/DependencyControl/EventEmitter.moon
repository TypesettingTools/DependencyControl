--- Minimal event registration mixin: on(event, cb) / off(event, cb) / _emit(event, ...).
-- Subclasses provide an `@Event` Enum that defines the valid event values.
-- @class EventEmitter
class EventEmitter
    new: =>
        @_listeners = {}

    --- Registers a callback for an event.
    -- @param event the event value (a member of the subclass's @Event enum)
    -- @param callback function called with the emitter instance (plus any event args)
    -- @return self (for chaining)
    on: (event, callback) =>
        valid, err = @@Event\validate event, "event"
        error err unless valid
        listeners = @_listeners[event]
        unless listeners
            listeners = {}
            @_listeners[event] = listeners
        listeners[#listeners + 1] = callback
        return @

    --- Unregisters a previously-registered callback for an event.
    -- @param event the event value
    -- @param callback the exact callback passed to on
    -- @return self (for chaining)
    off: (event, callback) =>
        listeners = @_listeners[event]
        return @ unless listeners
        for i = #listeners, 1, -1
            table.remove listeners, i if listeners[i] == callback
        return @

    -- Invokes all listeners for an event with (self, ...). Iterates a snapshot so
    -- a listener may safely on/off during dispatch.
    _emit: (event, ...) =>
        listeners = @_listeners[event]
        return unless listeners
        cb @, ... for cb in *[l for l in *listeners]
