"""test_ts_classifier.py — ts_classifier.bpf.o 단위 테스트 (BPF_PROG_TEST_RUN)

실행: sudo make -C bpf test   (root + bpftool + 빌드된 build/*.bpf.o 필요)
"""
from __future__ import annotations

import bpf_harness as h
import pytest

pytestmark = pytest.mark.skipif(
    not (h.is_root() and h.bpftool_available()),
    reason="root 권한과 bpftool 이 필요합니다 (sudo make test)",
)


@pytest.fixture(scope="module")
def prog():
    p = h.LoadedProg("ts_classifier")
    yield p
    p.close()


@pytest.fixture(autouse=True)
def reset_config(prog):
    """각 테스트를 기본 설정(모두 0 = 컴파일 타임 기본값)에서 시작."""
    prog.set_config(0, 0, 0)
    yield


def delta(prog, before, after):
    return {k: after[k] - before[k] for k in before}


# ── 분류 기준 ─────────────────────────────────────────────────────────────
def test_udp_default_port_is_ts(prog):
    c0 = prog.counters()
    r = prog.run(h.udp_frame(h.TS_DEFAULT_UDP_PORT))
    assert r.retval == h.TC_ACT_UNSPEC, "TCX_NEXT 를 반환해야 뒤의 Cilium 프로그램이 실행된다"
    assert r.priority == h.TS_DEFAULT_PRIORITY
    d = delta(prog, c0, prog.counters())
    assert d["TS_UDP"] == 1 and d["NORMAL"] == 0


def test_other_udp_port_untouched_keeps_existing_priority(prog):
    """비-TS 패킷의 priority 는 절대 덮어쓰지 않는다 (ADR-0004)."""
    c0 = prog.counters()
    r = prog.run(h.udp_frame(5000), ctx_priority=3)
    assert r.retval == h.TC_ACT_UNSPEC
    assert r.priority == 3
    assert delta(prog, c0, prog.counters())["NORMAL"] == 1


def test_non_ts_never_modifies_packet_bytes(prog):
    frame = h.udp_frame(5000, tos=0x28)
    r = prog.run(frame)
    assert r.data_out == frame


def test_tcp_on_ts_port_is_normal(prog):
    r = prog.run(h.eth(0x0800, h.ipv4(6, h.tcp(h.TS_DEFAULT_UDP_PORT))), ctx_priority=0)
    assert r.priority == 0


def test_vlan_pcp5_is_ts(prog):
    frame = h.eth(0x8100, h.vlan(5, 100, 0x0800, h.ipv4(17, h.udp(5000))))
    c0 = prog.counters()
    r = prog.run(frame)
    assert r.priority == h.TS_DEFAULT_PRIORITY
    assert delta(prog, c0, prog.counters())["TS_PCP"] == 1


def test_vlan_pcp1_is_normal(prog):
    frame = h.eth(0x8100, h.vlan(1, 100, 0x0800, h.ipv4(17, h.udp(5000))))
    r = prog.run(frame)
    assert r.priority == 0


def test_vlan_pcp1_but_ts_port_is_ts_by_port(prog):
    frame = h.eth(0x8100, h.vlan(1, 100, 0x0800, h.ipv4(17, h.udp(h.TS_DEFAULT_UDP_PORT))))
    c0 = prog.counters()
    r = prog.run(frame)
    assert r.priority == h.TS_DEFAULT_PRIORITY
    assert delta(prog, c0, prog.counters())["TS_UDP"] == 1


def test_qinq_outer_pcp_decides(prog):
    # 802.1ad 외곽 PCP 5 / 내부 PCP 1 → TS ; 외곽 1 / 내부 7 → normal
    inner_lo = h.vlan(1, 10, 0x0800, h.ipv4(17, h.udp(5000)))
    outer_hi = h.eth(0x88A8, h.vlan(5, 200, 0x8100, inner_lo))
    assert prog.run(outer_hi).priority == h.TS_DEFAULT_PRIORITY

    inner_hi = h.vlan(7, 10, 0x0800, h.ipv4(17, h.udp(5000)))
    outer_lo = h.eth(0x88A8, h.vlan(1, 200, 0x8100, inner_hi))
    assert prog.run(outer_lo).priority == 0


def test_avtp_ethertype_is_ts(prog):
    c0 = prog.counters()
    r = prog.run(h.eth(h.AVTP_ETHERTYPE, b"\x00" * 60))
    assert r.priority == h.TS_DEFAULT_PRIORITY
    assert delta(prog, c0, prog.counters())["TS_AVTP"] == 1


def test_arp_is_normal(prog):
    r = prog.run(h.eth(0x0806, b"\x00" * 28), ctx_priority=2)
    assert r.priority == 2


def test_ipv6_udp_ts_port_is_normal_documented_limitation(prog):
    """IPv6 는 아직 분류하지 않는다 (docs/LIMITATIONS.md)."""
    r = prog.run(h.eth(0x86DD, h.ipv6(17, h.udp(h.TS_DEFAULT_UDP_PORT))))
    assert r.priority == 0


def test_ipv4_options_ihl6_is_parsed(prog):
    frame = h.eth(0x0800, h.ipv4(17, h.udp(h.TS_DEFAULT_UDP_PORT), options=b"\x01\x01\x01\x01"))
    r = prog.run(frame)
    assert r.priority == h.TS_DEFAULT_PRIORITY


def test_truncated_ipv4_header_is_safe(prog):
    c0 = prog.counters()
    r = prog.run(h.eth(0x0800, b"\x45\x00\x00\x1c\x00\x00"))   # 6 bytes of IP header only
    assert r.retval == h.TC_ACT_UNSPEC and r.priority == 0
    assert delta(prog, c0, prog.counters())["PARSE_SHORT"] == 1


def test_ipv4_first_fragment_is_normal(prog):
    """단편은 TS 로 보지 않는다 — 첫 단편(MF=1)에 UDP:6000 헤더가 있어도 마찬가지."""
    frame = h.eth(0x0800, h.ipv4(17, h.udp(h.TS_DEFAULT_UDP_PORT), frag_off=h.IP_MF))
    r = prog.run(frame, ctx_priority=0)
    assert r.priority == 0


def test_ipv4_later_fragment_with_port_like_bytes_is_normal(prog):
    """뒤 단편(offset>0)의 payload 첫 바이트가 우연히 포트 6000 처럼 보여도 분류하지 않는다."""
    fake_udp_looking_payload = b"\x30\x39\x17\x70" + b"\x00" * 60   # sport 12345, dport 6000
    frame = h.eth(0x0800, h.ipv4(17, fake_udp_looking_payload, frag_off=185))
    r = prog.run(frame, ctx_priority=0)
    assert r.priority == 0


def test_truncated_udp_header_is_normal(prog):
    ip = h.ipv4(17, b"\x30\x39\x17\x70")   # UDP header cut after dport
    r = prog.run(h.eth(0x0800, ip))
    assert r.priority == 0


# ── 런타임 설정 ───────────────────────────────────────────────────────────
def test_custom_priority_from_config(prog):
    prog.set_config(priority=5)
    assert prog.run(h.udp_frame(h.TS_DEFAULT_UDP_PORT)).priority == 5


def test_disable_default_port_flag(prog):
    prog.set_config(flags=h.TS_CFG_DISABLE_UDP_DEFAULT)
    assert prog.run(h.udp_frame(h.TS_DEFAULT_UDP_PORT)).priority == 0


def test_port_map_adds_ts_port(prog):
    prog.add_ts_port(5001)
    assert prog.run(h.udp_frame(5001)).priority == h.TS_DEFAULT_PRIORITY
    assert prog.run(h.udp_frame(5002)).priority == 0


# ── DSCP 마킹 ─────────────────────────────────────────────────────────────
def test_dscp_not_marked_without_flag(prog):
    frame = h.udp_frame(h.TS_DEFAULT_UDP_PORT, tos=0)
    r = prog.run(frame)
    assert r.priority == h.TS_DEFAULT_PRIORITY
    assert r.data_out == frame


def test_dscp_ef_marking_updates_checksum(prog):
    prog.set_config(flags=h.TS_CFG_MARK_DSCP)          # dscp=0 → 기본 EF(46)
    c0 = prog.counters()
    orig = h.udp_frame(h.TS_DEFAULT_UDP_PORT, tos=0)
    r = prog.run(orig)
    tos, csum_ok = h.parse_ipv4_tos_and_csum_ok(r.data_out)
    assert tos == h.TS_DEFAULT_DSCP << 2 == 0xB8
    assert csum_ok, "IPv4 헤더 체크섬이 증분 갱신되어야 한다"
    assert delta(prog, c0, prog.counters())["DSCP_MARKED"] == 1
    # TOS(오프셋 15)와 체크섬(24..25) 외의 바이트는 그대로여야 한다
    assert len(r.data_out) == len(orig)
    assert r.data_out[:15] == orig[:15]
    assert r.data_out[16:24] == orig[16:24]
    assert r.data_out[26:] == orig[26:]


def test_dscp_marking_preserves_ecn_bits(prog):
    prog.set_config(dscp=34, flags=h.TS_CFG_MARK_DSCP)   # AF41 = 34
    r = prog.run(h.udp_frame(h.TS_DEFAULT_UDP_PORT, tos=(10 << 2) | 0b10))
    tos, csum_ok = h.parse_ipv4_tos_and_csum_ok(r.data_out)
    assert tos == (34 << 2) | 0b10 and csum_ok


def test_dscp_marking_with_ip_options(prog):
    prog.set_config(flags=h.TS_CFG_MARK_DSCP)
    frame = h.eth(0x0800, h.ipv4(17, h.udp(h.TS_DEFAULT_UDP_PORT), options=b"\x01\x01\x01\x01", tos=0))
    r = prog.run(frame)
    tos, csum_ok = h.parse_ipv4_tos_and_csum_ok(r.data_out)
    assert tos == 0xB8 and csum_ok


def test_dscp_marking_on_vlan_tagged_ts(prog):
    prog.set_config(flags=h.TS_CFG_MARK_DSCP)
    frame = h.eth(0x8100, h.vlan(6, 100, 0x0800, h.ipv4(17, h.udp(5000), tos=0)))
    r = prog.run(frame)
    tos, csum_ok = h.parse_ipv4_tos_and_csum_ok(r.data_out, ip_off=18)
    assert r.priority == h.TS_DEFAULT_PRIORITY and tos == 0xB8 and csum_ok


def test_dscp_already_marked_is_noop(prog):
    prog.set_config(flags=h.TS_CFG_MARK_DSCP)
    frame = h.udp_frame(h.TS_DEFAULT_UDP_PORT, tos=0xB8)
    c0 = prog.counters()
    r = prog.run(frame)
    assert r.data_out == frame
    assert delta(prog, c0, prog.counters())["DSCP_MARKED"] == 0


# ── 성능 감 잡기 (회귀 방지용 상한) ──────────────────────────────────────
def test_repeat_run_is_cheap(prog):
    """repeat 로 커널 측 평균 실행 시간을 재 본다 — 수 μs 를 넘으면 뭔가 잘못된 것."""
    r = prog.run(h.udp_frame(h.TS_DEFAULT_UDP_PORT), repeat=10000)
    assert r.priority == h.TS_DEFAULT_PRIORITY
