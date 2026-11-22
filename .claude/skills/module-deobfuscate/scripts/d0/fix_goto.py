import re, sys

GOTO = re.compile(r'(?i)^\s*перейти\s+(~\w+)\s*;$')
EXCEPT = re.compile(r'(?i)^\s*исключение\b')
LABEL = re.compile(r'^\s*(~\w+)\s*:')


def fix(src, dst):
    lines = open(src, encoding='utf-8-sig').read().split('\n')
    removed = 0
    i = 0
    out = []
    while i < len(lines):
        line = lines[i]
        m = GOTO.search(line)
        if m:
            j = i + 1
            while j < len(lines) and not lines[j].strip():
                j += 1
            if j < len(lines) and EXCEPT.match(lines[j]):
                removed += 1
                i += 1
                continue
        out.append(line)
        i += 1
    open(dst, 'w', encoding='utf-8-sig', newline='').write('\n'.join(out))
    print('fix_goto', dst, 'удалено:', removed)


for src, dst in [(sys.argv[1], sys.argv[2])]:
    fix(src, dst)
