"""Exercise the timing gate with a deterministic slow measurement backend."""

import contextlib
import io
import json
import os
from pathlib import Path
import runpy
from unittest.mock import patch


def reject(slow_control, label):
    module = runpy.run_path(str(Path(__file__).with_name("long-input.py")))
    namespace = module["main"].__globals__
    slow_seen = False

    def measure(command, data, env, limit, deadline):
        nonlocal slow_seen
        assert not slow_seen, "the gate continued after the first slow large input"
        fields = json.loads(data)["tool_input"]
        text = fields.get("description", fields["file_path"])
        large = len(text) == module["SIZE"]
        duration = (8 if large else 2) if slow_control or "description" not in fields else 0.5
        if large and duration == 8:
            slow_seen = True
            assert limit == 5, "large inputs must retain five seconds of prompt-hook headroom"
        if duration > limit:
            return None, limit + 0.001, b"", b""
        return 0, duration, b"", b""

    output = io.StringIO()
    with patch.dict(os.environ, AGENT_GUARD_TEST_LONG_INPUT_AWKS="default",
                    AGENT_GUARD_TEST_REQUIRE_AWKS=""), \
            patch.dict(namespace, measure=measure, correct=lambda *args, **kwargs: True), \
            contextlib.redirect_stdout(output):
        status = module["main"]()
    assert status == 1, "a slow large input passed"
    assert slow_seen, "a different measurement failed before the large input"
    assert label in output.getvalue()


# The relative budget alone allows 8s after a 2s quarter-sized measurement.
reject(True, "large control exceeds scaling budget")
# A cheap control must not hide the same slowdown in the candidate's field.
reject(False, "limit 5.000s")
print("long-input absolute-budget fixtures passed: 2")
