#!/usr/bin/env python3
"""The official MCP Python SDK, as a client of this server.

    pip install --require-hashes -r tests/mcp/requirements.txt
    python3 tests/mcp/sdk_client.py

A server that only its own tests understand proves little. This one is
driven by the reference client of the protocol, pinned by hash, against
manifests/mcp/server.py on localhost (tests/mcp/harness.py): it discovers
the server, negotiates 2026-07-28, lists and calls tools and reads resources
as two identities, and is refused what each is not granted. Prints one line
per check and exits non-zero if any fails.
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import harness  # noqa: E402

from mcp import Client  # noqa: E402
from mcp.client.streamable_http import streamable_http_client  # noqa: E402
from mcp.shared._httpx_utils import create_mcp_http_client  # noqa: E402

failed = []


def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + (": " + detail if detail and not ok else ""), flush=True)
    if not ok:
        failed.append(name)


async def as_identity(url, token):
    http = create_mcp_http_client(headers={"Authorization": "Bearer " + token})
    return http, Client(streamable_http_client(url, http_client=http, terminate_on_close=False))


async def main():
    with harness.running() as (url, _, _):
        http, client = await as_identity(url, "researcher-token")
        async with http, client as c:
            tools = [t.name for t in (await c.list_tools()).tools]
            check("researcher: the SDK lists the one granted tool", tools == ["quarterly_report"], str(tools))
            r = await c.call_tool("quarterly_report", {})
            text = r.content[0].text if r.content else ""
            check("researcher: the SDK calls it and gets the upstream's answer", not r.is_error and "SYSTEM NOTE" in text,
                  text[:80])
            try:
                r = await c.call_tool("records_lookup", {"customer_id": "C0001"})
                refused = bool(r.is_error)
            except Exception as e:  # the SDK raises on a JSON-RPC error
                refused = "Unknown tool" in str(e)
            check("researcher: a tool it is not granted is refused", refused)
            res = [str(x.uri) for x in (await c.list_resources()).resources]
            check("researcher: the SDK lists the one granted resource", res == ["report://quarterly"], str(res))

        http, client = await as_identity(url, "clerk-token")
        async with http, client as c:
            tools = [t.name for t in (await c.list_tools()).tools]
            check("records-clerk: the SDK lists its granted tool", tools == ["records_lookup"], str(tools))
            r = await c.call_tool("records_lookup", {"customer_id": "C0001"})
            text = r.content[0].text if r.content else ""
            check("records-clerk: the record comes back, fetched with a key the client never held",
                  not r.is_error and "Northwind" in text and harness.KEY not in text, text[:80])
            r = await c.read_resource("records://index")
            check("records-clerk: the SDK reads its granted resource", "C0001" in r.contents[0].text)
            try:
                r = await c.call_tool("delete_record", {"customer_id": "C0001"})
                refused = bool(r.is_error)
            except Exception as e:
                refused = "Unknown tool" in str(e)
            check("records-clerk: the destructive tool is refused", refused)

        http, client = await as_identity(url, "not-a-token")
        try:
            async with http, client as c:
                await c.list_tools()
            check("an unknown token is refused", False, "the SDK listed tools")
        except Exception:
            check("an unknown token is refused", True)
    print("%d failed" % len(failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
