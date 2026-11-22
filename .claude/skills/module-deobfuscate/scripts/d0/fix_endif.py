import re, sys

OPEN_IF = re.compile(r'(?i)^\s*если\b')
CLOSE_IF = re.compile(r'(?i)^\s*конецесли\b')
ELSE = re.compile(r'(?i)^\s*иначе\b')
END_PROC = re.compile(r'(?i)^\s*конец(процедуры|функции)\b')


def indent(line):
    return len(line) - len(line.lstrip('\t '))


def fix(src, dst):
    out = []
    stack = []
    for raw in open(src, encoding='utf-8-sig').read().split('\n'):
        line = raw.rstrip('\r')
        if not line.strip():
            out.append(line)
            continue
        ind = indent(line)
        w = line.lstrip('\t ')
        if CLOSE_IF.match(w):
            if stack:
                stack.pop()
            out.append(line)
            continue
        if END_PROC.match(w):
            while stack:
                out.append(' ' * stack.pop() + 'КонецЕсли;')
            stack = []
            out.append(line)
            continue
        if ELSE.match(w):
            while stack and stack[-1] > ind:
                out.append(' ' * stack.pop() + 'КонецЕсли;')
            out.append(line)
            continue
        while stack and ind <= stack[-1]:
            out.append(' ' * stack.pop() + 'КонецЕсли;')
        if OPEN_IF.match(w):
            stack.append(ind)
        out.append(line)
    data = '\n'.join(out) + '\n'
    open(dst, 'w', encoding='utf-8-sig', newline='').write(data)
    print('fixed', dst)


for src, dst in [(sys.argv[1], sys.argv[2])]:
    fix(src, dst)
