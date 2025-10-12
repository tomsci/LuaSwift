// Copyright (c) 2023 Tom Sutcliffe
// See LICENSE file for license information.

@testable import Lua
import CLua

extension LuaValue {
    public func internal_get_L() -> LuaState? {
        return L
    }
}

extension LuaHooksState {
    internal var internal_hooks: Dictionary<LuaState, LuaHook> {
        return _hooks
    }

    internal var internal_untrackedHookedStates: Set<LuaState> {
        return _untrackedHookedStates
    }

    internal var internal_trackedStatesRef: CInt {
        return _trackedStatesRef
    }
}

// These are to avoid deprecation warnings in the test code but still be able to test the deprecated fns
// extension LuaState {
// }
