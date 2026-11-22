import re, sys

TERM_WORDS = ('Тогда', 'Иначе', 'Попытка', 'Исключение', 'КонецЕсли', 'КонецЦикла',
              'КонецПопытки', 'КонецПроцедуры', 'КонецФункции', 'Цикл', 'Экспорт')
HDR = re.compile(r'^\s*(Процедура|Функция)\b', re.I)
DIRECTIVE = re.compile(r'^\s*(&|#|//)')


def finished(line):
    s = line.rstrip()
    if not s:
        return True
    if s.endswith(';') or s.endswith(':'):
        return True
    for w in TERM_WORDS:
        if s.endswith(w):
            return True
    if HDR.match(s):
        return True
    if DIRECTIVE.match(s):
        return True
    return False


def quotes_open(line, state):
    i = 0
    while i < len(line):
        if line[i] == '"':
            if line[i:i + 2] == '""':
                i += 2
                continue
            state = not state
        i += 1
    return state


def split_kw(line):
    for word in ('Тогда', 'Цикл'):
        q = False
        i = 0
        wl = len(word)
        while i < len(line):
            c = line[i]
            if c == '"':
                if line[i:i + 2] == '""':
                    i += 2
                    continue
                q = not q
            elif not q and line.startswith(word, i) and i > 0 and line[i - 1] in ' \t' \
                    and (i + wl == len(line) or line[i + wl] in ' \t'):
                right = line[i + wl:].strip()
                if right:
                    indent = line[:len(line) - len(line.lstrip('\t '))]
                    return line[:i + wl], indent + right
            i += 1
    return line, None


def put(out, line):
    a, b = split_kw(line)
    out.append(a)
    while b is not None:
        a, b = split_kw(b)
        out.append(a)


def flatten(src, dst):
    out = []
    buf = None
    in_str = False
    for raw in open(src, encoding='utf-8-sig').read().split('\n'):
        line = raw.rstrip('\r')
        stripped = line.lstrip('\t ')
        glued = False
        if buf is not None and in_str:
            buf += stripped if stripped.startswith('|') else ' ' + stripped
            glued = True
        elif buf is not None and stripped.startswith('|'):
            buf += stripped
            glued = True
        elif buf is not None and stripped and not finished(buf):
            buf = buf.rstrip() + ' ' + stripped
            glued = True
        if glued:
            in_str = quotes_open(stripped, in_str)
            if not in_str and finished(buf):
                put(out, buf)
                buf = None
            continue
        if buf is not None:
            put(out, buf)
            buf = None
        buf = line
        in_str = quotes_open(line, False)
        if not in_str and finished(line):
            put(out, buf)
            buf = None
    if buf is not None:
        put(out, buf)
    data = '\r\n'.join(out) + '\r\n'
    open(dst, 'w', encoding='utf-8-sig', newline='').write(data)
    print('flat', dst, len(out), 'lines')


for src, dst in [(sys.argv[1], sys.argv[2])]:
    flatten(src, dst)
