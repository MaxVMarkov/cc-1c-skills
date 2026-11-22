import re, sys

IF = re.compile(r'(?i)^\s*если\b')
ENDIF = re.compile(r'(?i)^\s*конецесли\b')
GOTO = re.compile(r'(?i)^\s*перейти\s+(~\d+)\s*;')
LABEL = re.compile(r'^\s*(~\d+)\s*:')


def indent(line):
    return len(line) - len(line.lstrip('\t '))


def fix(src, dst):
    lines = open(src, encoding='utf-8-sig').read().split('\n')
    labels = set()
    for l in lines:
        m = LABEL.match(l)
        if m:
            labels.add(m.group(1))
    out = []
    i = 0
    inserted = 0
    while i < len(lines):
        line = lines[i]
        m = GOTO.match(line)
        if m and m.group(1) not in labels:
            depth = 0
            j = i + 1
            target = None
            while j < len(lines):
                w = lines[j].lstrip('\t ')
                if IF.match(w):
                    depth += 1
                elif ENDIF.match(w):
                    depth -= 1
                    if depth <= 0:
                        k = j + 1
                        while k < len(lines) and not lines[k].strip():
                            k += 1
                        target = k
                        break
                j += 1
            if target is not None:
                ind = ' ' * indent(lines[j])
                lines.insert(target, ind + m.group(1) + ':')
                labels.add(m.group(1))
                inserted += 1
                out.append(line)
                i += 1
                continue
        out.append(line)
        i += 1
    data = '\n'.join(out)
    open(dst, 'w', encoding='utf-8-sig', newline='').write(data)
    print('fixed', dst, 'меток:', inserted)


for src, dst in [(sys.argv[1], sys.argv[2])]:
    fix(src, dst)
