"""Checks a release APK against the host surface Tachi extension DEX needs (U11).

Every class, method and field an extension's classes.dex references but does
not define must resolve, by its original name and signature, in the app's
DEX (after R8) or in the Android framework (android.*, java.*, javax.*,
dalvik.*, org.json, org.w3c, org.xml, which the app does not ship). Methods
and fields resolve through the superclass and interface chain.

usage: python -I check_keep_rules.py <dexdump> <release.apk> <extension.apk>... [--report out.txt]
"""

import re
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

FRAMEWORK = ('Landroid/', 'Ljava/', 'Ljavax/', 'Ldalvik/', 'Lorg/json/', 'Lorg/w3c/', 'Lorg/xml/', 'Lsun/', 'Llibcore/')
REF = re.compile(r'(L[^;\s]+;)\.([^:\s]+):(\S+)')


def dexes(apk: Path, out: Path) -> list[Path]:
    paths = []
    with zipfile.ZipFile(apk) as z:
        for name in z.namelist():
            if re.fullmatch(r'classes\d*\.dex', name):
                p = out / f'{apk.stem}-{name}'
                p.write_bytes(z.read(name))
                paths.append(p)
    return paths


def dump(dexdump: str, dex: Path, disassemble: bool) -> str:
    args = [dexdump] + (['-d'] if disassemble else []) + [str(dex)]
    return subprocess.run(args, capture_output=True, text=True, errors='replace', check=True).stdout


class Model:
    def __init__(self):
        self.classes = {}  # descriptor -> {super, interfaces, methods:set(name+proto), fields:set(name:type)}

    def parse(self, text: str):
        cur = None
        section = None
        member = None
        for line in text.splitlines():
            s = line.strip()
            m = re.match(r"Class descriptor\s*:\s*'(.+)'", s)
            if m:
                cur = self.classes.setdefault(m.group(1), {'super': None, 'interfaces': [], 'methods': set(), 'fields': set()})
                section = None
                continue
            if cur is None:
                continue
            if s.startswith('Superclass'):
                cur['super'] = re.search(r"'(.+)'", s).group(1)
            elif s.startswith('Interfaces'):
                section = 'interfaces'
            elif s.startswith(('Direct methods', 'Virtual methods')):
                section = 'methods'
            elif s.startswith(('Static fields', 'Instance fields')):
                section = 'fields'
            elif section == 'interfaces' and s.startswith('#') and 'name' not in s:
                i = re.search(r"'(.+)'", s)
                if i:
                    cur['interfaces'].append(i.group(1))
            elif s.startswith('name') and section in ('methods', 'fields'):
                member = re.search(r"'(.*)'", s).group(1)
            elif s.startswith('type') and section in ('methods', 'fields') and member is not None:
                t = re.search(r"'(.*)'", s).group(1)
                (cur['methods'] if section == 'methods' else cur['fields']).add(f'{member}:{t}')
                member = None

    def resolves(self, cls: str, member: str, kind: str, seen=None) -> bool:
        seen = seen or set()
        if cls in seen:
            return False
        seen.add(cls)
        if cls.startswith(FRAMEWORK):
            return True
        c = self.classes.get(cls)
        if c is None:
            return False
        if member in c[kind]:
            return True
        parents = ([c['super']] if c['super'] else []) + c['interfaces']
        return any(self.resolves(p, member, kind, seen) for p in parents)


def main():
    args = sys.argv[1:]
    report = None
    if '--report' in args:
        i = args.index('--report')
        report = Path(args[i + 1])
        del args[i:i + 2]
    dexdump, release, extensions = args[0], Path(args[1]), [Path(a) for a in args[2:]]
    tmp = Path(tempfile.mkdtemp())
    host = Model()
    for d in dexes(release, tmp):
        host.parse(dump(dexdump, d, False))
    lines = []
    missing_total = 0
    for ext in extensions:
        own = Model()
        texts = [dump(dexdump, d, True) for d in dexes(ext, tmp)]
        for t in texts:
            own.parse(t)
        refs = set()
        for t in texts:
            for line in t.splitlines():
                if 'method@' in line or 'field@' in line:
                    for m in REF.finditer(line):
                        kind = 'methods' if 'method@' in line else 'fields'
                        refs.add((m.group(1), f'{m.group(2)}:{m.group(3)}', kind))
        external = sorted(r for r in refs if r[0] not in own.classes and not r[0].startswith('['))
        hosted = [r for r in external if not r[0].startswith(FRAMEWORK)]
        missing = [r for r in hosted if not host.resolves(*r)]
        missing_total += len(missing)
        lines.append(f'{ext.name}: {len(external)} external member refs, {len(hosted)} on the host (not framework), {len(missing)} unresolved')
        lines += [f'  MISSING {c}.{m} ({k})' for c, m, k in missing]
    lines.append(f'TOTAL unresolved: {missing_total}')
    text = '\n'.join(lines) + '\n'
    print(text, end='')
    if report:
        report.write_text(text)
    sys.exit(1 if missing_total else 0)


if __name__ == '__main__':
    main()
