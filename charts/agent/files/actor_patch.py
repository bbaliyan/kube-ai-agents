# Runs inside the actor, in the master process of gunicorn, before gunicorn starts (see the command in
# templates/_helpers.tpl). It reports each running pr-agent command as the gauge pr_agent.commands_in_flight.
#
# Upstream gap: pr-agent has counters for commands, tokens and model calls, but no gauge for commands that
# run now. Upstream issue 5125 in The-PR-Agent/pr-agent asks for one. Delete this file, and its use in the
# command, when that ships.
#
# The wrapper is on handle_request, which also runs the final flush of the telemetry. It adds 1, flushes at
# once, runs the command, then subtracts 1 and flushes again. It never raises into the request path.
# The master forks the worker, and a thread that the master starts does not survive the fork. So the
# instrument is made on the first call, inside the worker, and never at import time.
import asyncio
import functools
import os


def _install_in_flight_gauge():
    if os.environ.get("OTEL__IS_ENABLED", "").lower() != "true":
        return
    from pr_agent.agent.pr_agent import PRAgent
    from pr_agent.log import get_logger
    from pr_agent.telemetry.meter import get_meter
    from pr_agent.telemetry.shutdown import flush_telemetry

    gauge = None

    async def change(delta):
        """Add delta to the gauge and push it. Return True if the gauge changed."""
        nonlocal gauge
        changed = False
        try:
            if gauge is None:
                gauge = get_meter().create_up_down_counter(
                    "pr_agent.commands_in_flight", unit="{command}", description="PR-Agent commands that run now"
                )
            gauge.add(delta)
            changed = True
            await asyncio.to_thread(flush_telemetry)
        except Exception as error:
            get_logger().warning(f"in-flight gauge: {error}")
        return changed

    original = PRAgent.handle_request

    @functools.wraps(original)
    async def handle_request(self, *args, **kwargs):
        counted = await change(1)
        try:
            return await original(self, *args, **kwargs)
        finally:
            if counted:
                await change(-1)

    PRAgent.handle_request = handle_request


def _name_each_worker():
    """Give each gunicorn worker its own service.instance.id, so the workers do not overwrite each other's series.

    The master forks the workers, and the meter of a worker is made later, inside it, from OTEL_RESOURCE_ATTRIBUTES.
    A hook that runs in each child, right after the fork, adds the id of the process there.
    """
    if os.environ.get("OTEL__IS_ENABLED", "").lower() != "true":
        return

    def in_child():
        attributes = [a for a in os.environ.get("OTEL_RESOURCE_ATTRIBUTES", "").split(",") if a]
        os.environ["OTEL_RESOURCE_ATTRIBUTES"] = ",".join(attributes + [f"service.instance.id={os.getpid()}"])

    os.register_at_fork(after_in_child=in_child)


_name_each_worker()
_install_in_flight_gauge()
