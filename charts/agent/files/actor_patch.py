# Runs inside the actor, in the master process of gunicorn, before gunicorn starts (see the command in
# templates/_helpers.tpl). It reports each running pr-agent command as the gauge pr_agent.commands_in_flight, and
# each command that ends as the counters pr_agent.commands_finished (outcome ok or failed, and the command) and
# pr_agent.commands_by_model (the model that answered, and whether it was a fallback).
#
# Upstream gap: pr-agent has counters for commands, tokens and model calls, but no gauge for commands that
# run now. Upstream issue 5125 in The-PR-Agent/pr-agent asks for one. Delete this file, and its use in the
# command, when that ships. The same goes for the outcome and the model of a command: pr-agent keeps both in its run
# details, and reports neither as a metric.
#
# The wrapper is on handle_request, which also runs the final flush of the telemetry. It adds 1, flushes at
# once, runs the command, then subtracts 1 and flushes again. It never raises into the request path.
# Each worker gets its own service.instance.id, from a hook after the fork, so that the workers do not overwrite each other's
# series: the master forks the workers, and the meter of a worker is made later, inside it, from OTEL_RESOURCE_ATTRIBUTES.
# The master forks the worker, and a thread that the master starts does not survive the fork. So the
# instrument is made on the first call, inside the worker, and never at import time.
import asyncio
import functools
import os


def _install_in_flight_gauge():
    if os.environ.get("OTEL__IS_ENABLED", "").lower() != "true":
        return
    from pr_agent.agent.pr_agent import PRAgent
    from pr_agent.agent.request_policy import RequestOutcome
    from pr_agent.algo.run_details import command_failed, get_run_details
    from pr_agent.log import get_logger
    from pr_agent.telemetry.meter import get_meter
    from pr_agent.telemetry.shutdown import flush_telemetry

    instruments = None

    async def record(delta, outcome=None, model=None, fallback=False, command="unknown"):
        nonlocal instruments
        changed = False
        try:
            if instruments is None:
                meter = get_meter()
                instruments = (
                    meter.create_up_down_counter(
                        "pr_agent.commands_in_flight", unit="{command}", description="Commands that run now"
                    ),
                    meter.create_counter(
                        "pr_agent.commands_finished", unit="{command}", description="Commands that ended"
                    ),
                    meter.create_counter(
                        "pr_agent.commands_by_model", unit="{command}",
                        description="Commands by model",
                    ),
                )
            gauge, finished, by_model = instruments
            gauge.add(delta)
            changed = True
            if outcome:
                finished.add(1, {"outcome": outcome, "pr_agent.command": command})
            if model:
                by_model.add(1, {"model": model, "fallback": "true" if fallback else "false"})
            await asyncio.to_thread(flush_telemetry)
        except Exception as error:
            get_logger().warning(f"in-flight gauge: {error}")
        return changed

    original = PRAgent.handle_request

    @functools.wraps(original)
    async def handle_request(self, *args, **kwargs):
        counted = await record(1)
        outcome, model, fallback, command = "failed", None, False, "unknown"
        try:
            request = args[1] if len(args) > 1 else kwargs.get("request")
            command = (request.split(None, 1)[0] if isinstance(request, str) else request[0]).lstrip("/").lower()
        except Exception:
            pass
        try:
            result = await original(self, *args, **kwargs)
            if result is RequestOutcome.SKIPPED:
                outcome = None
            else:
                outcome = "ok" if result and not command_failed() else "failed"
            details = get_run_details()
            if outcome and details is not None and details.model_used:
                model, fallback = details.model_used, details.fallback_used
            return result
        finally:
            if counted:
                await record(-1, outcome, model, fallback, command)

    PRAgent.handle_request = handle_request


def _name_each_worker():
    if os.environ.get("OTEL__IS_ENABLED", "").lower() != "true":
        return

    def in_child():
        attributes = [a for a in os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "").split(",") if a]
        os.environ["OTEL_RESOURCE_ATTRIBUTES"] = ",".join(attributes + [f"service.instance.id={os.getpid()}"])

    os.register_at_fork(after_in_child=in_child)


_name_each_worker()
_install_in_flight_gauge()
