# make bpf        eBPF 오브젝트 + tcx 로더 빌드
# make test       BPF 단위 테스트(root) + 분석 패키지 테스트
# make test-tcx   tcx 체인 테스트 (root, kernel >= 6.6)
# make testbed    netns 테스트베드 실행 (root) -> testbed/runs/local
# make report     $(OUT) 의 summary.md 와 그래프 생성
# make lint       shellcheck + ruff

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
	tsn-analysis summary $(OUT) --baseline fifo --markdown $(OUT)/report/summary.md
	tsn-analysis plot $(OUT) --out $(OUT)/report

lint:
	git ls-files '*.sh' | xargs shellcheck -S warning -x
	ruff check .

clean:
	$(MAKE) -C bpf clean
	rm -rf analysis/.pytest_cache analysis/build analysis/*.egg-info
