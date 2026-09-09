# 루트 Makefile — 자주 쓰는 진입점 모음 (Linux / WSL2)
#
#   make bpf            eBPF 프로그램 + tcx 로더 빌드           (bpf/)
#   make test           BPF 단위 테스트 + 분석 패키지 테스트      (root 필요: sudo make test)
#   make test-tcx       tcx 체인 통합 테스트 (kernel >= 6.6, root)
#   make testbed        netns 테스트베드 실험 (root)             → testbed/runs/local
#   make report         테스트베드 결과 요약/그래프              → testbed/runs/local/report
#   make lint           shellcheck / ruff
#   make clean
#
# Kubernetes 클러스터 실험은 scripts/experiment.sh (docs/RUNBOOK.md 참조).

PYTHON ?= python3
RUNS   ?= 3
RATE   ?= 20
FLOOD  ?= 30
OUT    ?= testbed/runs/local

.PHONY: bpf tools test test-bpf test-tcx test-analysis testbed report lint clean

bpf:
	$(MAKE) -C bpf
	$(MAKE) -C bpf tools

tools: bpf

test: test-bpf test-analysis

test-bpf: bpf
	$(MAKE) -C bpf test

test-tcx: bpf
	$(MAKE) -C bpf test-tcx

test-analysis:
	cd analysis && $(PYTHON) -m pytest -q

testbed: bpf
	bash testbed/run.sh --runs $(RUNS) --rate-mbps $(RATE) --flood-mbps $(FLOOD) --out $(OUT)

report:
	$(PYTHON) -m pip install -q -e ./analysis
	tsn-analysis summary $(OUT) --baseline fifo --markdown $(OUT)/report/summary.md --json $(OUT)/report/summary.json
	tsn-analysis plot $(OUT) --out $(OUT)/report

lint:
	git ls-files '*.sh' | xargs shellcheck -S warning -x
	ruff check .

clean:
	$(MAKE) -C bpf clean
	rm -rf analysis/.pytest_cache analysis/build analysis/*.egg-info
