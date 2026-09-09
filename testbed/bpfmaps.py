#!/usr/bin/env python3
"""bpfmaps.py — 테스트베드용 bpftool map 헬퍼 (pinned map 읽기/쓰기)

사용:
  bpfmaps.py dump-percpu <pinned-map>            → {"0": 12, "1": 3, ...} JSON
  bpfmaps.py set-ts-config <pinned-map> <priority> <dscp> <flags>
  bpfmaps.py counters <pinned-ts_counters>       → 이름 붙은 카운터 JSON
"""
import json
import struct
import subprocess
import sys

CNT_NAMES = ["normal", "ts_avtp", "ts_pcp", "ts_udp", "dscp_marked", "parse_short"]


def _to_int(v):
    if isinstance(v, int):
        return v
    if isinstance(v, list):
        return int.from_bytes(bytes(int(b, 16) for b in v), "little")
    return int(v)


def dump_percpu(pinned):
    out = subprocess.run(["bpftool", "-j", "map", "dump", "pinned", pinned],
                         capture_output=True, text=True, check=True).stdout
    res = {}
    for e in json.loads(out):
        fmt = e.get("formatted")
        if fmt is not None:
            key = fmt["key"]
            vals = fmt.get("values") or [{"value": fmt.get("value", 0)}]
        else:
            key = _to_int(e["key"])
            vals = e.get("values") or [{"value": e.get("value", 0)}]
        res[str(int(key))] = sum(_to_int(v["value"]) for v in vals)
    return res


def set_ts_config(pinned, priority, dscp, flags):
    key = struct.pack("<I", 0)
    val = struct.pack("<IIII", int(priority), int(dscp), int(flags), 0)
    subprocess.run(["bpftool", "map", "update", "pinned", pinned,
                    "key", "hex", *[f"{b:02x}" for b in key],
                    "value", "hex", *[f"{b:02x}" for b in val]], check=True)


def main(argv):
    cmd = argv[1]
    if cmd == "dump-percpu":
        print(json.dumps(dump_percpu(argv[2])))
    elif cmd == "counters":
        raw = dump_percpu(argv[2])
        print(json.dumps({name: raw.get(str(i), 0) for i, name in enumerate(CNT_NAMES)}))
    elif cmd == "set-ts-config":
        set_ts_config(argv[2], argv[3], argv[4], argv[5])
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
