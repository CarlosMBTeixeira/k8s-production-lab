// xdp_drop_icmp.c — lab 2.11. Drops IPv4 ICMP at XDP, passes everything else.
// Build: clang -O2 -g -target bpf -I/usr/include/$(uname -m)-linux-gnu -c xdp_drop_icmp.c -o xdp_drop_icmp.o
#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

SEC("xdp")
int xdp_drop_icmp(struct xdp_md *ctx)
{
    void *data     = (void *)(long)ctx->data;
    void *data_end = (void *)(long)ctx->data_end;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)          // the verifier insists on bounds checks
        return XDP_PASS;
    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return XDP_PASS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return XDP_PASS;

    return ip->protocol == IPPROTO_ICMP ? XDP_DROP : XDP_PASS;
}

char LICENSE[] SEC("license") = "GPL";
