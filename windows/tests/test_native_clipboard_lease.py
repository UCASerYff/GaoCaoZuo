from types import SimpleNamespace

import pytest

from gaocaozuo.clipboard_win import WindowsClipboard, CF_UNICODETEXT
from gaocaozuo.errors import AppError


def native_model(owner_changes=False):
    state = SimpleNamespace(sequence=7, owner=88, close_count=0, empty_count=0, installed={})
    native = WindowsClipboard.__new__(WindowsClipboard)
    native.create_window = lambda *args: 42
    native.destroy_window = lambda _window: True
    native.sequence = lambda: state.sequence
    native.owner = lambda: state.owner
    native.open = lambda window: window == 42
    native.free = lambda _handle: True
    native._prepare = dict

    def empty():
        state.owner = 42
        state.empty_count += 1
        state.sequence += 1
        state.installed.clear()
        return True

    def install(handles):
        state.installed.update(handles)
        state.sequence += len(handles)
        handles.clear()

    def close():
        state.close_count += 1
        if state.close_count == 1 and state.installed:
            # Windows synthesizes a standard text format when the first write closes.
            state.sequence += 1
            if owner_changes:
                state.owner = 99
                state.sequence += 1
                state.installed = {CF_UNICODETEXT: b"new owner"}

    native.empty = empty
    native._install = install
    native.close = close
    return native, state


def test_clipboard_replace_uses_finalized_windows_sequence_number():
    native, state = native_model()
    installed = native.replace({CF_UNICODETEXT: b"test"}, expected=7, fallback={})
    assert installed == native.sequence() == 10
    assert state.empty_count == 1
    assert native.replace({}, expected=installed) == 11
    assert state.installed == {}


def test_clipboard_replace_rejects_new_owner_during_finalization():
    native, state = native_model(owner_changes=True)
    with pytest.raises(AppError) as error:
        native.replace({CF_UNICODETEXT: b"test"}, expected=7, fallback={})
    assert error.value.code == "changed"
    assert state.installed == {CF_UNICODETEXT: b"new owner"}
    assert state.empty_count == 1
