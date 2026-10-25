#!/usr/bin/env python3
"""Rebuild break.sh files from the faults recorded in the workbook.

Source of each fault:
  phase labs        <lab>/solution.md   the bash block between <!--FAULT--> and <!--/FAULT-->
  final scenarios   <scenario>/solution.b64   (base64 Markdown; the bash block
                    under "## What was injected")
The "# Run:" line is kept from the existing break.sh.

Usage (from anywhere):
  python3 setup/build-breaks.py                 # rebuild every break.sh
  python3 setup/build-breaks.py phase3-k8s-networking/05-network-policy
  python3 setup/build-breaks.py --check         # exit 1 if any break.sh is stale

Changing a fault:
  phase lab        edit the FAULT block in solution.md, then run this script.
  final scenario   base64 -d solution.b64 > /tmp/s.md; edit the
                   "## What was injected" block; base64 /tmp/s.md > solution.b64;
                   rm /tmp/s.md; then run this script.
"""
import base64
import pathlib
import re
import sys

WB = pathlib.Path(__file__).resolve().parent.parent

TEMPLATE = '''#!/usr/bin/env bash
# {title} — break/fix injector.
# Run: {where}
# Rebuilds the lab's starting state, injects one fault, prints the ticket.
# The payload is base64 so a glance at this file does not spoil the
# challenge. {answer}
set -euo pipefail
export LAB_DIR="$(cd "$(dirname "${{BASH_SOURCE[0]}}")" && pwd)"
export PHASE_DIR="$(cd "$LAB_DIR/{up}" && pwd)"
export WB_DIR="$(cd "$PHASE_DIR/.." && pwd)"
P='{payload}'
base64 -d <<<"$P" | bash -s -- "$@"
'''

PHASE_FAULT = re.compile(r'<!--FAULT-->\n```bash\n(.*?)\n```\n<!--/FAULT-->', re.S)
FINAL_FAULT = re.compile(r'\n## What was injected\n\n```bash\n(.*?)\n```\n\Z', re.S)


def fault_body(lab: pathlib.Path) -> str:
    if (lab / 'solution.b64').exists():
        md = base64.b64decode((lab / 'solution.b64').read_text()).decode()
        m = FINAL_FAULT.search(md)
        src = 'solution.b64'
    else:
        md = (lab / 'solution.md').read_text()
        m = PHASE_FAULT.search(md)
        src = 'solution.md'
    if not m:
        sys.exit(f'{lab.relative_to(WB)}/{src}: fault block not found')
    return m.group(1)


def render(lab: pathlib.Path) -> str:
    rel = lab.relative_to(WB)
    old = (lab / 'break.sh').read_text()
    where = re.search(r'^# Run: (.*)$', old, re.M)
    if not where:
        sys.exit(f'{rel}/break.sh: no "# Run:" line')
    final = rel.parts[0] == 'final-assessment'
    if final:
        title = f'Final assessment {rel.name} (unseen scenario: no hints in this file)'
    else:
        title = f'Lab {rel.parts[0][5]}.{rel.name[:2]}'
    payload = base64.b64encode(('set -euo pipefail\n' + fault_body(lab) + '\n').encode()).decode()
    answer = ('The fix: ../../reveal.sh ' + rel.name + ', only once it is scored.' if final
              else 'The plaintext and the fix are in solution.md — open it last.')
    return TEMPLATE.format(title=title, where=where.group(1), payload=payload, answer=answer,
                           up='../..' if final else '..')


def main(argv):
    check = '--check' in argv
    targets = [a for a in argv if a != '--check']
    labs = [(WB / t).resolve() for t in targets] or sorted(p.parent for p in WB.rglob('break.sh'))
    stale = 0
    for lab in labs:
        new = render(lab)
        out = lab / 'break.sh'
        if out.read_text() == new:
            continue
        stale += 1
        if check:
            print('stale', out.relative_to(WB))
        else:
            out.write_text(new)
            out.chmod(0o755)
            print('built', out.relative_to(WB))
    print(f'{len(labs)} break.sh checked, {stale} {"stale" if check else "rebuilt"}')
    return 1 if check and stale else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
