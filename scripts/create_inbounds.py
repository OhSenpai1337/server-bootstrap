import json
import os
import sqlite3
import secrets
import time
import re
import subprocess
import shutil

DB_FILE = "/etc/x-ui/x-ui.db"

domain = os.environ["DOMAIN"]
cert_file = os.environ["CERT_FILE"]
key_file = os.environ["KEY_FILE"]
vless_ws_path = os.environ["XUI_VLESS_WS_PATH"]
hysteria_password = os.environ["HYSTERIA_PASSWORD"]
autodetect_country = os.environ["XUI_AUTODETECT_COUNTRY"]
server_country = os.environ.get("SERVER_COUNTRY", "Unknown")

def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

def generate_vless_encryption():
    xray_candidates = [
        "/usr/local/x-ui/bin/xray-linux-amd64",
        "/usr/local/x-ui/bin/xray",
        shutil.which("xray")
    ]

    xray_bin = next(
        (path for path in xray_candidates if path and os.path.isfile(path) and os.access(path, os.X_OK)),
        None
    )

    if not xray_bin:
        raise RuntimeError("Xray binary not found")

    result = subprocess.run(
        [xray_bin, "vlessenc"],
        capture_output=True,
        text=True,
        check=True,
        timeout=30
    )

    output = result.stdout

    match = re.search(
        r"Authentication:\s*X25519[^\n]*\n"
        r'"decryption"\s*:\s*"([^"]+)"\s*\n'
        r'"encryption"\s*:\s*"([^"]+)"',
        output
    )

    if not match:
        raise RuntimeError("Failed to parse X25519 Native keys")

    decryption, encryption = match.groups()

    if ".native." not in decryption or ".native." not in encryption:
        raise RuntimeError("Generated keys are not X25519 Native")

    return {
        "decryption": decryption,
        "encryption": encryption
    }

sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic"]
}

# VLESS + WebSocket
vless_settings = {
    "clients": [],
    **generate_vless_encryption()
}

vless_stream = {
    "network": "xhttp",
    "xhttpSettings": {
      "path": vless_ws_path,
      "host": domain,
      "mode": "stream-one",
      "xPaddingBytes": "128-1120",
      "xPaddingObfsMode": False,
      "xPaddingKey": "",
      "xPaddingHeader": "",
      "xPaddingPlacement": "",
      "xPaddingMethod": "",
      "sessionIDPlacement": "",
      "sessionIDKey": "",
      "sessionIDTable": "",
      "sessionIDLength": "",
      "seqPlacement": "",
      "seqKey": "",
      "uplinkDataPlacement": "",
      "uplinkDataKey": "",
      "scMaxEachPostBytes": "",
      "noSSEHeader": False,
      "scMaxBufferedPosts": 30,
      "scStreamUpServerSecs": "20-80",
      "serverMaxHeaderBytes": 0,
      "uplinkHTTPMethod": "",
      "headers": {},
      "scMinPostsIntervalMs": "",
      "uplinkChunkSize": 0,
      "noGRPCHeader": False,
      "xmux": {
        "maxConcurrency": "",
        "maxConnections": "1-3",
        "cMaxReuseTimes": 0,
        "hMaxRequestTimes": "600-900",
        "hMaxReusableSecs": "1800-3000",
        "hKeepAlivePeriod": 0
      },
      "enableXmux": True
    },
    "security": "none",
    "sockopt": {
      "tcpcongestion": "bbr",
      "trustedXForwardedFor": [
        "X-Real-IP"
      ],
      "acceptProxyProtocol": False,
      "tcpFastOpen": False,
      "mark": 0,
      "tproxy": "off",
      "tcpMptcp": False,
      "penetrate": False,
      "domainStrategy": "AsIs",
      "tcpMaxSeg": 0,
      "dialerProxy": "",
      "tcpKeepAliveInterval": 0,
      "tcpKeepAliveIdle": 0,
      "tcpUserTimeout": 0,
      "V6Only": False,
      "tcpWindowClamp": 0,
      "interface": "",
      "addressPortStrategy": "none",
      "customSockopt": []
    }
}

# TUIC
tuic_settings = {
    "server": {
        "alpn": ["h3", "spdy/3.1"],
        "authentication_timeout": 3,
        "certificate": cert_file,
        "congestion_control": "bbr",
        "log_level": "info",
        "max_idle_time": 15,
        "max_udp_relay_packet_size": 1500,
        "private_key": key_file,
        "sni": domain,
        "udp_relay_mode": "native",
        "zero_rtt_handshake": True
    }
}

conn = sqlite3.connect(DB_FILE)

try:
    conn.execute("BEGIN IMMEDIATE")

    # Prevent duplicate inbounds
    tags = [
        "in-8888-tcp",
        "in-8443-udp"
    ]

    placeholders = ",".join("?" for _ in tags)

    existing = conn.execute(
        f"SELECT tag FROM inbounds WHERE tag IN ({placeholders})",
        tags
    ).fetchall()

    if existing:
        raise RuntimeError(
            "Inbound tags already exist: " +
            ", ".join(row[0] for row in existing)
        )

    def add_inbound(remark, tag, listen, port, protocol,
                    settings, stream_settings, flow):
        cursor = conn.execute("""
            INSERT INTO inbounds (
                user_id, up, down, total,
                remark, enable, expiry_time,
                listen, port, protocol,
                settings, stream_settings,
                tag, sniffing, disable_flow
            )
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, (
            1, 0, 0, 0,
            remark, 1, 0,
            listen, port, protocol,
            encode(settings),
            encode(stream_settings),
            tag,
            encode(sniffing),
            flow
        ))

        return cursor.lastrowid

    # 1. VLESS + WS
    vless_id = add_inbound(
        remark=f"{server_country} (XHTTP)" if autodetect_country == "true" else "VLESS (XHTTP)",
        tag="in-8888-tcp",
        listen="127.0.0.1",
        port=8888,
        protocol="vless",
        settings=vless_settings,
        stream_settings=vless_stream,
        flow=0
    )

    # 2. TUIC
    tuic_id = add_inbound(
        remark=f"{server_country} (TUIC)" if autodetect_country == "true" else "TUIC",
        tag="in-8443-udp",
        listen="",
        port=8443,
        protocol="tuic",
        settings=tuic_settings,
        stream_settings={},
        flow=0
    )

    # WebSocket Host for VLESS
    now = int(time.time() * 1000)

    conn.execute("""
        INSERT INTO hosts (
            group_id,
            inbound_id,
            sort_order,
            remark,
            server_description,
            is_disabled,
            is_hidden,
            tags,
            address,
            port,
            security,
            sni,
            host_header,
            path,
            alpn,
            fingerprint,
            cipher_suites,
            override_sni_from_address,
            keep_sni_blank,
            created_at,
            updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        secrets.token_hex(8),
        vless_id,
        0,
        "XHTTP",
        "",
        0,
        0,
        "[]",
        domain,
        443,
        "tls",
        "",
        "",
        "",
        encode(["h2", "h3"]),
        "chrome",
        "",
        1,
        0,
        now,
        now
    ))

    conn.commit()

    print("Created inbounds:")
    print(f"  VLESS XHTTP: ID={vless_id}, port=8888")
    print(f"  TUIC:        ID={tuic_id}, port=8443/UDP")
    print(f"  XHTTP Host:  {domain}:443")

except Exception:
    conn.rollback()
    raise

finally:
    conn.close()