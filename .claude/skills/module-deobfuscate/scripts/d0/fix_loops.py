import re, sys

LOOP = re.compile(r'(?i)\bцикл\s*$')
END_LOOP = re.compile(r'(?i)^\s*конеццикла\b')
END_PROC = re.compile(r'(?i)^\s*конец(процедуры|функции)\b')


def fix(src, dst):
    lines = open(src, encoding='utf-8-sig').read().split('\n')
    out = []
    depth = 0
    fixed = 0
    for line in lines:
        w = line.lstrip('\t ').lower()
        if LOOP.search(w):
            depth += 1
        elif END_LOOP.match(w):
            depth -= 1
        elif END_PROC.match(w):
            ind = len(line) - len(line.lstrip('\t ')) + 4
            for _ in range(max(depth, 0)):
                out.append(' ' * ind + 'КонецЦикла;')
                fixed += 1
            depth = 0
        out.append(line)
    data = '\n'.join(out)
    open(dst, 'w', encoding='utf-8-sig', newline='').write(data)
    print('fixed', dst, fixed)


for src, dst in [(sys.argv[1], sys.argv[2])]:
    fix(src, dst)
