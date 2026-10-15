#!/usr/bin/env python3
"""Expose a loopback-only host LLM to libvirt guests, not to the public LAN.

Run on the *host*:
    python3 scripts/host-llm-gateway.py --port 8002

Requires a server already listening at 127.0.0.1:8002. The relay binds
only to the libvirt NAT gateway and accepts only connections from its subnet.
This is a plain TCP proxy, so streaming and OpenAI-compatible APIs work.
"""
import argparse
import asyncio
import ipaddress


async def forward(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        writer.close()


async def serve_connection(reader, writer, upstream_host, upstream_port, network):
    peer = writer.get_extra_info("peername")
    try:
        if not peer or ipaddress.ip_address(peer[0]) not in network:
            writer.close()
            await writer.wait_closed()
            return
        remote_reader, remote_writer = await asyncio.open_connection(upstream_host, upstream_port)
        a = asyncio.create_task(forward(reader, remote_writer))
        b = asyncio.create_task(forward(remote_reader, writer))
        done, pending = await asyncio.wait({a, b}, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        await asyncio.gather(*pending, return_exceptions=True)
        await asyncio.gather(*done, return_exceptions=True)
        remote_writer.close()
        writer.close()
        await asyncio.gather(remote_writer.wait_closed(), writer.wait_closed(), return_exceptions=True)
    except (OSError, ConnectionError):
        writer.close()
        await writer.wait_closed()


async def main_async(args):
    network = ipaddress.ip_network(args.allow_cidr, strict=False)
    if not isinstance(network, ipaddress.IPv4Network):
        raise ValueError("IPv4 guest network required")
    server = await asyncio.start_server(
        lambda r, w: serve_connection(r, w, args.upstream_host, args.upstream_port, network),
        args.listen, args.port,
    )
    print(f"host LLM gateway listening at {args.listen}:{args.port}; "
          f"upstream {args.upstream_host}:{args.upstream_port}; allowed {network}", flush=True)
    async with server:
        await server.serve_forever()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--listen", default="192.168.122.1")
    parser.add_argument("--port", type=int, default=8002)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int)
    parser.add_argument("--allow-cidr", default="192.168.122.0/24")
    args = parser.parse_args()
    args.upstream_port = args.upstream_port or args.port
    if not (1 <= args.port <= 65535 and 1 <= args.upstream_port <= 65535):
        parser.error("ports must be in 1..65535")
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
