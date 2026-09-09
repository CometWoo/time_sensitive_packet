"""bpf_harness.py — bpftool 기반 BPF_PROG_TEST_RUN 단위 테스트 하네스

커널 기능 BPF_PROG_TEST_RUN(bpf(2) BPF_PROG_RUN) 을 이용해 실제 NIC/트래픽 없이
SCHED_CLS(tc) 프로그램을 실행한다:
  - data_in  : 우리가 만든 이더넷 프레임 → 커널이 진짜 skb 로 감싸 프로그램에 넘김
  - ctx_in   : struct __sk_buff 초기값 (priority 등 일부 필드만 설정 가능)
  - data_out : 프로그램이 수정한 뒤의 패킷 (DSCP/체크섬 검증)
  - ctx_out  : 프로그램이 수정한 뒤의 __sk_buff (skb->priority 검증)
  - map      : bpftool map dump/update 로 카운터·설정 조작

왜 bpftool CLI 인가: 별도 C 로더나 python 바인딩(bcc) 없이 표준 도구만으로
재현 가능하고, CI(ubuntu-24.04 러너)에서도 그대로 돈다.

제약: test_run 은 ctx_in 의 vlan_present/vlan_tci 설정을 허용하지 않으므로
(net/bpf/test_run.c convert___skb_to_skb) HW-accel VLAN 메타데이터 경로는
여기서 검증하지 못한다 — 인라인 802.1Q 태그로만 검증한다.
"""
from __future__ import annotations

import json
import os
import shutil
import struct
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
BUILD_DIR = Path(os.environ.get("TSN_BPF_BUILD", HERE.parent / "build"))
BPFTOOL = os.environ.get("BPFTOOL", shutil.which("bpftool") or "bpftool")

# ── ts_common.h 와 동일해야 하는 상수 ─────────────────────────────────────
TS_DEFAULT_UDP_PORT = 6000
TS_DEFAULT_PRIORITY = 6
TS_DEFAULT_DSCP = 46
TS_VLAN_PCP_MIN = 5
AVTP_ETHERTYPE = 0x22F0
TS_CFG_MARK_DSCP = 1 << 0
TS_CFG_DISABLE_UDP_DEFAULT = 1 << 1
CNT = {"NORMAL": 0, "TS_AVTP": 1, "TS_PCP": 2, "TS_UDP": 3, "DSCP_MARKED": 4, "PARSE_SHORT": 5}

TC_ACT_UNSPEC = -1
TC_ACT_OK = 0

# struct __sk_buff 오프셋 (include/uapi/linux/bpf.h)
SKB_PRIORITY_OFF = 32
SKB_CTX_SIZE = 192          # v6.x 크기. 5.15(184) 에서는 꼬리가 0 이면 허용됨.


# ── 패킷 빌더 ───────────────────────────────────────────────────────────────
DST_MAC = bytes.fromhex("aabbccddeeff")
SRC_MAC = bytes.fromhex("112233445566")


def ip_checksum(hdr: bytes) -> int:
    if len(hdr) % 2:
        hdr += b"\x00"
    s = sum(struct.unpack("!%dH" % (len(hdr) // 2), hdr))
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


def eth(ethertype: int, payload: bytes, dst=DST_MAC, src=SRC_MAC) -> bytes:
    return dst + src + struct.pack("!H", ethertype) + payload


def vlan(pcp: int, vid: int, inner_ethertype: int, payload: bytes, tpid: int = 0x8100) -> bytes:
    """802.1Q(0x8100) / 802.1ad(0x88A8) 태그. 반환값은 TCI + inner ethertype + payload
    (바깥 이더넷 헤더의 ethertype 자리에 tpid 를 넣어 eth() 로 감싼다)."""
    tci = (pcp << 13) | (vid & 0xFFF)
    return struct.pack("!HH", tci, inner_ethertype) + payload


def ipv4(proto: int, payload: bytes, tos: int = 0, options: bytes = b"",
         src="10.0.0.1", dst="10.0.0.2", ttl: int = 64) -> bytes:
    assert len(options) % 4 == 0
    ihl = 5 + len(options) // 4
    total = ihl * 4 + len(payload)
    hdr = struct.pack("!BBHHHBBH4s4s", (4 << 4) | ihl, tos, total, 0x1234, 0, ttl, proto, 0,
                      bytes(map(int, src.split("."))), bytes(map(int, dst.split(".")))) + options
    csum = ip_checksum(hdr)
    hdr = hdr[:10] + struct.pack("!H", csum) + hdr[12:]
    return hdr + payload


def ipv6(next_header: int, payload: bytes) -> bytes:
    return struct.pack("!IHBB", 6 << 28, len(payload), next_header, 64) + bytes(16) + bytes(15) + b"\x01" + payload


def udp(dport: int, payload: bytes = b"\x00" * 116, sport: int = 12345) -> bytes:
    return struct.pack("!HHHH", sport, dport, 8 + len(payload), 0) + payload


def tcp(dport: int, payload: bytes = b"", sport: int = 12345) -> bytes:
    return struct.pack("!HHIIBBHHH", sport, dport, 1, 0, 5 << 4, 0x02, 65535, 0, 0) + payload


def udp_frame(dport: int, **ip_kw) -> bytes:
    return eth(0x0800, ipv4(17, udp(dport), **ip_kw))


def parse_ipv4_tos_and_csum_ok(frame: bytes, ip_off: int = 14) -> tuple[int, bool]:
    """(TOS 바이트, 헤더 체크섬이 올바른지)"""
    ihl = (frame[ip_off] & 0xF) * 4
    hdr = frame[ip_off:ip_off + ihl]
    return hdr[1], ip_checksum(hdr) == 0


# ── bpftool 래퍼 ────────────────────────────────────────────────────────────
def _run(args: list[str], check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(args, capture_output=True, text=True, check=check)


def bpftool_available() -> bool:
    try:
        return _run([BPFTOOL, "version"], check=False).returncode == 0
    except FileNotFoundError:
        return False


def is_root() -> bool:
    return hasattr(os, "geteuid") and os.geteuid() == 0


@dataclass
class RunResult:
    retval: int
    data_out: bytes
    ctx_out: bytes

    @property
    def priority(self) -> int:
        return struct.unpack_from("<I", self.ctx_out, SKB_PRIORITY_OFF)[0]


class LoadedProg:
    """bpftool prog load 로 pin 한 프로그램 하나 + 그 map 들."""

    def __init__(self, obj_name: str, pin_name: str | None = None):
        self.obj = BUILD_DIR / f"{obj_name}.bpf.o"
        if not self.obj.exists():
            raise FileNotFoundError(f"{self.obj} 없음 — make -C step6-ebpf 먼저")
        self.pin = f"/sys/fs/bpf/tsn_test_{pin_name or obj_name}_{os.getpid()}"
        self.tmp = Path(tempfile.mkdtemp(prefix="tsn-bpf-"))
        if os.path.exists(self.pin):
            os.unlink(self.pin)
        _run([BPFTOOL, "prog", "load", str(self.obj), self.pin, "type", "tc"])
        info = json.loads(_run([BPFTOOL, "-j", "prog", "show", "pinned", self.pin]).stdout)
        self.map_ids: dict[str, int] = {}
        for mid in info.get("map_ids", []):
            m = json.loads(_run([BPFTOOL, "-j", "map", "show", "id", str(mid)]).stdout)
            self.map_ids[m["name"]] = mid

    def close(self):
        try:
            os.unlink(self.pin)
        except FileNotFoundError:
            pass
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- maps --
    def map_dump(self, name: str) -> list:
        return json.loads(_run([BPFTOOL, "-j", "map", "dump", "id", str(self.map_ids[name])]).stdout)

    @staticmethod
    def _bytes_to_int(v) -> int:
        """bpftool -j 는 raw 값을 ["0x00","0x01",...] (little-endian 바이트 배열) 로 준다."""
        if isinstance(v, int):
            return v
        if isinstance(v, list):
            return int.from_bytes(bytes(int(b, 16) for b in v), "little")
        return int(v)

    def percpu_sum(self, name: str) -> dict[int, int]:
        """PERCPU/일반 ARRAY map 을 {key: 전체 CPU 합} 으로.

        BTF 가 있으면 'formatted' 에 해석된 값이 오고, 없으면 raw 바이트 배열만 온다 —
        둘 다 처리한다.
        """
        out: dict[int, int] = {}
        for e in self.map_dump(name):
            fmt = e.get("formatted")
            if fmt is not None:
                key = fmt["key"]
                vals = fmt.get("values") or [{"value": fmt.get("value", 0)}]
            else:
                key = self._bytes_to_int(e["key"])
                vals = e.get("values") or [{"value": e.get("value", 0)}]
            out[int(key)] = sum(self._bytes_to_int(v["value"]) for v in vals)
        return out

    def counters(self) -> dict[str, int]:
        raw = self.percpu_sum("ts_counters")
        return {k: raw.get(i, 0) for k, i in CNT.items()}

    def map_update(self, name: str, key: bytes, value: bytes):
        _run([BPFTOOL, "map", "update", "id", str(self.map_ids[name]),
              "key", "hex", *[f"{b:02x}" for b in key],
              "value", "hex", *[f"{b:02x}" for b in value]])

    def set_config(self, priority: int = 0, dscp: int = 0, flags: int = 0):
        self.map_update("ts_config", struct.pack("<I", 0), struct.pack("<IIII", priority, dscp, flags, 0))

    def add_ts_port(self, port: int):
        self.map_update("ts_udp_ports", struct.pack("<H", port), b"\x01")

    # -- run --
    def run(self, frame: bytes, ctx_priority: int = 0, repeat: int = 1) -> RunResult:
        din, dout = self.tmp / "data_in", self.tmp / "data_out"
        cin, cout = self.tmp / "ctx_in", self.tmp / "ctx_out"
        din.write_bytes(frame)
        ctx = bytearray(SKB_CTX_SIZE)
        struct.pack_into("<I", ctx, SKB_PRIORITY_OFF, ctx_priority)
        cin.write_bytes(bytes(ctx))
        for f in (dout, cout):
            if f.exists():
                f.unlink()
        res = _run([BPFTOOL, "-j", "prog", "run", "pinned", self.pin,
                    "data_in", str(din), "data_out", str(dout),
                    "ctx_in", str(cin), "ctx_out", str(cout), "repeat", str(repeat)])
        j = json.loads(res.stdout)
        rv = j.get("return_value")
        if rv is None:
            rv = j.get("retval")
        rv = int(rv)
        if rv >= 1 << 31:          # bpftool 은 u32 로 출력 → TC_ACT_UNSPEC(-1) 은 4294967295
            rv -= 1 << 32
        return RunResult(rv, dout.read_bytes(), cout.read_bytes())
