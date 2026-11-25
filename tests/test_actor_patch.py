"""Unit tests for charts/agent/files/actor_patch.py, run against stub pr_agent modules.

Run: python3 -m unittest discover -s tests
"""
import asyncio
import os
import sys
import types
import unittest
from pathlib import Path

PATCH = Path(__file__).resolve().parent.parent / "charts" / "agent" / "files" / "actor_patch.py"


class Gauge:
    def __init__(self, log):
        self.value = 0
        self.log = log

    def add(self, delta):
        self.value += delta
        self.log.append(("add", delta, self.value))


def install_stubs(test, original, gauge_error=None, flush_error=None):
    """Put stub pr_agent modules in sys.modules. Return the gauge and the event log."""
    log = []
    gauge = Gauge(log)
    names = ["pr_agent", "pr_agent.agent", "pr_agent.agent.pr_agent", "pr_agent.log",
             "pr_agent.telemetry", "pr_agent.telemetry.meter", "pr_agent.telemetry.shutdown"]
    saved = {name: sys.modules.get(name) for name in names}
    test.addCleanup(lambda: [sys.modules.pop(n, None) if v is None else sys.modules.__setitem__(n, v) for n, v in saved.items()])
    modules = {name: types.ModuleType(name) for name in names}

    class PRAgent:
        pass

    PRAgent.handle_request = original
    modules["pr_agent.agent.pr_agent"].PRAgent = PRAgent

    class Meter:
        def create_up_down_counter(self, name, unit, description):
            log.append(("create", name, unit))
            if gauge_error:
                raise gauge_error
            return gauge

    modules["pr_agent.telemetry.meter"].get_meter = lambda: Meter()

    def flush_telemetry(timeout_millis=None):
        log.append(("flush", gauge.value))
        if flush_error:
            raise flush_error

    modules["pr_agent.telemetry.shutdown"].flush_telemetry = flush_telemetry

    class Logger:
        def warning(self, message):
            log.append(("warning", message))

    modules["pr_agent.log"].get_logger = lambda: Logger()
    sys.modules.update(modules)
    return PRAgent, gauge, log


def run_patch():
    exec(compile(PATCH.read_text(), str(PATCH), "exec"), {"__name__": "actor_patch"})


class ActorPatchTest(unittest.TestCase):
    def setUp(self):
        saved = os.environ.get("OTEL__IS_ENABLED")
        self.addCleanup(lambda: os.environ.pop("OTEL__IS_ENABLED", None) if saved is None else os.environ.__setitem__("OTEL__IS_ENABLED", saved))
        os.environ["OTEL__IS_ENABLED"] = "true"

    def test_count_is_1_during_the_command_and_0_after(self):
        seen = []

        async def original(self, *args, **kwargs):
            seen.append(gauge.value)
            return "done"

        PRAgent, gauge, log = install_stubs(self, original)
        run_patch()
        self.assertEqual(asyncio.run(PRAgent().handle_request("a", key="b")), "done")
        self.assertEqual(seen, [1])
        self.assertEqual(gauge.value, 0)
        self.assertIn(("flush", 1), log)
        self.assertEqual(log[-1], ("flush", 0))

    def test_count_goes_back_to_0_when_the_command_raises(self):
        async def original(self):
            raise ValueError("boom")

        PRAgent, gauge, log = install_stubs(self, original)
        run_patch()
        with self.assertRaises(ValueError):
            asyncio.run(PRAgent().handle_request())
        self.assertEqual(gauge.value, 0)
        self.assertEqual(log[-1], ("flush", 0))

    def test_a_failing_meter_does_not_stop_the_command(self):
        ran = []

        async def original(self):
            ran.append(True)
            return "done"

        PRAgent, gauge, log = install_stubs(self, original, gauge_error=RuntimeError("no meter"))
        run_patch()
        self.assertEqual(asyncio.run(PRAgent().handle_request()), "done")
        self.assertEqual(ran, [True])
        self.assertEqual(gauge.value, 0)
        self.assertTrue([entry for entry in log if entry[0] == "warning"])

    def test_a_failing_flush_does_not_stop_the_command(self):
        async def original(self):
            return "done"

        PRAgent, gauge, log = install_stubs(self, original, flush_error=OSError("no collector"))
        run_patch()
        self.assertEqual(asyncio.run(PRAgent().handle_request()), "done")
        self.assertEqual(gauge.value, 0)
        self.assertTrue([entry for entry in log if entry[0] == "warning"])

    def test_the_instrument_is_made_on_the_first_call_and_not_at_import(self):
        async def original(self):
            return None

        PRAgent, gauge, log = install_stubs(self, original)
        run_patch()
        self.assertEqual(log, [])
        asyncio.run(PRAgent().handle_request())
        asyncio.run(PRAgent().handle_request())
        self.assertEqual([entry for entry in log if entry[0] == "create"], [("create", "pr_agent.commands_in_flight", "{command}")])

    @unittest.skipUnless(hasattr(os, "fork"), "needs fork")
    def test_each_forked_worker_gets_its_own_instance_id_and_the_master_does_not(self):
        async def original(self):
            return None

        os.environ["OTEL_RESOURCE_ATTRIBUTES"] = "ate.actor=a/b"
        self.addCleanup(os.environ.pop, "OTEL_RESOURCE_ATTRIBUTES", None)
        install_stubs(self, original)
        run_patch()
        read, write = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.write(write, os.environ["OTEL_RESOURCE_ATTRIBUTES"].encode())
            os._exit(0)
        os.waitpid(pid, 0)
        os.close(write)
        child = os.read(read, 4096).decode()
        os.close(read)
        self.assertTrue(child.startswith("ate.actor=a/b,service.instance.id="), child)
        self.assertIn(f"service.instance.id={pid}", child)
        self.assertEqual(os.environ["OTEL_RESOURCE_ATTRIBUTES"], "ate.actor=a/b")

    def test_nothing_runs_when_telemetry_is_off(self):
        async def original(self):
            return "done"

        for value in ("false", ""):
            os.environ["OTEL__IS_ENABLED"] = value
            PRAgent, gauge, log = install_stubs(self, original)
            run_patch()
            self.assertIs(PRAgent.handle_request, original)
            self.assertEqual(asyncio.run(PRAgent().handle_request()), "done")
            self.assertEqual(log, [])


if __name__ == "__main__":
    unittest.main()
