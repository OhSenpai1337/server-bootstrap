import json
import os
import sqlite3
import secrets
import time

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


sniffing = {
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"]
}

# VLESS + WebSocket
vless_settings = {
    "clients": [],
    "decryption": "none",
    "encryption": "none",
    "disable_flow": 1
}

vless_stream = {
    "network": "ws",
    "wsSettings": {
        "acceptProxyProtocol": False,
        "path": vless_ws_path,
        "host": "",
        "headers": {},
        "heartbeatPeriod": 0
    },
    "security": "none"
}

# Hysteria 2
hysteria_settings = {
    "version": 2
}

hysteria_stream = {
    "network": "hysteria",
    "hysteriaSettings": {
        "version": 2,
        "udpIdleTimeout": 60,
        "masquerade": {
            "type": "proxy",
            "dir": "",
            "url": f"https://{domain}/",
            "rewriteHost": False,
            "insecure": False,
            "content": "",
            "headers": {},
            "statusCode": 0
        }
    },
    "security": "tls",
    "tlsSettings": {
        "serverName": domain,
        "minVersion": "1.2",
        "maxVersion": "1.3",
        "cipherSuites": "",
        "rejectUnknownSni": False,
        "disableSystemRoot": False,
        "enableSessionResumption": False,
        "certificates": [{
            "ocspStapling": 0,
            "oneTimeLoading": False,
            "usage": "encipherment",
            "buildChain": False,
            "certificateFile": cert_file,
            "keyFile": key_file,
            "useFile": True
        }],
        "alpn": ["h3"],
        "echServerKeys": "",
        "settings": {
            "fingerprint": "chrome",
            "echConfigList": "",
            "pinnedPeerCertSha256": [],
            "verifyPeerCertByName": ""
        }
    },
    "finalmask": {
        "udp": [{
            "type": "salamander",
            "settings": {
                "password": hysteria_password
            }
        }]
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
        "in-443-udp",
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
        remark=f"{server_country} (WS)" if autodetect_country == "true" else "VLESS (WS)",
        tag="in-8888-tcp",
        listen="127.0.0.1",
        port=8888,
        protocol="vless",
        settings=vless_settings,
        stream_settings=vless_stream,
        flow=1
    )

    # 2. Hysteria 2
    hysteria_id = add_inbound(
        remark=f"{server_country} (Hysteria)" if autodetect_country == "true" else "Hysteria",
        tag="in-443-udp",
        listen="",
        port=443,
        protocol="hysteria",
        settings=hysteria_settings,
        stream_settings=hysteria_stream,
        flow=0
    )

    # 3. TUIC
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
        "WS",
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
        encode(["h2", "http/1.1"]),
        "chrome",
        "",
        1,
        0,
        now,
        now
    ))

    conn.commit()

    print("Created inbounds:")
    print(f"  VLESS WS:    ID={vless_id}, port=8888")
    print(f"  Hysteria 2:  ID={hysteria_id}, port=443/UDP")
    print(f"  TUIC:        ID={tuic_id}, port=8443/UDP")
    print(f"  WebSocket Host: {domain}:443")

except Exception:
    conn.rollback()
    raise

finally:
    conn.close()