# The brief

The original request, kept verbatim because the labs answer it and drift
is easy once the work starts.

> You are going to act as my hands-on networking coach and lab designer. Before writing any plan, inspect my environment, then build a practical lab workbook adapted to it.
>
> ## Git workflow (important)
> - I already created a branch from `main` called `feature/create-network-workbook`. Work ONLY on this branch.
> - First, run `git branch --show-current` and `git status` to confirm you are on `feature/create-network-workbook`. If you are not, tell me and ask before switching. Never commit to `main`.
> - Commit your work in small, logical commits (for example, one commit per lab or per phase) with clear messages.
> - Do NOT push, open PRs, merge or rebase without asking me first.
>
> ## Where the work lives (hard rule)
> - ALL the work produced on this branch for this workbook (labs, manifests, scripts, configs, cheatsheets, playbooks, assessments, notes, diagrams) must live inside a single dedicated folder: `workbooks/k8s_networking_workbook/`.
> - The top-level `workbooks/` folder is the parent for workbooks in this repo. If it doesn't exist, create it. If it already exists, follow its existing conventions and do not modify other workbooks.
> - Do not create or modify files outside `workbooks/k8s_networking_workbook/`, with one exception: if something outside is genuinely required (for example, an entry in a root README index), ask me first.
> - All relative paths inside labs and docs must be relative to that folder, so the workbook can be moved or copied as a whole.
>
> ## About me
> - DevOps / Platform / Cloud engineer, now focused on Kubernetes administration.
> - Learning style: 80% hands-on practice, 20% theory. NO books, minimal reading. Every concept should be learned by building, breaking and debugging something.
> - Language: write all lab content in English. Keep explanations short and direct.
>
> ## Timeline and end goal (hard constraints)
> - The whole program must fit in a MAXIMUM of 6 months. Do not design anything that requires more. If my available hours per week make 6 months unrealistic for the full scope, tell me and propose what to cut or compress, instead of silently extending the timeline.
> - Build a week-by-week schedule (26 weeks max) in the workbook `README.md`, with a time budget per week, and include a buffer week every month for catching up and revisiting weak spots.
> - End goal: after these 6 months I want to be an extremely capable Kubernetes engineer, with very strong networking fundamentals and the ability to troubleshoot Kubernetes and Linux networking problems quickly and methodically (DNS, CNI, kube-proxy/services, NetworkPolicies, MTU, conntrack, ingress/gateway, BGP, cross-node and external connectivity).
> - Prioritize by real-world impact: spend the most time on what causes real production incidents in Kubernetes networking, and less on exotic or purely enterprise topics. Where the scope is too big for 6 months, favor depth on Linux networking + Kubernetes networking + troubleshooting over breadth on enterprise routing/switching.
> - Define measurable exit criteria for each phase and for the whole program (for example: "I can diagnose a pod-to-pod failure across nodes using only tcpdump, ip, conntrack and hubble in under 15 minutes", "I can rebuild a CNI-like setup with namespaces, bridge, NAT and routing from scratch"). Include a final assessment: a set of unseen break/fix scenarios that I must solve without help, with a self-scoring sheet.
>
> ## Scope and phases (fit all of this within the 6 months, suggested split to adjust after you know my weekly hours)
> - Phase 1 (CCNA fundamentals, roughly months 1-2, running in parallel with Phase 2 labs when possible): I am handling this myself with Jeremy's IT Lab free CCNA 200-301 course on YouTube (I'm not taking the exam). Course playlist, starting at Day 1 (Network Devices): https://www.youtube.com/watch?v=H8W9oMNSuwo&list=PLxbwE86jKRgMpuZuLBivzlM8s2Dk5lXBQ
>   DO NOT build this phase from scratch. Only create a lightweight companion: for each day/topic of the course (follow the playlist order), suggest 1-2 practical exercises (Packet Tracer, GNS3, EVE-NG or Containerlab, whichever fits best) plus Wireshark/tcpdump captures I can do to reinforce it. Use the playlist as the source of the day-by-day structure; if you can't access it, ask me to paste the video list instead of guessing. Since I'm not taking the exam, tell me which course days I can skim or skip given the 6-month limit (for example, deep wireless, some Cisco-specific device management) and which ones are essential (IP addressing/subnetting, switching/VLANs/STP basics, routing, OSPF basics, NAT, ACLs, DNS/DHCP, troubleshooting).
> - Phase 2 (Linux networking deep dive, roughly months 2-3): network namespaces, veth pairs, bridges, routing, iproute2, iptables/nftables, conntrack, NAT, VXLAN, tcpdump, eBPF basics. Build by hand what Docker/CNI does.
> - Phase 3 (Kubernetes networking, roughly months 3-5): CNI internals (Cilium prioritized, plus Calico for comparison), kube-proxy modes (iptables/IPVS/eBPF replacement), CoreDNS and DNS troubleshooting, Services, Ingress, Gateway API, NetworkPolicies, service mesh basics, Hubble/observability, MTU and conntrack issues.
> - Phase 4 (BGP, cloud and enterprise, roughly months 5-6): BGP with FRR, Calico/Cilium BGP, MetalLB, hybrid connectivity concepts, cloud networking patterns (VPC design, peering, transit, private endpoints, hybrid DNS) simulated locally where possible, load balancing L4/L7, TLS, HTTP/2, QUIC, network observability.
> - The last 2-3 weeks of month 6 are reserved for the final assessment, consolidating my cheatsheet/playbook, and a final capstone.
>
> ## Step 1: Discover my environment (READ-ONLY, change nothing yet)
> Inspect and summarize:
> - Current git branch and repo structure, including whether `workbooks/` already exists and what conventions it follows (confirm the branch as described above)
> - Kubernetes version, distribution, node count/roles, OS and kernel versions on the nodes
> - Current CNI and its mode (overlay/routed, kube-proxy mode, eBPF yes/no), CoreDNS config, ingress controller, any service mesh, any LoadBalancer implementation
> - Existing namespaces, CNI/network policies, anything that looks production-critical or shared
> - Whether I have privileged access to nodes (SSH/sudo), and which tools are available (tcpdump, ip, nft, bpftool, etc.)
> - Whether the cluster can safely be broken, or whether I need a separate disposable cluster (kind, k3d, Minikube or VMs) for risky labs like replacing the CNI
> Then tell me what you found, list assumptions, and ask me any blocking questions (for example, hours per week available, whether I can run a second disposable cluster, whether the nodes are VMs or bare metal).
>
> ## Step 2: Design the workbook
> After my answers, create the following structure inside `workbooks/k8s_networking_workbook/` (on the feature branch):
> - `README.md`: roadmap, week-by-week schedule (max 26 weeks), exit criteria per phase, and a progress tracker (checkbox per lab)
> - One folder per phase containing numbered labs
> - `cheatsheet.md`: commands and debugging flows that grows as I progress
> - `troubleshooting-playbook.md`: a layer-by-layer debugging checklist for Kubernetes networking incidents
> - `final-assessment/`: unseen break/fix scenarios plus a self-scoring sheet
>
> Every lab must follow this template:
> 1. Objective (one sentence) and estimated time
> 2. Prerequisites
> 3. Hands-on steps with exact commands and manifests
> 4. Verification: what output I should see, and how to prove it works (tcpdump, curl, hubble, conntrack -L, etc.)
> 5. Break/fix challenge: a failure you inject (bad MTU, broken DNS, wrong policy, missing route, conntrack exhaustion, etc.) that I must diagnose WITHOUT you giving me the answer. Put the solution in a collapsed section or a separate file.
> 6. Cleanup commands
> 7. "What I should be able to explain after this" (3 bullet points, my 20% theory)
>
> ## Safety rules
> - Isolate every lab in its own namespace (prefix `lab-`) or its own namespace/VM/kind cluster. Never touch workloads outside those without explicit confirmation.
> - Anything that modifies nodes, the CNI, kube-proxy, sysctls, iptables on nodes or cluster-wide settings: mark clearly as RISKY, explain the blast radius and the rollback, and ask for my confirmation before running it. Prefer doing risky labs on a disposable cluster.
> - Do not delete resources you did not create.
> - Never run anything automatically from the labs: you write them, I execute them (unless I ask you to run a specific step).
>
> ## Final deliverable and working mode
> - Start with Step 1 and report back before creating files.
> - Then generate the workbook phase by phase, starting with Phase 2 (Phase 1 companion last, since I'm doing the course in parallel). Commit after each phase on `feature/create-network-workbook`, only touching files inside `workbooks/k8s_networking_workbook/`.
> - Size each phase to the time it gets in the schedule, not to a fixed number of labs: as a guideline 8-12 labs for Phases 2 and 3, 5-8 for Phase 4, ordered by increasing difficulty, each phase ending with a capstone project (for example Phase 2: rebuild a mini-CNI with namespaces, bridge, NAT and routing between two hosts; Phase 3: a full Cilium lab with policies, Hubble, Gateway API and a DNS failure investigation; Phase 4: BGP peering between FRR and the cluster advertising Service IPs).
> - Keep a light "reference-level" track (inside the same folder): ideas for blog posts, runbooks and open source contributions (Cilium, Calico, CoreDNS) that I can do along the way, without letting it take time from the core labs.

## Answers and decisions (2026-10-25)

| Question | Decision |
|---|---|
| Hours per week | **8–10 h.** The full scope fits in 26 weeks; Phase 4 is the first thing compressed if behind. |
| The study block's ground rule forbids video courses | Accepted as an exception for the CCNA course — then superseded: **the videos are not watched at all.** Phase 1 became self-contained drills keyed by topic. |
| CCNA playlist | Only Days 1–13 were available. Drills for those days carry the day number; later topics are named, not numbered. |
| Where risky labs run | Phase 2 and FRR topologies on throwaway **netlab** VMs (Containerlab inside them, never on the WSL host — its iptables keep the Multipass network alive). Cilium, kube-proxy modes and OVN-Kubernetes on **kind**. Calico, CoreDNS, MTU, conntrack and Gateway labs on **k8slab**, 2 workers, menu option 0. |
| OpenShift networking | **Added**: two OVN-Kubernetes labs in Phase 3, plus anything else that adds value. |
| Lab format | The seven sections above; every break/fix uses the four beats (hypothesis → tool → expected → what would have told me sooner); every phase ends in a runbook. |
| Packet Tracer vs Containerlab | Containerlab with Linux and FRR nodes. No Cisco IOS. |
| Final assessment | Payloads encoded so they stay unseen until solved. |
