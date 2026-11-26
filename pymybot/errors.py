class ControllerError(Exception):
    """Controller failure; previously issued hardware effects are not reversible."""


class ScriptError(ControllerError, ValueError):
    pass


class DriverError(ControllerError):
    pass


class DriverNotReady(DriverError):
    pass


class BudgetExceeded(ControllerError):
    pass


class AgentInterrupted(ControllerError):
    """Cooperative agent cancellation, distinct from a task timeout or failure."""
