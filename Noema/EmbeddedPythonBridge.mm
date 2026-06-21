#import "EmbeddedPythonBridge.h"

#import <Python/Python.h>

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

bool gIsInitialized = false;
PyThreadState *gMainThreadState = nullptr;

char *duplicateCString(const char *value) {
    if (value == nullptr) {
        return nullptr;
    }

    size_t length = std::strlen(value);
    char *copy = static_cast<char *>(std::malloc(length + 1));
    if (copy == nullptr) {
        return nullptr;
    }

    std::memcpy(copy, value, length);
    copy[length] = '\0';
    return copy;
}

char *duplicateString(const std::string &value) {
    return duplicateCString(value.c_str());
}

std::string pythonErrorString() {
    PyObject *type = nullptr;
    PyObject *value = nullptr;
    PyObject *traceback = nullptr;
    PyErr_Fetch(&type, &value, &traceback);
    PyErr_NormalizeException(&type, &value, &traceback);

    std::string message = "Embedded Python execution failed.";

    PyObject *tracebackModule = PyImport_ImportModule("traceback");
    if (tracebackModule != nullptr) {
        PyObject *formatter = PyObject_GetAttrString(tracebackModule, "format_exception");
        if (formatter != nullptr) {
            PyObject *formatted = PyObject_CallFunctionObjArgs(
                formatter,
                type != nullptr ? type : Py_None,
                value != nullptr ? value : Py_None,
                traceback != nullptr ? traceback : Py_None,
                nullptr
            );
            if (formatted != nullptr) {
                PyObject *separator = PyUnicode_FromString("");
                if (separator != nullptr) {
                    PyObject *joined = PyUnicode_Join(separator, formatted);
                    if (joined != nullptr) {
                        const char *utf8 = PyUnicode_AsUTF8(joined);
                        if (utf8 != nullptr) {
                            message = utf8;
                        }
                        Py_DECREF(joined);
                    }
                    Py_DECREF(separator);
                }
                Py_DECREF(formatted);
            }
            Py_DECREF(formatter);
        }
        Py_DECREF(tracebackModule);
    }

    if (message == "Embedded Python execution failed." && value != nullptr) {
        PyObject *valueString = PyObject_Str(value);
        if (valueString != nullptr) {
            const char *utf8 = PyUnicode_AsUTF8(valueString);
            if (utf8 != nullptr && std::strlen(utf8) > 0) {
                message = utf8;
            }
            Py_DECREF(valueString);
        }
    }

    Py_XDECREF(type);
    Py_XDECREF(value);
    Py_XDECREF(traceback);
    return message;
}

PyObject *setGlobalString(PyObject *globals, const char *name, const char *value) {
    PyObject *stringValue = PyUnicode_FromString(value != nullptr ? value : "");
    if (stringValue == nullptr) {
        return nullptr;
    }
    if (PyDict_SetItemString(globals, name, stringValue) != 0) {
        Py_DECREF(stringValue);
        return nullptr;
    }
    return stringValue;
}

const char *kExecutionWrapper = R"PY(
import json
import io
import os
import sys
import time
import ctypes
import threading
import tempfile
import traceback
import contextlib
import base64

_noema_user_code = __noema_user_code
_noema_sandbox_preamble = __noema_sandbox_preamble
_noema_timeout_seconds = __noema_timeout_seconds
_noema_temp_directory = __noema_temp_directory

os.environ['TMPDIR'] = _noema_temp_directory
os.environ['TMP'] = _noema_temp_directory
os.environ['TEMP'] = _noema_temp_directory
os.environ['NOEMA_PYTHON_ALLOWED_ROOT'] = _noema_temp_directory
tempfile.tempdir = _noema_temp_directory
os.chdir(_noema_temp_directory)

stdout_buffer = io.StringIO()
stderr_buffer = io.StringIO()
error_message = None
timed_out = False
exit_code = 0
_restore_sandbox = None

user_globals = {
    '__name__': '__main__',
    '__file__': os.path.join(_noema_temp_directory, 'script.py'),
    '__package__': None,
    '__builtins__': __builtins__,
    '__noema_allowed_root': _noema_temp_directory,
}

result_box = {}
cancel_box = {'cancelled': False}

def _trace(frame, event, arg):
    if cancel_box['cancelled']:
        raise TimeoutError(f'Execution timed out after {int(_noema_timeout_seconds)} seconds')
    return _trace

def _run_user_code():
    try:
        exec(_noema_sandbox_preamble, user_globals, user_globals)
        _restore = user_globals.get('_noema_restore_sandbox')
        if callable(_restore):
            result_box['restore'] = _restore
        sys.settrace(_trace)
        exec(compile(_noema_user_code, user_globals['__file__'], 'exec'), user_globals, user_globals)
        result_box['error'] = None
    except BaseException as exc:
        result_box['error'] = ''.join(traceback.format_exception(type(exc), exc, exc.__traceback__))
    finally:
        sys.settrace(None)

worker = threading.Thread(target=_run_user_code, daemon=True)

start_time = time.perf_counter()
with contextlib.redirect_stdout(stdout_buffer), contextlib.redirect_stderr(stderr_buffer):
    worker.start()
    worker.join(_noema_timeout_seconds)

    if worker.is_alive():
        timed_out = True
        cancel_box['cancelled'] = True
        ctypes.pythonapi.PyThreadState_SetAsyncExc(
            ctypes.c_ulong(worker.ident),
            ctypes.py_object(TimeoutError)
        )
        worker.join(0.25)
        if result_box.get('error') is None:
            result_box['error'] = f'Execution timed out after {int(_noema_timeout_seconds)} seconds'
        exit_code = -1

execution_time_ms = int((time.perf_counter() - start_time) * 1000)
error_message = result_box.get('error')
_restore_sandbox = result_box.get('restore')
if callable(_restore_sandbox):
    try:
        _restore_sandbox()
    except Exception:
        pass

if error_message:
    error_message = error_message.strip()
    if timed_out and 'Execution timed out' not in error_message:
        error_message = error_message + f'\nExecution timed out after {int(_noema_timeout_seconds)} seconds'
    if exit_code == 0 and not timed_out:
        exit_code = 1

def _noema_artifact_kind(path):
    ext = os.path.splitext(path)[1].lower().lstrip('.')
    if ext == 'png':
        return 'image', 'image/png'
    if ext in ('jpg', 'jpeg'):
        return 'image', 'image/jpeg'
    if ext == 'gif':
        return 'image', 'image/gif'
    if ext == 'webp':
        return 'image', 'image/webp'
    if ext == 'bmp':
        return 'image', 'image/bmp'
    if ext in ('tif', 'tiff'):
        return 'image', 'image/tiff'
    if ext == 'svg':
        return 'text', 'image/svg+xml'
    if ext == 'csv':
        return 'table', 'text/csv'
    if ext == 'tsv':
        return 'table', 'text/tab-separated-values'
    if ext == 'json':
        return 'json', 'application/json'
    if ext == 'jsonl':
        return 'text', 'application/x-ndjson'
    if ext in ('txt', 'md', 'markdown', 'log', 'out', 'err', 'py'):
        return 'text', 'text/plain'
    return 'file', None

def _noema_collect_artifacts():
    artifacts = []
    max_artifacts = 12
    max_preview_bytes = 32768
    max_embedded_bytes = 700000
    max_total_embedded_bytes = 1400000
    embedded_bytes = 0

    for root, dirs, files in os.walk(_noema_temp_directory):
        dirs[:] = [d for d in dirs if not d.startswith('.') and d != '__pycache__']
        for name in files:
            if len(artifacts) >= max_artifacts:
                return artifacts
            if name.startswith('.'):
                continue
            path = os.path.join(root, name)
            relative_path = os.path.relpath(path, _noema_temp_directory)
            if relative_path == 'script.py' or relative_path.endswith('.pyc'):
                continue

            try:
                size_bytes = os.path.getsize(path)
            except OSError:
                continue

            kind, mime_type = _noema_artifact_kind(path)
            data = None
            if 0 <= size_bytes <= max_embedded_bytes and embedded_bytes + size_bytes <= max_total_embedded_bytes:
                try:
                    with open(path, 'rb') as handle:
                        data = handle.read()
                    embedded_bytes += size_bytes
                except OSError:
                    data = None

            preview = None
            base64_data = None
            if data is not None:
                if kind == 'image':
                    base64_data = base64.b64encode(data).decode('ascii')
                else:
                    try:
                        preview = data[:max_preview_bytes].decode('utf-8').strip()
                    except UnicodeDecodeError:
                        preview = None

            artifacts.append({
                'relativePath': relative_path,
                'filename': name,
                'kind': kind,
                'mimeType': mime_type,
                'sizeBytes': size_bytes,
                'preview': preview,
                'base64Data': base64_data,
            })
    return artifacts

artifacts = _noema_collect_artifacts()

__noema_result_json = json.dumps({
    'stdout': stdout_buffer.getvalue(),
    'stderr': stderr_buffer.getvalue(),
    'exitCode': exit_code,
    'executionTimeMs': execution_time_ms,
    'error': error_message,
    'timedOut': timed_out,
    'artifacts': artifacts,
})
)PY";

}  // namespace

extern "C" struct NoemaEmbeddedPythonInitResult noema_embedded_python_initialize(
    const char *runtime_root,
    const char *stdlib_path,
    const char *executable_path,
    bool use_system_logger
) {
    if (gIsInitialized) {
        return {true, nullptr};
    }

    PyStatus status;
    PyConfig config;
    PyConfig_InitPythonConfig(&config);

    config.isolated = 1;
    config.use_environment = 0;
    config.user_site_directory = 0;
    config.site_import = 1;
    config.install_signal_handlers = 0;
    config.write_bytecode = 0;
    config.module_search_paths_set = 1;
#ifdef __APPLE__
    config.use_system_logger = use_system_logger ? 1 : 0;
#endif

    if (runtime_root != nullptr) {
        status = PyConfig_SetBytesString(&config, &config.home, runtime_root);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return {false, duplicateCString(status.err_msg)};
        }
    }

    if (executable_path != nullptr) {
        status = PyConfig_SetBytesString(&config, &config.program_name, executable_path);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return {false, duplicateCString(status.err_msg)};
        }

        status = PyConfig_SetBytesString(&config, &config.executable, executable_path);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return {false, duplicateCString(status.err_msg)};
        }
    }

    if (stdlib_path != nullptr) {
        wchar_t *stdlibWide = Py_DecodeLocale(stdlib_path, nullptr);
        status = PyWideStringList_Append(&config.module_search_paths, stdlibWide);
        PyMem_RawFree(stdlibWide);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return {false, duplicateCString(status.err_msg)};
        }

        std::string dynloadPath(stdlib_path);
        dynloadPath += "/lib-dynload";
        wchar_t *dynloadWide = Py_DecodeLocale(dynloadPath.c_str(), nullptr);
        status = PyWideStringList_Append(&config.module_search_paths, dynloadWide);
        PyMem_RawFree(dynloadWide);
        if (PyStatus_Exception(status)) {
            PyConfig_Clear(&config);
            return {false, duplicateCString(status.err_msg)};
        }
    }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);

    if (PyStatus_Exception(status)) {
        return {false, duplicateCString(status.err_msg)};
    }

    gMainThreadState = PyEval_SaveThread();
    gIsInitialized = true;
    return {true, nullptr};
}

extern "C" struct NoemaEmbeddedPythonExecutionResult noema_embedded_python_execute(
    const char *code,
    const char *sandbox_preamble,
    const char *temp_directory,
    double timeout_seconds
) {
    if (!gIsInitialized) {
        return {false, nullptr, duplicateCString("Embedded Python runtime has not been initialized.")};
    }

    PyGILState_STATE gilState = PyGILState_Ensure();

    PyObject *mainModule = PyImport_AddModule("__main__");
    if (mainModule == nullptr) {
        std::string error = pythonErrorString();
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateString(error)};
    }

    PyObject *globals = PyModule_GetDict(mainModule);
    if (globals == nullptr) {
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateCString("Embedded Python main module has no globals dictionary.")};
    }

    PyObject *userCode = setGlobalString(globals, "__noema_user_code", code);
    PyObject *sandbox = setGlobalString(globals, "__noema_sandbox_preamble", sandbox_preamble);
    PyObject *tempDirectory = setGlobalString(globals, "__noema_temp_directory", temp_directory);
    PyObject *timeout = PyFloat_FromDouble(timeout_seconds);

    if (userCode == nullptr || sandbox == nullptr || tempDirectory == nullptr || timeout == nullptr) {
        Py_XDECREF(userCode);
        Py_XDECREF(sandbox);
        Py_XDECREF(tempDirectory);
        Py_XDECREF(timeout);
        std::string error = pythonErrorString();
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateString(error)};
    }

    if (PyDict_SetItemString(globals, "__noema_timeout_seconds", timeout) != 0) {
        Py_DECREF(userCode);
        Py_DECREF(sandbox);
        Py_DECREF(tempDirectory);
        Py_DECREF(timeout);
        std::string error = pythonErrorString();
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateString(error)};
    }

    Py_DECREF(userCode);
    Py_DECREF(sandbox);
    Py_DECREF(tempDirectory);
    Py_DECREF(timeout);

    PyObject *execution = PyRun_StringFlags(kExecutionWrapper, Py_file_input, globals, globals, nullptr);
    if (execution == nullptr) {
        std::string error = pythonErrorString();
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateString(error)};
    }
    Py_DECREF(execution);

    PyObject *result = PyDict_GetItemString(globals, "__noema_result_json");
    if (result == nullptr) {
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateCString("Embedded Python execution completed without a result payload.")};
    }

    const char *json = PyUnicode_AsUTF8(result);
    if (json == nullptr) {
        std::string error = pythonErrorString();
        PyGILState_Release(gilState);
        return {false, nullptr, duplicateString(error)};
    }

    char *jsonCopy = duplicateCString(json);
    PyGILState_Release(gilState);
    return {true, jsonCopy, nullptr};
}

extern "C" void noema_embedded_python_reset(void) {
    if (!gIsInitialized) {
        return;
    }

    PyEval_RestoreThread(gMainThreadState);
    gMainThreadState = nullptr;
    Py_FinalizeEx();
    gIsInitialized = false;
}

extern "C" void noema_embedded_python_free_string(char *value) {
    if (value != nullptr) {
        std::free(value);
    }
}
