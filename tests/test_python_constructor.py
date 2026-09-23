"""Exercise wrapper ownership with a fake CFFI library; no audio dependencies."""
import contextlib
import errno
import importlib.util
import io
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch


class FakeFFI:
    NULL = None
    errno = 0

    def def_extern(self):
        return lambda fn: fn

    def new(self, declaration, value):
        return value

    def string(self, value):
        return value


class FakeLib:
    def __init__(self, ffi, fail, error):
        self.ffi, self.fail, self.error = ffi, fail, error
        self.live = []
        self.destroyed = []

    def __getattr__(self, name):
        if name == "olaf_db_identifier_id":
            return lambda *args: 123
        if name == "olaf_python_wrapper_handle_result":
            return lambda *args: None
        if name.endswith("_new") or name == "olaf_config_default":
            def new(*args):
                if name == self.fail:
                    self.ffi.errno = self.error
                    return None
                p = types.SimpleNamespace(name=name, audioSampleRate=16000, dbFolder=b"db")
                self.live.append(p)
                return p
            return new
        if name.endswith("_destroy"):
            def destroy(p, *args):
                self.live.remove(p)
                self.destroyed.append(p)
                self.ffi.errno = 999  # Cleanup must not replace the original error.
            return destroy
        raise AttributeError(name)


class ConstructorTests(unittest.TestCase):
    def load(self, fail=None, error=errno.ENOMEM):
        ffi = FakeFFI()
        lib = FakeLib(ffi, fail, error)
        modules = {"olaf_cffi": types.SimpleNamespace(ffi=ffi, lib=lib),
                   "librosa": types.ModuleType("librosa"), "numpy": types.ModuleType("numpy")}
        path = Path(__file__).resolve().parents[1] / "python-wrapper/olaf.py"
        spec = importlib.util.spec_from_file_location("olaf_wrapper_test", path)
        module = importlib.util.module_from_spec(spec)
        with patch.dict(sys.modules, modules):
            spec.loader.exec_module(module)
        return module, lib

    def test_partial_construction(self):
        for command, calls in (("QUERY", ["olaf_config_default", "olaf_fft_new", "olaf_ep_extractor_new",
                                         "olaf_fp_extractor_new", "olaf_db_new", "olaf_fp_matcher_new"]),
                               ("STORE", ["olaf_fp_db_writer_new"])):
            for call in calls:
                for code, expected in ((errno.ENOMEM, MemoryError), (errno.EINVAL, ValueError)):
                    with self.subTest(command=command, call=call, code=code):
                        module, lib = self.load(call, code)
                        with self.assertRaises(expected):
                            module.Olaf(getattr(module.OlafCommand, command), "example.wav")
                        self.assertEqual(lib.live, [])

    def test_cleanup_is_idempotent(self):
        for command in ("QUERY", "STORE", "EXTRACT_MAGNITUDES"):
            module, lib = self.load()
            with contextlib.redirect_stdout(io.StringIO()):
                obj = module.Olaf(getattr(module.OlafCommand, command), "example.wav")
            obj._close()
            count = len(lib.destroyed)
            obj._close()
            self.assertEqual(lib.live, [])
            self.assertEqual(len(lib.destroyed), count)


if __name__ == "__main__":
    unittest.main()
