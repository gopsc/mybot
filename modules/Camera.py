class Driver:
    def __init__(self, context):
        self.context = context
        self.handle = None
        self.defaults = {}

    def _close(self):
        if self.handle is None:
            return 0
        handle, self.handle = self.handle, None
        return self.context.call("close_handle", handle)

    def _failure(self, fallback):
        message = self.context.call("last_error")
        return {"result": "ERR", "message": message or fallback}

    def _options(self, data):
        if not isinstance(data, dict):
            return None, "Invalid Arguments Type: table"
        if (data.get("width") is None) != (data.get("height") is None):
            return None, "width and height must be given together"
        options = dict(self.defaults)
        options.update((key, value) for key, value in data.items() if value is not None)
        if "src" in options and not isinstance(options["src"], str):
            return None, "camera src must be a nonempty path"
        return options, None

    def _open(self, options):
        handle = self.context.call(
            "camera_open", options.get("path", options.get("device", 0)),
            options.get("width", 640), options.get("height", 480),
        )
        if isinstance(handle, bool) or not isinstance(handle, int) or handle < 0:
            return self._failure("Failed to open camera")
        self.handle = handle
        return None

    def _capture(self, options):
        result = self.context.call("camera_capture", self.handle, options)
        if isinstance(result, dict) and result.get("result") in ("OK", "ERR"):
            return result
        return self._failure("Failed to capture image")

    def build(self, data):
        self.context.check()
        self.defaults = {}
        self._close()
        options, message = self._options(data)
        if options is None:
            return {"result": "ERR", "message": message}
        failure = self._open(options)
        if failure is not None:
            return failure
        if options.get("src") not in (None, ""):
            result = self._capture(options)
            if result["result"] != "OK":
                self._close()
                return result
        self.defaults = options
        return {"result": "OK"}

    def call(self, data):
        self.context.check()
        options, message = self._options(data)
        if options is None:
            return {"result": "ERR", "message": message}
        if self.handle is None:
            failure = self._open(options)
            if failure is not None:
                return failure
        return self._capture(options)

    def read(self, data):
        return self.call(data)

    def destroy(self, data):
        self.defaults = {}
        result = self._close()
        if result != 0:
            return self._failure("Failed to close camera")
        return {"result": "OK"}
