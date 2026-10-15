"""Loopback-only TCP/TLS interruption + HTTP/3 peer for http3_image_probe.dart.

Test dependency: aioquic==1.6.1 (not an application dependency).
"""

import argparse
import asyncio
import base64
import datetime
import json
from pathlib import Path
import struct
import zlib

from aioquic.asyncio import QuicConnectionProtocol, serve
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


def png_chunk(kind, data):
    payload = kind + data
    return (
        struct.pack(">I", len(data))
        + payload
        + struct.pack(">I", zlib.crc32(payload) & 0xFFFFFFFF)
    )


PNG = (
    b"\x89PNG\r\n\x1a\n"
    + png_chunk(b"IHDR", struct.pack(">2I5B", 1, 1, 8, 6, 0, 0, 0))
    + png_chunk(b"IDAT", zlib.compress(b"\x00\xff\xff\xff\xff"))
    + png_chunk(b"IEND", b"")
)
HOSTNAME = "images.http3.test"


def make_certificates(directory):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Local HTTP3 probe CA")])
    now = datetime.datetime.now(datetime.timezone.utc)
    ca = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(False, False, False, False, False, True, True, False, False),
            critical=True,
        )
        .sign(key, hashes.SHA256())
    )
    server_key = ec.generate_private_key(ec.SECP256R1())
    server = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, HOSTNAME)]))
        .issuer_name(name)
        .public_key(server_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(HOSTNAME)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.ExtendedKeyUsage([x509.oid.ExtendedKeyUsageOID.SERVER_AUTH]),
            critical=False,
        )
        .sign(key, hashes.SHA256())
    )
    ca_file = directory / "ca.pem"
    server_file = directory / "server.pem"
    key_file = directory / "server-key.pem"
    ca_file.write_bytes(ca.public_bytes(serialization.Encoding.PEM))
    server_file.write_bytes(server.public_bytes(serialization.Encoding.PEM))
    key_file.write_bytes(
        server_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return ca_file, server_file, key_file


class Http3Peer(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.http = H3Connection(self._quic)

    def quic_event_received(self, event):
        for http_event in self.http.handle_event(event):
            if not isinstance(http_event, HeadersReceived):
                continue
            headers = dict(http_event.headers)
            path = headers.get(b":path", b"")
            if path.startswith(b"/slow"):
                continue
            redirect_referer = (
                b"https://" + headers.get(b":authority", b"") + b"/redirect?key=probe"
            )
            valid = (
                headers.get(b":method") == b"GET"
                and headers.get(b"cookie") == b"session=probe"
                and headers.get(b"authorization") == b"Bearer probe"
                and headers.get(b"referer")
                in (b"https://source.http3.test/", redirect_referer)
                and path.endswith(b"?key=probe")
            )
            if valid and path.startswith(b"/redirect"):
                response = [(b":status", b"302"), (b"location", b"/image?key=probe")]
                body = b""
            else:
                response = [
                    (b":status", b"200" if valid else b"400"),
                    (b"content-type", b"image/png"),
                    (b"content-length", str(len(PNG)).encode()),
                    (b"x-probe-protocol", b"h3"),
                ]
                body = PNG
            self.http.send_headers(http_event.stream_id, response)
            self.http.send_data(http_event.stream_id, body, end_stream=True)
            self.transmit()


async def interrupt_tls(reader, writer):
    try:
        await asyncio.wait_for(reader.read(8192), timeout=5)
    finally:
        writer.close()
        await writer.wait_closed()


async def main(state_file):
    state_file.parent.mkdir(parents=True, exist_ok=True)
    ca_file, server_file, key_file = make_certificates(state_file.parent)
    tcp = await asyncio.start_server(interrupt_tls, "127.0.0.1", 0)
    port = tcp.sockets[0].getsockname()[1]
    configuration = QuicConfiguration(is_client=False, alpn_protocols=H3_ALPN)
    configuration.load_cert_chain(server_file, key_file)
    quic = await serve(
        "127.0.0.1", port, configuration=configuration, create_protocol=Http3Peer
    )
    state_file.write_text(
        json.dumps(
            {
                "port": port,
                "hostname": HOSTNAME,
                "ca": str(ca_file),
                "png": base64.b64encode(PNG).decode(),
            }
        ),
        encoding="utf-8",
    )
    print(f"Loopback HTTP/3 peer ready on port {port}", flush=True)
    try:
        await asyncio.Future()
    finally:
        quic.close()
        tcp.close()
        await tcp.wait_closed()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    asyncio.run(main(args.state.resolve()))
