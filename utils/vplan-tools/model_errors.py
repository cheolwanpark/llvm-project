"""Errors shared by the model and command-line tools."""

class ToolError(Exception):
    pass


class ObservationUnavailable(ToolError):
    """Well-formed backend facts whose iteration/spill coverage is unproven."""
