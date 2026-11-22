"""Exercise the timing gate with a deterministic slow measurement backend."""

import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import sys
from unittest.mock import patch


def reject(platform, ceiling, slow_control, label):
    with patch.object(sys, "platform", platform):
        module = runpy.run_path(str(Path(__file__).with_name("long-input.py")))
    assert module["LARGE_INPUT_MAX_SECONDS"] == ceiling
    namespace = module["main"].__globals__
    slow_seen = False
    large_duration = 9 if platform == "darwin" else 8

    def measure(command, data, env, limit, deadline):
        nonlocal slow_seen
        assert not slow_seen, "the gate continued after the first slow large input"
        fields = json.loads(data)["tool_input"]
        text = fields.get("description", fields["file_path"])
        large = len(text) == module["SIZE"]
        duration = large_duration if large else large_duration / 4
        if not slow_control and "description" in fields:
            duration = 0.5
        if large and duration == large_duration:
            slow_seen = True
            assert limit == ceiling, "large inputs must retain platform-specific hook headroom"
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


for platform, ceiling in (("linux", 5), ("darwin", 8)):
    # The relative budget alone allows these proportional slow measurements.
    reject(platform, ceiling, True, "large control exceeds scaling budget")
    # A cheap control must not hide the same slowdown in the candidate's field.
    reject(platform, ceiling, False, f"limit {ceiling:.3f}s")
print("long-input absolute-budget fixtures passed: 4")
