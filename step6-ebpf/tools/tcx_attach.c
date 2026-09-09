// SPDX-License-Identifier: GPL-2.0
/*
 * tcx_attach.c — tcx(BPF_TCX_EGRESS/INGRESS) 링크 기반 attach 도구 (libbpf >= 1.3, kernel >= 6.6)
 *
 * 왜 tc(8) 대신 이 도구인가:
 *   iproute2 `tc filter add ... bpf` 는 legacy clsact 에만 붙는다. kernel >= 6.6 에서
 *   Cilium 은 tcx 로 붙고, Cilium 프로그램이 TC_ACT_OK 를 반환하면 legacy clsact 필터는
 *   실행조차 되지 않는다(net/core/dev.c sch_handle_egress). 우리 분류기가 반드시 실행되려면
 *   tcx 체인 **앞(BPF_F_BEFORE)** 에 붙어야 하고, 그 순서 제어는 bpf(2) 의
 *   BPF_LINK_CREATE + relative flags 로만 가능하다. bpftool 도 순서 플래그를 노출하지 않는다.
 *
 * 사용법:
 *   tcx_attach attach <ifname> <obj.bpf.o> <pin-path> [egress|ingress] [before|after]
 *   tcx_attach detach <pin-path>
 *   tcx_attach query  <ifname> [egress|ingress]
 *
 * 링크를 bpffs 에 pin 하므로 프로세스가 종료돼도 attach 가 유지되고,
 * detach 는 pin 파일을 지우는 것으로 끝난다 (Cilium 이 재시작해도 우리 링크는 남는다).
 */
#include <errno.h>
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>

static void usage(const char *argv0)
{
	fprintf(stderr,
		"usage:\n"
		"  %s attach <ifname> <obj.bpf.o> <pin-path> [egress|ingress] [before|after]\n"
		"  %s detach <pin-path>\n"
		"  %s query  <ifname> [egress|ingress]\n", argv0, argv0, argv0);
}

static enum bpf_attach_type parse_dir(const char *s)
{
	if (!s || !strcmp(s, "egress"))
		return BPF_TCX_EGRESS;
	if (!strcmp(s, "ingress"))
		return BPF_TCX_INGRESS;
	fprintf(stderr, "unknown direction: %s\n", s);
	exit(2);
}

static int do_attach(int argc, char **argv)
{
	const char *ifname = argv[2], *objpath = argv[3], *pin = argv[4];
	enum bpf_attach_type dir = parse_dir(argc > 5 ? argv[5] : NULL);
	int before = !(argc > 6 && !strcmp(argv[6], "after"));
	int ifindex = if_nametoindex(ifname);
	struct bpf_object *obj;
	struct bpf_program *prog;
	struct bpf_link *link;
	LIBBPF_OPTS(bpf_tcx_opts, opts);

	if (!ifindex) {
		fprintf(stderr, "no such interface: %s\n", ifname);
		return 1;
	}
	obj = bpf_object__open_file(objpath, NULL);
	if (!obj) {
		fprintf(stderr, "open %s: %s\n", objpath, strerror(errno));
		return 1;
	}
	if (bpf_object__load(obj)) {
		fprintf(stderr, "load %s failed (verifier?): %s\n", objpath, strerror(errno));
		return 1;
	}
	prog = bpf_object__next_program(obj, NULL);
	if (!prog) {
		fprintf(stderr, "no program in %s\n", objpath);
		return 1;
	}
	bpf_program__set_expected_attach_type(prog, dir);

	/* relative_fd/id = 0 + BPF_F_BEFORE → 체인 맨 앞, BPF_F_AFTER → 맨 뒤 */
	opts.flags = before ? BPF_F_BEFORE : BPF_F_AFTER;
	link = bpf_program__attach_tcx(prog, ifindex, &opts);
	if (!link) {
		fprintf(stderr, "attach_tcx(%s, %s) failed: %s (kernel >= 6.6 필요)\n",
			ifname, before ? "before" : "after", strerror(errno));
		return 1;
	}
	if (bpf_link__pin(link, pin)) {
		fprintf(stderr, "pin %s failed: %s\n", pin, strerror(errno));
		bpf_link__destroy(link);
		return 1;
	}
	printf("attached %s (%s) to %s %s at %s of chain, pinned at %s\n",
	       bpf_program__name(prog), objpath, ifname,
	       dir == BPF_TCX_EGRESS ? "egress" : "ingress",
	       before ? "head" : "tail", pin);
	/* link fd 는 pin 에 의해 살아남는다 — destroy 하지 말고 그냥 종료 */
	return 0;
}

static int do_detach(const char *pin)
{
	int fd = bpf_obj_get(pin);

	if (fd < 0) {
		fprintf(stderr, "open pin %s: %s\n", pin, strerror(errno));
		return 1;
	}
	if (bpf_link_detach(fd))
		fprintf(stderr, "bpf_link_detach: %s\n", strerror(errno));
	close(fd);
	if (unlink(pin)) {
		fprintf(stderr, "unlink %s: %s\n", pin, strerror(errno));
		return 1;
	}
	printf("detached %s\n", pin);
	return 0;
}

static int do_query(int argc, char **argv)
{
	const char *ifname = argv[2];
	enum bpf_attach_type dir = parse_dir(argc > 3 ? argv[3] : NULL);
	int ifindex = if_nametoindex(ifname);
	__u32 prog_ids[64] = {}, link_ids[64] = {};
	LIBBPF_OPTS(bpf_prog_query_opts, q, .prog_ids = prog_ids, .link_ids = link_ids,
		    .prog_cnt = 64);

	if (!ifindex) {
		fprintf(stderr, "no such interface: %s\n", ifname);
		return 1;
	}
	if (bpf_prog_query_opts(ifindex, dir, &q)) {
		fprintf(stderr, "query failed: %s\n", strerror(errno));
		return 1;
	}
	printf("%s %s tcx chain: %u program(s)\n", ifname,
	       dir == BPF_TCX_EGRESS ? "egress" : "ingress", q.prog_cnt);
	for (__u32 i = 0; i < q.prog_cnt; i++) {
		struct bpf_prog_info info = {};
		__u32 len = sizeof(info);
		int fd = bpf_prog_get_fd_by_id(prog_ids[i]);

		if (fd < 0 || bpf_obj_get_info_by_fd(fd, &info, &len)) {
			printf("  [%u] prog id %u (info unavailable)\n", i, prog_ids[i]);
			continue;
		}
		printf("  [%u] prog id %u  name %-16s link id %u\n", i, prog_ids[i], info.name,
		       link_ids[i]);
		close(fd);
	}
	return 0;
}

int main(int argc, char **argv)
{
	libbpf_set_print(NULL);
	if (argc >= 5 && !strcmp(argv[1], "attach"))
		return do_attach(argc, argv);
	if (argc == 3 && !strcmp(argv[1], "detach"))
		return do_detach(argv[2]);
	if (argc >= 3 && !strcmp(argv[1], "query"))
		return do_query(argc, argv);
	usage(argv[0]);
	return 2;
}
